--[[
	ItemData.lua
	Run-only ITEMS (Risk of Rain / Megabonk style): small stacking pick-ups from chests and
	shrines (src/server/Modules/LootSystem.lua). Items last for the whole run (kept across
	stages) and are gone when the run ends (return, defeat, leaving). Server: ItemSystem.lua.

	19 items in 3 rarities (colours: Theme.ItemRarity), every one with an effect you can see
	or clearly feel, and its value in plain words:
	  Common     ivory      8 items, stat bumps + one proc
	  Uncommon   slate-blue 8 items, procs / behaviours and crit damage
	  Legendary  gold       3 items, big all-rounders and a one-time revive

	Every item STACKS. How a stack grows is written in `Stack`:
	  Linear      each copy adds the same amount (PerStack x copies)
	  Hyperbolic  1 - 1 / (1 + k x copies): every copy helps, the total never reaches 100%
	              (k is the item's `K`; the first copy gives a bit less than k)
	  Special     written in the item's text (shorter intervals with a floor, consumed ...)

	Stat keys (PerStack, summed into LevelUpSystem.RecomputeStats with the passives):
	  might        +damage            attackSpeed  +attacks per second (divides cooldowns)
	  speed        +move speed        maxHpFlat    +max HP (flat)      maxHpMult  +max HP %
	  regen        HP per second      pickup       +pickup radius      luck       +luck
	  critChance   +crit chance       critDamage   +crit damage (on top of Config.Items.BaseCritDamage)
	  area         +attack area       duration     +effect duration
	  goldGain     +gold from kills (also used by the Bargain Shrine)
	Hyperbolic stats: DamageReduce (damage taken x 1 / (1 + K x copies)), the proc chances.

	Synergies: Keen Lens / Hunter's Eye (Deadeye) and Iron Plate / Barbed Mail (Bulwark) are
	pieces of the build synergies in SynergyData.lua.

	Balance rule: no single item breaks a run. Ten copies of a common are about one maxed
	passive; the procs have internal cooldowns (Config.Items) so huge swarms stay cheap.
]]

local ItemData = {}

ItemData.Rarities = { "Common", "Uncommon", "Legendary" }

export type Item = {
	Id: string,
	Name: string,
	Rarity: string,
	Text: string, -- one short line (pickup popup, HUD)
	Desc: string, -- full text with the stacking rule (pause menu list)
	Stack: string, -- "Linear" | "Hyperbolic" | "Special"
	PerStack: { [string]: number }?,
	K: number?, -- hyperbolic coefficient
	Proc: string?, -- behaviour handled by ItemSystem
	MaxStacks: number?, -- most copies a player can hold; another copy re-rolls (ItemSystem.Grant)
}

local ITEMS: { Item } = {
	-- Common ------------------------------------------------------------------------------
	{ Id = "Whetstone", Name = "Whetstone", Rarity = "Common", Stack = "Linear", PerStack = { might = 0.10 }, Text = "+10% damage", Desc = "+10% damage per stack." },
	{ Id = "QuickGloves", Name = "Quick Gloves", Rarity = "Common", Stack = "Linear", PerStack = { attackSpeed = 0.06 }, Text = "+6% attack speed", Desc = "Weapons attack 6% faster per stack." },
	{ Id = "SwiftFeather", Name = "Swift Feather", Rarity = "Common", Stack = "Linear", PerStack = { speed = 0.05 }, Text = "+5% move speed", Desc = "+5% move speed per stack." },
	{ Id = "HeartyBread", Name = "Hearty Bread", Rarity = "Common", Stack = "Linear", PerStack = { maxHpFlat = 15 }, Text = "+15 max HP", Desc = "+15 max HP per stack (heals that much too)." },
	{ Id = "Bandage", Name = "Bandage Roll", Rarity = "Common", Stack = "Linear", PerStack = { regen = 1.0 }, Text = "Regenerate 1 HP/s", Desc = "Regenerate 1 HP per second per stack." },
	{ Id = "Lodestone", Name = "Lodestone", Rarity = "Common", Stack = "Linear", PerStack = { pickup = 0.2 }, Text = "+20% pickup radius", Desc = "+20% gem pickup radius per stack." },
	{ Id = "KeenLens", Name = "Keen Lens", Rarity = "Common", Stack = "Linear", PerStack = { critChance = 0.05 }, Text = "+5% critical chance", Desc = "+5% chance per stack to land a critical hit (x2 damage; total chance max 60%)." },
	{ Id = "HealingHerb", Name = "Healing Herb", Rarity = "Common", Stack = "Hyperbolic", K = 0.05, Proc = "HealOnKill", Text = "5% of kills heal 3 HP", Desc = "Kills have a ~5% chance to heal 3 HP (hyperbolic: 2 stacks 9%, 5 stacks 20%)." },

	-- Uncommon ----------------------------------------------------------------------------
	{ Id = "IronPlate", Name = "Iron Plate", Rarity = "Uncommon", Stack = "Hyperbolic", K = 0.06, Text = "Take 6% less damage", Desc = "Take less damage (hyperbolic: 1 stack 6%, 3 stacks 15%, 10 stacks 38%)." },
	{ Id = "BarbedMail", Name = "Barbed Mail", Rarity = "Uncommon", Stack = "Linear", Proc = "Thorns", Text = "When hit, hit back x1.5", Desc = "When hit, deal 150% of the damage taken (+100% per stack) to enemies within 8 studs, once every 0.5 s." },
	{ Id = "StormCharm", Name = "Storm Charm", Rarity = "Uncommon", Stack = "Hyperbolic", K = 0.11, Proc = "Lightning", Text = "10% of hits call lightning", Desc = "Hits have a ~10% chance to strike 3 enemies (+1 per stack, max 5) for 40% of the hit; 2 stacks 18%." },
	{ Id = "VolatileSpore", Name = "Volatile Spore", Rarity = "Uncommon", Stack = "Linear", Proc = "Explode", Text = "20% of kills explode", Desc = "20% of kills burst for 60% of the enemy's max HP (+30% per stack) within 7 studs; bosses take at most 5%." },
	{ Id = "GuardianWard", Name = "Guardian Ward", Rarity = "Uncommon", Stack = "Linear", Proc = "Shield", Text = "8% HP shield after 5 s unhurt", Desc = "After 5 s without damage, gain a shield of 8% max HP per stack (up to 40%)." },
	{ Id = "SpareQuiver", Name = "Spare Quiver", Rarity = "Uncommon", Stack = "Special", Proc = "ExtraShot", Text = "+1 projectile every 6th attack", Desc = "Every 6th attack of each weapon fires +1 projectile (not Garlic Aura); each stack makes it 1 attack sooner (min every 2nd)." },
	{ Id = "MagnetTotem", Name = "Magnet Totem", Rarity = "Uncommon", Stack = "Special", Proc = "MagnetPulse", Text = "Pull gems every 10 s", Desc = "Every 10 s pull gems within 45 studs. Each stack: -2 s (min 4 s) and +10 studs." },
	{ Id = "HuntersEye", Name = "Hunter's Eye", Rarity = "Uncommon", Stack = "Linear", PerStack = { critDamage = 0.3, critChance = 0.03 }, Text = "+30% crit damage", Desc = "+30% critical damage and +3% critical chance per stack." },

	-- Legendary ---------------------------------------------------------------------------
	{ Id = "PhoenixFeather", Name = "Phoenix Feather", Rarity = "Legendary", Stack = "Special", Proc = "Revive", MaxStacks = 2, Text = "Rise again once at 50% HP", Desc = "When you fall, rise again at 50% HP. Used up (each stack is one more life; hold at most 2)." },
	{ Id = "CrownOfAges", Name = "Crown of Ages", Rarity = "Legendary", Stack = "Linear", PerStack = { might = 0.12, attackSpeed = 0.08, speed = 0.08, maxHpMult = 0.1 }, Text = "+12% damage, +8% speed, +10% HP", Desc = "+12% damage, +8% attack speed, +8% move speed and +10% max HP per stack." },
	{ Id = "SunMedallion", Name = "Sun Medallion", Rarity = "Legendary", Stack = "Linear", PerStack = { might = 0.18, area = 0.12, duration = 0.12 }, Text = "+18% damage, +12% area", Desc = "+18% damage, +12% attack area and +12% effect duration per stack." },
}

ItemData.Order = {} :: { string }
ItemData.Items = {} :: { [string]: Item }
ItemData.ByRarity = { Common = {}, Uncommon = {}, Legendary = {} } :: { [string]: { string } }
for _, item in ipairs(ITEMS) do
	table.insert(ItemData.Order, item.Id)
	ItemData.Items[item.Id] = item
	table.insert(ItemData.ByRarity[item.Rarity], item.Id)
end

-- Every additive stat key items can add (LevelUpSystem sums these).
ItemData.StatKeys = { "might", "attackSpeed", "speed", "maxHpFlat", "maxHpMult", "regen", "pickup", "luck", "critChance", "critDamage", "goldGain", "area", "duration" }

-- 1 - 1 / (1 + k n): the hyperbolic stacking curve.
function ItemData.Hyperbolic(k: number, n: number): number
	if n <= 0 then
		return 0
	end
	return 1 - 1 / (1 + k * n)
end

--[[
	Stat bonus of a stack table { [itemId] = count }: additive keys (see StatKeys) plus
	DamageTakenMult (Iron Plate, multiplies the damage taken).
]]
function ItemData.Bonus(counts: { [string]: number }): { [string]: number }
	local b: { [string]: number } = { DamageTakenMult = 1 }
	for _, k in ipairs(ItemData.StatKeys) do
		b[k] = 0
	end
	for id, n in pairs(counts) do
		local def = ItemData.Items[id]
		if def and n > 0 then
			if def.PerStack then
				for k, v in pairs(def.PerStack) do
					b[k] = (b[k] or 0) + v * n
				end
			end
			if id == "IronPlate" then
				b.DamageTakenMult *= 1 / (1 + (def.K or 0) * n)
			end
		end
	end
	return b
end

-- Weighted rarity roll. weights = { Common = w, Uncommon = w, Legendary = w }; luck raises
-- the Uncommon / Legendary weights by (1 + luck). `roll` is a 0-1 random number.
function ItemData.RollRarity(weights: { [string]: number }, luck: number, roll: number): string
	local l = math.clamp(luck, 0, 2)
	local w = {
		Common = weights.Common or 0,
		Uncommon = (weights.Uncommon or 0) * (1 + l),
		Legendary = (weights.Legendary or 0) * (1 + l),
	}
	local total = w.Common + w.Uncommon + w.Legendary
	if total <= 0 then
		return "Common"
	end
	local r = roll * total
	for _, name in ipairs(ItemData.Rarities) do
		r -= w[name]
		if r <= 0 then
			return name
		end
	end
	return "Common"
end

--[[
	Prices. StagePrice = base x stage^exponent (Config.Chests.CostExponent): what a chest or
	shrine costs on this stage before the player's own multiplier. PlayerPrice multiplies
	that by the player's gold multiplier (gamepasses pay out more gold, so their owners pay
	the same share of their income: a pass never buys extra items). Shared, so the client
	shows exactly the price the server charges.
]]
function ItemData.StagePrice(base: number, stage: number, exponent: number): number
	return math.floor(base * math.max(1, stage) ^ exponent + 0.5)
end

function ItemData.PlayerPrice(price: number, goldMult: number?): number
	return math.max(1, math.floor(price * (goldMult or 1) + 0.5))
end

return ItemData
