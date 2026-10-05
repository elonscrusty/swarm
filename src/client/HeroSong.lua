--[[
	HeroSong.lua (client)
	The Bard's Rally Song badge (feature 11, docs/features/HEROES.md). The server decides
	the buff (server HeroSong.lua) and publishes it as the player attribute "SongBuff"
	(whole percent). While it is set, a FeatureHud badge reads "SONG +12%". Idle while
	Config.Features.NewHeroes is off (the server never sets the attribute then).
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Palette = require(ReplicatedStorage.Shared.Palette)
local FeatureHud = require(script.Parent.FeatureHud)

local HeroSong = {}

local BADGE = "song"

local function refresh(player: Player)
	local pct = tonumber(player:GetAttribute("SongBuff"))
	if pct and pct > 0 then
		FeatureHud.Badge(BADGE, { Text = string.format("SONG +%d%%", pct), Color = Palette.gold_300, Order = 30 })
	else
		FeatureHud.RemoveBadge(BADGE)
	end
end

function HeroSong.Init()
	local player = Players.LocalPlayer
	if not player then
		return
	end
	player:GetAttributeChangedSignal("SongBuff"):Connect(function()
		refresh(player)
	end)
	refresh(player)
end

return HeroSong
