--[[
	CurseData.lua
	Run modifiers ("Curses") and the Daily Challenge, as pure data + pure functions so the
	server (RunModifiers.lua), the lobby (MenuCurses / MenuDaily) and the HUD agree.

	Curses: before a run the starter toggles up to MaxActive curses. Every curse makes the
	run harder for the WHOLE team and adds its Gold share to the run's gold multiplier
	(additive: two +20% curses = +40%). They are chosen in the lobby (remote SetCurses,
	validated by the server: known ids, no duplicates, at most MaxActive) and fixed when the
	run begins. Nothing is bought: curses are free and only ever make a run harder.

	  Effect fields (read by the server):
	    EnemySpeed     multiplier on normal enemy speed (bosses keep their patterns)
	    MaxHP          multiplier on the heroes' max HP (stat sheet, after everything else)
	    SpawnMult      multiplier on the live enemy target and mini-wave size (the enemy cap
	                   Config.Enemies.MaxLive still holds)
	    NoHealPickups  no Roast Chicken floor pickups drop
	    Might          multiplier on damage dealt; DamageTaken: multiplier on damage taken
	    EliteChance    multiplier on the random elite chance

	Daily Challenge: one fixed setup per UTC day (CurseData.Daily(day)): the first arena,
	the arena tour and the boss order of the run, a fixed curse set and a fixed starting
	bonus. Solo only. The first daily run of the day is the scored attempt; later ones are
	practice (unscored). Score = stages cleared, then time (CurseData.DailyScore).
]]

local CurseData = {}

CurseData.MaxActive = 3

CurseData.Order = { "Frenzy", "Fragile", "Horde", "Famine", "GlassCannon", "EliteSurge" }

export type Curse = {
	Id: string,
	Name: string,
	Icon: string, -- client Icons name
	Short: string, -- one line for chips / cards
	Text: string, -- full description
	Gold: number, -- added to the run gold multiplier (0.2 = +20%)
	EnemySpeed: number?,
	MaxHP: number?,
	SpawnMult: number?,
	NoHealPickups: boolean?,
	Might: number?,
	DamageTaken: number?,
	EliteChance: number?,
}

CurseData.Curses = {
	Frenzy = {
		Id = "Frenzy",
		Name = "Frenzy",
		Icon = "curse_Frenzy",
		Short = "Enemies +25% speed",
		Text = "The swarm moves 25% faster.",
		Gold = 0.20,
		EnemySpeed = 1.25,
	},
	Fragile = {
		Id = "Fragile",
		Name = "Fragile",
		Icon = "curse_Fragile",
		Short = "-30% max HP",
		Text = "Heroes have 30% less max HP.",
		Gold = 0.20,
		MaxHP = 0.7,
	},
	Horde = {
		Id = "Horde",
		Name = "Horde",
		Icon = "curse_Horde",
		Short = "+40% enemies",
		Text = "40% more enemies at once and bigger waves.",
		Gold = 0.25,
		SpawnMult = 1.4,
	},
	Famine = {
		Id = "Famine",
		Name = "Famine",
		Icon = "curse_Famine",
		Short = "No healing pickups",
		Text = "Roast chickens never drop.",
		Gold = 0.15,
		NoHealPickups = true,
	},
	GlassCannon = {
		Id = "GlassCannon",
		Name = "Glass Cannon",
		Icon = "curse_GlassCannon",
		Short = "+30% damage dealt and taken",
		Text = "You hit 30% harder, and so does the swarm.",
		Gold = 0.15,
		Might = 1.3,
		DamageTaken = 1.3,
	},
	EliteSurge = {
		Id = "EliteSurge",
		Name = "Elite Surge",
		Icon = "curse_EliteSurge",
		Short = "Elites 3x as often",
		Text = "Random elites appear three times as often.",
		Gold = 0.30,
		EliteChance = 3,
	},
} :: { [string]: Curse }

-- A clean list from anything a client sent: known ids, no duplicates, at most MaxActive,
-- in CurseData.Order. Returns nil when the input is not a list of strings at all.
function CurseData.Sanitize(list: any): { string }?
	if type(list) ~= "table" then
		return nil
	end
	local want: { [string]: boolean } = {}
	local n = 0
	for k, v in pairs(list) do
		if type(k) ~= "number" or type(v) ~= "string" or #v > 32 then
			return nil
		end
		n += 1
		if n > 16 then
			return nil
		end
		if CurseData.Curses[v] then
			want[v] = true
		end
	end
	local out = {}
	for _, id in ipairs(CurseData.Order) do
		if want[id] and #out < CurseData.MaxActive then
			table.insert(out, id)
		end
	end
	return out
end

-- "Frenzy,Horde" <-> { "Frenzy", "Horde" } (attributes carry the string form).
function CurseData.ToString(list: { string }): string
	return table.concat(list, ",")
end

function CurseData.FromString(s: any): { string }
	if type(s) ~= "string" or s == "" then
		return {}
	end
	return CurseData.Sanitize(string.split(s, ",")) or {}
end

-- The run gold multiplier of a curse set (1 = no curses).
function CurseData.GoldMult(list: { string }): number
	local m = 1
	for _, id in ipairs(list) do
		local c = CurseData.Curses[id]
		if c then
			m += c.Gold
		end
	end
	return m
end

-- "+45%" for a gold multiplier.
function CurseData.GoldText(mult: number): string
	return string.format("+%d%%", math.floor((mult - 1) * 100 + 0.5))
end

-- Combined effects of a curse set (multipliers start at 1).
function CurseData.Effects(list: { string })
	local e = { EnemySpeed = 1, MaxHP = 1, SpawnMult = 1, NoHealPickups = false, Might = 1, DamageTaken = 1, EliteChance = 1 }
	for _, id in ipairs(list) do
		local c = CurseData.Curses[id]
		if c then
			e.EnemySpeed *= c.EnemySpeed or 1
			e.MaxHP *= c.MaxHP or 1
			e.SpawnMult *= c.SpawnMult or 1
			e.Might *= c.Might or 1
			e.DamageTaken *= c.DamageTaken or 1
			e.EliteChance *= c.EliteChance or 1
			e.NoHealPickups = e.NoHealPickups or c.NoHealPickups == true
		end
	end
	return e
end

------------------------------------------------------------------------------------------
-- Daily Challenge
------------------------------------------------------------------------------------------

CurseData.DailyCurseCount = 2
CurseData.DailyMode = "Daily"

-- Starting bonuses of the daily (one per day; run-only, the same for every player).
CurseData.BonusOrder = { "Armory", "Treasure", "HeadStart", "SecondWind" }
CurseData.Bonuses = {
	Armory = { Id = "Armory", Name = "Armory", Icon = "opt_Armory", Text = "Start with a second weapon: %s" },
	Treasure = { Id = "Treasure", Name = "Treasure", Icon = "reward_ChestLarge", Text = "Start with two items: %s" },
	HeadStart = { Id = "HeadStart", Name = "Head Start", Icon = "opt_HeadStart", Text = "Start at level 4" },
	SecondWind = { Id = "SecondWind", Name = "Second Wind", Icon = "revive", Text = "One extra life this run" },
}
-- the pools the seed picks from (base weapons / common items every hero can use)
CurseData.ArmoryWeapons = { "MagicOrb", "Knives", "Garlic", "HolyWater", "Lightning", "Axe", "Boomerang", "Spear", "Crossbow", "FrostNova" }
CurseData.TreasureItems = { "Whetstone", "QuickGloves", "SwiftFeather", "HeartyBread", "Bandage", "Lodestone", "KeenLens" }
CurseData.HeadStartLevel = 4

CurseData.Arenas = { "Forest", "Ruins", "Swamp", "Snow", "Desert", "Lava" }
CurseData.Bosses = { "ScorpionQueen", "MothMatriarch", "RhinoWarlord", "HiveMother" }
-- From this UTC day on, the daily route also uses the two newer bosses. Days before it keep
-- the old list so a day's route never changes after players have scored on it.
CurseData.BossesFromDay = 20729 -- 2026-10-03
CurseData.BossesLater = { "ScorpionQueen", "MothMatriarch", "RhinoWarlord", "HiveMother", "BriarSentinel", "FrostboundColossus" }
CurseData.DailyStages = 12 -- arenas / bosses planned ahead (the plan repeats after this)

-- The UTC day number of a unix time (days since 1970-01-01).
function CurseData.DayOf(unix: number): number
	return math.floor(unix / 86400)
end

-- Seconds until the next UTC midnight.
function CurseData.SecondsLeft(unix: number): number
	return 86400 - (math.floor(unix) % 86400)
end

-- "2026-10-02" for a day number (proleptic Gregorian, civil-from-days).
function CurseData.DateText(day: number): string
	local z = day + 719468
	local era = (z >= 0 and z or z - 146096) // 146097
	local doe = z - era * 146097
	local yoe = (doe - doe // 1460 + doe // 36524 - doe // 146096) // 365
	local y = yoe + era * 400
	local doy = doe - (365 * yoe + yoe // 4 - yoe // 100)
	local mp = (5 * doy + 2) // 153
	local d = doy - (153 * mp + 2) // 5 + 1
	local m = mp < 10 and mp + 3 or mp - 9
	if m <= 2 then
		y += 1
	end
	return string.format("%04d-%02d-%02d", y, m, d)
end

local function shuffled(list: { string }, rng: Random): { string }
	local bag = table.clone(list)
	for i = #bag, 2, -1 do
		local j = rng:NextInteger(1, i)
		bag[i], bag[j] = bag[j], bag[i]
	end
	return bag
end

-- A plan of n entries from shuffled bags of `pool`, never the same entry twice in a row.
local function plan(pool: { string }, n: number, rng: Random, first: string?): { string }
	local out: { string } = {}
	if first then
		table.insert(out, first)
	end
	while #out < n do
		local bag = shuffled(pool, rng)
		if #bag > 1 and bag[1] == out[#out] then
			bag[1], bag[#bag] = bag[#bag], bag[1]
		end
		for _, id in ipairs(bag) do
			if #out < n then
				table.insert(out, id)
			end
		end
	end
	return out
end

export type Daily = {
	Day: number,
	Seed: number,
	Date: string,
	Arenas: { string }, -- stage n's arena
	Bosses: { string }, -- stage n's boss (stage 1 is always the Scorpion Queen)
	Curses: { string },
	Bonus: string,
	BonusWeapon: string?,
	BonusItems: { string }?,
}

-- The fixed setup of a UTC day: the same for every server and every player.
function CurseData.Daily(day: number): Daily
	local seed = (day * 7919 + 104729) % 2147483647
	local rng = Random.new(seed)
	local arenas = plan(CurseData.Arenas, CurseData.DailyStages, rng)
	local bosses = plan(day >= CurseData.BossesFromDay and CurseData.BossesLater or CurseData.Bosses, CurseData.DailyStages, rng, "ScorpionQueen")
	local curses = {}
	for _, id in ipairs(shuffled(CurseData.Order, rng)) do
		if #curses < CurseData.DailyCurseCount then
			table.insert(curses, id)
		end
	end
	curses = CurseData.Sanitize(curses) or {}
	local bonus = CurseData.BonusOrder[rng:NextInteger(1, #CurseData.BonusOrder)]
	local d: Daily = {
		Day = day,
		Seed = seed,
		Date = CurseData.DateText(day),
		Arenas = arenas,
		Bosses = bosses,
		Curses = curses,
		Bonus = bonus,
	}
	if bonus == "Armory" then
		d.BonusWeapon = CurseData.ArmoryWeapons[rng:NextInteger(1, #CurseData.ArmoryWeapons)]
	elseif bonus == "Treasure" then
		local items = shuffled(CurseData.TreasureItems, rng)
		d.BonusItems = { items[1], items[2] }
	end
	return d
end

-- The starting bonus in one line ("Start with a second weapon: Spear").
function CurseData.BonusText(d: Daily, nameOf: ((string) -> string)?): string
	local def = CurseData.Bonuses[d.Bonus]
	if not def then
		return ""
	end
	local function name(id: string): string
		if nameOf then
			return nameOf(id)
		end
		-- "HolyWater" -> "Holy Water"
		return (string.gsub(id, "(%l)(%u)", "%1 %2"))
	end
	if d.Bonus == "Armory" then
		return string.format(def.Text, name(d.BonusWeapon or "?"))
	elseif d.Bonus == "Treasure" then
		local items = d.BonusItems or {}
		return string.format(def.Text, name(items[1] or "?") .. " + " .. name(items[2] or "?"))
	end
	return def.Text
end

--[[
	Daily score as one integer (OrderedDataStore values are integers, higher = better):
	stages cleared first; then, with at least one stage cleared, the FASTER the last clear
	the better (the run time when the last boss died); with none cleared, the LONGER you
	survived the better. Times are clamped to MaxTime seconds.
]]
CurseData.MaxTime = 99999

function CurseData.DailyScore(cleared: number, clearTime: number, survived: number): number
	cleared = math.clamp(math.floor(cleared), 0, 999)
	if cleared > 0 then
		return cleared * 100000 + (CurseData.MaxTime - math.clamp(math.floor(clearTime), 0, CurseData.MaxTime))
	end
	return math.clamp(math.floor(survived), 0, CurseData.MaxTime)
end

-- (stages cleared, seconds, "cleared" | "survived") of a score.
function CurseData.DecodeScore(score: number): (number, number, string)
	score = math.max(0, math.floor(score))
	local cleared = score // 100000
	local rest = score % 100000
	if cleared > 0 then
		return cleared, CurseData.MaxTime - rest, "cleared"
	end
	return 0, rest, "survived"
end

-- "3 stages · 9:12" / "0 stages · survived 4:10".
function CurseData.ScoreText(score: number): string
	local cleared, t, kind = CurseData.DecodeScore(score)
	local clock = string.format("%d:%02d", t // 60, t % 60)
	if kind == "cleared" then
		return string.format("%d stage%s · %s", cleared, cleared == 1 and "" or "s", clock)
	end
	return "0 stages · survived " .. clock
end

return CurseData
