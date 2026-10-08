--[[
	BiomeHazards.lua
	The fixed floor hazards of the biome arenas (Config.Arenas.Hazards), decided on the
	server. MapBuilder places them as part of the designed layout and lists them in
	arena.Hazards = { { Kind = "Mud" | "Quicksand" | "Ice" | "Lava", Pos, Radius } }; their
	meshes (mud, quicksand, frozen pond, lava pool + a glow ring) are the telegraph.

	  Mud / Quicksand  players inside move at PlayerSpeed x their speed; walking enemies
	                   inside move at EnemySpeed x (through EnemyAI's slow fields, never
	                   stacking with a stronger slow); flyers and bosses wade through.
	  Ice              players inside get PlayerSpeed x speed and slippery steering (the
	                   client smooths the move input while the player attribute Terrain
	                   is "Ice", src/client/TerrainFx.lua); enemies keep their footing.
	  Lava             players inside take Damage every Tick seconds (first tick Grace
	                   seconds after stepping in) through RunManager.DamagePlayer, which
	                   respects invulnerability, armor and shields. Enemies are unharmed.

	The speed multiplier lives in rp.TerrainSpeedMult (RunManager.ApplyMovement multiplies
	WalkSpeed by it). Player attribute "Terrain" = the hazard kind the player stands in (or
	nil) for the client. Checked every Config.Arenas.Hazards.CheckInterval seconds; stepped
	by StageManager only while the run simulates.
]]

local Config = require(game:GetService("ReplicatedStorage").Shared.Config)
local Hazards = require(script.Parent.Hazards)
local HeightGrid = require(script.Parent.HeightGrid)

local BiomeHazards = {}

local ctx
local H = (Config.Arenas :: any).Hazards or {}
local hazards: { any } = {}
local timer = 0
local tracked: { [any]: boolean } = {} -- run players whose terrain state was touched
local eruptionTimer = 0
local arenaActive = false
local arenaName = ""

local function kindAt(x: number, z: number): any?
	for _, h in ipairs(hazards) do
		local dx, dz = x - h.Pos.X, z - h.Pos.Z
		if dx * dx + dz * dz <= h.Radius * h.Radius then
			return h
		end
	end
	return nil
end
BiomeHazards.At = kindAt

local function playerMult(kind: string?): number
	local def = kind and H[kind]
	return def and def.PlayerSpeed or 1
end

-- Puts a run player on `kind` ground (nil = plain floor): speed, attribute, lava timer.
local function setTerrain(rp, kind: string?)
	if rp.Terrain == kind then
		return
	end
	rp.Terrain = kind
	tracked[rp] = true
	local mult = playerMult(kind)
	if rp.TerrainSpeedMult ~= mult then
		rp.TerrainSpeedMult = mult
		ctx.RunManager.ApplyMovement(rp)
	end
	if kind == "Lava" then
		rp.LavaNext = ctx.RunManager.GetRunTime() + ((H.Lava and H.Lava.Grace) or 0.25)
	end
	if rp.Player and rp.Player.Parent then
		rp.Player:SetAttribute("Terrain", kind)
	end
end

local function resetPlayer(rp)
	rp.Terrain = nil
	rp.LavaNext = nil
	local was = rp.TerrainSpeedMult
	rp.TerrainSpeedMult = nil
	if was and was ~= 1 and rp.Alive and ctx.RunManager.GetRunPlayer(rp.Player) == rp then
		pcall(ctx.RunManager.ApplyMovement, rp)
	end
	if rp.Player and rp.Player.Parent then
		rp.Player:SetAttribute("Terrain", nil)
	end
end

local function stepPlayers()
	local now = ctx.RunManager.GetRunTime()
	local players = ctx.RunManager.GetRunPlayers()
	-- players who left the run (returned through the portal, disconnected) let go
	for rp in pairs(tracked) do
		if not table.find(players, rp) then
			tracked[rp] = nil
			resetPlayer(rp)
		end
	end
	for _, rp in ipairs(players) do
		local root: BasePart? = rp.Root
		local h = nil
		if rp.Alive and root and root.Parent then
			h = kindAt(root.Position.X, root.Position.Z)
		end
		local kind = h and h.Kind or nil
		setTerrain(rp, kind)
		if kind == "Lava" and now >= (rp.LavaNext or 0) then
			rp.LavaNext = now + ((H.Lava and H.Lava.Tick) or 0.5)
			ctx.RunManager.DamagePlayer(rp, ((H.Lava and H.Lava.Damage) or 6) * ctx.StageManager.DamageMult(), "Lava")
		end
	end
end

-- Walking enemies in mud / quicksand: EnemyAI multiplies their speed by SlowMult until
-- SlowUntil. A stronger or longer slow from a weapon (Chilling Aura) is left alone.
local function stepEnemies()
	local spawner = ctx.EnemySpawner
	local active = spawner and spawner.Active
	if not active then
		return
	end
	local now = ctx.RunManager.GetRunTime()
	local hold = ((H.CheckInterval or 0.1) * 2.5)
	for _, e in ipairs(active) do
		if e.Alive ~= false and not e.Boss and not (e.Def and e.Def.FlyHeight) and e.Pos then
			local h = kindAt(e.Pos.X, e.Pos.Z)
			local def = h and H[h.Kind]
			local mult = def and def.EnemySpeed
			if mult then
				local slowed = e.SlowUntil and e.SlowUntil > now
				-- a running weapon slow (TerrainSlow cleared by slowEnemy) is only replaced
				-- when the mud is stronger; our own mud slow is refreshed
				if not slowed or (e.SlowMult or 1) > mult or (e.TerrainSlow and (e.SlowMult or 1) >= mult) then
					e.SlowMult = mult
					e.SlowUntil = math.max(slowed and e.SlowUntil or 0, now + hold)
					e.TerrainSlow = true
				end
			elseif e.TerrainSlow then
				e.TerrainSlow = nil
				if e.SlowUntil and e.SlowUntil <= now + hold then
					e.SlowUntil = nil -- walked out: the mud lets go at once
					e.SlowMult = nil
				end
			end
		end
	end
end

-- The new stage's arena (after MapBuilder.BuildArena). Clears every player's terrain.
function BiomeHazards.SetArena(arena)
	hazards = (arena and arena.Hazards) or {}
	arenaActive = arena ~= nil
	arenaName = (arena and arena.Name) or ""
	eruptionTimer = Config.Enemies.StageHazards.Every
	Hazards.Clear("Biome")
	timer = 0
	BiomeHazards.ResetPlayers()
end

function BiomeHazards.ResetPlayers()
	for rp in pairs(tracked) do
		resetPlayer(rp)
	end
	table.clear(tracked)
end

-- The run ended: no hazards, every player back on plain floor.
function BiomeHazards.Clear()
	hazards = {}
	arenaActive = false
	Hazards.Clear("Biome")
	BiomeHazards.ResetPlayers()
end

function BiomeHazards.Count(): number
	return #hazards
end

function BiomeHazards.Step(dt: number)
	if not ctx.RunManager.IsSimulating() then return end
	local D = Config.Enemies.StageHazards
	if arenaActive and ctx.StageManager.GetStage() >= D.FirstStage and ctx.StageManager.GetPhase() == "Explore" then
		eruptionTimer -= dt
		if eruptionTimer <= 0 then
			eruptionTimer = D.Every
			local made = 0
			for _, rp in ipairs(ctx.RunManager.GetRunPlayers()) do
				if rp.Alive and rp.Root and not rp.Paused and made < D.MaxTargets then
					local p = rp.Root.Position
					local pos = HeightGrid.Ground(p)
					local frost = arenaName == "Snow"
					Hazards.Strike(pos, D.Radius, D.Warn, D.Damage * ctx.StageManager.DamageMult(),
						{ Group = "Biome", Style = frost and "frost" or "venom", Cause = frost and "Frost fracture" or "Ground eruption" })
					made += 1
				end
			end
		end
	end
	if #hazards == 0 then
		return
	end
	timer -= dt
	if timer > 0 then
		return
	end
	timer = H.CheckInterval or 0.1
	stepPlayers()
	stepEnemies()
end

function BiomeHazards.Init(c)
	ctx = c
end

return BiomeHazards
