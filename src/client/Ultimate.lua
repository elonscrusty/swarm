--[[
	Ultimate.lua (client)
	Feature 13, the hero ultimate (Config.Features.Ultimate; docs/features/HEROPOWER.md).

	Shows the FeatureHud ultimate slot (round ULT button above JUMP, keys Q / ButtonR1)
	from the server's player attributes: UltCharge (0..1), UltHero (whose ultimate) and
	UltUsed (a counter: each new value announces the move's name). Pressing it only asks
	the server (UseUltimate); the server checks the charge, life and the run itself.
	Also starts HeroPresets (feature 14), which keeps the favourites for the level-up tag.

	The button shows the move's icon (ICONS below: an evolution picture that matches the
	move's look, "sparkle" otherwise) and the charge in percent. The first time it is ready
	(once per session; the save has no per-tip field for it outside Config.Tutorial.Tips)
	a short callout names the move: "VALOR QUAKE: Slams the ground. Tap ULT!" for 5 s,
	unless Settings > Tips is off.
]]

local Players = game:GetService("Players")
local Shared = game:GetService("ReplicatedStorage"):WaitForChild("Shared")
local Config = require(Shared:WaitForChild("Config"))
local Remotes = require(Shared:WaitForChild("Remotes"))
local CharacterData = require(Shared:WaitForChild("CharacterData"))
local FeatureHud = require(script.Parent.FeatureHud)
local ClientSettings = require(script.Parent.ClientSettings)
local HeroPresets = require(script.Parent.HeroPresets)

local Ultimate = {}

local player = Players.LocalPlayer
local lastUsed: number? = nil
local started = false
local explained = false -- the first-ready callout was shown this session

-- Ultimate look (CharacterData.Ultimates[].Look) -> icon drawn on the button.
local ICONS: { [string]: string } = {
	Quake = "Earthsplitter",
	Stars = "Cataclysm",
	Blades = "ThousandEdge",
	Nova = "WispChoir",
	Arrows = "Windpiercer",
	Fire = "Hellfire",
	Sparks = "ThunderLoop",
	Souls = "SoulEater",
}

-- The first sentence of a move's text, cut at a colon ("Slams the ground: ..." -> "Slams
-- the ground."): one short line for the callout.
local function shortText(text: string): string
	local first = string.match(text, "^([^:%.]+)") or text
	return first .. "."
end

local function explain(def: any)
	if explained then
		return
	end
	explained = true
	if ClientSettings.Get("Tips") == false then
		return
	end
	FeatureHud.UltimateCallout(string.format("%s: %s %s!", string.upper(def.Name), shortText(def.Text or ""), FeatureHud.UltimateHow()), 5)
end

local function fire()
	Remotes.Get("UseUltimate"):FireServer()
end

local function refresh()
	local charge = player:GetAttribute("UltCharge")
	if not Config.FeatureOn("Ultimate") or type(charge) ~= "number" then
		FeatureHud.SetUltimate(nil)
		return
	end
	local def = CharacterData.UltimateFor(player:GetAttribute("UltHero"))
	local c = math.clamp(charge, 0, 1)
	FeatureHud.SetUltimate({ OnActivate = fire, Charge = c, Label = "ULT", Icon = ICONS[def.Look or ""] or "sparkle" })
	if c >= 1 then
		explain(def)
	end
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
	player:GetAttributeChangedSignal("UltHero"):Connect(refresh)
	lastUsed = player:GetAttribute("UltUsed")
	refresh()
end

return Ultimate
