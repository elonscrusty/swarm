--!strict
--[[
	SwarmV2/Run/RunClient.lua  (StarterPlayerScripts.SwarmV2Client.Run.RunClient)
	OWNER: gameplay track (Chat 2). Boot hook from the shared base: called once at startup, after the
	existing modules (CameraController and MobileControls are already running). See docs/redesign/OWNERSHIP.md.
]]

local RunClient = {}

-- One failing module must not stop the ones after it.
local function boot(name: string, fn: () -> ())
	local ok, err = (pcall :: any)(fn)
	if not ok then
		warn("[RunClient] " .. name .. " failed to start: " .. tostring(err))
	end
end

function RunClient.Init()
	boot("DashClient", function()
		require(script.Parent.DashClient).Init()
	end)
end

return RunClient
