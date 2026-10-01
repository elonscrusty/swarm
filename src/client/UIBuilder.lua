--[[
	UIBuilder.lua
	Builds every in-run screen in code: HUD (with the upgrade bar at the bottom), level-up
	cards, chest animation, pause / settings menu, revive offer, win/lose screen, and hosts
	the lobby menu (LobbyScreen) and the DEV button (DevPanel). Shared helpers: UIKit.

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
local WeaponData = require(Shared:WaitForChild("WeaponData"))
local UIAnim = require(script.Parent.UIAnim)
local UIKit = require(script.Parent.UIKit)
local LobbyScreen = require(script.Parent.LobbyScreen)
local DevPanel = require(script.Parent.DevPanel)

local UIBuilder = {}

local player = Players.LocalPlayer
local deps: { [string]: any } = {}

local gui: ScreenGui
local root: Frame
local uiScale: UIScale
local portrait = false

local profile: { [string]: any }? = nil
local inventory: { [string]: any }? = nil

-- Open modals that should stop movement.
local blocking: { [string]: boolean } = {}

local COLORS = UIKit.COLORS

------------------------------------------------------------------------------------------
-- Helpers (UIKit)
------------------------------------------------------------------------------------------

local new, corner, stroke, pad, label, button = UIKit.new, UIKit.corner, UIKit.stroke, UIKit.pad, UIKit.label, UIKit.button
local formatTime = UIKit.formatTime

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

-- Opening: the dark backdrop fades in and the panel pops up with a little overshoot.
local function show(overlay: GuiObject, name: string, blocks: boolean)
	overlay:SetAttribute("AnimToken", (tonumber(overlay:GetAttribute("AnimToken")) or 0) + 1)
	overlay:SetAttribute("Hiding", nil)
	local wasVisible = overlay.Visible
	overlay.Visible = true
	if not wasVisible then
		UIAnim.FadeIn(overlay, tonumber(overlay:GetAttribute("BackdropTransparency")) or 0.45)
		local panel = overlay:FindFirstChild("Panel")
		if panel and panel:IsA("GuiObject") then
			UIAnim.Pop(panel, 0, 0.7)
		end
	end
	if blocks then
		setBlocking(name, true)
	end
end

-- Closing: the panel shrinks away, then the overlay hides (unless reopened meanwhile).
-- Safe to call every frame: a close that is already animating is left to finish
-- (restarting it each frame used to keep the results screen on forever).
local function hide(overlay: GuiObject, name: string)
	setBlocking(name, false)
	if not overlay.Visible or overlay:GetAttribute("Hiding") then
		return
	end
	local token = (tonumber(overlay:GetAttribute("AnimToken")) or 0) + 1
	overlay:SetAttribute("AnimToken", token)
	local panel = overlay:FindFirstChild("Panel")
	if panel and panel:IsA("GuiObject") then
		overlay:SetAttribute("Hiding", true)
		UIAnim.PopOut(panel, function()
			if overlay:GetAttribute("AnimToken") == token then
				overlay:SetAttribute("Hiding", nil)
				overlay.Visible = false
			end
		end)
	else
		overlay.Visible = false
	end
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
	-- white "damage trail" that slides down behind the red fill
	hud.BossTrail = new("Frame", { Size = UDim2.fromScale(1, 1), BackgroundColor3 = Color3.fromRGB(255, 240, 240), BorderSizePixel = 0 }, bossBack)
	corner(hud.BossTrail, 6)
	hud.BossFill = new("Frame", { Size = UDim2.fromScale(1, 1), BackgroundColor3 = Color3.fromRGB(220, 30, 50), BorderSizePixel = 0 }, bossBack)
	corner(hud.BossFill, 6)
	label(bossBack, "SCORPION QUEEN", 16, { Size = UDim2.fromScale(1, 1), ZIndex = 2, TextStrokeTransparency = 0.3 })
	hud.Boss = bossBack

	-- Kills + gold (top left)
	hud.Counters = label(frame, "Kills 0   Gold 0", 20, {
		Position = UDim2.fromOffset(12, 24),
		Size = UDim2.fromOffset(320, 26),
		TextXAlignment = Enum.TextXAlignment.Left,
		TextStrokeTransparency = 0.5,
	})

	-- Upgrade bar: weapons (top row) and passives (bottom row), bottom centre. Nothing in
	-- it is Active, so a thumb that lands on it still drives the floating thumbstick.
	local wt, pt = Config.UI.BarWeaponTile, Config.UI.BarPassiveTile
	local bar = new("Frame", {
		Name = "UpgradeBar",
		AnchorPoint = Vector2.new(0.5, 1),
		Position = UDim2.new(0.5, 0, 1, -10),
		Size = UDim2.new(1, -20, 0, wt + pt + 8),
		BackgroundTransparency = 1,
		Active = false,
	}, frame)
	new("UIListLayout", { Padding = UDim.new(0, 8), HorizontalAlignment = Enum.HorizontalAlignment.Center, VerticalAlignment = Enum.VerticalAlignment.Bottom, SortOrder = Enum.SortOrder.LayoutOrder }, bar)
	hud.WeaponRow = new("Frame", { Name = "Weapons", Size = UDim2.new(1, 0, 0, wt), BackgroundTransparency = 1, LayoutOrder = 1 }, bar)
	new("UIListLayout", { FillDirection = Enum.FillDirection.Horizontal, Padding = UDim.new(0, 8), HorizontalAlignment = Enum.HorizontalAlignment.Center, SortOrder = Enum.SortOrder.LayoutOrder }, hud.WeaponRow)
	hud.PassiveRow = new("Frame", { Name = "Passives", Size = UDim2.new(1, 0, 0, pt), BackgroundTransparency = 1, LayoutOrder = 2 }, bar)
	new("UIListLayout", { FillDirection = Enum.FillDirection.Horizontal, Padding = UDim.new(0, 6), HorizontalAlignment = Enum.HorizontalAlignment.Center, SortOrder = Enum.SortOrder.LayoutOrder }, hud.PassiveRow)
	hud.Bar = bar

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
		Position = UDim2.new(0.5, 0, 1, -(Config.UI.BarWeaponTile + Config.UI.BarPassiveTile + 50)),
		Size = UDim2.fromOffset(700, 40),
		TextColor3 = Color3.fromRGB(255, 200, 200),
		TextStrokeTransparency = 0.3,
		Visible = false,
	})

	-- Red flash when hurt
	hud.Hurt = new("Frame", { Size = UDim2.fromScale(1, 1), BackgroundColor3 = Color3.fromRGB(255, 0, 0), BackgroundTransparency = 1, ZIndex = 0 }, frame)
end

-- Icon key of an inventory weapon: its evolution once evolved.
local function weaponIconId(id: string, evolved: boolean): string
	local def = WeaponData.Weapons[id]
	if evolved and def and def.Evolution then
		return def.Evolution.Id
	end
	return id
end

local shownLevels: { [string]: number } = {}

local function refreshInventory()
	for _, row in ipairs({ hud.WeaponRow, hud.PassiveRow }) do
		for _, c in ipairs(row:GetChildren()) do
			if c:IsA("Frame") then
				c:Destroy()
			end
		end
	end
	if not inventory then
		table.clear(shownLevels)
		return
	end
	-- tiles that are new or just levelled up pop in
	local function popIfChanged(tile: GuiObject, key: string, level: number)
		if shownLevels[key] ~= level then
			UIAnim.Pop(tile, 0, shownLevels[key] and 1.4 or 0.3)
			shownLevels[key] = level
		end
	end
	for i, w in ipairs(inventory.Weapons) do
		local t = UIKit.IconTile(hud.WeaponRow, { Id = weaponIconId(w.Id, w.Evolved), Name = w.Name, Color = w.Color, Size = Config.UI.BarWeaponTile, Level = w.Level, Evolved = w.Evolved })
		t.LayoutOrder = i
		popIfChanged(t, "W" .. w.Id, w.Level + (w.Evolved and 10 or 0))
	end
	for i, p in ipairs(inventory.Passives) do
		local t = UIKit.IconTile(hud.PassiveRow, { Id = p.Id, Name = p.Name, Color = p.Color, Size = Config.UI.BarPassiveTile, Level = p.Level })
		t.LayoutOrder = i
		popIfChanged(t, "P" .. p.Id, p.Level)
	end
end

function UIBuilder.HurtFlash()
	hud.Hurt.BackgroundTransparency = 0.65
	TweenService:Create(hud.Hurt, TweenInfo.new(0.35), { BackgroundTransparency = 1 }):Play()
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
		UIAnim.Punch(bigBanner, 0.8)
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
	UIAnim.Pop(t, 0, 0.5)
	t.TextTransparency = 1
	t.BackgroundTransparency = 1
	UIAnim.Tween(t, 0.2, { TextTransparency = 0, BackgroundTransparency = 0.5 })
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
	-- upgrade icon (IconData picture or placeholder); evolutions show the evolved icon
	local iconId = c.Id
	if c.Type == "Evolve" then
		local def = WeaponData.Weapons[c.Id]
		iconId = def and def.Evolution and def.Evolution.Id or c.Id
	elseif c.Type == "Gold" or c.Type == "Heal" then
		iconId = c.Type
	end
	local iconOpts: UIKit.IconOpts = {
		Id = iconId,
		Name = c.Name,
		Color = c.Color,
		Size = portrait and 44 or 84,
		Level = (c.Type == "WeaponUp" or c.Type == "PassiveUp") and c.Level or nil,
		Evolved = c.Type == "Evolve",
	}
	local levelText = ""
	if c.Type == "WeaponNew" or c.Type == "PassiveNew" then
		levelText = "NEW!"
	elseif c.Type == "WeaponUp" or c.Type == "PassiveUp" then
		levelText = "Level " .. c.Level
	elseif c.Type == "Evolve" then
		levelText = "EVOLUTION"
	end
	local title = c.Name .. (levelText ~= "" and ("  -  " .. levelText) or "")
	if portrait then
		-- portrait cards are short: icon and name share a row
		local row = new("Frame", { Size = UDim2.new(1, 0, 0, 44), BackgroundTransparency = 1, LayoutOrder = 3, ZIndex = 33 }, card)
		new("UIListLayout", { FillDirection = Enum.FillDirection.Horizontal, Padding = UDim.new(0, 10), VerticalAlignment = Enum.VerticalAlignment.Center, SortOrder = Enum.SortOrder.LayoutOrder }, row)
		UIKit.IconTile(row, iconOpts).LayoutOrder = 1
		label(row, title, 24, { LayoutOrder = 2, ZIndex = 33, TextWrapped = true, TextXAlignment = Enum.TextXAlignment.Left, Size = UDim2.new(1, -54, 0, 44) })
	else
		local icon = UIKit.IconTile(card, iconOpts)
		icon.LayoutOrder = 2
		UIAnim.Pop(icon, 0.08 * index + 0.15, 0.4)
		label(card, title, 24, { LayoutOrder = 3, ZIndex = 33, TextWrapped = true, Size = UDim2.new(1, 0, 0, 30) })
	end
	label(card, c.Description, 18, {
		LayoutOrder = 4,
		ZIndex = 33,
		TextWrapped = true,
		TextColor3 = COLORS.Dim,
		Font = Config.UI.BodyFont,
		Size = UDim2.new(1, 0, 0, portrait and 50 or 120),
		TextYAlignment = Enum.TextYAlignment.Top,
	})
	-- cards spin in one after another; evolutions get a pulsing glow
	UIAnim.Pop(card, 0.08 * (index - 1), 0.3)
	card.Rotation = (index % 2 == 0) and 8 or -8
	task.delay(0.08 * (index - 1), function()
		UIAnim.Tween(card, 0.4, { Rotation = 0 }, Enum.EasingStyle.Back)
	end)
	if c.Rarity == "Legendary" or c.Rarity == "Epic" then
		local st = card:FindFirstChildOfClass("UIStroke")
		if st then
			UIAnim.PulseStroke(st, 3, 7)
		end
	end
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
	UIAnim.Punch(levelUp.Title, 0.5)
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
	UIAnim.Pop(chest.Panel, 0, 0.4)
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
	pause.Title = label(panel, "PAUSED", 36, { LayoutOrder = 0, ZIndex = 41 })
	slider(panel, "Music", "Music", 1)
	slider(panel, "Sound effects", "Sfx", 2)
	pause.Note = label(panel, "", 16, { LayoutOrder = 3, TextColor3 = COLORS.Dim, Font = Config.UI.BodyFont, TextWrapped = true, Size = UDim2.new(1, 0, 0, 40), ZIndex = 41 })
	pause.Resume = button(panel, "Resume", COLORS.Green, function()
		UIBuilder.ClosePause()
	end, { LayoutOrder = 4, Size = UDim2.fromOffset(220, 54), ZIndex = 41 })
end

-- The same menu is the in-run pause menu and the lobby SETTINGS screen.
local pauseMode = "Pause" -- "Pause" | "Settings"

function UIBuilder.OpenPause()
	pauseMode = "Pause"
	pause.Title.Text = "PAUSED"
	pause.Resume.Text = "Resume"
	local participants = Remotes.State():GetAttribute("Participants") or 1
	pause.Note.Text = (participants <= 1 and Config.Run.SoloPauseFreezesRun) and "The run is paused." or "Group run: the swarm keeps coming while this menu is open!"
	show(pause.Overlay, "Pause", true)
	Remotes.Get("SetPause"):FireServer(true)
end

function UIBuilder.OpenSettings()
	pauseMode = "Settings"
	pause.Title.Text = "SETTINGS"
	pause.Resume.Text = "Close"
	pause.Note.Text = "Volume is saved with your progress."
	show(pause.Overlay, "Pause", true)
end

function UIBuilder.ClosePause()
	hide(pause.Overlay, "Pause")
	if pauseMode == "Pause" then
		Remotes.Get("SetPause"):FireServer(false)
	end
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
	-- title drops in, then the numbers count up one after another
	UIAnim.Pop(results.Title, 0.1, 2)
	UIAnim.CountUp(results.Lines[3], data.Kills, "Kills: %d", 0.8, 0.4)
	UIAnim.CountUp(results.Lines[4], data.Gold, "Gold earned: %d", 0.8, 0.7)
	UIAnim.CountUp(results.Lines[5], data.Level, "Level reached: %d", 0.6, 1.0)
	UIAnim.CountUp(results.Lines[6], data.Damage, "Damage dealt: %d", 0.8, 1.2)
	if data.NewBest then
		UIAnim.Punch(results.Lines[2], 0.4)
	end
end

------------------------------------------------------------------------------------------
-- Lobby (LobbyScreen) entry points kept for older callers
------------------------------------------------------------------------------------------

-- "Characters" | "Shop" / "Upgrades": jumps to that lobby screen.
function UIBuilder.OpenPanel(name: string)
	if player:GetAttribute("InRun") then
		return
	end
	LobbyScreen.Show(name)
end

function UIBuilder.ClosePanels()
	LobbyScreen.Show("Home")
end

------------------------------------------------------------------------------------------
-- Stats sign (a SurfaceGui on the lobby lectern, drawn only for this player)
------------------------------------------------------------------------------------------

local statsSign: { [string]: TextLabel } = {}

local function buildStatsSign()
	task.spawn(function()
		local map = workspace:WaitForChild("SwarmMap", 30)
		local lobby = map and map:WaitForChild("Lobby", 30)
		local sign = lobby and lobby:WaitForChild("StatsSign", 30)
		if not sign or not sign:IsA("BasePart") then
			return -- the lobby has no stats lectern any more
		end
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
	LobbyScreen.SetProfile(p)
	if statsSign.Best then
		statsSign.Best.Text = "Best time: " .. formatTime(p.Stats.BestTime)
		statsSign.Wins.Text = "Wins: " .. p.Stats.Wins
		statsSign.Runs.Text = "Runs: " .. p.Stats.Runs
		statsSign.Kills.Text = "Total kills: " .. p.Stats.TotalKills
		statsSign.Gold.Text = "Gold: " .. p.Gold
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

-- Values the HUD animates toward each frame.
local anim: { [string]: any } = { XP = 0 }
local frameDt = 1 / 60

local function updateFrame(dt: number)
	frameDt = dt
	local state = Remotes.State()
	local phase = state:GetAttribute("Phase") or "Lobby"
	local inRun = player:GetAttribute("InRun") == true

	hud.Frame.Visible = inRun
	if anim.InRun ~= inRun then
		anim.InRun = inRun
		-- the lobby is a menu: no thumbstick / walking there
		setBlocking("Lobby", not inRun)
		LobbyScreen.SetVisible(not inRun)
	end

	if inRun then
		local runTime = state:GetAttribute("RunTime") or 0
		hud.Timer.Text = formatTime(runTime)
		local minute = math.floor(runTime / 60)
		if minute ~= anim.Minute then
			if anim.Minute ~= nil then
				UIAnim.Punch(hud.Timer, 0.35)
			end
			anim.Minute = minute
		end
		-- the timer glows red in the last 10 seconds before the boss
		local toBoss = Config.Run.BossTime - runTime
		if toBoss > 0 and toBoss <= 10 then
			hud.Timer.TextColor3 = COLORS.Text:Lerp(COLORS.Red, 0.5 + 0.5 * math.sin(os.clock() * 10))
		else
			hud.Timer.TextColor3 = COLORS.Text
		end

		-- XP bar glides to its value; on a level up it fills, flashes white and resets
		local level = player:GetAttribute("Level") or 1
		local xp, need = player:GetAttribute("XP") or 0, player:GetAttribute("XPNeeded") or 1
		local target = math.clamp(xp / math.max(1, need), 0, 1)
		if anim.Level ~= nil and level > anim.Level then
			anim.XP = 0
			hud.XPFill.BackgroundColor3 = Color3.new(1, 1, 1)
			UIAnim.Tween(hud.XPFill, 0.5, { BackgroundColor3 = COLORS.XP })
			UIAnim.Punch(hud.Level, 0.6)
		end
		anim.Level = level
		anim.XP += (target - anim.XP) * math.min(1, frameDt * 10)
		hud.XPFill.Size = UDim2.fromScale(anim.XP, 1)
		hud.Level.Text = "LV " .. tostring(level)

		local kills, gold = player:GetAttribute("Kills") or 0, player:GetAttribute("RunGold") or 0
		if anim.Gold ~= nil and gold > anim.Gold then
			UIAnim.Punch(hud.Counters, 0.12)
		end
		anim.Gold = gold
		hud.Counters.Text = string.format("Kills %d   Gold %d", kills, gold)
		local bossMax = state:GetAttribute("BossMaxHP") or 0
		hud.Boss.Visible = bossMax > 0
		if bossMax > 0 then
			local frac = math.clamp((state:GetAttribute("BossHP") or 0) / bossMax, 0, 1)
			if not anim.BossShown then
				anim.BossShown = true
				anim.BossTrail = 1
				UIAnim.Pop(hud.Boss, 0, 0.3)
			end
			hud.BossFill.Size = UDim2.fromScale(frac, 1)
			anim.BossTrail = math.max(frac, anim.BossTrail - frameDt * 0.25)
			hud.BossTrail.Size = UDim2.fromScale(anim.BossTrail, 1)
		else
			anim.BossShown = false
		end
		local status = ""
		if state:GetAttribute("Frozen") then
			status = state:GetAttribute("LevelUpPause") and "PAUSED: a teammate is choosing an upgrade" or "PAUSED"
		elseif player:GetAttribute("Alive") == false and not revive.Overlay.Visible and phase == "Running" then
			local progress = player:GetAttribute("ReviveProgress") or 0
			if progress > 0 then
				status = string.format("A teammate is reviving you... %d%%", math.floor(progress * 100))
			elseif (player:GetAttribute("PartnerRevivesLeft") or 0) > 0 then
				status = "You fell! A teammate can revive you by standing next to you."
			else
				status = "You fell. Spectating your team..."
			end
		end
		hud.Status.Text = status
		hud.Status.Visible = status ~= ""
	else
		LobbyScreen.Update()
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
	-- the pause menu belongs to the run, the settings menu to the lobby
	if pause.Overlay.Visible and (pauseMode == "Pause") ~= inRun then
		hide(pause.Overlay, "Pause")
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
	UIKit.SetAudio(deps.Audio)

	buildHud()
	LobbyScreen.Init({
		Root = root,
		Audio = deps.Audio,
		VirtualSize = virtualSize,
		IsPortrait = function()
			return portrait
		end,
		OnRelayout = function(fn: () -> ())
			table.insert(relayoutCallbacks, fn)
		end,
		OpenSettings = UIBuilder.OpenSettings,
		Toast = function(text: string, color: Color3?)
			UIBuilder.Toast(text, color)
		end,
	})
	buildToasts()
	buildLevelUp()
	buildChest()
	buildPause()
	buildRevive()
	buildResults()
	buildStatsSign()
	DevPanel.Init(root)

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
			LobbyScreen.SetJoined(true)
		elseif type(name) == "string" then
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
