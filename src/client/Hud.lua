--[[
	Hud.lua
	The in-run HUD (built and driven by UIBuilder), laid out after the approved 02 Desktop /
	03 Mobile HUD (overhaul pack, docs/overhaul/HUD.md):
	  top left      vitals: one dark gold-rimmed panel under the Roblox buttons: heart + the
	                crimson health bar ("108 / 154 HP"; a steel band on it is the Guardian
	                Ward shield), then the level medallion, "LV 26" and the cyan XP bar
	                ("169 / 306 XP"; "Gold: ..." once levels pay coins). The run's item strip,
	                curse / bargain / synergy chips and reward popups follow under it
	                (LootUI, from Elements().LeftBottom / LeftWidth). Portrait: centred under
	                the objective.
	  top centre    the run timer in a dark pill, then the objective panel: a gold caption
	                "FOREST · STAGE 2 · WAVE 6" (Endless: "ENDLESS · STAGE 9 ...", the arena
	                name drops when it does not fit) over the one persistent objective
	                ("Find the portal", "Portal dormant · 0:26", "Opening the portal · 60%",
	                "Defeat the Scorpion Queen", "Survive the surge · 0:20"); under it the
	                boss bar with the boss's portrait while the boss lives; while the
	                Frostbound Colossus wears his frost armour (boss body attribute
	                FrostArmor, BossAI) the bar frosts over
	  top right     utility group: gold pill (run gold: earned this run, minus what chests and
	                shrines took), kills pill, the square pause (menu) button; the minimap
	                under them (MiniMap.lua). Next to a chest / shrine its price shows in the
	                gold pill (red "NEED N", LootUI SetPurseHint)
	  bottom centre the ability panel: "WEAPONS" and "PASSIVES" rows of square tiles (item
	                art, a round gold rank badge, a gold rim once evolved / maxed, quiet "+"
	                empty slots) and a BUILD column that opens the build details (every
	                weapon, passive and item with rank and effect; B / gamepad Y; the run
	                keeps going). Phones: scaled between the thumb side and the JUMP button.
	                Portrait: under the top cluster, away from the thumbs.
	  centre        status line (paused, "<Name> is choosing an upgrade", fallen, partner
	                revive progress); otherwise kept clear for combat
	The portal arrow, the charge ring, the portal choice panel and the travel fade live in
	StageUI.lua.
	  screen edges  crimson vignette pulse when hurt, slow pulse at low health (only those
	                two meanings: the wave-direction edge glow in StageUI is amber)
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

	The objective never hides (one persistent slot; short notices use UIState's centre
	lane). Texts are rewritten only when their value changes; text uses the Theme.Type roles
	(UIKit.Role).

	Nothing in the ability panel or the plates is Active, so a thumb landing on them still
	drives the floating thumbstick.
]]

local Players = game:GetService("Players")
local UserInputService = game:GetService("UserInputService")
local TweenService = game:GetService("TweenService")

local Shared = game:GetService("ReplicatedStorage"):WaitForChild("Shared")
local Config = require(Shared:WaitForChild("Config"))
local Theme = require(Shared:WaitForChild("Theme"))
local WeaponData = require(Shared:WaitForChild("WeaponData"))
local PassiveData = require(Shared:WaitForChild("PassiveData"))
local ItemData = require(Shared:WaitForChild("ItemData"))
local Remotes = require(Shared:WaitForChild("Remotes"))
local CharacterData = require(Shared:WaitForChild("CharacterData"))
local EnemyData = require(Shared:WaitForChild("EnemyData"))
local UIKit = require(script.Parent.UIKit)
local UIAnim = require(script.Parent.UIAnim)
local Icons = require(script.Parent.Icons)
local ArtImage = require(script.Parent.ArtImage)
local ClientSettings = require(script.Parent.ClientSettings)
local ClientPerformance = require(script.Parent.ClientPerformance)
local UIState = require(script.Parent.UIState)

local Hud = {}

-- RunIntro: the stage objective card replaces the plain stage banner (returns true when shown).
Hud.StageIntro = nil :: ((number) -> boolean)?

local player = Players.LocalPlayer
local new, role, TS = UIKit.new, UIKit.Role, UIKit.TS
local TY = Theme.Type
local C, P = Theme.Color, Theme.Palette

export type Insets = { Top: number, Left: number, Right: number }

-- A label that must stay inside its box: it scales down (never below `minSize`, never above
-- its own TextSize). Roblox's "Text size" accessibility setting (GuiService.PreferredTextSize)
-- grows plain TextSize text on the owner's phone by about 1.45x and does not touch TextScaled
-- text, so fixed boxes (tray labels, BUILD) use this.
local function fitText(label: TextLabel, minSize: number?): TextLabel
	local max = label.TextSize
	label.TextScaled = true
	local c = label:FindFirstChildOfClass("UITextSizeConstraint") or new("UITextSizeConstraint", {}, label)
	c.MaxTextSize = max
	c.MinTextSize = math.min(max, minSize or 9)
	return label
end

-- Health panel and ability panel, designed at full size (reference px), fitted with a UIScale.
local VIT = { W = 380, PadX = 10, PadY = 9, HP = 26, XP = 20, Gap = 8 } -- health / level panel
VIT.H = VIT.PadY * 2 + VIT.HP + VIT.Gap + VIT.XP
local INV = { Pad = 10, Label = 84, Tile = 64, Gap = 8, RowGap = 14, Build = 66 } -- ability panel (+ BUILD column)
local PILL_H, PAUSE = 44, 50 -- top right counters / pause button
local TIMER_W, TIMER_H = 150, 52
local OBJ_W, OBJ_H = 380, 54 -- objective panel under the timer (two lines)
-- XP / portal cyan of the approved HUD (02/03 mockups); the health bar stays crimson
local XP_GRADIENT = ColorSequence.new(Color3.fromRGB(150, 214, 229), Color3.fromRGB(84, 165, 189))
local XP_STROKE = Color3.fromRGB(42, 92, 110)

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

-- Objective panel under the timer (approved 02/03 HUD): a gold caption with where the run
-- is ("FOREST · STAGE 2 · WAVE 6") over the one current objective ("Find the portal",
-- "Portal dormant · 0:26", "Defeat the Scorpion Queen"). Persistent: the objective never
-- hides; short notices use the separate centre lane (UIState). Text shrinks before it
-- would truncate (TextScaled with a size cap), so long boss names and Endless fit phones.
local function buildStage(frame: Frame)
	local holder, face = goldSurface(frame, "Stage", Theme.Radius.M, UDim2.fromOffset(OBJ_W, OBJ_H))
	holder.AnchorPoint = Vector2.new(0.5, 0)
	ui.Stage = holder
	ui.StageFace = face
	UIKit.padding(face, 4, 14, 5, 14)
	-- the caption row: a thin gold rule, the caption, a rule (the mockup's "— FOREST · STAGE 1 —");
	-- it never scales: a caption too wide for the panel drops the arena name (updateStage)
	local cap = new("Frame", { Name = "Caption", BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0.42, 0) }, face)
	UIKit.list(cap, { FillDirection = Enum.FillDirection.Horizontal, HorizontalAlignment = Enum.HorizontalAlignment.Center, VerticalAlignment = Enum.VerticalAlignment.Center, Padding = UDim.new(0, 8) })
	ui.StageRuleL = new("Frame", { Name = "RuleL", BackgroundColor3 = P.gold_500, BackgroundTransparency = 0.35, BorderSizePixel = 0, Size = UDim2.fromOffset(18, 1), LayoutOrder = 1 }, cap)
	ui.StageNumber = role(cap, "Label", "STAGE 1", {
		Name = "Where",
		LayoutOrder = 2,
		Size = UDim2.fromScale(0, 1),
		AutomaticSize = Enum.AutomaticSize.X,
		TextColor3 = P.gold_200,
	})
	ui.StageRuleR = new("Frame", { Name = "RuleR", BackgroundColor3 = P.gold_500, BackgroundTransparency = 0.35, BorderSizePixel = 0, Size = UDim2.fromOffset(18, 1), LayoutOrder = 3 }, cap)
	ui.StageGoal = role(face, "Body", "", {
		Name = "Goal",
		AnchorPoint = Vector2.new(0.5, 1),
		Position = UDim2.fromScale(0.5, 1),
		Size = UDim2.new(1, 0, 0.58, 0),
		TextXAlignment = Enum.TextXAlignment.Center,
		TextColor3 = P.ivory_100,
		FontFace = Theme.Font.Heading,
		TextScaled = true,
	})
	new("UITextSizeConstraint", { MaxTextSize = TS(TY.Body.Size + 2), MinTextSize = 10 }, ui.StageGoal)
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
	-- "FROST ARMOR" after the name while the Colossus is armoured (updateBoss)
	ui.BossArmour = role(bossTitle, "Caption", "FROST ARMOR", {
		LayoutOrder = 3,
		Size = UDim2.fromOffset(0, 24),
		AutomaticSize = Enum.AutomaticSize.X,
		TextColor3 = P.ice_300,
		Visible = false,
	})
	ui.BossMeter = UIKit.Meter(boss, {
		Gradient = Theme.Gradient.Boss,
		Trail = true,
		Position = UDim2.fromOffset(0, 28),
		Size = UDim2.new(1, 0, 0, 16),
	})
	ui.BossStroke = UIKit.stroke(ui.BossMeter.Frame, P.crimson_400, 1.5, 0.2)
	-- the ice band over the bar while the armour is on
	ui.BossIce = new("Frame", { Name = "Ice", BackgroundColor3 = P.ice_300, BackgroundTransparency = 0.55, BorderSizePixel = 0, Size = UDim2.fromScale(1, 1), ZIndex = 5, Visible = false }, ui.BossMeter.Frame)
	UIKit.corner(ui.BossIce, 999)
	new("UIGradient", { Rotation = 90, Transparency = NumberSequence.new({ NumberSequenceKeypoint.new(0, 0), NumberSequenceKeypoint.new(0.5, 0.35), NumberSequenceKeypoint.new(1, 0.1) }) }, ui.BossIce)
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

	-- Aegis Charm ward (player attribute Ward): a small gold shield pip on the heart's
	-- lower-right corner while the ward is up (refreshWard, attribute signal only)
	ui.WardPip = new("Frame", { Name = "WardPip", BackgroundColor3 = P.gold_300, BorderSizePixel = 0, AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.new(0, 22, 0.5, 8), Size = UDim2.fromOffset(12, 12), ZIndex = 7, Visible = false }, hpRow)
	UIKit.corner(ui.WardPip, 999)
	UIKit.stroke(ui.WardPip, P.slate_950, 1.5, 0)
	new("Frame", { BackgroundColor3 = P.ivory_100, BorderSizePixel = 0, AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.5), Size = UDim2.fromOffset(4, 4), ZIndex = 8 }, ui.WardPip)

	-- Guardian Ward shield: a steel band along the top of the health bar
	ui.ShieldBar = new("Frame", { Name = "Shield", BackgroundColor3 = P.steel_200, BorderSizePixel = 0, Size = UDim2.new(0, 0, 0, 4), Visible = false, ZIndex = 6 }, ui.HP.Frame)
	UIKit.corner(ui.ShieldBar, 2)

	local xpRow = new("Frame", { Name = "XP", BackgroundTransparency = 1, Position = UDim2.fromOffset(VIT.PadX, VIT.PadY + VIT.HP + VIT.Gap), Size = UDim2.new(1, -2 * VIT.PadX, 0, VIT.XP) }, face)
	ui.XPRow = xpRow
	ui.Medal = medallion(xpRow, 24, 1)
	ui.Level = role(xpRow, "Number", "LV 1", {
		Name = "Level",
		Position = UDim2.fromOffset(32, 0),
		Size = UDim2.new(0, 66, 1, 0),
		TextColor3 = P.ivory_100,
	})
	ui.XP = UIKit.Meter(xpRow, {
		Gradient = XP_GRADIENT,
		TextStyle = "Number",
		TextSize = TY.Label.Size,
		AnchorPoint = Vector2.new(0, 0.5),
		Position = UDim2.new(0, 100, 0.5, 0),
		Size = UDim2.new(1, -100, 1, 0),
	})
	UIKit.stroke(ui.XP.Frame, XP_STROKE, 1.5, 0.1)

	-- bright leading edge on the XP fill (reads as the bar's "spark")
	local edge = new("Frame", { Name = "Edge", BackgroundColor3 = P.ivory_100, BackgroundTransparency = 0.55, BorderSizePixel = 0, AnchorPoint = Vector2.new(1, 0.5), Position = UDim2.fromScale(1, 0.5), Size = UDim2.new(0, 6, 1, 0), ZIndex = 3 }, ui.XP.Fill)
	UIKit.corner(edge, 999)
end

-- Icon key of an inventory weapon: its evolution once evolved.
local function weaponIconId(id: string, evolved: boolean): string
	local def = WeaponData.Weapons[id]
	if evolved and def and def.Evolution then
		return def.Evolution.Id
	end
	return id
end

-- Columns the ability panel shows: the owned weapons / passives plus one free "+" slot
-- (at least 3), up to the real slot count. A fresh run's tray is short and grows as the
-- build fills; the build details always state the full capacity ("WEAPONS 2 / 6").
local function shownSlots(): number
	local cap = math.max((inventory and inventory.WeaponSlots) or Config.Slots.Weapons, (inventory and inventory.PassiveSlots) or Config.Slots.Passives)
	local owned = math.max(inventory and inventory.Weapons and #inventory.Weapons or 0, inventory and inventory.Passives and #inventory.Passives or 0)
	return math.clamp(owned + 1, math.min(3, cap), cap)
end

local function invSize(): (number, number, number)
	local slots = shownSlots()
	local w = INV.Pad * 2 + INV.Label + slots * INV.Tile + math.max(0, slots - 1) * INV.Gap + INV.Build
	local h = INV.Pad * 2 + INV.Tile * 2 + INV.RowGap
	return w, h, slots
end

local setBuildOpen: (boolean) -> ()
local relayout: () -> () = function() end

-- Ability panel (bottom centre): labels + two rows of tiles, and at its right end the
-- BUILD button that opens the build details (every weapon, passive and item with its rank
-- and effect). The tiles stay non-Active (a thumb landing on them still moves the hero);
-- only the BUILD column takes input. Keyboard B / gamepad Y toggle it too.
local function buildBar(frame: Frame)
	local holder = new("Frame", { Name = "AbilityBar", BackgroundTransparency = 1, Active = false }, frame)
	ui.Bar = holder
	local w, h = invSize()
	local body, face = goldSurface(holder, "Body", Theme.Radius.L, UDim2.fromOffset(w, h))
	ui.BarBody = body
	ui.BarFit = new("UIScale", { Name = "Fit", Scale = 1 }, body)
	local function rowLabel(str: string, y: number)
		-- the word gets the label column only (the first tile starts right after it) and
		-- shrinks to fit: on a phone with large text "WEAPONS" ran under the first tile
		local l = role(face, "Label", str, {
			Name = str,
			Position = UDim2.fromOffset(INV.Pad + 2, y + math.floor(INV.Tile / 2) - 12),
			Size = UDim2.fromOffset(INV.Label - 8, 24),
			TextColor3 = P.ivory_100,
		})
		fitText(l, 9)
	end
	local y2 = INV.Pad + INV.Tile + INV.RowGap
	rowLabel("WEAPONS", INV.Pad)
	rowLabel("PASSIVES", y2)
	ui.BarRule = new("Frame", { Name = "Rule", BackgroundColor3 = P.gold_500, BackgroundTransparency = 0.7, BorderSizePixel = 0, Position = UDim2.fromOffset(INV.Pad, INV.Pad + INV.Tile + INV.RowGap / 2), Size = UDim2.new(1, -(2 * INV.Pad + INV.Build), 0, 1) }, face)
	ui.WeaponRow = new("Frame", { Name = "Weapons", BackgroundTransparency = 1, Active = false, Position = UDim2.fromOffset(INV.Pad + INV.Label, INV.Pad), Size = UDim2.new(1, -(2 * INV.Pad + INV.Label + INV.Build), 0, INV.Tile) }, face)
	UIKit.list(ui.WeaponRow, { FillDirection = Enum.FillDirection.Horizontal, VerticalAlignment = Enum.VerticalAlignment.Center, Padding = UDim.new(0, INV.Gap) })
	ui.PassiveRow = new("Frame", { Name = "Passives", BackgroundTransparency = 1, Active = false, Position = UDim2.fromOffset(INV.Pad + INV.Label, y2), Size = UDim2.new(1, -(2 * INV.Pad + INV.Label + INV.Build), 0, INV.Tile) }, face)
	UIKit.list(ui.PassiveRow, { FillDirection = Enum.FillDirection.Horizontal, VerticalAlignment = Enum.VerticalAlignment.Center, Padding = UDim.new(0, INV.Gap) })

	-- BUILD column: a divider, a chevron and the word; the whole column is the button
	new("Frame", { Name = "BuildRule", BackgroundColor3 = P.gold_500, BackgroundTransparency = 0.7, BorderSizePixel = 0, AnchorPoint = Vector2.new(1, 0), Position = UDim2.new(1, -(INV.Build - 4), 0, INV.Pad + 4), Size = UDim2.new(0, 1, 1, -(2 * INV.Pad + 8)) }, face)
	local btn = new("TextButton", {
		Name = "BuildButton",
		Text = "",
		AutoButtonColor = false,
		BackgroundColor3 = P.slate_800,
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		AnchorPoint = Vector2.new(1, 0.5),
		Position = UDim2.new(1, -4, 0.5, 0),
		Size = UDim2.new(0, INV.Build - 10, 1, -12),
		Selectable = true,
		ZIndex = 4,
	}, face)
	UIKit.corner(btn, Theme.Radius.M)
	ui.BuildButton = btn
	ui.BuildChevron = Icons.Draw(btn, "chevronsUp", { Size = 22, Color = P.gold_200, Back = P.slate_900, AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.new(0.5, 0, 0.5, -12), ZIndex = 5 })
	fitText(role(btn, "Label", "BUILD", {
		Name = "Word",
		AnchorPoint = Vector2.new(0.5, 0),
		Position = UDim2.new(0.5, 0, 0.5, 4),
		Size = UDim2.new(1, -6, 0, 20),
		TextXAlignment = Enum.TextXAlignment.Center,
		TextColor3 = P.ivory_100,
		ZIndex = 5,
	}), 9)
	btn.MouseEnter:Connect(function()
		btn.BackgroundTransparency = 0.4
	end)
	btn.MouseLeave:Connect(function()
		btn.BackgroundTransparency = ui.BuildOpen and 0.55 or 1
	end)
	btn.Activated:Connect(function()
		setBuildOpen(not ui.BuildOpen)
	end)
end

------------------------------------------------------------------------------------------
-- Build details (BUILD on the ability panel): what every owned weapon, passive and item
-- does, with its rank. A non-modal panel over the bottom of the arena (the run keeps
-- going; nothing pauses), closed by BUILD again, B / gamepad Y, its X, or any covering
-- overlay. Rebuilt only when it opens or the inventory / items change while open.
------------------------------------------------------------------------------------------

local runItems: { { Id: string, Count: number } } = {}
local BUILD_W = 560

local function buildDetails(frame: Frame)
	local holder, face = goldSurface(frame, "BuildDetails", Theme.Radius.L, UDim2.fromOffset(BUILD_W, 300))
	holder.Visible = false
	holder.Active = true -- taps on the open panel do not walk the hero
	holder.AnchorPoint = Vector2.new(0.5, 1)
	ui.Build = holder
	ui.BuildFace = face
	UIKit.padding(face, 8, 10, 10, 14)
	role(face, "Heading", "YOUR BUILD", { Name = "Title", Size = UDim2.new(1, -44, 0, 26) })
	ui.BuildNote = role(face, "Caption", "The run keeps going while this is open", { Name = "Note", Position = UDim2.fromOffset(0, 26), Size = UDim2.new(1, -44, 0, 16) })
	local close = UIKit.IconButton(face, {
		Icon = "close",
		Kind = "Outline",
		Size = 36,
		Name = "Close",
		AnchorPoint = Vector2.new(1, 0),
		Position = UDim2.new(1, 0, 0, 0),
		OnClick = function()
			setBuildOpen(false)
		end,
	})
	ui.BuildClose = close
	local list = new("ScrollingFrame", {
		Name = "List",
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		Position = UDim2.fromOffset(0, 46),
		Size = UDim2.new(1, 0, 1, -46),
		CanvasSize = UDim2.fromOffset(0, 0),
		AutomaticCanvasSize = Enum.AutomaticSize.Y,
		ScrollBarThickness = 4,
		ScrollBarImageColor3 = P.gold_500,
		ScrollingDirection = Enum.ScrollingDirection.Y,
		ElasticBehavior = Enum.ElasticBehavior.Never,
	}, face)
	UIKit.list(list, { Padding = UDim.new(0, 4) })
	UIKit.padding(list, 0, 8, 0, 0)
	ui.BuildList = list
end

-- One row: icon, name, rank (right) and the one-line effect.
local function detailRow(parent: Instance, order: number, icon: string, name: string, rank: string, effect: string, gold: boolean)
	local row = new("Frame", { Name = "Row", BackgroundColor3 = P.slate_800, BackgroundTransparency = 0.35, BorderSizePixel = 0, Size = UDim2.new(1, 0, 0, 48), LayoutOrder = order }, parent)
	UIKit.corner(row, Theme.Radius.S)
	if gold then
		UIKit.stroke(row, P.gold_400, 1.5, 0.2)
	end
	Icons.Upgrade(row, icon, { Size = 38, Position = UDim2.fromOffset(5, 5), Back = P.slate_800 })
	role(row, "Body", name, { Name = "Name", Position = UDim2.fromOffset(52, 3), Size = UDim2.new(1, -150, 0, 22), TextTruncate = Enum.TextTruncate.AtEnd })
	role(row, "Label", rank, { Name = "Rank", AnchorPoint = Vector2.new(1, 0), Position = UDim2.new(1, -8, 0, 3), Size = UDim2.fromOffset(92, 22), TextXAlignment = Enum.TextXAlignment.Right, TextColor3 = gold and P.gold_200 or P.ivory_300 })
	local fx = role(row, "Caption", effect, { Name = "Effect", Position = UDim2.fromOffset(52, 24), Size = UDim2.new(1, -60, 0, 20), TextColor3 = P.ivory_200, TextScaled = true })
	new("UITextSizeConstraint", { MaxTextSize = TS(TY.Caption.Size), MinTextSize = 9 }, fx)
end

local function detailHeader(parent: Instance, order: number, str: string)
	role(parent, "Label", str, { Name = "Section", Size = UDim2.new(1, 0, 0, 22), LayoutOrder = order, TextColor3 = P.gold_300 })
end

local function refreshDetails()
	local list = ui.BuildList :: ScrollingFrame?
	if not list or not ui.BuildOpen then
		return
	end
	for _, c in ipairs(list:GetChildren()) do
		if c:IsA("GuiObject") then
			c:Destroy()
		end
	end
	local inv = inventory
	local order = 0
	local function nextOrder(): number
		order += 1
		return order
	end
	local weapons = (inv and inv.Weapons) or {}
	local passives = (inv and inv.Passives) or {}
	detailHeader(list, nextOrder(), string.format("WEAPONS  %d / %d", #weapons, (inv and inv.WeaponSlots) or Config.Slots.Weapons))
	for _, wp in ipairs(weapons) do
		local def = WeaponData.Weapons[wp.Id]
		local evo = wp.Evolved and def and def.Evolution
		local name = evo and evo.Name or (def and def.Name) or wp.Id
		local rank = evo and "EVOLVED" or (wp.Level >= WeaponData.MaxLevel and string.format("MAX %d", wp.Level) or string.format("LV %d / %d", wp.Level, WeaponData.MaxLevel))
		local effect = (evo and evo.Description) or (def and def.Description) or ""
		detailRow(list, nextOrder(), weaponIconId(wp.Id, wp.Evolved), name, rank, effect, wp.Evolved or wp.Level >= WeaponData.MaxLevel)
	end
	detailHeader(list, nextOrder(), string.format("PASSIVES  %d / %d", #passives, (inv and inv.PassiveSlots) or Config.Slots.Passives))
	for _, ps in ipairs(passives) do
		local def = PassiveData.Passives[ps.Id]
		local maxLv = ps.MaxLevel or PassiveData.MaxLevelOf(ps.Id)
		local rank = ps.Level >= maxLv and string.format("MAX %d", ps.Level) or string.format("LV %d / %d", ps.Level, maxLv)
		detailRow(list, nextOrder(), ps.Id, (def and def.Name) or ps.Id, rank, (def and def.Description) or "", ps.Level >= maxLv)
	end
	local total = 0
	for _, it in ipairs(runItems) do
		total += it.Count
	end
	detailHeader(list, nextOrder(), total > 0 and string.format("ITEMS  %d", total) or "ITEMS  none yet")
	for _, it in ipairs(runItems) do
		local def = ItemData.Items[it.Id]
		if def then
			local rarity = def.Rarity and string.upper(def.Rarity) or ""
			detailRow(list, nextOrder(), it.Id, def.Name, (it.Count > 1 and ("x" .. it.Count .. "  ") or "") .. rarity, def.Text or def.Desc or "", false)
		end
	end
end

setBuildOpen = function(on: boolean)
	if not ui.Build then
		return
	end
	if on and not (ui.Frame and ui.Frame.Visible) then
		on = false
	end
	if ui.BuildOpen == on then
		return
	end
	ui.BuildOpen = on
	ui.Build.Visible = on
	-- routine headlines wait while the details are open (critical ones still show)
	UIState.SetHold("Build", on)
	ui.BuildButton.BackgroundTransparency = on and 0.55 or 1
	ui.BuildChevron.Rotation = on and 180 or 0
	if on then
		refreshDetails()
		if not (ClientSettings.Reduced() or ClientPerformance.Reduced()) then
			UIAnim.Pop(ui.Build, 0, 0.6)
		end
	end
	relayout()
end
Hud.SetBuildOpen = function(on: boolean)
	setBuildOpen(on)
end
function Hud.BuildOpen(): boolean
	return ui.BuildOpen == true
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
	-- the server's live Longbow bonus (SteadyAimBonus: with the hero's Signature upgrade);
	-- other weapons scale with it the way WeaponSystem does
	local base = trait and trait.Damage or 0.30
	local live = tonumber(player:GetAttribute("SteadyAimBonus")) or base
	local bow = math.floor(live * 100 + 0.5)
	local other = trait and math.floor((trait.OtherDamage or 0) * live / math.max(0.01, base) * 100 + 0.5) or 0
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
		TextScaled = true, -- long titles ("THE SWARM IS OVERWHELMING") shrink to fit phones
		ZIndex = 9,
	})
	new("UITextSizeConstraint", { MaxTextSize = TS(TY.Display.Size), MinTextSize = 14 }, ui.BannerTitle)
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

--[[
	The centre banner draws UIState's headline lane (docs/overhaul/UI_STATE_CONTRACT.md):
	  * UIState queues, dedupes by semantic id and holds headlines (one at a time); this
	    file only draws the one it is handed and reports when it has left;
	  * stack: persistent top-centre bars register with Hud.ReserveCentre (the caravan's
	    defence bar); while one is visible the banner drops below it.
]]
local bannerDone: (() -> ())? = nil
local bannerBaseY = 0
local centreBars: { GuiObject } = {}
local portraitBars: { GuiObject } = {} -- kept clear of the banner in portrait only
local bannerPortrait = false
local showBanner: (string, string, Color3?, (() -> ())?, (() -> ())?) -> ()

local function placeBanner()
	local box = ui.Banner :: Frame?
	if not box then
		return
	end
	local half = box.Size.Y.Offset / 2
	local y = bannerBaseY
	-- portrait: the left-edge minimap (Hud.AvoidInPortrait) sits about mid-screen too
	local list = centreBars
	if bannerPortrait and #portraitBars > 0 then
		list = table.clone(centreBars)
		for _, g in ipairs(portraitBars) do
			table.insert(list, g)
		end
	end
	for _ = 1, 3 do -- again: dropping under one bar may land on another
		for _, g in ipairs(list) do
			if g.Visible and g.Parent then
				local gh = g.Size.Y.Offset
				local top = g.Position.Y.Offset - g.AnchorPoint.Y * gh
				if y - half < top + gh + 8 and y + half > top - 8 then
					y = top + gh + 8 + half
				end
			end
		end
	end
	local at = UDim2.fromOffset(box.Position.X.Offset, math.floor(y))
	if box.Position ~= at then
		box.Position = at
	end
end

-- The status line (e.g. "A teammate is reviving you"): in portrait it drops below the
-- left-edge minimap (Hud.AvoidInPortrait) when they would overlap.
local statusBaseY = 0
local statusPortrait = false
local function placeStatus()
	local box = ui.Status :: Frame?
	if not box then
		return
	end
	local half = box.Size.Y.Offset / 2
	local y = statusBaseY
	if statusPortrait then
		for _ = 1, 2 do
			for _, g in ipairs(portraitBars) do
				if g.Visible and g.Parent then
					local gh = g.Size.Y.Offset
					local top = g.Position.Y.Offset - g.AnchorPoint.Y * gh
					if y - half < top + gh + 8 and y + half > top - 8 then
						y = top + gh + 8 + half
					end
				end
			end
		end
	end
	local at = UDim2.fromOffset(box.Position.X.Offset, math.floor(y))
	if box.Position ~= at then
		box.Position = at
	end
end

-- A persistent bar in the top centre (e.g. the caravan defence bar): banners stack under it.
function Hud.ReserveCentre(g: GuiObject)
	table.insert(centreBars, g)
end

-- A panel the centre banners must keep clear of in portrait only (the minimap there sits
-- at the left edge about mid-screen; in landscape it is in a corner).
function Hud.AvoidInPortrait(g: GuiObject)
	table.insert(portraitBars, g)
end

-- The portrait-only panels (the left-edge minimap), for world labels that must keep clear.
function Hud.PortraitBars(): { GuiObject }
	return portraitBars
end

-- The reserved top-centre bars (visible or not), for other markers that must keep clear.
function Hud.CentreBars(): { GuiObject }
	return centreBars
end

local function stopBanner()
	bannerToken += 1
	local done = bannerDone
	bannerDone = nil
	if done then
		done()
	end
	for _, t in ipairs(bannerTweens) do
		t:Cancel()
	end
	table.clear(bannerTweens)
	if ui.Banner then
		ui.Banner.Visible = false
	end
end

local function bannerLeft()
	local done = bannerDone
	bannerDone = nil
	if done then
		done()
	end
end

-- Slides / scales in, holds ~1 s, fades. Reduced effects: a plain fade, no scale or sparks.
-- `color` tints the title (the stage banner is gold; the portal reveal is arcane blue).
function showBanner(titleText: string, goal: string, color: Color3?, onShow: (() -> ())?, onDone: (() -> ())?)
	bannerToken += 1
	for _, t in ipairs(bannerTweens) do
		t:Cancel()
	end
	table.clear(bannerTweens)
	bannerLeft() -- a banner cut short still reports that it left
	bannerDone = onDone
	local token = bannerToken
	if onShow then
		onShow()
	end
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
	placeBanner()
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
				bannerLeft()
			end
		end)
	end)
end

local function showStageBanner(stageNo: number, goal: string)
	if Hud.StageIntro and Hud.StageIntro(stageNo) then
		return
	end
	UIState.Headline({ Id = "stage." .. tostring(stageNo), Title = "STAGE " .. tostring(stageNo), Sub = goal, Class = "Info" })
end

-- A one-off banner over the arena in the stage banner's style (StageUI: "THE PORTAL HAS
-- APPEARED"), through UIState's headline lane. `sound` names a Config.Sounds entry to
-- play with it (Audio); `id` is the semantic event id (default: the title), `class`
-- "Critical" for threats (they never wait for reward feedback or the stage card).
function Hud.Announce(title: string, sub: string, color: Color3?, sound: string?, id: string?, class: string?, expire: number?)
	UIState.Headline({ Id = id or title, Title = title, Sub = sub, Color = color, Sound = sound, Class = class or "Info", Prefer = true, Expire = expire })
end

-- UIState's headline renderer: draws `item` and calls `done` once it has left the screen.
local function renderHeadline(item: UIState.Headline, done: () -> ()): (() -> ())?
	if not ui.Banner then
		done()
		return nil
	end
	local sound = item.Sound
	showBanner(item.Title, item.Sub or "", item.Color, sound and function()
		if host.Audio and host.Audio.Play then
			host.Audio.Play(sound)
		end
	end or nil, done)
	-- UIState cancels it when a prompt / reward card / panel comes up under it
	return function()
		bannerDone = nil -- UIState already let go of it
		stopBanner()
	end
end

-- Bottom edge of the centre banner while it shows (notices sit under it), else nil.
function Hud.HeadlineBottom(): number?
	local box = ui.Banner :: Frame?
	if not box or not box.Visible or not (ui.Frame and ui.Frame.Visible) then
		return nil
	end
	return box.Position.Y.Offset + box.Size.Y.Offset * (1 - box.AnchorPoint.Y)
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

	-- utility group (top right): gold / kills pills + the pause (menu) button
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

	-- vitals (HP, run level, XP): top left under the Roblox buttons in landscape (the
	-- approved 02/03 layout); portrait has no room beside the timer, so they stack centred
	local kv = compact and 0.76 or 1
	kv = math.min(kv, (W - 2 * M) / VIT.W)
	ui.PlateFit.Scale = kv
	local vitW, vitH = VIT.W * kv, VIT.H * kv
	local leftRight = 0 -- right edge of the left column (vitals, item strip)
	local objW
	if portrait then
		-- the objective must clear Roblox's menu / chat buttons (44 px tall in a 58 px bar)
		y = math.max(y, ins.Top + 58 + 4)
		objW = math.min(OBJ_W + 40, W - 2 * M)
	else
		local vy = math.max(ins.Top, 4) + 6
		place(ui.Plate, M, vy, vitW, vitH)
		leftRight = M + vitW
		ui.LeftBottom = vy + vitH
		ui.LeftWidth = vitW
		-- the objective sits between the vitals and the minimap column under the counters
		local mapLeft = W - M - (compact and 128 or 180)
		local half = math.min(W / 2 - leftRight - 10, mapLeft - W / 2 - 10)
		objW = math.clamp(2 * half, 200, OBJ_W)
	end

	-- objective panel under the timer
	local objH = compact and 48 or OBJ_H
	ui.Stage.AnchorPoint = Vector2.new(0.5, 0)
	ui.Stage.Position = UDim2.fromOffset(math.floor(W / 2 + 0.5), math.floor(y))
	ui.Stage.Size = UDim2.fromOffset(math.floor(objW), objH)
	ui.StageRoom = objW
	if ui.Stage.Visible then
		y += objH + 6
	end

	if portrait then
		place(ui.Plate, W / 2 - vitW / 2, y, vitW, vitH)
		y += vitH
		ui.LeftBottom = nil
		ui.LeftWidth = nil
	end

	-- boss bar under the objective (clear of the left column in landscape)
	local bossW = portrait and math.min(560, W - 2 * M) or math.min(560, W - 2 * (leftRight + 12))
	local bossY = y + 4
	place(ui.Boss, W / 2 - bossW / 2, bossY, bossW, 46)
	local topBottom = ui.Boss.Visible and (bossY + 62) or (y + 2)
	ui.TopBottom = topBottom

	-- ability panel: bottom centre (landscape), between the thumb side and the JUMP button
	-- and never taller than ~25% of the screen; portrait: under the top cluster, away from
	-- the thumbs
	local invW, invH = invSize()
	local k
	if portrait then
		k = math.min(compact and 0.86 or 1, (W - 2 * M) / invW, (H * 0.22) / invH)
	else
		local jumpClear = (Config.Movement.ButtonSize or 84) + (Config.Movement.ButtonMargin or 26) / scale + ins.Right + 12
		k = math.min(compact and 0.68 or 0.78, (W - 2 * math.max(M, jumpClear)) / invW, (H * 0.24) / invH)
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

	-- build details: over the arena right above the ability panel (landscape) or under it
	-- (portrait), never under the top cluster
	if ui.Build then
		local bw = math.min(BUILD_W, W - 2 * M)
		if portrait then
			local top = clusterBottom + 8
			ui.Build.AnchorPoint = Vector2.new(0.5, 0)
			ui.Build.Position = UDim2.fromOffset(math.floor(W / 2), math.floor(top))
			ui.Build.Size = UDim2.fromOffset(math.floor(bw), math.floor(math.clamp(H - top - M - 140, 160, 460)))
		else
			local bottom = clusterTop - 8
			ui.Build.AnchorPoint = Vector2.new(0.5, 1)
			ui.Build.Position = UDim2.fromOffset(math.floor(W / 2), math.floor(bottom))
			ui.Build.Size = UDim2.fromOffset(math.floor(bw), math.floor(math.clamp(bottom - topBottom - 8, 150, 380)))
		end
		local face = ui.BuildFace :: Frame
		face.Size = UDim2.fromScale(1, 1)
	end

	-- stage banner: under the top cluster in landscape, mid-screen in portrait
	ui.Banner.Size = UDim2.fromOffset(math.min(520, W - 2 * M), 110)
	bannerBaseY = math.floor(portrait and H * 0.5 or math.max(H * 0.3, topBottom + 70))
	bannerPortrait = portrait
	ui.Banner.Position = UDim2.fromOffset(math.floor(W / 2), bannerBaseY)
	placeBanner()

	-- status line: centre-low in landscape, below the panels in portrait
	local statusW = math.min(640, W - 2 * M)
	ui.Status.Size = UDim2.fromOffset(statusW, compact and 58 or 50)
	if portrait then
		ui.Status.Position = UDim2.fromOffset(W / 2, clusterBottom + 40)
	else
		ui.Status.Position = UDim2.fromOffset(W / 2, math.min(H * 0.66, clusterTop - 44))
	end
	statusBaseY = ui.Status.Position.Y.Offset
	statusPortrait = portrait
	placeStatus()
end
Hud.Layout = layout
relayout = layout

------------------------------------------------------------------------------------------
-- Ability panel contents
------------------------------------------------------------------------------------------


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
		BackgroundTransparency = empty and 0.84 or 0.02,
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
	if empty then
		-- a quiet "+" says the slot can still be filled (capacity cue without a loud strip)
		new("TextLabel", {
			Name = "Plus",
			BackgroundTransparency = 1,
			Size = UDim2.fromScale(1, 1),
			Text = "+",
			FontFace = TY.Number.Font,
			TextSize = math.floor(size * 0.42),
			TextColor3 = P.slate_300,
			TextTransparency = 0.45,
			Active = false,
		}, tile)
	else
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
		setBuildOpen(false)
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
	local shown = shownSlots()
	for i = 1, math.min(shown, inv.WeaponSlots or Config.Slots.Weapons) do
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
	for i = 1, math.min(shown, inv.PassiveSlots or Config.Slots.Passives) do
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
	refreshDetails()
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
			-- the price in reach ("140 / 34" read like a fraction of a total)
			hint, hintColor = "COST " .. UIKit.formatNumber(purse.Price), P.moss_200
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

-- What to do on this stage: the objective sentence, the wave part of the caption ("WAVE 3",
-- "NEXT WAVE 0:03", "" = none) and the objective's colour. One wording everywhere: the
-- stage's way on is the PORTAL (the minimap legend, the edge marker and the banner say the
-- same word).
local function stageGoal(state: Configuration, stagePhase: string): (string, string, Color3)
	-- waves (Config.Waves, SwarmState Wave / WaveNext): "WAVE 3", or "NEXT WAVE 0:03"
	-- during the breather before it
	local waveText = ""
	local wave: number = tonumber(state:GetAttribute("Wave")) or 0
	local nextAt: number = tonumber(state:GetAttribute("WaveNext")) or 0
	if nextAt > 0 then
		local now: number = tonumber(state:GetAttribute("RunTime")) or 0
		waveText = string.format("WAVE %d IN %s", wave + 1, UIKit.formatTime(math.max(0, math.ceil(nextAt - now))))
	elseif wave > 0 then
		waveText = "WAVE " .. tostring(wave)
	end
	if stagePhase == "Explore" then
		local chargeNow = state:GetAttribute("PortalCharge") or 0
		local lockLeft = state:GetAttribute("PortalLockLeft") or 0
		if chargeNow > 0 then
			return string.format("Opening the portal · %d%%", math.floor(chargeNow * 100)), waveText, P.gold_200
		elseif lockLeft > 0 then
			return "Portal dormant · " .. UIKit.formatTime(lockLeft), waveText, P.ivory_100
		end
		-- swarm pressure (SwarmState SwarmWarn): the objective turns into a warning
		local warn = state:GetAttribute("SwarmWarn") or 0
		if warn >= 2 then
			return "Open the portal · swarm overwhelming", waveText, P.crimson_300
		elseif warn >= 1 then
			return "Open the portal · swarm growing", waveText, P.amber_300
		end
		return "Find the portal", waveText, P.ivory_100
	elseif stagePhase == "Boss" then
		return "Defeat the " .. tostring(state:GetAttribute("BossName") or state:GetAttribute("StageBoss") or "Queen"), waveText, P.crimson_300
	elseif stagePhase == "Surge" then
		local left = state:GetAttribute("SurgeLeft") or 0
		return left > 0 and ("Survive the surge · " .. UIKit.formatTime(left)) or "Survive the surge", waveText, P.crimson_300
	elseif stagePhase == "Open" then
		return "Portal open · step in", "", P.gold_200
	elseif stagePhase == "Travel" then
		return "Traveling", "", P.ivory_100
	end
	return "", "", P.ivory_100
end

local function updateStage(state: Configuration)
	local stageNo = state:GetAttribute("Stage") or 0
	local stagePhase = state:GetAttribute("StagePhase") or "None"
	local goal, waveText, goalColor = stageGoal(state, stagePhase)
	local stageShown = stageNo > 0 and goal ~= ""
	if ui.Stage.Visible ~= stageShown then
		ui.Stage.Visible = stageShown
		layout()
	end
	if stageShown then
		-- caption: "FOREST · STAGE 2 · WAVE 6" (Endless: "ENDLESS · STAGE 9 · ..."); a caption
		-- measured too wide for the panel drops the arena name (it is on the stage card)
		local arena = (Config.Arenas :: any)[tostring(state:GetAttribute("Arena") or "")]
		local where = state:GetAttribute("Endless") == true and "ENDLESS" or (type(arena) == "table" and arena.DisplayName and string.upper(arena.DisplayName)) or nil
		local parts = {}
		if where and anim.CaptionShort ~= stageNo then
			table.insert(parts, where)
		end
		table.insert(parts, "STAGE " .. tostring(stageNo))
		if waveText ~= "" then
			table.insert(parts, waveText)
		end
		local caption = table.concat(parts, " · ")
		if ui.StageNumber.Text ~= caption then
			local newStage = anim.CaptionStage ~= stageNo
			ui.StageNumber.Text = caption
			anim.CaptionStage = stageNo
			if newStage then
				UIAnim.Pop(ui.Stage, 0, 0.7)
			end
		end
		-- measure only on the few frames after the caption, UI scale or panel room changed
		-- (AutomaticSize settles within a frame or two): an AbsoluteSize read every frame
		-- forces a GUI layout pass each frame (PERF-01)
		local scale = host.Scale()
		if anim.CaptionMeasured ~= caption or anim.CaptionScale ~= scale or anim.CaptionRoom ~= ui.StageRoom then
			anim.CaptionMeasured, anim.CaptionScale, anim.CaptionRoom = caption, scale, ui.StageRoom
			anim.CaptionChecks = 4
		end
		if where and anim.CaptionShort ~= stageNo and ui.StageRoom and (anim.CaptionChecks or 0) > 0 then
			anim.CaptionChecks -= 1
			if ui.StageNumber.AbsoluteSize.X / math.max(0.01, scale) > ui.StageRoom - 2 * (18 + 8) - 28 then
				anim.CaptionShort = stageNo
			end
		end
		if ui.StageGoal.Text ~= goal then
			ui.StageGoal.Text = goal
			if string.sub(goal, 1, 15) == "Open the portal" and anim.GoalWarn ~= goal then
				anim.GoalWarn = goal
				UIAnim.Punch(ui.Stage, 0.25)
				UIAnim.Shake(ui.Stage, 4, 0.3)
				glow(ui.Stage, P.crimson_400)
			end
			if anim.StagePhase ~= stagePhase and anim.StagePhase ~= nil then
				UIAnim.Punch(ui.Stage, 0.2)
				glow(ui.Stage, (stagePhase == "Surge" or stagePhase == "Boss") and P.crimson_400 or P.gold_300)
				if stagePhase == "Surge" or stagePhase == "Boss" then
					UIAnim.Shake(ui.Stage, 4, 0.3)
				end
			end
		end
		anim.StagePhase = stagePhase
		if ui.StageGoal.TextColor3 ~= goalColor then
			ui.StageGoal.TextColor3 = goalColor
		end
	end

	-- stage banner: once per stage, after the travel fade has lifted
	if stageNo > 0 and anim.BannerStage ~= stageNo then
		if stagePhase ~= "Travel" and not state:GetAttribute("Frozen") then
			anim.BannerStage = stageNo
			-- joining mid-fight (reconnect, boss already up): no banner over the action
			if stagePhase == "Explore" or stagePhase == "None" then
				showStageBanner(stageNo, string.upper(goal))
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
				flash.Color = XP_GRADIENT
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
		or (player:GetAttribute("XPReward") == "Coins" and string.format("Gold: %d / %d XP", xp, need) or string.format("%d / %d XP", xp, need))
	if anim.XPShown ~= str then
		anim.XPShown = str
		ui.XP.Label.Text = str
	end
	setText(ui.Level, "LV " .. tostring(lvl))
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

-- The live boss's body (workspace.SwarmEnemies, EnemyData IsBoss; pooled bodies park
-- under y -100), looked up at most twice a second while the bar shows: its FrostArmor
-- attribute (BossAI) frosts the bar over.
local function bossBody(nowT: number): BasePart?
	local body = anim.BossBody
	if body and body.Parent and body.Position.Y > -100 then
		return body
	end
	if nowT < (anim.BossBodyAt or 0) then
		return nil
	end
	anim.BossBodyAt = nowT + 0.5
	anim.BossBody = nil
	local folder = workspace:FindFirstChild("SwarmEnemies")
	if folder then
		for _, m in ipairs(folder:GetChildren()) do
			local b = m:FindFirstChild("Body")
			if b and b:IsA("BasePart") and b.Position.Y > -100 then
				local def = EnemyData.Enemies[tostring(b:GetAttribute("Type") or "")]
				if def and def.IsBoss then
					anim.BossBody = b
					return b
				end
			end
		end
	end
	return nil
end

-- Frost armour on / off: ice band, ice rim, "FROST ARMOR" tag (only on a change).
local function setBossArmour(on: boolean)
	if anim.BossArmour == on then
		return
	end
	anim.BossArmour = on
	ui.BossIce.Visible = on
	ui.BossArmour.Visible = on
	ui.BossStroke.Color = on and P.ice_300 or P.crimson_400
	ui.BossStroke.Transparency = on and 0 or 0.2
	if on and ui.Boss.Visible and not (ClientSettings.Reduced() or ClientPerformance.Reduced()) then
		UIAnim.Pop(ui.BossArmour, 0, 0.6)
		UIAnim.SweepOnce(ui.BossMeter.Frame, P.ice_300, 0.6, 0.3)
	end
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
		anim.BossBody = nil
		setBossArmour(false)
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
	local body = bossBody(os.clock())
	setBossArmour(body ~= nil and body:GetAttribute("FrostArmor") == true)
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
		elseif player:GetAttribute("Paused") == true or UIState.IsShown("Pause") then
			-- this player's own run menu is open and says "SOLO · GAME PAUSED" itself; a
			-- second "Paused" banner only sat on the portal marker beside the drawer
			setStatus("")
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
			-- the hold time comes from the mode's revive rules (Config.Modes.<Mode>.PartnerRevive)
			local modeDef = (Config.Modes :: any)[state:GetAttribute("Mode") or ""]
			local secs = (modeDef and modeDef.PartnerRevive and modeDef.PartnerRevive.Seconds) or 2
			setStatus(string.format("You fell! A teammate standing beside you for %s second%s revives you.", tostring(secs), secs == 1 and "" or "s"), "people2")
		else
			setStatus("You fell. Spectating your team · Pause → MAIN MENU to leave now", "skull")
		end
	else
		setStatus("")
	end
end

function Hud.Update(dt: number, state: Configuration, reviveOpen: boolean)
	refreshBuff()
	if ui.Banner.Visible then
		placeBanner() -- a centre bar may appear mid-banner
	end
	if statusPortrait and ui.Status.Visible then
		placeStatus() -- the portrait minimap moves with the strips and chips
	end
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

-- Aegis Charm ward pip: shown while the player attribute Ward is true; pops when it
-- comes up (only on a change, never per frame).
local function refreshWard()
	local pip = ui.WardPip
	if not pip then
		return
	end
	local on = player:GetAttribute("Ward") == true
	if pip.Visible ~= on then
		pip.Visible = on
		if on and ui.Frame and ui.Frame.Visible and not (ClientSettings.Reduced() or ClientPerformance.Reduced()) then
			UIAnim.Pop(pip, 0, 1.6)
		end
	end
end

-- Resets per-run animation state (a new run starts from a clean HUD).
function Hud.Reset()
	anim = { XP = 0, HP = 1, HPTrail = 1 }
	stopBanner()
	refreshHpText()
	refreshWard()
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
		setBuildOpen(false)
		stopBanner()
		if ui.VignetteLevel then
			ui.VignetteLevel.Value = 1
		end
	end
end

function Hud.SetCovered(on: boolean)
	hudCovered = on
	if on then
		setBuildOpen(false) -- a decision / menu takes over; the details never linger behind it
	end
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
	-- the centre banner sits in its own full-screen layer one step above the HUD, so the
	-- world markers drawn after the HUD (StageUI's portal ring and edge arrow) never cover
	-- its text; the layer shows and hides with the HUD
	local top = new("Frame", { Name = "HUDTop", Size = UDim2.fromScale(1, 1), BackgroundTransparency = 1, Visible = false, Active = false, ZIndex = Theme.Z.Hud + 1 }, root)
	frame:GetPropertyChangedSignal("Visible"):Connect(function()
		top.Visible = frame.Visible
	end)
	buildBanner(top)
	UIState.SetRenderer("Headline", renderHeadline)
	buildBuffChip(frame)
	buildBar(frame)
	-- the build details sit in their own layer over the HUD, the banner layer and the world
	-- markers (the player opened them on purpose); shown and hidden with the HUD
	local detailLayer = new("Frame", { Name = "HUDBuild", Size = UDim2.fromScale(1, 1), BackgroundTransparency = 1, Visible = false, Active = false, ZIndex = Theme.Z.Hud + 4 }, root)
	frame:GetPropertyChangedSignal("Visible"):Connect(function()
		detailLayer.Visible = frame.Visible
	end)
	buildDetails(detailLayer)
	buildStatus(frame)
	buildVignette(fxGui)
	for _, name in ipairs({ "HP", "MaxHP", "Shield" }) do
		player:GetAttributeChangedSignal(name):Connect(refreshHpText)
	end
	refreshHpText()
	player:GetAttributeChangedSignal("Ward"):Connect(refreshWard)
	refreshWard()
	-- the run's items for the build details (the same list the item strip shows)
	Remotes.Get("Items").OnClientEvent:Connect(function(list)
		if type(list) ~= "table" then
			return
		end
		runItems = {}
		for _, it in ipairs(list) do
			if type(it) == "table" and type(it.Id) == "string" and ItemData.Items[it.Id] then
				table.insert(runItems, { Id = it.Id, Count = tonumber(it.Count) or 1 })
			end
		end
		refreshDetails()
	end)
	player:GetAttributeChangedSignal("InRun"):Connect(function()
		if not player:GetAttribute("InRun") then
			runItems = {}
			setBuildOpen(false)
		end
	end)
	-- B (keyboard) / Y (gamepad) toggle the build details while the HUD shows
	UserInputService.InputBegan:Connect(function(input, processed)
		if processed or UserInputService:GetFocusedTextBox() then
			return
		end
		if input.KeyCode == Enum.KeyCode.B or input.KeyCode == Enum.KeyCode.ButtonY then
			-- not under a panel that leaves the HUD visible (the run menu drawer owns input)
			if ui.Frame and ui.Frame.Visible and UIState.Owner() == nil then
				setBuildOpen(not ui.BuildOpen)
			end
		elseif input.KeyCode == Enum.KeyCode.ButtonStart and player:GetAttribute("InRun") == true then
			-- gamepad Start opens / closes the run menu like the on-screen menu button (S-16);
			-- a higher panel (level-up, reward, results...) keeps it shut (UIState.CanOpen)
			if UIState.Owner() == "Pause" then
				if host.OnPauseClose then
					host.OnPauseClose()
				end
			elseif UIState.CanOpen("Pause") and host.OnPause then
				host.OnPause()
			end
		end
	end)
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
