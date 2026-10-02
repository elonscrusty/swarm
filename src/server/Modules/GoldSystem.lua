--[[
	GoldSystem.lua
	Run gold and the lobby economy (characters, skins, meta upgrades, settings).

	Gold earned in a run goes straight into the saved profile the moment it is earned,
	so it is never lost on death, disconnect or a server crash after the next autosave.
	rp.Gold (player attribute RunGold, the HUD coin counter) is the gold this run has
	banked so far. Chests and shrines (LootSystem) spend from it with SpendRunGold, which
	takes the same amount back out of the save: a run can only spend what it earned,
	savings from earlier runs are never touched, and results show the gold taken home.
	All prices are read from the shared data modules on the server; the client only
	sends ids, never amounts.
]]

local Config = require(game:GetService("ReplicatedStorage").Shared.Config)
local Remotes = require(game:GetService("ReplicatedStorage").Shared.Remotes)
local CharacterData = require(game:GetService("ReplicatedStorage").Shared.CharacterData)
local MetaUpgradeData = require(game:GetService("ReplicatedStorage").Shared.MetaUpgradeData)

local GoldSystem = {}

local ctx
local rng = Random.new()

------------------------------------------------------------------------------------------
-- Run gold
------------------------------------------------------------------------------------------

-- Adds gold (after gamepass multipliers and the run's curse bonus, CurseData) to the run
-- counter and the save. Returns amount.
function GoldSystem.AddRunGold(rp, base: number): number
	local player: Player = rp.Player
	local data = ctx.DataService.GetData(player)
	if not data or base <= 0 then
		return 0
	end
	local curse = ctx.RunModifiers and ctx.RunModifiers.GoldMult() or 1
	local amount = math.floor(base * ctx.MonetizationService.GoldMultiplier(player) * curse + 0.5)
	data.Gold += amount
	rp.Gold += amount
	player:SetAttribute("RunGold", rp.Gold)
	return amount
end

-- Gold this run can still spend at chests / shrines: what it banked, never more than the
-- save holds (the save always holds at least that much: nothing else spends in a run).
function GoldSystem.RunWallet(rp): number
	local data = ctx.DataService.GetData(rp.Player)
	if not data then
		return 0
	end
	return math.max(0, math.min(rp.Gold, data.Gold))
end

-- Spends run gold (chests, shrines). False (and nothing spent) when the run can't afford
-- it. Keeps the save and the run counter in step; the save is written by the autosave.
function GoldSystem.SpendRunGold(rp, amount: number): boolean
	amount = math.floor(amount)
	if amount <= 0 then
		return true
	end
	local data = ctx.DataService.GetData(rp.Player)
	if not data or GoldSystem.RunWallet(rp) < amount then
		return false
	end
	data.Gold -= amount
	rp.Gold -= amount
	rp.GoldSpent = (rp.GoldSpent or 0) + amount
	rp.Player:SetAttribute("RunGold", rp.Gold)
	return true
end

-- Normal kill: 1-3 gold with Config.Gold.KillGoldChance (x the run's GoldMult: items, the
-- Bargain Shrine).
function GoldSystem.OnKill(rp)
	if rng:NextNumber() < Config.Gold.KillGoldChance then
		GoldSystem.AddRunGold(rp, rng:NextInteger(Config.Gold.MinPerKill, Config.Gold.MaxPerKill) * (rp.Stats and rp.Stats.GoldMult or 1))
	end
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
		Meta = data.Meta,
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
	if not data or type(characterId) ~= "string" then
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
	if not data or type(upgradeId) ~= "string" or not MetaUpgradeData.Upgrades[upgradeId] then
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
	for key, default in pairs(Config.Settings.Defaults) do
		local value = settings[key]
		if type(default) == "number" then
			local n = tonumber(value)
			if n and n == n then
				data.Settings[key] = math.clamp(n, 0, 1)
			end
		elseif type(default) == "boolean" and type(value) == "boolean" then
			data.Settings[key] = value
		end
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
	Remotes.Listen("EquipSkin", onEquipSkin, 4)
	Remotes.Listen("SaveSettings", onSaveSettings, 4)
	Remotes.Listen("Tutorial", onTutorial, 6)
	Remotes.Listen("RequestProfile", function(player)
		GoldSystem.SyncProfile(player)
	end, 2)
	ctx.DataService.OnProfileLoaded(function(player)
		GoldSystem.SyncProfile(player)
	end)
end

return GoldSystem
