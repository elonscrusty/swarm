-- pacing-sim: how even is progression over a whole run? Boots the REAL server, starts a
-- solo run (or Duo / Trio through a reserved-server ticket, like levelrate-sim) and plays
-- `stages` stages: explore `explore` seconds walking a circle, then summon the stage boss
-- at the portal (StageManager.DevActivate, no DEV taint) and fight it there; a boss still
-- alive after `bossmax` seconds is killed through EnemySpawner.Kill (its gems drop as
-- usual). Cards are auto-picked at once. Logs every level-up (run time, stage, phase), the
-- gaps between them (dead stretches > 45 s, bursts of 3+ levels inside 3 s), and per
-- stage: levels, run gold, kills, enemy HP multiplier.
--   lune ... --scene pacing-sim --studio --set stages=6 --set explore=150 --set bossmax=90
--   --set players=2|3 (no --studio)   --set pace=off (no gem XP pacing) --set waves=off (continuous spawning)
local Players = game:GetService("Players")
local me = Players.LocalPlayer
local n = math.clamp(tonumber(preview.args.players) or 1, 1, 3)
local stages = tonumber(preview.args.stages) or 6
local explore = tonumber(preview.args.explore) or 150
local bossMax = tonumber(preview.args.bossmax) or 90
for i = 2, n do
	preview.addPlayer("Mate" .. i, i)
end
if n > 1 then
	local T = preview.teleport()
	T.placeId, T.privateServerId, T.privateServerOwnerId = 4242, "ps-pacing", 0
	local members = {}
	for i = 1, n do
		table.insert(members, i)
	end
	local ticket = { SwarmRun = { V = 1, Mode = n == 2 and "Duo" or "Trio", Members = members, Starter = 1, Arena = "Forest" } }
	for i = 1, n do
		T.joinData[i] = ticket
	end
end
local Config = preview.shared("Config")
-- --set pace=off: the gem XP pacing multipliers off (Config.XP.StageMult / OpeningMult)
if preview.args.waves == "off" then
	Config.Waves.Enabled = false
end
if preview.args.pace == "off" then
	Config.XP.StageMult, Config.XP.OpeningMult = nil, nil
end
preview.startServer()
preview.advance(2)
local RM = preview.server("RunManager")
local SM = preview.server("StageManager")
local Spawner = preview.server("EnemySpawner")
-- gold by source (caller file:line), to see where run gold comes from
local GoldSys = preview.server("GoldSystem")
local goldBy = {}
local rawAdd = GoldSys.AddRunGold
GoldSys.AddRunGold = function(rp, base)
	local paid = rawAdd(rp, base)
	local src, line = debug.info(2, "sl")
	local key = (string.match(tostring(src), "([%w_]+)[\"%]]*$") or tostring(src)) .. ":" .. tostring(line)
	goldBy[key] = (goldBy[key] or 0) + paid
	return paid
end
if n == 1 then
	preview.remote("StartRun"):FireServer("Solo")
	preview.advance(1.5)
end
local rps = table.clone(RM.GetRunPlayers()) -- the live list empties when the run ends
assert(#rps == n, "expected " .. n .. " run players")
for _, rp in ipairs(rps) do
	rp.InvulnUntil = math.huge
end
local centre = Config.ArenaOrigin
local angle = 0
local function move(dt)
	angle += dt * 5 / 24
	for i, rp in ipairs(rps) do
		local root = rp.Root
		if root and rp.Alive then
			local a = angle + (i - 1) * (2 * math.pi / n)
			local pos = Vector3.new(centre.X + math.cos(a) * 24, root.Position.Y, centre.Z + math.sin(a) * 24)
			local dir = Vector3.new(-math.sin(a), 0, math.cos(a))
			rp.MoveDir, rp.Facing = dir, dir
			root.CFrame = CFrame.lookAt(pos, pos + dir)
			rp.LastValidPos, rp.SpeedCheckTimer = root.Position, 0
			rp.InvulnUntil = math.huge
		end
	end
end
local t = 0
-- Wasps ("bees", type Bat) alive in the opening: sampled every second for 6 minutes
local bees, beeNext = {}, 1
local function sampleBees()
	if t < beeNext or beeNext > 360 then
		return
	end
	beeNext += 1
	local c = 0
	for _, e in ipairs(Spawner.Active) do
		if e.Alive and e.Def and e.Def.Id == "Bat" then
			c += 1
		end
	end
	local m = math.floor((beeNext - 2) / 60) + 1
	local b = bees[m] or { Sum = 0, N = 0, Max = 0 }
	b.Sum += c
	b.N += 1
	b.Max = math.max(b.Max, c)
	bees[m] = b
	if beeNext == 361 then
		local parts = {}
		for i = 1, 6 do
			local r = bees[i]
			if r then
				table.insert(parts, string.format("m%d avg %.1f max %d", i, r.Sum / r.N, r.Max))
			end
		end
		preview.log("BEES alive per run minute: " .. table.concat(parts, " | "))
	end
end
local ups = {} -- { T, Stage, Phase, N }
local last = rps[1].Level
local function tick(dt)
	preview.advance(dt)
	t += dt
	move(dt)
	sampleBees()
	for _, rp in ipairs(rps) do
		if rp.Offer then
			rp.OfferDeadline = 0
		end
	end
	local rp = rps[1]
	if not rp then
		return
	end
	if rp.Level > last then
		table.insert(ups, { T = t, Stage = SM.GetStage(), Phase = SM.GetPhase(), N = rp.Level - last })
		preview.log(string.format("UP %d:%02d S%d %s L%d gold=%d", t // 60, t % 60, SM.GetStage(), SM.GetPhase(), rp.Level, rp.Gold))
		last = rp.Level
	end
end
local rows = {}
for s = 1, stages do
	local startT, startLevel, startGold, startKills = t, rps[1].Level, rps[1].Gold, rps[1].Kills
	local hp = SM.EnemyHPMult()
	-- explore
	centre = Config.ArenaOrigin
	local e0 = t
	while t - e0 < explore do
		tick(0.25)
	end
	local exploreLevels = rps[1].Level - startLevel
	-- boss at the portal
	local p = SM.PortalPosition()
	if p then
		centre = p
	end
	SM.DevActivate()
	local b0 = t
	local killed = false
	while SM.GetStage() == s and t - b0 < bossMax + 120 do
		tick(0.25)
		if not killed and SM.IsBossFight() and t - b0 >= bossMax then
			for _, e in ipairs(Spawner.Active) do
				if e.Alive and e.Boss then
					Spawner.Kill(e, rps[1])
					killed = true
				end
			end
		end
	end
	local bossT = t - b0
	-- the next stage's calm start
	table.insert(rows, string.format("stage %d: HPx%.2f  levels %d (explore %d) L%d->L%d  gold +%d  kills +%d  boss+surge+travel %.0fs%s",
		s, hp, rps[1].Level - startLevel, exploreLevels, startLevel, rps[1].Level, rps[1].Gold - startGold,
		rps[1].Kills - startKills, bossT, killed and " (boss force-killed)" or ""))
	preview.log(rows[#rows])
	if SM.GetStage() == s then
		preview.log("stage did not advance; stopping")
		break
	end
end
local gaps, bursts = {}, 0
local prevT = 0
for i, u in ipairs(ups) do
	local gap = u.T - prevT
	if gap > 45 then
		table.insert(gaps, string.format("%.0fs gap before L-up at %d:%02d (stage %d %s)", gap, u.T // 60, u.T % 60, u.Stage, u.Phase))
	end
	local within = u.N
	for j = i + 1, #ups do
		if ups[j].T - u.T <= 3 then within += ups[j].N else break end
	end
	if within >= 3 then bursts += 1 end
	prevT = u.T
end
local events = {}
for _, u in ipairs(ups) do
	table.insert(events, string.format("%d:%02d S%d %s%s", u.T // 60, u.T % 60, u.Stage, string.sub(u.Phase, 1, 2), u.N > 1 and ("x" .. u.N) or ""))
end
preview.log("LEVELUPS " .. table.concat(events, " | "))
for _, r in ipairs(rows) do
	preview.log(r)
end
for _, g in ipairs(gaps) do
	preview.log("GAP " .. g)
end
do
	local keys = {}
	for k in pairs(goldBy) do table.insert(keys, k) end
	table.sort(keys, function(x, y) return goldBy[x] > goldBy[y] end)
	local parts = {}
	for _, k in ipairs(keys) do table.insert(parts, k .. "=" .. goldBy[k]) end
	preview.log("GOLD BY SOURCE " .. table.concat(parts, " "))
end
preview.log(string.format("RESULT players=%d time=%.0fs level=%d gold=%d gaps>45s=%d bursts(3+ in 3s)=%d", n, t, rps[1].Level, rps[1].Gold, #gaps, bursts))
