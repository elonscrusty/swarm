--[[
	StageUI.lua
	The client side of the stage loop (server: StageManager), in the HUD's style:

	  portal reveal  SwarmState PortalReveal counts up when a stage's portal can be charged
	                 (StageManager): a banner "THE PORTAL HAS APPEARED" with a sound
	                 (Hud.Announce), the beacon pillar and pulsing floor ring over the
	                 portal (PortalBeacon, updated from here every frame) and the minimap
	                 ping (MiniMap). Owner: the portal must be very evident when it spawns.
	  portal arrow   from the reveal on (SwarmState PortalHint; Config.Stages.HintAfterSeconds
	                 can delay it) an arrow at the screen edge points at this stage's
	                 portal, with "PORTAL · 139 m" on a dark tag; when the portal is on
	                 screen the marker sits just above its arch (under the beacon pillar)
	                 instead. It keeps off the HUD corners, the centre bars, the banner
	                 lane, the notice pills and the touch buttons (JUMP, ULT), and hides
	                 while any panel is open (level-up, reward, portal choice, run menu,
	                 BUILD details, the merchant's shop)
	  charge ring    24 rune segments over the portal that fill while someone stands in
	                 its circle ("Stand here 2 s to summon" / "Summoning 60%")
	  choice panel   the portal opened (remote PortalOffer): stage cleared, the run so far,
	                 NEXT STAGE (primary gold) or RETURN TO LOBBY (+ the win bonus), the
	                 auto-continue countdown and who is ready (SwarmState ChoiceLeft /
	                 PortalReady). Answers with the PortalChoice remote; the server decides.
	                 Endless runs (offer.Endless): NEXT STAGE only, no RETURN TO LOBBY.
	  waves          SwarmState WaveSeq changes when the server announces a wave
	                 (EnemySpawner, Config.Waves): a big centre banner "WAVE 3" / "From the
	                 north" with the horn (Hud.Announce, WaveHorn) and an amber glow on the
	                 screen edge(s) it comes from (SwarmState WaveAngle + WaveSides; amber so
	                 it never reads as the crimson hurt / low-health vignette)
	  travel fade    remote StageTravel: the screen fades to slate with "STAGE N · Arena"
	                 (the title slams in with a ring and sparks), then fades back once the
	                 new stage is running
	Motion: the cleared title slams in with sparks, the portal icon swirls; charge-ring runes pop as they light and the ring flashes when full; the
	arrow marker punches when it first appears. All event-driven, honouring
	ClientSettings.Reduced().

	Nothing here is Active except the choice panel, so the thumbstick keeps working.
	UIBuilder builds it (StageUI.Build) and calls StageUI.Update every frame in a run.
]]

local Players = game:GetService("Players")
local TweenService = game:GetService("TweenService")

local Shared = game:GetService("ReplicatedStorage"):WaitForChild("Shared")
local Config = require(Shared:WaitForChild("Config"))
local Remotes = require(Shared:WaitForChild("Remotes"))
local Theme = require(Shared:WaitForChild("Theme"))
local UIKit = require(script.Parent.UIKit)
local UIAnim = require(script.Parent.UIAnim)
local Icons = require(script.Parent.Icons)
local Hud = require(script.Parent.Hud)
local MiniMap = require(script.Parent.MiniMap)
local LootUI = require(script.Parent.LootUI)
local ClientSettings = require(script.Parent.ClientSettings)
local Accessibility = require(script.Parent.Accessibility)
local PortalBeacon = require(script.Parent.PortalBeacon)
local RunIntro = require(script.Parent.RunIntro)
local UIState = require(script.Parent.UIState)

local StageUI = {}

local player = Players.LocalPlayer
local new, text, TS = UIKit.new, UIKit.text, UIKit.TS
local C, P = Theme.Color, Theme.Palette

local SEGMENTS = 24
local RING_R = 30
local ARROW_TAG_W = 118 -- the "PORTAL · 139 m" tag under the arrow badge
local ARROW_HALF_W = ARROW_TAG_W / 2 + 4 -- the marker's half width with its tag

local kit: { [string]: any } = {}
local ui: { [string]: any } = {}
local offer: { [string]: any }? = nil
local chosen = false
local travel = { Active = false, Since = 0 }
local lastReveal: number? = nil -- SwarmState PortalReveal seen last (nil = not in a run)
local lastWaveSeq: number? = nil -- SwarmState WaveSeq seen last (nil = not in a run)
local lastWarn = 0 -- SwarmState SwarmWarn seen last (the swarm-pressure banner)

-- Swarm pressure (SwarmState SwarmWarn, Config.Stages.Pressure): a banner each step up,
-- so nobody wonders why the swarm keeps thickening while the portal waits.
local function checkPressure(state: Configuration)
	local warn = state:GetAttribute("SwarmWarn") or 0
	if warn == lastWarn then
		return
	end
	local up = warn > lastWarn
	lastWarn = warn
	if up and warn == 1 then
		Hud.Announce("THE SWARM IS GROWING", Config.Waves.Enabled and "Bigger waves until the portal opens" or "Open the portal before it gets worse", Accessibility.Color(Color3.fromRGB(246, 218, 126), "Loot"), "PortalAppear", "swarm.pressure.1", "Info")
	elseif up and warn >= 2 then
		Hud.Announce("THE SWARM IS OVERWHELMING", Config.Waves.Enabled and "Huge waves: open the portal now!" or "Open the portal now!", Accessibility.Color(Color3.fromRGB(219, 106, 94), "Danger"), "PortalAppear", "swarm.pressure.2", "Critical")
	end
end

-- The portal reveal: banner + sound (the beacon and the minimap ping watch the attribute
-- themselves). A mid-run joiner sees the banner too: it tells them where to go.
local function checkReveal(state: Configuration)
	local reveal = state:GetAttribute("PortalReveal") or 0
	if lastReveal == nil then
		lastReveal = 0
	end
	if reveal ~= lastReveal then
		lastReveal = reveal
		if reveal > 0 then
			-- semantic id portal.reveal: the server's broadcast of the same moment merges
			-- into this one banner (UIState), never a second heading
			-- (the one portal instruction of the stage: the run start sends no objective notice)
			local boss = tostring(state:GetAttribute("StageBoss") or "")
			Hud.Announce("THE PORTAL HAS APPEARED", "Follow the PORTAL arrow · stand in its ring to summon " .. (boss ~= "" and ("the " .. boss) or "the boss"),
				Accessibility.Color(Color3.fromRGB(190, 210, 255), "Magic"), "PortalAppear", "portal.reveal", "Info", 15)
		end
	end
end

------------------------------------------------------------------------------------------
-- Build
------------------------------------------------------------------------------------------

local function buildArrow(root: Frame)
	local holder = new("Frame", {
		Name = "PortalArrow",
		BackgroundTransparency = 1,
		AnchorPoint = Vector2.new(0.5, 0.5),
		Size = UDim2.fromOffset(64, 64),
		Visible = false,
		ZIndex = Theme.Z.Hud,
	}, root)
	ui.Arrow = holder
	-- the pointer: a gold chevron on a ring that turns toward the portal
	local pivot = new("Frame", { Name = "Pivot", BackgroundTransparency = 1, AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.5), Size = UDim2.fromOffset(64, 64) }, holder)
	ui.ArrowPivot = pivot
	-- a gold diamond half hidden behind the badge reads as the arrow's point
	local tip = new("Frame", {
		Name = "Tip",
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.new(1, -8, 0.5, 0),
		Size = UDim2.fromOffset(22, 22),
		Rotation = 45,
		BackgroundColor3 = C.Blue,
		BorderSizePixel = 0,
	}, pivot)
	UIKit.corner(tip, 3)
	UIKit.stroke(tip, C.BlueDeep, 1.5, 0)
	local badge, face = UIKit.Surface(holder, { Name = "Badge", Radius = 999, Transparency = 0.02, Edge = C.PanelEdge, EdgeThickness = 3, Shadow = false, Size = UDim2.fromOffset(48, 48), AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.5) })
	UIKit.Raise(badge, 5, 3)
	Icons.Draw(face, "portal", { Size = 30, AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.5), Back = C.Panel })
	-- "PORTAL · 139 m" on a navy tag under the badge (readable over grass and snow)
	ui.ArrowDistance = UIKit.Role(holder, "Label", "", {
		AnchorPoint = Vector2.new(0.5, 0),
		Position = UDim2.new(0.5, 0, 1, 0),
		Size = UDim2.fromOffset(ARROW_TAG_W, TS(Theme.Type.Label.Size) + 6),
		TextXAlignment = Enum.TextXAlignment.Center,
		TextColor3 = C.TextOnBlue,
		TextStrokeTransparency = 1,
		BackgroundColor3 = C.Text,
		BackgroundTransparency = 0.08,
		-- scales down inside its box: the phone's large-text setting grew "139 m" onto the tray
		TextScaled = true,
	}, true)
	UIKit.corner(ui.ArrowDistance, 999)
	UIKit.stroke(ui.ArrowDistance, C.PanelEdge, 2, 0)
	UIKit.padding(ui.ArrowDistance, 1, 8, 1, 8)
	new("UITextSizeConstraint", { MinTextSize = 10, MaxTextSize = ui.ArrowDistance.TextSize }, ui.ArrowDistance)
	UIAnim.Breathe(badge, 0.06, 1.6)
end

local function buildRing(root: Frame)
	local holder = new("Frame", {
		Name = "PortalRing",
		BackgroundTransparency = 1,
		AnchorPoint = Vector2.new(0.5, 0.5),
		Size = UDim2.fromOffset(RING_R * 2 + 24, RING_R * 2 + 24),
		Visible = false,
		ZIndex = Theme.Z.Hud,
	}, root)
	ui.Ring = holder
	local disc = new("Frame", {
		Name = "Disc",
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.5),
		Size = UDim2.fromOffset(RING_R * 2 - 8, RING_R * 2 - 8),
		BackgroundColor3 = C.Panel,
		BackgroundTransparency = 0.05,
		BorderSizePixel = 0,
	}, holder)
	UIKit.corner(disc, 999)
	UIKit.stroke(disc, C.PanelEdge, 2, 0)
	Icons.Draw(disc, "portal", { Size = 28, AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.5), Back = C.Panel })
	ui.Segments = {}
	local c = RING_R + 12
	for i = 1, SEGMENTS do
		local a = (i - 1) / SEGMENTS * math.pi * 2 - math.pi / 2
		local seg = new("Frame", {
			Name = "Seg",
			AnchorPoint = Vector2.new(0.5, 0.5),
			Position = UDim2.fromOffset(c + math.cos(a) * RING_R, c + math.sin(a) * RING_R),
			Size = UDim2.fromOffset(4, 9),
			Rotation = math.deg(a) + 90,
			BackgroundColor3 = C.BluePale,
			BackgroundTransparency = 0.05,
			BorderSizePixel = 0,
		}, holder)
		UIKit.stroke(seg, C.Blue, 1, 0.3)
		UIKit.corner(seg, 999)
		ui.Segments[i] = seg
	end
	ui.RingLabel = UIKit.Role(holder, "Label", "", {
		AnchorPoint = Vector2.new(0.5, 0),
		Position = UDim2.new(0.5, 0, 1, 2),
		Size = UDim2.fromOffset(220, TS(Theme.Type.Label.Size) + 6),
		TextXAlignment = Enum.TextXAlignment.Center,
		TextColor3 = C.TextOnBlue,
		TextStrokeTransparency = 1,
		BackgroundColor3 = C.Text,
		BackgroundTransparency = 0.08,
	}, true)
	UIKit.corner(ui.RingLabel, 999)
	UIKit.stroke(ui.RingLabel, C.PanelEdge, 2, 0)
end

local function smallStat(parent: Instance, icon: string, caption: string, order: number): TextLabel
	local f = UIKit.Panel(parent, { Name = caption, LayoutOrder = order, Size = UDim2.fromOffset(104, 74) }, true)
	Icons.Draw(f, icon, { Size = 20, AnchorPoint = Vector2.new(0.5, 0), Position = UDim2.new(0.5, 0, 0, 8), Color = if icon == "coin" or icon == "portal" then nil else C.Blue, Back = C.PanelInset })
	local value = UIKit.Role(f, "Number", "0", {
		Name = "Value",
		Position = UDim2.fromOffset(0, 28),
		Size = UDim2.new(1, 0, 0, TS(Theme.Type.Number.Size) + 2),
		TextXAlignment = Enum.TextXAlignment.Center,
		TextStrokeTransparency = 1,
	})
	UIKit.Role(f, "Caption", UIKit.track(caption), {
		AnchorPoint = Vector2.new(0, 1),
		Position = UDim2.new(0, 0, 1, -6),
		Size = UDim2.new(1, 0, 0, TS(Theme.Type.Caption.Size) + 2),
		TextXAlignment = Enum.TextXAlignment.Center,
	})
	return value
end

local function choose(choice: string)
	if not offer then
		return
	end
	Remotes.Get("PortalChoice"):FireServer(choice)
	if choice == "Return" then
		-- the server sends the results screen next; close at once so it never flickers
		kit.Hide(ui.Choice.Overlay, "Portal")
		offer = nil
	end
end

local function buildChoice(root: Frame)
	local m = UIKit.Modal(root, "Portal", 560, 480, Theme.Z.LevelUp - 2)
	m.Overlay:SetAttribute("BackdropTransparency", 0.5)
	UIKit.Raise(m.Panel, 6, 3) -- arcade panel depth (as the Play setup panel)
	ui.Choice = m
	local content = m.Content
	local list = UIKit.list(content, { Padding = UDim.new(0, 10), HorizontalAlignment = Enum.HorizontalAlignment.Center })
	kit.FitModal(m, list)
	ui.ChoiceIcon = Icons.Draw(content, "portal", { Size = 46, LayoutOrder = 1, Back = C.Panel })
	ui.ChoiceTitle = UIKit.PageTitleStyle(text(content, "H1", "STAGE 1 CLEARED", { LayoutOrder = 2, TextXAlignment = Enum.TextXAlignment.Center }), 2.5)
	UIKit.Divider(content, 240, { LayoutOrder = 3 })
	ui.ChoiceSub = text(content, "Body", "The portal is open. Go deeper, or take your winnings home.", {
		LayoutOrder = 4,
		TextXAlignment = Enum.TextXAlignment.Center,
		TextWrapped = true,
		Size = UDim2.new(1, 0, 0, TS(16) * 2 + 6),
	})
	local stats = new("Frame", { Name = "Stats", BackgroundTransparency = 1, LayoutOrder = 5, Size = UDim2.new(1, 0, 0, 74) }, content)
	ui.ChoiceStats = stats
	UIKit.list(stats, { FillDirection = Enum.FillDirection.Horizontal, HorizontalAlignment = Enum.HorizontalAlignment.Center, Padding = UDim.new(0, 8), Wraps = true })
	ui.StatStages = smallStat(stats, "portal", "Stages", 1)
	ui.StatTime = smallStat(stats, "clock", "Time", 2)
	ui.StatKills = smallStat(stats, "skull", "Kills", 3)
	ui.StatGold = smallStat(stats, "coin", "Gold", 4)

	local buttons = new("Frame", { Name = "Buttons", BackgroundTransparency = 1, LayoutOrder = 6, Size = UDim2.new(1, 0, 0, 92) }, content)
	ui.ChoiceButtons = buttons
	ui.ChoiceButtonsList = UIKit.list(buttons, { FillDirection = Enum.FillDirection.Horizontal, HorizontalAlignment = Enum.HorizontalAlignment.Center, Padding = UDim.new(0, 12) })
	ui.Next = UIKit.Button(buttons, {
		Kind = "Primary",
		Title = "NEXT STAGE",
		Subtitle = "Stage 2",
		Icon = "portal",
		IconSize = 30,
		TitleSize = 15,
		Size = UDim2.fromOffset(240, 76),
		LayoutOrder = 1,
		Glow = true,
		Depth = "Strong",
		OnClick = function()
			choose("Next")
		end,
	})
	ui.Return = UIKit.Button(buttons, {
		Kind = "Secondary",
		Title = "RETURN TO LOBBY",
		Subtitle = "+0 gold · a win",
		Icon = "castle",
		IconSize = 26,
		TitleSize = 15,
		Size = UDim2.fromOffset(240, 76),
		LayoutOrder = 2,
		Depth = "Medium",
		OnClick = function()
			choose("Return")
		end,
	})
	ui.ChoiceNote = text(content, "Caption", "", { LayoutOrder = 7, TextXAlignment = Enum.TextXAlignment.Center })
	ui.ChoiceMeter = UIKit.Meter(content, { Gradient = Theme.Gradient.XP, Size = UDim2.fromOffset(280, 5), LayoutOrder = 8 })

	kit.OnRelayout(function()
		local v: Vector2 = kit.VirtualSize()
		local w = math.min(560, v.X - 32)
		local stacked = w < 540
		m.Panel.Size = UDim2.new(UDim.new(0, w), m.Panel.Size.Y)
		ui.ChoiceButtonsList.FillDirection = stacked and Enum.FillDirection.Vertical or Enum.FillDirection.Horizontal
		ui.ChoiceButtonsList.HorizontalAlignment = Enum.HorizontalAlignment.Center
		ui.ChoiceButtonsList.Padding = UDim.new(0, stacked and 8 or 12)
		local bw = stacked and math.min(320, w - 48) or math.floor((w - 48 - 12) / 2)
		ui.Next.Instance.Size = UDim2.fromOffset(bw, stacked and 66 or 76)
		ui.Return.Instance.Size = UDim2.fromOffset(bw, stacked and 66 or 76)
		buttons.Size = UDim2.new(1, 0, 0, stacked and 140 or 80)
		local narrow = w < 470
		stats.Size = UDim2.new(1, 0, 0, narrow and 156 or 74)
	end)
end

local function buildFade(root: Frame)
	local fade = new("Frame", {
		Name = "StageFade",
		BackgroundColor3 = C.Text,
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		Visible = false,
		ZIndex = Theme.Z.Toast - 1,
	}, root)
	UIKit.Bleed(fade)
	ui.Fade = fade
	local box = new("Frame", { Name = "Title", BackgroundTransparency = 1, AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.45), Size = UDim2.fromOffset(600, 150), ZIndex = 2 }, fade)
	UIKit.list(box, { Padding = UDim.new(0, 6), HorizontalAlignment = Enum.HorizontalAlignment.Center, VerticalAlignment = Enum.VerticalAlignment.Center })
	Icons.Draw(box, "portal", { Size = 44, LayoutOrder = 1, Back = C.Text, ZIndex = 2 })
	ui.FadeTitle = UIKit.Role(box, "Display", "STAGE 2", { LayoutOrder = 2, TextXAlignment = Enum.TextXAlignment.Center, TextColor3 = C.PrimaryTop, Size = UDim2.new(1, 0, 0, TS(Theme.Type.Display.Size) + 8), ZIndex = 2 })
	ui.FadeSub = UIKit.Role(box, "Body", "", { LayoutOrder = 3, TextXAlignment = Enum.TextXAlignment.Center, TextColor3 = C.BluePale, ZIndex = 2 })
	ui.FadeLabels = { ui.FadeTitle, ui.FadeSub }
end

------------------------------------------------------------------------------------------
-- Choice panel
------------------------------------------------------------------------------------------

local function refreshChoiceButtons()
	if chosen then
		ui.Next.SetText("READY", (offer and offer.Group) and "Waiting for your team" or "Traveling...")
		ui.Next.SetIcon("check")
		ui.Next.SetEnabled(false)
	else
		ui.Next.SetText("NEXT STAGE", offer and string.format("Stage %d · %s", offer.NextStage or 2, tostring(offer.NextArena or "")) or nil)
		ui.Next.SetIcon("portal")
		ui.Next.SetEnabled(true)
	end
end

local function onOffer(data)
	if type(data) ~= "table" then
		return
	end
	if data.Close then
		offer = nil
		chosen = false
		kit.Hide(ui.Choice.Overlay, "Portal")
		return
	end
	if data.Chosen then
		chosen = data.Chosen == "Next"
		refreshChoiceButtons()
		return
	end
	offer = data
	chosen = false
	ui.ChoiceTitle.Text = data.Complete and "EXPEDITION COMPLETE" or string.format("STAGE %d CLEARED", data.Stage or 1)
	ui.ChoiceSub.Text = data.Complete and string.format("%d stages cleared. Return safely with all your winnings.", tonumber(data.WinMinStages) or Config.Stages.WinMinStages or 5)
		or data.Endless and "ENDLESS · The portal only leads deeper. Leave any time from the pause menu."
		or (data.Group and "The portal is open. Go deeper together, or take your winnings home." or "The portal is open. Go deeper, or take your winnings home.")
	ui.Return.Instance.Visible = data.Endless ~= true
	ui.Next.Instance.Visible = data.Complete ~= true
	ui.StatStages.Text = tostring(data.StagesCleared or 0)
	ui.StatTime.Text = UIKit.formatTime(data.Time or 0)
	ui.StatKills.Text = UIKit.formatNumber(data.Kills or 0)
	ui.StatGold.Text = UIKit.formatNumber(data.Gold or 0)
	-- a return counts as a win only from Config.Stages.WinMinStages cleared stages
	local winNote = data.CountsAsWin and " · a win" or string.format(" · win from stage %d", data.WinMinStages or Config.Stages.WinMinStages or 5)
	ui.Return.SetText("RETURN TO LOBBY", string.format("+%s gold", UIKit.formatNumber(data.ReturnBonus or 0)) .. winNote)
	refreshChoiceButtons()
	kit.Show(ui.Choice.Overlay, "Portal", true)
	UIAnim.Pop(ui.ChoiceTitle, 0.05, 1.8)
	-- the portal icon swirls in, the run's numbers land and count up, then the two doors
	if not ClientSettings.Reduced() then
		ui.ChoiceIcon.Rotation = -200
		UIAnim.Tween(ui.ChoiceIcon, 0.6, { Rotation = 0 }, Enum.EasingStyle.Back)
		for i, label in ipairs({ ui.StatStages, ui.StatTime, ui.StatKills, ui.StatGold }) do
			local tile = label.Parent
			if tile and tile:IsA("GuiObject") then
				UIAnim.Pop(tile, 0.1 + 0.06 * i, 0.5)
			end
		end
		UIAnim.Pop(ui.Next.Instance, 0.38, 0.6)
		UIAnim.Pop(ui.Return.Instance, 0.46, 0.6)
		-- the title lands with sparks and the panel catches a glint
		task.delay(0.2, function()
			if offer == data and ui.ChoiceTitle.Parent then
				UIAnim.Sparks(ui.Choice.Panel, UDim2.new(0.5, 0, 0, 90), C.Primary, 12, 110, 0.65)
				UIAnim.Ring(ui.Choice.Panel, UDim2.new(0.5, 0, 0, 50), C.BlueLight, 140, 0.55)
			end
		end)
	end
	UIAnim.CountTo(ui.StatKills, 0, tonumber(data.Kills) or 0, UIKit.formatNumber, 0.7)
	UIAnim.CountTo(ui.StatGold, 0, tonumber(data.Gold) or 0, UIKit.formatNumber, 0.8)
	UIKit.FocusIfGamepad(data.Complete and ui.Return.Instance or ui.Next.Instance)
end

------------------------------------------------------------------------------------------
-- Travel
------------------------------------------------------------------------------------------

local function fadeTo(target: number, seconds: number)
	local f = ui.Fade :: Frame
	if target < 1 then
		f.Visible = true
	end
	local tw = TweenService:Create(f, TweenInfo.new(seconds, Enum.EasingStyle.Quad, Enum.EasingDirection.InOut), { BackgroundTransparency = target })
	tw:Play()
	for _, l in ipairs(ui.FadeLabels) do
		TweenService:Create(l, TweenInfo.new(seconds), { TextTransparency = target < 1 and 0 or 1 }):Play()
	end
	if target >= 1 then
		tw.Completed:Once(function()
			if not travel.Active then
				f.Visible = false
			end
		end)
	end
end

local function onTravel(data)
	if type(data) ~= "table" then
		return
	end
	travel.Active = true
	travel.Since = os.clock()
	-- the travel fade owns the screen (UIState: nothing else opens over it) and the last
	-- stage's queued headlines / notices are dropped
	UIState.Open("Travel", { Blocks = false, Covers = false })
	UIState.Reset("travel")
	ui.FadeTitle.Text = "STAGE " .. tostring(data.Stage or "?")
	-- "RUINS · MOTH MATRIARCH": the arena and the boss that guards its portal
	local sub = tostring(data.Arena or "")
	if type(data.Boss) == "string" and data.Boss ~= "" then
		sub ..= "  ·  " .. data.Boss
	end
	ui.FadeSub.Text = UIKit.track(sub)
	offer = nil
	kit.Hide(ui.Choice.Overlay, "Portal")
	fadeTo(0.02, math.max(0.2, (data.Seconds or 0.8) * 0.9))
	UIAnim.Pop(ui.FadeTitle, 0.1, 2.2)
	UIAnim.Pop(ui.FadeSub, 0.3, 0.9)
	task.delay(0.35, function()
		if travel.Active then
			UIAnim.Ring(ui.Fade, UDim2.fromScale(0.5, 0.45), C.BlueLight, 360, 0.7)
			UIAnim.Sparks(ui.Fade, UDim2.fromScale(0.5, 0.45), C.Primary, 14, 160, 0.7)

		end
	end)
end

local function endTravel()
	travel.Active = false
	UIState.Close("Travel")
	fadeTo(1, 0.6)
end

------------------------------------------------------------------------------------------
-- Per frame
------------------------------------------------------------------------------------------

local function project(world: Vector3): (Vector2, boolean)
	local cam = workspace.CurrentCamera
	local vp, onScreen = cam:WorldToViewportPoint(world)
	local s = math.max(0.01, kit.Scale())
	local off: Vector2 = kit.GuiOffset()
	return Vector2.new((vp.X - off.X) / s, (vp.Y - off.Y) / s), onScreen and vp.Z > 0
end

local function localRoot(): BasePart?
	local char = player.Character
	return char and char.PrimaryPart or nil
end

-- The arrow (64 px badge + distance label under it) centred at y must not lie on a
-- reserved top-centre bar (Hud.ReserveCentre: the caravan defence bar); drop it below.
local function clearCentreBars(x: number, y: number): number
	for _, g in ipairs(Hud.CentreBars()) do
		if g.Visible and g.Parent then
			local gw, gh = g.Size.X.Offset, g.Size.Y.Offset
			local gx = g.Position.X.Offset - g.AnchorPoint.X * gw
			local gy = g.Position.Y.Offset - g.AnchorPoint.Y * gh
			if x + 45 > gx - 6 and x - 45 < gx + gw + 6 and y + 54 > gy - 6 and y - 32 < gy + gh + 6 then
				y = gy + gh + 6 + 32
			end
		end
	end
	return y
end

-- The edge marker must not sit on the HUD's corner panels (landscape: the vitals + item
-- strip column top left, the minimap top right): an arrow that would land on one drops
-- just below it, keeping its side of the screen.
local function clearCornerPanels(x: number, y: number): number
	local rects = {}
	local function add(g: GuiObject?)
		if g and g.Visible and g.Parent and g.Size.X.Offset > 0 then
			local gw, gh = g.Size.X.Offset, g.Size.Y.Offset
			table.insert(rects, { g.Position.X.Offset - g.AnchorPoint.X * gw, g.Position.Y.Offset - g.AnchorPoint.Y * gh, gw, gh })
		end
	end
	local hud = Hud.Elements()
	if not kit.IsPortrait() then
		add(hud.Plate)
		local loot = LootUI.Elements()
		if loot.Strip and #loot.Strip:GetChildren() > 1 then
			add(loot.Strip)
		end
	end
	add(MiniMap.Elements().Holder)
	for _, r in ipairs(rects) do
		local gx, gy, gw, gh = r[1], r[2], r[3], r[4]
		if x + 40 > gx - 6 and x - 40 < gx + gw + 6 and y + 54 > gy - 6 and y - 32 < gy + gh + 6 then
			y = gy + gh + 6 + 32
		end
	end
	return y
end

-- Touch buttons and notice pills the marker must keep off, as rects in root pixels
-- ({ x, y, w, h }). Touch buttons live in their own ScreenGuis (SwarmStick: JUMP;
-- FeatureHud: ULT); their screen rects are read twice a second.
local touchRects: { { number } } = {}
local touchAt = -1

local function screenToRoot(g: GuiObject): { number }
	local s = math.max(0.01, kit.Scale())
	local off: Vector2 = kit.GuiOffset()
	local p, sz = g.AbsolutePosition, g.AbsoluteSize
	return { (p.X - off.X) / s, (p.Y - off.Y) / s, sz.X / s, sz.Y / s }
end

local function refreshTouchRects()
	if os.clock() - touchAt < 0.5 then
		return
	end
	touchAt = os.clock()
	table.clear(touchRects)
	local pg = player:FindFirstChild("PlayerGui")
	if not pg then
		return
	end
	local function add(gui: Instance?, path: { string })
		if not gui or not gui:IsA("ScreenGui") or not gui.Enabled then
			return
		end
		local obj: Instance? = gui
		for _, name in ipairs(path) do
			obj = obj and obj:FindFirstChild(name, true)
		end
		if obj and obj:IsA("GuiObject") and obj.Visible and obj.AbsoluteSize.X > 0 then
			table.insert(touchRects, screenToRoot(obj))
		end
	end
	add(pg:FindFirstChild("SwarmStick"), { "JumpButton" })
	add(pg:FindFirstChild("FeatureHud"), { "Ultimate" })
end

-- The notice pills (UIBuilder's toast list, a sibling in the same root) and the centre
-- banner while they show.
local function centreRects(): { { number } }
	local out = {}
	local root = ui.Arrow and ui.Arrow.Parent
	local toasts = root and root:FindFirstChild("Toasts")
	if toasts and toasts:IsA("GuiObject") and toasts.Visible then
		for _, c in ipairs(toasts:GetChildren()) do
			if c:IsA("GuiObject") and c.Visible and c.AbsoluteSize.X > 0 then
				table.insert(out, screenToRoot(c))
			end
		end
	end
	local banner = Hud.Elements().Banner
	if banner and banner.Visible then
		table.insert(out, screenToRoot(banner))
	end
	return out
end

-- Moves a marker centred at (x, y) off every rect in `rects`, along the screen edge it
-- sits on: on a side edge it moves up (or down, under a rect in the top half), on the top /
-- bottom edge sideways toward the nearer end of the rect.
local function avoidRects(x: number, y: number, rects: { { number } }, onSide: boolean, H: number): (number, number)
	for _ = 1, 3 do
		local moved = false
		for _, r in ipairs(rects) do
			local gx, gy, gw, gh = r[1], r[2], r[3], r[4]
			if x + ARROW_HALF_W > gx - 6 and x - ARROW_HALF_W < gx + gw + 6 and y + 54 > gy - 6 and y - 32 < gy + gh + 6 then
				moved = true
				if onSide then
					if gy + gh / 2 > H / 2 then
						y = gy - 6 - 54
					else
						y = gy + gh + 6 + 32
					end
				else
					if x < gx + gw / 2 then
						x = gx - 6 - ARROW_HALF_W
					else
						x = gx + gw + 6 + ARROW_HALF_W
					end
				end
			end
		end
		if not moved then
			break
		end
	end
	return x, y
end

local function updateArrowAndRing(state: Configuration, stagePhase: string)
	local pos = state:GetAttribute("PortalPos")
	local root = localRoot()
	local alive = player:GetAttribute("Alive") ~= false
	if typeof(pos) ~= "Vector3" or not root or travel.Active then
		ui.Arrow.Visible = false
		ui.Ring.Visible = false
		return
	end
	local v: Vector2 = kit.VirtualSize()
	local W, H = v.X, v.Y
	local flat = Vector3.new(pos.X - root.Position.X, 0, pos.Z - root.Position.Z)
	local dist = flat.Magnitude

	-- charge ring over the portal
	local charge = state:GetAttribute("PortalCharge") or 0
	local inside = alive and dist <= Config.Stages.PortalRadius
	local top, topOn = project(pos + Vector3.new(0, 12, 0))
	-- (also just outside the circle once revealed: the label says what to do there)
	local hinted = state:GetAttribute("PortalHint") == true
	local near = alive and hinted and dist <= Config.Stages.PortalRadius + 10
	local showRing = stagePhase == "Explore" and (inside or near or charge > 0) and topOn
	ui.Ring.Visible = showRing
	if not showRing then
		ui.LitSegments = 0
	end
	if showRing then
		-- beside the portal (right, or left near the edge), so the portal stays visible
		local base = project(pos)
		local side = (top.X + 150 > W - 60) and -1 or 1
		local x = math.clamp(top.X + side * 150, 60, W - 60)
		local y = math.clamp((top.Y + base.Y) / 2, Hud.TopBottom() + 50, H - 90)
		ui.Ring.Position = UDim2.fromOffset(math.floor(x + 0.5), math.floor(y + 0.5))
		local lit = math.floor(charge * SEGMENTS + 0.001)
		if lit > (ui.LitSegments or 0) and not ClientSettings.Reduced() then
			-- the rune that just lit pops
			UIAnim.Punch(ui.Segments[math.min(lit, SEGMENTS)], 0.9)
			if lit >= SEGMENTS then
				UIAnim.Sparks(ui.Ring, UDim2.fromScale(0.5, 0.5), C.Primary, 12, 60, 0.6)
				UIAnim.Ring(ui.Ring, UDim2.fromScale(0.5, 0.5), C.BlueLight, 130, 0.5)
			end
		end
		ui.LitSegments = lit
		for i, seg in ipairs(ui.Segments) do
			local on = i <= lit
			seg.BackgroundColor3 = on and C.Primary or C.BluePale
			seg.BackgroundTransparency = on and 0 or 0.05
			seg.Size = on and UDim2.fromOffset(5, 11) or UDim2.fromOffset(4, 9)
		end
		local lockLeft = state:GetAttribute("PortalLockLeft") or 0
		if charge > 0 then
			ui.RingLabel.Text = UIKit.track(string.format("Summoning %d%%", math.floor(charge * 100)))
		elseif lockLeft > 0 then
			ui.RingLabel.Text = UIKit.track("Dormant " .. UIKit.formatTime(lockLeft))
		else
			-- before the reveal it can't be charged (StageManager); after it: how to summon
			ui.RingLabel.Text = UIKit.track(not hinted and "Not open yet"
				or string.format("Stand here %s s to summon", tostring(Config.Stages.ChargeSeconds)))
		end
	end

	-- edge arrow (after the hint time, while exploring)
	-- (hidden while the player reads the BUILD details over the arena; the minimap keeps
	-- the portal pin and the marker returns when they close)
	-- (also hidden while this player's run menu is open: the drawer covers that side and the
	-- marker sat on the HUD's centre status line)
	-- (and while any panel is open: level-up, reward, portal choice, or the merchant's shop
	-- in the middle of the screen, UIState.SidePanelOpen)
	local showArrow = stagePhase == "Explore" and state:GetAttribute("PortalHint") == true and not inside and not showRing and not Hud.BuildOpen()
		and not UIState.IsShown("Pause") and UIState.Owner() == nil and not UIState.Covered() and not UIState.SidePanelOpen()
	if not showArrow then
		ui.Arrow.Visible = false
		ui.ArrowShown = false
		return
	end
	if not ui.ArrowShown then
		ui.ArrowShown = true
		UIAnim.Pop(ui.Arrow, 0, 0.4)
	end
	-- the arch is ~11 studs tall: on screen the marker sits just above it
	local p, on = project(pos + Vector3.new(0, 13, 0))
	local portrait: boolean = kit.IsPortrait()
	local els = Hud.Elements()
	local yMin = math.max(70, Hud.TopBottom() + 44)
	if portrait and els.BarBottom then
		yMin = math.max(yMin, els.BarBottom + 44)
	end
	local yMax = portrait and (H - 110) or (H - 70)
	local xMin, xMax = ARROW_HALF_W + 4, W - ARROW_HALF_W - 4
	-- landscape: the ability bar takes the bottom centre; keep the arrow above it there
	local barTop, barL, barR = math.huge, 0, 0
	if not portrait and els.Bar then
		-- the marker's centre: its 64 px badge plus the distance label under it (~30 px)
		-- stay above the tray with a small gap
		barTop = Hud.BarTop() - 66
		barL = els.Bar.Position.X.Offset - 40
		barR = barL + els.Bar.Size.X.Offset + 80
	end
	ui.ArrowDistance.Text = string.format("PORTAL · %d m", math.floor(dist + 0.5))
	local overBar = p.Y > barTop and p.X > barL and p.X < barR
	if on and p.X > xMin and p.X < xMax and p.Y > yMin and p.Y < yMax and not overBar then
		-- on screen: a marker floats over the portal, pointing down at it
		ui.Arrow.Visible = true
		local fy = p.Y - 34 + math.sin(os.clock() * 3) * 4
		ui.Arrow.Position = UDim2.fromOffset(math.floor(p.X + 0.5), math.floor(clearCentreBars(p.X, fy) + 0.5))
		ui.ArrowPivot.Rotation = 90
		return
	end
	-- off screen: clamp the direction from the screen centre onto the safe rectangle
	local c = Vector2.new(W / 2, (yMin + yMax) / 2)
	local d = p - c
	if not on then
		-- behind the camera (or projected backwards): use the ground direction instead
		local cam = workspace.CurrentCamera
		local right = cam.CFrame.RightVector * Vector3.new(1, 0, 1)
		local fwd = cam.CFrame.LookVector * Vector3.new(1, 0, 1)
		if right.Magnitude > 0.01 and fwd.Magnitude > 0.01 then
			d = Vector2.new(flat:Dot(right.Unit), -flat:Dot(fwd.Unit))
		end
	end
	if d.Magnitude < 1 then
		d = Vector2.new(0, -1)
	end
	local function clampTo(bottom: number): Vector2
		local kx = d.X ~= 0 and ((d.X > 0 and (xMax - c.X) or (xMin - c.X)) / d.X) or math.huge
		local ky = d.Y ~= 0 and ((d.Y > 0 and (bottom - c.Y) or (yMin - c.Y)) / d.Y) or math.huge
		return c + d * math.min(kx, ky)
	end
	local at = clampTo(yMax)
	if at.Y > barTop and at.X > barL and at.X < barR then
		at = clampTo(barTop)
	end
	refreshTouchRects()
	local ax, ay = at.X, clearCornerPanels(at.X, clearCentreBars(at.X, at.Y))
	local onSide = ax <= xMin + 1 or ax >= xMax - 1
	ax, ay = avoidRects(ax, ay, touchRects, onSide, H)
	ax, ay = avoidRects(ax, ay, centreRects(), onSide, H)
	ax = math.clamp(ax, xMin, xMax)
	ay = math.clamp(ay, yMin, yMax)
	ui.Arrow.Visible = true
	ui.Arrow.Position = UDim2.fromOffset(math.floor(ax + 0.5), math.floor(ay + 0.5))
	ui.ArrowPivot.Rotation = math.deg(math.atan2(d.Y, d.X))
end

------------------------------------------------------------------------------------------
-- Waves
------------------------------------------------------------------------------------------

local EDGE_SIDES = { "Left", "Right", "Top", "Bottom" }

local function buildEdges(root: Frame)
	ui.Edges = {}
	for _, side in ipairs(EDGE_SIDES) do
		local vertical = side == "Left" or side == "Right"
		-- amber, not crimson: crimson at the screen edge means YOU are hurt / low on health
		-- (Hud vignette); this edge only says where a new wave comes from
		local f = new("Frame", {
			Name = "WaveEdge" .. side,
			BackgroundColor3 = P.amber_500,
			BackgroundTransparency = 1,
			BorderSizePixel = 0,
			AnchorPoint = Vector2.new(side == "Right" and 1 or 0, side == "Bottom" and 1 or 0),
			Position = UDim2.fromScale(side == "Right" and 1 or 0, side == "Bottom" and 1 or 0),
			Size = vertical and UDim2.new(0, 90, 1, 0) or UDim2.new(1, 0, 0, 70),
			Visible = false,
			ZIndex = Theme.Z.Hud,
		}, root)
		-- solid at the screen edge, clear toward the middle
		local rot = ({ Left = 0, Right = 180, Top = 90, Bottom = 270 })[side]
		new("UIGradient", {
			Rotation = rot,
			Transparency = NumberSequence.new({ NumberSequenceKeypoint.new(0, 0.15), NumberSequenceKeypoint.new(1, 1) }),
		}, f)
		ui.Edges[side] = f
	end
end

-- Which screen edge a world direction (from the local hero) points at.
local function screenSide(angle: number): string?
	local root = localRoot()
	if not root then
		return nil
	end
	local p = root.Position
	local a, _ = project(p)
	local b, _ = project(p + Vector3.new(math.cos(angle), 0, math.sin(angle)) * 40)
	local d = b - a
	if d.Magnitude < 1 then
		return nil
	end
	if math.abs(d.X) > math.abs(d.Y) then
		return d.X > 0 and "Right" or "Left"
	end
	return d.Y > 0 and "Bottom" or "Top"
end

local function flashEdge(side: string)
	local f = ui.Edges and ui.Edges[side]
	if not f then
		return
	end
	f.Visible = true
	f.BackgroundTransparency = 1
	local reduced = ClientSettings.Reduced()
	-- in: quick (reduced: no pulse, one soft fade); hold; out
	local fadeIn = TweenService:Create(f, TweenInfo.new(reduced and 0.4 or 0.15), { BackgroundTransparency = reduced and 0.45 or 0.25 })
	fadeIn:Play()
	task.delay(reduced and 2.4 or 0.45, function()
		if not reduced then
			TweenService:Create(f, TweenInfo.new(0.3, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut, 2, true), { BackgroundTransparency = 0.55 }):Play()
		end
		task.delay(reduced and 0 or 1.2, function()
			local out = TweenService:Create(f, TweenInfo.new(0.8), { BackgroundTransparency = 1 })
			out.Completed:Connect(function()
				if f.BackgroundTransparency >= 0.99 then
					f.Visible = false
				end
			end)
			out:Play()
		end)
	end)
end

local function checkWave(state: Configuration)
	local seq = state:GetAttribute("WaveSeq") or 0
	if lastWaveSeq == nil then
		lastWaveSeq = seq -- entering a run mid-wave: no stale banner
		return
	end
	if seq == lastWaveSeq or RunIntro.Active() then
		return -- the stage-start card is up: the banner waits for it
	end
	lastWaveSeq = seq
	local n = state:GetAttribute("Wave") or 0
	local sides = string.split(tostring(state:GetAttribute("WaveSides") or ""), ",")
	local sub = #sides == 1 and sides[1] ~= "" and ("From the " .. sides[1]) or ("From " .. #sides .. " sides at once!")
	if state:GetAttribute("WaveBig") == true then
		sub = "BIG WAVE · " .. sub
	end
	-- the big banner + horn only for wave 1, every big wave and a stage's first wave
	-- (SwarmState WaveLoud); the others get the server's one-line toast, the pill and the
	-- edge glow
	if state:GetAttribute("WaveLoud") ~= false then
		Hud.Announce("WAVE " .. tostring(n), sub, Accessibility.Color(P.crimson_300, "Danger"), "WaveHorn", "wave." .. tostring(n), "Critical")
	end
	local base = state:GetAttribute("WaveAngle")
	if type(base) == "number" and #sides >= 1 then
		local lit = {}
		for d = 1, #sides do
			local side = screenSide(base + (d - 1) * (2 * math.pi / #sides))
			if side and not lit[side] then
				lit[side] = true
				flashEdge(side)
			end
		end
	end
end

function StageUI.Update(_dt: number, state: Configuration, inRun: boolean)
	local stagePhase = state:GetAttribute("StagePhase") or "None"
	if not inRun then
		ui.Arrow.Visible = false
		ui.Ring.Visible = false
		if UIState.IsOpen("Portal") then
			offer = nil
			kit.Hide(ui.Choice.Overlay, "Portal")
		end
		if travel.Active then
			endTravel()
		end
		if lastReveal ~= nil then
			lastReveal = nil
			PortalBeacon.Clear()
		end
		lastWaveSeq = nil
		return
	end
	checkReveal(state)
	checkWave(state)
	checkPressure(state)
	PortalBeacon.Update(state, not travel.Active)
	-- the travel fade lifts once the next stage runs (or after a safety timeout)
	if travel.Active and ((stagePhase ~= "Travel" and os.clock() - travel.Since > 0.5) or os.clock() - travel.Since > 8) then
		endTravel()
	end
	updateArrowAndRing(state, stagePhase)
	-- open (shown, or waiting behind the upgrade choice: UIState)
	if UIState.IsOpen("Portal") then
		if stagePhase ~= "Open" then
			offer = nil
			kit.Hide(ui.Choice.Overlay, "Portal")
		else
			local left = state:GetAttribute("ChoiceLeft") or 0
			local ready = state:GetAttribute("PortalReady") or ""
			local note
			if state:GetAttribute("ChoiceLeftHeld") == true then
				-- group run: the countdown waits (bounded) while someone has an upgrade choice open
				local names = tostring(state:GetAttribute("ChoosingNames") or "")
				note = string.format("Waiting for %s to choose · %ds", names ~= "" and names or "a teammate", left)
			elseif chosen then
				note = ready ~= "" and string.format("Waiting for your team (%s ready) · %ds", ready, left) or string.format("Traveling in %ds", left)
			else
				note = string.format((offer and offer.Complete) and "Returning in %ds" or (offer and offer.Endless) and "Next stage in %ds" or "Next stage in %ds unless you return", left)
			end
			if state:GetAttribute("Frozen") then
				note ..= "  ·  paused"
			end
			ui.ChoiceNote.Text = UIKit.track(note)
			ui.ChoiceMeter.Set(left / math.max(1, Config.Stages.ChoiceSeconds))
		end
	end
end

-- For the preview tool / tests.
function StageUI.Elements(): { [string]: any }
	return ui
end

-- Headlines whose moment can pass while they wait in UIState's queue (a reward card or the
-- stage-start card holds them): checked while they wait and while they show, so a late
-- "THE PORTAL HAS APPEARED" never plays once the portal is open or the boss is up.
local function registerValidators()
	local function phase(): string
		return tostring(Remotes.State():GetAttribute("StagePhase") or "None")
	end
	UIState.SetValidator("portal.reveal", function()
		return phase() == "Explore"
	end)
	UIState.SetValidator("swarm.pressure", function()
		return phase() == "Explore"
	end)
	UIState.SetValidator("portal.open", function()
		return phase() == "Open"
	end)
	-- "wave.6": stale once a later wave has started
	UIState.SetValidator("wave.", function(id: string)
		local n = tonumber(string.match(id, "^wave%.(%d+)$"))
		local now = tonumber(Remotes.State():GetAttribute("Wave"))
		return n == nil or now == nil or now <= n
	end)
	-- "stage.3": only on stage 3
	UIState.SetValidator("stage.", function(id: string)
		local n = tonumber(string.match(id, "^stage%.(%d+)$"))
		local now = tonumber(Remotes.State():GetAttribute("Stage"))
		return n == nil or now == nil or now == n
	end)
end

function StageUI.Build(root: Frame, k: { [string]: any })
	kit = k
	registerValidators()
	buildEdges(root)
	buildArrow(root)
	buildRing(root)
	buildChoice(root)
	buildFade(root)
	Remotes.Get("PortalOffer").OnClientEvent:Connect(onOffer)
	Remotes.Get("StageTravel").OnClientEvent:Connect(onTravel)
end

return StageUI
