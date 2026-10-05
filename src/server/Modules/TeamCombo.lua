--[[
	TeamCombo.lua (server)
	Feature 16, the team combo (Config.Features.TeamCombo; docs/features/TEAM.md).

	Charge: one shared meter per run. It fills while two "free" players stand within
	Config.TeamCombo.Radius of each other and the world runs (ChargeSeconds for a full
	meter), and drains slowly while nobody is paired. A free player is alive, still in the
	run (not through the portal), not waiting on the revive offer, not choosing a card
	(rp.Offer / rp.Paused) and not in a chest reward pause (rp.RewardUntil). So a player
	protected by an open choice can't charge it or fire it. Nothing happens in a solo run.
	After a burst the meter stays empty for Cooldown run seconds, and at most MaxPerStage
	bursts happen per stage.

	Publish (SwarmState, 10 Hz): "TeamCombo" (0..1, 2 % steps), "TeamComboPair" (",id,id,"
	of the pair standing together now, or nil) and "TeamComboUsed" (a counter the client
	announces). All are cleared outside a co-op run and while the switch is off.

	Fire: the client sends TeamComboFire (no arguments; rate-limited). The server checks the
	switch, a running and simulating run, a free sender with a free partner in range, a
	full meter, the cooldown and the stage cap. Effect: every enemy within BurstRadius of the
	pair's middle takes the capped damage once (proc damage: no crits, no item procs).
	Elites and the like take at most EliteShare of their max HP, bosses BossShare.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Config = require(ReplicatedStorage.Shared.Config)
local Remotes = require(ReplicatedStorage.Shared.Remotes)
local Fx = require(script.Parent.Fx)

local TeamCombo = {}

local ctx
local FLAT = Vector3.new(1, 0, 1)
local meter = 0
local usedAt = -math.huge
local stageUses = 0
local stageSeen: number? = nil
local uses = 0
local publishTimer = 0
local published = false

local function on(): boolean
	return Config.FeatureOn("TeamCombo")
end

-- A player who may charge or fire the combo right now.
function TeamCombo.Free(rp): boolean
	return rp ~= nil and rp.Alive == true and not rp.Returned and not rp.AwaitingRevive
		and rp.Root ~= nil and rp.Root.Parent ~= nil and not rp.Paused and rp.Offer == nil and rp.RewardUntil == nil
end

local function flatDist(a, b): number
	return ((a.Root.Position - b.Root.Position) * FLAT).Magnitude
end

-- The closest free teammate of `rp` within Radius, or nil.
function TeamCombo.Partner(rp)
	if not TeamCombo.Free(rp) then
		return nil
	end
	local best, bestD = nil, Config.TeamCombo.Radius + 1e-3
	for _, other in ipairs(ctx.RunManager.GetRunPlayers()) do
		if other ~= rp and TeamCombo.Free(other) then
			local d = flatDist(rp, other)
			if d <= bestD then
				best, bestD = other, d
			end
		end
	end
	return best
end

-- Any free pair standing together (the first found), or nil.
local function anyPair()
	for _, rp in ipairs(ctx.RunManager.GetRunPlayers()) do
		local mate = TeamCombo.Partner(rp)
		if mate then
			return rp, mate
		end
	end
	return nil, nil
end

local function coopRun(): boolean
	return #ctx.RunManager.GetRunPlayers() >= 2
end

function TeamCombo.Meter(): number
	return meter
end

function TeamCombo.Reset()
	meter = 0
	usedAt = -math.huge
	stageUses = 0
	stageSeen = nil
	uses = 0
end

local function clear()
	if not published then
		return
	end
	published = false
	local state = Remotes.State()
	state:SetAttribute("TeamCombo", nil)
	state:SetAttribute("TeamComboPair", nil)
	state:SetAttribute("TeamComboUsed", nil)
end

local function capFor(e, amount: number): number
	local T = Config.TeamCombo
	if e.Boss then
		return math.min(amount, e.MaxHP * T.BossShare)
	end
	if e.Elite or e.Guard or e.MiniBoss or e.Def.Spawner or e.Def.Object then
		return math.min(amount, e.MaxHP * T.EliteShare)
	end
	return amount
end

-- The damage one enemy takes before its share cap (both heroes' levels count).
function TeamCombo.Damage(a, b): number
	local T = Config.TeamCombo
	local level = ((a.Level or 1) + (b.Level or 1)) / 2
	return math.min(T.Cap, T.Damage + T.PerLevel * math.max(0, level - 1))
end

--[[
	Fires the combo for `player` when allowed. Returns true, or false and the reason
	("off", "norun", "frozen", "state", "partner", "charge", "stage").
]]
function TeamCombo.Fire(player: Player): (boolean, string?)
	if not on() then
		return false, "off"
	end
	local RM = ctx.RunManager
	local rp = RM.GetRunPlayer(player)
	if not rp or not coopRun() then
		return false, "norun"
	end
	if not RM.IsRunning() or not RM.IsSimulating() then
		return false, "frozen"
	end
	if not TeamCombo.Free(rp) then
		return false, "state"
	end
	local mate = TeamCombo.Partner(rp)
	if not mate then
		return false, "partner"
	end
	if meter < 1 then
		return false, "charge"
	end
	if stageUses >= Config.TeamCombo.MaxPerStage then
		return false, "stage"
	end
	local T = Config.TeamCombo
	local mid = (rp.Root.Position + mate.Root.Position) / 2
	local centre = mid * FLAT + Vector3.new(0, Config.ArenaOrigin.Y, 0)
	local r2 = T.BurstRadius * T.BurstRadius
	local amount = TeamCombo.Damage(rp, mate)
	local hit = {}
	for _, e in ipairs(ctx.EnemySpawner.Active) do
		if e.Alive and not e.Invulnerable then
			local dx, dz = e.Pos.X - centre.X, e.Pos.Z - centre.Z
			if dx * dx + dz * dz <= r2 then
				table.insert(hit, e)
			end
		end
	end
	Fx.Ring(centre, T.BurstRadius, rp.TeamPingColor or Color3.fromRGB(98, 225, 209))
	Fx.Ring(centre, T.BurstRadius * 0.6, mate.TeamPingColor or Color3.fromRGB(255, 214, 115))
	Fx.Explosion(centre, 10)
	Fx.Chain(rp.Root.Position, mate.Root.Position)
	Fx.Sound("Explosion")
	for _, e in ipairs(hit) do
		if e.Alive then
			local d = (e.Pos - centre) * FLAT
			local dir = d.Magnitude > 1e-3 and d.Unit or Vector3.zAxis
			ctx.EnemySpawner.Damage(e, capFor(e, amount), rp, dir, T.Knockback, true)
		end
	end
	meter = 0
	usedAt = RM.GetRunTime()
	stageUses += 1
	uses += 1
	Remotes.State():SetAttribute("TeamCombo", 0)
	Remotes.State():SetAttribute("TeamComboUsed", uses)
	return true, nil
end

function TeamCombo.Step(dt: number)
	local RM = ctx.RunManager
	if not on() or not RM.IsRunning() or not coopRun() then
		if not RM.IsRunning() then
			TeamCombo.Reset()
		end
		clear()
		return
	end
	local stage = ctx.StageManager.GetStage()
	if stage ~= stageSeen then
		stageSeen = stage
		stageUses = 0
	end
	local a, b = nil, nil
	if RM.IsSimulating() then
		a, b = anyPair()
		local T = Config.TeamCombo
		local cooling = RM.GetRunTime() - usedAt < T.Cooldown
		if a and not cooling and stageUses < T.MaxPerStage then
			meter = math.min(1, meter + dt / math.max(0.1, T.ChargeSeconds))
		elseif not a and meter < 1 then
			meter = math.max(0, meter - dt / math.max(0.1, T.DrainSeconds))
		end
	end
	publishTimer += dt
	if publishTimer < 0.1 then
		return
	end
	publishTimer = 0
	published = true
	local state = Remotes.State()
	local shown = math.floor(meter * 50) / 50
	if state:GetAttribute("TeamCombo") ~= shown then
		state:SetAttribute("TeamCombo", shown)
	end
	local pair = nil
	if a and b then
		local x, y = a.Player.UserId, b.Player.UserId
		pair = string.format(",%d,%d,", math.min(x, y), math.max(x, y))
	end
	if state:GetAttribute("TeamComboPair") ~= pair then
		state:SetAttribute("TeamComboPair", pair)
	end
	if state:GetAttribute("TeamComboUsed") ~= uses then
		state:SetAttribute("TeamComboUsed", uses)
	end
end

function TeamCombo.Init(c)
	ctx = c
end

function TeamCombo.Start()
	Remotes.Listen("TeamComboFire", function(player: Player)
		TeamCombo.Fire(player)
	end, Config.TeamCombo.Rate)
end

return TeamCombo
