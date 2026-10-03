--[[
	UIAnim.lua
	Small tween helpers that give the UI its motion: pop-ins, punches, slides, button
	press feedback, count-ups, pulses. Each animated object gets its own UIScale (named
	"AnimScale") so scaling never fights the layout or the global UI scale.

	Timings come from Theme.Motion (press scale 0.96, quick 0.12 s hovers, 0.22 s moves).
	The endless effects (PulseStroke, Glow, Shine) return their Tween so a screen can
	Cancel them when it closes; UIAnim.Track collects tweens (and IdleFx handles) for that.
]]

local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")

local Theme = require(game:GetService("ReplicatedStorage"):WaitForChild("Shared"):WaitForChild("Theme"))
local ClientSettings = require(script.Parent.ClientSettings)
local ClientPerformance = require(script.Parent.ClientPerformance)

local UIAnim = {}

local function scaleOf(obj: GuiObject): UIScale
	local s = obj:FindFirstChild("AnimScale") :: UIScale?
	if not s then
		local created = Instance.new("UIScale")
		created.Name = "AnimScale"
		created.Parent = obj
		s = created
	end
	return s :: UIScale
end
UIAnim.ScaleOf = scaleOf

-- UIAnim.Punch's replayable tweens (weak keys: gone with their UIScale)
local PUNCH_INFO = TweenInfo.new(0.3, Enum.EasingStyle.Back, Enum.EasingDirection.Out)
local punchTweens: { [UIScale]: Tween } = setmetatable({}, { __mode = "k" }) :: any

function UIAnim.Tween(obj: Instance, seconds: number, goal: { [string]: any }, style: Enum.EasingStyle?, dir: Enum.EasingDirection?): Tween
	local t = TweenService:Create(obj, TweenInfo.new(seconds, style or Enum.EasingStyle.Quad, dir or Enum.EasingDirection.Out), goal)
	t:Play()
	return t
end

-- Grows from small to full size with a springy overshoot.
function UIAnim.Pop(obj: GuiObject, delay: number?, from: number?)
	local s = scaleOf(obj)
	if ClientSettings.Reduced() then
		s.Scale = 1 -- reduced motion: no grow-in
		return
	end
	s.Scale = from or 0.6
	local function go()
		UIAnim.Tween(s, Theme.Motion.Slow, { Scale = 1 }, Enum.EasingStyle.Back)
	end
	if delay and delay > 0 then
		task.delay(delay, go)
	else
		go()
	end
end

-- Shrinks away, then calls done (e.g. to hide the object).
function UIAnim.PopOut(obj: GuiObject, done: (() -> ())?)
	local s = scaleOf(obj)
	local t = UIAnim.Tween(s, 0.16, { Scale = 0.9 }, Enum.EasingStyle.Quad, Enum.EasingDirection.In)
	t.Completed:Once(function()
		s.Scale = 1
		if done then
			done()
		end
	end)
end

-- Quick "bump" (counters, timer at a new minute, level number).
function UIAnim.Punch(obj: GuiObject, amount: number?)
	if ClientSettings.Reduced() then
		return
	end
	local s = scaleOf(obj)
	s.Scale = 1 + (amount or 0.25)
	-- one Tween per scale, replayed (a burst of gold / kills punches every frame: no
	-- new Tween each time); Play restarts from the value just set, like a fresh tween
	local t = punchTweens[s]
	if not t then
		t = TweenService:Create(s, PUNCH_INFO, { Scale = 1 })
		punchTweens[s] = t
	end
	t:Play()
end

-- Fades a frame's background from invisible to `target` transparency.
function UIAnim.FadeIn(obj: GuiObject, target: number, seconds: number?)
	obj.BackgroundTransparency = 1
	UIAnim.Tween(obj, seconds or 0.25, { BackgroundTransparency = target })
end

--[[
	Press / hover feedback for a plain button (swatches, small tiles): brighten the fill
	without scaling its hit target or changing a list's layout. Bigger components (UIKit buttons and cards)
	use their own lift-and-brighten states instead.
]]
function UIAnim.Button(b: GuiButton)
	local resting = b.BackgroundTransparency
	local hovering = false
	local function show(amount: number)
		UIAnim.Tween(b, Theme.Motion.Fast, { BackgroundTransparency = math.max(0, resting - amount) })
	end
	b.MouseEnter:Connect(function()
		if b.Active then
			hovering = true
			show(0.1)
		end
	end)
	b.MouseLeave:Connect(function()
		hovering = false
		show(0)
	end)
	b.MouseButton1Down:Connect(function()
		if b.Active then
			show(0.15)
		end
	end)
	b.MouseButton1Up:Connect(function()
		show(hovering and 0.1 or 0)
	end)
end

-- Counts a number label up from 0 to `value` using `format` (e.g. "Kills: %d").
function UIAnim.CountUp(label: TextLabel, value: number, format: string, seconds: number?, delay: number?)
	local token = {}
	label:SetAttribute("CountToken", tostring(token))
	label.Text = string.format(format, 0)
	task.delay(delay or 0, function()
		local duration = seconds or 0.8
		local start = os.clock()
		while label.Parent and label:GetAttribute("CountToken") == tostring(token) do
			local a = math.clamp((os.clock() - start) / duration, 0, 1)
			local eased = 1 - (1 - a) ^ 3
			label.Text = string.format(format, math.floor(value * eased + 0.5))
			if a >= 1 then
				UIAnim.Punch(label, 0.15)
				break
			end
			task.wait()
		end
	end)
end

-- Endless gentle pulse of a UIStroke's thickness (legendary cards, glowing buttons).
function UIAnim.PulseStroke(stroke: UIStroke, minThickness: number, maxThickness: number): Tween
	stroke.Thickness = minThickness
	local info = TweenInfo.new(0.6, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut, -1, true)
	local t = TweenService:Create(stroke, info, { Thickness = maxThickness })
	t:Play()
	return t
end

-- Endless slow "breathing" of a glow (a stroke's or frame's transparency between a and b).
function UIAnim.Glow(obj: Instance, property: string, a: number, b: number, seconds: number?): Tween
	(obj :: any)[property] = a
	local info = TweenInfo.new(seconds or 1.6, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut, -1, true)
	local t = TweenService:Create(obj, info, { [property] = b })
	t:Play()
	return t
end

-- Number formatters by label (CountTo); a formatter turns the animated value into text.
local formatters: { [TextLabel]: (number) -> string } = setmetatable({}, { __mode = "k" }) :: any

--[[
	Animates a number label from `from` to `to` (gold counter). Restarts cleanly when called
	again before it finishes. `format` is a string.format pattern or a function.
]]
function UIAnim.CountTo(label: TextLabel, from: number, to: number, format: string | (number) -> string, seconds: number?)
	local fmt: (number) -> string
	if type(format) == "function" then
		fmt = format
	else
		local pattern = format :: string
		fmt = function(n: number): string
			return string.format(pattern, n)
		end
	end
	formatters[label] = fmt
	local value = label:FindFirstChild("CountValue") :: NumberValue?
	if not value then
		local v = Instance.new("NumberValue")
		v.Name = "CountValue"
		v.Parent = label
		v.Changed:Connect(function(n)
			local f = formatters[label]
			if f then
				label.Text = f(math.floor(n + 0.5))
			end
		end)
		value = v
	end
	local nv = value :: NumberValue
	nv.Value = from
	label.Text = fmt(math.floor(from + 0.5))
	if from ~= to then
		UIAnim.Tween(nv, seconds or 0.6, { Value = to }, Enum.EasingStyle.Quart)
		if to > from then
			UIAnim.Punch(label, 0.12)
		end
	end
end

-- A light streak that sweeps across a button every few seconds (the parent should clip).
function UIAnim.Shine(obj: GuiObject, period: number?, transparency: number?): Tween
	local streak = Instance.new("Frame")
	streak.Name = "Shine"
	streak.BackgroundColor3 = Theme.Color.Hover
	streak.BackgroundTransparency = transparency or 0.82
	streak.BorderSizePixel = 0
	streak.AnchorPoint = Vector2.new(0.5, 0.5)
	streak.Size = UDim2.new(0, 22, 2, 0)
	streak.Rotation = 20
	streak.Position = UDim2.fromScale(-0.3, 0.5)
	streak.ZIndex = obj.ZIndex + 1
	streak.Parent = obj
	local info = TweenInfo.new(0.8, Enum.EasingStyle.Quad, Enum.EasingDirection.InOut, -1, false, period or 2.5)
	local t = TweenService:Create(streak, info, { Position = UDim2.fromScale(1.3, 0.5) })
	t:Play()
	return t
end

--[[
	A bag of tweens / connections owned by one screen: Add(x) keeps it, Clear() cancels
	every tween and disconnects every connection (call it when the screen closes or
	rebuilds, so endless effects never keep running on hidden UI).
]]
export type Track = { Add: (any) -> any, Clear: () -> () }
function UIAnim.Track(): Track
	local items: { any } = {}
	local track = {}
	function track.Add(x: any): any
		if x ~= nil then
			table.insert(items, x)
		end
		return x
	end
	function track.Clear()
		for _, x in ipairs(items) do
			if typeof(x) == "Instance" and x:IsA("Tween") then
				x:Cancel()
			elseif typeof(x) == "RBXScriptConnection" then
				x:Disconnect()
			elseif type(x) == "table" and type(x.Stop) == "function" then
				x.Stop() -- an IdleFx handle
			end
		end
		table.clear(items)
	end
	return track
end

-- Endless loop toward `goal` that jumps back to the start.
function UIAnim.Loop(obj: Instance, seconds: number, goal: { [string]: any }, delay: number?)
	local info = TweenInfo.new(seconds, Enum.EasingStyle.Linear, Enum.EasingDirection.Out, -1, false, delay or 0)
	TweenService:Create(obj, info, goal):Play()
end

-- Endless gentle scale "breath" on a wrapper frame (idle pulse of the main button).
-- Uses its own UIScale ("BreathScale") so it never fights press feedback.
function UIAnim.Breathe(obj: GuiObject, amount: number, seconds: number)
	local s = Instance.new("UIScale")
	s.Name = "BreathScale"
	s.Parent = obj
	local info = TweenInfo.new(seconds, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut, -1, true)
	TweenService:Create(s, info, { Scale = 1 + amount }):Play()
end

--[[
	Screen change: the old screen slides out (direction -1 = to the left) while the new one
	slides in from the other side. Positions are restored to `home` (both screens are
	full-size frames at 0,0).
]]
function UIAnim.SwapScreens(old: GuiObject?, newScreen: GuiObject, direction: number, seconds: number?)
	-- quick: at most 0.2 s (menus must feel fast), shorter still with reduced motion
	local t = math.min(seconds or 0.2, ClientSettings.Reduced() and 0.1 or 0.2)
	local home = UDim2.fromScale(0, 0)
	if old and old ~= newScreen then
		local token = (tonumber(old:GetAttribute("SwapToken")) or 0) + 1
		old:SetAttribute("SwapToken", token)
		local tw = UIAnim.Tween(old, t * 0.8, { Position = UDim2.new(-0.25 * direction, 0, 0, 0) }, Enum.EasingStyle.Quad, Enum.EasingDirection.In)
		tw.Completed:Once(function()
			if old:GetAttribute("SwapToken") == token then
				old.Visible = false
				old.Position = home
			end
		end)
	end
	newScreen:SetAttribute("SwapToken", (tonumber(newScreen:GetAttribute("SwapToken")) or 0) + 1)
	newScreen.Visible = true
	newScreen.Position = UDim2.new(0.25 * direction, 0, 0, 0)
	UIAnim.Tween(newScreen, t, { Position = home }, Enum.EasingStyle.Quint)
end

-- Endless gentle up-down float (titles).
function UIAnim.Float(obj: GuiObject, pixels: number, seconds: number)
	local base = obj.Position
	local info = TweenInfo.new(seconds, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut, -1, true)
	TweenService:Create(obj, info, { Position = base + UDim2.fromOffset(0, pixels) }):Play()
end

--[[
	Flashy extras for the menus. All of them honour (ClientSettings.Reduced() or ClientPerformance.Reduced()) (they do
	little or nothing) and clean up after themselves: Burst and Sweep are one-shot,
	Motes returns a stop function the screen calls when it hides.
]]

-- One light streak sweeps across `obj` once (the parent should clip). Returns nothing.
function UIAnim.Sweep(obj: GuiObject, delay: number?, transparency: number?, seconds: number?)
	if (ClientSettings.Reduced() or ClientPerformance.Reduced()) then
		return
	end
	local streak = Instance.new("Frame")
	streak.Name = "SweepOnce"
	streak.BackgroundColor3 = Color3.new(1, 1, 1)
	streak.BackgroundTransparency = transparency or 0.7
	streak.BorderSizePixel = 0
	streak.AnchorPoint = Vector2.new(0.5, 0.5)
	streak.Size = UDim2.new(0, 26, 2, 0)
	streak.Rotation = 20
	streak.Position = UDim2.fromScale(-0.2, 0.5)
	streak.ZIndex = obj.ZIndex + 5
	streak.Visible = false
	streak.Parent = obj
	task.delay(delay or 0, function()
		if not streak.Parent then
			return
		end
		streak.Visible = true
		local t = UIAnim.Tween(streak, seconds or 0.55, { Position = UDim2.fromScale(1.2, 0.5) }, Enum.EasingStyle.Quad, Enum.EasingDirection.InOut)
		t.Completed:Once(function()
			streak:Destroy()
		end)
	end)
end

--[[
	Confetti / sparkle burst of small frames from a point (`center` is a UDim2 inside
	`parent`). `colors` is a list of Color3. Pieces fly out, spin, drop and fade in about
	0.8 s, then destroy themselves. Reduced effects: a handful, no spin.
]]
function UIAnim.Burst(parent: GuiObject, center: UDim2, colors: { Color3 }, count: number?, spread: number?)
	local n = count or 18
	local reduced = (ClientSettings.Reduced() or ClientPerformance.Reduced())
	if reduced then
		n = math.min(n, 5)
	end
	local reach = spread or 90
	local rng = Random.new()
	for i = 1, n do
		local star = i % 3 == 0
		local size = star and rng:NextInteger(8, 14) or rng:NextInteger(4, 8)
		local piece = Instance.new("Frame")
		piece.Name = "BurstPiece"
		piece.BackgroundColor3 = colors[(i - 1) % #colors + 1]
		piece.BorderSizePixel = 0
		piece.AnchorPoint = Vector2.new(0.5, 0.5)
		piece.Size = UDim2.fromOffset(size, star and size or size * 1.6)
		piece.Position = center
		piece.Rotation = star and 45 or rng:NextInteger(0, 90)
		piece.ZIndex = parent.ZIndex + 20
		piece.Parent = parent
		local angle = rng:NextNumber(0, math.pi * 2)
		local dist = rng:NextNumber(0.4, 1) * reach
		local life = rng:NextNumber(0.55, 0.9)
		local goal = UDim2.new(center.X.Scale, center.X.Offset + math.cos(angle) * dist, center.Y.Scale, center.Y.Offset + math.sin(angle) * dist + (star and 0 or 26))
		UIAnim.Tween(piece, life, { Position = goal }, Enum.EasingStyle.Quart)
		local fade = UIAnim.Tween(piece, life, { BackgroundTransparency = 1, Rotation = reduced and piece.Rotation or piece.Rotation + rng:NextInteger(-200, 200) }, Enum.EasingStyle.Quad, Enum.EasingDirection.In)
		fade.Completed:Once(function()
			piece:Destroy()
		end)
	end
end

--[[
	Slow drifting light motes behind a screen (embers / fireflies). Returns a stop
	function that cancels the tweens and removes the layer: call it when the screen hides.
	Reduced effects: no motes at all.
]]
function UIAnim.Motes(parent: GuiObject, count: number?, color: Color3?): () -> ()
	if (ClientSettings.Reduced() or ClientPerformance.Reduced()) then
		return function() end
	end
	local layer = Instance.new("Frame")
	layer.Name = "Motes"
	layer.BackgroundTransparency = 1
	layer.Size = UDim2.fromScale(1, 1)
	layer.Active = false
	layer.ZIndex = math.max(parent.ZIndex - 1, 0)
	layer.Parent = parent
	local rng = Random.new()
	local tweens: { Tween } = {}
	local paused = false
	for _ = 1, count or 12 do
		local size = rng:NextInteger(2, 5)
		local mote = Instance.new("Frame")
		mote.Name = "Mote"
		mote.BackgroundColor3 = color or Theme.Color.Hover
		mote.BackgroundTransparency = rng:NextNumber(0.55, 0.85)
		mote.BorderSizePixel = 0
		mote.Size = UDim2.fromOffset(size, size)
		mote.Rotation = 45
		local x = rng:NextNumber(0.02, 0.98)
		mote.Position = UDim2.fromScale(x, rng:NextNumber(0, 1))
		mote.Parent = layer
		-- first leg finishes the current climb, then loops over the whole height
		local seconds = rng:NextNumber(9, 16)
		local info = TweenInfo.new(seconds, Enum.EasingStyle.Linear, Enum.EasingDirection.Out, -1, false, 0)
		mote.Position = UDim2.fromScale(x, 1.04)
		local t = TweenService:Create(mote, info, { Position = UDim2.fromScale(x + rng:NextNumber(-0.06, 0.06), -0.04) })
		task.delay(rng:NextNumber(0, seconds), function()
			if layer.Parent and not paused then
				t:Play()
			end
		end)
		table.insert(tweens, t)
	end
	task.spawn(function()
		while layer.Parent do
			task.wait(0.5)
			if not layer.Parent then break end
			local reduced = ClientSettings.Reduced() or ClientPerformance.Reduced()
			if paused ~= reduced then
				paused = reduced
				layer.Visible = not reduced
				for _, t in ipairs(tweens) do
					if reduced then t:Cancel() else t:Play() end
				end
			end
		end
	end)
	return function()
		for _, t in ipairs(tweens) do
			t:Cancel()
		end
		layer:Destroy()
	end
end

-- Staggered pop-in for a list of objects (each `step` seconds later), one call per screen.
function UIAnim.Cascade(objs: { GuiObject }, step: number?, from: number?, limit: number?)
	local reduced = (ClientSettings.Reduced() or ClientPerformance.Reduced())
	for i, o in ipairs(objs) do
		if i > (limit or 14) then
			break
		end
		UIAnim.Pop(o, reduced and 0 or (step or 0.03) * i, reduced and 0.97 or from or 0.85)
	end
end

-- A glow flash (a bright frame that fades) over `obj`: purchase / unlock feedback.
function UIAnim.Flash(obj: GuiObject, color: Color3?)
	if (ClientSettings.Flashes() or ClientPerformance.Reduced()) then
		return
	end
	local f = Instance.new("Frame")
	f.Name = "Flash"
	f.BackgroundColor3 = color or Color3.new(1, 1, 1)
	f.BackgroundTransparency = 0.55
	f.BorderSizePixel = 0
	f.Size = UDim2.fromScale(1, 1)
	f.ZIndex = obj.ZIndex + 6
	f.Parent = obj
	local corner = obj:FindFirstChildWhichIsA("UICorner")
	if corner then
		corner:Clone().Parent = f
	end
	local t = UIAnim.Tween(f, 0.45, { BackgroundTransparency = 1 })
	t.Completed:Once(function()
		f:Destroy()
	end)
end

------------------------------------------------------------------------------------------
-- One-shot flourishes (event-driven; each cleans itself up; skipped with Reduced effects)
------------------------------------------------------------------------------------------

-- A bright streak that crosses `obj` once (the parent should clip: bars, tiles).
function UIAnim.SweepOnce(obj: GuiObject, color: Color3?, seconds: number?, transparency: number?)
	if (ClientSettings.Reduced() or ClientPerformance.Reduced()) then
		return
	end
	local streak = Instance.new("Frame")
	streak.Name = "SweepOnce"
	streak.BackgroundColor3 = color or Theme.Color.Hover
	streak.BackgroundTransparency = transparency or 0.35
	streak.BorderSizePixel = 0
	streak.AnchorPoint = Vector2.new(0.5, 0.5)
	streak.Size = UDim2.new(0.18, 0, 2, 0)
	streak.Rotation = 20
	streak.Position = UDim2.fromScale(-0.2, 0.5)
	streak.ZIndex = obj.ZIndex + 4
	streak.Parent = obj
	local t = UIAnim.Tween(streak, seconds or 0.55, { Position = UDim2.fromScale(1.2, 0.5), BackgroundTransparency = 1 }, Enum.EasingStyle.Quad, Enum.EasingDirection.In)
	t.Completed:Once(function()
		streak:Destroy()
	end)
end

-- Sparks in flight, driven by one RenderStepped connection (only while any fly) and
-- recycled through a small pool: a big swarm's gold / kill sparks create no Frames or
-- Tweens per burst. Motion matches the old Quad-out tween (position, fade, shrink to 1 px).
local SPARK_POOL_MAX = 64
local sparkPool: { Frame } = {}
local sparks: { { [string]: any } } = {}
local sparkConn: RBXScriptConnection? = nil

local function stepSparks()
	local now = os.clock()
	local i = 1
	while i <= #sparks do
		local s = sparks[i]
		local f: Frame = s.Frame
		local t = (now - s.T0) / s.Dur
		if t >= 1 or f.Parent ~= s.Parent then
			-- done (or its parent went away): back to the pool when still usable
			local intact = f.Parent == s.Parent
			sparks[i] = sparks[#sparks]
			sparks[#sparks] = nil
			if intact and #sparkPool < SPARK_POOL_MAX then
				f.Parent = nil
				table.insert(sparkPool, f)
			else
				f:Destroy()
			end
		else
			local e = 1 - (1 - t) * (1 - t) -- Quad out
			f.Position = (s.From :: UDim2):Lerp(s.To, e)
			f.BackgroundTransparency = e
			local px = s.Size + (1 - s.Size) * e
			f.Size = UDim2.fromOffset(px, px)
			i += 1
		end
	end
	if #sparks == 0 and sparkConn then
		sparkConn:Disconnect()
		sparkConn = nil
	end
end

-- Radial sparks flying out of `center` (a UDim2 inside `parent`) and fading.
function UIAnim.Sparks(parent: GuiObject, center: UDim2, color: Color3, count: number?, distance: number?, seconds: number?)
	if (ClientSettings.Reduced() or ClientPerformance.Reduced()) then
		return
	end
	local n = count or 10
	local dist = distance or 46
	local dur = seconds or 0.55
	local now = os.clock()
	for i = 1, n do
		local a = (i / n) * math.pi * 2 + (i % 3) * 0.2
		local d = dist * (0.65 + 0.35 * ((i * 7) % 5) / 4)
		local size = 4 + (i % 3) * 2
		local spark = table.remove(sparkPool)
		if not spark then
			spark = Instance.new("Frame")
			spark.Name = "Spark"
			spark.BorderSizePixel = 0
			spark.AnchorPoint = Vector2.new(0.5, 0.5)
			spark.Rotation = 45
		end
		local f = spark :: Frame
		f.BackgroundColor3 = color
		f.BackgroundTransparency = 0
		f.Size = UDim2.fromOffset(size, size)
		f.Position = center
		f.ZIndex = parent.ZIndex + 5
		f.Parent = parent
		table.insert(sparks, { Frame = f, Parent = parent, T0 = now, Dur = dur, From = center, To = center + UDim2.fromOffset(math.cos(a) * d, math.sin(a) * d), Size = size })
	end
	if not sparkConn then
		sparkConn = RunService.RenderStepped:Connect(stepSparks)
	end
end

-- A ring that expands from `center` to `endSize` pixels while fading (level-up pulse).
function UIAnim.Ring(parent: GuiObject, center: UDim2, color: Color3, endSize: number?, seconds: number?)
	if (ClientSettings.Reduced() or ClientPerformance.Reduced()) then
		return
	end
	local ring = Instance.new("Frame")
	ring.Name = "RingPulse"
	ring.BackgroundTransparency = 1
	ring.AnchorPoint = Vector2.new(0.5, 0.5)
	ring.Size = UDim2.fromOffset(8, 8)
	ring.Position = center
	ring.ZIndex = parent.ZIndex + 4
	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(1, 0)
	corner.Parent = ring
	local stroke = Instance.new("UIStroke")
	stroke.Color = color
	stroke.Thickness = 3
	stroke.Parent = ring
	ring.Parent = parent
	local dur = seconds or 0.5
	local e = endSize or 90
	local t = UIAnim.Tween(ring, dur, { Size = UDim2.fromOffset(e, e) }, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
	UIAnim.Tween(stroke, dur, { Transparency = 1, Thickness = 0.5 })
	t.Completed:Once(function()
		ring:Destroy()
	end)
end

-- Quick positional jitter that settles back where it started. The shake is an offset on
-- top of whatever position the object has right now, so a relayout during the shake (the
-- HUD placing a pill under a timer that just moved) is kept instead of being undone when
-- the shake ends; a shake started while another runs takes over its offset (no drift).
local shakeApplied: { [GuiObject]: UDim2 } = setmetatable({}, { __mode = "k" }) :: any
local shakeToken: { [GuiObject]: number } = setmetatable({}, { __mode = "k" }) :: any
function UIAnim.Shake(obj: GuiObject, pixels: number?, seconds: number?)
	if (ClientSettings.Reduced() or ClientPerformance.Reduced()) then
		return
	end
	local token = (shakeToken[obj] or 0) + 1
	shakeToken[obj] = token
	local amp = pixels or 6
	local steps = 6
	local each = (seconds or 0.3) / steps
	task.spawn(function()
		for i = 1, steps do
			if not obj.Parent or shakeToken[obj] ~= token then
				return
			end
			local k = (1 - i / steps) * amp
			local dir = (i % 2 == 0) and 1 or -1
			local offset = UDim2.fromOffset(dir * k, (i % 3 - 1) * k * 0.5)
			obj.Position = obj.Position - (shakeApplied[obj] or UDim2.new()) + offset
			shakeApplied[obj] = offset
			task.wait(each)
		end
		if shakeToken[obj] == token then
			if obj.Parent then
				obj.Position = obj.Position - (shakeApplied[obj] or UDim2.new())
			end
			shakeApplied[obj] = nil
			shakeToken[obj] = nil
		end
	end)
end

--[[
	Menu motion (lobby screens). Every helper scales an inner frame (a button's Face, a
	pill, an icon) through its existing UIScale, never a hit box, and is skipped or cut
	short with reduced effects. Idle loops return a Tween to put in a screen's Track so
	they stop when the screen hides.
]]

function UIAnim.Reduced(): boolean
	return ClientSettings.Reduced() or ClientPerformance.Reduced()
end

-- The UIScale to animate: a UIKit button face's "Press" scale, else the AnimScale.
local function innerScale(obj: GuiObject): UIScale
	local press = obj:FindFirstChild("Press")
	if press and press:IsA("UIScale") then
		return press
	end
	return scaleOf(obj)
end

-- Small springy bump on an inner frame (a tab or button face just selected).
function UIAnim.Bump(obj: GuiObject?, amount: number?)
	if not obj or ClientSettings.Reduced() then
		return
	end
	local s = innerScale(obj)
	s.Scale = 1 + (amount or 0.06)
	UIAnim.Tween(s, 0.25, { Scale = 1 }, Enum.EasingStyle.Back)
end

-- Something was selected / equipped / bought: a bump plus a few sparks around it.
function UIAnim.Selected(obj: GuiObject?, color: Color3?)
	if not obj then
		return
	end
	UIAnim.Bump(obj, 0.12)
	UIAnim.Sparks(obj, UDim2.fromScale(0.5, 0.5), color or Theme.Palette.gold_300, 6, 26, 0.45)
end

-- Slides an underline / highlight frame to a new position and size (tab switch).
function UIAnim.SlideTo(obj: GuiObject, position: UDim2, size: UDim2?)
	local goal: { [string]: any } = { Position = position }
	if size then
		goal.Size = size
	end
	if UIAnim.Reduced() then
		obj.Position = position
		if size then
			obj.Size = size
		end
		return
	end
	UIAnim.Tween(obj, 0.18, goal, Enum.EasingStyle.Quint)
end

-- Endless gentle pulse of one property (a selected row's accent, a badge); nil with
-- reduced effects. Put the tween in the screen's Track.
function UIAnim.IdlePulse(obj: Instance, property: string, a: number, b: number, seconds: number?): Tween?
	if UIAnim.Reduced() then
		return nil
	end
	return UIAnim.Glow(obj, property, a, b, seconds or 1.4)
end

return UIAnim
