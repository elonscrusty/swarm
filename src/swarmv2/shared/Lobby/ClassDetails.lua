--!strict
--[[
	SwarmV2/Lobby/ClassDetails.lua  (ReplicatedStorage.SwarmV2.Lobby.ClassDetails)
	OWNER: lobby track (Chat 1), stream L1. What the class browser's details view shows, built from
	the shared authoritative tuning and nothing else:

	  health, walking speed       ClassRoster.Entry(id).Bonus (RunConfig.Classes.Roster) and
	                              Config.Player, with the same formulas as StatSheet.Compute
	  jump apex                   RunConfig.Movement.JumpApex / JumpApexByClass / Classes.ChargedJump
	  dash / leap distance, cd    RunConfig.Dash.Variants[id] or Dash.Default (what Dash.lua reads)
	  weapon damage / interval /  WeaponData.RankSpec(signature, 1) through BuildRules (B = 10,
	  range                       rank 1, no bonuses): the numbers a fresh run starts with
	  names, behaviour text       WeaponData (weapon), ClassRoster.Defs (class, passive name) and the
	                              kit numbers in RunConfig.Classes (passive / movement sentences)

	Every number is "base value before upgrades". A value that cannot be read (a missing spec, a
	weapon without a range) is returned as Hidden = <reason>, never as a zero or a made-up figure.
	Pure functions: no Instances, no state; the offline check (class-browser-regression) compares
	them with StatSheet / WeaponData / Dash directly.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local V2 = ReplicatedStorage:WaitForChild("SwarmV2")
local Shared = ReplicatedStorage:WaitForChild("Shared")
local ClassCatalog = require(V2:WaitForChild("ClassCatalog"))
local RunConfig = require(V2:WaitForChild("Run"):WaitForChild("RunConfig"))
local ClassRoster = require(V2:WaitForChild("Run"):WaitForChild("ClassRoster"))
local BuildRules = require(V2:WaitForChild("Run"):WaitForChild("BuildRules"))
local Config = require(Shared:WaitForChild("Config"))
local WeaponData = require(Shared:WaitForChild("WeaponData"))

local ClassDetails = {}

export type Stat = {
	Key: string, -- "Health" | "Speed" | "Jump" | "Dash" | "Cooldown" | "Damage" | "Interval" | "Range"
	Label: string,
	Number: number?, -- the figure (nil when Hidden)
	Value: string?, -- the figure as shown ("108", "15.4")
	Unit: string?, -- "HP", "studs/s", "studs", "s"
	Note: string?, -- short qualifier ("3 pellets per burst", "11 with the charged jump")
	Hidden: string?, -- why there is no figure (shown instead of a value)
}

export type Details = {
	Id: string,
	Name: string,
	Role: string,
	Description: string,
	Weapon: { Id: string, Name: string, Behavior: string, Notes: { string } },
	Passive: { Name: string, Behavior: string },
	Movement: { Name: string, Behavior: string, Kind: string },
	Stats: { Stat },
	BaseNote: string,
}

ClassDetails.BaseNote = "Base values before upgrades"

------------------------------------------------------------------------------------------
-- Formatting
------------------------------------------------------------------------------------------

-- 108 -> "108", 15.4 -> "15.4", 0.9 -> "0.9", 2.50 -> "2.5"
local function num(n: number): string
	local r = math.floor(n * 100 + 0.5) / 100
	if r == math.floor(r) then
		return string.format("%d", r)
	end
	local s = string.format("%.2f", r)
	s = string.gsub(s, "0+$", "")
	s = string.gsub(s, "%.$", "")
	return s
end
ClassDetails.FormatNumber = num

local function pct(x: number): string
	return num(x * 100) .. "%"
end

local function B(): number
	return BuildRules.B()
end

-- damage of a coefficient at rank 1 with no bonuses (what the weapon deals fresh in a run)
local function dmg(coeff: number): string
	return num(BuildRules.HitDamage(coeff, 1, 0))
end

local function stat(key: string, label: string, n: number?, unit: string?, note: string?, hidden: string?): Stat
	if n == nil or n ~= n then
		return { Key = key, Label = label, Hidden = hidden or "Not available in this build." }
	end
	return { Key = key, Label = label, Number = n, Value = num(n), Unit = unit, Note = note }
end

------------------------------------------------------------------------------------------
-- Class kit texts (the numbers are read from RunConfig.Classes / Combat / Dash at call time)
------------------------------------------------------------------------------------------

local function kit(): any
	return RunConfig.Classes
end

type Text = { Name: string, Text: () -> string }

local PASSIVE: { [string]: Text } = {
	ruckus = { Name = "Junk Collector", Text = function()
		local k = kit().JunkCollector
		return string.format("Every %d chest or item rewards charge your next Scrap Shot into a %d-scrap barrage (%s damage each).", k.RewardsPerCharge, k.Shots, dmg(k.Coeff))
	end },
	toastmaster = { Name = "Overheat", Text = function()
		local k = kit().Overheat
		local c = RunConfig.Combat
		return string.format("%d direct toast hits on one enemy within %s s scorch it for %s damage per second (%s s).", k.Hits, num(k.Window), num(c.ScorchDpsB * B()), num(c.ScorchSeconds))
	end },
	captain_croak = { Name = "Big Splash", Text = function()
		local k = kit().BigSplash
		return string.format("A leap that lands within %s studs of an enemy makes your next bubble burst %s harder (for %s s).", num(k.EnemyRange), pct(k.DamageMult - 1), num(k.Expiry))
	end },
	granny_boom = { Name = "Tangled Up", Text = function()
		local k = kit().TangledUp
		return string.format("Yarn damage slows enemies %s for %s s (bosses at most %s).", pct(k.Slow), num(k.Seconds), pct(RunConfig.Combat.BossSlowCap))
	end },
	coach_crunch = { Name = "Warm-Up", Text = function()
		local k = kit().WarmUp
		return string.format("Running faster than %s studs/s for %s s charges your next shoulder tackle.", num(k.Speed), num(k.Seconds))
	end },
	doug_janitor = { Name = "Clean Route", Text = function()
		local r = RunConfig.Classes.Roster.doug_janitor
		local bonus = r and r.Bonus and r.Bonus.pickupFlat or 0
		return string.format("+%s studs of pickup radius for your own XP shards.", num(bonus))
	end },
	peter_parkour = { Name = "Stride", Text = function()
		local k = kit().Stride
		return string.format("Running faster than %s studs/s for %s s makes your next sneaker throw hit %s harder (expires after %s s).", num(k.Speed), num(k.Seconds), pct(k.DamageBonus), num(k.Expiry))
	end },
	barry_plotter = { Name = "Garden Company", Text = function()
		local k = kit().GardenCompany
		return string.format("Your plants hit %s harder while you stand within %s studs of them.", pct(k.DamageBonus), num(k.Range))
	end },
	rambozo = { Name = "Punchline", Text = function()
		local k = kit().Punchline
		return string.format("+%s crit chance against enemies above %s of their health.", pct(k.CritBonus), pct(k.HpShare))
	end },
	swolverine = { Name = "Gains", Text = function()
		local k = kit().Gains
		return string.format("Every %d kills heal %s of your max health.", k.KillsPerHeal, pct(k.HealShare))
	end },
	crash_cassidy = { Name = "Momentum", Text = function()
		local k = kit().Momentum
		return string.format("Up to +%s weapon damage as your speed rises from %s to %s studs/s.", pct(k.MaxBonus), num(k.MinSpeed), num(k.MaxSpeed))
	end },
	knuckles_mcgee = { Name = "Heavy Hands", Text = function()
		local k = kit().HeavyHands
		return string.format("Punches knock normal enemies back %s further.", pct(k.KnockMult - 1))
	end },
}

local MOVEMENT: { [string]: Text } = {
	ruckus = { Name = "Can Roll", Text = function()
		local k = kit().DashCans
		return string.format("Dashing drops %d rolling cans that explode after %s s for %s damage in a %s-stud radius.", k.Count, num(k.Fuse), dmg(k.Coeff), num(k.Radius))
	end },
	toastmaster = { Name = "Spring Jump", Text = function()
		local k = kit().LandingBlast
		local apex = RunConfig.Movement.JumpApexByClass.toastmaster or RunConfig.Movement.JumpApex
		return string.format("Jumps reach %s studs. Landing from a real jump blasts nearby enemies for %s damage (%s-stud radius, every %s s).", num(apex), dmg(k.Coeff), num(k.Radius), num(k.Cooldown))
	end },
	captain_croak = { Name = "Leap", Text = function()
		local d = RunConfig.Dash.Variants.captain_croak
		return string.format("The dash is a %s-stud leap over %s s (peak %s studs).", num(d.Horizontal or 0), num(d.Duration), num(d.Apex or 0))
	end },
	granny_boom = { Name = "Rocket Boost", Text = function()
		local d = RunConfig.Dash.Variants.granny_boom
		return string.format("The dash is a rocket boost: %s studs/s for %s s.", num(d.Speed), num(d.Duration))
	end },
	coach_crunch = { Name = "Shoulder Tackle", Text = function()
		local k = kit().Tackle
		return string.format("The dash hits up to %d enemies once (%s damage charged, %s uncharged) and staggers them for %s s. It spends the Warm-Up charge.", k.MaxTargets, dmg(k.ChargedCoeff), dmg(k.Coeff), num(k.Stagger))
	end },
	doug_janitor = { Name = "Wet Trail", Text = function()
		local k = kit().WetTrail
		return string.format("Dashing leaves a %s-stud wet trail for %s s that slows enemies by %s (no damage).", num(k.Length), num(k.Seconds), pct(k.Slow))
	end },
	peter_parkour = { Name = "Charged Jump", Text = function()
		local k = kit().ChargedJump.peter_parkour
		return string.format("One jump every %s s reaches %s studs (normal jumps reach %s).", num(k.Cooldown), num(k.Apex), num(RunConfig.Movement.JumpApex))
	end },
	barry_plotter = { Name = "Seed Dash", Text = function()
		local k = kit().DashSeed
		return string.format("Dashing plants one extra seed (once every %s s; it shares the plant limit).", num(k.Cooldown))
	end },
	rambozo = { Name = "Balloon Grenade", Text = function()
		local k = kit().BalloonGrenade
		return string.format("Dashing drops a balloon that pops after %s s for %s damage in %s studs, then %d mini-pops of %s damage.", num(k.Fuse), dmg(k.Coeff), num(k.Radius), k.MiniCount, dmg(k.MiniCoeff))
	end },
	swolverine = { Name = "Dash Recovery", Text = function()
		local k = kit().DashRecovery
		return string.format("After a dash you deal %s more damage for %s s.", pct(k.DamageBonus), num(k.Seconds))
	end },
	crash_cassidy = { Name = "Body Check", Text = function()
		local k = kit().BodyCheck
		return string.format("The dash hits up to %d enemies once for %s damage and knocks them back.", k.MaxTargets, dmg(k.Coeff))
	end },
	knuckles_mcgee = { Name = "Close Dodge", Text = function()
		local k = kit().CloseDodge
		return string.format("A dash that ends within %s studs of an enemy adds one Glove Combo charge.", num(k.Range))
	end },
}

-- movement "kind" label for the details header: what replaces or extends the plain dash
local MOVE_KIND: { [string]: string } = {
	toastmaster = "Jump",
	captain_croak = "Leap",
	granny_boom = "Dash",
	peter_parkour = "Jump",
}

------------------------------------------------------------------------------------------
-- Weapon notes (rank 1)
------------------------------------------------------------------------------------------

local function weaponNotes(spec: any): { string }
	local out: { string } = {}
	local function add(s: string)
		table.insert(out, s)
	end
	if type(spec.Amount) == "number" and spec.Amount > 1 then
		add(string.format("%d pellets per burst", spec.Amount))
	end
	if type(spec.Bounces) == "number" and spec.Bounces > 0 and type(spec.BounceCoeff) == "number" then
		add(string.format("bounces %d time%s for %s damage", spec.Bounces, spec.Bounces == 1 and "" or "s", dmg(spec.BounceCoeff)))
	end
	if type(spec.BlastRadius) == "number" then
		add(string.format("%s-stud blast after a %s s fuse", num(spec.BlastRadius), num(spec.Fuse or 0)))
	elseif type(spec.BurstRadius) == "number" then
		add(string.format("%s-stud burst", num(spec.BurstRadius)))
	end
	if type(spec.OutTargets) == "number" then
		add(string.format("hits %d on the way out, %d on the way back (%s damage)", spec.OutTargets, spec.ReturnTargets or 0, dmg(spec.ReturnCoeff or 0)))
	end
	if type(spec.PlantCoeff) == "number" then
		add(string.format("plants shoot for %s damage every %s s (up to %d plants)", dmg(spec.PlantCoeff), num(spec.PlantFireEvery or 1), spec.PlantCap or 1))
	end
	if type(spec.UppercutCoeff) == "number" then
		add(string.format("after %d punches: %s damage uppercut", spec.ChargeAfter or 5, dmg(spec.UppercutCoeff)))
	end
	if type(spec.MaxTargets) == "number" and spec.MaxTargets > 1 and type(spec.Arc) == "number" then
		add(string.format("%s-degree arc, up to %d enemies", num(spec.Arc), spec.MaxTargets))
	end
	return out
end

------------------------------------------------------------------------------------------
-- Details
------------------------------------------------------------------------------------------

local function movementStats(id: string): { Stat }
	local out: { Stat } = {}
	local P: any = Config.Player
	local entry: any = ClassRoster.Entry(id)
	local bonus: any = entry and entry.Bonus or {}

	-- health and speed: StatSheet.Compute's formulas for a fresh character
	local hp = math.floor((P.BaseMaxHP + 0) * (1 + (bonus.maxHpMult or 0)) + 0.5)
	local speedMult = math.clamp(1 + (bonus.speed or 0), 0.5, Config.Items.MaxSpeedMult)
	local speed = P.BaseSpeed * speedMult
	table.insert(out, stat("Health", "Base health", hp, "HP"))
	table.insert(out, stat("Speed", "Move speed", speed, "studs/s"))

	-- jump apex (RunConfig.Movement); Peter's charged jump is a second, rarer figure
	local M: any = RunConfig.Movement
	local apex: number = (M.JumpApexByClass and M.JumpApexByClass[id]) or M.JumpApex
	local charged: any = RunConfig.Classes.ChargedJump and RunConfig.Classes.ChargedJump[id]
	local jumpNote: string? = nil
	if charged then
		jumpNote = string.format("%s with the charged jump, once every %s s", num(charged.Apex), num(charged.Cooldown))
	end
	table.insert(out, stat("Jump", "Jump height", apex, "studs", jumpNote))

	-- dash or leap (what Dash.lua reads for this class)
	local D: any = RunConfig.Dash
	local def: any = D.Variants[id] or D.Default
	local dist: number?
	local dashNote: string? = nil
	if def.Kind == "Leap" then
		dist = def.Horizontal
		dashNote = "a leap that replaces the dash"
	else
		dist = def.Speed * def.Duration
		if def.Speed ~= D.Default.Speed or def.Duration ~= D.Default.Duration then
			dashNote = string.format("%s studs/s for %s s", num(def.Speed), num(def.Duration))
		end
	end
	table.insert(out, stat("Dash", def.Kind == "Leap" and "Leap distance" or "Dash distance", dist, "studs", dashNote))
	table.insert(out, stat("Cooldown", "Movement cooldown", def.Cooldown, "s", nil))
	return out
end

local function weaponStats(weaponId: string?): ({ Stat }, { string })
	local out: { Stat } = {}
	local notes: { string } = {}
	local spec: any = weaponId and WeaponData.RankSpec(weaponId, 1)
	if not spec then
		local why = "No weapon numbers are available for this class."
		table.insert(out, { Key = "Damage", Label = "Weapon damage", Hidden = why })
		table.insert(out, { Key = "Interval", Label = "Weapon interval", Hidden = why })
		table.insert(out, { Key = "Range", Label = "Weapon range", Hidden = why })
		return out, notes
	end
	notes = weaponNotes(spec)
	local damageNote: string? = nil
	if type(spec.Amount) == "number" and spec.Amount > 1 then
		damageNote = string.format("per pellet, %d pellets", spec.Amount)
	elseif type(spec.ImpactCoeff) == "number" then
		damageNote = string.format("the burst; %s more on a direct hit", dmg(spec.ImpactCoeff))
	elseif type(spec.PlantCoeff) == "number" then
		damageNote = "the seed's own hit"
	elseif type(spec.BlastRadius) == "number" then
		damageNote = "to everything in the blast"
	end
	table.insert(out, stat("Damage", "Weapon damage", BuildRules.HitDamage(spec.Coeff, 1, 0), "per hit", damageNote))
	table.insert(out, stat("Interval", "Weapon interval", BuildRules.RankInterval(spec.Interval, 1), "s", "between attacks"))
	local range: number? = type(spec.Range) == "number" and spec.Range or nil
	local label = "Weapon range"
	if range == nil and type(spec.Reach) == "number" then
		range = spec.Reach
		label = "Weapon reach"
	end
	table.insert(out, stat("Range", label, range, "studs", nil, "This weapon has no fixed range."))
	return out, notes
end

-- Rank 1 figures of any catalog weapon (damage, interval, range / reach) and notes, for the codex.
function ClassDetails.WeaponStats(weaponId: string): ({ Stat }, { string })
	return weaponStats(weaponId)
end

function ClassDetails.Get(id: any): Details?
	local info = ClassCatalog.Get(id)
	if not info then
		return nil
	end
	local def: any = ClassRoster.Defs[info.Id]
	local roster: any = RunConfig.Classes.Roster[info.Id]
	local weaponId: string? = roster and roster.StartWeapon or WeaponData.Signatures[info.Id]
	local weaponDef: any = weaponId and WeaponData.Weapons[weaponId]

	local passive = PASSIVE[info.Id]
	local movement = MOVEMENT[info.Id]
	local stats = movementStats(info.Id)
	local wStats, wNotes = weaponStats(weaponId)
	for _, s in ipairs(wStats) do
		table.insert(stats, s)
	end

	return {
		Id = info.Id,
		Name = info.Name,
		Role = def and def.Role or info.Role or "",
		Description = def and def.Description or info.Tagline,
		Weapon = {
			Id = weaponId or "",
			Name = weaponDef and weaponDef.Name or "Unknown weapon",
			Behavior = weaponDef and weaponDef.Description or "No description available.",
			Notes = wNotes,
		},
		Passive = {
			Name = passive and passive.Name or (def and def.Trait and def.Trait.Name) or "Passive",
			Behavior = passive and passive.Text() or (def and def.Trait and def.Trait.Text) or "No description available.",
		},
		Movement = {
			Name = movement and movement.Name or "Dash",
			Behavior = movement and movement.Text() or "Dash a short distance.",
			Kind = MOVE_KIND[info.Id] or "Dash",
		},
		Stats = stats,
		BaseNote = ClassDetails.BaseNote,
	}
end

-- One stat by key, nil when absent.
function ClassDetails.StatOf(details: Details, key: string): Stat?
	for _, s in ipairs(details.Stats) do
		if s.Key == key then
			return s
		end
	end
	return nil
end

------------------------------------------------------------------------------------------
-- Access (unlock requirement), from ClassCatalog (prices, goals) and the player's progress
------------------------------------------------------------------------------------------

local STAT_UNIT: { [string]: { One: string, Many: string } } = {
	XP = { One = "XP", Many = "XP" },
	Distance = { One = "stud", Many = "studs" },
	Elites = { One = "elite", Many = "elites" },
	BestSurvive = { One = "second", Many = "seconds" },
	Chests = { One = "chest", Many = "chests" },
	Dashes = { One = "dash", Many = "dashes" },
	MostWeapons = { One = "weapon", Many = "weapons" },
	Kills = { One = "enemy", Many = "enemies" },
	CloseKills = { One = "close kill", Many = "close kills" },
	Bosses = { One = "boss", Many = "bosses" },
	Revives = { One = "revive", Many = "revives" },
}

local function thousands(n: number): string
	local s = tostring(math.floor(n))
	while true do
		local k
		s, k = string.gsub(s, "^(%d+)(%d%d%d)", "%1,%2")
		if k == 0 then
			break
		end
	end
	return s
end
ClassDetails.Thousands = thousands

local function clock(seconds: number): string
	seconds = math.max(0, math.floor(seconds))
	return string.format("%d:%02d", seconds // 60, seconds % 60)
end

-- "120 / 300 XP", "1:30 / 3:00" (the run-survival goal counts seconds)
function ClassDetails.ProgressText(stat: string, have: number, need: number): string
	if stat == "BestSurvive" then
		return string.format("%s / %s", clock(have), clock(need))
	end
	local unit = STAT_UNIT[stat]
	local word = unit and (need == 1 and unit.One or unit.Many) or ""
	return string.format("%s / %s%s", thousands(have), thousands(need), word ~= "" and (" " .. word) or "")
end

export type Access = {
	State: string, -- "Starter" | "Owned" | "Buyable" | "GoalOnly"
	Summary: string, -- one line: "Free starter class." / "Buy for 10,000 gold or earn it." / "Earn it in runs."
	Goal: string?, -- the goal text ("Dash 30 times")
	Parts: { string }?, -- progress lines ("12 / 30 dashes"); several for an "any one of" goal
	Fraction: number?, -- 0..1 of the main stat (for a bar)
	Price: number?, -- gold, only for a class that can be bought
}

-- progress: LobbyView.Progress[id] (Have / Need / Stat / Parts); owned: the class is already owned
function ClassDetails.Access(id: any, owned: boolean, progress: any?): Access?
	local info = ClassCatalog.Get(id)
	if not info then
		return nil
	end
	local goal = info.Goal
	if info.Id == ClassCatalog.Default then
		return { State = "Starter", Summary = "Free starter class. Every account has it." }
	end
	if owned then
		return { State = "Owned", Summary = "You own this class.", Goal = goal and goal.Text or nil }
	end
	local parts: { string }? = nil
	local fraction: number? = nil
	if goal then
		parts = {}
		if progress and type(progress.Parts) == "table" and #progress.Parts > 0 then
			local best = 0
			for _, p in ipairs(progress.Parts) do
				table.insert(parts :: { string }, ClassDetails.ProgressText(p.Stat, p.Have, p.Need))
				best = math.max(best, p.Need > 0 and p.Have / p.Need or 0)
			end
			fraction = best
		elseif progress then
			table.insert(parts :: { string }, ClassDetails.ProgressText(progress.Stat or goal.Stat, progress.Have, progress.Need))
			fraction = progress.Need > 0 and progress.Have / progress.Need or 0
		end
	end
	if info.GoalOnly then
		return {
			State = "GoalOnly",
			Summary = "Earn this class in runs. It cannot be bought.",
			Goal = goal and goal.Text or nil,
			Parts = parts,
			Fraction = fraction,
		}
	end
	return {
		State = "Buyable",
		Summary = string.format("Buy it for %s gold, or earn it in runs (whichever comes first).", thousands(info.Cost)),
		Goal = goal and goal.Text or nil,
		Parts = parts,
		Fraction = fraction,
		Price = info.Cost,
	}
end

return ClassDetails
