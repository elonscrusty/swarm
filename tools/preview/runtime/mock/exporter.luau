--!nocheck
--[[
	exporter.luau - turns the mock's DataModel into the JSON the browser renderer draws.

	World: BaseParts (Block/Ball/Cylinder/Wedge/CornerWedge, MeshParts by catalog piece,
	SpecialMesh shapes), lights, Fire / ParticleEmitter sprites, Highlights, Beams,
	Lighting + post effects, the camera.
	GUI: a flat paint list per Roblox ZIndex rules (ScreenGuis by DisplayOrder, Sibling /
	Global ZIndexBehavior, CanvasGroups as nested groups), each item with its final
	transform, clip rect, colours, corners, strokes, gradients and laid-out text lines.
	BillboardGuis are projected into screen space and drawn under the ScreenGuis.
	ViewportFrames export their own parts + camera for a second render pass.
]]

local roblox = require("@lune/roblox")
local R = require("./R")
local L = require("./layout")
local T = require("./text")

local states = R.states
local Enum = roblox.Enum
local CFrame, Vector3 = roblox.CFrame, roblox.Vector3

local E = {}

local function gp(st, key)
	local v = st.props[key]
	if v == nil then
		v = st.info.defaults[key]
	end
	return v
end

local function r4(x: number): number
	return math.floor(x * 10000 + 0.5) / 10000
end

local function cf12(cf)
	local c = { cf:GetComponents() }
	for i = 1, 12 do
		c[i] = r4(c[i])
	end
	return c
end

local function v3(v)
	return { r4(v.X), r4(v.Y), r4(v.Z) }
end

local function c3(c)
	return { r4(c.R), r4(c.G), r4(c.B) }
end

local function rgba(c, transparency)
	return { r4(c.R), r4(c.G), r4(c.B), r4(math.clamp(1 - (transparency or 0), 0, 1)) }
end

------------------------------------------------------------------------------------------
-- World
------------------------------------------------------------------------------------------

local SPECIAL = { Brick = "Block", Sphere = "Sphere", Cylinder = "Cylinder", Head = "Head", Wedge = "Wedge", Torso = "Torso", FileMesh = "File" }

local function partRecord(p, st, idCounter)
	local info = st.info
	local t = gp(st, "Transparency")
	local ltm = gp(st, "LocalTransparencyModifier") or 0
	local eff = 1 - (1 - t) * (1 - ltm)
	if eff >= 0.999 then
		return nil
	end
	local rec = {
		id = idCounter,
		name = st.name,
		size = v3(gp(st, "Size")),
		cf = cf12(gp(st, "CFrame")),
		color = c3(gp(st, "Color")),
		material = gp(st, "Material").Name,
		transparency = r4(eff),
		reflectance = r4(gp(st, "Reflectance")),
		shadow = gp(st, "CastShadow") and eff < 0.5,
	}
	if info.isA.MeshPart then
		rec.shape = "Mesh"
		local ref = st.attrs and st.attrs.PreviewMeshRef
		if ref then
			rec.mesh = { ref = ref }
		else
			rec.mesh = { id = gp(st, "MeshId") }
			R.note("MeshPart without a catalog mesh drawn as a box: " .. tostring(gp(st, "MeshId")))
		end
	elseif info.isA.WedgePart then
		rec.shape = "Wedge"
	elseif info.isA.CornerWedgePart then
		rec.shape = "CornerWedge"
	elseif info.isA.Part then
		rec.shape = gp(st, "Shape").Name
	else
		rec.shape = "Block"
		if not info.isA.TrussPart and not info.isA.SpawnLocation and not info.isA.Seat then
			R.note(info.name .. " drawn as a box")
		end
	end
	for _, c in ipairs(st.children) do
		local cs = states[c]
		if cs.info.isA.SpecialMesh then
			local mt = gp(cs, "MeshType").Name
			rec.shape = "Special"
			rec.special = SPECIAL[mt] or "Block"
			rec.meshScale = v3(gp(cs, "Scale"))
			rec.meshOffset = v3(gp(cs, "Offset"))
			if mt == "FileMesh" then
				R.note("SpecialMesh FileMesh drawn as a box")
			end
		elseif cs.info.isA.Decal then
			R.note("Decals / Textures are not drawn")
		elseif cs.info.isA.SurfaceGui then
			R.note("SurfaceGuis are not drawn")
		end
	end
	return rec
end

local NORMALS = {
	Front = Vector3.new(0, 0, -1),
	Back = Vector3.new(0, 0, 1),
	Top = Vector3.new(0, 1, 0),
	Bottom = Vector3.new(0, -1, 0),
	Left = Vector3.new(-1, 0, 0),
	Right = Vector3.new(1, 0, 0),
}

local function worldCFrameOf(inst)
	if not inst then
		return nil
	end
	local st = states[inst]
	if st.info.isA.BasePart then
		return gp(st, "CFrame")
	elseif st.info.isA.Attachment then
		return inst.WorldCFrame
	end
	return nil
end

local function sampleSequence(seq, t)
	local kps = seq.Keypoints
	if #kps == 0 then
		return nil
	end
	for i = 1, #kps - 1 do
		local a, b = kps[i], kps[i + 1]
		if t >= a.Time and t <= b.Time then
			local u = (t - a.Time) / math.max(b.Time - a.Time, 1e-6)
			if typeof(a.Value) == "Color3" then
				return a.Value:Lerp(b.Value, u)
			end
			return a.Value + (b.Value - a.Value) * u
		end
	end
	return kps[#kps].Value
end

local function maxOfSequence(seq)
	local m = 0
	for _, kp in ipairs(seq.Keypoints) do
		m = math.max(m, kp.Value)
	end
	return m
end

-- Collects world content under `root` (workspace or a ViewportFrame / WorldModel).
function E.collectWorld(root, opts)
	opts = opts or {}
	local out = { parts = {}, lights = {}, sprites = {}, highlights = {}, beams = {}, idOf = {} }
	local nextId = 0
	local rng = R.D.Random.new(12345)
	local function visit(inst)
		local st = states[inst]
		local info = st.info
		if info.isA.BasePart then
			if not info.isA.Terrain then
				nextId += 1
				local rec = partRecord(inst, st, nextId)
				if rec then
					table.insert(out.parts, rec)
					out.idOf[inst] = nextId
				end
			end
		elseif info.isA.Light then
			if gp(st, "Enabled") then
				local cf = worldCFrameOf(st.parent)
				if cf then
					local rec = {
						type = info.isA.PointLight and "point" or (info.isA.SpotLight and "spot" or "surface"),
						pos = v3(cf.Position),
						color = c3(gp(st, "Color")),
						brightness = r4(gp(st, "Brightness")),
						range = r4(gp(st, "Range")),
						shadows = gp(st, "Shadows"),
					}
					if not info.isA.PointLight then
						local face = gp(st, "Face").Name
						rec.dir = v3(cf:VectorToWorldSpace(NORMALS[face] or NORMALS.Front))
						rec.angle = r4(gp(st, "Angle"))
						if info.isA.SurfaceLight then
							local size = states[st.parent].info.isA.BasePart and gp(states[st.parent], "Size") or Vector3.one
							rec.pos = v3(cf * ((NORMALS[face] or NORMALS.Front) * size / 2))
						end
					end
					table.insert(out.lights, rec)
				end
			end
		elseif info.name == "Fire" then
			if gp(st, "Enabled") then
				local cf = worldCFrameOf(st.parent)
				if cf then
					local size = gp(st, "Size")
					local base = cf.Position
					local c1, c2 = gp(st, "Color"), gp(st, "SecondaryColor")
					for i = 1, 3 do
						table.insert(out.sprites, {
							kind = "fire",
							pos = v3(base + Vector3.new(0, (i - 1) * size * 0.35, 0)),
							size = r4(size * (1.1 - (i - 1) * 0.3)),
							color = c3(c1:Lerp(c2, (i - 1) / 2)),
							alpha = r4(0.85 - (i - 1) * 0.2),
							additive = true,
						})
					end
				end
			end
		elseif info.isA.ParticleEmitter then
			if gp(st, "Enabled") then
				local pst = st.parent and states[st.parent]
				local cf = worldCFrameOf(st.parent)
				if cf then
					local life = gp(st, "Lifetime")
					local count = math.clamp(math.floor(gp(st, "Rate") * (life.Min + life.Max) / 2 + 0.5), 1, 40)
					local half = (pst and pst.info.isA.BasePart) and gp(pst, "Size") / 2 or Vector3.zero
					local sizeSeq = gp(st, "Size")
					local transSeq = gp(st, "Transparency")
					local colSeq = gp(st, "Color")
					local emission = gp(st, "LightEmission")
					for _ = 1, count do
						local t = rng:NextNumber(0.15, 0.85)
						local local_ = Vector3.new(rng:NextNumber(-1, 1) * half.X, rng:NextNumber(-1, 1) * half.Y, rng:NextNumber(-1, 1) * half.Z)
						table.insert(out.sprites, {
							kind = "particle",
							pos = v3(cf * local_),
							size = r4(math.max(0.05, sampleSequence(sizeSeq, t) or maxOfSequence(sizeSeq))),
							color = c3(sampleSequence(colSeq, t) or roblox.Color3.new(1, 1, 1)),
							alpha = r4(math.clamp(1 - (sampleSequence(transSeq, t) or 0), 0, 1)),
							additive = emission > 0.5,
						})
					end
					R.note("ParticleEmitters are drawn as a few static sprites")
				end
			end
		elseif info.name == "Sparkles" or info.name == "Smoke" then
			R.note(info.name .. " effects are not drawn")
		elseif info.isA.Highlight then
			if gp(st, "Enabled") then
				table.insert(out.highlights, { inst = inst, st = st })
			end
		elseif info.isA.Beam then
			if gp(st, "Enabled") then
				local a0, a1 = gp(st, "Attachment0"), gp(st, "Attachment1")
				if a0 and a1 then
					local col = gp(st, "Color")
					local tr = gp(st, "Transparency")
					table.insert(out.beams, {
						p0 = v3(a0.WorldPosition),
						p1 = v3(a1.WorldPosition),
						w0 = r4(gp(st, "Width0")),
						w1 = r4(gp(st, "Width1")),
						color = c3(sampleSequence(col, 0.5) or roblox.Color3.new(1, 1, 1)),
						alpha = r4(1 - (sampleSequence(tr, 0.5) or 0)),
						additive = gp(st, "LightEmission") > 0.5,
					})
					R.note("Beams are drawn as flat camera-facing strips (no texture, no curve)")
				end
			end
		elseif info.isA.Trail then
			R.note("Trails are not drawn")
		end
		if not opts.skipChildrenOf or not opts.skipChildrenOf(inst) then
			for _, c in ipairs(st.children) do
				local cs = states[c]
				if not cs.info.isA.GuiBase2d then
					visit(c)
				end
			end
		end
	end
	for _, c in ipairs(states[root].children) do
		local cs = states[c]
		if not cs.info.isA.Camera and not cs.info.isA.GuiBase2d then
			visit(c)
		end
	end
	-- highlight → part ids
	local hl = {}
	for _, h in ipairs(out.highlights) do
		local adornee = gp(h.st, "Adornee") or h.st.parent
		local ids = {}
		if adornee then
			local ast = states[adornee]
			if ast.info.isA.BasePart and out.idOf[adornee] then
				table.insert(ids, out.idOf[adornee])
			end
			for _, d in ipairs(R.descendants(adornee)) do
				if out.idOf[d] then
					table.insert(ids, out.idOf[d])
				end
			end
		end
		if #ids > 0 then
			table.insert(hl, {
				parts = ids,
				fill = c3(gp(h.st, "FillColor")),
				fillAlpha = r4(1 - gp(h.st, "FillTransparency")),
				outline = c3(gp(h.st, "OutlineColor")),
				outlineAlpha = r4(1 - gp(h.st, "OutlineTransparency")),
				alwaysOnTop = gp(h.st, "DepthMode") == Enum.HighlightDepthMode.AlwaysOnTop,
			})
		end
	end
	out.highlights = hl
	out.idOf = nil
	return out
end

function E.lighting()
	local lighting = R.services.Lighting
	if not lighting then
		return nil
	end
	local st = states[lighting]
	local clock = lighting.ClockTime
	local lat = gp(st, "GeographicLatitude")
	local out = {
		clock = r4(clock),
		latitude = r4(lat),
		sun = v3(R.sunDirection(clock, lat)),
		brightness = r4(gp(st, "Brightness")),
		ambient = c3(gp(st, "Ambient")),
		outdoorAmbient = c3(gp(st, "OutdoorAmbient")),
		colorShiftTop = c3(gp(st, "ColorShift_Top")),
		colorShiftBottom = c3(gp(st, "ColorShift_Bottom")),
		shadowSoftness = r4(gp(st, "ShadowSoftness")),
		globalShadows = gp(st, "GlobalShadows"),
		envDiffuse = r4(gp(st, "EnvironmentDiffuseScale")),
		envSpecular = r4(gp(st, "EnvironmentSpecularScale")),
		exposure = r4(gp(st, "ExposureCompensation")),
		fogStart = r4(gp(st, "FogStart")),
		fogEnd = r4(gp(st, "FogEnd")),
		fogColor = c3(gp(st, "FogColor")),
		technology = gp(st, "Technology").Name,
		effects = {},
	}
	local function effectList(container)
		for _, c in ipairs(states[container].children) do
			local cs = states[c]
			local n = cs.info.name
			local enabled = not cs.info.props.Enabled or gp(cs, "Enabled") ~= false
			if n == "Atmosphere" then
				out.effects.atmosphere = { density = r4(gp(cs, "Density")), offset = r4(gp(cs, "Offset")), color = c3(gp(cs, "Color")), decay = c3(gp(cs, "Decay")), glare = r4(gp(cs, "Glare")), haze = r4(gp(cs, "Haze")) }
			elseif n == "BloomEffect" and enabled then
				out.effects.bloom = { intensity = r4(gp(cs, "Intensity")), size = r4(gp(cs, "Size")), threshold = r4(gp(cs, "Threshold")) }
			elseif n == "ColorCorrectionEffect" and enabled then
				out.effects.colorCorrection = out.effects.colorCorrection or {}
				table.insert(out.effects.colorCorrection, { brightness = r4(gp(cs, "Brightness")), contrast = r4(gp(cs, "Contrast")), saturation = r4(gp(cs, "Saturation")), tint = c3(gp(cs, "TintColor")) })
			elseif n == "SunRaysEffect" and enabled then
				out.effects.sunRays = { intensity = r4(gp(cs, "Intensity")), spread = r4(gp(cs, "Spread")) }
			elseif n == "BlurEffect" and enabled then
				out.effects.blur = { size = r4(gp(cs, "Size")) }
			elseif n == "DepthOfFieldEffect" and enabled then
				R.note("DepthOfFieldEffect is not drawn")
			elseif n == "Sky" then
				out.effects.sky = { celestialBodiesShown = gp(cs, "CelestialBodiesShown"), sunAngularSize = r4(gp(cs, "SunAngularSize")) }
				R.note("Sky textures are not drawn (gradient sky from the Atmosphere instead)")
			end
		end
	end
	effectList(lighting)
	local cam = R.services.Workspace and gp(states[R.services.Workspace], "CurrentCamera")
	if cam then
		effectList(cam)
	end
	return out
end

------------------------------------------------------------------------------------------
-- GUI
------------------------------------------------------------------------------------------

local vpCounter = 0

local function translateChain(chain, x, y)
	-- chain * T(x, y)
	return { chain[1], chain[2], chain[3], chain[4], chain[1] * x + chain[3] * y + chain[5], chain[2] * x + chain[4] * y + chain[6] }
end

local function round4list(t)
	local o = {}
	for i, v in ipairs(t) do
		o[i] = r4(v)
	end
	return o
end

local function componentsOf(st)
	local comps = {}
	for _, c in ipairs(st.children) do
		local cs = states[c]
		local n = cs.info.name
		if (cs.info.isA.UIComponent or cs.info.isA.UIBase) and not comps[n] then
			if not cs.info.props.Enabled or gp(cs, "Enabled") ~= false then
				comps[n] = cs
			end
		end
	end
	return comps
end

local function gradientOf(gst)
	if not gst then
		return nil
	end
	local colors = {}
	for _, kp in ipairs(gp(gst, "Color").Keypoints) do
		table.insert(colors, { r4(kp.Time), r4(kp.Value.R), r4(kp.Value.G), r4(kp.Value.B) })
	end
	local alphas = {}
	for _, kp in ipairs(gp(gst, "Transparency").Keypoints) do
		table.insert(alphas, { r4(kp.Time), r4(1 - kp.Value) })
	end
	local off = gp(gst, "Offset")
	return { rotation = r4(gp(gst, "Rotation")), offset = { r4(off.X), r4(off.Y) }, colors = colors, alphas = alphas }
end

local function strokeOf(sst, k)
	if not sst then
		return nil
	end
	local pos = sst.info.props.BorderStrokePosition and gp(sst, "BorderStrokePosition").Name or "Outer"
	return {
		thickness = r4(gp(sst, "Thickness") * k),
		color = rgba(gp(sst, "Color"), gp(sst, "Transparency")),
		mode = gp(sst, "ApplyStrokeMode").Name,
		position = pos,
		join = gp(sst, "LineJoinMode").Name,
		gradient = nil,
	}
end

local function textItem(st, rec, comps, alphaMul)
	local res = rec.text
	if not res or not rec.textBox then
		return nil
	end
	local box = rec.textBox
	local xa = gp(st, "TextXAlignment").Name
	local ya = gp(st, "TextYAlignment").Name
	local truncate = gp(st, "TextTruncate").Name ~= "None"
	local baseColor = gp(st, "TextColor3")
	local baseT = gp(st, "TextTransparency")
	if st.x.placeholder then
		baseColor = gp(st, "PlaceholderColor3")
	end
	local lines = res.lines
	if truncate then
		local maxLines = math.max(1, math.floor(box.h / math.max(lines[1] and lines[1].height or 1, 1) + 0.001))
		local cut = {}
		for i = 1, math.min(#lines, maxLines) do
			local line = lines[i]
			if i == math.min(#lines, maxLines) and (#lines > maxLines or line.width > box.w + 0.5) then
				line = T.truncateLine(line, box.w)
			end
			table.insert(cut, line)
		end
		lines = cut
	end
	local total = 0
	for _, l in ipairs(lines) do
		total += l.height
	end
	local y
	if ya == "Top" then
		y = 0
	elseif ya == "Bottom" then
		y = box.h - total
	else
		y = (box.h - total) / 2
	end
	local maxVisible = gp(st, "MaxVisibleGraphemes")
	local shown = 0
	local outLines = {}
	for _, line in ipairs(lines) do
		local lx
		if xa == "Left" then
			lx = 0
		elseif xa == "Right" then
			lx = box.w - line.width
		else
			lx = (box.w - line.width) / 2
		end
		local segs = {}
		for _, seg in ipairs(line.segments) do
			local run = seg.run or {}
			local text = seg.text
			if maxVisible and maxVisible >= 0 then
				local n = utf8.len(text) or #text
				if shown + n > maxVisible then
					local keep = math.max(0, maxVisible - shown)
					local cut = utf8.offset(text, keep + 1)
					text = cut and string.sub(text, 1, cut - 1) or text
				end
				shown += n
			end
			if text ~= "" then
				local color = run.color or baseColor
				local tr = run.transparency or baseT
				local f = seg.font
				local s = {
					t = text,
					x = r4(lx + seg.x),
					w = r4(seg.width),
					font = f.family,
					weight = f.weight,
					style = f.style,
					synth = f.syntheticItalic or nil,
					size = r4(seg.size),
					color = rgba(color, 1 - (1 - tr) * alphaMul),
					u = run.underline or nil,
					s = run.strike or nil,
				}
				if run.stroke then
					s.stroke = { color = rgba(run.stroke.color, run.stroke.transparency), thickness = r4(run.stroke.thickness * (rec.k or 1)) }
				end
				if run.mark then
					s.mark = rgba(run.mark.color, run.mark.transparency)
				end
				table.insert(segs, s)
			end
		end
		table.insert(outLines, { y = r4(y), h = r4(line.height), segs = segs })
		y += line.height
	end
	local out = { x = r4(box.x - rec.x), y = r4(box.y - rec.y), w = r4(box.w), h = r4(box.h), lines = outLines }
	local strokeT = gp(st, "TextStrokeTransparency")
	if strokeT < 1 then
		out.legacyStroke = { color = rgba(gp(st, "TextStrokeColor3"), 1 - (1 - strokeT) * (1 - baseT) * alphaMul), thickness = r4(1 * (rec.k or 1)) }
	end
	if comps.UIStroke and gp(comps.UIStroke, "ApplyStrokeMode") == Enum.ApplyStrokeMode.Contextual then
		local s = strokeOf(comps.UIStroke, rec.k or 1)
		s.color[4] = r4(s.color[4] * (1 - baseT) * alphaMul)
		out.stroke = s
	end
	if comps.UIGradient then
		out.gradient = gradientOf(comps.UIGradient)
	end
	return out
end

-- Builds the paint item(s) of one GuiObject; returns the item.
local function guiItem(obj, st, alphaMul, ctx)
	local rec = st.x.layout
	if not rec then
		return nil
	end
	local info = st.info
	local comps = componentsOf(st)
	local item = {
		t = "box",
		name = st.name,
		m = round4list(translateChain(rec.chain, rec.x, rec.y)),
		w = r4(rec.w),
		h = r4(rec.h),
		clip = rec.clip and round4list(rec.clip) or nil,
	}
	local bgT = gp(st, "BackgroundTransparency")
	if info.isA.TextBox or info.isA.TextLabel or info.isA.TextButton or info.isA.Frame or info.isA.ImageLabel or info.isA.ImageButton or info.isA.ScrollingFrame or info.isA.ViewportFrame or info.isA.CanvasGroup or info.isA.VideoFrame then
		if bgT < 1 then
			item.bg = rgba(gp(st, "BackgroundColor3"), 1 - (1 - bgT) * alphaMul)
		end
	end
	local minSide = math.min(rec.w, rec.h)
	if comps.UICorner then
		local cr = gp(comps.UICorner, "CornerRadius")
		item.radius = r4(math.min(cr.Scale * minSide + cr.Offset * (rec.k or 1), minSide / 2))
	end
	local border = gp(st, "BorderSizePixel")
	if border > 0 and bgT < 1 and not comps.UICorner then
		item.border = { w = border, color = rgba(gp(st, "BorderColor3"), 1 - (1 - bgT) * alphaMul), mode = gp(st, "BorderMode").Name }
	end
	if comps.UIStroke then
		local mode = gp(comps.UIStroke, "ApplyStrokeMode")
		local isTextObj = info.isA.TextLabel or info.isA.TextButton or info.isA.TextBox
		if mode == Enum.ApplyStrokeMode.Border or not isTextObj then
			local s = strokeOf(comps.UIStroke, rec.k or 1)
			s.color[4] = r4(s.color[4] * alphaMul)
			item.stroke = s
		end
	end
	if comps.UIGradient then
		item.gradient = gradientOf(comps.UIGradient)
	end
	if info.isA.TextLabel or info.isA.TextButton or info.isA.TextBox then
		item.text = textItem(st, rec, comps, alphaMul)
	end
	if info.isA.ImageLabel or info.isA.ImageButton then
		local image = gp(st, "Image")
		local imageT = gp(st, "ImageTransparency")
		if image ~= "" and imageT < 1 then
			item.image = { src = image, color = rgba(gp(st, "ImageColor3"), 1 - (1 - imageT) * alphaMul), scaleType = gp(st, "ScaleType").Name }
			R.note("Images (rbxassetid / rbxasset) are drawn as neutral placeholders")
		end
	end
	if info.isA.ScrollingFrame then
		local canvas = st.x.canvas
		local thick = gp(st, "ScrollBarThickness") * (rec.k or 1)
		if canvas and thick > 0 and gp(st, "ScrollingEnabled") then
			local bars = {}
			local dir = gp(st, "ScrollingDirection").Name
			if canvas.h > rec.h + 0.5 and dir ~= "X" then
				local frac = rec.h / canvas.h
				local len = math.max(thick * 2, rec.h * frac)
				local pos = (rec.h - len) * (canvas.y / math.max(canvas.h - rec.h, 1))
				table.insert(bars, { x = r4(rec.w - thick), y = r4(pos), w = r4(thick), h = r4(len) })
			end
			if canvas.w > rec.w + 0.5 and dir ~= "Y" then
				local frac = rec.w / canvas.w
				local len = math.max(thick * 2, rec.w * frac)
				local pos = (rec.w - len) * (canvas.x / math.max(canvas.w - rec.w, 1))
				table.insert(bars, { x = r4(pos), y = r4(rec.h - thick), w = r4(len), h = r4(thick) })
			end
			if #bars > 0 then
				item.scrollbars = { bars = bars, color = rgba(gp(st, "ScrollBarImageColor3"), 1 - (1 - gp(st, "ScrollBarImageTransparency")) * alphaMul) }
			end
		end
	end
	if info.isA.ViewportFrame then
		vpCounter += 1
		local id = "vp" .. vpCounter
		item.viewport = id
		table.insert(ctx.viewports, { id = id, inst = obj, st = st, rect = { rec.x, rec.y, rec.w, rec.h }, alphaMul = alphaMul })
	end
	if info.isA.VideoFrame then
		item.image = { src = "video", color = { 0.3, 0.3, 0.3, 1 } }
	end
	return item
end

local function pathItem(p, st, alphaMul)
	local rec = st.x.layout
	local pts = st.x.points
	if not rec or not pts or #pts < 2 then
		return nil
	end
	local function at(u)
		return rec.x + u.X.Scale * rec.w + u.X.Offset * (rec.k or 1), rec.y + u.Y.Scale * rec.h + u.Y.Offset * (rec.k or 1)
	end
	local function off(u)
		return u.X.Scale * rec.w + u.X.Offset * (rec.k or 1), u.Y.Scale * rec.h + u.Y.Offset * (rec.k or 1)
	end
	local d = {}
	local x0, y0 = at(pts[1].Position)
	table.insert(d, string.format("M %.2f %.2f", x0, y0))
	local count = #pts
	local closed = gp(st, "Closed")
	local segments = closed and count or count - 1
	for i = 1, segments do
		local a = pts[i]
		local b = pts[i % count + 1]
		local ax, ay = at(a.Position)
		local bx, by = at(b.Position)
		local rx, ry = off(a.RightTangent)
		local lx, ly = off(b.LeftTangent)
		table.insert(d, string.format("C %.2f %.2f %.2f %.2f %.2f %.2f", ax + rx, ay + ry, bx + lx, by + ly, bx, by))
	end
	if closed then
		table.insert(d, "Z")
	end
	return {
		t = "path",
		name = st.name,
		m = round4list(rec.chain),
		w = 0,
		h = 0,
		clip = rec.clip and round4list(rec.clip) or nil,
		path = { d = table.concat(d, " "), color = rgba(gp(st, "Color3"), 1 - (1 - gp(st, "Transparency")) * alphaMul), thickness = r4(gp(st, "Thickness") * (rec.k or 1)), closed = closed },
	}
end

local function sortedChildren(st)
	local list = {}
	for i, c in ipairs(st.children) do
		local cs = states[c]
		if cs.info.isA.GuiObject or cs.info.name == "Path2D" then
			table.insert(list, { c = c, st = cs, i = i, z = gp(cs, "ZIndex") })
		end
	end
	table.sort(list, function(a, b)
		if a.z ~= b.z then
			return a.z < b.z
		end
		return a.i < b.i
	end)
	return list
end

local function emitSibling(obj, st, out, alphaMul, ctx)
	if not gp(st, "Visible") then
		return
	end
	local item
	if st.info.name == "Path2D" then
		item = pathItem(obj, st, alphaMul)
		if item then
			table.insert(out, item)
		end
		return
	end
	item = guiItem(obj, st, alphaMul, ctx)
	if not item then
		return
	end
	local target = out
	if st.info.isA.CanvasGroup then
		local group = { t = "group", name = st.name, alpha = r4(1 - gp(st, "GroupTransparency")), tint = c3(gp(st, "GroupColor3")), items = {} }
		table.insert(out, group)
		table.insert(group.items, item)
		target = group.items
	else
		table.insert(out, item)
	end
	for _, entry in ipairs(sortedChildren(st)) do
		emitSibling(entry.c, entry.st, target, alphaMul, ctx)
	end
end

local function emitGlobal(root, rootSt, out, ctx)
	local all = {}
	local order = 0
	local function gather(inst, st, alphaMul)
		for _, c in ipairs(st.children) do
			local cs = states[c]
			if (cs.info.isA.GuiObject or cs.info.name == "Path2D") and gp(cs, "Visible") then
				order += 1
				local a = alphaMul
				table.insert(all, { c = c, st = cs, z = gp(cs, "ZIndex"), o = order, a = a })
				if cs.info.isA.CanvasGroup then
					a = a * (1 - gp(cs, "GroupTransparency"))
				end
				gather(c, cs, a)
			end
		end
	end
	gather(root, rootSt, 1)
	table.sort(all, function(a, b)
		if a.z ~= b.z then
			return a.z < b.z
		end
		return a.o < b.o
	end)
	for _, e in ipairs(all) do
		local item
		if e.st.info.name == "Path2D" then
			item = pathItem(e.c, e.st, e.a)
		else
			item = guiItem(e.c, e.st, e.a, ctx)
		end
		if item then
			table.insert(out, item)
		end
	end
end

function E.gui()
	L.update(true)
	vpCounter = 0
	local ctx = { viewports = {} }
	local screens, billboards = {}, {}
	for _, root in ipairs(L.roots()) do
		local st = states[root]
		if st.info.isA.ScreenGui then
			table.insert(screens, root)
		elseif st.info.isA.BillboardGui then
			table.insert(billboards, root)
		end
	end
	table.sort(screens, function(a, b)
		local sa, sb = states[a], states[b]
		local da, db = gp(sa, "DisplayOrder"), gp(sb, "DisplayOrder")
		if da ~= db then
			return da < db
		end
		return sa.id < sb.id
	end)
	local layers = {}
	-- billboards first (they live in the 3D layer), far ones first
	table.sort(billboards, function(a, b)
		local la, lb = states[a].x.layout, states[b].x.layout
		return (la and la.depth or 0) > (lb and lb.depth or 0)
	end)
	for _, bb in ipairs(billboards) do
		local st = states[bb]
		local l = st.x.layout
		if gp(st, "Enabled") and l and not l.offscreen and l.visible then
			local items = {}
			for _, entry in ipairs(sortedChildren(st)) do
				emitSibling(entry.c, entry.st, items, 1, ctx)
			end
			table.insert(layers, { kind = "billboard", name = st.name, alwaysOnTop = gp(st, "AlwaysOnTop"), items = items })
		end
	end
	for _, sg in ipairs(screens) do
		local st = states[sg]
		if gp(st, "Enabled") then
			local items = {}
			if gp(st, "ZIndexBehavior") == Enum.ZIndexBehavior.Global then
				emitGlobal(sg, st, items, ctx)
			else
				for _, entry in ipairs(sortedChildren(st)) do
					emitSibling(entry.c, entry.st, items, 1, ctx)
				end
			end
			local l = st.x.layout or {}
			table.insert(layers, { kind = "screen", name = st.name, displayOrder = gp(st, "DisplayOrder"), rect = { r4(l.x or 0), r4(l.y or 0), r4(l.w or 0), r4(l.h or 0) }, items = items })
		end
	end
	-- viewport worlds
	local viewports = {}
	for _, vp in ipairs(ctx.viewports) do
		local st = vp.st
		local cam = gp(st, "CurrentCamera")
		local camRec = nil
		if cam and states[cam] then
			local cst = states[cam]
			camRec = { cf = cf12(gp(cst, "CFrame")), fov = r4(gp(cst, "FieldOfView")) }
		end
		local world = E.collectWorld(vp.inst)
		local imageT = gp(st, "ImageTransparency")
		table.insert(viewports, {
			id = vp.id,
			rect = round4list(vp.rect),
			camera = camRec,
			ambient = c3(gp(st, "Ambient")),
			lightColor = c3(gp(st, "LightColor")),
			lightDir = v3(gp(st, "LightDirection")),
			imageColor = c3(gp(st, "ImageColor3")),
			alpha = r4((1 - imageT) * vp.alphaMul),
			parts = world.parts,
			lights = world.lights,
		})
	end
	local d = R.options.device
	local inset = R.guiInset()
	return {
		layers = layers,
		viewports = viewports,
		safe = d.safe,
		topbar = { y = (d.topbarBelowSafeTop and d.safe.top or 0), h = d.topbar, bottom = inset.Y },
		coreGui = R.coreGui,
	}
end

------------------------------------------------------------------------------------------
-- Scene metrics shared by every scene
------------------------------------------------------------------------------------------

function E.worldCounts(root)
	local counts = { instances = 0, parts = 0, meshParts = 0, visibleParts = 0, lights = 0, shadowCasters = 0, triangles = 0, guiObjects = 0 }
	local tris = R.meshTris or {}
	R.walk(root, function(d)
		if d == root then
			return
		end
		local st = states[d]
		local info = st.info
		counts.instances += 1
		if info.isA.BasePart and not info.isA.Terrain then
			counts.parts += 1
			local t = gp(st, "Transparency")
			if t < 1 then
				counts.visibleParts += 1
				if gp(st, "CastShadow") then
					counts.shadowCasters += 1
				end
			end
			if info.isA.MeshPart then
				counts.meshParts += 1
				local ref = st.attrs and st.attrs.PreviewMeshRef
				counts.triangles += ref and (tris[ref] or 0) or 0
			elseif t < 1 then
				local shape = info.isA.Part and gp(st, "Shape").Name or "Block"
				counts.triangles += (shape == "Ball" and 288) or (shape == "Cylinder" and 64) or 12
			end
		elseif info.isA.Light then
			counts.lights += 1
		elseif info.isA.GuiObject then
			counts.guiObjects += 1
		end
	end)
	counts.triangles = math.floor(counts.triangles + 0.5)
	return counts
end

R.exporter = E
return E
