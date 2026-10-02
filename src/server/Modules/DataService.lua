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
	Retry:   every DataStore call is pcall'd with exponential backoff.
	Studio:  uses Config.Data.StudioStoreName (never the live store); if DataStores are
	         unavailable (no API access) data is kept in memory only.

	Save shape (Config.Data.SchemaVersion = 6):
	  Version, Gold, Meta {id → level}, OwnedCharacters {id → true}, SelectedCharacter,
	  Skins {characterId → skinId}, Stats {BestTime, TotalKills, Wins, Runs, BestStage,
	  MostKills, BestScore, BestScoreEndless, BestLevel} (missing keys start at 0),
	  PurchaseIds {string}, Settings {Music, Sfx, Shake, ReducedEffects, DamageNumbers,
	  Tips} (Config.Settings.Defaults), ReviveTokens, SelectedArena,
	  Achievements {Progress {id → number}, Unlocked {id → os.time()}} (AchievementService),
	  Title (worn achievement title, "" = none), NameColor (AchievementData.Colors id, ""),
	  TutorialDone (first-run tips finished / skipped), SeenTips {tipId → true},
	  Curses {curseId} (the run modifiers last picked in the lobby, CurseData),
	  Endless (boolean: the lobby ENDLESS switch, Config.Endless; old saves: false),
	  Daily {Day, Used, Score, Plays, BestScore, BestDay} (Daily Challenge: today's scored
	  attempt and the best ever score, CurseData.DailyScore),
	  Account {XP, Level} (cosmetic account level, AccountData), Ring, Frame (worn dais
	  ring / portrait frame from the level track, "" = none)

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
local AccountData = require(game:GetService("ReplicatedStorage").Shared.AccountData)

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
		Meta = {},
		OwnedCharacters = { [CharacterData.Default] = true },
		SelectedCharacter = CharacterData.Default,
		Skins = {},
		Stats = { BestTime = 0, TotalKills = 0, Wins = 0, Runs = 0, BestStage = 0, MostKills = 0, BestScore = 0, BestScoreEndless = 0, BestLevel = 0 },
		PurchaseIds = {},
		Settings = table.clone(Config.Settings.Defaults),
		ReviveTokens = 0,
		SelectedArena = "Forest",
		Achievements = { Progress = {}, Unlocked = {} },
		Title = "",
		NameColor = "",
		TutorialDone = false,
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
	no ring / frame worn, Stats.MostKills 0.
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
}

-- Brings any stored table up to the current schema and fills missing fields.
function DataService.Migrate(data: any): { [string]: any }
	if type(data) ~= "table" then
		return defaultData()
	end
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
	if type(data.Stats) ~= "table" then
		data.Stats = defaults.Stats
	end
	for k, v in pairs(defaults.Stats) do
		if type(data.Stats[k]) ~= "number" then
			data.Stats[k] = v
		end
	end
	if type(data.Gold) ~= "number" or data.Gold ~= data.Gold then
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
	data.Version = Config.Data.SchemaVersion
	return data
end

------------------------------------------------------------------------------------------
-- Low-level store access with retry
------------------------------------------------------------------------------------------

local function update(key: string, transform: (any) -> any): (boolean, any)
	if not store then
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

local function loadProfile(player: Player): Profile?
	local key = Config.Data.KeyPrefix .. player.UserId
	for attempt = 1, Config.Data.LoadAttempts do
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
		if attempt < Config.Data.LoadAttempts then
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
	local profile = loadProfile(player)
	if not player.Parent then
		-- left while loading: give the lock back so another server can load at once
		if profile then
			DataService.SaveProfile(profile, true)
		end
		return
	end
	if not profile then
		player:Kick("Your data is still in use by another server. Please wait a minute and rejoin.")
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
	DataService.SaveProfile(profile, true)
	profiles[player] = nil
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
			warn("[DataService] DataStores unavailable, using memory only: " .. tostring(probeErr))
			store = nil
		end
	else
		warn("[DataService] DataStores unavailable, using memory only: " .. tostring(result))
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
