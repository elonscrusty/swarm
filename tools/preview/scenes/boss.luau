-- boss: one stage boss at one moment (--set boss=ScorpionQueen|MothMatriarch|RhinoWarlord|
-- HiveMother, --set moment=...), with its pose (the real EnemyRenderer driven by the "Act"
-- attribute), the floor telegraphs (Telegraphs.lua through the FxBatch remote, packed like
-- the server's Fx.Warn) and the boss bar (name, phase marker at 50%).
--   ScorpionQueen  entrance | charge | venom | ring | burrow | summon | stunned | collapse
--   MothMatriarch  entrance | storm (gathering: the gap lane) | wave (the ring rolling out)
--                  | dive | mines | summon | gust (phase 2) | grounded | collapse
--   RhinoWarlord   entrance | charge | stuck | pound | banner | summon | collapse
--   HiveMother     entrance | eggs | pools | trails (phase 2) | brood | pulse | collapse
-- --set t=<seconds> changes how long after the warnings the picture is taken.
local A = lib("arena")
local C = lib("common")
local E = lib("encounter")
local bossId = preview.args.boss or "ScorpionQueen"
local moment = preview.args.moment or (bossId == "ScorpionQueen" and "charge" or bossId == "MothMatriarch" and "storm" or bossId == "RhinoWarlord" and "pound" or "eggs")
local s = A.build({ swarm = false })
local c = s.centre
local hero = Vector3.new(c.X, c.Y, c.Z)
local bossAt = Vector3.new(c.X - 26, c.Y, c.Z + 2)
local function at(dx, dz)
	return Vector3.new(c.X + dx, c.Y, c.Z + dz)
end
local BossData = C.shared("BossData")
local data = BossData and BossData.Get(bossId)
local typeOf = { ScorpionQueen = "Boss", MothMatriarch = "MothBoss", RhinoWarlord = "RhinoBoss", HiveMother = "HiveBoss" }
local bossType = typeOf[bossId] or "Boss"
local radius = ({ Boss = 6, MothBoss = 5, RhinoBoss = 6, HiveBoss = 5.5 })[bossType]
local phase2 = moment == "stunned" or moment == "gust" or moment == "trails" or moment == "collapse"
local hpShare = moment == "collapse" and 0 or (phase2 and 0.42 or 0.78)
C.setState({ BossMaxHP = 2700, BossHP = math.floor(2700 * hpShare), BossName = data and data.DisplayName or "Scorpion Queen", BossIntro = moment == "entrance" and 2.5 or 0.05, BossPhaseAt = hpShare < 0.5 and 0 or 0.5, BossPhase = hpShare < 0.5 and 2 or 1, StagePhase = "Boss", Stage = bossId == "ScorpionQueen" and 1 or 3 })
for i, off in ipairs({ { -30, 8 }, { 26, 12 }, { -22, -18 }, { 34, -4 } }) do
	E.enemy(s, i % 2 == 0 and "Skeleton" or "Slime", at(off[1], off[2]), hero)
end

local acts = {
	ScorpionQueen = { entrance = "Emerge", charge = "Windup", venom = "Claws", ring = "TailRaise", burrow = "Burrow", summon = "Summon", stunned = "Stunned", collapse = "Collapse" },
	MothMatriarch = { entrance = "Emerge", storm = "Gather", dive = "Lift", mines = "Gather", summon = "Summon", gust = "GustWindup", grounded = "Grounded", collapse = "Collapse" },
	RhinoWarlord = { entrance = "Emerge", charge = "Windup", stuck = "Stuck", pound = "Pound", summon = "Summon", collapse = "Collapse" },
	HiveMother = { entrance = "Emerge", eggs = "Heave", pools = "Spew", trails = "Spew", brood = "Summon", collapse = "Collapse" },
}
local bossBody = E.enemy(s, bossType, bossAt, hero, { Act = (acts[bossId] or {})[moment] })
preview.advance(0.1)
local warns = {}
local wait = 0.5
local function laneTo(len, width, seconds)
	local d = (hero - bossAt).Unit
	return { "lane", bossAt.X + d.X * len / 2, bossAt.Z + d.Z * len / 2, math.atan2(-d.X, -d.Z), len, width, seconds }
end

if bossId == "ScorpionQueen" then
	local vr = 6
	if moment == "entrance" then
		warns = { { "pop", bossAt.X, bossAt.Z, 18, "dust" }, { "circle", bossAt.X, bossAt.Z, 8, 2.5, "burrow" } }
		wait = 1.3
	elseif moment == "charge" then
		warns = { laneTo(63, 12, 1.0) }
		wait = 0.6
	elseif moment == "venom" then
		warns = {
			{ "circle", hero.X + 0.8, hero.Z + 0.5, vr, 1.1, "venom" },
			{ "circle", hero.X - 11, hero.Z + 4, vr, 1.1, "venom" },
			{ "circle", hero.X + 10, hero.Z + 7, vr, 1.1, "venom" },
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
elseif bossId == "MothMatriarch" then
	local A2 = data.Attacks
	if moment == "entrance" then
		warns = { { "circle", bossAt.X, bossAt.Z, radius + 2, 2.5, "pulse" }, { "pop", bossAt.X, bossAt.Z, 10, "gust" } }
		wait = 1.2
	elseif moment == "storm" or moment == "wave" then
		-- the gap opens toward the hero's lower side, so the safe lane is on screen
		local W = A2.DustStorm
		local gap = math.atan2(hero.Z - 8 - bossAt.Z, hero.X - bossAt.X)
		warns = { { "wave", bossAt.X, bossAt.Z, radius * 0.8, W.Windup, W.Speed, W.MaxRadius, W.Width, gap, math.rad(W.GapHalf) } }
		wait = moment == "wave" and (W.Windup + 0.85) or 0.6
	elseif moment == "dive" then
		warns = { laneTo(A2.Dive.Speed * A2.Dive.Duration, radius * 2, A2.Dive.Windup) }
		wait = 0.6
	elseif moment == "mines" then
		local G = A2.GlimmerMines
		for _, off in ipairs({ { 4, -3 }, { -9, 6 }, { 10, 8 }, { -3, -13 }, { 14, -6 } }) do
			table.insert(warns, { "mine", hero.X + off[1], hero.Z + off[2], G.Radius, G.Fuse, bossAt.X, bossAt.Z })
		end
		wait = 1.3
	elseif moment == "summon" then
		for i = 1, 4 do
			local a = i * math.pi * 2 / 4 + 0.4
			table.insert(warns, { "egg", bossAt.X + math.cos(a) * 11, bossAt.Z + math.sin(a) * 11, 1.1 })
		end
		wait = 0.75
	elseif moment == "gust" then
		local Gu = A2.WingGust
		local d = (hero - bossAt).Unit
		warns = { { "gust", bossAt.X, bossAt.Z, math.atan2(d.Z, d.X), Gu.Length, math.rad(Gu.HalfAngle), Gu.Windup, Gu.Blow } }
		wait = 0.6
	elseif moment == "grounded" then
		warns = { { "pop", bossAt.X, bossAt.Z, 8, "dust" } }
		wait = 0.5
	elseif moment == "collapse" then
		warns = { { "pop", bossAt.X, bossAt.Z, 11, "dust" } }
		wait = 0.8
	end
elseif bossId == "RhinoWarlord" then
	local A2 = data.Attacks
	if moment == "entrance" then
		warns = { { "pop", bossAt.X, bossAt.Z, 20, "dust" }, { "circle", bossAt.X, bossAt.Z, radius + 2, 2.5, "burrow" } }
		wait = 1.3
	elseif moment == "charge" then
		warns = { laneTo(48, radius * 2, A2.HornCharge.Windup) }
		wait = 0.7
	elseif moment == "stuck" then
		warns = { { "pop", bossAt.X - 5, bossAt.Z, 6, "slam" } }
		wait = 0.3
	elseif moment == "pound" then
		local P2 = A2.GroundPound
		local inner = 0
		for i, outer in ipairs(P2.Bands) do
			table.insert(warns, { "band", bossAt.X, bossAt.Z, inner, outer, P2.First + (i - 1) * P2.Gap })
			inner = outer
		end
		wait = 0.7
	elseif moment == "banner" then
		local B = A2.WarBanner
		local spot = at(-10, 12)
		local banner = E.enemy(s, "WarBanner", spot, hero)
		if banner then
			banner:SetAttribute("HPFrac", 0.7)
		end
		if bossBody then
			bossBody:SetAttribute("BannerOut", true)
		end
		for _, off in ipairs({ { -2, 8 }, { -18, 14 }, { -12, 22 } }) do
			local b = E.enemy(s, "Skeleton", at(off[1], off[2]), hero)
			if b then
				b:SetAttribute("Rallied", true)
			end
		end
		warns = { { "aura", spot.X, spot.Z, B.Radius, 900 } }
		C.fire("Notify", { Text = "WAR BANNER! Destroy it to break the rally", Color = Color3.fromRGB(255, 190, 110) })
		wait = 0.8
	elseif moment == "summon" then
		for i = 1, 4 do
			local a = i * math.pi * 2 / 4 + 0.3
			table.insert(warns, { "emerge", bossAt.X + math.cos(a) * 13, bossAt.Z + math.sin(a) * 13, 1.1 })
		end
		wait = 0.7
	elseif moment == "collapse" then
		warns = { { "pop", bossAt.X, bossAt.Z, 13, "dust" } }
		wait = 0.8
	end
elseif bossId == "HiveMother" then
	local A2 = data.Attacks
	if moment == "entrance" then
		warns = { { "pop", bossAt.X, bossAt.Z, 18, "dust" }, { "circle", bossAt.X, bossAt.Z, radius + 2, 2.5, "burrow" } }
		wait = 1.3
	elseif moment == "eggs" then
		local Eg = A2.EggBarrage
		for _, off in ipairs({ { 3, -4 }, { -8, 6 }, { 9, 5 } }) do
			local p = at(off[1], off[2])
			table.insert(warns, { "glob", bossAt.X, bossAt.Z, p.X, p.Z, Eg.Flight, 6 + (p - bossAt).Magnitude * 0.15, "egg" })
			table.insert(warns, { "circle", p.X, p.Z, Eg.Splash, Eg.Flight, "acid" })
		end
		-- two eggs of the last barrage already on the ground, about to hatch
		for _, off in ipairs({ { -12, -10 }, { 12, -12 } }) do
			local p = at(off[1], off[2])
			local egg = E.enemy(s, "BroodEgg", p, hero, { Act = "Incubate" })
			if egg then
				egg:SetAttribute("HPFrac", 1)
			end
			table.insert(warns, { "circle", p.X, p.Z, 2.3, 3.5, "hatch" })
		end
		wait = 0.55
	elseif moment == "pools" or moment == "trails" then
		local P2 = A2.AcidPools
		for _, off in ipairs({ { 1, 1 }, { -10, 9 }, { 11, -6 } }) do
			local p = at(off[1], off[2])
			table.insert(warns, { "patch", p.X, p.Z, P2.Radius, P2.Fill, P2.Life, "acid" })
			if moment == "trails" then
				local dir = (bossAt - p).Unit
				for k = 1, P2.TrailCount do
					local q = p + dir * (P2.Radius + P2.TrailSpacing * (k - 0.4))
					table.insert(warns, { "patch", q.X, q.Z, P2.TrailRadius, P2.Fill + 0.1 * k, P2.Life * 0.7, "acid" })
				end
			end
		end
		wait = moment == "trails" and 1.6 or 0.7
	elseif moment == "brood" then
		for i = 1, 3 do
			local a = i * math.pi * 2 / 3 + 0.5
			table.insert(warns, { "emerge", bossAt.X + math.cos(a) * 15, bossAt.Z + math.sin(a) * 15, 1.2 })
		end
		wait = 0.8
	elseif moment == "pulse" then
		warns = { { "circle", bossAt.X, bossAt.Z, radius + 5, 0.9, "pulse" } }
		wait = 0.5
	elseif moment == "collapse" then
		warns = { { "pop", bossAt.X, bossAt.Z, 12, "dust" } }
		wait = 0.8
	end
end
E.warn(warns)
if bossId == "ScorpionQueen" and moment == "burrow" then
	-- the Queen moves underground toward the hero while the trail follows her
	for _ = 1, 8 do
		if bossBody then
			bossBody.CFrame = bossBody.CFrame + Vector3.new(1.6, 0, 0)
		end
		preview.advance(0.05)
	end
end
preview.advance(tonumber(preview.args.t) or wait, 30)
