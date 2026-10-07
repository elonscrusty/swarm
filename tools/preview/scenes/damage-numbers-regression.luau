-- damage-numbers-regression: the damage number options (shared DamageNumberView, client
-- DamageText + DamageOptionsUI; Config.Features.DamageNumberOptions, docs/next/DAMAGE_NUMBERS.md).
--   1) the rules: Off / Small / Normal / Big, Normal = the old look (18 / 22 px), the cycle order,
--      the merge window (0.3 s combined, none when off), crit star + bold
--   2) floating numbers: each size changes the label size; crits stay distinct (star, bold,
--      gold, bigger) at every size, Small included
--   3) label count (a fight of 16 enemies hit 8 times a second for 3 s, virtual clock):
--      Off creates none, Combine on makes far fewer labels than Combine off
--   4) the settings persist: valid values accepted, junk refused, a saved profile restores them
--   5) the Settings screen: the new rows exist, tapping cycles Off > Small > Normal > Big > Off
--      and the toggle flips Combine numbers (the final frame is that screen, for check_layout)
--   6) the switch off: the old toggle row, old merge window, old crit "!" and sizes
-- PASS / FAIL lines; any FAIL fails the regression. The perf figures are logged as NUMBERS lines.
local C = lib("common")
C.lobby()
C.startClient()
C.sendProfile()
C.settle(1)

local Config = C.shared("Config")
local View = C.shared("DamageNumberView")
local Settings = preview.client("ClientSettings")
local DamageText = preview.client("DamageText")
local fails = 0
local function check(ok: boolean, label: string)
	if not ok then
		fails += 1
	end
	preview.log((ok and "PASS " or "FAIL ") .. label)
end

------------------------------------------------------------------------------------------
-- 1) the rules
------------------------------------------------------------------------------------------
local O = Config.DamageNumberOptions
check(View.Mode({ DamageNumbers = false, DamageNumberSize = "Big" }) == "Off", "DamageNumbers off reads as Off whatever the size")
check(View.Mode({ DamageNumbers = true, DamageNumberSize = "Small" }) == "Small" and View.Mode({ DamageNumbers = true, DamageNumberSize = "Big" }) == "Big", "on + size reads as that size")
check(View.Mode({ DamageNumbers = true, DamageNumberSize = "Huge" }) == "Normal" and View.Mode({ DamageNumbers = true }) == "Normal", "an unknown or missing size reads as Normal")
check(Config.Settings.Defaults.DamageNumbers == false and Config.Settings.Defaults.DamageNumberSize == "Normal" and Config.Settings.Defaults.CombineNumbers == true, "defaults: Off (as before), size Normal, Combine on")
check(View.TextSize("Normal", false) == 18 and View.TextSize("Normal", true) == 22, "Normal is the old look: 18 px, crits 22 px")
check(View.TextSize("Small", false) < View.TextSize("Normal", false) and View.TextSize("Normal", false) < View.TextSize("Big", false), "Small < Normal < Big for a plain hit")
check(View.TextSize("Small", true) < View.TextSize("Normal", true) and View.TextSize("Normal", true) < View.TextSize("Big", true), "Small < Normal < Big for a crit")
local critBigger = true
for _, mode in ipairs({ "Small", "Normal", "Big" }) do
	critBigger = critBigger and View.TextSize(mode, true) > View.TextSize(mode, false)
end
check(critBigger, "a crit is bigger than a plain hit at every size")
local order, mode = {}, "Off"
for _ = 1, 5 do
	table.insert(order, mode)
	mode = View.Next(mode)
end
check(table.concat(order, ",") == "Off,Small,Normal,Big,Off", "the row cycles Off > Small > Normal > Big > Off (" .. table.concat(order, ",") .. ")")
check(View.Apply("Off").DamageNumbers == false and View.Apply("Off").DamageNumberSize == nil, "choosing Off only switches the numbers off (the size is remembered)")
check(View.Apply("Big").DamageNumbers == true and View.Apply("Big").DamageNumberSize == "Big" and View.Apply("Nope") == nil, "choosing a size switches the numbers on at that size")
check(View.MergeWindow({ CombineNumbers = true }) == 0.3 and View.MergeWindow({}) == 0.3 and View.MergeWindow({ CombineNumbers = false }) == 0, "Combine on merges within 0.3 s, off never")
check(string.sub(View.Text(123, true), 1, #O.CritMark) == O.CritMark and View.Text(123, false) == "123" and View.CritBold(), "a crit starts with the star and is bold; a plain hit is just the number")

------------------------------------------------------------------------------------------
-- 2) floating numbers
------------------------------------------------------------------------------------------
DamageText._Manual(true)
DamageText._SetPosition(function(id)
	return Vector3.new(id * 3, 3, 0)
end)
local T0 = 1000
local function clean()
	DamageText.Clear()
	DamageText.ResetDebug()
end
local function setSettings(on: boolean, size: string, combine: boolean)
	Settings.Apply({ DamageNumbers = on, DamageNumberSize = size, CombineNumbers = combine })
end
-- one plain hit on enemy 1, a crit on enemy 2; read them 0.3 s later (after the pop settled)
local function look(size: string)
	clean()
	setSettings(true, size, true)
	DamageText._Feed({ 1, 120, 0, 2, 450, 1 }, T0)
	DamageText._Step(T0)
	DamageText._Step(T0 + 0.3)
	local plain, crit
	for _, n in ipairs(DamageText.Shown()) do
		if n.Crit then
			crit = n
		else
			plain = n
		end
	end
	return plain, crit
end
local sizes = {}
local critsOk = true
for _, size in ipairs({ "Small", "Normal", "Big" }) do
	local plain, crit = look(size)
	sizes[size] = plain and plain.Size or -1
	local ok = plain ~= nil and crit ~= nil and plain.Size == View.TextSize(size, false) and crit.Size == View.TextSize(size, true)
	ok = ok and crit.Bold and not plain.Bold and string.sub(crit.Text, 1, #O.CritMark) == O.CritMark and string.find(plain.Text, O.CritMark, 1, true) == nil
	critsOk = critsOk and ok
	check(ok, size .. ": plain " .. tostring(plain and plain.Size) .. " px, crit " .. tostring(crit and crit.Size) .. " px, bold + star on the crit only")
end
check(sizes.Small < sizes.Normal and sizes.Normal < sizes.Big and sizes.Normal == 18, "each size changes the label size (" .. sizes.Small .. " / " .. sizes.Normal .. " / " .. sizes.Big .. ")")
check(critsOk, "crits stay distinct at every size, Small included")

------------------------------------------------------------------------------------------
-- 3) label counts: a fight, 16 enemies hit 8 times a second for 3 seconds
------------------------------------------------------------------------------------------
local function fight(on: boolean, size: string, combine: boolean)
	clean()
	setSettings(on, size, combine)
	local frame, flush = 1 / 60, 1 / 8
	local nextFlush = 0
	local t = 0
	while t < 3 do
		if t >= nextFlush then
			nextFlush += flush
			local batch = {}
			for id = 1, 16 do
				table.insert(batch, id)
				table.insert(batch, 40 + id)
				table.insert(batch, id % 8 == 0 and 1 or 0)
			end
			DamageText._Feed(batch, T0 + t)
		end
		DamageText._Step(T0 + t)
		t += frame
	end
	local d = DamageText.Debug()
	return d.Created, d.Peak, d.Merged
end
local offCreated, offPeak = fight(false, "Normal", true)
local plainCreated, plainPeak, plainMerged = fight(true, "Normal", false)
local combCreated, combPeak, combMerged = fight(true, "Normal", true)
preview.log(string.format("NUMBERS  labels created / most on screen at once, 16 enemies x 8 hits/s x 3 s: Off %d / %d, Combine off %d / %d, Combine on %d / %d (merged hits %d vs %d)", offCreated, offPeak, plainCreated, plainPeak, combCreated, combPeak, plainMerged, combMerged))
check(offCreated == 0 and offPeak == 0, "Off: no number labels at all")
check(combCreated < plainCreated and combCreated * 4 <= plainCreated, "Combine on makes at least 4x fewer labels than Combine off (" .. combCreated .. " vs " .. plainCreated .. ")")
check(combPeak <= plainPeak and plainPeak <= Config.DamageNumbers.MaxLabels, "Combine on never shows more labels at once; the hard cap " .. Config.DamageNumbers.MaxLabels .. " holds (" .. combPeak .. " / " .. plainPeak .. ")")
clean()

------------------------------------------------------------------------------------------
-- 4) persistence
------------------------------------------------------------------------------------------
local V = Config.ValidateSetting
check(V("DamageNumberSize", "Big") == "Big" and V("DamageNumberSize", "Huge") == nil and V("DamageNumberSize", 3) == nil, "the server accepts Small / Normal / Big and refuses junk sizes")
check(V("CombineNumbers", false) == false and V("CombineNumbers", "no") == nil and V("DamageNumbers", true) == true, "Combine numbers is a boolean; junk is refused")
Settings.Apply({ DamageNumbers = true, DamageNumberSize = "Big", CombineNumbers = false })
check(Settings.Get("DamageNumberSize") == "Big" and Settings.Get("CombineNumbers") == false and Settings.Get("DamageNumbers") == true, "a saved profile restores size and Combine on the client")
Settings.Apply({ DamageNumberSize = "Huge", CombineNumbers = "x" })
check(Settings.Get("DamageNumberSize") == "Big" and Settings.Get("CombineNumbers") == false, "junk in a profile is ignored")
setSettings(false, "Normal", true)

------------------------------------------------------------------------------------------
-- 5) the Settings screen
------------------------------------------------------------------------------------------
local function clickText(pattern: string): boolean
	local label = C.findText(pattern)
	local node = label
	while node and not node:IsA("GuiButton") do
		node = node.Parent
	end
	if not node then
		return false
	end
	preview.click(node)
	C.settle(0.4)
	return true
end
local settingsButton = C.findText("SETTINGS", "GuiButton")
if settingsButton then
	preview.click(settingsButton)
end
C.settle(1.5)
local row = C.findText("DAMAGE NUMBERS: ")
check(row ~= nil and string.find(string.upper(row.Text), "DAMAGE NUMBERS: OFF", 1, true) ~= nil, "Settings shows the DAMAGE NUMBERS row (Off first)")
check(C.findText("COMBINE NUMBERS") ~= nil, "Settings shows the COMBINE NUMBERS row")
local seen = {}
for _ = 1, 4 do
	if clickText("DAMAGE NUMBERS: ") then
		local r = C.findText("DAMAGE NUMBERS: ")
		table.insert(seen, r and string.match(string.upper(r.Text), "DAMAGE NUMBERS: (%u+)") or "?")
	end
end
check(table.concat(seen, ",") == "SMALL,NORMAL,BIG,OFF", "tapping the row cycles Small, Normal, Big, Off (" .. table.concat(seen, ",") .. ")")
clickText("DAMAGE NUMBERS: ")
check(Settings.Get("DamageNumbers") == true and Settings.Get("DamageNumberSize") == "Small", "the tap saved through the settings path (DamageNumbers on, size Small)")
local before = Settings.Get("CombineNumbers")
clickText("COMBINE NUMBERS")
check(Settings.Get("CombineNumbers") == not before, "the Combine numbers toggle flips the setting")
C.settle(1)

------------------------------------------------------------------------------------------
-- 6) the switch off
------------------------------------------------------------------------------------------
Config.Features.DamageNumberOptions = false
check(View.Mode({ DamageNumbers = true, DamageNumberSize = "Big" }) == "Normal" and View.TextSize("Big", false) == 18 and View.TextSize("Big", true) == 22, "switch off: always the old Normal look")
check(View.MergeWindow({ CombineNumbers = false }) == Config.DamageNumbers.MergeSeconds and View.Text(5, true) == "5!" and not View.CritBold(), "switch off: the old merge window and the old crit mark")
Config.Features.DamageNumberOptions = true

preview.log(fails == 0 and "damage-numbers-regression: all PASS" or string.format("damage-numbers-regression: %d FAIL", fails))
