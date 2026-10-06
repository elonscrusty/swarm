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
type Entry = { Level: number, Fit: Vector2?, Conns: { RBXScriptConnection } }

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
local function capFor(label: any, level: number): number
	local size = label.TextSize
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

local function apply(label: any, level: number)
	local own = ownConstraint(label)
	if not own then
		own = Instance.new("UITextSizeConstraint")
		own.Name = NAME
		own.MinTextSize = 1
		own.Parent = label
	end
	local cap = capFor(label, level)
	if own.MaxTextSize ~= cap then
		own.MaxTextSize = cap
	end
end

-- Should this label be managed now? (TextScaled text ignores the setting; a label with its
-- own UITextSizeConstraint already has a bound; NoTextFit opts out at the designed size.)
local function eligible(label: any): boolean
	return not label.TextScaled and label:GetAttribute("NoTextFit") ~= true and not foreignConstraint(label)
end

local function restart(label: any)
	local e = entries[label]
	if not e then
		return
	end
	if not eligible(label) then
		if label:GetAttribute("NoTextFit") == true and not label.TextScaled and not foreignConstraint(label) then
			e.Level = 3
			apply(label, 3)
			pending[label] = nil
			return
		end
		local own = ownConstraint(label)
		if own then
			own:Destroy()
		end
		pending[label] = nil
		return
	end
	e.Level = 1
	e.Fit = nil
	apply(label, 1)
	pending[label] = true
end

local function watch(label: any)
	if entries[label] then
		return
	end
	local e: Entry = { Level = 1, Fit = nil, Conns = {} }
	entries[label] = e
	local function resized()
		local fit = e.Fit
		local now = label.AbsoluteSize
		if fit and now.X <= fit.X + 1 and now.Y <= fit.Y + 1 then
			pending[label] = true -- smaller or the same: may only need to shrink
		else
			restart(label)
		end
	end
	table.insert(e.Conns, label:GetPropertyChangedSignal("AbsoluteSize"):Connect(resized))
	table.insert(e.Conns, label:GetPropertyChangedSignal("Text"):Connect(function()
		pending[label] = true
	end))
	for _, prop in ipairs({ "TextSize", "TextScaled", "TextWrapped", "FontFace" }) do
		table.insert(e.Conns, label:GetPropertyChangedSignal(prop):Connect(function()
			restart(label)
		end))
	end
	table.insert(e.Conns, label:GetAttributeChangedSignal("NoTextFit"):Connect(function()
		restart(label)
	end))
	table.insert(e.Conns, label.ChildAdded:Connect(function(c)
		if c:IsA("UITextSizeConstraint") and c.Name ~= NAME then
			restart(label)
		end
	end))
	table.insert(e.Conns, label.AncestryChanged:Connect(function(_, parent)
		if parent == nil then
			release(label)
		end
	end))
	restart(label)
end

local function step()
	for label in pairs(pending) do
		local e = entries[label]
		if not e or not label.Parent then
			pending[label] = nil
			continue
		end
		local abs = (label :: any).AbsoluteSize
		if abs.X < 1 or abs.Y < 1 then
			continue -- not laid out yet: wait for a size
		end
		if (label :: any).TextFits or e.Level >= 3 then
			e.Fit = abs
			pending[label] = nil
		else
			e.Level += 1
			apply(label, e.Level)
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
