--[[
	MenuPlay.lua
	The run-setup step (the home screen's PLAY opens it; overhaul 01_Title "Choose your
	mode next."):

	  left        SOLO / DUO / TRIO (big; the picked one lit), a line that says who starts
	              and what the size means (a party plays its own size, a member waits for
	              the leader), START
	  right       (scrolls when it does not fit)
	    HERO        the selected hero and equipped skin (opens CHARACTERS)
	    WORLD       the lobby's arena and the next one still locked (opens ARENAS)
	    DIFFICULTY  cycles through the unlocked tiers; locked tiers name what clears them
	    CURSES      the run modifiers picked and their gold (opens CURSES, MenuCurses)
	    ENDLESS     switch (remote SetEndless; the server's answer is the player attribute
	                "Endless", Config.Endless): no portal win, its own leaderboard
	    DAILY       today's scored try / practice and the reset time (opens DAILY, which
	                holds the full rules)
	    LAST RUN    the saved last run with RETRY (MenuLastRun), when there is one
	  START       starts the picked mode (remote StartRun, the same validated start the
	              server always used: RunManager.startRun). A party member's START is
	              their READY toggle instead (the leader starts).

	The picked mode lives here (MenuPlay.Mode) so the home screen's line under PLAY shows
	the same thing. It defaults to SOLO; joining a party picks the party's size.
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
		return title, string.format("Current · next: %s at best stage %d", nextDef.DisplayName, nextNeed)
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
		return string.format("You lead a party of %d: START begins a %s countdown for your party.", party.Count, name)
	elseif mode == (Config.Modes.Order[1] or "Solo") then
		return "Just you. START begins the run at once."
	end
	return string.format("START opens a %s countdown that players in this server can JOIN.", name)
end

function MenuPlay.Build(screen: Frame, ctx: { [string]: any })
	local host = ctx.Host
	local ui: { [string]: any } = { Modes = {} }
	local endlessSentAt = -100
	local function toast(str: string, color: Color3?)
		if ctx.Toast then
			ctx.Toast(str, color)
		end
	end
	ui.Header = UIKit.ScreenHeader(screen, "PLAY", ctx.Back)
	local holder, face = UIKit.Surface(screen, { Name = "Panel", Radius = Theme.Radius.L, Transparency = 0.06, Edge = P.gold_400, EdgeTransparency = 0.35 })
	ui.Panel = holder
	ui.Face = face

	-- MODE: three big buttons, the picked one lit
	for i, id in ipairs(Config.Modes.Order) do
		local def = (Config.Modes :: any)[id]
		local style = MODES[id] or { Sub = def.MaxPlayers .. " players", Icon = "people3" }
		local b = UIKit.Button(face, {
			Kind = "Secondary",
			Title = string.upper(def.DisplayName),
			Subtitle = style.Sub,
			Icon = style.Icon,
			IconSize = 30,
			TitleStyle = "H2",
			Align = "Left",
			Shrink = true,
			Name = id,
			LayoutOrder = i,
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
		ArtImage.ButtonIcon(b.Content:FindFirstChild("IconHolder"), "icons/ui/ui_" .. id, { Size = UDim2.fromScale(1.5, 1.5) })
		ui.Modes[i] = b
	end
	ui.Rule = UIKit.text(face, "Small", "", { Name = "Rule", TextWrapped = true, TextColor3 = P.ivory_200, TextYAlignment = Enum.TextYAlignment.Center, TextScaled = true }, 14)
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

	local function row(name: string, title: string, sub: string, icon: string, art: string?, onClick: () -> ()): any
		local b = UIKit.Button(opts, {
			Kind = "Secondary",
			Title = title,
			Subtitle = sub,
			Icon = icon,
			IconSize = 26,
			TitleStyle = "Label",
			TitleSize = 16,
			Chevron = true,
			Align = "Left",
			Shrink = true,
			Name = name,
			OnClick = onClick,
		})
		if art then
			ArtImage.ButtonIcon(b.Content:FindFirstChild("IconHolder"), "icons/ui/ui_" .. art, { Size = UDim2.fromScale(1.45, 1.45) })
		end
		return b
	end
	ui.Hero = row("Hero", "HERO · KNIGHT", "Change in Characters", "helmet", "Characters", function()
		ctx.ShowScreen("Characters")
	end)
	ui.Arena = row("Arena", "WORLD · FOREST", "Face the swarm", "castle", "Arenas", function()
		ctx.ShowScreen("Arenas")
	end)
	ui.Difficulty = row("Difficulty", "DIFFICULTY · STANDARD", "Tap to change", "skull", nil, function()
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
	ui.Curses = row("Curses", "CURSES", "Harder runs, more gold", "curse", "Curses", function()
		ctx.ShowScreen("Curses")
	end)
	local eHolder, eFace = UIKit.Surface(opts, { Name = "EndlessRow", Radius = Theme.Radius.M, Transparency = 0.12, Edge = C.PanelEdge, EdgeTransparency = Theme.Alpha.Edge, Shadow = false })
	ui.EndlessRow = eHolder
	ui.EndlessEdge = eFace:FindFirstChildOfClass("UIStroke")
	UIKit.padding(eFace, 0, 12, 0, 12)
	ui.EndlessToggle = UIKit.Toggle(eFace, "Endless", "cycle", "No portal win: stages go on. Own leaderboard.", player:GetAttribute("Endless") == true, function(on)
		endlessSentAt = os.clock()
		Remotes.Get("SetEndless"):FireServer(on)
	end, { AnchorPoint = Vector2.new(0, 0.5), Position = UDim2.fromScale(0, 0.5), Size = UDim2.new(1, 0, 0, 56) })
	if Config.Endless == nil or not Config.Endless.Enabled then
		eHolder.Visible = false
	end
	ui.Daily = row("Daily", "DAILY CHALLENGE", "One scored try a day", "calendar", "Daily", function()
		ctx.ShowScreen("Daily")
	end)
	-- META (docs/features/META.md): the worn Sigils and the Weekly Challenge (shown only while
	-- their switches are on)
	ui.Sigils = row("Sigils", "SIGILS", "None worn", "sparkle", nil, function()
		ctx.ShowScreen("Sigils")
	end)
	ui.Sigils.Instance.Visible = Config.FeatureOn("Sigils")
	ui.Weekly = row("Weekly", "WEEKLY CHALLENGE", "One hero, one week", "calendar", nil, function()
		ctx.ShowScreen("Weekly")
	end)
	ui.Weekly.Instance.Visible = Config.FeatureOn("WeeklyChallenge")
	ui.LastRun = MenuLastRun.Build(opts, ctx)
	ui.Start = UIKit.Button(face, {
		Kind = "Primary",
		Glow = true,
		Title = "START",
		Icon = "play",
		IconSize = 30,
		TitleStyle = "H1",
		TitleSize = 30,
		Align = "Center",
		Name = "Start",
		OnClick = function()
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
		end,
	})
	ArtImage.ButtonIcon(ui.Start.Content:FindFirstChild("IconHolder"), "icons/ui/ui_Play", { Size = UDim2.fromScale(1.6, 1.6) })

	local function showMode()
		local party = MenuParty.Summary()
		local member = party.Count > 0 and not party.Leader
		local forced = party.Count > 1 and MenuParty.PartyMode() or nil
		for i, id in ipairs(Config.Modes.Order) do
			local on = id == mode
			ui.Modes[i].SetSelected(on)
			ui.Modes[i].SetKind(on and "Outline" or "Secondary")
			-- a member, or a party of fixed size, cannot pick another size
			ui.Modes[i].Instance:SetAttribute("Locked", member or (forced ~= nil and forced ~= id))
			ui.Modes[i].Face.BackgroundTransparency = (member or (forced ~= nil and forced ~= id)) and 0.5 or 0
		end
		local def = (Config.Modes :: any)[mode]
		local startText = "START " .. string.upper(def and def.DisplayName or mode)
		if member then
			startText = party.MyReady and "UNREADY" or "READY"
		end
		ui.Start.SetText(startText)
		ui.Rule.Text = MenuPlay.RuleLine()
	end
	MenuPlay.OnModeChanged(showMode)
	showMode()

	local optionList = { ui.Hero.Instance, ui.Arena.Instance, ui.Difficulty.Instance, ui.Curses.Instance, ui.Sigils.Instance, ui.EndlessRow, ui.Daily.Instance, ui.Weekly.Instance }
	local function layoutOptions(colW: number, rowH: number, endlessH: number, lastH: number): number
		local G = Theme.Layout.Gutter
		local y = 0
		for _, b in ipairs(optionList) do
			if b.Visible or (b ~= ui.EndlessRow and b ~= ui.Sigils.Instance and b ~= ui.Weekly.Instance) then
				local h = b == ui.EndlessRow and endlessH or rowH
				place(b, 0, y, colW - 6, h)
				y += h + G
			end
		end
		if ui.LastRun.Has() then
			place(ui.LastRun.Frame, 0, y, colW - 6, lastH)
			ui.LastRun.SetWidth(colW - 6)
			y += lastH + G
		end
		opts.CanvasSize = UDim2.fromOffset(0, math.max(0, y - G))
		return math.max(0, y - G)
	end

	local function layout(v: Vector2, portrait: boolean, ins: { [string]: number })
		local W, H = v.X, v.Y
		local compact = UIKit.IsCompact()
		local M = compact and Theme.Layout.MarginCompact or Theme.Layout.Margin
		local G = Theme.Layout.Gutter
		local headY = math.max(ins.Top + 4, 12)
		place(ui.Header.Frame, M, headY, math.min(520, W - 2 * M), 56)
		local top = math.max(headY + 66 + (portrait and 58 or 0), portrait and 0 or 76)
		local hasLast = ui.LastRun.Has()
		local pad = 16
		local endlessH = 64
		if portrait then
			local w = math.min(W - 2 * M, 560)
			local inner = w - 2 * pad
			local modeH, rowH, lastH, startH, ruleH = 64, 56, 76, 68, 40
			local h = H - top - M
			place(ui.Panel, (W - w) / 2, top, w, h)
			local y = pad
			for i = 1, #ui.Modes do
				place(ui.Modes[i].Instance, pad, y, inner, modeH)
				y += modeH + G
			end
			place(ui.Rule, pad, y, inner, ruleH)
			y += ruleH + G
			place(ui.Start.Instance, pad, h - pad - startH, inner, startH)
			local optsH = h - pad - startH - G - y
			place(opts, pad, y, inner + 6, math.max(0, optsH))
			layoutOptions(inner + 6, rowH, endlessH, hasLast and lastH or 0)
		else
			-- two columns: the modes, the rule line and START on the left, the options right
			local w = math.min(W - 2 * M, 1000)
			local h = math.min(H - top - M, 520)
			place(ui.Panel, (W - w) / 2, top, w, h)
			local inner = h - 2 * pad
			local colW = math.floor((w - 2 * pad - 2 * G) / 2)
			local startH = math.clamp(math.floor(inner * 0.2), 52, 80)
			local ruleH = math.clamp(math.floor(inner * 0.13), 32, 52)
			local modeH = math.floor((inner - startH - ruleH - 3 * G) / 3)
			local y = pad
			for i = 1, #ui.Modes do
				place(ui.Modes[i].Instance, pad, y, colW, modeH)
				y += modeH + G
			end
			place(ui.Rule, pad, y, colW, ruleH)
			place(ui.Start.Instance, pad, h - pad - startH, colW, startH)
			local x = pad + colW + 2 * G
			local rows = 5 + (ui.Sigils.Instance.Visible and 1 or 0) + (ui.Weekly.Instance.Visible and 1 or 0)
			local lastH = hasLast and 76 or 0
			local rowH = math.clamp(math.floor((inner - lastH - (hasLast and G or 0) - endlessH - rows * G) / rows), Theme.Size.TapMin, 66)
			place(opts, x, pad, colW + 6, inner)
			layoutOptions(colW + 6, rowH, endlessH, lastH)
		end
		ui.LastRun.Frame.Visible = hasLast
	end
	MenuPlay._layout = function()
		layout(host.VirtualSize(), host.IsPortrait(), host.Insets())
	end

	local function refresh()
		local profile = ctx.Profile()
		local had = ui.LastRun.Has()
		ui.LastRun.Refresh(profile)
		-- the hero and skin PLAY will use (CHARACTERS changes them)
		local heroId = profile and profile.SelectedCharacter or CharacterData.Default
		local hero = CharacterData.Characters[heroId] or CharacterData.Characters[CharacterData.Default]
		local skinId = profile and type(profile.Skins) == "table" and profile.Skins[hero.Id] or "Default"
		local skin = skinId ~= "Default" and CharacterData.Skins[skinId] or nil
		ui.Hero.SetText("HERO · " .. string.upper(hero.Name), (skin and (skin.Name .. " · ") or "") .. "Change in Characters")
		local title, sub = arenaText(profile)
		ui.Arena.SetText(title, sub)
		local tier = DifficultyData.Tiers[DifficultyData.Selected(profile)]
		local nextLocked: string? = nil
		local unlocked = 0
		for _, id in ipairs(DifficultyData.Order) do
			if DifficultyData.IsUnlocked(profile, id) then
				unlocked += 1
			elseif not nextLocked then
				local t = DifficultyData.Tiers[id]
				local needs = DifficultyData.Tiers[t.Requires]
				nextLocked = string.format("%s locked: clear %s first", t.Name, needs and needs.Name or "Standard")
			end
		end
		ui.Difficulty.SetText("DIFFICULTY · " .. string.upper(tier and tier.Name or "Standard"), unlocked > 1 and "Tap to change" or (nextLocked or "Tap to change"))
		local curses = MenuCurses.Current()
		ui.Curses.SetText(#curses > 0 and string.format("CURSES · %d", #curses) or "CURSES", curseLine(curses, "Harder runs, more gold"))
		ui.Curses.SetSelected(#curses > 0)
		local used, score = MenuDaily.Status(profile)
		local dailySub = used and ("Scored try used" .. (score > 0 and (" · " .. CurseData.ScoreText(score)) or "") .. " · practice only · resets in " .. MenuDaily.TimeLeft())
			or ("One scored try · used when it starts · resets in " .. MenuDaily.TimeLeft())
		ui.Daily.SetText(nil, dailySub)
		if ui.Sigils.Instance.Visible then
			ui.Sigils.SetText(nil, MenuSigils.Summary(profile))
		end
		if ui.Weekly.Instance.Visible then
			ui.Weekly.SetText(nil, MenuWeekly.Summary(profile))
		end
		showMode()
		if had ~= ui.LastRun.Has() then
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
			UIAnim.Pop(ui.Start.Instance, 0.12, 0.85)
			MenuPlay._layout()
			UIKit.FocusIfGamepad(ui.Start.Instance)
		end,
		Update = function(_dt: number)
			-- the ENDLESS switch follows the server's answer (after a short wait for our tap)
			local endlessOn = player:GetAttribute("Endless") == true
			if os.clock() - endlessSentAt > 1.5 and ui.EndlessToggle.Get() ~= endlessOn then
				ui.EndlessToggle.Set(endlessOn)
			end
			local lit = ui.EndlessToggle.Get()
			if ui.EndlessEdge and ui.EndlessRow:GetAttribute("Lit") ~= lit then
				ui.EndlessRow:SetAttribute("Lit", lit)
				ui.EndlessEdge.Color = lit and P.gold_400 or C.PanelEdge
				ui.EndlessEdge.Transparency = lit and 0.1 or Theme.Alpha.Edge
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
