-- math-regression: deterministic checks of the run's stat, XP, upgrade and HP math against
-- the REAL modules (StatSheet, WeaponData, PassiveData, ItemData, SynergyData,
-- LevelUpSystem, XPSystem, RunManager, EnemySpawner, WeaponSystem), then a controlled-target
-- combat pass: every released weapon alone at level 1 against one high-HP dummy, each hit
-- compared with the prediction (WeaponSystem.WeaponStats). Audit 2026-10-05 (docs/audit/MATH.md).
-- run: lune run tools/preview/runtime/main.luau -- --scene math-regression --studio
--      --device pc --max-time 400 --set headless=on
local C = lib("common")
local Players = game:GetService("Players")
local Config = C.shared("Config")
local StatSheet = C.shared("StatSheet")
local WeaponData = C.shared("WeaponData")
local PassiveData = C.shared("PassiveData")
local ItemData = C.shared("ItemData")
local SynergyData = C.shared("SynergyData")
local CharacterData = C.shared("CharacterData")
local MetaUpgradeData = C.shared("MetaUpgradeData")

local results = {}
local function check(name: string, ok: boolean, detail: string?)
	table.insert(results, { name, ok })
	preview.log(string.format("%s %s%s", ok and "PASS" or "FAIL", name, detail and (": " .. detail) or ""))
end
local function finite(v: any): boolean
	return type(v) == "number" and v == v and math.abs(v) < math.huge
end
local function near(a: number, b: number, eps: number?): boolean
	return math.abs(a - b) <= (eps or 1e-6) * math.max(1, math.abs(b))
end

------------------------------------------------------------------------------------------
-- A. Pure formulas (StatSheet)
------------------------------------------------------------------------------------------
local P, I = Config.Player, Config.Items
local base = StatSheet.Compute({ CharacterId = "Knight" })
check("A1 Knight base sheet", base.Might == 1 and base.MaxHP == P.BaseMaxHP and near(base.DamageTaken, 0.9) and base.CooldownMult == 1 and base.Growth == 1,
	string.format("Might %.2f MaxHP %d DamageTaken %.2f", base.Might, base.MaxHP, base.DamageTaken))
local priest = StatSheet.Compute({ CharacterId = "Priest" })
check("A2 Priest +20% max HP rounds", priest.MaxHP == math.floor(P.BaseMaxHP * 1.2 + 0.5), tostring(priest.MaxHP))

-- additive inside a stat, multiplicative between layers: (1 + sum of might) x curse
local stack = StatSheet.Compute({ CharacterId = "Knight", Meta = { Might = 4 }, Passives = { Might = 2 }, Items = { Whetstone = 2 }, Curse = { Might = 1.3 } })
local mightLv2 = PassiveData.Passives.Might.Values[2].might
local expectMight = (1 + 4 * 0.05 + mightLv2 + 0.2) * 1.3
check("A3 Might stacking order", near(stack.Might, expectMight), string.format("%.4f vs %.4f", stack.Might, expectMight))

-- max HP: (base + flat) x (1 + mult), rounded, then the curse, rounded, never below 1
local hp = StatSheet.Compute({ CharacterId = "Priest", Items = { HeartyBread = 3 }, Curse = { MaxHP = 0.7 } })
local expectHp = math.max(1, math.floor(math.floor((P.BaseMaxHP + 45) * 1.2 + 0.5) * 0.7 + 0.5))
check("A4 MaxHP flat/mult/curse order", hp.MaxHP == expectHp, string.format("%d vs %d", hp.MaxHP, expectHp))

-- damage taken: additive reductions, Iron Plate multiplies, the curse multiplies
local dt = StatSheet.Compute({ CharacterId = "Knight", Passives = { Stoneskin = 1 }, Items = { IronPlate = 2 }, Curse = { DamageTaken = 1.3 } })
local stone = PassiveData.Passives.Stoneskin and PassiveData.Passives.Stoneskin.Values[1].damageTaken or 0
local expectDt = math.max(0.1, 1 - 0.10 + stone) * (1 / (1 + ItemData.Items.IronPlate.K * 2)) * 1.3
check("A5 DamageTaken order", near(dt.DamageTaken, expectDt), string.format("%.4f vs %.4f", dt.DamageTaken, expectDt))

-- caps: cooldown, crit, speed
local maxCd = PassiveData.MaxLevelOf("Cooldown")
local fast = StatSheet.Compute({ CharacterId = "Knight", Passives = { Cooldown = maxCd }, Items = { QuickGloves = 200, CrownOfAges = 50 } })
check("A6 CooldownMult floor", near(fast.CooldownMult, I.MinCooldownMult), tostring(fast.CooldownMult))
local cdMid = StatSheet.Compute({ CharacterId = "Knight", Passives = { Cooldown = maxCd }, Items = { QuickGloves = 2 } })
local cdExpect = math.max(I.MinCooldownMult, math.max(0.4, 1 - PassiveData.Passives.Cooldown.Values[maxCd].cooldown) / (1 + 0.12))
check("A7 cooldown reduction then attack speed divides", near(cdMid.CooldownMult, cdExpect), string.format("%.4f vs %.4f", cdMid.CooldownMult, cdExpect))
local crit = StatSheet.Compute({ CharacterId = "Knight", Items = { KeenLens = 100 } })
check("A8 crit chance cap", crit.CritChance == I.MaxCritChance, tostring(crit.CritChance))
local speedy = StatSheet.Compute({ CharacterId = "Rogue", Meta = { Speed = 6 }, Items = { SwiftFeather = 100 } })
check("A9 move speed cap", near(speedy.Speed, P.BaseSpeed * I.MaxSpeedMult), tostring(speedy.Speed))

-- rank overflow / garbage levels never scale a bonus past its definition
local meta = MetaUpgradeData.Upgrades
local over = StatSheet.Compute({ CharacterId = "Knight", Meta = { Growth = 1000, Might = 0 / 0, MaxHP = math.huge, Armor = -5 } })
local capped = StatSheet.Compute({ CharacterId = "Knight", Meta = { Growth = meta.Growth.MaxLevel, MaxHP = meta.MaxHP.MaxLevel } })
check("A10 meta level overflow/NaN/inf/negative clamps", near(over.Growth, capped.Growth) and over.Might == 1 and over.MaxHP == capped.MaxHP and over.Armor == P.BaseArmor,
	string.format("Growth %.2f (cap %.2f) Might %s MaxHP %s Armor %s", over.Growth, capped.Growth, tostring(over.Might), tostring(over.MaxHP), tostring(over.Armor)))
local sigOver = StatSheet.Compute({ CharacterId = "Knight", Meta = { Signature = 99 } })
local sigMax = StatSheet.Compute({ CharacterId = "Knight", Meta = { Signature = MetaUpgradeData.Signature.Knight.MaxLevel } })
check("A11 signature level overflow clamps (same as TraitValue)", near(sigOver.DamageTaken, sigMax.DamageTaken) and near(1 - sigMax.DamageTaken, MetaUpgradeData.TraitValue("Knight", 99)),
	string.format("%.3f vs %.3f", sigOver.DamageTaken, sigMax.DamageTaken))
local pOver = StatSheet.Compute({ CharacterId = "Knight", Passives = { Might = 99 } })
local pMax = StatSheet.Compute({ CharacterId = "Knight", Passives = { Might = PassiveData.MaxLevelOf("Might") } })
check("A12 passive level overflow clamps", pOver.Might == pMax.Might, tostring(pOver.Might))
local negItems = StatSheet.Compute({ CharacterId = "Knight", Items = { Whetstone = -3 } })
check("A13 negative item count ignored", negItems.Might == 1, tostring(negItems.Might))

-- every sheet value finite at the extremes
local everything = { Passives = {}, Items = {}, Meta = {} }
for _, id in ipairs(PassiveData.Order) do everything.Passives[id] = PassiveData.MaxLevelOf(id) end
for _, id in ipairs(ItemData.Order) do everything.Items[id] = 50 end
for _, id in ipairs(MetaUpgradeData.StatOrder) do everything.Meta[id] = meta[id].MaxLevel end
local allFinite, bad = true, nil
for _, hero in ipairs(CharacterData.Order) do
	everything.CharacterId = hero
	everything.Meta.Signature = 5
	local sheet = StatSheet.Compute(everything)
	for k, v in pairs(sheet) do
		if not finite(v) then allFinite, bad = false, hero .. "." .. k end
	end
	-- weapon stats never reach a zero / negative / non-finite cooldown
	local rp = { Stats = sheet, CharacterId = hero, Meta = everything.Meta }
	for id in pairs(WeaponData.Weapons) do
		for _, evolved in ipairs({ false, true }) do
			local w = { Id = id, Level = WeaponData.MaxLevel, Evolved = evolved and WeaponData.Weapons[id].Evolution ~= nil }
			local row = WeaponData.GetStats(id, w.Level, w.Evolved)
			local cd = math.max(Config.Projectiles.MaxWeaponCooldownFloor, row.cooldown * sheet.CooldownMult)
			if not (finite(cd) and cd >= Config.Projectiles.MaxWeaponCooldownFloor) then allFinite, bad = false, id .. " cooldown" end
		end
	end
end
check("A14 maxed builds stay finite, cooldown >= floor", allFinite, bad)

-- card lines: a stat that changes is shown with the sheet's own numbers
local lines = StatSheet.Lines(base, StatSheet.Compute({ CharacterId = "Knight", Items = { HeartyBread = 1 } }))
check("A15 card line = sheet delta", #lines == 1 and lines[1].From == tostring(P.BaseMaxHP) and lines[1].To == tostring(P.BaseMaxHP + 15), lines[1] and (lines[1].From .. " -> " .. lines[1].To) or "none")

------------------------------------------------------------------------------------------
-- B. Data inventory (every class, weapon, passive, item, synergy key)
------------------------------------------------------------------------------------------
local keys = {}
for _, k in ipairs(StatSheet.BonusKeys) do keys[k] = true end
local unknown = {}
local function keysKnown(where: string, t: { [string]: any }?)
	for k in pairs(t or {}) do
		if not keys[k] then table.insert(unknown, where .. "." .. k) end
	end
end
for _, hero in ipairs(CharacterData.Order) do
	local def = CharacterData.Characters[hero]
	keysKnown(hero, def.Bonus)
	check("B1 " .. hero .. " start weapon exists and is released", WeaponData.Weapons[def.StartWeapon] ~= nil and table.find(WeaponData.Order, def.StartWeapon) ~= nil, def.StartWeapon)
end
for id, def in pairs(meta) do keysKnown("Meta." .. id, def.PerLevel) end
for hero, def in pairs(MetaUpgradeData.Signature) do keysKnown("Signature." .. hero, def.PerLevel) end
for _, id in ipairs(ItemData.Order) do keysKnown("Item." .. id, ItemData.Items[id].PerStack) end
for _, id in ipairs(SynergyData.Order) do keysKnown("Synergy." .. id, SynergyData.Synergies[id].Bonus) end
local passiveBad = {}
for _, id in ipairs(PassiveData.Order) do
	local def = PassiveData.Passives[id]
	local prev = {}
	for level, values in ipairs(def.Values) do
		keysKnown("Passive." .. id, values)
		for k, v in pairs(values) do
			-- bigger is better, except the ward's recharge time (shorter is better)
			local worse = prev[k] and (if k == "ward" then v > prev[k] + 1e-9 else math.abs(v) < math.abs(prev[k]) - 1e-9)
			if not finite(v) or worse then
				table.insert(passiveBad, id .. " L" .. level .. " " .. k)
			end
			prev[k] = v
		end
	end
end
check("B2 every stat key is a real sheet key", #unknown == 0, table.concat(unknown, ", "))
check("B3 passive values finite and never get worse with level", #passiveBad == 0, table.concat(passiveBad, ", "))
local weaponBad, released = {}, {}
for _, id in ipairs(WeaponData.Order) do released[id] = true end
local function rowOk(id: string, label: string, r)
	for _, f in ipairs({ "damage", "cooldown", "amount", "area", "speed", "pierce", "duration", "knockback" }) do
		if not finite(r[f]) or r[f] < 0 then table.insert(weaponBad, id .. " " .. label .. " " .. f) end
	end
	if not (r.cooldown > 0) then table.insert(weaponBad, id .. " " .. label .. " cooldown<=0") end
	if not (r.amount >= 1) then table.insert(weaponBad, id .. " " .. label .. " amount<1") end
	if not (r.area > 0) then table.insert(weaponBad, id .. " " .. label .. " area<=0") end
end
for id, def in pairs(WeaponData.Weapons) do
	if #def.Levels ~= WeaponData.MaxLevel then table.insert(weaponBad, id .. " has " .. #def.Levels .. " levels") end
	for level, r in ipairs(def.Levels) do rowOk(id, "L" .. level, r) end
	if def.Evolution then
		rowOk(id, "evo", def.Evolution.Stats)
		local partner = def.Evolution.Passive
		if released[id] and not table.find(PassiveData.Order, partner) then
			table.insert(weaponBad, id .. " evolution passive " .. tostring(partner) .. " not released")
		end
	end
	if not WeaponData.StatUse[def.Behavior] then table.insert(weaponBad, id .. " no StatUse") end
end
check("B4 every weapon row valid, evolution partner released", #weaponBad == 0, table.concat(weaponBad, ", "))
check("B5 XP curve matches the documented costs", true)
local XS = preview.server("XPSystem")
local costs = { [1] = 42, [20] = 270, [21] = 276, [50] = 450 }
for level, cost in pairs(costs) do
	check("B5 XPNeeded(" .. level .. ")", XS.XPNeeded(level) == cost, tostring(XS.XPNeeded(level)))
end

------------------------------------------------------------------------------------------
-- C. Live server: upgrades, XP, HP
------------------------------------------------------------------------------------------
preview.startServer()
preview.advance(1)
local me = Players.LocalPlayer
local RM = preview.server("RunManager")
local LU = preview.server("LevelUpSystem")
local WS = preview.server("WeaponSystem")
local Spawner = preview.server("EnemySpawner")
local advance = preview.advance
preview.remote("StartRun"):FireServer("Solo")
advance(2)
local rp = assert(RM.GetRunPlayer(me), "run player missing")
local function clearOffers()
	for _ = 1, 30 do
		if not rp.Offer then return end
		preview.remote("LevelUpChoose"):FireServer(1, rp.OfferSeq)
		advance(0.3)
	end
end
clearOffers()
rp.InvulnUntil = math.huge
rp.XPNeeded = 1e12 -- no stray level-ups while testing (restored where a test needs it)

local function buildSum(): number
	local n = 0
	for _, w in pairs(rp.Weapons) do n += w.Level + (w.Evolved and 1 or 0) end
	for _, l in pairs(rp.Passives) do n += l end
	return n
end

-- C1 a pick applies exactly once (same OfferId sent twice, a stale id, a bad index)
rp.XPNeeded = XS.XPNeeded(rp.Level)
LU.QueueLevels(rp, 1)
advance(0.1)
check("C1a offer open", rp.Offer ~= nil and rp.Paused == true)
local whip = rp.Weapons[rp.WeaponOrder[1]]
whip.Timer = 0.77
rp.HP = 50
local maxBefore, sumBefore, seq = rp.Stats.MaxHP, buildSum(), rp.OfferSeq
preview.remote("LevelUpChoose"):FireServer(0 / 0, seq)
preview.remote("LevelUpChoose"):FireServer(99, seq)
preview.remote("LevelUpChoose"):FireServer(1, seq)
preview.remote("LevelUpChoose"):FireServer(1, seq)
preview.remote("LevelUpChoose"):FireServer(2, seq + 7)
advance(0.02)
check("C1b one pick, applied once", buildSum() == sumBefore + 1 and rp.PendingLevels == 0 and rp.Offer == nil,
	string.format("build %d -> %d pending %d", sumBefore, buildSum(), rp.PendingLevels))
check("C1c a pick does not reset weapon cooldowns", whip.Timer <= 0.77 + 1e-9, tostring(whip.Timer))
check("C1d a pick heals only by the max-HP increase", near(rp.HP, 50 + math.max(0, rp.Stats.MaxHP - maxBefore)), string.format("HP %.2f max %d -> %d", rp.HP, maxBefore, rp.Stats.MaxHP))
rp.XPNeeded = 1e12

-- C2 stale cards at max rank never overflow (WeaponUp / PassiveUp past the cap)
local wid = rp.WeaponOrder[1]
rp.Weapons[wid].Level = WeaponData.MaxLevel
rp.Weapons[wid].Evolved = false
if not rp.Passives.Might then table.insert(rp.PassiveOrder, "Might") end
rp.Passives.Might = PassiveData.MaxLevelOf("Might")
LU.RecomputeStats(rp)
rp.PendingLevels, rp.BatchRemaining, rp.BatchTotal, rp.Paused = 2, 2, 2, true
rp.OfferSeq += 1
rp.Offer = { { Type = "WeaponUp", Id = wid, Level = WeaponData.MaxLevel + 1 }, { Type = "PassiveUp", Id = "Might", Level = 99 } }
preview.remote("LevelUpChoose"):FireServer(1, rp.OfferSeq)
advance(0.02)
rp.Offer = { { Type = "PassiveUp", Id = "Might", Level = 99 } }
rp.Paused = true
rp.OfferSeq += 1
preview.remote("LevelUpChoose"):FireServer(1, rp.OfferSeq)
advance(0.02)
LU.Cancel(rp)
check("C2 stale max-rank cards cap", rp.Weapons[wid].Level == WeaponData.MaxLevel and rp.Passives.Might == PassiveData.MaxLevelOf("Might"),
	string.format("%s L%d, Might L%d", wid, rp.Weapons[wid].Level, rp.Passives.Might))
-- C3 a free chest level on a maxed build gives no rank past the cap
for _, id in ipairs(rp.PassiveOrder) do rp.Passives[id] = PassiveData.MaxLevelOf(id) end
for _, id in ipairs(rp.WeaponOrder) do rp.Weapons[id].Level = WeaponData.MaxLevel end
rp.Weapons[wid].Evolved = true -- nothing left to evolve either
LU.OpenChest(rp)
local over = false
for _, w in pairs(rp.Weapons) do if w.Level > WeaponData.MaxLevel then over = true end end
for id, l in pairs(rp.Passives) do if l > PassiveData.MaxLevelOf(id) then over = true end end
check("C3 chest level on a maxed build stays capped", not over)
advance(4) -- reward hold ends
clearOffers()
rp.Weapons[wid].Evolved = false

-- C4 XP: multi-level overflow carries the remainder, Growth/Coop/Pace multiply once
LU.Cancel(rp)
rp.XP = 0
rp.XPNeeded = XS.XPNeeded(rp.Level)
local L0 = rp.Level
local need2 = XS.XPNeeded(L0) + XS.XPNeeded(L0 + 1)
XS.GiveXP(rp, need2 + 3)
check("C4a two levels, remainder kept", rp.Level == L0 + 2 and near(rp.XP, 3) and rp.XPNeeded == XS.XPNeeded(L0 + 2),
	string.format("L%d -> L%d XP %.2f", L0, rp.Level, rp.XP))
LU.Cancel(rp)
rp.XPNeeded = 1e12
local x0 = rp.XP
XS.GiveXP(rp, 0 / 0)
XS.GiveXP(rp, -50)
XS.GiveXP(rp, math.huge) -- before the guard this spun forever
check("C4b NaN / negative / infinite XP ignored", rp.XP == x0 and rp.Level == L0 + 2, tostring(rp.XP))
rp.Meta = { Growth = meta.Growth.MaxLevel }
if not rp.Passives.Growth then table.insert(rp.PassiveOrder, "Growth") end
rp.Passives.Growth = PassiveData.MaxLevelOf("Growth")
LU.RecomputeStats(rp)
local growth = rp.Stats.Growth
local expectGrowth = 1 + meta.Growth.MaxLevel * 0.05 + PassiveData.Passives.Growth.Values[PassiveData.MaxLevelOf("Growth")].growth
x0 = rp.XP
XS.GiveSharedXP(10)
local gained = rp.XP - x0
local expectGain = 10 * XS.CoopShare() * XS.PaceMult() * expectGrowth
check("C4c stacked Growth is additive, applied once per gem", near(growth, expectGrowth) and near(gained, expectGain),
	string.format("Growth %.2f gain %.3f vs %.3f (coop %.2f pace %.2f)", growth, gained, expectGain, XS.CoopShare(), XS.PaceMult()))

-- C5 max-HP changes: increase heals the delta, decrease clamps, never above max
rp.Meta, rp.Items = {}, {}
LU.RecomputeStats(rp)
local m0 = rp.Stats.MaxHP
RM.Heal(rp, 1e9)
check("C5a heal clamps to max", rp.HP == m0, string.format("%.1f/%d", rp.HP, m0))
rp.HP = 40
rp.Items = { HeartyBread = 2 }
LU.RecomputeStats(rp)
check("C5b +30 max HP heals exactly 30", rp.Stats.MaxHP == m0 + 30 and near(rp.HP, 70), string.format("%.1f/%d", rp.HP, rp.Stats.MaxHP))
LU.RecomputeStats(rp)
check("C5c recompute without change does not heal", near(rp.HP, 70), tostring(rp.HP))
rp.HP = rp.Stats.MaxHP
rp.Items = {}
LU.RecomputeStats(rp)
check("C5d max HP drop clamps HP", rp.HP == m0 and me:GetAttribute("HP") == m0 and me:GetAttribute("MaxHP") == m0, string.format("%.1f/%d attr %s", rp.HP, rp.Stats.MaxHP, tostring(me:GetAttribute("HP"))))

-- C6 heal input validation
rp.HP = 60
RM.Heal(rp, 0 / 0)
RM.Heal(rp, -25)
RM.Heal(rp, -math.huge)
check("C6 heal ignores NaN / negative", rp.HP == 60 and rp.Alive, tostring(rp.HP))

-- C7 damage formula: max(MinDamagePerHit, raw x DamageTaken - armor), invalid ignored
rp.InvulnUntil = 0
rp.HP = 100
local s = rp.Stats
RM.DamagePlayer(rp, 20, "test")
local expect = math.max(P.MinDamagePerHit, 20 * s.DamageTaken - s.Armor)
check("C7a hit = raw x DamageTaken - armor", near(rp.HP, 100 - expect), string.format("HP %.2f expect %.2f", rp.HP, 100 - expect))
local h = rp.HP
RM.DamagePlayer(rp, 0 / 0, "nan")
RM.DamagePlayer(rp, -10, "neg")
RM.DamagePlayer(rp, math.huge, "inf")
check("C7b NaN / negative / inf damage ignored", rp.HP == h, tostring(rp.HP))
rp.Stats.Armor = 1000
RM.DamagePlayer(rp, 5, "armor")
check("C7c armor never below the minimum hit", near(rp.HP, h - P.MinDamagePerHit), tostring(rp.HP))
LU.RecomputeStats(rp)

-- C8 enemy damage: NaN / zero never touch HP
Spawner.DespawnAll()
local dummy = assert(Spawner.Spawn("Bat", rp.Root.Position + Vector3.new(6, 0, 0), { Force = true, HP = 1e6 }))
Spawner.Damage(dummy, 0 / 0, rp)
Spawner.Damage(dummy, 0, rp)
Spawner.Damage(dummy, -5, rp)
check("C8 enemy HP ignores NaN / zero / negative", dummy.HP == dummy.MaxHP and dummy.Alive, tostring(dummy.HP))
Spawner.Despawn(dummy)

-- C9 MATH-15: "Damage dealt" counts the HP really removed, not the overkill
local weak = assert(Spawner.Spawn("Bat", rp.Root.Position + Vector3.new(6, 0, 0), { Force = true, HP = 30 }))
local weakHP = weak.HP
local dealtBefore = rp.DamageDealt
Spawner.Damage(weak, 1000, rp, nil, 0, true) -- a proc: no crit, no item multipliers
check("C9 MATH-15 overkill not counted as damage dealt", near(rp.DamageDealt - dealtBefore, weakHP), string.format("+%.1f for a %.1f HP enemy", rp.DamageDealt - dealtBefore, weakHP))
Spawner.Despawn(weak)
local strong = assert(Spawner.Spawn("Bat", rp.Root.Position + Vector3.new(6, 0, 0), { Force = true, HP = 1e6 }))
dealtBefore = rp.DamageDealt
Spawner.Damage(strong, 25, rp, nil, 0, true)
check("C9b a hit that does not kill counts in full", near(rp.DamageDealt - dealtBefore, 25), string.format("+%.1f", rp.DamageDealt - dealtBefore))
Spawner.Despawn(strong)

-- C10 MATH-17: Windstep's burst never takes Speed past BaseSpeed x Items.MaxSpeedMult, even
-- when the speed rises during the burst (the multiplier was capped once, at its start)
local speedCap = P.BaseSpeed * I.MaxSpeedMult
local savedSpeed = rp.Stats.Speed
rp.Stats.Speed = P.BaseSpeed
rp.RushMult = 1.8 -- what OnKill stores at BaseSpeed (cap 2.2)
local rushLow = RM.RushMult(rp)
rp.Stats.Speed = P.BaseSpeed * 1.6 -- a speed pick during the burst
RM.ApplyMovement(rp)
local rushHigh = RM.RushMult(rp)
local hum = rp.Humanoid
local ws = hum and hum.WalkSpeed or 0
local env = (rp.TerrainSpeedMult or 1) * (rp.WeatherSpeedMult or 1)
check("C10 MATH-17 Windstep re-capped when speed rises mid-burst", near(rushLow, 1.8) and rp.Stats.Speed * rushHigh <= speedCap + 1e-6 and ws <= speedCap * env + 1e-6,
	string.format("rush %.3f -> %.3f, speed x rush %.2f (cap %.2f), WalkSpeed %.2f", rushLow, rushHigh, rp.Stats.Speed * rushHigh, speedCap, ws))
rp.Stats.Speed = speedCap * 2
check("C10b the burst never slows below x1", RM.RushMult(rp) == 1, string.format("%.3f", RM.RushMult(rp)))
rp.RushMult = nil
rp.Stats.Speed = savedSpeed
LU.RecomputeStats(rp)
RM.ApplyMovement(rp)

------------------------------------------------------------------------------------------
-- D. Controlled-target combat: each released weapon alone, predicted vs observed hits
------------------------------------------------------------------------------------------
rp.InvulnUntil = math.huge
rp.Meta, rp.Items = {}, {}
local realDamage = Spawner.Damage
local log = nil
Spawner.Damage = function(e, amount, who, ...)
	if log and e == log.Target and who == rp then
		table.insert(log.Hits, { Amount = amount, Proc = select(3, ...) == true })
	end
	return realDamage(e, amount, who, ...)
end
-- hits that are a share of the main hit by design (chains, shards, bursts, ticks)
local SHARE_OK = { Sling = true }
local MUST_HIT = { Whip = true, Garlic = true, Lightning = true, MagicOrb = true, Knives = true, Spear = true, Longbow = true }
local summary = {}
for _, id in ipairs(WeaponData.Order) do
	for k in pairs(rp.Weapons) do rp.Weapons[k] = nil end
	table.clear(rp.WeaponOrder)
	table.clear(rp.Passives)
	table.clear(rp.PassiveOrder)
	WS.ClearOwner(rp)
	advance(0.05)
	LU.AddWeapon(rp, id)
	LU.RecomputeStats(rp)
	WS.OnInventoryChanged(rp)
	rp.Stats.CritChance = 0
	Spawner.DespawnAll()
	-- a training dummy 4 studs in front of the hero (where facing weapons aim), put back
	-- every 0.1 s so knockback and its own AI never carry it out of reach
	local function spot(): Vector3
		return rp.Root.Position + rp.Facing * 4
	end
	local target = assert(Spawner.Spawn("Bat", spot(), { Force = true, HP = 1e7 }))
	target.SlowUntil, target.SlowMult = math.huge, 0
	local w = rp.Weapons[id]
	local stats = WS.WeaponStats(rp, w)
	log = { Target = target, Hits = {} }
	local window = 4
	for _ = 1, window * 10 do
		target.Pos, target.Knock = spot(), Vector3.zero
		advance(0.1)
	end
	local hits = log.Hits
	log = nil
	local total, maxHit, full = 0, 0, 0
	for _, hit in ipairs(hits) do
		total += hit.Amount
		maxHit = math.max(maxHit, hit.Amount)
		if near(hit.Amount, stats.damage, 1e-4) then full += 1 end
	end
	local lost = target.MaxHP - target.HP
	local ok = near(lost, total, 1e-6) -- HP lost == sum of the server's hits (no crit, no hidden multiplier)
	if not SHARE_OK[id] and maxHit > stats.damage * (1 + 1e-6) then ok = false end
	if MUST_HIT[id] and full == 0 then ok = false end
	table.insert(summary, string.format("%s dmg %.1f cd %.2f amt %d: %d hits (%d full), max %.1f, HP lost %.1f", id, stats.damage, stats.cooldown, stats.amount, #hits, full, maxHit, lost))
	check("D " .. id .. " observed hits match prediction", ok, summary[#summary])
	if id == "Garlic" then
		-- one ring tick per cooldown (first tick at the 0.3 s add timer)
		local expectTicks = math.floor((window - 0.3) / stats.cooldown) + 1
		check("D Garlic cadence", math.abs(full - expectTicks) <= 1, string.format("%d ticks vs %d", full, expectTicks))
		-- MATH-13 (owner OK 2026-10-05): the time past zero carries into the next cooldown;
		-- a long hitch carries at most one cooldown (one extra attack, on the next frame)
		local f = 1 / 60
		target.Pos, target.Knock = spot(), Vector3.zero
		w.Timer = 0.005
		WS.Step(f)
		check("D MATH-13 leftover carries over", near(w.Timer, stats.cooldown - (f - 0.005), 1e-9), string.format("%.6f vs %.6f", w.Timer, stats.cooldown - (f - 0.005)))
		w.Timer = 0.005
		WS.Step(5)
		check("D MATH-13 hitch carry capped (timer 0, not negative)", near(w.Timer, 0, 1e-9), string.format("%.6f", w.Timer))
		WS.Step(f)
		check("D MATH-13 one extra attack, then normal cadence", near(w.Timer, stats.cooldown - f, 1e-9), string.format("%.6f vs %.6f", w.Timer, stats.cooldown - f))
		-- 60 Hz over 3 s: fires == floor(3 / cooldown) (+-1 at the window edge), no lost frames
		local fires, frames = 0, 180
		w.Timer = stats.cooldown
		for _ = 1, frames do
			local before = w.Timer
			WS.Step(f)
			if w.Timer > before then fires += 1 end
		end
		local exact = math.floor(frames * f / stats.cooldown)
		check("D MATH-13 60 Hz cadence = 3 s / cooldown", math.abs(fires - exact) <= 1 and fires >= exact, string.format("%d fires vs %d (cd %.3f)", fires, exact, stats.cooldown))
	end
	Spawner.Despawn(target)
end
-- crits multiply once (x CritDamage), procs never crit
for k in pairs(rp.Weapons) do rp.Weapons[k] = nil end
table.clear(rp.WeaponOrder)
WS.ClearOwner(rp)
LU.RecomputeStats(rp)
rp.Stats.CritChance = 1
local target = assert(Spawner.Spawn("Bat", rp.Root.Position + Vector3.new(5, 0, 0), { Force = true, HP = 1e6 }))
Spawner.Damage(target, 10, rp)
local critLoss = target.MaxHP - target.HP
Spawner.Damage(target, 10, rp, nil, 0, true)
local procLoss = target.MaxHP - target.HP - critLoss
check("D crit x CritDamage once, proc never crits", near(critLoss, 10 * rp.Stats.CritDamage) and near(procLoss, 10), string.format("crit %.1f proc %.1f", critLoss, procLoss))
Spawner.Despawn(target)
Spawner.Damage = realDamage
LU.RecomputeStats(rp)

------------------------------------------------------------------------------------------
-- F. Dev "Next stage" during a boss fight removes the boss (audit W-08; dev only)
------------------------------------------------------------------------------------------
local SM = preview.server("StageManager")
Spawner.DespawnAll()
local stageBefore = SM.GetStage()
local activated = SM.DevActivate()
for _ = 1, 150 do
	if Spawner.Boss and Spawner.Boss.Alive then break end
	advance(0.1)
end
local liveBoss = Spawner.Boss
local hadBoss = liveBoss ~= nil and liveBoss.Alive
local moved = SM.DevNextStage()
local stateObj = game:GetService("ReplicatedStorage"):FindFirstChild("SwarmState")
check("F1 dev Next stage removes a live boss", activated and hadBoss and moved and Spawner.Boss == nil and not (liveBoss and liveBoss.Alive)
	and (stateObj == nil or stateObj:GetAttribute("BossName") == nil),
	string.format("activated %s boss %s next %s phase %s boss after %s", tostring(activated), tostring(hadBoss), tostring(moved), SM.GetPhase(), tostring(Spawner.Boss)))
for _ = 1, 200 do
	if SM.GetStage() > stageBefore and SM.GetPhase() == "Explore" then break end
	advance(0.1)
end
check("F2 the next stage starts with no boss", SM.GetStage() == stageBefore + 1 and SM.GetPhase() == "Explore" and Spawner.Boss == nil,
	string.format("stage %d -> %d phase %s", stageBefore, SM.GetStage(), SM.GetPhase()))
rp.InvulnUntil = math.huge

------------------------------------------------------------------------------------------
-- E. Lethal hits (last: the run ends)
------------------------------------------------------------------------------------------
rp.InvulnUntil = 0
rp.RevivesLeft = 1
rp.HP = 10
RM.DamagePlayer(rp, 500, "first")
local afterFirst = rp.HP
RM.DamagePlayer(rp, 500, "second") -- same frame
check("E1 two lethal hits in one frame use one extra life", rp.Alive and rp.RevivesLeft == 0 and near(afterFirst, rp.Stats.MaxHP * P.ReviveHPFraction) and rp.HP == afterFirst,
	string.format("alive %s lives %d HP %.1f", tostring(rp.Alive), rp.RevivesLeft, rp.HP))
rp.InvulnUntil = 0
rp.HP = 5
rp.Items = {}
RM.DamagePlayer(rp, 500, "lethal")
RM.Heal(rp, 50) -- a heal on the same frame (regen, totem) never lifts a fallen hero
RM.DamagePlayer(rp, 500, "after")
check("E2 heal on the lethal frame does nothing, HP clamps at 0", not rp.Alive and rp.HP == 0 and me:GetAttribute("HP") == 0, string.format("alive %s HP %s", tostring(rp.Alive), tostring(rp.HP)))

local failed = 0
for _, r in ipairs(results) do
	if not r[2] then failed += 1 end
end
preview.log(string.format("%s: math-regression %d/%d checks", failed == 0 and "PASS" or "FAIL", #results - failed, #results))
assert(failed == 0, failed .. " math checks failed")
