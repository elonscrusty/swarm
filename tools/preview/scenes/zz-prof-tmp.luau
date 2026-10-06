local A = lib("arena")
local C = lib("common")
A.build({ enemies = 10, seconds = 120, stage = 2 })
C.settle(1)
preview.setFrameLayout(false)
preview.profile(true)
preview.forcedLayouts(true)
local t0 = os.clock()
preview.advance(0.25, 60)
preview.log(string.format("wall %.2fs for 120 frames", os.clock() - t0))
for k, v in pairs(preview.forcedLayouts()) do preview.log("forced", k, v) end
local rep = preview.profileReport()
preview.profile(false)
local rows = {}
for k, v in pairs(rep.time) do
	table.insert(rows, { k, v.excl, v.calls })
end
table.sort(rows, function(a, b) return a[2] > b[2] end)
for i = 1, math.min(30, #rows) do
	preview.log(string.format("%-60s %8.3fs %6d", rows[i][1], rows[i][2], rows[i][3]))
end
local cs = {}
for k, v in pairs(rep.counters) do table.insert(cs, { k, v }) end
table.sort(cs, function(a, b) return a[2] > b[2] end)
for i = 1, math.min(10, #cs) do preview.log("counter", cs[i][1], cs[i][2]) end
local ps = {}
for k, v in pairs(rep.props) do table.insert(ps, { k, v }) end
table.sort(ps, function(a, b) return a[2] > b[2] end)
for i = 1, math.min(15, #ps) do preview.log("prop", ps[i][1], ps[i][2]) end
preview.log("created", rep.created, "destroyed", rep.destroyed)
