--[[
	XPSystem.lua
	Everything dropped on the arena floor: XP gems (pooled Parts), floor pickups
	(Chicken / Magnet / Bomb) and elite treasure chests. Also hands out shared XP.

	Gems
	  * 500 Parts built once (Config.XP.GemPoolSize) and parked under the map.
	  * Server owns positions; the client adds bob/spin locally using the gem's "Base"
	    attribute (see client VFX). Active gems have attribute Active = true.
	  * A player inside pickup radius makes the gem fly to them (server moves it).
	  * XP is SHARED: whoever collects a gem, every living participant gets its value
	    (times their own Growth stat).
	  * If the pool runs dry the value is merged into an existing active gem.
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
}

local gemFolder: Folder
local pickupFolder: Folder
local gems: { Gem } = {}
local freeGems: { number } = {}
local activeGems: { Gem } = {} -- dense list of active gems
local frame = 0

type Pickup = { Model: Model, Kind: string, Pos: Vector3, Expires: number }
local pickups: { Pickup } = {}

------------------------------------------------------------------------------------------
-- XP
------------------------------------------------------------------------------------------

function XPSystem.XPNeeded(level: number): number
	return Config.XP.Base + math.min(level, Config.XP.CapLevel) * Config.XP.PerLevel
end

-- Gives `amount` XP to every living run participant (each scaled by their Growth).
function XPSystem.GiveSharedXP(amount: number)
	for _, rp in ipairs(ctx.RunManager.GetRunPlayers()) do
		if rp.Alive then
			XPSystem.GiveXP(rp, amount * rp.Stats.Growth)
		end
	end
end

function XPSystem.GiveXP(rp, amount: number)
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

local function placeGem(gem: Gem, pos: Vector3)
	gem.Pos = pos
	gem.Part.CFrame = CFrame.new(pos)
	gem.Part:SetAttribute("Base", pos)
end

function XPSystem.SpawnGem(position: Vector3, value: number)
	local pos = Vector3.new(position.X, Config.ArenaOrigin.Y + Config.XP.GemHeight, position.Z)
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
end

local function releaseGem(i: number)
	local gem = activeGems[i]
	gem.Active = false
	gem.Target = nil
	gem.Part:SetAttribute("Active", false)
	gem.Part.CFrame = PARK
	-- swap-remove from the dense list
	activeGems[i] = activeGems[#activeGems]
	activeGems[#activeGems] = nil
	table.insert(freeGems, gem.Index)
end

-- Magnet pickup: every gem on the floor flies to this player.
function XPSystem.MagnetAll(rp)
	for _, gem in ipairs(activeGems) do
		gem.Target = rp
	end
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
			gem.Target = nearestCollector(gem.Pos, runPlayers)
		end
		local target = gem.Target
		if target then
			if not target.Alive or not target.Root or not target.Root.Parent then
				gem.Target = nil
			else
				local to = target.Root.Position - gem.Pos
				local dist = to.Magnitude
				if dist <= collectDist then
					XPSystem.GiveSharedXP(gem.Value)
					releaseGem(i)
					removed = true
				else
					gem.Speed = math.max(gem.Speed, Config.XP.MagnetSpeed * 0.5) + Config.XP.MagnetAcceleration * dt
					gem.Speed = math.min(gem.Speed, Config.XP.MagnetSpeed * 3)
					local step = math.min(dist, gem.Speed * dt)
					placeGem(gem, gem.Pos + to.Unit * step)
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

function XPSystem.SpawnPickup(kind: string, position: Vector3)
	if #pickups >= Config.Drops.MaxFloorPickups then
		return
	end
	local pos = Vector3.new(position.X, Config.ArenaOrigin.Y + 1.2, position.Z)
	local model = ModelBuilder.BuildPickup(kind, pos)
	model.Parent = pickupFolder
	table.insert(pickups, { Model = model, Kind = kind, Pos = pos, Expires = os.clock() + Config.Drops.PickupLifetime })
end

function XPSystem.SpawnChest(position: Vector3)
	local pos = Vector3.new(position.X, Config.ArenaOrigin.Y, position.Z)
	local model = ModelBuilder.BuildChest(pos)
	model.Parent = pickupFolder
	table.insert(pickups, { Model = model, Kind = "Chest", Pos = pos, Expires = os.clock() + Config.Drops.ChestLifetime })
end

-- Rolls a rare floor pickup for a normal kill (luck of the killer helps).
function XPSystem.RollFloorPickup(position: Vector3, luck: number)
	if rng:NextNumber() >= Config.Drops.FloorPickupChance * (1 + luck) then
		return
	end
	local total = 0
	for _, w in pairs(Config.Drops.Weights) do
		total += w
	end
	local roll = rng:NextNumber() * total
	for kind, w in pairs(Config.Drops.Weights) do
		roll -= w
		if roll <= 0 then
			XPSystem.SpawnPickup(kind, position)
			return
		end
	end
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
