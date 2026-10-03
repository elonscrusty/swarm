--[[
	GoldSystem.lua
	Run gold and the lobby economy (characters, skins, meta upgrades, settings).

	Run earnings are saved separately in RunEscrow until extraction or defeat. Chests
	spend only this ledger. Settlement retains all earnings on extraction, or a stage-based
	share on defeat. Existing savings and purchased coins never enter the at-risk ledger.
	All prices are read from the shared data modules on the server; the client only
	sends ids, never amounts.
]]

local Config = require(game:GetService("ReplicatedStorage").Shared.Config)
local Remotes = require(game:GetService("ReplicatedStorage").Shared.Remotes)
local CharacterData = require(game:GetService("ReplicatedStorage").Shared.CharacterData)
local MetaUpgradeData = require(game:GetService("ReplicatedStorage").Shared.MetaUpgradeData)

local Fx = require(script.Parent.Fx)

local GoldSystem = {}

local ctx
local rng = Random.new()

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

function GoldSystem.SettleRun(rp, extracted: boolean, cleared: number)
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
	rp.GoldSettlement = { Earned = earned, Retained = kept, Lost = earned - kept, Rate = rate }
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
	return amount
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
	if rng:NextNumber() < Config.Gold.KillGoldChance * (chanceMult or 1) then
		local paid = GoldSystem.AddRunGold(rp, rng:NextInteger(Config.Gold.MinPerKill, Config.Gold.MaxPerKill) * (rp.Stats and rp.Stats.GoldMult or 1))
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
		MemoryOnly = ctx.DataService.IsMemoryOnly(),
	})
	player:SetAttribute("Gold", data.Gold)
	-- the server sends damage numbers only to players who switched them on
	player:SetAttribute("DamageNumbers", data.Settings.DamageNumbers == true)
end

local function inLobby(player: Player): boolean
	return not ctx.RunManager.IsParticipant(player)
end

local function onSelectCharacter(player: Player, characterId: any)
	local data = ctx.DataService.GetData(player)
	if not data or type(characterId) ~= "string" or not CharacterData.Characters[characterId] then
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
	local data = ctx.DataService.GetData(player)
	if not data or not inLobby(player) or type(characterId) ~= "string" then
		return
	end
	local def = CharacterData.Characters[characterId]
	if not def or data.OwnedCharacters[characterId] then
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
	local data = ctx.DataService.GetData(player)
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
	local def = MetaUpgradeData.Upgrades[upgradeId]
	ctx.RunManager.Notify(player, string.format("%s upgraded to level %d!", def.Name, owned + 1), Color3.fromRGB(120, 255, 160))
	GoldSystem.SyncProfile(player)
end

--[[
	Hero Mastery: one level of a hero's own upgrade (a stat id or "Signature"). Checked here:
	in the lobby, a known and owned hero, a known upgrade, the level the client saw (a
	double tap buys one level), the hero's mastery cap, the max level and the gold.
]]
local function onBuyHeroUpgrade(player: Player, heroId: any, upgradeId: any, expectedLevel: any)
	local data = ctx.DataService.GetData(player)
	if not data or not inLobby(player) or type(heroId) ~= "string" or type(upgradeId) ~= "string" then
		return
	end
	local hero = CharacterData.Characters[heroId]
	local def = hero and MetaUpgradeData.HeroDef(heroId, upgradeId)
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
	ctx.RunManager.Notify(player, string.format("%s %s upgraded to level %d!", hero.Name, def.Name, owned + 1), Color3.fromRGB(120, 255, 160))
	GoldSystem.SyncProfile(player)
end
GoldSystem._BuyHeroUpgrade = onBuyHeroUpgrade -- (tests)

local function onEquipSkin(player: Player, characterId: any, skinId: any)
	local data = ctx.DataService.GetData(player)
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
	local data = ctx.DataService.GetData(player)
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
	The flags only decide which hints a client shows; nothing else reads them.
]]
local function onTutorial(player: Player, action: any, tipId: any)
	local data = ctx.DataService.GetData(player)
	if not data or type(action) ~= "string" then
		return
	end
	if action == "Seen" then
		if type(tipId) == "string" and table.find(Config.Tutorial.Tips, tipId) then
			data.SeenTips[tipId] = true
		end
		return -- no profile sync: the client already knows
	elseif action == "Skip" then
		data.TutorialDone = true
	elseif action == "Replay" then
		data.TutorialDone = false
		table.clear(data.SeenTips)
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
		if data and not (ctx.RunServers and type(ctx.RunServers.HasPendingReconnect) == "function" and ctx.RunServers.HasPendingReconnect(data)) then
			GoldSystem.RecoverEscrow(data)
		end
		GoldSystem.SyncProfile(player)
	end)
end

return GoldSystem
