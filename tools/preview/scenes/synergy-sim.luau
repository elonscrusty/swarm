-- synergy-sim: boots the REAL server and builds every synergy (SynergyData) on a solo run
-- through the real systems (LevelUpSystem.AddWeapon, passives, ItemSystem.Grant), printing
-- after each piece: the "Synergies" attribute and the stats the synergy touches (the
-- change when it completes must equal its Bonus). Ember Field is left one piece short
-- (Candle); then a real level-up offer is rerolled until a card names the synergy it
-- completes, and the scene ends on that offer (HUD synergy chip + card hint render).
-- run: render.sh synergy-sim --studio --devices pc,phone --max-time 200
local C = lib("common")
local Players = game:GetService("Players")
preview.forceMeshesUploaded()
preview.startServer()
preview.advance(1)
C.startClient()
preview.advance(1)
local me = Players.LocalPlayer
local RM = preview.server("RunManager")
local LU = preview.server("LevelUpSystem")
local WS = preview.server("WeaponSystem")
local IS = preview.server("ItemSystem")
local SynergyData = C.shared("SynergyData")
local advance = preview.advance

local function levelUps()
	for _ = 1, 30 do
		if not me:GetAttribute("Paused") then
			return
		end
		preview.remote("LevelUpChoose"):FireServer(1)
		advance(0.3)
	end
end

preview.remote("StartRun"):FireServer("Solo")
advance(2)
levelUps()
local rp = RM.GetRunPlayer(me)
if not rp then
	preview.log("FAIL: no run player")
	return
end
rp.InvulnUntil = math.huge
preview.log("start weapons:", table.concat(rp.WeaponOrder, ","), "passives:", table.concat(rp.PassiveOrder, ","))

local KEYS = { "Might", "AreaMult", "DurationMult", "CritChance", "CritDamage", "Armor", "MaxHP" }
local function stats(): string
	local parts = {}
	for _, k in ipairs(KEYS) do
		table.insert(parts, string.format("%s=%.3f", k, rp.Stats[k]))
	end
	return table.concat(parts, " ")
end

local function refresh()
	LU.RecomputeStats(rp)
	WS.OnInventoryChanged(rp)
	LU.SendInventory(rp)
end

local function addWeapon(id)
	if not rp.Weapons[id] then
		preview.log("  + weapon", id, tostring(LU.AddWeapon(rp, id)))
		refresh()
	end
end
local function addPassive(id)
	if not rp.Passives[id] then
		rp.Passives[id] = 1
		table.insert(rp.PassiveOrder, id)
		preview.log("  + passive", id)
		refresh()
	end
end
local function addItem(id)
	preview.log("  + item", id, tostring(IS.Grant(rp, id, "synergy-sim", false)))
end

local function owned()
	return { Weapons = rp.Weapons, Passives = rp.Passives, Items = rp.Items }
end

local function build(id: string, steps: { () -> () })
	local s = SynergyData.Synergies[id]
	preview.log(string.format("== %s (%s)", s.Name, s.Text))
	local before = nil
	for i, step in ipairs(steps) do
		local snap = table.clone(rp.Stats)
		step()
		advance(0.2)
		local have, need = SynergyData.Progress(id, owned())
		preview.log(string.format("  %d/%d attr=%q %s", have, need, tostring(me:GetAttribute("Synergies")), stats()))
		if have >= need and not before then
			before = snap
			for k, v in pairs(s.Bonus) do
				local key = ({ might = "Might", area = "AreaMult", duration = "DurationMult", critChance = "CritChance", critDamage = "CritDamage", armor = "Armor", maxHpMult = "MaxHP" })[k]
				preview.log(string.format("  completed: %s %.3f -> %.3f (bonus %s %.2f)", key, snap[key], rp.Stats[key], k, v))
			end
		end
		local _ = i
	end
end

build("Trinity", {
	function() addWeapon("FireTrail") end,
	function() addWeapon("FrostNova") end,
	function() addWeapon("Lightning") end,
})
build("Deadeye", {
	function() addWeapon("Longbow") end,
	function() addPassive("Precision") end,
	function() addItem("KeenLens") end,
})
build("Bulwark", {
	function()
		if not (rp.Weapons.Whip or rp.Weapons.Garlic or rp.Weapons.Spear) then
			addWeapon("Garlic")
		end
	end,
	function() addPassive("Armor") end,
	function() addItem("IronPlate") end,
})
-- Ember Field: the fire weapon is owned (Fire Trail); add Area, leave Candle to a card
build("EmberField", { function() addPassive("Area") end })
local adv, have, need = SynergyData.Advances(owned(), "Passive", "Candle")
preview.log(string.format("Advances(Candle) -> %s %d/%d", adv and adv.Name or "nil", have, need))
local adv2, h2, n2 = SynergyData.Advances(owned(), "Passive", "Luck")
preview.log(string.format("Advances(Luck) -> %s %d/%d (want nil)", adv2 and adv2.Name or "nil", h2, n2))
preview.log("active:", tostring(me:GetAttribute("Synergies")))

-- a real offer with the Candle card
rp.Rerolls = 60
LU.QueueLevels(rp, 1)
advance(0.5)
local found = nil
for r = 1, 60 do
	for _, card in ipairs(rp.Offer or {}) do
		if card.Synergy then
			found = card
			preview.log(string.format("offer after %d rerolls: %s %s -> %q ready=%s lines=%d", r - 1, card.Type, card.Id, card.Synergy, tostring(card.SynergyReady), #(card.Lines or {})))
			for _, l in ipairs(card.Lines or {}) do
				preview.log(string.format("    %s %s -> %s", tostring(l.Label), tostring(l.From), tostring(l.To)))
			end
		end
	end
	if found then
		break
	end
	preview.remote("LevelUpReroll"):FireServer()
	advance(0.4)
end
if not found then
	preview.log("FAIL: no synergy card in 60 rerolls")
end
advance(1.6)
preview.log("done")
