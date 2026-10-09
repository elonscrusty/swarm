--!strict
--[[
	SwarmV2/Run/LaunchPads.lua  (ServerScriptService.SwarmV2.Run.LaunchPads)
	Spring launch pads on the map (arena.LaunchPads = { {Pos, Target, Radius, Part} }, built by
	CliffwoodBuilder): a living run player standing on a pad is thrown in an arc to its
	Target (Dash.Launch: the client flies, the speed check allows the arc). Optional
	shortcuts only: every place a pad reaches also has a walking route.

	The arc's height comes from the ground under it (HeightGrid): the lowest apex (at least
	EXTRA_APEX over the higher end) whose path keeps CLEARANCE studs over every cliff or rock
	between the pad and its Target, worked out once per pad. Without a height grid the arc is
	the plain EXTRA_APEX one.
]]

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")

local Dash = require(script.Parent:WaitForChild("Dash"))
local HeightGrid = require(game:GetService("ServerScriptService"):WaitForChild("Modules"):WaitForChild("HeightGrid"))

local LaunchPads = {}

local PAD_COOLDOWN = 2 -- seconds per player between launches
local EXTRA_APEX = 10 -- studs above the higher end of the arc
local CLEARANCE = 8 -- studs the arc keeps over the ground between the pad and its target
local MAX_EXTRA = 160 -- the highest arc a pad may use
local CHECK_EVERY = 0.1

local ctx: any = nil
local last: { [Player]: number } = {}
local apexCache: { [any]: number } = setmetatable({}, { __mode = "k" }) :: any

--[[
	The extra apex (Dash.Launch's extraApex) for an arc from `from` to `target` that clears the
	ground in between, and whether it does. Ground no higher than the higher end (+1) is the
	pad's own floor or the landing terrace and is not checked. groundY(x, z) gives the ground.
]]
function LaunchPads.ApexFor(from: Vector3, target: Vector3, groundY: (number, number) -> number): (number, boolean)
	local g = workspace.Gravity
	local rise = math.max(0, target.Y - from.Y)
	local rim = math.max(from.Y, target.Y) + 1
	local extra = EXTRA_APEX
	while extra <= MAX_EXTRA do
		local apex = rise + math.max(4, extra)
		local vy = math.sqrt(2 * g * apex)
		local duration = vy / g + math.sqrt(2 * (apex - rise) / g)
		local clear = true
		for k = 1, 63 do
			local f = k / 64
			local p = from:Lerp(target, f)
			local ground = groundY(p.X, p.Z)
			if ground > rim then
				local t = duration * f
				if from.Y + vy * t - g * t * t / 2 < ground + CLEARANCE then
					clear = false
					break
				end
			end
		end
		if clear then
			return extra, true
		end
		extra += 4
	end
	return MAX_EXTRA, false
end

local function apexFor(pad: any): number
	local cached = apexCache[pad]
	if cached then
		return cached
	end
	local extra = EXTRA_APEX
	if HeightGrid.IsActive() then
		local ok
		extra, ok = LaunchPads.ApexFor(pad.Pos, pad.Target, HeightGrid.GroundY)
		if not ok then
			warn(string.format("[LaunchPads] the pad at (%.0f, %.0f) cannot arc over the ground to its target", pad.Pos.X, pad.Pos.Z))
		end
	end
	apexCache[pad] = extra
	return extra
end

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
					if Dash.Launch(rp, pos, pad.Target, apexFor(pad)) then
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
