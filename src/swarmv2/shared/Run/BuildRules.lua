--!strict
--[[
	SwarmV2/Run/BuildRules.lua  (ReplicatedStorage.SwarmV2.Run.BuildRules)
	OWNER: gameplay track, stream B. The continuation brief's build and combat formulas as pure
	functions (no instances, no state), shared by the server (WeaponSystem, LevelUpSystem,
	StatSheet), the cards / inventory and the offline regressions (builds-sim). Numbers:
	RunConfig.Builds / RunConfig.Combat. Notes: docs/redesign/gameplay/BUILDS.md.

	  RankMult(r)                     1 + 0.20 (r - 1), r clamped 1..MaxRank
	  HitDamage(coeff, r, bonus)      B x coeff x RankMult(r) x (1 + clamp(bonus, 0, 2))
	  Interval(base, r, attackSpeed)  max(0.25, base x 0.95^(r - 1) / (1 + clamp(attackSpeed, 0, 1)))
	  CritChance(bonus, base?)        clamp(base (5 %) + bonus, 0, 50 %)
	  ArmorMult(A)                    1 - A / (100 + A), A clamped 0..100 (never negative damage)
	  RarityTable(capacity)           the rank-grant tiers that fit (Common +1 ... Epic +4)
	  RollRarity(rng, capacity)       one tier, weights renormalised over the tiers that fit
	  RollOffer(rng, pool, n)         up to n distinct options: category by weight (empty ones
	                                  removed, renormalised), item uniform inside the category
	  SlowMult(share, boss)           1 - min(share, cap): 40 % normally, 10 % on bosses
	  Knockback(kind, studsPerSecond) bosses 0, elites half, everything capped at 24
	  Stagger(kind, seconds)          bosses 0, elites at most 0.15 s
	  ScorchTickDamage(mult)          0.12 B per second x mult, per 0.5 s tick
]]

local RunConfig = require(script.Parent.RunConfig)

local Builds: any = RunConfig.Builds
local Combat: any = RunConfig.Combat

local BuildRules = {}

export type Tier = { Name: string, Ranks: number, Weight: number, Label: string?, Color: Color3? }
export type Rng = { NextNumber: (self: any) -> number, NextInteger: (self: any, number, number) -> number }

-- True while the rank system is the live one (RunConfig.Builds.Enabled).
function BuildRules.On(): boolean
	return Builds.Enabled == true
end

function BuildRules.B(): number
	return Builds.B
end

function BuildRules.MaxRank(): number
	return Builds.MaxRank
end

local function clampRank(r: number?): number
	local n = tonumber(r) or 1
	if n ~= n then
		n = 1
	end
	return math.clamp(math.floor(n), 1, Builds.MaxRank)
end
BuildRules.ClampRank = clampRank

local function clampBonus(v: number?, max: number): number
	local n = tonumber(v) or 0
	if n ~= n then
		return 0
	end
	return math.clamp(n, 0, max)
end

function BuildRules.DamageBonus(v: number?): number
	return clampBonus(v, Combat.DamageBonusMax)
end

function BuildRules.AttackSpeed(v: number?): number
	return clampBonus(v, Combat.AttackSpeedMax)
end

function BuildRules.RankMult(r: number?): number
	return 1 + Builds.RankDamageStep * (clampRank(r) - 1)
end

function BuildRules.HitDamage(coeff: number, r: number?, bonus: number?): number
	return math.max(0, Builds.B * coeff * BuildRules.RankMult(r) * (1 + BuildRules.DamageBonus(bonus)))
end

-- The rank's own interval (before attack speed and the floor).
function BuildRules.RankInterval(base: number, r: number?): number
	return base * Builds.RankIntervalMult ^ (clampRank(r) - 1)
end

function BuildRules.Interval(base: number, r: number?, attackSpeed: number?): number
	return math.max(Combat.MinInterval, BuildRules.RankInterval(base, r) / (1 + BuildRules.AttackSpeed(attackSpeed)))
end

function BuildRules.CritChance(bonus: number?, base: number?): number
	local b = tonumber(base) or Combat.CritBase
	local v = b + (tonumber(bonus) or 0)
	if v ~= v then
		v = b
	end
	return math.clamp(v, 0, Combat.CritMax)
end

function BuildRules.ArmorMult(armor: number?): number
	local a = tonumber(armor) or 0
	if a ~= a then
		a = 0
	end
	a = math.clamp(a, 0, Combat.ArmorMax)
	return 1 - a / (100 + a)
end

-- The tiers whose rank grant fits in `capacity` remaining ranks (an acquisition has 5).
function BuildRules.RarityTable(capacity: number): { Tier }
	local out = {}
	for _, t in ipairs(Builds.Rarities) do
		if t.Ranks <= capacity then
			table.insert(out, t)
		end
	end
	return out
end

-- One rank-grant tier for an item with `capacity` ranks left (nil when it has none left).
function BuildRules.RollRarity(rng: Rng, capacity: number): Tier?
	local tiers = BuildRules.RarityTable(capacity)
	local total = 0
	for _, t in ipairs(tiers) do
		total += t.Weight
	end
	if total <= 0 then
		return nil
	end
	local roll = rng:NextNumber() * total
	for _, t in ipairs(tiers) do
		roll -= t.Weight
		if roll < 0 then
			return t
		end
	end
	return tiers[#tiers]
end

--[[
	Up to `n` distinct options from `pool` = { [category] = { item, ... } } (items are any
	values; each is used at most once). Each option: a category drawn by
	RunConfig.Builds.CategoryWeights among the categories that still hold items (renormalised),
	then an item drawn uniformly inside it. Returns { { Category = c, Item = item } } in draw
	order. `weights` overrides the category weights (tests).
]]
function BuildRules.RollOffer(rng: Rng, pool: { [string]: { any } }, n: number, weights: { [string]: number }?): { { Category: string, Item: any } }
	local w = weights or Builds.CategoryWeights
	local left: { [string]: { any } } = {}
	for cat, items in pairs(pool) do
		left[cat] = table.clone(items)
	end
	local out = {}
	for _ = 1, n do
		local total = 0
		for _, cat in ipairs(Builds.CategoryOrder) do
			local items = left[cat]
			if items and #items > 0 then
				total += w[cat] or 0
			end
		end
		if total <= 0 then
			break
		end
		local roll = rng:NextNumber() * total
		local pick: string? = nil
		for _, cat in ipairs(Builds.CategoryOrder) do
			local items = left[cat]
			if items and #items > 0 and (w[cat] or 0) > 0 then
				pick = cat
				roll -= w[cat]
				if roll < 0 then
					break
				end
			end
		end
		if not pick then
			break
		end
		local items = left[pick]
		local i = rng:NextInteger(1, #items)
		table.insert(out, { Category = pick, Item = items[i] })
		table.remove(items, i)
	end
	return out
end

-- Speed multiplier of a slow of `share` (0.35 = 35 % slower) after the cap.
function BuildRules.SlowMult(share: number, boss: boolean?): number
	local cap = boss and Combat.BossSlowCap or Combat.SlowCap
	local s = tonumber(share) or 0
	if s ~= s then
		s = 0
	end
	return 1 - math.clamp(s, 0, cap)
end

-- "Boss" | "Elite" | "Normal" of an enemy record.
function BuildRules.KindOf(e: any): string
	if e and e.Boss then
		return "Boss"
	elseif e and e.Elite then
		return "Elite"
	end
	return "Normal"
end

-- Horizontal knockback speed for this kind of enemy (studs/s), capped.
function BuildRules.Knockback(kind: string, speed: number?): number
	local v = tonumber(speed) or 0
	if v ~= v or v <= 0 or kind == "Boss" then
		return 0
	end
	if kind == "Elite" then
		v *= Combat.EliteKnockMult
	end
	return math.min(v, Combat.KnockbackCap)
end

-- Stagger seconds for this kind of enemy (bosses ignore staggers, elites are capped).
function BuildRules.Stagger(kind: string, seconds: number?): number
	local v = tonumber(seconds) or 0
	if v ~= v or v <= 0 or kind == "Boss" then
		return 0
	end
	if kind == "Elite" then
		v = math.min(v, Combat.EliteStaggerMax)
	end
	return v
end

-- Damage of one scorch tick (0.12 B per second; `mult` scales the source, strongest kept).
function BuildRules.ScorchTickDamage(mult: number?): number
	return Combat.ScorchDpsB * Builds.B * (tonumber(mult) or 1) * Combat.ScorchTick
end

return BuildRules
