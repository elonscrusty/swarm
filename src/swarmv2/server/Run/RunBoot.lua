--!strict
--[[
	SwarmV2/Run/RunBoot.lua  (ServerScriptService.SwarmV2.Run.RunBoot)
	OWNER: gameplay track (Chat 2). Boot hook from the shared base: called once at startup, after the
	existing modules. See docs/redesign/OWNERSHIP.md.

	Class kits (docs/redesign/gameplay/CLASSES.md): ClassRegistry registers the four classes into
	CharacterData and hides the old heroes; ClassKits runs their passives and movement reactions.
	Other helpers add their own Init calls below.
]]

local ClassRegistry = require(script.Parent.ClassRegistry)
local ClassKits = require(script.Parent.ClassKits)

local RunBoot = {}

function RunBoot.Init(ctx: any)
	ctx.ClassRegistry = ClassRegistry
	ClassRegistry.Init()
	ClassKits.Init(ctx)
end

return RunBoot
