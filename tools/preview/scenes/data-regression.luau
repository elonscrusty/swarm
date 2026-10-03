-- data-regression: pure data checks over WeaponData / EnemyData / BossData / Config
-- (every weapon row, evolution, perk, visual, spawn table and boss cycle); errors on any finding.
local WeaponData = preview.shared("WeaponData")
local EnemyData = preview.shared("EnemyData")
local BossData = preview.shared("BossData")
local PassiveData = preview.shared("PassiveData")
local Config = preview.shared("Config")

local findings = {}
local function bad(msg)
	table.insert(findings, msg)
	preview.log("FINDING " .. msg)
end

local KEYS = { "damage", "cooldown", "amount", "area", "speed", "pierce", "duration", "knockback" }
-- direction a stat should move with levels: +1 non-decreasing, -1 non-increasing
local DIR = { damage = 1, cooldown = -1, amount = 1, area = 1, speed = 1, pierce = 1, duration = 1, knockback = 1 }
local BEHAVIORS = { Whip = 1, Orb = 1, Knives = 1, Aura = 1, HolyWater = 1, Lightning = 1, Axe = 1, Boomerang = 1, Longbow = 1, Spear = 1, Crossbow = 1, Nova = 1, FireTrail = 1, Totem = 1, Hook = 1, Turret = 1, Soul = 1 }
local PERKS_USED = { Riposte = 1, Split = 1, Ricochet = 1, Chill = 1, Volley = 1, Impale = 1, Shatter = 1, Wildfire = 1, Rooting = 1, Barbed = 1, Flak = 1, Wandering = 1 }

local seenOrder = {}
for _, id in ipairs(WeaponData.Order) do
	seenOrder[id] = true
	local def = WeaponData.Weapons[id]
	if not def then
		bad("Order lists unknown weapon " .. id)
		continue
	end
	if def.Id ~= id then
		bad(id .. " Id field mismatch " .. tostring(def.Id))
	end
	if not BEHAVIORS[def.Behavior] then
		bad(id .. " unknown behaviour " .. tostring(def.Behavior))
	end
	if not WeaponData.StatUse[def.Behavior] then
		bad(id .. " behaviour " .. tostring(def.Behavior) .. " has no StatUse row")
	end
	if #def.Levels ~= WeaponData.MaxLevel then
		bad(id .. " has " .. #def.Levels .. " level rows")
	end
	for lvl, r in ipairs(def.Levels) do
		for _, k in ipairs(KEYS) do
			if type(r[k]) ~= "number" then
				bad(string.format("%s L%d %s is %s", id, lvl, k, tostring(r[k])))
			end
		end
		if def.Behavior == "Totem" and type(r.heal) ~= "number" then
			bad(string.format("%s L%d heal missing", id, lvl))
		end
		if lvl > 1 then
			local prev = def.Levels[lvl - 1]
			for _, k in ipairs(KEYS) do
				if type(r[k]) == "number" and type(prev[k]) == "number" then
					local d = (r[k] - prev[k]) * DIR[k]
					if d < -1e-9 then
						bad(string.format("%s L%d %s goes the wrong way %s -> %s", id, lvl, k, prev[k], r[k]))
					end
				end
			end
			if r.heal and prev.heal and r.heal < prev.heal then
				bad(string.format("%s L%d heal drops", id, lvl))
			end
			local same = true
			for _, k in ipairs(KEYS) do
				if r[k] ~= prev[k] then
					same = false
				end
			end
			if r.heal ~= prev.heal then
				same = false
			end
			if same and not WeaponData.PerkAt(id, lvl) then
				bad(string.format("%s L%d changes nothing (no stat change, no perk)", id, lvl))
			end
		end
	end
	local evo = def.Evolution
	if not evo then
		bad(id .. " has no evolution")
	else
		if not PassiveData.Passives[evo.Passive] then
			bad(id .. " evolution passive " .. tostring(evo.Passive) .. " does not exist")
		end
		local top = def.Levels[#def.Levels]
		local s = evo.Stats
		for _, k in ipairs(KEYS) do
			if type(s[k]) ~= "number" then
				bad(id .. " evolution stat " .. k .. " is " .. tostring(s[k]))
			end
		end
		if s.damage < top.damage then
			bad(id .. " evolution damage below level 12")
		end
		if s.cooldown > top.cooldown + 1e-9 and not (id == "Axe") then
			bad(string.format("%s evolution cooldown %.2f above level 12 %.2f", id, s.cooldown, top.cooldown))
		end
		if s.area < top.area then
			bad(id .. " evolution area below level 12")
		end
		if s.pierce < top.pierce then
			bad(id .. " evolution pierce below level 12")
		end
		if s.duration < top.duration - 1e-9 then
			bad(id .. " evolution duration below level 12")
		end
		if s.knockback < top.knockback and id ~= "Knives" then -- Thousand Edge is a stream: lighter knives on purpose
			bad(id .. " evolution knockback below level 12")
		end
		if s.heal and top.heal and s.heal < top.heal then
			bad(id .. " evolution heal below level 12")
		end
		local cap = def.Params and def.Params.MaxAmount
		if cap and (top.amount > cap or s.amount > cap) then
			bad(id .. " amount above MaxAmount")
		end
	end
	for _, perk in ipairs(def.Perks or {}) do
		if perk.Level < 2 or perk.Level > WeaponData.MaxLevel then
			bad(id .. " perk " .. perk.Id .. " at level " .. perk.Level)
		end
		if not PERKS_USED[perk.Id] then
			bad(id .. " perk " .. perk.Id .. " is never read by WeaponSystem")
		end
	end
	local P = def.Params or {}
	for _, key in ipairs({ "Visual", "EvoVisual", "ShotVisual" }) do
		if P[key] and not WeaponData.Visuals[P[key]] then
			bad(id .. " " .. key .. " " .. tostring(P[key]) .. " has no Visuals entry")
		end
	end
	-- card lines must produce something for every level step and the evolution
	for lvl = 1, WeaponData.MaxLevel do
		local lines = WeaponData.CardLines(id, lvl - 1, lvl)
		if #lines == 0 then
			bad(string.format("%s L%d card has no lines", id, lvl))
		end
	end
	if #WeaponData.CardLines(id, WeaponData.MaxLevel, WeaponData.MaxLevel, true) == 0 then
		bad(id .. " evolution card has no lines")
	end
end
for id in pairs(WeaponData.Weapons) do
	if not seenOrder[id] then
		bad("weapon " .. id .. " missing from Order")
	end
end
-- visual byte round trip
for idx in pairs(WeaponData.Visuals) do
	for tier = 0, 3 do
		local b = WeaponData.VisualByte(idx, tier)
		if WeaponData.VisualIndex(b) ~= idx or WeaponData.VisualTier(b) ~= tier then
			bad(string.format("VisualByte round trip fails for %d/%d", idx, tier))
		end
	end
end
-- mastery table cumulative
for i = 2, #WeaponData.Mastery do
	for _, k in ipairs({ "damage", "cooldown", "area", "amount" }) do
		if WeaponData.Mastery[i][k] < WeaponData.Mastery[i - 1][k] then
			bad("Mastery rank " .. i .. " " .. k .. " drops")
		end
	end
end

-- EnemyData
for id, def in pairs(EnemyData.Enemies) do
	if def.Id ~= id then
		bad("enemy " .. id .. " Id mismatch")
	end
	for _, k in ipairs({ "HP", "Speed", "Damage", "Radius" }) do
		if type(def[k]) ~= "number" then
			bad("enemy " .. id .. " " .. k .. " missing")
		end
	end
	if def.Gem then
		for kind in pairs(def.Gem) do
			if not Config.XP.GemValues[kind] then
				bad("enemy " .. id .. " gem kind " .. kind)
			end
		end
	end
	if def.Spawner and not EnemyData.Enemies[def.Spawner.Type] then
		bad("enemy " .. id .. " spawner type")
	end
	if def.Hatch and not EnemyData.Enemies[def.Hatch.Type] then
		bad("enemy " .. id .. " hatch type")
	end
end
local lastTarget = 0
for i, row in ipairs(EnemyData.SpawnTable) do
	if row.Target < lastTarget then
		bad("SpawnTable row " .. i .. " target drops")
	end
	lastTarget = row.Target
	for id in pairs(row.Weights) do
		local def = EnemyData.Enemies[id]
		if not def then
			bad("SpawnTable row " .. i .. " unknown enemy " .. id)
		elseif def.IsBoss or def.Object or def.Static then
			bad("SpawnTable row " .. i .. " lists " .. id)
		end
	end
end
for _, id in ipairs(Config.Pacing.EliteTypes) do
	if not EnemyData.Enemies[id] then
		bad("EliteTypes unknown " .. id)
	end
end
for id in pairs(Config.Pacing.IntroGroupOf) do
	if not EnemyData.Enemies[id] then
		bad("IntroGroupOf unknown " .. id)
	end
end

-- BossData
local STARTS = { Charge = 1, Dive = 1, HornCharge = 1, VenomBurst = 1, StingerRing = 1, Burrow = 1, Summon = 1, BroodCall = 1, DustStorm = 1, GlimmerMines = 1, WingGust = 1, GroundPound = 1, WarBanner = 1, EggBarrage = 1, AcidPools = 1, RootLines = 1, ThornVolley = 1, BrambleRing = 1, Sproutling = 1, GroundSlam = 1, IceLanes = 1, FrostBreath = 1, ShardRain = 1 }
for id, boss in pairs(BossData.Bosses) do
	if boss.Id ~= id then
		bad("boss " .. id .. " Id mismatch")
	end
	local body = EnemyData.Enemies[boss.EnemyType]
	if not body or not body.IsBoss then
		bad("boss " .. id .. " body " .. tostring(boss.EnemyType))
	end
	local lastAbove = 1
	for pi, phase in ipairs(boss.Phases) do
		if phase.Above >= lastAbove then
			bad("boss " .. id .. " phase " .. pi .. " Above not decreasing")
		end
		lastAbove = phase.Above
		for _, name in ipairs(phase.Cycle) do
			local A = boss.Attacks[name]
			if not A then
				bad("boss " .. id .. " cycle names unknown attack " .. name)
			elseif not STARTS[name] and not (A.Move and STARTS[A.Move]) then
				bad("boss " .. id .. " attack " .. name .. " has no BossAI start")
			end
		end
		for a, b in pairs(phase.FollowUps or {}) do
			if not boss.Attacks[a] or not boss.Attacks[b] then
				bad("boss " .. id .. " follow-up " .. a .. "->" .. b)
			end
		end
	end
	if boss.Phases[#boss.Phases].Above ~= 0 then
		bad("boss " .. id .. " last phase Above must be 0")
	end
	for name, A in pairs(boss.Attacks) do
		if A.Type and not EnemyData.Enemies[A.Type] then
			bad("boss " .. id .. " attack " .. name .. " type " .. tostring(A.Type))
		end
		if A.Recover and A.Recover <= 0 then
			bad("boss " .. id .. " attack " .. name .. " recover")
		end
		if A.Windup and A.Windup < 0.5 then
			bad("boss " .. id .. " attack " .. name .. " windup under 0.5 s")
		end
	end
end
for _, id in ipairs(BossData.Rotation) do
	if not BossData.Bosses[id] then
		bad("Rotation unknown " .. id)
	end
end
if not BossData.Bosses[Config.Boss.First] then
	bad("Config.Boss.First unknown")
end

preview.log(string.format("data sanity: %d finding(s)", #findings))
assert(#findings == 0, table.concat(findings, "\n"))
