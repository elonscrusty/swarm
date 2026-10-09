-- class-browser-regression: stream L1 (docs/redesign/lobby/L1_STATUS.md), the class browser's data and
-- server confirmation on the real modules, headless. Prints PASS / FAIL.
--   1) the exact twelve ids; every class has details (name, description, weapon, passive, movement)
--   2) every figure equals the authoritative tuning: health and speed = StatSheet.Compute, jump apex =
--      RunConfig.Movement, dash / leap distance and cooldown = what Dash.lua reads, weapon damage /
--      interval / range = WeaponData rank 1 (GetStats and RankSpec), labelled "base values before upgrades"
--   3) a missing figure is Hidden with a reason, never a zero
--   4) access text: starter / buyable (price + goal) / goal only, progress text (Knuckles has two parts)
--   5) LobbyView: Progress for the classes not owned, ClassAck after Select / Buy (worked and refused)
--   6) the codex: 12 classes, 15 weapons, 8 loot passives, 4 evolutions, 7 enemies, the controls; discovery
--      follows the existing rules and an unknown entry gives nothing away; every number comes from the tuning
--   7) settings: the new keys exist with defaults, validate (0-1 clamp, booleans), and the readers map them
--      (camera sensitivity / invert, effects intensity, UI size, master volume)
local RS = game:GetService("ReplicatedStorage")
local SSS = game:GetService("ServerScriptService")
local Players = game:GetService("Players")

local Lobby = SSS.SwarmV2.Lobby
local ClassCatalog = preview.require(RS.SwarmV2.ClassCatalog)
local ClassDetails = preview.require(RS.SwarmV2.Lobby.ClassDetails)
local RunConfig = preview.require(RS.SwarmV2.Run.RunConfig)
local ClassRoster = preview.require(RS.SwarmV2.Run.ClassRoster)
local BuildRules = preview.require(RS.SwarmV2.Run.BuildRules)
local ClassOwnership = preview.require(Lobby.ClassOwnership)
local ClassService = preview.require(Lobby.ClassService)
local Config = preview.shared("Config")
local CharacterData = preview.shared("CharacterData")
local MetaUpgradeData = preview.shared("MetaUpgradeData")
local WeaponData = preview.shared("WeaponData")
local StatSheet = preview.shared("StatSheet")
local CodexData = preview.require(RS.SwarmV2.Lobby.CodexData)
local EnemyData = preview.shared("EnemyData")
local PassiveData = preview.shared("PassiveData")

local passes, fails = 0, 0
local function check(label: string, ok: boolean, detail: any?)
	if ok then
		passes += 1
	else
		fails += 1
	end
	preview.log(string.format("%s %s%s", ok and "PASS" or "FAIL", label, (not ok and detail ~= nil) and (" (" .. tostring(detail) .. ")") or ""))
end
local function near(a: number?, b: number?): boolean
	return a ~= nil and b ~= nil and math.abs(a - b) < 1e-6
end

-- the server registers the classes in CharacterData at boot (ClassRegistry)
ClassRoster.Register(CharacterData, MetaUpgradeData)

local EXPECTED = {
	"ruckus", "toastmaster", "captain_croak", "granny_boom", "coach_crunch", "doug_janitor",
	"peter_parkour", "barry_plotter", "rambozo", "swolverine", "crash_cassidy", "knuckles_mcgee",
}

------------------------------------------------------------------------------------------
-- 1) ids and details
------------------------------------------------------------------------------------------
do
	local same = #ClassCatalog.Order == #EXPECTED
	for i, id in ipairs(EXPECTED) do
		same = same and ClassCatalog.Order[i] == id
	end
	check("catalog: the exact twelve ids in order", same, table.concat(ClassCatalog.Order, ","))
	check("catalog: old heroes are not classes", not ClassCatalog.IsClassId("Knight") and not ClassCatalog.IsClassId("Mage"))
	check("details: unknown / legacy ids have none", ClassDetails.Get("Knight") == nil and ClassDetails.Get(nil) == nil and ClassDetails.Get("tony_starch") == nil)
	for _, id in ipairs(EXPECTED) do
		local d = ClassDetails.Get(id)
		local ok = d ~= nil and d.Id == id and d.Name ~= "" and d.Description ~= "" and d.Role ~= ""
			and d.Weapon.Name ~= "Unknown weapon" and #d.Weapon.Behavior > 8
			and #d.Passive.Name > 2 and #d.Passive.Behavior > 12 and #d.Movement.Name > 2 and #d.Movement.Behavior > 12
			and d.BaseNote == "Base values before upgrades"
		check("details: " .. id .. " has name, description, weapon, passive, movement", ok)
		if d then
			local bad = false
			for _, text in ipairs({ d.Description, d.Weapon.Behavior, d.Passive.Behavior, d.Movement.Behavior }) do
				local low = string.lower(text)
				if string.find(low, "%f[%w]nan%f[%W]") or string.find(low, "%f[%w]inf%f[%W]") or string.find(low, "nil") or string.find(text, "%%[a-z]") then
					bad = true
				end
			end
			check("details: " .. id .. " texts have no nil / nan / stray format codes", not bad)
			check("details: " .. id .. " has the eight measurements (health, speed, jump, dash, cooldown, damage, interval, range)", #d.Stats == 8)
		end
	end
end

------------------------------------------------------------------------------------------
-- 2) figures equal the authoritative tuning
------------------------------------------------------------------------------------------
do
	local all = true
	for _, id in ipairs(EXPECTED) do
		local d = assert(ClassDetails.Get(id))
		local sheet = StatSheet.Compute({ CharacterId = id })
		local roster = RunConfig.Classes.Roster[id]
		local sig = roster.StartWeapon
		local row = WeaponData.GetStats(sig, 1)
		local spec = WeaponData.RankSpec(sig, 1)
		local dashDef = RunConfig.Dash.Variants[id] or RunConfig.Dash.Default
		local function S(key: string)
			return ClassDetails.StatOf(d, key)
		end
		local checks = {
			Health = near(S("Health").Number, sheet.MaxHP),
			Speed = near(S("Speed").Number, sheet.Speed),
			Jump = near(S("Jump").Number, RunConfig.Movement.JumpApexByClass[id] or RunConfig.Movement.JumpApex),
			Cooldown = near(S("Cooldown").Number, dashDef.Cooldown),
			Dash = near(S("Dash").Number, dashDef.Kind == "Leap" and dashDef.Horizontal or dashDef.Speed * dashDef.Duration),
			Damage = near(S("Damage").Number, row.damage),
			Interval = near(S("Interval").Number, row.cooldown),
			Range = near(S("Range").Number, spec.Range or spec.Reach),
			WeaponId = d.Weapon.Id == sig and d.Weapon.Id == WeaponData.Signatures[id],
			WeaponName = d.Weapon.Name == WeaponData.Weapons[sig].Name,
		}
		for k, ok in pairs(checks) do
			if not ok then
				all = false
				check("figures: " .. id .. " " .. k .. " equals the tuning", false, tostring(S(k) and S(k).Number))
			end
		end
	end
	check("figures: health, speed, jump, dash / leap, cooldown, damage, interval, range equal StatSheet / RunConfig / Dash / WeaponData for all twelve", all)

	-- spot values from the brief's tuning (not recomputed from the same formula)
	local function get(id: string, key: string): number
		return (assert(ClassDetails.StatOf(assert(ClassDetails.Get(id)), key)).Number :: number)
	end
	check("figures: Ruckus 120 HP, 22 studs/s, jump 9, dash 15.4 studs, 2.5 s", get("ruckus", "Health") == 120 and get("ruckus", "Speed") == 22 and get("ruckus", "Jump") == 9 and near(get("ruckus", "Dash"), 15.4) and get("ruckus", "Cooldown") == 2.5)
	check("figures: Toastmaster 108 HP and jump 12", get("toastmaster", "Health") == 108 and get("toastmaster", "Jump") == 12)
	check("figures: Captain Croak leaps 30 studs, 3 s", get("captain_croak", "Dash") == 30 and get("captain_croak", "Cooldown") == 3)
	check("figures: Granny Boom 132 HP, walks 20, boost 20 studs (80 x 0.25), 3 s", get("granny_boom", "Health") == 132 and get("granny_boom", "Speed") == 20 and get("granny_boom", "Dash") == 20 and get("granny_boom", "Cooldown") == 3)
	check("figures: Crash Cassidy body-check dash cooldown 2.2 s", get("crash_cassidy", "Cooldown") == 2.2)
	check("figures: Ruckus scrap 9 damage every 0.9 s, range 32", get("ruckus", "Damage") == 9 and get("ruckus", "Interval") == 0.9 and get("ruckus", "Range") == 32)
	check("figures: Swolverine claws reach 14, 115 percent health", get("swolverine", "Range") == 14 and get("swolverine", "Health") == 138)
	local peter = assert(ClassDetails.Get("peter_parkour"))
	check("figures: Peter keeps the 9-stud jump and names the charged jump (11 studs, 6 s)", get("peter_parkour", "Jump") == 9 and string.find(assert(ClassDetails.StatOf(peter, "Jump")).Note or "", "11") ~= nil and string.find(peter.Movement.Behavior, "11") ~= nil)
	local ramb = assert(ClassDetails.Get("rambozo"))
	check("figures: Rambozo's damage is per pellet and says three pellets", string.find(assert(ClassDetails.StatOf(ramb, "Damage")).Note or "", "3 pellets") ~= nil)
	-- numbers in the sentences follow RunConfig: change one and the text follows
	local old = RunConfig.Classes.JunkCollector.RewardsPerCharge
	RunConfig.Classes.JunkCollector.RewardsPerCharge = 7
	check("texts: passive sentences read RunConfig live (Junk Collector 5 -> 7)", string.find(assert(ClassDetails.Get("ruckus")).Passive.Behavior, "Every 7 ") ~= nil)
	RunConfig.Classes.JunkCollector.RewardsPerCharge = old
	check("texts: ... and back", string.find(assert(ClassDetails.Get("ruckus")).Passive.Behavior, "Every 5 ") ~= nil)
	-- weapon text, passive names
	check("texts: weapon names are the shipped ones", assert(ClassDetails.Get("ruckus")).Weapon.Name == "Scrap Shot" and assert(ClassDetails.Get("toastmaster")).Weapon.Name == "Toast Toss" and assert(ClassDetails.Get("knuckles_mcgee")).Weapon.Name == "Glove Combo")
	check("texts: passive names come from the class roster", assert(ClassDetails.Get("granny_boom")).Passive.Name == ClassRoster.Defs.granny_boom.Trait.Name or assert(ClassDetails.Get("granny_boom")).Passive.Name == "Tangled Up")
end

------------------------------------------------------------------------------------------
-- 3) hidden figures
------------------------------------------------------------------------------------------
do
	local def = WeaponData.Weapons.ScrapToss
	local saved = def.Rank
	def.Rank = nil
	local d = assert(ClassDetails.Get("ruckus"))
	local dmg = assert(ClassDetails.StatOf(d, "Damage"))
	check("hidden: a weapon without numbers hides damage / interval / range with a reason and no zero", dmg.Hidden ~= nil and dmg.Number == nil and dmg.Value == nil and assert(ClassDetails.StatOf(d, "Interval")).Hidden ~= nil and assert(ClassDetails.StatOf(d, "Range")).Hidden ~= nil)
	def.Rank = saved
	check("hidden: restored", assert(ClassDetails.StatOf(assert(ClassDetails.Get("ruckus")), "Damage")).Number == 9)
	local spec = WeaponData.Weapons.ScrapToss.Rank
	local r, reach = spec.Range, spec.Reach
	spec.Range = nil
	spec.Reach = nil
	local range = assert(ClassDetails.StatOf(assert(ClassDetails.Get("ruckus")), "Range"))
	check("hidden: a weapon with neither range nor reach explains it", range.Hidden == "This weapon has no fixed range." and range.Number == nil)
	spec.Range, spec.Reach = r, reach
	check("hidden: a melee weapon is labelled reach", assert(ClassDetails.StatOf(assert(ClassDetails.Get("doug_janitor")), "Range")).Label == "Weapon reach")
	local any = true
	for _, id in ipairs(EXPECTED) do
		for _, s in ipairs(assert(ClassDetails.Get(id)).Stats) do
			if s.Hidden == nil and (s.Number == nil or s.Number ~= s.Number or s.Value == nil or s.Value == "0" and s.Key ~= "Cooldown") then
				any = false
			end
		end
	end
	check("hidden: no class shows an empty or zero measurement", any)
end

------------------------------------------------------------------------------------------
-- 4) access text
------------------------------------------------------------------------------------------
do
	local A = ClassDetails.Access
	check("access: Ruckus is the free starter", A("ruckus", true, nil).State == "Starter")
	local t = A("toastmaster", false, { Have = 120, Need = 300, Stat = "XP" })
	check("access: Toastmaster is buyable for 10,000 and also has its goal with progress", t.State == "Buyable" and t.Price == 10000 and string.find(t.Summary, "10,000") ~= nil and t.Goal == "Collect 300 XP in runs" and t.Parts[1] == "120 / 300 XP" and near(t.Fraction, 0.4))
	check("access: Captain Croak 20,000 and Granny Boom 30,000", A("captain_croak", false, nil).Price == 20000 and A("granny_boom", false, nil).Price == 30000)
	local c = A("coach_crunch", false, { Have = 90, Need = 180, Stat = "BestSurvive" })
	check("access: Coach is goal only, survival progress shown as time", c.State == "GoalOnly" and c.Price == nil and c.Parts[1] == "1:30 / 3:00" and string.find(c.Summary, "cannot be bought") ~= nil)
	local k = A("knuckles_mcgee", false, { Have = 0, Need = 1, Stat = "Bosses", Parts = { { Stat = "Bosses", Have = 0, Need = 1 }, { Stat = "Revives", Have = 0, Need = 1 } } })
	check("access: Knuckles shows both routes (a boss or a revive)", k.State == "GoalOnly" and #k.Parts == 2 and k.Parts[1] == "0 / 1 boss" and k.Parts[2] == "0 / 1 revive")
	check("access: an owned class says so", A("toastmaster", true, nil).State == "Owned")
	check("access: unknown id", A("Knight", false, nil) == nil)
	check("access: no progress known -> no made-up progress", A("rambozo", false, nil).Parts == nil or #A("rambozo", false, nil).Parts == 0)
	check("access: thousands separator", ClassDetails.Thousands(10000) == "10,000" and ClassDetails.Thousands(999) == "999" and ClassDetails.ProgressText("Distance", 1234, 3000) == "1,234 / 3,000 studs")
end

------------------------------------------------------------------------------------------
-- 5) LobbyView pieces: Progress and ClassAck
------------------------------------------------------------------------------------------
do
	local data = { OwnedCharacters = { ruckus = true, toastmaster = true }, SelectedCharacter = "ruckus", Gold = 25000, Stats = { ClassGoals = { Dashes = 12, Bosses = 0, Revives = 1, BestSurvive = 400 } } }
	local prog = ClassOwnership.ProgressAll(data)
	check("progress: only classes not owned (toastmaster, ruckus absent)", prog.toastmaster == nil and prog.ruckus == nil and prog.peter_parkour ~= nil)
	check("progress: Peter 12 / 30 dashes", prog.peter_parkour.Have == 12 and prog.peter_parkour.Need == 30 and prog.peter_parkour.Stat == "Dashes")
	check("progress: Coach is capped at its need (400 of 180 -> 180)", prog.coach_crunch.Have == 180 and prog.coach_crunch.Need == 180)
	check("progress: Knuckles has both parts, the revive part is met", prog.knuckles_mcgee.Parts ~= nil and #prog.knuckles_mcgee.Parts == 2 and prog.knuckles_mcgee.Parts[2].Have == 1)
	check("progress: no stats yet -> zeros, never nil", ClassOwnership.ProgressAll({ OwnedCharacters = {} }).rambozo.Have == 0)
	check("progress: junk save -> empty / zero", next(ClassOwnership.ProgressAll(nil)) ~= nil and ClassOwnership.ProgressAll(nil).rambozo.Have == 0)

	-- ClassService answers
	local me = Players.LocalPlayer
	local saves: { [Player]: any } = { [me] = data }
	local notes: { string } = {}
	local pushes = 0
	ClassService._SetDeps({
		DataService = { GetData = function(p: Player)
			return saves[p]
		end },
		Notify = function(_p: Player, text: string)
			table.insert(notes, text)
		end,
		Push = function()
			pushes += 1
		end,
		OnClass = function() end,
	})
	check("ack: none before any action", ClassService.AckOf(me) == nil)
	ClassService.OnAction(me, "Select", "toastmaster")
	local a = ClassService.AckOf(me)
	check("ack: Select of an owned class worked, one push", a ~= nil and a.Ok and a.Id == "toastmaster" and a.Action == "Select" and a.N == 1 and data.SelectedCharacter == "toastmaster" and pushes == 1, pushes)
	ClassService.OnAction(me, "Select", "captain_croak")
	a = ClassService.AckOf(me)
	check("ack: Select of a locked class refused with a code, selection kept, one push", a ~= nil and not a.Ok and a.Code == "NOT_OWNED" and a.Id == "captain_croak" and a.N == 2 and data.SelectedCharacter == "toastmaster" and pushes == 2, pushes)
	ClassService.OnAction(me, "Buy", "coach_crunch")
	a = ClassService.AckOf(me)
	check("ack: Buy of a goal-only class refused (GOAL_ONLY) with a note, gold kept", a ~= nil and a.Code == "GOAL_ONLY" and data.Gold == 25000 and string.find(notes[#notes] or "", "earned in runs") ~= nil, notes[#notes])
	ClassService.OnAction(me, "Buy", "captain_croak")
	a = ClassService.AckOf(me)
	check("ack: Buy worked: gold paid once, class owned and selected", a ~= nil and a.Ok and a.Action == "Buy" and data.Gold == 5000 and data.OwnedCharacters.captain_croak == true and data.SelectedCharacter == "captain_croak")
	ClassService.OnAction(me, "Buy", "granny_boom")
	a = ClassService.AckOf(me)
	check("ack: Buy without enough gold refused (NO_GOLD), nothing taken", a ~= nil and a.Code == "NO_GOLD" and data.Gold == 5000 and data.OwnedCharacters.granny_boom == nil)
	local before = pushes
	ClassService.OnAction(me, "Select", "captain_croak")
	check("ack: re-selecting the same class still answers (the browser can resolve)", pushes == before + 1 and ClassService.AckOf(me).Ok)
	ClassService.OnAction(me, "Nope", "captain_croak")
	ClassService.OnAction(me, "Select", 5 :: any)
	a = ClassService.AckOf(me)
	check("ack: junk action ignored, junk id answered as UNKNOWN_CLASS", a ~= nil and a.Code == "UNKNOWN_CLASS")
end

------------------------------------------------------------------------------------------
-- 6) the codex
------------------------------------------------------------------------------------------
do
	local function cat(id: string)
		return assert(CodexData.Category(id))
	end
	check("codex: 12 classes, 15 weapons, 8 loot passives, 4 evolutions, 7 enemies", #cat("Classes").Entries == 12 and #cat("Weapons").Entries == 15 and #cat("Passives").Entries == 8 and #cat("Evolutions").Entries == 4 and #cat("Enemies").Entries == 7)
	local names = {}
	for _, e in ipairs(cat("Enemies").Entries) do
		table.insert(names, e.Name)
	end
	check("codex: the run's enemies are beetle, floating eye, root runner, stump brute, sap lobber, elite marker, Basin Breaker", table.concat(names, ",") == "Beetle,Floating Eye,Root Runner,Stump Brute,Sap Lobber,Elite marker,Basin Breaker", table.concat(names, ","))
	local classNames = {}
	for i, e in ipairs(cat("Classes").Entries) do
		classNames[i] = e.Id
	end
	check("codex: the classes are ClassCatalog.Order", table.concat(classNames, ",") == table.concat(ClassCatalog.Order, ","))
	local evoNames = {}
	for _, e in ipairs(cat("Evolutions").Entries) do
		table.insert(evoNames, e.Name)
	end
	check("codex: the four evolutions", table.concat(evoNames, ",") == "Junkyard Cyclone,Toaststorm,Bubble Torrent,Knitting Nightmare", table.concat(evoNames, ","))
	local noOld = true
	for _, e in ipairs(cat("Weapons").Entries) do
		if table.find({ "Knives", "Garlic", "Lightning" }, e.Id) then
			noOld = false
		end
	end
	for _, e in ipairs(cat("Passives").Entries) do
		if not table.find(PassiveData.LootOrder, e.Id) then
			noOld = false
		end
	end
	check("codex: no hidden old weapons or passives", noOld)
	check("codex: controls for keyboard, touch and gamepad plus how a run goes", #cat("Controls").Entries == 4 and CodexData.Known({}, "Controls", "Touch"))

	-- discovery: the existing rules
	local none = {}
	local some = {
		OwnedCharacters = { ruckus = true, toastmaster = true },
		Discovered = { Weapons = { ScrapToss = true }, Passives = { PocketDynamo = true }, Items = {}, Evolutions = { ScrapToss = true } },
		Journal = { Enemies = { Skeleton = true, BasinBoss = true } },
		Stats = { ClassGoals = { Elites = 2 } },
	}
	check("codex: nothing found on an empty profile except the free class and the controls", (function()
		local n, total = CodexData.Progress(none)
		return n == 1 and total == 12 + 15 + 8 + 4 + 7
	end)(), select(1, CodexData.Progress(none)))
	check("codex: owned classes, discovered weapons / passives / evolutions, met enemies are known", CodexData.Known(some, "Classes", "toastmaster") and CodexData.Known(some, "Weapons", "ScrapToss") and CodexData.Known(some, "Passives", "PocketDynamo") and CodexData.Known(some, "Evolutions", "ScrapToss") and CodexData.Known(some, "Enemies", "Skeleton"))
	check("codex: the rest stays unknown", not CodexData.Known(some, "Classes", "granny_boom") and not CodexData.Known(some, "Weapons", "ToastVolley") and not CodexData.Known(some, "Passives", "LuckyButton") and not CodexData.Known(some, "Evolutions", "ToastVolley") and not CodexData.Known(some, "Enemies", "FloatingEye"))
	check("codex: the elite marker needs a defeated elite, the Basin Breaker the journal", CodexData.Known(some, "Enemies", "EliteMarker") and not CodexData.Known(none, "Enemies", "EliteMarker") and CodexData.Known(some, "Enemies", "BasinBreaker") and not CodexData.Known(none, "Enemies", "BasinBreaker"))
	check("codex: junk profiles never throw and know nothing", not CodexData.Known(nil, "Weapons", "ScrapToss") and not CodexData.Known({ Discovered = 5 }, "Weapons", "ScrapToss"))

	-- details are real and complete
	local all = true
	for _, c in ipairs(CodexData.Categories) do
		for _, e in ipairs(c.Entries) do
			local d = CodexData.Detail(c.Id, e.Id)
			local text = table.concat(d.Lines, "\n")
			for _, r in ipairs(d.Rows) do
				text ..= "\n" .. r.Label .. ": " .. r.Value
			end
			local low = string.lower(text)
			local bad = #d.Lines == 0 or #text < 20 or string.find(low, "nil") ~= nil or string.find(low, "%f[%w]nan%f[%W]") ~= nil or string.find(text, "%%[a-z]") ~= nil or string.find(text, "No details available") ~= nil or string.find(text, "%d B%f[%W]") ~= nil
			if bad then
				all = false
				check("codex: " .. c.Id .. "/" .. e.Id .. " has real details", false, text)
			end
		end
	end
	check("codex: every entry has real details without nil / nan / format codes", all)
	local ruckus = CodexData.Detail("Classes", "ruckus")
	check("codex: class details carry the kit and base values", string.find(table.concat(ruckus.Lines, " "), "Scrap Shot") ~= nil and string.find(table.concat(ruckus.Lines, " "), "Junk Collector") ~= nil and #ruckus.Rows >= 8)
	local scrap = CodexData.Detail("Weapons", "ScrapToss")
	check("codex: weapon details carry rank milestones, the evolution and rank-1 figures", string.find(table.concat(scrap.Lines, " "), "Rank 3") ~= nil and string.find(table.concat(scrap.Lines, " "), "Junkyard Cyclone") ~= nil and #scrap.Rows >= 3)
	local evo = CodexData.Detail("Evolutions", "ScrapToss")
	local b = RunConfig.Builds
	check("codex: the evolution recipe reads the tuning (level / ranks)", string.find(table.concat(evo.Lines, " "), "rank " .. b.EvolutionWeaponRank) ~= nil and string.find(table.concat(evo.Lines, " "), "level " .. b.EvolutionLevel) ~= nil)
	local beetle = CodexData.Detail("Enemies", "Skeleton")
	local rosterBeetle = RunConfig.Director.Roster[1]
	check("codex: the beetle's health and speed are the roster's (HP x B)", string.find(beetle.Rows[2].Value, tostring(rosterBeetle.HP * RunConfig.Builds.B)) ~= nil and string.find(beetle.Rows[3].Value, tostring(rosterBeetle.Speed)) ~= nil, beetle.Rows[2].Value)
	local boss = CodexData.Detail("Enemies", "BasinBreaker")
	check("codex: the Basin Breaker lists its three marked attacks and its health from the director", #boss.Lines >= 4 and string.find(boss.Rows[1].Value, "2,000") ~= nil or string.find(boss.Rows[1].Value, "2000") ~= nil, boss.Rows[1].Value)
	check("codex: the controls entries come from the shared list the guide uses", CodexData.Controls.Touch[2] == "Camera: swipe the right side of the screen" and table.concat(CodexData.Detail("Controls", "Keyboard").Lines, " ") == table.concat(CodexData.Controls.Keyboard, " "))
	check("codex: EnemyData has display data for every listed type", (function()
		for _, e in ipairs(cat("Enemies").Entries) do
			if e.Id ~= "EliteMarker" and e.Id ~= "BasinBreaker" and EnemyData.Enemies[e.Id] == nil then
				return false
			end
		end
		return true
	end)())
end

------------------------------------------------------------------------------------------
-- 7) settings keys and readers
------------------------------------------------------------------------------------------
do
	local Remotes = preview.shared("Remotes")
	Remotes.Setup()
	preview.startClient(false) -- the client modules without any layout
	local D = Config.Settings.Defaults
	check("settings: the new keys exist with their defaults", D.MasterVolume == 1 and D.CameraSensitivity == 0.5 and D.InvertCameraX == false and D.InvertCameraY == false and D.EffectsIntensity == 1 and D.UIScale == 0.5 and D.LobbyGuideSeen == false)
	check("settings: the server validates them (0-1 clamp for sliders, booleans only)", Config.ValidateSetting("CameraSensitivity", 3) == 1 and Config.ValidateSetting("CameraSensitivity", -2) == 0 and Config.ValidateSetting("InvertCameraX", true) == true and Config.ValidateSetting("InvertCameraX", 1) == nil and Config.ValidateSetting("UIScale", 0 / 0) == nil and Config.ValidateSetting("Nope", 1) == nil)
	local CS = preview.client("ClientSettings")
	local mult, sx, sy = CS.CameraTuning()
	check("settings: the default camera is unchanged (1x, not inverted)", math.abs(mult - 1) < 1e-9 and sx == 1 and sy == 1 and math.abs(CS.UIScaleMult() - 1) < 1e-9 and CS.EffectsMult() == 1 and CS.MasterVolume() == 1)
	CS.Set("CameraSensitivity", 1)
	CS.Set("InvertCameraY", true)
	mult, sx, sy = CS.CameraTuning()
	check("settings: max sensitivity is 2x, invert Y flips only Y", math.abs(mult - 2) < 1e-9 and sx == 1 and sy == -1)
	CS.Set("CameraSensitivity", 0)
	CS.Set("InvertCameraX", true)
	mult, sx = CS.CameraTuning()
	check("settings: min sensitivity is 0.5x, invert X flips X", math.abs(mult - 0.5) < 1e-9 and sx == -1)
	check("settings: readouts", CS.SensitivityText(0.5) == "1.0x" and CS.SensitivityText(1) == "2.0x" and CS.UIScaleText(0.5) == "100%" and CS.UIScaleText(0) == "80%" and CS.UIScaleText(1) == "120%")
	CS.Set("UIScale", 1)
	CS.Set("EffectsIntensity", 0)
	CS.Set("MasterVolume", 0.25)
	check("settings: UI size 120%, effects intensity never below a quarter (decoration only), master volume", math.abs(CS.UIScaleMult() - 1.2) < 1e-9 and math.abs(CS.EffectsMult() - 0.25) < 1e-9 and CS.MasterVolume() == 0.25)
	CS.Set("CameraSensitivity", "loud" :: any)
	CS.Set("InvertCameraX", 5 :: any)
	check("settings: wrong types are ignored", CS.Get("CameraSensitivity") == 0 and CS.Get("InvertCameraX") == true)
	-- reset: every key back to its default through the same setter (one coalesced save)
	for key, default in pairs(D) do
		if key ~= "LobbyGuideSeen" then
			CS.Set(key, default)
		end
	end
	mult, sx, sy = CS.CameraTuning()
	check("settings: reset to defaults restores the camera, size, effects and volume", math.abs(mult - 1) < 1e-9 and sx == 1 and sy == 1 and math.abs(CS.UIScaleMult() - 1) < 1e-9 and CS.EffectsMult() == 1 and CS.MasterVolume() == 1)
end

preview.log(string.format("class-browser-regression: %d checks passed, %d failed", passes, fails))
if fails > 0 then
	error(string.format("class-browser-regression: %d checks failed", fails))
end
