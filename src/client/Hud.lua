--[[
	Hud.lua
	The in-run HUD (built and driven by UIBuilder):
	  top centre    big run timer (total run time over every stage), under it the stage
	                pill ("STAGE 2 · Find the portal" → "Defeat the Queen" → "Survive the
	                surge" → "Portal open"), a plate with health (heart + crimson bar) and
	                level / XP (gold bar), then the boss bar while the boss lives
	  top right     kills counter, pause button; a steel band on the health bar is the
	                Guardian Ward shield
	  purse         the run gold (earned this run, minus what chests and shrines took),
	                big and bold just above the ability bar (portrait: just under it):
	                coin + number that counts up and punches, a "+N" that floats off it,
	                and next to a chest / shrine its price (red "NEED N" after trying
	                to open one without enough gold, set by LootUI through SetPurseHint)
	  centre        status line (paused, "<Name> is choosing an upgrade", fallen, partner
	                revive progress)
	The portal arrow, the charge ring, the portal choice panel and the travel fade live in
	StageUI.lua.
	  bottom centre ability bar: weapons row + passives row with level badges (portrait:
	                under the health plate, away from the thumbs)
	  screen edges  crimson vignette pulse when hurt, slow pulse at low health
	Motion (all event-driven, short, skipped or reduced with ClientSettings.Reduced()):
	  XP bar        shine sweep per gem burst; level up = white flash, sweep, ring + sparks
	  health        white damage chip that holds a beat before it drains, heal shimmer, a
	                heart beat at low health
	  counters      kills punch + sweep on every 50th, timer flashes gold each minute
	  purse         bounce + coin sparkle on gains
	  ability bar   a new weapon / passive pops with a shine sweep and sparks, a level up
	                with a flash
	  stage         "STAGE 2" banner slams in under the timer for ~1.5 s (after the travel
	                fade), the pill flashes when the objective changes (red for the surge)
	  boss bar      drops in with a shake, the name fades in under a sweep, shakes again at
	                the phase marker

	Nothing in the ability bar or the plates is Active, so a thumb landing on them still
	drives the floating thumbstick.
]]

local Players = game:GetService("Players")
local TweenService = game:GetService("TweenService")

local Shared = game:GetService("ReplicatedStorage"):WaitForChild("Shared")
local Config = require(Shared:WaitForChild("Config"))
local Theme = require(Shared:WaitForChild("Theme"))
local WeaponData = require(Shared:WaitForChild("WeaponData"))
local PassiveData = require(Shared:WaitForChild("PassiveData"))
local CharacterData = require(Shared:WaitForChild("CharacterData"))
local UIKit = require(script.Parent.UIKit)
local UIAnim = require(script.Parent.UIAnim)
local Icons = require(script.Parent.Icons)
local ClientSettings = require(script.Parent.ClientSettings)

local Hud = {}

local player = Players.LocalPlayer
local new, text, TS = UIKit.new, UIKit.text, UIKit.TS
local C, P = Theme.Color, Theme.Palette

export type Insets = { Top: number, Left: number, Right: number }

local host: { [string]: any } = {}
local ui: { [string]: any } = {}
local anim: { [string]: any } = { XP = 0, HP = 1, HPTrail = 1 }
local inventory: { [string]: any }? = nil
local shownLevels: { [string]: number } = {}

local updatePurse: (number) -> ()

-- A soft colour flash over a Surface holder's face (a sibling of the face, so it never
-- joins the face's list layout); fades out and destroys itself.
local function glow(holder: GuiObject, color: Color3)
	if ClientSettings.Reduced() then
		return
	end
	local face = holder:FindFirstChild("Face")
	local f = new("Frame", { Name = "Glow", BackgroundColor3 = color, BackgroundTransparency = 0.45, BorderSizePixel = 0, Size = UDim2.fromScale(1, 1), ZIndex = 3 }, holder)
	local corner = face and face:FindFirstChildWhichIsA("UICorner")
	if corner then
		corner:Clone().Parent = f
	end
	local t = UIAnim.Tween(f, 0.5, { BackgroundTransparency = 1 })
	t.Completed:Once(function()
		f:Destroy()
	end)
end

local function place(obj: GuiObject, x: number, y: number, w: number, h: number)
	obj.Position = UDim2.fromOffset(math.floor(x + 0.5), math.floor(y + 0.5))
	obj.Size = UDim2.fromOffset(math.floor(w + 0.5), math.floor(h + 0.5))
end

------------------------------------------------------------------------------------------
-- Build
------------------------------------------------------------------------------------------

local function buildTop(frame: Frame)
	-- timer
	ui.Timer = text(frame, "Number", "00:00", {
		Name = "Timer",
		TextXAlignment = Enum.TextXAlignment.Center,
		TextStrokeColor3 = C.Shadow,
		TextStrokeTransparency = 0.55,
		TextColor3 = C.Text,
	}, Theme.TextSize.Display + 4)

	-- health + level plate
	local plateHolder, plate = UIKit.Surface(frame, { Name = "Plate", Transparency = Theme.Alpha.PanelSoft, Radius = Theme.Radius.M, Shadow = true })
	ui.Plate = plateHolder
	UIKit.padding(plate, 8, 12, 8, 12)
	local rows = new("Frame", { BackgroundTransparency = 1, Size = UDim2.fromScale(1, 1) }, plate)
	UIKit.list(rows, { Padding = UDim.new(0, 6), VerticalAlignment = Enum.VerticalAlignment.Center })

	local hpRow = new("Frame", { Name = "HP", BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0.5, -3), LayoutOrder = 1 }, rows)
	ui.Heart = Icons.Draw(hpRow, "heart", { Size = 22, AnchorPoint = Vector2.new(0, 0.5), Position = UDim2.fromScale(0, 0.5) })
	ui.HP = UIKit.Meter(hpRow, {
		Gradient = Theme.Gradient.Health,
		Trail = true,
		TextStyle = "Number",
		TextSize = Theme.TextSize.Body,
		AnchorPoint = Vector2.new(0, 0.5),
		Position = UDim2.new(0, 32, 0.5, 0),
		Size = UDim2.new(1, -32, 1, -2),
	})

	-- Guardian Ward shield: a steel band along the top of the health bar
	ui.ShieldBar = new("Frame", { Name = "Shield", BackgroundColor3 = P.steel_200, BorderSizePixel = 0, Size = UDim2.new(0, 0, 0, 4), Visible = false, ZIndex = 6 }, ui.HP.Frame)
	UIKit.corner(ui.ShieldBar, 2)

	local xpRow = new("Frame", { Name = "XP", BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0.5, -3), LayoutOrder = 2 }, rows)
	ui.Level = text(xpRow, "Label", "Lv. 1", {
		Name = "Level",
		TextColor3 = P.gold_300,
		Size = UDim2.new(0, 56, 1, 0),
		TextXAlignment = Enum.TextXAlignment.Left,
	}, Theme.TextSize.Body)
	ui.XPRow = xpRow
	ui.XP = UIKit.Meter(xpRow, {
		Gradient = Theme.Gradient.XP,
		TextStyle = "Number",
		TextSize = Theme.TextSize.Caption,
		AnchorPoint = Vector2.new(0, 0.5),
		Position = UDim2.new(0, 60, 0.5, 0),
		Size = UDim2.new(1, -60, 1, -6),
	})

	-- bright leading edge on the XP fill (reads as the bar's "spark")
	local edge = new("Frame", { Name = "Edge", BackgroundColor3 = P.ivory_100, BackgroundTransparency = 0.55, BorderSizePixel = 0, AnchorPoint = Vector2.new(1, 0.5), Position = UDim2.fromScale(1, 0.5), Size = UDim2.new(0, 6, 1, 0), ZIndex = 3 }, ui.XP.Fill)
	UIKit.corner(edge, 999)

	-- boss bar
	local boss = new("Frame", { Name = "BossBar", BackgroundTransparency = 1, Visible = false }, frame)
	ui.Boss = boss
	local bossTitle = new("Frame", { BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 24) }, boss)
	UIKit.list(bossTitle, {
		FillDirection = Enum.FillDirection.Horizontal,
		HorizontalAlignment = Enum.HorizontalAlignment.Center,
		VerticalAlignment = Enum.VerticalAlignment.Center,
		Padding = UDim.new(0, 8),
	})
	Icons.Draw(bossTitle, "skull", { Size = 20, Color = P.crimson_300, Back = P.slate_950, LayoutOrder = 1 })
	ui.BossName = text(bossTitle, "H3", "SCORPION QUEEN", {
		LayoutOrder = 2,
		Size = UDim2.fromOffset(0, 24),
		AutomaticSize = Enum.AutomaticSize.X,
		TextColor3 = P.crimson_300,
		TextStrokeColor3 = C.Shadow,
		TextStrokeTransparency = 0.5,
	})
	ui.BossMeter = UIKit.Meter(boss, {
		Gradient = Theme.Gradient.Boss,
		Trail = true,
		Position = UDim2.fromOffset(0, 28),
		Size = UDim2.new(1, 0, 0, 16),
	})
	UIKit.stroke(ui.BossMeter.Frame, P.crimson_400, 1.5, 0.2)
	-- phase marker (BossPhaseAt, e.g. 50%): a dark notch with an ivory core on the bar
	ui.BossMark = new("Frame", { Name = "PhaseMark", BackgroundColor3 = P.slate_950, BorderSizePixel = 0, AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.new(0.5, 0, 0, 36), Size = UDim2.fromOffset(5, 22), ZIndex = 4, Visible = false }, boss)
	new("Frame", { BackgroundColor3 = P.ivory_200, BorderSizePixel = 0, AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.5), Size = UDim2.new(0, 1, 1, -4), ZIndex = 5 }, ui.BossMark)

	-- kills / gold counters + pause
	local counters = UIKit.Panel(frame, { Name = "Counters", AutomaticSize = Enum.AutomaticSize.X, Size = UDim2.fromOffset(0, 44) }, true)
	UIKit.padding(counters, 0, 14, 0, 12)
	UIKit.list(counters, { FillDirection = Enum.FillDirection.Horizontal, VerticalAlignment = Enum.VerticalAlignment.Center, Padding = UDim.new(0, 14) })
	ui.Counters = counters
	ui.Kills = UIKit.Chip(counters, "skull", nil, "0", { LayoutOrder = 1, Size = UDim2.fromOffset(0, 44) }, { Size = 20, Color = P.ivory_200, Back = P.slate_950 })
	ui.Pause = UIKit.IconButton(frame, {
		Icon = "pause",
		Size = 52,
		Name = "Pause",
		OnClick = function()
			if host.OnPause then
				host.OnPause()
			end
		end,
	})
end

-- The purse: the run gold, big, in the middle just over the ability bar.
local function buildPurse(frame: Frame)
	local holder, face = UIKit.Surface(frame, { Name = "Purse", Transparency = 0.18, Radius = 999, Edge = P.gold_500, EdgeTransparency = 0.35, Size = UDim2.fromOffset(0, 50) })
	holder.AnchorPoint = Vector2.new(0.5, 0)
	holder.AutomaticSize = Enum.AutomaticSize.X
	face.AutomaticSize = Enum.AutomaticSize.X
	face.Size = UDim2.fromScale(0, 1)
	UIKit.padding(face, 0, 20, 0, 12)
	UIKit.list(face, { FillDirection = Enum.FillDirection.Horizontal, VerticalAlignment = Enum.VerticalAlignment.Center, Padding = UDim.new(0, 8) })
	ui.Purse = holder
	ui.PurseFace = face
	ui.PurseStroke = face:FindFirstChildOfClass("UIStroke")
	ui.PurseCoin = Icons.Draw(face, "coin", { Size = 32, LayoutOrder = 1 })
	ui.PurseValue = text(face, "Number", "0", {
		Name = "Value",
		LayoutOrder = 2,
		Size = UDim2.fromOffset(0, 50),
		AutomaticSize = Enum.AutomaticSize.X,
		TextColor3 = P.gold_200,
		TextStrokeColor3 = C.Shadow,
		TextStrokeTransparency = 0.45,
	}, 34)
	ui.PurseHint = text(face, "Label", "", {
		Name = "Hint",
		LayoutOrder = 3,
		Size = UDim2.fromOffset(0, 50),
		AutomaticSize = Enum.AutomaticSize.X,
		TextColor3 = C.TextMuted,
		Visible = false,
	}, Theme.TextSize.Caption + 2)
	-- "+N" floaters rise from the purse
	ui.PurseFloat = new("Frame", { Name = "PurseFloat", BackgroundTransparency = 1, Size = UDim2.fromOffset(1, 1), ZIndex = 5 }, frame)
end

-- Buff chip (Ranger's Steady Aim): a small pill over the ability bar. Shown only for a
-- hero with the trait (player attribute SteadyAim exists): dim "Stand still to aim" while
-- moving, lit "Steady Aim +30%" once the bonus is on.
local function buildBuffChip(frame: Frame)
	local holder, face = UIKit.Surface(frame, { Name = "BuffChip", Transparency = 0.15, Radius = 999, Shadow = false, Size = UDim2.fromOffset(0, 28) })
	holder.AutomaticSize = Enum.AutomaticSize.X
	face.AutomaticSize = Enum.AutomaticSize.X
	face.Size = UDim2.fromScale(0, 1)
	holder.Visible = false
	UIKit.padding(face, 0, 12, 0, 8)
	UIKit.list(face, { FillDirection = Enum.FillDirection.Horizontal, VerticalAlignment = Enum.VerticalAlignment.Center, Padding = UDim.new(0, 6) })
	ui.Buff = holder
	ui.BuffIcon = new("Frame", { BackgroundTransparency = 1, Size = UDim2.fromOffset(18, 18), LayoutOrder = 1 }, face)
	ui.BuffText = text(face, "Label", "", { LayoutOrder = 2, Size = UDim2.fromOffset(0, 28), AutomaticSize = Enum.AutomaticSize.X })
	ui.BuffStroke = UIKit.stroke(face, P.moss_300, 1.5, 0.2)
end

local function refreshBuff()
	local state = player:GetAttribute("SteadyAim")
	if not ui.Buff then
		return
	end
	ui.Buff.Visible = state ~= nil and player:GetAttribute("InRun") == true
	if state == nil or ui.BuffOn == state then
		return
	end
	ui.BuffOn = state
	for _, c in ipairs(ui.BuffIcon:GetChildren()) do
		c:Destroy()
	end
	Icons.Draw(ui.BuffIcon, "aim", { Size = 18, Color = (not state) and P.stone_400 or nil, Back = P.slate_900 })
	-- the hero's own numbers (CharacterData SteadyAim: Damage for the bow, OtherDamage for
	-- every other weapon)
	local heroDef = CharacterData.Characters[tostring(player:GetAttribute("CharacterId") or "")]
	local trait = (heroDef and heroDef.SteadyAim) or (CharacterData.Characters.Ranger and CharacterData.Characters.Ranger.SteadyAim)
	local bow = trait and math.floor((trait.Damage or 0) * 100 + 0.5) or 30
	local other = trait and math.floor((trait.OtherDamage or 0) * 100 + 0.5) or 0
	local onText = other > 0 and string.format("STEADY AIM +%d%% BOW · +%d%% OTHERS", bow, other) or string.format("STEADY AIM +%d%% DAMAGE", bow)
	ui.BuffText.Text = state and onText or "STAND STILL TO AIM"
	ui.BuffText.TextColor3 = state and P.moss_200 or C.TextMuted
	ui.BuffStroke.Transparency = state and 0.1 or 0.75
	if state then
		UIAnim.Pop(ui.Buff, 0, 1.2)
	end
end

-- Stage pill under the timer: portal icon, "STAGE 2", objective.
local function buildStage(frame: Frame)
	local holder, face = UIKit.Surface(frame, { Name = "Stage", Transparency = 0.2, Radius = 999, Shadow = false, Size = UDim2.fromOffset(0, 30) })
	holder.AnchorPoint = Vector2.new(0.5, 0)
	holder.AutomaticSize = Enum.AutomaticSize.X
	face.AutomaticSize = Enum.AutomaticSize.X
	face.Size = UDim2.fromScale(0, 1)
	UIKit.padding(face, 0, 14, 0, 10)
	UIKit.list(face, { FillDirection = Enum.FillDirection.Horizontal, VerticalAlignment = Enum.VerticalAlignment.Center, Padding = UDim.new(0, 7) })
	ui.Stage = holder
	ui.StageIcon = Icons.Draw(face, "portal", { Size = 18, LayoutOrder = 1, Back = P.slate_900 })
	ui.StageNumber = text(face, "Label", "STAGE 1", {
		LayoutOrder = 2,
		Size = UDim2.fromOffset(0, 30),
		AutomaticSize = Enum.AutomaticSize.X,
		TextColor3 = P.gold_300,
	})
	ui.StageDot = new("Frame", { BackgroundColor3 = P.gold_500, Size = UDim2.fromOffset(4, 4), LayoutOrder = 3, BorderSizePixel = 0 }, face)
	UIKit.corner(ui.StageDot, 999)
	ui.StageGoal = text(face, "BodyStrong", "Find the portal", {
		LayoutOrder = 4,
		Size = UDim2.fromOffset(0, 30),
		AutomaticSize = Enum.AutomaticSize.X,
	})
end

-- Stage banner: "STAGE 2" slams in over the arena for a moment (showStageBanner).
local function buildBanner(frame: Frame)
	local box = new("Frame", { Name = "StageBanner", BackgroundTransparency = 1, AnchorPoint = Vector2.new(0.5, 0.5), Size = UDim2.fromOffset(520, 110), Visible = false, Active = false, ZIndex = 8 }, frame)
	ui.Banner = box
	ui.BannerTitle = text(box, "Display", "STAGE 1", {
		Name = "Title",
		AnchorPoint = Vector2.new(0.5, 0),
		Position = UDim2.fromScale(0.5, 0),
		Size = UDim2.new(1, 0, 0, TS(52) + 6),
		TextXAlignment = Enum.TextXAlignment.Center,
		TextColor3 = P.gold_200,
		TextStrokeColor3 = C.Shadow,
		TextStrokeTransparency = 0.35,
		ZIndex = 9,
	}, 52)
	ui.BannerLine = new("Frame", { Name = "Line", BackgroundColor3 = P.gold_400, BorderSizePixel = 0, AnchorPoint = Vector2.new(0.5, 0), Position = UDim2.new(0.5, 0, 0, TS(52) + 10), Size = UDim2.fromOffset(0, 3), ZIndex = 9 }, box)
	UIKit.corner(ui.BannerLine, 2)
	ui.BannerSub = text(box, "Label", "", {
		Name = "Sub",
		AnchorPoint = Vector2.new(0.5, 0),
		Position = UDim2.new(0.5, 0, 0, TS(52) + 18),
		Size = UDim2.new(1, 0, 0, TS(16) + 4),
		TextXAlignment = Enum.TextXAlignment.Center,
		TextColor3 = P.ivory_200,
		TextStrokeColor3 = C.Shadow,
		TextStrokeTransparency = 0.4,
		ZIndex = 9,
	})
end

local bannerToken = 0
local bannerTweens: { Tween } = {}

local function stopBanner()
	bannerToken += 1
	for _, t in ipairs(bannerTweens) do
		t:Cancel()
	end
	table.clear(bannerTweens)
	if ui.Banner then
		ui.Banner.Visible = false
	end
end

-- Slides / scales in, holds ~1 s, fades. Reduced effects: a plain fade, no scale or sparks.
local function showStageBanner(stageNo: number, goal: string)
	stopBanner()
	local token = bannerToken
	local box, title, line, sub = ui.Banner :: Frame, ui.BannerTitle :: TextLabel, ui.BannerLine :: Frame, ui.BannerSub :: TextLabel
	local reduced = ClientSettings.Reduced()
	title.Text = UIKit.track("STAGE " .. tostring(stageNo))
	sub.Text = goal
	title.TextTransparency, title.TextStrokeTransparency = 1, 1
	sub.TextTransparency, sub.TextStrokeTransparency = 1, 1
	line.Size = UDim2.fromOffset(0, 3)
	line.BackgroundTransparency = 0
	box.Visible = true
	local function tw(obj: Instance, seconds: number, goalProps: { [string]: any }, style: Enum.EasingStyle?, dir: Enum.EasingDirection?)
		local t = UIAnim.Tween(obj, seconds, goalProps, style, dir)
		table.insert(bannerTweens, t)
		return t
	end
	local sc = UIAnim.ScaleOf(title)
	sc.Scale = reduced and 1 or 2.4
	tw(sc, 0.4, { Scale = 1 }, Enum.EasingStyle.Back)
	tw(title, 0.25, { TextTransparency = 0, TextStrokeTransparency = 0.35 })
	if not reduced then
		local at = UDim2.new(0.5, 0, 0, TS(52) / 2)
		UIAnim.Sparks(box, at, P.gold_200, 10, 120, 0.6)
		UIAnim.Ring(box, at, P.gold_300, 220, 0.5)
		task.delay(0.1, function()
			if token == bannerToken then
				tw(line, 0.45, { Size = UDim2.fromOffset(260, 3) }, Enum.EasingStyle.Quint)
			end
		end)
	end
	task.delay(reduced and 0 or 0.25, function()
		if token == bannerToken then
			tw(sub, 0.3, { TextTransparency = 0, TextStrokeTransparency = 0.4 })
		end
	end)
	task.delay(1.5, function()
		if token ~= bannerToken then
			return
		end
		tw(title, 0.4, { TextTransparency = 1, TextStrokeTransparency = 1 })
		tw(sub, 0.4, { TextTransparency = 1, TextStrokeTransparency = 1 })
		tw(line, 0.4, { BackgroundTransparency = 1 })
		task.delay(0.45, function()
			if token == bannerToken then
				box.Visible = false
			end
		end)
	end)
end

local function buildStatus(frame: Frame)
	local holder, face = UIKit.Surface(frame, { Name = "Status", Transparency = 0.12, Radius = 999, Visible = false })
	holder.AnchorPoint = Vector2.new(0.5, 0.5)
	ui.Status = holder
	UIKit.padding(face, 0, 22, 0, 18)
	local row = new("Frame", { BackgroundTransparency = 1, Size = UDim2.fromScale(1, 1) }, face)
	UIKit.list(row, { FillDirection = Enum.FillDirection.Horizontal, VerticalAlignment = Enum.VerticalAlignment.Center, Padding = UDim.new(0, 10) })
	ui.StatusIconHolder = new("Frame", { BackgroundTransparency = 1, Size = UDim2.fromOffset(22, 22), LayoutOrder = 1 }, row)
	ui.StatusText = text(row, "BodyStrong", "", {
		LayoutOrder = 2,
		Size = UDim2.new(1, -32, 1, 0),
		TextWrapped = true,
	}, Theme.TextSize.H3)
	ui.StatusMeter = UIKit.Meter(face, {
		Gradient = ColorSequence.new(P.moss_300, P.moss_500),
		AnchorPoint = Vector2.new(0.5, 1),
		Position = UDim2.new(0.5, 0, 1, -6),
		Size = UDim2.new(1, -24, 0, 5),
	})
	ui.StatusMeter.Frame.Visible = false
	ui.StatusIcon = ""
end

local function buildBar(frame: Frame)
	local bar = UIKit.Panel(frame, { Name = "AbilityBar", Active = false, BackgroundTransparency = 0.45 }, true)
	ui.Bar = bar
	ui.WeaponRow = new("Frame", { Name = "Weapons", BackgroundTransparency = 1, Active = false }, bar)
	UIKit.list(ui.WeaponRow, { FillDirection = Enum.FillDirection.Horizontal, HorizontalAlignment = Enum.HorizontalAlignment.Center, Padding = UDim.new(0, 6) })
	ui.PassiveRow = new("Frame", { Name = "Passives", BackgroundTransparency = 1, Active = false }, bar)
	UIKit.list(ui.PassiveRow, { FillDirection = Enum.FillDirection.Horizontal, HorizontalAlignment = Enum.HorizontalAlignment.Center, Padding = UDim.new(0, 6) })
end

-- Screen-edge vignette (its own full-screen ScreenGui, so it also covers notches).
local function buildVignette(fxGui: ScreenGui)
	local v = new("Frame", { Name = "HurtVignette", BackgroundTransparency = 1, Size = UDim2.fromScale(1, 1), Visible = false }, fxGui)
	ui.Vignette = v
	local edges = {}
	local function edge(rot: number, pos: UDim2, size: UDim2)
		local f = new("Frame", { BackgroundColor3 = P.crimson_600, BorderSizePixel = 0, Position = pos, Size = size }, v)
		new("UIGradient", {
			Rotation = rot,
			Transparency = NumberSequence.new({ NumberSequenceKeypoint.new(0, 0), NumberSequenceKeypoint.new(0.55, 0.75), NumberSequenceKeypoint.new(1, 1) }),
		}, f)
		table.insert(edges, f)
	end
	edge(90, UDim2.fromScale(0, 0), UDim2.fromScale(1, 0.22)) -- top (fades downward)
	edge(-90, UDim2.fromScale(0, 0.78), UDim2.fromScale(1, 0.22)) -- bottom
	edge(0, UDim2.fromScale(0, 0), UDim2.fromScale(0.16, 1)) -- left
	edge(180, UDim2.fromScale(0.84, 0), UDim2.fromScale(0.16, 1)) -- right
	ui.VignetteEdges = edges
	local level = new("NumberValue", { Name = "Level", Value = 1 }, v)
	ui.VignetteLevel = level
	level.Changed:Connect(function(t)
		for _, e in ipairs(edges) do
			e.BackgroundTransparency = t
		end
		v.Visible = t < 0.99
	end)
end

------------------------------------------------------------------------------------------
-- Layout
------------------------------------------------------------------------------------------

local barMetrics = { Weapon = 54, Passive = 44, Gap = 6, Pad = 8, OneRow = false }

local function layout()
	if not ui.Frame then
		return
	end
	local v: Vector2 = host.VirtualSize()
	local portrait: boolean = host.IsPortrait()
	local ins: Insets = host.Insets()
	local W, H = v.X, v.Y
	local compact = UIKit.IsCompact()
	local M = compact and Theme.Layout.MarginCompact or Theme.Layout.Margin

	-- pause + counters (top right)
	local pauseY = ins.Right > 4 and (ins.Top + 6) or 10
	place(ui.Pause.Instance, W - M - 52, pauseY, 52, 52)
	ui.Counters.AnchorPoint = Vector2.new(1, 0)
	ui.Counters.Position = UDim2.fromOffset(W - M - 52 - 10, pauseY + 4)

	-- timer (top centre; below the topbar if its buttons would touch it)
	local timerH = TS(Theme.TextSize.Display + 4) + 6
	local timerW = 220
	local timerY = 6
	if ins.Left + 8 > W / 2 - 70 then
		timerY = ins.Top + 2
	end
	if portrait then
		-- the counters sit top right; keep the timer clear of them
		local countersLeft = W - M - 52 - 10 - ui.Counters.AbsoluteSize.X / math.max(0.01, host.Scale())
		if countersLeft < W / 2 + 70 then
			timerY = math.max(timerY, pauseY + 56)
		end
	end
	place(ui.Timer, W / 2 - timerW / 2, timerY, timerW, timerH)

	-- stage pill under the timer
	local stageH = compact and 34 or 30
	local stageY = timerY + timerH - 2
	if portrait and ins.Left > 8 then
		-- the pill is wide ("STAGE 1 · The portal is dormant: 1:35"): on a narrow screen it
		-- would run into the Roblox menu buttons, so it goes below them
		stageY = math.max(stageY, ins.Top + 4)
	end
	ui.Stage.Position = UDim2.fromOffset(math.floor(W / 2 + 0.5), math.floor(stageY))
	ui.Stage.Size = UDim2.fromOffset(0, stageH)
	local stageBottom = ui.Stage.Visible and (stageY + stageH + 6) or (timerY + timerH + 2)

	-- plate
	local plateW = math.min(Theme.Layout.HudPlate.X, W - 2 * M)
	local plateH = compact and 78 or Theme.Layout.HudPlate.Y
	local plateY = stageBottom
	if portrait then
		-- keep the plate clear of the counters / pause row
		plateY = math.max(plateY, pauseY + 58)
	end
	place(ui.Plate, W / 2 - plateW / 2, plateY, plateW, plateH)

	-- boss bar under the plate
	local bossW = math.min(560, W - 2 * M)
	local bossY = plateY + plateH + 10
	place(ui.Boss, W / 2 - bossW / 2, bossY, bossW, 46)
	ui.TopBottom = bossY + (ui.Boss.Visible and 50 or 0)

	-- ability bar
	local slotsW = (inventory and inventory.WeaponSlots) or Config.Slots.Weapons
	local slotsP = (inventory and inventory.PassiveSlots) or Config.Slots.Passives
	local wt, pt = Config.UI.BarWeaponTile, Config.UI.BarPassiveTile
	if portrait then
		wt, pt = math.min(wt, 46), math.min(pt, 38)
	end
	local gap = 6
	local rowW = math.max(slotsW * wt + (slotsW - 1) * gap, slotsP * pt + (slotsP - 1) * gap)
	local pad = 8
	local barW = rowW + pad * 2
	local barH = wt + pt + gap + pad * 2
	barMetrics.Weapon, barMetrics.Passive = wt, pt
	local barY
	if portrait then
		-- under the plate / boss bar, away from the thumbs
		barY = (ui.Boss.Visible and (bossY + 52) or (plateY + plateH + 10))
	else
		barY = H - M - barH
	end
	place(ui.Bar, W / 2 - barW / 2, barY, barW, barH)
	place(ui.WeaponRow, pad, pad, rowW, wt)
	place(ui.PassiveRow, pad, pad + wt + gap, rowW, pt)

	-- the purse: centred just over the bar (portrait: just under it, the bar is up top).
	-- BarTop / BarBottom include it, so everything that keeps clear of the bar keeps
	-- clear of the purse too.
	local purseH = compact and 44 or 50
	ui.Purse.Size = UDim2.fromOffset(0, purseH)
	local clusterTop, clusterBottom
	if portrait then
		ui.Purse.Position = UDim2.fromOffset(math.floor(W / 2), barY + barH + 6)
		clusterTop, clusterBottom = barY, barY + barH + 6 + purseH
	else
		ui.Purse.Position = UDim2.fromOffset(math.floor(W / 2), barY - 8 - purseH)
		clusterTop, clusterBottom = barY - 8 - purseH, barY + barH
	end
	ui.PurseFloat.Position = UDim2.fromOffset(math.floor(W / 2), ui.Purse.Position.Y.Offset)
	ui.BarTop = clusterTop
	ui.BarBottom = clusterBottom
	if ui.Buff then
		if portrait then
			ui.Buff.AnchorPoint = Vector2.new(0.5, 0)
			ui.Buff.Position = UDim2.fromOffset(math.floor(W / 2), clusterBottom + 6)
		else
			ui.Buff.AnchorPoint = Vector2.new(0.5, 1)
			ui.Buff.Position = UDim2.fromOffset(math.floor(W / 2), clusterTop - 6)
		end
	end

	-- stage banner: under the top cluster in landscape, mid-screen in portrait
	ui.Banner.Size = UDim2.fromOffset(math.min(520, W - 2 * M), 110)
	ui.Banner.Position = UDim2.fromOffset(math.floor(W / 2), math.floor(portrait and H * 0.42 or math.max(H * 0.3, bossY + 90)))

	-- status line: centre-low in landscape, below the ability bar in portrait
	local statusW = math.min(640, W - 2 * M)
	ui.Status.Size = UDim2.fromOffset(statusW, compact and 58 or 50)
	if portrait then
		ui.Status.Position = UDim2.fromOffset(W / 2, clusterBottom + 40)
	else
		ui.Status.Position = UDim2.fromOffset(W / 2, math.min(H * 0.66, clusterTop - 44))
	end
end
Hud.Layout = layout

------------------------------------------------------------------------------------------
-- Ability bar contents
------------------------------------------------------------------------------------------

-- Icon key of an inventory weapon: its evolution once evolved.
local function weaponIconId(id: string, evolved: boolean): string
	local def = WeaponData.Weapons[id]
	if evolved and def and def.Evolution then
		return def.Evolution.Id
	end
	return id
end

-- Shine sweep inside the tile's rounded shape, plus sparks (new) or a flash (level up).
local function tileShine(tile: GuiObject, isNew: boolean)
	if ClientSettings.Reduced() then
		return
	end
	local clip = new("Frame", { Name = "ShineClip", BackgroundTransparency = 1, Size = UDim2.fromScale(1, 1), ClipsDescendants = true, ZIndex = 4 }, tile)
	local corner = tile:FindFirstChildWhichIsA("UICorner")
	if corner then
		corner:Clone().Parent = clip
	end
	UIAnim.SweepOnce(clip, P.ivory_100, 0.5, 0.2)
	if isNew then
		UIAnim.Sparks(tile, UDim2.fromScale(0.5, 0.5), P.gold_200, 8, 36, 0.5)
		UIAnim.Ring(tile, UDim2.fromScale(0.5, 0.5), P.gold_300, 70, 0.45)
	else
		UIAnim.Flash(tile, P.gold_200)
	end
	task.delay(0.7, function()
		clip:Destroy()
	end)
end

function Hud.SetInventory(inv: { [string]: any }?)
	inventory = inv
	for _, row in ipairs({ ui.WeaponRow, ui.PassiveRow }) do
		for _, c in ipairs(row:GetChildren()) do
			if c:IsA("GuiObject") then
				c:Destroy()
			end
		end
	end
	if not inv then
		table.clear(shownLevels)
		anim.BarReady = false
		return
	end
	layout()
	local wt, pt = barMetrics.Weapon, barMetrics.Passive
	-- tiles that are new or just levelled up pop in
	local function popIfChanged(tile: GuiObject, key: string, level: number)
		if shownLevels[key] ~= level then
			local isNew = shownLevels[key] == nil
			UIAnim.Pop(tile, 0, isNew and 0.3 or 1.35)
			shownLevels[key] = level
			-- the very first SetInventory of a run just fills the bar; only later changes shine
			if anim.BarReady then
				tileShine(tile, isNew)
			end
		end
	end
	local maxW = WeaponData.MaxLevel
	for i = 1, (inv.WeaponSlots or Config.Slots.Weapons) do
		local w = inv.Weapons[i]
		local tile
		if w then
			tile = UIKit.Tile(ui.WeaponRow, { Id = weaponIconId(w.Id, w.Evolved), Size = wt, Level = w.Level, Evolved = w.Evolved, Max = w.Level >= maxW })
			popIfChanged(tile, "W" .. w.Id, w.Level + (w.Evolved and 10 or 0))
		else
			tile = UIKit.Tile(ui.WeaponRow, { Size = wt, Empty = true })
		end
		tile.LayoutOrder = i
	end
	for i = 1, (inv.PassiveSlots or Config.Slots.Passives) do
		local p = inv.Passives[i]
		local tile
		if p then
			tile = UIKit.Tile(ui.PassiveRow, { Id = p.Id, Size = pt, Level = p.Level, Max = p.Level >= (p.MaxLevel or PassiveData.MaxLevelOf(p.Id)) })
			popIfChanged(tile, "P" .. p.Id, p.Level)
		else
			tile = UIKit.Tile(ui.PassiveRow, { Size = pt, Empty = true })
		end
		tile.LayoutOrder = i
	end
	anim.BarReady = true
end

------------------------------------------------------------------------------------------
-- Feedback
------------------------------------------------------------------------------------------

local vignetteTween: Tween? = nil

-- Crimson edge pulse (replaces the old full-screen red flash). Reduced effects: no
-- screen flash at all, only the heart icon reacts.
function Hud.Hurt()
	local level = ui.VignetteLevel :: NumberValue
	if not level then
		return
	end
	if ClientSettings.Reduced() then
		UIAnim.Punch(ui.Heart, 0.25)
		return
	end
	-- the bar flashes white for a frame or two (throttled so a swarm of hits stays calm)
	local now = os.clock()
	if now - (anim.HurtFlashAt or 0) > 0.25 then
		anim.HurtFlashAt = now
		UIAnim.Flash(ui.HP.Frame, P.ivory_100)
	end
	if vignetteTween then
		vignetteTween:Cancel()
	end
	level.Value = math.min(level.Value, 0.35)
	local tw = TweenService:Create(level, TweenInfo.new(0.5, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), { Value = 1 })
	vignetteTween = tw
	tw:Play()
	UIAnim.Punch(ui.Heart, 0.25)
end

local function setStatus(str: string, icon: string?, progress: number?)
	local show = str ~= ""
	if ui.Status.Visible ~= show then
		ui.Status.Visible = show
		if show then
			UIAnim.Pop(ui.Status, 0, 0.8)
		end
	end
	if not show then
		return
	end
	ui.StatusText.Text = str
	local iconName = icon or ""
	if ui.StatusIcon ~= iconName then
		ui.StatusIcon = iconName
		for _, c in ipairs(ui.StatusIconHolder:GetChildren()) do
			c:Destroy()
		end
		if icon then
			Icons.Draw(ui.StatusIconHolder, icon, { Size = 22, Color = P.gold_300 })
		end
	end
	ui.StatusMeter.Frame.Visible = progress ~= nil
	if progress then
		ui.StatusMeter.Set(progress)
	end
end

------------------------------------------------------------------------------------------
-- Purse (run gold)
------------------------------------------------------------------------------------------

local purse = { Shown = nil :: number?, Target = 0, LastPunch = 0, Float = nil :: TextLabel?, FloatAt = 0, FloatSum = 0, Price = 0, Afford = true, AlarmUntil = 0, Need = 0, Red = false }

-- "+N" rising off the purse; gains close together add up on one label.
local function purseFloat(gain: number)
	local now = os.clock()
	local f = purse.Float
	if f and f.Parent and now - purse.FloatAt < 0.4 then
		purse.FloatSum += gain
		f.Text = "+" .. UIKit.formatNumber(purse.FloatSum)
		UIAnim.Punch(f, 0.2)
		return
	end
	purse.FloatSum = gain
	purse.FloatAt = now
	local half = (ui.Purse.AbsoluteSize.X / math.max(0.01, host.Scale())) / 2
	local label = text(ui.PurseFloat, "Number", "+" .. UIKit.formatNumber(gain), {
		AnchorPoint = Vector2.new(0, 1),
		Position = UDim2.fromOffset(math.floor(half - 30), 4),
		Size = UDim2.fromOffset(120, 34),
		TextColor3 = P.gold_200,
		TextStrokeColor3 = C.Shadow,
		TextStrokeTransparency = 0.4,
		ZIndex = 6,
	}, 28)
	purse.Float = label
	UIAnim.Pop(label, 0, 0.5)
	local rise = ClientSettings.Reduced() and 10 or 30
	UIAnim.Tween(label, 0.9, { Position = label.Position - UDim2.fromOffset(0, rise), TextTransparency = 1, TextStrokeTransparency = 1 }, Enum.EasingStyle.Quad, Enum.EasingDirection.In)
	task.delay(0.95, function()
		label:Destroy()
	end)
end

--[[
	Chest / shrine price next to the purse (LootUI calls this every frame): price 0 = no
	priced loot in reach. alarm = the player just tried to open it without enough gold:
	the purse flashes red with "NEED N" for a moment and shakes.
]]
function Hud.SetPurseHint(price: number, afford: boolean, alarm: boolean?)
	purse.Price, purse.Afford = price, afford
	if alarm and ui.Purse then
		purse.AlarmUntil = os.clock() + 1.4
		purse.Need = math.max(0, price - (tonumber(player:GetAttribute("RunGold")) or 0))
		UIAnim.Punch(ui.Purse, 0.12)
		if not ClientSettings.Reduced() then
			local face = ui.PurseFace :: Frame
			face.Rotation = 4
			TweenService:Create(face, TweenInfo.new(0.05, Enum.EasingStyle.Linear, Enum.EasingDirection.InOut, 3, true), { Rotation = -4 }):Play()
			task.delay(0.42, function()
				face.Rotation = 0
			end)
		end
	end
end

updatePurse = function(dt: number)
	local gold = tonumber(player:GetAttribute("RunGold")) or 0
	local shown = purse.Shown
	if shown == nil then
		shown = gold
	elseif gold > purse.Target then
		purseFloat(gold - purse.Target)
		local now = os.clock()
		if now - purse.LastPunch > 0.12 then
			purse.LastPunch = now
			UIAnim.Punch(ui.Purse, 0.14)
			UIAnim.Punch(ui.PurseCoin, 0.35)
			if gold - purse.Target >= 5 then
				UIAnim.Sparks(ui.PurseCoin, UDim2.fromScale(0.5, 0.5), P.gold_200, 5, 26, 0.45)
			end
		end
	elseif gold < purse.Target then
		-- spent at a chest / shrine: the number drops quickly, no fanfare
		shown = math.min(shown, gold + (purse.Target - gold) * 0.5)
	end
	purse.Target = gold
	-- count up: quick at first, never slower than a few coins a frame
	local diff = gold - shown
	if math.abs(diff) < 0.5 then
		shown = gold
	else
		local step = diff * math.min(1, dt * 9)
		if math.abs(step) < 1 then
			step = diff > 0 and math.min(diff, 1) or math.max(diff, -1)
		end
		shown += step
	end
	purse.Shown = shown
	ui.PurseValue.Text = UIKit.formatNumber(math.floor(shown + 0.5))

	-- chest affordability
	local now = os.clock()
	local alarm = now < purse.AlarmUntil
	local hint, hintColor = "", C.TextMuted
	if alarm then
		hint, hintColor = "NEED " .. UIKit.formatNumber(math.max(1, purse.Need)), P.crimson_300
	elseif purse.Price > 0 then
		if purse.Afford then
			hint, hintColor = "/ " .. UIKit.formatNumber(purse.Price), P.moss_200
		else
			hint, hintColor = "NEED " .. UIKit.formatNumber(purse.Price - gold), P.crimson_300
		end
	end
	ui.PurseHint.Visible = hint ~= ""
	ui.PurseHint.Text = hint
	ui.PurseHint.TextColor3 = hintColor
	local red = alarm
	if purse.Red ~= red then
		purse.Red = red
		ui.PurseValue.TextColor3 = red and P.crimson_300 or P.gold_200
		if ui.PurseStroke then
			ui.PurseStroke.Color = red and P.crimson_400 or P.gold_500
			ui.PurseStroke.Transparency = red and 0 or 0.35
		end
	end
end

------------------------------------------------------------------------------------------
-- Per frame (only while in a run)
------------------------------------------------------------------------------------------

function Hud.Update(dt: number, state: Configuration, reviveOpen: boolean)
	refreshBuff()
	local phase = state:GetAttribute("Phase") or "Lobby"
	local runTime = state:GetAttribute("RunTime") or 0

	-- timer: punches each new minute, glows crimson in the last 10 s before the boss
	ui.Timer.Text = UIKit.formatClock(runTime)
	local minute = math.floor(runTime / 60)
	if minute ~= anim.Minute then
		if anim.Minute ~= nil then
			UIAnim.Punch(ui.Timer, 0.25)
			if not ClientSettings.Reduced() then
				ui.Timer.TextColor3 = P.gold_200
				UIAnim.Tween(ui.Timer, 0.9, { TextColor3 = C.Text })
			end
		end
		anim.Minute = minute
	end

	-- stage pill: what to do on this stage
	local stageNo = state:GetAttribute("Stage") or 0
	local stagePhase = state:GetAttribute("StagePhase") or "None"
	local goal, goalColor = "", C.Text
	if stagePhase == "Explore" then
		local chargeNow = state:GetAttribute("PortalCharge") or 0
		local lockLeft = state:GetAttribute("PortalLockLeft") or 0
		if chargeNow > 0 then
			goal = string.format("Opening the portal %d%%", math.floor(chargeNow * 100))
		elseif lockLeft > 0 then
			goal, goalColor = "The portal is dormant: " .. UIKit.formatTime(lockLeft), C.TextMuted
		else
			goal = "Find the portal"
		end
	elseif stagePhase == "Boss" then
		goal, goalColor = "Defeat the " .. tostring(state:GetAttribute("BossName") or state:GetAttribute("StageBoss") or "Queen"), P.crimson_300
	elseif stagePhase == "Surge" then
		local left = state:GetAttribute("SurgeLeft") or 0
		goal, goalColor = left > 0 and string.format("Survive the surge · %ds", left) or "Survive the surge", P.crimson_300
	elseif stagePhase == "Open" then
		goal, goalColor = "Portal open", P.gold_300
	elseif stagePhase == "Travel" then
		goal = "Travelling..."
	end
	local stageShown = stageNo > 0 and goal ~= ""
	if ui.Stage.Visible ~= stageShown then
		ui.Stage.Visible = stageShown
		layout()
	end
	if stageShown then
		local num = "STAGE " .. tostring(stageNo)
		if ui.StageNumber.Text ~= num then
			ui.StageNumber.Text = num
			UIAnim.Pop(ui.Stage, 0, 0.7)
		end
		if ui.StageGoal.Text ~= goal then
			ui.StageGoal.Text = goal
			if anim.StagePhase ~= stagePhase and anim.StagePhase ~= nil then
				UIAnim.Punch(ui.Stage, 0.2)
				glow(ui.Stage, (stagePhase == "Surge" or stagePhase == "Boss") and P.crimson_400 or P.gold_300)
				if stagePhase == "Surge" or stagePhase == "Boss" then
					UIAnim.Shake(ui.Stage, 4, 0.3)
				end
			end
		end
		anim.StagePhase = stagePhase
		ui.StageGoal.TextColor3 = goalColor
	end

	-- stage banner: once per stage, after the travel fade has lifted
	if stageNo > 0 and anim.BannerStage ~= stageNo then
		if stagePhase ~= "Travel" and not state:GetAttribute("Frozen") then
			anim.BannerStage = stageNo
			-- joining mid-fight (reconnect, boss already up): no banner over the action
			if stagePhase == "Explore" or stagePhase == "None" then
				showStageBanner(stageNo, goal)
			end
		end
	end

	-- health: the fill follows at once; the ivory trail (the damage chip) holds a beat
	-- and then slides down behind it
	local hp = player:GetAttribute("HP") or 0
	local maxHp = math.max(1, player:GetAttribute("MaxHP") or 1)
	local frac = math.clamp(hp / maxHp, 0, 1)
	local nowT = os.clock()
	if anim.LastFrac and frac < anim.LastFrac - 0.005 then
		anim.TrailHoldUntil = nowT + 0.3
	elseif anim.LastFrac and frac > anim.LastFrac + 0.01 and nowT - (anim.HealAt or 0) > 0.5 then
		-- heal shimmer: a soft green-white sweep over the bar, the heart swells
		anim.HealAt = nowT
		UIAnim.SweepOnce(ui.HP.Frame, P.moss_200, 0.5, 0.35)
		UIAnim.Punch(ui.Heart, 0.3)
	end
	anim.LastFrac = frac
	if frac > anim.HPTrail then
		anim.HPTrail = frac
	elseif nowT >= (anim.TrailHoldUntil or 0) then
		anim.HPTrail = math.max(frac, anim.HPTrail - dt * 0.45)
	end
	anim.HP += (frac - anim.HP) * math.min(1, dt * 14)
	local shield = player:GetAttribute("Shield") or 0
	ui.HP.Set(anim.HP)
	ui.ShieldBar.Visible = shield > 0
	if shield > 0 then
		ui.ShieldBar.Size = UDim2.new(math.clamp(shield / maxHp, 0, 1), 0, 0, 4)
	end
	ui.HP.SetTrail(anim.HPTrail)

	-- low health: the screen edge breathes crimson
	local level = ui.VignetteLevel :: NumberValue
	local alive = player:GetAttribute("Alive") ~= false
	if alive and frac > 0 and frac <= (Config.UI.LowHealthFraction or 0.3) then
		if nowT >= (anim.NextBeat or 0) then
			anim.NextBeat = nowT + 0.9
			UIAnim.Punch(ui.Heart, 0.18)
		end
		if not vignetteTween or vignetteTween.PlaybackState ~= Enum.PlaybackState.Playing then
			-- reduced effects: a steady edge instead of a breathing one
			level.Value = ClientSettings.Reduced() and 0.8 or (0.72 + 0.18 * (0.5 + 0.5 * math.sin(os.clock() * 4)))
		end
	elseif not vignetteTween or vignetteTween.PlaybackState ~= Enum.PlaybackState.Playing then
		level.Value = 1
	end

	-- XP: glides to its value; on a level up it flashes and restarts from 0
	local lvl = player:GetAttribute("Level") or 1
	local xp, need = player:GetAttribute("XP") or 0, player:GetAttribute("XPNeeded") or 1
	local target = math.clamp(xp / math.max(1, need), 0, 1)
	if anim.Level ~= nil and lvl > anim.Level then
		anim.XP = 0
		ui.XP.Fill.BackgroundTransparency = 0
		local flash = ui.XP.Fill:FindFirstChildOfClass("UIGradient")
		if flash and not ClientSettings.Reduced() then
			flash.Color = ColorSequence.new(P.ivory_100)
			task.delay(0.25, function()
				flash.Color = Theme.Gradient.XP
			end)
		end
		UIAnim.Punch(ui.Level, 0.4)
		-- level-up burst: a bright sweep along the bar, a ring and gold sparks
		UIAnim.SweepOnce(ui.XP.Frame, P.ivory_100, 0.45, 0.1)
		UIAnim.Ring(ui.XPRow, UDim2.new(0, 28, 0.5, 0), P.gold_200, 80, 0.5)
		UIAnim.Sparks(ui.XPRow, UDim2.new(0, 28, 0.5, 0), P.gold_200, 8, 40, 0.55)
		if not ClientSettings.Reduced() then
			ui.Level.TextColor3 = P.ivory_100
			UIAnim.Tween(ui.Level, 0.8, { TextColor3 = P.gold_300 })
		end
	elseif anim.LastXPFrac and target > anim.LastXPFrac + 0.015 and nowT - (anim.XPSweepAt or 0) > 0.6 then
		-- a gem burst: a quick glint along the bar
		anim.XPSweepAt = nowT
		UIAnim.SweepOnce(ui.XP.Frame, P.ivory_100, 0.4, 0.6)
	end
	anim.LastXPFrac = target
	anim.Level = lvl
	anim.XP += (target - anim.XP) * math.min(1, dt * 10)
	ui.XP.Set(anim.XP, string.format("%d / %d XP", xp, need))
	ui.Level.Text = "Lv. " .. tostring(lvl)

	-- counters
	local kills = player:GetAttribute("Kills") or 0
	if kills ~= anim.Kills then
		ui.Kills.SetValue(UIKit.formatNumber(kills))
		-- every 50th kill is a small celebration
		if anim.Kills and kills > anim.Kills and math.floor(kills / 50) > math.floor(anim.Kills / 50) then
			UIAnim.Punch(ui.Kills.Value, 0.35)
			if not ClientSettings.Reduced() then
				ui.Kills.Value.TextColor3 = P.gold_200
				UIAnim.Tween(ui.Kills.Value, 0.8, { TextColor3 = C.Text })
				local pos, w = ui.Counters.Position, ui.Counters.AbsoluteSize.X / math.max(0.01, host.Scale())
				UIAnim.Sparks(ui.Frame, UDim2.fromOffset(pos.X.Offset - w + 28, pos.Y.Offset + 22), P.gold_200, 6, 30, 0.45)
			end
		end
		anim.Kills = kills
	end
	updatePurse(dt)

	-- boss
	local bossMax = state:GetAttribute("BossMaxHP") or 0
	local bossShown = bossMax > 0
	if ui.Boss.Visible ~= bossShown then
		ui.Boss.Visible = bossShown
		layout()
	end
	if bossShown then
		local bfrac = math.clamp((state:GetAttribute("BossHP") or 0) / bossMax, 0, 1)
		if not anim.BossShown then
			anim.BossShown = true
			anim.BossTrail = 1
			anim.BossFill = 0 -- the bar fills with her name while she rises (BossIntro s)
			ui.BossName.Text = string.upper(tostring(state:GetAttribute("BossName") or "Scorpion Queen"))
			UIAnim.Pop(ui.Boss, 0, 0.3)
			UIAnim.Shake(ui.Boss, 7, 0.45)
			if not ClientSettings.Reduced() then
				ui.BossName.TextTransparency = 1
				ui.BossName.TextStrokeTransparency = 1
				UIAnim.Tween(ui.BossName, 0.7, { TextTransparency = 0, TextStrokeTransparency = 0.5 })
				UIAnim.Pop(ui.BossName, 0.15, 1.6)
			end
			UIAnim.SweepOnce(ui.BossMeter.Frame, P.crimson_200, 0.8, 0.4)
		end
		anim.BossFill = math.min(1, (anim.BossFill or 1) + dt / math.max(0.3, tonumber(state:GetAttribute("BossIntro")) or 2))
		bfrac = math.min(bfrac, anim.BossFill)
		ui.BossMeter.Set(bfrac)
		anim.BossTrail = math.max(bfrac, anim.BossTrail - dt * 0.25)
		ui.BossMeter.SetTrail(anim.BossTrail)
		local markAt = tonumber(state:GetAttribute("BossPhaseAt")) or 0
		ui.BossMark.Visible = markAt > 0 and markAt < 1
		-- crossing the phase marker: the bar shudders
		if markAt > 0 and markAt < 1 and bfrac < markAt and anim.BossPhaseHit ~= true and anim.BossFill >= 1 then
			anim.BossPhaseHit = true
			UIAnim.Shake(ui.Boss, 8, 0.4)
			UIAnim.SweepOnce(ui.BossMeter.Frame, P.ivory_100, 0.5, 0.3)
			UIAnim.Punch(ui.BossName, 0.25)
		end
		ui.BossMark.Position = UDim2.new(markAt, 0, 0, 36)
	else
		anim.BossShown = false
		anim.BossPhaseHit = false
	end

	-- status line
	local rewardNames = tostring(state:GetAttribute("RewardNames") or "")
	local rewardMine = string.find(tostring(state:GetAttribute("RewardIds") or ""), "," .. tostring(player.UserId) .. ",", 1, true) ~= nil
	if state:GetAttribute("Frozen") and rewardNames ~= "" and not state:GetAttribute("LevelUpPause") then
		-- someone's chest reward pauses the run (the opener sees the reward panel)
		if rewardMine then
			setStatus("")
		else
			local several = string.find(rewardNames, ",", 1, true) ~= nil
			setStatus(string.format("Paused: %s %s opening a chest", rewardNames, several and "are" or "is"), "chest")
		end
	elseif state:GetAttribute("Frozen") then
		if state:GetAttribute("LevelUpPause") then
			-- only someone else choosing is news; the chooser has the level-up cards
			local ids = state:GetAttribute("ChoosingIds") or ""
			local mine = string.find(ids, "," .. tostring(player.UserId) .. ",", 1, true) ~= nil
			local names = state:GetAttribute("ChoosingNames") or ""
			if mine or player:GetAttribute("Paused") or names == "" then
				setStatus("")
			else
				local several = string.find(names, ",", 1, true) ~= nil
				setStatus(string.format("Paused: %s %s choosing an upgrade", names, several and "are" or "is"), "hourglass")
			end
		else
			setStatus("Paused", "pause")
		end
	elseif not alive and not reviveOpen and phase == "Running" and stagePhase == "Open" then
		setStatus("The portal is open. Your team is choosing...", "portal")
	elseif not alive and not reviveOpen and phase == "Running" then
		local progress = player:GetAttribute("ReviveProgress") or 0
		if progress > 0 then
			setStatus(string.format("A teammate is reviving you... %d%%", math.floor(progress * 100)), "heart", progress)
		elseif (player:GetAttribute("PartnerRevivesLeft") or 0) > 0 then
			setStatus("You fell! A teammate can revive you by standing next to you.", "people2")
		else
			setStatus("You fell. Spectating your team...", "skull")
		end
	else
		setStatus("")
	end
end

-- Health number: rebuilt only when HP / MaxHP / Shield change (attribute signals on the
-- player, which survive respawns and revives), never per frame.
local function refreshHpText()
	if not ui.HP or not ui.HP.Label then
		return
	end
	local hp = math.ceil(tonumber(player:GetAttribute("HP")) or 0)
	local maxHp = math.max(1, math.ceil(tonumber(player:GetAttribute("MaxHP")) or 1))
	local shield = math.ceil(tonumber(player:GetAttribute("Shield")) or 0)
	ui.HP.Label.Text = shield > 0 and string.format("%d / %d HP  +%d", hp, maxHp, shield) or string.format("%d / %d HP", hp, maxHp)
end

-- Resets per-run animation state (a new run starts from a clean HUD).
function Hud.Reset()
	anim = { XP = 0, HP = 1, HPTrail = 1 }
	stopBanner()
	refreshHpText()
	purse.Shown = nil
	purse.Target = tonumber(player:GetAttribute("RunGold")) or 0
	purse.Price, purse.AlarmUntil = 0, 0
	Hud.SetInventory(nil)
	if ui.VignetteLevel then
		ui.VignetteLevel.Value = 1
	end
end

function Hud.SetVisible(on: boolean)
	if ui.Frame then
		ui.Frame.Visible = on
	end
	if not on then
		stopBanner()
		if ui.VignetteLevel then
			ui.VignetteLevel.Value = 1
		end
	end
end

-- Top of the ability bar.
function Hud.BarTop(): number
	return ui.BarTop or 600
end

-- Bottom of the top cluster (toasts go below it).
function Hud.TopBottom(): number
	return ui.TopBottom or 200
end

function Hud.Build(root: Frame, fxGui: ScreenGui, h: { [string]: any })
	host = h
	local frame = new("Frame", { Name = "HUD", Size = UDim2.fromScale(1, 1), BackgroundTransparency = 1, Visible = false, ZIndex = Theme.Z.Hud }, root)
	ui.Frame = frame
	buildTop(frame)
	buildStage(frame)
	buildBanner(frame)
	buildBuffChip(frame)
	buildBar(frame)
	buildPurse(frame)
	buildStatus(frame)
	buildVignette(fxGui)
	for _, name in ipairs({ "HP", "MaxHP", "Shield" }) do
		player:GetAttributeChangedSignal(name):Connect(refreshHpText)
	end
	refreshHpText()
	h.OnRelayout(layout)
	layout()
end

-- For the preview tool / tests: the HUD's elements.
function Hud.Elements(): { [string]: any }
	return ui
end

return Hud
