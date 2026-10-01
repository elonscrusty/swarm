--[[
	GameServer.server.lua
	Bootstraps SWARM: creates the remotes, initialises every module in dependency order,
	then drives all per-frame systems from ONE Heartbeat connection.

	Frame order: RunManager (timer, deaths) → EnemySpawner (spawns) → EnemyAI (movement,
	contact, grid rebuild) → WeaponSystem (firing, projectiles, sync) → XPSystem (gems,
	pickups) → LevelUpSystem (auto-pick timers) → Fx (effect batch flush).
]]

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Remotes = require(Shared.Remotes)
local Config = require(Shared.Config)

-- Remotes must exist before any module connects to them.
Remotes.Setup()

local Modules = script.Parent:WaitForChild("Modules")

local ctx = {
	Config = Config,
	Remotes = Remotes,
}

-- Dependency order: data first, then world, then gameplay.
local ORDER = {
	"DataService",
	"MonetizationService",
	"GoldSystem",
	"MapBuilder",
	"ModelBuilder",
	"XPSystem",
	"LevelUpSystem",
	"EnemySpawner",
	"EnemyAI",
	"WeaponSystem",
	"RunManager",
}

for _, name in ipairs(ORDER) do
	ctx[name] = require(Modules:WaitForChild(name))
end
ctx.Fx = require(Modules:WaitForChild("Fx"))

for _, name in ipairs(ORDER) do
	local m = ctx[name]
	if m.Init then
		m.Init(ctx)
	end
end
for _, name in ipairs(ORDER) do
	local m = ctx[name]
	if m.Start then
		m.Start(ctx)
	end
end

-- Leaving: commit run stats first, then save + release the profile.
Players.PlayerRemoving:Connect(function(player)
	local ok, err = pcall(ctx.RunManager.OnPlayerRemoving, player)
	if not ok then
		warn("[GameServer] RunManager.OnPlayerRemoving: " .. tostring(err))
	end
	ctx.DataService.ReleasePlayer(player)
end)

ctx.DataService.ShutdownHook = function()
	ctx.RunManager.CommitAll()
end

-- The single server loop.
local STEPS = {
	{ "RunManager", ctx.RunManager.Step },
	{ "EnemySpawner", ctx.EnemySpawner.Step },
	{ "EnemyAI", ctx.EnemyAI.Step },
	{ "WeaponSystem", ctx.WeaponSystem.Step },
	{ "XPSystem", ctx.XPSystem.Step },
	{ "LevelUpSystem", ctx.LevelUpSystem.Step },
	{ "Fx", ctx.Fx.Step },
}
local lastError: { [string]: number } = {}

RunService.Heartbeat:Connect(function(dt)
	dt = math.min(dt, 0.1) -- a long hitch must not teleport everything
	for _, step in ipairs(STEPS) do
		local ok, err = pcall(step[2], dt)
		if not ok then
			-- keep the loop alive, but don't spam the output
			local now = os.clock()
			if now - (lastError[step[1]] or 0) > 5 then
				lastError[step[1]] = now
				warn(string.format("[GameServer] %s.Step error: %s", step[1], tostring(err)))
			end
		end
	end
end)

print(string.format("[SWARM] server ready (v%s)%s", Config.Version, ctx.DataService.IsMemoryOnly() and " - DataStores OFF, progress won't save" or ""))
