-- boss: the Scorpion Queen fight at one moment (--set moment=...), with her pose (the
-- real EnemyRenderer driven by the "Act" attribute), the floor telegraph (Telegraphs.lua
-- through the FxBatch remote) and the boss bar (name, phase marker at 50%).
--   entrance  rising out of the ground, dust ring, the bar filling with her name
--   charge    crouched, the charge lane filling toward the hero
--   venom     claws up, Venom Burst circles filling under / around the hero
--   ring      tail raised and glowing, stinger spokes with three safe gaps
--   burrow    underground: dust trail, the eruption circle under the hero
--   summon    eggs wobbling and cracking around her
--   stunned   dizzy after a charge (stars), phase 2 (bar under the marker)
--   collapse  the defeat collapse
local A = lib("arena")
local C = lib("common")
local E = lib("encounter")
local moment = preview.args.moment or "charge"
local s = A.build({ swarm = false })
local c = s.centre
local hero = Vector3.new(c.X, c.Y, c.Z)
local bossAt = Vector3.new(c.X - 26, c.Y, c.Z + 2)
local acts = { entrance = "Emerge", charge = "Windup", venom = "Claws", ring = "TailRaise", burrow = "Burrow", summon = "Summon", stunned = "Stunned", collapse = "Collapse" }
local hpShare = (moment == "stunned" or moment == "collapse") and (moment == "collapse" and 0 or 0.42) or 0.78
C.setState({ BossMaxHP = 2700, BossHP = math.floor(2700 * hpShare), BossName = "Scorpion Queen", BossIntro = moment == "entrance" and 2.5 or 0.05, BossPhaseAt = hpShare < 0.5 and 0 or 0.5, BossPhase = hpShare < 0.5 and 2 or 1, StagePhase = "Boss", Stage = 1 })
for i, off in ipairs({ { -30, 8 }, { 26, 12 }, { -22, -18 }, { 34, -4 } }) do
	E.enemy(s, i % 2 == 0 and "Skeleton" or "Slime", Vector3.new(c.X + off[1], c.Y, c.Z + off[2]), hero)
end
local bossBody = E.enemy(s, "Boss", bossAt, hero, { Act = acts[moment] })
preview.advance(0.1)
local warns = {}
local wait = 0.5
local radius = 6
if moment == "entrance" then
	warns = { { "pop", bossAt.X, bossAt.Z, 18, "dust" }, { "circle", bossAt.X, bossAt.Z, 8, 2.5, "burrow" } }
	wait = 1.3
elseif moment == "charge" then
	local d = (hero - bossAt).Unit
	local len = 63
	warns = { { "lane", bossAt.X + d.X * len / 2, bossAt.Z + d.Z * len / 2, math.atan2(-d.X, -d.Z), len, 12, 1.0 } }
	wait = 0.6
elseif moment == "venom" then
	warns = {
		{ "circle", hero.X + 0.8, hero.Z + 0.5, radius, 1.1, "venom" },
		{ "circle", hero.X - 11, hero.Z + 4, radius, 1.1, "venom" },
		{ "circle", hero.X + 10, hero.Z + 7, radius, 1.1, "venom" },
	}
	wait = 0.6
elseif moment == "ring" then
	local angles = {}
	local count, skip = 20, { [2] = true, [3] = true, [4] = true, [9] = true, [10] = true, [11] = true, [16] = true, [17] = true, [18] = true }
	for i = 0, count - 1 do
		if not skip[i] then
			table.insert(angles, 0.1 + i * math.pi * 2 / count)
		end
	end
	warns = { { "spokes", bossAt.X, bossAt.Z, 6.5, 18, 1.8, angles } }
	wait = 0.6
elseif moment == "burrow" then
	warns = { { "circle", hero.X + 1, hero.Z - 6, 7.5, 0.8, "burrow" } }
	wait = 0.4
elseif moment == "summon" then
	for i = 1, 6 do
		local a = i * math.pi * 2 / 6
		table.insert(warns, { "egg", bossAt.X + math.cos(a) * 13, bossAt.Z + math.sin(a) * 13, 1.1 })
	end
	wait = 0.75
elseif moment == "collapse" then
	warns = { { "pop", bossAt.X, bossAt.Z, 13, "dust" } }
	wait = 0.8
end
E.warn(warns)
if moment == "burrow" then
	-- the Queen moves underground toward the hero while the trail follows her
	for _ = 1, 8 do
		if bossBody then
			bossBody.CFrame = bossBody.CFrame + Vector3.new(1.6, 0, 0)
		end
		preview.advance(0.05)
	end
end
preview.advance(tonumber(preview.args.t) or wait, 30)
