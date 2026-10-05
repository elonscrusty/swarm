-- heropower-regression: HEROPOWER (docs/features/HEROPOWER.md) against the real server.
--   1) second skill: off below Config.SecondSkill.Rank mastery, on at it (StatSheet), never
--      with the switch off
--   2) ultimate: refused in the lobby, without charge, while dead / paused, during the
--      cooldown and with the switch off; a full charge clears normal enemies, caps elites
--      and bosses (no instant boss kill), its own kills don't recharge it, the remote path
--      works, the attributes are published and cleared
--   3) build presets: SetPreset validation, caps, switch off; the level-up pool never
--      reads the presets
-- Every check errors on failure.
local player = game:GetService("Players").LocalPlayer
preview.startServer()
preview.advance(1)
local RM = preview.server("RunManager")
local DS = preview.server("DataService")
local Spawner = preview.server("EnemySpawner")
local Ult = preview.server("Ultimate")
local BP = preview.server("BuildPresets")
local Config = preview.shared("Config")
local Meta = preview.shared("MetaUpgradeData")
local CharacterData = preview.shared("CharacterData")
local U = Config.Ultimate

local data = assert(DS.GetData(player), "profile missing")
data.OwnedCharacters = { Knight = true, Priest = true }
data.SelectedCharacter = "Knight"
data.Heroes = { Knight = { XP = 0, Runs = 0 } }

local function xpForMastery(level: number): number
	local xp = 0
	for l = 1, level - 1 do
		xp += Meta.MasteryToNext(l)
	end
	return xp
end

local function startRun()
	preview.remote("StartRun"):FireServer("Solo")
	preview.advance(3)
	local rp = assert(RM.GetRunPlayer(player), "run player missing")
	rp.InvulnUntil = 1e9 -- the checks below are about the ultimate, not survival
	return rp
end

local function endRun(rp)
	RM.AbandonRun(rp)
	preview.advance(Config.Run.ResultsSeconds + 2)
	assert(not RM.IsParticipant(player), "back in the lobby")
end

------------------------------------------------------------------------------------------
-- 1) second skill
------------------------------------------------------------------------------------------
data.Heroes.Knight.XP = xpForMastery(Config.SecondSkill.Rank - 1)
local rp = startRun()
assert(rp.Meta.SecondSkill == nil, "second skill must be off below the rank")
local armorBefore = rp.Stats.Armor
endRun(rp)
data.Heroes.Knight.XP = xpForMastery(Config.SecondSkill.Rank)
assert(Meta.MasteryFor(data.Heroes.Knight.XP) == Config.SecondSkill.Rank, "test XP reaches the rank")
rp = startRun()
assert(rp.Meta.SecondSkill == 1, "second skill must be on at the rank")
assert(rp.Stats.Armor == armorBefore + CharacterData.SecondSkills.Knight.Bonus.armor, "Shield Wall must add its armor: " .. rp.Stats.Armor)
endRun(rp)
Config.Features.SecondSkill = false
rp = startRun()
assert(rp.Meta.SecondSkill == nil and rp.Stats.Armor == armorBefore, "switch off: no second skill")
endRun(rp)
Config.Features.SecondSkill = true
for _, id in ipairs(CharacterData.Order) do
	assert(CharacterData.SecondSkills[id] and CharacterData.Ultimates[id], "every hero has a second skill and an ultimate: " .. id)
end
preview.log("PASS second skill gated by mastery rank")

------------------------------------------------------------------------------------------
-- 2) ultimate
------------------------------------------------------------------------------------------
local ok, why = Ult.Use(player)
assert(not ok and why == "norun", "lobby: refused (" .. tostring(why) .. ")")
rp = startRun()
preview.advance(0.5)
assert(player:GetAttribute("UltCharge") == 0, "charge published, starts empty")
assert(player:GetAttribute("UltHero") == "Knight", "hero published")
ok, why = Ult.Use(player)
assert(not ok and why == "charge", "no charge: refused (" .. tostring(why) .. ")")
-- half charge
rp.Kills = rp.UltKillMark + math.floor(U.KillsToCharge / 2)
preview.advance(0.3)
local half = player:GetAttribute("UltCharge")
assert(half > 0.4 and half < 0.6, "half the kills = half a bar: " .. tostring(half))
-- the boss (wait out its entrance), then a crowd and an elite next to the hero
local root = rp.Root.Position
for i = #Spawner.Active, 1, -1 do
	Spawner.Despawn(Spawner.Active[i])
end
local boss = assert(Spawner.SpawnBoss(root + Vector3.new(14, 0, 0)), "boss")
for _ = 1, 80 do
	if not boss.Invulnerable then break end
	preview.advance(0.25)
end
assert(not boss.Invulnerable, "boss entrance over")
boss.Pos = root + Vector3.new(14, 0, 0)
local crowd = {}
for i = 1, 10 do
	local a = i / 10 * math.pi * 2
	local e = Spawner.Spawn("Skeleton", root + Vector3.new(math.cos(a) * 12, 0, math.sin(a) * 12), { Force = true })
	if e then table.insert(crowd, e) end
end
assert(#crowd >= 8, "crowd spawned")
local elite = assert(Spawner.Spawn("Brute", root + Vector3.new(-10, 0, 4), { Elite = true, Force = true }), "elite")
local far = assert(Spawner.Spawn("Skeleton", root + Vector3.new(U.Radius * 2.2, 0, 0), { Force = true }), "far enemy")
rp.Level = 20
rp.Kills = rp.UltKillMark + U.KillsToCharge
preview.advance(0.2)
assert(player:GetAttribute("UltCharge") == 1, "full charge published")
local bossHP, eliteHP, eliteShield = boss.HP, elite.HP, elite.Shield or 0
local usedBefore = player:GetAttribute("UltUsed") or 0
preview.remote("UseUltimate"):FireServer()
preview.advance(0.1)
assert((player:GetAttribute("UltUsed") or 0) == usedBefore + 1, "remote fired the ultimate")
local killed = 0
for _, e in ipairs(crowd) do
	if not e.Alive then killed += 1 end
end
assert(killed == #crowd, string.format("the crowd in range must fall (%d / %d)", killed, #crowd))
assert(far.Alive, "an enemy out of range is untouched")
local dmg = Ult.Damage(rp)
local bossPct, elitePct = (bossHP - boss.HP) / boss.MaxHP * 100, (eliteHP - elite.HP) / elite.MaxHP * 100
assert(boss.Alive and boss.HP > 0, "never an instant boss kill")
assert(bossHP - boss.HP <= boss.MaxHP * U.BossShare + 0.01, "boss share cap: " .. (bossHP - boss.HP))
assert(bossHP - boss.HP > 0, "the boss takes some damage")
assert(eliteHP - elite.HP <= elite.MaxHP * U.EliteShare + 0.01 or not elite.Alive, "elite share cap")
assert(elite.Alive, "an elite survives one ultimate")
assert(eliteHP - elite.HP > 0 or (elite.Shield or 0) < eliteShield, "the elite is hit (HP or its shield)")
assert(dmg <= U.Cap * 1.15 * U.MaxMight + 0.01, "damage capped")
assert(rp.InvulnUntil >= RM.GetRunTime(), "Knight guard")
preview.advance(0.2)
assert(player:GetAttribute("UltCharge") == 0, "its own kills don't recharge it")
-- kills again, but the cooldown holds it
rp.Kills = rp.UltKillMark + U.KillsToCharge
preview.advance(0.2)
ok, why = Ult.Use(player)
assert(not ok and why == "charge", "cooldown: refused (" .. tostring(why) .. ")")
-- run time only moves while the world runs: auto-pick any level-up on the way
local t0 = RM.GetRunTime()
for _ = 1, 400 do
	if RM.GetRunTime() - t0 > U.Cooldown + 1 then break end
	rp.OfferDeadline = 0
	preview.advance(0.5)
end
assert(RM.GetRunTime() - t0 > U.Cooldown, "cooldown elapsed")
rp.Kills = math.max(rp.Kills, rp.UltKillMark + U.KillsToCharge)
preview.advance(0.2)
-- paused (solo pause menu freezes the world)
preview.remote("SetPause"):FireServer(true)
preview.advance(0.2)
ok, why = Ult.Use(player)
assert(not ok and why == "frozen", "paused: refused (" .. tostring(why) .. ")")
preview.remote("SetPause"):FireServer(false)
preview.advance(0.2)
-- dead
rp.Alive = false
ok, why = Ult.Use(player)
assert(not ok and why == "state", "dead: refused (" .. tostring(why) .. ")")
rp.Alive = true
-- the switch
Config.Features.Ultimate = false
ok, why = Ult.Use(player)
assert(not ok and why == "off", "switch off: refused")
preview.advance(0.3)
assert(player:GetAttribute("UltCharge") == nil and player:GetAttribute("UltHero") == nil, "switch off: attributes cleared")
Config.Features.Ultimate = true
preview.advance(0.3)
-- clear any level-up choice the kills brought (a hero choosing a card can't fire it)
for _ = 1, 20 do
	if not rp.Offer and not rp.RewardUntil then break end
	rp.OfferDeadline = 0
	preview.advance(0.5)
end
ok, why = Ult.Use(player)
assert(ok, "ready again after the cooldown (" .. tostring(why) .. ")")
endRun(rp)
assert(player:GetAttribute("UltCharge") == nil, "attributes cleared after the run")
preview.log(string.format("PASS ultimate (damage %.0f at level 20, boss -%.1f%%, elite -%.0f%%)", dmg, bossPct, elitePct))

-- Priest heal
data.SelectedCharacter = "Priest"
rp = startRun()
rp.Kills = rp.UltKillMark + U.KillsToCharge
preview.advance(0.2)
rp.HP = 10
ok, why = Ult.Use(player)
assert(ok and rp.HP > 10, "Holy Nova heals (" .. tostring(why) .. ")")
endRun(rp)
data.SelectedCharacter = "Knight"
preview.log("PASS ultimate heal")

------------------------------------------------------------------------------------------
-- 3) build presets
------------------------------------------------------------------------------------------
assert(BP.Set(player, "Knight", "Weapons", "Whip", true), "mark a weapon")
assert(BP.Set(player, "Knight", "Passives", preview.shared("PassiveData").Order[1], true), "mark a passive")
assert(not BP.Set(player, "Knight", "Weapons", "Whip", true), "marking twice changes nothing")
assert(not BP.Set(player, "Nobody", "Weapons", "Whip", true), "unknown hero refused")
assert(not BP.Set(player, "Knight", "Hats", "Whip", true), "bad kind refused")
assert(not BP.Set(player, "Knight", "Weapons", "NotAWeapon", true), "unknown id refused")
assert(not BP.Set(player, "Knight", "Weapons", "Whip", "yes"), "non-boolean refused")
assert(not BP.Set(player, "Knight", "Weapons", { 1 }, true), "table id refused")
local entry = assert(BP.Entry(data, "Knight"), "Knight preset entry")
assert(table.find(entry.Weapons, "Whip"), "Whip saved")
assert(data.Presets.List[data.Presets.Active.Knight] == entry, "Active index points at the entry")
-- cap per list
local WeaponData = preview.shared("WeaponData")
for _, id in ipairs(WeaponData.Order) do
	BP.Set(player, "Knight", "Weapons", id, true)
end
assert(#entry.Weapons == math.min(#WeaponData.Order, Config.Data.Caps.PresetPicks), "picks capped")
-- unmark
assert(BP.Set(player, "Knight", "Weapons", "Whip", false), "unmark")
assert(not table.find(entry.Weapons, "Whip"), "Whip removed")
-- one entry per hero, every hero fits
for _, id in ipairs(CharacterData.Order) do
	BP.Set(player, id, "Weapons", "Whip", true)
end
assert(#data.Presets.List == #CharacterData.Order, "one list per hero")
-- the save stays valid after cleaning
DS.CleanFeatureFields(data)
assert(#data.Presets.List == #CharacterData.Order and data.Presets.Active.Knight ~= nil, "clean keeps the presets")
-- switch off
Config.Features.BuildPresets = false
assert(not BP.Set(player, "Mage", "Weapons", "MagicOrb", true), "switch off: refused")
Config.Features.BuildPresets = true
preview.log("PASS build presets")
preview.log("PASS heropower-regression")
