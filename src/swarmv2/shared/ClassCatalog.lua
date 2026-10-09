--!strict
--[[
	SwarmV2/ClassCatalog.lua  (ReplicatedStorage.SwarmV2.ClassCatalog)
	OWNER: lobby track (Chat 1). Read-only presentation metadata for the four playable
	classes. Visible to clients, so it holds no admission, ticket or ownership state:
	seeing a class here never means owning it (the server checks the save).

	Gameplay (models, kits, tuning) lives in ServerScriptService.SwarmV2.Run (Chat 2), keyed
	by the same ids. Owner decisions 2026-10-08 (docs/redesign/DECISIONS.md): the old 11
	heroes are hidden; Ruckus is free; the others reuse the existing 10k / 20k / 30k gold
	hero tiers.
]]

export type ClassInfo = {
	Id: string,
	Name: string,
	Tagline: string,
	Cost: number, -- gold; 0 = owned by every account
	Order: number,
	-- presentation only (lobby pedestals, cards); added by the lobby track, all optional for readers
	Role: string?, -- short card tag
	Look: string?, -- what the concept art shows (docs/redesign/reference/Swarm-Characters.png)
	Primary: Color3?, -- main body colour of the temporary pedestal preview / card
	Accent: Color3?, -- signature detail colour (goggles, coils, scarf, walker)
	-- [integration, continuation pack] earnable goal (DECISIONS C2/C3), read from the shared run
	-- tuning (RunConfig.Classes.Roster[id].Goal); GoalOnly classes have no gold price
	Goal: { Stat: string, Need: number, Text: string, Any: { { Stat: string, Need: number } }? }?,
	GoalOnly: boolean?,
}

local Classes: { [string]: ClassInfo } = {
	ruckus = {
		Id = "ruckus", Name = "Ruckus", Tagline = "Raccoon with a trash-can backpack. Bouncing scrap.", Cost = 0, Order = 1,
		Role = "BRAWLER",
		Look = "Raccoon with orange goggles, a teal patched vest and a trash-can backpack.",
		Primary = Color3.fromRGB(120, 118, 124), Accent = Color3.fromRGB(240, 140, 40),
	},
	toastmaster = {
		Id = "toastmaster", Name = "Toastmaster", Tagline = "Very serious toaster. Ricocheting toast.", Cost = 10000, Order = 2,
		Role = "RICOCHET",
		Look = "Steel toaster with tiny boots, glowing orange coils and two slices on top.",
		Primary = Color3.fromRGB(176, 180, 186), Accent = Color3.fromRGB(255, 150, 40),
	},
	captain_croak = {
		Id = "captain_croak", Name = "Captain Croak", Tagline = "Explorer frog. Bubble bombs and long leaps.", Cost = 20000, Order = 3,
		Role = "BOMBER",
		Look = "Round green frog with aviator goggles, a yellow scarf and an expedition backpack.",
		Primary = Color3.fromRGB(96, 170, 60), Accent = Color3.fromRGB(240, 196, 50),
	},
	granny_boom = {
		Id = "granny_boom", Name = "Granny Boom", Tagline = "Rocket walker grandma. Explosive yarn.", Cost = 30000, Order = 4,
		Role = "ARTILLERY",
		Look = "Tiny grandmother in welding goggles and armoured slippers on a rocket walker.",
		Primary = Color3.fromRGB(120, 70, 150), Accent = Color3.fromRGB(210, 60, 50),
	},
	-- [integration] the eight continuation-pack classes (goal unlocks only, no gold price)
	coach_crunch = {
		Id = "coach_crunch", Name = "Coach Crunch", Tagline = "Loud gym teacher. Bouncing dodgeballs.", Cost = 0, Order = 5, GoalOnly = true,
		Role = "BOUNCER", Look = "Gym teacher in tiny shorts and huge sneakers, whistle and dodgeballs.",
		Primary = Color3.fromRGB(60, 110, 200), Accent = Color3.fromRGB(220, 60, 60),
	},
	doug_janitor = {
		Id = "doug_janitor", Name = "Doug the Janitor", Tagline = "Tired janitor. Mop sweeps and wet floors.", Cost = 0, Order = 6, GoalOnly = true,
		Role = "CONTROL", Look = "Exhausted janitor with a crooked cap, a big cleaning backpack, mop and soap.",
		Primary = Color3.fromRGB(80, 120, 170), Accent = Color3.fromRGB(240, 200, 60),
	},
	peter_parkour = {
		Id = "peter_parkour", Name = "Peter Parkour", Tagline = "Free runner. Returning sneakers.", Cost = 0, Order = 7, GoalOnly = true,
		Role = "RUNNER", Look = "Free runner with goggles and springy oversized sneakers.",
		Primary = Color3.fromRGB(240, 120, 40), Accent = Color3.fromRGB(60, 160, 200),
	},
	barry_plotter = {
		Id = "barry_plotter", Name = "Barry Plotter", Tagline = "Gardener. Plants that shoot back.", Cost = 0, Order = 8, GoalOnly = true,
		Role = "GARDENER", Look = "Gardener with goggles, potted plants and a staff.",
		Primary = Color3.fromRGB(90, 140, 60), Accent = Color3.fromRGB(150, 90, 50),
	},
	rambozo = {
		Id = "rambozo", Name = "Rambozo", Tagline = "Commando clown. Confetti minigun.", Cost = 0, Order = 9, GoalOnly = true,
		Role = "GUNNER", Look = "Squat commando clown with a red headband, red nose and confetti minigun.",
		Primary = Color3.fromRGB(70, 110, 60), Accent = Color3.fromRGB(220, 40, 40),
	},
	swolverine = {
		Id = "swolverine", Name = "Swolverine", Tagline = "Grumpy gym fan. Protein claws.", Cost = 0, Order = 10, GoalOnly = true,
		Role = "BRUISER", Look = "Short gym fanatic with huge forearms, sideburns and clawed gym gauntlets.",
		Primary = Color3.fromRGB(240, 200, 40), Accent = Color3.fromRGB(60, 60, 70),
	},
	crash_cassidy = {
		Id = "crash_cassidy", Name = "Crash Cassidy", Tagline = "Roller-derby bruiser. Ricochet puck.", Cost = 0, Order = 11, GoalOnly = true,
		Role = "SKATER", Look = "Roller-derby bruiser with a teal helmet, big skates and a hockey stick.",
		Primary = Color3.fromRGB(50, 170, 170), Accent = Color3.fromRGB(150, 60, 160),
	},
	knuckles_mcgee = {
		Id = "knuckles_mcgee", Name = "Knuckles McGee", Tagline = "Tiny boxer. Glove combos and uppercuts.", Cost = 0, Order = 12, GoalOnly = true,
		Role = "BOXER", Look = "Tiny confident boxer with enormous red gloves, big boots and a belt.",
		Primary = Color3.fromRGB(230, 170, 120), Accent = Color3.fromRGB(210, 40, 40),
	},
}

-- Goals from the shared run tuning (one source of truth for the lobby and the run).
do
	local okCfg, RunConfig = pcall(function()
		return require(script.Parent:WaitForChild("Run"):WaitForChild("RunConfig"))
	end)
	local roster = okCfg and type(RunConfig) == "table" and RunConfig.Classes and RunConfig.Classes.Roster
	if type(roster) == "table" then
		for id, info in pairs(Classes) do
			local def = roster[id]
			if type(def) == "table" and type(def.Goal) == "table" then
				info.Goal = def.Goal
			end
		end
	end
end

local ClassCatalog = {}

ClassCatalog.Order = {
	"ruckus", "toastmaster", "captain_croak", "granny_boom",
	"coach_crunch", "doug_janitor", "peter_parkour", "barry_plotter",
	"rambozo", "swolverine", "crash_cassidy", "knuckles_mcgee",
}
-- the four physical pedestals in the basecamp (the full roster lives in the class menu)
ClassCatalog.Showcase = { "ruckus", "toastmaster", "captain_croak", "granny_boom" }
ClassCatalog.Default = "ruckus"
-- Old hero ids still stored in saves (CharacterData). Hidden, never selectable, never deleted.
ClassCatalog.LegacyIds = {
	"Knight", "Mage", "Rogue", "Priest", "Ranger", "Alchemist",
	"Engineer", "Necromancer", "Archer", "Bard", "Golem",
}

function ClassCatalog.Get(id: string): ClassInfo?
	return Classes[id]
end

function ClassCatalog.IsClassId(id: any): boolean
	return type(id) == "string" and Classes[id] ~= nil
end

-- An old hero id from CharacterData (stored in saves, hidden in the redesign).
function ClassCatalog.IsLegacyId(id: any): boolean
	return type(id) == "string" and table.find(ClassCatalog.LegacyIds, id) ~= nil
end

return ClassCatalog
