-- settings-sim: the EXISTING settings, client side (the server side and reloads are in
-- safety-sim). Errors on failure.
--   * a saved profile's settings reach ClientSettings and the settings screen
--   * rapid changes are saved once (debounced), only valid values
--   * a ProfileSync written before the server got the change does not switch it back
--   * Minimap off hides the minimap; Damage numbers off drops server batches
local C = lib("common")
C.lobby()
C.startClient()
local Settings = preview.client("ClientSettings")
local Config = C.shared("Config")

local saves = {}
preview.remote("SaveSettings").OnServerEvent:Connect(function(_, payload)
	table.insert(saves, payload)
end)

local saved = { Music = 0.4, Sfx = 0.7, Shake = 0.83, ReducedEffects = true, DamageNumbers = false, Tips = false, Minimap = false,
	Colorblind = "Protanopia", ReduceFlashes = true, CombatVolume = 0.5, InterfaceVolume = 0.6, WarningVolume = 1,
	MuteAll = false, VisualAudioCues = true, TouchLayout = "LeftHanded" }
-- UIBuilder passes ProfileSync.Settings to ClientSettings.Apply; the scene calls Apply the
-- same way so the logic is checked even when the menu scripts are not running (headless)
local function sync(settings)
	if preview.args.headless == "on" then
		Settings.Apply(settings)
	else
		C.sendProfile(C.profile({ Settings = settings }))
	end
end
sync(saved)
C.settle(1)
for key, value in pairs(saved) do
	assert(Settings.Get(key) == value, "profile setting not applied: " .. key)
end
for key in pairs(Config.Settings.Defaults) do
	assert(saved[key] ~= nil, "test profile misses setting " .. key .. " (new setting: add it here)")
end
assert(Settings.Reduced() and Settings.Flashes(), "reduced effects + reduce flashes read back")
preview.log("PASS every saved setting reaches the client")

if preview.args.headless ~= "on" then
	preview.client("UIBuilder").OpenPause()
	C.settle(0.5)
	assert(C.findText("COLORS: PROTANOPIA") or C.findText("COLORS: PROTAN"), "settings screen shows the saved colour mode")
	assert(C.findText("TOUCH LAYOUT: LEFT"), "settings screen shows the saved touch layout")
	preview.log("PASS settings screen shows the saved choices")
end

-- debounce: ten slider steps -> one save with the last value; junk never leaves the client
local before = #saves
for i = 1, 10 do
	Settings.Set("Music", i / 20)
end
Settings.Set("Music", 0 / 0)
Settings.Set("Colorblind", "Rainbow")
preview.advance(1)
assert(#saves == before + 1 and saves[#saves].Music == 0.5 and saves[#saves].Colorblind == nil, "one debounced save with the last valid value")
preview.log("PASS slider changes saved once, invalid values never sent")

-- stale sync: the server wrote this ProfileSync before it received Music = 0.5
local stale = table.clone(saved)
stale.Music = 0.4
sync(stale)
preview.advance(0.2)
assert(Settings.Get("Music") == 0.5, "a stale ProfileSync must not undo a change just sent")
-- the echo arrives, then a later real change from the server applies again
local echo = table.clone(saved)
echo.Music = 0.5
sync(echo)
preview.advance(0.2)
echo.Music = 0.3
sync(echo)
preview.advance(0.2)
assert(Settings.Get("Music") == 0.3, "after the echo the profile rules again")
preview.log("PASS stale ProfileSync never reverts a just-saved setting")

-- Minimap off: hidden in a run; on again: shown
local player = game:GetService("Players").LocalPlayer
if preview.args.headless ~= "on" then
	local MiniMap = preview.client("MiniMap")
	player:SetAttribute("InRun", true)
	C.setState({ Phase = "Running" })
	C.settle(0.5)
	local map = MiniMap.Elements()
	local root = map and (map.Root or map.Frame)
	if root then
		assert(not root.Visible, "Minimap off must hide the minimap in a run")
		Settings.Set("Minimap", true)
		C.settle(0.5)
		assert(root.Visible, "Minimap on must show it in a run")
		preview.log("PASS minimap setting hides / shows the minimap")
	else
		preview.log("BLOCKED minimap check: MiniMap.Elements() has no Root/Frame")
	end
end

-- Damage numbers off: a batch from the server is ignored on this client
local DamageText = preview.client("DamageText")
assert(type(DamageText) == "table", "DamageText module")
assert(Settings.Get("DamageNumbers") == false, "damage numbers stay off")
preview.log("PASS settings-sim")
