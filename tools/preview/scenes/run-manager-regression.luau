-- Real server boundaries for hold-to-revive teammate revives, escrow progress and damage grace.
-- (stream E1: a downed teammate is revived by a living teammate HOLDING interact within 8 studs
-- for 3 uninterrupted seconds; standing beside them alone does nothing.)
local Players = game:GetService("Players")
local player = Players.LocalPlayer
local friend = preview.addPlayer("ReviveHelper", 2)
preview.startServer()
preview.advance(1)
local RM = preview.server("RunManager")
local DS = preview.server("DataService")
local SM = preview.server("StageManager")
local RunConfig = preview.require(game:GetService("ReplicatedStorage").SwarmV2.Run.RunConfig)
local SD = RunConfig.Survival.Downed
preview.remote("ReviveHold"):FireServer(true) -- lobby input must be harmless
assert(RM.StartTeamRun({ player, friend }, "Duo", "Forest", player))
preview.advance(6)
local rp, helper = assert(RM.GetRunPlayer(player)), assert(RM.GetRunPlayer(friend))
rp.InvulnUntil, helper.InvulnUntil = 0, math.huge
rp.RevivesLeft, rp.ProductReviveUsed, rp.PendingLevels = 0, true, 7
RM.DamagePlayer(rp, 1e6, "Test boss strike")
assert(not rp.Alive and rp.Downed and not rp.AwaitingRevive and not rp.Eliminated, "test teammate must be downed")
assert(player:GetAttribute("Downed") == true and player:GetAttribute("Alive") == false, "downed attributes")
assert(rp.PendingLevels == 7 and rp.DeathCause == "Test boss strike", "knockdown must retain banked upgrades and cause")
local function stand(distance)
	helper.Root.CFrame = CFrame.new(rp.Root.Position + Vector3.new(distance, 0, 0))
	helper.Root.AssemblyLinearVelocity = Vector3.zero
	helper.LastValidPos = helper.Root.Position
	helper.SpeedCheckTimer = 0
end
-- holds interact for `seconds` (the client repeats the hold every HoldRefresh s)
local function hold(seconds)
	local t = 0
	while t < seconds - 1e-6 do
		preview.fireServerAs(friend, "ReviveHold", true)
		local step = math.min(SD.HoldRefresh, seconds - t)
		preview.advance(step)
		t += step
	end
end
stand(25)
hold(0.5)
assert((rp.ReviveProgress or 0) == 0, "a distant teammate holding interact must not revive")
stand(2)
preview.advance(1)
assert((rp.ReviveProgress or 0) == 0 and not rp.Alive, "standing beside without holding must not revive")
hold(1)
assert(rp.ReviveProgress > 0.25 and rp.ReviveProgress < 0.45 and not rp.Alive, "holding in range builds progress (about a third per second)")
preview.fireServerAs(friend, "ReviveHold", false)
preview.advance(0.1)
assert(rp.ReviveProgress == 0, "letting go resets the progress (3 uninterrupted seconds)")
hold(1)
stand(SD.ReviveRange + 4)
hold(0.3)
assert(rp.ReviveProgress == 0, "leaving range resets the progress")
stand(2)
hold(1)
assert(rp.ReviveProgress > 0, "progress again")
helper.InvulnUntil = 0
helper.HitProtectUntil = 0
RM.DamagePlayer(helper, 1, "Test contact")
preview.advance(0.05)
assert(rp.ReviveProgress < 0.05, "a hit on the reviver resets the progress")
helper.InvulnUntil = math.huge
for _ = 1, 40 do preview.fireServerAs(friend, "ReviveHold", true) end
preview.fireServerAs(friend, "ReviveHold", false)
preview.advance(0.1)
assert(rp.ReviveProgress == 0, "spammed holds then a release do not revive")
hold(SD.ReviveSeconds + 0.3)
assert(rp.Alive and rp.HP > 0 and rp.PartnerRevives == 1, "three held seconds beside the downed teammate must revive once")
assert(math.abs(rp.HP - rp.Stats.MaxHP * SD.ReviveHPShare) < 1, "revived at 25% of max HP, got " .. rp.HP .. " / " .. rp.Stats.MaxHP)
assert(rp.InvulnUntil > RM.GetRunTime() and rp.InvulnUntil <= RM.GetRunTime() + SD.ReviveProtectSeconds + 0.01, "one second of revive protection")
assert((player:GetAttribute("ReviveProtectUntil") or 0) > 0 and player:GetAttribute("Downed") == false, "revive attributes")
assert(rp.PendingLevels == 7, "revival must preserve earned upgrade bank")
assert(helper.Revives == 1, "the reviver's revive count (class goal) went up once")
preview.fireServerAs(friend, "ReviveHold", false)
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
preview.log("PASS hold-to-revive (range, release, reviver hit, 25% HP, 1 s protection), banked upgrades, escrow stage progress and combat-clock damage grace")
