--!strict
--[[
	SwarmV2Client/Lobby/Status.lua
	OWNER: lobby track (Chat 1), stream L1. What the home screen says about loading and the connection.

	LOAD CARD (centre, only while something is missing): the three things the lobby waits for, each
	with a tick when it has arrived: the lobby connection, the player's profile (ProfileSync), and the
	class ownership + selection (the first LobbyState). After 8 seconds it names what is still loading
	and why that can take a while; after 30 seconds it says so plainly (icon and words), promises the
	saved progress is untouched and offers RETRY (asks the server again: RequestProfile + LobbySync;
	safe to repeat, nothing is created or bought). Missing data is never treated as a new player:
	the guide, the class chip and the party strip all wait for the real answer.

	STATUS ROW (left column, under the party strip): "Connected" (or what is wrong with saving) and a
	HOW TO PLAY button that reopens the first-time guide.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Kit = require(script.Parent.Kit)
local Brief = require(script.Parent.Brief)
local Remotes = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Remotes"))
local LobbyConfig = require(ReplicatedStorage:WaitForChild("SwarmV2"):WaitForChild("Lobby"):WaitForChild("LobbyConfig"))

local UIKit = Kit.UIKit
local new = UIKit.new
local T = Brief.T

local Status = {}

export type Panel = {
	Layout: (ctx: Kit.Ctx, x: number, y: number) -> (),
	Render: (ctx: Kit.Ctx) -> (),
	Step: (ctx: Kit.Ctx) -> (),
	State: () -> { [string]: any },
	-- tests: the clock the 8 s / 30 s thresholds read
	_SetClock: ((() -> number)?) -> (),
}

Status.ExplainAfter = LobbyConfig.Home.ExplainLoadingAfter -- seconds until it says what is still loading (8)
Status.RetryAfter = LobbyConfig.Home.OfferRetryAfter -- seconds until it offers RETRY with a failure message (30)
local RETRY_COOLDOWN = 3

function Status.Build(ctx: Kit.Ctx): Panel
	local clock: () -> number = os.clock
	local startedAt = clock()
	local retriedAt: number? = nil
	local retries = 0
	local lastSig = ""

	-- load card ----------------------------------------------------------------------------
	local card = Brief.panel(ctx.Root, {
		Name = "LoadCard",
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.5),
		Size = UDim2.fromOffset(460, 300),
		ZIndex = 15,
		Active = true,
		Visible = true,
	})
	Brief.label(card, "Section", "GETTING YOUR CAMP READY", { Name = "Heading", Position = UDim2.fromOffset(20, 16), Size = UDim2.new(1, -40, 0, 34), TextTruncate = Enum.TextTruncate.AtEnd, ZIndex = 16 }, ctx.Compact)
	local rows: { [string]: { Mark: Frame, Text: TextLabel } } = {}
	local labels = {
		{ "Lobby", "Connected to the lobby" },
		{ "Profile", "Your profile: progress, gold, settings" },
		{ "Class", "Your classes: what you own and your pick" },
	}
	for i, l in ipairs(labels) do
		local y = 54 + (i - 1) * 30
		local mark = new("Frame", { Name = "Mark_" .. l[1], BackgroundTransparency = 1, Position = UDim2.fromOffset(20, y + 3), Size = UDim2.fromOffset(24, 24), ZIndex = 16 }, card)
		local text = Brief.label(card, "Body", l[2], { Name = "Row_" .. l[1], Position = UDim2.fromOffset(52, y), Size = UDim2.new(1, -72, 0, 30), TextTruncate = Enum.TextTruncate.AtEnd, ZIndex = 16 }, ctx.Compact)
		rows[l[1]] = { Mark = mark, Text = text }
	end
	local message = Brief.label(card, "Body", "", {
		Name = "Message",
		Position = UDim2.fromOffset(20, 150),
		Size = UDim2.new(1, -40, 0, 100),
		TextWrapped = true,
		TextYAlignment = Enum.TextYAlignment.Top,
		ZIndex = 16,
	}, ctx.Compact)
	message.FontFace = Brief.Weight.Regular
	local warnIcon = Kit.Icons.Draw(card, "warning", { Name = "WarnIcon", Size = 22, Color = T.Danger, Position = UDim2.fromOffset(20, 152), ZIndex = 17 })
	warnIcon.Visible = false
	local retry = Brief.button(card, {
		Name = "LoadRetry",
		Title = "RETRY",
		Icon = "cycle",
		Size = UDim2.new(1, -40, 0, 56),
		AnchorPoint = Vector2.new(0, 1),
		Position = UDim2.new(0, 20, 1, -16),
		ZIndex = 17,
		Kind = "Primary",
		TitleSize = 20,
		OnClick = function()
			retries += 1
			retriedAt = clock()
			pcall(function()
				Remotes.Get("RequestProfile"):FireServer()
			end)
			ctx.Fire("LobbySync")
		end,
	})
	retry.Instance.Visible = false

	-- status row ------------------------------------------------------------------------------
	local row = new("Frame", { Name = "StatusRow", BackgroundTransparency = 1, Size = UDim2.fromOffset(260, 48), ZIndex = 3 }, ctx.Root)
	local pill = new("Frame", { Name = "Pill", BackgroundColor3 = T.Navy, BorderSizePixel = 0, Size = UDim2.fromOffset(136, 48), ZIndex = 3 }, row)
	UIKit.corner(pill, 14)
	UIKit.stroke(pill, T.Line, 2, 0)
	local dot = new("Frame", { Name = "Dot", AnchorPoint = Vector2.new(0, 0.5), Position = UDim2.new(0, 12, 0.5, 0), Size = UDim2.fromOffset(12, 12), BackgroundColor3 = T.Good, BorderSizePixel = 0, ZIndex = 4 }, pill)
	UIKit.corner(dot, 999)
	local pillText = Brief.label(pill, "Label", "Connected", { Name = "Text", Position = UDim2.fromOffset(32, 0), Size = UDim2.new(1, -38, 1, 0), TextColor3 = T.Cream, TextTruncate = Enum.TextTruncate.AtEnd, ZIndex = 4 }, ctx.Compact)
	Brief.button(row, {
		Name = "HelpButton",
		Title = "HOW TO PLAY",
		Size = UDim2.fromOffset(116, 48),
		Position = UDim2.fromOffset(144, 0),
		ZIndex = 4,
		Kind = "Secondary",
		TitleSize = 14,
		OnClick = function()
			ctx.OpenGuide(true)
		end,
	})
	local saveWarn = Brief.label(ctx.Root, "Caption", "", { Name = "SaveWarning", Visible = false, TextWrapped = true, TextColor3 = T.Danger, Size = UDim2.fromOffset(260, 40), TextYAlignment = Enum.TextYAlignment.Top, ZIndex = 3 }, ctx.Compact)

	local player = Players.LocalPlayer

	local function mark(name: string, done: boolean)
		local m = rows[name].Mark
		for _, ch in ipairs(m:GetChildren()) do
			ch:Destroy()
		end
		if done then
			Kit.Icons.Draw(m, "check", { Size = 22, Color = T.Good, Name = "Tick" })
			rows[name].Text.TextColor3 = T.Cream
		else
			-- a plain ring: still waiting (shape and the words below carry the meaning, not colour)
			local ring = new("Frame", { Name = "Waiting", BackgroundTransparency = 1, Size = UDim2.fromOffset(20, 20), Position = UDim2.fromOffset(2, 2), ZIndex = 17 }, m)
			UIKit.corner(ring, 999)
			UIKit.stroke(ring, T.CreamMuted, 3, 0)
			rows[name].Text.TextColor3 = T.CreamMuted
		end
	end

	local function loadingNames(c: Kit.Ctx): { string }
		local out = {}
		if c.Profile == nil then
			table.insert(out, "your profile")
		end
		if c.View == nil then
			table.insert(out, "your class information")
		end
		return out
	end

	local function refresh(c: Kit.Ctx)
		local profileOk, classOk = c.Profile ~= nil, c.View ~= nil
		local loading = not (profileOk and classOk)
		card.Visible = loading
		if loading then
			local age = clock() - startedAt
			mark("Lobby", true)
			mark("Profile", profileOk)
			mark("Class", classOk)
			local names = table.concat(loadingNames(c), " and ")
			local text: string
			local escalated = age >= Status.RetryAfter
			if escalated then
				text = "Still loading " .. names .. ". Your saved progress is untouched; nothing here treats you as a new player. Press RETRY. If it keeps failing, rejoin the game."
			elseif age >= Status.ExplainAfter then
				text = "Still loading " .. names .. ". A busy server or a slow connection can take a while. Nothing is lost."
			else
				text = "Loading " .. names .. "..."
			end
			if retriedAt and clock() - retriedAt < RETRY_COOLDOWN then
				text = "Asking the server again (try " .. tostring(retries) .. ")..."
			end
			message.Text = text
			message.TextColor3 = escalated and T.Danger or T.Cream
			warnIcon.Visible = escalated
			message.Position = UDim2.fromOffset(escalated and 52 or 20, 150)
			message.Size = UDim2.new(1, escalated and -72 or -40, 0, ctx.Compact and 120 or 100)
			local cooling = retriedAt ~= nil and clock() - retriedAt < RETRY_COOLDOWN
			retry.Instance.Visible = escalated
			retry.SetEnabled(not cooling)
			retry.SetText(cooling and "ASKING..." or "RETRY")
		end
		-- the status row
		local save = player:GetAttribute("SaveStatus")
		if loading then
			pillText.Text = "Loading..."
			dot.BackgroundColor3 = T.Gold
		elseif save == "failing" then
			pillText.Text = "Not saving"
			dot.BackgroundColor3 = T.Danger
		elseif save == "memory" then
			pillText.Text = "Not saved"
			dot.BackgroundColor3 = T.Gold
		else
			pillText.Text = "Connected"
			dot.BackgroundColor3 = T.Good
		end
		if loading then
			saveWarn.Visible = false
		elseif save == "failing" then
			saveWarn.Visible = true
			saveWarn.Text = "Progress is not being saved right now, so changes may be lost."
		elseif save == "memory" then
			saveWarn.Visible = true
			saveWarn.Text = "Saving is off in this session (Studio or offline): nothing is kept."
		else
			saveWarn.Visible = false
		end
	end

	local panel: Panel
	panel = {
		Layout = function(c: Kit.Ctx, x: number, y: number)
			row.Position = UDim2.fromOffset(x, y)
			row.Size = UDim2.fromOffset(c.Portrait and math.min(300, c.W - 2 * Kit.M) or 260, 48)
			saveWarn.Position = UDim2.fromOffset(x, y + 52)
			saveWarn.Size = UDim2.fromOffset(row.Size.X.Offset, 40)
			card.Size = UDim2.fromOffset(math.min(460, c.W - 24), c.Compact and 350 or 330)
			for _, r in pairs(rows) do
				r.Text.TextSize = Brief.size("Body", c.Compact)
			end
			message.TextSize = Brief.size("Body", c.Compact)
			lastSig = ""
		end,
		Render = function(c: Kit.Ctx)
			refresh(c)
		end,
		Step = function(c: Kit.Ctx)
			-- cheap: only the clock-driven texts and the cooldown change between pushes
			local age = math.floor(clock() - startedAt)
			local cooling = retriedAt ~= nil and clock() - retriedAt < RETRY_COOLDOWN
			local sig = string.format("%d|%s|%s|%s|%s", age >= Status.RetryAfter and 2 or (age >= Status.ExplainAfter and 1 or 0), tostring(c.Profile ~= nil), tostring(c.View ~= nil), tostring(cooling), tostring(player:GetAttribute("SaveStatus")))
			if sig ~= lastSig then
				lastSig = sig
				refresh(c)
			end
		end,
		State = function(): { [string]: any }
			return { Visible = card.Visible, Retries = retries, Message = message.Text, RetryVisible = retry.Instance.Visible, Pill = pillText.Text }
		end,
		_SetClock = function(fn: (() -> number)?)
			clock = fn or os.clock
			startedAt = clock()
			retriedAt = nil
			lastSig = ""
		end,
	}
	return panel
end

return Status
