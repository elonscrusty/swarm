--[[
	XPSystem.lua
	Everything dropped on the arena floor: XP shards / gems (pooled Parts), floor pickups
	(Chicken / Magnet / Bomb) and elite treasure chests. Also hands out run XP.

	Personal XP shards (RunConfig.Economy, DECISIONS C9; stream E2):
	  * XPSystem.OnEnemyKilled (called by EnemySpawner.Kill) turns an eligible team kill
	    (a hero is credited with it) into an equal personal entitlement by enemy kind
	    (Economy.XP.ByKind: Normal 4, Tough 8, Elite 20). Every eligible player within
	    Economy.XP.ShareRadius (120 studs) of the kill gets their OWN shard of the full amount:
	    never divided by party size, never all to the last hitter. Eligible (IsEligible) =
	    initialized, connected, not eliminated, not returned: downed heroes included. Far
	    teammates get nothing (no catch-up). The boss (Kind "Boss", 100) is granted directly,
	    once, to every eligible participant (no shard).
	  * A shard can only be collected by its owner (attribute "Owner" = UserId; other clients
	    hide it), inside Economy.XP.PickupRadius (8 studs, scaled by the owner's pickup
	    bonus), once. It expires after Economy.XP.ExpireSeconds of run clock; its last
	    FadeSeconds are announced once with attribute "Fade" (server time it vanishes) and the
	    client blinks / shrinks it.
	  * Crowds: a new shard joins a resting shard of the same owner within MergeRadius that
	    was born less than MergeWindow s ago (values add up: the entitlement is unchanged).
	  * Collected XP = value x the owner's Growth (an approved modifier); the class-goal XP
	    counter (ClassGoals.AddXP) gets the base value.
	  * The kill also credits team run gold (GoldSystem.CreditKill) and the cooperative class
	    goals (elites, bosses: ClassGoals.OnEnemyKilled) for the same eligible players.
	Economy.Enabled = false restores the old shared gems below.

	Gems (both modes)
	  * Parts built once (Config.XP.GemPoolSize, Economy.XP.PoolSize) and parked under the map.
	  * Server owns positions; the client adds bob/spin locally using the gem's "Base"
	    attribute (see client VFX). Active gems have attribute Active = true.
	  * A collector inside pickup radius makes the gem fly to them. The flight is replicated
	    ONCE: the gem's "Fly" attribute = the collector's UserId; clients animate the
	    homing flight themselves (same speed rule) toward that player's character. The
	    server still flies the gem's position every frame (not the part) and decides when
	    it is collected, so XP timing stays server-side. A flight that loses its target
	    writes the resting spot ("Base") once and clears "Fly".
	  * Old mode only: XP is SHARED: whoever collects a gem, every living participant gets
	    its value (times their own Growth stat, times Config.XP.CoopShare for the team size).
	  * A gem that lands within the merge radius of a resting one is merged into it (values
	    add up, capped), so piles stay a few bigger crystals. Resting gems sit in a coarse
	    grid for that lookup; flying gems are not in it.
	  * If the pool runs dry the value is merged into an existing active gem (of the same
	    owner; with none, the owner gets it directly so no entitlement is lost).
	  * Gems are anchored parts with no collision, query or touch: no physics per gem.
]]

local Config = require(game:GetService("ReplicatedStorage").Shared.Config)
local ModelBuilder = require(script.Parent.ModelBuilder)
local Fx = require(script.Parent.Fx)
local HeightGrid = require(script.Parent.HeightGrid)
local Players = game:GetService("Players")
local RunConfig = require(game:GetService("ReplicatedStorage").SwarmV2.Run.RunConfig)
local Nav = RunConfig.Nav

local XPSystem = {}

local ctx
local rng = Random.new()
local PARK = CFrame.new(Config.Enemies.ParkPosition)

-- the redesign economy (RunConfig.Economy): personal shards, the new curve
local function econ()
	return (RunConfig :: any).Economy
end
local function personal(): boolean
	local E = econ()
	return E ~= nil and E.Enabled == true
end

type Gem = {
	Part: BasePart,
	Active: boolean,
	Value: number,
	Pos: Vector3,
	Target: any?, -- run player it's flying to
	Speed: number,
	Index: number,
	Cell: number?, -- grid cell key while resting (nil while flying or parked)
	Owner: any?, -- personal shard: the only run player who may collect it (nil = old shared gem)
	OwnerId: number?, -- ... their UserId (a reconnect replaces the run record: found again by it)
	Born: number, -- run clock when it appeared (merge window)
	Expires: number, -- run clock when an uncollected shard vanishes (math.huge: never)
	Fading: boolean, -- the "Fade" attribute is set (its last FadeSeconds)
}

local gemFolder: Folder
local pickupFolder: Folder
local gems: { Gem } = {}
local freeGems: { number } = {}
local activeGems: { Gem } = {} -- dense list of active gems
local frame = 0
local MERGE_CELL = 3 -- studs: grid cell edge, at least the merge radius (Init raises it if needed)
local grid: { [number]: { Gem } } = {}
local bossPaid: { [any]: boolean } = {} -- boss spawn Uid -> its XP was granted (once)
local recipientsBuf: { any } = {} -- reused per kill (callees must not keep it)

type Pickup = { Model: Model, Kind: string, Pos: Vector3, Expires: number }
local pickups: { Pickup } = {}

local function runNow(): number
	return ctx.RunManager.GetRunTime()
end

-- Is this gem a personal shard of `rp` (by UserId: a reconnected player's new run record
-- still owns the shards of the record it replaced)?
local function ownedBy(gem: Gem, rp): boolean
	if gem.Owner == rp then
		return true
	end
	local id = gem.OwnerId
	return id ~= nil and type(rp) == "table" and rp.Player ~= nil and rp.Player.UserId == id
end

-- The owner's current run record (nil while they are away): a record replaced by a
-- reconnect is swapped for the new one.
local function liveOwner(gem: Gem): any?
	local o = gem.Owner
	if o and o.Root and o.Player and o.Player.Parent then
		return o
	end
	local p = gem.OwnerId and Players:GetPlayerByUserId(gem.OwnerId)
	local cur = p and ctx.RunManager.GetRunPlayer(p)
	if cur then
		gem.Owner = cur
	end
	return cur
end

------------------------------------------------------------------------------------------
-- XP
------------------------------------------------------------------------------------------

-- XP needed to go from `level` to level + 1. Redesign: Base + Linear (L-1) + Quad (L-1)^2.
function XPSystem.XPNeeded(level: number): number
	if personal() then
		local X = econ().XP
		local l = math.max(0, level - 1)
		return X.Base + X.Linear * l + X.Quad * l * l
	end
	return Config.XP.Base + math.min(level, Config.XP.CapLevel) * Config.XP.PerLevel
		+ math.max(0, level - Config.XP.CapLevel) * Config.XP.AfterCapPerLevel
end

-- Shared-XP multiplier for the current team size (Config.XP.CoopShare, by living
-- participants): in Duo / Trio every gem is worth less to each player, since there are
-- PlayerCountMult times as many gems and everyone receives every one of them. Personal
-- shards are never divided by party size (CoopShare off): 1.
function XPSystem.CoopShare(): number
	if personal() then
		return 1
	end
	local alive = 0
	for _, rp in ipairs(ctx.RunManager.GetRunPlayers()) do
		if rp.Alive then
			alive += 1
		end
	end
	local list = Config.XP.CoopShare
	if not list or #list == 0 then
		return 1
	end
	return list[math.clamp(alive, 1, #list)] or 1
end

-- Gem XP pacing multiplier (Config.XP.OpeningMult / StageMult): a boost in the first
-- seconds of a run, then less per gem on later stages, where the swarm is far bigger.
-- The redesign's curve replaces it: 1.
function XPSystem.PaceMult(): number
	if personal() then
		return 1
	end
	local X = Config.XP
	local mult = 1
	local list = X.StageMult
	if list and #list > 0 and ctx.StageManager then
		mult = list[math.clamp(ctx.StageManager.GetStage(), 1, #list)] or 1
	end
	if X.OpeningSeconds and X.OpeningMult and ctx.RunManager.GetRunTime() < X.OpeningSeconds then
		mult *= X.OpeningMult
	end
	return mult
end

-- Gives `amount` gem XP to every living run participant (each scaled by their Growth, by
-- the team-size share, see CoopShare, and by the pacing multiplier, see PaceMult).
-- Old shared gems only; personal shards use GiveShardXP.
function XPSystem.GiveSharedXP(amount: number)
	amount *= XPSystem.CoopShare() * XPSystem.PaceMult()
	amount *= ctx.RunModifiers and ctx.RunModifiers.StageMod and ctx.RunModifiers.StageMod("XP") or 1 -- stage modifier (1 = none)
	for _, rp in ipairs(ctx.RunManager.GetRunPlayers()) do
		if rp.Alive then
			XPSystem.GiveXP(rp, amount * rp.Stats.Growth)
		end
	end
end

-- A personal entitlement reaches its owner (a collected shard, the boss's direct grant):
-- value x Growth to the bar, the base value to the class-goal XP counter.
function XPSystem.GiveShardXP(rp, value: number)
	if not (value > 0 and value < math.huge) then
		return
	end
	local mod = ctx.RunModifiers and ctx.RunModifiers.StageMod and ctx.RunModifiers.StageMod("XP") or 1 -- stage modifier (1 = none)
	XPSystem.GiveXP(rp, value * (rp.Stats and rp.Stats.Growth or 1) * mod)
	if ctx.ClassGoals then
		ctx.ClassGoals.AddXP(rp, value)
	end
end

-- Is this run player out for the rest of the run (stream E1: RunManager.IsEliminated, or
-- the Eliminated flag / attribute)?
local function eliminated(rp): boolean
	local RM = ctx and ctx.RunManager
	if RM and RM.IsEliminated and RM.IsEliminated(rp) then
		return true
	end
	local player = rp.Player
	return rp.Eliminated == true or (player ~= nil and player:GetAttribute("Eliminated") == true)
end

function XPSystem.GiveXP(rp, amount: number)
	-- only a finite positive amount: NaN would freeze the bar for the rest of the run and
	-- an infinite one would spin the level loop below forever (server hang)
	if not (amount > 0 and amount < math.huge) then
		return
	end
	-- [stream E2] an eliminated hero gets nothing more; a downed one keeps the XP and its
	-- levels wait in the choice queue until the revive (LevelUpSystem holds downed choices)
	if eliminated(rp) then
		return
	end
	rp.XP += amount
	local gained = 0
	while rp.XP >= rp.XPNeeded do
		rp.XP -= rp.XPNeeded
		rp.Level += 1
		rp.XPNeeded = XPSystem.XPNeeded(rp.Level)
		gained += 1
	end
	local player: Player = rp.Player
	player:SetAttribute("XP", rp.XP)
	player:SetAttribute("XPNeeded", rp.XPNeeded)
	if gained > 0 then
		player:SetAttribute("Level", rp.Level)
		if ctx.ItemSystem then ctx.ItemSystem.OnLevelUp(rp, gained) end -- Second Wind
		ctx.LevelUpSystem.QueueLevels(rp, gained)
	end
end

------------------------------------------------------------------------------------------
-- Eligibility and enemy kinds (personal economy)
------------------------------------------------------------------------------------------

--[[
	May this run player receive a personal reward right now (an XP entitlement, a chest
	choice, cooperative class-goal credit)? Initialized (a stat sheet), connected, still in
	the run (not returned), not eliminated. Downed heroes ARE eligible. Disconnected
	players are out of the run list already (RunManager holds their record apart).
	Eliminated: rp.Eliminated or the player attribute "Eliminated" (stream E1).
]]
function XPSystem.IsEligible(rp): boolean
	if type(rp) ~= "table" or rp.Returned or rp.Stats == nil then
		return false
	end
	local player = rp.Player
	if not player or not player.Parent then
		return false -- (a hero inside the disconnect window is away: out of the run list too)
	end
	return not eliminated(rp)
end

-- The reward kind of an enemy: e.Kind (stream D) when it names a known kind, else the
-- boss / elite flags, else Tough for big enemy types (Economy.XP.ToughHP), else Normal.
-- nil for objects (banners, eggs: no rewards).
function XPSystem.KindOf(e): string?
	local def = e.Def
	if def and def.Object then
		return nil
	end
	local by = econ().XP.ByKind
	if type(e.Kind) == "string" and by[e.Kind] then
		return e.Kind
	end
	if e.Boss or (def and def.IsBoss) then
		return "Boss"
	end
	if e.Elite then
		return "Elite"
	end
	if def and type(def.Kind) == "string" and by[def.Kind] then
		return def.Kind
	end
	if def and (tonumber(def.HP) or 0) >= (econ().XP.ToughHP or math.huge) then
		return "Tough"
	end
	return "Normal"
end

------------------------------------------------------------------------------------------
-- Gems
------------------------------------------------------------------------------------------

local function gemKind(value: number, owned: boolean): string
	if owned then
		local K = econ().XP.Kinds
		if value >= K.Large then
			return "Large"
		elseif value >= K.Medium then
			return "Medium"
		end
		return "Small"
	end
	if value >= Config.XP.GemValues.Large then
		return "Large"
	elseif value >= Config.XP.GemValues.Medium then
		return "Medium"
	end
	return "Small"
end

local function styleGem(gem: Gem)
	ModelBuilder.StyleGem(gem.Part, gemKind(gem.Value, gem.Owner ~= nil))
end

local function cellKey(x: number, z: number): number
	return math.floor(x / MERGE_CELL) * 100003 + math.floor(z / MERGE_CELL)
end

local function gridAdd(gem: Gem)
	local key = cellKey(gem.Pos.X, gem.Pos.Z)
	local list = grid[key]
	if not list then
		list = {}
		grid[key] = list
	end
	table.insert(list, gem)
	gem.Cell = key
end

local function gridRemove(gem: Gem)
	local key = gem.Cell
	if not key then
		return
	end
	gem.Cell = nil
	local list = grid[key]
	if not list then
		return
	end
	local i = table.find(list, gem)
	if i then
		list[i] = list[#list]
		list[#list] = nil
	end
	if #list == 0 then
		grid[key] = nil
	end
end

-- Sends a gem flying to a player (it leaves the merge grid); clients animate the flight.
local function setTarget(gem: Gem, rp)
	gem.Target = rp
	gridRemove(gem)
	local id = rp.Player and rp.Player.UserId or nil
	if gem.Part:GetAttribute("Fly") ~= id then
		gem.Part:SetAttribute("Fly", id)
	end
end

-- A resting gem near `pos` of the same owner that can take `value` more (nearest first),
-- or nil. A personal shard only joins one born within the merge window.
local function findMergeTarget(pos: Vector3, value: number, owner: any?, now: number): Gem?
	local X = econ().XP
	local radius = owner and X.MergeRadius or Config.XP.MergeRadius
	local maxValue = owner and X.MergeMax or Config.XP.MergeMax
	local window = X.MergeWindow or 0
	local best, bestD = nil, radius * radius
	local cx, cz = math.floor(pos.X / MERGE_CELL), math.floor(pos.Z / MERGE_CELL)
	for dx = -1, 1 do
		for dz = -1, 1 do
			local list = grid[(cx + dx) * 100003 + (cz + dz)]
			if list then
				for _, gem in ipairs(list) do
					if (if owner then ownedBy(gem, owner) else gem.Owner == nil) and (owner == nil or now - gem.Born <= window) then
						local ox, oz = gem.Pos.X - pos.X, gem.Pos.Z - pos.Z
						local d = ox * ox + oz * oz
						if d <= bestD and gem.Value + value <= maxValue then
							best, bestD = gem, d
						end
					end
				end
			end
		end
	end
	return best
end

local function placeGem(gem: Gem, pos: Vector3)
	gem.Pos = pos
	gem.Part.CFrame = CFrame.new(pos)
	gem.Part:SetAttribute("Base", pos)
end

-- A shard took on more entitlement: it lives ExpireSeconds from now again (and stops fading).
local function refreshExpiry(gem: Gem, now: number)
	if not gem.Owner then
		return
	end
	gem.Expires = now + econ().XP.ExpireSeconds
	if gem.Fading then
		gem.Fading = false
		gem.Part:SetAttribute("Fade", nil)
	end
end

-- Spawns (or merges) one gem. owner = the run player of a personal shard, nil = a shared gem.
local function spawn(position: Vector3, value: number, owner: any?)
	local pos = Vector3.new(position.X, HeightGrid.GroundY(position.X, position.Z) + Config.XP.GemHeight, position.Z)
	local now = runNow()
	local near = findMergeTarget(pos, value, owner, now)
	if near then
		-- piles up: one gem carries the sum (same total XP, fewer crystals on the floor)
		near.Value += value
		styleGem(near)
		refreshExpiry(near, now)
		return
	end
	local index = table.remove(freeGems)
	if not index then
		-- Pool exhausted: merge into an active gem of the same owner so no XP is ever lost
		local target = nil
		if owner then
			for _, g in ipairs(activeGems) do
				if ownedBy(g, owner) then
					target = g
					break
				end
			end
		else
			target = activeGems[rng:NextInteger(1, math.max(1, #activeGems))]
		end
		if target then
			target.Value += value
			styleGem(target)
			refreshExpiry(target, now)
		elseif owner then
			XPSystem.GiveShardXP(owner, value) -- no shard of theirs to carry it: granted directly
		end
		return
	end
	local gem = gems[index]
	gem.Active = true
	gem.Value = value
	gem.Target = nil
	gem.Speed = 0
	gem.Owner = owner
	gem.OwnerId = owner and owner.Player and owner.Player.UserId or nil
	gem.Born = now
	gem.Expires = owner and (now + econ().XP.ExpireSeconds) or math.huge
	local ownerId = owner and owner.Player and owner.Player.UserId or nil
	if gem.Part:GetAttribute("Owner") ~= ownerId then
		gem.Part:SetAttribute("Owner", ownerId) -- before Active: clients hide others' shards
	end
	if gem.Fading then
		gem.Fading = false
		gem.Part:SetAttribute("Fade", nil)
	end
	styleGem(gem)
	placeGem(gem, pos)
	gem.Part:SetAttribute("Active", true)
	table.insert(activeGems, gem)
	gridAdd(gem)
end

--[[
	Drops `value` XP at `position`. Old economy: one shared gem. Personal economy: an XP
	drop with no owner (the walkthrough's top-up, tests) becomes a personal shard of the
	full value for every eligible player within ShareRadius, like a kill (Award).
]]
function XPSystem.SpawnGem(position: Vector3, value: number)
	if personal() then
		XPSystem.Award(position, value)
		return
	end
	spawn(position, value, nil)
end

-- One personal shard of `value` for `rp` at `position` (no eligibility check: callers do).
function XPSystem.SpawnShard(position: Vector3, value: number, rp)
	if not (value > 0 and value < math.huge) or not rp then
		return
	end
	spawn(position, value, rp)
end

--[[
	Personal entitlement: every eligible run player within Economy.XP.ShareRadius of
	`position` gets their own shard of the full `amount` (no division, no catch-up for far
	teammates). Returns the recipients (a reused list: read it at once, never keep it).
]]
function XPSystem.Award(position: Vector3, amount: number, _kind: string?): { any }
	table.clear(recipientsBuf)
	if not (amount > 0 and amount < math.huge) then
		return recipientsBuf
	end
	local r = econ().XP.ShareRadius
	for _, rp in ipairs(ctx.RunManager.GetRunPlayers()) do
		local root = rp.Root
		if root and XPSystem.IsEligible(rp) and (root.Position - position).Magnitude <= r then
			table.insert(recipientsBuf, rp)
			spawn(position, amount, rp)
		end
	end
	return recipientsBuf
end

-- The boss's XP: granted directly (no shard) once to every eligible participant.
-- Returns the recipients (a reused list).
function XPSystem.GrantDirect(amount: number): { any }
	table.clear(recipientsBuf)
	for _, rp in ipairs(ctx.RunManager.GetRunPlayers()) do
		if XPSystem.IsEligible(rp) then
			table.insert(recipientsBuf, rp)
		end
	end
	for _, rp in ipairs(table.clone(recipientsBuf)) do
		XPSystem.GiveShardXP(rp, amount)
	end
	return recipientsBuf
end

--[[
	[stream E2] EnemySpawner.Kill calls this for every enemy that died (after its own
	bookkeeping; objects excluded). `rp` = the hero credited with the kill (nil: no killer:
	the portal sweep, a self-destruct, cleanup). With the personal economy on:
	  * an eligible kill (a credited hero, or the boss) gives the kind's personal XP
	    (shards for eligible players within ShareRadius; the boss directly, once), the
	    kind's team run gold, and the cooperative class-goal credit (elites, bosses);
	  * a kill with no killer gives nothing (no XP, no gold).
	Returns true when the personal economy handled the XP: the caller then skips its
	old gem drops. False = old economy (drop gems as before).
]]
function XPSystem.OnEnemyKilled(e, rp, pos: Vector3): boolean
	if not personal() then
		return false
	end
	local kind = XPSystem.KindOf(e)
	if not kind then
		return true
	end
	local isBoss = kind == "Boss"
	if not rp and not isBoss then
		return true -- swept away / blew itself up: not beaten, no rewards
	end
	local amount = econ().XP.ByKind[kind] or 0
	local recipients
	if isBoss then
		local key = e.Uid or e
		if bossPaid[key] then
			return true
		end
		bossPaid[key] = true
		recipients = XPSystem.GrantDirect(amount)
	else
		recipients = XPSystem.Award(pos, amount, kind)
	end
	if ctx.ClassGoals then
		ctx.ClassGoals.OnEnemyKilled(e, rp, kind, recipients)
	end
	local G = ctx.GoldSystem
	if G and G.CreditKill then
		G.CreditKill(kind)
	end
	return true
end

local function releaseGem(i: number)
	local gem = activeGems[i]
	gem.Active = false
	gem.Target = nil
	gem.Owner = nil
	gem.OwnerId = nil
	gridRemove(gem)
	gem.Part:SetAttribute("Active", false)
	gem.Part:SetAttribute("Fly", nil)
	gem.Part.CFrame = PARK
	-- swap-remove from the dense list
	activeGems[i] = activeGems[#activeGems]
	activeGems[#activeGems] = nil
	table.insert(freeGems, gem.Index)
end

-- Magnet pickup: every gem on the floor flies to this player (personal: their own shards
-- and any shared gem; teammates' shards stay theirs).
function XPSystem.MagnetAll(rp)
	for _, gem in ipairs(activeGems) do
		if gem.Owner == nil or ownedBy(gem, rp) then
			setTarget(gem, rp)
		end
	end
end

-- Magnet Totem pulse: gems within `radius` of `pos` fly to this player (their own shards).
function XPSystem.MagnetRadius(rp, pos: Vector3, radius: number)
	local r2 = radius * radius
	for _, gem in ipairs(activeGems) do
		if gem.Owner == nil or ownedBy(gem, rp) then
			local dx, dz = gem.Pos.X - pos.X, gem.Pos.Z - pos.Z
			if dx * dx + dz * dz <= r2 then
				setTarget(gem, rp)
			end
		end
	end
end

-- The raw XP value of the gems on the floor (or flying) within `radius` of `pos`
-- (the first-run walkthrough's top-up check, Walkthrough.lua). owner: only their shards.
function XPSystem.ValueNear(pos: Vector3, radius: number, owner: any?): number
	local r2, sum = radius * radius, 0
	for _, gem in ipairs(activeGems) do
		if owner == nil or gem.Owner == nil or ownedBy(gem, owner) then
			local dx, dz = gem.Pos.X - pos.X, gem.Pos.Z - pos.Z
			if dx * dx + dz * dz <= r2 then
				sum += gem.Value
			end
		end
	end
	return sum
end

-- The active personal shards of `rp` (tests, DEV): count and total value.
function XPSystem.ShardsOf(rp): (number, number)
	local n, value = 0, 0
	for _, gem in ipairs(activeGems) do
		if gem.Owner ~= nil and ownedBy(gem, rp) then
			n += 1
			value += gem.Value
		end
	end
	return n, value
end

-- Pickup radius of a personal shard for this player: the default scaled by their pickup bonus.
local function shardRadius(rp): number
	local base = econ().XP.PickupRadius
	local stat = rp.Stats and rp.Stats.PickupRadius
	local ref = Config.Player.BasePickupRadius
	local radius = base
	if type(stat) == "number" and type(ref) == "number" and ref > 0 and stat == stat and stat < math.huge then
		-- bonuses add the same studs they add to the normal pickup radius (Doug's Clean Route
		-- +4, Collector's Bell +1.5/rank stay exact on shards)
		radius = math.max(base * 0.25, base + (stat - ref))
	end
	if rp.AuraPullRadius and rp.AuraPullRadius > radius then
		radius = rp.AuraPullRadius
	end
	return radius
end

local function inBand(rp, pos: Vector3): boolean
	return not HeightGrid.IsActive()
		or math.abs(HeightGrid.GroundY(rp.Root.Position.X, rp.Root.Position.Z) + Config.XP.GemHeight - pos.Y) <= Nav.HitBand
end

local function nearestCollector(gem: Gem, runPlayers): any?
	local pos = gem.Pos
	if gem.Owner then
		local owner = liveOwner(gem)
		-- only its owner, alive or downed, connected, not eliminated
		if owner and owner.Root and XPSystem.IsEligible(owner) and inBand(owner, pos) then
			local m = ((owner.Root.Position - pos) * Vector3.new(1, 0, 1)).Magnitude
			if m <= shardRadius(owner) then
				return owner
			end
		end
		return nil
	end
	local best, bestD = nil, math.huge
	for _, rp in ipairs(runPlayers) do
		if rp.Alive and rp.Root and not rp.Paused and inBand(rp, pos) then
			local d = (rp.Root.Position - pos) * Vector3.new(1, 0, 1)
			local radius = rp.Stats.PickupRadius
			if rp.AuraPullRadius and rp.AuraPullRadius > radius then
				radius = rp.AuraPullRadius
			end
			local m = d.Magnitude
			if m <= radius and m < bestD then
				best, bestD = rp, m
			end
		end
	end
	return best
end

-- Can this flight go on? Shared gems: a living collector; shards: their eligible owner.
local function flightValid(gem: Gem, target): boolean
	if not target.Root or not target.Root.Parent then
		return false
	end
	if gem.Owner then
		return target == gem.Owner and XPSystem.IsEligible(target)
	end
	return target.Alive == true
end

local function updateGems(dt: number, runPlayers)
	frame += 1
	local chunks = Config.XP.CheckChunks
	local collectDist = Config.XP.CollectDistance
	local now = runNow()
	local fadeSeconds = econ().XP.FadeSeconds or 0
	local i = 1
	while i <= #activeGems do
		local gem = activeGems[i]
		local removed = false
		if gem.Owner and not gem.Target then
			-- an uncollected shard: gone at its expiry, announced FadeSeconds before
			if now >= gem.Expires then
				releaseGem(i)
				removed = true
			elseif not gem.Fading and now >= gem.Expires - fadeSeconds then
				gem.Fading = true
				gem.Part:SetAttribute("Fade", workspace:GetServerTimeNow() + (gem.Expires - now))
			end
		end
		-- idle gems look for a collector every few frames (chunked)
		if not removed and not gem.Target and (gem.Index + frame) % chunks == 0 then
			local found = nearestCollector(gem, runPlayers)
			if found then
				setTarget(gem, found)
			end
		end
		local target = not removed and gem.Target or nil
		if target then
			if not flightValid(gem, target) then
				gem.Target = nil
				placeGem(gem, gem.Pos) -- rests where it hung (the last flight step) ...
				gem.Part:SetAttribute("Fly", nil) -- ... written once, then the flight ends
				gridAdd(gem)
			else
				local to = target.Root.Position - gem.Pos
				local dist = to.Magnitude
				if dist <= collectDist then
					target.GemsPicked = (target.GemsPicked or 0) + 1 -- daily quests (DailyQuests)
					local owner, value = gem.Owner, gem.Value
					releaseGem(i) -- released first: collected once, whatever the grant does
					removed = true
					if owner then
						XPSystem.GiveShardXP(owner, value)
					else
						XPSystem.GiveSharedXP(value)
					end
				else
					gem.Speed = math.max(gem.Speed, Config.XP.MagnetSpeed * 0.5) + Config.XP.MagnetAcceleration * dt
					gem.Speed = math.min(gem.Speed, Config.XP.MagnetSpeed * 3)
					local step = math.min(dist, gem.Speed * dt)
					gem.Pos += to.Unit * step -- the part stays put: clients draw the flight
				end
			end
		end
		if not removed then
			i += 1
		end
	end
end

------------------------------------------------------------------------------------------
-- Floor pickups and chests
------------------------------------------------------------------------------------------

function XPSystem.SpawnPickup(kind: string, position: Vector3): boolean
	if #pickups >= Config.Drops.MaxFloorPickups then
		return false
	end
	local pos = Vector3.new(position.X, HeightGrid.GroundY(position.X, position.Z) + 1.2, position.Z)
	local model = ModelBuilder.BuildPickup(kind, pos)
	model.Parent = pickupFolder
	table.insert(pickups, { Model = model, Kind = kind, Pos = pos, Expires = os.clock() + Config.Drops.PickupLifetime })
	return true
end

function XPSystem.SpawnChest(position: Vector3)
	local pos = HeightGrid.Ground(position)
	local model = ModelBuilder.BuildChest(pos)
	model.Parent = pickupFolder
	table.insert(pickups, { Model = model, Kind = "Chest", Pos = pos, Expires = os.clock() + Config.Drops.ChestLifetime })
end

-- Rolls a rare floor pickup for a normal kill (luck of the killer helps).
function XPSystem.RollFloorPickup(position: Vector3, luck: number): string?
	if rng:NextNumber() >= Config.Drops.FloorPickupChance * (1 + luck) then
		return nil
	end
	-- the Famine curse: no healing pickups
	local weights = Config.Drops.Weights
	if ctx.RunModifiers and ctx.RunModifiers.NoHealPickups() then
		weights = table.clone(weights)
		weights.Chicken = nil
	end
	local total = 0
	for _, w in pairs(weights) do
		total += w
	end
	local roll = rng:NextNumber() * total
	for kind, w in pairs(weights) do
		roll -= w
		if roll <= 0 then
			return XPSystem.SpawnPickup(kind, position) and kind or nil
		end
	end
	return nil
end

local function collectPickup(p: Pickup, rp)
	local kind = p.Kind
	if kind == "Chicken" then
		ctx.RunManager.Heal(rp, Config.Drops.ChickenHeal)
	elseif kind == "Magnet" then
		XPSystem.MagnetAll(rp)
		Fx.Ring(rp.Root.Position, 30, Color3.fromRGB(90, 200, 255))
	elseif kind == "Bomb" then
		ctx.EnemySpawner.KillInRadius(rp.Root.Position, Config.Drops.BombRadius, rp)
		Fx.Explosion(rp.Root.Position, Config.Drops.BombRadius)
		Fx.Sound("Explosion")
	elseif kind == "Chest" then
		ctx.LevelUpSystem.OpenChest(rp)
	end
	p.Model:Destroy()
end

local function updatePickups(runPlayers)
	local now = os.clock()
	local radius = Config.Drops.PickupRadius
	for i = #pickups, 1, -1 do
		local p = pickups[i]
		if now >= p.Expires then
			p.Model:Destroy()
			table.remove(pickups, i)
		else
			for _, rp in ipairs(runPlayers) do
				if rp.Alive and rp.Root and not rp.Paused then
					local d = (rp.Root.Position - p.Pos) * Vector3.new(1, 0, 1)
					if d.Magnitude <= radius + 1 then
						table.remove(pickups, i)
						collectPickup(p, rp)
						break
					end
				end
			end
		end
	end
end

------------------------------------------------------------------------------------------
-- Lifecycle
------------------------------------------------------------------------------------------

function XPSystem.Step(dt: number)
	if not ctx.RunManager.IsSimulating() then
		return
	end
	local runPlayers = ctx.RunManager.GetRunPlayers()
	updateGems(dt, runPlayers)
	updatePickups(runPlayers)
end

--[[
	Before the arena is swapped (travel to the next stage) nothing on the floor is lost:
	the XP of every shared gem left goes to the team (shared, like a pickup), every personal
	shard goes to its owner (if still eligible), every chest is opened for a living
	participant (taking turns), a chicken heals the first living one. Magnets and bombs have
	nothing left to do and just vanish. Call Clear() afterwards.
	includeFallen: when nobody is alive (the run ends at the portal) chests go to fallen
	participants instead.
]]
function XPSystem.CollectAll(includeFallen: boolean?)
	local total = 0
	local owed: { [any]: number } = {}
	for _, gem in ipairs(activeGems) do
		if gem.Owner then
			local owner = liveOwner(gem)
			if owner then
				owed[owner] = (owed[owner] or 0) + gem.Value
			end
		else
			total += gem.Value
		end
	end
	local alive = {}
	for _, rp in ipairs(ctx.RunManager.GetRunPlayers()) do
		if rp.Alive and rp.Root then
			table.insert(alive, rp)
		end
	end
	if #alive == 0 and includeFallen then
		-- the run ends with only fallen teammates left: their chests still pay out
		for _, rp in ipairs(ctx.RunManager.GetRunPlayers()) do
			if rp.Stats then
				table.insert(alive, rp)
			end
		end
	end
	-- personal shards: their owners (still eligible run players), whatever the floor
	local runPlayers = ctx.RunManager.GetRunPlayers()
	for owner, value in pairs(owed) do
		if table.find(runPlayers, owner) and XPSystem.IsEligible(owner) then
			XPSystem.GiveShardXP(owner, value)
		end
	end
	-- (handed out: a later Clear() releases the parts without paying them twice)
	if next(owed) ~= nil then
		for i = #activeGems, 1, -1 do
			if activeGems[i].Owner then
				releaseGem(i)
			end
		end
	end
	if #alive == 0 then
		return
	end
	if total > 0 then
		XPSystem.GiveSharedXP(total)
	end
	local turn = 0
	for i = #pickups, 1, -1 do
		local p = pickups[i]
		if p.Kind == "Chest" or p.Kind == "Chicken" then
			turn += 1
			local rp = alive[(turn - 1) % #alive + 1]
			table.remove(pickups, i)
			collectPickup(p, rp)
		end
	end
end

-- Removes every gem, pickup and chest (run cleanup).
function XPSystem.Clear()
	for i = #activeGems, 1, -1 do
		releaseGem(i)
	end
	for _, p in ipairs(pickups) do
		p.Model:Destroy()
	end
	table.clear(pickups)
	table.clear(bossPaid)
end

function XPSystem.Init(c)
	ctx = c
	gemFolder = Instance.new("Folder")
	gemFolder.Name = "SwarmGems"
	gemFolder.Parent = workspace
	pickupFolder = Instance.new("Folder")
	pickupFolder.Name = "SwarmPickups"
	pickupFolder.Parent = workspace
	local X = econ() and econ().XP
	MERGE_CELL = math.max(3, Config.XP.MergeRadius, X and X.MergeRadius or 0)
	local size = Config.XP.GemPoolSize
	if personal() and X and X.PoolSize then
		size = math.max(size, X.PoolSize) -- one shard per owner: up to 4x the parts
	end
	for i = 1, size do
		local part = ModelBuilder.BuildGem(i, gemFolder)
		gems[i] = { Part = part, Active = false, Value = 0, Pos = PARK.Position, Target = nil, Speed = 0, Index = i, Owner = nil, OwnerId = nil, Born = 0, Expires = math.huge, Fading = false }
		table.insert(freeGems, i)
	end
end

function XPSystem.Start() end

return XPSystem
