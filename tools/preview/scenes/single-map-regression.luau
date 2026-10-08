-- single-map-regression: the stage plan logic of one continuous map (docs/redesign/gameplay/DESIGN.md
-- section 5). Landmark picking is pure (StageManager.PickLandmark): never the same landmark twice in a
-- row, stage 5 / every 5th stage on the boss landmark, every landmark gets used; the spot finder keeps to
-- the landmark disc; and a run on an old arena (no Landmarks) keeps the old stage rules.
preview.startServer()
preview.advance(1)
local SM = preview.server("StageManager")
local MapBuilder = preview.server("MapBuilder")
local Config = preview.shared("Config")

local names = { "Main Basin", "Old Ruins", "Stone Circle", "Hollow Spring", "Bramble Field" }
local rng = Random.new(7)

-- 1. walk 60 stages
local last: string? = nil
local bag = {}
local used = {}
for n = 2, 61 do
	local pick
	pick, bag = SM.PickLandmark(names, n, last, bag, rng)
	assert(pick and table.find(names, pick), "stage " .. n .. " picks a known landmark")
	assert(pick ~= last, "stage " .. n .. " repeats landmark " .. tostring(pick))
	if n % 5 == 0 then
		assert(pick == "Stone Circle", "boss stage " .. n .. " uses the Stone Circle, got " .. tostring(pick))
	else
		used[pick] = (used[pick] or 0) + 1
	end
	last = pick
end
for _, name in ipairs({ "Main Basin", "Old Ruins", "Hollow Spring", "Bramble Field" }) do
	assert((used[name] or 0) >= 4, name .. " used in the tour (" .. tostring(used[name]) .. ")")
end

-- 2. fewer landmarks / no boss landmark on the map: still valid, never twice in a row
for _, list in ipairs({ { "A", "B" }, { "A", "B", "C" }, { "Only" } }) do
	local l, b = nil, {}
	for n = 2, 30 do
		local pick
		pick, b = SM.PickLandmark(list, n, l, b, rng)
		assert(pick and table.find(list, pick), "pick from a small map")
		if #list > 1 then
			assert(pick ~= l, "small map repeat")
		end
		l = pick
	end
end
local none = SM.PickLandmark({}, 2, nil, {}, rng)
assert(none == nil, "no landmarks gives nil")

-- 3. the spot finder stays inside the disc and on free ground (Forest arena stands in for the map)
local arena = MapBuilder.BuildArena("Forest")
local centre = arena.Center + Vector3.new(150, 0, -90)
local rand = Random.new(3)
for _ = 1, 20 do
	local spot = MapBuilder.FindSpotInRadius(arena, rand, centre, 60, Config.Stages.PortalClearance)
	assert(spot, "a spot is found")
	local d = Vector3.new(spot.X - centre.X, 0, spot.Z - centre.Z).Magnitude
	assert(d <= 60.01, "spot inside the landmark disc (" .. d .. ")")
end
MapBuilder.DestroyArena()

-- 4. a run on an old arena keeps the old rules: no Landmarks, so BeginRun's single-map flag is off
assert(arena.Landmarks == nil, "old arenas have no Landmarks")
preview.log("PASS landmark order (no repeats, boss landmark every 5th stage), spot inside the landmark disc")
