-- evolution-panel-regression: batch B item B5 (Config.Features.EvolutionPreview,
-- docs/next/EVOLUTION_PREVIEW.md), the client side. The HUD's BUILD details (Hud
-- refreshDetails) get an EVOLUTIONS section: every evolution the build can reach, its recipe
-- and what is still missing. Fires the Inventory remote the way LevelUpSystem.SendInventory
-- does, opens BUILD and reads the labels; a second Inventory (after a pick) must update the
-- missing parts. Prints PASS / FAIL lines. Registered as a layout check on iphone,
-- phone-portrait and pc (the final frame shows the open panel for check_layout).
local A = lib("arena")
local C = lib("common")
local Players = game:GetService("Players")
A.build({ enemies = 30, seconds = 200, stage = 1 })
local WeaponData = C.shared("WeaponData")
local PassiveData = C.shared("PassiveData")
local Config = C.shared("Config")
local Hud = preview.client("Hud")
local fails = 0
local function check(ok: any, label: string)
	if not ok then
		fails += 1
	end
	preview.log((ok and "PASS " or "FAIL ") .. label)
end
check(Config.Features.EvolutionPreview == true, "EvolutionPreview switch on by default")

local function inventory(heart: number)
	local weapons, passives = {}, {}
	for _, w in ipairs({ { "Whip", 9 }, { "MagicOrb", 4 }, { "Garlic", 6 } }) do
		local def = WeaponData.Weapons[w[1]]
		table.insert(weapons, { Id = w[1], Name = def.Name, Level = w[2], MaxLevel = WeaponData.MaxLevel, Evolved = false, Color = def.Color })
	end
	for _, p in ipairs({ { "Heart", heart }, { "Might", 2 } }) do
		local def = PassiveData.Passives[p[1]]
		table.insert(passives, { Id = p[1], Name = def.Name, Level = p[2], MaxLevel = PassiveData.MaxLevelOf(p[1]), Color = def.Color })
	end
	C.fire("Inventory", { Weapons = weapons, Passives = passives, Rerolls = 1, Skips = 1, WeaponSlots = 6, PassiveSlots = 6 })
end
local function texts(): { string }
	local out = {}
	local gui = Players.LocalPlayer.PlayerGui
	local panel = gui:FindFirstChild("BuildDetails", true)
	for _, d in ipairs(panel and panel:GetDescendants() or {}) do
		if d:IsA("TextLabel") and d.Text ~= "" then
			table.insert(out, d.Text)
		end
	end
	return out
end
local function find(part: string): boolean
	for _, t in ipairs(texts()) do
		if string.find(t, part, 1, true) then
			return true
		end
	end
	return false
end

local sword = WeaponData.Weapons.Whip
local heart = PassiveData.Passives[sword.Evolution.Passive]
inventory(1)
C.settle(2)
Hud.SetBuildOpen(true)
C.settle(0.6)
check(find("EVOLUTIONS"), "the BUILD panel has an EVOLUTIONS section")
check(find(string.format("%s Lv %d + %s Lv 3", sword.Name, WeaponData.MaxLevel, heart.Name)), "the recipe row for " .. sword.Evolution.Name)
check(find(sword.Evolution.Name), "the evolution is named (" .. sword.Evolution.Name .. ")")
check(find(string.format("Missing: %s Lv 9 → %d, %s Lv 1 → 3", sword.Name, WeaponData.MaxLevel, heart.Name)), "the panel lists both missing parts")
-- a pick raises the passive: the next Inventory updates the missing parts
inventory(3)
C.settle(0.5)
check(find(string.format("Missing: %s Lv 9 → %d", sword.Name, WeaponData.MaxLevel)) and not find(string.format("%s Lv 1 → 3", heart.Name)), "after the pick only the weapon level is missing")
C.settle(0.6)
preview.log(fails == 0 and "PASS evolution panel: section, recipe, missing parts, update after a pick" or ("FAIL evolution panel: " .. fails .. " check(s) failed"))
