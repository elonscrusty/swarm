--[[
	DevTools.lua
	The dev panel's commands (client DevPanel.lua → RunManager "DevCommand"). RunManager
	checks isDev (Studio, or the creator with Config.Dev.ShowInLiveGame) before anything
	here runs; every argument is re-validated here as if it came from anyone.

	Profile (lobby; saved like normal progress, it is a test account):
	  UnlockAll        +1,000,000 gold, every character, every achievement + its rewards,
	                   every arena (best stage), account level 50 (its rings, frames, titles)
	                   and, in Studio only, every skin for this session (skins are Robux
	                   items: never saved, never granted in live servers)
	  ResetProgress    a fresh save of the developer's own profile (purchases and settings kept); lobby only
	  LobbyGold n      + n gold to the save (n = 1..1,000,000)
	  AccountLevels n  + n account levels (1..50)
	  DamageNumbers    toggles the damage numbers setting
	Run (your own run player):
	  AddLevels n, AddGold n (run wallet), God (toggle; player attribute DevGod, read by
	  RunManager.DamagePlayer), SpawnBoss id (the portal summons that boss now),
	  BossRotation (back to the normal boss order), SpawnEnemy type / SpawnElite type,
	  GiveItem id, GiveItems (3 random), GiveWeapon id (max level), MaxWeapons (every
	  weapon at max level), NewWeapons, EvolveWeapons, SpawnPortalBoss, TeleportToPortal,
	  NextStage
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage.Shared
local Config = require(Shared.Config)
local CharacterData = require(Shared.CharacterData)
local AccountData = require(Shared.AccountData)
local BossData = require(Shared.BossData)
local EnemyData = require(Shared.EnemyData)
local ItemData = require(Shared.ItemData)
local WeaponData = require(Shared.WeaponData)

local DevTools = {}

local DEV_COLOR = Color3.fromRGB(255, 160, 255)

-- Enemy types the panel may spawn (no boss bodies or boss objects).
DevTools.Enemies = { "Slime", "Bat", "Skeleton", "Ghost", "Brute", "Bomber", "Spitter", "Burrower", "Healer", "Nest" }

local function count(arg: any, lo: number, hi: number, default: number): number
	local n = tonumber(arg) or default
	if n ~= n then
		n = default
	end
	return math.clamp(math.floor(n), lo, hi)
end

local function isId(arg: any, set: { [string]: any }): boolean
	return type(arg) == "string" and #arg <= 64 and set[arg] ~= nil
end

-- What a dev command does: "lobby" (profile), "run" (needs your live run player) or nil.
local KIND = {
	UnlockAll = "lobby",
	ResetProgress = "lobby",
	LobbyGold = "lobby",
	AccountLevels = "lobby",
	DamageNumbers = "any",
	God = "any",
	AddLevels = "run",
	AddGold = "run",
	SpawnBoss = "run",
	BossRotation = "any",
	SpawnEnemy = "run",
	SpawnElite = "run",
	GiveItem = "run",
	GiveItems = "run",
	GiveWeapon = "run",
	MaxWeapons = "run",
	NewWeapons = "run",
	EvolveWeapons = "run",
	SpawnPortalBoss = "run",
	SkipToBoss = "run", -- old clients
	TeleportToPortal = "run",
	NextStage = "run",
}

-- Lobby commands that boost the profile (set data.DevBoosted). ResetProgress is not one:
-- it starts a fresh default profile.
local BOOSTS = { UnlockAll = true, LobbyGold = true, AccountLevels = true }
DevTools.Boosts = BOOSTS

function DevTools.Knows(command: string): boolean
	return KIND[command] ~= nil
end

local function syncLobby(ctx, player: Player)
	ctx.GoldSystem.SyncProfile(player)
	ctx.RunManager.RefreshLobbyCharacter(player)
end

local function unlockAll(ctx, player: Player, data)
	data.Gold += 1000000
	for id in pairs(CharacterData.Characters) do
		data.OwnedCharacters[id] = true
	end
	ctx.AchievementService.DevUnlockAll(player)
	local best = data.Stats.BestStage or 0
	for _, name in ipairs(Config.Arenas.Order) do
		best = math.max(best, (Config.Arenas :: any)[name].RequiredBestStage or 0)
	end
	data.Stats.BestStage = best
	data.Account = { XP = math.max(data.Account and data.Account.XP or 0, AccountData.TotalFor(AccountData.MaxLevel)), Level = AccountData.MaxLevel }
	ctx.MonetizationService.DevGrantSkins(player, true)
	syncLobby(ctx, player)
	local skins = game:GetService("RunService"):IsStudio() and " + every skin (this Studio session)" or ""
	ctx.RunManager.Notify(player, "DEV: everything unlocked" .. skins, DEV_COLOR)
end

local function resetProgress(ctx, player: Player, data)
	local keep = { PurchaseIds = data.PurchaseIds, Settings = data.Settings }
	local fresh = ctx.DataService.DefaultData()
	for k in pairs(data) do
		data[k] = nil
	end
	for k, v in pairs(fresh) do
		data[k] = v
	end
	data.PurchaseIds = keep.PurchaseIds or data.PurchaseIds
	data.Settings = keep.Settings or data.Settings
	ctx.MonetizationService.DevGrantSkins(player, false)
	player:SetAttribute("DevGod", nil)
	syncLobby(ctx, player)
	ctx.RunManager.Notify(player, "DEV: progress reset", DEV_COLOR)
end

--[[
	Runs one dev command for `player` (already checked by RunManager.isDev). inLobby: not
	in a run; rp: the player's run entry (nil in the lobby).
]]
function DevTools.Handle(ctx, player: Player, command: string, arg: any, inLobby: boolean, rp: any, running: boolean)
	local kind = KIND[command]
	if not kind then
		return
	end
	local data = ctx.DataService.GetData(player)
	if not data then
		return
	end
	if kind == "lobby" and not inLobby then
		ctx.RunManager.Notify(player, "DEV: lobby only", DEV_COLOR)
		return
	end
	local live = rp ~= nil and not rp.Returned and running
	if kind == "run" and not live then
		ctx.RunManager.Notify(player, "DEV: start a run first", DEV_COLOR)
		return
	end

	-- profile-boosting lobby commands mark the save: every later run by this player is
	-- dev-tainted (RunManager), so boosted gold / heroes / levels never reach boards or
	-- records (owner OK 2026-10-05, audit SEC-13)
	if BOOSTS[command] then
		data.DevBoosted = true
	end

	if command == "UnlockAll" then
		unlockAll(ctx, player, data)
	elseif command == "ResetProgress" then
		-- wipes only the developer's own save (tap twice on the client to confirm)
		if arg ~= "CONFIRM" then
			return
		end
		resetProgress(ctx, player, data)
	elseif command == "LobbyGold" then
		data.Gold += count(arg, 1, 1000000, 1000)
		ctx.GoldSystem.SyncProfile(player)
	elseif command == "AccountLevels" then
		local acc = data.Account or { XP = 0, Level = 1 }
		local level = math.min(AccountData.MaxLevel, AccountData.LevelFor(acc.XP or 0) + count(arg, 1, AccountData.MaxLevel, 5))
		data.Account = { XP = math.max(acc.XP or 0, AccountData.TotalFor(level)), Level = level }
		ctx.GoldSystem.SyncProfile(player)
	elseif command == "DamageNumbers" then
		data.Settings.DamageNumbers = not (data.Settings.DamageNumbers == true)
		player:SetAttribute("DamageNumbers", data.Settings.DamageNumbers)
		if inLobby then
			ctx.GoldSystem.SyncProfile(player)
		end
		ctx.RunManager.Notify(player, "DEV: damage numbers " .. (data.Settings.DamageNumbers and "on" or "off"), DEV_COLOR)
	elseif command == "God" then
		local on = player:GetAttribute("DevGod") ~= true
		player:SetAttribute("DevGod", on or nil)
		ctx.RunManager.Notify(player, "DEV: invincible " .. (on and "ON (this run is a test run: no records)" or "OFF"), DEV_COLOR)
	elseif command == "AddLevels" then
		if rp.Alive then
			for _ = 1, count(arg, 1, 50, Config.Dev.AddLevels) do
				ctx.XPSystem.GiveXP(rp, math.max(0, rp.XPNeeded - rp.XP))
			end
		end
	elseif command == "AddGold" then
		ctx.GoldSystem.AddRunGold(rp, count(arg, 1, 100000, 300))
	elseif command == "SpawnBoss" then
		if not isId(arg, BossData.Bosses) then
			return
		end
		ctx.StageManager.ForceBoss(arg)
		if ctx.StageManager.DevActivate() then
			ctx.RunManager.Broadcast("DEV: " .. BossData.Bosses[arg].DisplayName .. " summoned", DEV_COLOR, nil, { Id = "dev" })
		else
			ctx.RunManager.Notify(player, "DEV: the next portal summons " .. BossData.Bosses[arg].DisplayName .. " (the portal is busy now)", DEV_COLOR)
		end
	elseif command == "BossRotation" then
		ctx.StageManager.ForceBoss(nil)
		ctx.RunManager.Notify(player, "DEV: normal boss rotation", DEV_COLOR)
	elseif command == "SpawnEnemy" or command == "SpawnElite" then
		if type(arg) ~= "string" or not table.find(DevTools.Enemies, arg) or not EnemyData.Enemies[arg] then
			return
		end
		local elite = command == "SpawnElite"
		local n = elite and 1 or 5
		local spawned = 0
		for _ = 1, n do
			local pos = ctx.EnemySpawner.SpawnPoint(EnemyData.Enemies[arg].Radius or 2)
			if pos and ctx.EnemySpawner.Spawn(arg, pos, { Elite = elite, Force = true }) then
				spawned += 1
			end
		end
		ctx.RunManager.Notify(player, string.format("DEV: %d %s%s", spawned, elite and "elite " or "", EnemyData.Enemies[arg].DisplayName or arg), DEV_COLOR)
	elseif command == "GiveItem" then
		if isId(arg, ItemData.Items) then
			ctx.ItemSystem.Grant(rp, arg, "Dev")
		end
	elseif command == "GiveItems" then
		ctx.ItemSystem.DevGive(rp, 3)
	elseif command == "GiveWeapon" then
		if isId(arg, WeaponData.Weapons) and rp.Alive then
			ctx.LevelUpSystem.DevWeapons(rp, false, { arg })
		end
	elseif command == "MaxWeapons" or command == "NewWeapons" or command == "EvolveWeapons" then
		if rp.Alive then
			ctx.LevelUpSystem.DevWeapons(rp, command == "EvolveWeapons", command == "MaxWeapons" and WeaponData.Order or nil)
		end
	elseif command == "SpawnPortalBoss" or command == "SkipToBoss" then
		if ctx.StageManager.DevActivate() then
			ctx.RunManager.Broadcast("DEV: portal boss summoned", DEV_COLOR, nil, { Id = "dev" })
		end
	elseif command == "TeleportToPortal" then
		ctx.StageManager.DevTeleport(rp)
	elseif command == "NextStage" then
		if ctx.StageManager.DevNextStage() then
			ctx.RunManager.Broadcast("DEV: on to the next stage", DEV_COLOR, nil, { Id = "dev" })
		end
	end
end

return DevTools
