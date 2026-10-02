-- arena: Forest arena (--set arena=Ruins|Swamp|Snow|Desert|Lava for the others) at 8:24 into a run, the
-- hero at the centre, 120 mixed enemies (EnemyRenderer models), gems, pickups and the HUD
-- with several weapons / passives. Camera: the real CameraController run camera.
local A = lib("arena")
local C = lib("common")
-- --set at=hazard (next to the arena's first floor hazard, --set hazard=N for another) or
-- --set at=x,z (arena-relative): moves the hero (and the swarm) there
local at = preview.args.at
local place = nil
if at then
	place = function(_s, arena, centre)
		if at == "hazard" then
			local hz = arena.Hazards and arena.Hazards[tonumber(preview.args.hazard) or 1]
			if hz then
				return Vector3.new(hz.Pos.X, centre.Y, hz.Pos.Z + hz.Radius + 5)
			end
		else
			local x, z = string.match(at, "^(-?[%d.]+),(-?[%d.]+)$")
			if x and z then
				return Vector3.new(centre.X + tonumber(x), centre.Y, centre.Z + tonumber(z))
			end
		end
		return nil
	end
end
-- --set weapons=new: the HUD shows the weapons added with the Alchemist / Engineer /
-- Necromancer, and a moment of their effects is drawn by the real VFX (a ProjectileBatch
-- with spears, bolts, a turret and its shot, a totem, a hook with its chain, souls, ice
-- shards; WeaponFx flame patches behind the hero, a frost nova ring, a totem pulse).
-- --set evolved=on draws the evolved looks.
local newWeapons = preview.args.weapons == "new"
local s = A.build({ place = place, inventory = newWeapons and "new" or nil })
C.settle(3)
if newWeapons then
	local WeaponData = C.shared("WeaponData")
	local centre = s.centre
	local y0 = s.Config.ArenaOrigin.Y
	local evo = preview.args.evolved == "on"
	local tier = evo and 3 or 2
	local function vb(normal, evolved)
		return WeaponData.VisualByte(evo and evolved or normal, tier)
	end
	local items = {}
	local function add(visual, dx, dy, dz, yaw)
		table.insert(items, { visual, centre.X + dx, y0 + dy, centre.Z + dz, yaw or 0 })
	end
	-- spears thrust forward (-Z), bolts to the right, a hook out to the front left
	add(vb(22, 23), -0.9, 2.5, -9, 0)
	add(vb(22, 23), 1.2, 2.5, -8, -0.24)
	for i = 1, 3 do
		add(vb(24, 25), 8 + i * 4, 2.5, -2 - i * 1.5, -math.pi / 2 + 0.3)
	end
	add(vb(29, 30), -9, 2.5, -14, 0.55)
	-- the turret (left, aiming at the swarm) and its shot, the totem (right)
	add(vb(33, 34), -7, 0, 3, 0.9)
	add(WeaponData.VisualByte(35, tier), -10, 2.9, 0.5, 0.9)
	add(vb(27, 28), 7, 0, 4, 0)
	-- souls curling out, ice shards from a shattered enemy
	add(vb(31, 32), 4, 3.1, -5, -0.7)
	add(vb(31, 32), -4, 3.1, 7, 2.2)
	add(vb(31, 32), 11, 3.1, 8, -2.4)
	for i = 1, 3 do
		add(vb(26, 36), -14 + math.cos(i * 2.1) * 2, 2.5, -4 + math.sin(i * 2.1) * 2, i * 2.1)
	end
	local b = buffer.create(2 + #items * 11)
	buffer.writeu16(b, 0, #items)
	local o = 2
	for i, it in ipairs(items) do
		buffer.writeu16(b, o, 400 + i)
		buffer.writeu8(b, o + 2, it[1])
		buffer.writeu8(b, o + 3, 1)
		buffer.writei16(b, o + 4, math.floor(it[2] * 10 + 0.5))
		buffer.writei16(b, o + 6, math.floor(it[3] * 10 + 0.5))
		buffer.writei16(b, o + 8, math.floor(it[4] * 10 + 0.5))
		buffer.writeu8(b, o + 10, math.floor(((it[5] % (math.pi * 2)) / (math.pi * 2)) * 255 + 0.5) % 256)
		o += 11
	end
	C.fire("ProjectileBatch", b)
	local me = game:GetService("Players").LocalPlayer
	local x, z = centre.X, centre.Z
	-- the flame trail the hero left walking up from the south-east
	local patches = {}
	for i = 1, 6 do
		table.insert(patches, { x + 2 + i * 1.4, z + 3 + i * 2.4, 3.6, 3 - i * 0.3, evo and 1 or 0 })
	end
	C.fire("WeaponFx", {
		fp = patches,
		hk = { { me.UserId, 400 + 6, 1 } },
		tp = { { x + 7, z + 4, 9, evo and 1 or 0, 1 } },
	})
	C.settle(0.6)
	C.fire("ProjectileBatch", b)
	C.fire("WeaponFx", { nv = { { x, z, 13, evo and 1 or 0 } } })
	C.settle(0.12)
end
preview.metrics.swarm = preview.worldCounts()
preview.metrics.enemies = s.enemyCount
