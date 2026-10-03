--[[
	Hud.lua
	The in-run HUD (built and driven by UIBuilder), laid out after the owner's approved
	mockup:
	  top centre    the run timer (total run time over every stage) big in a dark pill with a
	                thin gold rim; right under it one dark gold-rimmed panel: heart + big
	                crimson health bar ("100 / 100 HP"; a steel band on it is the Guardian
	                Ward shield), then a level medallion, "LV. 86" and the gold XP bar
	                ("29 / 110 XP"); under that the boss bar with the boss's portrait while
	                the boss lives
	  top left      the stage pill under the Roblox menu buttons: "STAGE 3 • PORTAL DORMANT
	                • 0:26" (goal and countdown of the stage loop; Endless runs: "ENDLESS •
	                STAGE 9 • ..."); portrait: centred between the timer and the health panel
	  top right     gold pill (coin + run gold: earned this run, minus what chests and shrines
	                took), kills pill (skull + count), then the square gold-rimmed pause
	                button. The gold number counts up and punches, a "+N" floats into the
	                pill, and next to a chest / shrine its price shows in the pill (red "NEED
	                N" after trying to open one without enough gold, set by LootUI through
	                SetPurseHint)
	  bottom centre only the ability panel (more of the arena in view): "WEAPONS" and
	                "PASSIVES" rows of square tiles (item art, a round gold level badge, a
	                gold rim once evolved / maxed, faint empty slots). Phones (compact): it
	                scales down and stays centred, between the thumbstick side and the JUMP
	                button. Portrait: it sits under the top cluster, away from the thumbs.
	  centre        status line (paused, "<Name> is choosing an upgrade", fallen, partner
	                revive progress)
	The portal arrow, the charge ring, the portal choice panel and the travel fade live in
	StageUI.lua.
	  screen edges  crimson vignette pulse when hurt, slow pulse at low health
	Motion (all event-driven, short, skipped or reduced with (ClientSettings.Reduced() or ClientPerformance.Reduced())):
	  XP bar        shine sweep per gem burst; level up = white flash, sweep, ring + sparks
	                on the medallion
	  health        white damage chip that holds a beat before it drains, heal shimmer, a
	                heart beat at low health
	  counters      kills punch + sparks on every 50th, timer flashes gold each minute
	  gold          bounce + coin sparkle on gains
	  ability panel a new weapon / passive pops with a shine sweep and sparks, a level up
	                with a flash
	  stage         "STAGE 2" banner slams in under the timer for ~1.5 s (after the travel
	                fade), the pill flashes when the objective changes (red for the surge)
	  boss bar      drops in with a shake, the name fades in under a sweep, shakes again at
	                the phase marker

	Calm: a plain objective ("FIND THE PORTAL") is news for a few seconds, then the stage
	pill is just "STAGE N"; counting goals (dormant portal, charge, surge) and the boss stay.
	Texts are rewritten only when their value changes; text uses the Theme.Type roles
	(UIKit.Role).

	Nothing in the ability panel or the plates is Active, so a thumb landing on them still
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
local ArtImage = require(script.Parent.ArtImage)
local ClientSettings = require(script.Parent.ClientSettings)
local ClientPerformance = require(script.Parent.ClientPerformance)

local Hud = {}

local player = Players.LocalPlayer
local new, role, TS = UIKit.new, UIKit.Role, UIKit.TS
local TY = Theme.Type
local C, P = Theme.Color, Theme.Palette

export type Insets = { Top: number, Left: number, Right: number }

-- Health panel and ability panel, designed at full size (reference px), fitted with a UIScale.
local VIT = { W = 420, PadX = 10, PadY = 9, HP = 26, XP = 20, Gap = 8 } -- health / level panel
VIT.H = VIT.PadY * 2 + VIT.HP + VIT.Gap + VIT.XP
local INV = { Pad = 10, Label = 84, Tile = 64, Gap = 8, RowGap = 14 } -- ability panel
local PILL_H, PAUSE = 44, 50 -- top right counters / pause button
local TIMER_W, TIMER_H = 150, 52
local STAGE_H = 30

local host: { [string]: any } = {}
local ui: { [string]: any } = {}
local anim: { [string]: any } = { XP = 0, HP = 1, HPTrail = 1 }
local inventory: { [string]: any }? = nil
local shownLevels: { [string]: number } = {}

local updatePurse: (number) -> ()

-- A soft colour flash over a Surface holder's face (a sibling of the face, so it never
-- joins the face's list layout); fades out and destroys itself.
local function glow(holder: GuiObject, color: Color3)
	if (ClientSettings.Flashes() or ClientPerformance.Reduced()) then
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

-- Sets a label's text only when it changed (no per-frame text churn).
local function setText(label: TextLabel, str: string)
	if label.Text ~= str then
		label.Text = str
	end
end

-- A dark HUD surface with the thin gold rim of the mockup.
local function goldSurface(parent: Instance, name: string, radius: number, size: UDim2?): (Frame, Frame)
	return UIKit.Surface(parent, { Name = name, Transparency = 0.12, Radius = radius, Edge = P.gold_500, EdgeTransparency = 0.25, Shadow = false, Size = size })
end

-- A pill that grows with its content (holder + face both AutomaticSize X).
local function autoPill(parent: Instance, name: string, h: number, radius: number, padL: number, padR: number, gap: number): (Frame, Frame)
	local holder, face = goldSurface(parent, name, radius, UDim2.fromOffset(0, h))
	holder.AutomaticSize = Enum.AutomaticSize.X
	face.AutomaticSize = Enum.AutomaticSize.X
	face.Size = UDim2.fromScale(0, 1)
	UIKit.padding(face, 0, padR, 0, padL)
	UIKit.list(face, { FillDirection = Enum.FillDirection.Horizontal, VerticalAlignment = Enum.VerticalAlignment.Center, Padding = UDim.new(0, gap) })
	return holder, face
end

------------------------------------------------------------------------------------------
-- Build
------------------------------------------------------------------------------------------

-- Timer pill (top centre).
local function buildTimer(frame: Frame)
	local holder, face = goldSurface(frame, "TimerPill", Theme.Radius.L)
	ui.TimerPill = holder
	ui.Timer = role(face, "Stat", "00:00", {
		Name = "Timer",
		Size = UDim2.fromScale(1, 1),
		TextSize = TS(TY.Display.Size),
		TextXAlignment = Enum.TextXAlignment.Center,
	})
end

-- Stage pill under the timer: "STAGE 2 • FIND THE PORTAL", "STAGE 3 • PORTAL DORMANT • 0:26".
local function buildStage(frame: Frame)
	local holder, face = autoPill(frame, "Stage", STAGE_H, 999, 14, 14, 7)
	holder.AnchorPoint = Vector2.new(0.5, 0)
	ui.Stage = holder
	local function label(order: number, color: Color3): TextLabel
		return role(face, "Label", "", { LayoutOrder = order, Size = UDim2.fromOffset(0, STAGE_H), AutomaticSize = Enum.AutomaticSize.X, TextColor3 = color })
	end
	local function dot(order: number): Frame
		local d = new("Frame", { BackgroundColor3 = P.gold_400, Size = UDim2.fromOffset(4, 4), LayoutOrder = order, BorderSizePixel = 0 }, face)
		UIKit.corner(d, 999)
		return d
	end
	ui.StageNumber = label(1, P.gold_200)
	ui.StageNumber.Text = "STAGE 1"
	ui.StageDot = dot(2)
	ui.StageGoal = label(3, P.ivory_100)
	ui.StageDot2 = dot(4)
	ui.StageCount = label(5, P.ivory_100)
end

-- Boss bar (under the stage pill while the boss lives).
local function buildBoss(frame: Frame)
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
	ui.BossName = role(bossTitle, "Heading", "SCORPION QUEEN", {
		LayoutOrder = 2,
		Size = UDim2.fromOffset(0, 24),
		AutomaticSize = Enum.AutomaticSize.X,
		TextColor3 = P.crimson_300,
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
	-- the boss's painted portrait (bosses/<BossId>) in a crimson-rimmed disc at the bar's
	-- left end; the bar starts after it. Hidden for a boss without a picture (setBossArt).
	local disc = new("Frame", { Name = "Portrait", BackgroundColor3 = P.slate_950, BackgroundTransparency = 0.1, BorderSizePixel = 0, AnchorPoint = Vector2.new(0, 0.5), Position = UDim2.new(0, 0, 0, 34), Size = UDim2.fromOffset(52, 52), ZIndex = 6, Visible = false }, boss)
	UIKit.corner(disc, 999)
	UIKit.stroke(disc, P.crimson_400, 2, 0.05)
	ui.BossSkull = Icons.Draw(disc, "skull", { Size = 26, Color = P.crimson_300, Back = P.slate_950, AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.5) })
	ui.BossDisc = disc
	ui.BossInset = 0
end

-- Top right: gold pill, kills pill (both in ui.Counters, right-aligned), pause button.
local function buildCounters(frame: Frame)
	local counters = new("Frame", { Name = "Counters", BackgroundTransparency = 1, AutomaticSize = Enum.AutomaticSize.X, Size = UDim2.fromOffset(0, PILL_H), AnchorPoint = Vector2.new(1, 0) }, frame)
	UIKit.list(counters, { FillDirection = Enum.FillDirection.Horizontal, HorizontalAlignment = Enum.HorizontalAlignment.Right, VerticalAlignment = Enum.VerticalAlignment.Center, Padding = UDim.new(0, 8) })
	ui.Counters = counters

	-- gold (the purse)
	local holder, face = autoPill(counters, "Purse", PILL_H, Theme.Radius.M, 10, 14, 8)
	holder.LayoutOrder = 1
	ui.Purse = holder
	ui.PurseFace = face
	ui.PurseStroke = face:FindFirstChildOfClass("UIStroke")
	ui.PurseCoin = Icons.Draw(face, "lobby_Gold", { Size = 28, LayoutOrder = 1 })
	ui.PurseValue = role(face, "Number", "0", {
		Name = "Value",
		LayoutOrder = 2,
		Size = UDim2.fromOffset(0, PILL_H),
		AutomaticSize = Enum.AutomaticSize.X,
	})
	ui.PurseHint = role(face, "Label", "", {
		Name = "Hint",
		LayoutOrder = 3,
		Size = UDim2.fromOffset(0, PILL_H),
		AutomaticSize = Enum.AutomaticSize.X,
		TextColor3 = C.TextMuted,
		Visible = false,
	})
	-- "+N" floaters drift into the pill (placed under it when they spawn)
	ui.PurseFloat = new("Frame", { Name = "PurseFloat", BackgroundTransparency = 1, Size = UDim2.fromOffset(1, 1), ZIndex = 5 }, frame)

	-- kills
	local kHolder, kFace = autoPill(counters, "Kills", PILL_H, Theme.Radius.M, 10, 14, 8)
	kHolder.LayoutOrder = 2
	local skull = Icons.Draw(kFace, "skull", { Size = 24, Color = P.ivory_100, Back = P.slate_900, LayoutOrder = 1 })
	local value = role(kFace, "Number", "0", {
		Name = "Value",
		LayoutOrder = 2,
		Size = UDim2.fromOffset(0, PILL_H),
		AutomaticSize = Enum.AutomaticSize.X,
	})
	ui.Kills = {
		Frame = kHolder,
		Icon = skull,
		Value = value,
		SetValue = function(s: string)
			setText(value, s)
		end,
	}

	ui.Pause = UIKit.IconButton(frame, {
		Icon = "pause",
		Kind = "Outline",
		Size = PAUSE,
		Name = "Pause",
		OnClick = function()
			if host.OnPause then
				host.OnPause()
			end
		end,
	})
end

-- The level medallion: a gold disc with a dark rim and the level-up chevrons.
local function medallion(parent: Instance, size: number, x: number): Frame
	local m = new("Frame", { Name = "Medallion", BackgroundColor3 = Color3.new(1, 1, 1), BorderSizePixel = 0, AnchorPoint = Vector2.new(0, 0.5), Position = UDim2.new(0, x, 0.5, 0), Size = UDim2.fromOffset(size, size) }, parent)
	UIKit.corner(m, 999)
	new("UIGradient", { Rotation = 90, Color = ColorSequence.new(P.gold_200, P.gold_500) }, m)
	UIKit.stroke(m, P.gold_700, 1.5, 0)
	local inner = new("Frame", { BackgroundColor3 = P.gold_600, BackgroundTransparency = 0.2, BorderSizePixel = 0, AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.5), Size = UDim2.fromScale(0.66, 0.66) }, m)
	UIKit.corner(inner, 999)
	Icons.Draw(inner, "chevronsUp", { Size = math.floor(size * 0.46), Color = P.ivory_100, Back = P.gold_600, AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.5) })
	return m
end

-- Health + level panel (top centre, under the timer). ui.Plate is the placed holder; its Body is drawn
-- at full size and fitted by a UIScale.
local function buildVitals(frame: Frame)
	local holder = new("Frame", { Name = "Plate", BackgroundTransparency = 1, Active = false }, frame)
	ui.Plate = holder
	local body, face = goldSurface(holder, "Body", Theme.Radius.L, UDim2.fromOffset(VIT.W, VIT.H))
	ui.PlateFit = new("UIScale", { Name = "Fit", Scale = 1 }, body)

	local hpRow = new("Frame", { Name = "HP", BackgroundTransparency = 1, Position = UDim2.fromOffset(VIT.PadX, VIT.PadY), Size = UDim2.new(1, -2 * VIT.PadX, 0, VIT.HP) }, face)
	ui.Heart = Icons.Draw(hpRow, "heart", { Size = 24, AnchorPoint = Vector2.new(0, 0.5), Position = UDim2.new(0, 1, 0.5, 0) })
	ui.HP = UIKit.Meter(hpRow, {
		Gradient = Theme.Gradient.Health,
		Trail = true,
		TextStyle = "Number",
		TextSize = TY.Number.Size,
		AnchorPoint = Vector2.new(0, 0.5),
		Position = UDim2.new(0, 34, 0.5, 0),
		Size = UDim2.new(1, -34, 1, 0),
	})
	UIKit.stroke(ui.HP.Frame, P.crimson_700, 1.5, 0.1)

	-- Guardian Ward shield: a steel band along the top of the health bar
	ui.ShieldBar = new("Frame", { Name = "Shield", BackgroundColor3 = P.steel_200, BorderSizePixel = 0, Size = UDim2.new(0, 0, 0, 4), Visible = false, ZIndex = 6 }, ui.HP.Frame)
	UIKit.corner(ui.ShieldBar, 2)

	local xpRow = new("Frame", { Name = "XP", BackgroundTransparency = 1, Position = UDim2.fromOffset(VIT.PadX, VIT.PadY + VIT.HP + VIT.Gap), Size = UDim2.new(1, -2 * VIT.PadX, 0, VIT.XP) }, face)
	ui.XPRow = xpRow
	ui.Medal = medallion(xpRow, 24, 1)
	ui.Level = role(xpRow, "Number", "LV. 1", {
		Name = "Level",
		Position = UDim2.fromOffset(32, 0),
		Size = UDim2.new(0, 66, 1, 0),
		TextColor3 = P.ivory_100,
	})
	ui.XP = UIKit.Meter(xpRow, {
		Gradient = Theme.Gradient.XP,
		TextStyle = "Number",
		TextSize = TY.Label.Size,
		AnchorPoint = Vector2.new(0, 0.5),
		Position = UDim2.new(0, 100, 0.5, 0),
		Size = UDim2.new(1, -100, 1, 0),
	})

	-- bright leading edge on the XP fill (reads as the bar's "spark")
	local edge = new("Frame", { Name = "Edge", BackgroundColor3 = P.ivory_100, BackgroundTransparency = 0.55, BorderSizePixel = 0, AnchorPoint = Vector2.new(1, 0.5), Position = UDim2.fromScale(1, 0.5), Size = UDim2.new(0, 6, 1, 0), ZIndex = 3 }, ui.XP.Fill)
	UIKit.corner(edge, 999)
end

local function invSize(): (number, number, number)
	local slots = math.max((inventory and inventory.WeaponSlots) or Config.Slots.Weapons, (inventory and inventory.PassiveSlots) or Config.Slots.Passives)
	local w = INV.Pad * 2 + INV.Label + slots * INV.Tile + math.max(0, slots - 1) * INV.Gap
	local h = INV.Pad * 2 + INV.Tile * 2 + INV.RowGap
	return w, h, slots
end

-- Ability panel (bottom centre): labels + two rows of tiles.
local function buildBar(frame: Frame)
	local holder = new("Frame", { Name = "AbilityBar", BackgroundTransparency = 1, Active = false }, frame)
	ui.Bar = holder
	local w, h = invSize()
	local body, face = goldSurface(holder, "Body", Theme.Radius.L, UDim2.fromOffset(w, h))
	ui.BarBody = body
	ui.BarFit = new("UIScale", { Name = "Fit", Scale = 1 }, body)
	local function rowLabel(str: string, y: number)
		role(face, "Label", str, {
			Name = str,
			Position = UDim2.fromOffset(INV.Pad + 2, y),
			Size = UDim2.fromOffset(INV.Label - 4, INV.Tile),
			TextColor3 = P.ivory_100,
		})
	end
	local y2 = INV.Pad + INV.Tile + INV.RowGap
	rowLabel("WEAPONS", INV.Pad)
	rowLabel("PASSIVES", y2)
	ui.BarRule = new("Frame", { Name = "Rule", BackgroundColor3 = P.gold_500, BackgroundTransparency = 0.7, BorderSizePixel = 0, Position = UDim2.fromOffset(INV.Pad, INV.Pad + INV.Tile + INV.RowGap / 2), Size = UDim2.new(1, -2 * INV.Pad, 0, 1) }, face)
	ui.WeaponRow = new("Frame", { Name = "Weapons", BackgroundTransparency = 1, Active = false, Position = UDim2.fromOffset(INV.Pad + INV.Label, INV.Pad), Size = UDim2.new(1, -(2 * INV.Pad + INV.Label), 0, INV.Tile) }, face)
	UIKit.list(ui.WeaponRow, { FillDirection = Enum.FillDirection.Horizontal, VerticalAlignment = Enum.VerticalAlignment.Center, Padding = UDim.new(0, INV.Gap) })
	ui.PassiveRow = new("Frame", { Name = "Passives", BackgroundTransparency = 1, Active = false, Position = UDim2.fromOffset(INV.Pad + INV.Label, y2), Size = UDim2.new(1, -(2 * INV.Pad + INV.Label), 0, INV.Tile) }, face)
	UIKit.list(ui.PassiveRow, { FillDirection = Enum.FillDirection.Horizontal, VerticalAlignment = Enum.VerticalAlignment.Center, Padding = UDim.new(0, INV.Gap) })
end

-- Buff chip (Ranger's Steady Aim): a small pill over the ability panel. Shown only for a
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
	ui.BuffText = role(face, "Label", "", { LayoutOrder = 2, Size = UDim2.fromOffset(0, 28), AutomaticSize = Enum.AutomaticSize.X })
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

-- Stage banner: "STAGE 2" slams in over the arena for a moment (showStageBanner).
local function buildBanner(frame: Frame)
	local box = new("Frame", { Name = "StageBanner", BackgroundTransparency = 1, AnchorPoint = Vector2.new(0.5, 0.5), Size = UDim2.fromOffset(520, 110), Visible = false, Active = false, ZIndex = 8 }, frame)
	ui.Banner = box
	ui.BannerTitle = role(box, "Display", "STAGE 1", {
		Name = "Title",
		AnchorPoint = Vector2.new(0.5, 0),
		Position = UDim2.fromScale(0.5, 0),
		Size = UDim2.new(1, 0, 0, TS(TY.Display.Size) + 6),
		TextXAlignment = Enum.TextXAlignment.Center,
		TextColor3 = P.gold_200,
		TextStrokeTransparency = 0.35,
		ZIndex = 9,
	})
	ui.BannerLine = new("Frame", { Name = "Line", BackgroundColor3 = P.gold_400, BorderSizePixel = 0, AnchorPoint = Vector2.new(0.5, 0), Position = UDim2.new(0.5, 0, 0, TS(TY.Display.Size) + 10), Size = UDim2.fromOffset(0, 3), ZIndex = 9 }, box)
	UIKit.corner(ui.BannerLine, 2)
	ui.BannerSub = role(box, "Body", "", {
		Name = "Sub",
		AnchorPoint = Vector2.new(0.5, 0),
		Position = UDim2.new(0.5, 0, 0, TS(TY.Display.Size) + 18),
		Size = UDim2.new(1, 0, 0, TS(TY.Body.Size) + 4),
		TextXAlignment = Enum.TextXAlignment.Center,
		TextColor3 = P.ivory_200,
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
-- `color` tints the title (the stage banner is gold; the portal reveal is arcane blue).
local function showBanner(titleText: string, goal: string, color: Color3?)
	stopBanner()
	local token = bannerToken
	local box, title, line, sub = ui.Banner :: Frame, ui.BannerTitle :: TextLabel, ui.BannerLine :: Frame, ui.BannerSub :: TextLabel
	local reduced = (ClientSettings.Reduced() or ClientPerformance.Reduced())
	title.Text = UIKit.track(titleText)
	title.TextColor3 = color or P.gold_200
	line.BackgroundColor3 = color or P.gold_400
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
		local at = UDim2.new(0.5, 0, 0, TS(TY.Display.Size) / 2)
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

local function showStageBanner(stageNo: number, goal: string)
	showBanner("STAGE " .. tostring(stageNo), goal, nil)
end

-- A one-off banner over the arena in the stage banner's style (StageUI: "THE PORTAL HAS
-- APPEARED"). `sound` names a Config.Sounds entry to play with it (Audio).
function Hud.Announce(title: string, sub: string, color: Color3?, sound: string?)
	if not ui.Banner then
		return
	end
	showBanner(title, sub, color)
	if sound and host.Audio and host.Audio.Play then
		host.Audio.Play(sound)
	end
end

local function buildStatus(frame: Frame)
	local holder, face = UIKit.Surface(frame, { Name = "Status", Transparency = 0.12, Radius = 999, Visible = false })
	holder.AnchorPoint = Vector2.new(0.5, 0.5)
	ui.Status = holder
	UIKit.padding(face, 0, 22, 0, 18)
	local row = new("Frame", { BackgroundTransparency = 1, Size = UDim2.fromScale(1, 1) }, face)
	UIKit.list(row, { FillDirection = Enum.FillDirection.Horizontal, VerticalAlignment = Enum.VerticalAlignment.Center, Padding = UDim.new(0, 10) })
	ui.StatusIconHolder = new("Frame", { BackgroundTransparency = 1, Size = UDim2.fromOffset(22, 22), LayoutOrder = 1 }, row)
	ui.StatusText = role(row, "Body", "", {
		LayoutOrder = 2,
		Size = UDim2.new(1, -32, 1, 0),
		TextWrapped = true,
	})
	ui.StatusMeter = UIKit.Meter(face, {
		Gradient = ColorSequence.new(P.moss_300, P.moss_500),
		AnchorPoint = Vector2.new(0.5, 1),
		Position = UDim2.new(0.5, 0, 1, -6),
		Size = UDim2.new(1, -24, 0, 5),
	})
	ui.StatusMeter.Frame.Visible = false
	ui.StatusIcon = ""
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

-- Boss bar portrait for boss `id` (bosses/<id>): the disc shows and the meter starts after
-- it; no picture → the plain full-width bar. Entrance: the portrait lands big and settles.
local function setBossArt(id: any)
	local key = ArtImage.Boss(type(id) == "string" and id or "ScorpionQueen")
	local has = ArtImage.Image(key) ~= nil
	ui.BossDisc.Visible = has
	ui.BossInset = has and 58 or 0
	ui.BossMeter.Frame.Position = UDim2.fromOffset(ui.BossInset, 28)
	ui.BossMeter.Frame.Size = UDim2.new(1, -ui.BossInset, 0, 16)
	if not has then
		return
	end
	if ui.BossArt then
		ArtImage.Set(ui.BossArt, key, { ui.BossSkull })
	else
		ui.BossArt = ArtImage.Place(ui.BossDisc, key, { Name = "Art", AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.45), Size = UDim2.fromScale(1.3, 1.3), ZIndex = 7 }, { ui.BossSkull })
	end
	if not (ClientSettings.Reduced() or ClientPerformance.Reduced()) then
		UIAnim.Pop(ui.BossDisc, 0.05, 2.2)
	end
end

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
	local scale = math.max(0.01, host.Scale())

	-- pause + gold / kills pills (top right)
	local pauseY = ins.Right > 4 and (ins.Top + 6) or 10
	place(ui.Pause.Instance, W - M - PAUSE, pauseY, PAUSE, PAUSE)
	ui.Counters.Position = UDim2.fromOffset(W - M - PAUSE - 8, pauseY + (PAUSE - PILL_H) / 2)
	local countersLeft = W - M - PAUSE - 8 - ui.Counters.AbsoluteSize.X / scale

	-- timer pill (top centre; below the Roblox buttons or the counters if it would touch them)
	local timerY = 6
	if ins.Left + 8 > W / 2 - TIMER_W / 2 then
		timerY = ins.Top + 2
	end
	if countersLeft < W / 2 + TIMER_W / 2 + 8 then
		timerY = math.max(timerY, pauseY + PAUSE + 6)
	end
	place(ui.TimerPill, W / 2 - TIMER_W / 2, timerY, TIMER_W, TIMER_H)
	local y = timerY + TIMER_H + 6

	-- stage pill: top left under the Roblox menu buttons (landscape); portrait has no room
	-- beside the timer, so it sits centred under it
	if portrait then
		ui.Stage.AnchorPoint = Vector2.new(0.5, 0)
		ui.Stage.Position = UDim2.fromOffset(math.floor(W / 2 + 0.5), math.floor(y))
		if ui.Stage.Visible then
			y += STAGE_H + 6
		end
		ui.LeftBottom = nil
	else
		local sy = math.max(ins.Top, 0) + 6
		ui.Stage.AnchorPoint = Vector2.new(0, 0)
		ui.Stage.Position = UDim2.fromOffset(M, math.floor(sy))
		ui.LeftBottom = ui.Stage.Visible and (sy + STAGE_H) or nil
	end

	-- health / level panel under the timer (one fit factor; phones a bit smaller)
	local kv = compact and 0.85 or 1
	kv = math.min(kv, (W - 2 * M) / VIT.W)
	ui.PlateFit.Scale = kv
	local vitW, vitH = VIT.W * kv, VIT.H * kv
	place(ui.Plate, W / 2 - vitW / 2, y, vitW, vitH)
	-- width the stage pill may take before it runs under the health panel (updateStage)
	ui.StageRoom = portrait and (W - 2 * M) or (W / 2 - vitW / 2 - 10 - M)
	y += vitH

	-- boss bar under the health panel
	local bossW = math.min(560, W - 2 * M)
	local bossY = y + 10
	place(ui.Boss, W / 2 - bossW / 2, bossY, bossW, 46)
	local topBottom = ui.Boss.Visible and (bossY + 62) or (y + 4)
	ui.TopBottom = topBottom

	-- ability panel: bottom centre (landscape), between the thumb side and the JUMP button
	-- and never taller than ~30% of the screen; portrait: under the top cluster, away from
	-- the thumbs
	local invW, invH = invSize()
	local k
	if portrait then
		k = math.min(compact and 0.86 or 1, (W - 2 * M) / invW, (H * 0.22) / invH)
	else
		local jumpClear = (Config.Movement.ButtonSize or 84) + (Config.Movement.ButtonMargin or 26) / scale + ins.Right + 12
		k = math.min(compact and 0.62 or 0.78, (W - 2 * math.max(M, jumpClear)) / invW, (H * 0.24) / invH)
	end
	ui.BarFit.Scale = k
	local barW, barH = invW * k, invH * k
	local barY = portrait and (topBottom + 8) or (H - M - barH)
	place(ui.Bar, W / 2 - barW / 2, barY, barW, barH)
	local clusterTop, clusterBottom = barY, barY + barH
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
	ui.Banner.Position = UDim2.fromOffset(math.floor(W / 2), math.floor(portrait and H * 0.5 or math.max(H * 0.3, topBottom + 70)))

	-- status line: centre-low in landscape, below the panels in portrait
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
-- Ability panel contents
------------------------------------------------------------------------------------------

-- Icon key of an inventory weapon: its evolution once evolved.
local function weaponIconId(id: string, evolved: boolean): string
	local def = WeaponData.Weapons[id]
	if evolved and def and def.Evolution then
		return def.Evolution.Id
	end
	return id
end

--[[
	One ability tile: a dark rounded square with the item art, a round gold level badge in
	the bottom-right corner and a gold rim once evolved / maxed; an empty slot is a faint
	outline. Not Active (touches pass through to the thumbstick).
]]
local function hudTile(parent: Instance, size: number, id: string?, level: number?, gold: boolean?): Frame
	local empty = id == nil
	local tile = new("Frame", {
		Name = empty and "Empty" or "Tile",
		Size = UDim2.fromOffset(size, size),
		BackgroundColor3 = Color3.new(1, 1, 1),
		BackgroundTransparency = empty and 0.75 or 0.02,
		BorderSizePixel = 0,
		Active = false,
	})
	UIKit.corner(tile, math.floor(size * 0.18))
	new("UIGradient", { Rotation = 90, Color = ColorSequence.new(P.slate_700, P.slate_950) }, tile)
	if gold then
		UIKit.stroke(tile, P.gold_400, 2.5, 0)
	else
		UIKit.stroke(tile, empty and P.slate_600 or P.slate_500, 1, empty and 0.55 or 0.15)
	end
	if not empty then
		local inset = math.floor(size * 0.08)
		Icons.Upgrade(tile, id, { Size = size - inset * 2, Position = UDim2.fromOffset(inset, inset), Back = P.slate_800, Name = "Icon" })
		if level and level > 0 then
			local d = math.max(16, math.floor(size * 0.38))
			local badge = new("TextLabel", {
				Name = "Badge",
				AnchorPoint = Vector2.new(0.5, 0.5),
				Position = UDim2.new(1, -math.floor(d * 0.3), 1, -math.floor(d * 0.3)),
				Size = UDim2.fromOffset(d, d),
				BackgroundColor3 = Color3.new(1, 1, 1),
				BorderSizePixel = 0,
				Text = tostring(level),
				FontFace = TY.Number.Font,
				TextSize = math.floor(d * 0.72),
				TextColor3 = P.gold_900,
				ZIndex = 5,
				Active = false,
			}, tile)
			UIKit.corner(badge, 999)
			new("UIGradient", { Rotation = 90, Color = ColorSequence.new(P.gold_200, P.gold_500) }, badge)
			UIKit.stroke(badge, P.slate_950, 1.5, 0.1)
		end
	end
	tile.Parent = parent
	return tile
end

-- Shine sweep inside the tile's rounded shape, plus sparks (new) or a flash (level up).
local function tileShine(tile: GuiObject, isNew: boolean)
	if (ClientSettings.Reduced() or ClientPerformance.Reduced()) then
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
	local w, h = invSize()
	ui.BarBody.Size = UDim2.fromOffset(w, h)
	layout()
	local size = INV.Tile
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
		local wp = inv.Weapons[i]
		local tile
		if wp then
			tile = hudTile(ui.WeaponRow, size, weaponIconId(wp.Id, wp.Evolved), wp.Level, wp.Evolved or wp.Level >= maxW)
			popIfChanged(tile, "W" .. wp.Id, wp.Level + (wp.Evolved and 10 or 0))
		else
			tile = hudTile(ui.WeaponRow, size)
		end
		tile.LayoutOrder = i
	end
	for i = 1, (inv.PassiveSlots or Config.Slots.Passives) do
		local p = inv.Passives[i]
		local tile
		if p then
			tile = hudTile(ui.PassiveRow, size, p.Id, p.Level, p.Level >= (p.MaxLevel or PassiveData.MaxLevelOf(p.Id)))
			popIfChanged(tile, "P" .. p.Id, p.Level)
		else
			tile = hudTile(ui.PassiveRow, size)
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
	if (ClientSettings.Flashes() or ClientPerformance.Reduced()) then
		if vignetteTween then vignetteTween:Cancel() end
		level.Value = 1
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
	setText(ui.StatusText, str)
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
-- Purse (run gold, the gold pill top right)
------------------------------------------------------------------------------------------

local purse = { Shown = nil :: number?, Target = 0, LastPunch = 0, Float = nil :: TextLabel?, FloatAt = 0, FloatSum = 0, Price = 0, Afford = true, AlarmUntil = 0, Need = 0, Red = false }

-- "+N" drifting up into the gold pill from just under it; gains close together add up on
-- one label.
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
	local scale = math.max(0.01, host.Scale())
	local rel = (ui.Purse.AbsolutePosition - ui.Frame.AbsolutePosition) / scale
	local size = ui.Purse.AbsoluteSize / scale
	local label = role(ui.PurseFloat, "Number", "+" .. UIKit.formatNumber(gain), {
		AnchorPoint = Vector2.new(0.5, 0),
		Position = UDim2.fromOffset(math.floor(rel.X + size.X / 2), math.floor(rel.Y + size.Y + 26)),
		Size = UDim2.fromOffset(120, 30),
		TextXAlignment = Enum.TextXAlignment.Center,
		TextColor3 = P.gold_200,
		ZIndex = 6,
	})
	purse.Float = label
	UIAnim.Pop(label, 0, 0.5)
	local rise = (ClientSettings.Reduced() or ClientPerformance.Reduced()) and 8 or 24
	UIAnim.Tween(label, 0.9, { Position = label.Position - UDim2.fromOffset(0, rise), TextTransparency = 1, TextStrokeTransparency = 1 }, Enum.EasingStyle.Quad, Enum.EasingDirection.In)
	task.delay(0.95, function()
		label:Destroy()
	end)
end

--[[
	Chest / shrine price next to the gold (LootUI calls this every frame): price 0 = no
	priced loot in reach. alarm = the player just tried to open it without enough gold:
	the gold pill flashes red with "NEED N" for a moment and shakes.
]]
function Hud.SetPurseHint(price: number, afford: boolean, alarm: boolean?)
	purse.Price, purse.Afford = price, afford
	if alarm and ui.Purse then
		purse.AlarmUntil = os.clock() + 1.4
		purse.Need = math.max(0, price - (tonumber(player:GetAttribute("RunGold")) or 0))
		UIAnim.Punch(ui.Purse, 0.12)
		if not (ClientSettings.Reduced() or ClientPerformance.Reduced()) then
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
			UIAnim.Punch(ui.Purse, 0.12)
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
	setText(ui.PurseValue, UIKit.formatNumber(math.floor(shown + 0.5)))

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
	if ui.PurseHint.Visible ~= (hint ~= "") then
		ui.PurseHint.Visible = hint ~= ""
	end
	setText(ui.PurseHint, hint)
	ui.PurseHint.TextColor3 = hintColor
	local red = alarm
	if purse.Red ~= red then
		purse.Red = red
		ui.PurseValue.TextColor3 = red and P.crimson_300 or C.Text
		if ui.PurseStroke then
			ui.PurseStroke.Color = red and P.crimson_400 or P.gold_500
			ui.PurseStroke.Transparency = red and 0 or 0.25
		end
	end
end

------------------------------------------------------------------------------------------
-- Per frame (only while in a run)
------------------------------------------------------------------------------------------

-- What to do on this stage: goal (upper case), a countdown / progress ("" = none) and the
-- goal's colour.
local function stageGoal(state: Configuration, stagePhase: string): (string, string, Color3)
	if stagePhase == "Explore" then
		local chargeNow = state:GetAttribute("PortalCharge") or 0
		local lockLeft = state:GetAttribute("PortalLockLeft") or 0
		if chargeNow > 0 then
			return "OPENING THE PORTAL", string.format("%d%%", math.floor(chargeNow * 100)), P.gold_200
		elseif lockLeft > 0 then
			return "PORTAL DORMANT", UIKit.formatTime(lockLeft), P.ivory_100
		end
		return "FIND THE PORTAL", "", P.ivory_100
	elseif stagePhase == "Boss" then
		return "DEFEAT THE " .. string.upper(tostring(state:GetAttribute("BossName") or state:GetAttribute("StageBoss") or "Queen")), "", P.crimson_300
	elseif stagePhase == "Surge" then
		local left = state:GetAttribute("SurgeLeft") or 0
		return "SURVIVE THE SURGE", left > 0 and UIKit.formatTime(left) or "", P.crimson_300
	elseif stagePhase == "Open" then
		return "PORTAL OPEN", "", P.gold_200
	elseif stagePhase == "Travel" then
		return "TRAVELLING", "", P.ivory_100
	end
	return "", "", P.ivory_100
end

local function updateStage(state: Configuration)
	local stageNo = state:GetAttribute("Stage") or 0
	local stagePhase = state:GetAttribute("StagePhase") or "None"
	local goal, count, goalColor = stageGoal(state, stagePhase)
	-- a boss objective measured too wide for the room left of the health panel (phones,
	-- long boss names, Endless) is shortened; the boss bar right below names the boss
	local longGoal = goal
	if stagePhase == "Boss" and anim.StageTooWide == longGoal then
		goal = "DEFEAT THE BOSS"
	end
	local stageShown = stageNo > 0 and goal ~= ""
	if ui.Stage.Visible ~= stageShown then
		ui.Stage.Visible = stageShown
		layout()
	end
	if stageShown then
		-- Endless runs say so on the pill ("ENDLESS • STAGE 9", SwarmState Endless)
		local num = (state:GetAttribute("Endless") == true and "ENDLESS • STAGE " or "STAGE ") .. tostring(stageNo)
		if ui.StageNumber.Text ~= num then
			ui.StageNumber.Text = num
			UIAnim.Pop(ui.Stage, 0, 0.7)
		end
		if ui.StageGoal.Text ~= goal then
			ui.StageGoal.Text = goal
			anim.StageNewsAt = os.clock()
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
		setText(ui.StageCount, count)
		-- calm: a plain objective is news for a few seconds, then the pill is just
		-- "STAGE N"; boss / surge / open portal and counting goals stay (urgent or moving)
		local urgent = stagePhase ~= "Explore" or count ~= ""
		local calm = not urgent and os.clock() - (anim.StageNewsAt or 0) > 8
		if ui.StageGoal.Visible == calm then
			ui.StageGoal.Visible = not calm
			ui.StageDot.Visible = not calm
		end
		local showCount = count ~= "" and not calm
		if ui.StageCount.Visible ~= showCount then
			ui.StageCount.Visible = showCount
			ui.StageDot2.Visible = showCount
		end
		if goal == longGoal and stagePhase == "Boss" and ui.StageRoom then
			if ui.Stage.AbsoluteSize.X / math.max(0.01, host.Scale()) > ui.StageRoom then
				anim.StageTooWide = longGoal
			end
		end
	end

	-- stage banner: once per stage, after the travel fade has lifted
	if stageNo > 0 and anim.BannerStage ~= stageNo then
		if stagePhase ~= "Travel" and not state:GetAttribute("Frozen") then
			anim.BannerStage = stageNo
			-- joining mid-fight (reconnect, boss already up): no banner over the action
			if stagePhase == "Explore" or stagePhase == "None" then
				local sub = count ~= "" and (goal .. " • " .. count) or goal
				showStageBanner(stageNo, sub)
			end
		end
	end
	return stagePhase
end

local function updateHealth(dt: number, nowT: number): (number, boolean)
	-- health: the fill follows at once; the ivory trail (the damage chip) holds a beat
	-- and then slides down behind it
	local hp = player:GetAttribute("HP") or 0
	local maxHp = math.max(1, player:GetAttribute("MaxHP") or 1)
	local frac = math.clamp(hp / maxHp, 0, 1)
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
	if math.abs(anim.HP - frac) > 0.0005 or anim.HPSet ~= anim.HP then
		anim.HP += (frac - anim.HP) * math.min(1, dt * 14)
		anim.HPSet = anim.HP
		ui.HP.Set(anim.HP)
	end
	ui.HP.SetTrail(anim.HPTrail)
	local shield = player:GetAttribute("Shield") or 0
	if ui.ShieldBar.Visible ~= (shield > 0) then
		ui.ShieldBar.Visible = shield > 0
	end
	if shield > 0 then
		ui.ShieldBar.Size = UDim2.new(math.clamp(shield / maxHp, 0, 1), 0, 0, 4)
	end

	-- low health: the screen edge breathes crimson
	local level = ui.VignetteLevel :: NumberValue
	if ClientSettings.Flashes() and vignetteTween and vignetteTween.PlaybackState == Enum.PlaybackState.Playing then
		vignetteTween:Cancel()
	end
	local alive = player:GetAttribute("Alive") ~= false
	if alive and frac > 0 and frac <= (Config.UI.LowHealthFraction or 0.3) then
		if nowT >= (anim.NextBeat or 0) then
			anim.NextBeat = nowT + 0.9
			if ui.Frame.Visible then
				if not (ClientSettings.Reduced() or ClientPerformance.Reduced()) then
					UIAnim.Punch(ui.Heart, 0.18)
				end
				if host.Audio and host.Audio.Play then
					host.Audio.Play("Heartbeat")
				end
			end
		end
		if not vignetteTween or vignetteTween.PlaybackState ~= Enum.PlaybackState.Playing then
			-- reduced effects: a steady edge instead of a breathing one
			level.Value = (ClientSettings.Flashes() or ClientPerformance.Reduced()) and 0.8 or (0.72 + 0.18 * (0.5 + 0.5 * math.sin(os.clock() * 4)))
		end
	elseif level.Value ~= 1 and (not vignetteTween or vignetteTween.PlaybackState ~= Enum.PlaybackState.Playing) then
		level.Value = 1
	end
	return frac, alive
end

local function updateXP(dt: number, nowT: number)
	-- XP: glides to its value; on a level up it flashes and restarts from 0
	local lvl = player:GetAttribute("Level") or 1
	local xp, need = player:GetAttribute("XP") or 0, player:GetAttribute("XPNeeded") or 1
	local target = math.clamp(xp / math.max(1, need), 0, 1)
	if anim.Level ~= nil and lvl > anim.Level then
		anim.XP = 0
		ui.XP.Fill.BackgroundTransparency = 0
		local flash = ui.XP.Fill:FindFirstChildOfClass("UIGradient")
		if flash and not (ClientSettings.Flashes() or ClientPerformance.Reduced()) then
			flash.Color = ColorSequence.new(P.ivory_100)
			task.delay(0.25, function()
				flash.Color = Theme.Gradient.XP
			end)
		end
		UIAnim.Punch(ui.Level, 0.4)
		UIAnim.Punch(ui.Medal, 0.4)
		-- level-up burst: a bright sweep along the bar, a ring and gold sparks off the medallion
		local at = UDim2.new(0, 13, 0.5, 0)
		if not ClientSettings.Flashes() then
			UIAnim.SweepOnce(ui.XP.Frame, P.ivory_100, 0.45, 0.1)
		end
		UIAnim.Ring(ui.XPRow, at, P.gold_200, 80, 0.5)
		UIAnim.Sparks(ui.XPRow, at, P.gold_200, 8, 40, 0.55)
		if not (ClientSettings.Flashes() or ClientPerformance.Reduced()) then
			ui.Level.TextColor3 = P.gold_200
			UIAnim.Tween(ui.Level, 0.8, { TextColor3 = P.ivory_100 })
		end
	elseif not ClientSettings.Flashes() and anim.LastXPFrac and target > anim.LastXPFrac + 0.015 and nowT - (anim.XPSweepAt or 0) > 0.6 then
		-- a gem burst: a quick glint along the bar
		anim.XPSweepAt = nowT
		UIAnim.SweepOnce(ui.XP.Frame, P.ivory_100, 0.4, 0.6)
	end
	anim.LastXPFrac = target
	anim.Level = lvl
	if math.abs(anim.XP - target) > 0.0005 or anim.XPSet ~= anim.XP then
		anim.XP += (target - anim.XP) * math.min(1, dt * 10)
		anim.XPSet = anim.XP
		ui.XP.Set(anim.XP)
	end
	local pending = tonumber(player:GetAttribute("PendingUpgrades")) or 0
	local str = pending > 0 and string.format("%d upgrade%s ready", pending, pending == 1 and "" or "s")
		or string.format("%s: %d / %d XP", player:GetAttribute("XPReward") == "Coins" and "Coins" or "Upgrade", xp, need)
	if anim.XPShown ~= str then
		anim.XPShown = str
		ui.XP.Label.Text = str
	end
	setText(ui.Level, "LV. " .. tostring(lvl))
end

local function updateKills()
	local kills = player:GetAttribute("Kills") or 0
	if kills == anim.Kills then
		return
	end
	ui.Kills.SetValue(UIKit.formatNumber(kills))
	-- every 50th kill is a small celebration
	if anim.Kills and kills > anim.Kills and math.floor(kills / 50) > math.floor(anim.Kills / 50) then
		UIAnim.Punch(ui.Kills.Value, 0.35)
		if not (ClientSettings.Reduced() or ClientPerformance.Reduced()) then
			ui.Kills.Value.TextColor3 = P.gold_200
			UIAnim.Tween(ui.Kills.Value, 0.8, { TextColor3 = C.Text })
			UIAnim.Sparks(ui.Kills.Icon, UDim2.fromScale(0.5, 0.5), P.gold_200, 6, 30, 0.45)
		end
	end
	anim.Kills = kills
end

local function updateBoss(dt: number, state: Configuration)
	local bossMax = state:GetAttribute("BossMaxHP") or 0
	local bossShown = bossMax > 0
	if ui.Boss.Visible ~= bossShown then
		ui.Boss.Visible = bossShown
		layout()
	end
	if not bossShown then
		anim.BossShown = false
		anim.BossPhaseHit = false
		return
	end
	local bfrac = math.clamp((state:GetAttribute("BossHP") or 0) / bossMax, 0, 1)
	if not anim.BossShown then
		anim.BossShown = true
		anim.BossTrail = 1
		anim.BossFill = 0 -- the bar fills with her name while she rises (BossIntro s)
		ui.BossName.Text = string.upper(tostring(state:GetAttribute("BossName") or "Scorpion Queen"))
		setBossArt(state:GetAttribute("BossId"))
		UIAnim.Pop(ui.Boss, 0, 0.3)
		UIAnim.Shake(ui.Boss, 7, 0.45)
		if not (ClientSettings.Reduced() or ClientPerformance.Reduced()) then
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
	ui.BossMark.Position = UDim2.new(markAt, ui.BossInset * (1 - markAt), 0, 36)
end

local function updateStatus(state: Configuration, phase: string, stagePhase: string, alive: boolean, reviveOpen: boolean)
	local rewardNames = tostring(state:GetAttribute("RewardNames") or "")
	local rewardMine = string.find(tostring(state:GetAttribute("RewardIds") or ""), "," .. tostring(player.UserId) .. ",", 1, true) ~= nil
	if state:GetAttribute("Frozen") and rewardNames ~= "" and not state:GetAttribute("LevelUpPause") then
		-- someone's chest reward pauses the run (the opener sees the reward panel)
		if rewardMine then
			setStatus("")
		else
			local several = string.find(rewardNames, ",", 1, true) ~= nil
			setStatus(string.format("Paused: %s %s opening a chest", rewardNames, several and "are" or "is"), "reward_ChestLarge")
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
	elseif tostring(state:GetAttribute("ChoosingNames") or "") ~= "" and not player:GetAttribute("Paused")
		and not string.find(tostring(state:GetAttribute("ChoosingIds") or ""), "," .. tostring(player.UserId) .. ",", 1, true) then
		-- group run: a teammate picks a card while the world keeps going (they can't be hurt)
		local names = tostring(state:GetAttribute("ChoosingNames"))
		local several = string.find(names, ",", 1, true) ~= nil
		setStatus(string.format("%s %s choosing an upgrade", names, several and "are" or "is"), "hourglass")
	elseif not alive and not reviveOpen and phase == "Running" and stagePhase == "Open" then
		setStatus("The portal is open. Your team is choosing...", "portal")
	elseif not alive and not reviveOpen and phase == "Running" then
		local progress = player:GetAttribute("ReviveProgress") or 0
		if progress > 0 then
			setStatus(string.format("A teammate is reviving you... %d%%", math.floor(progress * 100)), "heart", progress)
		elseif (player:GetAttribute("PartnerRevivesLeft") or 0) > 0 then
		setStatus("You fell! A teammate can hold REVIVE beside you for 2 seconds.", "people2")
		else
			setStatus("You fell. Spectating your team · Pause → MAIN MENU to leave now", "skull")
		end
	else
		setStatus("")
	end
end

function Hud.Update(dt: number, state: Configuration, reviveOpen: boolean)
	refreshBuff()
	local phase = state:GetAttribute("Phase") or "Lobby"
	local runTime = state:GetAttribute("RunTime") or 0

	-- timer: punches each new minute
	setText(ui.Timer, UIKit.formatClock(runTime))
	local minute = math.floor(runTime / 60)
	if minute ~= anim.Minute then
		if anim.Minute ~= nil then
			UIAnim.Punch(ui.TimerPill, 0.15)
			if not (ClientSettings.Reduced() or ClientPerformance.Reduced()) then
				ui.Timer.TextColor3 = P.gold_200
				UIAnim.Tween(ui.Timer, 0.9, { TextColor3 = C.Text })
			end
		end
		anim.Minute = minute
	end

	local stagePhase = updateStage(state)
	local nowT = os.clock()
	local _, alive = updateHealth(dt, nowT)
	updateXP(dt, nowT)
	updateKills()
	updatePurse(dt)
	updateBoss(dt, state)
	updateStatus(state, phase, stagePhase, alive, reviveOpen)
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

-- The HUD is shown in a run (SetVisible) and hidden while a full-screen modal covers it
-- (SetCovered: level-up, chest reel, pause, revive, results), so its timer / health panel
-- never sit on top of or show through a modal's title and buttons.
local hudOn, hudCovered = false, false
function Hud.SetVisible(on: boolean)
	hudOn = on
	if ui.Frame then
		ui.Frame.Visible = on and not hudCovered
	end
	if not on then
		stopBanner()
		if ui.VignetteLevel then
			ui.VignetteLevel.Value = 1
		end
	end
end

function Hud.SetCovered(on: boolean)
	hudCovered = on
	if ui.Frame then
		ui.Frame.Visible = hudOn and not on
	end
end

-- Top of the ability panel.
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
	buildTimer(frame)
	buildStage(frame)
	buildBoss(frame)
	buildCounters(frame)
	buildVitals(frame)
	buildBanner(frame)
	buildBuffChip(frame)
	buildBar(frame)
	buildStatus(frame)
	buildVignette(fxGui)
	for _, name in ipairs({ "HP", "MaxHP", "Shield" }) do
		player:GetAttributeChangedSignal(name):Connect(refreshHpText)
	end
	refreshHpText()
	-- the counters grow with their numbers; keep the timer clear of them
	ui.Counters:GetPropertyChangedSignal("AbsoluteSize"):Connect(layout)
	h.OnRelayout(layout)
	layout()
end

-- For the preview tool / tests: the HUD's elements.
function Hud.Elements(): { [string]: any }
	return ui
end

return Hud
