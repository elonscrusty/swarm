-- run-hud: the continuation brief's run HUD (stream F) fed by the shared-contract attributes only.
--   --set stage=Survive|BeaconAvailable|Rally|Charge|Boss|Victory|Defeat|none   RunStage (none: attribute absent,
--                                                                              the previous stage objective shows)
--   --set clock=SECONDS          RunClock (default per stage; 930 shows OVERTIME)
--   --set team=1..4              party size (teammates: alive, downed, reviving, eliminated, in that order)
--   --set arena=Cliffwood|Forest the arena (default Cliffwood: the revealed minimap)
--   --set view=hud|inventory|bigmap|downed|spectate|cards|results|interact|menu   what is on top of the HUD
--   --set missing=on             every contract attribute absent (empty / hidden states)
-- Fake attributes for every RunStage, a downed hero, cards and results; the real client modules draw them.
local A = lib("arena")
local C = lib("common")
local stage = preview.args.stage or "Survive"
local team = tonumber(preview.args.team) or 3
local view = preview.args.view or "hud"
local missing = preview.args.missing == "on"
local arenaName = preview.args.arena or "Cliffwood"

local CLOCK = { Survive = 300, BeaconAvailable = 760, Rally = 790, Charge = 845, Boss = 900, Victory = 960, Defeat = 610 }
local clock = tonumber(preview.args.clock) or CLOCK[stage] or 300

local s = A.build({ arena = arenaName, enemies = tonumber(preview.args.enemies) or 40, seconds = clock })
local centre = s.centre
C.settle(0.3)

-- teammates (extra Players with real characters)
local function mate(name, userId, heroId, offset, attrs)
	local p = preview.addPlayer(name, userId)
	local model = C.try("BuildCharacter " .. heroId, s.ModelBuilder.BuildCharacter, heroId, "Default")
	if model then
		model.Name = name
		model:PivotTo(CFrame.new(centre + offset + Vector3.new(0, 3.5, 0)))
		model.Parent = workspace
		p.Character = model
	end
	p:SetAttribute("InRun", true)
	p:SetAttribute("CharacterId", heroId)
	for k, v in pairs(attrs) do
		p:SetAttribute(k, v)
	end
	return p
end
local roster = {
	{ "Ava", 2, "Mage", Vector3.new(14, 0, 6), { Alive = true, HP = 70, MaxHP = 110, Downed = false } },
	{ "Ben", 3, "Rogue", Vector3.new(-18, 0, 10), { Alive = false, HP = 0, MaxHP = 100, Downed = true, BleedLeft = 13, ReviveProgress = 0.4 } },
	{ "Cleo", 4, "Ranger", Vector3.new(30, 0, -22), { Alive = false, HP = 0, MaxHP = 100, Downed = false, Eliminated = true } },
}
for i = 1, math.min(team - 1, #roster) do
	local r = roster[i]
	mate(r[1], r[2], r[3], r[4], r[5])
end

-- inventory: rank-based entries (Rank 1..5), 4 + 4 slots, one evolved weapon
local WeaponData = C.shared("WeaponData")
local PassiveData = C.shared("PassiveData")
local weapons, passives = {}, {}
for i, id in ipairs({ "Whip", "Garlic", "Knives", "MagicOrb" }) do
	local def = WeaponData.Weapons[id]
	if def and i <= (preview.args.weapons and tonumber(preview.args.weapons) or 4) then
		table.insert(weapons, { Id = id, Name = def.Name, Rank = ({ 5, 3, 2, 1 })[i], Evolved = i == 1 and def.Evolution ~= nil, Damage = 12 + i * 3, Interval = 1.4 - i * 0.1 })
	end
end
for i, id in ipairs({ "Might", "Armor", "Heart" }) do
	local def = PassiveData.Passives[id]
	if def then
		table.insert(passives, { Id = id, Name = def.Name, Rank = ({ 3, 1, 4 })[i] })
	end
end
C.fire("Inventory", { Weapons = weapons, Passives = passives, WeaponSlots = 4, PassiveSlots = 4, Rerolls = 1, Skips = 0 })

-- the contract attributes
local state = {}
if stage ~= "none" and not missing then
	state.RunStage = stage
	state.RunClock = clock
	state.TeamRunGold = 215
	state.ChestCost = 140
	if stage == "BeaconAvailable" or stage == "Rally" or stage == "Charge" then
		state.BeaconPos = centre + Vector3.new(160, 0, -90)
	end
	if stage == "Rally" then
		state.RallyLeft = 21
	end
	if stage == "Charge" then
		state.BeaconCharge = 0.42
		state.BeaconPos = centre + Vector3.new(28, 0, -16)
	end
	if stage == "Boss" then
		state.BossName = "Basin Breaker"
		state.BossMaxHP = 24000
		state.BossHP = tonumber(preview.args.boss) and tonumber(preview.args.boss) * 24000 or 11800
	end
end
C.setState(state)
if not missing then
	C.setPlayer({ Downed = view == "downed" or view == "spectate", PendingChoices = view == "cards" and 2 or 0 })
end
C.settle(2.2)
preview.log("run-hud: stage=" .. stage .. " view=" .. view .. " team=" .. team .. " clock=" .. clock)
