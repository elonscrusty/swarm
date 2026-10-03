local C = lib("common")
preview.startServer()
preview.advance(1)
local RM = preview.server("RunManager")
local Spawner = preview.server("EnemySpawner")
local Fx = preview.server("Fx")
local player = game:GetService("Players").LocalPlayer
preview.remote("StartRun"):FireServer("Solo")
preview.advance(2)
local rp = assert(RM.GetRunPlayer(player))
rp.InvulnUntil = math.huge
local hits = 0
local origDamage = Spawner.Damage
Spawner.Damage = function(e, amount, r, ...)
	if r == rp then hits += 1 end
	return origDamage(e, amount, r, ...)
end
local swings = {}
local origSlash = Fx.Slash
Fx.Slash = function(pos, yaw, reach, ...)
	local best, bestE = math.huge, nil
	for _, e in ipairs(Spawner.Active) do
		if e.Alive then
			local d = ((e.Pos - pos) * Vector3.new(1,0,1)).Magnitude - e.Radius
			if d < best then best, bestE = d, e end
		end
	end
	table.insert(swings, { t = os.clock(), near = best, hitsBefore = hits, nearId = bestE and bestE.Def.Id, yaw = yaw })
	return origSlash(pos, yaw, reach, ...)
end
local ang = 0
for step = 1, tonumber(preview.args.steps or 600) do
	-- kite in a circle radius 30
	ang += 0.1 * 0.1 * 16 / 30
	if rp.Root then
		local c = rp.Root.Position
		local tgt = Vector3.new(math.cos(ang) * 30, c.Y, math.sin(ang) * 30)
		local dir = (tgt - c) * Vector3.new(1,0,1)
		if dir.Magnitude > 0.2 then
			local np = c + dir.Unit * math.min(dir.Magnitude, 1.6)
			rp.Root.CFrame = CFrame.lookAt(np, np + dir.Unit)
		end
	end
	pcall(function()
		player:GetAttribute("Paused")
		if player:GetAttribute("Paused") then preview.remote("LevelUpChoose"):FireServer(1) end
	end)
	preview.advance(0.1)
end
local zero, close = 0, 0
for i, s in ipairs(swings) do
	local after = (swings[i+1] and swings[i+1].hitsBefore or hits) - s.hitsBefore
	if s.near < 4 then
		close += 1
		if after == 0 then zero += 1; print("MISS", i, string.format("near=%.1f %s", s.near, tostring(s.nearId))) end
	end
end
print("swings", #swings, "close", close, "missed", zero, "kills", rp.Kills, "level", rp.Level)
