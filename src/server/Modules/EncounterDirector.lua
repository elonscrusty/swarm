--[[
	EncounterDirector.lua
	One hook for the feature encounters of a stage (map events, weather, mini-bosses,
	shrines, the merchant, rescue, secret rooms ...). docs/features/FOUNDATION.md.

	A feature module registers once (in its Init):

	  EncounterDirector.Register("Merchant", {
	      Feature = "Merchant",      -- Config.Features key (default: the name); off = never called
	      Ambient = false,           -- true: map-wide (weather, events), no spot, own cap
	      Weight = 1,                -- pick weight at stage start
	      Allow = function(info) return true end,          -- optional: may it start this stage?
	      OnStageStart = function(info) return started end, -- true = it runs this stage
	      OnTick = function(dt, info) end,                 -- every simulated frame of a stage
	      OnStageEnd = function(info) end,                 -- the stage ended while it ran
	      OnCleanup = function(reason) end,                -- ALWAYS: remove everything (idempotent)
	      OnPlayerOut = function(rp, reason) end,          -- a player died / left / abandoned
	  })

	info = { Arena, Stage, ArenaName, PortalPos, Rng (the director's own Random), Phase }.

	The stage loop drives it (StageManager): StageStart after the loot is placed (before
	EnemyAI.SetArena, so new colliders count), Step while the run simulates (not during
	travel), StageEnd before the next arena is built (travel) and when the run ends
	(defeat, the last player out by portal / MAIN MENU, server cleanup: StageManager.EndRun).
	RunManager calls PlayerOut on a death, a portal return and an abandon.

	Caps: at most Config.Encounters.Director.MaxActive placed and MaxAmbient ambient
	encounters run at once. Placed encounters take their spot with FindSpot, which keeps
	the same distances as the optional locations (LootSystem.BuildStage) from the portal,
	the loot, the caravan and every other reserved spot.

	With nothing registered (or every feature switched off) nothing here runs and the
	game behaves exactly as before. Every callback is pcall'd: one broken feature never
	stops the stage loop. The director has its own Random, so the stage / loot rolls of
	the existing game are unchanged.
]]

local Config = require(game:GetService("ReplicatedStorage").Shared.Config)
local MapBuilder = require(script.Parent.MapBuilder)

local EncounterDirector = {}

export type Def = {
	Feature: string?,
	Ambient: boolean?,
	Weight: number?,
	Allow: ((any) -> boolean)?,
	OnStageStart: ((any) -> boolean?)?,
	OnTick: ((number, any) -> ())?,
	OnStageEnd: ((any) -> ())?,
	OnCleanup: ((string) -> ())?,
	OnPlayerOut: ((any, string) -> ())?,
}

local ctx
local rng = Random.new()
local defs: { [string]: Def } = {}
local order: { string } = {} -- registration order (stable iteration)
local active: { [string]: boolean } = {}
local reserved: { { Name: string, Pos: Vector3 } } = {}
local info: any = nil -- the live stage, nil between stages
local lastError: { [string]: number } = {}

local function D()
	return Config.Encounters.Director
end

local function enabled(name: string): boolean
	local def = defs[name]
	return def ~= nil and Config.FeatureOn(def.Feature or name)
end

local function call(name: string, key: string, ...): (boolean, any)
	local def = defs[name] :: any
	local fn = def and def[key]
	if type(fn) ~= "function" then
		return false, nil
	end
	local ok, result = pcall(fn, ...)
	if not ok then
		local now = os.clock()
		if now - (lastError[name .. key] or -math.huge) > 5 then
			lastError[name .. key] = now
			warn(string.format("[EncounterDirector] %s.%s: %s", name, key, tostring(result)))
		end
		return false, nil
	end
	return true, result
end

local function countActive(ambient: boolean): number
	local n = 0
	for name in pairs(active) do
		local def = defs[name]
		if def and (def.Ambient == true) == ambient then
			n += 1
		end
	end
	return n
end

local function capFor(ambient: boolean): number
	return ambient and D().MaxAmbient or D().MaxActive
end

------------------------------------------------------------------------------------------
-- Registration
------------------------------------------------------------------------------------------

function EncounterDirector.Register(name: string, def: Def)
	assert(type(name) == "string" and name ~= "", "EncounterDirector.Register: name")
	assert(type(def) == "table", "EncounterDirector.Register: def")
	if not defs[name] then
		table.insert(order, name)
	end
	defs[name] = def
end

-- Tests / hot reload: forgets a registration (its cleanup runs first).
function EncounterDirector.Unregister(name: string)
	if not defs[name] then
		return
	end
	call(name, "OnCleanup", "Unregister")
	active[name] = nil
	EncounterDirector.Release(name)
	defs[name] = nil
	local i = table.find(order, name)
	if i then
		table.remove(order, i)
	end
end

function EncounterDirector.Registered(): { string }
	return table.clone(order)
end

------------------------------------------------------------------------------------------
-- Queries
------------------------------------------------------------------------------------------

function EncounterDirector.IsActive(name: string): boolean
	return active[name] == true
end

function EncounterDirector.ActiveCount(ambient: boolean?): number
	return countActive(ambient == true)
end

-- The live stage's info table (nil between stages).
function EncounterDirector.Stage(): any
	return info
end

------------------------------------------------------------------------------------------
-- Mid-stage start / finish (events that begin later in a stage)
------------------------------------------------------------------------------------------

-- Asks for a running slot now. True = it counts as running until Finish / stage end.
function EncounterDirector.Begin(name: string): boolean
	if not info or not enabled(name) then
		return false
	end
	if active[name] then
		return true
	end
	local ambient = defs[name].Ambient == true
	if countActive(ambient) >= capFor(ambient) then
		return false
	end
	active[name] = true
	return true
end

-- The encounter is done (its spot is freed too).
function EncounterDirector.Finish(name: string)
	active[name] = nil
	EncounterDirector.Release(name)
end

------------------------------------------------------------------------------------------
-- Space
------------------------------------------------------------------------------------------

local function avoidList(): { Vector3 }
	local avoid = {}
	if info and info.PortalPos then
		table.insert(avoid, info.PortalPos)
	end
	local loot = ctx and ctx.LootSystem
	if loot and loot.Objects then
		for _, obj in ipairs(loot.Objects()) do
			if typeof(obj.Pos) == "Vector3" then
				table.insert(avoid, obj.Pos)
			end
		end
	end
	local caravan = ctx and ctx.CaravanEvent and ctx.CaravanEvent.Get and ctx.CaravanEvent.Get()
	if caravan and typeof((caravan :: any).Pos) == "Vector3" then
		table.insert(avoid, (caravan :: any).Pos)
	end
	for _, r in ipairs(reserved) do
		table.insert(avoid, r.Pos)
	end
	return avoid
end

--[[
	A free spot for encounter `name` on the live stage, kept apart from the portal, the
	loot, the caravan and the other encounters (the optional-location rules). The spot is
	reserved for `name` until Release / Finish / stage end. opts may override MinDistance,
	Clearance, Spacing, EdgeMargin. Returns nil when the arena has no room.
]]
function EncounterDirector.FindSpot(name: string, opts: { [string]: any }?): Vector3?
	if not info or not info.Arena then
		return nil
	end
	local d = D()
	local o = opts or {}
	local spot = MapBuilder.FindOpenSpot(info.Arena, rng, {
		MinDistance = o.MinDistance or d.MinDistance,
		EdgeMargin = o.EdgeMargin or Config.Chests.EdgeMargin,
		Clearance = o.Clearance or d.Clearance,
		Spacing = o.Spacing or d.Spacing,
		Avoid = avoidList(),
		KeepFrom = info.PortalPos,
		KeepRadius = Config.Chests.PortalClearance,
	} :: any)
	if spot then
		table.insert(reserved, { Name = name, Pos = spot })
	end
	return spot
end

-- Frees every spot `name` reserved.
function EncounterDirector.Release(name: string)
	for i = #reserved, 1, -1 do
		if reserved[i].Name == name then
			table.remove(reserved, i)
		end
	end
end

function EncounterDirector.Reserved(): { { Name: string, Pos: Vector3 } }
	return table.clone(reserved)
end

------------------------------------------------------------------------------------------
-- Stage loop (StageManager / RunManager)
------------------------------------------------------------------------------------------

local function pickOrder(candidates: { string }): { string }
	-- weighted shuffle (director rng only)
	local pool = table.clone(candidates)
	local out: { string } = {}
	while #pool > 0 do
		local total = 0
		for _, name in ipairs(pool) do
			total += math.max(0, tonumber(defs[name].Weight) or 1)
		end
		local index = #pool
		if total > 0 then
			local roll = rng:NextNumber() * total
			for i, name in ipairs(pool) do
				roll -= math.max(0, tonumber(defs[name].Weight) or 1)
				if roll <= 0 then
					index = i
					break
				end
			end
		end
		local name: string = pool[index]
		table.remove(pool, index)
		table.insert(out, name)
	end
	return out
end

-- A new stage is built (arena, portal and loot placed).
function EncounterDirector.StageStart(arena: any, stage: number, portalPos: Vector3?, arenaName: string?)
	if info then
		EncounterDirector.StageEnd("Restart")
	end
	info = { Arena = arena, Stage = stage, ArenaName = arenaName, PortalPos = portalPos, Rng = rng, Phase = "Explore" }
	if #order == 0 then
		return
	end
	local candidates = {}
	for _, name in ipairs(order) do
		if enabled(name) then
			local allowed = true
			if (defs[name] :: any).Allow then
				local ok, result = call(name, "Allow", info)
				allowed = ok and result == true
			end
			if allowed then
				table.insert(candidates, name)
			end
		end
	end
	for _, name in ipairs(pickOrder(candidates)) do
		local ambient = defs[name].Ambient == true
		if countActive(ambient) < capFor(ambient) then
			local ok, started = call(name, "OnStageStart", info)
			if ok and started == true then
				active[name] = true
			else
				EncounterDirector.Release(name) -- a declined start keeps no spot
			end
		end
	end
end

-- Every simulated frame of a stage.
function EncounterDirector.Step(dt: number)
	if not info or #order == 0 then
		return
	end
	if ctx and ctx.StageManager then
		info.Phase = ctx.StageManager.GetPhase()
	end
	for _, name in ipairs(order) do
		if enabled(name) then
			call(name, "OnTick", dt, info)
		end
	end
end

--[[
	The stage ended (reason: "Travel" | "RunEnd" | "Restart"). Running encounters get
	OnStageEnd, then EVERY registered one gets OnCleanup (also switched-off features, so
	nothing is left behind when a flag changes mid-run).
]]
function EncounterDirector.StageEnd(reason: string)
	if not info then
		return
	end
	local was = info
	for _, name in ipairs(order) do
		if active[name] then
			call(name, "OnStageEnd", was)
		end
	end
	for _, name in ipairs(order) do
		call(name, "OnCleanup", reason)
	end
	table.clear(active)
	table.clear(reserved)
	info = nil
end

-- A player is out of the stage ("Death" | "Portal" | "Abandon").
function EncounterDirector.PlayerOut(rp: any, reason: string)
	if not info then
		return
	end
	for _, name in ipairs(order) do
		if enabled(name) then
			call(name, "OnPlayerOut", rp, reason)
		end
	end
end

function EncounterDirector.Init(c)
	ctx = c
end

return EncounterDirector
