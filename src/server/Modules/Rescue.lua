--[[
	Rescue.lua
	Feature 8, RESCUE A LOST VILLAGER (Config.Features.Rescue, Config.Explore.Rescue,
	docs/features/EXPLORE.md). An OPTIONAL placed EncounterDirector encounter.

	  Waiting    a lost villager waits on a spot the director reserved (far from the
	             spawn), waving. A living player within FindRadius starts the escort
	             (a one-time notice: "Escort: lead the villager to the portal ring"). On an
	             introductory stage it can't start during the boss fight or right after a
	             reward (EncounterDirector.IntroBlock; attribute Blocked).
	  Following  it walks (WalkSpeed) after the NEAREST living player and stops
	             FollowDistance studs from them. It walks around obstacles the way enemies
	             are pushed out of them (EnemyAI.PushOut) and stays inside the fence; if it
	             is stuck (not moving) more than CatchUp studs behind for CatchUpSeconds it hops to its hero (a
	             free spot beside them, pushed out of obstacles and clamped to the fence;
	             no free spot = no hop).
	             Enemies can hurt it (contact, Config.Enemies.ContactCooldown per enemy),
	             and enemies within AggroRadius that are closer to it than to any hero turn
	             toward it.
	  Saved      it stepped into the portal ring (Config.Stages.PortalRadius): every
	             teammate still in the run (a downed one waiting for a revive too) gets an item (ItemSystem.Roll with Rescue.Weights + ItemSystem.Grant,
	             the reward reel like a chest); if no item can be granted, run gold instead
	             (GoldSystem.AddRunGold). Exactly once.
	  Lost       its HP reached 0: a message says so; nothing is granted.
	Nothing happens to a villager nobody finds. Frozen runs (level-up, pause, reward reel)
	freeze it too (it only steps while the run simulates; hits use the run clock).
	Speech: a short line on a state change only (found, falling behind, delivered):
	attributes Say (text) and SaySeq (counts up; the client shows it briefly).

	World: model "Rescue" in workspace.SwarmEvents (anchored, no collision): EventKind =
	"Rescue", Title, State, Pos (updated ~10 times a second), HPFrac, Optional = true,
	Blocked ("" or why it can't start yet), Say / SaySeq.
]]

local Config = require(game:GetService("ReplicatedStorage").Shared.Config)
local Palette = require(game:GetService("ReplicatedStorage").Shared.Palette)
local ModelBuilder = require(script.Parent.ModelBuilder)
local MapBuilder = require(script.Parent.MapBuilder)
local Fx = require(script.Parent.Fx)
local EncounterDirector = require(script.Parent.EncounterDirector)
local HeightGrid = require(script.Parent.HeightGrid)
local Nav = require(game:GetService("ReplicatedStorage").SwarmV2.Run.RunConfig).Nav

local Rescue = {}

local NAME = "Rescue"
local P = Palette :: { [string]: Color3 }
local part = ModelBuilder.Part
local FLAT = Vector3.new(1, 0, 1)
local UPRIGHT = CFrame.Angles(0, 0, math.rad(90))
local POS_EVERY = 0.1 -- seconds between Pos attribute writes

type Villager = {
	Pos: Vector3,
	Face: Vector3,
	Stage: number,
	Model: Model,
	State: string,
	HP: number,
	MaxHP: number,
	Hits: { [any]: number }, -- enemy -> run time of its next allowed hit
	Stuck: number,
	PosTimer: number,
	ShownHP: number,
	WaveT: number,
	Behind: boolean, -- said "Wait for me!" and not caught up since
	SaidAt: number, -- run time of the last speech line
}

local ctx
local v: Villager? = nil
local buf = {}

local function K()
	return Config.Explore.Rescue
end

local function eventsFolder(): Folder
	local f = workspace:FindFirstChild("SwarmEvents")
	if not f then
		f = Instance.new("Folder")
		f.Name = "SwarmEvents"
		f.Parent = workspace
	end
	return f :: Folder
end

local function soloRun(): boolean
	return #ctx.RunManager.GetRunPlayers() <= 1
end

-- [stream D] a director run (the Cliffwood beacon run): the villager goes to the Stone Circle (the
-- beacon's landmark, info.PortalPos) and pays one passive choice per chest recipient
local function directorRun(): boolean
	return ctx.StageManager ~= nil and ctx.StageManager.IsDirector ~= nil and ctx.StageManager.IsDirector()
end

------------------------------------------------------------------------------------------
-- Model (a small part-built villager: tunic, head, straw hat, a lantern on a stick)
------------------------------------------------------------------------------------------

local function buildModel(m: Model)
	local function add(name: string, size: Vector3, at: Vector3, color: Color3, shape: Enum.PartType?, material: Enum.Material?, rot: CFrame?): BasePart
		local p = part({ Name = name, Shape = shape, Size = size, CFrame = CFrame.new(at) * (rot or CFrame.identity), Color = color, Material = material, CastShadow = name == "Body" })
		p.Parent = m
		return p
	end
	local root = add("Root", Vector3.new(0.4, 0.4, 0.4), Vector3.zero, P.wood_500)
	root.Transparency = 1
	m.PrimaryPart = root
	add("Leg", Vector3.new(0.45, 1.1, 0.45), Vector3.new(-0.3, 0.55, 0), P.leather_700)
	add("Leg", Vector3.new(0.45, 1.1, 0.45), Vector3.new(0.3, 0.55, 0), P.leather_700)
	add("Body", Vector3.new(1.4, 1.5, 0.9), Vector3.new(0, 1.85, 0), P.moss_500, nil, Enum.Material.Fabric)
	add("Belt", Vector3.new(1.45, 0.2, 0.95), Vector3.new(0, 1.3, 0), P.leather_600)
	add("Head", Vector3.new(1.0, 1.0, 1.0), Vector3.new(0, 3.1, 0), P.skin_400, Enum.PartType.Ball)
	add("Hat", Vector3.new(0.25, 2.0, 2.0), Vector3.new(0, 3.55, 0), P.sand_300, Enum.PartType.Cylinder, Enum.Material.Fabric, UPRIGHT)
	add("Crown", Vector3.new(0.6, 0.9, 0.9), Vector3.new(0, 3.8, 0), P.sand_400, Enum.PartType.Cylinder, Enum.Material.Fabric, UPRIGHT)
	add("Arm", Vector3.new(0.35, 1.2, 0.35), Vector3.new(-0.9, 1.9, 0), P.moss_600)
	add("Arm", Vector3.new(0.35, 1.2, 0.35), Vector3.new(0.9, 2.2, 0), P.moss_600, nil, nil, CFrame.Angles(0, 0, math.rad(-35)))
	add("Stick", Vector3.new(0.15, 2.2, 0.15), Vector3.new(1.35, 2.7, 0), P.wood_600, nil, nil, CFrame.Angles(0, 0, math.rad(-20)))
	local lamp = add("Lantern", Vector3.new(0.55, 0.55, 0.55), Vector3.new(1.75, 3.7, 0), P.gold_300, Enum.PartType.Ball, Enum.Material.Neon)
	local l = Instance.new("PointLight")
	l.Color = P.gold_300
	l.Range = 10
	l.Brightness = 1
	l.Shadows = false
	l.Parent = lamp
	local anchor = add("Anchor", Vector3.new(0.2, 0.2, 0.2), Vector3.new(0, 5.2, 0), P.gold_300)
	anchor.Transparency = 1
end

local function setAttr(m: Model, k: string, val: any)
	if m:GetAttribute(k) ~= val then
		m:SetAttribute(k, val)
	end
end

local function place(c: Villager)
	local look = c.Face.Magnitude > 0.1 and c.Face.Unit or Vector3.new(0, 0, -1)
	c.Model:PivotTo(CFrame.lookAt(c.Pos, c.Pos + look))
end

------------------------------------------------------------------------------------------
-- Escort
------------------------------------------------------------------------------------------

local function nearestPlayer(pos: Vector3): (any?, number)
	local best, bestD = nil, math.huge
	for _, rp in ipairs(ctx.RunManager.GetRunPlayers()) do
		local root: BasePart? = rp.Root
		if rp.Alive and not rp.Returned and root then
			local d = ((root.Position - pos) * FLAT).Magnitude
			if d < bestD then
				best, bestD = rp, d
			end
		end
	end
	return best, bestD
end

-- A short speech line over the villager (state changes only; the client shows it briefly).
local function say(c: Villager, line: string, force: boolean?)
	local now = ctx.RunManager.GetRunTime()
	if not force and now - c.SaidAt < (K().SayEvery or 6) then
		return
	end
	c.SaidAt = now
	c.Model:SetAttribute("Say", line)
	c.Model:SetAttribute("SaySeq", (tonumber(c.Model:GetAttribute("SaySeq")) or 0) + 1)
end

-- Inside the fence (the walking clamp).
local function clampToFence(p: Vector3): Vector3
	local x, z = HeightGrid.ClampXZ(p.X, p.Z, 2)
	return Vector3.new(x, HeightGrid.GroundY(x, z), z)
end

-- Catch-up hop: a free spot FollowDistance from the hero (behind them first, then around),
-- pushed out of obstacles and clamped to the fence. nil = no free spot (no hop this time).
local function hopSpot(target: Vector3, back: Vector3): Vector3?
	local k = K()
	for i = 0, 7 do
		local a = i * math.pi / 4
		local dir = CFrame.Angles(0, a, 0):VectorToWorldSpace(back)
		local at = clampToFence(Vector3.new(target.X, 0, target.Z) - dir * k.FollowDistance)
		if ctx.EnemyAI and ctx.EnemyAI.PushOut then
			at = clampToFence(ctx.EnemyAI.PushOut(at, k.Radius))
		end
		local blocked = (ctx.EnemyAI and ctx.EnemyAI.IsBlocked and ctx.EnemyAI.IsBlocked(at.X, at.Z, k.Radius))
			or not HeightGrid.IsWalkable(at.X, at.Z)
		-- bounded: never further from the hero than a short walk
		if not blocked and ((at - target) * FLAT).Magnitude <= k.FollowDistance * 3 then
			return at
		end
	end
	return nil
end

local function finish(c: Villager, state: string)
	c.State = state
	setAttr(c.Model, "State", state)
	setAttr(c.Model, "Pos", c.Pos)
	EncounterDirector.Finish(NAME)
end

local function save(c: Villager)
	if c.State ~= "Following" then
		return -- exactly once
	end
	finish(c, "Saved")
	Fx.Ring(c.Pos, 14, P.gold_300)
	Fx.Sound("Chest")
	local k = K()
	local anyItem = false
	if directorRun() and ctx.LevelUpSystem.QueueChoice then
		-- [stream D] one passive choice each (the chest recipients: connected, not eliminated,
		-- downed included), like a bought chest
		local list = ctx.LootSystem and ctx.LootSystem.ChestRecipients and ctx.LootSystem.ChestRecipients() or ctx.RunManager.GetRunPlayers()
		for _, rp in ipairs(list) do
			if not rp.Returned and rp.Stats then
				rp.VillagersSaved = (rp.VillagersSaved or 0) + 1 -- daily quests (DailyQuests)
				ctx.LevelUpSystem.QueueChoice(rp, "Chest", "PassiveOnly")
			end
		end
		ctx.RunManager.Broadcast("The villager is safe! " .. (soloRun() and "A passive choice for you." or "A passive choice for everyone."), Color3.fromRGB(255, 220, 120), nil, { Id = "rescue.result" })
		EncounterDirector.NoteReward()
		say(c, "Home at last! Thank you!", true)
		local dm = c.Model
		task.delay(1.5, function()
			if dm.Parent then
				dm:Destroy()
			end
		end)
		return
	end
	-- "for everyone": a teammate downed and waiting for a revive is still in the run
	for _, rp in ipairs(ctx.RunManager.GetRunPlayers()) do
		if (rp.Alive or rp.AwaitingRevive) and not rp.Returned and rp.Stats then
			rp.VillagersSaved = (rp.VillagersSaved or 0) + 1 -- daily quests (DailyQuests)
			local granted, dramatic = ctx.ItemSystem.Grant(rp, ctx.ItemSystem.Roll(k.Weights, rp.Stats.Luck), "Lost Villager", true)
			if granted then
				anyItem = true
				ctx.RunManager.HoldReward(rp, dramatic == true)
			else
				ctx.GoldSystem.AddRunGold(rp, k.Gold * (1 + k.GoldStageScale * (c.Stage - 1)) * rp.Stats.GoldMult)
			end
		end
	end
	local reward = anyItem and (soloRun() and "An item for you." or "An item for everyone.") or "Gold for everyone."
	ctx.RunManager.Broadcast("The villager is safe! " .. reward, Color3.fromRGB(255, 220, 120), nil, { Id = "rescue.result" })
	EncounterDirector.NoteReward() -- introductory stages: a quiet spell before the next one
	-- home through the portal: a last word, then gone (State Saved hides every escort label
	-- at once; the model only stays for the line)
	say(c, "Home at last! Thank you!", true)
	local m = c.Model
	task.delay(1.5, function()
		if m.Parent then
			m:Destroy()
		end
	end)
end

local function lose(c: Villager)
	if c.State ~= "Following" and c.State ~= "Waiting" then
		return
	end
	finish(c, "Lost")
	setAttr(c.Model, "HPFrac", 0)
	Fx.Ring(c.Pos, 8, P.stone_500)
	-- falls over, goes grey
	c.Model:PivotTo(CFrame.new(c.Pos) * CFrame.Angles(0, 0, math.rad(80)) * CFrame.new(0, 0.6, 0))
	for _, d in ipairs(c.Model:GetDescendants()) do
		if d:IsA("BasePart") and d.Name ~= "Root" and d.Name ~= "Anchor" then
			d.Color = d.Color:Lerp(P.stone_500, 0.6)
		elseif d:IsA("PointLight") then
			d.Enabled = false
		end
	end
	ctx.RunManager.Broadcast("The villager was lost... the swarm got them.", Color3.fromRGB(255, 130, 110), nil, { Id = "rescue.result" })
end

-- Enemies that touch it hurt it; nearby enemies closer to it than to any hero turn to it.
local function danger(c: Villager, nearestHero: number)
	local grid = ctx.EnemySpawner.Grid
	if not grid then
		return
	end
	local k = K()
	local now = ctx.RunManager.GetRunTime()
	local n = grid:QueryCircle(c.Pos.X, c.Pos.Z, k.AggroRadius, buf)
	for i = 1, n do
		local e = buf[i]
		if e.Alive and not e.Boss and not e.Harmless and not e.Untargetable then
			local d = ((e.Pos - c.Pos) * FLAT).Magnitude
			local reach = (e.Radius or 1) + k.Radius
			if d <= reach and (e.SpawnGrace or 0) <= 0 and (e.Damage or 0) > 0 and now >= (c.Hits[e] or 0) then
				c.Hits[e] = now + Config.Enemies.ContactCooldown
				c.HP -= e.Damage
			end
			-- turn toward the villager (EnemyAI keeps this heading until its next think)
			if d > reach * 0.8 and d < nearestHero and not e.Act and not (e.Def and (e.Def.Static or e.Def.Ranged or e.Def.Burrow)) then
				local to = (c.Pos - e.Pos) * FLAT
				if to.Magnitude > 0.1 then
					e.Dir = to.Unit
				end
			end
		end
	end
	if c.HP <= 0 then
		lose(c)
		return
	end
	local frac = math.floor(c.HP / c.MaxHP * 20 + 0.999) / 20
	if frac ~= c.ShownHP then
		c.ShownHP = frac
		setAttr(c.Model, "HPFrac", frac)
	end
end

local function step(dt: number, info)
	local c = v
	if not c or not ctx.RunManager.IsRunning() or not ctx.RunManager.IsSimulating() then
		return
	end
	local phase = info and info.Phase
	if phase == "Travel" then
		return
	end
	local k = K()
	if c.State == "Waiting" then
		local _, d = nearestPlayer(c.Pos)
		-- introductory stages: not during the boss fight / right after a reward
		local blocked = EncounterDirector.IntroBlock()
		setAttr(c.Model, "Blocked", blocked or "")
		if not blocked and d <= k.FindRadius then
			c.State = "Following"
			setAttr(c.Model, "State", "Following")
			setAttr(c.Model, "Blocked", "")
			Fx.Ring(c.Pos, 6, P.gold_300)
			say(c, "Thank you! Lead the way!", true)
			ctx.RunManager.Broadcast(directorRun() and "Escort: lead the villager to the Stone Circle" or "Escort: lead the villager to the portal ring", Color3.fromRGB(255, 220, 140), nil, { Id = "rescue.found" })
		else
			-- waving for help
			c.WaveT += dt
			return
		end
	end
	if c.State ~= "Following" then
		return
	end
	local rp, dist = nearestPlayer(c.Pos)
	local before = c.Pos
	if rp and rp.Root then
		local target = (rp.Root :: BasePart).Position
		local to = (target - c.Pos) * FLAT
		if dist > k.FollowDistance then
			local stepLen = math.min(k.WalkSpeed * dt, dist - k.FollowDistance)
			local dir = to.Unit
			-- height grid: round cliffs along its hero's flow field (as the enemies do)
			if HeightGrid.IsActive() and not (dist <= Nav.DirectSeekRange and HeightGrid.CanStep(c.Pos.X, c.Pos.Z, target.X, target.Z)) then
				local flow = HeightGrid.FlowDir(rp, c.Pos.X, c.Pos.Z)
				if flow ~= Vector3.zero then
					dir = flow
				end
			end
			local nextPos = c.Pos + dir * stepLen
			if ctx.EnemyAI and ctx.EnemyAI.PushOut then
				nextPos = ctx.EnemyAI.PushOut(nextPos, k.Radius)
			end
			if not HeightGrid.CanStep(c.Pos.X, c.Pos.Z, nextPos.X, nextPos.Z) then
				nextPos = c.Pos -- never off a cliff (the catch-up hop below gets it unstuck)
			end
			c.Pos = clampToFence(nextPos)
			c.Face = dir
		end
		-- stuck behind something far from its hero: hop to them
		if dist > k.CatchUp and ((c.Pos - before) * FLAT).Magnitude < k.WalkSpeed * dt * 0.25 then
			c.Stuck += dt
			if c.Stuck >= k.CatchUpSeconds then
				c.Stuck = 0
				local back = to.Magnitude > 0.1 and to.Unit or Vector3.new(0, 0, 1)
				local at = hopSpot(target, back)
				if at then
					c.Pos = at
					c.Behind = false
					Fx.Ring(c.Pos, 4, P.gold_300)
				end
			end
		else
			c.Stuck = 0
		end
		-- falling behind: one line, again only after it caught up
		local gap = ((target - c.Pos) * FLAT).Magnitude
		if not c.Behind and gap > (k.BehindDistance or 24) then
			c.Behind = true
			say(c, "Wait for me!")
		elseif c.Behind and gap < k.FollowDistance * 2.5 then
			c.Behind = false
		end
		place(c)
	end
	c.PosTimer -= dt
	if c.PosTimer <= 0 then
		c.PosTimer = POS_EVERY
		setAttr(c.Model, "Pos", c.Pos)
	end
	danger(c, dist)
	if c.State ~= "Following" then
		return
	end
	-- the portal ring
	local portal = info and info.PortalPos
	if portal and ((c.Pos - portal) * FLAT).Magnitude <= Config.Stages.PortalRadius then
		save(c)
	end
end

------------------------------------------------------------------------------------------
-- Director callbacks
------------------------------------------------------------------------------------------

local function cleanup(_reason: string?)
	local c = v
	v = nil
	if c then
		c.Model:Destroy()
	end
end

local function start(info): boolean
	cleanup("Restart")
	local k = K()
	local spot = EncounterDirector.FindSpot(NAME, { MinDistance = k.MinDistance, Clearance = k.Clearance })
	if not spot then
		return false
	end
	local m = Instance.new("Model")
	m.Name = NAME
	buildModel(m)
	local stage = math.max(1, info.Stage or 1)
	local hp = math.floor(k.HP * (1 + k.HPPerStage * (stage - 1)) + 0.5)
	local c: Villager = {
		Pos = spot,
		Face = (Config.ArenaOrigin - spot) * FLAT,
		Stage = stage,
		Model = m,
		State = "Waiting",
		HP = hp,
		MaxHP = hp,
		Hits = setmetatable({}, { __mode = "k" }) :: any,
		Stuck = 0,
		PosTimer = 0,
		ShownHP = 1,
		WaveT = 0,
		Behind = false,
		SaidAt = -math.huge,
	}
	place(c)
	MapBuilder.ClearDecor(info.Arena, spot, 3)
	m:SetAttribute("EventKind", NAME)
	m:SetAttribute("Title", "Lost Villager")
	m:SetAttribute("Optional", true)
	m:SetAttribute("State", "Waiting")
	m:SetAttribute("Pos", spot)
	m:SetAttribute("HPFrac", 1)
	m:SetAttribute("Blocked", "")
	m.Parent = eventsFolder()
	v = c
	return true
end

function Rescue.Get(): Villager?
	return v
end

function Rescue.Init(c)
	ctx = c
	EncounterDirector.Register(NAME, {
		Feature = "Rescue",
		Weight = Config.Explore.Rescue.Weight,
		OnStageStart = start,
		OnTick = step,
		OnCleanup = cleanup,
	})
end

return Rescue
