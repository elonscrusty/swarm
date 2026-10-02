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
	  Ghost, Erratic, Phase, Slot (index in Active)
]]

local Config = require(game:GetService("ReplicatedStorage").Shared.Config)
local EnemyData = require(game:GetService("ReplicatedStorage").Shared.EnemyData)
local Remotes = require(game:GetService("ReplicatedStorage").Shared.Remotes)
local ModelBuilder = require(script.Parent.ModelBuilder)
local SpatialGrid = require(script.Parent.SpatialGrid)
local Fx = require(script.Parent.Fx)

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
function EnemySpawner.SpawnPoint(radius: number, angle: number?): Vector3?
	local rp = randomAlivePlayer()
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

------------------------------------------------------------------------------------------
-- Spawning
------------------------------------------------------------------------------------------

--[[
	Spawns an enemy of `typeId` at a ground position.
	opts.Elite: 2x size, 5x HP, drops a chest. opts.Boss: boss stats.
]]
function EnemySpawner.Spawn(typeId: string, position: Vector3, opts: { Elite: boolean?, Boss: boolean? }?)
	local def = EnemyData.Enemies[typeId]
	if not def then
		return nil
	end
	local isBoss = opts and opts.Boss or false
	if not isBoss and #EnemySpawner.Active >= Config.Enemies.MaxLive then
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
	if isBoss then
		hp = Config.Boss.HP * (1 + Config.Boss.HPPerExtraPlayer * (playerCount() - 1)) * stages.BossHPMult()
	else
		hp = def.HP * (1 + statTier * D.HPPerMinute) * (1 + D.HPPerExtraPlayer * (playerCount() - 1)) * stages.EnemyHPMult()
		if elite then
			hp *= Config.Enemies.EliteHPMult
		end
	end
	local damage = (isBoss and Config.Boss.ContactDamage or def.Damage * (1 + statTier * D.DamagePerMinute) * (elite and Config.Enemies.EliteDamageMult or 1)) * stages.DamageMult()

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
	e.RingWave = nil
	e.ChargeDir = nil
	e.SpeedOverride = nil
	e.Sep = Vector3.zero
	e.Target = nil

	ModelBuilder.ApplyEnemyLook(e.Part, def, elite, sizeMult)
	e.Part.CFrame = CFrame.new(e.Pos + Vector3.new(0, e.Height, 0))
	e.Part:SetAttribute("Elite", elite)
	e.Part:SetAttribute("Type", typeId) -- set last: clients rebuild the model when it changes

	table.insert(EnemySpawner.Active, e)
	e.Slot = #EnemySpawner.Active

	if isBoss then
		EnemySpawner.Boss = e
		bossDirty = true
	end
	return e
end

-- Normal spawning toward the live target for this minute.
local function topUp()
	local row = EnemyData.GetSpawnRow(ctx.RunManager.GetRunTime())
	local target = math.floor(row.Target * countMult() * ctx.StageManager.SpawnMult())
	if EnemySpawner.Boss then
		-- during the Queen fight: a share of the normal target, within [min, boss cap]
		local S = Config.Stages
		target = math.max(S.BossMinionMin, math.min(Config.Boss.MinionCapDuringBoss, math.floor(target * S.BossMinionShare)))
	end
	target = math.min(target, Config.Enemies.MaxLive)
	local missing = math.min(Config.Spawn.MaxPerTick, target - #EnemySpawner.Active)
	for _ = 1, missing do
		local typeId = weightedPick(row.Weights)
		local def = EnemyData.Enemies[typeId]
		local elite = rng:NextNumber() < Config.Enemies.EliteChance
		local pos = EnemySpawner.SpawnPoint(def.Radius * (elite and 2 or 1))
		if pos then
			EnemySpawner.Spawn(typeId, pos, { Elite = elite })
		end
	end
end

-- Burst of one enemy type surrounding a random player (every MiniWaveInterval).
function EnemySpawner.MiniWave()
	local row = EnemyData.GetSpawnRow(ctx.RunManager.GetRunTime())
	local typeId = weightedPick(row.Weights)
	local def = EnemyData.Enemies[typeId]
	local count = math.floor((Config.Spawn.MiniWaveBaseCount + ctx.RunManager.GetTier() * Config.Spawn.MiniWavePerMinute) * countMult() * ctx.StageManager.SpawnMult())
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

-- The Scorpion Queen at `at` (the stage portal), or at a spawn point near a player.
function EnemySpawner.SpawnBoss(at: Vector3?)
	if Config.Boss.ClearMinionsOnSpawn then
		for i = #EnemySpawner.Active, 1, -1 do
			EnemySpawner.Despawn(EnemySpawner.Active[i])
		end
	end
	local pos = at or EnemySpawner.SpawnPoint(EnemyData.Enemies.Boss.Radius) or Config.ArenaOrigin
	local boss = EnemySpawner.Spawn("Boss", pos, { Boss = true })
	Fx.Sound("BossRoar")
	if boss then
		Fx.Ring(boss.Pos, 30, Color3.fromRGB(255, 40, 60))
	end
	return boss
end

--[[
	Portal surge: `count` enemies of this minute's mix climb out around `centre` (the
	portal) in a ring just outside its plinths. Returns how many spawned (the MaxLive cap
	or blocked spots can stop some).
]]
function EnemySpawner.SpawnSurge(count: number, centre: Vector3): number
	local row = EnemyData.GetSpawnRow(ctx.RunManager.GetRunTime())
	local made = 0
	for _ = 1, count do
		local typeId = weightedPick(row.Weights)
		local def = EnemyData.Enemies[typeId]
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
	if EnemySpawner.Boss == e then
		EnemySpawner.Boss = nil
		bossDirty = true -- hides the boss bar
	end
	table.insert(free, e.Id)
end

-- Removes an enemy with no rewards (cleanup, recycling).
function EnemySpawner.Despawn(e)
	if e.Alive then
		release(e)
	end
end

local function gemValue(weights: { [string]: number }, scale: number): number
	local kind = weightedPick(weights)
	return Config.XP.GemValues[kind] * scale
end

-- Kills an enemy and drops its rewards. `rp` = run player credited with the kill (may be nil).
function EnemySpawner.Kill(e, rp)
	if not e.Alive then
		return
	end
	local def = e.Def
	local pos = e.Pos
	release(e)
	Fx.Death(pos + Vector3.new(0, e.Height, 0), e.Part:GetAttribute("BaseColor") or def.Color, e.Radius * 2)
	Fx.Sound("EnemyDeath")

	if rng:NextNumber() < (def.GemChance or 1) then
		ctx.XPSystem.SpawnGem(pos, gemValue(def.Gem, def.XPScale or 1))
	end
	if rp then
		rp.Kills += 1
		rp.Player:SetAttribute("Kills", rp.Kills)
	end
	ctx.RunManager.AddTotalKill()

	if e.Boss then
		for _ = 1, 12 do
			ctx.XPSystem.SpawnGem(pos + Vector3.new(rng:NextNumber(-8, 8), 0, rng:NextNumber(-8, 8)), Config.XP.GemValues.Large)
		end
		ctx.RunManager.OnBossKilled(pos)
	elseif e.Elite then
		ctx.XPSystem.SpawnChest(pos)
		ctx.XPSystem.SpawnGem(pos + Vector3.new(2, 0, 0), gemValue(EnemyData.EliteGem, 1))
	else
		if rp then
			ctx.GoldSystem.OnKill(rp)
		end
		ctx.XPSystem.RollFloorPickup(pos, rp and rp.Stats.Luck or 0)
	end
end

--[[
	Server-authoritative damage. Called only by WeaponSystem / pickups, never by remotes.
	Returns true if the hit killed the enemy.
]]
function EnemySpawner.Damage(e, amount: number, rp, knockDir: Vector3?, knockback: number?): boolean
	if not e.Alive or amount <= 0 then
		return false
	end
	e.HP -= amount
	if rp then
		rp.DamageDealt += amount
	end
	Fx.Hit(e.Id)
	if knockDir and knockback and knockback > 0 then
		local resist = e.Def.KnockbackResist or 0
		if resist < 1 then
			e.Knock += knockDir * knockback * (1 - resist)
		end
	end
	if e.Boss then
		bossDirty = true
	end
	if e.HP <= 0 then
		EnemySpawner.Kill(e, rp)
		return true
	end
	return false
end

-- Bomber explosion: hurts players nearby, then the bomber dies (it still drops a gem).
function EnemySpawner.Explode(e)
	if not e.Alive then
		return
	end
	local ex = e.Def.Explode
	local radius = ex.Radius * (e.Elite and Config.Enemies.EliteSizeMult or 1)
	local D = Config.Difficulty
	local tierMult = (1 + math.min(ctx.RunManager.GetTier(), D.MaxTier or math.huge) * D.DamagePerMinute) * ctx.StageManager.DamageMult()
	for _, rp in ipairs(ctx.RunManager.GetRunPlayers()) do
		if rp.Alive and rp.Root then
			local d = (rp.Root.Position - e.Pos) * Vector3.new(1, 0, 1)
			if d.Magnitude <= radius then
				ctx.RunManager.DamagePlayer(rp, ex.Damage * tierMult)
			end
		end
	end
	Fx.Explosion(e.Pos, radius)
	Fx.Sound("Explosion")
	EnemySpawner.Kill(e, nil)
end

-- Bomb pickup / revive shockwave: kill every non-boss enemy in range.
function EnemySpawner.KillInRadius(pos: Vector3, radius: number, rp)
	local r2 = radius * radius
	for i = #EnemySpawner.Active, 1, -1 do
		local e = EnemySpawner.Active[i]
		if e and e.Alive and not e.Boss then
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
	local state = Remotes.State()
	state:SetAttribute("BossHP", 0)
	state:SetAttribute("BossMaxHP", 0)
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

	if not ctx.RunManager.IsSimulating() then
		return
	end
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
