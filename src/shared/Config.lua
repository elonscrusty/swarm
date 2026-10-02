--[[
	Config.lua
	Every tunable number in SWARM lives here. Server and client both read this module,
	so changing a value here changes it everywhere on the next sync.

	Sections:
	  Run, Dev, Player, Slots, LevelUp, XP, Gold, Drops, Enemies, Difficulty, Spawn, Boss,
	  Projectiles, Net, Camera, Controls, Data, Monetization, Sounds, UI, Arenas, Modes, Lobby
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
--   Config.Arenas.Order alternates: Forest, Ruins, Forest ...) with a PORTAL at a random
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
	WeightNewPassive = 5,
	WeightEvolution = 40, -- an available evolution is almost always offered
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
	Elite = 25, -- extra gold from an elite's chest (on top of ChestGold)
	Boss = 200, -- every living player gets this each time the Scorpion Queen dies
	ChestGoldMin = 15,
	ChestGoldMax = 40,
	WinBonus = 100, -- paid when a player leaves through an open portal (a win)
	StageClearBonus = 75, -- plus this per stage cleared, on that same return
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
-- ENEMIES
------------------------------------------------------------------------------------------
Config.Enemies = {
	MaxLive = 200, -- hard cap on living enemies (must be <= PoolSize)
	PoolSize = 300, -- enemy models pre-built at server start
	EliteChance = 1 / 50,
	EliteSizeMult = 2,
	EliteHPMult = 5,
	EliteDamageMult = 1.5,
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
	HP = 9000,
	HPPerExtraPlayer = 0.6, -- x(1 + this * (players - 1))
	SpawnWarningSeconds = 5,
	ClearMinionsOnSpawn = true, -- normal enemies vanish when the boss arrives
	MinionCapDuringBoss = 60, -- regular spawning keeps this many alive during the fight
	ChaseSeconds = 3.5,
	ChargeTelegraph = 0.9,
	ChargeSpeed = 70,
	ChargeDuration = 1.1,
	RingProjectiles = 18,
	RingWaves = 3,
	RingWaveGap = 0.45,
	RingProjectileSpeed = 32,
	RingProjectileDamage = 15,
	RingProjectileRadius = 1.4,
	RingProjectileLife = 6,
	SummonCount = 8,
	SummonType = "Skeleton",
	ContactDamage = 30,
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
	SchemaVersion = 3, -- bump and add a migration step in DataService when the save shape changes
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
Config.Sounds = {
	Hit = { Id = "rbxasset://sounds/swordslash.wav", Volume = 0.25, MinGap = 0.05 },
	LevelUp = { Id = "rbxasset://sounds/electronicpingshort.wav", Volume = 0.8 },
	GemPickup = { Id = "rbxasset://sounds/clickfast.wav", Volume = 0.3, MinGap = 0.04 },
	Death = { Id = "rbxasset://sounds/collide.wav", Volume = 0.8 },
	EnemyDeath = { Id = "rbxasset://sounds/snap.mp3", Volume = 0.2, MinGap = 0.05 },
	BossRoar = { Id = "rbxasset://sounds/Launching rocket.wav", Volume = 1 },
	Explosion = { Id = "rbxasset://sounds/collide.wav", Volume = 0.6, MinGap = 0.1 },
	Chest = { Id = "rbxasset://sounds/electronicpingshort.wav", Volume = 0.7 },
	Click = { Id = "rbxasset://sounds/button.wav", Volume = 0.5 },
	Lightning = { Id = "rbxasset://sounds/Rocket shot.wav", Volume = 0.35, MinGap = 0.08 },
	LobbyMusic = { Id = "", Volume = 0.35 },
	BattleMusic = { Id = "", Volume = 0.3 },
	BossMusic = { Id = "", Volume = 0.35 },
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
	Order = { "Forest", "Ruins" },
	-- RequiredBestStage: the arena can be picked in the lobby once the player has reached
	-- this stage in a run (Stats.BestStage). Stage runs visit every arena regardless.
	Forest = { DisplayName = "Forest", RequiredBestStage = 0 },
	Ruins = { DisplayName = "Ruins", RequiredBestStage = 2 },
	Size = 400, -- square arena, centred on ArenaOrigin
	ClearRadius = 40, -- nothing collidable this close to the centre (player spawn)
	-- Layouts (landmarks, groves, paths) are designed in MapBuilder with a fixed seed per
	-- arena; obstacle coverage is kept close to the old builder (see MapBuilder header).
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
}

Config.ArenaOrigin = Vector3.new(0, 0, 0) -- floor top surface is at this height
Config.Lobby = {
	Origin = Vector3.new(1200, 0, 0), -- the castle courtyard (menu backdrop), far from the arena
	MenuFieldOfView = 55, -- FOV of the menu shot (MenuCamera attribute; portrait widens it)
}

return Config
