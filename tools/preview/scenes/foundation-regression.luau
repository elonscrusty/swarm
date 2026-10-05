-- foundation-regression: the 30-features groundwork (docs/features/FOUNDATION.md).
--   1) EncounterDirector lifecycle on a real arena: StageStart / Step / StageEnd, the
--      MaxActive / MaxAmbient caps, FindSpot spacing from the portal, the loot and each
--      other, cleanup on travel and run end, a switched-off feature is never started,
--      one throwing feature never stops the others, PlayerOut reaches the running ones
--   2) nothing registered = the director does nothing (the game as before)
-- Every check errors on failure.
local C = lib("common")
local s = C.bootServer()
local Config = s.Config
local Loot = C.server("LootSystem")
local Caravan = C.server("CaravanEvent")
local ED = C.server("EncounterDirector")
local ctx = { RunManager = { GetRunPlayers = function() return {} end }, CaravanEvent = Caravan, LootSystem = Loot }
Loot.Init(ctx)
Caravan.Init(ctx)
ED.Init(ctx)

-- 2) empty director
local arena = s.MapBuilder.BuildArena("Forest", 0)
local portal = s.Config.ArenaOrigin + Vector3.new(120, 0, 0)
Loot.BuildStage(arena, 1, portal)
ED.StageStart(arena, 1, portal, "Forest")
assert(ED.ActiveCount() == 0 and ED.ActiveCount(true) == 0, "nothing registered: nothing runs")
ED.Step(0.1)
ED.StageEnd("Travel")
assert(ED.Stage() == nil, "stage closed")

-- 1) fake encounters
local log = {}
local function make(name, feature, ambient, opts)
	opts = opts or {}
	log[name] = { Start = 0, Tick = 0, End = 0, Clean = 0, Out = 0, Spot = nil }
	ED.Register(name, {
		Feature = feature,
		Ambient = ambient,
		OnStageStart = function(info)
			log[name].Start += 1
			if opts.Throw then error("boom") end
			if not ambient then
				log[name].Spot = ED.FindSpot(name)
				return log[name].Spot ~= nil
			end
			return true
		end,
		OnTick = function() log[name].Tick += 1 end,
		OnStageEnd = function() log[name].End += 1 end,
		OnCleanup = function() log[name].Clean += 1 end,
		OnPlayerOut = function() log[name].Out += 1 end,
	})
end
make("A", "Merchant", false)
make("B", "Rescue", false)
make("Cc", "MiniBosses", false)
make("W1", "Weather", true)
make("W2", "MapEvents", true)
make("Bad", "SecretRooms", false, { Throw = true })
make("Off", "TrialShrine", false)
Config.Features.TrialShrine = false

local D = Config.Encounters.Director
for stage = 1, 6 do
	local a = s.MapBuilder.BuildArena(Config.Arenas.Order[(stage - 1) % #Config.Arenas.Order + 1], stage % 3)
	Loot.BuildStage(a, stage, portal)
	ED.StageStart(a, stage, portal, "x")
	assert(ED.ActiveCount() <= D.MaxActive, "placed cap")
	assert(ED.ActiveCount(true) <= D.MaxAmbient, "ambient cap")
	assert(ED.ActiveCount(true) == 1, "one ambient runs")
	assert(ED.ActiveCount() >= 1, "at least one placed encounter runs")
	assert(not ED.IsActive("Off") and log.Off.Start == 0, "a switched-off feature never starts")
	assert(not ED.IsActive("Bad"), "a throwing feature is not active")
	-- spacing: every reserved spot away from the portal, the loot and the other spots
	local spots = ED.Reserved()
	for i, r in ipairs(spots) do
		local flat = Vector3.new(1, 0, 1)
		assert(((r.Pos - portal) * flat).Magnitude >= Config.Chests.PortalClearance, "spot clear of the portal")
		for j, o in ipairs(spots) do
			if i ~= j then
				assert(((r.Pos - o.Pos) * flat).Magnitude >= D.Spacing * 0.35 - 0.01, "spots apart")
			end
		end
		for _, obj in ipairs(Loot.Objects()) do
			assert(((r.Pos - obj.Pos) * flat).Magnitude >= D.Spacing * 0.35 - 0.01, "spot clear of loot")
		end
	end
	ED.Step(0.1)
	ED.PlayerOut({}, "Death")
	-- a mid-stage Begin respects the cap
	local before = ED.ActiveCount()
	local begun = ED.Begin("Cc")
	assert(ED.ActiveCount() <= D.MaxActive, "Begin respects the cap")
	if begun and before < D.MaxActive then ED.Finish("Cc") end
	ED.StageEnd(stage % 2 == 0 and "Travel" or "RunEnd")
	assert(ED.ActiveCount() == 0 and ED.ActiveCount(true) == 0 and #ED.Reserved() == 0, "stage end clears everything")
	Loot.Clear()
end
for _, name in ipairs({ "A", "B", "Cc", "W1", "W2", "Bad", "Off" }) do
	assert(log[name].Clean == 6, name .. " cleaned up every stage (" .. log[name].Clean .. ")")
end
assert(log.Off.Tick == 0 and log.Off.Out == 0, "a switched-off feature gets no ticks")
assert(log.A.Tick == 6 and log.W1.Tick == 6, "enabled features tick")
assert(log.A.End + log.B.End + log.Cc.End >= 6, "running encounters got OnStageEnd")
-- every feature off: the director starts nothing
for k in pairs(Config.Features) do Config.Features[k] = false end
local a = s.MapBuilder.BuildArena("Forest", 1)
ED.StageStart(a, 1, portal, "Forest")
assert(ED.ActiveCount() == 0 and ED.ActiveCount(true) == 0, "all flags off: nothing starts")
ED.StageEnd("RunEnd")
for k in pairs(Config.Features) do Config.Features[k] = true end
for _, name in ipairs(ED.Registered()) do ED.Unregister(name) end
assert(#ED.Registered() == 0, "unregistered")
preview.log("PASS foundation-regression: director caps, spacing, cleanup on travel / run end, flags off, error isolation")
