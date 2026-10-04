--[[
	DataService.lua
	Player save data with ProfileService-style session locking.

	Each DataStore key holds:
	  { Data = <save table>, Lock = { JobId = string, Time = os.time() } | nil }

	Load:    UpdateAsync claims the lock. If another live server holds it (refreshed less
	         than Config.Data.LockStaleSeconds ago) we retry a few times, then kick with a
	         friendly message. A lock that stopped being refreshed (crashed server) is stolen.
	Save:    UpdateAsync writes Data only if we still own the lock and refreshes Lock.Time.
	         If the lock was taken by another server we stop saving and kick (prevents
	         two servers overwriting each other = item duplication).
	Release: on leave / shutdown the final save clears the lock.
	Handoff: a teleport to / from a private run server (RunServers) first saves and releases
	         the profile (ReleaseForTeleport), so the next server loads the latest save at
	         once; nothing is written by this server after that. A player who arrived by a
	         SWARM teleport gets Config.RunServers.HandoffLoadAttempts load retries (a slow
	         release on the other side is waited for, never stolen). If the teleport fails
	         the player stays and Reclaim takes the lock back (keeping this server's data
	         unless another server saved the profile meanwhile: then the stored save wins).
	         Every save also writes LastJob (the JobId that wrote it) for that check.
	Retry:   every DataStore call is pcall'd with exponential backoff.
	Studio:  uses Config.Data.StudioStoreName (never the live store); if DataStores are
	         unavailable (no API access) data is kept in memory only.

	Save shape (Config.Data.SchemaVersion = 7):
	  Version, Gold, Meta {id → level} (account upgrades Revive / Reroll / Skip; the old
	  shared stat levels stay in it untouched for rollback safety but are no longer read),
	  Heroes {heroId → {XP, Runs}} (Hero Mastery), HeroUpgrades {heroId → {upgradeId →
	  level}} (each hero's six stat upgrades + "Signature"), OwnedCharacters {id → true}, SelectedCharacter,
	  Skins {characterId → skinId}, Stats {BestTime, TotalKills, Wins, Runs, BestStage,
	  MostKills, BestScore, BestScoreEndless, BestLevel, TimePlayed (seconds in clean runs)}
	  (missing keys start at 0),
	  PurchaseIds {string}, Settings {Music, Sfx, Shake, ReducedEffects, DamageNumbers,
	  Tips} (Config.Settings.Defaults), ReviveTokens, SelectedArena,
	  Achievements {Progress {id → number}, Unlocked {id → os.time()}} (AchievementService),
	  Title (worn achievement title, "" = none), NameColor (AchievementData.Colors id, ""),
	  TutorialDone (first-run tips finished / skipped), FirstRunBonus (first-run gold paid), SeenTips {tipId → true},
	  Curses {curseId} (the run modifiers last picked in the lobby, CurseData),
	  Endless (boolean: the lobby ENDLESS switch, Config.Endless; old saves: false),
	  Daily {Day, Used, Score, Plays, BestScore, BestDay} (Daily Challenge: today's scored
	  attempt and the best ever score, CurseData.DailyScore),
	  Account {XP, Level} (cosmetic account level, AccountData), Ring, Frame (worn dais
	  ring / portrait frame from the level track, "" = none),
	  Discovered {Weapons, Passives, Items, Evolutions, Synergies} ({id → true}: what the
	  player has owned or seen; DiscoveryService, used to gate combination clues)

	Save health is shown to the player (never pretend saving works): the player attribute
	"SaveStatus" is "ok", "memory" (DataStores unavailable: nothing is saved this session)
	or "failing" (the last save failed after its retries; cleared by the next good save).
]]

local DataStoreService = game:GetService("DataStoreService")
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")

local Config = require(game:GetService("ReplicatedStorage").Shared.Config)
local CharacterData = require(game:GetService("ReplicatedStorage").Shared.CharacterData)
local CurseData = require(game:GetService("ReplicatedStorage").Shared.CurseData)
local MetaUpgradeData = require(game:GetService("ReplicatedStorage").Shared.MetaUpgradeData)
local AccountData = require(game:GetService("ReplicatedStorage").Shared.AccountData)
local EnemyData = require(game:GetService("ReplicatedStorage").Shared.EnemyData)

local DataService = {}

type Profile = {
	Player: Player,
	Key: string,
	Data: { [string]: any },
	Saving: boolean,
	Released: boolean,
	LockLost: boolean,
	LastSave: number,
}

local store: DataStore? = nil
local memoryStore: { [string]: any } = {} -- fallback when DataStores are unavailable
local profiles: { [Player]: Profile } = {}
-- UserIds whose leave / shutdown save is still being written by this server. A quick
-- rejoin to the same server (reconnect, Rejoin) waits for it: our own lock does not stop
-- the load, so without this it could read the save from before that final write and the
-- next autosave would put the older data back.
local releasing: { [number]: boolean } = {}
local loadedCallbacks: { (Player, Profile) -> () } = {}
local jobId = (game.JobId ~= "" and game.JobId) or ("studio-" .. tostring(math.random(1, 1e9)))

------------------------------------------------------------------------------------------
-- Defaults and migration
------------------------------------------------------------------------------------------

local function defaultDaily()
	return { Day = 0, Used = false, Score = 0, Plays = 0, BestScore = 0, BestDay = 0 }
end

local function defaultData()
	return {
		Version = Config.Data.SchemaVersion,
		Gold = 0,
		Difficulty = "Standard",
		DifficultyClears = { Standard = false, Veteran = false, Nightmare = false },
		Meta = {},
		Heroes = {},
		HeroUpgrades = {},
		OwnedCharacters = { [CharacterData.Default] = true },
		SelectedCharacter = CharacterData.Default,
		Skins = {},
		Stats = { BestTime = 0, TotalKills = 0, Wins = 0, Runs = 0, BestStage = 0, MostKills = 0, BestScore = 0, BestScoreEndless = 0, BestLevel = 0, TimePlayed = 0 },
		PurchaseIds = {},
		Settings = table.clone(Config.Settings.Defaults),
		ReviveTokens = 0,
		SelectedArena = "Forest",
		Achievements = { Progress = {}, Unlocked = {} },
		Journal = { Enemies = {}, Drops = {} },
		Discovered = { Weapons = {}, Passives = {}, Items = {}, Evolutions = {}, Synergies = {} },
		Title = "",
		NameColor = "",
		TutorialDone = false,
		FirstRunBonus = false, -- the first run's one-time gold bonus was paid (Config.FirstRun)
		SeenTips = {},
		Curses = {},
		Endless = false,
		Daily = defaultDaily(),
		Account = { XP = 0, Level = 1 },
		Ring = "",
		Frame = "",
	}
end
DataService.DefaultData = defaultData

--[[
	Migration steps: MIGRATIONS[n] upgrades a version-n save to version n+1.
	Version 1 (early test builds) stored owned characters as an array and had no
	settings / revive tokens. Version 2 had no Stats.BestStage (the stage loop): it starts
	at 0, the furthest stage reached in a run from now on. Version 3 had no achievements: they
	start empty (owned characters, gold and skins are untouched). Version 4 had no
	accessibility settings and no first-run tips: settings get their defaults, and anyone
	who has played a run already counts as having done the tutorial. Version 5 had no
	retention systems: curses start unpicked, no daily played, account level 1 with 0 XP
	(the level track starts for everyone from the next run; old progress is untouched),
	no ring / frame worn, Stats.MostKills 0. Version 6 had one shared set of stat upgrades
	(Meta): Hero Mastery copies those levels to EVERY hero's own track (nothing wiped or
	refunded, gold untouched, Meta kept as it was) and every hero starts at mastery 0 XP.
]]
local MIGRATIONS: { [number]: (any) -> any } = {
	[0] = function(data)
		-- pre-versioned saves: treat as version 1
		data.Version = 1
		return data
	end,
	[1] = function(data)
		if type(data.OwnedCharacters) == "table" and data.OwnedCharacters[1] ~= nil then
			local set = {}
			for _, id in ipairs(data.OwnedCharacters) do
				set[id] = true
			end
			data.OwnedCharacters = set
		end
		data.Settings = data.Settings or { Music = 0.6, Sfx = 0.8 }
		data.ReviveTokens = data.ReviveTokens or 0
		data.Version = 2
		return data
	end,
	[2] = function(data)
		if type(data.Stats) ~= "table" then
			data.Stats = {}
		end
		if type(data.Stats.BestStage) ~= "number" then
			data.Stats.BestStage = 0
		end
		data.Version = 3
		return data
	end,
	[3] = function(data)
		-- achievements and their cosmetics; everything already owned stays as it is
		if type(data.Achievements) ~= "table" then
			data.Achievements = {}
		end
		if type(data.Achievements.Progress) ~= "table" then
			data.Achievements.Progress = {}
		end
		if type(data.Achievements.Unlocked) ~= "table" then
			data.Achievements.Unlocked = {}
		end
		if type(data.Title) ~= "string" then
			data.Title = ""
		end
		if type(data.NameColor) ~= "string" then
			data.NameColor = ""
		end
		data.Version = 4
		return data
	end,
	[4] = function(data)
		-- accessibility settings (filled from Config.Settings.Defaults below) and the
		-- first-run tips: players who already played skip them
		local runs = type(data.Stats) == "table" and tonumber(data.Stats.Runs) or 0
		data.TutorialDone = (runs or 0) > 0
		data.SeenTips = {}
		data.Version = 5
		return data
	end,
	[5] = function(data)
		-- curses, the daily challenge, the account level and its cosmetics (all new)
		data.Curses = {}
		data.Daily = defaultDaily()
		data.Account = { XP = 0, Level = 1 }
		data.Ring = ""
		data.Frame = ""
		if type(data.Stats) == "table" and type(data.Stats.MostKills) ~= "number" then
			data.Stats.MostKills = 0
		end
		data.Version = 6
		return data
	end,
	[6] = function(data)
		-- Hero Mastery: the shared stat levels become every hero's own levels
		local seed = {}
		if type(data.Meta) == "table" then
			for _, id in ipairs(MetaUpgradeData.StatOrder) do
				local n = tonumber(data.Meta[id])
				if n and n == n and n > 0 and n < math.huge then
					seed[id] = math.clamp(math.floor(n), 0, MetaUpgradeData.Upgrades[id].MaxLevel)
				end
			end
		end
		local tracks = type(data.HeroUpgrades) == "table" and data.HeroUpgrades or {}
		for _, heroId in ipairs(CharacterData.Order) do
			local track = type(tracks[heroId]) == "table" and tracks[heroId] or {}
			for id, level in pairs(seed) do
				if level > 0 and (tonumber(track[id]) or 0) < level then
					track[id] = level
				end
			end
			tracks[heroId] = track
		end
		data.HeroUpgrades = tracks
		if type(data.Heroes) ~= "table" then
			data.Heroes = {}
		end
		data.Version = 7
		return data
	end,
}

-- Brings any stored table up to the current schema and fills missing fields.
function DataService.Migrate(data: any): { [string]: any }
	if type(data) ~= "table" then
		return defaultData()
	end
	local legacyDifficulty = data.DifficultyClears == nil
	local version = tonumber(data.Version) or 0
	while version < Config.Data.SchemaVersion do
		local step = MIGRATIONS[version]
		if not step then
			break
		end
		data = step(data)
		version = tonumber(data.Version) or (version + 1)
	end
	-- Fill anything missing (also protects against hand-edited saves).
	local defaults = defaultData()
	for k, v in pairs(defaults) do
		if data[k] == nil then
			data[k] = v
		end
	end
	-- a stored table field of the wrong shape (hand edits, a partial write) gets its default;
	-- every other field of the save is left as it is
	for k, v in pairs(defaults) do
		if type(v) == "table" and type(data[k]) ~= "table" then
			data[k] = v
		end
	end
	for k, v in pairs(defaults.Stats) do
		local n = data.Stats[k]
		if type(n) ~= "number" or n ~= n or math.abs(n) == math.huge then
			data.Stats[k] = v
		end
	end
	-- permanent upgrades: whole levels inside each upgrade's range (the shop compares and
	-- prices them as numbers); ids the game no longer knows are left untouched
	for id, level in pairs(data.Meta) do
		local def = MetaUpgradeData.Upgrades[id]
		if def then
			local n = tonumber(level)
			n = (n and n == n and n < math.huge) and math.clamp(math.floor(n), 0, def.MaxLevel) or 0
			data.Meta[id] = n > 0 and n or nil
		end
	end
	-- Hero Mastery (schema 7): whole, finite XP / run counts per known hero and whole
	-- upgrade levels inside each upgrade's range; unknown ids are left untouched
	for _, heroId in ipairs(CharacterData.Order) do
		local h = data.Heroes[heroId]
		if h ~= nil then
			if type(h) ~= "table" then
				h = {}
			end
			for _, key in ipairs({ "XP", "Runs" }) do
				local n = tonumber(h[key])
				h[key] = (n and n == n and n < math.huge) and math.max(0, math.floor(n)) or 0
			end
			data.Heroes[heroId] = h
		end
		local track = data.HeroUpgrades[heroId]
		if track ~= nil then
			if type(track) ~= "table" then
				track = {}
			end
			for id, level in pairs(track) do
				local def = MetaUpgradeData.HeroDef(heroId, id)
				if def then
					local n = tonumber(level)
					n = (n and n == n and n < math.huge) and math.clamp(math.floor(n), 0, def.MaxLevel) or 0
					track[id] = n > 0 and n or nil
				end
			end
			data.HeroUpgrades[heroId] = track
		end
	end
	local tokens = tonumber(data.ReviveTokens)
	data.ReviveTokens = (tokens and tokens == tokens and tokens < math.huge) and math.max(0, math.floor(tokens)) or 0
	local purchaseIds = {}
	for _, id in ipairs(data.PurchaseIds) do
		if type(id) == "string" then
			table.insert(purchaseIds, id)
		end
	end
	data.PurchaseIds = purchaseIds
	if type(data.SelectedArena) ~= "string" or not table.find(Config.Arenas.Order, data.SelectedArena) then
		data.SelectedArena = "Forest"
	end
	if type(data.Gold) ~= "number" or data.Gold ~= data.Gold or math.abs(data.Gold) == math.huge then
		data.Gold = 0
	end
	data.Gold = math.max(0, math.floor(data.Gold))
	if type(data.Achievements) ~= "table" then
		data.Achievements = defaults.Achievements
	end
	if type(data.Achievements.Progress) ~= "table" then
		data.Achievements.Progress = {}
	end
	if type(data.Achievements.Unlocked) ~= "table" then
		data.Achievements.Unlocked = {}
	end
	-- settings: every key present and of the right type (old saves, hand edits)
	if type(data.Settings) ~= "table" then
		data.Settings = {}
	end
	for k, v in pairs(Config.Settings.Defaults) do
		if type(data.Settings[k]) ~= type(v) then
			data.Settings[k] = v
		end
	end
	if type(data.TutorialDone) ~= "boolean" then
		data.TutorialDone = (data.Stats.Runs or 0) > 0
	end
	if type(data.SeenTips) ~= "table" then
		data.SeenTips = {}
	end
	-- additive (no schema bump): an older save never gets the first-run welcome anyway
	-- (Stats.Runs > 0), so a missing flag reads as "not paid"
	if type(data.FirstRunBonus) ~= "boolean" then
		data.FirstRunBonus = false
	end
	-- discovered weapons / passives / items / evolutions / synergies (DiscoveryService):
	-- every table present, nothing removed (additive, no schema bump)
	if type(data.Discovered) ~= "table" then
		data.Discovered = {}
	end
	for _, kind in ipairs({ "Weapons", "Passives", "Items", "Evolutions", "Synergies" }) do
		if type(data.Discovered[kind]) ~= "table" then
			data.Discovered[kind] = {}
		end
	end
	-- schema 6: curses, daily, account level, cosmetics (hand edits / partial saves)
	if type(data.Curses) ~= "table" then
		data.Curses = {}
	end
	data.Curses = CurseData.Sanitize(data.Curses) or {}
	if type(data.Endless) ~= "boolean" then
		data.Endless = false
	end
	if type(data.Daily) ~= "table" then
		data.Daily = defaultDaily()
	end
	for k, v in pairs(defaultDaily()) do
		if type(data.Daily[k]) ~= type(v) then
			data.Daily[k] = v
		end
	end
	if type(data.Account) ~= "table" then
		data.Account = { XP = 0, Level = 1 }
	end
	local xp = tonumber(data.Account.XP)
	data.Account.XP = (xp and xp == xp) and math.max(0, math.floor(xp)) or 0
	data.Account.Level = (AccountData.LevelFor(data.Account.XP))
	for _, key in ipairs({ "Ring", "Frame", "Title", "NameColor" }) do
		if type(data[key]) ~= "string" then
			data[key] = ""
		end
	end
	if type(data.OwnedCharacters) ~= "table" then
		data.OwnedCharacters = {}
	end
	data.OwnedCharacters[CharacterData.Default] = true
	if not CharacterData.Characters[data.SelectedCharacter] or not data.OwnedCharacters[data.SelectedCharacter] then
		data.SelectedCharacter = CharacterData.Default
	end
	-- worn skins: a known skin of that character (or the Starter Pack one); ownership is
	-- checked again by MonetizationService when the look is built
	for characterId, skinId in pairs(data.Skins) do
		local skin = type(skinId) == "string" and CharacterData.Skins[skinId] or nil
		local fits = skinId == "Default" or (skin ~= nil and (skin.Character == characterId or skin.Character == "*"))
		if not CharacterData.Characters[characterId] or not fits then
			data.Skins[characterId] = nil
		end
	end
	if data.Difficulty ~= "Standard" and data.Difficulty ~= "Veteran" and data.Difficulty ~= "Nightmare" then
		data.Difficulty = "Standard"
	end
	local oldJournal = type(data.Journal) == "table" and data.Journal or {}
	local journal = { Enemies = {}, Drops = {} }
	for id in pairs(EnemyData.Enemies) do
		if type(oldJournal.Enemies) == "table" and oldJournal.Enemies[id] == true then journal.Enemies[id] = true end
		local drops = type(oldJournal.Drops) == "table" and oldJournal.Drops[id]
		if type(drops) == "table" then
			for _, drop in ipairs({ "XP", "Gold", "Chest", "Chicken", "Magnet", "Bomb" }) do
				if drops[drop] == true then
					journal.Enemies[id] = true
					journal.Drops[id] = journal.Drops[id] or {}
					journal.Drops[id][drop] = true
				end
			end
		end
	end
	data.Journal = journal
	local lastRun = data.LastRun
	data.LastRun = nil
	if type(lastRun) == "table" then
		local clean = { Won = lastRun.Won == true, Portal = lastRun.Portal == true }
		for _, key in ipairs({ "Time", "Stage", "StagesCleared", "Kills", "Level", "Gold" }) do
			local value = lastRun[key]
			clean[key] = type(value) == "number" and value == value and math.abs(value) < math.huge
				and math.clamp(math.floor(value), 0, 1e12) or 0
		end
		clean.Mode = type(lastRun.Mode) == "string" and type((Config.Modes :: any)[lastRun.Mode]) == "table" and lastRun.Mode ~= "Order" and lastRun.Mode or "Solo"
		clean.CharacterId = CharacterData.Characters[lastRun.CharacterId] and lastRun.CharacterId or CharacterData.Default
		clean.Difficulty = (lastRun.Difficulty == "Veteran" or lastRun.Difficulty == "Nightmare") and lastRun.Difficulty or "Standard"
		clean.DeathCause = type(lastRun.DeathCause) == "string" and string.sub(lastRun.DeathCause, 1, 100) or nil
		data.LastRun = clean
	end
	local reconnect = data.RunReconnect
	if type(reconnect) ~= "table" or type(reconnect.AccessCode) ~= "string" or #reconnect.AccessCode > 512
		or type(reconnect.PrivateId) ~= "string" or #reconnect.PrivateId > 128
		or type(reconnect.Id) ~= "string" or #reconnect.Id > 160
		or type(reconnect.Expires) ~= "number" or reconnect.Expires ~= reconnect.Expires
		or math.abs(reconnect.Expires) == math.huge then
		data.RunReconnect = nil
	else
		data.RunReconnect = { AccessCode = reconnect.AccessCode, PrivateId = reconnect.PrivateId, Id = reconnect.Id, Expires = reconnect.Expires }
	end
	if type(data.DifficultyClears) ~= "table" then
		data.DifficultyClears = {}
	end
	for _, id in ipairs({ "Standard", "Veteran", "Nightmare" }) do
		data.DifficultyClears[id] = data.DifficultyClears[id] == true
	end
	-- Existing recorded winners keep access to the next tier after the redesign.
	if legacyDifficulty and (data.Stats.Wins or 0) > 0 then
		data.DifficultyClears.Standard = true
	end
	if type(data.RunEscrow) ~= "table" or type(data.RunEscrow.Id) ~= "string" then
		data.RunEscrow = nil
	else
		for _, key in ipairs({ "Gold", "Stages" }) do
			local value = tonumber(data.RunEscrow[key])
			data.RunEscrow[key] = value and value == value and math.abs(value) < math.huge
				and math.max(0, math.floor(value)) or 0
		end
	end
	data.Version = Config.Data.SchemaVersion
	return data
end

------------------------------------------------------------------------------------------
-- Low-level store access with retry
------------------------------------------------------------------------------------------

local function update(key: string, transform: (any) -> any): (boolean, any)
	if not store then
		if not RunService:IsStudio() then
			return false, "Live DataStores unavailable"
		end
		local result = transform(memoryStore[key])
		if result ~= nil then
			memoryStore[key] = result
		end
		return true, memoryStore[key]
	end
	local s = store :: DataStore
	local delay = 1
	local lastErr
	for attempt = 1, Config.Data.SaveAttempts do
		local ok, result = pcall(function()
			return s:UpdateAsync(key, transform)
		end)
		if ok then
			return true, result
		end
		lastErr = result
		if attempt < Config.Data.SaveAttempts then
			task.wait(delay)
			delay *= 2
		end
	end
	warn("[DataService] UpdateAsync failed for " .. key .. ": " .. tostring(lastErr))
	return false, lastErr
end

------------------------------------------------------------------------------------------
-- Load
------------------------------------------------------------------------------------------

-- True when the player came through a SWARM teleport (to or from a private run server):
-- the other server released the save just before, so a lock still on it is worth waiting for.
local function arrivedByHandoff(player: Player): boolean
	local ok, data = pcall(function()
		return player:GetJoinData()
	end)
	local td = ok and type(data) == "table" and data.TeleportData or nil
	return type(td) == "table" and (td.SwarmRun ~= nil or td.SwarmReturn ~= nil or td.SwarmRejoin ~= nil)
end

local function loadProfile(player: Player): Profile?
	local key = Config.Data.KeyPrefix .. player.UserId
	local attempts = Config.Data.LoadAttempts
	local R = (Config :: any).RunServers
	if R and arrivedByHandoff(player) then
		attempts = math.max(attempts, R.HandoffLoadAttempts or attempts)
	end
	for attempt = 1, attempts do
		local lockedByOther = false
		local ok, record = update(key, function(old)
			old = (type(old) == "table") and old or {}
			local lock = old.Lock
			if lock and lock.JobId ~= jobId and type(lock.Time) == "number" and os.time() - lock.Time < Config.Data.LockStaleSeconds then
				lockedByOther = true
				return nil -- cancel the write, keep their lock
			end
			old.Lock = { JobId = jobId, Time = os.time() }
			return old
		end)
		if ok and not lockedByOther then
			local data = DataService.Migrate(type(record) == "table" and record.Data or nil)
			return {
				Player = player,
				Key = key,
				Data = data,
				Saving = false,
				Released = false,
				LockLost = false,
				LastSave = os.clock(),
			}
		end
		if attempt < attempts then
			task.wait(Config.Data.LoadRetryDelay)
		end
	end
	return nil
end

------------------------------------------------------------------------------------------
-- Save
------------------------------------------------------------------------------------------

--[[
	Saves a profile. `release` clears the session lock (leave / shutdown).
	Concurrent calls wait for the running save, then save again with the latest data.
	Returns true when the data is safely written.
]]
function DataService.SaveProfile(profile: Profile, release: boolean?): boolean
	if profile.LockLost or profile.Released then
		return false
	end
	while profile.Saving do
		task.wait(0.1)
	end
	if profile.Released then
		return false
	end
	profile.Saving = true
	local lostLock = false
	local snapshot = profile.Data
	local ok = update(profile.Key, function(old)
		old = (type(old) == "table") and old or {}
		local lock = old.Lock
		if lock and lock.JobId ~= jobId then
			lostLock = true
			return nil
		end
		old.Data = snapshot
		old.LastJob = jobId
		old.Lock = (not release) and { JobId = jobId, Time = os.time() } or nil
		return old
	end)
	profile.Saving = false
	profile.LastSave = os.clock()
	if not lostLock and profile.Player.Parent then
		-- the player sees when progress is not being written (UIBuilder save notice)
		DataService.SetSaveStatus(profile.Player, ok and "ok" or "failing")
	end
	if lostLock then
		profile.LockLost = true
		warn("[DataService] session lock lost for " .. profile.Key)
		if profile.Player.Parent then
			profile.Player:Kick("Your save was opened on another server. Please rejoin.")
		end
		return false
	end
	if ok and release then
		profile.Released = true
	end
	return ok
end

------------------------------------------------------------------------------------------
-- Public API
------------------------------------------------------------------------------------------

function DataService.GetProfile(player: Player): Profile?
	return profiles[player]
end

function DataService.GetData(player: Player): { [string]: any }?
	local p = profiles[player]
	return p and p.Data
end

-- Calls fn(player, profile) for every profile loaded from now on (and already loaded).
function DataService.OnProfileLoaded(fn: (Player, Profile) -> ())
	table.insert(loadedCallbacks, fn)
	for player, profile in pairs(profiles) do
		task.spawn(fn, player, profile)
	end
end

-- Saves now (used by receipts). Returns true on success.
function DataService.ForceSave(player: Player): boolean
	local p = profiles[player]
	if not p then
		return false
	end
	return DataService.SaveProfile(p, false)
end

function DataService.HasPurchase(player: Player, purchaseId: string): boolean
	local data = DataService.GetData(player)
	if not data then
		return false
	end
	return table.find(data.PurchaseIds, purchaseId) ~= nil
end

function DataService.RecordPurchase(player: Player, purchaseId: string)
	local data = DataService.GetData(player)
	if not data then
		return
	end
	table.insert(data.PurchaseIds, purchaseId)
	while #data.PurchaseIds > Config.Data.MaxStoredPurchaseIds do
		table.remove(data.PurchaseIds, 1)
	end
end

--[[
	Teleport handoff (RunServers): saves and releases the profile while the player is still
	here, so the destination server can load it straight away. The profile stays readable
	(GetData) but is never written again by this server unless Reclaim takes it back.
	Returns true when the save is written and the lock cleared (only then teleport).
]]
function DataService.ReleaseForTeleport(player: Player): boolean
	local p = profiles[player]
	if not p then
		return false
	end
	if p.Released then
		return true
	end
	if store == nil then
		-- memory only: nothing to hand over (the other server starts from defaults anyway)
		p.Released = true
		return true
	end
	return DataService.SaveProfile(p, true)
end

-- True while the profile is handed off (released for a teleport that has not failed).
function DataService.IsReleased(player: Player): boolean
	local p = profiles[player]
	return p ~= nil and p.Released
end

--[[
	The teleport failed and the player is still here: take the session lock back. When the
	stored save was written by another server after our release (LastJob is not us), the
	stored data replaces ours (it is newer). Returns false when another live server holds
	the lock (the player is kicked to rejoin: two servers must never write one save).
]]
function DataService.Reclaim(player: Player): boolean
	local p = profiles[player]
	if not p then
		return false
	end
	if not p.Released or p.LockLost then
		return not p.LockLost
	end
	if store == nil then
		p.Released = false
		return true
	end
	local lockedByOther = false
	local ok, record = update(p.Key, function(old)
		old = (type(old) == "table") and old or {}
		local lock = old.Lock
		if lock and lock.JobId ~= jobId and type(lock.Time) == "number" and os.time() - lock.Time < Config.Data.LockStaleSeconds then
			lockedByOther = true
			return nil
		end
		old.Lock = { JobId = jobId, Time = os.time() }
		return old
	end)
	if not ok or lockedByOther then
		warn("[DataService] could not reclaim " .. p.Key .. (lockedByOther and " (locked by another server)" or ""))
		DataService.SetSaveStatus(player, "failing")
		if lockedByOther and player.Parent then
			p.LockLost = true
			player:Kick("Your save was opened on another server. Please rejoin.")
		end
		return false
	end
	if type(record) == "table" and record.LastJob ~= nil and record.LastJob ~= jobId and type(record.Data) == "table" then
		p.Data = DataService.Migrate(record.Data)
	end
	p.Released = false
	p.LastSave = os.clock()
	DataService.SetSaveStatus(player, "ok")
	return true
end

-- Set by GameServer: runs at shutdown before the final saves.
DataService.ShutdownHook = nil :: (() -> ())?

function DataService.IsMemoryOnly(): boolean
	return store == nil
end

-- Player attribute "SaveStatus": "ok" | "failing" | "memory" (see the header).
function DataService.SetSaveStatus(player: Player, status: string)
	if store == nil then
		status = "memory"
	end
	if player:GetAttribute("SaveStatus") ~= status then
		player:SetAttribute("SaveStatus", status)
		if status ~= "ok" then
			warn(string.format("[DataService] save status for %s: %s", player.Name, status))
		end
	end
end

local function onPlayerAdded(player: Player)
	local waited = 0
	while releasing[player.UserId] and waited < 30 and player.Parent do
		task.wait(0.25)
		waited += 0.25
	end
	if not player.Parent then
		return
	end
	local profile = loadProfile(player)
	if not player.Parent then
		-- left while loading: give the lock back so another server can load at once
		if profile then
			DataService.SaveProfile(profile, true)
		end
		return
	end
	if not profile then
		player:Kick("Your save could not be opened. Please wait a minute and rejoin.")
		return
	end
	profiles[player] = profile
	DataService.SetSaveStatus(player, "ok")
	for _, fn in ipairs(loadedCallbacks) do
		task.spawn(fn, player, profile)
	end
end

local function onPlayerRemoving(player: Player)
	local profile = profiles[player]
	if not profile then
		return
	end
	-- Other services commit run results on PlayerRemoving first (GameServer orders this).
	local userId = player.UserId
	releasing[userId] = true
	local ok, err = pcall(DataService.SaveProfile, profile, true)
	releasing[userId] = nil
	if profiles[player] == profile then
		profiles[player] = nil
	end
	if not ok then
		warn("[DataService] final save failed for " .. profile.Key .. ": " .. tostring(err))
	end
end
DataService.ReleasePlayer = onPlayerRemoving

function DataService.Init(_ctx)
	local ok, result = pcall(function()
		-- Studio (tests, DEV commands) uses its own store: live saves are never touched
		local name = Config.Data.StoreName
		if RunService:IsStudio() then
			name = Config.Data.StudioStoreName or (Config.Data.StoreName .. "_Studio")
		end
		return DataStoreService:GetDataStore(name)
	end)
	if ok then
		store = result
		-- A quick read tells us if API access is enabled (Studio without access throws).
		local probeOk, probeErr = pcall(function()
			return (result :: DataStore):GetAsync("__probe")
		end)
		if not probeOk then
			warn("[DataService] DataStore probe failed: " .. tostring(probeErr))
			-- A transient live read failure must not replace existing saves with defaults.
			-- Keep the live store so normal retrying UpdateAsync determines availability.
			if RunService:IsStudio() then
				store = nil
			end
		end
	else
		warn("[DataService] DataStores unavailable: " .. tostring(result))
	end
end

function DataService.Start(_ctx)
	Players.PlayerAdded:Connect(onPlayerAdded)
	for _, player in ipairs(Players:GetPlayers()) do
		task.spawn(onPlayerAdded, player)
	end

	-- Auto-save loop (also refreshes the session lock).
	task.spawn(function()
		while true do
			task.wait(5)
			for _, profile in pairs(profiles) do
				if os.clock() - profile.LastSave >= Config.Data.AutoSaveSeconds and not profile.Saving then
					task.spawn(DataService.SaveProfile, profile, false)
				end
			end
		end
	end)

	game:BindToClose(function()
		-- Let gameplay commit unsaved run gold/stats into the profiles first.
		if DataService.ShutdownHook then
			pcall(DataService.ShutdownHook)
		end
		if RunService:IsStudio() and not store then
			return
		end
		local pending = 0
		for player, profile in pairs(profiles) do
			pending += 1
			task.spawn(function()
				DataService.SaveProfile(profile, true)
				profiles[player] = nil
				pending -= 1
			end)
		end
		local started = os.clock()
		while pending > 0 and os.clock() - started < 25 do
			task.wait(0.2)
		end
	end)
end

return DataService
