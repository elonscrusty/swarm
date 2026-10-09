--[[
	SwarmV2/Run/Beacon.lua  (ServerScriptService.SwarmV2.Run.Beacon)
	OWNER: gameplay track, stream D (docs/redesign/continuation/GAMEPLAY_PLAN.md).

	The single final beacon of a Cliffwood run (DECISIONS C5; tuning RunConfig.Director.Beacon).
	StageManager drives it; this module owns the beacon's own state, its world model and the
	activation rules. Phases:
	  Hidden     placed (Place) at a landmark but not shown
	  Available  revealed (Reveal, 12:30): the model, a tall light pillar (the far direction cue),
	             a ProximityPrompt, SwarmState BeaconPos (and the old PortalPos / PortalHint so the
	             existing HUD arrow and minimap point at it until the new run UI reads BeaconPos)
	  Rally      activated once (TryActivate): RallyLeft counts down RallySeconds
	  Charge     BeaconCharge fills over ChargeSeconds while at least one living, non-downed hero
	             stands within ChargeRadius (and HeightBand); it pauses otherwise, never goes back
	  Done       full: StageManager spawns the boss (Step returned "Charged" exactly once)

	Public API (UI / interact layer, tests):
	  Beacon.TryActivate(rp) -> (ok, reason?)   reason: "NotAvailable" | "NotEligible" | "TooFar"
	  Beacon.CanActivate(rp) -> (ok, reason?)   the same check without acting
	  Beacon.Phase(), Beacon.Position(), Beacon.Charge(), Beacon.RallyLeft()
	  Beacon.IsInside(rp)                       inside the charge ring (living, non-downed)
	SwarmState attributes: BeaconPos (Vector3 or nil), BeaconCharge (0..1), RallyLeft (s).
	Nothing here teleports anyone: distant heroes walk to it through the same map.
]]

local CollectionService = game:GetService("CollectionService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Remotes = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Remotes"))
local Palette = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Palette"))
local RunConfig = require(ReplicatedStorage:WaitForChild("SwarmV2"):WaitForChild("Run"):WaitForChild("RunConfig"))

local Beacon = {}

local ctx: any = nil
local HeightGrid: any = nil -- ServerScriptService.Modules.HeightGrid (bound in Init)

local FLAT = Vector3.new(1, 0, 1)
local UPRIGHT = CFrame.Angles(0, 0, math.pi / 2) -- a cylinder's axis is X: stand it up
local RING_MARKS = 36

local phase = "None" -- "None" | "Hidden" | "Available" | "Rally" | "Charge" | "Done"
local pos: Vector3? = nil
local arena: any = nil
local charge = 0
local shownCharge = -1
local rallyLeft = 0
local shownRally = -1
local activator: any = nil
local model: Model? = nil
local prompt: ProximityPrompt? = nil
local crystal: BasePart? = nil
local pillar: BasePart? = nil
local ringMarks: { BasePart } = {}
local collider: BasePart? = nil
local obstacleEntry: any = nil

local function cfg(): { [string]: any }
	local d = (RunConfig :: any).Director
	return (d and d.Beacon) or {}
end

local function state(): Configuration
	return Remotes.State()
end

local function setAttr(name: string, value: any)
	local s = state()
	if s:GetAttribute(name) ~= value then
		s:SetAttribute(name, value)
	end
end

------------------------------------------------------------------------------------------
-- Eligibility
------------------------------------------------------------------------------------------

-- A hero who counts at the beacon: in the run, alive, not downed (stream E1's Downed state as
-- the rp field or the player attribute), not gone, with a live root.
local function eligible(rp: any): boolean
	if not rp or not rp.Alive or rp.Returned or rp.Downed then
		return false
	end
	local player = rp.Player
	if player and (player.Parent == nil or player:GetAttribute("Downed") == true or player:GetAttribute("Eliminated") == true) then
		return false
	end
	local root = rp.Root
	return root ~= nil and root.Parent ~= nil
end

-- Flat distance from rp's root to the beacon, math.huge across a cliff (HeightBand).
local function distance(rp: any): number
	local p = pos
	local root = rp.Root
	if not p or not root then
		return math.huge
	end
	local rpos = root.Position
	local d = ((rpos - p) * FLAT).Magnitude
	local band = cfg().HeightBand or 8
	if HeightGrid and HeightGrid.IsActive() and math.abs(HeightGrid.GroundY(rpos.X, rpos.Z) - p.Y) > band then
		return math.huge
	end
	return d
end

function Beacon.IsInside(rp: any): boolean
	return eligible(rp) and distance(rp) <= (cfg().ChargeRadius or 35)
end

function Beacon.CanActivate(rp: any): (boolean, string?)
	if phase ~= "Available" then
		return false, "NotAvailable"
	end
	if not eligible(rp) then
		return false, "NotEligible"
	end
	if distance(rp) > (cfg().ActivateRadius or 20) then
		return false, "TooFar"
	end
	return true, nil
end

------------------------------------------------------------------------------------------
-- The world model
------------------------------------------------------------------------------------------

local function part(parent: Instance, name: string, shape: Enum.PartType, size: Vector3, cf: CFrame, color: Color3, material: Enum.Material, collide: boolean): Part
	local p = Instance.new("Part")
	p.Name = name
	p.Shape = shape
	p.Size = size
	p.CFrame = cf
	p.Color = color
	p.Material = material
	p.Anchored = true
	p.CanCollide = collide
	p.CanQuery = collide
	p.CanTouch = false
	p.CastShadow = collide
	p.TopSurface = Enum.SurfaceType.Smooth
	p.BottomSurface = Enum.SurfaceType.Smooth
	p.Parent = parent
	return p
end

-- Colour of the crystal / pillar / ring per phase.
local function phaseColor(): Color3
	if phase == "Rally" then
		return Palette.amber_500
	elseif phase == "Charge" then
		return Palette.gold_300:Lerp(Palette.ivory_100, charge)
	elseif phase == "Done" then
		return Palette.ivory_100
	end
	return Palette.gold_400
end

local function paint()
	local c = phaseColor()
	if crystal then
		crystal.Color = c
	end
	if pillar then
		pillar.Color = c
		pillar.Transparency = phase == "Charge" and (0.55 - 0.25 * charge) or 0.55
	end
	local showRing = phase == "Rally" or phase == "Charge"
	for i, mark in ipairs(ringMarks) do
		mark.Transparency = showRing and ((phase == "Charge" and i / RING_MARKS <= charge) and 0.05 or 0.35) or 1
		mark.Color = (phase == "Charge" and i / RING_MARKS <= charge) and Palette.gold_300 or Palette.amber_500
	end
end

local function build()
	local p = pos
	if not p or model then
		return
	end
	local parent: Instance = (arena and arena.Model) or workspace
	local m = Instance.new("Model")
	m.Name = "SwarmBeacon"
	-- plinth, crystal and a tall light pillar (the far direction cue: CameraIgnore, no query)
	local stone = Palette.stone_400
	local base = part(m, "Plinth", Enum.PartType.Cylinder, Vector3.new(1.6, 9, 9), CFrame.new(p + Vector3.new(0, 0.8, 0)) * UPRIGHT, Palette.stone_500, Enum.Material.SmoothPlastic, true)
	part(m, "Column", Enum.PartType.Block, Vector3.new(3, 7, 3), CFrame.new(p + Vector3.new(0, 5, 0)), stone, Enum.Material.SmoothPlastic, true)
	part(m, "Cap", Enum.PartType.Block, Vector3.new(4.2, 0.8, 4.2), CFrame.new(p + Vector3.new(0, 8.8, 0)), Palette.stone_300, Enum.Material.SmoothPlastic, true)
	local gem = part(m, "Crystal", Enum.PartType.Block, Vector3.new(2.2, 3.2, 2.2), CFrame.new(p + Vector3.new(0, 11.4, 0)) * CFrame.Angles(0, math.rad(45), math.rad(12)), Palette.gold_400, Enum.Material.Neon, false)
	crystal = gem
	local beam = part(m, "Pillar", Enum.PartType.Cylinder, Vector3.new(160, 1.6, 1.6), CFrame.new(p + Vector3.new(0, 13 + 80, 0)) * UPRIGHT, Palette.gold_400, Enum.Material.Neon, false)
	beam.Transparency = 0.55
	pillar = beam
	CollectionService:AddTag(beam, "CameraIgnore")
	CollectionService:AddTag(gem, "CameraIgnore")
	local light = Instance.new("PointLight")
	light.Range = 24
	light.Brightness = 1.6
	light.Color = Palette.gold_300
	light.Parent = gem
	-- the charge ring (ChargeRadius): short flat marks, shown during the rally and the charge
	local r = cfg().ChargeRadius or 35
	table.clear(ringMarks)
	for i = 1, RING_MARKS do
		local a = (i - 0.5) / RING_MARKS * math.pi * 2
		local x, z = p.X + math.cos(a) * r, p.Z + math.sin(a) * r
		local y = HeightGrid and HeightGrid.GroundY(x, z) or p.Y
		local mark = part(m, "RingMark", Enum.PartType.Block, Vector3.new(0.6, 0.12, 2 * math.pi * r / RING_MARKS * 0.55), CFrame.new(x, y + 0.1, z) * CFrame.Angles(0, -a, 0), Palette.amber_500, Enum.Material.Neon, false)
		mark.Transparency = 1
		mark.CastShadow = false
		CollectionService:AddTag(mark, "CameraIgnore")
		table.insert(ringMarks, mark)
	end
	-- interact: E / touch hold. TryActivate re-checks every rule on the server.
	local pp = Instance.new("ProximityPrompt")
	pp.Name = "BeaconPrompt"
	pp.ActionText = "Light the beacon"
	pp.ObjectText = "Beacon"
	pp.HoldDuration = cfg().PromptHold or 0.5
	pp.MaxActivationDistance = cfg().ActivateRadius or 20
	pp.RequiresLineOfSight = false
	pp.KeyboardKeyCode = Enum.KeyCode.E
	pp.Parent = base
	pp.Triggered:Connect(function(player: Player)
		local rp = ctx and ctx.RunManager and ctx.RunManager.GetRunPlayer(player)
		if rp then
			Beacon.TryActivate(rp)
		end
	end)
	prompt = pp
	m.Parent = parent
	model = m
	-- the column blocks enemies too (obstacle grid; EnemyAI.SetArena rebuilds it)
	if arena and arena.ObstacleFolder and arena.Obstacles then
		local cp = part(arena.ObstacleFolder, "BeaconCollider", Enum.PartType.Cylinder, Vector3.new(10, 5, 5), CFrame.new(p + Vector3.new(0, 5, 0)) * UPRIGHT, stone, Enum.Material.SmoothPlastic, true)
		cp.Transparency = 1
		collider = cp
		obstacleEntry = { Kind = "Circle", Pos = p, Radius = 2.5 }
		table.insert(arena.Obstacles, obstacleEntry)
		if ctx and ctx.EnemyAI then
			ctx.EnemyAI.SetArena(arena)
		end
	end
	paint()
end

------------------------------------------------------------------------------------------
-- Lifecycle (StageManager)
------------------------------------------------------------------------------------------

-- Remembers the beacon's spot for this run (nothing is shown yet).
function Beacon.Place(a: any, at: Vector3)
	Beacon.Clear()
	arena = a
	pos = at
	phase = "Hidden"
end

-- The 12:30 reveal: builds the beacon and publishes its position. False when not hidden.
function Beacon.Reveal(): boolean
	if phase ~= "Hidden" or not pos then
		return false
	end
	phase = "Available"
	build()
	setAttr("BeaconPos", pos)
	-- the existing HUD arrow / minimap marker follow PortalPos while PortalHint is set
	setAttr("PortalPos", pos)
	setAttr("PortalHint", true)
	return true
end

--[[
	A hero asks to light the beacon (ProximityPrompt, or the interact layer). Any living,
	non-downed hero within ActivateRadius may, once; distant or downed teammates never block
	it. Starts the rally. Returns (true) or (false, reason).
]]
function Beacon.TryActivate(rp: any): (boolean, string?)
	local ok, reason = Beacon.CanActivate(rp)
	if not ok then
		return false, reason
	end
	phase = "Rally"
	activator = rp
	rallyLeft = cfg().RallySeconds or 30
	shownRally = -1
	if prompt then
		prompt.Enabled = false
	end
	setAttr("RallyLeft", math.ceil(rallyLeft))
	paint()
	if ctx and ctx.StageManager and ctx.StageManager.OnBeaconActivated then
		ctx.StageManager.OnBeaconActivated(rp)
	end
	return true, nil
end

-- Who lit it (nil before).
function Beacon.Activator(): any
	return activator
end

--[[
	dt = director seconds. Returns "ChargeStarted" when the rally ends, "Charged" once when the
	charge reaches 100%, else nil.
]]
function Beacon.Step(dt: number, players: { any }): string?
	if phase == "Rally" then
		rallyLeft = math.max(0, rallyLeft - dt)
		local shown = math.ceil(rallyLeft)
		if shown ~= shownRally then
			shownRally = shown
			setAttr("RallyLeft", shown)
		end
		if rallyLeft <= 0 then
			phase = "Charge"
			paint()
			return "ChargeStarted"
		end
		return nil
	end
	if phase ~= "Charge" then
		return nil
	end
	local inside = false
	for _, rp in ipairs(players) do
		if Beacon.IsInside(rp) then
			inside = true
			break
		end
	end
	if inside then
		-- progress only while someone is inside; outside it pauses (never goes back)
		charge = math.min(1, charge + dt / math.max(0.01, cfg().ChargeSeconds or 60))
	end
	local step = cfg().PublishStep or 0.01
	local q = charge >= 1 and 1 or math.floor(charge / step) * step
	if q ~= shownCharge then
		shownCharge = q
		setAttr("BeaconCharge", q)
		paint()
	end
	if charge >= 1 then
		phase = "Done"
		paint()
		return "Charged"
	end
	return nil
end

-- Dev (StageManager.DevNextStage): light a revealed beacon without a hero beside it.
function Beacon.DevActivate(): boolean
	if phase ~= "Available" then
		return false
	end
	phase = "Rally"
	rallyLeft = cfg().RallySeconds or 30
	shownRally = -1
	if prompt then
		prompt.Enabled = false
	end
	setAttr("RallyLeft", math.ceil(rallyLeft))
	paint()
	if ctx and ctx.StageManager and ctx.StageManager.OnBeaconActivated then
		ctx.StageManager.OnBeaconActivated(nil)
	end
	return true
end

-- Dev / tests: during the rally, end it (the next Step starts the charge and reports
-- "ChargeStarted"); during the charge, jump it to `value` (never down).
function Beacon.ForceCharge(value: number)
	if phase == "Rally" then
		rallyLeft = 0
		return
	end
	if phase == "Charge" then
		charge = math.clamp(math.max(charge, value), 0, 1)
	end
end

function Beacon.Phase(): string
	return phase
end

function Beacon.Position(): Vector3?
	return pos
end

function Beacon.Charge(): number
	return charge
end

function Beacon.RallyLeft(): number
	return rallyLeft
end

-- Removes the beacon and its attributes (run end, a new run).
function Beacon.Clear()
	if model then
		model:Destroy()
		model = nil
	end
	if collider then
		collider:Destroy()
		collider = nil
	end
	if obstacleEntry and arena and arena.Obstacles then
		local i = table.find(arena.Obstacles, obstacleEntry)
		if i then
			table.remove(arena.Obstacles, i)
		end
	end
	obstacleEntry = nil
	prompt = nil
	crystal = nil
	pillar = nil
	table.clear(ringMarks)
	phase = "None"
	pos = nil
	arena = nil
	charge = 0
	shownCharge = -1
	rallyLeft = 0
	shownRally = -1
	activator = nil
	local s = state()
	s:SetAttribute("BeaconPos", nil)
	s:SetAttribute("BeaconCharge", 0)
	s:SetAttribute("RallyLeft", 0)
end

function Beacon.Init(c: any)
	ctx = c
	local modules = game:GetService("ServerScriptService"):FindFirstChild("Modules")
	local hg = modules and modules:FindFirstChild("HeightGrid")
	if hg then
		HeightGrid = require(hg :: ModuleScript)
	end
end

return Beacon
