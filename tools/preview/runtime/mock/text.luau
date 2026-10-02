--!nocheck
--[[
	text.luau - fonts, rich text and line breaking with Roblox semantics.

	Measurements use the advance widths of the real font files the browser draws
	(tools/preview/.cache/fonts/metrics.json, made by fonts/fetch_fonts.py), so the
	runtime's TextBounds / TextScaled / wrapping match the screenshot.
	  * line height = TextSize * LineHeight; TextBounds.Y = lines * line height
	  * wrapping breaks at spaces; a word longer than the line breaks between characters
	  * TextScaled: largest whole size (1..100, UITextSizeConstraint) whose wrapped text fits
	  * rich text: b, i, u, s, br, font (color/size/face/family/weight/transparency),
	    stroke, uc/uppercase, sc/smallcaps, mark, comments, &lt; &gt; &amp; &quot; &apos;
]]

local roblox = require("@lune/roblox")
local R = require("./R")

local Enum = roblox.Enum
local T = {}

local metrics -- decoded metrics.json

function T.setMetrics(m)
	metrics = m
end

------------------------------------------------------------------------------------------
-- Font resolution: Roblox FontFace → a font file the browser has
------------------------------------------------------------------------------------------

local resolveCache = {}

local function familyKey(family: string): string
	local stem = string.match(family, "families/([%w_%-]+)%.json") or string.match(family, "([%w_%-]+)$") or family
	return string.lower(stem), stem
end

-- Returns { family, weight, style, file, syntheticItalic, note }
function T.resolve(font)
	local fam = font and font.Family or "rbxasset://fonts/families/SourceSansPro.json"
	local weight = font and font.Weight and font.Weight.Value or 400
	local italic = font and font.Style == Enum.FontStyle.Italic
	local key = fam .. "|" .. weight .. "|" .. tostring(italic)
	local cached = resolveCache[key]
	if cached then
		return cached
	end
	local lower, stem = familyKey(fam)
	local mapped = metrics and metrics.map[lower]
	local family, note
	if mapped then
		family = mapped[1]
		if mapped[2] ~= "same font" and mapped[2] ~= "same font (renamed)" then
			note = string.format("font %s drawn with %s (%s)", stem, family, mapped[2])
		end
	else
		family = metrics and metrics.default or "Source Sans 3"
		note = string.format("font %s is not available; drawn with %s", stem, family)
	end
	if note then
		R.note(note)
	end
	local files = metrics and metrics.families[family] or {}
	-- nearest available weight (CSS rule: heavier first above 500, lighter first below)
	local best, bestScore = nil, math.huge
	for k in pairs(files) do
		local w, style = string.match(k, "^(%d+)%-(%a+)$")
		w = tonumber(w)
		if style == "normal" then
			local d = math.abs(w - weight)
			local penalty = 0
			if weight >= 500 and w < weight then
				penalty = 1000
			elseif weight < 500 and w > weight then
				penalty = 1000
			end
			if d + penalty < bestScore then
				best, bestScore = w, d + penalty
			end
		end
	end
	best = best or 400
	local style = "normal"
	local synthetic = false
	if italic then
		if files[best .. "-italic"] then
			style = "italic"
		else
			synthetic = true
		end
	end
	local file = files[best .. "-" .. style] or files["400-normal"]
	local r = { family = family, weight = best, style = style, file = file, syntheticItalic = synthetic, metrics = file and metrics.metrics[file] }
	resolveCache[key] = r
	return r
end

------------------------------------------------------------------------------------------
-- Measuring
------------------------------------------------------------------------------------------

local function charWidth(m, ch: string): number
	local w = m and m.adv[ch]
	if w then
		return w
	end
	local cp = utf8.codepoint(ch)
	if cp and cp >= 0x2E80 then
		return 1.0 -- CJK / wide symbols
	end
	return m and m.fallback or 0.55
end

-- Width in px of `text` with resolved font `f` at `size` px.
function T.width(f, size: number, text: string): number
	local m = f.metrics
	local w = 0
	for _, cp in utf8.codes(text) do
		w += charWidth(m, utf8.char(cp))
	end
	return w * size
end

------------------------------------------------------------------------------------------
-- Rich text parsing → runs
------------------------------------------------------------------------------------------

local ENTITIES = { lt = "<", gt = ">", amp = "&", quot = '"', apos = "'" }

local function unescape(s: string): string
	return (string.gsub(s, "&(%a+);", function(name)
		return ENTITIES[name] or ("&" .. name .. ";")
	end))
end

local function parseColor(v: string)
	if not v then
		return nil
	end
	v = string.gsub(v, "%s", "")
	local hex = string.match(v, "^#(%x%x%x%x%x%x)$")
	if hex then
		return roblox.Color3.fromRGB(tonumber(string.sub(hex, 1, 2), 16), tonumber(string.sub(hex, 3, 4), 16), tonumber(string.sub(hex, 5, 6), 16))
	end
	local r, g, b = string.match(v, "^rgb%((%d+),(%d+),(%d+)%)$")
	if r then
		return roblox.Color3.fromRGB(tonumber(r), tonumber(g), tonumber(b))
	end
	return nil
end

local function parseAttrs(s: string)
	local out = {}
	for k, v in string.gmatch(s, "([%w_]+)%s*=%s*\"([^\"]*)\"") do
		out[string.lower(k)] = v
	end
	for k, v in string.gmatch(s, "([%w_]+)%s*=%s*'([^']*)'") do
		out[string.lower(k)] = v
	end
	return out
end

local WEIGHT_NAMES = { thin = 100, extralight = 200, light = 300, regular = 400, medium = 500, semibold = 600, bold = 700, extrabold = 800, heavy = 900 }

-- Splits rich text into runs: { text, bold, italic, underline, strike, color, size, family,
-- weight, transparency, stroke, upper, small, mark }
function T.parseRich(text: string)
	local runs = {}
	local stack = { {} }
	local function top()
		return stack[#stack]
	end
	local function push(over)
		local cur = table.clone(top())
		for k, v in pairs(over) do
			cur[k] = v
		end
		table.insert(stack, cur)
	end
	local function emit(s: string)
		if s == "" then
			return
		end
		local style = top()
		local t = unescape(s)
		if style.upper then
			t = string.upper(t)
		end
		local run = table.clone(style)
		run.text = t
		table.insert(runs, run)
	end
	local i = 1
	local n = #text
	while i <= n do
		local lt = string.find(text, "<", i, true)
		if not lt then
			emit(string.sub(text, i))
			break
		end
		emit(string.sub(text, i, lt - 1))
		if string.sub(text, lt, lt + 3) == "<!--" then
			local close = string.find(text, "-->", lt + 4, true)
			i = close and close + 3 or n + 1
		else
			local gt = string.find(text, ">", lt + 1, true)
			if not gt then
				emit(string.sub(text, lt))
				break
			end
			local tag = string.sub(text, lt + 1, gt - 1)
			local closing = string.sub(tag, 1, 1) == "/"
			local name = string.lower(string.match(tag, "^/?%s*([%a]+)") or "")
			if closing then
				if #stack > 1 then
					table.remove(stack)
				end
			elseif name == "br" then
				local run = table.clone(top())
				run.text = "\n"
				table.insert(runs, run)
			else
				local attrs = parseAttrs(tag)
				if name == "b" then
					push({ bold = true })
				elseif name == "i" then
					push({ italic = true })
				elseif name == "u" then
					push({ underline = true })
				elseif name == "s" then
					push({ strike = true })
				elseif name == "uc" or name == "uppercase" then
					push({ upper = true })
				elseif name == "sc" or name == "smallcaps" then
					push({ small = true, upper = true })
				elseif name == "font" then
					local over = {}
					over.color = parseColor(attrs.color)
					over.size = tonumber(attrs.size)
					over.transparency = tonumber(attrs.transparency)
					if attrs.face then
						over.family = "rbxasset://fonts/families/" .. attrs.face .. ".json"
					elseif attrs.family then
						over.family = attrs.family
					end
					if attrs.weight then
						over.weight = tonumber(attrs.weight) or WEIGHT_NAMES[string.lower(attrs.weight)]
					end
					push(over)
				elseif name == "stroke" then
					push({ stroke = { color = parseColor(attrs.color) or roblox.Color3.new(0, 0, 0), thickness = tonumber(attrs.thickness) or 1, transparency = tonumber(attrs.transparency) or 0 } })
				elseif name == "mark" then
					push({ mark = { color = parseColor(attrs.color) or roblox.Color3.new(1, 1, 0), transparency = tonumber(attrs.transparency) or 0 } })
				else
					push({})
				end
				if string.sub(tag, -1) == "/" and #stack > 1 then
					table.remove(stack)
				end
			end
			i = gt + 1
		end
	end
	return runs
end

function T.stripRich(text: string): string
	local out = {}
	for _, r in ipairs(T.parseRich(text)) do
		table.insert(out, r.text)
	end
	return table.concat(out)
end

------------------------------------------------------------------------------------------
-- Line layout
------------------------------------------------------------------------------------------

-- A run's resolved font and px size for a base font / size.
local function runFont(baseFont, baseSize: number, run)
	local fam = run.family or (baseFont and baseFont.Family) or "rbxasset://fonts/families/SourceSansPro.json"
	local weight = run.weight
	if not weight then
		weight = baseFont and baseFont.Weight and baseFont.Weight.Value or 400
		if run.bold then
			weight = math.max(weight, 700)
		end
	end
	local italic = run.italic or (baseFont and baseFont.Style == Enum.FontStyle.Italic)
	local weightItem = Enum.FontWeight.Regular
	for _, item in ipairs(Enum.FontWeight:GetEnumItems()) do
		if math.abs(item.Value - weight) < math.abs(weightItem.Value - weight) then
			weightItem = item
		end
	end
	local f = T.resolve(roblox.Font.new(fam, weightItem, italic and Enum.FontStyle.Italic or Enum.FontStyle.Normal))
	local size = run.size or baseSize
	if run.small then
		size *= 0.8
	end
	return f, size
end

--[[
	Lays out text in a box. opts:
	  text, font (Font), size (px), rich (bool), wrap (bool), maxWidth (px or nil),
	  lineHeight (multiplier)
	Returns { lines = { { width, height, segments = { { text, x, width, font, size, run } } } },
	          width, height }
]]
function T.layout(opts)
	local baseFont = opts.font
	local size = opts.size
	local lh = opts.lineHeight or 1
	local runs
	if opts.rich then
		runs = T.parseRich(opts.text)
	else
		runs = { { text = opts.text } }
	end
	-- tokens: words, spaces and newlines, each tied to its run
	local tokens = {}
	for _, run in ipairs(runs) do
		local f, sz = runFont(baseFont, size, run)
		local t = run.text
		local i = 1
		while i <= #t do
			local c = string.sub(t, i, i)
			if c == "\n" then
				table.insert(tokens, { kind = "nl", run = run, font = f, size = sz })
				i += 1
			elseif c == " " or c == "\t" then
				local j = i
				while j <= #t and (string.sub(t, j, j) == " " or string.sub(t, j, j) == "\t") do
					j += 1
				end
				local s = string.rep(" ", j - i)
				table.insert(tokens, { kind = "space", text = s, run = run, font = f, size = sz, width = T.width(f, sz, s) })
				i = j
			else
				local j = i
				while j <= #t do
					local cj = string.sub(t, j, j)
					if cj == " " or cj == "\t" or cj == "\n" then
						break
					end
					j += 1
				end
				local s = string.sub(t, i, j - 1)
				table.insert(tokens, { kind = "word", text = s, run = run, font = f, size = sz, width = T.width(f, sz, s) })
				i = j
			end
		end
	end

	local maxWidth = opts.wrap and opts.maxWidth or nil
	local lines = {}
	local line = { segments = {}, width = 0, maxSize = 0 }
	local pendingSpace = nil

	local function pushLine()
		if line.maxSize == 0 then
			line.maxSize = size
		end
		line.height = line.maxSize * lh
		table.insert(lines, line)
		line = { segments = {}, width = 0, maxSize = 0 }
		pendingSpace = nil
	end

	local function addSegment(text: string, tok, width: number)
		local seg = { text = text, x = line.width, width = width, font = tok.font, size = tok.size, run = tok.run }
		table.insert(line.segments, seg)
		line.width += width
		if tok.size > line.maxSize then
			line.maxSize = tok.size
		end
	end

	-- breaks a long word into pieces that fit `avail`
	local function breakWord(tok)
		local text = tok.text
		local pieces = {}
		local cur, curW = "", 0
		for _, cp in utf8.codes(text) do
			local ch = utf8.char(cp)
			local w = charWidth(tok.font.metrics, ch) * tok.size
			local avail = (#pieces == 0) and (maxWidth - line.width) or maxWidth
			if curW + w > avail and cur ~= "" then
				table.insert(pieces, { text = cur, width = curW })
				cur, curW = "", 0
			end
			cur ..= ch
			curW += w
		end
		if cur ~= "" then
			table.insert(pieces, { text = cur, width = curW })
		end
		return pieces
	end

	for _, tok in ipairs(tokens) do
		if tok.kind == "nl" then
			if tok.size > line.maxSize then
				line.maxSize = tok.size
			end
			line.hardBreak = true
			pushLine()
		elseif tok.kind == "space" then
			if not maxWidth then
				addSegment(tok.text, tok, tok.width)
			elseif #line.segments > 0 then
				-- only kept if the next word fits on this line (no trailing spaces)
				pendingSpace = tok
			elseif #lines == 0 or lines[#lines].hardBreak then
				addSegment(tok.text, tok, tok.width) -- leading spaces of a paragraph
			end
		else
			if maxWidth then
				local spaceW = pendingSpace and pendingSpace.width or 0
				if line.width + spaceW + tok.width <= maxWidth + 0.01 or #line.segments == 0 then
					if pendingSpace and #line.segments > 0 then
						addSegment(pendingSpace.text, pendingSpace, spaceW)
					end
					pendingSpace = nil
					if tok.width > maxWidth + 0.01 then
						local pieces = breakWord(tok)
						for k, piece in ipairs(pieces) do
							if k > 1 then
								pushLine()
							end
							addSegment(piece.text, tok, piece.width)
						end
					else
						addSegment(tok.text, tok, tok.width)
					end
				else
					pushLine()
					if tok.width > maxWidth + 0.01 then
						local pieces = breakWord(tok)
						for k, piece in ipairs(pieces) do
							if k > 1 then
								pushLine()
							end
							addSegment(piece.text, tok, piece.width)
						end
					else
						addSegment(tok.text, tok, tok.width)
					end
				end
			else
				addSegment(tok.text, tok, tok.width)
			end
		end
	end
	pushLine()

	local w, h = 0, 0
	for _, l in ipairs(lines) do
		if l.width > w then
			w = l.width
		end
		h += l.height
	end
	return { lines = lines, width = w, height = h }
end

-- Largest whole text size (min..max) whose layout fits boxW x boxH.
function T.fitSize(opts, boxW: number, boxH: number, minSize: number, maxSize: number): number
	local lo, hi = math.max(1, math.floor(minSize)), math.max(1, math.floor(maxSize))
	local function fits(s)
		local o = table.clone(opts)
		o.size = s
		o.wrap = true
		o.maxWidth = boxW
		local res = T.layout(o)
		if res.height > boxH + 0.01 then
			return false
		end
		-- words may not be split when scaling
		for _, l in ipairs(res.lines) do
			if l.width > boxW + 0.01 then
				return false
			end
		end
		local words = T.layout({ text = opts.text, font = opts.font, size = s, rich = opts.rich, wrap = false, lineHeight = opts.lineHeight })
		for _, l in ipairs(words.lines) do
			for _, seg in ipairs(l.segments) do
				if seg.width > boxW + 0.01 and not string.find(seg.text, " ") then
					return false
				end
			end
		end
		return true
	end
	if fits(hi) then
		return hi
	end
	if not fits(lo) then
		return lo
	end
	while hi - lo > 1 do
		local mid = math.floor((lo + hi) / 2)
		if fits(mid) then
			lo = mid
		else
			hi = mid
		end
	end
	return lo
end

-- Cuts `line` so it fits `maxWidth`, ending with "..." (TextTruncate).
function T.truncateLine(line, maxWidth: number)
	if line.width <= maxWidth + 0.01 then
		return line
	end
	local out = { segments = {}, width = 0, height = line.height, maxSize = line.maxSize }
	local dotsFont = line.segments[1] and line.segments[1].font
	local dotsSize = line.segments[1] and line.segments[1].size or 14
	local dotsW = dotsFont and T.width(dotsFont, dotsSize, "...") or 0
	for _, seg in ipairs(line.segments) do
		if out.width + seg.width + dotsW <= maxWidth then
			table.insert(out.segments, seg)
			out.width += seg.width
		else
			local cut = ""
			local cutW = 0
			for _, cp in utf8.codes(seg.text) do
				local ch = utf8.char(cp)
				local w = charWidth(seg.font.metrics, ch) * seg.size
				if out.width + cutW + w + dotsW > maxWidth then
					break
				end
				cut ..= ch
				cutW += w
			end
			local s = table.clone(seg)
			s.text = cut .. "..."
			s.width = cutW + dotsW
			s.x = out.width
			table.insert(out.segments, s)
			out.width += s.width
			return out
		end
	end
	return out
end

R.text = T
return T
