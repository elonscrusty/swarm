--[[
	IdleFx.lua
	Idle life for icon pictures: one Heartbeat loop moves every attached GuiObject a little
	(sway, bounce, spin, glint ...) instead of a tween per icon. An entry only steps while
	its object is really on screen (every ancestor Visible, the ScreenGui enabled); hidden
	objects are put back to their rest pose and cost nothing but a visibility check four
	times a second. Destroyed objects drop out by themselves.

	IdleFx.Attach(obj, kind, opts?) -> Handle { Stop }   (a second Attach on the same object replaces the first)
	IdleFx.Stop(obj)                                     rest pose, entry removed
	IdleFx.Flip(obj)                                     a Coin entry flips now (gold gained)
	IdleFx.Count() / IdleFx.Stats()                      live entries (perf scenes)

	Kinds (all subtle, each entry staggered by a random phase):
	  Sway     banner: swings from its pole top (opts.Pivot, default (0.5, 0.18)) with a
	           slight horizontal squash as cloth ripple
	  Hammer   anvil: every opts.Period (4.5 s) a quick squash-stretch "hit" with 2-3 spark
	           dots popping off the top (opts.Spark = where they start, default (0.5, 0.4))
	  Sun      slow rock, a breathing glow disc behind the picture (opts.Color) and a sparkle
	           at a ray tip every few seconds
	  Flicker  candle: a flame glow (opts.Flame, default (0.5, 0.16); opts.Color) and the
	           picture's brightness and height flicker
	  Spin     steady rotation, opts.Period seconds per turn (16)
	  Glint    every opts.Period (5 s) a sparkle star and a tiny scale punch (unlocked
	           rewards, medals, trophies)
	  Bob      gentle up-down drift with a slight tilt (helmets, selected roster badge)
	  Float    slow vertical float (level-up card icons)
	  Drift    slow zoom and parallax inside a clipping frame (arena pictures)
	  Pulse    slow scale breath (skull, warning)
	  Coin     slight tilt and an occasional flip (the picture narrows and widens like a
	           turning coin); IdleFx.Flip triggers one; opts.Auto = false: only on Flip
	  Shine    a brief brightness lift (ImageColor3 towards white is not possible, so the
	           picture dims and recovers: a soft blink) every opts.Period seconds

	Reduced effects (ClientSettings.Reduced()): continuous motions run at a third of the
	speed and half the amplitude; one-shots (hits, sparks, sparkles, flips) never fire.

	Transforms write Rotation, Position (an offset on the laid-out position; objects in a
	UIListLayout only show rotation / scale), Size (non-uniform squash about the object's
	anchor, so pictures should be centre-anchored) and a UIScale "IdleScale" (uniform). The
	rest pose is re-read whenever a layout pass moved the object, so layout changes win.
]]

local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")

local ClientSettings = require(script.Parent.ClientSettings)

local IdleFx = {}

export type Handle = { Stop: () -> () }

type Entry = {
	Obj: GuiObject,
	Kind: string,
	Opts: { [string]: any },
	Clock: number,
	Phase: number,
	Shown: boolean,
	NextCheck: number,
	Reduced: boolean,
	-- rest pose and what we last wrote (to notice layout changes)
	BaseRot: number,
	BasePos: UDim2,
	BaseSize: UDim2,
	WroteRot: number?,
	WrotePos: UDim2?,
	WroteSize: UDim2?,
	Scale: UIScale?,
	Glow: Frame?,
	BaseColor: Color3?,
	W: number,
	H: number,
	X: { [string]: any }, -- per-kind scratch
}

local CHECK = 0.25
local SPARK_COLOR = Color3.fromRGB(255, 221, 130)
local rng = Random.new()

local entries: { Entry } = {}
local byObj: { [GuiObject]: Entry } = {}
local conn: RBXScriptConnection? = nil

------------------------------------------------------------------------------------------
-- Helpers
------------------------------------------------------------------------------------------

local function isShown(obj: GuiObject): boolean
	local o: Instance? = obj
	while o do
		if o:IsA("GuiObject") then
			if not o.Visible then
				return false
			end
		elseif o:IsA("ScreenGui") or o:IsA("SurfaceGui") or o:IsA("BillboardGui") then
			return o.Enabled
		end
		o = o.Parent
	end
	return false
end

local function scaleOf(e: Entry): UIScale
	local s = e.Scale
	if not s or s.Parent ~= e.Obj then
		s = e.Obj:FindFirstChild("IdleScale") :: UIScale?
		if not s then
			local created = Instance.new("UIScale")
			created.Name = "IdleScale"
			created.Parent = e.Obj
			s = created
		end
		e.Scale = s
	end
	return s :: UIScale
end

local function setRot(e: Entry, deg: number)
	local v = e.BaseRot + deg
	e.Obj.Rotation = v
	e.WroteRot = v
end

local function setOffset(e: Entry, dx: number, dy: number)
	local v = e.BasePos + UDim2.fromOffset(dx, dy)
	e.Obj.Position = v
	e.WrotePos = v
end

local function setStretch(e: Entry, sx: number, sy: number)
	local b = e.BaseSize
	local v = UDim2.new(b.X.Scale * sx, b.X.Offset * sx, b.Y.Scale * sy, b.Y.Offset * sy)
	e.Obj.Size = v
	e.WroteSize = v
end

local function setScale(e: Entry, s: number)
	scaleOf(e).Scale = s
end

-- The picture(s) inside an Icons container: narrowed about their centre for a coin flip.
local function setInner(e: Entry, sx: number)
	for _, ch in ipairs(e.Obj:GetChildren()) do
		if ch:IsA("GuiObject") and (ch.Name == "Image" or ch.Name == "Fallback" or ch.Name == "Art") then
			ch.Size = UDim2.fromScale(sx, 1)
			ch.Position = UDim2.fromScale((1 - sx) / 2, 0)
		end
	end
end

local function setBrightness(e: Entry, k: number)
	local obj = e.Obj
	if obj:IsA("ImageLabel") then
		if not e.BaseColor then
			e.BaseColor = obj.ImageColor3
		end
		local c = e.BaseColor :: Color3
		obj.ImageColor3 = Color3.new(c.R * k, c.G * k, c.B * k)
	else
		for _, ch in ipairs(obj:GetChildren()) do
			if ch:IsA("ImageLabel") then
				if not e.BaseColor then
					e.BaseColor = ch.ImageColor3
				end
				local c = e.BaseColor :: Color3
				ch.ImageColor3 = Color3.new(c.R * k, c.G * k, c.B * k)
			end
		end
	end
end

-- A soft round glow behind the picture (a sibling just under it), sized from the object.
local function glowOf(e: Entry, color: Color3): Frame?
	local g = e.Glow
	if g and g.Parent then
		return g
	end
	local obj = e.Obj
	local parent = obj.Parent
	if not parent then
		return nil
	end
	g = Instance.new("Frame")
	g.Name = "IdleGlow"
	g.BackgroundColor3 = color
	g.BackgroundTransparency = 1
	g.BorderSizePixel = 0
	g.AnchorPoint = Vector2.new(0.5, 0.5)
	g.Active = false
	g.ZIndex = math.max(obj.ZIndex - 1, 0)
	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(1, 0)
	corner.Parent = g
	g.Parent = parent
	e.Glow = g
	return g
end

-- Places the glow over fraction (fx, fy) of the object with a size fraction of the object's
-- smaller side (object sizes are in its parent's units, so the glow uses pixels).
local function placeGlow(e: Entry, g: Frame, fx: number, fy: number, frac: number, alpha: number)
	local obj = e.Obj
	local ap, size = obj.AnchorPoint, obj.AbsoluteSize
	local w, h = size.X, size.Y
	local parentSize = (obj.Parent :: GuiObject).AbsoluteSize
	-- the object's top-left in parent pixels: from its own Position and anchor
	local px = obj.Position.X.Scale * parentSize.X + obj.Position.X.Offset - ap.X * w
	local py = obj.Position.Y.Scale * parentSize.Y + obj.Position.Y.Offset - ap.Y * h
	local d = math.min(w, h) * frac
	g.Position = UDim2.fromOffset(math.floor(px + fx * w + 0.5), math.floor(py + fy * h + 0.5))
	g.Size = UDim2.fromOffset(math.floor(d + 0.5), math.floor(d + 0.5))
	g.BackgroundTransparency = alpha
	g.Visible = true
end

-- A small four-point sparkle at fraction (fx, fy) of the object: two thin crossed frames
-- that grow and fade. One short tween each; they destroy themselves.
local function sparkle(e: Entry, fx: number, fy: number, size: number, color: Color3?)
	local obj = e.Obj
	for i = 0, 1 do
		local bar = Instance.new("Frame")
		bar.Name = "Sparkle"
		bar.BackgroundColor3 = color or Color3.new(1, 1, 1)
		bar.BackgroundTransparency = 0.1
		bar.BorderSizePixel = 0
		bar.AnchorPoint = Vector2.new(0.5, 0.5)
		bar.Position = UDim2.fromScale(fx, fy)
		bar.Rotation = i * 90
		bar.Size = UDim2.fromOffset(2, 2)
		bar.ZIndex = obj.ZIndex + 2
		bar.Active = false
		bar.Parent = obj
		local grow = TweenService:Create(bar, TweenInfo.new(0.22, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), { Size = UDim2.fromOffset(2, size) })
		grow:Play()
		grow.Completed:Once(function()
			if bar.Parent then
				local fade = TweenService:Create(bar, TweenInfo.new(0.3, Enum.EasingStyle.Quad, Enum.EasingDirection.In), { Size = UDim2.fromOffset(1, 2), BackgroundTransparency = 1 })
				fade:Play()
				fade.Completed:Once(function()
					bar:Destroy()
				end)
			end
		end)
	end
end

-- Spark dots flying up and out of (fx, fy) (the anvil's top): a hammer hit.
local function sparks(e: Entry, fx: number, fy: number, count: number)
	local obj = e.Obj
	local w = math.max(e.W, 24)
	for i = 1, count do
		local dot = Instance.new("Frame")
		dot.Name = "Spark"
		dot.BackgroundColor3 = SPARK_COLOR
		dot.BorderSizePixel = 0
		dot.AnchorPoint = Vector2.new(0.5, 0.5)
		dot.Rotation = 45
		local s = rng:NextInteger(2, 4)
		dot.Size = UDim2.fromOffset(s, s)
		dot.Position = UDim2.fromScale(fx, fy)
		dot.ZIndex = obj.ZIndex + 2
		dot.Active = false
		dot.Parent = obj
		local dx = (rng:NextNumber(-0.35, 0.35) + (i - (count + 1) / 2) * 0.18) * w
		local dy = -rng:NextNumber(0.3, 0.55) * w
		local t = TweenService:Create(dot, TweenInfo.new(rng:NextNumber(0.35, 0.5), Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
			Position = UDim2.new(fx, dx, fy, dy),
			BackgroundTransparency = 1,
			Size = UDim2.fromOffset(1, 1),
		})
		t:Play()
		t.Completed:Once(function()
			dot:Destroy()
		end)
	end
end

local function smooth(u: number): number
	u = math.clamp(u, 0, 1)
	return u * u * (3 - 2 * u)
end

------------------------------------------------------------------------------------------
-- Kinds: step(e, t, amp, reduced) with t the entry's clock (already slowed when reduced)
------------------------------------------------------------------------------------------

local STEP: { [string]: (Entry, number, number, boolean) -> () } = {}

STEP.Sway = function(e, t, amp, _reduced)
	local a = (4 * math.sin(t * 1.3) + 1.2 * math.sin(t * 2.9 + 1)) * amp
	setRot(e, a)
	local pivot = e.Opts.Pivot or Vector2.new(0.5, 0.18)
	local vx, vy = (0.5 - pivot.X) * e.W, (0.5 - pivot.Y) * e.H
	local r = math.rad(a)
	local c, s = math.cos(r), math.sin(r)
	setOffset(e, vx * c - vy * s - vx, vx * s + vy * c - vy)
	setStretch(e, 1 - 0.03 * amp * (0.5 + 0.5 * math.sin(t * 2.2 + 0.7)), 1)
end

STEP.Hammer = function(e, t, _amp, reduced)
	if reduced then
		return
	end
	local period = e.Opts.Period or 4.5
	local u = t % period
	local cycle = math.floor(t / period)
	local sx, sy = 1, 1
	if u < 0.12 then
		local k = smooth(u / 0.12) -- the hit: pressed down
		sx, sy = 1 + 0.07 * k, 1 - 0.1 * k
	elseif u < 0.3 then
		local k = smooth((u - 0.12) / 0.18) -- rebound, a touch tall
		sx, sy = 1.07 - 0.1 * k, 0.9 + 0.14 * k
	elseif u < 0.7 then
		local k = (u - 0.3) / 0.4 -- settle
		local w = math.sin(k * math.pi * 2) * (1 - k) * 0.02
		sx, sy = 0.97 + 0.03 * smooth(k) - w, 1.04 - 0.04 * smooth(k) + w
	end
	setStretch(e, sx, sy)
	if u >= 0.1 and e.X.Cycle ~= cycle then
		e.X.Cycle = cycle
		local at = e.Opts.Spark or Vector2.new(0.5, 0.4)
		sparks(e, at.X, at.Y, rng:NextInteger(2, 3))
	end
end

STEP.Sun = function(e, t, amp, reduced)
	setRot(e, 1.5 * amp * math.sin(t * 0.5))
	setScale(e, 1 + 0.015 * amp * math.sin(t * 1.1))
	local g = glowOf(e, e.Opts.Color or SPARK_COLOR)
	if g then
		placeGlow(e, g, 0.5, 0.46, 0.82 + 0.06 * math.sin(t * 1.1), 0.82 + 0.08 * math.sin(t * 1.1 + 1))
	end
	if not reduced then
		local period = e.Opts.Period or 5.5
		local cycle = math.floor(t / period)
		if e.X.Cycle ~= cycle then
			e.X.Cycle = cycle
			local tips = { Vector2.new(0.5, 0.1), Vector2.new(0.82, 0.3), Vector2.new(0.18, 0.3), Vector2.new(0.78, 0.66) }
			local p = tips[rng:NextInteger(1, #tips)]
			sparkle(e, p.X, p.Y, math.max(8, e.W * 0.22))
		end
	end
end

STEP.Flicker = function(e, t, amp, reduced)
	local n = 0.5 + 0.5 * (math.sin(t * 9) * 0.6 + math.sin(t * 13.7 + 2) * 0.4)
	if reduced then
		n = 0.5 + 0.5 * math.sin(t * 2)
	end
	setBrightness(e, 1 - 0.07 * amp * n)
	setStretch(e, 1, 1 + 0.012 * amp * (n - 0.5))
	local g = glowOf(e, e.Opts.Color or Color3.fromRGB(214, 120, 255))
	if g then
		local flame = e.Opts.Flame or Vector2.new(0.5, 0.16)
		placeGlow(e, g, flame.X, flame.Y, 0.34 + 0.08 * n, 0.72 + 0.14 * (1 - n))
	end
end

STEP.Spin = function(e, t, _amp, _reduced)
	setRot(e, (t * 360 / (e.Opts.Period or 16)) % 360)
end

STEP.Glint = function(e, t, _amp, reduced)
	if reduced then
		return
	end
	local period = e.Opts.Period or 5
	local u = t % period
	local cycle = math.floor(t / period)
	if u < 0.35 then
		setScale(e, 1 + 0.06 * math.sin(u / 0.35 * math.pi))
	else
		setScale(e, 1)
	end
	if e.X.Cycle ~= cycle then
		e.X.Cycle = cycle
		local spots = { Vector2.new(0.78, 0.22), Vector2.new(0.3, 0.18), Vector2.new(0.72, 0.6) }
		local p = spots[rng:NextInteger(1, #spots)]
		sparkle(e, p.X, p.Y, math.max(7, e.W * 0.26), e.Opts.Color)
	end
end

STEP.Bob = function(e, t, amp, _reduced)
	setOffset(e, 0, 1.5 * amp * math.sin(t * 1.6))
	setRot(e, 2 * amp * math.sin(t * 1.1 + 0.5))
end

STEP.Float = function(e, t, amp, _reduced)
	setOffset(e, 0, 2.5 * amp * math.sin(t * 1.2))
end

STEP.Drift = function(e, t, amp, _reduced)
	setScale(e, 1.04 + 0.02 * amp * math.sin(t * 0.35))
	setOffset(e, 2 * amp * math.sin(t * 0.27), 1.5 * amp * math.sin(t * 0.41))
end

STEP.Pulse = function(e, t, amp, _reduced)
	setScale(e, 1 + 0.025 * amp * math.sin(t * 1.5))
end

STEP.Coin = function(e, t, amp, reduced)
	setRot(e, 4 * amp * math.sin(t * 1.2))
	if reduced then
		setInner(e, 1)
		return
	end
	local flipAt = e.X.FlipAt
	if not flipAt and e.Opts.Auto ~= false then
		local period = e.Opts.Period or 8
		local cycle = math.floor(t / period)
		if e.X.Cycle ~= cycle then
			e.X.Cycle = cycle
			flipAt = t
			e.X.FlipAt = t
		end
	end
	if flipAt then
		local u = (t - flipAt) / 0.55
		if u >= 1 then
			e.X.FlipAt = nil
			setInner(e, 1)
		else
			setInner(e, math.max(0.08, math.abs(math.cos(u * math.pi))))
		end
	else
		setInner(e, 1)
	end
end

STEP.Shine = function(e, t, _amp, reduced)
	if reduced then
		return
	end
	local period = e.Opts.Period or 6
	local u = t % period
	if u < 0.5 then
		setBrightness(e, 1 - 0.18 * math.sin(u / 0.5 * math.pi))
	else
		setBrightness(e, 1)
	end
end

------------------------------------------------------------------------------------------
-- The loop
------------------------------------------------------------------------------------------

local function rest(e: Entry)
	local obj = e.Obj
	if e.WroteRot then
		obj.Rotation = e.BaseRot
		e.WroteRot = nil
	end
	if e.WrotePos then
		obj.Position = e.BasePos
		e.WrotePos = nil
	end
	if e.WroteSize then
		obj.Size = e.BaseSize
		e.WroteSize = nil
	end
	if e.Scale and e.Scale.Parent then
		e.Scale.Scale = 1
	end
	if e.Glow and e.Glow.Parent then
		e.Glow.Visible = false
	end
	if e.BaseColor then
		setBrightness(e, 1)
	end
	if e.Kind == "Coin" then
		setInner(e, 1)
		e.X.FlipAt = nil
	end
end

-- Re-reads the rest pose where a layout pass (not us) changed the object.
local function rebase(e: Entry)
	local obj = e.Obj
	if e.WroteRot == nil or obj.Rotation ~= e.WroteRot then
		e.BaseRot = obj.Rotation
	end
	if e.WrotePos == nil or obj.Position ~= e.WrotePos then
		e.BasePos = obj.Position
	end
	if e.WroteSize == nil or obj.Size ~= e.WroteSize then
		e.BaseSize = obj.Size
	end
	local size = obj.AbsoluteSize
	e.W, e.H = size.X, size.Y
end

local function remove(i: number)
	local e = entries[i]
	byObj[e.Obj] = nil
	local last = #entries
	entries[i] = entries[last]
	entries[last] = nil
	if e.Glow then
		e.Glow:Destroy()
		e.Glow = nil
	end
end

local function step(dt: number)
	local now = os.clock()
	local i = 1
	while i <= #entries do
		local e = entries[i]
		local obj = e.Obj
		if obj.Parent == nil then
			remove(i)
			continue
		end
		if now >= e.NextCheck then
			e.NextCheck = now + CHECK
			e.Reduced = ClientSettings.Reduced()
			local shown = isShown(obj)
			if shown ~= e.Shown then
				e.Shown = shown
				if not shown then
					rest(e)
				end
			end
			if shown then
				rebase(e)
			end
		end
		if e.Shown then
			local reduced = e.Reduced
			e.Clock += dt * (reduced and 0.35 or 1)
			STEP[e.Kind](e, e.Clock + e.Phase, reduced and 0.5 or 1, reduced)
		end
		i += 1
	end
	if #entries == 0 and conn then
		conn:Disconnect()
		conn = nil
	end
end

local function start()
	if not conn then
		conn = RunService.Heartbeat:Connect(step)
	end
end

------------------------------------------------------------------------------------------
-- Public
------------------------------------------------------------------------------------------

function IdleFx.Attach(obj: GuiObject?, kind: string, opts: { [string]: any }?): Handle?
	if not obj or not STEP[kind] then
		return nil
	end
	local old = byObj[obj]
	if old then
		rest(old)
		local idx = table.find(entries, old)
		if idx then
			remove(idx)
		end
	end
	local size = obj.AbsoluteSize
	local e: Entry = {
		Obj = obj,
		Kind = kind,
		Opts = opts or {},
		Clock = 0,
		Phase = rng:NextNumber(0, 40),
		Shown = false,
		NextCheck = 0,
		Reduced = false,
		BaseRot = obj.Rotation,
		BasePos = obj.Position,
		BaseSize = obj.Size,
		WroteRot = nil,
		WrotePos = nil,
		WroteSize = nil,
		Scale = nil,
		Glow = nil,
		BaseColor = nil,
		W = size.X,
		H = size.Y,
		X = {},
	}
	table.insert(entries, e)
	byObj[obj] = e
	start()
	return {
		Stop = function()
			IdleFx.Stop(obj)
		end,
	}
end

function IdleFx.Stop(obj: GuiObject?)
	local e = obj and byObj[obj]
	if not e then
		return
	end
	if e.Obj.Parent then
		rest(e)
	end
	local idx = table.find(entries, e)
	if idx then
		remove(idx)
	end
end

-- A Coin entry turns over once (ignored with Reduced effects or when not on screen).
function IdleFx.Flip(obj: GuiObject?)
	local e = obj and byObj[obj]
	if e and e.Kind == "Coin" and e.Shown and not e.Reduced and not e.X.FlipAt then
		e.X.FlipAt = e.Clock + e.Phase
	end
end

function IdleFx.Count(): number
	return #entries
end

function IdleFx.Stats(): { Entries: number, Shown: number, Loop: number, Kinds: { [string]: number } }
	local shown, kinds = 0, {}
	for _, e in ipairs(entries) do
		if e.Shown then
			shown += 1
		end
		kinds[e.Kind] = (kinds[e.Kind] or 0) + 1
	end
	return { Entries = #entries, Shown = shown, Loop = conn and 1 or 0, Kinds = kinds }
end

return IdleFx
