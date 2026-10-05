--[[
	PhotoMode.lua (client; feature 29, Config.Features.PhotoMode, docs/features/LOBBY.md)
	PHOTO on the results screen: every other GUI hides, a posed copy of your hero stands where
	your hero is, and the camera circles it slowly. Nothing is uploaded or saved: the player
	takes the picture with the device's own screenshot.

	  controls  a slim bar at the bottom: POSE (Config.PhotoMode.Poses through HeroPoses:
	            HEROIC = the lobby stance, CHEER = HeroPoses.Shared.Cheer, RELAXED = idle),
	            ORBIT (slow turn on / off), FRAME (none / gold / crimson / frost border) and
	            EXIT. The bar fades out after HintSeconds without input (photo-ready); a tap
	            then brings it back, a tap on empty space while it shows exits. Esc / B exit.
	  safety    the hero copy is local, anchored and never collides; your real character is
	            only hidden locally (LocalTransparencyModifier, its overhead bar shrunk) and
	            comes back on exit, like every hidden ScreenGui. Leaving the run (InRun false) exits at once.

	PhotoMode.AttachButton(parent, order, onOpen?) → Button?  (UIBuilder's results footer;
	        nil while the switch is off)
	PhotoMode.Enter() / .Exit() / .IsOn()
	PhotoMode.CloneHero(characterId, skinId) → Model?  an anchored, non-colliding copy
	        (also LobbyFun's mirror)
]]

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")

local Shared = game:GetService("ReplicatedStorage"):WaitForChild("Shared")
local Config = require(Shared:WaitForChild("Config"))
local Theme = require(Shared:WaitForChild("Theme"))
local HeroPoses = require(Shared:WaitForChild("HeroPoses"))
local UIKit = require(script.Parent.UIKit)
local ViewportPreview = require(script.Parent.ViewportPreview)

local PhotoMode = {}

local player = Players.LocalPlayer
local new, text = UIKit.new, UIKit.text
local P = Theme.Palette
local PM = Config.PhotoMode

local FRAME_COLORS: { [string]: { Color3 } } = {
	Gold = { P.gold_300, P.gold_600 },
	Crimson = { P.crimson_400, P.crimson_700 },
	Frost = { P.ice_100, P.ice_300 },
}

type Session = {
	Gui: ScreenGui,
	Bar: Frame,
	Hint: TextLabel,
	Frame: Frame,
	Hidden: { ScreenGui },
	HiddenParts: { [BasePart]: number },
	HiddenBoards: { [BillboardGui]: UDim2 },
	Model: Model?,
	Feet: CFrame,
	Pose: number,
	Orbit: boolean,
	Angle: number,
	FrameStyle: number,
	LastInput: number,
	Started: number,
	Conns: { RBXScriptConnection },
	Buttons: { [string]: any },
}

local session: Session? = nil

------------------------------------------------------------------------------------------
-- The hero copy
------------------------------------------------------------------------------------------

local RIG = { "RootJoint", "Neck", "Left Shoulder", "Right Shoulder", "Left Hip", "Right Hip" }

local function rigReady(m: Model): boolean
	for _, name in ipairs(RIG) do
		local j = m:FindFirstChild(name, true)
		if not (j and j:IsA("Motor6D") and j.Part0 and j.Part1) then
			return false
		end
	end
	return m:FindFirstChild("HumanoidRootPart") ~= nil
end

-- An anchored, non-colliding local copy of the hero (own character when it matches, else
-- the server-built preview template). nil when neither is ready.
function PhotoMode.CloneHero(characterId: string, skinId: string?): Model?
	local skin = skinId or "Default"
	local source: Model? = nil
	local own = player.Character
	if own and own:GetAttribute("CharacterId") == characterId and (own:GetAttribute("SkinId") or "Default") == skin and rigReady(own) then
		source = own
	else
		local template = ViewportPreview.Template(characterId, skin)
		if template and rigReady(template) then
			source = template
		end
	end
	if not source then
		return nil
	end
	local src = source :: Model
	local was = src.Archivable
	src.Archivable = true
	local ok, result = pcall(function()
		return src:Clone()
	end)
	src.Archivable = was
	if not ok or not result then
		return nil
	end
	local m = result :: Model
	for _, d in ipairs(m:GetDescendants()) do
		if d:IsA("BaseScript") or d:IsA("Humanoid") or d:IsA("BillboardGui") or d:IsA("ProximityPrompt") or d:IsA("Sound") or d:IsA("ForceField") then
			d:Destroy()
		elseif d:IsA("BasePart") then
			d.Anchored = true
			d.CanCollide = false
			d.CanQuery = false
			d.CanTouch = false
			d.LocalTransparencyModifier = 0
		end
	end
	local root = m:FindFirstChild("HumanoidRootPart")
	if not (root and root:IsA("BasePart")) then
		m:Destroy()
		return nil
	end
	m.PrimaryPart = root
	m:SetAttribute("CharacterId", characterId)
	return m
end

-- Root height above the feet of a built hero (as Showcase measures it).
local function rootOffset(m: Model): number
	local root = m.PrimaryPart :: BasePart
	local bbCF, bbSize = m:GetBoundingBox()
	return math.clamp(root.Position.Y - (bbCF.Position.Y - bbSize.Y / 2), 2.4, 4.2)
end

-- Where the hero's feet are now (on the floor under the character), facing the camera.
local function feetCFrame(): CFrame
	local cam = workspace.CurrentCamera
	local char = player.Character
	local root = char and char:FindFirstChild("HumanoidRootPart") :: BasePart?
	local at = root and root.Position or (cam.Focus.Position)
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.FilterDescendantsInstances = { char or workspace.CurrentCamera }
	local hit = workspace:Raycast(at + Vector3.new(0, 2, 0), Vector3.new(0, -12, 0), params)
	local feet = hit and hit.Position or (at - Vector3.new(0, 3, 0))
	local look = cam.CFrame.Position - feet
	look = Vector3.new(look.X, 0, look.Z)
	if look.Magnitude < 0.1 then
		look = Vector3.new(0, 0, 1)
	end
	return CFrame.lookAt(feet, feet + look.Unit)
end

------------------------------------------------------------------------------------------
-- Session
------------------------------------------------------------------------------------------

local function setBarShown(s: Session, on: boolean)
	s.Bar.Visible = on
	s.Hint.Visible = on
end

local function applyFrame(s: Session)
	local style = PM.Frames[s.FrameStyle] or "None"
	local colors = FRAME_COLORS[style]
	s.Frame.Visible = colors ~= nil
	if colors then
		local outer = s.Frame:FindFirstChild("Outer") :: Frame
		local inner = s.Frame:FindFirstChild("Inner") :: Frame
		(outer:FindFirstChildOfClass("UIStroke") :: UIStroke).Color = colors[1];
		(inner:FindFirstChildOfClass("UIStroke") :: UIStroke).Color = colors[2]
		for _, gem in ipairs(s.Frame:GetChildren()) do
			if gem.Name == "Gem" and gem:IsA("Frame") then
				gem.BackgroundColor3 = colors[1]
			end
		end
	end
	s.Buttons.Frame.SetText("FRAME: " .. string.upper(style))
end

local function applyPose(s: Session)
	local name = PM.Poses[s.Pose] or "Showcase"
	s.Buttons.Pose.SetText("POSE: " .. (PM.PoseNames[name] or string.upper(name)))
end

local function bump(s: Session)
	s.LastInput = os.clock()
	setBarShown(s, true)
end

local function buildGui(s: Session)
	local playerGui = player:WaitForChild("PlayerGui")
	local g = new("ScreenGui", { Name = "PhotoMode", ResetOnSpawn = false, IgnoreGuiInset = true, DisplayOrder = 60, Enabled = true }, playerGui) :: ScreenGui
	s.Gui = g
	-- the whole screen: a tap on empty space exits (or wakes the faded bar)
	local catcher = new("TextButton", { Name = "TapToExit", Text = "", AutoButtonColor = false, BackgroundTransparency = 1, Size = UDim2.fromScale(1, 1) }, g)
	table.insert(s.Conns, catcher.Activated:Connect(function()
		if not s.Bar.Visible then
			bump(s)
		else
			PhotoMode.Exit()
		end
	end))
	-- frame overlay (two borders + four corner gems), off by default
	local frame = new("Frame", { Name = "Frame", BackgroundTransparency = 1, Size = UDim2.fromScale(1, 1), Visible = false }, g)
	s.Frame = frame
	local outer = new("Frame", { Name = "Outer", BackgroundTransparency = 1, Position = UDim2.fromOffset(14, 14), Size = UDim2.new(1, -28, 1, -28) }, frame)
	UIKit.stroke(outer, P.gold_300, 6, 0)
	UIKit.corner(outer, 8)
	local inner = new("Frame", { Name = "Inner", BackgroundTransparency = 1, Position = UDim2.fromOffset(26, 26), Size = UDim2.new(1, -52, 1, -52) }, frame)
	UIKit.stroke(inner, P.gold_600, 2, 0.1)
	UIKit.corner(inner, 6)
	for _, c in ipairs({ { 0, 0 }, { 1, 0 }, { 0, 1 }, { 1, 1 } }) do
		local gem = new("Frame", { Name = "Gem", AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.new(c[1], c[1] == 0 and 17 or -17, c[2], c[2] == 0 and 17 or -17), Size = UDim2.fromOffset(16, 16), Rotation = 45, BackgroundColor3 = P.gold_300, BorderSizePixel = 0 }, frame)
		UIKit.stroke(gem, P.slate_950, 1.5, 0.2)
	end
	-- control bar
	local bar = new("Frame", { Name = "Bar", BackgroundTransparency = 1, AnchorPoint = Vector2.new(0.5, 1), Position = UDim2.new(0.5, 0, 1, -18), Size = UDim2.new(1, -24, 0, 44) }, g)
	s.Bar = bar
	UIKit.list(bar, { FillDirection = Enum.FillDirection.Horizontal, HorizontalAlignment = Enum.HorizontalAlignment.Center, VerticalAlignment = Enum.VerticalAlignment.Center, Padding = UDim.new(0, 8), Wraps = true })
	local function button(name: string, title: string, order: number, w: number, fn: () -> ())
		local b = UIKit.Button(bar, { Kind = name == "Exit" and "Primary" or "Secondary", Title = title, Name = name, Align = "Center", Shadow = false, Shrink = true, Size = UDim2.fromOffset(w, 44), LayoutOrder = order, OnClick = function()
			bump(s)
			fn()
		end })
		s.Buttons[name] = b
		return b
	end
	button("Pose", "POSE", 1, 150, function()
		s.Pose = s.Pose % #PM.Poses + 1
		applyPose(s)
	end)
	button("Orbit", "ORBIT", 2, 96, function()
		s.Orbit = not s.Orbit
		s.Buttons.Orbit.SetSelected(s.Orbit)
	end)
	button("Frame", "FRAME", 3, 150, function()
		s.FrameStyle = s.FrameStyle % #PM.Frames + 1
		applyFrame(s)
	end)
	button("Exit", "EXIT", 4, 90, function()
		PhotoMode.Exit()
	end)
	s.Hint = text(g, "Small", "Buttons fade for your screenshot. Tap empty space to exit.", { Name = "Hint", AnchorPoint = Vector2.new(0.5, 1), Position = UDim2.new(0.5, 0, 1, -68), Size = UDim2.new(1, -24, 0, 18), TextXAlignment = Enum.TextXAlignment.Center, TextColor3 = P.ivory_100, TextStrokeTransparency = 0.4 }, 12)
	-- narrow phones: smaller buttons so the bar keeps one row
	local function fit()
		local w = g.AbsoluteSize.X
		local narrow = w > 0 and w < 520
		s.Buttons.Pose.Instance.Size = UDim2.fromOffset(narrow and 120 or 150, 44)
		s.Buttons.Frame.Instance.Size = UDim2.fromOffset(narrow and 120 or 150, 44)
		s.Buttons.Orbit.Instance.Size = UDim2.fromOffset(narrow and 76 or 96, 44)
		s.Buttons.Exit.Instance.Size = UDim2.fromOffset(narrow and 64 or 90, 44)
	end
	table.insert(s.Conns, g:GetPropertyChangedSignal("AbsoluteSize"):Connect(fit))
	fit()
end

function PhotoMode.IsOn(): boolean
	return session ~= nil
end

function PhotoMode.Enter()
	if session or not Config.FeatureOn("PhotoMode") then
		return
	end
	local s: Session = {
		Gui = nil :: any,
		Bar = nil :: any,
		Hint = nil :: any,
		Frame = nil :: any,
		Hidden = {},
		HiddenParts = {},
		HiddenBoards = {},
		Model = nil,
		Feet = feetCFrame(),
		Pose = 1,
		Orbit = true,
		Angle = 0,
		FrameStyle = 1,
		LastInput = os.clock(),
		Started = os.clock(),
		Conns = {},
		Buttons = {},
	}
	session = s
	-- hide every other GUI (restored on exit)
	local playerGui = player:FindFirstChild("PlayerGui")
	if playerGui then
		for _, g in ipairs(playerGui:GetChildren()) do
			if g:IsA("ScreenGui") and g.Enabled then
				g.Enabled = false
				table.insert(s.Hidden, g)
			end
		end
	end
	buildGui(s)
	-- the posed copy where the hero stands; the real character hides locally
	local char = player.Character
	local characterId = char and char:GetAttribute("CharacterId")
	local skinId = char and char:GetAttribute("SkinId")
	local m = PhotoMode.CloneHero(type(characterId) == "string" and characterId or "Knight", type(skinId) == "string" and skinId or "Default")
	if m then
		m.Name = "PhotoHero"
		m:PivotTo(s.Feet * CFrame.new(0, rootOffset(m), 0))
		m.Parent = workspace
		s.Model = m
		if char then
			for _, d in ipairs(char:GetDescendants()) do
				if d:IsA("BasePart") then
					s.HiddenParts[d] = d.LocalTransparencyModifier
					d.LocalTransparencyModifier = 1
				end
			end
			-- its overhead bar / plates (VFX writes only their Enabled, so they shrink to nothing)
			for _, d in ipairs(workspace:GetDescendants()) do
				if d:IsA("BillboardGui") and ((d.Adornee and d.Adornee:IsDescendantOf(char)) or d:IsDescendantOf(char)) then
					s.HiddenBoards[d] = d.Size
					d.Size = UDim2.new()
				end
			end
		end
	end
	applyPose(s)
	applyFrame(s)
	s.Buttons.Orbit.SetSelected(true)
	table.insert(s.Conns, player:GetAttributeChangedSignal("InRun"):Connect(function()
		PhotoMode.Exit()
	end))
	table.insert(s.Conns, UserInputService.InputBegan:Connect(function(input, processed)
		if input.KeyCode == Enum.KeyCode.Escape or input.KeyCode == Enum.KeyCode.ButtonB then
			PhotoMode.Exit()
		elseif not processed and (input.UserInputType == Enum.UserInputType.Keyboard or input.UserInputType == Enum.UserInputType.Gamepad1) then
			bump(s)
		end
	end))
	RunService:BindToRenderStep("SwarmPhoto", Enum.RenderPriority.Camera.Value + 5, function(dt)
		local cur = session
		if not cur then
			return
		end
		local now = os.clock()
		if cur.Orbit then
			cur.Angle += math.rad(PM.OrbitSpeed) * dt
		end
		if cur.Model and cur.Model.Parent then
			HeroPoses.Apply(cur.Model, PM.Poses[cur.Pose] or "Showcase", now - cur.Started)
		end
		local feet = cur.Feet
		local aim = feet.Position + Vector3.new(0, PM.AimHeight, 0)
		local offset = (feet * CFrame.Angles(0, cur.Angle, 0)).LookVector * PM.Distance + Vector3.new(0, PM.Height, 0)
		local cam = workspace.CurrentCamera
		cam.FieldOfView = PM.FieldOfView
		cam.CFrame = CFrame.lookAt(feet.Position + offset, aim)
		cam.Focus = CFrame.new(aim)
		if cur.Bar.Visible and now - cur.LastInput > PM.HintSeconds then
			setBarShown(cur, false)
		end
	end)
end

function PhotoMode.Exit()
	local s = session
	if not s then
		return
	end
	session = nil
	pcall(function()
		RunService:UnbindFromRenderStep("SwarmPhoto")
	end)
	for _, c in ipairs(s.Conns) do
		c:Disconnect()
	end
	if s.Model then
		s.Model:Destroy()
	end
	for part, ltm in pairs(s.HiddenParts) do
		if part.Parent then
			part.LocalTransparencyModifier = ltm
		end
	end
	for board, size in pairs(s.HiddenBoards) do
		if board.Parent then
			board.Size = size
		end
	end
	for _, g in ipairs(s.Hidden) do
		if g.Parent then
			g.Enabled = true
		end
	end
	if s.Gui then
		s.Gui:Destroy()
	end
end

-- The PHOTO button for the results footer (nil while the switch is off).
function PhotoMode.AttachButton(parent: Instance, order: number, onOpen: (() -> ())?): any
	if not Config.FeatureOn("PhotoMode") then
		return nil
	end
	local b = UIKit.Button(parent, {
		Kind = "Secondary",
		Title = "PHOTO",
		Icon = "sparkle",
		IconSize = 16,
		Name = "Photo",
		Align = "Center",
		Shadow = false,
		Size = UDim2.fromOffset(112, 44),
		LayoutOrder = order,
		OnClick = function()
			if onOpen then
				onOpen()
			end
			PhotoMode.Enter()
		end,
	})
	-- follow the footer's height (36 on slim phones, 44 otherwise)
	if parent:IsA("GuiObject") then
		local function fit()
			local h = (parent :: GuiObject).Size.Y.Offset
			b.Instance.Size = UDim2.fromOffset(UIKit.TS(12) * 5 + 50, h > 0 and h or 44)
		end
		parent:GetPropertyChangedSignal("Size"):Connect(fit)
		fit()
	end
	return b
end

return PhotoMode
