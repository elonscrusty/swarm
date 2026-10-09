--!strict
--[[
	SwarmV2/Run/ClassGoals.lua  (ServerScriptService.SwarmV2.Run.ClassGoals)
	OWNER: gameplay track, stream E2. Class unlock goal progress (docs/redesign/DECISIONS.md C3,
	docs/redesign/continuation/GAMEPLAY_PLAN.md "Unlock goals").

	Counts, per run and only from confirmed server events, what the lobby's class goals read
	(ClassCatalog Goal.Stat), on the run record (rp.ClassGoals):
	  XP           eligible run XP collected (personal shards and the boss grant; base value)
	                 XPSystem.GiveShardXP -> AddXP
	  Distance     legitimate horizontal studs: root positions sampled at Economy.ClassGoals
	                 SampleHz, each step bounded by the permitted speed (stat speed, rush,
	                 terrain, a validated dash's allowance, at least SpeedFloor) x SpeedSlack;
	                 a longer step (teleport, rescue, reconnect, travel) counts nothing; no
	                 counting while downed, frozen, travelling or loading
	  Elites       elite kills, cooperative: every eligible player of the kill (XPSystem.Award)
	  BestSurvive  seconds survived in the run (the settlement's run time; best single run)
	  Chests       chests this player opened (LootSystem: a completed deliberate hold)
	  Dashes       server-validated dashes and leaps (Dash.OnDash)
	  MostWeapons  different weapons held during the run (the best single run)
	  Kills        kills credited to this player (rp.Kills, the same count as Stats.TotalKills)
	  CloseKills   kills by a close-range source within CloseRange (10) studs of the hero:
	                 WeaponSystem.OnKill with a weapon in Economy.ClassGoals.CloseWeapons (the
	                 Sword is "Whip"), WeaponData Melee / Close = true, or a source table with
	                 Dash = true (a dash effect: stream C passes it to WeaponSystem.ClassBurst)
	  Bosses       boss kills, cooperative: every eligible participant (XPSystem.GrantDirect)
	  Revives      teammate revives completed (Events "PartnerRevive"; stream E1 may call
	                 ClassGoals.OnRevive(helperRp) instead: a completion reported twice within
	                 ReviveDedupe s counts once)

	Settlement (Commit, called by RunManager.saveRunStats once per run, rp.Committed): adds
	this run's counters to the save's data.Stats.ClassGoals (created when missing, never
	reset, unknown keys kept) through DataService's profile (the one writer). Sums are added
	as deltas against what was already recorded for this run record (rp.ClassGoalsRecorded),
	so a disconnect commit (RunManager.OnPlayerRemoving keeps lifetime progress) followed by
	the final settlement, a repeated finish event or a replay never adds twice. BestSurvive
	and MostWeapons keep the best value. DEV-tainted runs add nothing.
	RefreshEarned(player): the lobby's ClassOwnership.RefreshEarned (guarded: absent = nil).
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local ServerScriptService = game:GetService("ServerScriptService")

local RunConfig = require(ReplicatedStorage:WaitForChild("SwarmV2"):WaitForChild("Run"):WaitForChild("RunConfig"))

local ClassGoals = {}

-- every goal stat, in the save (data.Stats.ClassGoals)
ClassGoals.Stats = { "XP", "Distance", "Elites", "BestSurvive", "Chests", "Dashes", "MostWeapons", "Kills", "CloseKills", "Bosses", "Revives" }
local SUMS = { "XP", "Distance", "Elites", "Chests", "Dashes", "Kills", "CloseKills", "Bosses", "Revives" }
local BESTS = { "BestSurvive", "MostWeapons" }

local FLAT = Vector3.new(1, 0, 1)

local ctx: any = nil
local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared:WaitForChild("Config")) :: any
local WeaponData = require(Shared:WaitForChild("WeaponData")) :: any

local function cfg(): any
	return ((RunConfig :: any).Economy or {}).ClassGoals or {}
end

export type Counters = {
	XP: number,
	Distance: number,
	Elites: number,
	Chests: number,
	Dashes: number,
	CloseKills: number,
	Bosses: number,
	Revives: number,
	Weapons: { [string]: boolean },
	MostWeapons: number,
	LastPos: Vector3?,
	LastAt: number,
	ReviveAt: number,
}

-- This run record's counters (created on first use; the record is new every run).
function ClassGoals.For(rp: any): Counters
	local g = rp.ClassGoals
	if type(g) ~= "table" then
		g = {
			XP = 0, Distance = 0, Elites = 0, Chests = 0, Dashes = 0, CloseKills = 0, Bosses = 0, Revives = 0,
			Weapons = {}, MostWeapons = 0, LastPos = nil, LastAt = 0, ReviveAt = -math.huge,
		}
		rp.ClassGoals = g
	end
	return g :: Counters
end

local function live(rp: any): boolean
	return type(rp) == "table" and rp.Returned ~= true and ctx ~= nil and ctx.RunManager.IsRunning()
end

local function finite(n: any): boolean
	return type(n) == "number" and n == n and n > -math.huge and n < math.huge
end

------------------------------------------------------------------------------------------
-- Events
------------------------------------------------------------------------------------------

-- Base XP of a collected personal entitlement (XPSystem.GiveShardXP).
function ClassGoals.AddXP(rp: any, amount: number)
	if live(rp) and finite(amount) and amount > 0 then
		local g = ClassGoals.For(rp)
		g.XP += amount
	end
end

-- An eligible kill (XPSystem.OnEnemyKilled): elites and bosses are cooperative credit for
-- every eligible player of the kill (`recipients`: read now, never kept).
function ClassGoals.OnEnemyKilled(_e: any, _rp: any, kind: string, recipients: { any })
	local key = if kind == "Elite" then "Elites" elseif kind == "Boss" then "Bosses" else nil
	if not key then
		return
	end
	for _, r in ipairs(recipients) do
		if live(r) then
			local g = ClassGoals.For(r) :: any
			g[key] += 1
		end
	end
end

-- A chest this player opened with a completed hold (LootSystem.openChest).
function ClassGoals.OnChestOpened(rp: any)
	if live(rp) then
		local g = ClassGoals.For(rp)
		g.Chests += 1
	end
end

-- A server-validated dash or leap (Dash.OnDash).
function ClassGoals.OnDash(rp: any)
	if live(rp) then
		local g = ClassGoals.For(rp)
		g.Dashes += 1
	end
end

-- A teammate revive this player completed (stream E1 calls this, or Events "PartnerRevive").
function ClassGoals.OnRevive(helper: any)
	if not live(helper) then
		return
	end
	local g = ClassGoals.For(helper)
	local now = os.clock()
	if now - g.ReviveAt < (tonumber(cfg().ReviveDedupe) or 1) then
		return -- the same completion reported twice
	end
	g.ReviveAt = now
	g.Revives += 1
end

-- Is this kill source close-range (a melee signature, the Sword, a dash effect)?
function ClassGoals.IsCloseSource(w: any): boolean
	if type(w) ~= "table" then
		return false
	end
	if w.Dash == true or w.Close == true then
		return true
	end
	local id = w.Id
	if type(id) ~= "string" then
		return false
	end
	local list = cfg().CloseWeapons
	if type(list) == "table" and list[id] == true then
		return true
	end
	local def = WeaponData.Weapons[id]
	return type(def) == "table" and (def.Melee == true or def.Close == true)
end

-- WeaponSystem.OnKill: a weapon kill by rp with source w of enemy e.
function ClassGoals.OnWeaponKill(rp: any, w: any, e: any)
	if not live(rp) or not ClassGoals.IsCloseSource(w) then
		return
	end
	local root: BasePart? = rp.Root
	local pos = type(e) == "table" and e.Pos
	if not root or typeof(pos) ~= "Vector3" then
		return
	end
	local range = tonumber(cfg().CloseRange) or 10
	if ((pos - root.Position) * FLAT).Magnitude <= range then
		local g = ClassGoals.For(rp)
		g.CloseKills += 1
	end
end

------------------------------------------------------------------------------------------
-- Sampling: distance and weapons held
------------------------------------------------------------------------------------------

local function weaponIds(rp: any): { string }
	local out = {}
	local order = rp.WeaponOrder
	if type(order) == "table" then
		for _, id in ipairs(order) do
			if type(id) == "string" then
				table.insert(out, id)
			end
		end
	end
	return out
end

-- The step a player may legitimately cover in `dt` seconds (studs, horizontal).
local function allowedStep(rp: any, dt: number): number
	local C = cfg()
	local stats = rp.Stats
	local speed = math.max(type(stats) == "table" and tonumber(stats.Speed) or 0, tonumber(Config.Player.BaseSpeed) or 22)
	speed *= math.max(1, tonumber(rp.TerrainSpeedMult) or 1) * math.max(1, tonumber(rp.RushMult) or 1)
	speed = math.max(speed * (tonumber(C.SpeedSlack) or 1.25), tonumber(C.SpeedFloor) or 36)
	local dashUntil = rp.DashUntil
	if type(dashUntil) == "number" and os.clock() < dashUntil + 0.25 + dt then
		local dashSpeed = tonumber(rp.DashAllow) or (tonumber(rp.DashSpeed) or 0) * 1.15
		speed = math.max(speed, dashSpeed)
	end
	return speed * dt + (tonumber(C.StepAllowance) or 1)
end

local function sample(rp: any, now: number, frozen: boolean)
	local g = ClassGoals.For(rp)
	-- different weapons held this run (only real held weapons, never offers)
	for _, id in ipairs(weaponIds(rp)) do
		if not g.Weapons[id] then
			g.Weapons[id] = true
			g.MostWeapons += 1
		end
	end
	local root: BasePart? = rp.Root
	if frozen or rp.Alive ~= true or rp.Returned or not root or not root.Parent or root.Anchored then
		g.LastPos = nil -- downed, frozen, travelling, loading: the next sample starts over
		return
	end
	local pos = root.Position
	local last = g.LastPos
	local dt = now - g.LastAt
	g.LastPos, g.LastAt = pos, now
	if not last or dt <= 0 then
		return
	end
	local step = ((pos - last) * FLAT).Magnitude
	if step <= allowedStep(rp, dt) then
		g.Distance += step
	end
	-- longer: a teleport, rescue, reconnect or something suspicious: not counted
end

function ClassGoals.SampleAll()
	if not ctx or not ctx.RunManager.IsRunning() then
		return
	end
	local frozen = not ctx.RunManager.IsSimulating() or (ctx.StageManager and ctx.StageManager.IsHolding and ctx.StageManager.IsHolding())
	local now = os.clock()
	for _, rp in ipairs(ctx.RunManager.GetRunPlayers()) do
		sample(rp, now, frozen == true)
	end
end

------------------------------------------------------------------------------------------
-- Settlement
------------------------------------------------------------------------------------------

local function count(v: any): number
	return (finite(v) and v > 0) and v or 0
end

-- This run's current totals (Kills = rp.Kills, BestSurvive = `seconds`).
function ClassGoals.Snapshot(rp: any, seconds: number?): { [string]: number }
	local g = ClassGoals.For(rp)
	return {
		XP = g.XP, Distance = g.Distance, Elites = g.Elites, Chests = g.Chests, Dashes = g.Dashes,
		Kills = count(rp.Kills), CloseKills = g.CloseKills, Bosses = g.Bosses, Revives = g.Revives,
		BestSurvive = math.floor(count(seconds)), MostWeapons = math.max(g.MostWeapons, #weaponIds(rp)),
	}
end

--[[
	Adds this run's progress to data.Stats.ClassGoals: sums as deltas against
	rp.ClassGoalsRecorded (whole units; a fraction waits for the next commit), bests as the
	maximum. Safe to call more than once for the same record. Returns the amounts added this
	call (results / tests), or nil when nothing may be written (no save, DEV-tainted run).
]]
function ClassGoals.Commit(rp: any, data: any, seconds: number?): { [string]: number }?
	if type(rp) ~= "table" or rp.DevTainted == true or type(data) ~= "table" or type(data.Stats) ~= "table" then
		return nil
	end
	local saved = data.Stats.ClassGoals
	if type(saved) ~= "table" then
		saved = {}
		data.Stats.ClassGoals = saved
	end
	local cur = ClassGoals.Snapshot(rp, seconds)
	local rec = rp.ClassGoalsRecorded
	if type(rec) ~= "table" then
		rec = {}
		rp.ClassGoalsRecorded = rec
	end
	local added: { [string]: number } = {}
	for _, key in ipairs(SUMS) do
		local d = math.floor(math.max(0, cur[key] - (tonumber(rec[key]) or 0)))
		rec[key] = (tonumber(rec[key]) or 0) + d
		saved[key] = count(saved[key]) + d
		added[key] = d
	end
	for _, key in ipairs(BESTS) do
		local v = math.floor(count(cur[key]))
		saved[key] = math.max(count(saved[key]), v)
		added[key] = v
	end
	return added
end

-- The lobby's grant (ClassOwnership.RefreshEarned, lobby track): newly unlocked class ids,
-- or nil when that module or function does not exist (yet) or failed.
function ClassGoals.RefreshEarned(player: Player): { string }?
	local v2 = ServerScriptService:FindFirstChild("SwarmV2")
	local lobby = v2 and v2:FindFirstChild("Lobby")
	local module = lobby and lobby:FindFirstChild("ClassOwnership")
	if not module or not module:IsA("ModuleScript") then
		return nil
	end
	local okReq, mod = pcall(require, module :: ModuleScript)
	if not okReq or type(mod) ~= "table" or type((mod :: any).RefreshEarned) ~= "function" then
		return nil
	end
	local ok, result = pcall((mod :: any).RefreshEarned, player)
	if not ok then
		warn("[ClassGoals] RefreshEarned failed: " .. tostring(result))
		return nil
	end
	local out = {}
	if type(result) == "table" then
		for _, id in ipairs(result) do
			if type(id) == "string" then
				table.insert(out, id)
			end
		end
	end
	return out
end

------------------------------------------------------------------------------------------
-- Boot (RunBoot)
------------------------------------------------------------------------------------------

function ClassGoals.Init(runCtx: any)
	ctx = runCtx
	runCtx.ClassGoals = ClassGoals
	local okDash, Dash = pcall(require, script.Parent:WaitForChild("Dash"))
	if okDash and type(Dash) == "table" and (Dash :: any).OnDash then
		(Dash :: any).OnDash:Connect(function(rp: any)
			ClassGoals.OnDash(rp)
		end)
	end
	if runCtx.WeaponSystem and runCtx.WeaponSystem.OnKill then
		runCtx.WeaponSystem.OnKill(ClassGoals.OnWeaponKill)
	end
	local modules = ServerScriptService:FindFirstChild("Modules")
	local events = modules and modules:FindFirstChild("Events")
	if events and events:IsA("ModuleScript") then
		local okEv, Events = pcall(require, events)
		if okEv and type(Events) == "table" and type((Events :: any).On) == "function" then
			(Events :: any).On("PartnerRevive", function(player: Player)
				local rp = runCtx.RunManager.GetRunPlayer(player)
				if rp then
					ClassGoals.OnRevive(rp)
				end
			end)
		end
	end
	local acc = 0
	RunService.Heartbeat:Connect(function(dt: number)
		acc += dt
		if acc < 1 / math.max(1, tonumber(cfg().SampleHz) or 4) then
			return
		end
		acc = 0
		local ok, err = (pcall :: any)(ClassGoals.SampleAll)
		if not ok then
			warn("[ClassGoals] sample failed: " .. tostring(err))
		end
	end)
end

return ClassGoals
