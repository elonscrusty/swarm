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

	[stream F, continuation brief] The run HUD now follows docs/redesign/continuation (RunUIConfig.Layout,
	RunLayout, RunTheme: navy panels, cream text, gold actions, cyan focus):
	  desktop   health + XP plate upper left, timer top centre (OVERTIME after 15:00) with the objective
	            strip (RunStage) and the boss bar under it, gold / kills / menu and the minimap upper
	            right, party indicators down the left (TeamUI), the 4 + 4 equipment rows along the
	            bottom (rank pips 1-5, an evolution mark)
	  phone     the brief's safe-area fractions: health 5% / 5%, timer 50% / 5%, map 82% / 17%, party
	            4% / 25%, equipment above a bottom XP strip; the touch controls are kept clear
	  portrait  a stack under the top cluster
	When the server has not set RunStage yet, the previous stage objective + boss bar stay.
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
local EvolutionPreview = require(Shared:WaitForChild("EvolutionPreview")) -- batch B5 (docs/next/EVOLUTION_PREVIEW.md)
local UIKit = require(script.Parent.UIKit)
local UIAnim = require(script.Parent.UIAnim)
local Icons = require(script.Parent.Icons)
local ArtImage = require(script.Parent.ArtImage)
local ClientSettings = require(script.Parent.ClientSettings)
local ClientPerformance = require(script.Parent.ClientPerformance)
local UIState = require(script.Parent.UIState)
-- [stream F] the continuation brief's run HUD (tokens, layout numbers, objective strip, widgets)
local RunConfig = require(game:GetService("ReplicatedStorage"):WaitForChild("SwarmV2"):WaitForChild("Run"):WaitForChild("RunConfig"))
local RunLayout = require(game:GetService("ReplicatedStorage"):WaitForChild("SwarmV2"):WaitForChild("Run"):WaitForChild("RunLayout"))
local RunClientFolder = script.Parent.Parent:WaitForChild("SwarmV2Client"):WaitForChild("Run")
local K = require(RunClientFolder:WaitForChild("RunTheme"))
local RunWidgets = require(RunClientFolder:WaitForChild("RunWidgets"))
local RunObjective = require(RunClientFolder:WaitForChild("RunObjective"))
local RunUI = RunConfig.UI

local Hud = {}

-- RunIntro: the stage objective card replaces the plain stage banner (returns true when shown).
Hud.StageIntro = nil :: ((number) -> boolean)?

local player = Players.LocalPlayer
local new, TS = UIKit.new, UIKit.TS
local TY = Theme.Type
local C, P = Theme.Color, Theme.Palette

-- Text in the Theme type roles, in the run tokens: cream on the navy panels (muted cream for
-- captions) unless the caller names a colour.
local function role(parent: Instance?, roleName: string, str: string, props: { [string]: any }?, world: boolean?): TextLabel
	local p = props or {}
	if p.TextColor3 == nil then
		p = table.clone(p)
		p.TextColor3 = if roleName == "Caption" then K.CreamMuted else K.Cream
	end
	return UIKit.Role(parent, roleName, str, p, world)
end

export type Insets = { Top: number, Left: number, Right: number }

-- A label that must stay inside its box: it scales down (never below `minSize`, never above
-- its own TextSize). Roblox's "Text size" accessibility setting (GuiService.PreferredTextSize)
-- grows plain TextSize text on the owner's phone by about 1.45x and does not touch TextScaled
-- text, so fixed boxes (tray labels, BUILD) use this.
local function fitText(label: TextLabel, minSize: number?): TextLabel
	local max = label.TextSize
	label.TextScaled = true
	-- our own named constraint; TextFit's (it skips TextScaled labels) must not stay
	local tf = label:FindFirstChild("TextFit")
	if tf then
		tf:Destroy()
	end
	label:SetAttribute("NoTextFit", true)
	local c = label:FindFirstChild("Fit") or new("UITextSizeConstraint", { Name = "Fit" }, label)
	c.MaxTextSize = max
	c.MinTextSize = math.min(max, minSize or 9)
	return label
end

-- Health plate + equipment panel, designed at full size (design px). Desktop and portrait: the
-- plate holds health and the level / XP row; phone landscape: health only (the XP strip sits at
-- the bottom, above nothing, with the equipment right above it).
local VIT = { W = 320, PadX = 12, PadY = 10, HP = 26, XP = 20, Gap = 8 }
VIT.H = VIT.PadY * 2 + VIT.HP + VIT.Gap + VIT.XP
local VIT_PHONE = { W = 224, H = 42, PadX = 10, PadY = 8 }
-- equipment panel: weapons | passives (4 + 4), rank pips under every tile, + the BUILD button
local INV = { Pad = 8, Tile = 56, Gap = 6, Split = 18, Build = 58, Pips = 10, PipSize = 7 }
local XP_STRIP = { W = 420, H = 26 }
local PILL_H, PAUSE = 44, 50 -- top right counters / pause button
local TIMER_W, TIMER_H = 128, 46
local OVERTIME_EXTRA = 118 -- the timer pill grows by this once the OVERTIME tag shows
local OBJ_W, OBJ_H = 380, 54 -- previous stage objective panel under the timer (two lines)
-- the XP bar is cyan on a navy track; the health bar stays red
local XP_GRADIENT = ColorSequence.new(K.Cyan, K.CyanDeep)
local XP_STROKE = K.NavyEdge

local host: { [string]: any } = {}
local ui: { [string]: any } = {}
local anim: { [string]: any } = { XP = 0, HP = 1, HPTrail = 1 }
local inventory: { [string]: any }? = nil
local shownLevels: { [string]: number } = {}

local updatePurse: (number) -> ()
local clockTick = RunObjective.Ticker() -- RunClock continued between the server's updates
local hudOn, hudCovered = false, false

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

-- A HUD plate in the run tokens: an opaque navy face, a quiet blue-grey rim and a dark base
-- under it (RunWidgets.Panel), so text stays readable over any scenery.
local function goldSurface(parent: Instance, name: string, radius: number, size: UDim2?): (Frame, Frame)
	return RunWidgets.Panel(parent, { Name = name, Radius = radius, Size = size or UDim2.fromScale(1, 1) })
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

-- Timer pill (top centre): the run clock. Once the clock passes RunConfig.UI.OvertimeAt an
-- OVERTIME tag joins it (updateTimer widens the pill and shows the tag).
local function buildTimer(frame: Frame)
	local holder, face = goldSurface(frame, "TimerPill", Theme.Radius.L)
	ui.TimerPill = holder
	ui.TimerFace = face
	ui.Timer = role(face, "Stat", "00:00", {
		Name = "Timer",
		Size = UDim2.fromScale(1, 1),
		TextSize = TS(28),
		TextXAlignment = Enum.TextXAlignment.Center,
	})
	fitText(ui.Timer, 16)
	local tag = new("Frame", { Name = "OvertimeTag", BackgroundColor3 = K.DangerDeep, BorderSizePixel = 0, AnchorPoint = Vector2.new(0, 0.5), Position = UDim2.new(0, 8, 0.5, 0), Size = UDim2.fromOffset(OVERTIME_EXTRA - 14, 30), Visible = false, Active = false, ZIndex = 3 }, face)
	UIKit.corner(tag, 999)
	UIKit.stroke(tag, K.Danger, 1.5, 0)
	ui.OvertimeTag = tag
	ui.OvertimeText = fitText(role(tag, "Label", "OVERTIME", { Size = UDim2.fromScale(1, 1), TextXAlignment = Enum.TextXAlignment.Center, TextColor3 = K.Cream, ZIndex = 4 }), 10)
end

-- Previous stage objective panel (Stage / StagePhase flow): a caption with where the run is over
-- the one current objective. Kept for runs whose server has not set RunStage yet; the new strip
-- (RunObjective) replaces it once RunStage exists. Text shrinks before it would truncate.
local function buildStage(frame: Frame)
	local holder, face = goldSurface(frame, "Stage", Theme.Radius.M, UDim2.fromOffset(OBJ_W, OBJ_H))
	holder.AnchorPoint = Vector2.new(0.5, 0)
	ui.Stage = holder
	ui.StageFace = face
	UIKit.padding(face, 4, 14, 5, 14)
	-- the caption row: a thin rule, the caption, a rule; it never scales: a caption too wide
	-- for the panel drops the arena name (updateStage)
	local cap = new("Frame", { Name = "Caption", BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0.42, 0) }, face)
	UIKit.list(cap, { FillDirection = Enum.FillDirection.Horizontal, HorizontalAlignment = Enum.HorizontalAlignment.Center, VerticalAlignment = Enum.VerticalAlignment.Center, Padding = UDim.new(0, 8) })
	ui.StageRuleL = new("Frame", { Name = "RuleL", BackgroundColor3 = K.Cyan, BackgroundTransparency = 0.2, BorderSizePixel = 0, Size = UDim2.fromOffset(18, 2), LayoutOrder = 1 }, cap)
	ui.StageNumber = role(cap, "Label", "STAGE 1", {
		Name = "Where",
		LayoutOrder = 2,
		Size = UDim2.fromScale(0, 1),
		AutomaticSize = Enum.AutomaticSize.X,
		TextColor3 = K.Cream,
	})
	ui.StageRuleR = new("Frame", { Name = "RuleR", BackgroundColor3 = K.Cyan, BackgroundTransparency = 0.2, BorderSizePixel = 0, Size = UDim2.fromOffset(18, 2), LayoutOrder = 3 }, cap)
	ui.StageGoal = role(face, "Body", "", {
		Name = "Goal",
		AnchorPoint = Vector2.new(0.5, 1),
		Position = UDim2.fromScale(0.5, 1),
		Size = UDim2.new(1, 0, 0.58, 0),
		TextXAlignment = Enum.TextXAlignment.Center,
		TextColor3 = K.CreamMuted,
		FontFace = Theme.Font.Heading,
		TextScaled = true,
	})
	new("UITextSizeConstraint", { MaxTextSize = TS(TY.Body.Size + 2), MinTextSize = 10 }, ui.StageGoal)
end

-- Previous boss bar (BossMaxHP > 0 without RunStage).
local function buildBoss(frame: Frame)
	local boss = new("Frame", { Name = "BossBar", BackgroundTransparency = 1, Visible = false }, frame)
	ui.Boss = boss
	-- a navy plate behind the name and bar so they read over any arena
	local plate = new("Frame", { Name = "Plate", BackgroundColor3 = K.Navy, BackgroundTransparency = K.PanelAlpha, BorderSizePixel = 0, Position = UDim2.fromOffset(-8, -4), Size = UDim2.new(1, 16, 0, 56) }, boss)
	UIKit.corner(plate, Theme.Radius.M)
	UIKit.stroke(plate, K.DangerDeep, 2, 0)
	ui.BossPlate = plate
	local bossTitle = new("Frame", { BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 24) }, boss)
	UIKit.list(bossTitle, {
		FillDirection = Enum.FillDirection.Horizontal,
		HorizontalAlignment = Enum.HorizontalAlignment.Center,
		VerticalAlignment = Enum.VerticalAlignment.Center,
		Padding = UDim.new(0, 8),
	})
	Icons.Draw(bossTitle, "skull", { Size = 20, Color = K.Danger, Back = K.Navy, LayoutOrder = 1 })
	ui.BossName = role(bossTitle, "Heading", "SCORPION QUEEN", {
		LayoutOrder = 2,
		Size = UDim2.fromOffset(0, 24),
		AutomaticSize = Enum.AutomaticSize.X,
		TextColor3 = K.Cream,
	})
	-- "FROST ARMOR" after the name while the Colossus is armoured (updateBoss)
	ui.BossArmour = role(bossTitle, "Caption", "FROST ARMOR", {
		LayoutOrder = 3,
		Size = UDim2.fromOffset(0, 24),
		AutomaticSize = Enum.AutomaticSize.X,
		TextColor3 = K.Cyan,
		Visible = false,
	})
	ui.BossMeter = UIKit.Meter(boss, {
		Gradient = Theme.Gradient.Boss,
		Trail = true,
		Position = UDim2.fromOffset(0, 28),
		Size = UDim2.new(1, 0, 0, 16),
	})
	ui.BossMeter.Frame.BackgroundColor3 = K.NavyDeep
	ui.BossMeter.Frame.BackgroundTransparency = 0
	ui.BossStroke = UIKit.stroke(ui.BossMeter.Frame, K.Danger, 1.5, 0.2)
	-- the ice band over the bar while the armour is on
	ui.BossIce = new("Frame", { Name = "Ice", BackgroundColor3 = P.ice_300, BackgroundTransparency = 0.55, BorderSizePixel = 0, Size = UDim2.fromScale(1, 1), ZIndex = 5, Visible = false }, ui.BossMeter.Frame)
	UIKit.corner(ui.BossIce, 999)
	new("UIGradient", { Rotation = 90, Transparency = NumberSequence.new({ NumberSequenceKeypoint.new(0, 0), NumberSequenceKeypoint.new(0.5, 0.35), NumberSequenceKeypoint.new(1, 0.1) }) }, ui.BossIce)
	-- phase marker (BossPhaseAt, e.g. 50%): a cream notch on the bar
	ui.BossMark = new("Frame", { Name = "PhaseMark", BackgroundColor3 = K.Cream, BorderSizePixel = 0, AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.new(0.5, 0, 0, 36), Size = UDim2.fromOffset(4, 22), ZIndex = 4, Visible = false }, boss)
	new("Frame", { BackgroundColor3 = K.Navy, BorderSizePixel = 0, AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.5), Size = UDim2.new(0, 1, 1, -4), ZIndex = 5 }, ui.BossMark)
	-- the boss's painted portrait (bosses/<BossId>) in a red-rimmed disc at the bar's left end;
	-- the bar starts after it. Hidden for a boss without a picture (setBossArt).
	local disc = new("Frame", { Name = "Portrait", BackgroundColor3 = K.NavyDeep, BackgroundTransparency = 0, BorderSizePixel = 0, AnchorPoint = Vector2.new(0, 0.5), Position = UDim2.new(0, 0, 0, 34), Size = UDim2.fromOffset(52, 52), ZIndex = 6, Visible = false }, boss)
	UIKit.corner(disc, 999)
	UIKit.stroke(disc, K.Danger, 2, 0.05)
	ui.BossSkull = Icons.Draw(disc, "skull", { Size = 26, Color = K.Danger, Back = K.NavyDeep, AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.5) })
	ui.BossDisc = disc
	ui.BossInset = 0
end

-- Top right: gold pill (the team's run gold), kills pill (both in ui.Counters, right-aligned),
-- pause button.
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
		TextColor3 = K.CreamMuted,
		Visible = false,
	})
	-- "+N" floaters drift into the pill (placed under it when they spawn)
	ui.PurseFloat = new("Frame", { Name = "PurseFloat", BackgroundTransparency = 1, Size = UDim2.fromOffset(1, 1), ZIndex = 5 }, frame)

	-- kills
	local kHolder, kFace = autoPill(counters, "Kills", PILL_H, Theme.Radius.M, 10, 14, 8)
	kHolder.LayoutOrder = 2
	local skull = Icons.Draw(kFace, "skull", { Size = 24, Color = K.Cream, Back = K.Navy, LayoutOrder = 1 })
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

	-- the menu button: a navy square, 50 px (the touch minimum is 48)
	local pHolder, pFace = goldSurface(frame, "Pause", Theme.Radius.M, UDim2.fromOffset(PAUSE, PAUSE))
	local pBtn = new("TextButton", { Name = "Hit", Text = "", AutoButtonColor = false, BackgroundTransparency = 1, Size = UDim2.fromScale(1, 1), ZIndex = 5, Selectable = true, Active = true }, pFace)
	UIKit.Focusable(pBtn)
	Icons.Draw(pFace, "pause", { Size = 24, Color = K.Cream, Back = K.Navy, AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.5) })
	pBtn.MouseEnter:Connect(function()
		pFace.BackgroundColor3 = K.NavyRaised
	end)
	pBtn.MouseLeave:Connect(function()
		pFace.BackgroundColor3 = K.Navy
	end)
	pBtn.Activated:Connect(function()
		if host.OnPause then
			host.OnPause()
		end
	end)
	ui.Pause = { Instance = pHolder, Button = pBtn }
end

-- The level medallion: a gold disc with the level-up chevrons.
local function medallion(parent: Instance, size: number, x: number): Frame
	local m = new("Frame", { Name = "Medallion", BackgroundColor3 = Color3.new(1, 1, 1), BorderSizePixel = 0, AnchorPoint = Vector2.new(0, 0.5), Position = UDim2.new(0, x, 0.5, 0), Size = UDim2.fromOffset(size, size) }, parent)
	UIKit.corner(m, 999)
	new("UIGradient", { Rotation = 90, Color = ColorSequence.new(K.Gold, K.GoldDeep) }, m)
	UIKit.stroke(m, K.Cream, 1.5, 0)
	Icons.Draw(m, "chevronsUp", { Size = math.floor(size * 0.6), Color = K.OnGold, Back = K.Gold, AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.5) })
	return m
end

-- Health + level plate. ui.Plate is the placed holder; its Body is drawn at full size. Desktop
-- and portrait show both rows; phone landscape shows health only and the level / XP row moves to
-- the bottom strip (placeXpRow).
local function buildVitals(frame: Frame)
	local holder = new("Frame", { Name = "Plate", BackgroundTransparency = 1, Active = false }, frame)
	ui.Plate = holder
	local body, face = goldSurface(holder, "Body", Theme.Radius.L, UDim2.fromOffset(VIT.W, VIT.H))
	ui.PlateBody = body
	ui.PlateFace = face
	ui.PlateFit = new("UIScale", { Name = "Fit", Scale = 1 }, body)

	local hpRow = new("Frame", { Name = "HP", BackgroundTransparency = 1, Position = UDim2.fromOffset(VIT.PadX, VIT.PadY), Size = UDim2.new(1, -2 * VIT.PadX, 0, VIT.HP) }, face)
	ui.HPRow = hpRow
	ui.Heart = Icons.Draw(hpRow, "heart", { Size = 24, Color = K.Health, Back = K.Navy, AnchorPoint = Vector2.new(0, 0.5), Position = UDim2.new(0, 1, 0.5, 0) })
	ui.HP = UIKit.Meter(hpRow, {
		Gradient = Theme.Gradient.Health,
		Trail = true,
		TextStyle = "Number",
		TextSize = TY.Number.Size,
		AnchorPoint = Vector2.new(0, 0.5),
		Position = UDim2.new(0, 34, 0.5, 0),
		Size = UDim2.new(1, -34, 1, 0),
	})
	ui.HP.Frame.BackgroundColor3 = K.NavyDeep
	ui.HP.Frame.BackgroundTransparency = 0
	UIKit.stroke(ui.HP.Frame, K.DangerDeep, 1.5, 0.1)

	-- Aegis Charm ward (player attribute Ward): a small gold shield pip on the heart's
	-- lower-right corner while the ward is up (refreshWard, attribute signal only)
	ui.WardPip = new("Frame", { Name = "WardPip", BackgroundColor3 = K.Gold, BorderSizePixel = 0, AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.new(0, 22, 0.5, 8), Size = UDim2.fromOffset(12, 12), ZIndex = 7, Visible = false }, hpRow)
	UIKit.corner(ui.WardPip, 999)
	UIKit.stroke(ui.WardPip, K.Cream, 1.5, 0)
	new("Frame", { BackgroundColor3 = K.Navy, BorderSizePixel = 0, AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.5), Size = UDim2.fromOffset(4, 4), ZIndex = 8 }, ui.WardPip)

	-- Guardian Ward shield: a steel band along the top of the health bar
	ui.ShieldBar = new("Frame", { Name = "Shield", BackgroundColor3 = K.Cyan, BorderSizePixel = 0, Size = UDim2.new(0, 0, 0, 4), Visible = false, ZIndex = 6 }, ui.HP.Frame)
	UIKit.corner(ui.ShieldBar, 2)

	local xpRow = new("Frame", { Name = "XP", BackgroundTransparency = 1, Position = UDim2.fromOffset(VIT.PadX, VIT.PadY + VIT.HP + VIT.Gap), Size = UDim2.new(1, -2 * VIT.PadX, 0, VIT.XP) }, face)
	ui.XPRow = xpRow
	ui.Medal = medallion(xpRow, 24, 1)
	ui.Level = role(xpRow, "Number", "LV 1", {
		Name = "Level",
		Position = UDim2.fromOffset(32, 0),
		Size = UDim2.new(0, 66, 1, 0),
		TextColor3 = K.Cream,
	})
	-- "LV 14" stays left of the XP bar (large phone text ran it under the bar)
	fitText(ui.Level, 10)
	ui.XP = UIKit.Meter(xpRow, {
		Gradient = XP_GRADIENT,
		TextStyle = "Number",
		TextSize = TY.Label.Size,
		AnchorPoint = Vector2.new(0, 0.5),
		Position = UDim2.new(0, 100, 0.5, 0),
		Size = UDim2.new(1, -100, 1, 0),
	})
	ui.XP.Frame.BackgroundColor3 = K.NavyDeep
	ui.XP.Frame.BackgroundTransparency = 0
	UIKit.stroke(ui.XP.Frame, XP_STROKE, 1.5, 0.1)

	-- bright leading edge on the XP fill (reads as the bar's "spark")
	local edge = new("Frame", { Name = "Edge", BackgroundColor3 = K.Cream, BackgroundTransparency = 0.55, BorderSizePixel = 0, AnchorPoint = Vector2.new(1, 0.5), Position = UDim2.fromScale(1, 0.5), Size = UDim2.new(0, 6, 1, 0), ZIndex = 3 }, ui.XP.Fill)
	UIKit.corner(edge, 999)
end

-- The bottom XP strip of a phone in landscape (the level / XP row lives here instead of the plate).
local function buildXpStrip(frame: Frame)
	local holder, face = goldSurface(frame, "XPStrip", Theme.Radius.M, UDim2.fromOffset(XP_STRIP.W, XP_STRIP.H))
	holder.Visible = false
	ui.XPStrip = holder
	ui.XPStripFace = face
end

-- Moves the level / XP row between the plate (desktop, portrait) and the bottom strip (phone
-- landscape). Cheap and only on a change of class.
local function placeXpRow(class: string)
	if anim.XpClass == class then
		return
	end
	anim.XpClass = class
	local row = ui.XPRow :: Frame
	if class == "phone" then
		row.Parent = ui.XPStripFace
		row.Position = UDim2.fromOffset(8, 3)
		row.Size = UDim2.new(1, -16, 1, -6)
		ui.XPStrip.Visible = true
	else
		row.Parent = ui.PlateFace
		row.Position = UDim2.fromOffset(VIT.PadX, VIT.PadY + VIT.HP + VIT.Gap)
		row.Size = UDim2.new(1, -2 * VIT.PadX, 0, VIT.XP)
		ui.XPStrip.Visible = false
	end
end

-- Icon key of an inventory weapon: its evolution once evolved.
local function weaponIconId(id: string, evolved: boolean): string
	local def = WeaponData.Weapons[id]
	if evolved and def and def.Evolution then
		return def.Evolution.Id
	end
	return id
end

-- "desktop" | "phone" (landscape, compact) | "portrait"
local function hudClass(): string
	if host.IsPortrait and host.IsPortrait() then
		return "portrait"
	end
	return UIKit.IsCompact() and "phone" or "desktop"
end

-- Equipment sizes for this device (tile, gaps): portrait fits the tiles to the width.
local function applyMetrics()
	local class = hudClass()
	local tile, gap, split, pad, build, pip
	if class == "desktop" then
		tile, gap, split, pad, build, pip = RunUI.TileDesktop, 6, 18, 8, 58, 7
	elseif class == "phone" then
		tile, gap, split, pad, build, pip = RunUI.TilePhone, 4, 12, 6, 52, 6
	else
		local v: Vector2 = host.VirtualSize()
		local avail = v.X - 2 * RunUI.Layout.MarginPhone
		pad, gap, split, build, pip = 6, 4, 10, 52, 5
		tile = math.clamp(math.floor((avail - 2 * pad - 6 * gap - split - build) / 8), 30, 46)
	end
	if INV.Tile ~= tile or INV.Gap ~= gap then
		anim.TilesStale = true
	end
	INV.Tile, INV.Gap, INV.Split, INV.Pad, INV.Build, INV.PipSize = tile, gap, split, pad, build, pip
	INV.Pips = pip + 4
end

-- Slots per row: what the Inventory payload says, else the brief's 4 + 4 (never fewer than
-- what is owned).
local function slotCounts(): (number, number)
	local ownedW = inventory and inventory.Weapons and #inventory.Weapons or 0
	local ownedP = inventory and inventory.Passives and #inventory.Passives or 0
	local capW = tonumber(inventory and inventory.WeaponSlots) or math.max(ownedW, RunUI.Slots.Weapons)
	local capP = tonumber(inventory and inventory.PassiveSlots) or math.max(ownedP, RunUI.Slots.Passives)
	return math.max(1, capW), math.max(1, capP)
end

local function rowWidth(n: number): number
	return n * INV.Tile + math.max(0, n - 1) * INV.Gap
end

local function invSize(): (number, number)
	local nW, nP = slotCounts()
	local w = INV.Pad * 2 + rowWidth(nW) + INV.Split + rowWidth(nP) + INV.Build
	local h = INV.Pad * 2 + INV.Tile + INV.Pips
	return w, h
end

-- Places the weapon row, the divider and the passive row side by side (one row).
local function placeRows()
	local nW, nP = slotCounts()
	local y = INV.Pad
	local rowH = INV.Tile + INV.Pips
	ui.WeaponRow.Position = UDim2.fromOffset(INV.Pad, y)
	ui.WeaponRow.Size = UDim2.fromOffset(rowWidth(nW), rowH)
	local sx = INV.Pad + rowWidth(nW) + math.floor(INV.Split / 2)
	ui.BarSplit.Position = UDim2.fromOffset(sx, y + 6)
	ui.BarSplit.Size = UDim2.fromOffset(2, INV.Tile - 12)
	ui.PassiveRow.Position = UDim2.fromOffset(INV.Pad + rowWidth(nW) + INV.Split, y)
	ui.PassiveRow.Size = UDim2.fromOffset(rowWidth(nP), rowH)
	if ui.BuildRule then
		ui.BuildRule.Position = UDim2.new(1, -(INV.Build - 4), 0, INV.Pad + 4)
		ui.BuildRule.Size = UDim2.new(0, 1, 1, -(2 * INV.Pad + 8))
	end
	if ui.BuildButton then
		ui.BuildButton.Size = UDim2.new(0, INV.Build - 10, 1, -(2 * INV.Pad - 2))
		if ui.BuildBase then
			ui.BuildBase.Size = ui.BuildButton.Size
		end
	end
end

local setBuildOpen: (boolean) -> ()
local relayout: () -> () = function() end

-- Equipment panel (bottom): "AbilityBar" (ClassHud finds it by this name) with the weapon row,
-- the passive row and, at its right end, the BUILD button that opens the inventory (also Tab / B /
-- gamepad Y; the run keeps going). The tiles stay non-Active (a thumb landing on them still moves
-- the hero); only the BUILD column takes input.
local function buildBar(frame: Frame)
	local holder = new("Frame", { Name = "AbilityBar", BackgroundTransparency = 1, Active = false }, frame)
	ui.Bar = holder
	local w, h = invSize()
	local body, face = goldSurface(holder, "Body", Theme.Radius.L, UDim2.fromOffset(w, h))
	ui.BarBody = body
	ui.BarFace = face
	ui.BarFit = new("UIScale", { Name = "Fit", Scale = 1 }, body)
	ui.WeaponRow = new("Frame", { Name = "Weapons", BackgroundTransparency = 1, Active = false }, face)
	UIKit.list(ui.WeaponRow, { FillDirection = Enum.FillDirection.Horizontal, VerticalAlignment = Enum.VerticalAlignment.Top, Padding = UDim.new(0, INV.Gap) })
	ui.BarSplit = new("Frame", { Name = "Split", BackgroundColor3 = K.NavyEdge, BackgroundTransparency = 0, BorderSizePixel = 0, Size = UDim2.fromOffset(2, INV.Tile - 12) }, face)

	ui.PassiveRow = new("Frame", { Name = "Passives", BackgroundTransparency = 1, Active = false }, face)
	UIKit.list(ui.PassiveRow, { FillDirection = Enum.FillDirection.Horizontal, VerticalAlignment = Enum.VerticalAlignment.Top, Padding = UDim.new(0, INV.Gap) })

	-- BUILD column: a divider and a button (chevron + the word + the Tab key on keyboards)
	ui.BuildRule = new("Frame", { Name = "BuildRule", BackgroundColor3 = K.NavyEdge, BackgroundTransparency = 0.4, BorderSizePixel = 0, AnchorPoint = Vector2.new(1, 0), Position = UDim2.new(1, -(INV.Build - 4), 0, INV.Pad + 4), Size = UDim2.new(0, 1, 1, -(2 * INV.Pad + 8)) }, face)
	ui.BuildBase = new("Frame", { Name = "BuildBase", BackgroundColor3 = K.Scrim, BorderSizePixel = 0, AnchorPoint = Vector2.new(1, 0.5), Position = UDim2.new(1, -INV.Pad, 0.5, 3), Size = UDim2.new(0, INV.Build - 10, 1, -12), ZIndex = 3, Active = false }, face)
	UIKit.corner(ui.BuildBase, Theme.Radius.M)
	local btn = new("TextButton", {
		Name = "BuildButton",
		Text = "",
		AutoButtonColor = false,
		BackgroundColor3 = K.NavyRaised,
		BackgroundTransparency = 0,
		BorderSizePixel = 0,
		AnchorPoint = Vector2.new(1, 0.5),
		Position = UDim2.new(1, -INV.Pad, 0.5, 0),
		Size = UDim2.new(0, INV.Build - 10, 1, -12),
		Selectable = true,
		ZIndex = 4,
	}, face)
	UIKit.corner(btn, Theme.Radius.M)
	ui.BuildStroke = UIKit.stroke(btn, K.Cyan, 2, 0.35)
	UIKit.Focusable(btn)
	ui.BuildButton = btn
	ui.BuildChevron = Icons.Draw(btn, "chevronsUp", { Size = 22, Color = K.Cyan, Back = K.NavyRaised, AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.new(0.5, 0, 0.5, -12), ZIndex = 5 })
	fitText(role(btn, "Label", "BUILD", {
		Name = "Word",
		AnchorPoint = Vector2.new(0.5, 0),
		Position = UDim2.new(0.5, 0, 0.5, 2),
		Size = UDim2.new(1, -6, 0, 20),
		TextXAlignment = Enum.TextXAlignment.Center,
		TextColor3 = K.Cream,
		ZIndex = 5,
	}), 9)
	-- the Tab key hint (keyboard only; touch and pads have the button itself)
	ui.BuildKey = fitText(role(btn, "Caption", "TAB", {
		Name = "Key",
		AnchorPoint = Vector2.new(0.5, 1),
		Position = UDim2.new(0.5, 0, 1, -2),
		Size = UDim2.new(1, -6, 0, 14),
		TextXAlignment = Enum.TextXAlignment.Center,
		TextColor3 = K.CreamMuted,
		ZIndex = 5,
		Visible = UserInputService.KeyboardEnabled and not UserInputService.TouchEnabled,
	}), 8)
	btn.MouseEnter:Connect(function()
		btn.BackgroundColor3 = K.NavyDeep
	end)
	btn.MouseLeave:Connect(function()
		btn.BackgroundColor3 = K.NavyRaised
	end)
	btn.Activated:Connect(function()
		setBuildOpen(not ui.BuildOpen)
	end)
	placeRows()
end

------------------------------------------------------------------------------------------
-- Build details (BUILD on the ability panel): what every owned weapon, passive and item
-- does, with its rank. A non-modal panel over the bottom of the arena (the run keeps
-- going; nothing pauses), closed by BUILD again, B / gamepad Y, its X, or any covering
-- overlay. Rebuilt only when it opens or the inventory / items change while open.
------------------------------------------------------------------------------------------

local runItems: { { Id: string, Count: number } } = {}
local BUILD_W = 600

-- A 48 px navy square button with a cream icon (the inventory's close button).
local function squareIconButton(parent: Instance, icon: string, name: string, props: { [string]: any }, onClick: () -> ()): Frame
	local holder, face = goldSurface(parent, name, Theme.Radius.M, UDim2.fromOffset(RunUI.Layout.TouchMin, RunUI.Layout.TouchMin))
	for k, v in pairs(props) do
		(holder :: any)[k] = v
	end
	local hit = new("TextButton", { Name = "Hit", Text = "", AutoButtonColor = false, BackgroundTransparency = 1, Size = UDim2.fromScale(1, 1), ZIndex = 5, Selectable = true, Active = true }, face)
	UIKit.Focusable(hit)
	Icons.Draw(face, icon, { Size = 22, Color = K.Cream, Back = K.Navy, AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.5) })
	hit.MouseEnter:Connect(function()
		face.BackgroundColor3 = K.NavyRaised
	end)
	hit.MouseLeave:Connect(function()
		face.BackgroundColor3 = K.Navy
	end)
	hit.Activated:Connect(onClick)
	return holder
end

local function buildDetails(frame: Frame)
	local holder, face = goldSurface(frame, "BuildDetails", Theme.Radius.L, UDim2.fromOffset(BUILD_W, 300))
	-- the inventory is a real panel (the player opened it on purpose): opaque navy
	face.BackgroundTransparency = 0
	holder.Visible = false
	holder.Active = true -- taps on the open panel do not walk the hero
	holder.AnchorPoint = Vector2.new(0.5, 1)
	ui.Build = holder
	ui.BuildFace = face
	UIKit.padding(face, 8, 12, 10, 12)
	-- the title (its width follows its text; the note beside it follows too)
	local titleH = TS(22) + 18
	local plate = new("Frame", { Name = "TitlePlate", BackgroundTransparency = 1, Size = UDim2.fromOffset(0, titleH), AutomaticSize = Enum.AutomaticSize.X, Active = false }, face)
	ui.BuildTitle = role(plate, "Title", "INVENTORY", { Name = "Title", Size = UDim2.fromOffset(0, titleH), AutomaticSize = Enum.AutomaticSize.X, TextColor3 = K.Gold })
	ui.BuildTitle.TextSize = TS(22)
	ui.BuildPlate = plate
	plate:GetPropertyChangedSignal("AbsoluteSize"):Connect(function()
		relayout()
	end)
	ui.BuildTitleH = titleH
	ui.BuildNote = role(face, "Caption", "The run continues while this is open", { Name = "Note", Position = UDim2.fromOffset(2, titleH + 6), Size = UDim2.new(1, -60, 0, 18), TextTruncate = Enum.TextTruncate.AtEnd, TextWrapped = true })
	ui.BuildClose = squareIconButton(face, "close", "Close", { AnchorPoint = Vector2.new(1, 0), Position = UDim2.new(1, 0, 0, 0) }, function()
		setBuildOpen(false)
	end)
	local listTop = titleH + 28
	local list = new("ScrollingFrame", {
		Name = "List",
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		Position = UDim2.fromOffset(0, listTop),
		Size = UDim2.new(1, 0, 1, -listTop),
		CanvasSize = UDim2.fromOffset(0, 0),
		AutomaticCanvasSize = Enum.AutomaticSize.Y,
		ScrollBarThickness = 5,
		ScrollBarImageColor3 = K.Cyan,
		ScrollingDirection = Enum.ScrollingDirection.Y,
		ElasticBehavior = Enum.ElasticBehavior.Never,
	}, face)
	UIKit.list(list, { Padding = UDim.new(0, 5) })
	UIKit.padding(list, 0, 8, 6, 0)
	ui.BuildList = list
	UIKit.ScrollHint(list)
end

--[[
	One row: an icon tile, the name, the rank (right, a word and a bar so colour is never the only
	carrier), the effective stat line and the description / requirement (muted). Both text lines wrap
	(the row grows with AutomaticSize), so a full description or a phone's narrow panel never cuts the
	text; the list scrolls. `frac` = rank progress 0..1 (nil: no bar, e.g. items); `gold` = maxed /
	evolved (gold rim); `ready` = an evolution ready to take (cyan rim).
]]
local function detailRow(parent: Instance, order: number, icon: string, name: string, rank: string, effect: string, gold: boolean, extra: string?, frac: number?, ready: boolean?)
	local row = new("Frame", { Name = "Row", BackgroundColor3 = K.NavyRaised, BorderSizePixel = 0, Size = UDim2.new(1, 0, 0, 58), AutomaticSize = Enum.AutomaticSize.Y, LayoutOrder = order }, parent)
	UIKit.corner(row, Theme.Radius.S)
	UIKit.stroke(row, ready and K.Cyan or (gold and K.Gold or K.NavyEdge), 2, 0)
	local tile = new("Frame", { Name = "IconTile", BackgroundColor3 = K.NavyDeep, BorderSizePixel = 0, Position = UDim2.fromOffset(8, 7), Size = UDim2.fromOffset(44, 44) }, row)
	UIKit.corner(tile, Theme.Radius.S)
	UIKit.stroke(tile, gold and K.Gold or K.NavyEdge, 1.5, 0)
	Icons.Upgrade(tile, icon, { Size = 36, Position = UDim2.fromOffset(4, 4), Back = K.NavyDeep })
	local rankW = frac and 128 or 150
	fitText(role(row, "Heading", name, { Name = "Name", Position = UDim2.fromOffset(60, 4), Size = UDim2.new(1, -(60 + rankW + 14), 0, 24) }), 11)
	fitText(role(row, frac and "Heading" or "Label", rank, { Name = "Rank", AnchorPoint = Vector2.new(1, 0), Position = UDim2.new(1, -10, 0, 4), Size = UDim2.fromOffset(rankW, 24), TextXAlignment = Enum.TextXAlignment.Right, TextColor3 = ready and K.Cyan or (gold and K.Gold or K.Cream) }), 10)

	if frac then
		local track = new("Frame", { Name = "Progress", BackgroundColor3 = K.NavyDeep, BorderSizePixel = 0, AnchorPoint = Vector2.new(1, 0), Position = UDim2.new(1, -10, 0, 33), Size = UDim2.fromOffset(rankW - 8, 8) }, row)
		UIKit.corner(track, 999)
		local fill = new("Frame", { Name = "Fill", BackgroundColor3 = gold and K.Gold or K.Cyan, BorderSizePixel = 0, Size = UDim2.fromScale(math.clamp(frac, 0.04, 1), 1) }, track)
		UIKit.corner(fill, 999)
	end
	local body = new("Frame", { Name = "Body", BackgroundTransparency = 1, Position = UDim2.fromOffset(60, 28), Size = UDim2.new(1, -(60 + (frac and rankW + 14 or 10)), 0, 0), AutomaticSize = Enum.AutomaticSize.Y }, row)
	UIKit.list(body, { Padding = UDim.new(0, 1) })
	UIKit.padding(body, 0, 0, 6, 0)
	role(body, "Label", effect, { Name = "Effect", Size = UDim2.new(1, 0, 0, 0), AutomaticSize = Enum.AutomaticSize.Y, TextWrapped = true, LayoutOrder = 1 })
	if extra and extra ~= "" and extra ~= effect then
		role(body, "Caption", extra, { Name = "Extra", Size = UDim2.new(1, 0, 0, 0), AutomaticSize = Enum.AutomaticSize.Y, TextWrapped = true, LayoutOrder = 2 })
	end
end

-- A section header: a dark band with the name and count ("WEAPONS  2 / 4").
local function detailHeader(parent: Instance, order: number, str: string, hint: string?)
	local band = new("Frame", { Name = "Section", BackgroundColor3 = K.NavyDeep, BorderSizePixel = 0, Size = UDim2.new(1, 0, 0, 30), LayoutOrder = order }, parent)
	UIKit.corner(band, Theme.Radius.S)
	UIKit.stroke(band, K.NavyEdge, 1.5, 0)
	role(band, "Heading", str, { Name = "Title", Position = UDim2.fromOffset(10, 0), Size = UDim2.new(1, -20, 1, 0), TextColor3 = K.Cream, TextTruncate = Enum.TextTruncate.AtEnd })
	if hint then
		role(band, "Caption", hint, { Name = "Hint", AnchorPoint = Vector2.new(1, 0), Position = UDim2.new(1, -10, 0, 0), Size = UDim2.new(0.4, 0, 1, 0), TextXAlignment = Enum.TextXAlignment.Right, TextColor3 = K.CreamMuted })
	end
end

local function trimNum(v: number): string
	if math.abs(v - math.floor(v + 0.5)) < 1e-6 then
		return tostring(math.floor(v + 0.5))
	end
	return (string.format("%.2f", v):gsub("0+$", ""):gsub("%.$", ""))
end

-- The item's rank and its ceiling. Rank-based entries ({Id, Rank, Evolved}) top out at
-- RunConfig.UI.MaxRank (5); older entries carry Level out of the data module's MaxLevel.
local function rankOf(entry, legacyMax: number): (number, number, boolean)
	local rank = tonumber(entry.Rank)
	if rank then
		return rank, tonumber(entry.MaxRank) or RunUI.MaxRank, true
	end
	return tonumber(entry.Level) or 1, tonumber(entry.MaxRank) or tonumber(entry.MaxLevel) or legacyMax, false
end

-- A weapon's key stats at its rank, before passives and items ("Damage 15 · Cooldown
-- 1.2 s · 2 swings"; the totem leads with its heal: "Heals 2 HP each second · ..."). When the
-- server sends the effective numbers (Damage, Interval, Range) those are shown instead.
local function weaponStatLine(wp): string
	local sent = {}
	if tonumber(wp.Damage) then
		table.insert(sent, "Damage " .. trimNum(wp.Damage))
	end
	if tonumber(wp.Interval) then
		table.insert(sent, string.format("every %s s", trimNum(wp.Interval)))
	end
	if tonumber(wp.Range) then
		table.insert(sent, string.format("range %s", trimNum(wp.Range)))
	end
	if #sent > 0 then
		return table.concat(sent, "  ·  ")
	end
	local def = WeaponData.Weapons[wp.Id]
	local rank = rankOf(wp, WeaponData.MaxLevel)
	local r = def and WeaponData.GetStats(wp.Id, math.min(rank, WeaponData.MaxLevel), wp.Evolved)
	if not def or not r then
		return ""
	end
	local use = WeaponData.StatUse[def.Behavior] or {}
	local parts = {}
	if def.Behavior == "Totem" and r.heal then
		local params = def.Params or {}
		local pulse = (wp.Evolved and params.EvoPulse) or params.Pulse or 1
		table.insert(parts, string.format("Heals %s HP %s", trimNum(r.heal), WeaponData.EveryText(pulse)))
	end
	table.insert(parts, "Damage " .. trimNum(r.damage))
	if use.cooldown then
		table.insert(parts, string.format("%s %s s", def.CooldownLabel or "Cooldown", trimNum(r.cooldown)))
	end
	local amount = WeaponData.CapAmount(wp.Id, r.amount or 1)
	if use.amount and amount >= 2 then
		table.insert(parts, string.format("%s %s", trimNum(amount), string.lower(def.AmountLabel or "Shots")))
	end
	return table.concat(parts, "  ·  ")
end

-- The known evolution requirement of a weapon: "Evolves into Bloodblade: Sword rank 5 + Heart rank
-- 3 (you: Heart rank 1)". Nothing for an evolved weapon or one without an evolution.
local function evolutionLine(wp, passives): string?
	local def = WeaponData.Weapons[wp.Id]
	if not def or not def.Evolution or wp.Evolved then
		return nil
	end
	local passiveId = tostring(wp.EvoPassive or def.Evolution.Passive or "")
	local pdef = PassiveData.Passives[passiveId]
	if passiveId == "" or not pdef then
		return nil
	end
	local need = tonumber(wp.EvoPassiveRank) or math.min(3, PassiveData.MaxLevelOf(passiveId))
	local have = 0
	for _, p in ipairs(passives) do
		if p.Id == passiveId then
			have = rankOf(p, PassiveData.MaxLevelOf(passiveId))
		end
	end
	local _, wmax = rankOf(wp, WeaponData.MaxLevel)
	return string.format(
		"Evolves into %s: %s rank %d + %s rank %d (%s)",
		def.Evolution.Name,
		def.Name,
		wmax,
		pdef.Name,
		need,
		have >= need and ("you have " .. pdef.Name .. " rank " .. have) or (have > 0 and ("you: " .. pdef.Name .. " rank " .. have) or ("you: no " .. pdef.Name))
	)
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
	local capW, capP = slotCounts()
	-- weapon numbers are the weapon's own (passives and items add on top)
	detailHeader(list, nextOrder(), string.format("WEAPONS  %d / %d", #weapons, capW), "base stats")
	for _, wp in ipairs(weapons) do
		local def = WeaponData.Weapons[wp.Id]
		local evo = wp.Evolved and def and def.Evolution
		local name = evo and evo.Name or (def and def.Name) or wp.Id
		local rank, max, ranked = rankOf(wp, WeaponData.MaxLevel)
		local word = ranked and "RANK" or "LV"
		local rankText = evo and "EVOLVED" or (rank >= max and string.format("MAX %d", rank) or string.format("%s %d / %d", word, rank, max))
		local about = (evo and evo.Description) or (def and def.Description) or ""
		local stats = weaponStatLine(wp)
		local evoLine = evolutionLine(wp, passives)
		local extra = evoLine and (evoLine .. (about ~= "" and stats ~= "" and ("\n" .. about) or "")) or (stats ~= "" and about or nil)
		detailRow(list, nextOrder(), weaponIconId(wp.Id, wp.Evolved), name, rankText, stats ~= "" and stats or about, wp.Evolved == true or rank >= max, extra, wp.Evolved and 1 or rank / math.max(1, max))
	end
	detailHeader(list, nextOrder(), string.format("PASSIVES  %d / %d", #passives, capP))
	for _, ps in ipairs(passives) do
		local def = PassiveData.Passives[ps.Id]
		local rank, max, ranked = rankOf(ps, PassiveData.MaxLevelOf(ps.Id))
		local word = ranked and "RANK" or "LV"
		local rankText = rank >= max and string.format("MAX %d", rank) or string.format("%s %d / %d", word, rank, max)
		-- the passive's whole effect at its level ("Deal 30% more damage with every weapon.")
		local total = PassiveData.TotalText(ps.Id, math.min(rank, PassiveData.MaxLevelOf(ps.Id))) or (def and def.Description) or ""
		if type(ps.Effect) == "string" and ps.Effect ~= "" then
			total = ps.Effect
		end
		detailRow(list, nextOrder(), ps.Id, (def and def.Name) or ps.Id, rankText, total, rank >= max, def and def.Note or nil, rank / math.max(1, max))
	end
	if EvolutionPreview.On() then
		-- EvolutionPreview (docs/next/EVOLUTION_PREVIEW.md): every evolution this build can
		-- reach, its recipe and what is still missing (WeaponData only; ready ones first)
		local slotsFree = #weapons < capW
		local evos = EvolutionPreview.List(weapons, passives, slotsFree)
		detailHeader(list, nextOrder(), #evos > 0 and string.format("EVOLUTIONS  %d", #evos) or "EVOLUTIONS  none in reach yet")
		for _, s in ipairs(evos) do
			local recipe = string.format("%s Lv %d + %s Lv %d", s.WeaponName, s.WeaponNeed, s.PassiveName, s.PassiveNeed)
			local met = (s.WeaponOk and 1 or 0) + (s.PassiveOk and 1 or 0)
			local status = s.Ready and "Ready! Look for the EVOLUTION card, or open a chest." or ("Missing: " .. tostring(s.Missing))
			detailRow(list, nextOrder(), s.EvoId, s.Name, s.Ready and "READY" or string.format("%d / 2", met), recipe, false, status, met / 2, s.Ready)
		end
	end
	local total = 0
	for _, it in ipairs(runItems) do
		total += it.Count
	end
	if total > 0 or #runItems == 0 then
		detailHeader(list, nextOrder(), total > 0 and string.format("ITEMS  %d", total) or "ITEMS  none yet")
	end
	for _, it in ipairs(runItems) do
		local def = ItemData.Items[it.Id]
		if def then
			local rarity = def.Rarity and string.upper(def.Rarity) or ""
			-- the full description (Desc), not just the short card line
			detailRow(list, nextOrder(), it.Id, def.Name, (it.Count > 1 and ("x" .. it.Count .. "  ") or "") .. rarity, def.Desc or def.Text or "", false)
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
	-- routine headlines wait while the inventory is open (critical ones still show)
	UIState.SetHold("Build", on)
	ui.BuildButton.BackgroundTransparency = 0
	ui.BuildStroke.Transparency = on and 0 or 0.35
	ui.BuildStroke.Thickness = on and 3 or 2
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
	local holder, face = RunWidgets.Panel(frame, { Name = "BuffChip", Radius = 999, Size = UDim2.fromOffset(0, 28) })
	holder.AutomaticSize = Enum.AutomaticSize.X
	face.AutomaticSize = Enum.AutomaticSize.X
	face.Size = UDim2.fromScale(0, 1)
	holder.Visible = false
	UIKit.padding(face, 0, 12, 0, 8)
	UIKit.list(face, { FillDirection = Enum.FillDirection.Horizontal, VerticalAlignment = Enum.VerticalAlignment.Center, Padding = UDim.new(0, 6) })
	ui.Buff = holder
	ui.BuffIcon = new("Frame", { BackgroundTransparency = 1, Size = UDim2.fromOffset(18, 18), LayoutOrder = 1 }, face)
	ui.BuffText = role(face, "Label", "", { LayoutOrder = 2, Size = UDim2.fromOffset(0, 28), AutomaticSize = Enum.AutomaticSize.X })
	ui.BuffStroke = face:FindFirstChildOfClass("UIStroke")
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
	Icons.Draw(ui.BuffIcon, "aim", { Size = 18, Color = (not state) and K.CreamFaint or K.Cyan, Back = K.Navy })
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
	ui.BuffText.TextColor3 = state and K.Good or K.CreamMuted
	ui.BuffStroke.Transparency = state and 0.1 or 0.75
	if state then
		UIAnim.Pop(ui.Buff, 0, 1.2)
	end
end

-- Stage banner: "STAGE 2" slams in over the arena for a moment (showStageBanner). It sits on
-- a white / blue plate with a royal blue rim (the HUD surfaces' look), so the title and
-- its line stay readable over bright grass and snow; layoutBanner sizes the inside.
local function buildBanner(frame: Frame)
	local box = new("Frame", { Name = "StageBanner", BackgroundTransparency = 1, AnchorPoint = Vector2.new(0.5, 0.5), Size = UDim2.fromOffset(520, 110), Visible = false, Active = false, ZIndex = 8 }, frame)
	ui.Banner = box
	local back = new("Frame", { Name = "Back", BackgroundColor3 = K.Navy, BackgroundTransparency = 1, BorderSizePixel = 0, Size = UDim2.fromScale(1, 1), ZIndex = 8 }, box)
	UIKit.corner(back, Theme.Radius.L)
	ui.BannerBack = back
	ui.BannerEdge = UIKit.stroke(back, K.NavyEdge, 2, 1)
	ui.BannerTitle = role(box, "Display", "STAGE 1", {
		Name = "Title",
		AnchorPoint = Vector2.new(0.5, 0),
		Position = UDim2.new(0.5, 0, 0, 6),
		Size = UDim2.new(1, -24, 0, TS(TY.Display.Size) + 6),
		TextXAlignment = Enum.TextXAlignment.Center,
		TextColor3 = K.Gold,
		TextStrokeTransparency = 1,
		TextScaled = true, -- long titles ("THE SWARM IS OVERWHELMING") shrink to fit phones
		ZIndex = 9,
	})
	new("UITextSizeConstraint", { MaxTextSize = TS(TY.Display.Size), MinTextSize = 14 }, ui.BannerTitle)
	ui.BannerLine = new("Frame", { Name = "Line", BackgroundColor3 = K.Gold, BorderSizePixel = 0, AnchorPoint = Vector2.new(0.5, 0), Position = UDim2.new(0.5, 0, 0, TS(TY.Display.Size) + 10), Size = UDim2.fromOffset(0, 3), ZIndex = 9 }, box)
	UIKit.corner(ui.BannerLine, 2)
	ui.BannerSub = role(box, "Body", "", {
		Name = "Sub",
		AnchorPoint = Vector2.new(0.5, 0),
		Position = UDim2.new(0.5, 0, 0, TS(TY.Display.Size) + 18),
		Size = UDim2.new(1, -24, 0, TS(TY.Body.Size) + 4),
		TextXAlignment = Enum.TextXAlignment.Center,
		TextColor3 = K.CreamMuted,
		TextStrokeTransparency = 1,
		TextScaled = true,
		ZIndex = 9,
	})
	new("UITextSizeConstraint", { MaxTextSize = TS(TY.Body.Size), MinTextSize = 11 }, ui.BannerSub)
end

-- The banner's inside for one layout: title, gold rule and sub line on the plate. Compact
-- (phones) uses a shorter plate so the lane under the top stack leaves room for the world
-- (and an open merchant panel under it). Returns the plate height.
local function layoutBanner(width: number, compact: boolean): number
	local titleH = compact and 32 or (TS(TY.Display.Size) + 6)
	local subH = compact and 18 or (TS(TY.Body.Size) + 4)
	local h = 6 + titleH + 9 + subH + 7
	ui.Banner.Size = UDim2.fromOffset(math.floor(width), h)
	ui.BannerTitle.Size = UDim2.new(1, -24, 0, titleH)
	local fit = ui.BannerTitle:FindFirstChildOfClass("UITextSizeConstraint")
	if fit then
		fit.MaxTextSize = compact and 30 or TS(TY.Display.Size)
	end
	ui.BannerLine.Position = UDim2.new(0.5, 0, 0, 6 + titleH + 3)
	ui.BannerSub.Position = UDim2.new(0.5, 0, 0, 6 + titleH + 9)
	ui.BannerSub.Size = UDim2.new(1, -24, 0, subH)
	ui.BannerLineW = math.floor(math.min(260, width - 80))
	return h
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
	-- a caller's colour (portal blue, crimson threat...) is the accent: the line and rim use it
	-- as given, the title a lighter shade of it so it reads on the navy plate
	local ink = K.Gold
	if color then
		local lum = 0.299 * color.R + 0.587 * color.G + 0.114 * color.B
		ink = color:Lerp(K.Cream, lum > 0.55 and 0.2 or 0.55)
	end
	title.TextColor3 = ink
	line.BackgroundColor3 = color or K.Gold
	sub.Text = goal
	title.TextTransparency = 1
	sub.TextTransparency = 1
	line.Size = UDim2.fromOffset(0, 3)
	line.BackgroundTransparency = 0
	local back, edge = ui.BannerBack :: Frame, ui.BannerEdge :: UIStroke
	back.BackgroundTransparency, edge.Transparency = 1, 1
	edge.Color = color or K.NavyEdge
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
	tw(title, 0.25, { TextTransparency = 0 })
	tw(back, 0.2, { BackgroundTransparency = 0.04 })
	tw(edge, 0.2, { Transparency = 0 })
	local lineW = ui.BannerLineW or 260
	if reduced then
		line.Size = UDim2.fromOffset(lineW, 3)
	else
		local at = UDim2.new(0.5, 0, 0, TS(TY.Display.Size) / 2)
		UIAnim.Sparks(box, at, K.Gold, 10, 120, 0.6)
		UIAnim.Ring(box, at, K.Cyan, 220, 0.5)
		task.delay(0.1, function()
			if token == bannerToken then
				tw(line, 0.45, { Size = UDim2.fromOffset(lineW, 3) }, Enum.EasingStyle.Quint)
			end
		end)
	end
	task.delay(reduced and 0 or 0.25, function()
		if token == bannerToken then
			tw(sub, 0.3, { TextTransparency = 0 })
		end
	end)
	task.delay(1.5, function()
		if token ~= bannerToken then
			return
		end
		tw(title, 0.4, { TextTransparency = 1 })
		tw(sub, 0.4, { TextTransparency = 1 })
		tw(line, 0.4, { BackgroundTransparency = 1 })
		tw(back, 0.4, { BackgroundTransparency = 1 })
		tw(edge, 0.4, { Transparency = 1 })
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
	local holder, face = RunWidgets.Panel(frame, { Name = "Status", Radius = 24, Visible = false })
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
		Gradient = ColorSequence.new(K.Cyan, K.CyanDeep),
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

-- Sizes other pieces (the minimap, the party stack) report for the shared run layout.
local pieceSizes: { [string]: { W: number, H: number } } = {}
local runRects: RunLayout.Layout = {}
local layoutHooks: { (RunLayout.Layout) -> () } = {}

local function overtimeNow(): boolean
	return ui.Overtime == true
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
	local scale = math.max(0.01, host.Scale())
	local class = hudClass()
	applyMetrics()
	if anim.TilesStale and inventory then
		Hud.SetInventory(inventory) -- the tiles changed size: rebuild them (this calls layout again)
		return
	end
	placeXpRow(class)

	-- the shared layout env (RunLayout): safe-area size, top-bar insets, device class, touch
	local env: RunLayout.Env = {
		W = W,
		H = H,
		Insets = ins,
		Phone = compact,
		Portrait = portrait,
		Touch = UserInputService.TouchEnabled,
		Scale = scale,
		Mirror = ClientSettings.Get("TouchLayout") == "LeftHanded",
	}
	local cfg = RunUI.Layout
	local margin = if compact then cfg.MarginPhone else cfg.MarginDesktop

	-- piece sizes (design px)
	local timerW, timerH = compact and 108 or TIMER_W, compact and 40 or TIMER_H
	if overtimeNow() then
		timerW += OVERTIME_EXTRA
	end
	local countersW = ui.Counters.AbsoluteSize.X / scale
	local cluster = { W = countersW + 8 + PAUSE, H = PAUSE }
	-- health plate: both rows on desktop / portrait (fitted down on a narrow screen), health only on a phone in landscape
	local healthW, healthH, plateK = VIT.W, VIT.H, 1
	if class == "phone" then
		healthW, healthH = VIT_PHONE.W, VIT_PHONE.H
	else
		plateK = math.min(1, (W - 2 * margin) / VIT.W)
		healthW, healthH = VIT.W * plateK, VIT.H * plateK
	end
	local newFlow = ui.RunFlow == true
	local objShown = newFlow or (ui.Stage.Visible and not newFlow)
	local objW, objH
	if newFlow then
		objW, objH = RunObjective.StripSize(compact and 360 or 420, compact)
	else
		objH = compact and 48 or OBJ_H
		objW = portrait and math.min(OBJ_W + 40, W - 2 * margin) or OBJ_W
	end
	local bossShown, bossW, bossH = false, 0, 0
	if newFlow then
		local _, shown = RunObjective.Shown()
		bossShown = shown
		bossW, bossH = RunObjective.BossSize(compact and 440 or 520)
	elseif ui.Boss.Visible then
		bossShown, bossW, bossH = true, math.min(560, W - 2 * margin), 46
	end
	local invW, invH = invSize()
	-- the equipment panel shrinks (UIScale) rather than overflow the room between the thumbs
	local touchRects = env.Touch and RunLayout.Thumbs(env, cfg) or nil
	local lo, hi = margin, W - margin
	if touchRects and not portrait then
		lo, hi = RunLayout.BottomBand(env, touchRects, cfg.Gap, margin)
	end
	local k = math.min(1, (hi - lo) / invW)
	if portrait then
		k = math.min(1, (W - 2 * margin) / invW)
	end
	local sizes: RunLayout.Sizes = {
		Health = { W = healthW, H = healthH },
		Timer = { W = timerW, H = timerH },
		Objective = objShown and { W = objW, H = objH } or nil,
		Boss = bossShown and { W = bossW, H = bossH } or nil,
		Counters = cluster,
		Map = pieceSizes.Map or { W = compact and 128 or 180, H = compact and 150 or 210 },
		Party = pieceSizes.Party,
		Equipment = { W = invW * k, H = invH * k },
		XpStrip = class == "phone" and { W = math.min(XP_STRIP.W, hi - lo), H = XP_STRIP.H } or nil,
	}
	local rects = RunLayout.Compute(env, sizes, cfg)
	runRects = rects

	-- utility group (top right): gold / kills pills + the menu button
	local cr = rects.Counters
	place(ui.Pause.Instance, cr.X + cr.W - PAUSE, cr.Y, PAUSE, PAUSE)
	ui.Counters.Position = UDim2.fromOffset(math.floor(cr.X + cr.W - PAUSE - 8 + 0.5), math.floor(cr.Y + (PAUSE - PILL_H) / 2 + 0.5))

	-- timer (top centre)
	local tr = rects.Timer
	place(ui.TimerPill, tr.X, tr.Y, tr.W, tr.H)
	if overtimeNow() then
		ui.OvertimeTag.Visible = true
		ui.Timer.Position = UDim2.fromOffset(OVERTIME_EXTRA, 0)
		ui.Timer.Size = UDim2.new(1, -OVERTIME_EXTRA - 6, 1, 0)
	else
		ui.OvertimeTag.Visible = false
		ui.Timer.Position = UDim2.new()
		ui.Timer.Size = UDim2.fromScale(1, 1)
	end

	-- health plate; the item strip + chips + popups (LootUI) start under it
	local hr = rects.Health
	ui.PlateBody.Size = UDim2.fromOffset(class == "phone" and VIT_PHONE.W or VIT.W, class == "phone" and VIT_PHONE.H or VIT.H)
	ui.PlateFit.Scale = plateK
	place(ui.Plate, hr.X, hr.Y, 0, 0)
	ui.Plate.Visible = true
	ui.XPStrip.Visible = class == "phone"
	if class == "phone" then
		ui.HPRow.Position = UDim2.fromOffset(VIT_PHONE.PadX, VIT_PHONE.PadY)
		ui.HPRow.Size = UDim2.new(1, -2 * VIT_PHONE.PadX, 1, -2 * VIT_PHONE.PadY)
		local xr = rects.XpStrip
		if xr then
			place(ui.XPStrip, xr.X, xr.Y, xr.W, xr.H)
		end
	else
		ui.HPRow.Position = UDim2.fromOffset(VIT.PadX, VIT.PadY)
		ui.HPRow.Size = UDim2.new(1, -2 * VIT.PadX, 0, VIT.HP)
	end
	if portrait then
		ui.LeftBottom = nil
		ui.LeftWidth = nil
	else
		ui.LeftBottom = hr.Y + hr.H + 6
		ui.LeftWidth = compact and 240 or 300
	end

	-- previous stage objective (Stage / StagePhase flow) or the new strip (RunStage flow)
	local objRect, bossRect = rects.Objective, rects.Boss
	ui.StageRoom = objW
	if newFlow then
		RunObjective.Place(objRect, bossRect)
	else
		if objRect then
			ui.Stage.AnchorPoint = Vector2.new(0.5, 0)
			ui.Stage.Position = UDim2.fromOffset(math.floor(objRect.X + objRect.W / 2 + 0.5), math.floor(objRect.Y + 0.5))
			ui.Stage.Size = UDim2.fromOffset(math.floor(objRect.W), math.floor(objRect.H))
		end
		if bossRect then
			place(ui.Boss, bossRect.X, bossRect.Y + 4, bossRect.W, 46)
		end
	end
	local topBottom = rects.TopBottom.Y
	if not newFlow and bossRect then
		topBottom = bossRect.Y + 62
	end
	ui.TopBottom = topBottom

	-- equipment (weapons | passives): bottom row, above the XP strip on a phone
	local er = rects.Equipment
	ui.BarBody.Size = UDim2.fromOffset(invW, invH)
	placeRows()
	ui.BarFit.Scale = k
	place(ui.Bar, er.X, er.Y, invW * k, invH * k)
	local barW, barH = invW * k, invH * k
	local clusterTop, clusterBottom = er.Y, er.Y + barH
	ui.BarTop = clusterTop
	ui.BarBottom = clusterBottom
	if ui.Buff then
		if portrait then
			ui.Buff.AnchorPoint = Vector2.new(0.5, 0)
			ui.Buff.Position = UDim2.fromOffset(math.floor(er.X + barW / 2), clusterBottom + 6)
		else
			ui.Buff.AnchorPoint = Vector2.new(0.5, 1)
			ui.Buff.Position = UDim2.fromOffset(math.floor(er.X + barW / 2), clusterTop - 6)
		end
	end

	-- inventory panel: over the arena right above the equipment (landscape) or under it
	-- (portrait), never under the top cluster
	if ui.Build then
		local bw = math.min(BUILD_W, W - 2 * margin)
		if portrait then
			local top = clusterBottom + 8
			ui.Build.AnchorPoint = Vector2.new(0.5, 0)
			ui.Build.Position = UDim2.fromOffset(math.floor(W / 2), math.floor(top))
			ui.Build.Size = UDim2.fromOffset(math.floor(bw), math.floor(math.clamp(H - top - margin - 140, 160, 460)))
		else
			-- centred over the open middle of the arena: under the wave banner's lane, above the
			-- equipment; on a short phone it starts under the top stack instead (the panel then
			-- covers the lane, never the other way round: it sits in a higher layer)
			local bottom = clusterTop - 8
			local top = math.max(topBottom, ui.LaneBottom or topBottom) + 6
			if bottom - top < 190 then
				top = topBottom + 4
			end
			local bh = math.floor(math.clamp(bottom - top, 150, 420))
			ui.Build.AnchorPoint = Vector2.new(0.5, 0.5)
			ui.Build.Position = UDim2.fromOffset(math.floor(W / 2), math.floor(top + (bottom - top) / 2))
			ui.Build.Size = UDim2.fromOffset(math.floor(bw), bh)
		end
		local face = ui.BuildFace :: Frame
		face.Size = UDim2.fromScale(1, 1)
		-- the status note under the title, or beside it on a short screen (the list gets that
		-- row back); it wraps to two lines there rather than being cut
		local titleH = ui.BuildTitleH or 40
		local plateW = math.floor(ui.BuildPlate.AbsoluteSize.X / scale + 0.5)
		local besideW = math.floor(bw) - 24 - plateW - 12 - 56
		local beside = H < 500 and plateW > 0 and besideW >= 150
		if beside then
			ui.BuildNote.Position = UDim2.fromOffset(plateW + 12, math.floor((titleH - 32) / 2))
			ui.BuildNote.Size = UDim2.fromOffset(besideW, 32)
		else
			ui.BuildNote.Position = UDim2.fromOffset(2, titleH + 6)
			ui.BuildNote.Size = UDim2.new(1, -60, 0, 18)
		end
		local listTop = beside and (titleH + 10) or (titleH + 28)
		ui.BuildList.Position = UDim2.fromOffset(0, listTop)
		ui.BuildList.Size = UDim2.new(1, 0, 1, -listTop)
	end

	-- stage banner: landscape: its own lane right under the top-centre stack (timer, objective,
	-- boss bar), so it never covers them and an open merchant panel sits under it
	-- (Hud.BannerLane); portrait: mid-screen, under the stacked top panels
	local bannerH = layoutBanner(math.min(compact and 440 or 520, W - 2 * margin), compact)
	local laneTop = topBottom + 6
	ui.LaneTop, ui.LaneBottom = laneTop, laneTop + bannerH
	bannerBaseY = math.floor(portrait and H * 0.5 or (laneTop + bannerH / 2))
	bannerPortrait = portrait
	ui.Banner.Position = UDim2.fromOffset(math.floor(W / 2), bannerBaseY)
	placeBanner()

	-- status line: centre-low in landscape, below the panels in portrait
	local statusW = math.min(640, W - 2 * margin)
	ui.Status.Size = UDim2.fromOffset(statusW, compact and 58 or 50)
	if portrait then
		ui.Status.Position = UDim2.fromOffset(W / 2, clusterBottom + 40)
	else
		ui.Status.Position = UDim2.fromOffset(W / 2, math.min(H * 0.66, clusterTop - 44))
	end
	statusBaseY = ui.Status.Position.Y.Offset
	statusPortrait = portrait
	placeStatus()
	-- the minimap, party stack and interact prompt follow this layout
	for _, fn in ipairs(layoutHooks) do
		local ok, err = pcall(fn, rects)
		if not ok then
			warn("[Hud] layout hook: " .. tostring(err))
		end
	end
end
Hud.Layout = layout
relayout = layout

-- A piece placed by another module (MiniMap, TeamUI) reports its size so the shared layout can
-- keep everything clear of it; the layout runs again when the size changed.
function Hud.SetPieceSize(name: string, w: number, h: number)
	local cur = pieceSizes[name]
	if w <= 0 then
		if cur == nil then
			return
		end
		pieceSizes[name] = nil
	else
		if cur and cur.W == w and cur.H == h then
			return
		end
		pieceSizes[name] = { W = w, H = h }
	end
	if ui.Frame then
		layout()
	end
end

-- The rectangle (design px) the run layout gave a named piece: Health, Timer, Objective, Boss,
-- Counters, Map, Party, Equipment, XpStrip, Stick, Jump, Dash. nil when the piece does not exist
-- on this device or before the first layout.
function Hud.RunRect(name: string): RunLayout.Rect?
	return runRects[name]
end

-- fn(rects) runs after every layout (the minimap and the party stack move into their spots).
function Hud.OnLayout(fn: (RunLayout.Layout) -> ())
	table.insert(layoutHooks, fn)
end

------------------------------------------------------------------------------------------
-- Equipment rows (weapons | passives)
------------------------------------------------------------------------------------------

--[[
	One equipment tile: a navy square with the item art, a round gold rank number in the
	bottom-right corner, an evolution mark (a ringed gold disc) at the top-left once evolved, a gold
	rim once evolved / maxed, and `max` rank pips underneath (filled up to the rank). An empty slot
	is a faint outline with a "+". Not Active (touches pass through to the thumbstick).
]]
local function hudTile(parent: Instance, id: string?, rank: number?, max: number?, evolved: boolean?): Frame
	local size = INV.Tile
	local empty = id == nil
	local outer = new("Frame", {
		Name = empty and "Empty" or "Tile",
		Size = UDim2.fromOffset(size, size + INV.Pips),
		BackgroundTransparency = 1,
		Active = false,
	})
	local gold = evolved == true or (rank ~= nil and max ~= nil and rank >= max)
	local art = new("Frame", {
		Name = "Art",
		Size = UDim2.fromOffset(size, size),
		BackgroundColor3 = empty and K.NavyDeep or K.NavyRaised,
		BackgroundTransparency = empty and 0.3 or 0,
		BorderSizePixel = 0,
		Active = false,
	}, outer)
	UIKit.corner(art, math.floor(size * 0.18))
	UIKit.stroke(art, gold and K.Gold or K.NavyEdge, gold and 3 or 2, empty and 0.4 or 0)
	if empty then
		-- a quiet "+" says the slot can still be filled
		new("TextLabel", {
			Name = "Plus",
			BackgroundTransparency = 1,
			Size = UDim2.fromScale(1, 1),
			Text = "+",
			FontFace = TY.Number.Font,
			TextSize = math.floor(size * 0.42),
			TextColor3 = K.CreamFaint,
			TextTransparency = 0.2,
			Active = false,
		}, art)
	else
		local inset = math.floor(size * 0.08)
		Icons.Upgrade(art, id, { Size = size - inset * 2, Position = UDim2.fromOffset(inset, inset), Back = K.NavyRaised, Name = "Icon" })
		if rank and rank > 0 then
			local d = math.max(16, math.floor(size * 0.36))
			local badge = new("TextLabel", {
				Name = "Badge",
				AnchorPoint = Vector2.new(0.5, 0.5),
				Position = UDim2.new(1, -math.floor(d * 0.3), 1, -math.floor(d * 0.3)),
				Size = UDim2.fromOffset(d, d),
				BackgroundColor3 = gold and K.Gold or K.Cream,
				BorderSizePixel = 0,
				Text = tostring(rank),
				FontFace = TY.Number.Font,
				TextSize = math.floor(d * 0.72),
				TextColor3 = K.OnGold,
				ZIndex = 5,
				Active = false,
			}, art)
			UIKit.corner(badge, 999)
			UIKit.stroke(badge, K.Navy, 1.5, 0)
		end
		if evolved then
			-- the evolution mark: the ringed gold disc, a second carrier besides the rim
			local mark = RunWidgets.RaritySymbol(art, "Evolution", math.max(14, math.floor(size * 0.3)))
			mark.Name = "EvolutionMark"
			mark.Position = UDim2.fromOffset(3, 3)
			mark.ZIndex = 6
			for _, d in ipairs(mark:GetChildren()) do
				if d:IsA("GuiObject") then
					d.ZIndex = 6
				end
			end
		end
		-- rank pips, 1..max (never wider than the tile)
		local n = math.max(1, math.floor(max or RunUI.MaxRank))
		local ps = math.clamp(math.floor((size - (n - 1) * 2) / n), 3, INV.PipSize)
		local pips = RunWidgets.Pips(outer, { Size = ps, Gap = 2, Position = UDim2.fromOffset(0, size + 3) })
		pips.Set(rank or 0, n, gold)
	end
	outer.Parent = parent
	return outer
end

-- Shine sweep inside the tile's rounded shape, plus sparks (new) or a flash (level up).
local function tileShine(tile: GuiObject, isNew: boolean)
	if (ClientSettings.Reduced() or ClientPerformance.Reduced()) then
		return
	end
	local art = tile:FindFirstChild("Art") :: GuiObject?
	if not art then
		return
	end
	local clip = new("Frame", { Name = "ShineClip", BackgroundTransparency = 1, Size = UDim2.fromScale(1, 1), ClipsDescendants = true, ZIndex = 4 }, art)
	local corner = art:FindFirstChildWhichIsA("UICorner")
	if corner then
		corner:Clone().Parent = clip
	end
	UIAnim.SweepOnce(clip, K.Cream, 0.5, 0.2)
	if isNew then
		UIAnim.Sparks(art, UDim2.fromScale(0.5, 0.5), K.Gold, 8, 36, 0.5)
		UIAnim.Ring(art, UDim2.fromScale(0.5, 0.5), K.Cyan, 70, 0.45)
	else
		UIAnim.Flash(art, K.Gold)
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
	applyMetrics()
	anim.TilesStale = false
	local w, h = invSize()
	ui.BarBody.Size = UDim2.fromOffset(w, h)
	placeRows()
	layout()
	-- tiles that are new or just ranked up pop in
	local function popIfChanged(tile: GuiObject, key: string, rank: number)
		if shownLevels[key] ~= rank then
			local isNew = shownLevels[key] == nil
			UIAnim.Pop(tile, 0, isNew and 0.3 or 1.35)
			shownLevels[key] = rank
			-- the very first SetInventory of a run just fills the bar; only later changes shine
			if anim.BarReady then
				tileShine(tile, isNew)
			end
		end
	end
	local capW, capP = slotCounts()
	for i = 1, capW do
		local wp = inv.Weapons[i]
		local tile
		if wp then
			local rank, max = rankOf(wp, WeaponData.MaxLevel)
			tile = hudTile(ui.WeaponRow, weaponIconId(wp.Id, wp.Evolved), rank, max, wp.Evolved == true)
			popIfChanged(tile, "W" .. wp.Id, rank + (wp.Evolved and 10 or 0))
		else
			tile = hudTile(ui.WeaponRow)
		end
		tile.LayoutOrder = i
	end
	for i = 1, capP do
		local p = inv.Passives[i]
		local tile
		if p then
			local rank, max = rankOf(p, PassiveData.MaxLevelOf(p.Id))
			tile = hudTile(ui.PassiveRow, p.Id, rank, max, false)
			popIfChanged(tile, "P" .. p.Id, rank)
		else
			tile = hudTile(ui.PassiveRow)
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
		UIAnim.Flash(ui.HP.Frame, K.Cream)
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
			Icons.Draw(ui.StatusIconHolder, icon, { Size = 22, Color = K.Cyan, Back = K.Navy })
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
		TextColor3 = K.Gold,
		TextStrokeColor3 = K.Scrim,
		TextStrokeTransparency = 0.2,
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
		purse.Need = math.max(0, price - Hud.Gold())
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

-- The balance the gold pill shows: the team's run gold (SwarmState TeamRunGold, one balance for
-- everyone) once the server sets it, else this player's run gold.
local function goldNow(): number
	local team = Remotes.State():GetAttribute("TeamRunGold")
	if type(team) == "number" then
		return team
	end
	return tonumber(player:GetAttribute("RunGold")) or 0
end
Hud.Gold = goldNow

updatePurse = function(dt: number)
	local gold = goldNow()
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
				UIAnim.Sparks(ui.PurseCoin, UDim2.fromScale(0.5, 0.5), C.Coin, 5, 26, 0.45)
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
	local hint, hintColor = "", K.CreamMuted
	if alarm then
		hint, hintColor = "NEED " .. UIKit.formatNumber(math.max(1, purse.Need)), K.Danger
	elseif purse.Price > 0 then
		if purse.Afford then
			-- the price in reach ("140 / 34" read like a fraction of a total)
			hint, hintColor = "COST " .. UIKit.formatNumber(purse.Price), K.Good
		else
			hint, hintColor = "NEED " .. UIKit.formatNumber(purse.Price - gold), K.Danger
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
		ui.PurseValue.TextColor3 = red and K.Danger or K.Cream
		if ui.PurseStroke then
			ui.PurseStroke.Color = red and K.Danger or K.NavyEdge
			ui.PurseStroke.Transparency = 0
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
			-- this hero in the ring: keep standing; a teammate charging it: the progress
			local pos = state:GetAttribute("PortalPos")
			local char = player.Character
			local root = char and char.PrimaryPart
			local inside = false
			if typeof(pos) == "Vector3" and root and player:GetAttribute("Alive") ~= false then
				local d = Vector3.new(pos.X - root.Position.X, 0, pos.Z - root.Position.Z)
				inside = d.Magnitude <= Config.Stages.PortalRadius
			end
			local pct = math.floor(chargeNow * 100)
			return inside and string.format("Stay in the ring · summoning %d%%", pct) or string.format("Summoning the boss · %d%%", pct), waveText, K.Cyan
		elseif lockLeft > 0 then
			return "Portal dormant · " .. UIKit.formatTime(lockLeft), waveText, K.CreamMuted
		end
		-- before the reveal (SwarmState PortalHint) there is nothing to find yet: no arrow,
		-- no beacon (the tutorial run waits for the first upgrade pick)
		if state:GetAttribute("PortalHint") ~= true then
			return "Survive until the portal opens", waveText, K.CreamMuted
		end
		-- swarm pressure (SwarmState SwarmWarn): the objective turns into a warning
		local warn = state:GetAttribute("SwarmWarn") or 0
		if warn >= 2 then
			return "Open the portal · swarm overwhelming", waveText, K.Danger
		elseif warn >= 1 then
			return "Open the portal · swarm growing", waveText, K.Warn
		end
		return "Reach the portal", waveText, K.CreamMuted
	elseif stagePhase == "Boss" then
		return "Defeat the " .. tostring(state:GetAttribute("BossName") or state:GetAttribute("StageBoss") or "Queen"), waveText, K.Danger
	elseif stagePhase == "Surge" then
		local left = state:GetAttribute("SurgeLeft") or 0
		return left > 0 and ("Survive the surge · " .. UIKit.formatTime(left)) or "Survive the surge", waveText, K.Danger
	elseif stagePhase == "Open" then
		return "Portal open · step in", "", K.Gold
	elseif stagePhase == "Travel" then
		return "Traveling", "", K.CreamMuted
	end
	return "", "", K.CreamMuted
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
				glow(ui.Stage, K.Danger)
			end
			if anim.StagePhase ~= stagePhase and anim.StagePhase ~= nil then
				UIAnim.Punch(ui.Stage, 0.2)
				glow(ui.Stage, (stagePhase == "Surge" or stagePhase == "Boss") and K.Danger or K.Cyan)
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
		UIAnim.SweepOnce(ui.HP.Frame, K.Good, 0.5, 0.35)
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
			flash.Color = ColorSequence.new(K.Cream)
			task.delay(0.25, function()
				flash.Color = XP_GRADIENT
			end)
		end
		UIAnim.Punch(ui.Level, 0.4)
		UIAnim.Punch(ui.Medal, 0.4)
		-- level-up burst: a bright sweep along the bar, a ring and gold sparks off the medallion
		local at = UDim2.new(0, 13, 0.5, 0)
		if not ClientSettings.Flashes() then
			UIAnim.SweepOnce(ui.XP.Frame, K.Cream, 0.45, 0.1)
		end
		UIAnim.Ring(ui.XPRow, at, K.Gold, 80, 0.5)
		UIAnim.Sparks(ui.XPRow, at, K.Gold, 8, 40, 0.55)
		if not (ClientSettings.Flashes() or ClientPerformance.Reduced()) then
			ui.Level.TextColor3 = K.Gold
			UIAnim.Tween(ui.Level, 0.8, { TextColor3 = K.Cream })
		end
	elseif not ClientSettings.Flashes() and anim.LastXPFrac and target > anim.LastXPFrac + 0.015 and nowT - (anim.XPSweepAt or 0) > 0.6 then
		-- a gem burst: a quick glint along the bar
		anim.XPSweepAt = nowT
		UIAnim.SweepOnce(ui.XP.Frame, K.Cream, 0.4, 0.6)
	end
	anim.LastXPFrac = target
	anim.Level = lvl
	if math.abs(anim.XP - target) > 0.0005 or anim.XPSet ~= anim.XP then
		anim.XP += (target - anim.XP) * math.min(1, dt * 10)
		anim.XPSet = anim.XP
		ui.XP.Set(anim.XP)
	end
	local pending = tonumber(player:GetAttribute("PendingChoices")) or tonumber(player:GetAttribute("PendingUpgrades")) or 0
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
			ui.Kills.Value.TextColor3 = K.Cyan
			UIAnim.Tween(ui.Kills.Value, 0.8, { TextColor3 = K.Cream })
			UIAnim.Sparks(ui.Kills.Icon, UDim2.fromScale(0.5, 0.5), K.Cyan, 6, 30, 0.45)
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
	ui.BossStroke.Color = on and K.Cyan or K.Danger
	ui.BossStroke.Transparency = on and 0 or 0.2
	if on and ui.Boss.Visible and not (ClientSettings.Reduced() or ClientPerformance.Reduced()) then
		UIAnim.Pop(ui.BossArmour, 0, 0.6)
		UIAnim.SweepOnce(ui.BossMeter.Frame, K.Cyan, 0.6, 0.3)
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
		UIAnim.SweepOnce(ui.BossMeter.Frame, K.Cream, 0.5, 0.3)
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
	elseif player:GetAttribute("Downed") ~= nil then
		-- the new downed flow (Downed / BleedLeft / ReviveProgress): RunDowned owns the fallen
		-- hero's screen, so no second status line here
		setStatus("")
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

	-- the new run flow (RunStage set by the server): the objective strip, boss bar and beacon cue
	-- replace the previous stage objective + boss bar
	local v: Vector2 = host.VirtualSize()
	local portrait: boolean = host.IsPortrait()
	local edge = RunUI.ArrowEdge
	local flow = RunObjective.Update(dt, state, {
		Frame = ui.Frame,
		Scale = host.Scale(),
		Covered = hudCovered,
		Bounds = { edge, (ui.TopBottom or 120) + 24, v.X - edge, portrait and v.Y * 0.78 or ((ui.BarTop or (v.Y - 100)) - 16) },
	})
	if flow ~= (ui.RunFlow == true) then
		ui.RunFlow = flow
		layout()
	end

	-- the run clock: RunClock (server seconds, continued between updates) once the server sets
	-- it, else the previous RunTime
	local rawClock = state:GetAttribute("RunClock")
	local runTime
	if type(rawClock) == "number" then
		runTime = clockTick(rawClock, state:GetAttribute("Frozen") == true and 0 or 1, os.clock())
	else
		runTime = state:GetAttribute("RunTime") or 0
	end
	local over = flow and runTime >= RunUI.OvertimeAt
	if over ~= (ui.Overtime == true) then
		ui.Overtime = over
		layout()
	end

	-- the inventory's run-status line stays accurate (the run only stops for a shared pause)
	if ui.BuildOpen and ui.BuildNote then
		local note = state:GetAttribute("Frozen") and "The run is paused right now" or "The run continues while this is open"
		if ui.BuildNote.Text ~= note then
			ui.BuildNote.Text = note
		end
	end

	-- timer: punches each new minute
	setText(ui.Timer, UIKit.formatClock(runTime))
	if over ~= anim.OverShown then
		anim.OverShown = over
		ui.Timer.TextColor3 = over and K.Danger or K.Cream
	end
	local minute = math.floor(runTime / 60)
	if minute ~= anim.Minute then
		if anim.Minute ~= nil then
			UIAnim.Punch(ui.TimerPill, 0.15)
			if not (ClientSettings.Reduced() or ClientPerformance.Reduced()) then
				ui.Timer.TextColor3 = K.Gold
				UIAnim.Tween(ui.Timer, 0.9, { TextColor3 = over and K.Danger or K.Cream })
			end
		end
		anim.Minute = minute
	end

	local stagePhase = updateStage(state)
	if ui.RunFlow then
		-- the new strip + boss bar own the top centre: the previous ones stay out of the way
		if ui.Stage.Visible then
			ui.Stage.Visible = false
		end
		if ui.Boss.Visible then
			ui.Boss.Visible = false
		end
	else
		updateBoss(dt, state)
	end
	local nowT = os.clock()
	local _, alive = updateHealth(dt, nowT)
	updateXP(dt, nowT)
	updateKills()
	updatePurse(dt)
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
	clockTick = RunObjective.Ticker()
	ui.Overtime = false
	ui.RunFlow = false
	RunObjective.Reset()
	stopBanner()
	refreshHpText()
	refreshWard()
	purse.Shown = nil
	purse.Target = Hud.Gold()
	purse.Price, purse.AlarmUntil = 0, 0
	Hud.SetInventory(nil)
	if ui.VignetteLevel then
		ui.VignetteLevel.Value = 1
	end
end

-- The HUD is shown in a run (SetVisible) and hidden while a full-screen modal covers it
-- (SetCovered: level-up, chest reel, pause, revive, results), so its timer / health panel
-- never sit on top of or show through a modal's title and buttons.
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

-- The centre banner's reserved lane in landscape (top, bottom; root pixels), whether a
-- banner shows or not: panels and world labels in the middle of the screen keep under it.
-- Portrait: nil (the banner is mid-screen there).
function Hud.BannerLane(): (number?, number?)
	if host.IsPortrait and host.IsPortrait() then
		return nil, nil
	end
	return ui.LaneTop, ui.LaneBottom
end

-- Top of the ability panel.
function Hud.BarTop(): number
	return ui.BarTop or 600
end

-- Bottom of the ability panel.
function Hud.BarBottom(): number
	return ui.BarBottom or 700
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
	buildXpStrip(frame)
	-- the run flow's strip, boss bar and beacon cue (RunObjective); its layout follows ours
	RunObjective.Build(frame)
	RunObjective.OnLayout(layout)
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
	-- the inventory sits in their own layer over the HUD, the banner layer and the world
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
	-- the run's items for the inventory (the same list the item strip shows)
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
	-- Tab / B (keyboard) and Y (gamepad) toggle the inventory while the HUD shows
	UserInputService.InputBegan:Connect(function(input, processed)
		if processed or UserInputService:GetFocusedTextBox() then
			return
		end
		if input.KeyCode == Enum.KeyCode.Tab or input.KeyCode == Enum.KeyCode.B or input.KeyCode == Enum.KeyCode.ButtonY then
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
