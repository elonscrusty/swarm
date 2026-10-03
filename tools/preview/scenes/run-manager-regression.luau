-- Real server boundaries for held teammate revives, escrow progress and damage grace.
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
stand(2)
preview.advance(0.5)
assert((rp.ReviveProgress or 0) == 0, "proximity alone must not revive")
preview.fireServerAs(friend, "ReviveHold", true)
preview.advance(0.6)
assert(rp.ReviveProgress > 0 and not rp.Alive, "held input must build progress")
helper.Root.AssemblyLinearVelocity = Vector3.new(4, 0, 0)
preview.advance(0.1)
assert(rp.ReviveProgress == 0, "moving must reset revive progress")
stand(2)
preview.advance(0.4)
preview.fireServerAs(friend, "ReviveHold", false)
preview.advance(0.1)
assert(rp.ReviveProgress == 0, "release must reset revive progress")
stand(25)
preview.fireServerAs(friend, "ReviveHold", true)
preview.advance(0.5)
assert(rp.ReviveProgress == 0, "out-of-range input must not revive")
for _ = 1, 40 do preview.fireServerAs(friend, "ReviveHold", true) end
preview.fireServerAs(friend, "ReviveHold", false)
assert(not helper.ReviveHeld, "release must survive an exhausted press limiter")
preview.advance(1.1)
preview.fireServerAs(friend, "ReviveHold", true)
stand(2)
preview.advance(2.1)
assert(rp.Alive and rp.HP > 0 and rp.PartnerRevives == 1, "two-second held revive must succeed once")
assert(rp.PendingLevels == 7, "revival must preserve earned upgrade bank")
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
preview.log("PASS held revives, banked upgrades, escrow stage progress and combat-clock damage grace")
