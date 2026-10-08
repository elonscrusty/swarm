--!strict
--[[
	SwarmV2/Run/LaunchPads.lua  (ServerScriptService.SwarmV2.Run.LaunchPads)
	Spring launch pads on the map (arena.LaunchPads = { {Pos, Target, Radius, Part} }, built by
	CliffwoodBuilder): a living run player standing on a pad is thrown in an arc to its
	Target (Dash.Launch: the client flies, the speed check allows the arc). Optional
	shortcuts only: every place a pad reaches also has a walking route.
]]

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")

local Dash = require(script.Parent:WaitForChild("Dash"))

local LaunchPads = {}

local PAD_COOLDOWN = 2 -- seconds per player between launches
local EXTRA_APEX = 10 -- studs above the higher end of the arc
local CHECK_EVERY = 0.1

local ctx: any = nil
local last: { [Player]: number } = {}

local function step()
	local arena = ctx.MapBuilder and ctx.MapBuilder.GetArena()
	local pads = arena and arena.LaunchPads
	if not pads or #pads == 0 or not ctx.RunManager.IsRunning() then
		return
	end
	local now = os.clock()
	for _, rp in ipairs(ctx.RunManager.GetRunPlayers()) do
		local root: BasePart? = rp.Root
		if rp.Alive and root and root.Parent and now - (last[rp.Player] or 0) >= PAD_COOLDOWN then
			local p = root.Position
			for _, pad in ipairs(pads) do
				local pos: Vector3 = pad.Pos
				local r: number = pad.Radius or 6
				local dx, dz = p.X - pos.X, p.Z - pos.Z
				if dx * dx + dz * dz <= r * r and math.abs(p.Y - pos.Y) < 6 then
					if Dash.Launch(rp, pos, pad.Target, EXTRA_APEX) then
						last[rp.Player] = now
						if ctx.Fx and ctx.Fx.Ring then
							pcall(ctx.Fx.Ring, pos, r + 2, Color3.fromRGB(120, 230, 255))
						end
					end
					break
				end
			end
		end
	end
end

function LaunchPads.Init(c: any)
	ctx = c
	local acc = 0
	RunService.Heartbeat:Connect(function(dt)
		acc += dt
		if acc < CHECK_EVERY then
			return
		end
		acc = 0
		local ok, err = (pcall :: any)(step)
		if not ok then
			warn("[LaunchPads] " .. tostring(err))
		end
	end)
	Players.PlayerRemoving:Connect(function(p)
		last[p] = nil
	end)
end

return LaunchPads
