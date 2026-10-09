--[[
	GoldSystem.lua
	Run gold and the lobby economy (characters, skins, meta upgrades, settings).

	Run earnings are saved separately in RunEscrow until extraction or defeat. Chests
	spend only this ledger. Settlement retains all earnings on extraction, or a stage-based
	share on defeat. Existing savings and purchased coins never enter the at-risk ledger.
	All prices are read from the shared data modules on the server; the client only
	sends ids, never amounts.

	Team run gold (redesign, DECISIONS C7; RunConfig.Economy.Gold; stream E2): a second,
	temporary balance owned by the whole team, never saved and never converted into account
	gold. Credited once per eligible kill by enemy kind (CreditKill: Normal 3, Tough 6,
	Elite 20); it pays for chests only (BuyChest: round(40 x 1.35^k), at most 400, k = chests
	bought this run). SwarmState attributes TeamRunGold and ChestCost show both (and
	TeamChestsBought the purchase count, so the client can say "next chest"). It starts at
	Economy.Gold.StartGold with every run (BeginRun sees a new run id) and is cleared in the
	lobby. With the
	redesign economy on, chests no longer spend the personal escrow below; that escrow, its
	settlement (kill gold, survival gold, bonuses, pass multipliers, loss retention) is
	unchanged.
]]

local Config = require(game:GetService("ReplicatedStorage").Shared.Config)
local Remotes = require(game:GetService("ReplicatedStorage").Shared.Remotes)
local CharacterData = require(game:GetService("ReplicatedStorage").Shared.CharacterData)
local MetaUpgradeData = require(game:GetService("ReplicatedStorage").Shared.MetaUpgradeData)
local RunConfig = require(game:GetService("ReplicatedStorage"):WaitForChild("SwarmV2"):WaitForChild("Run"):WaitForChild("RunConfig"))

local Fx = require(script.Parent.Fx)

local GoldSystem = {}

local ctx
local rng = Random.new()

------------------------------------------------------------------------------------------
-- Team run gold (stream E2)
------------------------------------------------------------------------------------------

local function econ()
	return (RunConfig :: any).Economy
end

-- the team balance of the current run (server truth; the attributes only display it)
local team = { RunId = nil :: string?, Gold = 0, Bought = 0, Dirty = false, FlushedAt = 0 }
local TEAM_FLUSH = 0.1 -- s: kill credits reach the TeamRunGold attribute at most 10x a second

-- The redesign's team gold pays for chests (RunConfig.Economy.Enabled).
function GoldSystem.TeamGoldOn(): boolean
	local E = econ()
	return E ~= nil and E.Enabled == true
end

-- Chest price after `k` chests were bought this run: round(Base x Growth^k), at most Cap.
function GoldSystem.ChestCostAt(k: number): number
	local G = econ().Gold
	local cost = math.floor(G.ChestBase * G.ChestGrowth ^ math.max(0, math.floor(k)) + 0.5)
	return math.min(G.ChestCap, cost)
end

function GoldSystem.ChestCost(): number
	return GoldSystem.ChestCostAt(team.Bought)
end

function GoldSystem.TeamGold(): number
	return team.Gold
end

function GoldSystem.ChestsBought(): number
	return team.Bought
end

local function publishTeam()
	team.Dirty = false
	team.FlushedAt = os.clock()
	local state = Remotes.State()
	if state:GetAttribute("TeamRunGold") ~= team.Gold then
		state:SetAttribute("TeamRunGold", team.Gold)
	end
	local cost = GoldSystem.ChestCost()
	if state:GetAttribute("ChestCost") ~= cost then
		state:SetAttribute("ChestCost", cost)
	end
	-- [R5] chests bought this run: the HUD labels the price "NEXT CHEST" once one was bought, so
	-- the raised price never reads as what the last chest cost
	if state:GetAttribute("TeamChestsBought") ~= team.Bought then
		state:SetAttribute("TeamChestsBought", team.Bought)
	end
end

-- A new run (runId): the opening balance (Economy.Gold.StartGold, a proposal: 0 = none), no
-- chests bought. The lobby (nil): 0.
function GoldSystem.ResetTeamGold(runId: string?)
	team.RunId = runId
	local start = runId ~= nil and tonumber(econ().Gold.StartGold) or 0
	team.Gold = (start and start > 0 and start < math.huge) and math.floor(start) or 0
	team.Bought = 0
	publishTeam()
end

-- Team gold for one eligible kill of this enemy kind (XPSystem.OnEnemyKilled). Returns it.
function GoldSystem.CreditKill(kind: string): number
	local RM = ctx.RunManager
	if not GoldSystem.TeamGoldOn() or not (RM and RM.IsRunning and RM.IsRunning()) then
		return 0
	end
	local amount = tonumber(econ().Gold.ByKind[kind]) or 0
	if not (amount > 0 and amount < math.huge) then
		return 0
	end
	team.Gold += math.floor(amount)
	team.Dirty = true
	if os.clock() - team.FlushedAt >= TEAM_FLUSH then
		publishTeam()
	end
	return math.floor(amount)
end

-- Sets the team balance (DEV tools, tests): a whole amount >= 0; the purchase count stays.
function GoldSystem.SetTeamGold(amount: number)
	if not (amount >= 0 and amount < math.huge) then
		return
	end
	team.Gold = math.floor(amount)
	publishTeam()
end

-- Adds team gold directly (DEV tools, tests). Whole positive amounts only.
function GoldSystem.AddTeamGold(amount: number): number
	if not (amount > 0 and amount < math.huge) then
		return 0
	end
	team.Gold += math.floor(amount)
	publishTeam()
	return math.floor(amount)
end

--[[
	The one chest purchase: when the balance covers the current price it is debited ONCE,
	the purchase count goes up (the next price rises) and both attributes update, all in one
	step with no yield, so two interacts finishing together cannot both pay or both open.
	Returns (true, cost) or (false, cost) with nothing changed.
]]
function GoldSystem.BuyChest(): (boolean, number)
	local cost = GoldSystem.ChestCost()
	if team.Gold < cost then
		return false, cost
	end
	team.Gold -= cost
	team.Bought += 1
	publishTeam()
	return true, cost
end

------------------------------------------------------------------------------------------
-- Run gold
------------------------------------------------------------------------------------------

function GoldSystem.RetentionRate(cleared: number): number
	local rate = Config.Gold.FailureRetainBase + math.max(0, math.floor(cleared)) * Config.Gold.FailureRetainPerStage
	-- rounded to whole percents so 0.35 + 2 x 0.15 keeps 65%, not 64.99...%
	return math.min(Config.Gold.FailureRetainCap, math.floor(rate * 100 + 0.5) / 100)
end

-- Saved ledgers left by a crashed server are settled once when the profile loads.
function GoldSystem.RecoverEscrow(data): number
	local ledger = data.RunEscrow
	if type(ledger) ~= "table" then
		return 0
	end
	local gold, stages = tonumber(ledger.Gold) or 0, tonumber(ledger.Stages) or 0
	local kept = 0
	if gold == gold and stages == stages and gold < math.huge and stages < math.huge then
		kept = math.floor(math.max(0, gold) * GoldSystem.RetentionRate(stages))
	end
	data.Gold += kept
	data.RunEscrow = nil
	return kept
end

function GoldSystem.BeginRun(rp)
	-- [stream E2] the first record of a new run starts the team balance at 0
	local RM = ctx.RunManager
	if rp.RunId ~= nil and team.RunId ~= tostring(rp.RunId) and RM and RM.IsRunning and RM.IsRunning() then
		GoldSystem.ResetTeamGold(tostring(rp.RunId))
	end
	local data = ctx.DataService.GetData(rp.Player)
	if not data or rp.GoldSettlement then
		return
	end
	local id = tostring(rp.RunId)
	if data.RunEscrow and data.RunEscrow.Id == id then
		return
	end
	GoldSystem.RecoverEscrow(data)
	data.RunEscrow = { Id = id, Gold = rp.Gold or 0, Stages = 0 }
end

function GoldSystem.UpdateRunProgress(rp, cleared: number)
	local data = ctx.DataService.GetData(rp.Player)
	if data and data.RunEscrow and data.RunEscrow.Id == tostring(rp.RunId) then
		data.RunEscrow.Stages = math.max(data.RunEscrow.Stages, cleared)
	end
end

-- Survival gold (owner): Config.Gold.SurvivalPerMinute for every whole minute survived, up
-- to SurvivalMaxMinutes, times the published gold multiplier like all other gold.
function GoldSystem.SurvivalGold(player: Player, seconds: number?): number
	local s = tonumber(seconds) or 0
	if s ~= s or s <= 0 then
		return 0
	end
	local minutes = math.min(Config.Gold.SurvivalMaxMinutes or 0, math.floor(math.min(s, 1e7) / 60))
	if minutes <= 0 then
		return 0
	end
	return math.floor((Config.Gold.SurvivalPerMinute or 0) * minutes * GoldSystem.PublishGoldMult(player) + 0.5)
end

-- `seconds` = how long the player lasted. Survival gold goes straight to the save: never
-- into RunEscrow (chests can't spend it) and never cut by the loss rule.
function GoldSystem.SettleRun(rp, extracted: boolean, cleared: number, seconds: number?)
	if rp.GoldSettlement then
		return rp.GoldSettlement
	end
	local data = ctx.DataService.GetData(rp.Player)
	local ledger = data and data.RunEscrow
	local earned = ledger and ledger.Id == tostring(rp.RunId) and ledger.Gold or 0
	local rate = extracted and 1 or GoldSystem.RetentionRate(cleared)
	local kept = math.floor(earned * rate)
	if data and ledger and ledger.Id == tostring(rp.RunId) then
		data.Gold += kept
		data.RunEscrow = nil
	end
	local survival = data and GoldSystem.SurvivalGold(rp.Player, seconds) or 0
	if data and survival > 0 then
		data.Gold += survival
	end
	-- Roblox group members (GroupBonus.lua): a bonus on what this run paid into the lobby,
	-- added here at settlement only (never to in-run gold, so chest prices are unchanged)
	local group = 0
	if data and ctx.GroupBonus and ctx.GroupBonus.Settle then
		group = ctx.GroupBonus.Settle(rp, kept + survival, data)
	end
	-- Prestige stars of the hero played (Prestige.lua): the same base, settlement only
	local prestige = 0
	if data and ctx.Prestige and ctx.Prestige.Settle then
		prestige = ctx.Prestige.Settle(rp, kept + survival, data)
	end
	rp.GoldSettlement = { Earned = earned, Retained = kept, Lost = earned - kept, Rate = rate, Survival = survival, Group = group, Prestige = prestige }
	return rp.GoldSettlement
end

-- Adds gold (after gamepass multipliers and the run's curse bonus, CurseData) to the run
-- counter and its saved escrow. Returns amount.
function GoldSystem.AddRunGold(rp, base: number): number
	local player: Player = rp.Player
	local data = ctx.DataService.GetData(player)
	if not data or base <= 0 or base ~= base or base == math.huge or rp.GoldSettlement then
		return 0
	end
	GoldSystem.BeginRun(rp)
	local curse = ctx.RunModifiers and ctx.RunModifiers.GoldMult() or 1
	local amount = math.floor(base * GoldSystem.PublishGoldMult(player) * curse + 0.5)
	data.RunEscrow.Gold += amount
	rp.Gold += amount
	player:SetAttribute("RunGold", rp.Gold)
	-- the pass lookup has not answered yet (first seconds on a fresh server): remember
	-- what was earned so the pass bonus can be paid back once it does (EC-A21)
	local mon = ctx.MonetizationService
	if mon.PassesKnown and not mon.PassesKnown(player) then
		local early = rp.EarlyGold or { Base = 0, Paid = 0 }
		early.Base += base * curse
		early.Paid += amount
		rp.EarlyGold = early
	end
	return amount
end

-- Pays the difference for gold earned before the pass lookup answered (AddRunGold keeps
-- it in rp.EarlyGold): the multiplier the player really has, minus what was paid. Once
-- per run; nothing for non-owners. Returns the top-up.
function GoldSystem.CorrectEarlyGold(rp): number
	local early = rp.EarlyGold
	if not early or rp.GoldSettlement then
		return 0
	end
	rp.EarlyGold = nil
	local data = ctx.DataService.GetData(rp.Player)
	if not data or not data.RunEscrow or data.RunEscrow.Id ~= tostring(rp.RunId) then
		return 0
	end
	local owed = math.floor(early.Base * GoldSystem.PublishGoldMult(rp.Player) + 0.5) - early.Paid
	if owed <= 0 or owed ~= owed or owed == math.huge then
		return 0
	end
	data.RunEscrow.Gold += owed
	rp.Gold += owed
	rp.Player:SetAttribute("RunGold", rp.Gold)
	return owed
end

--[[
	The gamepass gold multiplier chests and shrines are priced with. The client shows prices
	with the GoldMult attribute (LootUI.priceOf), so the server charges with that same
	server-written value, never with a newer one the client has not seen: a pass lookup that
	answers late (fresh run server, a slow or failed first lookup) or a pass bought mid-run
	used to raise the charged price above the shown one ("Not enough gold." with enough gold
	on the HUD). PublishGoldMult moves earnings and the shown price together.
]]
function GoldSystem.PublishGoldMult(player: Player): number
	local mult = ctx.MonetizationService.GoldMultiplier(player)
	if player:GetAttribute("GoldMult") ~= mult then
		player:SetAttribute("GoldMult", mult)
	end
	return mult
end

function GoldSystem.PriceMult(player: Player): number
	local shown = tonumber(player:GetAttribute("GoldMult"))
	if shown and shown == shown and shown > 0 and shown < math.huge then
		return shown
	end
	return GoldSystem.PublishGoldMult(player)
end

-- Only the current run's unspent escrow can pay for chests and shrines.
function GoldSystem.RunWallet(rp): number
	local data = ctx.DataService.GetData(rp.Player)
	if not data then
		return 0
	end
	local ledger = data.RunEscrow
	return ledger and ledger.Id == tostring(rp.RunId) and math.max(0, math.min(rp.Gold, ledger.Gold)) or 0
end

-- Spends run gold (chests, shrines). False (and nothing spent) when the run can't afford
-- it. Keeps the saved escrow and run counter in step.
function GoldSystem.SpendRunGold(rp, amount: number): boolean
	if amount ~= amount or math.abs(amount) == math.huge then
		return false
	end
	amount = math.floor(amount)
	if amount <= 0 then
		return true
	end
	local data = ctx.DataService.GetData(rp.Player)
	if not data or GoldSystem.RunWallet(rp) < amount then
		return false
	end
	data.RunEscrow.Gold -= amount
	rp.Gold -= amount
	rp.GoldSpent = (rp.GoldSpent or 0) + amount
	rp.Player:SetAttribute("RunGold", rp.Gold)
	return true
end

-- Normal kill: 1-3 gold with Config.Gold.KillGoldChance (x the run's GoldMult: items, the
-- Bargain Shrine). pos (where the enemy died) only feeds the coin burst clients draw.
-- chanceMult scales the chance (wave enemies: Config.Waves.GoldChanceMult).
function GoldSystem.OnKill(rp, pos: Vector3?, chanceMult: number?)
	local chance = Config.Gold.KillGoldChance * (chanceMult or 1)
	if ctx.WorldEvents then
		chance = ctx.WorldEvents.GoldChance(chance) -- a GOLD RUSH map event (capped)
	end
	if rng:NextNumber() < chance then
		local mod = ctx.RunModifiers and ctx.RunModifiers.StageMod and ctx.RunModifiers.StageMod("KillGold") or 1 -- stage modifier Bounty
		local paid = GoldSystem.AddRunGold(rp, rng:NextInteger(Config.Gold.MinPerKill, Config.Gold.MaxPerKill) * (rp.Stats and rp.Stats.GoldMult or 1) * mod)
		if paid > 0 and pos then
			Fx.Gold(pos, paid, rp.Player.UserId)
		end
		return paid
	end
	return 0
end

------------------------------------------------------------------------------------------
-- Lobby economy
------------------------------------------------------------------------------------------

-- Sends the lobby view of the save to the client.
function GoldSystem.SyncProfile(player: Player)
	local data = ctx.DataService.GetData(player)
	if not data then
		return
	end
	local M = ctx.MonetizationService
	Remotes.FireClient("ProfileSync", player, {
		Gold = data.Gold,
		Difficulty = data.Difficulty,
		DifficultyClears = data.DifficultyClears,
		Meta = data.Meta,
		Heroes = data.Heroes or {}, -- Hero Mastery: { heroId = { XP, Runs } }
		HeroUpgrades = data.HeroUpgrades or {}, -- { heroId = { upgradeId = level } }
		OwnedCharacters = data.OwnedCharacters,
		SelectedCharacter = data.SelectedCharacter,
		Skins = data.Skins,
		Stats = data.Stats,
		Settings = data.Settings,
		TutorialDone = data.TutorialDone == true,
		SeenTips = data.SeenTips or {},
		TutorialStep = tonumber(data.TutorialStep) or 0, -- tutorial runs played (SmartTutorial)
		ReviveTokens = data.ReviveTokens,
		Achievements = ctx.AchievementService and ctx.AchievementService.ProfileView(data) or nil,
		Title = data.Title or "",
		NameColor = data.NameColor or "",
		-- retention: curses picked, the daily, the account level and its cosmetics
		Curses = data.Curses or {},
		Daily = ctx.RunModifiers and ctx.RunModifiers.DailyView(data) or nil,
		Journal = data.Journal,
		LastRun = data.LastRun,
		Account = ctx.AccountService and ctx.AccountService.View(data) or nil,
		Ring = data.Ring or "",
		Frame = data.Frame or "",
		OwnedSkins = M.OwnedSkins(player),
		Passes = {
			StarterPack = M.OwnsPass(player, "StarterPack"),
			VIP = M.OwnsPass(player, "VIP"),
			DoubleGold = M.OwnsPass(player, "DoubleGold"),
		},
		-- the cosmetic store (StoreService.View: owned / worn looks, Supporter); nil with Store off
		Store = ctx.StoreService and ctx.StoreService.View(player, data) or nil,
		MemoryOnly = ctx.DataService.IsMemoryOnly(),
		-- 30-features batch save fields (DataService.FeatureView, docs/features/FOUNDATION.md)
		Features = ctx.DataService.FeatureView and ctx.DataService.FeatureView(data) or nil,
	})
	player:SetAttribute("Gold", data.Gold)
	-- the server sends damage numbers only to players who switched them on
	player:SetAttribute("DamageNumbers", data.Settings.DamageNumbers == true)
end

local function inLobby(player: Player): boolean
	return not ctx.RunManager.IsParticipant(player)
end

-- The profile a lobby action may change: loaded, still ours and not handed to a teleport
-- (DataService.IsReady). A change made while the profile is released (teleport handoff) would
-- stay in memory and never be saved, so those actions are refused instead.
-- A hero the lobby lists (CharacterData.Order: the twelve classes). The old heroes are hidden
-- (docs/redesign/DECISIONS.md): their entries and save data stay, but they are never bought,
-- selected or upgraded again.
local function listedHero(characterId: string): boolean
	return table.find(CharacterData.Order, characterId) ~= nil
end

local function writableData(player: Player): { [string]: any }?
	local ds = ctx.DataService
	if ds.IsReady and not ds.IsReady(player) then
		return nil
	end
	return ds.GetData(player)
end

local function onSelectCharacter(player: Player, characterId: any)
	local data = writableData(player)
	if not data or type(characterId) ~= "string" or not CharacterData.Characters[characterId] or not listedHero(characterId) then
		return
	end
	if not data.OwnedCharacters[characterId] or not inLobby(player) then
		return
	end
	data.SelectedCharacter = characterId
	ctx.RunManager.RefreshLobbyCharacter(player)
	GoldSystem.SyncProfile(player)
end

local function onBuyCharacter(player: Player, characterId: any)
	local data = writableData(player)
	if not data or not inLobby(player) or type(characterId) ~= "string" then
		return
	end
	local def = CharacterData.Characters[characterId]
	if not def or data.OwnedCharacters[characterId] or not listedHero(characterId) then
		return
	end
	if def.Unlock then
		-- achievement characters are earned, never bought
		ctx.RunManager.Notify(player, def.Name .. " is unlocked by an achievement.", Color3.fromRGB(255, 220, 120))
		GoldSystem.SyncProfile(player)
		return
	end
	if data.Gold < def.Cost then
		ctx.RunManager.Notify(player, "Not enough gold.", Color3.fromRGB(255, 120, 120))
		return
	end
	data.Gold -= def.Cost
	data.OwnedCharacters[characterId] = true
	if inLobby(player) then
		data.SelectedCharacter = characterId
		ctx.RunManager.RefreshLobbyCharacter(player)
	end
	ctx.RunManager.Notify(player, def.Name .. " unlocked!", Color3.fromRGB(120, 255, 160))
	GoldSystem.SyncProfile(player)
end

-- expectedLevel (optional): the level the client saw when the player tapped BUY. A second
-- tap sent before the ProfileSync arrived carries the old level and is ignored, so a
-- double tap never buys two levels.
local function onBuyMeta(player: Player, upgradeId: any, expectedLevel: any)
	local data = writableData(player)
	-- only the account upgrades: the stat upgrades are bought per hero (onBuyHeroUpgrade)
	if not data or not inLobby(player) or not MetaUpgradeData.IsAccount(upgradeId) or not MetaUpgradeData.Upgrades[upgradeId] then
		return
	end
	local owned = data.Meta[upgradeId] or 0
	if type(expectedLevel) == "number" and expectedLevel ~= owned then
		GoldSystem.SyncProfile(player)
		return
	end
	local cost = MetaUpgradeData.CostOf(upgradeId, owned)
	if not cost then
		GoldSystem.SyncProfile(player)
		return
	end
	if data.Gold < cost then
		ctx.RunManager.Notify(player, "Not enough gold.", Color3.fromRGB(255, 120, 120))
		GoldSystem.SyncProfile(player) -- the client's gold was stale: show the real amount
		return
	end
	data.Gold -= cost
	data.Meta[upgradeId] = owned + 1
	-- no success toast: the upgrade row updates from the ProfileSync (TITLE handoff)
	GoldSystem.SyncProfile(player)
end

--[[
	Hero Mastery: one level of a hero's own upgrade (a stat id or "Signature"). Checked here:
	in the lobby, a known and owned hero, a known upgrade, the level the client saw (a
	double tap buys one level), the hero's mastery cap, the max level and the gold.
]]
local function onBuyHeroUpgrade(player: Player, heroId: any, upgradeId: any, expectedLevel: any)
	local data = writableData(player)
	if not data or not inLobby(player) or type(heroId) ~= "string" or type(upgradeId) ~= "string" then
		return
	end
	local hero = CharacterData.Characters[heroId]
	local def = hero and listedHero(heroId) and MetaUpgradeData.HeroDef(heroId, upgradeId)
	if not def or data.OwnedCharacters[heroId] ~= true then
		GoldSystem.SyncProfile(player)
		return
	end
	if type(data.HeroUpgrades) ~= "table" then
		data.HeroUpgrades = {}
	end
	local track = data.HeroUpgrades[heroId]
	local owned = type(track) == "table" and tonumber(track[upgradeId]) or 0
	owned = owned or 0
	if type(expectedLevel) ~= "number" or expectedLevel ~= owned then
		GoldSystem.SyncProfile(player)
		return
	end
	local heroes = type(data.Heroes) == "table" and data.Heroes or {}
	local mastery = MetaUpgradeData.MasteryFor(type(heroes[heroId]) == "table" and heroes[heroId].XP or 0)
	if owned + 1 > MetaUpgradeData.HeroCap(mastery, upgradeId, heroId) then
		ctx.RunManager.Notify(player, string.format("Needs %s Mastery %d.", hero.Name, MetaUpgradeData.RequiredMastery(upgradeId, owned + 1)), Color3.fromRGB(255, 220, 120))
		GoldSystem.SyncProfile(player)
		return
	end
	local cost = MetaUpgradeData.HeroCostOf(heroId, upgradeId, owned)
	if not cost then
		GoldSystem.SyncProfile(player)
		return
	end
	if data.Gold < cost then
		ctx.RunManager.Notify(player, "Not enough gold.", Color3.fromRGB(255, 120, 120))
		GoldSystem.SyncProfile(player)
		return
	end
	data.Gold -= cost
	if type(track) ~= "table" then
		track = {}
		data.HeroUpgrades[heroId] = track
	end
	track[upgradeId] = owned + 1
	-- no success toast: the hero's upgrade row updates from the ProfileSync
	GoldSystem.SyncProfile(player)
end
GoldSystem._BuyHeroUpgrade = onBuyHeroUpgrade -- (tests)

local function onEquipSkin(player: Player, characterId: any, skinId: any)
	local data = writableData(player)
	if not data or type(characterId) ~= "string" or type(skinId) ~= "string" then
		return
	end
	if not CharacterData.Characters[characterId] then
		return
	end
	if skinId ~= "Default" then
		local skin = CharacterData.Skins[skinId]
		if not skin or (skin.Character ~= characterId and skin.Character ~= "*") then
			return
		end
		if not ctx.MonetizationService.OwnsSkin(player, skinId) then
			return
		end
	end
	data.Skins[characterId] = skinId
	if data.SelectedCharacter == characterId and inLobby(player) then
		ctx.RunManager.RefreshLobbyCharacter(player)
	end
	GoldSystem.SyncProfile(player)
end

--[[
	Settings from the pause / settings menu (Config.Settings.Defaults lists every key).
	Any subset may be sent; each value is checked against its default's type: numbers are
	clamped to 0-1 (NaN ignored), booleans must be booleans, unknown keys are ignored.
]]
local function onSaveSettings(player: Player, settings: any)
	local data = writableData(player)
	if not data or type(settings) ~= "table" then
		return
	end
	for key in pairs(Config.Settings.Defaults) do
		local value = Config.ValidateSetting(key, settings[key])
		if value ~= nil then data.Settings[key] = value end
	end
	player:SetAttribute("DamageNumbers", data.Settings.DamageNumbers == true)
end

--[[
	First-run tips (client Tutorial.lua):
	  ("Seen", tipId)  a hint was shown: it never shows again (ids from Config.Tutorial.Tips)
	  ("Skip")         "Skip tips": the tutorial is done
	  ("Replay")       Settings > Replay tips: every hint shows again from the next run
	                   (SmartTutorial: TutorialStep back to 0, so two tutorial runs again)
	The flags only decide which hints a client shows; nothing else reads them.
]]
-- the SmartTutorial tour (client Tutorial.lua); all seen = the tutorial is done
local SMART_TIPS = { "Move", "Attack", "Gems", "LevelUp", "Chest", "Portal", "Boss" }

local function onTutorial(player: Player, action: any, tipId: any)
	local data = writableData(player)
	if not data or type(action) ~= "string" then
		return
	end
	if action == "Seen" then
		if type(tipId) == "string" and table.find(Config.Tutorial.Tips, tipId) then
			data.SeenTips[tipId] = true
			-- SmartTutorial: every one of the seven tips seen ends the tutorial early
			if (Config :: any).Features.SmartTutorial == true and data.TutorialDone ~= true then
				local all = true
				for _, id in ipairs(SMART_TIPS) do
					if data.SeenTips[id] ~= true then
						all = false
						break
					end
				end
				if all then
					data.TutorialDone = true
				end
			end
		end
		return -- no profile sync: the client already knows
	elseif action == "Skip" then
		data.TutorialDone = true
	elseif action == "Replay" then
		data.TutorialDone = false
		table.clear(data.SeenTips)
		data.TutorialStep = 0 -- SmartTutorial: the first Config.Tutorial.Smart.Runs runs again
		data.WalkthroughReplay = true -- the interactive walkthrough again on the next run (Walkthrough.lua)
		data.Settings.Tips = true
	else
		return
	end
	GoldSystem.SyncProfile(player)
end

function GoldSystem.Init(c)
	ctx = c
end

function GoldSystem.Start()
	-- [stream E2] team gold: throttled attribute flush; cleared back in the lobby
	game:GetService("RunService").Heartbeat:Connect(function()
		if team.Dirty and os.clock() - team.FlushedAt >= TEAM_FLUSH then
			publishTeam()
		end
	end)
	local state = Remotes.State()
	state:GetAttributeChangedSignal("Phase"):Connect(function()
		if state:GetAttribute("Phase") == "Lobby" and (team.Gold ~= 0 or team.Bought ~= 0) then
			GoldSystem.ResetTeamGold(nil)
		end
	end)
	publishTeam()
	Remotes.Listen("SelectCharacter", onSelectCharacter, 4)
	Remotes.Listen("BuyCharacter", onBuyCharacter, 2)
	Remotes.Listen("BuyMeta", onBuyMeta, 4)
	Remotes.Listen("BuyHeroUpgrade", onBuyHeroUpgrade, 4)
	Remotes.Listen("EquipSkin", onEquipSkin, 4)
	Remotes.Listen("SaveSettings", onSaveSettings, 4)
	Remotes.Listen("Tutorial", onTutorial, 6)
	Remotes.Listen("RequestProfile", function(player)
		GoldSystem.SyncProfile(player)
	end, 2)
	ctx.DataService.OnProfileLoaded(function(player)
		local data = ctx.DataService.GetData(player)
		-- a disconnected solo run waiting for its player (QuickResume) keeps its escrow too
		if data and not (ctx.RunServers and type(ctx.RunServers.HasPendingReconnect) == "function" and ctx.RunServers.HasPendingReconnect(data))
			and not (ctx.QuickResume and ctx.QuickResume.Pending(data))
			-- [stream E1] back on the match server inside their disconnect window: the run resumes it
			and not (ctx.RunManager and type(ctx.RunManager.HoldsReconnect) == "function" and ctx.RunManager.HoldsReconnect(player.UserId)) then
			GoldSystem.RecoverEscrow(data)
		end
		GoldSystem.SyncProfile(player)
	end)
end

return GoldSystem
