--[[
	WorldLabelFade.lua
	World labels (ExploreUI's billboards over the merchant, cracked wall and villager;
	LootUI's altar and caravan pills) fade out instead of popping when they would sit on the
	HUD: the top-centre stack (timer, objective, boss bar), the vitals, the ability panel,
	the minimap, the centre banner while it shows, the notice pills, the reserved centre
	bars, or a panel registered with Avoid (the merchant's shop). They fade back in once
	clear.

	Rects are in AbsolutePosition space (the space WorldToScreenPoint answers in), so a
	billboard's projected box and a GUI element compare directly.
]]

local Hud = require(script.Parent.Hud)

local WorldLabelFade = {}

type Box = { number } -- { left, top, right, bottom }

local avoid: { GuiObject } = {}
local FADE_SECONDS = 0.18

-- A panel world labels must keep off while it is visible (and its ScreenGui enabled).
function WorldLabelFade.Avoid(g: GuiObject)
	table.insert(avoid, g)
end

local function add(out: { Box }, g: any)
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

-- Every HUD rect a world label must not cover right now.
function WorldLabelFade.Rects(): { Box }
	local out: { Box } = {}
	local els = Hud.Elements()
	local frame = els.Frame
	if typeof(frame) == "Instance" and frame:IsA("GuiObject") and frame.Visible then
		for _, key in ipairs({ "TimerPill", "Stage", "Plate", "Boss", "Bar", "Banner", "Build" }) do
			add(out, els[key])
		end
		for _, g in ipairs(Hud.CentreBars()) do
			add(out, g)
		end
		-- the notice pills: UIBuilder's toast list beside the HUD frame
		local root = frame.Parent
		local toasts = root and root:FindFirstChild("Toasts")
		if toasts then
			for _, c in ipairs(toasts:GetChildren()) do
				add(out, c)
			end
		end
	end
	-- the minimap (registered for portrait, but a panel to keep off everywhere)
	for _, g in ipairs(Hud.PortraitBars()) do
		add(out, g)
	end
	for _, g in ipairs(avoid) do
		add(out, g)
	end
	return out
end

-- Whether the box (l, t, r, b) touches any rect (4 px margin).
function WorldLabelFade.Hits(l: number, t: number, r: number, b: number, rects: { Box }?): boolean
	for _, rc in ipairs(rects or WorldLabelFade.Rects()) do
		if rc[3] > l - 4 and rc[1] < r + 4 and rc[4] > t - 4 and rc[2] < b + 4 then
			return true
		end
	end
	return false
end

-- One fade step: `alpha` 0 = fully shown, 1 = gone; moves toward `hidden` over ~0.18 s.
function WorldLabelFade.Step(alpha: number, hidden: boolean, dt: number): number
	local goal = hidden and 1 or 0
	local stepSize = math.max(dt, 1 / 60) / FADE_SECONDS
	if alpha < goal then
		return math.min(goal, alpha + stepSize)
	end
	return math.max(goal, alpha - stepSize)
end

return WorldLabelFade
