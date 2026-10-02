--[[
	MobileControls.lua
	Movement only: a floating virtual thumbstick (appears wherever the thumb lands),
	WASD / arrow keys and a gamepad left stick. No jump, no attack buttons.

	The default Roblox control scripts are disabled (StarterPlayer movement modes are
	"Scriptable" in default.project.json); this module calls Humanoid:Move every frame
	with a direction relative to the fixed camera.
]]

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")

local Config = require(game:GetService("ReplicatedStorage"):WaitForChild("Shared"):WaitForChild("Config"))
local Theme = require(game:GetService("ReplicatedStorage"):WaitForChild("Shared"):WaitForChild("Theme"))
local CameraController = require(script.Parent.CameraController)

local MobileControls = {}

local player = Players.LocalPlayer
local enabled = true
local stickInput: InputObject? = nil
local stickOrigin = Vector2.zero
local stickVector = Vector2.zero -- x right, y down (screen space), length 0..1
local keys: { [Enum.KeyCode]: boolean } = {}
local gamepadVector = Vector2.zero

local gui: ScreenGui
local base: Frame
local knob: Frame
local uiScale: UIScale? = nil

-- Lets other UI stop movement (level-up screen, panels, results).
function MobileControls.SetEnabled(on: boolean)
	enabled = on
	if not on then
		stickInput = nil
		stickVector = Vector2.zero
		base.Visible = false
	end
end

function MobileControls.SetScale(scale: UIScale)
	uiScale = scale
end

local function radiusPixels(): number
	local s = uiScale and uiScale.Scale or 1
	return Config.Controls.StickRadius * s
end

local function updateStick(position: Vector2)
	local delta = position - stickOrigin
	local r = radiusPixels()
	if delta.Magnitude > r then
		-- drag the base along so the stick never "sticks" at the edge
		stickOrigin = position - delta.Unit * r
		delta = position - stickOrigin
	end
	stickVector = delta / r
	if stickVector.Magnitude < Config.Controls.DeadZone then
		stickVector = Vector2.zero
	end
	-- InputObject positions and this ScreenGui (IgnoreGuiInset = false) share coordinates
	base.Position = UDim2.fromOffset(stickOrigin.X, stickOrigin.Y)
	knob.Position = UDim2.new(0.5, delta.X / (uiScale and uiScale.Scale or 1), 0.5, delta.Y / (uiScale and uiScale.Scale or 1))
end

local function buildGui()
	gui = Instance.new("ScreenGui")
	gui.Name = "SwarmStick"
	gui.ResetOnSpawn = false
	gui.IgnoreGuiInset = false
	-- above the HUD (a stick may start over the ability bar); hidden while modals are open
	gui.DisplayOrder = 11
	gui.Parent = player:WaitForChild("PlayerGui")

	-- visual style (Theme): dark slate well with a gold hairline and a faint inner ring,
	-- an ivory knob with a gold rim
	local P = Theme.Palette
	local r = Config.Controls.StickRadius
	base = Instance.new("Frame")
	base.Name = "StickBase"
	base.AnchorPoint = Vector2.new(0.5, 0.5)
	base.Size = UDim2.fromOffset(r * 2, r * 2)
	base.BackgroundColor3 = P.slate_900
	base.BackgroundTransparency = 0.55
	base.Visible = false
	base.Parent = gui
	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(1, 0)
	corner.Parent = base
	local stroke = Instance.new("UIStroke")
	stroke.Color = P.gold_400
	stroke.Transparency = 0.45
	stroke.Thickness = 2
	stroke.Parent = base
	local inner = Instance.new("Frame")
	inner.Name = "Ring"
	inner.AnchorPoint = Vector2.new(0.5, 0.5)
	inner.Position = UDim2.fromScale(0.5, 0.5)
	inner.Size = UDim2.fromScale(0.62, 0.62)
	inner.BackgroundTransparency = 1
	inner.Parent = base
	local ic = Instance.new("UICorner")
	ic.CornerRadius = UDim.new(1, 0)
	ic.Parent = inner
	local is = Instance.new("UIStroke")
	is.Color = P.ivory_300
	is.Transparency = 0.8
	is.Thickness = 1
	is.Parent = inner
	local scale = Instance.new("UIScale")
	scale.Parent = base

	knob = Instance.new("Frame")
	knob.Name = "Knob"
	knob.AnchorPoint = Vector2.new(0.5, 0.5)
	knob.Position = UDim2.fromScale(0.5, 0.5)
	knob.Size = UDim2.fromOffset(r * 0.86, r * 0.86)
	knob.BackgroundColor3 = Color3.new(1, 1, 1)
	knob.BackgroundTransparency = 0.12
	knob.Parent = base
	local kc = Instance.new("UICorner")
	kc.CornerRadius = UDim.new(1, 0)
	kc.Parent = knob
	local kg = Instance.new("UIGradient")
	kg.Rotation = 90
	kg.Color = ColorSequence.new(P.ivory_100, P.ivory_400)
	kg.Parent = knob
	local ks = Instance.new("UIStroke")
	ks.Color = P.gold_500
	ks.Thickness = 2
	ks.Parent = knob

	-- keep the stick graphic scaled like the rest of the UI
	RunService.RenderStepped:Connect(function()
		scale.Scale = uiScale and uiScale.Scale or 1
	end)
end

local function moveVector(): Vector2
	if stickVector.Magnitude > 0 then
		return stickVector
	end
	if gamepadVector.Magnitude > Config.Controls.DeadZone then
		return Vector2.new(gamepadVector.X, -gamepadVector.Y)
	end
	local v = Vector2.zero
	if keys[Enum.KeyCode.W] or keys[Enum.KeyCode.Up] then
		v += Vector2.new(0, -1)
	end
	if keys[Enum.KeyCode.S] or keys[Enum.KeyCode.Down] then
		v += Vector2.new(0, 1)
	end
	if keys[Enum.KeyCode.A] or keys[Enum.KeyCode.Left] then
		v += Vector2.new(-1, 0)
	end
	if keys[Enum.KeyCode.D] or keys[Enum.KeyCode.Right] then
		v += Vector2.new(1, 0)
	end
	if v.Magnitude > 1 then
		v = v.Unit
	end
	return v
end

function MobileControls.Init()
	buildGui()

	-- Try to switch off the default control module too (belt and braces).
	task.spawn(function()
		local ok, playerModule = pcall(function()
			return require(player:WaitForChild("PlayerScripts"):WaitForChild("PlayerModule", 10) :: ModuleScript) :: any
		end)
		if ok and playerModule then
			pcall(function()
				playerModule:GetControls():Disable()
			end)
		end
	end)

	UserInputService.InputBegan:Connect(function(input, processed)
		if input.UserInputType == Enum.UserInputType.Touch then
			if processed or stickInput or not enabled then
				return
			end
			local viewport = workspace.CurrentCamera.ViewportSize
			if input.Position.X > viewport.X * Config.Controls.TouchZone then
				return
			end
			stickInput = input
			stickOrigin = Vector2.new(input.Position.X, input.Position.Y)
			base.Visible = true
			updateStick(stickOrigin)
		elseif input.UserInputType == Enum.UserInputType.Keyboard then
			if not processed then
				keys[input.KeyCode] = true
			end
		end
	end)

	UserInputService.InputChanged:Connect(function(input)
		if input == stickInput then
			updateStick(Vector2.new(input.Position.X, input.Position.Y))
		elseif input.UserInputType == Enum.UserInputType.Gamepad1 and input.KeyCode == Enum.KeyCode.Thumbstick1 then
			gamepadVector = Vector2.new(input.Position.X, input.Position.Y)
		end
	end)

	UserInputService.InputEnded:Connect(function(input)
		if input == stickInput then
			stickInput = nil
			stickVector = Vector2.zero
			base.Visible = false
		elseif input.UserInputType == Enum.UserInputType.Keyboard then
			keys[input.KeyCode] = nil
		end
	end)

	UserInputService.WindowFocusReleased:Connect(function()
		table.clear(keys)
	end)

	RunService:BindToRenderStep("SwarmMove", Enum.RenderPriority.Input.Value + 1, function()
		local char = player.Character
		local hum = char and char:FindFirstChildOfClass("Humanoid")
		if not hum then
			return
		end
		local v = enabled and moveVector() or Vector2.zero
		local forward, right = CameraController.GroundAxes()
		local world = right * v.X + forward * -v.Y
		hum:Move(world, false)
	end)
end

return MobileControls
