-- passives-regression: boots the REAL server and checks that each behaviour passive
-- (PassiveData: Giant's Bane, Thornhide, Blood Rune, Aegis Charm, Windstep, Gilded Purse,
-- Stoneskin, Second Wind, Ember Oil, Lionheart) changes the stat it names AND that the
-- system reading that stat really does it (ItemSystem / RunManager / XPSystem hooks).
-- run: lune run tools/preview/runtime/main.luau -- --scene passives-regression --studio
--      --device pc --max-time 200 --set headless=on
local C = lib("common")
local Players = game:GetService("Players")
preview.startServer()
preview.advance(1)
local me = Players.LocalPlayer
local RM = preview.server("RunManager")
local LU = preview.server("LevelUpSystem")
local IS = preview.server("ItemSystem")
local XS = preview.server("XPSystem")
local Spawner = preview.server("EnemySpawner")
local PassiveData = C.shared("PassiveData")
local StatSheet = C.shared("StatSheet")
local advance = preview.advance

preview.remote("StartRun"):FireServer("Solo")
advance(2)
local rp = assert(RM.GetRunPlayer(me), "run player missing")
local function clearOffers()
	for _ = 1, 30 do
		if not rp.Paused then
			return
		end
		preview.remote("LevelUpChoose"):FireServer(1)
		advance(0.3)
	end
end
clearOffers()
rp.InvulnUntil = math.huge

-- every new passive: real data shape and a visible card line at each level
local NEW = { "GiantsBane", "Thornhide", "BloodRune", "AegisCharm", "Windstep", "GildedPurse", "Stoneskin", "SecondWind", "EmberOil", "Lionheart", "StillWaters" }
local base = StatSheet.Compute({ CharacterId = rp.CharacterId })
for _, id in ipairs(NEW) do
	local def = assert(PassiveData.Passives[id], id .. " missing")
	-- released (Order) or held for a later update (HeldOrder), never both
	local released, held = table.find(PassiveData.Order, id) ~= nil, table.find(PassiveData.HeldOrder or {}, id) ~= nil
	assert(released ~= held, id .. " must be in exactly one of Order / HeldOrder")
	assert(#def.Description <= 48, id .. " card text too long")
	local prev = base
	for level = 1, PassiveData.MaxLevelOf(id) do
		local sheet = StatSheet.Compute({ CharacterId = rp.CharacterId, Passives = { [id] = level } })
		local lines = StatSheet.Lines(prev, sheet)
		assert(#lines >= 1, id .. " level " .. level .. " changes no stat line")
		preview.log(string.format("  %s L%d: %s %s -> %s", id, level, lines[1].Label, lines[1].From, lines[1].To))
		prev = sheet
	end
end

local function give(id: string, level: number)
	if not rp.Passives[id] then
		table.insert(rp.PassiveOrder, id)
	end
	rp.Passives[id] = level
	LU.RecomputeStats(rp)
end
local function drop(id: string)
	rp.Passives[id] = nil
	local i = table.find(rp.PassiveOrder, id)
	if i then table.remove(rp.PassiveOrder, i) end
	LU.RecomputeStats(rp)
end
local function enemy(dx: number, elite: boolean?)
	local e = assert(Spawner.Spawn("Bat", rp.Root.Position + Vector3.new(dx, 0, 0), { Elite = elite, Affix = elite and "Swift" or nil, Force = true, HP = 100000 }))
	return e
end
local function noCrit()
	rp.Stats.CritChance = 0
end
local results = {}
local function check(name: string, ok: boolean, detail: string)
	table.insert(results, { name, ok })
	preview.log(string.format("%s %s: %s", ok and "PASS" or "FAIL", name, detail))
end

-- Giant's Bane: elites take +45%, normal enemies don't
give("GiantsBane", 3)
noCrit()
local el, nm = enemy(30, true), enemy(-30)
local h1, h2 = el.HP, nm.HP
Spawner.Damage(el, 100, rp)
Spawner.Damage(nm, 100, rp)
check("GiantsBane", rp.Stats.EliteDamage == 1.45 and math.abs((h1 - el.HP) - 145) < 0.01 and math.abs((h2 - nm.HP) - 100) < 0.01,
	string.format("EliteDamage %.2f, elite took %.1f, normal took %.1f", rp.Stats.EliteDamage, h1 - el.HP, h2 - nm.HP))
drop("GiantsBane")

-- Lionheart: +50% below 40% HP only
give("Lionheart", 3)
noCrit()
rp.HP = rp.Stats.MaxHP
local a = nm.HP; Spawner.Damage(nm, 100, rp); local full = a - nm.HP
rp.HP = rp.Stats.MaxHP * 0.3
a = nm.HP; Spawner.Damage(nm, 100, rp); local low = a - nm.HP
check("Lionheart", math.abs(full - 100) < 0.01 and math.abs(low - 150) < 0.01, string.format("full HP %.1f, low HP %.1f", full, low))
drop("Lionheart")

-- Blood Rune: a crit heals 3
give("BloodRune", 3)
rp.Stats.CritChance = 1
rp.HP = rp.Stats.MaxHP - 20
local hp0 = rp.HP
Spawner.Damage(nm, 10, rp)
check("BloodRune", rp.Stats.CritHeal == 3 and math.abs(rp.HP - hp0 - 3) < 0.01, string.format("CritHeal %d, healed %.1f", rp.Stats.CritHeal, rp.HP - hp0))
drop("BloodRune")

-- Ember Oil: a hit sets the enemy burning; burn ticks keep hurting it
give("EmberOil", 3)
noCrit()
local burnSheet = rp.Stats.BurnChance
rp.Stats.BurnChance = 1
Spawner.Damage(nm, 100, rp)
local afterHit = nm.HP
local burning = IS.BurnCount()
advance(1.6)
check("EmberOil", burnSheet == 0.2 and burning >= 1 and afterHit - nm.HP >= 29, string.format("BurnChance %.2f, burning %d, burn damage %.1f in 1.6 s", burnSheet, burning, afterHit - nm.HP))
drop("EmberOil")
clearOffers()

-- Thornhide: being hit hurts a nearby enemy
give("Thornhide", 3)
local near = enemy(3)
advance(0.1) -- the spawner files new enemies into its grid on its next step
local nh = near.HP
rp.HP = rp.Stats.MaxHP
rp.InvulnUntil = 0
RM.DamagePlayer(rp, 20, "test")
rp.InvulnUntil = math.huge
check("Thornhide", rp.Stats.Thorns == 2.5 and nh - near.HP > 20, string.format("Thorns %.1f, enemy took %.1f", rp.Stats.Thorns, nh - near.HP))
drop("Thornhide")

-- Stoneskin: 18% less damage
local function hitFor(amount: number): number
	rp.HP = rp.Stats.MaxHP
	rp.InvulnUntil = 0
	local before = rp.HP
	RM.DamagePlayer(rp, amount, "test")
	rp.InvulnUntil = math.huge
	local took = before - rp.HP
	rp.HP = rp.Stats.MaxHP
	return took
end
local plain = hitFor(100)
give("Stoneskin", 3)
local stone = hitFor(100)
check("Stoneskin", stone < plain - 10, string.format("DamageTaken %.2f, hit 100 took %.1f (was %.1f)", rp.Stats.DamageTaken, stone, plain))
drop("Stoneskin")

-- Aegis Charm: the ready ward blocks one whole hit, the next one lands
give("AegisCharm", 3)
advance(0.2)
local w1 = hitFor(50)
local w2 = hitFor(50)
check("AegisCharm", rp.Stats.WardSeconds == 8 and w1 == 0 and w2 > 0, string.format("WardSeconds %d, first hit %.1f, second %.1f", rp.Stats.WardSeconds, w1, w2))
advance(8.5)
local w3 = hitFor(50)
check("AegisCharm recharge", w3 == 0, string.format("after 8.5 s the ward blocked again (took %.1f)", w3))
drop("AegisCharm")
clearOffers()

-- Windstep: a kill gives a short speed burst, then it ends
give("Windstep", 3)
local victim = enemy(-20)
Spawner.Damage(victim, 1e7, rp)
local mult = rp.RushMult
local ws = rp.Humanoid and rp.Humanoid.WalkSpeed or 0
-- the running weapons keep killing (and refreshing the burst): drop the passive, then the
-- last burst must run out on its own
drop("Windstep")
advance(2)
clearOffers()
check("Windstep", mult ~= nil and mult > 1.15 and ws > rp.Stats.Speed and rp.RushMult == nil,
	string.format("mult %s, WalkSpeed %.1f vs %.1f, ended %s", tostring(mult), ws, rp.Stats.Speed, tostring(rp.RushMult == nil)))

-- Second Wind: a level-up heals 20% max HP
give("SecondWind", 3)
rp.HP = 10
XS.GiveXP(rp, rp.XPNeeded + 0.01)
local healed = rp.HP - 10
check("SecondWind", math.abs(healed - rp.Stats.MaxHP * 0.2) < 0.6, string.format("LevelHeal %.2f, healed %.1f of %d", rp.Stats.LevelHeal, healed, rp.Stats.MaxHP))
clearOffers()
drop("SecondWind")

-- Gilded Purse: the gold multiplier every gold source reads (GoldSystem, chests, bosses)
give("GildedPurse", 3)
check("GildedPurse", rp.Stats.GoldMult == 1.5, string.format("GoldMult %.2f", rp.Stats.GoldMult))
drop("GildedPurse")

-- Renewal regenerates even with no run items (ItemSystem.Step used to skip item-less players)
local savedItems = rp.Items
rp.Items = {}
give("Renewal", 3)
rp.HP = 50
advance(2)
clearOffers()
check("Renewal without items", rp.HP > 52, string.format("HP 50 -> %.1f in 2 s", rp.HP))
rp.Items = savedItems
drop("Renewal")

-- Still Waters: standing still heals ~5% max HP per second; moving or a hit stops it
give("StillWaters", 3)
rp.Root.Anchored = true -- hold the hero still (the server reads its real position)
rp.HP = rp.Stats.MaxHP * 0.3
local s0 = rp.HP
advance(2.75) -- 0.75 s wait, then 2 s of healing
clearOffers()
local still = rp.HP - s0
-- moving: nudge the hero every step, it must not heal
rp.HP = rp.Stats.MaxHP * 0.3
local m0 = rp.HP
for i = 1, 20 do
	rp.Root.CFrame = rp.Root.CFrame + Vector3.new(i % 2 == 0 and 1 or -1, 0, 0)
	advance(0.1)
end
clearOffers()
local moving = rp.HP - m0
-- a hit pauses it
advance(1)
local h0 = rp.HP
rp.ItemState.LastHurt = os.clock()
advance(0.5)
local afterHit = rp.HP - h0
rp.Root.Anchored = false
check("StillWaters", rp.Stats.StillHeal == 0.05 and still > rp.Stats.MaxHP * 0.08 and still < rp.Stats.MaxHP * 0.12 and moving < 0.5 and afterHit < 0.5,
	string.format("StillHeal %.3f, still healed %.1f in 2.75 s, moving %.1f, after a hit %.1f", rp.Stats.StillHeal, still, moving, afterHit))
drop("StillWaters")

local failed = 0
for _, r in ipairs(results) do
	if not r[2] then failed += 1 end
end
preview.log(string.format("%s: %d/%d passive checks", failed == 0 and "PASS" or "FAIL", #results - failed, #results))
assert(failed == 0, "passive checks failed")
