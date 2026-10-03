-- Real server boundaries for proximity teammate revives, escrow progress and damage grace.
local Players = game:GetService("Players")
local player = Players.LocalPlayer
local friend = preview.addPlayer("ReviveHelper", 2)
preview.startServer()
preview.advance(1)
local RM = preview.server("RunManager")
local DS = preview.server("DataService")
local SM = preview.server("StageManager")
preview.remote("ReviveHold"):FireServer(true) -- lobby input must be harmless
assert(RM.StartTeamRun({ player, friend }, "Duo", "Forest", player))
preview.advance(6)
local rp, helper = assert(RM.GetRunPlayer(player)), assert(RM.GetRunPlayer(friend))
rp.InvulnUntil, helper.InvulnUntil = 0, math.huge
rp.RevivesLeft, rp.ProductReviveUsed, rp.PendingLevels = 0, true, 7
RM.DamagePlayer(rp, 1e6, "Test boss strike")
assert(not rp.Alive and not rp.AwaitingRevive, "test teammate must be downed")
assert(rp.PendingLevels == 7 and rp.DeathCause == "Test boss strike", "knockdown must retain banked upgrades and cause")
local function stand(distance)
	helper.Root.CFrame = CFrame.new(rp.Root.Position + Vector3.new(distance, 0, 0))
	helper.Root.AssemblyLinearVelocity = Vector3.zero
	helper.LastValidPos = helper.Root.Position
	helper.SpeedCheckTimer = 0
end
stand(25)
preview.advance(0.5)
assert((rp.ReviveProgress or 0) == 0, "a distant teammate must not revive")
stand(2)
preview.advance(0.6)
assert(rp.ReviveProgress > 0 and not rp.Alive, "standing in range must build progress (no button)")
local partial = rp.ReviveProgress
helper.Root.AssemblyLinearVelocity = Vector3.new(4, 0, 0)
preview.advance(0.3)
assert(rp.ReviveProgress > partial, "moving inside the radius must keep filling")
stand(25)
preview.advance(0.3)
local drained = rp.ReviveProgress
assert(drained > 0 and drained < rp.ReviveProgress + 1 and drained < 0.9, "out of range drains, it does not reset at once")
preview.advance(2)
assert(rp.ReviveProgress == 0, "progress drains to zero while nobody is near")
for _ = 1, 40 do preview.fireServerAs(friend, "ReviveHold", true) end
preview.fireServerAs(friend, "ReviveHold", false)
preview.advance(0.1)
assert(rp.ReviveProgress == 0, "the old hold remote alone must not revive")
stand(2)
preview.advance(2.1)
assert(rp.Alive and rp.HP > 0 and rp.PartnerRevives == 1, "two seconds beside the fallen teammate must revive once")
assert(rp.PendingLevels == 7, "revival must preserve earned upgrade bank")
-- This fixture tests revive grace, not upgrade choices. Clear the earned menu
-- so combat time advances after the immediate XP upgrade policy resumes it.
preview.server("LevelUpSystem").Cancel(rp)
local originalCleared = SM.StagesCleared
SM.StagesCleared = function() return 2 end
RM.Step(0)
assert(DS.GetData(player).RunEscrow.Stages == 2, "escrow must track stage progress without interaction input")
SM.StagesCleared = originalCleared
rp.InvulnUntil = RM.GetRunTime() + 1
local hp = rp.HP
RM.DamagePlayer(rp, 10, "Test enemy")
assert(rp.HP == hp, "combat-clock grace must protect immediately")
preview.advance(1.1)
RM.DamagePlayer(rp, 10, "Test enemy")
assert(rp.HP < hp, "combat-clock grace must expire during active play")
preview.log("PASS proximity revives, banked upgrades, escrow stage progress and combat-clock damage grace")
