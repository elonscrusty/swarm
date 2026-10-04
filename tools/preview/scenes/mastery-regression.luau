-- mastery-regression: Hero Mastery against the real server modules.
--   * a run reads the selected hero's own stat track + Signature (never the old shared Meta stats)
--   * a committed run gives mastery XP only to the hero played; a DEV-tainted run gives none
--   * BuyHeroUpgrade: locked hero / over the mastery cap / stale level / short gold are refused
--   * every signature level changes its stat in-run
local player = game:GetService("Players").LocalPlayer
preview.startServer()
preview.advance(1)
local RM = preview.server("RunManager")
local DS = preview.server("DataService")
local GS = preview.server("GoldSystem")
local WS = preview.server("WeaponSystem")
local Meta = preview.shared("MetaUpgradeData")
local StatSheet = preview.shared("StatSheet")
local Config = preview.shared("Config")
local CharacterData = preview.shared("CharacterData")

local data = assert(DS.GetData(player), "profile missing")
data.OwnedCharacters = { Knight = true, Mage = true }
data.SelectedCharacter = "Knight"
data.Meta = { MaxHP = 9, Might = 9, Revive = 1 } -- old shared stat levels stay but are not read
data.HeroUpgrades = { Knight = { MaxHP = 4, Signature = 2 }, Mage = { MaxHP = 1 } }
data.Heroes = {}

-- 1) the run uses the Knight's track
preview.remote("StartRun"):FireServer("Solo")
preview.advance(3)
local rp = assert(RM.GetRunPlayer(player), "run player missing")
assert(rp.Meta.MaxHP == 4 and rp.Meta.Signature == 2 and rp.Meta.Revive == 1, "run must merge account ids + the hero's track")
assert(rp.Meta.Might == nil, "the old shared Might level must not reach the run")
local sheet = StatSheet.Compute({ CharacterId = "Knight", Meta = rp.Meta })
assert(sheet.MaxHP == Config.Player.BaseMaxHP + 40, "Knight sheet must use the Knight's Max HP track: " .. sheet.MaxHP)
assert(math.abs(sheet.DamageTaken - 0.86) < 1e-6, "Iron Skin level 2 must give -14% damage taken: " .. sheet.DamageTaken)
assert(rp.RevivesLeft == 1, "account Revive must still apply")

-- 2) a committed run gives mastery XP only to the hero played
rp.Kills = 200
preview.advance(30)
RM.AbandonRun(rp)
preview.advance(1)
local k = data.Heroes.Knight
assert(type(k) == "table" and k.XP > 0 and k.Runs == 1, "the Knight must get mastery XP and a run")
assert(data.Heroes.Mage == nil, "a hero not played must get nothing")
assert(k.XP <= (preview.shared("AccountData").XP.MaxRun), "mastery XP must keep the account MaxRun cap")
local knightXP = k.XP
preview.log(string.format("PASS mastery to the hero played: Knight +%d XP", knightXP))

-- 3) a DEV-tainted run gives none
preview.advance(Config.Run.ResultsSeconds + 2)
preview.remote("StartRun"):FireServer("Solo")
preview.advance(3)
rp = assert(RM.GetRunPlayer(player), "second run player missing")
rp.DevTainted = true
rp.Kills = 300
preview.advance(20)
RM.AbandonRun(rp)
preview.advance(1)
assert(data.Heroes.Knight.XP == knightXP and data.Heroes.Knight.Runs == 1, "a DEV-tainted run must not give mastery")
preview.log("PASS no mastery on DEV-tainted runs")

-- 4) BuyHeroUpgrade checks (in the lobby)
preview.advance(Config.Run.ResultsSeconds + 2)
assert(not RM.IsParticipant(player), "player must be back in the lobby")
local buy = GS._BuyHeroUpgrade
data.Gold = 5000
data.Heroes.Knight.XP = 0 -- mastery 1: stats up to level 2
buy(player, "Rogue", "MaxHP", 0)
assert(data.HeroUpgrades.Rogue == nil and data.Gold == 5000, "a hero not owned must be refused")
buy(player, "Knight", "MaxHP", 4)
assert(data.HeroUpgrades.Knight.MaxHP == 4 and data.Gold == 5000, "over the mastery cap must be refused")
buy(player, "Knight", "Bogus", 0)
assert(data.Gold == 5000, "an unknown upgrade must be refused")
buy(player, "Knight", "Revive", 0)
assert(data.Gold == 5000 and data.HeroUpgrades.Knight.Revive == nil, "account upgrades are not hero upgrades")
buy(player, "Knight", "Might", 1)
assert(data.HeroUpgrades.Knight.Might == nil and data.Gold == 5000, "a stale level must be refused")
buy(player, "Knight", "Might", 0)
assert(data.HeroUpgrades.Knight.Might == 1 and data.Gold == 5000 - 300, "a valid purchase must buy one level")
buy(player, "Knight", "Might", 0)
assert(data.HeroUpgrades.Knight.Might == 1, "a double tap must buy one level only")
data.Gold = 10
buy(player, "Knight", "Might", 1)
assert(data.HeroUpgrades.Knight.Might == 1 and data.Gold == 10, "short gold must be refused")
data.Gold = 5000
buy(player, "Knight", "Signature", 2)
assert(data.HeroUpgrades.Knight.Signature == 2, "signature level 3 needs mastery 6")
data.Heroes.Knight.XP = 1e6 -- max mastery
buy(player, "Knight", "Signature", 2)
assert(data.HeroUpgrades.Knight.Signature == 3 and data.Gold == 5000 - 1280, "signature level 3 costs 1,280 at mastery 10")
preview.remote("BuyMeta"):FireServer("MaxHP", 9)
preview.advance(0.5)
assert(data.Meta.MaxHP == 9, "BuyMeta must refuse stat ids now")
preview.log("PASS BuyHeroUpgrade refuses locked hero, over cap, stale level, short gold")

-- 5) every signature level changes its stat
local costs = {}
for l = 0, 4 do
	table.insert(costs, Meta.HeroCostOf("Knight", "Signature", l))
end
assert(table.concat(costs, ",") == "500,800,1280,2048,3277", "signature prices: " .. table.concat(costs, ","))
-- owner: no per-hero stat level costs more than MaxStatLevelCost (20,000); cheaper levels unchanged
assert(Meta.MaxStatLevelCost == 20000, "stat level cap")
for _, upgradeId in ipairs(Meta.StatOrder) do
	local def = Meta.HeroDef("Knight", upgradeId)
	for l = 0, def.MaxLevel - 1 do
		local raw = math.floor(def.BaseCost * def.CostGrowth ^ l + 0.5)
		local cost = Meta.HeroCostOf("Knight", upgradeId, l)
		assert(cost == math.min(raw, 20000), upgradeId .. " level " .. (l + 1) .. " costs " .. tostring(cost))
	end
	assert(Meta.HeroCostOf("Knight", upgradeId, def.MaxLevel) == nil, upgradeId .. " maxed has no price")
end
assert(Meta.HeroCostOf("Knight", "MaxHP", 12) == 20000 and Meta.HeroCostOf("Knight", "MaxHP", 11) < 20000, "Max HP level 13 is capped, level 12 is not")
-- owner: achievement heroes have real goals
local Ach = preview.shared("AchievementData").Achievements
assert(Ach.QueenSlayer.Goal == 3 and Ach.QueenSlayer.Reward.Character == "Ranger", "Ranger: beat the Scorpion Queen 3 times")
assert(Ach.Reaper.Goal == 1500 and Ach.Reaper.Kind == "Max" and Ach.Reaper.Reward.Character == "Necromancer", "Necromancer: 1,500 kills in one run")
assert(Ach.FieldEngineer.Goal == 5 and Ach.FieldEngineer.Filter and Ach.FieldEngineer.Filter.Kind == "Altar"
	and Ach.FieldEngineer.Reward.Character == "Engineer", "Engineer: 5 Guarded Altars, Bargains don't count")
preview.log("PASS stat level cost cap and achievement hero goals")
local function sheetAt(hero, level)
	return StatSheet.Compute({ CharacterId = hero, Meta = { Signature = level } })
end
local fakeRp = function(hero, level)
	local r = { CharacterId = hero, Meta = { Signature = level }, Player = player, MoveDir = Vector3.zero }
	r.Stats = StatSheet.Compute({ CharacterId = hero, Meta = r.Meta })
	return r
end
local expect = {
	Knight = { 0.90, 0.80, function(l) return sheetAt("Knight", l).DamageTaken end },
	Mage = { 1.10, 1.25, function(l) return sheetAt("Mage", l).AreaMult end },
	Rogue = { 1.15, 1.25, function(l) return sheetAt("Rogue", l).Speed / Config.Player.BaseSpeed end },
	Priest = { 1.20, 1.35, function(l) return sheetAt("Priest", l).MaxHP / Config.Player.BaseMaxHP end },
	Alchemist = { 1.20, 1.35, function(l)
		local r = fakeRp("Alchemist", l)
		local base = WS.WeaponStats(fakeRp("Knight", 0), { Id = "FireTrail", Level = 1 }).damage
		return WS.WeaponStats(r, { Id = "FireTrail", Level = 1 }).damage / base
	end },
	Engineer = { 1.30, 1.55, function(l)
		local base = WS.WeaponStats(fakeRp("Knight", 0), { Id = "Turret", Level = 1 }).duration
		return WS.WeaponStats(fakeRp("Engineer", l), { Id = "Turret", Level = 1 }).duration / base
	end },
	Necromancer = { 0.15, 0.25, function(l) return WS._TraitValue(fakeRp("Necromancer", l), 0) end },
	Ranger = { 0.30, 0.55, function(l)
		local r = fakeRp("Ranger", l)
		r.Root = { Position = Vector3.new(0, 3, 0) }
		WS._UpdateSteadyAim(r, 0.1)
		WS._UpdateSteadyAim(r, 2)
		assert(r.SteadyAim and r.SteadyAimOther, "Ranger must reach Steady Aim")
		local other = CharacterData.Characters.Ranger.SteadyAim.OtherDamage
		assert(math.abs(r.SteadyAimOther - other * r.SteadyAimBonus / 0.30) < 1e-6, "other weapons must scale with the Longbow bonus")
		return r.SteadyAimBonus
	end },
}
for _, hero in ipairs(CharacterData.Order) do
	local e = assert(expect[hero], "no signature check for " .. hero)
	local last = nil
	for l = 0, 5 do
		local v = e[3](l)
		if l == 0 then
			assert(math.abs(v - e[1]) < 1e-3, string.format("%s signature level 0 must equal today's trait %.3f (got %.3f)", hero, e[1], v))
		end
		if l == 5 then
			assert(math.abs(v - e[2]) < 2e-2, string.format("%s signature level 5 must reach %.3f (got %.3f)", hero, e[2], v))
		end
		if last then
			assert(math.abs(v - last) > 1e-4, string.format("%s signature level %d changes nothing", hero, l))
		end
		last = v
	end
end
preview.log("PASS every signature level changes its stat in-run")
preview.log("PASS: hero mastery")
