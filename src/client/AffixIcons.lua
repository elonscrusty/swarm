--[[
	AffixIcons.lua (Config.Features.AffixIcons; docs/next/AFFIX_ICONS.md)
	A small badge over every elite that shows its affix, client only:

	  Swift     blue circle with three speed lines
	  Shielded  silver shield
	  Burning   orange flame

	The shape differs per affix as well as the colour (colour-blind players), and colours go
	through Accessibility.Color. The badge is Config.AffixIcons.Size px (20, within 18-22) and
	one icon wide: far narrower than any enemy health bar (64 px), so it never sticks out.
	It hangs a little above the elite's name tag (EnemyRenderer's AffixTag), and goes when the
	elite dies: a dead or pooled body is parked below the arena (ACTIVE_Y), loses its Elite
	attribute or its Affix, or leaves the folder.

	Data: the replicated enemy bodies in workspace.SwarmEnemies, their attributes "Elite"
	(true) and "Affix" ("Swift" | "Shielded" | "Burning", set by EnemySpawner; no new remote
	and no new attribute). The first-sight notice is the server's (AffixSight.lua).

	The badge pulses softly; Reduced effects keeps the badge and drops the pulse. Scanned
	UpdateHz times a second, so a death removes the badge within an eighth of a second.
	Nothing runs while the switch is off.
]]

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")

local Shared = game:GetService("ReplicatedStorage"):WaitForChild("Shared")
local Config = require(Shared:WaitForChild("Config"))
local Theme = require(Shared:WaitForChild("Theme"))
local AffixIconData = require(Shared:WaitForChild("AffixIconData"))
local UIKit = require(script.Parent.UIKit)
local ClientSettings = require(script.Parent.ClientSettings)
local Accessibility = require(script.Parent.Accessibility)

local AffixIcons = {}

local P = Theme.Palette
local player = Players.LocalPlayer
local ACTIVE_Y = -100 -- below this an enemy body is parked in the server pool
local DESIGN = 20 -- the glyphs below are drawn on a 20 x 20 grid and scaled to cfg().Size

type Badge = {
	Gui: BillboardGui,
	Scale: UIScale,
	Affix: string,
	Shape: string,
	Pulse: Tween?,
	Body: BasePart,
}

local badges: { [BasePart]: Badge } = {}
local lastScan = 0
local started = false

-- The enemy pool's "Body" parts (a fixed pool the server never destroys), kept up to date by
-- ChildAdded / ChildRemoved instead of GetChildren + FindFirstChild("Body") on ~300 models
-- per scan. Shared with DangerArrows and MiniMap: treat the list as read only.
local enemyBodies: { BasePart } = {}
local bodyOf: { [Instance]: BasePart } = {}
local bodyIndex: { [BasePart]: number } = {}
local bodyFolder: Instance? = nil
local bodyConns: { RBXScriptConnection } = {}

local function addBody(model: Instance, body: Instance?)
	if bodyOf[model] or not body or not body:IsA("BasePart") or bodyFolder == nil or model.Parent ~= bodyFolder then
		return
	end
	bodyOf[model] = body
	table.insert(enemyBodies, body)
	bodyIndex[body] = #enemyBodies
end

local function removeBody(model: Instance)
	local body = bodyOf[model]
	if not body then
		return
	end
	bodyOf[model] = nil
	local i = bodyIndex[body]
	bodyIndex[body] = nil
	local last = #enemyBodies
	if i and i <= last then
		local moved = enemyBodies[last]
		enemyBodies[i] = moved
		enemyBodies[last] = nil
		if moved ~= body then
			bodyIndex[moved] = i
		end
	end
end

local function watchEnemy(model: Instance)
	local body = model:FindFirstChild("Body")
	if body then
		addBody(model, body)
		return
	end
	task.spawn(function()
		addBody(model, model:WaitForChild("Body", 10)) -- a model whose parts arrive late
	end)
end

function AffixIcons.EnemyBodies(): { BasePart }
	local folder = workspace:FindFirstChild("SwarmEnemies")
	if folder ~= bodyFolder then
		for _, c in ipairs(bodyConns) do
			c:Disconnect()
		end
		table.clear(bodyConns)
		table.clear(enemyBodies)
		table.clear(bodyOf)
		table.clear(bodyIndex)
		bodyFolder = folder
		if folder then
			table.insert(bodyConns, folder.ChildAdded:Connect(watchEnemy))
			table.insert(bodyConns, folder.ChildRemoved:Connect(removeBody))
			for _, m in ipairs(folder:GetChildren()) do
				watchEnemy(m)
			end
		end
	end
	return enemyBodies
end

local function cfg(): { [string]: any }
	return (Config :: any).AffixIcons or {}
end

local function on(): boolean
	return Config.FeatureOn("AffixIcons")
end

------------------------------------------------------------------------------------------
-- Glyphs (plain frames: no pictures to upload, they scale and recolour freely)
------------------------------------------------------------------------------------------

local function px(k: number, v: number): number
	return math.floor(v * k + 0.5)
end

-- A filled piece on the 20 x 20 grid (centre x, centre y, width, height).
local function piece(parent: Instance, k: number, color: Color3, cx: number, cy: number, w: number, h: number, round: boolean?, rotation: number?): Frame
	local f = UIKit.new("Frame", {
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromOffset(px(k, cx), px(k, cy)),
		Size = UDim2.fromOffset(px(k, w), px(k, h)),
		BackgroundColor3 = color,
		BorderSizePixel = 0,
		Rotation = rotation or 0,
	}, parent) :: Frame
	if round then
		UIKit.corner(f, 999)
	end
	return f
end

-- Swift: a round badge with three speed lines.
local function drawLines(root: Frame, k: number, col: Color3)
	local dark = P.slate_950
	piece(root, k, dark, 10, 10, 20, 20, true)
	piece(root, k, col, 10, 10, 17, 17, true)
	piece(root, k, dark, 9, 6.5, 11, 2.2) -- three bars, the middle one longest
	piece(root, k, dark, 11, 10, 13, 2.2)
	piece(root, k, dark, 9, 13.5, 9, 2.2)
end

-- Shielded: a shield (a plate with a point under it).
local function drawShield(root: Frame, k: number, col: Color3)
	local dark = P.slate_950
	piece(root, k, dark, 10, 7.2, 18, 13.5) -- outline layer first
	piece(root, k, dark, 10, 11.8, 12.4, 12.4, false, 45)
	piece(root, k, col, 10, 7.2, 15.4, 11)
	piece(root, k, col, 10, 11.8, 9.6, 9.6, false, 45)
	piece(root, k, P.slate_700, 10, 8.4, 2.4, 9) -- a centre rib
end

-- Burning: a flame (a ball with a point on top) and a bright core.
local function drawFlame(root: Frame, k: number, col: Color3)
	local dark = P.slate_950
	piece(root, k, dark, 10, 13, 18, 18, true)
	piece(root, k, dark, 10, 6.2, 11.5, 11.5, false, 45)
	piece(root, k, col, 10, 13, 15.4, 15.4, true)
	piece(root, k, col, 10, 6.6, 8.6, 8.6, false, 45)
	piece(root, k, P.gold_300, 10, 14.5, 7, 7, true)
end

local DRAW: { [string]: (Frame, number, Color3) -> () } = {
	Lines = drawLines,
	Shield = drawShield,
	Flame = drawFlame,
}

------------------------------------------------------------------------------------------
-- Badges
------------------------------------------------------------------------------------------

local function destroy(b: Badge)
	if b.Pulse then
		b.Pulse:Cancel()
		b.Pulse = nil
	end
	b.Gui:Destroy()
end

local function build(body: BasePart, affix: string): Badge?
	local entry = AffixIconData.Get(affix)
	local draw = entry and DRAW[entry.Shape]
	if not entry or not draw then
		return nil
	end
	local size = math.clamp(math.floor(tonumber(cfg().Size) or DESIGN), 18, 22)
	local k = size / DESIGN
	local gui = UIKit.new("BillboardGui", {
		Name = "AffixBadge",
		Size = UDim2.fromOffset(size + 6, size + 6), -- a little room for the pulse
		LightInfluence = 0,
		MaxDistance = tonumber(cfg().MaxDistance) or 200,
		AlwaysOnTop = false,
		ResetOnSpawn = false,
	}) :: BillboardGui
	local holder = UIKit.new("Frame", {
		Name = "Holder",
		BackgroundTransparency = 1,
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.5),
		Size = UDim2.fromOffset(size, size),
	}, gui) :: Frame
	local scale = UIKit.new("UIScale", { Scale = 1 }, holder) :: UIScale
	draw(holder, k, Accessibility.Color(entry.Color, entry.Role))
	holder:SetAttribute("AffixShape", entry.Shape)
	holder:SetAttribute("AffixId", entry.Id)
	gui:SetAttribute("Affix", entry.Id)
	gui:SetAttribute("Shape", entry.Shape)
	gui:SetAttribute("BadgeSize", size)
	gui.Adornee = body
	gui.StudsOffsetWorldSpace = Vector3.new(0, body.Size.Y / 2 + (tonumber(cfg().Lift) or 6.2), 0)
	local pg = player and player:FindFirstChildOfClass("PlayerGui")
	gui.Parent = pg or workspace
	return { Gui = gui, Scale = scale, Affix = affix, Shape = entry.Shape, Pulse = nil, Body = body }
end

-- Pulse on, or off (and back to full size) with Reduced effects.
local function setPulse(b: Badge)
	if ClientSettings.Reduced() then
		if b.Pulse then
			b.Pulse:Cancel()
			b.Pulse = nil
		end
		b.Scale.Scale = 1
	elseif not b.Pulse then
		local tw = TweenService:Create(b.Scale, TweenInfo.new(tonumber(cfg().PulseSeconds) or 0.6, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut, -1, true), { Scale = tonumber(cfg().PulseScale) or 1.12 })
		tw:Play()
		b.Pulse = tw
	end
end

-- The affix an elite body wears, or nil (not an elite, parked, dead, junk attribute).
local function affixOf(body: BasePart): string?
	if body.Position.Y < ACTIVE_Y or body:GetAttribute("Elite") ~= true then
		return nil
	end
	local a = body:GetAttribute("Affix")
	if AffixIconData.Get(a) then
		return a :: string
	end
	return nil
end

local seen: { [BasePart]: boolean } = {}

local function update()
	table.clear(seen)
	for _, body in ipairs(AffixIcons.EnemyBodies()) do
		local affix = affixOf(body)
		if affix then
			seen[body] = true
			local b = badges[body]
			if b and b.Affix ~= affix then
				destroy(b)
				badges[body] = nil
				b = nil
			end
			if not b then
				b = build(body, affix)
				badges[body] = b
			end
			if b then
				b.Gui.StudsOffsetWorldSpace = Vector3.new(0, body.Size.Y / 2 + (tonumber(cfg().Lift) or 6.2), 0)
				setPulse(b)
			end
		end
	end
	for body, b in pairs(badges) do
		if not seen[body] then
			destroy(b)
			badges[body] = nil
		end
	end
end

local function clearAll()
	for body, b in pairs(badges) do
		destroy(b)
		badges[body] = nil
	end
end

------------------------------------------------------------------------------------------
-- Public
------------------------------------------------------------------------------------------

-- The badges now shown (regression scenes): { Affix, Shape, Size, Pulse, Gui }.
function AffixIcons.Debug(): { { [string]: any } }
	local out = {}
	for _, b in pairs(badges) do
		table.insert(out, {
			Affix = b.Affix,
			Shape = b.Shape,
			Size = b.Gui:GetAttribute("BadgeSize"),
			Width = b.Gui.Size.X.Offset,
			Pulse = b.Pulse ~= nil,
			Gui = b.Gui,
			Body = b.Body,
		})
	end
	return out
end

-- Scan now (regression scenes; the game scans UpdateHz times a second).
function AffixIcons.Refresh()
	if on() then
		update()
	else
		clearAll()
	end
end

function AffixIcons.Init()
	if started then
		return
	end
	started = true
	RunService.Heartbeat:Connect(function()
		local now = os.clock()
		if now - lastScan < 1 / math.max(1, tonumber(cfg().UpdateHz) or 8) then
			return
		end
		lastScan = now
		AffixIcons.Refresh()
	end)
end

return AffixIcons
