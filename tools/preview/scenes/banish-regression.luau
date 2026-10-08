-- banish-regression: batch B item B6 (Config.Features.Banish, docs/next/BANISH.md). Boots
-- the REAL server, starts a Solo run and drives the LevelUpBanish remote with the OfferId
-- flow: the banished id leaves the pool and never comes back that run (pool keys plus real
-- rerolls), only that slot re-rolls (fresh OfferId, same deadline, no level used), the
-- count goes 3 → 0 and stops, owned cards / bonus cards / stale ids / a forged NEW card of an
-- owned id are refused, an empty pool falls back to the existing Gold Pouch / Roast Chicken
-- card, and switched off nothing happens. Prints PASS / FAIL lines.
-- run: lune run tools/preview/runtime/main.luau -- --scene banish-regression
--      --studio --device pc --max-time 200 --set headless=on
local Players = game:GetService("Players")
preview.startServer()
preview.advance(1)
local me = Players.LocalPlayer
local RM = preview.server("RunManager")
local LUS = preview.server("LevelUpSystem")
local Config = preview.shared("Config")
local WeaponData = preview.shared("WeaponData")
local PassiveData = preview.shared("PassiveData")
local advance = preview.advance

local fails = 0
local function check(ok: any, label: string)
	if not ok then
		fails += 1
	end
	preview.log((ok and "PASS " or "FAIL ") .. label)
end

check(Config.Features.Banish == true, "Banish switch on by default")
check(Config.LevelUp.Banishes == 3, "Config.LevelUp.Banishes = 3")

preview.fireServerAs(me, "StartRun", "Solo")
advance(2)
local rp = assert(RM.GetRunPlayer(me), "run player missing")
rp.InvulnUntil = math.huge
LUS.Cancel(rp)
check(LUS.BanishesLeft(rp) == 3, "a new run starts with 3 banishes")

-- opens a panel with one level (levels the arena hands out on their own are dropped)
local function open()
	LUS.Cancel(rp)
	LUS.QueueLevels(rp, 1)
	advance(0.1)
	return rp.Offer
end
local function banish(index: number, offerId: number?)
	preview.fireServerAs(me, "LevelUpBanish", index, offerId)
	advance(0.4) -- under the remote's rate limit (3 / s)
end
local function unownedWeapons(): { string }
	local out = {}
	for _, id in ipairs(WeaponData.Order) do
		if not rp.Weapons[id] then
			table.insert(out, id)
		end
	end
	return out
end
local free = unownedWeapons()
assert(#free >= 4, "needs four weapons the hero does not own")

-- 1) banish a NEW weapon card: the slot re-rolls, the rest of the set stays
assert(open(), "a level opens a panel")
rp.Offer[1] = LUS.DescribeCard(rp, "WeaponNew", free[1], 1)
local keep2, keep3 = rp.Offer[2], rp.Offer[3]
local seq, deadline, pending = rp.OfferSeq, rp.OfferDeadline, rp.PendingLevels
banish(1, seq)
check(rp.Banished and rp.Banished["Weapon:" .. free[1]] == true, "the banished id is stored in the run state")
check(LUS.BanishesLeft(rp) == 2, "the count decrements (3 → 2)")
check(rp.OfferSeq == seq + 1 and me:GetAttribute("ChoiceOfferId") == seq + 1, "a fresh OfferId after the banish")
check(rp.Offer[1] and not (rp.Offer[1].Type == "WeaponNew" and rp.Offer[1].Id == free[1]), "slot 1 re-rolled to another card (" .. tostring(rp.Offer[1] and rp.Offer[1].Id) .. ")")
check(rp.Offer[2] == keep2 and rp.Offer[3] == keep3, "only that one slot changed")
check(rp.OfferDeadline == deadline and rp.PendingLevels == pending and rp.Paused, "no level used, deadline and pause unchanged")
local dup = false
for i, c in ipairs(rp.Offer) do
	for j, d in ipairs(rp.Offer) do
		if i < j and c.Type == d.Type and c.Id == d.Id then
			dup = true
		end
	end
end
check(not dup, "the re-rolled card is not a copy of another slot")

-- 2) stale ids and owned / bonus cards are refused
banish(2, seq) -- the old set's id
check(LUS.BanishesLeft(rp) == 2 and rp.OfferSeq == seq + 1, "a banish naming an older set is ignored")
local ownedId = rp.WeaponOrder[1]
local w = rp.Weapons[ownedId]
if w.Level < WeaponData.MaxLevel then
	rp.Offer[1] = LUS.DescribeCard(rp, "WeaponUp", ownedId, w.Level + 1)
	banish(1, rp.OfferSeq)
	check(LUS.BanishesLeft(rp) == 2 and rp.Offer[1].Type == "WeaponUp", "can't banish an owned weapon's upgrade")
end
rp.Offer[1] = { Type = "WeaponNew", Id = ownedId, Level = 1, Name = "forged" }
banish(1, rp.OfferSeq)
check(LUS.BanishesLeft(rp) == 2 and not rp.Banished["Weapon:" .. ownedId], "can't banish an owned id even on a forged NEW card")
rp.Offer[1] = LUS.DescribeCard(rp, "Gold", "Gold", 0)
banish(1, rp.OfferSeq)
check(LUS.BanishesLeft(rp) == 2 and rp.Offer[1].Type == "Gold", "bonus cards can't be banished")
banish(9, rp.OfferSeq)
banish(0 / 0, rp.OfferSeq)
check(LUS.BanishesLeft(rp) == 2, "bad indexes are ignored")

-- 3) the banished id never appears again this run
local inPool = false
for _, key in ipairs(LUS.PoolKeys(rp)) do
	if key == "WeaponNew:" .. free[1] then
		inPool = true
	end
end
check(not inPool, "the pool skips the banished id")
rp.Rerolls = 1000
local seen = false
for _ = 1, 30 do
	preview.fireServerAs(me, "LevelUpReroll", rp.OfferSeq)
	advance(0.34)
	for _, c in ipairs(rp.Offer or {}) do
		if c.Type == "WeaponNew" and c.Id == free[1] then
			seen = true
		end
	end
end
check(not seen, "30 real rerolls never offer the banished weapon")

-- 4) the count stops at 0
for i = 2, 3 do
	open()
	rp.Offer[1] = LUS.DescribeCard(rp, "WeaponNew", free[i], 1)
	banish(1, rp.OfferSeq)
end
check(LUS.BanishesLeft(rp) == 0 and rp.Banished["Weapon:" .. free[3]], "three banishes used (→ 0)")
open()
rp.Offer[1] = LUS.DescribeCard(rp, "WeaponNew", free[4], 1)
local before = rp.OfferSeq
banish(1, rp.OfferSeq)
check(LUS.BanishesLeft(rp) == 0 and not rp.Banished["Weapon:" .. free[4]] and rp.OfferSeq == before, "a fourth banish is refused (stays at 0)")

-- 5) an empty pool falls back to the existing bonus cards
rp.BanishesLeft = 1
for _, id in ipairs(rp.WeaponOrder) do
	rp.Weapons[id].Level = WeaponData.MaxLevel
	rp.Weapons[id].Evolved = true
end
for _, id in ipairs(rp.PassiveOrder) do
	rp.Passives[id] = PassiveData.MaxLevelOf(id)
end
local last = free[4]
for _, id in ipairs(WeaponData.Order) do
	if id ~= last and not rp.Weapons[id] then
		rp.Banished["Weapon:" .. id] = true
	end
end
for _, id in ipairs(PassiveData.Order) do
	if not rp.Passives[id] then
		rp.Banished["Passive:" .. id] = true
	end
end
local keys = LUS.PoolKeys(rp)
check(#keys == 1 and keys[1] == "WeaponNew:" .. last, "pool narrowed to one card (" .. table.concat(keys, ",") .. ")")
open()
check(rp.Offer ~= nil, "a panel opens with one card left in the pool")
if rp.Offer then
	rp.HP = rp.Stats.MaxHP
	rp.Offer = { LUS.DescribeCard(rp, "WeaponNew", last, 1) }
	banish(1, rp.OfferSeq)
	local c = rp.Offer and rp.Offer[1]
	check(c and c.Type == "Gold" and c.Name == "Gold Pouch", "empty pool: the slot becomes the Gold Pouch (" .. tostring(c and c.Type) .. ")")
	check(#LUS.PoolKeys(rp) == 0 and me:GetAttribute("XPReward") == "Coins", "pool empty, XP reward reads Coins")
	local gold = rp.Gold
	preview.fireServerAs(me, "LevelUpChoose", 1, rp.OfferSeq)
	advance(0.4)
	check(rp.Gold > gold and not rp.Offer and not rp.Paused, "the fallback card pays out and the panel closes safely")
end

-- 6) switched off: the remote does nothing
Config.Features.Banish = false
rp.BanishesLeft = 2
rp.Banished = {}
rp.Weapons[rp.WeaponOrder[1]].Evolved = false
open()
if rp.Offer then
	local fid = unownedWeapons()[1]
	rp.Offer[1] = LUS.DescribeCard(rp, "WeaponNew", fid, 1)
	local s0 = rp.OfferSeq
	banish(1, s0)
	check(rp.BanishesLeft == 2 and rp.OfferSeq == s0 and not rp.Banished["Weapon:" .. fid], "switched off: a banish does nothing")
end
Config.Features.Banish = true
LUS.Cancel(rp)

preview.log(fails == 0 and "PASS banish: id never offered again, count 3 → 0, owned refused, empty pool falls back" or ("FAIL banish: " .. fails .. " check(s) failed"))
