--!strict
--[[
	SwarmV2/Run/ClassRoster.lua  (ReplicatedStorage.SwarmV2.Run.ClassRoster)
	OWNER: gameplay track (Chat 2). The four playable classes as CharacterData entries.

	ClassRoster.Register(CharacterData, MetaUpgradeData) inserts ruckus, toastmaster,
	captain_croak and granny_boom into CharacterData.Characters (only ids that are missing; an
	existing entry is never overwritten), puts them first in CharacterData.Order, takes the 11
	old heroes out of Order (their Characters entries stay, so saves keep working: a hidden hero
	is never selectable or listed, never deleted) and makes `ruckus` the default hero (free for
	every account). It also gives each class a hero-mastery Signature upgrade. Safe to call more
	than once. The server calls it from ClassRegistry at RunBoot; the client may call the same
	function so its own CharacterData copy knows the ids.

	Numbers (prices, bonuses) come from RunConfig.Classes.Roster. Models are
	"Ruckus", "Toastmaster", "CaptainCroak", "GrannyBoom" (category "Classes"); until their
	MeshCatalog entries exist ModelBuilder uses its generic part-built fallback.
]]

local RunConfig = require(script.Parent.RunConfig)
local Palette = require(game:GetService("ReplicatedStorage"):WaitForChild("Shared"):WaitForChild("Palette"))

local ClassRoster = {}

ClassRoster.LegacyIds = {
	"Knight", "Mage", "Rogue", "Priest", "Ranger", "Alchemist",
	"Engineer", "Necromancer", "Archer", "Bard", "Golem",
}

local function colors(t: { [string]: Color3 }): { [string]: Color3 }
	return t
end

-- Presentation + identity of each class (numbers are in RunConfig.Classes.Roster).
local Defs: { [string]: { [string]: any } } = {
	ruckus = {
		Name = "Ruckus",
		MeshName = "Ruckus",
		Role = "Loot raider",
		Description = "Raccoon with a trash-can backpack. Starts with Scrap Toss. +25% pickup radius.",
		BonusText = "+25% pickup radius",
		Trait = { Name = "Loot Rush", Text = "Every 5 chests, shrines or items you grab load a Scrap Barrage: a ring of 8 scraps with your next volley. Dashing drops 2 exploding cans." },
		Strengths = "Bouncing scrap hits crowds, and looting is a weapon.",
		Tradeoff = "Needs pickups to charge the barrage; scraps are single-target until they bounce.",
		SignatureName = "Scavenger",
		SignatureFormat = "+%d%% pickup radius",
		Hat = "Beanie",
		Swatch = "Cloth",
		Colors = colors({
			Metal = Palette.steel_400,
			MetalDark = Palette.steel_600,
			Cloth = Palette.slate_500,
			Cloth2 = Palette.slate_700,
			Accent = Palette.crimson_500,
			AccentDark = Palette.crimson_700,
			Gold = Palette.gold_500,
			Hat = Palette.crimson_600,
			HatAccent = Palette.ivory_200,
			Skin = Palette.slate_300,
		}),
	},
	toastmaster = {
		Name = "Toastmaster",
		MeshName = "Toastmaster",
		Role = "Ricochet gunner",
		Description = "Very serious toaster. Starts with Toast Volley. +10% max HP.",
		BonusText = "+10% max HP",
		Trait = { Name = "Overheat", Text = "3 hits on one enemy within 4 s set it burning for 3 s. Spring jumps reach higher and land with a blast." },
		Strengths = "Ricocheting toast and burning targets melt single enemies; a high spring jump.",
		Tradeoff = "Slices fly at one target at a time; the landing blast needs a real jump.",
		SignatureName = "Sturdy Casing",
		SignatureFormat = "+%d%% max HP",
		Hat = "Tophat",
		Swatch = "Metal",
		Colors = colors({
			Metal = Palette.steel_300,
			MetalDark = Palette.steel_500,
			Cloth = Palette.sand_400,
			Cloth2 = Palette.slate_700,
			Accent = Palette.crimson_500,
			AccentDark = Palette.crimson_700,
			Gold = Palette.gold_500,
			Hat = Palette.slate_800,
			HatAccent = Palette.gold_400,
			Skin = Palette.ivory_300,
		}),
	},
	captain_croak = {
		Name = "Captain Croak",
		MeshName = "CaptainCroak",
		Role = "Leaping bomber",
		Description = "Explorer frog. Starts with Bubble Bomb. +10% XP.",
		BonusText = "+10% XP",
		Trait = { Name = "Big Splash", Text = "A leap that lands near an enemy makes your next bubble hit 80% harder and burst 40% wider." },
		Strengths = "Bursting bubbles clear groups; the long leap crosses the map fast.",
		Tradeoff = "The leap lands where it lands: it is not a quick sidestep.",
		SignatureName = "Quick Study",
		SignatureFormat = "+%d%% XP",
		Hat = "Miner",
		Swatch = "Cloth",
		Colors = colors({
			Metal = Palette.leather_500,
			MetalDark = Palette.leather_700,
			Cloth = Palette.moss_500,
			Cloth2 = Palette.moss_700,
			Accent = Palette.amber_500,
			AccentDark = Palette.amber_300,
			Gold = Palette.gold_500,
			Hat = Palette.leather_600,
			HatAccent = Palette.amber_500,
			Skin = Palette.moss_300,
		}),
	},
	granny_boom = {
		Name = "Granny Boom",
		MeshName = "GrannyBoom",
		Role = "Crowd bomber",
		Description = "Rocket walker grandma. Starts with Yarn Bomb. +10% area.",
		BonusText = "+10% area",
		Trait = { Name = "Tangled Up", Text = "Yarn explosions tangle enemies: 35% slower for 0.75 s. Her rocket boost scorches the ground behind her." },
		Strengths = "Big explosions and tangled crowds; the boost burns a path.",
		Tradeoff = "Bombs land after a short flight, and bosses shrug off most of the tangle.",
		SignatureName = "Big Boom",
		SignatureFormat = "+%d%% area",
		Hat = "Hood",
		Swatch = "Cloth",
		Colors = colors({
			Metal = Palette.steel_400,
			MetalDark = Palette.steel_600,
			Cloth = Color3.fromRGB(226, 126, 170),
			Cloth2 = Palette.slate_600,
			Accent = Palette.ivory_200,
			AccentDark = Palette.ivory_300,
			Gold = Palette.gold_500,
			Hat = Color3.fromRGB(190, 190, 205),
			HatAccent = Palette.crimson_400,
			Skin = Palette.skin_400,
		}),
	},
}

local SIGNATURE_LEVELS = 5

-- The ultimate and the second (rank-unlocked) skill of each class, built from the existing
-- effects (CharacterData.Ultimates / SecondSkills shape; the Look names are Ultimate.lua's).
local Ultimates: { [string]: { [string]: any } } = {
	ruckus = { Name = "Trash Avalanche", Text = "Tips the can: a shockwave of junk hurls back everything near you, and you take no damage for 1 s.", Damage = 1.0, Radius = 0.9, Look = "Quake", Color = Palette.steel_300, Guard = 1.0, Knock = 1.8 },
	toastmaster = { Name = "Burnt Offering", Text = "Every toaster coil flares: flames burst all around you.", Damage = 1.1, Radius = 1.0, Look = "Fire", Color = Palette.amber_500 },
	captain_croak = { Name = "Tidal Splash", Text = "A wave of bubbles bursts all around you and chills the survivors.", Damage = 1.0, Radius = 1.0, Look = "Stars", Color = Palette.ice_300, Slow = { Mult = 0.6, Seconds = 2 } },
	granny_boom = { Name = "Knitting Needles", Text = "A whirl of flying needles cuts every enemy around you.", Damage = 1.15, Radius = 0.85, Look = "Blades", Color = Color3.fromRGB(240, 120, 175) },
}
local SecondSkills: { [string]: { [string]: any } } = {
	ruckus = { Name = "Quick Paws", Text = "+5% move speed.", Bonus = { speed = 0.05 } },
	toastmaster = { Name = "Crisp Edge", Text = "+5% crit chance.", Bonus = { critChance = 0.05 } },
	captain_croak = { Name = "Long Legs", Text = "+20% pickup radius.", Bonus = { pickup = 0.20 } },
	granny_boom = { Name = "Tough Old Bird", Text = "+1 armor: every hit does 1 less damage.", Bonus = { armor = 1 } },
}

function ClassRoster.Register(CharacterData: any, MetaUpgradeData: any?): { string }
	local added = {}
	local C = RunConfig.Classes
	for _, id in ipairs(C.Order) do
		local def = Defs[id]
		local num = C.Roster[id]
		if CharacterData.Characters[id] == nil and def and num then
			local entry = table.clone(def)
			entry.Id = id
			entry.Cost = num.Cost
			entry.StartWeapon = num.StartWeapon
			entry.Bonus = table.clone(num.Bonus)
			entry.Class = true -- a SwarmV2 class (not one of the old heroes)
			CharacterData.Characters[id] = entry
			table.insert(added, id)
		end
		if CharacterData.Ultimates and CharacterData.Ultimates[id] == nil and Ultimates[id] then
			CharacterData.Ultimates[id] = table.clone(Ultimates[id])
		end
		if CharacterData.SecondSkills and CharacterData.SecondSkills[id] == nil and SecondSkills[id] then
			CharacterData.SecondSkills[id] = table.clone(SecondSkills[id])
		end
		local sigs = MetaUpgradeData and MetaUpgradeData.Signature
		if sigs and sigs[id] == nil and def and num then
			local s = num.Signature
			sigs[id] = {
				Id = "Signature",
				Hero = id,
				Name = def.SignatureName,
				Description = string.format(def.SignatureFormat, s.Base) .. " now; " .. string.format(def.SignatureFormat, s.Base + s.Per * SIGNATURE_LEVELS) .. " at level " .. SIGNATURE_LEVELS .. ".",
				MaxLevel = SIGNATURE_LEVELS,
				BaseCost = 500,
				CostGrowth = 1.6,
				Trait = { Base = s.Base, Per = s.Per },
				Effect = { Format = def.SignatureFormat },
				PerLevel = table.clone(s.PerLevel),
			}
		end
	end
	-- Order: the four classes first (in class order), the old heroes hidden
	local order: { string } = CharacterData.Order
	for i = #order, 1, -1 do
		if table.find(ClassRoster.LegacyIds, order[i]) then
			table.remove(order, i)
		end
	end
	local at = 1
	for _, id in ipairs(C.Order) do
		if CharacterData.Characters[id] then
			local have = table.find(order, id)
			if have then
				table.remove(order, have)
			end
			table.insert(order, at, id)
			at += 1
		end
	end
	if CharacterData.Characters[C.Default] then
		CharacterData.Default = C.Default
	end
	return added
end

function ClassRoster.IsLegacy(id: any): boolean
	return type(id) == "string" and table.find(ClassRoster.LegacyIds, id) ~= nil
end

return ClassRoster
