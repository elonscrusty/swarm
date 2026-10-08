-- cliffwood_metrics: prints the Cliffwood Basin layout (ASCII map) and its route numbers.
-- run: /tmp/sh-tools/lune/lune run tools/cliffwood_metrics.luau [map]
local process = require("@lune/process")
local Layout = require("../src/server/Modules/CliffwoodLayout")

local plan = Layout.Plan()
local N = plan.N

local counts = { rock = 0, walk = 0, ramp = 0, cave = 0, void = 0 }
for i = 1, N do
	for j = 1, N do
		counts[plan.Kind[i][j]] += 1
	end
end
print(string.format("cells: rock %d, walk %d, ramp %d, cave %d, void %d (of %d)", counts.rock, counts.walk, counts.ramp, counts.cave, counts.void, N * N))

if table.find(process.args, "map") then
	local chars = { [0] = ".", [14] = "r", [30] = "T", [36] = "O", [9] = "a", [19] = "b" }
	for j = 1, N do
		local row = {}
		for i = 1, N do
			local k = plan.Kind[i][j]
			local c = "#"
			if k == "walk" then
				c = chars[plan.T[i][j]] or "+"
			elseif k == "ramp" then
				c = "/"
			elseif k == "cave" then
				c = "c"
			elseif k == "void" then
				c = "~"
			end
			table.insert(row, c)
		end
		print(table.concat(row))
	end
end

local route, len = Layout.MainLoop(plan)
print(string.format("main loop: %d points, %.0f studs, %.1f s at %d studs/s", #route, len, len / Layout.WALK_SPEED, Layout.WALK_SPEED))
local all = Layout.Paths(plan)
local total, main = 0, 0
for _, seg in ipairs(all) do
	local l = math.sqrt((seg.B[1] - seg.A[1]) ^ 2 + (seg.B[2] - seg.A[2]) ^ 2)
	total += l
	if seg.Main then
		main += l
	end
end
print(string.format("paths: %d segments, %.0f studs in total, %.0f studs on the main loop", #all, total, main))
for _, r in ipairs(plan.Ramps) do
	print(string.format("ramp %-14s len %.0f rise %.0f slope %.1f deg width %d", r.Name, r.Len, r.Rise, r.Slope, r.W))
end
-- every clearing centre and every main-loop point must be open floor at the right height
local bad = 0
for _, c in ipairs(Layout.Clearings) do
	local f = plan.FloorAt(c.X, c.Z)
	if f ~= c.Y then
		bad += 1
		print("BAD clearing " .. c.Name, f)
	end
end
for _, p in ipairs(route) do
	local f = plan.FloorAt(p[1], p[2])
	if not f or math.abs(f - p[3]) > 1.6 then
		bad += 1
		print(string.format("BAD route point (%.0f, %.0f) y %.1f floor %s", p[1], p[2], p[3], tostring(f)))
	end
end
print("route check: " .. (bad == 0 and "PASS" or ("FAIL " .. bad)))
