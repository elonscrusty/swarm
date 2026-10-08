--[[
	MetaData.lua
	Data for the META features (docs/features/META.md). Pure data and maths: the server
	(MetaService) grants, the lobby screens show.

	  Weekly challenge (21, Config.Features.WeeklyChallenge)
	    WeekOf(unix), WeekSecondsLeft(unix), Weekly(week) → { Week, Seed, Hero, Curses, Arena }
	    One fixed hero, two curses and the first world per UTC week (Monday 00:00 UTC), from
	    a deterministic seed: every server and player gets the same setup.
	  Season track (22, Config.Features.SeasonTrack)
	    Season(unix) → the season running now (Config.Season dates) or nil
	    SeasonReward(tier) → { Kind = "Gold" | "Title" | "Nameplate", Gold?, Id? }
	  Login streak (25, Config.Features.LoginStreak)
	    StreakGold(day), StreakMilestones, StreakNext(lastDay, streak, today)
	  Titles (23, Config.Features.Titles)
	    Titles: the milestone titles (earned by play; achievement and level-track titles
	    stay in AchievementData / AccountData)
	  Nameplates: the earned nameplate frames (season / streak rewards)

	Rewards here are coins (gold) and cosmetics only, never power.
]]

local Config = require(script.Parent.Config)
local CurseData = require(script.Parent.CurseData)

local MetaData = {}

------------------------------------------------------------------------------------------
-- Weekly challenge
------------------------------------------------------------------------------------------

-- Heroes the weekly may pick (a fixed list, so a hero added later never changes a week
-- that is already running). The hero is lent for the run: owning it is not needed.
MetaData.WeeklyHeroes = { "Knight", "Mage", "Rogue", "Priest", "Ranger", "Alchemist", "Engineer", "Necromancer" }
MetaData.WeeklyCurseCount = 2
MetaData.WeeklyMode = "Weekly"

-- The UTC week number of a unix time: weeks start on Monday 00:00 UTC (day 0 was a Thursday).
function MetaData.WeekOf(unix: number): number
	return (CurseData.DayOf(unix) + 3) // 7
end

-- The first UTC day number of a week.
function MetaData.WeekFirstDay(week: number): number
	return week * 7 - 3
end

-- Seconds until the next week starts.
function MetaData.WeekSecondsLeft(unix: number): number
	local nextStart = MetaData.WeekFirstDay(MetaData.WeekOf(unix) + 1) * 86400
	return math.max(0, nextStart - math.floor(unix))
end

export type Weekly = { Week: number, Seed: number, Hero: string, Curses: { string }, Arena: string, Date: string }

function MetaData.Weekly(week: number): Weekly
	local seed = (week * 104723 + 7727) % 2147483647
	local rng = Random.new(seed)
	local hero = MetaData.WeeklyHeroes[rng:NextInteger(1, #MetaData.WeeklyHeroes)]
	local bag = table.clone(CurseData.Order)
	for i = #bag, 2, -1 do
		local j = rng:NextInteger(1, i)
		bag[i], bag[j] = bag[j], bag[i]
	end
	local curses = {}
	for i = 1, math.min(MetaData.WeeklyCurseCount, #bag) do
		table.insert(curses, bag[i])
	end
	local arena = CurseData.Arenas[rng:NextInteger(1, #CurseData.Arenas)]
	return {
		Week = week,
		Seed = seed,
		Hero = hero,
		Curses = CurseData.Sanitize(curses) or {},
		Arena = arena,
		Date = CurseData.DateText(MetaData.WeekFirstDay(week)),
	}
end

------------------------------------------------------------------------------------------
-- Season track
------------------------------------------------------------------------------------------

-- Day number of "YYYY-MM-DD" (UTC), or nil.
function MetaData.DayOfDate(text: string): number?
	local y, m, d = string.match(text, "^(%d%d%d%d)%-(%d%d)%-(%d%d)$")
	if not y then
		return nil
	end
	local yy, mm, dd = tonumber(y) :: number, tonumber(m) :: number, tonumber(d) :: number
	if mm <= 2 then
		yy -= 1
	end
	local era = (yy >= 0 and yy or yy - 399) // 400
	local yoe = yy - era * 400
	local mp = mm > 2 and mm - 3 or mm + 9
	local doy = (153 * mp + 2) // 5 + dd - 1
	local doe = yoe * 365 + yoe // 4 - yoe // 100 + doy
	return era * 146097 + doe - 719468
end

export type Season = { Id: string, Name: string, Start: number, End: number }

-- The season running at `unix` (Config.Season.List: Start ≤ day ≤ End), or nil.
function MetaData.Season(unix: number): Season?
	local S = (Config :: any).Season
	if type(S) ~= "table" or type(S.List) ~= "table" then
		return nil
	end
	local day = CurseData.DayOf(unix)
	for _, s in ipairs(S.List) do
		local a, b = MetaData.DayOfDate(s.Start or ""), MetaData.DayOfDate(s.End or "")
		if a and b and day >= a and day <= b and type(s.Id) == "string" and s.Id ~= "" then
			return { Id = s.Id, Name = s.Name or s.Id, Start = a, End = b }
		end
	end
	return nil
end

function MetaData.SeasonTiers(): number
	return math.max(1, math.floor(tonumber(((Config :: any).Season or {}).Tiers) or 30))
end

function MetaData.SeasonXPPerTier(): number
	return math.max(1, math.floor(tonumber(((Config :: any).Season or {}).XPPerTier) or 400))
end

-- Tiers reached with this much season XP (0..SeasonTiers).
function MetaData.TierFor(xp: number): number
	return math.clamp(math.floor((tonumber(xp) or 0) / MetaData.SeasonXPPerTier()), 0, MetaData.SeasonTiers())
end

export type Reward = { Kind: string, Gold: number?, Id: string? }

-- Cosmetic tiers (every other tier pays gold). An item you already own pays DupeGold.
MetaData.SeasonCosmetics = {
	[5] = { Kind = "Nameplate", Id = "Nameplate_Ember" },
	[10] = { Kind = "Title", Id = "Title_Trailblazer" },
	[15] = { Kind = "Nameplate", Id = "Nameplate_Frost" },
	[20] = { Kind = "Title", Id = "Title_Seasoned" },
	[25] = { Kind = "Nameplate", Id = "Nameplate_Royal" },
	[30] = { Kind = "Title", Id = "Title_Season Champion" },
}
MetaData.DupeGold = 250

function MetaData.SeasonReward(tier: number): Reward
	local c = MetaData.SeasonCosmetics[tier]
	if c then
		return { Kind = c.Kind, Id = c.Id }
	end
	return { Kind = "Gold", Gold = 100 + 10 * math.max(0, tier) }
end

------------------------------------------------------------------------------------------
-- Login streak
------------------------------------------------------------------------------------------

MetaData.StreakCycle = { 50, 75, 100, 125, 150, 200, 300 } -- gold for streak day 1..7, then repeats
MetaData.StreakGrace = 1 -- missed days forgiven (1 = one missed day keeps the streak)
MetaData.StreakMilestones = {
	{ Day = 7, Kind = "Title", Id = "Title_Faithful" },
	{ Day = 14, Kind = "Nameplate", Id = "Nameplate_Dawn" },
	{ Day = 30, Kind = "Title", Id = "Title_Devoted" },
}

function MetaData.StreakGold(day: number): number
	local n = #MetaData.StreakCycle
	return MetaData.StreakCycle[((math.max(1, day) - 1) % n) + 1]
end

-- What a claim today does: (canClaim, newStreak). lastDay = the day of the last claim (0 =
-- never), streak = the streak after that claim.
function MetaData.StreakNext(lastDay: number, streak: number, today: number): (boolean, number)
	if lastDay >= today then
		return false, streak
	end
	local gap = today - lastDay
	if lastDay > 0 and gap <= 1 + MetaData.StreakGrace then
		return true, streak + 1
	end
	return true, 1
end

------------------------------------------------------------------------------------------
-- Titles and nameplates (earned by play)
------------------------------------------------------------------------------------------

-- Milestone titles: Id (CosmeticData id, "Title_" .. Name), Name (the text shown), How.
MetaData.Titles = {
	{ Id = "Title_Collector", Name = "Collector", How = "Collection book half full" },
	{ Id = "Title_Archivist", Name = "Archivist", How = "Collection book complete" },
	{ Id = "Title_Sigil Seeker", Name = "Sigil Seeker", How = "Own 6 Sigils" },
	{ Id = "Title_Sigil Keeper", Name = "Sigil Keeper", How = "Own every Sigil" },
	{ Id = "Title_Weekly Warrior", Name = "Weekly Warrior", How = "Clear 3 stages in a weekly challenge" },
	{ Id = "Title_Brothers in Arms", Name = "Brothers in Arms", How = "Clear 3 stages in a Duo or Trio run" },
	{ Id = "Title_Faithful", Name = "Faithful", How = "Log in 7 days in a row" },
	{ Id = "Title_Devoted", Name = "Devoted", How = "Log in 30 days in a row" },
	{ Id = "Title_Trailblazer", Name = "Trailblazer", How = "Season tier 10" },
	{ Id = "Title_Seasoned", Name = "Seasoned", How = "Season tier 20" },
	{ Id = "Title_Season Champion", Name = "Season Champion", How = "Season tier 30" },
	-- next batch (docs/next/): the Starter Bundle, invites and the Roblox group; each is
	-- granted by its own server module (StarterBundle, InviteRewards, GroupBonus); Feature =
	-- the Config.Features switch: while it is off nobody can earn the title, so the menu hides it
	-- (unless the player already owns it)
	{ Id = "Title_Pioneer", Name = "Pioneer", How = "Comes with the Starter Bundle", Feature = "StarterBundle" },
	{ Id = "Title_Recruiter", Name = "Recruiter", How = "Invite a new friend who finishes a run", Feature = "InviteRewards" },
	{ Id = "Title_Group Member", Name = "Group Member", How = "Join our Roblox group", Feature = "GroupBonus" },
}
MetaData.TitleById = {}
for _, t in ipairs(MetaData.Titles) do
	MetaData.TitleById[t.Id] = t
end

-- The title id for a shown title text.
function MetaData.TitleId(name: string): string
	return "Title_" .. name
end

-- Nameplate frames (the plate's edge colour under the name).
MetaData.Nameplates = {
	{ Id = "Nameplate_Ember", Name = "Ember", Color = Color3.fromRGB(240, 130, 70), How = "Season tier 5" },
	{ Id = "Nameplate_Frost", Name = "Frost", Color = Color3.fromRGB(140, 200, 255), How = "Season tier 15" },
	{ Id = "Nameplate_Royal", Name = "Royal", Color = Color3.fromRGB(190, 140, 255), How = "Season tier 25" },
	{ Id = "Nameplate_Dawn", Name = "Dawn", Color = Color3.fromRGB(255, 214, 120), How = "Login streak of 14 days" },
}
MetaData.NameplateById = {}
for _, n in ipairs(MetaData.Nameplates) do
	MetaData.NameplateById[n.Id] = n
end

-- The CosmeticData entries this module adds (CosmeticData requires this module).
function MetaData.CosmeticEntries(): { { [string]: any } }
	local out = {}
	for _, t in ipairs(MetaData.Titles) do
		table.insert(out, { Id = t.Id, Kind = "Title", Name = t.Name, Source = "Earned", Condition = t.How, Feature = t.Feature })
	end
	for _, n in ipairs(MetaData.Nameplates) do
		table.insert(out, { Id = n.Id, Kind = "Nameplate", Name = n.Name, Source = "Earned", Condition = n.How })
	end
	return out
end

-- "3d 4h" / "5h 12m" / "8m" for a number of seconds.
function MetaData.TimeText(seconds: number): string
	seconds = math.max(0, math.floor(seconds))
	local d, h, m = seconds // 86400, (seconds % 86400) // 3600, (seconds % 3600) // 60
	if d > 0 then
		return string.format("%dd %dh", d, h)
	elseif h > 0 then
		return string.format("%dh %dm", h, m)
	end
	return string.format("%dm", math.max(1, m))
end

return MetaData
