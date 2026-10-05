--[[
	SigilData.lua
	Sigils (feature 1, Config.Features.Sigils; docs/SIGILS_PLAN.md, docs/features/META.md).
	Permanent charms earned by play: bosses and elites sometimes drop one. Each Sigil gives
	something and takes something of the same size away, so none is simply stronger.
	No Robux anywhere: Sigils are never sold, traded or bought.

	Per Sigil: Id, Name, Rarity ("Common" | "Rare"), Bonus (StatSheet bonus keys, added
	after the hero's upgrades), Special? (what a stat cannot say), Text (one short line for
	cards), Icon (an existing menu icon name).

	Specials:
	  StartWeapon  the run starts with that weapon too (Clove Bulb: Garlic Aura)
	  FewerFirst   the first level-up card set shows one card fewer
	  ChestRefund  this share of the gold paid at chests and shrines comes back
	  NoRegen      no health regeneration (StatSheet sets Regen to 0)
	  LoneWolf     +Might while no living ally is within LoneWolfRange, -Might while one is
]]

local SigilData = {}

SigilData.Order = {
	"HaresFoot",
	"CloveBulb",
	"HagglersCoin",
	"GlassEye",
	"TortoiseShell",
	"EmberHeart",
	"Lodestar",
	"MisersPurse",
	"ScholarsQuill",
	"HourglassSand",
	"WideBrim",
	"LoneWolf",
}

SigilData.Sigils = {
	HaresFoot = { Name = "Hare's Foot", Rarity = "Common", Bonus = { speed = 0.15, maxHpMult = -0.10 }, Text = "+15% move speed, -10% max HP", Icon = "boot" },
	CloveBulb = { Name = "Clove Bulb", Rarity = "Rare", Bonus = {}, Special = { StartWeapon = "Garlic", FewerFirst = true }, Text = "Start with Garlic Aura, 1 card fewer on your first level-up", Icon = "Garlic" },
	HagglersCoin = { Name = "Haggler's Coin", Rarity = "Common", Bonus = { might = -0.05 }, Special = { ChestRefund = 0.10 }, Text = "10% of chest gold back, -5% damage", Icon = "coin" },
	GlassEye = { Name = "Glass Eye", Rarity = "Rare", Bonus = { critChance = 0.08, damageTaken = 0.08 }, Text = "+8% crit chance, take 8% more damage", Icon = "aim" },
	TortoiseShell = { Name = "Tortoise Shell", Rarity = "Common", Bonus = { armor = 2, speed = -0.10 }, Text = "+2 armor, -10% move speed", Icon = "shield" },
	EmberHeart = { Name = "Ember Heart", Rarity = "Common", Bonus = { might = 0.10 }, Special = { NoRegen = true }, Text = "+10% damage, no health regen", Icon = "heart" },
	Lodestar = { Name = "Lodestar", Rarity = "Common", Bonus = { pickup = 0.40, area = -0.08 }, Text = "+40% pickup radius, -8% area", Icon = "magnet" },
	MisersPurse = { Name = "Miser's Purse", Rarity = "Common", Bonus = { goldGain = 0.15, growth = -0.10 }, Text = "+15% gold, -10% XP", Icon = "pouch" },
	ScholarsQuill = { Name = "Scholar's Quill", Rarity = "Common", Bonus = { growth = 0.12, goldGain = -0.10 }, Text = "+12% XP, -10% gold", Icon = "sparkle" },
	HourglassSand = { Name = "Hourglass Sand", Rarity = "Rare", Bonus = { cooldown = 0.08, duration = -0.15 }, Text = "Weapons 8% faster, effects 15% shorter", Icon = "hourglass" },
	WideBrim = { Name = "Wide Brim", Rarity = "Common", Bonus = { area = 0.15, projSpeed = -0.10 }, Text = "+15% area, -10% projectile speed", Icon = "area" },
	LoneWolf = { Name = "Lone Wolf", Rarity = "Rare", Bonus = {}, Special = { LoneWolf = 0.10 }, Text = "+10% damage with no ally near, -10% with one", Icon = "person" },
}
for id, def in pairs(SigilData.Sigils) do
	def.Id = id
end

SigilData.LoneWolfRange = 30 -- studs
SigilData.DupeGold = { Common = 150, Rare = 400 } -- a copy you already own turns into gold
SigilData.RarityWeight = { Common = 3, Rare = 1 } -- which Sigil a drop is
SigilData.BossChance = 0.25 -- per boss kill, per player (each rolls for themselves)
SigilData.EliteChance = 0.02 -- per elite the player kills (not guards / wave elites)
SigilData.ElitePerRun = 1 -- elite Sigils per player per run
SigilData.KeepOnLoss = 0.35 -- a found Sigil is kept on a loss this often (a win / portal keeps it)
SigilData.SlotUnlockMastery = 3 -- slot 2 opens when any hero reaches this Hero Mastery
SigilData.BaseSlots = 1

-- How many Sigil slots this save has (2 once any hero reaches SlotUnlockMastery).
-- masteryFor: MetaUpgradeData.MasteryFor (passed in to keep this module dependency-free).
function SigilData.SlotsFor(data: any, masteryFor: (number) -> number): number
	local slots = SigilData.BaseSlots
	if type(data) == "table" and type(data.Heroes) == "table" then
		for _, h in pairs(data.Heroes) do
			if type(h) == "table" and masteryFor(tonumber(h.XP) or 0) >= SigilData.SlotUnlockMastery then
				return slots + 1
			end
		end
	end
	return slots
end

-- A weighted pick (rng: a Random). Returns a Sigil id.
function SigilData.Roll(rng: Random): string
	local total = 0
	for _, id in ipairs(SigilData.Order) do
		total += SigilData.RarityWeight[SigilData.Sigils[id].Rarity] or 1
	end
	local r = rng:NextNumber() * total
	for _, id in ipairs(SigilData.Order) do
		r -= SigilData.RarityWeight[SigilData.Sigils[id].Rarity] or 1
		if r <= 0 then
			return id
		end
	end
	return SigilData.Order[#SigilData.Order]
end

-- The worn set of valid ids ({id → true}) from an equipped list, at most `slots`.
function SigilData.Set(equipped: any, slots: number): { [string]: boolean }
	local out = {}
	local n = 0
	if type(equipped) ~= "table" then
		return out
	end
	for _, id in ipairs(equipped) do
		if type(id) == "string" and SigilData.Sigils[id] and not out[id] and n < slots then
			out[id] = true
			n += 1
		end
	end
	return out
end

return SigilData
