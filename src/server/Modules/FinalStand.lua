--[[
	FinalStand.lua (server)
	Final Stand (batch B, Config.Features.FinalStand; numbers Config.FinalStand;
	docs/next/FINAL_STAND.md).

	The first time in a stage a living hero's HP drops below Config.FinalStand.HPShare of max
	HP (after a hit, RunManager.DamagePlayer calls OnHurt), they get +Speed and +Damage for
	Seconds of run time. The buff is a temporary stat-sheet multiplier: rp.TempMods.FinalStand
	= { Might, Speed }, which LevelUpSystem's sheet passes to StatSheet.Compute (input.Temp,
	applied last), then RecomputeStats re-applies the walk speed. Per player (co-op: each
	hero has their own), once per stage (rp.FinalStandStage), re-armed by the next stage.

	Never while choosing an upgrade / watching a reward (rp.Paused, rp.Offer, rp.RewardUntil),
	while protected (rp.InvulnUntil), within ReviveGrace s of a revive (rp.RevivedAt, set by
	RunManager's revive) or while the world is not simulating. No healing; it never blocks
	lethal damage (a lethal hit downs the hero before OnHurt runs).

	Cleared (Step, every frame) on timeout, death (also a down that an extra life revived:
	rp.RevivedAt after the start), the stage's end (travel / a new stage), leaving the run
	(portal return, MAIN MENU, disconnect: no longer a run player) and the run's end.
	The player attribute "FinalStand" (seconds of the buff) is set while it lasts; the client
	(FinalStandFx.lua) draws the aura, the "FINAL STAND!" headline and its one sound.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Config = require(ReplicatedStorage.Shared.Config)
local Fx = require(script.Parent.Fx)

local FinalStand = {}

local ctx
local tracked: { [any]: boolean } = {} -- run players with a live buff
local KEY = "FinalStand" -- rp.TempMods key and player attribute

local function F()
	return (Config :: any).FinalStand
end

local function on(): boolean
	return Config.FeatureOn("FinalStand")
end

-- The multipliers while the buff lasts (StatSheet input.Temp).
function FinalStand.Mults(): { [string]: number }
	return { Might = 1 + F().Damage, Speed = 1 + F().Speed }
end

function FinalStand.IsActive(rp): boolean
	return rp ~= nil and rp.FinalStandUntil ~= nil
end

--[[
	May `rp` start Final Stand now? Returns (ok, reason). Pure on the run player's state and
	the run clock, so the regression scene can ask it directly.
]]
function FinalStand.CanTrigger(rp): (boolean, string)
	if not on() then
		return false, "off"
	end
	if not rp or not rp.Stats or type(rp.HP) ~= "number" then
		return false, "no player"
	end
	if not rp.Alive or rp.AwaitingRevive or rp.Returned or rp.HP <= 0 then
		return false, "dead"
	end
	if rp.FinalStandUntil then
		return false, "active"
	end
	local stage = ctx.StageManager.GetStage()
	if stage <= 0 or rp.FinalStandStage == stage then
		return false, "used"
	end
	if rp.HP >= rp.Stats.MaxHP * F().HPShare then
		return false, "hp"
	end
	if rp.Paused or rp.Offer ~= nil or rp.RewardUntil then
		return false, "choosing"
	end
	local now = ctx.RunManager.GetRunTime()
	if now < (rp.InvulnUntil or 0) then
		return false, "protected"
	end
	if now - (rp.RevivedAt or -math.huge) < F().ReviveGrace then
		return false, "revive"
	end
	if not ctx.RunManager.IsSimulating() then
		return false, "paused"
	end
	return true, "ok"
end

local function setTemp(rp, mods: { [string]: number }?)
	local t = rp.TempMods
	if mods then
		t = t or {}
		t[KEY] = mods
		rp.TempMods = t
	elseif t then
		t[KEY] = nil
		if next(t) == nil then
			rp.TempMods = nil
		end
	end
end

local function start(rp)
	local now = ctx.RunManager.GetRunTime()
	rp.FinalStandStage = ctx.StageManager.GetStage()
	rp.FinalStandStart = now
	rp.FinalStandUntil = now + F().Seconds
	tracked[rp] = true
	setTemp(rp, FinalStand.Mults())
	ctx.LevelUpSystem.RecomputeStats(rp) -- damage now, walk speed via ApplyMovement
	local player: Player = rp.Player
	player:SetAttribute(KEY, F().Seconds)
	if rp.Root then
		Fx.Ring(rp.Root.Position, 9, Color3.fromRGB(230, 70, 60))
	end
end

-- After a non-lethal hit (RunManager.DamagePlayer). True when Final Stand started.
function FinalStand.OnHurt(rp): boolean
	if not on() then
		return false
	end
	if FinalStand.CanTrigger(rp) then
		start(rp)
		return true
	end
	return false
end

--[[
	Ends the buff (why: "timeout" | "death" | "stage" | "leave" | "run"). inRun = the player
	is still a run player (their stat sheet is recomputed; a player who left keeps theirs
	untouched, it is no longer used).
]]
function FinalStand.Clear(rp, _why: string?, inRun: boolean?)
	tracked[rp] = nil
	if not rp.FinalStandUntil and not (rp.TempMods and rp.TempMods[KEY]) then
		return
	end
	rp.FinalStandUntil = nil
	setTemp(rp, nil)
	if inRun ~= false and rp.Stats then
		ctx.LevelUpSystem.RecomputeStats(rp)
	end
	local player: Player? = rp.Player
	if player and player.Parent then
		player:SetAttribute(KEY, nil)
	end
end

function FinalStand.Step(_dt: number)
	if next(tracked) == nil then
		return
	end
	local players = ctx.RunManager.GetRunPlayers()
	local running = ctx.RunManager.IsRunning()
	local stage = ctx.StageManager.GetStage()
	local travel = ctx.StageManager.GetPhase() == "Travel"
	local now = ctx.RunManager.GetRunTime()
	for rp in pairs(tracked) do
		local inRun = table.find(players, rp) ~= nil
		if not running then
			FinalStand.Clear(rp, "run", inRun)
		elseif not inRun or rp.Returned then
			FinalStand.Clear(rp, "leave", inRun)
		elseif not rp.Alive or rp.AwaitingRevive or (rp.RevivedAt or -math.huge) >= (rp.FinalStandStart or math.huge) then
			FinalStand.Clear(rp, "death")
		elseif travel or stage ~= rp.FinalStandStage then
			FinalStand.Clear(rp, "stage")
		elseif now >= (rp.FinalStandUntil or 0) then
			FinalStand.Clear(rp, "timeout")
		end
	end
end

function FinalStand.Init(c)
	ctx = c
end

return FinalStand
