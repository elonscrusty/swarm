-- combat-fx: the CombatFx "juice" over the arena (hero at the centre, 120 enemies), drawn by
-- the real VFX / CombatFx from FxBatch / Inventory / SwarmState like the server sends them.
--   --set moment=kills    (default) a batch of hits, crits, small kills, a big and a huge kill
--   --set moment=levelup  the level-up pillar      --set moment=evolve  a weapon evolving
--   --set moment=phase    a boss phase change (screen-edge flash)
--   --set moment=pickup   a floor pickup taken next to the hero
--   --set moment=stress   15 heavy batches a second for 10 s (60 deaths, 120 hits, 16 crits,
--                         4 level-ups, 16 swings each), printing CombatFx.Stats() and the
--                         effect instances alive every second: they must stay bounded
--   --set t=0.06          seconds after the batch to render;  --set reduced=on  Reduced effects
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
	C.fire("FxBatch", { h = h, d = d, k = k, s = { { x, z, 0.4, 7, 1, 3, me.UserId } } })
	preview.advance(t, 30)
elseif moment == "levelup" then
	C.fire("FxBatch", { u = { { me.UserId, "levelup" } } })
	preview.advance(t > 0.1 and t or 0.15, 30)
elseif moment == "evolve" then
	local inv = A.inventory("new")
	inv.Weapons[1].Evolved = true
	C.fire("Inventory", inv)
	preview.advance(t > 0.1 and t or 0.1, 30)
elseif moment == "phase" then
	C.setState({ BossPhase = 1, BossMaxHP = 5000, BossHP = 2400, BossName = "Scorpion Queen" })
	preview.advance(0.2, 30)
	C.setState({ BossPhase = 2 })
	preview.advance(t > 0.1 and t or 0.12, 30)
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
			preview.advance(0.3, 30)
			near:Destroy()
		end
	end
	preview.advance(t > 0.1 and t or 0.1, 30)
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
	preview.advance(2, 30)
	stats("+2s idle")
end
stats(moment)
preview.metrics.combatFx = CFX and CFX.Stats() or nil
