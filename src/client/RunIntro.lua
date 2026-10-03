--[[
	RunIntro.lua
	The stage objective card at the start of every stage (owner: "a screen when the game
	starts that says: open the portal before the swarm gets too heavy"). It takes the
	place of the HUD's plain "STAGE N" banner (Hud.StageIntro hook), so it shows exactly
	when that banner did: once per stage, after the travel fade has lifted, never when
	joining mid-fight; and only for a stage this client saw begin (a reconnect mid-stage
	keeps the plain banner).

	  eyebrow   STAGE N · arena name (ENDLESS · STAGE N on Endless runs)
	  headline  OPEN THE PORTAL / BEFORE THE SWARM GROWS TOO STRONG
	  hints     stage 1 (and a player's first run): three icon hints with live numbers:
	            find the portal (or when it wakes, SwarmState PortalLockLeft), stand in its
	            ring (Config.Stages.ChargeSeconds), beat the stage boss (StageBoss).
	            Stages 2+: the headline only, shorter.
	  footer    TAP TO CLOSE + a draining gold bar

	Never blocks or pauses anything: nothing in it is Active (a thumb landing on it still
	moves the hero); a tap / click inside the card closes it early (read from
	UserInputService, the touch still reaches the thumbstick). It leaves early when the
	portal reveal banner comes (SwarmState PortalReveal) or the run ends. Co-op: purely
	local. Motion: slams in (scale + ring + sparks), hints cascade in; reduced effects: a
	plain fade. While it shows, the first-run tips wait (RunIntro.Active, UIBuilder).
	The first-run version (profile TutorialDone = false) stays longer and adds a line on
	why the clock matters.
]]

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

local RunIntro = {}

local new, TS = UIKit.new, UIKit.TS
local C, P = Theme.Color, Theme.Palette

-- seconds on screen (UI timing, not game balance)
local SECONDS_FIRST_STAGE = 3.6
local SECONDS_FIRST_RUN = 5
local SECONDS_LATER = 2.4

local HEAD = 30 -- headline (Display font), reference px
local SUB = 16 -- "BEFORE THE SWARM..." (Label font)
local HINT_ICON = 30
local PAD = 16

local kit: { [string]: any } = {}
local ui: { [string]: any } = {}
local firstRun = false -- profile TutorialDone == false
local show = { Token = 0, Until = 0, Since = 0, Seconds = 1, Reveal = 0, Full = false, Long = false }
local tweens: { Tween } = {}
-- the stage this client saw begin (SwarmState Stage changed while it watched) and when:
-- a client that joins mid-stage (reconnect) gets the plain banner instead
local begun = { Stage = 0, At = -math.huge }
local BEGUN_WINDOW = 25 -- seconds from the Stage change to the banner moment (travel fade, countdown)

local function reduced(): boolean
	return UIAnim.Reduced()
end

local function tw(obj: Instance, seconds: number, goal: { [string]: any }, style: Enum.EasingStyle?, dir: Enum.EasingDirection?): Tween
	local t = UIAnim.Tween(obj, seconds, goal, style, dir)
	table.insert(tweens, t)
	return t
end

local function stopTweens()
	for _, t in ipairs(tweens) do
		t:Cancel()
	end
	table.clear(tweens)
end

-- Wrapped line count of `str` at `size` px in `width`.
local function lines(str: string, size: number, font: Enum.Font, width: number): number
	local ok, s = pcall(function()
		return TextService:GetTextSize(str, size, font, Vector2.new(width, 1000))
	end)
	if ok and typeof(s) == "Vector2" then
		return math.clamp(math.ceil(s.Y / size - 0.2), 1, 3)
	end
	return 2
end

------------------------------------------------------------------------------------------
-- Build
------------------------------------------------------------------------------------------

local function hintCell(parent: Instance, name: string, icon: string): { [string]: any }
	local cell = new("Frame", { Name = name, BackgroundColor3 = C.PanelInset, BackgroundTransparency = 0.1, BorderSizePixel = 0, Active = false }, parent)
	UIKit.corner(cell, Theme.Radius.M)
	UIKit.stroke(cell, P.gold_500, 1, 0.55)
	local well = new("Frame", { Name = "Icon", BackgroundColor3 = P.slate_800, BorderSizePixel = 0, AnchorPoint = Vector2.new(0, 0.5), Size = UDim2.fromOffset(HINT_ICON + 10, HINT_ICON + 10) }, cell)
	UIKit.corner(well, 999)
	UIKit.stroke(well, P.gold_400, 1.5, 0.2)
	Icons.Draw(well, icon, { Size = HINT_ICON, AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.5) })
	local title = UIKit.Role(cell, "Label", "", { Name = "Title", TextColor3 = P.ivory_100, TextWrapped = true }, false)
	local sub = UIKit.Role(cell, "Caption", "", { Name = "Sub", TextColor3 = P.gold_200, TextWrapped = true }, false)
	return { Frame = cell, Well = well, Title = title, Sub = sub }
end

local function build(root: Frame)
	local holder = new("CanvasGroup", {
		Name = "RunIntro",
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		AnchorPoint = Vector2.new(0.5, 0.5),
		Size = UDim2.fromOffset(560, 200),
		Visible = false,
		Active = false,
		ZIndex = Theme.Z.Toast - 1,
		GroupTransparency = 0,
	}, root)
	ui.Card = holder
	-- the panel: opaque slate, gold edge (strong contrast over the arena)
	local face = new("Frame", { Name = "Face", BackgroundColor3 = Color3.new(1, 1, 1), BackgroundTransparency = 0.02, BorderSizePixel = 0, Size = UDim2.fromScale(1, 1), Active = false }, holder)
	UIKit.corner(face, Theme.Radius.L)
	new("UIGradient", { Rotation = 90, Color = ColorSequence.new(P.slate_800, P.slate_950) }, face)
	UIKit.stroke(face, P.gold_400, 2, 0.1)
	ui.Face = face
	-- a gold band across the top
	local band = new("Frame", { Name = "Band", BackgroundColor3 = P.gold_400, BorderSizePixel = 0, Size = UDim2.new(1, 0, 0, 4) }, face)
	UIKit.corner(band, 2)

	ui.Eyebrow = UIKit.Role(face, "Label", "STAGE 1", { Name = "Eyebrow", TextXAlignment = Enum.TextXAlignment.Center, TextColor3 = P.gold_300, TextTruncate = Enum.TextTruncate.AtEnd }, false)
	ui.Head = UIKit.Role(face, "Display", "OPEN THE PORTAL", { Name = "Head", TextXAlignment = Enum.TextXAlignment.Center, TextColor3 = P.gold_200, TextWrapped = true }, false)
	ui.Head.TextSize = TS(HEAD)
	ui.Sub = UIKit.Role(face, "Label", "BEFORE THE SWARM GROWS TOO STRONG", { Name = "Sub", TextXAlignment = Enum.TextXAlignment.Center, TextColor3 = P.ivory_100, TextWrapped = true }, false)
	ui.Sub.TextSize = TS(SUB)
	ui.Why = UIKit.Role(face, "Body", "", { Name = "Why", TextXAlignment = Enum.TextXAlignment.Center, TextColor3 = C.TextMuted, TextWrapped = true }, false)
	ui.Rule = new("Frame", { Name = "Rule", BackgroundColor3 = P.gold_500, BackgroundTransparency = 0.4, BorderSizePixel = 0, AnchorPoint = Vector2.new(0.5, 0), Size = UDim2.fromOffset(160, 2) }, face)
	ui.Hints = {
		hintCell(face, "HintPortal", "portal"),
		hintCell(face, "HintCharge", "hourglass"),
		hintCell(face, "HintBoss", "skull"),
	}
	ui.Close = UIKit.Role(face, "Caption", "TAP TO CLOSE", { Name = "Close", TextXAlignment = Enum.TextXAlignment.Center, TextColor3 = C.TextMuted }, false)
	local track = new("Frame", { Name = "TimerTrack", BackgroundColor3 = C.PanelInset, BorderSizePixel = 0, AnchorPoint = Vector2.new(0.5, 1) }, face)
	UIKit.corner(track, 999)
	ui.TimerTrack = track
	ui.Timer = new("Frame", { Name = "Timer", BackgroundColor3 = P.gold_400, BorderSizePixel = 0, Size = UDim2.fromScale(1, 1) }, track)
	UIKit.corner(ui.Timer, 999)
end

------------------------------------------------------------------------------------------
-- Layout
------------------------------------------------------------------------------------------

local function layout()
	if not ui.Card then
		return
	end
	local v: Vector2 = kit.VirtualSize()
	local W, H = v.X, v.Y
	local portrait: boolean = kit.IsPortrait()
	local w = portrait and math.min(W - 24, 420) or math.min(600, W - 48)
	local inner = w - 2 * PAD
	local y = PAD
	local eyebrowH = TS(Theme.Type.Label.Size) + 4
	ui.Eyebrow.Position = UDim2.fromOffset(PAD, y)
	ui.Eyebrow.Size = UDim2.fromOffset(inner, eyebrowH)
	y += eyebrowH + 2
	local headPx = TS(portrait and HEAD - 4 or HEAD)
	ui.Head.TextSize = headPx
	local headLines = lines(ui.Head.Text, headPx, Enum.Font.Merriweather, inner)
	ui.Head.Position = UDim2.fromOffset(PAD, y)
	ui.Head.Size = UDim2.fromOffset(inner, headLines * (headPx + 4))
	y += headLines * (headPx + 4) + 2
	local subPx = TS(SUB)
	ui.Sub.TextSize = subPx
	local subLines = lines(ui.Sub.Text, subPx, Enum.Font.SourceSansBold, inner - 8)
	ui.Sub.Position = UDim2.fromOffset(PAD, y)
	ui.Sub.Size = UDim2.fromOffset(inner, subLines * (subPx + 3))
	y += subLines * (subPx + 3) + 6
	ui.Why.Visible = show.Long
	if show.Long then
		local px = TS(Theme.Type.Body.Size)
		local n = lines(ui.Why.Text, px, Enum.Font.SourceSansSemibold, inner - 8)
		ui.Why.Position = UDim2.fromOffset(PAD, y)
		ui.Why.Size = UDim2.fromOffset(inner, n * (px + 3))
		y += n * (px + 3) + 6
	end
	ui.Rule.Visible = show.Full
	for _, h in ipairs(ui.Hints) do
		h.Frame.Visible = show.Full
	end
	if show.Full then
		ui.Rule.Position = UDim2.fromOffset(w / 2, y)
		y += 10
		local cols = (inner >= 480) and 3 or 1
		local gap = 8
		local titlePx = TS(Theme.Type.Label.Size)
		local subPx2 = TS(Theme.Type.Caption.Size)
		local iconBox = HINT_ICON + 10
		if cols == 3 then
			local cw = (inner - 2 * gap) / 3
			local tx = iconBox + 16
			local ch = math.max(iconBox + 12, 10 + (titlePx + 4) + (subPx2 + 4) + 10)
			for i, h in ipairs(ui.Hints) do
				local tl = lines(h.Title.Text, titlePx, Enum.Font.SourceSansBold, cw - tx - 8)
				ch = math.max(ch, 10 + tl * (titlePx + 2) + (subPx2 + 4) + 10)
				h.Frame.Position = UDim2.fromOffset(PAD + (i - 1) * (cw + gap), y)
				h.Frame.Size = UDim2.fromOffset(cw, ch)
			end
			for _, h in ipairs(ui.Hints) do
				local tl = lines(h.Title.Text, titlePx, Enum.Font.SourceSansBold, cw - tx - 8)
				local th = tl * (titlePx + 2)
				local top = (ch - th - (subPx2 + 4)) / 2
				h.Well.Position = UDim2.fromOffset(8, ch / 2)
				h.Title.Position = UDim2.fromOffset(tx, top)
				h.Title.Size = UDim2.new(1, -tx - 8, 0, th)
				h.Sub.Position = UDim2.fromOffset(tx, top + th)
				h.Sub.Size = UDim2.new(1, -tx - 8, 0, subPx2 + 4)
			end
			y += ch + 8
		else
			local rh = iconBox + 8
			for _, h in ipairs(ui.Hints) do
				h.Frame.Position = UDim2.fromOffset(PAD, y)
				h.Frame.Size = UDim2.fromOffset(inner, rh)
				h.Well.Position = UDim2.fromOffset(6, rh / 2)
				local tx = iconBox + 14
				-- title left, value right-aligned on the same row
				h.Title.Position = UDim2.fromOffset(tx, 0)
				h.Title.Size = UDim2.new(0.58, -tx, 1, 0)
				h.Sub.TextXAlignment = Enum.TextXAlignment.Right
				h.Sub.Position = UDim2.new(0.58, 0, 0, 0)
				h.Sub.Size = UDim2.new(0.42, -10, 1, 0)
				y += rh + 6
			end
			y += 2
		end
	end
	local closeH = TS(Theme.Type.Caption.Size) + 4
	ui.Close.Position = UDim2.fromOffset(PAD, y)
	ui.Close.Size = UDim2.fromOffset(inner, closeH)
	y += closeH + 6
	ui.TimerTrack.Position = UDim2.new(0.5, 0, 0, y + 4)
	ui.TimerTrack.Size = UDim2.fromOffset(math.min(220, inner), 4)
	y += 4 + PAD - 4
	local h = y
	ui.Card.Size = UDim2.fromOffset(math.floor(w), math.floor(h))
	-- between the top HUD and the bottom bar (landscape); portrait: under the HUD block,
	-- over the arena (the hero stays visible around it; nothing here takes input)
	local cy
	if portrait then
		cy = math.clamp(H * 0.58, h / 2 + 12, H - h / 2 - 120)
	else
		local top = Hud.TopBottom() + 12
		local bottom = Hud.BarTop() - 12
		cy = (bottom - top >= h) and (top + bottom) / 2 or math.max(top + h / 2, H / 2)
		cy = math.clamp(cy, h / 2 + 8, H - h / 2 - 8)
	end
	ui.Card.Position = UDim2.fromOffset(math.floor(W / 2), math.floor(cy))
end

------------------------------------------------------------------------------------------
-- Show / hide
------------------------------------------------------------------------------------------

local function hide(fast: boolean?)
	if not ui.Card or not ui.Card.Visible then
		return
	end
	show.Token += 1
	local token = show.Token
	stopTweens()
	show.Until = 0
	if fast or reduced() then
		ui.Card.Visible = false
		return
	end
	tw(ui.Card, 0.22, { GroupTransparency = 1 })
	local sc = UIAnim.ScaleOf(ui.Card)
	tw(sc, 0.22, { Scale = 0.94 }, Enum.EasingStyle.Quad, Enum.EasingDirection.In)
	task.delay(0.24, function()
		if token == show.Token then
			ui.Card.Visible = false
			sc.Scale = 1
		end
	end)
end

local function fill(state: Configuration, stageNo: number)
	local endless = state:GetAttribute("Endless") == true
	local arena = tostring(state:GetAttribute("StageArena") or "")
	local head = (endless and "ENDLESS · STAGE " or "STAGE ") .. tostring(stageNo)
	if arena ~= "" then
		head ..= "  ·  " .. string.upper(arena)
	end
	ui.Eyebrow.Text = UIKit.track(head)
	ui.Head.Text = "OPEN THE PORTAL"
	ui.Sub.Text = "BEFORE THE SWARM GROWS TOO STRONG"
	ui.Why.Text = "The swarm gets bigger and tougher every minute. Find the portal fast."
	-- live hint values
	local lockLeft = tonumber(state:GetAttribute("PortalLockLeft")) or 0
	local charge = Config.Stages.ChargeSeconds
	local boss = tostring(state:GetAttribute("StageBoss") or "")
	local hp, hc, hb = ui.Hints[1], ui.Hints[2], ui.Hints[3]
	hp.Title.Text = "FIND THE PORTAL"
	hp.Sub.Text = lockLeft > 0 and ("Wakes in " .. UIKit.formatTime(lockLeft)) or "Follow the gold arrow"
	hc.Title.Text = "STAND IN ITS RING"
	hc.Sub.Text = string.format("%s s to charge", tostring(charge))
	hb.Title.Text = "BEAT THE BOSS"
	hb.Sub.Text = boss ~= "" and boss or "Then the portal opens"
	ui.Close.Text = UIKit.track(UserInputService.TouchEnabled and not UserInputService.KeyboardEnabled and "TAP TO CLOSE" or "CLICK TO CLOSE")
end

-- Hud's stage-banner hook: shows the card for stage `stageNo`; true = the banner is ours.
function RunIntro.Show(stageNo: number): boolean
	if not ui.Card then
		return false
	end
	local state = Remotes.State()
	local saw = begun.Stage == stageNo and os.clock() - begun.At <= BEGUN_WINDOW
	-- a private run server: the client may arrive after Stage was set; a fresh run counts
	local fresh = stageNo == 1 and (tonumber(state:GetAttribute("RunTime")) or 0) < 15
	if not saw and not fresh then
		return false
	end
	begun.Stage = 0 -- once per stage
	show.Full = stageNo <= 1 or firstRun
	show.Long = firstRun
	show.Seconds = firstRun and SECONDS_FIRST_RUN or (stageNo <= 1 and SECONDS_FIRST_STAGE or SECONDS_LATER)
	show.Reveal = tonumber(state:GetAttribute("PortalReveal")) or 0
	fill(state, stageNo)
	stopTweens()
	show.Token += 1
	show.Since = os.clock()
	show.Until = show.Since + show.Seconds
	layout()
	local card = ui.Card :: CanvasGroup
	card.Visible = true
	ui.Timer.Size = UDim2.fromScale(1, 1)
	local sc = UIAnim.ScaleOf(card)
	if reduced() then
		sc.Scale = 1
		card.GroupTransparency = 1
		tw(card, 0.2, { GroupTransparency = 0 })
		return true
	end
	-- slam: big and clear, then settle with an overshoot; ring + sparks off the headline
	card.GroupTransparency = 0.6
	sc.Scale = 1.35
	tw(card, 0.18, { GroupTransparency = 0 })
	tw(sc, 0.38, { Scale = 1 }, Enum.EasingStyle.Back)
	local at = UDim2.new(0.5, 0, 0, ui.Head.Position.Y.Offset + ui.Head.Size.Y.Offset / 2)
	UIAnim.Ring(ui.Face, at, P.gold_300, 260, 0.5)
	UIAnim.Sparks(ui.Face, at, P.gold_200, 10, 140, 0.6)
	UIAnim.Sweep(ui.Face, 0.15)
	if show.Full then
		local objs = {}
		for _, h in ipairs(ui.Hints) do
			table.insert(objs, h.Frame)
		end
		UIAnim.Cascade(objs, 0.08, 0.7)
	end
	return true
end

-- True while the card is up (the first-run tips wait for it).
function RunIntro.Active(): boolean
	return ui.Card ~= nil and ui.Card.Visible and show.Until > 0
end

-- Per frame (UIBuilder).
function RunIntro.Update(_dt: number, state: Configuration, inRun: boolean)
	if not ui.Card or not ui.Card.Visible or show.Until <= 0 then
		return
	end
	local now = os.clock()
	if not inRun then
		hide(true)
		return
	end
	-- the portal reveal banner takes over (after the card has had a moment)
	local reveal = tonumber(state:GetAttribute("PortalReveal")) or 0
	if reveal ~= show.Reveal and now - show.Since > 1.2 then
		hide()
		return
	end
	local left = show.Until - now
	ui.Timer.Size = UDim2.fromScale(math.clamp(left / show.Seconds, 0, 1), 1)
	if left <= 0 then
		hide()
	end
end

function RunIntro.Build(root: Frame, k: { [string]: any })
	kit = k
	build(root)
	kit.OnRelayout(function()
		if ui.Card.Visible then
			layout()
		end
	end)
	-- tap / click inside the card closes it (the card is not Active, so the same touch
	-- still moves the hero)
	UserInputService.InputBegan:Connect(function(input)
		local t = input.UserInputType
		if not RunIntro.Active() or os.clock() - show.Since < 0.35 then
			return
		end
		if t ~= Enum.UserInputType.Touch and t ~= Enum.UserInputType.MouseButton1 then
			return
		end
		local card = ui.Card :: GuiObject
		local p, s = card.AbsolutePosition, card.AbsoluteSize
		local x, y = input.Position.X, input.Position.Y
		-- AbsolutePosition excludes the top bar inset; input positions may include it
		local inset = 0
		pcall(function()
			inset = game:GetService("GuiService"):GetGuiInset().Y
		end)
		local inside = x >= p.X and x <= p.X + s.X and ((y >= p.Y and y <= p.Y + s.Y) or (y - inset >= p.Y and y - inset <= p.Y + s.Y))
		if inside then
			hide()
		end
	end)
	-- first run (profile): the longer version
	Remotes.Get("ProfileSync").OnClientEvent:Connect(function(data)
		if type(data) == "table" and data.TutorialDone ~= nil then
			firstRun = data.TutorialDone == false
		end
	end)
	local state = Remotes.State()
	state:GetAttributeChangedSignal("Stage"):Connect(function()
		local n = tonumber(state:GetAttribute("Stage")) or 0
		if n > 0 then
			begun.Stage, begun.At = n, os.clock()
		end
	end)
	Hud.StageIntro = RunIntro.Show
end

-- For the preview tool / tests.
function RunIntro.Elements(): { [string]: any }
	return ui
end

return RunIntro
