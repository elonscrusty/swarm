local process = require("@lune/process")
local Mock = require("./preview/runtime/mock")
local R, S = Mock.R, Mock.S
local preview = Mock.boot({ device = process.args[1] or "phone", seed = 7, repo = process.cwd, root = process.cwd .. "/tools/preview", fontMetrics = nil })
local ok, err = S.runMain(function()
	preview.startClient(false)
	local remotes = preview.shared("Remotes"); remotes.Setup()
	local env = R.envFor(nil)
	local model = env.Instance.new("Model"); model.Parent = R.services.Workspace
	local body = env.Instance.new("Part"); body.Position = env.Vector3.zero; body.Parent = model; model.PrimaryPart = body
	R.localPlayer.Character = model
	R.localPlayer:SetAttribute("InRun", true); R.localPlayer:SetAttribute("Alive", true)
	local state = remotes.State(); state:SetAttribute("Mode", "Duo"); state:SetAttribute("Phase", "Running")
	local enemies = env.Instance.new("Folder"); enemies.Name = "SwarmEnemies"; enemies.Parent = R.services.Workspace
	local loot = env.Instance.new("Folder"); loot.Name = "SwarmLoot"; loot.Parent = R.services.Workspace
	local function object(parent, name, distance, id)
		local m = env.Instance.new("Model"); m.Name = name; m.Parent = parent
		local part = env.Instance.new("Part"); part.Name = "Body"; part.Position = env.Vector3.new(distance, 0, 0); part.Parent = m; m.PrimaryPart = part
		if id then m:SetAttribute("LootId", id); m:SetAttribute("State", "Ready") end
		return m
	end
	object(enemies, "E7", 20); object(enemies, "E9", 5); object(enemies, "E11", 101)
	local chest = object(loot, "Chest", 8, 29)
	local ping = preview.client("TeamPings"); ping.Init(); ping.Init(); preview.advance(.1)
	assert(ping.Target("Enemy") == 9 and ping.Target("Loot") == 29, "closest replicated IDs")
	local sent = {}
	remotes.Get("TeamPing").OnServerEvent:Connect(function(_, kind, target) table.insert(sent, { kind, target }) end)
	assert(ping.Send("Enemy")); assert(ping.Send("Help")); preview.advance(.05)
	assert(sent[1][1] == "Enemy" and sent[1][2] == 9 and sent[2][1] == "Help" and sent[2][2] == nil, "exact target and preset payloads")
	chest:SetAttribute("State", "Opened"); assert(ping.Target("Loot") == nil, "spent loot excluded")
	for _, e in ipairs(enemies:GetChildren()) do e.PrimaryPart.Position = env.Vector3.new(101, 0, 0) end
	assert(not ping.Send("Enemy"), "out of range has no target")
	local gui = preview.playerGui():FindFirstChild("TeamPings")
	local controls = gui.Controls
	assert(gui.Enabled and controls.Ping.Size.Y.Offset >= 44, "co-op native touch button")
	controls.Ping.Activated:_fire(); preview.advance(.05); assert(controls.PingOptions.Visible, "menu toggles")
	controls.PingOptions.Regroup.Activated:_fire(); preview.advance(.05)
	assert(sent[#sent][1] == "Regroup" and not controls.PingOptions.Visible, "selection sends preset and closes")
	local function visible()
		local n = 0
		for _, part in ipairs(R.services.Workspace:GetChildren()) do if part.Name == "TeamPingMarker" and part.Ping.Enabled then n += 1 end end
		return n
	end
	remotes.Get("TeamPingShown").OnClientEvent:_fire({ Kind = "Help", Position = env.Vector3.new(0/0, 0, 0), Color = env.Color3.new(1,1,1) }); preview.advance(.05)
	assert(visible() == 0, "nonfinite render payload rejected")
	remotes.Get("TeamPingShown").OnClientEvent:_fire({ Kind = "Help", Position = env.Vector3.zero, Color = env.Color3.new(1,1,1) }); preview.advance(.05)
	assert(visible() == 1, "pooled marker renders")
	preview.advance(6.1); assert(visible() == 0, "six-second marker expiry")
	state:SetAttribute("Mode", "Solo"); preview.advance(.05); assert(not gui.Enabled and not ping.Send("Help"), "solo hides pings")
	state:SetAttribute("Mode", "Duo"); remotes.Get("TeamPingShown").OnClientEvent:_fire({ Kind = "Help", Position = env.Vector3.zero, Color = env.Color3.new(1,1,1) }); preview.advance(.05)
	R.localPlayer:SetAttribute("InRun", false); preview.advance(.05)
	assert(visible() == 0 and not gui.Enabled, "run-end clears markers and controls")
	print("PASS closest IDs, bounds, presets, 44px touch, toggle, selection, invalid payload, pooled expiry, solo and run-end cleanup")
end, 10)
assert(ok, err)
assert(#R.log.errors == 0, "runtime errors")

