--[[
	PartyLines.lua (client; Config.Features.PartyQuickLines, Config.PartyQuickLines;
	docs/next/PARTY_QUICK_LINES.md)
	Fixed quick lines for a party ("Ready?", "Go!", "GG", "One more?", "Wait for me",
	"Thanks!"). Never free text: a tap sends only the line's INDEX (Party remote, "Say");
	the server validates it, rate limits it and delivers it to the sender's party members
	(remote PartySay { FromId, FromName, Index }). The text shown always comes from
	Config.PartyQuickLines.Lines on this client, so nothing typed ever travels.

	  Row      PartyLines.BuildRow(parent, opts): the six buttons, wrapped to fit a width
	           (used on the PARTY screen, MenuParty, and in the lobby popup).
	  Chip     PartyLines.BuildChip(parent): the lobby home's small SAY chip (only in a party);
	           a tap opens a popup with the row, a tap on a line sends it and closes it.
	  Feed     PartyLines.BuildFeed(parent): the last lines, newest at the bottom (PARTY screen).
	  Bubble   a short speech bubble over the sender's lobby hero that holds
	           BubbleSeconds and then fades out (your own hero on the menu stand, other
	           members' lobby characters otherwise).
	The buttons also wait MinGap seconds after a tap (the server's limit, so a quick second
	tap is not silently dropped); the server stays the judge.
]]

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")

local Shared = game:GetService("ReplicatedStorage"):WaitForChild("Shared")
local Config = require(Shared:WaitForChild("Config"))
local Theme = require(Shared:WaitForChild("Theme"))
local Remotes = require(Shared:WaitForChild("Remotes"))
local UIKit = require(script.Parent.UIKit)
local UIAnim = require(script.Parent.UIAnim)
local UIState = require(script.Parent.UIState)
local Icons = require(script.Parent.Icons)
local Showcase = require(script.Parent.Showcase)

local PartyLines = {}

local new, text, TS = UIKit.new, UIKit.text, UIKit.TS
local C, P = Theme.Color, Theme.Palette
local player = Players.LocalPlayer
local NAVY = Color3.fromRGB(16, 22, 38)

local BTN_H = 40
local GAP = 6
local MIN_BTN_W = 104

export type FeedLine = { FromId: number, Name: string, Text: string, At: number }
export type Row = {
	Frame: Frame,
	Buttons: { any },
	Measure: (w: number) -> number,
	Layout: (w: number) -> number,
}

local feed: { FeedLine } = {}
local feedListeners: { () -> () } = {}
local sentListeners: { () -> () } = {}
local sendTimes: { number } = {}
local lockUntil = 0
local rows: { { Refresh: () -> () } } = {}
local started = false

local function cfg(): { [string]: any }
	return (Config :: any).PartyQuickLines
end

function PartyLines.Enabled(): boolean
	return Config.FeatureOn("PartyQuickLines")
end

function PartyLines.Lines(): { string }
	return cfg().Lines
end

-- True while the local player is in a party (PartyService sets the PartyId attribute).
function PartyLines.InParty(): boolean
	local id = player:GetAttribute("PartyId")
	return type(id) == "number" and id > 0
end

-- The quick lines are usable now: switch on and in a party.
function PartyLines.Available(): boolean
	return PartyLines.Enabled() and PartyLines.InParty()
end

-- True while the buttons wait out the gap after your last line.
function PartyLines.Locked(): boolean
	return os.clock() < lockUntil
end

local function refreshRows()
	for _, r in ipairs(rows) do
		r.Refresh()
	end
end

------------------------------------------------------------------------------------------
-- Sending
------------------------------------------------------------------------------------------

-- Sends quick line `index` (1..#Lines). Returns true when it was sent; false when the switch
-- is off, you are not in a party, the index is wrong or you are inside your own rate limit.
function PartyLines.Say(index: number): boolean
	if not PartyLines.Available() then
		return false
	end
	local lines = cfg().Lines
	if type(index) ~= "number" or index ~= index or index < 1 or index > #lines or index % 1 ~= 0 then
		return false
	end
	local now = os.clock()
	if now < lockUntil then
		return false
	end
	local kept = {}
	for _, t in ipairs(sendTimes) do
		if now - t < 60 then
			table.insert(kept, t)
		end
	end
	sendTimes = kept
	if #sendTimes >= cfg().PerMinute then
		return false
	end
	table.insert(sendTimes, now)
	lockUntil = now + cfg().MinGap
	Remotes.Get("Party"):FireServer("Say", index)
	refreshRows()
	task.delay(cfg().MinGap + 0.05, refreshRows)
	for _, fn in ipairs(sentListeners) do
		fn()
	end
	return true
end

-- Called after a line went out (the lobby popup closes itself).
function PartyLines.OnSent(fn: () -> ())
	table.insert(sentListeners, fn)
end

------------------------------------------------------------------------------------------
-- Feed
------------------------------------------------------------------------------------------

function PartyLines.Feed(): { FeedLine }
	return feed
end

function PartyLines.OnFeed(fn: () -> ())
	table.insert(feedListeners, fn)
end

local function changed()
	for _, fn in ipairs(feedListeners) do
		task.spawn(fn)
	end
end

------------------------------------------------------------------------------------------
-- Bubbles
------------------------------------------------------------------------------------------

type Bubble = { Gui: BillboardGui, Body: Frame, Label: TextLabel, Stroke: UIStroke, Born: number }
local bubbles: { [number]: Bubble } = {}
local bubbleFolder: Folder? = nil
local menuAnchor: Part? = nil
local stepConn: RBXScriptConnection? = nil
local anchorOverride: ((userId: number) -> BasePart?)? = nil

-- Tests set this to give a sender a hero to talk over.
function PartyLines._SetAnchorResolver(fn: ((userId: number) -> BasePart?)?)
	anchorOverride = fn
end

local function folder(): Folder
	local f = bubbleFolder
	if f and f.Parent then
		return f
	end
	local gui = player:WaitForChild("PlayerGui")
	f = new("Folder", { Name = "PartyLines" }, gui) :: Folder
	bubbleFolder = f
	return f :: Folder
end

-- What a bubble hangs on: your own hero on the menu stand, or the member's lobby character.
local function anchorFor(userId: number): (BasePart?, number)
	if anchorOverride then
		return anchorOverride(userId), 0
	end
	local who = Players:GetPlayerByUserId(userId)
	if not who then
		return nil, 0
	end
	if who == player then
		local stand = Showcase.Stand()
		if stand then
			local a = menuAnchor
			if not a or not a.Parent then
				a = new("Part", { Name = "PartyLinesMenuAnchor", Anchored = true, CanCollide = false, CanQuery = false, CanTouch = false, Transparency = 1, Size = Vector3.new(0.2, 0.2, 0.2) }, workspace) :: Part
				menuAnchor = a
			end
			(a :: Part).CFrame = stand * CFrame.new(0, 6.4, 0)
			return a, 0
		end
	end
	local char = who.Character
	local root = char and (char.PrimaryPart or char:FindFirstChild("HumanoidRootPart"))
	if root and root:IsA("BasePart") then
		return root, 5.2
	end
	return nil, 0
end

local function dropBubble(userId: number)
	local b = bubbles[userId]
	if b then
		bubbles[userId] = nil
		b.Gui:Destroy()
	end
end

local function stepBubbles()
	local now = os.clock()
	local life, fade = cfg().BubbleSeconds, cfg().FadeSeconds
	local any = false
	for userId, b in pairs(bubbles) do
		local age = now - b.Born
		if age >= life or not b.Gui.Parent then
			dropBubble(userId)
		else
			any = true
			local a = 0
			if age > life - fade then
				a = math.clamp((age - (life - fade)) / fade, 0, 1)
			end
			b.Body.BackgroundTransparency = 0.12 + 0.88 * a
			b.Label.TextTransparency = a
			b.Stroke.Transparency = 0.1 + 0.9 * a
		end
	end
	if not any and stepConn then
		stepConn:Disconnect()
		stepConn = nil
	end
end

local function showBubble(userId: number, line: string)
	local anchor, lift = anchorFor(userId)
	dropBubble(userId)
	if not anchor then
		return
	end
	local gui = new("BillboardGui", {
		Name = "Bubble_" .. userId,
		Adornee = anchor,
		Size = UDim2.fromOffset(190, 52),
		StudsOffsetWorldSpace = Vector3.new(0, lift, 0),
		AlwaysOnTop = true,
		MaxDistance = 140,
		ResetOnSpawn = false,
	}, folder()) :: BillboardGui
	local body = new("Frame", { Name = "Body", AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.5), Size = UDim2.new(1, -8, 1, -8), BackgroundColor3 = NAVY, BackgroundTransparency = 0.12, BorderSizePixel = 0 }, gui) :: Frame
	UIKit.corner(body, 14)
	local stroke = UIKit.stroke(body, P.gold_300, 2, 0.1)
	local label = new("TextLabel", {
		Name = "Line",
		BackgroundTransparency = 1,
		Size = UDim2.new(1, -16, 1, -8),
		Position = UDim2.fromOffset(8, 4),
		Text = line,
		FontFace = Theme.Font.Title,
		TextSize = 22,
		TextScaled = true,
		TextColor3 = P.ivory_100,
		TextXAlignment = Enum.TextXAlignment.Center,
	}, body) :: TextLabel
	label:SetAttribute("NoTextFit", true)
	new("UITextSizeConstraint", { MaxTextSize = 24, MinTextSize = 10 }, label)
	bubbles[userId] = { Gui = gui, Body = body, Label = label, Stroke = stroke, Born = os.clock() }
	UIAnim.Pop(body, 0, 0.5)
	if not stepConn then
		stepConn = RunService.Heartbeat:Connect(stepBubbles)
	end
end

-- Active bubbles (tests): how many, and one sender's fade 0 (solid) .. 1 (gone).
function PartyLines.BubbleCount(): number
	local n = 0
	for _ in pairs(bubbles) do
		n += 1
	end
	return n
end

function PartyLines.BubbleAlpha(userId: number): number?
	local b = bubbles[userId]
	if not b then
		return nil
	end
	return math.clamp((b.Body.BackgroundTransparency - 0.12) / 0.88, 0, 1)
end

------------------------------------------------------------------------------------------
-- Incoming lines
------------------------------------------------------------------------------------------

-- A PartySay message (also called by tests). Returns the shown line or nil when it is junk.
function PartyLines.Receive(d: any): string?
	if not PartyLines.Enabled() or type(d) ~= "table" then
		return nil
	end
	local lines = cfg().Lines
	local index = d.Index
	local fromId = d.FromId
	if type(index) ~= "number" or index ~= index or index < 1 or index > #lines or index % 1 ~= 0 then
		return nil
	end
	if type(fromId) ~= "number" or fromId ~= fromId then
		return nil
	end
	local line = lines[index]
	local name = type(d.FromName) == "string" and string.sub(d.FromName, 1, 40) or "?"
	table.insert(feed, { FromId = fromId, Name = name, Text = line, At = os.clock() })
	while #feed > cfg().FeedMax do
		table.remove(feed, 1)
	end
	showBubble(fromId, line)
	changed()
	return line
end

------------------------------------------------------------------------------------------
-- The row of buttons
------------------------------------------------------------------------------------------

-- Columns that give every button at least MIN_BTN_W in a row `w` wide.
local function columnsFor(w: number): number
	for _, cols in ipairs({ 6, 3, 2 }) do
		if (w - (cols - 1) * GAP) / cols >= MIN_BTN_W then
			return cols
		end
	end
	return 2
end

function PartyLines.BuildRow(parent: Instance, o: { Name: string?, Height: number? }?): Row
	local opts = o or {}
	local height = opts.Height or BTN_H
	local frame = new("Frame", { Name = opts.Name or "QuickLines", BackgroundTransparency = 1, Size = UDim2.fromOffset(100, height) }, parent) :: Frame
	local buttons = {}
	for i, line in ipairs(cfg().Lines) do
		local b = UIKit.Button(frame, {
			Kind = "Secondary",
			Title = line,
			TitleStyle = "Label",
			TitleSize = 16,
			Align = "Center",
			Shrink = true,
			Shadow = false,
			Name = "Line" .. i,
			Radius = 10,
			OnClick = function()
				PartyLines.Say(i)
			end,
		})
		buttons[i] = b
	end
	local function measure(w: number): number
		local cols = columnsFor(w)
		local n = math.ceil(#buttons / cols)
		return n * height + (n - 1) * GAP
	end
	local function layout(w: number): number
		local cols = columnsFor(w)
		local bw = math.floor((w - (cols - 1) * GAP) / cols)
		for i, b in ipairs(buttons) do
			local cx, cy = (i - 1) % cols, math.floor((i - 1) / cols)
			b.Instance.Position = UDim2.fromOffset(cx * (bw + GAP), cy * (height + GAP))
			b.Instance.Size = UDim2.fromOffset(bw, height)
		end
		local h = measure(w)
		frame.Size = UDim2.fromOffset(w, h)
		return h
	end
	local row: Row = { Frame = frame, Buttons = buttons, Measure = measure, Layout = layout }
	local function refresh()
		local ok = PartyLines.Available() and not PartyLines.Locked()
		for _, b in ipairs(buttons) do
			if b.IsEnabled() ~= ok then
				b.SetEnabled(ok)
			end
		end
	end
	table.insert(rows, { Refresh = refresh })
	refresh()
	row.Layout(300)
	return row
end

------------------------------------------------------------------------------------------
-- The feed (PARTY screen)
------------------------------------------------------------------------------------------

export type FeedView = { Frame: Frame, Measure: (lines: number) -> number, Layout: (w: number, lines: number) -> number, Refresh: () -> () }

function PartyLines.BuildFeed(parent: Instance): FeedView
	local frame = new("Frame", { Name = "QuickFeed", BackgroundTransparency = 1, Size = UDim2.fromOffset(100, 40) }, parent) :: Frame
	local labels: { TextLabel } = {}
	for i = 1, cfg().FeedMax do
		local l = text(frame, "Small", "", { Name = "Line" .. i, TextXAlignment = Enum.TextXAlignment.Left, TextTruncate = Enum.TextTruncate.AtEnd, TextColor3 = P.ivory_100, Visible = false }, 14)
		labels[i] = l
	end
	local empty = text(frame, "Small", "Tap a quick line to talk to your party.", { Name = "Empty", TextXAlignment = Enum.TextXAlignment.Left, TextTruncate = Enum.TextTruncate.AtEnd, TextColor3 = C.TextMuted }, 14)
	local shown = 3
	local lineH = TS(14) + 3
	local function measure(lines: number): number
		return math.max(1, lines) * (TS(14) + 3) + 2
	end
	local function refresh()
		local list = feed
		local from = math.max(1, #list - shown + 1)
		local k = 0
		for i, l in ipairs(labels) do
			local entry = list[from + i - 1]
			if i <= shown and entry then
				k += 1
				l.Visible = true
				l.Text = entry.Name .. ": " .. entry.Text
				l.TextColor3 = entry.FromId == player.UserId and P.gold_200 or P.ivory_100
				l.Position = UDim2.fromOffset(0, (i - 1) * lineH)
				l.Size = UDim2.new(1, 0, 0, lineH)
			else
				l.Visible = false
			end
		end
		empty.Visible = k == 0
		empty.Size = UDim2.new(1, 0, 0, lineH)
	end
	local function layout(w: number, lines: number): number
		shown = math.clamp(lines, 1, #labels)
		lineH = TS(14) + 3
		local h = measure(shown)
		frame.Size = UDim2.fromOffset(w, h)
		refresh()
		return h
	end
	local view: FeedView = { Frame = frame, Measure = measure, Layout = layout, Refresh = refresh }
	PartyLines.OnFeed(function()
		view.Refresh()
	end)
	view.Refresh()
	return view
end

------------------------------------------------------------------------------------------
-- The lobby home's SAY chip + popup
------------------------------------------------------------------------------------------

export type Chip = {
	Button: TextButton,
	Layout: (x: number, y: number, w: number, h: number, bounds: Vector2, below: boolean) -> (),
	Hide: () -> (),
	Wanted: () -> boolean,
	Close: () -> (),
	IsOpen: () -> boolean,
}

-- The chip's width for a height (icon + "SAY"), so the lobby can reserve its room.
function PartyLines.ChipWidth(h: number): number
	return math.floor(h * 2.6 + 0.5)
end

function PartyLines.BuildChip(parent: Frame): Chip
	local b = new("TextButton", {
		Name = "SayChip",
		Text = "",
		AutoButtonColor = false,
		BackgroundColor3 = NAVY,
		BackgroundTransparency = 0.18,
		BorderSizePixel = 0,
		Visible = false,
	}, parent) :: TextButton
	UIKit.corner(b, 10)
	UIKit.stroke(b, P.gold_400, 1.5, 0.25)
	UIKit.Focusable(b)
	UIAnim.Button(b)
	local iconHolder = new("Frame", { Name = "IconHolder", BackgroundTransparency = 1 }, b)
	Icons.Draw(iconHolder, "people3", { Size = 18, AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.5), Back = NAVY })
	local label = new("TextLabel", {
		Name = "ChipText",
		BackgroundTransparency = 1,
		Text = "SAY",
		FontFace = Theme.Font.Title,
		TextSize = 15,
		TextScaled = true,
		TextColor3 = P.gold_200,
		TextXAlignment = Enum.TextXAlignment.Left,
		TextTruncate = Enum.TextTruncate.AtEnd,
		TextStrokeColor3 = C.Shadow,
		TextStrokeTransparency = 0.6,
	}, b)
	new("UITextSizeConstraint", { Name = "Fit", MaxTextSize = 16, MinTextSize = 8 }, label)

	local holder, face = UIKit.Surface(parent, { Name = "SayPopup", Radius = Theme.Radius.M, Transparency = 0.06, Edge = P.gold_400, EdgeTransparency = 0.35, ZIndex = 15, Visible = false })
	UIKit.padding(face, 10, 10, 10, 10)
	local row = PartyLines.BuildRow(face, { Name = "PopupLines" })

	local wanted, covered, open = false, false, false
	local last = { x = 0, y = 0, w = 0, h = 0, bounds = Vector2.new(0, 0), below = false }
	local function sync()
		local usable = wanted and not covered and PartyLines.Available()
		b.Visible = usable
		holder.Visible = usable and open
	end
	local function place()
		local bounds = last.bounds
		local popupW = math.max(120, math.min(bounds.X - 16, 360))
		local innerW = popupW - 20
		local rowH = row.Layout(innerW)
		local popupH = rowH + 20
		local px = math.clamp(last.x + last.w - popupW, 8, math.max(8, bounds.X - popupW - 8))
		local py = last.below and (last.y + last.h + 6) or (last.y - 6 - popupH)
		py = math.clamp(py, 8, math.max(8, bounds.Y - popupH - 8))
		holder.Position = UDim2.fromOffset(math.floor(px + 0.5), math.floor(py + 0.5))
		holder.Size = UDim2.fromOffset(popupW, popupH)
		row.Frame.Position = UDim2.fromOffset(0, 0)
	end
	b.Activated:Connect(function()
		UIKit.Click()
		open = not open
		sync()
		if open then
			place()
		end
	end)
	UIState.OnOwnerChanged(function(owner: string?)
		covered = owner ~= nil
		if covered then
			open = false
		end
		sync()
	end)
	local chip: Chip
	chip = {
		Button = b,
		Layout = function(x: number, y: number, w: number, h: number, bounds: Vector2, below: boolean)
			wanted = w > 0 and h > 0
			last = { x = x, y = y, w = w, h = h, bounds = bounds, below = below }
			b.Position = UDim2.fromOffset(math.floor(x + 0.5), math.floor(y + 0.5))
			b.Size = UDim2.fromOffset(math.floor(w + 0.5), math.floor(h + 0.5))
			local s = math.max(14, h - 12)
			iconHolder.Position = UDim2.fromOffset(8, (h - s) / 2)
			iconHolder.Size = UDim2.fromOffset(s, s)
			label.Position = UDim2.fromOffset(8 + s + 6, 4)
			label.Size = UDim2.new(1, -(8 + s + 6 + 10), 1, -8)
			if open then
				place()
			end
			sync()
		end,
		Hide = function()
			wanted = false
			open = false
			sync()
		end,
		Wanted = function()
			return PartyLines.Available()
		end,
		Close = function()
			open = false
			sync()
		end,
		IsOpen = function()
			return open and holder.Visible
		end,
	}
	-- a line sent from the popup closes it
	PartyLines.OnSent(function()
		open = false
		sync()
	end)
	rows[#rows + 1] = { Refresh = sync }
	return chip
end

------------------------------------------------------------------------------------------
-- Start
------------------------------------------------------------------------------------------

function PartyLines.Init()
	if started then
		return
	end
	started = true
	Remotes.Get("PartySay").OnClientEvent:Connect(function(d)
		PartyLines.Receive(d)
	end)
	-- leaving the party empties the feed; joining / leaving changes which buttons work
	player:GetAttributeChangedSignal("PartyId"):Connect(function()
		if not PartyLines.InParty() then
			table.clear(feed)
			table.clear(sendTimes)
			lockUntil = 0
			changed()
		end
		refreshRows()
	end)
end

return PartyLines
