--[[
	Config.lua
	Every tunable number in SWARM lives here. Server and client both read this module,
	so changing a value here changes it everywhere on the next sync.

	Sections:
	  Run, Dev, Player, Slots, LevelUp, XP, Gold, Drops, Items, Chests, Shrines, Guarded,
	  Enemies, Difficulty, Spawn, Boss, Pacing,
	  Projectiles, Net, Camera, Controls, Graphics, Data, Monetization, Sounds, Audio,
	  Settings, Tutorial, DamageNumbers, UI, Arenas, Modes, Lobby, Features (FeatureOn),
	  Encounters (Director), FeatureHud, WorldEvents, Weather
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
	ResultsSeconds = 12, -- defeat screen time before everyone is sent back automatically (MAIN MENU leaves at once)
	MaxPlayers = 4, -- players per run (server MaxPlayers should match in game settings)
	ArenaSpawnSpread = 10, -- players are placed in a circle of this radius at run start
	-- A solo player who opens the pause menu freezes the whole run. In a group run the
	-- menu is only an overlay (the run keeps going), so nobody can stall a shared run.
	SoloPauseFreezesRun = true,
	-- Level-up cards and chest rewards freeze the world only when one player is left
	-- fighting. In a group run the chooser / opener stands still and can't be hurt
	-- (Player.LevelUpInvulnerable) while everyone else keeps playing.
	CoopChoiceFreezesRun = false,
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
	-- The portal can sleep for a while after a stage starts: it can't be charged before
	-- this many seconds on the stage (stage 1, later stages); the HUD says "The portal is
	-- dormant: m:ss". 0 = the portal can be charged at any time (owner's choice).
	PortalLockSeconds = { 0, 0 },
	-- The portal REVEAL (SwarmState PortalReveal counts up; PortalHint turns on): the
	-- moment the portal can be charged, at the earliest RevealDelaySeconds into the stage
	-- so the "STAGE N" banner has gone first. Clients make it unmistakable: a banner and a
	-- sound, the tall beacon pillar + pulsing floor ring (client PortalBeacon), the edge
	-- arrow with the distance (StageUI) and a minimap ping (MiniMap). Owner: "when the
	-- portal spawns it needs to be very evident."
	RevealDelaySeconds = 4,
	-- the HUD arrow toward the portal appears after this long (never before the lock ends
	-- or the reveal delay); 0 = from the reveal on, always
	HintAfterSeconds = 0,
	-- SWARM PRESSURE: the swarm keeps growing until the portal is charged. While exploring,
	-- SwarmState SwarmWarn steps to 1 ("SWARM GROWING") at WarnSeconds of stage time and to
	-- 2 ("SWARM OVERWHELMING") at DangerSeconds, back to 0 on the next stage. The HUD
	-- turns the stage pill into OPEN THE PORTAL with the warning and a banner each step;
	-- with waves on (Config.Waves) each step makes the waves bigger (PressureMult).
	Pressure = { WarnSeconds = 75, DangerSeconds = 150 },
	-- difficulty on top of the run-time scaling, x(1 + this * (stage - 1))
	-- 0.35 (was 0.25): owner playtest "by map 2 players instant kill everything"; stage 1
	-- stays as it was
	EnemyHPPerStage = 0.35,
	EnemyDamagePerStage = 0.08, -- also the boss's contact / orb damage and bomb ticks
	SpawnTargetPerStage = 0.1, -- live-enemy target and mini-wave size
	-- Scorpion Queen HP = Config.Boss.HP x this (x the player-count scaling). She comes
	-- much earlier than the old 15:00 boss, so stage 1 is lighter; then +BossHPPerExtraStage
	-- per stage past the list.
	-- { 0.22, 0.4, 0.7, 1.05, 1.5 } (was 0.3, 0.75, 1.1, 1.5, 2.0): stage 2's boss was a x2.5
	-- jump (owner: "round two is way too hard") and the stage-1 Queen took a level-6 hero
	-- 3-4 minutes in pacing-sim; now steps of x1.8, x1.75, x1.5, x1.43
	-- { .., .., 0.85, 1.35, 2.0 } (was 0.7, 1.05, 1.5; overhaul 2026-10-04,
	-- docs/overhaul/BALANCE_TUNE.md): stage 3-5 bosses fell in 6-35 s for a buying build;
	-- econ-sim boss time on stage 3 went 25 -> 30 s (n=5). Stages 1-2 unchanged.
	-- stage 2 0.4 -> 0.5 (owner OK 2026-10-05, audit W-12): a buying build found the second
	-- world easier than the first (boss time below in docs/audit/WORLD.md). Others unchanged.
	BossHPByStage = { 0.22, 0.5, 0.85, 1.35, 2.0 },
	-- 0.4 (was 0.5): with the Endless boss growth on top, stage 6 was a x1.44 jump over
	-- stage 5; now x1.27 (Standard) / x1.39 (Endless), then smaller steps
	BossHPPerExtraStage = 0.4,
	BossSpawnOffset = 12, -- the Queen climbs out this far behind the portal
	-- regular enemies kept alive during the Queen fight: this share of the normal live
	-- target, at most Config.Boss.MinionCapDuringBoss and at least BossMinionMin
	-- 0.35 / 12 (was 0.5 / 15): auto-aim spent the fight on the crowd (pacing-sim: the
	-- stage-1 Queen took ~4 minutes), so the boss fight thins the swarm more
	BossMinionShare = 0.35,
	BossMinionMin = 12,
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
	-- group runs: the countdown waits while a living player has an upgrade choice open, for
	-- at most this many seconds per stage clear (> one group panel, GroupAutoPickSeconds 10)
	ChoiceHoldMaxSeconds = 12,
	TravelFadeSeconds = 0.8, -- screen fade before / after the arena swap
	TravelHealFraction = 0.6, -- living players are healed up to at least this share of max HP
	ReviveOnTravelHPFraction = 0.5, -- fallen teammates stand up again on the next stage
	-- RETURN TO LOBBY counts as a WIN (Stats.Wins) only with at least this many stages
	-- cleared; the gold bonus (Config.Gold.WinBonus + StageClearBonus) is paid either way.
	WinMinStages = 5,
}

------------------------------------------------------------------------------------------
-- ENDLESS (an option on SOLO / DUO / TRIO; never the Daily Challenge)
--   The run's starter switches ENDLESS on in the lobby (remote SetEndless, saved as
--   data.Endless; RunModifiers fixes it when the run begins, like curses). An Endless run
--   has no win: the open portal only offers NEXT STAGE (StageManager), the run ends when
--   everyone falls or leaves through the pause menu's MAIN MENU. Biomes and bosses keep
--   rotating as in any long run. Score goes to its own board "ScoreEndless".
--   Difficulty: up to LastNormalStage it is exactly the Standard curve. Past it every
--   stage adds, on top of the Standard per-stage multipliers (Config.Stages):
--     extra      = min(stage - LastNormalStage, MaxExtraStages)   (0 before that)
--     enemy HP   x(1 + HPPerStage * extra)          → at most x7 at the cap
--     damage     x(1 + DamagePerStage * extra)      → at most x4
--     boss HP    x(1 + BossHPPerStage * extra)      → at most x4
--     spawns     x min(1 + SpawnPerStage * extra, SpawnMultCap) (live target, mini-waves)
--   Live enemies stay capped by Config.Enemies.MaxLive (and the surge by it too), so the
--   server load is bounded however deep a run goes; past the cap only HP / damage grow.
------------------------------------------------------------------------------------------
Config.Endless = {
	Enabled = true,
	Modes = { "Solo", "Duo", "Trio" }, -- modes that may run Endless
	LastNormalStage = 5, -- the Standard curve's last tuned stage (#Config.Stages.BossHPByStage)
	HPPerStage = 0.2,
	DamagePerStage = 0.1,
	BossHPPerStage = 0.1, -- was 0.15 (see Config.Stages.BossHPPerExtraStage)
	SpawnPerStage = 0.05,
	SpawnMultCap = 1.5,
	MaxExtraStages = 30, -- growth stops this many stages past LastNormalStage (stage 35)
}

------------------------------------------------------------------------------------------
-- DEV TOOLS (Studio and the game's creator only; the server re-checks every request)
------------------------------------------------------------------------------------------
Config.Dev = {
	Enabled = true, -- false hides the DEV button everywhere and ignores dev requests
	-- Dev controls show in Studio, and in live servers to the UserIds in the server-only
	-- DevAllowlist (the owner). true also gives them to the game's creator (user-owned
	-- games). The server checks every command (DevAccess.lua); normal players never see it.
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
	BaseMaxHP = 120,
	BaseSpeed = 16, -- Humanoid WalkSpeed
	BasePickupRadius = 7, -- studs, gems inside this radius fly to you
	BaseLuck = 0, -- 0.1 = +10%
	BaseArmor = 0, -- flat damage reduction per hit
	MinDamagePerHit = 1, -- armor can never reduce a hit below this
	HurtFlashSeconds = 0.15,
	ReviveHPFraction = 0.5, -- revived players come back with this share of max HP
	ReviveInvulnSeconds = 3,
	-- grace after closing the level-up cards or a chest reward: can't be hurt this long, so
	-- the swarm that closed in meanwhile doesn't land a hit the moment play resumes
	ChoiceGraceSeconds = 1.5,
	-- after taking CONTACT damage (an enemy body touching you), further contact hits are
	-- ignored this long, so a crowd cannot stack several bites into one frame; area
	-- attacks, projectiles and hazards are not affected (RunManager.DamagePlayer)
	ContactGraceSeconds = 0.4,
	ReviveClearRadius = 22, -- non-boss enemies inside this radius die on revive
	LevelUpInvulnerable = true, -- paused (choosing an upgrade) players can't be hurt
	-- Movement sanity check: the server snaps players back if they move faster than their
	-- speed * Movement.HopSpeedCap * Movement.ServerTolerance (plus a small allowance for lag).
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
	ChoicesPerPanel = 4,
	-- levels earned while a panel is open join it (a burst of filled bars becomes one
	-- longer panel instead of panel after panel), up to this many choices in total
	PanelMergeMax = 6,
	-- If a player doesn't pick in this many seconds a random card is chosen for them,
	-- so nobody can stay paused (and protected) forever.
	AutoPickSeconds = 25,
	-- In Duo/Trio the chooser stands still and can't be hurt while the team keeps playing
	-- (Run.CoopChoiceFreezesRun), so the auto-pick comes sooner.
	GroupAutoPickSeconds = 10,
	-- Duo/Trio protection budget (docs/overhaul/CHOICE_STATE.md): seconds a player may spend
	-- protected (choosing an upgrade, close grace; rewards never protect) while the team plays on. It drains while
	-- protected and refills at RefillPerMinute; a panel's deadline never exceeds what is left,
	-- and a new panel waits (levels stay banked) until at least GroupMinPanelSeconds are back.
	-- So nobody can stay protected more than ~ProtectBudgetSeconds out of every minute.
	ProtectBudgetSeconds = 20,
	ProtectBudgetRefillPerMinute = 20,
	GroupMinPanelSeconds = 4,
	SkipGold = 10, -- run gold granted when a level-up is skipped
	-- Relative weights for building the 3 cards. Luck multiplies the "new" weights.
	-- (cardpool measure, 1000 real rolls: the old 10 / 7 / shared-weapons-only weights
	-- offered the starting weapon at the first level-up 18 % of the time; these 70 %)
	WeightUpgradeWeapon = 12,
	WeightUpgradePassive = 8,
	WeightNewWeapon = 6,
	WeightNewPassive = 5,
	-- the new-weapon / new-passive weights are each shared out as if there were at most
	-- this many you don't own yet (27 weapons and 26 passives must not crowd out upgrades) ...
	NewWeaponPoolRef = 8,
	NewPassivePoolRef = 8,
	-- ... and fewer while the build is young: Start with one item owned, +PerItem for each
	-- further weapon / passive owned (LevelUpSystem newShare)
	NewPoolRefStart = 2.5,
	NewPoolRefPerItem = 1,
	WeightEvolution = 40, -- an available evolution is almost always offered
	-- a passive that evolves a weapon you own (and don't have yet) is this much likelier
	EvolutionPassiveWeightMult = 1.5,
	-- weapon cards from this level on say what the weapon evolves with ("Evolves at Lv 12
	-- with Heart (owned)")
	EvolveHintLevel = 9,
	-- Rarity names → card colour (UI) and label.
	Rarities = {
		Common = { Label = "Upgrade", Color = Color3.fromRGB(205, 210, 220) },
		Rare = { Label = "New", Color = Color3.fromRGB(80, 160, 255) },
		Epic = { Label = "Max", Color = Color3.fromRGB(190, 90, 255) },
		Legendary = { Label = "EVOLUTION", Color = Color3.fromRGB(255, 200, 40) },
	},
	FallbackGold = 25, -- card offered when every slot is maxed
	FallbackHeal = 30,
	-- early build help (LevelUpSystem rollChoices): for the first this-many level-ups of a
	-- run, a card set with no Damage / Recovery / Defense card swaps its lowest-weight
	-- other card (Utility first, then Growth) for a weighted one, when the pool has one
	EarlyHelpLevels = 3,
	-- seconds added to every panel deadline (solo and group, still capped by the group
	-- protection budget) so the auto-pick clock never runs while the client loads the
	-- icons, plays the card reveal and arms touch input (up to ~1.2 s)
	RevealGraceSeconds = 1.5,
	-- Banish (batch B, Config.Features.Banish, docs/next/BANISH.md): BANISH then a NEW card
	-- removes that weapon / passive from the offers for the rest of the run, this many per run
	Banishes = 3,
}

------------------------------------------------------------------------------------------
-- XP AND GEMS
------------------------------------------------------------------------------------------
Config.XP = {
	-- XP needed to go from level L to L+1 = Base + min(L, CapLevel) * PerLevel
	-- Early costs grow by PerLevel; after CapLevel, each extra level adds AfterCapPerLevel.
	-- Every filled bar offers an upgrade at once (no pacing timer): the ONLY brake on how
	-- often the upgrade cards appear is this cost curve. levelrate-sim (real server, hero
	-- walking in the swarm) measured ~3 level-ups per minute solo on the old 20 + 8/level
	-- curve; these costs (x1.5) bring that to ~2 per minute. Level 1 costs 42, level 20
	-- costs 270, level 21 costs 276, level 50 costs 450.
	Base = 30,
	PerLevel = 12,
	CapLevel = 20,
	AfterCapPerLevel = 6,
	-- Co-op: XP is shared (every living teammate gets every gem), while Duo / Trio spawn
	-- Config.Difficulty.PlayerCountMult times the enemies and several heroes kill faster,
	-- so without a brake a duo levelled about twice as fast per player as a solo hero and
	-- everyone sat through everyone's upgrade panels. Shared gem XP is multiplied by this
	-- (index = living participants) so each player's bar fills about as fast as solo.
	CoopShare = { 1, 0.5, 0.36, 0.3 },
	-- Gem XP pacing (the cost curve above stays as set). pacing-sim (real server, solo hero
	-- in the swarm) measured the kill rate climbing ~7x from stage 1 to stage 4 while level
	-- costs only grow ~5x: the first level-up came at 0:38 with 35-45 s gaps, stage 3-5
	-- levelled every 5-15 s and finished in bursts of 15-20 levels (with waves and the
	-- per-stage spawn rows, Config.Spawn.StageRowSpan, kills grow less). Collected gem XP is
	-- multiplied by OpeningMult for the first OpeningSeconds of a run and by StageMult[stage]
	-- (the last entry for later stages), so every stage levels at a similar pace.
	OpeningSeconds = 90,
	OpeningMult = 1.5,
	StageMult = { 1, 1, 0.9, 0.8, 0.7 },
	GemValues = { Small = 1, Medium = 5, Large = 25 },
	GemPoolSize = 500,
	MagnetSpeed = 45, -- studs/s a gem flies toward the player once inside pickup radius
	MagnetAcceleration = 90,
	CollectDistance = 3, -- studs from the player's root
	GemHeight = 1.2, -- resting height above the floor
	-- Server gem cube edge per kind (studs). The client reads the kind back from the size
	-- and draws a blue-white crystal about 1.5x / 1.9x / 2.5x as tall (VFX).
	GemSize = { Small = 1.1, Medium = 1.45, Large = 1.9 },
	-- A new gem lands on a resting one within MergeRadius studs (their values add up, so no
	-- XP is lost) as long as the total stays at most MergeMax; keeps big fights from
	-- littering the floor with hundreds of crystals.
	MergeRadius = 2.4,
	MergeMax = 25,
	-- Gems are only checked against players every N frames in chunks (perf).
	CheckChunks = 2,
}

------------------------------------------------------------------------------------------
-- GOLD
------------------------------------------------------------------------------------------
Config.Gold = {
	FailureRetainBase = 0.35, -- owner: 0.35 (was 0.25), early defeats keep more gold
	FailureRetainPerStage = 0.15,
	FailureRetainCap = 0.85,
	-- Normal enemies give 1-3 gold to the player who killed them. KillGoldChance is how
	-- often a kill pays at all (1 = every kill; lower it if gold comes in too fast).
	MinPerKill = 1,
	MaxPerKill = 3,
	KillGoldChance = 0.25, -- owner: 0.25 (was 0.12)
	Elite = 15, -- extra gold from an elite's chest (on top of ChestGold) ...
	EliteStageScale = 0.25, -- ... the whole elite chest gold x (1 + this x (stage - 1)) on stages 1-2,
	-- then + EliteLateStageScale per stage from stage 3 on (owner OK 2026-10-04: stage 3+ only;
	-- was 0.25 like the early step, stages 1-2 unchanged)
	EliteLateStageScale = 0.05,
	Boss = 200, -- every living player gets this each time the Scorpion Queen dies
	ChestGoldMin = 15,
	ChestGoldMax = 40,
	WinBonus = 100, -- paid when a player leaves through an open portal (a win)
	StageClearBonus = 300, -- plus this per stage cleared, on that same return (owner: was 150)
	-- Survival gold: this much per whole minute survived (up to SurvivalMaxMinutes), paid at
	-- the end of every run straight to the save, outside the run purse and the loss rule.
	SurvivalPerMinute = 40,
	SurvivalMaxMinutes = 30,
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
--   Run gold is spent: what you earned THIS run (the RunGold counter, kept in the save's
--   RunEscrow ledger until the run settles: GoldSystem). Savings from earlier runs are
--   never touched.
--   Open: stand next to it and hold E / gamepad X / the on-screen button (touch).
------------------------------------------------------------------------------------------
Config.Chests = {
	SmallCount = { 10, 14 }, -- random count per stage (min, max)
	LargeCount = { 2, 3 },
	GoldenCount = 1,
	Cost = { Small = 25, Large = 60, Golden = 150 }, -- on stage 1
	CostExponent = 1.2, -- stage 2 = x2.3; with LateCostExponent stage 3 = x5.1, stage 4 = x8.9, stage 5 = x13.7
	-- From stage 3 on, prices are also x (stage / 2)^this; stages 1-2 unchanged. Shared with
	-- the Shrine of Chance (ItemData.StagePrice). Owner OK 2026-10-04 ("stage 3+ only").
	LateCostExponent = 0.75,
	-- hold E / gamepad X / the touch button this long to open a chest (tune in playtesting)
	HoldSeconds = { Small = 0.4, Large = 0.4, Golden = 0.4, Guarded = 0.4 },
	-- Rare reward showcases protect the chooser (pause solo) while their reel spins.
	-- Ordinary item rewards continue combat. The client ends a showcase when it is done
	-- (remote RewardClose); the server never waits longer than RewardPauseSeconds after a
	-- reward (+ RewardQueueSeconds for each one queued behind it), and never more than
	-- RewardPauseMax in a row however many rewards arrive.
	RewardPauseSeconds = 3.2,
	RewardQueueSeconds = 2.2,
	RewardPauseMax = 7,
	-- the case-opening reel (client UIBuilder): seconds of spin for the first reward and for
	-- each queued one, then the reveal; the reel lands on the server's item (tune in playtesting)
	Reel = { Spin = 1.3, QueuedSpin = 0.8, Reveal = 1.3, QueuedReveal = 1.0, Tiles = 26 },
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
-- GUARDED ALTAR (LootSystem.lua): an optional encounter drawn by Config.Encounters.
-- Hold its prompt deliberately; then a group of elite guards climbs out
-- around it. When every guard is dead the chest unlocks; opening it gives EVERY living
-- teammate one item (Config.Chests.Weights.Guarded). Guards drop gems, not elite chests.
------------------------------------------------------------------------------------------
Config.Guarded = {
	Guards = 2, -- + GuardsPerStage x stage + GuardsPerExtraPlayer x (players - 1) ...
	GuardsPerStage = 1,
	GuardsPerExtraPlayer = 1,
	MaxGuards = 8, -- ... at most this many
	SpawnRadius = { 12, 20 }, -- ring around the altar
	MinDistance = 90, -- studs from the spawn centre
}

------------------------------------------------------------------------------------------
-- LOST CARAVAN (CaravanEvent.lua): an optional encounter, at most one per stage. A stranded
-- supply cart away from the centre; stepping into its ring starts the defence: stay in the
-- ring HoldSeconds in total while waves climb out around it. Nobody in the ring for
-- LeaveGrace seconds in a row = the caravan is lost. Saved = every living teammate gets
-- one item (Weights) and run gold (Gold x (1 + GoldStageScale x (stage - 1))).
------------------------------------------------------------------------------------------
Config.Caravan = {
	-- (no Chance here: LootSystem.BuildStage draws the caravan as one of
	-- Config.Encounters.Types, Count per stage; the old per-stage Chance was never read)
	MinDistance = 75, -- studs from the spawn centre
	Clearance = 8, -- free radius for the cart
	ZoneRadius = 12, -- the ring to hold (studs)
	HoldSeconds = 20, -- seconds in the ring to save it (they add up; leaving pauses)
	LeaveGrace = 8, -- seconds the ring may stand empty before the caravan is lost ...
	LeaveGraceByStage = { 10 }, -- ... except on these stages (index = stage): stage 1 is gentler
	StartSeconds = 1, -- a living hero must stay this long in the ring to start the defence
	WaveEvery = 5, -- a wave on start and then every this many seconds of defence
	WaveBase = 4, -- + WavePerStage x stage + WavePerExtraPlayer x (players - 1) ...
	WavePerStage = 2,
	WavePerExtraPlayer = 3,
	WaveMax = 18, -- ... at most this many per wave
	WaveRadius = { 18, 26 }, -- ring around the cart
	LastWaveElite = true, -- the final wave brings one elite
	Gold = 60, -- per living teammate on stage 1 (before their gold multiplier)
	GoldStageScale = 0.35,
	Weights = { Common = 30, Uncommon = 60, Legendary = 10 }, -- the item each
}

------------------------------------------------------------------------------------------
-- EXPLORE features (docs/features/EXPLORE.md): secret rooms (4), the merchant cart (6),
-- the lost villager (8). Each is a placed encounter of the EncounterDirector (at most
-- Config.Encounters.Director.MaxActive placed encounters run per stage, so not every
-- stage gets every one). Switches: Config.Features.SecretRooms / Merchant / Rescue.
------------------------------------------------------------------------------------------
Config.Explore = {
	SecretRoom = {
		Weight = 1, -- director pick weight
		EdgeMargin = 20, -- the alcove centre stays this far inside the fence ...
		EdgeBand = 26, -- ... and at most EdgeMargin + EdgeBand from it (an arena edge)
		Width = 12, -- alcove inside, along the edge (studs)
		Depth = 9, -- alcove inside, toward the fence
		Wall = 1.6, -- wall thickness
		Height = 8, -- wall height (a jump is ~3.7 studs)
		HP = 70, -- the cracked wall's HP on stage 1 ...
		HPPerStage = 0.6, -- ... x (1 + this x (stage - 1))
		BreakRange = 16, -- studs from the wall: every weapon a player fires within this hits it
		MaxShots = 3, -- a weapon's projectile count counts up to this many hits per attack
		ChallengeChance = 0.4, -- else a free treasure chest (LootSystem.AddTreasure)
		PackBase = 2, -- elites in the challenge pack: PackBase + 1 per 2 stages ...
		PackMax = 4, -- ... at most this many
	},
	Merchant = {
		Weight = 1.5,
		Clearance = 7,
		InteractRadius = 10, -- studs from the cart: the shop panel shows
		Slots = 3, -- items per player
		-- rarity of each offered item (luck raises Uncommon / Legendary like chests)
		Weights = { Common = 55, Uncommon = 37, Legendary = 8 },
		-- an item costs what a chest of its rarity costs (Config.Chests.Cost through
		-- ItemData.StagePrice / PlayerPrice): no new price formula
		PriceChest = { Common = "Small", Uncommon = "Large", Legendary = "Golden" },
	},
	Rescue = {
		Weight = 1,
		MinDistance = 90, -- studs from the spawn centre
		Clearance = 6,
		FindRadius = 9, -- a living player this close starts the escort
		BehindDistance = 24, -- studs from the nearest hero: "Wait for me!" (once until it catches up)
		SayEvery = 6, -- seconds at least between two speech lines
		WalkSpeed = 15, -- studs/s (hero walk speed is about 16-18)
		FollowDistance = 5, -- stops this close to the hero it follows
		CatchUp = 12, -- stuck (not moving) this far behind for CatchUpSeconds: it hops to its hero (was 45: a rock 40 studs back left it stranded)
		CatchUpSeconds = 3,
		HP = 80, -- stage 1 ...
		HPPerStage = 0.4, -- ... x (1 + this x (stage - 1))
		AggroRadius = 14, -- enemies this close turn on the villager when it is nearer than any hero
		Radius = 1.4, -- body radius for enemy contact
		Gold = 60, -- fallback when no item can be granted (before gold multipliers) ...
		GoldStageScale = 0.35,
		Weights = { Common = 30, Uncommon = 60, Legendary = 10 }, -- the item for each living teammate
	},
}

------------------------------------------------------------------------------------------
-- ENEMIES
------------------------------------------------------------------------------------------
Config.Enemies = {
	MaxHazards = 48, -- cancelled warnings never deal damage
	EliteStageChanceGrowth = 0.12,
	StageHazards = { FirstStage = 3, Every = 22, Warn = 1.4, Radius = 5, Damage = 10, MaxTargets = 2 },
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
	ContactCooldown = 0.6, -- seconds between contact hits from the same enemy on the same player
	SeparationRadius = 1.1, -- multiplier on the two radii when pushing enemies apart
	SeparationCell = 8, -- studs: cell of EnemyAI's fine separation grid (perf only)
	-- Body sync (perf only, no gameplay effect): enemy bodies within BodySyncNear studs of
	-- a player move every frame, farther ones every BodyFarEvery frames (clients smooth).
	BodySyncNear = 30,
	BodyFarEvery = 3,
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

-- Elite affix icons (Config.Features.AffixIcons; client AffixIcons.lua, server AffixSight.lua,
-- shared AffixIconData.lua; docs/next/AFFIX_ICONS.md). A small badge over every elite shows
-- its affix (Swift: blue speed lines in a circle, Shielded: silver shield, Burning: orange
-- flame; the shape differs as well as the colour). SeenAffixes in the save remembers which
-- first-sight notices a player already got.
Config.AffixIcons = {
	Size = 20, -- badge size in pixels (18-22 on phones); far below an enemy health bar (64 px)
	Lift = 6.2, -- studs above the elite's body centre is half its height plus this
	UpdateHz = 8, -- client scan rate for new / dead elites
	PulseSeconds = 0.6, -- one half-beat of the soft pulse (none with Reduced effects)
	PulseScale = 1.12,
	MaxDistance = 200, -- the badge is not drawn farther than this many studs from the camera
	SightRange = 60, -- server: an elite this close (studs) to a player counts as met
	SightEvery = 0.5, -- server: seconds between the first-sight checks
}

------------------------------------------------------------------------------------------
-- DIFFICULTY SCALING (tier = floor(minutes))
------------------------------------------------------------------------------------------
Config.Difficulty = {
	HPPerMinute = 0.12, -- enemy HP x(1 + tier * this)
	SpeedPerMinute = 0.02, -- enemy speed x(1 + tier * this) ...
	SpeedCap = 1.3, -- ... capped here
	DamagePerMinute = 0.045, -- enemy damage x(1 + tier * this)
	-- Live-enemy target and burst size multiplier by player count (index = players).
	PlayerCountMult = { 1, 1.6, 2.1, 2.5 },
	-- Enemy HP multiplier per extra player.
	HPPerExtraPlayer = 0.25,
	-- HP and damage stop growing with time after this many minutes (long stage runs lean
	-- on the per-stage multipliers in Config.Stages instead).
	-- 16 (was 12; overhaul 2026-10-04, docs/overhaul/BALANCE_TUNE.md): the cap was reached
	-- during stage 3, so stages 4-5 went soft. Stages 1-3 end before minute 12 in econ-sim,
	-- so they are unchanged; stage 5 normal enemies get up to x1.2 HP and x1.12 damage
	-- (Endless past stage 5: the same constant step, then its own per-stage growth).
	MaxTier = 16,
}

------------------------------------------------------------------------------------------
-- SPAWNING
------------------------------------------------------------------------------------------
Config.Spawn = {
	OpeningSeconds = 60,
	OpeningMult = 0.65,
	StageProgressionSeconds = 120,
	-- The spawn-table minute (live target and enemy mix) on stage n stays within
	-- [(n-1) x StageProgressionSeconds, that + StageRowSpan] whatever the run clock says.
	-- Before, a slow stage 1 (a 4-minute boss fight) put stage 2 on the 6-7 minute rows:
	-- ~90 enemies alive on arrival, three times stage 1 (owner: "round two ... mobs just keep
	-- spawning"). Enemy HP / damage still follow the run clock (Config.Difficulty).
	StageRowSpan = 180,
	TickSeconds = 0.4, -- how often the spawner tops up toward the target count
	MaxPerTick = 8,
	-- "ScreenEdge": spawn on a ring just off-screen around a random player, clamped
	--               inside the fence (reads as "from the edges" on a phone).
	-- "ArenaEdge":  spawn right inside the fence on the side nearest a random player.
	Mode = "ScreenEdge",
	ScreenRadius = 72,
	ScreenRadiusJitter = 10,
	MiniWaveBaseCount = 14,
	MiniWavePerMinute = 3,
}

------------------------------------------------------------------------------------------
-- WAVES (EnemySpawner stepWaves; owner: "ALL the enemies come in waves. Wave 1 is easy,
-- wave 2 a little harder, wave 3 even harder")
--   While exploring nothing spawns between waves. Wave N (counted across the whole run:
--   stage 2 goes on from where stage 1 ended) comes after a breather, is announced (big
--   centre "WAVE N" banner, horn, red glow on the screen edge it comes from; the stage pill
--   says "WAVE N" / "WAVE N IN 0:03") and pours in over BurstSeconds from 1 side, 2 from
--   SidesAtWave[1], 3 from SidesAtWave[2]. The next breather starts when at most
--   ClearShare of the wave is alive or after MaxSeconds (no stalling). The breather waits
--   while someone stands at the portal. Boss fights keep their own crowd
--   (Config.Stages.BossMinionShare), the surge replaces waves.
--   size  = (Base + PerWave x (N - 1), PerWaveLate past LateFromWave) x Config.Difficulty.PlayerCountMult x the stage
--           spawn multiplier (Horde, Endless) x BigMult on every BigEvery-th wave x
--           PressureMult once the swarm pressure warning is up
--   mix   = EnemyData.SpawnTable row at (N - 1) x RowSecondsPerWave seconds (never below
--           the stage's first row), one main type per side + MixShare from the row; wasps only
--           from BeesFromWave (smaller, Config.Pacing.WaveCountMult)
--   HP    wave members x(1 + HPPerWave x (N - 1)) on top of the run-clock and stage scaling
--   elites lead a wave from EliteFromWave on (EliteChance, always on big waves), one more
--           every ElitePerWaves waves, at most EliteMax
--   never shrink: a normal wave is at least the last normal one (per player-count density);
--           a big wave is the bump on top. Elite Surge (RunModifiers.EliteChanceMult) raises
--           the elite chance and adds one elite per wave.
--   announce: the big "WAVE N" banner + horn only for wave 1, big waves and a stage's first
--           wave (SwarmState WaveLoud); other waves get one toast line, the pill and the glow.
--   Boss-fight and surge kills also get XPMult (waves on), so level-ups stay even.
--   SwarmState: Wave, WaveSeq, WaveBig, WaveLoud, WaveSides, WaveAngle, WaveNext (run time the next
--   wave starts, 0 = none), WaveLeft (enemies of the current wave left).
--   Enabled = false: the old continuous spawning with ring mini-waves.
------------------------------------------------------------------------------------------
Config.Waves = {
	Enabled = true,
	FirstDelay = 4, -- stage 1: wave 1 comes right after the stage card
	StageStartDelay = 6, -- later stages, after the travel and the stage card
	BreatherSeconds = 3,
	PortalHoldSeconds = 3, -- the breather stays at least this long while someone is at the portal
	ClearShare = 0.1, -- the next breather starts at max(ClearMin, ClearShare x size) left
	ClearMin = 3,
	MaxSeconds = 30,
	-- gem XP of wave enemies x this: waves come in bursts with breathers, so fewer enemies
	-- spawn than with the old continuous top-up; this keeps the level-up pace (pacing-sim)
	XPMult = 1.8,
	GoldChanceMult = 1.5, -- the same for the kill-gold chance (Config.Gold.KillGoldChance)
	BurstSeconds = 4.5,
	MaxPerStep = 6, -- enemies spawned per frame at most while a wave pours in (perf)
	Base = 12,
	PerWave = 3,
	-- past LateFromWave each wave adds PerWaveLate instead (late waves still grow, slower)
	LateFromWave = 8,
	PerWaveLate = 1.5,
	-- wave members' HP x(1 + HPPerWave x (N - 1)) on top of the run-clock / stage scaling
	HPPerWave = 0.01,
	BigEvery = 5,
	BigMult = 1.35,
	RowSecondsPerWave = 15,
	BeesFromWave = 4,
	SidesAtWave = { 4, 9 },
	ArcRadians = 0.6, -- each side spreads this far either way
	EliteFromWave = 4,
	EliteChance = 0.5,
	ElitePerWaves = 8,
	EliteMax = 3,
	-- a share of each side is mixed from the whole spawn row (Spitters within
	-- Config.Enemies.MaxLiveRanged, Healers / Burrowers within their caps), from MixFromWave
	MixShare = 0.25,
	-- at most Base + PerWave x (N - 1) of these alive per wave, counting the ones left from
	-- earlier waves (the rest is re-picked): piled-up Brutes made stage 3 the hardest stage
	TypeCap = { Brute = { Base = 1, PerWave = 0.2 }, Bomber = { Base = 4, PerWave = 0.5 } },
	MixFromWave = 3,
	-- swarm pressure (Config.Stages.Pressure, SwarmWarn 1 / 2): waves x this
	PressureMult = { 1.15, 1.35 },
	-- from NestFromStage every NestEveryWaves-th wave (not a big one) plants a Nest
	-- (Config.Pacing.Nests caps); the old timed nests are off while waves are on
	NestFromStage = 2,
	NestEveryWaves = 4,
}

--[[
	FAST START (switch Config.Features.FastStart, docs/next/FAST_START.md): the first Waves
	waves of the run, while it is on stage 1, come quicker and a little bigger (EnemySpawner
	FastStartMult). Each value multiplies its Config.Waves number for those waves only:
	  FirstDelayMult  FirstDelay before wave 1
	  BurstMult       BurstSeconds (the wave pours in faster)
	  MaxSecondsMult  MaxSeconds (the wave's time cap)
	  BreatherMult    BreatherSeconds after waves 1..Waves
	  SizeMult        the wave's size (after the never-shrink floor is recorded, so wave
	                  Waves + 1 and later are sized exactly as before)
	  ClearShare      replaces Config.Waves.ClearShare (the next breather starts sooner)
	Stage 2+ and every later wave are unchanged. Config.FirstRun's gentle waves still apply
	on top in an account's first run.
]]
-- Tuned with fast-start-regression's measure mode (8 seeds, docs/next/FAST_START.md): waves
-- 1-3 done ~27% sooner, XP in the first 90 s +24-33%, first level-up ~20 s (was ~24 s),
-- stage-1 damage and would-be deaths unchanged within noise. FirstDelay and the pour-in stay
-- as they were (shortening them pushed the first level-up under 20 s).
Config.FastStart = {
	Waves = 3,
	FirstDelayMult = 1,
	BurstMult = 1,
	MaxSecondsMult = 0.35, -- 30 s -> 10.5 s; leftovers keep fighting alongside the next wave
	BreatherMult = 0.34, -- 3 s -> ~1 s
	SizeMult = 1.2, -- 12 / 15 / 18 -> 14 / 18 / 22 (solo)
	ClearShare = 0.4, -- the next breather starts with 40 % of the wave left (plain 0.1, at least 3)
	FirstLevelUpBy = 30, -- fast-start-regression: the first level-up comes by this run time
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
	--[[
		Teachable first boss (BossAI): applies only when the boss fight is on one of Stages
		and the run's difficulty is Difficulty (the base one), to the bosses listed in Bosses.
		  Opening       the first Count attacks are Attack (the simplest read), then the
		                normal cycle introduces the others one by one
		  SafeRecover   after these attacks she is dizzy (no contact damage) for at least
		                Seconds, so melee heroes can punish safely
		  StingerGapWidth  directions left out per stinger gap in phase 1 (BossData's
		                GapWidth is 3 = 72 degrees between the lanes beside a gap; 4 = 90)
	]]
	Intro = {
		Enabled = true,
		Stages = { 1 },
		Difficulty = "Standard",
		Bosses = {
			ScorpionQueen = {
				Opening = { Attack = "Charge", Count = 2 },
				SafeRecover = { Attacks = { VenomBurst = true, StingerRing = true }, Seconds = 0.8 },
				StingerGapWidth = 4,
			},
		},
	},
	--[[
		Weapon targeting near a boss (WeaponSystem.nearestEnemies, single-target weapons:
		Magic Orb, Longbow, Crossbow, Soul Bolt, Sling, Spirit Wisps). With PreferBoss on, a
		targetable boss whose body edge is inside the weapon's range AND within PreferWithin
		studs of the hero is aimed at first (a multi-shot weapon still sends its other shots
		at the nearest enemies). Range checks use the target's body edge, never its centre.
		ImmuneCueSeconds: a hero hitting an invulnerable boss (entrance, burrowed) sees a small
		"IMMUNE" cue at most this often.
	]]
	Targeting = {
		PreferBoss = true,
		PreferWithin = 20,
		ImmuneCueSeconds = 1.0,
	},
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
	RunStartCalm = 12,
	StageStartCalm = 10,
	CalmMult = 0.35,
	BuildUpFrom = 0.85,
	BuildUpTo = 1.1,
	MiniWaveLull = 8,
	LullMult = 0.55,
	IntroGroup = 3,
	EliteFirst = 210,
	EliteEvery = 165,
	EliteMinTime = 60,
	EliteTypes = { "Slime", "Skeleton", "Brute", "Ghost", "Spitter" }, -- scheduled elites (never a bomb tick)
	-- Wave groups by type: no group of this type before WaveMinTime seconds of run time
	-- (old mini-waves) / Config.Waves.BeesFromWave (waves); Mites instead. Its group is
	-- WaveCountMult times the usual size. Wasps are fast flyers: a full ring of them in the
	-- first minute was the "too many bees" start (pacing-sim: up to 22 alive in minute 1).
	WaveMinTime = { Bat = 150 },
	-- Bombers / Brutes: a whole side of them was most of the damage in pacing-sim waves
	WaveCountMult = { Bat = 0.6, Bomber = 0.5, Brute = 0.5 },
	-- smaller intro groups for the later creatures (Healer from 6:00, Burrower from 7:00
	-- in EnemyData.SpawnTable)
	IntroGroupOf = { Healer = 2, Burrower = 2 },
	-- Nests (EnemyData.Nest): stationary spawners on later stages / late in stage 1. The
	-- first one comes FirstStageTime seconds into a stage (stage 1: not before
	-- Stage1RunTime of run time), then every Every seconds, at most PerStage (+1 from
	-- stage 3) per stage and MaxAlive at once, Distance studs from a living player.
	-- Only while exploring (never during the boss fight or the surge).
	Nests = {
		Stage1RunTime = 480,
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
	Landscape phones (short side under PhoneShortSide points, the same rule as the compact
	UI) use RunDistance x PhoneDistanceMult (0.85 = 65.9 studs): the hero and enemies read
	about 18% bigger on a small screen (owner brief, 2026-10-07). Visible ground there:
	  19.5:9 / 1108x512 phone  113 x 70 (was 133 x 82)
	  16:9 small phone 667x375  93 x 70 (was 109 x 82)
	Enemies still spawn off-screen (ScreenRadius 72 > half the width), the amber wave edge
	glow (StageUI) and the minimap boss pin still point at what is coming. Portrait phones
	keep PortraitDistanceMult only.
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
	PhoneDistanceMult = 0.85, -- landscape phones: a closer run camera (see the note above)
	PhoneShortSide = 560, -- viewport short side (points) below which a screen counts as a phone
	SpectatePanSeconds = 0.4, -- glide to the next teammate when the spectated one falls
	ShakeScale = 1, -- multiplies every screen shake (0 = off)
	ShakeMax = 0.6, -- studs; shakes stay small
	KickMax = 4, -- studs: the most a camera punch (CombatFx big kills, evolution) pulls in
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
	-- Enemy level of detail (src/client/EnemyRenderer.lua). No enemy ever shows its plain
	-- server body. Enemies outside the camera view (plus CullMargin studs) have no model and
	-- cost nothing. Of the enemies ON SCREEN, the nearest MaxDetailedEnemies get the full
	-- animated model; the rest get a low-detail variant (the model's LowDetailParts largest
	-- pieces in their own colours, posed rigidly). The boss, elites and static / support
	-- creatures are always full. (Was 110 counted over all live enemies, the rest drawn as
	-- plain recoloured bodies.)
	MaxDetailedEnemies = 80,
	-- ... and on a device that can't keep up (frames slower than 40 fps for a while) the
	-- budget steps down toward this (the rest low-detail), and back up once frames are fast.
	MinDetailedEnemies = 40,
	LowDetailParts = 4, -- pieces in a low-detail model (a mirrored pair counts as two)
	CullMargin = 6, -- studs past the screen edge an enemy still gets its model
	-- When more enemies are on screen than this, only the nearest this many update their
	-- pose every frame; the others (and every low-detail model) every 2nd frame.
	FullRateEnemies = 30,
	-- regular enemies' mesh pieces never cast shadows (bosses keep theirs): a hundred
	-- moving shadow casters is the single biggest render cost in a big swarm
	EnemyShadows = false,
	-- Effect budget: pooled effect parts animating at once (sparks, dust, rings, bolts).
	-- Cosmetic effects past it are skipped; boss warnings and player events never are.
	MaxEffectParts = 220,
	MaxTrails = 40, -- projectile trails at once (more projectiles fly without one)
	-- Settings > Reduced effects (accessibility): the effect and trail budgets above are
	-- multiplied by this, and screen flashes (hurt pulse, XP flash) are switched off.
	ReducedEffectsBudget = 0.4,
	-- Combat "juice" (src/client/CombatFx.lua): impact stars, kill shards, elite / boss kill
	-- bursts, level-up pillar, evolution flash, pickup sparkles, crit stars, boss phase
	-- edge flash. Its own pool, separate from MaxEffectParts above.
	CombatFx = {
		MaxParts = 110, -- juice parts alive at once; new effects past it are skipped
		PartsPerSecond = 320, -- spawn budget refill rate (token bucket)
		Burst = 48, -- bucket size: the most parts one frame can start
		MidDistance = 45, -- studs from the hero: beyond this, effects use half their parts
		FarDistance = 85, -- beyond this, only elite / boss kills still play
		SlowFrame = 1 / 40, -- smoothed frame time past this halves the budget (past 1.6x: quarter)
		BigKillSize = 4.6, -- death size (studs, the diameter) from which a kill gets the big burst (brutes, elites)
		HugeKillSize = 9.5, -- boss / large elite: biggest burst + camera kick
		ReducedBudget = 0.25, -- Reduced effects: budget share; only milestone effects play
	},
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
	-- Ground detail (src/client/GroundDetail.lua): small grass tufts, flowers, clover /
	-- moss discs and pebbles drawn by each client only in the camera's footprint and
	-- recycled as it moves (nothing replicates). Pooled one-part pieces, anchored, no
	-- collision / queries / shadows. The cell grid and what each cell holds are fixed by
	-- the arena's seed, so every client sees the same floor.
	GroundDetail = {
		MaxParts = 300, -- pool size on desktop / console
		MaxPartsTouch = 170, -- phones and tablets
		ReducedShare = 0.5, -- Settings > Reduced effects: this share of the pool
		Cell = 8, -- studs; a cell holds 0-4 pieces
		UpdateHz = 8, -- how often the footprint is re-checked
		ClearingDensity = 0.4, -- density share inside the spawn clearing (combat stays readable)
		EdgeBoost = 1.7, -- density near obstacles and path edges (clutter gathers there)
		OuterDensity = 0.55, -- density share on the outer ground past the boundary walls
	},
}

------------------------------------------------------------------------------------------
-- DATA STORE
------------------------------------------------------------------------------------------
Config.Data = {
	StoreName = "SwarmPlayerData",
	StudioStoreName = "SwarmPlayerData_Studio", -- used instead in Studio: tests never touch live saves
	KeyPrefix = "Player_",
	SchemaVersion = 7, -- bump and add a migration step in DataService when the save shape changes
	AutoSaveSeconds = 60,
	-- A session lock is considered dead (the server crashed) if it wasn't refreshed for
	-- this long. Must be well above AutoSaveSeconds.
	LockStaleSeconds = 200,
	LoadAttempts = 6,
	LoadRetryDelay = 4,
	SaveAttempts = 4,
	MaxStoredPurchaseIds = 150,
	-- size caps for the additive feature fields (DataService.Migrate trims anything above)
	Caps = {
		IdLength = 64, -- longest id string kept in a set / list
		SetEntries = 400, -- ids per owned / seen set (cosmetics, titles, collection ...)
		Sigils = 64, -- owned Sigils
		SigilSlots = 2, -- equipped Sigils
		SeasonClaims = 200, -- claimed season tiers
		Presets = 12, -- build presets (one per hero; HEROPOWER raised 6 -> 12 for 8 + 3 heroes)
		PresetPicks = 12, -- weapon / passive ids in one preset
		WeaponMastery = 128, -- weapons with a mastery count
	},
}

------------------------------------------------------------------------------------------
-- MONETIZATION
-- Paste your real IDs here. 0 = not configured (the shop hides/greys that item).
------------------------------------------------------------------------------------------
Config.Monetization = {
	GamePasses = {
		StarterPack = 2008346507, -- +25% gold forever, Gold Trim skin for every character
		VIP = 2006432550, -- +1 reroll per run, [VIP] chat tag, lobby crown
		DoubleGold = 2005460551, -- 2x gold
	},
	Products = {
		Gold500 = 3716061041,
		Gold1500 = 3716061205,
		Gold5000 = 3716061092,
		Revive = 3716061270, -- mid-run revive, offered once per run on death
	},
	ProductGold = { Gold500 = 500, Gold1500 = 1500, Gold5000 = 5000 },
	-- Cosmetic developer products for the store (CosmeticData / StoreCatalog Store keys
	-- point here; docs/features/STORE.md). 0 = not created yet: the shop shows "Coming
	-- soon". Each one gives one look (data.Cosmetics.Owned) and can be gifted.
	Cosmetics = {
		Trail_Ember = 0,
		Trail_Frost = 0,
		Trail_Royal = 0,
		Burst_Confetti = 0,
		Burst_Void = 0,
		Burst_Frost = 0,
		Pet_Fox = 0,
		Pet_Owl = 0,
		Pet_Drake = 0,
		Emote_Cheer = 0,
		Emote_Flex = 0,
		Plate_Gold = 0,
		Plate_Ember = 0,
		Dais_Obsidian = 0,
		Dais_Sunfire = 0,
	},
	-- Cosmetic game passes: Supporter = one-time pass (badge, glowing nameplate, lobby
	-- banner; looks only). 0 = not created yet.
	CosmeticPasses = {
		Supporter = 0,
	},
	-- HEROES (feature 11): early unlock of the three heroes that are also sold for gold
	-- (CharacterData StoreKey "HeroUnlocks.<Id>"). Developer products, 0 = not created yet:
	-- the Store shows "Coming soon". The owner creates them and pastes the ids; STORE wires
	-- the purchase (it sets OwnedCharacters[id] = true, the same flag gold buys).
	HeroUnlocks = { Archer = 0, Bard = 0, Golem = 0 },
	-- STARTER BUNDLE (Config.Features.StarterBundle; docs/next/STARTER_BUNDLE.md): one developer
	-- product, once per account (Pioneer Knight skin + gold + "Pioneer" title, Config.StarterBundle).
	-- 0 = hidden: the owner creates the product, sets its price on Roblox and pastes the id here.
	StarterBundle = 0,
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

-- The cosmetic store (Config.Features.Store; docs/features/STORE.md). Looks only.
Config.Store = {
	GiftSeconds = 300, -- a gift target is kept this long while the Roblox prompt is open
	EmoteCooldown = 3, -- seconds between two emotes of one player
	EmoteSeconds = 2.2, -- how long an emote shows over the hero
	MaxPets = 8, -- pets drawn at once on one screen (nearest first)
	PetRange = 150, -- studs: pets / trails / plates further from the camera are not drawn
	PlateRange = 70, -- studs: nameplates show within this distance
}

-- Starter bundle (Config.Features.StarterBundle; docs/next/STARTER_BUNDLE.md). The product id
-- is Config.Monetization.StarterBundle; its price only ever comes from GetProductInfo.
Config.StarterBundle = {
	Gold = 2000, -- gold added to the save by the purchase
	Skin = "Knight_Pioneer", -- CharacterData skin (Pass = "StarterBundle"); PENDING owner OK
	Title = "Title_Pioneer", -- MetaData title granted with it
	OfferDays = 7, -- the home card shows for this many days after the save's FirstJoin
}

-- Roblox group bonus (Config.Features.GroupBonus; docs/next/GROUP_BONUS.md). Id = 0: off
-- until the owner gives the group id. Members get GoldBonus of the gold a run pays into
-- the lobby (kept + survival, at settlement; never in-run chest gold), at most GoldCap.
Config.Group = {
	Id = 0,
	GoldBonus = 0.10,
	GoldCap = 500,
	Title = "Title_Group Member", -- worn while a member (MetaData)
}

-- Invite rewards (Config.Features.InviteRewards; docs/next/INVITE_REWARDS.md). Cosmetic only.
Config.Invite = {
	Badge = "Plate_Friend", -- nameplate for a new player who joined through an invite
	Title = "Title_Recruiter", -- the inviter's title (first credited friend)
	Trail = "Trail_Recruiter", -- the inviter's trail at TrailAt credited friends
	TrailAt = 3,
	RunsNeeded = 1, -- the new player must finish this many runs before the inviter is credited
	MaxCredits = 200, -- credited friends kept in the inviter's save (the set is capped)
	StoreName = "SwarmInvites", -- pending credits, keyed by the inviter (Studio: StoreName .. "_Studio")
	PollSeconds = 300, -- an online inviter's pending credits are checked this often
}

------------------------------------------------------------------------------------------
-- AUDIO
--   "SWARM SFX" = original effects synthesized for this game (tools/synth_sfx.py), uploaded
--                 by the owner's account (user 20194281) with tools/upload_audio.py and
--                 approved by Roblox moderation (art/audio/uploaded_ids.json).
--   built-in    = rbxasset://sounds/... files that ship with every Roblox client.
--   "APMOfficial" (7462718749) = the APM Music library Roblox licenses for free use in any
--                 Roblox experience (the Creator Store music catalogue).
-- Owner checklist, previous ids and how to swap a sound: docs/AUDIO.md.
------------------------------------------------------------------------------------------
--[[
	Sound effects and music. Volume is the sound's own volume; the player's Music / Effects
	sliders scale everything on top (their meaning never changes here).

	Fields: Category (Config.Audio.Categories: voice limit, priority, ducking), MinGap (s
	between two plays of this sound), Pitch (base playback speed) and PitchVar (random
	+/- around it, so repeats don't sound mechanical), Steps (semitone offsets: each play
	picks a note of this scale instead) with Climb (seconds: quick repeats walk up the
	scale, a pause resets it), DuckMusic (seconds the music dips under this sound),
	World = played at a world position (3D, quieter far away) when the caller gives one.

	Mixing goal (owner feedback: "less annoying"): the frequent sounds (hits, deaths, gems,
	coins, clicks) are quiet, soft-timbred and rate-limited; the rare cues that carry
	information (hurt, level-up, chest, boss, warnings) stay clear above them.
]]
Config.Sounds = {
	-- combat (lowest priority: there is always a lot of it; VFX plays Hit once per batch).
	-- Soft, low-mid and short so a swarm reads as a murmur; pitch spread kills repetition.
	Hit = { Id = "rbxassetid://132528923449580", Volume = 0.1, Category = "Combat", MinGap = 0.09, PitchVar = 0.15 }, -- SWARM SFX Hit: muted thump
	EnemyDeath = { Id = "rbxassetid://121753247942951", Volume = 0.12, Category = "Combat", MinGap = 0.1, PitchVar = 0.18 }, -- SWARM SFX EnemyDeath: soft poof
	Lightning = { Id = "rbxassetid://74962400988388", Volume = 0.22, Category = "Combat", MinGap = 0.2, PitchVar = 0.12 }, -- SWARM SFX Lightning: crackle
	Explosion = { Id = "rbxassetid://121247904139587", Volume = 0.15, Category = "Combat", MinGap = 0.25, PitchVar = 0.1, World = true }, -- SWARM SFX Explosion
	-- the local hero's own attacks and body
	Swing = { Id = "rbxassetid://110381677719056", Volume = 0.09, Category = "Player", MinGap = 0.18, PitchVar = 0.12 }, -- SWARM SFX Swing: airy whoosh
	Throw = { Id = "rbxassetid://110381677719056", Volume = 0.06, Category = "Player", MinGap = 0.25, Pitch = 1.25, PitchVar = 0.1 }, -- SWARM SFX Swing, higher
	Hurt = { Id = "rbxassetid://103629944065626", Volume = 0.32, Category = "Player", MinGap = 0.3, PitchVar = 0.06 }, -- SWARM SFX Hurt: punch + grunt
	Heartbeat = { Id = "rbxassetid://106832514643917", Volume = 0.16, Category = "Player", Priority = 5, MinGap = 0.4, PitchVar = 0 }, -- SWARM SFX Heartbeat: lub-dub
	Death = { Id = "rbxassetid://106619962538253", Volume = 0.36, Category = "Player", PitchVar = 0, DuckMusic = 2.4 }, -- SWARM SFX Death: falling minor chord
	LevelUp = { Id = "rbxassetid://131826585081742", Volume = 0.46, Category = "Player", MinGap = 0.4, PitchVar = 0, DuckMusic = 1.4 }, -- SWARM SFX LevelUp: C-major arpeggio
	Revive = { Id = "rbxassetid://97435297484172", Volume = 0.36, Category = "Player", MinGap = 0.4, PitchVar = 0, DuckMusic = 1.6 }, -- SWARM SFX Revive: A-major rise
	-- combat juice (CombatFx)
	BigKill = { Id = "rbxassetid://79432466085613", Volume = 0.16, Category = "Combat", MinGap = 0.35, PitchVar = 0.06 }, -- SWARM SFX BigKill: deep impact
	Evolve = { Id = "rbxassetid://93333085469531", Volume = 0.43, Category = "Player", MinGap = 0.6, PitchVar = 0, DuckMusic = 2.2 }, -- SWARM SFX Evolve: shimmer swell
	-- pickups and rewards. Gems climb a pentatonic scale while you keep collecting.
	GemPickup = { Id = "rbxassetid://111456984593913", Volume = 0.07, Category = "Pickup", MinGap = 0.07, Pitch = 0.5, PitchVar = 0.008,
		Steps = { 0, 2, 4, 7, 9, 12 }, Climb = 0.35 }, -- SWARM SFX GemPickup: crystal tink
	Coin = { Id = "rbxassetid://86606172414417", Volume = 0.11, Category = "Pickup", MinGap = 0.12, PitchVar = 0.01, Steps = { 0, 2, 4 } }, -- SWARM SFX Coin: two-note ding
	Chest = { Id = "rbxassetid://109507162178062", Volume = 0.6, Category = "Pickup", MinGap = 0.25, PitchVar = 0, DuckMusic = 1.6 }, -- SWARM SFX Chest: lid + treasure sparkle
	Item = { Id = "rbxassetid://105588297309015", Volume = 0.2, Category = "Pickup", MinGap = 0.2, PitchVar = 0.02 }, -- SWARM SFX Item: rising chime
	Shrine = { Id = "rbxassetid://106727264178055", Volume = 0.24, Category = "Pickup", MinGap = 0.3, PitchVar = 0, DuckMusic = 1.6 }, -- SWARM SFX Shrine: mystic chord
	-- the stage portal is revealed (client StageUI, with the banner)
	PortalAppear = { Id = "rbxassetid://72802301491749", Volume = 0.52, Category = "UI", MinGap = 1, PitchVar = 0, DuckMusic = 2.6 }, -- SWARM SFX PortalAppear: rising whoosh + drone
	Victory = { Id = "rbxassetid://71641610011777", Volume = 0.55, Category = "UI", PitchVar = 0, DuckMusic = 3 }, -- SWARM SFX Victory: horn fanfare
	-- warnings: telegraphs that ask the player to move (never dropped for combat noise)
	FuseTick = { Id = "rbxasset://sounds/clickfast.wav", Volume = 0.35, Category = "Warning", MinGap = 0.09, Pitch = 1.6, PitchVar = 0.03, World = true },
	SpitterWindup = { Id = "rbxasset://sounds/splat.wav", Volume = 0.26, Category = "Warning", MinGap = 0.25, Pitch = 1.3, PitchVar = 0.08, World = true },
	Lunge = { Id = "rbxasset://sounds/unsheath.wav", Volume = 0.3, Category = "Warning", MinGap = 0.2, Pitch = 0.8, PitchVar = 0.06, World = true },
	-- the Queen
	BossRoar = { Id = "rbxassetid://135802539734782", Volume = 0.5, Category = "Boss", MinGap = 1, PitchVar = 0.04, DuckMusic = 2.2 }, -- SWARM SFX BossRoar: growl + sub hit
	WaveHorn = { Id = "rbxassetid://135802539734782", Volume = 0.42, Category = "UI", Priority = 5, MinGap = 2, Pitch = 1.35, PitchVar = 0, DuckMusic = 1.2 }, -- the BossRoar sound pitched up: a wave is coming (StageUI)
	BossWarn = { Id = "rbxassetid://113336786346138", Volume = 0.35, Category = "Boss", MinGap = 0.4, Pitch = 1.1, PitchVar = 0.04, World = true }, -- SWARM SFX BossWhoosh
	BossSummon = { Id = "rbxasset://sounds/splat.wav", Volume = 0.4, Category = "Boss", MinGap = 0.4, Pitch = 0.6, PitchVar = 0.05, World = true },
	-- the rotating bosses (Telegraphs plays these for their new warning shapes)
	BossWave = { Id = "rbxassetid://113336786346138", Volume = 0.38, Category = "Boss", MinGap = 0.5, Pitch = 0.9, PitchVar = 0.04, World = true }, -- SWARM SFX BossWhoosh
	BossGust = { Id = "rbxassetid://113336786346138", Volume = 0.38, Category = "Boss", MinGap = 0.5, Pitch = 0.75, PitchVar = 0.03, World = true }, -- SWARM SFX BossWhoosh, lower
	BossPound = { Id = "rbxassetid://114145211136875", Volume = 0.26, Category = "Boss", MinGap = 0.3, PitchVar = 0.05, World = true }, -- SWARM SFX BossSlam: ground pound
	BossMine = { Id = "rbxasset://sounds/clickfast.wav", Volume = 0.22, Category = "Warning", MinGap = 0.15, Pitch = 1.2, PitchVar = 0.08, World = true },
	BossEmerge = { Id = "rbxassetid://114145211136875", Volume = 0.22, Category = "Boss", MinGap = 0.4, Pitch = 0.8, PitchVar = 0.05, World = true }, -- SWARM SFX BossSlam, lower
	BossBanner = { Id = "rbxasset://sounds/unsheath.wav", Volume = 0.45, Category = "Boss", MinGap = 0.5, Pitch = 0.6, PitchVar = 0.03, World = true },
	BurrowWarn = { Id = "rbxasset://sounds/splat.wav", Volume = 0.26, Category = "Warning", MinGap = 0.25, Pitch = 0.7, PitchVar = 0.08, World = true },
	-- an elite spawns (server Fx batch name "EliteSpawn"): the BossWhoosh id, low and short
	EliteSpawn = { Id = "rbxassetid://113336786346138", Volume = 0.3, Category = "Warning", MinGap = 1.2, Pitch = 0.85, PitchVar = 0.03, DuckMusic = 0.8 }, -- SWARM SFX BossWhoosh
	HealPulse = { Id = "rbxassetid://133320151991833", Volume = 0.06, Category = "Combat", MinGap = 0.4, Pitch = 0.75, PitchVar = 0.05, World = true }, -- SWARM SFX Tip, lower
	-- interface
	Click = { Id = "rbxassetid://130072904039232", Volume = 0.38, Category = "UI", MinGap = 0.06, PitchVar = 0.04 }, -- SWARM SFX Click: soft wooden tick
	Toggle = { Id = "rbxassetid://78864064038524", Volume = 0.27, Category = "UI", MinGap = 0.06, PitchVar = 0.02 }, -- SWARM SFX Toggle: two-tone tick
	Tip = { Id = "rbxassetid://133320151991833", Volume = 0.11, Category = "UI", MinGap = 0.6, PitchVar = 0 }, -- SWARM SFX Tip: two soft bells
	ReelTick = { Id = "rbxassetid://111197240897473", Volume = 0.12, Category = "UI", MinGap = 0.04, PitchVar = 0.05 }, -- SWARM SFX ReelTick
	-- UI states (existing ids re-pitched; callers: UIKit.Sound / audio.Play by name)
	CardAppear = { Id = "rbxassetid://105588297309015", Volume = 0.1, Category = "UI", MinGap = 0.25, Pitch = 1.3, PitchVar = 0.02 }, -- compact reward card slides in (SWARM SFX Item, higher, quiet)
	ChoiceOpen = { Id = "rbxassetid://133320151991833", Volume = 0.2, Category = "UI", MinGap = 0.5, Pitch = 1.15, PitchVar = 0, DuckMusic = 0.6 }, -- upgrade choice opens (SWARM SFX Tip)
	ChoicePick = { Id = "rbxassetid://78864064038524", Volume = 0.3, Category = "UI", MinGap = 0.15, Pitch = 1.2, PitchVar = 0.02 }, -- a card is picked (SWARM SFX Toggle)
	ResultsLose = { Id = "rbxassetid://106619962538253", Volume = 0.3, Category = "UI", MinGap = 1, Pitch = 0.9, PitchVar = 0, DuckMusic = 2.4 }, -- results after a loss (SWARM SFX Death, softer)
	PartyJoin = { Id = "rbxassetid://105588297309015", Volume = 0.22, Category = "UI", MinGap = 0.4, Pitch = 0.9, PitchVar = 0.02 }, -- a duo partner joins the menu party (SWARM SFX Item)
	TitleStart = { Id = "rbxassetid://130072904039232", Volume = 0.34, Category = "UI", MinGap = 0.3, Pitch = 0.8, PitchVar = 0.02 }, -- PLAY on the title (SWARM SFX Click, deeper)
	-- music (APMOfficial, free in any Roblox experience; looped, crossfaded and ducked under
	-- big moments by Audio.lua). Swap: paste another Creator Store id as "rbxassetid://<id>"
	-- (docs/AUDIO.md lists candidates to audition); "" = silent.
	LobbyMusic = { Id = "rbxassetid://1836939228", Volume = 0.26, Category = "Music" }, -- Celtic Adventures, Bob Bradley, 2:16
	BattleMusic = { Id = "rbxassetid://9047425352", Volume = 0.22, Category = "Music" }, -- Drums of Battle, Gabriel Saban, 2:47
	BossMusic = { Id = "rbxassetid://1838623501", Volume = 0.26, Category = "Music" }, -- Hell Ride, Thomas Parisch, 2:21
	-- music slots (feature 28, Config.Features.MusicSlots; docs/features/FEEL.md): one track per
	-- world and one for the boss's later phases. "" = no track of its own yet, so the slot
	-- plays its Fallback (the tracks above). Owner: paste a licensed / Creator Store id here.
	WorldMusic_Forest = { Id = "", Volume = 0.22, Category = "Music", Fallback = "BattleMusic" },
	WorldMusic_Ruins = { Id = "", Volume = 0.22, Category = "Music", Fallback = "BattleMusic" },
	WorldMusic_Swamp = { Id = "", Volume = 0.22, Category = "Music", Fallback = "BattleMusic" },
	WorldMusic_Snow = { Id = "", Volume = 0.22, Category = "Music", Fallback = "BattleMusic" },
	WorldMusic_Desert = { Id = "", Volume = 0.22, Category = "Music", Fallback = "BattleMusic" },
	WorldMusic_Lava = { Id = "", Volume = 0.22, Category = "Music", Fallback = "BattleMusic" },
	BossPhaseMusic = { Id = "", Volume = 0.26, Category = "Music", Fallback = "BossMusic" }, -- boss phase 2+
	-- kill-streak milestone callout (feature 26): the SWARM SFX Item chime, played higher per milestone
	ComboMilestone = { Id = "rbxassetid://105588297309015", Volume = 0.24, Category = "UI", MinGap = 0.8, PitchVar = 0 },
}

--[[
	Mixing rules for Config.Sounds (client Audio.lua).
	  MaxVoices   effects playing at once in total; a new sound with a higher Priority
	              steals the voice of the oldest lower-priority one, a lower one is dropped
	  Categories  per category: Volume (sub-mix), MaxVoices, Priority (higher wins)
	  Duck        while a Warning / Boss sound plays, Combat is turned down this much
	  Crowd       density ceiling: when more than Start sounds of the listed categories
	              begin within Window seconds, those groups fade towards Floor (x their
	              volume) and recover once the swarm thins; keeps 200 kills a murmur
	  World       3D sounds: full volume up to RollOffMin studs from the camera (the run
	              camera sits ~78 studs from the hero), fading out by RollOffMax
	  Music       Fade = crossfade seconds between tracks; Resume = a track continues
	              where it left off (battle music is not restarted after a boss)
]]
Config.Audio = {
	MaxVoices = 12,
	-- only Warning / Boss sounds and the low-HP heartbeat (priority 5) may use the last Reserve voices
	CriticalPriority = 5,
	Categories = {
		Combat = { Volume = 0.7, MaxVoices = 3, Priority = 1 },
		Pickup = { Volume = 0.8, MaxVoices = 3, Priority = 2 },
		UI = { Volume = 0.75, MaxVoices = 2, Priority = 3 },
		Player = { Volume = 1, MaxVoices = 3, Priority = 4 },
		Warning = { Volume = 1, MaxVoices = 3, Priority = 5 },
		Boss = { Volume = 1, MaxVoices = 2, Priority = 5 },
	},
	Duck = { Triggers = { "Warning", "Boss" }, Target = "Combat", Volume = 0.45, Seconds = 0.5 },
	Crowd = { Categories = { "Combat", "Pickup" }, Window = 0.6, Start = 4, Full = 14, Floor = 0.35 },
	World = { RollOffMin = 90, RollOffMax = 280, Emitters = 10 },
	Music = { Fade = 1.5, Resume = true },
	-- music dip under big moments (sounds with DuckMusic): to Volume x in Attack s, back in Release s
	MusicDuck = { Volume = 0.4, Attack = 0.12, Release = 1.2 },
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
	Defaults = { Music = 0.6, Sfx = 0.8, Shake = 1, ReducedEffects = false, DamageNumbers = false, Tips = true, Minimap = true,
		Colorblind = "Off", ReduceFlashes = false, CombatVolume = 1, InterfaceVolume = 1, WarningVolume = 1,
		MuteAll = false, VisualAudioCues = false, TouchLayout = "RightHanded",
		DamageNumberSize = "Normal", CombineNumbers = true }, -- last two: DamageNumberOptions
	Enums = {
		DamageNumberSize = { "Small", "Normal", "Big" },
		Colorblind = { "Off", "Protanopia", "Deuteranopia", "Tritanopia" },
		TouchLayout = { "RightHanded", "LeftHanded", "Compact" },
	},
}

function Config.ValidateSetting(key: string, value: any): any
	local default = Config.Settings.Defaults[key]
	if default == nil or type(value) ~= type(default) then return nil end
	if type(value) == "number" then
		if value ~= value or math.abs(value) == math.huge then return nil end
		return math.clamp(value, 0, 1)
	end
	if type(value) == "string" and not (Config.Settings.Enums[key] and table.find(Config.Settings.Enums[key], value)) then return nil end
	return value
end

Config.TeamPings = { Cooldown = 2, Duration = 6, MaxDistance = 100 }

--[[
	TEAM (features 16, 17, 18, 20; docs/features/TEAM.md). Co-op only: a solo run never
	sees any of it. Each has its own switch in Config.Features.
]]
-- 16 team combo: two living, free players close together charge one shared meter; when
-- it is full either of them fires a burst around both (server-checked, capped damage).
Config.TeamCombo = {
	Radius = 12, -- studs between the two players (flat distance)
	ChargeSeconds = 25, -- seconds together (world running) for a full meter
	DrainSeconds = 60, -- apart: the meter drains from full to empty in this long
	Cooldown = 40, -- run seconds after a burst before the meter fills again
	BurstRadius = 20, -- around the middle of the pair
	Damage = 120, -- base damage per enemy, + PerLevel per average hero level
	PerLevel = 12,
	Cap = 600, -- per enemy, before the elite / boss share caps
	EliteShare = 0.2, -- elites, guards, mini-bosses, nests: at most this share of max HP
	BossShare = 0.04, -- bosses: at most this share of max HP (never an instant kill)
	Knockback = 30,
	MaxPerStage = 3, -- bursts per stage, whatever the meter says
	Rate = 2, -- TeamComboFire remote, per player per second
	Key = Enum.KeyCode.F, -- keyboard
	Pad = Enum.KeyCode.ButtonL1, -- gamepad
	ButtonSize = 60, -- touch button (pixels), left of the ULT button
}

-- 17 quick pings and emotes: the ping wheel (FeatureHud PingWheel slot). Presets only, no
-- text from players. Every ping still goes through TeamPingService (Config.TeamPings
-- cooldown + the remote rate limit). Labels are what teammates see on the marker.
Config.QuickPings = {
	Order = { "Help", "Loot", "Portal", "OnMyWay", "Wave", "Cheer" },
	Labels = {
		Help = "HELP HERE",
		Loot = "CHEST HERE",
		Portal = "GO PORTAL",
		OnMyWay = "ON MY WAY",
		Wave = "HELLO!",
		Cheer = "NICE!",
		ReviveMe = "REVIVE ME",
	},
	Emotes = { Wave = true, Cheer = true }, -- shown over the sender's head
	OpenKey = Enum.KeyCode.G, -- keyboard (the old PING key); 1-6 send directly
	PadOpen = Enum.KeyCode.DPadUp, -- gamepad: open / close
	PadNext = Enum.KeyCode.DPadRight, -- gamepad: highlight the next / previous option
	PadPrev = Enum.KeyCode.DPadLeft,
	PadSend = Enum.KeyCode.DPadDown, -- gamepad: send the highlighted option
	WheelSize = 260, -- pixels (the FeatureHud slot)
	ButtonSize = 76, -- each option (pixels, >= 44 touch)
}

-- 18 co-op boss mechanic: with 2+ living players, while one player holds this boss's
-- aggro for HoldSeconds a weak spot opens on its back (the side away from the holder) for
-- OpenSeconds. Hits from the other players standing behind it deal Mult damage. Solo and
-- every other boss are unchanged.
Config.CoopBoss = {
	Boss = "ScorpionQueen", -- the BossData id that gets the co-op variant
	MinPlayers = 2, -- living players needed
	HoldSeconds = 3, -- same aggro holder this long (boss attacking, not in its entrance)
	LoseSeconds = 0.6, -- the boss must aim at someone else this long before the holder changes
	OpenSeconds = 6,
	Cooldown = 8, -- after it closes
	Mult = 1.5, -- damage from behind while open (non-holders only)
	BackDot = -0.2, -- "behind": dot(boss→hitter, boss→holder) below this
	MaxBonusShare = 0.05, -- extra damage per opening, at most this share of the boss's max HP
	MarkerDistance = 1.0, -- marker sits this many boss radii behind it
}

-- 20 spectate: while down or out in a group run, cycle the camera through living
-- teammates; a REVIVE ME ping (teammates see it at your body).
Config.Spectate = {
	PrevKeys = { Enum.KeyCode.Left, Enum.KeyCode.DPadLeft },
	NextKeys = { Enum.KeyCode.Right, Enum.KeyCode.DPadRight },
	ReviveKeys = { Enum.KeyCode.G, Enum.KeyCode.DPadUp },
	ButtonSize = 56, -- arrow buttons (pixels)
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
--[[
	A brand-new player's first join drops straight into a Solo run with the first-run tips
	(the lobby shows after it). The client asks (remote StartFirstRun) once its lobby is up;
	RunManager decides (no run ever started, tutorial not done, lobby server, no party,
	not travelling / reconnecting) and answers with the player attribute FirstRun.
]]
Config.FirstRun = {
	AutoStart = true,
	Mode = "Solo",
	CoverSeconds = 4, -- the lobby waits at most this long for the server's answer
	--[[
		The first run's welcome (RunManager decides per run player: rp.FirstRun, player
		attribute FirstRunBoost). Only an account's very first run (no run ever started,
		tutorial not done, bonus not paid), Solo, no curses / Endless, never DEV-tainted,
		never co-op or Daily, and only while AutoStart is on (the preview mock switches it
		off for every scene but firstjoin-sim). The global XP curve is untouched.
	]]
	Boost = true,
	FirstLevelXP = 18, -- level 1 -> 2 in the first run (normally Config.XP: 42); firstjoin-sim: ~15 s
	-- the first level-up always offers one of these (the first one not owned) as a NEW
	-- weapon, plus an upgrade for the starting weapon; the third card is a normal roll
	ShowcaseWeapons = { "Lightning", "Garlic", "HolyWater" },
	GentleWaves = 2, -- waves 1..GentleWaves are smaller and softer in the first run
	GentleSizeMult = 0.7,
	GentleHPMult = 0.7,
	-- paid once per account when the first run ends (win or lose, not DEV-tainted), on top
	-- of the run's gold: the price of the cheapest permanent upgrade (a hero's Max HP lv 1: 200)
	BonusGold = 200,
	--[[
		The tutorial run's portal reveal (StageManager, RunManager.TutorialRevealHold): a
		Solo run whose player has not finished the tutorial (save TutorialDone false, tips on,
		not DEV-tainted) keeps the stage-1 portal hidden until the first level-up card is
		picked, then reveals it RevealAfterPickSeconds later (the cards have closed), or at
		RevealCapSeconds of stage time, whichever comes first. Co-op and returning players:
		the normal Config.Stages.RevealDelaySeconds.
	]]
	RevealWaitsForPick = true, -- needs AutoStart on too (the preview switches it off)
	RevealAfterPickSeconds = 1,
	RevealCapSeconds = 45,
}

--[[
	The interactive first-run walkthrough (Config.Features.Walkthrough; server
	Walkthrough.lua, client WalkthroughClient.lua, docs/next/WALKTHROUGH.md). Same gate as the
	first-run flow (Config.FirstRun.AutoStart on, Solo, Standard, no curses / Endless / Daily,
	not DEV-tainted, tips on) plus: the account's very first run (Stats.Runs 0, TutorialDone
	false) or Settings > Replay tips (save WalkthroughReplay). Runs once (save WalkthroughDone).
	Steps wait for the player: MOVE (stand in a gold ring), FIGHT (beat EnemyCount weak
	enemies), GEMS (pick up their gems; first level-up), UPGRADE (pick a card), CHEST (open a
	free chest), GO (waves + portal reveal released). Normal waves and the stage-1 portal
	reveal are held until GO. Every step auto-completes after its timeout (run clock: pause
	and panels stop it), so nobody gets stuck.
]]
Config.Walkthrough = {
	RingDistance = 15, -- studs from the hero to the MOVE ring
	RingRadius = 4.5, -- the hero counts as "in the ring" within this many studs
	RingClearance = 5, -- open ground needed around the ring / chest (EnemyAI obstacles)
	EnemyType = "Slime", -- the weakest basic enemy (EnemyData)
	EnemyCount = 5,
	EnemyDistance = 20, -- studs from the hero
	EnemyHP = 4, -- each one dies to one or two hits
	EnemySpeedMult = 0.45, -- slow
	EnemyDamageMult = 0.3, -- soft bites
	GemRadius = 45, -- gems within this many studs count for the first level (top-up check)
	ChestDistance = 12, -- studs from the hero to the free chest
	ChestType = "Small", -- a normal free chest (LootSystem.AddFeatureChest, normal reward)
	GoSeconds = 6, -- "Waves are coming!" stays this long, then the walkthrough ends
	ReleaseWaveDelay = 4, -- the first wave comes at most this long after GO
	-- seconds of run time before a step completes on its own
	Timeouts = { Move = 45, Fight = 45, Gems = 30, Upgrade = 45, Chest = 45 },
}

Config.Tutorial = {
	Tips = { "Move", "Attack", "Gems", "LevelUp", "Portal", "Boss", "Revive", "TeamRules", "Chest" },
	HintSeconds = 6.5, -- each hint stays this long
	GapSeconds = 1.5, -- pause between two hints
	FirstDelay = 1.5, -- the first hint after the run starts
	PortalTipDelay = 2, -- seconds after the portal reveal (its banner first) before the portal tip
	--[[
		Smarter tutorial (Config.Features.SmartTutorial; client TutorialBubble.lua,
		docs/next/SMART_TUTORIAL.md): seven one-at-a-time speech-bubble tips (Move, Attack,
		Gems, LevelUp, Chest, Portal, Boss), each when it is needed, over the player's first
		Runs runs (save TutorialStep counts the tutorial runs played; TutorialDone ends it).
		A bubble fades once its action is done or after Seconds.
	]]
	Smart = {
		Runs = 2, -- tutorial runs before TutorialDone
		Seconds = 8, -- a bubble's longest stay
		AttackSeconds = 4, -- "your weapon attacks by itself" (nothing to do)
		MoveStuds = 10, -- the move tip ends once the hero walked this far
		GemNearStuds = 30, -- the gem tip starts when a gem lies this close
		ChestStuds = 12, -- the chest tip starts this close to a ready chest
		GapSeconds = 0.8, -- pause between two bubbles
	},
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

-- Damage number options (Config.Features.DamageNumberOptions; shared DamageNumberView.lua,
-- client DamageText.lua + DamageOptionsUI.lua; docs/next/DAMAGE_NUMBERS.md). Settings:
-- DamageNumbers (the old on / off switch = "Off" vs the three sizes), DamageNumberSize
-- (Small / Normal / Big; Normal is the look above) and CombineNumbers (hits on one enemy
-- within CombineSeconds merge into one rising number; off = every server batch gets its own).
Config.DamageNumberOptions = {
	Order = { "Off", "Small", "Normal", "Big" },
	Sizes = { -- text size in pixels: plain hit, critical hit
		Small = { Hit = 14, Crit = 18 },
		Normal = { Hit = 18, Crit = 22 },
		Big = { Hit = 24, Crit = 30 },
	},
	CombineSeconds = 0.3,
	CritMark = "★", -- crits start with a star, are bold and gold (never colour alone)
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
	-- Phones in landscape (short side < 560 px) use this smaller design space instead, so a
	-- 852 x 393 phone renders reference px at ~0.77 (text ~11-15 pt, buttons ~40 pt) and
	-- layouts reflow into ~960 x 514 virtual px.
	PhoneReferenceSize = Vector2.new(960, 470),
	-- The player's Roblox "Text size" setting (GuiService.PreferredTextSize) scales every
	-- TextSize-sized label at render time. TextFit lets text grow up to this much over its
	-- designed size where the label has room, and shrinks it back (never below the design
	-- size) where it would be cut or run into its neighbours (docs/MOBILE_FIX.md).
	TextGrowMax = 1.25,
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
-- A fallen player is revived by a living teammate standing next to them (no button).
local PARTNER_REVIVE = {
	Seconds = 2, -- stand within Radius this long; out of range the progress drains at the same rate
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
	-- The Weekly Challenge (feature 21, Config.Features.WeeklyChallenge; MetaData.Weekly):
	-- solo, a fixed hero, curses and first world per UTC week, its own weekly board. Not in
	-- Order: it has its own screen (MenuWeekly). Accepted only while the switch is on.
	Weekly = { DisplayName = "Weekly", MaxPlayers = 1, Countdown = false },
}

-- Revive thank-you (Config.Features.ReviveThanks; docs/next/REVIVE_THANKS.md): after a
-- teammate revives you, a THANKS! button shows for ThanksSeconds. A tap tells the reviver
-- "<name> says thanks!" and gives them ThanksXP run XP (server-checked: once per revive, at
-- most ThanksPerPair per run for one pair, never yourself, never solo, never a DEV run).
-- PROPOSED: ThanksXP awaits the owner's approval.
Config.Revive = {
	ThanksXP = 25, -- run XP the reviver gets per thank-you
	ThanksSeconds = 6, -- the button's time on screen
	ThanksGrace = 1.5, -- the server accepts a tap this much later (network lag)
	ThanksPerPair = 3, -- thank-yous per run for one (revived, reviver) pair
	ThanksRate = 2, -- "ReviveThanks" remote calls per second per player
}

-- Parties (server PartyService.lua, lobby PARTY screen MenuParty.lua). Friends on this
-- server form a party; when the leader starts SOLO / DUO / TRIO (or the Daily) the
-- members join that run at once, up to the mode's size. A party is never bigger than
-- the largest lobby mode (and Config.Run.MaxPlayers). Friends on other servers: Roblox's
-- invite prompt and a JOIN (teleport to the friend's server) that lands in their party.
Config.Party = {
	Enabled = true,
	InviteSeconds = 30, -- an invite expires after this
	ReinviteSeconds = 8, -- the same player can't be invited again sooner
	MaxPendingInvites = 6, -- open invites one player may have sent
	FriendsCacheSeconds = 30, -- the client asks Roblox for online friends at most this often
	FollowCooldown = 6, -- seconds between JOIN (teleport) attempts per player
	ActionRate = 4, -- "Party" remote calls per second per player
}

-- Party quick lines (Config.Features.PartyQuickLines; docs/next/PARTY_QUICK_LINES.md): fixed
-- text only, the client sends a line INDEX (1..#Lines), never text. The server checks the
-- index, the rate limits and that sender and receivers share a party. A line shows as a
-- bubble over the sender's lobby hero and in the PARTY screen's feed.
Config.PartyQuickLines = {
	Lines = { "Ready?", "Go!", "GG", "One more?", "Wait for me", "Thanks!" },
	MinGap = 2, -- seconds between two lines from one player
	PerMinute = 10, -- lines per player in any 60 s
	BubbleSeconds = 4, -- a bubble stays this long (the last FadeSeconds fade out)
	FadeSeconds = 0.6,
	FeedMax = 6, -- lines kept in the PARTY screen's feed
}

-- Private run servers (server RunServers.lua, client TravelOverlay.lua). In the live game a
-- run never plays on the public lobby server: its players are saved and teleported
-- together to a fresh reserved server of this place, which starts the run by itself and
-- sends everyone back to a public lobby afterwards. So a run can always start, whoever else
-- is playing. Studio, an unpublished place (PlaceId 0) or Enabled = false keep runs on
-- the lobby server as before; so does a teleport that fails twice.
Config.RunServers = {
	Enabled = true,
	TicketVersion = 1, -- bump when the ticket shape changes (older tickets are refused)
	WaitForTeamSeconds = 15, -- run server: wait this long for the whole team to arrive
	WaitForLoadSeconds = 45, -- ...longer while someone who arrived is still loading their save
	GiveUpSeconds = 60, -- nobody's save loaded by then: everyone goes back to the lobby
	TeleportTimeoutSeconds = 40, -- still here this long after the teleport: it failed
	HomeDelaySeconds = 20, -- results over the lobby (portal / MAIN MENU): back to a lobby after this
	ReplayGraceSeconds = 10, -- REPLAY on a run server: the new run / countdown must start within this, else the home countdown (the defeat results / MAIN MENU go home at once, FLOW)
	HandoffLoadAttempts = 12, -- DataService load retries for a player arriving by a SWARM teleport
	RejoinGraceSeconds = 120, -- a disconnected co-op member can return while this run remains alive
	SoloResumeSeconds = 60, -- QuickResume: a disconnected SOLO run waits (frozen) this long (docs/next/QUICK_RESUME.md)
}

-- Quick resume (Config.Features.QuickResume; server QuickResume.lua, client ResumeCard.lua;
-- docs/next/QUICK_RESUME.md). The window itself is Config.RunServers.SoloResumeSeconds.
Config.QuickResume = {
	Rate = 2, -- "QuickResume" requests per second per player (Remotes.Listen)
}

------------------------------------------------------------------------------------------
-- LEADERBOARDS (server LeaderboardService.lua, OrderedDataStores)
--   High Score (Standard), High Score Endless, Best Stage (all time), Daily Challenge
--   (today's scored attempts), Most Kills (one run), Highest Level (one run).
--   Writes happen when a run is committed, queued and throttled per player and board, and
--   only while the DataStore write budget allows; reads are cached and refreshed at most
--   every RefreshSeconds while someone looks at them. Without DataStores (Studio without
--   API access) the boards show this server's runs only, with a clear note.
------------------------------------------------------------------------------------------
Config.Leaderboards = {
	Enabled = true,
	StorePrefix = "SwarmLB_", -- OrderedDataStore names: SwarmLB_Score, SwarmLB_ScoreEndless, SwarmLB_BestStage, SwarmLB_Kills, SwarmLB_Level, SwarmLB_Daily_<day>
	StudioStorePrefix = "SwarmLB_Studio_", -- used instead in Studio: tests never touch live boards
	Order = { "Score", "ScoreEndless", "BestStage", "Daily", "Kills", "Level", "Playtime" }, -- Playtime: total seconds in clean runs (lobby home panel)
	-- High score of one run (board "Score"), worked out on the server from the run's own
	-- numbers (LeaderboardService.RunScore), never sent by a client:
	--   Stage * stages cleared + Boss * bosses beaten + Level * level reached + Kill * kills
	--   + Second * whole seconds survived
	-- Clearing stages counts most (the game's goal), bosses next; kills, levels and time
	-- break ties between runs that got equally far. "Score" takes Standard runs only;
	-- Endless runs (Config.Endless) score with the same formula on "ScoreEndless".
	-- "Level" is the highest level reached in one run (any mode, Daily included).
	Score = { Stage = 1000, Boss = 500, Level = 20, Kill = 1, Second = 0.5 },
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
	MenuFieldOfView = 40, -- FOV of the menu shot (MenuCamera attribute; portrait widens it)
}

------------------------------------------------------------------------------------------
-- MOVEMENT: jump and bunny hop (client JumpController.lua, server RunManager speedCheck)
--   Jump: Space / gamepad A / the JUMP button (touch). A press shortly before landing is
--   kept (BufferSeconds) and a press just after walking off an edge still jumps
--   (CoyoteSeconds). No jumping while the run is frozen (level-up, pause), downed or in
--   the lobby.
--   Bunny hop: jumping again within HopWindow of landing (while moving) adds HopBonus to
--   a speed multiplier, never above HopSpeedCap. On the ground it decays back to 1 at
--   HopDecay per second (and resets at once when the player stops).
--   Air control: in the air the move input only steers the takeoff direction at
--   AirControl per second (modest; no full mid-air turns).
--   Server: RunManager's position check allows base speed * HopSpeedCap * ServerTolerance
--   (plus Config.Player.SpeedCheckAllowance for lag) and snaps back anything faster.
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
	ServerTolerance = 1.35, -- server speed check slack on top of the hop cap (lag, knockback)
	ButtonSize = 84, -- touch JUMP button (pixels before UIScale)
	ButtonMargin = 26, -- from the right and bottom safe-area edges
}

Config.Encounters = {
	Types = { "Guarded", "Caravan", "Runes", "Treasure" },
	Count = { 1, 2 },
	-- Introductory stages (EncounterDirector.IntroBlock; the caravan defence and the villager
	-- escort): one that has NOT started yet can't start during the stage boss fight (Boss,
	-- Surge) nor for QuietAfterSeconds after the boss died or an optional reward paid out.
	-- One already running goes on under its normal rules. Later stages are unchanged.
	Intro = { Stages = { 1 }, QuietAfterSeconds = 20 },
	-- EncounterDirector (server): the feature encounters (map events, mini-bosses, shrines,
	-- merchant, rescue, secret rooms ...) on top of the optional locations above.
	Director = {
		MaxActive = 2, -- placed encounters running at the same time (per stage)
		MaxAmbient = 1, -- ambient ones (weather, map-wide events) at the same time
		-- FindSpot defaults: the same rules as the optional locations (LootSystem.BuildStage)
		MinDistance = 75, -- studs from the spawn centre
		Clearance = 11, -- free radius around the spot
		Spacing = 34, -- studs from the portal, loot, the caravan and other encounters
	},
}

------------------------------------------------------------------------------------------
-- FEATURES (the 30-features batch, docs/features/FOUNDATION.md)
--   One switch per feature. false = the game behaves exactly as before that feature.
--   Read with Config.FeatureOn(name) (unknown names read as off).
------------------------------------------------------------------------------------------
Config.Features = {
	Sigils = true, -- 1  Sigils (docs/SIGILS_PLAN.md)
	MapEvents = true, -- 2  meteor shower, gold rush minute, fog
	MiniBosses = true, -- 3  mid-stage mini-boss guarding a big chest
	SecretRooms = true, -- 4  cracked walls
	TrialShrine = true, -- 5  Shrine of Trial
	Merchant = true, -- 6  merchant cart
	CursedChests = true, -- 7  cursed chests
	Rescue = true, -- 8  lost villager to the portal
	Weather = true, -- 9  weather per world
	BossIntro = true, -- 10 boss phase intro (camera push + name card)
	NewHeroes = true, -- 11 Archer, Bard, Golem
	SecondSkill = true, -- 12 second signature skill via mastery
	Ultimate = true, -- 13 hero ultimate
	BuildPresets = true, -- 14 favourite build paths
	WeaponMastery = true, -- 15 weapon mastery glow / trail
	TeamCombo = true, -- 16 team combo move
	QuickPings = true, -- 17 quick pings / emotes
	CoopBoss = true, -- 18 co-op-only boss mechanic
	TeamBoard = true, -- 19 weekly team leaderboard
	Spectate = true, -- 20 spectate a teammate after death
	WeeklyChallenge = true, -- 21 weekly challenge run
	SeasonTrack = true, -- 22 free season track
	Titles = true, -- 23 achievement titles under the name
	CollectionBook = true, -- 24 collection book
	LoginStreak = true, -- 25 daily login streak
	DailyQuests = true, -- 3 daily quests per UTC day (docs/next/DAILY_QUESTS.md)
	ComebackGift = true, -- welcome-back gift after 3+ days away (docs/next/COMEBACK_GIFT.md)
	Announcer = false, -- off 2026-10-07: the owner found the combo text blocked the screen. -- 26 kill-streak announcer + combo counter
	HitFeel = true, -- 27 hit-stop + death burst
	MusicSlots = true, -- 28 per-world + boss-phase music slots
	PhotoMode = true, -- 29 photo mode on results
	LobbyFun = true, -- 30 training dummy, mirror, jump-pad course
	Store = true, -- the cosmetics store (docs/features/STORE.md)
	FastStart = true, -- quicker, slightly bigger waves 1-3 on stage 1 (Config.FastStart, docs/next/FAST_START.md)
	StarterBundle = true, -- one-per-account starter bundle product (docs/next/STARTER_BUNDLE.md)
	GroupBonus = true, -- Roblox group member gold bonus + title (docs/next/GROUP_BONUS.md)
	InviteRewards = true, -- invite friends: cosmetic rewards (docs/next/INVITE_REWARDS.md)
	BugReportPlus = true, -- bug report snapshot, 3 reports/hour, DEV inbox latest 20 (docs/next/BUG_REPORT_PLUS.md)
	SmartTutorial = true, -- one-at-a-time speech-bubble tips over the first 2 runs (docs/next/SMART_TUTORIAL.md)
	DangerArrows = true, -- off-screen boss / champion / elite edge arrows (docs/next/DANGER_ARROWS.md)
	Walkthrough = true, -- interactive first-run walkthrough: move, fight, gems, upgrade, chest, go (Config.Walkthrough, docs/next/WALKTHROUGH.md)
	-- batch B (docs/PROMPT_BATCH_B.md, docs/next/)
	AffixIcons = true, -- elite affix badges over elites + first-sight notice (docs/next/AFFIX_ICONS.md)
	EvolutionPreview = true, -- evolution line on cards + BUILD panel Evolutions list (docs/next/EVOLUTION_PREVIEW.md)
	Banish = true, -- BANISH on the level-up panel, 3 per run (docs/next/BANISH.md)
	DamageNumberOptions = true, -- damage number size + combine settings (docs/next/DAMAGE_NUMBERS.md)
	FinalStand = true, -- 5 s speed/damage burst under 10% HP, once per stage (docs/next/FINAL_STAND.md)
	StageModifiers = true, -- one trade-off modifier per stage from stage 2 (docs/next/STAGE_MODIFIERS.md)
	PartyQuickLines = true, -- fixed-text party quick lines (docs/next/PARTY_QUICK_LINES.md)
	ReviveThanks = true, -- THANKS! button after a teammate revive (docs/next/REVIVE_THANKS.md)
	Prestige = true, -- reset a maxed hero's mastery for a gold-bonus star (docs/next/PRESTIGE.md)
	QuickResume = true, -- resume a disconnected solo run within 60 s (docs/next/QUICK_RESUME.md)
}

-- Season track (feature 22, Config.Features.SeasonTrack; MetaData, docs/features/META.md).
-- A season runs from Start to End (UTC dates, both days included); its Id keys the save's
-- progress (a new Id starts a new track, and tiers reached but not claimed in the old one
-- are paid when the new one starts). Free only: there is no paid lane. Add the next season
-- as a new row; never reuse an Id.
Config.Season = {
	List = {
		{ Id = "S1", Name = "Season 1", Start = "2026-10-05", End = "2027-01-03" },
	},
	XPPerTier = 400, -- season XP per tier (season XP = the account XP a clean run gives)
	Tiers = 30,
}

-- Off-screen danger arrows (Config.Features.DangerArrows; client DangerArrows.lua,
-- docs/next/DANGER_ARROWS.md): an edge arrow per boss / champion / elite that is off screen
-- or farther than FarStuds, nearest first, at most MaxArrows, refreshed UpdateHz times a second.
Config.DangerArrows = {
	FarStuds = 60, -- on screen but farther than this still gets an arrow
	MaxArrows = 4,
	UpdateHz = 10,
	FadeSeconds = 0.15, -- fade in (under 0.2 s)
	Size = 44, -- badge size in pixels (the distance tag sits under it)
	EdgeMargin = 8, -- pixels inside the safe area
}

-- True when feature `name` (a Config.Features key) is switched on.
function Config.FeatureOn(name: string): boolean
	return (Config.Features :: any)[name] == true
end

-- Client FeatureHud (src/client/FeatureHud.lua): reserved HUD slots for new features.
Config.FeatureHud = {
	UltimateKey = Enum.KeyCode.Q, -- keyboard
	UltimatePad = Enum.KeyCode.ButtonR1, -- gamepad
	UltimateSize = 72, -- touch button (pixels), above the JUMP button
	BadgeSize = 36, -- top-right badge row (pixels)
	MaxBadges = 6,
	MaxBadgesCompact = 3, -- phones: fewer badges (lowest Order first) so the row fits
	BadgeMinScale = 0.7, -- the row shrinks down to this before badges are dropped
	AnnounceSeconds = 1.6, -- combo / announcer line default time on screen
}

--[[
	LOBBY (features 15, 29, 30; docs/features/LOBBY.md). Cosmetic and lobby-only: nothing
	here changes a run's power.
]]
-- 15 Weapon mastery (Config.Features.WeaponMastery): the server counts each weapon's kills
-- (save field WeaponMastery {weaponId → kills}); a milestone unlocks a glow colour for THAT
-- weapon. The colour each weapon wears is chosen per weapon in the WEAPON MASTERY menu and
-- saved in the same field as "Glow:<weaponId>" → milestone number (absent = its own colour).
-- Only your own weapon effects are tinted, on your screen.
Config.WeaponMastery = {
	Milestones = { -- kills with one weapon → a glow colour for it (CosmeticData "Earned" Trail entries)
		{ Kills = 250, Id = "Trail_MasteryBronze", Name = "Bronze Glow", Color = Color3.fromRGB(222, 142, 74) },
		{ Kills = 1000, Id = "Trail_MasterySilver", Name = "Silver Glow", Color = Color3.fromRGB(200, 222, 244) },
		{ Kills = 3000, Id = "Trail_MasteryGold", Name = "Gold Glow", Color = Color3.fromRGB(255, 204, 72) },
		{ Kills = 8000, Id = "Trail_MasteryArcane", Name = "Arcane Glow", Color = Color3.fromRGB(184, 120, 255) },
	},
	Tint = 0.8, -- how much of the weapon's own trail / slash colour the glow replaces
	MaxCount = 100000000, -- a weapon's count stops here
	EquipRate = 4, -- SetMasteryGlow requests per second per player
}

-- 29 Photo mode on the results screen (Config.Features.PhotoMode): no upload, the player
-- uses the device's own screenshot.
Config.PhotoMode = {
	Poses = { "Showcase", "Cheer", "Idle" }, -- HeroPoses names, in the POSE button's order
	PoseNames = { Showcase = "HEROIC", Cheer = "CHEER", Idle = "RELAXED" },
	OrbitSpeed = 10, -- degrees per second while ORBIT is on
	Distance = 17, -- camera distance from the hero (studs)
	Height = 6, -- camera height above the hero's feet (looks over gems and small props)
	AimHeight = 3.2, -- aim point above the feet
	FieldOfView = 40,
	Frames = { "None", "Gold", "Crimson", "Frost" }, -- overlay frame styles (FRAME button)
	HintSeconds = 2.5, -- "Tap to exit" hint
}

-- 30 Lobby fun (Config.Features.LobbyFun): a courtyard behind the menu camera, built on the
-- client only while the player is there (never in the title shot). Offsets are studs from
-- Config.Lobby.Origin; +Z is behind the menu camera.
Config.LobbyFun = {
	-- the play camera looks the run camera's way (toward −Z), so things further up the
	-- screen have a smaller z: the spawn is at the back (+Z), the course runs up the screen
	Spawn = Vector3.new(0, 3, 104), -- where you appear
	WalkSpeed = 16,
	CameraDistance = 34,
	Dummy = Vector3.new(-15, 0, 94), -- training dummy (DPS of the selected hero's start weapon)
	DummyHitEvery = 0.5, -- seconds between the dummy's shown hits
	Mirror = Vector3.new(15, 0, 94), -- cosmetics mirror
	Lanterns = { Vector3.new(-9, 0, 100), Vector3.new(9, 0, 100), Vector3.new(0, 0, 70) }, -- warm lights (dusk)
	Course = {
		-- a jump pad sits at the start and on every platform but the last; a pad throws you
		-- straight up (LaunchSpeed) and you steer onto the next platform in the air
		Start = Vector3.new(0, 0, 86), -- the first pad, on the courtyard floor
		Platforms = { -- top centre + size; the last one is the finish
			{ At = Vector3.new(0, 5, 78), Size = Vector3.new(7, 1, 7) },
			{ At = Vector3.new(8, 10, 71), Size = Vector3.new(7, 1, 7) },
			{ At = Vector3.new(0, 15, 64), Size = Vector3.new(7, 1, 7) },
			{ At = Vector3.new(-9, 19, 58), Size = Vector3.new(9, 1, 9) },
		},
		LaunchSpeed = 62, -- studs/s up (about 9.8 studs high)
		PadRadius = 1.8,
		PadCooldown = 0.4,
		FinishRadius = 4,
		FallY = -8, -- below this (relative to the origin) you are put back at the start
		MaxSeconds = 120, -- a try longer than this is dropped
	},
	Floor = { Centre = Vector3.new(0, 0, 80), Size = Vector3.new(64, 1, 64) }, -- top at y 0
	MaxParts = 80, -- the whole courtyard stays under this many parts (perf)
}

--[[
	FEEL (features 10, 26, 27, 28; docs/features/FEEL.md). Client-only presentation: none of
	it changes damage, timing or what the server simulates.
	  BossIntro  boss arrival / phase change: a short camera push toward the boss (solo), a
	             zoom + vignette that never moves the view (co-op), the name card through
	             UIState's headline lane. Reduced effects or Screen shake 0 = card only.
	  Announcer  combo counter in the FeatureHud announcer line + milestone callouts.
	  HitFeel    a tiny camera hold on crits / huge kills (capped per second) and a pooled
	             chunk burst on enemy deaths.
]]
Config.Feel = {
	BossIntro = {
		Seconds = 1.1, -- whole push: ease in, hold, ease out (never over 1.2)
		In = 0.3,
		Out = 0.45,
		Shift = 0.4, -- the view slides this fraction of the hero -> boss gap ...
		MaxShift = 16, -- ... at most this many studs, so the hero stays on screen
		Pull = 0.16, -- and moves this fraction of the camera distance closer
		CoopZoom = 0.9, -- co-op: field of view x this at the peak (a zoom; the view never moves)
		Vignette = 0.5, -- co-op: darkest edge (0 = none, 1 = black)
	},
	Announcer = {
		ResetSeconds = 3, -- the combo ends after this long without a kill
		ShowFrom = 10, -- the counter shows from this many kills in a row
		Milestones = { 50, 100, 250, 500, 1000 },
		Words = { [50] = "KILLING SPREE", [100] = "RAMPAGE", [250] = "UNSTOPPABLE", [500] = "LEGENDARY", [1000] = "GODLIKE" },
		CalloutSeconds = 1.8,
		PitchStep = 2, -- semitones higher per milestone (ComboMilestone sound)
	},
	HitFeel = {
		StopSeconds = 0.035, -- camera hold on a big hit (<= 0.04)
		MaxPerSecond = 2, -- hit-stops in any 1 s window
		MinGap = 0.3,
		CritRange = 55, -- studs: only crits this close to the local hero count
		BurstsPerBatch = 6, -- death bursts per FxBatch (nearest first in batch order)
		BurstRange = 70, -- studs from the hero
		Pieces = 5, -- chunks per normal kill (big kills x2)
		MaxPieces = 60, -- alive at once (pooled parts)
		PiecesPerSecond = 160, -- token bucket
		Life = 0.65, -- seconds a chunk flies
		Gravity = 70,
	},
}

------------------------------------------------------------------------------------------
-- MAP EVENTS (feature 2, src/server/Modules/WorldEvents.lua, docs/features/EVENTS.md)
--   At most one map event per stage, through EncounterDirector (an ambient encounter).
--   It starts StartAfter seconds into the stage's explore phase and ends early when the
--   boss comes (any phase but Explore). Balance-neutral by design: meteors hit enemies
--   too, the gold rush only raises the kill-gold CHANCE (capped), fog is visual only.
------------------------------------------------------------------------------------------
Config.WorldEvents = {
	FirstStage = 2, -- stage 1 stays plain (first runs, the tutorial)
	Chance = 0.6, -- per stage from FirstStage
	StartAfter = { 40, 100 }, -- seconds into the explore phase
	Weights = { Meteor = 1, GoldRush = 1, Fog = 1 },
	Meteor = {
		Seconds = 24, -- the shower lasts this long
		Every = 3.2, -- a volley every this many seconds
		PerVolley = 3, -- impacts per volley (one near each living player first, then random)
		Warn = 1.3, -- seconds between the warning ring and the impact (at least 1.2)
		Radius = 7,
		NearPlayer = { 4, 14 }, -- the player-aimed impact lands this far from them (never on top)
		Damage = 14, -- to players, x the stage DamageMult; armor / invulnerability apply
		EnemyHPFraction = 0.45, -- normal enemies lose this share of their max HP (no gold: no killer)
		EliteHPFraction = 0.12,
		MaxHazardShare = 0.5, -- skip a volley while other hazards use this share of MaxHazards
	},
	GoldRush = {
		Seconds = 60,
		ChanceMult = 2, -- kill-gold chance x this (amount, GoldMult and passes unchanged)
		MaxChance = 0.6, -- the boosted chance never goes above this
	},
	Fog = {
		Seconds = 45,
		Radius = 42, -- enemies show within this many studs of a living run player
		Hysteresis = 4, -- shown ones hide only this far past the radius (no flicker)
		-- bosses, elites, telegraphs, projectiles, pickups and the minimap always show
	},
}

------------------------------------------------------------------------------------------
-- WEATHER (feature 9, src/server/Modules/Weather.lua, client WorldFx.lua)
--   A property of the world, not an encounter: it never takes the director's ambient
--   slot, so a map event can still run beside it. Snow: everyone (enemies too) moves a
--   little slower. Lava: telegraphed fire patches (burn players and enemies alike).
--   Every world has at most one light ambient particle effect (Reduced effects: none
--   for decoration, a lighter snowfall).
------------------------------------------------------------------------------------------
Config.Weather = {
	FirstStage = 1,
	Snow = {
		PlayerSpeed = 0.9, -- WalkSpeed x this (stacks with the floor hazards' mult)
		EnemySpeed = 0.9, -- every walking enemy (not bosses' scripted moves)
	},
	Lava = {
		FirstAfter = 20, -- seconds into the explore phase
		Every = { 14, 20 }, -- seconds between eruptions
		Patches = 2, -- per eruption (the first near a random living player)
		NearPlayer = { 6, 16 },
		Radius = 6,
		Arm = 1.6, -- harmless glow first (the telegraph)
		Life = 4,
		Tick = 0.5,
		Damage = 5, -- per tick to players, x the stage DamageMult
		EnemyDamageFraction = 0.08, -- per tick, of a normal enemy's max HP (elites x0.25)
		MaxHazardShare = 0.5,
	},
	-- client ambience per arena (WorldFx): Kind = "Snow" | "Embers" | "Leaves" | "Motes" |
	-- "Dust" | nil, Rate = particles per second (x0.4 with Reduced effects; decoration
	-- kinds are off with Reduced effects, snow stays light so the storm is still told)
	Ambient = {
		Forest = { Kind = "Leaves", Rate = 6 },
		Ruins = { Kind = "Motes", Rate = 5 },
		Swamp = { Kind = "Motes", Rate = 7 },
		Snow = { Kind = "Snow", Rate = 70 },
		Desert = { Kind = "Dust", Rate = 8 },
		Lava = { Kind = "Embers", Rate = 14 },
	},
}

--[[
	CHALLENGES (features 3, 5, 7; docs/features/CHALLENGES.md). Server-owned encounters;
	every reward is granted once on the server through the existing pipelines.
	  MiniBoss     from stage MinStage, a buffed elite guards a big free chest (EncounterDirector
	               placed encounter). The chest stays locked until a player kills the guard.
	  TrialShrine  hold to start a short, harder fight; survive inside the ring for Seconds and
	               each survivor gets one extra upgrade pick with a guaranteed NEW / MAX /
	               EVOLUTION card (LevelUpSystem.QueueBonusPick, the normal OfferId flow).
	  CursedChest  one paid chest per stage (Chance) turns cursed: better loot, same price;
	               opening it makes the swarm stronger for Seconds (shown on the prompt first).
]]
Config.MiniBoss = {
	MinStage = 2,
	Weight = 3, -- EncounterDirector pick weight (higher = more often picked first)
	WakeRadius = 30, -- a player this close wakes the guard (studs from the chest)
	-- buffed existing enemy types, picked at random; the name plate shows the name
	Types = { "Brute", "Skeleton", "Ghost" },
	Names = { Brute = "Ironhorn the Brute", Skeleton = "Beetle Captain", Ghost = "Moth Duchess" },
	HPMult = 3, -- on top of the elite's HP (x Config.Enemies.EliteHPMult)
	DamageMult = 1.3, -- contact + attack damage
	SpeedMult = 0.9,
	ChestWeights = { Common = 0, Uncommon = 70, Legendary = 30 }, -- free Large chest
	RetrySeconds = 4, -- the guard was swept away (not killed): it comes back after this
}
Config.TrialShrine = {
	MinStage = 2, -- BALANCE-2: a level-1 hero who started it on stage 1 died in ~8 s (econ-sim)
	Weight = 1,
	Hold = 1.2,
	Seconds = 30, -- survive this long
	Radius = 22, -- stay inside this ring (studs from the shrine)
	LeaveGrace = 2, -- seconds outside the ring before the trial fails
	Alive = 10, -- trial enemies kept alive at once (solo) ...
	AlivePerExtraPlayer = 4, -- ... + this per extra player in the trial
	SpawnRadius = { 16, 24 },
	EliteEvery = 10, -- an elite joins every this many seconds
	HPMult = 1.5,
	DamageMult = 1.25,
}
Config.CursedChest = {
	Chance = 0.6, -- per stage, from MinStage
	MinStage = 1,
	Types = { "Small", "Large" }, -- which paid chests may turn cursed (price unchanged)
	Seconds = 60,
	EnemyDamageMult = 1.25,
	EnemySpeedMult = 1.15,
	Weights = {
		Small = { Common = 30, Uncommon = 60, Legendary = 10 }, -- normal Small 80 / 19 / 1
		Large = { Common = 0, Uncommon = 55, Legendary = 45 }, -- normal Large 0 / 80 / 20
	},
}

------------------------------------------------------------------------------------------
-- HERO MASTERY (MetaUpgradeData, DataService schema 7)
--   Playing a hero gives that hero Mastery XP: the same amount as the account XP of the
--   run (AccountData.RunXP, its MaxRun cap), only for the hero played, none on DEV runs.
--   XP from level L to L + 1 = Base + PerLevel * (L - 1); heroes start at level 1.
--   Mastery level N lets the hero's stat upgrades go up to level StatPerLevel * N; the
--   signature upgrade's level n needs mastery SignatureEvery * n. Gold buys the levels.
------------------------------------------------------------------------------------------
Config.HeroMastery = {
	MaxLevel = 10, -- 2 x 10 = 20 = the highest stat upgrade (Max HP, Might)
	Base = 150, -- level 1 -> 2 (a short first run)
	PerLevel = 100, -- each next level needs this much more (4,950 XP to level 10)
	StatPerLevel = 2,
	SignatureEvery = 2, -- signature level n needs mastery 2n (levels 2, 4, 6, 8, 10)
}

-- Prestige (Config.Features.Prestige; shared PrestigeData.lua, server Prestige.lua, client
-- MenuPrestige.lua + PrestigeConfirm.lua; docs/next/PRESTIGE.md). A hero with its whole
-- mastery track maxed resets those upgrade levels to 0 for a star. PROPOSED reward numbers,
-- awaiting owner approval: +5% per star of the gold a run with that hero pays into the
-- lobby at settlement (never in-run gold, so chest prices keep the GoldMult rule), max 5
-- stars = +25%. No combat power, no Robux path.
Config.Prestige = {
	MaxStars = 5, -- PROPOSED
	GoldPerStar = 0.05, -- PROPOSED
	GoldCap = 0.25, -- PROPOSED (never above MaxStars x GoldPerStar)
	ConfirmSeconds = 3, -- the PRESTIGE <HERO> button needs a second tap within this
	Rate = 2, -- "Prestige" requests per second per player (Remotes.Listen)
	CooldownSeconds = 5, -- server: at most one prestige per player this often
}

------------------------------------------------------------------------------------------
-- HEROPOWER (docs/features/HEROPOWER.md): hero ultimate (13), second signature skill (12),
-- build presets (14). Each sits behind its Config.Features switch.
------------------------------------------------------------------------------------------
-- Hero ultimate (server Ultimate.lua, client Ultimate.lua): kills charge it, the ULT button /
-- Q / R1 fires it. Damage = min(Cap, Base + PerLevel x (level - 1)) x hero Damage x Might
-- (Might counted up to MaxMight); elites, altar guards, mini-bosses and nests take at most
-- EliteShare of their max HP, bosses at most BossShare (never an instant boss kill).
Config.Ultimate = {
	KillsToCharge = 200, -- own kills for a full charge (kills made by the ultimate don't count)
	Cooldown = 60, -- run seconds between two uses, even with the kills already made
	Radius = 42, -- studs around the hero (x the hero's Radius); the Bomb pickup clears 75
	Base = 40,
	PerLevel = 8,
	Cap = 480, -- before Might and the hero's own Damage factor
	MaxMight = 2.5,
	EliteShare = 0.4,
	BossShare = 0.06,
	Knockback = 18,
	Rate = 2, -- UseUltimate requests per second per player (Remotes.Listen)
}
-- Second signature skill: one small passive per hero (CharacterData.SecondSkills), free,
-- switched on for runs once the hero's Hero Mastery reaches Rank.
Config.SecondSkill = {
	Rank = 5,
}
-- Build presets: favourite weapons / passives per hero (save field Presets, one list per
-- hero). Level-up cards of a favourite get a small tag; offers and weights never change.
Config.BuildPresets = {
	Tag = "★ Favourite",
	Rate = 6, -- SetPreset requests per second per player
}

-- Daily quests (Config.Features.DailyQuests; server DailyQuests.lua, shared QuestData.lua,
-- lobby MenuQuests.lua; docs/next/DAILY_QUESTS.md). 3 quests per UTC day, the same for
-- everyone; progress from clean runs only (never DEV / DevBoosted-tainted ones).
Config.DailyQuests = {
	Slots = { "Easy", "Easy", "Hard" }, -- the pool tier of each slot (QuestData.Quests)
	-- gold per slot: proposed, awaiting owner approval
	Rewards = { 300, 300, 600 },
	-- all three claimed: the first of these earned looks not owned yet (StoreCatalog
	-- entries, Source "Earned"); proposed, awaiting owner approval
	BonusCosmetics = { "Plate_Questor", "Trail_Questor" },
	-- the bonus once every look above is owned: proposed, awaiting owner approval
	BonusGoldAfter = 200,
	PlayMinSeconds = 60, -- "play a Duo run" / "play the daily" need this much of the run
	ToastGap = 20, -- seconds between two in-run quest notices (one player)
	Rate = 4, -- Quests remote requests per second per player
}

-- Comeback gift (Config.Features.ComebackGift; server ComebackGift.lua, lobby
-- MenuComeback.lua; docs/next/COMEBACK_GIFT.md). Joining after AwayDays+ days away (save
-- LastSeen, kept fresh while online and on leave) offers a one-time WELCOME BACK card.
Config.Comeback = {
	AwayDays = 3,
	LongDays = 7, -- this many days away or more: the long-absence gift
	-- gold: proposed, awaiting owner approval
	Gold = 500, -- 3-6 days away
	LongGold = 1000, -- 7+ days away
	-- 7+ days: this earned look too (StoreCatalog entry, Source "Earned"); proposed, awaiting owner approval
	LongCosmetic = "Trail_Homecoming",
	CosmeticOwnedGold = 250, -- the look is owned already: this gold instead (proposed, awaiting owner approval)
	CooldownHours = 72, -- at most one gift per this many hours
	MinRuns = 1, -- never for a brand-new account (finished runs before the time away)
	SeenEvery = 60, -- seconds between LastSeen refreshes while online
	Rate = 2, -- Comeback remote requests per second per player
}

return Config
