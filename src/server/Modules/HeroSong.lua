--[[
	HeroSong.lua (server)
	The Bard's Rally Song (feature 11, Config.Features.NewHeroes; docs/features/HEROES.md).

	Every Bard in a running, simulating run gives each living teammate within Song.Radius
	+trait damage (MetaUpgradeData Signature "Bard": 12% + 2% per signature level). The
	Bard itself always gets Song.SelfShare of its own value, so a solo Bard has a smaller
	buff. Two Bards never stack: each player keeps the best single value.

	The buff lives on the run player as rp.SongBuff (0 = none); WeaponSystem multiplies
	weapon damage by (1 + rp.SongBuff). It is decided here on the server from server
	positions only. The player attribute "SongBuff" (whole percent) drives the HUD badge.
	Every Song.Pulse seconds the Bard's ring is drawn with Fx.Ring (existing effect).
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Config = require(ReplicatedStorage.Shared.Config)
local CharacterData = require(ReplicatedStorage.Shared.CharacterData)
local MetaUpgradeData = require(ReplicatedStorage.Shared.MetaUpgradeData)
local Fx = require(script.Parent.Fx)

local HeroSong = {}

local ctx
local TICK = 0.25 -- seconds between recomputes (positions change slowly enough)
local timer = 0
local pulse: { [any]: number } = {}
local shown: { [Player]: boolean } = {} -- players whose SongBuff attribute is set
local FLAT = Vector3.new(1, 0, 1)

local function on(): boolean
	return Config.FeatureOn("NewHeroes")
end

-- The song value (0.12 = +12%) a Bard run player gives its allies.
function HeroSong.Value(rp): number
	local def = CharacterData.Characters[rp.CharacterId]
	if not def or not def.Song then
		return 0
	end
	return MetaUpgradeData.TraitValue(rp.CharacterId, rp.Meta and rp.Meta.Signature or 0) or 0
end

local function active(rp): boolean
	return rp.Alive and rp.Root ~= nil and not rp.Returned and not rp.AwaitingRevive
end

local function setBuff(rp, value: number)
	value = math.max(0, value)
	if rp.SongBuff ~= value then
		rp.SongBuff = value
	end
end

-- Recomputes every run player's buff now (also used by the regression scene).
function HeroSong.Refresh()
	local players = ctx.RunManager.GetRunPlayers()
	if on() and #players > 0 and not ctx.RunManager.IsSimulating() then
		return -- paused, frozen or travelling: keep the buffs as they are
	end
	local best: { [any]: number } = {}
	if on() then
		for _, bard in ipairs(players) do
			local def = CharacterData.Characters[bard.CharacterId]
			local song = def and def.Song
			if song and active(bard) then
				local v = HeroSong.Value(bard)
				local selfV = v * (song.SelfShare or 0)
				best[bard] = math.max(best[bard] or 0, selfV)
				local r2 = (song.Radius or 0) ^ 2
				local bp = bard.Root.Position * FLAT
				for _, other in ipairs(players) do
					if other ~= bard and active(other) then
						local d = other.Root.Position * FLAT - bp
						if d:Dot(d) <= r2 then
							best[other] = math.max(best[other] or 0, v)
						end
					end
				end
			end
		end
	end
	local seen: { [Player]: boolean } = {}
	for _, rp in ipairs(players) do
		setBuff(rp, best[rp] or 0)
		local p = rp.Player
		if p then
			local pct = math.floor(rp.SongBuff * 100 + 0.5)
			if pct > 0 then
				seen[p] = true
				shown[p] = true
				if p:GetAttribute("SongBuff") ~= pct then
					p:SetAttribute("SongBuff", pct)
				end
			end
		end
	end
	-- clear the badge of everyone without a buff now (also players whose run ended)
	for p in pairs(shown) do
		if not seen[p] then
			shown[p] = nil
			if p.Parent then
				p:SetAttribute("SongBuff", nil)
			end
		end
	end
end

function HeroSong.Init(c)
	ctx = c
end

function HeroSong.Step(dt: number)
	timer += dt
	if timer < TICK then
		return
	end
	local step = timer
	timer = 0
	HeroSong.Refresh()
	if not on() or not ctx.RunManager.IsSimulating() then
		table.clear(pulse)
		return
	end
	-- the ring around each Bard (cosmetic; the existing Fx.Ring effect)
	for _, rp in ipairs(ctx.RunManager.GetRunPlayers()) do
		local def = CharacterData.Characters[rp.CharacterId]
		local song = def and def.Song
		if song and active(rp) then
			pulse[rp] = (pulse[rp] or 0) - step
			if pulse[rp] <= 0 then
				pulse[rp] = song.Pulse or 4
				Fx.Ring(rp.Root.Position, song.Radius or 20, def.Colors.Accent)
			end
		else
			pulse[rp] = nil
		end
	end
end

return HeroSong
