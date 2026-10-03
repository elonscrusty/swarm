-- levelrate-sim: how fast do XP bars fill? Boots the REAL server (spawner, weapons, gems,
-- shared XP) with N players walking circles near the spawn and reports every player's
-- level each minute plus level-ups per minute, solo vs duo vs trio. Level-up offers are
-- auto-picked at once (the deadline is forced), so the run never pauses. Run it with
-- render.sh levelrate-sim --devices pc --set players=2 --set seconds=240   (no --studio: the Duo / Trio
-- ticket is a reserved-server join, which only counts outside Studio; solo works either way)
--   --set players=1|2|3   run size (2 and 3 start a Duo / Trio run through a reserved-server ticket)
--   --set seconds=240     simulated seconds
--   --set share=0.6       overrides Config.XP.CoopShare[players] (what-if; the real value by default)
local Players = game:GetService("Players")
local me = Players.LocalPlayer
local n = math.clamp(tonumber(preview.args.players) or 1, 1, 3)
local seconds = tonumber(preview.args.seconds) or 240
local extras = {}
for i = 2, n do
	table.insert(extras, preview.addPlayer("Mate" .. i, i))
end
if n > 1 then
	local T = preview.teleport()
	T.placeId, T.privateServerId, T.privateServerOwnerId = 4242, "ps-levelrate", 0
	local members = { 1 }
	for i = 2, n do
		table.insert(members, i)
	end
	local ticket = { SwarmRun = { V = 1, Mode = n == 2 and "Duo" or "Trio", Members = members, Starter = 1, Arena = "Forest" } }
	for i = 1, n do
		T.joinData[i] = ticket
	end
end
local Config = preview.shared("Config")
if preview.args.share then
	Config.XP.CoopShare[n] = tonumber(preview.args.share)
end
preview.startServer()
preview.advance(2)
local RM = preview.server("RunManager")
local LU = preview.server("LevelUpSystem")
local Spawner = preview.server("EnemySpawner")
if n == 1 then
	preview.remote("StartRun"):FireServer("Solo")
	preview.advance(1.5)
end
local rps = RM.GetRunPlayers()
assert(#rps == n, "expected " .. n .. " run players, got " .. #rps)
for _, rp in ipairs(rps) do
	rp.InvulnUntil = math.huge
end
preview.log(string.format("players=%d share=%.2f PlayerCountMult=%.2f XPNeeded(1..5)=%d %d %d %d %d", n,
	Config.XP.CoopShare and Config.XP.CoopShare[n] or 1, Config.Difficulty.PlayerCountMult[n],
	preview.server("XPSystem").XPNeeded(1), preview.server("XPSystem").XPNeeded(2), preview.server("XPSystem").XPNeeded(3),
	preview.server("XPSystem").XPNeeded(4), preview.server("XPSystem").XPNeeded(5)))

-- every hero walks a 24-stud circle around the spawn at ~5 studs/s (slow enough for the swarm to reach them), spaced out
local c = Config.ArenaOrigin
local angle = 0
local function move(dt)
	angle += dt * 5 / 24
	for i, rp in ipairs(rps) do
		local root = rp.Root
		if root then
			local a = angle + (i - 1) * (2 * math.pi / n)
			local pos = Vector3.new(c.X + math.cos(a) * 24, root.Position.Y, c.Z + math.sin(a) * 24)
			local dir = Vector3.new(-math.sin(a), 0, math.cos(a))
			rp.MoveDir = dir
			rp.Facing = dir
			root.CFrame = CFrame.lookAt(pos, pos + dir)
			rp.LastValidPos = root.Position
			rp.SpeedCheckTimer = 0
		end
	end
end
local function autoPick()
	for _, rp in ipairs(rps) do
		if rp.Offer then
			rp.OfferDeadline = 0 -- LevelUpSystem.Step auto-picks a card at once
		end
	end
end
local levelUps = {}
local prevLevel = {}
for i, rp in ipairs(rps) do
	levelUps[i], prevLevel[i] = 0, rp.Level
end
local t, nextReport = 0, 60
local perMinute = {}
while t < seconds do
	local dt = 0.25
	preview.advance(dt)
	t += dt
	move(dt)
	autoPick()
	for i, rp in ipairs(rps) do
		if rp.Level > prevLevel[i] then
			levelUps[i] += rp.Level - prevLevel[i]
			prevLevel[i] = rp.Level
		end
	end
	if t >= nextReport - 1e-6 then
		local parts = {}
		local sum = 0
		for i, rp in ipairs(rps) do
			table.insert(parts, string.format("P%d L%d", i, rp.Level))
			sum += levelUps[i]
		end
		local near, risen = math.huge, 0
		for _, e in ipairs(Spawner.Active) do
			if e.Alive and e.Pos and rps[1].Root then
				near = math.min(near, (e.Pos - rps[1].Root.Position).Magnitude)
			end
		end
		preview.log(string.format("        debug: nearest enemy %.1f studs, weapons %s, HP %s", near, table.concat(rps[1].WeaponOrder, "+"), tostring(rps[1].HP)))
		local rate = sum / n / (t / 60)
		table.insert(perMinute, rate)
		preview.log(string.format("%3d:00  %s | kills=%d enemies=%d | level-ups so far %d (avg %.2f per player) = %.2f per player-minute",
			math.floor(t / 60), table.concat(parts, "  "), me:GetAttribute("Kills") or 0, #Spawner.Active, sum, sum / n, rate))
		nextReport += 60
	end
end
local sum = 0
for i in ipairs(rps) do
	sum += levelUps[i]
end
preview.log(string.format("RESULT players=%d minutes=%.1f level-ups per player %.1f -> %.2f per player-minute (upgrade panels on this server: %d)",
	n, t / 60, sum / n, sum / n / (t / 60), sum))
