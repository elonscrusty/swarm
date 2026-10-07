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
local BEHAVIORS = { Whip = 1, Orb = 1, Knives = 1, Aura = 1, HolyWater = 1, Lightning = 1, Axe = 1, Boomerang = 1, Longbow = 1, Spear = 1, Crossbow = 1, Nova = 1, FireTrail = 1, Totem = 1, Hook = 1, Turret = 1, Soul = 1, Shields = 1, Quake = 1, Meteor = 1, Sling = 1, Cloud = 1, Saw = 1, Vines = 1, Horn = 1, Wisps = 1, Vortex = 1 }
local PERKS_USED = { Riposte = 1, Split = 1, Ricochet = 1, Chill = 1, Volley = 1, Impale = 1, Shatter = 1, Wildfire = 1, Rooting = 1, Barbed = 1, Flak = 1, Wandering = 1, Bulwark = 1, Aftershock = 1, Molten = 1, Stagger = 1, Choking = 1, Rebound = 1, Thornbloom = 1, Echo = 1, Glow = 1, Implosion = 1 }

local seenOrder = {}
-- released weapons (Order) and the ones held for a later update (HeldOrder) are both checked
local allWeapons = table.clone(WeaponData.Order)
for _, id in ipairs(WeaponData.HeldOrder or {}) do
	if table.find(WeaponData.Order, id) then
		bad("weapon " .. id .. " is in both Order and HeldOrder")
	end
	table.insert(allWeapons, id)
end
for _, id in ipairs(allWeapons) do
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
		bad("weapon " .. id .. " missing from Order / HeldOrder")
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

-- 30-features batch (docs/features/FOUNDATION.md): flags, cosmetics registry, save fields
do
	local NAMES = { "Sigils", "MapEvents", "MiniBosses", "SecretRooms", "TrialShrine", "Merchant", "CursedChests", "Rescue", "Weather", "BossIntro", "NewHeroes", "SecondSkill", "Ultimate", "BuildPresets", "WeaponMastery", "TeamCombo", "QuickPings", "CoopBoss", "TeamBoard", "Spectate", "WeeklyChallenge", "SeasonTrack", "Titles", "CollectionBook", "LoginStreak", "Announcer", "HitFeel", "MusicSlots", "PhotoMode", "LobbyFun", "Store",
		-- next batch (docs/next/)
		"SmartTutorial", "Walkthrough", "DangerArrows", "FastStart", "DailyQuests", "ComebackGift", "StarterBundle", "GroupBonus", "InviteRewards", "BugReportPlus" }
	local n = 0
	for name, on in pairs(Config.Features) do
		n += 1
		if type(on) ~= "boolean" then bad("Config.Features." .. name .. " is not a boolean") end
		if not table.find(NAMES, name) then bad("Config.Features." .. name .. " is not a known feature") end
	end
	for _, name in ipairs(NAMES) do
		if Config.FeatureOn(name) ~= (Config.Features[name] == true) then bad("FeatureOn(" .. name .. ") disagrees") end
	end
	if n ~= #NAMES then bad("Config.Features has " .. n .. " flags, expected " .. #NAMES) end
	if Config.FeatureOn("NoSuchFeature") then bad("unknown feature reads as on") end

	local Cos = preview.shared("CosmeticData")
	local CharacterData = preview.shared("CharacterData")
	for _, id in ipairs(Cos.Order) do
		local e = Cos.Items[id]
		if e.Id ~= id then bad("cosmetic " .. id .. " Id mismatch") end
		if not table.find(Cos.Kinds, e.Kind) then bad("cosmetic " .. id .. " kind " .. tostring(e.Kind)) end
		if e.Source == "Earned" and (type(e.Condition) ~= "string" or e.Condition == "") then bad("earned cosmetic " .. id .. " has no condition text") end
		if e.Source == "Store" and type(e.StoreKey) ~= "string" then bad("store cosmetic " .. id .. " has no StoreKey") end
		if e.Source == "Store" and Cos.StoreId(id) == 0 and not Cos.ComingSoon(id) then bad("cosmetic " .. id .. " coming-soon state") end
	end
	for id in pairs(CharacterData.Skins) do
		if not Cos.Items[id] or Cos.Items[id].Kind ~= "Skin" then bad("skin " .. id .. " missing from CosmeticData") end
	end

	local DS = preview.server("DataService")
	local S = Config.Data.SchemaVersion
	-- an old save (schema 7, before this batch) loads with every new field at its default
	local old = DS.Migrate({ Version = S, Gold = 777, OwnedCharacters = { Mage = true }, Title = "Veteran", Ring = "Ember", Skins = { Knight = "Default" }, Stats = { Wins = 2 } })
	if old.Gold ~= 777 or not old.OwnedCharacters.Mage or old.Title ~= "Veteran" or old.Ring ~= "Ember" or old.Stats.Wins ~= 2 then bad("old save lost progress") end
	if old.Version ~= S then bad("feature fields bumped the schema") end
	if type(old.Sigils.Owned) ~= "table" or #old.Sigils.Equipped ~= 0 then bad("Sigils default") end
	if old.Weekly.BestScore ~= 0 or old.Season.Id ~= "" or old.Season.XP ~= 0 then bad("Weekly / Season default") end
	if next(old.Titles.Owned) ~= nil or next(old.Collection.Seen) ~= nil then bad("Titles / Collection default") end
	if old.LoginStreak.Day ~= 0 or old.LoginStreak.LastDay ~= 0 then bad("LoginStreak default") end
	if #old.Presets.List ~= 0 or next(old.WeaponMastery) ~= nil then bad("Presets / WeaponMastery default") end
	if old.Cosmetics.Equipped.Trail ~= "" or old.Cosmetics.Equipped.Dais ~= "" or old.Supporter ~= false then bad("Cosmetics / Supporter default") end
	-- a filled save keeps everything valid
	local full = DS.Migrate({
		Version = S, Gold = 1,
		Sigils = { Owned = { HaresFoot = 1700000000, GlassEye = 1700000001 }, Equipped = { "HaresFoot", "Nope", "GlassEye", "HaresFoot" } },
		Weekly = { Week = 2900, Score = 50, Plays = 3, BestScore = 900, BestWeek = 2899 },
		Season = { Id = "S1", XP = 1234, Claimed = { ["1"] = true, ["2"] = true } },
		Titles = { Owned = { Trailblazer = true } },
		Collection = { Seen = { ["Boss:ScorpionQueen"] = true } },
		LoginStreak = { Day = 5, LastDay = 20000, Best = 9 },
		Presets = { List = { { Hero = "Knight", Weapons = { "Whip", "Whip", "Orb" }, Passives = { "Armor" } } }, Active = { Knight = 1, Mage = 4 } },
		WeaponMastery = { Whip = 120, Orb = 3.7 },
		Cosmetics = { Owned = { Trail_Ember = true }, Equipped = { Trail = "Trail_Ember", Pet = 5 } },
		Supporter = true,
	})
	if full.Sigils.Owned.HaresFoot ~= 1700000000 or #full.Sigils.Equipped ~= 2 or full.Sigils.Equipped[2] ~= "GlassEye" then bad("Sigils kept / cleaned") end
	if full.Weekly.BestScore ~= 900 or full.Season.XP ~= 1234 or not full.Season.Claimed["2"] then bad("Weekly / Season kept") end
	if not full.Titles.Owned.Trailblazer or not full.Collection.Seen["Boss:ScorpionQueen"] then bad("Titles / Collection kept") end
	if full.LoginStreak.Day ~= 5 or full.LoginStreak.Best ~= 9 then bad("LoginStreak kept") end
	local p1 = full.Presets.List[1]
	if not p1 or p1.Hero ~= "Knight" or #p1.Weapons ~= 2 or full.Presets.Active.Knight ~= 1 or full.Presets.Active.Mage ~= nil then bad("Presets kept / cleaned") end
	if full.WeaponMastery.Whip ~= 120 or full.WeaponMastery.Orb ~= 3 then bad("WeaponMastery kept") end
	if full.Cosmetics.Equipped.Trail ~= "Trail_Ember" or full.Cosmetics.Equipped.Pet ~= "" or not full.Cosmetics.Owned.Trail_Ember or full.Supporter ~= true then bad("Cosmetics / Supporter kept") end
	-- malformed and oversized
	local junk = DS.Migrate({ Version = S, Sigils = "x", Weekly = { Week = 0 / 0, BestScore = math.huge }, Season = 5, Titles = { Owned = { [string.rep("a", 200)] = true, ok = "yes" } }, LoginStreak = { Day = -3 }, Presets = { List = "x" }, Cosmetics = { Equipped = "x" }, Supporter = "yes", WeaponMastery = { [1] = 5 } })
	if type(junk.Sigils.Owned) ~= "table" or junk.Weekly.Week ~= 0 or junk.Weekly.BestScore ~= 0 or junk.Season.Id ~= "" or next(junk.Titles.Owned) ~= nil
		or junk.LoginStreak.Day ~= 0 or #junk.Presets.List ~= 0 or junk.Cosmetics.Equipped.Trail ~= "" or junk.Supporter ~= false or next(junk.WeaponMastery) ~= nil then
		bad("malformed feature fields not reset")
	end
	local many, presets = {}, {}
	for i = 1, Config.Data.Caps.SetEntries + 50 do many["id" .. i] = true end
	for _ = 1, Config.Data.Caps.Presets + 3 do table.insert(presets, { Hero = "Knight", Weapons = {}, Passives = {} }) end
	local capped = DS.Migrate({ Version = S, Collection = { Seen = many }, Presets = { List = presets } })
	local count = 0
	for _ in pairs(capped.Collection.Seen) do count += 1 end
	if count ~= Config.Data.Caps.SetEntries or #capped.Presets.List ~= Config.Data.Caps.Presets then bad("feature caps not applied") end
	-- a second pass changes nothing (Migrate is stable on its own output)
	local again = DS.Migrate(full)
	if again.Sigils.Equipped[1] ~= "HaresFoot" or again.Season.XP ~= 1234 or again.Presets.Active.Knight ~= 1 then bad("Migrate not stable on feature fields") end
	local view = DS.FeatureView(full)
	for _, k in ipairs({ "Sigils", "Weekly", "Season", "Titles", "Collection", "LoginStreak", "Presets", "WeaponMastery", "Cosmetics" }) do
		if type(view[k]) ~= "table" then bad("FeatureView misses " .. k) end
	end
	preview.log("PASS feature foundation: 31 flags, " .. #Cos.Order .. " cosmetics, save fields default / keep / clean / cap")
end

preview.log(string.format("data sanity: %d finding(s)", #findings))
assert(#findings == 0, table.concat(findings, "\n"))
