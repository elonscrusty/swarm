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
local ArtImage = require(script.Parent.ArtImage)
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
local MenuTitles = require(script.Parent.MenuTitles)
local MenuCollection = require(script.Parent.MenuCollection)

local MenuMore = {}

local new = UIKit.new
local P = Theme.Palette

local function place(obj: GuiObject, x: number, y: number, w: number, h: number)
	obj.Position = UDim2.fromOffset(math.floor(x + 0.5), math.floor(y + 0.5))
	obj.Size = UDim2.fromOffset(math.floor(w + 0.5), math.floor(h + 0.5))
end

function MenuMore.Build(screen: Frame, ctx: { [string]: any })
	local host = ctx.Host
	local ui: { [string]: any } = { Rows = {} }
	ui.Header = UIKit.ScreenHeader(screen, "MORE", ctx.Back)
	local holder, face = UIKit.Surface(screen, { Name = "Panel", Radius = Theme.Radius.L, Transparency = 0.06 })
	ui.Panel = holder
	local scroll = new("ScrollingFrame", {
		Name = "List",
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		Position = UDim2.fromOffset(12, 12),
		Size = UDim2.new(1, -24, 1, -24),
		ScrollBarThickness = 4,
		ScrollBarImageColor3 = P.gold_500,
		CanvasSize = UDim2.new(),
		ScrollingDirection = Enum.ScrollingDirection.Y,
	}, face)
	ui.Scroll = scroll

	local ITEMS = {
		-- a session notice, listed first while it lasts (player attribute SaveStatus; the home
		-- screen never shows it); a tap repeats it as a toast
		{ Id = "SaveStatus", Title = "PROGRESS NOT SAVED", Sub = "Saving isn't working right now", Icon = "warning", Notice = true, Go = function()
			if host.Toast then
				host.Toast("Progress isn't being saved right now. We'll keep trying.", P.crimson_300)
			end
		end },
		{ Id = "Daily", Title = "DAILY CHALLENGE", Sub = "One scored try a day", Icon = "calendar", Art = "Daily", Go = function() ctx.ShowScreen("Daily") end },
		{ Id = "Party", Title = "PARTY", Sub = "Play with friends", Icon = "lobby_Party", Go = function() ctx.ShowScreen("Party") end },
		{ Id = "Ranks", Title = "RANKS", Sub = "Leaderboards", Icon = "podium", Art = "Leaderboards", Go = function() ctx.ShowScreen("Ranks") end },
		{ Id = "Stats", Title = "STATS", Sub = "Your records", Icon = "bars", Go = function() ctx.ShowScreen("Stats", "Stats") end },
		{ Id = "Track", Title = "ACCOUNT LEVEL", Sub = "Rewards for every run", Icon = "medal", Art = "Track", Go = function() ctx.ShowScreen("Track") end },
		{ Id = "Journal", Title = "JOURNAL", Sub = "Enemies you have met", Icon = "skull", Go = function() ctx.ShowScreen("Journal") end },
		-- META (docs/features/META.md): each row shows only while its switch is on
		{ Id = "Streak", Title = "DAILY REWARD", Sub = "Log in each day", Icon = "gift", Feature = "LoginStreak", Go = function() ctx.ShowScreen("Streak") end },
		{ Id = "Weekly", Title = "WEEKLY CHALLENGE", Sub = "One hero, one week", Icon = "calendar", Feature = { "WeeklyChallenge", "TeamBoard" }, Go = function() ctx.ShowScreen("Weekly") end },
		{ Id = "Season", Title = "SEASON", Sub = "Free rewards track", Icon = "flag", Feature = "SeasonTrack", Go = function() ctx.ShowScreen("Season") end },
		{ Id = "Titles", Title = "TITLES", Sub = "Wear a title under your name", Icon = "medal", Feature = "Titles", Go = function() ctx.ShowScreen("Titles") end },
		{ Id = "Collection", Title = "COLLECTION", Sub = "Everything you have found", Icon = "chest", Feature = "CollectionBook", Go = function() ctx.ShowScreen("Collection") end },
		{ Id = "Achievements", Title = "ACHIEVEMENTS", Sub = "Goals, titles and colours", Icon = "trophy", Go = function() ctx.ShowScreen("Stats", "Achievements") end },
		-- LOBBY features (docs/features/LOBBY.md), listed only while their switch is on
		{ Id = "Courtyard", Title = "COURTYARD", Sub = "Dummy, mirror and jump pads", Icon = "castle", Feature = "LobbyFun", Go = function()
			require(script.Parent.LobbyFun).Enter()
		end },
		{ Id = "WeaponMastery", Title = "WEAPON MASTERY", Sub = "Glow colours from kills", Icon = "sword", Feature = "WeaponMastery", Go = function()
			require(script.Parent.WeaponMastery).Open()
		end },
		{ Id = "Settings", Title = "SETTINGS", Sub = "Sound, controls, display", Icon = "gear", Art = "Settings", Go = function()
			if host.OpenSettings then
				host.OpenSettings()
			end
		end },
		{ Id = "BugReport", Title = "REPORT A BUG", Sub = "Tell us what went wrong", Icon = "warning", Go = function() BugReportUI.Open() end },
		{ Id = "Dev", Title = "DEV", Sub = "Developer tools", Icon = "info", Dev = true, Go = function() DevPanel.Open() end },
	}
	for i, item in ipairs(ITEMS) do
		local b = UIKit.Button(scroll, {
			Kind = "Secondary",
			Title = item.Title,
			Subtitle = item.Sub,
			Icon = item.Icon,
			IconSize = 28,
			TitleStyle = "Label",
			TitleSize = 17,
			Chevron = true,
			Align = "Left",
			Shrink = true,
			Name = item.Id,
			LayoutOrder = i,
			OnClick = item.Go,
		})
		if item.Art then
			ArtImage.ButtonIcon(b.Content:FindFirstChild("IconHolder"), "icons/ui/ui_" .. item.Art, { Size = UDim2.fromScale(1.45, 1.45) })
		end
		ui.Rows[i] = { Item = item, Button = b }
		if item.Notice then
			ui.NoticeRow = b
			local st = b.Face:FindFirstChildOfClass("UIStroke")
			if st then
				st.Color = P.crimson_400
				st.Transparency = 0.1
			end
		end
		if item.Id == "Daily" or item.Id == "Party" or item.Id == "Achievements" or item.Id == "Track" then
			NoticeDots.Attach(item.Id, b.Instance, { Position = UDim2.new(1, -10, 0, 10) })
		end
		if item.Id == "Party" then
			ui.PartyRow = b
			ui.PartyBadge = UIKit.Badge(b.Instance, "", "Crimson", { Name = "InviteBadge", AnchorPoint = Vector2.new(1, 0), Position = UDim2.new(1, 4, 0, -4), ZIndex = 6, Visible = false })
		elseif item.Id == "Daily" then
			ui.DailyRow = b
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
			local on = (not r.Item.Dev or DevPanel.IsDev()) and (not r.Item.Notice or saveStatus() ~= "ok") and featureOn(r.Item.Feature) and (not r.Item.Feature or Config.FeatureOn(r.Item.Feature))
			r.Button.Instance.Visible = on
			if on then
				table.insert(list, r)
			end
		end
		return list
	end

	local function layout(v: Vector2, portrait: boolean, ins: { [string]: number })
		local W, H = v.X, v.Y
		local M = UIKit.IsCompact() and Theme.Layout.MarginCompact or Theme.Layout.Margin
		local G = Theme.Layout.Gutter
		local headY = math.max(ins.Top + 4, 12)
		place(ui.Header.Frame, M, headY, math.min(520, W - 2 * M), 56)
		local top = math.max(headY + 66 + (portrait and 58 or 0), portrait and 0 or 76)
		local w = math.min(W - 2 * M, 900)
		local inner = w - 24 - 8
		local cols = inner >= 600 and 2 or 1
		local cellW = math.floor((inner - (cols - 1) * G) / cols)
		local list = shownRows()
		local rows = math.ceil(#list / cols)
		-- rows shrink (never below a finger's size) so the whole list fits without scrolling
		local rowH = math.clamp(math.floor((H - top - M - 24 - (rows - 1) * G) / rows), 56, 68)
		local contentH = rows * rowH + (rows - 1) * G
		local h = math.min(contentH + 24, H - top - M)
		place(ui.Panel, (W - w) / 2, top, w, h)
		for i, r in ipairs(list) do
			local c = (i - 1) % cols
			local rr = math.floor((i - 1) / cols)
			place(r.Button.Instance, c * (cellW + G), rr * (rowH + G), cellW, rowH)
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
			Weekly = Config.FeatureOn("WeeklyChallenge") and MenuWeekly.Summary(p) or nil,
			Season = Config.FeatureOn("SeasonTrack") and MenuSeason.Summary(p) or nil,
			Titles = Config.FeatureOn("Titles") and MenuTitles.Summary(p) or nil,
			Collection = Config.FeatureOn("CollectionBook") and MenuCollection.Summary(p) or nil,
		}
		local metaKey = ""
		for _, id in ipairs({ "Streak", "Weekly", "Season", "Titles", "Collection" }) do
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
		if saveChanged then
			MenuMore._layout()
		end
		ui.PartyRow.SetText(nil, partySub)
		ui.PartyRow.SetSelected(party.Count > 0)
		ui.DailyRow.SetText(nil, dailySub)
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
