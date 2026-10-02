--[[
	Hud.lua
	The in-run HUD (built and driven by UIBuilder):
	  top centre    big run timer, under it a plate with health (heart + crimson bar) and
	                level / XP (gold bar), then the boss bar while the boss lives
	  top right     kills and gold counters, pause button
	  centre        status line (paused, teammate choosing, fallen, partner revive progress)
	  bottom centre ability bar: weapons row + passives row with level badges (portrait:
	                under the health plate, away from the thumbs)
	  screen edges  crimson vignette pulse when hurt, slow pulse at low health

	Nothing in the ability bar or the plates is Active, so a thumb landing on them still
	drives the floating thumbstick.
]]

local Players = game:GetService("Players")
local TweenService = game:GetService("TweenService")

local Shared = game:GetService("ReplicatedStorage"):WaitForChild("Shared")
local Config = require(Shared:WaitForChild("Config"))
local Theme = require(Shared:WaitForChild("Theme"))
local WeaponData = require(Shared:WaitForChild("WeaponData"))
local UIKit = require(script.Parent.UIKit)
local UIAnim = require(script.Parent.UIAnim)
local Icons = require(script.Parent.Icons)

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
		TextSize = Theme.TextSize.Small,
		AnchorPoint = Vector2.new(0, 0.5),
		Position = UDim2.new(0, 32, 0.5, 0),
		Size = UDim2.new(1, -32, 1, -2),
	})

	local xpRow = new("Frame", { Name = "XP", BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0.5, -3), LayoutOrder = 2 }, rows)
	ui.Level = text(xpRow, "Label", "Lv. 1", {
		Name = "Level",
		TextColor3 = P.gold_300,
		Size = UDim2.new(0, 56, 1, 0),
		TextXAlignment = Enum.TextXAlignment.Left,
	}, Theme.TextSize.Body)
	ui.XP = UIKit.Meter(xpRow, {
		Gradient = Theme.Gradient.XP,
		TextStyle = "Number",
		TextSize = Theme.TextSize.Caption,
		AnchorPoint = Vector2.new(0, 0.5),
		Position = UDim2.new(0, 60, 0.5, 0),
		Size = UDim2.new(1, -60, 1, -6),
	})

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
	text(bossTitle, "H3", "SCORPION QUEEN", {
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

	-- kills / gold counters + pause
	local counters = UIKit.Panel(frame, { Name = "Counters", AutomaticSize = Enum.AutomaticSize.X, Size = UDim2.fromOffset(0, 44) }, true)
	UIKit.padding(counters, 0, 14, 0, 12)
	UIKit.list(counters, { FillDirection = Enum.FillDirection.Horizontal, VerticalAlignment = Enum.VerticalAlignment.Center, Padding = UDim.new(0, 14) })
	ui.Counters = counters
	ui.Kills = UIKit.Chip(counters, "skull", nil, "0", { LayoutOrder = 1, Size = UDim2.fromOffset(0, 44) }, { Size = 20, Color = P.ivory_200, Back = P.slate_950 })
	ui.Gold = UIKit.Chip(counters, "coin", nil, "0", { LayoutOrder = 2, Size = UDim2.fromOffset(0, 44) }, { Size = 20 })
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

	-- plate
	local plateW = math.min(Theme.Layout.HudPlate.X, W - 2 * M)
	local plateH = compact and 78 or Theme.Layout.HudPlate.Y
	local plateY = timerY + timerH + 2
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
	ui.BarTop = barY
	ui.BarBottom = barY + barH

	-- status line: centre-low in landscape, below the ability bar in portrait
	local statusW = math.min(640, W - 2 * M)
	ui.Status.Size = UDim2.fromOffset(statusW, compact and 58 or 50)
	if portrait then
		ui.Status.Position = UDim2.fromOffset(W / 2, barY + barH + 40)
	else
		ui.Status.Position = UDim2.fromOffset(W / 2, math.min(H * 0.66, barY - 44))
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
		return
	end
	layout()
	local wt, pt = barMetrics.Weapon, barMetrics.Passive
	-- tiles that are new or just levelled up pop in
	local function popIfChanged(tile: GuiObject, key: string, level: number)
		if shownLevels[key] ~= level then
			UIAnim.Pop(tile, 0, shownLevels[key] and 1.35 or 0.3)
			shownLevels[key] = level
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
			tile = UIKit.Tile(ui.PassiveRow, { Id = p.Id, Size = pt, Level = p.Level, Max = p.Level >= 5 })
			popIfChanged(tile, "P" .. p.Id, p.Level)
		else
			tile = UIKit.Tile(ui.PassiveRow, { Size = pt, Empty = true })
		end
		tile.LayoutOrder = i
	end
end

------------------------------------------------------------------------------------------
-- Feedback
------------------------------------------------------------------------------------------

local vignetteTween: Tween? = nil

-- Crimson edge pulse (replaces the old full-screen red flash).
function Hud.Hurt()
	local level = ui.VignetteLevel :: NumberValue
	if not level then
		return
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
-- Per frame (only while in a run)
------------------------------------------------------------------------------------------

function Hud.Update(dt: number, state: Configuration, reviveOpen: boolean)
	local phase = state:GetAttribute("Phase") or "Lobby"
	local runTime = state:GetAttribute("RunTime") or 0

	-- timer: punches each new minute, glows crimson in the last 10 s before the boss
	ui.Timer.Text = UIKit.formatClock(runTime)
	local minute = math.floor(runTime / 60)
	if minute ~= anim.Minute then
		if anim.Minute ~= nil then
			UIAnim.Punch(ui.Timer, 0.25)
		end
		anim.Minute = minute
	end
	local toBoss = Config.Run.BossTime - runTime
	if toBoss > 0 and toBoss <= 10 then
		ui.Timer.TextColor3 = C.Text:Lerp(P.crimson_300, 0.5 + 0.5 * math.sin(os.clock() * 10))
	else
		ui.Timer.TextColor3 = C.Text
	end

	-- health: the fill follows at once, the ivory trail slides down behind it
	local hp = player:GetAttribute("HP") or 0
	local maxHp = math.max(1, player:GetAttribute("MaxHP") or 1)
	local frac = math.clamp(hp / maxHp, 0, 1)
	if frac > anim.HPTrail then
		anim.HPTrail = frac
	else
		anim.HPTrail = math.max(frac, anim.HPTrail - dt * 0.45)
	end
	anim.HP += (frac - anim.HP) * math.min(1, dt * 14)
	ui.HP.Set(anim.HP, string.format("%d / %d", math.ceil(hp), maxHp))
	ui.HP.SetTrail(anim.HPTrail)

	-- low health: the screen edge breathes crimson
	local level = ui.VignetteLevel :: NumberValue
	local alive = player:GetAttribute("Alive") ~= false
	if alive and frac > 0 and frac <= (Config.UI.LowHealthFraction or 0.3) then
		if not vignetteTween or vignetteTween.PlaybackState ~= Enum.PlaybackState.Playing then
			level.Value = 0.72 + 0.18 * (0.5 + 0.5 * math.sin(os.clock() * 4))
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
		if flash then
			flash.Color = ColorSequence.new(P.ivory_100)
			task.delay(0.25, function()
				flash.Color = Theme.Gradient.XP
			end)
		end
		UIAnim.Punch(ui.Level, 0.4)
	end
	anim.Level = lvl
	anim.XP += (target - anim.XP) * math.min(1, dt * 10)
	ui.XP.Set(anim.XP, string.format("%d / %d XP", xp, need))
	ui.Level.Text = "Lv. " .. tostring(lvl)

	-- counters
	local kills, gold = player:GetAttribute("Kills") or 0, player:GetAttribute("RunGold") or 0
	if anim.Gold ~= nil and gold > anim.Gold then
		UIAnim.Punch(ui.Gold.Value, 0.2)
	end
	anim.Gold = gold
	ui.Kills.SetValue(UIKit.formatNumber(kills))
	ui.Gold.SetValue(UIKit.formatNumber(gold))

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
			UIAnim.Pop(ui.Boss, 0, 0.3)
		end
		ui.BossMeter.Set(bfrac)
		anim.BossTrail = math.max(bfrac, anim.BossTrail - dt * 0.25)
		ui.BossMeter.SetTrail(anim.BossTrail)
	else
		anim.BossShown = false
	end

	-- status line
	if state:GetAttribute("Frozen") then
		if state:GetAttribute("LevelUpPause") then
			if player:GetAttribute("Paused") then
				setStatus("") -- you are the one choosing: the level-up screen says it all
			else
				setStatus("Paused: a teammate is choosing an upgrade", "hourglass")
			end
		else
			setStatus("Paused", "pause")
		end
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

-- Resets per-run animation state (a new run starts from a clean HUD).
function Hud.Reset()
	anim = { XP = 0, HP = 1, HPTrail = 1 }
	Hud.SetInventory(nil)
	if ui.VignetteLevel then
		ui.VignetteLevel.Value = 1
	end
end

function Hud.SetVisible(on: boolean)
	if ui.Frame then
		ui.Frame.Visible = on
	end
	if not on and ui.VignetteLevel then
		ui.VignetteLevel.Value = 1
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
	buildBar(frame)
	buildStatus(frame)
	buildVignette(fxGui)
	h.OnRelayout(layout)
	layout()
end

-- For the preview tool / tests: the HUD's elements.
function Hud.Elements(): { [string]: any }
	return ui
end

return Hud
