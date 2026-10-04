-- combat-fx: the CombatFx "juice" over the arena (hero at the centre, 120 enemies), drawn by
-- the real VFX / CombatFx from FxBatch / Inventory / SwarmState like the server sends them.
--   --set moment=kills    (default) a batch of hits, crits, small kills, a big and a huge kill
--   --set moment=levelup  the level-up pillar      --set moment=evolve  a weapon evolving
--   --set moment=phase    a boss phase change (screen-edge flash)
--   --set moment=pickup   a floor pickup taken next to the hero
--   --set moment=armoury  the armoury-batch weapons (shields, meteor, saws, crack, wisps, rift,
--                         horn blast, censer cloud; --set evolved=on for the evolutions,
--                         --set moved=on: the hero steps aside, the shields follow it)
--   --set moment=stress   15 heavy batches a second for 10 s (60 deaths, 120 hits, 16 crits,
--                         4 level-ups, 16 swings each), printing CombatFx.Stats() and the
--                         effect instances alive every second: they must stay bounded
--   --set t=0.06          seconds after the batch to render;  --set reduced=on  Reduced effects
--   --set dump=on         also print the first CombatFx parts (position, size, transparency)
local A = lib("arena")
local C = lib("common")
local Players = game:GetService("Players")
local moment = preview.args.moment or "kills"
local s = A.build({ inventory = "new" })
C.settle(2)
local me = Players.LocalPlayer
local CFX = C.try("require CombatFx", preview.client, "CombatFx")
local Settings = C.try("require ClientSettings", preview.client, "ClientSettings")
if preview.args.reduced == "on" and Settings then
	Settings.Set("ReducedEffects", true)
end
local x, z = s.centre.X, s.centre.Z
local t = tonumber(preview.args.t) or 0.06
local tints = { Color3.fromRGB(120, 160, 70), Color3.fromRGB(170, 90, 60), Color3.fromRGB(110, 90, 150) }

local function killBatch(n, hits, crits)
	local h, d, k = {}, {}, {}
	for i = 1, hits do
		h[i] = (i % 120) + 1
	end
	for i = 1, crits do
		k[i] = ((i * 7) % 120) + 1
	end
	for i = 1, n do
		local a = i * 2.4
		local r = 6 + (i % 5) * 3
		d[i] = { x + math.cos(a) * r, z + math.sin(a) * r, tints[i % 3 + 1], 2.8 }
	end
	return h, d, k
end

local function stats(label)
	local st = CFX and CFX.Stats() or {}
	local juice = workspace:FindFirstChild("SwarmCombatFx")
	local vfx = workspace:FindFirstChild("SwarmClientFx")
	preview.log(string.format("%-8s alive=%d peak=%d started=%d skipped=%d pool=%d | instances: SwarmCombatFx=%d SwarmClientFx=%d", label, st.Alive or -1, st.Peak or -1,
		st.Started or -1, st.Skipped or -1, st.PoolSize or -1, juice and #juice:GetChildren() or -1, vfx and #vfx:GetDescendants() or -1))
end

if moment == "kills" then
	local h, d, k = killBatch(8, 30, 5)
	table.insert(d, { x + 10, z - 6, Color3.fromRGB(150, 70, 60), 5.2 }) -- brute / elite
	table.insert(d, { x - 12, z - 9, Color3.fromRGB(190, 150, 70), 11 }) -- boss-sized
	preview.advance(0.5, 60) -- 60 fps frames (30 fps halves the CombatFx budget)
	C.fire("FxBatch", { h = h, d = d, k = k, s = { { x, z, 0.4, 7, 1, 3, me.UserId } } })
	preview.advance(t, 60)
elseif moment == "levelup" then
	C.fire("FxBatch", { u = { { me.UserId, "levelup" } } })
	preview.advance(t > 0.1 and t or 0.15, 60)
elseif moment == "evolve" then
	local inv = A.inventory("new")
	inv.Weapons[1].Evolved = true
	C.fire("Inventory", inv)
	preview.advance(t > 0.1 and t or 0.1, 60)
elseif moment == "phase" then
	C.setState({ BossPhase = 1, BossMaxHP = 5000, BossHP = 2400, BossName = "Scorpion Queen" })
	preview.advance(0.2, 60)
	C.setState({ BossPhase = 2 })
	preview.advance(t > 0.1 and t or 0.12, 60)
elseif moment == "pickup" then
	local folder = workspace:FindFirstChild("SwarmPickups")
	local root = me.Character and me.Character.PrimaryPart
	if folder and root then
		local near, best = nil, math.huge
		for _, m in ipairs(folder:GetChildren()) do
			if m:IsA("Model") and m.Name ~= "Chest" then
				local dd = (m:GetPivot().Position - root.Position).Magnitude
				if dd < best then
					near, best = m, dd
				end
			end
		end
		if near then
			-- carry the hero next to it, then the server takes it
			root.CFrame = CFrame.new(near:GetPivot().Position + Vector3.new(2, 3, 0))
			preview.advance(0.3, 60)
			near:Destroy()
		end
	end
	preview.advance(t > 0.1 and t or 0.1, 60)
elseif moment == "armoury" then
	-- the armoury-batch weapons drawn by the real VFX (ProjectileBatch + WeaponFx like the
	-- server sends them): Ward Shields circling the hero, a Starfall meteor diving at its
	-- warning ring, two sawblades, an Earthsplitter crack, spirit wisps, a Vortex rift and a
	-- War Horn blast. --set evolved=on draws the evolved looks.
	local WeaponData = C.shared("WeaponData")
	local evo = preview.args.evolved == "on"
	local y0 = s.Config.ArenaOrigin.Y
	local tier = evo and 3 or 2
	local function vb(normal, evolved)
		return WeaponData.VisualByte(evo and evolved or normal, tier)
	end
	local items = {}
	local function add(visual, dx, dy, dz, yaw)
		table.insert(items, { visual, x + dx, y0 + dy, z + dz, yaw or 0 })
	end
	for i = 0, 3 do -- shields on their orbit (yaw = facing outward)
		local a = i * math.pi / 2 + 0.4
		local dir = Vector3.new(math.cos(a), 0, math.sin(a))
		add(vb(39, 40), dir.X * 5, 2.5, dir.Z * 5, math.atan2(-dir.X, -dir.Z))
	end
	add(vb(43, 44), -8, 14, -14, 0.8) -- meteor falling toward (-12, -17)
	add(vb(49, 50), 9, 1.4, -6, -1)
	add(vb(49, 50), 13, 1.4, 2, -1.8)
	add(vb(41, 42), -6, 0.6, 9, 2.6) -- crack head
	for i = 1, 3 do
		add(vb(53, 54), 3 + i * 1.6, 3, 6 + i * 0.8, 0)
	end
	add(vb(55, 56), 16, 0.15, 12, 0)
	add(vb(47, 48), -16, 1.2, 4, 0)
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
	local e = evo and 1 or 0
	C.fire("ProjectileBatch", b)
	-- the shields are drawn around the hero's live position (VFX K.setOrbit), the cloud by
	-- VFX on its invisible marker (K.newCloud)
	local orbits = {}
	for i = 0, 3 do
		table.insert(orbits, { me.UserId, 401 + i, 1, 5, 0, 1.2, (i * math.pi / 2 + 0.4) % (math.pi * 2) })
	end
	C.fire("WeaponFx", {
		ob = orbits,
		cl = { { 400 + #items, 1, evo and 7.2 or 5.6, e } },
		mt = { { x - 12, z - 17, 5.5, 0.9, e } },
		vx = { { x + 16, z + 12, 6.5, 3, e } },
		vn = { { x - 10, z - 4, 3.2, e } },
	})
	preview.advance(0.2, 60)
	C.fire("ProjectileBatch", b)
	preview.advance(0.6, 60) -- the cloud fades in
	C.fire("ProjectileBatch", b)
	if preview.args.moved == "on" then
		-- the hero steps 6 studs east: the shields must stay centred on the hero
		local root = me.Character and me.Character.PrimaryPart
		if root then
			root.CFrame = root.CFrame + Vector3.new(6, 0, 0)
		end
		preview.advance(0.1, 60)
		C.fire("ProjectileBatch", b)
	end
	local quake = {}
	for i = 1, 4 do
		table.insert(quake, { x - 1.5 * i, z + 2.2 * i, 2.4, e })
	end
	C.fire("WeaponFx", {
		qk = quake,
		hn = { { x, z, math.rad(-35), 11, evo and 180 or 55, e } },
		wb = { { x + 4, z - 3, e } },
	})
	preview.advance(t > 0.1 and t or 0.12, 60)
elseif moment == "stress" then
	stats("start")
	for sec = 1, 10 do
		for _ = 1, 15 do
			local h, d, k = killBatch(60, 120, 16)
			d[1][4] = 11 -- one huge and a few big kills in every batch
			d[2][4] = 5.2
			d[3][4] = 6
			local u, sw = {}, {}
			for i = 1, 4 do
				u[i] = { me.UserId, "levelup" }
			end
			for i = 1, 16 do
				sw[i] = { x, z, i * 0.4, 7, i % 2 == 0 and 1 or -1, i % 4, me.UserId }
			end
			C.fire("FxBatch", { h = h, d = d, k = k, u = u, s = sw })
			preview.advance(1 / 15, 4)
		end
		stats(sec .. "s")
	end
	preview.advance(2, 60)
	stats("+2s idle")
end
stats(moment)
if preview.args.dump == "on" then
	local juice = workspace:FindFirstChild("SwarmCombatFx")
	for i, part in ipairs(juice and juice:GetChildren() or {}) do
		if i <= 12 then
			local q = part.Position
			preview.log(string.format("  %s %s pos=(%.1f,%.1f,%.1f) size=(%.1f,%.1f,%.1f) alpha=%.2f", part.ClassName, part.Material.Name, q.X - x, q.Y, q.Z - z, part.Size.X, part.Size.Y, part.Size.Z, part.Transparency))
		end
	end
end
preview.metrics.combatFx = CFX and CFX.Stats() or nil
