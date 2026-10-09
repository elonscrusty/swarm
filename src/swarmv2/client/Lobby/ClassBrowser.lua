--!strict
--[[
	SwarmV2Client/Lobby/ClassBrowser.lua
	OWNER: lobby track (Chat 1), stream L1. The class browser (replaces the old four-card class sheet).

	Wide screens (desktop, tablet): a stable three-column card grid beside a details panel.
	Phones: a two-column grid, then a dedicated details view (BACK returns to the same filter, page
	and highlighted card). All / Owned filters (locked classes show in All), paged grids (never a
	scroll that moves cards), every card is a focusable button so a gamepad reaches all of them
	(the pager buttons reach the other pages).

	Cards: portrait (a ViewportFrame of the real class model from ReplicatedStorage.CharacterPreviews
	when the server has built it; a labelled loading / unavailable swatch otherwise), name, ownership
	badge, selected badge, role.

	Details: class id, name, description, ownership state, unlock requirement + progress
	(ClassDetails.Access, LobbyView.Progress), starting weapon, passive, movement ability (names and
	behaviour), and the eight base measurements (ClassDetails: all read from the shared tuning, labelled
	"base values before upgrades"; a figure that cannot be read is hidden with its reason).

	Actions: PREVIEW (a turning model, never selects or buys) and SELECT / BUY / SELECTED / LOCKED.
	A choice stays pending until the server's ClassAck answers (LobbyView.ClassAck): the previous
	class stays selected on a refusal or a silent server (timeout), and the reason is shown. While
	queued the class is locked: the browser explains it and offers LEAVE QUEUE. The gold purchase
	(the three priced classes, DECISIONS C2) goes through a confirmation that names the class, the
	price and the outcome; it is disabled while the profile or a class answer is pending.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Kit = require(script.Parent.Kit)
local Brief = require(script.Parent.Brief)

local V2 = ReplicatedStorage:WaitForChild("SwarmV2")
local ClassCatalog = require(V2:WaitForChild("ClassCatalog"))
local ClassDetails = require(V2:WaitForChild("Lobby"):WaitForChild("ClassDetails"))
local clientRoot = script.Parent.Parent.Parent:WaitForChild("SwarmClient")
local ViewportPreview = require(clientRoot:WaitForChild("ViewportPreview"))

local UIKit = Kit.UIKit
local new = UIKit.new
local T = Brief.T

local ClassBrowser = {}

export type Sheet = {
	Overlay: Frame,
	Open: () -> (),
	Close: () -> (),
	IsOpen: () -> boolean,
}

export type Panel = {
	Sheet: Sheet,
	Layout: (ctx: Kit.Ctx) -> (),
	Render: (ctx: Kit.Ctx) -> (),
	Step: (ctx: Kit.Ctx) -> (),
	-- Escape / gamepad B: one step back (confirmation -> details -> grid -> closed). false when closed.
	Back: () -> boolean,
	-- for tools and tests
	State: () -> { [string]: any },
}

local PENDING_SECONDS = 6 -- a silent server: the choice is dropped and the previous class stays
local PREVIEW_UNAVAILABLE_AFTER = 12 -- seconds a missing model stays "loading" before "unavailable"
local FILTERS = { "All", "Owned" }

local function thousands(n: number): string
	return ClassDetails.Thousands(n)
end

local function nameOf(id: string): string
	local info = ClassCatalog.Get(id)
	return info and info.Name or id
end

------------------------------------------------------------------------------------------
-- Portraits (a ViewportFrame of the real class model, or a labelled placeholder)
------------------------------------------------------------------------------------------

type Portrait = {
	Frame: Frame,
	Id: string,
	Preview: any,
	Swatch: Frame,
	Status: TextLabel,
	Since: number,
	Done: boolean,
}

local function makePortrait(parent: Instance, classId: string, props: { [string]: any }, speed: number, compact: boolean): Portrait
	local info = ClassCatalog.Get(classId)
	local primary = info and info.Primary or T.Navy
	local frame = new("Frame", {
		Name = "Portrait",
		BackgroundColor3 = primary:Lerp(T.NavyDeep, 0.6),
		BorderSizePixel = 0,
		ClipsDescendants = true,
		Size = UDim2.fromScale(1, 1),
	})
	for k, v in pairs(props) do
		(frame :: any)[k] = v
	end
	UIKit.corner(frame, 10)
	frame.Parent = parent
	-- the labelled placeholder (shown until the model arrives; never presented as the finished picture)
	local swatch = new("Frame", {
		Name = "Swatch",
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.42),
		Size = UDim2.fromOffset(46, 46),
		BackgroundColor3 = primary,
		BorderSizePixel = 0,
		ZIndex = (props.ZIndex or 1) + 1,
	}, frame)
	UIKit.corner(swatch, 999)
	UIKit.stroke(swatch, info and info.Accent or T.Cream, 3, 0)
	local capH = Brief.size("Caption", compact)
	local status = Brief.label(frame, "Caption", "PREVIEW LOADING", {
		Name = "Status",
		AnchorPoint = Vector2.new(0.5, 1),
		Position = UDim2.new(0.5, 0, 1, -4),
		Size = UDim2.new(1, -8, 0, capH + 4),
		TextXAlignment = Enum.TextXAlignment.Center,
		TextColor3 = T.CreamMuted,
		TextTruncate = Enum.TextTruncate.AtEnd,
		ZIndex = (props.ZIndex or 1) + 2,
	}, compact)
	local pv = ViewportPreview.Create(frame, { Size = UDim2.fromScale(1, 1), ZIndex = (props.ZIndex or 1) + 3 })
	pv.Speed = speed
	pv.Phase = math.pi - 0.45 -- the front, a little from the side
	return { Frame = frame, Id = classId, Preview = pv, Swatch = swatch, Status = status, Since = os.clock(), Done = false }
end

local function tryModel(p: Portrait): boolean
	if p.Done then
		return true
	end
	local tpl = ViewportPreview.Template(p.Id)
	if tpl then
		ViewportPreview.SetModel(p.Preview, tpl)
		if p.Preview.Model ~= nil then
			-- a little more room than ViewportPreview's tight fit: the idle bob never clips a head
			p.Preview.Radius = p.Preview.Radius * 1.22
			p.Done = true
			p.Swatch.Visible = false
			p.Status.Visible = false
			return true
		end
	end
	if os.clock() - p.Since > PREVIEW_UNAVAILABLE_AFTER then
		p.Status.Text = "PREVIEW UNAVAILABLE"
	end
	return false
end

------------------------------------------------------------------------------------------
-- Build
------------------------------------------------------------------------------------------

function ClassBrowser.Build(ctx: Kit.Ctx): Panel
	-- state ----------------------------------------------------------------------------
	local isOpen = false
	local compact = ctx.Compact
	local mode = "Wide" -- Wide | PhonePortrait | PhoneLandscape
	local filter = "All"
	local page = 1
	local inspected: string = ClassCatalog.Default
	local screen = "Grid" -- Grid | Details (phones only; Wide shows both)
	local previewOn = false
	local confirming: string? = nil
	local pending: { Id: string, Action: string, N0: number, At: number }? = nil
	local notice: { Kind: string, Text: string }? = nil
	local portraits: { Portrait } = {}
	local detailPortrait: Portrait? = nil
	local pollAt = 0
	local gridSig, detailSig = "", ""
	local lastView: any = nil
	local perPage = 6
	local cols, rows = 3, 2
	local cardW, cardH = 200, 200
	local rowStyle = false
	local headH = 100 -- the details head grows when a long name wraps
	local cardButtons: { [string]: TextButton } = {}
	local ctxRefresh: () -> () = function() end -- layout + render (set below)

	-- frames ---------------------------------------------------------------------------
	local overlay = new("Frame", {
		Name = "ClassBrowser",
		BackgroundTransparency = 1,
		Size = UDim2.fromScale(1, 1),
		Visible = false,
		Active = true,
		ZIndex = 10,
	}, ctx.Root)
	local dim = new("TextButton", {
		Name = "Dim",
		Text = "",
		AutoButtonColor = false,
		BackgroundColor3 = T.NavyDeep,
		BackgroundTransparency = 0.25,
		BorderSizePixel = 0,
		Size = UDim2.fromScale(1, 1),
		ZIndex = 10,
		Selectable = false,
	}, overlay)
	local panel = Brief.panel(overlay, {
		Name = "Panel",
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.5),
		Size = UDim2.fromOffset(900, 600),
		ZIndex = 11,
		Active = true,
	})

	local header = new("Frame", { Name = "Header", BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 56), ZIndex = 12 }, panel)
	local title = Brief.label(header, "Title", "CLASSES", { Name = "ScreenTitle", ZIndex = 12, Size = UDim2.fromOffset(240, 44), TextTruncate = Enum.TextTruncate.AtEnd }, compact)
	local lockChip: Frame? = nil
	local goldLabel = Brief.label(header, "Section", "", { Name = "Gold", TextXAlignment = Enum.TextXAlignment.Right, ZIndex = 12, TextColor3 = T.Gold, Size = UDim2.fromOffset(190, 36) }, compact)
	local backBtn: Brief.Button
	local closeBtn: Brief.Button

	local tabRow = new("Frame", { Name = "Tabs", BackgroundTransparency = 1, Size = UDim2.fromOffset(240, 48), ZIndex = 12 }, panel)
	local tabButtons: { [string]: Brief.Button } = {}
	local pagerRow = new("Frame", { Name = "Pager", BackgroundTransparency = 1, Size = UDim2.fromOffset(240, 48), ZIndex = 12 }, panel)
	local pageLabel = Brief.label(pagerRow, "Label", "", { Name = "Page", TextXAlignment = Enum.TextXAlignment.Center, ZIndex = 13, Size = UDim2.fromOffset(80, 48) }, compact)
	local prevBtn: Brief.Button
	local nextBtn: Brief.Button
	local gridHost = new("Frame", { Name = "Grid", BackgroundTransparency = 1, Size = UDim2.fromOffset(600, 400), ZIndex = 12 }, panel)
	local gridLayout = new("UIGridLayout", {
		SortOrder = Enum.SortOrder.LayoutOrder,
		CellPadding = UDim2.fromOffset(12, 12),
		CellSize = UDim2.fromOffset(200, 200),
		HorizontalAlignment = Enum.HorizontalAlignment.Left,
		VerticalAlignment = Enum.VerticalAlignment.Top,
		FillDirection = Enum.FillDirection.Horizontal,
	}, gridHost)

	local details = new("Frame", { Name = "Details", BackgroundTransparency = 1, Size = UDim2.fromOffset(400, 500), ZIndex = 12 }, panel)
	local detailHead = new("Frame", { Name = "Head", BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 100), ZIndex = 13 }, details)
	local scroll = new("ScrollingFrame", {
		Name = "Scroll",
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		Size = UDim2.fromOffset(400, 300),
		CanvasSize = UDim2.new(),
		AutomaticCanvasSize = Enum.AutomaticSize.Y,
		ScrollingDirection = Enum.ScrollingDirection.Y,
		ScrollBarThickness = 6,
		ScrollBarImageColor3 = T.Line,
		ElasticBehavior = Enum.ElasticBehavior.Never,
		ZIndex = 13,
	}, details)
	local content = new("Frame", { Name = "Content", BackgroundTransparency = 1, Size = UDim2.new(1, -12, 0, 10), AutomaticSize = Enum.AutomaticSize.Y, ZIndex = 13 }, scroll)
	new("UIListLayout", { SortOrder = Enum.SortOrder.LayoutOrder, Padding = UDim.new(0, 14) }, content)
	local actions = new("Frame", { Name = "Actions", BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 130), ZIndex = 13 }, details)
	local actionNote = new("Frame", { Name = "NoteHost", BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 40), ZIndex = 13 }, actions)
	new("UIListLayout", { SortOrder = Enum.SortOrder.LayoutOrder, Padding = UDim.new(0, 4) }, actionNote)
	local actionRow = new("Frame", { Name = "Buttons", BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 56), ZIndex = 13 }, actions)
	local previewBtn: Brief.Button
	local mainBtn: Brief.Button
	local leaveBtn: Brief.Button

	-- the purchase confirmation (names the class, the price and the outcome)
	local confirmDim = new("TextButton", {
		Name = "ConfirmDim",
		Text = "",
		AutoButtonColor = false,
		BackgroundColor3 = T.NavyDeep,
		BackgroundTransparency = 0.2,
		BorderSizePixel = 0,
		Size = UDim2.fromScale(1, 1),
		Visible = false,
		ZIndex = 30,
		Selectable = false,
	}, overlay)
	local confirmPanel = Brief.panel(confirmDim, {
		Name = "Confirm",
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.5),
		Size = UDim2.fromOffset(460, 320),
		ZIndex = 31,
		Active = true,
	})
	local confirmTitle = Brief.label(confirmPanel, "Section", "", { Name = "ConfirmTitle", Position = UDim2.fromOffset(20, 18), Size = UDim2.new(1, -40, 0, 34), TextTruncate = Enum.TextTruncate.AtEnd, ZIndex = 32 }, compact)
	local confirmBody = Brief.label(confirmPanel, "Body", "", { Name = "ConfirmBody", Position = UDim2.fromOffset(20, 60), Size = UDim2.new(1, -40, 0, 140), TextWrapped = true, TextYAlignment = Enum.TextYAlignment.Top, ZIndex = 32 }, compact)
	local confirmYes: Brief.Button
	local confirmNo: Brief.Button

	-- helpers ----------------------------------------------------------------------------
	local function ownedNow(id: string): boolean
		local v = lastView
		return id == ClassCatalog.Default or (v ~= nil and v.Owned ~= nil and v.Owned[id] == true)
	end
	local function queued(): boolean
		return lastView ~= nil and lastView.Queue ~= nil
	end
	local function committed(): boolean
		local v = lastView
		if v == nil then
			return false
		end
		if v.ClassLocked == true then
			return true
		end
		local q = v.Queue
		return q ~= nil and (q.State == "Committed" or q.State == "Teleporting")
	end
	local function filtered(): { string }
		local out = {}
		for _, id in ipairs(ClassCatalog.Order) do
			if filter == "All" or ownedNow(id) then
				table.insert(out, id)
			end
		end
		return out
	end
	local function setNotice(kind: string?, text: string?)
		if kind and text then
			notice = { Kind = kind, Text = text }
		else
			notice = nil
		end
		detailSig = ""
	end
	local function close()
		isOpen = false
		overlay.Visible = false
		confirming = nil
		confirmDim.Visible = false
		screen = "Grid"
		previewOn = false
	end
	local function inspect(id: string)
		if inspected ~= id then
			inspected = id
			previewOn = false
			notice = nil
		end
		if mode ~= "Wide" then
			screen = "Details"
		end
		gridSig, detailSig = "", ""
	end
	local function fireAction(action: string, id: string)
		local ack = lastView and lastView.ClassAck
		pending = { Id = id, Action = action, N0 = ack and ack.N or 0, At = os.clock() }
		setNotice(nil, nil)
		gridSig, detailSig = "", ""
		ctx.Fire("ClassAction", action, id)
	end

	-- the one decision table for the main action of a class ---------------------------------
	type Plan = { Title: string, Kind: string, Enabled: boolean, Note: string?, NoteKind: string?, Action: string?, Pending: boolean }
	local function plan(id: string): Plan
		local v = lastView
		local info = ClassCatalog.Get(id)
		if info == nil then
			return { Title = "UNAVAILABLE", Kind = "Secondary", Enabled = false, Note = "This class is not available.", NoteKind = "Error", Pending = false }
		end
		local owned = ownedNow(id)
		local pend = pending
		if pend and pend.Id == id then
			return { Title = pend.Action == "Buy" and "BUYING..." or "SELECTING...", Kind = "Primary", Enabled = false, Note = "Waiting for the server to confirm. Your current class stays selected until it does.", NoteKind = "Info", Pending = true }
		end
		if v == nil then
			return { Title = owned and "SELECT" or "LOCKED", Kind = "Secondary", Enabled = false, Note = "Your save is still loading. You can browse the classes meanwhile.", NoteKind = "Info", Pending = false }
		end
		if owned and v.Selected == id then
			return { Title = "SELECTED", Kind = "Selected", Enabled = false, Note = "This is your class for the next run.", NoteKind = "Good", Pending = false }
		end
		if committed() then
			return { Title = owned and "SELECT" or "LOCKED", Kind = "Secondary", Enabled = false, Note = "Your class is locked while the run starts.", NoteKind = "Info", Pending = false }
		end
		if pend then
			return { Title = owned and "SELECT" or "BUY", Kind = "Secondary", Enabled = false, Note = "Waiting for the server to answer for " .. nameOf(pend.Id) .. ".", NoteKind = "Info", Pending = false }
		end
		if queued() then
			return { Title = owned and "SELECT" or (info.GoalOnly and "LOCKED" or "BUY"), Kind = "Secondary", Enabled = false, Note = "You are in a queue, so your class is locked. Leave the queue to change it.", NoteKind = "Info", Pending = false }
		end
		if owned then
			return { Title = "SELECT", Kind = "Primary", Enabled = true, Action = "Select", Pending = false }
		end
		if info.GoalOnly then
			local access = ClassDetails.Access(id, false, v.Progress and v.Progress[id] or nil)
			return { Title = "LOCKED", Kind = "Secondary", Enabled = false, Note = access and access.Summary or "Earn this class in runs.", NoteKind = "Info", Pending = false }
		end
		local gold: number = v.Gold or 0
		if gold >= info.Cost then
			return { Title = "BUY " .. thousands(info.Cost) .. " GOLD", Kind = "Primary", Enabled = true, Action = "BuyConfirm", Pending = false }
		end
		return { Title = "NEED " .. thousands(info.Cost - gold) .. " MORE GOLD", Kind = "Secondary", Enabled = false, Note = "Earn gold in runs, or earn the class by its goal.", NoteKind = "Info", Pending = false }
	end

	-- cards ------------------------------------------------------------------------------------
	local function badgeFor(id: string): (string, string)
		if lastView == nil and id ~= ClassCatalog.Default then
			return "Info", "CHECKING"
		end
		if id == ClassCatalog.Default then
			return "Starter", "STARTER"
		end
		if ownedNow(id) then
			return "Owned", "OWNED"
		end
		return "Locked", "LOCKED"
	end

	-- the card's requirement line: the price (where one exists) and the goal in words
	local function hintFor(id: string): (string?, number?)
		local v = lastView
		if v == nil or ClassCatalog.Get(id) == nil or ownedNow(id) then
			return nil, nil
		end
		local access = ClassDetails.Access(id, false, v.Progress and v.Progress[id] or nil)
		if access == nil then
			return nil, nil
		end
		local text = access.Goal or access.Summary
		if access.State == "Buyable" and access.Price then
			text = thousands(access.Price) .. " gold or " .. string.lower(string.sub(text, 1, 1)) .. string.sub(text, 2)
		end
		return text, access.Fraction
	end

	local function buildCard(id: string, order: number)
		local info = ClassCatalog.Get(id)
		if not info then
			return
		end
		local v = lastView
		local selected = v ~= nil and v.Selected == id
		local on = inspected == id
		local owned = ownedNow(id)
		local card = new("TextButton", {
			Name = "Card_" .. id,
			Text = "",
			AutoButtonColor = false,
			BackgroundColor3 = on and T.NavyHover or T.NavyRaised,
			BorderSizePixel = 0,
			LayoutOrder = order,
			Size = UDim2.fromOffset(cardW, cardH),
			ZIndex = 13,
		}, gridHost)
		Brief.focusable(card)
		UIKit.corner(card, 12)
		UIKit.stroke(card, on and T.Cyan or T.Line, on and 3 or 2, 0)
		cardButtons[id] = card
		local pad = 8
		local picW, picH, textX, textW
		if rowStyle then
			picW, picH = cardH - 2 * pad, cardH - 2 * pad
			textX, textW = pad + picW + 10, cardW - (pad + picW + 10) - pad
		else
			picW, picH = cardW - 2 * pad, math.floor(cardH * 0.5)
			textX, textW = pad, cardW - 2 * pad
		end
		local por = makePortrait(card, id, { Position = UDim2.fromOffset(pad, pad), Size = UDim2.fromOffset(picW, picH), ZIndex = 14 }, 0, compact)
		table.insert(portraits, por)
		tryModel(por)
		if not owned and v ~= nil then
			-- locked: the picture stays visible but dimmed, with its lock named in words
			local shade = new("Frame", { Name = "LockedShade", BackgroundColor3 = T.NavyDeep, BackgroundTransparency = 0.55, BorderSizePixel = 0, Size = UDim2.fromScale(1, 1), ZIndex = 20, Active = false }, por.Frame)
			UIKit.corner(shade, 10)
		end
		-- badges: selected (cyan) and ownership
		local bKind, bText = badgeFor(id)
		if rowStyle then
			local row = new("Frame", { Name = "Badges", BackgroundTransparency = 1, Position = UDim2.fromOffset(textX, cardH - pad - 28), Size = UDim2.fromOffset(textW, 26), ZIndex = 15 }, card)
			new("UIListLayout", { FillDirection = Enum.FillDirection.Horizontal, VerticalAlignment = Enum.VerticalAlignment.Center, SortOrder = Enum.SortOrder.LayoutOrder, Padding = UDim.new(0, 4) }, row)
			if selected then
				Brief.badge(row, "Selected", "SELECTED", { LayoutOrder = 1, ZIndex = 15 }, true)
			end
			Brief.badge(row, bKind, bText, { LayoutOrder = 2, ZIndex = 15 }, true)
		else
			if selected then
				Brief.badge(por.Frame, "Selected", "SELECTED", { Position = UDim2.fromOffset(6, 6), ZIndex = 22 }, compact)
			end
			Brief.badge(por.Frame, bKind, bText, { AnchorPoint = Vector2.new(1, 0), Position = UDim2.new(1, -6, 0, 6), ZIndex = 22 }, compact)
		end
		local nameSize = rowStyle and 19 or 20
		local nameY = rowStyle and pad or (pad + picH + 6)
		Brief.label(card, "Body", info.Name, {
			Name = "Name",
			FontFace = Brief.Weight.Black,
			TextSize = nameSize,
			Position = UDim2.fromOffset(textX, nameY),
			Size = UDim2.fromOffset(textW, nameSize + 6),
			TextTruncate = Enum.TextTruncate.AtEnd,
			ZIndex = 14,
		}, compact)
		local d = ClassDetails.Get(id)
		Brief.label(card, "Label", d and d.Role or (info.Role or ""), {
			Name = "Role",
			Position = UDim2.fromOffset(textX, nameY + nameSize + 6),
			Size = UDim2.fromOffset(textW, Brief.size("Label", compact) + 4),
			TextTruncate = Enum.TextTruncate.AtEnd,
			ZIndex = 14,
		}, compact)
		if not rowStyle then
			local hint, fraction = hintFor(id)
			if hint then
				local capH = Brief.size("Caption", compact)
				Brief.label(card, "Caption", hint, {
					Name = "Hint",
					TextColor3 = T.Gold,
					Position = UDim2.new(0, pad, 1, -(2 * capH + 18)),
					Size = UDim2.new(1, -2 * pad, 0, 2 * capH + 4),
					TextWrapped = true,
					TextYAlignment = Enum.TextYAlignment.Top,
					TextTruncate = Enum.TextTruncate.AtEnd,
					ZIndex = 14,
				}, compact)
				if fraction then
					local _, setBar = Brief.bar(card, { Name = "GoalBar", Position = UDim2.new(0, pad, 1, -12), Size = UDim2.new(1, -2 * pad, 0, 6), ZIndex = 14 })
					setBar(fraction)
				end
			end
		end
		card.Activated:Connect(function()
			inspect(id)
			ctxRefresh()
		end)
	end

	local function rebuildGrid()
		for i = #portraits, 1, -1 do
			if portraits[i] ~= detailPortrait then
				table.remove(portraits, i)
			end
		end
		Kit.clear(gridHost)
		table.clear(cardButtons)
		local list = filtered()
		local totalPages = math.max(1, math.ceil(#list / perPage))
		page = math.clamp(page, 1, totalPages)
		local from = (page - 1) * perPage
		for i = 1, perPage do
			local id = list[from + i]
			if not id then
				break
			end
			buildCard(id, i)
		end
		gridLayout.CellSize = UDim2.fromOffset(cardW, cardH)
		pageLabel.Text = string.format("PAGE %d / %d", page, totalPages)
		prevBtn.SetEnabled(page > 1)
		nextBtn.SetEnabled(page < totalPages)
		tabButtons.All.SetText(string.format("ALL %d", #ClassCatalog.Order))
		local n = 0
		for _, id in ipairs(ClassCatalog.Order) do
			if ownedNow(id) then
				n += 1
			end
		end
		tabButtons.Owned.SetText(string.format("OWNED %d", n))
		for _, f in ipairs(FILTERS) do
			tabButtons[f].SetKind(filter == f and "Selected" or "Secondary")
		end
	end

	-- details -----------------------------------------------------------------------------------
	local function section(order: number, heading: string): Frame
		local f = new("Frame", { Name = "Section_" .. order, BackgroundTransparency = 1, LayoutOrder = order, Size = UDim2.new(1, 0, 0, 10), AutomaticSize = Enum.AutomaticSize.Y, ZIndex = 14 }, content)
		new("UIListLayout", { SortOrder = Enum.SortOrder.LayoutOrder, Padding = UDim.new(0, 4) }, f)
		Brief.label(f, "Label", heading, { LayoutOrder = 1, ZIndex = 14, TextColor3 = T.CreamMuted }, compact)
		return f
	end
	local function paragraph(parent: Instance, order: number, text: string, role: string?, color: Color3?): TextLabel
		local r = role or "Body"
		local l = Brief.label(parent, r, text, {
			LayoutOrder = order,
			TextWrapped = true,
			TextYAlignment = Enum.TextYAlignment.Top,
			Size = UDim2.new(1, 0, 0, 10),
			AutomaticSize = Enum.AutomaticSize.Y,
			ZIndex = 14,
		}, compact)
		if color then
			l.TextColor3 = color
		end
		if r == "Body" then
			l.FontFace = Brief.Weight.Regular
		end
		return l
	end

	local function rebuildDetails()
		for i = #portraits, 1, -1 do
			if portraits[i] == detailPortrait then
				table.remove(portraits, i)
			end
		end
		detailPortrait = nil
		Kit.clear(content)
		Kit.clear(detailHead)
		Kit.clear(actionNote)
		local id = inspected
		local info = ClassCatalog.Get(id)
		local d = ClassDetails.Get(id)
		if not info or not d then
			Brief.note(content, "Error", "This class could not be shown.", { LayoutOrder = 1 }, compact)
			return
		end
		local v = lastView
		local owned = ownedNow(id)
		local access = ClassDetails.Access(id, owned, v and v.Progress and v.Progress[id] or nil)
		local bKind, bText = badgeFor(id)

		-- head: name (wraps up to three lines), badges, role and id
		local nameSize = compact and 26 or 30
		local headW = (mode == "PhoneLandscape") and math.floor(details.Size.X.Offset * 0.42) or details.Size.X.Offset
		local nameLines = math.clamp(math.ceil(#d.Name * nameSize * 0.56 / math.max(120, headW)), 1, 3)
		local nameH = nameLines * (nameSize + 6) + 2
		headH = 70 + nameH
		Brief.label(detailHead, "Title", d.Name, {
			Name = "ClassName",
			TextSize = nameSize,
			Size = UDim2.new(1, 0, 0, nameH),
			TextWrapped = true,
			TextYAlignment = Enum.TextYAlignment.Top,
			TextTruncate = Enum.TextTruncate.AtEnd,
			ZIndex = 14,
		}, compact)
		local badgeRow = new("Frame", { Name = "Badges", BackgroundTransparency = 1, Position = UDim2.fromOffset(0, nameH + 2), Size = UDim2.new(1, 0, 0, 28), ZIndex = 14 }, detailHead)
		new("UIListLayout", { FillDirection = Enum.FillDirection.Horizontal, VerticalAlignment = Enum.VerticalAlignment.Center, SortOrder = Enum.SortOrder.LayoutOrder, Padding = UDim.new(0, 6) }, badgeRow)
		if v ~= nil and v.Selected == id then
			Brief.badge(badgeRow, "Selected", "SELECTED", { LayoutOrder = 1, ZIndex = 14 }, compact)
		end
		Brief.badge(badgeRow, bKind, bText, { LayoutOrder = 2, ZIndex = 14 }, compact)
		Brief.label(detailHead, "Label", d.Role .. "  |  id: " .. id, {
			Name = "RoleAndId",
			Position = UDim2.fromOffset(0, nameH + 34),
			Size = UDim2.new(1, 0, 0, Brief.size("Label", compact) + 6),
			TextTruncate = Enum.TextTruncate.AtEnd,
			ZIndex = 14,
			TextColor3 = T.CreamMuted,
		}, compact)

		-- preview (a still portrait; PREVIEW turns it)
		local capH = Brief.size("Caption", compact) + 6
		local pv = new("Frame", { Name = "PreviewHost", BackgroundTransparency = 1, LayoutOrder = 1, Size = UDim2.new(1, 0, 0, (previewOn and 230 or 150) + capH + 4), ZIndex = 14 }, content)
		local por = makePortrait(pv, id, { ZIndex = 14, Size = UDim2.new(1, 0, 0, previewOn and 230 or 150) }, previewOn and 1 or 0, compact)
		detailPortrait = por
		table.insert(portraits, por)
		tryModel(por)
		Brief.label(pv, "Caption", previewOn and "PREVIEW: a turning model, nothing is chosen" or "Still picture. Press PREVIEW to turn it.", {
			Name = "PreviewCaption",
			AnchorPoint = Vector2.new(0, 1),
			Position = UDim2.new(0, 2, 1, 0),
			Size = UDim2.new(1, -4, 0, capH),
			TextTruncate = Enum.TextTruncate.AtEnd,
			ZIndex = 14,
		}, compact)

		paragraph(content, 2, d.Description, "Body")

		-- how to get it
		local acc = section(3, "HOW TO GET IT")
		if access then
			paragraph(acc, 2, access.Summary, "Body")
			if access.Goal and not owned then
				paragraph(acc, 3, "Goal: " .. access.Goal, "Body", T.Gold)
			end
			if access.Parts and #access.Parts > 0 and not owned then
				for i, line in ipairs(access.Parts) do
					paragraph(acc, 3 + i, "Progress: " .. line, "Label", T.CreamMuted)
				end
				if access.Fraction then
					local bar, setBar = Brief.bar(acc, { LayoutOrder = 10 })
					setBar(access.Fraction)
					bar.Name = "GoalBar"
				end
			elseif access.State ~= "Starter" and not owned and v == nil then
				paragraph(acc, 4, "Progress is still loading.", "Label", T.CreamMuted)
			end
		end

		-- the kit
		local w = section(4, "STARTING WEAPON")
		paragraph(w, 2, d.Weapon.Name, "Section")
		paragraph(w, 3, d.Weapon.Behavior, "Body")
		if #d.Weapon.Notes > 0 then
			paragraph(w, 4, "Rank 1: " .. table.concat(d.Weapon.Notes, "; ") .. ".", "Label", T.CreamMuted)
		end
		local p = section(5, "PASSIVE")
		paragraph(p, 2, d.Passive.Name, "Section")
		paragraph(p, 3, d.Passive.Behavior, "Body")
		local m = section(6, "MOVEMENT ABILITY")
		paragraph(m, 2, d.Movement.Name, "Section")
		paragraph(m, 3, d.Movement.Behavior, "Body")

		-- measurements
		local st = section(7, "BASE STATS  -  " .. string.upper(d.BaseNote))
		local grid = new("Frame", { Name = "Stats", BackgroundTransparency = 1, LayoutOrder = 2, Size = UDim2.new(1, 0, 0, 10), AutomaticSize = Enum.AutomaticSize.Y, ZIndex = 14 }, st)
		local cellH = compact and 104 or 96
		new("UIGridLayout", { SortOrder = Enum.SortOrder.LayoutOrder, CellPadding = UDim2.fromOffset(8, 8), CellSize = UDim2.new(0.5, -4, 0, cellH) }, grid)
		for i, s in ipairs(d.Stats) do
			local cell = new("Frame", { Name = "Stat_" .. s.Key, BackgroundColor3 = T.NavyRaised, BorderSizePixel = 0, LayoutOrder = i, ZIndex = 14 }, grid)
			UIKit.corner(cell, 10)
			Brief.label(cell, "Caption", string.upper(s.Label), { Position = UDim2.fromOffset(10, 6), Size = UDim2.new(1, -20, 0, 18), TextTruncate = Enum.TextTruncate.AtEnd, ZIndex = 15 }, compact)
			if s.Hidden then
				Brief.label(cell, "Label", "Not shown", { Position = UDim2.fromOffset(10, 26), Size = UDim2.new(1, -20, 0, 24), ZIndex = 15, TextColor3 = T.CreamFaint }, compact)
				Brief.label(cell, "Caption", s.Hidden, { Position = UDim2.fromOffset(10, 50), Size = UDim2.new(1, -20, 0, cellH - 54), TextWrapped = true, TextYAlignment = Enum.TextYAlignment.Top, ZIndex = 15 }, compact)
			else
				Brief.label(cell, "Section", (s.Value or "") .. (s.Unit and (" " .. s.Unit) or ""), { Name = "Value", Position = UDim2.fromOffset(10, 24), Size = UDim2.new(1, -20, 0, 32), TextTruncate = Enum.TextTruncate.AtEnd, ZIndex = 15 }, compact)
				if s.Note then
					Brief.label(cell, "Caption", s.Note, { Position = UDim2.fromOffset(10, 58), Size = UDim2.new(1, -20, 0, cellH - 62), TextWrapped = true, TextYAlignment = Enum.TextYAlignment.Top, ZIndex = 15 }, compact)
				end
			end
		end
		paragraph(st, 3, "Base values before upgrades. Hero Mastery, passives and items found in a run change them.", "Caption", T.CreamFaint)

		-- the action notes (why a button is off, pending text, the last refusal)
		local pl = plan(id)
		if notice then
			Brief.note(actionNote, notice.Kind, notice.Text, { LayoutOrder = 1 }, compact)
		end
		if pl.Note then
			Brief.note(actionNote, pl.NoteKind or "Info", pl.Note, { LayoutOrder = 2 }, compact)
		end
	end

	local function applyButtons()
		local pl = plan(inspected)
		mainBtn.SetText(pl.Title)
		mainBtn.SetKind(pl.Kind)
		mainBtn.SetEnabled(pl.Enabled)
		mainBtn.SetPending(pl.Pending, pl.Title)
		previewBtn.SetText(previewOn and "STOP PREVIEW" or "PREVIEW")
		previewBtn.SetKind(previewOn and "Selected" or "Secondary")
		leaveBtn.Instance.Visible = queued() and not committed()
	end

	-- layout --------------------------------------------------------------------------------------
	local function place(obj: GuiObject, x: number, y: number, w: number, h: number)
		obj.Position = UDim2.fromOffset(x, y)
		obj.Size = UDim2.fromOffset(w, h)
	end

	-- rough height of the action notes at `width` (text wraps; generous so buttons are never covered)
	local function notesHeight(width: number): number
		local size = Brief.size("Body", compact)
		local h = 0
		local function add(text: string)
			local perLine = math.max(8, math.floor((width - (size + 10)) / (size * 0.56)))
			h += math.ceil(#text / perLine) * (size + 6) + 6
		end
		if notice then
			add(notice.Text)
		end
		local pl = plan(inspected)
		if pl.Note then
			add(pl.Note)
		end
		return h
	end

	local function layout(c: Kit.Ctx)
		compact = c.Compact
		local newMode = compact and (c.Portrait and "PhonePortrait" or "PhoneLandscape") or "Wide"
		if newMode ~= mode then
			mode = newMode
			if mode == "Wide" then
				screen = "Grid"
			end
		end
		local m = (mode == "Wide") and Brief.Margin.Desktop or Brief.Margin.Mobile
		local pw = (mode == "Wide") and math.min(c.W - 2 * m, 1180) or (c.W - 2 * m)
		local ph = (mode == "Wide") and math.min(c.H - 2 * m, 700) or (c.H - 2 * m)
		panel.Size = UDim2.fromOffset(pw, ph)
		local ip = (mode == "Wide") and 18 or 12
		local innerW = pw - 2 * ip
		local hh = (mode == "PhoneLandscape") and 52 or 56
		local isDetails = mode ~= "Wide" and screen == "Details"

		-- header (title / BACK on the left, gold and close on the right)
		place(header, ip, ip, innerW, hh)
		title.Visible = not isDetails
		backBtn.Instance.Visible = isDetails
		title.TextSize = (mode == "PhoneLandscape") and 28 or Brief.size("Title", compact)
		place(title, 0, 4, (mode == "PhoneLandscape") and 180 or 220, 44)
		place(closeBtn.Instance, innerW - 48, 4, 48, 48)
		place(backBtn.Instance, 0, 4, 120, 48)
		goldLabel.TextSize = Brief.size("Section", compact)
		place(goldLabel, innerW - 48 - 8 - 190, 8, 190, 36)
		goldLabel.Visible = mode ~= "PhoneLandscape" and not (isDetails and mode == "PhonePortrait")

		local bodyY = ip + hh + 8
		local bodyH = ph - bodyY - ip
		local gridW, gridH
		local gy = bodyY
		if mode == "Wide" then
			local gridColW = math.floor(innerW * 0.58)
			cols = 3
			rowStyle = false
			place(tabRow, ip, bodyY, gridColW, 48)
			place(pagerRow, ip, bodyY + bodyH - 48, gridColW, 48)
			gridW = gridColW
			gy = bodyY + 48 + 10
			gridH = bodyH - 2 * (48 + 10)
			rows = math.clamp(math.floor((gridH + 12) / (190 + 12)), 1, 4)
			place(details, ip + gridColW + 16, bodyY, innerW - gridColW - 16, bodyH)
			details.Visible = true
		elseif mode == "PhoneLandscape" then
			-- one header row: title, tabs, pager, close; the grid gets everything below it
			cols = 2
			rowStyle = true
			place(tabRow, ip + 190, ip + 2, 232, 48)
			place(pagerRow, ip + 190 + 232 + 8, ip + 2, 192, 48)
			gridW = innerW
			gridH = bodyH
			rows = math.clamp(math.floor((gridH + 12) / (84 + 12)), 1, 4)
			place(details, ip, bodyY, innerW, bodyH)
			details.Visible = isDetails
		else
			cols = 2
			rowStyle = false
			place(tabRow, ip, bodyY, 232, 48)
			place(pagerRow, ip + innerW - 192, bodyY, 192, 48)
			gridW = innerW
			gy = bodyY + 48 + 10
			gridH = bodyH - 48 - 10
			rows = math.clamp(math.floor((gridH + 12) / (190 + 12)), 1, 4)
			place(details, ip, bodyY, innerW, bodyH)
			details.Visible = isDetails
		end
		cardW = math.floor((gridW - (cols - 1) * 12) / cols)
		cardH = math.floor((gridH - (rows - 1) * 12) / rows)
		cardH = math.min(cardH, rowStyle and 110 or 260)
		perPage = cols * rows
		place(gridHost, ip, gy, gridW, gridH)
		local showGrid = mode == "Wide" or not isDetails
		gridHost.Visible = showGrid
		tabRow.Visible = showGrid
		pagerRow.Visible = showGrid
		-- tab and pager buttons (centred in their rows)
		place(tabButtons.All.Instance, 0, 0, 104, 48)
		place(tabButtons.Owned.Instance, 112, 0, 120, 48)
		local prw = pagerRow.Size.X.Offset
		local px0 = math.floor((prw - 192) / 2)
		place(prevBtn.Instance, px0, 0, 48, 48)
		place(pageLabel, px0 + 56, 0, 80, 48)
		place(nextBtn.Instance, px0 + 144, 0, 48, 48)
		pageLabel.TextSize = Brief.size("Label", compact)

		-- the details view
		local dw, dh = details.Size.X.Offset, details.Size.Y.Offset
		leaveBtn.Instance.Visible = queued() and not committed()
		local hasLeave = leaveBtn.Instance.Visible
		if mode == "PhoneLandscape" then
			-- left: name, notes, buttons stacked; right: the scrolling text
			local lw = math.floor(dw * 0.42)
			place(detailHead, 0, 0, lw, headH)
			local nh = notesHeight(lw)
			place(actions, 0, headH + 6, lw, nh + 8 + 56 + 8 + 48)
			place(actionNote, 0, 0, lw, nh)
			place(actionRow, 0, nh + 8, lw, 56 + 8 + 48)
			place(mainBtn.Instance, 0, 0, lw, 56)
			if hasLeave then
				local half = math.floor((lw - 8) / 2)
				place(previewBtn.Instance, 0, 64, half, 48)
				place(leaveBtn.Instance, half + 8, 64, lw - half - 8, 48)
			else
				place(previewBtn.Instance, 0, 64, lw, 48)
			end
			place(scroll, lw + 12, 0, dw - lw - 12, dh)
		else
			local nh = notesHeight(dw)
			local actionsH = nh + (nh > 0 and 8 or 0) + 56
			place(detailHead, 0, 0, dw, headH)
			place(actions, 0, dh - actionsH, dw, actionsH)
			place(actionNote, 0, 0, dw, nh)
			place(actionRow, 0, actionsH - 56, dw, 56)
			place(scroll, 0, headH + 6, dw, math.max(60, dh - headH - 6 - actionsH - 8))
			local pwid = hasLeave and math.floor(dw * 0.26) or math.floor(dw * 0.34)
			place(previewBtn.Instance, 0, 0, pwid, 56)
			local used = pwid + 8
			if hasLeave then
				local lwid = math.floor(dw * 0.34)
				place(leaveBtn.Instance, used, 0, lwid, 56)
				used += lwid + 8
			end
			place(mainBtn.Instance, used, 0, dw - used, 56)
		end

		-- the purchase confirmation
		local ch = compact and 340 or 320
		local cw = math.min(460, c.W - 24)
		confirmPanel.Size = UDim2.fromOffset(cw, ch)
		place(confirmYes.Instance, 20, ch - (56 + 20 + 56 + 8), cw - 40, 56)
		place(confirmNo.Instance, 20, ch - (56 + 20), cw - 40, 56)
		confirmBody.TextSize = Brief.size("Body", compact)
		confirmTitle.TextSize = Brief.size("Section", compact)
		gridSig, detailSig = "", ""
	end

	-- buttons (built once) ---------------------------------------------------------------------
	closeBtn = Brief.button(header, { Name = "ClassClose", Title = "", Icon = "close", Size = UDim2.fromOffset(48, 48), ZIndex = 14, Kind = "Secondary", OnClick = function()
		close()
	end })
	backBtn = Brief.button(header, { Name = "ClassBack", Title = "BACK", Icon = "chevronLeft", Size = UDim2.fromOffset(120, 48), ZIndex = 14, Kind = "Secondary", OnClick = function()
		screen = "Grid"
		ctxRefresh()
		Brief.focusIfGamepad(cardButtons[inspected])
	end })
	backBtn.Instance.Visible = false
	for i, f in ipairs(FILTERS) do
		tabButtons[f] = Brief.button(tabRow, { Name = "ClassTab_" .. f, Title = string.upper(f), Size = UDim2.fromOffset(110, 48), LayoutOrder = i, ZIndex = 13, Kind = f == filter and "Selected" or "Secondary", OnClick = function()
			filter = f
			-- keep the highlighted card on screen when it is still in the list, else go to page 1
			local list = filtered()
			local at = table.find(list, inspected)
			if at then
				page = math.ceil(at / math.max(1, perPage))
			else
				page = 1
				inspected = list[1] or ClassCatalog.Default
			end
			ctxRefresh()
		end })
	end
	prevBtn = Brief.button(pagerRow, { Name = "ClassPagePrev", Title = "", Icon = "chevronLeft", Size = UDim2.fromOffset(48, 48), ZIndex = 13, OnClick = function()
		page = math.max(1, page - 1)
		ctxRefresh()
	end })
	nextBtn = Brief.button(pagerRow, { Name = "ClassPageNext", Title = "", Icon = "chevronRight", Size = UDim2.fromOffset(48, 48), ZIndex = 13, OnClick = function()
		page += 1
		ctxRefresh()
	end })
	previewBtn = Brief.button(actionRow, { Name = "ClassPreview", Title = "PREVIEW", Size = UDim2.fromOffset(150, 56), ZIndex = 14, Kind = "Secondary", OnClick = function()
		previewOn = not previewOn
		ctxRefresh()
	end })
	leaveBtn = Brief.button(actionRow, { Name = "ClassLeaveQueue", Title = "LEAVE QUEUE", TitleSize = 16, Size = UDim2.fromOffset(150, 56), ZIndex = 14, Kind = "Danger", OnClick = function()
		ctx.Fire("QueueAction", "Leave")
	end })
	leaveBtn.Instance.Visible = false
	mainBtn = Brief.button(actionRow, { Name = "ClassMain", Title = "SELECT", Size = UDim2.fromOffset(200, 56), ZIndex = 14, Kind = "Primary", TitleSize = 20, OnClick = function()
		local pl = plan(inspected)
		if not pl.Enabled or not pl.Action then
			return
		end
		if pl.Action == "Select" then
			fireAction("Select", inspected)
			ctxRefresh()
		elseif pl.Action == "BuyConfirm" then
			confirming = inspected
			ctxRefresh()
		end
	end })
	confirmYes = Brief.button(confirmPanel, { Name = "ConfirmBuy", Title = "BUY", Size = UDim2.fromOffset(400, 56), ZIndex = 33, Kind = "Primary", TitleSize = 20, OnClick = function()
		local id = confirming
		confirming = nil
		confirmDim.Visible = false
		if id then
			fireAction("Buy", id)
			ctxRefresh()
		end
	end })
	confirmNo = Brief.button(confirmPanel, { Name = "ConfirmCancel", Title = "CANCEL", Size = UDim2.fromOffset(400, 56), ZIndex = 33, Kind = "Secondary", OnClick = function()
		confirming = nil
		confirmDim.Visible = false
	end })
	dim.Activated:Connect(function()
		close()
	end)
	confirmDim.Activated:Connect(function()
		confirming = nil
		confirmDim.Visible = false
	end)

	-- render ----------------------------------------------------------------------------------------
	-- a pending choice resolves on the server's word: ClassAck.N moved on for that class
	local function resolvePending(c: Kit.Ctx)
		local pend = pending
		local v: any = c.View
		if not pend or not v then
			return
		end
		local ack = v.ClassAck
		local answered = ack ~= nil and ack.N > pend.N0 and ack.Id == pend.Id
		if answered and ack.Ok ~= true then
			pending = nil
			local why: string = ack.Code or "ERROR"
			local text = ({
				NOT_OWNED = "You do not own " .. nameOf(pend.Id) .. " yet.",
				NO_GOLD = "Not enough gold for " .. nameOf(pend.Id) .. ".",
				GOAL_ONLY = nameOf(pend.Id) .. " is earned in runs; it cannot be bought.",
				LOCKED = "Your class is locked while the run starts.",
				UNKNOWN_CLASS = "That class is not available.",
			} :: any)[why] or "The server could not change your class."
			local current = v.Selected or ClassCatalog.Default
			setNotice("Error", text .. " Still using " .. nameOf(current) .. ".")
			c.Toast(text, "warn")
		elseif (answered and v.Selected == pend.Id) or (v.Selected == pend.Id and ownedNow(pend.Id)) then
			pending = nil
			c.Toast(nameOf(pend.Id) .. (pend.Action == "Buy" and " unlocked and selected" or " selected"), "good")
		elseif answered then
			pending = nil -- it worked, but another class is selected now: nothing to say
		end
	end

	local function render(c: Kit.Ctx)
		lastView = c.View
		compact = c.Compact
		resolvePending(c)
		local v: any = c.View
		-- lock chip next to the title (queued / locked): words and an icon (wide screens; phones get the note)
		if lockChip then
			lockChip:Destroy()
			lockChip = nil
		end
		if v and (queued() or committed()) and mode == "Wide" then
			lockChip = Brief.badge(header, "Info", committed() and "CLASS LOCKED" or "IN QUEUE  |  CLASS LOCKED", { Name = "LockChip", Position = UDim2.fromOffset(250, 8), ZIndex = 14 }, compact)
		end
		goldLabel.Text = v and ("GOLD " .. thousands(v.Gold or 0)) or "GOLD ..."
		if isOpen and v and v.Queue and v.Queue.State == "Teleporting" then
			close() -- an active transfer is never covered
			return
		end
		-- the confirmation text
		if confirming then
			local info = ClassCatalog.Get(confirming)
			local gold: number = v and v.Gold or 0
			if info and v then
				confirmTitle.Text = "Buy " .. info.Name .. "?"
				confirmBody.Text = string.format("Price: %s gold, paid once from your account gold.\nYou have %s gold and will have %s left.\nOutcome: %s is unlocked for good and becomes your class. Nothing here is bought with Robux.", thousands(info.Cost), thousands(gold), thousands(math.max(0, gold - info.Cost)), info.Name)
				confirmYes.SetText("BUY FOR " .. thousands(info.Cost) .. " GOLD")
				confirmYes.SetEnabled(gold >= info.Cost and pending == nil and not queued() and not committed())
				confirmDim.Visible = true
			else
				confirming = nil
				confirmDim.Visible = false
			end
		else
			confirmDim.Visible = false
		end
		-- grid and details are rebuilt only when something they show changed
		local g = { mode, filter, tostring(page), inspected, screen, tostring(cardW), tostring(cardH), tostring(perPage), tostring(rowStyle), tostring(compact) }
		local d = { inspected, previewOn and "pv" or "still", pending and (pending.Id .. pending.Action) or "-", notice and notice.Text or "-", mode, tostring(compact), screen }
		if v then
			local sel = tostring(v.Selected)
			table.insert(g, sel)
			table.insert(d, sel)
			table.insert(d, tostring(math.floor(v.Gold or 0)))
			table.insert(d, tostring(v.ClassLocked == true))
			table.insert(d, v.Queue and tostring(v.Queue.State) or "-")
			for _, id in ipairs(ClassCatalog.Order) do
				local o = (v.Owned and v.Owned[id]) and "1" or "0"
				table.insert(g, o)
				table.insert(d, o)
				local pr = v.Progress and v.Progress[id]
				if pr then
					local line = tostring(pr.Have)
					if pr.Parts then
						for _, part in ipairs(pr.Parts) do
							line ..= "," .. tostring(part.Have)
						end
					end
					table.insert(g, line)
					table.insert(d, id .. line)
				end
			end
		else
			table.insert(g, "noview")
			table.insert(d, "noview")
		end
		local gs, ds = table.concat(g, "|"), table.concat(d, "|")
		if gs ~= gridSig then
			gridSig = gs
			rebuildGrid()
		end
		if ds ~= detailSig then
			rebuildDetails()
			applyButtons()
			layout(c) -- the action area follows its notes
			gridSig, detailSig = gs, ds
		else
			applyButtons()
		end
	end
	ctxRefresh = function()
		layout(ctx)
		render(ctx)
	end

	local sheet: Sheet = {
		Overlay = overlay,
		Open = function()
			if isOpen then
				return
			end
			isOpen = true
			overlay.Visible = true
			layout(ctx)
			-- the highlighted class keeps its filter and page from last time; a first visit starts on the class in use
			local v: any = lastView
			if v and v.Selected and ClassCatalog.Get(v.Selected) and not table.find(filtered(), inspected) then
				inspected = v.Selected
			end
			local at = table.find(filtered(), inspected)
			if at then
				page = math.ceil(at / math.max(1, perPage))
			end
			render(ctx)
			Brief.focusIfGamepad(cardButtons[inspected])
		end,
		Close = function()
			close()
		end,
		IsOpen = function(): boolean
			return isOpen
		end,
	}

	local self: Panel
	self = {
		Sheet = sheet,
		Layout = function(c: Kit.Ctx)
			layout(c)
			if isOpen then
				render(c)
			end
		end,
		Render = function(c: Kit.Ctx)
			lastView = c.View
			if isOpen then
				render(c)
			else
				resolvePending(c)
			end
		end,
		Step = function(_c: Kit.Ctx)
			if not isOpen then
				return
			end
			local now = os.clock()
			local pend = pending
			if pend and now - pend.At > PENDING_SECONDS then
				local current = lastView and lastView.Selected or ClassCatalog.Default
				pending = nil
				setNotice("Error", "The server did not confirm " .. nameOf(pend.Id) .. ". Still using " .. nameOf(current) .. ". Try again in a moment.")
				ctxRefresh()
			end
			if now >= pollAt then
				pollAt = now + 0.5
				for i = #portraits, 1, -1 do
					local por = portraits[i]
					if not por.Frame.Parent then
						table.remove(portraits, i)
					elseif not por.Done then
						tryModel(por)
					end
				end
			end
		end,
		Back = function(): boolean
			if not isOpen then
				return false
			end
			if confirming then
				confirming = nil
				confirmDim.Visible = false
				return true
			end
			if mode ~= "Wide" and screen == "Details" then
				screen = "Grid"
				ctxRefresh()
				Brief.focusIfGamepad(cardButtons[inspected])
				return true
			end
			close()
			return true
		end,
		State = function(): { [string]: any }
			return {
				Open = isOpen,
				Mode = mode,
				Filter = filter,
				Page = page,
				Inspected = inspected,
				Screen = screen,
				Pending = pending ~= nil and pending.Id or nil,
				Confirming = confirming,
				PerPage = perPage,
				PreviewOn = previewOn,
				Notice = notice ~= nil and notice.Text or nil,
			}
		end,
	}
	return self
end

return ClassBrowser
