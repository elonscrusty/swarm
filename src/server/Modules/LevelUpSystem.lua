--[[
	LevelUpSystem.lua
	Stat sheets, level-up offers (3 cards, reroll, skip, auto-pick), weapon / passive
	upgrades, evolutions and treasure chest rewards.

	Earned levels bank between grouped upgrade panels. During a panel the player is
	"Paused": they stop moving, their weapons stop and
	(Config.Player.LevelUpInvulnerable) they can't be hurt. The rest of the server keeps
	running. If they don't choose within Config.LevelUp.AutoPickSeconds a random card
	is taken for them.

	Card types: WeaponNew, WeaponUp, Evolve, PassiveNew, PassiveUp, Gold, Heal.
	Synergies (SynergyData): complete sets add their bonus to the stat sheet here; the
	player attribute "Synergies" lists discovered active ids.
	Combination clues are gated by discovery (DiscoveryService, saved per player): a
	weapon card names its evolution partner / result, a NEW card names the synergy it
	advances, and the ITEMS list names a synergy's missing pieces only once the player has
	owned or seen them; otherwise the clue says "???". Every card also carries Summary:
	one short line of what it gives now ("+10 damage, +1 arrow").
	Only the card index comes from the client; the server owns the card list.
]]

local Config = require(game:GetService("ReplicatedStorage").Shared.Config)
local Remotes = require(game:GetService("ReplicatedStorage").Shared.Remotes)
local WeaponData = require(game:GetService("ReplicatedStorage").Shared.WeaponData)
local PassiveData = require(game:GetService("ReplicatedStorage").Shared.PassiveData)
local StatSheet = require(game:GetService("ReplicatedStorage").Shared.StatSheet)
local SynergyData = require(game:GetService("ReplicatedStorage").Shared.SynergyData)
local Fx = require(script.Parent.Fx)

local LevelUpSystem = {}

local ctx
local rng = Random.new()

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
	-- Max HP increases also heal by the same amount.
	if oldMax and rp.Stats.MaxHP > oldMax then
		rp.HP += rp.Stats.MaxHP - oldMax
	end
	if rp.HP then
		rp.HP = math.min(rp.HP, rp.Stats.MaxHP)
	end
	local player: Player = rp.Player
	player:SetAttribute("MaxHP", rp.Stats.MaxHP)
	if rp.HP then
		player:SetAttribute("HP", rp.HP)
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
	for _, id in ipairs(rp.WeaponOrder) do
		local w = rp.Weapons[id]
		local def = WeaponData.Weapons[id]
		table.insert(weapons, {
			Id = id,
			Name = w.Evolved and def.Evolution.Name or def.Name,
			Level = w.Level,
			MaxLevel = WeaponData.MaxLevel,
			Evolved = w.Evolved,
			Color = def.Color,
		})
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
		WeaponSlots = Config.Slots.Weapons,
		PassiveSlots = Config.Slots.Passives,
	})
end

function LevelUpSystem.AddWeapon(rp, weaponId: string): boolean
	if rp.Weapons[weaponId] or not WeaponData.Weapons[weaponId] then
		return false
	end
	if #rp.WeaponOrder >= Config.Slots.Weapons then
		return false
	end
	rp.Weapons[weaponId] = { Id = weaponId, Level = 1, Evolved = false, Timer = 0.3, Live = {}, Growth = 0 }
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
		local unowned = 0
		for _, id in ipairs(WeaponData.Order) do
			if not rp.Weapons[id] then
				unowned += 1
			end
		end
		-- with many weapons the "new weapon" weight is shared, so the odds of a new weapon
		-- card stay what they were with the first 9 weapons (Config.LevelUp.NewWeaponPoolRef)
		local share = math.min(1, (L.NewWeaponPoolRef or unowned) / math.max(1, unowned))
		for _, id in ipairs(WeaponData.Order) do
			if not rp.Weapons[id] then
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
		for _, id in ipairs(PassiveData.Order) do
			if not rp.Passives[id] then
				local _, useful = passiveLines(rp, id, 1)
				if useful then
					local weight = L.WeightNewPassive * luck
					if evolvesOwned(rp, id) then
						weight *= L.EvolutionPassiveWeightMult -- the missing evolution piece shows up more
					end
					table.insert(pool, card("PassiveNew", id, 1, weight))
				end
			end
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
			c.Description = def.Description
			c.Lines = WeaponData.CardLines(c.Id, 0, 1)
			c.Summary = def.Description
			synergyClue(rp, c, "Weapon")
		else
			c.Rank = string.format("Lv %d → %d / %d", c.Level - 1, c.Level, WeaponData.MaxLevel)
			c.Lines = WeaponData.CardLines(c.Id, c.Level - 1, c.Level)
			c.Description = joinLines(c.Lines)
			c.Summary = WeaponData.SummaryText(c.Lines, c.Description)
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
			c.Summary = WeaponData.SummaryText(c.Lines, def.Description)
			synergyClue(rp, c, "Passive")
		else
			c.Rank = string.format("Lv %d → %d / %d", c.Level - 1, c.Level, maxLevel)
			c.Description = def.Description -- the lines carry the real numbers
			c.Summary = WeaponData.SummaryText(c.Lines, def.Description)
			if c.Level >= maxLevel then
				rarity = "Epic"
			end
		end
		-- the passive a weapon you own needs to evolve
		for _, id in ipairs(rp.WeaponOrder) do
			local wdef = WeaponData.Weapons[id]
			if not rp.Weapons[id].Evolved and wdef.Evolution and wdef.Evolution.Passive == c.Id then
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

local function rollChoices(rp)
	local pool = buildPool(rp)
	local choices = {}
	for _ = 1, Config.LevelUp.Choices do
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
				table.insert(choices, decorate(rp, c))
				table.remove(pool, i)
				break
			end
		end
	end
	return choices
end

local function apply(rp, c)
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

local function sendOffer(rp)
	Remotes.FireClient("LevelUpOffer", rp.Player, {
		Choices = rp.Offer,
		Rerolls = rp.Rerolls,
		Skips = rp.Skips,
		RerollsMax = rp.RerollsMax or rp.Rerolls, -- per run (permanent upgrades, VIP)
		SkipsMax = rp.SkipsMax or rp.Skips,
		SkipGold = Config.LevelUp.SkipGold,
		Seconds = math.max(0, rp.OfferDeadline - os.clock()),
		Level = rp.Level - rp.PendingLevels + 1,
		Pending = rp.PendingLevels,
		PanelId = rp.PanelId,
		BatchRemaining = rp.BatchRemaining,
		BatchTotal = rp.BatchTotal,
	})
end

local function closePanel(rp, grace: boolean?)
	local wasOpen = rp.Paused
	rp.Offer = nil
	rp.BatchRemaining = 0
	rp.Paused = false
	if wasOpen then
		Remotes.FireClient("LevelUpClose", rp.Player)
		if grace then ctx.RunManager.GrantChoiceGrace(rp) end
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
	closePanel(rp)
	ctx.GoldSystem.AddRunGold(rp, value * count)
	return true
end

local function offerNext(rp)
	if not rp.Alive then closePanel(rp); return end
	if convertMaxedLevels(rp) then return end
	if rp.PendingLevels <= 0 or (rp.Paused and rp.BatchRemaining <= 0) then
		closePanel(rp, true)
		return
	end
	if not rp.Paused then
		if not ctx.RunManager.IsRunning() or ctx.RunManager.IsMenuPaused() or ctx.RunManager.IsFrozen()
			or ctx.StageManager.IsHolding() or rp.RewardUntil then return end
		rp.PanelId = (rp.PanelId or 0) + 1
		rp.BatchRemaining = math.min(Config.LevelUp.ChoicesPerPanel, rp.PendingLevels)
		rp.BatchTotal = rp.BatchRemaining
		local group = #ctx.RunManager.GetRunPlayers() > 1
		rp.OfferDeadline = os.clock() + (group and Config.LevelUp.GroupAutoPickSeconds or Config.LevelUp.AutoPickSeconds)
		rp.Paused = true
		ctx.RunManager.ApplyMovement(rp)
		ctx.RunManager.RefreshFrozen()
	end
	rp.Offer = rollChoices(rp)
	sendOffer(rp)
end

function LevelUpSystem.QueueLevels(rp, count: number)
	rp.PendingLevels += count
	if count > 0 and #buildPool(rp) > 0 then Fx.PlayerEvent(rp.Player, "levelup") end
	if not rp.Offer then
		offerNext(rp)
	end
	rp.Player:SetAttribute("PendingUpgrades", rp.PendingLevels)
	rp.Player:SetAttribute("XPReward", #buildPool(rp) == 0 and "Coins" or "Upgrade")
end

local function choose(rp, index: number)
	local offer = rp.Offer
	if not offer then
		return
	end
	local c = offer[index]
	if not c then
		return
	end
	rp.Offer = nil
	rp.PendingLevels -= 1
	rp.BatchRemaining -= 1
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
	closePanel(rp)
	if not preserveLevels then rp.PendingLevels = 0 end
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
	-- 1) an available evolution
	for _, id in ipairs(rp.WeaponOrder) do
		if canEvolve(rp, id) then
			rp.Weapons[id].Evolved = true
			local def = WeaponData.Weapons[id]
			table.insert(rewards, { Name = def.Evolution.Name, Text = "EVOLVED!", Color = def.Color })
			return true
		end
	end
	-- 2) a random owned weapon below max
	local candidates = {}
	for _, id in ipairs(rp.WeaponOrder) do
		local w = rp.Weapons[id]
		if not w.Evolved and w.Level < WeaponData.MaxLevel then
			table.insert(candidates, id)
		end
	end
	if #candidates > 0 then
		local id = candidates[rng:NextInteger(1, #candidates)]
		local w = rp.Weapons[id]
		w.Level += 1
		local def = WeaponData.Weapons[id]
		table.insert(rewards, { Name = def.Name, Text = "Level " .. w.Level, Color = def.Color })
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
	-- elite chest gold grows with the stage so it keeps pace with chest / shrine prices
	local stageScale = 1 + Config.Gold.EliteStageScale * (math.max(1, ctx.StageManager.GetStage()) - 1)
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

-- The weapons that came with the Alchemist, the Engineer and the Necromancer.
LevelUpSystem.NewWeapons = { "Spear", "Crossbow", "FrostNova", "FireTrail", "HealingTotem", "ChainHook", "Turret", "SoulBolt" }

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
				w.Level = WeaponData.MaxLevel
				w.Evolved = true
			end
		end
	else
		for _, id in ipairs(list or LevelUpSystem.NewWeapons) do
			if not rp.Weapons[id] and WeaponData.Weapons[id] then
				rp.Weapons[id] = { Id = id, Level = WeaponData.MaxLevel, Evolved = false, Timer = 0.3, Live = {}, Growth = 0 }
				table.insert(rp.WeaponOrder, id)
			elseif rp.Weapons[id] then
				rp.Weapons[id].Level = WeaponData.MaxLevel
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
	local now = os.clock()
	for _, rp in ipairs(ctx.RunManager.GetRunPlayers()) do
		if rp.Offer then
			if menuPaused then
				rp.OfferDeadline += dt -- the solo pause menu also pauses the auto-pick timer
			elseif now >= rp.OfferDeadline then
				-- One deadline bounds the entire protected panel, including all queued choices.
				for _ = 1, Config.LevelUp.ChoicesPerPanel do
					if not rp.Offer then break end
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
	Remotes.Listen("LevelUpChoose", function(player, index)
		local rp = ctx.RunManager.GetRunPlayer(player)
		if not rp or type(index) ~= "number" or index ~= index then
			return
		end
		index = math.floor(index)
		if index < 1 or index > Config.LevelUp.Choices + 1 then
			return
		end
		choose(rp, index)
	end, 6)

	Remotes.Listen("LevelUpReroll", function(player)
		local rp = ctx.RunManager.GetRunPlayer(player)
		if not rp or not rp.Offer or rp.Rerolls <= 0 then
			return
		end
		rp.Rerolls -= 1
		rp.Offer = rollChoices(rp)
		-- keep the original deadline: rerolling must not extend the protected pause
		sendOffer(rp)
		LevelUpSystem.SendInventory(rp)
	end, 3)

	Remotes.Listen("LevelUpSkip", function(player)
		local rp = ctx.RunManager.GetRunPlayer(player)
		if not rp or not rp.Offer or rp.Skips <= 0 then
			return
		end
		rp.Skips -= 1
		rp.Offer = nil
		rp.PendingLevels -= 1
		rp.BatchRemaining -= 1
		ctx.GoldSystem.AddRunGold(rp, Config.LevelUp.SkipGold)
		LevelUpSystem.SendInventory(rp)
		offerNext(rp)
	end, 3)
end

return LevelUpSystem
