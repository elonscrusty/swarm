--[[
	StageModifierUI.lua (client)
	The stage modifier's HUD badge (batch B, Config.Features.StageModifiers;
	docs/next/STAGE_MODIFIERS.md). The server publishes the live stage's modifier as the
	SwarmState attribute "StageModifier" (an id, "" = none; RunModifiers.Publish). While a run
	is running and the id is set, a FeatureHud badge names it ("GLASS ARENA"); FeatureHud keeps
	the badge row inside the safe area, shrinks it on phones and hides it whenever a panel
	covers the HUD (UIState). The stage card (RunIntro) spells out the effects.
]]

local Players = game:GetService("Players")
local Shared = game:GetService("ReplicatedStorage"):WaitForChild("Shared")
local Config = require(Shared:WaitForChild("Config"))
local Remotes = require(Shared:WaitForChild("Remotes"))
local Theme = require(Shared:WaitForChild("Theme"))
local StageModifierData = require(Shared:WaitForChild("StageModifierData"))
local FeatureHud = require(script.Parent.FeatureHud)

local StageModifierUI = {}

local BADGE = "stagemod"
local ORDER = 12 -- before the song / curse-timer badges, after weather (10)
local shown = "" -- the id on the badge ("" = none)

-- The badge text for modifier `id` ("" = none).
function StageModifierUI.Text(id: string?): string
	local name = StageModifierData.Name(id)
	return name ~= "" and string.upper(name) or ""
end

function StageModifierUI.Refresh()
	local state = Remotes.State()
	local id = tostring(state:GetAttribute("StageModifier") or "")
	local player = Players.LocalPlayer
	local running = state:GetAttribute("Phase") == "Running" and (player == nil or player:GetAttribute("InRun") == true)
	local text = (running and Config.FeatureOn("StageModifiers")) and StageModifierUI.Text(id) or ""
	if text == "" then
		if shown ~= "" then
			FeatureHud.RemoveBadge(BADGE)
		end
		shown = ""
		return
	end
	if shown ~= id then
		FeatureHud.Badge(BADGE, { Text = text, Color = Theme.Color.CrimsonDark, Order = ORDER })
		shown = id
	end
end

-- The id on the badge now ("" = none) (preview / tests).
function StageModifierUI.Shown(): string
	return shown
end

function StageModifierUI.Init()
	local state = Remotes.State()
	for _, attr in ipairs({ "StageModifier", "Phase" }) do
		state:GetAttributeChangedSignal(attr):Connect(StageModifierUI.Refresh)
	end
	local player = Players.LocalPlayer
	if player then
		player:GetAttributeChangedSignal("InRun"):Connect(StageModifierUI.Refresh)
	end
	StageModifierUI.Refresh()
end

return StageModifierUI
