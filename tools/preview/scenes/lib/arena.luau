--[[
	scenes/lib/arena.luau - an in-run moment: arena + lighting, the hero at the centre, a
	swarm of enemy bodies made exactly like EnemySpawner makes them (pooled shells,
	ApplyEnemyLook, Type / Elite attributes) so the real client EnemyRenderer hangs its
	ModelLibrary models on them, gems and pickups like XPSystem, and the in-run HUD fed
	through the real attributes and the Inventory remote.

	options: arena ("Forest" | "Ruins"), enemies (120), seconds (run time, 504),
	         swarm (false = no enemies), client (false = no UI / client modules),
	         portal (place the stage portal like StageManager: MapBuilder.FindPortalSpot +
	         BuildPortal; s.portal), heroNearPortal (studs south of the portal to stand,
	         the hero and the swarm then centre there), stage (Stage attributes: number)
]]

local C = lib("common")
local A = {}

local Players = game:GetService("Players")

local function weightedPick(rng, weights)
	local total = 0
	local keys = {}
	for k, w in pairs(weights) do
		total += w
		table.insert(keys, k)
	end
	table.sort(keys)
	local roll = rng:NextNumber() * total
	for _, k in ipairs(keys) do
		roll -= weights[k]
		if roll <= 0 then
			return k
		end
	end
	return keys[#keys]
end

-- Enemy bodies like EnemySpawner.Spawn: ring 8-45 studs around `centre`, facing it.
function A.swarm(s, centre: Vector3, count: number, runSeconds: number)
	local EnemyData = C.shared("EnemyData")
	local Config = s.Config
	local ModelBuilder = s.ModelBuilder
	if not EnemyData or not ModelBuilder or not Config then
		return 0
	end
	local folder = workspace:FindFirstChild("SwarmEnemies") or Instance.new("Folder")
	folder.Name = "SwarmEnemies"
	folder.Parent = workspace
	local rng = Random.new(preview.seed * 31 + 7)
	local row = EnemyData.GetSpawnRow(runSeconds)
	local made = 0
	for i = 1, count do
		local typeId = weightedPick(rng, row.Weights)
		local def = EnemyData.Enemies[typeId]
		local elite = i % 40 == 0 -- a few elites
		local sizeMult = elite and Config.Enemies.EliteSizeMult or 1
		local model, body = C.try("BuildEnemyShell", ModelBuilder.BuildEnemyShell, i, folder)
		if model and body then
			local a = rng:NextNumber(0, math.pi * 2)
			local r = math.sqrt(rng:NextNumber(8 * 8, 45 * 45))
			local pos = Vector3.new(centre.X + math.cos(a) * r, Config.ArenaOrigin.Y, centre.Z + math.sin(a) * r)
			C.try("ApplyEnemyLook", ModelBuilder.ApplyEnemyLook, body, def, elite, sizeMult)
			local height = (def.FlyHeight or 0) + def.Size.Y * sizeMult / 2
			local c = pos + Vector3.new(0, height, 0)
			local look = Vector3.new(centre.X - pos.X, 0, centre.Z - pos.Z)
			body.CFrame = CFrame.lookAt(c, c + (look.Magnitude > 0.1 and look.Unit or Vector3.new(0, 0, -1)))
			body:SetAttribute("Elite", elite)
			body:SetAttribute("Type", typeId)
			made += 1
		end
	end
	return made
end

-- XP gems + floor pickups + a chest like XPSystem.
function A.drops(s, centre: Vector3)
	local ModelBuilder = s.ModelBuilder
	local Config = s.Config
	if not ModelBuilder or not Config then
		return
	end
	local gems = Instance.new("Folder")
	gems.Name = "SwarmGems"
	gems.Parent = workspace
	local pickups = Instance.new("Folder")
	pickups.Name = "SwarmPickups"
	pickups.Parent = workspace
	local rng = Random.new(preview.seed * 17 + 3)
	for i = 1, 40 do
		local gem = C.try("BuildGem", ModelBuilder.BuildGem, i, gems)
		if gem then
			local kind = (i % 13 == 0 and "Large") or (i % 5 == 0 and "Medium") or "Small"
			C.try("StyleGem", ModelBuilder.StyleGem, gem, kind)
			local a, r = rng:NextNumber(0, math.pi * 2), rng:NextNumber(4, 34)
			local pos = Vector3.new(centre.X + math.cos(a) * r, Config.ArenaOrigin.Y + Config.XP.GemHeight, centre.Z + math.sin(a) * r)
			gem.CFrame = CFrame.new(pos)
			gem:SetAttribute("Base", pos)
			gem:SetAttribute("Active", true)
		end
	end
	for i, kind in ipairs({ "Chicken", "Magnet", "Bomb" }) do
		local a = i * 2.1
		local pos = Vector3.new(centre.X + math.cos(a) * 16, Config.ArenaOrigin.Y + 1.2, centre.Z + math.sin(a) * 16)
		local m = C.try("BuildPickup " .. kind, ModelBuilder.BuildPickup, kind, pos)
		if m then
			m.Parent = pickups
		end
	end
	local chest = C.try("BuildChest", ModelBuilder.BuildChest, Vector3.new(centre.X - 12, Config.ArenaOrigin.Y, centre.Z + 9))
	if chest then
		chest.Parent = pickups
	end
end

-- Inventory payload like LevelUpSystem.SendInventory ("new": the weapons added with the
-- Alchemist / Engineer / Necromancer).
function A.inventory(which: string?)
	local WeaponData = C.shared("WeaponData")
	local PassiveData = C.shared("PassiveData")
	if not WeaponData or not PassiveData then
		return nil
	end
	local weapons = {}
	if which == "new" then
		for i, id in ipairs({ "FireTrail", "Turret", "SoulBolt", "Spear", "ChainHook", "HealingTotem" }) do
			local def = WeaponData.Weapons[id]
			local evolved = preview.args.evolved == "on" and i <= 3
			table.insert(weapons, { Id = id, Name = evolved and def.Evolution.Name or def.Name, Level = evolved and WeaponData.MaxLevel or (9 - i), Evolved = evolved, Color = def.Color })
		end
		local passives = {}
		for i, id in ipairs({ "Precision", "Renewal", "Might" }) do
			local def = PassiveData.Passives[id]
			table.insert(passives, { Id = id, Name = def.Name, Level = 4 - i, Color = def.Color })
		end
		return { Weapons = weapons, Passives = passives, Rerolls = 1, Skips = 1, WeaponSlots = 6, PassiveSlots = 6 }
	end
	for i, id in ipairs(WeaponData.Order) do
		if i > 4 then
			break
		end
		local def = WeaponData.Weapons[id]
		local evolved = i == 1 and def.Evolution ~= nil
		table.insert(weapons, { Id = id, Name = evolved and def.Evolution.Name or def.Name, Level = evolved and WeaponData.MaxLevel or (9 - i * 2), Evolved = evolved, Color = def.Color })
	end
	local passives = {}
	for i, id in ipairs(PassiveData.Order) do
		if i > 3 then
			break
		end
		local def = PassiveData.Passives[id]
		table.insert(passives, { Id = id, Name = def.Name, Level = 4 - i, Color = def.Color })
	end
	return { Weapons = weapons, Passives = passives, Rerolls = 1, Skips = 1, WeaponSlots = 6, PassiveSlots = 6 }
end

function A.build(opts)
	opts = opts or {}
	local arenaName = opts.arena or preview.args.arena or "Forest"
	local runSeconds = opts.seconds or 504
	local s = C.bootServer()
	local arena
	if s.MapBuilder then
		-- the lobby exists in a real server too (built at boot)
		if opts.lobby ~= false then
			C.try("MapBuilder.BuildLobby", s.MapBuilder.BuildLobby)
		end
		arena = C.try("MapBuilder.BuildArena", s.MapBuilder.BuildArena, arenaName)
	end
	s.arena = arena
	local centre = (arena and arena.Center) or (s.Config and s.Config.ArenaOrigin) or Vector3.zero
	if opts.portal and arena and s.MapBuilder and s.MapBuilder.BuildPortal then
		local spot = C.try("MapBuilder.FindPortalSpot", s.MapBuilder.FindPortalSpot, arena, Random.new(preview.seed * 13 + 5), nil)
		if spot then
			s.portal = C.try("MapBuilder.BuildPortal", s.MapBuilder.BuildPortal, arena, spot)
			if s.portal and opts.portalState then
				C.try("portal SetState", s.portal.SetState, opts.portalState, opts.portalCharge or 0)
			end
			if opts.heroNearPortal then
				centre = Vector3.new(spot.X, centre.Y, spot.Z + opts.heroNearPortal)
			end
		end
	end
	if opts.place and arena then
		-- the scene puts things on the map and may move the hero (returns a floor point)
		centre = opts.place(s, arena, centre) or centre
	end
	s.centre = centre
	if opts.hero ~= false then
		C.spawnCharacter(s.ModelBuilder, CFrame.new(centre + Vector3.new(0, 3.5, 0)), opts.character or preview.args.character or "Knight")
	end
	if opts.swarm ~= false then
		s.enemyCount = A.swarm(s, centre, opts.enemies or tonumber(preview.args.enemies) or 120, runSeconds)
		A.drops(s, centre)
	end
	C.setState({ Phase = "Running", Mode = "Solo", RunTime = runSeconds, Participants = 1, Arena = arenaName, SelectedArena = arenaName, BossHP = 0, BossMaxHP = 0, Frozen = false, LobbySpawn = CFrame.new(1200, 3.5, -6) })
	C.setPlayer({ InRun = true, Alive = true, HP = 82, MaxHP = 120, Level = 14, XP = 38, XPNeeded = 80, Kills = 412, RunGold = 57, PartnerRevivesLeft = 0, AuraRadius = 0 })
	-- the run's curses / a daily run (HUD chips): --set curses=Frenzy,Horde --set daily=on
	if preview.args.curses or preview.args.daily then
		local list = preview.args.curses or ""
		local CurseData = C.shared("CurseData")
		C.setState({ Curses = list, CurseGold = CurseData and CurseData.GoldMult(CurseData.FromString(list)) or 1, DailyRun = preview.args.daily == "on" })
	end
	if preview.args.steadyaim then
		-- the Ranger's buff chip (WeaponSystem sets SteadyAim): --set steadyaim=on|off
		C.setPlayer({ SteadyAim = preview.args.steadyaim == "on" })
	end
	if opts.stage then
		C.setState({
			Stage = opts.stage,
			StagePhase = opts.stagePhase or "Explore",
			StageArena = arenaName,
			PortalPos = s.portal and s.portal.Pos or nil,
			PortalHint = opts.portalHint == true,
			-- --set swarmwarn=1|2 shows the swarm-pressure warning on the stage pill
			SwarmWarn = opts.swarmWarn or tonumber(preview.args.swarmwarn) or 0,
			PortalReveal = opts.portalReveal or 0,
			PortalCharge = opts.portalCharge or 0,
			PortalLockLeft = opts.lockLeft or 0,
			SurgeLeft = opts.surgeLeft or 0,
			ChoiceLeft = opts.choiceLeft or 0,
			PortalReady = opts.portalReady or "",
		})
	end
	if opts.client ~= false then
		C.startClient()
		C.sendProfile()
		local inv = A.inventory(opts.inventory)
		if inv then
			C.fire("Inventory", inv)
		end
	end
	return s
end

return A
