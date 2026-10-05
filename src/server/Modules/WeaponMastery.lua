--[[
	WeaponMastery.lua (server; feature 15, Config.Features.WeaponMastery, docs/features/LOBBY.md)
	Counts every weapon's kills into the save and lets the player pick an earned glow colour
	per weapon. Purely cosmetic: nothing here touches damage, drops or a run's power.

	  Kills    WeaponSystem.OnKill reports (rp, weapon, enemy) for each weapon kill; the count
	           goes straight into data.WeaponMastery[weaponId] (saved with the profile like any
	           other field). Never on a DEV-tainted run (RunManager rp.DevTainted). A count stops
	           at Config.WeaponMastery.MaxCount; a new weapon id is only added while the field
	           holds fewer than Config.Data.Caps.WeaponMastery keys.
	  Glow     data.WeaponMastery["Glow:<weaponId>"] = milestone number (1..#Milestones) that
	           weapon wears; absent = its own colour. Set by the SetMasteryGlow remote, which
	           checks the weapon's kills reach that milestone.
	  Notice   crossing a milestone in a run sends a quiet notice ("Sword: Bronze Glow unlocked").

	WeaponMastery.Count(data, weaponId), .Earned(data, weaponId, index), .SetGlow(player,
	weaponId, index) → ok, why (also used by the regression scene).
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared:WaitForChild("Config"))
local Remotes = require(Shared:WaitForChild("Remotes"))
local WeaponData = require(Shared:WaitForChild("WeaponData"))

local WeaponMastery = {}

local ctx: any = nil
local M = Config.WeaponMastery
local GLOW = "Glow:"

local function keyCount(t: { [string]: any }): number
	local n = 0
	for _ in pairs(t) do
		n += 1
	end
	return n
end

-- Kills recorded for a weapon (0 when none / not a number).
function WeaponMastery.Count(data: any, weaponId: string): number
	local t = type(data) == "table" and data.WeaponMastery
	local v = type(t) == "table" and t[weaponId]
	return type(v) == "number" and v or 0
end

-- True when that weapon's kills reach milestone `index` (0 = its own colour, always true).
function WeaponMastery.Earned(data: any, weaponId: string, index: number): boolean
	if index == 0 then
		return true
	end
	local m = M.Milestones[index]
	return m ~= nil and WeaponMastery.Count(data, weaponId) >= m.Kills
end

-- Adds one kill for weapon `weaponId` to a save; returns the milestone crossed (or nil).
function WeaponMastery.AddKill(data: any, weaponId: string): number?
	local t = data.WeaponMastery
	if type(t) ~= "table" then
		return nil
	end
	local before = t[weaponId]
	if type(before) ~= "number" then
		if keyCount(t) >= Config.Data.Caps.WeaponMastery then
			return nil
		end
		before = 0
	end
	local after = math.min(before + 1, M.MaxCount)
	t[weaponId] = after
	for i, m in ipairs(M.Milestones) do
		if before < m.Kills and after >= m.Kills then
			return i
		end
	end
	return nil
end

-- The glow a player picks for a weapon: index 0 = its own colour.
function WeaponMastery.SetGlow(player: Player, weaponId: any, index: any): (boolean, string?)
	if not Config.FeatureOn("WeaponMastery") then
		return false, "off"
	end
	if type(weaponId) ~= "string" or not WeaponData.Weapons[weaponId] then
		return false, "weapon"
	end
	if type(index) ~= "number" or index ~= index or index % 1 ~= 0 or index < 0 or index > #M.Milestones then
		return false, "index"
	end
	local data = ctx.DataService.GetData(player)
	if not data or type(data.WeaponMastery) ~= "table" then
		return false, "nodata"
	end
	if not WeaponMastery.Earned(data, weaponId, index) then
		return false, "locked"
	end
	local key = GLOW .. weaponId
	if index == 0 then
		data.WeaponMastery[key] = nil
	elseif data.WeaponMastery[key] == nil and keyCount(data.WeaponMastery) >= Config.Data.Caps.WeaponMastery then
		return false, "full"
	else
		data.WeaponMastery[key] = index
	end
	return true, nil
end

local function onKill(rp, w, _enemy)
	if not Config.FeatureOn("WeaponMastery") or rp.DevTainted or type(w) ~= "table" or type(w.Id) ~= "string" then
		return
	end
	local player: Player? = rp.Player
	local data = player and ctx.DataService.GetData(player)
	if not data then
		return
	end
	local crossed = WeaponMastery.AddKill(data, w.Id)
	if crossed and player then
		local m = M.Milestones[crossed]
		local def = WeaponData.Weapons[w.Id]
		ctx.RunManager.Notify(player, string.format("%s: %s unlocked", def and def.Name or w.Id, m.Name), m.Color, { Id = "mastery:" .. w.Id, Lane = "Notice", Class = "Info" })
	end
end

function WeaponMastery.Init(c)
	ctx = c
	ctx.WeaponSystem.OnKill(onKill)
end

function WeaponMastery.Start()
	Remotes.Listen("SetMasteryGlow", function(player, weaponId, index)
		WeaponMastery.SetGlow(player, weaponId, index)
		-- the answer is a fresh profile either way (the menu waits for it)
		ctx.GoldSystem.SyncProfile(player)
	end, M.EquipRate)
end

return WeaponMastery
