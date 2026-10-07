--[[
	XPSystem.lua
	Everything dropped on the arena floor: XP gems (pooled Parts), floor pickups
	(Chicken / Magnet / Bomb) and elite treasure chests. Also hands out shared XP.

	Gems
	  * 500 Parts built once (Config.XP.GemPoolSize) and parked under the map.
	  * Server owns positions; the client adds bob/spin locally using the gem's "Base"
	    attribute (see client VFX). Active gems have attribute Active = true.
	  * A player inside pickup radius makes the gem fly to them. The flight is replicated
	    ONCE: the gem's "Fly" attribute = the collector's UserId; clients animate the
	    homing flight themselves (same speed rule) toward that player's character. The
	    server still flies the gem's position every frame (not the part) and decides when
	    it is collected, so XP timing stays server-side. A flight that loses its target
	    writes the resting spot ("Base") once and clears "Fly".
	  * XP is SHARED: whoever collects a gem, every living participant gets its value
	    (times their own Growth stat, times Config.XP.CoopShare for the team size, so a
	    duo / trio does not level twice as fast as a solo hero).
	  * A gem that lands within Config.XP.MergeRadius of a resting one is merged into it
	    (values add up, capped at Config.XP.MergeMax), so piles stay a few bigger crystals.
	    Resting gems sit in a coarse grid for that lookup; flying gems are not in it.
	  * If the pool runs dry the value is merged into an existing active gem.
	  * Gems are anchored parts with no collision, query or touch: no physics per gem.
]]

local Config = require(game:GetService("ReplicatedStorage").Shared.Config)
local ModelBuilder = require(script.Parent.ModelBuilder)
local Fx = require(script.Parent.Fx)

local XPSystem = {}

local ctx
local rng = Random.new()
local PARK = CFrame.new(Config.Enemies.ParkPosition)

type Gem = {
	Part: BasePart,
	Active: boolean,
	Value: number,
	Pos: Vector3,
	Target: any?, -- run player it's flying to
	Speed: number,
	Index: number,
	Cell: number?, -- grid cell key while resting (nil while flying or parked)
}

local gemFolder: Folder
local pickupFolder: Folder
local gems: { Gem } = {}
local freeGems: { number } = {}
local activeGems: { Gem } = {} -- dense list of active gems
local frame = 0
local MERGE_CELL = 3 -- studs: grid cell edge, at least Config.XP.MergeRadius
local grid: { [number]: { Gem } } = {}

type Pickup = { Model: Model, Kind: string, Pos: Vector3, Expires: number }
local pickups: { Pickup } = {}

------------------------------------------------------------------------------------------
-- XP
------------------------------------------------------------------------------------------

function XPSystem.XPNeeded(level: number): number
	return Config.XP.Base + math.min(level, Config.XP.CapLevel) * Config.XP.PerLevel
		+ math.max(0, level - Config.XP.CapLevel) * Config.XP.AfterCapPerLevel
end

-- Shared-XP multiplier for the current team size (Config.XP.CoopShare, by living
-- participants): in Duo / Trio every gem is worth less to each player, since there are
-- PlayerCountMult times as many gems and everyone receives every one of them.
function XPSystem.CoopShare(): number
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
function XPSystem.PaceMult(): number
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
function XPSystem.GiveSharedXP(amount: number)
	amount *= XPSystem.CoopShare() * XPSystem.PaceMult()
	for _, rp in ipairs(ctx.RunManager.GetRunPlayers()) do
		if rp.Alive then
			XPSystem.GiveXP(rp, amount * rp.Stats.Growth)
		end
	end
end

function XPSystem.GiveXP(rp, amount: number)
	-- only a finite positive amount: NaN would freeze the bar for the rest of the run and
	-- an infinite one would spin the level loop below forever (server hang)
	if not (amount > 0 and amount < math.huge) then
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
-- Gems
------------------------------------------------------------------------------------------

local function gemKind(value: number): string
	if value >= Config.XP.GemValues.Large then
		return "Large"
	elseif value >= Config.XP.GemValues.Medium then
		return "Medium"
	end
	return "Small"
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

-- A resting gem near `pos` that can take `value` more (nearest first), or nil.
local function findMergeTarget(pos: Vector3, value: number): Gem?
	local radius = Config.XP.MergeRadius
	local best, bestD = nil, radius * radius
	local cx, cz = math.floor(pos.X / MERGE_CELL), math.floor(pos.Z / MERGE_CELL)
	for dx = -1, 1 do
		for dz = -1, 1 do
			local list = grid[(cx + dx) * 100003 + (cz + dz)]
			if list then
				for _, gem in ipairs(list) do
					local ox, oz = gem.Pos.X - pos.X, gem.Pos.Z - pos.Z
					local d = ox * ox + oz * oz
					if d <= bestD and gem.Value + value <= Config.XP.MergeMax then
						best, bestD = gem, d
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

function XPSystem.SpawnGem(position: Vector3, value: number)
	local pos = Vector3.new(position.X, Config.ArenaOrigin.Y + Config.XP.GemHeight, position.Z)
	local near = findMergeTarget(pos, value)
	if near then
		-- piles up: one gem carries the sum (same total XP, fewer crystals on the floor)
		near.Value += value
		ModelBuilder.StyleGem(near.Part, gemKind(near.Value))
		return
	end
	local index = table.remove(freeGems)
	if not index then
		-- Pool exhausted: merge into a random active gem so no XP is ever lost.
		local target = activeGems[rng:NextInteger(1, #activeGems)]
		if target then
			target.Value += value
			ModelBuilder.StyleGem(target.Part, gemKind(target.Value))
		end
		return
	end
	local gem = gems[index]
	gem.Active = true
	gem.Value = value
	gem.Target = nil
	gem.Speed = 0
	ModelBuilder.StyleGem(gem.Part, gemKind(value))
	placeGem(gem, pos)
	gem.Part:SetAttribute("Active", true)
	table.insert(activeGems, gem)
	gridAdd(gem)
end

local function releaseGem(i: number)
	local gem = activeGems[i]
	gem.Active = false
	gem.Target = nil
	gridRemove(gem)
	gem.Part:SetAttribute("Active", false)
	gem.Part:SetAttribute("Fly", nil)
	gem.Part.CFrame = PARK
	-- swap-remove from the dense list
	activeGems[i] = activeGems[#activeGems]
	activeGems[#activeGems] = nil
	table.insert(freeGems, gem.Index)
end

-- Magnet pickup: every gem on the floor flies to this player.
function XPSystem.MagnetAll(rp)
	for _, gem in ipairs(activeGems) do
		setTarget(gem, rp)
	end
end

-- Magnet Totem pulse: gems within `radius` of `pos` fly to this player.
function XPSystem.MagnetRadius(rp, pos: Vector3, radius: number)
	local r2 = radius * radius
	for _, gem in ipairs(activeGems) do
		local dx, dz = gem.Pos.X - pos.X, gem.Pos.Z - pos.Z
		if dx * dx + dz * dz <= r2 then
			setTarget(gem, rp)
		end
	end
end

-- The raw XP value of the gems on the floor (or flying) within `radius` of `pos`
-- (the first-run walkthrough's top-up check, Walkthrough.lua).
function XPSystem.ValueNear(pos: Vector3, radius: number): number
	local r2, sum = radius * radius, 0
	for _, gem in ipairs(activeGems) do
		local dx, dz = gem.Pos.X - pos.X, gem.Pos.Z - pos.Z
		if dx * dx + dz * dz <= r2 then
			sum += gem.Value
		end
	end
	return sum
end

local function nearestCollector(pos: Vector3, runPlayers): any?
	local best, bestD = nil, math.huge
	for _, rp in ipairs(runPlayers) do
		if rp.Alive and rp.Root and not rp.Paused then
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

local function updateGems(dt: number, runPlayers)
	frame += 1
	local chunks = Config.XP.CheckChunks
	local collectDist = Config.XP.CollectDistance
	local i = 1
	while i <= #activeGems do
		local gem = activeGems[i]
		local removed = false
		-- idle gems look for a collector every few frames (chunked)
		if not gem.Target and (gem.Index + frame) % chunks == 0 then
			local found = nearestCollector(gem.Pos, runPlayers)
			if found then
				setTarget(gem, found)
			end
		end
		local target = gem.Target
		if target then
			if not target.Alive or not target.Root or not target.Root.Parent then
				gem.Target = nil
				placeGem(gem, gem.Pos) -- rests where it hung (the last flight step) ...
				gem.Part:SetAttribute("Fly", nil) -- ... written once, then the flight ends
				gridAdd(gem)
			else
				local to = target.Root.Position - gem.Pos
				local dist = to.Magnitude
				if dist <= collectDist then
					target.GemsPicked = (target.GemsPicked or 0) + 1 -- daily quests (DailyQuests)
					XPSystem.GiveSharedXP(gem.Value)
					releaseGem(i)
					removed = true
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
	local pos = Vector3.new(position.X, Config.ArenaOrigin.Y + 1.2, position.Z)
	local model = ModelBuilder.BuildPickup(kind, pos)
	model.Parent = pickupFolder
	table.insert(pickups, { Model = model, Kind = kind, Pos = pos, Expires = os.clock() + Config.Drops.PickupLifetime })
	return true
end

function XPSystem.SpawnChest(position: Vector3)
	local pos = Vector3.new(position.X, Config.ArenaOrigin.Y, position.Z)
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
	the XP of every gem left goes to the team (shared, like a pickup), every chest is
	opened for a living participant (taking turns), a chicken heals the first living one.
	Magnets and bombs have nothing left to do and just vanish. Call Clear() afterwards.
	includeFallen: when nobody is alive (the run ends at the portal) chests go to fallen
	participants instead.
]]
function XPSystem.CollectAll(includeFallen: boolean?)
	local total = 0
	for _, gem in ipairs(activeGems) do
		total += gem.Value
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
end

function XPSystem.Init(c)
	ctx = c
	gemFolder = Instance.new("Folder")
	gemFolder.Name = "SwarmGems"
	gemFolder.Parent = workspace
	pickupFolder = Instance.new("Folder")
	pickupFolder.Name = "SwarmPickups"
	pickupFolder.Parent = workspace
	for i = 1, Config.XP.GemPoolSize do
		local part = ModelBuilder.BuildGem(i, gemFolder)
		gems[i] = { Part = part, Active = false, Value = 0, Pos = PARK.Position, Target = nil, Speed = 0, Index = i }
		table.insert(freeGems, i)
	end
end

function XPSystem.Start() end

return XPSystem
