--[[
	CameraController.lua
	Run camera: third-person orbit (docs/redesign/gameplay/DESIGN.md section 1). Yaw and pitch
	come from input (touch drag on the camera side of the screen, right-mouse drag or mouse-look,
	gamepad right stick), distance 22 (pinch / wheel 16-28), focus = root + (0, 2.5, 0). A
	spherecast pulls the camera in front of walls (fast in, slow out). Touch and gamepad recenter
	behind the move direction after RecenterDelay without camera input. GroundAxes() gives the
	camera-relative move axes. Reduced motion (ClientSettings.Reduced): no shake, kick or FOV kick,
	slower recenter. When the local player is dead it follows a living teammate (spectate). Shake
	(smooth noise) and Kick (a short pull toward the hero) add combat punch, both scaled by the
	Screen shake setting.

	Outside a run: if workspace attribute "SwarmV2Lobby" == true the lobby uses the standard Roblox
	follow camera (CameraType Custom, left alone). Otherwise the old menu camera below.

	Lobby (not in a run): the 2D lobby screen covers the screen and the camera is a fixed
	scenic shot. If workspace has a Model/Folder "Lobby" (directly or inside "SwarmMap")
	holding a part named "MenuCamera", that part's CFrame is used; otherwise a fixed view
	of the lobby spawn (SwarmState attribute "LobbySpawn"). It sways very slightly.
]]

local CollectionService = game:GetService("CollectionService")
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")

local Shared = game:GetService("ReplicatedStorage"):WaitForChild("Shared")
local Config = require(Shared:WaitForChild("Config"))
local Remotes = require(Shared:WaitForChild("Remotes"))
local ClientSettings = require(script.Parent:WaitForChild("ClientSettings"))
local RunConfig = require(game:GetService("ReplicatedStorage"):WaitForChild("SwarmV2"):WaitForChild("Run"):WaitForChild("RunConfig"))

local CameraController = {}

local player = Players.LocalPlayer
local focus: Vector3? = nil
local shake = 0 -- studs of jitter at the start of the running shake
local shakeLeft = 0 -- seconds of it left (it fades to nothing over shakeLen)
local shakeLen = 0.11
local kick = 0 -- studs of camera punch (Kick), eased out
local spectated: Player? = nil -- teammate followed while the local player is down
local subjectKey: any = nil -- who the follow camera is on (a change = glide, not snap)
local panUntil = 0 -- while > now, the follow camera glides to a new subject

local menuPart: BasePart? = nil
local nextMenuSearch = 0
local menuBlend = 0 -- 0 = follow camera, 1 = lobby menu camera (smooth switch)
local menuTilt = 0 -- menu framing offset (screen fraction), eased toward MenuHeroY
local menuPan = 0 -- sideways framing offset (screen fraction), eased toward MenuHeroX

-- The "MenuCamera" part of the lobby, searched again every 2 s until found.
local function findMenuCamera(): BasePart?
	if menuPart and menuPart:IsDescendantOf(workspace) then
		return menuPart
	end
	menuPart = nil
	local now = os.clock()
	if now < nextMenuSearch then
		return nil
	end
	nextMenuSearch = now + 2
	local map = workspace:FindFirstChild("SwarmMap")
	-- two candidates, either may be nil (ipairs would stop at a nil first entry)
	local candidates = { workspace:FindFirstChild("Lobby") or false, map and map:FindFirstChild("Lobby") or false }
	for _, lobby in ipairs(candidates) do
		local cam = lobby and lobby:FindFirstChild("MenuCamera", true)
		if cam and cam:IsA("BasePart") then
			menuPart = cam
			return cam
		end
	end
	return nil
end

-- Where the lobby menu camera sits.
local function menuCFrame(): CFrame?
	local part = findMenuCamera()
	if part then
		return part.CFrame
	end
	local spawn = Remotes.State():GetAttribute("LobbySpawn")
	if typeof(spawn) == "CFrame" then
		local at = spawn.Position
		return CFrame.lookAt(at + Vector3.new(0, 9, 24), at + Vector3.new(0, 2, -6))
	end
	return nil
end

--[[
	Short screen shake. Ordinary feedback (hits taken, explosions, kills) is mild and over in
	Config.Camera.ShakeSeconds (< 0.12 s) at most OrdinaryShakeMax studs; kind "boss" (a boss roar, a
	phase change, the Boss stage, a huge kill) is the one longer shake, still capped: BossShakeMax
	studs for BossShakeSeconds. Scaled by ShakeScale and the player's Screen shake setting (0 = off);
	Reduced effects: none at all. A stronger shake replaces a weaker one that is still running.
]]
function CameraController.Shake(amount: number, kind: string?)
	if ClientSettings.Reduced() then
		return
	end
	local cam = Config.Camera :: any
	local setting = tonumber(ClientSettings.Get("Shake")) or 1
	if setting <= 0 or amount ~= amount then
		return
	end
	local boss = kind == "boss"
	local cap = math.min(boss and (cam.BossShakeMax or 0.55) or (cam.OrdinaryShakeMax or 0.4), cam.ShakeMax or 0.6)
	local a = math.min(amount * (cam.ShakeScale or 1) * setting, cap * setting)
	local len = boss and (cam.BossShakeSeconds or 0.3) or (cam.ShakeSeconds or 0.11)
	local current = shakeLeft > 0 and shake * (shakeLeft / shakeLen) or 0
	if a >= current then
		shake = a
		shakeLen = len
		shakeLeft = len
	end
end

-- For tests: { Amount (studs now), Left (seconds), Length } of the running shake.
function CameraController.ShakeState(): { Amount: number, Left: number, Length: number }
	return { Amount = shakeLeft > 0 and shake * (shakeLeft / shakeLen) or 0, Left = math.max(shakeLeft, 0), Length = shakeLen }
end

-- Short camera punch toward the hero (big kills, evolution, boss phase): the "hit-stop"
-- beat. `amount` = studs pulled in, capped at KickMax, scaled by the Screen shake setting
-- like Shake, eased back out within ~0.2 s.
function CameraController.Kick(amount: number)
	if ClientSettings.Reduced() then
		return
	end
	local cam = Config.Camera :: any
	local setting = tonumber(ClientSettings.Get("Shake")) or 1
	if setting <= 0 then
		return
	end
	kick = math.max(kick, math.min(amount * (cam.ShakeScale or 1), cam.KickMax or 2) * setting)
end

local function rootOf(p: Player): BasePart?
	local char = p.Character
	return char and char:FindFirstChild("HumanoidRootPart") :: BasePart?
end

local function canSpectate(p: Player?): boolean
	-- [stream F] a living teammate: not downed, not eliminated (the new survival attributes)
	return p ~= nil
		and p.Parent ~= nil
		and p:GetAttribute("InRun") == true
		and p:GetAttribute("Alive") ~= false
		and p:GetAttribute("Downed") ~= true
		and p:GetAttribute("Eliminated") ~= true
		and rootOf(p) ~= nil
end

-- [stream F] The local player is out of the action: down in the older flow (Alive false) or, in the
-- new survival rules, eliminated / spectating. The follow camera and the spectate cycle use this.
local function iAmOut(): boolean
	return player:GetAttribute("Alive") == false or player:GetAttribute("Eliminated") == true or player:GetAttribute("Spectating") == true
end

-- Living teammates the camera may follow, in a stable order (UserId).
local function spectateList(): { Player }
	local list = {}
	for _, other in ipairs(Players:GetPlayers()) do
		if other ~= player and canSpectate(other) then
			table.insert(list, other)
		end
	end
	table.sort(list, function(a, b)
		return a.UserId < b.UserId
	end)
	return list
end

-- The teammate followed while the local player is down in a run (nil otherwise).
function CameraController.Spectated(): Player?
	if player:GetAttribute("InRun") == true and iAmOut() and canSpectate(spectated) then
		return spectated
	end
	return nil
end

-- Spectate (feature 20, docs/features/TEAM.md): follow the next (step 1) or previous
-- (step -1) living teammate. Only while the local player is down in a run; the camera
-- glides over (SpectatePanSeconds). Returns who is followed now.
function CameraController.SpectateCycle(step: number): Player?
	if player:GetAttribute("InRun") ~= true or not iAmOut() then
		return nil
	end
	local list = spectateList()
	if #list == 0 then
		return nil
	end
	local at = spectated and table.find(list, spectated) or nil
	local i = at and ((at - 1 + (step < 0 and -1 or 1)) % #list + 1) or 1
	spectated = list[i]
	return spectated
end

------------------------------------------------------------------------------------------
-- Third-person orbit state and input
------------------------------------------------------------------------------------------
local R = RunConfig.Camera
local yaw = math.rad(Config.Camera.Yaw) -- the camera sits at +(sin yaw, cos yaw) from the focus
local pitch = math.rad(R.Pitch)
local userDist: number = R.Distance
local camDist: number? = nil -- collision-adjusted distance
local lastInputAt = -math.huge
local touchCam: InputObject? = nil
local rmbDown = false
local mouseLocked = false
local padLook = Vector2.zero
local pinchBase: number? = nil
local fovKick = 0
local wasInRun = false
local standardMode = false -- the lobby uses the standard Roblox camera

local function movementSide(x: number, width: number): boolean
	local left = ClientSettings.Get("TouchLayout") == "LeftHanded"
	local zone = math.min(Config.Controls.TouchZone, 0.5)
	return left and x >= width * (1 - zone) or not left and x <= width * zone
end

local function cameraSide(x: number): boolean
	return not movementSide(x, workspace.CurrentCamera.ViewportSize.X)
end

local function rotate(dx: number, dy: number)
	-- [stream L1] Settings: camera sensitivity and invert X / Y apply to every look input (touch, mouse, stick)
	local look, signX, signY = ClientSettings.CameraTuning()
	dx, dy = dx * look * signX, dy * look * signY
	yaw -= dx
	pitch = math.clamp(pitch + dy, math.rad(R.MinPitch), math.rad(R.MaxPitch))
	lastInputAt = os.clock()
end

local function inRunNow(): boolean
	return player:GetAttribute("InRun") == true
end

local function setupInput()
	UserInputService.InputBegan:Connect(function(input, processed)
		if processed or not inRunNow() then
			return
		end
		local t = input.UserInputType
		if t == Enum.UserInputType.Touch then
			if touchCam == nil and cameraSide(input.Position.X) then
				touchCam = input
				lastInputAt = os.clock()
			end
		elseif t == Enum.UserInputType.MouseButton2 then
			rmbDown = true
			lastInputAt = os.clock()
		elseif input.KeyCode == R.MouseLockKey then
			mouseLocked = not mouseLocked
			if not mouseLocked and not rmbDown then
				UserInputService.MouseBehavior = Enum.MouseBehavior.Default
			end
		end
	end)

	UserInputService.InputChanged:Connect(function(input, processed)
		local t = input.UserInputType
		if input == touchCam then
			rotate(input.Delta.X * R.TouchSensitivity, input.Delta.Y * R.TouchSensitivity)
		elseif t == Enum.UserInputType.MouseMovement then
			if (rmbDown or mouseLocked) and inRunNow() then
				rotate(input.Delta.X * R.MouseSensitivity, input.Delta.Y * R.MouseSensitivity)
			end
		elseif t == Enum.UserInputType.MouseWheel then
			if not processed and inRunNow() then
				userDist = math.clamp(userDist - input.Position.Z * R.WheelStep, R.MinDistance, R.MaxDistance)
			end
		elseif t == Enum.UserInputType.Gamepad1 and input.KeyCode == Enum.KeyCode.Thumbstick2 then
			padLook = Vector2.new(input.Position.X, input.Position.Y)
		end
	end)

	UserInputService.InputEnded:Connect(function(input)
		if input == touchCam then
			touchCam = nil
		elseif input.UserInputType == Enum.UserInputType.MouseButton2 then
			rmbDown = false
			if not mouseLocked then
				UserInputService.MouseBehavior = Enum.MouseBehavior.Default
			end
		end
	end)

	-- two fingers on the camera side: pinch zoom
	UserInputService.TouchPinch:Connect(function(positions, scale, _velocity, state, processed)
		if processed or not inRunNow() or #positions < 2 then
			return
		end
		if not (cameraSide(positions[1].X) and cameraSide(positions[2].X)) then
			return
		end
		if state == Enum.UserInputState.Begin or pinchBase == nil then
			pinchBase = userDist
		end
		local base = pinchBase
		if base and scale > 0.05 then
			userDist = math.clamp(base / scale, R.MinDistance, R.MaxDistance)
		end
		if state == Enum.UserInputState.End or state == Enum.UserInputState.Cancel then
			pinchBase = nil
		end
	end)

	UserInputService.WindowFocusReleased:Connect(function()
		touchCam = nil
		rmbDown = false
		padLook = Vector2.zero
		if not mouseLocked then
			UserInputService.MouseBehavior = Enum.MouseBehavior.Default
		end
	end)
end

-- Camera collision: a spherecast from the focus toward the wanted position. Characters, enemies,
-- projectiles, loot, effects, non-colliding parts and anything tagged CameraIgnore (or a tree
-- canopy that fades, Occlusion) never block it.
local ignoreNames: { [string]: boolean } = {}
for _, name in ipairs(R.IgnoreFolders) do
	ignoreNames[name] = true
end
local castParams = RaycastParams.new()
castParams.FilterType = Enum.RaycastFilterType.Exclude
local filterList: { Instance } = {}

local function ignorable(part: BasePart): boolean
	if not part.CanCollide or CollectionService:HasTag(part, R.IgnoreTag) or CollectionService:HasTag(part, "SwarmOccluder") then
		return true
	end
	local node: Instance? = part.Parent
	while node and node ~= workspace do
		if ignoreNames[node.Name] or CollectionService:HasTag(node, R.IgnoreTag) or CollectionService:HasTag(node, "SwarmOccluder") then
			return true
		end
		if node:IsA("Model") and node:FindFirstChildOfClass("Humanoid") then
			return true
		end
		node = node.Parent
	end
	return false
end

-- How far from `from` along `dir` (unit) the camera may go, up to `want` studs.
local function clearDistance(from: Vector3, dir: Vector3, want: number): number
	table.clear(filterList)
	for _, p in ipairs(Players:GetPlayers()) do
		if p.Character then
			table.insert(filterList, p.Character)
		end
	end
	local best = want
	for _ = 1, 4 do
		castParams.FilterDescendantsInstances = filterList
		local hit = workspace:Spherecast(from, R.CollisionRadius, dir * want, castParams)
		if not hit then
			break
		end
		if ignorable(hit.Instance) then
			table.insert(filterList, hit.Instance)
		else
			best = math.max(R.MinCollisionDistance, math.min(want, hit.Distance))
			break
		end
	end
	return best
end

-- A short widening of the FOV (dash start). Off in reduced motion.
function CameraController.FovKick(degrees: number)
	if ClientSettings.Reduced() then
		return
	end
	fovKick = math.max(fovKick, math.min(degrees, 12))
end

-- Camera yaw (radians; the camera sits at +(sin yaw, cos yaw) of the focus).
function CameraController.GetYaw(): number
	return yaw
end

-- Reduced camera motion for jumps: while the local hero is in the air (a hop) the camera
-- keeps the height it had on the ground, so bunny hops never bob the view. A long fall
-- (over AirHoldSeconds) is followed normally.
local AIR_HOLD_SECONDS = 1.2
local groundY: number? = nil
local airSince = 0
local function steadyHeight(root: BasePart): Vector3
	local pos = root.Position
	local hum = root.Parent and root.Parent:FindFirstChildOfClass("Humanoid")
	local now = os.clock()
	local airborne = hum ~= nil and hum.FloorMaterial == Enum.Material.Air
	if not airborne or groundY == nil then
		groundY = pos.Y
		airSince = now
		return pos
	end
	if now - airSince > AIR_HOLD_SECONDS or math.abs(pos.Y - (groundY :: number)) > 12 then
		groundY = pos.Y
		return pos
	end
	return Vector3.new(pos.X, groundY :: number, pos.Z)
end

-- Who the follow camera is on (and where): the local player, or while they are down the
-- same living teammate for as long as that teammate stays up.
local function subjectPosition(): (Vector3?, any)
	local inRun = player:GetAttribute("InRun") == true
	if inRun and iAmOut() then
		if not canSpectate(spectated) then
			spectated = nil
			for _, other in ipairs(Players:GetPlayers()) do
				if other ~= player and canSpectate(other) then
					spectated = other
					break
				end
			end
		end
		local sp = spectated
		if sp then
			local root = rootOf(sp)
			if root then
				return root.Position, sp
			end
		end
	else
		spectated = nil
	end
	local root = rootOf(player)
	if root then
		return steadyHeight(root), player
	end
	return nil, nil
end

local function lobbyIsStandard(): boolean
	return workspace:GetAttribute("SwarmV2Lobby") == true and not inRunNow()
end

function CameraController.Init()
	local camera = workspace.CurrentCamera
	if not lobbyIsStandard() then
		camera.CameraType = Enum.CameraType.Scriptable
	end
	camera.FieldOfView = Config.Camera.FieldOfView
	setupInput()

	-- Roblox may reset the camera type when the character changes.
	player.CharacterAdded:Connect(function()
		task.defer(function()
			if not lobbyIsStandard() then
				workspace.CurrentCamera.CameraType = Enum.CameraType.Scriptable
			end
		end)
	end)

	RunService:BindToRenderStep("SwarmCamera", Enum.RenderPriority.Camera.Value + 1, function(dt)
		local cam = workspace.CurrentCamera
		local inRun = player:GetAttribute("InRun") == true
		standardMode = lobbyIsStandard()
		if standardMode then
			-- the lobby track's basecamp: the standard follow camera, left alone
			if cam.CameraType ~= Enum.CameraType.Custom then
				cam.CameraType = Enum.CameraType.Custom
			end
			local hum = player.Character and player.Character:FindFirstChildOfClass("Humanoid")
			if hum and cam.CameraSubject ~= hum then
				cam.CameraSubject = hum
			end
			menuBlend = 0
			focus = nil
			camDist = nil
			wasInRun = false
			return
		end
		if cam.CameraType ~= Enum.CameraType.Scriptable then
			cam.CameraType = Enum.CameraType.Scriptable
		end
		if not inRun then
			local menu = menuCFrame()
			if menu then
				local part = findMenuCamera()
				local fov = part and tonumber(part:GetAttribute("FieldOfView"))
				local menuFov = fov or Config.Camera.FieldOfView
				if cam.ViewportSize.Y > cam.ViewportSize.X then
					-- portrait: a taller view keeps the hero on the dais at a sensible size
					menuFov = math.min(menuFov * 1.4, 80)
				end
				-- the lobby layout asks for a wider shot when the hero has little room on
				-- screen (portrait with the LAST RUN card): MenuHeroZoom scales the view
				local zoom = tonumber(cam:GetAttribute("MenuHeroZoom")) or 1
				if zoom > 1 then
					menuFov = math.min(math.deg(2 * math.atan(math.tan(math.rad(menuFov) / 2) * zoom)), 95)
				end
				cam.FieldOfView = menuFov
				-- slow "breathing" sway so the backdrop feels alive
				local t = os.clock()
				local sway = CFrame.Angles(math.sin(t * 0.21) * 0.012, math.sin(t * 0.17) * 0.025, 0)
				-- framing: the menu layout (LobbyScreen) says where on screen the hero on the
				-- dais should sit (camera attribute MenuHeroY, 0 = top, 0.5 = centre); tilt
				-- the shot so the aim point lands there (portrait puts the hero higher)
				local heroY = tonumber(cam:GetAttribute("MenuHeroY")) or 0.5
				menuTilt += (math.clamp(0.5 - heroY, -0.25, 0.25) - menuTilt) * math.min(1, dt * 5)
				local tilt = math.atan(2 * menuTilt * math.tan(math.rad(cam.FieldOfView) / 2))
				-- MenuHeroX (0 = left edge, 0.5 = centre): the title screen puts the hero on the
				-- dais right of centre, so the shot turns left by the matching angle
				local heroX = tonumber(cam:GetAttribute("MenuHeroX")) or 0.5
				menuPan += (math.clamp(heroX - 0.5, -0.25, 0.25) - menuPan) * math.min(1, dt * 5)
				local aspect = cam.ViewportSize.X / math.max(1, cam.ViewportSize.Y)
				local pan = math.atan(2 * menuPan * math.tan(math.rad(cam.FieldOfView) / 2) * aspect)
				local goal = menu * CFrame.Angles(0, pan, 0) * CFrame.Angles(-tilt, 0, 0) * sway
				menuBlend = math.min(1, menuBlend + dt * 2)
				if menuBlend >= 1 then
					cam.CFrame = goal
				else
					cam.CFrame = cam.CFrame:Lerp(goal, math.min(1, dt * 6))
				end
				cam.Focus = goal * CFrame.new(0, 0, -20)
				focus = nil -- the run camera snaps to the player when the run starts
				return
			end
		end
		menuBlend = 0
		local C = Config.Camera :: any
		local reduced = ClientSettings.Reduced()
		local target, who = subjectPosition()
		if not target then
			return
		end
		if inRun and target.Y < Config.ArenaOrigin.Y + 1 then
			-- never follow a hero under the floor (the server puts a fallen hero back,
			-- RunManager fallRescue): the view stays above the arena meanwhile
			target = Vector3.new(target.X, Config.ArenaOrigin.Y + 1, target.Z)
		end
		local now = os.clock()
		if who ~= subjectKey then
			-- spectate switch: glide over instead of cutting (the first subject snaps)
			if subjectKey ~= nil and focus then
				panUntil = now + (C.SpectatePanSeconds or 0.4)
			end
			subjectKey = who
		end
		target += Vector3.new(0, R.FocusHeight, 0)

		-- a run starts: the view is behind the hero, looking where it looks
		if inRun and not wasInRun then
			local rootNow = rootOf(player)
			if rootNow then
				local lookDir = rootNow.CFrame.LookVector
				yaw = math.atan2(-lookDir.X, -lookDir.Z)
			end
			pitch = math.rad(R.Pitch)
			userDist = R.Distance
			focus = nil
			camDist = nil
		end
		wasInRun = inRun

		-- orbit input held this frame
		if mouseLocked then
			UserInputService.MouseBehavior = Enum.MouseBehavior.LockCenter
		elseif rmbDown then
			UserInputService.MouseBehavior = Enum.MouseBehavior.LockCurrentPosition
		end
		local padActive = padLook.Magnitude > R.GamepadDeadZone
		if padActive then
			rotate(padLook.X * R.GamepadRate * dt, -padLook.Y * R.GamepadRate * dt)
		end
		local dragging = touchCam ~= nil or rmbDown or mouseLocked or padActive

		-- recenter behind the move direction (touch and gamepad; slower in reduced motion)
		local keyboardOnly = UserInputService.KeyboardEnabled and not UserInputService.TouchEnabled and not UserInputService.GamepadEnabled
		if inRun and not dragging and not keyboardOnly and now - lastInputAt >= R.RecenterDelay then
			local hum = player.Character and player.Character:FindFirstChildOfClass("Humanoid")
			local move = hum and hum.MoveDirection or Vector3.zero
			if move.Magnitude > 0.3 then
				local moveDir = Vector3.new(move.X, 0, move.Z).Unit
				local fwd = Vector3.new(-math.sin(yaw), 0, -math.cos(yaw))
				if moveDir:Dot(fwd) >= R.RecenterMinDot then
					local goal = math.atan2(-moveDir.X, -moveDir.Z)
					local delta = (goal - yaw + math.pi) % (2 * math.pi) - math.pi
					local rate = if reduced then R.RecenterRateReduced else R.RecenterRate
					local maxStep = rate * dt
					-- slow down near the goal so it settles instead of snapping
					yaw += math.clamp(delta * math.min(1, math.abs(delta) / 0.3 + 0.2), -maxStep, maxStep)
				end
			end
		end

		-- focus: spectate glide, snap on teleports, otherwise smoothed
		if now < panUntil and focus and (target - (focus :: Vector3)).Magnitude < 400 then
			local left = math.max(panUntil - now, 1e-3)
			focus = (focus :: Vector3):Lerp(target, math.clamp(dt / left * 2.2, 0, 1))
		elseif not focus or (target - (focus :: Vector3)).Magnitude > 40 then
			focus = target
		else
			focus = (focus :: Vector3):Lerp(target, 1 - math.exp(-dt * R.FollowSharpness))
		end

		local look = focus :: Vector3
		local dir = Vector3.new(math.sin(yaw) * math.cos(pitch), math.sin(pitch), math.cos(yaw) * math.cos(pitch))

		-- collision: pull in fast, ease back out slowly
		local clear = clearDistance(look, dir, userDist)
		local cd = camDist
		if cd == nil or clear < cd - 4 then
			cd = clear
		elseif clear < cd then
			cd += (clear - cd) * math.min(1, dt * R.PullInRate)
		else
			cd += (clear - cd) * math.min(1, dt * R.EaseOutRate)
		end
		camDist = cd
		local dist: number = math.min(cd, clear)
		if kick > 0.02 then
			-- the punch: pulled in along the view line, eased back out
			dist = math.max(R.MinCollisionDistance, dist - kick)
			kick *= math.exp(-dt * 24) -- [stream G] a 1.5-stud punch is gone in ~0.18 s (was 16: ~0.27 s)
		else
			kick = 0
		end

		local jitter = Vector3.zero
		if shakeLeft > 0 and shake > 0.01 and not reduced then
			-- smooth noise (not per-frame random jumps) that fades out linearly over the shake's length
			local t = now * 18
			jitter = Vector3.new(math.noise(t, 0.3), math.noise(0.7, t) * 0.6, math.noise(t, 5.1)) * (2 * shake * (shakeLeft / shakeLen))
			shakeLeft -= dt
		else
			shake = 0
			shakeLeft = 0
		end
		if fovKick > 0.05 then
			fovKick *= math.exp(-dt * 8)
		else
			fovKick = 0
		end
		cam.FieldOfView = (if inRun then R.FieldOfView else C.FieldOfView) + fovKick
		cam.CFrame = CFrame.lookAt(look + dir * dist + jitter, look + jitter)
		cam.Focus = CFrame.new(look)
	end)
end


-- World-space forward/right on the ground plane for camera-relative movement: the orbit
-- yaw in a run, the standard camera's look direction in the lobby.
function CameraController.GroundAxes(): (Vector3, Vector3)
	local forward: Vector3
	if standardMode then
		local look = workspace.CurrentCamera.CFrame.LookVector
		local flat = Vector3.new(look.X, 0, look.Z)
		forward = if flat.Magnitude > 1e-3 then flat.Unit else Vector3.new(0, 0, -1)
	else
		forward = Vector3.new(-math.sin(yaw), 0, -math.cos(yaw))
	end
	local right = Vector3.new(-forward.Z, 0, forward.X)
	return forward, right
end

return CameraController
