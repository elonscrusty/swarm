-- safety-sim: security, purchases and persistence against the real server modules.
-- Runs WITHOUT --studio (a live-server mock: DevAccess must treat the test player as an
-- ordinary user). Every check errors on failure; each section logs PASS.
--   1) every client->server remote survives malformed payloads (no handler error, no
--      change to gold / unlocks / upgrades / settings), in the lobby and in a run
--   2) rate limits and stale double taps never buy twice
--   3) DEV commands and the DEV inbox are refused for an ordinary user (and taint nothing);
--      an allowlisted UserId is accepted
--   4) developer-product receipts: grant once, repeated callbacks, failed save + retry,
--      unknown product, absent player, released (teleporting) profile
--   5) revive: decline, expiry, purchase after the run ended (token kept), token spent on
--      the next fall, one product revive per run, purchase while waiting
--   6) persistence: first load, returning load, schema 0 -> 7 migration, duplicate
--      session (fresh lock refused, stale lock taken), failed save + retry, lost lock,
--      settings saved and reloaded
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local player = Players.LocalPlayer
assert(not RunService:IsStudio(), "safety-sim must run without --studio (live-server DEV rules)")

preview.startServer()
preview.advance(1)
local Config = preview.shared("Config")
local Remotes = preview.shared("Remotes")
local CharacterData = preview.shared("CharacterData")
local RM = preview.server("RunManager")
local DS = preview.server("DataService")
local GS = preview.server("GoldSystem")
local MS = preview.server("MonetizationService")
local DevAccess = preview.server("DevAccess")

local data = assert(DS.GetData(player), "profile missing")
data.Gold = 5000
-- A handler error is only a warning (Remotes.Listen pcalls handlers): tools/run_regressions.py
-- fails any scene whose output contains "handler error", which covers the fuzzing below.
local function deepCopy(t)
	if type(t) ~= "table" then
		return t
	end
	local out = {}
	for k, v in pairs(t) do
		out[k] = deepCopy(v)
	end
	return out
end
local function same(a, b): boolean
	if type(a) ~= type(b) then
		return false
	end
	if type(a) ~= "table" then
		return a == b or (a ~= a and b ~= b)
	end
	for k, v in pairs(a) do
		if not same(v, b[k]) then
			return false
		end
	end
	for k in pairs(b) do
		if a[k] == nil then
			return false
		end
	end
	return true
end
local GUARDED = { "Gold", "OwnedCharacters", "Meta", "HeroUpgrades", "Heroes", "Settings", "Skins", "ReviveTokens", "PurchaseIds", "Stats", "Difficulty", "Curses", "Title", "NameColor", "Ring", "Frame", "Account" }
local function snapshot()
	local s = {}
	for _, key in ipairs(GUARDED) do
		s[key] = deepCopy(data[key])
	end
	return s
end
local function assertUnchanged(before, label)
	for _, key in ipairs(GUARDED) do
		assert(same(before[key], data[key]), label .. ": " .. key .. " changed")
	end
end

------------------------------------------------------------------------------------------
-- 1) malformed payloads on every client -> server remote
------------------------------------------------------------------------------------------
local part = Instance.new("Part")
local JUNK = {
	{}, { true }, { 0 / 0 }, { math.huge }, { -math.huge }, { -1 }, { 1e308 }, { 2 ^ 53 }, { "" },
	{ string.rep("x", 5000) }, { {} }, { { 1, 2, 3 } }, { { Gold = 1e9, Music = 0 / 0 } }, { Vector3.new(1e9, 0, 0) },
	{ part }, { "Solo", 0 / 0 }, { 0 / 0, 0 / 0, 0 / 0 }, { "Knight", "MaxHP", -1 }, { "Knight", "MaxHP", 0 / 0 },
	{ "__index" }, { "Page", { cursor = true } }, { "SetStatus", 1, "Fixed" }, { "Invite", 0 / 0 }, { "Title", string.rep("y", 41) },
}
-- AbandonRun takes no argument: any call is a real "leave the run" (checked on its own)
local function fuzzAll(label, skip)
	local before = snapshot()
	local inRunBefore = RM.IsParticipant(player)
	for _, name in ipairs(Remotes.ClientToServer) do
		if skip and skip[name] then
			continue
		end
		for _, args in ipairs(JUNK) do
			preview.remote(name):FireServer(table.unpack(args, 1, 3))
		end
		preview.advance(0.6) -- refill the per-remote token bucket
	end
	preview.advance(1)
	assertUnchanged(before, label)
	assert(RM.IsParticipant(player) == inRunBefore, label .. ": junk changed the run membership")
	preview.log(string.format("PASS %d remotes x %d malformed payloads (%s): save unchanged", #Remotes.ClientToServer, #JUNK, label))
end
fuzzAll("lobby")

------------------------------------------------------------------------------------------
-- 2) rate limits and stale taps
------------------------------------------------------------------------------------------
do
	data.Gold = 1e6
	local level = data.Meta.Reroll or 0
	for _ = 1, 20 do
		preview.remote("BuyMeta"):FireServer("Reroll", level) -- the level the client saw
	end
	preview.advance(1)
	assert((data.Meta.Reroll or 0) == level + 1, "20 taps with the same seen level must buy exactly one level")
	data.Meta.Reroll = level
	local spent = data.Gold
	for _ = 1, 40 do
		preview.remote("BuyMeta"):FireServer("Reroll") -- no level: only the rate limit holds
	end
	assert((data.Meta.Reroll or 0) - level <= 4, "40 taps in one frame must be cut by the 4/s limit")
	assert(data.Gold <= spent, "gold can only go down when buying")
	data.Meta.Reroll = level ~= 0 and level or nil
	preview.advance(2)
	local owned = data.HeroUpgrades.Knight and data.HeroUpgrades.Knight.MaxHP or 0
	for _ = 1, 10 do
		preview.remote("BuyHeroUpgrade"):FireServer("Knight", "MaxHP", owned)
	end
	preview.advance(1)
	assert((data.HeroUpgrades.Knight and data.HeroUpgrades.Knight.MaxHP or 0) <= owned + 1, "a hero upgrade double tap must buy at most one level")
	-- a character costs its server price; an achievement hero cannot be bought
	data.Gold = 100
	preview.remote("BuyCharacter"):FireServer("Mage")
	assert(not data.OwnedCharacters.Mage and data.Gold == 100, "short gold must refuse a hero")
	for id, def in pairs(CharacterData.Characters) do
		if def.Unlock then
			data.Gold = 1e7
			preview.advance(1)
			preview.remote("BuyCharacter"):FireServer(id)
			assert(not data.OwnedCharacters[id] and data.Gold == 1e7, "achievement hero " .. id .. " must never be sold")
			break
		end
	end
	data.Gold = 5000
	preview.log("PASS rate limits, stale-level double taps, short gold and earned-only heroes")
end

------------------------------------------------------------------------------------------
-- 3) DEV tools for an ordinary user
------------------------------------------------------------------------------------------
do
	assert(not DevAccess.IsDev(player), "the test player (UserId " .. player.UserId .. ") must not be a developer")
	assert(player:GetAttribute("DevAccess") ~= true, "no DevAccess attribute for ordinary users")
	assert(not RM.IsDev(player), "RunManager must agree")
	local before = snapshot()
	for _, cmd in ipairs({ "UnlockAll", "LobbyGold", "AccountLevels", "ResetProgress", "DamageNumbers", "God", "StartSolo" }) do
		preview.remote("DevCommand"):FireServer(cmd, cmd == "ResetProgress" and "CONFIRM" or 1000000)
		preview.advance(0.3)
	end
	assertUnchanged(before, "DEV commands from an ordinary user")
	assert(player:GetAttribute("DevGod") == nil, "God must not toggle for an ordinary user")
	assert(not RM.IsParticipant(player), "StartSolo must not start a run for an ordinary user")
	local inboxAnswers = 0
	Remotes.Get("BugInboxData").OnClientEvent:Connect(function()
		inboxAnswers += 1
	end)
	preview.remote("BugInbox"):FireServer("Page")
	preview.remote("BugInbox"):FireServer("SetStatus", "x", "Fixed")
	preview.advance(1)
	assert(inboxAnswers == 0, "the DEV bug inbox must not answer an ordinary user")
	preview.log("PASS DEV commands, God and the bug inbox refused server-side for an ordinary user")
end

------------------------------------------------------------------------------------------
-- 4) developer-product receipts
------------------------------------------------------------------------------------------
local Decision = Enum.ProductPurchaseDecision
local products = Config.Monetization.Products
local nextPurchase = 0
local function receipt(productId, who, purchaseId)
	nextPurchase += 1
	return MS._ProcessReceipt({
		PlayerId = (who or player).UserId,
		ProductId = productId,
		PurchaseId = purchaseId or ("test-" .. nextPurchase),
		CurrencySpent = 0,
		PlaceIdWherePurchased = 0,
	})
end
do
	assert(products.Gold500 ~= 0 and products.Revive ~= 0, "products must be configured for this test")
	local gold = data.Gold
	assert(receipt(products.Gold500, nil, "p-1") == Decision.PurchaseGranted, "a gold product must be granted")
	assert(data.Gold == gold + 500, "Gold500 adds 500")
	for _ = 1, 3 do
		assert(receipt(products.Gold500, nil, "p-1") == Decision.PurchaseGranted, "a repeated callback is acknowledged")
	end
	assert(data.Gold == gold + 500, "a repeated callback must never grant twice")
	-- failed save: granted in memory, NOT acknowledged; the retry acknowledges without a second grant
	preview.failDataStores(false, true)
	Config.Data.SaveAttempts = 1
	assert(receipt(products.Gold1500, nil, "p-2") == Decision.NotProcessedYet, "an unsaved grant must not be acknowledged")
	assert(data.Gold == gold + 2000, "the grant is held in memory")
	assert(player:GetAttribute("SaveStatus") == "failing", "a failed save must show as failing")
	assert(receipt(products.Gold1500, nil, "p-2") == Decision.NotProcessedYet, "still failing: still not acknowledged")
	preview.failDataStores(false, false)
	assert(receipt(products.Gold1500, nil, "p-2") == Decision.PurchaseGranted, "after recovery the retry is acknowledged")
	assert(data.Gold == gold + 2000, "the retry must not grant again")
	assert(player:GetAttribute("SaveStatus") == "ok", "a good save clears the failing status")
	-- unknown product, malformed info, absent player
	assert(receipt(123456789) == Decision.NotProcessedYet, "an unknown product is never acknowledged")
	assert(MS._ProcessReceipt(nil) == Decision.NotProcessedYet and MS._ProcessReceipt({ PlayerId = "x" }) == Decision.NotProcessedYet, "malformed receipt info")
	local ghost = { UserId = 987654321 }
	assert(receipt(products.Gold500, ghost) == Decision.NotProcessedYet, "a player who left: Roblox retries on their next join")
	assert(data.Gold == gold + 2000, "nothing else granted")
	-- a pass-purchase signal only counts for this game's configured passes
	assert(MS.IsConfiguredPass(Config.Monetization.GamePasses.VIP), "VIP is a configured pass")
	assert(not MS.IsConfiguredPass(0) and not MS.IsConfiguredPass(424242) and not MS.IsConfiguredPass("VIP") and not MS.IsConfiguredPass(nil), "unknown pass ids are ignored")
	preview.log("PASS receipts: once per PurchaseId, repeated callbacks, failed save + retry, unknown product, absent player")
end

------------------------------------------------------------------------------------------
-- 6) persistence (other players: their own keys in the mock live store)
------------------------------------------------------------------------------------------
local store = game:GetService("DataStoreService"):GetDataStore(Config.Data.StoreName)
local function keyOf(userId)
	return Config.Data.KeyPrefix .. userId
end
local function join(name, userId)
	local p = preview.addPlayer(name, userId)
	preview.playerJoined(p)
	preview.advance(0.5)
	return p
end
do
	-- first load: no record -> current schema defaults; the record is locked by us
	local newbie = join("Newbie", 50001)
	local d = assert(DS.GetData(newbie), "a first load must create a profile")
	assert(d.Version == Config.Data.SchemaVersion and d.Gold == 0 and d.OwnedCharacters[CharacterData.Default], "fresh save at the current schema")
	-- settings: valid values saved, junk ignored, everything survives leave + rejoin
	preview.fireServerAs(newbie, "SaveSettings", { Music = 0.25, Shake = 0.83, ReducedEffects = true, Colorblind = "Tritanopia", TouchLayout = "LeftHanded", Minimap = false, Sfx = "loud", Tips = 1, CombatVolume = 7 })
	assert(d.Settings.Music == 0.25 and d.Settings.Shake == 0.83 and d.Settings.ReducedEffects == true, "valid settings saved")
	assert(d.Settings.Sfx == Config.Settings.Defaults.Sfx and d.Settings.Tips == true and d.Settings.CombatVolume == 1, "junk settings ignored, numbers clamped")
	d.Gold = 4242
	preview.removePlayer(newbie)
	preview.advance(0.5)
	local record = store:GetAsync(keyOf(50001))
	assert(record and record.Lock == nil and record.Data.Gold == 4242, "leaving saves and releases the lock")
	local back = join("Newbie", 50001)
	local d2 = assert(DS.GetData(back), "returning load")
	assert(d2.Gold == 4242 and d2.Settings.Shake == 0.83 and d2.Settings.Colorblind == "Tritanopia" and d2.Settings.TouchLayout == "LeftHanded" and d2.Settings.Minimap == false, "a returning player keeps gold and settings")
	preview.removePlayer(back)
	preview.advance(0.5)
	preview.log("PASS first load, returning load, settings persistence")

	-- schema 0 -> current
	store:SetAsync(keyOf(50002), { Data = { Gold = 77, OwnedCharacters = { "Knight", "Mage" }, Meta = { MaxHP = 3 } } })
	local old = join("Oldtimer", 50002)
	local d3 = assert(DS.GetData(old), "old save loads")
	assert(d3.Version == Config.Data.SchemaVersion and d3.Gold == 77 and d3.OwnedCharacters.Mage == true, "v0 save migrates, keeps gold and heroes")
	assert(d3.HeroUpgrades.ruckus.MaxHP == 3 and d3.Meta.MaxHP == 3, "shared stat levels copied to heroes, Meta kept")
	for k, v in pairs(Config.Settings.Defaults) do
		assert(d3.Settings[k] ~= nil and type(d3.Settings[k]) == type(v), "migrated settings key " .. k)
	end
	preview.removePlayer(old)
	preview.advance(0.5)
	preview.log("PASS schema 0 -> " .. Config.Data.SchemaVersion .. " migration through the live load path")

	-- duplicate session: a fresh lock held by another server refuses the load (kick) and
	-- writes nothing; a stale lock (crashed server) is taken over with the data kept
	Config.Data.LoadAttempts = 1
	store:SetAsync(keyOf(50003), { Data = { Version = 7, Gold = 900 }, Lock = { JobId = "other-server", Time = os.time() } })
	local dup = join("Twin", 50003)
	assert(DS.GetData(dup) == nil, "a save locked by another live server must not load here")
	local r3 = store:GetAsync(keyOf(50003))
	assert(r3.Lock.JobId == "other-server" and r3.Data.Gold == 900, "the other server's lock and data are untouched")
	preview.removePlayer(dup)
	store:SetAsync(keyOf(50004), { Data = { Version = 7, Gold = 901 }, Lock = { JobId = "crashed-server", Time = os.time() - Config.Data.LockStaleSeconds - 5 } })
	local stale = join("Phoenix", 50004)
	assert(DS.GetData(stale) and DS.GetData(stale).Gold == 901, "a stale lock is taken over and the data kept")
	-- lost lock: another server took the save while we hold it -> stop writing (no overwrite)
	local r4 = store:GetAsync(keyOf(50004))
	r4.Lock = { JobId = "thief-server", Time = os.time() }
	r4.Data.Gold = 12345
	store:SetAsync(keyOf(50004), r4)
	DS.GetData(stale).Gold = 1
	assert(not DS.ForceSave(stale), "a save after the lock was lost must fail")
	assert(DS.GetProfile(stale).LockLost, "the profile is marked lock-lost")
	assert(store:GetAsync(keyOf(50004)).Data.Gold == 12345, "the other server's newer data must not be overwritten")
	assert(not DS.ForceSave(stale), "no later save either")
	preview.removePlayer(stale)
	preview.advance(0.5)
	assert(store:GetAsync(keyOf(50004)).Data.Gold == 12345, "leaving must not overwrite it either")
	-- a receipt for a profile handed off to another server (teleport) is left for that server
	store:SetAsync(keyOf(50005), nil)
	local traveller = join("Traveller", 50005)
	local td = assert(DS.GetData(traveller), "traveller profile")
	assert(DS.ReleaseForTeleport(traveller), "handoff release")
	local g = td.Gold
	assert(receipt(products.Gold500, traveller, "t-1") == Decision.NotProcessedYet and td.Gold == g, "a released profile must not take a grant")
	assert(DS.Reclaim(traveller), "a failed teleport reclaims the save")
	assert(receipt(products.Gold500, traveller, "t-1") == Decision.PurchaseGranted and td.Gold == g + 500, "after reclaim the receipt is granted once")
	preview.removePlayer(traveller)
	preview.advance(0.5)
	Config.Data.LoadAttempts = 6
	preview.log("PASS duplicate session refused, stale lock taken, lost lock never overwrites, teleport handoff receipts")

	-- an allowlisted UserId (the owner) is a developer on a live server
	local DevAllowlist = preview.server("DevAllowlist")
	local ownerId = next(DevAllowlist)
	if ownerId then
		local owner = join("Owner", ownerId)
		assert(DevAccess.IsDev(owner), "an allowlisted UserId is a developer")
		local od = assert(DS.GetData(owner), "owner profile")
		local before = od.Gold
		preview.fireServerAs(owner, "DevCommand", "LobbyGold", 10)
		assert(od.Gold == before + 10, "the allowlisted developer's command runs")
		preview.removePlayer(owner)
		preview.advance(0.5)
		store:SetAsync(keyOf(ownerId), nil) -- mock store only
		preview.log("PASS allowlisted developer accepted (positive control)")
	end
end

------------------------------------------------------------------------------------------
-- 5) revive product flow (solo runs)
------------------------------------------------------------------------------------------
local function startSolo()
	preview.advance(Config.Run.ResultsSeconds + 2)
	assert(not RM.IsParticipant(player), "back in the lobby before a new run")
	preview.remote("StartRun"):FireServer("Solo")
	preview.advance(3)
	local rp = assert(RM.GetRunPlayer(player), "run player missing")
	rp.RevivesLeft = 0
	rp.InvulnUntil = 0
	return rp
end
local function fall(rp)
	rp.InvulnUntil = 0
	rp.HitProtectUntil = 0 -- stream E1: a fall right after another hit is not inside the shared 0.35 s window
	rp.Paused, rp.RewardUntil = false, nil
	RM.DamagePlayer(rp, 1e7, "test")
end
do
	data.ReviveTokens = 0
	-- fuzz again inside a live run
	local rp = startSolo()
	fuzzAll("run", { AbandonRun = true })
	preview.remote("SetPause"):FireServer(false) -- the junk included a real SetPause(true)
	preview.advance(0.5)
	assert(not RM.IsDevTainted(player), "junk DevCommand must not taint the run")
	-- decline: the run ends, a purchase that completes afterwards is kept as a token
	fall(rp)
	assert(rp.AwaitingRevive and not rp.Alive, "falling with the product configured offers the revive")
	preview.remote("ReviveDecline"):FireServer()
	preview.advance(1)
	assert(not rp.AwaitingRevive and not RM.IsSimulating(), "decline ends the solo run")
	assert(receipt(products.Revive, nil, "r-1") == Decision.PurchaseGranted, "a late revive purchase is acknowledged")
	preview.advance(0.5)
	assert(data.ReviveTokens == 1, "a purchase after the run ended is kept as one token")
	assert(receipt(products.Revive, nil, "r-1") == Decision.PurchaseGranted and data.ReviveTokens == 1, "repeated callback: still one token")
	-- next run: the token is spent automatically on the next fall; the second fall gets no offer
	rp = startSolo()
	fall(rp)
	assert(rp.Alive and data.ReviveTokens == 0 and rp.ProductReviveUsed, "the saved token revives once")
	fall(rp)
	assert(not rp.Alive and not rp.AwaitingRevive, "one product revive per run: no second offer")
	preview.advance(1)
	-- purchase while waiting: revived once, token spent; a repeated callback changes nothing
	rp = startSolo()
	fall(rp)
	assert(rp.AwaitingRevive, "offer open")
	assert(receipt(products.Revive, nil, "r-2") == Decision.PurchaseGranted, "purchase acknowledged")
	preview.advance(0.5)
	assert(rp.Alive and data.ReviveTokens == 0 and rp.ProductReviveUsed, "bought while waiting: revived, token spent")
	assert(receipt(products.Revive, nil, "r-2") == Decision.PurchaseGranted and data.ReviveTokens == 0, "repeated callback grants nothing")
	-- expiry: the offer runs out and the run ends; nothing is granted without a receipt
	fall(rp)
	assert(not rp.Alive, "second fall in the run")
	RM.AbandonRun(rp)
	preview.advance(1)
	rp = startSolo()
	fall(rp)
	assert(rp.AwaitingRevive, "offer open (expiry case)")
	preview.advance(Config.Monetization.RevivePromptSeconds + 2)
	assert(not rp.AwaitingRevive and not rp.Alive and data.ReviveTokens == 0, "an expired offer grants nothing")
	preview.log("PASS revive: decline, late purchase kept as a token, auto-spend, one per run, buy while waiting, expiry, repeated callbacks")
end

preview.log("PASS safety-sim")
