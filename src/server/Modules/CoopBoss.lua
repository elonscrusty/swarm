--[[
	CoopBoss.lua (server)
	Feature 18, the co-op boss mechanic (Config.Features.CoopBoss; docs/features/TEAM.md).

	A variant of ONE boss (Config.CoopBoss.Boss) that only exists while 2+ players are
	alive in the run. It plugs into BossAI's variant hook (BossAI.Variant = this module):
	  Step(e, dt)          every boss frame (BossAI.Step), not while it collapses
	  Hit(e, amount, rp)   a player's hit on a boss (EnemySpawner.Damage via
	                       BossAI.ModifyHit) -> the amount to apply
	  Clear(e)             hazards cleared (travel, collapse, run end)

	Rule: the boss's aggro holder is its target (EnemyAI think: the nearest free player);
	a switch shorter than LoseSeconds is a flicker and keeps the holder.
	When the same player has held it for HoldSeconds while the boss fights (not in its
	entrance, collapse or underground), a weak spot opens on the side away from the
	holder for OpenSeconds. Hits from the OTHER players standing behind the boss
	(dot(boss->hitter, boss->holder) < BackDot) deal Mult damage, the extra capped at
	MaxBonusShare of its max HP per opening. If the holder changes or falls, it closes.
	Then Cooldown seconds before the next hold counts.

	Telegraph: a notice (id boss.weakspot), a glimmer pop at the spot, and SwarmState
	attributes the client draws (WeakSpot.lua): BossWeakSpot (Vector3 of the marker, only
	while open), BossAggroId (the holder's UserId while the variant runs).
	Solo runs, other bosses and the switch off: no state, no attributes, no damage change.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Config = require(ReplicatedStorage.Shared.Config)
local Remotes = require(ReplicatedStorage.Shared.Remotes)
local Fx = require(script.Parent.Fx)
local BossAI = require(script.Parent.BossAI)

local CoopBoss = {}

local ctx
local FLAT = Vector3.new(1, 0, 1)
local clock = 0
local publishTimer = 0

local function free(rp): boolean
	return rp ~= nil and rp.Alive == true and not rp.Returned and rp.Root ~= nil and rp.Root.Parent ~= nil
		and not (rp.Paused == true and rp.Offer ~= nil)
end

local function livingCount(): number
	local n = 0
	for _, rp in ipairs(ctx.RunManager.GetRunPlayers()) do
		if rp.Alive and not rp.Returned then
			n += 1
		end
	end
	return n
end

-- True when boss `e` runs the co-op variant right now.
function CoopBoss.Active(e): boolean
	return Config.FeatureOn("CoopBoss") and e ~= nil and e.BossData ~= nil
		and e.BossData.Id == Config.CoopBoss.Boss and livingCount() >= Config.CoopBoss.MinPlayers
end

function CoopBoss.IsOpen(e): boolean
	return e ~= nil and e.WeakSpotUntil ~= nil and clock < e.WeakSpotUntil
end

-- Where the weak spot marker sits: behind the boss, away from the holder.
function CoopBoss.SpotPosition(e): Vector3?
	local holder = e.WeakHolder
	if not holder or not holder.Root then
		return nil
	end
	local away = (e.Pos - holder.Root.Position) * FLAT
	local dir = away.Magnitude > 1e-3 and away.Unit or Vector3.zAxis
	local at = e.Pos + dir * (e.Radius or 4) * Config.CoopBoss.MarkerDistance
	return Vector3.new(at.X, Config.ArenaOrigin.Y, at.Z)
end

local function publish(e)
	local state = Remotes.State()
	local spot = CoopBoss.IsOpen(e) and CoopBoss.SpotPosition(e) or nil
	if spot then
		spot = Vector3.new(math.floor(spot.X * 4 + 0.5) / 4, spot.Y, math.floor(spot.Z * 4 + 0.5) / 4)
	end
	if state:GetAttribute("BossWeakSpot") ~= spot then
		state:SetAttribute("BossWeakSpot", spot)
	end
	local holder = e and e.WeakHolder
	local id = holder and holder.Player and holder.Player.UserId or nil
	if state:GetAttribute("BossAggroId") ~= id then
		state:SetAttribute("BossAggroId", id)
	end
end

local function close(e)
	if e.WeakSpotUntil then
		e.WeakSpotUntil = nil
		e.WeakNextAt = clock + Config.CoopBoss.Cooldown
	end
end

function CoopBoss.Clear(e)
	if e then
		e.WeakSpotUntil = nil
		e.WeakHolder = nil
		e.WeakHold = 0
		e.WeakBonus = 0
	end
	local state = Remotes.State()
	state:SetAttribute("BossWeakSpot", nil)
	state:SetAttribute("BossAggroId", nil)
end

function CoopBoss.Step(e, dt: number)
	clock += dt
	if not CoopBoss.Active(e) or e.Dying then
		if e.WeakHolder or e.WeakSpotUntil then
			CoopBoss.Clear(e)
		end
		return
	end
	local C = Config.CoopBoss
	local fighting = e.BossState ~= "Entrance" and not e.Invulnerable
	local target = e.Target
	if not free(target) then
		target = nil
	end
	if target ~= e.WeakHolder then
		-- the aggro moved for longer than a short flicker (or the holder fell / is
		-- choosing): start over
		e.WeakAway = (e.WeakAway or 0) + dt
		if not free(e.WeakHolder) or e.WeakAway >= C.LoseSeconds then
			close(e)
			e.WeakHolder = target
			e.WeakHold = 0
			e.WeakAway = 0
		end
	else
		e.WeakAway = 0
	end
	target = e.WeakHolder
	if target and fighting and (e.WeakAway or 0) == 0 then
		e.WeakHold = (e.WeakHold or 0) + dt
	end
	if e.WeakSpotUntil and clock >= e.WeakSpotUntil then
		close(e)
		e.WeakHold = 0
	end
	if not e.WeakSpotUntil and target and fighting and (e.WeakHold or 0) >= C.HoldSeconds and clock >= (e.WeakNextAt or 0) then
		e.WeakSpotUntil = clock + C.OpenSeconds
		e.WeakBonus = 0
		local spot = CoopBoss.SpotPosition(e)
		if spot then
			Fx.Warn("pop", spot.X, spot.Z, (e.Radius or 4) * 0.8, "glimmer")
		end
		ctx.RunManager.Broadcast("Weak spot open! Hit its back!", Color3.fromRGB(255, 215, 120), nil, { Id = "boss.weakspot" })
	end
	publishTimer += dt
	if publishTimer >= 0.1 then
		publishTimer = 0
		publish(e)
	end
end

-- A player's hit on boss `e`: Mult for non-holders behind it while the spot is open.
function CoopBoss.Hit(e, amount: number, rp): number
	if not CoopBoss.IsOpen(e) or not CoopBoss.Active(e) or rp == nil or rp == e.WeakHolder or not rp.Root then
		return amount
	end
	local holder = e.WeakHolder
	if not holder or not holder.Root then
		return amount
	end
	local toHitter = (rp.Root.Position - e.Pos) * FLAT
	local toHolder = (holder.Root.Position - e.Pos) * FLAT
	if toHitter.Magnitude < 1e-3 or toHolder.Magnitude < 1e-3 then
		return amount
	end
	if toHitter.Unit:Dot(toHolder.Unit) >= Config.CoopBoss.BackDot then
		return amount
	end
	local budget = e.MaxHP * Config.CoopBoss.MaxBonusShare - (e.WeakBonus or 0)
	local extra = math.clamp(amount * (Config.CoopBoss.Mult - 1), 0, math.max(0, budget))
	e.WeakBonus = (e.WeakBonus or 0) + extra
	return amount + extra
end

function CoopBoss.Init(c)
	ctx = c
	BossAI.Variant = CoopBoss
end

return CoopBoss
