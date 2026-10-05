-- perf-regression: the HUD's stage caption ("FOREST · STAGE 2 · WAVE 3") measures its width
-- (AbsoluteSize, which forces a GUI layout pass while the GUI is dirty) only on the few
-- frames after the caption, UI scale or panel room changed, not every frame (audit PERF-01:
-- 66 forced layouts in 66 frames before). A caption too wide for the panel still drops the
-- arena name. GUI layout runs on demand only (like perf-sim), so every AbsoluteSize read on a
-- dirty GUI is counted by preview.forcedLayouts(). Prints PASS / FAIL lines.
local A = lib("arena")
local C = lib("common")
A.build({ enemies = 10, seconds = 120, stage = 2 })
C.settle(2)
preview.setFrameLayout(false)
local Hud = preview.client("Hud")
local fails = 0
local function check(ok: boolean, label: string)
	if not ok then
		fails += 1
	end
	preview.log((ok and "PASS " or "FAIL ") .. label)
end
local function hudLayouts(): number
	local n = 0
	for k, v in pairs(preview.forcedLayouts()) do
		if string.find(k, "Hud.lua", 1, true) then
			n += v
		end
	end
	return n
end

local ui = Hud.Elements()
local where = ui.StageNumber
check(where ~= nil and preview.isShown(where) and string.find(where.Text, "STAGE 2", 1, true) ~= nil,
	"stage caption shown: " .. tostring(where and where.Text))

-- a steady caption: 5 s at 60 fps (300 HUD updates)
preview.forcedLayouts(true)
preview.advance(5, 60)
local steady = hudLayouts()
check(steady <= 12, string.format("steady caption: %d forced HUD layouts in 300 frames (was one per frame)", steady))

-- the caption changes: measured again on the next frames, and a caption too wide for the
-- panel drops the arena name
local Config = preview.shared("Config")
local state = C.state()
local arenaId = tostring(state:GetAttribute("Arena"))
local arena = (Config.Arenas :: any)[arenaId]
if type(arena) == "table" then
	local old = arena.DisplayName
	arena.DisplayName = string.rep("Very Long Arena Name ", 4)
	C.setState({ Wave = 7 }) -- any caption change
	preview.advance(0.5, 60)
	check(not string.find(where.Text, "VERY LONG", 1, true) and string.find(where.Text, "STAGE 2", 1, true) ~= nil,
		"too-wide caption drops the arena name: " .. where.Text)
	arena.DisplayName = old
else
	check(false, "arena " .. arenaId .. " has a Config.Arenas entry")
end
preview.forcedLayouts(true)
preview.advance(3, 60)
local after = hudLayouts()
check(after <= 8, string.format("after the drop: %d forced HUD layouts in 180 frames", after))
preview.log(fails == 0 and "PASS perf-regression" or ("FAIL perf-regression (" .. fails .. ")"))
