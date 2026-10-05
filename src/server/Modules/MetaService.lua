--[[
	MetaService.lua
	META features (docs/features/META.md), each behind its Config.Features switch:
	  1  Sigils           (Sigils)          drops from bosses / elites, kept on a finished run,
	                                         worn in slots, applied by StatSheet on the server
	  19 Weekly team board (TeamBoard)      Duo / Trio run scores per UTC week (LeaderboardService)
	  21 Weekly challenge  (WeeklyChallenge) a fixed hero + curses per week (RunModifiers), its own
	                                         weekly board and the best in data.Weekly
	  22 Season track      (SeasonTrack)    season XP from clean runs fills tiers: gold or cosmetics
	  23 Titles            (Titles)         milestone titles (data.Titles.Owned), the worn title and
	                                         nameplate frame published for the name plates
	  24 Collection book   (CollectionBook) heroes played / bosses beaten (DiscoveryService)
	  25 Login streak      (LoginStreak)    one claim per UTC day, coins and cosmetics only

	Every grant happens here, on the server, exactly once:
	  * run rewards (Sigils, weekly, team board, season XP, collection) only in CommitRun,
	    which RunManager calls once per run player after its DEV-taint return (a DEV-tainted
	    or DevBoosted run never reaches it);
	  * claims (streak day, season tier) mark the save before paying and refuse a second try
	    (LoginStreak.LastDay, Season.Claimed); the save is force-saved right after.
	Rewards are gold and cosmetics only; nothing here is sold for Robux.

	Remote "Meta" (rate 6/s), lobby only (never while in a run):
	  ("EquipSigil", slot, id | "")  ("ClaimStreak")  ("ClaimSeason", tier | "All")  ("Sync")
	Nameplate frames earned here go into Cosmetics.Owned and are worn through the STORE's
	StoreEquip remote (StoreCatalog lists them as Earned entries).
	Player attributes: "Title" (the worn title, "" = none) while Titles is on (client
	TitlePlates); "Sigils" ("HaresFoot,Lodestar") in a run.
]]

local Players = game:GetService("Players")
local Shared = game:GetService("ReplicatedStorage").Shared

local Config = require(Shared.Config)
local Remotes = require(Shared.Remotes)
local SigilData = require(Shared.SigilData)
local MetaData = require(Shared.MetaData)
local CollectionData = require(Shared.CollectionData)
local CurseData = require(Shared.CurseData)
local MetaUpgradeData = require(Shared.MetaUpgradeData)
local Events = require(script.Parent.Events)

local MetaService = {}

local ctx
local rng = Random.new()
local stepTimer = 0
local publishTimer = 0

local GOOD = Color3.fromRGB(255, 220, 120)
local INFO = Color3.fromRGB(200, 220, 255)
local WARN = Color3.fromRGB(255, 200, 120)

local function on(name: string): boolean
	return Config.FeatureOn(name)
end

local function notify(player: Player, text: string, color: Color3?, id: string?)
	if ctx.RunManager and player.Parent then
		ctx.RunManager.Notify(player, text, color or GOOD, { Id = id or ("meta:" .. string.lower(text)) })
	end
end

local function sync(player: Player)
	if player.Parent and ctx.GoldSystem then
		ctx.GoldSystem.SyncProfile(player)
	end
end

local function save(player: Player)
	if ctx.DataService.ForceSave then
		task.spawn(function()
			pcall(ctx.DataService.ForceSave, player)
		end)
	end
end

local function sub(data: any, key: string): { [string]: any }
	if type(data[key]) ~= "table" then
		data[key] = {}
	end
	return data[key]
end

local function count(t: { [any]: any }): number
	local n = 0
	for _ in pairs(t) do
		n += 1
	end
	return n
end

------------------------------------------------------------------------------------------
-- Cosmetics and titles
------------------------------------------------------------------------------------------

local function titleName(id: string): string
	local def = MetaData.TitleById[id]
	return def and def.Name or (string.gsub(id, "^Title_", ""))
end

local function ownsCosmetic(data, kind: string, id: string): boolean
	if kind == "Title" then
		return type(data.Titles) == "table" and type(data.Titles.Owned) == "table" and data.Titles.Owned[id] == true
	end
	local c = data.Cosmetics
	return type(c) == "table" and type(c.Owned) == "table" and c.Owned[id] == true
end

-- Adds a cosmetic to the save; false when already owned or the set is full.
local function grantCosmetic(data, kind: string, id: string): boolean
	if ownsCosmetic(data, kind, id) then
		return false
	end
	local holder = kind == "Title" and sub(data, "Titles") or sub(data, "Cosmetics")
	if type(holder.Owned) ~= "table" then
		holder.Owned = {}
	end
	if count(holder.Owned) >= Config.Data.Caps.SetEntries then
		return false
	end
	holder.Owned[id] = true
	if kind == "Title" and (data.Title == nil or data.Title == "") then
		data.Title = titleName(id) -- the first title earned is worn at once (as achievements do)
	end
	return true
end

-- Pays a reward ({Kind, Gold?, Id?}); an owned cosmetic pays MetaData.DupeGold instead.
-- Returns the line for the toast.
local function grantReward(data, reward: MetaData.Reward): string
	if reward.Kind == "Gold" then
		local gold = math.max(0, math.floor(reward.Gold or 0))
		data.Gold += gold
		return "+" .. gold .. " gold"
	end
	local id = reward.Id or ""
	if grantCosmetic(data, reward.Kind, id) then
		if reward.Kind == "Title" then
			return "Title: " .. titleName(id)
		end
		local plate = MetaData.NameplateById[id]
		return "Nameplate: " .. (plate and plate.Name or id)
	end
	data.Gold += MetaData.DupeGold
	return "+" .. MetaData.DupeGold .. " gold (already owned)"
end

-- META titles: the worn title text `name` is owned through data.Titles (Titles switch on).
function MetaService.OwnsTitle(data, name: string): boolean
	if not on("Titles") or type(name) ~= "string" then
		return false
	end
	return ownsCosmetic(data, "Title", MetaData.TitleId(name))
end

local function earnTitle(player: Player, data, id: string)
	if not on("Titles") or data.DevBoosted == true then
		return
	end
	if grantCosmetic(data, "Title", id) then
		notify(player, "Title earned: " .. titleName(id) .. "!", GOOD, "meta.title." .. id)
	end
end

-- Milestone titles that follow from the save (collection, Sigils owned).
local function checkTitles(player: Player, data)
	if not on("Titles") then
		return
	end
	if on("CollectionBook") then
		local seen, total = CollectionData.Progress(data)
		if total > 0 and seen * 2 >= total then
			earnTitle(player, data, "Title_Collector")
		end
		if total > 0 and seen >= total then
			earnTitle(player, data, "Title_Archivist")
		end
	end
	if on("Sigils") then
		local owned = count(sub(sub(data, "Sigils"), "Owned"))
		if owned >= 6 then
			earnTitle(player, data, "Title_Sigil Seeker")
		end
		if owned >= #SigilData.Order then
			earnTitle(player, data, "Title_Sigil Keeper")
		end
	end
end

-- The player attribute the name plates read ("Title": the worn title, "" = none). The
-- frame of the plate is the STORE's worn Nameplate (attribute CosPlate, StoreService).
local function publish(player: Player)
	local data = ctx.DataService.GetData(player)
	local title = nil
	if data and on("Titles") then
		title = type(data.Title) == "string" and data.Title or ""
	end
	if player:GetAttribute("Title") ~= title then
		player:SetAttribute("Title", title)
	end
end

------------------------------------------------------------------------------------------
-- Season track
------------------------------------------------------------------------------------------

--[[
	The running season (or nil), with the save's track moved to it. A new season id starts
	a new track; tiers reached in the old one but never claimed are paid first (once: they
	are marked claimed before the track is replaced).
]]
local function ensureSeason(player: Player?, data): MetaData.Season?
	local season = MetaData.Season(os.time())
	if not season then
		return nil
	end
	local S = sub(data, "Season")
	if S.Id ~= season.Id then
		if type(S.Id) == "string" and S.Id ~= "" then
			local claimed = type(S.Claimed) == "table" and S.Claimed or {}
			local lines = {}
			for tier = 1, MetaData.TierFor(tonumber(S.XP) or 0) do
				if not claimed[tostring(tier)] then
					claimed[tostring(tier)] = true
					table.insert(lines, grantReward(data, MetaData.SeasonReward(tier)))
				end
			end
			if player and #lines > 0 then
				notify(player, "Last season's unclaimed rewards: " .. table.concat(lines, ", "), GOOD, "meta.season.rollover")
			end
		end
		data.Season = { Id = season.Id, XP = 0, Claimed = {} }
	end
	if type(data.Season.Claimed) ~= "table" then
		data.Season.Claimed = {}
	end
	return season
end

local function claimSeason(player: Player, data, which: any)
	if not on("SeasonTrack") then
		return
	end
	local season = ensureSeason(player, data)
	if not season then
		notify(player, "No season is running right now.", WARN, "meta.season.none")
		return
	end
	local S = data.Season
	local reached = MetaData.TierFor(S.XP)
	local tiers = {}
	if which == "All" then
		for tier = 1, reached do
			table.insert(tiers, tier)
		end
	elseif type(which) == "number" and which == which and which % 1 == 0 and which >= 1 and which <= MetaData.SeasonTiers() then
		if which > reached then
			notify(player, "Reach that tier first.", WARN, "meta.season.locked")
			return
		end
		tiers = { which }
	else
		return
	end
	local lines = {}
	for _, tier in ipairs(tiers) do
		local key = tostring(tier)
		if not S.Claimed[key] and count(S.Claimed) < Config.Data.Caps.SeasonClaims then
			S.Claimed[key] = true -- marked before paying: a second claim finds it taken
			table.insert(lines, grantReward(data, MetaData.SeasonReward(tier)))
		end
	end
	if #lines == 0 then
		notify(player, "Nothing to claim yet.", INFO, "meta.season.nothing")
		return
	end
	notify(player, "Season rewards: " .. table.concat(lines, ", "), GOOD, "meta.season.claim")
	checkTitles(player, data)
	save(player)
	sync(player)
end

------------------------------------------------------------------------------------------
-- Login streak
------------------------------------------------------------------------------------------

function MetaService.Today(): number
	return CurseData.DayOf(os.time())
end

local function claimStreak(player: Player, data)
	if not on("LoginStreak") then
		return
	end
	local L = sub(data, "LoginStreak")
	local today = MetaService.Today()
	local can, streak = MetaData.StreakNext(tonumber(L.LastDay) or 0, tonumber(L.Day) or 0, today)
	if not can then
		notify(player, "Already claimed today. Come back tomorrow!", INFO, "meta.streak.done")
		return
	end
	-- the claim is recorded before anything is paid: one claim per UTC day
	L.LastDay = today
	L.Day = streak
	L.Best = math.max(tonumber(L.Best) or 0, streak)
	local gold = MetaData.StreakGold(streak)
	data.Gold += gold
	local lines = { "+" .. gold .. " gold" }
	for _, m in ipairs(MetaData.StreakMilestones) do
		if streak >= m.Day and not ownsCosmetic(data, m.Kind, m.Id) then
			table.insert(lines, grantReward(data, { Kind = m.Kind, Id = m.Id }))
		end
	end
	notify(player, string.format("Day %d streak: %s", streak, table.concat(lines, ", ")), GOOD, "meta.streak.claim")
	checkTitles(player, data)
	save(player)
	sync(player)
end

------------------------------------------------------------------------------------------
-- Sigils
------------------------------------------------------------------------------------------

function MetaService.SigilSlots(data): number
	return SigilData.SlotsFor(data, function(xp: number): number
		return (MetaUpgradeData.MasteryFor(xp))
	end)
end

local function equipSigil(player: Player, data, slot: any, id: any)
	if not on("Sigils") then
		return
	end
	local slots = MetaService.SigilSlots(data)
	if type(slot) ~= "number" or slot ~= slot or slot % 1 ~= 0 or slot < 1 or slot > Config.Data.Caps.SigilSlots then
		return
	end
	if slot > slots then
		notify(player, "Slot 2 opens when any hero reaches Mastery " .. SigilData.SlotUnlockMastery .. ".", WARN, "meta.sigil.slot")
		return
	end
	if type(id) ~= "string" then
		return
	end
	local S = sub(data, "Sigils")
	local owned = type(S.Owned) == "table" and S.Owned or {}
	if id ~= "" and (not SigilData.Sigils[id] or owned[id] == nil) then
		return
	end
	-- the slots as positions (the save keeps the worn ids in slot order, no gaps)
	local worn = {}
	for i = 1, slots do
		local cur = type(S.Equipped) == "table" and S.Equipped[i] or nil
		worn[i] = (type(cur) == "string" and SigilData.Sigils[cur] and owned[cur] ~= nil) and cur or ""
	end
	for i = 1, slots do
		if worn[i] == id then
			worn[i] = "" -- moved from the other slot
		end
	end
	worn[slot] = id
	local list = {}
	for i = 1, slots do
		if worn[i] ~= "" and not table.find(list, worn[i]) then
			table.insert(list, worn[i])
		end
	end
	S.Equipped = list
	sync(player)
end

-- A Sigil drop roll for this run player (boss / elite). Returns the id found, or nil.
local function roll(rp, chance: number, source: string): string?
	if not on("Sigils") or rp.DevTainted or rp.Daily or rp.Weekly or rp.Returned then
		return nil
	end
	if rng:NextNumber() >= chance then
		return nil
	end
	local id = SigilData.Roll(rng)
	rp.SigilFound = rp.SigilFound or {}
	table.insert(rp.SigilFound, id)
	notify(rp.Player, string.format("Sigil found: %s! Finish the run to keep it.", SigilData.Sigils[id].Name), Color3.fromRGB(200, 170, 255), "meta.sigil.found." .. source)
	return id
end

-- EnemySpawner: an elite (not a guard, not a wave elite) killed by this run player.
function MetaService.OnEliteKilled(rp)
	if (rp.EliteSigils or 0) >= SigilData.ElitePerRun then
		return
	end
	if roll(rp, SigilData.EliteChance, "elite") then
		rp.EliteSigils = (rp.EliteSigils or 0) + 1
	end
end

-- LootSystem: `price` run gold was paid at a chest / shrine (Haggler's Coin pays part back).
function MetaService.OnGoldPaid(rp, price: number)
	local share = 0
	for id in pairs(rp.Sigils or {}) do
		local special = SigilData.Sigils[id] and SigilData.Sigils[id].Special
		if special and special.ChestRefund then
			share = math.max(share, special.ChestRefund)
		end
	end
	local back = math.floor((tonumber(price) or 0) * share)
	if back <= 0 or not on("Sigils") then
		return
	end
	local data = ctx.DataService.GetData(rp.Player)
	if not data or type(data.RunEscrow) ~= "table" or rp.GoldSettlement then
		return
	end
	data.RunEscrow.Gold += back
	rp.Gold += back
	rp.GoldSpent = math.max(0, (rp.GoldSpent or 0) - back)
	rp.Player:SetAttribute("RunGold", rp.Gold)
end

------------------------------------------------------------------------------------------
-- Run hooks (RunManager)
------------------------------------------------------------------------------------------

-- The hero a run of `mode` plays: the Weekly Challenge's lent hero, or nil (the selected one).
function MetaService.RunHero(mode: string, _data): string?
	if mode == MetaData.WeeklyMode and on("WeeklyChallenge") then
		return MetaData.Weekly(MetaData.WeekOf(os.time())).Hero
	end
	return nil
end

-- A run player was just created (after its start weapon and RunModifiers' setup).
function MetaService.SetupRunPlayer(rp, mode: string, list: { Player })
	local ids = {}
	for _, p in ipairs(list) do
		table.insert(ids, p.UserId)
	end
	rp.MetaMode = mode
	rp.MetaTeam = ids
	rp.SigilFound = {}
	rp.EliteSigils = 0
	rp.Sigils = nil
	rp.SigilAlone = #list <= 1
	rp.Player:SetAttribute("Sigils", nil)
	local data = ctx.DataService.GetData(rp.Player)
	-- the Daily and the Weekly are the same setup for everyone: no Sigils
	if not data or not on("Sigils") or rp.Daily or rp.Weekly then
		return
	end
	local worn = SigilData.Set(type(data.Sigils) == "table" and data.Sigils.Equipped or nil, MetaService.SigilSlots(data))
	local owned = type(data.Sigils) == "table" and type(data.Sigils.Owned) == "table" and data.Sigils.Owned or {}
	local names = {}
	for id in pairs(worn) do
		if owned[id] == nil then
			worn[id] = nil
		else
			table.insert(names, id)
		end
	end
	if #names == 0 then
		return
	end
	table.sort(names)
	rp.Sigils = worn
	rp.Player:SetAttribute("Sigils", table.concat(names, ","))
	for id in pairs(worn) do
		local special = SigilData.Sigils[id].Special
		if special and special.StartWeapon and not rp.Weapons[special.StartWeapon] then
			ctx.LevelUpSystem.AddWeapon(rp, special.StartWeapon)
		end
		if special and special.FewerFirst then
			rp.SigilFewerFirst = true
		end
	end
end

--[[
	A clean run is committed (RunManager.saveRunStats, once per run player, after the
	DEV-taint return). info = { Won, Score, Cleared, AccountXP, Mode }. Returns the results
	data { Sigils = {{Id, Kept, Gold}}, Weekly?, Season? } or nil.
]]
function MetaService.CommitRun(rp, info: { [string]: any }): { [string]: any }?
	local player: Player = rp.Player
	local data = ctx.DataService.GetData(player)
	if not data or rp.DevTainted then
		return nil
	end
	local out: { [string]: any } = {}
	local score = math.max(0, math.floor(tonumber(info.Score) or 0))
	local cleared = math.max(0, math.floor(tonumber(info.Cleared) or 0))

	-- Sigils found this run: kept on a win / portal, else KeepOnLoss of the time
	local found = rp.SigilFound or {}
	rp.SigilFound = {}
	if #found > 0 and on("Sigils") then
		local keep = info.Won == true or rp.Extracted == true or rng:NextNumber() < SigilData.KeepOnLoss
		local S = sub(data, "Sigils")
		if type(S.Owned) ~= "table" then
			S.Owned = {}
		end
		out.Sigils = {}
		for _, id in ipairs(found) do
			local def = SigilData.Sigils[id]
			local line = { Id = id, Kept = keep, Gold = 0 }
			if keep and def then
				if S.Owned[id] ~= nil or count(S.Owned) >= Config.Data.Caps.Sigils then
					line.Gold = SigilData.DupeGold[def.Rarity] or 0
					data.Gold += line.Gold
					notify(player, string.format("%s again: +%d gold.", def.Name, line.Gold), GOOD, "meta.sigil.dupe." .. id)
				else
					S.Owned[id] = os.time()
					notify(player, "New Sigil: " .. def.Name .. "! Wear it from PLAY.", Color3.fromRGB(200, 170, 255), "meta.sigil.new." .. id)
				end
			elseif def then
				notify(player, "The " .. def.Name .. " Sigil was lost.", WARN, "meta.sigil.lost." .. id)
			end
			table.insert(out.Sigils, line)
		end
	end

	-- the Weekly Challenge: the week's best in the save and its board
	if rp.Weekly and on("WeeklyChallenge") then
		local W = sub(data, "Weekly")
		local week = tonumber(rp.WeeklyWeek) or MetaData.WeekOf(os.time())
		if W.Week ~= week then
			W.Week = week
			W.Score = 0
			W.Plays = 0
		end
		W.Plays = (tonumber(W.Plays) or 0) + 1
		local before = tonumber(W.Score) or 0
		W.Score = math.max(before, score)
		local newBest = false
		if score > (tonumber(W.BestScore) or 0) then
			W.BestScore = score
			W.BestWeek = week
			newBest = true
		end
		out.Weekly = { Week = week, Score = score, WeekBest = W.Score, NewWeekBest = score > before, NewBest = newBest }
		ctx.LeaderboardService.Submit(player, "Weekly", score, week, rp.RunId)
		notify(player, string.format("Weekly challenge: %s points%s", tostring(score), score > before and " (week best!)" or ""), GOOD, "meta.weekly.score")
		if cleared >= 3 then
			earnTitle(player, data, "Title_Weekly Warrior")
		end
	end

	-- the weekly team board: Duo / Trio runs with their whole starting team
	local team = rp.MetaTeam or {}
	if on("TeamBoard") and (rp.MetaMode == "Duo" or rp.MetaMode == "Trio") and #team == (rp.MetaMode == "Duo" and 2 or 3) then
		ctx.LeaderboardService.SubmitTeam(#team == 2 and "TeamDuo" or "TeamTrio", team, score, MetaData.WeekOf(os.time()), rp.RunId, player.UserId)
		if cleared >= 3 then
			earnTitle(player, data, "Title_Brothers in Arms")
		end
	end

	-- the season track: the account XP this run gave
	if on("SeasonTrack") then
		local season = ensureSeason(player, data)
		local gained = math.max(0, math.floor(tonumber(info.AccountXP) or 0))
		if season and gained > 0 then
			local before = MetaData.TierFor(data.Season.XP)
			data.Season.XP = math.min((tonumber(data.Season.XP) or 0) + gained, MetaData.SeasonTiers() * MetaData.SeasonXPPerTier()) -- no XP past the last tier
			local after = MetaData.TierFor(data.Season.XP)
			out.Season = { Gained = gained, From = before, To = after }
			if after > before then
				notify(player, string.format("Season tier %d reached! Claim it in MORE.", after), GOOD, "meta.season.tier")
			end
		end
	end

	-- the collection book: the hero played
	if on("CollectionBook") and ctx.DiscoveryService and type(rp.CharacterId) == "string" then
		ctx.DiscoveryService.RecordCollection(player, "Hero:" .. rp.CharacterId)
	end
	checkTitles(player, data)
	return out
end

------------------------------------------------------------------------------------------
-- Remote, lifecycle
------------------------------------------------------------------------------------------

local function onMeta(player: Player, action: any, a: any, b: any)
	local data = ctx.DataService.GetData(player)
	if not data or type(action) ~= "string" then
		return
	end
	if action == "Sync" then
		sync(player)
		return
	end
	-- equips and claims only from the lobby (a run never changes them)
	if ctx.RunManager.IsParticipant(player) then
		return
	end
	if action == "EquipSigil" then
		equipSigil(player, data, a, b)
	elseif action == "ClaimStreak" then
		claimStreak(player, data)
	elseif action == "ClaimSeason" then
		claimSeason(player, data, a)
	end
end

-- Lone Wolf (every 0.5 s) and the name plate attributes (every second).
function MetaService.Step(dt: number)
	stepTimer += dt
	publishTimer += dt
	if stepTimer >= 0.5 then
		stepTimer = 0
		if on("Sigils") and ctx.RunManager.IsRunning() then
			local list = ctx.RunManager.GetRunPlayers()
			for _, rp in ipairs(list) do
				if rp.Sigils and rp.Sigils.LoneWolf and rp.Root then
					local alone = true
					for _, other in ipairs(list) do
						if other ~= rp and other.Alive and not other.Returned and other.Root
							and (other.Root.Position - rp.Root.Position).Magnitude <= SigilData.LoneWolfRange then
							alone = false
						end
					end
					if alone ~= rp.SigilAlone then
						rp.SigilAlone = alone
						ctx.LevelUpSystem.RecomputeStats(rp)
					end
				end
			end
		end
	end
	if publishTimer >= 1 then
		publishTimer = 0
		for _, player in ipairs(Players:GetPlayers()) do
			publish(player)
		end
	end
end

function MetaService.Init(c)
	ctx = c
end

function MetaService.Start()
	Remotes.Listen("Meta", onMeta, 6)
	Events.On("BossKilled", function(player)
		local rp = ctx.RunManager.GetRunPlayer(player)
		if rp then
			roll(rp, SigilData.BossChance, "boss")
		end
	end)
	Events.On("BossDefeated", function(player, payload)
		if type(payload.Boss) == "string" and ctx.DiscoveryService then
			ctx.DiscoveryService.RecordCollection(player, "Boss:" .. payload.Boss)
		end
	end)
	ctx.DataService.OnProfileLoaded(function(player)
		local data = ctx.DataService.GetData(player)
		if data and on("SeasonTrack") then
			ensureSeason(player, data)
		end
		publish(player)
	end)
end

return MetaService
