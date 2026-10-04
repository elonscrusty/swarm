-- Group stage clear vs an open upgrade choice (docs/overhaul/NOTIFY_SERVER.md item 3):
-- the stage-clear countdown (SwarmState ChoiceLeft) waits while a living player has an
-- upgrade panel open, at most Config.Stages.ChoiceHoldMaxSeconds per stage clear, so a
-- chooser (or endless queued levels) can never stall the team; with no panel it runs.
local Players = game:GetService("Players")
local player = Players.LocalPlayer
local friend = preview.addPlayer("HoldMate", 2)
preview.startServer()
preview.advance(1)
local RM = preview.server("RunManager")
local LUS = preview.server("LevelUpSystem")
local Stage = preview.server("StageManager")
local Spawner = preview.server("EnemySpawner")
local Config = preview.shared("Config")
local S = Config.Stages
local state = game:GetService("ReplicatedStorage"):FindFirstChild("SwarmState")
assert(S.ChoiceHoldMaxSeconds and S.ChoiceHoldMaxSeconds > 0, "Config.Stages.ChoiceHoldMaxSeconds set")
-- Notify payloads carry the UI lane routing (UI_STATE_CONTRACT section 3)
local pl = RM.NotifyPayload("THE PORTAL IS OPEN", nil, true, { Id = "portal.open", Class = "Info" })
assert(pl.Id == "portal.open" and pl.Lane == "Headline" and pl.Class == "Info", "tagged broadcast payload")
pl = RM.NotifyPayload("Not enough gold.", nil, nil, nil)
assert(pl.Id == "text:not enough gold." and pl.Lane == "Notice" and pl.Class == "Info", "default notice payload")
assert(RM.StartTeamRun({ player, friend }, "Duo", "Forest", player))
preview.advance(6)
local rp, mate = assert(RM.GetRunPlayer(player)), assert(RM.GetRunPlayer(friend))
local function tough()
	for _, r in ipairs({ rp, mate }) do
		r.Stats.MaxHP = 1e7
		RM.Heal(r, 1e7, true)
	end
end
local function clear()
	LUS.Cancel(rp)
	LUS.Cancel(mate)
	rp.PendingLevels, mate.PendingLevels = 0, 0
end
local function step(seconds)
	for _ = 1, math.max(1, math.floor(seconds / 0.1 + 0.5)) do
		tough()
		preview.advance(0.1)
	end
end
-- clear the stage: summon the boss, kill it, burn the surge, wait for the open portal
local function openPortal()
	tough()
	assert(Stage.DevActivate(), "portal boss summoned")
	step(0.3)
	local boss = assert(Spawner.Boss, "boss alive")
	Spawner.Damage(boss, 1e12, rp)
	for _ = 1, 400 do
		for _, e in ipairs(table.clone(Spawner.Active)) do
			Spawner.Kill(e, rp)
		end
		step(0.1)
		if Stage.GetPhase() == "Open" then
			break
		end
	end
	assert(Stage.GetPhase() == "Open", "the portal opened (phase " .. Stage.GetPhase() .. ")")
	clear()
end
local function left(): number
	return state and state:GetAttribute("ChoiceLeft") or -1
end
-- a group panel for the player while the stage-clear dialog is up (it outranks the dialog
-- on the client; the server opens it here as if it was open before the portal)
local function openChoice(levels)
	rp.PortalOffered = false
	rp.ProtectBudget = Config.LevelUp.ProtectBudgetSeconds
	LUS.QueueLevels(rp, levels)
	assert(rp.Offer and rp.Paused, "a group panel is open")
	assert(player:GetAttribute("ChoiceGroup") == true and not RM.IsFrozen(), "duo choice: the world is live")
end

-- 1) a panel open at the stage clear: the countdown waits for it
openPortal()
step(0.3)
local start = left()
assert(start >= S.ChoiceSeconds - 1, "the countdown starts full (" .. start .. ")")
openChoice(1)
step(3)
assert(Stage.GetPhase() == "Open", "the portal waits")
assert(left() == start, string.format("the countdown waits for an open choice (%d -> %d)", start, left()))
assert(state:GetAttribute("ChoiceLeftHeld") == true and Stage.AnyChoiceOpen(), "ChoiceLeftHeld published")
preview.log(string.format("hold: ChoiceLeft %d after 3 s with a panel open", left()))
-- the pick resolves the panel: the countdown resumes
for _ = 1, 12 do -- every round in the panel (gems flown in at the clear may add rounds)
	if not rp.Offer then break end
	preview.fireServerAs(player, "LevelUpChoose", 1, player:GetAttribute("ChoiceOfferId"))
end
assert(not rp.Offer, "the picks closed the panel")
step(2.2)
assert(left() <= start - 2 and state:GetAttribute("ChoiceLeftHeld") == false, "the countdown resumes after the pick (" .. left() .. ")")
-- the teammate decides; the chooser never answers: the countdown still ends the stage clear
preview.fireServerAs(friend, "PortalChoice", "Next")
step(S.ChoiceSeconds + 1)
assert(Stage.GetPhase() ~= "Open", "the portal resolved on its own after the hold")
step(3)
assert(Stage.GetStage() == 2, "on to stage 2")
preview.log("PASS hold while a panel is open, resume after the pick")

-- 2) bounded: panels kept open the whole time can hold it for ChoiceHoldMaxSeconds at most
openPortal()
step(0.3)
local t0 = RM.GetRunTime()
local resolved = nil
for _ = 1, math.floor((S.ChoiceSeconds + S.ChoiceHoldMaxSeconds + 8) / 0.1) do
	if not rp.Offer and Stage.GetPhase() == "Open" then
		openChoice(6) -- a fresh panel (full budget) every time one closes: the worst case
	end
	step(0.1)
	if Stage.GetPhase() ~= "Open" then
		resolved = RM.GetRunTime() - t0
		break
	end
end
assert(resolved, "the stage clear resolved although a panel was always open")
assert(resolved <= S.ChoiceSeconds + S.ChoiceHoldMaxSeconds + 1.5, string.format("bounded: resolved after %.1f s (cap %d)", resolved, S.ChoiceSeconds + S.ChoiceHoldMaxSeconds))
assert(resolved >= S.ChoiceSeconds + S.ChoiceHoldMaxSeconds - 1.5, string.format("it did wait the full hold (%.1f s)", resolved))
preview.log(string.format("bounded: always-open panels resolved the stage clear after %.1f s (ChoiceSeconds %d + hold cap %d)", resolved, S.ChoiceSeconds, S.ChoiceHoldMaxSeconds))
clear()
step(3)

-- 3) no panel: the plain countdown
openPortal()
step(0.3)
local t1 = RM.GetRunTime()
local plain = nil
for _ = 1, math.floor((S.ChoiceSeconds + 5) / 0.1) do
	step(0.1)
	if Stage.GetPhase() ~= "Open" then
		plain = RM.GetRunTime() - t1
		break
	end
end
assert(plain and plain <= S.ChoiceSeconds + 0.5, "no panel: the countdown is not held (" .. tostring(plain) .. ")")
preview.log(string.format("PASS portal hold: waits for open choices, capped at %d s, plain countdown %.1f s", S.ChoiceHoldMaxSeconds, plain))
