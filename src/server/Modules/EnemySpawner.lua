--[[
	EnemySpawner.lua
	Owns every enemy: the object pool (Config.Enemies.PoolSize single-Part models built at
	boot), spawning (per-minute table, mini-waves, elites, boss, the portal surge), damage
	and death/drops. Stats scale with run time (tier) and with the stage (StageManager).
	Movement and AI live in EnemyAI, which reads EnemySpawner.Active every Heartbeat.

	Enemy record fields:
	  Id (pool index, also the model name "E<Id>"), Uid (unique per spawn), Model, Part,
	  Def, Type, Elite, Boss, Alive, Pos (ground position), Height (body centre above floor),
	  Radius, HP, MaxHP, Speed, Damage, Dir, Knock (knockback velocity), NextContact,
	  Ghost, Erratic, Phase, Slot (index in Active), Guard (guarded-altar id, LootSystem),
	  Affix (elites: "Swift" | "Shielded" | "Burning"), Shield (HP the shield still soaks),
	  DmgScale (attack damage multiplier), SpawnGrace, Act / ActTimer (EnemyAI behaviours),
	  WarnId (its live telegraph), Harmless / Invulnerable / Untargetable / Dying (boss,
	  a tunnelling Burrower), Owner (the boss that made an object: War Banner, Brood Egg),
	  Children (a nest's mites), RallyUntil (War Banner buff), HPShown (ShowHP bar)
	Pacing (Config.Pacing): calm at run / stage start, build-up between mini-waves, a lull
	after each mini-wave, first-appearance callouts with a small intro group, scheduled
	elites, nests on later stages (Config.Pacing.Nests). The boss encounter itself is
	BossAI (data: BossData); the stage's boss id comes from StageManager.
	Run items hook in here (ItemSystem): crits and Storm Charm in Damage, kill procs in Kill;
	the Bargain Shrine's enemy HP (LootSystem.EnemyHPMult) in Spawn.
	Replication: the boss HP attributes and each player's "Kills" attribute are written at
	10 Hz from Step (not on every hit / kill); rp.Kills itself is always exact.
]]

local Config = require(game:GetService("ReplicatedStorage").Shared.Config)
local EnemyData = require(game:GetService("ReplicatedStorage").Shared.EnemyData)
local Remotes = require(game:GetService("ReplicatedStorage").Shared.Remotes)
local ModelBuilder = require(script.Parent.ModelBuilder)
local SpatialGrid = require(script.Parent.SpatialGrid)
local Fx = require(script.Parent.Fx)
local DamageNumbers = require(script.Parent.DamageNumbers)
local BossAI = require(script.Parent.BossAI)
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
-- waves (Config.Waves): the stage's wave count and the burst still to pour in
local waveStage = 0
local waveNumber = 0
local waveQueue: { { Type: string, Angle: number, Spread: number, Elite: boolean, Rp: any } } = {}
local waveDelay = 0 -- seconds until the announced wave pours in
local burstLeft = 0 -- seconds left to pour the rest of it in
-- nests (Config.Pacing.Nests), per stage
local nestStage = 0
local nestStageTime = 0
local nestsMade = 0
local nextNestAt = 0

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

-- Clamps a ground point inside the fence.
local function clampToArena(x: number, z: number, margin: number): (number, number)
	local c = Config.ArenaOrigin
	local h = Config.Arenas.Size / 2 - margin
	return math.clamp(x, c.X - h, c.X + h), math.clamp(z, c.Z - h, c.Z + h)
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
function EnemySpawner.SpawnPoint(radius: number, angle: number?, around: any?): Vector3?
	local rp = (around and around.Alive and around.Root) and around or randomAlivePlayer()
	if not rp then
		return nil
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

-- A living player near the portal while exploring (Config.Waves.PortalCalmRadius).
local function nearPortal(): boolean
	local W = Config.Waves
	local p = W.PortalCalmRadius and ctx.StageManager.GetPhase() == "Explore" and ctx.StageManager.PortalPosition()
	if not p then
		return false
	end
	local r2 = W.PortalCalmRadius * W.PortalCalmRadius
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
	local W = Config.Waves
	if calmLeft > 0 then
		return P.CalmMult
	end
	if lullLeft > 0 then
		return W.Enabled and W.LullMult or P.LullMult
	end
	local u = math.clamp(sinceWave / math.max(1, Config.Run.MiniWaveInterval), 0, 1)
	if W.Enabled then
		-- between waves only a light trickle, so kills and XP never fully stall
		return (W.TrickleFrom + (W.TrickleTo - W.TrickleFrom) * u) * (nearPortal() and W.PortalCalmMult or 1)
	end
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
]]
function EnemySpawner.Spawn(typeId: string, position: Vector3, opts: { Elite: boolean?, Boss: boolean?, Affix: string?, Force: boolean?, HP: number?, BossData: any? }?)
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
	local elite = (opts and opts.Elite) and not isBoss or false
	local tier = ctx.RunManager.GetTier()
	local D = Config.Difficulty
	local statTier = math.min(tier, D.MaxTier or tier) -- HP / damage stop growing at MaxTier
	local sizeMult = elite and Config.Enemies.EliteSizeMult or 1

	local stages = ctx.StageManager
	local hp
	local bossData = opts and opts.BossData
	if isBoss then
		hp = Config.Boss.HP * (bossData and bossData.HPMult or 1) * (1 + Config.Boss.HPPerExtraPlayer * (playerCount() - 1)) * stages.BossHPMult()
	elseif opts and opts.HP then
		hp = opts.HP
	else
		hp = def.HP * (1 + statTier * D.HPPerMinute) * (1 + D.HPPerExtraPlayer * (playerCount() - 1)) * stages.EnemyHPMult()
		if elite then
			hp *= Config.Enemies.EliteHPMult
		end
	end
	if not (opts and opts.HP) then
		hp *= ctx.LootSystem.EnemyHPMult() -- the Bargain Shrine (1 unless sealed this stage)
	end
	local damage = (isBoss and (bossData and bossData.ContactDamage or Config.Boss.ContactDamage) or def.Damage * (1 + statTier * D.DamagePerMinute) * (elite and Config.Enemies.EliteDamageMult or 1)) * stages.DamageMult()

	uidCounter += 1
	e.Uid = uidCounter
	e.Def = def
	e.Type = typeId
	e.Elite = elite
	e.Boss = isBoss
	e.Alive = true
	e.Radius = def.Radius * sizeMult
	e.Height = (def.FlyHeight or 0) + def.Size.Y * sizeMult / 2
	e.Pos = Vector3.new(position.X, Config.ArenaOrigin.Y, position.Z)
	e.HP = hp
	e.MaxHP = hp
	e.Speed = def.Speed * math.min(1 + tier * D.SpeedPerMinute, D.SpeedCap)
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
	-- elites: exactly one affix
	local affix: string? = nil
	if elite then
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
		ctx.RunManager.Broadcast(string.format("An elite %s %s hunts you!", e.Affix or "", def.DisplayName or typeId), Color3.fromRGB(255, 205, 120))
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
					ctx.RunManager.Broadcast("A Nest takes root nearby!", Color3.fromRGB(255, 205, 120))
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
	A WAVE (Config.Waves), started every Config.Run.MiniWaveInterval while exploring
	(StageManager): announced at once ("WAVE 3 · from the north"), then after WarnSeconds
	it pours in over BurstSeconds from 1-3 directions around one player, one enemy type per
	direction (so it reads). Size = (Base + PerMinute x difficulty minute) x the player-count
	density x the stage spawn multiplier (Endless included) x the opening ramp, growing by
	GrowPerWave per wave of the stage (up to GrowCap). Afterwards a short lull; between
	waves a light trickle keeps going (pacingMult). Config.Waves.Enabled = false brings
	back the old ring-shaped mini-wave on top of continuous spawning.
]]
local function startWave()
	local W = Config.Waves
	local P = Config.Pacing
	local stage = ctx.StageManager.GetStage()
	if stage ~= waveStage then
		waveStage = stage
		waveNumber = 0
	end
	local rp = randomAlivePlayer()
	if not rp or nearPortal() then
		return -- someone is pushing into the portal: no wave on top of them
	end
	waveNumber += 1
	local runTime = ctx.RunManager.GetRunTime()
	local row = EnemyData.GetSpawnRow(progressionTime())
	local grow = math.min(W.GrowCap, 1 + W.GrowPerWave * (waveNumber - 1))
	local total = (W.Base + ctx.RunManager.GetTier() * W.PerMinute) * countMult() * ctx.StageManager.SpawnMult() * openingMult() * grow
	local dirs = 1
	for _, at in ipairs(W.DirectionsAt) do
		if progressionTime() >= at then
			dirs += 1
		end
	end
	dirs = math.min(dirs, 3)
	local base = rng:NextNumber(0, math.pi * 2)
	local leadElite = runTime >= P.EliteMinTime and rng:NextNumber() < W.EliteLeadChance * (1 + Config.Enemies.EliteStageChanceGrowth * math.min(8, stage - 1))
	local sides = {}
	table.clear(waveQueue)
	for d = 1, dirs do
		local typeId = pickType(row.Weights, false, true)
		if P.WaveMinTime and P.WaveMinTime[typeId] and runTime < P.WaveMinTime[typeId] then
			typeId = "Slime"
		end
		introduce(typeId)
		local count = math.floor(total / dirs * (P.WaveCountMult and P.WaveCountMult[typeId] or 1) + 0.5)
		local angle = base + (d - 1) * (2 * math.pi / dirs) + rng:NextNumber(-0.3, 0.3)
		table.insert(sides, compass(angle))
		local eliteOk = leadElite and d == 1 and table.find(P.EliteTypes, typeId) ~= nil
		for k = 1, count do
			table.insert(waveQueue, { Type = typeId, Angle = angle, Spread = W.ArcRadians, Elite = eliteOk and k == 1, Rp = rp })
		end
	end
	waveDelay = W.WarnSeconds
	burstLeft = W.BurstSeconds
	sinceWave = 0
	lullLeft = W.WarnSeconds + W.BurstSeconds + W.LullSeconds
	Remotes.State():SetAttribute("Wave", waveNumber)
	if #waveQueue > 0 then
		local where = dirs == 1 and ("from the " .. sides[1]) or (dirs .. " sides")
		ctx.RunManager.Broadcast(string.format("WAVE %d · %s", waveNumber, where), Color3.fromRGB(255, 190, 110))
		Fx.Sound("Tip")
	end
end

-- Pours the announced wave in over Config.Waves.BurstSeconds (a capped number per step).
local function stepWave(dt: number)
	if #waveQueue == 0 then
		return
	end
	if waveDelay > 0 then
		waveDelay -= dt
		return
	end
	if not ctx.StageManager.AllowSpawning() or EnemySpawner.Boss then
		table.clear(waveQueue) -- the boss came (or the stage ended): drop the rest
		return
	end
	local W = Config.Waves
	local per = math.min(W.MaxPerStep, math.max(1, math.ceil(#waveQueue * dt / math.max(dt, burstLeft))))
	burstLeft -= dt
	for _ = 1, per do
		local q = table.remove(waveQueue)
		if not q then
			break
		end
		if #EnemySpawner.Active >= Config.Enemies.MaxLive then
			table.clear(waveQueue)
			break
		end
		local def = EnemyData.Enemies[q.Type]
		local pos = EnemySpawner.SpawnPoint(def.Radius * (q.Elite and Config.Enemies.EliteSizeMult or 1), q.Angle + rng:NextNumber(-q.Spread, q.Spread), q.Rp)
		if pos then
			local e = EnemySpawner.Spawn(q.Type, pos, { Elite = q.Elite })
			if e and q.Elite then
				ctx.RunManager.Broadcast(string.format("An elite %s %s leads the wave!", e.Affix or "", def.DisplayName or q.Type), Color3.fromRGB(255, 205, 120))
			end
		end
	end
end

-- Burst of one enemy type surrounding a random player (every MiniWaveInterval), or a
-- WAVE when Config.Waves.Enabled (startWave).
function EnemySpawner.MiniWave()
	if Config.Waves.Enabled then
		startWave()
		return
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
		ctx.RunManager.Broadcast("A swarm of " .. (def.DisplayName or typeId) .. "s approaches!", Color3.fromRGB(255, 160, 80))
	end
end

-- The stage boss (BossData id, default the Scorpion Queen) at `at` (the stage portal),
-- or at a spawn point near a player.
function EnemySpawner.SpawnBoss(at: Vector3?, bossId: string?)
	if Config.Boss.ClearMinionsOnSpawn then
		for i = #EnemySpawner.Active, 1, -1 do
			EnemySpawner.Despawn(EnemySpawner.Active[i])
		end
	end
	local data = BossData.Get(bossId)
	local typeId = EnemyData.Enemies[data.EnemyType] and data.EnemyType or "Boss"
	local pos = at or EnemySpawner.SpawnPoint(EnemyData.Enemies[typeId].Radius) or Config.ArenaOrigin
	local boss = EnemySpawner.Spawn(typeId, pos, { Boss = true, BossData = data })
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

	if rng:NextNumber() < (def.GemChance or 1) then
		ctx.XPSystem.SpawnGem(pos, gemValue(def.Gem, def.XPScale or 1))
		table.insert(drops, "XP")
	end
	if rp then
		rp.Kills += 1 -- the "Kills" attribute follows at 10 Hz (EnemySpawner.Step)
	end
	ctx.RunManager.AddTotalKill()

	if e.Boss then
		table.insert(drops, "XP")
		for _ = 1, 12 do
			ctx.XPSystem.SpawnGem(pos + Vector3.new(rng:NextNumber(-8, 8), 0, rng:NextNumber(-8, 8)), Config.XP.GemValues.Large)
		end
		ctx.RunManager.OnBossKilled(pos)
	elseif e.Elite then
		-- altar guards drop gems only: the altar's chest is their reward
		if not e.Guard then
			ctx.XPSystem.SpawnChest(pos)
			table.insert(drops, "Chest")
		end
		ctx.XPSystem.SpawnGem(pos + Vector3.new(2, 0, 0), gemValue(EnemyData.EliteGem, 1))
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
			for k = 1, R.Gems or 0 do
				local a = k * 2.4
				ctx.XPSystem.SpawnGem(pos + Vector3.new(math.cos(a) * 3, 0, math.sin(a) * 3), gemValue(def.Gem, 1))
			end
			ctx.RunManager.Broadcast(string.format("Nest destroyed! +%d gold each", gold), Color3.fromRGB(255, 215, 120))
		end
		Fx.Warn("pop", pos.X, pos.Z, e.Radius * 2, "dust")
	else
		if rp then
			local paid = ctx.GoldSystem.OnKill(rp, pos)
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
function EnemySpawner.Damage(e, amount: number, rp, knockDir: Vector3?, knockback: number?, isProc: boolean?): boolean
	if not e.Alive or amount <= 0 then
		return false
	end
	if e.Invulnerable or e.Dying then
		return false -- the Queen's entrance, burrow and collapse
	end
	local crit = false
	if rp and not isProc then
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
	e.HP -= amount
	if rp then
		rp.DamageDealt += amount
		DamageNumbers.Add(rp.Player, e.Id, amount, crit) -- only for players with the setting on
	end
	Fx.Hit(e.Id)
	if crit then
		Fx.Crit(e.Id) -- gold crit star (client CombatFx)
	end
	if knockDir and knockback and knockback > 0 then
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
			local d = (rp.Root.Position - e.Pos) * Vector3.new(1, 0, 1)
			if d.Magnitude <= radius then
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
function EnemySpawner.KillInRadius(pos: Vector3, radius: number, rp)
	local r2 = radius * radius
	for i = #EnemySpawner.Active, 1, -1 do
		local e = EnemySpawner.Active[i]
		if e and e.Alive and not e.Boss and not e.Def.Object and not e.Def.Spawner and not e.Invulnerable then
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
		table.clear(waveQueue)
	end
	lastRunTime = runTime
	calmLeft = math.max(0, calmLeft - dt)
	lullLeft = math.max(0, lullLeft - dt)
	sinceWave += dt
	if runTime >= nextEliteAt and ctx.StageManager.GetPhase() == "Explore" then
		nextEliteAt = runTime + Config.Pacing.EliteEvery / (1 + 0.12 * math.min(8, ctx.StageManager.GetStage() - 1))
		scheduledElite()
	end
	stepNests(dt, runTime)
	stepWave(dt)
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
