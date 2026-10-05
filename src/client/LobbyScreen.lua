--[[
	LobbyScreen.lua
	The main menu, shown whenever the player is not in a run. The 3D castle courtyard at
	dusk is the backdrop and the selected hero stands on the glowing dais right of centre
	(Showcase.lua, drag to spin; CameraController frames it from MenuHeroX / MenuHeroY).
	The home screen follows the approved title screen (overhaul 01_Title.png):

	  top left      the SWARM logo and under it the hero caption "KNIGHT · GOLD TRIM" (the
	                selected hero and its equipped skin, from the profile; a tap opens
	                CHARACTERS)
	  left          the big gold PLAY plate and "Choose your mode next.": PLAY opens the
	                run-setup step (MenuPlay: Solo / Duo / Trio, world, difficulty, curses,
	                Endless, Daily, LAST RUN + RETRY, START). A party member gets a READY
	                toggle under PLAY. A countdown (who joined, the curses, an ENDLESS line,
	                JOIN, START NOW, the number) or "run in progress" replaces PLAY.
	  top right     the account pill (hero badge, account LV, gold; a tap opens ACCOUNT
	                LEVEL) and the PARTY button (party size, invite badge)
	  bottom        CHARACTERS / SHOP / WORLDS / DAILY
	  bottom right  MORE (Stats, Ranks, Account Level, Journal, Achievements, Party,
	                Settings, Report a bug, DEV) and the settings cog (UIBuilder's modal)
	Portrait stacks: pill + party, logo + caption, hero, PLAY + hint, the bottom row.
	Sub-screens keep the gold chip (top right; inline on CHARACTERS).

	A brand-new player (no run ever started, tutorial not done) asks the server once for
	the automatic first Solo run (remote StartFirstRun, Config.FirstRun); the server
	decides and answers with the player attribute FirstRun. Meanwhile a plain cover says
	the run is starting (at most Config.FirstRun.CoverSeconds).

	Sub-screens slide in: Characters (MenuCharacters), Upgrades (MenuUpgrades), Play
	(MenuPlay), More (MenuMore), Stats (MenuStats), Journal (MenuJournal), Curses
	(MenuCurses), Daily (MenuDaily), Ranks (MenuLeaderboards), Track (MenuTrack), Arenas
	(MenuArenas, "Worlds"), Party (MenuParty); Settings is UIBuilder's modal. BACK returns
	to the screen it was opened from (else PARENT, else home). Everything sent to the
	server is an id or a mode name; the server validates it (RunManager: StartRun /
	JoinRun / StartNow / CycleArena, GoldSystem: purchases and selection).
]]

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService = game:GetService("UserInputService")
local GuiService = game:GetService("GuiService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared:WaitForChild("Config"))
local Remotes = require(Shared:WaitForChild("Remotes"))
local Theme = require(Shared:WaitForChild("Theme"))
local CharacterData = require(Shared:WaitForChild("CharacterData"))
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
local UIState = require(script.Parent.UIState)

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
-- the screen each one was opened from this time (home's WORLDS / DAILY / PARTY / the
-- account pill go back home; the PLAY sheet's WORLD row goes back to the sheet)
local cameFrom: { [string]: string } = {}
local goingBack = false
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
		-- the picture's box ends at about 136
		ui.LogoW, ui.LogoH = 280, 136
		logo.Size = UDim2.fromOffset(280, 136)
	end
	return logo
end

-- The hero caption under the logo: a thin gold rule with a diamond, then the selected
-- hero and its equipped skin in letter-spaced serif caps ("K N I G H T  ·  G O L D  T R I M").
-- A tap opens CHARACTERS.
local function buildCaption(parent: Instance)
	local b = new("TextButton", { Name = "HeroCaption", Text = "", AutoButtonColor = false, BackgroundTransparency = 1, Size = UDim2.fromOffset(300, 44) }, parent)
	UIKit.Focusable(b)
	b.Activated:Connect(function()
		UIKit.Click()
		LobbyScreen.Show("Characters")
	end)
	local rule = new("Frame", { Name = "Rule", BackgroundTransparency = 1, AnchorPoint = Vector2.new(0.5, 0), Position = UDim2.new(0.5, 0, 0, 2), Size = UDim2.new(0.86, 0, 0, 8) }, b)
	for i, side in ipairs({ 0, 1 }) do
		local line = new("Frame", { Name = "Line" .. i, BorderSizePixel = 0, BackgroundColor3 = P.gold_400, AnchorPoint = Vector2.new(side, 0.5), Position = UDim2.fromScale(side, 0.5), Size = UDim2.new(0.5, -9, 0, 1) }, rule)
		new("UIGradient", { Transparency = NumberSequence.new(side == 0 and 0.85 or 0.1, side == 0 and 0.1 or 0.85) }, line)
	end
	new("Frame", { Name = "Diamond", BackgroundColor3 = P.gold_300, BorderSizePixel = 0, Rotation = 45, AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.5), Size = UDim2.fromOffset(7, 7) }, rule)
	ui.CaptionText = new("TextLabel", {
		Name = "Text",
		BackgroundTransparency = 1,
		Position = UDim2.fromOffset(0, 12),
		Size = UDim2.new(1, 0, 1, -12),
		Text = "K N I G H T",
		FontFace = Theme.Font.Title,
		TextSize = 18,
		TextColor3 = P.ivory_100,
		TextStrokeColor3 = C.Shadow,
		TextStrokeTransparency = 0.45,
		TextScaled = true,
	}, b)
	ui.CaptionFit = new("UITextSizeConstraint", { MaxTextSize = 20, MinTextSize = 9 }, ui.CaptionText)
	ui.Caption = b
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
	local pill = new("Frame", { Name = "LoadingPill", BackgroundColor3 = P.slate_900, BackgroundTransparency = 0.25, Size = UDim2.fromOffset(0, 30), AutomaticSize = Enum.AutomaticSize.X, Position = UDim2.new(1, 0, 0, 56), AnchorPoint = Vector2.new(1, 0), Visible = false, ZIndex = 5 }, ui.Frame)
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
		local at = ui.PillAnchor or { X = 0, Y = 56, AX = 0 }
		pill.AnchorPoint = Vector2.new(at.AX, 0)
		pill.Position = UDim2.fromOffset(at.X, at.Y)
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
		local at = ui.PillAnchor or { X = 0, Y = 56, AX = 0 }
		pill.AnchorPoint = Vector2.new(at.AX, 0)
		pill.Position = UDim2.fromOffset(at.X, at.Y)
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
-- Home: account pill + PARTY (top right), the bottom row, MORE
------------------------------------------------------------------------------------------

-- A dark plate with a thin gold edge (the reference's pills and the cog's square).
local function plate(face: GuiObject)
	face.BackgroundColor3 = NAVY
	face.BackgroundTransparency = 0.12
	local st = face:FindFirstChildOfClass("UIStroke")
	if st then
		st.Color = P.gold_400
		st.Transparency = 0.2
		st.Thickness = 1.5
	end
end

-- Account pill: the selected hero's badge, "LV n" (account level, MenuTrack), a gold rule,
-- the coin and the gold. A tap opens ACCOUNT LEVEL (the track and its cosmetic rewards).
local function buildAccount(screen: Frame)
	local b = new("TextButton", { Name = "AccountPill", Text = "Account level", TextTransparency = 1, AutoButtonColor = false, BackgroundColor3 = NAVY, BackgroundTransparency = 0.12, BorderSizePixel = 0 }, screen)
	UIKit.corner(b, 10)
	UIKit.stroke(b, P.gold_400, 1.5, 0.2)
	UIKit.Focusable(b)
	UIAnim.Button(b)
	b.Activated:Connect(function()
		UIKit.Click()
		LobbyScreen.Show("Track")
	end)
	ui.AccountHero = new("Frame", { Name = "Hero", BackgroundTransparency = 1, Size = UDim2.fromOffset(44, 44) }, b)
	ui.AccountLevel = text(b, "Label", "LV 1", { Name = "AccountLevel", FontFace = Theme.Font.Title, TextColor3 = P.ivory_100, TextXAlignment = Enum.TextXAlignment.Center }, 18)
	ui.AccountRule = new("Frame", { Name = "Rule", BackgroundColor3 = P.gold_400, BackgroundTransparency = 0.35, BorderSizePixel = 0 }, b)
	ui.AccountCoin = Icons.Draw(b, "lobby_Gold", { Size = 30, Back = NAVY })
	ui.AccountGold = text(b, "Number", "0", { Name = "AccountGold", FontFace = Theme.Font.Title, TextColor3 = P.ivory_100 }, 20)
	ui.AccountBtn = b
	NoticeDots.Attach("Track", b, { Position = UDim2.new(1, -8, 0, 8) })

	ui.PartyBtn = UIKit.Button(screen, { Kind = "Secondary", Name = "PartyButton", Title = "Party", TitleStyle = "Label", TitleSize = 17, Icon = "lobby_Party", IconSize = 26, Align = "Center", Shrink = true, Radius = 10, OnClick = function()
		LobbyScreen.Show("Party")
	end })
	plate(ui.PartyBtn.Face)
	if ui.PartyBtn.Title then
		ui.PartyBtn.Title.FontFace = Theme.Font.Title
		ui.PartyBtn.Title.TextColor3 = P.ivory_100
	end
	ui.PartyBadge = UIKit.Badge(ui.PartyBtn.Instance, "", "Crimson", { Name = "InviteBadge", AnchorPoint = Vector2.new(1, 0), Position = UDim2.new(1, 6, 0, -6), ZIndex = 6, Visible = false })
	NoticeDots.Attach("Party", ui.PartyBtn.Instance, { Position = UDim2.new(1, -8, 0, 8) })
end

-- Bottom row: CHARACTERS / SHOP / WORLDS / DAILY (gold icon over a serif caption, thin gold
-- separators, a soft dark band behind so they read over the courtyard).
local NAV = {
	{ Name = "Characters", Icon = "helmet", Art = "ui/home/home_Heroes", Screen = "Characters", Dot = "Heroes" },
	{ Name = "Shop", Icon = "chest", Art = "ui/home/home_Shop", Screen = "Upgrades", Dot = "Shop" },
	{ Name = "Worlds", Icon = "castle", Art = "icons/ui/ui_Arenas", Screen = "Arenas" },
	{ Name = "Daily", Icon = "calendar", Art = "icons/ui/ui_Daily", Screen = "Daily", Dot = "Daily" },
}

local function buildNav(screen: Frame)
	local row = new("Frame", { Name = "Nav", BackgroundTransparency = 1 }, screen)
	ui.Nav = row
	local shade = new("Frame", { Name = "Shade", BackgroundColor3 = C.Backdrop, BackgroundTransparency = 0.35, BorderSizePixel = 0, AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.55), Size = UDim2.new(1, 80, 1, 24), ZIndex = 0, Active = false }, row)
	new("UIGradient", { Transparency = NumberSequence.new({ NumberSequenceKeypoint.new(0, 1), NumberSequenceKeypoint.new(0.2, 0.15), NumberSequenceKeypoint.new(0.8, 0.15), NumberSequenceKeypoint.new(1, 1) }) }, shade)
	ui.NavItems = {}
	ui.NavSeps = {}
	for i, item in ipairs(NAV) do
		local b = UIKit.IconButton(row, { Icon = item.Icon, Caption = item.Name, Kind = "Ghost", Size = 96, IconSize = 40, Name = item.Name, LayoutOrder = i, OnClick = function()
			LobbyScreen.Show(item.Screen)
		end })
		local cap = b.Content:FindFirstChild("Caption") :: TextLabel?
		if cap then
			cap.Text = item.Name -- the reference's title case
			cap.TextColor3 = P.ivory_100
			cap.FontFace = Theme.Font.Title
			cap.TextStrokeColor3 = C.Shadow
			cap.TextStrokeTransparency = 0.4
			cap.TextScaled = true
			new("UITextSizeConstraint", { MaxTextSize = TS(17), MinTextSize = 9 }, cap)
		end
		ArtImage.ButtonIcon(b.Content, item.Art, { Size = UDim2.fromOffset(46, 46), AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.new(0.5, 0, 0.5, -TS(Theme.TextSize.Caption) / 2 - 4) }, "Glyph")
		if item.Dot then
			NoticeDots.Attach(item.Dot, b.Instance, { Position = UDim2.new(1, -12, 0, 10) })
		end
		ui.NavItems[i] = b
		if i > 1 then
			ui.NavSeps[i - 1] = new("Frame", { Name = "Sep" .. (i - 1), BackgroundColor3 = P.gold_400, BackgroundTransparency = 0.5, BorderSizePixel = 0 }, row)
		end
	end
	-- MORE: three gold dots on a small dark plate beside the cog
	ui.MoreBtn = UIKit.IconButton(screen, { Icon = "plus", Size = 48, IconSize = 26, Name = "More", OnClick = function()
		LobbyScreen.Show("More")
	end })
	plate(ui.MoreBtn.Face)
	local glyph = ui.MoreBtn.Content:FindFirstChild("Glyph")
	if glyph then
		glyph:Destroy()
	end
	local dots = new("Frame", { Name = "Dots", BackgroundTransparency = 1, AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.5), Size = UDim2.fromOffset(28, 8) }, ui.MoreBtn.Content)
	for k = 0, 2 do
		local d = new("Frame", { BackgroundColor3 = P.gold_400, BorderSizePixel = 0, Position = UDim2.fromOffset(k * 10, 0), Size = UDim2.fromOffset(8, 8) }, dots)
		UIKit.corner(d, 999)
	end
	NoticeDots.Attach("More", ui.MoreBtn.Instance, { Position = UDim2.new(1, -6, 0, 6) })
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
	-- the painted plate has chamfered corners and its own rim: while it shows, the kit's
	-- rounded face, edge line and top bevel would peek out at the corners, so they go clear
	-- (the kit repaints the face on hover / press, hence the property watch)
	table.insert(drawn, fill)
	local faceStroke = face:FindFirstChildOfClass("UIStroke")
	local kitBevel = face:FindFirstChild("Bevel")
	local artOn = false
	local pad = b.Content:FindFirstChildOfClass("UIPadding")
	local padL = pad and pad.PaddingLeft or UDim.new()
	local padR = pad and pad.PaddingRight or UDim.new()
	face:GetPropertyChangedSignal("BackgroundTransparency"):Connect(function()
		if artOn and face.BackgroundTransparency ~= 1 then
			face.BackgroundTransparency = 1
		end
	end)
	ArtImage.Place(face, "ui/home/home_PlayButton", { Name = "PlayArt", ScaleType = Enum.ScaleType.Stretch, Size = UDim2.fromScale(1, 1), ZIndex = 2 }, function(show: boolean)
		artOn = not show
		for _, g in ipairs(drawn) do
			if g.Parent then
				g.Visible = show
			end
		end
		if faceStroke then
			faceStroke.Enabled = show
		end
		if kitBevel and kitBevel:IsA("GuiObject") then
			kitBevel.Visible = show
		end
		face.BackgroundTransparency = show and 0 or 1
		-- keep the arrow (scaled 1.6x, it grows rightwards) inside the painted rim and bevel
		if pad then
			pad.PaddingLeft = show and padL or UDim.new(0.07, 0)
			pad.PaddingRight = show and padR or UDim.new(0.07, 14)
		end
	end)
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
		-- the run-setup step (mode, world, rules) comes next; START there starts the run
		OnClick = function()
			LobbyScreen.Show("Play")
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
	-- under PLAY: "Choose your mode next." (or what is picked / the party's rule)
	ui.PlayHint = text(screen, "Body", "Choose your mode next.", {
		Name = "PlayHint",
		FontFace = Theme.Font.Title,
		TextColor3 = P.ivory_100,
		TextStrokeColor3 = C.Shadow,
		TextStrokeTransparency = 0.4,
		TextXAlignment = Enum.TextXAlignment.Center,
		TextScaled = true,
	}, 20)
	ui.PlayHintFit = new("UITextSizeConstraint", { MaxTextSize = 22, MinTextSize = 10 }, ui.PlayHint)
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

-- The line under PLAY: "Choose your mode next." while nothing is picked beyond SOLO, else
-- what PLAY will start with ("DUO · ENDLESS · change it next"); a party says who starts.
function LobbyScreen._modeText()
	if not ui.PlayHint then
		return
	end
	local party = MenuParty.Summary()
	local line
	if party.Count > 0 and not party.Leader then
		line = "Your party leader picks the mode and starts."
	else
		local summary = MenuPlay.Summary()
		local plain = string.upper(((Config.Modes :: any)[Config.Modes.Order[1]] or {}).DisplayName or "SOLO")
		if summary == plain and party.Count == 0 then
			line = "Choose your mode next."
		else
			line = summary .. " · change it next"
		end
	end
	if ui.PlayHint.Text ~= line then
		ui.PlayHint.Text = line
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
	buildCaption(screen)
	buildAccount(screen)
	buildNav(screen)
	buildPlay(screen)
	buildQueue(screen)
end

------------------------------------------------------------------------------------------
-- Layout
------------------------------------------------------------------------------------------

-- The account pill's inside (badge, LV, rule, coin, gold) for a pill h tall; returns its width.
local function layoutAccount(h: number): number
	local heroS = h - 8
	local x = 6
	place(ui.AccountHero, x, 4, heroS, heroS)
	x += heroS + 8
	local lvSize = math.floor(math.clamp(h * 0.34, 14, 19))
	ui.AccountLevel.TextSize = TS(lvSize)
	local lvW = math.floor(TS(lvSize) * 0.66 * #ui.AccountLevel.Text + 4)
	place(ui.AccountLevel, x, 0, lvW, h)
	x += lvW + 12
	place(ui.AccountRule, x, h * 0.22, 1, h * 0.56)
	x += 13
	ui.AccountCoin.Position = UDim2.fromOffset(x, math.floor((h - 30) / 2))
	x += 30 + 8
	local goldSize = math.floor(math.clamp(h * 0.38, 15, 21))
	ui.AccountGold.TextSize = TS(goldSize)
	local goldStr = UIKit.formatNumber(profile and profile.Gold or 0)
	local gw = math.floor(TS(goldSize) * 0.64 * math.max(4, #goldStr) + 4)
	place(ui.AccountGold, x, 0, gw, h)
	return x + gw + 14
end

-- The bottom row: four items itemW wide, their captions and icons sized to the row.
local function layoutNav(x: number, y: number, itemW: number, navH: number)
	place(ui.Nav, x, y, itemW * #ui.NavItems, navH)
	local capH = math.floor(math.clamp(navH * 0.26, 14, 24))
	for i, b in ipairs(ui.NavItems) do
		place(b.Instance, (i - 1) * itemW, 0, itemW, navH)
		local cap = b.Content:FindFirstChild("Caption") :: TextLabel?
		if cap then
			cap.Size = UDim2.new(1, -4, 0, capH)
			cap.Position = UDim2.new(0.5, 0, 1, -math.floor(navH * 0.06))
		end
		local iconS = math.floor(math.clamp(navH - capH - 8, 30, 60))
		for _, ch in ipairs(b.Content:GetChildren()) do
			if ch:IsA("GuiObject") and (ch.Name == "Glyph" or ch.Name == "Art") then
				ch.Position = UDim2.new(0.5, 0, 0.5, -math.floor(capH / 2) - 2)
				if ch.Name == "Art" then
					ch.Size = UDim2.fromOffset(iconS, iconS)
				end
			end
		end
	end
	for i, sep in ipairs(ui.NavSeps) do
		place(sep, i * itemW, navH * 0.22, 1, navH * 0.56)
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
	local home = current == "Home"
	local showQueue = lastStatus == "Countdown" or lastStatus == "Busy"
	local showReady = ui.ReadyBtn.Instance.Visible

	-- sub-screens: the gold chip (phones in landscape put it in the Roblox top-bar row,
	-- right of the Roblox buttons, above the screen's header); home has the account pill
	setChipFlat(not portrait and current == "Characters")
	local topRowChip = compact and not portrait and not home and ins.Top >= 48
	ui.Chip.Visible = not home and (topRowChip or not (compact and not portrait and current ~= "Characters"))
	ui.Cog.Instance.Visible = home
	local chipY = ins.Right > 4 and (ins.Top + 6) or 12
	if portrait then
		chipY = ins.Top >= 48 and math.max(4, math.floor((ins.Top - 52) / 2)) or 12
	elseif current == "Characters" or topRowChip then
		chipY = math.max(0, math.floor((ins.Top - 48) / 2))
	end
	ui.Chip.AnchorPoint = Vector2.new(1, 0)
	if portrait and not home then
		-- portrait sub-screens: under their header, centred
		ui.Chip.AnchorPoint = Vector2.new(0.5, 0)
		ui.Chip.Position = UDim2.fromOffset(W / 2, math.max(ins.Top + 4, 12) + 64)
		ui.PillAnchor = { X = W / 2, Y = math.max(ins.Top + 4, 12) + 64 + 56, AX = 0.5 }
	else
		ui.Chip.Position = UDim2.fromOffset(W - M, chipY)
		ui.PillAnchor = { X = W - M, Y = chipY + 56, AX = 1 }
	end

	local heroFrac, heroX = 0.47, 0.6
	local rightM = portrait and M or math.max(M, math.floor(W * 0.022))
	local topY = chipY
	if not portrait and ins.Right <= 4 then
		topY = math.max(topY, math.floor(H * 0.025))
	end
	local pillH = math.floor(math.clamp(H * 0.062, 44, 58))
	if portrait then
		pillH = 46
	end
	-- top right: the account pill and PARTY
	local partyW = math.floor(math.clamp(W * 0.085, 116, 150))
	if portrait then
		partyW = 112
	end
	local accW = layoutAccount(pillH)
	place(ui.PartyBtn.Instance, W - rightM - partyW, topY, partyW, pillH)
	place(ui.AccountBtn, W - rightM - partyW - G - accW, topY, accW, pillH)
	if home then
		ui.PillAnchor = { X = W - rightM, Y = topY + pillH + 8, AX = 1 }
	end
	local cogS = 48
	local logoScale, logoX, logoY, capW, capH
	local playW, playH, hintH, playY, playX
	local navX, navY, itemW, navH
	if portrait then
		local w = math.min(W - 2 * M, 560)
		local x = (W - w) / 2
		logoScale = math.clamp((w - 20) / ui.LogoW, 0.55, 1.05)
		logoY = math.max(topY + pillH + 10, ins.Top + 4)
		logoX = (W - ui.LogoW * logoScale) / 2
		capW = math.min(w, 360)
		capH = 34
		-- bottom row: four items, then MORE and the cog
		navH = 82
		navY = H - M - navH
		local side = 2 * (cogS + G)
		itemW = math.floor((w - side) / 4)
		navX = x
		place(ui.Cog.Instance, x + w - cogS, navY + (navH - cogS) / 2, cogS, cogS)
		place(ui.MoreBtn.Instance, x + w - 2 * cogS - G, navY + (navH - cogS) / 2, cogS, cogS)
		-- PLAY (keeps the plate's ~3.25 : 1) with its line under it, over the bottom row
		playW = math.min(w, 440)
		playH = math.floor(math.clamp(playW / 3.25, 80, 136))
		playW = math.min(playW, math.floor(playH * 3.25))
		hintH = 26
		local blockH = playH + 6 + hintH + (showReady and (G + 48) or 0)
		playY = navY - G - blockH
		playX = (W - playW) / 2
	else
		local sideM = math.max(M, math.floor(W * 0.045))
		logoScale = math.clamp(math.min(W * 0.31 / ui.LogoW, H * 0.27 / ui.LogoH), 0.5, 1.7)
		logoY = math.max(ins.Top + 2, math.floor(H * 0.035))
		logoX = sideM
		capW = ui.LogoW * logoScale * 0.92
		capH = math.floor(math.clamp(H * 0.05, 28, 50))
		-- bottom: the row of four centred under the hero, MORE and the cog bottom right
		local bottomM = math.max(M, math.floor(H * 0.03))
		navH = math.floor(math.clamp(H * 0.11, 70, 100))
		navY = H - bottomM - navH
		itemW = math.floor(math.clamp(W * 0.085, 76, 150))
		local cogY = H - bottomM - cogS
		place(ui.Cog.Instance, W - rightM - cogS, cogY, cogS, cogS)
		local moreX = W - rightM - 2 * cogS - G
		place(ui.MoreBtn.Instance, moreX, cogY, cogS, cogS)
		-- (narrow windows: the items shrink so the row still ends before MORE)
		itemW = math.max(40, math.min(itemW, math.floor((moreX - G - sideM) / 4)))
		navX = math.clamp(math.floor(W * 0.49 - 2 * itemW), sideM, math.max(sideM, moreX - G - 4 * itemW))
		-- left: PLAY and its line, between the caption and the bottom row
		playW = math.floor(math.clamp(W * 0.31, 230, 560))
		playH = math.floor(math.clamp(playW / 3.25, 66, 172))
		hintH = math.floor(math.clamp(H * 0.034, 20, 30))
		local capBottom = logoY + ui.LogoH * logoScale + 2 + capH
		local extra = 6 + hintH + (showReady and (G + 48) or 0)
		local room = navY - G - (capBottom + G)
		if playH + extra > room then
			playH = math.max(56, room - extra)
			playW = math.min(playW, math.floor(playH * 3.6))
		end
		playY = math.max(capBottom + G, math.min(math.floor(H * 0.52), navY - G - playH - extra))
		playX = sideM
		heroFrac = math.clamp((navY - 6) / H - 0.36, 0.38, 0.48)
	end
	ui.LogoScale.Scale = logoScale
	ui.Logo.Position = UDim2.fromOffset(math.floor(logoX), math.floor(logoY))
	local logoW = ui.LogoW * logoScale
	local logoBottom = logoY + ui.LogoH * logoScale
	place(ui.Caption, logoX + (logoW - capW) / 2, logoBottom + 2, capW, capH)
	ui.CaptionFit.MaxTextSize = math.max(10, math.floor((capH - 12) * 0.95))
	layoutNav(navX, navY, itemW, navH)
	place(ui.PlayHolder, playX, playY, playW, playH)
	place(ui.PlayHint, playX - 20, playY + playH + 6, playW + 40, hintH)
	ui.PlayHintFit.MaxTextSize = math.max(10, hintH - 4)
	local readyW = math.min(playW, 220)
	place(ui.ReadyBtn.Instance, playX + (playW - readyW) / 2, playY + playH + 6 + hintH + G, readyW, 48)
	local capBottom = logoBottom + 2 + capH
	if portrait then
		place(ui.Queue, (W - math.min(W - 2 * M, 560)) / 2, capBottom + math.floor((playY - capBottom) * 0.3), math.min(W - 2 * M, 560), navY - G - (capBottom + math.floor((playY - capBottom) * 0.3)))
		heroFrac = ((capBottom + playY) / 2) / H
		heroX = 0.5
	else
		local qw = math.max(playW, math.min(W * 0.36, 440))
		place(ui.Queue, playX, capBottom + G, qw, navY - G - (capBottom + G))
	end
	-- PLAY lettering scales with the plate (reference: the word fills ~56 % of the width)
	if ui.PlayBtn.Title then
		ui.PlayBtn.Title.TextSize = math.floor(math.clamp(playH * 0.6, 34, 92))
	end
	if ui.PlayCrown then
		ui.PlayCrown.Visible = playH >= 80
	end

	-- the queue replaces PLAY and its line (portrait: the hero's gap too)
	ui.PlayHolder.Visible = not showQueue
	ui.PlayHint.Visible = not showQueue
	ui.Queue.Visible = showQueue
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
	-- where the hero should sit on screen (read by CameraController's menu shot);
	-- CHARACTERS sets its own framing
	if current ~= "Characters" then
		local cam = workspace.CurrentCamera
		cam:SetAttribute("MenuHeroY", heroFrac)
		cam:SetAttribute("MenuHeroX", heroX)
		cam:SetAttribute("MenuHeroZoom", 1)
	end
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
	UIAnim.Pop(ui.Caption, STAGGER, 0.9)
	UIAnim.Pop(ui.AccountBtn, STAGGER * 2, 0.85)
	UIAnim.Pop(ui.PartyBtn.Instance, STAGGER * 2, 0.85)
	UIAnim.Pop(ui.PlayBtn.Instance, STAGGER * 3, 0.8)
	UIAnim.Pop(ui.Nav, STAGGER * 4, 0.85)
	UIAnim.Pop(ui.MoreBtn.Instance, STAGGER * 5, 0.85)
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
	if not goingBack and name ~= "Home" then
		cameFrom[name] = from
	end
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
	-- a gamepad keeps its selection on the new screen (the button it was on is now hidden);
	-- a screen's OnShow may move it to a better first control
	if name ~= "Home" then
		local last = UserInputService:GetLastInputType()
		if last == Enum.UserInputType.Gamepad1 or last == Enum.UserInputType.Gamepad2 then
			pcall(function()
				GuiService:Select(ui[name])
			end)
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
		table.clear(cameFrom)
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

-- "K N I G H T  ·  G O L D  T R I M": the caption's letter-spaced words.
local function spacedCaps(str: string): string
	local words = {}
	for w in string.gmatch(string.upper(str), "%S+") do
		table.insert(words, (string.sub((string.gsub(w, "(.)", "%1 ")), 1, -2)))
	end
	return table.concat(words, "   ")
end

-- The caption, the account pill's badge and the hero on the dais: the selected hero and
-- its equipped skin (Default reads as the hero's name only).
local captionHero = ""
function LobbyScreen.RefreshHero()
	if not ui.CaptionText then
		return
	end
	local id = selectedChar()
	local def = CharacterData.Characters[id] or CharacterData.Characters[CharacterData.Default]
	local skinId = skinOf(def.Id or id)
	local skin = skinId ~= "Default" and CharacterData.Skins[skinId] or nil
	local line = spacedCaps(def.Name) .. (skin and ("   ·   " .. spacedCaps(skin.Name)) or "")
	if ui.CaptionText.Text ~= line then
		ui.CaptionText.Text = line
	end
	ui.Caption:SetAttribute("Hero", def.Id or id)
	ui.Caption:SetAttribute("Skin", skinId)
	if captionHero ~= (def.Id or id) then
		captionHero = def.Id or id
		for _, c in ipairs(ui.AccountHero:GetChildren()) do
			c:Destroy()
		end
		Icons.Character(ui.AccountHero, captionHero, { Size = 40, AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.5) })
	end
	if current ~= "Characters" then
		Showcase.Show(id, skinId)
	end
end

-- The account pill's level and gold (account level: MenuTrack / AccountData).
local function refreshAccount(p: { [string]: any }): boolean
	local level = MenuTrack.Account(p)
	local lv = "LV " .. tostring(level)
	local width = ui.AccountLevel.Text ~= lv or #UIKit.formatNumber(p.Gold or 0) ~= #UIKit.formatNumber(shownGold or 0)
	ui.AccountLevel.Text = lv
	UIAnim.CountTo(ui.AccountGold, shownGold or p.Gold, p.Gold, UIKit.formatNumber, 0.7)
	return width
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
	local resize = refreshAccount(p)
	if shownGold and shownGold ~= p.Gold and ui.Frame.Visible then
		-- the coin icon pops when gold changes (a buy, a run's haul)
		for _, ch in ipairs(ui.Gold.Frame:GetChildren()) do
			if ch:IsA("GuiObject") and ch.LayoutOrder == 1 then
				UIAnim.Selected(ch, P.gold_300)
			end
		end
	end
	shownGold = p.Gold
	if resize then
		relayout()
	end
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

	-- PARTY: the button's size and invite badge, a member's READY toggle, the party's mode
	local party = MenuParty.Summary()
	if party.Count ~= lastPartyCount then
		lastPartyCount = party.Count
		local partyMode = party.Count > 1 and MenuParty.PartyMode() or nil
		if partyMode then
			MenuPlay.SetMode(partyMode)
		end
		ui.PartyBtn.SetText(party.Count > 0 and string.format("Party %d/%d", party.Count, party.Max) or "Party")
		ui.PartyBtn.SetSelected(party.Count > 0)
	end
	local showReady = party.Count > 0 and not party.Leader and kind == "Modes"
	if ui.ReadyBtn.Instance.Visible ~= showReady then
		ui.ReadyBtn.Instance.Visible = showReady
		relayout()
	end
	local readyText = party.MyReady and "UNREADY" or "READY"
	if showReady and ui.ReadyBtn.Instance:GetAttribute("Shown") ~= readyText then
		ui.ReadyBtn.Instance:SetAttribute("Shown", readyText)
		ui.ReadyBtn.SetText(readyText)
		ui.ReadyBtn.SetKind(party.MyReady and "Secondary" or "Primary")
		ui.ReadyBtn.SetIcon(not party.MyReady and "check" or nil)
	end
	local badge = party.Invites > 0 and tostring(party.Invites) or ""
	if ui.PartyBadge.Text ~= badge then
		NoticeDots.SetInvites(party.Invites)
		ui.PartyBadge.Text = badge
		ui.PartyBadge.Visible = badge ~= ""
		if badge ~= "" then
			UIAnim.Pop(ui.PartyBadge, 0, 0.4) -- a new invite: the badge pops in
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
			local to = cameFrom[current] or PARENT[current] or "Home"
			if to == current or not SCREEN_ORDER[to] then
				to = "Home"
			end
			goingBack = true
			LobbyScreen.Show(to)
			goingBack = false
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
	-- gamepad B on a lobby screen = its BACK button. Not while a panel (settings, bug
	-- report ...) owns input, nor on the same press that just closed one (its own B
	-- handler may run first), nor while typing.
	local ownerFreedAt = -math.huge
	UIState.OnOwnerChanged(function(owner: string?)
		if owner == nil then
			ownerFreedAt = os.clock()
		end
	end)
	UserInputService.InputBegan:Connect(function(input)
		if input.KeyCode ~= Enum.KeyCode.ButtonB or not ui.Frame.Visible or current == "Home" then
			return
		end
		if UIState.Owner() ~= nil or os.clock() - ownerFreedAt < 0.1 or UserInputService:GetFocusedTextBox() then
			return
		end
		ctx.Back()
	end)
	h.OnRelayout(relayout)
	relayout()
end

return LobbyScreen
