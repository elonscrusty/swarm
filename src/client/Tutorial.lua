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
	  Attack    "your weapons attack on their own" → the weapon row
	  Gems      after the first kill: gems are XP → the XP bar
	  LevelUp   the first level-up offer: one line under LEVEL UP! explains the cards
	            (UIBuilder asks LevelUpHint; not a callout)
	  Portal    after Config.Tutorial.PortalTipAt run seconds: the stage objective → the
	            stage pill
	  Boss      when the stage boss appears: red floor shapes show where it strikes → the
	            boss bar
	Co-op tips (once ever, also for experienced players; "TEAM TIP" instead of a count):
	  TeamRules the first group run: what is shared and what is your own
	  Revive    the first time a teammate falls: stand in the gold circle

	Each card slides in with its icon spinning, a glint across the card and a ring pulse
	around the element it explains (plain with Reduced effects).
	Each hint shown is reported (Tutorial remote "Seen") so it never repeats; SKIP TIPS
	ends the tutorial ("Skip"); Settings > Show tips switches every hint off and Settings >
	Replay tips ("Replay") shows them again from the next run. The server marks the
	tutorial done when the first run ends.
]]

local Players = game:GetService("Players")
local UserInputService = game:GetService("UserInputService")
local TextService = game:GetService("TextService")

local Shared = game:GetService("ReplicatedStorage"):WaitForChild("Shared")
local Config = require(Shared:WaitForChild("Config"))
local Remotes = require(Shared:WaitForChild("Remotes"))
local Theme = require(Shared:WaitForChild("Theme"))
local UIKit = require(script.Parent.UIKit)
local UIAnim = require(script.Parent.UIAnim)
local Icons = require(script.Parent.Icons)
local Hud = require(script.Parent.Hud)
local ClientSettings = require(script.Parent.ClientSettings)

local Tutorial = {}

local player = Players.LocalPlayer
local new, TS = UIKit.new, UIKit.TS
local C, P = Theme.Color, Theme.Palette
local T = Config.Tutorial

local COOP = { TeamRules = true, Revive = true }
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

type Tip = { Id: string, Text: string, Title: string, Icon: string, Seconds: number }

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

------------------------------------------------------------------------------------------
-- The callout
------------------------------------------------------------------------------------------

local function build(root: Frame)
	rootFrame = root
	-- the gold ring around the element a tip explains (under the card)
	local focus = new("Frame", { Name = "TipFocus", BackgroundColor3 = P.gold_300, BackgroundTransparency = 0.9, Visible = false, Active = false, ZIndex = Theme.Z.Toast }, root)
	UIKit.corner(focus, Theme.Radius.M)
	ui.FocusStroke = UIKit.stroke(focus, P.gold_300, 3, 0.05)
	UIAnim.PulseStroke(ui.FocusStroke, 2, 4)
	ui.Focus = focus

	local holder, face = UIKit.Surface(root, { Name = "TipCard", Radius = Theme.Radius.L, Transparency = 0.02, Edge = P.gold_400, EdgeThickness = 2, EdgeTransparency = 0.1, Visible = false, ZIndex = Theme.Z.Toast, AnchorPoint = Vector2.new(0.5, 0), Size = UDim2.fromOffset(560, 140) })
	holder.Active = false
	ui.Card = holder
	ui.Face = face
	-- the arrow: a diamond behind the face, half of it sticking out toward the target
	local arrow = new("Frame", { Name = "Arrow", AnchorPoint = Vector2.new(0.5, 0.5), Size = UDim2.fromOffset(ARROW, ARROW), Rotation = 45, BackgroundColor3 = C.Panel, BorderSizePixel = 0, ZIndex = 0, Visible = false }, holder)
	UIKit.stroke(arrow, P.gold_400, 2, 0.1)
	ui.Arrow = arrow
	UIKit.padding(face, 14, 16, 14, 16)

	local iconWell = new("Frame", { Name = "IconWell", BackgroundColor3 = C.PanelInset, BackgroundTransparency = 0.05, Size = UDim2.fromOffset(ICON, ICON) }, face)
	UIKit.corner(iconWell, 999)
	UIKit.stroke(iconWell, P.gold_400, 2, 0.15)
	ui.IconWell = iconWell
	ui.Step = UIKit.Badge(face, "TIP 1 / 5", "Gold", { Name = "Step", AnchorPoint = Vector2.new(1, 0), Position = UDim2.fromScale(1, 0) })
	ui.Title = UIKit.Role(face, "Title", "", { Name = "Title", Position = UDim2.fromOffset(ICON + 14, 0), TextColor3 = P.gold_200, TextTruncate = Enum.TextTruncate.AtEnd })
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
	ui.Timer = new("Frame", { Name = "Timer", BackgroundColor3 = P.gold_400, BorderSizePixel = 0, Size = UDim2.fromScale(1, 1) }, track)
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
		x = right and (W - 12 - w / 2) or (12 + w / 2)
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
	Icons.Draw(ui.IconWell, name, { Size = 30, AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.5), Back = P.slate_900 })
end

local function hideCard()
	if current then
		current = nil
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
	current = { Id = tip.Id, Until = now + tip.Seconds, Seconds = tip.Seconds, Since = now }
	ui.Title.Text = tip.Title
	ui.Body.Text = tip.Text
	ui.Step.Text = stepText(tip.Id)
	setIcon(tip.Icon)
	layout()
	ui.Card.Visible = true
	-- slide in from the side of what it explains (or rise from below)
	local d = (current :: any).Dir
	UIAnim.SlideIn(ui.Card, Vector2.new(0, d < 0 and -28 or 28), 0)
	if not ClientSettings.Reduced() then
		-- the icon spins in, the TIP badge pops, a glint crosses the card, and the ring
		-- around the explained element pulses out once
		ui.IconWell.Rotation = -180
		UIAnim.Tween(ui.IconWell, 0.55, { Rotation = 0 }, Enum.EasingStyle.Back)
		UIAnim.Pop(ui.IconWell, 0.1, 0.4)
		UIAnim.Pop(ui.Step, 0.3, 0.3)
		local clip = new("Frame", { Name = "ShineClip", BackgroundTransparency = 1, Size = UDim2.fromScale(1, 1), ClipsDescendants = true, ZIndex = 20 }, ui.Card)
		UIKit.corner(clip, Theme.Radius.L)
		UIAnim.SweepOnce(clip, P.ivory_100, 0.6, 0.8)
		task.delay(0.8, function()
			clip:Destroy()
		end)
		if ui.Focus.Visible then
			UIAnim.Pop(ui.Focus, 0.15, 1.25)
			UIAnim.Ring(rootFrame :: Frame, ui.Focus.Position + UDim2.fromOffset(ui.Focus.Size.X.Offset / 2, ui.Focus.Size.Y.Offset / 2), P.gold_300, math.max(ui.Focus.Size.X.Offset, ui.Focus.Size.Y.Offset) + 40, 0.5)
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
	local last = UserInputService:GetLastInputType()
	local gamepad = string.find(tostring(last), "Gamepad") ~= nil
	if gamepad then
		return "Move with the left stick, A to jump. Chain hops for a bit of speed!"
	elseif UserInputService.TouchEnabled and not UserInputService.KeyboardEnabled then
		return "Drag anywhere to move, tap JUMP to hop over trouble."
	end
	return "Move with WASD or the arrow keys, Space to jump. Chain hops for a bit of speed!"
end

local function heroPos(): Vector3?
	local char = player.Character
	local root = char and char.PrimaryPart
	return root and root.Position or nil
end

local function startRun(_state: Configuration)
	table.clear(run)
	run.Start = os.clock()
	run.StartPos = heroPos()
	run.Kills0 = player:GetAttribute("Kills") or 0
	push("Move", "Move", moveText(), "boot")
	push("Attack", "Auto attack", "Your weapons fire on their own. Just keep moving!", "sword")
end

local function triggers(state: Configuration)
	-- a group run: the team rules first (checked for a few seconds: the player count may
	-- arrive just after InRun)
	if not run.Team and os.clock() - (run.Start or 0) < 8 and (state:GetAttribute("Participants") or 1) > 1 then
		run.Team = true
		push("TeamRules", "Team run", "Gem XP is shared by everyone standing. Gold and items are your own.", "people2", T.HintSeconds + 2, true)
	end
	-- gems after the first kill
	if not run.Gems and (player:GetAttribute("Kills") or 0) > (run.Kills0 or 0) then
		run.Gems = true
		push("Gems", "Collect gems", "Walk over gems for XP. Fill this bar to level up!", "gem")
	end
	-- the objective, a while into the run
	local runTime = state:GetAttribute("RunTime") or 0
	local stagePhase = state:GetAttribute("StagePhase") or "None"
	if not run.Portal and stagePhase == "Explore" and runTime >= T.PortalTipAt then
		run.Portal = true
		local lockLeft = state:GetAttribute("PortalLockLeft") or 0
		local body = lockLeft > 0 and string.format("Find the stone portal (it wakes in %s). Stand in its circle to call the boss.", UIKit.formatTime(lockLeft))
			or "Find the stone portal and stand in its circle to call the boss."
		push("Portal", "Find the portal", body, "portal", T.HintSeconds + 1)
	end
	if not run.Boss and stagePhase == "Boss" then
		run.Boss = true
		push("Boss", "Dodge the red", "Red shapes on the floor show where the boss strikes. Step out!", "skull")
	end
	-- the first fallen teammate
	if not run.Revive then
		for _, p in ipairs(Players:GetPlayers()) do
			if p ~= player and p:GetAttribute("InRun") == true and p:GetAttribute("Alive") == false and (tonumber(p:GetAttribute("PartnerRevivesLeft")) or 0) > 0 and p:GetAttribute("AwaitingRevive") ~= true then
				run.Revive = true
				push("Revive", "Revive " .. p.DisplayName, "Stand in the gold circle around them for a few seconds.", "revive")
				break
			end
		end
	end
	-- Move ends early once the hero has walked a few steps
	if current and current.Id == "Move" and run.StartPos then
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
	if not wants("LevelUp") then
		return nil
	end
	markSeen("LevelUp")
	return "Tap a card: a new weapon, an upgrade or a passive"
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
	local now = os.clock()
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
	kit.OnRelayout(layout)
	ClientSettings.OnChanged(function(key, value)
		if key == "Tips" and value == false then
			Tutorial.Clear()
		end
	end)
end

-- For the preview tool / tests.
function Tutorial.Elements(): { [string]: any }
	return ui
end

return Tutorial
