--[[
	LobbyScreen.lua
	The main menu, shown whenever the player is not in a run. The 3D castle courtyard at
	dusk is the backdrop and the hero stands on the lit dais in the middle (Showcase.lua,
	drag to spin). The home screen is deliberately simple (owner mockup "One big PLAY"):

	  top left      SWARM logo + "SURVIVE ◆ UPGRADE ◆ CONQUER"
	  top right     gold chip (every screen) and the settings cog (home)
	  centre        the hero; under it the hero selector pill "‹ NAME ›" with the hero's
	                Hero Mastery level and bar (arrows switch between owned heroes, a tap
	                on the name opens HEROES)
	  bottom left   one panel: HEROES (MenuCharacters) / SHOP (MenuUpgrades) / MORE
	                (MenuMore: Daily, Party, Ranks, Stats, Account Level, Journal,
	                Achievements, Settings, Report a bug, DEV) with the party invite badge
	  bottom right  the big PLAY button (starts the picked mode with the current options:
	                one tap to a run) and under it the mode selector "SOLO ›" that opens
	                the PLAY sheet (MenuPlay: Solo / Duo / Trio, Arena, Difficulty,
	                Curses, Endless, LAST RUN + RETRY, START). A party member gets a small
	                READY pill above PLAY. A countdown (who joined, the curses, an ENDLESS
	                line, JOIN, START NOW, the number) or "run in progress" replaces PLAY.
	Portrait stacks: chip + cog, logo, hero, hero pill, tiles, PLAY, mode selector.

	A brand-new player (no run ever started, tutorial not done) asks the server once for
	the automatic first Solo run (remote StartFirstRun, Config.FirstRun); the server
	decides and answers with the player attribute FirstRun. Meanwhile a plain cover says
	the run is starting (at most Config.FirstRun.CoverSeconds).

	Sub-screens slide in: Characters (MenuCharacters), Upgrades (MenuUpgrades), Play
	(MenuPlay), More (MenuMore), Stats (MenuStats), Journal (MenuJournal), Curses
	(MenuCurses), Daily (MenuDaily), Ranks (MenuLeaderboards), Track (MenuTrack), Arenas
	(MenuArenas), Party (MenuParty); Settings is UIBuilder's modal. BACK returns to the
	screen's parent (PARENT). Everything sent to the server is an id or a mode name; the
	server validates it (RunManager: StartRun / JoinRun / StartNow / CycleArena,
	GoldSystem: purchases and selection).
]]

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared:WaitForChild("Config"))
local Remotes = require(Shared:WaitForChild("Remotes"))
local Theme = require(Shared:WaitForChild("Theme"))
local CharacterData = require(Shared:WaitForChild("CharacterData"))
local MetaUpgradeData = require(Shared:WaitForChild("MetaUpgradeData"))
local CurseData = require(Shared:WaitForChild("CurseData"))
local UIKit = require(script.Parent.UIKit)
local UIAnim = require(script.Parent.UIAnim)
local Icons = require(script.Parent.Icons)
local ArtImage = require(script.Parent.ArtImage)
local Showcase = require(script.Parent.Showcase)
local MenuCharacters = require(script.Parent.MenuCharacters)
local MenuUpgrades = require(script.Parent.MenuUpgrades)
local MenuStats = require(script.Parent.MenuStats)
local MenuCurses = require(script.Parent.MenuCurses)
local MenuDaily = require(script.Parent.MenuDaily)
local MenuJournal = require(script.Parent.MenuJournal)
local MenuLeaderboards = require(script.Parent.MenuLeaderboards)
local MenuTrack = require(script.Parent.MenuTrack)
local MenuArenas = require(script.Parent.MenuArenas)
local MenuParty = require(script.Parent.MenuParty)
local NoticeDots = require(script.Parent.NoticeDots)
local MenuPlay = require(script.Parent.MenuPlay)
local MenuMore = require(script.Parent.MenuMore)

local LobbyScreen = {}

local player = Players.LocalPlayer
local new, text, TS = UIKit.new, UIKit.text, UIKit.TS
local C, P = Theme.Color, Theme.Palette

local host: { [string]: any } = {}
local profile: { [string]: any }? = nil
local joinedCountdown = false
local ui: { [string]: any } = {}
local current = "Home"
local SCREEN_ORDER = { Home = 1, Play = 1.5, Characters = 2, Upgrades = 3, Arenas = 3.5, More = 3.8, Stats = 4, Journal = 4.5, Curses = 5, Daily = 6, Ranks = 7, Track = 8, Party = 9 }
-- where BACK goes from each screen (anything else goes home)
local PARENT = { Arenas = "Play", Curses = "Play", Daily = "More", Party = "More", Ranks = "More", Stats = "More", Track = "More", Journal = "More" }
local screens: { [string]: any } = {}
local shownGold: number? = nil
local lastStatus = ""
local lastPartyCount = 0
-- the automatic first run: "" (not asked), "Asked" (waiting for the server), "Done"
local firstRun = ""
local firstRunAt = 0

local function place(obj: GuiObject, x: number, y: number, w: number, h: number)
	obj.Position = UDim2.fromOffset(math.floor(x + 0.5), math.floor(y + 0.5))
	obj.Size = UDim2.fromOffset(math.floor(w + 0.5), math.floor(h + 0.5))
end

-- Home palette taken from the reference (brighter than the antique UI gold on purpose:
-- the PLAY plate is the one bright thing on the screen)
local NAVY = Color3.fromRGB(16, 22, 38)
local PLAY_HI = Color3.fromRGB(255, 233, 150)
local PLAY_MID = Color3.fromRGB(242, 194, 74)
local PLAY_LO = Color3.fromRGB(196, 139, 38)
local PLAY_RIM = Color3.fromRGB(122, 80, 20)
local PLAY_LINE = Color3.fromRGB(255, 243, 200)

local decoratePlay: (b: any) -> ()

-- A thin gold border drawn on its own frame, so a button's hover / press repaint (which
-- resets the face's own stroke) never takes it away.
local function goldEdge(face: GuiObject, radius: number, transparency: number?, thickness: number?): Frame
	local f = new("Frame", { Name = "GoldEdge", BackgroundTransparency = 1, Size = UDim2.fromScale(1, 1), ZIndex = 2, Active = false }, face)
	UIKit.corner(f, radius)
	UIKit.stroke(f, P.gold_400, thickness or 1.5, transparency or 0.1)
	return f
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
	-- the tagline: small letter-spaced ivory serif words with gold diamonds between them
	-- (Roblox has no letter spacing, so the letters are spaced by hand; the diamonds are drawn)
	local tagline = new("Frame", { Name = "Tagline", BackgroundTransparency = 1, Position = UDim2.fromOffset(4, 100), Size = UDim2.fromOffset(280, 18) }, logo)
	UIKit.list(tagline, { FillDirection = Enum.FillDirection.Horizontal, HorizontalAlignment = Enum.HorizontalAlignment.Center, VerticalAlignment = Enum.VerticalAlignment.Center, Padding = UDim.new(0, 9) })
	for i, w in ipairs({ "SURVIVE", "UPGRADE", "CONQUER" }) do
		if i > 1 then
			local d = new("Frame", { Name = "Diamond" .. i, BackgroundColor3 = P.gold_400, BorderSizePixel = 0, Rotation = 45, Size = UDim2.fromOffset(6, 6), LayoutOrder = i * 2 - 1 }, tagline)
			d.Active = false
		end
		local spaced = string.sub((string.gsub(w, "(.)", "%1 ")), 1, -2)
		new("TextLabel", {
			Name = "Word" .. i,
			BackgroundTransparency = 1,
			AutomaticSize = Enum.AutomaticSize.X,
			Size = UDim2.fromOffset(0, 18),
			Text = spaced,
			FontFace = Theme.Font.Title,
			TextSize = 11,
			TextColor3 = P.ivory_100,
			TextStrokeColor3 = C.Shadow,
			TextStrokeTransparency = 0.55,
			LayoutOrder = i * 2,
		}, tagline)
	end
	-- the painted logo (screens/logo_SWARM, 2:1) replaces the sword and letters; they stay
	-- as the fallback while it loads or if it is not uploaded. The frame grows to fit it.
	ui.LogoW, ui.LogoH = 350, 130
	local drawn = { sword }
	for _, ch in ipairs(logo:GetChildren()) do
		if ch:IsA("TextLabel") and ch.Name ~= "Tagline" then
			table.insert(drawn, ch)
		end
	end
	local art = ArtImage.Place(logo, "screens/logo_SWARM", { Name = "LogoArt", Position = UDim2.fromOffset(0, -4), Size = UDim2.fromOffset(280, 140), ZIndex = 2 }, drawn)
	if art then
		ui.LogoW, ui.LogoH = 280, 162
		logo.Size = UDim2.fromOffset(360, 162)
		-- under the painted logo's frame (the picture's box ends at 136), centred on it
		tagline.Position = UDim2.fromOffset(0, 134)
		tagline.Size = UDim2.fromOffset(280, 18)
	end
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
-- Gold chip + settings cog (top right)
------------------------------------------------------------------------------------------

local function buildChip(frame: Frame)
	-- a compact dark rounded plate with a thin gold edge (reference: not a full pill)
	local holder, face = UIKit.Surface(frame, { Name = "StatsChip", Radius = 10, Color = NAVY, Transparency = 0.12, Edge = P.gold_400, EdgeTransparency = 0.2, Size = UDim2.fromOffset(0, 48) })
	holder.AutomaticSize = Enum.AutomaticSize.X
	face.AutomaticSize = Enum.AutomaticSize.X
	face.Size = UDim2.fromScale(0, 1)
	UIKit.padding(face, 0, 18, 0, 14)
	UIKit.list(face, { FillDirection = Enum.FillDirection.Horizontal, VerticalAlignment = Enum.VerticalAlignment.Center, Padding = UDim.new(0, 10) })
	ui.Chip = holder
	ui.ChipFace = face
	-- gold only (best time / wins live on the STATS screen)
	ui.Gold = UIKit.Chip(face, "lobby_Gold", nil, "0", { Name = "Gold", LayoutOrder = 1, Size = UDim2.fromOffset(0, 48) }, { Size = 28 })
	ui.Gold.Value.FontFace = Theme.Font.Title
	ui.Gold.Value.TextColor3 = P.gold_200
	-- the settings cog beside it (home only; it stays still)
	ui.Cog = UIKit.IconButton(frame, {
		Icon = "gear",
		Size = 48,
		IconSize = 30,
		Name = "SettingsCog",
		OnClick = function()
			if host.OpenSettings then
				host.OpenSettings()
			end
		end,
	})
	-- square dark plate, gold edge, plain gold gear (the reference); the painted wrench-and-
	-- gear picture read as a different icon, so the drawn gold gear stays until the gold
	-- gear picture (ui/home/home_Gear) is uploaded
	goldEdge(ui.Cog.Face, Theme.Radius.M, 0.15)
	ArtImage.ButtonIcon(ui.Cog.Content, "ui/home/home_Gear", { Size = UDim2.fromOffset(34, 34) }, "Glyph")
end

-- CHARACTERS shows the stats inline in the top bar: no pill box (face, edge, shadow) behind them
local function setChipFlat(flat: boolean)
	local face = ui.ChipFace
	if not face or (ui.ChipFlat == true) == flat then
		return
	end
	if ui.ChipAlpha == nil then
		ui.ChipAlpha = face.BackgroundTransparency
	end
	ui.ChipFlat = flat
	face.BackgroundTransparency = flat and 1 or ui.ChipAlpha
	local edge = face:FindFirstChildOfClass("UIStroke")
	if edge then
		edge.Enabled = not flat
	end
	for _, name in ipairs({ "Shadow", "ShadowWide" }) do
		local sh = ui.Chip:FindFirstChild(name)
		if sh and sh:IsA("GuiObject") then
			sh.Visible = not flat
		end
	end
end

--[[
	"Loading models…" pill under the stats chip while the server is still loading the
	lobby / hero meshes (ReplicatedStorage.SwarmMeshes: Loaded / Total, PriorityReady). The
	menu works the whole time; the pill only says why things still look plain. It fades
	out once the lobby and heroes are in.
]]
local function buildLoadingPill()
	local pill = new("Frame", { Name = "LoadingPill", BackgroundColor3 = P.slate_900, BackgroundTransparency = 0.25, Size = UDim2.fromOffset(0, 30), AutomaticSize = Enum.AutomaticSize.X, Position = UDim2.new(1, 0, 0, 56), AnchorPoint = Vector2.new(1, 0), Visible = false }, ui.Chip)
	UIKit.corner(pill, 999)
	UIKit.stroke(pill, P.gold_500, 1, 0.55)
	UIKit.padding(pill, 0, 14, 0, 12)
	UIKit.list(pill, { FillDirection = Enum.FillDirection.Horizontal, VerticalAlignment = Enum.VerticalAlignment.Center, Padding = UDim.new(0, 8) })
	local dot = new("Frame", { Name = "Dot", BackgroundColor3 = P.gold_300, Size = UDim2.fromOffset(8, 8), LayoutOrder = 1 }, pill)
	UIKit.corner(dot, 999)
	UIAnim.Glow(dot, "BackgroundTransparency", 0, 0.75, 0.7)
	ui.LoadingText = text(pill, "Small", "Loading models…", { Name = "Text", AutomaticSize = Enum.AutomaticSize.X, Size = UDim2.fromOffset(0, 30), LayoutOrder = 2, TextColor3 = P.ivory_200 })
	ui.LoadingPill = pill
end

local function updateLoadingPill()
	local pill = ui.LoadingPill
	if not pill then
		return
	end
	local folder = ReplicatedStorage:FindFirstChild("SwarmMeshes")
	local total = folder and tonumber(folder:GetAttribute("Total")) or 0
	local show = folder ~= nil and total > 0 and folder:GetAttribute("PriorityReady") ~= true
	-- DEV: models that failed to load stay reported (why heroes show their part stand-ins)
	local failed = folder and tonumber(folder:GetAttribute("Failed")) or 0
	local dev = RunService:IsStudio() or Players.LocalPlayer:GetAttribute("DevAccess") == true
	-- (a DEV note: only on the MORE screen, never in the home composition)
	if folder and not show and failed > 0 and dev and current == "More" then
		ui.LoadingText.Text = string.format("DEV · %d of %d models failed · %s", failed, total, tostring(folder:GetAttribute("LastError") or ""))
		pill.AnchorPoint = Vector2.new(ui.Chip.AnchorPoint.X, 0)
		pill.Position = UDim2.new(ui.Chip.AnchorPoint.X, 0, 0, 56)
		pill.Visible = true
		ui.LoadingShown = true
	elseif show then
		-- progress of what the menu needs (lobby + heroes), else of everything
		local need = tonumber(folder:GetAttribute("PriorityTotal")) or 0
		local done = tonumber(folder:GetAttribute("PriorityDone")) or 0
		if need <= 0 then
			need = total
			done = (tonumber(folder:GetAttribute("Loaded")) or 0) + (tonumber(folder:GetAttribute("Failed")) or 0)
		end
		ui.LoadingText.Text = string.format("Loading models… %d%%", math.floor(100 * math.clamp(done / need, 0, 1)))
		pill.AnchorPoint = Vector2.new(ui.Chip.AnchorPoint.X, 0)
		pill.Position = UDim2.new(ui.Chip.AnchorPoint.X, 0, 0, 56)
		pill.Visible = true
		ui.LoadingShown = true
	elseif ui.LoadingShown then
		ui.LoadingShown = false
		UIAnim.PopOut(pill, function()
			pill.Visible = false
		end)
	end
end

------------------------------------------------------------------------------------------
-- Home: hero selector pill
------------------------------------------------------------------------------------------

-- Arrows: the next / previous OWNED hero (selected at once; the server confirms).
local selectToken = 0
local function browseStep(dir: number)
	local order = CharacterData.Order
	local cur = selectedChar()
	local i = table.find(order, cur) or 1
	local nextId = nil
	for step = 1, #order - 1 do
		local id = order[((i - 1 + dir * step) % #order) + 1]
		if owned(id) then
			nextId = id
			break
		end
	end
	if not nextId then
		toast("Unlock more heroes in HEROES.", P.gold_300)
		UIAnim.Bump(ui.HeroPill, 0.04)
		return
	end
	if profile then
		-- show it at once; the server's profile sync confirms
		profile.SelectedCharacter = nextId
	end
	-- send only the last of several quick taps (the remote is rate limited), then ask
	-- for the profile so the server's choice always wins on screen
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
	LobbyScreen.RefreshHero()
	UIAnim.Bump(ui.HeroName, 0.08)
end

local function buildHeroPill(screen: Frame)
	local holder, face = UIKit.Surface(screen, { Name = "HeroPill", Radius = 999, Color = NAVY, Transparency = 0.1, Edge = P.gold_400, EdgeTransparency = 0.15, EdgeThickness = 1.5 })
	ui.HeroPill = holder
	-- the middle opens HEROES
	local open = new("TextButton", { Name = "Open", Text = "", AutoButtonColor = false, BackgroundTransparency = 1, Position = UDim2.fromOffset(56, 0), Size = UDim2.new(1, -112, 1, 0), ZIndex = 3 }, face)
	UIKit.Focusable(open)
	open.Activated:Connect(function()
		UIKit.Click()
		LobbyScreen.Show("Characters")
	end)
	ui.HeroName = text(face, "Label", "KNIGHT", {
		Name = "HeroName",
		AnchorPoint = Vector2.new(0.5, 0),
		Position = UDim2.new(0.5, 0, 0, 8),
		Size = UDim2.new(1, -112, 0, TS(18) + 4),
		TextXAlignment = Enum.TextXAlignment.Center,
		TextColor3 = P.ivory_100,
		TextTruncate = Enum.TextTruncate.AtEnd,
		FontFace = Theme.Font.Title,
	}, 16)
	ui.HeroLevel = text(face, "Caption", "LV 1", {
		Name = "HeroLevel",
		Position = UDim2.new(0.5, -84, 0, 14 + TS(18)),
		Size = UDim2.fromOffset(48, TS(12) + 4),
		TextColor3 = P.gold_300,
	}, 12)
	ui.HeroBar = UIKit.Meter(face, {
		Gradient = ColorSequence.new(P.gold_500, P.gold_300),
		Position = UDim2.new(0.5, -34, 0, 18 + TS(18)),
		Size = UDim2.fromOffset(118, 8),
	})
	ui.PrevArrow = UIKit.IconButton(face, {
		Icon = "chevronLeft",
		Size = 44,
		Round = true,
		Name = "Prev",
		AnchorPoint = Vector2.new(0, 0.5),
		Position = UDim2.new(0, 8, 0.5, 0),
		OnClick = function()
			browseStep(-1)
		end,
	})
	ui.NextArrow = UIKit.IconButton(face, {
		Icon = "chevronRight",
		Size = 44,
		Round = true,
		Name = "Next",
		AnchorPoint = Vector2.new(1, 0.5),
		Position = UDim2.new(1, -8, 0.5, 0),
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

------------------------------------------------------------------------------------------
-- Home: HEROES / SHOP / MORE tiles, PLAY and the mode selector
------------------------------------------------------------------------------------------

local function buildTiles(screen: Frame)
	-- the dock: dark navy plate, thin gold border, rounded corners (reference). The painted
	-- frame (ui/home/home_DockFrame, 9-slice) replaces the drawn border once uploaded.
	local holder, face = UIKit.Surface(screen, { Name = "Tiles", Radius = 12, Color = NAVY, Transparency = 0.1, Edge = P.gold_400, EdgeTransparency = 0.1, EdgeThickness = 1.5 })
	ui.Tiles = holder
	ui.TilesFace = face
	local edge = face:FindFirstChildOfClass("UIStroke")
	ArtImage.Place(face, "ui/home/home_DockFrame", {
		Name = "DockArt",
		ScaleType = Enum.ScaleType.Slice,
		SliceCenter = Rect.new(64, 64, 704, 192),
		SliceScale = 0.35,
		Size = UDim2.fromScale(1, 1),
		ZIndex = 2,
	}, edge and function(show: boolean)
		edge.Enabled = show
	end or nil)
	local function tile(name: string, icon: string, caption: string, order: number, onClick: () -> ()): any
		local b = UIKit.IconButton(face, { Icon = icon, Caption = caption, Kind = "Ghost", Size = 96, IconSize = 46, Name = name, LayoutOrder = order, OnClick = onClick })
		local cap = b.Content:FindFirstChild("Caption") :: TextLabel?
		if cap then
			cap.TextColor3 = P.ivory_100
			cap.FontFace = Theme.Font.Title
			cap.TextSize = TS(15)
			cap.Size = UDim2.new(1, -4, 0, TS(15) + 4)
		end
		-- the gold dock icon picture (ui/home/home_<Name>) over the drawn one once uploaded
		ArtImage.ButtonIcon(b.Content, "ui/home/home_" .. name, { Size = UDim2.fromOffset(52, 52), AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.new(0.5, 0, 0.5, -TS(Theme.TextSize.Caption) / 2 - 4) }, name == "More" and "Dots" or "Glyph")
		return b
	end
	ui.HeroesTile = tile("Heroes", "helmet", "Heroes", 1, function()
		LobbyScreen.Show("Characters")
	end)
	ui.ShopTile = tile("Shop", "chest", "Shop", 2, function()
		LobbyScreen.Show("Upgrades")
	end)
	ui.MoreTile = tile("More", "plus", "More", 3, function()
		LobbyScreen.Show("More")
	end)
	-- MORE: three gold dots instead of a glyph
	local glyph = ui.MoreTile.Content:FindFirstChild("Glyph")
	if glyph then
		glyph:Destroy()
	end
	local dots = new("Frame", { Name = "Dots", BackgroundTransparency = 1, AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.new(0.5, 0, 0.5, -TS(Theme.TextSize.Caption) / 2 - 2), Size = UDim2.fromOffset(44, 12) }, ui.MoreTile.Content)
	for i = 0, 2 do
		local d = new("Frame", { BackgroundColor3 = P.gold_400, BorderSizePixel = 0, Position = UDim2.fromOffset(i * 16, 0), Size = UDim2.fromOffset(12, 12) }, dots)
		UIKit.corner(d, 999)
	end
	ui.MoreBadge = UIKit.Badge(ui.MoreTile.Instance, "", "Crimson", { Name = "InviteBadge", AnchorPoint = Vector2.new(1, 0), Position = UDim2.new(1, -6, 0, 6), ZIndex = 6, Visible = false })
	-- notice dots (NoticeDots): something new behind the tile (the invite badge sits on top)
	NoticeDots.Attach("Heroes", ui.HeroesTile.Instance, { Position = UDim2.new(1, -14, 0, 14) })
	NoticeDots.Attach("Shop", ui.ShopTile.Instance, { Position = UDim2.new(1, -14, 0, 14) })
	NoticeDots.Attach("More", ui.MoreTile.Instance, { Position = UDim2.new(1, -14, 0, 14) })
	-- thin gold separators between the tiles
	ui.TileSeps = {}
	for i = 1, 2 do
		ui.TileSeps[i] = new("Frame", { Name = "Sep" .. i, BackgroundColor3 = P.gold_400, BackgroundTransparency = 0.45, BorderSizePixel = 0 }, face)
	end
end

--[[
	The ornate PLAY plate (reference: bright gold gradient, a dark bronze rim with a light
	inner bevel line, small corner studs, a faint crown behind the letters, dark serif
	lettering, right arrow). Built from UI objects as a best-effort stand-in: it is NOT the
	painted plate. Once ui/home/home_PlayButton is uploaded (docs/IMAGE_PROMPTS.md group 22)
	the picture covers the drawn rim, bevel, studs and crown (the letters stay live text).
]]
decoratePlay = function(b: any)
	local face: Frame = b.Face
	local radius = Theme.Radius.M
	-- the bright gold fill sits over the kit's antique gradient (hover / press repaint the
	-- face underneath; this layer keeps the reference's colour)
	local fill = new("Frame", { Name = "GoldFill", BackgroundColor3 = Color3.new(1, 1, 1), BorderSizePixel = 0, Size = UDim2.fromScale(1, 1), ZIndex = 1, Active = false }, face)
	UIKit.corner(fill, radius)
	new("UIGradient", {
		Rotation = 90,
		Color = ColorSequence.new({
			ColorSequenceKeypoint.new(0, PLAY_HI),
			ColorSequenceKeypoint.new(0.42, PLAY_MID),
			ColorSequenceKeypoint.new(1, PLAY_LO),
		}),
	}, fill)
	local hover = face:FindFirstChild("Hover")
	if hover and hover:IsA("GuiObject") then
		hover.ZIndex = 2
	end
	local drawn: { GuiObject } = {}
	-- outer bronze rim (thick) and the light bevel line inside it
	local rim = new("Frame", { Name = "Rim", BackgroundTransparency = 1, Size = UDim2.fromScale(1, 1), ZIndex = 2, Active = false }, face)
	UIKit.corner(rim, radius)
	UIKit.stroke(rim, PLAY_RIM, 3, 0)
	table.insert(drawn, rim)
	local line = new("Frame", { Name = "Bevel2", BackgroundTransparency = 1, Position = UDim2.fromOffset(6, 6), Size = UDim2.new(1, -12, 1, -12), ZIndex = 2, Active = false }, face)
	UIKit.corner(line, math.max(2, radius - 4))
	UIKit.stroke(line, PLAY_LINE, 1.5, 0.15)
	table.insert(drawn, line)
	local shade = new("Frame", { Name = "Bevel3", BackgroundTransparency = 1, Position = UDim2.fromOffset(8, 8), Size = UDim2.new(1, -16, 1, -16), ZIndex = 2, Active = false }, face)
	UIKit.corner(shade, math.max(2, radius - 6))
	UIKit.stroke(shade, PLAY_LO, 1, 0.35)
	table.insert(drawn, shade)
	-- small diamond studs in the corners of the bevel line
	for _, at in ipairs({ Vector2.new(0, 0), Vector2.new(1, 0), Vector2.new(0, 1), Vector2.new(1, 1) }) do
		local stud = new("Frame", {
			Name = "Stud",
			BackgroundColor3 = PLAY_RIM,
			BorderSizePixel = 0,
			Rotation = 45,
			AnchorPoint = Vector2.new(0.5, 0.5),
			Position = UDim2.new(at.X, at.X == 0 and 14 or -14, at.Y, at.Y == 0 and 14 or -14),
			Size = UDim2.fromOffset(6, 6),
			ZIndex = 2,
			Active = false,
		}, face)
		table.insert(drawn, stud)
	end
	-- a bigger arrow (reference), scaled so the kit's repaint keeps it
	local right = b.Content:FindFirstChild("Right")
	if right then
		new("UIScale", { Name = "Big", Scale = 1.6 }, right)
	end
	-- the faint crown behind the letters
	local crownHolder = new("CanvasGroup", { Name = "Crown", BackgroundTransparency = 1, GroupTransparency = 0.68, AnchorPoint = Vector2.new(0.5, 0), Position = UDim2.new(0.5, 0, 0, 3), Size = UDim2.fromOffset(64, 44), ZIndex = 2 }, face)
	Icons.Draw(crownHolder, "crown", { Size = 44, Color = PLAY_HI, Back = PLAY_MID, AnchorPoint = Vector2.new(0.5, 0), Position = UDim2.fromScale(0.5, 0) })
	table.insert(drawn, crownHolder)
	ui.PlayCrown = crownHolder
	ArtImage.Place(face, "ui/home/home_PlayButton", { Name = "PlayArt", ScaleType = Enum.ScaleType.Stretch, Size = UDim2.fromScale(1, 1), ZIndex = 2 }, drawn)
end

local function buildPlay(screen: Frame)
	-- the wrapper breathes (a gentle pulse); the button inside keeps its press feedback
	ui.PlayHolder = new("Frame", { Name = "PlayHolder", BackgroundTransparency = 1 }, screen)
	ui.PlayBtn = UIKit.Button(ui.PlayHolder, {
		Kind = "Primary",
		Glow = true,
		Title = "PLAY",
		TitleStyle = "H1",
		TitleSize = 46,
		Chevron = true,
		Align = "Center",
		Name = "Play",
		Size = UDim2.fromScale(1, 1),
		OnClick = function()
			MenuPlay.Start(toast)
		end,
	})
	if ui.PlayBtn.Title then
		ui.PlayBtn.Title.FontFace = Theme.Font.Display
		ui.PlayBtn.Title.TextColor3 = Color3.fromRGB(28, 18, 6)
	end
	decoratePlay(ui.PlayBtn)
	ui.PlayBtn.Face.ClipsDescendants = true
	UIAnim.Shine(ui.PlayBtn.Face, 3.2, 0.78)
	if not UIAnim.Reduced() then
		UIAnim.Breathe(ui.PlayHolder, 0.025, 1.4)
	end
	ui.ModeSelect = UIKit.Button(screen, {
		Kind = "Secondary",
		Title = "SOLO",
		TitleStyle = "Label",
		TitleSize = 17,
		Chevron = true,
		Align = "Center",
		Shrink = true,
		Name = "ModeSelect",
		OnClick = function()
			LobbyScreen.Show("Play")
		end,
	})
	-- reference: a narrower dark plate, thin gold border, ivory serif text, gold chevron
	if ui.ModeSelect.Title then
		ui.ModeSelect.Title.FontFace = Theme.Font.Title
	end
	goldEdge(ui.ModeSelect.Face, Theme.Radius.M, 0.15)
	ArtImage.Place(ui.ModeSelect.Face, "ui/home/home_ModeFrame", {
		Name = "ModeArt",
		ScaleType = Enum.ScaleType.Slice,
		SliceCenter = Rect.new(48, 48, 592, 80),
		SliceScale = 0.3,
		Size = UDim2.fromScale(1, 1),
		ZIndex = 2,
	}, { ui.ModeSelect.Face:FindFirstChild("GoldEdge") :: GuiObject })
	-- a party member's READY toggle (the leader's start waits for everyone)
	ui.ReadyBtn = UIKit.Button(screen, {
		Kind = "Primary",
		Title = "READY",
		Icon = "check",
		IconSize = 18,
		Align = "Center",
		Name = "PartyReady",
		OnClick = function()
			MenuParty.SetReady(not MenuParty.Summary().MyReady)
		end,
	})
	ui.ReadyBtn.Instance.Visible = false
	MenuPlay.OnModeChanged(function()
		LobbyScreen._modeText()
	end)
end

-- The selector's text: the mode and anything that changes the run ("SOLO · ENDLESS").
function LobbyScreen._modeText()
	if ui.ModeSelect then
		local line = MenuPlay.Summary()
		if ui.ModeSelect.Instance:GetAttribute("Line") ~= line then
			ui.ModeSelect.Instance:SetAttribute("Line", line)
			ui.ModeSelect.SetText(line)
		end
	end
end

-- "Starting your first run…" while the server answers a brand-new player's StartFirstRun.
local function buildFirstRunCover(frame: Frame)
	local cover = new("Frame", { Name = "FirstRunCover", BackgroundColor3 = C.Backdrop, BackgroundTransparency = 0.15, BorderSizePixel = 0, Size = UDim2.fromScale(1, 1), ZIndex = 20, Visible = false, Active = true }, frame)
	text(cover, "H1", "Starting your first run…", { Name = "Text", AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.5), Size = UDim2.new(1, -40, 0, TS(30) + 8), TextXAlignment = Enum.TextXAlignment.Center, ZIndex = 21 })
	ui.FirstRunCover = cover
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
	-- the run's curses (the starter's pick): a tap opens the CURSES screen
	local curseRow = new("TextButton", { Name = "QueueCurses", Text = "", AutoButtonColor = false, BackgroundColor3 = C.PanelInset, BackgroundTransparency = 0.25, Size = UDim2.new(1, 0, 0, 56) }, face)
	UIKit.corner(curseRow, Theme.Radius.S)
	UIKit.stroke(curseRow, P.crimson_400, 1, 0.45)
	Icons.Draw(curseRow, "curse", { Size = 22, AnchorPoint = Vector2.new(0, 0.5), Position = UDim2.new(0, 8, 0.5, 0), Back = C.PanelInset })
	-- two lines: several curses wrap instead of reading "Frenz..."
	ui.QueueCurseText = text(curseRow, "Label", "", { Position = UDim2.fromOffset(38, 0), Size = UDim2.new(1, -46, 1, 0), TextWrapped = true, TextTruncate = Enum.TextTruncate.AtEnd, RichText = true }, 13)
	curseRow.Activated:Connect(function()
		UIKit.Click()
		LobbyScreen.Show("Curses")
	end)
	ui.QueueCurses = curseRow
	-- an Endless run (the starter's switch, SwarmState Endless)
	local endlessRow = new("Frame", { Name = "QueueEndless", BackgroundColor3 = C.PanelInset, BackgroundTransparency = 0.25, Size = UDim2.new(1, 0, 0, 32), Visible = false }, face)
	UIKit.corner(endlessRow, Theme.Radius.S)
	UIKit.stroke(endlessRow, P.gold_400, 1, 0.45)
	Icons.Draw(endlessRow, "cycle", { Size = 20, AnchorPoint = Vector2.new(0, 0.5), Position = UDim2.new(0, 8, 0.5, 0), Back = C.PanelInset })
	text(endlessRow, "Label", string.format('<font color="%s">ENDLESS</font>  no win, only deeper stages', UIKit.hex(P.gold_300)), { Position = UDim2.fromOffset(36, 0), Size = UDim2.new(1, -44, 1, 0), TextTruncate = Enum.TextTruncate.AtEnd, RichText = true }, 13)
	ui.QueueEndless = endlessRow
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
	buildHeroPill(screen)
	buildTiles(screen)
	buildPlay(screen)
	buildQueue(screen)
end

------------------------------------------------------------------------------------------
-- Layout
------------------------------------------------------------------------------------------

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
	local home = current == "Home"
	local showQueue = lastStatus == "Countdown" or lastStatus == "Busy"

	setChipFlat(not portrait and current == "Characters")
	-- every screen shows the gold chip; phones in landscape put it in the Roblox top-bar
	-- row (right of the Roblox buttons) on the sub-screens, above the screen's header
	local topRowChip = compact and not portrait and not home and ins.Top >= 48
	ui.Chip.Visible = topRowChip or not (compact and not portrait and not home and current ~= "Characters")
	ui.Cog.Instance.Visible = home
	local chipY = ins.Right > 4 and (ins.Top + 6) or 12
	if portrait then
		chipY = ins.Top >= 48 and math.max(4, math.floor((ins.Top - 52) / 2)) or 12
	elseif current == "Characters" or topRowChip then
		chipY = math.max(0, math.floor((ins.Top - 48) / 2))
	end
	-- home in landscape: the reference's margins (~4 % from the top, ~2 % from the right)
	local homeWide = home and not portrait
	local rightM = homeWide and math.max(M, math.floor(W * 0.022)) or M
	if homeWide and ins.Right <= 4 then
		chipY = math.max(chipY, math.floor(H * 0.04))
	end
	local cogS = 48
	local cogW = home and (cogS + math.max(G, homeWide and math.floor(W * 0.014) or G)) or 0
	ui.Chip.AnchorPoint = Vector2.new(1, 0)
	if portrait and not home then
		-- portrait sub-screens: under their header, centred
		ui.Chip.AnchorPoint = Vector2.new(0.5, 0)
		ui.Chip.Position = UDim2.fromOffset(W / 2, math.max(ins.Top + 4, 12) + 64)
	else
		ui.Chip.Position = UDim2.fromOffset(W - rightM - cogW, chipY)
	end
	place(ui.Cog.Instance, W - rightM - cogS, chipY, cogS, cogS)

	local heroFrac = 0.5
	local pillH = 64
	local tilesW = 3 * (compact and 92 or 104) + 16
	local tilesH = compact and 92 or 104
	if portrait then
		local logoScale = math.clamp((W - 2 * M) / 380, 0.66, 0.9)
		ui.LogoScale.Scale = logoScale
		local logoY = math.max(chipY + 52, ins.Top) + 6
		ui.Logo.Position = UDim2.fromOffset((W - ui.LogoW * logoScale) / 2, logoY)
		local w = math.min(W - 2 * M, 560)
		local x = (W - w) / 2
		-- bottom-up: mode selector, PLAY, tiles, hero pill
		local selH, playH = 60, 108
		local y = H - M - selH
		local selW = math.min(w, 420)
		place(ui.ModeSelect.Instance, (W - selW) / 2, y, selW, selH)
		y -= G + playH
		place(ui.PlayHolder, x, y, w, playH)
		local playTop = y
		y -= G + 6 + tilesH
		place(ui.Tiles, x, y, w, tilesH)
		y -= 18 + pillH
		local pillW = math.min(w, 400)
		place(ui.HeroPill, (W - pillW) / 2, y, pillW, pillH)
		-- the countdown / busy panel takes the pill, tiles, PLAY and selector area
		place(ui.Queue, x, y, w, H - M - y)
		place(ui.ReadyBtn.Instance, W - M - 132, playTop - G - 48 - tilesH - G - 6, 132, 48)
		local logoBottom = logoY + (ui.LogoH + 10) * logoScale
		heroFrac = ((logoBottom + y) / 2) / H
	else
		--[[ Proportions measured on the owner's reference (home-mockup, 16:9), as fractions of
		     the safe area: logo 28 % wide top left; dock 27.4 % x 13.3 %, bottom 6 % up;
		     hero selector 21.3 % x 6.6 % centred, PLAY 26.8 % x 15.5 % right with the
		     SOLO selector (70 % of PLAY's width, 6.4 % tall) under it, both ending 7.5 % up.
		     Phones keep finger-sized minimums. ]]
		local sideM = math.max(M, math.floor(W * 0.022))
		-- logo: ~28 % of the width, never taller than ~30 % of the height
		local logoScale = math.min(W * 0.28 / ui.LogoW, H * 0.3 / ui.LogoH)
		logoScale = math.clamp(logoScale, 0.5, 1.4)
		ui.LogoScale.Scale = logoScale
		local logoY = math.max(ins.Top + 2, math.floor(H * 0.03))
		ui.Logo.Position = UDim2.fromOffset(sideM, logoY)
		local baseB = math.max(M, math.floor(H * 0.06))
		local lowB = math.max(M, math.floor(H * 0.075))
		-- bottom left: the dock
		tilesH = math.floor(math.clamp(H * 0.133, 90, 108))
		tilesW = math.floor(math.clamp(W * 0.274, 3 * 92 + 16, 390))
		place(ui.Tiles, sideM, H - baseB - tilesH, tilesW, tilesH)
		-- bottom right: PLAY over the mode selector
		local pw = math.floor(math.clamp(W * 0.268, 250, 400))
		local playH = math.floor(math.clamp(H * 0.155, 80, 124))
		local selH = math.floor(math.clamp(H * 0.064, 46, 52))
		local selW = math.floor(pw * 0.7)
		local selGap = math.max(8, math.floor(H * 0.018))
		place(ui.ModeSelect.Instance, W - sideM - pw / 2 - selW / 2, H - lowB - selH, selW, selH)
		local playY = H - lowB - selH - selGap - playH
		place(ui.PlayHolder, W - sideM - pw, playY, pw, playH)
		place(ui.ReadyBtn.Instance, W - sideM - 132, playY - G - 48, 132, 48)
		local qTop = chipY + 64
		place(ui.Queue, W - sideM - pw, qTop, pw, H - M - qTop)
		-- the hero selector, compact and centred at the bottom (else in the gap between)
		pillH = math.floor(math.clamp(H * 0.066, 50, 56))
		local gapL, gapR = sideM + tilesW + 16, W - sideM - pw - 16
		local half = math.min(W / 2 - gapL, gapR - W / 2)
		local want = math.clamp(W * 0.213, 250, 320)
		if 2 * half >= 250 then
			local pillW = math.min(want, 2 * half)
			place(ui.HeroPill, W / 2 - pillW / 2, H - lowB - pillH, pillW, pillH)
		else
			local pillW = math.clamp(gapR - gapL, 230, want)
			place(ui.HeroPill, (gapL + gapR) / 2 - pillW / 2, H - lowB - pillH, pillW, pillH)
		end
		heroFrac = 0.5
	end
	-- PLAY lettering scales with the plate (reference: the word fills ~56 % of the width)
	if ui.PlayBtn.Title then
		local ph = ui.PlayHolder.Size.Y.Offset
		ui.PlayBtn.Title.TextSize = math.floor(math.clamp(ph * 0.6, 40, 70))
	end
	if ui.PlayCrown then
		ui.PlayCrown.Visible = ui.PlayHolder.Size.Y.Offset >= 80
	end
	-- tiles: three equal cells with separators
	local tw = ui.Tiles.Size.X.Offset
	local cell = math.floor((tw - 16) / 3)
	for i, b in ipairs({ ui.HeroesTile, ui.ShopTile, ui.MoreTile }) do
		place(b.Instance, 8 + (i - 1) * cell, 4, cell, tilesH - 8)
	end
	for i, sep in ipairs(ui.TileSeps) do
		place(sep, 8 + i * cell, 20, 1, tilesH - 40)
	end
	-- the pill: name centred, "LV n" and a small gold bar under it, round arrows at the ends
	local pw = ui.HeroPill.Size.X.Offset
	local ph = ui.HeroPill.Size.Y.Offset
	local arrow = math.min(44, ph - 8)
	for _, b in ipairs({ ui.PrevArrow, ui.NextArrow }) do
		b.Instance.Size = UDim2.fromOffset(arrow, arrow)
	end
	ui.PrevArrow.Instance.Position = UDim2.new(0, 4, 0.5, 0)
	ui.NextArrow.Instance.Position = UDim2.new(1, -4, 0.5, 0)
	local nameH = TS(16) + 2
	local levelH = TS(11) + 2
	local top = math.max(2, math.floor((ph - nameH - levelH - 2) / 2))
	ui.HeroName.Position = UDim2.new(0.5, 0, 0, top)
	ui.HeroName.Size = UDim2.new(1, -2 * (arrow + 10), 0, nameH)
	local levelW = 38
	local barW = math.clamp(pw - 2 * (arrow + 10) - levelW - 24, 50, 110)
	local rowX = -(barW + levelW) / 2
	local rowY = top + nameH + 2
	ui.HeroLevel.TextSize = TS(11)
	ui.HeroLevel.Position = UDim2.new(0.5, rowX, 0, rowY)
	ui.HeroLevel.Size = UDim2.fromOffset(levelW, levelH)
	ui.HeroBar.Frame.Position = UDim2.new(0.5, rowX + levelW, 0, rowY + math.floor((levelH - 5) / 2))
	ui.HeroBar.Frame.Size = UDim2.fromOffset(barW, 5)
	local openPad = arrow + 8
	local open = ui.HeroPill:FindFirstChild("Open", true) :: GuiObject?
	if open then
		open.Position = UDim2.fromOffset(openPad, 0)
		open.Size = UDim2.new(1, -2 * openPad, 1, 0)
	end

	-- the queue replaces PLAY (portrait: the whole bottom block)
	ui.PlayHolder.Visible = not showQueue
	ui.ModeSelect.Instance.Visible = not showQueue
	ui.Queue.Visible = showQueue
	ui.HeroPill.Visible = not (showQueue and portrait)
	ui.Tiles.Visible = not (showQueue and portrait)
	-- "run in progress" needs no player list: a compact panel
	if lastStatus == "Busy" then
		ui.Queue.Size = UDim2.fromOffset(ui.Queue.Size.X.Offset, math.min(ui.Queue.Size.Y.Offset, 96 + TS(16) * 3 + 20))
	end
	-- queue panel: a short panel folds the player list into the note
	local qh = ui.Queue.Size.Y.Offset
	local busy = lastStatus == "Busy"
	-- the full panel needs the player list, the curse / endless lines, the note and buttons
	local extraLines = (ui.QueueCurses:GetAttribute("Has") == true and 62 or 0) + (ui.QueueEndless:GetAttribute("Has") == true and 38 or 0)
	local short = qh < math.max(280, 72 + 4 * 30 + extraLines + TS(16) * 3 + 8 + 52 + 36) and not busy
	ui.QueueList.Visible = not short and not busy
	local noteY = (short or busy) and 68 or (72 + 4 * 30)
	-- the curse line sits under the note (above the buttons)
	ui.QueueCurses.Visible = ui.QueueCurses:GetAttribute("Has") == true
	if ui.QueueCurses.Visible then
		ui.QueueCurses.Position = UDim2.fromOffset(0, noteY)
		noteY += 62
	end
	ui.QueueEndless.Visible = ui.QueueEndless:GetAttribute("Has") == true
	if ui.QueueEndless.Visible then
		ui.QueueEndless.Position = UDim2.fromOffset(0, noteY)
		noteY += 38
	end
	ui.QueueNote.Position = UDim2.fromOffset(0, noteY)
	ui.QueueNote.Size = UDim2.new(1, 0, 0, short and (TS(16) + 6) or (TS(16) * 3 + 8))
	ui.QueueNote.TextTruncate = short and Enum.TextTruncate.AtEnd or Enum.TextTruncate.None
	-- where the hero should sit on screen (read by CameraController's menu shot)
	workspace.CurrentCamera:SetAttribute("MenuHeroY", heroFrac)
	workspace.CurrentCamera:SetAttribute("MenuHeroZoom", 1)
	for _, s in pairs(screens) do
		if s.Layout then
			s.Layout(v, portrait, ins)
		end
	end
end

------------------------------------------------------------------------------------------
-- Screens
------------------------------------------------------------------------------------------

-- Ambient life on the home screen: drifting motes and a light sweep over the logo every few
-- seconds. Only runs while Home is showing (stopped when another screen or the run opens).
local ambientStop: (() -> ())?
local ambientToken = 0
local function homeAmbient(on: boolean)
	ambientToken += 1
	if ambientStop then
		ambientStop()
		ambientStop = nil
	end
	if not on or not ui.Frame then
		return
	end
	local token = ambientToken
	ambientStop = UIAnim.Motes(ui.Home, 14, P.gold_300)
	ui.Logo.ClipsDescendants = true
	task.spawn(function()
		task.wait(0.7)
		while token == ambientToken and ui.Home.Visible and ui.Frame.Visible do
			UIAnim.Sweep(ui.Logo, 0, 0.6, 0.7)
			task.wait(6)
		end
	end)
end

-- staggered entrance: 0.03 s per item, the whole wave done within ~0.25 s (scale only:
-- relayout owns every Position)
local STAGGER = 0.03
local function homeEntrance()
	homeAmbient(true)
	UIAnim.Pop(ui.Logo, 0, 0.9)
	UIAnim.Pop(ui.Tiles, STAGGER * 2, 0.85)
	UIAnim.Pop(ui.HeroPill, STAGGER * 3, 0.85)
	UIAnim.Pop(ui.PlayBtn.Instance, STAGGER * 4, 0.8)
	UIAnim.Pop(ui.ModeSelect.Instance, STAGGER * 5, 0.85)
end

-- Slides to "Home" | "Play" | "More" | "Characters" | "Upgrades" | "Stats" | "Journal" |
-- "Curses" | "Daily" | "Ranks" | "Track" | "Arenas" | "Party" (old panel name "Shop" =
-- Upgrades). arg goes to the screen's OnShow (Ranks: the board, Stats: the tab).
-- The notice dot a screen clears when the player looks at it (NoticeDots).
local function markSeen(name: string, arg: any?)
	local id = ({ Characters = "Heroes", Upgrades = "Shop", More = "More", Daily = "Daily", Party = "Party", Track = "Track" } :: { [string]: string })[name]
	if name == "Stats" and arg == "Achievements" then
		id = "Achievements"
	end
	if id then
		NoticeDots.MarkSeen(id)
	end
end

function LobbyScreen.Show(name: string, arg: any?)
	if name == "Shop" then
		name = "Upgrades"
	end
	if not SCREEN_ORDER[name] or not ui.Frame then
		return
	end
	markSeen(name, arg)
	if name == current and ui[name].Visible then
		local s = screens[name]
		if s and s.OnShow and arg ~= nil then
			s.OnShow(profile, arg)
		end
		return
	end
	local direction = SCREEN_ORDER[name] >= SCREEN_ORDER[current] and 1 or -1
	UIAnim.SwapScreens(ui[current], ui[name], direction, math.min(0.2, Config.UI.ScreenSlideSeconds))
	local from = current
	current = name
	-- the screen being left stops its idle loops (OnHide)
	local left = screens[from]
	if left and left.OnHide then
		left.OnHide()
	end
	if from == "Home" then
		homeAmbient(false)
	end
	relayout()
	UIAnim.Tween(ui.Dim, Theme.Motion.Base, { BackgroundTransparency = (name ~= "Home" and name ~= "Characters") and 0.4 or 1 })
	if from == "Characters" or name == "Characters" then
		if name == "Characters" and screens.Characters.Inspect then
			screens.Characters.Inspect(selectedChar())
		else
			Showcase.Show(selectedChar(), skinOf(selectedChar()))
			LobbyScreen.RefreshHero()
		end
	end
	local s = screens[name]
	if s and s.OnShow then
		s.OnShow(profile, arg)
		Remotes.Get("RequestProfile"):FireServer()
	end
	if name == "Home" then
		homeEntrance()
		UIKit.FocusIfGamepad(ui.PlayBtn.Instance)
	end
end

function LobbyScreen.Current(): string
	return current
end

local maybeAskFirstRun: (p: { [string]: any }) -> ()

-- Shows / hides the whole lobby (UIBuilder: not in a run ⇔ visible).
function LobbyScreen.SetVisible(on: boolean)
	if not ui.Frame or ui.Frame.Visible == on then
		return
	end
	ui.Frame.Visible = on
	ui.Vignette.Visible = on
	if not on then
		homeAmbient(false)
		local s = screens[current]
		if s and s.OnHide then
			s.OnHide()
		end
		if firstRun == "Asked" then
			firstRun = "Done" -- the first run started: the lobby shows normally after it
		end
		ui.FirstRunCover.Visible = false
	end
	if on then
		-- always come back to the home screen
		for name in pairs(SCREEN_ORDER) do
			ui[name].Visible = false
		end
		current = "Home"
		ui.Dim.BackgroundTransparency = 1
		UIAnim.SwapScreens(nil, ui.Home, 1, Config.UI.ScreenSlideSeconds)
		-- scale-only entrance: relayout() owns the chip's Position
		UIAnim.Pop(ui.Chip, 0, 0.85)
		homeEntrance()
		lastStatus = ""
		LobbyScreen.RefreshHero()
		UIKit.FocusIfGamepad(ui.PlayBtn.Instance)
		if profile then
			maybeAskFirstRun(profile)
		end
	end
end

-- The hero pill and the hero on the dais: the selected character.
function LobbyScreen.RefreshHero()
	if not ui.HeroName then
		return
	end
	local id = selectedChar()
	local def = CharacterData.Characters[id] or CharacterData.Characters[CharacterData.Default]
	ui.HeroName.Text = string.upper(def.Name)
	-- Hero Mastery: the hero's level and the XP into it
	local heroes = profile and profile.Heroes
	local h = type(heroes) == "table" and heroes[def.Id or id] or nil
	local level, into, need = MetaUpgradeData.MasteryFor(type(h) == "table" and h.XP or 0)
	ui.HeroLevel.Text = "LV " .. level
	local maxed = level >= Config.HeroMastery.MaxLevel
	ui.HeroBar.Set(maxed and 1 or (need > 0 and math.clamp(into / need, 0, 1) or 0))
	if current ~= "Characters" then
		Showcase.Show(id, skinOf(id))
	end
end

function LobbyScreen.SetJoined(on: boolean)
	joinedCountdown = on
end

-- A brand-new player's first join: ask the server once for the automatic first run.
maybeAskFirstRun = function(p: { [string]: any })
	if firstRun ~= "" or not ui.Frame or not ui.Frame.Visible then
		return
	end
	local cfg = (Config :: any).FirstRun
	local state = Remotes.State()
	local runs = type(p.Stats) == "table" and tonumber(p.Stats.Runs) or 0
	if not cfg or cfg.AutoStart ~= true or p.TutorialDone ~= false or (runs or 0) > 0
		or player:GetAttribute("InRun") == true or player:GetAttribute("Travel") ~= nil
		or state:GetAttribute("RunServer") == true or (state:GetAttribute("Phase") or "Lobby") ~= "Lobby"
		or MenuParty.Summary().Count > 0 then
		firstRun = "Done"
		return
	end
	firstRun = "Asked"
	firstRunAt = os.clock()
	ui.FirstRunCover.Visible = true
	Remotes.Get("StartFirstRun"):FireServer()
end

function LobbyScreen.SetProfile(p: { [string]: any })
	profile = p
	if not ui.Frame then
		return
	end
	UIAnim.CountTo(ui.Gold.Value, shownGold or p.Gold, p.Gold, UIKit.formatNumber, 0.7)
	if shownGold and shownGold ~= p.Gold and ui.Frame.Visible then
		-- the coin icon pops when gold changes (a buy, a run's haul)
		for _, ch in ipairs(ui.Gold.Frame:GetChildren()) do
			if ch:IsA("GuiObject") and ch.LayoutOrder == 1 then
				UIAnim.Selected(ch, P.gold_300)
			end
		end
	end
	shownGold = p.Gold
	-- the worn dais ring (level track) under the hero
	Showcase.SetRing(type(p.Ring) == "string" and p.Ring or "")
	LobbyScreen.RefreshHero()
	for _, s in pairs(screens) do
		if s.Refresh then
			s.Refresh(p)
		end
	end
	NoticeDots.Refresh(p)
	if ui.Frame.Visible then
		markSeen(current) -- a change on the open screen is seen already
	end
	maybeAskFirstRun(p)
end

local function clearQueueList()
	for _, c in ipairs(ui.QueueList:GetChildren()) do
		if c:IsA("GuiObject") then
			c:Destroy()
		end
	end
end

-- "+45% gold · Frenzy, Horde" for the countdown's curse line.
local function curseLine(list: { string }): string
	local names = {}
	for _, id in ipairs(list) do
		table.insert(names, CurseData.Curses[id].Name)
	end
	return CurseData.GoldText(CurseData.GoldMult(list)) .. " gold · " .. table.concat(names, ", ")
end

--[[
	Per-frame updates (cheap: only strings and visibility). PLAY and its selector swap
	with the queue panel when a countdown or another run is going.
]]
function LobbyScreen.Update(_dt: number?)
	if not ui.Frame or not ui.Frame.Visible then
		return
	end
	updateLoadingPill()
	-- the first-run cover waits for the server's answer (or gives up)
	if firstRun == "Asked" then
		local answer = player:GetAttribute("FirstRun")
		if answer == "Lobby" or os.clock() - firstRunAt > ((Config :: any).FirstRun.CoverSeconds or 4) then
			firstRun = "Done"
			ui.FirstRunCover.Visible = false
		end
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
		ui.QueueCaption.Text = UIKit.track((state:GetAttribute("Endless") == true and "Endless · " or "") .. (stageNo > 0 and ("Stage " .. stageNo .. " · ") or "") .. "Time " .. UIKit.formatTime(state:GetAttribute("RunTime") or 0))
		ui.QueueNote.Text = "Wait here for the next one!"
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
		relayout()
		UIAnim.Pop(kind ~= "Modes" and ui.Queue or ui.PlayBtn.Instance, 0, 0.8)
	end

	-- PARTY: invites on the MORE tile, a member's READY pill, the party's mode
	local party = MenuParty.Summary()
	if party.Count ~= lastPartyCount then
		lastPartyCount = party.Count
		local partyMode = party.Count > 1 and MenuParty.PartyMode() or nil
		if partyMode then
			MenuPlay.SetMode(partyMode)
		end
	end
	local showReady = party.Count > 0 and not party.Leader and kind == "Modes"
	ui.ReadyBtn.Instance.Visible = showReady
	local readyText = party.MyReady and "UNREADY" or "READY"
	if showReady and ui.ReadyBtn.Instance:GetAttribute("Shown") ~= readyText then
		ui.ReadyBtn.Instance:SetAttribute("Shown", readyText)
		ui.ReadyBtn.SetText(readyText)
		ui.ReadyBtn.SetKind(party.MyReady and "Secondary" or "Primary")
		ui.ReadyBtn.SetIcon(not party.MyReady and "check" or nil)
	end
	local badge = party.Invites > 0 and tostring(party.Invites) or ""
	if ui.MoreBadge.Text ~= badge then
		NoticeDots.SetInvites(party.Invites)
		ui.MoreBadge.Text = badge
		ui.MoreBadge.Visible = badge ~= ""
		if badge ~= "" then
			UIAnim.Pop(ui.MoreBadge, 0, 0.4) -- a new invite: the badge pops in
		end
	end
	LobbyScreen._modeText()

	-- the countdown's curse / endless lines (the starter's pick)
	local endlessShown = kind == "Countdown" and state:GetAttribute("Endless") == true
	if ui.QueueEndless:GetAttribute("Has") ~= endlessShown then
		ui.QueueEndless:SetAttribute("Has", endlessShown)
		relayout()
	end
	local shown = CurseData.FromString(state:GetAttribute("Curses"))
	local has = kind ~= "Modes" and #shown > 0
	if ui.QueueCurses:GetAttribute("Has") ~= has then
		ui.QueueCurses:SetAttribute("Has", has)
		relayout()
	end
	if has then
		local line = string.format('<font color="%s">CURSES</font>  %s', UIKit.hex(P.crimson_300), curseLine(shown))
		if ui.QueueCurseText.Text ~= line then
			ui.QueueCurseText.Text = line
		end
	end
	for _, s in pairs(screens) do
		if s.Update then
			s.Update(_dt or 0)
		end
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
	buildLoadingPill()
	buildFirstRunCover(frame)
	local ctx = {
		Host = h,
		Back = function()
			LobbyScreen.Show(PARENT[current] or "Home")
		end,
		Toast = toast,
		Current = function(): string
			return current
		end,
		Profile = function(): { [string]: any }?
			return profile
		end,
		ShowScreen = function(name: string, arg: any?)
			LobbyScreen.Show(name, arg)
		end,
	}
	screens.Characters = MenuCharacters.Build(screen("Characters"), ctx)
	screens.Upgrades = MenuUpgrades.Build(screen("Upgrades"), ctx)
	screens.Play = MenuPlay.Build(screen("Play"), ctx)
	screens.More = MenuMore.Build(screen("More"), ctx)
	screens.Stats = MenuStats.Build(screen("Stats"), ctx)
	screens.Journal = MenuJournal.Build(screen("Journal"), ctx)
	screens.Curses = MenuCurses.Build(screen("Curses"), ctx)
	screens.Daily = MenuDaily.Build(screen("Daily"), ctx)
	screens.Ranks = MenuLeaderboards.Build(screen("Ranks"), ctx)
	screens.Track = MenuTrack.Build(screen("Track"), ctx)
	screens.Arenas = MenuArenas.Build(screen("Arenas"), ctx)
	screens.Party = MenuParty.Build(screen("Party"), ctx)
	h.OnRelayout(relayout)
	relayout()
end

return LobbyScreen
