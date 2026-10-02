--[[
	CameraController.lua
	Fixed-angle, slightly top-down follow camera. No rotation or zoom input: on a phone
	every touch is movement. Zooms out further during runs and in portrait orientation.
	When the local player is dead it follows a living teammate (spectate).

	Lobby (not in a run): the 2D lobby screen covers the screen and the camera is a fixed
	scenic shot. If workspace has a Model/Folder "Lobby" (directly or inside "SwarmMap")
	holding a part named "MenuCamera", that part's CFrame is used; otherwise a fixed view
	of the lobby spawn (SwarmState attribute "LobbySpawn"). It sways very slightly.
]]

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")

local Shared = game:GetService("ReplicatedStorage"):WaitForChild("Shared")
local Config = require(Shared:WaitForChild("Config"))
local Remotes = require(Shared:WaitForChild("Remotes"))
local ClientSettings = require(script.Parent:WaitForChild("ClientSettings"))

local CameraController = {}

local player = Players.LocalPlayer
local focus: Vector3? = nil
local distance = Config.Camera.LobbyDistance
local shake = 0
local spectated: Player? = nil -- teammate followed while the local player is down
local subjectKey: any = nil -- who the follow camera is on (a change = glide, not snap)
local panUntil = 0 -- while > now, the follow camera glides to a new subject

local menuPart: BasePart? = nil
local nextMenuSearch = 0
local menuBlend = 0 -- 0 = follow camera, 1 = lobby menu camera (smooth switch)
local menuTilt = 0 -- menu framing offset (screen fraction), eased toward MenuHeroY

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

-- Short screen shake (hurt, explosions, boss).
-- Kept small: scaled by Config.Camera.ShakeScale and the player's Screen shake setting
-- (0 = off), capped at ShakeMax studs.
function CameraController.Shake(amount: number)
	local cam = Config.Camera :: any
	local setting = tonumber(ClientSettings.Get("Shake")) or 1
	if setting <= 0 then
		return
	end
	local a = math.min(amount * (cam.ShakeScale or 1) * setting, (cam.ShakeMax or 0.6) * setting)
	shake = math.max(shake, a)
end

local function rootOf(p: Player): BasePart?
	local char = p.Character
	return char and char:FindFirstChild("HumanoidRootPart") :: BasePart?
end

local function canSpectate(p: Player?): boolean
	return p ~= nil and p.Parent ~= nil and p:GetAttribute("InRun") == true and p:GetAttribute("Alive") == true and rootOf(p) ~= nil
end

-- Who the follow camera is on (and where): the local player, or while they are down the
-- same living teammate for as long as that teammate stays up.
local function subjectPosition(): (Vector3?, any)
	local inRun = player:GetAttribute("InRun") == true
	if inRun and player:GetAttribute("Alive") == false then
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
		return root.Position, player
	end
	return nil, nil
end

function CameraController.Init()
	local camera = workspace.CurrentCamera
	camera.CameraType = Enum.CameraType.Scriptable
	camera.FieldOfView = Config.Camera.FieldOfView

	-- Roblox may reset the camera type when the character changes.
	player.CharacterAdded:Connect(function()
		task.defer(function()
			workspace.CurrentCamera.CameraType = Enum.CameraType.Scriptable
		end)
	end)

	RunService:BindToRenderStep("SwarmCamera", Enum.RenderPriority.Camera.Value + 1, function(dt)
		local cam = workspace.CurrentCamera
		if cam.CameraType ~= Enum.CameraType.Scriptable then
			cam.CameraType = Enum.CameraType.Scriptable
		end
		local inRun = player:GetAttribute("InRun") == true
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
				local goal = menu * CFrame.Angles(-tilt, 0, 0) * sway
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
		cam.FieldOfView = inRun and (C.RunFieldOfView or C.FieldOfView) or C.FieldOfView
		local target, who = subjectPosition()
		if not target then
			return
		end
		local now = os.clock()
		if who ~= subjectKey then
			-- spectate switch: glide over instead of cutting (the first subject snaps)
			if subjectKey ~= nil and focus then
				panUntil = now + (C.SpectatePanSeconds or 0.4)
			end
			subjectKey = who
		end
		local viewport = cam.ViewportSize
		local portrait = viewport.Y > viewport.X
		local want = inRun and Config.Camera.RunDistance or Config.Camera.LobbyDistance
		if portrait then
			want *= Config.Camera.PortraitDistanceMult
		end
		distance += (want - distance) * math.min(1, dt * 3)

		-- big jumps (teleports) snap, normal movement is smoothed
		if now < panUntil and focus and (target - (focus :: Vector3)).Magnitude < 400 then
			-- quick, eased glide to the new subject
			local left = math.max(panUntil - now, 1e-3)
			focus = (focus :: Vector3):Lerp(target, math.clamp(dt / left * 2.2, 0, 1))
		elseif not focus or (target - (focus :: Vector3)).Magnitude > 40 then
			focus = target
		else
			focus = (focus :: Vector3):Lerp(target, 1 - math.exp(-dt * Config.Camera.FollowSharpness))
		end

		local pitch = math.rad(Config.Camera.Pitch)
		local yaw = math.rad(Config.Camera.Yaw)
		local offset = Vector3.new(math.sin(yaw) * math.cos(pitch), math.sin(pitch), math.cos(yaw) * math.cos(pitch)) * distance
		local look = focus :: Vector3
		local jitter = Vector3.zero
		if shake > 0.01 then
			-- smooth noise (not per-frame random jumps), decaying fast
			local t = now * 18
			jitter = Vector3.new(math.noise(t, 0.3), math.noise(0.7, t) * 0.6, math.noise(t, 5.1)) * (2 * shake)
			shake *= math.exp(-dt * 7)
		else
			shake = 0
		end
		cam.CFrame = CFrame.lookAt(look + offset + jitter, look + jitter)
		cam.Focus = CFrame.new(look)
	end)
end

-- World-space forward/right on the ground plane for camera-relative movement.
function CameraController.GroundAxes(): (Vector3, Vector3)
	local yaw = math.rad(Config.Camera.Yaw)
	local forward = Vector3.new(-math.sin(yaw), 0, -math.cos(yaw))
	local right = Vector3.new(-forward.Z, 0, forward.X)
	return forward, right
end

return CameraController
