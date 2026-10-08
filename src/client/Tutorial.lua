--[[
	Tutorial.lua
	First-run tips that teach through play (Config.Tutorial). One big callout at a time:
	an icon, a short bold title, one line, "TIP 2 / 5" and a big SKIP TIPS button. It sits
	next to what it explains with an arrow pointing at it (the XP bar for gems, the weapon
	row for auto attack, the stage pill for the portal, the boss bar for the boss) and a
	soft gold ring around that element; it slides in from that side and pops out. It
	dismisses itself after a few seconds and never pauses or blocks the run: nothing in it
	is Active (a thumb landing on it still moves the hero) except the SKIP TIPS button.

	Tutorial tips (a player's first run; anyone with a run played before skips them):
	  Move      at the start: drag anywhere / WASD / left stick and how to jump (by input device); done
	            early once the hero has walked a few steps
	  Attack    "your weapon attacks automatically, keep moving" → the weapon row
	  Gems      after the first kill: walk over the blue gems for XP → the XP bar
	  LevelUp   the first level-up offer: one line under LEVEL UP! explains the cards
	            (UIBuilder asks LevelUpHint; not a callout)
	  Portal    Config.Tutorial.PortalTipDelay seconds after the portal reveal (SwarmState
	            PortalHint; its banner first), unless the portal is already charging: the
	            PORTAL arrow, the ring, the real ChargeSeconds, the boss → the stage pill.
	            The tutorial run's reveal waits for the first upgrade pick (server,
	            Config.FirstRun.RevealCapSeconds), so the tour runs Move, Attack, Gems,
	            the cards, Portal, Boss.
	  Boss      when the stage boss appears: red floor shapes show where <boss name> strikes
	            → the boss bar
	Co-op tips (once ever, also for experienced players; "TEAM TIP" instead of a count):
	  TeamRules the first group run: what is shared and what is your own
	  Revive    the first time a teammate falls: stand beside them to revive

	Each card slides in with its icon spinning, a glint across the card and a ring pulse
	around the element it explains (plain with Reduced effects).
	Each hint shown is reported (Tutorial remote "Seen") so it never repeats; SKIP TIPS
	ends the tutorial ("Skip"); Settings > Show tips switches every hint off and Settings >
	Replay tips ("Replay") shows them again from the next run. The server marks the
	tutorial done when the first run ends.

	SmartTutorial (Config.Features.SmartTutorial, Config.Tutorial.Smart,
	docs/next/SMART_TUTORIAL.md) replaces the tour above (the callout card stays for the
	switch off): seven tips over the player's first two runs (save TutorialStep), one at a
	time in a small speech bubble above the ability tray (TutorialBubble.lua) whose pointer
	aims at the thing, each when it is needed and gone once its action is done or after
	Smart.Seconds:
	  Move      run start, until the hero walked Smart.MoveStuds (InputPrompts.MoveShort)
	  Attack    the first kill: "Your weapon attacks by itself" → the weapon row
	  Gems      a gem lands within Smart.GemNearStuds: "Pick up the blue gems for XP" → the
	            gem; done when the XP bar moves
	  LevelUp   the first level-up offer: "Choose an upgrade" under LEVEL UP! (the cards stay
	            free to pick; LevelUpHint)
	  Chest     a ready chest within Smart.ChestStuds (InputPrompts.OpenChest) → the chest;
	            done when it opens
	  Portal    after the reveal (PortalTipDelay): "Find and charge the portal" → the PORTAL
	            arrow (StageUI); done when the charge starts
	  Boss      the first boss arrival: "Bosses guard the way out" → the boss bar
	The co-op tips use the same bubble. The bubble hides while a panel covers the screen.
]]

local Players = game:GetService("Players")
local TextService = game:GetService("TextService")
local GuiService = game:GetService("GuiService")

local Shared = game:GetService("ReplicatedStorage"):WaitForChild("Shared")
local Config = require(Shared:WaitForChild("Config"))
local Remotes = require(Shared:WaitForChild("Remotes"))
local Theme = require(Shared:WaitForChild("Theme"))
local UIKit = require(script.Parent.UIKit)
local UIAnim = require(script.Parent.UIAnim)
local Icons = require(script.Parent.Icons)
local Hud = require(script.Parent.Hud)
local MiniMap = require(script.Parent.MiniMap)
local TeamUI = require(script.Parent.TeamUI)
local LootUI = require(script.Parent.LootUI)
local ClientSettings = require(script.Parent.ClientSettings)
local InputPrompts = require(script.Parent.InputPrompts)
local TutorialBubble = require(script.Parent.TutorialBubble)
local FeatureHud = require(script.Parent.FeatureHud)
local StageUI = require(script.Parent.StageUI)
local WalkthroughClient = require(script.Parent.WalkthroughClient)

local Tutorial = {}

local player = Players.LocalPlayer
local new, TS = UIKit.new, UIKit.TS
local C = Theme.Color
local T = Config.Tutorial
local S = T.Smart or {}

-- SmartTutorial (one bubble at a time, seven tips over the first two runs)
local function smart(): boolean
	return (Config :: any).Features.SmartTutorial == true
end

local COOP = { TeamRules = true, Revive = true }
-- the tips the interactive walkthrough teaches by doing (WalkthroughClient): never shown after it
local WALK_TIPS = { "Move", "Attack", "Gems", "LevelUp", "Chest", "Portal" }
-- the numbered tour of a first run ("TIP n / total")
local TOUR = { "Move", "Attack", "Gems", "Portal", "Boss" }
-- what each tip points at: Hud.Elements() keys, first visible one wins
local TARGETS: { [string]: { string } } = {
	Attack = { "WeaponRow", "Bar" },
	Gems = { "XP", "Plate" },
	Portal = { "Stage", "StageGoal" },
	Boss = { "Boss", "BossMeter" },
}

local TITLE_SIZE = Theme.Type.Title.Size
local BODY_SIZE = Theme.Type.Body.Size
local ICON = 48
local ARROW = 22
local SKIP_W, SKIP_H = 150, 38

type Tip = { Id: string, Text: string, Title: string, Icon: string, Seconds: number, Done: (() -> boolean)?, Aim: (() -> Vector2?)? }

local kit: { [string]: any } = {}
local ui: { [string]: any } = {}
local rootFrame: Frame? = nil
local tutorialDone = true -- until the profile says otherwise
local seen: { [string]: boolean } = {}
local queue: { Tip } = {}
local current: { [string]: any }? = nil
local nextAt = 0
local run: { [string]: any } = {} -- per-run trigger state

------------------------------------------------------------------------------------------
-- Eligibility
------------------------------------------------------------------------------------------

local function tipsOn(): boolean
	return ClientSettings.Get("Tips") ~= false
end

local function wants(id: string): boolean
	if not tipsOn() or seen[id] then
		return false
	end
	if COOP[id] then
		return true
	end
	return not tutorialDone
end

local function markSeen(id: string)
	if not seen[id] then
		seen[id] = true
		Remotes.Get("Tutorial"):FireServer("Seen", id)
	end
end

local function queued(id: string): boolean
	if current and current.Id == id then
		return true
	end
	for _, q in ipairs(queue) do
		if q.Id == id then
			return true
		end
	end
	return false
end

local function push(id: string, title: string, body: string, icon: string, seconds: number?, first: boolean?)
	if not wants(id) or queued(id) then
		return
	end
	table.insert(queue, first and 1 or (#queue + 1), { Id = id, Title = title, Text = body, Icon = icon, Seconds = seconds or T.HintSeconds })
end

-- A SmartTutorial tip: done() ends it early once its action happened, aim() is the point
-- its pointer aims at (root pixels) or nil.
local function pushSmart(id: string, body: string, icon: string, seconds: number?, done: (() -> boolean)?, aim: (() -> Vector2?)?)
	if not wants(id) or queued(id) then
		return
	end
	table.insert(queue, { Id = id, Title = "", Text = body, Icon = icon, Seconds = seconds or S.Seconds or 8, Done = done, Aim = aim })
end

------------------------------------------------------------------------------------------
-- The callout
------------------------------------------------------------------------------------------

local function build(root: Frame)
	rootFrame = root
	-- the gold ring around the element a tip explains (under the card)
	local focus = new("Frame", { Name = "TipFocus", BackgroundColor3 = C.Primary, BackgroundTransparency = 0.85, Visible = false, Active = false, ZIndex = Theme.Z.Toast }, root)
	UIKit.corner(focus, Theme.Radius.M)
	ui.FocusStroke = UIKit.stroke(focus, C.Primary, 3, 0)
	UIAnim.PulseStroke(ui.FocusStroke, 2, 4)
	ui.Focus = focus

	local holder, face = UIKit.Surface(root, { Name = "TipCard", Radius = Theme.Radius.L, Transparency = 0.02, Edge = C.PanelEdge, EdgeThickness = 2, EdgeTransparency = 0, Visible = false, ZIndex = Theme.Z.Toast, AnchorPoint = Vector2.new(0.5, 0), Size = UDim2.fromOffset(560, 140) })
	holder.Active = false
	ui.Card = holder
	ui.Face = face
	-- the arrow: a diamond behind the face, half of it sticking out toward the target
	local arrow = new("Frame", { Name = "Arrow", AnchorPoint = Vector2.new(0.5, 0.5), Size = UDim2.fromOffset(ARROW, ARROW), Rotation = 45, BackgroundColor3 = C.Panel, BorderSizePixel = 0, ZIndex = 0, Visible = false }, holder)
	UIKit.stroke(arrow, C.PanelEdge, 2, 0)
	ui.Arrow = arrow
	UIKit.padding(face, 14, 16, 14, 16)

	local iconWell = new("Frame", { Name = "IconWell", BackgroundColor3 = C.BluePale, BackgroundTransparency = 0, Size = UDim2.fromOffset(ICON, ICON) }, face)
	UIKit.corner(iconWell, 999)
	UIKit.stroke(iconWell, C.Blue, 2, 0)
	ui.IconWell = iconWell
	ui.Step = UIKit.Badge(face, "TIP 1 / 5", "Gold", { Name = "Step", AnchorPoint = Vector2.new(1, 0), Position = UDim2.fromScale(1, 0) })
	ui.Title = UIKit.Role(face, "Title", "", { Name = "Title", Position = UDim2.fromOffset(ICON + 14, 0), TextColor3 = C.BlueDeep, TextTruncate = Enum.TextTruncate.AtEnd })
	ui.Body = UIKit.Role(face, "Body", "", {
		Name = "Body",
		Position = UDim2.fromOffset(ICON + 14, TS(TITLE_SIZE) + 6),
		TextWrapped = true,
		TextYAlignment = Enum.TextYAlignment.Top,
		TextColor3 = C.Text,
	})
	ui.Skip = UIKit.Button(face, {
		Kind = "Outline",
		Title = "SKIP TIPS",
		Icon = "skip",
		IconSize = 16,
		Align = "Center",
		AnchorPoint = Vector2.new(1, 1),
		Position = UDim2.fromScale(1, 1),
		Size = UDim2.fromOffset(SKIP_W, SKIP_H),
		Shadow = false,
		Name = "SkipTips",
		OnClick = function()
			Tutorial.Skip()
		end,
	})
	-- time left: a gold bar left of SKIP TIPS
	local track = new("Frame", { Name = "TimerTrack", BackgroundColor3 = C.PanelInset, BorderSizePixel = 0, AnchorPoint = Vector2.new(0, 1) }, face)
	UIKit.corner(track, 999)
	ui.TimerTrack = track
	ui.Timer = new("Frame", { Name = "Timer", BackgroundColor3 = C.Blue, BorderSizePixel = 0, Size = UDim2.fromScale(1, 1) }, track)
	UIKit.corner(ui.Timer, 999)
end

-- Wrapped height of the body text in px (1-3 lines), measured like Roblox lays it out.
local function bodyLines(body: string, width: number): number
	local ok, size = pcall(function()
		return TextService:GetTextSize(body, TS(BODY_SIZE), Enum.Font.SourceSansSemibold, Vector2.new(width, 1000))
	end)
	if ok and typeof(size) == "Vector2" then
		return math.clamp(math.ceil(size.Y / TS(BODY_SIZE) - 0.2), 1, 3)
	end
	return 2
end

-- Rect of a HUD element in root (virtual) pixels, or nil when it is not on screen.
local function targetRect(id: string): (Vector2?, Vector2?)
	local keys = TARGETS[id]
	local root = rootFrame
	if not keys or not root then
		return nil, nil
	end
	local ok, els = pcall(Hud.Elements)
	if not ok or type(els) ~= "table" then
		return nil, nil
	end
	local v: Vector2 = kit.VirtualSize()
	local scale = v.X > 0 and root.AbsoluteSize.X / v.X or 1
	for _, k in ipairs(keys) do
		local g = els[k]
		if type(g) == "table" then
			g = g.Frame -- a UIKit component (Meter, Chip ...)
		end
		if typeof(g) == "Instance" and g:IsA("GuiObject") and g.Visible and g.AbsoluteSize.X > 4 then
			local shown = true
			local a: Instance? = g.Parent
			while a and a ~= root do
				if a:IsA("GuiObject") and not a.Visible then
					shown = false
					break
				end
				a = a.Parent
			end
			if shown then
				local pos = (g.AbsolutePosition - root.AbsolutePosition) / scale
				return pos, g.AbsoluteSize / scale
			end
		end
	end
	return nil, nil
end

-- Sizes the card's insides for width w; returns its height.
local function sizeCard(w: number): number
	local textW = w - 32 - ICON - 14
	local lines = bodyLines(ui.Body.Text, textW)
	local bodyH = lines * (TS(BODY_SIZE) + 3)
	ui.Title.Size = UDim2.fromOffset(textW - 96, TS(TITLE_SIZE) + 4)
	ui.Body.Size = UDim2.fromOffset(textW, bodyH)
	ui.TimerTrack.Position = UDim2.new(0, ICON + 14, 1, -(SKIP_H / 2 - 3))
	ui.TimerTrack.Size = UDim2.new(1, -(ICON + 14 + SKIP_W + 16), 0, 6)
	local h = 28 + TS(TITLE_SIZE) + 6 + bodyH + 10 + SKIP_H
	ui.Card.Size = UDim2.fromOffset(w, h)
	return h
end

--[[
	Places the card (and its arrow / focus ring) for the current tip: next to its target
	(below an element in the top half, above one in the bottom half) with the arrow at the
	target; without a target, above the ability bar (landscape) or under the hero
	(portrait). The hero stands at the screen centre: when the card would cover it (short
	landscape phones), the card moves to the side of the screen with more room, narrower.
]]
-- Screen rects (virtual units, x / y / w / h) of what a tip card must not cover. The
-- first list holds the touch controls the card must clear; the second everything else a
-- new spot for it must also leave visible.
local function obstacleRects(W: number): ({ { number } }, { { number } })
	local parent = ui.Card and ui.Card.Parent :: GuiObject?
	if not parent or parent.AbsoluteSize.X < 1 then
		return {}, {}
	end
	local k = W / parent.AbsoluteSize.X
	local origin = parent.AbsolutePosition
	local function rect(g: Instance?, pad: number): { number }?
		if not g or not g:IsA("GuiObject") or not g.Visible or g.AbsoluteSize.X < 1 then
			return nil
		end
		local anc: Instance? = g.Parent
		while anc and anc:IsA("GuiObject") do
			if not anc.Visible then
				return nil
			end
			anc = anc.Parent
		end
		local p, sz = (g.AbsolutePosition - origin) * k, g.AbsoluteSize * k
		return { p.X - pad, p.Y - pad, sz.X + 2 * pad, sz.Y + 2 * pad }
	end
	local controls: { { number } }, others: { { number } } = {}, {}
	local function add(list: { { number } }, r: { number }?)
		if r then
			table.insert(list, r)
		end
	end
	local pg = player:FindFirstChildOfClass("PlayerGui")
	if pg then
		add(controls, rect(pg:FindFirstChild("JumpButton", true), 8))
		local ping = pg:FindFirstChild("Ping", true)
		if ping and ping:IsA("GuiButton") then
			add(controls, rect(ping, 8))
		end
	end
	add(others, rect(MiniMap.Elements().Holder, 6))
	add(others, rect(LootUI.Elements().Prompt, 6))
	local team = TeamUI.Elements()
	add(others, rect(team.List, 6))
	for _, mk in pairs(team.Markers or {}) do
		local r = rect(mk.Holder, 12)
		if r then
			r[4] += 26 -- the name / progress label under the ring
			add(others, r)
		end
	end
	local hud = Hud.Elements()
	add(others, rect(hud.Stage, 6))
	add(others, rect(hud.TimerPill, 6))
	add(others, rect(hud.Plate and hud.Plate:FindFirstChild("Body"), 6))
	add(others, rect(hud.Bar, 6))
	add(others, rect(hud.Counters, 6))
	return controls, others
end

local function clearOfControls(x: number, y: number, w: number, h: number, W: number, H: number): (number, number, number, number)
	local controls, others = obstacleRects(W)
	local function hitsAny(list: { { number } }, cx: number, cy: number, cw: number?, ch: number?): boolean
		local ww, hh = cw or w, ch or h
		local l, t = cx - ww / 2, cy
		for _, r in ipairs(list) do
			-- (a few px of touch is fine: the rects already carry padding)
			if l + 4 < r[1] + r[3] and l + ww > r[1] + 4 and t + 4 < r[2] + r[4] and t + hh > r[2] + 4 then
				return true
			end
		end
		return false
	end
	if not hitsAny(controls, x, y) then
		return x, y, w, h
	end
	local function aboveControls(cx: number): number
		local top = y
		for _, r in ipairs(controls) do
			local l = cx - w / 2
			if l < r[1] + r[3] and l + w > r[1] then
				top = math.min(top, r[2] - 8 - h)
			end
		end
		return top
	end
	local xl, xr = 12 + w / 2, W - 12 - w / 2
	local candidates = {
		{ x, aboveControls(x), w, h },
		{ x < W / 2 and xr or xl, y, w, h },
		{ x < W / 2 and xr or xl, aboveControls(x < W / 2 and xr or xl), w, h },
		{ xl, math.max(8, Hud.TopBottom() + 8), w, h },
	}
	-- the top-left corner under Roblox's buttons, narrowed to end before the top HUD
	-- (timer / vitals) that starts to its right
	local cornerY = 56
	local edge = W
	for _, r in ipairs(others) do
		if r[2] < cornerY + h and r[1] > 40 then
			edge = math.min(edge, r[1])
		end
	end
	local cw = math.min(w, edge - 24)
	if cw >= 320 and bodyLines(ui.Body.Text, cw - 32 - ICON - 14) <= 2 then
		local ch = sizeCard(cw)
		table.insert(candidates, { 12 + cw / 2, cornerY, cw, ch })
	end
	for _, c in ipairs(candidates) do
		local cx, cy, cw2, ch2 = c[1], c[2], c[3], c[4]
		local hero = not (math.abs(cx - W / 2) < cw2 / 2 + 70 and cy < H / 2 + 80 and cy + ch2 > H / 2 - 80)
		if cy >= 8 and cy + ch2 <= H - 8 and hero and not hitsAny(controls, cx, cy, cw2, ch2) and not hitsAny(others, cx, cy, cw2, ch2) then
			return cx, cy, cw2, ch2
		end
	end
	-- nowhere fully free: at least keep the controls clear
	for _, c in ipairs(candidates) do
		if c[2] >= 8 and c[2] + c[4] <= H - 8 and not hitsAny(controls, c[1], c[2], c[3], c[4]) then
			return c[1], c[2], c[3], c[4]
		end
	end
	return x, y, w, h
end

local function layout()
	if not ui.Card or not current then
		return
	end
	local v: Vector2 = kit.VirtualSize()
	local W, H = v.X, v.Y
	local portrait: boolean = kit.IsPortrait()
	local w = portrait and (W - 24) or math.min(520, W - 48)
	local h = sizeCard(w)

	local pos, size = targetRect(current.Id)
	local tx = W / 2
	local y: number
	local dir = 0 -- arrow: -1 up (target above), 1 down (target below), 0 none
	if pos and size then
		tx = pos.X + size.X / 2
		dir = (pos.Y + size.Y / 2 < H / 2) and -1 or 1
	end
	local function place(): number
		if pos and size then
			local yy = dir < 0 and (pos.Y + size.Y + ARROW / 2 + 14) or (pos.Y - h - ARROW / 2 - 14)
			return math.clamp(yy, 8, H - h - 8)
		elseif portrait then
			return H * 0.6
		end
		return math.max(8, Hud.BarTop() - 12 - h)
	end
	y = place()
	local x = math.clamp(tx, w / 2 + 12, W - w / 2 - 12)
	-- keep the hero (screen centre) clear
	local heroHalf = Vector2.new(70, 80)
	local function coversHero(cx: number, cy: number, cw: number, ch: number): boolean
		return math.abs(cx - W / 2) < cw / 2 + heroHalf.X and cy < H / 2 + heroHalf.Y and cy + ch > H / 2 - heroHalf.Y
	end
	if not portrait and coversHero(x, y, w, h) then
		local w2 = math.max(300, math.min(w, W / 2 - heroHalf.X - 24))
		h = sizeCard(w2)
		w = w2
		y = place()
		local right = tx >= W / 2
		-- a card with no target takes the side where it covers nothing that matters: the
		-- minimap (right, phones), a revive marker over a fallen teammate, the loot prompt
		-- (the card lets touches through, so a thumb landing on it still moves the hero)
		if not (pos and size) then
			local function covers(cx: number): boolean
				local l, r, t, b = cx - w / 2, cx + w / 2, y, y + h
				local function hits(g: GuiObject?): boolean
					if not g or not g.Visible then
						return false
					end
					local gx, gy = g.Position.X.Offset - g.AnchorPoint.X * g.Size.X.Offset, g.Position.Y.Offset - g.AnchorPoint.Y * g.Size.Y.Offset
					local gw, gh = g.Size.X.Offset, g.Size.Y.Offset + 24 -- + the label under a marker
					return l < gx + gw and r > gx and t < gy + gh and b > gy
				end
				if hits(MiniMap.Elements().Holder :: Frame?) or hits(LootUI.Elements().Prompt :: Frame?) then
					return true
				end
				for _, mk in pairs(TeamUI.Elements().Markers or {}) do
					if hits(mk.Holder) then
						return true
					end
				end
				return false
			end
			local xr, xl = W - 12 - w / 2, 12 + w / 2
			if covers(right and xr or xl) and not covers(right and xl or xr) then
				right = not right
			end
			-- both sides blocked and the card would lie over the minimap: drop it under the
			-- map when there is room (iphone with team rows)
			local map = MiniMap.Elements().Holder :: Frame?
			local cx = right and xr or xl
			if map and map.Visible then
				local mx, my = map.Position.X.Offset, map.Position.Y.Offset
				local mw, mh = map.Size.X.Offset, map.Size.Y.Offset
				if cx - w / 2 < mx + mw and cx + w / 2 > mx and y < my + mh and y + h > my and my + mh + 8 + h <= H - 8 then
					y = my + mh + 8
				end
			end
		end
		x = right and (W - 12 - w / 2) or (12 + w / 2)
	end
	-- touch controls (JUMP, PING) must never sit under the card: a tip without a target
	-- moves up / to the other side / to the top-left corner, to the first spot that covers
	-- no control, map, team row, revive marker, loot prompt or the hero
	if not (pos and size) then
		x, y, w, h = clearOfControls(x, y, w, h, W, H)
		h = sizeCard(w) -- the spot search may have measured other widths
	end
	if pos and size then
		local ax = math.clamp(tx - (x - w / 2), 28, w - 28)
		ui.Arrow.Position = UDim2.fromOffset(ax, dir < 0 and 0 or h)
		ui.Arrow.Visible = true
		ui.Focus.Position = UDim2.fromOffset(pos.X - 6, pos.Y - 6)
		ui.Focus.Size = UDim2.fromOffset(size.X + 12, size.Y + 12)
		ui.Focus.Visible = true
	else
		ui.Arrow.Visible = false
		ui.Focus.Visible = false
	end
	current.Dir = dir
	ui.Card.Position = UDim2.fromOffset(math.floor(x), math.floor(y))
end

local function setIcon(name: string)
	for _, c in ipairs(ui.IconWell:GetChildren()) do
		if c:IsA("Frame") then
			c:Destroy()
		end
	end
	Icons.Draw(ui.IconWell, name, { Size = 30, AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.5), Back = C.BluePale })
end

local function hideCard()
	if current then
		current = nil
		if smart() then
			TutorialBubble.Hide()
			return
		end
		local card = ui.Card :: Frame
		ui.Focus.Visible = false
		UIAnim.PopOut(card, function()
			if not current then
				card.Visible = false
			end
		end)
	end
end

-- "TIP n / 5": n counts the tour tips already seen (this run or before) plus this one, so
-- the count only goes up even when the portal tip comes before the gems one.
local function stepText(id: string): string
	if COOP[id] then
		return "TEAM TIP"
	end
	if not table.find(TOUR, id) then
		return "TIP"
	end
	local n = 1
	for _, t in ipairs(TOUR) do
		if t ~= id and seen[t] then
			n += 1
		end
	end
	return string.format("TIP %d / %d", math.min(n, #TOUR), #TOUR)
end

local function showNext(now: number)
	local tip = table.remove(queue, 1)
	if not tip then
		return
	end
	if not wants(tip.Id) then
		return
	end
	current = { Id = tip.Id, Until = now + tip.Seconds, Seconds = tip.Seconds, Since = now, Done = tip.Done }
	if smart() then
		-- input-aware lines are read when the tip shows (the device in hand may have changed)
		local text = tip.Id == "Move" and InputPrompts.MoveShort() or tip.Id == "Chest" and InputPrompts.OpenChest() or tip.Text
		if COOP[tip.Id] then
			text = tip.Title .. ": " .. text
		end
		TutorialBubble.Show(text, tip.Icon, tip.Aim)
		markSeen(tip.Id)
		if kit.Audio then
			pcall(kit.Audio.Play, "Tip")
		end
		return
	end
	ui.Title.Text = tip.Title
	-- input-aware text is read when the tip shows (the device in hand may have changed)
	ui.Body.Text = tip.Id == "Move" and InputPrompts.Move() or tip.Text
	ui.Step.Text = stepText(tip.Id)
	setIcon(tip.Icon)
	layout()
	ui.Card.Visible = true
	-- scale-only entrance: layout() owns the card's Position (a Position tween would
	-- override any relayout during it and leave the card at a stale spot)
	UIAnim.Pop(ui.Card, 0, 0.9)
	if not ClientSettings.Reduced() then
		-- the icon spins in, the TIP badge pops, a glint crosses the card, and the ring
		-- around the explained element pulses out once
		ui.IconWell.Rotation = -180
		UIAnim.Tween(ui.IconWell, 0.55, { Rotation = 0 }, Enum.EasingStyle.Back)
		UIAnim.Pop(ui.IconWell, 0.1, 0.4)
		UIAnim.Pop(ui.Step, 0.3, 0.3)
		local clip = new("Frame", { Name = "ShineClip", BackgroundTransparency = 1, Size = UDim2.fromScale(1, 1), ClipsDescendants = true, ZIndex = 20 }, ui.Card)
		UIKit.corner(clip, Theme.Radius.L)
		UIAnim.SweepOnce(clip, C.Panel, 0.6, 0.8)
		task.delay(0.8, function()
			clip:Destroy()
		end)
		if ui.Focus.Visible then
			UIAnim.Pop(ui.Focus, 0.15, 1.25)
			UIAnim.Ring(rootFrame :: Frame, ui.Focus.Position + UDim2.fromOffset(ui.Focus.Size.X.Offset / 2, ui.Focus.Size.Y.Offset / 2), C.Primary, math.max(ui.Focus.Size.X.Offset, ui.Focus.Size.Y.Offset) + 40, 0.5)
		end
	end
	markSeen(tip.Id)
	if kit.Audio then
		pcall(kit.Audio.Play, "Tip")
	end
end

------------------------------------------------------------------------------------------
-- Triggers
------------------------------------------------------------------------------------------

local function moveText(): string
	return InputPrompts.Move()
end

local function heroPos(): Vector3?
	local char = player.Character
	local root = char and char.PrimaryPart
	return root and root.Position or nil
end

-- The first run's welcome is on (Config.FirstRun; set by the server for that run only).
local function welcome(): boolean
	return player:GetAttribute("FirstRunBoost") == true
end

------------------------------------------------------------------------------------------
-- SmartTutorial triggers
------------------------------------------------------------------------------------------

-- The centre of a HUD target (TARGETS keys) in root pixels, or nil when it is not shown.
local function hudAim(id: string): () -> Vector2?
	return function()
		local pos, size = targetRect(id)
		if pos and size then
			return pos + size / 2
		end
		return nil
	end
end

-- A world point in root pixels (clamped to the screen when it is off it).
local function worldAim(get: () -> Vector3?): () -> Vector2?
	return function()
		local p = get()
		local cam = workspace.CurrentCamera
		if not p or not cam or not rootFrame then
			return nil
		end
		local vp = cam:WorldToViewportPoint(p)
		if vp.Z <= 0 then
			return nil
		end
		local sg = rootFrame:FindFirstAncestorOfClass("ScreenGui")
		local inset: Vector2 = Vector2.zero
		if sg and not sg.IgnoreGuiInset then
			inset = GuiService:GetGuiInset()
		end
		local pt = TutorialBubble.ToRoot(Vector2.new(vp.X, vp.Y) - inset)
		if not pt then
			return nil
		end
		local v: Vector2 = kit.VirtualSize()
		return Vector2.new(math.clamp(pt.X, 8, v.X - 8), math.clamp(pt.Y, 8, v.Y - 8))
	end
end

-- The nearest live XP gem (workspace.SwarmGems, attribute Base) within maxD studs.
local function nearestGem(maxD: number): Vector3?
	local folder = workspace:FindFirstChild("SwarmGems")
	local hp = heroPos()
	if not folder or not hp then
		return nil
	end
	local best, bd = nil, maxD * maxD
	for _, g in ipairs(folder:GetChildren()) do
		if g:IsA("BasePart") and g:GetAttribute("Active") == true then
			local b = g:GetAttribute("Base")
			if typeof(b) == "Vector3" then
				local dx, dz = b.X - hp.X, b.Z - hp.Z
				local d = dx * dx + dz * dz
				if d <= bd then
					best, bd = b, d
				end
			end
		end
	end
	return best
end

-- The nearest ready chest (workspace.SwarmLoot, LootKind Chest) within maxD studs.
local function nearChest(maxD: number): Model?
	local folder = workspace:FindFirstChild("SwarmLoot")
	local hp = heroPos()
	if not folder or not hp then
		return nil
	end
	for _, m in ipairs(folder:GetChildren()) do
		if m:IsA("Model") and (m:GetAttribute("LootKind") or "Chest") == "Chest" and m:GetAttribute("State") == "Ready" then
			local pos = m:GetAttribute("Pos")
			if typeof(pos) == "Vector3" and Vector2.new(pos.X - hp.X, pos.Z - hp.Z).Magnitude <= maxD then
				return m
			end
		end
	end
	return nil
end

local function xpMark(): string
	return tostring(player:GetAttribute("Level") or 0) .. ":" .. tostring(player:GetAttribute("XP") or 0)
end

local function smartStart()
	pushSmart("Move", InputPrompts.MoveShort(), "boot", S.Seconds, function()
		local pos = heroPos()
		run.StartPos = run.StartPos or pos -- the character may arrive after the run start
		local start = run.StartPos
		return start ~= nil and pos ~= nil and ((pos - start) * Vector3.new(1, 0, 1)).Magnitude >= (S.MoveStuds or 10)
	end)
end

local function smartTriggers(state: Configuration)
	local now = os.clock()
	-- 2: the first kill
	if not run.Attack and (player:GetAttribute("Kills") or 0) > (run.Kills0 or 0) then
		run.Attack = true
		pushSmart("Attack", "Your weapon attacks by itself", "sword", S.AttackSeconds or 4, nil, hudAim("Attack"))
	end
	-- 3 and 5 scan the world a few times a second
	if now >= (run.ScanAt or 0) then
		run.ScanAt = now + 0.25
		if not run.Gems and wants("Gems") and nearestGem(S.GemNearStuds or 30) then
			run.Gems = true
			local mark = xpMark()
			pushSmart("Gems", "Pick up the blue gems for XP", "gem", S.Seconds, function()
				return xpMark() ~= mark
			end, worldAim(function()
				return nearestGem((S.GemNearStuds or 30) * 2)
			end))
		end
		if not run.Chest and wants("Chest") then
			local chest = nearChest(S.ChestStuds or 12)
			if chest then
				run.Chest = true
				pushSmart("Chest", InputPrompts.OpenChest(), "chest", S.Seconds, function()
					return chest.Parent == nil or chest:GetAttribute("State") ~= "Ready"
				end, worldAim(function()
					local pos = chest:GetAttribute("Pos")
					return typeof(pos) == "Vector3" and pos + Vector3.new(0, 2, 0) or nil
				end))
			end
		end
	end
	-- 6: the portal, once revealed (its banner first)
	local stagePhase = state:GetAttribute("StagePhase") or "None"
	if not run.Portal and stagePhase == "Explore" and state:GetAttribute("PortalHint") == true then
		run.RevealSeen = run.RevealSeen or now
		if now - run.RevealSeen >= (T.PortalTipDelay or 2) then
			run.Portal = true
			-- a player already charging the portal has found it: no tip
			if (tonumber(state:GetAttribute("PortalCharge")) or 0) <= 0 then
				pushSmart("Portal", "Find and charge the portal", "portal", S.Seconds, function()
					return (tonumber(state:GetAttribute("PortalCharge")) or 0) > 0 or state:GetAttribute("StagePhase") ~= "Explore"
				end, function()
					local arrow = StageUI.Elements().Arrow
					if typeof(arrow) == "Instance" and arrow:IsA("GuiObject") and arrow.Visible then
						return TutorialBubble.ToRoot(arrow.AbsolutePosition + arrow.AbsoluteSize / 2)
					end
					return worldAim(function()
						local pp = state:GetAttribute("PortalPos")
						return typeof(pp) == "Vector3" and pp or nil
					end)()
				end)
			end
		end
	end
	-- 7: the first boss
	if not run.Boss and stagePhase == "Boss" then
		run.Boss = true
		pushSmart("Boss", "Bosses guard the way out", "skull", S.Seconds, function()
			return state:GetAttribute("StagePhase") ~= "Boss"
		end, hudAim("Boss"))
	end
end

local function startRun(_state: Configuration)
	table.clear(run)
	run.Start = os.clock()
	run.StartPos = heroPos()
	run.Kills0 = player:GetAttribute("Kills") or 0
	if smart() then
		smartStart()
		return
	end
	push("Move", "Move", moveText(), "boot")
	-- the first run's welcome (server attribute FirstRunBoost: the first level-up comes
	-- within ~20 s) keeps this one short so the gem tip lands before the cards
	push("Attack", "Auto attack", "Your weapon attacks automatically. Keep moving to dodge enemies!", "sword", welcome() and 4.5 or nil)
end

local function triggers(state: Configuration)
	-- a group run: the team rules first (checked for a few seconds: the player count may
	-- arrive just after InRun)
	if not run.Team and os.clock() - (run.Start or 0) < 8 and (state:GetAttribute("Participants") or 1) > 1 then
		run.Team = true
		push("TeamRules", "Team run", "Gem XP is shared by every living teammate. Gold and items are your own.", "people2", T.HintSeconds + 2, true)
	end
	if smart() then
		smartTriggers(state)
	end
	-- gems after the first kill
	if not smart() and not run.Gems and (player:GetAttribute("Kills") or 0) > (run.Kills0 or 0) then
		run.Gems = true
		-- first run: straight after the current tip (the first level-up is close)
		push("Gems", "Collect gems", "Walk over blue gems to collect XP. A full bar = an upgrade!", "gem", nil, welcome())
	end
	-- the objective, once the portal is revealed (its banner shows first)
	local stagePhase = state:GetAttribute("StagePhase") or "None"
	if not smart() and not run.Portal and stagePhase == "Explore" and state:GetAttribute("PortalHint") == true then
		run.RevealSeen = run.RevealSeen or os.clock()
		if os.clock() - run.RevealSeen >= (T.PortalTipDelay or 2) then
			run.Portal = true
			-- A player already charging the portal has found it: no tip.
			if (tonumber(state:GetAttribute("PortalCharge")) or 0) <= 0 then
				local boss = tostring(state:GetAttribute("StageBoss") or "")
				local body = string.format("Follow the PORTAL arrow, then stand in its ring for %s s to summon %s.",
					tostring(Config.Stages.ChargeSeconds), boss ~= "" and ("the " .. boss) or "the boss")
				push("Portal", "Reach the portal", body, "portal", T.HintSeconds + 1)
			end
		end
	end
	if not smart() and not run.Boss and stagePhase == "Boss" then
		run.Boss = true
		local boss = tostring(state:GetAttribute("BossName") or state:GetAttribute("StageBoss") or "")
		local who = boss ~= "" and ("the " .. boss) or "the boss"
		push("Boss", "Dodge the red", string.format("Red floor shapes show where %s strikes. Step out!", who), "skull")
	end
	-- the first fallen teammate
	if not run.Revive then
		for _, p in ipairs(Players:GetPlayers()) do
			if p ~= player and p:GetAttribute("InRun") == true and p:GetAttribute("Alive") == false and (tonumber(p:GetAttribute("PartnerRevivesLeft")) or 0) > 0 and p:GetAttribute("AwaitingRevive") ~= true then
				run.Revive = true
				local modeDef = (Config.Modes :: any)[state:GetAttribute("Mode") or ""]
				local secs = (modeDef and modeDef.PartnerRevive and modeDef.PartnerRevive.Seconds) or 2
				push("Revive", "Revive " .. p.DisplayName, string.format("Stand beside them for %s second%s to revive.", tostring(secs), secs == 1 and "" or "s"), "revive")
				break
			end
		end
	end
	-- Move ends early once the hero has walked a few steps
	if not smart() and current and current.Id == "Move" and run.StartPos then
		local pos = heroPos()
		if pos and (pos - run.StartPos).Magnitude > 14 and os.clock() - current.Since > 2.5 then
			current.Until = math.min(current.Until, os.clock() + 0.6)
		end
	end
end

------------------------------------------------------------------------------------------
-- Public
------------------------------------------------------------------------------------------

-- Profile from ProfileSync: TutorialDone, SeenTips.
function Tutorial.SetProfile(p: { [string]: any })
	tutorialDone = p.TutorialDone ~= false
	if smart() and (tonumber(p.TutorialStep) or 0) >= (S.Runs or 2) then
		tutorialDone = true -- the two tutorial runs are over (the server agrees)
	end
	if type(p.SeenTips) == "table" then
		-- the server's list plus whatever this session showed (its "Seen" may be in flight;
		-- Replay clears both)
		for id, on in pairs(p.SeenTips) do
			if on == true then
				seen[id] = true
			end
		end
	end
end

-- The first level-up offer's explanation (nil once seen or when tips are off).
function Tutorial.LevelUpHint(): string?
	-- the interactive walkthrough's UPGRADE step (WalkthroughClient)
	local walk = WalkthroughClient.LevelUpHint()
	if walk then
		markSeen("LevelUp")
		return walk
	end
	if not wants("LevelUp") then
		return nil
	end
	markSeen("LevelUp")
	if smart() then
		-- step 4: the line under LEVEL UP! points the player at the cards; it never blocks them
		return welcome() and "Choose an upgrade: try the NEW weapon!" or "Choose an upgrade"
	end
	-- input-neutral: the line under the cards already says how to choose on this device
	-- (InputPrompts.Choose), so this one only explains what the cards are
	if welcome() then
		return "Choose one: try the NEW weapon!"
	end
	return "Choose one: a new weapon, an upgrade or a passive"
end

-- "Skip tips": no more tutorial hints (co-op tips stay until seen or Show tips is off).
function Tutorial.Skip()
	tutorialDone = true
	for i = #queue, 1, -1 do
		if not COOP[queue[i].Id] then
			table.remove(queue, i)
		end
	end
	hideCard()
	Remotes.Get("Tutorial"):FireServer("Skip")
end

-- Settings > Replay tips: every hint again from the next run.
function Tutorial.Replay()
	tutorialDone = false
	table.clear(seen)
	Remotes.Get("Tutorial"):FireServer("Replay")
end

-- Hides everything (run end, tips switched off).
function Tutorial.Clear()
	table.clear(queue)
	hideCard()
end

--[[
	Per frame. blocked = a modal is open (level-up cards, pause, results): the current hint
	waits (its clock stops) and no new one starts.
]]
function Tutorial.Update(dt: number, state: Configuration, inRun: boolean, blocked: boolean)
	if not ui.Card then
		return
	end
	-- the open quick-ping wheel covers the middle of the screen: tips wait behind it
	blocked = blocked or FeatureHud.PingWheelOpen()
	local now = os.clock()
	-- the interactive first-run walkthrough (WalkthroughClient, Config.Features.Walkthrough)
	-- owns the bubble while it runs; the tips it replaces never show
	local walking, walkStarted = WalkthroughClient.Update(dt, inRun and tipsOn(), blocked)
	if walking then
		if walkStarted then
			for _, id in ipairs(WALK_TIPS) do
				markSeen(id)
			end
			for i = #queue, 1, -1 do
				if not COOP[queue[i].Id] then
					table.remove(queue, i)
				end
			end
			if current and not COOP[current.Id] then
				if smart() then
					current = nil -- the walkthrough's line already took the bubble
				else
					hideCard()
				end
			end
		end
		return
	end
	if not inRun or not tipsOn() then
		if run.Start then
			table.clear(run)
		end
		Tutorial.Clear()
		return
	end
	if not run.Start then
		startRun(state)
		nextAt = now + T.FirstDelay
	end
	if (state:GetAttribute("Phase") or "") ~= "Running" then
		Tutorial.Clear()
		return
	end
	triggers(state)
	if current then
		if smart() then
			-- behind a panel (UIState owner, the stage-start card) the tip waits, hidden
			TutorialBubble.SetCovered(blocked)
			if blocked then
				current.Until += dt
				return
			end
			TutorialBubble.Step(dt)
			if current.Done and not current.Finished then
				local ok, done = pcall(current.Done)
				if ok and done then
					-- the action is done: fade shortly
					current.Finished = true
					current.Until = math.min(current.Until, now + 0.6)
				end
			end
			if now >= current.Until then
				hideCard()
				nextAt = now + (S.GapSeconds or T.GapSeconds)
			end
			return
		end
		if blocked then
			current.Until += dt
			ui.Card.Visible = false
			ui.Focus.Visible = false
			return
		end
		ui.Card.Visible = true
		local left = math.max(0, current.Until - now)
		ui.Timer.Size = UDim2.fromScale(math.clamp(left / current.Seconds, 0, 1), 1)
		-- follow the element (the HUD may re-lay out), after the slide-in has finished
		current.Relayout = (current.Relayout or 0) + dt
		if current.Relayout > 0.25 and now - current.Since > 0.5 then
			current.Relayout = 0
			layout()
		end
		if left <= 0 then
			hideCard()
			nextAt = now + T.GapSeconds
		end
	elseif not blocked and now >= nextAt and #queue > 0 then
		showNext(now)
	end
end

function Tutorial.Build(root: Frame, k: { [string]: any })
	kit = k
	build(root)
	TutorialBubble.Build(root, k)
	WalkthroughClient.Build(root, k)
	kit.OnRelayout(layout)
	-- the player switched device (touch / keyboard and mouse / gamepad): reword the shown tip
	InputPrompts.OnChanged(function()
		if smart() then
			if current and current.Id == "Move" then
				TutorialBubble.SetText(InputPrompts.MoveShort())
			elseif current and current.Id == "Chest" then
				TutorialBubble.SetText(InputPrompts.OpenChest())
			end
			return
		end
		if current and current.Id == "Move" and ui.Body then
			ui.Body.Text = moveText()
			layout()
		end
	end)
	ClientSettings.OnChanged(function(key, value)
		if key == "Tips" and value == false then
			Tutorial.Clear()
		end
	end)
end

-- For the preview tool / tests.
function Tutorial.Elements(): { [string]: any }
	ui.Bubble = TutorialBubble.Elements()
	return ui
end

-- For tests: the tip on screen (nil when none), the queued ids, and whether it is hidden
-- behind a panel.
function Tutorial.Current(): (string?, { string }, boolean)
	local ids = {}
	for _, q in ipairs(queue) do
		table.insert(ids, q.Id)
	end
	return current and current.Id or nil, ids, current ~= nil and not TutorialBubble.Showing()
end

return Tutorial
