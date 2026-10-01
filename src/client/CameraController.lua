--[[
	CameraController.lua
	Fixed-angle, slightly top-down follow camera. No rotation or zoom input: on a phone
	every touch is movement. Zooms out further during runs and in portrait orientation.
	When the local player is dead it follows a living teammate (spectate).
]]

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")

local Config = require(game:GetService("ReplicatedStorage"):WaitForChild("Shared"):WaitForChild("Config"))

local CameraController = {}

local player = Players.LocalPlayer
local focus: Vector3? = nil
local distance = Config.Camera.LobbyDistance
local shake = 0

-- Short screen shake (hurt, explosions, boss).
function CameraController.Shake(amount: number)
	shake = math.max(shake, amount)
end

local function subjectPosition(): Vector3?
	local inRun = player:GetAttribute("InRun") == true
	if inRun and player:GetAttribute("Alive") == false then
		-- spectate the first living teammate
		for _, other in ipairs(Players:GetPlayers()) do
			if other ~= player and other:GetAttribute("InRun") and other:GetAttribute("Alive") then
				local char = other.Character
				local root = char and char:FindFirstChild("HumanoidRootPart") :: BasePart?
				if root then
					return root.Position
				end
			end
		end
	end
	local char = player.Character
	local root = char and char:FindFirstChild("HumanoidRootPart") :: BasePart?
	if root then
		return root.Position
	end
	return nil
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
		local target = subjectPosition()
		if not target then
			return
		end
		local inRun = player:GetAttribute("InRun") == true
		local viewport = cam.ViewportSize
		local portrait = viewport.Y > viewport.X
		local want = inRun and Config.Camera.RunDistance or Config.Camera.LobbyDistance
		if portrait then
			want *= Config.Camera.PortraitDistanceMult
		end
		distance += (want - distance) * math.min(1, dt * 3)

		-- big jumps (teleports) snap, normal movement is smoothed
		if not focus or (target - (focus :: Vector3)).Magnitude > 40 then
			focus = target
		else
			focus = (focus :: Vector3):Lerp(target, math.min(1, dt * Config.Camera.FollowSharpness))
		end

		local pitch = math.rad(Config.Camera.Pitch)
		local yaw = math.rad(Config.Camera.Yaw)
		local offset = Vector3.new(math.sin(yaw) * math.cos(pitch), math.sin(pitch), math.cos(yaw) * math.cos(pitch)) * distance
		local look = focus :: Vector3
		local jitter = Vector3.zero
		if shake > 0.01 then
			jitter = Vector3.new(math.random() - 0.5, math.random() - 0.5, math.random() - 0.5) * shake
			shake *= math.max(0, 1 - dt * 8)
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
