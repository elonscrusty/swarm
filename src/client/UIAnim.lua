--[[
	UIAnim.lua
	Small tween helpers that give the UI its motion: pop-ins, punches, slides, button
	press feedback, count-ups, pulses. Each animated object gets its own UIScale (named
	"AnimScale") so scaling never fights the layout or the global UI scale.
]]

local TweenService = game:GetService("TweenService")

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

function UIAnim.Tween(obj: Instance, seconds: number, goal: { [string]: any }, style: Enum.EasingStyle?, dir: Enum.EasingDirection?): Tween
	local t = TweenService:Create(obj, TweenInfo.new(seconds, style or Enum.EasingStyle.Quad, dir or Enum.EasingDirection.Out), goal)
	t:Play()
	return t
end

-- Grows from small to full size with a springy overshoot.
function UIAnim.Pop(obj: GuiObject, delay: number?, from: number?)
	local s = scaleOf(obj)
	s.Scale = from or 0.6
	local function go()
		UIAnim.Tween(s, 0.35, { Scale = 1 }, Enum.EasingStyle.Back)
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
	local t = UIAnim.Tween(s, 0.16, { Scale = 0.85 }, Enum.EasingStyle.Quad, Enum.EasingDirection.In)
	t.Completed:Once(function()
		s.Scale = 1
		if done then
			done()
		end
	end)
end

-- Quick "bump" (counters, timer at a new minute, level number).
function UIAnim.Punch(obj: GuiObject, amount: number?)
	local s = scaleOf(obj)
	s.Scale = 1 + (amount or 0.25)
	UIAnim.Tween(s, 0.3, { Scale = 1 }, Enum.EasingStyle.Back)
end

-- Slides in from an offset (in pixels) while fading in, staggered by `delay`.
function UIAnim.SlideIn(obj: GuiObject, offset: Vector2, delay: number?)
	local target = obj.Position
	obj.Position = target + UDim2.fromOffset(offset.X, offset.Y)
	local s = scaleOf(obj)
	s.Scale = 0.9
	task.delay(delay or 0, function()
		UIAnim.Tween(obj, 0.4, { Position = target }, Enum.EasingStyle.Back)
		UIAnim.Tween(s, 0.4, { Scale = 1 }, Enum.EasingStyle.Back)
	end)
end

-- Fades a frame's background from invisible to `target` transparency.
function UIAnim.FadeIn(obj: GuiObject, target: number, seconds: number?)
	obj.BackgroundTransparency = 1
	UIAnim.Tween(obj, seconds or 0.25, { BackgroundTransparency = target })
end

-- Press / hover feedback for any button.
function UIAnim.Button(b: GuiButton)
	local s = scaleOf(b)
	b.MouseEnter:Connect(function()
		UIAnim.Tween(s, 0.12, { Scale = 1.05 })
	end)
	b.MouseLeave:Connect(function()
		UIAnim.Tween(s, 0.12, { Scale = 1 })
	end)
	b.MouseButton1Down:Connect(function()
		UIAnim.Tween(s, 0.08, { Scale = 0.92 })
	end)
	b.MouseButton1Up:Connect(function()
		UIAnim.Tween(s, 0.25, { Scale = 1 }, Enum.EasingStyle.Back)
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

-- Endless gentle pulse of a UIStroke (legendary cards, glowing buttons).
function UIAnim.PulseStroke(stroke: UIStroke, minThickness: number, maxThickness: number)
	stroke.Thickness = minThickness
	local info = TweenInfo.new(0.6, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut, -1, true)
	TweenService:Create(stroke, info, { Thickness = maxThickness }):Play()
end

-- Animates a number label from `from` to `to` (gold counter). Restarts cleanly when called
-- again before it finishes.
function UIAnim.CountTo(label: TextLabel, from: number, to: number, format: string, seconds: number?)
	local value = label:FindFirstChild("CountValue") :: NumberValue?
	if not value then
		local v = Instance.new("NumberValue")
		v.Name = "CountValue"
		v.Parent = label
		v.Changed:Connect(function(n)
			label.Text = string.format(tostring(label:GetAttribute("CountFormat") or "%d"), math.floor(n + 0.5))
		end)
		value = v
	end
	local nv = value :: NumberValue
	label:SetAttribute("CountFormat", format)
	nv.Value = from
	label.Text = string.format(format, math.floor(from + 0.5))
	if from ~= to then
		UIAnim.Tween(nv, seconds or 0.6, { Value = to }, Enum.EasingStyle.Quart)
		if to > from then
			UIAnim.Punch(label, 0.12)
		end
	end
end

-- A light streak that sweeps across a button every few seconds (the parent should clip).
function UIAnim.Shine(obj: GuiObject, period: number?)
	local streak = Instance.new("Frame")
	streak.Name = "Shine"
	streak.BackgroundColor3 = Color3.new(1, 1, 1)
	streak.BackgroundTransparency = 0.8
	streak.BorderSizePixel = 0
	streak.AnchorPoint = Vector2.new(0.5, 0.5)
	streak.Size = UDim2.new(0, 26, 2, 0)
	streak.Rotation = 20
	streak.Position = UDim2.fromScale(-0.3, 0.5)
	streak.ZIndex = obj.ZIndex + 1
	streak.Parent = obj
	local info = TweenInfo.new(0.7, Enum.EasingStyle.Quad, Enum.EasingDirection.InOut, -1, false, period or 2.5)
	TweenService:Create(streak, info, { Position = UDim2.fromScale(1.3, 0.5) }):Play()
end

-- Endless loop toward `goal` that jumps back to the start (drifting background dots).
function UIAnim.Loop(obj: Instance, seconds: number, goal: { [string]: any }, delay: number?)
	local info = TweenInfo.new(seconds, Enum.EasingStyle.Linear, Enum.EasingDirection.Out, -1, false, delay or 0)
	TweenService:Create(obj, info, goal):Play()
end

-- Endless gentle scale "breath" on a wrapper frame (main mode buttons idle pulse).
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
	local t = seconds or 0.3
	local home = UDim2.fromScale(0, 0)
	if old and old ~= newScreen then
		local token = (tonumber(old:GetAttribute("SwapToken")) or 0) + 1
		old:SetAttribute("SwapToken", token)
		local tw = UIAnim.Tween(old, t * 0.8, { Position = UDim2.new(-0.35 * direction, 0, 0, 0) }, Enum.EasingStyle.Quad, Enum.EasingDirection.In)
		tw.Completed:Once(function()
			if old:GetAttribute("SwapToken") == token then
				old.Visible = false
				old.Position = home
			end
		end)
	end
	newScreen:SetAttribute("SwapToken", (tonumber(newScreen:GetAttribute("SwapToken")) or 0) + 1)
	newScreen.Visible = true
	newScreen.Position = UDim2.new(0.35 * direction, 0, 0, 0)
	UIAnim.Tween(newScreen, t, { Position = home }, Enum.EasingStyle.Back)
end

-- Endless gentle up-down float (lobby buttons, titles).
function UIAnim.Float(obj: GuiObject, pixels: number, seconds: number)
	local base = obj.Position
	local info = TweenInfo.new(seconds, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut, -1, true)
	TweenService:Create(obj, info, { Position = base + UDim2.fromOffset(0, pixels) }):Play()
end

return UIAnim
