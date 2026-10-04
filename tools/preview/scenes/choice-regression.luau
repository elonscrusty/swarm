-- Server choice state (docs/overhaul/CHOICE_STATE.md): duo chooser protection, teammate
-- vulnerability, bounded deadlines, the protection budget, idempotent offer ids,
-- deferral, cancellation, run menu / reward toast non-protection, solo pause.
local Players = game:GetService("Players")
local player = Players.LocalPlayer
local friend = preview.addPlayer("ChoiceMate", 2)
preview.startServer()
preview.advance(1)
local RM = preview.server("RunManager")
local LUS = preview.server("LevelUpSystem")
local Config = preview.shared("Config")
local L = Config.LevelUp
assert(RM.StartTeamRun({ player, friend }, "Duo", "Forest", player))
preview.advance(6)
local rp, mate = assert(RM.GetRunPlayer(player)), assert(RM.GetRunPlayer(friend))
LUS.Cancel(rp)
LUS.Cancel(mate)
local function tough(r)
	r.Stats.MaxHP = 1e7
	RM.Heal(r, 1e7, true)
end
tough(rp)
tough(mate)
rp.InvulnUntil, mate.InvulnUntil = 0, 0
local function serverLeft(): number
	return (player:GetAttribute("ChoiceProtectedUntil") or 0) - workspace:GetServerTimeNow()
end

-- 1) duo: the chooser is protected, the world and the teammate are not
LUS.QueueLevels(rp, 1)
assert(rp.Offer and rp.Paused, "a duo level-up opens a panel")
assert(player:GetAttribute("ChoiceOpen") == true and player:GetAttribute("ChoiceGroup") == true, "choice attributes published")
assert(not RM.IsFrozen(), "a duo choice must not freeze the world")
assert(serverLeft() <= L.GroupAutoPickSeconds + 0.05, "group deadline bounded by GroupAutoPickSeconds")
local t0 = RM.GetRunTime()
preview.advance(0.5)
assert(RM.GetRunTime() > t0, "the run clock keeps going for the team")
tough(rp); tough(mate)
local hp, mateHp = rp.HP, mate.HP
RM.DamagePlayer(rp, 1e5, "Test")
RM.DamagePlayer(mate, 1e5, "Test")
assert(rp.HP == hp, "the chooser is protected while the panel is open")
assert(mate.HP < mateHp, "the teammate takes damage normally")
assert(rp.Root.Parent and rp.Humanoid.WalkSpeed == 0, "the chooser is rooted")

-- 2) idempotent offer ids and merged rounds that do not extend the deadline
local id = player:GetAttribute("ChoiceOfferId")
local deadline = rp.OfferDeadline
LUS.QueueLevels(rp, 2)
assert(rp.BatchTotal == 3 and rp.OfferDeadline == deadline, "merged rounds share the first deadline")
preview.fireServerAs(player, "LevelUpChoose", 1, id + 99)
assert(rp.PendingLevels == 3, "a pick naming another card set is ignored")
preview.fireServerAs(player, "LevelUpChoose", 1, id)
assert(rp.PendingLevels == 2 and player:GetAttribute("ChoiceOfferId") ~= id, "a valid pick applies once and rolls a new set")
preview.fireServerAs(player, "LevelUpChoose", 1, id) -- double tap / late packet
assert(rp.PendingLevels == 2, "a repeated pick must not land on the next round")
preview.fireServerAs(player, "LevelUpReroll", id)
preview.fireServerAs(player, "LevelUpSkip", id)
assert(rp.PendingLevels == 2, "stale reroll / skip ignored")

-- 3) holding the panel: the auto-pick resolves every round, control and damage come back
preview.advance(L.GroupAutoPickSeconds + 0.3)
assert(not rp.Offer and not rp.Paused and rp.PendingLevels == 0, "deadline auto-picks the whole panel")
assert(player:GetAttribute("ChoiceOpen") == false, "ChoiceOpen cleared on close")
assert(rp.Humanoid.WalkSpeed > 0, "control restored when the panel closes")
preview.advance((Config.Player.ChoiceGraceSeconds or 0) + 0.1)
tough(rp); hp = rp.HP
RM.DamagePlayer(rp, 1e5, "Test")
assert(rp.HP < hp, "protection ends after the panel and its grace")

-- 4) farming: endless queued levels cannot keep a player protected
local protected, deferred = 0, false
local function farm(seconds)
	local p = 0
	for _ = 1, math.floor(seconds / 0.1) do
		if rp.PendingLevels < 5 then LUS.QueueLevels(rp, 10) end
		rp.PortalOffered = false
		tough(rp)
		tough(mate)
		preview.advance(0.1)
		if (rp.Paused and rp.Offer) or RM.GetRunTime() < rp.InvulnUntil then p += 0.1 end
		if player:GetAttribute("ChoiceDeferred") == "Budget" then deferred = true end
	end
	return p
end
farm(60)
protected = farm(60)
local cap = L.ProtectBudgetRefillPerMinute + (Config.Player.ChoiceGraceSeconds or 0) + 1
assert(rp.Alive and mate.Alive, "both players alive through the farming test")
assert(protected <= cap, string.format("protected %.1f s in a minute of farming (cap %.1f)", protected, cap))
assert(deferred, "an exhausted budget defers the next panel (levels stay banked)")
assert(rp.PendingLevels > 0 or rp.Offer, "deferred levels are not dropped")
preview.log(string.format("farming: %.1f s protected in the second minute (budget %d s/min)", protected, L.ProtectBudgetRefillPerMinute))
LUS.Cancel(rp)
rp.ProtectBudget = L.ProtectBudgetSeconds

-- 5) the duo run menu and reward toasts never protect; Paused alone is not protection
preview.fireServerAs(player, "SetPause", true)
assert(not RM.IsMenuPaused() and not RM.IsFrozen(), "the duo run menu does not pause the server")
rp.InvulnUntil = 0
tough(rp); hp = rp.HP
RM.DamagePlayer(rp, 1e5, "Test")
assert(rp.HP < hp, "an open run menu grants no protection")
preview.fireServerAs(player, "SetPause", false)
RM.HoldReward(rp, false)
assert(rp.RewardUntil == nil, "a compact reward toast does not protect")
RM.HoldReward(rp, true)
assert(rp.RewardUntil == nil and rp.Humanoid.WalkSpeed > 0, "a duo chest reveal neither holds nor roots")
tough(rp); hp = rp.HP
RM.DamagePlayer(rp, 1e5, "Test")
assert(rp.HP < hp and not RM.IsFrozen(), "a duo chest reward grants no protection and no freeze")
rp.Paused = true
tough(rp); hp = rp.HP
RM.DamagePlayer(rp, 1e5, "Test")
assert(rp.HP < hp, "Paused without a server offer is not protection")
rp.Paused = false
RM.ApplyMovement(rp)

-- 6) deferral during the stage-clear dialog, cancellation on going down
rp.PortalOffered = true
LUS.QueueLevels(rp, 1)
assert(not rp.Offer and player:GetAttribute("ChoiceDeferred") == "Portal", "no panel over the stage-clear dialog")
rp.PortalOffered = false
preview.advance(0.1)
assert(rp.Offer, "deferred panel opens once the dialog is gone")
rp.Alive = false
preview.advance(0.1)
assert(not rp.Offer and not rp.Paused and rp.PendingLevels == 1, "going down closes the panel and keeps the level")
rp.Alive = true
LUS.Cancel(rp)

-- 7) solo (teammate left): the world freezes, the long timer applies, the menu stops it
RM.AbandonRun(mate)
preview.advance(0.2)
LUS.QueueLevels(rp, 1)
assert(rp.Offer and RM.IsFrozen() and player:GetAttribute("ChoiceGroup") == false, "solo choice freezes the world")
assert(serverLeft() > L.GroupAutoPickSeconds, "solo uses AutoPickSeconds")
preview.fireServerAs(player, "SetPause", true)
local before = rp.OfferDeadline
preview.advance(1)
assert(player:GetAttribute("ChoiceTimerPaused") == true and rp.OfferDeadline > before, "the solo pause menu stops the auto-pick clock")
preview.fireServerAs(player, "SetPause", false)
preview.advance(L.AutoPickSeconds + 0.5)
assert(not rp.Offer and rp.PendingLevels == 0, "solo auto-pick still resolves the panel")
preview.log("PASS choice state: duo protection, teammate damage, bounded deadlines, budget, offer ids, deferral, cancellation, solo pause")
