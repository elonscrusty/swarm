--[[
	TextFit.lua
	Keeps the player's Roblox "Text size" accessibility setting (GuiService.PreferredTextSize)
	from breaking layouts, without throwing it away.

	Roblox scales every TextSize-sized label by that setting at render time (about 1.6x on
	the owner's iPhone, docs/MOBILE_FIX.md); TextScaled labels are not scaled, and no label
	grows past a UITextSizeConstraint's MaxTextSize. Our layouts are measured for the
	designed TextSize, so a big setting cut "BACK" to "BA...", stacked two-line rows on top
	of each other and pushed text out of fixed panels.

	For every TextLabel / TextButton under the watched roots (not TextScaled, not opted out,
	no constraint of its own) TextFit adds a UITextSizeConstraint named "TextFit" and steps
	its MaxTextSize through
	    designed x Config.UI.TextGrowMax  ->  halfway  ->  designed
	until the label reports TextFits: text grows where its label has room and falls back to
	the designed size (which the layouts are checked at) where it would be cut or overflow.
	A label that got smaller re-checks only by shrinking; one that got bigger starts again
	from the top. Nothing is added while the setting is the default (Medium).

	Opt a label out with the attribute NoTextFit = true (it then keeps its designed size).
]]

local GuiService = game:GetService("GuiService")
local RunService = game:GetService("RunService")

local Config = require(game:GetService("ReplicatedStorage"):WaitForChild("Shared"):WaitForChild("Config"))

local TextFit = {}

local NAME = "TextFit"
local MAX_RESTARTS = 8 -- per label; after that it keeps its designed size (no flicker loops)
local PER_FRAME = 300 -- labels looked at per Heartbeat
type Entry = {
	Level: number, -- 1 = most growth ... 3 = designed size
	Fit: Vector2?, -- AbsoluteSize the current level was settled at
	Want: string?, -- "restart" | "check" | nil
	Restarts: number,
	Size: number, -- TextSize the level was computed for
	Conns: { RBXScriptConnection },
}

local roots: { Instance } = {}
local entries: { [Instance]: Entry } = {}
local pending: { [Instance]: boolean } = {}
local active = false
local stepConn: RBXScriptConnection? = nil

local function growMax(): number
	return (Config.UI and Config.UI.TextGrowMax) or 1.25
end

-- Whether the player's setting is above the default (TextFit is idle otherwise).
function TextFit.Enlarged(): boolean
	local ok, v = pcall(function()
		return GuiService.PreferredTextSize
	end)
	return ok and v ~= nil and v ~= Enum.PreferredTextSize.Medium
end

local function isText(obj: Instance): boolean
	return obj:IsA("TextLabel") or obj:IsA("TextButton")
end

-- MaxTextSize for a level (1 = most growth, 3 = the designed size).
local function capFor(size: number, level: number): number
	local g = growMax()
	if level <= 1 then
		return math.max(1, math.floor(size * g))
	elseif level == 2 then
		return math.max(1, math.floor(size * (1 + g) / 2))
	end
	return math.max(1, math.floor(size + 0.5))
end

local function ownConstraint(label: Instance): UITextSizeConstraint?
	return label:FindFirstChild(NAME) :: UITextSizeConstraint?
end

local function foreignConstraint(label: Instance): boolean
	for _, c in ipairs(label:GetChildren()) do
		if c:IsA("UITextSizeConstraint") and c.Name ~= NAME then
			return true
		end
	end
	return false
end

local function release(label: Instance)
	local e = entries[label]
	if e then
		for _, c in ipairs(e.Conns) do
			c:Disconnect()
		end
		entries[label] = nil
	end
	pending[label] = nil
	local own = ownConstraint(label)
	if own then
		own:Destroy()
	end
end

-- Writes the level's cap (only from step(), never inside a layout signal).
local function apply(label: any, e: Entry)
	local own = ownConstraint(label)
	if not own then
		own = Instance.new("UITextSizeConstraint")
		own.Name = NAME
		own.MinTextSize = 1
		own.Parent = label
	end
	local cap = capFor(e.Size, e.Level)
	if own.MaxTextSize ~= cap then
		own.MaxTextSize = cap
	end
end

-- Should this label be managed now? (TextScaled text ignores the setting; a label with its
-- own UITextSizeConstraint already has a bound; NoTextFit keeps the designed size.)
local function eligible(label: any): boolean
	return not label.TextScaled and label:GetAttribute("NoTextFit") ~= true and not foreignConstraint(label)
end

local function want(label: Instance, what: string)
	local e = entries[label]
	if not e then
		return
	end
	if e.Want ~= "restart" then
		e.Want = what
	end
	pending[label] = true
end

local function watch(label: any)
	if entries[label] then
		return
	end
	local e: Entry = { Level = 1, Fit = nil, Want = "restart", Restarts = 0, Size = label.TextSize, Conns = {} }
	entries[label] = e
	table.insert(e.Conns, label:GetPropertyChangedSignal("Text"):Connect(function()
		want(label, "check")
	end))
	table.insert(e.Conns, label:GetPropertyChangedSignal("TextSize"):Connect(function()
		if label.TextSize ~= e.Size then
			want(label, "restart")
		end
	end))
	for _, prop in ipairs({ "TextScaled", "TextWrapped", "FontFace" }) do
		table.insert(e.Conns, label:GetPropertyChangedSignal(prop):Connect(function()
			want(label, "restart")
		end))
	end
	table.insert(e.Conns, label:GetAttributeChangedSignal("NoTextFit"):Connect(function()
		want(label, "restart")
	end))
	table.insert(e.Conns, label.ChildAdded:Connect(function(c)
		if c:IsA("UITextSizeConstraint") and c.Name ~= NAME then
			want(label, "restart")
		end
	end))
	table.insert(e.Conns, label.AncestryChanged:Connect(function(_, parent)
		if parent == nil then
			release(label)
		end
	end))
	pending[label] = true
end

-- A settled label whose box changed: less room may need a smaller cap, more room may let
-- it grow again. The same shape only scaled is a press / pop / breathing UIScale animation
-- (AbsoluteSize changes every frame, the room for the text does not): ignored.
local function sizeChanged(label: Instance, e: Entry, now: Vector2)
	local fit = e.Fit
	if not fit or e.Want then
		return
	end
	if math.abs(now.X - fit.X) <= 1 and math.abs(now.Y - fit.Y) <= 1 then
		return
	end
	if fit.X > 0 and fit.Y > 0 and math.abs(now.X / fit.X - now.Y / fit.Y) < 0.02 then
		return
	end
	if now.X <= fit.X + 1 and now.Y <= fit.Y + 1 then
		want(label, "check")
	else
		want(label, "restart")
	end
end

-- Settled labels are re-measured a slice at a time (no per-label AbsoluteSize listeners:
-- thousands of them cost more than a slow round-robin).
local SWEEP_EVERY = 0.25
local SWEEP_SLICE = 250
local sweepList: { Instance } = {}
local sweepAt = 1
local sweepClock = 0

local function sweep()
	if sweepAt > #sweepList then
		table.clear(sweepList)
		for label in pairs(entries) do
			table.insert(sweepList, label)
		end
		sweepAt = 1
	end
	local last = math.min(#sweepList, sweepAt + SWEEP_SLICE - 1)
	for i = sweepAt, last do
		local label = sweepList[i]
		local e = entries[label]
		if e and e.Fit and not e.Want and label.Parent then
			sizeChanged(label, e, (label :: any).AbsoluteSize)
		end
	end
	sweepAt = last + 1
end

-- One pass per frame: first read every label (one layout), then write the new caps.
local function step(dt: number)
	sweepClock += dt
	if sweepClock >= SWEEP_EVERY then
		sweepClock = 0
		sweep()
	end
	local reads = {}
	local n = 0
	for label in pairs(pending) do
		n += 1
		if n > PER_FRAME then
			break
		end
		local e = entries[label]
		if not e or not label.Parent then
			pending[label] = nil
			continue
		end
		local abs = (label :: any).AbsoluteSize
		table.insert(reads, { label, e, abs, (label :: any).TextFits })
	end
	for _, r in ipairs(reads) do
		local label, e, abs, fits = r[1], r[2], r[3], r[4]
		pending[label] = nil
		if e.Want == "restart" then
			e.Want = "check"
			e.Restarts += 1
			e.Size = (label :: any).TextSize
			if not eligible(label) then
				e.Want = nil
				local own = ownConstraint(label)
				if (label :: any).TextScaled or foreignConstraint(label) then
					if own then
						own:Destroy()
					end
				else
					e.Level = 3 -- NoTextFit: the designed size
					apply(label, e)
				end
			else
				e.Level = e.Restarts > MAX_RESTARTS and 3 or 1
				e.Fit = nil
				apply(label, e)
				pending[label] = true -- look again next frame
			end
		elseif e.Want == "check" then
			if abs.X < 1 or abs.Y < 1 then
				e.Want = nil -- not laid out (hidden or empty): a size change brings it back
				e.Fit = nil
			elseif fits or e.Level >= 3 then
				e.Want = nil
				e.Fit = abs
			else
				e.Level += 1
				apply(label, e)
				pending[label] = true
			end
		end
	end
end

local function scan(root: Instance)
	for _, d in ipairs(root:GetDescendants()) do
		if isText(d) then
			watch(d)
		end
	end
end

local function setActive(on: boolean)
	if on == active then
		return
	end
	active = on
	if on then
		for _, root in ipairs(roots) do
			scan(root)
		end
		stepConn = RunService.Heartbeat:Connect(step)
	else
		if stepConn then
			stepConn:Disconnect()
			stepConn = nil
		end
		local list = {}
		for label in pairs(entries) do
			table.insert(list, label)
		end
		for _, label in ipairs(list) do
			release(label)
		end
	end
end

-- Watches every text object under `root` (now and later).
function TextFit.Watch(root: Instance)
	table.insert(roots, root)
	root.DescendantAdded:Connect(function(d)
		if active and isText(d) then
			watch(d)
		end
	end)
	if active then
		scan(root)
	end
end

-- Starts following the player's Text size setting (call once).
function TextFit.Start()
	pcall(function()
		GuiService:GetPropertyChangedSignal("PreferredTextSize"):Connect(function()
			setActive(TextFit.Enlarged())
		end)
	end)
	setActive(TextFit.Enlarged())
end

-- How many labels are managed / still settling (regression scenes).
function TextFit.Stats(): { Watched: number, Pending: number }
	local n, p = 0, 0
	for _ in pairs(entries) do
		n += 1
	end
	for _ in pairs(pending) do
		p += 1
	end
	return { Watched = n, Pending = p }
end

return TextFit
