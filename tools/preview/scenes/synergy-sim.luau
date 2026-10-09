-- synergy-sim: boots the REAL server and builds every synergy (SynergyData) on a solo run
-- through the real systems (LevelUpSystem.AddWeapon, passives, ItemSystem.Grant), printing
-- after each piece: the "Synergies" attribute and the stats the synergy touches (the
-- change when it completes must equal its Bonus). Ember Field is left one piece short
-- (Candle); real upgrade cards must keep recipes hidden, and completing the build reveals
-- its active bonus.
-- run: render.sh synergy-sim --studio --devices pc,phone --max-time 200
local C = lib("common")
local Players = game:GetService("Players")
-- [stream B] synergies belong to the old 12-level system (the continuation pack's rank system hides
-- them: SynergyData.Hidden): this scene runs with RunConfig.Builds.Enabled off
require(game:GetService("ReplicatedStorage").SwarmV2.Run.RunConfig).Builds.Enabled = false
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
		preview.remote("LevelUpChoose"):FireServer(1, game:GetService("Players").LocalPlayer:GetAttribute("ChoiceOfferId"))
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

-- Clues are discovery-gated on real offers: upgrade cards carry no synergy clue, a NEW
-- card advancing the never-completed Ember Field says "???" and never names it; every
-- card has a one-line Summary. The completed build still announces its bonus.
local DS = preview.server("DiscoveryService")
rp.NextUpgradeCombatTime = 0
LU.QueueLevels(rp, 1)
assert(rp.Offer, "expected a real offer")
for _, choice in ipairs(rp.Offer) do
    assert(type(choice.Summary) == "string" and choice.Summary ~= "", "card without a Summary: " .. tostring(choice.Name))
    preview.log(string.format("  card %s [%s] summary=%q hint=%q synergy=%q", tostring(choice.Name), tostring(choice.Type), choice.Summary, tostring(choice.Hint), tostring(choice.Synergy)))
    if choice.Type ~= "WeaponNew" and choice.Type ~= "PassiveNew" then
        assert(choice.Synergy == nil and choice.SynergyReady == nil, "upgrade card exposed a hidden recipe")
    elseif choice.Synergy then
        assert(string.find(choice.Synergy, "???", 1, true) and not string.find(choice.Synergy, "Ember", 1, true), "undiscovered synergy named on a card: " .. choice.Synergy)
    end
end
LU.Cancel(rp)
assert(not DS.Known(me, "Synergies", "EmberField"), "Ember Field discovered before completion")
local clues = LU.SynergyClues(rp)
local ember = nil
for _, clue in ipairs(clues) do
    preview.log(string.format("  clue %s %d/%d active=%s id=%s", clue.Name, clue.Have, clue.Need, tostring(clue.Active), tostring(clue.Id)))
    if not clue.Active then ember = clue end
end
assert(ember and ember.Name == "???" and ember.Id == nil, "incomplete, undiscovered synergy was named in the ITEMS clues")
for _, piece in ipairs(ember.Pieces) do
    if not piece.Owned then
        assert(piece.Label == "???", "undiscovered missing piece was named: " .. tostring(piece.Label))
    end
end
assert(not table.find(SynergyData.Active(owned()), "EmberField"), "recipe completed before Candle")
addPassive("Candle")
assert(table.find(SynergyData.Active(owned()), "EmberField"), "discovered synergy did not activate")
assert(string.find(me:GetAttribute("Synergies"), "EmberField", 1, true), "discovered synergy was not published")
assert(DS.Known(me, "Synergies", "EmberField"), "completed synergy was not recorded as discovered")
assert(DS.Known(me, "Weapons", "FireTrail") and DS.Known(me, "Items", "KeenLens"), "owned weapon / item not recorded as discovered")
local data = preview.server("DataService").GetData(me)
assert(data and data.Discovered and data.Discovered.Synergies.EmberField == true, "discovery missing from the save")
preview.log("PASS discovery: clues gated, Ember Field revealed after completion")
advance(1.6)
preview.log("PASS: hidden recipes and discovered active synergies")
