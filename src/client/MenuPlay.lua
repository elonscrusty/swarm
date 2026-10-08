--[[
	MenuPlay.lua
	The run-setup step (the home screen's PLAY opens it). One centred panel (owner picture,
	2026-10-08):

	  header      BACK + "Play"
	  mode tabs   SOLO / DUO / TRIO (the picked one gold), one muted line under them saying
	              what the picked size means and who starts
	  grid        two columns (one on narrow screens; it scrolls when it does not fit) of rows,
	              each with a small caption, the value, an optional muted line and a chevron:
	    HERO        the selected hero and equipped skin (opens CHARACTERS)
	    WORLD       the lobby's arena and the next one still locked (opens ARENAS)
	    DIFFICULTY  cycles through the unlocked tiers; locked tiers name what clears them
	    CURSES      the run modifiers picked and their gold (opens CURSES, MenuCurses)
	    SIGILS      the worn sigils (opens SIGILS; only while the Sigils feature is on)
	    ENDLESS     switch (remote SetEndless; the server's answer is the player attribute
	                "Endless", Config.Endless): no portal win, its own leaderboard
	  LAST RUN    the saved last run with RETRY (MenuLastRun), when there is one
	  footer      "Details" (shows the DAILY CHALLENGE and WEEKLY CHALLENGE rows under the grid)
	              and the gold START (remote StartRun, the same validated start the server always
	              used: RunManager.startRun) with a one-line note of what it does. A party
	              member's START is their READY toggle instead (the leader starts).

	The picked mode lives here (MenuPlay.Mode) so the home screen's line under PLAY shows
	the same thing. It defaults to SOLO; joining a party picks the party's size.

	New accounts (owner brief item 9; MenuPlay.IsSimple: fewer than SIMPLE_RUNS (3)
	saved runs, profile.Stats.Runs, and not in a party) get a simpler setup:
	  a summary card   HERO (opens CHARACTERS) and WORLD (opens ARENAS)
	  START SOLO       one big primary action ("QuickStart"; same start as START)
	  ADVANCED OPTIONS collapsed by default; opens mode (SOLO / DUO / TRIO), the rule line,
	                   difficulty, curses, endless, daily, sigils, weekly and LAST RUN (the
	                   same controls as the full screen, moved into one scroll column)
	Anyone in a party (leader or member) always gets the full screen with READY.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared:WaitForChild("Config"))
local Remotes = require(Shared:WaitForChild("Remotes"))
local Theme = require(Shared:WaitForChild("Theme"))
local CurseData = require(Shared:WaitForChild("CurseData"))
local DifficultyData = require(Shared:WaitForChild("DifficultyData"))
local UIKit = require(script.Parent.UIKit)
local UIAnim = require(script.Parent.UIAnim)
local ArtImage = require(script.Parent.ArtImage)
local MenuCurses = require(script.Parent.MenuCurses)
local MenuParty = require(script.Parent.MenuParty)
local MenuLastRun = require(script.Parent.MenuLastRun)
local MenuDaily = require(script.Parent.MenuDaily)
local CharacterData = require(Shared:WaitForChild("CharacterData"))
local MenuSigils = require(script.Parent.MenuSigils)
local MenuWeekly = require(script.Parent.MenuWeekly)

local MenuPlay = {}

local player = Players.LocalPlayer
local C, P = Theme.Color, Theme.Palette

local MODES = {
	Solo = { Sub = "Just you", Icon = "person" },
	Duo = { Sub = "2 players + revives", Icon = "people2" },
	Trio = { Sub = "3 players + revives", Icon = "people3" },
}

local mode = Config.Modes.Order[1] or "Solo"
local listeners: { () -> () } = {}
local SIMPLE_RUNS = 3 -- saved runs before the full run setup shows by default
local advancedOpen = false -- the simple setup's ADVANCED OPTIONS (kept for the session)

local function place(obj: GuiObject, x: number, y: number, w: number, h: number)
	obj.Position = UDim2.fromOffset(math.floor(x + 0.5), math.floor(y + 0.5))
	obj.Size = UDim2.fromOffset(math.floor(w + 0.5), math.floor(h + 0.5))
end

function MenuPlay.Mode(): string
	return mode
end

function MenuPlay.SetMode(id: string)
	if id == mode or not table.find(Config.Modes.Order, id) then
		return
	end
	mode = id
	for _, fn in ipairs(listeners) do
		fn()
	end
end

-- True when this profile gets the simple run setup: a new account (fewer than SIMPLE_RUNS
-- runs saved) that is not in a party (party play keeps the full screen with READY).
function MenuPlay.IsSimple(profile: { [string]: any }?): boolean
	local stats = profile and profile.Stats
	local runs = type(stats) == "table" and tonumber(stats.Runs) or nil
	if runs == nil or runs >= SIMPLE_RUNS then
		return false
	end
	return MenuParty.Summary().Count == 0
end

-- Called whenever the picked mode changes.
function MenuPlay.OnModeChanged(fn: () -> ())
	table.insert(listeners, fn)
end

-- "SOLO" plus what changes the run from the default: "SOLO · ENDLESS · 2 CURSES".
function MenuPlay.Summary(): string
	local def = (Config.Modes :: any)[mode]
	local parts = { string.upper(def and def.DisplayName or mode) }
	if player:GetAttribute("Endless") == true and Config.Endless and Config.Endless.Enabled then
		table.insert(parts, "ENDLESS")
	end
	local n = #MenuCurses.Current()
	if n > 0 then
		table.insert(parts, n == 1 and "1 CURSE" or (n .. " CURSES"))
	end
	return table.concat(parts, " · ")
end

-- Starts the picked mode (the server validates: lobby phase, party rules, run servers).
-- Returns false when the client already knows it cannot start (a party member).
function MenuPlay.Start(toast: ((string, Color3?) -> ())?): boolean
	local party = MenuParty.Summary()
	local id = mode
	if party.Count > 0 then
		if not party.Leader then
			if toast then
				toast("Your party leader starts the runs: tap READY.", P.gold_300)
			end
			return false
		end
		local partyMode = MenuParty.PartyMode()
		if partyMode then
			id = partyMode
		end
	end
	Remotes.Get("StartRun"):FireServer(id)
	return true
end

-- "+45% gold · Frenzy, Horde" (or the empty text) for a curse list.
local function curseLine(list: { string }, empty: string): string
	if #list == 0 then
		return empty
	end
	local names = {}
	for _, id in ipairs(list) do
		table.insert(names, CurseData.Curses[id].Name)
	end
	return CurseData.GoldText(CurseData.GoldMult(list)) .. " gold · " .. table.concat(names, ", ")
end

-- The world row: its name, and the next world still locked (or the picked one's hint).
local function arenaText(profile: { [string]: any }?): (string, string)
	local arenaId = Remotes.State():GetAttribute("SelectedArena") or "Forest"
	local arena = (Config.Arenas :: any)[arenaId]
	local title = "WORLD · " .. string.upper(arena and arena.DisplayName or tostring(arenaId))
	local best = profile and profile.Stats and (profile.Stats.BestStage or 0) or 0
	local nextDef, nextNeed = nil, math.huge
	for _, name in ipairs(Config.Arenas.Order) do
		local def = (Config.Arenas :: any)[name]
		local need = def and def.RequiredBestStage or 0
		if def and best < need and need < nextNeed then
			nextDef, nextNeed = def, need
		end
	end
	if nextDef then
		return title, string.format("Next: %s at stage %d", nextDef.DisplayName, nextNeed)
	end
	return title, (arena and arena.Hint) or "Face the swarm"
end

-- Who starts and what the picked size means (party rules: MenuParty / RunManager).
function MenuPlay.RuleLine(): string
	local party = MenuParty.Summary()
	local def = (Config.Modes :: any)[mode]
	local name = def and def.DisplayName or mode
	if party.Count > 0 and not party.Leader then
		return "Party member: your leader picks the mode, curses and Endless and starts the run. Tap READY."
	elseif party.Count > 1 then
		return string.format("You lead a party of %d: Start begins a %s countdown for your party.", party.Count, name)
	end
	local style = MODES[mode]
	local lead = name .. (style and (" · " .. style.Sub) or "")
	if mode == (Config.Modes.Order[1] or "Solo") then
		return lead .. ". Start begins the run at once."
	end
	return string.format("%s. Start opens a countdown that players in this server can join.", lead)
end

function MenuPlay.Build(screen: Frame, ctx: { [string]: any })
	local host = ctx.Host
	local ui: { [string]: any } = { Modes = {} }
	local endlessSentAt = -100
	local endlessOn = player:GetAttribute("Endless") == true
	local detailsOpen = false
	local function toast(str: string, color: Color3?)
		if ctx.Toast then
			ctx.Toast(str, color)
		end
	end
	local holder, face = UIKit.Surface(screen, { Name = "Panel", Radius = Theme.Radius.L, Transparency = 0.04, Edge = P.gold_500, EdgeTransparency = 0.35 })
	ui.Panel = holder
	ui.Face = face
	-- header: BACK and a modest "Play" title, inside the panel
	ui.Header = UIKit.ScreenHeader(face, "Play", ctx.Back)
	ui.Header.Title.TextSize = UIKit.TS(30)

	-- MODE tabs: the picked one gold
	for i, id in ipairs(Config.Modes.Order) do
		local def = (Config.Modes :: any)[id]
		local style = MODES[id] or { Sub = def.MaxPlayers .. " players", Icon = "people3" }
		local b = UIKit.Button(face, {
			Kind = "Secondary",
			Title = string.upper(def.DisplayName),
			Icon = style.Icon,
			IconSize = 30,
			TitleStyle = "H2",
			TitleSize = 20,
			Align = "Center",
			Shrink = true,
			Name = id,
			LayoutOrder = i,
			Shadow = false,
			OnClick = function()
				local party = MenuParty.Summary()
				if party.Count > 0 and not party.Leader then
					toast("Your party leader picks the mode.", P.gold_300)
					return
				end
				local forced = party.Count > 1 and MenuParty.PartyMode() or nil
				if forced and forced ~= id then
					toast(string.format("A party of %d plays %s.", party.Count, string.upper(forced)), P.gold_300)
					return
				end
				MenuPlay.SetMode(id)
				UIAnim.Bump(ui.Modes[i].Face, 0.06)
			end,
		})
		ArtImage.ButtonIcon(b.Content:FindFirstChild("IconHolder"), "icons/ui/ui_" .. id, { Size = UDim2.fromScale(1.3, 1.3) })
		ui.Modes[i] = b
	end
	ui.Rule = UIKit.text(face, "Small", "", { Name = "Rule", TextWrapped = true, TextColor3 = C.TextMuted, TextYAlignment = Enum.TextYAlignment.Center, TextScaled = true }, 14)
	UIKit.new("UITextSizeConstraint", { MaxTextSize = UIKit.TS(14), MinTextSize = 9 }, ui.Rule)

	-- the options column scrolls when it does not fit (phones in landscape)
	local opts = UIKit.new("ScrollingFrame", {
		Name = "Options",
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		ScrollBarThickness = 4,
		ScrollBarImageColor3 = P.gold_500,
		CanvasSize = UDim2.new(),
		ScrollingDirection = Enum.ScrollingDirection.Y,
	}, face)
	ui.Options = opts

	-- One setting row: a small caps caption, the value, an optional muted line, a chevron.
	local function row(name: string, caption: string, icon: string, art: string?, chevron: boolean, onClick: () -> ()): any
		local b = UIKit.Button(opts, {
			Kind = "Secondary",
			Title = " ",
			Subtitle = " ",
			Icon = icon,
			IconSize = 34,
			TitleStyle = "Label",
			TitleSize = 18,
			Chevron = chevron,
			Align = "Left",
			Shrink = true,
			Name = name,
			Shadow = false,
			OnClick = onClick,
		})
		if art then
			ArtImage.ButtonIcon(b.Content:FindFirstChild("IconHolder"), "icons/ui/ui_" .. art, { Size = UDim2.fromScale(1.3, 1.3) })
		end
		local column = b.Content:FindFirstChild("Text")
		local cap = UIKit.text(column, "Caption", string.upper(caption), { Name = "Caption", LayoutOrder = 0, TextTruncate = Enum.TextTruncate.AtEnd }, 12)
		cap.TextColor3 = C.TextMuted
		return b
	end
	-- value line (and the muted line under it; "" hides it)
	local hideSummarySub = false -- the simple setup's side-by-side HERO / WORLD have no room for it
	local function setRow(b: any, value: string, sub: string?)
		b.SetText(value, sub or "")
		if b.Subtitle then
			b.Subtitle.Visible = sub ~= nil and sub ~= "" and not (hideSummarySub and (b == ui.Hero or b == ui.Arena))
		end
	end

	ui.Hero = row("Hero", "Hero", "helmet", "Characters", true, function()
		ctx.ShowScreen("Characters")
	end)
	ui.Arena = row("Arena", "World", "castle", "Arenas", true, function()
		ctx.ShowScreen("Arenas")
	end)
	ui.Difficulty = row("Difficulty", "Difficulty", "skull", nil, true, function()
		local profile = ctx.Profile()
		local currentTier = DifficultyData.Selected(profile)
		local at = table.find(DifficultyData.Order, currentTier) or 1
		for step = 1, #DifficultyData.Order - 1 do
			local id = DifficultyData.Order[(at + step - 1) % #DifficultyData.Order + 1]
			if DifficultyData.IsUnlocked(profile, id) then
				Remotes.Get("SetDifficulty"):FireServer(id)
				return
			end
		end
		-- the first tier still locked, and the one it needs cleared
		for _, id in ipairs(DifficultyData.Order) do
			if not DifficultyData.IsUnlocked(profile, id) then
				local nextLocked = DifficultyData.Tiers[id]
				local needs = DifficultyData.Tiers[nextLocked.Requires]
				toast(string.format("Clear all %d %s stages to unlock %s.", Config.Stages.WinMinStages, needs and needs.Name or "Standard", nextLocked.Name), P.gold_300)
				return
			end
		end
	end)
	ui.Curses = row("Curses", "Curses", "curse", "Curses", true, function()
		ctx.ShowScreen("Curses")
	end)
	-- META (docs/features/META.md): the worn Sigils (shown only while the switch is on)
	ui.Sigils = row("Sigils", "Sigils", "sparkle", nil, true, function()
		ctx.ShowScreen("Sigils")
	end)
	local sigilsOn = Config.FeatureOn("Sigils")
	ui.Sigils.Instance.Visible = sigilsOn
	-- ENDLESS: the row is the switch (remote SetEndless; the player attribute is the answer)
	ui.Endless = row("Endless", "Endless", "cycle", nil, false, function()
		endlessOn = not endlessOn
		endlessSentAt = os.clock()
		ui.PaintEndless()
		Remotes.Get("SetEndless"):FireServer(endlessOn)
	end)
	local endlessEnabled = Config.Endless ~= nil and Config.Endless.Enabled == true
	ui.Endless.Instance.Visible = endlessEnabled
	do
		local right = ui.Endless.Content:FindFirstChild("Right")
		if right then
			(right :: Frame).Visible = false
		end
		local contentPad = ui.Endless.Content:FindFirstChildOfClass("UIPadding")
		if contentPad then
			contentPad.PaddingRight = UDim.new(0, Theme.Space.L + 52)
		end
		local track = UIKit.new("Frame", {
			Name = "Switch",
			AnchorPoint = Vector2.new(1, 0.5),
			Position = UDim2.new(1, -Theme.Space.L, 0.5, 0),
			Size = UDim2.fromOffset(46, 26),
			BackgroundColor3 = P.slate_700,
			BorderSizePixel = 0,
			ZIndex = 4,
			Active = false,
		}, ui.Endless.Face)
		UIKit.new("UICorner", { CornerRadius = UDim.new(0.5, 0) }, track)
		UIKit.new("UIStroke", { Color = P.slate_500, Thickness = 1, Transparency = 0.3 }, track)
		local knob = UIKit.new("Frame", {
			Name = "Knob",
			AnchorPoint = Vector2.new(0, 0.5),
			Position = UDim2.new(0, 3, 0.5, 0),
			Size = UDim2.fromOffset(20, 20),
			BackgroundColor3 = P.ivory_200,
			BorderSizePixel = 0,
			ZIndex = 5,
			Active = false,
		}, track)
		UIKit.new("UICorner", { CornerRadius = UDim.new(0.5, 0) }, knob)
		ui.PaintEndless = function()
			track.BackgroundColor3 = endlessOn and P.gold_400 or P.slate_700
			knob.Position = endlessOn and UDim2.new(1, -23, 0.5, 0) or UDim2.new(0, 3, 0.5, 0)
			ui.Endless.SetSelected(endlessOn)
			setRow(ui.Endless, endlessOn and "On" or "Off", endlessOn and "No portal win · own leaderboard" or nil)
		end
		ui.PaintEndless()
	end
	ui.LastRun = MenuLastRun.Build(opts, ctx)
	-- DETAILS: the daily and weekly challenges (the footer link shows them under the grid)
	ui.Daily = row("Daily", "Daily challenge", "calendar", "Daily", true, function()
		ctx.ShowScreen("Daily")
	end)
	local weeklyOn = Config.FeatureOn("WeeklyChallenge")
	ui.Weekly = row("Weekly", "Weekly challenge", "calendar", nil, true, function()
		ctx.ShowScreen("Weekly")
	end)

	local function onStart()
		local party = MenuParty.Summary()
		if party.Count > 0 and not party.Leader then
			-- a member's START is READY (the leader's start waits for everyone)
			MenuParty.SetReady(not party.MyReady)
			return
		end
		if MenuPlay.Start(toast) then
			-- a group countdown shows on the home screen; a solo run hides the lobby
			ctx.Back()
		end
	end
	local simple = false
	local function showAdvanced()
		ui.Advanced.SetText(advancedOpen and "HIDE ADVANCED OPTIONS" or "ADVANCED OPTIONS", advancedOpen and "Back to the quick start" or "Mode, difficulty, curses, endless, daily")
		ui.Advanced.SetSelected(advancedOpen)
		opts.Visible = not simple or advancedOpen
	end
	ui.Start = UIKit.Button(face, {
		Kind = "Primary",
		Glow = false,
		Title = "Start Solo",
		Icon = "play",
		IconSize = 32,
		TitleStyle = "H2",
		TitleSize = 24,
		Align = "Center",
		Shrink = true,
		Name = "Start",
		OnClick = function()
			onStart()
		end,
	})
	ArtImage.ButtonIcon(ui.Start.Content:FindFirstChild("IconHolder"), "icons/ui/ui_Play", { Size = UDim2.fromScale(1.4, 1.4) })
	ui.Note = UIKit.text(face, "Caption", "", { Name = "StartNote", TextXAlignment = Enum.TextXAlignment.Center, TextTruncate = Enum.TextTruncate.AtEnd }, 12)
	ui.Divider = UIKit.new("Frame", { Name = "Divider", BackgroundColor3 = P.slate_600, BackgroundTransparency = 0.5, BorderSizePixel = 0 }, face)
	-- "Details >": shows the daily and weekly challenge rows
	ui.Details = UIKit.new("TextButton", {
		Name = "Details",
		Text = "Details >",
		FontFace = Theme.Font.Label,
		TextSize = UIKit.TS(16),
		TextColor3 = P.gold_200,
		TextXAlignment = Enum.TextXAlignment.Left,
		BackgroundTransparency = 1,
		AutoButtonColor = false,
	}, face)
	UIKit.Focusable(ui.Details)
	ui.Details.Activated:Connect(function()
		detailsOpen = not detailsOpen
		ui.Details.Text = detailsOpen and "Hide details" or "Details >"
		MenuPlay._layout()
		if detailsOpen then
			opts.CanvasPosition = Vector2.new(0, opts.CanvasSize.Y.Offset)
		end
	end)

	-- the simple setup (new accounts, MenuPlay.IsSimple): a summary card holding the HERO and
	-- WORLD rows, one big START with a line under it, and ADVANCED OPTIONS (collapsed)
	ui.Summary = UIKit.new("Frame", { Name = "Summary", BackgroundTransparency = 1 }, face)
	ui.QuickStart = UIKit.Button(face, {
		Kind = "Primary",
		Glow = true,
		Title = "START SOLO",
		Subtitle = "Just you · the run begins at once",
		Icon = "play",
		IconSize = 34,
		TitleStyle = "H1",
		TitleSize = 32,
		Align = "Center",
		Shrink = true,
		Name = "QuickStart",
		OnClick = function()
			onStart()
		end,
	})
	ArtImage.ButtonIcon(ui.QuickStart.Content:FindFirstChild("IconHolder"), "icons/ui/ui_Play", { Size = UDim2.fromScale(1.6, 1.6) })
	ui.Advanced = UIKit.Button(face, {
		Kind = "Secondary",
		Title = "ADVANCED OPTIONS",
		Subtitle = "Mode, difficulty, curses, endless, daily",
		Icon = "sparkle",
		IconSize = 24,
		TitleStyle = "Label",
		TitleSize = 16,
		Chevron = true,
		Align = "Left",
		Shrink = true,
		Name = "Advanced",
		OnClick = function()
			advancedOpen = not advancedOpen
			showAdvanced()
			MenuPlay._layout()
			if advancedOpen then
				UIAnim.Pop(opts, 0, 0.92)
			end
		end,
	})
	ui.Summary.Visible = false
	ui.QuickStart.Instance.Visible = false
	ui.Advanced.Instance.Visible = false

	local function showMode()
		local party = MenuParty.Summary()
		local member = party.Count > 0 and not party.Leader
		local forced = party.Count > 1 and MenuParty.PartyMode() or nil
		for i, id in ipairs(Config.Modes.Order) do
			local on = id == mode
			ui.Modes[i].SetSelected(false)
			ui.Modes[i].SetKind(on and "Primary" or "Secondary")
			-- a member, or a party of fixed size, cannot pick another size
			local locked = member or (forced ~= nil and forced ~= id)
			ui.Modes[i].Instance:SetAttribute("Locked", locked)
			ui.Modes[i].Face.BackgroundTransparency = (locked and not on) and 0.5 or 0
		end
		local def = (Config.Modes :: any)[mode]
		local startText = "Start " .. (def and def.DisplayName or mode)
		local note
		if member then
			startText = party.MyReady and "Unready" or "Ready"
			note = "Your leader starts the run"
		elseif party.Count > 1 then
			note = "Starts a countdown for your party"
		elseif mode == (Config.Modes.Order[1] or "Solo") then
			note = "Starts your run immediately"
		else
			note = "Opens a countdown others here can join"
		end
		ui.Start.SetText(startText)
		ui.Note.Text = note
		ui.QuickStart.SetText(string.upper(startText), mode == (Config.Modes.Order[1] or "Solo") and "Just you · the run begins at once"
			or "Opens a countdown that players here can JOIN")
		ui.Rule.Text = MenuPlay.RuleLine()
	end
	MenuPlay.OnModeChanged(showMode)
	showMode()

	local gridList = { ui.Hero.Instance, ui.Arena.Instance, ui.Difficulty.Instance, ui.Curses.Instance, ui.Sigils.Instance, ui.Endless.Instance }
	-- Places the rows in a grid (two columns when `w` allows) from y0; returns the next y.
	local function grid(list: { GuiObject }, w: number, y0: number, rowH: number): number
		local G = 10
		local cols = w >= 620 and 2 or 1
		local cw = math.floor((w - (cols - 1) * G) / cols)
		local n = 0
		for _, b in ipairs(list) do
			if simple and (b == ui.Hero.Instance or b == ui.Arena.Instance) then
				continue -- on the summary card
			end
			if not b.Visible then
				continue
			end
			local col, r = n % cols, math.floor(n / cols)
			place(b, col * (cw + G), y0 + r * (rowH + G), cw, rowH)
			n += 1
		end
		return y0 + math.ceil(n / cols) * (rowH + G)
	end

	local function layoutOptions(colW: number, rowH: number, y0: number?): number
		local w = colW - 6
		ui.Sigils.Instance.Visible = sigilsOn
		ui.Endless.Instance.Visible = endlessEnabled
		local showDetails = simple or detailsOpen
		ui.Daily.Instance.Visible = showDetails
		ui.Weekly.Instance.Visible = showDetails and weeklyOn
		local y = grid(gridList, w, y0 or 0, rowH)
		if ui.LastRun.Has() then
			place(ui.LastRun.Frame, 0, y, w, 76)
			ui.LastRun.SetWidth(w)
			y += 76 + 10
		end
		y = grid({ ui.Daily.Instance, ui.Weekly.Instance }, w, y, rowH)
		opts.CanvasSize = UDim2.fromOffset(0, math.max(0, y - 10))
		return math.max(0, y - 10)
	end

	-- Moves the controls between the full screen and the simple setup (same buttons).
	local function applySimple(on: boolean)
		simple = on
		screen:SetAttribute("Simple", on)
		ui.Hero.Instance.Parent = on and ui.Summary or opts
		ui.Arena.Instance.Parent = on and ui.Summary or opts
		for _, b in ipairs(ui.Modes) do
			b.Instance.Parent = on and opts or face
		end
		ui.Rule.Parent = on and opts or face
		ui.Start.Instance.Visible = not on
		ui.Note.Visible = not on
		ui.Divider.Visible = not on
		ui.Details.Visible = not on
		ui.Summary.Visible = on
		ui.QuickStart.Instance.Visible = on
		ui.Advanced.Instance.Visible = on
		showAdvanced()
	end

	-- The simple setup's ADVANCED column: the modes (a row of three when they fit), the
	-- rule line, then the usual option rows.
	local function layoutAdvanced(colW: number, rowH: number)
		local G = 10
		local w = colW - 6
		local y = 0
		local per = math.floor((w - 2 * G) / 3)
		if per >= 110 then
			for i, b in ipairs(ui.Modes) do
				place(b.Instance, (i - 1) * (per + G), 0, per, 52)
			end
			y = 52 + G
		else
			for _, b in ipairs(ui.Modes) do
				place(b.Instance, 0, y, w, 48)
				y += 48 + G
			end
		end
		place(ui.Rule, 0, y, w, 40)
		y += 40 + G
		layoutOptions(colW, rowH, y)
	end

	local function layoutSimple(W: number, H: number, top: number, M: number, portrait: boolean, pad: number, headH: number, rowH: number, short: boolean)
		local G = Theme.Layout.Gutter
		local availH = H - top - M
		local advH = 56
		local y0 = pad + headH + G
		-- the left (portrait: only) column: HERO, WORLD, START, ADVANCED OPTIONS
		-- (short landscape screens put HERO and WORLD side by side)
		local sideBySide = short and not portrait
		local summaryH = sideBySide and rowH or (2 * rowH + 10)
		local function column(x: number, colW: number, startH: number)
			local y = y0
			hideSummarySub = sideBySide
			for _, r in ipairs({ ui.Hero, ui.Arena }) do
				if r.Subtitle then
					r.Subtitle.Visible = not sideBySide and r.Subtitle.Text ~= ""
				end
			end
			place(ui.Summary, x, y, colW, summaryH)
			if sideBySide then
				local half = math.floor((colW - 10) / 2)
				place(ui.Hero.Instance, 0, 0, half, rowH)
				place(ui.Arena.Instance, half + 10, 0, half, rowH)
			else
				place(ui.Hero.Instance, 0, 0, colW, rowH)
				place(ui.Arena.Instance, 0, rowH + 10, colW, rowH)
			end
			y += summaryH + G
			place(ui.QuickStart.Instance, x, y, colW, startH)
			y += startH + G
			place(ui.Advanced.Instance, x, y, colW, advH)
			return y + advH + G
		end
		if portrait then
			local w = math.min(W - 2 * M, 560)
			local inner = w - 2 * pad
			local startH = 96
			local need = y0 + summaryH + G + startH + G + advH + pad
			local h = advancedOpen and availH or math.min(availH, need)
			place(ui.Panel, (W - w) / 2, top, w, h)
			local y = column(pad, inner, startH)
			place(opts, pad, y, inner + 6, math.max(0, h - pad - y))
			layoutAdvanced(inner + 6, rowH)
		else
			local maxH = math.min(availH, 520)
			local w = advancedOpen and math.min(W - 2 * M, 1000) or math.min(W - 2 * M, 600)
			local colW = advancedOpen and math.floor((w - 2 * pad - 2 * G) / 2) or (w - 2 * pad)
			local fixed = y0 + summaryH + 2 * G + advH + pad
			local startH = math.clamp(maxH - fixed, 64, advancedOpen and 150 or 104)
			local h = advancedOpen and maxH or math.min(maxH, fixed + startH)
			place(ui.Panel, (W - w) / 2, top, w, h)
			column(pad, colW, startH)
			place(opts, pad + colW + 2 * G, y0, colW + 6, h - y0 - pad)
			layoutAdvanced(colW + 6, rowH)
		end
		ui.LastRun.Frame.Visible = ui.LastRun.Has()
	end

	local function layout(v: Vector2, portrait: boolean, ins: { [string]: number })
		local W, H = v.X, v.Y
		local compact = UIKit.IsCompact()
		local M = compact and Theme.Layout.MarginCompact or Theme.Layout.Margin
		local G = 10
		local headY = math.max(ins.Top + 4, 12)
		-- clear the Roblox buttons and the gold readout along the top
		local top = headY + (portrait and 130 or 46)
		local pad = compact and 12 or 18
		local headH = 52
		local short = not portrait and H < 520
		-- phones at the Largest Roblox text size need the taller rows (three text lines)
		local rowH = short and 92 or (compact and 78 or 72)
		if simple then
			place(ui.Header.Frame, pad, pad, 300, headH)
			layoutSimple(W, H, top, M, portrait, pad, headH, short and 84 or rowH, short)
			return
		end
		local hasLast = ui.LastRun.Has()
		local w = math.min(W - 2 * M, 760)
		local iw = w - 2 * pad
		local availH = H - top - M
		local tabH = compact and 48 or 56
		local ruleH = iw >= 600 and 22 or 36
		local footH = 66
		local cols = (iw - 6) >= 620 and 2 or 1
		local rows = 4 + (sigilsOn and 1 or 0) + (endlessEnabled and 1 or 0)
		local want = math.ceil(rows / cols) * (rowH + G) - G + (hasLast and 76 + G or 0)
		if detailsOpen then
			local extra = 1 + (weeklyOn and 1 or 0)
			want += G + math.ceil(extra / cols) * (rowH + G) - G
		end
		-- header (+ tabs beside it on short screens), tabs, rule, body, footer
		local topBlock = short and (headH + 6) or (headH + G + tabH + 4)
		local h = math.min(availH, pad + topBlock + ruleH + G + want + G + footH + pad)
		place(ui.Panel, (W - w) / 2, top, w, h)
		local y = pad
		if short then
			place(ui.Header.Frame, pad, y, 270, headH)
			local tx = pad + 280
			local per = math.floor((w - pad - tx - 2 * 8) / 3)
			for i, b in ipairs(ui.Modes) do
				place(b.Instance, tx + (i - 1) * (per + 8), y + 2, per, headH - 4)
			end
			y += headH + 6
		else
			place(ui.Header.Frame, pad, y, iw, headH)
			y += headH + G
			local per = math.floor((iw - 2 * 8) / 3)
			for i, b in ipairs(ui.Modes) do
				place(b.Instance, pad + (i - 1) * (per + 8), y, per, tabH)
			end
			y += tabH + 4
		end
		place(ui.Rule, pad, y, iw, ruleH)
		y += ruleH + G
		local footY = h - pad - footH
		place(opts, pad, y, iw + 6, math.max(0, footY - G - y))
		layoutOptions(iw + 6, rowH)
		place(ui.Divider, pad, footY - 6, iw, 1)
		local sw = math.min(math.floor(iw * 0.62), 340)
		place(ui.Start.Instance, pad + iw - sw, footY, sw, 48)
		place(ui.Note, pad + iw - sw, footY + 50, sw, 16)
		place(ui.Details, pad, footY, math.min(120, iw - sw - 8), 48)
		ui.LastRun.Frame.Visible = hasLast
	end
	MenuPlay._layout = function()
		layout(host.VirtualSize(), host.IsPortrait(), host.Insets())
	end

	local function refresh()
		local profile = ctx.Profile()
		local had = ui.LastRun.Has()
		local wantSimple = MenuPlay.IsSimple(profile)
		local modeChanged = wantSimple ~= simple
		if modeChanged then
			applySimple(wantSimple)
		end
		ui.LastRun.Refresh(profile)
		-- the hero and skin PLAY will use (CHARACTERS changes them)
		local heroId = profile and profile.SelectedCharacter or CharacterData.Default
		local hero = CharacterData.Characters[heroId] or CharacterData.Characters[CharacterData.Default]
		local skinId = profile and type(profile.Skins) == "table" and profile.Skins[hero.Id] or "Default"
		local skin = skinId ~= "Default" and CharacterData.Skins[skinId] or nil
		setRow(ui.Hero, hero.Name, skin and skin.Name or "Default skin")
		local arenaId = Remotes.State():GetAttribute("SelectedArena") or "Forest"
		local arena = (Config.Arenas :: any)[arenaId]
		local _, arenaSub = arenaText(profile)
		setRow(ui.Arena, arena and arena.DisplayName or tostring(arenaId), arenaSub)
		local tier = DifficultyData.Tiers[DifficultyData.Selected(profile)]
		local nextLocked: string? = nil
		for _, id in ipairs(DifficultyData.Order) do
			if not DifficultyData.IsUnlocked(profile, id) then
				-- the next locked tier beside the option (the tap toast names what opens it)
				local t = DifficultyData.Tiers[id]
				nextLocked = t.Name .. " locked"
				break
			end
		end
		setRow(ui.Difficulty, tier and tier.Name or "Standard", nextLocked or "Tap to change")
		local curses = MenuCurses.Current()
		setRow(ui.Curses, #curses > 0 and string.format("%d active", #curses) or "None", curseLine(curses, "Harder runs, more gold"))
		ui.Curses.SetSelected(#curses > 0)
		local used, score = MenuDaily.Status(profile)
		local dailySub = used and ("Practice only" .. (score > 0 and (" · " .. CurseData.ScoreText(score)) or "") .. " · resets in " .. MenuDaily.TimeLeft())
			or ("Used when it starts · resets in " .. MenuDaily.TimeLeft())
		setRow(ui.Daily, used and "Scored try used" or "Scored try ready", dailySub)
		if sigilsOn then
			setRow(ui.Sigils, MenuSigils.Summary(profile), nil)
		end
		if weeklyOn then
			setRow(ui.Weekly, MenuWeekly.Summary(profile), "One hero, one week")
		end
		showMode()
		if modeChanged or had ~= ui.LastRun.Has() then
			MenuPlay._layout()
		end
	end

	return {
		Layout = layout,
		Refresh = function(_p)
			refresh()
		end,
		OnShow = function(_p)
			refresh()
			showMode()
			for i, b in ipairs(ui.Modes) do
				UIAnim.Pop(b.Instance, 0.03 * i, 0.85)
			end
			UIAnim.Pop(simple and ui.QuickStart.Instance or ui.Start.Instance, 0.12, 0.85)
			MenuPlay._layout()
			UIKit.FocusIfGamepad(simple and ui.QuickStart.Instance or ui.Start.Instance)
		end,
		Update = function(_dt: number)
			-- the ENDLESS switch follows the server's answer (after a short wait for our tap)
			local serverOn = player:GetAttribute("Endless") == true
			if os.clock() - endlessSentAt > 1.5 and endlessOn ~= serverOn then
				endlessOn = serverOn
				ui.PaintEndless()
			end
			if screen.Visible then
				local party = MenuParty.Summary()
				local key = tostring(Remotes.State():GetAttribute("SelectedArena")) .. "|" .. table.concat(MenuCurses.Current(), ",")
					.. "|" .. party.Count .. "|" .. tostring(party.Leader) .. "|" .. tostring(party.MyReady) .. "|" .. MenuDaily.TimeLeft()
				if key ~= ui.Key then
					ui.Key = key
					refresh()
				end
			end
		end,
	}
end

MenuPlay._layout = function() end

return MenuPlay
