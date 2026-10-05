--[[
	BuildPresets.lua (server)
	Feature 14, build presets (Config.Features.BuildPresets; docs/features/HEROPOWER.md).

	A player marks favourite weapons / passives per hero on the Characters screen. They are
	kept in the save field Presets (DataService, FOUNDATION): one List entry per hero
	{ Hero, Weapons {id}, Passives {id} } and Active[heroId] = its index. The level-up
	cards of a favourite get a small tag on the client; offers and weights never change,
	so nothing here touches a run.

	SetPreset(heroId, kind, id, on): kind "Weapons" | "Passives"; the hero must exist and
	the id must be a released weapon / passive (WeaponData / PassiveData). Caps:
	Config.Data.Caps.Presets lists, Caps.PresetPicks ids per list. Lobby or run, any time.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Config = require(ReplicatedStorage.Shared.Config)
local Remotes = require(ReplicatedStorage.Shared.Remotes)
local CharacterData = require(ReplicatedStorage.Shared.CharacterData)
local WeaponData = require(ReplicatedStorage.Shared.WeaponData)
local PassiveData = require(ReplicatedStorage.Shared.PassiveData)

local BuildPresets = {}

local ctx

local function validId(kind: string, id: any): boolean
	if type(id) ~= "string" then
		return false
	end
	if kind == "Weapons" then
		return WeaponData.Weapons[id] ~= nil
	elseif kind == "Passives" then
		return PassiveData.Passives[id] ~= nil
	end
	return false
end

-- The preset list entry of `heroId` (created when `create` and there is room), or nil.
function BuildPresets.Entry(data: { [string]: any }, heroId: string, create: boolean?): { [string]: any }?
	local presets = data.Presets
	if type(presets) ~= "table" then
		return nil
	end
	presets.List = type(presets.List) == "table" and presets.List or {}
	presets.Active = type(presets.Active) == "table" and presets.Active or {}
	local index = tonumber(presets.Active[heroId])
	local entry = index and presets.List[index]
	if type(entry) == "table" and entry.Hero == heroId then
		return entry
	end
	for i, p in ipairs(presets.List) do
		if type(p) == "table" and p.Hero == heroId then
			presets.Active[heroId] = i
			return p
		end
	end
	if not create or #presets.List >= Config.Data.Caps.Presets then
		return nil
	end
	local fresh = { Hero = heroId, Weapons = {}, Passives = {} }
	table.insert(presets.List, fresh)
	presets.Active[heroId] = #presets.List
	return fresh
end

--[[
	Marks / unmarks one favourite. Returns true when the save changed.
]]
function BuildPresets.Set(player: Player, heroId: any, kind: any, id: any, onFlag: any): boolean
	if not Config.FeatureOn("BuildPresets") then
		return false
	end
	local data = ctx.DataService.GetData(player)
	if not data or type(heroId) ~= "string" or not CharacterData.Characters[heroId] then
		return false
	end
	if (kind ~= "Weapons" and kind ~= "Passives") or not validId(kind, id) or type(onFlag) ~= "boolean" then
		return false
	end
	local entry = BuildPresets.Entry(data, heroId, onFlag)
	if not entry then
		return false
	end
	local list = type(entry[kind]) == "table" and entry[kind] or {}
	entry[kind] = list
	local at = table.find(list, id)
	if onFlag and not at then
		if #list >= Config.Data.Caps.PresetPicks then
			ctx.RunManager.Notify(player, string.format("Up to %d favourites of each kind.", Config.Data.Caps.PresetPicks), Color3.fromRGB(255, 220, 120))
			return false
		end
		table.insert(list, id)
	elseif not onFlag and at then
		table.remove(list, at)
	else
		return false
	end
	ctx.GoldSystem.SyncProfile(player)
	return true
end

function BuildPresets.Init(c)
	ctx = c
end

function BuildPresets.Start()
	Remotes.Listen("SetPreset", function(player: Player, heroId, kind, id, onFlag)
		BuildPresets.Set(player, heroId, kind, id, onFlag)
	end, Config.BuildPresets.Rate)
end

return BuildPresets
