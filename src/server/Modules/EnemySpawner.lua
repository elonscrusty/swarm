--[[
	EnemySpawner.lua
	Owns every enemy: the object pool (Config.Enemies.PoolSize single-Part models built at
	boot), spawning (per-minute table, mini-waves, elites, boss, the portal surge), damage
	and death/drops. Stats scale with run time (tier) and with the stage (StageManager).
	Movement and AI live in EnemyAI, which reads EnemySpawner.Active every Heartbeat.

	Enemy record fields:
	  Id (pool index, also the model name "E<Id>"), Uid (unique per spawn), Model, Part,
	  Def, Type, Elite, Boss, Alive, Pos (ground position), Height (body centre above floor),
	  Radius, HP, MaxHP, Speed, Damage, Dir, Knock (knockback velocity), NextContact (latest contact bite; the real cooldown is per player, ContactNext),
	  Ghost, Erratic, Phase, Slot (index in Active), Guard (guarded-altar id, LootSystem),
	  Affix (elites: "Swift" | "Shielded" | "Burning"), Shield (HP the shield still soaks),
	  DmgScale (attack damage multiplier), SpawnGrace, Act / ActTimer (EnemyAI behaviours),
	  WarnId (its live telegraph), Harmless / Invulnerable / Untargetable / Dying (boss,
	  a tunnelling Burrower), Owner (the boss that made an object: War Banner, Brood Egg),
	  Children (a nest's mites), RallyUntil (War Banner buff), HPShown (ShowHP bar)
	Waves (Config.Waves, stepWaves): while exploring every enemy comes in a numbered wave;
	the continuous top-up below only runs during boss fights (or with waves off).
	Pacing (Config.Pacing, waves off): calm at run / stage start, build-up between mini-waves, a lull
	after each mini-wave, first-appearance callouts with a small intro group, scheduled
	elites, nests on later stages (Config.Pacing.Nests). The boss encounter itself is
	BossAI (data: BossData); the stage's boss id comes from StageManager.
	Run items hook in here (ItemSystem): crits and Storm Charm in Damage, kill procs in Kill;
	the Bargain Shrine's enemy HP (LootSystem.EnemyHPMult) in Spawn.
	Replication: the boss HP attributes and each player's "Kills" attribute are written at
	10 Hz from Step (not on every hit / kill); rp.Kills itself is always exact.
	[stream D] Director run (StageManager.IsDirector, SetDirector): waves, nests, top-ups and
	scheduled elites are off; stepDirector spawns the Cliffwood roster at the brief's rate
	(RunConfig.Director.Spawn) within the alive caps, 35-70 studs from a living hero on reachable
	ground (directorSpawnPoint, also used by SpawnPoint / recycling). Extra record fields: Kind
	(Normal / Tough / Elite / Boss), ContactCooldown, AttackDamage (ranged / slam hits), StuckAt /
	StuckPos / StuckCount / RepathUntil / RepathDir (EnemyAI stuck repath), SlamReady, ChargeHits.
]]

local Config = require(game:GetService("ReplicatedStorage").Shared.Config)
local EnemyData = require(game:GetService("ReplicatedStorage").Shared.EnemyData)
local Remotes = require(game:GetService("ReplicatedStorage").Shared.Remotes)
local ModelBuilder = require(script.Parent.ModelBuilder)
local SpatialGrid = require(script.Parent.SpatialGrid)
local Fx = require(script.Parent.Fx)
local DamageNumbers = require(script.Parent.DamageNumbers)
local AffixSight = require(script.Parent.AffixSight) -- first-sight notice for elite affixes (AffixIcons)
local BossAI = require(script.Parent.BossAI)
local HeightGrid = require(script.Parent.HeightGrid)
local RunConfig = require(game:GetService("ReplicatedStorage").SwarmV2.Run.RunConfig)
local Nav = RunConfig.Nav
-- [stream D] the run director (RunConfig.Director; StageManager runs its phases)
local Dir: { [string]: any } = (RunConfig :: any).Director or {}
local BossData = require(game:GetService("ReplicatedStorage").Shared.BossData)

local EnemySpawner = {}

local ctx
local rng = Random.new()
local PARK = CFrame.new(Config.Enemies.ParkPosition)

EnemySpawner.Active = {} :: { any } -- living enemies (dense array)
EnemySpawner.Grid = SpatialGrid.new(Config.Projectiles.CellSize) -- rebuilt by EnemyAI
EnemySpawner.Boss = nil :: any?

local pool: { any } = {}
local free: { number } = {}
local folder: Folder
local uidCounter = 0
local spawnTimer = 0
local bossDirty = false
local bossAttrTimer = 0
local killsAttrTimer = 0
-- pacing (Config.Pacing); reset when a new run starts (the run clock goes back)
local lastRunTime = math.huge
local calmLeft = 0
local sinceWave = 0
local lullLeft = 0
local nextEliteAt = 0
local seen: { [string]: boolean } = {}
-- waves (Config.Waves): numbered across the whole run
local waveStage = 0 -- stage the wave state belongs to (a new stage starts with a breather)
local runWave = 0 -- the current / last wave number of this run
local lastWaveBase = 0 -- the last normal wave's size per player-count density (waves never shrink)
local stageFirstWave = false -- the next wave is the first of its stage (a loud announcement)
local wavePhase = "Off" -- "Off" | "Breather" | "Pouring" | "Fighting"
local waveTimer = 0 -- Breather: seconds to the next wave; Fighting: seconds before it moves on anyway
local waveTotal = 0 -- enemies queued for the current wave
local waveQueue: { { Type: string, Angle: number, Spread: number, Elite: boolean, Rp: any } } = {}
local burstLeft = 0 -- seconds left to pour the rest of it in
local waveSeq = 0 -- every wave of the server's life (SwarmState WaveSeq: clients announce on change)
-- nests (Config.Pacing.Nests), per stage
local nestStage = 0
local nestStageTime = 0
local nestsMade = 0
local nextNestAt = 0
-- [stream D] director spawning (stepDirector): on for a single-map director run
local directorOn = false
local dirBudget = 0 -- enemies owed by the spawn rate (capped: no burst after a full cap)
local dirTick = 0
local rosterByType: { [string]: any } = {}
for _, entry in ipairs(Dir.Roster or {}) do
	if type(entry) == "table" and type(entry.Type) == "string" then
		rosterByType[entry.Type] = entry
	end
end
-- what the director did this run (tests, the DEV panel): reset by SetDirector(true)
EnemySpawner.DirectorStats = {} :: { [string]: any }

------------------------------------------------------------------------------------------
-- Helpers
------------------------------------------------------------------------------------------

local function playerCount(): number
	local n = 0
	for _, rp in ipairs(ctx.RunManager.GetRunPlayers()) do
		if rp.Alive or rp.AwaitingRevive then
			n += 1
		end
	end
	return math.max(1, n)
end

local function countMult(): number
	local list = Config.Difficulty.PlayerCountMult
	return list[math.clamp(playerCount(), 1, #list)]
end

local function weightedPick(weights: { [string]: number }): string
	local total = 0
	for _, w in pairs(weights) do
		total += w
	end
	local roll = rng:NextNumber() * total
	local last = "Slime"
	for id, w in pairs(weights) do
		last = id
		roll -= w
		if roll <= 0 then
			return id
		end
	end
	return last
end

-- Living enemies matching a test (caps for Spitters, Healers, Burrowers, nests).
local function liveCount(test: (any) -> boolean): number
	local n = 0
	for _, e in ipairs(EnemySpawner.Active) do
		if e.Alive and e.Def and test(e.Def) then
			n += 1
		end
	end
	return n
end
EnemySpawner.LiveCount = liveCount

-- Clamps a ground point inside the fence (the arena's bounds; today's square without them).
local function clampToArena(x: number, z: number, margin: number): (number, number)
	return HeightGrid.ClampXZ(x, z, margin)
end
EnemySpawner.ClampToArena = clampToArena

local function randomAlivePlayer()
	local alive = {}
	for _, rp in ipairs(ctx.RunManager.GetRunPlayers()) do
		if rp.Alive and rp.Root then
			table.insert(alive, rp)
		end
	end
	if #alive == 0 then
		return nil
	end
	return alive[rng:NextInteger(1, #alive)]
end

--[[
	Picks a spawn point. ScreenEdge: a ring just off-screen around a random player,
	clamped inside the fence. ArenaEdge: just inside the fence on the side nearest that
	player. Points inside obstacles are retried.
]]
--[[
	With a height grid (HeightGrid.IsActive): a walkable spot connected to the player, at a
	path distance of Nav.SpawnMinPath-SpawnMaxPath studs (the player's flow field). Before
	the player's first field is ready, a walkable spot at that straight distance. The
	closest-to-range connected spot found is the fallback.
	TODO (camera yaw): prefer spots behind the player's camera once the client reports its
	yaw (DESIGN.md section 3; a small rate-limited remote in SwarmV2Net.Run).
]]
local function gridSpawnPoint(rp, radius: number, angle: number?): Vector3?
	local p = rp.Root.Position
	local minD, maxD = Nav.SpawnMinPath, Nav.SpawnMaxPath
	local hasField = HeightGrid.HasField(rp)
	local fallback: Vector3? = nil
	local fallbackGap = math.huge
	for attempt = 1, Nav.SpawnTries do
		local a = (angle and attempt == 1) and angle or rng:NextNumber(0, math.pi * 2)
		-- path >= straight distance, so try a little closer than the minimum too
		local r = rng:NextNumber(minD * 0.8, maxD)
		local x, z = clampToArena(p.X + math.cos(a) * r, p.Z + math.sin(a) * r, 4)
		if HeightGrid.IsWalkable(x, z) and not ctx.EnemyAI.IsBlocked(x, z, radius) then
			local d
			if hasField then
				d = HeightGrid.PathDistance(rp, x, z)
			else
				local dx, dz = x - p.X, z - p.Z
				d = math.sqrt(dx * dx + dz * dz)
			end
			if d >= minD and d <= maxD then
				return Vector3.new(x, HeightGrid.GroundY(x, z), z)
			elseif d < math.huge then
				local gap = d < minD and minD - d or d - maxD
				if gap < fallbackGap then
					fallbackGap = gap
					fallback = Vector3.new(x, HeightGrid.GroundY(x, z), z)
				end
			end
		end
	end
	return fallback
end

--[[
	[stream D] Director spawn point: on reachable walkable ground MinDistance-MaxDistance (flat)
	from `rp`, at least MinDistance from every living hero (never inside a player), its whole
	footprint on walkable cells and clear of colliders (never inside walls), and, once rp's flow
	field exists, a walking distance of at most MaxPathFactor x MaxDistance (a spot on a ledge
	with no way down is skipped). nil when no try fits (the budget waits).
]]
local function directorSpawnPoint(rp, radius: number, angle: number?): Vector3?
	local S = Dir.Spawn or {}
	local p = rp.Root.Position
	local minD, maxD = S.MinDistance or 35, S.MaxDistance or 70
	local maxPath = maxD * (S.MaxPathFactor or 2)
	local grid = HeightGrid.IsActive()
	local hasField = grid and HeightGrid.HasField(rp)
	for attempt = 1, S.Tries or 12 do
		local a = (angle and attempt == 1) and angle or rng:NextNumber(0, math.pi * 2)
		local r = rng:NextNumber(minD, maxD)
		local x, z = clampToArena(p.X + math.cos(a) * r, p.Z + math.sin(a) * r, 4 + radius)
		local dx, dz = x - p.X, z - p.Z
		local d2 = dx * dx + dz * dz
		local ok = d2 >= minD * minD and d2 <= maxD * maxD and HeightGrid.IsWalkable(x, z)
		if ok and grid then
			-- the whole body on walkable ground (not half over a cliff edge or in water)
			ok = HeightGrid.IsWalkable(x + radius, z) and HeightGrid.IsWalkable(x - radius, z)
				and HeightGrid.IsWalkable(x, z + radius) and HeightGrid.IsWalkable(x, z - radius)
		end
		if ok then
			ok = not ctx.EnemyAI.IsBlocked(x, z, radius + 0.5)
		end
		if ok then
			for _, other in ipairs(ctx.RunManager.GetRunPlayers()) do
				local root = other.Root
				if root and (other.Alive or other.AwaitingRevive or other.Downed) and not other.Eliminated then
					local ox, oz = root.Position.X - x, root.Position.Z - z
					if ox * ox + oz * oz < minD * minD then
						ok = false
						break
					end
				end
			end
		end
		if ok and hasField then
			ok = HeightGrid.PathDistance(rp, x, z) <= maxPath
		end
		if ok then
			return Vector3.new(x, HeightGrid.GroundY(x, z), z)
		end
	end
	return nil
end

function EnemySpawner.SpawnPoint(radius: number, angle: number?, around: any?): Vector3?
	local rp = (around and around.Alive and around.Root) and around or randomAlivePlayer()
	if not rp then
		return nil
	end
	if directorOn then
		return directorSpawnPoint(rp, radius, angle)
	end
	if HeightGrid.IsActive() then
		return gridSpawnPoint(rp, radius, angle)
	end
	local p = rp.Root.Position
	local c = Config.ArenaOrigin
	local half = Config.Arenas.Size / 2
	for attempt = 1, 6 do
		local x, z
		if Config.Spawn.Mode == "ArenaEdge" then
			local dx, dz = p.X - c.X, p.Z - c.Z
			local t = rng:NextNumber(-half + 4, half - 4)
			if math.abs(dx) > math.abs(dz) then
				x, z = c.X + math.sign(dx) * (half - 4), c.Z + t
			else
				x, z = c.X + t, c.Z + math.sign(dz) * (half - 4)
			end
		else
			local a = (angle and attempt == 1) and angle or rng:NextNumber(0, math.pi * 2)
			local r = Config.Spawn.ScreenRadius + rng:NextNumber(-Config.Spawn.ScreenRadiusJitter, Config.Spawn.ScreenRadiusJitter)
			x, z = p.X + math.cos(a) * r, p.Z + math.sin(a) * r
		end
		x, z = clampToArena(x, z, 4)
		if not ctx.EnemyAI.IsBlocked(x, z, radius) then
			return Vector3.new(x, c.Y, z)
		end
	end
	return nil
end

-- Sets an enemy's current behaviour (EnemyAI / BossAI); the body attribute "Act" drives
-- the client's poses (swelling, rearing up, dizzy ...). seconds = the behaviour's timer.
function EnemySpawner.SetAct(e, act: string?, seconds: number?)
	e.ActTimer = seconds or 0
	if e.Act ~= act then
		e.Act = act
		e.Part:SetAttribute("Act", act)
	end
end

-- "New: Spitter - dodge the acid", once per run, the first time a type spawns.
local function introduce(typeId: string): boolean
	if seen[typeId] then
		return false
	end
	seen[typeId] = true
	local def = EnemyData.Enemies[typeId]
	-- Discovery clues live in the manual journal; this return still paces new enemy groups.
	return def ~= nil and def.Intro ~= nil
end

-- A living player charging the portal while exploring: inside its ring (the same radius
-- StageManager charges with) while it can be charged. Only the charge itself holds the next
-- wave back, and a charge summons the boss in Config.Stages.ChargeSeconds. (It used to be
-- the ring + 4 studs, also while dormant: a hero standing just outside the ring held every
-- wave off for as long as they liked, a risk-free spot to idle for survival gold. WORLD
-- audit W-03, tools/preview/scenes/world-regression.luau.)
local function nearPortal(): boolean
	local p = ctx.StageManager.GetPhase() == "Explore" and ctx.StageManager.PortalPosition()
	if not p then
		return false
	end
	if (tonumber(Remotes.State():GetAttribute("PortalLockLeft")) or 0) > 0 then
		return false -- dormant: standing there charges nothing
	end
	local r = Config.Stages.PortalRadius
	local r2 = r * r
	for _, rp in ipairs(ctx.RunManager.GetRunPlayers()) do
		local root = rp.Alive and rp.Root
		if root then
			local dx, dz = root.Position.X - p.X, root.Position.Z - p.Z
			if dx * dx + dz * dz <= r2 then
				return true
			end
		end
	end
	return false
end

-- Live-target multiplier from the pacing curve (calm, lull, build-up).
local function pacingMult(): number
	local P = Config.Pacing
	if calmLeft > 0 then
		return P.CalmMult
	end
	if lullLeft > 0 then
		return P.LullMult
	end
	local u = math.clamp(sinceWave / math.max(1, Config.Run.MiniWaveInterval), 0, 1)
	return P.BuildUpFrom + (P.BuildUpTo - P.BuildUpFrom) * u
end

------------------------------------------------------------------------------------------
-- Spawning
------------------------------------------------------------------------------------------

--[[
	Spawns an enemy of `typeId` at a ground position.
	opts.Elite: 2x size, 5x HP, drops a chest, one affix (opts.Affix or random).
	opts.Boss: boss stats (opts.BossData = the BossData entry: HPMult, ContactDamage).
	opts.Force: past the MaxLive cap (boss objects: a banner, eggs; the pool still limits).
	opts.HP: a fixed max HP (a War Banner's share of the boss's HP).
	opts.BossHP / BossContact / BossDmgScale: a boss's exact max HP, contact damage and attack
	damage multiplier (the director's Basin Breaker).
	[stream D] On a director run the Cliffwood roster's types (RunConfig.Director.Roster) get the
	director's stats whatever spawns them: HP = coeff x B x party x minute, contact / attack damage
	= coeff x H0 x party x minute (N and t at this spawn), the roster speed; elites x Elite.HPMult /
	DamageMult (no affix unless Elite.Affixes). Every enemy gets e.Kind (Normal / Tough / Elite /
	Boss) for the XP / gold rules.
]]
function EnemySpawner.Spawn(typeId: string, position: Vector3, opts: { Elite: boolean?, Boss: boolean?, Affix: string?, Force: boolean?, HP: number?, BossData: any?, BossHP: number?, BossContact: number?, BossDmgScale: number? }?)
	local def = EnemyData.Enemies[typeId]
	if not def then
		return nil
	end
	local isBoss = opts and opts.Boss or false
	if not isBoss and not (opts and opts.Force) and #EnemySpawner.Active >= Config.Enemies.MaxLive then
		return nil
	end
	local index = table.remove(free)
	if not index then
		return nil
	end
	local e = pool[index]
	e.WaveId = nil -- set by pourWave for wave members
	local elite = (opts and opts.Elite) and not isBoss or false
	local tier = ctx.RunManager.GetTier()
	local D = Config.Difficulty
	local statTier = math.min(tier, D.MaxTier or tier) -- HP / damage stop growing at MaxTier
	local sizeMult = elite and Config.Enemies.EliteSizeMult or 1

	local stages = ctx.StageManager
	local hp
	local bossData = opts and opts.BossData
	-- [stream D] director stats for the roster types (N and the minute at this spawn)
	local dirEntry = (directorOn and not isBoss) and rosterByType[typeId] or nil
	local F = dirEntry and stages.Formula or nil
	local dirN = dirEntry and stages.PartyN() or 1
	local dirT = dirEntry and stages.DirectorMinutes() or 0
	local EliteCfg = Dir.Elite or {}
	if isBoss then
		hp = (opts and opts.BossHP) or Config.Boss.HP * (bossData and bossData.HPMult or 1) * (1 + Config.Boss.HPPerExtraPlayer * (playerCount() - 1)) * stages.BossHPMult()
	elseif opts and opts.HP then
		hp = opts.HP
	elseif dirEntry and F then
		hp = F.EnemyHP(dirEntry.HP or 1, dirN, dirT) * stages.EnemyHPMult()
		if elite then
			hp *= EliteCfg.HPMult or 3
		end
	else
		hp = def.HP * (1 + statTier * D.HPPerMinute) * (1 + D.HPPerExtraPlayer * (playerCount() - 1)) * stages.EnemyHPMult()
		if elite then
			hp *= Config.Enemies.EliteHPMult
		end
	end
	if not (opts and (opts.HP or opts.BossHP)) then
		hp *= ctx.LootSystem.EnemyHPMult() -- the Bargain Shrine (1 unless sealed this stage)
	end
	local damage = (isBoss and (bossData and bossData.ContactDamage or Config.Boss.ContactDamage) or def.Damage * (1 + statTier * D.DamagePerMinute) * (elite and Config.Enemies.EliteDamageMult or 1)) * stages.DamageMult()
	local dirEliteDmg = elite and (EliteCfg.DamageMult or 1.25) or 1
	if isBoss and opts and opts.BossContact then
		damage = opts.BossContact
	elseif dirEntry and F then
		damage = F.EnemyDamage(dirEntry.Contact or 0, dirN, dirT) * dirEliteDmg * stages.DamageMult()
	end

	uidCounter += 1
	e.Uid = uidCounter
	e.Def = def
	e.Type = typeId
	e.Elite = elite
	e.Boss = isBoss
	e.Alive = true
	e.Radius = def.Radius * sizeMult
	e.Height = (def.FlyHeight or 0) + def.Size.Y * sizeMult / 2
	-- on the ground (the caller's Y is ignored); a spot off the walkable ground moves to the
	-- nearest walkable cell when there is one close by (HeightGrid)
	local px, pz = position.X, position.Z
	if not HeightGrid.IsWalkable(px, pz) then
		local nx, nz = HeightGrid.NearestWalkable(px, pz, 4)
		if nx and nz then
			px, pz = nx, nz
		end
	end
	e.Pos = Vector3.new(px, HeightGrid.GroundY(px, pz), pz)
	e.HP = hp
	e.MaxHP = hp
	e.Speed = dirEntry and (dirEntry.Speed or def.Speed) or def.Speed * math.min(1 + tier * D.SpeedPerMinute, D.SpeedCap)
	if not isBoss then
		e.Speed *= ctx.RunModifiers and ctx.RunModifiers.EnemySpeedMult() or 1 -- the Frenzy curse
	end
	e.Damage = damage
	e.Dir = Vector3.zero
	e.Knock = Vector3.zero
	e.NextContact = 0
	e.Ghost = def.Ghost == true or isBoss
	e.Erratic = def.Erratic or 0
	e.Phase = rng:NextNumber(0, math.pi * 2)
	e.ThinkSlot = rng:NextInteger(0, Config.Enemies.ThinkChunks - 1)
	-- clear everything a previous occupant of this pool slot (maybe the boss) left behind
	e.BossState = nil
	e.BossTimer = nil
	e.BossCycle = nil
	e.BossFollowup = nil
	e.RingWave = nil
	e.ChargeDir = nil
	e.SpeedOverride = nil
	e.Sep = Vector3.zero
	e.PinPos = nil
	e.Target = nil
	e.Guard = nil
	e.BossData = nil
	e.BossWarns = nil
	e.PhaseIndex = nil
	e.Act = nil
	e.ActTimer = 0
	e.Cooldown = nil
	e.Face = nil
	e.WarnId = nil
	e.GlobTarget = nil
	e.LungeDir = nil
	e.Patches = nil
	e.BurnTimer = nil
	e.SlowUntil = nil -- Chilling Aura (Garlic perk) slow
	e.StaggerUntil = nil -- the combat core's stagger and its immunity window (a recycled pool
	e.StaggerImmuneUntil = nil -- slot must not inherit them)
	e.SlowMult = nil
	e.TerrainSlow = nil -- mud / quicksand slow (BiomeHazards)
	e.Harmless = false
	e.Invulnerable = false
	e.Untargetable = false
	e.Dying = false
	e.Killer = nil
	e.Owner = nil
	e.Children = nil
	e.RallyUntil = nil
	e.Rallied = nil
	e.HPShown = nil
	e.BossObjects = nil
	e.Tunnel = nil
	e.SurfaceAt = nil
	e.HealTimer = nil
	e.SpawnTimer = nil
	e.HatchLeft = nil
	e.HitLog = nil
	e.PulseReady = nil
	e.StaticFace = nil
	e.Mines = nil
	e.PoundQueue = nil
	e.Throws = nil
	e.GustDir = nil
	e.GustLeft = nil
	e.HatchCount = nil
	e.SpawnedCount = nil
	e.NestSpots = nil
	e.RallyRadius = nil
	e.RallySpeed = nil
	e.RallyDamage = nil
	e.RallyTick = nil
	e.ChargeName = nil
	e.ChargeBlocked = nil
	e.ChargeTime = nil
	e.SummonSpots = nil
	e.SummonType = nil
	e.StormLeft = nil
	e.StormGap = nil
	e.ThrowIndex = nil
	e.HitSum = nil
	e.HitAt = nil
	e.SpawnGrace = isBoss and 0 or Config.Enemies.SpawnGrace
	e.DmgScale = (1 + statTier * D.DamagePerMinute) * (elite and Config.Enemies.EliteDamageMult or 1) * stages.DamageMult()
	-- [stream D] director fields (EnemyAI): per-player contact cooldown, attack damage, stuck
	-- tracking, the XP / gold kind
	e.ContactCooldown = dirEntry and dirEntry.ContactCooldown or nil
	e.AttackDamage = nil
	e.StuckAt = nil
	e.StuckPos = nil
	e.StuckCount = 0
	e.RepathUntil = nil
	e.RepathDir = nil
	e.SlamReady = nil
	e.ChargeHits = nil
	e.SpawnMinute = dirEntry and dirT or nil -- the director minute and party size it was scaled for
	e.SpawnN = dirEntry and dirN or nil
	-- the XP / gold kind (stream E2's XPSystem.KindOf): boss, elite, the roster's / def's Kind,
	-- else E2's own rule (Tough from its HP threshold); boss objects have none (no rewards)
	e.Kind = nil
	local kind = isBoss and "Boss" or (elite and "Elite") or (dirEntry and dirEntry.Kind) or def.Kind
	if not kind and not def.Object and ctx.XPSystem and ctx.XPSystem.KindOf then
		kind = ctx.XPSystem.KindOf(e)
	end
	e.Kind = (not def.Object) and (kind or "Normal") or nil
	if dirEntry and F then
		e.DmgScale = F.PartyDamage(dirN) * F.TimeDamage(dirT) * dirEliteDmg * stages.DamageMult()
		if dirEntry.Attack then
			e.AttackDamage = F.EnemyDamage(dirEntry.Attack, dirN, dirT) * dirEliteDmg * stages.DamageMult()
		end
	elseif isBoss and opts and opts.BossDmgScale then
		e.DmgScale = opts.BossDmgScale
	end
	-- elites: exactly one affix (director elites: none unless Elite.Affixes or asked for)
	local affix: string? = nil
	if elite and not (dirEntry and EliteCfg.Affixes == false and not (opts and opts.Affix)) then
		local list = Config.Enemies.EliteAffixes
		affix = (opts and opts.Affix and table.find(list, opts.Affix)) and opts.Affix or list[rng:NextInteger(1, #list)]
	end
	e.Affix = affix
	e.Shield = 0
	if affix == "Swift" then
		e.Speed *= Config.Enemies.Affix.Swift.SpeedMult
	elseif affix == "Shielded" then
		e.Shield = hp * Config.Enemies.Affix.Shielded.ShieldFraction
	end

	ModelBuilder.ApplyEnemyLook(e.Part, def, elite, sizeMult)
	e.Part.CFrame = CFrame.new(e.Pos + Vector3.new(0, e.Height, 0))
	e.Part:SetAttribute("Elite", elite)
	e.Part:SetAttribute("Affix", affix)
	e.Part:SetAttribute("Shield", affix == "Shielded")
	e.Part:SetAttribute("Act", nil)
	e.Part:SetAttribute("Rallied", nil)
	e.Part:SetAttribute("BannerOut", nil)
	e.Part:SetAttribute("HPFrac", def.ShowHP and 1 or nil)
	if def.Static then
		-- stationary things face a random way (a nest's openings)
		local a = rng:NextNumber(0, math.pi * 2)
		e.StaticFace = Vector3.new(math.cos(a), 0, math.sin(a))
	end
	e.Part:SetAttribute("Type", typeId) -- set last: clients rebuild the model when it changes

	table.insert(EnemySpawner.Active, e)
	e.Slot = #EnemySpawner.Active
	if ctx.JournalService then ctx.JournalService.Observe(typeId, e.Pos) end

	if isBoss then
		EnemySpawner.Boss = e
		bossDirty = true
	elseif elite then
		Fx.Sound("EliteSpawn") -- every elite (waves, altar guards, caravan); the client spaces repeats (MinGap)
	end
	return e
end

-- Ranged enemies (Spitters) alive now; Config.Enemies.MaxLiveRanged caps them.
local function liveRanged(): number
	return liveCount(function(def)
		return def.Ranged ~= nil
	end)
end
EnemySpawner.LiveRanged = liveRanged

-- Room for more Healers / Burrowers (Config.Enemies caps, a little more in a group).
local function supportRoom(): boolean
	local extra = playerCount() - 1
	return liveCount(function(def)
		return def.Support ~= nil
	end) < Config.Enemies.MaxLiveSupport + extra
end
local function burrowRoom(): boolean
	local extra = playerCount() - 1
	return liveCount(function(def)
		return def.Burrow ~= nil
	end) < Config.Enemies.MaxLiveBurrowers + extra * 2
end

--[[
	weightedPick, leaving out Ranged types when allowRanged is false, Healers / Burrowers
	over their caps, and NoWave types in a mini-wave or the surge (wave = true).
]]
local function pickType(weights: { [string]: number }, allowRanged: boolean, wave: boolean?): string
	local support, burrow = supportRoom(), burrowRoom()
	local w = {}
	for id, v in pairs(weights) do
		local def = EnemyData.Enemies[id]
		local ok = def ~= nil
			and (allowRanged or not def.Ranged)
			and (support or not def.Support)
			and (burrow or not def.Burrow)
			and not (wave and def.NoWave)
		if ok then
			w[id] = v
		end
	end
	if next(w) == nil then
		return "Slime"
	end
	return weightedPick(w)
end

-- Normal spawning toward the live target for this minute.
local function progressionTime(): number
	if directorOn then
		return ctx.StageManager.DirectorClock() -- [stream D] the director's minute (roster rows)
	end
	local from = (ctx.StageManager.GetStage() - 1) * Config.Spawn.StageProgressionSeconds
	return math.clamp(ctx.RunManager.GetRunTime(), from, from + (Config.Spawn.StageRowSpan or math.huge))
end

EnemySpawner.ProgressionTime = progressionTime

local function openingMult(): number
	if ctx.StageManager.GetStage() > 1 then return 1 end
	local progress = math.clamp(ctx.RunManager.GetRunTime() / Config.Spawn.OpeningSeconds, 0, 1)
	return Config.Spawn.OpeningMult + (1 - Config.Spawn.OpeningMult) * progress
end

local function topUp()
	if Config.Waves.Enabled and not EnemySpawner.Boss then
		return -- while exploring every enemy comes in a wave (stepWaves)
	end
	local row = EnemyData.GetSpawnRow(progressionTime())
	local target = math.floor(row.Target * countMult() * ctx.StageManager.SpawnMult() * openingMult())
	if EnemySpawner.Boss then
		-- during the Queen fight: a share of the normal target, within [min, boss cap]
		local S = Config.Stages
		target = math.max(S.BossMinionMin, math.min(Config.Boss.MinionCapDuringBoss, math.floor(target * S.BossMinionShare)))
	else
		target = math.floor(target * pacingMult())
	end
	target = math.min(target, Config.Enemies.MaxLive)
	local missing = math.min(Config.Spawn.MaxPerTick, target - #EnemySpawner.Active)
	local eliteOk = ctx.RunManager.GetRunTime() >= Config.Pacing.EliteMinTime
	local ranged = missing > 0 and liveRanged() or 0
	for _ = 1, missing do
		local typeId = pickType(row.Weights, ranged < Config.Enemies.MaxLiveRanged)
		local def = EnemyData.Enemies[typeId]
		if def.Ranged then
			ranged += seen[typeId] and 1 or Config.Pacing.IntroGroup
		end
		if not seen[typeId] then
			-- first appearance this run: a small group with a callout, so it reads
			introduce(typeId)
			local pos = EnemySpawner.SpawnPoint(def.Radius)
			if pos then
				local group = (Config.Pacing.IntroGroupOf :: any)[typeId] or Config.Pacing.IntroGroup
				for k = 1, group do
					local a = k * 2.1
					local x, z = clampToArena(pos.X + math.cos(a) * 3, pos.Z + math.sin(a) * 3, 4)
					EnemySpawner.Spawn(typeId, Vector3.new(x, Config.ArenaOrigin.Y, z))
				end
			end
			break
		end
		local stageChance = 1 + Config.Enemies.EliteStageChanceGrowth * math.min(8, ctx.StageManager.GetStage() - 1)
		local elite = eliteOk and rng:NextNumber() < Config.Enemies.EliteChance * stageChance * (ctx.RunModifiers and ctx.RunModifiers.EliteChanceMult() or 1)
		local pos = EnemySpawner.SpawnPoint(def.Radius * (elite and 2 or 1))
		if pos then
			EnemySpawner.Spawn(typeId, pos, { Elite = elite })
		end
	end
end

-- A scheduled elite (Config.Pacing.EliteFirst / EliteEvery), announced.
local function scheduledElite()
	local row = EnemyData.GetSpawnRow(progressionTime())
	local weights = {}
	for _, id in ipairs(Config.Pacing.EliteTypes) do
		if row.Weights[id] then
			weights[id] = row.Weights[id]
		end
	end
	if next(weights) == nil then
		weights = { Slime = 1 }
	end
	local typeId = weightedPick(weights)
	local def = EnemyData.Enemies[typeId]
	local pos = EnemySpawner.SpawnPoint(def.Radius * Config.Enemies.EliteSizeMult)
	local e = pos and EnemySpawner.Spawn(typeId, pos, { Elite = true }) or nil
	if e then
		seen[typeId] = true
		ctx.RunManager.Broadcast(string.format("An elite %s %s hunts you!", e.Affix or "", def.DisplayName or typeId), Color3.fromRGB(255, 205, 120), nil, { Id = "elite", Class = "Critical" })
	end
end

-- A nest (EnemyData.Nest) a little way from a random living player, on clear ground
-- away from the portal. Returns the enemy or nil.
local function spawnNest()
	local rp = randomAlivePlayer()
	if not rp then
		return nil
	end
	local N = Config.Pacing.Nests
	local def = EnemyData.Enemies.Nest
	local portal = ctx.StageManager.PortalPosition()
	for _ = 1, 10 do
		local a = rng:NextNumber(0, math.pi * 2)
		local d = rng:NextNumber(N.Distance[1], N.Distance[2])
		local p = rp.Root.Position
		local x, z = clampToArena(p.X + math.cos(a) * d, p.Z + math.sin(a) * d, 12)
		local nearPortal = portal and ((Vector3.new(x, portal.Y, z) - portal).Magnitude < Config.Stages.PortalRadius + 8)
		if not nearPortal and not ctx.EnemyAI.IsBlocked(x, z, def.Radius + 1.5) then
			local e = EnemySpawner.Spawn("Nest", Vector3.new(x, Config.ArenaOrigin.Y, z))
			if e then
				if not introduce("Nest") then
					ctx.RunManager.Broadcast("A Nest takes root nearby!", Color3.fromRGB(255, 205, 120), nil, { Id = "nest.spawn" })
				end
				Fx.Warn("pop", x, z, def.Radius * 2.5, "dust")
				return e
			end
		end
	end
	return nil
end
EnemySpawner.SpawnNest = spawnNest

-- Nests on later stages (Config.Pacing.Nests), only while exploring.
local function stepNests(dt: number, runTime: number)
	if Config.Waves.Enabled then
		return -- waves plant nests themselves (Config.Waves.NestEveryWaves)
	end
	local N = Config.Pacing.Nests
	local stage = ctx.StageManager.GetStage()
	if stage ~= nestStage then
		nestStage = stage
		nestStageTime = 0
		nestsMade = 0
		nextNestAt = N.FirstStageTime
	end
	if ctx.StageManager.GetPhase() ~= "Explore" then
		return
	end
	nestStageTime += dt
	if nestStageTime < nextNestAt then
		return
	end
	local cap = N.PerStage + (stage >= 3 and 1 or 0)
	local alive = liveCount(function(def)
		return def.Spawner ~= nil
	end)
	if (stage > 1 or runTime >= N.Stage1RunTime) and nestsMade < cap and alive < N.MaxAlive then
		if spawnNest() then
			nestsMade += 1
			nextNestAt = nestStageTime + N.Every
		else
			nextNestAt = nestStageTime + 3 -- no clear spot right now: try again soon
		end
	else
		nextNestAt = nestStageTime + 5
	end
end

-- Compass word for a spawn direction (x, z offset from the player; -Z is north).
local function compass(a: number): string
	local dx, dz = math.cos(a), math.sin(a)
	if math.abs(dx) > math.abs(dz) then
		return dx > 0 and "east" or "west"
	end
	return dz > 0 and "south" or "north"
end

--[[
	WAVES (Config.Waves; owner: "ALL the enemies come in waves. Wave 1 is easy, wave 2 a
	little harder, wave 3 even harder"). While exploring there is no continuous spawning:
	  Breather  a short countdown (SwarmState WaveNext = the run time the wave starts); it
	            waits while someone stands at the portal (charging it)
	  Pouring   wave N (counted across the whole run, SwarmState Wave / WaveSeq) is
	            announced (StageUI: big "WAVE N" banner, horn, red screen-edge glow from
	            WaveSides / WaveAngle) and pours in over BurstSeconds from 1-3 sides
	  Fighting  until at most ClearShare of it is alive (SwarmState WaveLeft), or MaxSeconds
	            pass, then the next breather
	Size = (Base + PerWave x (N - 1)) x player-count density x the stage spawn multiplier
	(Horde curse, Endless) x BigMult on every BigEvery-th wave. The enemy mix is the spawn
	table row at (N - 1) x RowSecondsPerWave. Elites lead waves from EliteFromWave on.
	Boss fights keep their own crowd (topUp), the surge replaces waves; a new stage starts
	with StageStartDelay of breather. Enemy HP / damage keep the run-clock scaling.
]]
local function waveAlive(): number
	local n = 0
	for _, e in ipairs(EnemySpawner.Active) do
		if e.Alive and e.WaveId == runWave then
			n += 1
		end
	end
	return n
end

-- One enemy type for wave N: Bats (wasps) only from Config.Waves.BeesFromWave (Mites
-- before, smaller groups after, Config.Pacing.WaveCountMult).
local function waveType(row, n: number, allowRanged: boolean, wave: boolean): string
	local P = Config.Pacing
	local typeId = pickType(row.Weights, allowRanged, wave)
	if P.WaveMinTime and P.WaveMinTime[typeId] and n < (Config.Waves.BeesFromWave or 0) then
		typeId = "Slime"
	end
	return typeId
end

-- Spawn-table seconds for wave N's mix: (N - 1) x RowSecondsPerWave, never below the
-- current stage's first row (stage n starts at (n-1) x Config.Spawn.StageProgressionSeconds).
local function waveRowSeconds(n: number): number
	local floor = (ctx.StageManager.GetStage() - 1) * Config.Spawn.StageProgressionSeconds
	return math.max(floor, (n - 1) * Config.Waves.RowSecondsPerWave)
end

-- Swarm pressure (Config.Stages.Pressure, SwarmState SwarmWarn 0-2) makes waves bigger.
local function pressureMult(): number
	local warn = tonumber(Remotes.State():GetAttribute("SwarmWarn")) or 0
	local list = Config.Waves.PressureMult
	return warn > 0 and list and list[math.min(warn, #list)] or 1
end

-- The faster stage-1 opening (Config.FastStart, switch Config.Features.FastStart): for
-- run waves 1..Waves while the run is on stage 1, `key`'s multiplier, else 1. Exported for
-- fast-start-regression.
local function fastStartCfg(n: number): any
	local cfg = (Config :: any).FastStart
	if not cfg or not Config.FeatureOn("FastStart") or n < 1 or n > (cfg.Waves or 0) or ctx.StageManager.GetStage() ~= 1 then
		return nil
	end
	return cfg
end
local function fastStart(n: number, key: string): number
	local cfg = fastStartCfg(n)
	return cfg and tonumber(cfg[key]) or 1
end
EnemySpawner.FastStartMult = fastStart

-- The first run's gentle opening (Config.FirstRun: waves 1..GentleWaves of an account's
-- very first Solo run, RunManager.IsFirstRunWelcome): `key`'s multiplier, else 1.
local function gentle(n: number, key: string): number
	local cfg = (Config :: any).FirstRun
	if not cfg or n > (cfg.GentleWaves or 0) or not ctx.RunManager.IsFirstRunWelcome or not ctx.RunManager.IsFirstRunWelcome() then
		return 1
	end
	return tonumber(cfg[key]) or 1
end

-- Wave N's size before the live cap and the never-shrink floor (Config.Waves), without
-- the big-wave bump: exported for the sims.
function EnemySpawner.WaveSize(n: number): number
	local W = Config.Waves
	local late = W.LateFromWave and math.max(0, n - W.LateFromWave) or 0
	local total = (W.Base + W.PerWave * (n - 1 - late) + (W.PerWaveLate or W.PerWave) * late) * countMult() * ctx.StageManager.SpawnMult() * pressureMult()
	return math.floor(total * gentle(n, "GentleSizeMult") + 0.5)
end

local function startWave()
	local W = Config.Waves
	local P = Config.Pacing
	local rp = randomAlivePlayer()
	if not rp then
		return false
	end
	runWave += 1
	local n = runWave
	local row = EnemyData.GetSpawnRow(waveRowSeconds(n))
	local big = W.BigEvery > 0 and n % W.BigEvery == 0
	-- waves never shrink (owner: "each wave harder"): a normal wave is at least the last
	-- normal one, per player-count density (a teammate leaving still shrinks it), so a new
	-- stage dropping the pressure step or the stage multiplier changing cannot undo it; a
	-- big wave is the bump on top
	local density = countMult()
	local normal = math.max(EnemySpawner.WaveSize(n), math.ceil(lastWaveBase * density))
	lastWaveBase = normal / density
	-- FastStart's bigger opening waves come after the floor above, so later waves keep their size
	local total = math.min(math.floor(normal * (big and W.BigMult or 1) * fastStart(n, "SizeMult") + 0.5), Config.Enemies.MaxLive)
	local loud = n == 1 or big or stageFirstWave -- the big banner + horn (StageUI); else a toast
	stageFirstWave = false
	local dirs = 1
	for _, at in ipairs(W.SidesAtWave) do
		if n >= at then
			dirs += 1
		end
	end
	dirs = math.min(dirs, 3)
	-- elites: x the Elite Surge curse (RunModifiers.EliteChanceMult; also Daily runs), which
	-- also adds one elite per wave
	local eliteMult = ctx.RunModifiers and ctx.RunModifiers.EliteChanceMult() or 1
	local elites = 0
	if n >= W.EliteFromWave and (big or rng:NextNumber() < math.min(1, W.EliteChance * eliteMult)) then
		elites = 1 + math.floor((n - W.EliteFromWave) / W.ElitePerWaves) + (eliteMult > 1 and 1 or 0)
		elites = math.min(W.EliteMax + (eliteMult > 1 and 1 or 0), elites)
	end
	total = math.max(dirs, total - elites) -- the elites are part of the wave, not extra
	local base = rng:NextNumber(0, math.pi * 2)
	local sides = {}
	-- the mixed share of each side: Spitters within Config.Enemies.MaxLiveRanged (counting
	-- the ones already queued), Healers / Burrowers within their caps (pickType)
	local rangedRoom = Config.Enemies.MaxLiveRanged - liveRanged()
	table.clear(waveQueue)
	-- heavy types are capped per wave (Config.Waves.TypeCap: Base + PerWave x (N - 1)); the
	-- rest of their share is re-picked (a sudden side of Brutes was the stage-3 damage spike)
	-- (the ones still alive from earlier waves count: tanky Brutes piled up wave on wave)
	local typeCount: { [string]: number } = {}
	for id in pairs(W.TypeCap or {}) do
		typeCount[id] = liveCount(function(def)
			return def.Id == id
		end)
	end
	local function capped(typeId: string): boolean
		local c = W.TypeCap and W.TypeCap[typeId]
		return c ~= nil and (typeCount[typeId] or 0) >= math.floor(c.Base + c.PerWave * (n - 1))
	end
	for d = 1, dirs do
		-- each side reads as one main type (never Ranged / NoWave) plus a mixed share
		local mainType = waveType(row, n, false, true)
		introduce(mainType)
		-- the side's full share (the sides add up to the wave total); a type that comes in
		-- smaller groups (Config.Pacing.WaveCountMult: wasps, Bombers, Brutes) fills the
		-- rest of its side from the row mix, so the wave does not shrink
		local count = math.floor(total * d / dirs) - math.floor(total * (d - 1) / dirs)
		local mixed = n >= (W.MixFromWave or 1) and math.floor(count * (W.MixShare or 0)) or 0
		local mainCount = math.floor((count - mixed) * (P.WaveCountMult and P.WaveCountMult[mainType] or 1) + 0.5)
		mixed = count - mainCount
		local angle = base + (d - 1) * (2 * math.pi / dirs) + rng:NextNumber(-0.3, 0.3)
		table.insert(sides, compass(angle))
		for k = 1, count do
			local typeId = mainType
			if k <= mixed then
				typeId = waveType(row, n, rangedRoom > 0, false)
				if typeId == mainType and P.WaveCountMult and P.WaveCountMult[mainType] then
					typeId = waveType(row, n, rangedRoom > 0, false) -- one more roll for variety
				end
				if EnemyData.Enemies[typeId].Ranged then
					rangedRoom -= 1
				end
				introduce(typeId)
			end
			for _ = 1, 3 do
				if not capped(typeId) then
					break
				end
				typeId = waveType(row, n, false, true)
			end
			if capped(typeId) then
				typeId = "Slime"
			end
			typeCount[typeId] = (typeCount[typeId] or 0) + 1
			table.insert(waveQueue, { Type = typeId, Angle = angle, Spread = W.ArcRadians, Elite = false, Rp = rp })
		end
	end
	-- the elites lead (queued last, popped first) as one of the elite types
	local eliteWeights = {}
	for _, id in ipairs(P.EliteTypes) do
		if row.Weights[id] then
			eliteWeights[id] = row.Weights[id]
		end
	end
	if next(eliteWeights) == nil then
		eliteWeights = { Slime = 1 }
	end
	for _ = 1, elites do
		table.insert(waveQueue, { Type = weightedPick(eliteWeights), Angle = base, Spread = W.ArcRadians, Elite = true, Rp = rp })
	end
	waveTotal = #waveQueue
	burstLeft = W.BurstSeconds * fastStart(n, "BurstMult")
	wavePhase = "Pouring"
	waveTimer = W.MaxSeconds * fastStart(n, "MaxSecondsMult")
	waveSeq += 1
	-- later stages: every NestEveryWaves-th wave plants a Nest (Config.Pacing.Nests caps)
	local N = P.Nests
	local stage = ctx.StageManager.GetStage()
	if stage ~= nestStage then
		nestStage = stage
		nestsMade = 0
	end
	if W.NestEveryWaves and stage >= (W.NestFromStage or 2) and n % W.NestEveryWaves == 0 and not big
		and nestsMade < N.PerStage + (stage >= 3 and 1 or 0)
		and liveCount(function(def) return def.Spawner ~= nil end) < N.MaxAlive then
		local nest = EnemySpawner.SpawnNest()
		if nest then
			nestsMade += 1
			nest.WaveId = runWave
		end
	end
	local state = Remotes.State()
	state:SetAttribute("Wave", n)
	state:SetAttribute("WaveBig", big)
	state:SetAttribute("WaveLoud", loud)
	-- one message per wave at most: a quiet wave's toast names its sides and elites; a loud
	-- wave's elites get one toast under the banner
	local where = #sides == 1 and ("from the " .. sides[1]) or (#sides .. " sides")
	local eliteText = elites == 1 and "an elite leads it" or (elites > 1 and (elites .. " elites lead it") or nil)
	if not loud then
		ctx.RunManager.Broadcast(string.format("WAVE %d · %s%s", n, where, eliteText and (" · " .. eliteText) or ""), Color3.fromRGB(255, 190, 110), nil, { Id = "wave." .. n .. ".info", Class = "Critical" })
	elseif eliteText then
		ctx.RunManager.Broadcast(string.format("Wave %d: %s!", n, eliteText), Color3.fromRGB(255, 205, 120), nil, { Id = "wave." .. n .. ".elite", Class = "Critical" })
	end
	state:SetAttribute("WaveSides", table.concat(sides, ","))
	state:SetAttribute("WaveAngle", math.floor(base * 100 + 0.5) / 100)
	state:SetAttribute("WaveNext", 0)
	state:SetAttribute("WaveSeq", waveSeq) -- last: clients read the rest when it changes
	return true
end

-- Pours the announced wave in over Config.Waves.BurstSeconds (a capped number per step).
local function pourWave(dt: number)
	local W = Config.Waves
	local per = math.min(W.MaxPerStep, math.max(1, math.ceil(#waveQueue * dt / math.max(dt, burstLeft))))
	burstLeft -= dt
	for _ = 1, per do
		local q = table.remove(waveQueue)
		if not q then
			break
		end
		if #EnemySpawner.Active >= Config.Enemies.MaxLive then
			table.insert(waveQueue, q) -- the live cap is full: the rest waits for room
			break
		end
		local def = EnemyData.Enemies[q.Type]
		local pos = EnemySpawner.SpawnPoint(def.Radius * (q.Elite and Config.Enemies.EliteSizeMult or 1), q.Angle + rng:NextNumber(-q.Spread, q.Spread), q.Rp)
		if pos then
			local e = EnemySpawner.Spawn(q.Type, pos, { Elite = q.Elite })
			if e then
				e.WaveId = runWave
				local hpMult = (1 + (W.HPPerWave or 0) * (runWave - 1)) * gentle(runWave, "GentleHPMult")
				e.HP *= hpMult
				e.MaxHP *= hpMult
				e.Shield *= hpMult
			end
		end
	end
end

local function setWaveLeft(n: number)
	local state = Remotes.State()
	if state:GetAttribute("WaveLeft") ~= n then
		state:SetAttribute("WaveLeft", n)
	end
end

local function breather(seconds: number, runTime: number)
	wavePhase = "Breather"
	waveTimer = seconds
	Remotes.State():SetAttribute("WaveNext", math.floor((runTime + seconds) * 10 + 0.5) / 10)
end

-- The wave state machine (only while exploring; Config.Waves.Enabled).
local function stepWaves(dt: number, runTime: number)
	local W = Config.Waves
	local stage = ctx.StageManager.GetStage()
	local exploring = W.Enabled and ctx.StageManager.GetPhase() == "Explore"
	if not exploring then
		if wavePhase ~= "Off" then
			wavePhase = "Off"
			table.clear(waveQueue)
			Remotes.State():SetAttribute("WaveNext", 0)
			setWaveLeft(0)
		end
		return
	end
	if stage ~= waveStage or wavePhase == "Off" then
		stageFirstWave = stage ~= waveStage
		waveStage = stage
		breather(stage <= 1 and W.FirstDelay * fastStart(runWave + 1, "FirstDelayMult") or W.StageStartDelay, runTime)
		return
	end
	if wavePhase == "Breather" then
		if next(EnemySpawner.Holds) ~= nil then
			-- held (EnemySpawner.SetHold: the first-run walkthrough): the next wave waits
			if Remotes.State():GetAttribute("WaveNext") ~= 0 then
				Remotes.State():SetAttribute("WaveNext", 0)
			end
			return
		end
		if nearPortal() then
			-- someone is charging the portal: the next wave waits for them
			if waveTimer < W.PortalHoldSeconds then
				breather(W.PortalHoldSeconds, runTime)
			end
			return
		end
		waveTimer -= dt
		if waveTimer <= 0 then
			if not startWave() then
				breather(1, runTime)
			end
		end
		return
	end
	waveTimer -= dt
	if wavePhase == "Pouring" then
		pourWave(dt)
		if #waveQueue == 0 then
			wavePhase = "Fighting"
		end
	end
	local alive = waveAlive() + #waveQueue
	setWaveLeft(alive)
	local fast = fastStartCfg(runWave)
	local clearShare = fast and tonumber(fast.ClearShare) or W.ClearShare
	if wavePhase == "Fighting" then
		local cleared = alive <= math.max(W.ClearMin or 0, math.floor(waveTotal * clearShare))
		if cleared or waveTimer <= 0 then
			-- funnel analytics: only a real clear counts, not the MaxSeconds timeout (pcalled inside)
			if cleared and ctx.Analytics then
				ctx.Analytics.OnWaveCleared(runWave)
			end
			breather(W.BreatherSeconds * fastStart(runWave, "BreatherMult"), runTime)
		end
	end
end

-- Wave holds by reason (Walkthrough.lua): while any is on, the next wave waits in its
-- breather; the last one let go resumes it (at most `delay` seconds away).
EnemySpawner.Holds = {} :: { [string]: boolean }
function EnemySpawner.SetHold(reason: string, on: boolean, delay: number?)
	EnemySpawner.Holds[reason] = on and true or nil
	if not on and next(EnemySpawner.Holds) == nil and wavePhase == "Breather" then
		breather(math.min(waveTimer, delay or waveTimer), ctx.RunManager.GetRunTime())
	end
end

-- Burst of one enemy type surrounding a random player (every MiniWaveInterval), or a
-- WAVE when Config.Waves.Enabled (startWave).
function EnemySpawner.MiniWave()
	if Config.Waves.Enabled then
		return -- waves keep their own state machine (stepWaves)
	end
	local row = EnemyData.GetSpawnRow(progressionTime())
	-- never a ring of Spitters (Ranged): a full circle of acid has no safe side; never
	-- Healers / Burrowers either (NoWave)
	local typeId = pickType(row.Weights, false, true)
	local P = Config.Pacing
	if P.WaveMinTime and P.WaveMinTime[typeId] and ctx.RunManager.GetRunTime() < P.WaveMinTime[typeId] then
		typeId = "Slime"
	end
	local def = EnemyData.Enemies[typeId]
	introduce(typeId)
	sinceWave = 0
	lullLeft = Config.Pacing.MiniWaveLull
	local count = math.floor((Config.Spawn.MiniWaveBaseCount + ctx.RunManager.GetTier() * Config.Spawn.MiniWavePerMinute) * countMult() * ctx.StageManager.SpawnMult() * openingMult()
		* (P.WaveCountMult and P.WaveCountMult[typeId] or 1))
	count = math.min(count, Config.Enemies.MaxLive - #EnemySpawner.Active)
	local offset = rng:NextNumber(0, math.pi * 2)
	for i = 1, count do
		local pos = EnemySpawner.SpawnPoint(def.Radius, offset + (i / count) * math.pi * 2)
		if pos then
			EnemySpawner.Spawn(typeId, pos)
		end
	end
	if count > 0 then
		ctx.RunManager.Broadcast("A swarm of " .. (def.DisplayName or typeId) .. "s approaches!", Color3.fromRGB(255, 160, 80), nil, { Id = "swarm.approach", Class = "Critical" })
	end
end

-- The stage boss (BossData id, default the Scorpion Queen) at `at` (the stage portal),
-- or at a spawn point near a player.
function EnemySpawner.SpawnBoss(at: Vector3?, bossId: string?, stats: { BossHP: number?, BossContact: number?, BossDmgScale: number? }?)
	if Config.Boss.ClearMinionsOnSpawn then
		for i = #EnemySpawner.Active, 1, -1 do
			EnemySpawner.Despawn(EnemySpawner.Active[i])
		end
	end
	local data = BossData.Get(bossId)
	local typeId = EnemyData.Enemies[data.EnemyType] and data.EnemyType or "Boss"
	local pos = at or EnemySpawner.SpawnPoint(EnemyData.Enemies[typeId].Radius) or Config.ArenaOrigin
	local boss = EnemySpawner.Spawn(typeId, pos, { Boss = true, BossData = data, BossHP = stats and stats.BossHP, BossContact = stats and stats.BossContact, BossDmgScale = stats and stats.BossDmgScale })
	Fx.Sound("BossRoar")
	if boss then
		Fx.Ring(boss.Pos, 30, Color3.fromRGB(255, 40, 60))
		BossAI.Begin(boss, data) -- the entrance: rises out of the ground, then the fight
	end
	return boss
end

--[[
	Portal surge: `count` enemies of this minute's mix climb out around `centre` (the
	portal) in a ring just outside its plinths. Returns how many spawned (the MaxLive cap
	or blocked spots can stop some).
]]
function EnemySpawner.SpawnSurge(count: number, centre: Vector3): number
	local row = EnemyData.GetSpawnRow(progressionTime())
	local made = 0
	local ranged = liveRanged()
	for _ = 1, count do
		local typeId = pickType(row.Weights, ranged < Config.Enemies.MaxLiveRanged, true)
		local def = EnemyData.Enemies[typeId]
		if def.Ranged then
			ranged += 1
		end
		for _attempt = 1, 4 do
			local a = rng:NextNumber(0, math.pi * 2)
			local r = rng:NextNumber(6, 14)
			local x, z = clampToArena(centre.X + math.cos(a) * r, centre.Z + math.sin(a) * r, 4)
			if def.Ghost or not ctx.EnemyAI.IsBlocked(x, z, def.Radius) then
				if EnemySpawner.Spawn(typeId, Vector3.new(x, Config.ArenaOrigin.Y, z)) then
					made += 1
				end
				break
			end
		end
	end
	if made > 0 then
		Fx.Ring(centre, 16, Color3.fromRGB(255, 90, 80))
	end
	return made
end

------------------------------------------------------------------------------------------
-- Damage and death
------------------------------------------------------------------------------------------

local function release(e)
	e.Alive = false
	-- swap-remove from Active
	local list = EnemySpawner.Active
	local slot = e.Slot
	local last = list[#list]
	if list[slot] == e then
		list[slot] = last
		last.Slot = slot
		list[#list] = nil
	else
		local i = table.find(list, e)
		if i then
			list[i] = list[#list]
			list[i].Slot = i
			list[#list] = nil
		end
	end
	e.Part.CFrame = PARK
	if e.WarnId then
		-- died mid wind-up / fuse: its telegraph goes with it
		Fx.ClearWarn(e.WarnId)
		e.WarnId = nil
	end
	if e.Act then
		e.Act = nil
		e.Part:SetAttribute("Act", nil)
	end
	if EnemySpawner.Boss == e then
		EnemySpawner.Boss = nil
		bossDirty = true -- hides the boss bar
		BossAI.ClearHazards(e)
		local state = Remotes.State()
		state:SetAttribute("BossName", nil)
		state:SetAttribute("BossPhase", 0)
	end
	table.insert(free, e.Id)
end

-- Removes an enemy with no rewards (cleanup, recycling).
function EnemySpawner.Despawn(e)
	if e.Alive then
		release(e)
		if e.Guard then
			ctx.LootSystem.OnGuardDown(e, false)
		end
	end
end

local function gemValue(weights: { [string]: number }, scale: number): number
	local kind = weightedPick(weights)
	return Config.XP.GemValues[kind] * scale
end

-- Kills an enemy and drops its rewards. `rp` = run player credited with the kill (may be
-- nil); isProc = an item proc killed it (kill procs don't chain).
function EnemySpawner.Kill(e, rp, isProc: boolean?)
	if not e.Alive then
		return
	end
	local def = e.Def
	local pos = e.Pos
	local maxHP = e.MaxHP
	local drops = {}
	release(e)
	Fx.Death(pos + Vector3.new(0, e.Height, 0), e.Part:GetAttribute("BaseColor") or def.Color, e.Radius * 2)
	Fx.Sound("EnemyDeath")
	if def.Object then
		-- a boss's banner / egg: no gems, gold, pickups, kill count or kill procs (no
		-- farming). BossAI notices it is gone through its BossObjects list.
		Fx.Warn("pop", pos.X, pos.Z, e.Radius * 1.6, def.Hatch and "hatch" or "slam")
		return
	end

	-- [stream E2] personal XP shards + team run gold + class goals (RunConfig.Economy): true =
	-- handled, so the old shared gem drops below are skipped
	local personal = ctx.XPSystem.OnEnemyKilled(e, rp, pos)
	if personal then
		-- a beaten enemy gave its XP as personal shards: the journal records the XP drop
		if rp and ctx.XPSystem.KindOf(e) then
			table.insert(drops, "XP")
		end
	elseif rng:NextNumber() < (def.GemChance or 1) then
		-- wave members (stepWaves) and, with waves on, the boss fight's crowd and the surge
		-- (the only XP for a minute or two: without it the level-ups dried up, then came 5-6
		-- at once at the portal)
		local phase = ctx.StageManager.GetPhase()
		local waveXP = (e.WaveId or (Config.Waves.Enabled and not e.Boss and (phase == "Boss" or phase == "Surge"))) and Config.Waves.XPMult or 1
		ctx.XPSystem.SpawnGem(pos, gemValue(def.Gem, (def.XPScale or 1) * waveXP))
		table.insert(drops, "XP")
	end
	if rp then
		rp.Kills += 1 -- the "Kills" attribute follows at 10 Hz (EnemySpawner.Step)
	end
	ctx.RunManager.AddTotalKill()

	if e.Boss then
		table.insert(drops, "XP")
		for _ = 1, personal and 0 or 12 do -- [stream E2]
			ctx.XPSystem.SpawnGem(pos + Vector3.new(rng:NextNumber(-8, 8), 0, rng:NextNumber(-8, 8)), Config.XP.GemValues.Large)
		end
		ctx.RunManager.OnBossKilled(pos)
	elseif e.Elite then
		-- altar guards drop gems only: the altar's chest is their reward. An elite with no
		-- killer (burnt up by the open portal's sweep, or an elite Bomb Tick blowing itself
		-- up) was not beaten: gems only, no free chest (WORLD audit W-04).
		if not e.Guard and rp then
			-- [stream D] a director run pays elites in team gold and XP only (the brief); no free
			-- chest (RunConfig.Director.Rewards.EliteFloorChest)
			local R = Dir.Rewards
			if not (directorOn and R and R.EliteFloorChest == false) then
				ctx.XPSystem.SpawnChest(pos)
				table.insert(drops, "Chest")
			end
			if ctx.MetaService and not e.WaveId then
				ctx.MetaService.OnEliteKilled(rp) -- META: the killer's Sigil roll (wave elites never)
			end
		end
		if not personal then -- [stream E2]
			ctx.XPSystem.SpawnGem(pos + Vector3.new(2, 0, 0), gemValue(EnemyData.EliteGem, 1))
		end
		table.insert(drops, "XP")
	elseif def.Reward then
		-- a destroyed nest (by a player, not swept away): gold for every living player
		-- and a few extra gems
		if rp then
			local R = def.Reward
			table.insert(drops, "Gold")
			table.insert(drops, "XP")
			local gold = math.floor(R.Gold + R.GoldPerStage * math.max(0, ctx.StageManager.GetStage() - 1))
			for _, other in ipairs(ctx.RunManager.GetRunPlayers()) do
				if other.Alive and not other.Returned then
					local paid = ctx.GoldSystem.AddRunGold(other, gold * (other.Stats and other.Stats.GoldMult or 1))
					if paid > 0 then
						Fx.Gold(pos, paid, other.Player.UserId)
					end
				end
			end
			for k = 1, personal and 0 or (R.Gems or 0) do -- [stream E2]
				local a = k * 2.4
				ctx.XPSystem.SpawnGem(pos + Vector3.new(math.cos(a) * 3, 0, math.sin(a) * 3), gemValue(def.Gem, 1))
			end
			ctx.RunManager.Broadcast(string.format("Nest destroyed! +%d gold each", gold), Color3.fromRGB(255, 215, 120), nil, { Id = "nest.destroyed" })
		end
		Fx.Warn("pop", pos.X, pos.Z, e.Radius * 2, "dust")
	else
		if rp then
			local paid = ctx.GoldSystem.OnKill(rp, pos, e.WaveId and Config.Waves.GoldChanceMult or 1)
			if paid and paid > 0 then table.insert(drops, "Gold") end
		end
		local drop = ctx.XPSystem.RollFloorPickup(pos, rp and rp.Stats.Luck or 0)
		if drop then table.insert(drops, drop) end
	end
	if ctx.JournalService then ctx.JournalService.Observe(e.Type, pos, drops) end
	if e.Guard then
		-- killed by a player (or blew itself up next to one); the portal burning the
		-- leftovers (no killer) counts as swept away, not beaten
		ctx.LootSystem.OnGuardDown(e, rp ~= nil or def.Explode ~= nil)
	end
	if rp then
		ctx.ItemSystem.OnKill(rp, pos, maxHP, isProc)
	end
end

--[[
	Server-authoritative damage. Called only by WeaponSystem / pickups / item procs, never
	by remotes. Returns true if the hit killed the enemy. A player's hit may crit and may
	call Storm Charm lightning (ItemSystem); isProc = this hit IS an item proc (no crit, no
	further procs).
]]
-- critIn ([stream B], WeaponSystem.Damage): nil = roll crits here as before (ItemSystem.ModifyHit,
-- non-proc hits only); true = the caller already rolled a crit (amount includes it: show it);
-- false = this hit never crits (no roll).
function EnemySpawner.Damage(e, amount: number, rp, knockDir: Vector3?, knockback: number?, isProc: boolean?, critIn: boolean?): boolean
	if not e.Alive or not (amount > 0) then -- (NaN too: it would make the enemy unkillable)
		return false
	end
	if e.Invulnerable or e.Dying then
		-- the Queen's entrance, burrow and collapse. A hero hitting a boss that really is
		-- protected now (not the collapse) sees a small throttled "IMMUNE" cue on it (VFX)
		if e.Boss and rp and not e.Dying and e.Invulnerable and rp.Player then
			local now = os.clock()
			if now >= (rp.ImmuneCueAt or 0) then
				rp.ImmuneCueAt = now + Config.Boss.Targeting.ImmuneCueSeconds
				Fx.PlayerEvent(rp.Player, "immune:" .. tostring(e.Id))
			end
		end
		return false
	end
	local crit = critIn == true -- [stream B]
	if rp and not isProc and critIn == nil then
		amount, crit = ctx.ItemSystem.ModifyHit(rp, amount, e) -- e: Giant's Bane
	end
	if e.Shield > 0 then
		-- Shielded elite: the orbiting plates soak damage first, then break
		local soaked = math.min(e.Shield, amount)
		e.Shield -= soaked
		amount -= soaked
		if e.Shield <= 0 and not e.Boss then
			-- (a boss's shield is the Colossus's frost armour: BossAI.stepArmor shatters it)
			e.Part:SetAttribute("Shield", false)
			Fx.Warn("pop", e.Pos.X, e.Pos.Z, e.Radius * 1.4, "shield")
		end
		if amount <= 0 then
			Fx.Hit(e.Id)
			return false
		end
	end
	if e.Boss and rp then
		amount = BossAI.ModifyHit(e, amount, rp) -- the co-op weak spot (CoopBoss.lua)
	end
	local hpBefore = math.max(0, e.HP)
	e.HP -= amount
	if rp then
		-- "Damage dealt" counts the HP really removed, not the overkill (MATH-15)
		rp.DamageDealt += math.min(amount, hpBefore)
		DamageNumbers.Add(rp.Player, e.Id, amount, crit) -- only for players with the setting on
	end
	Fx.Hit(e.Id)
	if crit then
		Fx.Crit(e.Id, rp and rp.Player and rp.Player.UserId or nil) -- gold crit star (client CombatFx); [stream G] + who crit
	end
	if knockDir and knockback and knockback > 0 and not e.Boss then -- bosses ignore knockback
		local resist = e.Def.KnockbackResist or 0
		if resist < 1 then
			e.Knock += knockDir * knockback * (1 - resist)
		end
	end
	if e.Boss then
		bossDirty = true
		if e.HP > 0 then
			BossAI.OnDamaged(e, amount) -- the Hive Mother's pulse when hit hard
		end
	end
	if e.Def.ShowHP then
		local frac = math.clamp(math.ceil(e.HP / math.max(1, e.MaxHP) * 50) / 50, 0, 1)
		if frac ~= e.HPShown then
			e.HPShown = frac
			e.Part:SetAttribute("HPFrac", frac)
		end
	end
	local died = e.HP <= 0
	if died and e.Boss then
		BossAI.StartCollapse(e, rp) -- the collapse first; BossAI kills her after it
	elseif died then
		EnemySpawner.Kill(e, rp, isProc)
	end
	if rp and not isProc then
		ctx.ItemSystem.OnHit(rp, e, amount)
	end
	return died
end

-- Bomber explosion: hurts players nearby, then the bomber dies (it still drops a gem).
function EnemySpawner.Explode(e)
	if not e.Alive then
		return
	end
	local ex = e.Def.Explode
	local radius = ex.Radius * (e.Elite and Config.Enemies.EliteBlastMult or 1)
	if e.Act == "Fuse" and e.PinPos then
		e.Pos = e.PinPos -- blast from the ring drawn at fuse start
	end
	-- the same scale as every other enemy attack (tier, elite x1.5, stage, difficulty)
	local scale = EnemySpawner.DamageScale(e)
	for _, rp in ipairs(ctx.RunManager.GetRunPlayers()) do
		if rp.Alive and rp.Root then
			local rpos = rp.Root.Position
			local d = (rpos - e.Pos) * Vector3.new(1, 0, 1)
			if d.Magnitude <= radius and HeightGrid.InBand(HeightGrid.GroundY(rpos.X, rpos.Z), e.Pos.Y, Nav.ContactBand) then
				ctx.RunManager.DamagePlayer(rp, ex.Damage * scale, (e.Def.DisplayName or e.Type) .. " explosion")
			end
		end
	end
	Fx.Explosion(e.Pos, radius)
	Fx.Sound("Explosion")
	EnemySpawner.Kill(e, nil)
end

-- Bomb pickup / revive shockwave: kill every ordinary enemy in range (never bosses, their
-- banners / eggs, nests or anything invulnerable such as a burrowed Burrower).
-- rp == nil is the open portal's sweep (StageManager.openPortal: no killer): it also takes
-- burrowed enemies and cancels every pending enemy hazard, so nothing keeps hunting the team
-- while they choose (a tunnelling Burrower from the boss fight used to survive it and surface
-- during the stage-clear choice; WORLD audit W-05).
function EnemySpawner.KillInRadius(pos: Vector3, radius: number, rp)
	local r2 = radius * radius
	local sweep = rp == nil
	if sweep then
		ctx.EnemyAI.ClearHazards(nil)
	end
	for i = #EnemySpawner.Active, 1, -1 do
		local e = EnemySpawner.Active[i]
		if e and e.Alive and not e.Boss and not e.Def.Object and not e.Def.Spawner and (sweep or not e.Invulnerable) then
			local dx, dz = e.Pos.X - pos.X, e.Pos.Z - pos.Z
			if dx * dx + dz * dz <= r2 then
				EnemySpawner.Kill(e, rp)
			end
		end
	end
end

function EnemySpawner.DespawnAll()
	for i = #EnemySpawner.Active, 1, -1 do
		release(EnemySpawner.Active[i])
	end
	EnemySpawner.Boss = nil
	EnemySpawner.Grid:Clear()
	ctx.EnemyAI.ClearHazards(nil)
	Fx.ClearWarn(0) -- every telegraph on every client
	calmLeft = Config.Pacing.StageStartCalm -- a breather on the next stage
	table.clear(waveQueue)
	local state = Remotes.State()
	state:SetAttribute("BossHP", 0)
	state:SetAttribute("BossMaxHP", 0)
	state:SetAttribute("BossName", nil)
	state:SetAttribute("BossPhase", 0)
end

-- Attack damage multiplier of an enemy (tier, elite, stage): EnemyAI / Hazards attacks.
function EnemySpawner.DamageScale(e): number
	return e.DmgScale or 1
end

------------------------------------------------------------------------------------------
-- [stream D] Director spawning (single-map run; RunConfig.Director)
------------------------------------------------------------------------------------------

-- Roster weights unlocked by this director minute (FromMinute gates).
local function directorWeights(minutes: number): { [string]: number }
	local w: { [string]: number } = {}
	for _, entry in ipairs(Dir.Roster or {}) do
		if minutes >= (entry.FromMinute or 0) and EnemyData.Enemies[entry.Type] then
			w[entry.Type] = (w[entry.Type] or 0) + (entry.Weight or 1)
		end
	end
	return w
end
EnemySpawner.DirectorWeights = directorWeights

-- Ordinary enemies alive (bosses and their objects / static things do not count to the cap).
local function ordinaryAlive(): number
	local n = 0
	for _, e in ipairs(EnemySpawner.Active) do
		if e.Alive and not e.Boss and not (e.Def and (e.Def.Object or e.Def.Static)) then
			n += 1
		end
	end
	return n
end
EnemySpawner.OrdinaryAlive = ordinaryAlive

local function resetDirectorStats()
	EnemySpawner.DirectorStats = {
		Spawned = 0,
		Elites = 0,
		ByType = {},
		FirstAt = {}, -- type -> director minute of its first spawn
		MinDist = math.huge, -- flat distance to the hero it spawned around
		MaxDist = 0,
		MinToAnyHero = math.huge,
		NoSpot = 0, -- ticks that found no valid spot
		StuckRepaths = 0,
		StuckDespawns = 0,
		LastRate = 0,
		LastCap = 0,
	}
end
resetDirectorStats()

--[[
	On (StageManager, a director run starts) / off (victory, run end). On: the roster rows are
	installed as EnemyData.RowOverride (encounters and altars spawn the Cliffwood roster), the
	stats reset. Off: the old spawn table again.
]]
-- [stream H] the director's opening (RunConfig.Director.Spawn.Opening, a proposal on top of the
-- brief's rate): the rate is x Start at 0:00 and rises linearly to x1 at Seconds; FirstEnemies
-- are owed at once so the first contact comes within a few seconds; PartyRamp also ramps the
-- party's extra spawn share in (stepDirector). nil / Seconds 0: x1.
function EnemySpawner.OpeningMult(seconds: number): number
	local O = (Dir.Spawn or {}).Opening
	local len = O and tonumber(O.Seconds) or 0
	if not O or len <= 0 or seconds >= len then
		return 1
	end
	local start = math.clamp(tonumber(O.Start) or 1, 0, 1)
	return start + (1 - start) * math.max(0, seconds) / len
end

function EnemySpawner.SetDirector(on: boolean)
	directorOn = on
	local O = (Dir.Spawn or {}).Opening
	dirBudget = on and O and math.max(0, tonumber(O.FirstEnemies) or 0) or 0
	dirTick = 0
	if on then
		resetDirectorStats()
		EnemyData.RowOverride = function(seconds: number)
			local n = ctx.StageManager.PartyN and ctx.StageManager.PartyN() or 1
			local cap = ctx.StageManager.Formula and ctx.StageManager.Formula.AliveCap(n) or 55
			return { Target = cap, Weights = directorWeights((seconds or 0) / 60) }
		end
	else
		EnemyData.RowOverride = nil
	end
end

function EnemySpawner.IsDirector(): boolean
	return directorOn
end

--[[
	The director's pressure: SpawnRate(t, N) enemies per second (x the Horde curse), banked as a
	budget (at most MaxBank ahead, so a full cap never turns into a burst) and spent every
	TickSeconds up to MaxPerTick, while ordinary enemies alive < AliveCap(N) (BossRateMult /
	BossCapMult during the boss). Types from the minute's roster weights; elites from
	Elite.FromMinute at Elite.Chance. Each spawn surrounds a random living hero
	(directorSpawnPoint). Nothing spawns after the victory / defeat or while the first-run
	walkthrough holds the swarm (EnemySpawner.Holds).
]]
local function stepDirector(dt: number)
	local SM = ctx.StageManager
	local stage = SM.RunStage and SM.RunStage() or nil
	if stage == nil or stage == "Victory" or stage == "Defeat" then
		return
	end
	if next(EnemySpawner.Holds) ~= nil then
		return
	end
	local S = Dir.Spawn or {}
	local F = SM.Formula
	local t = SM.DirectorMinutes()
	local n = SM.PartyN()
	local opening = EnemySpawner.OpeningMult(t * 60)
	local rate = F.SpawnRate(t, n) * (ctx.RunModifiers and ctx.RunModifiers.SpawnMult() or 1) * opening
	-- [stream H] Opening.PartyRamp: the extra heroes' share of the rate (Party.SpawnPerExtra) ramps
	-- in with the opening too, so a party's first level choice is not twice as early as a solo one
	local O = S.Opening
	if O and O.PartyRamp and opening < 1 and n > 1 then
		local party = F.PartySpawn(n)
		rate *= (1 + (party - 1) * opening) / party
	end
	local cap = F.AliveCap(n)
	if stage == "Boss" then
		rate *= S.BossRateMult or 0.5
		cap = math.floor(cap * (S.BossCapMult or 0.5))
	end
	local tick = S.TickSeconds or 0.25
	dirBudget = math.min(dirBudget + rate * dt, math.max((S.MaxBank or 3) + rate * tick, dirBudget))
	dirTick += dt
	if dirTick < tick then
		return
	end
	dirTick = 0
	local stats = EnemySpawner.DirectorStats
	stats.LastRate = rate
	stats.LastCap = cap
	local alive = ordinaryAlive()
	local made = 0
	local E = Dir.Elite or {}
	local eliteMult = ctx.RunModifiers and ctx.RunModifiers.EliteChanceMult() or 1
	while dirBudget >= 1 and alive < cap and made < (S.MaxPerTick or 6) do
		local rp = randomAlivePlayer()
		if not rp then
			break
		end
		local typeId = weightedPick(directorWeights(t))
		local def = EnemyData.Enemies[typeId]
		if not def then
			break
		end
		local elite = t >= (E.FromMinute or 5) and rng:NextNumber() < (E.Chance or 0.05) * eliteMult
		local pos = directorSpawnPoint(rp, def.Radius * (elite and Config.Enemies.EliteSizeMult or 1))
		if not pos then
			stats.NoSpot += 1
			break -- no valid spot this tick: the budget waits
		end
		local e = EnemySpawner.Spawn(typeId, pos, { Elite = elite })
		if not e then
			break
		end
		dirBudget -= 1
		alive += 1
		made += 1
		stats.Spawned += 1
		stats.ByType[typeId] = (stats.ByType[typeId] or 0) + 1
		if stats.FirstAt[typeId] == nil then
			stats.FirstAt[typeId] = t
		end
		if elite then
			stats.Elites += 1
		end
		local root = rp.Root
		if root then
			local d = ((pos - root.Position) * Vector3.new(1, 0, 1)).Magnitude
			stats.MinDist = math.min(stats.MinDist, d)
			stats.MaxDist = math.max(stats.MaxDist, d)
		end
		for _, other in ipairs(ctx.RunManager.GetRunPlayers()) do
			if other.Alive and other.Root then
				local d = ((pos - other.Root.Position) * Vector3.new(1, 0, 1)).Magnitude
				stats.MinToAnyHero = math.min(stats.MinToAnyHero, d)
			end
		end
	end
end

-- A stuck enemy that repathing did not free (EnemyAI): gone without rewards.
function EnemySpawner.DespawnStuck(e)
	if e.Alive and not e.Boss then
		EnemySpawner.Despawn(e)
		EnemySpawner.DirectorStats.StuckDespawns += 1
	end
end

------------------------------------------------------------------------------------------
-- Lifecycle
------------------------------------------------------------------------------------------

function EnemySpawner.Step(dt: number)
	-- Boss HP attribute at 10 Hz (not on every hit).
	bossAttrTimer += dt
	if bossDirty and bossAttrTimer >= 0.1 then
		bossAttrTimer = 0
		bossDirty = false
		local state = Remotes.State()
		local boss = EnemySpawner.Boss
		state:SetAttribute("BossHP", boss and math.max(0, math.ceil(boss.HP)) or 0)
		state:SetAttribute("BossMaxHP", boss and math.ceil(boss.MaxHP) or 0)
	end

	-- Kill counters to the HUD at 10 Hz, not on every kill (a big swarm dies by the
	-- hundreds per second); rp.Kills itself is exact and is what results / saves use.
	killsAttrTimer += dt
	if killsAttrTimer >= 0.1 then
		killsAttrTimer = 0
		for _, rp in ipairs(ctx.RunManager.GetRunPlayers()) do
			local player = rp.Player
			if player and player.Parent and player:GetAttribute("InRun") == true and player:GetAttribute("Kills") ~= rp.Kills then
				player:SetAttribute("Kills", rp.Kills)
			end
		end
	end

	if not ctx.RunManager.IsSimulating() then
		return
	end
	-- a new run started (the run clock went back): reset the pacing and the callouts
	local runTime = ctx.RunManager.GetRunTime()
	if runTime < lastRunTime - 0.5 then
		table.clear(seen)
		calmLeft = Config.Pacing.RunStartCalm
		sinceWave = 0
		lullLeft = 0
		nextEliteAt = Config.Pacing.EliteFirst
		nestStage = 0 -- a new run: the nest schedule starts over
		waveStage = 0
		runWave = 0
		lastWaveBase = 0
		wavePhase = "Off"
		table.clear(waveQueue)
		local state = Remotes.State()
		state:SetAttribute("Wave", 0)
		state:SetAttribute("WaveNext", 0)
		state:SetAttribute("WaveLeft", 0)
	end
	lastRunTime = runTime
	AffixSight.Step(dt, ctx, EnemySpawner.Active) -- once per account and affix (docs/next/AFFIX_ICONS.md)
	calmLeft = math.max(0, calmLeft - dt)
	lullLeft = math.max(0, lullLeft - dt)
	sinceWave += dt
	if directorOn then
		stepDirector(dt) -- [stream D] no waves, nests, top-ups or scheduled elites on a director run
		return
	end
	if runTime >= nextEliteAt and ctx.StageManager.GetPhase() == "Explore" and not Config.Waves.Enabled then
		nextEliteAt = runTime + Config.Pacing.EliteEvery / (1 + 0.12 * math.min(8, ctx.StageManager.GetStage() - 1))
		scheduledElite()
	end
	stepNests(dt, runTime)
	stepWaves(dt, runTime)
	spawnTimer += dt
	if spawnTimer >= Config.Spawn.TickSeconds then
		spawnTimer = 0
		if ctx.StageManager.AllowSpawning() then
			topUp()
		end
	end
end

function EnemySpawner.Init(c)
	ctx = c
	assert(Config.Enemies.MaxLive <= Config.Enemies.PoolSize, "Config.Enemies.MaxLive must be <= PoolSize")
	folder = Instance.new("Folder")
	folder.Name = "SwarmEnemies"
	folder.Parent = workspace
	for i = 1, Config.Enemies.PoolSize + 1 do -- +1 keeps a slot for the boss at the cap
		local model, body = ModelBuilder.BuildEnemyShell(i, folder)
		pool[i] = { Id = i, Uid = 0, Model = model, Part = body, Alive = false, Pos = PARK.Position, Radius = 1 }
		table.insert(free, 1, i) -- free list pops from the end; keep low ids first
	end
end

function EnemySpawner.Start() end

return EnemySpawner
