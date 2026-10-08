--!nonstrict
--[[
	SwarmV2/Run/DashClient.lua  (StarterPlayerScripts.SwarmV2Client.Run.DashClient)
	OWNER: gameplay track (Chat 2). Design: docs/redesign/gameplay/DESIGN.md section 2.

	The client half of the dash (server: SwarmV2.Run.Dash).
	  Input     keyboard Shift or Q, gamepad B or RB (R1), the touch DASH button (MobileControls).
	  Request   a unit, flat direction (the move direction, else where the hero faces) on
	            ReplicatedStorage.SwarmV2Net.Run.Dash. Nothing else is sent.
	  Answer    DashAck(ok, kind, dir, speed, duration, vy, cooldown). On ok the client (network owner
	            of its character) moves itself: AssemblyLinearVelocity = dir * speed, horizontal only,
	            for `duration`; a Leap also gets the vertical launch `vy` and ends on landing.
	  Anti-tunnel  every frame a ray goes ahead of the hero (waist and feet); the dash stops
	            RunConfig.Dash.WallMargin studs before a wall.
	  Ring      the DASH button's cooldown comes from the player attributes DashReadyAt (server time)
	            and DashCd, both set by the server.

	Public: DashClient.Init(), DashClient.Request(), DashClient.IsDashing(),
	DashClient.OnDash(callback(kind, dir)) -> disconnect function.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")

local RunConfig = require(ReplicatedStorage:WaitForChild("SwarmV2"):WaitForChild("Run"):WaitForChild("RunConfig"))
local D = RunConfig.Dash

local DashClient = {}

local player = Players.LocalPlayer
local request: RemoteEvent? = nil
local controls: any = nil
local jumpController: any = nil
local cameraController: any = nil
local stateConfig: Configuration? = nil

local pendingSince: number? = nil
local lastRequest = -math.huge
local active: {
	Dir: Vector3,
	Speed: number,
	Until: number,
	Leap: boolean,
	Start: number,
	Vy: number,
}? = nil
local hooks: { (string, Vector3) -> () } = {}

local castParams = RaycastParams.new()
castParams.FilterType = Enum.RaycastFilterType.Exclude
castParams.RespectCanCollide = true
local filterList: { Instance } = {}
local ignoreNames: { [string]: boolean } = {}
for _, name in ipairs(RunConfig.Camera.IgnoreFolders) do
	ignoreNames[name] = true
end

local function character(): (Model?, Humanoid?, BasePart?)
	local char = player.Character
	local hum = char and char:FindFirstChildOfClass("Humanoid")
	local root = char and char:FindFirstChild("HumanoidRootPart")
	return char, hum, root :: BasePart?
end

local function cooldownLeft(): number
	local readyAt = player:GetAttribute("DashReadyAt")
	if type(readyAt) ~= "number" then
		return 0
	end
	return math.max(0, readyAt - workspace:GetServerTimeNow())
end

local function cooldownLength(): number
	local cd = player:GetAttribute("DashCd")
	return if type(cd) == "number" and cd > 0 then cd else D.Default.Cooldown
end

-- True when a dash may be asked for right now (the server decides for real).
local function canDash(): boolean
	if player:GetAttribute("InRun") ~= true or player:GetAttribute("Alive") == false or player:GetAttribute("Paused") == true then
		return false
	end
	local state = stateConfig
	if state and (state:GetAttribute("Frozen") == true or state:GetAttribute("LevelUpPause") == true) then
		return false
	end
	if controls and controls.IsEnabled and not controls.IsEnabled() then
		return false
	end
	local _, hum, root = character()
	if not hum or not root or hum.Health <= 0 or root.Anchored or hum.WalkSpeed <= 0 then
		return false
	end
	return active == nil and pendingSince == nil
end

local function stop()
	local a = active
	active = nil
	if controls then
		controls.MoveOverride = nil
	end
	if jumpController then
		jumpController.Suppress = false
	end
	local _, hum, root = character()
	if a and root and hum and not a.Leap then
		-- hand control back at walking pace, in the dash direction
		local v = root.AssemblyLinearVelocity
		root.AssemblyLinearVelocity = Vector3.new(a.Dir.X * hum.WalkSpeed, v.Y, a.Dir.Z * hum.WalkSpeed)
	end
end

-- Ray ahead of the hero; returns the free distance along `dir` (up to `reach`) before a solid wall.
local function freeDistance(char: Model, root: BasePart, dir: Vector3, reach: number): number
	local best = reach
	for _, dy in ipairs({ 0, -2.2 }) do
		table.clear(filterList)
		table.insert(filterList, char)
		local from = root.Position + Vector3.new(0, dy, 0)
		for _ = 1, 3 do
			castParams.FilterDescendantsInstances = filterList
			local hit = workspace:Raycast(from, dir * reach, castParams)
			if not hit then
				break
			end
			local skip = false
			local node: Instance? = hit.Instance
			while node and node ~= workspace do
				if ignoreNames[node.Name] or (node:IsA("Model") and node:FindFirstChildOfClass("Humanoid")) then
					skip = true
					break
				end
				node = node.Parent
			end
			if skip then
				table.insert(filterList, hit.Instance)
			else
				best = math.min(best, hit.Distance)
				break
			end
		end
	end
	return best
end

local function start(kind: string, dir: Vector3, speed: number, duration: number, vy: number)
	local _, hum, root = character()
	if not hum or not root then
		return
	end
	local now = os.clock()
	local leap = kind == "Leap"
	active = { Dir = dir, Speed = speed, Until = now + duration, Leap = leap, Start = now, Vy = vy }
	if controls then
		controls.MoveOverride = dir
	end
	if jumpController then
		jumpController.Suppress = true
	end
	if leap then
		hum:ChangeState(Enum.HumanoidStateType.Jumping)
		local v = root.AssemblyLinearVelocity
		root.AssemblyLinearVelocity = Vector3.new(v.X, vy, v.Z)
	end
	if cameraController and cameraController.FovKick then
		cameraController.FovKick(RunConfig.Camera.DashFovKick)
	end
	for _, cb in ipairs(table.clone(hooks)) do
		task.spawn(cb, kind, dir)
	end
end

local function step(dt: number)
	local a = active
	if not a then
		return
	end
	local char, hum, root = character()
	local state = stateConfig
	if not char or not hum or not root or hum.Health <= 0 or player:GetAttribute("Alive") == false
		or (state and (state:GetAttribute("Frozen") == true or state:GetAttribute("LevelUpPause") == true)) then
		stop()
		return
	end
	local now = os.clock()
	if a.Leap then
		-- ends on landing (after the first moments in the air) or when the arc should be over
		local airborne = hum.FloorMaterial == Enum.Material.Air
		if (now - a.Start > 0.15 and not airborne) or now > a.Until + 0.6 then
			stop()
			return
		end
	elseif now >= a.Until then
		stop()
		return
	end

	local radius = math.max(root.Size.X, root.Size.Z) / 2
	local speed = a.Speed
	local finish = false
	local reach = speed * dt + D.WallMargin + radius
	local free = freeDistance(char, root, a.Dir, reach)
	if free < reach then
		-- a wall: cover only what leaves WallMargin, then stop
		local room = free - D.WallMargin - radius
		if room <= 0.05 then
			stop()
			return
		end
		speed = math.min(speed, room / math.max(dt, 1e-3))
		finish = true
	end
	local v = root.AssemblyLinearVelocity
	root.AssemblyLinearVelocity = Vector3.new(a.Dir.X * speed, v.Y, a.Dir.Z * speed)
	if finish then
		stop()
	end
end

local function updateButton()
	if not controls or not controls.SetDashButton then
		return
	end
	local show = player:GetAttribute("InRun") == true and player:GetAttribute("Alive") ~= false
	local left = cooldownLeft()
	local cd = cooldownLength()
	controls.SetDashButton(show, show and left <= 0.05 and canDash(), 1 - math.clamp(left / cd, 0, 1), left)
end

-- Asks the server for a dash in the move direction (or where the hero faces).
function DashClient.Request()
	local remote = request
	if not remote or not canDash() or cooldownLeft() > 0.05 then
		return
	end
	local now = os.clock()
	if now - lastRequest < 0.15 then
		return
	end
	local _, hum, root = character()
	if not hum or not root then
		return
	end
	local move = hum.MoveDirection
	local dir = Vector3.new(move.X, 0, move.Z)
	if dir.Magnitude < 0.1 then
		local look = root.CFrame.LookVector
		dir = Vector3.new(look.X, 0, look.Z)
	end
	if dir.Magnitude < 1e-3 then
		return
	end
	lastRequest = now
	pendingSince = now
	remote:FireServer(dir.Unit)
end

function DashClient.IsDashing(): boolean
	return active ~= nil
end

-- callback(kind, dir) when a dash starts; returns a function that removes it.
function DashClient.OnDash(callback: (string, Vector3) -> ()): () -> ()
	table.insert(hooks, callback)
	return function()
		local i = table.find(hooks, callback)
		if i then
			table.remove(hooks, i)
		end
	end
end

function DashClient.Init()
	local scripts = player:WaitForChild("PlayerScripts")
	local main = scripts:WaitForChild("SwarmClient")
	controls = require(main:WaitForChild("MobileControls"))
	jumpController = require(main:WaitForChild("JumpController"))
	cameraController = require(main:WaitForChild("CameraController"))
	stateConfig = ReplicatedStorage:WaitForChild("SwarmState") :: Configuration

	controls.OnDash = DashClient.Request

	UserInputService.InputBegan:Connect(function(input, processed)
		if processed then
			return
		end
		local k = input.KeyCode
		if k == Enum.KeyCode.LeftShift or k == Enum.KeyCode.RightShift or k == Enum.KeyCode.Q
			or k == Enum.KeyCode.ButtonB or k == Enum.KeyCode.ButtonR1 then
			DashClient.Request()
		end
	end)

	-- after SwarmMove (Input + 1): the dash velocity is written last, before physics
	RunService:BindToRenderStep("SwarmDash", Enum.RenderPriority.Input.Value + 2, function(dt: number)
		local pend = pendingSince
		if pend and os.clock() - pend > D.AckTimeout then
			pendingSince = nil
		end
		step(dt)
		updateButton()
	end)

	-- the server's answer (the remotes exist once the server booted)
	task.spawn(function()
		local net = ReplicatedStorage:WaitForChild("SwarmV2Net"):WaitForChild("Run")
		request = net:WaitForChild("Dash") :: RemoteEvent
		local ack = net:WaitForChild("DashAck") :: RemoteEvent
		ack.OnClientEvent:Connect(function(ok, kind, dir, speed, duration, vy, _cooldown)
			if pendingSince == nil then
				return -- too late: the request timed out
			end
			pendingSince = nil
			if ok ~= true or typeof(dir) ~= "Vector3" or type(speed) ~= "number" or type(duration) ~= "number" or type(vy) ~= "number" then
				return
			end
			if kind ~= "Dash" and kind ~= "Leap" then
				return
			end
			start(kind, dir, speed, duration, vy)
		end)
		-- spring launch pads: the server starts the arc (no request, no cooldown)
		local launch = net:WaitForChild("Launch") :: RemoteEvent
		launch.OnClientEvent:Connect(function(dir, speed, duration, vy)
			if typeof(dir) ~= "Vector3" or type(speed) ~= "number" or type(duration) ~= "number" or type(vy) ~= "number" then
				return
			end
			start("Leap", dir, speed, duration, vy)
		end)
	end)

	player:GetAttributeChangedSignal("Alive"):Connect(function()
		if player:GetAttribute("Alive") == false then
			stop()
		end
	end)
	player:GetAttributeChangedSignal("InRun"):Connect(function()
		if player:GetAttribute("InRun") ~= true then
			stop()
			pendingSince = nil
		end
	end)
end

return DashClient
