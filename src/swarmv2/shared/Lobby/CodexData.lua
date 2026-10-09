--!strict
--[[
	SwarmV2/Lobby/CodexData.lua  (ReplicatedStorage.SwarmV2.Lobby.CodexData)
	OWNER: lobby track (Chat 1), stream L1. The codex (the lobby's COLLECTION screen, MenuCollection):
	what the redesigned game contains, written from the real data modules and nothing else.

	  Classes (12)       ClassCatalog.Order + ClassDetails (kit, base values, how to get it)
	  Weapons (15)       WeaponData.Catalog: rank 1 figures, rank 3 / 5 milestones, the evolution it can reach
	  Passives (8)       PassiveData.LootOrder
	  Evolutions (4)     RunConfig.Builds.Evolutions: the four recipes
	  Enemies (7)        the Cliffwood roster (RunConfig.Director.Roster), the elite marker, the Basin Breaker
	  Controls           keyboard, touch, gamepad (the one list the first-time guide also reads)

	Discovery follows the rules that already exist (CollectionData / DiscoveryService / JournalService):
	a class is known when owned or played, a weapon / passive when Discovered.Weapons / Passives has
	it, an evolution when Discovered.Evolutions has its base weapon, an enemy when Journal.Enemies has
	its type, the Basin Breaker like any boss. The elite marker has no record of its own: it is known
	once the player has defeated an elite (Stats.ClassGoals.Elites, counted by the server). An unknown
	entry shows "???" and how to find it, never its details. Controls are always shown.
	Every number is a base value read from the shared tuning (B = 10, H0 = 120), never typed here.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local V2 = ReplicatedStorage:WaitForChild("SwarmV2")
local Shared = ReplicatedStorage:WaitForChild("Shared")
local ClassCatalog = require(V2:WaitForChild("ClassCatalog"))
local ClassDetails = require(V2:WaitForChild("Lobby"):WaitForChild("ClassDetails"))
local RunConfig = require(V2:WaitForChild("Run"):WaitForChild("RunConfig"))
local BuildRules = require(V2:WaitForChild("Run"):WaitForChild("BuildRules"))
local Config = require(Shared:WaitForChild("Config"))
local WeaponData = require(Shared:WaitForChild("WeaponData"))
local PassiveData = require(Shared:WaitForChild("PassiveData"))
local EnemyData = require(Shared:WaitForChild("EnemyData"))
local BossData = require(Shared:WaitForChild("BossData"))
local CollectionData = require(Shared:WaitForChild("CollectionData"))

local CodexData = {}

export type Entry = {
	Id: string,
	Name: string,
	Sub: string, -- one line under the name (known entries)
	Icon: string?, -- Icons name
	Character: string?, -- class id (drawn with Icons.Character)
}

export type Detail = {
	Lines: { string }, -- sentences
	Rows: { { Label: string, Value: string } }, -- label / value pairs (base values)
}

export type Category = {
	Id: string,
	Title: string,
	Counts: boolean, -- part of the "found" total (Controls are not)
	Hint: string, -- how an unknown entry is found
	Entries: { Entry },
}

local function B(): number
	return BuildRules.B()
end
local function H0(): number
	return (Config.Player :: any).BaseMaxHP
end
local num = ClassDetails.FormatNumber

-- the profile's nested set (a ProfileSync table, or a save)
local function set(p: any, ...: string): { [string]: any }
	local t = p
	for _, k in ipairs({ ... }) do
		if type(t) ~= "table" then
			return {}
		end
		t = t[k]
	end
	return type(t) == "table" and t or {}
end

------------------------------------------------------------------------------------------
-- Controls (also the first-time guide's list)
------------------------------------------------------------------------------------------

CodexData.Controls = {
	Keyboard = { "Move: W A S D", "Jump: Space", "Dash: Left Shift (or Q)", "Camera: hold the right mouse button and move the mouse" },
	Touch = { "Move: the left thumbstick", "Camera: swipe the right side of the screen", "Jump and Dash: the JUMP and DASH buttons" },
	Gamepad = { "Move: left stick", "Camera: right stick", "Jump: A", "Dash: B or R1" },
} :: { [string]: { string } }

CodexData.ControlOrder = { "Keyboard", "Touch", "Gamepad" }
CodexData.ControlTitles = { Keyboard = "Keyboard and mouse", Touch = "Touch screen", Gamepad = "Gamepad" } :: { [string]: string }

------------------------------------------------------------------------------------------
-- Entry lists
------------------------------------------------------------------------------------------

local classes: { Entry } = {}
for _, id in ipairs(ClassCatalog.Order) do
	local info = ClassCatalog.Get(id)
	if info then
		local d = ClassDetails.Get(id)
		table.insert(classes, { Id = id, Name = info.Name, Sub = d and d.Role or (info.Role or ""), Character = id })
	end
end

local weapons: { Entry } = {}
for _, id in ipairs(WeaponData.Catalog) do
	local def: any = WeaponData.Weapons[id]
	if def then
		local owner = def.ClassOnly and ClassCatalog.Get(def.ClassOnly)
		table.insert(weapons, { Id = id, Name = def.Name, Sub = owner and ("Signature of " .. owner.Name) or "Found in runs", Icon = id })
	end
end

local passives: { Entry } = {}
for _, id in ipairs(PassiveData.LootOrder) do
	local def: any = PassiveData.Passives[id]
	if def then
		table.insert(passives, { Id = id, Name = def.Name, Sub = def.Description, Icon = id })
	end
end

local evolutions: { Entry } = {}
for _, baseId in ipairs((RunConfig.Builds :: any).Evolutions) do
	local def: any = WeaponData.Weapons[baseId]
	local evo = def and def.Evolution
	if evo then
		local passive: any = PassiveData.Passives[evo.Passive]
		table.insert(evolutions, { Id = baseId, Name = evo.Name, Sub = def.Name .. " + " .. (passive and passive.Name or evo.Passive), Icon = baseId })
	end
end

-- the Cliffwood roster in the director's order, then the elite marker, then the boss
local enemies: { Entry } = {}
for _, r in ipairs((RunConfig.Director :: any).Roster) do
	local def: any = EnemyData.Enemies[r.Type]
	if def then
		local name: string = r.Name or def.DisplayName
		table.insert(enemies, { Id = r.Type, Name = name, Sub = def.Role or "", Icon = "skull" })
	end
end
table.insert(enemies, { Id = "EliteMarker", Name = "Elite marker", Sub = "A golden crown over an enemy: a tougher one", Icon = "crown" })
do
	local boss: any = BossData.Bosses.BasinBreaker
	table.insert(enemies, { Id = "BasinBreaker", Name = boss and boss.DisplayName or "Basin Breaker", Sub = "The final boss of Cliffwood Basin", Icon = "crown" })
end

CodexData.Categories = {
	{ Id = "Classes", Title = "CLASSES", Counts = true, Hint = "Own the class or play a run as it.", Entries = classes },
	{ Id = "Weapons", Title = "WEAPONS", Counts = true, Hint = "Own it in a run, or see it on an upgrade card.", Entries = weapons },
	{ Id = "Passives", Title = "PASSIVES", Counts = true, Hint = "Own it in a run, or see it on an upgrade card.", Entries = passives },
	{ Id = "Evolutions", Title = "EVOLUTIONS", Counts = true, Hint = "Evolve the weapon in a run.", Entries = evolutions },
	{ Id = "Enemies", Title = "ENEMIES", Counts = true, Hint = "Meet it in a run.", Entries = enemies },
	{ Id = "Controls", Title = "CONTROLS", Counts = false, Hint = "", Entries = {} },
} :: { Category }

-- the controls category lists one entry per device
do
	local cat = CodexData.Categories[#CodexData.Categories]
	for _, device in ipairs(CodexData.ControlOrder) do
		table.insert(cat.Entries, { Id = device, Name = CodexData.ControlTitles[device], Sub = "How to play on this device", Icon = "info" })
	end
	table.insert(cat.Entries, { Id = "Run", Name = "How a run goes", Sub = "Attacks, XP and upgrades", Icon = "info" })
end

function CodexData.Category(id: string): Category?
	for _, c in ipairs(CodexData.Categories) do
		if c.Id == id then
			return c
		end
	end
	return nil
end

------------------------------------------------------------------------------------------
-- Discovery (the rules that already exist)
------------------------------------------------------------------------------------------

function CodexData.Known(profile: any, categoryId: string, id: string): boolean
	if categoryId == "Controls" then
		return true
	elseif categoryId == "Classes" then
		return id == ClassCatalog.Default or CollectionData.Categories.Heroes.Known(profile, id)
	elseif categoryId == "Weapons" then
		return CollectionData.Categories.Weapons.Known(profile, id)
	elseif categoryId == "Passives" then
		return CollectionData.Categories.Passives.Known(profile, id)
	elseif categoryId == "Evolutions" then
		return set(profile, "Discovered", "Evolutions")[id] == true
	elseif categoryId == "Enemies" then
		if id == "EliteMarker" then
			local goals = set(profile, "Stats", "ClassGoals")
			return (tonumber(goals.Elites) or 0) >= 1
		elseif id == "BasinBreaker" then
			return CollectionData.Categories.Bosses.Known(profile, "BasinBreaker")
		end
		return CollectionData.Categories.Enemies.Known(profile, id)
	end
	return false
end

-- (found, total) over the categories that count, or over one category.
function CodexData.Progress(profile: any, categoryId: string?): (number, number)
	local n, total = 0, 0
	for _, c in ipairs(CodexData.Categories) do
		if c.Counts and (categoryId == nil or c.Id == categoryId) then
			for _, e in ipairs(c.Entries) do
				total += 1
				if CodexData.Known(profile, c.Id, e.Id) then
					n += 1
				end
			end
		end
	end
	return n, total
end

------------------------------------------------------------------------------------------
-- Details (known entries): sentences and base values read from the data modules
------------------------------------------------------------------------------------------

local function statRows(stats: { ClassDetails.Stat }): { { Label: string, Value: string } }
	local rows = {}
	for _, s in ipairs(stats) do
		if s.Hidden then
			table.insert(rows, { Label = s.Label, Value = "not shown: " .. s.Hidden })
		else
			table.insert(rows, { Label = s.Label, Value = (s.Value or "") .. (s.Unit and (" " .. s.Unit) or "") .. (s.Note and (" (" .. s.Note .. ")") or "") })
		end
	end
	return rows
end

local function classDetail(id: string): Detail
	local d = ClassDetails.Get(id)
	if not d then
		return { Lines = { "No details available." }, Rows = {} }
	end
	local access = ClassDetails.Access(id, true, nil)
	local info = ClassCatalog.Get(id)
	local lines = {
		d.Description,
		"Weapon: " .. d.Weapon.Name .. ". " .. d.Weapon.Behavior,
		"Passive, " .. d.Passive.Name .. ": " .. d.Passive.Behavior,
		"Movement, " .. d.Movement.Name .. ": " .. d.Movement.Behavior,
	}
	if info and info.Id ~= ClassCatalog.Default and info.Goal then
		table.insert(lines, "Unlock goal: " .. info.Goal.Text .. (info.GoalOnly and " (earned in runs only)." or ", or buy it for " .. ClassDetails.Thousands(info.Cost) .. " gold."))
	elseif access and access.State == "Starter" then
		table.insert(lines, access.Summary)
	end
	local rows = statRows(d.Stats)
	table.insert(rows, 1, { Label = "Values", Value = d.BaseNote })
	return { Lines = lines, Rows = rows }
end

local function evolutionFor(weaponId: string): any?
	for _, baseId in ipairs((RunConfig.Builds :: any).Evolutions) do
		if baseId == weaponId then
			local def: any = WeaponData.Weapons[baseId]
			return def and def.Evolution
		end
	end
	return nil
end

local function weaponDetail(id: string): Detail
	local def: any = WeaponData.Weapons[id]
	local lines = { def and def.Description or "No description available." }
	local owner = def and def.ClassOnly and ClassCatalog.Get(def.ClassOnly)
	table.insert(lines, owner and ("The starting weapon of " .. owner.Name .. "; other classes can find it once they own that class.") or "Any class can find this weapon in a run.")
	local stats, notes = ClassDetails.WeaponStats(id)
	if #notes > 0 then
		table.insert(lines, "Rank 1: " .. table.concat(notes, "; ") .. ".")
	end
	for _, rank in ipairs({ 3, 5 }) do
		local text = WeaponData.MilestoneText(id, rank)
		if text then
			-- the card texts quote damage in multiples of B ("0.40 B"): show the damage itself
			local shown = string.gsub(text, "([%d%.]+) B%f[%W]", function(coeff: string): string
				return num((tonumber(coeff) or 0) * B()) .. " damage"
			end)
			text = shown
			table.insert(lines, string.format("Rank %d: %s.", rank, text))
		end
	end
	local evo = evolutionFor(id)
	if evo then
		local passive: any = PassiveData.Passives[evo.Passive]
		table.insert(lines, string.format("Evolves into %s with %s.", evo.Name, passive and passive.Name or evo.Passive))
	end
	local rows = statRows(stats)
	table.insert(rows, 1, { Label = "Values", Value = "base values at rank 1, before upgrades" })
	return { Lines = lines, Rows = rows }
end

local function passiveDetail(id: string): Detail
	local def: any = PassiveData.Passives[id]
	local lines = { def and def.Description or "No description available." }
	table.insert(lines, string.format("It has %d ranks; every rank adds the same amount.", def and #def.Values or BuildRules.MaxRank()))
	for _, baseId in ipairs((RunConfig.Builds :: any).Evolutions) do
		local w: any = WeaponData.Weapons[baseId]
		if w and w.Evolution and w.Evolution.Passive == id then
			table.insert(lines, string.format("Evolution partner: %s turns into %s.", w.Name, w.Evolution.Name))
		end
	end
	return { Lines = lines, Rows = {} }
end

local function evolutionDetail(baseId: string): Detail
	local def: any = WeaponData.Weapons[baseId]
	local evo: any = def and def.Evolution
	if not evo then
		return { Lines = { "No details available." }, Rows = {} }
	end
	local passive: any = PassiveData.Passives[evo.Passive]
	local b: any = RunConfig.Builds
	return {
		Lines = {
			evo.Description,
			string.format("Recipe: %s at rank %d and %s at rank %d, at player level %d or higher.", def.Name, b.EvolutionWeaponRank, passive and passive.Name or evo.Passive, b.EvolutionPassiveRank, b.EvolutionLevel),
		},
		Rows = {},
	}
end

local function money(coeff: number, base: number): string
	return num(coeff * base)
end

local function enemyDetail(id: string): Detail
	if id == "EliteMarker" then
		local e: any = (RunConfig.Director :: any).Elite
		return {
			Lines = {
				"A small golden crown over an enemy marks an elite: the same creature, tougher and harder hitting. Defeating elites pays well.",
				string.format("Elites can appear from minute %s: about %s of spawns, with %s times the health and %s times the damage.", num(e.FromMinute), num(e.Chance * 100) .. "%", num(e.HPMult), num(e.DamageMult)),
			},
			Rows = {},
		}
	end
	if id == "BasinBreaker" then
		local boss: any = BossData.Bosses.BasinBreaker
		local d: any = (RunConfig.Director :: any).Boss
		local a: any = boss.Attacks
		local lines = {
			"The final boss of Cliffwood Basin. It rises once the beacon is charged; defeating it wins the run.",
			string.format("Root Slam: a marked circle of %s studs after %s s, %s damage.", num(a.RootSlam.Radius), num(a.RootSlam.Windup), money(a.RootSlam.DamageH0, H0())),
			string.format("Breaker Charge: a marked lane about %s studs long after %s s, %s damage.", num(a.BreakerCharge.Speed * a.BreakerCharge.Duration), num(a.BreakerCharge.Windup), money(a.BreakerCharge.DamageH0, H0())),
			string.format("Sap Circles: %d marked circles, one after another, %s damage each.", a.SapCircles.Count, money(a.SapCircles.DamageH0, H0())),
			"Below half health it recovers faster. Every attack is marked on the ground first.",
		}
		return {
			Lines = lines,
			Rows = {
				{ Label = "Health", Value = num(d.HPB * B()) .. " for a solo run at the start (more with more players)" },
				{ Label = "Touch damage", Value = money(d.Contact, H0()) },
			},
		}
	end
	local def: any = EnemyData.Enemies[id]
	local r: any = nil
	for _, row in ipairs((RunConfig.Director :: any).Roster) do
		if row.Type == id then
			r = row
		end
	end
	if not def or not r then
		return { Lines = { "No details available." }, Rows = {} }
	end
	local rows = {
		{ Label = "Values", Value = "base values at the start of the run" },
		{ Label = "Health", Value = money(r.HP, B()) },
		{ Label = "Speed", Value = num(r.Speed) .. " studs/s" },
		{ Label = "Touch damage", Value = money(r.Contact, H0()) },
		{ Label = "Appears from", Value = r.FromMinute == 0 and "the start" or ("minute " .. num(r.FromMinute)) },
	}
	if r.Attack then
		table.insert(rows, { Label = "Attack damage", Value = money(r.Attack, H0()) })
	end
	return { Lines = { def.Role or "Watch its approach and the marks on the ground." }, Rows = rows }
end

local function controlDetail(id: string): Detail
	if id == "Run" then
		return {
			Lines = {
				"Attacks are automatic: your weapons fire at the nearest enemy, so you only move, jump and dash.",
				"Defeated enemies drop XP. Fill the bar to level up and pick one of three upgrades.",
				"Weapons and passives have five ranks. Reach rank 5 on a weapon and rank 3 on its partner passive to evolve it.",
			},
			Rows = {},
		}
	end
	local lines = {}
	for _, l in ipairs(CodexData.Controls[id] or {}) do
		table.insert(lines, l)
	end
	return { Lines = lines, Rows = {} }
end

function CodexData.Detail(categoryId: string, id: string): Detail
	if categoryId == "Classes" then
		return classDetail(id)
	elseif categoryId == "Weapons" then
		return weaponDetail(id)
	elseif categoryId == "Passives" then
		return passiveDetail(id)
	elseif categoryId == "Evolutions" then
		return evolutionDetail(id)
	elseif categoryId == "Enemies" then
		return enemyDetail(id)
	elseif categoryId == "Controls" then
		return controlDetail(id)
	end
	return { Lines = {}, Rows = {} }
end

return CodexData
