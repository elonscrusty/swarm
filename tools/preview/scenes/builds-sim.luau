-- builds-sim: the continuation pack's rank build system and combat core ([stream B];
-- docs/redesign/gameplay/BUILDS.md) against the REAL modules: BuildRules formulas at ranks 1/3/5,
-- crit / armor / interval caps, the rarity and category distributions over many rolls, capacity
-- filtering, slot limits and the protected signature slot, the 15-weapon catalog and the 8 loot
-- passives, entitlement for other classes' signatures, the heal fallback, evolution gating, the
-- solo deadline (first card) and reroll accounting, live hits vs the formula, status caps
-- (slow / knockback / stagger / scorch), the secondary-emission budget, line of sight blocked by a
-- terrain wall (HeightGrid) and no recursive secondaries (Splinter Badge, evolution pulses).
-- run: lune run tools/preview/runtime/main.luau -- --scene builds-sim --studio --device pc
--      --max-time 400 --set headless=on          (PASS / FAIL lines; exits non-zero on a FAIL)
local Players = game:GetService("Players")
local RS = game:GetService("ReplicatedStorage")
local RunConfig = require(RS.SwarmV2.Run.RunConfig)
local BuildRules = require(RS.SwarmV2.Run.BuildRules)
local Builds, Combat = RunConfig.Builds, RunConfig.Combat
local WeaponData = preview.shared("WeaponData")
local PassiveData = preview.shared("PassiveData")
local StatSheet = preview.shared("StatSheet")
local SynergyData = preview.shared("SynergyData")
local Config = preview.shared("Config")

local results = {}
local function check(name: string, ok: boolean, detail: any?)
	table.insert(results, { name, ok })
	preview.log(string.format("%s %s%s", ok and "PASS" or "FAIL", name, detail ~= nil and (": " .. tostring(detail)) or ""))
end
local function near(a: number, b: number, eps: number?): boolean
	return math.abs(a - b) <= (eps or 1e-6) * math.max(1, math.abs(b))
end

------------------------------------------------------------------------------------------
-- A. Pure rules (BuildRules, WeaponData, PassiveData, StatSheet)
------------------------------------------------------------------------------------------
check("A0 rank system on, B = 10", Builds.Enabled == true and BuildRules.On() and BuildRules.B() == 10)
-- damage = B x coeff x (1 + 0.2 (r - 1)) x (1 + bonus); Scrap Shot coeff 0.90
local d1, d3, d5 = BuildRules.HitDamage(0.9, 1, 0), BuildRules.HitDamage(0.9, 3, 0), BuildRules.HitDamage(0.9, 5, 0)
check("A1 damage at ranks 1/3/5 (Scrap Shot 0.90 B)", near(d1, 9) and near(d3, 12.6) and near(d5, 16.2), string.format("%.2f / %.2f / %.2f", d1, d3, d5))
check("A2 additive damage bonus, clamped 0..2", near(BuildRules.HitDamage(0.9, 3, 0.5), 12.6 * 1.5) and near(BuildRules.HitDamage(0.9, 1, 7), 27) and near(BuildRules.HitDamage(0.9, 1, -3), 9),
	string.format("x1.5 %.2f, bonus 7 -> %.2f, bonus -3 -> %.2f", BuildRules.HitDamage(0.9, 3, 0.5), BuildRules.HitDamage(0.9, 1, 7), BuildRules.HitDamage(0.9, 1, -3)))
local i1, i3, i5 = BuildRules.Interval(0.9, 1, 0), BuildRules.Interval(0.9, 3, 0), BuildRules.Interval(0.9, 5, 0)
check("A3 interval at ranks 1/3/5 (0.95^(r-1))", near(i1, 0.9) and near(i3, 0.9 * 0.95 ^ 2) and near(i5, 0.9 * 0.95 ^ 4), string.format("%.4f / %.4f / %.4f", i1, i3, i5))
check("A4 attack speed divides, clamped 0..1", near(BuildRules.Interval(0.9, 1, 0.4), 0.9 / 1.4) and near(BuildRules.Interval(0.9, 1, 5), 0.45) and near(BuildRules.Interval(0.9, 1, -1), 0.9))
check("A5 interval floor 0.25 s", BuildRules.Interval(0.4, 5, 1) == Combat.MinInterval and BuildRules.Interval(0.1, 1, 0) == 0.25, tostring(BuildRules.Interval(0.4, 5, 1)))
check("A6 crit base 5 %, cap 50 %", BuildRules.CritChance(0) == 0.05 and BuildRules.CritChance(0.15) == 0.20 and BuildRules.CritChance(9) == 0.5 and BuildRules.CritChance(0, 0) == 0 and Combat.CritMult == 1.75)
check("A7 armor A/(100+A), A clamped 0..100", near(BuildRules.ArmorMult(0), 1) and near(BuildRules.ArmorMult(50), 1 - 50 / 150) and near(BuildRules.ArmorMult(100), 0.5) and near(BuildRules.ArmorMult(500), 0.5) and near(BuildRules.ArmorMult(-5), 1),
	string.format("%.3f %.3f %.3f", BuildRules.ArmorMult(50), BuildRules.ArmorMult(100), BuildRules.ArmorMult(500)))
check("A8 status caps (slow 40 %, boss 10 %, knockback 24, elite half, boss 0)", near(BuildRules.SlowMult(0.6), 0.6) and near(BuildRules.SlowMult(0.6, true), 0.9) and near(BuildRules.SlowMult(0.2), 0.8)
	and BuildRules.Knockback("Normal", 100) == 24 and BuildRules.Knockback("Elite", 20) == 10 and BuildRules.Knockback("Boss", 20) == 0
	and BuildRules.Stagger("Elite", 1) == 0.15 and BuildRules.Stagger("Boss", 1) == 0 and BuildRules.Stagger("Normal", 0.25) == 0.25)
check("A9 scorch 0.12 B/s in 0.5 s ticks", near(BuildRules.ScorchTickDamage(1), 0.6) and Combat.ScorchSeconds == 3)

-- catalog: 15 weapons (12 signatures + Sword, Magic Orb, Vortex), milestones at 3 and 5, specs valid
local catOk, catBad = #WeaponData.Catalog == 15, {}
local sigCount = 0
for cls, wid in pairs(WeaponData.Signatures) do
	sigCount += 1
	local def = WeaponData.Weapons[wid]
	if not def or def.ClassOnly ~= cls or not table.find(WeaponData.ClassOrder, wid) then table.insert(catBad, wid .. " signature") end
end
for _, id in ipairs(WeaponData.Catalog) do
	local def = WeaponData.Weapons[id]
	local spec = def and def.Rank
	if not spec or not (spec.Coeff > 0) or not (spec.Interval > 0) or not WeaponData.MilestoneText(id, 3) or not WeaponData.MilestoneText(id, 5) then
		table.insert(catBad, id .. " spec / milestones")
	end
	if def and #def.Levels ~= WeaponData.MaxLevel then table.insert(catBad, id .. " legacy rows") end
end
check("A10 catalog: 15 weapons, 12 signatures, milestones at ranks 3 and 5", catOk and sigCount == 12 and #catBad == 0, table.concat(catBad, ", "))
local names = { ScrapToss = "Scrap Shot", ToastVolley = "Toast Toss", BubbleBomb = "Bubble Bomb", YarnBomb = "Yarn Bomb", Whip = "Sword", MagicOrb = "Magic Orb", Vortex = "Vortex" }
local nameBad = {}
for id, n in pairs(names) do
	if WeaponData.Weapons[id].Name ~= n then table.insert(nameBad, id) end
end
check("A11 display names", #nameBad == 0, table.concat(nameBad, ", "))
-- the brief's numbers for the first four signatures and the legacy three
local function spec(id, r) return WeaponData.RankSpec(id, r) end
check("A12 Scrap Shot: 0.90 B, 0.90 s, range 32, speed 70, bounce 0.45 B / 10; r3 2 bounces; r5 +1 0.40 B scrap",
	spec("ScrapToss", 1).Coeff == 0.9 and spec("ScrapToss", 1).Interval == 0.9 and spec("ScrapToss", 1).Range == 32 and spec("ScrapToss", 1).Speed == 70
	and spec("ScrapToss", 1).Bounces == 1 and spec("ScrapToss", 1).BounceCoeff == 0.45 and spec("ScrapToss", 1).BounceRange == 10
	and spec("ScrapToss", 2).Bounces == 1 and spec("ScrapToss", 3).Bounces == 2 and spec("ScrapToss", 4).ExtraShots == nil and spec("ScrapToss", 5).ExtraShots == 1 and spec("ScrapToss", 5).ExtraCoeff == 0.4)
check("A13 Toast Toss: 0.65 B, 0.85 s, 32, 65, ricochet 0.35 B; r3 2; r5 radius-3 0.20 B burst",
	spec("ToastVolley", 1).Coeff == 0.65 and spec("ToastVolley", 1).Interval == 0.85 and spec("ToastVolley", 1).Speed == 65 and spec("ToastVolley", 1).BounceCoeff == 0.35
	and spec("ToastVolley", 3).Bounces == 2 and spec("ToastVolley", 5).FinalBurst.Radius == 3 and spec("ToastVolley", 5).FinalBurst.Coeff == 0.2)
check("A14 Bubble Bomb: 0.20 B + r6 0.90 B, 1.20 s, 28, 48, fuse 0.8; r3 radius 7; r5 half second bubble",
	spec("BubbleBomb", 1).ImpactCoeff == 0.2 and spec("BubbleBomb", 1).Coeff == 0.9 and spec("BubbleBomb", 1).BurstRadius == 6 and spec("BubbleBomb", 1).Fuse == 0.8
	and spec("BubbleBomb", 3).BurstRadius == 7 and spec("BubbleBomb", 5).SecondBubble.Share == 0.5)
check("A15 Yarn Bomb: 1.25 B, 1.40 s, 35, fuse 1, radius 8, max 8; r3 fuse 0.85; r5 radius 10",
	spec("YarnBomb", 1).Coeff == 1.25 and spec("YarnBomb", 1).Interval == 1.4 and spec("YarnBomb", 1).Fuse == 1 and spec("YarnBomb", 1).BlastRadius == 8 and spec("YarnBomb", 1).MaxTargets == 8
	and spec("YarnBomb", 3).Fuse == 0.85 and spec("YarnBomb", 5).BlastRadius == 10)
check("A16 Sword / Magic Orb / Vortex fallback numbers and milestones",
	spec("Whip", 1).Arc == 110 and spec("Whip", 1).Reach == 10 and spec("Whip", 1).Interval == 0.95 and spec("Whip", 1).MaxTargets == 6 and spec("Whip", 3).Arc == 130 and spec("Whip", 5).Reach == 12
	and spec("MagicOrb", 1).OrbitRadius == 6 and spec("MagicOrb", 1).Coeff == 0.45 and spec("MagicOrb", 1).Interval == 0.75 and spec("MagicOrb", 3).Amount == 2 and spec("MagicOrb", 5).Amount == 3
	and spec("Vortex", 1).VortexRadius == 7 and spec("Vortex", 1).Duration == 3 and spec("Vortex", 1).Tick == 0.75 and spec("Vortex", 1).MaxTargets == 8 and spec("Vortex", 3).VortexRadius == 9 and spec("Vortex", 5).Duration == 4)
local evoOk = WeaponData.Weapons.ScrapToss.Evolution.Name == "Junkyard Cyclone" and WeaponData.Weapons.ScrapToss.Evolution.Passive == "PatchworkPadding"
	and WeaponData.Weapons.ToastVolley.Evolution.Name == "Toaststorm" and WeaponData.Weapons.ToastVolley.Evolution.Passive == "RatchetTimer"
	and WeaponData.Weapons.BubbleBomb.Evolution.Name == "Bubble Torrent" and WeaponData.Weapons.BubbleBomb.Evolution.Passive == "CollectorsBell"
	and WeaponData.Weapons.YarnBomb.Evolution.Name == "Knitting Nightmare" and WeaponData.Weapons.YarnBomb.Evolution.Passive == "SplinterBadge"
check("A17 the four evolutions and their partner passives", evoOk and #Builds.Evolutions == 4)
-- loot passives: 8, five ranks, the brief's per-rank values
local function sheet(passives, char) return StatSheet.Compute({ CharacterId = char or "ruckus", Passives = passives }) end
local base = sheet({})
local lp = {
	{ "PocketDynamo", function(s) return near(s.Might, base.Might + 0.5) end },
	{ "RatchetTimer", function(s) return near(s.AttackSpeed, 0.40) and near(s.CooldownMult, 1 / 1.4) end },
	{ "TrailSneakers", function(s) return near(s.Speed - base.Speed, Config.Player.BaseSpeed * 0.20, 1e-4) end },
	{ "PatchworkPadding", function(s) return s.MaxHP > base.MaxHP end },
	{ "CollectorsBell", function(s) return near(s.PickupRadius, base.PickupRadius + 7.5) end },
	{ "LuckyButton", function(s) return near(s.CritChance, 0.05 + 0.15) end },
	{ "SpringStitch", function(s) return near(s.FallDamageMult, 0.6) and near(s.LandLockReduce, 0.05) end },
	{ "SplinterBadge", function(s) return near(s.SplinterChance, 0.20) end },
}
local lpBad = {}
for _, row in ipairs(lp) do
	local id = row[1]
	local def = PassiveData.Passives[id]
	if not def or #def.Values ~= 5 or not table.find(PassiveData.LootOrder, id) or not row[2](sheet({ [id] = 5 })) then
		table.insert(lpBad, id)
	end
end
check("A18 eight loot passives, five ranks, rank-5 values", #PassiveData.LootOrder == 8 and #lpBad == 0, table.concat(lpBad, ", "))
check("A19 Patchwork Padding +8 % n max HP", sheet({ PatchworkPadding = 3 }).MaxHP == math.floor(Config.Player.BaseMaxHP * 1.24 + 0.5), tostring(sheet({ PatchworkPadding = 3 }).MaxHP))
check("A20 synergies hidden", #SynergyData.Active({ Weapons = {}, Passives = { Area = 3, Candle = 3 }, Items = {} }) == 0 and SynergyData.Hidden())

-- rarity distribution (capacity 5) and capacity filtering
local rng = Random.new(7)
local counts = { Common = 0, Uncommon = 0, Rare = 0, Epic = 0 }
local N = 40000
for _ = 1, N do
	local t = BuildRules.RollRarity(rng, 5)
	counts[t.Name] += 1
end
local function share(n) return n / N end
check("A21 rarity 70 / 23 / 6 / 1 over 40k rolls", math.abs(share(counts.Common) - 0.70) < 0.012 and math.abs(share(counts.Uncommon) - 0.23) < 0.012 and math.abs(share(counts.Rare) - 0.06) < 0.006 and math.abs(share(counts.Epic) - 0.01) < 0.003,
	string.format("%.3f / %.3f / %.3f / %.3f", share(counts.Common), share(counts.Uncommon), share(counts.Rare), share(counts.Epic)))
local c2 = { Common = 0, Uncommon = 0, Rare = 0, Epic = 0 }
for _ = 1, 20000 do
	local t = BuildRules.RollRarity(rng, 2)
	c2[t.Name] += 1
end
local only1 = true
for _ = 1, 2000 do
	if BuildRules.RollRarity(rng, 1).Ranks ~= 1 then only1 = false end
end
check("A22 capacity filtering: capacity 2 -> Common / Uncommon renormalised (70:23), capacity 1 -> +1, 0 -> none",
	c2.Rare == 0 and c2.Epic == 0 and math.abs(c2.Common / 20000 - 70 / 93) < 0.015 and only1 and BuildRules.RollRarity(rng, 0) == nil,
	string.format("cap 2: %.3f / %.3f", c2.Common / 20000, c2.Uncommon / 20000))
-- category weights 45 / 35 / 12 / 8 (first option), removal of empty categories, distinct items
local pool = { WeaponUpgrade = { "w1", "w2", "w3" }, PassiveUpgrade = { "p1", "p2", "p3" }, NewWeapon = { "n1", "n2", "n3" }, NewPassive = { "q1", "q2", "q3" } }
local cc = { WeaponUpgrade = 0, PassiveUpgrade = 0, NewWeapon = 0, NewPassive = 0 }
local distinct = true
for _ = 1, 20000 do
	local picks = BuildRules.RollOffer(rng, pool, 3)
	cc[picks[1].Category] += 1
	local seen = {}
	for _, p in ipairs(picks) do
		if seen[p.Item] then distinct = false end
		seen[p.Item] = true
	end
end
check("A23 category weights 45 / 35 / 12 / 8 (first option)", math.abs(cc.WeaponUpgrade / 20000 - 0.45) < 0.015 and math.abs(cc.PassiveUpgrade / 20000 - 0.35) < 0.015 and math.abs(cc.NewWeapon / 20000 - 0.12) < 0.01 and math.abs(cc.NewPassive / 20000 - 0.08) < 0.01,
	string.format("%.3f / %.3f / %.3f / %.3f", cc.WeaponUpgrade / 20000, cc.PassiveUpgrade / 20000, cc.NewWeapon / 20000, cc.NewPassive / 20000))
check("A24 options are distinct (drawn without replacement)", distinct)
local small = BuildRules.RollOffer(rng, { WeaponUpgrade = { "only" }, PassiveUpgrade = {} }, 3)
check("A25 fewer options when the pool is small (never duplicates)", #small == 1 and small[1].Item == "only", tostring(#small))

------------------------------------------------------------------------------------------
-- B. Live server: slots, offers, evolution, heal fallback, deadline, rerolls, hits, statuses
------------------------------------------------------------------------------------------
preview.startServer()
preview.advance(1)
local me = Players.LocalPlayer
local RM = preview.server("RunManager")
local LU = preview.server("LevelUpSystem")
local WS = preview.server("WeaponSystem")
local Spawner = preview.server("EnemySpawner")
local HeightGrid = preview.server("HeightGrid")
local DS = preview.server("DataService")
local data = DS.GetData(me)
if data then
	-- own toastmaster only (cross-class entitlement check below)
	data.OwnedCharacters = data.OwnedCharacters or {}
	data.OwnedCharacters.toastmaster = true
	data.OwnedCharacters.captain_croak = nil
	data.OwnedCharacters.granny_boom = nil
	data.SelectedCharacter = "ruckus"
end
preview.remote("StartRun"):FireServer("Solo")
preview.advance(2)
local rp = assert(RM.GetRunPlayer(me), "run player missing")
rp.InvulnUntil = math.huge
rp.XPNeeded = 1e12
LU.Cancel(rp)

check("B1 the signature is weapon slot 1 at rank 1", rp.WeaponOrder[1] == "ScrapToss" and rp.Weapons.ScrapToss.Level == 1, tostring(rp.WeaponOrder[1]))
check("B2 free rerolls added once", rp.Rerolls >= Builds.FreeRerolls, tostring(rp.Rerolls))
-- entitlement: owned toastmaster's Toast Toss may come, unowned classes' signatures may not
local keys = LU.PoolKeys(rp)
local function hasKey(k) return table.find(keys, k) ~= nil end
check("B3 pool: owned class's signature yes, unowned no, legacy three yes, old weapons never",
	hasKey("NewWeapon:ToastVolley") and not hasKey("NewWeapon:BubbleBomb") and not hasKey("NewWeapon:Dodgeball")
	and hasKey("NewWeapon:Whip") and hasKey("NewWeapon:MagicOrb") and hasKey("NewWeapon:Vortex") and not hasKey("NewWeapon:Knives") and not hasKey("NewWeapon:Garlic"),
	table.concat(keys, " "))
local oldPassive = false
for _, k in ipairs(keys) do
	local id = string.match(k, "^NewPassive:(.+)$")
	if id and not table.find(PassiveData.LootOrder, id) then oldPassive = true end
end
check("B4 pool: only the 8 loot passives", not oldPassive and hasKey("NewPassive:PocketDynamo") and hasKey("WeaponUpgrade:ScrapToss"))
check("B5 AddWeapon refuses an unowned class's signature", LU.AddWeapon(rp, "BubbleBomb") == false and LU.AddWeapon(rp, "YarnBomb") == false)
-- slots: 4 weapons, 4 passives
for _, id in ipairs({ "Whip", "MagicOrb", "Vortex" }) do LU.AddWeapon(rp, id) end
check("B6 weapon slots: 4, the fifth is refused", #rp.WeaponOrder == 4 and LU.AddWeapon(rp, "ToastVolley") == false, tostring(#rp.WeaponOrder))
keys = LU.PoolKeys(rp)
local newW = false
for _, k in ipairs(keys) do
	if string.find(k, "^NewWeapon:") then newW = true end
end
check("B7 no NewWeapon option with the weapon slots full", not newW)
for _, id in ipairs({ "PocketDynamo", "RatchetTimer", "TrailSneakers", "LuckyButton" }) do
	rp.Passives[id] = 1
	table.insert(rp.PassiveOrder, id)
end
LU.RecomputeStats(rp)
keys = LU.PoolKeys(rp)
local newP = false
for _, k in ipairs(keys) do
	if string.find(k, "^NewPassive:") then newP = true end
end
check("B8 no NewPassive option with the passive slots full", not newP)
-- an offer: distinct items, rank grants within capacity, contract fields
local okCards, capOk, fieldsOk = true, true, true
for _ = 1, 300 do
	local offer = LU.RollOffer(rp)
	local seen = {}
	for _, c in ipairs(offer) do
		if seen[c.Id] then okCards = false end
		seen[c.Id] = true
		if c.RankTo and c.RankTo > 5 then capOk = false end
		if c.Category ~= "Heal" and (c.Category == nil or c.Rarity == nil or c.RankTo == nil or c.Slot == nil or c.Lines == nil) then fieldsOk = false end
	end
end
check("B9 offers: distinct items, never past rank 5, contract fields (Category, Rarity, RankFrom/To, Slot, Lines)", okCards and capOk and fieldsOk)
rp.Weapons.Whip.Level = 4
local capped = true
for _ = 1, 400 do
	for _, c in ipairs(LU.RollOffer(rp)) do
		if c.Id == "Whip" and (c.RankTo ~= 5 or c.Rarity ~= "Common") then capped = false end
	end
end
check("B10 a rank-4 weapon only ever offers Common +1 (capacity filtering)", capped)
-- protected slot: inventory flag, the signature never leaves slot 1
check("B11 protected slot 1", rp.WeaponOrder[1] == "ScrapToss")

-- evolution gating: rank 5 + Patchwork Padding rank 3 + level 8
rp.Weapons.ScrapToss.Level = 5
table.remove(rp.PassiveOrder, table.find(rp.PassiveOrder, "LuckyButton"))
rp.Passives.LuckyButton = nil
rp.Passives.PatchworkPadding = 3
table.insert(rp.PassiveOrder, "PatchworkPadding")
rp.Level = 7
local function evoFirst()
	local offer = LU.RollOffer(rp)
	return offer[1] and offer[1].Category == "Evolution" and offer[1].Id == "ScrapToss"
end
check("B12 no evolution below player level 8", not evoFirst())
rp.Level = 8
rp.Passives.PatchworkPadding = 2
check("B13 no evolution with the partner passive at rank 2", not evoFirst())
rp.Passives.PatchworkPadding = 3
local always = true
for _ = 1, 50 do
	if not evoFirst() then always = false end
end
check("B14 level 8 + rank 5 + partner rank 3: the evolution is always the first option", always)
local evoCard = LU.RollOffer(rp)[1]
check("B15 evolution card label", evoCard.Rarity == "Evolution" and evoCard.Name == "Junkyard Cyclone" and evoCard.Type == "Evolve")
-- choose it through the real flow (solo: paused, frozen)
LU.QueueLevels(rp, 1)
local evoIndex = nil
for i, c in ipairs(rp.Offer or {}) do
	if c.Type == "Evolve" then evoIndex = i end
end
preview.remote("LevelUpChoose"):FireServer(evoIndex or 1, rp.OfferSeq)
preview.advance(0.1)
check("B16 the evolution applies once and is never offered again", rp.Weapons.ScrapToss.Evolved == true and not evoFirst())

-- heal fallback: everything maxed, slots full
for _, id in ipairs(rp.WeaponOrder) do rp.Weapons[id].Level = 5 end
for _, id in ipairs(rp.PassiveOrder) do rp.Passives[id] = 5 end
LU.RecomputeStats(rp)
local healOffer = LU.RollOffer(rp)
check("B17 exhausted pool: exactly one heal card", #healOffer == 1 and healOffer[1].Type == "Heal" and healOffer[1].Category == "Heal", tostring(#healOffer))
rp.HP = rp.Stats.MaxHP * 0.5
LU.QueueLevels(rp, 1)
local hp0 = rp.HP
preview.remote("LevelUpChoose"):FireServer(1, rp.OfferSeq)
preview.advance(0.1)
check("B18 the heal card heals 10 % max HP", near(rp.HP - hp0, rp.Stats.MaxHP * Builds.HealShare, 1e-3), string.format("+%.2f of %d", rp.HP - hp0, rp.Stats.MaxHP))

-- reset to a young build for the flow checks
for _, id in ipairs({ "Whip", "MagicOrb", "Vortex" }) do
	rp.Weapons[id] = nil
	table.remove(rp.WeaponOrder, table.find(rp.WeaponOrder, id))
end
rp.Weapons.ScrapToss.Level, rp.Weapons.ScrapToss.Evolved = 1, false
table.clear(rp.Passives)
table.clear(rp.PassiveOrder)
WS.ClearOwner(rp)
LU.RecomputeStats(rp)
preview.advance(0.1)

-- solo deadline: the first displayed card is taken; reroll accounting
LU.QueueLevels(rp, 1)
check("B19 solo choice pauses as before", rp.Offer ~= nil and rp.Paused and RM.IsFrozen())
local rr = rp.Rerolls
local function keyset(o)
	local t = {}
	for _, c in ipairs(o) do table.insert(t, tostring(c.Category) .. tostring(c.Id) .. tostring(c.RankTo)) end
	table.sort(t)
	return table.concat(t, ",")
end
local k0, dl = keyset(rp.Offer), rp.OfferDeadline
preview.remote("LevelUpReroll"):FireServer(rp.OfferSeq)
preview.advance(0.05)
local changed = keyset(rp.Offer) ~= k0
check("B20 a reroll is debited only for a new offer and keeps the deadline", ((changed and rp.Rerolls == rr - 1) or (not changed and rp.Rerolls == rr)) and rp.OfferDeadline == dl,
	string.format("changed %s rerolls %d -> %d", tostring(changed), rr, rp.Rerolls))
local rr2 = rp.Rerolls
preview.remote("LevelUpReroll"):FireServer(rp.OfferSeq)
preview.advance(0.05)
check("B21 one reroll per choice", rp.Rerolls == rr2 or not changed)
local first = rp.Offer[1]
local fType, fId, fTo = first.Type, first.Id, first.RankTo
preview.advance(Builds.SoloChoiceSeconds + (Config.LevelUp.RevealGraceSeconds or 0) + 0.5)
local took = (fType == "WeaponUp" or fType == "WeaponNew") and rp.Weapons[fId] ~= nil and rp.Weapons[fId].Level == fTo
	or (fType == "PassiveUp" or fType == "PassiveNew") and rp.Passives[fId] == fTo
check("B22 the deadline takes the first displayed card", took and not rp.Offer, string.format("%s %s -> %s", tostring(fType), tostring(fId), tostring(fTo)))
-- inventory payload for the HUD: rank, effective damage / interval, protected slot
local inv = nil
local conn = preview.remote("Inventory").OnClientEvent:Connect(function(payload) inv = payload end)
LU.SendInventory(rp)
preview.advance(0.05)
conn:Disconnect()
local w1 = inv and inv.Weapons and inv.Weapons[1]
check("B23 inventory: slots 4 + 4, rank, effective damage and interval, protected slot 1", inv ~= nil and inv.WeaponSlots == 4 and inv.PassiveSlots == 4 and w1 and w1.Rank ~= nil and w1.Damage ~= nil and w1.Interval ~= nil and w1.Protected == true)

-- live hits vs the formula (no crit), crit x1.75, status never crits, armor
LU.Cancel(rp)
for k in pairs(rp.Weapons) do rp.Weapons[k].Timer = 1e9 end -- hold the weapons: hits by hand only
Spawner.DespawnAll()
local dummy = assert(Spawner.Spawn("Bat", rp.Root.Position + Vector3.new(6, 0, 0), { Force = true, HP = 1e7 }))
preview.advance(0.05)
rp.Stats.CritChance = 0
local function lost(fn)
	local h = dummy.HP
	fn()
	return h - dummy.HP
end
local hitBad = {}
for _, r in ipairs({ 1, 3, 5 }) do
	rp.Weapons.ScrapToss.Level = r
	local s = WS.WeaponStats(rp, rp.Weapons.ScrapToss)
	local expect = BuildRules.HitDamage(0.9, r, rp.Stats.DamageBonus)
	local got = lost(function() WS.Damage(rp, dummy, 0.9, "ScrapToss", nil, {}) end)
	if not near(got, expect, 1e-4) or not near(s.damage, expect, 1e-4) then table.insert(hitBad, string.format("r%d %.2f/%.2f/%.2f", r, got, s.damage, expect)) end
	local iv = BuildRules.Interval(0.9, r, rp.Stats.AttackSpeed)
	if not near(s.cooldown, iv, 1e-4) then table.insert(hitBad, string.format("r%d interval %.3f vs %.3f", r, s.cooldown, iv)) end
end
check("B24 live hit and weapon stats = the formula at ranks 1/3/5", #hitBad == 0, table.concat(hitBad, "; "))
rp.Weapons.ScrapToss.Level = 1
rp.Stats.CritChance = 1
local critHit = lost(function() WS.Damage(rp, dummy, 1, "ScrapToss", 1, {}) end)
local statusHit = lost(function() WS.Damage(rp, dummy, 1, "ScrapToss", 1, { Status = true }) end)
local secHit = lost(function() WS.Damage(rp, dummy, 1, "ScrapToss", 1, { Secondary = true }) end)
check("B25 crit x1.75 on a direct hit; status and secondary hits never crit", near(critHit, 17.5, 1e-4) and near(statusHit, 10, 1e-4) and near(secHit, 10, 1e-4),
	string.format("crit %.2f status %.2f secondary %.2f", critHit, statusHit, secHit))
rp.Stats.CritChance = 0
dummy.Armor = 50
local armored = lost(function() WS.Damage(rp, dummy, 1, "ScrapToss", 1, {}) end)
dummy.Armor = 400
local capArmor = lost(function() WS.Damage(rp, dummy, 1, "ScrapToss", 1, {}) end)
dummy.Armor = nil
check("B26 armor 50 -> x0.667, 400 -> capped at 100 (x0.5)", near(armored, 10 * (1 - 50 / 150), 1e-4) and near(capArmor, 5, 1e-4), string.format("%.3f / %.3f", armored, capArmor))
-- cast ledger: one hit per target per cast id
local cast = WS.NewCast()
local twice = lost(function()
	WS.Damage(rp, dummy, 1, "ScrapToss", 1, { CastId = cast })
	WS.Damage(rp, dummy, 1, "ScrapToss", 1, { CastId = cast })
end)
check("B27 a cast hits a target once (hit ledger by cast id)", near(twice, 10, 1e-4), string.format("%.2f", twice))
-- the interval floor in the live weapon stats
rp.Stats.CooldownMult = 0.01
local floorS = WS.WeaponStats(rp, rp.Weapons.ScrapToss)
check("B28 live interval never below 0.25 s", floorS.cooldown == Combat.MinInterval, tostring(floorS.cooldown))
LU.RecomputeStats(rp)

-- statuses: slow (strongest only, cap 40 %, boss 10 %), knockback cap / elite half, stagger rules, scorch
local now = RM.GetRunTime()
WS.ApplySlow(dummy, 0.9, 2)
local slowCap = dummy.SlowMult
WS.ApplySlow(dummy, 0.2, 5)
check("B29 slow capped at 40 %, a weaker slow never replaces a stronger one", near(slowCap, 0.6) and near(dummy.SlowMult, 0.6) and dummy.SlowUntil < now + 2.5, string.format("%.2f %.2f", slowCap, dummy.SlowMult))
local fakeBoss = { Alive = true, Boss = true, SlowUntil = nil, SlowMult = 1, Uid = -5 }
WS.ApplySlow(fakeBoss, 0.5, 2)
check("B30 boss slow capped at 10 %", near(fakeBoss.SlowMult, 0.9), tostring(fakeBoss.SlowMult))
dummy.Knock = Vector3.zero
WS.Damage(rp, dummy, 0.01, "ScrapToss", 1, { Knock = 500, From = dummy.Pos - Vector3.new(3, 0, 0) })
check("B31 knockback speed capped at 24", dummy.Knock.Magnitude <= Combat.KnockbackCap + 1e-6 and dummy.Knock.Magnitude > 0, string.format("%.2f", dummy.Knock.Magnitude))
local elite = assert(Spawner.Spawn("Bat", rp.Root.Position + Vector3.new(-6, 0, 0), { Force = true, HP = 1e7, Elite = true }))
preview.advance(0.05)
elite.Knock = Vector3.zero
WS.Damage(rp, elite, 0.01, "ScrapToss", 1, { Knock = 20, From = elite.Pos - Vector3.new(3, 0, 0) })
local resist = 1 - (elite.Def.KnockbackResist or 0)
check("B32 elites take half knockback", near(elite.Knock.Magnitude, 10 * resist, 1e-3), string.format("%.2f", elite.Knock.Magnitude))
check("B33 stagger: normal 0.25 s then 1.5 s immunity; elite at most 0.15 s; boss never",
	WS.Stagger(dummy, 0.25) and near(dummy.StaggerUntil - RM.GetRunTime(), 0.25, 1e-3) and not WS.Stagger(dummy, 0.25)
	and WS.Stagger(elite, 1) and near(elite.StaggerUntil - RM.GetRunTime(), 0.15, 1e-3) and not WS.Stagger(fakeBoss, 1))
dummy.StaggerUntil = nil
local sc0 = dummy.HP
WS.ApplyScorch(rp, dummy, 1)
WS.ApplyScorch(rp, dummy, 1) -- refresh, never a second burn
preview.advance(3.2)
local scorchLost = sc0 - dummy.HP
check("B34 scorch: 0.12 B/s for 3 s in 0.5 s ticks, refreshed not stacked, no crit", near(scorchLost, 6 * 0.6, 0.02) or near(scorchLost, 7 * 0.6, 0.02), string.format("%.2f (6 ticks = 3.6)", scorchLost))

-- secondary-emission budget: 10 per second per player
local Rk = WS._Rank
rp.EmitTokens, rp.EmitAt = nil, nil
local okN = 0
for _ = 1, 30 do
	if Rk.tryEmit(rp) then okN += 1 end
end
preview.advance(0.5)
local after = 0
for _ = 1, 30 do
	if Rk.tryEmit(rp) then after += 1 end
end
check("B35 secondary emissions capped at 10 per second (refills over time)", okN == Combat.SecondaryPerSecond and after >= 4 and after <= 6, string.format("%d now, %d after 0.5 s", okN, after))
check("B36 a terminal effect can never emit (chain depth)", WS.CanEmit(rp, { Terminal = true }) == false and WS.CanEmit(rp, { Depth = Combat.MaxChainDepth }) == false)

-- no recursion: Splinter Badge on every direct hit emits at most 2 splinters, splinters never splinter
rp.EmitTokens, rp.EmitAt = nil, nil
rp.Stats.SplinterChance = 1
rp.Splinters = 0
local near1 = assert(Spawner.Spawn("Bat", dummy.Pos + Vector3.new(0, 0, 3), { Force = true, HP = 1e7 }))
local near2 = assert(Spawner.Spawn("Bat", dummy.Pos + Vector3.new(0, 0, -3), { Force = true, HP = 1e7 }))
preview.advance(0.1)
local logHits = {}
local realDamage = Spawner.Damage
Spawner.Damage = function(e, amount, who, dir, kb, isProc, crit)
	table.insert(logHits, { E = e, Amount = amount, Proc = isProc == true })
	return realDamage(e, amount, who, dir, kb, isProc, crit)
end
rp.Stats.CritChance = 0
WS.Damage(rp, dummy, 1, "ScrapToss", 1, {})
Spawner.Damage = realDamage
local splinterHits, procHits = 0, 0
for _, h in ipairs(logHits) do
	if h.E ~= dummy then splinterHits += 1 end
	if h.Proc then procHits += 1 end
end
check("B37 Splinter Badge: one direct hit -> 2 splinters at other enemies (secondary), no further splinters", rp.Splinters == 1 and splinterHits == 2 and procHits == 2 and #logHits == 3,
	string.format("hits %d splinter hits %d proc %d", #logHits, splinterHits, procHits))
rp.Stats.SplinterChance = 0
LU.RecomputeStats(rp)

------------------------------------------------------------------------------------------
-- C. Line of sight: a terrain wall (HeightGrid) blocks targeting and blasts
------------------------------------------------------------------------------------------
Spawner.DespawnAll()
local root = rp.Root.Position
local gy = HeightGrid.GroundY(root.X, root.Z)
local savedGrid = HeightGrid.GetGrid()
local Core = HeightGrid.Core
local cell = 4
local g = Core.NewGrid(root.X - 100, root.Z - 100, 50, 50, cell, 3.2, gy)
for j = 0, 49 do
	for i = 0, 49 do
		Core.Set(g, i, j, gy, true)
	end
end
-- a wall 12 studs high: the cells 3 columns east of the hero (x in [root+12, root+16))
local wallI = math.floor((root.X + 13 - g.MinX) / cell)
for j = 0, 49 do
	Core.Set(g, wallI, j, gy + 12, false)
end
HeightGrid.SetGrid(g, nil)
local east = Vector3.new(root.X + 24, gy, root.Z)
local south = Vector3.new(root.X, gy, root.Z + 24)
check("C1 a wall blocks the sight line, open ground does not", WS.HasLineOfSight(Vector3.new(root.X, gy, root.Z), east) == false and WS.HasLineOfSight(Vector3.new(root.X, gy, root.Z), south) == true)
local behind = assert(Spawner.Spawn("Bat", Vector3.new(root.X + 18, gy, root.Z), { Force = true, HP = 1e7 }))
local visible = assert(Spawner.Spawn("Bat", Vector3.new(root.X - 2, gy, root.Z + 22), { Force = true, HP = 1e7 }))
preview.advance(0.1)
behind.Pos = Vector3.new(root.X + 18, gy, root.Z)
visible.Pos = Vector3.new(root.X - 2, gy, root.Z + 22)
local pickT = WS.NearestTarget(rp, 32, { From = Vector3.new(root.X, gy, root.Z) })
check("C2 targeting skips the nearer enemy behind the wall for the farther visible one", pickT == visible, pickT and pickT.Uid or "nil")
local hB = behind.HP
WS._Rank.burst(rp, Vector3.new(root.X + 8, gy, root.Z), 12, 5, nil, nil, false)
check("C3 a blast does not hit through the wall", behind.HP == hB, string.format("%.1f", hB - behind.HP))
local blocked = WS.Damage(rp, behind, 1, "ScrapToss", 1, { From = Vector3.new(root.X, gy, root.Z) })
check("C4 WeaponSystem.Damage with an origin refuses a hit through terrain", blocked == false and behind.HP == hB)
-- targeting hold: a picked target is kept 0.30 s even when a nearer one appears
local key = { Key = "test", From = Vector3.new(root.X, gy, root.Z) }
local t1 = WS.NearestTarget(rp, 32, key)
local closer = assert(Spawner.Spawn("Bat", Vector3.new(root.X - 3, gy, root.Z + 3), { Force = true, HP = 1e7 }))
preview.advance(0.05)
closer.Pos = Vector3.new(root.X - 3, gy, root.Z + 3)
local t2 = WS.NearestTarget(rp, 32, key)
preview.advance(Combat.TargetHold + 0.05)
closer.Pos = Vector3.new(root.X - 3, gy, root.Z + 3)
local t3 = WS.NearestTarget(rp, 32, key)
check("C5 a valid target is held 0.30 s, then the nearest wins", t1 == visible and t2 == visible and t3 == closer)
HeightGrid.SetGrid(savedGrid, nil)

------------------------------------------------------------------------------------------
-- D. The live weapons fire at rank 1 / 3 / 5 and evolved without errors
------------------------------------------------------------------------------------------
-- every catalog weapon alone (a test loadout set by hand), each rank state for 2.5 s against a
-- still ring of enemies 6 studs out: it must deal damage (the 8 newer signatures run their
-- placeholder behaviours until stream C)
local silent = {}
local emitted: { [string]: number } = {}
local saved = { Weapons = rp.Weapons, Order = rp.WeaponOrder }
for _, id in ipairs(WeaponData.Catalog) do
	for _, r in ipairs({ 1, 3, 5, 6 }) do
		if r < 6 or WeaponData.Weapons[id].Evolution then
			Spawner.DespawnAll()
			WS.ClearOwner(rp)
			preview.advance(0.05)
			rp.Weapons = { [id] = { Id = id, Level = math.min(r, 5), Rank = math.min(r, 5), Evolved = r == 6, Timer = 0, Live = {}, Growth = 0 } }
			rp.WeaponOrder = { id }
			for i = 1, 8 do
				local a = i * math.pi / 4
				local e = Spawner.Spawn("Bat", rp.Root.Position + Vector3.new(math.cos(a) * 6, 0, math.sin(a) * 6), { Force = true, HP = 1e6 })
				if e then
					e.SlowUntil, e.SlowMult = math.huge, 0
				end
			end
			local d0, e0 = rp.DamageDealt, rp.Emitted or 0
			preview.advance(2.5)
			if not (rp.DamageDealt > d0) then
				table.insert(silent, id .. (r == 6 and "*" or tostring(r)))
			end
			emitted[id .. (r == 6 and "*" or tostring(r))] = (rp.Emitted or 0) - e0
		end
	end
end
rp.Weapons, rp.WeaponOrder = saved.Weapons, saved.Order
WS.ClearOwner(rp)
check("D1 all 15 catalog weapons deal damage at ranks 1, 3, 5 (and evolved)", #silent == 0, #silent > 0 and table.concat(silent, ", ") or "all fire")
-- secondaries (bounces, milestone extras, evolution pulses / toasts / small bubbles / fragments)
-- really emit, and never more than the budget allows (10 / s: at most 10 + 2.5 x 10 per run)
local evoEmit = (emitted["ScrapToss*"] or 0) > 0 and (emitted["ToastVolley*"] or 0) > 0 and (emitted["BubbleBomb*"] or 0) > 0 and (emitted["YarnBomb*"] or 0) > 0
local bounded = true
for _, n in pairs(emitted) do
	if n > 10 + 2.5 * Combat.SecondaryPerSecond then bounded = false end
end
check("D2 evolution / milestone secondaries emit, within the per-player budget", evoEmit and bounded and (emitted.ScrapToss5 or 0) > (emitted.ScrapToss1 or 0),
	string.format("Scrap 1/3/5/* %d/%d/%d/%d, Toast* %d, Bubble* %d, Yarn* %d", emitted.ScrapToss1 or 0, emitted.ScrapToss3 or 0, emitted.ScrapToss5 or 0, emitted["ScrapToss*"] or 0,
		emitted["ToastVolley*"] or 0, emitted["BubbleBomb*"] or 0, emitted["YarnBomb*"] or 0))

local failed = 0
for _, row in ipairs(results) do
	if not row[2] then failed += 1 end
end
preview.log(string.format("%s: builds-sim %d/%d checks", failed == 0 and "PASS" or "FAIL", #results - failed, #results))
assert(failed == 0, failed .. " builds checks failed")
