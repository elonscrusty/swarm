-- Server choice state. With the continuation pack's rank system (RunConfig.Builds.Enabled, the
-- live default; docs/redesign/gameplay/BUILDS.md): a team run never pauses (the chooser keeps
-- moving and fighting, no protection), one choice at a time from a queue with its own deadline,
-- the first card on timeout, idempotent offer ids, deferral, a downed hero's choice suspended
-- and resumed with the same cards, one reroll per choice, CancelAll, and solo kept as before
-- (the world freezes, the solo timer, the pause menu stops it). With the switch off the old
-- 12-level checks run (docs/overhaul/CHOICE_STATE.md: duo protection, budget, merged panels).
local Players = game:GetService("Players")
local player = Players.LocalPlayer
local friend = preview.addPlayer("ChoiceMate", 2)
local RunConfig = require(game:GetService("ReplicatedStorage").SwarmV2.Run.RunConfig)
local Builds = RunConfig.Builds
if preview.args.builds == "legacy" then
	Builds.Enabled = false -- --set builds=legacy: the old 12-level system's checks
end
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
local function hit(r)
	for _ = 1, 3 do RM.DamagePlayer(r, 1e5, "Test") end
end
local function serverLeft(): number
	return (player:GetAttribute("ChoiceProtectedUntil") or 0) - workspace:GetServerTimeNow()
end
local grace = L.RevealGraceSeconds or 0

if Builds.Enabled then
	local function keys(offer)
		local out = {}
		for _, c in ipairs(offer or {}) do
			table.insert(out, string.format("%s:%s:%s", tostring(c.Category), tostring(c.Id), tostring(c.RankTo)))
		end
		table.sort(out)
		return table.concat(out, ",")
	end
	local function buildSum(r): number
		local n = 0
		for _, w in pairs(r.Weapons) do n += w.Level + (w.Evolved and 1 or 0) end
		for _, l in pairs(r.Passives) do n += l end
		return n
	end

	-- no stray level-ups from the weapons' kills while testing (the test queues its own)
	rp.XPNeeded, mate.XPNeeded = 1e12, 1e12
	-- 1) a team run: the choice opens live, nothing pauses or protects
	LUS.QueueLevels(rp, 1)
	assert(rp.Offer and not rp.Paused and rp.LiveChoice, "a duo level-up opens a live choice (not paused)")
	assert(player:GetAttribute("ChoiceOpen") == true and player:GetAttribute("ChoiceLive") == true, "choice attributes published")
	assert(player:GetAttribute("PendingChoices") == 1, "PendingChoices attribute")
	assert(not RM.IsFrozen(), "a duo choice must not freeze the world")
	assert(serverLeft() <= Builds.ChoiceSeconds + grace + 0.05 and serverLeft() > Builds.ChoiceSeconds - 0.5, "the live deadline is ChoiceSeconds")
	local t0 = RM.GetRunTime()
	preview.advance(0.5)
	assert(RM.GetRunTime() > t0, "the run clock keeps going")
	tough(rp); tough(mate)
	local hp, mateHp = rp.HP, mate.HP
	hit(rp)
	hit(mate)
	assert(rp.HP < hp, "the chooser is NOT protected while choosing (combat continues)")
	assert(mate.HP < mateHp, "the teammate takes damage normally")
	assert(rp.Humanoid.WalkSpeed > 0, "the chooser keeps moving")
	tough(rp)

	-- 2) the queue: one choice at a time, idempotent offer ids, a fresh deadline per choice
	local id = player:GetAttribute("ChoiceOfferId")
	local deadline = rp.OfferDeadline
	LUS.QueueLevels(rp, 2)
	assert(rp.PendingLevels == 3 and rp.OfferDeadline == deadline and player:GetAttribute("ChoiceOfferId") == id, "queued choices wait; the open one keeps its deadline")
	preview.fireServerAs(player, "LevelUpChoose", 1, id + 99)
	assert(rp.PendingLevels == 3, "a pick naming another card set is ignored")
	local sum = buildSum(rp)
	preview.advance(0.3)
	preview.fireServerAs(player, "LevelUpChoose", 1, id)
	assert(rp.PendingLevels == 2 and player:GetAttribute("ChoiceOfferId") ~= id, "a valid pick applies once and opens the next choice")
	assert(buildSum(rp) > sum or rp.Offer, "the pick changed the build")
	assert(rp.OfferDeadline > deadline, "the next choice has its own deadline")
	preview.fireServerAs(player, "LevelUpChoose", 1, id) -- double tap / late packet
	assert(rp.PendingLevels == 2, "a repeated pick must not land on the next choice")
	preview.fireServerAs(player, "LevelUpReroll", id)
	preview.fireServerAs(player, "LevelUpSkip", id)
	assert(rp.PendingLevels == 2, "stale reroll / skip ignored")

	-- 3) reroll: one per choice, debited only when a new offer comes out, deadline kept
	local rerolls = rp.Rerolls
	assert(rerolls >= Builds.FreeRerolls, "the run's free rerolls are there")
	local before, dl = keys(rp.Offer), rp.OfferDeadline
	preview.fireServerAs(player, "LevelUpReroll", rp.OfferSeq)
	local changed = keys(rp.Offer) ~= before
	assert((changed and rp.Rerolls == rerolls - 1) or (not changed and rp.Rerolls == rerolls), "a reroll is debited only for a new offer")
	assert(rp.OfferDeadline == dl, "a reroll keeps the deadline")
	local after = rp.Rerolls
	preview.fireServerAs(player, "LevelUpReroll", rp.OfferSeq)
	assert(rp.Rerolls == after or not changed, "one reroll per choice")

	-- 4) deadlines: the FIRST displayed card is taken, then the next choice opens
	local first = rp.Offer[1]
	local firstKind, firstId = first.Type, first.Id
	local level0 = (firstKind == "WeaponUp" and rp.Weapons[firstId] and rp.Weapons[firstId].Level) or (firstKind == "PassiveUp" and rp.Passives[firstId]) or 0
	preview.advance(Builds.ChoiceSeconds + grace + 0.3)
	local applied = false
	if firstKind == "WeaponNew" or firstKind == "WeaponUp" then
		applied = rp.Weapons[firstId] ~= nil and rp.Weapons[firstId].Level > level0
	elseif firstKind == "PassiveNew" or firstKind == "PassiveUp" then
		applied = (rp.Passives[firstId] or 0) > level0
	else
		applied = true -- an evolution / heal card
	end
	assert(applied, "the timeout took the first displayed card (" .. tostring(firstKind) .. " " .. tostring(firstId) .. ")")
	assert(rp.PendingLevels == 1 and rp.Offer, "the next queued choice opened")
	preview.advance(Builds.ChoiceSeconds + grace + 0.3)
	assert(not rp.Offer and rp.PendingLevels == 0 and player:GetAttribute("ChoiceOpen") == false, "the queue drains, ChoiceOpen cleared")

	-- 5) farming: endless levels never protect anyone (there is no protection to farm)
	local protected = 0
	for _ = 1, 300 do
		if rp.PendingLevels < 5 then LUS.QueueLevels(rp, 10) end
		rp.PortalOffered = false
		tough(rp)
		tough(mate)
		preview.advance(0.1)
		if (rp.Paused and rp.Offer) or RM.GetRunTime() < (rp.InvulnUntil or 0) then protected += 0.1 end
	end
	assert(protected == 0, string.format("no protection while choosing in a team run (%.1f s)", protected))
	assert(rp.Alive and mate.Alive, "both players alive through the farming test")
	LUS.Cancel(rp)

	-- 6) the duo run menu and reward toasts never protect; Paused alone is not protection
	preview.fireServerAs(player, "SetPause", true)
	assert(not RM.IsMenuPaused() and not RM.IsFrozen(), "the duo run menu does not pause the server")
	rp.InvulnUntil = 0
	tough(rp); hp = rp.HP
	hit(rp)
	assert(rp.HP < hp, "an open run menu grants no protection")
	preview.fireServerAs(player, "SetPause", false)
	RM.HoldReward(rp, true)
	assert(rp.RewardUntil == nil and rp.Humanoid.WalkSpeed > 0, "a duo chest reveal neither holds nor roots")
	rp.Paused = true
	tough(rp); hp = rp.HP
	hit(rp)
	assert(rp.HP < hp, "Paused without a server offer is not protection")
	rp.Paused = false
	RM.ApplyMovement(rp)

	-- 7) deferral during the stage-clear dialog
	rp.PortalOffered = true
	LUS.QueueLevels(rp, 1)
	assert(not rp.Offer and player:GetAttribute("ChoiceDeferred") == "Portal", "no choice over the stage-clear dialog")
	rp.PortalOffered = false
	preview.advance(0.1)
	assert(rp.Offer, "the deferred choice opens once the dialog is gone")

	-- 8) going down suspends the personal deadline (not the world); revival resumes the SAME cards
	local cards = keys(rp.Offer)
	local leftBefore = rp.OfferDeadline - os.clock()
	rp.Alive = false
	preview.advance(0.1)
	assert(not rp.Offer and rp.SuspendedOffer and rp.PendingLevels == 1, "going down suspends the choice and keeps it queued")
	assert(not RM.IsFrozen(), "a downed teammate's choice does not freeze the world")
	preview.fireServerAs(player, "LevelUpChoose", 1, rp.OfferSeq)
	preview.advance(Builds.ChoiceSeconds + grace + 1)
	assert(rp.PendingLevels == 1 and rp.SuspendedOffer, "no pick and no timeout while downed")
	rp.Alive = true
	preview.advance(0.1)
	assert(rp.Offer and keys(rp.Offer) == cards, "revival resumes the same cards")
	local leftAfter = rp.OfferDeadline - os.clock()
	assert(leftAfter <= leftBefore + 0.1 and leftAfter >= 0.9, string.format("the deadline resumes where it stopped (%.2f -> %.2f)", leftBefore, leftAfter))
	LUS.Cancel(rp)

	-- 9) CancelAll (victory / run end): everything dropped, nothing new opens
	LUS.QueueChoice(rp, "Chest", "PassiveOnly")
	assert(rp.Offer and rp.OfferMeta and rp.OfferMeta.Source == "Chest", "QueueChoice opens a chest choice")
	for _, c in ipairs(rp.Offer) do
		assert(c.Category == "PassiveUpgrade" or c.Category == "NewPassive" or c.Category == "Heal", "a chest choice offers passives only (" .. tostring(c.Category) .. ")")
	end
	LUS.QueueLevels(rp, 2)
	assert(LUS.PendingCount(rp) == 3, "PendingCount counts the queue")
	LUS.CancelAll(rp)
	assert(not rp.Offer and LUS.PendingCount(rp) == 0, "CancelAll drops every choice")
	LUS.QueueLevels(rp, 1)
	LUS.QueueChoice(rp, "Chest", "PassiveOnly")
	assert(not rp.Offer and LUS.PendingCount(rp) == 0, "no new choice after CancelAll")
	rp.ChoicesClosed = nil

	-- 10) solo (teammate left): the world freezes, the solo timer, the menu stops it
	RM.AbandonRun(mate)
	preview.advance(0.2)
	LUS.QueueLevels(rp, 1)
	assert(rp.Offer and rp.Paused and RM.IsFrozen() and player:GetAttribute("ChoiceGroup") == false, "solo choice freezes the world (kept as before)")
	assert(serverLeft() > Builds.ChoiceSeconds + grace, "solo uses SoloChoiceSeconds")
	preview.fireServerAs(player, "SetPause", true)
	local beforeDl = rp.OfferDeadline
	preview.advance(1)
	assert(player:GetAttribute("ChoiceTimerPaused") == true and rp.OfferDeadline > beforeDl, "the solo pause menu stops the clock")
	preview.fireServerAs(player, "SetPause", false)
	preview.advance(Builds.SoloChoiceSeconds + grace + 0.5)
	assert(not rp.Offer and rp.PendingLevels == 0 and not RM.IsFrozen(), "solo auto-pick resolves and unfreezes")
	preview.log("PASS choice state (rank system): live duo choices, no protection, queue + per-choice deadlines, first card on timeout, offer ids, reroll, deferral, downed suspension, CancelAll, solo pause")
	return
end

-- old 12-level system (RunConfig.Builds.Enabled = false)
-- 1) duo: the chooser is protected, the world and the teammate are not
LUS.QueueLevels(rp, 1)
assert(rp.Offer and rp.Paused, "a duo level-up opens a panel")
assert(player:GetAttribute("ChoiceOpen") == true and player:GetAttribute("ChoiceGroup") == true, "choice attributes published")
assert(not RM.IsFrozen(), "a duo choice must not freeze the world")
assert(serverLeft() <= L.GroupAutoPickSeconds + (L.RevealGraceSeconds or 0) + 0.05, "group deadline bounded by GroupAutoPickSeconds")
local t0 = RM.GetRunTime()
preview.advance(0.5)
assert(RM.GetRunTime() > t0, "the run clock keeps going for the team")
tough(rp); tough(mate)
local hp, mateHp = rp.HP, mate.HP
hit(rp)
hit(mate)
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
preview.advance(L.GroupAutoPickSeconds + (L.RevealGraceSeconds or 0) + 0.3)
assert(not rp.Offer and not rp.Paused and rp.PendingLevels == 0, "deadline auto-picks the whole panel")
assert(player:GetAttribute("ChoiceOpen") == false, "ChoiceOpen cleared on close")
assert(rp.Humanoid.WalkSpeed > 0, "control restored when the panel closes")
preview.advance((Config.Player.ChoiceGraceSeconds or 0) + 0.1)
tough(rp); hp = rp.HP
hit(rp)
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
hit(rp)
assert(rp.HP < hp, "an open run menu grants no protection")
preview.fireServerAs(player, "SetPause", false)
RM.HoldReward(rp, false)
assert(rp.RewardUntil == nil, "a compact reward toast does not protect")
RM.HoldReward(rp, true)
assert(rp.RewardUntil == nil and rp.Humanoid.WalkSpeed > 0, "a duo chest reveal neither holds nor roots")
tough(rp); hp = rp.HP
hit(rp)
assert(rp.HP < hp and not RM.IsFrozen(), "a duo chest reward grants no protection and no freeze")
rp.Paused = true
tough(rp); hp = rp.HP
hit(rp)
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
preview.advance(L.AutoPickSeconds + (L.RevealGraceSeconds or 0) + 0.5)
assert(not rp.Offer and rp.PendingLevels == 0, "solo auto-pick still resolves the panel")
preview.log("PASS choice state: duo protection, teammate damage, bounded deadlines, budget, offer ids, deferral, cancellation, solo pause")
