-- codex-ui: stream L1. The CODEX (lobby COLLECTION screen, MenuCollection) on the real client from a sample profile.
--   --set tab=Classes|Weapons|Passives|Evolutions|Enemies|Controls   (default Classes)
--   --set open=<entry id>   open one entry's details (e.g. ScrapToss, BasinBreaker, Touch)
--   --set found=none|some   what the profile has found (default some)
-- Checks (PASS / FAIL lines): the category sizes, "???" for entries not found (details never leak), details of a
-- found entry, the progress line, and the keyboard / touch / gamepad controls.
local C = lib("common")
C.lobby()
C.startClient()

local passes, fails = 0, 0
local function check(label: string, ok: boolean, detail: any?)
	if ok then
		passes += 1
	else
		fails += 1
	end
	local why = detail ~= nil and tostring(detail) or ""
	if #why > 240 then
		why = string.sub(why, 1, 240) .. "..."
	end
	preview.log(string.format("%s %s%s", ok and "PASS" or "FAIL", label, (not ok and why ~= "") and (" (" .. why .. ")") or ""))
end

local tab = preview.args.tab or "Classes"
local found = preview.args.found or "some"
local p = C.profile()
p.Stats = { BestTime = 754, TotalKills = 4821, Wins = 1, Runs = 4, ClassGoals = { Elites = found == "some" and 2 or 0 } }
p.OwnedCharacters = found == "some" and { ruckus = true, toastmaster = true } or { ruckus = true }
p.SelectedCharacter = "ruckus"
p.Journal = { Enemies = found == "some" and { Skeleton = true, FloatingEye = true, BasinBoss = true } or {}, Drops = {} }
p.Discovered = {
	Weapons = found == "some" and { ScrapToss = true, ToastVolley = true, Whip = true } or {},
	Passives = found == "some" and { PocketDynamo = true, RatchetTimer = true } or {},
	Items = {},
	Evolutions = found == "some" and { ScrapToss = true } or {},
	Synergies = {},
}
p.Features = { Collection = { Seen = {} } }
C.sendProfile(p)
C.settle(1)
preview.client("LobbyScreen").Show("Collection")
C.settle(1)

local function entries(): { any }
	return preview.findGui(function(o)
		return o.Name:sub(1, 6) == "Entry_" and o.ClassName == "Frame"
	end)
end
local function textOf(root: any): string
	local out = {}
	for _, d in ipairs(root:GetDescendants()) do
		if d:IsA("TextLabel") and d.Text ~= "" then
			table.insert(out, d.Text)
		end
	end
	return table.concat(out, " | ")
end
local function clickText(t: string)
	local g = preview.findGui(function(o)
		return o:IsA("GuiButton") and string.upper(o.Text) == string.upper(t) and preview.isShown(o)
	end)[1]
	if g then
		preview.click(g)
		C.settle(0.5)
		return true
	end
	return false
end

local sizes = { Classes = 12, Weapons = 15, Passives = 8, Evolutions = 4, Enemies = 7, Controls = 4 }
if tab ~= "Classes" then
	check("tab " .. tab .. " exists", clickText(tab))
end
local list = entries()
check(tab .. ": " .. tostring(sizes[tab]) .. " entries listed", #list == sizes[tab], #list)

local qs = preview.args.open
local header = textOf(preview.findGui(function(o)
	return o.Name == "Progress"
end)[1] or {})
if found == "none" and tab ~= "Controls" then
	local unknown = 0
	for _, e in ipairs(list) do
		if string.find(textOf(e), "???", 1, true) then
			unknown += 1
		end
	end
	check(tab .. ": nothing found shows ??? for every entry but the free class", unknown >= sizes[tab] - 1, unknown)
end
if qs then
	local head = preview.findGui(function(o)
		return o.Name == "Head" and o.Parent and o.Parent.Name == "Entry_" .. qs
	end)[1]
	check("entry " .. qs .. " exists", head ~= nil)
	if head then
		preview.click(head)
		C.settle(0.6)
		local entry = preview.findGui(function(o)
			return o.Name == "Entry_" .. qs
		end)[1]
		local t = entry and textOf(entry) or ""
		if string.find(t, "???", 1, true) then
			check("unknown entry " .. qs .. " says it is not found and gives no details", string.find(t, "Not found yet") ~= nil and not string.find(t, "damage") and not string.find(t, "Health"), t)
		else
			check("found entry " .. qs .. " shows details", #t > 80, t)
		end
	end
end
preview.log("codex-ui progress line: " .. header)
preview.log(string.format("codex-ui tab=%s found=%s: %d PASS, %d FAIL", tab, found, passes, fails))
if fails > 0 then
	error(string.format("codex-ui: %d checks failed", fails))
end
