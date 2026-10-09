--!strict
--[[
	SwarmV2/Run/RunLayout.lua  (ReplicatedStorage.SwarmV2.Run.RunLayout)
	OWNER: stream F (run UI). Pure numbers, no Roblox types beyond plain tables, so a test can
	run it with any screen size.

	Turns the brief's HUD starting points (RunConfig.UI.Layout) into rectangles for one screen:

	  desktop   health + XP upper left, timer top centre (objective strip + boss bar under it),
	            gold / kills / menu and the minimap upper right, compact party indicators down the
	            left, the weapon + passive rows along the bottom
	  phone     safe-area-relative starting points: health 5% / 5%, timer 50% / 5%, map 82% / 17%,
	            party 4% / 25%, equipment above a bottom XP strip; the joystick (16% / 84%, 112 pt),
	            JUMP (86% / 74%, 64 pt) and DASH (82% / 87%, 64 pt) are kept clear of every piece
	  portrait  a stack under the top cluster (the thumbs own the bottom corners)

	Every rectangle is clamped to the safe bounds and kept off the Roblox top-bar buttons. The
	numbers are design px of the UI root (virtual px); touch sizes are device points, divided by
	the UI scale on the way in.

	Used by: Hud (placement), MiniMap, TeamUI, MobileControls (touch points), the run
	interact prompt and the cards (what to stay clear of), and the layout regression.
]]

local RunLayout = {}

export type Rect = { X: number, Y: number, W: number, H: number }
export type Insets = { Top: number, Left: number, Right: number }
export type Env = {
	W: number,
	H: number,
	Insets: Insets,
	Phone: boolean, -- compact (short side under 560 pt)
	Portrait: boolean,
	Touch: boolean, -- touch controls exist on this device
	Scale: number, -- UIScale: device points = virtual px * Scale
	Mirror: boolean?, -- left-handed touch layout
}
export type Size = { W: number, H: number }
export type Sizes = {
	Health: Size,
	Timer: Size,
	Objective: Size?,
	Boss: Size?,
	Counters: Size,
	Map: Size,
	Party: Size?,
	Equipment: Size,
	XpStrip: Size?,
}
export type Layout = { [string]: Rect }

local function rect(x: number, y: number, w: number, h: number): Rect
	return { X = x, Y = y, W = w, H = h }
end
RunLayout.Rect = rect

function RunLayout.Right(r: Rect): number
	return r.X + r.W
end

function RunLayout.Bottom(r: Rect): number
	return r.Y + r.H
end

-- Do two rectangles overlap (with `gap` of breathing room)?
function RunLayout.Overlaps(a: Rect, b: Rect, gap: number?): boolean
	local g = gap or 0
	return a.X < b.X + b.W + g and b.X < a.X + a.W + g and a.Y < b.Y + b.H + g and b.Y < a.Y + a.H + g
end

-- Keeps `r` inside the safe bounds (margin from every edge).
function RunLayout.Clamp(r: Rect, env: Env, margin: number): Rect
	local x = math.max(margin, math.min(r.X, env.W - margin - r.W))
	local y = math.max(margin, math.min(r.Y, env.H - margin - r.H))
	return rect(x, y, r.W, r.H)
end

-- The Roblox menu / chat buttons (left cluster) and the right cluster occupy the top-bar
-- band; anything that touches them drops below it.
function RunLayout.AvoidTopbar(r: Rect, env: Env): Rect
	local ins = env.Insets
	if r.Y < ins.Top and (r.X < ins.Left + 4 or r.X + r.W > env.W - ins.Right - 4) then
		return rect(r.X, ins.Top + 2, r.W, r.H)
	end
	return r
end

function RunLayout.Margin(env: Env, cfg: any): number
	return if env.Phone then cfg.MarginPhone else cfg.MarginDesktop
end

-- Moves `r` along the line away from `from` until the two rectangles no longer overlap.
local function pushAway(r: Rect, from: Rect, gap: number, env: Env, margin: number): Rect
	if not RunLayout.Overlaps(r, from, gap) then
		return r
	end
	-- candidates: left, right, above, below the obstacle; take the nearest that fits
	local options = {
		rect(from.X - gap - r.W, r.Y, r.W, r.H),
		rect(from.X + from.W + gap, r.Y, r.W, r.H),
		rect(r.X, from.Y - gap - r.H, r.W, r.H),
		rect(r.X, from.Y + from.H + gap, r.W, r.H),
	}
	local best, bestCost = r, math.huge
	for _, o in ipairs(options) do
		local c = RunLayout.Clamp(o, env, margin)
		if not RunLayout.Overlaps(c, from, gap - 0.5) then
			local cost = math.abs(c.X - r.X) + math.abs(c.Y - r.Y)
			if cost < bestCost then
				best, bestCost = c, cost
			end
		end
	end
	return best
end

-- A circle (centre cx, cy, diameter d) as the rectangle that bounds it.
local function circle(cx: number, cy: number, d: number): Rect
	return rect(cx - d / 2, cy - d / 2, d, d)
end

-- Touch controls: the resting joystick, JUMP and DASH, from the brief's fractions. Sizes are
-- device points (cfg.StickPx / JumpPx / DashPx) converted to virtual px; the three are
-- clamped to the safe bounds and JUMP / DASH are pushed apart when they would touch.
function RunLayout.Thumbs(env: Env, cfg: any): Layout
	local p = cfg.Phone
	local s = math.max(0.01, env.Scale)
	local margin = RunLayout.Margin(env, cfg)
	local function fx(f: number): number
		return (if env.Mirror then 1 - f else f) * env.W
	end
	local stickD = cfg.StickPx / s
	local jumpD = cfg.JumpPx / s
	local dashD = cfg.DashPx / s
	local stick = RunLayout.Clamp(circle(fx(p.Stick[1]), p.Stick[2] * env.H, stickD), env, margin)
	local jump = RunLayout.Clamp(circle(fx(p.Jump[1]), p.Jump[2] * env.H, jumpD), env, margin)
	local dash = RunLayout.Clamp(circle(fx(p.Dash[1]), p.Dash[2] * env.H, dashD), env, margin)
	-- JUMP and DASH are round: keep their centres a diameter plus the gap apart
	local jcx, jcy = jump.X + jump.W / 2, jump.Y + jump.H / 2
	local dcx, dcy = dash.X + dash.W / 2, dash.Y + dash.H / 2
	local need = (jumpD + dashD) / 2 + cfg.Gap
	local dx, dy = dcx - jcx, dcy - jcy
	local dist = math.sqrt(dx * dx + dy * dy)
	if dist < need then
		-- slide DASH away from JUMP along the line between them (down-left by default)
		local ux, uy = -0.6, 0.8
		if dist > 0.5 then
			ux, uy = dx / dist, dy / dist
		end
		dcx, dcy = jcx + ux * need, jcy + uy * need
		dash = RunLayout.Clamp(circle(dcx, dcy, dashD), env, margin)
		-- clamping may have pulled it back toward JUMP: then slide sideways instead
		dcx, dcy = dash.X + dash.W / 2, dash.Y + dash.H / 2
		local dx2, dy2 = dcx - jcx, dcy - jcy
		if math.sqrt(dx2 * dx2 + dy2 * dy2) < need - 0.5 then
			local side = if env.Mirror then 1 else -1
			local reach = math.sqrt(math.max(0, need * need - dy2 * dy2))
			dash = RunLayout.Clamp(circle(jcx + side * reach, dcy, dashD), env, margin)
		end
	end
	return { Stick = stick, Jump = jump, Dash = dash }
end

-- Where a touch thumb can be: the union rectangle of the three controls plus a gap.
local function thumbList(t: Layout?): { Rect }
	local out = {}
	if t then
		for _, k in ipairs({ "Stick", "Jump", "Dash" }) do
			if t[k] then
				table.insert(out, t[k])
			end
		end
	end
	return out
end

-- The room between the thumbs on the bottom row: x range a centred bottom piece may use.
function RunLayout.BottomBand(env: Env, thumbs: Layout?, gap: number, margin: number): (number, number)
	local lo, hi = margin, env.W - margin
	for _, t in ipairs(thumbList(thumbs)) do
		local cx = t.X + t.W / 2
		if cx < env.W / 2 then
			lo = math.max(lo, t.X + t.W + gap)
		else
			hi = math.min(hi, t.X - gap)
		end
	end
	return lo, hi
end

--[[
	Every rectangle of the run HUD for one screen. `sizes` are the measured design sizes of the
	pieces (so a bigger Roblox text size or a longer name makes room, not overlap).
	Returns { Health, Timer, Objective, Boss, Counters, Map, Party, Equipment, XpStrip?, Stick,
	Jump, Dash, TopBottom (a number in Layout.Extra), ... } as rectangles. Pieces that do not
	exist on a device (XpStrip off phones, thumbs without touch) are nil.
]]
function RunLayout.Compute(env: Env, sizes: Sizes, cfg: any): Layout
	local out: Layout = {}
	local W, H = env.W, env.H
	local margin = RunLayout.Margin(env, cfg)
	local gap = cfg.Gap
	local ins = env.Insets
	local thumbs = if env.Touch then RunLayout.Thumbs(env, cfg) else nil
	if thumbs then
		out.Stick, out.Jump, out.Dash = thumbs.Stick, thumbs.Jump, thumbs.Dash
	end
	local phoneLandscape = env.Phone and not env.Portrait
	local p = cfg.Phone

	-- counters (gold, kills, menu): the right end of the top band
	local cw, ch = sizes.Counters.W, sizes.Counters.H
	local cy = if ins.Right > 4 then ins.Top + 6 else 6
	out.Counters = RunLayout.Clamp(rect(W - margin - cw, cy, cw, ch), env, 2)

	-- health plate
	local hw, hh = sizes.Health.W, sizes.Health.H
	local hx, hy
	if phoneLandscape then
		hx, hy = p.Health[1] * W, p.Health[2] * H
	else
		hx, hy = margin, math.max(ins.Top, 0) + 6
	end
	local health = RunLayout.AvoidTopbar(rect(hx, hy, hw, hh), env)
	out.Health = RunLayout.Clamp(health, env, 2)

	-- timer: top centre
	local tw, th = sizes.Timer.W, sizes.Timer.H
	local ty = if phoneLandscape then p.Timer[2] * H else 6
	if ins.Left + 8 > W / 2 - tw / 2 or ins.Right + 8 > W / 2 - tw / 2 then
		ty = math.max(ty, ins.Top + 2)
	end
	local timer = rect(W / 2 - tw / 2, ty, tw, th)
	-- under the counters when they reach it (narrow screens)
	if RunLayout.Overlaps(timer, out.Counters, gap) then
		timer = rect(timer.X, RunLayout.Bottom(out.Counters) + 6, tw, th)
	end
	out.Timer = timer

	-- objective strip + boss bar stack under the timer; a piece that would touch the health
	-- plate or the counters (narrow screens, portrait) drops below them
	local function dropBelow(r: Rect): Rect
		local cur = r
		for _ = 1, 2 do
			for _, o in ipairs({ out.Health, out.Counters, out.Timer }) do
				if RunLayout.Overlaps(cur, o, gap) then
					cur = rect(cur.X, RunLayout.Bottom(o) + 6, cur.W, cur.H)
				end
			end
		end
		return cur
	end
	local y = RunLayout.Bottom(timer) + 6
	if sizes.Objective and sizes.Objective.H > 0 then
		local ow = math.min(sizes.Objective.W, W - 2 * margin)
		out.Objective = dropBelow(rect(W / 2 - ow / 2, y, ow, sizes.Objective.H))
		y = RunLayout.Bottom(out.Objective) + 6
	end
	if sizes.Boss and sizes.Boss.H > 0 then
		local bw = math.min(sizes.Boss.W, W - 2 * margin)
		out.Boss = dropBelow(rect(W / 2 - bw / 2, y, bw, sizes.Boss.H))
		y = RunLayout.Bottom(out.Boss) + 6
	end
	out.TopBottom = rect(0, y, 0, 0)

	-- XP strip (phone landscape): the bottom edge; equipment sits above it
	local eqW, eqH = sizes.Equipment.W, sizes.Equipment.H
	local bandLo, bandHi = margin, W - margin
	if thumbs then
		bandLo, bandHi = RunLayout.BottomBand(env, thumbs, gap, margin)
	end
	local bottom = H - margin
	if phoneLandscape and sizes.XpStrip then
		local sw = math.min(sizes.XpStrip.W, bandHi - bandLo)
		local cx = (bandLo + bandHi) / 2
		out.XpStrip = rect(cx - sw / 2, bottom - sizes.XpStrip.H, sw, sizes.XpStrip.H)
		bottom = out.XpStrip.Y - 4
	end

	-- equipment
	if env.Portrait then
		-- portrait: under the top cluster (the thumbs own the bottom corners)
		local ex = W / 2 - eqW / 2
		out.Equipment = RunLayout.Clamp(rect(ex, y + 2, eqW, eqH), env, margin)
	else
		local cx = (bandLo + bandHi) / 2
		out.Equipment = rect(cx - eqW / 2, bottom - eqH, eqW, eqH)
	end

	-- map
	local mw, mh = sizes.Map.W, sizes.Map.H
	local map
	if phoneLandscape then
		map = rect(p.Map[1] * W - mw / 2, p.Map[2] * H, mw, mh)
	elseif env.Portrait then
		map = rect(W - margin - mw, RunLayout.Bottom(out.Equipment) + 8, mw, mh)
	else
		map = rect(W - margin - mw, RunLayout.Bottom(out.Counters) + 10, mw, mh)
	end
	map = RunLayout.Clamp(map, env, 2)
	map = pushAway(map, out.Counters, gap, env, 2)
	for _, o in ipairs({ out.Objective, out.Boss }) do
		if o then
			map = pushAway(map, o, gap, env, 2)
		end
	end
	if thumbs then
		for _, t in ipairs(thumbList(thumbs)) do
			map = pushAway(map, t, gap, env, 2)
		end
	end
	out.Map = map

	-- party stack: down the left, under the health plate
	if sizes.Party then
		local pw, ph = sizes.Party.W, sizes.Party.H
		local party
		if phoneLandscape then
			party = rect(p.Party[1] * W, p.Party[2] * H, pw, ph)
		elseif env.Portrait then
			party = rect(margin, RunLayout.Bottom(out.Equipment) + 8, pw, ph)
		else
			party = rect(margin, RunLayout.Bottom(out.Health) + 14, pw, ph)
		end
		party = RunLayout.Clamp(party, env, 2)
		party = pushAway(party, out.Health, gap, env, 2)
		for _, o in ipairs({ out.Objective, out.Boss }) do
			if o then
				party = pushAway(party, o, gap, env, 2)
			end
		end
		if thumbs then
			for _, t in ipairs(thumbList(thumbs)) do
				party = pushAway(party, t, gap, env, 2)
			end
		end
		party = pushAway(party, out.Equipment, gap, env, 2)
		out.Party = party
	end

	out.LeftBottom = rect(0, RunLayout.Bottom(out.Health), 0, 0)
	return out
end

-- Overlaps among the named pieces: { "A vs B", ... } (empty when the layout is clean).
-- `allowed` names pairs that may touch, written "A|B". The touch controls are round: they
-- conflict when their discs touch, not their bounding squares.
local ROUND: { [string]: boolean } = { Stick = true, Jump = true, Dash = true }

function RunLayout.Conflicts(layout: Layout, names: { string }, gap: number?, allowed: { [string]: boolean }?): { string }
	local out = {}
	local g = gap or 0
	for i = 1, #names do
		for j = i + 1, #names do
			local a, b = layout[names[i]], layout[names[j]]
			if a and b and a.W > 0 and b.W > 0 then
				local hit
				if ROUND[names[i]] and ROUND[names[j]] then
					local dx, dy = (a.X + a.W / 2) - (b.X + b.W / 2), (a.Y + a.H / 2) - (b.Y + b.H / 2)
					hit = math.sqrt(dx * dx + dy * dy) < (a.W + b.W) / 2 + g - 0.5
				else
					hit = RunLayout.Overlaps(a, b, g)
				end
				if hit then
					local key = names[i] .. "|" .. names[j]
					local rev = names[j] .. "|" .. names[i]
					if not (allowed and (allowed[key] or allowed[rev])) then
						table.insert(out, names[i] .. " vs " .. names[j])
					end
				end
			end
		end
	end
	return out
end

-- Is `r` entirely inside the safe bounds?
function RunLayout.Inside(r: Rect, env: Env, margin: number?): boolean
	local m = (margin or 0) - 0.5
	return r.X >= m and r.Y >= m and r.X + r.W <= env.W - m and r.Y + r.H <= env.H - m
end

return RunLayout
