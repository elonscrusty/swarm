-- temp (parts pass): arena look at the run camera angle, no enemies. --set arena=X --set at=x,z
local C = lib("common")
local s = C.bootServer()
local arena = s.MapBuilder.BuildArena(preview.args.arena or "Forest")
local c = arena.Center
local x, z = 0, 0
if preview.args.at then
	local a, b = string.match(preview.args.at, "([%-%d%.]+),([%-%d%.]+)")
	x, z = tonumber(a) or 0, tonumber(b) or 0
end
local focus = c + Vector3.new(x, 0, z)
local pitch = math.rad(55)
local dist = tonumber(preview.args.dist) or 77.5
preview.camera = { cf = CFrame.lookAt(focus + Vector3.new(0, math.sin(pitch) * dist, math.cos(pitch) * dist), focus), fov = 42 }
preview.render.hideCoreUi = true
preview.advance(0.1)
