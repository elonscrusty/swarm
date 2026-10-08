--[[
	MenuWeekly.lua
	The WEEKLY screen (features 21 and 19; Config.Features.WeeklyChallenge / TeamBoard).
	  head  this week's challenge: the fixed hero, curses and first world (MetaData.Weekly,
	        the same for everyone), your best this week and ever, the reset time; tabs for
	        the boards: WEEKLY (the challenge), DUO and TRIO (the weekly team boards)
	  body  the picked board (LeaderboardRequest / LeaderboardData, LeaderboardService)
	  foot  PLAY WEEKLY (StartRun "Weekly": the server sets the hero and curses itself)
	Every try counts (the week's best is kept). Sigils are off in the weekly run.
]]

local Shared = game:GetService("ReplicatedStorage"):WaitForChild("Shared")
local Config = require(Shared:WaitForChild("Config"))
local Theme = require(Shared:WaitForChild("Theme"))
local Remotes = require(Shared:WaitForChild("Remotes"))
local MetaData = require(Shared:WaitForChild("MetaData"))
local CurseData = require(Shared:WaitForChild("CurseData"))
local CharacterData = require(Shared:WaitForChild("CharacterData"))
local UIKit = require(script.Parent.UIKit)
local UIAnim = require(script.Parent.UIAnim)
local Icons = require(script.Parent.Icons)
local MetaUI = require(script.Parent.MetaUI)

local MenuWeekly = {}

local new, TS = UIKit.new, UIKit.TS
local C = Theme.Color

-- This week's setup (server clock).
function MenuWeekly.Setup(): MetaData.Weekly
	return MetaData.Weekly(MetaData.WeekOf(MetaUI.Now()))
end

-- (this week's best score, all-time best) from the profile.
function MenuWeekly.Best(p: { [string]: any }?): (number, number)
	local w = MetaUI.Features(p).Weekly
	if type(w) ~= "table" then
		return 0, 0
	end
	local week = MetaData.WeekOf(MetaUI.Now())
	return (w.Week == week and tonumber(w.Score) or 0) :: number, tonumber(w.BestScore) or 0
end

-- The PLAY / MORE row's sub line.
function MenuWeekly.Summary(p: { [string]: any }?): string
	local setup = MenuWeekly.Setup()
	local hero = CharacterData.Characters[setup.Hero]
	local best = MenuWeekly.Best(p)
	return string.format("%s · %s · resets in %s", hero and hero.Name or setup.Hero, best > 0 and ("best " .. UIKit.formatNumber(best)) or "not played", MetaData.TimeText(MetaData.WeekSecondsLeft(MetaUI.Now())))
end

function MenuWeekly.Build(screen: Frame, ctx: { [string]: any })
	local host = ctx.Host
	local ui = MetaUI.Screen(screen, ctx, "WEEKLY")
	local heroWell = new("Frame", { Name = "Hero", BackgroundColor3 = C.PanelRaised, BackgroundTransparency = 0, Size = UDim2.fromOffset(64, 64) }, ui.Head)
	UIKit.corner(heroWell, 999)
	UIKit.stroke(heroWell, C.PanelEdge, 2, 0)
	local line1 = MetaUI.Line(ui.Head, "Label", "", 17, { Name = "WeekHero", TextColor3 = C.BlueDeep })
	local line2 = MetaUI.Line(ui.Head, "Small", "", 14, { Name = "WeekCurses", TextColor3 = C.Text })
	local line3 = MetaUI.Line(ui.Head, "Small", "", 14, { Name = "WeekBest" })

	local boards = {}
	if Config.FeatureOn("WeeklyChallenge") then
		table.insert(boards, { Id = "Weekly", Title = "Weekly" })
	end
	if Config.FeatureOn("TeamBoard") then
		table.insert(boards, { Id = "TeamDuo", Title = "Duo" })
		table.insert(boards, { Id = "TeamTrio", Title = "Trio" })
	end
	local selected = boards[1] and boards[1].Id or "Weekly"
	local fillBoard: (any) -> ()
	local lastData: { [string]: any } = {}
	local tabs = UIKit.Tabs(ui.Head, boards, function(id: string)
		selected = id
		fillBoard(lastData[id])
		Remotes.Get("LeaderboardRequest"):FireServer(id)
	end, { Name = "BoardTabs" })
	UIKit.list(ui.Body, { Padding = UDim.new(0, 6) })

	local play = UIKit.Button(ui.Foot, {
		Kind = "Primary",
		Glow = true,
		Title = "PLAY WEEKLY",
		Icon = "play",
		IconSize = 24,
		TitleStyle = "H2",
		Align = "Center",
		Name = "PlayWeekly",
		Size = UDim2.fromScale(1, 1),
		OnClick = function()
			Remotes.Get("StartRun"):FireServer(MetaData.WeeklyMode)
			ctx.Back()
		end,
	})
	play.Instance.Visible = Config.FeatureOn("WeeklyChallenge")

	fillBoard = function(data: any)
		MetaUI.Clear(ui.Body)
		local explain = selected == "Weekly" and "Best weekly challenge score of each player this week."
			or ("Best " .. (selected == "TeamDuo" and "Duo" or "Trio") .. " run score of each team this week (the best member's score).")
		local note = MetaUI.Row(ui.Body, { Name = "Explain", Order = 0, Icon = "podium", Title = selected == "Weekly" and "WEEKLY BOARD" or (selected == "TeamDuo" and "DUO TEAMS" or "TRIO TEAMS"), Sub = explain, Height = 56 })
		note.SetDim(false)
		if type(data) ~= "table" then
			MetaUI.Row(ui.Body, { Name = "Loading", Order = 1, Title = "Loading...", Sub = "Asking the server", Height = 56 })
			return
		end
		local rows = type(data.Rows) == "table" and data.Rows or {}
		if data.Status == "local" then
			MetaUI.Row(ui.Body, { Name = "Local", Order = 1, Icon = "warning", Title = "THIS SERVER ONLY", Sub = "Global boards are unavailable here (Studio without API access)", Height = 56 })
		elseif data.Status == "error" then
			MetaUI.Row(ui.Body, { Name = "Error", Order = 1, Icon = "warning", Title = "BOARD UNAVAILABLE", Sub = "Could not read the board. Try again later.", Height = 56 })
		end
		if #rows == 0 then
			MetaUI.Row(ui.Body, { Name = "Empty", Order = 2, Title = "NO SCORES YET", Sub = "Be the first this week!", Height = 56 })
		end
		for i, r in ipairs(rows) do
			if i > 50 then
				break
			end
			local row = MetaUI.Row(ui.Body, {
				Name = "Rank" .. i,
				Order = 10 + i,
				Title = string.format("#%d  %s", tonumber(r.Rank) or i, tostring(r.Name or "?")),
				Sub = UIKit.formatNumber(tonumber(r.Value) or 0) .. " points",
				Height = 52,
			})
			row.SetDone(r.Me == true)
			if r.Me then
				row.Title.TextColor3 = C.BlueDeep
			end
		end
	end
	Remotes.Get("LeaderboardData").OnClientEvent:Connect(function(data)
		if type(data) ~= "table" or (data.Board ~= "Weekly" and data.Board ~= "TeamDuo" and data.Board ~= "TeamTrio") then
			return
		end
		lastData[data.Board] = data
		if data.Board == selected and screen.Visible then
			fillBoard(data)
		end
	end)

	local function fillHead()
		local setup = MenuWeekly.Setup()
		local hero = CharacterData.Characters[setup.Hero]
		MetaUI.Clear(heroWell)
		Icons.Character(heroWell, setup.Hero, { Size = 46, AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.5), Back = C.PanelInset })
		local arena = (Config.Arenas :: any)[setup.Arena]
		line1.Text = string.format("HERO · %s   WORLD · %s", string.upper(hero and hero.Name or setup.Hero), string.upper(arena and arena.DisplayName or setup.Arena))
		local names = {}
		for _, id in ipairs(setup.Curses) do
			table.insert(names, CurseData.Curses[id].Name)
		end
		line2.Text = "Curses: " .. table.concat(names, ", ") .. " · " .. CurseData.GoldText(CurseData.GoldMult(setup.Curses)) .. " gold"
		local best, ever = MenuWeekly.Best(ctx.Profile())
		line3.Text = string.format("This week %s · best ever %s · resets in %s", best > 0 and UIKit.formatNumber(best) or "-", ever > 0 and UIKit.formatNumber(ever) or "-", MetaData.TimeText(MetaData.WeekSecondsLeft(MetaUI.Now())))
	end

	local function layout(v: Vector2, portrait: boolean, ins: { [string]: number })
		local lineH = TS(17) + 6
		local infoH = math.max(64, lineH * 3 + 4)
		local tabsH = #boards > 0 and Theme.Size.TapMin or 0
		local headH = infoH + 8 + tabsH
		ui.Layout(v, portrait, ins, headH, Config.FeatureOn("WeeklyChallenge") and 60 or 0)
		local w = ui.Head.Size.X.Offset
		MetaUI.place(heroWell, 0, (infoH - 64) / 2, 64, 64)
		MetaUI.place(line1, 76, 0, w - 76, lineH)
		MetaUI.place(line2, 76, lineH, w - 76, lineH)
		MetaUI.place(line3, 76, lineH * 2, w - 76, lineH)
		MetaUI.place(tabs.Frame, 0, infoH + 8, w, tabsH)
		tabs.Frame.Visible = #boards > 0
	end

	return {
		Layout = layout,
		Refresh = function(_p)
			if screen.Visible then
				fillHead()
			end
		end,
		OnShow = function(_p, arg)
			if type(arg) == "string" then
				for _, b in ipairs(boards) do
					if b.Id == arg then
						selected = arg
						tabs.Select(arg)
					end
				end
			end
			fillHead()
			fillBoard(lastData[selected])
			if #boards > 0 then
				Remotes.Get("LeaderboardRequest"):FireServer(selected)
			end
			layout(host.VirtualSize(), host.IsPortrait(), host.Insets())
			UIAnim.Pop(ui.Panel, 0, 0.96)
		end,
	}
end

return MenuWeekly
