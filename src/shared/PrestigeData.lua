--[[
	PrestigeData.lua
	Pure rules for Prestige (Config.Features.Prestige, Config.Prestige; docs/next/PRESTIGE.md),
	shared by the server (Prestige.lua) and the Characters screen (MenuPrestige.lua,
	PrestigeConfirm.lua).

	A hero whose whole Hero Mastery track is maxed (its six stat upgrades and its signature
	at their max level, MetaUpgradeData.HeroOrder) may Prestige: those upgrade levels go
	back to 0 and the hero gets one star (at most MaxStars). Each star adds GoldPerStar of
	the gold a run with that hero pays into the lobby at settlement (GoldCap at most).
	Stars never change damage, health or any other combat number.

	Save field: Prestige = { [heroId] = stars } (whole numbers 1..MaxStars; 0 is left out).
]]

local Config = require(script.Parent.Config)
local MetaUpgradeData = require(script.Parent.MetaUpgradeData)

local PrestigeData = {}

local function cfg(): { [string]: any }
	return (Config :: any).Prestige or {}
end

function PrestigeData.MaxStars(): number
	return math.max(0, math.floor(tonumber(cfg().MaxStars) or 5))
end

local function whole(v: any): number
	local n = tonumber(v)
	if not n or n ~= n or n == math.huge or n == -math.huge then
		return 0
	end
	return math.floor(n)
end

-- A clean copy of a stored Prestige table: string ids, whole stars 1..MaxStars.
function PrestigeData.Clean(t: any): { [string]: number }
	local out = {}
	if type(t) ~= "table" then
		return out
	end
	local max = PrestigeData.MaxStars()
	local n = 0
	for id, v in pairs(t) do
		if type(id) == "string" and #id > 0 and #id <= 40 and n < 64 then
			local stars = math.clamp(whole(v), 0, max)
			if stars > 0 then
				out[id] = stars
				n += 1
			end
		end
	end
	return out
end

-- A hero's stars in a Prestige table (0 when none / junk).
function PrestigeData.Stars(t: any, heroId: string?): number
	if type(t) ~= "table" or type(heroId) ~= "string" then
		return 0
	end
	return math.clamp(whole(t[heroId]), 0, PrestigeData.MaxStars())
end

-- The gold bonus rate for a number of stars (0.05 per star, never above the cap).
function PrestigeData.BonusRate(stars: number): number
	local c = cfg()
	local per = math.max(0, tonumber(c.GoldPerStar) or 0)
	local cap = math.max(0, tonumber(c.GoldCap) or 0)
	local s = math.clamp(whole(stars), 0, PrestigeData.MaxStars())
	return math.min(cap, s * per)
end

-- The bonus gold for `base` gold paid into the lobby by a run with `stars` stars.
function PrestigeData.BonusFor(base: number, stars: number): number
	if type(base) ~= "number" or base ~= base or base <= 0 or base == math.huge then
		return 0
	end
	return math.max(0, math.floor(base * PrestigeData.BonusRate(stars)))
end

-- Whole percent text ("+10%").
function PrestigeData.PercentText(stars: number): string
	return string.format("+%d%%", math.floor(PrestigeData.BonusRate(stars) * 100 + 0.5))
end

-- True when every one of the hero's own upgrades (six stats + signature) is at its max.
function PrestigeData.IsMaxed(heroId: string, track: any): boolean
	if type(track) ~= "table" then
		return false
	end
	local any = false
	for _, id in ipairs(MetaUpgradeData.HeroOrder()) do
		local def = MetaUpgradeData.HeroDef(heroId, id)
		if def then
			any = true
			if whole(track[id]) < (def.MaxLevel or 0) then
				return false
			end
		end
	end
	return any
end

-- How many of the hero's upgrades are maxed, of how many (the Characters screen line).
function PrestigeData.Progress(heroId: string, track: any): (number, number)
	local done, total = 0, 0
	local t = type(track) == "table" and track or {}
	for _, id in ipairs(MetaUpgradeData.HeroOrder()) do
		local def = MetaUpgradeData.HeroDef(heroId, id)
		if def then
			total += 1
			if whole(t[id]) >= (def.MaxLevel or 0) then
				done += 1
			end
		end
	end
	return done, total
end

-- The star mark ("★2"; "" for none).
function PrestigeData.StarText(stars: number): string
	local s = math.clamp(whole(stars), 0, PrestigeData.MaxStars())
	return s > 0 and ("\u{2605}" .. s) or ""
end

-- The confirmation sentence (owner spec, docs/next/PRESTIGE.md). nextStars = the star the
-- hero gets ("You get ★1 and +5% gold with the Knight.").
function PrestigeData.ConfirmText(heroName: string, nextStars: number): string
	return string.format("Your %s's upgrades go back to level 0. You keep your gold, skins and other heroes. You get %s and %s gold with the %s.",
		heroName, PrestigeData.StarText(nextStars), PrestigeData.PercentText(nextStars), heroName)
end

function PrestigeData.ButtonText(heroName: string): string
	return "PRESTIGE " .. string.upper(heroName)
end

return PrestigeData
