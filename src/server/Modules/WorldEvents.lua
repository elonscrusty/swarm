--[[
	WorldEvents.lua
	MAP EVENTS (feature 2, flag Config.Features.MapEvents, docs/features/EVENTS.md): at
	most one map-wide event per stage, run as an ambient EncounterDirector encounter.

	  Meteor    METEOR SHOWER: volleys of impacts. Each lands Warn (>= 1.2) seconds after
	            its warning ring (Hazards.Strike, the "blast" double ring); it hurts the
	            players inside (DamagePlayer: armor, invulnerability and the choice
	            protection apply) and the enemies inside (a share of their max HP, with no
	            killer, so no kill gold). Altar guards, nests, boss objects and bosses are
	            left alone. The first impact of a volley lands near (never on) each player.
	  GoldRush  GOLD RUSH: for Seconds, the kill-gold CHANCE is x ChanceMult (capped at
	            MaxChance; the amount, GoldMult and the gold passes are untouched).
	            GoldSystem.OnKill asks WorldEvents.GoldChance.
	  Fog       FOG: visual only. Clients draw enemies only within Radius of a living run
	            player (bosses, elites, telegraphs, projectiles, pickups and the minimap
	            always show), WorldFx.lua.

	Schedule: a stage from FirstStage rolls Chance (the director's own Random, so the
	stage and loot rolls never change); the event starts StartAfter seconds into the
	explore phase and ends after its Seconds or as soon as the stage leaves the explore
	phase (the boss came). Frozen runs freeze it (the director only steps while the run
	simulates).

	Clients read workspace.WorldFx attributes: MapEvent ("Meteor" | "GoldRush" | "Fog" |
	nil), MapEventLeft (whole seconds), FogRadius. A meteor's fall is a marker part in the
	folder (attribute Land = seconds until impact) that WorldFx animates.
]]

local Config = require(game:GetService("ReplicatedStorage").Shared.Config)
local EncounterDirector = require(script.Parent.EncounterDirector)
local Hazards = require(script.Parent.Hazards)

local WorldEvents = {}

local NAME = "MapEvents"
local GROUP = "MapEvent"
local FLAT = Vector3.new(1, 0, 1)

local ctx
local folder: Folder? = nil
-- the stage's event: Kind, StartIn (pending) or Left (running), Volley timer, markers
local ev: any = nil
local markers: { { Part: BasePart, Left: number } } = {}
local stats = { Started = 0, Volleys = 0, Impacts = 0, EnemyHits = 0, Boosted = 0 }

local function W()
	return Config.WorldEvents
end

-- workspace.WorldFx: the attributes and markers the client reads (shared with Weather).
local function getFolder(): Folder
	if folder and folder.Parent then
		return folder
	end
	local f = workspace:FindFirstChild("WorldFx")
	if not (f and f:IsA("Folder")) then
		f = Instance.new("Folder")
		f.Name = "WorldFx"
		f.Parent = workspace
	end
	folder = f :: Folder
	return f :: Folder
end
WorldEvents.Folder = getFolder

local function living(): { any }
	local out = {}
	for _, rp in ipairs(ctx.RunManager.GetRunPlayers()) do
		if rp.Alive and not rp.Returned and rp.Root and rp.Root.Parent then
			table.insert(out, rp)
		end
	end
	return out
end

-- A floor point inside the arena (kept EdgeMargin from the walls).
local function clampToArena(p: Vector3): Vector3
	local o = Config.ArenaOrigin
	local half = Config.Arenas.Size / 2 - (Config.Chests.EdgeMargin or 12)
	return Vector3.new(math.clamp(p.X, o.X - half, o.X + half), o.Y, math.clamp(p.Z, o.Z - half, o.Z + half))
end

local function around(rng: Random, centre: Vector3, r0: number, r1: number): Vector3
	local a = rng:NextNumber() * math.pi * 2
	local d = rng:NextNumber(r0, r1)
	return clampToArena(Vector3.new(centre.X + math.cos(a) * d, Config.ArenaOrigin.Y, centre.Z + math.sin(a) * d))
end
WorldEvents._Around = around -- (Weather)

------------------------------------------------------------------------------------------
-- Meteor shower
------------------------------------------------------------------------------------------

-- The enemies a meteor (or a fire patch) may hurt: no bosses, boss objects, nests,
-- static creatures or altar guards (their deaths have their own rules).
local function hurtable(e): boolean
	local def = e.Def
	return e.Alive ~= false and not e.Boss and not e.Guard and not e.Dying and not e.Invulnerable
		and def ~= nil and not def.Object and not def.Reward and not def.Static
end
WorldEvents._Hurtable = hurtable

-- Hurts the enemies within `radius` of `pos` by a share of their max HP (no killer).
function WorldEvents.HurtEnemies(pos: Vector3, radius: number, fraction: number, eliteFraction: number): number
	local spawner = ctx.EnemySpawner
	local list = spawner and spawner.Active
	if not list then
		return 0
	end
	local hits = {}
	for _, e in ipairs(list) do
		if e.Pos and hurtable(e) then
			local r = radius + (e.Radius or 1)
			local d = (e.Pos - pos) * FLAT
			if d.X * d.X + d.Z * d.Z <= r * r then
				table.insert(hits, e)
			end
		end
	end
	-- (damage after the scan: a kill swap-removes from Active)
	for _, e in ipairs(hits) do
		local share = e.Elite and eliteFraction or fraction
		spawner.Damage(e, math.max(1, (e.MaxHP or 1) * share), nil)
	end
	return #hits
end

local function addMarker(pos: Vector3, land: number)
	local p = Instance.new("Part")
	p.Name = "Meteor"
	p.Anchored = true
	p.CanCollide = false
	p.CanQuery = false
	p.CanTouch = false
	p.Transparency = 1
	p.Size = Vector3.new(1, 1, 1)
	p.CFrame = CFrame.new(pos)
	p:SetAttribute("Land", land)
	p:SetAttribute("Radius", W().Meteor.Radius)
	p.Parent = getFolder()
	table.insert(markers, { Part = p, Left = land + 0.6 })
end

local function clearMarkers()
	for _, m in ipairs(markers) do
		m.Part:Destroy()
	end
	table.clear(markers)
end

local function volley(rng: Random)
	local M = W().Meteor
	if Hazards.Count() >= Config.Enemies.MaxHazards * M.MaxHazardShare then
		return -- a boss or the swarm is busy telegraphing: never crowd out their warnings
	end
	local players = living()
	if #players == 0 then
		return
	end
	stats.Volleys += 1
	local dmg = M.Damage * ctx.StageManager.DamageMult()
	for i = 1, M.PerVolley do
		local rp = players[(i - 1) % #players + 1]
		local base = rp.Root.Position
		local pos
		if i <= #players then
			pos = around(rng, base, M.NearPlayer[1], M.NearPlayer[2])
		else
			pos = around(rng, base, 10, 34)
		end
		Hazards.Strike(pos, M.Radius, M.Warn, dmg, {
			Group = GROUP,
			Style = "blast",
			Cause = "Meteor",
			OnStrike = function(s)
				stats.Impacts += 1
				stats.EnemyHits += WorldEvents.HurtEnemies(s.Pos, s.Radius, M.EnemyHPFraction, M.EliteHPFraction)
			end,
		})
		addMarker(pos, M.Warn)
	end
end

------------------------------------------------------------------------------------------
-- Gold rush
------------------------------------------------------------------------------------------

-- GoldSystem.OnKill: the kill-gold chance with the gold rush applied (never lowered).
function WorldEvents.GoldChance(chance: number): number
	if not (ev and ev.Running and ev.Kind == "GoldRush") then
		return chance
	end
	local G = W().GoldRush
	stats.Boosted += 1
	return math.max(chance, math.min(chance * G.ChanceMult, G.MaxChance))
end

------------------------------------------------------------------------------------------
-- Lifecycle
------------------------------------------------------------------------------------------

local function publish(kind: string?, left: number?)
	local f = getFolder()
	f:SetAttribute("MapEvent", kind)
	f:SetAttribute("MapEventLeft", left and math.max(0, math.ceil(left)) or nil)
	f:SetAttribute("FogRadius", kind == "Fog" and W().Fog.Radius or nil)
end

local function stop()
	if ev and ev.Running then
		publish(nil)
	end
	ev = nil
	Hazards.Clear(GROUP)
	clearMarkers()
	EncounterDirector.Finish(NAME)
end

local function start(rng: Random)
	local def = (W() :: any)[ev.Kind]
	ev.Running = true
	ev.Left = def.Seconds
	ev.Volley = 0.6 -- the first volley soon after the headline
	ev.Shown = -1
	stats.Started += 1
	publish(ev.Kind, ev.Left)
end

local function pickKind(rng: Random): string
	local total = 0
	local kinds = { "Meteor", "GoldRush", "Fog" }
	for _, k in ipairs(kinds) do
		total += math.max(0, (W().Weights :: any)[k] or 0)
	end
	local roll = rng:NextNumber() * total
	for _, k in ipairs(kinds) do
		roll -= math.max(0, (W().Weights :: any)[k] or 0)
		if roll <= 0 then
			return k
		end
	end
	return "Fog"
end

local function onTick(dt: number, info: any)
	for i = #markers, 1, -1 do
		local m = markers[i]
		m.Left -= dt
		if m.Left <= 0 then
			m.Part:Destroy()
			table.remove(markers, i)
		end
	end
	if not ev then
		return
	end
	local explore = info.Phase == "Explore"
	if not ev.Running then
		if not explore then
			if info.Phase ~= "None" then
				stop() -- the boss came first: no event this stage
			end
			return
		end
		ev.StartIn -= dt
		if ev.StartIn <= 0 then
			start(info.Rng)
		end
		return
	end
	if not explore then
		stop()
		return
	end
	ev.Left -= dt
	if ev.Left <= 0 then
		stop()
		return
	end
	local shown = math.ceil(ev.Left)
	if shown ~= ev.Shown then
		ev.Shown = shown
		getFolder():SetAttribute("MapEventLeft", shown)
	end
	if ev.Kind == "Meteor" then
		ev.Volley -= dt
		if ev.Volley <= 0 then
			ev.Volley = W().Meteor.Every
			volley(info.Rng)
		end
	end
end

-- Tests / DEV: starts `kind` now on the live stage (true = started).
function WorldEvents.Force(kind: string): boolean
	local info = EncounterDirector.Stage()
	if not info or not Config.FeatureOn("MapEvents") then
		return false
	end
	if ev then
		stop()
	end
	if not EncounterDirector.Begin(NAME) then
		return false
	end
	ev = { Kind = kind, StartIn = 0 }
	start(info.Rng)
	return true
end

function WorldEvents.Current(): (string?, boolean, number?)
	if not ev then
		return nil, false, nil
	end
	return ev.Kind, ev.Running == true, ev.Running and ev.Left or ev.StartIn
end

function WorldEvents.Stats(): { [string]: number }
	return table.clone(stats)
end

function WorldEvents.MarkerCount(): number
	return #markers
end

function WorldEvents.Init(c)
	ctx = c
	getFolder()
	EncounterDirector.Register(NAME, {
		Feature = "MapEvents",
		Ambient = true,
		Weight = 1,
		Allow = function(info)
			return info.Stage >= W().FirstStage and info.Rng:NextNumber() < W().Chance
		end,
		OnStageStart = function(info)
			ev = { Kind = pickKind(info.Rng), StartIn = info.Rng:NextNumber(W().StartAfter[1], W().StartAfter[2]) }
			return true
		end,
		OnTick = onTick,
		OnCleanup = function(_reason)
			if ev and ev.Running then
				publish(nil)
			end
			ev = nil
			Hazards.Clear(GROUP)
			clearMarkers()
			local f = folder
			if f then
				f:SetAttribute("MapEvent", nil)
				f:SetAttribute("MapEventLeft", nil)
				f:SetAttribute("FogRadius", nil)
			end
		end,
	})
end

return WorldEvents
