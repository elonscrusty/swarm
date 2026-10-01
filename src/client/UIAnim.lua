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

-- Endless gentle up-down float (lobby buttons, titles).
function UIAnim.Float(obj: GuiObject, pixels: number, seconds: number)
	local base = obj.Position
	local info = TweenInfo.new(seconds, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut, -1, true)
	TweenService:Create(obj, info, { Position = base + UDim2.fromOffset(0, pixels) }):Play()
end

return UIAnim
