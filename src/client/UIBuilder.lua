--[[
	UIBuilder.lua
	Builds every screen in code: HUD, level-up cards, chest animation, pause menu,
	revive offer, win/lose screen, lobby panels (characters, shop), lobby banners and the
	stats sign.

	Scaling: all UI lives under one "Root" frame with a UIScale. The design is done in
	"reference pixels" (1280x720 landscape, 720x1280 portrait); Root is sized 1/scale so
	the scaled result always fills the screen exactly. Everything uses this UIScale.
	The ScreenGui uses the device safe area (notches, rounded corners).
]]

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")
local UserInputService = game:GetService("UserInputService")
local MarketplaceService = game:GetService("MarketplaceService")

local Shared = game:GetService("ReplicatedStorage"):WaitForChild("Shared")
local Config = require(Shared:WaitForChild("Config"))
local Remotes = require(Shared:WaitForChild("Remotes"))
local CharacterData = require(Shared:WaitForChild("CharacterData"))
local MetaUpgradeData = require(Shared:WaitForChild("MetaUpgradeData"))

local UIBuilder = {}

local player = Players.LocalPlayer
local deps: { [string]: any } = {}

local gui: ScreenGui
local root: Frame
local uiScale: UIScale
local portrait = false

local profile: { [string]: any }? = nil
local inventory: { [string]: any }? = nil
local joinedCountdown = false

-- Open modals that should stop movement.
local blocking: { [string]: boolean } = {}

local COLORS = {
	Panel = Color3.fromRGB(24, 24, 34),
	PanelLight = Color3.fromRGB(40, 40, 56),
	Text = Color3.fromRGB(240, 240, 245),
	Dim = Color3.fromRGB(170, 170, 185),
	Gold = Color3.fromRGB(255, 210, 70),
	Green = Color3.fromRGB(70, 200, 110),
	Red = Color3.fromRGB(220, 70, 70),
	Blue = Color3.fromRGB(70, 140, 230),
	Gray = Color3.fromRGB(90, 90, 105),
	XP = Color3.fromRGB(90, 170, 255),
}

------------------------------------------------------------------------------------------
-- Helpers
------------------------------------------------------------------------------------------

local function new(className: string, props: { [string]: any }, parent: Instance?): any
	local obj = Instance.new(className)
	for k, v in pairs(props) do
		(obj :: any)[k] = v
	end
	if parent then
		obj.Parent = parent
	end
	return obj
end

local function corner(obj: Instance, radius: number?)
	new("UICorner", { CornerRadius = UDim.new(0, radius or 10) }, obj)
end

local function stroke(obj: Instance, color: Color3, thickness: number?)
	return new("UIStroke", { Color = color, Thickness = thickness or 2, ApplyStrokeMode = Enum.ApplyStrokeMode.Border }, obj)
end

local function pad(obj: Instance, p: number)
	new("UIPadding", { PaddingTop = UDim.new(0, p), PaddingBottom = UDim.new(0, p), PaddingLeft = UDim.new(0, p), PaddingRight = UDim.new(0, p) }, obj)
end

local function label(parent: Instance, text: string, size: number, props: { [string]: any }?): TextLabel
	local l = new("TextLabel", {
		BackgroundTransparency = 1,
		Text = text,
		TextSize = size,
		Font = Config.UI.Font,
		TextColor3 = COLORS.Text,
		Size = UDim2.new(1, 0, 0, size + 6),
	}, parent)
	if props then
		for k, v in pairs(props) do
			(l :: any)[k] = v
		end
	end
	return l
end

local function button(parent: Instance, text: string, color: Color3, onClick: () -> (), props: { [string]: any }?): TextButton
	local b = new("TextButton", {
		Text = text,
		TextSize = 22,
		Font = Config.UI.Font,
		TextColor3 = Color3.new(1, 1, 1),
		BackgroundColor3 = color,
		AutoButtonColor = true,
		Size = UDim2.fromOffset(180, 50),
	}, parent)
	corner(b, 10)
	if props then
		for k, v in pairs(props) do
			(b :: any)[k] = v
		end
	end
	b.Activated:Connect(function()
		if deps.Audio then
			deps.Audio.Play("Click")
		end
		onClick()
	end)
	return b
end

local function formatTime(seconds: number): string
	seconds = math.max(0, math.floor(seconds))
	return string.format("%d:%02d", seconds // 60, seconds % 60)
end

local function setBlocking(name: string, on: boolean)
	if on then
		blocking[name] = true
	else
		blocking[name] = nil
	end
	if deps.MobileControls then
		deps.MobileControls.SetEnabled(next(blocking) == nil)
	end
end

-- Dark full-screen overlay that swallows touches + a centred panel.
local function modal(name: string, width: number, height: number, order: number): (Frame, Frame)
	local overlay = new("Frame", {
		Name = name,
		Size = UDim2.fromScale(1, 1),
		BackgroundColor3 = Color3.new(0, 0, 0),
		BackgroundTransparency = 0.45,
		Active = true,
		Visible = false,
		ZIndex = order,
	}, root)
	local panel = new("Frame", {
		Name = "Panel",
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.5),
		Size = UDim2.fromOffset(width, height),
		BackgroundColor3 = COLORS.Panel,
		ZIndex = order,
	}, overlay)
	corner(panel, 16)
	stroke(panel, COLORS.PanelLight, 3)
	return overlay, panel
end

local function show(overlay: GuiObject, name: string, blocks: boolean)
	overlay.Visible = true
	if blocks then
		setBlocking(name, true)
	end
end

local function hide(overlay: GuiObject, name: string)
	overlay.Visible = false
	setBlocking(name, false)
end

------------------------------------------------------------------------------------------
-- Root + scaling
------------------------------------------------------------------------------------------

local relayoutCallbacks: { () -> () } = {}

local function virtualSize(): Vector2
	return gui.AbsoluteSize / math.max(0.01, uiScale.Scale)
end

local function updateScale()
	local size = gui.AbsoluteSize
	if size.X < 1 or size.Y < 1 then
		return
	end
	portrait = size.Y > size.X
	local ref = Config.UI.ReferenceSize
	local refX, refY = ref.X, ref.Y
	if portrait then
		refX, refY = ref.Y, ref.X
	end
	local s = math.clamp(math.min(size.X / refX, size.Y / refY), Config.UI.MinScale, Config.UI.MaxScale)
	uiScale.Scale = s
	root.Size = UDim2.fromScale(1 / s, 1 / s)
	for _, fn in ipairs(relayoutCallbacks) do
		fn()
	end
end

------------------------------------------------------------------------------------------
-- HUD (in run)
------------------------------------------------------------------------------------------

local hud: { [string]: any } = {}

local function buildHud()
	local frame = new("Frame", { Name = "HUD", Size = UDim2.fromScale(1, 1), BackgroundTransparency = 1, Visible = false }, root)
	hud.Frame = frame

	-- XP bar across the top
	local xpBack = new("Frame", { Name = "XPBar", Size = UDim2.new(1, 0, 0, 18), BackgroundColor3 = Color3.fromRGB(20, 20, 30), BorderSizePixel = 0 }, frame)
	hud.XPFill = new("Frame", { Size = UDim2.fromScale(0, 1), BackgroundColor3 = COLORS.XP, BorderSizePixel = 0 }, xpBack)
	hud.Level = label(xpBack, "LV 1", 16, { Size = UDim2.fromScale(1, 1), TextXAlignment = Enum.TextXAlignment.Right, ZIndex = 2 })
	new("UIPadding", { PaddingRight = UDim.new(0, 10) }, hud.Level)

	-- Timer (top centre)
	hud.Timer = label(frame, "0:00", 44, {
		AnchorPoint = Vector2.new(0.5, 0),
		Position = UDim2.new(0.5, 0, 0, 22),
		Size = UDim2.fromOffset(220, 50),
		TextStrokeTransparency = 0.4,
	})

	-- Boss bar
	local bossBack = new("Frame", {
		Name = "BossBar",
		AnchorPoint = Vector2.new(0.5, 0),
		Position = UDim2.new(0.5, 0, 0, 80),
		Size = UDim2.new(0.6, 0, 0, 24),
		BackgroundColor3 = Color3.fromRGB(40, 10, 15),
		Visible = false,
	}, frame)
	corner(bossBack, 6)
	stroke(bossBack, Color3.fromRGB(255, 80, 90), 2)
	hud.BossFill = new("Frame", { Size = UDim2.fromScale(1, 1), BackgroundColor3 = Color3.fromRGB(220, 30, 50), BorderSizePixel = 0 }, bossBack)
	corner(hud.BossFill, 6)
	label(bossBack, "THE SWARM QUEEN", 16, { Size = UDim2.fromScale(1, 1), ZIndex = 2, TextStrokeTransparency = 0.3 })
	hud.Boss = bossBack

	-- Kills + gold (top left)
	hud.Counters = label(frame, "Kills 0   Gold 0", 20, {
		Position = UDim2.fromOffset(12, 24),
		Size = UDim2.fromOffset(320, 26),
		TextXAlignment = Enum.TextXAlignment.Left,
		TextStrokeTransparency = 0.5,
	})

	-- Inventory icons
	local inv = new("Frame", { Name = "Inventory", Position = UDim2.fromOffset(12, 56), Size = UDim2.fromOffset(330, 100), BackgroundTransparency = 1 }, frame)
	new("UIListLayout", { Padding = UDim.new(0, 6), SortOrder = Enum.SortOrder.LayoutOrder }, inv)
	hud.WeaponRow = new("Frame", { Size = UDim2.fromOffset(330, 46), BackgroundTransparency = 1, LayoutOrder = 1 }, inv)
	new("UIListLayout", { FillDirection = Enum.FillDirection.Horizontal, Padding = UDim.new(0, 5) }, hud.WeaponRow)
	hud.PassiveRow = new("Frame", { Size = UDim2.fromOffset(330, 40), BackgroundTransparency = 1, LayoutOrder = 2 }, inv)
	new("UIListLayout", { FillDirection = Enum.FillDirection.Horizontal, Padding = UDim.new(0, 5) }, hud.PassiveRow)

	-- Pause button (top right). Optional: nothing in a run needs a button.
	button(frame, "II", Color3.fromRGB(50, 50, 70), function()
		UIBuilder.OpenPause()
	end, {
		AnchorPoint = Vector2.new(1, 0),
		Position = UDim2.new(1, -12, 0, 26),
		Size = UDim2.fromOffset(56, 56),
		TextSize = 26,
		BackgroundTransparency = 0.2,
	})

	hud.Status = label(frame, "", 30, {
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.75),
		Size = UDim2.fromOffset(700, 40),
		TextColor3 = Color3.fromRGB(255, 200, 200),
		TextStrokeTransparency = 0.3,
		Visible = false,
	})

	-- Red flash when hurt
	hud.Hurt = new("Frame", { Size = UDim2.fromScale(1, 1), BackgroundColor3 = Color3.fromRGB(255, 0, 0), BackgroundTransparency = 1, ZIndex = 0 }, frame)
end

local function iconTile(parent: Instance, color: Color3, level: number, maxLevel: number, evolved: boolean, size: number)
	local tile = new("Frame", { Size = UDim2.fromOffset(size, size), BackgroundColor3 = color }, parent)
	corner(tile, 6)
	stroke(tile, evolved and COLORS.Gold or Color3.fromRGB(20, 20, 25), evolved and 3 or 2)
	-- level pips along the bottom
	local pips = new("Frame", { AnchorPoint = Vector2.new(0.5, 1), Position = UDim2.new(0.5, 0, 1, -3), Size = UDim2.new(1, -6, 0, 5), BackgroundTransparency = 1 }, tile)
	new("UIListLayout", { FillDirection = Enum.FillDirection.Horizontal, Padding = UDim.new(0, 1), HorizontalAlignment = Enum.HorizontalAlignment.Center }, pips)
	local pipW = math.floor((size - 6 - maxLevel) / maxLevel)
	for i = 1, maxLevel do
		new("Frame", { Size = UDim2.fromOffset(pipW, 5), BackgroundColor3 = (evolved or i <= level) and Color3.new(1, 1, 1) or Color3.fromRGB(30, 30, 40), BorderSizePixel = 0 }, pips)
	end
	return tile
end

local function refreshInventory()
	for _, row in ipairs({ hud.WeaponRow, hud.PassiveRow }) do
		for _, c in ipairs(row:GetChildren()) do
			if c:IsA("Frame") then
				c:Destroy()
			end
		end
	end
	if not inventory then
		return
	end
	for _, w in ipairs(inventory.Weapons) do
		local t = iconTile(hud.WeaponRow, w.Color, w.Level, 8, w.Evolved, 46)
		label(t, string.sub(w.Name, 1, 2), 18, { Size = UDim2.new(1, 0, 1, -8), TextStrokeTransparency = 0.3 })
	end
	for _, p in ipairs(inventory.Passives) do
		local t = iconTile(hud.PassiveRow, p.Color, p.Level, 5, false, 38)
		label(t, string.sub(p.Name, 1, 2), 15, { Size = UDim2.new(1, 0, 1, -8), TextStrokeTransparency = 0.3 })
	end
end

function UIBuilder.HurtFlash()
	hud.Hurt.BackgroundTransparency = 0.65
	TweenService:Create(hud.Hurt, TweenInfo.new(0.35), { BackgroundTransparency = 1 }):Play()
end

------------------------------------------------------------------------------------------
-- Lobby HUD
------------------------------------------------------------------------------------------

local lobbyUi: { [string]: any } = {}

local function buildLobbyHud()
	local frame = new("Frame", { Name = "LobbyHUD", Size = UDim2.fromScale(1, 1), BackgroundTransparency = 1 }, root)
	lobbyUi.Frame = frame
	lobbyUi.Gold = label(frame, "Gold 0", 26, {
		Position = UDim2.fromOffset(14, 12),
		Size = UDim2.fromOffset(300, 32),
		TextXAlignment = Enum.TextXAlignment.Left,
		TextColor3 = COLORS.Gold,
		TextStrokeTransparency = 0.4,
	})

	local banner = new("Frame", {
		Name = "Countdown",
		AnchorPoint = Vector2.new(0.5, 0),
		Position = UDim2.new(0.5, 0, 0, 12),
		Size = UDim2.fromOffset(460, 110),
		BackgroundColor3 = COLORS.Panel,
		BackgroundTransparency = 0.15,
		Visible = false,
	}, frame)
	corner(banner, 14)
	lobbyUi.CountdownText = label(banner, "Run starts in 10", 30, { Position = UDim2.fromOffset(0, 8), Size = UDim2.new(1, 0, 0, 38) })
	lobbyUi.JoinButton = button(banner, "JOIN RUN", COLORS.Green, function()
		Remotes.Get("JoinRun"):FireServer()
	end, { AnchorPoint = Vector2.new(0.5, 0), Position = UDim2.new(0.5, 0, 0, 50), Size = UDim2.fromOffset(220, 50) })
	lobbyUi.Banner = banner

	lobbyUi.Info = label(frame, "", 22, {
		AnchorPoint = Vector2.new(0.5, 1),
		Position = UDim2.new(0.5, 0, 1, -16),
		Size = UDim2.fromOffset(700, 30),
		TextStrokeTransparency = 0.4,
	})

	-- Quick access buttons (the boards' prompts open the same panels).
	local quick = new("Frame", { AnchorPoint = Vector2.new(1, 1), Position = UDim2.new(1, -14, 1, -60), Size = UDim2.fromOffset(170, 120), BackgroundTransparency = 1 }, frame)
	new("UIListLayout", { Padding = UDim.new(0, 8), HorizontalAlignment = Enum.HorizontalAlignment.Right }, quick)
	button(quick, "Characters", COLORS.Blue, function()
		UIBuilder.OpenPanel("Characters")
	end, { Size = UDim2.fromOffset(170, 50) })
	button(quick, "Upgrades", Color3.fromRGB(200, 140, 40), function()
		UIBuilder.OpenPanel("Shop")
	end, { Size = UDim2.fromOffset(170, 50) })
end

------------------------------------------------------------------------------------------
-- Toasts and banners
------------------------------------------------------------------------------------------

local toastList: Frame
local bigBanner: TextLabel

local function buildToasts()
	toastList = new("Frame", {
		Name = "Toasts",
		AnchorPoint = Vector2.new(0.5, 0),
		Position = UDim2.new(0.5, 0, 0, 130),
		Size = UDim2.fromOffset(620, 200),
		BackgroundTransparency = 1,
		ZIndex = 20,
	}, root)
	new("UIListLayout", { Padding = UDim.new(0, 6), HorizontalAlignment = Enum.HorizontalAlignment.Center, SortOrder = Enum.SortOrder.LayoutOrder }, toastList)
	bigBanner = label(root, "", 64, {
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.38),
		Size = UDim2.fromOffset(900, 80),
		TextStrokeTransparency = 0.2,
		TextTransparency = 1,
		TextStrokeColor3 = Color3.new(0, 0, 0),
		ZIndex = 20,
	})
end

local toastOrder = 0
function UIBuilder.Toast(text: string, color: Color3?, big: boolean?)
	if big then
		bigBanner.Text = text
		bigBanner.TextColor3 = color or COLORS.Text
		bigBanner.TextTransparency = 0
		bigBanner.TextStrokeTransparency = 0.2
		task.delay(2.2, function()
			if bigBanner.Text == text then
				TweenService:Create(bigBanner, TweenInfo.new(0.5), { TextTransparency = 1, TextStrokeTransparency = 1 }):Play()
			end
		end)
		return
	end
	toastOrder += 1
	local t = label(toastList, text, 22, {
		Size = UDim2.fromOffset(620, 32),
		TextColor3 = color or COLORS.Text,
		BackgroundColor3 = Color3.fromRGB(0, 0, 0),
		BackgroundTransparency = 0.5,
		LayoutOrder = toastOrder,
		TextWrapped = true,
	})
	corner(t, 8)
	local children = toastList:GetChildren()
	if #children > 6 then
		for _, c in ipairs(children) do
			if c:IsA("TextLabel") then
				c:Destroy()
				break
			end
		end
	end
	task.delay(Config.UI.ToastSeconds, function()
		if t.Parent then
			local tw = TweenService:Create(t, TweenInfo.new(0.4), { TextTransparency = 1, BackgroundTransparency = 1 })
			tw.Completed:Once(function()
				t:Destroy()
			end)
			tw:Play()
		end
	end)
end

------------------------------------------------------------------------------------------
-- Level-up screen
------------------------------------------------------------------------------------------

local levelUp: { [string]: any } = {}

local function buildLevelUp()
	local overlay = new("Frame", {
		Name = "LevelUp",
		Size = UDim2.fromScale(1, 1),
		BackgroundColor3 = Color3.new(0, 0, 0),
		BackgroundTransparency = 0.4,
		Active = true,
		Visible = false,
		ZIndex = 30,
	}, root)
	levelUp.Overlay = overlay
	levelUp.Title = label(overlay, "LEVEL UP!", 52, {
		AnchorPoint = Vector2.new(0.5, 0),
		Position = UDim2.new(0.5, 0, 0, 30),
		Size = UDim2.fromOffset(600, 60),
		TextColor3 = COLORS.Gold,
		TextStrokeTransparency = 0.3,
		ZIndex = 31,
	})
	levelUp.Sub = label(overlay, "", 20, {
		AnchorPoint = Vector2.new(0.5, 0),
		Position = UDim2.new(0.5, 0, 0, 92),
		Size = UDim2.fromOffset(600, 26),
		TextColor3 = COLORS.Dim,
		ZIndex = 31,
	})
	levelUp.Cards = new("Frame", {
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.52),
		Size = UDim2.fromOffset(960, 380),
		BackgroundTransparency = 1,
		ZIndex = 31,
	}, overlay)
	levelUp.Layout = new("UIListLayout", {
		FillDirection = Enum.FillDirection.Horizontal,
		Padding = UDim.new(0, 18),
		HorizontalAlignment = Enum.HorizontalAlignment.Center,
		VerticalAlignment = Enum.VerticalAlignment.Center,
		SortOrder = Enum.SortOrder.LayoutOrder,
	}, levelUp.Cards)

	local actions = new("Frame", {
		AnchorPoint = Vector2.new(0.5, 1),
		Position = UDim2.new(0.5, 0, 1, -24),
		Size = UDim2.fromOffset(460, 56),
		BackgroundTransparency = 1,
		ZIndex = 31,
	}, overlay)
	new("UIListLayout", { FillDirection = Enum.FillDirection.Horizontal, Padding = UDim.new(0, 16), HorizontalAlignment = Enum.HorizontalAlignment.Center }, actions)
	levelUp.Reroll = button(actions, "Reroll", COLORS.Blue, function()
		Remotes.Get("LevelUpReroll"):FireServer()
	end, { Size = UDim2.fromOffset(200, 54), ZIndex = 32 })
	levelUp.Skip = button(actions, "Skip", COLORS.Gray, function()
		Remotes.Get("LevelUpSkip"):FireServer()
	end, { Size = UDim2.fromOffset(200, 54), ZIndex = 32 })

	table.insert(relayoutCallbacks, function()
		local v = virtualSize()
		if portrait then
			levelUp.Layout.FillDirection = Enum.FillDirection.Vertical
			levelUp.Cards.Size = UDim2.fromOffset(math.min(v.X - 30, 660), 3 * 170 + 40)
		else
			levelUp.Layout.FillDirection = Enum.FillDirection.Horizontal
			levelUp.Cards.Size = UDim2.fromOffset(math.min(v.X - 30, 1000), 380)
		end
		for _, card in ipairs(levelUp.Cards:GetChildren()) do
			if card:IsA("TextButton") then
				card.Size = portrait and UDim2.fromOffset(math.min(v.X - 30, 660), 165) or UDim2.fromOffset(300, 360)
			end
		end
	end)
end

local offerDeadline = 0
local offerOpen = false

local function makeCard(c, index: number)
	local v = virtualSize()
	local card = new("TextButton", {
		Name = "Card" .. index,
		Text = "",
		AutoButtonColor = true,
		BackgroundColor3 = COLORS.Panel,
		Size = portrait and UDim2.fromOffset(math.min(v.X - 30, 660), 165) or UDim2.fromOffset(300, 360),
		LayoutOrder = index,
		ZIndex = 32,
	}, levelUp.Cards)
	corner(card, 14)
	stroke(card, c.RarityColor, c.Rarity == "Legendary" and 5 or 3)
	pad(card, 12)
	new("UIListLayout", { Padding = UDim.new(0, 6), HorizontalAlignment = Enum.HorizontalAlignment.Center, SortOrder = Enum.SortOrder.LayoutOrder }, card)
	label(card, c.RarityLabel, 16, { TextColor3 = c.RarityColor, LayoutOrder = 1, ZIndex = 33 })
	if not portrait then
		local icon = new("Frame", { Size = UDim2.fromOffset(84, 84), BackgroundColor3 = c.Color, LayoutOrder = 2, ZIndex = 33 }, card)
		corner(icon, 12)
		stroke(icon, Color3.new(0, 0, 0), 2)
	end
	local levelText = ""
	if c.Type == "WeaponNew" or c.Type == "PassiveNew" then
		levelText = "NEW!"
	elseif c.Type == "WeaponUp" or c.Type == "PassiveUp" then
		levelText = "Level " .. c.Level
	elseif c.Type == "Evolve" then
		levelText = "EVOLUTION"
	end
	label(card, c.Name .. (levelText ~= "" and ("  -  " .. levelText) or ""), 24, { LayoutOrder = 3, ZIndex = 33, TextWrapped = true, Size = UDim2.new(1, 0, 0, 30) })
	label(card, c.Description, 18, {
		LayoutOrder = 4,
		ZIndex = 33,
		TextWrapped = true,
		TextColor3 = COLORS.Dim,
		Font = Config.UI.BodyFont,
		Size = UDim2.new(1, 0, 0, portrait and 50 or 120),
		TextYAlignment = Enum.TextYAlignment.Top,
	})
	card.Activated:Connect(function()
		if not offerOpen then
			return
		end
		offerOpen = false
		if deps.Audio then
			deps.Audio.Play("Click")
		end
		Remotes.Get("LevelUpChoose"):FireServer(index)
	end)
end

local function showOffer(offer)
	for _, c in ipairs(levelUp.Cards:GetChildren()) do
		if c:IsA("TextButton") then
			c:Destroy()
		end
	end
	for i, c in ipairs(offer.Choices) do
		makeCard(c, i)
	end
	levelUp.Reroll.Text = "Reroll (" .. offer.Rerolls .. ")"
	levelUp.Reroll.Visible = offer.Rerolls > 0
	levelUp.Skip.Text = "Skip (" .. offer.Skips .. ")"
	levelUp.Skip.Visible = offer.Skips > 0
	levelUp.Title.Text = offer.Pending > 1 and string.format("LEVEL UP! (+%d)", offer.Pending) or "LEVEL UP!"
	offerDeadline = os.clock() + offer.Seconds
	offerOpen = true
	show(levelUp.Overlay, "LevelUp", true)
end

local function closeOffer()
	offerOpen = false
	hide(levelUp.Overlay, "LevelUp")
end

------------------------------------------------------------------------------------------
-- Chest animation
------------------------------------------------------------------------------------------

local chest: { [string]: any } = {}

local function buildChest()
	local panel = new("Frame", {
		Name = "Chest",
		AnchorPoint = Vector2.new(0.5, 0),
		Position = UDim2.new(0.5, 0, 0, 150),
		Size = UDim2.fromOffset(420, 300),
		BackgroundColor3 = COLORS.Panel,
		BackgroundTransparency = 0.1,
		Visible = false,
		ZIndex = 25,
	}, root)
	corner(panel, 16)
	stroke(panel, COLORS.Gold, 3)
	chest.Panel = panel
	chest.Box = new("Frame", { AnchorPoint = Vector2.new(0.5, 0), Position = UDim2.new(0.5, 0, 0, 70), Size = UDim2.fromOffset(150, 80), BackgroundColor3 = Color3.fromRGB(130, 80, 40), ZIndex = 26 }, panel)
	corner(chest.Box, 6)
	stroke(chest.Box, COLORS.Gold, 3)
	chest.Lid = new("Frame", { AnchorPoint = Vector2.new(0.5, 1), Position = UDim2.new(0.5, 0, 0, 72), Size = UDim2.fromOffset(160, 36), BackgroundColor3 = Color3.fromRGB(150, 95, 50), ZIndex = 27 }, panel)
	corner(chest.Lid, 10)
	stroke(chest.Lid, COLORS.Gold, 3)
	chest.Glow = new("Frame", { AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.new(0.5, 0, 0, 80), Size = UDim2.fromOffset(10, 10), BackgroundColor3 = COLORS.Gold, BackgroundTransparency = 1, ZIndex = 25 }, panel)
	corner(chest.Glow, 100)
	chest.Rewards = new("Frame", { Position = UDim2.fromOffset(10, 160), Size = UDim2.new(1, -20, 0, 130), BackgroundTransparency = 1, ZIndex = 26 }, panel)
	new("UIListLayout", { Padding = UDim.new(0, 4), HorizontalAlignment = Enum.HorizontalAlignment.Center }, chest.Rewards)
	label(panel, "TREASURE!", 28, { Position = UDim2.fromOffset(0, 10), TextColor3 = COLORS.Gold, ZIndex = 26 })
end

function UIBuilder.ShowChest(data)
	for _, c in ipairs(chest.Rewards:GetChildren()) do
		if c:IsA("TextLabel") then
			c:Destroy()
		end
	end
	chest.Panel.Visible = true
	chest.Lid.Position = UDim2.new(0.5, 0, 0, 72)
	chest.Lid.Rotation = 0
	chest.Glow.Size = UDim2.fromOffset(10, 10)
	chest.Glow.BackgroundTransparency = 1
	-- shake, pop the lid, burst of light, then list the rewards
	local shake = TweenService:Create(chest.Box, TweenInfo.new(0.06, Enum.EasingStyle.Linear, Enum.EasingDirection.InOut, 5, true), { Rotation = 6 })
	shake:Play()
	task.delay(0.4, function()
		chest.Box.Rotation = 0
		TweenService:Create(chest.Lid, TweenInfo.new(0.35, Enum.EasingStyle.Back), { Position = UDim2.new(0.5, 40, 0, 30), Rotation = 35 }):Play()
		chest.Glow.BackgroundTransparency = 0.2
		TweenService:Create(chest.Glow, TweenInfo.new(0.5), { Size = UDim2.fromOffset(260, 260), BackgroundTransparency = 1 }):Play()
		for i, r in ipairs(data.Rewards) do
			task.delay(0.15 * i, function()
				label(chest.Rewards, r.Name .. "  " .. r.Text, 22, { TextColor3 = r.Color, ZIndex = 26 })
			end)
		end
		task.delay(0.15 * (#data.Rewards + 1), function()
			label(chest.Rewards, "+" .. tostring(data.Gold) .. " gold", 22, { TextColor3 = COLORS.Gold, ZIndex = 26 })
		end)
	end)
	task.delay(3.2, function()
		chest.Panel.Visible = false
	end)
end

------------------------------------------------------------------------------------------
-- Pause menu
------------------------------------------------------------------------------------------

local pause: { [string]: any } = {}
local volumes = { Music = 0.6, Sfx = 0.8 }

local function slider(parent: Instance, text: string, key: string, order: number)
	local row = new("Frame", { Size = UDim2.new(1, 0, 0, 60), BackgroundTransparency = 1, LayoutOrder = order, ZIndex = 41 }, parent)
	local title = label(row, text, 20, { Size = UDim2.new(1, 0, 0, 24), TextXAlignment = Enum.TextXAlignment.Left, ZIndex = 41 })
	local bar = new("Frame", { Position = UDim2.fromOffset(0, 36), Size = UDim2.new(1, 0, 0, 12), BackgroundColor3 = COLORS.PanelLight, ZIndex = 41 }, row)
	corner(bar, 6)
	local fill = new("Frame", { Size = UDim2.fromScale(volumes[key], 1), BackgroundColor3 = COLORS.Blue, ZIndex = 42 }, bar)
	corner(fill, 6)
	local knob = new("Frame", { AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(volumes[key], 0.5), Size = UDim2.fromOffset(28, 28), BackgroundColor3 = Color3.new(1, 1, 1), ZIndex = 43 }, bar)
	corner(knob, 14)
	local dragging: InputObject? = nil
	local function setFromX(x: number)
		local v = math.clamp((x - bar.AbsolutePosition.X) / math.max(1, bar.AbsoluteSize.X), 0, 1)
		volumes[key] = v
		fill.Size = UDim2.fromScale(v, 1)
		knob.Position = UDim2.fromScale(v, 0.5)
		title.Text = string.format("%s  %d%%", text, math.floor(v * 100 + 0.5))
		if deps.Audio then
			deps.Audio.SetVolumes(volumes.Music, volumes.Sfx)
		end
	end
	local hit = new("TextButton", { Text = "", BackgroundTransparency = 1, Position = UDim2.fromOffset(0, 24), Size = UDim2.new(1, 0, 0, 36), ZIndex = 44 }, row)
	hit.InputBegan:Connect(function(input)
		if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
			dragging = input
			setFromX(input.Position.X)
		end
	end)
	UserInputService.InputChanged:Connect(function(input)
		if dragging and (input == dragging or input.UserInputType == Enum.UserInputType.MouseMovement) then
			setFromX(input.Position.X)
		end
	end)
	UserInputService.InputEnded:Connect(function(input)
		if dragging and (input == dragging or input.UserInputType == Enum.UserInputType.MouseButton1) then
			dragging = nil
			Remotes.Get("SaveSettings"):FireServer({ Music = volumes.Music, Sfx = volumes.Sfx })
		end
	end)
	pause[key] = function()
		fill.Size = UDim2.fromScale(volumes[key], 1)
		knob.Position = UDim2.fromScale(volumes[key], 0.5)
		title.Text = string.format("%s  %d%%", text, math.floor(volumes[key] * 100 + 0.5))
	end
	pause[key]()
end

local function buildPause()
	local overlay, panel = modal("Pause", 440, 380, 40)
	pause.Overlay = overlay
	pad(panel, 20)
	new("UIListLayout", { Padding = UDim.new(0, 12), HorizontalAlignment = Enum.HorizontalAlignment.Center, SortOrder = Enum.SortOrder.LayoutOrder }, panel)
	label(panel, "PAUSED", 36, { LayoutOrder = 0, ZIndex = 41 })
	slider(panel, "Music", "Music", 1)
	slider(panel, "Sound effects", "Sfx", 2)
	pause.Note = label(panel, "", 16, { LayoutOrder = 3, TextColor3 = COLORS.Dim, Font = Config.UI.BodyFont, TextWrapped = true, Size = UDim2.new(1, 0, 0, 40), ZIndex = 41 })
	button(panel, "Resume", COLORS.Green, function()
		UIBuilder.ClosePause()
	end, { LayoutOrder = 4, Size = UDim2.fromOffset(220, 54), ZIndex = 41 })
end

function UIBuilder.OpenPause()
	local participants = Remotes.State():GetAttribute("Participants") or 1
	pause.Note.Text = (participants <= 1 and Config.Run.SoloPauseFreezesRun) and "The run is paused." or "Group run: the swarm keeps coming while this menu is open!"
	show(pause.Overlay, "Pause", true)
	Remotes.Get("SetPause"):FireServer(true)
end

function UIBuilder.ClosePause()
	hide(pause.Overlay, "Pause")
	Remotes.Get("SetPause"):FireServer(false)
end

------------------------------------------------------------------------------------------
-- Revive offer
------------------------------------------------------------------------------------------

local revive: { [string]: any } = {}
local reviveDeadline = 0

local function buildRevive()
	local overlay, panel = modal("Revive", 440, 260, 45)
	revive.Overlay = overlay
	pad(panel, 18)
	new("UIListLayout", { Padding = UDim.new(0, 10), HorizontalAlignment = Enum.HorizontalAlignment.Center, SortOrder = Enum.SortOrder.LayoutOrder }, panel)
	label(panel, "YOU FELL!", 38, { TextColor3 = COLORS.Red, LayoutOrder = 1, ZIndex = 46 })
	revive.Text = label(panel, "Revive and keep fighting?", 20, { LayoutOrder = 2, TextColor3 = COLORS.Dim, ZIndex = 46 })
	local row = new("Frame", { Size = UDim2.new(1, 0, 0, 56), BackgroundTransparency = 1, LayoutOrder = 3, ZIndex = 46 }, panel)
	new("UIListLayout", { FillDirection = Enum.FillDirection.Horizontal, Padding = UDim.new(0, 12), HorizontalAlignment = Enum.HorizontalAlignment.Center }, row)
	revive.Buy = button(row, "Revive", COLORS.Green, function()
		local id = Config.Monetization.Products.Revive
		if id and id ~= 0 then
			MarketplaceService:PromptProductPurchase(player, id)
		end
	end, { Size = UDim2.fromOffset(180, 54), ZIndex = 47 })
	button(row, "No thanks", COLORS.Gray, function()
		Remotes.Get("ReviveDecline"):FireServer()
		hide(revive.Overlay, "Revive")
	end, { Size = UDim2.fromOffset(180, 54), ZIndex = 47 })
	revive.Timer = label(panel, "", 18, { LayoutOrder = 4, TextColor3 = COLORS.Dim, ZIndex = 46 })
end

local function onReviveOffer(data)
	if data.Close then
		hide(revive.Overlay, "Revive")
		return
	end
	reviveDeadline = os.clock() + (data.Seconds or 10)
	revive.Buy.Text = "Revive (R$)"
	pcall(function()
		local info = MarketplaceService:GetProductInfo(data.ProductId, Enum.InfoType.Product)
		if info and info.PriceInRobux then
			revive.Buy.Text = "Revive (R$" .. info.PriceInRobux .. ")"
		end
	end)
	show(revive.Overlay, "Revive", true)
end

------------------------------------------------------------------------------------------
-- Results
------------------------------------------------------------------------------------------

local results: { [string]: any } = {}
local resultsDeadline = 0

local function buildResults()
	local overlay, panel = modal("Results", 520, 480, 50)
	results.Overlay = overlay
	pad(panel, 22)
	new("UIListLayout", { Padding = UDim.new(0, 8), HorizontalAlignment = Enum.HorizontalAlignment.Center, SortOrder = Enum.SortOrder.LayoutOrder }, panel)
	results.Title = label(panel, "VICTORY", 52, { LayoutOrder = 1, ZIndex = 51 })
	results.Lines = {}
	for i = 1, 7 do
		results.Lines[i] = label(panel, "", 22, { LayoutOrder = 1 + i, ZIndex = 51, Font = Config.UI.BodyFont })
	end
	results.Button = button(panel, "Return to lobby", COLORS.Blue, function()
		Remotes.Get("ReturnToLobby"):FireServer()
		hide(results.Overlay, "Results")
	end, { LayoutOrder = 20, Size = UDim2.fromOffset(260, 56), ZIndex = 51 })
	results.Timer = label(panel, "", 16, { LayoutOrder = 21, TextColor3 = COLORS.Dim, ZIndex = 51 })
end

local function onRunResult(data)
	closeOffer()
	hide(revive.Overlay, "Revive")
	hide(pause.Overlay, "Pause")
	results.Title.Text = data.Won and "VICTORY!" or "DEFEATED"
	results.Title.TextColor3 = data.Won and COLORS.Gold or COLORS.Red
	local lines = {
		"Arena: " .. data.Arena,
		"Time survived: " .. formatTime(data.Time) .. (data.NewBest and "  (NEW BEST!)" or ""),
		"Kills: " .. data.Kills,
		"Gold earned: " .. data.Gold,
		"Level reached: " .. data.Level,
		"Damage dealt: " .. data.Damage,
		data.Unlocked and ("Unlocked: " .. data.Unlocked .. " arena!") or "",
	}
	for i, l in ipairs(results.Lines) do
		l.Text = lines[i] or ""
		l.TextColor3 = (i == 7) and COLORS.Gold or COLORS.Text
	end
	resultsDeadline = os.clock() + (data.Seconds or 20)
	show(results.Overlay, "Results", true)
end

------------------------------------------------------------------------------------------
-- Lobby panels: characters and shop
------------------------------------------------------------------------------------------

local panels: { [string]: any } = {}
local currentPanel: string? = nil

local function panelFrame(name: string, title: string): (Frame, ScrollingFrame, TextLabel)
	local overlay, panel = modal(name, 1100, 620, 35)
	local titleLabel = label(panel, title, 34, { Position = UDim2.fromOffset(0, 12), ZIndex = 36 })
	local gold = label(panel, "", 22, { Position = UDim2.fromOffset(20, 18), Size = UDim2.fromOffset(300, 28), TextXAlignment = Enum.TextXAlignment.Left, TextColor3 = COLORS.Gold, ZIndex = 36 })
	button(panel, "X", COLORS.Red, function()
		UIBuilder.ClosePanels()
	end, { AnchorPoint = Vector2.new(1, 0), Position = UDim2.new(1, -12, 0, 12), Size = UDim2.fromOffset(48, 48), ZIndex = 37 })
	local scroll = new("ScrollingFrame", {
		Position = UDim2.fromOffset(16, 70),
		Size = UDim2.new(1, -32, 1, -86),
		BackgroundTransparency = 1,
		ScrollBarThickness = 8,
		AutomaticCanvasSize = Enum.AutomaticSize.Y,
		CanvasSize = UDim2.new(),
		ScrollingDirection = Enum.ScrollingDirection.Y,
		ZIndex = 36,
	}, panel)
	table.insert(relayoutCallbacks, function()
		local v = virtualSize()
		panel.Size = UDim2.fromOffset(math.min(v.X - 24, 1100), math.min(v.Y - 24, 640))
	end)
	local _ = titleLabel
	return overlay, scroll, gold
end

local function characterPreview(parent: Instance, characterId: string, skinId: string?)
	local look = CharacterData.ResolveLook(characterId, skinId)
	local c = look.Colors
	local box = new("Frame", { Size = UDim2.fromOffset(110, 130), BackgroundTransparency = 1, LayoutOrder = 1, ZIndex = 37 }, parent)
	local function block(x, y, w, h, color)
		local f = new("Frame", { Position = UDim2.fromOffset(x, y), Size = UDim2.fromOffset(w, h), BackgroundColor3 = color, BorderSizePixel = 0, ZIndex = 38 }, box)
		corner(f, 3)
	end
	block(40, 4, 30, 14, c.Hat) -- hat
	block(42, 16, 26, 26, c.Head) -- head
	block(30, 44, 50, 46, c.Torso) -- torso
	block(14, 44, 14, 44, c.Arms)
	block(82, 44, 14, 44, c.Arms)
	block(32, 90, 21, 38, c.Legs)
	block(57, 90, 21, 38, c.Legs)
	block(30, 78, 50, 6, look.GoldTrim and COLORS.Gold or c.Accent) -- belt
end

local function refreshCharacters()
	local scroll: ScrollingFrame = panels.CharScroll
	for _, c in ipairs(scroll:GetChildren()) do
		if c:IsA("Frame") then
			c:Destroy()
		end
	end
	if not profile then
		return
	end
	local p = profile
	panels.CharGold.Text = "Gold " .. p.Gold
	for order, id in ipairs(CharacterData.Order) do
		local def = CharacterData.Characters[id]
		local owned = p.OwnedCharacters[id] == true
		local selected = p.SelectedCharacter == id
		local equipped = p.Skins[id] or "Default"
		local card = new("Frame", { Size = UDim2.fromOffset(250, 520), BackgroundColor3 = COLORS.PanelLight, LayoutOrder = order, ZIndex = 37 }, scroll)
		corner(card, 12)
		stroke(card, selected and COLORS.Gold or COLORS.Panel, selected and 3 or 2)
		pad(card, 10)
		new("UIListLayout", { Padding = UDim.new(0, 5), HorizontalAlignment = Enum.HorizontalAlignment.Center, SortOrder = Enum.SortOrder.LayoutOrder }, card)
		characterPreview(card, id, equipped)
		label(card, def.Name, 26, { LayoutOrder = 2, ZIndex = 38 })
		label(card, def.BonusText, 18, { LayoutOrder = 3, TextColor3 = COLORS.Green, ZIndex = 38 })
		label(card, def.Description, 15, { LayoutOrder = 4, TextColor3 = COLORS.Dim, Font = Config.UI.BodyFont, TextWrapped = true, Size = UDim2.new(1, 0, 0, 56), ZIndex = 38 })
		if not owned then
			local afford = p.Gold >= def.Cost
			button(card, "Buy " .. def.Cost .. "g", afford and COLORS.Green or COLORS.Gray, function()
				Remotes.Get("BuyCharacter"):FireServer(id)
			end, { LayoutOrder = 5, Size = UDim2.fromOffset(200, 44), ZIndex = 39 })
		elseif selected then
			button(card, "Selected", COLORS.Gold, function() end, { LayoutOrder = 5, Size = UDim2.fromOffset(200, 44), ZIndex = 39, AutoButtonColor = false, TextColor3 = Color3.fromRGB(40, 30, 0) })
		else
			button(card, "Select", COLORS.Blue, function()
				Remotes.Get("SelectCharacter"):FireServer(id)
			end, { LayoutOrder = 5, Size = UDim2.fromOffset(200, 44), ZIndex = 39 })
		end
		label(card, "Skins", 16, { LayoutOrder = 6, TextColor3 = COLORS.Dim, ZIndex = 38 })
		for skinOrder, skinId in ipairs(CharacterData.SkinsFor(id)) do
			local skin = CharacterData.Skins[skinId]
			local name = skin and skin.Name or "Default"
			local ownsSkin = p.OwnedSkins[skinId] == true
			local text, color, action
			if equipped == skinId then
				text, color = name .. "  (on)", COLORS.Gold
				action = function() end
			elseif ownsSkin then
				text, color = name, COLORS.Blue
				action = function()
					Remotes.Get("EquipSkin"):FireServer(id, skinId)
				end
			else
				local passId = skin and (skin.Pass == "StarterPack" and Config.Monetization.GamePasses.StarterPack or Config.Monetization.SkinPasses[skinId]) or 0
				if passId and passId ~= 0 then
					text, color = name .. "  (R$)", Color3.fromRGB(60, 160, 90)
					action = function()
						MarketplaceService:PromptGamePassPurchase(player, passId)
					end
				else
					text, color = name .. "  (soon)", COLORS.Gray
					action = function() end
				end
			end
			button(card, text, color, action, { LayoutOrder = 6 + skinOrder, Size = UDim2.fromOffset(220, 30), TextSize = 15, ZIndex = 39 })
		end
	end
end

local function pips(level: number, maxLevel: number): string
	return string.rep("#", level) .. string.rep("-", maxLevel - level)
end

local function refreshShop()
	local scroll: ScrollingFrame = panels.ShopScroll
	for _, c in ipairs(scroll:GetChildren()) do
		if c:IsA("Frame") or c:IsA("TextLabel") then
			c:Destroy()
		end
	end
	if not profile then
		return
	end
	local p = profile
	panels.ShopGold.Text = "Gold " .. p.Gold

	label(scroll, "Permanent upgrades (gold)", 22, { LayoutOrder = 1, TextColor3 = COLORS.Gold, ZIndex = 37 })
	local grid = new("Frame", { Size = UDim2.new(1, -10, 0, 0), AutomaticSize = Enum.AutomaticSize.Y, BackgroundTransparency = 1, LayoutOrder = 2, ZIndex = 37 }, scroll)
	new("UIGridLayout", { CellSize = UDim2.fromOffset(240, 170), CellPadding = UDim2.fromOffset(10, 10), SortOrder = Enum.SortOrder.LayoutOrder }, grid)
	for order, id in ipairs(MetaUpgradeData.Order) do
		local def = MetaUpgradeData.Upgrades[id]
		local level = p.Meta[id] or 0
		local cost = MetaUpgradeData.CostOf(id, level)
		local cell = new("Frame", { BackgroundColor3 = COLORS.PanelLight, LayoutOrder = order, ZIndex = 37 }, grid)
		corner(cell, 10)
		stroke(cell, def.Color, 2)
		pad(cell, 8)
		new("UIListLayout", { Padding = UDim.new(0, 3), HorizontalAlignment = Enum.HorizontalAlignment.Center, SortOrder = Enum.SortOrder.LayoutOrder }, cell)
		label(cell, def.Name, 22, { LayoutOrder = 1, TextColor3 = def.Color, ZIndex = 38 })
		label(cell, def.Description, 14, { LayoutOrder = 2, TextColor3 = COLORS.Dim, Font = Config.UI.BodyFont, TextWrapped = true, Size = UDim2.new(1, 0, 0, 36), ZIndex = 38 })
		label(cell, pips(level, def.MaxLevel) .. "  " .. level .. "/" .. def.MaxLevel, 16, { LayoutOrder = 3, ZIndex = 38, Font = Enum.Font.Code })
		if cost then
			button(cell, "Buy " .. cost .. "g", p.Gold >= cost and COLORS.Green or COLORS.Gray, function()
				Remotes.Get("BuyMeta"):FireServer(id)
			end, { LayoutOrder = 4, Size = UDim2.fromOffset(180, 40), ZIndex = 39 })
		else
			label(cell, "MAX", 22, { LayoutOrder = 4, TextColor3 = COLORS.Gold, ZIndex = 38 })
		end
	end

	label(scroll, "Robux shop (gold and cosmetics only)", 22, { LayoutOrder = 3, TextColor3 = Color3.fromRGB(120, 220, 140), ZIndex = 37 })
	local robux = new("Frame", { Size = UDim2.new(1, -10, 0, 0), AutomaticSize = Enum.AutomaticSize.Y, BackgroundTransparency = 1, LayoutOrder = 4, ZIndex = 37 }, scroll)
	new("UIGridLayout", { CellSize = UDim2.fromOffset(240, 110), CellPadding = UDim2.fromOffset(10, 10), SortOrder = Enum.SortOrder.LayoutOrder }, robux)
	local items = {
		{ Name = "500 Gold", Kind = "Product", Id = Config.Monetization.Products.Gold500, Desc = "A pouch of gold." },
		{ Name = "1500 Gold", Kind = "Product", Id = Config.Monetization.Products.Gold1500, Desc = "A sack of gold." },
		{ Name = "5000 Gold", Kind = "Product", Id = Config.Monetization.Products.Gold5000, Desc = "A chest of gold." },
		{ Name = "Starter Pack", Kind = "Pass", Key = "StarterPack", Id = Config.Monetization.GamePasses.StarterPack, Desc = "+25% gold forever + Gold Trim skins." },
		{ Name = "VIP", Kind = "Pass", Key = "VIP", Id = Config.Monetization.GamePasses.VIP, Desc = "+1 reroll per run, chat tag, lobby crown." },
		{ Name = "2x Gold", Kind = "Pass", Key = "DoubleGold", Id = Config.Monetization.GamePasses.DoubleGold, Desc = "Double gold from runs." },
	}
	for order, item in ipairs(items) do
		local cell = new("Frame", { BackgroundColor3 = COLORS.PanelLight, LayoutOrder = order, ZIndex = 37 }, robux)
		corner(cell, 10)
		pad(cell, 8)
		new("UIListLayout", { Padding = UDim.new(0, 3), HorizontalAlignment = Enum.HorizontalAlignment.Center, SortOrder = Enum.SortOrder.LayoutOrder }, cell)
		label(cell, item.Name, 20, { LayoutOrder = 1, ZIndex = 38 })
		label(cell, item.Desc, 13, { LayoutOrder = 2, TextColor3 = COLORS.Dim, Font = Config.UI.BodyFont, TextWrapped = true, Size = UDim2.new(1, 0, 0, 30), ZIndex = 38 })
		local owned = item.Kind == "Pass" and p.Passes[item.Key] == true
		if owned then
			label(cell, "Owned", 18, { LayoutOrder = 3, TextColor3 = COLORS.Gold, ZIndex = 38 })
		elseif not item.Id or item.Id == 0 then
			label(cell, "Not set up yet", 16, { LayoutOrder = 3, TextColor3 = COLORS.Gray, ZIndex = 38 })
		else
			button(cell, "Buy (R$)", Color3.fromRGB(60, 160, 90), function()
				if item.Kind == "Pass" then
					MarketplaceService:PromptGamePassPurchase(player, item.Id)
				else
					MarketplaceService:PromptProductPurchase(player, item.Id)
				end
			end, { LayoutOrder = 3, Size = UDim2.fromOffset(160, 34), TextSize = 18, ZIndex = 39 })
		end
	end
	if p.MemoryOnly then
		label(scroll, "Studio test: DataStores are off, progress will not be saved.", 16, { LayoutOrder = 5, TextColor3 = COLORS.Red, ZIndex = 37 })
	end
end

local function buildPanels()
	local overlay, scroll, gold = panelFrame("Characters", "CHARACTERS")
	new("UIGridLayout", { CellSize = UDim2.fromOffset(250, 520), CellPadding = UDim2.fromOffset(12, 12), SortOrder = Enum.SortOrder.LayoutOrder, HorizontalAlignment = Enum.HorizontalAlignment.Center }, scroll)
	panels.Characters = overlay
	panels.CharScroll = scroll
	panels.CharGold = gold

	local overlay2, scroll2, gold2 = panelFrame("Shop", "UPGRADES")
	new("UIListLayout", { Padding = UDim.new(0, 10), SortOrder = Enum.SortOrder.LayoutOrder }, scroll2)
	panels.Shop = overlay2
	panels.ShopScroll = scroll2
	panels.ShopGold = gold2
end

function UIBuilder.OpenPanel(name: string)
	if player:GetAttribute("InRun") then
		return
	end
	UIBuilder.ClosePanels()
	local overlay = panels[name]
	if not overlay then
		return
	end
	currentPanel = name
	if name == "Characters" then
		refreshCharacters()
	else
		refreshShop()
	end
	show(overlay, "Panel", true)
	Remotes.Get("RequestProfile"):FireServer()
end

function UIBuilder.ClosePanels()
	currentPanel = nil
	panels.Characters.Visible = false
	panels.Shop.Visible = false
	setBlocking("Panel", false)
end

------------------------------------------------------------------------------------------
-- Stats sign (a SurfaceGui on the lobby lectern, drawn only for this player)
------------------------------------------------------------------------------------------

local statsSign: { [string]: TextLabel } = {}

local function buildStatsSign()
	task.spawn(function()
		local map = workspace:WaitForChild("SwarmMap")
		local lobby = map:WaitForChild("Lobby")
		local sign = lobby:WaitForChild("StatsSign") :: BasePart
		local surface = new("SurfaceGui", {
			Name = "SwarmStats",
			Adornee = sign,
			Face = Enum.NormalId.Back,
			SizingMode = Enum.SurfaceGuiSizingMode.PixelsPerStud,
			PixelsPerStud = 50,
			LightInfluence = 0,
			ResetOnSpawn = false,
		}, player:WaitForChild("PlayerGui"))
		local frame = new("Frame", { Size = UDim2.fromScale(1, 1), BackgroundColor3 = Color3.fromRGB(25, 25, 38) }, surface)
		pad(frame, 16)
		new("UIListLayout", { Padding = UDim.new(0, 4), HorizontalAlignment = Enum.HorizontalAlignment.Center }, frame)
		label(frame, "YOUR STATS", 40, { TextColor3 = COLORS.Gold })
		for _, key in ipairs({ "Best", "Wins", "Runs", "Kills", "Gold" }) do
			statsSign[key] = label(frame, "", 28)
		end
		UIBuilder.RefreshProfileViews()
	end)
end

------------------------------------------------------------------------------------------
-- Profile + state driven refresh
------------------------------------------------------------------------------------------

function UIBuilder.RefreshProfileViews()
	if not profile then
		return
	end
	local p = profile
	lobbyUi.Gold.Text = "Gold " .. p.Gold
	if statsSign.Best then
		statsSign.Best.Text = "Best time: " .. formatTime(p.Stats.BestTime)
		statsSign.Wins.Text = "Wins: " .. p.Stats.Wins
		statsSign.Runs.Text = "Runs: " .. p.Stats.Runs
		statsSign.Kills.Text = "Total kills: " .. p.Stats.TotalKills
		statsSign.Gold.Text = "Gold: " .. p.Gold
	end
	if currentPanel == "Characters" then
		refreshCharacters()
	elseif currentPanel == "Shop" then
		refreshShop()
	end
end

local function onProfile(data)
	profile = data
	if data.Settings then
		volumes.Music = data.Settings.Music
		volumes.Sfx = data.Settings.Sfx
		if pause.Music then
			pause.Music()
			pause.Sfx()
		end
		if deps.Audio then
			deps.Audio.SetVolumes(volumes.Music, volumes.Sfx)
		end
	end
	UIBuilder.RefreshProfileViews()
end

local function updateFrame()
	local state = Remotes.State()
	local phase = state:GetAttribute("Phase") or "Lobby"
	local inRun = player:GetAttribute("InRun") == true

	hud.Frame.Visible = inRun
	lobbyUi.Frame.Visible = not inRun

	if inRun then
		local runTime = state:GetAttribute("RunTime") or 0
		hud.Timer.Text = formatTime(runTime)
		local xp, need = player:GetAttribute("XP") or 0, player:GetAttribute("XPNeeded") or 1
		hud.XPFill.Size = UDim2.fromScale(math.clamp(xp / math.max(1, need), 0, 1), 1)
		hud.Level.Text = "LV " .. tostring(player:GetAttribute("Level") or 1)
		hud.Counters.Text = string.format("Kills %d   Gold %d", player:GetAttribute("Kills") or 0, player:GetAttribute("RunGold") or 0)
		local bossMax = state:GetAttribute("BossMaxHP") or 0
		hud.Boss.Visible = bossMax > 0
		if bossMax > 0 then
			hud.BossFill.Size = UDim2.fromScale(math.clamp((state:GetAttribute("BossHP") or 0) / bossMax, 0, 1), 1)
		end
		local status = ""
		if state:GetAttribute("Frozen") then
			status = "PAUSED"
		elseif player:GetAttribute("Alive") == false and not revive.Overlay.Visible and phase == "Running" then
			status = "You fell. Spectating your team..."
		end
		hud.Status.Text = status
		hud.Status.Visible = status ~= ""
	else
		if phase == "Countdown" then
			lobbyUi.Banner.Visible = true
			lobbyUi.CountdownText.Text = "Run starts in " .. tostring(state:GetAttribute("Countdown") or 0)
			lobbyUi.JoinButton.Visible = not joinedCountdown
			lobbyUi.Info.Text = joinedCountdown and "You're in! Get ready..." or ""
		else
			lobbyUi.Banner.Visible = false
			joinedCountdown = false
			if phase == "Running" or phase == "Results" then
				lobbyUi.Info.Text = "A run is in progress (" .. formatTime(state:GetAttribute("RunTime") or 0) .. "). Wait here for the next one!"
			else
				lobbyUi.Info.Text = "Step on the green pad to start a run!"
			end
		end
	end

	if levelUp.Overlay.Visible then
		levelUp.Sub.Text = string.format("Choose an upgrade (auto-pick in %ds)", math.max(0, math.ceil(offerDeadline - os.clock())))
	end
	if revive.Overlay.Visible then
		local left = math.max(0, math.ceil(reviveDeadline - os.clock()))
		revive.Timer.Text = left .. "s"
		if left <= 0 then
			hide(revive.Overlay, "Revive")
		end
	end
	if results.Overlay.Visible then
		results.Timer.Text = "Back to the lobby in " .. math.max(0, math.ceil(resultsDeadline - os.clock())) .. "s"
		if not inRun then
			hide(results.Overlay, "Results")
		end
	end
	if pause.Overlay.Visible and not inRun then
		hide(pause.Overlay, "Pause")
	end
	if (panels.Characters.Visible or panels.Shop.Visible) and inRun then
		UIBuilder.ClosePanels()
	end
end

------------------------------------------------------------------------------------------
-- Init
------------------------------------------------------------------------------------------

function UIBuilder.Init(d: { [string]: any })
	deps = d
	gui = new("ScreenGui", {
		Name = "SwarmUI",
		ResetOnSpawn = false,
		IgnoreGuiInset = false,
		ScreenInsets = Enum.ScreenInsets.DeviceSafeInsets,
		ZIndexBehavior = Enum.ZIndexBehavior.Sibling,
		DisplayOrder = 10,
	}, player:WaitForChild("PlayerGui"))
	root = new("Frame", { Name = "Root", Size = UDim2.fromScale(1, 1), BackgroundTransparency = 1 }, gui)
	uiScale = new("UIScale", { Scale = 1 }, root)
	if deps.MobileControls then
		deps.MobileControls.SetScale(uiScale)
	end

	buildHud()
	buildLobbyHud()
	buildToasts()
	buildLevelUp()
	buildChest()
	buildPause()
	buildRevive()
	buildResults()
	buildPanels()
	buildStatsSign()

	gui:GetPropertyChangedSignal("AbsoluteSize"):Connect(updateScale)
	updateScale()

	Remotes.Get("Inventory").OnClientEvent:Connect(function(data)
		inventory = data
		refreshInventory()
	end)
	Remotes.Get("LevelUpOffer").OnClientEvent:Connect(showOffer)
	Remotes.Get("LevelUpClose").OnClientEvent:Connect(closeOffer)
	Remotes.Get("ChestOpened").OnClientEvent:Connect(UIBuilder.ShowChest)
	Remotes.Get("Notify").OnClientEvent:Connect(function(data)
		if type(data) == "table" and type(data.Text) == "string" then
			UIBuilder.Toast(data.Text, data.Color, data.Big)
		end
	end)
	Remotes.Get("RunResult").OnClientEvent:Connect(onRunResult)
	Remotes.Get("ProfileSync").OnClientEvent:Connect(onProfile)
	Remotes.Get("ReviveOffer").OnClientEvent:Connect(onReviveOffer)
	Remotes.Get("OpenPanel").OnClientEvent:Connect(function(name)
		if name == "Joined" then
			joinedCountdown = true
		else
			UIBuilder.OpenPanel(name)
		end
	end)

	-- Leaving a run clears the HUD inventory.
	player:GetAttributeChangedSignal("InRun"):Connect(function()
		if not player:GetAttribute("InRun") then
			inventory = nil
			refreshInventory()
			closeOffer()
		end
	end)

	RunService.RenderStepped:Connect(updateFrame)
	Remotes.Get("RequestProfile"):FireServer()
end

return UIBuilder
