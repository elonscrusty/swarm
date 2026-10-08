-- basecamp: the walk-around social basecamp (SwarmV2.Lobby.Basecamp), part-built, no GUI.
--   --set view=top|gates|pedestals|bonfire|ruins   camera (default top: high 3/4 overhead)
--   --set sign=full|searching   gate status text sample (default: three different statuses)
local C = lib("common")
local s = C.bootServer()

local RS = game:GetService("ReplicatedStorage")
local Origin = preview.require(RS.SwarmV2.Lobby.LobbyConfig).Origin

if s.MapBuilder and s.MapBuilder.ApplyLighting then
	C.try("ApplyLighting", s.MapBuilder.ApplyLighting, "Forest")
end

local mod = game:GetService("ServerScriptService").SwarmV2.Lobby.Basecamp
local Basecamp = preview.require(mod)
local built = C.try("Basecamp.Build", Basecamp.Build)
if not built then
	return
end
-- idempotent rebuild
built = Basecamp.Build()

local n = 0
for _, d in ipairs(workspace.SwarmV2Lobby:GetDescendants()) do
	if d:IsA("BasePart") then
		n += 1
	end
end
preview.note("basecamp parts: " .. n)
preview.metrics.parts = n

Basecamp.SetBoard("PublicA", "2/4 PLAYERS", Color3.fromRGB(150, 240, 150))
Basecamp.SetBoard("Party", "WAITING FOR PARTY", Color3.fromRGB(255, 220, 120))
Basecamp.SetBoard("PublicB", "OPEN", Color3.fromRGB(226, 238, 255))

local function O(x, y, z)
	return Vector3.new(Origin.X + x, Origin.Y + y, Origin.Z + z)
end
local view = preview.args.view or "top"
preview.hideCoreUi = true
if view == "gates" then
	preview.camera = { cf = CFrame.lookAt(O(0, 30, -30), O(0, 12, -86)), fov = 62 }
elseif view == "pedestals" then
	preview.camera = { cf = CFrame.lookAt(O(14, 14, 0), O(78, 11, 0)), fov = 70 }
elseif view == "bonfire" then
	preview.camera = { cf = CFrame.lookAt(O(-18, 14, 24), O(0, 2, 0)), fov = 55 }
elseif view == "ruins" then
	preview.camera = { cf = CFrame.lookAt(O(10, 40, 100), O(-52, 6, 58)), fov = 60 }
else
	preview.camera = { cf = CFrame.lookAt(O(-30, 100, 112), O(10, 0, -22)), fov = 72 }
end

local cam = workspace.CurrentCamera
if cam and preview.camera then
	cam.CFrame = preview.camera.cf
	cam.FieldOfView = preview.camera.fov
end
-- the mock draws BillboardGuis only from PlayerGui: show the pedestal boards there (same objects, cloned)
for _, d in ipairs(workspace.SwarmV2Lobby:GetDescendants()) do
	if d:IsA("BillboardGui") then
		local c = d:Clone()
		c.Adornee = d.Parent
		c.Parent = preview.playerGui()
	end
end
preview.advance(0.3)
