--!strict
--[[
	SwarmV2/Run/ReviveHoldClient.lua  (StarterPlayerScripts.SwarmV2Client.Run.ReviveHoldClient)
	OWNER: gameplay track, stream E1 (survival rules). Minimal input binding for hold-to-revive;
	the run UI (stream F) owns the prompts, rings and downed / spectate screens.

	While a downed teammate (Player attribute Downed) is within RunConfig.Survival.Downed.ReviveRange
	(plus a little slack: the server measures for real) of the local hero:
	  * holding E (keyboard), gamepad X (the existing interact button) or the touch REVIVE button
	    sends ReplicatedStorage.Remotes.ReviveHold(true), repeated every HoldRefresh seconds while
	    held; letting go (or losing the target, or the window losing focus) sends ReviveHold(false).
	  * The server decides everything else (range, the 3 uninterrupted seconds, cancels).
	Holding revive wins over an incidental chest: LootUI's E / X hold asks TeamUI.CanRevive, which
	reads HasTarget() here.

	Public: Init(), HasTarget(): boolean, Holding(): boolean, Target(): Player?
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")

local RunConfig = require(ReplicatedStorage:WaitForChild("SwarmV2"):WaitForChild("Run"):WaitForChild("RunConfig"))
local SD = RunConfig.Survival.Downed

local ReviveHoldClient = {}

local player = Players.LocalPlayer
local remote: RemoteEvent? = nil
local keyHeld = false
local touchHeld = false
local sending = false
local lastSent = -math.huge
local target: Player? = nil
local button: TextButton? = nil
local fill: Frame? = nil
local started = false

local RANGE_SLACK = 1 -- studs: the client shows / sends a little early, the server decides

local function myRoot(): BasePart?
	local char = player.Character
	local root = char and char:FindFirstChild("HumanoidRootPart")
	return if root and root:IsA("BasePart") then root else nil
end

-- The nearest downed teammate in reach, or nil.
local function findTarget(): Player?
	if player:GetAttribute("InRun") ~= true or player:GetAttribute("Alive") == false then
		return nil
	end
	local root = myRoot()
	if not root then
		return nil
	end
	local best: Player? = nil
	local bestD = SD.ReviveRange + RANGE_SLACK
	for _, p in ipairs(Players:GetPlayers()) do
		if p ~= player and p:GetAttribute("InRun") == true and p:GetAttribute("Downed") == true then
			local char = p.Character
			local r = char and char.PrimaryPart
			if r then
				local d = (r.Position - root.Position).Magnitude
				if d <= bestD then
					best, bestD = p, d
				end
			end
		end
	end
	return best
end

-- True while a downed teammate is in reach (interact means revive now).
function ReviveHoldClient.HasTarget(): boolean
	return target ~= nil
end

-- True while a held revive is being sent.
function ReviveHoldClient.Holding(): boolean
	return sending
end

function ReviveHoldClient.Target(): Player?
	return target
end

local function send(on: boolean)
	local r = remote
	if not r then
		return
	end
	r:FireServer(on)
	lastSent = os.clock()
end

local function isInteractKey(input: InputObject): boolean
	return input.KeyCode == Enum.KeyCode.E or input.KeyCode == Enum.KeyCode.ButtonX
end

local function step()
	target = findTarget()
	local want = (keyHeld or touchHeld) and target ~= nil
	if want then
		if not sending or os.clock() - lastSent >= SD.HoldRefresh then
			sending = true
			send(true)
		end
	elseif sending then
		sending = false
		send(false)
	end
	local b = button
	if b then
		local show = target ~= nil and UserInputService.TouchEnabled
		if b.Visible ~= show then
			b.Visible = show
		end
		if not show then
			touchHeld = false
		end
		local f = fill
		if f and show then
			local t = target :: Player
			local p = math.clamp(tonumber(t:GetAttribute("ReviveProgress")) or 0, 0, 1)
			f.Size = UDim2.fromScale(1, p)
		end
	end
end

-- A plain touch button above JUMP (bottom right); stream F restyles it.
local function buildButton()
	local gui = Instance.new("ScreenGui")
	gui.Name = "SwarmReviveHold"
	gui.ResetOnSpawn = false
	gui.IgnoreGuiInset = false
	gui.DisplayOrder = 12
	gui.Parent = player:WaitForChild("PlayerGui")
	local b = Instance.new("TextButton")
	b.Name = "ReviveButton"
	b.AnchorPoint = Vector2.new(1, 1)
	b.Position = UDim2.new(1, -26, 1, -(26 + 96 + 18))
	b.Size = UDim2.fromOffset(84, 84)
	b.BackgroundColor3 = Color3.fromRGB(255, 214, 64)
	b.AutoButtonColor = false
	b.Text = ""
	b.Visible = false
	b.ClipsDescendants = true
	b.Parent = gui
	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(1, 0)
	corner.Parent = b
	local stroke = Instance.new("UIStroke")
	stroke.Color = Color3.fromRGB(26, 42, 92)
	stroke.Thickness = 3
	stroke.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
	stroke.Parent = b
	local f = Instance.new("Frame")
	f.Name = "Fill"
	f.AnchorPoint = Vector2.new(0, 1)
	f.Position = UDim2.fromScale(0, 1)
	f.Size = UDim2.fromScale(1, 0)
	f.BackgroundColor3 = Color3.fromRGB(150, 230, 60)
	f.BorderSizePixel = 0
	f.Parent = b
	local label = Instance.new("TextLabel")
	label.Name = "Label"
	label.BackgroundTransparency = 1
	label.Size = UDim2.fromScale(1, 1)
	label.Text = "HOLD\nREVIVE"
	label.TextColor3 = Color3.fromRGB(26, 42, 92)
	label.TextSize = 16
	label.Font = Enum.Font.FredokaOne
	label.ZIndex = 2
	label:SetAttribute("NoTextFit", true)
	label.Parent = b
	b.InputBegan:Connect(function(input)
		if input.UserInputType == Enum.UserInputType.Touch or input.UserInputType == Enum.UserInputType.MouseButton1 then
			touchHeld = true
		end
	end)
	b.InputEnded:Connect(function(input)
		if input.UserInputType == Enum.UserInputType.Touch or input.UserInputType == Enum.UserInputType.MouseButton1 then
			touchHeld = false
		end
	end)
	button = b
	fill = f
end

function ReviveHoldClient.Init()
	if started then
		return
	end
	started = true
	task.spawn(function()
		local Remotes = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Remotes")) :: any
		remote = Remotes.Get("ReviveHold")
	end)
	pcall(buildButton)
	UserInputService.InputBegan:Connect(function(input, processed)
		if processed or UserInputService:GetFocusedTextBox() then
			return
		end
		if isInteractKey(input) then
			keyHeld = true
		end
	end)
	UserInputService.InputEnded:Connect(function(input)
		if isInteractKey(input) then
			keyHeld = false
		end
	end)
	-- focus loss: the key's InputEnded may never come
	UserInputService.WindowFocusReleased:Connect(function()
		keyHeld = false
		touchHeld = false
	end)
	RunService.Heartbeat:Connect(step)
end

return ReviveHoldClient
