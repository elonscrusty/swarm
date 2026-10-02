--[[
	JumpController.lua
	Jump and bunny hop for the local hero (numbers in Config.Movement).

	  * Input: Space, gamepad A and the touch JUMP button (MobileControls). A press is kept
	    for BufferSeconds, so pressing just before landing still jumps on the landing frame;
	    a press within CoyoteSeconds of walking off an edge still jumps.
	  * Bunny hop: a jump within HopWindow of landing from a jump, while moving, raises a
	    speed multiplier by HopBonus up to HopSpeedCap. On the ground it decays back to 1
	    (HopDecay per second) and stopping resets it. The multiplier is applied to the
	    local WalkSpeed only; the server's WalkSpeed stays the base and MovementGuard trims
	    anything above the cap.
	  * Air control: in the air the move input steers the takeoff direction at AirControl
	    per second (MobileControls.AirFilter).
	  * No jumping in the lobby, while downed, while the run is frozen (SwarmState
	    attributes Frozen / LevelUpPause), while the player is Paused, or while
	    MobileControls is disabled by a panel.

	Init(MobileControls) is called by MobileControls.Init.
]]

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")

local Shared = game:GetService("ReplicatedStorage"):WaitForChild("Shared")
local Config = require(Shared:WaitForChild("Config"))
local Remotes = require(Shared:WaitForChild("Remotes"))

local JumpController = {}

local M = Config.Movement
local player = Players.LocalPlayer

local controls: any = nil
local requestedAt = -math.huge -- last jump press (buffer)
local groundedAt = -math.huge -- last frame on the ground (coyote time)
local landedAt = -math.huge -- when the last hop landed
local jumpedAt = -math.huge
local inHop = false -- airborne because of our own jump
local wasGrounded = true
local hopMult = 1
local airDir = Vector3.zero

-- WalkSpeed bookkeeping: the server writes the base speed (0 when frozen); we write
-- base * hopMult locally. A value we did not write is a new base from the server.
local hookedHum: Humanoid? = nil
local baseSpeed = 0
local lastWritten: number? = nil

local function isGrounded(hum: Humanoid): boolean
	local st = hum:GetState()
	if st == Enum.HumanoidStateType.Freefall or st == Enum.HumanoidStateType.Jumping then
		return false
	end
	return hum.FloorMaterial ~= Enum.Material.Air
end

-- True when the hero may jump right now (ignores ground / coyote checks).
function JumpController.CanJump(): boolean
	if not M.JumpEnabled then
		return false
	end
	if player:GetAttribute("InRun") ~= true or player:GetAttribute("Alive") == false or player:GetAttribute("Paused") == true then
		return false
	end
	local state = Remotes.State()
	if state:GetAttribute("Frozen") == true or state:GetAttribute("LevelUpPause") == true then
		return false
	end
	if controls and controls.IsEnabled and not controls.IsEnabled() then
		return false
	end
	return baseSpeed > 0
end

-- Queues a jump (buffered for BufferSeconds).
function JumpController.Request()
	requestedAt = os.clock()
end

-- Air control: MobileControls passes the world move direction (0..1) every frame.
function JumpController.AirFilter(world: Vector3, dt: number): Vector3
	if wasGrounded then
		airDir = world
		return world
	end
	local k = 1 - math.exp(-math.max(dt, 0) * M.AirControl)
	airDir = airDir:Lerp(world, k)
	return airDir
end

-- The current hop speed multiplier (1 = none), for UI or debugging.
function JumpController.HopMultiplier(): number
	return hopMult
end

local function resetHop()
	hopMult = 1
	inHop = false
	landedAt = -math.huge
end

local function doJump(hum: Humanoid, root: BasePart, now: number, moving: boolean)
	-- a chained hop: landing from our own jump, jumping again quickly, while moving
	if moving and now - landedAt <= M.HopWindow then
		hopMult = math.min(M.HopSpeedCap, hopMult + M.HopBonus)
	elseif not moving then
		hopMult = 1
	end
	requestedAt = -math.huge
	jumpedAt = now
	groundedAt = -math.huge -- no second coyote jump
	inHop = true
	wasGrounded = false
	local v = root.AssemblyLinearVelocity
	root.AssemblyLinearVelocity = Vector3.new(v.X, M.JumpPower, v.Z)
	hum:ChangeState(Enum.HumanoidStateType.Jumping)
end

local function step(dt: number)
	local char = player.Character
	local hum = char and char:FindFirstChildOfClass("Humanoid")
	local root = char and char:FindFirstChild("HumanoidRootPart") :: BasePart?
	if not hum or not root then
		hookedHum = nil
		return
	end
	if hum ~= hookedHum then
		hookedHum = hum
		baseSpeed = hum.WalkSpeed
		lastWritten = nil
		resetHop()
	end
	local now = os.clock()
	-- a WalkSpeed we did not write came from the server: that is the new base
	local cur = hum.WalkSpeed
	if lastWritten == nil or math.abs(cur - (lastWritten :: number)) > 1e-3 then
		baseSpeed = cur
	end

	-- the takeoff frame may still read as grounded before physics runs
	local grounded = isGrounded(hum) and now - jumpedAt > 0.1
	local allowed = JumpController.CanJump()
	local moving = hum.MoveDirection.Magnitude > 0.3

	if grounded then
		groundedAt = now
		if not wasGrounded and inHop then
			landedAt = now
		end
		inHop = false
	end
	wasGrounded = grounded

	if not allowed then
		requestedAt = -math.huge
		resetHop()
	elseif now - requestedAt <= M.BufferSeconds and now - jumpedAt >= M.JumpCooldown then
		if grounded or now - groundedAt <= M.CoyoteSeconds then
			doJump(hum, root, now, moving)
		end
	end

	-- decay the hop bonus on the ground; stopping ends it at once
	if not moving and wasGrounded then
		hopMult = 1
	elseif wasGrounded and now - landedAt > M.HopWindow then
		hopMult = math.max(1, hopMult - M.HopDecay * dt)
	end

	local want = baseSpeed * hopMult
	if math.abs(cur - want) > 1e-3 then
		hum.WalkSpeed = want
		lastWritten = hum.WalkSpeed
	else
		lastWritten = cur
	end

	if controls and controls.SetJumpButton then
		controls.SetJumpButton(player:GetAttribute("InRun") == true and player:GetAttribute("Alive") ~= false, allowed)
	end
end

function JumpController.Init(mobileControls: any)
	controls = mobileControls
	mobileControls.AirFilter = JumpController.AirFilter
	mobileControls.OnJump = JumpController.Request

	UserInputService.InputBegan:Connect(function(input, processed)
		if processed then
			return
		end
		if input.KeyCode == Enum.KeyCode.Space or input.KeyCode == Enum.KeyCode.ButtonA then
			JumpController.Request()
		end
	end)

	-- before SwarmMove (Input + 1) so the hop speed and air state are current
	RunService:BindToRenderStep("SwarmJump", Enum.RenderPriority.Input.Value, step)
end

return JumpController
