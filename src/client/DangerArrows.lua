--[[
	DangerArrows.lua (Config.Features.DangerArrows; docs/next/DANGER_ARROWS.md)
	Edge-of-screen arrows for the big threats, client only:

	  Boss      red skull badge
	  Champion  gold crown badge (the mini-boss guarding a chest: body attribute "MiniBoss")
	  Elite     crimson ring badge (body attribute "Elite")

	An arrow shows while its enemy is off screen or farther than Config.DangerArrows.FarStuds
	from the local hero: a round badge on the safe-area edge with a pointer that turns toward
	the enemy and "42 m" under it (studs read as metres, like the portal arrow). The badge
	shape differs per kind as well as the colour (colour-blind players), and colours go
	through Accessibility.Color. At most MaxArrows, nearest first; bosses never lose their
	place to a nearer elite. Each fades in (FadeSeconds) and pulses softly; Reduced effects
	keeps the arrow but drops the pulse.

	Placement: the arrow sits where the direction from the screen centre meets the safe
	rectangle, then slides along the edge until its box clears every HUD rect a world label
	must keep off (WorldLabelFade.Rects: top-centre stack, vitals, ability bar, banner,
	BUILD, centre bars, notice pills, minimap), the gold / kills pills, pause, buff and status
	chips (Hud), the touch buttons (JUMP, ULT), the feature
	badges, the portal arrow (StageUI) and the arrows already placed. No clear spot = no
	arrow. Hidden outside a running run, while dead and while any panel is open (the same
	rules as the portal arrow).

	Data: the replicated enemy bodies in workspace.SwarmEnemies (the ones EnemyRenderer
	draws), their Type / Elite / MiniBoss attributes and EnemyData IsBoss. No remotes.
	Refreshed UpdateHz times a second; positions glide between refreshes with short tweens.
]]

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")

local Shared = game:GetService("ReplicatedStorage"):WaitForChild("Shared")
local Config = require(Shared:WaitForChild("Config"))
local Remotes = require(Shared:WaitForChild("Remotes"))
local EnemyData = require(Shared:WaitForChild("EnemyData"))
local Theme = require(Shared:WaitForChild("Theme"))
local UIKit = require(script.Parent.UIKit)
local Icons = require(script.Parent.Icons)
local Hud = require(script.Parent.Hud)
local MiniMap = require(script.Parent.MiniMap)
local StageUI = require(script.Parent.StageUI)
local UIState = require(script.Parent.UIState)
local WorldLabelFade = require(script.Parent.WorldLabelFade)
local ClientSettings = require(script.Parent.ClientSettings)
local Accessibility = require(script.Parent.Accessibility)

local DangerArrows = {}

local player = Players.LocalPlayer
local P = Theme.Palette
local ACTIVE_Y = -100 -- below this an enemy body is parked in the server pool
local TAG_H = 18
local STEP = 12 -- pixels per slide step along the edge

type Box = { number } -- { left, top, right, bottom } in AbsolutePosition space
type Target = { Kind: string, Dist: number, Pos: Vector3, Body: BasePart }
type Arrow = {
	Holder: CanvasGroup,
	Pivot: Frame,
	Point: Frame,
	Badge: Frame,
	Stroke: UIStroke,
	Glyph: Frame?,
	Tag: TextLabel,
	Scale: UIScale,
	Kind: string?,
	Shown: boolean,
	Pulse: Tween?,
	Body: BasePart?,
	X: number,
	Y: number,
	Box: Box?,
}

local KINDS = {
	Boss = { Rank = 1, Color = P.crimson_400, Role = "Danger" },
	Champion = { Rank = 2, Color = P.gold_400, Role = "Loot" },
	Elite = { Rank = 3, Color = P.crimson_600, Role = "Danger" },
}

local gui: ScreenGui? = nil
local root: Frame? = nil
local arrows: { Arrow } = {}
local lastStep = 0
local debugInfo: { { [string]: any } } = {}

local function cfg(): { [string]: any }
	return (Config :: any).DangerArrows or {}
end

local function on(): boolean
	return Config.FeatureOn("DangerArrows")
end

------------------------------------------------------------------------------------------
-- Build
------------------------------------------------------------------------------------------

local function makeArrow(parent: Instance, i: number): Arrow
	local size = tonumber(cfg().Size) or 44
	local holder = UIKit.new("CanvasGroup", {
		Name = "Danger" .. i,
		BackgroundTransparency = 1,
		AnchorPoint = Vector2.new(0.5, 0.5),
		Size = UDim2.fromOffset(size + 24, size + 24 + TAG_H),
		GroupTransparency = 1,
		Visible = false,
	}, parent) :: CanvasGroup
	local scale = UIKit.new("UIScale", { Scale = 1 }, holder) :: UIScale
	-- the pointer: a diamond on the badge's rim, turned toward the enemy
	local pivot = UIKit.new("Frame", {
		Name = "Pivot",
		BackgroundTransparency = 1,
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromOffset((size + 24) / 2, (size + 24) / 2),
		Size = UDim2.fromOffset(size + 20, size + 20),
	}, holder) :: Frame
	local point = UIKit.new("Frame", {
		Name = "Point",
		AnchorPoint = Vector2.new(1, 0.5),
		Position = UDim2.new(1, -2, 0.5, 0),
		Size = UDim2.fromOffset(16, 16),
		Rotation = 45,
		BorderSizePixel = 0,
		BackgroundColor3 = P.crimson_500,
	}, pivot) :: Frame
	UIKit.corner(point, 3)
	UIKit.stroke(point, P.slate_950, 2, 0.2)
	local badge = UIKit.new("Frame", {
		Name = "Badge",
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromOffset((size + 24) / 2, (size + 24) / 2),
		Size = UDim2.fromOffset(size, size),
		BackgroundColor3 = P.slate_900,
		BackgroundTransparency = 0.12,
		BorderSizePixel = 0,
	}, holder) :: Frame
	UIKit.corner(badge, 999)
	local stroke = UIKit.stroke(badge, P.crimson_500, 3, 0)
	local tag = UIKit.Role(holder, "Label", "", {
		Name = "Distance",
		AnchorPoint = Vector2.new(0.5, 0),
		Position = UDim2.new(0.5, 0, 0, size + 22),
		Size = UDim2.fromOffset(0, TAG_H),
		AutomaticSize = Enum.AutomaticSize.X,
		TextXAlignment = Enum.TextXAlignment.Center,
		TextColor3 = P.ivory_100,
		BackgroundColor3 = P.slate_950,
		BackgroundTransparency = 0.25,
		TextStrokeTransparency = 1,
	})
	UIKit.corner(tag, 999)
	UIKit.padding(tag, 0, 6, 0, 6)
	-- distance tags are short numbers: they keep their designed size (no Text size growth)
	UIKit.new("UITextSizeConstraint", { MinTextSize = 9, MaxTextSize = math.max(10, tag.TextSize) }, tag)
	tag:SetAttribute("NoTextFit", true)
	return {
		Holder = holder,
		Pivot = pivot,
		Point = point,
		Badge = badge,
		Stroke = stroke,
		Glyph = nil,
		Tag = tag,
		Scale = scale,
		Kind = nil,
		Shown = false,
		Pulse = nil,
		Body = nil,
		X = 0,
		Y = 0,
		Box = nil,
	}
end

-- The badge's inside: skull (boss), crown (champion), a ring with a dot (elite).
local function setKind(a: Arrow, kind: string)
	if a.Kind == kind then
		return
	end
	a.Kind = kind
	if a.Glyph then
		a.Glyph:Destroy()
		a.Glyph = nil
	end
	local size = tonumber(cfg().Size) or 44
	local col = Accessibility.Color(KINDS[kind].Color, KINDS[kind].Role)
	a.Stroke.Color = col
	a.Point.BackgroundColor3 = col
	local g: Frame
	if kind == "Elite" then
		g = UIKit.new("Frame", {
			Name = "Ring",
			BackgroundTransparency = 1,
			AnchorPoint = Vector2.new(0.5, 0.5),
			Position = UDim2.fromScale(0.5, 0.5),
			Size = UDim2.fromOffset(math.floor(size * 0.52), math.floor(size * 0.52)),
		}, a.Badge) :: Frame
		UIKit.corner(g, 999)
		UIKit.stroke(g, col, 4, 0)
		local dot = UIKit.new("Frame", {
			Name = "Dot",
			AnchorPoint = Vector2.new(0.5, 0.5),
			Position = UDim2.fromScale(0.5, 0.5),
			Size = UDim2.fromOffset(6, 6),
			BackgroundColor3 = col,
			BorderSizePixel = 0,
		}, g)
		UIKit.corner(dot, 999)
	else
		g = Icons.Draw(a.Badge, kind == "Boss" and "skull" or "crown", {
			Name = "Glyph",
			Size = math.floor(size * 0.66),
			Color = col,
			Back = P.slate_900,
			AnchorPoint = Vector2.new(0.5, 0.5),
			Position = UDim2.fromScale(0.5, 0.5),
		})
	end
	g:SetAttribute("DangerKind", kind)
	a.Glyph = g
end

------------------------------------------------------------------------------------------
-- Targets
------------------------------------------------------------------------------------------

local function classify(body: BasePart): string?
	local typeId = body:GetAttribute("Type")
	if typeof(typeId) ~= "string" then
		return nil
	end
	local def = (EnemyData.Enemies :: any)[typeId]
	if def and def.IsBoss == true then
		return "Boss"
	end
	local mini = body:GetAttribute("MiniBoss")
	if typeof(mini) == "string" and mini ~= "" then
		return "Champion"
	end
	if body:GetAttribute("Elite") == true then
		return "Elite"
	end
	return nil
end

local function targets(from: Vector3): { Target }
	local out: { Target } = {}
	local folder = workspace:FindFirstChild("SwarmEnemies")
	if not folder then
		return out
	end
	for _, m in ipairs(folder:GetChildren()) do
		local body = m:FindFirstChild("Body")
		if body and body:IsA("BasePart") then
			local pos = body.Position
			if pos.Y >= ACTIVE_Y then
				local kind = classify(body)
				if kind then
					local flat = Vector3.new(pos.X - from.X, 0, pos.Z - from.Z)
					table.insert(out, { Kind = kind, Dist = flat.Magnitude, Pos = pos, Body = body })
				end
			end
		end
	end
	-- bosses first, then nearest
	table.sort(out, function(a, b)
		if (a.Kind == "Boss") ~= (b.Kind == "Boss") then
			return a.Kind == "Boss"
		end
		return a.Dist < b.Dist
	end)
	return out
end

------------------------------------------------------------------------------------------
-- Placement
------------------------------------------------------------------------------------------

local function addBox(out: { Box }, g: any)
	if typeof(g) ~= "Instance" or not g:IsA("GuiObject") or not g.Visible or not g.Parent then
		return
	end
	local screen = g:FindFirstAncestorOfClass("ScreenGui")
	if screen and not screen.Enabled then
		return
	end
	local p, s = g.AbsolutePosition, g.AbsoluteSize
	if s.X > 0 and s.Y > 0 then
		table.insert(out, { p.X, p.Y, p.X + s.X, p.Y + s.Y })
	end
end

-- Every rect an arrow must keep off right now.
local function blockers(): { Box }
	local out = WorldLabelFade.Rects()
	addBox(out, MiniMap.Elements().Holder)
	-- the top-right gold / kills pills and the pause button, the buff chip and the status plate
	-- (WorldLabelFade.Rects does not list them)
	local hud = Hud.Elements()
	addBox(out, hud.Counters)
	addBox(out, hud.Purse)
	addBox(out, hud.Kills and hud.Kills.Frame)
	addBox(out, hud.Pause and hud.Pause.Instance)
	addBox(out, hud.Buff)
	addBox(out, hud.Status)
	local stage = StageUI.Elements()
	addBox(out, stage.Arrow)
	local pg = player:FindFirstChild("PlayerGui")
	if pg then
		local stick = pg:FindFirstChild("SwarmStick")
		addBox(out, stick and stick:FindFirstChild("JumpButton", true))
		local fh = pg:FindFirstChild("FeatureHud")
		if fh then
			addBox(out, fh:FindFirstChild("Ultimate", true))
			local badges = fh:FindFirstChild("Badges", true)
			if badges then
				for _, c in ipairs(badges:GetChildren()) do
					addBox(out, c)
				end
			end
		end
	end
	return out
end

local function hits(b: Box, rects: { Box }): boolean
	for _, r in ipairs(rects) do
		if r[3] > b[1] - 4 and r[1] < b[3] + 4 and r[4] > b[2] - 4 and r[2] < b[4] + 4 then
			return true
		end
	end
	return false
end

-- The arrow's footprint centred on the badge at (x, y).
local function footprint(x: number, y: number): Box
	local size = tonumber(cfg().Size) or 44
	local half = size / 2 + 12 -- the badge plus its pointer
	return { x - half, y - half, x + half, y + size / 2 + 12 + TAG_H }
end

type Rect = { L: number, T: number, R: number, B: number }

-- A point on the rectangle's perimeter at distance t (clockwise from the top-left corner).
local function perimeterPoint(r: Rect, t: number): (number, number)
	local w, h = r.R - r.L, r.B - r.T
	local per = 2 * (w + h)
	t = t % per
	if t < w then
		return r.L + t, r.T
	end
	t -= w
	if t < h then
		return r.R, r.T + t
	end
	t -= h
	if t < w then
		return r.R - t, r.B
	end
	t -= w
	return r.L, r.B - t
end

local function perimeterT(r: Rect, x: number, y: number): number
	local w, h = r.R - r.L, r.B - r.T
	if math.abs(y - r.T) < 0.5 then
		return x - r.L
	elseif math.abs(x - r.R) < 0.5 then
		return w + (y - r.T)
	elseif math.abs(y - r.B) < 0.5 then
		return w + h + (r.R - x)
	end
	return 2 * w + h + (r.B - y)
end

-- Screen point (AbsolutePosition space) for one target, or nil when it needs no arrow.
local function place(t: Target, hero: Vector3, r: Rect, rects: { Box }): (number?, number?, number?)
	local cam = workspace.CurrentCamera
	if not cam then
		return nil
	end
	local vp, onScreen = cam:WorldToScreenPoint(t.Pos) -- AbsolutePosition space, like the HUD rects
	local p = Vector2.new(vp.X, vp.Y)
	local visible = onScreen and vp.Z > 0 and p.X >= r.L and p.X <= r.R and p.Y >= r.T and p.Y <= r.B
	local far = tonumber(cfg().FarStuds) or 60
	if visible and t.Dist <= far then
		return nil
	end
	local c = Vector2.new((r.L + r.R) / 2, (r.T + r.B) / 2)
	local d = p - c
	if vp.Z <= 0 then
		-- behind the camera: the ground direction instead
		local flat = Vector3.new(t.Pos.X - hero.X, 0, t.Pos.Z - hero.Z)
		local right = cam.CFrame.RightVector * Vector3.new(1, 0, 1)
		local fwd = cam.CFrame.LookVector * Vector3.new(1, 0, 1)
		if right.Magnitude > 0.01 and fwd.Magnitude > 0.01 then
			d = Vector2.new(flat:Dot(right.Unit), -flat:Dot(fwd.Unit))
		end
	end
	if d.Magnitude < 1 then
		d = Vector2.new(0, -1)
	end
	local kx = d.X ~= 0 and (((d.X > 0) and (r.R - c.X) or (r.L - c.X)) / d.X) or math.huge
	local ky = d.Y ~= 0 and (((d.Y > 0) and (r.B - c.Y) or (r.T - c.Y)) / d.Y) or math.huge
	local at = c + d * math.min(kx, ky)
	local angle = math.deg(math.atan2(d.Y, d.X))
	-- slide along the edge (both ways, nearest first) until the footprint is clear
	local t0 = perimeterT(r, at.X, at.Y)
	local per = 2 * ((r.R - r.L) + (r.B - r.T))
	local tries = math.min(80, math.floor(per / STEP / 2))
	for k = 0, tries do
		for _, sgn in ipairs(k == 0 and { 1 } or { 1, -1 }) do
			local x, y = perimeterPoint(r, t0 + sgn * k * STEP)
			if not hits(footprint(x, y), rects) then
				return x, y, angle
			end
		end
	end
	return nil
end

------------------------------------------------------------------------------------------
-- Show / hide
------------------------------------------------------------------------------------------

local function hide(a: Arrow)
	if a.Pulse then
		a.Pulse:Cancel()
		a.Pulse = nil
	end
	a.Scale.Scale = 1
	a.Holder.Visible = false
	a.Holder.GroupTransparency = 1
	a.Shown = false
	a.Body = nil
	a.Box = nil
end

local function hideAll()
	for _, a in ipairs(arrows) do
		if a.Shown then
			hide(a)
		end
	end
	table.clear(debugInfo)
end

local function show(a: Arrow, t: Target, x: number, y: number, angle: number, offX: number, offY: number)
	setKind(a, t.Kind)
	a.Tag.Text = string.format("%d m", math.floor(t.Dist + 0.5))
	local pos = UDim2.fromOffset(math.floor(x - offX + 0.5), math.floor(y - offY + TAG_H / 2 + 0.5))
	local fresh = not a.Shown or a.Body ~= t.Body
	if fresh then
		a.Holder.Position = pos
		a.Pivot.Rotation = angle
		a.Holder.Visible = true
		if not a.Shown then
			a.Holder.GroupTransparency = 1
			TweenService:Create(a.Holder, TweenInfo.new(tonumber(cfg().FadeSeconds) or 0.15, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), { GroupTransparency = 0 }):Play()
		end
	else
		local step = 1 / math.max(1, tonumber(cfg().UpdateHz) or 10)
		TweenService:Create(a.Holder, TweenInfo.new(step, Enum.EasingStyle.Linear), { Position = pos }):Play()
		-- turn the short way round
		local cur = a.Pivot.Rotation
		local goal = cur + ((angle - cur + 180) % 360 - 180)
		TweenService:Create(a.Pivot, TweenInfo.new(step, Enum.EasingStyle.Linear), { Rotation = goal }):Play()
	end
	a.Shown = true
	a.Body = t.Body
	a.X, a.Y = x, y
	-- pulse (none with Reduced effects; the arrow stays)
	if ClientSettings.Reduced() then
		if a.Pulse then
			a.Pulse:Cancel()
			a.Pulse = nil
		end
		a.Scale.Scale = 1
	elseif not a.Pulse then
		a.Scale.Scale = 1
		local tw = TweenService:Create(a.Scale, TweenInfo.new(0.55, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut, -1, true), { Scale = 1.08 })
		tw:Play()
		a.Pulse = tw
	end
end

local function allowed(): boolean
	if not on() or player:GetAttribute("InRun") ~= true or player:GetAttribute("Alive") == false then
		return false
	end
	if Remotes.State():GetAttribute("Phase") ~= "Running" then
		return false
	end
	return not Hud.BuildOpen() and not UIState.IsShown("Pause") and UIState.Owner() == nil
		and not UIState.Covered() and not UIState.SidePanelOpen()
end

local function update()
	local g, rt = gui, root
	if not g or not rt then
		return
	end
	local char = player.Character
	local hrp = char and char.PrimaryPart
	if not allowed() or not hrp then
		g.Enabled = false
		hideAll()
		return
	end
	g.Enabled = true
	local hero = hrp.Position
	local list = targets(hero)
	local size = tonumber(cfg().Size) or 44
	local margin = tonumber(cfg().EdgeMargin) or 8
	local ap, as = rt.AbsolutePosition, rt.AbsoluteSize
	local half = size / 2 + 12
	local r: Rect = {
		L = ap.X + margin + half,
		T = ap.Y + margin + half,
		R = ap.X + as.X - margin - half,
		B = ap.Y + as.Y - margin - half - TAG_H,
	}
	if r.R <= r.L or r.B <= r.T then
		hideAll()
		return
	end
	local rects = blockers()
	local maxN = math.max(0, math.floor(tonumber(cfg().MaxArrows) or 4))
	table.clear(debugInfo)
	-- keep each enemy on the arrow it already had (no swapping between refreshes)
	local placed: { [number]: { t: Target, x: number, y: number, angle: number } } = {}
	local order: { { t: Target, x: number, y: number, angle: number } } = {}
	for _, t in ipairs(list) do
		if #order >= maxN then
			break
		end
		local x, y, angle = place(t, hero, r, rects)
		if x and y and angle then
			local item = { t = t, x = x, y = y, angle = angle }
			table.insert(order, item)
			table.insert(rects, footprint(x, y))
		end
	end
	local used: { [Arrow]: boolean } = {}
	for _, item in ipairs(order) do
		for i, a in ipairs(arrows) do
			if a.Shown and a.Body == item.t.Body and not used[a] then
				used[a] = true
				placed[i] = item
				break
			end
		end
	end
	for _, item in ipairs(order) do
		local taken = false
		for _, v in pairs(placed) do
			if v == item then
				taken = true
				break
			end
		end
		if not taken then
			for i, a in ipairs(arrows) do
				if not used[a] then
					used[a] = true
					placed[i] = item
					break
				end
			end
		end
	end
	local arrowOf: { [any]: Arrow } = {}
	for i, a in ipairs(arrows) do
		local item = placed[i]
		if item then
			show(a, item.t, item.x, item.y, item.angle, ap.X, ap.Y)
			arrowOf[item] = a
		elseif a.Shown then
			hide(a)
		end
	end
	-- in priority order (boss, then nearest)
	for _, item in ipairs(order) do
		local a = arrowOf[item]
		if a then
			table.insert(debugInfo, {
				Kind = item.t.Kind,
				Dist = item.t.Dist,
				X = item.x,
				Y = item.y,
				Box = footprint(item.x, item.y),
				Glyph = a.Glyph and a.Glyph:GetAttribute("DangerKind"),
				Text = a.Tag.Text,
				Pulse = a.Pulse ~= nil,
			})
		end
	end
end

------------------------------------------------------------------------------------------
-- Public
------------------------------------------------------------------------------------------

-- The arrows on screen after the last refresh (regression scenes): { Kind, Dist, X, Y,
-- Box = { l, t, r, b }, Glyph, Text, Pulse }, plus the rects they kept off.
function DangerArrows.Debug(): ({ { [string]: any } }, { Box })
	return debugInfo, (gui and gui.Enabled) and blockers() or {}
end

-- Refresh now (regression scenes; the game refreshes UpdateHz times a second).
function DangerArrows.Refresh()
	update()
end

function DangerArrows.Init()
	if gui then
		return
	end
	local playerGui = player:WaitForChild("PlayerGui")
	local screen = UIKit.new("ScreenGui", {
		Name = "DangerArrows",
		ResetOnSpawn = false,
		IgnoreGuiInset = true,
		ScreenInsets = Enum.ScreenInsets.DeviceSafeInsets,
		DisplayOrder = 10,
		Enabled = false,
	}, playerGui) :: ScreenGui
	gui = screen
	local frame = UIKit.new("Frame", { Name = "Root", BackgroundTransparency = 1, Size = UDim2.fromScale(1, 1) }, screen) :: Frame
	root = frame
	local n = math.max(0, math.floor(tonumber(cfg().MaxArrows) or 4))
	for i = 1, n do
		table.insert(arrows, makeArrow(frame, i))
	end
	RunService.Heartbeat:Connect(function()
		local now = os.clock()
		if now - lastStep < 1 / math.max(1, tonumber(cfg().UpdateHz) or 10) then
			return
		end
		lastStep = now
		if not on() then
			if screen.Enabled then
				screen.Enabled = false
				hideAll()
			end
			return
		end
		update()
	end)
end

return DangerArrows
