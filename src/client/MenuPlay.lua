--[[
	MenuPlay.lua
	The PLAY options sheet (opened from the home screen's mode selector under PLAY):

	  MODE        SOLO / DUO / TRIO (big; a tap picks the mode the home PLAY button uses)
	  ARENA       the lobby's arena (opens the ARENAS screen, MenuArenas)
	  DIFFICULTY  cycles through the unlocked tiers (remote SetDifficulty)
	  CURSES      the run modifiers picked and their gold (opens CURSES, MenuCurses)
	  ENDLESS     switch (remote SetEndless; the server's answer is the player attribute
	              "Endless", Config.Endless)
	  LAST RUN    the saved last run with RETRY (MenuLastRun), when there is one
	  START       starts the picked mode (remote StartRun, the same validated start as
	              the home PLAY button; the server decides: RunManager.startRun)

	The picked mode lives here (MenuPlay.Mode) so the home PLAY button and its selector
	show the same thing. It defaults to SOLO; joining a party picks the party's size.
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

-- The arena row: its name, and the next arena still locked (or the picked arena's hint).
local function arenaText(profile: { [string]: any }?): (string, string)
	local arenaId = Remotes.State():GetAttribute("SelectedArena") or "Forest"
	local arena = (Config.Arenas :: any)[arenaId]
	local title = "ARENA · " .. string.upper(arena and arena.DisplayName or tostring(arenaId))
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
		return title, string.format("Unlock %s at stage %d", nextDef.DisplayName, nextNeed)
	end
	return title, (arena and arena.Hint) or "Face the swarm"
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
				MenuPlay.SetMode(id)
				UIAnim.Bump(ui.Modes[i].Face, 0.06)
			end,
		})
		ArtImage.ButtonIcon(b.Content:FindFirstChild("IconHolder"), "icons/ui/ui_" .. id, { Size = UDim2.fromScale(1.5, 1.5) })
		ui.Modes[i] = b
	end

	local function row(name: string, title: string, sub: string, icon: string, art: string?, onClick: () -> ()): any
		local b = UIKit.Button(face, {
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
	ui.Arena = row("Arena", "ARENA · FOREST", "Face the swarm", "castle", "Arenas", function()
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
	local eHolder, eFace = UIKit.Surface(face, { Name = "EndlessRow", Radius = Theme.Radius.M, Transparency = 0.12, Edge = C.PanelEdge, EdgeTransparency = Theme.Alpha.Edge, Shadow = false })
	ui.EndlessRow = eHolder
	ui.EndlessEdge = eFace:FindFirstChildOfClass("UIStroke")
	UIKit.padding(eFace, 0, 12, 0, 12)
	ui.EndlessToggle = UIKit.Toggle(eFace, "Endless", "cycle", nil, player:GetAttribute("Endless") == true, function(on)
		endlessSentAt = os.clock()
		Remotes.Get("SetEndless"):FireServer(on)
	end, { AnchorPoint = Vector2.new(0, 0.5), Position = UDim2.fromScale(0, 0.5), Size = UDim2.new(1, 0, 0, Theme.Size.TapMin) })
	if Config.Endless == nil or not Config.Endless.Enabled then
		eHolder.Visible = false
	end
	ui.LastRun = MenuLastRun.Build(face, ctx)
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
			if MenuPlay.Start(toast) then
				-- a group countdown shows on the home screen; a solo run hides the lobby
				ctx.Back()
			end
		end,
	})
	ArtImage.ButtonIcon(ui.Start.Content:FindFirstChild("IconHolder"), "icons/ui/ui_Play", { Size = UDim2.fromScale(1.6, 1.6) })

	local function showMode()
		for i, id in ipairs(Config.Modes.Order) do
			local on = id == mode
			ui.Modes[i].SetSelected(on)
			ui.Modes[i].SetKind(on and "Outline" or "Secondary")
		end
		local def = (Config.Modes :: any)[mode]
		ui.Start.SetText("START " .. string.upper(def and def.DisplayName or mode))
	end
	MenuPlay.OnModeChanged(showMode)
	showMode()

	local function layout(v: Vector2, portrait: boolean, ins: { [string]: number })
		local W, H = v.X, v.Y
		local compact = UIKit.IsCompact()
		local M = compact and Theme.Layout.MarginCompact or Theme.Layout.Margin
		local G = Theme.Layout.Gutter
		local headY = math.max(ins.Top + 4, 12)
		place(ui.Header.Frame, M, headY, math.min(520, W - 2 * M), 56)
		local top = math.max(headY + 66 + (portrait and 58 or 0), portrait and 0 or 76)
		local hasLast = ui.LastRun.Has()
		local endless = ui.EndlessRow.Visible
		local pad = 16
		if portrait then
			local w = math.min(W - 2 * M, 560)
			local inner = w - 2 * pad
			local modeH, rowH, lastH, startH = 76, 60, 76, 76
			local rows = 3 + (endless and 1 or 0)
			local h = pad + 3 * modeH + 2 * G + 18 + rows * rowH + (rows - 1) * G + (hasLast and (G + lastH) or 0) + 18 + startH + pad
			h = math.min(h, H - top - M)
			place(ui.Panel, (W - w) / 2, top, w, h)
			local y = pad
			for i = 1, #ui.Modes do
				place(ui.Modes[i].Instance, pad, y, inner, modeH)
				y += modeH + G
			end
			y += 18 - G
			for _, b in ipairs({ ui.Arena.Instance, ui.Difficulty.Instance, ui.Curses.Instance, ui.EndlessRow }) do
				if b.Visible or b ~= ui.EndlessRow then
					place(b, pad, y, inner, rowH)
					y += rowH + G
				end
			end
			if hasLast then
				place(ui.LastRun.Frame, pad, y, inner, lastH)
				ui.LastRun.SetWidth(inner)
			end
			place(ui.Start.Instance, pad, h - pad - startH, inner, startH)
		else
			-- two columns: the modes and START on the left, the options on the right
			local w = math.min(W - 2 * M, 980)
			local h = math.min(H - top - M, 470)
			place(ui.Panel, (W - w) / 2, top, w, h)
			local inner = h - 2 * pad
			local colW = math.floor((w - 2 * pad - 2 * G) / 2)
			local startH = math.clamp(math.floor(inner * 0.24), 56, 84)
			local modeH = math.floor((inner - startH - 3 * G) / 3)
			local y = pad
			for i = 1, #ui.Modes do
				place(ui.Modes[i].Instance, pad, y, colW, modeH)
				y += modeH + G
			end
			place(ui.Start.Instance, pad, h - pad - startH, colW, startH)
			local x = pad + colW + 2 * G
			local rows = 3 + (endless and 1 or 0)
			local lastH = hasLast and 76 or 0
			local rowH = math.clamp(math.floor((inner - lastH - (hasLast and G or 0) - (rows - 1) * G) / rows), Theme.Size.TapMin, 72)
			y = pad
			for _, b in ipairs({ ui.Arena.Instance, ui.Difficulty.Instance, ui.Curses.Instance, ui.EndlessRow }) do
				if b.Visible or b ~= ui.EndlessRow then
					place(b, x, y, colW, rowH)
					y += rowH + G
				end
			end
			if hasLast then
				place(ui.LastRun.Frame, x, h - pad - lastH, colW, lastH)
				ui.LastRun.SetWidth(colW)
			end
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
		local title, sub = arenaText(profile)
		ui.Arena.SetText(title, sub)
		local tier = DifficultyData.Tiers[DifficultyData.Selected(profile)]
		local unlocked = 0
		for _, id in ipairs(DifficultyData.Order) do
			if DifficultyData.IsUnlocked(profile, id) then
				unlocked += 1
			end
		end
		ui.Difficulty.SetText("DIFFICULTY · " .. string.upper(tier and tier.Name or "Standard"), unlocked > 1 and "Tap to change" or "More unlock as you clear stages")
		local curses = MenuCurses.Current()
		ui.Curses.SetText(#curses > 0 and string.format("CURSES · %d", #curses) or "CURSES", curseLine(curses, "Harder runs, more gold"))
		ui.Curses.SetSelected(#curses > 0)
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
				local key = tostring(Remotes.State():GetAttribute("SelectedArena")) .. "|" .. table.concat(MenuCurses.Current(), ",")
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
