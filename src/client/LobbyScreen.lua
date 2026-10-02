--[[
	LobbyScreen.lua
	The main menu, shown whenever the player is not in a run. The 3D castle courtyard at
	dusk is the backdrop and the hero stands on the lit dais in the middle (Showcase.lua);
	the UI frames it:

	  top left      SWARM logo (sword behind the letters) + "SURVIVE · UPGRADE · CONQUER"
	  top right     stats chip: best time, wins, gold (stays on every menu screen)
	  left column   feature cards CHARACTERS / UPGRADES / ARENA: <name>
	  bottom centre nameplate of the hero with gold arrows to browse characters
	                (owned → selected at once; locked → price, UNLOCK / DETAILS)
	  right column  SOLO (primary gold), DUO, TRIO. A countdown (who joined, JOIN,
	                START NOW, the number) or "run in progress" replaces this column.
	  bottom left   SETTINGS and STATS
	Portrait stacks: logo, stats, hero, nameplate, modes, cards, settings / stats.

	Sub-screens slide in: Characters (MenuCharacters), Upgrades (MenuUpgrades), Stats
	(MenuStats); Settings is UIBuilder's modal. Everything sent to the server is an id or a
	mode name; the server validates it (RunManager: StartRun / JoinRun / StartNow /
	CycleArena, GoldSystem: purchases and selection).
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared:WaitForChild("Config"))
local Remotes = require(Shared:WaitForChild("Remotes"))
local Theme = require(Shared:WaitForChild("Theme"))
local CharacterData = require(Shared:WaitForChild("CharacterData"))
local AchievementData = require(Shared:WaitForChild("AchievementData"))
local UIKit = require(script.Parent.UIKit)
local UIAnim = require(script.Parent.UIAnim)
local Icons = require(script.Parent.Icons)
local Showcase = require(script.Parent.Showcase)
local MenuCharacters = require(script.Parent.MenuCharacters)
local MenuUpgrades = require(script.Parent.MenuUpgrades)
local MenuStats = require(script.Parent.MenuStats)

local LobbyScreen = {}

local player = Players.LocalPlayer
local new, text, TS = UIKit.new, UIKit.text, UIKit.TS
local C, P = Theme.Color, Theme.Palette

local MODES = {
	Solo = { Sub = "Start right now", Icon = "person" },
	Duo = { Sub = "2 players + revives", Icon = "people2" },
	Trio = { Sub = "3 players + revives", Icon = "people3" },
}

local host: { [string]: any } = {}
local profile: { [string]: any }? = nil
local joinedCountdown = false
local ui: { [string]: any } = {}
local current = "Home"
local SCREEN_ORDER = { Home = 1, Characters = 2, Upgrades = 3, Stats = 4 }
local screens: { [string]: any } = {}
local shownGold: number? = nil
local lastStatus = ""
local browse: string? = nil -- a locked character being looked at from the nameplate

local function place(obj: GuiObject, x: number, y: number, w: number, h: number)
	obj.Position = UDim2.fromOffset(math.floor(x + 0.5), math.floor(y + 0.5))
	obj.Size = UDim2.fromOffset(math.floor(w + 0.5), math.floor(h + 0.5))
end

local function toast(str: string, color: Color3?)
	if host.Toast then
		host.Toast(str, color)
	end
end

local function owned(id: string): boolean
	return profile ~= nil and profile.OwnedCharacters[id] == true
end

local function selectedChar(): string
	return profile and profile.SelectedCharacter or CharacterData.Default
end

local function skinOf(id: string): string
	return profile and profile.Skins[id] or "Default"
end

------------------------------------------------------------------------------------------
-- Logo and vignette
------------------------------------------------------------------------------------------

local function buildLogo(parent: Instance): Frame
	local logo = new("Frame", { Name = "Logo", BackgroundTransparency = 1, Size = UDim2.fromOffset(360, 130) }, parent)
	ui.LogoScale = new("UIScale", { Name = "Fit" }, logo)
	-- the sword behind the letters
	local sword = new("Frame", { Name = "Sword", BackgroundTransparency = 1, AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromOffset(170, 54), Size = UDim2.fromOffset(330, 26), Rotation = -14 }, logo)
	local blade = new("Frame", { BackgroundColor3 = Color3.new(1, 1, 1), BorderSizePixel = 0, Position = UDim2.fromOffset(84, 6), Size = UDim2.fromOffset(232, 14) }, sword)
	new("UIGradient", { Rotation = 90, Color = Theme.Gradient.Steel }, blade)
	UIKit.stroke(blade, P.steel_600, 1, 0.3)
	new("Frame", { BackgroundColor3 = P.steel_200, BorderSizePixel = 0, AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromOffset(316, 13), Size = UDim2.fromOffset(10, 10), Rotation = 45 }, sword)
	new("Frame", { BackgroundColor3 = P.steel_400, BorderSizePixel = 0, Position = UDim2.fromOffset(92, 12), Size = UDim2.fromOffset(212, 2) }, sword)
	local guard = new("Frame", { BackgroundColor3 = P.gold_400, BorderSizePixel = 0, AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromOffset(80, 13), Size = UDim2.fromOffset(10, 52) }, sword)
	UIKit.corner(guard, 4)
	UIKit.stroke(guard, P.gold_700, 1, 0.2)
	local grip = new("Frame", { BackgroundColor3 = P.leather_500, BorderSizePixel = 0, AnchorPoint = Vector2.new(1, 0.5), Position = UDim2.fromOffset(75, 13), Size = UDim2.fromOffset(46, 9) }, sword)
	UIKit.corner(grip, 3)
	local pommel = new("Frame", { BackgroundColor3 = P.gold_400, BorderSizePixel = 0, AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromOffset(26, 13), Size = UDim2.fromOffset(16, 16) }, sword)
	UIKit.corner(pommel, 999)
	-- the letters: a shadow, then steel-gradient text with a dark outline
	local function word(offset: Vector2, color: Color3, transparency: number): TextLabel
		return new("TextLabel", {
			BackgroundTransparency = 1,
			Position = UDim2.fromOffset(offset.X, offset.Y),
			Size = UDim2.fromOffset(360, 92),
			Text = "SWARM",
			FontFace = Theme.Font.Display,
			TextSize = 84,
			TextColor3 = color,
			TextTransparency = transparency,
			TextXAlignment = Enum.TextXAlignment.Left,
		}, logo)
	end
	word(Vector2.new(4, 10), C.Shadow, 0.35)
	local letters = word(Vector2.new(0, 4), Color3.new(1, 1, 1), 0)
	new("UIGradient", { Rotation = 90, Color = Theme.Gradient.Steel }, letters)
	new("UIStroke", { Color = P.slate_950, Thickness = 2, Transparency = 0.15, ApplyStrokeMode = Enum.ApplyStrokeMode.Contextual }, letters)
	text(logo, "Label", UIKit.track("Survive · Upgrade · Conquer"), {
		Name = "Tagline",
		Position = UDim2.fromOffset(4, 100),
		Size = UDim2.fromOffset(360, 22),
		TextColor3 = P.gold_300,
		TextStrokeColor3 = C.Shadow,
		TextStrokeTransparency = 0.6,
	}, 14)
	return logo
end

-- Soft dark edges over the 3D scene so the menu reads (in the full-screen FX gui).
local function buildVignette(fxGui: ScreenGui)
	local v = new("Frame", { Name = "MenuVignette", BackgroundTransparency = 1, Size = UDim2.fromScale(1, 1), Visible = false }, fxGui)
	ui.Vignette = v
	local function edge(rot: number, pos: UDim2, size: UDim2, strength: number)
		local f = new("Frame", { BackgroundColor3 = C.Backdrop, BorderSizePixel = 0, Position = pos, Size = size }, v)
		new("UIGradient", {
			Rotation = rot,
			Transparency = NumberSequence.new({ NumberSequenceKeypoint.new(0, strength), NumberSequenceKeypoint.new(1, 1) }),
		}, f)
	end
	edge(0, UDim2.fromScale(0, 0), UDim2.fromScale(0.42, 1), 0.35)
	edge(180, UDim2.fromScale(0.62, 0), UDim2.fromScale(0.38, 1), 0.4)
	edge(90, UDim2.fromScale(0, 0), UDim2.fromScale(1, 0.25), 0.45)
	edge(-90, UDim2.fromScale(0, 0.72), UDim2.fromScale(1, 0.28), 0.4)
	-- the dense sub-screens dim the scene a little more
	ui.Dim = new("Frame", { BackgroundColor3 = C.Backdrop, BackgroundTransparency = 1, BorderSizePixel = 0, Size = UDim2.fromScale(1, 1) }, v)
end

------------------------------------------------------------------------------------------
-- Stats chip (top right, every screen)
------------------------------------------------------------------------------------------

local function buildChip(frame: Frame)
	local holder, face = UIKit.Surface(frame, { Name = "StatsChip", Radius = 999, Size = UDim2.fromOffset(0, 48) })
	holder.AutomaticSize = Enum.AutomaticSize.X
	face.AutomaticSize = Enum.AutomaticSize.X
	face.Size = UDim2.fromScale(0, 1)
	UIKit.padding(face, 0, 18, 0, 16)
	UIKit.list(face, { FillDirection = Enum.FillDirection.Horizontal, VerticalAlignment = Enum.VerticalAlignment.Center, Padding = UDim.new(0, 12) })
	ui.Chip = holder
	local function sep(order: number)
		new("Frame", { BackgroundColor3 = C.Gold, BackgroundTransparency = 0.6, BorderSizePixel = 0, Size = UDim2.fromOffset(1, 22), LayoutOrder = order }, face)
	end
	ui.Best = UIKit.Chip(face, "crown", "Best time", "0:00", { LayoutOrder = 1, Size = UDim2.fromOffset(0, 48) }, { Size = 22, Color = P.gold_400, Accent = P.gold_200 })
	sep(2)
	ui.Wins = UIKit.Chip(face, "skull", "Wins", "0", { LayoutOrder = 3, Size = UDim2.fromOffset(0, 48) }, { Size = 22, Color = P.ivory_200, Back = P.slate_900 })
	sep(4)
	ui.Gold = UIKit.Chip(face, "coin", "Gold", "0", { LayoutOrder = 5, Size = UDim2.fromOffset(0, 48) }, { Size = 22 })
	ui.Gold.Value.TextColor3 = P.gold_200
end

------------------------------------------------------------------------------------------
-- Home
------------------------------------------------------------------------------------------

local function arenaText(): (string, string)
	local state = Remotes.State()
	local arenaId = state:GetAttribute("SelectedArena") or "Forest"
	local arena = (Config.Arenas :: any)[arenaId]
	local title = "ARENA: " .. string.upper(arena and arena.DisplayName or tostring(arenaId))
	local best = profile and (profile.Stats.BestStage or 0) or 0
	-- the next arena still locked (lowest requirement first), else the picked arena's hint
	local nextDef, nextNeed = nil, math.huge
	for _, name in ipairs(Config.Arenas.Order) do
		local def = (Config.Arenas :: any)[name]
		local need = def and def.RequiredBestStage or 0
		if def and best < need and need < nextNeed then
			nextDef, nextNeed = def, need
		end
	end
	if nextDef then
		return title, string.format("%s: reach stage %d to unlock", nextDef.DisplayName, nextNeed)
	end
	return title, (arena and arena.Hint) or "Face the swarm"
end

-- Nameplate arrows: browse characters in order.
local selectToken = 0
local function browseStep(dir: number)
	local order = CharacterData.Order
	local cur = browse or selectedChar()
	local i = table.find(order, cur) or 1
	local nextId = order[((i - 1 + dir) % #order) + 1]
	if owned(nextId) then
		browse = nil
		if nextId ~= selectedChar() then
			if profile then
				-- show it at once; the server's profile sync confirms
				profile.SelectedCharacter = nextId
			end
			-- send only the last of several quick taps (the remote is rate limited), then
			-- ask for the profile so the server's choice always wins on screen
			selectToken += 1
			local token = selectToken
			task.delay(0.35, function()
				if token == selectToken then
					Remotes.Get("SelectCharacter"):FireServer(nextId)
					task.delay(1, function()
						if token == selectToken then
							Remotes.Get("RequestProfile"):FireServer()
						end
					end)
				end
			end)
		end
	else
		browse = nextId
		Showcase.Show(nextId, "Default")
	end
	LobbyScreen.RefreshHero()
	UIAnim.Punch(ui.NameTitle, 0.08)
end

local function buildNameplate(frame: Frame)
	local plate = new("Frame", { Name = "Nameplate", BackgroundTransparency = 1 }, frame)
	ui.Nameplate = plate
	local holder, face = UIKit.Surface(plate, { Name = "Plate", Radius = Theme.Radius.L })
	ui.PlateSurface = holder
	ui.NameTitle = text(face, "H1", "Knight", { Name = "Name", TextXAlignment = Enum.TextXAlignment.Center, Position = UDim2.fromOffset(0, 8), Size = UDim2.new(1, 0, 0, TS(30) + 4) })
	ui.NameDivider = UIKit.Divider(face, 160, { AnchorPoint = Vector2.new(0.5, 0), Position = UDim2.new(0.5, 0, 0, 12 + TS(30)) })
	ui.NameSub = text(face, "Body", "", {
		Name = "Sub",
		TextXAlignment = Enum.TextXAlignment.Center,
		TextWrapped = true,
		Position = UDim2.fromOffset(16, 24 + TS(30)),
		Size = UDim2.new(1, -32, 0, TS(16) * 2 + 6),
		TextYAlignment = Enum.TextYAlignment.Top,
	})
	ui.LockIcon = Icons.Draw(face, "lock", { Size = 22, Color = P.gold_400, Position = UDim2.fromOffset(16, 14) })
	-- your name with the achievement title / nameplate colour you wear (AchievementData)
	ui.PlayerTag = text(plate, "Label", "", {
		Name = "PlayerTag",
		AnchorPoint = Vector2.new(0.5, 1),
		Position = UDim2.new(0.5, 0, 0, -6),
		Size = UDim2.new(1, 0, 0, TS(15) + 4),
		TextXAlignment = Enum.TextXAlignment.Center,
		TextStrokeColor3 = C.Shadow,
		TextStrokeTransparency = 0.45,
		RichText = true,
	}, 15)
	-- locked character: price + unlock / details
	local lockRow = new("Frame", { Name = "LockRow", BackgroundTransparency = 1, Visible = false, AnchorPoint = Vector2.new(0, 1), Position = UDim2.new(0, 0, 1, -12), Size = UDim2.new(1, 0, 0, 48) }, face)
	ui.LockRow = lockRow
	UIKit.list(lockRow, { FillDirection = Enum.FillDirection.Horizontal, HorizontalAlignment = Enum.HorizontalAlignment.Center, VerticalAlignment = Enum.VerticalAlignment.Center, Padding = UDim.new(0, 10) })
	ui.Unlock = UIKit.Button(lockRow, {
		Kind = "Outline",
		Title = "UNLOCK",
		Icon = "coin",
		IconSize = 20,
		Align = "Center",
		Size = UDim2.fromOffset(196, 48),
		LayoutOrder = 1,
		OnClick = function()
			local id = browse
			if not id or not profile then
				return
			end
			local def = CharacterData.Characters[id]
			if profile.Gold < def.Cost then
				toast("Not enough gold yet: " .. UIKit.formatNumber(def.Cost) .. " needed.", P.crimson_300)
				return
			end
			Remotes.Get("BuyCharacter"):FireServer(id)
		end,
	})
	ui.Details = UIKit.Button(lockRow, {
		Title = "DETAILS",
		Icon = "helmet",
		IconSize = 20,
		Align = "Center",
		Size = UDim2.fromOffset(146, 48),
		LayoutOrder = 2,
		OnClick = function()
			LobbyScreen.Show("Characters")
		end,
	})
	ui.PrevArrow = UIKit.IconButton(plate, {
		Icon = "chevronLeft",
		Size = 52,
		Round = true,
		Name = "Prev",
		OnClick = function()
			browseStep(-1)
		end,
	})
	ui.NextArrow = UIKit.IconButton(plate, {
		Icon = "chevronRight",
		Size = 52,
		Round = true,
		Name = "Next",
		OnClick = function()
			browseStep(1)
		end,
	})
	for _, b in ipairs({ ui.PrevArrow, ui.NextArrow }) do
		local st = b.Face:FindFirstChildOfClass("UIStroke")
		if st then
			st.Color = P.gold_400
			st.Transparency = 0.1
		end
	end
end

local function buildModes(frame: Frame)
	ui.ModeButtons = {}
	for i, id in ipairs(Config.Modes.Order) do
		local def = (Config.Modes :: any)[id]
		local style = MODES[id] or { Sub = def.MaxPlayers .. " players", Icon = "people3" }
		local b = UIKit.Button(frame, {
			Kind = i == 1 and "Primary" or "Secondary",
			Glow = i == 1,
			Title = string.upper(def.DisplayName),
			Subtitle = style.Sub,
			Icon = style.Icon,
			IconSize = 34,
			TitleStyle = "H1",
			TitleSize = i == 1 and 30 or 26,
			Chevron = true,
			Align = "Left",
			Name = id,
			OnClick = function()
				Remotes.Get("StartRun"):FireServer(id)
			end,
		})
		if i == 1 then
			b.Face.ClipsDescendants = true
			UIAnim.Shine(b.Face, 3.2, 0.78)
		end
		ui.ModeButtons[i] = b
	end
end

-- Countdown (who joined, JOIN / START NOW, the number) or "run in progress".
local function buildQueue(frame: Frame)
	local holder, face = UIKit.Surface(frame, { Name = "Queue", Radius = Theme.Radius.L, Visible = false, Edge = P.gold_400, EdgeTransparency = 0.25 })
	ui.Queue = holder
	UIKit.padding(face, 14, 16, 14, 16)
	local ring = new("Frame", { Name = "Ring", AnchorPoint = Vector2.new(1, 0), Position = UDim2.new(1, 0, 0, 0), Size = UDim2.fromOffset(60, 60), BackgroundColor3 = C.PanelInset, BackgroundTransparency = 0.2 }, face)
	UIKit.corner(ring, 999)
	UIKit.stroke(ring, P.gold_400, 2.5, 0)
	ui.QueueRing = ring
	ui.QueueNumber = text(ring, "Number", "10", { Size = UDim2.fromScale(1, 1), TextXAlignment = Enum.TextXAlignment.Center, TextColor3 = P.gold_200 }, 28)
	ui.QueueTitle = text(face, "H2", "", { Position = UDim2.fromOffset(0, 2), Size = UDim2.new(1, -70, 0, TS(22) + 6), TextTruncate = Enum.TextTruncate.AtEnd })
	ui.QueueCaption = text(face, "Caption", "", { Position = UDim2.fromOffset(0, 8 + TS(22)), Size = UDim2.new(1, -70, 0, TS(12) + 4), TextColor3 = P.gold_300 })
	ui.QueueList = new("Frame", { Name = "Players", BackgroundTransparency = 1, Position = UDim2.fromOffset(0, 72), Size = UDim2.new(1, 0, 0, 116) }, face)
	UIKit.list(ui.QueueList, { Padding = UDim.new(0, 4) })
	ui.QueueNote = text(face, "Body", "", { Name = "Note", TextWrapped = true, TextYAlignment = Enum.TextYAlignment.Top, Size = UDim2.new(1, 0, 0, TS(16) * 3 + 8) })
	local row = new("Frame", { Name = "Buttons", BackgroundTransparency = 1, AnchorPoint = Vector2.new(0, 1), Position = UDim2.fromScale(0, 1), Size = UDim2.new(1, 0, 0, 52) }, face)
	ui.QueueRow = row
	UIKit.list(row, { FillDirection = Enum.FillDirection.Horizontal, HorizontalAlignment = Enum.HorizontalAlignment.Center, Padding = UDim.new(0, 10) })
	ui.Join = UIKit.Button(row, {
		Kind = "Primary",
		Glow = true,
		Title = "JOIN",
		Icon = "userPlus",
		IconSize = 22,
		Align = "Center",
		Size = UDim2.new(1, 0, 1, 0),
		LayoutOrder = 1,
		OnClick = function()
			Remotes.Get("JoinRun"):FireServer()
		end,
	})
	ui.StartNow = UIKit.Button(row, {
		Kind = "Primary",
		Title = "START NOW",
		Icon = "play",
		IconSize = 20,
		Align = "Center",
		Size = UDim2.new(1, 0, 1, 0),
		LayoutOrder = 2,
		OnClick = function()
			Remotes.Get("StartNow"):FireServer()
		end,
	})
end

local function playerRow(name: string?, order: number)
	local row = new("Frame", { BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 26), LayoutOrder = order }, ui.QueueList)
	Icons.Draw(row, "person", { Size = 20, Color = name and P.gold_400 or P.slate_500, Position = UDim2.fromOffset(0, 3) })
	text(row, "BodyStrong", name or "Waiting for a player...", {
		Position = UDim2.fromOffset(28, 0),
		Size = UDim2.new(1, -28, 1, 0),
		TextColor3 = name and C.Text or C.TextFaint,
		TextTruncate = Enum.TextTruncate.AtEnd,
	})
end

local function buildHome(screen: Frame)
	ui.Logo = buildLogo(screen)
	ui.Cards = new("Frame", { Name = "Cards", BackgroundTransparency = 1 }, screen)
	ui.CardsLayout = UIKit.list(ui.Cards, { Padding = UDim.new(0, Theme.Layout.Gutter) })
	ui.CardCharacters = UIKit.Card(ui.Cards, {
		Icon = "helmet",
		Title = "CHARACTERS",
		Subtitle = "Choose your fighter",
		LayoutOrder = 1,
		OnClick = function()
			LobbyScreen.Show("Characters")
		end,
	})
	ui.CardUpgrades = UIKit.Card(ui.Cards, {
		Icon = "chevronsUp",
		Title = "UPGRADES",
		Subtitle = "Get stronger",
		LayoutOrder = 2,
		OnClick = function()
			LobbyScreen.Show("Upgrades")
		end,
	})
	ui.CardArena = UIKit.Card(ui.Cards, {
		Icon = "tree",
		Title = "ARENA: FOREST",
		Subtitle = "Face the swarm",
		LayoutOrder = 3,
		OnClick = function()
			Remotes.Get("CycleArena"):FireServer()
		end,
	})
	ui.Corner = new("Frame", { Name = "CornerButtons", BackgroundTransparency = 1 }, screen)
	ui.CornerLayout = UIKit.list(ui.Corner, { FillDirection = Enum.FillDirection.Horizontal, Padding = UDim.new(0, Theme.Layout.Gutter) })
	ui.SettingsBtn = UIKit.IconButton(ui.Corner, {
		Icon = "gear",
		Caption = "Settings",
		Size = 76,
		LayoutOrder = 1,
		OnClick = function()
			if host.OpenSettings then
				host.OpenSettings()
			end
		end,
	})
	ui.StatsBtn = UIKit.IconButton(ui.Corner, {
		Icon = "bars",
		Caption = "Stats",
		Size = 76,
		LayoutOrder = 2,
		OnClick = function()
			LobbyScreen.Show("Stats")
		end,
	})
	buildNameplate(screen)
	buildModes(screen)
	buildQueue(screen)
end

------------------------------------------------------------------------------------------
-- Layout
------------------------------------------------------------------------------------------

-- Portrait: the three feature cards become small tiles (icon over a short caps title).
local function setCardsCompact(on: boolean)
	if ui.CardsCompact == on then
		return
	end
	ui.CardsCompact = on
	for _, b in ipairs({ ui.CardCharacters, ui.CardUpgrades, ui.CardArena }) do
		local layout = b.Content:FindFirstChildOfClass("UIListLayout")
		local column = b.Content:FindFirstChild("Text") :: Frame?
		local right = b.Content:FindFirstChild("Right") :: Frame?
		local iconHolder = b.Content:FindFirstChild("IconHolder") :: Frame?
		if layout then
			layout.FillDirection = on and Enum.FillDirection.Vertical or Enum.FillDirection.Horizontal
			layout.HorizontalAlignment = on and Enum.HorizontalAlignment.Center or Enum.HorizontalAlignment.Left
			layout.Padding = UDim.new(0, on and 4 or Theme.Space.M)
		end
		if right then
			right.Visible = not on
		end
		if iconHolder then
			iconHolder.Size = on and UDim2.fromOffset(40, 40) or UDim2.fromOffset(46, 46)
		end
		if column then
			column.Size = on and UDim2.new(1, 0, 0, TS(15) + 6) or UDim2.new(1, -(46 + 20 + 2 * Theme.Space.M), 1, 0)
		end
		if b.Subtitle then
			b.Subtitle.Visible = not on
		end
		if b.Title then
			b.Title.FontFace = on and Theme.Font.Label or Theme.Font.Title
			b.Title.TextSize = on and TS(15) or TS(Theme.TextSize.H2)
			b.Title.TextXAlignment = on and Enum.TextXAlignment.Center or Enum.TextXAlignment.Left
			b.Title.Size = UDim2.new(1, 0, 0, b.Title.TextSize + 6)
		end
	end
end

local function relayout()
	if not ui.Frame then
		return
	end
	local v: Vector2 = host.VirtualSize()
	local portrait: boolean = host.IsPortrait()
	local ins = host.Insets()
	local W, H = v.X, v.Y
	local compact = UIKit.IsCompact()
	local M = compact and Theme.Layout.MarginCompact or Theme.Layout.Margin
	local G = Theme.Layout.Gutter

	local chipY = ins.Right > 4 and (ins.Top + 6) or 12
	local plateH = (browse and 158 or 104) + (compact and 16 or 0)
	local heroFrac = 0.5

	if portrait then
		local logoScale = math.clamp((W - 2 * M) / 380, 0.66, 0.85)
		ui.LogoScale.Scale = logoScale
		local logoY = math.max(ins.Top + 2, 10)
		ui.Logo.Position = UDim2.fromOffset((W - 350 * logoScale) / 2, logoY)
		local chipTop = logoY + 124 * logoScale + 4
		ui.Chip.AnchorPoint = Vector2.new(0.5, 0)
		-- sub-screens: under their header instead of the logo
		ui.Chip.Position = UDim2.fromOffset(W / 2, current == "Home" and chipTop or (math.max(ins.Top + 4, 12) + 64))
		local w = W - 2 * M
		-- bottom-up: settings / stats, cards, DUO + TRIO, SOLO, nameplate
		local cornerH = 64
		local y = H - M - cornerH
		place(ui.Corner, M, y, w, cornerH)
		for _, b in ipairs({ ui.SettingsBtn, ui.StatsBtn }) do
			b.Instance.Size = UDim2.fromOffset(math.floor((w - G) / 2), cornerH)
		end
		local cardH = compact and 96 or 88
		setCardsCompact(true)
		y -= G + cardH
		ui.CardsLayout.FillDirection = Enum.FillDirection.Horizontal
		place(ui.Cards, M, y, w, cardH)
		for _, b in ipairs({ ui.CardCharacters, ui.CardUpgrades, ui.CardArena }) do
			b.Instance.Size = UDim2.fromOffset(math.floor((w - 2 * G) / 3), cardH)
		end
		local soloH, smallH = 84, 76
		y -= G + smallH
		local half = math.floor((w - G) / 2)
		place(ui.ModeButtons[2].Instance, M, y, half, smallH)
		place(ui.ModeButtons[3].Instance, M + half + G, y, half, smallH)
		y -= G + soloH
		place(ui.ModeButtons[1].Instance, M, y, w, soloH)
		place(ui.Queue, M, y, w, soloH + G + smallH)
		y -= 18 + plateH
		local plateW = math.min(w - 2 * 62, 460)
		place(ui.Nameplate, (W - plateW) / 2, y, plateW, plateH)
		heroFrac = ((chipTop + 52 + y) / 2) / H
	else
		local logoScale = math.clamp(H / 760, 0.7, 1)
		ui.LogoScale.Scale = logoScale
		local logoY = math.max(ins.Top + 2, 14)
		ui.Logo.Position = UDim2.fromOffset(M, logoY)
		ui.Chip.AnchorPoint = Vector2.new(1, 0)
		ui.Chip.Position = UDim2.fromOffset(W - M, chipY)
		local logoBottom = logoY + 126 * logoScale
		place(ui.Corner, M, H - M - 76, 200, 76)
		for _, b in ipairs({ ui.SettingsBtn, ui.StatsBtn }) do
			b.Instance.Size = UDim2.fromOffset(76, 76)
		end
		-- left cards, centred between the logo and the corner buttons
		local cw = math.clamp(W * 0.27, 290, 360)
		local cardH = compact and 86 or 80
		setCardsCompact(false)
		ui.CardsLayout.FillDirection = Enum.FillDirection.Vertical
		local cardsH = 3 * cardH + 2 * G
		local top, bottom = logoBottom + 12, H - M - 76 - 12
		place(ui.Cards, M, math.max(top, (top + bottom - cardsH) / 2), cw, cardsH)
		for _, b in ipairs({ ui.CardCharacters, ui.CardUpgrades, ui.CardArena }) do
			b.Instance.Size = UDim2.fromOffset(cw, cardH)
		end
		-- right column: SOLO / DUO / TRIO
		local rw = math.clamp(W * 0.25, 280, 340)
		local soloH, smallH = 96, 80
		local colH = soloH + 2 * smallH + 2 * G
		local colTop = math.max(chipY + 64, (H - colH) / 2)
		place(ui.ModeButtons[1].Instance, W - M - rw, colTop, rw, soloH)
		place(ui.ModeButtons[2].Instance, W - M - rw, colTop + soloH + G, rw, smallH)
		place(ui.ModeButtons[3].Instance, W - M - rw, colTop + soloH + smallH + 2 * G, rw, smallH)
		place(ui.Queue, W - M - rw, colTop - 10, rw, math.min(colH + 60, H - colTop - M))
		-- nameplate bottom centre, between the columns
		local gapL, gapR = M + cw + 16, W - M - rw - 16
		local plateW = math.clamp(gapR - gapL - 2 * 64, 300, 460)
		place(ui.Nameplate, W / 2 - plateW / 2, H - M - plateH, plateW, plateH)
	end
	ui.PlateSurface.Size = UDim2.fromScale(1, 1)
	ui.PrevArrow.Instance.AnchorPoint = Vector2.new(1, 0.5)
	ui.PrevArrow.Instance.Position = UDim2.new(0, -10, 0.5, 0)
	ui.NextArrow.Instance.AnchorPoint = Vector2.new(0, 0.5)
	ui.NextArrow.Instance.Position = UDim2.new(1, 10, 0.5, 0)
	-- "run in progress" needs no player list: a compact panel
	if lastStatus == "Busy" then
		ui.Queue.Size = UDim2.fromOffset(ui.Queue.Size.X.Offset, math.min(ui.Queue.Size.Y.Offset, 96 + TS(16) * 3 + 20))
	end
	-- queue panel: a short panel (portrait) folds the player list into the note
	local qh = ui.Queue.Size.Y.Offset
	local busy = lastStatus == "Busy"
	local short = qh < 240 and not busy
	ui.QueueList.Visible = not short and not busy
	ui.QueueNote.Position = UDim2.fromOffset(0, (short or busy) and 68 or (72 + 4 * 30))
	ui.QueueNote.Size = UDim2.new(1, 0, 0, short and (TS(16) + 6) or (TS(16) * 3 + 8))
	ui.QueueNote.TextTruncate = short and Enum.TextTruncate.AtEnd or Enum.TextTruncate.None
	-- where the hero should sit on screen (read by CameraController's menu shot)
	workspace.CurrentCamera:SetAttribute("MenuHeroY", heroFrac)
	for _, s in pairs(screens) do
		if s.Layout then
			s.Layout(v, portrait, ins)
		end
	end
end

------------------------------------------------------------------------------------------
-- Screens
------------------------------------------------------------------------------------------

local function homeEntrance()
	local i = 0
	for _, b in ipairs(ui.ModeButtons) do
		i += 1
		UIAnim.Pop(b.Instance, Theme.Motion.Stagger * i, 0.85)
	end
	for _, b in ipairs({ ui.CardCharacters, ui.CardUpgrades, ui.CardArena }) do
		i += 1
		UIAnim.Pop(b.Instance, Theme.Motion.Stagger * i, 0.85)
	end
	UIAnim.Pop(ui.Nameplate, 0.1, 0.85)
	UIAnim.Pop(ui.Logo, 0, 0.9)
end

-- Slides to "Home" | "Characters" | "Upgrades" | "Stats" (old panel name "Shop" = Upgrades).
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
	local from = current
	current = name
	relayout()
	UIAnim.Tween(ui.Dim, Theme.Motion.Base, { BackgroundTransparency = (name == "Upgrades" or name == "Stats") and 0.4 or 1 })
	if from == "Characters" or name == "Characters" then
		local target = browse
		browse = nil
		if name == "Characters" and screens.Characters.Inspect then
			screens.Characters.Inspect(target or selectedChar())
		else
			Showcase.Show(selectedChar(), skinOf(selectedChar()))
			LobbyScreen.RefreshHero()
		end
	end
	local s = screens[name]
	if s and s.OnShow then
		s.OnShow(profile)
		Remotes.Get("RequestProfile"):FireServer()
	end
	if name == "Home" then
		homeEntrance()
		UIKit.FocusIfGamepad(ui.ModeButtons[1].Instance)
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
	ui.Vignette.Visible = on
	if on then
		-- always come back to the home screen
		for name in pairs(SCREEN_ORDER) do
			ui[name].Visible = false
		end
		current = "Home"
		browse = nil
		ui.Dim.BackgroundTransparency = 1
		UIAnim.SwapScreens(nil, ui.Home, 1, Config.UI.ScreenSlideSeconds)
		UIAnim.SlideIn(ui.Chip, Vector2.new(0, -60), 0)
		homeEntrance()
		lastStatus = ""
		LobbyScreen.RefreshHero()
		UIKit.FocusIfGamepad(ui.ModeButtons[1].Instance)
	end
end

-- Nameplate + hero on the dais: the selected character, or the locked one being browsed.
function LobbyScreen.RefreshHero()
	if not ui.NameTitle then
		return
	end
	local id = browse or selectedChar()
	local def = CharacterData.Characters[id] or CharacterData.Characters[CharacterData.Default]
	local locked = browse ~= nil
	ui.NameTitle.Text = def.Name
	ui.LockRow.Visible = locked
	ui.LockIcon.Visible = locked
	if locked and def.Unlock then
		-- earned through an achievement (the Ranger), never bought
		local a = AchievementData.Achievements[def.Unlock.Achievement]
		ui.NameSub.Text = string.format("Locked · %s", a and a.Description or "earn its achievement")
		ui.NameSub.TextColor3 = P.gold_300
		ui.Unlock.SetText("LOCKED")
		ui.Unlock.SetIcon("lock")
		ui.Unlock.SetEnabled(false)
	elseif locked then
		local afford = profile ~= nil and profile.Gold >= def.Cost
		ui.NameSub.Text = string.format("Locked · %s · %s", def.Role or "", def.BonusText or "")
		ui.NameSub.TextColor3 = P.gold_300
		ui.Unlock.SetText("UNLOCK  " .. UIKit.formatNumber(def.Cost))
		ui.Unlock.SetIcon("coin")
		ui.Unlock.SetEnabled(afford)
	else
		local skinId = skinOf(id)
		local skin = CharacterData.Skins[skinId]
		ui.NameSub.Text = (skin and (skin.Name .. " · ") or "") .. def.Description
		ui.NameSub.TextColor3 = C.TextMuted
		if current ~= "Characters" then
			Showcase.Show(id, skinId)
		end
	end
	relayout()
end

function LobbyScreen.SetJoined(on: boolean)
	joinedCountdown = on
end

function LobbyScreen.SetProfile(p: { [string]: any })
	profile = p
	if not ui.Frame then
		return
	end
	UIAnim.CountTo(ui.Gold.Value, shownGold or p.Gold, p.Gold, UIKit.formatNumber, 0.7)
	shownGold = p.Gold
	ui.Best.SetValue(UIKit.formatTime(p.Stats.BestTime))
	ui.Wins.SetValue(UIKit.formatNumber(p.Stats.Wins))
	if ui.PlayerTag then
		local colorDef = AchievementData.Colors[p.NameColor or ""]
		local nameColor = colorDef and colorDef.Color or P.ivory_200
		local title = (type(p.Title) == "string" and p.Title ~= "") and string.format('  <font color="%s">·  %s</font>', UIKit.hex(P.gold_300), string.upper(p.Title)) or ""
		ui.PlayerTag.Text = string.format('<font color="%s">%s</font>%s', UIKit.hex(nameColor), Players.LocalPlayer.DisplayName, title)
	end
	if browse and owned(browse) then
		browse = nil -- just bought it (the server also selects it)
	end
	LobbyScreen.RefreshHero()
	for _, s in pairs(screens) do
		if s.Refresh then
			s.Refresh(p)
		end
	end
end

local function clearQueueList()
	for _, c in ipairs(ui.QueueList:GetChildren()) do
		if c:IsA("GuiObject") then
			c:Destroy()
		end
	end
end

--[[
	Per-frame updates (cheap: only strings and visibility). The mode column swaps with the
	queue panel when a countdown or another run is going.
]]
function LobbyScreen.Update(_dt: number?)
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
		ui.QueueRing.Visible = true
		ui.QueueTitle.Text = string.upper(def and def.DisplayName or modeId) .. " RUN"
		ui.QueueCaption.Text = UIKit.track(string.format("Starting · %d/%d joined", joinedN, maxN))
		local num = tostring(seconds)
		if ui.QueueNumber.Text ~= num then
			ui.QueueNumber.Text = num
			UIAnim.Punch(ui.QueueRing, 0.15)
		end
		local names = state:GetAttribute("JoinedNames") or ""
		local key = names .. "|" .. maxN
		if ui.QueueKey ~= key then
			ui.QueueKey = key
			clearQueueList()
			local list = names ~= "" and string.split(names, ", ") or {}
			for i = 1, math.min(maxN, 4) do
				playerRow(list[i], i)
			end
		end
		local isStarter = state:GetAttribute("Starter") == player.UserId
		ui.Join.Instance.Visible = not joinedCountdown
		ui.StartNow.Instance.Visible = joinedCountdown and isStarter and joinedN >= 2
		local buttons = (ui.Join.Instance.Visible and 1 or 0) + (ui.StartNow.Instance.Visible and 1 or 0)
		ui.QueueRow.Visible = buttons > 0
		ui.Join.Instance.Size = UDim2.new(1 / math.max(1, buttons), -5, 1, 0)
		ui.StartNow.Instance.Size = UDim2.new(1 / math.max(1, buttons), -5, 1, 0)
		local note
		if joinedCountdown then
			note = (isStarter and joinedN < 2) and "You're in! Waiting for someone to join..." or "You're in! Get ready..."
		else
			note = "Tap JOIN to play together."
		end
		if not ui.QueueList.Visible and names ~= "" then
			note = names .. " · " .. note
		end
		ui.QueueNote.Text = note
	elseif phase == "Running" or phase == "Results" then
		kind = "Busy"
		ui.QueueRing.Visible = false
		ui.QueueTitle.Text = "RUN IN PROGRESS"
		local stageNo = state:GetAttribute("Stage") or 0
		ui.QueueCaption.Text = UIKit.track((stageNo > 0 and ("Stage " .. stageNo .. " · ") or "") .. "Time " .. UIKit.formatTime(state:GetAttribute("RunTime") or 0))
		ui.QueueNote.Text = "Wait here for the next one! Pick a character or buy upgrades meanwhile."
		ui.QueueRow.Visible = false
		if ui.QueueKey ~= "busy" then
			ui.QueueKey = "busy"
			clearQueueList()
		end
	else
		joinedCountdown = false
	end
	if kind ~= lastStatus then
		lastStatus = kind
		local showQueue = kind ~= "Modes"
		for _, b in ipairs(ui.ModeButtons) do
			b.Instance.Visible = not showQueue
		end
		ui.Queue.Visible = showQueue
		UIAnim.Pop(showQueue and ui.Queue or ui.ModeButtons[1].Instance, 0, 0.8)
		relayout()
	end

	local title, sub = arenaText()
	if ui.CardArena.Title and ui.CardArena.Title.Text ~= title then
		if ui.ArenaShown then
			UIAnim.Punch(ui.CardArena.Instance, 0.06)
		end
		ui.ArenaShown = true
		ui.CardArena.SetText(title, sub)
	elseif ui.CardArena.Subtitle and ui.CardArena.Subtitle.Text ~= sub then
		ui.CardArena.SetText(nil, sub)
	end
end

function LobbyScreen.Init(h: { [string]: any })
	host = h
	local frame = new("Frame", { Name = "Lobby", Size = UDim2.fromScale(1, 1), BackgroundTransparency = 1, Visible = false, ZIndex = Theme.Z.Lobby }, h.Root)
	ui.Frame = frame
	buildVignette(h.FxGui)
	ui.Screens = new("Frame", { Name = "Screens", BackgroundTransparency = 1, Size = UDim2.fromScale(1, 1) }, frame)
	local function screen(name: string): Frame
		local f = new("Frame", { Name = name, Size = UDim2.fromScale(1, 1), BackgroundTransparency = 1, Visible = false }, ui.Screens)
		ui[name] = f
		return f
	end
	buildHome(screen("Home"))
	buildChip(frame)
	local ctx = {
		Host = h,
		Back = function()
			LobbyScreen.Show("Home")
		end,
		Toast = toast,
		Current = function(): string
			return current
		end,
		Profile = function(): { [string]: any }?
			return profile
		end,
	}
	screens.Characters = MenuCharacters.Build(screen("Characters"), ctx)
	screens.Upgrades = MenuUpgrades.Build(screen("Upgrades"), ctx)
	screens.Stats = MenuStats.Build(screen("Stats"), ctx)
	h.OnRelayout(relayout)
	relayout()
end

return LobbyScreen
