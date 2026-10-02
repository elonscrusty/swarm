--[[
	Config.lua
	Every tunable number in SWARM lives here. Server and client both read this module,
	so changing a value here changes it everywhere on the next sync.

	Sections:
	  Run, Dev, Player, Slots, LevelUp, XP, Gold, Drops, Items, Chests, Shrines, Guarded,
	  Enemies, Difficulty, Spawn, Boss, Pacing,
	  Projectiles, Net, Camera, Controls, Graphics, Data, Monetization, Sounds, Audio,
	  Settings, Tutorial, DamageNumbers, UI, Arenas, Modes, Lobby
]]

local Config = {}

Config.Version = "1.0.0"

-- Turn on extra warnings in the output window (server and client).
Config.Debug = false

------------------------------------------------------------------------------------------
-- RUN FLOW
------------------------------------------------------------------------------------------
Config.Run = {
	CountdownSeconds = 10, -- lobby countdown after someone presses Start
	-- UNUSED since the stage loop (Config.Stages): the boss no longer comes at a fixed time,
	-- it is summoned at each stage's portal. Kept so old references keep compiling.
	BossTime = 15 * 60,
	MiniWaveInterval = 30, -- a burst of extra enemies every N seconds (while exploring)
	ResultsSeconds = 25, -- defeat screen time before everyone is sent back automatically
	MaxPlayers = 4, -- players per run (server MaxPlayers should match in game settings)
	ArenaSpawnSpread = 10, -- players are placed in a circle of this radius at run start
	-- A solo player who opens the pause menu freezes the whole run. In a group run the
	-- menu is only an overlay (the run keeps going), so nobody can stall a shared run.
	SoloPauseFreezesRun = true,
}

------------------------------------------------------------------------------------------
-- STAGES (Risk of Rain style loop)
--   A run is a series of stages. Each stage is an arena (stage 1 = the lobby's arena, then
--   a shuffled tour of Config.Arenas.Rotation, never the same twice in a row) with a PORTAL at a random
--   clear spot. Explore while the swarm comes as usual; stand in the portal's rune circle
--   to charge it (ChargeSeconds); that summons the Scorpion Queen at the portal. When she
--   dies a SURGE pours out of the portal; survive it and the portal opens: every living
--   player picks NEXT STAGE or RETURN TO LOBBY (a win, paid StageClearBonus per stage).
--   Enemy scaling keeps counting TOTAL run time (Config.Difficulty, the spawn table) and
--   adds the per-stage multipliers below; stage 1 multiplies by exactly 1.
------------------------------------------------------------------------------------------
Config.Stages = {
	-- portal placement (rejection sampling, a new spot every stage)
	PortalMinDistance = 120, -- studs from the spawn centre
	PortalEdgeMargin = 24, -- studs inside the fence
	PortalClearance = 9, -- free radius around the portal (colliders, landmarks, ponds)
	PortalRepeatDistance = 80, -- a new portal is this far from the last one in that arena
	-- activation: any living player standing in the rune circle charges it (touch friendly)
	PortalRadius = 9, -- studs from the portal centre
	ChargeSeconds = 2,
	ChargeDecay = 0.5, -- share of a full charge lost per second while nobody stands there
	-- The portal sleeps for a while after a stage starts: it can't be charged before this
	-- many seconds on the stage (stage 1, later stages); the HUD says "The portal is
	-- dormant: m:ss". Stops a rush to the boss with a starting build.
	PortalLockSeconds = { 150, 45 },
	-- the HUD arrow toward the portal appears after this long (never before the lock ends)
	HintAfterSeconds = 90,
	-- difficulty on top of the run-time scaling, x(1 + this * (stage - 1))
	EnemyHPPerStage = 0.25,
	EnemyDamagePerStage = 0.08, -- also the boss's contact / orb damage and bomb ticks
	SpawnTargetPerStage = 0.1, -- live-enemy target and mini-wave size
	-- Scorpion Queen HP = Config.Boss.HP x this (x the player-count scaling). She comes
	-- much earlier than the old 15:00 boss, so stage 1 is lighter; then +BossHPPerExtraStage
	-- per stage past the list.
	BossHPByStage = { 0.3, 0.75, 1.1, 1.5, 2.0 },
	BossHPPerExtraStage = 0.5,
	BossSpawnOffset = 12, -- the Queen climbs out this far behind the portal
	-- regular enemies kept alive during the Queen fight: this share of the normal live
	-- target, at most Config.Boss.MinionCapDuringBoss and at least BossMinionMin
	BossMinionShare = 0.5,
	BossMinionMin = 15,
	-- surge after the Queen dies
	-- surge size = SurgeBase + SurgePerStage x stage (x Config.Difficulty.PlayerCountMult,
	-- capped by MaxLive): 40 on stage 1, 55 on stage 2 ...
	SurgeBase = 25,
	SurgePerStage = 15,
	SurgeSpawnSeconds = 4, -- they pour out over this long
	SurgeSeconds = 20, -- survive this long ...
	SurgeEndRemaining = 0.2, -- ... or until at most this share of the surge is still alive
	-- the open portal
	ChoiceSeconds = 15, -- undecided living players go to the next stage after this
	TravelFadeSeconds = 0.8, -- screen fade before / after the arena swap
	TravelHealFraction = 0.6, -- living players are healed up to at least this share of max HP
	ReviveOnTravelHPFraction = 0.5, -- fallen teammates stand up again on the next stage
	-- RETURN TO LOBBY counts as a WIN (Stats.Wins) only with at least this many stages
	-- cleared; the gold bonus (Config.Gold.WinBonus + StageClearBonus) is paid either way.
	WinMinStages = 3,
}

------------------------------------------------------------------------------------------
-- DEV TOOLS (Studio and the game's creator only; the server re-checks every request)
------------------------------------------------------------------------------------------
Config.Dev = {
	Enabled = true, -- false hides the DEV button everywhere and ignores dev requests
	-- Dev controls show in Studio only. true also shows them to the game's creator in live
	-- servers (user-owned games); leave false for normal play.
	ShowInLiveGame = false,
	AddLevels = 5, -- "+5 levels" button
	SkipToTime = 14 * 60 + 30, -- unused since the stage loop (was "Skip to 14:30")
	-- In a run: "Spawn portal boss" charges the stage portal at once, "Teleport to portal"
	-- puts you next to it.
}

------------------------------------------------------------------------------------------
-- PLAYER BASE STATS (before character, passive and meta bonuses)
------------------------------------------------------------------------------------------
Config.Player = {
	BaseMaxHP = 100,
	BaseSpeed = 16, -- Humanoid WalkSpeed
	BasePickupRadius = 7, -- studs, gems inside this radius fly to you
	BaseLuck = 0, -- 0.1 = +10%
	BaseArmor = 0, -- flat damage reduction per hit
	MinDamagePerHit = 1, -- armor can never reduce a hit below this
	HurtFlashSeconds = 0.15,
	ReviveHPFraction = 0.5, -- revived players come back with this share of max HP
	ReviveInvulnSeconds = 3,
	ReviveClearRadius = 22, -- non-boss enemies inside this radius die on revive
	LevelUpInvulnerable = true, -- paused (choosing an upgrade) players can't be hurt
	-- Movement sanity check: the server snaps players back if they move faster than this
	-- multiple of their WalkSpeed (plus a small allowance for lag).
	SpeedCheckTolerance = 1.6,
	SpeedCheckAllowance = 6,
}

-- Inventory slot limits (weapons and passives are separate).
Config.Slots = {
	Weapons = 6,
	Passives = 6,
}

------------------------------------------------------------------------------------------
-- LEVEL UP
------------------------------------------------------------------------------------------
Config.LevelUp = {
	Choices = 3,
	-- If a player doesn't pick in this many seconds a random card is chosen for them,
	-- so nobody can stay paused (and protected) forever.
	AutoPickSeconds = 25,
	-- In Duo/Trio a level-up freezes everyone's game, so the auto-pick comes sooner.
	GroupAutoPickSeconds = 10,
	SkipGold = 10, -- run gold granted when a level-up is skipped
	-- Relative weights for building the 3 cards. Luck multiplies the "new" weights.
	WeightUpgradeWeapon = 10,
	WeightUpgradePassive = 7,
	WeightNewWeapon = 6,
	-- the new-weapon weight is shared out as if there were at most this many weapons you
	-- don't own yet (17 weapons must not crowd out upgrades: same odds as with 9)
	NewWeaponPoolRef = 8,
	WeightNewPassive = 5,
	WeightEvolution = 40, -- an available evolution is almost always offered
	-- a passive that evolves a weapon you own (and don't have yet) is this much likelier
	EvolutionPassiveWeightMult = 1.5,
	-- weapon cards from this level on say what the weapon evolves with ("Evolves at Lv 8
	-- with Heart (owned)")
	EvolveHintLevel = 6,
	-- Rarity names → card colour (UI) and label.
	Rarities = {
		Common = { Label = "Upgrade", Color = Color3.fromRGB(205, 210, 220) },
		Rare = { Label = "New", Color = Color3.fromRGB(80, 160, 255) },
		Epic = { Label = "Max", Color = Color3.fromRGB(190, 90, 255) },
		Legendary = { Label = "EVOLUTION", Color = Color3.fromRGB(255, 200, 40) },
	},
	FallbackGold = 25, -- card offered when every slot is maxed
	FallbackHeal = 30,
}

------------------------------------------------------------------------------------------
-- XP AND GEMS
------------------------------------------------------------------------------------------
Config.XP = {
	-- XP needed to go from level L to L+1 = Base + min(L, CapLevel) * PerLevel
	-- (grows by PerLevel each level, then stays flat after CapLevel).
	Base = 10,
	PerLevel = 5,
	CapLevel = 20,
	GemValues = { Small = 1, Medium = 5, Large = 25 },
	GemPoolSize = 500,
	MagnetSpeed = 45, -- studs/s a gem flies toward the player once inside pickup radius
	MagnetAcceleration = 90,
	CollectDistance = 3, -- studs from the player's root
	GemHeight = 1.2, -- resting height above the floor
	-- Gems are only checked against players every N frames in chunks (perf).
	CheckChunks = 2,
}

------------------------------------------------------------------------------------------
-- GOLD
------------------------------------------------------------------------------------------
Config.Gold = {
	-- Normal enemies give 1-3 gold to the player who killed them. KillGoldChance is how
	-- often a kill pays at all (1 = every kill; lower it if gold comes in too fast).
	MinPerKill = 1,
	MaxPerKill = 3,
	KillGoldChance = 0.12,
	Elite = 15, -- extra gold from an elite's chest (on top of ChestGold) ...
	EliteStageScale = 0.25, -- ... the whole elite chest gold x (1 + this x (stage - 1))
	Boss = 200, -- every living player gets this each time the Scorpion Queen dies
	ChestGoldMin = 15,
	ChestGoldMax = 40,
	WinBonus = 100, -- paid when a player leaves through an open portal (a win)
	StageClearBonus = 150, -- plus this per stage cleared, on that same return
}

------------------------------------------------------------------------------------------
-- FLOOR PICKUPS (chicken, magnet, bomb) AND CHESTS
------------------------------------------------------------------------------------------
Config.Drops = {
	FloorPickupChance = 0.004, -- per normal enemy death, multiplied by (1 + luck)
	Weights = { Chicken = 60, Magnet = 22, Bomb = 18 },
	ChickenHeal = 30,
	BombRadius = 75, -- "on screen" radius around the player who picked it up
	PickupRadius = 4, -- studs to collect a floor pickup or chest
	PickupLifetime = 60, -- seconds before an uncollected floor pickup vanishes
	ChestLifetime = 120,
	MaxFloorPickups = 20,
	-- Chance the chest also gives a second weapon level-up, multiplied by (1 + luck).
	ChestBonusLevelChance = 0.2,
}

------------------------------------------------------------------------------------------
-- RUN ITEMS (src/shared/ItemData.lua, server ItemSystem.lua)
--   Small stacking items from chests, the Shrine of Chance and the guarded altar. They last
--   for the whole run (kept across stages) and vanish when the run ends. Stats go through
--   the normal stat sheet (LevelUpSystem.RecomputeStats); procs have internal cooldowns
--   here so a huge swarm can't turn them into a lag machine.
------------------------------------------------------------------------------------------
Config.Items = {
	BaseCritChance = 0, -- nobody crits without items
	BaseCritDamage = 2.0, -- a critical hit deals x this (Hunter's Eye adds to it)
	MaxCritChance = 0.6,
	MaxSpeedMult = 2.2, -- move speed never goes above BaseSpeed x this
	MinCooldownMult = 0.3, -- passives + items together never make weapons faster than this
	-- procs (per player)
	HealOnKillAmount = 3, -- Healing Herb
	LightningCooldown = 0.2, -- Storm Charm: seconds between procs
	LightningRange = 16, -- studs from the hit enemy to the extra targets
	LightningDamage = 0.4, -- share of the triggering hit
	LightningTargets = 2, -- + 1 per stack
	LightningMaxTargets = 5,
	ExplodeChance = 0.2, -- Volatile Spore
	ExplodeShare = 0.6, -- of the dead enemy's max HP (+ExplodeSharePerStack per extra stack)
	ExplodeSharePerStack = 0.3,
	ExplodeRadius = 7,
	ExplodeCooldown = 0.08,
	ExplodeBossMaxShare = 0.05, -- a burst deals at most this share of a boss's max HP
	ThornsMult = 1.5, -- Barbed Mail: x the hit (+ThornsPerStack per extra stack); the hit is
	ThornsPerStack = 1.0, -- max(raw x ThornsRawShare, damage taken after armor)
	ThornsRawShare = 0.5,
	ThornsRadius = 8,
	ThornsCooldown = 0.5,
	ShieldPerStack = 0.08, -- Guardian Ward: share of max HP
	ShieldMax = 0.4,
	ShieldDelay = 5, -- seconds without damage before it refills
	ShieldRefillSeconds = 1,
	QuiverEvery = 7, -- Spare Quiver: every (this - stacks)th attack, at least every QuiverMin
	QuiverMin = 2,
	MagnetInterval = 12, -- Magnet Totem: seconds (- MagnetIntervalPerStack per stack) ...
	MagnetIntervalPerStack = 2,
	MagnetIntervalMin = 4,
	MagnetRadius = 35, -- ... studs (+ MagnetRadiusPerStack per stack)
	MagnetRadiusPerStack = 10,
	RegenTick = 0.5, -- regeneration is applied in ticks of this many seconds
	PopupSeconds = 3.5, -- item popup on screen
}

------------------------------------------------------------------------------------------
-- CHESTS ON THE MAP (LootSystem.lua; RoR style: pay gold, get one item)
--   New spots every stage (clear of obstacles, outside the spawn clearing, away from the
--   portal and each other); everything is removed on travel and when the run ends.
--   Price = Cost x stage^CostExponent, x the player's gold multiplier (gamepass owners
--   earn more gold, so they pay the same share: a pass never buys extra items).
--   Run gold is spent: what you earned THIS run (the RunGold counter; it was banked into
--   your saved gold as you earned it, so spending takes it back out). Savings from earlier
--   runs are never touched.
--   Open: stand next to it and hold E / gamepad X / the on-screen button (touch).
------------------------------------------------------------------------------------------
Config.Chests = {
	SmallCount = { 10, 14 }, -- random count per stage (min, max)
	LargeCount = { 2, 3 },
	GoldenCount = 1,
	Cost = { Small = 25, Large = 60, Golden = 150 }, -- on stage 1
	CostExponent = 1.2, -- stage 2 = x2.3, stage 3 = x3.7, stage 5 = x6.9
	HoldSeconds = { Small = 0.8, Large = 1.1, Golden = 1.4, Guarded = 1.2 },
	-- item rarity weights per chest (luck raises Uncommon / Legendary by x(1 + luck))
	Weights = {
		Small = { Common = 80, Uncommon = 19, Legendary = 1 },
		Large = { Common = 0, Uncommon = 80, Legendary = 20 },
		Golden = { Common = 0, Uncommon = 0, Legendary = 100 },
		Guarded = { Common = 0, Uncommon = 75, Legendary = 25 },
		Chance = { Common = 55, Uncommon = 38, Legendary = 7 },
	},
	InteractRadius = 6.5, -- studs from the chest / shrine centre
	-- placement
	Spacing = 32, -- studs between loot spots (relaxed if the map is too full)
	EdgeMargin = 16, -- studs inside the fence
	SpawnExtra = 6, -- studs beyond Config.Arenas.ClearRadius (the spawn clearing)
	PortalClearance = 16, -- studs from the portal
	Clearance = 3.5, -- free radius around a chest (colliders, landmarks)
}

------------------------------------------------------------------------------------------
-- SHRINES (LootSystem.lua). Each one says what it gives and what it costs BEFORE you use
-- it (prompt: "+ benefit" / "- tradeoff") and shows when it is spent.
------------------------------------------------------------------------------------------
Config.Shrines = {
	ChanceCount = { 1, 2 }, -- Shrines of Chance per stage
	BargainCount = 1, -- Bargain Shrines per stage
	HoldSeconds = 1.2,
	-- Shrine of Chance: pay gold, maybe an item. Each try costs more; after MaxItems items
	-- (or MaxTries tries) it goes dark.
	ChanceCost = 15, -- on stage 1 (x stage^Config.Chests.CostExponent, x gold multiplier)
	ChanceCostGrowth = 1.2,
	ChanceSuccess = 0.5,
	ChanceMaxItems = 2,
	ChanceMaxTries = 6,
	-- Bargain Shrine: the whole team gets the benefit, the swarm gets the tradeoff, for the
	-- rest of this stage (enemies that spawn after it, and the Queen)
	BargainDamage = 0.25, -- +25% damage
	BargainGold = 0.3, -- +30% gold from kills
	BargainEnemyHP = 0.2, -- enemies +20% HP
}

------------------------------------------------------------------------------------------
-- GUARDED ALTAR (LootSystem.lua): one per stage. A free rare chest on an altar. Dormant
-- until a living player comes within WakeRadius; then a group of elite guards climbs out
-- around it. When every guard is dead the chest unlocks; opening it gives EVERY living
-- teammate one item (Config.Chests.Weights.Guarded). Guards drop gems, not elite chests.
------------------------------------------------------------------------------------------
Config.Guarded = {
	WakeRadius = 24,
	Guards = 2, -- + GuardsPerStage x stage + GuardsPerExtraPlayer x (players - 1) ...
	GuardsPerStage = 1,
	GuardsPerExtraPlayer = 1,
	MaxGuards = 8, -- ... at most this many
	SpawnRadius = { 12, 20 }, -- ring around the altar
	MinDistance = 90, -- studs from the spawn centre
}

------------------------------------------------------------------------------------------
-- ENEMIES
------------------------------------------------------------------------------------------
Config.Enemies = {
	MaxLive = 200, -- hard cap on living enemies (must be <= PoolSize)
	PoolSize = 300, -- enemy models pre-built at server start
	MaxLiveRanged = 12, -- at most this many Ranged enemies (Spitters) alive; mini-waves never use them
	MaxLiveSupport = 4, -- at most this many Healers alive (+1 per extra player)
	MaxLiveBurrowers = 6, -- at most this many Burrowers alive (+2 per extra player)
	EliteChance = 1 / 80, -- random elites (after Config.Pacing.EliteMinTime); scheduled ones: Pacing
	EliteSizeMult = 2,
	EliteHPMult = 5,
	EliteDamageMult = 1.5,
	EliteBlastMult = 1.4, -- elite Bomb Tick blast radius x this (not x EliteSizeMult) ...
	EliteFuse = 1.0, -- ... and its fuse lasts at least this many seconds
	-- Every elite gets exactly ONE affix (picked at random), shown by its aura (EliteAura_*
	-- models, part fallback) and a small name tag:
	--   Swift     moves faster and leaves a wind trail
	--   Shielded  orbiting plates soak the first ShieldFraction x max HP of damage, then break
	--   Burning   drops small fire patches behind it while it walks; a patch glows for Arm
	--             seconds before it hurts, then burns for Life seconds (Damage every Tick)
	EliteAffixes = { "Swift", "Shielded", "Burning" },
	Affix = {
		Swift = { SpeedMult = 1.45 },
		Shielded = { ShieldFraction = 0.4 },
		Burning = { Every = 0.8, Radius = 2.6, Arm = 0.5, Life = 3.2, Tick = 0.5, Damage = 6, MaxPatches = 5 },
	},
	-- New enemies fade in (client emerge) for this long; they can't hurt anyone meanwhile.
	SpawnGrace = 0.45,
	-- AI thinking (target choice, obstacle raycasts, separation) is split into this many
	-- chunks; each enemy re-thinks every N frames. Movement itself runs every frame.
	ThinkChunks = 3,
	ContactCooldown = 0.6, -- seconds between contact hits from the same enemy
	SeparationRadius = 1.1, -- multiplier on the two radii when pushing enemies apart
	SeparationStrength = 10,
	AvoidRayLength = 9, -- obstacle look-ahead in studs
	AvoidTurnStrength = 1.4,
	KnockbackDecay = 8, -- per second
	HitFlashSeconds = 0.08,
	-- Enemies left far behind are moved to the screen edge again instead of walking back.
	RecycleDistance = 150,
	-- Where pooled (inactive) enemies and gems wait: under the floor, but above
	-- Workspace.FallenPartsDestroyHeight (-200).
	ParkPosition = Vector3.new(0, -150, 0),
}

------------------------------------------------------------------------------------------
-- DIFFICULTY SCALING (tier = floor(minutes))
------------------------------------------------------------------------------------------
Config.Difficulty = {
	HPPerMinute = 0.16, -- enemy HP x(1 + tier * this)
	SpeedPerMinute = 0.02, -- enemy speed x(1 + tier * this) ...
	SpeedCap = 1.3, -- ... capped here
	DamagePerMinute = 0.06, -- enemy damage x(1 + tier * this)
	-- Live-enemy target and burst size multiplier by player count (index = players).
	PlayerCountMult = { 1, 1.6, 2.1, 2.5 },
	-- Enemy HP multiplier per extra player.
	HPPerExtraPlayer = 0.25,
	-- HP and damage stop growing with time after this many minutes (long stage runs lean
	-- on the per-stage multipliers in Config.Stages instead).
	MaxTier = 12,
}

------------------------------------------------------------------------------------------
-- SPAWNING
------------------------------------------------------------------------------------------
Config.Spawn = {
	TickSeconds = 0.4, -- how often the spawner tops up toward the target count
	MaxPerTick = 8,
	-- "ScreenEdge": spawn on a ring just off-screen around a random player, clamped
	--               inside the fence (reads as "from the edges" on a phone).
	-- "ArenaEdge":  spawn right inside the fence on the side nearest a random player.
	Mode = "ScreenEdge",
	ScreenRadius = 72,
	ScreenRadiusJitter = 10,
	MiniWaveBaseCount = 18,
	MiniWavePerMinute = 3,
}

------------------------------------------------------------------------------------------
-- BOSS
------------------------------------------------------------------------------------------
Config.Boss = {
	-- Which BossData entry guards each stage's portal. Stage 1 is always First; later
	-- stages go through BossData.Rotation (Scorpion Queen, Moth Matriarch, Rhino Warlord,
	-- Hive Mother) in a shuffled order that visits every boss before any repeats and never
	-- puts the same boss on two stages in a row. Attack patterns, timings and the entrance /
	-- collapse live in src/shared/BossData.lua; HP and crowd rules stay here.
	First = "ScorpionQueen",
	Id = "ScorpionQueen", -- fallback for old callers (BossAI uses the stage's pick)
	HP = 9000, -- x BossData HPMult x Config.Stages.BossHPByStage[stage]
	HPPerExtraPlayer = 0.6, -- x(1 + this * (players - 1))
	ClearMinionsOnSpawn = true, -- normal enemies vanish when the boss arrives
	MinionCapDuringBoss = 60, -- regular spawning keeps this many alive during the fight
	ContactDamage = 30,
}

------------------------------------------------------------------------------------------
-- PACING (EnemySpawner): the shape of the pressure inside the per-minute spawn table.
--   calm      the first seconds of a run / of every new stage spawn at CalmMult of the
--             normal target (a breather after travel or after the Queen's surge)
--   build-up  between mini-waves the live target climbs from BuildUpFrom to BuildUpTo
--   mini-wave every Config.Run.MiniWaveInterval while exploring (a ring of one type)
--   lull      for MiniWaveLull seconds after a mini-wave the target drops to LullMult, so
--             once the wave is beaten there is a short recovery
--   intro     the first time a type spawns in a run it comes as a small group of
--             IntroGroup with a one-line callout ("New: Spitter - dodge the acid")
--   elites    a scheduled elite at EliteFirst seconds of run time, then every EliteEvery
--             (announced); random elites only after EliteMinTime
--   boss      the Queen fight keeps a reduced crowd (Config.Stages.BossMinionShare)
------------------------------------------------------------------------------------------
Config.Pacing = {
	RunStartCalm = 6,
	StageStartCalm = 10,
	CalmMult = 0.35,
	BuildUpFrom = 0.85,
	BuildUpTo = 1.1,
	MiniWaveLull = 8,
	LullMult = 0.55,
	IntroGroup = 3,
	EliteFirst = 150,
	EliteEvery = 165,
	EliteMinTime = 60,
	EliteTypes = { "Slime", "Skeleton", "Brute", "Ghost", "Spitter" }, -- scheduled elites (never a bomb tick)
	-- smaller intro groups for the later creatures (Healer from 6:00, Burrower from 7:00
	-- in EnemyData.SpawnTable)
	IntroGroupOf = { Healer = 2, Burrower = 2 },
	-- Nests (EnemyData.Nest): stationary spawners on later stages / late in stage 1. The
	-- first one comes FirstStageTime seconds into a stage (stage 1: not before
	-- Stage1RunTime of run time), then every Every seconds, at most PerStage (+1 from
	-- stage 3) per stage and MaxAlive at once, Distance studs from a living player.
	-- Only while exploring (never during the boss fight or the surge).
	Nests = {
		Stage1RunTime = 360,
		FirstStageTime = 50,
		Every = 70,
		PerStage = 2,
		MaxAlive = 2,
		Distance = { 30, 46 },
	},
}

------------------------------------------------------------------------------------------
-- PROJECTILES AND HIT DETECTION
------------------------------------------------------------------------------------------
Config.Projectiles = {
	PoolSize = 500, -- player + boss projectiles alive at once
	CellSize = 20, -- spatial grid bucket size in studs
	Height = 2.5, -- flying height above the floor
	MaxWeaponCooldownFloor = 0.08, -- no weapon fires faster than this
}

------------------------------------------------------------------------------------------
-- NETWORK
------------------------------------------------------------------------------------------
Config.Net = {
	ProjectileSyncHz = 30, -- projectile position batches per second
	FxFlushHz = 30, -- effect batches per second
	-- Remote rate limits (calls per second, per player) for client→server remotes.
	DefaultRate = 8,
}

------------------------------------------------------------------------------------------
-- CAMERA AND CONTROLS (client)
------------------------------------------------------------------------------------------
--[[
	Run camera. Pitch 55 matches the angle the models are designed for (ART_DIRECTION §4)
	and shows more of their sides; the narrower FOV from further away flattens the
	perspective (enemies near the top of the screen keep their size) while the visible
	ground stays what it was. Visible ground at the player (studs, width x depth):
	  16:9 PC        109 x 82  (was 110 x 81 at pitch 58 / 64 studs / FOV 50)
	  19.5:9 phone   133 x 82  (was 135 x 81)
	  9:19.5 phone    38 x 109 (was 38 x 108)
	The spawn ring (Config.Spawn.ScreenRadius) stays past the screen edges at the player's
	row; only the far top corners reach it, slightly less than before.
]]
Config.Camera = {
	Pitch = 55, -- degrees down from horizontal
	Yaw = 0, -- fixed world yaw (degrees)
	RunDistance = 77.5,
	LobbyDistance = 34,
	FieldOfView = 50, -- vertical FOV outside runs (fallback for the menu shot)
	RunFieldOfView = 42, -- vertical FOV of the run / spectate camera
	FollowSharpness = 12, -- higher = snappier follow
	PortraitDistanceMult = 1.35, -- zoom out further when the phone is held upright
	SpectatePanSeconds = 0.4, -- glide to the next teammate when the spectated one falls
	ShakeScale = 1, -- multiplies every screen shake (0 = off)
	ShakeMax = 0.6, -- studs; shakes stay small
}

Config.Controls = {
	StickRadius = 60, -- pixels (before UIScale)
	DeadZone = 0.12,
	-- Touches that start in this part of the screen (0-1 from the left) drive the stick.
	-- 1 = the whole screen; any touch anywhere moves the player.
	TouchZone = 1,
}

------------------------------------------------------------------------------------------
-- GRAPHICS (client only)
------------------------------------------------------------------------------------------
Config.Graphics = {
	-- Enemies drawn with the full animated 3D model. Past this many, extra enemies show
	-- their simple one-part body (keeps phones smooth in huge swarms). The nearest ones
	-- get the models; the boss and elites are always detailed.
	MaxDetailedEnemies = 110,
	-- Effect budget: pooled effect parts animating at once (sparks, dust, rings, bolts).
	-- Cosmetic effects past it are skipped; boss warnings and player events never are.
	MaxEffectParts = 220,
	MaxTrails = 40, -- projectile trails at once (more projectiles fly without one)
	-- Settings > Reduced effects (accessibility): the effect and trail budgets above are
	-- multiplied by this, and screen flashes (hurt pulse, XP flash) are switched off.
	ReducedEffectsBudget = 0.4,
	-- Tall scenery fade (src/client/Occlusion.lua): Parts or Models tagged with Tag
	-- (CollectionService) turn see-through while they cover the local player's
	-- surroundings on screen, and fade back when they don't.
	Occlusion = {
		Tag = "SwarmOccluder",
		Fade = 0.65, -- LocalTransparencyModifier while covering
		CheckHz = 10,
		FadeSeconds = 0.25,
		InnerRadius = 6, -- studs: ground ring around the player that must stay visible
		OuterRadius = 11, -- second ring (enemies about to reach the player)
	},
}

------------------------------------------------------------------------------------------
-- DATA STORE
------------------------------------------------------------------------------------------
Config.Data = {
	StoreName = "SwarmPlayerData",
	KeyPrefix = "Player_",
	SchemaVersion = 6, -- bump and add a migration step in DataService when the save shape changes
	AutoSaveSeconds = 60,
	-- A session lock is considered dead (the server crashed) if it wasn't refreshed for
	-- this long. Must be well above AutoSaveSeconds.
	LockStaleSeconds = 200,
	LoadAttempts = 6,
	LoadRetryDelay = 4,
	SaveAttempts = 4,
	MaxStoredPurchaseIds = 150,
}

------------------------------------------------------------------------------------------
-- MONETIZATION
-- Paste your real IDs here. 0 = not configured (the shop hides/greys that item).
------------------------------------------------------------------------------------------
Config.Monetization = {
	GamePasses = {
		StarterPack = 0, -- +25% gold forever, Gold Trim skin for every character
		VIP = 0, -- +1 reroll per run, [VIP] chat tag, lobby crown
		DoubleGold = 0, -- 2x gold
	},
	Products = {
		Gold500 = 0,
		Gold1500 = 0,
		Gold5000 = 0,
		Revive = 0, -- mid-run revive, offered once per run on death
	},
	ProductGold = { Gold500 = 500, Gold1500 = 1500, Gold5000 = 5000 },
	-- One gamepass per cosmetic skin. Keys must match skin ids in CharacterData.
	SkinPasses = {
		Knight_Crimson = 0,
		Knight_Shadow = 0,
		Knight_Paladin = 0,
		Mage_Frost = 0,
		Mage_Ember = 0,
		Mage_Void = 0,
		Rogue_Forest = 0,
		Rogue_Pirate = 0,
		Rogue_Ninja = 0,
		Priest_Sun = 0,
		Priest_Moon = 0,
		Priest_Angel = 0,
	},
	StarterPackGoldMult = 1.25,
	DoubleGoldMult = 2,
	VIPExtraRerolls = 1,
	RevivePromptSeconds = 12, -- how long the revive offer stays up after death
}

------------------------------------------------------------------------------------------
-- AUDIO (swap freely; rbxasset:// sounds ship with every Roblox client)
-- Music needs Creator Store IDs: open the Creator Store, Audio, filter by "Roblox"
-- (free, licensed), copy the ID and paste it as "rbxassetid://<id>". Empty = silent.
------------------------------------------------------------------------------------------
--[[
	Sound effects and music. Every effect uses a sound that ships with Roblox
	(rbxasset://sounds/...) until licensed audio is chosen: put an uploaded asset in Id
	("rbxassetid://123") to replace one. Music slots are empty on purpose (no licensed
	tracks yet): set LobbyMusic / BattleMusic / BossMusic Id to an audio asset you own or
	that is free to use, and the client plays it (looped) in the lobby, during a run and
	during the Queen fight. Volume is the sound's own volume; the player's Music / Effects
	sliders scale everything on top.

	Fields: Category (Config.Audio.Categories: voice limit, priority, ducking), MinGap (s
	between two plays of this sound), Pitch (base playback speed) and PitchVar (random
	+/- around it, so repeats don't sound mechanical), World = played at a world position
	(3D, quieter far away) when the caller gives one.
]]
Config.Sounds = {
	-- combat (lowest priority: there is always a lot of it)
	Hit = { Id = "rbxasset://sounds/swordslash.wav", Volume = 0.22, Category = "Combat", MinGap = 0.06, PitchVar = 0.08 },
	EnemyDeath = { Id = "rbxasset://sounds/snap.mp3", Volume = 0.2, Category = "Combat", MinGap = 0.06, PitchVar = 0.1 },
	Lightning = { Id = "rbxasset://sounds/Rocket shot.wav", Volume = 0.3, Category = "Combat", MinGap = 0.1, PitchVar = 0.08 },
	Explosion = { Id = "rbxasset://sounds/collide.wav", Volume = 0.55, Category = "Combat", MinGap = 0.12, PitchVar = 0.06, World = true },
	-- the local hero's own attacks and body
	Swing = { Id = "rbxasset://sounds/swordlunge.wav", Volume = 0.16, Category = "Player", MinGap = 0.14, PitchVar = 0.08 },
	Throw = { Id = "rbxasset://sounds/Rocket whoosh 01.wav", Volume = 0.08, Category = "Player", MinGap = 0.2, Pitch = 1.3, PitchVar = 0.1 },
	Hurt = { Id = "rbxasset://sounds/action_jump_land.mp3", Volume = 0.6, Category = "Player", MinGap = 0.25, Pitch = 0.85, PitchVar = 0.05 },
	Death = { Id = "rbxasset://sounds/collide.wav", Volume = 0.8, Category = "Player", Pitch = 0.75, PitchVar = 0 },
	LevelUp = { Id = "rbxasset://sounds/electronicpingshort.wav", Volume = 0.7, Category = "Player", MinGap = 0.3, PitchVar = 0 },
	Revive = { Id = "rbxasset://sounds/electronicpingshort.wav", Volume = 0.6, Category = "Player", MinGap = 0.3, Pitch = 1.3, PitchVar = 0 },
	-- pickups and rewards
	GemPickup = { Id = "rbxasset://sounds/clickfast.wav", Volume = 0.25, Category = "Pickup", MinGap = 0.05, Pitch = 1.1, PitchVar = 0.12 },
	Chest = { Id = "rbxasset://sounds/electronicpingshort.wav", Volume = 0.6, Category = "Pickup", MinGap = 0.2, PitchVar = 0 },
	Item = { Id = "rbxasset://sounds/electronicpingshort.wav", Volume = 0.5, Category = "Pickup", MinGap = 0.15, Pitch = 1.15, PitchVar = 0 },
	Shrine = { Id = "rbxasset://sounds/button.wav", Volume = 0.6, Category = "Pickup", MinGap = 0.2, PitchVar = 0 },
	Victory = { Id = "rbxasset://sounds/victory.wav", Volume = 0.5, Category = "UI", PitchVar = 0 },
	-- warnings: telegraphs that ask the player to move (never dropped for combat noise)
	FuseTick = { Id = "rbxasset://sounds/clickfast.wav", Volume = 0.45, Category = "Warning", MinGap = 0.09, Pitch = 1.6, PitchVar = 0.03, World = true },
	SpitterWindup = { Id = "rbxasset://sounds/splat.wav", Volume = 0.3, Category = "Warning", MinGap = 0.25, Pitch = 1.3, PitchVar = 0.08, World = true },
	Lunge = { Id = "rbxasset://sounds/unsheath.wav", Volume = 0.35, Category = "Warning", MinGap = 0.2, Pitch = 0.8, PitchVar = 0.06, World = true },
	-- the Queen
	BossRoar = { Id = "rbxasset://sounds/Launching rocket.wav", Volume = 0.9, Category = "Boss", MinGap = 1, PitchVar = 0.04 },
	BossWarn = { Id = "rbxasset://sounds/Rocket whoosh 01.wav", Volume = 0.45, Category = "Boss", MinGap = 0.4, Pitch = 0.7, PitchVar = 0.04, World = true },
	BossSummon = { Id = "rbxasset://sounds/splat.wav", Volume = 0.45, Category = "Boss", MinGap = 0.4, Pitch = 0.6, PitchVar = 0.05, World = true },
	-- the rotating bosses (Telegraphs plays these for their new warning shapes)
	BossWave = { Id = "rbxasset://sounds/Rocket whoosh 01.wav", Volume = 0.5, Category = "Boss", MinGap = 0.5, Pitch = 0.55, PitchVar = 0.04, World = true },
	BossGust = { Id = "rbxasset://sounds/Rocket whoosh 01.wav", Volume = 0.5, Category = "Boss", MinGap = 0.5, Pitch = 0.42, PitchVar = 0.03, World = true },
	BossPound = { Id = "rbxasset://sounds/collide.wav", Volume = 0.6, Category = "Boss", MinGap = 0.3, Pitch = 0.6, PitchVar = 0.04, World = true },
	BossMine = { Id = "rbxasset://sounds/electronicpingshort.wav", Volume = 0.25, Category = "Warning", MinGap = 0.15, Pitch = 1.8, PitchVar = 0.1, World = true },
	BossEmerge = { Id = "rbxasset://sounds/splat.wav", Volume = 0.4, Category = "Boss", MinGap = 0.4, Pitch = 0.45, PitchVar = 0.05, World = true },
	BossBanner = { Id = "rbxasset://sounds/unsheath.wav", Volume = 0.5, Category = "Boss", MinGap = 0.5, Pitch = 0.6, PitchVar = 0.03, World = true },
	BurrowWarn = { Id = "rbxasset://sounds/splat.wav", Volume = 0.3, Category = "Warning", MinGap = 0.25, Pitch = 0.7, PitchVar = 0.08, World = true },
	HealPulse = { Id = "rbxasset://sounds/electronicpingshort.wav", Volume = 0.2, Category = "Combat", MinGap = 0.3, Pitch = 0.75, PitchVar = 0.05, World = true },
	-- interface
	Click = { Id = "rbxasset://sounds/button.wav", Volume = 0.45, Category = "UI", MinGap = 0.05, PitchVar = 0 },
	Toggle = { Id = "rbxasset://sounds/button.wav", Volume = 0.4, Category = "UI", MinGap = 0.05, Pitch = 1.25, PitchVar = 0 },
	Tip = { Id = "rbxasset://sounds/electronicpingshort.wav", Volume = 0.2, Category = "UI", MinGap = 0.5, Pitch = 1.5, PitchVar = 0 },
	-- music slots (empty = silent; see the note above)
	LobbyMusic = { Id = "", Volume = 0.35, Category = "Music" },
	BattleMusic = { Id = "", Volume = 0.3, Category = "Music" },
	BossMusic = { Id = "", Volume = 0.35, Category = "Music" },
}

--[[
	Mixing rules for Config.Sounds (client Audio.lua).
	  MaxVoices   effects playing at once in total; a new sound with a higher Priority
	              steals the voice of the oldest lower-priority one, a lower one is dropped
	  Categories  per category: Volume (sub-mix), MaxVoices, Priority (higher wins)
	  Duck        while a Warning / Boss sound plays, Combat is turned down this much
	  World       3D sounds: full volume up to RollOffMin studs from the camera (the run
	              camera sits ~78 studs from the hero), fading out by RollOffMax
]]
Config.Audio = {
	MaxVoices = 14,
	Categories = {
		Combat = { Volume = 0.9, MaxVoices = 4, Priority = 1 },
		Pickup = { Volume = 1, MaxVoices = 3, Priority = 2 },
		UI = { Volume = 1, MaxVoices = 2, Priority = 3 },
		Player = { Volume = 1, MaxVoices = 3, Priority = 4 },
		Warning = { Volume = 1, MaxVoices = 3, Priority = 5 },
		Boss = { Volume = 1, MaxVoices = 2, Priority = 5 },
	},
	Duck = { Triggers = { "Warning", "Boss" }, Target = "Combat", Volume = 0.45, Seconds = 0.5 },
	World = { RollOffMin = 90, RollOffMax = 280, Emitters = 10 },
	DefaultPitchVar = 0.05,
}

--[[
	Player settings (saved in the profile, checked by the server: GoldSystem SaveSettings).
	  Music, Sfx       volumes 0-1
	  Shake            screen shake strength 0-1 (0 = off)
	  ReducedEffects   fewer particles and trails, no screen flashes or pulsing edges
	  DamageNumbers    floating damage numbers over enemies (off by default; summed per
	                   enemy and capped, so a swarm never turns into a wall of text)
	  Tips             contextual hints (first run tutorial, co-op rules)
]]
Config.Settings = {
	Defaults = { Music = 0.6, Sfx = 0.8, Shake = 1, ReducedEffects = false, DamageNumbers = false, Tips = true },
}

--[[
	First-run tips (client Tutorial.lua): small hints that teach through play, each shown
	once (the server keeps the ids seen in the profile: SeenTips) and dismissed on their
	own; they never pause or block the run. A player with any run played before this
	feature (Stats.Runs > 0) starts with TutorialDone, so only brand new players see them.
	Settings: "Show tips" switches them off, "Replay tips" shows them again next run.
	TeamRules (shared XP, own gold and items) shows once in the first group run, also for
	experienced players.
]]
Config.Tutorial = {
	Tips = { "Move", "Attack", "Gems", "LevelUp", "Portal", "Boss", "Revive", "TeamRules" },
	HintSeconds = 6.5, -- each hint stays this long
	GapSeconds = 1.5, -- pause between two hints
	FirstDelay = 1.5, -- the first hint after the run starts
	PortalTipAt = 40, -- run seconds before the portal objective is explained
}

--[[
	Optional floating damage numbers (Settings > Damage numbers, off by default). The server
	sums each player's damage per enemy and sends it only to players who switched the
	setting on, FlushHz times a second (at most MaxPerFlush enemies, the biggest hits
	first). The client merges a new hit into an enemy's number still on screen, creates at
	most MaxNewPerFrame numbers per frame and shows at most MaxLabels at once.
]]
Config.DamageNumbers = {
	FlushHz = 8,
	MaxPerFlush = 16,
	MaxLabels = 18,
	MaxNewPerFrame = 3,
	MergeSeconds = 0.5,
	LifeSeconds = 0.9,
}

------------------------------------------------------------------------------------------
-- UI
------------------------------------------------------------------------------------------
Config.UI = {
	ReferenceSize = Vector2.new(1280, 720), -- UI is designed at this size, UIScale fits it
	-- Phones would scale the reference layout down to ~0.5; this floor keeps touch targets
	-- and text big enough (layouts reflow into the smaller virtual space instead).
	MinScale = 0.6,
	MaxScale = 1.5,
	-- Fonts and sizes live in Theme (Merriweather titles, Source Sans body / numbers).
	-- These two are only the fallbacks for plain Enum.Font properties.
	Font = Enum.Font.SourceSansBold,
	BodyFont = Enum.Font.SourceSans,
	ToastSeconds = 3,
	-- Lobby screen
	PreviewSpinSeconds = 9, -- one full turn of the 3D character previews
	ScreenSlideSeconds = 0.3, -- slide between lobby screens
	-- Hero on the lobby dais (client-only clone, see src/client/Showcase.lua)
	ShowcaseYawDegrees = 0, -- extra turn away from the menu camera (0 = faces it)
	ShowcaseClearRadius = 8, -- lobby characters this close to the dais are hidden locally
	-- Upgrade bar (weapons + passives at the bottom of the screen during a run)
	BarWeaponTile = 54,
	BarPassiveTile = 44,
	-- HUD
	LowHealthFraction = 0.3, -- below this the screen edge pulses crimson
}

------------------------------------------------------------------------------------------
-- ARENAS AND LOBBY
------------------------------------------------------------------------------------------
Config.Arenas = {
	-- Lobby picker order (the ARENA card cycles through the unlocked ones).
	Order = { "Forest", "Ruins", "Swamp", "Snow", "Desert", "Lava" },
	-- Stage runs: stage 1 is the lobby's arena, later stages tour Rotation (shuffled per
	-- run when ShuffleRotation; when the tour runs out it reshuffles every arena). Never
	-- the same arena twice in a row.
	Rotation = { "Ruins", "Swamp", "Snow", "Desert", "Lava" },
	ShuffleRotation = true,
	-- RequiredBestStage: the arena can be picked in the lobby once the player has reached
	-- this stage in a run (Stats.BestStage). Stage runs visit every arena regardless.
	-- Hint: the lobby ARENA card subtitle for the picked arena.
	Forest = { DisplayName = "Forest", RequiredBestStage = 0, Hint = "A mossy clearing" },
	Ruins = { DisplayName = "Ruins", RequiredBestStage = 2, Hint = "Sunlit old stones" },
	Swamp = { DisplayName = "Swamp", RequiredBestStage = 3, Hint = "Mud pools slow you" },
	Snow = { DisplayName = "Snow", RequiredBestStage = 4, Hint = "Ice ponds are slippery" },
	Desert = { DisplayName = "Desert", RequiredBestStage = 5, Hint = "Beware the quicksand" },
	Lava = { DisplayName = "Lava", RequiredBestStage = 6, Hint = "Lava pools burn" },
	Size = 400, -- square arena, centred on ArenaOrigin
	ClearRadius = 40, -- nothing collidable this close to the centre (player spawn)
	-- Layouts (landmarks, groves, paths) are designed in MapBuilder with a fixed seed per
	-- arena; obstacle coverage is kept close to the old builder (see MapBuilder header).

	-- Biome floor hazards (server-authoritative, src/server/Modules/BiomeHazards.lua):
	-- fixed pools in the designed layouts, shown by their own meshes (lava also glows),
	-- never in the spawn clearing and never under the portal or the loot. A player is in
	-- a pool while their root is within its radius. Flyers and bosses ignore all of them.
	Hazards = {
		CheckInterval = 0.1, -- seconds between checks
		-- Swamp: mud slows players and walking enemies
		Mud = { PlayerSpeed = 0.65, EnemySpeed = 0.65 },
		-- Desert: quicksand slows harder
		Quicksand = { PlayerSpeed = 0.55, EnemySpeed = 0.55 },
		-- Snow: frozen ponds are slippery: faster, but turning and stopping drift (the
		-- client smooths the move input with this time constant); enemies keep their footing
		Ice = { PlayerSpeed = 1.2, DriftSeconds = 0.35 },
		-- Lava: burns players (Damage before armor, every Tick seconds, the first tick
		-- Grace seconds after stepping in; respects invulnerability); enemies are at home
		Lava = { Damage = 6, Tick = 0.5, Grace = 0.25 },
		-- the portal and the loot keep at least this much floor from a pool's edge
		LootPad = 4,
	},
}

-- Run modes, picked with the big SOLO / DUO / TRIO buttons on the lobby screen.
--   Solo  starts at once (no countdown).
--   Duo / Trio  count down (Config.Run.CountdownSeconds) so others can join; the starter
--   can press START NOW once someone joined, and a full run starts by itself.
-- A fallen player can be revived by a teammate standing next to them (PartnerRevive).
local PARTNER_REVIVE = {
	Seconds = 3, -- stand this long next to a fallen teammate to revive them
	Radius = 7,
	HPFraction = 0.4,
	PerRun = 3, -- per downed player
}
Config.Modes = {
	Order = { "Solo", "Duo", "Trio" }, -- modes shown in the lobby (and accepted from clients)
	Solo = { DisplayName = "Solo", MaxPlayers = 1, Countdown = false },
	Duo = { DisplayName = "Duo", MaxPlayers = 2, Countdown = true, PartnerRevive = PARTNER_REVIVE },
	Trio = { DisplayName = "Trio", MaxPlayers = 3, Countdown = true, PartnerRevive = PARTNER_REVIVE },
	-- Old 1-4 player mode: no longer in the UI, still accepted from old clients (JoinRun).
	Squad = { DisplayName = "Squad", MaxPlayers = 4, Countdown = true },
	-- The Daily Challenge (lobby DAILY card): solo, fixed arena tour / bosses / curses /
	-- starting bonus per UTC day (CurseData.Daily). Not in Order: it has its own card.
	Daily = { DisplayName = "Daily", MaxPlayers = 1, Countdown = false },
}

------------------------------------------------------------------------------------------
-- LEADERBOARDS (server LeaderboardService.lua, OrderedDataStores)
--   Best Stage (all time), Daily Challenge (today's scored attempts), Most Kills (one run).
--   Writes happen when a run is committed, queued and throttled per player and board, and
--   only while the DataStore write budget allows; reads are cached and refreshed at most
--   every RefreshSeconds while someone looks at them. Without DataStores (Studio without
--   API access) the boards show this server's runs only, with a clear note.
------------------------------------------------------------------------------------------
Config.Leaderboards = {
	Enabled = true,
	StorePrefix = "SwarmLB_", -- OrderedDataStore names: SwarmLB_BestStage, SwarmLB_Kills, SwarmLB_Daily_<day>
	Order = { "BestStage", "Daily", "Kills" },
	Top = 50, -- entries shown
	RefreshSeconds = 60, -- a board's cache is re-read at most this often
	WatchSeconds = 180, -- boards nobody asked for this long are not refreshed
	WriteThrottleSeconds = 30, -- one write per player and board at most this often
	FlushSeconds = 6, -- the write queue is checked this often
	MinBudget = 3, -- keep this many DataStore requests of a type in reserve
	MaxRetries = 5,
}

Config.ArenaOrigin = Vector3.new(0, 0, 0) -- floor top surface is at this height
Config.Lobby = {
	Origin = Vector3.new(1200, 0, 0), -- the castle courtyard (menu backdrop), far from the arena
	MenuFieldOfView = 55, -- FOV of the menu shot (MenuCamera attribute; portrait widens it)
}

------------------------------------------------------------------------------------------
-- MOVEMENT: jump and bunny hop (client JumpController.lua, server MovementGuard.lua)
--   Jump: Space / gamepad A / the JUMP button (touch). A press shortly before landing is
--   kept (BufferSeconds) and a press just after walking off an edge still jumps
--   (CoyoteSeconds). No jumping while the run is frozen (level-up, pause), downed or in
--   the lobby.
--   Bunny hop: jumping again within HopWindow of landing (while moving) adds HopBonus to
--   a speed multiplier, never above HopSpeedCap. On the ground it decays back to 1 at
--   HopDecay per second (and resets at once when the player stops).
--   Air control: in the air the move input only steers the takeoff direction at
--   AirControl per second (modest; no full mid-air turns).
--   Server: MovementGuard trims horizontal velocity that stays above
--   WalkSpeed * HopSpeedCap * ServerTolerance + ServerAllowance for ServerGraceSeconds
--   (lag tolerant, never kicks). RunManager's position check still applies on top.
------------------------------------------------------------------------------------------
Config.Movement = {
	JumpEnabled = true,
	JumpPower = 38, -- studs/s upward (about 3.7 studs high, 0.39 s in the air at 196.2 gravity)
	BufferSeconds = 0.12,
	CoyoteSeconds = 0.1,
	JumpCooldown = 0.2, -- minimum time between two jumps
	AirControl = 3.5, -- how fast the air direction follows the stick (per second)
	HopWindow = 0.15, -- seconds after landing in which a jump counts as a chained hop
	HopBonus = 0.06, -- speed multiplier added per chained hop
	HopSpeedCap = 1.24, -- hard cap on the hop speed multiplier
	HopDecay = 0.6, -- multiplier lost per second on the ground after HopWindow
	ServerTolerance = 1.15,
	ServerAllowance = 3, -- studs/s
	ServerGraceSeconds = 0.35, -- over-speed must last this long before it is trimmed
	ButtonSize = 84, -- touch JUMP button (pixels before UIScale)
	ButtonMargin = 26, -- from the right and bottom safe-area edges
}

return Config
