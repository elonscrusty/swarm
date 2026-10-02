--[[
	StatSheet.lua
	The player's run stat sheet as a pure function (no instances, no side effects), so the
	server (LevelUpSystem.RecomputeStats), the level-up cards ("Max HP 120 → 144") and the
	preview scenes all compute it the same way.

	StatSheet.Compute(input) → sheet
	  input = {
	    CharacterId = "Knight",            -- CharacterData bonus
	    Meta = { [upgradeId] = level },    -- permanent upgrades (MetaUpgradeData.PerLevel)
	    Passives = { [passiveId] = level },-- PassiveData.Values[level] (TOTAL bonus per level)
	    Items = { [itemId] = count },      -- run items (ItemData.Bonus)
	    Team = { might = 0.15, ... }?,     -- this stage's Bargain Shrine boon (LootSystem)
	  }
	  sheet = { Might, Armor, MaxHP, Speed, CooldownMult, AreaMult, Amount, Pierce,
	            PickupRadius, Luck, ProjSpeedMult, DurationMult, Growth, DamageTaken, Regen,
	            CritChance, CritDamage, GoldMult }

	StatSheet.Lines(before, after) → { {Key, Label, From, To} } the stats that differ, in
	plain words with display values (used by passive level-up cards).
]]

local Config = require(script.Parent.Config)
local CharacterData = require(script.Parent.CharacterData)
local MetaUpgradeData = require(script.Parent.MetaUpgradeData)
local PassiveData = require(script.Parent.PassiveData)
local ItemData = require(script.Parent.ItemData)

local StatSheet = {}

local BONUS_KEYS = { "might", "armor", "maxHpMult", "maxHpFlat", "speed", "cooldown", "area", "amount", "pierce", "pickup", "luck", "projSpeed", "duration", "growth", "damageTaken" }
for _, k in ipairs(ItemData.StatKeys) do
	if not table.find(BONUS_KEYS, k) then
		table.insert(BONUS_KEYS, k) -- attackSpeed, regen, critChance, critDamage, goldGain
	end
end
StatSheet.BonusKeys = BONUS_KEYS

export type Input = {
	CharacterId: string?,
	Meta: { [string]: number }?,
	Passives: { [string]: number }?,
	Items: { [string]: number }?,
	Team: { [string]: number }?,
}

function StatSheet.Compute(input: Input): { [string]: number }
	local b: { [string]: number } = {}
	for _, k in ipairs(BONUS_KEYS) do
		b[k] = 0
	end
	local function addAll(t: { [string]: number }?)
		if not t then
			return
		end
		for k, v in pairs(t) do
			if b[k] ~= nil and type(v) == "number" then
				b[k] += v
			end
		end
	end

	local character = input.CharacterId and CharacterData.Characters[input.CharacterId]
	addAll(character and character.Bonus)
	for upgradeId, level in pairs(input.Meta or {}) do
		local def = MetaUpgradeData.Upgrades[upgradeId]
		if def and def.PerLevel then
			for k, v in pairs(def.PerLevel) do
				if b[k] ~= nil then
					b[k] += v * level
				end
			end
		end
	end
	for passiveId, level in pairs(input.Passives or {}) do
		local def = PassiveData.Passives[passiveId]
		if def then
			addAll(def.Values[math.clamp(level, 1, #def.Values)])
		end
	end
	local items = ItemData.Bonus(input.Items or {})
	addAll(items)
	addAll(input.Team)

	local P = Config.Player
	local I = Config.Items
	return {
		Might = 1 + b.might,
		Armor = P.BaseArmor + b.armor,
		MaxHP = math.floor((P.BaseMaxHP + b.maxHpFlat) * (1 + b.maxHpMult) + 0.5),
		Speed = P.BaseSpeed * math.min(1 + b.speed, I.MaxSpeedMult),
		-- passive cooldown reduction, then item attack speed divides what is left
		CooldownMult = math.max(I.MinCooldownMult, math.max(0.4, 1 - b.cooldown) / (1 + b.attackSpeed)),
		AreaMult = 1 + b.area,
		Amount = b.amount,
		Pierce = b.pierce, -- extra enemies a stopping projectile passes through (Fletching)
		PickupRadius = P.BasePickupRadius * (1 + b.pickup),
		Luck = P.BaseLuck + b.luck,
		ProjSpeedMult = 1 + b.projSpeed,
		DurationMult = 1 + b.duration,
		Growth = 1 + b.growth,
		DamageTaken = math.max(0.1, 1 + b.damageTaken) * (items.DamageTakenMult or 1),
		Regen = b.regen, -- HP per second
		CritChance = math.clamp(I.BaseCritChance + b.critChance, 0, I.MaxCritChance),
		CritDamage = I.BaseCritDamage + b.critDamage,
		GoldMult = 1 + b.goldGain, -- in-run gold (kills, elite chests, the Queen)
	}
end

local function pct(mult: number): string
	local v = math.floor((mult - 1) * 100 + 0.5)
	return (v >= 0 and "+" or "") .. v .. "%"
end

local function num(v: number): string
	if math.abs(v - math.floor(v + 0.5)) < 0.05 then
		return tostring(math.floor(v + 0.5))
	end
	return string.format("%.1f", v)
end

-- Sheet key → label and how to print its value. Only stats a passive can change.
local LINES = {
	{ Key = "MaxHP", Label = "Max HP", Fmt = num },
	{ Key = "Might", Label = "Damage", Fmt = pct },
	{ Key = "Armor", Label = "Armor", Fmt = num },
	{ Key = "Speed", Label = "Move speed", Fmt = num },
	{
		Key = "CooldownMult",
		Label = "Attack cooldown",
		Fmt = function(v: number): string
			local r = math.floor((1 - v) * 100 + 0.5)
			return r > 0 and ("-" .. r .. "%") or "0%"
		end,
	},
	{ Key = "AreaMult", Label = "Area", Fmt = pct },
	{
		Key = "Amount",
		Label = "Extra projectiles",
		Fmt = function(v: number): string
			return "+" .. num(v)
		end,
	},
	{
		Key = "Pierce",
		Label = "Extra pierce",
		Fmt = function(v: number): string
			return "+" .. num(v)
		end,
	},
	{
		Key = "PickupRadius",
		Label = "Pickup radius",
		Fmt = function(v: number): string
			return num(v) .. " studs"
		end,
	},
	{
		Key = "Luck",
		Label = "Luck",
		Fmt = function(v: number): string
			return pct(1 + v)
		end,
	},
	{ Key = "ProjSpeedMult", Label = "Projectile speed", Fmt = pct },
	{ Key = "DurationMult", Label = "Duration", Fmt = pct },
	{ Key = "Growth", Label = "XP gain", Fmt = pct },
}

-- Stats that differ between two sheets, as display lines.
function StatSheet.Lines(before: { [string]: number }, after: { [string]: number }): { { [string]: string } }
	local out = {}
	for _, l in ipairs(LINES) do
		local a, b = before[l.Key], after[l.Key]
		if a and b and math.abs(a - b) > 1e-6 then
			local from, to = l.Fmt(a), l.Fmt(b)
			if from ~= to then
				table.insert(out, { Key = l.Key, Label = l.Label, From = from, To = to })
			end
		end
	end
	return out
end

return StatSheet
