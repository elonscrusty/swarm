--!nocheck
--[[
	layout.luau - Roblox GUI layout (not CSS): computes AbsolutePosition / AbsoluteSize /
	AbsoluteRotation, TextBounds, AbsoluteContentSize ... for every GuiObject under a
	ScreenGui / BillboardGui / SurfaceGui, and keeps the results for the exporter.

	Rules implemented (see docs/PREVIEW.md for what is approximated):
	  * ScreenGui area: device safe area (DeviceSafeInsets / CoreUISafeInsets) and the 58 px
	    top bar unless IgnoreGuiInset; ScreenInsets None = whole screen.
	  * UDim2 Size / Position against the parent's content box; AnchorPoint; SizeConstraint.
	  * UIScale scales the object around its anchor point (and everything inside it);
	    layouts place children by their unscaled size (as Roblox does).
	  * UIPadding, UIListLayout (fill direction, padding, alignment, sort order, Wraps,
	    HorizontalFlex/VerticalFlex + UIFlexItem basics), UIGridLayout, UIPageLayout (shows
	    the first page), UIAspectRatioConstraint, UISizeConstraint, UITextSizeConstraint,
	    AutomaticSize, ScrollingFrame canvas (CanvasSize, AutomaticCanvasSize,
	    CanvasPosition), ClipsDescendants (not on rotated objects), Rotation (inherited).
]]

local roblox = require("@lune/roblox")
local R = require("./R")
local T = require("./text")
local S = require("./scheduler")

local states = R.states
local Vector2, UDim, UDim2 = roblox.Vector2, roblox.UDim, roblox.UDim2
local Enum = roblox.Enum

local L = {}

local function gp(st, key)
	local v = st.props[key]
	if v == nil then
		v = st.info.defaults[key]
	end
	return v
end

------------------------------------------------------------------------------------------
-- 2D affine helpers: { a, b, c, d, e, f } maps (x, y) → (a x + c y + e, b x + d y + f)
------------------------------------------------------------------------------------------

local IDENTITY = { 1, 0, 0, 1, 0, 0 }

local function mul(m, n)
	return {
		m[1] * n[1] + m[3] * n[2],
		m[2] * n[1] + m[4] * n[2],
		m[1] * n[3] + m[3] * n[4],
		m[2] * n[3] + m[4] * n[4],
		m[1] * n[5] + m[3] * n[6] + m[5],
		m[2] * n[5] + m[4] * n[6] + m[6],
	}
end

local function rotateAbout(cx, cy, degrees)
	local r = math.rad(degrees)
	local c, s = math.cos(r), math.sin(r)
	-- T(c) * Rot * T(-c)
	return { c, s, -s, c, cx - c * cx + s * cy, cy - s * cx - c * cy }
end
L.mul = mul

------------------------------------------------------------------------------------------
-- Children and components
------------------------------------------------------------------------------------------

local function classify(obj)
	local st = states[obj]
	local kids, comps = {}, {}
	for _, c in ipairs(st.children) do
		local cs = states[c]
		local info = cs.info
		if info.isA.GuiObject then
			table.insert(kids, c)
		elseif info.isA.UIComponent or info.isA.UIBase then
			local n = info.name
			if not comps[n] then
				comps[n] = c
			end
			if info.isA.UIGridStyleLayout and not comps.layout then
				comps.layout = c
			end
		elseif info.name == "Path2D" then
			table.insert(kids, c)
		end
	end
	return kids, comps
end
L.classify = classify

local function componentEnabled(c)
	if not c then
		return nil
	end
	local st = states[c]
	if st.info.props.Enabled and gp(st, "Enabled") == false then
		return nil
	end
	return c
end

local function ownScale(comps): number
	local sc = componentEnabled(comps.UIScale)
	if sc then
		return gp(states[sc], "Scale")
	end
	return 1
end

------------------------------------------------------------------------------------------
-- Text
------------------------------------------------------------------------------------------

local function isText(st)
	local n = st.info
	return n.isA.TextLabel or n.isA.TextButton or n.isA.TextBox
end

-- Lays out an object's text in a box of width w / height h (screen px) at scale k.
local function layoutText(st, comps, w, h, k, wrapWidth)
	local text = gp(st, "Text")
	if st.info.isA.TextBox and text == "" then
		text = gp(st, "PlaceholderText")
		st.x.placeholder = true
	else
		st.x.placeholder = false
	end
	local font = gp(st, "FontFace")
	local rich = gp(st, "RichText")
	local lh = gp(st, "LineHeight")
	local opts = { text = text, font = font, rich = rich, lineHeight = lh }
	local size
	if gp(st, "TextScaled") then
		local minS, maxS = 1, 100
		local tc = componentEnabled(comps.UITextSizeConstraint)
		if tc then
			minS = gp(states[tc], "MinTextSize")
			maxS = gp(states[tc], "MaxTextSize")
		end
		size = T.fitSize(opts, math.max(1, w), math.max(1, h), minS * k, maxS * k)
		opts.wrap = true
		opts.maxWidth = w
	else
		size = gp(st, "TextSize") * k
		opts.wrap = gp(st, "TextWrapped")
		opts.maxWidth = wrapWidth or w
	end
	opts.size = size
	local res = T.layout(opts)
	res.size = size
	return res
end

------------------------------------------------------------------------------------------
-- Sizes
------------------------------------------------------------------------------------------

local function paddingOf(comps, w, h, k)
	local p = componentEnabled(comps.UIPadding)
	if not p then
		return 0, 0, 0, 0
	end
	local st = states[p]
	local function u(name, base)
		local v = gp(st, name)
		return v.Scale * base + v.Offset * k
	end
	return u("PaddingLeft", w), u("PaddingRight", w), u("PaddingTop", h), u("PaddingBottom", h)
end
L.paddingOf = paddingOf

local function applyConstraints(comps, w, h, k, parentW, parentH)
	local sc = componentEnabled(comps.UISizeConstraint)
	if sc then
		local st = states[sc]
		local minS, maxS = gp(st, "MinSize"), gp(st, "MaxSize")
		w = math.clamp(w, minS.X * k, math.max(minS.X * k, maxS.X * k))
		h = math.clamp(h, minS.Y * k, math.max(minS.Y * k, maxS.Y * k))
	end
	local ar = componentEnabled(comps.UIAspectRatioConstraint)
	if ar then
		local st = states[ar]
		local ratio = gp(st, "AspectRatio")
		if ratio > 0 then
			local aspectType = gp(st, "AspectType")
			local axis = gp(st, "DominantAxis")
			if aspectType == Enum.AspectType.ScaleWithParentSize then
				if axis == Enum.DominantAxis.Width then
					h = w / ratio
				else
					w = h * ratio
				end
			else
				-- FitWithinMaxSize: the largest box with this ratio inside w x h
				if w / math.max(h, 1e-6) > ratio then
					w = h * ratio
				else
					h = w / ratio
				end
			end
		end
	end
	return w, h
end

-- Size (screen px, before the object's own UIScale) from the parent's content box.
local function baseSize(st, comps, box)
	local size = gp(st, "Size")
	local k = box.k
	local pw, ph = box.w, box.h
	local constraint = gp(st, "SizeConstraint")
	local sxBase, syBase = pw, ph
	if constraint == Enum.SizeConstraint.RelativeXX then
		syBase = pw
	elseif constraint == Enum.SizeConstraint.RelativeYY then
		sxBase = ph
	end
	local w = sxBase * size.X.Scale + size.X.Offset * k
	local h = syBase * size.Y.Scale + size.Y.Offset * k
	return w, h
end

------------------------------------------------------------------------------------------
-- Layout pass
------------------------------------------------------------------------------------------

local layoutObject -- forward

local function sortedForLayout(layoutSt, kids)
	local list = {}
	for i, c in ipairs(kids) do
		local cs = states[c]
		if cs.info.isA.GuiObject and gp(cs, "Visible") then
			table.insert(list, { c = c, st = cs, i = i })
		end
	end
	local byName = gp(layoutSt, "SortOrder") == Enum.SortOrder.Name
	table.sort(list, function(a, b)
		if byName then
			if a.st.name ~= b.st.name then
				return a.st.name < b.st.name
			end
		else
			local la, lb = gp(a.st, "LayoutOrder"), gp(b.st, "LayoutOrder")
			if la ~= lb then
				return la < lb
			end
		end
		return a.i < b.i
	end)
	return list
end

local function align(kind, free: number): number
	if kind == "Center" then
		return free / 2
	elseif kind == "Right" or kind == "Bottom" then
		return free
	end
	return 0
end

-- Full size of a child (base size, constraints, AutomaticSize) without placing it.
local measureSize -- forward

local function arrangeList(layout, kids, box)
	local lst = states[layout]
	local items = sortedForLayout(lst, kids)
	local horizontal = gp(lst, "FillDirection") == Enum.FillDirection.Horizontal
	local pad = gp(lst, "Padding")
	local gap = pad.Scale * (horizontal and box.w or box.h) + pad.Offset * box.k
	local hAlign = gp(lst, "HorizontalAlignment").Name
	local vAlign = gp(lst, "VerticalAlignment").Name
	local wraps = lst.info.props.Wraps and gp(lst, "Wraps") or false
	local flexH = lst.info.props.HorizontalFlex and gp(lst, "HorizontalFlex").Name or "None"
	local flexV = lst.info.props.VerticalFlex and gp(lst, "VerticalFlex").Name or "None"
	local flexMain = horizontal and flexH or flexV
	for _, it in ipairs(items) do
		it.w, it.h = measureSize(it.c, it.st, box)
	end
	-- lines (only more than one when Wraps)
	local lines = {}
	local cur = { items = {}, main = 0, cross = 0 }
	local limit = horizontal and box.w or box.h
	for _, it in ipairs(items) do
		local m = horizontal and it.w or it.h
		local c = horizontal and it.h or it.w
		local add = (#cur.items > 0 and gap or 0) + m
		if wraps and #cur.items > 0 and cur.main + add > limit + 0.01 then
			table.insert(lines, cur)
			cur = { items = {}, main = 0, cross = 0 }
			add = m
		end
		table.insert(cur.items, it)
		cur.main += add
		cur.cross = math.max(cur.cross, c)
	end
	if #cur.items > 0 then
		table.insert(lines, cur)
	end
	-- flex: grow items (UIFlexItem Grow/Fill or the layout's Fill mode)
	for _, line in ipairs(lines) do
		local free = limit - line.main
		if free > 0.5 then
			local growers = {}
			for _, it in ipairs(line.items) do
				local flex
				for _, ch in ipairs(it.st.children) do
					if states[ch].info.name == "UIFlexItem" then
						flex = ch
					end
				end
				local mode = flex and gp(states[flex], "FlexMode").Name or "None"
				if mode == "Grow" or mode == "Fill" or (mode == "Custom" and gp(states[flex], "GrowRatio") > 0) or (mode == "None" and flexMain == "Fill") then
					table.insert(growers, it)
				end
			end
			if #growers > 0 then
				local each = free / #growers
				for _, it in ipairs(growers) do
					if horizontal then
						it.w += each
					else
						it.h += each
					end
				end
				line.main = limit
				free = 0
			end
			line.free = free
		else
			line.free = math.max(0, free)
		end
	end
	-- place
	local totalCross = 0
	for i, line in ipairs(lines) do
		totalCross += line.cross + (i > 1 and gap or 0)
	end
	local crossFree = (horizontal and box.h or box.w) - totalCross
	local crossPos = align(horizontal and vAlign or hAlign, crossFree)
	if #lines <= 1 then
		crossPos = 0
	end
	local contentW, contentH = 0, 0
	for li, line in ipairs(lines) do
		local spacing = gap
		local start = 0
		local n = #line.items
		local free = line.free or 0
		if flexMain == "SpaceBetween" and n > 1 then
			spacing = gap + free / (n - 1)
		elseif flexMain == "SpaceAround" and n > 0 then
			spacing = gap + free / n
			start = free / n / 2
		elseif flexMain == "SpaceEvenly" and n > 0 then
			spacing = gap + free / (n + 1)
			start = free / (n + 1)
		else
			start = align(horizontal and hAlign or vAlign, free)
		end
		local pos = start
		for _, it in ipairs(line.items) do
			local x, y
			if horizontal then
				x = box.x + pos
				local crossSpace = #lines > 1 and line.cross or box.h
				y = box.y + crossPos + align(vAlign, crossSpace - it.h)
				pos += it.w + spacing
			else
				y = box.y + pos
				local crossSpace = #lines > 1 and line.cross or box.w
				x = box.x + crossPos + align(hAlign, crossSpace - it.w)
				pos += it.h + spacing
			end
			it.x, it.y = x, y
		end
		local used = pos - spacing - start
		if horizontal then
			contentW = math.max(contentW, line.main)
			contentH += line.cross + (li > 1 and gap or 0)
		else
			contentH = math.max(contentH, line.main)
			contentW += line.cross + (li > 1 and gap or 0)
		end
		local _ = used
		crossPos += line.cross + gap
	end
	if not horizontal then
		-- vertical lists: content width is the widest item
		contentW = 0
		for _, it in ipairs(items) do
			contentW = math.max(contentW, it.w)
		end
	else
		contentH = 0
		for _, it in ipairs(items) do
			contentH = math.max(contentH, it.h)
		end
		if #lines > 1 then
			contentH = totalCross
		end
	end
	lst.x.contentSize = Vector2.new(contentW, contentH)
	return items
end

local function arrangeGrid(layout, kids, box)
	local lst = states[layout]
	local items = sortedForLayout(lst, kids)
	local cs, cp = gp(lst, "CellSize"), gp(lst, "CellPadding")
	local k = box.k
	local cw = cs.X.Scale * box.w + cs.X.Offset * k
	local ch = cs.Y.Scale * box.h + cs.Y.Offset * k
	local px = cp.X.Scale * box.w + cp.X.Offset * k
	local py = cp.Y.Scale * box.h + cp.Y.Offset * k
	local horizontal = gp(lst, "FillDirection") == Enum.FillDirection.Horizontal
	local maxCells = gp(lst, "FillDirectionMaxCells")
	local n = #items
	local perLine
	if horizontal then
		perLine = math.max(1, math.floor((box.w + px + 0.01) / math.max(cw + px, 1e-6)))
	else
		perLine = math.max(1, math.floor((box.h + py + 0.01) / math.max(ch + py, 1e-6)))
	end
	if maxCells and maxCells > 0 then
		perLine = math.min(perLine, maxCells)
	end
	local cols, rows
	if horizontal then
		cols = math.min(perLine, math.max(n, 1))
		rows = math.ceil(n / perLine)
	else
		rows = math.min(perLine, math.max(n, 1))
		cols = math.ceil(n / perLine)
	end
	local blockW = cols * cw + math.max(0, cols - 1) * px
	local blockH = rows * ch + math.max(0, rows - 1) * py
	local x0 = box.x + align(gp(lst, "HorizontalAlignment").Name, box.w - blockW)
	local y0 = box.y + align(gp(lst, "VerticalAlignment").Name, box.h - blockH)
	local corner = gp(lst, "StartCorner").Name
	for i, it in ipairs(items) do
		local idx = i - 1
		local col, row
		if horizontal then
			col, row = idx % perLine, math.floor(idx / perLine)
		else
			row, col = idx % perLine, math.floor(idx / perLine)
		end
		if corner == "TopRight" or corner == "BottomRight" then
			col = cols - 1 - col
		end
		if corner == "BottomLeft" or corner == "BottomRight" then
			row = rows - 1 - row
		end
		it.x = x0 + col * (cw + px)
		it.y = y0 + row * (ch + py)
		it.w, it.h = cw, ch
		it.fixedSize = true
	end
	lst.x.contentSize = Vector2.new(blockW, blockH)
	lst.x.cellSize = Vector2.new(cw, ch)
	lst.x.cellCount = Vector2.new(cols, rows)
	return items
end

-- Places all children of `obj` inside content box `box`.
local function layoutChildren(obj, st, comps, kids, box)
	local layout = componentEnabled(comps.layout)
	local placed = {}
	if layout then
		local lname = states[layout].info.name
		local items
		if lname == "UIGridLayout" then
			items = arrangeGrid(layout, kids, box)
		elseif lname == "UIPageLayout" then
			items = sortedForLayout(states[layout], kids)
			for i, it in ipairs(items) do
				it.x, it.y, it.w, it.h = box.x + (i - 1) * box.w, box.y, box.w, box.h
				it.fixedSize = true
			end
			states[layout].x.contentSize = Vector2.new(box.w, box.h)
		else
			items = arrangeList(layout, kids, box)
		end
		for _, it in ipairs(items) do
			placed[it.c] = true
			layoutObject(it.c, it.st, box, it.x, it.y, it.w, it.h, it.fixedSize)
		end
	end
	for _, c in ipairs(kids) do
		if not placed[c] then
			local cs = states[c]
			if cs.info.name == "Path2D" then
				cs.x.layout = { x = box.x, y = box.y, w = box.w, h = box.h, k = box.k, chain = box.chain, clip = box.clip, visible = box.visible and gp(cs, "Visible"), rot = box.rot, root = box.root }
			else
				layoutObject(c, cs, box)
			end
		end
	end
end

-- Content extent of children laid out in `box` (relative to the box origin).
local function childExtent(kids, comps, box)
	local layout = componentEnabled(comps.layout)
	if layout and #kids > 0 then
		local cs = states[layout].x.contentSize
		if cs then
			return cs.X, cs.Y
		end
	end
	local w, h = 0, 0
	for _, c in ipairs(kids) do
		local l = states[c].x.layout
		if l and gp(states[c], "Visible") and states[c].info.isA.GuiObject then
			w = math.max(w, l.x + l.w - box.x)
			h = math.max(h, l.y + l.h - box.y)
		end
	end
	return w, h
end

-- The content box for an object's children given its final rect.
local function contentBox(obj, st, comps, x, y, w, h, kChild)
	local pl, pr, pt, pb = paddingOf(comps, w, h, kChild)
	return { x = x + pl, y = y + pt, w = math.max(0, w - pl - pr), h = math.max(0, h - pt - pb), k = kChild }
end

measureSize = function(obj, st, box)
	local _, comps = classify(obj)
	local w, h = baseSize(st, comps, box)
	w, h = applyConstraints(comps, w, h, box.k, box.w, box.h)
	local auto = gp(st, "AutomaticSize")
	if auto and auto ~= Enum.AutomaticSize.None then
		w, h = L.autoSize(obj, st, comps, box, w, h, auto)
	end
	return w, h
end

-- AutomaticSize: grows the auto axes to fit text and children (sizes before own UIScale).
function L.autoSize(obj, st, comps, box, w, h, auto)
	local s = ownScale(comps)
	local k = box.k
	local kChild = k * s
	local growX = auto == Enum.AutomaticSize.X or auto == Enum.AutomaticSize.XY
	local growY = auto == Enum.AutomaticSize.Y or auto == Enum.AutomaticSize.XY
	local pl, pr, pt, pb = paddingOf(comps, w * s, h * s, kChild)
	local cw, ch = 0, 0
	if isText(st) then
		local wrapWidth = (not growX) and math.max(0, w * s - pl - pr) or nil
		local res = layoutText(st, comps, w * s - pl - pr, h * s - pt - pb, kChild, wrapWidth)
		if growX and gp(st, "TextWrapped") then
			-- grows in X without a wrap limit
			res = layoutText(st, comps, math.huge, h * s - pt - pb, kChild, math.huge)
		end
		cw, ch = res.width, res.height
	end
	local kids = classify(obj)
	if #kids > 0 then
		local inner = { x = 0, y = 0, w = math.max(0, w * s - pl - pr), h = math.max(0, h * s - pt - pb), k = kChild, chain = IDENTITY, rot = 0, visible = false, provisional = true }
		layoutChildren(obj, st, comps, kids, inner)
		local ew, eh = childExtent(kids, comps, inner)
		cw, ch = math.max(cw, ew), math.max(ch, eh)
	end
	if growX then
		w = math.max(w, (cw + pl + pr) / s)
	end
	if growY then
		h = math.max(h, (ch + pt + pb) / s)
	end
	return w, h
end

layoutObject = function(obj, st, box, px, py, pw, ph, fixedSize)
	local kids, comps = classify(obj)
	local k = box.k
	local w, h
	if pw then
		w, h = pw, ph
	else
		w, h = baseSize(st, comps, box)
		w, h = applyConstraints(comps, w, h, k, box.w, box.h)
		local auto = gp(st, "AutomaticSize")
		if auto and auto ~= Enum.AutomaticSize.None then
			w, h = L.autoSize(obj, st, comps, box, w, h, auto)
		end
	end
	local ap = gp(st, "AnchorPoint")
	local ax, ay
	if px then
		ax, ay = px + ap.X * w, py + ap.Y * h
	else
		local pos = gp(st, "Position")
		ax = box.x + box.w * pos.X.Scale + pos.X.Offset * k
		ay = box.y + box.h * pos.Y.Scale + pos.Y.Offset * k
	end
	local s = ownScale(comps)
	local fw, fh = w * s, h * s
	local x, y = ax - ap.X * fw, ay - ap.Y * fh
	local rotation = gp(st, "Rotation")
	local chain = box.chain or IDENTITY
	if rotation ~= 0 then
		chain = mul(chain, rotateAbout(x + fw / 2, y + fh / 2, rotation))
	end
	local totalRot = (box.rot or 0) + rotation
	local visible = (box.visible ~= false) and gp(st, "Visible")
	local kChild = k * s
	local rec = st.x.layout
	if not rec or box.provisional then
		rec = {}
	end
	rec.x, rec.y, rec.w, rec.h = x, y, fw, fh
	rec.k = kChild
	rec.chain = chain
	rec.rot = totalRot
	rec.clip = box.clip
	rec.visible = visible
	rec.root = box.root
	rec.provisional = box.provisional
	st.x.layout = rec

	-- text
	if isText(st) then
		local pl, pr, pt, pb = paddingOf(comps, fw, fh, kChild)
		local res = layoutText(st, comps, math.max(0, fw - pl - pr), math.max(0, fh - pt - pb), kChild, nil)
		rec.text = res
		rec.textBox = { x = x + pl, y = y + pt, w = math.max(0, fw - pl - pr), h = math.max(0, fh - pt - pb) }
	end

	-- children
	local childClip = box.clip
	local clips = gp(st, "ClipsDescendants") or st.info.isA.ScrollingFrame or st.info.isA.CanvasGroup
	if clips and totalRot == 0 then
		local c = { x, y, x + fw, y + fh }
		if childClip then
			c = { math.max(c[1], childClip[1]), math.max(c[2], childClip[2]), math.min(c[3], childClip[3]), math.min(c[4], childClip[4]) }
		end
		childClip = c
	end
	if #kids > 0 or st.info.isA.ScrollingFrame then
		local inner
		if st.info.isA.ScrollingFrame then
			local cs = gp(st, "CanvasSize")
			local canvasW = cs.X.Scale * fw + cs.X.Offset * kChild
			local canvasH = cs.Y.Scale * fh + cs.Y.Offset * kChild
			local autoCanvas = gp(st, "AutomaticCanvasSize")
			local probe = { x = 0, y = 0, w = math.max(canvasW, fw), h = math.max(canvasH, fh), k = kChild }
			if autoCanvas ~= Enum.AutomaticSize.None then
				local pl, pr, pt, pb = paddingOf(comps, fw, fh, kChild)
				local tmp = { x = pl, y = pt, w = math.max(0, fw - pl - pr), h = math.max(0, fh - pt - pb), k = kChild, chain = IDENTITY, rot = 0, visible = false, provisional = true }
				layoutChildren(obj, st, comps, kids, tmp)
				local ew, eh = childExtent(kids, comps, tmp)
				if autoCanvas == Enum.AutomaticSize.X or autoCanvas == Enum.AutomaticSize.XY then
					canvasW = math.max(canvasW, ew + pl + pr)
				end
				if autoCanvas == Enum.AutomaticSize.Y or autoCanvas == Enum.AutomaticSize.XY then
					canvasH = math.max(canvasH, eh + pt + pb)
				end
			end
			local _ = probe
			-- the canvas is never smaller than the window
			canvasW = math.max(canvasW, fw)
			canvasH = math.max(canvasH, fh)
			local cpos = gp(st, "CanvasPosition")
			local maxX, maxY = math.max(0, canvasW - fw), math.max(0, canvasH - fh)
			local cx, cy = math.clamp(cpos.X, 0, maxX), math.clamp(cpos.Y, 0, maxY)
			st.x.canvas = { w = canvasW, h = canvasH, x = cx, y = cy }
			local pl, pr, pt, pb = paddingOf(comps, canvasW, canvasH, kChild)
			inner = { x = x - cx + pl, y = y - cy + pt, w = math.max(0, canvasW - pl - pr), h = math.max(0, canvasH - pt - pb), k = kChild }
		else
			inner = contentBox(obj, st, comps, x, y, fw, fh, kChild)
		end
		inner.chain = chain
		inner.rot = totalRot
		inner.clip = childClip
		inner.visible = visible
		inner.root = box.root
		inner.provisional = box.provisional
		rec.content = inner
		layoutChildren(obj, st, comps, kids, inner)
	end
	return rec
end

------------------------------------------------------------------------------------------
-- Roots
------------------------------------------------------------------------------------------

-- ScreenGui rect (screen px) for the current device profile.
function L.screenRect(st)
	local d = R.options.device
	local insets = gp(st, "ScreenInsets")
	local ignore = gp(st, "IgnoreGuiInset")
	local safe = (insets ~= Enum.ScreenInsets.None) and d.safe or { left = 0, right = 0, top = 0, bottom = 0 }
	local top = safe.top
	if not ignore then
		local topbarBottom = (d.topbarBelowSafeTop and d.safe.top or 0) + d.topbar
		top = math.max(top, topbarBottom)
	end
	return safe.left, top, d.width - safe.left - safe.right, d.height - top - safe.bottom
end

local function billboardRect(gui, st)
	local adornee = gp(st, "Adornee") or st.parent
	if not adornee or not states[adornee] then
		return nil
	end
	local ast = states[adornee]
	local pos
	if ast.info.isA.BasePart then
		pos = R.getProp(ast, "CFrame").Position
	elseif ast.info.isA.Attachment then
		pos = adornee.WorldPosition
	elseif ast.info.isA.Model then
		pos = adornee:GetPivot().Position
	else
		return nil
	end
	local cam = R.services.Workspace and R.getProp(states[R.services.Workspace], "CurrentCamera")
	if not cam then
		return nil
	end
	local camCF = R.getProp(states[cam], "CFrame")
	local offset = gp(st, "StudsOffset")
	pos = pos + gp(st, "StudsOffsetWorldSpace") + camCF:VectorToWorldSpace(offset)
	local v, _ = R.project(cam, pos)
	if v.Z <= 0.05 then
		return nil
	end
	local maxDist = gp(st, "MaxDistance")
	if maxDist and maxDist > 0 and maxDist < math.huge and v.Z > maxDist then
		return nil
	end
	local fov = math.rad(R.getProp(states[cam], "FieldOfView"))
	local d = R.options.device
	local pxPerStud = (d.height / 2) / (v.Z * math.tan(fov / 2))
	local size = gp(st, "Size")
	local w = size.X.Scale * pxPerStud + size.X.Offset
	local h = size.Y.Scale * pxPerStud + size.Y.Offset
	local so = gp(st, "SizeOffset")
	local x = v.X - w / 2 + so.X * w
	local y = v.Y - h / 2 - so.Y * h
	return x, y, w, h, v.Z
end

local function surfaceRect(gui, st)
	local adornee = gp(st, "Adornee") or st.parent
	if not adornee or not states[adornee] or not states[adornee].info.isA.BasePart then
		return 0, 0, 0, 0
	end
	local size = R.getProp(states[adornee], "Size")
	local face = gp(st, "Face").Name
	local fw, fh
	if face == "Front" or face == "Back" then
		fw, fh = size.X, size.Y
	elseif face == "Left" or face == "Right" then
		fw, fh = size.Z, size.Y
	else
		fw, fh = size.X, size.Z
	end
	if gp(st, "SizingMode") == Enum.SurfaceGuiSizingMode.PixelsPerStud then
		local pps = gp(st, "PixelsPerStud")
		return 0, 0, fw * pps, fh * pps
	end
	local cs = gp(st, "CanvasSize")
	return 0, 0, cs.X, cs.Y
end

-- LayerCollectors to lay out: ScreenGuis under PlayerGui, Billboard/SurfaceGuis anywhere.
function L.roots()
	local out = {}
	local function scan(inst, insideCollector)
		local st = states[inst]
		for _, c in ipairs(st.children) do
			local cs = states[c]
			if cs.info.isA.LayerCollector then
				table.insert(out, c)
			elseif not cs.info.isA.GuiObject then
				scan(c, insideCollector)
			end
		end
	end
	local player = R.localPlayer
	local pg = player and R.findChild(states[player], "PlayerGui")
	if pg then
		scan(pg, false)
	end
	if R.services.Workspace then
		scan(R.services.Workspace, false)
	end
	return out
end

local prevAbs = setmetatable({}, { __mode = "k" })

local layoutNow

function L.update(force: boolean?)
	if not R.guiDirty and not force then
		return
	end
	local P = R.prof
	if P and P.on then
		-- on-demand layouts (AbsoluteSize reads) are mock cost, not the reader's
		P.enter("[mock] gui layout")
		layoutNow()
		P.leave()
		return
	end
	layoutNow()
end

layoutNow = function()
	R.guiDirty = false
	L.updating = true
	for _, root in ipairs(L.roots()) do
		local st = states[root]
		local info = st.info
		local x, y, w, h, depth
		if info.isA.ScreenGui then
			x, y, w, h = L.screenRect(st)
		elseif info.isA.BillboardGui then
			x, y, w, h, depth = billboardRect(root, st)
		elseif info.isA.SurfaceGui then
			x, y, w, h = surfaceRect(root, st)
		else
			x, y, w, h = 0, 0, R.options.device.width, R.options.device.height
		end
		if x then
			local enabled = gp(st, "Enabled")
			st.x.layout = { x = x, y = y, w = w, h = h, k = 1, chain = IDENTITY, rot = 0, visible = enabled, depth = depth }
			local kids, comps = classify(root)
			local clip = nil
			if info.isA.BillboardGui and gp(st, "ClipsDescendants") then
				clip = { x, y, x + w, y + h }
			elseif info.isA.ScreenGui and R.options.device.clipSafe and gp(st, "ScreenInsets") ~= Enum.ScreenInsets.None and gp(st, "ClipToDeviceSafeArea") ~= false then
				clip = { x, y, x + w, y + h } -- devices with insetSpace: clip to the safe area
			end
			local box = { x = x, y = y, w = w, h = h, k = 1, chain = IDENTITY, rot = 0, clip = clip, visible = enabled, root = root }
			st.x.layout.content = box
			layoutChildren(root, st, comps, kids, box)
		else
			st.x.layout = { x = 0, y = 0, w = 0, h = 0, k = 1, chain = IDENTITY, rot = 0, visible = false, offscreen = true }
		end
	end
	L.updating = false
	-- AbsoluteSize / AbsolutePosition change signals for anything that listens
	for _, root in ipairs(L.roots()) do
		R.walk(root, function(d)
			local st = states[d]
			local ps = st.propSigs
			if ps and (ps.AbsoluteSize or ps.AbsolutePosition) then
				local l = st.x.layout
				if l then
					local prev = prevAbs[d]
					local now = { l.x, l.y, l.w, l.h }
					if prev then
						if ps.AbsoluteSize and (math.abs(prev[3] - now[3]) > 1e-3 or math.abs(prev[4] - now[4]) > 1e-3) then
							ps.AbsoluteSize:_fire()
						end
						if ps.AbsolutePosition and (math.abs(prev[1] - now[1]) > 1e-3 or math.abs(prev[2] - now[2]) > 1e-3) then
							ps.AbsolutePosition:_fire()
						end
					end
					prevAbs[d] = now
				end
			end
		end)
	end
end

function L.ensure()
	if R.guiDirty and not L.updating then
		-- a forced (on-demand) layout: count it by the game line that read AbsoluteSize /
		-- TextBounds on a dirty GUI (api.forcedLayouts)
		local key = "?"
		for lvl = 2, 8 do
			local src, ln = debug.info(lvl, "sl")
			if src and not string.find(src, "mock", 1, true) and not string.find(src, "runtime", 1, true) then
				key = string.gsub(src, '^%[string "(.*)"%]$', "%1") .. ":" .. tostring(ln)
				break
			end
		end
		R.forcedLayouts = R.forcedLayouts or {}
		R.forcedLayouts[key] = (R.forcedLayouts[key] or 0) + 1
		L.update()
	end
end

S.frameHooks.layout = function()
	if R.skipFrameLayout then
		return -- perf scenes: layout only on demand (AbsoluteSize reads call L.ensure)
	end
	L.update()
end

-- Seeds the change-detection baseline when someone starts listening.
R.onPropertySignal = function(inst, st, prop)
	if prop == "AbsoluteSize" or prop == "AbsolutePosition" then
		L.ensure()
		local l = st.x.layout
		if l then
			prevAbs[inst] = { l.x, l.y, l.w, l.h }
		end
	end
end

------------------------------------------------------------------------------------------
-- GUI classes: computed properties and legacy aliases
------------------------------------------------------------------------------------------

local function absGetter(field)
	return function(obj, st)
		-- insetSpace devices report positions with y = 0 at the bottom of the top bar
		local shift = R.options.device.insetSpace and R.options.device.topbar or 0
		if st.info.isA.ScreenGui then
			local x, y, w, h = L.screenRect(st)
			if field == "pos" then
				return Vector2.new(x, y - shift)
			end
			return Vector2.new(w, h)
		end
		L.ensure()
		local l = st.x.layout
		if not l then
			return Vector2.zero
		end
		if field == "pos" then
			return Vector2.new(l.x, l.y - shift)
		end
		return Vector2.new(l.w, l.h)
	end
end

R.defineClass("GuiBase2d", {
	getters = {
		AbsolutePosition = absGetter("pos"),
		AbsoluteSize = absGetter("size"),
		AbsoluteRotation = function(_, st)
			L.ensure()
			return st.x.layout and st.x.layout.rot or 0
		end,
	},
})

local function legacyTween(obj, props, easingDirection, easingStyle, time, override, callback)
	local TweenService = R.getService(R.game, "TweenService")
	local info = R.D.TweenInfo.new(time or 1, easingStyle or Enum.EasingStyle.Quad, easingDirection or Enum.EasingDirection.Out)
	local tween = TweenService:Create(obj, info, props)
	if callback then
		tween.Completed:Connect(function(state)
			callback(state == Enum.PlaybackState.Completed and Enum.TweenStatus.Completed or Enum.TweenStatus.Canceled)
		end)
	end
	tween:Play()
	return true
end

R.defineClass("GuiObject", {
	events = {
		"InputBegan", "InputChanged", "InputEnded", "MouseEnter", "MouseLeave", "MouseMoved", "MouseWheelForward",
		"MouseWheelBackward", "SelectionGained", "SelectionLost", "SelectionChanged", "TouchTap", "TouchLongPress",
		"TouchPan", "TouchPinch", "TouchRotate", "TouchSwipe", "DragBegin", "DragStopped",
	},
	defaults = {
		AutomaticSize = Enum.AutomaticSize.None,
		SizeConstraint = Enum.SizeConstraint.RelativeXY,
		BorderMode = Enum.BorderMode.Outline,
	},
	getters = {
		Transparency = function(_, st)
			return gp(st, "BackgroundTransparency")
		end,
		BackgroundColor = function(_, st)
			return roblox.BrickColor.new(gp(st, "BackgroundColor3"))
		end,
		BorderColor = function(_, st)
			return roblox.BrickColor.new(gp(st, "BorderColor3"))
		end,
		GuiState = function()
			return Enum.GuiState.Idle
		end,
		-- images never load here; `--set images=loaded` pretends they all did (pictures
		-- that hide their drawn fallback once loaded then show the loaded look)
		IsLoaded = function()
			local a = R.options and R.options.sceneArgs
			return a ~= nil and a.images == "loaded"
		end,
	},
	setters = {
		Transparency = function(obj, _, v)
			obj.BackgroundTransparency = v
		end,
		BackgroundColor = function(obj, _, v)
			obj.BackgroundColor3 = v.Color
		end,
		BorderColor = function(obj, _, v)
			obj.BorderColor3 = v.Color
		end,
	},
	methods = {
		TweenPosition = function(obj, pos, dir, style, time, override, cb)
			return legacyTween(obj, { Position = pos }, dir, style, time, override, cb)
		end,
		TweenSize = function(obj, size, dir, style, time, override, cb)
			return legacyTween(obj, { Size = size }, dir, style, time, override, cb)
		end,
		TweenSizeAndPosition = function(obj, size, pos, dir, style, time, override, cb)
			return legacyTween(obj, { Size = size, Position = pos }, dir, style, time, override, cb)
		end,
	},
})

R.defineClass("GuiButton", {
	events = { "Activated", "MouseButton1Click", "MouseButton1Down", "MouseButton1Up", "MouseButton2Click", "MouseButton2Down", "MouseButton2Up", "SecondaryActivated" },
})

-- Legacy Font enum <-> FontFace
local enumByFont = {}
for _, item in ipairs(Enum.Font:GetEnumItems()) do
	local ok, f = pcall(roblox.Font.fromEnum, item)
	if ok and f then
		local key = f.Family .. "|" .. f.Weight.Name .. "|" .. f.Style.Name
		if not enumByFont[key] then
			enumByFont[key] = item
		end
	end
end

local FONT_SIZES = {}
for _, item in ipairs(Enum.FontSize:GetEnumItems()) do
	local n = tonumber(string.match(item.Name, "%d+"))
	if n then
		FONT_SIZES[n] = item
	end
end

local function textDef()
	return {
		defaults = {},
		getters = {
			Font = function(_, st)
				local f = gp(st, "FontFace")
				return enumByFont[f.Family .. "|" .. f.Weight.Name .. "|" .. f.Style.Name] or Enum.Font.Unknown
			end,
			TextBounds = function(obj, st)
				L.ensure()
				local l = st.x.layout
				if not l or not l.text then
					return Vector2.zero
				end
				local k = l.k or 1
				-- TextBounds are in the object's own units (before UIScale)
				return Vector2.new(l.text.width / k, l.text.height / k)
			end,
			TextFits = function(_, st)
				L.ensure()
				local l = st.x.layout
				if not l or not l.text or not l.textBox then
					return true
				end
				return l.text.width <= l.textBox.w + 0.5 and l.text.height <= l.textBox.h + 0.5
			end,
			ContentText = function(_, st)
				local t = gp(st, "Text")
				if gp(st, "RichText") then
					return T.stripRich(t)
				end
				return t
			end,
			LocalizedText = function(_, st)
				return gp(st, "Text")
			end,
			TextWrap = function(_, st)
				return gp(st, "TextWrapped")
			end,
			TextColor = function(_, st)
				return roblox.BrickColor.new(gp(st, "TextColor3"))
			end,
			FontSize = function(_, st)
				local size = gp(st, "TextSize")
				local best, bestD = Enum.FontSize.Size14, math.huge
				for n, item in pairs(FONT_SIZES) do
					if math.abs(n - size) < bestD then
						best, bestD = item, math.abs(n - size)
					end
				end
				return best
			end,
		},
		setters = {
			Font = function(obj, _, v)
				local item = R.enumFromValue(Enum.Font, v)
				if not item then
					error("Unable to assign property Font. EnumItem expected, got " .. R.D.typeof(v), 0)
				end
				obj.FontFace = roblox.Font.fromEnum(item)
			end,
			TextWrap = function(obj, _, v)
				obj.TextWrapped = v
			end,
			TextColor = function(obj, _, v)
				obj.TextColor3 = v.Color
			end,
			FontSize = function(obj, _, v)
				local item = R.enumFromValue(Enum.FontSize, v)
				local n = item and tonumber(string.match(item.Name, "%d+"))
				if n then
					obj.TextSize = n
				end
			end,
		},
	}
end
R.defineClass("TextLabel", textDef())
R.defineClass("TextButton", textDef())
R.defineClass("TextBox", (function()
	local def = textDef()
	def.events = { "FocusLost", "Focused", "ReturnPressedFromOnScreenKeyboard" }
	def.methods = {
		CaptureFocus = function() end,
		ReleaseFocus = function() end,
		IsFocused = function()
			return false
		end,
	}
	return def
end)())

R.defineClass("ScrollingFrame", {
	getters = {
		AbsoluteCanvasSize = function(_, st)
			L.ensure()
			local c = st.x.canvas
			return c and Vector2.new(c.w, c.h) or Vector2.zero
		end,
		AbsoluteWindowSize = function(_, st)
			L.ensure()
			local l = st.x.layout
			return l and Vector2.new(l.w, l.h) or Vector2.zero
		end,
	},
})

local function contentSizeGetter(_, st)
	local parent = st.parent
	if parent then
		L.ensure()
	end
	return st.x.contentSize or Vector2.zero
end

R.defineClass("UIGridStyleLayout", {
	getters = { AbsoluteContentSize = contentSizeGetter },
	methods = {
		ApplyLayout = function() end,
	},
})
R.defineClass("UIListLayout", {
	defaults = {
		FillDirection = Enum.FillDirection.Vertical,
		HorizontalAlignment = Enum.HorizontalAlignment.Left,
		VerticalAlignment = Enum.VerticalAlignment.Top,
		SortOrder = Enum.SortOrder.LayoutOrder,
	},
})
R.defineClass("UIGridLayout", {
	defaults = {
		FillDirection = Enum.FillDirection.Horizontal,
		HorizontalAlignment = Enum.HorizontalAlignment.Left,
		VerticalAlignment = Enum.VerticalAlignment.Top,
		SortOrder = Enum.SortOrder.LayoutOrder,
	},
	getters = {
		AbsoluteCellSize = function(_, st)
			L.ensure()
			return st.x.cellSize or Vector2.zero
		end,
		AbsoluteCellCount = function(_, st)
			L.ensure()
			return st.x.cellCount or Vector2.zero
		end,
	},
})
R.defineClass("UIPageLayout", {
	events = { "PageEnter", "PageLeave", "Stopped" },
	defaults = {
		FillDirection = Enum.FillDirection.Horizontal,
		HorizontalAlignment = Enum.HorizontalAlignment.Center,
		VerticalAlignment = Enum.VerticalAlignment.Center,
		SortOrder = Enum.SortOrder.LayoutOrder,
	},
	methods = {
		JumpTo = function() end,
		JumpToIndex = function() end,
		Next = function() end,
		Previous = function() end,
	},
})
R.defineClass("UITableLayout", {
	defaults = { SortOrder = Enum.SortOrder.LayoutOrder },
})

R.defineClass("LayerCollector", {
	methods = {
		GetLayoutNodeTree = function()
			return nil
		end,
	},
})
R.defineClass("ScreenGui", {
	defaults = { IgnoreGuiInset = false, ZIndexBehavior = Enum.ZIndexBehavior.Sibling },
})
R.defineClass("BillboardGui", {
	defaults = { ZIndexBehavior = Enum.ZIndexBehavior.Sibling },
	getters = {
		CurrentDistance = function(_, st)
			L.ensure()
			return st.x.layout and st.x.layout.depth or 0
		end,
	},
})
R.defineClass("SurfaceGui", {
	defaults = { ZIndexBehavior = Enum.ZIndexBehavior.Sibling, Face = Enum.NormalId.Front },
})

-- Path2D: control points live in x.points.
R.defineClass("Path2D", {
	methods = {
		SetControlPoints = function(p, points)
			local st = states[p]
			st.x.points = table.clone(points)
			R.guiDirty = true
		end,
		GetControlPoints = function(p)
			return table.clone(states[p].x.points or {})
		end,
		GetControlPoint = function(p, i)
			return (states[p].x.points or {})[i]
		end,
		InsertControlPoint = function(p, i, point)
			local st = states[p]
			st.x.points = st.x.points or {}
			table.insert(st.x.points, i, point)
			R.guiDirty = true
		end,
		RemoveControlPoint = function(p, i)
			local st = states[p]
			table.remove(st.x.points or {}, i)
			R.guiDirty = true
		end,
		UpdateControlPoint = function(p, i, point)
			local st = states[p]
			st.x.points = st.x.points or {}
			st.x.points[i] = point
			R.guiDirty = true
		end,
		GetMaxLength = function()
			return 0
		end,
		GetLength = function()
			return 0
		end,
	},
	onClone = function(_, _, src, dst)
		dst.x.points = src.x.points and table.clone(src.x.points) or nil
	end,
})

R.layout = L
return L
