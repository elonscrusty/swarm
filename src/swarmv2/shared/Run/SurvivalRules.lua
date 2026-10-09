--!strict
--[[
	SwarmV2/Run/SurvivalRules.lua  (ReplicatedStorage.SwarmV2.Run.SurvivalRules)
	OWNER: gameplay track, stream E1. Pure maths for the survival rules (no services, no state), so
	the server, the client and offline tests share one source. Numbers: RunConfig.Survival.

	  FallDamage(drop, maxHP, reduction)  damage of one landing (0 below SafeDrop)
	  RescueCost(maxHP, hp)                an out-of-bounds rescue's cost (never downs)
	  JumpVelocity(gravity, apex)          takeoff speed for an apex height (the one jump source)
	  StepMove(cur, target, dt, grounded)  the client move driver: accel / decel / air steering
	  CapHorizontal(v, cap)                a velocity with its flat part capped
	  AllowedSpeed(walk, boost)            the generic horizontal speed allowed (cap 34)
]]

local RunConfig = require(script.Parent:WaitForChild("RunConfig"))

local SurvivalRules = {}

local function finite(n: number): boolean
	return n == n and n ~= math.huge and n ~= -math.huge
end

-- Damage of one landing: no damage for drops up to SafeDrop studs (measured from the highest point
-- of the fall), then PerStud of max HP per extra stud, at most MaxShare. `reduction` (0..1, e.g. the
-- Spring Stitch passive's rp.Stats.FallDamageReduction) scales the result down.
function SurvivalRules.FallDamage(drop: number, maxHP: number, reduction: number?): number
	local F = RunConfig.Survival.Fall
	if not finite(drop) or not finite(maxHP) or maxHP <= 0 or drop <= F.SafeDrop then
		return 0
	end
	local share = math.min(F.MaxShare, (drop - F.SafeDrop) * F.PerStud)
	local r = reduction
	if type(r) == "number" and finite(r) then
		share *= 1 - math.clamp(r, 0, 1)
	end
	return maxHP * share
end

-- An out-of-bounds rescue's cost: MaxHPShare of max HP, never taking the last hit point.
function SurvivalRules.RescueCost(maxHP: number, hp: number): number
	if not finite(maxHP) or not finite(hp) or maxHP <= 0 or hp <= 1 then
		return 0
	end
	return math.max(0, math.min(maxHP * RunConfig.Survival.Rescue.MaxHPShare, hp - 1))
end

-- Takeoff speed that reaches `apex` studs under `gravity` (studs/s^2): sqrt(2 g h).
function SurvivalRules.JumpVelocity(gravity: number, apex: number): number
	if not finite(gravity) or not finite(apex) or gravity <= 0 or apex <= 0 then
		return 0
	end
	return math.sqrt(2 * gravity * apex)
end

--[[
	The client move driver. `cur` is the move vector used last frame and `target` the wanted one
	(flat, length 0..1, 1 = full walk speed). On the ground it moves toward the target at
	1 / AccelSeconds per second while speeding up or turning and 1 / DecelSeconds while slowing
	down, so standing to full speed takes AccelSeconds and a release stops in DecelSeconds. In the
	air the same rates are scaled by `airScale` (the air steering share, RunConfig.Movement.AirControl).
]]
function SurvivalRules.StepMove(cur: Vector3, target: Vector3, dt: number, airScale: number?): Vector3
	local M = RunConfig.Survival.Move
	if dt <= 0 then
		return cur
	end
	local diff = target - cur
	local dist = diff.Magnitude
	if dist < 1e-4 then
		return target
	end
	local slowing = target.Magnitude < cur.Magnitude - 1e-4 and target:Dot(cur) >= 0
	local seconds = if slowing then M.DecelSeconds else M.AccelSeconds
	local rate = 1 / math.max(seconds, 1e-3)
	if airScale then
		rate *= math.clamp(airScale, 0, 1)
	end
	local stepLen = rate * dt
	if stepLen >= dist then
		return target
	end
	return cur + diff.Unit * stepLen
end

-- `v` with its flat (X, Z) speed limited to `cap`; the vertical part is kept.
function SurvivalRules.CapHorizontal(v: Vector3, cap: number): Vector3
	local flat = Vector3.new(v.X, 0, v.Z)
	local speed = flat.Magnitude
	if speed <= cap or speed < 1e-6 then
		return v
	end
	local s = cap / speed
	return Vector3.new(v.X * s, v.Y, v.Z * s)
end

-- The generic horizontal speed allowed for a walk speed: capped at HorizontalCap unless an
-- explicit class boost (studs/s) is active.
function SurvivalRules.AllowedSpeed(walk: number, boost: number?): number
	local cap = RunConfig.Survival.Move.HorizontalCap
	local w = if finite(walk) then math.max(0, walk) else 0
	local allowed = math.min(w, cap)
	if type(boost) == "number" and finite(boost) and boost > allowed then
		allowed = boost
	end
	return allowed
end

return SurvivalRules
