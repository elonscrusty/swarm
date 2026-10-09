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
local UIS = game:GetService("UserInputService")
local function press(key)
	local input = { UserInputType = Enum.UserInputType.Keyboard, UserInputState = Enum.UserInputState.Begin, KeyCode = key, Position = Vector3.zero, Delta = Vector3.zero }
	UIS.InputBegan:_fire(input, false)
	C.settle(0.4)
end

if not missing then
	C.setPlayer({
		Downed = (view == "downed") or nil,
		BleedLeft = view == "downed" and 12 or nil,
		ReviveProgress = view == "downed" and (tonumber(preview.args.revive) or 0) or nil,
		Eliminated = view == "spectate" or nil,
		Spectating = view == "spectate" or nil,
		PendingChoices = view == "cards" and 2 or 0,
	})
	if view == "downed" or view == "spectate" then
		-- the local hero lies where the camera is; teammates stay up (the first one is the nearest)
		C.setPlayer({ HP = 0 })
	end
end
C.settle(2.2)

if view == "inventory" then
	local Hud = preview.client("Hud")
	Hud.SetBuildOpen(true)
	C.settle(0.8)
elseif view == "bigmap" then
	press(Enum.KeyCode.M)
	C.settle(0.8)
elseif view == "interact" then
	-- a downed teammate beside the hero (Revive wins over the chest beside us), or the chest alone
	-- (--set interact=chest) or the beacon (--set interact=beacon)
	local kind = preview.args.interact or "revive"
	local folder = workspace:FindFirstChild("SwarmLoot") or Instance.new("Folder")
	folder.Name = "SwarmLoot"
	folder.Parent = workspace
	local chest = Instance.new("Model")
	chest.Name = "Chest1"
	for k, v in pairs({ Pos = centre + Vector3.new(4, 0, 2), LootKind = "Chest", State = "Ready", Price = 140, LootId = 11, Hold = 0.4 }) do
		chest:SetAttribute(k, v)
	end
	chest.Parent = folder
	if kind == "revive" then
		local ben
		for _, p in ipairs(game:GetService("Players"):GetPlayers()) do
			if p.Name == "Ben" then
				ben = p
			end
		end
		if ben and ben.Character then
			ben.Character:PivotTo(CFrame.new(centre + Vector3.new(3, 3.5, 5)))
		end
	elseif kind == "beacon" then
		C.setState({ RunStage = "BeaconAvailable", BeaconPos = centre + Vector3.new(6, 0, 3) })
	elseif kind == "chest" then
		C.setState({ TeamRunGold = tonumber(preview.args.gold) or 215 })
	end
	-- the interact remote (stream D / E1 add it; the scene stands in)
	local net = game:GetService("ReplicatedStorage"):FindFirstChild("SwarmV2Net")
	local run = net and net:FindFirstChild("Run")
	if run and not run:FindFirstChild("Interact") then
		local ev = Instance.new("RemoteEvent")
		ev.Name = "Interact"
		ev.Parent = run
	end
	C.settle(1.2)
elseif view == "cards" then
	local ok, now = pcall(function()
		return workspace:GetServerTimeNow()
	end)
	now = ok and now or 0
	local source = preview.args.source or "Level"
	C.fire("LevelUpOffer", {
		OfferId = 7,
		Source = source,
		Level = 8,
		Deadline = now + (tonumber(preview.args.left) or 8.2),
		Seconds = tonumber(preview.args.left) or 8.2,
		RerollsLeft = tonumber(preview.args.rerolls) or 2,
		Group = team > 1,
		Choices = {
			{ Type = "WeaponUp", Id = "Whip", Name = "Rusty Sword", Category = "WeaponUpgrade", Rarity = "Rare", RankFrom = 2, RankTo = 3, Slot = 1,
				Lines = { { Label = "Damage", From = "14", To = "17" }, { Label = "Swings", From = "1", To = "2" }, { Label = "Interval", From = "1.40 s", To = "1.33 s" } },
				Synergy = "Blood Pact with Heart" },
			{ Type = "PassiveNew", Id = "Armor", Name = "Iron Plating", Category = "NewPassive", Rarity = "Uncommon", RankFrom = 0, RankTo = 2,
				Lines = { { Label = "Armor", From = "0", To = "6" } } },
			{ Type = "Evolve", Id = "Whip", Name = "Bloodblade", Category = "Evolution", Rarity = "Evolution", Slot = 1,
				Lines = { { Text = "Sword becomes Bloodblade" }, { Label = "Damage", From = "30", To = "52" } } },
		},
	})
	C.settle(1.4)
elseif view == "results" then
	C.setState({ Phase = "Results" })
	C.sendProfile(C.profile({ Frame = "Gold", Account = { XP = 2240 } }))
	local outcome = preview.args.outcome or "Victory"
	local save = preview.args.save or "Pending"
	C.fire("RunResult", {
		Outcome = outcome,
		Duration = 927,
		NewUnlocks = outcome == "Victory" and { "granny_boom", { Id = "coach_crunch", Name = "Coach Crunch" } } or nil,
		SaveStatus = save ~= "none" and save or nil,
		Stats = { Kills = 1840, Elites = 12, Chests = 7, Dashes = 96, Revives = 2, Distance = 9120, Bosses = outcome == "Victory" and 1 or 0 },
		Mode = "Trio",
		CharacterId = "Knight",
		Build = { Weapons = { { Id = "Whip", Level = 5, Evolved = true }, { Id = "MagicOrb", Level = 3 } }, Passives = { { Id = "Might", Level = 3 } } },
		Account = { Gained = 342, From = 7, To = 8, Into = 92, Need = 500, Rewards = {} },
		Time = 927, Kills = 1840, Gold = 640, GoldEarned = 640, GoldLost = 0, GoldRetention = 1, Level = 21, Damage = 186400,
		Arena = "Cliffwood", Seconds = 25, StagesCleared = 1, Stage = 1, BossKills = outcome == "Victory" and 1 or 0, BossFight = true, Items = {},
	})
	C.settle(2.5)
elseif view == "menu" then
	local UIBuilder = preview.client("UIBuilder")
	UIBuilder.OpenPause()
	C.settle(1)
end
preview.log("run-hud: stage=" .. stage .. " view=" .. view .. " team=" .. team .. " clock=" .. clock)
