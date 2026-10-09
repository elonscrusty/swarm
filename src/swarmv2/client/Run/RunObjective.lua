--!nonstrict
--[[
	SwarmV2/Run/RunObjective.lua  (StarterPlayerScripts.SwarmV2Client.Run.RunObjective)
	OWNER: stream F (run UI).

	The objective stage strip, the boss bar and the beacon direction cue of the 15-minute run,
	driven by the shared contract (docs/redesign/continuation/GAMEPLAY_PLAN.md):

	  SwarmState RunStage   Survive | BeaconAvailable | Rally | Charge | Boss | Victory | Defeat
	             RunClock   server seconds (the timer says OVERTIME after RunConfig.UI.OvertimeAt)
	             BeaconPos  Vector3, BeaconCharge 0..1, RallyLeft seconds
	             BossHP / BossMaxHP / BossName

	  strip      five step pips (done = gold, current = cyan and larger, to come = dark), the stage
	             word, one detail line and a value on the right (a countdown, a percentage or a
	             distance); a thin bar along the bottom for Rally and Charge
	  boss bar   name, health bar with the 50% phase notch, "123 / 456" and PHASE 2 below it
	  beacon     an edge arrow with the distance when BeaconPos is off screen, a small marker when
	             it is far on screen; hidden near the beacon and while a panel covers the HUD

	Absent attributes give a hidden strip (the previous stage objective keeps working until the
	server sets RunStage): Active() tells Hud which one to show. Reads only replicated
	attributes. Reduced motion: no pops, no shake, the bar fills without a sweep.
]]

local Players = game:GetService("Players")

local RunConfig = require(game:GetService("ReplicatedStorage"):WaitForChild("SwarmV2"):WaitForChild("Run"):WaitForChild("RunConfig"))
local Client = script.Parent.Parent.Parent:WaitForChild("SwarmClient")
local UIKit = require(Client:WaitForChild("UIKit"))
local UIAnim = require(Client:WaitForChild("UIAnim"))
local Icons = require(Client:WaitForChild("Icons"))
local ClientSettings = require(Client:WaitForChild("ClientSettings"))
local RunTheme = require(script.Parent.RunTheme)
local W = require(script.Parent.RunWidgets)

local RunObjective = {}

local UI = RunConfig.UI
local player = Players.LocalPlayer
local new, corner, stroke = UIKit.new, UIKit.corner, UIKit.stroke

local STAGES = { "Survive", "BeaconAvailable", "Rally", "Charge", "Boss" }
local STEP = { Survive = 1, BeaconAvailable = 2, Rally = 3, Charge = 4, Boss = 5, Victory = 6, Defeat = 6 }
local WORD = {
	Survive = "SURVIVE",
	BeaconAvailable = "BEACON AVAILABLE",
	Rally = "RALLY",
	Charge = "CHARGE",
	Boss = "BOSS",
	Victory = "VICTORY",
	Defeat = "DEFEAT",
}
local ICON = { Survive = "clock", BeaconAvailable = "flag", Rally = "people2", Charge = "portal", Boss = "skull", Victory = "crown", Defeat = "skull" }
local STEP_NAME = { "Survive", "Beacon", "Rally", "Charge", "Boss" }

local ui: { [string]: any } = {}
local anim: { [string]: any } = {}
local FLAT = Vector3.new(1, 0, 1)

-- A value read from an attribute, extended in time between its updates (a countdown that
-- the server writes once a second still ticks smoothly). rate -1 counts down, +1 up.
local function ticker()
	local raw, at = nil, 0
	return function(value: number, rate: number, now: number): number
		if value ~= raw then
			raw, at = value, now
		end
		return value + rate * (now - at)
	end
end
RunObjective.Ticker = ticker

local tickClock, tickRally = ticker(), ticker()

local function fmtClock(sec: number): string
	sec = math.max(0, math.floor(sec + 0.5))
	return string.format("%d:%02d", sec // 60, sec % 60)
end

------------------------------------------------------------------------------------------
-- Build
------------------------------------------------------------------------------------------

local STRIP_H_DESKTOP, STRIP_H_PHONE = 64, 60
local BOSS_H = 58

function RunObjective.Build(parent: Instance, layer: Instance?)
	local holder, face = W.Panel(parent, { Name = "RunObjective", Visible = false, ZIndex = 2 })
	ui.Strip, ui.StripFace = holder, face
	holder.AnchorPoint = Vector2.zero
	-- step pips (left)
	local pips = new("Frame", { Name = "Steps", BackgroundTransparency = 1, Position = UDim2.fromOffset(12, 11), Size = UDim2.fromOffset(92, 14), Active = false }, face)
	ui.Pips = {}
	for i = 1, #STAGES do
		local p = new("Frame", { Name = "Step" .. i, BackgroundColor3 = RunTheme.NavyDeep, BorderSizePixel = 0, AnchorPoint = Vector2.new(0, 0.5), Position = UDim2.new(0, (i - 1) * 19, 0.5, 0), Size = UDim2.fromOffset(15, 8), Active = false }, pips)
		corner(p, 4)
		ui.Pips[i] = { Frame = p, Stroke = stroke(p, RunTheme.NavyEdge, 1.5, 0) }
	end
	ui.Word = W.Text(face, "SURVIVE", { Name = "Word", Size = 20, Font = "Heading", Position = UDim2.fromOffset(112, 4), Box = UDim2.new(1, -112 - 96, 0, 26), Fit = 13, Color = RunTheme.Cream })
	ui.Value = W.Text(face, "", { Name = "Value", Size = 22, Font = "Number", Align = "Right", AnchorPoint = Vector2.new(1, 0), Position = UDim2.new(1, -12, 0, 2), Box = UDim2.fromOffset(92, 28), Fit = 13, Color = RunTheme.Gold })
	ui.Detail = W.Text(face, "", { Name = "Detail", Size = 16, Font = "Body", Position = UDim2.fromOffset(12, 28), Box = UDim2.new(1, -24, 0, 21), Fit = 12, Color = RunTheme.CreamMuted })
	ui.Progress = W.Bar(face, { Name = "Progress", Size = UDim2.new(1, -24, 0, 4), AnchorPoint = Vector2.new(0, 1), Position = UDim2.new(0, 12, 1, -4), Color = RunTheme.Cyan })
	ui.Progress.Frame.Visible = false

	-- boss bar
	local bholder, bface = W.Panel(parent, { Name = "RunBoss", Visible = false, ZIndex = 2, Edge = RunTheme.DangerDeep })
	ui.Boss, ui.BossFace = bholder, bface
	ui.BossIcon = Icons.Draw(bface, "skull", { Size = 24, Color = RunTheme.Danger, Back = RunTheme.Navy, AnchorPoint = Vector2.new(0, 0), Position = UDim2.fromOffset(10, 5) })
	ui.BossName = W.Text(bface, "BOSS", { Name = "Name", Size = 20, Font = "Heading", Position = UDim2.fromOffset(40, 3), Box = UDim2.new(1, -40 - 110, 0, 26), Fit = 13, Color = RunTheme.Cream })
	ui.BossPhase = W.Text(bface, "PHASE 2", { Name = "Phase", Size = 14, Font = "Label", Align = "Right", AnchorPoint = Vector2.new(1, 0), Position = UDim2.new(1, -10, 0, 5), Box = UDim2.fromOffset(100, 22), Fit = 10, Color = RunTheme.Danger, Visible = false })
	ui.BossBar = W.Bar(bface, { Name = "HP", Size = UDim2.new(1, -20, 0, 20), Position = UDim2.new(0, 10, 1, -28), Color = RunTheme.Health, Trail = true, Label = 14 })
	-- the numbers sit at the right end so the 50% phase notch never crosses them
	ui.BossBar.Label.TextXAlignment = Enum.TextXAlignment.Right
	ui.BossBar.Label.Size = UDim2.new(1, -12, 1, 0)
	-- the 50% phase notch sits on the bar but is not clipped by it (a child of the panel face)
	ui.BossMark = new("Frame", { Name = "PhaseMark", BackgroundColor3 = RunTheme.Cream, BorderSizePixel = 0, AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.5), Size = UDim2.fromOffset(3, 28), ZIndex = 6, Active = false }, bface)

	-- beacon cue layer (edge arrow / far marker), full screen, never Active
	local cueParent = layer or parent
	ui.Cue = new("Frame", { Name = "BeaconCue", BackgroundTransparency = 1, Size = UDim2.fromOffset(150, 52), AnchorPoint = Vector2.new(0.5, 0.5), Visible = false, ZIndex = 6, Active = false }, cueParent)
	local disc = new("Frame", { Name = "Disc", BackgroundColor3 = RunTheme.Navy, BorderSizePixel = 0, AnchorPoint = Vector2.new(0, 0.5), Position = UDim2.new(0, 0, 0.5, 0), Size = UDim2.fromOffset(44, 44), ZIndex = 6, Active = false }, ui.Cue)
	corner(disc, 999)
	stroke(disc, RunTheme.Gold, 2.5, 0)
	ui.CueDisc = disc
	ui.CuePivot = new("Frame", { Name = "Pivot", BackgroundTransparency = 1, AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.5), Size = UDim2.fromScale(1, 1), ZIndex = 7, Active = false }, disc)
	ui.CueArrow = Icons.Draw(ui.CuePivot, "arrowRight", { Size = 30, Color = RunTheme.Gold, Back = RunTheme.Navy, AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.5), ZIndex = 7 })
	ui.CueLabel = W.Text(ui.Cue, "Beacon", { Name = "Label", Size = 16, Font = "Strong", Position = UDim2.fromOffset(50, 0), Box = UDim2.new(1, -50, 1, 0), Color = RunTheme.Cream, ZIndex = 7, Fit = 11, Props = { TextStrokeColor3 = RunTheme.Scrim, TextStrokeTransparency = 0.3 } })
end

------------------------------------------------------------------------------------------
-- Which flow is on, sizes, placement
------------------------------------------------------------------------------------------

-- The new run flow is on once the server sets RunStage.
function RunObjective.Active(state: Instance?): boolean
	return state ~= nil and type(state:GetAttribute("RunStage")) == "string"
end

function RunObjective.StripSize(w: number, phone: boolean): (number, number)
	return w, phone and STRIP_H_PHONE or STRIP_H_DESKTOP
end

function RunObjective.BossSize(w: number): (number, number)
	return w, BOSS_H
end

function RunObjective.Place(strip: { X: number, Y: number, W: number, H: number }?, boss: { X: number, Y: number, W: number, H: number }?)
	if strip then
		ui.Strip.Position = UDim2.fromOffset(math.floor(strip.X + 0.5), math.floor(strip.Y + 0.5))
		ui.Strip.Size = UDim2.fromOffset(math.floor(strip.W + 0.5), math.floor(strip.H + 0.5))
	end
	if boss then
		ui.Boss.Position = UDim2.fromOffset(math.floor(boss.X + 0.5), math.floor(boss.Y + 0.5))
		ui.Boss.Size = UDim2.fromOffset(math.floor(boss.W + 0.5), math.floor(boss.H + 0.5))
	end
end

function RunObjective.Shown(): (boolean, boolean)
	return ui.Strip ~= nil and ui.Strip.Visible, ui.Boss ~= nil and ui.Boss.Visible
end

------------------------------------------------------------------------------------------
-- Per frame
------------------------------------------------------------------------------------------

local function reduced(): boolean
	return ClientSettings.Reduced()
end

local function localRoot(): BasePart?
	local c = player.Character
	return c and c.PrimaryPart or nil
end

local function distanceTo(pos: Vector3?): number?
	local root = localRoot()
	if typeof(pos) ~= "Vector3" or not root then
		return nil
	end
	return ((pos - root.Position) * FLAT).Magnitude
end

local function setPips(step: number)
	for i, p in ipairs(ui.Pips) do
		local done, current = i < step, i == step
		local color = done and RunTheme.Gold or (current and RunTheme.Cyan or RunTheme.NavyDeep)
		if p.Frame.BackgroundColor3 ~= color then
			p.Frame.BackgroundColor3 = color
		end
		p.Stroke.Color = current and RunTheme.Cream or (done and RunTheme.GoldDeep or RunTheme.NavyEdge)
		local h = current and 12 or 8
		if p.Frame.Size.Y.Offset ~= h then
			p.Frame.Size = UDim2.fromOffset(15, h)
		end
	end
end

-- The text of one stage: word, detail, right-hand value, bar fraction (nil = no bar).
local function describe(stage: string, state: Instance, clock: number, now: number): (string, string, string, number?, Color3)
	local word = WORD[stage] or string.upper(stage)
	local detail, value, bar = "", "", nil
	local color = RunTheme.Gold
	local over = clock >= UI.OvertimeAt
	local beaconPos = state:GetAttribute("BeaconPos")
	local dist = distanceTo(beaconPos)
	local distText = dist and string.format("%d m", math.floor(dist + 0.5)) or nil
	if stage == "Survive" then
		local left = UI.BeaconAt - clock
		if over then
			detail, value, color = "Overtime: the swarm keeps growing", "OVERTIME", RunTheme.Danger
		elseif left > 0 then
			detail, value = "Hold out. The beacon opens soon", fmtClock(left)
			bar = math.clamp(clock / UI.BeaconAt, 0, 1)
		else
			detail, value = "Hold out until the beacon opens", ""
		end
	elseif stage == "BeaconAvailable" then
		detail = (distText and ("Go to the beacon  ·  " .. distText)) or "Go to the beacon"
		value = distText or ""
	elseif stage == "Rally" then
		local left = tickRally(tonumber(state:GetAttribute("RallyLeft")) or 0, -1, now)
		anim.RallyMax = math.max(anim.RallyMax or 0, left)
		detail = (distText and ("Gather at the beacon  ·  " .. distText)) or "Gather at the beacon"
		value = fmtClock(math.max(0, left))
		bar = anim.RallyMax > 0 and math.clamp(1 - left / anim.RallyMax, 0, 1) or 0
	elseif stage == "Charge" then
		local charge = math.clamp(tonumber(state:GetAttribute("BeaconCharge")) or 0, 0, 1)
		local stalled = anim.ChargeSeen ~= nil and now - anim.ChargeAt > UI.ChargeStallSeconds and charge < 1
		if charge ~= anim.ChargeSeen then
			anim.ChargeSeen, anim.ChargeAt = charge, now
		end
		local inside = dist ~= nil and dist <= UI.BeaconRadius
		if stalled and not inside then
			detail, color = "Charge paused. Return to the ring", RunTheme.Warn
		elseif stalled then
			detail, color = "Charge paused. Nobody can hold the ring", RunTheme.Warn
		elseif inside then
			detail = "Stay inside the ring"
		else
			detail = (distText and ("Back to the ring  ·  " .. distText)) or "Back to the ring"
			color = RunTheme.Warn
		end
		value = string.format("%d%%", math.floor(charge * 100 + 0.5))
		bar = charge
	elseif stage == "Boss" then
		detail = "Defeat " .. tostring(state:GetAttribute("BossName") or "the boss")
	elseif stage == "Victory" then
		detail, color = "The basin is safe", RunTheme.Good
	elseif stage == "Defeat" then
		detail, color = "The run is over", RunTheme.Danger
	end
	return word, detail, value, bar, color
end

local function updateStrip(state: Instance, now: number)
	local stage = state:GetAttribute("RunStage")
	local clock = tickClock(tonumber(state:GetAttribute("RunClock")) or 0, 1, now)
	local step = STEP[stage] or 1
	if anim.Stage ~= stage then
		local first = anim.Stage == nil
		anim.Stage = stage
		anim.RallyMax, anim.ChargeSeen, anim.ChargeAt = nil, nil, now
		if not first and not reduced() then
			UIAnim.Pop(ui.Strip, 0, 0.8)
			if stage == "Boss" or stage == "Defeat" then
				UIAnim.Shake(ui.Strip, 4, 0.25)
			end
		end
	end
	setPips(step)
	local word, detail, value, bar, color = describe(stage, state, clock, now)
	W.Set(ui.Word, word)
	W.Set(ui.Detail, detail)
	W.Set(ui.Value, value)
	if ui.Value.TextColor3 ~= color then
		ui.Value.TextColor3 = color
	end
	ui.Progress.Frame.Visible = bar ~= nil
	if bar then
		ui.Progress.Set(bar)
		ui.Progress.SetColor(stage == "Rally" and RunTheme.Gold or RunTheme.Cyan)
	end
end

local function updateBoss(state: Instance, dt: number)
	local max = tonumber(state:GetAttribute("BossMaxHP")) or 0
	local show = max > 0
	if ui.Boss.Visible ~= show then
		ui.Boss.Visible = show
		anim.BossShown = false
		if anim.OnLayout then
			anim.OnLayout()
		end
	end
	if not show then
		return
	end
	local hp = math.clamp(tonumber(state:GetAttribute("BossHP")) or 0, 0, max)
	local frac = hp / max
	if not anim.BossShown then
		anim.BossShown = true
		anim.Trail = 1
		anim.PhaseHit = false
		if not reduced() then
			UIAnim.Pop(ui.Boss, 0, 0.5)
			UIAnim.Shake(ui.Boss, 6, 0.35)
		end
	end
	W.Set(ui.BossName, string.upper(tostring(state:GetAttribute("BossName") or "Boss")))
	ui.BossBar.Set(frac)
	anim.Trail = math.max(frac, (anim.Trail or 1) - dt * 0.3)
	ui.BossBar.SetTrail(anim.Trail)
	W.Set(ui.BossBar.Label, string.format("%s / %s", UIKit.formatNumber(math.ceil(hp)), UIKit.formatNumber(max)))
	local at = tonumber(state:GetAttribute("BossPhaseAt")) or 0.5
	ui.BossMark.Visible = at > 0 and at < 1
	-- the notch rides the bar: 10 px of side padding, 20 px of bar frame margin
	ui.BossMark.Position = UDim2.new(at, (1 - 2 * at) * 10, 1, -18)
	local phase2 = at > 0 and at < 1 and frac <= at and hp > 0
	ui.BossPhase.Visible = phase2
	if phase2 and not anim.PhaseHit then
		anim.PhaseHit = true
		if not reduced() then
			UIAnim.Shake(ui.Boss, 7, 0.4)
			UIAnim.SweepOnce(ui.BossBar.Frame, RunTheme.Cream, 0.5, 0.4)
		end
	end
end

-- Screen position (design px) of a world point, and whether it is on screen.
local function project(frame: GuiObject, world: Vector3, scale: number): (Vector2, boolean)
	local cam = workspace.CurrentCamera
	local vp, onScreen = cam:WorldToViewportPoint(world)
	local off = frame.AbsolutePosition
	local s = math.max(0.01, scale)
	return Vector2.new((vp.X - off.X) / s, (vp.Y - off.Y) / s), onScreen and vp.Z > 0
end

--[[
	Edge arrow toward the beacon: an arrow disc on the screen edge (inside `bounds`: left, top,
	right, bottom in design px) with "Beacon  84 m", turned toward it; a small marker over the
	beacon when it is far but on screen; nothing within 40 studs or without BeaconPos.
]]
local function updateCue(state: Instance, frame: GuiObject, bounds: { number }, scale: number, covered: boolean)
	local pos = state:GetAttribute("BeaconPos")
	local stage = state:GetAttribute("RunStage")
	local wanted = typeof(pos) == "Vector3" and (stage == "BeaconAvailable" or stage == "Rally" or stage == "Charge") and not covered
	local root = localRoot()
	if not wanted or not root then
		ui.Cue.Visible = false
		return
	end
	local dist = ((pos - root.Position) * FLAT).Magnitude
	if dist < 40 then
		ui.Cue.Visible = false
		return
	end
	local left, top, right, bottom = bounds[1], bounds[2], bounds[3], bounds[4]
	local p, on = project(frame, pos + Vector3.new(0, 6, 0), scale)
	local label = string.format("Beacon  %d m", math.floor(dist + 0.5))
	W.Set(ui.CueLabel, label)
	ui.Cue.Visible = true
	local w, h = ui.Cue.Size.X.Offset, ui.Cue.Size.Y.Offset
	if on and p.X > left + w / 2 and p.X < right - w / 2 and p.Y > top + h / 2 and p.Y < bottom - h / 2 then
		-- on screen and far: a marker over the beacon, arrow pointing down at it
		ui.Cue.Position = UDim2.fromOffset(math.floor(p.X + 0.5), math.floor(p.Y + 0.5))
		ui.CuePivot.Rotation = 90
		return
	end
	-- off screen: from the screen centre toward the beacon, onto the safe rectangle
	local c = Vector2.new((left + right) / 2, (top + bottom) / 2)
	local d
	if on then
		d = p - c
	else
		local cam = workspace.CurrentCamera
		local r = cam.CFrame.RightVector * FLAT
		local f = cam.CFrame.LookVector * FLAT
		local flat = (pos - root.Position) * FLAT
		if r.Magnitude > 0.01 and f.Magnitude > 0.01 then
			d = Vector2.new(flat:Dot(r.Unit), -flat:Dot(f.Unit))
		else
			d = p - c
		end
	end
	if d.Magnitude < 1 then
		d = Vector2.new(0, -1)
	end
	local halfW, halfH = w / 2, h / 2
	local xMin, xMax = left + halfW, right - halfW
	local yMin, yMax = top + halfH, bottom - halfH
	local kx = d.X ~= 0 and ((d.X > 0 and (xMax - c.X) or (xMin - c.X)) / d.X) or math.huge
	local ky = d.Y ~= 0 and ((d.Y > 0 and (yMax - c.Y) or (yMin - c.Y)) / d.Y) or math.huge
	local at = c + d * math.min(kx, ky)
	ui.Cue.Position = UDim2.fromOffset(math.floor(at.X + 0.5), math.floor(at.Y + 0.5))
	ui.CuePivot.Rotation = math.floor(math.deg(math.atan2(d.Y, d.X)) + 0.5)
end

--[[
	Every frame while in a run. `ctx`: Frame (a GuiObject at the UI root, for projection), Scale,
	Bounds { left, top, right, bottom } for the beacon cue, Covered (a panel hides the HUD).
	Returns true when the new flow is on (Hud hides its previous objective + boss bar then).
]]
function RunObjective.Update(dt: number, state: Instance, ctx: { [string]: any }): boolean
	if not ui.Strip then
		return false
	end
	local active = RunObjective.Active(state)
	if ui.Strip.Visible ~= active then
		ui.Strip.Visible = active
		if not active then
			ui.Boss.Visible = false
			ui.Cue.Visible = false
			anim.Stage = nil
		end
		if anim.OnLayout then
			anim.OnLayout()
		end
	end
	if not active then
		return false
	end
	local now = os.clock()
	updateStrip(state, now)
	updateBoss(state, dt)
	updateCue(state, ctx.Frame, ctx.Bounds, ctx.Scale, ctx.Covered == true)
	return true
end

-- Hud sets a function that re-runs its layout when the strip or the boss bar appears / goes.
function RunObjective.OnLayout(fn: () -> ())
	anim.OnLayout = fn
end

function RunObjective.Reset()
	anim = { OnLayout = anim.OnLayout }
	tickClock, tickRally = ticker(), ticker()
	if ui.Strip then
		ui.Strip.Visible = false
		ui.Boss.Visible = false
		ui.Cue.Visible = false
	end
end

function RunObjective.Elements(): { [string]: any }
	return ui
end

-- Pure helpers for tests.
RunObjective.Stages = STAGES
RunObjective.StepOf = function(stage: string): number
	return STEP[stage] or 1
end
RunObjective.WordOf = function(stage: string): string
	return WORD[stage] or string.upper(stage)
end
RunObjective.Format = fmtClock
RunObjective.StepNames = STEP_NAME
RunObjective.Icon = ICON

return RunObjective
