-- TEMP (world helper): paid chests (Small / Large / Golden) vs free ones (Buried Cache,
-- elite drop) in a row in front of the hero. Deleted after the check.
local A = lib("arena")
local C = lib("common")
local s = A.build({
	enemies = 0,
	seconds = 380,
	stage = 2,
	place = function(s, arena, centre)
		local loot = C.server("LootSystem")
		local MB = C.server("ModelBuilder")
		local stub = {
			RunManager = { GetRunPlayers = function() return {} end, GetRunTime = function() return 380 end },
			MonetizationService = { GoldMultiplier = function() return 1 end },
			CaravanEvent = nil,
		}
		loot.Init(stub)
		local picked = {}
		for _ = 1, 25 do
			loot.BuildStage(arena, 2, nil)
			for _, obj in ipairs(loot.Objects()) do
				if obj.Type == "Treasure" then picked.Treasure = true end
			end
			if picked.Treasure then break end
		end
		local row = { Small = -9, Large = -3, Golden = 3, Treasure = 9 }
		local done = {}
		for _, obj in ipairs(loot.Objects()) do
			local x = row[obj.Type]
			if x and not done[obj.Type] then
				done[obj.Type] = true
				local delta = Vector3.new(centre.X + x, centre.Y, centre.Z - 8) - obj.Pos
				for _, d in ipairs(obj.Model:GetDescendants()) do
					if d:IsA("BasePart") then d.CFrame = d.CFrame + delta end
				end
			end
		end
		local drop = MB.BuildChest(Vector3.new(centre.X + 15, centre.Y, centre.Z - 8))
		drop.Parent = workspace
		print("CHESTS", done.Small, done.Large, done.Golden, done.Treasure)
		return Vector3.new(centre.X, centre.Y, centre.Z + 2)
	end,
})
C.settle(0.5)
