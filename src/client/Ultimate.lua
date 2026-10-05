--[[
	Ultimate.lua (client)
	Feature 13, the hero ultimate (Config.Features.Ultimate; docs/features/HEROPOWER.md).

	Shows the FeatureHud ultimate slot (round ULT button above JUMP, keys Q / ButtonR1)
	from the server's player attributes: UltCharge (0..1), UltHero (whose ultimate) and
	UltUsed (a counter: each new value announces the move's name). Pressing it only asks
	the server (UseUltimate); the server checks the charge, life and the run itself.
	Also starts HeroPresets (feature 14), which keeps the favourites for the level-up tag.
]]

local Players = game:GetService("Players")
local Shared = game:GetService("ReplicatedStorage"):WaitForChild("Shared")
local Config = require(Shared:WaitForChild("Config"))
local Remotes = require(Shared:WaitForChild("Remotes"))
local CharacterData = require(Shared:WaitForChild("CharacterData"))
local FeatureHud = require(script.Parent.FeatureHud)
local HeroPresets = require(script.Parent.HeroPresets)

local Ultimate = {}

local player = Players.LocalPlayer
local lastUsed: number? = nil
local started = false

local function fire()
	Remotes.Get("UseUltimate"):FireServer()
end

local function refresh()
	local charge = player:GetAttribute("UltCharge")
	if not Config.FeatureOn("Ultimate") or type(charge) ~= "number" then
		FeatureHud.SetUltimate(nil)
		return
	end
	FeatureHud.SetUltimate({ OnActivate = fire, Charge = math.clamp(charge, 0, 1), Label = "ULT" })
end

local function onUsed()
	local n = player:GetAttribute("UltUsed")
	if type(n) ~= "number" then
		lastUsed = nil
		return
	end
	if lastUsed ~= nil and n > lastUsed then
		local def = CharacterData.UltimateFor(player:GetAttribute("UltHero"))
		FeatureHud.Announce(string.upper(def.Name) .. "!", { Color = def.Color, Seconds = 1.6 })
	end
	lastUsed = n
end

function Ultimate.Init()
	if started then
		return
	end
	started = true
	HeroPresets.Init()
	player:GetAttributeChangedSignal("UltCharge"):Connect(refresh)
	player:GetAttributeChangedSignal("UltUsed"):Connect(onUsed)
	lastUsed = player:GetAttribute("UltUsed")
	refresh()
end

return Ultimate
