--[[
	DevInbox.lua
	The DEV bug inbox: player reports, newest first, a page at a time, each with its status
	(New / Seen / Fixed / Won't fix) that a dev can change.

	Opened from the DEV panel ("Bug inbox"), or, for allowlisted players in live servers
	where the DEV panel is hidden, from a small BUGS button that shows when the server sets
	the player attribute "BugInbox". Showing the button is not security: the server
	(BugReportService) checks every request against its own allowlist and dev rule.

	Report text arrives already filtered by the server and is shown as plain text (no rich
	text). Remotes: BugInbox ("Page", cursor?) | ("SetStatus", id, status) → BugInboxData.
	BugReportPlus (Config.Features): pages hold the latest 20 reports, each with its
	automatic snapshot (BugSnapshotData.Lines), cleaned again by the server.
]]

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")

local Shared = game:GetService("ReplicatedStorage"):WaitForChild("Shared")
local Remotes = require(Shared:WaitForChild("Remotes"))
local Theme = require(Shared:WaitForChild("Theme"))
local B = require(Shared:WaitForChild("BugReportData"))
local SnapshotData = require(Shared:WaitForChild("BugSnapshotData"))
local UIKit = require(script.Parent.UIKit)

local DevInbox = {}

local player = Players.LocalPlayer
local new, text, TS = UIKit.new, UIKit.text, UIKit.TS
local C, P = Theme.Color, Theme.Palette

local host: { [string]: any } = {}
local ui: { [string]: any } = {}
local claimed = false -- the DEV panel provides the entry button
local cursors: { any } = { false } -- cursors[page] (false = first page)
local page = 1
local nextCursor: any = nil
local loading = false
local rowsById: { [string]: { [string]: any } } = {}

local STATUS_BADGE = { New = "Gold", Seen = "Slate", Fixed = "Moss", WontFix = "Dark" }

-- Called by the DEV panel: it shows its own "Bug inbox" button.
function DevInbox.ClaimButton()
	claimed = true
end

local function request(cursor: any)
	if loading then
		return
	end
	loading = true
	ui.Info.Text = "Loading..."
	ui.Prev.SetEnabled(false)
	ui.Next.SetEnabled(false)
	Remotes.Get("BugInbox"):FireServer("Page", cursor or nil)
	local token = (ui.Token or 0) + 1
	ui.Token = token
	task.delay(15, function()
		if loading and ui.Token == token then
			loading = false
			ui.Info.Text = "No answer from the server."
			ui.Prev.SetEnabled(page > 1)
		end
	end)
end

local function formatTime(t: any): string
	if type(t) ~= "number" then
		return "?"
	end
	local ok, s = pcall(function()
		return DateTime.fromUnixTimestamp(t):FormatLocalTime("YYYY-MM-DD HH:mm", "en-us")
	end)
	return ok and tostring(s) or "?"
end

local function paintStatus(row: { [string]: any })
	for id, b in pairs(row.Buttons) do
		b.SetKind(id == row.Status and "Primary" or "Ghost")
	end
	row.Badge.Text = string.upper(B.StatusTitles[row.Status] or row.Status)
	local kind = STATUS_BADGE[row.Status] or "Dark"
	-- Badge colours are set on creation; rebuild the look by kind
	local bg = { Gold = P.gold_400, Slate = P.slate_600, Moss = P.moss_600, Dark = C.PanelInset }
	local fg = { Gold = P.gold_900, Slate = P.ivory_100, Moss = P.ivory_100, Dark = C.Text }
	row.Badge.BackgroundColor3 = bg[kind]
	row.Badge.TextColor3 = fg[kind]
end

local function buildRow(r: { [string]: any }, order: number)
	local card, face = UIKit.Surface(ui.List, {
		Name = "Report_" .. tostring(r.Id),
		Size = UDim2.new(1, -8, 0, 0),
		LayoutOrder = order,
		Shadow = false,
		Transparency = 0.15,
	})
	card.AutomaticSize = Enum.AutomaticSize.Y
	face.AutomaticSize = Enum.AutomaticSize.Y
	face.Size = UDim2.fromScale(1, 0)
	UIKit.pad(face, 10)
	UIKit.list(face, { Padding = UDim.new(0, 6) })

	if r.Missing then
		text(face, "Small", "Report " .. tostring(r.Id) .. " could not be read.", { LayoutOrder = 1, TextColor3 = C.TextDanger })
		return
	end

	local head = new("Frame", { Name = "Head", BackgroundTransparency = 1, LayoutOrder = 1, Size = UDim2.new(1, 0, 0, Theme.Size.Badge + 4) }, face)
	UIKit.list(head, { FillDirection = Enum.FillDirection.Horizontal, VerticalAlignment = Enum.VerticalAlignment.Center, Padding = UDim.new(0, 8) })
	local row = { Id = r.Id, Status = r.Status, Buttons = {} :: { [string]: any } }
	row.Badge = UIKit.Badge(head, "", "Gold", { LayoutOrder = 1 })
	UIKit.Badge(head, string.upper(tostring(r.Category or "?")), "Slate", { LayoutOrder = 2 })
	text(head, "Label", string.format("%s  ·  %s", tostring(r.Name or "?"), formatTime(r.Time)), {
		LayoutOrder = 3,
		Size = UDim2.fromOffset(0, Theme.Size.Badge + 4),
		AutomaticSize = Enum.AutomaticSize.X,
		TextColor3 = C.TextMuted,
	})

	text(face, "BodyStrong", tostring(r.Text or ""), {
		LayoutOrder = 2,
		RichText = false,
		TextWrapped = true,
		Size = UDim2.new(1, 0, 0, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		TextYAlignment = Enum.TextYAlignment.Top,
	})
	local extra = {}
	if type(r.Mode) == "string" then
		table.insert(extra, r.Mode)
	end
	if type(r.RunTime) == "number" and r.RunTime > 0 then
		table.insert(extra, UIKit.formatTime(r.RunTime))
	end
	if type(r.PlaceVersion) == "number" then
		table.insert(extra, "place v" .. r.PlaceVersion)
	end
	local serverLine = tostring(r.Context or "")
	if #extra > 0 then
		serverLine ..= (serverLine ~= "" and " · " or "") .. table.concat(extra, " · ")
	end
	text(face, "Small", "Server: " .. serverLine, { LayoutOrder = 3, TextWrapped = true, Size = UDim2.new(1, 0, 0, 0), AutomaticSize = Enum.AutomaticSize.Y })
	if type(r.ClientLine) == "string" and r.ClientLine ~= "" then
		text(face, "Small", "Client says: " .. r.ClientLine, { LayoutOrder = 4, TextWrapped = true, TextColor3 = C.TextFaint, Size = UDim2.new(1, 0, 0, 0), AutomaticSize = Enum.AutomaticSize.Y })
	end

	-- BugReportPlus: the automatic snapshot (ids, enums, numbers; log lines filtered by the server)
	if SnapshotData.On() and type(r.Snapshot) == "table" then
		local box = new("Frame", {
			Name = "Snapshot",
			LayoutOrder = 5,
			BackgroundColor3 = C.PanelInset,
			BackgroundTransparency = 0.3,
			BorderSizePixel = 0,
			Size = UDim2.new(1, 0, 0, 0),
			AutomaticSize = Enum.AutomaticSize.Y,
		}, face)
		UIKit.corner(box, Theme.Radius.S)
		UIKit.pad(box, 6)
		UIKit.list(box, { Padding = UDim.new(0, 2) })
		for i, line in ipairs(SnapshotData.Lines(r.Snapshot, r.ServerBuild)) do
			local isLog = string.sub(line, 1, 1) == "[" or string.sub(line, 1, 4) == "Log:"
			text(box, "Small", line, {
				Name = "Line" .. i,
				LayoutOrder = i,
				RichText = false,
				TextWrapped = true,
				TextColor3 = isLog and C.TextFaint or C.TextMuted,
				Size = UDim2.new(1, 0, 0, 0),
				AutomaticSize = Enum.AutomaticSize.Y,
			})
		end
	end

	local buttons = new("Frame", { Name = "Status", BackgroundTransparency = 1, LayoutOrder = 6, Size = UDim2.new(1, 0, 0, 44) }, face)
	new("UIListLayout", {
		FillDirection = Enum.FillDirection.Horizontal,
		Padding = UDim.new(0, 6),
		SortOrder = Enum.SortOrder.LayoutOrder,
		HorizontalFlex = Enum.UIFlexAlignment.Fill,
	}, buttons)
	for i, s in ipairs(B.Statuses) do
		row.Buttons[s] = UIKit.Button(buttons, {
			Kind = "Ghost",
			Title = string.upper(B.StatusTitles[s]),
			Size = UDim2.new(0.25, -6, 1, 0),
			LayoutOrder = i,
			Shadow = false,
			Radius = Theme.Radius.S,
			Align = "Center",
			OnClick = function()
				if row.Status ~= s then
					Remotes.Get("BugInbox"):FireServer("SetStatus", row.Id, s)
				end
			end,
		})
	end
	rowsById[r.Id] = row
	paintStatus(row)
end

local function onData(data: any)
	if type(data) ~= "table" or not ui.Overlay then
		return
	end
	if data.Kind == "Status" then
		local row = rowsById[data.Id]
		if row and data.Ok and B.IsStatus(data.Status) then
			row.Status = data.Status
			paintStatus(row)
		elseif not data.Ok and host.Toast then
			host.Toast("Status could not be saved.", C.Danger)
		end
		return
	end
	if data.Kind ~= "Page" then
		return
	end
	loading = false
	for _, ch in ipairs(ui.List:GetChildren()) do
		if ch:IsA("GuiObject") then
			ch:Destroy()
		end
	end
	rowsById = {}
	local rows = type(data.Rows) == "table" and data.Rows or {}
	for i, r in ipairs(rows) do
		if type(r) == "table" and B.IsReportId(r.Id) then
			buildRow(r, i)
		end
	end
	nextCursor = data.Next
	local where = RunService:IsStudio() and "Studio store" or "live store"
	if data.Status ~= "ok" then
		ui.Info.Text = tostring(data.Message or "Could not load reports.")
	elseif #rows == 0 then
		ui.Info.Text = page == 1 and ("No reports yet · " .. where) or ("No more reports · " .. where)
	else
		ui.Info.Text = string.format("Page %d · %d report%s · %s", page, #rows, #rows == 1 and "" or "s", where)
	end
	ui.Prev.SetEnabled(page > 1)
	ui.Next.SetEnabled(nextCursor ~= nil)
	ui.List.CanvasPosition = Vector2.zero
end

function DevInbox.Open()
	if not ui.Overlay then
		return
	end
	host.Show(ui.Overlay, "DevInbox", true)
	cursors = { false }
	page = 1
	request(nil)
end

function DevInbox.Close()
	if ui.Overlay then
		host.Hide(ui.Overlay, "DevInbox")
	end
end

-- Standalone BUGS button (live servers without the DEV panel).
local function buildToggle(root: Instance)
	if claimed or ui.Toggle then
		return
	end
	local t = UIKit.Button(root, {
		Kind = "Secondary",
		Title = "BUGS",
		Name = "BugInboxButton",
		Size = UDim2.fromOffset(88, 48),
		ZIndex = Theme.Z.Dev,
		Align = "Center",
		OnClick = DevInbox.Open,
	})
	ui.Toggle = t.Instance
	host.Layout()
end

--[[
	h: Show, Hide, OnRelayout, VirtualSize, IsPortrait, Toast (UIBuilder's host API)
]]
function DevInbox.Init(root: Instance, h: { [string]: any })
	host = h
	local m = UIKit.Modal(root, "DevInbox", 860, 600, Theme.Z.Dev + 2)
	ui.Overlay = m.Overlay
	local content = m.Content
	UIKit.list(content, { Padding = UDim.new(0, 8) })

	text(content, "H1", "BUG INBOX", { LayoutOrder = 1, TextColor3 = P.crimson_300 })
	ui.Info = text(content, "Small", "", { LayoutOrder = 2, TextTruncate = Enum.TextTruncate.AtEnd, Size = UDim2.new(1, -48, 0, TS(14) + 6) })
	local list = new("ScrollingFrame", {
		Name = "Reports",
		LayoutOrder = 3,
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		Size = UDim2.new(1, 0, 0, 300),
		CanvasSize = UDim2.new(),
		AutomaticCanvasSize = Enum.AutomaticSize.Y,
		ScrollBarThickness = 4,
		ScrollBarImageColor3 = P.gold_400,
		ScrollingDirection = Enum.ScrollingDirection.Y,
	}, content)
	UIKit.list(list, { Padding = UDim.new(0, 8) })
	ui.List = list

	local row = new("Frame", { Name = "Paging", BackgroundTransparency = 1, LayoutOrder = 4, Size = UDim2.new(1, 0, 0, Theme.Size.TapMin) }, content)
	UIKit.list(row, { FillDirection = Enum.FillDirection.Horizontal, HorizontalAlignment = Enum.HorizontalAlignment.Center, VerticalAlignment = Enum.VerticalAlignment.Center, Padding = UDim.new(0, 10) })
	ui.Prev = UIKit.Button(row, {
		Kind = "Secondary",
		Title = "PREV",
		Icon = "chevronLeft",
		IconSize = 18,
		Align = "Center",
		Size = UDim2.fromOffset(140, Theme.Size.TapMin),
		LayoutOrder = 1,
		OnClick = function()
			if page > 1 and not loading then
				page -= 1
				request(cursors[page])
			end
		end,
	})
	ui.Refresh = UIKit.Button(row, {
		Kind = "Outline",
		Title = "REFRESH",
		Icon = "cycle",
		IconSize = 18,
		Align = "Center",
		Size = UDim2.fromOffset(160, Theme.Size.TapMin),
		LayoutOrder = 2,
		OnClick = function()
			if not loading then
				request(cursors[page])
			end
		end,
	})
	ui.Next = UIKit.Button(row, {
		Kind = "Secondary",
		Title = "NEXT",
		IconRight = "chevronRight",
		IconSize = 18,
		Align = "Center",
		Size = UDim2.fromOffset(140, Theme.Size.TapMin),
		LayoutOrder = 3,
		OnClick = function()
			if nextCursor ~= nil and not loading then
				page += 1
				cursors[page] = nextCursor
				request(nextCursor)
			end
		end,
	})
	UIKit.IconButton(m.Face, {
		Icon = "close",
		Size = 40,
		Kind = "Ghost",
		AnchorPoint = Vector2.new(1, 0),
		Position = UDim2.new(1, -10, 0, 10),
		ZIndex = 5,
		OnClick = DevInbox.Close,
	})

	local function layout()
		local v: Vector2 = h.VirtualSize()
		local w = math.min(860, v.X - 24)
		local hh = math.min(640, v.Y - 24)
		m.Panel.Size = UDim2.fromOffset(w, hh)
		local fixed = (TS(30) + 6) + (TS(14) + 6) + Theme.Size.TapMin + 3 * 8 + 2 * Theme.Space.XL
		list.Size = UDim2.new(1, 0, 0, math.max(120, hh - fixed))
		local bw = math.clamp(math.floor((w - 2 * Theme.Space.XL - 20) / 3), 90, 160)
		ui.Prev.Instance.Size = UDim2.fromOffset(bw, Theme.Size.TapMin)
		ui.Refresh.Instance.Size = UDim2.fromOffset(bw, Theme.Size.TapMin)
		ui.Next.Instance.Size = UDim2.fromOffset(bw, Theme.Size.TapMin)
		local t = ui.Toggle
		if t then
			local M = UIKit.IsCompact() and Theme.Layout.MarginCompact or Theme.Layout.Margin
			if h.IsPortrait() then
				t.AnchorPoint = Vector2.new(0, 0)
				t.Position = UDim2.fromOffset(M, math.floor(v.Y * 0.4))
			else
				t.AnchorPoint = Vector2.new(1, 1)
				t.Position = UDim2.fromOffset(v.X - M, v.Y - M)
			end
		end
	end
	host.Layout = layout
	h.OnRelayout(layout)
	layout()

	Remotes.Get("BugInboxData").OnClientEvent:Connect(onData)

	local function check()
		if player:GetAttribute("BugInbox") == true then
			buildToggle(root)
		end
	end
	player:GetAttributeChangedSignal("BugInbox"):Connect(check)
	check()
end

return DevInbox
