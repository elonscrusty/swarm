--!nonstrict
--[[
	SwarmV2/Run/RunScreens.lua  (StarterPlayerScripts.SwarmV2Client.Run.RunScreens)
	OWNER: stream F (run UI).

	One entry point for UIBuilder: builds and drives the run screens of the continuation brief that live
	outside the HUD frame itself: the upgrade cards (RunCards), the interact prompt (RunInteract) and the
	downed / revived / spectate screen (RunDowned). The HUD pieces (Hud: vitals, timer, objective strip,
	equipment; MiniMap + BigMap; TeamUI) are built by their own modules.

	  RunScreens.Build(root, kit)       kit: OnRelayout, VirtualSize, TopBottom(), TimerBottom(),
	                                    EquipmentTop(), Thumbs(), OpenMenu()
	  RunScreens.Update(dt, state, inRun)   every frame
	  RunScreens.Cards                  RunCards (UIBuilder routes LevelUpOffer / LevelUpClose to it)
]]

local Client = script.Parent.Parent.Parent:WaitForChild("SwarmClient")
local Shared = game:GetService("ReplicatedStorage"):WaitForChild("Shared")
local Remotes = require(Shared:WaitForChild("Remotes"))
local LootUI = require(Client:WaitForChild("LootUI"))
local RunCards = require(script.Parent.RunCards)
local RunInteract = require(script.Parent.RunInteract)
local RunDowned = require(script.Parent.RunDowned)
local RunObjective = require(script.Parent.RunObjective)

local RunScreens = {}

RunScreens.Cards = RunCards
RunScreens.Interact = RunInteract
RunScreens.Downed = RunDowned

function RunScreens.Build(root: Instance, kit: any)
	RunCards.Build(root, kit)
	RunInteract.Build(root, kit)
	RunDowned.Build(root, kit)
	-- the chest hold and its prompt: the interact prompt presents it in the new run flow
	RunInteract.SetLoot(LootUI)
	LootUI.Suppress = function(): boolean
		local priority = RunInteract.Priority()
		return priority == "Revive" or priority == "Beacon"
	end
	LootUI.HideChestPrompt = function(): boolean
		return RunObjective.Active(Remotes.State())
	end
end

function RunScreens.Update(dt: number, state: Instance, inRun: boolean)
	RunCards.Update(dt)
	RunInteract.Update(dt, state, inRun)
	RunDowned.Update(dt, state, inRun)
end

return RunScreens
