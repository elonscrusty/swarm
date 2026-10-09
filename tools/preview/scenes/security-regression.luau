-- security-regression: audit 2026-10-05 (docs/audit/SECURITY.md). Runs WITHOUT --studio
-- (live-server DEV rules, the mock live store). Every check errors on failure.
--   1) save lifecycle fixtures: Migrate never throws on malformed / legacy / oversized saves
--      and keeps real progress; a newer build's save keeps its version (SEC-05)
--   2) a corrupt record is kept under Recovered, never overwritten (SEC-04)
--   3) same-server rejoin while the last session's final save is still running: never
--      loads the older save (waits, then loads the final data; or is turned away) (SEC-03)
--   4) a failed load writes nothing over a real save
--   5) DEV: a command mid-run taints the whole team (no boards, records, playtime); a
--      lobby God toggle taints the next run; invincibility ends with the run
--   6) duo choice protection: RewardClose / SetPause spam gives no invulnerability; a
--      chooser who drops out leaves no stale Paused / Offer flags
--      and enemies target the free partner, not a protected chooser (SEC-02b)
--   7) DevBoosted (SEC-13, owner OK 2026-10-05): run DEV commands never set it; lobby
--      LobbyGold / AccountLevels / UnlockAll do; Migrate defaults and keeps it; every later
--      run with a boosted player is tainted (team-wide) and submits nothing
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
assert(not RunService:IsStudio(), "security-regression must run without --studio")
local me = Players.LocalPlayer
local owner = preview.addPlayer("Owner", 20194281) -- DevAllowlist
local mate = preview.addPlayer("Mate", 61001)
preview.startServer()
preview.advance(2)
local Config = preview.shared("Config")
local DS = preview.server("DataService")
local RM = preview.server("RunManager")
local LB = preview.server("LeaderboardService")
local LUS = preview.server("LevelUpSystem")
local DevAccess = preview.server("DevAccess")
local CharacterData = preview.shared("CharacterData")
local Remotes = preview.shared("Remotes")
local store = game:GetService("DataStoreService"):GetDataStore(Config.Data.StoreName)
local function keyOf(id) return Config.Data.KeyPrefix .. id end
local function join(name, id)
	local p = preview.addPlayer(name, id)
	preview.playerJoined(p)
	preview.advance(0.5)
	return p
end

------------------------------------------------------------------------------------------
-- 1) Migrate fixtures
------------------------------------------------------------------------------------------
do
	local S = Config.Data.SchemaVersion
	local fixtures = {
		{}, { Version = "x" }, { Version = 0 / 0 }, { Version = math.huge }, { Version = -4 }, { Version = 3.5 },
		{ Gold = "12" }, { Gold = 1e308 }, { Gold = -50 }, { Stats = "junk" }, { Stats = { Runs = 0 / 0, BestStage = math.huge } },
		{ Meta = { MaxHP = 1e9, Revive = "3" } }, { OwnedCharacters = "Knight" }, { OwnedCharacters = { "Mage", 7, {} } },
		{ Settings = { Music = 0 / 0, Sfx = "loud" } }, { Achievements = { Progress = 5 } }, { Daily = { Day = "x" } },
		{ Account = { XP = -1e9 } }, { Account = { XP = 0 / 0 } }, { HeroUpgrades = { Knight = { MaxHP = math.huge } } },
		{ Skins = { Knight = 5, Nobody = "Default" } }, { PurchaseIds = { 1, "a", {} } }, { Curses = { 1, 2, 3 } },
		{ LastRun = { Time = math.huge, Mode = {} } }, { RunEscrow = { Id = 5 } }, { RunReconnect = { AccessCode = string.rep("x", 600) } },
		{ Journal = "x" }, { Discovered = { Weapons = 3 } }, { Difficulty = "God" }, { SelectedCharacter = "Nobody" },
		-- 30-features batch fields (docs/features/FOUNDATION.md)
		{ Sigils = { Owned = "x", Equipped = { {}, 5 } } }, { Sigils = { Owned = { A = 0 / 0 }, Equipped = "A" } },
		{ Weekly = "x" }, { Season = { Claimed = { 1, 2 }, XP = -1 } }, { Titles = { Owned = { [{}] = true } } },
		{ Collection = 3 }, { LoginStreak = { LastDay = math.huge } }, { Presets = { List = { 5, { Weapons = "x" } }, Active = 2 } },
		{ WeaponMastery = { Whip = 0 / 0 } }, { Cosmetics = { Owned = { [string.rep("z", 99)] = true }, Equipped = { Trail = 7 } } }, { Supporter = 1 },
	}
	for i, f in ipairs(fixtures) do
		local ok, out = pcall(DS.Migrate, f)
		assert(ok, "Migrate threw on fixture " .. i .. ": " .. tostring(out))
		assert(out.Version >= S and type(out.Gold) == "number" and out.Gold >= 0 and out.Gold == out.Gold, "fixture " .. i .. " normalised")
		assert(out.OwnedCharacters[CharacterData.Default] == true, "fixture " .. i .. " keeps the default hero")
	end
	-- real progress survives junk next to it
	local real = DS.Migrate({ Version = S, Gold = 4321, OwnedCharacters = { Mage = true }, Stats = { Wins = 3, BestStage = 4, Runs = "bad" } })
	assert(real.Gold == 4321 and real.OwnedCharacters.Mage and real.Stats.Wins == 3 and real.Stats.BestStage == 4 and real.Stats.Runs == 0, "junk field reset, progress kept")
	-- oversized but finite values are kept (nothing silently clipped from a real save)
	local big = DS.Migrate({ Version = S, Gold = 2 ^ 40, Stats = { TotalKills = 2 ^ 40 } })
	assert(big.Gold == 2 ^ 40 and big.Stats.TotalKills == 2 ^ 40, "large finite values kept")
	-- SEC-05: a save from a newer build keeps its version (its migrations never re-run)
	assert(DS.Migrate({ Version = S + 1, Gold = 5 }).Version == S + 1, "a newer build's version is kept")
	assert(DS.Migrate({ Version = 9999, Gold = 5 }).Version == S, "a far-off version is junk")
	assert(DS.Migrate({ Version = 2, Gold = 5 }).Version == S, "an old save reaches the current schema")
	-- feature fields never forge ownership: an equipped Sigil must be owned, junk is dropped
	local forged = DS.Migrate({ Version = S, Sigils = { Owned = {}, Equipped = { "HaresFoot" } }, Supporter = "true" })
	assert(#forged.Sigils.Equipped == 0 and forged.Supporter == false, "feature fields cannot be forged by a malformed save")
	preview.log(string.format("PASS migrate: %d malformed / legacy / oversized fixtures, progress kept, newer version kept", #fixtures))
end

------------------------------------------------------------------------------------------
-- 2) corrupt record kept under Recovered
------------------------------------------------------------------------------------------
do
	store:SetAsync(keyOf(62001), "corrupt-string-record")
	local p = join("Corrupt", 62001)
	assert(DS.GetData(p), "a corrupt record still opens a profile")
	DS.GetData(p).Gold = 9
	assert(DS.ForceSave(p), "and saves")
	local r = store:GetAsync(keyOf(62001))
	assert(r.Recovered == "corrupt-string-record" and r.Data.Gold == 9, "the unreadable value is kept under Recovered")
	preview.removePlayer(p)
	preview.advance(0.5)
	store:SetAsync(keyOf(62002), { Data = "half-written", Other = 1 })
	local q = join("Corrupt2", 62002)
	assert(DS.GetData(q), "non-table Data opens a profile")
	assert(DS.ForceSave(q))
	local r2 = store:GetAsync(keyOf(62002))
	assert(r2.Recovered == "half-written" and type(r2.Data) == "table" and r2.Other == 1, "non-table Data kept under Recovered")
	preview.removePlayer(q)
	preview.advance(0.5)
	preview.log("PASS corrupt records kept under Recovered (no destructive repair)")
end

------------------------------------------------------------------------------------------
-- 3) same-server rejoin during a slow final save
------------------------------------------------------------------------------------------
do
	store:SetAsync(keyOf(62003), { Data = { Version = Config.Data.SchemaVersion, Gold = 100 } })
	local p = join("Rejoiner", 62003)
	local profile = assert(DS.GetProfile(p))
	profile.Data.Gold = 555 -- earned this session, not yet autosaved
	profile.Saving = true -- an autosave still in flight (slow DataStore)
	preview.removePlayer(p) -- the final save queues behind it
	preview.advance(0.2)
	local back = join("Rejoiner", 62003)
	preview.advance(34) -- past the old 30 s cap
	assert(DS.GetData(back) == nil, "no load while the last session's final save is still pending")
	profile.Saving = false -- the slow save returns; the final save runs
	preview.advance(2)
	local d = assert(DS.GetData(back), "the rejoin loads once the final save is written")
	assert(d.Gold == 555, "the rejoin sees the final save (got " .. tostring(d.Gold) .. ")")
	preview.removePlayer(back)
	preview.advance(0.5)
	-- a final save that never finishes: the rejoin is turned away, nothing is loaded or written
	local p2 = join("Stuck", 62004)
	local prof2 = assert(DS.GetProfile(p2))
	prof2.Data.Gold = 77
	prof2.Saving = true
	preview.removePlayer(p2)
	preview.advance(0.2)
	local back2 = join("Stuck", 62004)
	preview.advance(65)
	assert(DS.GetData(back2) == nil, "a rejoin is turned away rather than loading an older save")
	prof2.Saving = false
	preview.advance(2)
	assert(store:GetAsync(keyOf(62004)).Data.Gold == 77, "the final save still lands")
	preview.removePlayer(back2)
	preview.advance(0.5)
	preview.log("PASS same-server rejoin never loads a save older than the final write")
end

------------------------------------------------------------------------------------------
-- 4) a failed load writes nothing
------------------------------------------------------------------------------------------
do
	Config.Data.LoadAttempts, Config.Data.SaveAttempts = 2, 1
	store:SetAsync(keyOf(62005), { Data = { Version = Config.Data.SchemaVersion, Gold = 31337 } })
	preview.failDataStores(false, true)
	local p = join("Unlucky", 62005)
	preview.advance(10)
	assert(DS.GetData(p) == nil, "a failed load gives no profile")
	preview.failDataStores(false, false)
	preview.removePlayer(p)
	preview.advance(1)
	local r = store:GetAsync(keyOf(62005))
	assert(r.Data.Gold == 31337 and r.Lock == nil, "the real save is untouched by a failed load")
	Config.Data.LoadAttempts, Config.Data.SaveAttempts = 6, 4
	preview.log("PASS failed load never writes defaults over a real save")
end

------------------------------------------------------------------------------------------
-- 5) DEV taint
------------------------------------------------------------------------------------------
local submits = 0
local realSubmit = LB.Submit
LB.Submit = function(...)
	submits += 1
	return realSubmit(...)
end
do
	assert(DevAccess.IsDev(owner) and not DevAccess.IsDev(mate) and not DevAccess.IsDev(me), "allowlist: owner only")
	local od, md = assert(DS.GetData(owner)), assert(DS.GetData(mate))
	assert(RM.StartTeamRun({ owner, mate }, "Duo", "Forest", owner), "duo starts")
	preview.advance(3)
	local orp, mrp = assert(RM.GetRunPlayer(owner)), assert(RM.GetRunPlayer(mate))
	assert(not orp.DevTainted and not mrp.DevTainted, "a clean start")
	preview.fireServerAs(mate, "DevCommand", "AddGold", 10)
	preview.advance(0.2)
	assert(not mrp.DevTainted, "an ordinary player's DEV request taints nothing")
	local playtime, best = md.Stats.TimePlayed, md.Stats.BestScore
	preview.fireServerAs(owner, "DevCommand", "AddGold", 10)
	preview.advance(0.2)
	assert(orp.DevTainted and mrp.DevTainted, "a DEV command taints every player in the run")
	preview.advance(5)
	submits = 0
	RM.AbandonRun(mrp)
	RM.AbandonRun(orp)
	preview.advance(1)
	assert(submits == 0, "a tainted run submits nothing to the leaderboards")
	assert(md.Stats.TimePlayed == playtime and md.Stats.BestScore == best, "no records or playtime from a tainted run")
	-- God in the lobby taints the next run; invincibility ends with it
	preview.advance(Config.Run.ResultsSeconds + 2)
	preview.fireServerAs(owner, "DevCommand", "God")
	assert(owner:GetAttribute("DevGod") == true, "God toggles for the developer")
	assert(RM.StartTeamRun({ owner }, "Solo", "Forest", owner), "solo starts")
	preview.advance(2)
	local grp = assert(RM.GetRunPlayer(owner))
	assert(grp.DevTainted, "a run started with God on is tainted")
	RM.AbandonRun(grp)
	preview.advance(1)
	assert(owner:GetAttribute("DevGod") == nil, "invincibility ends with the run")
	assert(od ~= nil)
	preview.log("PASS DEV: allowlist, team-wide taint, no boards / records / playtime, God taints and ends")
end
------------------------------------------------------------------------------------------
-- 7) DevBoosted profile flag
------------------------------------------------------------------------------------------
do
	preview.advance(Config.Run.ResultsSeconds + 2)
	local od, md = assert(DS.GetData(owner)), assert(DS.GetData(mate))
	assert(od.DevBoosted == false and md.DevBoosted == false, "default false; run commands (AddGold, God) never boost the profile")
	assert(DS.DefaultData().DevBoosted == false, "DefaultData has DevBoosted = false")
	local legacy = DS.Migrate({ Version = Config.Data.SchemaVersion, Gold = 5 })
	assert(legacy.DevBoosted == false, "a save without the flag migrates to false")
	local bad = DS.Migrate({ Version = Config.Data.SchemaVersion, Gold = 5, DevBoosted = "yes" })
	assert(bad.DevBoosted == false, "a malformed flag reads as false")
	local kept = DS.Migrate({ Version = Config.Data.SchemaVersion, Gold = 5, DevBoosted = true })
	assert(kept.DevBoosted == true, "Migrate keeps a set flag")
	-- a non-dev's lobby request does nothing
	preview.fireServerAs(mate, "DevCommand", "LobbyGold", 500)
	preview.advance(0.2)
	assert(md.DevBoosted == false, "an ordinary player's lobby DEV request sets nothing")
	-- clean solo run first: not tainted
	assert(RM.StartTeamRun({ owner }, "Solo", "Forest", owner), "solo starts")
	preview.advance(2)
	local crp = assert(RM.GetRunPlayer(owner))
	assert(not crp.DevTainted, "an unboosted profile starts a clean run")
	RM.AbandonRun(crp)
	preview.advance(1)
	preview.advance(Config.Run.ResultsSeconds + 2)
	for _, cmd in ipairs({ "LobbyGold", "AccountLevels", "UnlockAll" }) do
		od.DevBoosted = false
		preview.fireServerAs(owner, "DevCommand", cmd, 1)
		preview.advance(0.2)
		assert(od.DevBoosted == true, cmd .. " marks the profile DevBoosted")
	end
	assert(owner:GetAttribute("DevGod") == nil, "no God left on (taint must come from the flag)")
	-- a duo with the boosted owner: tainted for both, nothing submitted
	assert(RM.StartTeamRun({ owner, mate }, "Duo", "Forest", owner), "duo starts")
	preview.advance(3)
	local orp, mrp = assert(RM.GetRunPlayer(owner)), assert(RM.GetRunPlayer(mate))
	assert(orp.DevTainted and mrp.DevTainted, "a run with a DevBoosted player is tainted team-wide")
	local playtime = md.Stats.TimePlayed
	preview.advance(5)
	submits = 0
	RM.AbandonRun(mrp)
	RM.AbandonRun(orp)
	preview.advance(1)
	assert(submits == 0, "a DevBoosted run submits nothing to the leaderboards")
	assert(md.Stats.TimePlayed == playtime, "no playtime from a DevBoosted run")
	assert(od.DevBoosted == true, "the flag persists after the run")
	preview.log("PASS DevBoosted: lobby boosts set the flag, Migrate keeps it, boosted runs are tainted and submit nothing")
end
LB.Submit = realSubmit

------------------------------------------------------------------------------------------
-- 6) duo choice protection: no grace farming, no stale flags
------------------------------------------------------------------------------------------
do
	preview.advance(Config.Run.ResultsSeconds + 2)
	assert(RM.StartTeamRun({ owner, mate }, "Duo", "Forest", owner), "duo starts")
	preview.advance(6)
	local orp, mrp = assert(RM.GetRunPlayer(owner)), assert(RM.GetRunPlayer(mate))
	LUS.Cancel(orp)
	LUS.Cancel(mrp)
	preview.advance(3)
	local invuln = mrp.InvulnUntil
	for _ = 1, 20 do
		preview.fireServerAs(mate, "RewardClose", 1e9)
		preview.fireServerAs(mate, "SetPause", true)
		preview.advance(0.3)
	end
	preview.fireServerAs(mate, "SetPause", false)
	assert(mrp.InvulnUntil == invuln, "RewardClose / SetPause spam grants no invulnerability in a duo")
	assert(not RM.IsFrozen(), "and never freezes a duo")
	-- a chooser who drops out leaves no protection behind
	LUS.QueueLevels(mrp, 1)
	-- [stream B] the continuation pack's rank system: a team-run choice is live (not paused, not
	-- protected), so enemies keep chasing the chooser; the old system protects and they leave
	local liveChoices = require(game:GetService("ReplicatedStorage").SwarmV2.Run.RunConfig).Builds.Enabled == true
	assert(mrp.Offer and (mrp.Paused or (liveChoices and mrp.LiveChoice)), "panel open")
	if liveChoices then
		local Spawner = preview.server("EnemySpawner")
		local e = assert(Spawner.Spawn("Bat", mrp.Root.Position + Vector3.new(3, 0, 0), { Force = true, HP = 1e6 }))
		preview.advance(0.3)
		assert(e.Target == mrp, "a live chooser is not protected: the enemy next to them targets them")
		Spawner.Despawn(e)
		preview.log("PASS live choice: no protection, enemies keep their target")
	end
	-- SEC-02b (owner OK 2026-10-05): enemies leave a protected chooser for a free partner
	if not liveChoices then
		local Spawner = preview.server("EnemySpawner")
		local e = assert(Spawner.Spawn("Bat", mrp.Root.Position + Vector3.new(3, 0, 0), { Force = true, HP = 1e6 }))
		preview.advance(0.3)
		assert(e.Target == orp, "an enemy next to the chooser targets the free partner")
		LUS.QueueLevels(orp, 1)
		preview.advance(0.3)
		if orp.Offer and orp.Paused then
			assert(e.Target == mrp, "everyone protected: the nearest player again (no idle)")
			LUS.Cancel(orp)
		end
		Spawner.Despawn(e)
		preview.log("PASS SEC-02b: enemies skip a protected chooser while a partner is free")
	end
	preview.removePlayer(mate)
	preview.advance(0.5)
	-- the record is inert once out of the run: no one counts as choosing, nothing frozen
	local SM = preview.server("StageManager")
	assert(RM.GetRunPlayer(mate) == nil and not mrp.Alive, "the leaver is out of the run")
	assert(not SM.AnyChoiceOpen() and not RM.IsFrozen(), "no stale open choice holds the stage or the world")
	assert(Remotes.State():GetAttribute("ChoosingIds") == "", "nobody is shown as choosing")
	preview.log("PASS duo choice: no grace farming from RewardClose / SetPause, no stale flags after leaving")
end

preview.log("PASS security-regression")
