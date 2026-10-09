-- xp-sim: boots the REAL server, starts a solo run and drops XP gems (clustered, so they
-- merge, plus a spread-out batch), then pulls them in with the Magnet pickup and prints the
-- gem count before / after merging and whether every point of XP reached the hero. Also
-- checks the pool-exhausted path. Run it with --studio:
--   render.sh xp-sim --studio --devices pc
-- Redesign economy (RunConfig.Economy on): an unowned drop becomes the hero's personal shard
-- (XPSystem.Award, within ShareRadius 120 studs), collected through GiveShardXP; the drops stay
-- inside that radius and both grant paths are counted.
local C = lib("common")
local Players = game:GetService("Players")
preview.forceMeshesUploaded()
preview.startServer()
preview.advance(1)
C.startClient()
preview.advance(1)
local me = Players.LocalPlayer
local RM = preview.server("RunManager")
local XP = preview.server("XPSystem")
local Config = C.shared("Config")
preview.remote("StartRun"):FireServer("Solo")
preview.advance(1.5)
local rp = RM.GetRunPlayer(me)
if rp then
	rp.InvulnUntil = math.huge
end
local given = 0
local orig = XP.GiveSharedXP
XP.GiveSharedXP = function(amount)
	given += amount
	return orig(amount)
end
local origShard = XP.GiveShardXP -- the personal shard path (redesign economy)
if origShard then
	XP.GiveShardXP = function(who, amount)
		given += amount
		return origShard(who, amount)
	end
end
local poolSize = #workspace:WaitForChild("SwarmGems"):GetChildren()
local gemsFolder = workspace:WaitForChild("SwarmGems")
local function active()
	local n = 0
	for _, g in ipairs(gemsFolder:GetChildren()) do
		if g:GetAttribute("Active") then
			n += 1
		end
	end
	return n
end
local origin = rp and rp.Root and rp.Root.Position or Vector3.zero
local rng = Random.new(7)
local total, spawned = 0, 0
local function drop(x, z, v)
	XP.SpawnGem(Vector3.new(x, origin.Y, z), v)
	total += v
	spawned += 1
end
-- 300 small gems in 6 piles of 50 within 1.5 studs, 120 mixed gems spread over the arena
for p = 1, 6 do
	local cx, cz = origin.X + rng:NextNumber(-60, 60), origin.Z + rng:NextNumber(-60, 60) -- (inside the 120-stud share radius)
	for _ = 1, 50 do
		drop(cx + rng:NextNumber(-1.5, 1.5), cz + rng:NextNumber(-1.5, 1.5), Config.XP.GemValues.Small)
	end
end
for _ = 1, 120 do
	local r = rng:NextInteger(1, 10)
	drop(origin.X + rng:NextNumber(-80, 80), origin.Z + rng:NextNumber(-80, 80), r == 10 and Config.XP.GemValues.Large or (r > 6 and Config.XP.GemValues.Medium or Config.XP.GemValues.Small))
end
preview.log(string.format("dropped %d gems worth %d XP -> %d gem parts active", spawned, total, active()))
-- 600 more tight ones than the pool holds
for _ = 1, 700 do
	drop(origin.X + rng:NextNumber(-80, 80), origin.Z + rng:NextNumber(-80, 80), 1)
end
preview.log(string.format("after the pool test: %d gems dropped, %d XP in all, %d gem parts active (pool %d)", spawned, total, active(), poolSize))
XP.MagnetAll(rp)
for _ = 1, 60 do
	preview.advance(0.5)
	for _ = 1, 20 do
		if not me:GetAttribute("Paused") then
			break
		end
		preview.remote("LevelUpChoose"):FireServer(1, game:GetService("Players").LocalPlayer:GetAttribute("ChoiceOfferId"))
		preview.advance(0.2)
	end
	if active() == 0 then
		break
	end
end
preview.log(string.format("XP given %d of %d dropped, gems left %d -> %s", given, total, active(), (given == total and active() == 0) and "PASS" or "FAIL"))
