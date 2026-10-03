--[[
	MobileControls.lua
	Movement only: a floating virtual thumbstick (appears wherever the thumb lands),
	WASD / arrow keys and a gamepad left stick, plus a JUMP button for touch screens
	(bottom right, clear of the inventory bar; the jump itself is JumpController.lua).
	No attack buttons.

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
local ClientSettings = require(script.Parent.ClientSettings)

local MobileControls = {}

-- Optional move input filter (TerrainFx: slippery steering on ice), world dir in and out.
MobileControls.Filter = nil :: ((Vector3, number) -> Vector3)?
-- Air control filter (JumpController), applied after Filter.
MobileControls.AirFilter = nil :: ((Vector3, number) -> Vector3)?
-- Called when the touch JUMP button is pressed (JumpController.Request).
MobileControls.OnJump = nil :: (() -> ())?

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
local jumpButton: TextButton? = nil
local jumpUsable: boolean? = nil
local relayout: (() -> ())? = nil -- re-applies scale and side (set by buildGui)

-- Lets other UI stop movement (level-up screen, panels, results).
function MobileControls.SetEnabled(on: boolean)
	enabled = on
	if not on then
		stickInput = nil
		stickVector = Vector2.zero
		base.Visible = false
	end
end

function MobileControls.IsEnabled(): boolean
	return enabled
end

-- JumpController sets this every frame: shown during a run on touch screens (hidden while
-- a panel disabled the controls), dimmed while a jump is not allowed (frozen, paused).
function MobileControls.SetJumpButton(show: boolean, usable: boolean)
	local b = jumpButton
	if not b then
		return
	end
	local visible = show and enabled and UserInputService.TouchEnabled
	if b.Visible ~= visible then
		b.Visible = visible
	end
	if jumpUsable ~= usable then
		jumpUsable = usable
		b.BackgroundTransparency = usable and 0.15 or 0.6
		b.TextTransparency = usable and 0 or 0.5
	end
end

function MobileControls.SetScale(scale: UIScale)
	uiScale = scale
	if relayout then
		relayout()
	end
end

local function radiusPixels(): number
	local s = uiScale and uiScale.Scale or 1
	return Config.Controls.StickRadius * s * (ClientSettings.Get("TouchLayout") == "Compact" and 0.8 or 1)
end

function MobileControls.MovementSide(x: number, width: number): boolean
	local left = ClientSettings.Get("TouchLayout") == "LeftHanded"
	local zone = math.min(Config.Controls.TouchZone, 0.5)
	return left and x >= width * (1 - zone)
		or not left and x <= width * zone
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
	local scale = (uiScale and uiScale.Scale or 1) * (ClientSettings.Get("TouchLayout") == "Compact" and 0.8 or 1)
	knob.Position = UDim2.new(0.5, delta.X / scale, 0.5, delta.Y / scale)
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

	-- JUMP button (touch): bottom right, inside the safe area, thumb sized; it sinks its
	-- touches so they never start the stick
	local M = Config.Movement
	local jump = Instance.new("TextButton")
	jump.Name = "JumpButton"
	jump.AnchorPoint = Vector2.new(1, 1)
	jump.Position = UDim2.new(1, -M.ButtonMargin, 1, -M.ButtonMargin)
	jump.Size = UDim2.fromOffset(M.ButtonSize, M.ButtonSize)
	jump.BackgroundColor3 = P.slate_900
	jump.BackgroundTransparency = 0.15
	jump.AutoButtonColor = false
	jump.Text = "JUMP"
	jump.TextColor3 = P.ivory_100
	jump.TextScaled = false
	jump.TextSize = 20
	jump.FontFace = Theme.Font.Label
	jump.Visible = false
	jump.Parent = gui
	local jc = Instance.new("UICorner")
	jc.CornerRadius = UDim.new(1, 0)
	jc.Parent = jump
	local js = Instance.new("UIStroke")
	js.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
	js.Color = P.gold_400
	js.Thickness = 2.5
	js.Parent = jump
	local jumpScale = Instance.new("UIScale")
	jumpScale.Parent = jump
	jump.InputBegan:Connect(function(input)
		if input.UserInputType == Enum.UserInputType.Touch or input.UserInputType == Enum.UserInputType.MouseButton1 then
			local cb = MobileControls.OnJump
			if cb then
				cb()
			end
			js.Thickness = 4
		end
	end)
	jump.InputEnded:Connect(function(input)
		if input.UserInputType == Enum.UserInputType.Touch or input.UserInputType == Enum.UserInputType.MouseButton1 then
			js.Thickness = 2.5
		end
	end)
	jumpButton = jump

	-- keep the stick graphic and the JUMP button scaled like the rest of the UI and on the
	-- side the touch layout asks for; event-driven (UI scale / setting changes), not per frame
	local watchedScale: UIScale? = nil
	local scaleConn: RBXScriptConnection? = nil
	local function layout()
		local base = uiScale and uiScale.Scale or 1
		local compact = ClientSettings.Get("TouchLayout") == "Compact" and 0.8 or 1
		scale.Scale = base * compact
		jumpScale.Scale = base * compact
		local left = ClientSettings.Get("TouchLayout") == "LeftHanded"
		jump.AnchorPoint = Vector2.new(left and 0 or 1, 1)
		jump.Position = UDim2.new(left and 0 or 1, left and M.ButtonMargin or -M.ButtonMargin, 1, -M.ButtonMargin)
		if uiScale ~= watchedScale then
			if scaleConn then
				scaleConn:Disconnect()
				scaleConn = nil
			end
			watchedScale = uiScale
			if uiScale then
				scaleConn = uiScale:GetPropertyChangedSignal("Scale"):Connect(layout)
			end
		end
	end
	relayout = layout
	layout()
	ClientSettings.OnChanged(function(key)
		if key == "TouchLayout" then
			layout()
		end
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
	ClientSettings.OnChanged(function(key)
		if key == "TouchLayout" then
			stickInput = nil
			stickVector = Vector2.zero
			base.Visible = false
		end
	end)
	pcall(function()
		require(script.Parent:WaitForChild("TerrainFx") :: ModuleScript).Init(MobileControls)
	end)
	pcall(function()
		require(script.Parent:WaitForChild("JumpController") :: ModuleScript).Init(MobileControls)
	end)

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
			if not MobileControls.MovementSide(input.Position.X, viewport.X) then
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
		stickInput = nil
		stickVector = Vector2.zero
		gamepadVector = Vector2.zero
		base.Visible = false
	end)

	RunService:BindToRenderStep("SwarmMove", Enum.RenderPriority.Input.Value + 1, function(dt: number)
		local char = player.Character
		local hum = char and char:FindFirstChildOfClass("Humanoid")
		if not hum then
			return
		end
		local v = enabled and moveVector() or Vector2.zero
		local forward, right = CameraController.GroundAxes()
		local world = right * v.X + forward * -v.Y
		local filter = MobileControls.Filter
		if filter then
			world = filter(world, dt)
		end
		local air = MobileControls.AirFilter
		if air then
			world = air(world, dt)
		end
		hum:Move(world, false)
	end)
end

return MobileControls
