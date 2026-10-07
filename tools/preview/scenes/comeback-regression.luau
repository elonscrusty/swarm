-- comeback-regression: the welcome-back gift (docs/next/COMEBACK_GIFT.md) against the real server.
--   1) switch off: no offer, LastSeen untouched, the remote pays nothing
--   2) brand-new accounts never get one (no LastSeen yet, or no finished run)
--   3) 2 days away: nothing; 3 days away: the short gift (gold, no look)
--   4) claim: paid once, refused in a run, the second claim pays nothing
--   5) at most once per 72 h; 7+ days: gold + the look; an owned look pays gold instead
--   6) LastSeen kept fresh while online (the card opening by itself: meta.luau screen=Comeback)
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
local CB = preview.server("ComebackGift")
local K = Config.Comeback
local DAY = 86400

local data = assert(DS.GetData(me), "profile missing")
data.OwnedCharacters = { Knight = true }
data.SelectedCharacter = "Knight"
data.TutorialDone = true
data.FirstRunBonus = true
data.Gold = 1000
C.startClient()
preview.advance(1)

local fails = 0
local function check(label: string, ok: boolean, detail: string?)
	if not ok then
		fails += 1
	end
	preview.log(string.format("%s  %s%s", ok and "PASS" or "FAIL", label, detail and ("  (" .. detail .. ")") or ""))
end
local now = 1800000000
CB._SetClock(function()
	return now
end)
local function claim()
	preview.remote("Comeback"):FireServer("Claim")
	preview.advance(0.4)
end
local function away(days: number)
	data.LastSeen = now - days * DAY - 60
	return CB.Evaluate(data)
end

------------------------------------------------------------------------------------------
-- 1) switch off
------------------------------------------------------------------------------------------
Config.Features.ComebackGift = false
data.Stats.Runs = 5
data.LastSeen = now - 10 * DAY
data.Comeback = nil
check("off: no offer", CB.Evaluate(data) == nil and data.Comeback == nil)
check("off: LastSeen untouched", data.LastSeen == now - 10 * DAY)
data.Comeback = { LastGift = 0, Pending = { Days = 9, Gold = 500 } }
local g0 = data.Gold
claim()
check("off: the remote pays nothing", data.Gold == g0 and data.Comeback.Pending ~= nil)
data.Comeback = nil
Config.Features.ComebackGift = true

------------------------------------------------------------------------------------------
-- 2) brand-new accounts
------------------------------------------------------------------------------------------
data.LastSeen = nil
data.Stats.Runs = 0
check("new account (no LastSeen): nothing", CB.Evaluate(data) == nil and data.LastSeen == now)
data.Stats.Runs = 0
check("no finished run yet: nothing, even 10 days away", away(10) == nil)
data.Stats.Runs = 5

------------------------------------------------------------------------------------------
-- 3) 2 days vs 3 days
------------------------------------------------------------------------------------------
check("2 days away: nothing", away(2) == nil and data.Comeback.Pending == nil)
local gift = away(3)
check("3 days away: the short gift", gift ~= nil and gift.Gold == K.Gold and gift.Look == nil and gift.Days == 3, gift and tostring(gift.Gold) or "nil")
check("LastSeen refreshed after the check", data.LastSeen == now)

------------------------------------------------------------------------------------------
-- 4) claim once
------------------------------------------------------------------------------------------
preview.remote("StartRun"):FireServer("Solo")
preview.advance(2)
local rp = RM.GetRunPlayer(me)
if rp then
	rp.InvulnUntil = 1e9
end
g0 = data.Gold
claim()
check("claim refused in a run", data.Gold == g0 and data.Comeback.Pending ~= nil)
if rp then
	RM.AbandonRun(rp)
end
preview.advance(Config.Run.ResultsSeconds + 3)
g0 = data.Gold
claim()
claim()
check("claim pays once", data.Gold == g0 + K.Gold and data.Comeback.Pending == nil, string.format("+%d", data.Gold - g0))

------------------------------------------------------------------------------------------
-- 5) cooldown, the long gift, an owned look
------------------------------------------------------------------------------------------
now += DAY
check("within " .. K.CooldownHours .. " h of the last gift: nothing", away(5) == nil)
now += 3 * DAY
data.Cosmetics.Owned[K.LongCosmetic] = nil
gift = away(8)
check("7+ days away: gold + the look", gift ~= nil and gift.Gold == K.LongGold and gift.Look == K.LongCosmetic, gift and tostring(gift.Gold) or "nil")
check("a waiting gift is not replaced", away(9) == nil and data.Comeback.Pending.Days == 8)
g0 = data.Gold
claim()
check("long gift claimed: gold and the look", data.Gold == g0 + K.LongGold and data.Cosmetics.Owned[K.LongCosmetic] == true)
now += 4 * DAY
gift = away(10)
g0 = data.Gold
claim()
check("look already owned: gold instead", gift ~= nil and data.Gold == g0 + K.LongGold + K.CosmeticOwnedGold, string.format("+%d", data.Gold - g0))

------------------------------------------------------------------------------------------
-- 6) LastSeen while online (the WELCOME BACK card opening by itself is checked in the
--    client scene meta.luau, screen=Comeback: a full client here costs ~40 s per sim second)
------------------------------------------------------------------------------------------
K.SeenEvery = 2
data.LastSeen = 1
now += 100
preview.advance(K.SeenEvery + 1)
check("LastSeen refreshed while online", data.LastSeen == now, tostring(data.LastSeen))
K.SeenEvery = 60

CB._SetClock(nil)
if fails > 0 then
	error(string.format("comeback-regression: %d check(s) failed", fails))
end
preview.log("PASS comeback-regression: off, new accounts, 2 vs 3 days, once, cooldown, long gift, LastSeen")
