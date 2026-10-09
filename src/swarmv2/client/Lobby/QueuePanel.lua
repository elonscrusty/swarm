--!strict
--[[
	SwarmV2Client/Lobby/QueuePanel.lua
	OWNER: lobby track (Chat 1). The PLAY button, the gate sheet (live gate boards + JOIN) and
	the queue panel (members, READY / LEAVE, countdown, state lines). Everything is a request
	to the server through QueueAction; what is shown comes from LobbyState and the gate boards.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Kit = require(script.Parent.Kit)
local V2 = ReplicatedStorage:WaitForChild("SwarmV2")
local LobbyNet = require(V2:WaitForChild("Lobby"):WaitForChild("LobbyNet"))
local LobbyConfig = require(V2:WaitForChild("Lobby"):WaitForChild("LobbyConfig"))
local ClassCatalog = require(V2:WaitForChild("ClassCatalog"))

local UIKit, Theme, C = Kit.UIKit, Kit.Theme, Kit.C
local new = UIKit.new

local QueuePanel = {}

export type Panel = {
	Play: any,
	Queue: Frame,
	Sheet: Kit.Sheet,
	Layout: (ctx: Kit.Ctx) -> (),
	Render: (ctx: Kit.Ctx) -> (),
	Step: (ctx: Kit.Ctx) -> (),
}

local MODE_LINES = {
	Public = "Recruit match: others from camp can join (up to 4).",
	Party = "Party match: only you and your party play.",
}

local STATE_TEXT = {
	Open = "OPEN",
	Countdown = "STARTING",
	Launching = "LAUNCHING",
	Full = "FULL",
}

local function gateDef(id: string): LobbyConfig.GateDef?
	for _, g in ipairs(LobbyConfig.Gates) do
		if g.Id == id then
			return g
		end
	end
	return nil
end

local function className(id: string): string
	local info = ClassCatalog.Get(id)
	return info and info.Name or id
end

function QueuePanel.Build(ctx: Kit.Ctx): Panel
	------------------------------------------------------------------ PLAY
	local play = Kit.btn(ctx.Root, {
		Kind = "Primary",
		Title = "PLAY",
		TitleSize = 34,
		Icon = "play",
		IconSize = 30,
		Size = UDim2.fromOffset(230, 84),
		AnchorPoint = Vector2.new(1, 1),
		Position = UDim2.new(1, -Kit.M, 1, -Kit.M),
		Name = "PlayButton",
		Depth = "Strong",
		Radius = Theme.Radius.L,
		ZIndex = 3,
		OnClick = function()
			ctx.OpenSheet("Gates")
		end,
	})

	------------------------------------------------------------------ gate sheet
	local sheet = Kit.sheet(ctx.Root, "GateSheet", "CHOOSE A GATE", function()
		ctx.OpenSheet(nil)
	end)
	local info = Kit.txt(sheet.Body, "Small", "", {
		Name = "Modes",
		Size = UDim2.new(1, 0, 0, 40),
		TextWrapped = true,
		TextYAlignment = Enum.TextYAlignment.Top,
		TextColor3 = C.Text,
		ZIndex = 12,
	}, 14)
	info.Text = "RECRUIT: other players from this camp can join, up to 4.\nPARTY: only you and your party play together."
	local rows = new("ScrollingFrame", {
		Name = "Gates",
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		Position = UDim2.fromOffset(0, 44),
		Size = UDim2.new(1, 0, 1, -44 - 30),
		CanvasSize = UDim2.new(),
		AutomaticCanvasSize = Enum.AutomaticSize.Y,
		ScrollBarThickness = 4,
		ZIndex = 12,
	}, sheet.Body)
	new("UIListLayout", { SortOrder = Enum.SortOrder.LayoutOrder, Padding = UDim.new(0, 6) }, rows)
	Kit.txt(sheet.Body, "BodyStrong", "Or walk onto a gate pad.", {
		Name = "PadNote",
		AnchorPoint = Vector2.new(0, 1),
		Position = UDim2.fromScale(0, 1),
		Size = UDim2.new(1, 0, 0, 26),
		TextXAlignment = Enum.TextXAlignment.Center,
		TextColor3 = C.BlueDeep,
		ZIndex = 12,
	}, 16)

	type GateRow = { Id: string, Count: TextLabel, Join: any }
	local gateRows: { GateRow } = {}

	local function buildGateRows(c: Kit.Ctx)
		Kit.clear(rows)
		gateRows = {}
		local rowW = math.min(c.W - 2 * Kit.M, 760) - 28
		for i, g in ipairs(LobbyConfig.Gates) do
			local f = new("Frame", {
				Name = "Gate_" .. g.Id,
				LayoutOrder = i,
				Size = UDim2.new(1, -6, 0, 84),
				BackgroundColor3 = C.PanelRaised,
				BorderSizePixel = 0,
				ZIndex = 13,
			}, rows)
			UIKit.corner(f, Theme.Radius.M)
			UIKit.stroke(f, C.PanelEdge, 2, 0)
			local textW = rowW - 6 - 146
			Kit.txt(f, "H3", g.Label, {
				Name = "Label",
				Position = UDim2.fromOffset(12, 6),
				Size = UDim2.fromOffset(textW, 26),
				TextTruncate = Enum.TextTruncate.AtEnd,
				ZIndex = 14,
			}, 19)
			Kit.txt(f, "Small", g.Hint, {
				Name = "Hint",
				Position = UDim2.fromOffset(12, 34),
				Size = UDim2.fromOffset(textW, 44),
				TextWrapped = true,
				TextYAlignment = Enum.TextYAlignment.Top,
				ZIndex = 14,
			}, 14)
			local count = Kit.txt(f, "Label", "", {
				Name = "Count",
				AnchorPoint = Vector2.new(1, 0),
				Position = UDim2.new(1, -10, 0, 6),
				Size = UDim2.fromOffset(124, 22),
				TextXAlignment = Enum.TextXAlignment.Center,
				TextColor3 = C.BlueDeep,
				ZIndex = 14,
			}, 14)
			local join = Kit.btn(f, {
				Kind = "Primary",
				Title = "JOIN",
				Size = UDim2.fromOffset(124, 48),
				AnchorPoint = Vector2.new(1, 1),
				Position = UDim2.new(1, -10, 1, -6),
				Name = "Join",
				Depth = "Medium",
				ZIndex = 15,
				OnClick = function()
					c.Fire("QueueAction", "Join", g.Id)
				end,
			})
			table.insert(gateRows, { Id = g.Id, Count = count, Join = join })
		end
	end

	local function stepGates()
		for _, r in ipairs(gateRows) do
			local board = LobbyNet.Gate(r.Id)
			local cnt: number = tonumber(board and board:GetAttribute("Count")) or 0
			local cap: number = tonumber(board and board:GetAttribute("Capacity")) or LobbyConfig.MaxPlayers
			local st: string = tostring(board and board:GetAttribute("State") or "Open")
			r.Count.Text = string.format("%d/%d  %s", cnt, cap, STATE_TEXT[st] or tostring(st))
			local can = st == "Open" or st == "Countdown"
			r.Join.SetEnabled(can)
			r.Join.SetKind(can and "Primary" or "Disabled")
		end
	end

	------------------------------------------------------------------ queue panel
	local holder, face = UIKit.Surface(ctx.Root, {
		Name = "QueuePanel",
		Size = UDim2.fromOffset(500, 260),
		AnchorPoint = Vector2.new(0.5, 1),
		Position = UDim2.new(0.5, 0, 1, -Kit.M),
		Radius = Theme.Radius.L,
		Depth = 4,
		Transparency = 0.02,
		ZIndex = 4,
		Visible = false,
	})
	local pad = new("Frame", { Name = "Pad", BackgroundTransparency = 1, Size = UDim2.fromScale(1, 1), ZIndex = 5 }, face)
	UIKit.pad(pad, 12)
	local gateLabel = Kit.txt(pad, "H2", "", { Name = "Gate", Size = UDim2.new(1, 0, 0, 28), TextTruncate = Enum.TextTruncate.AtEnd, ZIndex = 5 }, 21)
	local modeLine = Kit.txt(pad, "Small", "", { Name = "Mode", Position = UDim2.fromOffset(0, 28), Size = UDim2.new(1, 0, 0, 20), TextTruncate = Enum.TextTruncate.AtEnd, ZIndex = 5 }, 14)
	local members = new("Frame", { Name = "Members", BackgroundTransparency = 1, Position = UDim2.fromOffset(0, 54), Size = UDim2.new(1, 0, 0, 88), ZIndex = 5 }, pad)
	local grid = new("UIGridLayout", {
		SortOrder = Enum.SortOrder.LayoutOrder,
		CellPadding = UDim2.fromOffset(6, 4),
		CellSize = UDim2.new(0.5, -3, 0, 40),
	}, members)
	local status = Kit.txt(pad, "H3", "", { Name = "Status", Size = UDim2.new(1, 0, 0, 28), TextXAlignment = Enum.TextXAlignment.Center, ZIndex = 5 }, 19)
	local message = Kit.txt(pad, "Small", "", { Name = "Message", Size = UDim2.new(1, 0, 0, 20), TextXAlignment = Enum.TextXAlignment.Center, TextColor3 = C.TextDanger, TextTruncate = Enum.TextTruncate.AtEnd, Visible = false, ZIndex = 5 }, 14)
	local buttons = new("Frame", { Name = "Buttons", BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 56), AnchorPoint = Vector2.new(0, 1), Position = UDim2.fromScale(0, 1), ZIndex = 5 }, pad)
	local readyNow = false
	local ready = Kit.btn(buttons, {
		Kind = "Primary",
		Title = "READY",
		TitleSize = 24,
		Size = UDim2.new(0.62, -4, 1, 0),
		Name = "Ready",
		Depth = "Medium",
		ZIndex = 6,
		OnClick = function()
			ctx.Fire("QueueAction", "Ready", not readyNow)
		end,
	})
	local leave = Kit.btn(buttons, {
		Kind = "Danger",
		Title = "LEAVE",
		Size = UDim2.new(0.38, -4, 1, 0),
		AnchorPoint = Vector2.new(1, 0),
		Position = UDim2.fromScale(1, 0),
		Name = "Leave",
		Depth = "Medium",
		ZIndex = 6,
		OnClick = function()
			ctx.Fire("QueueAction", "Leave")
		end,
	})

	local msig = ""
	local lastQ: any? = nil

	local lockedNow = false
	local function layoutQueue(c: Kit.Ctx, nMembers: number, hasMsg: boolean)
		local cols = c.Portrait and 1 or 2
		grid.CellSize = UDim2.new(1 / cols, -(cols == 2 and 3 or 0), 0, 40)
		local rowsN = math.max(1, math.ceil(math.max(1, nMembers) / cols))
		local memH = rowsN * 40 + (rowsN - 1) * 4
		members.Size = UDim2.new(1, 0, 0, memH)
		local y = 54 + memH + 6
		status.Position = UDim2.fromOffset(0, y)
		y += 30
		message.Visible = hasMsg
		message.Position = UDim2.fromOffset(0, y)
		if hasMsg then
			y += 22
		end
		local h = y + 6 + (lockedNow and 0 or 56) + 24
		holder.Size = UDim2.fromOffset(math.min(c.W - 2 * Kit.M, c.Portrait and 480 or 500), h)
	end

	local function memberChip(m: any, order: number, isMe: boolean)
		local f = new("Frame", {
			Name = "M" .. order,
			LayoutOrder = order,
			BackgroundColor3 = isMe and C.SelectedPale or C.PanelRaised,
			BorderSizePixel = 0,
			ZIndex = 6,
		}, members)
		UIKit.corner(f, Theme.Radius.S)
		UIKit.stroke(f, m.Ready and C.SelectedEdge or C.PanelEdge, 2, 0)
		local x = 8
		if m.Leader then
			Kit.Icons.Draw(f, "crown", { Size = 20, Color = C.Coin, Position = UDim2.fromOffset(x, 10), ZIndex = 7, Name = "Crown" })
			x += 24
		end
		Kit.txt(f, "BodyStrong", m.Name, {
			Name = "Name",
			Position = UDim2.fromOffset(x, 2),
			Size = UDim2.new(1, -(x + 84), 0, 20),
			TextTruncate = Enum.TextTruncate.AtEnd,
			ZIndex = 7,
		}, 15)
		Kit.txt(f, "Caption", string.upper(className(m.ClassId)), {
			Name = "Class",
			Position = UDim2.fromOffset(x, 21),
			Size = UDim2.new(1, -(x + 84), 0, 16),
			TextTruncate = Enum.TextTruncate.AtEnd,
			ZIndex = 7,
		}, 12)
		Kit.txt(f, "Label", m.Ready and "READY" or "", {
			Name = "ReadyTick",
			AnchorPoint = Vector2.new(1, 0.5),
			Position = UDim2.new(1, -6, 0.5, 0),
			Size = UDim2.fromOffset(52, 24),
			TextXAlignment = Enum.TextXAlignment.Center,
			TextColor3 = m.Ready and C.Success or C.TextFaint,
			ZIndex = 7,
		}, 13)
		if m.Ready then
			Kit.Icons.Draw(f, "check", { Size = 14, Color = C.Success, Position = UDim2.new(1, -78, 0.5, -7), ZIndex = 7, Name = "Tick" })
		end
	end

	local panel: Panel
	panel = {
		Play = play,
		Queue = holder,
		Sheet = sheet,
		Layout = function(c: Kit.Ctx)
			local avail = math.min(c.W - 2 * Kit.M, 760)
			local rowsH = #LobbyConfig.Gates * 90
			local want = 28 + 58 + 44 + rowsH + 30
			sheet.Resize(avail, math.min(want, c.H - 2 * Kit.M))
			info.Size = UDim2.new(1, 0, 0, c.Portrait and 56 or 40)
			rows.Position = UDim2.fromOffset(0, c.Portrait and 60 or 44)
			rows.Size = UDim2.new(1, 0, 1, -(c.Portrait and 60 or 44) - 30)
			buildGateRows(c)
			stepGates()
			play.Instance.Position = UDim2.new(1, -Kit.M, 1, -Kit.M - (c.Touch and 90 or 0))
			msig = ""
			if lastQ then
				layoutQueue(c, #lastQ.Members, lastQ.Message ~= nil and lastQ.Message ~= "")
			end
		end,
		Render = function(c: Kit.Ctx)
			local v = c.View
			local q = v and v.Queue
			lastQ = q
			play.Instance.Visible = q == nil and v ~= nil
			holder.Visible = q ~= nil
			if not q then
				return
			end
			local def = gateDef(q.GateId)
			gateLabel.Text = def and def.Label or q.GateId
			modeLine.Text = MODE_LINES[q.Mode] or ""
			local locked = q.State == "Committed" or q.State == "Teleporting"
			if locked ~= lockedNow then
				lockedNow = locked
				msig = ""
			end
			ready.Instance.Visible = not locked
			leave.Instance.Visible = not locked
			local me = Kit.me().UserId
			local mine = false
			for _, m in ipairs(q.Members) do
				if m.UserId == me then
					mine = m.Ready
				end
			end
			readyNow = mine
			ready.SetText(mine and "NOT READY" or "READY", nil)
			ready.SetKind(mine and "Secondary" or "Primary")
			local hasMsg = q.Message ~= nil and q.Message ~= ""
			message.Text = hasMsg and (q.Message :: string) or ""
			local parts = { tostring(c.Portrait), tostring(#q.Members), tostring(hasMsg) }
			for _, m in ipairs(q.Members) do
				table.insert(parts, string.format("%d:%s:%s:%s", m.UserId, m.ClassId, tostring(m.Ready), tostring(m.Leader)))
			end
			local s = table.concat(parts, "|")
			if s ~= msig then
				msig = s
				Kit.clear(members)
				for i, m in ipairs(q.Members) do
					memberChip(m, i, m.UserId == me)
				end
				layoutQueue(c, #q.Members, hasMsg)
			end
			-- buttons sit at the bottom of the (re-sized) panel
			buttons.Visible = not locked
		end,
		Step = function(c: Kit.Ctx)
			if sheet.IsOpen() then
				stepGates()
			end
			local q = c.View and c.View.Queue
			if not q then
				return
			end
			local readyCount = 0
			for _, m in ipairs(q.Members) do
				if m.Ready then
					readyCount += 1
				end
			end
			local text = ""
			local color = C.Text
			if q.State == "Countdown" then
				local left = math.max(0, math.ceil((q.EndsAt or 0) - workspace:GetServerTimeNow()))
				text = "STARTING IN " .. tostring(left)
				color = C.Success
			elseif q.State == "Committed" then
				text = "Match found. Get ready!"
				color = C.BlueDeep
			elseif q.State == "Teleporting" then
				text = "Teleporting now"
				color = C.BlueDeep
			elseif q.State == "Failed" then
				text = "Could not start the run."
				color = C.TextDanger
			else
				text = string.format("%d / %d ready", readyCount, #q.Members)
				if q.Mode == "Public" and #q.Members < q.Capacity then
					text ..= string.format("  -  room for %d more", q.Capacity - #q.Members)
				end
			end
			status.Text = text
			status.TextColor3 = color
		end,
	}
	return panel
end

return QueuePanel
