--[[
	MenuStreak.lua
	The DAILY REWARD screen (feature 25, Config.Features.LoginStreak): one claim per UTC
	day. Claiming on back-to-back days grows the streak (one missed day is forgiven,
	MetaData.StreakGrace); a longer gap starts again at day 1. Rewards are coins and
	cosmetics only (the 7-day gold cycle and the streak milestones). The server checks the
	day and pays once (MetaService, LoginStreak.LastDay).
]]

local Shared = game:GetService("ReplicatedStorage"):WaitForChild("Shared")
local Theme = require(Shared:WaitForChild("Theme"))
local MetaData = require(Shared:WaitForChild("MetaData"))
local CurseData = require(Shared:WaitForChild("CurseData"))
local UIKit = require(script.Parent.UIKit)
local UIAnim = require(script.Parent.UIAnim)
local MetaUI = require(script.Parent.MetaUI)

local MenuStreak = {}

local TS = UIKit.TS
local C = Theme.Color

-- (canClaimToday, streak after that claim, current streak, best) for this profile.
function MenuStreak.State(p: { [string]: any }?): (boolean, number, number, number)
	local s = MetaUI.Features(p).LoginStreak
	local last = type(s) == "table" and tonumber(s.LastDay) or 0
	local day = type(s) == "table" and tonumber(s.Day) or 0
	local best = type(s) == "table" and tonumber(s.Best) or 0
	local today = CurseData.DayOf(MetaUI.Now())
	local can, nextDay = MetaData.StreakNext(last :: number, day :: number, today)
	-- a streak that can no longer continue reads as 0 until the next claim
	local current = (can and nextDay == 1) and 0 or day
	return can, nextDay, current :: number, best :: number
end

function MenuStreak.Summary(p: { [string]: any }?): string
	local can, nextDay, current = MenuStreak.State(p)
	if can then
		return string.format("Claim day %d: +%d gold", nextDay, MetaData.StreakGold(nextDay))
	end
	return string.format("Day %d streak · next in %s", current, MetaData.TimeText(CurseData.SecondsLeft(MetaUI.Now())))
end

function MenuStreak.Build(screen: Frame, ctx: { [string]: any })
	local host = ctx.Host
	local ui = MetaUI.Screen(screen, ctx, "DAILY REWARD")
	local title = MetaUI.Line(ui.Head, "H3", "", 20, { Name = "StreakDays", TextColor3 = C.BlueDeep })
	local sub = MetaUI.Line(ui.Head, "Small", "", 14, { Name = "StreakRule" })
	UIKit.list(ui.Body, { Padding = UDim.new(0, 6) })
	local claim = UIKit.Button(ui.Foot, {
		Kind = "Primary",
		Glow = true,
		Title = "CLAIM",
		Icon = "gift",
		IconSize = 22,
		TitleStyle = "H2",
		Align = "Center",
		Name = "ClaimStreak",
		Size = UDim2.fromScale(1, 1),
		OnClick = function()
			MetaUI.Send("ClaimStreak")
		end,
	})

	local function fill()
		local p = ctx.Profile()
		local can, nextDay, current, best = MenuStreak.State(p)
		title.Text = string.format("DAY %d STREAK · BEST %d", current, best)
		sub.Text = can and "Claim once a day (UTC). Miss two days in a row and it starts again."
			or ("Claimed today. Next claim in " .. MetaData.TimeText(CurseData.SecondsLeft(MetaUI.Now())) .. ".")
		claim.SetEnabled(can)
		claim.SetText(can and string.format("CLAIM DAY %d · +%d GOLD", nextDay, MetaData.StreakGold(nextDay)) or "COME BACK TOMORROW")
		MetaUI.Clear(ui.Body)
		local order = 0
		local function section(str: string)
			order += 1
			local l = UIKit.SectionLabel(ui.Body, str)
			l.LayoutOrder = order
		end
		section("THE 7-DAY CYCLE")
		local n = #MetaData.StreakCycle
		local at = ((math.max(1, can and nextDay or current) - 1) % n) + 1
		for i, gold in ipairs(MetaData.StreakCycle) do
			order += 1
			local row = MetaUI.Row(ui.Body, {
				Name = "Day" .. i,
				Order = order,
				Icon = "lobby_Gold",
				Title = string.format("DAY %d · +%d GOLD", i, gold),
				Sub = (i == at and can) and "Today's reward" or (i < at or (i == at and not can)) and "This week: done" or "Coming up",
				Height = 52,
			})
			local isToday = i == at and can
			row.SetDone(i < at or (i == at and not can))
			row.SetDim(i > at)
			if isToday then
				row.SetDone(false)
			end
		end
		section("STREAK MILESTONES")
		for _, m in ipairs(MetaData.StreakMilestones) do
			order += 1
			local name
			if m.Kind == "Title" then
				local def = MetaData.TitleById[m.Id]
				name = "TITLE · " .. string.upper(def and def.Name or m.Id)
			else
				local def = MetaData.NameplateById[m.Id]
				name = "NAMEPLATE · " .. string.upper(def and def.Name or m.Id)
			end
			local done = best >= m.Day
			local row = MetaUI.Row(ui.Body, {
				Name = "Milestone" .. m.Day,
				Order = order,
				Icon = m.Kind == "Title" and "medal" or "crown",
				Title = string.format("%d DAYS · %s", m.Day, name),
				Sub = done and "Earned" or string.format("%d more day%s", m.Day - current, m.Day - current == 1 and "" or "s"),
				Height = 56,
			})
			row.SetDone(done)
		end
	end

	local function layout(v: Vector2, portrait: boolean, ins: { [string]: number })
		local h1, h2 = TS(20) + 6, TS(14) + 6
		ui.Layout(v, portrait, ins, h1 + h2, 60)
		local w = ui.Head.Size.X.Offset
		MetaUI.place(title, 0, 0, w, h1)
		MetaUI.place(sub, 0, h1, w, h2)
	end

	return {
		Layout = layout,
		Refresh = function(_p)
			if screen.Visible then
				fill()
			end
		end,
		OnShow = function(_p)
			fill()
			layout(host.VirtualSize(), host.IsPortrait(), host.Insets())
			UIAnim.Pop(ui.Panel, 0, 0.96)
		end,
	}
end

return MenuStreak
