--[[
	Icons.lua
	One consistent vector icon set, drawn in code (no image assets): menu icons and an icon
	for every upgrade id in IconData (weapons, evolutions, passives, Gold, Heal).

	Every icon is designed on a 24 x 24 grid (Theme.Icon) out of a few primitives:
	  box / dot      Frames with UICorner (and Rotation)
	  seg / line     rounded capsules (strokes with round caps and joins)
	  ring / arc     UIStroke circles (arcs are rings inside a clipping frame)
	  tri            a right-angled triangle (a 45 degree square in a clipping frame)
	  drop           teardrop (dot + tangent triangle: flames, drops)
	  curve          smooth Path2D stroke (falls back to capsules if Path2D is missing)
	Positions and sizes use Scale, so the shapes stay exact at any icon size.

	Colours: an icon has roles main / accent / extra (+ back for cut-outs such as eyes and
	visors, which should match what the icon sits on). Menu icons default to ivory + gold;
	item icons have designed colours from the palette. Passing opts.Color draws the icon in
	one colour (disabled states, icons on the gold primary button).

	Icons.Draw(parent, name, opts)    any icon by name ("gear", "Whip", "Whetstone", ...);
	                                  run items use their ItemData id as the icon name
	Icons.Upgrade(parent, id, opts)   upgrade icon: IconData picture if one is set, else the
	                                  vector icon, else the IconData glyph letters
	Icons.Character(parent, id, opts) class icon of a character (helmet, hat, hood, mitre)
	Icons.MetaIcon(id)                icon name of a permanent upgrade
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Theme = require(Shared:WaitForChild("Theme"))
local IconData = require(Shared:WaitForChild("IconData"))

local P = Theme.Palette
local G = Theme.Icon.Grid
local SQRT2 = math.sqrt(2)
local WHITE = Color3.new(1, 1, 1)

local Icons = {}

export type Opts = {
	Size: number?,
	Color: Color3?, -- one-colour icon
	Accent: Color3?,
	Back: Color3?, -- colour of cut-outs (the surface the icon sits on)
	Position: UDim2?,
	AnchorPoint: Vector2?,
	ZIndex: number?,
	LayoutOrder: number?,
	Name: string?,
}

type Ctx = {
	Frame: GuiObject,
	Ox: number,
	Oy: number,
	Sx: number,
	Sy: number,
	Px: number, -- pixels per grid unit
	Z: { n: number },
	main: Color3,
	accent: Color3,
	extra: Color3,
	back: Color3,
	light: Color3,
	dim: Color3,
	mono: boolean,
}

local function V(x: number, y: number): Vector2
	return Vector2.new(x, y)
end

------------------------------------------------------------------------------------------
-- Primitives (grid units; a Ctx maps them to Scale inside its frame)
------------------------------------------------------------------------------------------

local function shape(c: Ctx, cx: number, cy: number, w: number, h: number, color: Color3, alpha: number?, rot: number?): Frame
	local f = Instance.new("Frame")
	f.Name = "S"
	f.BorderSizePixel = 0
	f.AnchorPoint = Vector2.new(0.5, 0.5)
	f.Position = UDim2.fromScale((cx - c.Ox) / c.Sx, (cy - c.Oy) / c.Sy)
	f.Size = UDim2.fromScale(w / c.Sx, h / c.Sy)
	f.BackgroundColor3 = color
	f.BackgroundTransparency = alpha or 0
	f.Rotation = rot or 0
	f.Active = false
	f.Selectable = false
	c.Z.n += 1
	f.ZIndex = c.Z.n
	f.Parent = c.Frame
	return f
end

local function round(f: GuiObject, r: number, w: number, h: number)
	if r > 0 then
		local k = Instance.new("UICorner")
		k.CornerRadius = UDim.new(math.min(0.5, r / math.max(0.001, math.min(w, h))), 0)
		k.Parent = f
	end
end

-- Rectangle centred on (cx, cy), w x h, turned `rot` degrees clockwise, corner radius r.
local function box(c: Ctx, cx: number, cy: number, w: number, h: number, color: Color3, rot: number?, r: number?, alpha: number?): Frame
	local f = shape(c, cx, cy, w, h, color, alpha, rot)
	round(f, r or 0, w, h)
	return f
end

local function dot(c: Ctx, cx: number, cy: number, r: number, color: Color3, alpha: number?): Frame
	return box(c, cx, cy, r * 2, r * 2, color, 0, r, alpha)
end

-- Stroke from (x1, y1) to (x2, y2) with round caps.
local function seg(c: Ctx, x1: number, y1: number, x2: number, y2: number, w: number, color: Color3, alpha: number?): Frame
	local dx, dy = x2 - x1, y2 - y1
	local len = math.sqrt(dx * dx + dy * dy)
	return box(c, (x1 + x2) / 2, (y1 + y2) / 2, len + w, w, color, math.deg(math.atan2(dy, dx)), w / 2, alpha)
end

-- Polyline of round-capped strokes (the caps make round joins).
local function line(c: Ctx, pts: { Vector2 }, w: number, color: Color3, closed: boolean?, alpha: number?)
	for i = 1, #pts - 1 do
		seg(c, pts[i].X, pts[i].Y, pts[i + 1].X, pts[i + 1].Y, w, color, alpha)
	end
	if closed and #pts > 2 then
		seg(c, pts[#pts].X, pts[#pts].Y, pts[1].X, pts[1].Y, w, color, alpha)
	end
end

-- Circle outline: r is the radius of the stroke's centre line, w its width.
local function ring(c: Ctx, cx: number, cy: number, r: number, w: number, color: Color3, alpha: number?): Frame
	local d = math.max(0.1, 2 * r - w)
	local f = shape(c, cx, cy, d, d, color, 1, 0)
	round(f, d / 2, d, d)
	local s = Instance.new("UIStroke")
	s.Thickness = w * c.Px
	s.Color = color
	s.Transparency = alpha or 0
	s.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
	s.Parent = f
	return f
end

-- A clipping window (x0, y0)-(x1, y1); shapes drawn into the returned Ctx are cut to it.
local function clip(c: Ctx, x0: number, y0: number, x1: number, y1: number): Ctx
	local f = Instance.new("Frame")
	f.Name = "Clip"
	f.BackgroundTransparency = 1
	f.BorderSizePixel = 0
	f.ClipsDescendants = true
	f.Active = false
	f.Position = UDim2.fromScale((x0 - c.Ox) / c.Sx, (y0 - c.Oy) / c.Sy)
	f.Size = UDim2.fromScale((x1 - x0) / c.Sx, (y1 - y0) / c.Sy)
	c.Z.n += 1
	f.ZIndex = c.Z.n
	f.Parent = c.Frame
	return {
		Frame = f,
		Ox = x0,
		Oy = y0,
		Sx = x1 - x0,
		Sy = y1 - y0,
		Px = c.Px,
		Z = c.Z,
		main = c.main,
		accent = c.accent,
		extra = c.extra,
		back = c.back,
		light = c.light,
		dim = c.dim,
		mono = c.mono,
	}
end

-- Part of a ring visible through the window (x0, y0)-(x1, y1).
local function arc(c: Ctx, cx: number, cy: number, r: number, w: number, color: Color3, x0: number, y0: number, x1: number, y1: number, alpha: number?)
	ring(clip(c, x0, y0, x1, y1), cx, cy, r, w, color, alpha)
end

--[[
	Right-angled isosceles triangle. (x, y) is the middle of its base, `base` its length;
	dir = "up" | "down" | "left" | "right" is where the apex points (base / 2 away).
]]
local function tri(c: Ctx, x: number, y: number, base: number, dir: string, color: Color3, alpha: number?)
	local h = base / 2
	local sub
	if dir == "up" then
		sub = clip(c, x - h, y - h, x + h, y)
	elseif dir == "down" then
		sub = clip(c, x - h, y, x + h, y + h)
	elseif dir == "left" then
		sub = clip(c, x - h, y - h, x, y + h)
	else
		sub = clip(c, x, y - h, x + h, y + h)
	end
	local side = base / SQRT2
	box(sub, x, y, side, side, color, 45, 0, alpha)
end

-- Teardrop: a circle (cx, cy, r) with a tangent 90 degree tip pointing up.
local function drop(c: Ctx, cx: number, cy: number, r: number, color: Color3, alpha: number?)
	dot(c, cx, cy, r, color, alpha)
	tri(c, cx, cy - r / SQRT2, r * SQRT2, "up", color, alpha)
end

local function text(c: Ctx, str: string, cx: number, cy: number, w: number, h: number, color: Color3)
	local t = Instance.new("TextLabel")
	t.Name = "Glyph"
	t.BackgroundTransparency = 1
	t.AnchorPoint = Vector2.new(0.5, 0.5)
	t.Position = UDim2.fromScale((cx - c.Ox) / c.Sx, (cy - c.Oy) / c.Sy)
	t.Size = UDim2.fromScale(w / c.Sx, h / c.Sy)
	t.Text = str
	t.TextScaled = true
	t.FontFace = Theme.Font.Number
	t.TextColor3 = color
	c.Z.n += 1
	t.ZIndex = c.Z.n
	t.Parent = c.Frame
end

--[[
	Smooth stroke through `pts` (Catmull-Rom), drawn as short capsules (exact at every
	size). Icons.UsePath2D = true draws it with one Path2D instead (fewer instances; its
	stroke width does not follow UIScale everywhere, so it is off by default).
]]
Icons.UsePath2D = false
local path2DWorks: boolean? = nil
local function curve(c: Ctx, pts: { Vector2 }, w: number, color: Color3, closed: boolean?, alpha: number?)
	local n = #pts
	if n < 2 then
		return
	end
	local function tangent(i: number): Vector2
		local a = pts[i - 1] or (closed and pts[n]) or pts[i]
		local b = pts[i + 1] or (closed and pts[1]) or pts[i]
		return (b - a) / 6
	end
	if Icons.UsePath2D and path2DWorks ~= false then
		local ok, created = pcall(function()
			return Instance.new("Path2D")
		end)
		if ok and created then
			path2DWorks = true
			local path = created :: Path2D
			path.Name = "Curve"
			path.Thickness = w * c.Px
			path.Color3 = color
			path.Transparency = alpha or 0
			path.Closed = closed == true
			c.Z.n += 1
			path.ZIndex = c.Z.n
			local cps = {}
			for i, p in ipairs(pts) do
				local t = tangent(i)
				local tl = UDim2.fromScale(-t.X / c.Sx, -t.Y / c.Sy)
				local tr = UDim2.fromScale(t.X / c.Sx, t.Y / c.Sy)
				cps[i] = Path2DControlPoint.new(UDim2.fromScale((p.X - c.Ox) / c.Sx, (p.Y - c.Oy) / c.Sy), tl, tr)
			end
			path:SetControlPoints(cps)
			path.Parent = c.Frame
			return
		end
		path2DWorks = false
	end
	-- fallback: sample the same spline into short capsules
	local samples: { Vector2 } = {}
	local last = closed and n or n - 1
	for i = 1, last do
		local p0, p1 = pts[i], pts[(i % n) + 1]
		local h0, h1 = p0 + tangent(i), p1 - tangent((i % n) + 1)
		for k = 0, 3 do
			local t = k / 4
			local u = 1 - t
			table.insert(samples, p0 * (u * u * u) + h0 * (3 * u * u * t) + h1 * (3 * u * t * t) + p1 * (t * t * t))
		end
	end
	table.insert(samples, closed and pts[1] or pts[n])
	line(c, samples, w, color, false, alpha)
end

-- Sword: hilt at (hx, hy), blade towards `ang` degrees (0 = right, -90 = up).
local function sword(c: Ctx, hx: number, hy: number, ang: number, len: number, w: number, blade: Color3, guard: Color3, grip: Color3, gripLen: number?)
	local rad = math.rad(ang)
	local dx, dy = math.cos(rad), math.sin(rad)
	local gl = gripLen or len * 0.26
	-- grip and pommel behind the guard
	local gx, gy = hx - dx * (gl / 2 + w * 0.4), hy - dy * (gl / 2 + w * 0.4)
	box(c, gx, gy, gl, w * 0.78, grip, ang, w * 0.3)
	dot(c, hx - dx * (gl + w * 0.55), hy - dy * (gl + w * 0.55), w * 0.62, guard)
	-- blade with a pointed tip
	box(c, hx + dx * len / 2, hy + dy * len / 2, len, w, blade, ang, w * 0.2)
	box(c, hx + dx * len, hy + dy * len, w * 0.72, w * 0.72, blade, ang + 45, 0.1)
	-- a lighter edge line for the faceted look
	box(c, hx + dx * len * 0.52, hy + dy * len * 0.52, len * 0.86, w * 0.26, c.mono and blade or blade:Lerp(WHITE, 0.45), ang, w * 0.13)
	-- cross guard
	box(c, hx, hy, w * 0.9, w * 3.3, guard, ang, w * 0.32)
end

-- Bust silhouette (head + shoulders); (x, y) = head centre, s = scale.
local function figure(c: Ctx, x: number, y: number, s: number, color: Color3, grow: number?)
	local g = grow or 0
	dot(c, x, y, 4.2 * s + g, color)
	box(c, x, y + 11 * s, 15 * s + 2 * g, 8.6 * s + 2 * g, color, 0, 4.2 * s + g)
	box(c, x, y + 13.8 * s + g / 2, 15 * s + 2 * g, 3 * s + g, color, 0, 0)
end

------------------------------------------------------------------------------------------
-- Designed colours (used unless opts.Color asks for a one-colour icon)
------------------------------------------------------------------------------------------

-- muted versions of the item colours that have no palette family
local ARCANE = Color3.fromRGB(150, 130, 210)
local ARCANE_LIGHT = Color3.fromRGB(206, 196, 238)
local ROSE = Color3.fromRGB(206, 140, 178)
local TEAL = Color3.fromRGB(104, 178, 186)
local HOLY_BLUE = Color3.fromRGB(104, 150, 206)
local LAVENDER = Color3.fromRGB(176, 156, 214)

type Colors = { Main: Color3, Accent: Color3, Extra: Color3? }

local DEFAULT: { [string]: Colors } = {
	coin = { Main = P.gold_400, Accent = P.gold_700, Extra = P.gold_200 },
	info = { Main = P.gold_400, Accent = P.ivory_100 },
	warning = { Main = P.crimson_300, Accent = P.ivory_100 },
	heart = { Main = P.crimson_400, Accent = P.crimson_600, Extra = P.crimson_300 },
	gem = { Main = P.gold_300, Accent = P.gold_500, Extra = P.gold_200 },
	trophy = { Main = P.gold_400, Accent = P.gold_600, Extra = P.gold_200 },
	chest = { Main = P.wood_500, Accent = P.gold_400, Extra = P.wood_400 },
	pouch = { Main = P.leather_500, Accent = P.gold_400, Extra = P.leather_600 },
	gift = { Main = P.crimson_500, Accent = P.gold_400, Extra = P.crimson_400 },
	helmet = { Main = P.steel_300, Accent = P.crimson_400, Extra = P.steel_200 },
	wizardHat = { Main = P.slate_400, Accent = P.gold_400, Extra = P.slate_300 },
	hood = { Main = P.moss_400, Accent = P.crimson_500, Extra = P.moss_500 },
	mitre = { Main = P.ivory_100, Accent = P.gold_400, Extra = P.ivory_300 },
	featherCap = { Main = P.moss_400, Accent = P.ivory_200, Extra = P.leather_500 },
	goggles = { Main = P.leather_600, Accent = P.gold_500, Extra = P.amber_300 },
	minerHelm = { Main = P.steel_300, Accent = P.gold_500, Extra = P.fx_gold },
	skullHood = { Main = P.slate_700, Accent = P.ivory_200, Extra = P.fx_heal },
	aim = { Main = P.moss_200, Accent = P.gold_300, Extra = P.moss_300 },
	-- retention screens (curses, daily, leaderboards, account level)
	curse = { Main = P.ivory_200, Accent = P.crimson_400, Extra = P.crimson_300 },
	calendar = { Main = P.ivory_200, Accent = P.crimson_400, Extra = P.gold_400 },
	podium = { Main = P.gold_400, Accent = P.slate_300, Extra = P.gold_200 },
	medal = { Main = P.gold_400, Accent = P.crimson_400, Extra = P.gold_200 },
	-- weapons
	Whip = { Main = P.steel_200, Accent = P.gold_400, Extra = P.crimson_300 },
	MagicOrb = { Main = ARCANE, Accent = ARCANE_LIGHT, Extra = P.fx_arcane },
	Knives = { Main = P.steel_200, Accent = P.gold_400, Extra = P.leather_500 },
	Garlic = { Main = P.ivory_200, Accent = P.ivory_100, Extra = P.moss_300 },
	HolyWater = { Main = P.slate_200, Accent = HOLY_BLUE, Extra = P.wood_400 },
	Lightning = { Main = P.gold_300, Accent = P.amber_300, Extra = P.fx_bolt },
	Axe = { Main = P.steel_300, Accent = P.wood_400, Extra = P.gold_400 },
	Boomerang = { Main = P.wood_400, Accent = P.gold_300, Extra = P.wood_600 },
	Longbow = { Main = P.wood_400, Accent = P.steel_200, Extra = P.ivory_200 },
	Spear = { Main = P.steel_200, Accent = P.wood_400, Extra = P.gold_400 },
	Crossbow = { Main = P.steel_200, Accent = P.wood_500, Extra = P.ivory_300 },
	FrostNova = { Main = P.ice_100, Accent = P.fx_arcane, Extra = P.ice_300 },
	FireTrail = { Main = P.fx_fire, Accent = P.amber_300, Extra = P.crimson_400 },
	HealingTotem = { Main = P.wood_500, Accent = P.wood_400, Extra = P.fx_heal },
	ChainHook = { Main = P.steel_300, Accent = P.steel_600, Extra = P.steel_400 },
	Turret = { Main = P.steel_300, Accent = P.gold_500, Extra = P.steel_600 },
	SoulBolt = { Main = P.ivory_200, Accent = P.fx_heal, Extra = P.moss_200 },
	-- evolutions
	Bloodwhip = { Main = P.crimson_300, Accent = P.gold_300, Extra = P.crimson_400 },
	TwinOrbs = { Main = ARCANE, Accent = ROSE, Extra = ARCANE_LIGHT },
	ThousandEdge = { Main = P.gold_300, Accent = P.gold_500, Extra = P.gold_200 },
	SoulEater = { Main = ARCANE, Accent = P.ivory_100, Extra = ARCANE_LIGHT },
	Hellfire = { Main = P.fx_fire, Accent = P.gold_300, Extra = P.crimson_400 },
	ThunderLoop = { Main = P.gold_300, Accent = P.amber_300, Extra = P.fx_arcane },
	DeathSpiral = { Main = P.crimson_400, Accent = P.steel_300, Extra = P.crimson_300 },
	InfiniteReturn = { Main = TEAL, Accent = P.wood_400, Extra = P.gold_300 },
	Windpiercer = { Main = P.moss_300, Accent = P.gold_300, Extra = P.moss_200 },
	DragonLance = { Main = P.crimson_400, Accent = P.gold_300, Extra = P.gold_200 },
	Heartseeker = { Main = P.crimson_300, Accent = P.crimson_700, Extra = P.gold_300 },
	AbsoluteZero = { Main = P.ice_100, Accent = P.fx_holy, Extra = P.ice_300 },
	PhoenixStride = { Main = P.gold_300, Accent = P.ivory_100, Extra = P.fx_fire },
	Lifebloom = { Main = P.gold_500, Accent = P.gold_300, Extra = P.fx_heal },
	ReapersChain = { Main = P.crimson_400, Accent = P.crimson_700, Extra = P.ivory_200 },
	Bastion = { Main = P.gold_400, Accent = P.crimson_500, Extra = P.steel_600 },
	SoulStorm = { Main = P.ivory_200, Accent = P.crimson_300, Extra = P.crimson_400 },
	-- passives
	Might = { Main = P.steel_200, Accent = P.crimson_400, Extra = P.gold_400 },
	Armor = { Main = P.steel_300, Accent = P.gold_400, Extra = P.slate_500 },
	Heart = { Main = P.crimson_400, Accent = P.crimson_600, Extra = P.crimson_300 },
	SpeedBoots = { Main = P.dirt_400, Accent = P.gold_300, Extra = P.wood_700 },
	Cooldown = { Main = P.gold_300, Accent = P.wood_400, Extra = P.slate_300 },
	Area = { Main = P.gold_300, Accent = P.amber_500, Extra = P.gold_300 },
	Duplicator = { Main = LAVENDER, Accent = P.ivory_100, Extra = Color3.fromRGB(122, 108, 158) },
	Vacuum = { Main = P.crimson_400, Accent = P.steel_200, Extra = P.crimson_300 },
	Luck = { Main = P.moss_300, Accent = P.moss_500, Extra = P.moss_200 },
	Ammo = { Main = P.steel_200, Accent = P.gold_300, Extra = P.wood_400 },
	Candle = { Main = P.ivory_200, Accent = P.fx_fire, Extra = P.gold_300 },
	Growth = { Main = P.moss_300, Accent = P.dirt_500, Extra = P.moss_200 },
	Fletching = { Main = P.ivory_200, Accent = P.crimson_400, Extra = P.wood_400 },
	Precision = { Main = P.ivory_200, Accent = P.crimson_400, Extra = P.gold_400 },
	Renewal = { Main = P.moss_300, Accent = P.fx_heal, Extra = P.moss_500 },
	-- fallback cards and permanent upgrades
	Gold = { Main = P.gold_400, Accent = P.gold_700, Extra = P.gold_600 },
	Heal = { Main = P.dirt_400, Accent = P.ivory_100, Extra = P.gold_300 },
	revive = { Main = P.crimson_400, Accent = P.ivory_100, Extra = P.crimson_300 },
	portal = { Main = P.stone_300, Accent = P.fx_arcane, Extra = P.gold_400 },
	-- run items (ItemData) and loot
	Whetstone = { Main = P.stone_400, Accent = P.gold_300, Extra = P.stone_200 },
	QuickGloves = { Main = P.leather_500, Accent = P.gold_400, Extra = P.ivory_300 },
	SwiftFeather = { Main = P.ivory_200, Accent = P.gold_400, Extra = P.slate_300 },
	HeartyBread = { Main = P.gold_600, Accent = P.gold_800, Extra = P.gold_400 },
	Bandage = { Main = P.ivory_200, Accent = P.crimson_400, Extra = P.ivory_400 },
	Lodestone = { Main = P.stone_600, Accent = P.gold_300, Extra = P.stone_400 },
	KeenLens = { Main = P.gold_400, Accent = P.gold_300, Extra = P.slate_300 },
	HealingHerb = { Main = P.moss_300, Accent = P.crimson_400, Extra = P.moss_500 },
	IronPlate = { Main = P.steel_400, Accent = P.gold_400, Extra = P.steel_300 },
	BarbedMail = { Main = P.steel_400, Accent = P.crimson_400, Extra = P.steel_200 },
	StormCharm = { Main = P.slate_600, Accent = P.gold_400, Extra = P.fx_bolt },
	VolatileSpore = { Main = P.moss_400, Accent = P.fx_fire, Extra = P.moss_200 },
	GuardianWard = { Main = P.slate_300, Accent = P.gold_400, Extra = P.slate_200 },
	SpareQuiver = { Main = P.leather_500, Accent = P.steel_200, Extra = P.wood_400 },
	MagnetTotem = { Main = P.wood_500, Accent = P.crimson_400, Extra = P.slate_300 },
	HuntersEye = { Main = P.ivory_200, Accent = P.moss_400, Extra = P.crimson_300 },
	PhoenixFeather = { Main = P.fx_fire, Accent = P.gold_300, Extra = P.ivory_100 },
	CrownOfAges = { Main = P.gold_400, Accent = P.gold_600, Extra = P.crimson_400 },
	SunMedallion = { Main = P.gold_300, Accent = P.gold_500, Extra = P.gold_700 },
	shrine = { Main = P.stone_300, Accent = P.gold_400, Extra = P.stone_400 },
	altar = { Main = P.stone_300, Accent = P.wood_400, Extra = P.wood_500 },
}

------------------------------------------------------------------------------------------
-- Icon designs
------------------------------------------------------------------------------------------

local DRAW: { [string]: (Ctx) -> () } = {}

-- Menu --------------------------------------------------------------------------------

DRAW.helmet = function(c)
	-- plume
	box(c, 14.6, 3.4, 7, 3, c.accent, -16, 1.5)
	box(c, 12, 4.8, 3.2, 4.2, c.accent, 0, 1.5)
	-- great helm: rounded dome with a squared lower edge
	box(c, 12, 11.6, 14.4, 14.4, c.main, 0, 6.2)
	box(c, 12, 16.6, 14.4, 5, c.main, 0, 1.4)
	box(c, 12, 8.2, 10.4, 1.1, c.light, 0, 0.5, 0.45)
	-- T visor
	box(c, 12, 11.2, 10.6, 2.3, c.back, 0, 1)
	box(c, 12, 14.8, 2.4, 6.4, c.back, 0, 1)
end

DRAW.chevronsUp = function(c)
	line(c, { V(5.5, 12.4), V(12, 5.9), V(18.5, 12.4) }, 2.9, c.main)
	line(c, { V(5.5, 19), V(12, 12.5), V(18.5, 19) }, 2.9, c.main)
end

DRAW.tree = function(c)
	box(c, 12, 21, 3.2, 4, c.accent, 0, 0.6)
	tri(c, 12, 20, 18, "up", c.main)
	tri(c, 12, 15, 14, "up", c.main)
	tri(c, 12, 10, 10, "up", c.main)
end

DRAW.person = function(c)
	figure(c, 12, 7.6, 1, c.main)
end

DRAW.people2 = function(c)
	figure(c, 16, 6.6, 0.78, c.dim)
	figure(c, 9.4, 8.6, 0.9, c.back, 1.3)
	figure(c, 9.4, 8.6, 0.9, c.main)
end

DRAW.people3 = function(c)
	figure(c, 5.4, 7.4, 0.68, c.dim)
	figure(c, 18.6, 7.4, 0.68, c.dim)
	figure(c, 12, 8.6, 0.88, c.back, 1.3)
	figure(c, 12, 8.6, 0.88, c.main)
end

DRAW.userPlus = function(c)
	figure(c, 9.6, 7.8, 0.92, c.main)
	box(c, 19.2, 9.4, 2.4, 8, c.accent, 0, 1)
	box(c, 19.2, 9.4, 8, 2.4, c.accent, 0, 1)
end

DRAW.gear = function(c)
	for k = 0, 3 do
		box(c, 12, 12, 4.4, 20.4, c.main, k * 45, 1)
	end
	dot(c, 12, 12, 7.2, c.main)
	dot(c, 12, 12, 3, c.back)
end

DRAW.bars = function(c)
	box(c, 5.5, 16.5, 4, 7, c.main, 0, 1)
	box(c, 12, 14, 4, 12, c.main, 0, 1)
	box(c, 18.5, 11.5, 4, 17, c.main, 0, 1)
	box(c, 12, 21.6, 19, 1.4, c.main, 0, 0.7, 0.5)
end

DRAW.crown = function(c)
	box(c, 6, 12.6, 5.4, 5.4, c.main, 45, 0.6)
	box(c, 12, 10.8, 6, 6, c.main, 45, 0.6)
	box(c, 18, 12.6, 5.4, 5.4, c.main, 45, 0.6)
	box(c, 12, 15.4, 15, 5.6, c.main, 0, 0.8)
	box(c, 12, 19.4, 16, 2.4, c.mono and c.main or c.accent, 0, 1)
	local jewel = c.mono and c.back or c.accent
	dot(c, 6, 7.9, 1.4, c.mono and c.main or c.accent)
	dot(c, 12, 5.7, 1.6, c.mono and c.main or c.accent)
	dot(c, 18, 7.9, 1.4, c.mono and c.main or c.accent)
	dot(c, 12, 15.4, 1.3, jewel)
end

DRAW.skull = function(c)
	dot(c, 12, 10.6, 8.2, c.main)
	box(c, 12, 17.6, 9.4, 6.4, c.main, 0, 2)
	dot(c, 8.7, 11.2, 2.5, c.back)
	dot(c, 15.3, 11.2, 2.5, c.back)
	box(c, 12, 15.2, 2, 2, c.back, 45, 0.3)
	box(c, 10.3, 19.6, 1, 2.6, c.back, 0, 0.4)
	box(c, 13.7, 19.6, 1, 2.6, c.back, 0, 0.4)
end

-- Curse: a horned skull (crimson horns).
DRAW.curse = function(c)
	local horn = c.mono and c.main or c.accent
	box(c, 5.6, 5.6, 2.6, 7.4, horn, -32, 1.2)
	box(c, 18.4, 5.6, 2.6, 7.4, horn, 32, 1.2)
	dot(c, 12, 11.4, 7.6, c.main)
	box(c, 12, 18, 8.6, 5.8, c.main, 0, 2)
	box(c, 8.9, 11.6, 3.6, 2.2, c.back, 18, 1)
	box(c, 15.1, 11.6, 3.6, 2.2, c.back, -18, 1)
	box(c, 12, 15.4, 1.8, 1.8, c.back, 45, 0.3)
	box(c, 10.4, 19.8, 1, 2.4, c.back, 0, 0.4)
	box(c, 13.6, 19.8, 1, 2.4, c.back, 0, 0.4)
end

-- Calendar page with a red header and a gold day mark.
DRAW.calendar = function(c)
	box(c, 12, 13.4, 17.6, 15.6, c.main, 0, 2.2)
	box(c, 12, 7.4, 17.6, 4.2, c.mono and c.main or c.accent, 0, 1.6)
	box(c, 7.6, 4.2, 2, 4.4, c.mono and c.main or c.light, 0, 1)
	box(c, 16.4, 4.2, 2, 4.4, c.mono and c.main or c.light, 0, 1)
	for row = 0, 2 do
		for col = 0, 3 do
			local x, y = 6.9 + col * 3.4, 12 + row * 3.2
			if row == 1 and col == 2 then
				box(c, x, y, 2.6, 2.4, c.mono and c.back or c.extra, 0, 0.6)
			else
				box(c, x, y, 2.2, 1.8, c.back, 0, 0.5, 0.35)
			end
		end
	end
end

-- Podium: three steps, a star over the top one.
DRAW.podium = function(c)
	box(c, 12, 16.4, 6.4, 11.2, c.main, 0, 0.8)
	box(c, 5.6, 18.4, 6, 7.2, c.mono and c.main or c.accent, 0, 0.8)
	box(c, 18.4, 19.4, 6, 5.2, c.mono and c.main or c.accent, 0, 0.8)
	box(c, 12, 15, 2, 4.6, c.back, 0, 0.5, 0.3)
	box(c, 12, 5.6, 4.6, 4.6, c.mono and c.main or c.extra, 45, 0.6)
	box(c, 12, 5.6, 4.6, 4.6, c.mono and c.main or c.extra, 0, 0.6)
end

-- Medal: two ribbons and a gold disc with a star mark (the account level).
DRAW.medal = function(c)
	local ribbon = c.mono and c.main or c.accent
	box(c, 9, 6, 3.6, 9, ribbon, -24, 0.6)
	box(c, 15, 6, 3.6, 9, ribbon, 24, 0.6)
	dot(c, 12, 15, 7, c.main)
	ring(c, 12, 15, 4.9, 1.2, c.mono and c.back or c.extra)
	box(c, 12, 15, 3.6, 3.6, c.mono and c.back or c.extra, 45, 0.4)
	box(c, 12, 15, 3.6, 3.6, c.mono and c.back or c.extra, 0, 0.4)
end

DRAW.coin = function(c)
	local detail = c.mono and c.back or c.accent
	dot(c, 12, 12, 9, c.main)
	ring(c, 12, 12, 6.4, 1.5, detail)
	box(c, 12, 12, 4.6, 4.6, detail, 45, 0.6)
	if not c.mono then
		box(c, 8.4, 7.6, 3.4, 1.5, c.extra, -40, 0.75, 0.25)
	end
end

DRAW.lock = function(c)
	ring(c, 12, 9.6, 4.8, 2.6, c.main)
	box(c, 12, 15.8, 14.6, 10.4, c.main, 0, 2.2)
	dot(c, 12, 14.8, 1.9, c.back)
	box(c, 12, 17.4, 1.5, 3.6, c.back, 0, 0.7)
end

DRAW.check = function(c)
	line(c, { V(4.8, 12.6), V(9.8, 17.6), V(19.4, 6.8) }, 3.2, c.main)
end

DRAW.chevronRight = function(c)
	line(c, { V(9, 4.8), V(16.2, 12), V(9, 19.2) }, 3.2, c.main)
end

DRAW.chevronLeft = function(c)
	line(c, { V(15, 4.8), V(7.8, 12), V(15, 19.2) }, 3.2, c.main)
end

DRAW.arrowRight = function(c)
	seg(c, 4.4, 12, 18.4, 12, 2.8, c.main)
	line(c, { V(12.4, 6), V(18.6, 12), V(12.4, 18) }, 2.8, c.main)
end

DRAW.arrowLeft = function(c)
	seg(c, 5.6, 12, 19.6, 12, 2.8, c.main)
	line(c, { V(11.6, 6), V(5.4, 12), V(11.6, 18) }, 2.8, c.main)
end

DRAW.close = function(c)
	seg(c, 6, 6, 18, 18, 3.2, c.main)
	seg(c, 18, 6, 6, 18, 3.2, c.main)
end

DRAW.pause = function(c)
	box(c, 8.4, 12, 4.4, 15.6, c.main, 0, 1.3)
	box(c, 15.6, 12, 4.4, 15.6, c.main, 0, 1.3)
end

DRAW.play = function(c)
	tri(c, 8.4, 12, 16, "right", c.main)
end

DRAW.heart = function(c)
	dot(c, 8.32, 9.4, 5.2, c.main)
	dot(c, 15.68, 9.4, 5.2, c.main)
	box(c, 12, 13.08, 10.4, 10.4, c.main, 45, 0.8)
	if not c.mono then
		box(c, 7.4, 7.6, 3.2, 1.6, c.extra, -45, 0.8, 0.3)
	end
end

DRAW.plus = function(c)
	box(c, 12, 12, 3.2, 15, c.main, 0, 1.2)
	box(c, 12, 12, 15, 3.2, c.main, 0, 1.2)
end

DRAW.sword = function(c)
	sword(c, 7.6, 16.4, -45, 12.6, 2.9, c.main, c.accent, c.mono and c.main or P.leather_500)
end

DRAW.shield = function(c)
	local face = c.mono and c.dim or c.main
	local rim = c.mono and c.main or c.accent
	box(c, 12, 8.8, 15, 10.4, rim, 0, 2.2)
	tri(c, 12, 13.2, 15, "down", rim)
	box(c, 12, 9.2, 12.4, 8.6, face, 0, 1.6)
	tri(c, 12, 13, 12.4, "down", face)
	local cross = c.mono and c.main or c.extra
	box(c, 12, 11.4, 2.2, 8.4, cross, 0, 0.6)
	box(c, 12, 9.6, 7.6, 2.2, cross, 0, 0.6)
end

DRAW.boot = function(c)
	box(c, 4.2, 8.6, 4, 1.5, c.accent, 0, 0.75)
	box(c, 3.2, 12, 5, 1.5, c.accent, 0, 0.75)
	box(c, 4.2, 15.4, 4, 1.5, c.accent, 0, 0.75)
	box(c, 11.4, 9.6, 6.4, 11, c.main, 0, 1.2)
	box(c, 14.6, 16.6, 12.8, 5.4, c.main, 0, 2.4)
	box(c, 14.6, 19.8, 13.4, 1.8, c.mono and c.dim or c.extra, 0, 0.9)
	box(c, 11.4, 4.6, 7.4, 2.2, c.accent, 0, 0.9)
end

DRAW.hourglass = function(c)
	local frame = c.mono and c.main or c.accent
	box(c, 5.6, 12, 1.6, 15, frame, 0, 0.8)
	box(c, 18.4, 12, 1.6, 15, frame, 0, 0.8)
	tri(c, 12, 5.4, 11, "down", c.extra, 0.55)
	tri(c, 12, 18.6, 11, "up", c.extra, 0.55)
	tri(c, 12, 7.8, 6.2, "down", c.main)
	tri(c, 12, 18.6, 9, "up", c.main)
	box(c, 12, 12.2, 1.2, 2.8, c.main, 0, 0.5)
	box(c, 12, 3.8, 15, 2.2, frame, 0, 1)
	box(c, 12, 20.2, 15, 2.2, frame, 0, 1)
end

DRAW.area = function(c)
	ring(c, 12, 12, 5.6, 1.8, c.main, 0.15)
	dot(c, 12, 12, 2.2, c.accent)
	line(c, { V(3.4, 8.2), V(3.4, 3.4), V(8.2, 3.4) }, 2.2, c.main)
	line(c, { V(15.8, 3.4), V(20.6, 3.4), V(20.6, 8.2) }, 2.2, c.main)
	line(c, { V(20.6, 15.8), V(20.6, 20.6), V(15.8, 20.6) }, 2.2, c.main)
	line(c, { V(8.2, 20.6), V(3.4, 20.6), V(3.4, 15.8) }, 2.2, c.main)
end

DRAW.duplicate = function(c)
	box(c, 14.6, 9.4, 11.4, 11.4, c.mono and c.dim or c.extra, 0, 2.2)
	box(c, 9.4, 14.6, 13.6, 13.6, c.back, 0, 3)
	box(c, 9.4, 14.6, 11.4, 11.4, c.main, 0, 2.2)
	box(c, 9.4, 14.6, 1.9, 6.4, c.back, 0, 0.6)
	box(c, 9.4, 14.6, 6.4, 1.9, c.back, 0, 0.6)
end

DRAW.magnet = function(c)
	arc(c, 12, 11, 6, 4.4, c.main, 2, 11, 22, 21)
	box(c, 6, 7, 4.4, 8, c.main)
	box(c, 18, 7, 4.4, 8, c.main)
	box(c, 6, 4.2, 4.4, 2.6, c.accent, 0, 0.4)
	box(c, 18, 4.2, 4.4, 2.6, c.accent, 0, 0.4)
end

DRAW.clover = function(c)
	seg(c, 12.6, 14, 16.4, 21.4, 1.9, c.mono and c.main or c.accent)
	dot(c, 12, 7.4, 4.2, c.main)
	dot(c, 16.6, 12, 4.2, c.main)
	dot(c, 12, 16.6, 4.2, c.main)
	dot(c, 7.4, 12, 4.2, c.main)
	dot(c, 12, 12, 2.4, c.mono and c.back or c.accent)
end

DRAW.arrowFast = function(c)
	box(c, 4.8, 7.2, 4.6, 1.5, c.accent, 0, 0.75, 0.3)
	box(c, 3.8, 16.8, 4.6, 1.5, c.accent, 0, 0.75, 0.3)
	seg(c, 5.6, 12, 15.4, 12, 2.2, c.mono and c.main or c.extra)
	tri(c, 14.4, 12, 9.4, "right", c.main)
	seg(c, 6.2, 12, 3.2, 9, 1.7, c.accent)
	seg(c, 6.2, 12, 3.2, 15, 1.7, c.accent)
end

DRAW.candle = function(c)
	box(c, 12, 21, 11, 2.2, c.mono and c.main or c.extra, 0, 1.1)
	box(c, 12, 15.4, 6.4, 10, c.main, 0, 1.2)
	box(c, 10.2, 12.6, 1.6, 3.8, c.mono and c.back or c.light, 0, 0.8, c.mono and 0.4 or 0)
	seg(c, 12, 8.8, 12, 10.4, 0.9, c.back)
	drop(c, 12, 7, 2.4, c.accent)
	if not c.mono then
		dot(c, 12, 7.4, 1.1, P.gold_200)
	end
end

DRAW.sprout = function(c)
	box(c, 12, 20.6, 13, 2.6, c.mono and c.main or c.accent, 0, 1.3)
	seg(c, 12, 19.5, 12, 10.4, 2, c.main)
	box(c, 8.4, 11.2, 7.8, 4.4, c.main, 28, 2.2)
	box(c, 15.6, 8.6, 8.2, 4.6, c.mono and c.main or c.extra, -28, 2.3)
end

DRAW.gem = function(c)
	box(c, 12, 12, 12.4, 12.4, c.accent, 45, 1)
	box(c, 12, 9.6, 6.4, 6.4, c.mono and c.back or c.main, 45, 0.5, c.mono and 0.5 or 0)
	if not c.mono then
		box(c, 9.2, 9.4, 1.8, 1.8, c.extra, 45, 0.3)
	end
end

DRAW.cycle = function(c)
	arc(c, 12, 12, 7, 2.6, c.main, 1, 1, 23, 11)
	arc(c, 12, 12, 7, 2.6, c.main, 1, 13, 23, 23)
	tri(c, 19, 10.2, 6.4, "down", c.main)
	tri(c, 5, 13.8, 6.4, "up", c.main)
end

DRAW.skip = function(c)
	tri(c, 4.4, 12, 12, "right", c.main)
	tri(c, 10.4, 12, 12, "right", c.main)
	box(c, 18.4, 12, 2.8, 12, c.main, 0, 0.8)
end

DRAW.sparkle = function(c)
	box(c, 12, 12, 2.8, 19, c.main, 0, 1.4)
	box(c, 12, 12, 19, 2.8, c.main, 0, 1.4)
	box(c, 12, 12, 7.4, 7.4, c.main, 45, 0.8)
	dot(c, 19, 5, 1.4, c.accent)
	dot(c, 5, 19, 1.1, c.accent)
end

DRAW.trophy = function(c)
	ring(c, 5.8, 8.6, 3, 1.8, c.main)
	ring(c, 18.2, 8.6, 3, 1.8, c.main)
	box(c, 12, 8.8, 11.6, 10, c.main, 0, 3.6)
	box(c, 12, 4.8, 13.2, 2.4, c.main, 0, 1)
	box(c, 12, 15.6, 2.6, 4, c.mono and c.main or c.accent, 0, 0.4)
	box(c, 12, 18.6, 8.4, 2.2, c.main, 0, 0.8)
	box(c, 12, 20.6, 11, 2.2, c.mono and c.main or c.accent, 0, 1)
	box(c, 12, 8.6, 3.2, 3.2, c.mono and c.back or c.extra, 45, 0.4)
end

DRAW.flag = function(c)
	box(c, 5.8, 12, 2, 19, c.main, 0, 1)
	box(c, 12.6, 8, 12, 8.4, c.accent, 0, 1)
	tri(c, 18.7, 8, 8.4, "left", c.back)
end

DRAW.music = function(c)
	dot(c, 6.6, 18.2, 3.2, c.main)
	dot(c, 16.4, 16.2, 3.2, c.main)
	box(c, 9, 11, 1.8, 14.4, c.main, 0, 0.5)
	box(c, 18.8, 9, 1.8, 14.4, c.main, 0, 0.5)
	box(c, 13.9, 4.6, 11.6, 3, c.main, -11.5, 0.6)
end

DRAW.speaker = function(c)
	box(c, 6, 12, 4.6, 7, c.main, 0, 1)
	tri(c, 13.2, 12, 14, "left", c.main)
	arc(c, 13.2, 12, 4.4, 1.9, c.main, 15.4, 6, 20, 18)
	arc(c, 13.2, 12, 8, 1.9, c.main, 18.6, 2, 23, 22)
end

DRAW.robux = function(c)
	box(c, 12, 12, 19, 19, c.main, 0, 4.4, 0.8)
	text(c, "R$", 12, 12.4, 17, 13.5, c.main)
end

DRAW.bag = function(c)
	arc(c, 12, 9, 4.4, 2.2, c.main, 6, 2, 18, 9.4)
	box(c, 12, 15, 16, 12, c.main, 0, 2.6)
	box(c, 12, 12.6, 16, 1.4, c.back, 0, 0, 0.4)
end

-- Information: a ring with an "i" (tips).
DRAW.info = function(c)
	ring(c, 12, 12, 8.6, 2.4, c.main)
	dot(c, 12, 7.6, 1.6, c.accent)
	box(c, 12, 13.8, 2.6, 6.8, c.accent, 0, 1.1)
end

-- Warning: a ring with an "!" (save problems, alerts).
DRAW.warning = function(c)
	ring(c, 12, 12, 8.6, 2.4, c.main)
	box(c, 12, 10.2, 2.6, 7.4, c.accent, 0, 1.2)
	dot(c, 12, 16.4, 1.6, c.accent)
end

DRAW.clock = function(c)
	ring(c, 12, 12, 8.4, 2.4, c.main)
	seg(c, 12, 12, 12, 7, 2.2, c.main)
	seg(c, 12, 12, 15.6, 14, 2.2, c.main)
end

-- Stage portal: stone ring on two plinths with a glowing membrane and a gold keystone.
DRAW.portal = function(c)
	dot(c, 12, 10.6, 5.6, c.accent, c.mono and 0.6 or 0.25)
	ring(c, 12, 10.6, 7.6, 2.6, c.main)
	box(c, 5.6, 19, 4.4, 4.4, c.main, 0, 0.8)
	box(c, 18.4, 19, 4.4, 4.4, c.main, 0, 0.8)
	box(c, 12, 22.2, 21, 1.8, c.main, 0, 0.8)
	box(c, 12, 3.1, 3.2, 3.2, c.mono and c.main or c.extra, 45, 0.5)
	dot(c, 12, 10.6, 2.2, c.mono and c.back or c.light, c.mono and 0 or 0.35)
end

DRAW.castle = function(c)
	box(c, 12, 15.6, 15, 9.8, c.main, 0, 0.4)
	box(c, 5.2, 12.6, 5.2, 15.8, c.main, 0, 0.4)
	box(c, 18.8, 12.6, 5.2, 15.8, c.main, 0, 0.4)
	for _, x in ipairs({ 3.6, 6.8, 17.2, 20.4 }) do
		box(c, x, 3.6, 2, 2.6, c.main)
	end
	for _, x in ipairs({ 9.6, 14.4 }) do
		box(c, x, 9.6, 2, 2.6, c.main)
	end
	box(c, 12, 17.6, 4.8, 6.6, c.back, 0, 2.4)
	box(c, 12, 19.6, 4.8, 2.6, c.back)
end

DRAW.chest = function(c)
	box(c, 12, 15.8, 18, 9, c.main, 0, 1)
	box(c, 12, 9.4, 18, 6.4, c.mono and c.main or c.extra, 0, 3)
	local band = c.mono and c.back or c.accent
	box(c, 12, 12.4, 18.6, 1.6, band)
	box(c, 5, 14.2, 1.8, 12.2, band)
	box(c, 19, 14.2, 1.8, 12.2, band)
	box(c, 12, 13.8, 3.8, 4.6, band, 0, 0.6)
	dot(c, 12, 14, 0.9, c.mono and c.main or c.back)
end

DRAW.pouch = function(c)
	dot(c, 12, 15.2, 7, c.main)
	box(c, 12, 8.8, 6.4, 4, c.main, 0, 1.2)
	box(c, 12, 6.2, 9.4, 3, c.mono and c.main or c.extra, 0, 1.5)
	local tie = c.mono and c.back or c.accent
	box(c, 12, 9, 7.8, 1.6, tie, 0, 0.8)
	dot(c, 12, 15.6, 3, tie)
	box(c, 12, 15.6, 1.8, 1.8, c.main, 45)
end

DRAW.gift = function(c)
	box(c, 12, 15.8, 16, 9.6, c.main, 0, 1)
	box(c, 12, 9.6, 18, 3.8, c.mono and c.main or c.extra, 0, 0.8)
	local ribbon = c.mono and c.back or c.accent
	box(c, 12, 14.6, 2.8, 13.6, ribbon)
	box(c, 9.2, 5.6, 5.8, 2.8, ribbon, 24, 1.4)
	box(c, 14.8, 5.6, 5.8, 2.8, ribbon, -24, 1.4)
	dot(c, 12, 6.8, 1.7, ribbon)
end

DRAW.wizardHat = function(c)
	box(c, 12, 18.4, 20, 3.6, c.main, 0, 1.8)
	box(c, 12, 14, 10.4, 6.4, c.main, 0, 0.8)
	box(c, 12.9, 9.2, 7.4, 5.4, c.main, 0, 0.8)
	box(c, 14, 5.2, 4.4, 4.4, c.main, 0, 0.8)
	box(c, 15.6, 2.9, 2.6, 2.6, c.main, 20, 0.6)
	box(c, 12, 15.4, 10.6, 2.2, c.mono and c.back or c.accent, 0, 0.4)
	if not c.mono then
		box(c, 12, 15.4, 2.2, 2.2, P.gold_200, 45)
	end
end

DRAW.hood = function(c)
	box(c, 12, 4.4, 4.4, 4.4, c.main, 45, 0.6)
	dot(c, 12, 12, 8.2, c.main)
	box(c, 12, 18.6, 15, 5, c.main, 0, 1.4)
	dot(c, 12, 12.8, 4.8, c.back)
	box(c, 12, 16, 9.8, 3, c.mono and c.main or c.accent, 0, 1.2)
	if not c.mono then
		dot(c, 10.2, 11.8, 0.9, P.gold_300)
		dot(c, 13.8, 11.8, 0.9, P.gold_300)
	end
end

DRAW.mitre = function(c)
	box(c, 12, 14.6, 11, 10, c.main, 0, 0.8)
	tri(c, 12, 10, 11, "up", c.main)
	local gold = c.mono and c.back or c.accent
	box(c, 12, 19.4, 12, 2.4, gold, 0, 0.6)
	box(c, 12, 12.6, 1.8, 7, gold, 0, 0.4)
	box(c, 12, 11.4, 5.4, 1.8, gold, 0, 0.4)
end

DRAW.revive = function(c)
	DRAW.heart(c)
	local plus = c.mono and c.back or c.accent
	box(c, 12, 12, 2.2, 7.4, plus, 0, 0.8)
	box(c, 12, 12, 7.4, 2.2, plus, 0, 0.8)
end

-- Weapons -------------------------------------------------------------------------------

DRAW.Whip = function(c)
	arc(c, 15, 15, 10, 2.4, c.extra, 1, 1, 15, 15, 0.1)
	arc(c, 15, 15, 7, 1.2, c.extra, 1, 1, 15, 15, 0.5)
	sword(c, 6.6, 17.4, -45, 13.4, 2.8, c.main, c.accent, c.mono and c.main or P.leather_500)
end

DRAW.MagicOrb = function(c)
	ring(c, 12, 12, 9.4, 1.4, c.extra, 0.45)
	dot(c, 12, 12, 6.6, c.main)
	dot(c, 10.4, 10.2, 3.2, c.accent, 0.35)
	dot(c, 9.4, 9.2, 1.3, c.mono and c.back or P.ivory_100)
	box(c, 19.6, 4.6, 2.6, 2.6, c.accent, 45)
	box(c, 4.4, 19.4, 2, 2, c.accent, 45)
end

DRAW.Knives = function(c)
	local grip = c.mono and c.main or c.extra
	box(c, 3.6, 6.8, 3.6, 1.3, c.main, 0, 0.65, 0.45)
	box(c, 3, 13.2, 3, 1.3, c.main, 0, 0.65, 0.45)
	sword(c, 7.4, 12.4, -38, 10, 2.5, c.main, c.accent, grip, 2.8)
	sword(c, 10.6, 19.6, -38, 10, 2.5, c.main, c.accent, grip, 2.8)
end

DRAW.Garlic = function(c)
	ring(c, 12, 12, 10, 1.3, c.main, 0.55)
	ring(c, 12, 12, 7, 1.6, c.main, 0.25)
	dot(c, 12, 13.4, 3.8, c.accent)
	box(c, 12, 10.2, 3, 3, c.accent, 45, 0.3)
	seg(c, 12, 9.4, 12.8, 7, 1.1, c.mono and c.accent or c.extra)
	seg(c, 10.6, 12, 10.6, 15.4, 0.6, c.mono and c.back or P.ivory_400)
	seg(c, 13.4, 12, 13.4, 15.4, 0.6, c.mono and c.back or P.ivory_400)
end

DRAW.HolyWater = function(c)
	dot(c, 12, 15, 6.8, c.main)
	box(c, 12, 7.6, 4.2, 5.4, c.main, 0, 0.8)
	box(c, 12, 4.4, 5, 2.4, c.mono and c.main or c.extra, 0, 0.8)
	dot(c, 12, 15.8, 5.2, c.mono and c.back or c.accent)
	box(c, 12, 12.4, 10, 2.4, c.main)
	if not c.mono then
		box(c, 12, 16.8, 1.4, 4.4, P.ivory_100, 0, 0.3, 0.2)
		box(c, 12, 16, 3.6, 1.4, P.ivory_100, 0, 0.3, 0.2)
		dot(c, 8.6, 14.4, 1.1, P.ivory_100, 0.3)
	end
end

DRAW.Lightning = function(c)
	local bolt = { V(15.4, 2.6), V(8.4, 12.6), V(14.4, 12.6), V(8, 21.6) }
	if not c.mono then
		line(c, bolt, 6, c.extra, false, 0.78)
	end
	line(c, bolt, 3.4, c.main)
	line(c, { V(14.2, 5.6), V(10.6, 10.8) }, 1, c.mono and c.main or P.ivory_100, false, 0.3)
end

DRAW.Axe = function(c)
	seg(c, 12, 4.4, 12, 21.4, 2.2, c.accent)
	local blade = c.main
	-- double-bit head: two broad rounded blades flaring out from the socket
	for _, sx in ipairs({ -1, 1 }) do
		box(c, 12 + sx * 5.6, 9.2, 6.4, 11.6, blade, sx * 8, 3.2)
		box(c, 12 + sx * 3.4, 9.2, 3.6, 6.4, blade, 0, 0.4)
		box(c, 12 + sx * 8.2, 9.2, 1.2, 9, c.mono and blade or P.steel_200, sx * 8, 0.6)
	end
	box(c, 12, 9.2, 4.2, 6.2, c.mono and c.main or P.steel_500, 0, 0.6)
	dot(c, 12, 3.6, 1.6, c.mono and c.main or c.extra)
	box(c, 12, 21.2, 2.8, 1.6, c.mono and c.main or c.extra, 0, 0.5)
end

DRAW.Boomerang = function(c)
	seg(c, 6.2, 12.6, 16.8, 4.6, 4.2, c.main)
	seg(c, 6.2, 12.6, 16.8, 20.4, 4.2, c.main)
	seg(c, 8.6, 10.6, 13.6, 6.9, 1.1, c.accent)
	seg(c, 8.6, 14.6, 13.6, 18.3, 1.1, c.accent)
	arc(c, 9, 12.4, 12.4, 1.2, c.accent, 18.4, 1, 23.6, 23.6, 0.55)
end

-- Bow (limbs bulging left, string at x = 14) and an arrow across it toward +x.
local function bow(c: Ctx, wood: Color3, str: Color3, arrowColor: Color3, head: Color3)
	local pts = {}
	for i = 0, 10 do
		local t = i / 10
		local a = math.pi * (0.5 + t) -- 90..270 degrees: the left half of an ellipse
		table.insert(pts, V(14 + math.cos(a) * 9.4, 12 - math.sin(a) * 9.6))
	end
	line(c, pts, 2.4, wood)
	seg(c, 14, 2.4, 14, 21.6, 0.7, str)
	seg(c, 3.4, 12, 18.6, 12, 1.3, arrowColor)
	box(c, 19.6, 12, 3.4, 3.4, head, 45, 0.3)
	seg(c, 3.2, 12, 1.6, 9.6, 1, c.mono and arrowColor or P.crimson_400)
	seg(c, 3.2, 12, 1.6, 14.4, 1, c.mono and arrowColor or P.crimson_400)
end

DRAW.Longbow = function(c)
	bow(c, c.main, c.extra, c.mono and c.main or P.wood_500, c.accent)
end

-- Evolutions ----------------------------------------------------------------------------

DRAW.Windpiercer = function(c)
	for _, dy in ipairs({ -5.5, 5.5 }) do
		seg(c, 6, 12 + dy * 0.4, 18.4, 12 + dy, 1, c.extra, 0.35)
	end
	bow(c, c.main, c.mono and c.main or P.ivory_100, c.main, c.accent)
	dot(c, 21, 5.2, 1.2, c.extra)
	dot(c, 21, 18.8, 1.2, c.extra)
end

DRAW.Bloodwhip = function(c)
	arc(c, 15, 15, 10.4, 3, c.extra, 1, 1, 15, 15)
	arc(c, 15, 15, 7, 1.4, c.extra, 1, 1, 15, 15, 0.45)
	sword(c, 6.6, 17.4, -45, 13.4, 3, c.main, c.accent, c.mono and c.main or P.crimson_700)
	drop(c, 19.4, 19, 2.2, c.extra)
end

DRAW.TwinOrbs = function(c)
	ring(c, 12, 12, 10, 1.2, c.extra, 0.5)
	dot(c, 8.4, 13.6, 5.2, c.main)
	dot(c, 7.2, 12.2, 1.2, c.mono and c.back or P.ivory_100)
	dot(c, 15.8, 10, 5.2, c.accent)
	dot(c, 14.6, 8.6, 1.2, c.mono and c.back or P.ivory_100)
end

DRAW.ThousandEdge = function(c)
	for _, a in ipairs({ -84, -50, -16 }) do
		sword(c, 5.6, 18.6, a, 12, 2.3, c.main, c.accent, c.mono and c.main or P.gold_600, 2.4)
	end
	box(c, 19.8, 4.2, 2.4, 2.4, c.extra, 45)
end

DRAW.SoulEater = function(c)
	ring(c, 12, 12, 9.6, 2.2, c.main)
	ring(c, 12, 12, 6.8, 1, c.main, 0.5)
	dot(c, 12, 11.2, 3.6, c.accent)
	box(c, 12, 14.2, 4, 2.6, c.accent, 0, 0.8)
	dot(c, 10.6, 11.4, 1, c.back)
	dot(c, 13.4, 11.4, 1, c.back)
	dot(c, 20.6, 7.4, 1.2, c.extra)
	dot(c, 3.6, 16.6, 1, c.extra)
end

DRAW.Hellfire = function(c)
	drop(c, 6.8, 14.8, 2.2, c.extra)
	drop(c, 17.4, 14, 1.9, c.extra)
	drop(c, 12, 14.8, 6.4, c.extra)
	drop(c, 12, 16.2, 4.6, c.mono and c.back or c.main)
	drop(c, 12, 17.6, 2.6, c.mono and c.main or c.accent)
end

DRAW.ThunderLoop = function(c)
	ring(c, 12, 12, 9.6, 1.8, c.extra, 0.15)
	local bolt = { V(13.8, 4.6), V(9.2, 12.4), V(13.6, 12.4), V(9.8, 19.4) }
	if not c.mono then
		line(c, bolt, 5, c.extra, false, 0.8)
	end
	line(c, bolt, 2.8, c.main)
end

DRAW.DeathSpiral = function(c)
	local pts = {}
	for i = 0, 18 do
		local t = i / 18
		local a = t * math.pi * 3.1 + 0.6
		local r = 1.2 + t * 8.4
		table.insert(pts, V(12 + math.cos(a) * r, 12 + math.sin(a) * r))
	end
	curve(c, pts, 2.2, c.main)
	local tip = pts[#pts]
	box(c, tip.X, tip.Y, 4.6, 4.6, c.accent, 20, 0.8)
	box(c, 18.8, 16.4, 3.2, 3.2, c.accent, 40, 0.6)
	dot(c, 12, 12, 1.6, c.mono and c.main or c.extra)
end

DRAW.InfiniteReturn = function(c)
	local pts = {}
	for i = 0, 23 do
		local t = i / 24 * math.pi * 2
		local s, co = math.sin(t), math.cos(t)
		local d = 1 + s * s
		table.insert(pts, V(12 + 9.4 * co / d, 13 + 9.4 * s * co / d))
	end
	curve(c, pts, 2.2, c.main, true)
	seg(c, 9.4, 4.8, 13.2, 2.6, 1.9, c.accent)
	seg(c, 9.4, 4.8, 13.2, 7, 1.9, c.accent)
	dot(c, 19.4, 4.2, 1.1, c.mono and c.main or c.extra)
end

-- Passives ------------------------------------------------------------------------------

DRAW.Might = function(c)
	local grip = c.mono and c.main or c.accent
	local guard = c.mono and c.main or c.extra
	sword(c, 6.8, 17.2, -45, 12.6, 2.6, c.main, guard, grip)
	sword(c, 17.2, 17.2, -135, 12.6, 2.6, c.main, guard, grip)
end

DRAW.Armor = DRAW.shield

DRAW.Fletching = function(c)
	-- a long feather (vane + spine) over an arrow shaft
	box(c, 13, 10.6, 6.4, 15, c.main, 40, 3.2)
	seg(c, 7.2, 17.6, 18.4, 4.2, 1, c.mono and c.back or c.extra)
	if not c.mono then
		seg(c, 11.6, 8.4, 15.2, 10.6, 0.7, c.accent)
		seg(c, 9.4, 11, 13, 13.2, 0.7, c.accent)
	end
	seg(c, 4, 20.6, 8, 16.4, 1.6, c.mono and c.main or c.extra)
end

DRAW.featherCap = function(c)
	-- the Ranger's peaked cap with a long feather
	box(c, 11, 13.6, 14.8, 8.4, c.main, -10, 4)
	box(c, 11.4, 18, 19, 2.6, c.mono and c.main or c.extra, -4, 1.3)
	tri(c, 19.6, 15.6, 5, "right", c.main)
	seg(c, 13, 11, 21.2, 3, 2.2, c.accent)
	if not c.mono then
		seg(c, 14.6, 9.4, 20.2, 3.8, 0.6, P.ivory_400)
	end
end

-- Weapons added with the Alchemist / Engineer / Necromancer ---------------------------

-- A spear along the diagonal, head toward the top right.
local function spearIcon(c: Ctx, shaft: Color3, head: Color3, collar: Color3)
	seg(c, 3.4, 20.6, 15.4, 8.6, 1.8, shaft)
	seg(c, 4.6, 19.4, 7.4, 16.6, 2.6, c.mono and shaft or P.leather_600)
	box(c, 18, 6, 7.6, 3.6, head, -45, 1.5)
	box(c, 18.2, 5.8, 5.4, 0.9, c.mono and head or head:Lerp(WHITE, 0.45), -45, 0.4)
	box(c, 14.8, 9.2, 4.4, 1.7, collar, 45, 0.6)
end

DRAW.Spear = function(c)
	spearIcon(c, c.accent, c.main, c.extra)
end

DRAW.DragonLance = function(c)
	spearIcon(c, c.mono and c.main or P.crimson_700, c.main, c.accent)
	for _, d in ipairs({ { 21.4, 9.4, 1.3 }, { 14.6, 2.6, 1.3 }, { 22, 3, 1 } }) do
		dot(c, d[1], d[2], d[3], c.extra)
	end
end

-- Crossbow seen from above: curved limbs across the top, string, stock, a loaded bolt.
local function crossbowIcon(c: Ctx, wood: Color3, metal: Color3, str: Color3)
	curve(c, { V(2.8, 10.6), V(6.6, 7.2), V(12, 6.2), V(17.4, 7.2), V(21.2, 10.6) }, 2.2, wood)
	seg(c, 3.2, 10.8, 12, 13.6, 0.7, str)
	seg(c, 20.8, 10.8, 12, 13.6, 0.7, str)
	box(c, 12, 15.4, 3.4, 13, wood, 0, 1.2)
	box(c, 12, 20.6, 4.6, 2.6, c.mono and wood or P.leather_600, 0, 1)
	seg(c, 12, 3.8, 12, 13.6, 1.2, metal)
	tri(c, 12, 4.6, 3.6, "up", metal)
end

DRAW.Crossbow = function(c)
	crossbowIcon(c, c.accent, c.main, c.extra)
end

DRAW.Heartseeker = function(c)
	crossbowIcon(c, c.mono and c.main or P.crimson_700, c.main, c.extra)
	for _, dx in ipairs({ -5, 5 }) do
		seg(c, 12 + dx, 2.4, 12 + dx * 0.7, 5.6, 1, c.extra, 0.3)
	end
end

-- Six-armed snowflake with side twigs.
local function flake(c: Ctx, r: number, w: number, color: Color3, core: Color3)
	for k = 0, 2 do
		local a = k * math.pi / 3
		seg(c, 12 + math.cos(a) * r, 12 + math.sin(a) * r, 12 - math.cos(a) * r, 12 - math.sin(a) * r, w, color)
	end
	for k = 0, 5 do
		local a = k * math.pi / 3
		local x, y = 12 + math.cos(a) * r * 0.62, 12 + math.sin(a) * r * 0.62
		for _, sgn in ipairs({ -1, 1 }) do
			local b = a + sgn * 0.85
			seg(c, x, y, x + math.cos(b) * r * 0.32, y + math.sin(b) * r * 0.32, w * 0.62, color)
		end
	end
	dot(c, 12, 12, w * 1.1, core)
end

DRAW.FrostNova = function(c)
	ring(c, 12, 12, 10.4, 1.2, c.extra, 0.35)
	flake(c, 8.4, 1.8, c.main, c.accent)
end

DRAW.AbsoluteZero = function(c)
	ring(c, 12, 12, 10.6, 1.6, c.extra)
	ring(c, 12, 12, 7.8, 0.8, c.accent, 0.4)
	flake(c, 7.4, 1.9, c.main, c.accent)
end

-- Three flames along a path, the newest (top right) the biggest.
local function flames(c: Ctx, outer: Color3, inner: Color3, tail: Color3)
	drop(c, 5.4, 19.2, 2.1, tail)
	drop(c, 5.4, 20, 1, c.mono and c.back or inner)
	drop(c, 10.8, 15.4, 3, outer)
	drop(c, 10.8, 16.4, 1.6, c.mono and c.back or inner)
	drop(c, 17.2, 10, 4.2, outer)
	drop(c, 17.2, 11.4, 2.3, c.mono and c.back or inner)
end

DRAW.FireTrail = function(c)
	flames(c, c.main, c.accent, c.extra)
	box(c, 12, 22, 20, 1.2, c.extra, -20, 0.6, 0.55)
end

DRAW.PhoenixStride = function(c)
	-- a wing over the flames
	curve(c, { V(3, 9), V(7, 4.4), V(13, 3.4), V(19.6, 4.6) }, 2, c.accent, false, 0.8)
	curve(c, { V(5, 11), V(9, 7.6), V(14, 6.8) }, 1.4, c.accent, false, 0.55)
	flames(c, c.main, c.accent, c.extra)
end

-- Totem pole: post, carved wings with a face, glowing orb on top, a small base.
local function totemIcon(c: Ctx, wood: Color3, carving: Color3, glow: Color3)
	box(c, 12, 14.4, 5, 14, wood, 0, 1)
	box(c, 12, 12, 13, 4.4, carving, 0, 1.6)
	box(c, 12, 12.2, 3, 1.6, c.back, 0, 0.6)
	box(c, 12, 21.4, 9.4, 1.8, carving, 0, 0.9)
	dot(c, 12, 4.6, 2.9, glow)
end

DRAW.HealingTotem = function(c)
	totemIcon(c, c.main, c.accent, c.extra)
	box(c, 20, 18.6, 1.5, 5.2, c.extra, 0, 0.6)
	box(c, 20, 18.6, 5.2, 1.5, c.extra, 0, 0.6)
end

DRAW.Lifebloom = function(c)
	ring(c, 12, 4.6, 4.6, 0.9, c.extra, 0.45)
	totemIcon(c, c.main, c.accent, c.extra)
	box(c, 4.4, 18.2, 4.6, 2.2, c.extra, -35, 1.1)
	box(c, 19.6, 18.2, 4.6, 2.2, c.extra, 35, 1.1)
end

-- Hook (top right) on a chain of links (bottom left).
local function hookIcon(c: Ctx, metal: Color3, chainColor: Color3)
	for i = 0, 3 do
		local x, y = 3.8 + i * 2.6, 20.2 - i * 2.6
		box(c, x, y, 3.2, 1.8, chainColor, -45 + (i % 2) * 90, 0.9)
	end
	seg(c, 13.2, 11.2, 18.6, 5.4, 1.8, metal)
	arc(c, 15.4, 9.6, 4.4, 2, metal, 9, 9.6, 22, 16)
	seg(c, 19.8, 9.8, 19.8, 8.2, 2, metal)
	tri(c, 11.2, 10.6, 3.2, "up", metal)
end

DRAW.ChainHook = function(c)
	hookIcon(c, c.main, c.extra)
end

DRAW.ReapersChain = function(c)
	hookIcon(c, c.main, c.accent)
	dot(c, 6.2, 6.6, 3, c.extra)
	box(c, 6.2, 9, 3.2, 1.8, c.extra, 0, 0.6)
	dot(c, 5.2, 6.6, 0.8, c.mono and c.back or P.crimson_700)
	dot(c, 7.2, 6.6, 0.8, c.mono and c.back or P.crimson_700)
end

-- Turret: base, post, head with a barrel to the right and a muzzle glint.
local function turretIcon(c: Ctx, head: Color3, barrel: Color3, base: Color3)
	box(c, 12, 19.4, 16, 4.2, base, 0, 1.4)
	box(c, 12, 15.6, 4, 4, base, 0, 0.6)
	box(c, 10.6, 11, 10.4, 6.6, head, 0, 2.4)
	box(c, 18.4, 10.6, 7.6, 2.4, barrel, 0, 1)
	dot(c, 22, 10.6, 1, c.mono and barrel or P.fx_gold)
	dot(c, 8.4, 8.4, 1.1, c.mono and c.back or P.crimson_400)
end

DRAW.Turret = function(c)
	turretIcon(c, c.main, c.accent, c.extra)
end

DRAW.Bastion = function(c)
	turretIcon(c, c.main, c.accent, c.extra)
	box(c, 4, 13, 3.6, 7.6, c.main, 0, 1.2)
	box(c, 4, 13, 1.2, 4.6, c.accent, 0, 0.5)
end

-- Skull with a ghostly tail.
local function soulIcon(c: Ctx, x: number, y: number, s: number, bone: Color3, glow: Color3, tail: Color3)
	curve(c, { V(x - 11 * s, y + 11 * s), V(x - 8 * s, y + 6 * s), V(x - 5 * s, y + 3.6 * s), V(x - 2 * s, y + 1.6 * s) }, 3.4 * s, tail, false, 0.45)
	dot(c, x, y, 5.6 * s, bone)
	box(c, x, y + 4.6 * s, 6 * s, 3.4 * s, bone, 0, 1.2 * s)
	dot(c, x - 2.1 * s, y + 0.2 * s, 1.5 * s, c.mono and c.back or glow)
	dot(c, x + 2.1 * s, y + 0.2 * s, 1.5 * s, c.mono and c.back or glow)
	box(c, x, y + 2.8 * s, 0.9 * s, 1.4 * s, c.mono and c.back or P.slate_900, 0, 0.3)
end

DRAW.SoulBolt = function(c)
	soulIcon(c, 14.4, 10, 1, c.main, c.accent, c.extra)
end

DRAW.SoulStorm = function(c)
	soulIcon(c, 8.6, 14.6, 0.7, c.main, c.accent, c.extra)
	soulIcon(c, 16, 8.2, 0.85, c.main, c.accent, c.extra)
end

DRAW.Precision = function(c)
	ring(c, 11, 13, 8.2, 1.6, c.main)
	ring(c, 11, 13, 4.4, 1.6, c.main)
	dot(c, 11, 13, 1.6, c.accent)
	seg(c, 11.6, 12.4, 20, 4, 1.2, c.extra)
	seg(c, 20, 4, 22.4, 4, 1, c.mono and c.extra or c.accent)
	seg(c, 20, 4, 20, 1.6, 1, c.mono and c.extra or c.accent)
end

DRAW.Renewal = function(c)
	box(c, 9.4, 12, 7.8, 15, c.main, 40, 3.9)
	seg(c, 4.8, 19.4, 13.8, 4.8, 0.9, c.mono and c.back or c.extra)
	box(c, 18, 16.4, 2.2, 8, c.accent, 0, 0.7)
	box(c, 18, 16.4, 8, 2.2, c.accent, 0, 0.7)
end

-- Hero class icons: the Alchemist's goggled cap, the Engineer's lamp helmet, the
-- Necromancer's hood with its bone mask.
DRAW.goggles = function(c)
	box(c, 12, 11.4, 16, 10.4, c.main, 0, 5.2)
	box(c, 12, 16, 19, 2.6, c.main, 0, 1.3)
	box(c, 12, 11.8, 17, 1.2, c.mono and c.main or P.slate_950, 0, 0.6)
	for _, x in ipairs({ 7.6, 16.4 }) do
		dot(c, x, 11.6, 3.6, c.accent)
		dot(c, x, 11.6, 2.3, c.mono and c.back or c.extra)
	end
end

DRAW.minerHelm = function(c)
	box(c, 12, 12.8, 17, 11, c.main, 0, 5.5)
	box(c, 12, 17.8, 20.4, 2.4, c.main, 0, 1.2)
	box(c, 12, 9, 2.2, 8.4, c.accent, 0, 1)
	dot(c, 12, 13, 3.4, c.accent)
	dot(c, 12, 13, 2.2, c.mono and c.back or c.extra)
end

DRAW.skullHood = function(c)
	box(c, 12, 13, 17.6, 17, c.main, 0, 7.4)
	box(c, 12, 4.6, 5, 5, c.main, 45, 1)
	dot(c, 12, 12.4, 4.6, c.accent)
	box(c, 12, 16, 5, 3, c.accent, 0, 1)
	dot(c, 10.3, 12.4, 1.2, c.mono and c.back or c.extra)
	dot(c, 13.7, 12.4, 1.2, c.mono and c.back or c.extra)
end

DRAW.aim = function(c)
	ring(c, 12, 12, 7.4, 1.8, c.main)
	for _, d in ipairs({ { 0, -1 }, { 0, 1 }, { -1, 0 }, { 1, 0 } }) do
		seg(c, 12 + d[1] * 5.6, 12 + d[2] * 5.6, 12 + d[1] * 10.4, 12 + d[2] * 10.4, 1.8, c.main)
	end
	dot(c, 12, 12, 2.2, c.accent)
end
DRAW.Heart = DRAW.heart
DRAW.SpeedBoots = DRAW.boot
DRAW.Cooldown = DRAW.hourglass
DRAW.Area = DRAW.area
DRAW.Duplicator = DRAW.duplicate
DRAW.Vacuum = DRAW.magnet
DRAW.Luck = DRAW.clover
DRAW.Ammo = DRAW.arrowFast
DRAW.Candle = DRAW.candle
DRAW.Growth = DRAW.sprout

-- Run items (ItemData) and loot ---------------------------------------------------------

DRAW.Whetstone = function(c)
	box(c, 11.4, 14.6, 18, 6.6, c.main, -20, 2.2)
	box(c, 10.8, 12.4, 14.6, 1.6, c.mono and c.main or c.extra, -20, 0.8)
	box(c, 18.6, 5.4, 3.2, 3.2, c.accent, 45, 0.4)
	box(c, 18.6, 5.4, 1, 6.4, c.accent, 0, 0.5)
	box(c, 18.6, 5.4, 6.4, 1, c.accent, 0, 0.5)
end

DRAW.QuickGloves = function(c)
	for _, x in ipairs({ 10.6, 13, 15.4, 17.8 }) do
		box(c, x, 8.8, 2.1, 6, c.main, 0, 1.05)
	end
	box(c, 14.2, 14.6, 9.8, 8.6, c.main, 0, 2.4)
	box(c, 9, 13.8, 2.4, 6, c.main, -38, 1.2)
	box(c, 14.2, 20.2, 10.4, 2.8, c.accent, 0, 0.8)
	box(c, 3.6, 9.4, 3.6, 1.3, c.mono and c.main or c.extra, 0, 0.65, 0.3)
	box(c, 2.8, 13.4, 3.6, 1.3, c.mono and c.main or c.extra, 0, 0.65, 0.3)
	box(c, 3.6, 17.4, 3.6, 1.3, c.mono and c.main or c.extra, 0, 0.65, 0.3)
end

DRAW.SwiftFeather = function(c)
	box(c, 13.2, 10.6, 7.4, 16, c.main, 40, 3.7)
	box(c, 15.6, 8.2, 2.6, 3, c.back, 40, 0.4, 0.2)
	seg(c, 5, 20.4, 17.6, 5.2, 1.2, c.mono and c.main or c.accent)
	box(c, 3.6, 7.6, 3.2, 1.2, c.mono and c.main or c.extra, 0, 0.6, 0.35)
	box(c, 4.4, 11.4, 2.6, 1.2, c.mono and c.main or c.extra, 0, 0.6, 0.35)
end

DRAW.HeartyBread = function(c)
	box(c, 12, 15.2, 19, 8.4, c.main, 0, 3.6)
	box(c, 12, 11.6, 16, 8, c.mono and c.main or c.extra, 0, 4)
	for _, x in ipairs({ 7.6, 12, 16.4 }) do
		seg(c, x - 1.2, 13.4, x + 1.2, 9.6, 1.2, c.accent)
	end
end

DRAW.Bandage = function(c)
	box(c, 12, 12, 21, 7.8, c.main, -45, 3.9)
	box(c, 12, 12, 7, 7, c.mono and c.dim or c.accent, -45, 1.2)
	for _, p in ipairs({ { 6.4, 15.4 }, { 8.6, 17.6 }, { 15.4, 6.4 }, { 17.6, 8.6 } }) do
		dot(c, p[1], p[2], 0.7, c.mono and c.back or c.extra)
	end
end

DRAW.Lodestone = function(c)
	box(c, 9.4, 15, 12, 9, c.main, 14, 2.6)
	box(c, 8.4, 13, 7, 2.2, c.mono and c.main or c.extra, 14, 1)
	box(c, 18.6, 6.4, 3.2, 3.2, c.accent, 45, 0.4)
	box(c, 20.2, 12.6, 2.4, 2.4, c.accent, 45, 0.4)
	arc(c, 9.4, 15, 8.6, 1.2, c.accent, 12, 2, 23, 12, 0.5)
end

DRAW.KeenLens = function(c)
	dot(c, 10, 10, 6, c.mono and c.dim or c.extra, c.mono and 0 or 0.55)
	ring(c, 10, 10, 6.4, 2.2, c.main)
	box(c, 7.6, 7.6, 3.2, 1.4, P.ivory_100, -45, 0.7, 0.3)
	curve(c, { V(14.6, 14.6), V(17.4, 15.6), V(18.6, 18.6), V(20.8, 21) }, 1.2, c.accent)
end

DRAW.HealingHerb = function(c)
	seg(c, 12, 21.4, 12, 9, 1.6, c.mono and c.main or c.extra)
	box(c, 8.2, 12.6, 7.4, 3.8, c.main, 30, 1.9)
	box(c, 15.8, 10.2, 7.4, 3.8, c.main, -30, 1.9)
	box(c, 12, 5.8, 3.8, 6.8, c.main, 0, 1.9)
	dot(c, 7.6, 18.2, 1.8, c.accent)
	dot(c, 16.6, 17, 1.8, c.accent)
	box(c, 16.6, 4.2, 1.2, 4.4, c.accent, 0, 0.5)
	box(c, 16.6, 4.2, 4.4, 1.2, c.accent, 0, 0.5)
end

DRAW.IronPlate = function(c)
	box(c, 12, 12, 16.4, 18.4, c.main, 0, 3.4)
	box(c, 12, 11, 12, 13, c.mono and c.dim or c.extra, 0, 2.2)
	for _, p in ipairs({ { 6.6, 5.4 }, { 17.4, 5.4 }, { 6.6, 18.6 }, { 17.4, 18.6 } }) do
		dot(c, p[1], p[2], 1.2, c.accent)
	end
end

DRAW.BarbedMail = function(c)
	tri(c, 12, 4.6, 4.8, "up", c.accent)
	tri(c, 4.4, 12.4, 4.8, "left", c.accent)
	tri(c, 19.6, 12.4, 4.8, "right", c.accent)
	tri(c, 12, 19.8, 4.8, "down", c.accent)
	box(c, 12, 12.2, 14.6, 14.6, c.main, 0, 3.4)
	box(c, 12, 12.2, 1.6, 9, c.mono and c.back or c.extra, 0, 0.6)
	box(c, 12, 12.2, 9, 1.6, c.mono and c.back or c.extra, 0, 0.6)
end

DRAW.StormCharm = function(c)
	ring(c, 12, 4.2, 1.9, 1.3, c.accent)
	dot(c, 12, 13.6, 7.4, c.accent)
	dot(c, 12, 13.6, 5.8, c.mono and c.back or c.main)
	line(c, { V(13.4, 9), V(10.4, 13.8), V(13.4, 13.8), V(10.6, 18.4) }, 1.7, c.mono and c.main or c.extra)
end

DRAW.VolatileSpore = function(c)
	for k = 0, 7 do
		local a = k / 8 * math.pi * 2
		seg(c, 12 + math.cos(a) * 8.4, 12 + math.sin(a) * 8.4, 12 + math.cos(a) * 10.6, 12 + math.sin(a) * 10.6, 1.4, c.accent)
	end
	dot(c, 12, 12, 6.6, c.main)
	dot(c, 9.6, 10.2, 1.4, c.mono and c.back or c.extra)
	dot(c, 14.4, 11.2, 1.1, c.mono and c.back or c.extra)
	dot(c, 11.4, 14.8, 1.2, c.mono and c.back or c.extra)
end

DRAW.GuardianWard = function(c)
	dot(c, 12, 12, 9.6, c.main, c.mono and 0.6 or 0.7)
	ring(c, 12, 12, 9.4, 1.6, c.main)
	box(c, 12, 10.2, 8, 5.8, c.accent, 0, 1.4)
	tri(c, 12, 12.6, 8, "down", c.accent)
	box(c, 8.4, 6.6, 3.2, 1.2, P.ivory_100, -40, 0.6, 0.35)
end

DRAW.SpareQuiver = function(c)
	for i, x in ipairs({ 9.4, 12.4, 15.4 }) do
		local top = 2.8 + (i == 2 and 0 or 1.2)
		seg(c, x, top + 2, x, 12, 1.1, c.mono and c.main or c.extra)
		tri(c, x, top + 1.2, 3.2, "up", c.accent)
	end
	box(c, 12.4, 15.6, 9.8, 12, c.main, 8, 2.4)
	box(c, 12.2, 11.2, 10.6, 2.2, c.accent, 8, 1)
end

DRAW.MagnetTotem = function(c)
	ring(c, 12, 10, 9.8, 1, c.mono and c.main or c.extra, 0.55)
	box(c, 12, 17.4, 6, 9.6, c.main, 0, 1.2)
	box(c, 12, 21.6, 10, 2, c.main, 0, 1)
	arc(c, 12, 8.6, 4.4, 3, c.accent, 6, 8.6, 18, 15)
	box(c, 7.6, 6.4, 3, 4.4, c.accent)
	box(c, 16.4, 6.4, 3, 4.4, c.accent)
	box(c, 7.6, 3.6, 3, 1.6, c.mono and c.main or P.steel_200, 0, 0.3)
	box(c, 16.4, 3.6, 3, 1.6, c.mono and c.main or P.steel_200, 0, 0.3)
end

DRAW.HuntersEye = function(c)
	box(c, 12, 12, 13, 13, c.main, 45, 3)
	dot(c, 12, 12, 4, c.accent)
	dot(c, 12, 12, 1.8, c.back)
	box(c, 12, 2.6, 1.4, 4, c.mono and c.main or c.extra, 0, 0.7)
	box(c, 12, 21.4, 1.4, 4, c.mono and c.main or c.extra, 0, 0.7)
	box(c, 2.6, 12, 4, 1.4, c.mono and c.main or c.extra, 0, 0.7)
	box(c, 21.4, 12, 4, 1.4, c.mono and c.main or c.extra, 0, 0.7)
end

DRAW.PhoenixFeather = function(c)
	drop(c, 12, 14.4, 6.6, c.main)
	drop(c, 12, 16, 4.2, c.mono and c.back or c.accent)
	drop(c, 12, 17.4, 2.2, c.mono and c.main or c.extra)
	drop(c, 5.4, 14, 2, c.main)
	drop(c, 18.6, 14, 2, c.main)
	seg(c, 12, 19, 12, 22.4, 1.2, c.mono and c.main or c.accent)
end

DRAW.CrownOfAges = function(c)
	DRAW.crown(c)
	if not c.mono then
		dot(c, 12, 15.4, 1.6, c.extra)
	end
end

DRAW.SunMedallion = function(c)
	for k = 0, 7 do
		local a = k * 45
		local r = math.rad(a)
		box(c, 12 + math.cos(r) * 8.6, 12 + math.sin(r) * 8.6, 4, 2.6, c.accent, a, 1.3)
	end
	dot(c, 12, 12, 6.6, c.main)
	ring(c, 12, 12, 4.4, 1.1, c.mono and c.back or c.extra)
	dot(c, 12, 12, 1.6, c.mono and c.back or c.extra)
end

-- Loot on the map (prompts, toasts)
DRAW.shrine = function(c)
	box(c, 12, 20.4, 16, 3.4, c.main, 0, 0.8)
	box(c, 12, 11.4, 9, 15, c.main, 0, 1.4)
	box(c, 12, 10.6, 4.4, 4.4, c.mono and c.back or c.accent, 45, 0.5)
	box(c, 12, 4.6, 7.4, 2, c.mono and c.main or c.extra, 0, 0.8)
end

DRAW.altar = function(c)
	box(c, 12, 20.6, 21, 3, c.main, 0, 1)
	box(c, 12, 17.4, 16, 3.4, c.main, 0, 0.8)
	box(c, 12, 12.4, 11, 5.6, c.accent, 0, 0.8)
	box(c, 12, 8.4, 11, 3.2, c.mono and c.main or c.extra, 0, 1.4)
	box(c, 12, 11.4, 2.2, 2.6, c.mono and c.back or P.gold_300, 0, 0.4)
	box(c, 3.4, 13, 2.4, 9, c.main, 0, 0.6)
	box(c, 20.6, 13, 2.4, 9, c.main, 0, 0.6)
end

-- Fallback cards ------------------------------------------------------------------------

DRAW.Gold = function(c)
	local detail = c.mono and c.back or c.accent
	dot(c, 15.6, 9, 6, c.mono and c.dim or c.extra)
	ring(c, 15.6, 9, 4, 1.1, detail)
	dot(c, 9.4, 14.6, 7.4, c.back)
	dot(c, 9.4, 14.6, 7, c.main)
	ring(c, 9.4, 14.6, 4.9, 1.3, detail)
	box(c, 9.4, 14.6, 3.4, 3.4, detail, 45, 0.4)
	if not c.mono then
		box(c, 6.4, 10.6, 2.8, 1.3, P.gold_200, -40, 0.6, 0.3)
	end
end

DRAW.Heal = function(c)
	seg(c, 13, 13, 18.4, 18.4, 2.6, c.accent)
	dot(c, 19.8, 17.4, 1.9, c.accent)
	dot(c, 17.4, 19.8, 1.9, c.accent)
	dot(c, 10, 10, 7, c.main)
	box(c, 13.4, 13.4, 5, 5, c.main, 45, 1)
	if not c.mono then
		dot(c, 7.6, 7.8, 2, c.extra, 0.45)
	end
end

DRAW.missing = function(c)
	box(c, 12, 12, 16, 16, c.main, 45, 2, 0.6)
end

------------------------------------------------------------------------------------------
-- Public
------------------------------------------------------------------------------------------

function Icons.Has(name: string): boolean
	return DRAW[name] ~= nil
end

-- Every icon name (for a preview sheet).
function Icons.List(): { string }
	local list = {}
	for name in pairs(DRAW) do
		if name ~= "missing" then
			table.insert(list, name)
		end
	end
	table.sort(list)
	return list
end

local function container(name: string, o: Opts): Frame
	local size = o.Size or Theme.Size.Icon
	local f = Instance.new("Frame")
	f.Name = o.Name or ("Icon_" .. name)
	f.BackgroundTransparency = 1
	f.BorderSizePixel = 0
	f.Size = UDim2.fromOffset(size, size)
	f.AnchorPoint = o.AnchorPoint or Vector2.zero
	f.Position = o.Position or UDim2.new()
	f.Active = false
	f.Selectable = false
	if o.ZIndex then
		f.ZIndex = o.ZIndex
	end
	if o.LayoutOrder then
		f.LayoutOrder = o.LayoutOrder
	end
	return f
end

-- Draws icon `name` (a menu icon or an upgrade id) into a new square frame.
function Icons.Draw(parent: Instance?, name: string, opts: Opts?): Frame
	local o: Opts = opts or {}
	local f = container(name, o)
	local size = o.Size or Theme.Size.Icon
	local def = DEFAULT[name]
	local mono = o.Color ~= nil
	local main = o.Color or (def and def.Main) or Theme.Icon.Main
	local accent = o.Accent or (mono and main) or (def and def.Accent) or Theme.Icon.Accent
	local extra = (mono and main) or (def and def.Extra) or accent
	local back = o.Back or Theme.Icon.Back
	local c: Ctx = {
		Frame = f,
		Ox = 0,
		Oy = 0,
		Sx = G,
		Sy = G,
		Px = size / G,
		Z = { n = 0 },
		main = main,
		accent = accent,
		extra = extra,
		back = back,
		light = main:Lerp(WHITE, 0.4),
		dim = main:Lerp(back, 0.45),
		mono = mono,
	}
	local fn = DRAW[name] or DRAW.missing
	local ok, err = pcall(fn, c)
	if not ok then
		warn("[Icons] " .. name .. ": " .. tostring(err))
	end
	f.Parent = parent
	return f
end

--[[
	Upgrade icon for a weapon / evolution / passive / Gold / Heal id. An IconData picture
	(if someone uploads one) wins over the vector icon; an unknown id shows its glyph.
]]
function Icons.Upgrade(parent: Instance?, id: string?, opts: Opts?): Frame
	local o: Opts = opts or {}
	local key = id or "?"
	local image = IconData.Image(id)
	if image then
		local f = container(key, o)
		local img = Instance.new("ImageLabel")
		img.Name = "Image"
		img.BackgroundTransparency = 1
		img.Image = image
		img.ScaleType = Enum.ScaleType.Fit
		img.Size = UDim2.fromScale(1, 1)
		img.ImageColor3 = o.Color or WHITE
		img.Parent = f
		f.Parent = parent
		return f
	end
	if DRAW[key] then
		return Icons.Draw(parent, key, o)
	end
	local f = container(key, o)
	local t = Instance.new("TextLabel")
	t.BackgroundTransparency = 1
	t.Size = UDim2.fromScale(1, 1)
	t.Text = IconData.Glyph(id, id)
	t.TextScaled = true
	t.FontFace = Theme.Font.Heading
	t.TextColor3 = o.Color or Theme.Icon.Main
	t.Parent = f
	f.Parent = parent
	return f
end

local CHARACTER_ICONS = { Knight = "helmet", Mage = "wizardHat", Rogue = "hood", Priest = "mitre", Ranger = "featherCap", Alchemist = "goggles", Engineer = "minerHelm", Necromancer = "skullHood" }

function Icons.CharacterIcon(characterId: string): string
	return CHARACTER_ICONS[characterId] or "person"
end

function Icons.Character(parent: Instance?, characterId: string, opts: Opts?): Frame
	return Icons.Draw(parent, Icons.CharacterIcon(characterId), opts)
end

local META_ICONS = {
	MaxHP = "Heart",
	Might = "Might",
	Armor = "Armor",
	Speed = "SpeedBoots",
	Luck = "Luck",
	Growth = "Growth",
	Revive = "revive",
	Reroll = "cycle",
	Skip = "skip",
}

function Icons.MetaIcon(upgradeId: string): string
	return META_ICONS[upgradeId] or "chevronsUp"
end

return Icons
