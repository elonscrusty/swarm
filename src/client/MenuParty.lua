--[[
	MenuParty.lua
	The PARTY screen (lobby PARTY button) and the invite card. Friends group up here; when
	the party leader starts SOLO / DUO / TRIO (or the Daily) the members join that run at
	once, up to the mode's size (server PartyService + RunManager; nothing here is trusted).

	  left    YOUR PARTY n/max: open invites to you (ACCEPT / DECLINE), the members (round
	          head shot, display name, LEADER / READY / NOT READY pills, KICK for the leader,
	          your own READY toggle), open slots, a line on how party starts work, LEAVE PARTY
	          and the leader's START (the mode that fits the party; only when all are READY)
	  right   tabs THIS SERVER (everyone else on this server: status and INVITE / ACCEPT)
	          and FRIENDS (INVITE FRIENDS = Roblox's own invite prompt through SocialService,
	          and the friends online list; a friend playing SWARM on another server has JOIN,
	          which asks the server to teleport you there: PartyFollow)
	  card    a PartyInvite shows a small card at the top of the screen on any screen (also
	          during a run): who invites you, ACCEPT / DECLINE and the time left
	Only Roblox display names are shown, and there is no text input. The friends list comes
	from Player:GetFriendsOnline (pcall'd, cached Config.Party.FriendsCacheSeconds).
	MenuParty.Summary() feeds the home screen's PARTY button (size, pending invites, ready
	count) and its READY button (MenuParty.SetReady).
]]

local Players = game:GetService("Players")
local SocialService = game:GetService("SocialService")

local Shared = game:GetService("ReplicatedStorage"):WaitForChild("Shared")
local Config = require(Shared:WaitForChild("Config"))
local Theme = require(Shared:WaitForChild("Theme"))
local Remotes = require(Shared:WaitForChild("Remotes"))
local UIKit = require(script.Parent.UIKit)
local UIAnim = require(script.Parent.UIAnim)
local Icons = require(script.Parent.Icons)
local PartyLines = require(script.Parent.PartyLines)

local MenuParty = {}

local new, text, TS = UIKit.new, UIKit.text, UIKit.TS
local C, P = Theme.Color, Theme.Palette
local player = Players.LocalPlayer

local ROW_H = 56
local ROW_GAP = 6

type State = { LeaderId: number, Members: { { UserId: number, Name: string, Ready: boolean? } }, Max: number, Invites: { { FromId: number, FromName: string, Seconds: number } }, Sent: { number } }

local state: State = { LeaderId = 0, Members = {}, Max = 3, Invites = {}, Sent = {} }
local deadlines: { [number]: number } = {} -- invite from userId -> os.clock() it expires
local knownMembers: { [number]: boolean }? = nil -- party member ids at the last PartyState (PartyJoin sound)

local function place(obj: GuiObject, x: number, y: number, w: number, h: number)
	obj.Position = UDim2.fromOffset(math.floor(x + 0.5), math.floor(y + 0.5))
	obj.Size = UDim2.fromOffset(math.floor(w + 0.5), math.floor(h + 0.5))
end

local function openInvites(): { { FromId: number, FromName: string, Seconds: number } }
	local list = {}
	local now = os.clock()
	for _, inv in ipairs(state.Invites) do
		if (deadlines[inv.FromId] or 0) > now then
			table.insert(list, inv)
		end
	end
	return list
end

-- For the home PARTY button: members (0 = no party), max size, open invites, leader?
function MenuParty.Summary(): { Count: number, Max: number, Invites: number, Leader: boolean, MyReady: boolean, Ready: number, Others: number }
	local ready, others, mine = 0, 0, false
	for _, m in ipairs(state.Members) do
		if m.UserId ~= state.LeaderId then
			others += 1
			if m.Ready == true then
				ready += 1
				mine = mine or m.UserId == player.UserId
			end
		end
	end
	return { Count = #state.Members, Max = state.Max, Invites = #openInvites(), Leader = state.LeaderId == player.UserId, MyReady = mine, Ready = ready, Others = others }
end

-- A member's READY toggle (the home screen's READY button and the PARTY screen).
function MenuParty.SetReady(on: boolean)
	Remotes.Get("Party"):FireServer("Ready", on)
end

-- The lobby mode that takes the whole party (2 → Duo, 3 → Trio), or nil.
function MenuParty.PartyMode(): string?
	local n = #state.Members
	for _, id in ipairs(Config.Modes.Order) do
		local def = (Config.Modes :: any)[id]
		if def and def.MaxPlayers == n then
			return id
		end
	end
	return nil
end

local function inParty(): boolean
	return #state.Members > 0
end

local function isLeader(): boolean
	return state.LeaderId == player.UserId
end

local function sentTo(userId: number): boolean
	return table.find(state.Sent, userId) ~= nil
end

local function send(action: string, arg: number?)
	Remotes.Get("Party"):FireServer(action, arg)
end

-- Narrow lists (phones, stacked columns): row buttons lose their icons and shrink so the
-- name keeps room; set by the layout from the measured list widths.
local narrow = false

-- Width of a row button (narrow lists: smaller, icon-less unless it is icon-only).
local function bw(w: number, title: string): number
	if narrow and title ~= "" then
		-- never narrower than the word itself ("AC..." on phones)
		return math.max(76, #title * 16 + 30, w - 32)
	end
	return w
end

-- A small button on a row's right edge.
local function rowButton(parent: Instance, title: string, icon: string?, kind: string, w: number, x: number, onClick: () -> ()): any
	if narrow and title ~= "" then
		icon = nil
	end
	return UIKit.Button(parent, {
		Kind = kind,
		Title = title,
		Icon = icon,
		IconSize = 16,
		Align = "Center",
		Shadow = false,
		Size = UDim2.fromOffset(bw(w, title), 40),
		AnchorPoint = Vector2.new(1, 0.5),
		Position = UDim2.new(1, -x, 0.5, 0),
		Name = title,
		OnClick = onClick,
	})
end

-- Head shot, name and a status line; `right` = room kept for buttons.
local function personRow(parent: Instance, order: number, userId: number, name: string, sub: string, subColor: Color3?, right: number, gold: boolean?): Frame
	local f = UIKit.Panel(parent, { Name = "Row" .. order, LayoutOrder = order, Size = UDim2.new(1, 0, 0, ROW_H), ClipsDescendants = true }, true)
	f.BackgroundColor3 = gold and P.slate_800 or P.slate_950
	f.BackgroundTransparency = gold and 0.05 or 0.35
	if gold then
		UIKit.stroke(f, P.gold_400, 1.5, 0.15)
	end
	UIKit.Avatar(f, userId, 40, { AnchorPoint = Vector2.new(0, 0.5), Position = UDim2.new(0, 10, 0.5, 0) })
	text(f, "BodyStrong", name, {
		Name = "Name",
		Position = UDim2.fromOffset(60, 7),
		Size = UDim2.new(1, -(68 + right), 0, TS(16) + 4),
		TextTruncate = Enum.TextTruncate.AtEnd,
	}, 16)
	text(f, "Small", sub, {
		Name = "Sub",
		Position = UDim2.fromOffset(60, 11 + TS(16)),
		Size = UDim2.new(1, -(68 + right), 0, TS(13) + 4),
		TextTruncate = Enum.TextTruncate.AtEnd,
		TextColor3 = subColor or C.TextMuted,
	}, 13)
	return f
end

local function clear(parent: Instance)
	for _, ch in ipairs(parent:GetChildren()) do
		if ch:IsA("GuiObject") then
			ch:Destroy()
		end
	end
end

------------------------------------------------------------------------------------------
-- Friends (Roblox APIs, client side)
------------------------------------------------------------------------------------------

local friends = { At = -math.huge, Rows = {} :: { any }, Status = "idle" }

local function fetchFriends(force: boolean?, done: () -> ())
	if friends.Status == "loading" then
		return
	end
	if not force and os.clock() - friends.At < Config.Party.FriendsCacheSeconds then
		done()
		return
	end
	friends.Status = "loading"
	done()
	task.spawn(function()
		local ok, list = pcall(function()
			return (player :: any):GetFriendsOnlineAsync(50)
		end)
		if not ok then
			ok, list = pcall(function()
				return player:GetFriendsOnline(50)
			end)
		end
		friends.At = os.clock()
		if ok and type(list) == "table" then
			local rows = {}
			for _, f in ipairs(list) do
				if type(f) == "table" and type(f.VisitorId) == "number" then
					local inSwarm = f.PlaceId == game.PlaceId and game.PlaceId ~= 0
					table.insert(rows, {
						UserId = f.VisitorId,
						Name = tostring(f.DisplayName or f.UserName or "Friend"),
						InSwarm = inSwarm,
						Here = inSwarm and f.GameId == game.JobId,
					})
				end
			end
			table.sort(rows, function(a, b)
				if a.InSwarm ~= b.InSwarm then
					return a.InSwarm
				end
				return a.Name < b.Name
			end)
			friends.Rows = rows
			friends.Status = "ok"
		else
			friends.Status = "error"
		end
		done()
	end)
end

-- Roblox's invite prompt (friends get a notification; they land on this server and in
-- your party: LaunchData "party:<your UserId>", PartyService).
local function inviteFriends(toast: (string, Color3?) -> ())
	task.spawn(function()
		local ok, can = pcall(function()
			return SocialService:CanSendGameInviteAsync(player)
		end)
		if not ok or not can then
			toast("Invites can't be sent from here right now.", P.gold_300)
			return
		end
		local options: Instance? = nil
		pcall(function()
			local o = Instance.new("ExperienceInviteOptions");
			(o :: any).LaunchData = "party:" .. player.UserId
			options = o
		end)
		local shown = pcall(function()
			SocialService:PromptGameInvite(player, options)
		end)
		if not shown then
			toast("Couldn't open the invite prompt.", P.gold_300)
		end
	end)
end

-- the same prompt for the MORE screen's INVITE FRIENDS screen (MenuInvite, InviteRewards)
MenuParty.InviteFriends = inviteFriends

------------------------------------------------------------------------------------------
-- Invite card (top of the screen, any screen)
------------------------------------------------------------------------------------------

local card: { [string]: any } = {}

local function buildCard(host: { [string]: any })
	local holder, face = UIKit.Surface(host.Root, { Name = "PartyInviteCard", Radius = Theme.Radius.L, Transparency = 0.04, Edge = P.gold_400, EdgeTransparency = 0.1, Visible = false })
	holder.ZIndex = Theme.Z.Toast
	card.Holder = holder
	UIKit.padding(face, 10, 12, 10, 12)
	card.AvatarSlot = new("Frame", { Name = "AvatarSlot", BackgroundTransparency = 1, Position = UDim2.fromOffset(0, 2), Size = UDim2.fromOffset(44, 44) }, face)
	card.Title = text(face, "BodyStrong", "", { Name = "Title", Position = UDim2.fromOffset(56, 0), Size = UDim2.new(1, -56, 0, TS(16) + 4), TextTruncate = Enum.TextTruncate.AtEnd }, 16)
	card.Sub = text(face, "Small", "", { Name = "Sub", Position = UDim2.fromOffset(56, TS(16) + 6), Size = UDim2.new(1, -56, 0, TS(13) + 4), TextColor3 = P.gold_300 }, 13)
	local bar = new("Frame", { Name = "Time", BackgroundColor3 = P.gold_400, BorderSizePixel = 0, AnchorPoint = Vector2.new(0, 1), Position = UDim2.new(0, 0, 1, 6), Size = UDim2.new(1, 0, 0, 3) }, face)
	UIKit.corner(bar, 2)
	card.Bar = bar
	local row = new("Frame", { Name = "Buttons", BackgroundTransparency = 1, AnchorPoint = Vector2.new(0, 1), Position = UDim2.new(0, 0, 1, -4), Size = UDim2.new(1, 0, 0, 44) }, face)
	UIKit.list(row, { FillDirection = Enum.FillDirection.Horizontal, HorizontalAlignment = Enum.HorizontalAlignment.Right, Padding = UDim.new(0, 8) })
	card.Decline = UIKit.Button(row, {
		Kind = "Secondary",
		Title = "DECLINE",
		Icon = "close",
		IconSize = 16,
		Align = "Center",
		Shadow = false,
		Size = UDim2.new(0.5, -4, 1, 0),
		LayoutOrder = 1,
		Name = "PartyDecline",
		OnClick = function()
			if card.FromId then
				send("Decline", card.FromId)
				deadlines[card.FromId] = 0
				MenuParty._card()
			end
		end,
	})
	card.Accept = UIKit.Button(row, {
		Kind = "Primary",
		Title = "ACCEPT",
		Icon = "check",
		IconSize = 16,
		Align = "Center",
		Shadow = false,
		Size = UDim2.new(0.5, -4, 1, 0),
		LayoutOrder = 2,
		Name = "PartyAccept",
		OnClick = function()
			if card.FromId then
				send("Accept", card.FromId)
				deadlines[card.FromId] = 0
				MenuParty._card()
			end
		end,
	})
	local function layout()
		local v: Vector2 = host.VirtualSize()
		local ins = host.Insets()
		-- landscape: under the top row (stats chip, PARTY) and clear of the mode column
		local portrait = host.IsPortrait()
		local w = portrait and math.min(420, v.X - 32) or math.min(420, math.floor(v.X * 0.42))
		place(holder, (v.X - w) / 2, portrait and math.max(ins.Top + 8, 12) or math.max(ins.Top + 6, 12) + 62, w, 20 + TS(16) + TS(13) + 8 + 10 + 44 + 10)
	end
	host.OnRelayout(layout)
	layout()
end

-- Shows the oldest open invite on the card (or hides it).
MenuParty._card = function()
	if not card.Holder then
		return
	end
	local inv = openInvites()[1]
	if not inv or (card.Hidden and card.Hidden()) then
		card.FromId = nil
		card.Holder.Visible = false
		return
	end
	if card.FromId ~= inv.FromId then
		card.FromId = inv.FromId
		local old = card.AvatarSlot:FindFirstChild("Avatar")
		if old then
			old:Destroy()
		end
		UIKit.Avatar(card.AvatarSlot, inv.FromId, 44)
		card.Title.Text = inv.FromName .. " invites you to their party"
		card.Total = math.max(1, (deadlines[inv.FromId] or 0) - os.clock())
		card.Holder.Visible = true
		-- scale-only entrance: the layout owns the card's Position
		UIAnim.Pop(card.Holder, 0, 0.9)
		-- ticks on every screen (the lobby's Update stops during a run)
		if not card.Ticking then
			card.Ticking = true
			task.spawn(function()
				while card.Holder.Visible do
					task.wait(0.25)
					MenuParty._card()
				end
				card.Ticking = false
			end)
		end
	end
	local left = math.max(0, (deadlines[inv.FromId] or 0) - os.clock())
	card.Sub.Text = UIKit.track(string.format("Party invite · %ds", math.ceil(left)))
	card.Bar.Size = UDim2.new(math.clamp(left / (card.Total or 30), 0, 1), 0, 0, 3)
end

------------------------------------------------------------------------------------------
-- The screen
------------------------------------------------------------------------------------------

function MenuParty.Build(screen: Frame, ctx: { [string]: any })
	local host = ctx.Host
	local ui: { [string]: any } = {}
	local tab = "Server"
	local dirty = true

	ui.Header = UIKit.ScreenHeader(screen, "PARTY", ctx.Back)
	local holder, face = UIKit.Surface(screen, { Name = "Panel", Radius = Theme.Radius.L, Transparency = 0.06, Edge = P.gold_400, EdgeTransparency = 0.35 })
	ui.Panel = holder
	UIKit.padding(face, 16, 18, 16, 18)

	-- left: your party
	local left = new("Frame", { Name = "Party", BackgroundTransparency = 1 }, face)
	ui.Left = left
	ui.PartyLabel = UIKit.SectionLabel(left, "Your party", nil, { Size = UDim2.new(1, 0, 0, TS(12) + 6) })
	local plist = new("ScrollingFrame", {
		Name = "Members",
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		ScrollBarThickness = 4,
		ScrollBarImageColor3 = P.gold_500,
		AutomaticCanvasSize = Enum.AutomaticSize.Y,
		CanvasSize = UDim2.new(),
		ScrollingDirection = Enum.ScrollingDirection.Y,
	}, left)
	UIKit.padding(plist, 2, 8, 2, 2) -- strokes stay inside the clip; room for the scroll bar
	UIKit.list(plist, { Padding = UDim.new(0, ROW_GAP) })
	ui.Members = plist
	ui.Hint = text(left, "Small", "", { Name = "Hint", TextWrapped = true, TextYAlignment = Enum.TextYAlignment.Top, TextColor3 = C.TextMuted }, 14)
	ui.Leave = UIKit.Button(left, {
		Kind = "Secondary",
		Title = "LEAVE PARTY",
		Icon = "close",
		IconSize = 18,
		Align = "Center",
		Name = "LeaveParty",
		OnClick = function()
			send("Leave")
		end,
	})

	-- the leader's START: the mode that takes the whole party, once everyone is ready
	ui.Start = UIKit.Button(left, {
		Kind = "Primary",
		Title = "START",
		Icon = "play",
		IconSize = 18,
		Align = "Center",
		Name = "PartyStart",
		OnClick = function()
			local mode = MenuParty.PartyMode()
			if mode then
				Remotes.Get("StartRun"):FireServer(mode)
			end
		end,
	})

	-- right: this server / friends
	local right = new("Frame", { Name = "Find", BackgroundTransparency = 1 }, face)
	ui.Right = right
	ui.Tabs = UIKit.Tabs(right, { { Id = "Server", Title = "This server", Icon = "people3" }, { Id = "Friends", Title = "Friends", Icon = "userPlus" } }, function(id)
		tab = id
		dirty = true
		if id == "Friends" then
			fetchFriends(false, function()
				dirty = true
			end)
		end
	end)
	ui.InviteFriends = UIKit.Button(right, {
		Kind = "Primary",
		Title = "INVITE FRIENDS",
		Icon = "userPlus",
		IconSize = 20,
		Align = "Center",
		Name = "InviteFriends",
		OnClick = function()
			inviteFriends(ctx.Toast)
		end,
	})
	ui.Refresh = UIKit.IconButton(right, {
		Icon = "cycle",
		Size = 48,
		Name = "RefreshFriends",
		OnClick = function()
			fetchFriends(true, function()
				dirty = true
			end)
		end,
	})
	local list = new("ScrollingFrame", {
		Name = "People",
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		ScrollBarThickness = 4,
		ScrollBarImageColor3 = P.gold_500,
		AutomaticCanvasSize = Enum.AutomaticSize.Y,
		CanvasSize = UDim2.new(),
		ScrollingDirection = Enum.ScrollingDirection.Y,
	}, right)
	UIKit.padding(list, 2, 8, 2, 2)
	UIKit.list(list, { Padding = UDim.new(0, ROW_GAP) })
	ui.List = list
	ui.Empty = text(right, "Body", "", { Name = "Empty", TextWrapped = true, TextXAlignment = Enum.TextXAlignment.Center, TextColor3 = C.TextMuted, Visible = false })

	-- quick lines (PartyQuickLines): a strip under both columns, the row of fixed lines and
	-- the party feed (PartyLines); only in a party
	ui.Bar = new("Frame", { Name = "QuickBar", BackgroundTransparency = 1, Visible = false }, face)
	ui.Say = PartyLines.BuildRow(ui.Bar)
	ui.Feed = PartyLines.BuildFeed(ui.Bar)

	local leftRows = 0
	local rightRows = 0

	local function fillParty()
		clear(plist)
		local order = 0
		-- invites to you first
		for _, inv in ipairs(openInvites()) do
			order += 1
			local f = personRow(plist, order, inv.FromId, inv.FromName, narrow and "Invited you" or "Invited you to their party", P.gold_300, bw(108, "ACCEPT") + 8 + 44 + 16, true)
			rowButton(f, "ACCEPT", nil, "Primary", 108, 8, function()
				send("Accept", inv.FromId)
				deadlines[inv.FromId] = 0
				dirty = true
			end)
			rowButton(f, "", "close", "Secondary", 44, bw(108, "ACCEPT") + 16, function()
				send("Decline", inv.FromId)
				deadlines[inv.FromId] = 0
				dirty = true
			end).Instance.Name = "DeclineInvite"
		end
		local members = state.Members
		if #members == 0 then
			members = { { UserId = player.UserId, Name = player.DisplayName } }
		end
		for _, m in ipairs(members) do
			order += 1
			local me = m.UserId == player.UserId
			local leads = m.UserId == state.LeaderId
			local ready = m.Ready == true
			local sub = leads and "Leader · starts the runs" or (inParty() and (ready and "Ready" or "Not ready") or "Not in a party yet")
			local canKick = isLeader() and not me
			local toggle = me and not leads and inParty()
			-- right side: [pill] [KICK | READY toggle]
			local btnW = canKick and bw(100, "KICK") or (toggle and bw(120, ready and "UNREADY" or "READY") or 0)
			local pillW = (leads or (inParty() and not toggle)) and (ready and 84 or 112) or 0
			local right = (btnW > 0 and btnW + 12 or 0) + (pillW > 0 and pillW + 8 or 0)
			local f = personRow(plist, order, m.UserId, m.Name .. (me and "  (you)" or ""), sub, (leads or ready) and P.gold_300 or nil, right, me)
			if pillW > 0 then
				local pill = UIKit.StatusPill(f, "READY", { AnchorPoint = Vector2.new(1, 0.5), Position = UDim2.new(1, -(btnW > 0 and btnW + 20 or 12), 0.5, 0), Name = leads and "Leader" or "ReadyPill" })
				if leads then
					UIKit.SetStatus(pill, "READY", "LEADER")
				elseif ready then
					UIKit.SetStatus(pill, "UNLOCKED", "READY")
				else
					UIKit.SetStatus(pill, "WAITING", "NOT READY")
				end
			end
			if canKick then
				rowButton(f, "KICK", nil, "Secondary", 100, 8, function()
					send("Kick", m.UserId)
				end)
			elseif toggle then
				rowButton(f, ready and "UNREADY" or "READY", if ready then nil else "check", ready and "Secondary" or "Primary", 120, 8, function()
					MenuParty.SetReady(not ready)
				end).Instance.Name = "ReadyToggle"
			end
		end
		-- open slots
		local slots = math.max(0, state.Max - #members)
		for i = 1, slots do
			order += 1
			local f = UIKit.Panel(plist, { Name = "Slot" .. i, LayoutOrder = order, Size = UDim2.new(1, 0, 0, ROW_H) }, true)
			f.BackgroundColor3 = P.slate_950
			f.BackgroundTransparency = 0.6
			UIKit.stroke(f, P.slate_500, 1, 0.5)
			Icons.Draw(f, "userPlus", { Size = 24, Color = P.slate_400, AnchorPoint = Vector2.new(0, 0.5), Position = UDim2.new(0, 18, 0.5, 0) })
			text(f, "Body", "Open slot", { Position = UDim2.fromOffset(60, 0), Size = UDim2.new(1, -70, 1, 0), TextColor3 = C.TextFaint }, 15)
		end
		leftRows = order
		local count = math.max(1, #state.Members)
		ui.PartyLabel.Text = UIKit.track(string.format("Your party  %d/%d", count, state.Max))
		if not inParty() then
			ui.Hint.Text = "Invite players on this server or your friends. When the leader starts DUO or TRIO, party members join that run (up to its size). SOLO and Daily runs are the leader's alone."
		elseif isLeader() then
			ui.Hint.Text = "When everyone is READY, press START (or DUO / TRIO on the home screen): your party joins your run."
		else
			ui.Hint.Text = "Tap READY when you're set. Your leader starts the run and you join it automatically."
		end
		ui.Leave.Instance.Visible = inParty()
		local sum = MenuParty.Summary()
		local mode = MenuParty.PartyMode()
		ui.Start.Instance.Visible = inParty() and isLeader() and mode ~= nil
		if ui.Start.Instance.Visible then
			local allReady = sum.Ready >= sum.Others
			ui.Start.SetText(allReady and ("START " .. string.upper((Config.Modes :: any)[mode :: string].DisplayName)) or string.format("%d/%d READY", sum.Ready, sum.Others))
			ui.Start.SetEnabled(allReady)
		end
	end

	local function serverRows(): number
		local others = {}
		for _, p in ipairs(Players:GetPlayers()) do
			if p ~= player then
				table.insert(others, p)
			end
		end
		table.sort(others, function(a, b)
			return a.DisplayName < b.DisplayName
		end)
		local myParty = player:GetAttribute("PartyId") or 0
		local full = inParty() and #state.Members >= state.Max
		local canInvite = (not inParty() or isLeader()) and not full
		local invitedMe: { [number]: boolean } = {}
		for _, inv in ipairs(openInvites()) do
			invitedMe[inv.FromId] = true
		end
		for i, p in ipairs(others) do
			local theirParty = p:GetAttribute("PartyId") or 0
			local same = myParty ~= 0 and theirParty == myParty
			local sub, color = "On this server", nil
			if same then
				sub, color = "In your party", P.moss_200
			elseif invitedMe[p.UserId] then
				sub, color = "Invited you", P.gold_300
			elseif sentTo(p.UserId) then
				sub = "Invite sent"
			elseif theirParty ~= 0 then
				sub = "In another party"
			elseif p:GetAttribute("InRun") == true then
				sub = "In a run"
			end
			local showInvite = not same and not invitedMe[p.UserId]
			local f = personRow(list, i, p.UserId, p.DisplayName, sub, color, (showInvite or invitedMe[p.UserId]) and (bw(140, "INVITE") + 12) or 0)
			if invitedMe[p.UserId] then
				rowButton(f, "ACCEPT", "check", "Primary", 140, 8, function()
					send("Accept", p.UserId)
					deadlines[p.UserId] = 0
					dirty = true
				end)
			elseif showInvite then
				local b = rowButton(f, sentTo(p.UserId) and "SENT" or "INVITE", "userPlus", "Primary", 140, 8, function()
					send("Invite", p.UserId)
				end)
				b.SetEnabled(canInvite and not sentTo(p.UserId))
			end
		end
		return #others
	end

	local function friendRows(): number
		for i, f in ipairs(friends.Rows) do
			local sub = f.Here and "On this server" or (f.InSwarm and "Playing SWARM" or "Online")
			local r = personRow(list, i, f.UserId, f.Name, sub, f.InSwarm and P.moss_200 or nil, f.InSwarm and not f.Here and (bw(112, "JOIN") + 12) or 0)
			if f.InSwarm and not f.Here then
				rowButton(r, "JOIN", "play", "Primary", 112, 8, function()
					Remotes.Get("PartyFollow"):FireServer(f.UserId)
				end)
			end
		end
		return #friends.Rows
	end

	local function fill()
		dirty = false
		fillParty()
		clear(list)
		local n
		local friendsTab = tab == "Friends"
		ui.InviteFriends.Instance.Visible = friendsTab
		ui.Refresh.Instance.Visible = friendsTab
		if friendsTab then
			n = friendRows()
			ui.Empty.Text = friends.Status == "loading" and "Looking for your friends..." or (friends.Status == "error" and "Couldn't load your friends list. Tap refresh to try again." or "None of your friends are online. Invite them with INVITE FRIENDS!")
		else
			n = serverRows()
			ui.Empty.Text = "Nobody else is on this server yet. Use the FRIENDS tab to invite your friends."
		end
		ui.Empty.Visible = n == 0
		rightRows = n
		MenuParty._layout()
	end

	local function layout(v: Vector2, portrait: boolean, ins: { [string]: number })
		local W, H = v.X, v.Y
		-- the real screen size in layout units (AbsoluteSize / the root UIScale), when known
		local scale = host.Scale and host.Scale() or 1
		local abs = screen.AbsoluteSize
		if abs.X > 0 and scale > 0 then
			W, H = math.min(W, abs.X / scale), math.min(H, abs.Y / scale)
		end
		local M = UIKit.IsCompact() and Theme.Layout.MarginCompact or Theme.Layout.Margin
		local headY = math.max(ins.Top + 4, 12)
		place(ui.Header.Frame, M, headY, math.min(560, W - 2 * M), 56)
		local top = math.max(headY + 66 + (portrait and 58 or 0), portrait and 0 or 76)
		local maxH = H - top - M
		local w = math.min(W - 2 * M, 1040)
		local labelH = TS(12) + 6
		local stackedW = W - 2 * M - 36
		local hintW = (portrait or stackedW < 620) and stackedW or math.floor(stackedW * 0.44)
		local hintLines = math.clamp(math.ceil(#ui.Hint.Text * TS(14) * 0.56 / math.max(1, hintW - 8)), 1, 5)
		local hintH = hintLines * (TS(14) + 3) + 6
		local leaveH = ui.Leave.Instance.Visible and Theme.Size.Button or 0
		local listWant = leftRows * (ROW_H + ROW_GAP) + 4
		local tabsH = Theme.Size.TapMin + 4
		local stacked = portrait or w - 36 < 620
		-- landscape: only as tall as the longer column needs (at least four rows)
		local leftWant = labelH + 8 + listWant + 8 + hintH + (leaveH > 0 and leaveH + 8 or 0)
		local rightWant = tabsH + 10 + (tab == "Friends" and 58 or 0) + math.max(4, rightRows) * (ROW_H + ROW_GAP) + 4
		-- quick lines strip under both columns (PartyLines): the row, then the feed
		local sayOn = PartyLines.Available()
		local sayRowH, feedLines, barH = 0, 0, 0
		if sayOn then
			sayRowH = ui.Say.Measure(w - 36)
			feedLines = (portrait or H >= 560) and 3 or 1
			barH = sayRowH + 6 + ui.Feed.Measure(feedLines) + 10
		end
		local panelH = math.min(maxH, (stacked and (leftWant + 14 + rightWant) or math.max(leftWant, rightWant)) + 36 + barH)
		local iw, ih = w - 36, panelH - 32
		place(ui.Panel, (W - w) / 2, top, w, panelH)
		local colH = ih - barH
		ui.Bar.Visible = sayOn
		if sayOn then
			place(ui.Bar, 0, colH + 10, iw, barH - 10)
			ui.Say.Layout(iw)
			ui.Say.Frame.Position = UDim2.fromOffset(0, 0)
			ui.Feed.Layout(iw, feedLines)
			ui.Feed.Frame.Position = UDim2.fromOffset(0, sayRowH + 6)
		end
		local lw, lh, rx, ry, rw, rh
		if stacked then
			-- stacked: the party (as tall as it needs, up to half), then the lists
			lw = iw
			lh = math.min(leftWant, math.max(math.floor(colH * 0.45), colH - 14 - rightWant))
			rx, ry, rw, rh = 0, lh + 14, iw, colH - lh - 14
		else
			lw = math.floor(iw * 0.44)
			lh = colH
			rx, ry, rw, rh = lw + 24, 0, iw - lw - 24, colH
		end
		place(ui.Left, 0, 0, lw, lh)
		local listH = math.max(ROW_H, lh - labelH - 8 - 8 - hintH - (leaveH > 0 and leaveH + 8 or 0))
		place(ui.Members, 0, labelH + 8, lw, math.min(listH, listWant))
		local y = labelH + 8 + math.min(listH, listWant) + 8
		place(ui.Hint, 0, y, lw, hintH)
		if leaveH > 0 then
			local bwid = ui.Start.Instance.Visible and math.min(220, math.floor((lw - 12) / 2)) or math.min(lw, 260)
			place(ui.Leave.Instance, 0, y + hintH + 4, bwid, leaveH)
			place(ui.Start.Instance, bwid + 12, y + hintH + 4, bwid, leaveH)
		end
		place(ui.Right, rx, ry, rw, rh)
		-- narrow lists: compact row buttons (rows are rebuilt when this flips)
		local wasNarrow = narrow
		narrow = math.min(lw, rw) < 440
		if narrow ~= wasNarrow then
			dirty = true
		end
		-- tabs: no icons when the column is narrow, so the titles fit
		for _, b in ipairs(ui.Tabs.Frame:GetChildren()) do
			local icon = b:FindFirstChild("IconHolder", true)
			if icon and icon:IsA("GuiObject") then
				icon.Visible = rw >= 420
			end
		end
		ui.Tabs.Frame.Position = UDim2.new()
		ui.Tabs.Frame.Size = UDim2.new(1, 0, 0, tabsH)
		local ly = tabsH + 10
		if ui.InviteFriends.Instance.Visible then
			place(ui.InviteFriends.Instance, 0, ly, rw - 58, 48)
			place(ui.Refresh.Instance, rw - 48, ly, 48, 48)
			ly += 58
		end
		place(ui.List, 0, ly, rw, math.max(ROW_H, rh - ly))
		place(ui.Empty, 12, ly + 12, rw - 24, TS(16) * 3 + 12)
	end
	MenuParty._layout = function()
		layout(host.VirtualSize(), host.IsPortrait(), host.Insets())
	end

	Remotes.Get("PartyState").OnClientEvent:Connect(function(d)
		if type(d) ~= "table" then
			return
		end
		state = {
			LeaderId = tonumber(d.LeaderId) or 0,
			Members = type(d.Members) == "table" and d.Members or {},
			Max = tonumber(d.Max) or 3,
			Invites = type(d.Invites) == "table" and d.Invites or {},
			Sent = type(d.Sent) == "table" and d.Sent or {},
		}
		-- someone else joined my party, or I joined theirs (not the first state after load): PartyJoin
		local nowIds: { [number]: boolean } = {}
		local joinedNew = false
		for _, m in ipairs(state.Members) do
			local id = tonumber(m.UserId) or 0
			nowIds[id] = true
			if knownMembers and not knownMembers[id] and id ~= player.UserId then
				joinedNew = true
			end
		end
		knownMembers = nowIds
		if joinedNew then
			UIKit.Sound("PartyJoin")
		end
		local now = os.clock()
		local seen: { [number]: boolean } = {}
		for _, inv in ipairs(state.Invites) do
			seen[inv.FromId] = true
			local left = now + (tonumber(inv.Seconds) or 0)
			-- 0 = answered here already; otherwise the server's time left (never longer)
			local dl = deadlines[inv.FromId]
			if dl ~= 0 then
				deadlines[inv.FromId] = (dl and dl > now) and math.min(dl, left) or left
			end
		end
		for id in pairs(deadlines) do
			if not seen[id] then
				deadlines[id] = nil
			end
		end
		dirty = true
		MenuParty._card()
	end)
	Remotes.Get("PartyInvite").OnClientEvent:Connect(function(d)
		if type(d) ~= "table" or type(d.FromId) ~= "number" then
			return
		end
		deadlines[d.FromId] = os.clock() + (tonumber(d.Seconds) or 30)
		local known = false
		for _, inv in ipairs(state.Invites) do
			known = known or inv.FromId == d.FromId
		end
		if not known then
			table.insert(state.Invites, { FromId = d.FromId, FromName = tostring(d.FromName or "?"), Seconds = tonumber(d.Seconds) or 30 })
		end
		dirty = true
		MenuParty._card()
	end)
	local function markDirty()
		dirty = true
	end
	Players.PlayerAdded:Connect(markDirty)
	Players.PlayerRemoving:Connect(markDirty)
	local function watch(p: Player)
		p:GetAttributeChangedSignal("PartyId"):Connect(markDirty)
		p:GetAttributeChangedSignal("InRun"):Connect(markDirty)
	end
	for _, p in ipairs(Players:GetPlayers()) do
		watch(p)
	end
	Players.PlayerAdded:Connect(watch)

	buildCard(host)
	card.Hidden = function(): boolean
		return screen.Visible and ctx.Current() == "Party"
	end
	task.defer(function()
		send("Sync")
	end)

	local tick = 0
	return {
		Layout = layout,
		OnShow = function()
			fill()
			UIAnim.Pop(holder, 0, 0.94)
			if tab == "Friends" then
				fetchFriends(false, markDirty)
			end
		end,
		Update = function(dt: number)
			tick += dt
			if tick >= 0.25 then
				tick = 0
				MenuParty._card() -- back from the PARTY screen: an open invite shows again
				-- an invite ran out: drop its row
				for _, inv in ipairs(state.Invites) do
					local dl = deadlines[inv.FromId]
					if dl and dl > 0 and dl <= os.clock() then
						deadlines[inv.FromId] = 0
						dirty = true
					end
				end
			end
			if dirty and screen.Visible then
				fill()
			end
		end,
	}
end

MenuParty._layout = function() end

return MenuParty
