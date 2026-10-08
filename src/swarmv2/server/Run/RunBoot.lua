--!strict
--[[
	SwarmV2/Run/RunBoot.lua  (ServerScriptService.SwarmV2.Run.RunBoot)
	OWNER: gameplay track (Chat 2). Boot hook from the shared base: called once at startup, after the
	existing modules. See docs/redesign/OWNERSHIP.md.
]]

local RunBoot = {}

-- One failing module must not stop the ones after it.
local function boot(name: string, fn: () -> ())
	local ok, err = (pcall :: any)(fn)
	if not ok then
		warn("[RunBoot] " .. name .. " failed to start: " .. tostring(err))
	end
end

function RunBoot.Init(ctx: any)
	boot("Dash", function()
		require(script.Parent.Dash).Init(ctx)
	end)
	boot("LaunchPads", function()
		require(script.Parent.LaunchPads).Init(ctx)
	end)
	-- last: it may start admitting players (match servers)
	boot("RunEntry", function()
		require(script.Parent.RunEntry).Init(ctx)
	end)
end

return RunBoot
