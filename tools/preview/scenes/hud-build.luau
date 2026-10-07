-- hud-build: the approved 02/03 HUD under load: stage 2 at wave 6 after the portal reveal (the
-- objective panel, the edge marker with the distance, the minimap), a FULL build (6 weapons,
-- 6 passives, high ranks, one evolved) and a run with several stacked items, with the BUILD
-- details open over the arena. --set build=off shows the closed tray; --set early=on shows a
-- fresh run (one weapon, quiet empty slots, no items).
local A = lib("arena")
local C = lib("common")
local early = preview.args.early == "on"
A.build({ enemies = 90, seconds = 400, portal = true, portalState = "Idle", stage = 2, portalHint = true, portalReveal = 1 })
C.setState({ Wave = 6, WaveNext = 0 })
local WeaponData = C.shared("WeaponData")
local PassiveData = C.shared("PassiveData")
local weapons, passives = {}, {}
local wIds = early and { "Whip" } or { "Whip", "Garlic", "Knives", "Sawblade", "MagicOrb", "SoulBolt" }
for i, id in ipairs(wIds) do
	local def = WeaponData.Weapons[id]
	if def then
		local evolved = (not early) and i == 1 and def.Evolution ~= nil
		table.insert(weapons, { Id = id, Name = def.Name, Level = early and 1 or (evolved and WeaponData.MaxLevel or (9 - i)), Evolved = evolved, Color = def.Color })
	end
end
if not early then
	for i, id in ipairs({ "Might", "Armor", "Heart", "SpeedBoots", "Cooldown", "Area" }) do
		local def = PassiveData.Passives[id]
		if def then
			table.insert(passives, { Id = id, Name = def.Name, Level = math.min(#def.Values, 1 + (i % 4)), Color = def.Color })
		end
	end
end
C.fire("Inventory", { Weapons = weapons, Passives = passives, Rerolls = 1, Skips = 1, WeaponSlots = 6, PassiveSlots = 6 })
if not early then
	C.fire("Items", {
		{ Id = "StormCharm", Count = 2 },
		{ Id = "Bandage", Count = 3 },
		{ Id = "SunMedallion", Count = 1 },
		{ Id = "MagnetTotem", Count = 1 },
		{ Id = "VolatileSpore", Count = 4 },
	})
end
C.settle(2.5)
if preview.args.build ~= "off" and not early then
	-- opened a moment after the portal reveal headline (a headline already on screen would
	-- finish under the panel; new routine ones wait while it is open: UIState hold "Build")
	C.settle(3)
	local Hud = preview.client("Hud")
	Hud.SetBuildOpen(true)
	C.settle(0.6)
end
-- --set ult=0.4 shows the ultimate button charging (40%), --set ult=ready ready (gold, pulse,
-- the first-ready callout); --set ulthero=Mage another hero's move
local ult = preview.args.ult
if ult then
	local charge = ult == "ready" and 1 or (tonumber(ult) or 0)
	C.setPlayer({ UltHero = preview.args.ulthero or "Knight", UltCharge = charge })
	C.settle(1)
end
