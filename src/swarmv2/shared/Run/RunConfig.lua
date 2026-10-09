--!strict
--[[
	SwarmV2/Run/RunConfig.lua  (ReplicatedStorage.SwarmV2.Run.RunConfig)
	OWNER: gameplay track (Chat 2). Run numbers for the redesign (docs/redesign/OWNERSHIP.md).

	Sections:
	  Camera / Movement / Dash   third-person orbit camera, jump and air control, dash and leap
	                             (docs/redesign/gameplay/DESIGN.md sections 1 and 2).
	  Builds / Combat            [stream B] weapon ranks, offers, evolutions, damage rules
	                             (docs/redesign/gameplay/BUILDS.md).
	  Classes                    [stream C] the twelve class rosters and kits
	                             (docs/redesign/gameplay/CLASSES.md).
]]

export type DashDef = {
	Kind: string, -- "Dash" (straight burst) | "Leap" (ballistic arc)
	Speed: number, -- Dash: horizontal studs/s
	Duration: number, -- Dash: seconds of burst (Leap: computed from Horizontal and Apex)
	Cooldown: number, -- seconds
	Horizontal: number?, -- Leap: horizontal distance in studs
	Apex: number?, -- Leap: peak height in studs
}

local RunConfig = {}

------------------------------------------------------------------------------------------
-- CAMERA / MOVEMENT / DASH
------------------------------------------------------------------------------------------
RunConfig.Camera = {
	Distance = 22, -- studs behind the focus
	MinDistance = 16, -- pinch / wheel limits
	MaxDistance = 28,
	FocusHeight = 2.5, -- focus = root + (0, FocusHeight, 0), about the upper torso
	Pitch = 22, -- degrees down, default
	MinPitch = 8,
	MaxPitch = 70,
	FieldOfView = 70, -- vertical FOV of the run camera
	FollowSharpness = 20, -- focus smoothing (higher = snappier)
	CollisionRadius = 0.6, -- spherecast radius
	MinCollisionDistance = 3, -- the camera never gets closer to the focus than this
	PullInRate = 40, -- 1/s: how fast the camera pulls in when something is in the way
	EaseOutRate = 3, -- 1/s: how slowly it eases back out
	IgnoreTag = "CameraIgnore", -- CollectionService tag: never blocks the camera
	-- folders whose parts never block the camera (enemies, loot, effects)
	IgnoreFolders = {
		"SwarmEnemies", "SwarmEnemyModels", "SwarmLoot", "SwarmGems", "SwarmPickups", "SwarmClientFx",
		"SwarmCombatFx", "SwarmTelegraphs", "SwarmDamageNumbers", "SwarmGroundDetail", "SwarmTeamFx",
		"WorldFx", "WorldFxClient", "SwarmHazardOutlines", "SwarmStoreFx", "SwarmStorePlates",
		"WalkthroughMarker", "PortalFx", "Projectiles", "SwarmProjectiles",
	} :: { string },
	-- input
	TouchZone = 0.45, -- the left share of the screen is the move stick, the rest orbits the camera
	TouchSensitivity = 0.0050, -- radians per pixel
	MouseSensitivity = 0.0035,
	GamepadRate = 2.6, -- radians per second at full right-stick
	GamepadDeadZone = 0.15,
	WheelStep = 2, -- studs per wheel notch
	MouseLockKey = Enum.KeyCode.LeftControl, -- toggle mouse-look (Shift is the dash key)
	-- recenter (touch, gamepad): yaw eases behind the move direction after no camera input
	RecenterDelay = 1.25, -- seconds
	RecenterRate = 2.2, -- radians per second
	RecenterRateReduced = 0.8, -- reduced motion
	RecenterMinDot = 0.35, -- only while moving at least this much "forward" relative to the camera
	DashFovKick = 6, -- degrees of extra FOV at the start of a dash (off in reduced motion)
}

RunConfig.Movement = {
	JumpApex = 9, -- studs, JumpPower = sqrt(2 * gravity * apex)
	JumpApexByClass = { toastmaster = 12 } :: { [string]: number },
	AirControl = 0.65, -- [stream E1] share of the live stick that steers in the air (the rest is the takeoff direction)
}

RunConfig.Dash = {
	Default = { Kind = "Dash", Speed = 70, Duration = 0.22, Cooldown = 2.5 } :: DashDef,
	-- per class (canonical ids) [stream C: the continuation brief's class movement]
	Variants = {
		-- Granny: rocket boost 80 studs/s for 0.25 s, cooldown 3 s
		granny_boom = { Kind = "Dash", Speed = 80, Duration = 0.25, Cooldown = 3.0 },
		-- Croak: a leap, ballistic arc ~30 studs forward over ~0.45 s (apex 5 = 2 sqrt(2 x 5 / 196.2)
		-- = 0.45 s at the default gravity), cooldown 3 s; the normal jump is unchanged
		captain_croak = { Kind = "Leap", Speed = 0, Duration = 0.45, Cooldown = 3.0, Horizontal = 30, Apex = 5 },
		-- Crash: the body-check dash, the shared dash with a 2.20 s cooldown
		crash_cassidy = { Kind = "Dash", Speed = 70, Duration = 0.22, Cooldown = 2.2 },
	} :: { [string]: DashDef },
	AllowMult = 1.15, -- speed check allows DashSpeed * this
	LeapAllowMult = 1.2, -- ... for a leap's horizontal speed
	AllowTail = 0.25, -- seconds after the dash that the speed check still allows it
	WallMargin = 0.8, -- studs: the client stops this far before a wall
	AckTimeout = 0.7, -- the client gives up waiting for the server's answer
	RequestRate = 3, -- requests per second per player (token bucket, burst 3)
	CooldownSlack = 0.08, -- seconds of clock difference the server forgives
	LandMinAirtime = 0.35, -- Dash.OnLanded only fires after this long in the air
	LeapLandMinAirtime = 0.15, -- Dash.OnLeapLanded after a leap
	GroundProbe = 1.2, -- studs under the feet that still count as grounded
	LandCheckHz = 30,
}

------------------------------------------------------------------------------------------
-- GROUND HEIGHT + NAVIGATION
------------------------------------------------------------------------------------------
RunConfig.Nav = {
	GroundTag = "NavGround", -- CollectionService tag: floors, terraces, ramps, bridge decks, cave floors
	BlockTag = "NavBlock", -- tag (on a part or its model): cliff faces, water, gaps; never walkable
	CellSize = 4, -- studs per grid cell
	StepMax = 3.2, -- most height change between neighbour cells (per 4 studs, about 38 degrees)
	MaxCells = 160000, -- safety cap on the grid size (1100 x 1100 studs at 4 = ~76k)
	RayPad = 20, -- the down rays start this far above the highest tagged part
	-- flow fields (one Dijkstra fill per living run player)
	FieldRadius = 72, -- cells (288 studs)
	FieldRebuild = 0.25, -- seconds between starting field rebuilds (round robin, one player each)
	FieldBudget = 6000, -- cells settled per server frame while a field builds (spreads the cost)
	-- enemy steering (EnemyAI.think)
	DirectSeekRange = 10, -- closer than this with a steppable straight line: seek directly
	-- vertical bands (|dy| between ground heights)
	ContactBand = 6, -- enemy contact damage
	HitBand = 7, -- weapon hits and weapon targeting (a weapon's Params.HitBand overrides)
	HazardBand = 6, -- enemy ground strikes, patches and waves
	RootHeight = 3, -- a standing hero's root above the ground
	-- spawning (EnemySpawner.SpawnPoint)
	SpawnMinPath = 45, -- path distance from the hero, studs
	SpawnMaxPath = 80,
	SpawnTries = 10,
	-- fall rescue (RunManager): below GroundY - RescueBelow, back to the last good ground spot
	RescueBelow = 40,
	SafeAbove = 8, -- a root at most this high above the ground counts as standing on it
}

------------------------------------------------------------------------------------------
-- CLIFFWOOD BASIN MAP
------------------------------------------------------------------------------------------
RunConfig.Map = {
	MapName = "Cliffwood", -- the single-map arena
	SingleMap = true, -- false: every stage builds its own arena as before
	BossLandmark = "Stone Circle", -- portal landmark of stage 5 and the Endless boss-milestone stages
	TransitionSeconds = 0.7, -- the burst effect plays, then the old stage is cleared and the new one placed
	PortalLandmarkMargin = 14, -- portal spot stays this far inside the landmark radius
	ChestMult = 2.5, -- chests per stage x this on the big map (loot every 10-15 s of travel)
}

------------------------------------------------------------------------------------------
-- CLASS KITS  [stream C] (continuation brief "Twelve approved classes"; docs/redesign/gameplay/CLASSES.md)
------------------------------------------------------------------------------------------
--[[
	The twelve classes: roster numbers (price, start weapon, HP / speed / crit modifiers, unlock goal,
	Hero Mastery signature) and every kit number (passives and movement hooks). Damage coefficients
	(`Coeff`) are multiples of B and go through the shared rank formula with the rank of the class
	signature (WeaponSystem.KitBurst / Damage). Hook cooldowns ignore attack speed. H0 = the normal
	player maximum HP (Config.Player.BaseMaxHP, 120): `maxHpMult` -0.10 = 0.90 H0.
	Code: ClassRoster (shared, roster), ClassKits (server, kits), WeaponSystem (signature behaviours).
]]
export type ClassGoal = {
	Stat: string, -- data.Stats.ClassGoals key (DECISIONS C3)
	Need: number,
	Text: string,
	Any: { { Stat: string, Need: number } }?, -- Knuckles: any one of these (boss OR revive)
}

RunConfig.Classes = {
	-- ids of the playable classes, in roster order (also the lobby's ClassCatalog.Order)
	Order = {
		"ruckus", "toastmaster", "captain_croak", "granny_boom",
		"coach_crunch", "doug_janitor", "peter_parkour", "barry_plotter",
		"rambozo", "swolverine", "crash_cassidy", "knuckles_mcgee",
	},
	Default = "ruckus",
	-- A run whose selected hero is one of the 11 hidden old heroes plays the Default class instead
	-- (safety net for saves that still select one). Tests of the old heroes switch it off.
	MapLegacyToDefault = true,

	--[[
		Roster (shape of CharacterData.Characters; ClassRoster copies it). Cost = gold (0 = free for
		ruckus; the first four keep the owner's prices, DECISIONS C2). Goal = the pack's earnable
		goal ({Stat, Need, Text}, counted by stream E2 into data.Stats.ClassGoals, granted by the lobby
		track's ClassOwnership.RefreshEarned); the 8 newer classes have NO gold price (GoalOnly: their
		CharacterData entry gets Unlock = { Goal = ... }, which the old buy path refuses). Bonus keys
		= StatSheet bonus keys: maxHpMult (x H0), pickupFlat (studs). BaseSpeed = walking speed
		(studs/s; Config.Player.BaseSpeed 22 when absent). CritBase = base crit chance (default 5 %).
		Signature = the Hero Mastery upgrade (account progression, 5 levels, nothing innate: Base 0).
	]]
	Roster = {
		ruckus = {
			Cost = 0,
			StartWeapon = "ScrapToss",
			Bonus = {},
			Signature = { Base = 0, Per = 4, PerLevel = { pickup = 0.04 } },
		},
		toastmaster = {
			Cost = 10000,
			StartWeapon = "ToastVolley",
			Bonus = { maxHpMult = -0.10 }, -- 0.90 H0
			Goal = { Stat = "XP", Need = 300, Text = "Collect 300 XP in runs" },
			Signature = { Base = 0, Per = 3, PerLevel = { maxHpMult = 0.03 } },
		},
		captain_croak = {
			Cost = 20000,
			StartWeapon = "BubbleBomb",
			Bonus = {},
			Goal = { Stat = "Distance", Need = 3000, Text = "Travel 3,000 studs in runs" },
			Signature = { Base = 0, Per = 2, PerLevel = { growth = 0.02 } },
		},
		granny_boom = {
			Cost = 30000,
			StartWeapon = "YarnBomb",
			Bonus = { maxHpMult = 0.10 }, -- 1.10 H0
			BaseSpeed = 20,
			Goal = { Stat = "Elites", Need = 3, Text = "Defeat 3 elite enemies" },
			Signature = { Base = 0, Per = 3, PerLevel = { area = 0.03 } },
		},
		coach_crunch = {
			GoalOnly = true,
			StartWeapon = "Dodgeball",
			Bonus = {},
			Goal = { Stat = "BestSurvive", Need = 180, Text = "Survive 3 minutes in one run" },
			Signature = { Base = 0, Per = 2, PerLevel = { speed = 0.02 } },
		},
		doug_janitor = {
			GoalOnly = true,
			StartWeapon = "MopSweep",
			Bonus = { maxHpMult = 0.10, pickupFlat = 4 }, -- 1.10 H0; Clean Route +4 studs pickup
			Goal = { Stat = "Chests", Need = 5, Text = "Open 5 reward chests" },
			Signature = { Base = 0, Per = 4, PerLevel = { pickup = 0.04 } },
		},
		peter_parkour = {
			GoalOnly = true,
			StartWeapon = "ReturningSneakers",
			Bonus = { maxHpMult = -0.05 }, -- 0.95 H0
			Goal = { Stat = "Dashes", Need = 30, Text = "Dash 30 times" },
			Signature = { Base = 0, Per = 2, PerLevel = { speed = 0.02 } },
		},
		barry_plotter = {
			GoalOnly = true,
			StartWeapon = "SeedSlinger",
			Bonus = {},
			Goal = { Stat = "MostWeapons", Need = 3, Text = "Hold 3 different weapons in one run" },
			Signature = { Base = 0, Per = 3, PerLevel = { area = 0.03 } },
		},
		rambozo = {
			GoalOnly = true,
			StartWeapon = "ConfettiMinigun",
			Bonus = {},
			Goal = { Stat = "Kills", Need = 300, Text = "Defeat 300 enemies" },
			Signature = { Base = 0, Per = 1, PerLevel = { critChance = 0.01 } },
		},
		swolverine = {
			GoalOnly = true,
			StartWeapon = "ProteinClaws",
			Bonus = { maxHpMult = 0.15 }, -- 1.15 H0
			CritBase = 0, -- base critical chance zero
			Goal = { Stat = "CloseKills", Need = 100, Text = "Defeat 100 enemies up close" },
			Signature = { Base = 0, Per = 3, PerLevel = { maxHpMult = 0.03 } },
		},
		crash_cassidy = {
			GoalOnly = true,
			StartWeapon = "RicochetPuck",
			Bonus = { maxHpMult = -0.10 }, -- 0.90 H0
			Goal = { Stat = "Distance", Need = 10000, Text = "Travel 10,000 studs in runs" },
			Signature = { Base = 0, Per = 2, PerLevel = { speed = 0.02 } },
		},
		knuckles_mcgee = {
			GoalOnly = true,
			StartWeapon = "GloveCombo",
			Bonus = {},
			Goal = {
				Stat = "Bosses",
				Need = 1,
				Any = { { Stat = "Bosses", Need = 1 }, { Stat = "Revives", Need = 1 } },
				Text = "Defeat a boss or revive a teammate",
			},
			Signature = { Base = 0, Per = 3, PerLevel = { maxHpMult = 0.03 } },
		},
	} :: { [string]: any },

	-- CloseKills (stream E2, ClassGoals): the melee signatures carry WeaponData Melee = true; dash
	-- effects (cans, tackle, body-check, balloon) are credited to a source with Dash = true and the
	-- landing blast to one with Close = true (WeaponSystem.KitBurst).

	-- server-measured horizontal speed (Warm-Up, Stride, Momentum): studs moved over this window
	SpeedWindow = 0.25,

	-- Ruckus, Junk Collector: chest / item rewards (not XP shards) charge it; the next Scrap Shot
	-- becomes a barrage of Shots projectiles (Coeff each, the weapon's bounces), consuming one charge.
	JunkCollector = { RewardsPerCharge = 5, MaxStored = 1, Shots = 3, Coeff = 0.60, Spread = 10 },
	-- Ruckus, dash: rolling cans; each explodes after Fuse for Coeff in Radius; one can hit per target
	-- per dash (one cast ledger per dash)
	DashCans = { Count = 2, Fuse = 0.90, Radius = 5, Coeff = 0.40, RollSpeed = 16, SpreadDegrees = 35, MaxLive = 4 },

	-- Toastmaster, Overheat: Hits direct toast hits on one target within Window s = scorch, counter reset
	Overheat = { Hits = 3, Window = 5, ScorchMult = 1 },
	-- Toastmaster, spring jump landing blast (apex 12: RunConfig.Movement.JumpApexByClass). Only a
	-- landing after an intentional jump (the server saw the root rise faster than JumpRiseSpeed studs/s,
	-- at most JumpMaxAir s before the landing; stairs, slopes, falls, launch pads and rescues never count).
	LandingBlast = { MinAirtime = 0.35, Radius = 6, Coeff = 0.35, Cooldown = 2, JumpRiseSpeed = 30, JumpMaxAir = 3 },

	-- Captain Croak, Big Splash: a leap landing within EnemyRange of a living enemy stores one
	-- empowered bubble (+30 % burst damage), expiring after Expiry s. The leap: RunConfig.Dash.Variants.
	BigSplash = { EnemyRange = 10, DamageMult = 1.30, RadiusMult = 1.0, MaxStored = 1, Expiry = 6 },

	-- Granny Boom, Tangled Up: yarn damage slows 35 % for 0.75 s (refresh only, strongest slow kept;
	-- bosses capped at RunConfig.Combat.BossSlowCap 10 %). Her rocket boost: RunConfig.Dash.Variants.
	TangledUp = { Slow = 0.35, Seconds = 0.75 },

	-- Coach Crunch, Warm-Up: Seconds above Speed studs/s charges it; the shoulder-tackle dash hits up
	-- to MaxTargets enemies once (ChargedCoeff charged, Coeff uncharged) with a Stagger (immunity rules)
	WarmUp = { Speed = 18, Seconds = 2 },
	Tackle = { ChargedCoeff = 0.60, Coeff = 0.30, MaxTargets = 4, Stagger = 0.25, HitRadius = 3 },

	-- Doug the Janitor, Clean Route: +4 studs pickup (Roster Bonus pickupFlat; shards are personal).
	-- Dash: a Length-stud wet trail along the dash for Seconds: Slow on enemies within Width studs, no damage
	WetTrail = { Length = 16, Seconds = 2, Slow = 0.25, Width = 3, Tick = 0.2 },

	-- Peter Parkour, Stride: Seconds continuously above Speed studs/s charges it; the next signature
	-- attack deals +DamageBonus (additive damage bonus, inside the 0..2 clamp); expires after Expiry s.
	Stride = { Speed = 20, Seconds = 2, DamageBonus = 0.30, Expiry = 6 },
	-- Peter, charged jump (client JumpController): a jump reaches Apex studs once per Cooldown s
	ChargedJump = { peter_parkour = { Apex = 11, Cooldown = 6 } } :: { [string]: { Apex: number, Cooldown: number } },

	-- Barry Plotter, Garden Company: plants within Range of Barry deal +DamageBonus (additive).
	-- Dash: one extra seed planted at the dash origin, once per Cooldown s (shares the plant cap).
	GardenCompany = { Range = 12, DamageBonus = 0.15 },
	DashSeed = { Cooldown = 6 },

	-- Rambozo, Punchline: +CritBonus crit chance against enemies above HpShare of their max HP.
	Punchline = { HpShare = 0.70, CritBonus = 0.10 },
	-- Rambozo, dash: one balloon grenade at the dash origin: Fuse, then Coeff in Radius, then MiniCount
	-- mini-pops (MiniCoeff, MiniRadius, MiniOffset studs out, MiniDelay later; each target takes at most
	-- one mini-pop of a grenade; mini-pops never explode again)
	BalloonGrenade = { Fuse = 0.80, Radius = 6, Coeff = 0.40, MiniCount = 2, MiniCoeff = 0.15, MiniRadius = 3, MiniOffset = 3.5, MiniDelay = 0.2 },

	-- Swolverine, Gains: HealShare of max HP after every KillsPerHeal credited kills, at most one heal
	-- per MinGap s (extra heals wait, at most MaxBanked).
	Gains = { KillsPerHeal = 10, HealShare = 0.01, MinGap = 1, MaxBanked = 5 },
	-- Swolverine, dash recovery: +DamageBonus for Seconds after a dash ends (refreshed, never stacked)
	DashRecovery = { DamageBonus = 0.15, Seconds = 2 },

	-- Crash Cassidy, Momentum: +0..MaxBonus weapon damage as horizontal speed rises MinSpeed..MaxSpeed
	Momentum = { MinSpeed = 12, MaxSpeed = 30, MaxBonus = 0.15 },
	-- Crash, body-check dash (cooldown 2.20: RunConfig.Dash.Variants): Coeff once to each of at most
	-- MaxTargets enemies touched, Knock studs/s (normal enemies; elites half, bosses none)
	BodyCheck = { Coeff = 0.35, MaxTargets = 4, Knock = 20, HitRadius = 3 },

	-- Knuckles McGee, Heavy Hands: x KnockMult knockback on normal enemies (inside the shared cap).
	HeavyHands = { KnockMult = 1.25 },
	-- Knuckles, close dodge: a dash ending within Range studs of an enemy adds one Glove Combo charge
	CloseDodge = { Range = 6 },
}

------------------------------------------------------------------------------------------
-- RUN ENTRY + ADMISSION
------------------------------------------------------------------------------------------
RunConfig.Entry = {
	Arena = "Cliffwood", -- the run map (falls back to the lobby's arena until it exists)
	GroupWaitSeconds = 20, -- after the first admitted arrival
	LateGraceSeconds = 60, -- after the run starts, for missing expected players
	ProfileWaitSeconds = 30, -- save load before admission gives up
	ResolveRetryDelays = { 1, 2, 4 }, -- transient admission failures
	RetryAttempts = 1, -- the lobby advises one more call on a recoverable error
	-- MatchAdmission errors worth one more try (docs/redesign/lobby/HANDOFF.md section 5);
	-- every other code is final: show the message, then return to the lobby
	RetryCodes = { "STORE_UNAVAILABLE", "PROFILE_UNAVAILABLE", "TIMEOUT", "ADMISSION_ERROR" },
	RejectShowSeconds = 4, -- the reason stays on screen this long before the return
	ReturnAttempts = 2,
}

------------------------------------------------------------------------------------------
-- CONTINUATION PACK sections (docs/redesign/continuation/GAMEPLAY_PLAN.md): one per stream
------------------------------------------------------------------------------------------
--[[
	[stream B] BUILDS: weapon ranks 1-5, the 15-weapon catalog, 8 loot passives, offers and evolutions
	(continuation brief "Progression and personal choices", "Twelve approved classes", "Eight
	original loot passives"; docs/redesign/gameplay/BUILDS.md). Pure rules: SwarmV2.Run.BuildRules.
	Enabled = false switches the whole run back to the old 12-level system (6 + 6 slots, old weights,
	every old weapon / passive / synergy offered): only for the regressions of the old content.

	Baselines (audited, BUILDS.md): B = 10 = the ordinary starter damage before upgrades (Knight's
	Sword level 1 and Ruckus's Scrap Toss level 1 both dealt 10). H0 = Config.Player.BaseMaxHP (120),
	the normal player maximum HP; class HP modifiers multiply it (RunConfig.Classes, stream C).
]]
RunConfig.Builds = {
	Enabled = true,
	B = 10, -- weapon / enemy HP coefficients multiply this
	MaxRank = 5,
	RankDamageStep = 0.20, -- hit = B x coeff x (1 + 0.20 (r - 1)) x (1 + additive damage bonus)
	RankIntervalMult = 0.95, -- interval = base x 0.95^(r - 1) / (1 + attack speed bonus)
	WeaponSlots = 4, -- the class signature is weapon slot 1 (protected, never replaced)
	PassiveSlots = 4,
	Choices = 3, -- at most this many distinct options per offer
	-- category weights (empty categories are removed and the rest renormalised; uniform inside)
	CategoryWeights = { WeaponUpgrade = 45, PassiveUpgrade = 35, NewWeapon = 12, NewPassive = 8 },
	CategoryOrder = { "WeaponUpgrade", "PassiveUpgrade", "NewWeapon", "NewPassive" },
	-- rank grant by rarity (tiers past the item's remaining capacity are removed, then renormalised)
	Rarities = {
		{ Name = "Common", Ranks = 1, Weight = 70, Label = "Common", Color = Color3.fromRGB(205, 210, 220) },
		{ Name = "Uncommon", Ranks = 2, Weight = 23, Label = "Uncommon", Color = Color3.fromRGB(90, 200, 110) },
		{ Name = "Rare", Ranks = 3, Weight = 6, Label = "Rare", Color = Color3.fromRGB(80, 160, 255) },
		{ Name = "Epic", Ranks = 4, Weight = 1, Label = "Epic", Color = Color3.fromRGB(190, 90, 255) },
	},
	EvolutionLabel = "Evolution",
	EvolutionColor = Color3.fromRGB(255, 200, 40),
	-- evolutions: player level >= EvolutionLevel, weapon rank 5, the partner passive at rank 3
	EvolutionLevel = 8,
	EvolutionWeaponRank = 5,
	EvolutionPassiveRank = 3,
	-- the only evolutions offered (the four signature recipes; every other recipe stays as data)
	Evolutions = { "ScrapToss", "ToastVolley", "BubbleBomb", "YarnBomb" },
	HealShare = 0.10, -- exhausted pool: one card healing this share of max HP (living heroes only)
	-- personal choices: one at a time from a queue. Live (a team run): the world and the chooser keep
	-- going, no protection, ChoiceSeconds per choice. Solo: kept as before the pack (the world
	-- freezes while choosing, the longer solo timer), documented in BUILDS.md.
	ChoiceSeconds = 10,
	SoloChoiceSeconds = 25,
	RerollsPerPanel = 1,
	FreeRerolls = 2, -- per run, on top of the existing VIP pass rerolls and account Reroll upgrade
	HideSynergies = true, -- SynergyData sets give nothing and are never hinted while Enabled
}

--[[
	[stream B] COMBAT: shared damage rules (WeaponSystem.Damage, HasLineOfSight, NearestTarget).
	Crit and proc rolls are server-side. Status damage never crits; secondaries never proc.
]]
RunConfig.Combat = {
	DamageBonusMax = 2.0, -- additive damage bonus clamp (0..2), class bonuses included
	AttackSpeedMax = 1.0, -- attack speed bonus clamp (0..1)
	MinInterval = 0.25, -- seconds, no weapon attacks faster
	CritBase = 0.05,
	CritMax = 0.50,
	CritMult = 1.75, -- critical direct damage
	ArmorMax = 100, -- armor A reduces damage by A / (100 + A), A clamped 0..100
	-- targeting: nearest living hostile in range with line of sight, ties by enemy Uid
	Retarget = 0.15, -- seconds between re-picks
	TargetHold = 0.30, -- a still-valid target is kept at least this long
	LeadMaxSeconds = 0.25, -- projectile aim prediction: at most this much of the flight time ...
	LeadMaxStuds = 3, -- ... and at most this many studs
	LOSHeight = 2.5, -- sight line height above the ground at both ends
	LOSStep = 2, -- studs between ground samples along a sight line
	LOSTolerance = 0.5, -- ground may rise this far above the line before it blocks
	LOSMaxChecks = 8, -- sight-line tests per target pick (bounded search)
	-- statuses
	ScorchDpsB = 0.12, -- scorch: 0.12 B per second ...
	ScorchSeconds = 3, -- ... for 3 s, refreshed (strongest source kept, never stacked)
	ScorchTick = 0.5,
	SlowCap = 0.40, -- strongest slow only, at most 40 % slower
	BossSlowCap = 0.10,
	KnockbackCap = 24, -- horizontal knockback speed per target, studs/s
	EliteKnockMult = 0.5,
	StaggerImmunity = 1.5, -- seconds a normal enemy cannot be staggered again
	EliteStaggerMax = 0.15,
	-- secondary effects (bounces, bursts, pulses, splinters, fragments)
	SecondaryPerSecond = 10, -- per-player emission cap (token bucket, burst 10)
	MaxChainDepth = 2, -- a primary hit (0) may emit (1); only documented finite chains reach 2
	-- Splinter Badge: two splinters at different visible enemies within this range
	SplinterRange = 8,
	SplinterCoeff = 0.15,
	SplinterCount = 2,
}
--[[
	[stream D] RUN DIRECTOR (docs/redesign/DECISIONS.md C5; brief "Enemy pressure and final objective").
	One 15-minute run on the single map (Map.MapName) replaces the 5-stage portal loop:
	  Survive -> (12:30) BeaconAvailable -> Rally (30 s) -> Charge (60 s, r35) -> Boss -> Victory,
	  or Defeat on a full wipe. Overtime (past RunMinutes) only ramps the spawn rate.
	StageManager runs the phases, Beacon.lua the beacon, EnemySpawner the pressure, BossAI the
	Basin Breaker. Every number below is a proposed default from the brief and can be changed.
	B / H0: the brief's baselines (weapon/enemy HP coefficients x B, player damage x H0).
	  B  = Builds.B (stream B, 10 = the starter damage), else Combat.B, else DefaultB
	  H0 = Builds.H0 / Survival.H0 when set, else Config.Player.BaseMaxHP (120, the existing
	       normal player maximum HP)
]]
RunConfig.Director = {
	Enabled = true,
	-- true: the single map plays the old 5-stage portal loop again (other arenas always do)
	LegacyStages = false,
	-- tests only: the director clock runs this many times faster. Honoured in Studio only
	-- (RunService:IsStudio(), the preview runs with --studio); live servers always use 1.
	TimeScale = 1,
	RunMinutes = 15, -- the target length; past it the overtime ramp starts (no timer defeat)
	DefaultB = 10,

	-- the final objective (Beacon.lua)
	Beacon = {
		RevealAt = 750, -- seconds of director clock (12:30)
		Landmark = "Stone Circle", -- arena.Landmarks name; the landmark centre on the ground
		ActivateRadius = 20, -- a living, non-downed hero this close activates it (once)
		RallySeconds = 30, -- warning broadcast before the charge starts
		ChargeSeconds = 60, -- charge time with at least one living hero inside ChargeRadius
		ChargeRadius = 35,
		HeightBand = 8, -- |dy| of ground heights that still counts as "at the beacon"
		PromptHold = 0.5, -- the ProximityPrompt hold (E / touch); TryActivate checks the rules
		PublishStep = 0.01, -- BeaconCharge attribute resolution
	},

	-- party size N (1..Max): initialised heroes at start, raised by late admissions, never lowered
	Party = {
		Max = 4,
		HPPerExtra = 0.30, -- ordinary HP x (1 + 0.30 (N-1))
		DamagePerExtra = 0.10, -- contact / attack damage x (1 + 0.10 (N-1)); the boss too
		SpawnPerExtra = 0.45, -- spawn rate x (1 + 0.45 (N-1))
	},
	-- t = director minutes at the enemy's spawn (living enemies are never rescaled)
	Time = {
		HPPerMinute = 0.07, -- ordinary HP x (1 + 0.07 t)
		DamagePerMinute = 0.025, -- damage x (1 + 0.025 t)
	},
	Spawn = {
		Base = 0.60, -- enemies/s at t = 0 ...
		PerMinute = 0.14, -- ... + this per minute
		OvertimePerMinute = 0.10, -- past RunMinutes: rate x min(OvertimeCap, 1 + 0.10 (t - 15))
		OvertimeCap = 1.5,
		AliveCaps = { 55, 95, 145, 200 }, -- ordinary enemies alive by N (perf limits to test)
		MinDistance = 35, -- spawn ring around a living hero (flat studs) ...
		MaxDistance = 70,
		MaxPathFactor = 2.0, -- reachable: walking distance (flow field) at most this x MaxDistance
		Tries = 12,
		TickSeconds = 0.25, -- spawn checks per second = 4
		MaxPerTick = 6,
		MaxBank = 3, -- budget kept while capped / no spot (no burst when room opens)
		BossRateMult = 0.5, -- during the boss fight
		BossCapMult = 0.5,
	},
	Elite = {
		FromMinute = 5,
		Chance = 0.05, -- share of spawns
		HPMult = 3, -- x the archetype HP
		DamageMult = 1.25,
		Affixes = false, -- true: the old elite affixes (Swift / Shielded / Burning) as well
	},
	--[[
		Roster of the single map (other EnemyData types are kept but never spawned there).
		HP x B, Contact / Attack x H0; Kind is the XP / gold tag (Normal / Tough / Elite / Boss).
		The attack timings live in EnemyData (FloatingEye / SapLobber Ranged, StumpBrute Slam).
		Contact values marked "proposed" are not in the brief.
	]]
	Roster = {
		{ Type = "Skeleton", Name = "Beetle", FromMinute = 0, Weight = 60, HP = 2, Speed = 14, Contact = 0.05, ContactCooldown = 0.8, Kind = "Normal" },
		{ Type = "FloatingEye", FromMinute = 0, Weight = 25, HP = 3, Speed = 10, Contact = 0.02, Attack = 0.07, Kind = "Normal" }, -- contact proposed
		{ Type = "RootRunner", FromMinute = 2, Weight = 30, HP = 1.5, Speed = 20, Contact = 0.04, Kind = "Normal" },
		{ Type = "StumpBrute", FromMinute = 4, Weight = 14, HP = 5, Speed = 8, Contact = 0.05, Attack = 0.10, Kind = "Tough" }, -- contact proposed
		{ Type = "SapLobber", FromMinute = 6, Weight = 16, HP = 3, Speed = 9, Contact = 0.02, Attack = 0.06, Kind = "Normal" }, -- contact proposed
	} :: { any },
	-- stuck enemies (EnemyAI): no progress for CheckSeconds -> a short sideways repath, at most
	-- Repaths times, then a quiet despawn (no rewards)
	Stuck = {
		CheckSeconds = 3,
		MinMove = 2, -- studs moved per check while trying to walk
		NearTarget = 12, -- closer than this to its hero: crowding, never "stuck"
		Repaths = 2,
		RepathSeconds = 1.2,
	},
	--[[
		Rewards on a director run (the brief: elites pay team gold and XP, chests are bought with team
		gold and give passive choices; nothing grants the old run items):
		  EliteFloorChest = false   no free chest from an elite kill (its Sigil roll stays)
		  OptionalLocations = false no guarded altar, runes, treasure or caravan; no Shrine of Chance
		                            or Bargain; no chest variants (cursed chests) (LootSystem)
		  Encounters                the feature encounters that may start (EncounterDirector); the
		                            others (merchant, mini-boss, secret room, cursed chests) grant old
		                            items. The villager rescue pays one passive choice per recipient
		                            and is delivered to the Stone Circle (the beacon's landmark).
	]]
	Rewards = {
		EliteFloorChest = false,
		OptionalLocations = false,
		Encounters = { "Rescue", "Weather", "MapEvents", "TrialShrine" } :: { string },
	},
	-- the Basin Breaker (BossData BasinBreaker): HP = HPB x B x [1 + 0.80 (N-1)] x [1 + 0.07 t]
	Boss = {
		Id = "BasinBreaker",
		HPB = 200,
		HPPerExtra = 0.80,
		HPPerMinute = 0.07,
		Contact = 0.10, -- walking into it, x H0 x party damage (proposed; attacks in BossData)
		SpawnDistance = 22, -- from the beacon, on walkable ground
		SlowCap = 0.10, -- every boss: slows take at most 10% of its speed (no knockback, no stun)
	},
}
-- [stream E1] downed, revive, protection, falls, disconnects, movement feel
-- (server RunManager "HP, death, revive" / fallRescue / speedCheck / reconnect sections, Dash.lua
-- landings; client JumpController, MobileControls, DashClient, ReviveHoldClient; pure maths in
-- SurvivalRules.lua). Base move speed stays Config.Player.BaseSpeed (22), jump height
-- RunConfig.Movement.JumpApex (9) and air steering RunConfig.Movement.AirControl (0.65).
RunConfig.Survival = {
	Downed = {
		BleedSeconds = 20, -- downed this long (while the world runs), then eliminated
		ReviveSeconds = 3, -- a living teammate holds interact this long, uninterrupted
		ReviveRange = 8, -- studs between the reviver's and the downed hero's roots
		ReviveHPShare = 0.25, -- revived with this share of max HP
		ReviveProtectSeconds = 1, -- no damage this long after a teammate revive (ReviveProtectUntil)
		HoldFreshSeconds = 0.6, -- a held revive the client stopped refreshing counts as released
		HoldRate = 12, -- "ReviveHold" remote calls per second per player
		HoldRefresh = 0.25, -- the client re-sends a held revive this often
	},
	-- one shared protection window after an ordinary incoming hit (any attacker, any kind but falls
	-- and rescues); it never stacks per attacker (HitProtectUntil)
	HitProtectSeconds = 0.35,
	-- an open upgrade / reward panel grants no protection (live menus never pause the world)
	MenuProtection = false,
	Fall = {
		SafeDrop = 18, -- studs from the highest point of the fall: no damage below this
		PerStud = 0.02, -- share of max HP per stud past SafeDrop
		MaxShare = 0.35, -- most damage of one landing
	},
	Rescue = {
		MaxHPShare = 0.10, -- an out-of-bounds rescue costs at most this share of max HP (never downs)
		LockoutSeconds = 3, -- no damage this long after a rescue (rescue costs included)
	},
	Disconnect = {
		WindowSeconds = 60, -- a living hero who drops keeps their state this long
		ReturnProtectSeconds = 2, -- no damage this long after coming back
	},
	Move = {
		AccelSeconds = 0.18, -- standing to full speed (client move driver)
		DecelSeconds = 0.15, -- full speed to standing after release
		BufferSeconds = 0.10, -- a jump pressed this long before landing still jumps
		CoyoteSeconds = 0.10, -- a jump this long after walking off an edge still jumps
		JumpCooldown = 0.2, -- minimum time between two jumps (no double jumps)
		-- no jump this long after a landing (a press buffered into it fires when it ends); the Spring
		-- Stitch passive shortens it (Player attribute LandLockReduce, stream B)
		LandLockSeconds = 0.12,
		HorizontalCap = 34, -- studs/s, outside dashes and explicit class boosts (RunManager.SetSpeedBoost)
		ServerTolerance = 1.3, -- server speed check slack on top of the allowed speed (lag, pushes)
		SpeedAllowance = 6, -- studs per check window on top of that
		DashSlopeRise = 0, -- upward studs/s a ground dash may gain (no ramp launches)
	},
}
-- [stream E2] XP shards, team run gold, chests, class goals (DECISIONS C3, C7, C9). Read by
-- XPSystem, GoldSystem, LootSystem, ItemSystem and SwarmV2/Run/ClassGoals.
RunConfig.Economy = {
	-- false: the old economy (shared gems, the Config.XP curve, chests paid from the personal
	-- escrow with an item inside). Tests of the old rules switch it off.
	Enabled = true,
	XP = {
		-- XP needed from level L to L+1 = Base + Linear (L-1) + Quad (L-1)^2  (20, 35, 56, 83, 116, ...)
		Base = 20,
		Linear = 12,
		Quad = 3,
		-- entitlement per eligible kill, by enemy kind (Boss is granted directly, no shard)
		ByKind = { Normal = 4, Tough = 8, Elite = 20, Boss = 100 } :: { [string]: number },
		-- until stream D sets e.Kind: an enemy type with at least this base HP counts as Tough
		ToughHP = 40,
		ShareRadius = 120, -- studs from the kill: every eligible player inside gets the full amount
		PickupRadius = 8, -- default shard pickup radius, scaled by the player's pickup bonus
		ExpireSeconds = 30, -- run clock: an uncollected shard vanishes after this
		FadeSeconds = 5, -- ... blinking and shrinking for the last seconds (client VFX)
		-- crowd aggregation: a new shard joins a resting one of the SAME owner within
		-- MergeRadius studs that was born less than MergeWindow s ago (values add up, the
		-- entitlement total is unchanged; its expiry moves to the newer one)
		MergeRadius = 3,
		MergeWindow = 4,
		MergeMax = 400,
		PoolSize = 800, -- pooled shard parts (one per owner per shard; 4 players share it)
		-- crystal size by shard value (Small below Medium)
		Kinds = { Medium = 8, Large = 40 },
	},
	Gold = {
		-- team run gold credited once per eligible kill, by enemy kind (temporary, never saved)
		ByKind = { Normal = 3, Tough = 6, Elite = 20, Boss = 0 } :: { [string]: number },
		-- chest k+1 costs round(ChestBase x ChestGrowth^k), at most ChestCap (k = chests bought this run)
		ChestBase = 40,
		ChestGrowth = 1.35,
		ChestCap = 400,
	},
	Chests = {
		-- with stream B's LevelUpSystem.QueueChoice: chests never hold an old item; every
		-- recipient gets one "Chest" / "PassiveOnly" choice (up to 3 options) instead
		HideItems = true,
	},
	ClassGoals = {
		SampleHz = 4, -- distance / weapons sampling rate (positions are never saved per frame)
		SpeedSlack = 1.25, -- x the player's permitted speed
		SpeedFloor = 36, -- studs/s always allowed (the generic horizontal cap is 34)
		StepAllowance = 1, -- studs of slack per sample
		CloseRange = 10, -- studs: a close kill is a melee / Sword / dash kill this near the hero
		-- weapon ids that count as close-range (WeaponData Melee = true / Close = true also do;
		-- a dash effect's damage source may carry Dash = true)
		CloseWeapons = { Whip = true } :: { [string]: boolean },
		ReviveDedupe = 1, -- s: one revive completion reported twice counts once
	},
}
RunConfig.UI = {} -- [stream F] run HUD layout and screens

return RunConfig
