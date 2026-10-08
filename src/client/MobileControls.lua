--[[
	MobileControls.lua
	Movement only: a floating virtual thumbstick (touch-down in the left 45% of the screen
	spawns it, Config.Controls.TouchZone; the rest of the screen orbits the camera,
	CameraController), WASD / arrow keys and a gamepad left stick, plus a JUMP button and a
	DASH button (with a radial cooldown ring) for touch screens. JUMP is bottom right, DASH
	above-left of it. The jump itself is JumpController.lua, the dash DashClient.lua.
	No attack buttons.

	The default Roblox control scripts are disabled (StarterPlayer movement modes are
	"Scriptable" in default.project.json); this module calls Humanoid:Move every frame
	with a direction relative to the camera (CameraController.GroundAxes).
]]

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")

local Config = require(game:GetService("ReplicatedStorage"):WaitForChild("Shared"):WaitForChild("Config"))
local Theme = require(game:GetService("ReplicatedStorage"):WaitForChild("Shared"):WaitForChild("Theme"))
local CameraController = require(script.Parent.CameraController)
local ClientSettings = require(script.Parent.ClientSettings)
local Icons = require(script.Parent.Icons)
local UIKit = require(script.Parent.UIKit)

local MobileControls = {}

-- Optional move input filter (TerrainFx: slippery steering on ice), world dir in and out.
MobileControls.Filter = nil :: ((Vector3, number) -> Vector3)?
-- Air control filter (JumpController), applied after Filter.
MobileControls.AirFilter = nil :: ((Vector3, number) -> Vector3)?
-- Called when the touch JUMP button is pressed (JumpController.Request).
MobileControls.OnJump = nil :: (() -> ())?
-- Called when the touch DASH button is pressed (DashClient).
MobileControls.OnDash = nil :: (() -> ())?
-- While set, the hero is moved along this world direction instead of the stick (a dash).
MobileControls.MoveOverride = nil :: Vector3?

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
local jumpLabel: TextLabel? = nil
local jumpArrow: CanvasGroup? = nil
local jumpFace: Frame? = nil
local jumpBaseFrame: Frame? = nil
local jumpUsable: boolean? = nil
local relayout: (() -> ())? = nil -- re-applies scale and side (set by buildGui)

type RoundButton = {
	Button: TextButton,
	Face: Frame,
	FaceStroke: UIStroke,
	Base: Frame,
	Arrow: CanvasGroup,
	Label: TextLabel,
	Scale: UIScale,
}
local dashButton: RoundButton? = nil
local dashUsable: boolean? = nil
local ringRight: UIGradient? = nil
local ringLeft: UIGradient? = nil
local ringStrokes: { UIStroke } = {}
local dashSeconds: TextLabel? = nil

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
		if jumpFace then
			jumpFace.BackgroundTransparency = usable and 0 or 0.5
		end
		if jumpBaseFrame then
			jumpBaseFrame.BackgroundTransparency = usable and 0 or 0.6
		end
		if jumpLabel then
			jumpLabel.TextTransparency = usable and 0 or 0.5
		end
		if jumpArrow then
			jumpArrow.GroupTransparency = usable and 0 or 0.5
		end
	end
end

-- DashClient sets this every frame: shown during a run on touch screens, dimmed while a dash
-- is not allowed. `ready` is the cooldown progress 0..1 (1 = ready), `secondsLeft` the wait.
function MobileControls.SetDashButton(show: boolean, usable: boolean, ready: number, secondsLeft: number)
	local d = dashButton
	if not d then
		return
	end
	local visible = show and enabled and UserInputService.TouchEnabled
	if d.Button.Visible ~= visible then
		d.Button.Visible = visible
	end
	if not visible then
		return
	end
	if dashUsable ~= usable then
		dashUsable = usable
		d.Face.BackgroundTransparency = usable and 0 or 0.5
		d.Base.BackgroundTransparency = usable and 0 or 0.6
		d.Label.TextTransparency = usable and 0 or 0.5
		d.Arrow.GroupTransparency = usable and 0 or 0.5
	end
	-- radial ring: the right half fills over the first half of the cooldown, the left half after
	local p = math.clamp(ready, 0, 1)
	if ringRight and ringLeft then
		ringRight.Rotation = math.clamp(p * 360, 0, 180)
		ringLeft.Rotation = 180 + math.clamp(p * 360 - 180, 0, 180)
	end
	local C = Theme.Color :: any
	local ringColor = if p >= 1 then (C.Selected or Color3.fromRGB(150, 230, 60)) else C.Blue
	for _, st in ipairs(ringStrokes) do
		st.Color = ringColor
	end
	if dashSeconds then
		dashSeconds.Text = if secondsLeft > 0.05 then string.format("%.1f", secondsLeft) else ""
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

	-- visual style (Bright Arcade): a light translucent well with a blue rim and a faint inner
	-- ring, a white knob with a blue rim
	local C = Theme.Color
	local r = Config.Controls.StickRadius
	base = Instance.new("Frame")
	base.Name = "StickBase"
	base.AnchorPoint = Vector2.new(0.5, 0.5)
	base.Size = UDim2.fromOffset(r * 2, r * 2)
	base.BackgroundColor3 = C.Panel
	base.BackgroundTransparency = 0.72
	base.Visible = false
	base.Parent = gui
	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(1, 0)
	corner.Parent = base
	local stroke = Instance.new("UIStroke")
	stroke.Color = C.Blue
	stroke.Transparency = 0.2
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
	is.Color = C.Panel
	is.Transparency = 0.35
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
	kg.Color = ColorSequence.new(C.Panel, C.BluePale)
	kg.Parent = knob
	local ks = Instance.new("UIStroke")
	ks.Color = C.Blue
	ks.Thickness = 2
	ks.Parent = knob

	-- Round action buttons (touch): JUMP bottom right, DASH above-left of it; inside the safe area,
	-- thumb sized. They sink their touches so they never start the stick or the camera drag.
	local M = Config.Movement
	local function roundButton(name: string, text: string, size: number, onPress: () -> ()): RoundButton
		local btn = Instance.new("TextButton")
		btn.Name = name
		btn.AnchorPoint = Vector2.new(1, 1)
		btn.Size = UDim2.fromOffset(size, size)
		btn.BackgroundTransparency = 1
		btn.AutoButtonColor = false
		btn.Text = ""
		btn.Visible = false
		btn.Parent = gui
		-- Bright Arcade: a raised round face (gradient, white rim, top highlight) on a dark-blue
		-- base; the TextButton itself stays the (unchanged) hit area
		local gradient = if name == "DashButton" then Theme.Gradient.Primary else Theme.Gradient.Blue
		local onColor = if name == "DashButton" then C.TextOnGold else C.TextOnBlue
		local f, _, fs, fb = UIKit.RoundFace(btn, gradient, C.Panel, 3, 5)
		fs.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
		UIKit.Highlight(f, 40, 0.55)
		-- an arrow over the word: reads as the action without reading
		local ar = Instance.new("CanvasGroup")
		ar.Name = "Arrow"
		ar.BackgroundTransparency = 1
		ar.AnchorPoint = Vector2.new(0.5, 0.5)
		ar.Position = UDim2.fromScale(0.5, 0.36)
		ar.Size = UDim2.fromOffset(30, 30)
		ar.ZIndex = 3
		ar.Parent = f
		Icons.Draw(ar, if name == "DashButton" then "arrowFast" else "chevronsUp", {
			Size = 30, Color = onColor, Back = if name == "DashButton" then C.Primary else C.Blue,
			Position = UDim2.fromScale(0.5, 0.5), AnchorPoint = Vector2.new(0.5, 0.5),
		})
		local w = Instance.new("TextLabel")
		w.Name = "Label"
		w.BackgroundTransparency = 1
		w.AnchorPoint = Vector2.new(0.5, 0)
		w.Position = UDim2.fromScale(0.5, 0.58)
		w.Size = UDim2.new(0.8, 0, 0, 20)
		w.Text = text
		w.TextColor3 = onColor
		w.TextSize = 17
		w.FontFace = Theme.Font.Number
		w.ZIndex = 3
		w:SetAttribute("NoTextFit", true)
		w.Parent = f
		local cap = Instance.new("UITextSizeConstraint") -- the Roblox Text size setting must not push it out
		cap.MaxTextSize = 17
		cap.Parent = w
		local sc = Instance.new("UIScale")
		sc.Parent = btn
		btn.InputBegan:Connect(function(input)
			if input.UserInputType == Enum.UserInputType.Touch or input.UserInputType == Enum.UserInputType.MouseButton1 then
				onPress()
				fs.Thickness = 5
				f.Position = UDim2.fromOffset(0, 3) -- presses down onto its base
			end
		end)
		btn.InputEnded:Connect(function(input)
			if input.UserInputType == Enum.UserInputType.Touch or input.UserInputType == Enum.UserInputType.MouseButton1 then
				fs.Thickness = 3
				f.Position = UDim2.new()
			end
		end)
		return { Button = btn, Face = f, FaceStroke = fs, Base = fb, Arrow = ar, Label = w, Scale = sc }
	end

	local jumpRb = roundButton("JumpButton", "JUMP", M.ButtonSize, function()
		local cb = MobileControls.OnJump
		if cb then
			cb()
		end
	end)
	local jump, jumpScale = jumpRb.Button, jumpRb.Scale
	jumpFace, jumpBaseFrame, jumpArrow, jumpLabel = jumpRb.Face, jumpRb.Base, jumpRb.Arrow, jumpRb.Label
	jumpButton = jump

	local dashRb = roundButton("DashButton", "DASH", M.DashButtonSize, function()
		local cb = MobileControls.OnDash
		if cb then
			cb()
		end
	end)
	local dash, dashScale = dashRb.Button, dashRb.Scale
	dashButton = dashRb
	-- the radial cooldown ring: two clipped halves, each a full circle outline with a hard-edged
	-- gradient that DashClient rotates through SetDashButton
	local ring = Instance.new("Frame")
	ring.Name = "CooldownRing"
	ring.BackgroundTransparency = 1
	ring.AnchorPoint = Vector2.new(0.5, 0.5)
	ring.Position = UDim2.fromScale(0.5, 0.5)
	ring.Size = UDim2.new(1, 12, 1, 12)
	ring.ZIndex = 6
	ring.Parent = dash
	for i = 1, 2 do
		local half = Instance.new("Frame")
		half.Name = if i == 1 then "RightHalf" else "LeftHalf"
		half.BackgroundTransparency = 1
		half.ClipsDescendants = true
		half.Size = UDim2.fromScale(0.5, 1)
		half.Position = UDim2.fromScale(if i == 1 then 0.5 else 0, 0)
		half.ZIndex = 6
		half.Parent = ring
		local circle = Instance.new("Frame")
		circle.Name = "Circle"
		circle.BackgroundTransparency = 1
		circle.Size = UDim2.fromScale(2, 1)
		circle.Position = UDim2.fromScale(if i == 1 then -1 else 0, 0)
		circle.ZIndex = 6
		circle.Parent = half
		local cc = Instance.new("UICorner")
		cc.CornerRadius = UDim.new(1, 0)
		cc.Parent = circle
		local st = Instance.new("UIStroke")
		st.Thickness = 5
		st.Color = C.Blue
		st.Parent = circle
		local g = Instance.new("UIGradient")
		g.Transparency = NumberSequence.new({
			NumberSequenceKeypoint.new(0, 0),
			NumberSequenceKeypoint.new(0.499, 0),
			NumberSequenceKeypoint.new(0.5, 1),
			NumberSequenceKeypoint.new(1, 1),
		})
		g.Rotation = if i == 1 then 0 else 180
		g.Parent = st
		table.insert(ringStrokes, st)
		if i == 1 then
			ringRight = g
		else
			ringLeft = g
		end
	end
	local secs = Instance.new("TextLabel")
	secs.Name = "Seconds"
	secs.BackgroundTransparency = 1
	secs.AnchorPoint = Vector2.new(0.5, 0.5)
	secs.Position = UDim2.fromScale(0.5, 0.5)
	secs.Size = UDim2.fromOffset(40, 24)
	secs.Text = ""
	secs.TextSize = 20
	secs.FontFace = Theme.Font.Number
	secs.TextColor3 = C.TextOnGold
	secs.TextStrokeTransparency = 0.4
	secs.TextStrokeColor3 = Color3.new(1, 1, 1)
	secs.ZIndex = 8
	secs:SetAttribute("NoTextFit", true)
	secs.Parent = dash
	dashSeconds = secs

	-- keep the stick graphic and the JUMP button scaled like the rest of the UI and on the
	-- side the touch layout asks for; event-driven (UI scale / setting changes), not per frame
	local watchedScale: UIScale? = nil
	local scaleConn: RBXScriptConnection? = nil
	local function layout()
		local base = uiScale and uiScale.Scale or 1
		local compact = ClientSettings.Get("TouchLayout") == "Compact" and 0.8 or 1
		scale.Scale = base * compact
		jumpScale.Scale = base * compact
		dashScale.Scale = base * compact
		local left = ClientSettings.Get("TouchLayout") == "LeftHanded"
		local side = left and 0 or 1
		local sign = left and 1 or -1
		jump.AnchorPoint = Vector2.new(side, 1)
		jump.Position = UDim2.new(side, sign * M.ButtonMargin, 1, -M.ButtonMargin)
		-- DASH: above-left of JUMP (above-right when left handed), clear of it and of the ULT slot
		local dashSize = M.DashButtonSize
		dash.AnchorPoint = Vector2.new(side, 1)
		dash.Position = UDim2.new(side, sign * (M.ButtonMargin + M.ButtonSize + 10), 1, -(M.ButtonMargin + M.ButtonSize * 0.55))
		dash.Size = UDim2.fromOffset(dashSize, dashSize)
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
		local override = MobileControls.MoveOverride
		if override then
			-- a dash moves the hero along its own direction, whatever the stick says
			hum:Move(override, false)
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
