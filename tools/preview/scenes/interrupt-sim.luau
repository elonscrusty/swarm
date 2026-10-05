-- interrupt-sim (audit 2026-10-05, docs/audit/JOURNEY.md): how often is a representative
-- run interrupted, and for how long can the player not play? Boots the REAL server (no
-- client UI) and plays `stages` stages like a steady player: walks a circle near the
-- centre for `explore` seconds, detours to a priced chest when the run purse covers it,
-- charges the portal, fights the boss up close (force-killed after `bossmax` s), waits out
-- the surge and answers the stage-clear dialog with NEXT STAGE after `portalthink` s.
-- Cards: the first round of a panel is picked after `think` s, each further round after
-- `thinknext` s (a human-ish pace; set think=0 for the old "auto-pick at once" pacing).
-- A rare (dramatic) reward is closed `reveal` s after it arrives, like the client reel
-- (spin 1.3 + reveal 1.3 by default). The hero is invulnerable (InvulnUntil) so every run
-- reaches the same stages: an assumption that keeps the measurement comparable.
-- Reports per stage and in total: level-up panels and rounds, reward reveals and compact
-- rewards, stage-clear dialogs, travel holds, seconds the player could not move by cause
-- (choice / reward / stage clear / travel), blocking interruptions per minute, and the
-- headline / notice broadcasts the server sent (non-blocking interruptions).
--   lune run tools/preview/runtime/main.luau -- --scene interrupt-sim --studio --device pc
--     --out <json> --set headless=on [--set stages=3 --set explore=150 --set think=2]
--   --set players=2 (Duo through RunManager.StartTeamRun; the mate picks at the same pace)
local Players = game:GetService("Players")
local me = Players.LocalPlayer
local n = math.clamp(tonumber(preview.args.players) or 1, 1, 2)
local stages = tonumber(preview.args.stages) or 3
local explore = tonumber(preview.args.explore) or 150
local bossMax = tonumber(preview.args.bossmax) or 90
local think = tonumber(preview.args.think) or 2
local thinkNext = tonumber(preview.args.thinknext) or 1.2
local portalThink = tonumber(preview.args.portalthink) or 2.5
local revealT = tonumber(preview.args.reveal) or 2.6
local mates = {}
for i = 2, n do
	table.insert(mates, preview.addPlayer("Mate" .. i, i))
end
local Config = preview.shared("Config")
preview.startServer()
preview.advance(2)
local RM = preview.server("RunManager")
local SM = preview.server("StageManager")
local Spawner = preview.server("EnemySpawner")
local Loot = preview.server("LootSystem")
local Gold = preview.server("GoldSystem")

-- server broadcasts / notices (headline = big)
local headlines, notices = 0, 0
local rawBroadcast = RM.Broadcast
RM.Broadcast = function(text, color, big, meta, ...)
	if big or (type(meta) == "table" and meta.Lane == "Headline") then
		headlines += 1
	else
		notices += 1
	end
	return rawBroadcast(text, color, big, meta, ...)
end
local rawNotify = RM.Notify
RM.Notify = function(player, ...)
	if player == me then
		notices += 1
	end
	return rawNotify(player, ...)
end

if n == 1 then
	preview.remote("StartRun"):FireServer("Solo")
	preview.advance(1.5)
else
	assert(RM.StartTeamRun({ me, table.unpack(mates) }, "Duo", "Forest", me))
	preview.advance(6)
end
local rps = table.clone(RM.GetRunPlayers())
assert(#rps == n, "expected " .. n .. " run players, got " .. #rps)

-- rewards: dramatic (held) vs compact, counted from the server's own HoldReward
local reveals, compacts = 0, 0
local closeAt: { [any]: number } = {}
local rawHold = RM.HoldReward
RM.HoldReward = function(rp, dramatic, ...)
	if rp == rps[1] then
		if dramatic then
			reveals += 1
			closeAt[rp] = closeAt[rp] or (os.clock() + revealT)
		else
			compacts += 1
		end
	end
	return rawHold(rp, dramatic, ...)
end

local t = 0
local centre = Config.ArenaOrigin
local radius = 24
local angle = 0
-- per player: when the current round appeared
local roundSeen: { [any]: any } = {}
local panels, rounds, portalDialogs, travels = 0, 0, 0, 0
local lastPanel = nil
local blocked = { Choice = 0, Reward = 0, Portal = 0, Travel = 0, Frozen = 0 }
local blockStarts = 0
local wasBlocked = false
local longest, cur = 0, 0
local portalSeenAt = nil
local wasTravel = false
local travelEnd = nil
local afterTravel = {}
-- per stage summary
local stageRow = {}
local function row(s)
	stageRow[s] = stageRow[s] or { Panels = 0, Rounds = 0, Reveals = 0, Compacts = 0, Blocked = 0, Secs = 0, Starts = 0 }
	return stageRow[s]
end

local function move(dt)
	angle += dt * 5 / 24
	for i, rp in ipairs(rps) do
		local root = rp.Root
		rp.InvulnUntil = math.huge
		if root and rp.Alive and not rp.Paused and not root.Anchored then
			local a = angle + (i - 1) * math.pi
			local pos = Vector3.new(centre.X + math.cos(a) * radius, root.Position.Y, centre.Z + math.sin(a) * radius)
			local dir = Vector3.new(-math.sin(a), 0, math.cos(a))
			rp.MoveDir, rp.Facing = dir, dir
			root.CFrame = CFrame.lookAt(pos, pos + dir)
			rp.LastValidPos, rp.SpeedCheckTimer = root.Position, 0
		end
	end
end

local function answer(rp)
	if rp.Offer and rp.Paused then
		local seen = roundSeen[rp]
		if not seen or seen.Id ~= rp.OfferSeq then
			local first = rp.PanelId ~= (seen and seen.Panel)
			roundSeen[rp] = { Id = rp.OfferSeq, Panel = rp.PanelId, At = t, Wait = first and think or thinkNext }
			if rp == rps[1] and first then
				panels += 1
				row(SM.GetStage()).Panels += 1
			end
			seen = roundSeen[rp]
		end
		if t - seen.At >= seen.Wait then
			if rp == rps[1] then
				rounds += 1
				row(SM.GetStage()).Rounds += 1
			end
			preview.fireServerAs(rp.Player, "LevelUpChoose", 1, rp.OfferSeq)
		end
	end
	if closeAt[rp] and os.clock() >= closeAt[rp] then
		closeAt[rp] = nil
		preview.fireServerAs(rp.Player, "RewardClose", rp.RewardSeq or 0)
	end
	if not rp.RewardUntil and closeAt[rp] == nil then
		-- nothing open
	end
end

local function tick(dt)
	preview.advance(dt)
	t += dt
	move(dt)
	for _, rp in ipairs(rps) do
		answer(rp)
	end
	local rp = rps[1]
	local holding = SM.IsHolding()
	local cause = nil
	if holding then
		cause = "Travel"
	elseif rp.Paused and rp.Offer then
		cause = "Choice"
	elseif rp.RewardUntil then
		cause = "Reward"
	elseif rp.PortalOffered and not rp.PortalChoice then
		cause = "Portal"
	elseif RM.IsFrozen() then
		cause = "Frozen" -- someone else's choice / reward froze the world
	end
	local r = row(SM.GetStage())
	r.Secs += dt
	if cause then
		blocked[cause] += dt
		r.Blocked += dt
		cur += dt
		if not wasBlocked then
			blockStarts += 1
			r.Starts += 1
		end
	else
		longest = math.max(longest, cur)
		cur = 0
	end
	wasBlocked = cause ~= nil
	if holding and not wasTravel then
		travels += 1
	end
	if wasTravel and not holding then
		travelEnd = t
	end
	if travelEnd and rp.Offer and rp.Paused then
		table.insert(afterTravel, string.format("%.1f", t - travelEnd))
		travelEnd = nil
	elseif travelEnd and t - travelEnd > 15 then
		table.insert(afterTravel, "none")
		travelEnd = nil
	end
	wasTravel = holding
	if rp.PortalOffered and not portalSeenAt then
		portalSeenAt = t
		portalDialogs += 1
	end
	if portalSeenAt and not rp.PortalChoice and t - portalSeenAt >= portalThink and SM.GetPhase() == "Open" then
		for _, p in ipairs(rps) do
			if p.Alive and not p.PortalChoice and p.PortalOffered then
				preview.fireServerAs(p.Player, "PortalChoice", "Next")
			end
		end
	end
	if SM.GetPhase() ~= "Open" then
		portalSeenAt = nil
	end
end

-- a detour to a chest the purse covers (once every 20 s at most)
local nextChest = 20
local function tryChest()
	if t < nextChest then
		return
	end
	nextChest = t + 20
	local rp = rps[1]
	if rp.Paused or rp.RewardUntil or not rp.Alive or SM.GetPhase() ~= "Explore" then
		return
	end
	local best = nil
	for _, obj in ipairs(Loot.Objects()) do
		if obj.Kind == "Chest" and obj.State == "Ready" then
			local price = obj.Model:GetAttribute("Price") or 0
			if price <= Gold.RunWallet(rp) and (best == nil or price < best.P) then
				best = { O = obj, P = price }
			end
		end
	end
	if not best then
		if preview.args.debug == "on" then
			local c, minP = 0, math.huge
			for _, obj in ipairs(Loot.Objects()) do
				if obj.Kind == "Chest" and obj.State == "Ready" then
					c += 1
					minP = math.min(minP, obj.Model:GetAttribute("Price") or 0)
				end
			end
			preview.log(string.format("chest t=%.0f ready %d min price %s wallet %d gold %d", t, c, tostring(minP), Gold.RunWallet(rp), rp.Gold))
		end
		return
	end
	local obj = best.O
	local root = rp.Root
	root.CFrame = CFrame.new(obj.Pos + Vector3.new(2, 3, 0))
	rp.LastValidPos, rp.SpeedCheckTimer = root.Position, 0
	tick(0.1)
	preview.fireServerAs(rp.Player, "LootHold", obj.Id, true)
	local hold = (obj.Model:GetAttribute("Hold") or 0.4) + 0.2
	local h0 = t
	while t - h0 < hold do
		local root2 = rp.Root
		root2.CFrame = CFrame.new(obj.Pos + Vector3.new(2, 3, 0))
		rp.LastValidPos, rp.SpeedCheckTimer = root2.Position, 0
		preview.advance(0.1)
		t += 0.1
	end
	preview.fireServerAs(rp.Player, "LootHold", obj.Id, false)
end

local startT = t
for s = 1, stages do
	centre, radius = Config.ArenaOrigin, 24
	local e0 = t
	while t - e0 < explore do
		tick(0.25)
		tryChest()
	end
	local p = SM.PortalPosition()
	if p then
		centre = p
	end
	radius = 2
	local c0 = t
	while not SM.IsBossFight() and t - c0 < 40 and SM.GetStage() == s do
		tick(0.25)
	end
	radius = 24
	if not SM.IsBossFight() and SM.GetStage() == s then
		SM.DevActivate()
	end
	local b0 = t
	local killed = false
	while SM.GetStage() == s and RM.IsRunning() and t - b0 < bossMax + 120 do
		local boss = Spawner.Boss
		if boss and boss.Alive then
			centre, radius = boss.Pos, 12
		end
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
	-- let the new stage settle (the panel that waited for the travel)
	for _ = 1, 40 do
		tick(0.25)
	end
	local r = row(s)
	preview.log(string.format("STAGE %d: %.0fs, panels %d rounds %d, blocked %.1fs in %d stretches%s",
		s, r.Secs, r.Panels, r.Rounds, r.Blocked, r.Starts, SM.GetStage() == s and " (did not advance)" or ""))
	if SM.GetStage() == s or not RM.IsRunning() then
		break
	end
end
longest = math.max(longest, cur)
local total = t - startT
local blockedTotal = blocked.Choice + blocked.Reward + blocked.Portal + blocked.Travel + blocked.Frozen
preview.log(string.format("RUN %s %.0fs simulated (%.1f min), level %d, think %.1f/%.1f s, reveal %.1f s",
	n == 1 and "Solo" or "Duo", total, total / 60, rps[1].Level, think, thinkNext, revealT))
preview.log(string.format("PANELS %d (rounds %d, %.2f rounds/panel), REVEALS %d, COMPACT REWARDS %d, STAGE-CLEAR DIALOGS %d, TRAVELS %d",
	panels, rounds, rounds / math.max(1, panels), reveals, compacts, portalDialogs, travels))
preview.log(string.format("UNABLE TO PLAY %.1fs = %.1f%% of the run: choice %.1f, reward %.1f, stage clear %.1f, travel %.1f, frozen by a mate %.1f",
	blockedTotal, blockedTotal / total * 100, blocked.Choice, blocked.Reward, blocked.Portal, blocked.Travel, blocked.Frozen))
preview.log(string.format("BLOCKING INTERRUPTIONS %d (%.2f per minute), longest %.1fs; HEADLINES %d, NOTICES %d (%.2f per minute)",
	blockStarts, blockStarts / (total / 60), longest, headlines, notices, (headlines + notices) / (total / 60)))
preview.log("FIRST PANEL AFTER EACH TRAVEL (s after the fade): " .. (#afterTravel > 0 and table.concat(afterTravel, ", ") or "-"))
