-- evolution-preview-regression: batch B item B5 (Config.Features.EvolutionPreview,
-- docs/next/EVOLUTION_PREVIEW.md). Boots the REAL server, starts a Solo run and checks the
-- level-up cards LevelUpSystem decorates (LevelUpSystem.DescribeCard = the same decorate an
-- offer uses): a weapon card names its evolution, the evolved icon and the recipe with live
-- progress; the partner passive's card says "Needed for <evolution>"; progress changes after
-- real picks (LevelUpChoose with the OfferId); the BUILD panel's list
-- (EvolutionPreview.List, fed the Inventory shape) names what is missing; switched off,
-- the cards fall back to the old hint. Prints PASS / FAIL lines.
-- run: lune run tools/preview/runtime/main.luau -- --scene evolution-preview-regression
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
local EP = preview.shared("EvolutionPreview")
local advance = preview.advance

local fails = 0
local function check(ok: any, label: string)
	if not ok then
		fails += 1
	end
	preview.log((ok and "PASS " or "FAIL ") .. label)
end
local function has(s: any, part: string): boolean
	return type(s) == "string" and string.find(s, part, 1, true) ~= nil
end

check(Config.Features.EvolutionPreview == true, "EvolutionPreview switch on by default")

-- 1) data: every released weapon with an evolution maps to its own evolution
local dataOk, checked = true, 0
for _, id in ipairs(WeaponData.Order) do
	local evo = WeaponData.Weapons[id].Evolution
	if evo then
		checked += 1
		local s = EP.Status(id, 1, 0)
		local line = s and EP.WeaponLine(s) or ""
		if not s or s.EvoId ~= evo.Id or s.Name ~= evo.Name or s.PassiveId ~= evo.Passive
			or not has(line, evo.Name) or not has(line, WeaponData.Weapons[id].Name) or not has(line, PassiveData.Passives[evo.Passive].Name) then
			dataOk = false
			preview.log("  wrong evolution data for " .. id .. ": " .. line)
		end
	end
end
check(dataOk and checked > 0, string.format("the right evolution for all %d released weapons with one", checked))

-- a Solo run
preview.fireServerAs(me, "StartRun", "Solo")
advance(2)
local rp = assert(RM.GetRunPlayer(me), "run player missing")
rp.InvulnUntil = math.huge
-- levels the arena hands out on its own are dropped, never picked at random (a random
-- pick could change the build under test)
local function clearOffers()
	LUS.Cancel(rp)
end
clearOffers()

-- the weapon under test: the first owned weapon with an evolution (else the Sword)
local wid: string? = nil
for _, id in ipairs(rp.WeaponOrder) do
	if WeaponData.Weapons[id].Evolution and not rp.Weapons[id].Evolved then
		wid = id
		break
	end
end
if not wid then
	LUS.AddWeapon(rp, "Whip")
	wid = "Whip"
end
local weaponId = wid :: string
local evo = WeaponData.Weapons[weaponId].Evolution
local pid = evo.Passive
local pname = PassiveData.Passives[pid].Name
local need = EP.PassiveNeed(pid)
rp.Passives[pid] = nil
local at = table.find(rp.PassiveOrder, pid)
if at then
	table.remove(rp.PassiveOrder, at)
end
rp.Weapons[weaponId].Level = 9

-- 2) the weapon card: icon, name, recipe and live progress
local card = LUS.DescribeCard(rp, "WeaponUp", weaponId, 10)
local recipe = string.format("%s: %s Lv %d + %s Lv %d", evo.Name, WeaponData.Weapons[weaponId].Name, WeaponData.MaxLevel, pname, need)
check(card.EvoIcon == evo.Id and card.EvoName == evo.Name, "weapon card carries the evolved icon and name (" .. tostring(card.EvoIcon) .. ")")
check(has(card.Hint, recipe) and has(card.Hint, "you: no " .. pname), "weapon card line: " .. tostring(card.Hint))
check(card.HintReady == false, "not ready without the passive")
local fresh = nil
for _, id in ipairs(WeaponData.Order) do
	if not rp.Weapons[id] and WeaponData.Weapons[id].Evolution then
		fresh = id
		break
	end
end
if fresh then
	local newCard = LUS.DescribeCard(rp, "WeaponNew", fresh, 1)
	check(newCard.EvoIcon == WeaponData.Weapons[fresh].Evolution.Id and has(newCard.Hint, WeaponData.Weapons[fresh].Evolution.Name), "a NEW weapon card shows its evolution too: " .. tostring(newCard.Hint))
end

-- 3) the ingredient passive card
local pcard = LUS.DescribeCard(rp, "PassiveNew", pid, 1)
check(pcard.Hint == string.format("Needed for %s (%s Lv %d)", evo.Name, pname, need) and pcard.EvoIcon == evo.Id, "ingredient passive card: " .. tostring(pcard.Hint))

-- 4) progress after real picks (the server applies the forced card through LevelUpChoose)
local function forcePick(kind: string, id: string, level: number): boolean
	LUS.QueueLevels(rp, 1)
	advance(0.1)
	if not rp.Offer then
		return false
	end
	rp.Offer[1] = LUS.DescribeCard(rp, kind, id, level)
	preview.fireServerAs(me, "LevelUpChoose", 1, rp.OfferSeq)
	advance(0.4)
	clearOffers()
	return true
end
check(forcePick("PassiveNew", pid, 1) and rp.Passives[pid] == 1, pname .. " picked (level 1)")
card = LUS.DescribeCard(rp, "WeaponUp", weaponId, 10)
check(has(card.Hint, string.format("you: %s 1", pname)), "progress updates after the pick: " .. tostring(card.Hint))
for lv = 2, need do
	forcePick("PassiveUp", pid, lv)
end
check(rp.Passives[pid] == need, string.format("%s raised to Lv %d", pname, need))
card = LUS.DescribeCard(rp, "WeaponUp", weaponId, 10)
check(has(card.Hint, pname .. " done") and card.HintReady == false, "passive done, weapon still short: " .. tostring(card.Hint))
rp.Weapons[weaponId].Level = WeaponData.MaxLevel - 1
card = LUS.DescribeCard(rp, "WeaponUp", weaponId, WeaponData.MaxLevel)
check(has(card.Hint, "ready!") and card.HintReady == true, "the final weapon level reads ready: " .. tostring(card.Hint))

-- 5) the BUILD panel list (fed the Inventory payload's shape, as Hud does)
local function inventory()
	local weapons, passives = {}, {}
	for _, id in ipairs(rp.WeaponOrder) do
		table.insert(weapons, { Id = id, Level = rp.Weapons[id].Level, Evolved = rp.Weapons[id].Evolved })
	end
	for _, id in ipairs(rp.PassiveOrder) do
		table.insert(passives, { Id = id, Level = rp.Passives[id] })
	end
	return weapons, passives
end
local function row(list, id: string)
	for _, s in ipairs(list) do
		if s.WeaponId == id then
			return s
		end
	end
	return nil
end
local list = EP.List(inventory())
local r = row(list, weaponId)
check(r ~= nil and r.Owned == true and not r.Ready and has(r.Missing, string.format("Lv %d → %d", WeaponData.MaxLevel - 1, WeaponData.MaxLevel)), "panel lists the weapon level still missing: " .. tostring(r and r.Missing))
-- a passive whose weapon is not owned yet: listed with the weapon missing
local other: string? = nil
for _, id in ipairs(WeaponData.Order) do
	local e = WeaponData.Weapons[id].Evolution
	if e and not rp.Weapons[id] and not rp.Passives[e.Passive] and e.Passive ~= pid then
		other = id
		break
	end
end
if other and #rp.PassiveOrder < Config.Slots.Passives then
	local opid = WeaponData.Weapons[other].Evolution.Passive
	forcePick("PassiveNew", opid, 1)
	list = EP.List(inventory())
	local orow = row(list, other)
	check(orow ~= nil and orow.Owned == false and has(orow.Missing, WeaponData.Weapons[other].Name .. " (not owned)"), "panel lists an evolution whose weapon is missing: " .. tostring(orow and orow.Missing))
end
rp.Weapons[weaponId].Level = WeaponData.MaxLevel
list = EP.List(inventory())
r = row(list, weaponId)
check(r ~= nil and r.Ready and r.Missing == "" and list[1] == r, "a ready evolution comes first with nothing missing")

-- 6) switched off: the old hint, no evolution fields
Config.Features.EvolutionPreview = false
rp.Weapons[weaponId].Level = 9
card = LUS.DescribeCard(rp, "WeaponUp", weaponId, 10)
check(card.EvoIcon == nil and has(card.Hint, "Evolves at Lv"), "switched off: the old evolution hint (" .. tostring(card.Hint) .. ")")
Config.Features.EvolutionPreview = true

preview.log(fails == 0 and "PASS evolution preview: right evolution, live progress after picks, panel lists missing parts" or ("FAIL evolution preview: " .. fails .. " check(s) failed"))
