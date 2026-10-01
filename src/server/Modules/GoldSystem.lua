--[[
	GoldSystem.lua
	Run gold and the lobby economy (characters, skins, meta upgrades, settings).

	Gold earned in a run goes straight into the saved profile the moment it is earned,
	so it is never lost on death, disconnect or a server crash after the next autosave.
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

-- Adds gold (after gamepass multipliers) to the run counter and the save. Returns amount.
function GoldSystem.AddRunGold(rp, base: number): number
	local player: Player = rp.Player
	local data = ctx.DataService.GetData(player)
	if not data or base <= 0 then
		return 0
	end
	local amount = math.floor(base * ctx.MonetizationService.GoldMultiplier(player) + 0.5)
	data.Gold += amount
	rp.Gold += amount
	player:SetAttribute("RunGold", rp.Gold)
	return amount
end

-- Normal kill: 1-3 gold with Config.Gold.KillGoldChance.
function GoldSystem.OnKill(rp)
	if rng:NextNumber() < Config.Gold.KillGoldChance then
		GoldSystem.AddRunGold(rp, rng:NextInteger(Config.Gold.MinPerKill, Config.Gold.MaxPerKill))
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
		ReviveTokens = data.ReviveTokens,
		OwnedSkins = M.OwnedSkins(player),
		Passes = {
			StarterPack = M.OwnsPass(player, "StarterPack"),
			VIP = M.OwnsPass(player, "VIP"),
			DoubleGold = M.OwnsPass(player, "DoubleGold"),
		},
		MemoryOnly = ctx.DataService.IsMemoryOnly(),
	})
	player:SetAttribute("Gold", data.Gold)
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

local function onBuyMeta(player: Player, upgradeId: any)
	local data = ctx.DataService.GetData(player)
	if not data or type(upgradeId) ~= "string" or not MetaUpgradeData.Upgrades[upgradeId] then
		return
	end
	local owned = data.Meta[upgradeId] or 0
	local cost = MetaUpgradeData.CostOf(upgradeId, owned)
	if not cost then
		return
	end
	if data.Gold < cost then
		ctx.RunManager.Notify(player, "Not enough gold.", Color3.fromRGB(255, 120, 120))
		return
	end
	data.Gold -= cost
	data.Meta[upgradeId] = owned + 1
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

local function onSaveSettings(player: Player, settings: any)
	local data = ctx.DataService.GetData(player)
	if not data or type(settings) ~= "table" then
		return
	end
	local music, sfx = tonumber(settings.Music), tonumber(settings.Sfx)
	if music and music == music then
		data.Settings.Music = math.clamp(music, 0, 1)
	end
	if sfx and sfx == sfx then
		data.Settings.Sfx = math.clamp(sfx, 0, 1)
	end
end

function GoldSystem.Init(c)
	ctx = c
end

function GoldSystem.Start()
	Remotes.Listen("SelectCharacter", onSelectCharacter, 4)
	Remotes.Listen("BuyCharacter", onBuyCharacter, 2)
	Remotes.Listen("BuyMeta", onBuyMeta, 4)
	Remotes.Listen("EquipSkin", onEquipSkin, 4)
	Remotes.Listen("SaveSettings", onSaveSettings, 2)
	Remotes.Listen("RequestProfile", function(player)
		GoldSystem.SyncProfile(player)
	end, 2)
	ctx.DataService.OnProfileLoaded(function(player)
		GoldSystem.SyncProfile(player)
	end)
end

return GoldSystem
