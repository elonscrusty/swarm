--[[
	MovementGuard.lua
	Server check for the bunny hop (Config.Movement). The client owns its character and
	raises its local WalkSpeed while chaining hops (JumpController.lua); the server's
	WalkSpeed stays the base speed (RunManager.ApplyMovement). Here, every Heartbeat, a run
	player's horizontal velocity is compared with

	    WalkSpeed * HopSpeedCap * ServerTolerance + ServerAllowance

	and only when it stays above that for ServerGraceSeconds (replication jitter and lag
	spikes pass) is it trimmed back to WalkSpeed * HopSpeedCap. Nobody is kicked or
	snapped back here; RunManager's position check (Config.Player.SpeedCheck*) still
	handles frozen / paused players and teleport-like travel.
]]

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")

local Config = require(game:GetService("ReplicatedStorage"):WaitForChild("Shared"):WaitForChild("Config"))

local MovementGuard = {}

local M = Config.Movement
local overFor: { [Player]: number } = {}

-- The largest horizontal speed a player with this server WalkSpeed may keep.
function MovementGuard.Cap(walkSpeed: number): number
	return walkSpeed * M.HopSpeedCap
end

local function check(player: Player, dt: number)
	if player:GetAttribute("InRun") ~= true then
		overFor[player] = nil
		return
	end
	local char = player.Character
	local hum = char and char:FindFirstChildOfClass("Humanoid")
	local root = char and char:FindFirstChild("HumanoidRootPart") :: BasePart?
	if not hum or not root or root.Anchored then
		overFor[player] = nil
		return
	end
	local walk = hum.WalkSpeed
	if walk <= 0 then
		-- frozen / paused / downed: RunManager's position check owns that case
		overFor[player] = nil
		return
	end
	local v = root.AssemblyLinearVelocity
	local flat = math.sqrt(v.X * v.X + v.Z * v.Z)
	local limit = walk * M.HopSpeedCap * M.ServerTolerance + M.ServerAllowance
	if flat <= limit then
		overFor[player] = math.max(0, (overFor[player] or 0) - dt)
		return
	end
	local t = (overFor[player] or 0) + dt
	if t < M.ServerGraceSeconds then
		overFor[player] = t
		return
	end
	overFor[player] = 0
	local k = MovementGuard.Cap(walk) / flat
	root.AssemblyLinearVelocity = Vector3.new(v.X * k, v.Y, v.Z * k)
end

function MovementGuard.Start(_ctx)
	Players.PlayerRemoving:Connect(function(player)
		overFor[player] = nil
	end)
	RunService.Heartbeat:Connect(function(dt)
		dt = math.min(dt, 0.1)
		for _, player in ipairs(Players:GetPlayers()) do
			local ok, err = pcall(check, player, dt)
			if not ok then
				warn("[MovementGuard] " .. tostring(err))
			end
		end
	end)
end

return MovementGuard
