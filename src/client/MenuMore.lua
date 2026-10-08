--[[
	MenuMore.lua
	The MORE screen (home screen's MORE tile): one clean list of everything that is not
	PLAY, HEROES or SHOP, so the home screen stays simple:

	  DAILY CHALLENGE  (MenuDaily)          PARTY (MenuParty: size, ready, invite badge)
	  RANKS (MenuLeaderboards)              STATS (MenuStats)
	  ACCOUNT LEVEL (MenuTrack)             JOURNAL (MenuJournal)
	  ACHIEVEMENTS (MenuStats' tab)         SETTINGS (UIBuilder's modal)
	  REPORT A BUG (BugReportUI)            DEV (DevPanel; only when DevPanel.IsDev: the
	                                        server checks every DEV command again)
	  COURTYARD (LobbyFun) and WEAPON MASTERY (WeaponMastery): only while their
	  Config.Features switch is on (docs/features/LOBBY.md)
]]

local Shared = game:GetService("ReplicatedStorage"):WaitForChild("Shared")
local Theme = require(Shared:WaitForChild("Theme"))
local UIKit = require(script.Parent.UIKit)
local UIAnim = require(script.Parent.UIAnim)
local MenuParty = require(script.Parent.MenuParty)
local MenuDaily = require(script.Parent.MenuDaily)
local CurseData = require(Shared:WaitForChild("CurseData"))
local DevPanel = require(script.Parent.DevPanel)
local BugReportUI = require(script.Parent.BugReportUI)
local NoticeDots = require(script.Parent.NoticeDots)
local Config = require(Shared:WaitForChild("Config"))
local MenuWeekly = require(script.Parent.MenuWeekly)
local MenuSeason = require(script.Parent.MenuSeason)
local MenuStreak = require(script.Parent.MenuStreak)
local MenuQuests = require(script.Parent.MenuQuests)
local MenuComeback = require(script.Parent.MenuComeback)
local MenuTitles = require(script.Parent.MenuTitles)
local MenuCollection = require(script.Parent.MenuCollection)
local MenuInvite = require(script.Parent.MenuInvite)
local MenuGroup = require(script.Parent.MenuGroup)

local MenuMore = {}

local new = UIKit.new
local C = Theme.Color

local function place(obj: GuiObject, x: number, y: number, w: number, h: number)
	obj.Position = UDim2.fromOffset(math.floor(x + 0.5), math.floor(y + 0.5))
	obj.Size = UDim2.fromOffset(math.floor(w + 0.5), math.floor(h + 0.5))
end

function MenuMore.Build(screen: Frame, ctx: { [string]: any })
	local host = ctx.Host
	local ui: { [string]: any } = { Rows = {} }
	local holder, face = UIKit.Surface(screen, { Name = "Panel", Radius = Theme.Radius.L, Transparency = 0, EdgeThickness = Theme.Stroke.Medium, Depth = 4 })
	ui.Panel = holder
	-- BACK and the title (on its blue plate) stay in the panel's header; only the list scrolls
	ui.Header = UIKit.ScreenHeader(face, "MORE", ctx.Back, true)
	local scroll = new("ScrollingFrame", {
		Name = "List",
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		Position = UDim2.fromOffset(12, 12),
		Size = UDim2.new(1, -24, 1, -24),
		ScrollBarThickness = 4,
		ScrollBarImageColor3 = C.Blue,
		CanvasSize = UDim2.new(),
		ScrollingDirection = Enum.ScrollingDirection.Y,
	}, face)
	ui.Scroll = scroll

	local ITEMS = {
		-- a session notice, listed first while it lasts (player attribute SaveStatus; the home
		-- screen never shows it); a tap repeats it as a toast
		{ Id = "SaveStatus", Title = "PROGRESS NOT SAVED", Sub = "Saving isn't working right now", Icon = "warning", Tint = "Red", Notice = true, Go = function()
			if host.Toast then
				host.Toast("Progress isn't being saved right now. We'll keep trying.", C.Danger)
			end
		end },
		{ Id = "Daily", Title = "DAILY CHALLENGE", Sub = "One scored try a day", Icon = "calendar", Tint = "Orange", Go = function() ctx.ShowScreen("Daily") end },
		{ Id = "Party", Title = "PARTY", Sub = "Play with friends", Icon = "people3", Tint = "Blue", Go = function() ctx.ShowScreen("Party") end },
		-- next batch (docs/next/): invite rewards and the Roblox group bonus (the group row only
		-- once the owner set Config.Group.Id)
		{ Id = "Invite", Title = "INVITE FRIENDS", Sub = "Rewards for bringing friends", Icon = "userPlus", Tint = "Teal", Feature = "InviteRewards", Go = function() ctx.ShowScreen("Invite") end },
		{ Id = "Group", Title = "JOIN OUR GROUP", Sub = "Bonus gold for members", Icon = "people2", Tint = "Navy", Feature = "GroupBonus", Shown = MenuGroup.Shown, Go = function() ctx.ShowScreen("Group") end },
		{ Id = "Ranks", Title = "RANKS", Sub = "Leaderboards", Icon = "podium", Tint = "Gold", Go = function() ctx.ShowScreen("Ranks") end },
		{ Id = "Stats", Title = "STATS", Sub = "Your records", Icon = "bars", Tint = "Blue", Go = function() ctx.ShowScreen("Stats", "Stats") end },
		{ Id = "Track", Title = "ACCOUNT LEVEL", Sub = "Rewards for every run", Icon = "medal", Tint = "Green", Go = function() ctx.ShowScreen("Track") end },
		{ Id = "Journal", Title = "JOURNAL", Sub = "Enemies you have met", Icon = "skull", Tint = "Navy", Go = function() ctx.ShowScreen("Journal") end },
		-- META (docs/features/META.md): each row shows only while its switch is on
		-- the comeback gift: listed only while one waits, just before DAILY REWARD
		{ Id = "Comeback", Title = "WELCOME BACK", Sub = "A gift is waiting", Icon = "gift", Tint = "Orange", Feature = "ComebackGift", Shown = function()
			return MenuComeback.Pending(ctx.Profile()) ~= nil
		end, Go = function() ctx.ShowScreen("Comeback") end },
		{ Id = "Quests", Title = "DAILY QUESTS", Sub = "Three quests a day", Icon = "flag", Tint = "Green", Feature = "DailyQuests", Go = function() ctx.ShowScreen("Quests") end },
		{ Id = "Streak", Title = "DAILY REWARD", Sub = "Log in each day", Icon = "gift", Tint = "Red", Feature = "LoginStreak", Go = function() ctx.ShowScreen("Streak") end },
		{ Id = "Weekly", Title = "WEEKLY CHALLENGE", Sub = "One hero, one week", Icon = "calendar", Tint = "Navy", Feature = { "WeeklyChallenge", "TeamBoard" }, Go = function() ctx.ShowScreen("Weekly") end },
		{ Id = "Season", Title = "SEASON", Sub = "Free rewards track", Icon = "flag", Tint = "Blue", Feature = "SeasonTrack", Go = function() ctx.ShowScreen("Season") end },
		{ Id = "Titles", Title = "TITLES", Sub = "Wear a title under your name", Icon = "medal", Tint = "Purple", Feature = "Titles", Go = function() ctx.ShowScreen("Titles") end },
		{ Id = "Collection", Title = "COLLECTION", Sub = "Everything you have found", Icon = "chest", Tint = "Gold", Feature = "CollectionBook", Go = function() ctx.ShowScreen("Collection") end },
		{ Id = "Achievements", Title = "ACHIEVEMENTS", Sub = "Goals, titles and colours", Icon = "trophy", Tint = "Orange", Go = function() ctx.ShowScreen("Stats", "Achievements") end },
		-- LOBBY features (docs/features/LOBBY.md), listed only while their switch is on
		{ Id = "Courtyard", Title = "COURTYARD", Sub = "Dummy, mirror and jump pads", Icon = "castle", Tint = "Green", Feature = "LobbyFun", Go = function()
			require(script.Parent.LobbyFun).Enter()
		end },
		{ Id = "WeaponMastery", Title = "WEAPON MASTERY", Sub = "Glow colours from kills", Icon = "sword", Tint = "Red", Feature = "WeaponMastery", Go = function()
			require(script.Parent.WeaponMastery).Open()
		end },
		{ Id = "Settings", Title = "SETTINGS", Sub = "Sound, controls, display", Icon = "gear", Tint = "Navy", Go = function()
			if host.OpenSettings then
				host.OpenSettings()
			end
		end },
		{ Id = "BugReport", Title = "REPORT A BUG", Sub = "Tell us what went wrong", Icon = "warning", Tint = "Orange", Go = function() BugReportUI.Open() end },
		{ Id = "Dev", Title = "DEV", Sub = "Developer tools", Icon = "info", Tint = "Navy", Dev = true, Go = function() DevPanel.Open() end },
	}
	for i, item in ipairs(ITEMS) do
		-- one navigation card per row: icon badge, title, live subtitle, chevron
		local b = UIKit.NavCard(scroll, {
			Name = item.Id,
			Title = item.Title,
			Subtitle = item.Sub,
			Icon = item.Icon,
			Tint = (Theme.IconTint :: any)[item.Tint] or Theme.IconTint.Blue,
			LayoutOrder = i,
			OnClick = item.Go,
		})
		ui.Rows[i] = { Item = item, Button = b }
		if item.Notice then
			-- the save warning (red warning badge; the title says it, not only the colour)
			ui.NoticeRow = b
		end
		if item.Id == "Daily" or item.Id == "Party" or item.Id == "Achievements" or item.Id == "Track" or item.Id == "Quests" then
			NoticeDots.Attach(item.Id, b.Instance, { Position = UDim2.new(1, -10, 0, 10) })
		end
		if item.Id == "Party" then
			ui.PartyRow = b
			ui.PartyBadge = UIKit.Badge(b.Instance, "", "Crimson", { Name = "InviteBadge", AnchorPoint = Vector2.new(1, 0), Position = UDim2.new(1, 4, 0, -4), ZIndex = 6, Visible = false })
		elseif item.Id == "Daily" then
			ui.DailyRow = b
		elseif item.Id == "Streak" then
			ui.StreakRow = b
		end
	end

	local function saveStatus(): string
		local st = tostring(game:GetService("Players").LocalPlayer:GetAttribute("SaveStatus") or "ok")
		return (st == "failing" or st == "memory") and st or "ok"
	end

	-- a META row's switch (a name, or a list: on when any of them is on)
	local function featureOn(f: any): boolean
		if f == nil then
			return true
		elseif type(f) == "table" then
			for _, name in ipairs(f) do
				if Config.FeatureOn(name) then
					return true
				end
			end
			return false
		end
		return Config.FeatureOn(f)
	end

	local function shownRows(): { any }
		local list = {}
		for _, r in ipairs(ui.Rows) do
			local on = (not r.Item.Dev or DevPanel.IsDev()) and (not r.Item.Notice or saveStatus() ~= "ok") and featureOn(r.Item.Feature) and (not r.Item.Feature or Config.FeatureOn(r.Item.Feature)) and (not r.Item.Shown or r.Item.Shown())
			r.Button.Instance.Visible = on
			if on then
				table.insert(list, r)
			end
		end
		return list
	end

	-- The scroll body clips: cards keep INSET px clear on the sides / top and BASE px below,
	-- so their outlines and raised bases are never cut.
	local INSET, BASE = 4, 6
	local function layout(v: Vector2, portrait: boolean, ins: { [string]: number })
		local W, H = v.X, v.Y
		local compact = UIKit.IsCompact()
		local M = compact and Theme.Layout.MarginCompact or Theme.Layout.Margin
		local G = 10
		local headY = math.max(ins.Top + 4, 12)
		local short = not portrait and (H < 520 or (compact and H < 640))
		local top = headY + (portrait and 130 or (short and 6 or 46))
		local pad = short and 10 or (compact and 12 or 18)
		local headH = short and 50 or 52
		local w = math.min(W - 2 * M, 900)
		local sw = w - 2 * pad + 6 -- the scroll frame (room for its bar on the right)
		local inner = sw - 6 - 2 * INSET
		local cols = inner >= 600 and 2 or 1
		local cellW = math.floor((inner - (cols - 1) * G) / cols)
		local list = shownRows()
		local rows = math.ceil(#list / cols)
		local bodyTop = pad + headH + 8
		local availH = H - top - M
		-- rows shrink (never below a finger's size) so the whole list fits without scrolling
		local rowH = math.clamp(math.floor((availH - bodyTop - pad - INSET - BASE - (rows - 1) * G) / rows), 60, 70)
		local contentH = INSET + rows * rowH + (rows - 1) * G + BASE
		local h = math.min(bodyTop + contentH + pad, availH)
		place(ui.Panel, (W - w) / 2, top, w, h)
		place(ui.Header.Frame, pad, pad, w - 2 * pad, headH)
		place(scroll, pad, bodyTop, sw, h - bodyTop - pad)
		for i, r in ipairs(list) do
			local c = (i - 1) % cols
			local rr = math.floor((i - 1) / cols)
			place(r.Button.Instance, INSET + c * (cellW + G), INSET + rr * (rowH + G), cellW, rowH)
		end
		scroll.CanvasSize = UDim2.fromOffset(0, contentH)
	end
	MenuMore._layout = function()
		layout(host.VirtualSize(), host.IsPortrait(), host.Insets())
	end

	-- the live subtitles: the party's size / invites, the daily's state
	local lastKey = ""
	local lastSave: string? = nil
	MenuMore._update = function(p: { [string]: any }?)
		local party = MenuParty.Summary()
		local partySub = "Play with friends"
		if party.Count > 0 then
			partySub = party.Others > 0 and string.format("%d/%d · %d/%d ready", party.Count, party.Max, party.Ready, party.Others) or string.format("%d/%d · %s", party.Count, party.Max, party.Leader and "Leader" or "Member")
		end
		local used, score = MenuDaily.Status(p)
		local dailySub = used and ("Done · " .. (score > 0 and CurseData.ScoreText(score) or "practice open")) or ("Ready · " .. MenuDaily.TimeLeft() .. " left")
		local badge = party.Invites > 0 and tostring(party.Invites) or ""
		local save = saveStatus()
		-- META rows' live lines
		local metaSubs = {
			Streak = Config.FeatureOn("LoginStreak") and MenuStreak.Summary(p) or nil,
			Quests = Config.FeatureOn("DailyQuests") and MenuQuests.Summary(p) or nil,
			Comeback = Config.FeatureOn("ComebackGift") and MenuComeback.Summary(p) or nil,
			Weekly = Config.FeatureOn("WeeklyChallenge") and MenuWeekly.Summary(p) or nil,
			Season = Config.FeatureOn("SeasonTrack") and MenuSeason.Summary(p) or nil,
			Titles = Config.FeatureOn("Titles") and MenuTitles.Summary(p) or nil,
			Collection = Config.FeatureOn("CollectionBook") and MenuCollection.Summary(p) or nil,
			Invite = Config.FeatureOn("InviteRewards") and MenuInvite.Summary() or nil,
			Group = MenuGroup.Shown() and MenuGroup.Summary() or nil,
		}
		local metaKey = ""
		for _, id in ipairs({ "Streak", "Quests", "Comeback", "Weekly", "Season", "Titles", "Collection", "Invite", "Group" }) do
			metaKey ..= "|" .. tostring(metaSubs[id])
		end
		local key = partySub .. "|" .. dailySub .. "|" .. badge .. "|" .. save .. metaKey
		if key == lastKey then
			return
		end
		local saveChanged = lastSave ~= nil and lastSave ~= save
		lastSave = save
		lastKey = key
		ui.NoticeRow.SetText(nil, save == "memory" and "Not saved in this session" or "Saving isn't working right now")
		-- the WELCOME BACK row comes and goes with the gift
		local gift = Config.FeatureOn("ComebackGift") and MenuComeback.Pending(p) ~= nil
		if saveChanged or gift ~= ui.GiftShown then
			ui.GiftShown = gift
			MenuMore._layout()
		end
		ui.PartyRow.SetText(nil, partySub)
		ui.DailyRow.SetText(nil, dailySub)
		-- a claimable DAILY REWARD is the one yellow card (real claim state, MenuStreak.State)
		if ui.StreakRow then
			local canClaim = Config.FeatureOn("LoginStreak") and (MenuStreak.State(p))
			ui.StreakRow.SetKind(canClaim and "Primary" or "Secondary")
		end
		for _, r in ipairs(ui.Rows) do
			local line = metaSubs[r.Item.Id]
			if line then
				r.Button.SetText(nil, line)
			end
		end
		ui.PartyBadge.Text = badge
		ui.PartyBadge.Visible = badge ~= ""
	end

	return {
		Layout = layout,
		OnShow = function(p)
			MenuMore._update(p)
			MenuMore._layout()
			for i, r in ipairs(ui.Rows) do
				if r.Button.Instance.Visible then
					UIAnim.Pop(r.Button.Instance, math.min(0.02 * i, 0.2), 0.85)
				end
			end
		end,
		Update = function(_dt: number)
			if screen.Visible then
				MenuMore._update(ctx.Profile())
			end
		end,
	}
end

MenuMore._update = function(_p: { [string]: any }?) end
MenuMore._layout = function() end

return MenuMore
