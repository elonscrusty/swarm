-- whip-regression: the Knight's Whip against the real server modules (owner bug: "the
-- Knight has a sword glitch where it doesn't damage anyone").
-- Each case places enemies around the hero, fires one Whip swing through the real
-- WeaponSystem.Step loop and checks which enemies lost HP:
--   * all close: every enemy inside the swing's sector is hit
--   * one close + far ones in other directions: the close one is hit every swing
--   * a big enemy (boss / Nest) whose EDGE is in reach while a small enemy's CENTRE is
--     nearer but out of reach: the swing must turn to the one it can hit
--   * a burrowing Burrower right next to the hero must not steal the aim
--   * after a stage travel, and with Hero Mastery (Signature) levels applied
-- Every hit enemy must also lie inside the drawn slash (Fx.Slash yaw / reach), so the
-- picture and the damage agree.
local player = game:GetService("Players").LocalPlayer
-- [stream B] these checks are the old Sword (12 levels, forehand + backhand, Riposte): run with the
-- continuation pack's rank system off (the rank Sword, 110 / 130 degrees, 10 / 12 studs, max 6, is
-- checked by builds-sim)
require(game:GetService("ReplicatedStorage").SwarmV2.Run.RunConfig).Builds.Enabled = false
preview.startServer()
preview.advance(1)
local RM = preview.server("RunManager")
local DS = preview.server("DataService")
local Spawner = preview.server("EnemySpawner")
local Stage = preview.server("StageManager")
local Fx = preview.server("Fx")
local WeaponData = preview.shared("WeaponData")

local data = assert(DS.GetData(player), "profile missing")
-- these checks are about the old Knight: let a run play a hidden old hero (SwarmV2 RunConfig)
require(game:GetService("ReplicatedStorage").SwarmV2.Run.RunConfig).Classes.MapLegacyToDefault = false
data.SelectedCharacter = "Knight"
preview.remote("StartRun"):FireServer("Solo")
preview.advance(3)
local rp = assert(RM.GetRunPlayer(player), "run player missing")
assert(rp.CharacterId == "Knight", "the run must use the Knight")
assert(rp.Weapons.Whip, "the Knight must start with the Whip")
rp.InvulnUntil = math.huge

local FLAT = Vector3.new(1, 0, 1)
local whip = WeaponData.Weapons.Whip
local half = math.rad(whip.Params.Arc) / 2

-- the drawn slashes of the last swing
local slashes = {}
local realSlash = Fx.Slash
Fx.Slash = function(pos, yaw, reach, sweep, tier, userId)
	table.insert(slashes, { Pos = pos, Yaw = yaw, Reach = reach })
	return realSlash(pos, yaw, reach, sweep, tier, userId)
end

-- where each enemy stood when the Whip hit it (separation / knockback move it after)
local hitAt = {}
local realDamage = Spawner.Damage
Spawner.Damage = function(e, amount, r, ...)
	if r == rp and not hitAt[e] then
		hitAt[e] = e.Pos
	end
	return realDamage(e, amount, r, ...)
end

local tracked = {}
local function clearEnemies()
	for i = #Spawner.Active, 1, -1 do
		Spawner.Despawn(Spawner.Active[i])
	end
	table.clear(tracked)
end

-- an enemy `dist` studs (centre) from the hero at `deg` degrees, held still with lots of HP
local function place(id: string, deg: number, dist: number, radius: number?)
	local o = rp.Root.Position
	local a = math.rad(deg)
	local e = assert(Spawner.Spawn(id, Vector3.new(o.X + math.cos(a) * dist, o.Y, o.Z + math.sin(a) * dist), { Force = true }), id)
	e.MaxHP, e.HP = 1e7, 1e7
	e.SpeedOverride = 0
	if radius then
		e.Radius = radius
	end
	tracked[#tracked + 1] = { E = e, Deg = deg, Dist = dist, Id = id }
	return e
end

-- one swing: re-place the tracked enemies, fire the Whip once, return the set hit
local function swing(level: number?)
	local w = rp.Weapons.Whip
	if level then
		w.Level = level
	end
	-- only the test's enemies: nothing the spawner adds may become the nearest
	for i = #Spawner.Active, 1, -1 do
		local e = Spawner.Active[i]
		local mine = false
		for _, t in ipairs(tracked) do
			mine = mine or t.E == e
		end
		if not mine then
			Spawner.Despawn(e)
		end
	end
	local o = rp.Root.Position
	for _, t in ipairs(tracked) do
		local a = math.rad(t.Deg)
		t.E.Pos = Vector3.new(o.X + math.cos(a) * t.Dist, t.E.Pos.Y, o.Z + math.sin(a) * t.Dist)
		t.E.Knock = Vector3.zero
		t.E.HP = 1e7
	end
	table.clear(slashes)
	table.clear(hitAt)
	preview.advance(0.05) -- the grid is rebuilt with the new positions
	for _, t in ipairs(tracked) do
		local a = math.rad(t.Deg)
		t.E.Pos = Vector3.new(o.X + math.cos(a) * t.Dist, t.E.Pos.Y, o.Z + math.sin(a) * t.Dist)
	end
	w.Timer = 0
	preview.advance(0.3)
	w.Timer = 1e9 -- hold the next swing until the test asks
	local hit = {}
	for _, t in ipairs(tracked) do
		if t.E.HP < 1e7 then
			hit[t] = true
		end
	end
	-- the drawn slash covers every enemy that was hit
	for t in pairs(hit) do
		local covered = false
		for _, s in ipairs(slashes) do
			local dir = Vector3.new(-math.sin(s.Yaw), 0, -math.cos(s.Yaw))
			local rel = ((hitAt[t.E] or t.E.Pos) - s.Pos) * FLAT
			local d = rel.Magnitude
			local inner = d <= 1.5 + t.E.Radius
			local off = d > 1e-3 and math.acos(math.clamp(rel:Dot(dir) / d, -1, 1)) - half or 0
			local edge = off <= 0 or (off < math.pi / 2 and d * math.sin(off) <= t.E.Radius + 0.15)
			if d <= s.Reach + t.E.Radius + 0.5 and (inner or edge) then
				covered = true
			end
		end
		assert(covered, string.format("a %s at %d deg was damaged outside the drawn slash", t.Id, t.Deg))
	end
	return hit
end

local failures = {}
local function check(label: string, ok: boolean, detail: string?)
	if ok then
		preview.log("PASS " .. label)
	else
		preview.log("FAIL " .. label .. (detail and (": " .. detail) or ""))
		table.insert(failures, label)
	end
end

local function runCases(tag: string)
	-- 1) all close, in a 120 degree fan: all are hit, every swing
	clearEnemies()
	for _, deg in ipairs({ -60, -30, 0, 30, 60 }) do
		place("Slime", deg, 4.5)
	end
	local all = true
	for _ = 1, 3 do
		local hit = swing()
		for _, t in ipairs(tracked) do
			all = all and hit[t] == true
		end
	end
	check(tag .. " all close enemies hit every swing", all)

	-- 2) one close enemy, far ones in the other directions
	for _, close in ipairs({ 0, 90, 200, 300 }) do
		clearEnemies()
		local target = place("Slime", close, 4)
		place("Skeleton", close + 120, 14)
		place("Bat", close + 180, 20)
		place("Brute", close - 100, 26)
		local every = true
		for _ = 1, 3 do
			local hit = swing()
			every = every and hit[tracked[1]] == true
		end
		check(string.format("%s close enemy at %d deg hit every swing (far ones elsewhere)", tag, close), every and target.Alive)
	end

	-- 3) a big enemy's edge in reach, a small enemy's centre nearer but out of reach
	clearEnemies()
	local reach = whip.Params.Reach
	place("Nest", 0, reach + 2.0) -- Nest radius 2.6: its edge is 4.4+... inside reach
	place("Slime", 180, reach + 1.9) -- centre nearer than the Nest's, edge out of reach
	local nestHit = true
	for _ = 1, 3 do
		nestHit = nestHit and swing()[tracked[1]] == true
	end
	check(tag .. " Nest in reach hit while a nearer-centred enemy is out of reach", nestHit)

	clearEnemies()
	place("Brute", 90, reach + 1.6, 6) -- boss-sized body: edge 2.6 studs inside reach
	place("Slime", 270, reach + 1.5)
	local bigHit = true
	for _ = 1, 3 do
		bigHit = bigHit and swing()[tracked[1]] == true
	end
	check(tag .. " boss-sized enemy in reach hit while a nearer-centred enemy is out of reach", bigHit)

	-- 4) a burrowing Burrower next to the hero must not steal the aim
	clearEnemies()
	local slime = place("Slime", 45, 4.5)
	local burrower = place("Burrower", 225, 2)
	preview.advance(0.1) -- it goes underground on its first step
	local underground = burrower.Untargetable == true
	local ok = true
	for _ = 1, 3 do
		burrower.Untargetable, burrower.Invulnerable = true, true
		ok = ok and swing()[tracked[1]] == true
	end
	check(tag .. " burrowed Burrower beside the hero does not steal the swing", ok and underground and slime.Alive,
		"underground=" .. tostring(underground))
end

runCases("stage 1:")

-- after a stage travel
local before = Stage.GetStage()
local travelled = Stage.DevNextStage()
for _ = 1, 30 do
	preview.advance(0.5)
	if Stage.GetStage() ~= before and Stage.GetPhase() ~= "Travel" and RM.IsSimulating() then
		break
	end
end
rp = assert(RM.GetRunPlayer(player), "run player missing after travel")
rp.InvulnUntil = math.huge
check("stage travel happened", travelled and Stage.GetStage() ~= before, "stage " .. tostring(Stage.GetStage()))
runCases("after travel:")

-- Hero Mastery: Signature + stat levels in the run's Meta, stats recomputed
rp.Meta = rp.Meta or {}
rp.Meta.Signature = 5
rp.Meta.Might, rp.Meta.Armor, rp.Meta.MaxHP, rp.Meta.Speed = 5, 5, 5, 5
preview.server("LevelUpSystem").RecomputeStats(rp)
local s = rp.Stats
check("mastery stats are sane", s.Might > 0 and s.AreaMult > 0 and s.Might == s.Might and s.AreaMult == s.AreaMult,
	string.format("Might=%s Area=%s", tostring(s.Might), tostring(s.AreaMult)))
runCases("mastery:")

-- a levelled Whip (two swings: forehand toward the target, backhand opposite)
clearEnemies()
place("Slime", 0, 4.5)
place("Slime", 180, 4.5)
local both = true
for _ = 1, 3 do
	local hit = swing(4)
	both = both and hit[tracked[1]] == true and hit[tracked[2]] == true
end
check("level 4 Whip: forehand and backhand both land", both)

Fx.Slash = realSlash
Spawner.Damage = realDamage
if #failures > 0 then
	error("whip-regression FAILED: " .. table.concat(failures, "; "))
end
preview.log("whip-regression: all cases PASS")
