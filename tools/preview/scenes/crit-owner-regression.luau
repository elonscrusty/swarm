-- crit-owner-regression: stream G. The server says WHO rolled each critical hit so a client gives its own
-- crits the crit tick and the bigger burst (FxBatch "k" = enemy ids, "ku" = user ids, same index).
--   1) Fx.Crit(enemyId, userId) lands in k / ku at the same index; no user = 0
--   2) the k cap (16) cuts k and ku together, they never drift apart
--   3) a real hit through EnemySpawner.Damage: a crit by a player carries that player's UserId, a hit that is
--      not a crit sends nothing, a crit without a killer (hazard, nobody) sends 0
-- Prints PASS / FAIL lines.
local C = lib("common")
local Players = game:GetService("Players")
local me = Players.LocalPlayer

preview.forceMeshesUploaded()
preview.startServer()
preview.advance(2)

local fails = 0
local function check(ok: boolean, label: string, detail: any?)
	if not ok then
		fails += 1
	end
	preview.log((ok and "PASS " or "FAIL ") .. label .. (detail ~= nil and ("  (" .. tostring(detail) .. ")") or ""))
end

local Fx = preview.server("Fx")
local batches = {}
preview.remote("FxBatch").OnClientEvent:Connect(function(b)
	table.insert(batches, b)
end)
local function collect()
	local k, ku = {}, {}
	for _, b in ipairs(batches) do
		for i, id in ipairs(b.k or {}) do
			table.insert(k, id)
			table.insert(ku, (b.ku or {})[i])
		end
	end
	table.clear(batches)
	return k, ku
end
local function join(t)
	local out = {}
	for i, v in ipairs(t) do
		out[i] = tostring(v)
	end
	return table.concat(out, ",")
end
preview.advance(0.3)
collect()

-- 1) direct
Fx.Crit(5, me.UserId)
Fx.Crit(6)
Fx.Crit(7, 12345)
preview.advance(0.2)
local k, ku = collect()
check(join(k) == "5,6,7" and join(ku) == me.UserId .. ",0,12345", "Fx.Crit: k and ku line up (no user = 0)", join(k) .. " | " .. join(ku))

-- 2) the cap
for i = 1, 20 do
	Fx.Crit(100 + i, 900 + i)
end
preview.advance(0.2)
k, ku = collect()
check(#k == 16 and #ku == 16 and k[16] == 116 and ku[16] == 916, "20 crits in one flush: k and ku are cut together at 16", #k .. " / " .. #ku)

-- 3) through the real damage path
local RM = preview.server("RunManager")
local Spawner = preview.server("EnemySpawner")
preview.remote("StartRun"):FireServer("Solo")
preview.advance(2)
local rp = assert(RM.GetRunPlayer(me), "run player missing")
rp.InvulnUntil = math.huge
local e = assert(Spawner.Spawn("Ghost", rp.Root.Position + Vector3.new(6, 0, 0)))
e.HP, e.MaxHP = 1e6, 1e6
preview.advance(0.3)
collect()
Spawner.Damage(e, 10, rp, nil, 0, false, true)
preview.advance(0.2)
k, ku = collect()
check(join(k) == tostring(e.Id) and join(ku) == tostring(me.UserId), "a crit by the player: the enemy id and the player's UserId", join(k) .. " | " .. join(ku))
Spawner.Damage(e, 10, rp, nil, 0, false, false)
preview.advance(0.2)
k, ku = collect()
check(#k == 0 and #ku == 0, "a hit that is not a crit sends no k / ku", #k)
Spawner.Damage(e, 10, nil, nil, 0, false, true)
preview.advance(0.2)
k, ku = collect()
check(join(k) == tostring(e.Id) and join(ku) == "0", "a crit with no player behind it sends user 0", join(k) .. " | " .. join(ku))

preview.log(fails == 0 and "crit-owner-regression: all PASS" or string.format("crit-owner-regression: %d FAIL", fails))
