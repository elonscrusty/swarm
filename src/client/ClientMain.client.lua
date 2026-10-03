--[[
	ClientMain.client.lua
	Starts every client module in order and wires the few things that span modules:
	music per phase, the hurt flash, the [VIP] chat tag, the background image preload
	(AssetPreload) and the first-join loading picture (screens/loading + the logo, shown
	only while the server is still loading the lobby / hero models, at most LOADING_MAX
	seconds; it fades out when they are in and never holds anything back). Player settings
	live in ClientSettings (filled from the profile by UIBuilder).
]]

local Players = game:GetService("Players")
local TextChatService = game:GetService("TextChatService")

local Shared = game:GetService("ReplicatedStorage"):WaitForChild("Shared")
local Remotes = require(Shared:WaitForChild("Remotes"))

local Audio = require(script.Parent:WaitForChild("Audio"))
local CameraController = require(script.Parent:WaitForChild("CameraController"))
local MobileControls = require(script.Parent:WaitForChild("MobileControls"))
local EnemyRenderer = require(script.Parent:WaitForChild("EnemyRenderer"))
local VFX = require(script.Parent:WaitForChild("VFX"))
local UIBuilder = require(script.Parent:WaitForChild("UIBuilder"))
local DamageText = require(script.Parent:WaitForChild("DamageText"))
local AssetPreload = require(script.Parent:WaitForChild("AssetPreload"))

local player = Players.LocalPlayer

-- warm the home-screen art and the upgrade / item pictures in the background (the menu and
-- level-up cards show them at once)
AssetPreload.Start()

--[[
	First-join loading picture. Only while ReplicatedStorage.SwarmMeshes says the lobby /
	hero models are still on their way (the same signal as the menu's "Loading models" pill):
	it covers the plain-looking first seconds and fades out as soon as PriorityReady is set,
	the player enters a run, or LOADING_MAX seconds pass. Nothing waits for it; with no
	uploaded picture there is no loading screen at all.
]]
local LOADING_MAX = 12
task.spawn(function()
	local ArtImage = require(script.Parent:WaitForChild("ArtImage"))
	local ClientSettings = require(script.Parent:WaitForChild("ClientSettings"))
	local Theme = require(Shared:WaitForChild("Theme"))
	if not ArtImage.Image("screens/loading") then
		return
	end
	local ReplicatedStorage = game:GetService("ReplicatedStorage")
	local folder = ReplicatedStorage:WaitForChild("SwarmMeshes", 2)
	local function ready(): boolean
		return folder == nil
			or (tonumber(folder:GetAttribute("Total")) or 0) <= 0
			or folder:GetAttribute("PriorityReady") == true
			or player:GetAttribute("InRun") == true
	end
	if ready() then
		return
	end
	local gui = Instance.new("ScreenGui")
	gui.Name = "LoadingScreen"
	gui.IgnoreGuiInset = true
	gui.ScreenInsets = Enum.ScreenInsets.None -- edge to edge, under notches too
	gui.ResetOnSpawn = false
	gui.DisplayOrder = 100
	local back = Instance.new("Frame")
	back.Name = "Backdrop"
	back.BackgroundColor3 = Color3.fromRGB(14, 16, 24)
	back.BorderSizePixel = 0
	back.Size = UDim2.fromScale(1, 1)
	back.Active = true -- the menu under it is not tapped blind
	back.Parent = gui
	local fades: { Instance } = { back }
	local picture = ArtImage.Place(back, "screens/loading", { Name = "Picture", ScaleType = Enum.ScaleType.Crop, FadeIn = 0.35 })
	if picture then
		table.insert(fades, picture)
	end
	local logo = ArtImage.Place(back, "screens/logo_SWARM", {
		Name = "Logo",
		AnchorPoint = Vector2.new(0.5, 0),
		Position = UDim2.fromScale(0.5, 0.06),
		Size = UDim2.fromScale(0.5, 0.36),
		FadeIn = 0.35,
		ZIndex = 2,
	})
	if logo then
		local cap = Instance.new("UISizeConstraint")
		cap.MaxSize = Vector2.new(640, 320)
		cap.Parent = logo
		table.insert(fades, logo)
	end
	local label = Instance.new("TextLabel")
	label.Name = "Progress"
	label.BackgroundTransparency = 1
	label.AnchorPoint = Vector2.new(0.5, 1)
	label.Position = UDim2.new(0.5, 0, 1, -28)
	label.Size = UDim2.new(1, -32, 0, 30)
	label.FontFace = Theme.Font.Label
	label.TextSize = 20
	label.TextColor3 = Color3.fromRGB(246, 226, 160)
	label.TextStrokeTransparency = 0.4
	label.Text = "Loading…"
	label.ZIndex = 3
	label.Parent = back
	table.insert(fades, label)
	gui.Parent = player:WaitForChild("PlayerGui")
	local t0 = os.clock()
	while not ready() and os.clock() - t0 < LOADING_MAX do
		local need = tonumber(folder:GetAttribute("PriorityTotal")) or 0
		local done = tonumber(folder:GetAttribute("PriorityDone")) or 0
		if need > 0 then
			label.Text = string.format("Loading… %d%%", math.floor(100 * math.clamp(done / need, 0, 1)))
		end
		task.wait(0.2)
	end
	if ClientSettings.Reduced() then
		gui:Destroy()
		return
	end
	local TweenService = game:GetService("TweenService")
	local info = TweenInfo.new(0.5)
	for _, obj in ipairs(fades) do
		local goal = obj:IsA("ImageLabel") and { ImageTransparency = 1 } or obj:IsA("TextLabel") and { TextTransparency = 1, TextStrokeTransparency = 1 } or { BackgroundTransparency = 1 }
		TweenService:Create(obj, info, goal):Play()
	end
	task.wait(0.55)
	gui:Destroy()
end)
Audio.Init()
CameraController.Init()
MobileControls.Init()
EnemyRenderer.Init() -- before VFX: it sets up the folder the 3D models live in
VFX.Init({
	OnLocalEvent = function(kind)
		if kind == "hurt" then
			UIBuilder.HurtFlash()
		end
	end,
})
UIBuilder.Init({ Audio = Audio, MobileControls = MobileControls })
require(script.Parent:WaitForChild("TeamPings")).Init()
require(script.Parent:WaitForChild("ClientPerformance")).Init()
require(script.Parent:WaitForChild("GroundDetail")).Init()
DamageText.Init() -- optional damage numbers (Settings), after EnemyRenderer
require(script.Parent:WaitForChild("TravelOverlay")).Init() -- private run servers: travel cover + go-home banner

-- Humanoid state switches don't replicate and the client owns its character, so the
-- server's settings are repeated here: no tripping, ragdolling or dying (jumps: JumpController).
local function setupCharacter(char: Model)
	local hum = char:WaitForChild("Humanoid", 10) :: Humanoid?
	if hum then
		for _, s in ipairs({ Enum.HumanoidStateType.FallingDown, Enum.HumanoidStateType.Ragdoll, Enum.HumanoidStateType.Dead }) do
			hum:SetStateEnabled(s, false)
		end
	end
end
player.CharacterAdded:Connect(setupCharacter)
if player.Character then
	task.spawn(setupCharacter, player.Character)
end

-- Music follows the game phase.
local state = Remotes.State()
local function updateMusic()
	local inRun = player:GetAttribute("InRun") == true
	if not inRun then
		Audio.SetMusic("LobbyMusic")
	elseif (state:GetAttribute("BossMaxHP") or 0) > 0 then
		Audio.SetMusic("BossMusic")
	else
		Audio.SetMusic("BattleMusic")
	end
end
player:GetAttributeChangedSignal("InRun"):Connect(updateMusic)
state:GetAttributeChangedSignal("BossMaxHP"):Connect(updateMusic)
updateMusic()

-- [VIP] chat tag (TextChatService). The VIP attribute is set by the server.
TextChatService.OnIncomingMessage = function(message: TextChatMessage)
	local props = Instance.new("TextChatMessageProperties")
	local source = message.TextSource
	if source then
		local speaker = Players:GetPlayerByUserId(source.UserId)
		if speaker and speaker:GetAttribute("VIP") then
			props.PrefixText = '<font color="#FFD24A">[VIP]</font> ' .. message.PrefixText
		end
	end
	return props
end
