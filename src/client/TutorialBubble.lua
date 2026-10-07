--[[
	TutorialBubble.lua
	The SmartTutorial's look (Config.Features.SmartTutorial; Tutorial.lua decides what and
	when, docs/next/SMART_TUTORIAL.md): one small speech-bubble card near the bottom centre,
	just above the ability tray, with an icon and one short line. When the tip is about a
	thing (the weapon row, a gem, a chest, the PORTAL arrow, the boss bar) a tail on the
	bubble's edge and a gold pointer from it aim at that thing and follow it while it moves.

	Nothing here is Active: a thumb landing on the bubble still moves the hero. Tutorial.lua
	hides the bubble while a panel covers the screen (UIState) and fades it when the tip's
	action is done or its time is up.

	Show(text, icon, target?)  target() returns the point to aim at in root (virtual) pixels,
	                           or nil (no pointer); it is asked again every Step
	Hide()                     pops the bubble out
	SetCovered(on)             hidden behind a panel (keeps the tip); the quick-ping wheel
	                           (PingWheel) hides it too
	Step(dt)                   per frame: placement and the pointer
]]

local TextService = game:GetService("TextService")

local Shared = game:GetService("ReplicatedStorage"):WaitForChild("Shared")
local Theme = require(Shared:WaitForChild("Theme"))
local UIKit = require(script.Parent.UIKit)
local UIAnim = require(script.Parent.UIAnim)
local Icons = require(script.Parent.Icons)
local Hud = require(script.Parent.Hud)
local ClientSettings = require(script.Parent.ClientSettings)
local PingWheel = require(script.Parent.PingWheel)
local LootUI = require(script.Parent.LootUI)
local MiniMap = require(script.Parent.MiniMap)

local TutorialBubble = {}

local new, TS = UIKit.new, UIKit.TS
local C, P = Theme.Color, Theme.Palette

local BODY_SIZE = Theme.Type.Body.Size
local ICON = 34
local PAD = 12
local TAIL = 16
local MAX_W = 440
local POINTER_MAX = 90 -- longest pointer line (virtual px)

local kit: { [string]: any } = {}
local ui: { [string]: any } = {}
local rootFrame: Frame? = nil
local showing = false
local covered = false
local target: (() -> Vector2?)? = nil
local clock = 0

local function build(root: Frame)
	rootFrame = root
	local holder, face = UIKit.Surface(root, {
		Name = "TipBubble",
		Radius = Theme.Radius.L,
		Transparency = 0.04,
		Edge = P.gold_400,
		EdgeThickness = 2,
		EdgeTransparency = 0.1,
		Visible = false,
		ZIndex = Theme.Z.Toast,
		AnchorPoint = Vector2.new(0.5, 1),
		Size = UDim2.fromOffset(360, 56),
	})
	holder.Active = false
	ui.Card = holder
	ui.Face = face
	-- the speech-bubble tail: a diamond behind the face, half of it out toward the target
	local tail = new("Frame", { Name = "Tail", AnchorPoint = Vector2.new(0.5, 0.5), Size = UDim2.fromOffset(TAIL, TAIL), Rotation = 45, BackgroundColor3 = C.Panel, BorderSizePixel = 0, ZIndex = 0, Visible = false }, holder)
	UIKit.stroke(tail, P.gold_400, 2, 0.1)
	ui.Tail = tail
	UIKit.padding(face, 8, PAD, 8, PAD)
	local well = new("Frame", { Name = "IconWell", BackgroundColor3 = C.PanelInset, BackgroundTransparency = 0.05, Size = UDim2.fromOffset(ICON, ICON), AnchorPoint = Vector2.new(0, 0.5), Position = UDim2.fromScale(0, 0.5) }, face)
	UIKit.corner(well, 999)
	UIKit.stroke(well, P.gold_400, 2, 0.15)
	ui.IconWell = well
	ui.Body = UIKit.Role(face, "Body", "", {
		Name = "Body",
		AnchorPoint = Vector2.new(0, 0.5),
		Position = UDim2.new(0, ICON + 10, 0.5, 0),
		Size = UDim2.new(1, -(ICON + 10), 1, 0),
		TextWrapped = true,
		TextXAlignment = Enum.TextXAlignment.Left,
		TextColor3 = C.Text,
	})
	-- the pointer: a gold line from the tail toward the target with a V head
	local pointer = new("Frame", { Name = "TipPointer", BackgroundTransparency = 1, Size = UDim2.fromScale(1, 1), Visible = false, Active = false, ZIndex = Theme.Z.Toast }, root)
	ui.Pointer = pointer
	local function bar(name: string): Frame
		local f = new("Frame", { Name = name, AnchorPoint = Vector2.new(0.5, 0.5), BackgroundColor3 = P.gold_300, BorderSizePixel = 0, Size = UDim2.fromOffset(10, 4) }, pointer)
		UIKit.corner(f, 999)
		UIKit.stroke(f, P.slate_950, 1, 0.4)
		return f
	end
	ui.Line = bar("Line")
	ui.HeadA = bar("HeadA")
	ui.HeadB = bar("HeadB")
end

local function setIcon(name: string)
	for _, c in ipairs(ui.IconWell:GetChildren()) do
		if c:IsA("Frame") then
			c:Destroy()
		end
	end
	Icons.Draw(ui.IconWell, name, { Size = 22, AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.5), Back = P.slate_900 })
end

-- Wrapped line count of the text at width w (1-3), measured like Roblox lays it out.
local function lines(text: string, w: number): number
	local ok, size = pcall(function()
		return TextService:GetTextSize(text, TS(BODY_SIZE), Enum.Font.SourceSansSemibold, Vector2.new(w, 1000))
	end)
	if ok and typeof(size) == "Vector2" then
		return math.clamp(math.ceil(size.Y / TS(BODY_SIZE) - 0.2), 1, 3)
	end
	return 2
end

local function textWidth(text: string): number
	local ok, size = pcall(function()
		return TextService:GetTextSize(text, TS(BODY_SIZE), Enum.Font.SourceSansSemibold, Vector2.new(4000, 1000))
	end)
	if ok and typeof(size) == "Vector2" then
		return size.X
	end
	return 300
end

-- Root-pixel rect (x, y, w, h) of a shown GuiObject, or nil.
local function rectOf(g: Instance?): { number }?
	local root = rootFrame
	if not root or not g or not g:IsA("GuiObject") or not g.Visible or g.AbsoluteSize.X < 1 then
		return nil
	end
	local anc: Instance? = g.Parent
	while anc and anc:IsA("GuiObject") do
		if not anc.Visible then
			return nil
		end
		anc = anc.Parent
	end
	local v: Vector2 = kit.VirtualSize()
	local k = v.X / math.max(1, root.AbsoluteSize.X)
	local p = (g.AbsolutePosition - root.AbsolutePosition) * k
	local sz = g.AbsoluteSize * k
	return { p.X, p.Y, sz.X, sz.Y }
end

-- Portrait: the ability tray sits at the top under the HUD stack, so the bubble goes near
-- the bottom, above whatever lives there (JUMP / PING, the item strip, the loot prompt,
-- the minimap) and below the hero.
local function portraitBottom(W: number, H: number, w: number, h: number): number
	local obstacles: { { number } } = {}
	local function add(g: Instance?)
		local r = rectOf(g)
		if r then
			table.insert(obstacles, r)
		end
	end
	local pg = game:GetService("Players").LocalPlayer:FindFirstChildOfClass("PlayerGui")
	if pg then
		add(pg:FindFirstChild("JumpButton", true))
		local ping = pg:FindFirstChild("Ping", true)
		if ping and ping:IsA("GuiButton") then
			add(ping)
		end
	end
	local loot = LootUI.Elements()
	add(loot.Strip)
	add(loot.Prompt)
	add(MiniMap.Elements().Holder)
	local l, r = W / 2 - w / 2, W / 2 + w / 2
	local bottom = H - 16
	for _ = 1, 6 do
		local moved = false
		for _, o in ipairs(obstacles) do
			if l < o[1] + o[3] and r > o[1] and bottom - h < o[2] + o[4] and bottom > o[2] then
				bottom = o[2] - 10
				moved = true
			end
		end
		if not moved then
			break
		end
	end
	-- never up into the hero (screen centre) or the top HUD
	return math.max(bottom, math.min(H - 16, H / 2 + 90 + h), Hud.TopBottom() + 8 + h)
end

-- Places the bubble: bottom centre, just above the ability tray (landscape), or near the
-- bottom clear of the touch controls (portrait). Returns its rect.
local function place(): (number, number, number, number)
	local v: Vector2 = kit.VirtualSize()
	local W, H = v.X, v.Y
	local text = ui.Body.Text
	local inner = ICON + 10
	-- room for a bigger Roblox "Text size" (TextFit grows labels up to ~1.25x where they fit)
	local w = math.clamp(textWidth(text) * 1.3 + inner + 2 * PAD + 8, 220, math.min(MAX_W, W - 32))
	local n = lines(text, (w - inner - 2 * PAD) / 1.25)
	local h = math.max(ICON + 16, n * (TS(BODY_SIZE) + 4) * 1.25 + 16)
	local bottom: number
	if kit.IsPortrait and kit.IsPortrait() then
		bottom = portraitBottom(W, H, w, h)
	else
		bottom = math.min(H - 8, Hud.BarTop() - 14 - TAIL / 2)
		bottom = math.max(bottom, math.min(H - 8, Hud.TopBottom() + 8 + h))
	end
	ui.Card.Size = UDim2.fromOffset(math.floor(w), math.floor(h))
	ui.Card.Position = UDim2.fromOffset(math.floor(W / 2), math.floor(bottom))
	return W / 2 - w / 2, bottom - h, w, h
end

local function placePointer(x: number, y: number, w: number, h: number)
	local t = target and target() or nil
	if not t then
		ui.Tail.Visible = false
		ui.Pointer.Visible = false
		return
	end
	local cx = x + w / 2
	-- the tail sits on the edge facing the target
	local ex, ey
	if t.Y < y then
		ex, ey = math.clamp(t.X, x + 22, x + w - 22), y
	elseif t.Y > y + h then
		ex, ey = math.clamp(t.X, x + 22, x + w - 22), y + h
	else
		ex, ey = (t.X < cx) and x or (x + w), math.clamp(t.Y, y + 12, y + h - 12)
	end
	ui.Tail.Position = UDim2.fromOffset(ex - x, ey - y)
	ui.Tail.Visible = true
	local d = t - Vector2.new(ex, ey)
	local dist = d.Magnitude
	local len = math.min(POINTER_MAX, dist - 18)
	if len < 14 then
		ui.Pointer.Visible = false
		return
	end
	local dir = d / dist
	-- a small nudge toward the target (none with Reduced effects)
	local bob = ClientSettings.Reduced() and 0 or (math.sin(clock * 6) * 4 + 4)
	local a = Vector2.new(ex, ey) + dir * (TAIL / 2 + 2 + bob)
	local b = a + dir * len
	local ang = math.atan2(dir.Y, dir.X)
	ui.Line.Size = UDim2.fromOffset(len, 4)
	ui.Line.Position = UDim2.fromOffset((a.X + b.X) / 2, (a.Y + b.Y) / 2)
	ui.Line.Rotation = math.deg(ang)
	for i, head in ipairs({ ui.HeadA, ui.HeadB }) do
		local ha = ang + math.rad(i == 1 and 145 or -145)
		local hd = Vector2.new(math.cos(ha), math.sin(ha))
		head.Size = UDim2.fromOffset(14, 4)
		head.Position = UDim2.fromOffset(b.X + hd.X * 6, b.Y + hd.Y * 6)
		head.Rotation = math.deg(ha)
	end
	ui.Pointer.Visible = true
end

-- Hidden: a panel covers the screen (the caller says) or the quick-ping wheel is open.
local function hiddenNow(): boolean
	return covered or PingWheel.IsOpen()
end

local function layout()
	if not showing or not ui.Card or hiddenNow() then
		return
	end
	local x, y, w, h = place()
	placePointer(x, y, w, h)
end

------------------------------------------------------------------------------------------
-- Public
------------------------------------------------------------------------------------------

function TutorialBubble.Show(text: string, icon: string, aim: (() -> Vector2?)?)
	if not ui.Card then
		return
	end
	target = aim
	showing = true
	ui.Body.Text = text
	setIcon(icon)
	local hidden = hiddenNow()
	if not hidden then
		layout()
	end
	ui.Card.Visible = not hidden
	ui.Pointer.Visible = ui.Pointer.Visible and not hidden
	UIAnim.Pop(ui.Card, 0, 0.85)
end

function TutorialBubble.SetText(text: string)
	if ui.Body then
		ui.Body.Text = text
		layout()
	end
end

function TutorialBubble.Hide()
	if not showing then
		return
	end
	showing = false
	target = nil
	ui.Pointer.Visible = false
	ui.Tail.Visible = false
	local card = ui.Card :: Frame
	UIAnim.PopOut(card, function()
		if not showing then
			card.Visible = false
		end
	end)
end

-- Hidden behind a panel (level-up, pause, results ...): the tip waits.
function TutorialBubble.SetCovered(on: boolean)
	covered = on
	if not ui.Card then
		return
	end
	if hiddenNow() then
		ui.Card.Visible = false
		ui.Pointer.Visible = false
	elseif showing and not ui.Card.Visible then
		ui.Card.Visible = true
		layout()
	end
end

function TutorialBubble.Showing(): boolean
	return showing and not hiddenNow()
end

function TutorialBubble.Step(dt: number)
	clock += dt
	if not ui.Card then
		return
	end
	if showing and hiddenNow() then
		ui.Card.Visible = false
		ui.Pointer.Visible = false
	elseif showing then
		ui.Card.Visible = true
		layout()
	end
end

-- Root (virtual) pixels per screen pixel, and the root's screen origin.
function TutorialBubble.ToRoot(screen: Vector2): Vector2?
	local root = rootFrame
	if not root or root.AbsoluteSize.X < 1 then
		return nil
	end
	local v: Vector2 = kit.VirtualSize()
	local scale = v.X > 0 and root.AbsoluteSize.X / v.X or 1
	return (screen - root.AbsolutePosition) / scale
end

function TutorialBubble.Build(root: Frame, k: { [string]: any })
	kit = k
	build(root)
	if kit.OnRelayout then
		kit.OnRelayout(layout)
	end
end

-- For the preview tool / tests.
function TutorialBubble.Elements(): { [string]: any }
	return ui
end

return TutorialBubble
