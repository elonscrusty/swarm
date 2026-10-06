-- challenges-regression: features 3, 5, 7 (docs/features/CHALLENGES.md) on the REAL server
-- (GameServer, every module), a solo run driven through the remotes:
--   1) stage 1: no champion (MinStage 2); a cursed chest (Chance forced to 1) states its
--      curse before the hold, keeps its chest price, pays one item once, then every
--      non-boss enemy is faster / harder hitting for Seconds and back to normal after
--   2) stage 1: Shrine of Trial: hold → trial wave; survive in the ring → ONE bonus pick
--      whose card set holds a card above Common (normal OfferId flow), exactly once
--   3) stage 2: a second trial walked out of → failed, no bonus pick
--   4) stage 2: the champion's chest is locked; walking close wakes the guard (name plate
--      attributes); a guard dying with no killer pays nothing and comes back (W-04); a
--      player kill unlocks the chest; one item, once
--   5) travel and MAIN MENU clean up (models, SwarmState attributes, enemy buffs)
--   6) the three switches off: nothing placed, nothing cursed, chests as before
-- Prints PASS / FAIL lines. Run: lune run tools/preview/runtime/main.luau -- --scene
-- challenges-regression --studio --device pc --out <json> --max-time 400 --set headless=on
local C = lib("common")
local Players = game:GetService("Players")
preview.startServer()
preview.advance(1)
C.startClient()
preview.advance(1)
local me = Players.LocalPlayer
local RM = preview.server("RunManager")
local SM = preview.server("StageManager")
local ES = preview.server("EnemySpawner")
local Loot = preview.server("LootSystem")
local Gold = preview.server("GoldSystem")
local MB = preview.server("MiniBoss")
local TS = preview.server("TrialShrine")
local CC = preview.server("CursedChest")
local ItemData = C.shared("ItemData")
local Config = C.shared("Config")
local state = C.state()
local advance = preview.advance
local fails = 0

local function check(ok: any, label: string)
	if ok then
		preview.log("PASS " .. label)
	else
		fails += 1
		preview.log("FAIL " .. label)
	end
end

-- only this batch's challenges run: the other features are switched off for the test
local mine = { MiniBosses = true, TrialShrine = true, CursedChests = true }
for k in pairs(Config.Features) do
	Config.Features[k] = mine[k] == true
end
Config.CursedChest.Chance = 1
-- the trial's mechanics are tested on stage 1, so its stage gate (Config.TrialShrine.MinStage,
-- 2 since BALANCE-2) is lowered here; section 5b checks the gate itself
local trialGate = Config.TrialShrine.MinStage or 1
Config.TrialShrine.MinStage = 1

local function itemCount(rp): number
	local n = 0
	for _, c in pairs(rp.Items or {}) do
		n += c
	end
	return n
end

local rp
local boostedSeen, boostedRare = 0, 0
local function levelUps()
	for _ = 1, 40 do
		if not rp or not rp.Offer then
			return
		end
		if rp.OfferBoosted then
			boostedSeen += 1
			for _, c in ipairs(rp.Offer) do
				if c.Rarity ~= "Common" then
					boostedRare += 1
					break
				end
			end
		end
		preview.remote("LevelUpChoose"):FireServer(1, rp.OfferSeq)
		advance(0.3)
	end
end
local function closeRewards()
	if rp and rp.RewardSeq then
		preview.remote("RewardClose"):FireServer(rp.RewardSeq)
	end
end
local function standAt(pos: Vector3)
	local root = rp.Root
	if root then
		root.CFrame = CFrame.new(pos + Vector3.new(0, 3, 0))
		rp.LastValidPos = root.Position
		rp.SpeedCheckTimer = 0
	end
end
local function hold(obj)
	-- a level-up panel opening mid-hold (gems picked up) cancels it ("paused"), like a
	-- player's release: try again after picking, as a player would
	local before = obj.Model:GetAttribute("State")
	for _ = 1, 3 do
		levelUps()
		closeRewards()
		standAt(obj.Pos + Vector3.new(2, 0, 0))
		advance(0.1)
		preview.remote("LootHold"):FireServer(obj.Id, true)
		for _ = 1, 8 do
			advance(0.25)
			standAt(obj.Pos + Vector3.new(2, 0, 0))
		end
		preview.remote("LootHold"):FireServer(obj.Id, false)
		advance(0.3)
		closeRewards()
		advance(0.3)
		levelUps()
		if obj.Model:GetAttribute("State") ~= before then
			break
		end
	end
end
local function nextStage()
	SM.DevNextStage()
	for _ = 1, 60 do
		advance(0.5)
		levelUps()
		closeRewards()
		if SM.GetPhase() == "Explore" then
			break
		end
	end
	if rp then
		rp.InvulnUntil = math.huge -- travel resets it (ReviveInvulnSeconds)
	end
end
local function cursedChest()
	for _, obj in ipairs(Loot.Objects()) do
		if obj.Model:GetAttribute("Cursed") == true then
			return obj
		end
	end
	return nil
end

preview.remote("StartRun"):FireServer("Solo")
advance(2)
rp = RM.GetRunPlayer(me)
if not rp then
	preview.log("FAIL no run player")
	return
end
levelUps()
rp.InvulnUntil = math.huge
Gold.AddRunGold(rp, 100000)
advance(0.5)

-- 1) cursed chest --------------------------------------------------------------------
check(MB.Get() == nil, "stage 1 has no champion (MinStage 2)")
local cursed = cursedChest()
check(cursed ~= nil, "a cursed chest is placed (Chance 1)")
if cursed then
	local base = ItemData.StagePrice(Config.Chests.Cost[cursed.Type], 1, Config.Chests.CostExponent)
	check(cursed.Price == base and cursed.Model:GetAttribute("Price") == base, string.format("cursed %s keeps its price (%d = %d)", cursed.Type, cursed.Price, base))
	check(cursed.Model:GetAttribute("Tradeoff") == CC.TradeoffText() and string.find(cursed.Model:GetAttribute("Tradeoff"), "Curse") ~= nil, "the curse is on the prompt before the hold: " .. tostring(cursed.Model:GetAttribute("Tradeoff")))
	check(cursed.Weights == Config.CursedChest.Weights[cursed.Type], "cursed chest rolls the better table")
	-- a sturdy test enemy far from the hero's weapons
	local probe = ES.Spawn("Skeleton", rp.Root.Position + Vector3.new(60, 0, 60), { Force = true })
	probe.MaxHP, probe.HP = 1e9, 1e9
	local speed0, dmg0, scale0 = probe.Speed, probe.Damage, probe.DmgScale
	local items0 = itemCount(rp)
	hold(cursed)
	check(itemCount(rp) == items0 + 1 and cursed.State == "Opened", "cursed chest pays one item")
	check(CC.Active() and (state:GetAttribute("CurseLeft") or 0) > 55, "curse on, CurseLeft=" .. tostring(state:GetAttribute("CurseLeft")))
	advance(0.5)
	check(math.abs(probe.Speed - speed0 * Config.CursedChest.EnemySpeedMult) < 1e-6 and math.abs(probe.Damage - dmg0 * Config.CursedChest.EnemyDamageMult) < 1e-6
		and math.abs(probe.DmgScale - scale0 * Config.CursedChest.EnemyDamageMult) < 1e-6, string.format("enemies stronger: speed %.2f→%.2f dmg %.2f→%.2f", speed0, probe.Speed, dmg0, probe.Damage))
	local late = ES.Spawn("Slime", rp.Root.Position + Vector3.new(-60, 0, 60), { Force = true })
	local lateSpeed = late and late.Speed or 0
	advance(0.2)
	check(late and late.Speed > lateSpeed * 1.1, "an enemy spawned during the curse is buffed too")
	hold(cursed)
	check(itemCount(rp) == items0 + 1, "an opened cursed chest pays nothing again")
	for _ = 1, 64 do
		advance(1)
		levelUps()
		closeRewards()
		probe.HP = 1e9
	end
	check(not CC.Active() and state:GetAttribute("CurseLeft") == 0, "the curse ends after its seconds")
	check(probe.Alive and math.abs(probe.Speed - speed0) < 1e-6 and math.abs(probe.Damage - dmg0) < 1e-6 and math.abs(probe.DmgScale - scale0) < 1e-6, "enemy stats back to normal after the curse")
	ES.Despawn(probe)
end

-- 2) Shrine of Trial: won ------------------------------------------------------------
local trial = TS.Get()
check(trial ~= nil and trial.Obj.Model:GetAttribute("State") == "Ready", "a Shrine of Trial is placed (state Ready)")
if trial then
	check(string.find(tostring(trial.Obj.Model:GetAttribute("Tradeoff")), "no reward") ~= nil, "the trial's risk is on the prompt")
	local bonus0 = rp.BonusPicks or 0
	boostedSeen, boostedRare = 0, 0
	hold(trial.Obj)
	check(trial.Phase == "Running" and (state:GetAttribute("TrialLeft") or 0) >= Config.TrialShrine.Seconds - 2 and me:GetAttribute("TrialIn") == true, "hold starts the trial, TrialLeft=" .. tostring(state:GetAttribute("TrialLeft")))
	local maxFoes = 0
	for _ = 1, Config.TrialShrine.Seconds + 4 do
		standAt(trial.Pos + Vector3.new(3, 0, 0))
		advance(1)
		maxFoes = math.max(maxFoes, #trial.Foes)
		if trial.Phase ~= "Running" then
			break
		end
		if rp.Offer then
			-- a normal level-up mid-trial: pick it (the solo panel freezes the trial too)
			levelUps()
		end
	end
	preview.log(string.format("trial foes alive at most: %d (want <= %d + elites)", maxFoes, Config.TrialShrine.Alive))
	check(maxFoes > 0 and maxFoes <= Config.TrialShrine.Alive + 4, "trial wave kept around the shrine")
	check(trial.Phase == "Won", "surviving in the ring wins: " .. tostring(trial.Phase))
	check((rp.BonusPicks or 0) + boostedSeen >= bonus0 + 1, "one bonus pick queued")
	advance(0.5)
	levelUps()
	check(boostedSeen >= 1 and boostedRare >= 1, string.format("the bonus card set holds a card above Common (sets %d, with rare %d)", boostedSeen, boostedRare))
	check((rp.BonusPicks or 0) == bonus0, "the bonus pick is used up by its pick")
	check(state:GetAttribute("TrialLeft") == -1 and me:GetAttribute("TrialIn") == nil, "trial attributes cleared")
	hold(trial.Obj)
	check(trial.Phase == "Won" and (rp.BonusPicks or 0) == bonus0, "a finished shrine cannot start again")
end

-- 3) + 4) stage 2 --------------------------------------------------------------------
local oldTrialModel = trial and trial.Obj.Model
nextStage()
check(SM.GetStage() == 2, "stage 2")
check(oldTrialModel == nil or oldTrialModel.Parent == nil, "travel removed the old shrine")
local trial2 = TS.Get()
if trial2 then
	local bonus0 = rp.BonusPicks or 0
	hold(trial2.Obj)
	check(trial2.Phase == "Running", "second trial started")
	for _ = 1, 6 do
		standAt(trial2.Pos + Vector3.new(Config.TrialShrine.Radius + 15, 0, 0))
		advance(1)
		levelUps()
		if trial2.Phase ~= "Running" then
			break
		end
	end
	check(trial2.Phase == "Failed" and (rp.BonusPicks or 0) == bonus0, "leaving the ring fails the trial with no reward")
else
	check(false, "stage 2 has a Shrine of Trial (both placed encounters fit MaxActive)")
end

local mb = MB.Get()
check(mb ~= nil, "stage 2 has a champion's chest")
if mb then
	local chest = mb.Chest
	check(chest.State == "Locked" and chest.Price == 0, "champion's chest is free and locked")
	local items0 = itemCount(rp)
	hold(chest)
	check(itemCount(rp) == items0 and chest.State == "Locked", "a locked chest cannot be opened")
	standAt(chest.Pos + Vector3.new(Config.MiniBoss.WakeRadius - 8, 0, 0))
	advance(0.5)
	local g = mb.Guard
	check(g ~= nil and g.Alive and g.Elite, "walking close wakes the champion")
	if g then
		check(state:GetAttribute("MiniBossId") == g.Id and g.Part:GetAttribute("MiniBoss") == mb.Name and g.Part:GetAttribute("HPFrac") ~= nil, "name plate / HP bar attributes: " .. tostring(mb.Name))
		check(g.MaxHP > 0 and g.Guard == chest.Id, "champion buffed and guarding")
		-- W-04: dies with no killer → no reward, stays locked, comes back later
		ES.Kill(g, nil)
		advance(0.2)
		check(chest.State == "Locked" and mb.Phase == "Dormant" and itemCount(rp) == items0 and state:GetAttribute("MiniBossId") == 0, "no killer: nothing paid, chest stays locked")
		check(g.Part:GetAttribute("MiniBoss") == nil, "the pool body forgets the name plate")
		local t0 = RM.GetRunTime()
		for _ = 1, 30 do
			standAt(chest.Pos + Vector3.new(6, 0, 0))
			advance(0.5)
			levelUps()
			closeRewards()
			if mb.Phase == "Awake" then
				break
			end
		end
		preview.log(string.format("champion back after %.1f s of run time (RetrySeconds %d)", RM.GetRunTime() - t0, Config.MiniBoss.RetrySeconds))
		local g2 = mb.Guard
		check(g2 ~= nil and g2.Alive and mb.Phase == "Awake", "the champion comes back")
		if g2 then
			ES.Kill(g2, rp)
			advance(0.2)
			check(chest.State == "Ready" and mb.Phase == "Open", "a player kill unlocks the chest")
			hold(chest)
			check(itemCount(rp) == items0 + 1 and chest.State == "Opened", "champion's chest pays one item")
			hold(chest)
			check(itemCount(rp) == items0 + 1, "and only once")
		end
	end
end

-- 5) MAIN MENU mid-curse / mid-trial cleans up --------------------------------------
local c2 = cursedChest()
if c2 then
	hold(c2)
end
local mbModel = mb and mb.Chest.Model
preview.remote("AbandonRun"):FireServer()
advance(2)
check(not RM.IsRunning(), "run ended")
check(MB.Get() == nil and TS.Get() == nil and not CC.Active(), "encounters cleaned up at run end")
check((state:GetAttribute("MiniBossId") or 0) == 0 and (state:GetAttribute("TrialLeft") or -1) == -1 and (state:GetAttribute("CurseLeft") or 0) == 0, "SwarmState attributes cleared")
check(mbModel == nil or mbModel.Parent == nil, "chest models removed")

-- 5b) stage gate: with the shipped MinStage there is no Shrine of Trial on stage 1 --------
Config.TrialShrine.MinStage = trialGate
preview.remote("StartRun"):FireServer("Solo")
advance(2)
check(trialGate <= 1 or TS.Get() == nil, "MinStage " .. tostring(trialGate) .. ": no Shrine of Trial on stage 1")
preview.remote("AbandonRun"):FireServer()
advance(2)
check(not RM.IsRunning(), "gate run ended")

-- 6) switches off --------------------------------------------------------------------
Config.Features.MiniBosses, Config.Features.TrialShrine, Config.Features.CursedChests = false, false, false
preview.remote("StartRun"):FireServer("Solo")
advance(2)
rp = RM.GetRunPlayer(me)
levelUps()
rp.InvulnUntil = math.huge
nextStage()
check(MB.Get() == nil and TS.Get() == nil and cursedChest() == nil, "switches off: no champion, no trial, no cursed chest")
local sane = true
for _, obj in ipairs(Loot.Objects()) do
	if obj.Weights or obj.OnOpened or obj.OnComplete or obj.OnGuardDown then
		sane = false
	end
end
check(sane, "switches off: every loot object is a plain one")
preview.remote("AbandonRun"):FireServer()
advance(2)
preview.log(fails == 0 and "PASS challenges-regression" or string.format("FAIL challenges-regression (%d)", fails))
