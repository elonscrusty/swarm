--[[
	LevelUpSystem.lua
	Stat sheets, level-up offers (3 cards, reroll, skip, auto-pick), weapon / passive
	upgrades, evolutions and treasure chest rewards.

	Earned levels bank between grouped upgrade panels. During a panel the player is
	"Paused": they stop moving, their weapons stop and
	(Config.Player.LevelUpInvulnerable) they can't be hurt. Solo: the world freezes too
	(RunManager.RefreshFrozen). Duo/Trio: the world keeps running and only the chooser is
	protected, bounded by GroupAutoPickSeconds and the protection budget
	(RunManager.ChoiceBudget). When the deadline passes a random card is taken for every
	choice left in the panel. The full contract: docs/overhaul/CHOICE_STATE.md
	(player attributes ChoiceOpen / ChoiceId / ChoiceOfferId / ChoiceProtectedUntil /
	ChoiceTimerPaused / ChoiceDeferred / ChoiceGroup).

	Card types: WeaponNew, WeaponUp, Evolve, PassiveNew, PassiveUp, Gold, Heal.
	Synergies (SynergyData): complete sets add their bonus to the stat sheet here; the
	player attribute "Synergies" lists discovered active ids.
	Combination clues are gated by discovery (DiscoveryService, saved per player): a
	weapon card names its evolution partner / result, a NEW card names the synergy it
	advances, and the ITEMS list names a synergy's missing pieces only once the player has
	owned or seen them; otherwise the clue says "???". Every card also carries Summary:
	one short line of what it gives now ("+10 damage, +1 arrow").
	Only the card index comes from the client; the server owns the card list.

	Batch B: EvolutionPreview (docs/next/EVOLUTION_PREVIEW.md) puts the evolution recipe with
	live progress on every weapon card that has an evolution and "Needed for <evolution>" on
	the partner passive's card (fields Hint / HintReady / EvoIcon / EvoName). Banish
	(docs/next/BANISH.md): remote LevelUpBanish (index, offerId) removes a NEW card's weapon /
	passive from the pool for the rest of the run (rp.Banished, rp.BanishesLeft from
	Config.LevelUp.Banishes) and re-rolls only that slot; owned things can never be banished.
]]

local Config = require(game:GetService("ReplicatedStorage").Shared.Config)
local Remotes = require(game:GetService("ReplicatedStorage").Shared.Remotes)
local WeaponData = require(game:GetService("ReplicatedStorage").Shared.WeaponData)
local PassiveData = require(game:GetService("ReplicatedStorage").Shared.PassiveData)
local StatSheet = require(game:GetService("ReplicatedStorage").Shared.StatSheet)
local SynergyData = require(game:GetService("ReplicatedStorage").Shared.SynergyData)
local EvolutionPreview = require(game:GetService("ReplicatedStorage").Shared.EvolutionPreview)
local RunConfig = require(game:GetService("ReplicatedStorage").SwarmV2.Run.RunConfig)
local BuildRules = require(game:GetService("ReplicatedStorage").SwarmV2.Run.BuildRules)
local Fx = require(script.Parent.Fx)

local LevelUpSystem = {}

local ctx
local rng = Random.new()

--[[
	[stream B] The continuation pack's rank system (RunConfig.Builds.Enabled; BuildRules;
	docs/redesign/gameplay/BUILDS.md). Its functions live in `R` (declared here so the older code
	above can branch into it). While on:
	  * 4 weapon + 4 passive slots, the class signature in weapon slot 1 at rank 1; catalog = the 15
	    WeaponData.Catalog weapons (another class's signature only when its class is owned) and the 8
	    PassiveData.LootOrder passives; every other weapon / passive / synergy is never offered.
	  * an offer: the eligible evolution first (deterministic), then up to 3 distinct options: a
	    category by weight (45 / 35 / 12 / 8, empty ones removed), an item uniform inside it, a rank
	    grant by rarity (70 / 23 / 6 / 1 for +1..+4, tiers past the item's capacity removed). An
	    exhausted pool offers one heal card (10 % max HP). Fewer options are shown honestly.
	  * choices queue (rp.ChoiceQueue: { Source = "Level" | "Chest", Kind = "Any" | "PassiveOnly" })
	    and show one at a time. A team run never pauses: the chooser keeps moving and fighting
	    (rp.LiveChoice, no protection), RunConfig.Builds.ChoiceSeconds per choice, the first card
	    on timeout. Solo keeps the old behaviour (the world freezes while choosing, the solo
	    timer). A downed hero's choice is suspended (rp.SuspendedOffer) and resumes on revival.
	  * 1 reroll per choice, Builds.FreeRerolls per run on top of the existing VIP pass / account
	    Reroll upgrade; a reroll is debited only when it produces a different offer, and keeps the
	    deadline. OfferId (rp.OfferSeq) validation as before.
	API (shared contract): QueueChoice(rp, source, kind), PendingCount(rp), CancelAll(rp).
]]
local R: { [string]: any } = {}
local Builds: { [string]: any } = RunConfig.Builds
local function ranked(): boolean
	return BuildRules.On()
end
local function weaponSlots(): number
	return ranked() and Builds.WeaponSlots or Config.Slots.Weapons
end
local function passiveSlots(): number
	return ranked() and Builds.PassiveSlots or Config.Slots.Passives
end

------------------------------------------------------------------------------------------
-- Discovery (DiscoveryService): what this player has owned or seen, across runs
------------------------------------------------------------------------------------------

local function known(rp, kind: string, id: string): boolean
	local D = ctx.DiscoveryService
	return D ~= nil and D.Known(rp.Player, kind, id)
end

local function discover(rp, kind: string, id: string)
	local D = ctx.DiscoveryService
	if D then
		D.Record(rp.Player, kind, id)
	end
end

local UNKNOWN = "???"

------------------------------------------------------------------------------------------
-- Stats
------------------------------------------------------------------------------------------

-- What the player owns, for SynergyData (optionally with other passive levels: cards).
local function ownedOf(rp, passives: { [string]: number }?): SynergyData.Owned
	return { Weapons = rp.Weapons or {}, Passives = passives or rp.Passives or {}, Items = rp.Items or {} }
end

-- The stage's team boon plus the player's complete synergies (both additive stat keys).
local function teamAndSynergy(rp, passives: { [string]: number }?): { [string]: number }?
	local team = ctx.LootSystem and ctx.LootSystem.TeamBonus() or nil
	local active = SynergyData.Active(ownedOf(rp, passives))
	if #active == 0 then
		return team
	end
	local b = SynergyData.Bonus(active)
	for k, v in pairs(team or {}) do
		b[k] = (b[k] or 0) + v
	end
	return b
end

-- The stat sheet for this run player, optionally with other passive levels (cards).
local function sheetFor(rp, passives: { [string]: number }?)
	return StatSheet.Compute({
		CharacterId = rp.CharacterId,
		Meta = rp.Meta,
		Passives = passives or rp.Passives,
		Items = rp.Items or {},
		Team = teamAndSynergy(rp, passives),
		Curse = ctx.RunModifiers and ctx.RunModifiers.StatMults() or nil,
		Sigils = rp.Sigils, -- META (feature 1): nil unless worn (never in Daily / Weekly runs)
		SigilAlone = rp.SigilAlone,
		Temp = rp.TempMods, -- temporary multipliers (Final Stand, FinalStand.lua); nil = none
	})
end

-- Publishes the active synergies (attribute "Synergies") and announces a new one.
local function updateSynergies(rp)
	local active = SynergyData.Active(ownedOf(rp))
	local key = table.concat(active, ",")
	if key == rp.SynergyKey then
		return
	end
	local before = SynergyData.FromString(rp.SynergyKey)
	rp.SynergyKey = key
	local player: Player = rp.Player
	player:SetAttribute("Synergies", key)
	for _, id in ipairs(active) do
		if not table.find(before, id) then
			local s = SynergyData.Synergies[id]
			if ctx.DiscoveryService then
				ctx.DiscoveryService.Record(player, "Synergies", id)
			end
			ctx.RunManager.Notify(player, string.format("Synergy: %s! %s", s.Name, s.Text), s.Color)
		end
	end
end

-- Rebuilds rp.Stats from base config + character + meta upgrades + passives + run items
-- (ItemData) + this stage's team boon (Bargain Shrine, LootSystem.TeamBonus) + complete
-- synergies (SynergyData): StatSheet.
function LevelUpSystem.RecomputeStats(rp)
	local oldMax = rp.Stats and rp.Stats.MaxHP or nil
	rp.Stats = sheetFor(rp)
	updateSynergies(rp)
	if oldMax and rp.Stats.MaxHP > oldMax and rp.HP then
		if ranked() then
			-- [stream B] a max-HP rise keeps the current HP fraction (a downed hero stays at 0)
			rp.HP = rp.HP / math.max(1, oldMax) * rp.Stats.MaxHP
		else
			-- Max HP increases also heal by the same amount.
			rp.HP += rp.Stats.MaxHP - oldMax
		end
	end
	if rp.HP then
		rp.HP = math.min(rp.HP, rp.Stats.MaxHP)
	end
	local player: Player = rp.Player
	player:SetAttribute("MaxHP", rp.Stats.MaxHP)
	if rp.HP then
		player:SetAttribute("HP", rp.HP)
	end
	if ranked() then
		-- [stream B] Spring Stitch numbers for the movement code (stream E1 / JumpController)
		player:SetAttribute("FallDamageMult", rp.Stats.FallDamageMult)
		player:SetAttribute("LandLockReduce", rp.Stats.LandLockReduce)
	end
	ctx.RunManager.ApplyMovement(rp)
	if ctx.ItemSystem then ctx.ItemSystem.UpdateShieldMax(rp) end -- Guardian Ward follows max HP
end

------------------------------------------------------------------------------------------
-- Inventory
------------------------------------------------------------------------------------------

--[[
	The ITEMS list's synergy rows: every synergy the player holds at least one piece of,
	{ Id?, Name, Text, Have, Need, Active, Pieces = { { Label, Owned } } } in SynergyData
	order (complete ones first). An undiscovered synergy (never completed before) has no Id
	and is named "???"; a missing piece is labelled only when one of the pieces that would
	fill it has been discovered, else "???".
]]
function LevelUpSystem.SynergyClues(rp): { { [string]: any } }
	if SynergyData.Hidden() then
		return {} -- [stream B] the rank system hides synergies
	end
	local owned = ownedOf(rp)
	local D = ctx.DiscoveryService
	local out = {}
	for _, sid in ipairs(SynergyData.Order) do
		local s = SynergyData.Synergies[sid]
		local have, need = SynergyData.Progress(sid, owned)
		if have >= 1 then
			local active = have >= need
			local revealed = active or known(rp, "Synergies", sid)
			local pieces = {}
			for _, piece in ipairs(s.Pieces) do
				local has = SynergyData.PieceOwned(piece, owned)
				local label = (has or (D and D.PieceKnown(rp.Player, piece))) and piece.Label or UNKNOWN
				table.insert(pieces, { Label = label, Owned = has })
			end
			table.insert(out, {
				Id = revealed and sid or nil,
				Name = revealed and s.Name or UNKNOWN,
				Text = s.Text,
				Have = have,
				Need = need,
				Active = active,
				Pieces = pieces,
			})
		end
	end
	-- complete ones first, each group in SynergyData order
	local sorted = {}
	for _, pass in ipairs({ true, false }) do
		for _, row in ipairs(out) do
			if row.Active == pass then
				table.insert(sorted, row)
			end
		end
	end
	return sorted
end

function LevelUpSystem.SendInventory(rp)
	local weapons = {}
	for slot, id in ipairs(rp.WeaponOrder) do
		local w = rp.Weapons[id]
		local def = WeaponData.Weapons[id]
		local row = {
			Id = id,
			Name = w.Evolved and def.Evolution.Name or def.Name,
			Level = w.Level,
			MaxLevel = WeaponData.MaxLevelOf(id),
			Evolved = w.Evolved,
			Color = def.Color,
		}
		if ranked() then
			-- [stream B] rank, effective damage / interval now and the known evolution requirement
			row.Rank = w.Level
			row.MaxRank = WeaponData.MaxLevelOf(id)
			row.Slot = slot
			row.Protected = slot == 1 or nil
			local s = rp.Stats and ctx.WeaponSystem.WeaponStats(rp, w)
			if s then
				row.Damage = math.floor(s.damage * 10 + 0.5) / 10
				row.Interval = math.floor(s.cooldown * 100 + 0.5) / 100
			end
			row.Evolution = R.evolutionText(rp, id)
			row.NextMilestone = WeaponData.NextMilestoneText(id, w.Level)
		end
		table.insert(weapons, row)
	end
	local passives = {}
	for _, id in ipairs(rp.PassiveOrder) do
		local def = PassiveData.Passives[id]
		table.insert(passives, { Id = id, Name = def.Name, Level = rp.Passives[id], MaxLevel = PassiveData.MaxLevelOf(id), Color = def.Color })
	end
	Remotes.FireClient("Inventory", rp.Player, {
		Weapons = weapons,
		Passives = passives,
		Synergies = LevelUpSystem.SynergyClues(rp),
		Rerolls = rp.Rerolls,
		Skips = rp.Skips,
		WeaponSlots = weaponSlots(),
		PassiveSlots = passiveSlots(),
		Ranked = ranked() or nil,
		Pending = ranked() and rp.PendingLevels or nil,
	})
end

function LevelUpSystem.AddWeapon(rp, weaponId: string): boolean
	if rp.Weapons[weaponId] or not WeaponData.Weapons[weaponId] then
		return false
	end
	if ranked() then
		-- [stream B] another class's signature only with that class owned (weapon behaviour only)
		R.setup(rp)
		if not WeaponData.AllowedWith(weaponId, rp.CharacterId, R.owned(rp)) then
			return false
		end
	elseif not WeaponData.AllowedFor(weaponId, rp.CharacterId) then
		return false -- a class signature weapon belongs to its own class only
	end
	if #rp.WeaponOrder >= weaponSlots() then
		return false
	end
	rp.Weapons[weaponId] = { Id = weaponId, Level = 1, Rank = 1, Evolved = false, Timer = 0.3, Live = {}, Growth = 0 }
	table.insert(rp.WeaponOrder, weaponId)
	if ctx.DiscoveryService then
		ctx.DiscoveryService.Record(rp.Player, "Weapons", weaponId)
	end
	return true
end

local function afterChange(rp)
	LevelUpSystem.RecomputeStats(rp)
	ctx.WeaponSystem.OnInventoryChanged(rp)
	LevelUpSystem.SendInventory(rp)
end

local function canEvolve(rp, weaponId: string): boolean
	if ranked() then
		return R.canEvolve(rp, weaponId)
	end
	local w = rp.Weapons[weaponId]
	local def = WeaponData.Weapons[weaponId]
	return w ~= nil and not w.Evolved and w.Level >= WeaponData.MaxLevel and def.Evolution ~= nil
		and (rp.Passives[def.Evolution.Passive] or 0) >= math.min(3, PassiveData.MaxLevelOf(def.Evolution.Passive))
end

------------------------------------------------------------------------------------------
-- Cards
------------------------------------------------------------------------------------------

local function card(kind: string, id: string, level: number, weight: number)
	return { Type = kind, Id = id, Level = level, Weight = weight }
end

-- Banish (Config.Features.Banish, docs/next/BANISH.md): banishes left this run (lazily set
-- from Config.LevelUp.Banishes: a run player is new every run) and the banished ids.
local function banishesLeft(rp): number
	if rp.BanishesLeft == nil then
		rp.BanishesLeft = math.max(0, math.floor(tonumber(Config.LevelUp.Banishes) or 0))
	end
	return rp.BanishesLeft
end

local function isBanished(rp, kind: string, id: string): boolean
	local b = rp.Banished
	return b ~= nil and b[kind .. ":" .. id] == true and Config.FeatureOn("Banish")
end

-- Only NEW cards can be banished (a card for something the player owns never can).
local BANISHABLE = { WeaponNew = "Weapon", PassiveNew = "Passive" }


-- Sheet stat → the weapon stat it feeds (a passive changing only stats no owned weapon
-- uses does nothing for this build). Player stats (HP, armor, speed ...) always count.
local WEAPON_STAT = {
	CooldownMult = "cooldown",
	AreaMult = "area",
	Amount = "amount",
	ProjSpeedMult = "speed",
	DurationMult = "duration",
	Pierce = "pierce",
}

local function anyWeaponUses(rp, stat: string): boolean
	for _, id in ipairs(rp.WeaponOrder) do
		if WeaponData.UsesStat(id, stat, rp.Weapons[id].Evolved) then
			return true
		end
	end
	return false
end

-- Is `passiveId` the evolution partner of a weapon this player owns (not yet evolved)?
local function evolvesOwned(rp, passiveId: string): boolean
	for _, id in ipairs(rp.WeaponOrder) do
		local def = WeaponData.Weapons[id]
		if not rp.Weapons[id].Evolved and def.Evolution and def.Evolution.Passive == passiveId then
			return true
		end
	end
	return false
end

-- Card lines of a passive going to `level` for this player (real numbers from the stat
-- sheet), and whether it does anything for the current build.
local function passiveLines(rp, passiveId: string, level: number): ({ { [string]: string } }, boolean)
	local passives = table.clone(rp.Passives)
	passives[passiveId] = level
	local lines = StatSheet.Lines(rp.Stats, sheetFor(rp, passives))
	local useful = false
	for _, line in ipairs(lines) do
		local stat = WEAPON_STAT[line.Key]
		if not stat or anyWeaponUses(rp, stat) then
			useful = true
		end
	end
	return lines, useful or evolvesOwned(rp, passiveId)
end

--[[
	How many unowned weapons (or passives) the "new" weight is shared out over at most:
	with 27 weapons and 26 passives every NEW card would otherwise bury the few upgrades a
	young build has (the first level-up offered the starting weapon only ~1 time in 6).
	The share starts small (NewPoolRefStart with one item owned) and grows by
	NewPoolRefPerItem per owned item up to NewWeaponPoolRef / NewPassivePoolRef, so early
	offers usually carry an upgrade of what you have and later ones keep bringing new items.
]]
local function newShare(rp, cap: number?, unowned: number): number
	local L = Config.LevelUp
	local owned = #rp.WeaponOrder + #rp.PassiveOrder
	local ref = cap or unowned
	if L.NewPoolRefStart then
		ref = math.min(ref, L.NewPoolRefStart + (L.NewPoolRefPerItem or 0) * math.max(0, owned - 1))
	end
	return math.min(1, ref / math.max(1, unowned))
end

local function buildPool(rp)
	local L = Config.LevelUp
	local luck = 1 + rp.Stats.Luck
	local pool = {}
	for _, id in ipairs(rp.WeaponOrder) do
		local w = rp.Weapons[id]
		if canEvolve(rp, id) then
			table.insert(pool, card("Evolve", id, WeaponData.MaxLevel, L.WeightEvolution))
		elseif not w.Evolved and w.Level < WeaponData.MaxLevel then
			table.insert(pool, card("WeaponUp", id, w.Level + 1, L.WeightUpgradeWeapon))
		end
	end
	if #rp.WeaponOrder < Config.Slots.Weapons then
		-- the shared weapons plus the signature weapon of this player's own class (a ClassOnly
		-- weapon is never offered to another class)
		local offer = {}
		for _, id in ipairs(WeaponData.Order) do
			if WeaponData.AllowedFor(id, rp.CharacterId) then
				table.insert(offer, id)
			end
		end
		for _, id in ipairs(WeaponData.ClassOrder) do
			if WeaponData.Weapons[id] and WeaponData.Weapons[id].ClassOnly == rp.CharacterId then
				table.insert(offer, id)
			end
		end
		local unowned = 0
		for _, id in ipairs(offer) do
			if not rp.Weapons[id] and not isBanished(rp, "Weapon", id) then
				unowned += 1
			end
		end
		-- with many weapons the "new weapon" weight is shared (newShare), so more weapons
		-- don't crowd out upgrades
		local share = newShare(rp, L.NewWeaponPoolRef, unowned)
		for _, id in ipairs(offer) do
			if not rp.Weapons[id] and not isBanished(rp, "Weapon", id) then
				table.insert(pool, card("WeaponNew", id, 1, L.WeightNewWeapon * luck * share))
			end
		end
	end
	-- Finish every owned passive before converting XP to coins. New passives must
	-- help the build or unlock an owned weapon's evolution.
	for _, id in ipairs(rp.PassiveOrder) do
		local level = rp.Passives[id]
		if level < PassiveData.MaxLevelOf(id) then
			table.insert(pool, card("PassiveUp", id, level + 1, L.WeightUpgradePassive))
		end
	end
	if #rp.PassiveOrder < Config.Slots.Passives then
		-- the useful new passives share one weight bucket, like new weapons (newShare)
		local fresh = {}
		for _, id in ipairs(PassiveData.Order) do
			if not rp.Passives[id] and not isBanished(rp, "Passive", id) then
				local _, useful = passiveLines(rp, id, 1)
				if useful then
					table.insert(fresh, id)
				end
			end
		end
		local share = newShare(rp, L.NewPassivePoolRef, #fresh)
		for _, id in ipairs(fresh) do
			local weight = L.WeightNewPassive * luck * share
			if evolvesOwned(rp, id) then
				weight *= L.EvolutionPassiveWeightMult -- the missing evolution piece shows up more
			end
			table.insert(pool, card("PassiveNew", id, 1, weight))
		end
	end
	return pool
end

local function joinLines(lines): string
	local parts = {}
	for _, line in ipairs(lines) do
		table.insert(parts, WeaponData.LineText(line))
	end
	return table.concat(parts, ", ")
end

-- Weapon card hint about its evolution, once the weapon is close (EvolveHintLevel+).
local function evolveHint(rp, c, def)
	local evo = def.Evolution
	if evo and EvolutionPreview.On() then
		-- EvolutionPreview: the recipe on every such weapon card, with live progress
		-- ("Bloodblade: Sword Lv 12 + Heart Lv 3 (you: Heart 1)") and the evolved icon
		local s = EvolutionPreview.Status(c.Id, c.Level, rp.Passives[evo.Passive] or 0)
		if s then
			c.Hint = EvolutionPreview.WeaponLine(s)
			c.HintReady = s.Ready
			-- the client hides the line until the partner passive is owned (or the weapon
			-- is near its evolution level); the BUILD panel still lists every recipe
			c.HintStarted = s.Ready or s.PassiveHave > 0 or c.Level >= Config.LevelUp.EvolveHintLevel
			c.EvoIcon = s.EvoId
			c.EvoName = s.Name
			return
		end
	end
	if not evo or c.Level < Config.LevelUp.EvolveHintLevel then
		return
	end
	local pdef = PassiveData.Passives[evo.Passive]
	local needed = math.min(3, PassiveData.MaxLevelOf(evo.Passive))
	local owned = (rp.Passives[evo.Passive] or 0) >= needed
	-- the partner passive is named once the player owns or has discovered it, the result
	-- once they have evolved this weapon before; otherwise "???"
	local partnerKnown = rp.Passives[evo.Passive] ~= nil or known(rp, "Passives", evo.Passive)
	local result = known(rp, "Evolutions", c.Id) and evo.Name or UNKNOWN
	local partner = string.format("%s Lv %d", partnerKnown and pdef.Name or UNKNOWN, needed)
	c.HintReady = owned
	if c.Level >= WeaponData.MaxLevel then
		c.Hint = owned and string.format("Evolves into %s next level-up!", result) or string.format("Evolves into %s with %s", result, partner)
	else
		c.Hint = string.format("Evolves at Lv %d with %s%s", WeaponData.MaxLevel, partner, owned and " (ready)" or "")
	end
end

-- The synergy a NEW weapon / passive would complete or advance (the player already holds
-- another piece): card fields Synergy ("Synergy: <name> have/need") and SynergyReady.
-- The synergy is named only once the player has completed it before; otherwise "???".
local function synergyClue(rp, c, kind: string)
	local s, have, need = SynergyData.Advances(ownedOf(rp), kind, c.Id)
	if not s then
		return
	end
	local name = known(rp, "Synergies", s.Id) and s.Name or UNKNOWN
	c.Synergy = string.format("Synergy: %s %d/%d", name, have, need)
	c.SynergyReady = have >= need
end

-- Adds display fields for the client:
--   Name, Rank ("NEW" | "Lv 3 → 4 / 8" | "EVOLUTION"), Lines (what changes, real numbers),
--   Description (short text; also the joined lines for older clients), Hint (evolution
--   requirement on weapon cards when close), Rarity / RarityLabel / RarityColor.
-- Synergy recipes stay hidden until players discover them through their build.
local function decorate(rp, c)
	local rarity = "Common"
	if c.Type == "WeaponNew" or c.Type == "WeaponUp" then
		local def = WeaponData.Weapons[c.Id]
		c.Name = def.Name
		c.Color = def.Color
		discover(rp, "Weapons", c.Id) -- seen on a card counts
		if c.Type == "WeaponNew" then
			rarity = "Rare"
			c.Rank = "NEW"
			-- the Healing Totem says how it heals from its real numbers (IntroText)
			c.Description = WeaponData.IntroText(c.Id, 1) or def.Description
			c.Lines = WeaponData.CardLines(c.Id, 0, 1)
			c.Summary = c.Description
			synergyClue(rp, c, "Weapon")
		else
			c.Rank = string.format("Lv %d → %d / %d", c.Level - 1, c.Level, WeaponData.MaxLevel)
			c.Lines = WeaponData.CardLines(c.Id, c.Level - 1, c.Level)
			c.Description = joinLines(c.Lines)
			-- one plain sentence for this pick ("Adds one extra sword swing per attack.")
			c.Summary = (WeaponData.BenefitText(c.Id, c.Lines)) or WeaponData.SummaryText(c.Lines, c.Description)
			if c.Level >= WeaponData.MaxLevel then
				rarity = "Epic"
			end
		end
		evolveHint(rp, c, def)
	elseif c.Type == "Evolve" then
		local def = WeaponData.Weapons[c.Id]
		c.Name = def.Evolution.Name
		c.Description = def.Evolution.Description
		c.Summary = def.Evolution.Description -- what it becomes, in a few words
		c.Color = def.Color
		c.Rank = "EVOLUTION"
		c.Lines = WeaponData.CardLines(c.Id, WeaponData.MaxLevel, WeaponData.MaxLevel, true)
		rarity = "Legendary"
	elseif c.Type == "PassiveNew" or c.Type == "PassiveUp" then
		local def = PassiveData.Passives[c.Id]
		local maxLevel = PassiveData.MaxLevelOf(c.Id)
		c.Name = def.Name
		c.Color = def.Color
		c.Lines = (passiveLines(rp, c.Id, c.Level))
		discover(rp, "Passives", c.Id)
		if c.Type == "PassiveNew" then
			rarity = "Rare"
			c.Rank = "NEW"
			c.Description = def.Description
			-- the gain of this level from the real Values ("Earn 15% more gold from ...")
			c.Summary = PassiveData.BenefitText(c.Id, c.Level) or WeaponData.SummaryText(c.Lines, def.Description)
			synergyClue(rp, c, "Passive")
		else
			c.Rank = string.format("Lv %d → %d / %d", c.Level - 1, c.Level, maxLevel)
			c.Description = def.Description -- the lines carry the real numbers
			c.Summary = PassiveData.BenefitText(c.Id, c.Level) or WeaponData.SummaryText(c.Lines, def.Description)
			if c.Level >= maxLevel then
				rarity = "Epic"
			end
		end
		-- the passive a weapon you own needs to evolve
		for _, id in ipairs(rp.WeaponOrder) do
			local wdef = WeaponData.Weapons[id]
			if not rp.Weapons[id].Evolved and wdef.Evolution and wdef.Evolution.Passive == c.Id then
				local s = EvolutionPreview.On() and EvolutionPreview.Status(id, rp.Weapons[id].Level, c.Level) or nil
				if s then
					-- EvolutionPreview: "Needed for Bloodblade (Heart Lv 3)"
					c.Hint = EvolutionPreview.PassiveLine(s)
					c.HintReady = s.Ready
					c.EvoIcon = s.EvoId
					c.EvoName = s.Name
					break
				end
				local needed = math.min(3, PassiveData.MaxLevelOf(c.Id))
				-- the weapon is owned (discovered); its evolution is named once reached before
				local into = known(rp, "Evolutions", id) and (" into " .. wdef.Evolution.Name) or ""
				c.Hint = string.format("Evolves %s at Lv %d with this at Lv %d%s", wdef.Name, WeaponData.MaxLevel, needed, into)
				c.HintReady = rp.Weapons[id].Level >= WeaponData.MaxLevel and c.Level >= needed
				break
			end
		end
	elseif c.Type == "Gold" then
		c.Name = "Gold Pouch"
		c.Description = "Everything is maxed: take some gold."
		c.Lines = { { Label = "Run gold", To = "+" .. Config.LevelUp.FallbackGold } }
		c.Summary = string.format("+%d run gold", Config.LevelUp.FallbackGold)
		c.Rank = "BONUS"
		c.Color = Color3.fromRGB(255, 210, 60)
	elseif c.Type == "Heal" then
		c.Name = "Roast Chicken"
		c.Description = "Everything is maxed: patch yourself up."
		c.Lines = { { Label = "Heal", To = Config.LevelUp.FallbackHeal .. " HP" } }
		c.Summary = string.format("Heal %d HP now", Config.LevelUp.FallbackHeal)
		c.Rank = "BONUS"
		c.Color = Color3.fromRGB(200, 120, 60)
	end
	c.Rarity = rarity
	c.RarityLabel = Config.LevelUp.Rarities[rarity].Label
	c.RarityColor = Config.LevelUp.Rarities[rarity].Color
	c.Weight = nil
	return c
end

--[[
	The first run's first offer (Config.FirstRun, rp.FirstRun): a flashy NEW weapon (the
	first ShowcaseWeapons id still in the pool) and the starting weapon's upgrade come
	first, the rest is a normal roll. Only the very first offer of that run (a reroll
	rolls normally).
]]
local function showcaseChoices(rp, pool): { any }
	local choices = {}
	if not rp.FirstRun or rp.FirstOfferShown then
		return choices
	end
	rp.FirstOfferShown = true
	local function take(kind: string, id: string?): boolean
		for i, c in ipairs(pool) do
			if c.Type == kind and c.Id == id then
				table.insert(choices, decorate(rp, c))
				table.remove(pool, i)
				return true
			end
		end
		return false
	end
	for _, id in ipairs((Config :: any).FirstRun.ShowcaseWeapons or {}) do
		if take("WeaponNew", id) then
			break
		end
	end
	take("WeaponUp", rp.WeaponOrder[1])
	return choices
end

-- A card's role tag (WeaponData.Roles / PassiveData.Roles): Damage, Recovery, Defense,
-- Growth or Utility. The client shows the same tag as a chip.
local function roleOf(c): string
	if c.Type == "PassiveNew" or c.Type == "PassiveUp" then
		return PassiveData.RoleOf(c.Id)
	elseif c.Type == "Heal" then
		return "Recovery"
	elseif c.Type == "Gold" then
		return "Growth"
	end
	return WeaponData.RoleOf(c.Id)
end

local function immediate(c): boolean
	return WeaponData.ImmediateRoles[roleOf(c)] == true
end

--[[
	Early build help (Config.LevelUp.EarlyHelpLevels): during the first level-ups of a run
	a set of undecorated draws with no Damage / Recovery / Defense card swaps its
	lowest-weight Utility card (else its lowest-weight Growth card) for a weighted pick of
	the pool's immediate upgrades / passives. NEW weapons and evolutions are never forced;
	a bonus-pick set is left alone.
]]
local function earlyHelp(rp, drawn: { any }, pool: { any })
	local L = Config.LevelUp
	-- the level-up this set is for (1 = the run's first), as sendOffer counts Level
	local index = (tonumber(rp.Level) or 1) - (tonumber(rp.PendingLevels) or 0)
	if #drawn == 0 or index > (L.EarlyHelpLevels or 0) or (rp.BonusPicks or 0) > 0 then
		return
	end
	for _, c in ipairs(drawn) do
		if immediate(c) then
			return
		end
	end
	local candidates, total = {}, 0
	for i, c in ipairs(pool) do
		if c.Type ~= "WeaponNew" and c.Type ~= "Evolve" and c.Weight > 0 and immediate(c) then
			table.insert(candidates, i)
			total += c.Weight
		end
	end
	if total <= 0 then
		return
	end
	local out, outRank, outWeight = nil, 0, math.huge
	for i, c in ipairs(drawn) do
		local rank = roleOf(c) == "Utility" and 2 or 1
		if rank > outRank or (rank == outRank and c.Weight < outWeight) then
			out, outRank, outWeight = i, rank, c.Weight
		end
	end
	if not out then
		return
	end
	local roll = rng:NextNumber() * total
	local pick = candidates[#candidates]
	for _, i in ipairs(candidates) do
		roll -= pool[i].Weight
		if roll <= 0 then
			pick = i
			break
		end
	end
	local swapped = drawn[out]
	drawn[out] = pool[pick]
	table.remove(pool, pick)
	table.insert(pool, swapped) -- back in the pool (a bonus pick below may still use it)
end

local function rollChoices(rp)
	if ranked() then
		local meta = rp.OfferMeta
		return R.roll(rp, meta and meta.Kind or "Any", meta and meta.Bonus) -- [stream B]
	end
	local pool = buildPool(rp)
	local choices = showcaseChoices(rp, pool)
	local showcase = #choices > 0
	local drawn = {}
	for _ = #choices + 1, Config.LevelUp.Choices do
		local total = 0
		for _, c in ipairs(pool) do
			total += c.Weight
		end
		if total <= 0 then
			break
		end
		local roll = rng:NextNumber() * total
		for i, c in ipairs(pool) do
			roll -= c.Weight
			if roll <= 0 then
				table.insert(drawn, c)
				table.remove(pool, i)
				break
			end
		end
	end
	if not showcase then
		earlyHelp(rp, drawn, pool)
	end
	-- decorated only now: a card swapped out above was never shown (no discovery record)
	for _, c in ipairs(drawn) do
		table.insert(choices, decorate(rp, c))
	end
	if #choices == 0 and #pool > 0 then
		-- never an empty panel (a protected pause with nothing to pick): the first legal card
		table.insert(choices, decorate(rp, pool[1]))
	end
	-- Clove Bulb Sigil (META): the first card set of the run shows one card fewer
	if rp.SigilFewerFirst then
		rp.SigilFewerFirst = nil
		if #choices > 1 then
			table.remove(choices)
		end
	end
	-- a bonus pick (Shrine of Trial, QueueBonusPick): at least one card above Common
	rp.OfferBoosted = nil
	if (rp.BonusPicks or 0) > 0 then
		local has = false
		for _, c in ipairs(choices) do
			has = has or c.Rarity ~= "Common"
		end
		local best = nil
		for _, c in ipairs(pool) do
			local rare = c.Type == "WeaponNew" or c.Type == "PassiveNew" or c.Type == "Evolve"
				or (c.Type == "WeaponUp" and c.Level >= WeaponData.MaxLevel)
				or (c.Type == "PassiveUp" and c.Level >= PassiveData.MaxLevelOf(c.Id))
			if not has and rare and (not best or c.Weight > best.Weight) then
				best = c
			end
		end
		if best then
			choices[math.min(#choices + 1, Config.LevelUp.Choices)] = decorate(rp, best)
		end
		rp.OfferBoosted = true
		for _, c in ipairs(choices) do
			c.Bonus = true -- the client may tag the set ("TRIAL REWARD")
		end
	end
	return choices
end

--[[
	One extra upgrade pick earned in the run (Shrine of Trial): queued like a level, and its
	card set always holds a card above Common (NEW / MAX / EVOLUTION) when the build still
	has one. Picked through the normal OfferId flow; used up by that pick (or a skip).
]]
function LevelUpSystem.QueueBonusPick(rp)
	if ranked() then
		-- [stream B] a queued choice whose offer holds a card above Common (R.roll `bonus`)
		rp.BonusPicks = (rp.BonusPicks or 0) + 1
		LevelUpSystem.QueueChoice(rp, "Level", "Any", true)
		return
	end
	rp.BonusPicks = (rp.BonusPicks or 0) + 1
	LevelUpSystem.QueueLevels(rp, 1)
end

local function useBonus(rp)
	if rp.OfferBoosted then
		rp.OfferBoosted = nil
		rp.BonusPicks = math.max(0, (rp.BonusPicks or 0) - 1)
	end
end

--[[
	Banish (docs/next/BANISH.md): after a banish only slot `index` of the open set changes. A
	weighted draw from the pool (the banished id is already out of it) that skips what the
	other slots show; when nothing is left, the existing bonus cards: Roast Chicken while
	hurt, else the Gold Pouch.
]]
local function rerollSlot(rp, index: number)
	if ranked() then
		R.rollSlot(rp, index) -- [stream B]
		return
	end
	local offer = rp.Offer
	local old = offer[index]
	local taken = {}
	for i, c in ipairs(offer) do
		if i ~= index then
			taken[c.Type .. ":" .. c.Id] = true
		end
	end
	local pool, total = {}, 0
	for _, c in ipairs(buildPool(rp)) do
		if not taken[c.Type .. ":" .. c.Id] then
			table.insert(pool, c)
			total += math.max(0, c.Weight)
		end
	end
	local pick = nil
	if total > 0 then
		local roll = rng:NextNumber() * total
		for _, c in ipairs(pool) do
			roll -= math.max(0, c.Weight)
			if roll <= 0 then
				pick = c
				break
			end
		end
		pick = pick or pool[#pool]
	elseif #pool > 0 then
		pick = pool[1]
	end
	local fallback = pick == nil
	if fallback then
		local hurt = rp.HP ~= nil and rp.Stats ~= nil and rp.HP < rp.Stats.MaxHP
		local kind = hurt and "Heal" or "Gold"
		if taken[kind .. ":" .. kind] then
			kind = kind == "Heal" and "Gold" or "Heal"
		end
		pick = card(kind, kind, 0, 0)
	end
	local c = decorate(rp, pick)
	if fallback then
		c.Description = c.Type == "Heal" and "Nothing else to offer: patch yourself up." or "Nothing else to offer: take some gold."
	end
	c.Bonus = old and old.Bonus or nil
	offer[index] = c
end

-- (tests / scenes) a decorated card exactly as an offer would show it, and the pool's
-- "Type:Id" keys for this player right now.
function LevelUpSystem.DescribeCard(rp, kind: string, id: string, level: number)
	return decorate(rp, card(kind, id, level, 0))
end
function LevelUpSystem.PoolKeys(rp): { string }
	local out = {}
	if ranked() then
		return R.poolKeys(rp, "Any") -- [stream B] "Category:Id" of the rank pool
	end
	for _, c in ipairs(buildPool(rp)) do
		table.insert(out, c.Type .. ":" .. c.Id)
	end
	return out
end
function LevelUpSystem.BanishesLeft(rp): number
	return banishesLeft(rp)
end

local function apply(rp, c)
	if ranked() then
		R.apply(rp, c) -- [stream B]
		return
	end
	if c.Type == "WeaponNew" then
		LevelUpSystem.AddWeapon(rp, c.Id)
	elseif c.Type == "WeaponUp" then
		local w = rp.Weapons[c.Id]
		if w and not w.Evolved then
			w.Level = math.min(WeaponData.MaxLevel, w.Level + 1)
		end
	elseif c.Type == "Evolve" then
		if canEvolve(rp, c.Id) then
			rp.Weapons[c.Id].Evolved = true
			if ctx.Analytics then
				ctx.Analytics.OnEvolution(rp.Player) -- before discover: an empty record = the account's first
			end
			discover(rp, "Evolutions", c.Id)
			ctx.RunManager.Notify(rp.Player, WeaponData.Weapons[c.Id].Evolution.Name .. "!", Color3.fromRGB(255, 210, 60))
		end
	elseif c.Type == "PassiveNew" then
		if not rp.Passives[c.Id] and #rp.PassiveOrder < Config.Slots.Passives then
			rp.Passives[c.Id] = 1
			table.insert(rp.PassiveOrder, c.Id)
			discover(rp, "Passives", c.Id)
		end
	elseif c.Type == "PassiveUp" then
		if rp.Passives[c.Id] then
			rp.Passives[c.Id] = math.min(PassiveData.MaxLevelOf(c.Id), rp.Passives[c.Id] + 1)
		end
	elseif c.Type == "Gold" then
		ctx.GoldSystem.AddRunGold(rp, Config.LevelUp.FallbackGold)
	elseif c.Type == "Heal" then
		ctx.RunManager.Heal(rp, Config.LevelUp.FallbackHeal)
	end
	afterChange(rp)
end

------------------------------------------------------------------------------------------
-- Offer flow
------------------------------------------------------------------------------------------

-- Mirrors the server choice state onto player attributes (read-only for the client).
-- ChoiceProtectedUntil is workspace:GetServerTimeNow() time; while ChoiceTimerPaused the
-- clock is stopped (solo pause menu, stage travel) and it is re-sent on resume.
local function publishChoice(rp)
	local player = rp.Player
	if not player.Parent then return end
	-- (a live team-run choice is open without pausing the chooser: [stream B] rp.LiveChoice)
	local open = rp.Offer ~= nil and (rp.Paused == true or rp.LiveChoice == true)
	player:SetAttribute("ChoiceOpen", open)
	player:SetAttribute("PendingChoices", rp.PendingLevels or 0) -- [stream B] shared contract
	player:SetAttribute("ChoiceLive", open and rp.LiveChoice == true or nil)
	player:SetAttribute("ChoiceId", open and rp.PanelId or nil)
	player:SetAttribute("ChoiceOfferId", open and rp.OfferSeq or nil)
	player:SetAttribute("ChoiceProtectedUntil", open and (workspace:GetServerTimeNow() + math.max(0, rp.OfferDeadline - os.clock())) or nil)
	if open then
		player:SetAttribute("ChoiceTimerPaused", rp.ChoiceTimerPaused == true)
		player:SetAttribute("ChoiceGroup", rp.ChoiceGroup == true)
	else
		player:SetAttribute("ChoiceTimerPaused", nil)
		player:SetAttribute("ChoiceGroup", nil)
	end
	player:SetAttribute("ChoiceDeferred", (not open and rp.PendingLevels > 0) and rp.ChoiceDeferred or nil)
end

local function setDeferred(rp, reason: string?)
	if rp.ChoiceDeferred ~= reason then
		rp.ChoiceDeferred = reason
		publishChoice(rp)
	end
end

local function sendOffer(rp)
	-- every new card set gets a fresh id: a pick / reroll / skip naming an older id (a
	-- double tap, a late packet) is ignored instead of landing on the next round
	rp.OfferSeq = (rp.OfferSeq or 0) + 1
	publishChoice(rp)
	local payload = R.offerFields(rp) -- [stream B] contract fields (nil while the rank system is off)
	Remotes.FireClient("LevelUpOffer", rp.Player, {
		-- [stream B] Deadline (server time), RerollsLeft (this choice), Source, Kind, Live, Empty
		-- and EmptyText (fewer options than Builds.Choices, said honestly)
		Deadline = payload and payload.Deadline,
		RerollsLeft = payload and payload.RerollsLeft,
		Source = payload and payload.Source,
		Kind = payload and payload.Kind,
		Live = payload and payload.Live,
		Empty = payload and payload.Empty,
		EmptyText = payload and payload.EmptyText,
		OfferId = rp.OfferSeq,
		Group = rp.ChoiceGroup == true,
		Choices = rp.Offer,
		Rerolls = rp.Rerolls,
		Skips = rp.Skips,
		RerollsMax = rp.RerollsMax or rp.Rerolls, -- per run (permanent upgrades, VIP)
		SkipsMax = rp.SkipsMax or rp.Skips,
		SkipGold = Config.LevelUp.SkipGold,
		-- Banish (docs/next/BANISH.md): nil while switched off (the client hides the button)
		Banishes = Config.FeatureOn("Banish") and banishesLeft(rp) or nil,
		BanishesMax = Config.FeatureOn("Banish") and math.max(0, math.floor(tonumber(Config.LevelUp.Banishes) or 0)) or nil,
		Seconds = math.max(0, rp.OfferDeadline - os.clock()),
		Level = rp.Level - rp.PendingLevels + 1,
		Pending = rp.PendingLevels,
		PanelId = rp.PanelId,
		BatchRemaining = rp.BatchRemaining,
		BatchTotal = rp.BatchTotal,
	})
end

local function closePanel(rp, grace: boolean?)
	local wasOpen = rp.Paused or rp.PanelOpen
	local wasLive = rp.LiveChoice == true
	rp.Offer = nil
	rp.OfferMeta = nil
	rp.BatchRemaining = 0
	rp.Paused = false
	rp.PanelOpen = false -- [stream B] rank system: a sequence of queued choices is showing
	rp.LiveChoice = false
	rp.ChoiceTimerPaused = false
	if wasOpen then
		publishChoice(rp)
		Remotes.FireClient("LevelUpClose", rp.Player)
		-- (a live team-run choice never protected anyone: no close grace either)
		if grace and not wasLive then ctx.RunManager.GrantChoiceGrace(rp) end
		ctx.RunManager.ApplyMovement(rp)
		ctx.RunManager.RefreshFrozen()
	end
end

-- Exhaustion uses the same useful-build pool as cards: no new slots or legal evolution
-- may be lost. The economy applies the selected tier and purchase/curses once.
local function convertMaxedLevels(rp): boolean
	if rp.PendingLevels <= 0 or #buildPool(rp) > 0 then return false end
	local minutes = math.floor(math.max(0, ctx.RunManager.GetRunTime() - (rp.LastDownTime or 0)) / 60)
	local value = Config.LevelUp.FallbackGold * math.min(3, 1 + 0.1 * minutes)
	local count = rp.PendingLevels
	rp.PendingLevels = 0
	closePanel(rp, true) -- the last card of a panel may have maxed the build: same grace as any close
	ctx.GoldSystem.AddRunGold(rp, value * count)
	return true
end

local function offerNext(rp)
	if ranked() then
		R.offerNext(rp) -- [stream B]
		return
	end
	if not rp.Alive then closePanel(rp); setDeferred(rp, nil); return end
	if rp.PendingLevels <= 0 then
		closePanel(rp, true)
		setDeferred(rp, nil)
		return
	end
	-- Step retries every frame while levels wait: nothing may open (or be converted) during
	-- a reward reel, a stage swap, the stage-clear (portal) dialog or the pause menu, so the
	-- pool is not built until it can. The levels stay banked (ChoiceDeferred says why).
	if not rp.Paused then
		local wait = nil
		if not ctx.RunManager.IsRunning() then
			wait = "Run"
		elseif ctx.RunManager.IsMenuPaused() or ctx.RunManager.IsFrozen() then
			wait = "Paused"
		elseif ctx.StageManager.IsHolding() then
			wait = "Travel"
		elseif rp.PortalOffered then
			wait = "Portal"
		elseif rp.RewardUntil then
			wait = "Reward"
		elseif ctx.RunManager.IsGroupChoice() and ctx.RunManager.ChoiceBudget(rp) < (Config.LevelUp.GroupMinPanelSeconds or 0) then
			wait = "Budget" -- protected too long this minute: keep fighting, the panel opens once it refills
		end
		setDeferred(rp, wait)
		if wait then return end
	end
	if convertMaxedLevels(rp) then return end
	if rp.Paused and rp.BatchRemaining <= 0 then
		closePanel(rp, true)
		return
	end
	if not rp.Paused then
		rp.PanelId = (rp.PanelId or 0) + 1
		rp.BatchRemaining = math.min(Config.LevelUp.ChoicesPerPanel, rp.PendingLevels)
		rp.BatchTotal = rp.BatchRemaining
		-- live group run: the panel's whole life is capped by the budget left (never more
		-- than GroupAutoPickSeconds); solo / last fighter: the world freezes, normal timer
		local group = ctx.RunManager.IsGroupChoice()
		rp.ChoiceGroup = group
		-- + RevealGraceSeconds: the clock must not run while the client is still revealing
		-- the cards (icon load, entrance, touch arming); a group panel stays capped by the
		-- protection budget left, which drains for the whole protected time as before
		local grace = Config.LevelUp.RevealGraceSeconds or 0
		local seconds = Config.LevelUp.AutoPickSeconds + grace
		if group then
			seconds = math.min(Config.LevelUp.GroupAutoPickSeconds + grace, ctx.RunManager.ChoiceBudget(rp))
		end
		rp.OfferDeadline = os.clock() + seconds
		rp.ChoiceTimerPaused = false
		rp.Paused = true
		rp.Offer = rollChoices(rp)
		-- after rp.Offer is set: RefreshFrozen counts a choice by rp.Offer (before this
		-- order fix a solo panel rooted the player but never froze the world)
		ctx.RunManager.ApplyMovement(rp)
		ctx.RunManager.RefreshFrozen()
	else
		rp.Offer = rollChoices(rp)
	end
	sendOffer(rp)
end

------------------------------------------------------------------------------------------
-- [stream B] RANK SYSTEM: pool, offers, queue, deadlines, rerolls (header of this module)
------------------------------------------------------------------------------------------

-- Once per run player: the run's free rerolls (on top of the account upgrade and VIP pass).
function R.setup(rp)
	if rp.RankSetup then
		return
	end
	rp.RankSetup = true
	local free = math.max(0, math.floor(tonumber(Builds.FreeRerolls) or 0))
	rp.Rerolls = (tonumber(rp.Rerolls) or 0) + free
	rp.RerollsMax = (tonumber(rp.RerollsMax) or 0) + free
end

-- The classes this player owns (save OwnedCharacters through the lobby's ClassOwnership rules),
-- snapshotted once per run; the run's own class and the free default class always count.
function R.owned(rp): { [string]: boolean }
	if rp.OwnedClasses then
		return rp.OwnedClasses
	end
	local set: { [string]: boolean } = {}
	local data = ctx.DataService and ctx.DataService.GetData and ctx.DataService.GetData(rp.Player) or nil
	if R.ownership == nil then
		R.ownership = false
		local folder = game:GetService("ServerScriptService"):FindFirstChild("SwarmV2")
		local lobby = folder and folder:FindFirstChild("Lobby")
		local mod = lobby and lobby:FindFirstChild("ClassOwnership")
		if mod and mod:IsA("ModuleScript") then
			local ok, m = pcall(require, mod)
			if ok and type(m) == "table" and type(m.Owns) == "function" then
				R.ownership = m
			end
		end
	end
	local owned = type(data) == "table" and type(data.OwnedCharacters) == "table" and data.OwnedCharacters or nil
	for cls in pairs(WeaponData.Signatures) do
		local yes = false
		if R.ownership then
			local ok, r = pcall(R.ownership.Owns, data, cls)
			yes = ok and r == true
		end
		set[cls] = yes or (owned ~= nil and owned[cls] == true)
	end
	local default = RunConfig.Classes and RunConfig.Classes.Default
	if default then
		set[default] = true -- Ruckus is free for every account
	end
	if rp.CharacterId then
		set[rp.CharacterId] = true
	end
	rp.OwnedClasses = set
	return set
end

-- (tests / stream C) may this player own another class's signature `weaponId` now?
function LevelUpSystem.Entitled(rp, weaponId: string): boolean
	return WeaponData.AllowedWith(weaponId, rp.CharacterId, R.owned(rp))
end

function R.canEvolve(rp, weaponId: string): boolean
	local w = rp.Weapons[weaponId]
	local def = WeaponData.Weapons[weaponId]
	return w ~= nil and def ~= nil and not w.Evolved and def.Evolution ~= nil
		and table.find(Builds.Evolutions, weaponId) ~= nil
		and w.Level >= Builds.EvolutionWeaponRank
		and (tonumber(rp.Level) or 1) >= Builds.EvolutionLevel
		and (rp.Passives[def.Evolution.Passive] or 0) >= Builds.EvolutionPassiveRank
end

-- "Evolves into Junkyard Cyclone: rank 5 + Patchwork Padding rank 3, level 8+" (nil: no recipe).
function R.evolutionText(rp, weaponId: string): string?
	local def = WeaponData.Weapons[weaponId]
	local w = rp.Weapons[weaponId]
	if not def or not def.Evolution or not table.find(Builds.Evolutions, weaponId) then
		return nil
	end
	local evo = def.Evolution
	if w and w.Evolved then
		return evo.Name
	end
	local pdef = PassiveData.Passives[evo.Passive]
	return string.format("Evolves into %s: rank %d + %s rank %d, level %d+", evo.Name, Builds.EvolutionWeaponRank,
		pdef and pdef.Name or evo.Passive, Builds.EvolutionPassiveRank, Builds.EvolutionLevel)
end

-- The first owned weapon whose evolution is offered now (deterministic, slot order), or nil.
function R.evolutionReady(rp): string?
	for _, id in ipairs(rp.WeaponOrder) do
		if R.canEvolve(rp, id) then
			return id
		end
	end
	return nil
end

--[[
	The rank pool for `kind` ("Any" | "PassiveOnly"): { [category] = { { Id, From } } }.
	WeaponUpgrade: owned catalog weapons below their max rank (not evolved); PassiveUpgrade: owned
	loot passives below rank 5; NewWeapon: catalog weapons not owned, allowed for this player
	(another class's signature only with that class owned), while a weapon slot is free; NewPassive:
	loot passives not owned while a passive slot is free. Banished ids and `exclude` keys
	("Category:Id") are left out.
]]
function R.pool(rp, kind: string, exclude: { [string]: boolean }?): { [string]: { any } }
	local pool = { WeaponUpgrade = {}, PassiveUpgrade = {}, NewWeapon = {}, NewPassive = {} }
	local function ok(cat: string, id: string): boolean
		return not (exclude and exclude[cat .. ":" .. id])
	end
	local max = BuildRules.MaxRank()
	if kind ~= "PassiveOnly" then
		for _, id in ipairs(rp.WeaponOrder) do
			local w = rp.Weapons[id]
			if WeaponData.IsRanked(id) and not w.Evolved and w.Level < max and ok("WeaponUpgrade", id) then
				table.insert(pool.WeaponUpgrade, { Id = id, From = w.Level })
			end
		end
		if #rp.WeaponOrder < weaponSlots() then
			local owned = R.owned(rp)
			for _, id in ipairs(WeaponData.Catalog) do
				if not rp.Weapons[id] and WeaponData.AllowedWith(id, rp.CharacterId, owned) and not isBanished(rp, "Weapon", id) and ok("NewWeapon", id) then
					table.insert(pool.NewWeapon, { Id = id, From = 0 })
				end
			end
		end
	end
	for _, id in ipairs(rp.PassiveOrder) do
		local level = rp.Passives[id]
		if table.find(PassiveData.LootOrder, id) and level < PassiveData.MaxLevelOf(id) and ok("PassiveUpgrade", id) then
			table.insert(pool.PassiveUpgrade, { Id = id, From = level })
		end
	end
	if #rp.PassiveOrder < passiveSlots() then
		for _, id in ipairs(PassiveData.LootOrder) do
			if not rp.Passives[id] and not isBanished(rp, "Passive", id) and ok("NewPassive", id) then
				table.insert(pool.NewPassive, { Id = id, From = 0 })
			end
		end
	end
	return pool
end

function R.poolKeys(rp, kind: string): { string }
	local out = {}
	local evo = kind ~= "PassiveOnly" and R.evolutionReady(rp) or nil
	if evo then
		table.insert(out, "Evolution:" .. evo)
	end
	for _, cat in ipairs(Builds.CategoryOrder) do
		for _, item in ipairs(R.pool(rp, kind)[cat]) do
			table.insert(out, cat .. ":" .. item.Id)
		end
	end
	return out
end

local RANK_TYPE = { WeaponUpgrade = "WeaponUp", NewWeapon = "WeaponNew", PassiveUpgrade = "PassiveUp", NewPassive = "PassiveNew", Evolution = "Evolve", Heal = "Heal" }

--[[
	A card for the offer payload (shared contract): Category, Rarity, RankFrom, RankTo, Slot, Lines
	(current -> next), Synergy (the evolution partner text or nil), plus the older fields the cards
	already read (Type, Id, Level = RankTo, Name, Color, Rank, Description, Summary, Hint, Role).
	o = { Category, Id, From, To, Tier }.
]]
function R.card(rp, o: any): { [string]: any }
	local cat = o.Category
	local max = BuildRules.MaxRank()
	local c: { [string]: any } = { Category = cat, Type = RANK_TYPE[cat], Id = o.Id or cat, RankFrom = o.From, RankTo = o.To, Level = o.To }
	local stats = rp.Stats or {}
	if cat == "Heal" then
		local amount = math.floor((stats.MaxHP or Config.Player.BaseMaxHP) * Builds.HealShare + 0.5)
		c.Id, c.Level, c.RankFrom, c.RankTo = "Heal", 0, nil, nil
		c.Name = "Patch-Up"
		c.Description = "Your build is complete: patch yourself up."
		c.Summary = string.format("Heal %d HP now (10%% of max HP)", amount)
		c.Lines = { { Label = "Heal", To = amount .. " HP" } }
		c.Rank = "HEAL"
		c.Color = Color3.fromRGB(120, 210, 120)
		c.Rarity = "Common"
	elseif cat == "Evolution" then
		local def = WeaponData.Weapons[o.Id]
		local evo = def.Evolution
		c.Level, c.RankFrom, c.RankTo = max, max, max
		c.Name = evo.Name
		c.Description = evo.Description
		c.Summary = evo.Description
		c.Color = def.Color
		c.Rank = "EVOLUTION"
		c.Lines = WeaponData.RankLines(o.Id, max, max, true)
		c.Slot = table.find(rp.WeaponOrder, o.Id)
		c.Rarity = "Evolution"
		c.RarityLabel = Builds.EvolutionLabel
		c.RarityColor = Builds.EvolutionColor
		c.EvoIcon = evo.Id
		c.EvoName = evo.Name
	elseif cat == "WeaponUpgrade" or cat == "NewWeapon" then
		local def = WeaponData.Weapons[o.Id]
		local new = cat == "NewWeapon"
		c.Name = def.Name
		c.Color = def.Color
		c.Lines = WeaponData.RankLines(o.Id, o.From, o.To, false, stats.DamageBonus or 0, stats.AttackSpeed or 0)
		c.Slot = table.find(rp.WeaponOrder, o.Id) or (#rp.WeaponOrder + 1)
		c.Rank = new and string.format("NEW · Rank %d", o.To) or string.format("Rank %d → %d / %d", o.From, o.To, max)
		c.Description = new and def.Description or joinLines(c.Lines)
		local milestone = nil
		for _, line in ipairs(c.Lines) do
			if line.Text then
				milestone = line.Text
			end
		end
		c.Summary = new and def.Description or (milestone or WeaponData.SummaryText(c.Lines, c.Description))
		local evoText = R.evolutionText(rp, o.Id)
		if evoText then
			local evo = def.Evolution
			c.Hint = evoText
			c.HintReady = false
			c.HintStarted = rp.Passives[evo.Passive] ~= nil or o.To >= 3
			c.EvoIcon = evo.Id
			c.EvoName = evo.Name
		end
		discover(rp, "Weapons", o.Id)
	else
		local def = PassiveData.Passives[o.Id]
		local new = cat == "NewPassive"
		c.Name = def.Name
		c.Color = def.Color
		local passives = table.clone(rp.Passives)
		passives[o.Id] = o.To
		local lines = { { Label = "Rank", From = (not new) and tostring(o.From) or nil, To = tostring(o.To) } }
		if rp.Stats then
			for _, line in ipairs(StatSheet.Lines(rp.Stats, sheetFor(rp, passives))) do
				table.insert(lines, line)
			end
		end
		c.Lines = lines
		c.Slot = table.find(rp.PassiveOrder, o.Id) or (#rp.PassiveOrder + 1)
		c.Rank = new and string.format("NEW · Rank %d", o.To) or string.format("Rank %d → %d / %d", o.From, o.To, max)
		c.Description = def.Description
		c.Summary = PassiveData.TotalText(o.Id, o.To) or def.Description
		-- the evolution partner of a weapon this player owns
		for _, id in ipairs(rp.WeaponOrder) do
			local wdef = WeaponData.Weapons[id]
			if not rp.Weapons[id].Evolved and wdef.Evolution and wdef.Evolution.Passive == o.Id and table.find(Builds.Evolutions, id) then
				c.Synergy = string.format("Evolves %s into %s at rank %d", wdef.Name, wdef.Evolution.Name, Builds.EvolutionPassiveRank)
				c.Hint = c.Synergy
				c.HintReady = o.To >= Builds.EvolutionPassiveRank and rp.Weapons[id].Level >= Builds.EvolutionWeaponRank and (tonumber(rp.Level) or 1) >= Builds.EvolutionLevel
				c.EvoIcon = wdef.Evolution.Id
				c.EvoName = wdef.Evolution.Name
				break
			end
		end
		discover(rp, "Passives", o.Id)
	end
	local tier = o.Tier
	if tier then
		c.Rarity = tier.Name
		c.RarityLabel = tier.Label or tier.Name
		c.RarityColor = tier.Color
	end
	c.RarityLabel = c.RarityLabel or c.Rarity
	c.Role = roleOf(c)
	return c
end

-- A fresh offer for `kind`: the eligible evolution first, then up to Builds.Choices distinct
-- options (BuildRules.RollOffer + RollRarity); nothing left = one heal card. bonus (a Shrine of
-- Trial pick): when no card is above Common, one card that has room gets an Uncommon+ grant
-- (weights renormalised over the tiers above Common that fit).
function R.roll(rp, kind: string, bonus: boolean?): { any }
	local cards = {}
	local evo = kind ~= "PassiveOnly" and R.evolutionReady(rp) or nil
	if evo then
		table.insert(cards, R.card(rp, { Category = "Evolution", Id = evo }))
	end
	local max = BuildRules.MaxRank()
	for _, pick in ipairs(BuildRules.RollOffer(rng, R.pool(rp, kind), Builds.Choices - #cards)) do
		local item = pick.Item
		local tier = BuildRules.RollRarity(rng, max - item.From)
		if tier then
			table.insert(cards, R.card(rp, { Category = pick.Category, Id = item.Id, From = item.From, To = item.From + tier.Ranks, Tier = tier }))
		end
	end
	if #cards == 0 then
		table.insert(cards, R.card(rp, { Category = "Heal" }))
	end
	if bonus then
		local above = false
		for _, c in ipairs(cards) do
			above = above or (c.Rarity ~= nil and c.Rarity ~= "Common")
		end
		for i, c in ipairs(cards) do
			local from = tonumber(c.RankFrom) or 0
			if above then
				break
			end
			if (c.Category == "WeaponUpgrade" or c.Category == "NewWeapon" or c.Category == "PassiveUpgrade" or c.Category == "NewPassive") and max - from >= 2 then
				local tiers, total = {}, 0
				for _, t in ipairs(BuildRules.RarityTable(max - from)) do
					if t.Ranks >= 2 then
						table.insert(tiers, t)
						total += t.Weight
					end
				end
				local roll, tier = rng:NextNumber() * total, tiers[#tiers]
				for _, t in ipairs(tiers) do
					roll -= t.Weight
					if roll < 0 then
						tier = t
						break
					end
				end
				cards[i] = R.card(rp, { Category = c.Category, Id = c.Id, From = from, To = from + tier.Ranks, Tier = tier })
				above = true
			end
		end
		for _, c in ipairs(cards) do
			c.Bonus = true -- the client may tag the set ("TRIAL REWARD")
		end
	end
	-- Clove Bulb Sigil (META): the run's first offer shows one card fewer (never the evolution)
	if rp.SigilFewerFirst and kind ~= "PassiveOnly" then
		rp.SigilFewerFirst = nil
		if #cards > 1 then
			table.remove(cards)
		end
	end
	return cards
end

-- Banish: only slot `index` changes (a draw that skips what the other slots show); nothing left:
-- the slot goes (never a duplicate), or a heal card when it was the only one.
function R.rollSlot(rp, index: number)
	local offer = rp.Offer
	local meta = rp.OfferMeta or {}
	local exclude = {}
	for i, c in ipairs(offer) do
		if i ~= index then
			exclude[tostring(c.Category) .. ":" .. tostring(c.Id)] = true
		end
	end
	local picks = BuildRules.RollOffer(rng, R.pool(rp, meta.Kind or "Any", exclude), 1)
	local pick = picks[1]
	local card = nil
	if pick then
		local tier = BuildRules.RollRarity(rng, BuildRules.MaxRank() - pick.Item.From)
		if tier then
			card = R.card(rp, { Category = pick.Category, Id = pick.Item.Id, From = pick.Item.From, To = pick.Item.From + tier.Ranks, Tier = tier })
		end
	end
	if card then
		offer[index] = card
	elseif #offer > 1 then
		table.remove(offer, index)
	else
		offer[index] = R.card(rp, { Category = "Heal" })
	end
end

local function cardKey(c): string
	return string.format("%s:%s:%s", tostring(c.Category), tostring(c.Id), tostring(c.RankTo))
end

function R.sameSet(a: { any }, b: { any }): boolean
	if #a ~= #b then
		return false
	end
	local keys = {}
	for _, c in ipairs(a) do
		keys[cardKey(c)] = true
	end
	for _, c in ipairs(b) do
		if not keys[cardKey(c)] then
			return false
		end
	end
	return true
end

function R.apply(rp, c)
	local max = BuildRules.MaxRank()
	local grant = (c.RankTo and c.RankFrom) and (c.RankTo - c.RankFrom) or 1
	grant = math.clamp(math.floor(tonumber(grant) or 1), 1, max - 1)
	if c.Type == "WeaponNew" then
		if LevelUpSystem.AddWeapon(rp, c.Id) then
			local w = rp.Weapons[c.Id]
			w.Level = math.clamp(math.floor(tonumber(c.RankTo) or 1), 1, WeaponData.MaxLevelOf(c.Id))
			w.Rank = w.Level
		end
	elseif c.Type == "WeaponUp" then
		local w = rp.Weapons[c.Id]
		if w and not w.Evolved then
			-- a stale card (the rank moved meanwhile) still gives its grant, never past the cap
			w.Level = math.min(WeaponData.MaxLevelOf(c.Id), w.Level + grant)
			w.Rank = w.Level
		end
	elseif c.Type == "Evolve" then
		if R.canEvolve(rp, c.Id) then
			rp.Weapons[c.Id].Evolved = true
			if ctx.Analytics then
				ctx.Analytics.OnEvolution(rp.Player)
			end
			discover(rp, "Evolutions", c.Id)
			ctx.RunManager.Notify(rp.Player, WeaponData.Weapons[c.Id].Evolution.Name .. "!", Builds.EvolutionColor)
		end
	elseif c.Type == "PassiveNew" then
		if not rp.Passives[c.Id] and PassiveData.Passives[c.Id] and #rp.PassiveOrder < passiveSlots() then
			rp.Passives[c.Id] = math.clamp(math.floor(tonumber(c.RankTo) or 1), 1, PassiveData.MaxLevelOf(c.Id))
			table.insert(rp.PassiveOrder, c.Id)
			discover(rp, "Passives", c.Id)
		end
	elseif c.Type == "PassiveUp" then
		if rp.Passives[c.Id] then
			rp.Passives[c.Id] = math.min(PassiveData.MaxLevelOf(c.Id), rp.Passives[c.Id] + grant)
		end
	elseif c.Type == "Heal" then
		-- living heroes only (RunManager.Heal refuses a downed / dead one)
		if rp.Alive and not rp.Downed and rp.Stats then
			ctx.RunManager.Heal(rp, rp.Stats.MaxHP * Builds.HealShare)
		end
	end
	afterChange(rp)
end

-- More than one hero in the run (eliminated / downed ones count, players who left do not):
-- choices never pause anything then.
function R.teamRun(): boolean
	local n = 0
	for _, o in ipairs(ctx.RunManager.GetRunPlayers()) do
		if not o.Returned then
			n += 1
		end
	end
	return n > 1
end

-- The choice queue, reconciled with rp.PendingLevels (older code may still bump that number).
function R.queue(rp): { any }
	local q = rp.ChoiceQueue
	if not q then
		q = {}
		rp.ChoiceQueue = q
	end
	local want = math.max(0, math.floor(tonumber(rp.PendingLevels) or 0))
	while #q < want do
		table.insert(q, { Source = "Level", Kind = "Any" })
	end
	while #q > want do
		table.remove(q)
	end
	return q
end

function R.publishPending(rp)
	local player = rp.Player
	if player and player.Parent then
		player:SetAttribute("PendingUpgrades", rp.PendingLevels)
		player:SetAttribute("PendingChoices", rp.PendingLevels)
		player:SetAttribute("XPReward", "Upgrade")
	end
end

-- Downed, eliminated or disconnected (inside the reconnect window): the personal choice waits.
function R.downed(rp): boolean
	return not rp.Alive or rp.Downed == true or rp.Returned == true or not (rp.Player and rp.Player.Parent)
end

-- Opens the queue's head choice when it can (or closes the panel when the queue is empty).
function R.offerNext(rp)
	local q = R.queue(rp)
	if rp.Offer then
		return -- the head choice is showing
	end
	if #q == 0 then
		closePanel(rp, true)
		setDeferred(rp, nil)
		return
	end
	if R.downed(rp) then
		closePanel(rp) -- a downed hero's choices wait for the revive (deadline suspended)
		setDeferred(rp, "Downed")
		return
	end
	if not rp.PanelOpen then
		local wait = nil
		if not ctx.RunManager.IsRunning() then
			wait = "Run"
		elseif ctx.RunManager.IsMenuPaused() or ctx.RunManager.IsFrozen() then
			wait = "Paused"
		elseif ctx.StageManager.IsHolding() then
			wait = "Travel"
		elseif rp.PortalOffered then
			wait = "Portal"
		elseif rp.RewardUntil then
			wait = "Reward"
		end
		setDeferred(rp, wait)
		if wait then
			return
		end
	end
	local live = R.teamRun()
	local head = q[1]
	local seconds
	local sus = rp.SuspendedOffer
	if sus then
		rp.SuspendedOffer = nil
		rp.OfferMeta = sus.Meta
		rp.Offer = sus.Choices
		seconds = sus.Left
	else
		rp.OfferMeta = { Source = head.Source, Kind = head.Kind, Rerolled = false, Bonus = head.Bonus }
		rp.Offer = R.roll(rp, head.Kind, head.Bonus)
		seconds = (live and Builds.ChoiceSeconds or Builds.SoloChoiceSeconds) + (Config.LevelUp.RevealGraceSeconds or 0)
	end
	rp.OfferBoosted = (rp.OfferMeta and rp.OfferMeta.Bonus) or nil -- useBonus spends the bonus pick
	rp.OfferDeadline = os.clock() + seconds
	rp.ChoiceTimerPaused = false
	if not rp.PanelOpen then
		rp.PanelId = (rp.PanelId or 0) + 1
		rp.BatchTotal = 0
	end
	rp.PanelOpen = true
	rp.LiveChoice = live
	rp.ChoiceGroup = live
	rp.Paused = not live -- solo: rooted, protected and the world frozen, as before the pack
	rp.BatchRemaining = #q
	rp.BatchTotal = math.max(rp.BatchTotal or 0, #q)
	ctx.RunManager.ApplyMovement(rp)
	ctx.RunManager.RefreshFrozen()
	setDeferred(rp, nil)
	sendOffer(rp)
end

-- Extra LevelUpOffer fields (shared contract); nil while the rank system is off.
function R.offerFields(rp): { [string]: any }?
	if not ranked() then
		return nil
	end
	local meta = rp.OfferMeta or {}
	local n = rp.Offer and #rp.Offer or 0
	local left = math.max(0, (rp.OfferDeadline or 0) - os.clock())
	local empty = math.max(0, Builds.Choices - n)
	local onlyHeal = n == 1 and rp.Offer[1].Type == "Heal"
	return {
		Deadline = workspace:GetServerTimeNow() + left,
		RerollsLeft = (meta.Rerolled or (rp.Rerolls or 0) <= 0) and 0 or math.min(Builds.RerollsPerPanel, rp.Rerolls),
		Source = meta.Source or "Level",
		Kind = meta.Kind or "Any",
		Live = rp.LiveChoice == true,
		Empty = empty > 0 and empty or nil,
		EmptyText = onlyHeal and "Your build is complete: nothing left to upgrade."
			or (empty > 0 and string.format("Only %d upgrade%s left for your build.", n, n == 1 and "" or "s") or nil),
	}
end

function R.choose(rp, index: number, offerId: number?)
	local offer = rp.Offer
	if not offer or (offerId ~= nil and offerId ~= rp.OfferSeq) or R.downed(rp) then
		return
	end
	local c = offer[index]
	if not c then
		return
	end
	local q = R.queue(rp)
	rp.Offer = nil
	table.remove(q, 1)
	rp.PendingLevels = #q
	useBonus(rp)
	-- offerNext must always run (it releases a solo freeze), even if apply fails
	local ok, err = pcall(apply, rp, c)
	R.offerNext(rp)
	R.publishPending(rp)
	if not ok then
		warn("[LevelUpSystem] apply failed: " .. tostring(err))
	end
end

--[[
	LevelUpSystem.QueueChoice(rp, source, kind): one personal choice. source "Level" | "Chest";
	kind "Any" | "PassiveOnly" (a chest: passive upgrades and new passives only). Choices show one
	at a time in queue order. Ignored after CancelAll (the run ended).
]]
function LevelUpSystem.QueueChoice(rp, source: string?, kind: string?, bonus: boolean?)
	if rp.ChoicesClosed then
		return
	end
	if not ranked() then
		LevelUpSystem.QueueLevels(rp, 1)
		return
	end
	-- [stream C] a chest reward charges Ruckus's Junk Collector (ClassKits; XP shards never do)
	if source == "Chest" and ctx.ClassKits then
		ctx.ClassKits.OnLootPickup(rp, "Chest")
	end
	R.setup(rp)
	local q = R.queue(rp)
	-- (bonus: a Shrine of Trial pick, QueueBonusPick: its offer holds a card above Common)
	table.insert(q, { Source = source == "Chest" and "Chest" or "Level", Kind = kind == "PassiveOnly" and "PassiveOnly" or "Any", Bonus = bonus == true or nil })
	rp.PendingLevels = #q
	if source ~= "Chest" then
		Fx.PlayerEvent(rp.Player, "levelup")
	end
	if not rp.Offer then
		R.offerNext(rp)
	else
		rp.BatchRemaining = #q
		rp.BatchTotal = math.max(rp.BatchTotal or 0, #q)
	end
	R.publishPending(rp)
end

-- Queued choices not yet made (the one showing included).
function LevelUpSystem.PendingCount(rp): number
	return math.max(0, math.floor(tonumber(rp.PendingLevels) or 0))
end

-- The run ended (victory / defeat / leave): every open and queued choice is dropped and no new
-- one opens for this run player. Choices already made stay.
function LevelUpSystem.CancelAll(rp)
	rp.ChoicesClosed = true
	rp.SuspendedOffer = nil
	rp.ChoiceQueue = {}
	LevelUpSystem.Cancel(rp)
end

-- (tests) a rank card exactly as an offer would build it.
function LevelUpSystem.RankCard(rp, category: string, id: string?, from: number?, to: number?)
	return R.card(rp, { Category = category, Id = id, From = from or 0, To = to or 1 })
end

-- (tests) a fresh rank offer for `kind` without opening anything.
function LevelUpSystem.RollOffer(rp, kind: string?)
	return R.roll(rp, kind or "Any")
end

function LevelUpSystem.QueueLevels(rp, count: number)
	if ranked() then
		-- [stream B] each filled XP bar is one personal choice in the queue
		for _ = 1, math.max(0, math.floor(count)) do
			LevelUpSystem.QueueChoice(rp, "Level", "Any")
		end
		if count <= 0 and not rp.Offer then
			R.offerNext(rp) -- (a revive: the waiting choices resume)
		end
		return
	end
	rp.PendingLevels += count
	if count > 0 and #buildPool(rp) > 0 then Fx.PlayerEvent(rp.Player, "levelup") end
	if not rp.Offer then
		offerNext(rp)
	elseif count > 0 and rp.Paused then
		-- Levels filled while a panel is open (portal vacuum, surge kills) join that panel
		-- (up to PanelMergeMax choices) instead of closing it and popping a second one
		-- straight after: one "LEVEL UP 2 / 5" panel, no extra wait, same shared deadline.
		local room = math.max(0, (Config.LevelUp.PanelMergeMax or Config.LevelUp.ChoicesPerPanel) - (rp.BatchTotal or 0))
		local add = math.min(count, room)
		rp.BatchRemaining += add
		rp.BatchTotal = (rp.BatchTotal or 0) + add
	end
	rp.Player:SetAttribute("PendingUpgrades", rp.PendingLevels)
	rp.Player:SetAttribute("XPReward", #buildPool(rp) == 0 and "Coins" or "Upgrade")
end

local function choose(rp, index: number, offerId: number?)
	if ranked() then
		R.choose(rp, index, offerId) -- [stream B]
		return
	end
	local offer = rp.Offer
	if not offer or (offerId ~= nil and offerId ~= rp.OfferSeq) then
		return
	end
	local c = offer[index]
	if not c then
		return
	end
	rp.Offer = nil
	rp.PendingLevels -= 1
	rp.BatchRemaining -= 1
	useBonus(rp)
	-- offerNext must always run (it releases the whole-run freeze), even if apply fails
	local ok, err = pcall(apply, rp, c)
	offerNext(rp)
	rp.Player:SetAttribute("PendingUpgrades", rp.PendingLevels)
	rp.Player:SetAttribute("XPReward", #buildPool(rp) == 0 and "Coins" or "Upgrade")
	if not ok then
		warn("[LevelUpSystem] apply failed: " .. tostring(err))
	end
end

-- Ends any open offer without applying it (death, leaving, run end).
function LevelUpSystem.Cancel(rp, preserveLevels: boolean?)
	if ranked() then
		-- [stream B] going down keeps the open choice (same cards, the time left) for the revive
		if preserveLevels and rp.Offer and #rp.Offer > 0 then
			rp.SuspendedOffer = { Choices = rp.Offer, Meta = rp.OfferMeta, Left = math.max(1, (rp.OfferDeadline or 0) - os.clock()) }
		elseif not preserveLevels then
			rp.SuspendedOffer = nil
			rp.ChoiceQueue = {}
		end
	end
	closePanel(rp)
	if not preserveLevels then rp.PendingLevels = 0; rp.BonusPicks = 0 end
	rp.ChoiceDeferred = nil
	publishChoice(rp)
	rp.Player:SetAttribute("PendingUpgrades", rp.PendingLevels)
	if rp.Player.Parent then
		Remotes.FireClient("LevelUpClose", rp.Player)
	end
	ctx.RunManager.RefreshFrozen()
end

------------------------------------------------------------------------------------------
-- Chests
------------------------------------------------------------------------------------------

local function chestLevelUp(rp, rewards)
	-- 1) an available evolution (old system only: the rank system offers evolutions in the level
	-- choices, never straight from a chest)
	for _, id in ipairs(rp.WeaponOrder) do
		if not ranked() and canEvolve(rp, id) then
			rp.Weapons[id].Evolved = true
			if ctx.Analytics then
				ctx.Analytics.OnEvolution(rp.Player) -- before discover: an empty record = the account's first
			end
			discover(rp, "Evolutions", id) -- a chest evolution reveals the result on later cards too
			local def = WeaponData.Weapons[id]
			table.insert(rewards, { Name = def.Evolution.Name, Text = "EVOLVED!", Color = def.Color })
			return true
		end
	end
	-- 2) a random owned weapon below max
	local candidates = {}
	for _, id in ipairs(rp.WeaponOrder) do
		local w = rp.Weapons[id]
		if not w.Evolved and w.Level < WeaponData.MaxLevelOf(id) then
			table.insert(candidates, id)
		end
	end
	if #candidates > 0 then
		local id = candidates[rng:NextInteger(1, #candidates)]
		local w = rp.Weapons[id]
		w.Level += 1
		w.Rank = w.Level
		local def = WeaponData.Weapons[id]
		table.insert(rewards, { Name = def.Name, Text = (ranked() and "Rank " or "Level ") .. w.Level, Color = def.Color })
		return true
	end
	-- 3) a random owned passive below max
	table.clear(candidates)
	for _, id in ipairs(rp.PassiveOrder) do
		if rp.Passives[id] < PassiveData.MaxLevelOf(id) then
			table.insert(candidates, id)
		end
	end
	if #candidates > 0 then
		local id = candidates[rng:NextInteger(1, #candidates)]
		rp.Passives[id] += 1
		local def = PassiveData.Passives[id]
		table.insert(rewards, { Name = def.Name, Text = "Level " .. rp.Passives[id], Color = def.Color })
		return true
	end
	return false
end

function LevelUpSystem.OpenChest(rp)
	local rewards = {}
	chestLevelUp(rp, rewards)
	if rng:NextNumber() < Config.Drops.ChestBonusLevelChance * (1 + rp.Stats.Luck) then
		chestLevelUp(rp, rewards)
	end
	-- stage modifier Elite Night: extra rolls (0 otherwise; docs/next/STAGE_MODIFIERS.md)
	for _ = 1, ctx.RunModifiers and ctx.RunModifiers.StageModCount and ctx.RunModifiers.StageModCount("ChestRolls") or 0 do
		chestLevelUp(rp, rewards)
	end
	-- elite chest gold grows with the stage: EliteStageScale up to stage 2, then the smaller
	-- EliteLateStageScale per stage from stage 3 on (stages 1-2 unchanged)
	local stageNo = math.max(1, ctx.StageManager.GetStage())
	local stageScale = 1 + Config.Gold.EliteStageScale * (math.min(stageNo, 2) - 1)
		+ (Config.Gold.EliteLateStageScale or Config.Gold.EliteStageScale) * math.max(0, stageNo - 2)
	local gold = ctx.GoldSystem.AddRunGold(rp, (rng:NextInteger(Config.Gold.ChestGoldMin, Config.Gold.ChestGoldMax) + Config.Gold.Elite) * stageScale * rp.Stats.GoldMult)
	afterChange(rp)
	local dramatic = #rewards > 1
	for _, reward in ipairs(rewards) do
		if reward.Text == "EVOLVED!" then dramatic = true end
	end
	Remotes.FireClient("ChestOpened", rp.Player, { Rewards = rewards, Gold = gold, Dramatic = dramatic })
	Fx.Sound("Chest")
	ctx.RunManager.HoldReward(rp, dramatic)
	if rp.PendingLevels > 0 then offerNext(rp) end
end

------------------------------------------------------------------------------------------
-- Dev tools (RunManager "DevCommand": Studio / creator only)
------------------------------------------------------------------------------------------

-- The weapons that came with the Alchemist, the Engineer and the Necromancer, then the armoury batch.
LevelUpSystem.NewWeapons = { "Spear", "Crossbow", "FrostNova", "FireTrail", "HealingTotem", "ChainHook", "Turret", "SoulBolt",
	"WardShields", "Earthsplitter", "Starfall", "Sling", "PlagueCenser", "Sawblade", "VineSnare", "WarHorn", "SpiritWisps", "Vortex" }

--[[
	evolve = false: gives every weapon in `list` (default NewWeapons; WeaponData.Order = all
	of them) at level 12 (past Config.Slots.Weapons: a test loadout). evolve = true: evolves
	every owned weapon (its passive is not needed).
]]
function LevelUpSystem.DevWeapons(rp, evolve: boolean, list: { string }?)
	if evolve then
		for _, id in ipairs(rp.WeaponOrder) do
			local w = rp.Weapons[id]
			if WeaponData.Weapons[id].Evolution then
				w.Level = WeaponData.MaxLevelOf(id) -- (rank system: rank 5)
				w.Rank = w.Level
				w.Evolved = true
			end
		end
	else
		for _, id in ipairs(list or LevelUpSystem.NewWeapons) do
			local max = WeaponData.MaxLevelOf(id)
			if not rp.Weapons[id] and WeaponData.Weapons[id] then
				rp.Weapons[id] = { Id = id, Level = max, Rank = max, Evolved = false, Timer = 0.3, Live = {}, Growth = 0 }
				table.insert(rp.WeaponOrder, id)
			elseif rp.Weapons[id] then
				rp.Weapons[id].Level = max
				rp.Weapons[id].Rank = max
			end
		end
	end
	afterChange(rp)
end

------------------------------------------------------------------------------------------
-- Lifecycle
------------------------------------------------------------------------------------------

function LevelUpSystem.Step(dt: number)
	if not ctx.RunManager.IsRunning() then return end
	-- Level-up pauses freeze the run too, but only the pause menu stops the auto-pick timer
	-- (otherwise a player could hold everyone's game paused forever).
	local menuPaused = ctx.RunManager.IsMenuPaused()
	local holding = ctx.StageManager.IsHolding()
	local now = os.clock()
	local rank = ranked()
	for _, rp in ipairs(ctx.RunManager.GetRunPlayers()) do
		if rank then
			-- [stream B] one choice at a time: downed = suspended (not the world), the first card
			-- when the personal deadline passes, the queue resumes on its own
			if rp.Offer and R.downed(rp) then
				LevelUpSystem.Cancel(rp, true)
			elseif rp.Offer then
				local timerPaused = menuPaused or holding
				if timerPaused ~= (rp.ChoiceTimerPaused == true) then
					rp.ChoiceTimerPaused = timerPaused
					publishChoice(rp)
				end
				if timerPaused then
					rp.OfferDeadline += dt
				elseif now >= rp.OfferDeadline then
					if #rp.Offer == 0 then
						closePanel(rp, true)
					else
						R.choose(rp, 1, rp.OfferSeq) -- the first displayed option
					end
				end
			elseif not R.downed(rp) and not menuPaused and not ctx.RunManager.IsFrozen() and ((rp.PendingLevels or 0) > 0 or rp.PanelOpen) then
				R.offerNext(rp)
			end
			continue
		end
		if rp.Offer and not rp.Alive then
			LevelUpSystem.Cancel(rp, true) -- downed / dead: close it, keep the banked levels
		elseif rp.Offer then
			-- the solo pause menu and stage travel stop the auto-pick clock (nobody can be
			-- hurt then); the duo run menu never does (menuPaused is solo only)
			local timerPaused = menuPaused or holding
			if timerPaused ~= (rp.ChoiceTimerPaused == true) then
				rp.ChoiceTimerPaused = timerPaused
				publishChoice(rp)
			end
			if timerPaused then
				rp.OfferDeadline += dt
			elseif now >= rp.OfferDeadline then
				-- One deadline bounds the entire protected panel, including all queued choices.
				for _ = 1, math.max(Config.LevelUp.ChoicesPerPanel, Config.LevelUp.PanelMergeMax or 0) do
					if not rp.Offer then break end
					if #rp.Offer == 0 then
						closePanel(rp, true) -- nothing to pick: never a stuck protected pause
						break
					end
					choose(rp, rng:NextInteger(1, #rp.Offer))
				end
			end
		elseif rp.Alive and not menuPaused and not ctx.RunManager.IsFrozen() then
			offerNext(rp)
		end
	end
end

function LevelUpSystem.Init(c)
	ctx = c
end

function LevelUpSystem.Start()
	-- offerId (LevelUpOffer.OfferId / attribute ChoiceOfferId): required. A request without
	-- it, or for any other card set, is dropped, so each round applies exactly once.
	local function staleId(rp, offerId): boolean
		return type(offerId) ~= "number" or offerId ~= rp.OfferSeq
	end

	Remotes.Listen("LevelUpChoose", function(player, index, offerId)
		local rp = ctx.RunManager.GetRunPlayer(player)
		if not rp or type(index) ~= "number" or index ~= index or staleId(rp, offerId) then
			return
		end
		index = math.floor(index)
		if index < 1 or index > Config.LevelUp.Choices + 1 then
			return
		end
		choose(rp, index, offerId)
	end, 6)

	Remotes.Listen("LevelUpReroll", function(player, offerId)
		local rp = ctx.RunManager.GetRunPlayer(player)
		if not rp or not rp.Offer or rp.Rerolls <= 0 or staleId(rp, offerId) then
			return
		end
		if ranked() then
			-- [stream B] one reroll per choice; debited only when a different offer comes out,
			-- the deadline stays; never while downed
			local meta = rp.OfferMeta
			if not meta or meta.Rerolled or R.downed(rp) then
				return
			end
			local new = R.roll(rp, meta.Kind or "Any", meta.Bonus)
			if R.sameSet(new, rp.Offer) then
				return
			end
			rp.Rerolls -= 1
			meta.Rerolled = true
			rp.Offer = new
			sendOffer(rp)
			LevelUpSystem.SendInventory(rp)
			return
		end
		rp.Rerolls -= 1
		rp.Offer = rollChoices(rp)
		-- keep the original deadline: rerolling must not extend the protected pause
		sendOffer(rp)
		LevelUpSystem.SendInventory(rp)
	end, 3)

	-- Banish (Config.Features.Banish, docs/next/BANISH.md): the NEW card at `index` leaves
	-- the pool for the rest of the run; only that slot re-rolls (fresh OfferId, same
	-- deadline: nobody's pause changes). Per player, so co-op needs nothing extra.
	Remotes.Listen("LevelUpBanish", function(player, index, offerId)
		if not Config.FeatureOn("Banish") then
			return
		end
		local rp = ctx.RunManager.GetRunPlayer(player)
		if not rp or not rp.Offer or not (rp.Paused or rp.LiveChoice) or type(index) ~= "number" or index ~= index or staleId(rp, offerId) then
			return
		end
		local c = rp.Offer[math.floor(index)]
		local kind = c and BANISHABLE[c.Type]
		if not c or not kind or banishesLeft(rp) <= 0 then
			return
		end
		-- never something the player owns
		if (kind == "Weapon" and rp.Weapons[c.Id]) or (kind == "Passive" and rp.Passives[c.Id]) then
			return
		end
		rp.Banished = rp.Banished or {}
		rp.Banished[kind .. ":" .. c.Id] = true
		rp.BanishesLeft -= 1
		rerollSlot(rp, math.floor(index))
		sendOffer(rp)
		rp.Player:SetAttribute("XPReward", (ranked() or #buildPool(rp) > 0) and "Upgrade" or "Coins")
	end, 3)

	Remotes.Listen("LevelUpSkip", function(player, offerId)
		local rp = ctx.RunManager.GetRunPlayer(player)
		if not rp or not rp.Offer or rp.Skips <= 0 or staleId(rp, offerId) then
			return
		end
		if ranked() and R.downed(rp) then
			return
		end
		rp.Skips -= 1
		rp.Offer = nil
		if ranked() then
			table.remove(R.queue(rp), 1) -- [stream B] the head choice is skipped
		end
		rp.PendingLevels -= 1
		useBonus(rp)
		rp.BatchRemaining -= 1
		ctx.GoldSystem.AddRunGold(rp, Config.LevelUp.SkipGold)
		LevelUpSystem.SendInventory(rp)
		offerNext(rp)
		if ranked() then
			R.publishPending(rp)
		end
	end, 3)
end

return LevelUpSystem
