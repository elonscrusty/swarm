--[[
	Config.lua
	Every tunable number in SWARM lives here. Server and client both read this module,
	so changing a value here changes it everywhere on the next sync.

	Sections:
	  Run, Player, Slots, LevelUp, XP, Gold, Drops, Enemies, Difficulty, Spawn, Boss,
	  Projectiles, Net, Camera, Controls, Data, Monetization, Sounds, UI, Arenas, Lobby
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
	BossTime = 15 * 60, -- seconds into the run when the boss spawns (15:00)
	MiniWaveInterval = 30, -- a burst of extra enemies every N seconds
	ResultsSeconds = 25, -- win/lose screen time before everyone is sent back automatically
	MaxPlayers = 4, -- players per run (server MaxPlayers should match in game settings)
	ArenaSpawnSpread = 10, -- players are placed in a circle of this radius at run start
	-- A solo player who opens the pause menu freezes the whole run. In a group run the
	-- menu is only an overlay (the run keeps going), so nobody can stall a shared run.
	SoloPauseFreezesRun = true,
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
	Boss = 200, -- every surviving player gets this when the boss dies
	ChestGoldMin = 15,
	ChestGoldMax = 40,
	WinBonus = 100, -- every participant gets this on a win
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
Config.Camera = {
	Pitch = 58, -- degrees down from horizontal
	Yaw = 0, -- fixed world yaw (degrees)
	RunDistance = 64,
	LobbyDistance = 34,
	FieldOfView = 50,
	FollowSharpness = 12, -- higher = snappier follow
	PortraitDistanceMult = 1.35, -- zoom out further when the phone is held upright
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
	-- their simple one-part body (keeps phones smooth in huge swarms). The boss is
	-- always detailed.
	MaxDetailedEnemies = 110,
}

------------------------------------------------------------------------------------------
-- DATA STORE
------------------------------------------------------------------------------------------
Config.Data = {
	StoreName = "SwarmPlayerData",
	KeyPrefix = "Player_",
	SchemaVersion = 2, -- bump and add a migration step in DataService when the save shape changes
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
	MinScale = 0.55,
	MaxScale = 1.5,
	Font = Enum.Font.GothamBold,
	BodyFont = Enum.Font.Gotham,
	ToastSeconds = 3,
}

------------------------------------------------------------------------------------------
-- ARENAS AND LOBBY
------------------------------------------------------------------------------------------
Config.Arenas = {
	Order = { "Backyard", "Mall" },
	Backyard = { DisplayName = "Backyard", RequiredWins = 0 },
	Mall = { DisplayName = "Mall", RequiredWins = 1 },
	Size = 400, -- square arena, centred on ArenaOrigin
	FenceHeight = 8,
	TreeCount = 38,
	RockCount = 30,
	StorefrontCount = 14,
}
Config.ArenaOrigin = Vector3.new(0, 0, 0) -- floor top surface is at this height
Config.Lobby = {
	Origin = Vector3.new(1200, 0, 0),
	Size = 60,
	WallHeight = 6, -- low walls so the top-down camera sees over them
}

return Config
