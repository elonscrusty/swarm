--[[
	StageModifierData.lua
	Stage modifiers (batch B, Config.Features.StageModifiers; docs/next/STAGE_MODIFIERS.md) as
	pure functions over Config.StageModifiers, so the server (RunModifiers), the stage card
	(RunIntro), the HUD badge (StageModifierUI) and the preview scenes agree.

	  Roll(seed, stage) → id?       the modifier of `stage` for a run seed (nil before FromStage).
	                                Deterministic: the same seed gives the same list everywhere
	                                (Daily / Weekly runs use their fixed seed). One Random per
	                                call, walked from FromStage, so stage n never depends on
	                                anything but the seed; NoRepeat skips the previous stage's id.
	  Effects(id?) → table          every effect key with its multiplier (1 = none; ChestRolls 0).
	  Combine(curse, mod, cap) → n  curse x modifier, capped when the modifier raises an effect.
	  Lines(id) → { string }        plain words for each effect ("Enemies +15% speed", "+20% XP").
	  Short(id) → string            the lines joined with " · " (stage card).
	  Name(id) → string             "Swift Foes"
]]

local Config = require(script.Parent.Config)

local StageModifierData = {}

-- every effect key (multipliers default 1, counts default 0)
StageModifierData.Keys = { "EnemySpeed", "EnemyHP", "EnemyDamage", "SpawnMult", "EliteChance", "Might", "DamageTaken", "Speed", "CooldownMult", "XP", "Gold", "KillGold", "SmallChests", "ChestRolls" }
local COUNTS = { ChestRolls = true }

local function S()
	return (Config :: any).StageModifiers
end

function StageModifierData.Def(id: string?): { [string]: any }?
	if type(id) ~= "string" then
		return nil
	end
	return S().Pool[id]
end

function StageModifierData.Name(id: string?): string
	local def = StageModifierData.Def(id)
	return def and def.Name or ""
end

-- The modifier of `stage` for run seed `seed` (nil before FromStage or for a bad seed).
function StageModifierData.Roll(seed: number?, stage: number): string?
	local cfg = S()
	if type(seed) ~= "number" or seed ~= seed or type(stage) ~= "number" or stage < cfg.FromStage then
		return nil
	end
	local rng = Random.new(math.floor(math.abs(seed)) % 2147483647)
	local prev: string? = nil
	local pick: string? = nil
	for _ = cfg.FromStage, math.floor(stage) do
		local total = 0
		for _, id in ipairs(cfg.Order) do
			if not (cfg.NoRepeat and id == prev) then
				total += math.max(0, cfg.Pool[id].Weight or 1)
			end
		end
		pick = nil
		local roll = rng:NextNumber() * total
		for _, id in ipairs(cfg.Order) do
			if not (cfg.NoRepeat and id == prev) then
				roll -= math.max(0, cfg.Pool[id].Weight or 1)
				if roll <= 0 and pick == nil then
					pick = id
				end
			end
		end
		if pick == nil then
			-- float edge: the last allowed id
			for i = #cfg.Order, 1, -1 do
				local id = cfg.Order[i]
				if not (cfg.NoRepeat and id == prev) then
					pick = id
					break
				end
			end
		end
		prev = pick
	end
	return pick
end

-- Every effect key of modifier `id` (nil / unknown: all neutral). The table is shared (the
-- hooks ask per kill / spawn / gem): read it, never change it.
local memo: { [any]: { [string]: number } } = {}
local memoPool: any = nil
function StageModifierData.Effects(id: string?): { [string]: number }
	if memoPool ~= S().Pool then
		memoPool = S().Pool
		table.clear(memo)
	end
	local def = StageModifierData.Def(id)
	local key: any = def and id or false
	local hit = memo[key]
	if hit then
		return hit
	end
	local out: { [string]: number } = {}
	memo[key] = out
	for _, k in ipairs(StageModifierData.Keys) do
		local v = def and def[k]
		if COUNTS[k] then
			out[k] = type(v) == "number" and math.max(0, math.floor(v)) or 0
		else
			out[k] = (type(v) == "number" and v == v and v > 0) and v or 1
		end
	end
	return out
end

--[[
	A curse's multiplier combined with the stage modifier's for the same effect. A modifier
	that raises the effect never pushes the product past `cap` (a curse alone above the cap
	keeps its own value); a modifier that lowers it always applies.
]]
function StageModifierData.Combine(curse: number, mod: number?, cap: number?): number
	local m = mod or 1
	local v = curse * m
	if m > 1 and cap then
		v = math.max(curse, math.min(v, cap))
	end
	return v
end

local function pct(v: number): string
	local n = math.floor((v - 1) * 100 + (v >= 1 and 0.5 or -0.5))
	return (n >= 0 and "+" or "") .. n .. "%"
end

-- key → how one effect reads (v = its multiplier / count)
local LABELS: { [string]: (number) -> string } = {
	EnemySpeed = function(v) return "Enemies " .. pct(v) .. " speed" end,
	EnemyHP = function(v) return "Enemies " .. pct(v) .. " HP" end,
	EnemyDamage = function(v) return "Enemies " .. pct(v) .. " damage" end,
	SpawnMult = function(v) return pct(v) .. " enemies" end,
	EliteChance = function(v) return v >= 2 and "Elites twice as often, +1 per wave" or ("Elites " .. pct(v) .. " as often") end,
	Might = function(v) return "You deal " .. pct(v) .. " damage" end,
	DamageTaken = function(v) return "You take " .. pct(v) .. " damage" end,
	Speed = function(v) return "You " .. pct(v) .. " speed" end,
	CooldownMult = function(v) return "Weapon cooldowns " .. pct(v) end,
	XP = function(v) return pct(v) .. " XP" end,
	Gold = function(v) return pct(v) .. " gold" end,
	KillGold = function(v) return string.format("Kill gold x%g", math.floor(v * 100 + 0.5) / 100) end,
	SmallChests = function(v) return v < 1 and "Fewer chests" or "More chests" end,
	ChestRolls = function(v) return "Elite chests +" .. v .. " roll" end,
}

-- Plain lines for modifier `id`, in Keys order (only the effects it has).
function StageModifierData.Lines(id: string?): { string }
	local def = StageModifierData.Def(id)
	local out = {}
	if not def then
		return out
	end
	local e = StageModifierData.Effects(id)
	for _, k in ipairs(StageModifierData.Keys) do
		local v = e[k]
		if (COUNTS[k] and v > 0) or (not COUNTS[k] and math.abs(v - 1) > 1e-6) then
			table.insert(out, LABELS[k](v))
		end
	end
	return out
end

function StageModifierData.Short(id: string?): string
	return table.concat(StageModifierData.Lines(id), " · ")
end

return StageModifierData
