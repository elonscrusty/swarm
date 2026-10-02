-- loot: stage 2 in the Forest with this stage's chests, shrines and the guarded altar
-- placed by the real LootSystem (MapBuilder.FindOpenSpot), the hero standing at one of
-- them with the loot prompt up, the items strip, an item popup and a sealed Bargain.
--   --set focus=Small|Large|Golden|Chance|Bargain|Guarded   what the hero stands at
--   --set altar=Dormant|Guarded|Claimable                     the altar's state
--   --set gold=N                                              run gold (default 140)
local A = lib("arena")
local C = lib("common")
local focus = preview.args.focus or "Chance"
local Players = game:GetService("Players")

local loot
local s = A.build({
	enemies = 45,
	seconds = 380,
	portal = true,
	portalState = "Idle",
	stage = 2,
	place = function(s, arena, centre)
		loot = C.server("LootSystem")
		if not loot then
			return nil
		end
		local stub = {
			RunManager = { GetRunPlayers = function() return {} end, GetRunTime = function() return 380 end },
			MonetizationService = { GoldMultiplier = function() return 1 end },
		}
		C.try("LootSystem.Init", loot.Init, stub)
		C.try("LootSystem.BuildStage", loot.BuildStage, arena, 2, s.portal and s.portal.Pos or nil)
		local target
		for _, obj in ipairs(loot.Objects()) do
			if obj.Type == focus and not target then
				target = obj
			end
			if obj.Kind == "Altar" and preview.args.altar then
				obj.Model:SetAttribute("State", preview.args.altar)
				obj.Model:SetAttribute("Detail", preview.args.altar == "Guarded" and "Guards left: 3 / 5" or "")
			end
			if obj.Type == "Bargain" and focus ~= "Bargain" then
				obj.Model:SetAttribute("State", "Active")
			end
		end
		preview.metrics.loot = #loot.Objects()
		if target then
			-- stand just south of it (the camera side)
			return Vector3.new(target.Pos.X + 1, centre.Y, target.Pos.Z + 5.2)
		end
		return nil
	end,
})
C.setPlayer({ RunGold = tonumber(preview.args.gold) or 140, GoldMult = 1, Shield = 9, ShieldMax = 12 })
C.fire("Items", {
	{ Id = "Whetstone", Count = 3 },
	{ Id = "QuickGloves", Count = 2 },
	{ Id = "StormCharm", Count = 1 },
	{ Id = "GuardianWard", Count = 1 },
	{ Id = "KeenLens", Count = 4 },
	{ Id = "HealingHerb", Count = 1 },
	{ Id = "SunMedallion", Count = 1 },
	{ Id = "SpareQuiver", Count = 2 },
})
C.settle(0.5)
C.fire("ItemGained", { Id = "StormCharm", Count = 1, Source = "Large Chest" })
C.fire("ItemGained", { Id = "SunMedallion", Count = 1, Source = "Guarded Altar" })
C.settle(1.2)
local _ = Players
