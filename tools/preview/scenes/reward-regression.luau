-- Ordinary rewards never pause; rare rewards have bounded pauses and reject stale closes.
preview.startServer()
preview.advance(1)
local player = game:GetService("Players").LocalPlayer
local RM = preview.server("RunManager")
local Gold = preview.server("GoldSystem")
local Loot = preview.server("LootSystem")
local Items = preview.server("ItemSystem")
local Config = preview.shared("Config")
assert(RM.StartTeamRun({ player }, "Solo", "Forest", player))
preview.advance(4)
local rp = assert(RM.GetRunPlayer(player))
rp.InvulnUntil = math.huge
Gold.AddRunGold(rp, 10000)
local function open(id)
	local chest
	for _, obj in ipairs(Loot.Objects()) do
		-- not the Golden Chest: it is always a rare reveal (LootSystem pauses for it)
		if obj.Kind == "Chest" and obj.State == "Ready" and obj.Type ~= "Golden" then chest = obj; break end
	end
	assert(chest, "expected another chest")
	rp.Root.CFrame = CFrame.new(chest.Pos + Vector3.new(2, 3, 0))
	rp.LastValidPos, rp.SpeedCheckTimer = rp.Root.Position, 0
	Items.Roll = function() return id end
	preview.remote("LootHold"):FireServer(chest.Id, true)
	preview.advance((chest.Model:GetAttribute("Hold") or 0.4) + 0.2)
	assert(chest.State == "Opened" and rp.Items[id] == 1, "chest must grant server item immediately")
end
open("HealingHerb")
assert(not rp.RewardUntil and not RM.IsFrozen(), "ordinary chest must allow solo combat to continue")
local seq = rp.RewardSeq
preview.server("LevelUpSystem").OpenChest(rp)
assert(rp.RewardSeq == seq + 1, "elite chest must share item reward sequence even when ordinary")
RM.EndReward(rp)
open("SunMedallion")
assert(rp.RewardUntil and RM.IsFrozen(), "rare chest must enter dramatic pause")
preview.remote("RewardClose"):FireServer((rp.RewardSeq or 0) - 1)
preview.advance(0.1)
assert(rp.RewardUntil, "stale close cannot dismiss a newer reward")
for _ = 1, 20 do RM.HoldReward(rp, true) end
assert(rp.RewardUntil <= rp.RewardStart + Config.Chests.RewardPauseMax, "reward burst must respect hard pause cap")
preview.remote("RewardClose"):FireServer(rp.RewardSeq)
preview.advance(0.1)
assert(not rp.RewardUntil and not RM.IsFrozen(), "current close must release the dramatic pause")
preview.log("PASS ordinary and rare chest ownership, pause boundaries, stale closes and burst cap")
