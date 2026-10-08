-- affix-sight-regression: the first-sight notice and the SeenAffixes save field against the
-- real server (server AffixSight via EnemySpawner.Step; Config.Features.AffixIcons,
-- docs/next/AFFIX_ICONS.md).
--   1) the save: a fresh profile has SeenAffixes = {}; Migrate repairs junk and drops unknown ids
--   2) a run: the first elite of an affix near the hero sends ONE notice (lane Notice, id
--      affix.<Affix>), a second elite of the same affix none, another affix its own
--   3) the field is saved and the notice never repeats in a later run
--   4) a DEV-tainted run neither shows nor records a new affix
--   5) the switch off: nothing is sent or recorded
--   6) the elite's replicated attribute "Affix" is what the badge reads
-- PASS / FAIL lines; any FAIL fails the regression.
local C = lib("common")
local Players = game:GetService("Players")
local me = Players.LocalPlayer
preview.forceMeshesUploaded()
preview.startServer()
preview.advance(2)

local Config = C.shared("Config")
local RM = preview.server("RunManager")
local DS = preview.server("DataService")
local ES = preview.server("EnemySpawner")

local data = assert(DS.GetData(me), "profile missing")
data.OwnedCharacters = { Knight = true }
data.SelectedCharacter = "Knight"
data.TutorialDone = true
data.FirstRunBonus = true
data.Stats.Runs = 5
C.startClient()
preview.advance(1)

local fails = 0
local function check(label: string, ok: boolean, detail: string?)
	if not ok then
		fails += 1
	end
	preview.log(string.format("%s  %s%s", ok and "PASS" or "FAIL", label, detail and ("  (" .. detail .. ")") or ""))
end

local notices = {}
preview.remote("Notify").OnClientEvent:Connect(function(d)
	if type(d) == "table" and type(d.Id) == "string" and string.sub(d.Id, 1, 6) == "affix." then
		table.insert(notices, d)
	end
end)
local function countOf(id: string): number
	local n = 0
	for _, d in ipairs(notices) do
		if d.Id == id then
			n += 1
		end
	end
	return n
end

local function startSolo()
	preview.remote("StartRun"):FireServer("Solo")
	preview.advance(2)
	local rp = RM.GetRunPlayer(me)
	if rp then
		rp.InvulnUntil = 1e9
	end
	return rp
end
local function backToLobby()
	local rp = RM.GetRunPlayer(me)
	if rp then
		RM.AbandonRun(rp)
	end
	preview.advance(Config.Run.ResultsSeconds + 3)
end
local function spawnElite(rp, affix: string, dx: number)
	local p = rp.Root.Position
	local e = ES.Spawn("Skeleton", Vector3.new(p.X + dx, p.Y, p.Z + 12), { Elite = true, Affix = affix, Force = true })
	if e then
		e.Speed = 0 -- stays where it spawned
	end
	return e
end

------------------------------------------------------------------------------------------
-- 1) the save field
------------------------------------------------------------------------------------------
check("a new profile has SeenAffixes = {}", type(DS.DefaultData().SeenAffixes) == "table" and next(DS.DefaultData().SeenAffixes) == nil)
local migrated = DS.Migrate({ Version = Config.Data.SchemaVersion, SeenAffixes = { Swift = true, Nope = true, Burning = "yes", Shielded = false } })
check("Migrate keeps known affixes seen and drops the rest", migrated.SeenAffixes.Swift == true and migrated.SeenAffixes.Nope == nil and migrated.SeenAffixes.Burning == nil and migrated.SeenAffixes.Shielded == nil)
check("Migrate repairs a junk SeenAffixes", type(DS.Migrate({ Version = Config.Data.SchemaVersion, SeenAffixes = 7 }).SeenAffixes) == "table")
data.SeenAffixes = {}

------------------------------------------------------------------------------------------
-- 2) a run
------------------------------------------------------------------------------------------
local rp = startSolo()
check("solo run started", rp ~= nil and rp.Root ~= nil)
if rp and rp.Root then
	local e1 = spawnElite(rp, "Shielded", 0)
	check("the elite exists and replicates its Affix attribute", e1 ~= nil and e1.Part:GetAttribute("Affix") == "Shielded" and e1.Part:GetAttribute("Elite") == true)
	preview.advance(1.5)
	check("first Shielded elite: one notice", countOf("affix.Shielded") == 1, tostring(countOf("affix.Shielded")))
	check("it is saved in SeenAffixes", data.SeenAffixes.Shielded == true)
	spawnElite(rp, "Shielded", 5)
	preview.advance(1.5)
	check("a second Shielded elite: no second notice", countOf("affix.Shielded") == 1)
	spawnElite(rp, "Swift", -5)
	preview.advance(1.5)
	check("a Swift elite: its own notice", countOf("affix.Swift") == 1 and data.SeenAffixes.Swift == true)
	check("Burning is still unseen", data.SeenAffixes.Burning == nil and countOf("affix.Burning") == 0)

	----------------------------------------------------------------------------------------
	-- 4) DEV taint: a new affix is neither shown nor recorded
	----------------------------------------------------------------------------------------
	rp.DevTainted = true
	spawnElite(rp, "Burning", 8)
	preview.advance(1.5)
	check("DEV-tainted run: no notice and nothing recorded", countOf("affix.Burning") == 0 and data.SeenAffixes.Burning == nil)
	rp.DevTainted = false
end
backToLobby()

------------------------------------------------------------------------------------------
-- 3) a later run: nothing repeats; Burning is still new
------------------------------------------------------------------------------------------
rp = startSolo()
if rp and rp.Root then
	spawnElite(rp, "Shielded", 0)
	spawnElite(rp, "Swift", 6)
	preview.advance(1.5)
	check("a later run: Shielded and Swift show nothing again", countOf("affix.Shielded") == 1 and countOf("affix.Swift") == 1)

	----------------------------------------------------------------------------------------
	-- 5) the switch off
	----------------------------------------------------------------------------------------
	Config.Features.AffixIcons = false
	spawnElite(rp, "Burning", -8)
	preview.advance(1.5)
	check("switch off: no notice and nothing recorded", countOf("affix.Burning") == 0 and data.SeenAffixes.Burning == nil)
	Config.Features.AffixIcons = true
	preview.advance(1.5)
	check("switch on again: the waiting Burning elite is met once", countOf("affix.Burning") == 1 and data.SeenAffixes.Burning == true)
	check("every notice carried the notice lane", (function()
		for _, d in ipairs(notices) do
			if d.Lane ~= "Notice" then
				return false
			end
		end
		return #notices == 3
	end)(), tostring(#notices) .. " notices")
end
backToLobby()

preview.log(fails == 0 and "affix-sight-regression: all PASS" or string.format("affix-sight-regression: %d FAIL", fails))
