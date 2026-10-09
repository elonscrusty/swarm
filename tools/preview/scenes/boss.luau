-- boss: one stage boss at one moment (--set boss=ScorpionQueen|MothMatriarch|RhinoWarlord|
-- HiveMother, --set moment=...), with its pose (the real EnemyRenderer driven by the "Act"
-- attribute), the floor telegraphs (Telegraphs.lua through the FxBatch remote, packed like
-- the server's Fx.Warn) and the boss bar (name, phase marker at 50%).
--   ScorpionQueen  entrance | charge | venom | ring | burrow | summon | stunned | collapse
--   MothMatriarch  entrance | storm (gathering: the gap lane) | wave (the ring rolling out)
--                  | dive | mines | summon | gust (phase 2) | grounded | collapse
--   RhinoWarlord   entrance | charge | stuck | pound | banner | summon | collapse
--   HiveMother     entrance | eggs | pools | trails (phase 2) | brood | pulse | collapse
--   BriarSentinel  entrance | roots | erupt (thorns running along the lanes) | volley |
--                  bramble (gathering: the way out) | closing | summon | collapse
--   FrostboundColossus  entrance | slam | wave | lanes | spikes | breath | shards |
--                  armor (phase 2, frost armour on) | stunned (armour shattered) | collapse
--   BasinBreaker   entrance | slam (root slam ring) | charge (the 45-stud lane) | sap (three
--                  circles, one after another) | stuck | collapse   [stream D, the Cliffwood boss]
-- --set t=<seconds> changes how long after the warnings the picture is taken.
local A = lib("arena")
local C = lib("common")
local E = lib("encounter")
local bossId = preview.args.boss or "ScorpionQueen"
local DEFAULT_MOMENT = { ScorpionQueen = "charge", MothMatriarch = "storm", RhinoWarlord = "pound", HiveMother = "eggs", BriarSentinel = "roots", FrostboundColossus = "lanes", BasinBreaker = "slam" }
local moment = preview.args.moment or DEFAULT_MOMENT[bossId] or "entrance"
local s = A.build({ swarm = false })
local c = s.centre
local hero = Vector3.new(c.X, c.Y, c.Z)
local bossAt = Vector3.new(c.X - 26, c.Y, c.Z + 2)
local function at(dx, dz)
	return Vector3.new(c.X + dx, c.Y, c.Z + dz)
end
local BossData = C.shared("BossData")
local data = BossData and BossData.Get(bossId)
local typeOf = { ScorpionQueen = "Boss", MothMatriarch = "MothBoss", RhinoWarlord = "RhinoBoss", HiveMother = "HiveBoss", BriarSentinel = "BriarBoss", FrostboundColossus = "FrostBoss", BasinBreaker = "BasinBoss" }
local bossType = typeOf[bossId] or "Boss"
local radius = ({ Boss = 6, MothBoss = 5, RhinoBoss = 6, HiveBoss = 5.5, BriarBoss = 5.5, FrostBoss = 6, BasinBoss = 6 })[bossType]
local phase2 = moment == "stunned" or moment == "gust" or moment == "trails" or moment == "collapse" or moment == "closing" or moment == "armor"
local hpShare = moment == "collapse" and 0 or (phase2 and 0.42 or 0.78)
C.setState({ BossMaxHP = 2700, BossHP = math.floor(2700 * hpShare), BossName = data and data.DisplayName or "Scorpion Queen", BossId = bossId, BossIntro = moment == "entrance" and 2.5 or 0.05, BossPhaseAt = hpShare < 0.5 and 0 or 0.5, BossPhase = hpShare < 0.5 and 2 or 1, StagePhase = "Boss", Stage = bossId == "ScorpionQueen" and 1 or 3 })
for i, off in ipairs({ { -30, 8 }, { 26, 12 }, { -22, -18 }, { 34, -4 } }) do
	E.enemy(s, i % 2 == 0 and "Skeleton" or "Slime", at(off[1], off[2]), hero)
end

local acts = {
	ScorpionQueen = { entrance = "Emerge", charge = "Windup", venom = "Claws", ring = "TailRaise", burrow = "Burrow", summon = "Summon", stunned = "Stunned", collapse = "Collapse" },
	MothMatriarch = { entrance = "Emerge", storm = "Gather", dive = "Lift", mines = "Gather", summon = "Summon", gust = "GustWindup", grounded = "Grounded", collapse = "Collapse" },
	RhinoWarlord = { entrance = "Emerge", charge = "Windup", stuck = "Stuck", pound = "Pound", summon = "Summon", collapse = "Collapse" },
	HiveMother = { entrance = "Emerge", eggs = "Heave", pools = "Spew", trails = "Spew", brood = "Summon", collapse = "Collapse" },
	BriarSentinel = { entrance = "Emerge", roots = "Root", erupt = "Rooted", volley = "Volley", bramble = "Root", closing = "Rooted", summon = "Summon", collapse = "Collapse" },
	FrostboundColossus = { entrance = "Emerge", slam = "SlamWindup", wave = "Slam", lanes = "Stomp", spikes = "Stomp", breath = "Inhale", shards = "ShardCall", stunned = "Stunned", collapse = "Collapse" },
	BasinBreaker = { entrance = "Emerge", slam = "SlamWindup", charge = "Windup", sap = "Spew", stuck = "Stuck", collapse = "Collapse" },
}
local bossBody = E.enemy(s, bossType, bossAt, hero, { Act = (acts[bossId] or {})[moment] })
if bossBody and bossId == "FrostboundColossus" and moment == "armor" then
	bossBody:SetAttribute("FrostArmor", true)
end
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
elseif bossId == "BriarSentinel" then
	local A2 = data.Attacks
	local d = (hero - bossAt).Unit
	local function rootLanes(seconds)
		local R = A2.RootLines
		local out = {}
		local base = math.atan2(d.Z, d.X)
		for _, off in ipairs({ 0, 0.75, -0.8 }) do
			local a = base + off
			local dir = Vector3.new(math.cos(a), 0, math.sin(a))
			local from = bossAt + dir * (radius * 0.5)
			local mid = from + dir * (R.Length / 2)
			table.insert(out, { "lane", mid.X, mid.Z, math.atan2(-dir.X, -dir.Z), R.Length, R.Width, seconds })
		end
		return out
	end
	if moment == "entrance" then
		warns = { { "pop", bossAt.X, bossAt.Z, 18, "dust" }, { "circle", bossAt.X, bossAt.Z, radius + 2, 2.5, "burrow" } }
		wait = 1.3
	elseif moment == "roots" then
		warns = rootLanes(A2.RootLines.Windup)
		wait = 0.7
	elseif moment == "erupt" then
		-- the lanes have filled; thorns burst along them, running away from her
		warns = rootLanes(0.25)
		local base = math.atan2(d.Z, d.X)
		for _, off in ipairs({ 0, 0.75, -0.8 }) do
			local dir = Vector3.new(math.cos(base + off), 0, math.sin(base + off))
			for k = 0, 4 do
				local p = bossAt + dir * (radius * 0.5 + 2.2 + k * 7)
				table.insert(warns, { "pop", p.X, p.Z, 2.8, "thorn" })
			end
		end
		wait = 0.3
	elseif moment == "volley" then
		local V = A2.ThornVolley
		local mid = math.atan2(d.Z, d.X)
		local angles = {}
		for i = 0, V.Count - 1 do
			table.insert(angles, mid - math.rad(V.Spread) / 2 + math.rad(V.Spread) * i / (V.Count - 1))
		end
		warns = { { "spokes", bossAt.X, bossAt.Z, radius + 0.5, 22, 1.8, angles } }
		wait = 0.6
	elseif moment == "bramble" or moment == "closing" then
		local B = A2.BrambleRing
		-- the gap opens toward the hero's lower side, so the way out is on screen
		local gap = math.atan2(hero.Z - 6 - bossAt.Z, hero.X - bossAt.X)
		warns = { { "bramble", bossAt.X, bossAt.Z, B.StartRadius, B.Windup, B.Speed, radius + 1.5, B.Width, gap, math.rad(B.GapHalf) } }
		wait = moment == "closing" and (B.Windup + 1.1) or 0.7
	elseif moment == "summon" then
		for i = 1, 4 do
			local a = i * math.pi * 2 / 4 + 0.3
			table.insert(warns, { "emerge", bossAt.X + math.cos(a) * 13, bossAt.Z + math.sin(a) * 13, 1.1 })
		end
		for _, off in ipairs({ { -14, 6 }, { -8, -10 } }) do
			E.enemy(s, "ThornSprout", at(off[1], off[2]), hero)
		end
		wait = 0.7
	elseif moment == "collapse" then
		warns = { { "pop", bossAt.X, bossAt.Z, 12, "dust" } }
		wait = 0.8
	end
elseif bossId == "FrostboundColossus" then
	local A2 = data.Attacks
	local d = (hero - bossAt).Unit
	local right = Vector3.new(-d.Z, 0, d.X)
	local function lanes(seconds)
		local L = A2.IceLanes
		local out = {}
		local s0 = (hero - bossAt):Dot(right)
		for k = 1, L.Lanes do
			local off = s0 + (k - 2) * L.Spacing
			local from = bossAt + right * off - d * 4
			local mid = from + d * (L.Length / 2)
			table.insert(out, { "lane", mid.X, mid.Z, math.atan2(-d.X, -d.Z), L.Length, L.Width, seconds })
		end
		return out
	end
	if moment == "entrance" then
		warns = { { "pop", bossAt.X, bossAt.Z, 22, "dust" }, { "circle", bossAt.X, bossAt.Z, radius + 2, 2.5, "burrow" } }
		wait = 1.3
	elseif moment == "slam" or moment == "wave" then
		local W = A2.GroundSlam
		local gap = math.atan2(hero.Z - 8 - bossAt.Z, hero.X - bossAt.X)
		warns = { { "wave", bossAt.X, bossAt.Z, radius * 0.8, W.Windup, W.Speed, W.MaxRadius, W.Width, gap, math.rad(W.GapHalf) } }
		if moment == "wave" then
			table.insert(warns, { "pop", bossAt.X, bossAt.Z, radius * 1.6, "frost" })
		end
		wait = moment == "wave" and (W.Windup + 1.0) or 0.6
	elseif moment == "lanes" then
		warns = lanes(A2.IceLanes.Windup)
		wait = 0.7
	elseif moment == "spikes" then
		warns = lanes(0.2)
		local s0 = (hero - bossAt):Dot(right)
		for k = 1, A2.IceLanes.Lanes do
			local from = bossAt + right * (s0 + (k - 2) * A2.IceLanes.Spacing) - d * 4
			for j = 0, 5 do
				local p = from + d * (2.2 + j * 7)
				table.insert(warns, { "pop", p.X, p.Z, 2.8, "ice" })
			end
		end
		wait = 0.3
	elseif moment == "breath" then
		local B = A2.FrostBreath
		warns = { { "gust", bossAt.X, bossAt.Z, math.atan2(d.Z, d.X), B.Length, math.rad(B.HalfAngle), B.Windup, B.Breath, "frost" } }
		wait = 0.7
	elseif moment == "shards" then
		local S = A2.ShardRain
		for i, off in ipairs({ { 1, 0 }, { -8, 6 }, { 9, 5 }, { -4, -9 }, { 10, -7 }, { -12, -2 } }) do
			table.insert(warns, { "circle", hero.X + off[1], hero.Z + off[2], S.Radius, S.Fall + (i - 1) * S.Stagger, "frost" })
		end
		wait = 0.8
	elseif moment == "armor" then
		warns = { { "pop", bossAt.X, bossAt.Z, radius * 1.4, "frost" } }
		C.fire("Notify", { Text = "THE COLOSSUS GROWS FROST ARMOUR! Break it!", Color = Color3.fromRGB(255, 90, 80) })
		wait = 0.3
	elseif moment == "stunned" then
		warns = { { "pop", bossAt.X, bossAt.Z, radius * 1.8, "frost" } }
		C.fire("Notify", { Text = "FROST ARMOUR SHATTERED!", Color = Color3.fromRGB(190, 225, 255) })
		wait = 0.3
	elseif moment == "collapse" then
		warns = { { "pop", bossAt.X, bossAt.Z, 13, "dust" } }
		wait = 0.8
	end
elseif bossId == "BasinBreaker" then
	local A2 = data.Attacks
	if moment == "entrance" then
		warns = { { "pop", bossAt.X, bossAt.Z, 20, "dust" }, { "circle", bossAt.X, bossAt.Z, 8, 2.5, "burrow" } }
		wait = 1.3
	elseif moment == "slam" then
		warns = { { "circle", bossAt.X, bossAt.Z, A2.RootSlam.Radius, A2.RootSlam.Windup, "burrow" } }
		wait = 0.7
	elseif moment == "charge" then
		local reach = radius + 1.2
		local Ch = A2.BreakerCharge
		warns = { laneTo(Ch.Speed * Ch.Duration + reach, reach * 2, Ch.Windup) }
		wait = 0.9
	elseif moment == "sap" then
		local S = A2.SapCircles
		warns = { { "circle", hero.X + 0.5, hero.Z, S.Radius, S.Warn, "acid" } }
		wait = 0.6
	elseif moment == "stuck" then
		warns = { { "pop", bossAt.X + 4, bossAt.Z, 6, "slam" } }
		wait = 0.3
	elseif moment == "collapse" then
		warns = { { "pop", bossAt.X, bossAt.Z, 13, "dust" } }
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
