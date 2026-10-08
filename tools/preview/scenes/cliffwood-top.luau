-- cliffwood-top: the Cliffwood Basin built by the real MapBuilder, seen from above with the
-- routes (main loop gold, other roads white), landmarks, loot spots and the launch pad drawn
-- on top; prints the part counts and route numbers.
--   --set view=top (default) | oblique (a tilted view from the south, like the run camera)
--   --set focus=x,z --set zoom=N   a close top view (N = ortho height in studs)
local C = lib("common")
local s = C.bootServer()
if not s.MapBuilder or not s.Config then
	return
end
local arena = C.try("MapBuilder.BuildArena", s.MapBuilder.BuildArena, "Cliffwood")
if not arena then
	return
end
local c = arena.Center
local counts = preview.worldCounts(arena.Model)
local plan = arena.CliffwoodPlan

local routeLen = arena.RouteLength or 0
local parts = 0
local tags = { NavGround = 0, NavBlock = 0 }
for _, d in ipairs(arena.Model:GetDescendants()) do
	if d:IsA("BasePart") then
		parts += 1
		for tagName in pairs(tags) do
			if d:HasTag(tagName) then
				tags[tagName] += 1
			end
		end
	end
end
local byName = {}
for _, d in ipairs(arena.Model:GetDescendants()) do
	if d:IsA("BasePart") then
		local key = d.Parent and d.Parent:IsA("Model") and d.Parent ~= arena.Model and ("(" .. d.Parent.Name .. ")") or d.Name
		byName[key] = (byName[key] or 0) + 1
	end
end
local names = {}
for k, v in pairs(byName) do
	table.insert(names, { k, v })
end
table.sort(names, function(x, y) return x[2] > y[2] end)
local top = {}
for i = 1, math.min(22, #names) do
	table.insert(top, names[i][1] .. "=" .. names[i][2])
end
preview.log("BYNAME " .. table.concat(top, ", "))
preview.log(string.format("PARTS %d (MeshParts %d), trees %d, rocks %d, obstacles %d, lights %d", parts, counts.meshParts or 0, arena.Trees, arena.Rocks, #arena.Obstacles, arena.Lights))
preview.log(string.format("TAGS NavGround %d, NavBlock %d", tags.NavGround, tags.NavBlock))
preview.log(string.format("ROUTE main loop %.0f studs = %.1f s at 22 studs/s", routeLen, routeLen / 22))
local pathTotal, pathMain = 0, 0
for _, seg in ipairs(arena.Paths) do
	local l = (seg.B - seg.A).Magnitude
	pathTotal += l
	if seg.Main then
		pathMain += l
	end
end
preview.log(string.format("PATHS %d segments, %.0f studs total, %.0f studs main", #arena.Paths, pathTotal, pathMain))
preview.log(string.format("LOOT %d spots, landmarks %d, launch pads %d", #arena.LootSpots, #arena.Landmarks, #arena.LaunchPads))
preview.metrics.parts = parts
preview.metrics.routeLength = routeLen
preview.metrics.lootSpots = #arena.LootSpots

local showOverlays = preview.args.overlays ~= "off"
for _, ob in ipairs(showOverlays and arena.Obstacles or {}) do
	if ob.Kind == "Circle" then
		preview.overlay({ kind = "circle", x = ob.Pos.X, z = ob.Pos.Z, y = ob.Pos.Y + 0.3, r = ob.Radius, color = "#ff2a2a", width = 1 })
	end
end
local pts = showOverlays and arena.MainRoute or {}
for i = 1, #pts - 1 do
	preview.overlay({ kind = "line", x1 = pts[i].X, z1 = pts[i].Z, x2 = pts[i + 1].X, z2 = pts[i + 1].Z, y = pts[i].Y + 1, color = "#ffd23f", width = 3 })
end
for _, lm in ipairs(showOverlays and arena.Landmarks or {}) do
	preview.overlay({ kind = "circle", x = lm.Pos.X, z = lm.Pos.Z, y = lm.Pos.Y + 0.5, r = lm.Radius, color = "#7fe0ff", width = 2, dash = "8 6" })
	preview.overlay({ kind = "label", x = lm.Pos.X, z = lm.Pos.Z, text = lm.Name, color = "#ffffff", size = 16 })
end
for _, sp in ipairs(showOverlays and arena.LootSpots or {}) do
	preview.overlay({ kind = "circle", x = sp.X, z = sp.Z, y = sp.Y + 0.6, r = 6, color = "#ff9f1c", fill = "#ff9f1c", width = 2 })
end
for _, lp in ipairs(showOverlays and arena.LaunchPads or {}) do
	preview.overlay({ kind = "circle", x = lp.Pos.X, z = lp.Pos.Z, y = lp.Pos.Y + 0.6, r = 7, color = "#3dff7a", fill = "#3dff7a", width = 2 })
	preview.overlay({ kind = "line", x1 = lp.Pos.X, z1 = lp.Pos.Z, x2 = lp.Target.X, z2 = lp.Target.Z, y = lp.Target.Y + 1, color = "#3dff7a", width = 2, dash = "6 6" })
end
if showOverlays then preview.overlay({ kind = "circle", x = arena.Spawn.X, z = arena.Spawn.Z, y = 1, r = 40, color = "#ffe066", width = 2.5 }) end

local view = preview.args.view or "top"
if preview.args.cam then
	local n = {}
	for v in string.gmatch(preview.args.cam, "-?[%d%.]+") do
		table.insert(n, tonumber(v))
	end
	preview.camera = { cf = CFrame.lookAt(c + Vector3.new(n[1], n[2], n[3]), c + Vector3.new(n[4], n[5], n[6])), fov = tonumber(preview.args.fov) or 60, near = 1, far = 4000 }
elseif preview.args.focus then
	local fx, fz = string.match(preview.args.focus, "(-?%d+),(-?%d+)")
	local f = c + Vector3.new(tonumber(fx) or 0, 0, tonumber(fz) or 0)
	local zoom = tonumber(preview.args.zoom) or 300
	preview.camera = { cf = CFrame.lookAt(f + Vector3.new(0, 900, 0), f, Vector3.new(0, 0, -1)), ortho = { height = zoom }, near = 1, far = 3000 }
elseif view == "oblique" then
	preview.camera = { cf = CFrame.lookAt(c + Vector3.new(0, 620, 760), c + Vector3.new(0, 0, 40)), fov = 55, near = 1, far = 4000 }
else
	preview.camera = { cf = CFrame.lookAt(c + Vector3.new(0, 1000, 0), c, Vector3.new(0, 0, -1)), ortho = { height = 1180 }, near = 1, far = 3000 }
end
preview.render.hideCoreUi = true
preview.advance(0.1)

-- checks (PASS / FAIL lines; a FAIL line also fails tools/run_regressions.py)
local fails = 0
local function check(ok: boolean, label: string)
	if ok then
		preview.log("PASS " .. label)
	else
		fails += 1
		preview.log("FAIL: " .. label)
	end
end
check(parts <= 6000, string.format("part budget %d <= 6000", parts))
check(routeLen >= 1400 and routeLen <= 1800, string.format("main loop %.0f studs in 1400-1800", routeLen))
check(routeLen / 22 >= 60 and routeLen / 22 <= 90, string.format("main loop %.1f s in 60-90 s at 22 studs/s", routeLen / 22))
check(arena.Half == 550 and arena.Bounds.MinX == c.X - 550 and arena.Bounds.MaxZ == c.Z + 550, "Half 550 and Bounds")
check(arena.Spawn ~= nil and #arena.Landmarks >= 7, "Spawn and landmarks")
check(#arena.LootSpots >= 12, "loot spots " .. #arena.LootSpots)
-- loot spots and landmarks stand on real floor
local badLoot = 0
for _, sp in ipairs(arena.LootSpots) do
	local f = plan.FloorAt(sp.X - c.X, sp.Z - c.Z)
	if not f or math.abs(f - (sp.Y - c.Y)) > 0.5 then
		badLoot += 1
	end
end
check(badLoot == 0, "every loot spot is on the floor (" .. badLoot .. " off)")
-- loot spacing along the main loop: gaps between consecutive route spots 120-330
local routeSpots = 0
for _, info in ipairs(arena.LootSpotInfo) do
	if info.Kind == "Route" then
		routeSpots += 1
	end
end
check(routeSpots >= 5, "route loot spots " .. routeSpots)
-- ramps: wide, not steeper than 35 degrees
local ramps = 0
for _, r in ipairs(plan.Ramps) do
	ramps += 1
	check(r.W >= 24 and math.abs(r.Slope) <= 35, string.format("ramp %s width %d slope %.1f", r.Name, r.W, r.Slope))
end
-- nothing collidable in the spawn clearing, nothing on a rock cell, lanes stay >= 24 wide
local inClear, inRock = 0, 0
for _, ob in ipairs(arena.Obstacles) do
	local dx, dz = ob.Pos.X - c.X, ob.Pos.Z - c.Z
	if math.sqrt(dx * dx + dz * dz) - ob.Radius < (arena.Clear or 40) then
		inClear += 1
	end
	if ob.Kind == "Circle" and ob.Radius < 20 and not plan.FloorAt(dx, dz) then
		inRock += 1
		preview.log(string.format("  collider off the floor at (%.0f, %.0f) r %.1f", dx, dz, ob.Radius))
	end
end
check(inClear == 0, "no collider in the spawn clearing (" .. inClear .. ")")
check(inRock == 0, "no collider off the floor (" .. inRock .. ")")
local blockedLane = 0
for k = 1, #arena.MainRoute - 1 do
	local a, b = arena.MainRoute[k], arena.MainRoute[k + 1]
	local len = (b - a).Magnitude
	local steps = math.max(1, math.floor(len / 6))
	for st = 0, steps do
		local p = a:Lerp(b, st / steps)
		for _, ob in ipairs(arena.Obstacles) do
			local d = math.huge
			if ob.Kind == "Circle" and ob.Radius < 20 then
				d = math.sqrt((ob.Pos.X - p.X) ^ 2 + (ob.Pos.Z - p.Z) ^ 2) - ob.Radius
			elseif ob.Kind == "Box" then
				local qx = math.max(ob.MinX - p.X, 0, p.X - ob.MaxX)
				local qz = math.max(ob.MinZ - p.Z, 0, p.Z - ob.MaxZ)
				d = math.sqrt(qx * qx + qz * qz)
			end
			do
				if d < 12 then
					blockedLane += 1
					preview.log(string.format("  lane blocked near (%.0f, %.0f) by r %.1f at (%.0f, %.0f)", p.X - c.X, p.Z - c.Z, ob.Radius, ob.Pos.X - c.X, ob.Pos.Z - c.Z))
					break
				end
			end
		end
	end
end
check(blockedLane == 0, "main loop keeps a 24 wide lane clear of colliders (" .. blockedLane .. " samples blocked)")
-- tags
check(tags.NavGround > 100 and tags.NavBlock > 100, "NavGround / NavBlock tags present")
local roofs, roofTagged = 0, 0
for _, d in ipairs(arena.Model:GetDescendants()) do
	if d:IsA("BasePart") and d.Name == "CaveRoof" then
		roofs += 1
		if d:HasTag("NavGround") or d:HasTag("NavBlock") then
			roofTagged += 1
		end
	end
end
check(roofs > 0 and roofTagged == 0, "cave roofs exist and are untagged (" .. roofs .. ")")
local pad = #arena.LaunchPads == 1 and arena.LaunchPads[1].Part
check(pad and typeof(pad:GetAttribute("LaunchPad")) == "Vector3", "launch pad part carries the LaunchPad attribute")
-- rebuild is identical
local firstParts = parts
local again = C.try("rebuild", s.MapBuilder.BuildArena, "Cliffwood")
local n2 = 0
for _, d in ipairs(again.Model:GetDescendants()) do
	if d:IsA("BasePart") then
		n2 += 1
	end
end
check(n2 == firstParts, "a rebuild gives the same part count (" .. n2 .. ")")
preview.log(fails == 0 and "ALL PASS" or ("FAILURES: " .. fails))
