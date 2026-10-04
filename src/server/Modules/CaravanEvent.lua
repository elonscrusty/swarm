--[[
	CaravanEvent.lua
	The LOST CARAVAN: an optional encounter, at most one per stage (Config.Caravan). A
	stranded supply cart with a broken wheel stands away from the arena centre; LootSystem
	places it with the loot placement rules (LootSystem.BuildStage → Build) and removes it
	with the stage (LootSystem.Clear → Clear: travel, run end, the last player leaving
	through MAIN MENU).

	  Waiting    a living player steps into the cart's ring (ZoneRadius) during a fighting
	             phase (Explore, Boss, Surge) → the defence starts.
	  Defending  time in the ring adds up to HoldSeconds (any living teammate counts, a
	             teammate choosing a card included). A wave of this minute's enemies climbs
	             out around the cart on start and every WaveEvery seconds (the last one with
	             an elite). The ring may stand empty LeaveGrace seconds in a row; longer and
	             the caravan is lost. While the portal is open (Open) time still counts but
	             no waves come. Frozen runs (level-up, pause, reward reel) stop everything.
	  Saved      every living teammate gets one item (Config.Caravan.Weights, through
	             ItemSystem.Grant + the reward reel) and run gold (GoldSystem.AddRunGold).
	  Lost       nothing; the cart goes dark. Its waves stay and fight on.
	Rewards use the existing paths only: no new currency, nothing bought.

	World: one model in workspace.SwarmEvents with attributes the client reads (LootUI:
	world marker, edge arrow, defence bar): EventKind = "Caravan", Title, State, Pos,
	Radius, Hold (seconds), Progress (0-1), Left (seconds still to hold), Grace (seconds
	before it is lost while the ring is empty, -1 = someone is in it), Benefit.
]]

local Config = require(game:GetService("ReplicatedStorage").Shared.Config)
local EnemyData = require(game:GetService("ReplicatedStorage").Shared.EnemyData)
local Palette = require(game:GetService("ReplicatedStorage").Shared.Palette)
local MapBuilder = require(script.Parent.MapBuilder)
local ModelBuilder = require(script.Parent.ModelBuilder)
local Fx = require(script.Parent.Fx)

local CaravanEvent = {}

local P = Palette :: { [string]: Color3 }
local part = ModelBuilder.Part
local NEON = Enum.Material.Neon
local UPRIGHT = CFrame.Angles(0, 0, math.rad(90))
local FACE_CAMERA = CFrame.Angles(0, math.pi, 0)
local FLAT = Vector3.new(1, 0, 1)
local RING_FILL = 0.88 -- the hold ring's faint fill (its dashed edge carries the shape)

type Caravan = {
	Pos: Vector3,
	Model: Model,
	State: string,
	Stage: number,
	Progress: number, -- seconds held
	Empty: number, -- seconds the ring has stood empty in a row
	WaveTimer: number,
	Waves: number,
	Glow: { BasePart },
	Light: PointLight?,
	Ring: BasePart?,
	Marks: { BasePart }, -- the ring's dashed edge (a friendly area: edge marks, not a filled pool)
	Shown: { [string]: any },
	StartPhase: string?, -- the stage phase the defence began in
}

local ctx
local rng = Random.new()
local folder: Folder
local current: Caravan? = nil

------------------------------------------------------------------------------------------
-- Model
------------------------------------------------------------------------------------------

local function add(m: Model, cf: CFrame, name: string, size: Vector3, at: Vector3, color: Color3, material: Enum.Material?, shape: Enum.PartType?, rot: CFrame?): BasePart
	local p = part({
		Name = name,
		Shape = shape,
		Size = size,
		CFrame = cf * CFrame.new(at) * (rot or CFrame.identity),
		Color = color,
		Material = material,
		CastShadow = name == "Bed" or name == "Canvas",
	})
	p.Parent = m
	return p
end

-- A part-built covered cart, tipped toward its broken front-left wheel, with spilled
-- crates, a banded cargo chest, a banner pole and a lantern (the glow that shows its
-- state). The canvas is plain cloth (no Fabric texture: it read as a fine pattern beside
-- the flat-coloured props) and wears the kingdom's crimson band with a gold crest on the
-- side facing the camera, like the altar's banner.
local function buildCart(c: Caravan, cf: CFrame)
	local m = c.Model
	local wood, dark, canvas = P.wood_500, P.wood_700, P.ivory_300
	local tip = cf * CFrame.Angles(math.rad(-4), 0, math.rad(5)) -- sagging on the broken wheel
	add(m, tip, "Bed", Vector3.new(7, 0.8, 3.6), Vector3.new(0, 1.9, 0), wood)
	add(m, tip, "Rail", Vector3.new(7, 0.6, 0.25), Vector3.new(0, 2.6, 1.7), dark)
	add(m, tip, "Rail", Vector3.new(7, 0.6, 0.25), Vector3.new(0, 2.6, -1.7), dark)
	add(m, tip, "Rail", Vector3.new(0.25, 0.6, 3.6), Vector3.new(-3.4, 2.6, 0), dark)
	-- canvas cover: two slopes and its hoops
	for _, z in ipairs({ 0.95, -0.95 }) do
		add(m, tip, "Canvas", Vector3.new(5.4, 0.18, 2.3), Vector3.new(0.4, 3.75, z), canvas, nil, nil, CFrame.Angles(math.rad(z > 0 and 40 or -40), 0, 0))
	end
	-- heraldry on the camera side (model -Z): a crimson band and a gold crest
	local slope = tip * CFrame.new(0.4, 3.75, -0.95) * CFrame.Angles(math.rad(-40), 0, 0)
	local band = part({ Name = "Heraldry", Size = Vector3.new(1.5, 0.06, 2.34), CFrame = slope * CFrame.new(0, 0.12, 0), Color = P.crimson_500 })
	band.Parent = m
	local crest = part({ Name = "Heraldry", Shape = Enum.PartType.Cylinder, Size = Vector3.new(0.08, 0.95, 0.95), CFrame = slope * CFrame.new(0, 0.17, 0.1) * UPRIGHT, Color = P.gold_400 })
	crest.Parent = m
	for _, x in ipairs({ -2.0, 0.4, 2.8 }) do
		add(m, tip, "Hoop", Vector3.new(0.2, 0.2, 3.2), Vector3.new(x, 4.55, 0), dark)
	end
	-- wheels (axles along the cart's width): three on, one broken in the grass
	local wheel = Vector3.new(0.35, 2.6, 2.6)
	local axle = CFrame.Angles(0, math.rad(90), 0)
	add(m, tip, "Wheel", wheel, Vector3.new(2.4, 1.3, 1.95), dark, nil, Enum.PartType.Cylinder, axle)
	add(m, tip, "Wheel", wheel, Vector3.new(2.4, 1.3, -1.95), dark, nil, Enum.PartType.Cylinder, axle)
	add(m, tip, "Wheel", wheel, Vector3.new(-2.4, 1.3, -1.95), dark, nil, Enum.PartType.Cylinder, axle)
	add(m, cf, "Wheel", wheel, Vector3.new(-3.6, 0.2, 3.6), dark, nil, Enum.PartType.Cylinder, UPRIGHT * CFrame.Angles(math.rad(20), 0, 0))
	add(m, tip, "Shaft", Vector3.new(3.4, 0.25, 0.25), Vector3.new(4.9, 1.2, 0.7), dark, nil, nil, CFrame.Angles(0, 0, math.rad(-12)))
	add(m, tip, "Shaft", Vector3.new(3.4, 0.25, 0.25), Vector3.new(4.9, 1.2, -0.7), dark, nil, nil, CFrame.Angles(0, 0, math.rad(-12)))
	-- spilled cargo
	add(m, cf, "Crate", Vector3.new(1.4, 1.4, 1.4), Vector3.new(-4.6, 0.7, -1.2), P.wood_400, nil, nil, CFrame.Angles(0, math.rad(25), 0))
	add(m, cf, "Crate", Vector3.new(1.1, 1.1, 1.1), Vector3.new(-4.0, 0.55, -3.0), P.wood_600, nil, nil, CFrame.Angles(0, math.rad(-15), 0))
	add(m, cf, "Sack", Vector3.new(1.2, 1.2, 1.2), Vector3.new(-5.4, 0.5, 0.6), P.sand_400, Enum.Material.Fabric, Enum.PartType.Ball)
	-- the cargo worth saving: a small banded chest in the open back of the cart
	add(m, tip, "Cargo", Vector3.new(1.5, 0.9, 1.1), Vector3.new(-1.9, 2.75, 0.2), P.wood_400)
	add(m, tip, "Cargo", Vector3.new(1.56, 0.32, 1.16), Vector3.new(-1.9, 3.35, 0.2), P.wood_500)
	for _, x in ipairs({ -2.35, -1.45 }) do
		add(m, tip, "Cargo", Vector3.new(0.16, 1.28, 1.18), Vector3.new(x, 2.94, 0.2), P.gold_500, Enum.Material.Metal)
	end
	-- banner pole with a pennant: the marker you see from afar
	add(m, cf, "Pole", Vector3.new(0.25, 7, 0.25), Vector3.new(3.8, 3.5, -3.2), dark)
	local flag = add(m, cf, "Banner", Vector3.new(2.2, 1.3, 0.1), Vector3.new(4.95, 6.2, -3.2), P.crimson_400, Enum.Material.Fabric)
	table.insert(c.Glow, flag)
	-- lantern
	local lantern = part({ Name = "Lantern", Shape = Enum.PartType.Ball, Size = Vector3.new(0.9, 0.9, 0.9), CFrame = cf * CFrame.new(3.8, 7.3, -3.2), Color = P.gold_300, Material = NEON })
	lantern.Parent = m
	table.insert(c.Glow, lantern)
	local l = Instance.new("PointLight")
	l.Color = P.gold_300
	l.Range = 16
	l.Brightness = 1.2
	l.Shadows = false
	l.Parent = lantern
	c.Light = l
	-- the ring to hold
	local r = Config.Caravan.ZoneRadius
	local disc = part({ Name = "Ring", Shape = Enum.PartType.Cylinder, Size = Vector3.new(0.06, r * 2, r * 2), CFrame = CFrame.new(c.Pos + Vector3.new(0, 0.06, 0)) * UPRIGHT, Color = P.gold_300, Transparency = RING_FILL })
	disc.Parent = m
	c.Ring = disc
	-- the ring's edge: short dashes, so a friendly hold area reads differently from a
	-- filled hostile pool of the same warm colour
	local n = 28
	for i = 1, n do
		local a = (i - 0.5) / n * math.pi * 2
		local at = c.Pos + Vector3.new(math.cos(a) * (r - 0.4), 0.09, math.sin(a) * (r - 0.4))
		local dash = part({ Name = "RingMark", Size = Vector3.new(0.45, 0.06, math.pi * 2 * r / n * 0.5), CFrame = CFrame.new(at) * CFrame.Angles(0, -a, 0), Color = P.ivory_100, Transparency = 0.25 })
		dash.Parent = m
		table.insert(c.Marks, dash)
	end
end

local function setAttr(c: Caravan, k: string, v: any)
	if c.Shown[k] ~= v then
		c.Shown[k] = v
		c.Model:SetAttribute(k, v)
	end
end

local function setState(c: Caravan, s: string)
	c.State = s
	setAttr(c, "State", s)
end

local function recolour(c: Caravan, color: Color3, dim: boolean)
	for _, g in ipairs(c.Glow) do
		if g.Name == "Lantern" then
			g.Color = color
			g.Transparency = dim and 0.6 or 0
		end
	end
	if c.Light then
		c.Light.Color = color
		c.Light.Enabled = not dim
	end
	if c.Ring then
		c.Ring.Color = color
		c.Ring.Transparency = dim and 1 or RING_FILL
	end
	for _, mark in ipairs(c.Marks) do
		mark.Color = dim and P.stone_500 or (color == P.crimson_300 and P.ivory_100 or color)
		mark.Transparency = dim and 1 or 0.25
	end
end

------------------------------------------------------------------------------------------
-- Stage lifecycle (LootSystem)
------------------------------------------------------------------------------------------

-- Removes the caravan (travel, run end). Its waves are normal enemies and stay.
function CaravanEvent.Clear()
	local c = current
	current = nil
	if c then
		c.Model:Destroy()
	end
end

-- Should this stage get a caravan? (Config.Caravan.Chance)
function CaravanEvent.Roll(): boolean
	return rng:NextNumber() < (Config.Caravan.Chance or 1)
end

-- Places this stage's caravan at floor point `pos` (LootSystem found the spot).
function CaravanEvent.Build(arena, pos: Vector3, stage: number)
	CaravanEvent.Clear()
	local cf = CFrame.new(pos) * FACE_CAMERA * CFrame.Angles(0, rng:NextNumber(-0.5, 0.5), 0)
	local model = Instance.new("Model")
	model.Name = "Caravan"
	local c: Caravan = {
		Pos = pos,
		Model = model,
		State = "Waiting",
		Stage = math.max(1, stage),
		Progress = 0,
		Empty = 0,
		WaveTimer = 0,
		Waves = 0,
		Glow = {},
		Light = nil,
		Ring = nil,
		Marks = {},
		Shown = {},
	}
	buildCart(c, cf)
	local K = Config.Caravan
	setAttr(c, "EventKind", "Caravan")
	setAttr(c, "Title", "Lost Caravan")
	setAttr(c, "Pos", pos)
	setAttr(c, "Radius", K.ZoneRadius)
	setAttr(c, "Hold", K.HoldSeconds)
	setAttr(c, "Progress", 0)
	setAttr(c, "Left", K.HoldSeconds)
	setAttr(c, "Grace", -1)
	setAttr(c, "Benefit", "An item and gold for every teammate")
	setState(c, "Waiting")
	-- the cart blocks heroes and enemies like any prop (an axis-aligned box: it is small)
	MapBuilder.AddCollider(arena, { Kind = "Box", Size = { 6, 6 }, Height = 4 }, CFrame.new(pos), 1)
	MapBuilder.ClearDecor(arena, pos, K.ZoneRadius * 0.6)
	model.Parent = folder
	current = c
end

-- The current caravan (preview scenes / tests).
function CaravanEvent.Get(): Caravan?
	return current
end

------------------------------------------------------------------------------------------
-- Defence
------------------------------------------------------------------------------------------

local function inRing(c: Caravan, rp): boolean
	local root: BasePart? = rp.Root
	if not rp.Alive or rp.Returned or not root then
		return false
	end
	local d = (root.Position - c.Pos) * FLAT
	return d.X * d.X + d.Z * d.Z <= Config.Caravan.ZoneRadius ^ 2
end

local function anyInRing(c: Caravan, needUnpaused: boolean): boolean
	for _, rp in ipairs(ctx.RunManager.GetRunPlayers()) do
		if inRing(c, rp) and not (needUnpaused and rp.Paused) then
			return true
		end
	end
	return false
end

local function livingPlayers(): number
	local n = 0
	for _, rp in ipairs(ctx.RunManager.GetRunPlayers()) do
		if rp.Alive or rp.AwaitingRevive then
			n += 1
		end
	end
	return math.max(1, n)
end

local function totalWaves(): number
	local K = Config.Caravan
	return math.max(1, math.ceil(K.HoldSeconds / K.WaveEvery))
end

-- An enemy type of this minute's mix that can come in a ring: no ranged, support,
-- burrowing, wave-shy or boss types.
local function waveType(): string
	local row = EnemyData.GetSpawnRow(ctx.EnemySpawner.ProgressionTime())
	local total = 0
	local pool = {}
	for id, w in pairs(row.Weights) do
		local def = EnemyData.Enemies[id]
		if def and not def.Ranged and not def.Support and not def.Burrow and not def.NoWave and not def.IsBoss then
			table.insert(pool, { id, w })
			total += w
		end
	end
	if total <= 0 then
		return "Slime"
	end
	local roll = rng:NextNumber() * total
	for _, e in ipairs(pool) do
		roll -= e[2]
		if roll <= 0 then
			return e[1]
		end
	end
	return pool[#pool][1]
end

local function spawnWave(c: Caravan)
	local K = Config.Caravan
	c.Waves += 1
	local last = c.Waves >= totalWaves()
	local count = math.min(K.WaveMax, K.WaveBase + K.WavePerStage * c.Stage + K.WavePerExtraPlayer * (livingPlayers() - 1))
	local typeId = waveType()
	local def = EnemyData.Enemies[typeId]
	local offset = rng:NextNumber(0, math.pi * 2)
	local made = 0
	for i = 1, count do
		local elite = last and K.LastWaveElite and i == 1
		for _ = 1, 4 do
			local a = offset + (i / count) * math.pi * 2 + rng:NextNumber(-0.25, 0.25)
			local r = rng:NextNumber(K.WaveRadius[1], K.WaveRadius[2])
			local x, z = ctx.EnemySpawner.ClampToArena(c.Pos.X + math.cos(a) * r, c.Pos.Z + math.sin(a) * r, 4)
			local radius = def.Radius * (elite and Config.Enemies.EliteSizeMult or 1)
			if def.Ghost or not ctx.EnemyAI.IsBlocked(x, z, radius) then
				if ctx.EnemySpawner.Spawn(typeId, Vector3.new(x, Config.ArenaOrigin.Y, z), elite and { Elite = true } or nil) then
					made += 1
				end
				break
			end
		end
	end
	if made > 0 then
		Fx.Ring(c.Pos, K.WaveRadius[2], P.crimson_400)
	end
	return made
end

local function start(c: Caravan)
	setState(c, "Defending")
	c.Progress = 0
	c.Empty = 0
	c.Waves = 0
	c.WaveTimer = 0 -- the first wave comes at once
	recolour(c, P.crimson_300, false)
	Fx.Ring(c.Pos, Config.Caravan.ZoneRadius, P.gold_300)
	Fx.Sound("BossBanner")
	ctx.RunManager.Broadcast(string.format("Defend the caravan! Hold its ring for %d seconds.", Config.Caravan.HoldSeconds), Color3.fromRGB(255, 200, 120))
end

local function succeed(c: Caravan, line: string?)
	local K = Config.Caravan
	setState(c, "Saved")
	c.Progress = K.HoldSeconds
	setAttr(c, "Progress", 1)
	setAttr(c, "Left", 0)
	setAttr(c, "Grace", -1)
	-- saved: the event is over, so the cart goes quiet (ring and its edge gone, a low
	-- warm lantern, the banner stays)
	recolour(c, P.gold_300, true)
	for _, g in ipairs(c.Glow) do
		if g.Name == "Lantern" then
			g.Transparency = 0.35
		end
	end
	Fx.Ring(c.Pos, 18, P.gold_300)
	Fx.Sound("Chest")
	local gold = K.Gold * (1 + K.GoldStageScale * (c.Stage - 1))
	for _, rp in ipairs(ctx.RunManager.GetRunPlayers()) do
		if rp.Alive and not rp.Returned and rp.Stats then
			ctx.GoldSystem.AddRunGold(rp, gold * rp.Stats.GoldMult)
			local granted, dramatic = ctx.ItemSystem.Grant(rp, ctx.ItemSystem.Roll(K.Weights, rp.Stats.Luck), "Lost Caravan", true, true)
			if granted then ctx.RunManager.HoldReward(rp, dramatic == true) end
		end
	end
	ctx.RunManager.Broadcast(line or "The caravan is saved! An item and gold for everyone.", Color3.fromRGB(255, 220, 120))
end

local FIGHTING = { Explore = true, Boss = true, Surge = true }

-- Nobody held the ring for LeaveGrace seconds. While the portal is open no wave came, so
-- the team simply left it behind (a different line: nothing "overran" it).
local function fail(c: Caravan, phase: string)
	setState(c, "Lost")
	setAttr(c, "Grace", -1)
	recolour(c, P.stone_500, true)
	Fx.Ring(c.Pos, 10, P.stone_500)
	if FIGHTING[phase] then
		ctx.RunManager.Broadcast("The caravan was overrun... nobody held its ring.", Color3.fromRGB(255, 130, 110))
	else
		ctx.RunManager.Broadcast("The caravan was left behind... nobody held its ring.", Color3.fromRGB(255, 130, 110))
	end
end

function CaravanEvent.Step(dt: number)
	local c = current
	if not c or not ctx.RunManager.IsRunning() or not ctx.RunManager.IsSimulating() then
		return -- frozen runs (level-up, pause, the reward reel) stop the clock
	end
	local phase = ctx.StageManager.GetPhase()
	if c.State == "Waiting" then
		if FIGHTING[phase] and anyInRing(c, true) then
			c.StartPhase = phase
			start(c)
		end
		return
	end
	if c.State ~= "Defending" then
		return
	end
	-- The stage boss arriving clears every normal enemy (Config.Boss.ClearMinionsOnSpawn),
	-- the caravan's attackers too: the defence ends there and counts as won (nobody can
	-- hold a ring with the boss on the field, and the waves it was holding off are gone).
	if phase == "Boss" and c.StartPhase ~= "Boss" and Config.Boss.ClearMinionsOnSpawn then
		succeed(c, "The boss scattered the raiders: the caravan escapes! An item and gold for everyone.")
		return
	end
	local K = Config.Caravan
	if anyInRing(c, false) then
		c.Progress += dt
		c.Empty = 0
	else
		c.Empty += dt
		if c.Empty >= K.LeaveGrace then
			fail(c, phase)
			return
		end
	end
	if c.Progress >= K.HoldSeconds then
		succeed(c)
		return
	end
	if FIGHTING[phase] and c.Waves < totalWaves() then
		c.WaveTimer -= dt
		if c.WaveTimer <= 0 then
			c.WaveTimer = K.WaveEvery
			spawnWave(c)
		end
	end
	setAttr(c, "Progress", math.floor(c.Progress / K.HoldSeconds * 50) / 50)
	setAttr(c, "Left", math.ceil(K.HoldSeconds - c.Progress))
	setAttr(c, "Grace", c.Empty > 0 and math.ceil(K.LeaveGrace - c.Empty) or -1)
end

function CaravanEvent.Init(c)
	ctx = c
	folder = Instance.new("Folder")
	folder.Name = "SwarmEvents"
	folder.Parent = workspace
end

return CaravanEvent
