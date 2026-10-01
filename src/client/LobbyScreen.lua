--[[
	LobbyScreen.lua
	The 2D lobby menu, shown full-screen whenever the player is not in a run. The 3D lobby
	stays behind it as a scenic backdrop (CameraController points the camera at it).

	Screens (they slide into each other):
	  Home        top bar (gold, best time, wins, SETTINGS), the player's own character big in
	              the middle (turning 3D preview), permanent upgrade summary, SOLO / DUO /
	              TRIO buttons, CHARACTERS / UPGRADES / ARENA buttons. During a countdown
	              the mode buttons become a "who joined" panel with JOIN / START NOW; while
	              another run is going it says "A run is in progress (m:ss)".
	  Characters  one card per character: turning 3D preview, name, role, description,
	              starting weapon, bonus, buy / select, skins.
	  Upgrades    permanent gold upgrades + the Robux shop (gold and cosmetics only).

	Everything sent to the server is an id or a mode name; the server validates it
	(RunManager: StartRun / StartNow / CycleArena, GoldSystem: purchases and selection).
	UIBuilder owns the root, scaling and the profile; it calls Init / SetProfile / Update.
]]

local Players = game:GetService("Players")
local MarketplaceService = game:GetService("MarketplaceService")
local TweenService = game:GetService("TweenService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared:WaitForChild("Config"))
local Remotes = require(Shared:WaitForChild("Remotes"))
local CharacterData = require(Shared:WaitForChild("CharacterData"))
local MetaUpgradeData = require(Shared:WaitForChild("MetaUpgradeData"))
local WeaponData = require(Shared:WaitForChild("WeaponData"))
local UIKit = require(script.Parent.UIKit)
local UIAnim = require(script.Parent.UIAnim)
local ViewportPreview = require(script.Parent.ViewportPreview)

local LobbyScreen = {}

local player = Players.LocalPlayer
local new, corner, stroke, pad, label, button = UIKit.new, UIKit.corner, UIKit.stroke, UIKit.pad, UIKit.label, UIKit.button
local COLORS = UIKit.COLORS

local TOP = 76 -- height of the top bar area (reference pixels)
local MARGIN = 20

local MODE_STYLE = {
	Solo = { Color = Color3.fromRGB(60, 185, 100), Sub = "Start right now" },
	Duo = { Color = Color3.fromRGB(60, 130, 225), Sub = "2 players + revives" },
	Trio = { Color = Color3.fromRGB(140, 80, 220), Sub = "3 players + revives" },
}

-- Set by UIBuilder.
local host: { [string]: any } = {}
local profile: { [string]: any }? = nil
local joinedCountdown = false
local ui: { [string]: any } = {}
local current = "Home"
local SCREEN_ORDER = { Home = 1, Characters = 2, Upgrades = 3 }
local shownGold: number? = nil
local lastStatus = ""
local homeEntrance: () -> ()

local function place(obj: GuiObject, x: number, y: number, w: number, h: number)
	obj.Position = UDim2.fromOffset(math.floor(x), math.floor(y))
	obj.Size = UDim2.fromOffset(math.floor(w), math.floor(h))
end

local function toast(text: string, color: Color3?)
	if host.Toast then
		host.Toast(text, color)
	end
end

------------------------------------------------------------------------------------------
-- Background: soft animated gradient + drifting dots (looping tweens only)
------------------------------------------------------------------------------------------

local function buildBackground(frame: Frame)
	local shade = new("Frame", { Name = "Shade", Size = UDim2.fromScale(1, 1), BackgroundColor3 = Color3.new(1, 1, 1), BorderSizePixel = 0 }, frame)
	local grad = new("UIGradient", {
		Rotation = 90,
		Color = ColorSequence.new({
			ColorSequenceKeypoint.new(0, Color3.fromRGB(20, 18, 50)),
			ColorSequenceKeypoint.new(0.5, Color3.fromRGB(40, 20, 70)),
			ColorSequenceKeypoint.new(1, Color3.fromRGB(10, 30, 45)),
		}),
		-- dark at the top and bottom (readable bars), clear in the middle (3D lobby shows)
		Transparency = NumberSequence.new({
			NumberSequenceKeypoint.new(0, 0.15),
			NumberSequenceKeypoint.new(0.22, 0.75),
			NumberSequenceKeypoint.new(0.6, 0.85),
			NumberSequenceKeypoint.new(1, 0.2),
		}),
	}, shade)
	TweenService:Create(grad, TweenInfo.new(6, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut, -1, true), { Offset = Vector2.new(0, 0.08) }):Play()

	local dots = new("Frame", { Name = "Dots", Size = UDim2.fromScale(1, 1), BackgroundTransparency = 1, ClipsDescendants = true }, frame)
	local rng = Random.new()
	for _ = 1, Config.UI.LobbyParticles do
		local size = rng:NextInteger(4, 11)
		local x = rng:NextNumber(0.02, 0.98)
		local dot = new("Frame", {
			AnchorPoint = Vector2.new(0.5, 0.5),
			Position = UDim2.fromScale(x, 1.05),
			Size = UDim2.fromOffset(size, size),
			BackgroundColor3 = rng:NextNumber() < 0.3 and COLORS.Gold or Color3.fromRGB(170, 200, 255),
			BackgroundTransparency = rng:NextNumber(0.55, 0.8),
			BorderSizePixel = 0,
		}, dots)
		corner(dot, size)
		local seconds = rng:NextNumber(9, 18)
		-- start somewhere along the path so the screen isn't empty at first
		local t0 = rng:NextNumber()
		dot.Position = UDim2.fromScale(x, 1.05 - 1.15 * t0)
		local first = TweenService:Create(dot, TweenInfo.new(seconds * (1 - t0), Enum.EasingStyle.Linear), { Position = UDim2.fromScale(x + rng:NextNumber(-0.05, 0.05), -0.1) })
		first.Completed:Once(function()
			dot.Position = UDim2.fromScale(x, 1.05)
			UIAnim.Loop(dot, seconds, { Position = UDim2.fromScale(x + rng:NextNumber(-0.06, 0.06), -0.1) })
		end)
		first:Play()
	end
end

------------------------------------------------------------------------------------------
-- Top bar
------------------------------------------------------------------------------------------

local function pill(parent: Instance, caption: string, color: Color3, order: number): (Frame, TextLabel)
	local f = new("Frame", { Size = UDim2.fromOffset(170, 52), BackgroundColor3 = COLORS.Panel, BackgroundTransparency = 0.15, LayoutOrder = order }, parent)
	corner(f, 26)
	stroke(f, color, 2)
	label(f, caption, 12, { Position = UDim2.fromOffset(0, 5), Size = UDim2.new(1, 0, 0, 14), TextColor3 = COLORS.Dim })
	local value = label(f, "-", 24, { Position = UDim2.fromOffset(0, 19), Size = UDim2.new(1, 0, 0, 28), TextColor3 = color })
	return f, value
end

local function buildTopBar(frame: Frame)
	local bar = new("Frame", { Name = "TopBar", BackgroundTransparency = 1 }, frame)
	ui.TopBar = bar
	local pills = new("Frame", { Name = "Pills", Size = UDim2.fromScale(1, 1), BackgroundTransparency = 1 }, bar)
	new("UIListLayout", { FillDirection = Enum.FillDirection.Horizontal, Padding = UDim.new(0, 10), VerticalAlignment = Enum.VerticalAlignment.Center, SortOrder = Enum.SortOrder.LayoutOrder }, pills)
	local goldPill
	goldPill, ui.Gold = pill(pills, "GOLD", COLORS.Gold, 1)
	local bestPill
	bestPill, ui.Best = pill(pills, "BEST TIME", Color3.fromRGB(140, 210, 255), 2)
	local winsPill
	winsPill, ui.Wins = pill(pills, "WINS", Color3.fromRGB(130, 235, 150), 3)
	ui.Pills = { goldPill, bestPill, winsPill }
	ui.Settings = button(bar, "SETTINGS", COLORS.Gray, function()
		if host.OpenSettings then
			host.OpenSettings()
		end
	end, { AnchorPoint = Vector2.new(1, 0.5), Position = UDim2.new(1, 0, 0.5, 0), Size = UDim2.fromOffset(140, 52), TextSize = 20 })
	stroke(ui.Settings, Color3.fromRGB(200, 200, 215), 2)
end

------------------------------------------------------------------------------------------
-- Screen headers (Characters, Upgrades)
------------------------------------------------------------------------------------------

-- A full-size screen (what slides) holding a dark rounded panel (the content).
local function screenFrame(name: string): (Frame, Frame)
	local f = new("Frame", { Name = name, Size = UDim2.fromScale(1, 1), BackgroundTransparency = 1, Visible = false }, ui.Screens)
	local panel = new("Frame", {
		Name = "Panel",
		Position = UDim2.fromOffset(MARGIN, 0),
		Size = UDim2.new(1, -2 * MARGIN, 1, -10),
		BackgroundTransparency = 0.12,
		BackgroundColor3 = COLORS.Panel,
	}, f)
	corner(panel, 18)
	stroke(panel, COLORS.PanelLight, 2)
	return f, panel
end

local function header(screen: Frame, title: string): TextLabel
	button(screen, "< BACK", COLORS.Gray, function()
		LobbyScreen.Show("Home")
	end, { Position = UDim2.fromOffset(10, 10), Size = UDim2.fromOffset(130, 52), TextSize = 20 })
	label(screen, title, 34, { Position = UDim2.fromOffset(0, 14), Size = UDim2.new(1, 0, 0, 40), TextColor3 = COLORS.Text, TextStrokeTransparency = 0.5 })
	return label(screen, "", 20, { AnchorPoint = Vector2.new(1, 0), Position = UDim2.new(1, -16, 0, 22), Size = UDim2.fromOffset(200, 26), TextXAlignment = Enum.TextXAlignment.Right, TextColor3 = COLORS.Gold })
end

local function scroller(screen: Frame): ScrollingFrame
	return new("ScrollingFrame", {
		Position = UDim2.fromOffset(10, 72),
		Size = UDim2.new(1, -20, 1, -80),
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		ScrollBarThickness = 8,
		AutomaticCanvasSize = Enum.AutomaticSize.Y,
		CanvasSize = UDim2.new(),
		ScrollingDirection = Enum.ScrollingDirection.Y,
	}, screen)
end

------------------------------------------------------------------------------------------
-- Home
------------------------------------------------------------------------------------------

local function bigButton(parent: Instance, title: string, sub: string, color: Color3, order: number, onClick: () -> ()): (Frame, TextButton)
	local wrap = new("Frame", { Name = title, BackgroundTransparency = 1, LayoutOrder = order, Size = UDim2.fromOffset(280, 90) }, parent)
	local b = button(wrap, "", color, onClick, { Size = UDim2.fromScale(1, 1), ClipsDescendants = true })
	corner(b, 16)
	UIKit.sheen(b, 0.3)
	stroke(b, color:Lerp(Color3.new(1, 1, 1), 0.5), 2)
	label(b, title, 32, { Name = "Title", AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.new(0.5, 0, 0.5, -9), Size = UDim2.new(1, -10, 0, 36), TextStrokeTransparency = 0.6 })
	label(b, sub, 15, { Name = "Sub", AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.new(0.5, 0, 0.5, 20), Size = UDim2.new(1, -10, 0, 18), TextColor3 = Color3.fromRGB(235, 240, 255), Font = Config.UI.BodyFont })
	return wrap, b
end

local function buildHome(screen: Frame)
	-- Your character, big and turning. Tap it to open the character screen.
	local hero = new("TextButton", { Name = "Hero", Text = "", BackgroundTransparency = 1, AutoButtonColor = false }, screen)
	ui.Hero = hero
	local glow = new("Frame", {
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.new(0.5, 0, 1, -58),
		Size = UDim2.new(0.55, 0, 0, 34),
		BackgroundColor3 = COLORS.Gold,
		BackgroundTransparency = 0.8,
	}, hero)
	corner(glow, 200)
	TweenService:Create(glow, TweenInfo.new(1.6, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut, -1, true), { BackgroundTransparency = 0.6, Size = UDim2.new(0.65, 0, 0, 40) }):Play()
	ui.HeroPreview = ViewportPreview.Create(hero, { Size = UDim2.new(1, 0, 1, -44) })
	ui.HeroName = label(hero, "", 26, { AnchorPoint = Vector2.new(0.5, 1), Position = UDim2.new(0.5, 0, 1, -16), Size = UDim2.new(1, 0, 0, 30), TextStrokeTransparency = 0.4 })
	label(hero, "tap to change character", 14, { AnchorPoint = Vector2.new(0.5, 1), Position = UDim2.new(0.5, 0, 1, 0), Size = UDim2.new(1, 0, 0, 16), TextColor3 = COLORS.Dim, Font = Config.UI.BodyFont })
	hero.Activated:Connect(function()
		LobbyScreen.Show("Characters")
	end)

	-- Permanent upgrade summary (tap → upgrades)
	local meta = new("TextButton", { Name = "Meta", Text = "", AutoButtonColor = false, BackgroundColor3 = COLORS.Panel, BackgroundTransparency = 0.2 }, screen)
	ui.Meta = meta
	corner(meta, 12)
	stroke(meta, Color3.fromRGB(70, 70, 95), 2)
	pad(meta, 8)
	label(meta, "PERMANENT UPGRADES", 14, { Size = UDim2.new(1, 0, 0, 18), TextColor3 = COLORS.Gold })
	local grid = new("Frame", { Position = UDim2.fromOffset(0, 24), Size = UDim2.new(1, 0, 1, -24), BackgroundTransparency = 1 }, meta)
	ui.MetaGrid = new("UIGridLayout", { CellSize = UDim2.fromOffset(84, 40), CellPadding = UDim2.fromOffset(6, 6), SortOrder = Enum.SortOrder.LayoutOrder }, grid)
	ui.MetaChips = {}
	for order, id in ipairs(MetaUpgradeData.Order) do
		local def = MetaUpgradeData.Upgrades[id]
		local chip = new("Frame", { BackgroundColor3 = COLORS.PanelLight, LayoutOrder = order }, grid)
		corner(chip, 8)
		label(chip, def.Name, 13, { Position = UDim2.fromOffset(5, 2), Size = UDim2.new(1, -10, 0, 18), TextXAlignment = Enum.TextXAlignment.Left, TextTruncate = Enum.TextTruncate.AtEnd })
		local lv = label(chip, "0/" .. def.MaxLevel, 12, { AnchorPoint = Vector2.new(1, 1), Position = UDim2.new(1, -4, 1, -2), Size = UDim2.fromOffset(30, 16), TextXAlignment = Enum.TextXAlignment.Right, TextColor3 = COLORS.Dim })
		local back = new("Frame", { Position = UDim2.new(0, 5, 1, -12), Size = UDim2.new(1, -40, 0, 6), BackgroundColor3 = Color3.fromRGB(20, 20, 28), BorderSizePixel = 0 }, chip)
		corner(back, 3)
		local fill = new("Frame", { Size = UDim2.fromScale(0, 1), BackgroundColor3 = def.Color, BorderSizePixel = 0 }, back)
		corner(fill, 3)
		ui.MetaChips[id] = { Level = lv, Fill = fill, Shown = -1 }
	end
	meta.Activated:Connect(function()
		LobbyScreen.Show("Upgrades")
	end)

	-- CHARACTERS / UPGRADES / ARENA
	local nav = new("Frame", { Name = "Nav", BackgroundTransparency = 1 }, screen)
	ui.Nav = nav
	ui.NavLayout = new("UIListLayout", { Padding = UDim.new(0, 10), SortOrder = Enum.SortOrder.LayoutOrder, HorizontalAlignment = Enum.HorizontalAlignment.Center }, nav)
	ui.NavButtons = {}
	local navDefs = {
		{ "CHARACTERS", COLORS.Blue, function()
			LobbyScreen.Show("Characters")
		end },
		{ "UPGRADES", COLORS.Orange, function()
			LobbyScreen.Show("Upgrades")
		end },
		{ "ARENA", Color3.fromRGB(40, 150, 140), function()
			Remotes.Get("CycleArena"):FireServer()
		end },
	}
	for i, d in ipairs(navDefs) do
		local b = button(nav, d[1], d[2], d[3], { LayoutOrder = i, TextSize = 22 })
		UIKit.sheen(b, 0.25)
		stroke(b, (d[2] :: Color3):Lerp(Color3.new(1, 1, 1), 0.4), 2)
		ui.NavButtons[i] = b
	end
	ui.ArenaButton = ui.NavButtons[3]

	-- SOLO / DUO / TRIO
	local modes = new("Frame", { Name = "Modes", BackgroundTransparency = 1 }, screen)
	ui.Modes = modes
	ui.ModeLayout = new("UIListLayout", { Padding = UDim.new(0, 14), SortOrder = Enum.SortOrder.LayoutOrder, HorizontalAlignment = Enum.HorizontalAlignment.Center, VerticalAlignment = Enum.VerticalAlignment.Center }, modes)
	ui.ModeButtons = {}
	ui.ModeInner = {} -- the buttons inside (the wrappers carry the idle "breath" scale)
	for i, id in ipairs(Config.Modes.Order) do
		local def = (Config.Modes :: any)[id]
		local style = MODE_STYLE[id] or { Color = COLORS.Blue, Sub = def.MaxPlayers .. " players" }
		local wrap, b = bigButton(modes, string.upper(def.DisplayName), style.Sub, style.Color, i, function()
			Remotes.Get("StartRun"):FireServer(id)
		end)
		-- idle motion: a slow breath, a glowing edge and a light sweep, offset per button
		UIAnim.Breathe(wrap, 0.035, 1.1 + i * 0.17)
		local st = b:FindFirstChildOfClass("UIStroke")
		if st then
			UIAnim.PulseStroke(st, 2, 4)
		end
		UIAnim.Shine(b, 2.2 + i * 0.6)
		ui.ModeButtons[i] = wrap
		ui.ModeInner[i] = b
	end

	-- Countdown / run in progress panel (takes the mode buttons' place)
	local status = new("Frame", { Name = "Status", BackgroundColor3 = COLORS.Panel, BackgroundTransparency = 0.1, Visible = false }, screen)
	ui.Status = status
	corner(status, 16)
	ui.StatusStroke = stroke(status, COLORS.Green, 3)
	pad(status, 10)
	new("UIListLayout", { Padding = UDim.new(0, 6), HorizontalAlignment = Enum.HorizontalAlignment.Center, VerticalAlignment = Enum.VerticalAlignment.Center, SortOrder = Enum.SortOrder.LayoutOrder }, status)
	ui.StatusTitle = label(status, "", 26, { LayoutOrder = 1, TextWrapped = true, Size = UDim2.new(1, 0, 0, 32) })
	ui.StatusSub = label(status, "", 17, { LayoutOrder = 2, TextWrapped = true, TextColor3 = COLORS.Dim, Font = Config.UI.BodyFont, Size = UDim2.new(1, 0, 0, 42) })
	local row = new("Frame", { LayoutOrder = 3, Size = UDim2.new(1, 0, 0, 54), BackgroundTransparency = 1 }, status)
	ui.StatusRow = row
	new("UIListLayout", { FillDirection = Enum.FillDirection.Horizontal, Padding = UDim.new(0, 10), HorizontalAlignment = Enum.HorizontalAlignment.Center, SortOrder = Enum.SortOrder.LayoutOrder }, row)
	ui.Join = button(row, "JOIN", COLORS.Green, function()
		Remotes.Get("JoinRun"):FireServer()
	end, { LayoutOrder = 1, Size = UDim2.fromOffset(140, 52), TextSize = 24 })
	UIAnim.PulseStroke(stroke(ui.Join, Color3.fromRGB(200, 255, 210), 2), 1, 5)
	ui.StartNow = button(row, "START NOW", COLORS.Gold, function()
		Remotes.Get("StartNow"):FireServer()
	end, { LayoutOrder = 2, Size = UDim2.fromOffset(150, 52), TextSize = 20, TextColor3 = Color3.fromRGB(50, 35, 0) })
end

------------------------------------------------------------------------------------------
-- Characters
------------------------------------------------------------------------------------------

local cards: { [string]: { [string]: any } } = {}

local function skinOwned(p, skinId: string): boolean
	return skinId == "Default" or p.OwnedSkins[skinId] == true
end

local function skinPassId(skinId: string): number?
	local skin = CharacterData.Skins[skinId]
	if not skin then
		return nil
	end
	local id = skin.Pass == "StarterPack" and Config.Monetization.GamePasses.StarterPack or Config.Monetization.SkinPasses[skinId]
	if id and id ~= 0 then
		return id
	end
	return nil
end

local function onSkinTapped(characterId: string, skinId: string)
	local p = profile
	if not p then
		return
	end
	if skinOwned(p, skinId) then
		if (p.Skins[characterId] or "Default") ~= skinId then
			Remotes.Get("EquipSkin"):FireServer(characterId, skinId)
		end
		return
	end
	local passId = skinPassId(skinId)
	if passId then
		MarketplaceService:PromptGamePassPurchase(player, passId)
	else
		toast("That skin is coming soon!", COLORS.Dim)
	end
end

local function onCharacterAction(characterId: string)
	local p = profile
	if not p then
		return
	end
	local def = CharacterData.Characters[characterId]
	if p.OwnedCharacters[characterId] ~= true then
		if p.Gold < def.Cost then
			toast("Not enough gold yet: " .. def.Cost .. " needed.", Color3.fromRGB(255, 140, 120))
		end
		Remotes.Get("BuyCharacter"):FireServer(characterId)
	elseif p.SelectedCharacter ~= characterId then
		Remotes.Get("SelectCharacter"):FireServer(characterId)
	end
end

local function buildCard(scroll: ScrollingFrame, id: string, order: number)
	local def = CharacterData.Characters[id]
	local c: { [string]: any } = {}
	local card = new("Frame", { Name = id, BackgroundColor3 = COLORS.PanelLight, LayoutOrder = order }, scroll)
	c.Frame = card
	corner(card, 14)
	UIKit.sheen(card, 0.2)
	c.Stroke = stroke(card, COLORS.Panel, 2)
	pad(card, 10)
	new("UIListLayout", { Padding = UDim.new(0, 4), HorizontalAlignment = Enum.HorizontalAlignment.Center, SortOrder = Enum.SortOrder.LayoutOrder }, card)

	local stage = new("Frame", { Size = UDim2.new(1, 0, 0, 170), BackgroundColor3 = Color3.fromRGB(22, 22, 34), LayoutOrder = 1 }, card)
	corner(stage, 10)
	new("UIGradient", { Rotation = 90, Color = ColorSequence.new(Color3.fromRGB(60, 60, 95), Color3.fromRGB(15, 15, 25)) }, stage)
	c.Preview = ViewportPreview.Create(stage, { Size = UDim2.fromScale(1, 1) })
	c.Ribbon = label(stage, "SELECTED", 14, {
		AnchorPoint = Vector2.new(0.5, 0),
		Position = UDim2.new(0.5, 0, 0, 6),
		Size = UDim2.fromOffset(110, 22),
		BackgroundColor3 = COLORS.Gold,
		BackgroundTransparency = 0,
		TextColor3 = Color3.fromRGB(50, 35, 0),
		Visible = false,
	})
	corner(c.Ribbon, 11)

	label(card, def.Name, 26, { LayoutOrder = 2, Size = UDim2.new(1, 0, 0, 30) })
	label(card, def.Role or "", 15, { LayoutOrder = 3, TextColor3 = COLORS.Gold, Size = UDim2.new(1, 0, 0, 18) })
	label(card, def.Description, 14, { LayoutOrder = 4, TextColor3 = COLORS.Dim, Font = Config.UI.BodyFont, TextWrapped = true, Size = UDim2.new(1, 0, 0, 36) })

	-- starting weapon with its icon
	local weapon = WeaponData.Weapons[def.StartWeapon]
	local wrow = new("Frame", { LayoutOrder = 5, Size = UDim2.new(1, 0, 0, 34), BackgroundTransparency = 1 }, card)
	new("UIListLayout", { FillDirection = Enum.FillDirection.Horizontal, Padding = UDim.new(0, 8), HorizontalAlignment = Enum.HorizontalAlignment.Center, VerticalAlignment = Enum.VerticalAlignment.Center }, wrow)
	UIKit.IconTile(wrow, { Id = def.StartWeapon, Name = weapon and weapon.Name, Color = weapon and weapon.Color, Size = 32 })
	label(wrow, "Starts with " .. (weapon and weapon.Name or def.StartWeapon), 15, { Size = UDim2.fromOffset(170, 20), TextXAlignment = Enum.TextXAlignment.Left, AutomaticSize = Enum.AutomaticSize.X })
	label(card, def.BonusText, 19, { LayoutOrder = 6, TextColor3 = COLORS.Green, Size = UDim2.new(1, 0, 0, 24) })

	c.Action = button(card, "", COLORS.Blue, function()
		onCharacterAction(id)
	end, { LayoutOrder = 7, Size = UDim2.new(1, -10, 0, 50), TextSize = 22 })

	label(card, "SKINS", 13, { LayoutOrder = 8, TextColor3 = COLORS.Dim, Size = UDim2.new(1, 0, 0, 16) })
	local skins = new("Frame", { LayoutOrder = 9, Size = UDim2.new(1, 0, 0, 102), BackgroundTransparency = 1 }, card)
	new("UIGridLayout", { CellSize = UDim2.fromOffset(48, 48), CellPadding = UDim2.fromOffset(6, 6), HorizontalAlignment = Enum.HorizontalAlignment.Center, SortOrder = Enum.SortOrder.LayoutOrder }, skins)
	c.Skins = {}
	for skinOrder, skinId in ipairs(CharacterData.SkinsFor(id)) do
		local look = CharacterData.ResolveLook(id, skinId)
		local sw = new("TextButton", { Text = "", AutoButtonColor = true, BackgroundColor3 = look.Colors.Torso, LayoutOrder = skinOrder, ClipsDescendants = true }, skins)
		corner(sw, 10)
		local cap = new("Frame", { Size = UDim2.new(1, 0, 0.36, 0), BackgroundColor3 = look.Colors.Hat, BorderSizePixel = 0 }, sw)
		local _ = cap
		new("Frame", { AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.62), Size = UDim2.new(1, 0, 0, 5), BackgroundColor3 = look.GoldTrim and COLORS.Gold or look.Colors.Accent, BorderSizePixel = 0 }, sw)
		local lock = label(sw, "", 12, { AnchorPoint = Vector2.new(0.5, 1), Position = UDim2.new(0.5, 0, 1, -1), Size = UDim2.new(1, 0, 0, 14), TextStrokeTransparency = 0.2 })
		local st = stroke(sw, Color3.fromRGB(15, 15, 20), 2)
		UIAnim.Button(sw)
		sw.Activated:Connect(function()
			if host.Audio then
				host.Audio.Play("Click")
			end
			onSkinTapped(id, skinId)
		end)
		c.Skins[skinId] = { Button = sw, Lock = lock, Stroke = st }
	end
	c.SkinName = label(card, "", 14, { LayoutOrder = 10, TextColor3 = COLORS.Dim, Font = Config.UI.BodyFont, Size = UDim2.new(1, 0, 0, 18) })
	cards[id] = c
end

local function refreshCharacters()
	local p = profile
	if not p then
		return
	end
	ui.CharGold.Text = "Gold " .. p.Gold
	for id, c in pairs(cards) do
		local def = CharacterData.Characters[id]
		local owned = p.OwnedCharacters[id] == true
		local selected = p.SelectedCharacter == id
		local equipped = p.Skins[id] or "Default"
		ViewportPreview.SetModel(c.Preview, ViewportPreview.Template(id, equipped))
		c.Stroke.Color = selected and COLORS.Gold or (owned and Color3.fromRGB(80, 80, 110) or COLORS.Panel)
		c.Stroke.Thickness = selected and 4 or 2
		if c.Ribbon.Visible ~= selected and selected then
			UIAnim.Pop(c.Ribbon, 0, 0.4)
			UIAnim.Punch(c.Frame, 0.06)
		end
		c.Ribbon.Visible = selected
		if not owned then
			local afford = p.Gold >= def.Cost
			c.Action.Text = "BUY  " .. def.Cost .. " gold"
			c.Action.BackgroundColor3 = afford and COLORS.Green or COLORS.Gray
			c.Action.TextColor3 = Color3.new(1, 1, 1)
		elseif selected then
			c.Action.Text = "SELECTED"
			c.Action.BackgroundColor3 = COLORS.Gold
			c.Action.TextColor3 = Color3.fromRGB(50, 35, 0)
		else
			c.Action.Text = "SELECT"
			c.Action.BackgroundColor3 = COLORS.Blue
			c.Action.TextColor3 = Color3.new(1, 1, 1)
		end
		for skinId, s in pairs(c.Skins) do
			local on = skinId == equipped
			s.Stroke.Color = on and COLORS.Gold or Color3.fromRGB(15, 15, 20)
			s.Stroke.Thickness = on and 4 or 2
			if skinOwned(p, skinId) then
				s.Lock.Text = ""
			else
				s.Lock.Text = skinPassId(skinId) and "R$" or "soon"
			end
		end
		local skin = CharacterData.Skins[equipped]
		c.SkinName.Text = "Skin: " .. (skin and skin.Name or "Default")
	end
end

local function buildCharacters(screen: Frame)
	ui.CharGold = header(screen, "CHARACTERS")
	local scroll = scroller(screen)
	ui.CharGrid = new("UIGridLayout", { CellSize = UDim2.fromOffset(260, 580), CellPadding = UDim2.fromOffset(12, 12), HorizontalAlignment = Enum.HorizontalAlignment.Center, SortOrder = Enum.SortOrder.LayoutOrder }, scroll)
	for order, id in ipairs(CharacterData.Order) do
		buildCard(scroll, id, order)
	end
	-- the server rebuilds previews when the uploaded meshes finish loading
	task.spawn(function()
		local folder = ReplicatedStorage:WaitForChild("CharacterPreviews", 30)
		if folder then
			folder.ChildAdded:Connect(function()
				task.defer(function()
					refreshCharacters()
					LobbyScreen.RefreshHero()
				end)
			end)
			refreshCharacters()
			LobbyScreen.RefreshHero()
		end
	end)
end

------------------------------------------------------------------------------------------
-- Upgrades (permanent gold upgrades + Robux shop)
------------------------------------------------------------------------------------------

local function pips(level: number, maxLevel: number): string
	return string.rep("#", level) .. string.rep("-", maxLevel - level)
end

local function refreshShop(animate: boolean?)
	local scroll: ScrollingFrame = ui.ShopScroll
	for _, c in ipairs(scroll:GetChildren()) do
		if c:IsA("GuiObject") then
			c:Destroy()
		end
	end
	local p = profile
	if not p then
		return
	end
	ui.ShopGold.Text = "Gold " .. p.Gold
	local n = 0
	local function enter(obj: GuiObject)
		if animate then
			n += 1
			UIAnim.Pop(obj, 0.035 * n, 0.5)
		end
	end

	label(scroll, "Permanent upgrades (gold)", 22, { LayoutOrder = 1, TextColor3 = COLORS.Gold })
	local grid = new("Frame", { Size = UDim2.new(1, -10, 0, 0), AutomaticSize = Enum.AutomaticSize.Y, BackgroundTransparency = 1, LayoutOrder = 2 }, scroll)
	new("UIGridLayout", { CellSize = UDim2.fromOffset(240, 176), CellPadding = UDim2.fromOffset(10, 10), SortOrder = Enum.SortOrder.LayoutOrder, HorizontalAlignment = Enum.HorizontalAlignment.Center }, grid)
	for order, id in ipairs(MetaUpgradeData.Order) do
		local def = MetaUpgradeData.Upgrades[id]
		local level = p.Meta[id] or 0
		local cost = MetaUpgradeData.CostOf(id, level)
		local cell = new("Frame", { BackgroundColor3 = COLORS.PanelLight, LayoutOrder = order }, grid)
		corner(cell, 10)
		UIKit.sheen(cell, 0.2)
		stroke(cell, def.Color, 2)
		pad(cell, 8)
		new("UIListLayout", { Padding = UDim.new(0, 3), HorizontalAlignment = Enum.HorizontalAlignment.Center, SortOrder = Enum.SortOrder.LayoutOrder }, cell)
		label(cell, def.Name, 22, { LayoutOrder = 1, TextColor3 = def.Color })
		label(cell, def.Description, 14, { LayoutOrder = 2, TextColor3 = COLORS.Dim, Font = Config.UI.BodyFont, TextWrapped = true, Size = UDim2.new(1, 0, 0, 36) })
		label(cell, pips(level, def.MaxLevel) .. "  " .. level .. "/" .. def.MaxLevel, 16, { LayoutOrder = 3, Font = Enum.Font.Code })
		if cost then
			button(cell, "Buy " .. cost .. "g", p.Gold >= cost and COLORS.Green or COLORS.Gray, function()
				Remotes.Get("BuyMeta"):FireServer(id)
			end, { LayoutOrder = 4, Size = UDim2.fromOffset(180, 48) })
		else
			label(cell, "MAX", 22, { LayoutOrder = 4, TextColor3 = COLORS.Gold })
		end
		enter(cell)
	end

	label(scroll, "Robux shop (gold and cosmetics only)", 22, { LayoutOrder = 3, TextColor3 = Color3.fromRGB(120, 220, 140) })
	local robux = new("Frame", { Size = UDim2.new(1, -10, 0, 0), AutomaticSize = Enum.AutomaticSize.Y, BackgroundTransparency = 1, LayoutOrder = 4 }, scroll)
	new("UIGridLayout", { CellSize = UDim2.fromOffset(240, 120), CellPadding = UDim2.fromOffset(10, 10), SortOrder = Enum.SortOrder.LayoutOrder, HorizontalAlignment = Enum.HorizontalAlignment.Center }, robux)
	local items = {
		{ Name = "500 Gold", Kind = "Product", Id = Config.Monetization.Products.Gold500, Desc = "A pouch of gold." },
		{ Name = "1500 Gold", Kind = "Product", Id = Config.Monetization.Products.Gold1500, Desc = "A sack of gold." },
		{ Name = "5000 Gold", Kind = "Product", Id = Config.Monetization.Products.Gold5000, Desc = "A chest of gold." },
		{ Name = "Starter Pack", Kind = "Pass", Key = "StarterPack", Id = Config.Monetization.GamePasses.StarterPack, Desc = "+25% gold forever + Gold Trim skins." },
		{ Name = "VIP", Kind = "Pass", Key = "VIP", Id = Config.Monetization.GamePasses.VIP, Desc = "+1 reroll per run, chat tag, lobby crown." },
		{ Name = "2x Gold", Kind = "Pass", Key = "DoubleGold", Id = Config.Monetization.GamePasses.DoubleGold, Desc = "Double gold from runs." },
	}
	for order, item in ipairs(items) do
		local cell = new("Frame", { BackgroundColor3 = COLORS.PanelLight, LayoutOrder = order }, robux)
		corner(cell, 10)
		UIKit.sheen(cell, 0.2)
		pad(cell, 8)
		new("UIListLayout", { Padding = UDim.new(0, 3), HorizontalAlignment = Enum.HorizontalAlignment.Center, SortOrder = Enum.SortOrder.LayoutOrder }, cell)
		label(cell, item.Name, 20, { LayoutOrder = 1 })
		label(cell, item.Desc, 13, { LayoutOrder = 2, TextColor3 = COLORS.Dim, Font = Config.UI.BodyFont, TextWrapped = true, Size = UDim2.new(1, 0, 0, 30) })
		local owned = item.Kind == "Pass" and p.Passes[item.Key] == true
		if owned then
			label(cell, "Owned", 18, { LayoutOrder = 3, TextColor3 = COLORS.Gold })
		elseif not item.Id or item.Id == 0 then
			label(cell, "Not set up yet", 16, { LayoutOrder = 3, TextColor3 = COLORS.Gray })
		else
			button(cell, "Buy (R$)", Color3.fromRGB(60, 160, 90), function()
				if item.Kind == "Pass" then
					MarketplaceService:PromptGamePassPurchase(player, item.Id)
				else
					MarketplaceService:PromptProductPurchase(player, item.Id)
				end
			end, { LayoutOrder = 3, Size = UDim2.fromOffset(160, 48), TextSize = 18 })
		end
		enter(cell)
	end
	if p.MemoryOnly then
		label(scroll, "Studio test: DataStores are off, progress will not be saved.", 16, { LayoutOrder = 5, TextColor3 = COLORS.Red })
	end
end

local function buildUpgrades(screen: Frame)
	ui.ShopGold = header(screen, "UPGRADES")
	ui.ShopScroll = scroller(screen)
	new("UIListLayout", { Padding = UDim.new(0, 10), SortOrder = Enum.SortOrder.LayoutOrder, HorizontalAlignment = Enum.HorizontalAlignment.Center }, ui.ShopScroll)
end

------------------------------------------------------------------------------------------
-- Layout (landscape and portrait)
------------------------------------------------------------------------------------------

local function relayout()
	if not ui.Frame then
		return
	end
	local v: Vector2 = host.VirtualSize()
	local portrait: boolean = host.IsPortrait()
	local W = v.X
	local H = v.Y - TOP
	local m = MARGIN

	place(ui.TopBar, m, 12, W - 2 * m, 56)
	for _, p in ipairs(ui.Pills) do
		p.Size = UDim2.fromOffset(portrait and 150 or 170, 52)
	end
	ui.Screens.Position = UDim2.fromOffset(0, TOP)
	ui.Screens.Size = UDim2.new(1, 0, 1, -TOP)

	if portrait then
		local w = W - 2 * m
		local metaH = 16 + 24 + 2 * 40 + 6
		local modeH = 118
		local rest = 8 + metaH + 14 + modeH + 30 + 12 + 60 + 16
		-- the character gets the spare height; tall phones centre the whole stack
		local heroH = math.clamp(H - rest, 220, 560)
		local y0 = math.max(0, (H - heroH - rest) / 2)
		place(ui.Hero, m, y0, w, heroH)
		local cols = 5
		local cellW = (w - 16 - (cols - 1) * 6) / cols
		ui.MetaGrid.CellSize = UDim2.fromOffset(math.floor(cellW), 40)
		place(ui.Meta, m, y0 + heroH + 8, w, metaH)
		local y = y0 + heroH + 8 + metaH + 14
		ui.ModeLayout.FillDirection = Enum.FillDirection.Horizontal
		place(ui.Modes, m, y, w, modeH)
		place(ui.Status, m, y, w, modeH + 30)
		for _, b in ipairs(ui.ModeButtons) do
			b.Size = UDim2.fromOffset(math.floor((w - 28) / 3), modeH)
		end
		y += modeH + 30 + 12
		ui.NavLayout.FillDirection = Enum.FillDirection.Horizontal
		place(ui.Nav, m, y, w, 60)
		for _, b in ipairs(ui.NavButtons) do
			b.Size = UDim2.fromOffset(math.floor((w - 20) / 3), 60)
		end
		ui.CharGrid.CellSize = UDim2.fromOffset(math.floor(math.min(340, (w - 50) / 2)), 580)
	else
		local side = math.clamp(W * 0.24, 240, 320)
		ui.NavLayout.FillDirection = Enum.FillDirection.Vertical
		place(ui.Nav, m, 6, side, 3 * 62 + 20)
		for _, b in ipairs(ui.NavButtons) do
			b.Size = UDim2.fromOffset(side, 62)
		end
		local cellW = (side - 16 - 2 * 6) / 3
		ui.MetaGrid.CellSize = UDim2.fromOffset(math.floor(cellW), 40)
		place(ui.Meta, m, 6 + 3 * 62 + 20 + 14, side, 16 + 24 + 3 * 40 + 2 * 6)
		local modesH = 3 * 100 + 2 * 14
		ui.ModeLayout.FillDirection = Enum.FillDirection.Vertical
		place(ui.Modes, W - m - side, math.max(0, (H - modesH) / 2 - 10), side, modesH)
		for _, b in ipairs(ui.ModeButtons) do
			b.Size = UDim2.fromOffset(side, 100)
		end
		place(ui.Status, W - m - side, math.max(0, (H - 230) / 2 - 10), side, 230)
		local heroX = m + side + 16
		place(ui.Hero, heroX, 0, W - 2 * heroX, H - 8)
		local inner = W - 2 * m - 20
		local cw = math.clamp((inner - 3 * 12) / 4, 230, 300)
		ui.CharGrid.CellSize = UDim2.fromOffset(math.floor(cw), 580)
	end
	-- the countdown buttons sit side by side; narrow panels shrink them
	local statusW = ui.Status.Size.X.Offset - 20
	local bw = math.clamp((statusW - 10) / 2, 110, 200)
	ui.Join.Size = UDim2.fromOffset(bw, 52)
	ui.StartNow.Size = UDim2.fromOffset(bw, 52)
end

------------------------------------------------------------------------------------------
-- Public
------------------------------------------------------------------------------------------

-- Home: the main buttons, the upgrade summary and your character drop in one by one.
function homeEntrance()
	local i = 0
	for _, b in ipairs(ui.ModeInner) do
		i += 1
		UIAnim.Pop(b, 0.05 * i, 0.7)
	end
	for _, b in ipairs(ui.NavButtons) do
		i += 1
		UIAnim.Pop(b, 0.05 * i, 0.7)
	end
	UIAnim.Pop(ui.Meta, 0.05 * (i + 1), 0.8)
	UIAnim.Pop(ui.Hero, 0, 0.85)
end

-- Slides to "Home" | "Characters" | "Upgrades" (old panel name "Shop" = Upgrades).
function LobbyScreen.Show(name: string)
	if name == "Shop" then
		name = "Upgrades"
	end
	if not SCREEN_ORDER[name] or not ui.Frame then
		return
	end
	if name == current and ui[name].Visible then
		return
	end
	local direction = SCREEN_ORDER[name] >= SCREEN_ORDER[current] and 1 or -1
	UIAnim.SwapScreens(ui[current], ui[name], direction, Config.UI.ScreenSlideSeconds)
	current = name
	if name == "Characters" then
		refreshCharacters()
		local i = 0
		for _, id in ipairs(CharacterData.Order) do
			local c = cards[id]
			if c then
				i += 1
				UIAnim.Pop(c.Frame, 0.06 * i, 0.6)
			end
		end
		Remotes.Get("RequestProfile"):FireServer()
	elseif name == "Upgrades" then
		refreshShop(true)
		Remotes.Get("RequestProfile"):FireServer()
	else
		homeEntrance()
	end
end

function LobbyScreen.Current(): string
	return current
end

-- Shows / hides the whole lobby (UIBuilder: not in a run ⇔ visible).
function LobbyScreen.SetVisible(on: boolean)
	if not ui.Frame or ui.Frame.Visible == on then
		return
	end
	ui.Frame.Visible = on
	if on then
		-- always come back to the home screen
		for _, name in ipairs({ "Characters", "Upgrades" }) do
			ui[name].Visible = false
		end
		ui.Home.Visible = false
		current = "Home"
		UIAnim.SwapScreens(nil, ui.Home, 1, Config.UI.ScreenSlideSeconds)
		UIAnim.SlideIn(ui.TopBar, Vector2.new(0, -80), 0)
		homeEntrance()
		LobbyScreen.RefreshHero()
		lastStatus = ""
	end
end

-- The big centre preview: a clone of your own character (template while it spawns).
function LobbyScreen.RefreshHero()
	if not ui.HeroPreview then
		return
	end
	local p = profile
	local characterId = p and p.SelectedCharacter or CharacterData.Default
	local skinId = p and p.Skins[characterId] or "Default"
	local def = CharacterData.Characters[characterId] or CharacterData.Characters[CharacterData.Default]
	local skin = CharacterData.Skins[skinId]
	ui.HeroName.Text = def.Name .. (skin and ("  -  " .. skin.Name) or "")
	local own = ViewportPreview.OwnCharacter()
	ViewportPreview.SetModel(ui.HeroPreview, own or ViewportPreview.Template(characterId, skinId))
end

function LobbyScreen.SetJoined(on: boolean)
	joinedCountdown = on
end

function LobbyScreen.SetProfile(p: { [string]: any })
	local oldChar = profile and profile.SelectedCharacter
	local oldSkin = profile and profile.Skins[profile.SelectedCharacter]
	profile = p
	if not ui.Frame then
		return
	end
	UIAnim.CountTo(ui.Gold, shownGold or p.Gold, p.Gold, "%d", 0.7)
	shownGold = p.Gold
	ui.Best.Text = UIKit.formatTime(p.Stats.BestTime)
	ui.Wins.Text = tostring(p.Stats.Wins)
	for id, chip in pairs(ui.MetaChips) do
		local def = MetaUpgradeData.Upgrades[id]
		local level = p.Meta[id] or 0
		chip.Level.Text = level .. "/" .. def.MaxLevel
		chip.Level.TextColor3 = level >= def.MaxLevel and COLORS.Gold or COLORS.Dim
		if chip.Shown ~= level then
			UIAnim.Tween(chip.Fill, chip.Shown < 0 and 0.01 or 0.5, { Size = UDim2.fromScale(level / def.MaxLevel, 1) }, Enum.EasingStyle.Back)
			chip.Shown = level
		end
	end
	if current == "Characters" then
		refreshCharacters()
	elseif current == "Upgrades" then
		refreshShop(false)
	end
	if oldChar ~= p.SelectedCharacter or oldSkin ~= p.Skins[p.SelectedCharacter] then
		LobbyScreen.RefreshHero()
	end
end

--[[
	Per-frame text updates (cheap: only strings and visibility). Mode buttons swap with
	the status panel when a countdown or another run is going.
]]
function LobbyScreen.Update()
	if not ui.Frame or not ui.Frame.Visible then
		return
	end
	local state = Remotes.State()
	local phase = state:GetAttribute("Phase") or "Lobby"
	local kind = "Modes"
	if phase == "Countdown" then
		kind = "Countdown"
		local modeId = state:GetAttribute("Mode") or "Duo"
		local def = (Config.Modes :: any)[modeId]
		local seconds = state:GetAttribute("Countdown") or 0
		local joinedN = state:GetAttribute("Joined") or 0
		local maxN = state:GetAttribute("MaxJoin") or (def and def.MaxPlayers) or 4
		local title = string.upper(def and def.DisplayName or modeId) .. " run starts in " .. tostring(seconds)
		if ui.StatusTitle.Text ~= title then
			ui.StatusTitle.Text = title
			UIAnim.Punch(ui.StatusTitle, 0.2)
		end
		local names = state:GetAttribute("JoinedNames") or ""
		ui.StatusSub.Text = string.format("Joined %d/%d: %s", joinedN, maxN, names ~= "" and names or "-") .. (joinedCountdown and "\nYou're in! Get ready..." or "")
		ui.Join.Visible = not joinedCountdown
		local isStarter = state:GetAttribute("Starter") == player.UserId
		ui.StartNow.Visible = joinedCountdown and isStarter and joinedN >= 2
		ui.StatusRow.Visible = ui.Join.Visible or ui.StartNow.Visible
		ui.StatusStroke.Color = COLORS.Green
	elseif phase == "Running" or phase == "Results" then
		kind = "Busy"
		ui.StatusTitle.Text = "A run is in progress (" .. UIKit.formatTime(state:GetAttribute("RunTime") or 0) .. ")"
		ui.StatusSub.Text = "Wait here for the next one! Pick a character or buy upgrades meanwhile."
		ui.StatusRow.Visible = false
		ui.StatusStroke.Color = COLORS.Orange
	else
		joinedCountdown = false
	end
	if kind ~= lastStatus then
		lastStatus = kind
		local showStatus = kind ~= "Modes"
		ui.Modes.Visible = not showStatus
		ui.Status.Visible = showStatus
		UIAnim.Pop(showStatus and ui.Status or ui.Modes, 0, 0.7)
	end

	local arenaId = state:GetAttribute("SelectedArena") or "Forest"
	local arena = (Config.Arenas :: any)[arenaId]
	local text = "ARENA: " .. string.upper(arena and arena.DisplayName or tostring(arenaId))
	if ui.ArenaButton.Text ~= text then
		if ui.ArenaButton.Text ~= "ARENA" then
			UIAnim.Punch(ui.ArenaButton, 0.15)
		end
		ui.ArenaButton.Text = text
	end
end

function LobbyScreen.Init(h: { [string]: any })
	host = h
	local frame = new("Frame", { Name = "Lobby", Size = UDim2.fromScale(1, 1), BackgroundTransparency = 1, Visible = false, ZIndex = 2 }, h.Root)
	ui.Frame = frame
	buildBackground(frame)
	buildTopBar(frame)
	ui.Screens = new("Frame", { Name = "Screens", BackgroundTransparency = 1, Size = UDim2.fromScale(1, 1) }, frame)
	-- screens slide in from the side; their container clips nothing (full width)
	ui.Home = new("Frame", { Name = "Home", Size = UDim2.fromScale(1, 1), BackgroundTransparency = 1, Visible = false }, ui.Screens)
	buildHome(ui.Home)
	local charPanel, shopPanel
	ui.Characters, charPanel = screenFrame("Characters")
	buildCharacters(charPanel)
	ui.Upgrades, shopPanel = screenFrame("Upgrades")
	buildUpgrades(shopPanel)
	h.OnRelayout(relayout)
	relayout()

	-- your own character respawns when you change character or skin
	player.CharacterAdded:Connect(function()
		task.delay(0.6, LobbyScreen.RefreshHero)
	end)
end

return LobbyScreen
