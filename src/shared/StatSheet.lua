--[[
	StatSheet.lua
	The player's run stat sheet as a pure function (no instances, no side effects), so the
	server (LevelUpSystem.RecomputeStats), the level-up cards ("Max HP 120 → 144") and the
	preview scenes all compute it the same way.

	StatSheet.Compute(input) → sheet
	  input = {
	    CharacterId = "Knight",            -- CharacterData bonus
	    Meta = { [upgradeId] = level },    -- permanent upgrades (MetaUpgradeData.PerLevel): the
	                                       -- account ids, the hero's stat track and
	                                       -- Signature (the hero's trait upgrade)
	    Passives = { [passiveId] = level },-- PassiveData.Values[level] (TOTAL bonus per level)
	    Items = { [itemId] = count },      -- run items (ItemData.Bonus)
	    Team = { might = 0.15, ... }?,     -- this stage's Bargain Shrine boon (LootSystem)
	    Curse = { MaxHP = 0.7, Might = 1.3, DamageTaken = 1.3 }?, -- the run's curses
	                                       -- (CurseData), final multipliers
	  }
	  sheet = { Might, Armor, MaxHP, Speed, CooldownMult, AreaMult, Amount, Pierce,
	            PickupRadius, Luck, ProjSpeedMult, DurationMult, Growth, DamageTaken, Regen,
	            CritChance, CritDamage, GoldMult, EliteDamage, Thorns, CritHeal, WardSeconds,
	            KillRush, LevelHeal, BurnChance, LowHpMight, StillHeal }

	StatSheet.Lines(before, after) → { {Key, Label, From, To} } the stats that differ, in
	plain words with display values (used by passive level-up cards).
]]

local Config = require(script.Parent.Config)
local CharacterData = require(script.Parent.CharacterData)
local MetaUpgradeData = require(script.Parent.MetaUpgradeData)
local PassiveData = require(script.Parent.PassiveData)
local ItemData = require(script.Parent.ItemData)

local StatSheet = {}

local BONUS_KEYS = { "might", "armor", "maxHpMult", "maxHpFlat", "speed", "cooldown", "area", "amount", "pierce", "pickup", "luck", "projSpeed", "duration", "growth", "damageTaken",
	-- behaviour passives (PassiveData; read by ItemSystem)
	"eliteDamage", "thorns", "critHeal", "ward", "killRush", "levelHeal", "burnChance", "lowHpMight", "stillHeal" }
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
	Curse: { [string]: number }?,
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
		-- "Signature": the hero's own trait upgrade (only the stat traits carry PerLevel)
		local def = if upgradeId == "Signature"
			then (input.CharacterId and MetaUpgradeData.Signature[input.CharacterId])
			else MetaUpgradeData.Upgrades[upgradeId]
		if def and def.PerLevel and type(level) == "number" then
			-- a saved level is never trusted past the upgrade's own range (an over-max,
			-- negative, NaN or infinite level would scale the bonus without limit)
			local l = if level == level then math.clamp(math.floor(level), 0, def.MaxLevel or 0) else 0
			for k, v in pairs(def.PerLevel) do
				if b[k] ~= nil then
					b[k] += v * l
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
	local curse = input.Curse or {}
	local sheet = {
		Might = 1 + b.might,
		Armor = P.BaseArmor + b.armor,
		MaxHP = math.floor((P.BaseMaxHP + b.maxHpFlat) * (1 + b.maxHpMult) + 0.5),
		Speed = P.BaseSpeed * math.clamp(1 + b.speed, 0.5, I.MaxSpeedMult),
		-- passive cooldown reduction, then item attack speed divides what is left
		CooldownMult = math.max(I.MinCooldownMult, math.max(0.4, 1 - b.cooldown) / math.max(0.1, 1 + b.attackSpeed)),
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
		-- behaviour passives (ItemSystem reads them)
		EliteDamage = 1 + b.eliteDamage, -- damage multiplier against elites and bosses
		Thorns = math.max(0, b.thorns), -- share of a hit dealt back around the player
		CritHeal = math.max(0, b.critHeal), -- HP per critical hit
		WardSeconds = math.max(0, b.ward), -- one-hit ward recharge (0 = no ward)
		KillRush = math.max(0, b.killRush), -- +move speed for a moment after a kill
		LevelHeal = math.clamp(b.levelHeal, 0, 1), -- share of max HP healed per level-up
		BurnChance = math.clamp(b.burnChance, 0, PassiveData.Tuning.MaxBurnChance),
		LowHpMight = 1 + b.lowHpMight, -- damage multiplier while badly hurt (Lionheart)
		StillHeal = math.max(0, b.stillHeal), -- share of max HP per second standing still
	}
	-- curses multiply the finished sheet (Fragile, Glass Cannon)
	sheet.MaxHP = math.max(1, math.floor(sheet.MaxHP * (curse.MaxHP or 1) + 0.5))
	sheet.Might *= curse.Might or 1
	sheet.DamageTaken *= curse.DamageTaken or 1
	return sheet
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

--[[
	Sheet key → label and how to print its value. Only stats a passive can change.
	Values are TOTALS for the whole build (hero trait, permanent upgrades, items and
	passives together), so a first pick can start from a non-zero value (Knight's Iron
	Skin makes Stoneskin read "Damage reduction 10% → 16%"). Distances print in m: the
	game's distance unit (1 stud), the same unit the HUD's markers use.
]]
local TUNING = PassiveData.Tuning
local LINES = {
	{ Key = "MaxHP", Label = "Max HP", Fmt = num },
	{ Key = "Might", Label = "Damage", Fmt = pct },
	{ Key = "Armor", Label = "Armor", Fmt = num },
	{
		Key = "Speed",
		Label = "Move speed",
		-- against the base speed, like Speed Boots' "+10% per level" (was a bare 17.6)
		Fmt = function(v: number): string
			return pct(v / Config.Player.BaseSpeed)
		end,
	},
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
			return num(v) .. " m"
		end,
	},
	{
		Key = "Luck",
		Label = "Luck",
		Fmt = function(v: number): string
			return pct(1 + v)
		end,
	},
	{
		Key = "CritChance",
		Label = "Crit chance",
		Fmt = function(v: number): string
			return math.floor(v * 100 + 0.5) .. "%"
		end,
	},
	{
		Key = "Regen",
		Label = "HP regen",
		Fmt = function(v: number): string
			return num(v) .. " HP/s"
		end,
	},
	{ Key = "ProjSpeedMult", Label = "Projectile speed", Fmt = pct },
	{ Key = "DurationMult", Label = "Duration", Fmt = pct },
	{ Key = "Growth", Label = "XP gain", Fmt = pct },
	{ Key = "EliteDamage", Label = "Elite and boss damage", Fmt = pct },
	{
		Key = "Thorns",
		-- ItemSystem.OnHurt: a share of the damage you took (at least half the raw hit),
		-- times your damage, to enemies around you
		Label = "Thorns (of hit taken)",
		Fmt = function(v: number): string
			return math.floor(v * 100 + 0.5) .. "%"
		end,
	},
	{
		Key = "CritHeal",
		Label = "Heal per crit",
		Fmt = function(v: number): string
			return num(v) .. " HP"
		end,
	},
	{
		Key = "WardSeconds",
		Label = "Ward recharge",
		Fmt = function(v: number): string
			return v > 0 and (num(v) .. " s") or "none"
		end,
	},
	{
		Key = "KillRush",
		Label = string.format("Speed %s s after a kill", num(TUNING.WindstepSeconds)),
		Fmt = function(v: number): string
			return pct(1 + v)
		end,
	},
	{ Key = "GoldMult", Label = "Gold", Fmt = pct },
	{
		Key = "DamageTaken",
		-- the sheet keeps a multiplier on damage taken (0.84 = 16% less); the card shows the
		-- reduction as a plain positive share (negative only when curses raise damage taken)
		Label = "Damage reduction",
		Fmt = function(v: number): string
			return math.floor((1 - v) * 100 + 0.5) .. "%"
		end,
	},
	{
		Key = "LevelHeal",
		Label = "Heal per level-up",
		Fmt = function(v: number): string
			return math.floor(v * 100 + 0.5) .. "% max HP"
		end,
	},
	{
		Key = "BurnChance",
		Label = "Burn chance",
		Fmt = function(v: number): string
			return math.floor(v * 100 + 0.5) .. "%"
		end,
	},
	{ Key = "LowHpMight", Label = string.format("Damage below %d%% max HP", math.floor(TUNING.LionheartHp * 100 + 0.5)), Fmt = pct },
	{
		Key = "StillHeal",
		Label = "Heal standing still",
		Fmt = function(v: number): string
			return num(v * 100) .. "% max HP/s"
		end,
	},
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
