--[[
	NextGoal.lua
	The results screen's NEXT GOAL card: one clear reason to play again, picked from a
	player's save AFTER the run is settled (RunManager sends it in the RunResult payload).
	Display only: it never changes the save.

	Candidates (each with a progress share 0..1 and a weight):
	  - a hero bought with gold (the cheapest one not owned): "2,300 gold to unlock Mage"
	  - a hero earned by an achievement: "Reach stage 4 in one run to unlock Alchemist"
	  - the played hero's next mastery level: "340 XP to Knight Mastery 4"
	  - the next difficulty: "Win a Standard run to unlock Veteran"
	  - today's scored Daily Challenge, while it is unplayed
	The closest one wins (share + weight); a hero you can afford now always wins.

	NextGoal.Pick(data, opts) -> { Kind, Icon, Text, Sub?, Progress, ProgressText? } or nil
	  opts.Hero     the hero just played (mastery goal)
	  opts.RunGold  gold kept from this run (estimates "about N runs")
	  opts.Now      os.time() override (tests)
	Icon is an Icons name, or "hero:<CharacterId>" for a hero portrait icon.
]]

local Config = require(script.Parent.Config)
local CharacterData = require(script.Parent.CharacterData)
local AchievementData = require(script.Parent.AchievementData)
local DifficultyData = require(script.Parent.DifficultyData)
local MetaUpgradeData = require(script.Parent.MetaUpgradeData)
local CurseData = require(script.Parent.CurseData)

local NextGoal = {}

local function fmt(n: number): string
	local s = tostring(math.floor(n))
	local out = s:reverse():gsub("(%d%d%d)", "%1,"):reverse()
	return (out:gsub("^,", ""))
end

local function runsText(left: number, perRun: number): string?
	if perRun <= 0 or left <= 0 then
		return nil
	end
	local runs = math.ceil(left / perRun)
	if runs > 20 then
		return nil
	end
	return runs == 1 and "about 1 more run" or string.format("about %d more runs", runs)
end

-- How each achievement that unlocks a hero reads as a goal.
local ACH_TEXT: { [string]: string } = {
	QueenSlayer = "Beat the Scorpion Queen",
	DeepDelver = "Reach stage 4 in one run",
	FieldEngineer = "Open 3 Guarded Altars or seal 3 Bargains",
	Reaper = "Defeat 500 enemies in one run",
}

function NextGoal.Pick(data: any, opts: { Hero: string?, RunGold: number?, Now: number? }?): { [string]: any }?
	if type(data) ~= "table" then
		return nil
	end
	local o = opts or {}
	local owned = type(data.OwnedCharacters) == "table" and data.OwnedCharacters or {}
	local gold = math.max(0, tonumber(data.Gold) or 0)
	local candidates = {}
	local function add(goal: { [string]: any }, score: number)
		goal.Progress = math.clamp(tonumber(goal.Progress) or 0, 0, 1)
		goal.Score = score
		table.insert(candidates, goal)
	end

	-- 1. the cheapest hero sold for gold
	local cheapest = nil
	for _, id in ipairs(CharacterData.Order) do
		local def = CharacterData.Characters[id]
		if def and not owned[id] and not def.Unlock and (tonumber(def.Cost) or 0) > 0 then
			if not cheapest or def.Cost < cheapest.Cost then
				cheapest = def
			end
		end
	end
	if cheapest then
		local cost = cheapest.Cost
		local id = cheapest.Id or cheapest.Name
		if gold >= cost then
			add({ Kind = "BuyHero", Icon = "hero:" .. id, Text = string.format("You can unlock %s now!", cheapest.Name), Sub = "Visit CHARACTERS in the lobby", Progress = 1, ProgressText = string.format("%s / %s gold", fmt(gold), fmt(cost)) }, 3)
		else
			local left = cost - gold
			local share = gold / cost
			add({ Kind = "BuyHero", Icon = "hero:" .. id, Text = string.format("%s gold to unlock %s", fmt(left), cheapest.Name), Sub = runsText(left, tonumber(o.RunGold) or 0), Progress = share, ProgressText = string.format("%s / %s gold", fmt(gold), fmt(cost)) }, share + 0.15)
		end
	end

	-- 2. heroes earned by achievements (first one in roster order with a known goal)
	local ach = type(data.Achievements) == "table" and data.Achievements or {}
	local progress = type(ach.Progress) == "table" and ach.Progress or {}
	local unlocked = type(ach.Unlocked) == "table" and ach.Unlocked or {}
	for _, id in ipairs(CharacterData.Order) do
		local def = CharacterData.Characters[id]
		local achId = def and def.Unlock and def.Unlock.Achievement
		local adef = achId and AchievementData.Achievements[achId]
		if def and not owned[id] and adef and not unlocked[achId] and ACH_TEXT[achId] then
			local have = math.clamp(tonumber(progress[achId]) or 0, 0, adef.Goal)
			local share = have / math.max(1, adef.Goal)
			-- a one-off goal (beat a boss) has no partial progress: rank it as halfway
			local rank = adef.Goal <= 1 and 0.45 or share
			add({ Kind = "EarnHero", Icon = "hero:" .. id, Text = string.format("%s to unlock %s", ACH_TEXT[achId], def.Name), Progress = share, ProgressText = string.format("%s / %s", fmt(have), fmt(adef.Goal)) }, rank + 0.1)
			break
		end
	end

	-- 3. the played hero's next mastery level
	local heroId = o.Hero
	local hero = heroId and CharacterData.Characters[heroId]
	if hero then
		local h = type(data.Heroes) == "table" and data.Heroes[heroId] or nil
		local xp = type(h) == "table" and math.max(0, tonumber(h.XP) or 0) or 0
		local runs = type(h) == "table" and math.max(0, tonumber(h.Runs) or 0) or 0
		local level, into, need = MetaUpgradeData.MasteryFor(xp)
		if need > 0 then
			local left = need - into
			add({ Kind = "Mastery", Icon = "chevronsUp", Text = string.format("%s XP to %s Mastery %d", fmt(left), hero.Name, level + 1), Sub = runsText(left, runs > 0 and xp / runs or 0) or "More hero upgrades to buy", Progress = into / need, ProgressText = string.format("%s / %s XP", fmt(into), fmt(need)) }, into / need)
		end
	end

	-- 4. the next difficulty tier
	for _, tierId in ipairs(DifficultyData.Order) do
		local tier = DifficultyData.Tiers[tierId]
		if tier.Requires ~= "" and not DifficultyData.IsUnlocked(data, tierId) then
			local need = Config.Stages.WinMinStages
			local share, cleared = 0, 0
			if tier.Requires == "Standard" then
				-- BestStage is the furthest stage REACHED: stages cleared = reached - 1
				local best = type(data.Stats) == "table" and tonumber(data.Stats.BestStage) or 0
				cleared = math.clamp((best or 0) - 1, 0, need)
				share = math.clamp(cleared / need, 0, 0.95)
			end
			-- cleared all stages already (a run that went on, Endless or a Daily) but never
			-- returned through the portal: the bar used to read "5 / 5" with the tier still
			-- locked; say what is missing instead
			local done = tier.Requires == "Standard" and cleared >= need
			add({ Kind = "Difficulty", Icon = "crown", Text = string.format("Win a %s run (clear %d stages) to unlock %s", tier.Requires, need, tier.Name), Sub = done and "Then return through the portal (not Endless or Daily)" or nil, Progress = share, ProgressText = tier.Requires == "Standard" and (done and "Not won yet" or string.format("Best: %d / %d stages", cleared, need)) or nil }, share + 0.05)
			break
		end
	end

	-- 5. today's scored Daily Challenge
	local D = type(data.Daily) == "table" and data.Daily or {}
	local today = CurseData.DayOf(o.Now or os.time())
	if D.Day ~= today or D.Used ~= true then
		-- new players (first runs) are steered to heroes and mastery first
		local runs = type(data.Stats) == "table" and tonumber(data.Stats.Runs) or 0
		add({ Kind = "Daily", Icon = "calendar", Text = "Daily Challenge ready", Sub = "One scored try today", Progress = 1 }, (runs or 0) >= 3 and 0.6 or 0.3)
	end

	if #candidates == 0 then
		return nil
	end
	table.sort(candidates, function(a, b)
		return a.Score > b.Score
	end)
	local best = candidates[1]
	best.Score = nil
	return best
end

return NextGoal
