--[[
	Ultimate.lua (server)
	Feature 13, the hero ultimate (Config.Features.Ultimate; docs/features/HEROPOWER.md).

	Charge: a player's own kills (rp.Kills) since the last use, KillsToCharge for a full
	bar, and at least Cooldown run seconds since the last use. Kills made by the ultimate
	itself never count toward the next charge.
	Publish: player attributes "UltCharge" (0..1, 2% steps, 10 Hz), "UltHero" (the hero id
	whose ultimate it is) and "UltUsed" (a counter the client announces). All cleared
	outside a run and while the switch is off.
	Use: the client sends UseUltimate (no arguments). The server checks the switch, a
	running and simulating run (not frozen, paused or travelling), a living participant
	who hasn't left through the portal, isn't choosing a card, and a full charge. Remotes
	rate-limits it (Config.Ultimate.Rate).
	Effect: every enemy within Radius takes the capped damage once (proc damage: no crits,
	no item procs). Elites, altar guards, mini-bosses and nests take at most EliteShare
	of their max HP and bosses BossShare, so it never kills a boss outright. Each hero
	adds its own look and a small extra (CharacterData.Ultimates).
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")
local Config = require(ReplicatedStorage.Shared.Config)
local Remotes = require(ReplicatedStorage.Shared.Remotes)
local CharacterData = require(ReplicatedStorage.Shared.CharacterData)
local Fx = require(script.Parent.Fx)

local Ultimate = {}

local ctx
local published: { [Player]: boolean } = {}
local publishTimer = 0
local rng = Random.new()
local FLAT = Vector3.new(1, 0, 1)

local function on(): boolean
	return Config.FeatureOn("Ultimate")
end

-- Charge 0..1 of a run player (kills since the last use and the cooldown together).
function Ultimate.Charge(rp): number
	local U = Config.Ultimate
	local kills = math.max(0, (rp.Kills or 0) - (rp.UltKillMark or 0))
	local killFrac = math.clamp(kills / math.max(1, U.KillsToCharge), 0, 1)
	local since = ctx.RunManager.GetRunTime() - (rp.UltUsedAt or -math.huge)
	local coolFrac = math.clamp(since / math.max(0.01, U.Cooldown), 0, 1)
	return math.min(killFrac, coolFrac)
end

-- The damage one enemy would take (before its elite / boss share cap).
function Ultimate.Damage(rp): number
	local U = Config.Ultimate
	local def = CharacterData.UltimateFor(rp.CharacterId)
	local base = math.min(U.Cap, U.Base + U.PerLevel * math.max(0, (rp.Level or 1) - 1))
	local might = math.clamp(rp.Stats and rp.Stats.Might or 1, 0, U.MaxMight)
	return base * (def.Damage or 1) * might
end

local function capFor(e, amount: number): number
	local U = Config.Ultimate
	if e.Boss then
		return math.min(amount, e.MaxHP * U.BossShare)
	end
	if e.Elite or e.Guard or e.MiniBoss or e.Def.Spawner or e.Def.Object then
		return math.min(amount, e.MaxHP * U.EliteShare)
	end
	return amount
end

local function ringPoints(c: Vector3, radius: number, count: number): { Vector3 }
	local out = {}
	local turn = rng:NextNumber(0, math.pi * 2)
	for i = 1, count do
		local a = turn + i / count * math.pi * 2
		table.insert(out, c + Vector3.new(math.cos(a) * radius, 0, math.sin(a) * radius))
	end
	return out
end

local function scatter(c: Vector3, radius: number, count: number): { Vector3 }
	local out = {}
	for _ = 1, count do
		local a, r = rng:NextNumber(0, math.pi * 2), radius * math.sqrt(rng:NextNumber(0.05, 1))
		table.insert(out, c + Vector3.new(math.cos(a) * r, 0, math.sin(a) * r))
	end
	return out
end

-- Existing effects only (Fx batch): each look is a few rings, blasts, slashes or arcs.
local LOOKS: { [string]: (c: Vector3, r: number, color: Color3, rp: any, hit: { any }) -> () } = {
	Quake = function(c, r, color)
		Fx.Ring(c, r, color)
		Fx.Ring(c, r * 0.55, color)
		Fx.Warn("pop", c.X, c.Z, r * 0.5, "pound")
		Fx.Explosion(c, 10)
	end,
	Stars = function(c, r, color)
		for _, p in ipairs(ringPoints(c, r * 0.55, 7)) do
			Fx.Explosion(p, 9)
		end
		Fx.Explosion(c, 11)
		Fx.Ring(c, r, color)
	end,
	Blades = function(c, r, color, rp)
		for i = 0, 5 do
			Fx.Slash(c, i / 6 * math.pi * 2, r * 0.6, i % 2 == 0 and 1 or -1, 3, rp.Player.UserId)
		end
		Fx.Ring(c, r, color)
	end,
	Nova = function(c, r, color, rp)
		Fx.Ring(c, r, color)
		Fx.Ring(c, r * 0.5, color)
		Fx.Pool(c, r * 0.35, 2, true)
		Fx.PlayerEvent(rp.Player, "heal")
	end,
	Arrows = function(c, r, color)
		for _, p in ipairs(scatter(c, r, 12)) do
			Fx.Warn("pop", p.X, p.Z, 4, "dust")
		end
		Fx.Ring(c, r, color)
	end,
	Fire = function(c, r, color)
		for _, p in ipairs(scatter(c, r * 0.8, 9)) do
			Fx.Explosion(p, 8)
		end
		Fx.Ring(c, r, color)
	end,
	Sparks = function(c, r, color, _rp, hit)
		Fx.Bolt(c, 8, 3)
		for i = 1, math.min(#hit, 14) do
			Fx.Chain(c, hit[i].Pos)
		end
		Fx.Ring(c, r, color)
	end,
	Souls = function(c, r, color, _rp, hit)
		for i = 1, math.min(#hit, 12) do
			Fx.Chain(c, hit[i].Pos)
		end
		Fx.Warn("pop", c.X, c.Z, r * 0.4, "glimmer")
		Fx.Ring(c, r, color)
	end,
}

--[[
	Fires the ultimate of `player` when allowed. Returns true when it fired, or false and
	the reason (tests and the regression scene read it).
]]
function Ultimate.Use(player: Player): (boolean, string?)
	if not on() then
		return false, "off"
	end
	local RM = ctx.RunManager
	local rp = RM.GetRunPlayer(player)
	if not rp then
		return false, "norun"
	end
	if not RM.IsRunning() or not RM.IsSimulating() then
		return false, "frozen"
	end
	if not rp.Alive or rp.Returned or rp.AwaitingRevive or rp.Paused or rp.RewardUntil or not rp.Root then
		return false, "state"
	end
	if Ultimate.Charge(rp) < 1 then
		return false, "charge"
	end
	local U = Config.Ultimate
	local def = CharacterData.UltimateFor(rp.CharacterId)
	local centre = rp.Root.Position * FLAT + Vector3.new(0, Config.ArenaOrigin.Y, 0)
	local radius = U.Radius * (def.Radius or 1)
	local r2 = radius * radius
	local damage = Ultimate.Damage(rp)
	local knock = U.Knockback * (def.Knock or 1)
	local now = RM.GetRunTime()
	-- targets first (a kill can change the Active list)
	local hit = {}
	for _, e in ipairs(ctx.EnemySpawner.Active) do
		if e.Alive and not e.Invulnerable then
			local dx, dz = e.Pos.X - centre.X, e.Pos.Z - centre.Z
			if dx * dx + dz * dz <= r2 then
				table.insert(hit, e)
			end
		end
	end
	table.sort(hit, function(a, b)
		return (a.Pos - centre).Magnitude < (b.Pos - centre).Magnitude
	end)
	local look = LOOKS[def.Look or ""] or LOOKS.Quake
	look(centre, radius, def.Color or Color3.fromRGB(255, 215, 120), rp, hit)
	Fx.Sound("Explosion")
	for _, e in ipairs(hit) do
		if e.Alive then
			local d = (e.Pos - centre) * FLAT
			local dir = d.Magnitude > 1e-3 and d.Unit or Vector3.zAxis
			if def.Slow and not e.Boss then
				-- a stronger slow that is still running is kept (WeaponSystem's rule)
				if not (e.SlowUntil and e.SlowUntil > now and (e.SlowMult or 1) < def.Slow.Mult) then
					e.SlowMult = def.Slow.Mult
					e.SlowUntil = now + def.Slow.Seconds
				end
			end
			ctx.EnemySpawner.Damage(e, capFor(e, damage), rp, dir, knock, true)
		end
	end
	-- the hero's extra
	if def.Heal and def.Heal > 0 then
		for _, other in ipairs(RM.GetRunPlayers()) do
			if other.Alive and other.Root and not other.Returned and other.Stats then
				local d = (other.Root.Position - centre) * FLAT
				if other == rp or d.Magnitude <= radius then
					RM.Heal(other, other.Stats.MaxHP * def.Heal)
				end
			end
		end
	end
	if def.Guard and def.Guard > 0 then
		rp.InvulnUntil = math.max(rp.InvulnUntil or 0, now + def.Guard)
	end
	-- the next charge starts now: the ultimate's own kills don't count
	rp.UltKillMark = rp.Kills
	rp.UltUsedAt = now
	rp.UltUses = (rp.UltUses or 0) + 1
	player:SetAttribute("UltCharge", 0)
	player:SetAttribute("UltUsed", (tonumber(player:GetAttribute("UltUsed")) or 0) + 1)
	return true, nil
end

local function clear(player: Player)
	published[player] = nil
	if player.Parent then
		player:SetAttribute("UltCharge", nil)
		player:SetAttribute("UltHero", nil)
		player:SetAttribute("UltUsed", nil)
	end
end

function Ultimate.Step(dt: number)
	publishTimer += dt
	if publishTimer < 0.1 then
		return
	end
	publishTimer = 0
	local RM = ctx.RunManager
	local live: { [Player]: boolean } = {}
	if on() and RM.IsRunning() then
		for _, rp in ipairs(RM.GetRunPlayers()) do
			local player = rp.Player
			if player and player.Parent and not rp.Returned then
				if rp.UltKillMark == nil then
					-- a new run player: the bar starts empty and the cooldown starts now
					rp.UltKillMark = rp.Kills or 0
					rp.UltUsedAt = RM.GetRunTime() - Config.Ultimate.Cooldown
				end
				live[player] = true
				published[player] = true
				local charge = math.floor(Ultimate.Charge(rp) * 50) / 50
				if player:GetAttribute("UltCharge") ~= charge then
					player:SetAttribute("UltCharge", charge)
				end
				if player:GetAttribute("UltHero") ~= rp.CharacterId then
					player:SetAttribute("UltHero", rp.CharacterId)
				end
			end
		end
	end
	for player in pairs(published) do
		if not live[player] then
			clear(player)
		end
	end
end

function Ultimate.Init(c)
	ctx = c
end

function Ultimate.Start()
	Remotes.Listen("UseUltimate", function(player: Player)
		Ultimate.Use(player)
	end, Config.Ultimate.Rate)
	Players.PlayerRemoving:Connect(function(player)
		published[player] = nil
	end)
end

return Ultimate
