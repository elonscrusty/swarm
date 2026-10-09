--[[
	JumpController.lua
	Jump, air steering and the generic speed cap for the local hero (stream E1 survival rules,
	numbers in RunConfig.Survival.Move and RunConfig.Movement).

	  * Input: Space, gamepad A and the touch JUMP button (MobileControls). A press is kept
	    for BufferSeconds (0.10), so pressing just before landing still jumps on the landing frame;
	    a press within CoyoteSeconds (0.10) of walking off an edge still jumps. One jump per
	    takeoff (JumpCooldown, no double jumps).
	  * No bunny hop: chained jumps never raise the speed. Horizontal momentum carries through a
	    jump (the humanoid keeps walking), and the flat speed is capped at HorizontalCap (34)
	    outside dashes / leaps (Suppress) and an explicit class boost (player attributes
	    SpeedBoost + SpeedBoostUntil, server time, set by RunManager.SetSpeedBoost).
	  * Air control: in the air the world move direction is AirControl (0.65) the live input and
	    the rest the takeoff direction (MobileControls.AirFilter).
	  * Jump height: one source. The takeoff speed is sqrt(2 * workspace.Gravity * apex)
	    (SurvivalRules.JumpVelocity, apex RunConfig.Movement.JumpApex = 9, per class
	    JumpApexByClass by the run hero's CharacterId); the Humanoid's own JumpPower is kept equal
	    to it (UseJumpPower), so the jump state never adds a different impulse.
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
local RunFolder = game:GetService("ReplicatedStorage"):WaitForChild("SwarmV2"):WaitForChild("Run")
local RunConfig = require(RunFolder:WaitForChild("RunConfig"))
local SurvivalRules = require(RunFolder:WaitForChild("SurvivalRules"))

local JumpController = {}
-- Set by DashClient while a dash / leap moves the hero: no jumping then (and no speed cap).
JumpController.Suppress = false

local M = Config.Movement
local SM = RunConfig.Survival.Move
local player = Players.LocalPlayer

local controls: any = nil
local requestedAt = -math.huge -- last jump press (buffer)
local groundedAt = -math.huge -- last frame on the ground (coyote time)
local jumpedAt = -math.huge
local wasGrounded = true
local airStart: number? = nil
local airDir = Vector3.zero
local hookedHum: Humanoid? = nil

local function isGrounded(hum: Humanoid): boolean
	local st = hum:GetState()
	if st == Enum.HumanoidStateType.Freefall or st == Enum.HumanoidStateType.Jumping then
		return false
	end
	return hum.FloorMaterial ~= Enum.Material.Air
end

-- The player is walking in the SwarmV2 basecamp (lobby track), not in a run.
local function inCamp(): boolean
	return player:GetAttribute("InRun") ~= true and workspace:GetAttribute("SwarmV2Lobby") == true
end

local function currentHumanoid(): Humanoid?
	local char = player.Character
	return char and char:FindFirstChildOfClass("Humanoid") or nil
end

-- True when the hero may jump right now (ignores ground / coyote checks).
function JumpController.CanJump(): boolean
	if not M.JumpEnabled or JumpController.Suppress then
		return false
	end
	local hum = currentHumanoid()
	local canMove = hum ~= nil and hum.WalkSpeed > 0
	if inCamp() then
		-- the SwarmV2 basecamp: a normal walkable place, no run state applies
		if controls and controls.IsEnabled and not controls.IsEnabled() then
			return false
		end
		return canMove
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
	return canMove
end

-- Queues a jump (buffered for BufferSeconds).
function JumpController.Request()
	requestedAt = os.clock()
end

-- Air control: MobileControls passes the world move direction (0..1) every frame. In the
-- air the result is AirControl of the live input plus the rest of the takeoff direction.
function JumpController.AirFilter(world: Vector3, _dt: number): Vector3
	if wasGrounded then
		airDir = world
		return world
	end
	local a = math.clamp(RunConfig.Movement.AirControl, 0, 1)
	return airDir * (1 - a) + world * a
end

-- True while the hero is in the air (for the move driver).
function JumpController.Airborne(): boolean
	return not wasGrounded
end

-- Calls back(airtime) whenever the hero lands after at least 0.1 s in the air (a jump, a
-- dash arc or a fall). Returns a function that removes the callback.
local landedCallbacks: { (number) -> () } = {}
function JumpController.OnLanded(callback: (number) -> ()): () -> ()
	table.insert(landedCallbacks, callback)
	return function()
		local i = table.find(landedCallbacks, callback)
		if i then
			table.remove(landedCallbacks, i)
		end
	end
end

-- The jump velocity of the local hero: sqrt(2 * gravity * apex) for its class.
function JumpController.JumpPower(): number
	local apex = RunConfig.Movement.JumpApex
	-- the run's hero (CharacterId, set by the server from the admitted class), else the lobby pick
	local id = player:GetAttribute("InRun") == true and player:GetAttribute("CharacterId") or player:GetAttribute("SwarmClass")
	if type(id) == "string" then
		apex = RunConfig.Movement.JumpApexByClass[id] or apex
	end
	return SurvivalRules.JumpVelocity(workspace.Gravity, apex)
end

-- Kept for older callers: there is no hop speed multiplier any more.
function JumpController.HopMultiplier(): number
	return 1
end

-- The flat speed allowed right now (nil = no cap: dash, leap, lobby).
function JumpController.SpeedCap(): number?
	if JumpController.Suppress or player:GetAttribute("InRun") ~= true then
		return nil
	end
	local boost = player:GetAttribute("SpeedBoost")
	local untilT = player:GetAttribute("SpeedBoostUntil")
	if type(boost) == "number" and type(untilT) == "number" and workspace:GetServerTimeNow() < untilT then
		return math.max(SM.HorizontalCap, boost)
	end
	return SM.HorizontalCap
end

local function doJump(hum: Humanoid, root: BasePart, now: number)
	requestedAt = -math.huge
	jumpedAt = now
	groundedAt = -math.huge -- no second coyote jump
	wasGrounded = false
	local v = root.AssemblyLinearVelocity
	root.AssemblyLinearVelocity = Vector3.new(v.X, JumpController.JumpPower(), v.Z)
	hum:ChangeState(Enum.HumanoidStateType.Jumping)
end

local function step(_dt: number)
	local char = player.Character
	local hum = char and char:FindFirstChildOfClass("Humanoid")
	local root = char and char:FindFirstChild("HumanoidRootPart") :: BasePart?
	if not hum or not root then
		hookedHum = nil
		return
	end
	-- one jump source: the Humanoid's own jump impulse equals the computed takeoff speed
	local jp = JumpController.JumpPower()
	if hum ~= hookedHum or math.abs(hum.JumpPower - jp) > 0.01 or not hum.UseJumpPower then
		hookedHum = hum
		hum.UseJumpPower = true
		hum.JumpPower = jp
	end
	local now = os.clock()

	-- the takeoff frame may still read as grounded before physics runs
	local grounded = isGrounded(hum) and now - jumpedAt > 0.1
	local allowed = JumpController.CanJump()

	if not grounded and airStart == nil then
		airStart = now
	end
	if grounded then
		local started = airStart
		airStart = nil
		if started and now - started >= 0.1 then
			for _, cb in ipairs(table.clone(landedCallbacks)) do
				task.spawn(cb, now - started)
			end
		end
		groundedAt = now
	end
	wasGrounded = grounded

	if not allowed then
		requestedAt = -math.huge
	elseif now - requestedAt <= SM.BufferSeconds and now - jumpedAt >= SM.JumpCooldown then
		if grounded or now - groundedAt <= SM.CoyoteSeconds then
			doJump(hum, root, now)
		end
	end

	-- the generic horizontal cap (pushes, slopes, anything but a dash / leap / class boost)
	local cap = JumpController.SpeedCap()
	if cap and not root.Anchored then
		local v = root.AssemblyLinearVelocity
		local capped = SurvivalRules.CapHorizontal(v, cap)
		if capped ~= v then
			root.AssemblyLinearVelocity = capped
		end
	end

	if controls and controls.SetJumpButton then
		controls.SetJumpButton((player:GetAttribute("InRun") == true and player:GetAttribute("Alive") ~= false) or inCamp(), allowed)
	end
end

function JumpController.Init(mobileControls: any)
	controls = mobileControls
	mobileControls.AirFilter = JumpController.AirFilter
	mobileControls.OnJump = JumpController.Request
	mobileControls.Airborne = JumpController.Airborne

	UserInputService.InputBegan:Connect(function(input, processed)
		if processed then
			return
		end
		if input.KeyCode == Enum.KeyCode.Space or input.KeyCode == Enum.KeyCode.ButtonA then
			JumpController.Request()
		end
	end)

	-- before SwarmMove (Input + 1) so the air state is current
	RunService:BindToRenderStep("SwarmJump", Enum.RenderPriority.Input.Value, step)
end

return JumpController
