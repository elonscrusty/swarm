-- fall-regression: real server (no physics in the mock, positions only move when set).
-- Owner bug "stuck falling through map" after a stage travel: the speed check accepted
-- spots under the floor as valid and snapped a falling hero back to them forever.
-- Checks, for a duo travelling through every arena (Desert included): roots are held
-- (anchored) for the whole travel and released after it, each hero lands on a colliding
-- floor at the arena floor height, a hero under the floor / outside the arena is put
-- back on the floor (stream E1: at most 10% of max HP, never the last hit point, then a 3 s
-- damage lockout with no second cost inside it), and the speed check never stores a spot
-- under the floor.
local Players = game:GetService("Players")
local player = Players.LocalPlayer
local friend = preview.addPlayer("FallHelper", 2)
preview.startServer()
preview.advance(1)
local RM = preview.server("RunManager")
local SM = preview.server("StageManager")
local LU = preview.server("LevelUpSystem")
local Config = require(game:GetService("ReplicatedStorage").Shared.Config)
local FLOOR = Config.ArenaOrigin.Y
local players = { player, friend }
local function rps()
	return { assert(RM.GetRunPlayer(player)), assert(RM.GetRunPlayer(friend)) }
end
local function settle()
	for _, rp in ipairs(rps()) do
		rp.InvulnUntil = math.huge
		LU.Cancel(rp)
	end
end
-- a colliding floor slab: the old arenas' "Floor" parts or the Cliffwood map's NavGround slabs
-- (its basin floor is at the same height; HeightGrid stays flat here, the mock's rays hit nothing)
local CollectionService = game:GetService("CollectionService")
local function floorUnder(pos: Vector3): BasePart?
	for _, d in ipairs(workspace:GetDescendants()) do
		if d:IsA("BasePart") and (d.Name == "Floor" or CollectionService:HasTag(d, "NavGround")) and d.CanCollide then
			local top = d.Position.Y + d.Size.Y / 2
			if math.abs(top - FLOOR) < 0.05 and math.abs(pos.X - d.Position.X) <= d.Size.X / 2
				and math.abs(pos.Z - d.Position.Z) <= d.Size.Z / 2 then
				return d
			end
		end
	end
	return nil
end
local function checkStanding(label: string)
	for i, rp in ipairs(rps()) do
		local root = assert(rp.Root, label .. ": no root")
		local p = root.Position
		if not floorUnder(p) then
			preview.log("FAIL", label, "player", i, "has no colliding floor under", tostring(p))
		end
		if p.Y < FLOOR + 1 or p.Y > FLOOR + 6 then
			preview.log("FAIL", label, "player", i, "not at standing height", tostring(p))
		end
		if root.Anchored then
			preview.log("FAIL", label, "player", i, "still anchored after travel")
		end
	end
end
local st = game:GetService("ReplicatedStorage"):WaitForChild("SwarmState")
local function arenaName()
	return st:GetAttribute("Arena") or "?"
end
local seen = {}
-- one expedition (5 stages) per start arena; two starts cover all six arenas
local function expedition(first: string)
	for _ = 1, 120 do
		if RM.StartTeamRun(players, "Duo", first, player) then
			break
		end
		preview.advance(0.5)
	end
	preview.advance(6)
	settle()
	checkStanding("stage 1 " .. arenaName())
	seen[arenaName()] = true
	for stageN = 2, 5 do
		settle()
		assert(SM.DevNextStage(), "dev next stage must start the travel")
		local held, sawTravel = true, false
		for _ = 1, 40 do
			preview.advance(0.1)
			settle()
			if SM.IsHolding() then
				sawTravel = true
				for _, rp in ipairs(rps()) do
					if rp.Root and not rp.Root.Anchored then
						held = false
					end
				end
			elseif sawTravel then
				break
			end
		end
		preview.advance(0.2)
		if not sawTravel then
			preview.log("FAIL stage", stageN, "never travelled")
		elseif not held then
			preview.log("FAIL stage", stageN, "a root was not held during travel")
		end
		local name = arenaName()
		seen[name] = true
		checkStanding("stage " .. stageN .. " " .. name)
		preview.log("travelled to stage", stageN, name)
	end
end
-- every arena may be the first stage here (Desert needs BestStage 5 in the lobby)
for _, p in ipairs(players) do
	local data = preview.server("DataService").GetData(p)
	if data then
		data.Stats.BestStage = math.max(data.Stats.BestStage or 0, 10)
	end
end
-- the single map first (Cliffwood: every stage on one map), then the old biome tour, then any
-- arena the tour skipped; the rescue checks below run on the last (flat) arena
local function missingArena(): string?
	local names = {}
	for name, def in pairs(Config.Arenas) do
		if type(def) == "table" and def.DisplayName and not seen[name] then
			table.insert(names, name)
		end
	end
	table.sort(names)
	return names[1]
end
local starts = { "Cliffwood", "Desert" }
for i = 1, 6 do
	local first = starts[i] or missingArena()
	if not first then
		break
	end
	if i > 1 then
		RM.FinishFromPortal() -- finish this expedition, then start the next one
	end
	expedition(first)
end
for name, def in pairs(Config.Arenas) do
	if type(def) == "table" and def.DisplayName and not seen[name] then
		preview.log("FAIL arena never visited:", name)
	end
end

-- rescue: under the floor (the owner's state: last "valid" spot under the floor too)
settle()
local rp = rps()[1]
local hp = rp.HP
rp.InvulnUntil = 0
local spot = rp.Root.Position
local function drop(at: Vector3)
	rp.Root.CFrame = CFrame.new(at)
	rp.Root.AssemblyLinearVelocity = Vector3.new(0, -60, 0)
end
drop(Vector3.new(spot.X, FLOOR - 15, spot.Z))
rp.LastValidPos = rp.Root.Position
preview.advance(0.6)
local p = rp.Root.Position
assert(p.Y > FLOOR + 1 and p.Y < FLOOR + 6, "a hero under the floor must be put back on it, got " .. tostring(p))
local maxHP = rp.Stats.MaxHP
assert(rp.HP < hp and hp - rp.HP <= maxHP * 0.10 + 1e-6, string.format("the rescue costs at most 10%% of max HP (%.1f -> %.1f of %.1f)", hp, rp.HP, maxHP))
assert(rp.InvulnUntil >= RM.GetRunTime() + 2.0, "the rescue grants the 3 s damage lockout")
local afterFirst = rp.HP
assert((rp.FallRescues or 0) >= 1, "rescue counted")
assert(floorUnder(p), "rescued onto a colliding floor")
-- deep fall (inside the first rescue's lockout: no second cost)
drop(Vector3.new(spot.X + 3, FLOOR - 150, spot.Z))
preview.advance(0.2)
assert(rp.Root.Position.Y > FLOOR + 1, "deep fall rescued")
assert(rp.HP == afterFirst, "no second rescue cost inside the lockout")
-- out of bounds (past the boundary walls)
drop(Vector3.new(Config.Arenas.Size, FLOOR + 3, 0))
preview.advance(0.2)
p = rp.Root.Position
assert(math.abs(p.X) <= Config.Arenas.Size / 2 and p.Y > FLOOR + 1, "out-of-bounds hero rescued, got " .. tostring(p))
-- the speed check never stores a spot under the floor
rp.Root.CFrame = CFrame.new(spot.X, FLOOR - 3, spot.Z)
rp.Root.AssemblyLinearVelocity = Vector3.zero
preview.advance(1.1)
assert(not rp.LastValidPos or rp.LastValidPos.Y >= FLOOR - 1, "speed check stored an under-floor spot")
-- a downed (anchored) hero under the floor is moved too
settle()
local mate = rps()[2]
mate.InvulnUntil, mate.RevivesLeft, mate.ProductReviveUsed = 0, 0, true
RM.DamagePlayer(mate, 1e6, "Test")
preview.advance(0.1)
if not mate.Alive and mate.Root then
	mate.Root.CFrame = CFrame.new(10, FLOOR - 30, 10)
	preview.advance(0.2)
	assert(mate.Root.Position.Y > FLOOR + 1, "downed hero under the floor rescued")
end
preview.log("PASS travel hold, floor under every hero in every arena, below-floor / out-of-bounds rescue")
