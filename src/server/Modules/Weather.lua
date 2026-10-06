--[[
	Weather.lua
	WEATHER PER WORLD (feature 9, flag Config.Features.Weather, docs/features/EVENTS.md).
	Weather belongs to the world, not to an encounter: it registers with
	EncounterDirector for the stage loop (ticks, cleanup) but never asks for the ambient
	slot (Allow is always false), so a map event still runs beside it.

	  Snow   SNOW STORM: every run player's WalkSpeed x Snow.PlayerSpeed (rp.WeatherSpeedMult,
	         RunManager.ApplyMovement) and every walking enemy x Snow.EnemySpeed
	         (EnemyAI.WorldSpeedMult; scripted boss moves keep their speed). Clients add a
	         light snowfall (WorldFx).
	  Lava   ERUPTIONS: during the explore phase, every Every seconds Patches fire patches
	         (Hazards.Patch "fire": a harmless glow for Arm seconds, the telegraph, then
	         they burn for Life). They burn players inside (DamagePlayer rules) and normal
	         enemies inside (a share of max HP per tick, no killer, no gold).
	  Others one light ambient particle effect on the clients only (Config.Weather.Ambient).

	Clients read workspace.WorldFx attributes: World (the arena name while Weather is on),
	Storm (true in a snow storm).
]]

local Config = require(game:GetService("ReplicatedStorage").Shared.Config)
local EncounterDirector = require(script.Parent.EncounterDirector)
local Hazards = require(script.Parent.Hazards)

local Weather = {}

local NAME = "Weather"
local GROUP = "Weather"

local ctx
local world: string? = nil -- the arena the weather was set up for (nil = none)
local stageNo = 0
local tracked: { [any]: boolean } = {} -- run players with a weather speed mult
local eruptTimer = 0
local patches: { any } = {} -- { Pos, Radius, Arm, Life, Tick }
local stats = { Eruptions = 0, Patches = 0, EnemyBurns = 0 }

local function V()
	return Config.Weather
end

local function folder(): Folder
	return ctx.WorldEvents.Folder()
end

local function setPlayerMult(rp, mult: number?)
	-- a reconnected player comes back as a copy of its record (RunManager snapshot) that
	-- still carries the old multiplier: track it too, or it would never be reset (REVIEW R-02)
	if rp.WeatherSpeedMult == mult and (mult == nil or tracked[rp]) then
		return
	end
	rp.WeatherSpeedMult = mult
	if mult then
		tracked[rp] = true
	else
		tracked[rp] = nil
	end
	if rp.Humanoid and ctx.RunManager.GetRunPlayer(rp.Player) == rp then
		pcall(ctx.RunManager.ApplyMovement, rp)
	end
end

local function resetAll()
	for rp in pairs(tracked) do
		setPlayerMult(rp, nil)
	end
	table.clear(tracked)
	if ctx.EnemyAI then
		ctx.EnemyAI.WorldSpeedMult = 1
	end
	Hazards.Clear(GROUP)
	table.clear(patches)
	world = nil
	stageNo = 0
	local f = ctx.WorldEvents and ctx.WorldEvents.Folder and folder()
	if f then
		f:SetAttribute("World", nil)
		f:SetAttribute("Storm", nil)
	end
end

local function setup(info: any)
	resetAll()
	world = info.ArenaName or ""
	stageNo = info.Stage or 0
	if stageNo < V().FirstStage then
		world = "" -- (no weather yet, but the stage is known)
	end
	local storm = world == "Snow"
	folder():SetAttribute("World", world ~= "" and world or nil)
	folder():SetAttribute("Storm", storm or nil)
	ctx.EnemyAI.WorldSpeedMult = storm and V().Snow.EnemySpeed or 1
	eruptTimer = V().Lava.FirstAfter
end

local function stepSnow()
	local mult = V().Snow.PlayerSpeed
	local players = ctx.RunManager.GetRunPlayers()
	for rp in pairs(tracked) do
		if not table.find(players, rp) then
			setPlayerMult(rp, nil) -- left the run (portal, disconnect)
		end
	end
	for _, rp in ipairs(players) do
		if rp.Alive and not rp.Returned then
			setPlayerMult(rp, mult)
		end
	end
end

local function erupt(rng: Random)
	local L = V().Lava
	if Hazards.Count() >= Config.Enemies.MaxHazards * L.MaxHazardShare then
		return
	end
	local players = {}
	for _, rp in ipairs(ctx.RunManager.GetRunPlayers()) do
		if rp.Alive and not rp.Returned and rp.Root and rp.Root.Parent then
			table.insert(players, rp)
		end
	end
	if #players == 0 then
		return
	end
	stats.Eruptions += 1
	local target = players[rng:NextInteger(1, #players)]
	local dmg = L.Damage * ctx.StageManager.DamageMult()
	for i = 1, L.Patches do
		local pos = i == 1 and ctx.WorldEvents._Around(rng, target.Root.Position, L.NearPlayer[1], L.NearPlayer[2])
			or ctx.WorldEvents._Around(rng, target.Root.Position, 12, 36)
		local h = Hazards.Patch(pos, L.Radius, L.Arm, L.Life, L.Tick, dmg, GROUP, "fire")
		h.Cause = "Lava eruption"
		table.insert(patches, { Pos = pos, Radius = L.Radius, Arm = L.Arm, Life = L.Life, Tick = 0 })
		stats.Patches += 1
	end
end

-- Burning patches hurt the normal enemies standing in them (like the players).
local function stepPatches(dt: number)
	local L = V().Lava
	for i = #patches, 1, -1 do
		local p = patches[i]
		if p.Arm > 0 then
			p.Arm -= dt
		else
			p.Life -= dt
			if p.Life <= 0 then
				table.remove(patches, i)
			else
				p.Tick -= dt
				if p.Tick <= 0 then
					p.Tick = L.Tick
					stats.EnemyBurns += ctx.WorldEvents.HurtEnemies(p.Pos, p.Radius, L.EnemyDamageFraction, L.EnemyDamageFraction * 0.25)
				end
			end
		end
	end
end

local function onTick(dt: number, info: any)
	if world == nil or stageNo ~= info.Stage then
		setup(info)
	end
	if world == "Snow" then
		stepSnow()
	elseif world == "Lava" then
		stepPatches(dt)
		if info.Phase == "Explore" then
			eruptTimer -= dt
			if eruptTimer <= 0 then
				local E = V().Lava.Every
				eruptTimer = info.Rng:NextNumber(E[1], E[2])
				erupt(info.Rng)
			end
		end
	end
end

function Weather.World(): string?
	return world
end

function Weather.Stats(): { [string]: number }
	return table.clone(stats)
end

function Weather.Init(c)
	ctx = c
	EncounterDirector.Register(NAME, {
		Feature = "Weather",
		Ambient = true,
		Weight = 0,
		-- a property of the world: it never takes the ambient slot (map events keep it)
		Allow = function()
			return false
		end,
		OnTick = onTick,
		OnCleanup = function(_reason)
			resetAll()
		end,
		OnPlayerOut = function(rp, _reason)
			setPlayerMult(rp, nil)
		end,
	})
end

return Weather
