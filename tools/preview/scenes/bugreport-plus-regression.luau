-- bugreport-plus-regression: Config.Features.BugReportPlus (docs/next/BUG_REPORT_PLUS.md).
-- Runs WITHOUT --studio (live DEV rules: only the DevAllowlist owner may read the inbox;
-- the mock live DataStores). Every check prints PASS/FAIL; any FAIL errors at the end.
--   1) BugSnapshotData.CleanSnapshot keeps only known ids / fixed names / clamped numbers
--      (no free text), caps logs at 10 x 200 characters, rolling-hour check
--   2) the client helper (BugSnapshot.Collect) fills every snapshot field
--   3) real reports through the BugReport remote: the snapshot is stored, its log lines
--      lose player names and pass the text filter, the report text is filtered too
--   4) rate limit: the 4th report inside an hour is refused (server)
--   5) a non-dev player gets no inbox data; the owner gets the latest rows with snapshots
--   6) switch off: no snapshot stored or sent, inbox pages back to the old size
--   lune run tools/preview/runtime/main.luau -- --scene bugreport-plus-regression --device pc --set headless=on
local C = lib("common")
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
assert(not RunService:IsStudio(), "bugreport-plus-regression must run without --studio")

local failed = 0
local function check(ok: any, label: string)
	if ok then
		preview.log("PASS " .. label)
	else
		failed += 1
		preview.log("FAIL " .. label)
	end
end

local me = Players.LocalPlayer
local owner = preview.addPlayer("OwnerDev", 20194281) -- DevAllowlist
preview.startServer()
preview.advance(2)
preview.playerJoined(owner)
preview.advance(0.5)
C.startClient()
preview.advance(1)

local Config = preview.shared("Config")
local B = preview.shared("BugReportData")
local S = preview.shared("BugSnapshotData")
local Remotes = preview.shared("Remotes")
check(Config.Features.BugReportPlus == true, "switch BugReportPlus is on by default")

------------------------------------------------------------------------------------------
-- 1) pure cleaning
------------------------------------------------------------------------------------------
local anyWeapon, anyPassive, anyHero, anyArena
for id in pairs(preview.shared("WeaponData").Weapons) do
	anyWeapon = id
	break
end
for id in pairs(preview.shared("PassiveData").Passives) do
	anyPassive = id
	break
end
for id in pairs(preview.shared("CharacterData").Characters) do
	anyHero = id
	break
end
for id, a in pairs(Config.Arenas) do
	if type(a) == "table" then
		anyArena = id
		break
	end
end
local hostileLogs = {}
for i = 1, 30 do
	table.insert(hostileLogs, { Kind = i % 2 == 0 and "Error" or "Shout", Text = string.rep("z", 500) .. "\0\n" })
end
local clean = S.CleanSnapshot({
	Panel = "<b>hello mom</b>",
	Stage = 1e12,
	Wave = -5,
	Arena = "Nowhere land",
	Hero = "my cool text",
	Weapons = { { Id = anyWeapon, Level = 999 }, { Id = "free text weapon", Level = 3 }, { Id = anyWeapon, Level = 2 } },
	Passives = { { Id = anyPassive, Level = 0 / 0 } },
	Device = "My phone lol",
	ScreenW = math.huge,
	ScreenH = 390,
	TextSize = "Huge",
	Input = "Mind",
	Fps = 1e9,
	PlaceVersion = "12",
	Logs = hostileLogs,
	Note = "free text that must vanish",
})
check(clean.Panel == "None", "unknown panel becomes None")
check(clean.Stage == 999 and clean.Wave == 0, "stage / wave clamped")
check(clean.Arena == nil and clean.Hero == nil, "unknown arena / hero dropped")
check(#clean.Weapons == 1 and clean.Weapons[1].Level <= preview.shared("WeaponData").MaxLevel, "weapons: known ids only, level clamped, no repeats")
check(#clean.Passives == 1 and clean.Passives[1].Level == 1, "passive NaN level becomes 1")
check(clean.Device == "Unknown" and clean.Input == "Unknown" and clean.TextSize == nil, "device / input / text size from fixed lists only")
check(clean.ScreenW == nil and clean.ScreenH == 390 and clean.Fps == 999 and clean.PlaceVersion == nil, "numbers clamped, non-numbers dropped")
check(clean.Note == nil, "unknown keys dropped")
local logsOk = #clean.Logs == S.MaxLogs
for _, e in ipairs(clean.Logs) do
	if #e.Text > S.MaxLogLength or string.find(e.Text, "[%z\n]") or (e.Kind ~= "Warn" and e.Kind ~= "Error") then
		logsOk = false
	end
end
check(logsOk, "logs: at most 10 lines, 200 characters, printable, Warn/Error only")
local good = S.CleanSnapshot({ Panel = "LevelUp", Hero = anyHero, Arena = anyArena, TextSize = "Largest", Input = "Touch", Device = "Phone" })
check(good.Panel == "LevelUp" and good.Hero == anyHero and good.Arena == anyArena and good.TextSize == "Largest", "valid values kept")
check(S.RedactNames("ClientMain: OwnerDev hit ownerdev", { "OwnerDev" }) == "ClientMain: [player] hit [player]", "player names redacted (any case)")
local now = 5000000
local fits1 = S.HourCheck({ now - 3700, now - 100, now - 50 }, now)
local fits2 = S.HourCheck({ now - 10, now - 20, now - 30 }, now)
check(fits1 == true and fits2 == false, "rolling hour: 3 inside the hour blocks, older ones expire")

------------------------------------------------------------------------------------------
-- 2) client helper
------------------------------------------------------------------------------------------
local Snap = C.try("require BugSnapshot", preview.client, "BugSnapshot")
local collected: any = nil
if Snap then
	Snap.Start()
	preview.advance(2.5)
	Snap._AddLog("Players." .. me.Name .. ".PlayerScripts.Hud:12: attempt to index nil (badword)", Enum.MessageType.MessageError)
	Snap._AddLog("[Sound] asset failed to load", Enum.MessageType.MessageWarning)
	Snap._AddLog("plain print is not kept", Enum.MessageType.MessageOutput)
	collected = Snap.Collect()
end
check(type(collected) == "table", "BugSnapshot.Collect returns a table")
collected = collected or {}
for _, key in ipairs({ "Panel", "Device", "ScreenW", "ScreenH", "TextSize", "Input", "Fps", "PlaceVersion", "Logs", "Weapons", "Passives" }) do
	check(collected[key] ~= nil, "snapshot field " .. key .. " present (" .. tostring(collected[key]) .. ")")
end
check(type(collected.Logs) == "table" and #collected.Logs == 2, "only warnings / errors are kept from the log")
preview.log("client snapshot lines: " .. table.concat(S.Lines(S.CleanSnapshot(collected), nil), " || "))

------------------------------------------------------------------------------------------
-- 3) + 4) real reports and the rate limit
------------------------------------------------------------------------------------------
local results = {}
preview.remote("BugReportResult").OnClientEvent:Connect(function(d)
	table.insert(results, d)
	preview.log(string.format("BugReportResult Ok=%s Message=%s", tostring(d.Ok), tostring(d.Message)))
end)
B.CooldownSeconds = 1 -- the per-minute gap is not under test here
local function report(textValue: string)
	local n = #results
	preview.remote("BugReport"):FireServer({ Category = "Gameplay", Text = textValue, Client = {}, Snapshot = collected })
	preview.advance(6.5) -- past the 5 s retry gap and the 1 s cooldown
	return results[n + 1]
end
local r1 = report("First report, badword in the text.")
local r2 = report("Second report about the same bug.")
local r3 = report("Third report about the same bug.")
local r4 = report("Fourth report inside the same hour.")
check(r1 and r1.Ok and r2 and r2.Ok and r3 and r3.Ok, "three reports in an hour are saved")
check(r4 and r4.Ok == false and string.find(tostring(r4.Message), "this hour") ~= nil, "the fourth report in the hour is refused")

------------------------------------------------------------------------------------------
-- 5) inbox access
------------------------------------------------------------------------------------------
local sent: { { player: Player, data: any } } = {}
local realFire = Remotes.FireClient
Remotes.FireClient = function(name, player, ...)
	if name == "BugInboxData" then
		table.insert(sent, { player = player, data = (...) })
	end
	return realFire(name, player, ...)
end
preview.remote("BugInbox"):FireServer("Page", nil)
preview.advance(1)
local toMe = 0
for _, e in ipairs(sent) do
	if e.player == me then
		toMe += 1
	end
end
check(toMe == 0, "a non-dev player gets no inbox data")
preview.fireServerAs(owner, "BugInbox", "Page", nil)
preview.advance(1)
local page = sent[#sent]
check(page and page.player == owner and page.data.Status == "ok", "the DEV owner gets an inbox page")
local rows = page and page.data.Rows or {}
check(#rows == 3, "inbox lists the 3 saved reports (got " .. #rows .. ")")
local row = rows[1] or {}
check(type(row.Snapshot) == "table", "rows carry the snapshot")
local snap = type(row.Snapshot) == "table" and row.Snapshot or {}
check(snap.Device ~= nil and snap.Input ~= nil and snap.PlaceVersion ~= nil and snap.ScreenW ~= nil, "stored snapshot has device / input / screen / place version")
local joined = ""
for _, e in ipairs(snap.Logs or {}) do
	joined ..= e.Text .. "\n"
end
check(#(snap.Logs or {}) == 2, "stored snapshot keeps the 2 log lines")
check(string.find(joined, me.Name, 1, true) == nil and string.find(joined, "[player]", 1, true) ~= nil, "log lines have the player name removed")
check(string.find(joined, "badword", 1, true) == nil and string.find(joined, "#######", 1, true) ~= nil, "log lines went through the text filter")
check(string.find(tostring(row.Text), "badword", 1, true) == nil, "report text is filtered")
for _, line in ipairs(S.Lines(snap, row.ServerBuild)) do
	preview.log("  inbox: " .. line)
end
check(S.InboxRows == 20, "inbox page size is 20 with the switch on")

------------------------------------------------------------------------------------------
-- 6) switch off
------------------------------------------------------------------------------------------
Config.Features.BugReportPlus = false
local r5 = report("Fifth report with the switch off.")
check(r5 and r5.Ok == true, "switch off: no hourly limit (old daily quota only)")
preview.fireServerAs(owner, "BugInbox", "Page", nil)
preview.advance(1)
page = sent[#sent]
local offRows = page and page.data.Rows or {}
local anySnap = false
for _, r in ipairs(offRows) do
	if r.Snapshot ~= nil or r.ServerBuild ~= nil then
		anySnap = true
	end
end
check(#offRows == 4 and not anySnap, "switch off: inbox rows have no snapshot")
local store = game:GetService("DataStoreService"):GetDataStore(B.StoreName)
local newest = offRows[1] and store:GetAsync(offRows[1].Id)
check(type(newest) == "table" and newest.Snapshot == nil, "switch off: the new record stores no snapshot")
Config.Features.BugReportPlus = true
Remotes.FireClient = realFire

preview.log(string.format("bugreport-plus-regression: %d failure(s)", failed))
if failed > 0 then
	error("bugreport-plus-regression failed")
end
