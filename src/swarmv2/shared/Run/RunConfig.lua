--!strict
--[[
	SwarmV2/Run/RunConfig.lua  (ReplicatedStorage.SwarmV2.Run.RunConfig)
	OWNER: gameplay track (Chat 2). Run numbers for the redesign (docs/redesign/OWNERSHIP.md).

	Sections:
	  Camera / Movement / Dash   third-person orbit camera, jump and air control, dash and leap
	                             (docs/redesign/gameplay/DESIGN.md sections 1 and 2).
	  Builds / Combat            [stream B] weapon ranks, offers, evolutions, damage rules
	                             (docs/redesign/gameplay/BUILDS.md).
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
	-- per class (canonical ids)
	Variants = {
		granny_boom = { Kind = "Dash", Speed = 80, Duration = 0.25, Cooldown = 3.0 },
		-- Croak: a leap, ballistic arc, 31 studs forward, 7 up at the apex, about 0.55 s
		captain_croak = { Kind = "Leap", Speed = 0, Duration = 0.55, Cooldown = 2.5, Horizontal = 31, Apex = 7 },
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
-- CLASS KITS
------------------------------------------------------------------------------------------
RunConfig.Classes = {
	-- ids of the playable classes (also ClassCatalog.Order, lobby track)
	Order = { "ruckus", "toastmaster", "captain_croak", "granny_boom" },
	Default = "ruckus",
	-- A run whose selected hero is one of the 11 hidden old heroes plays the Default class instead
	-- (safety net for saves that still select one). Tests of the old heroes switch it off.
	MapLegacyToDefault = true,

	-- Roster stats (shape of CharacterData.Characters). Cost = gold; Bonus keys = PassiveData keys.
	Roster = {
		ruckus = {
			Cost = 0,
			StartWeapon = "ScrapToss",
			Bonus = { pickup = 0.25 },
			-- Signature upgrade (Hero Mastery): trait % now, + per level (5 levels)
			Signature = { Base = 25, Per = 4, PerLevel = { pickup = 0.04 } },
		},
		toastmaster = {
			Cost = 10000,
			StartWeapon = "ToastVolley",
			Bonus = { maxHpMult = 0.10 },
			Signature = { Base = 10, Per = 3, PerLevel = { maxHpMult = 0.03 } },
		},
		captain_croak = {
			Cost = 20000,
			StartWeapon = "BubbleBomb",
			Bonus = { growth = 0.10 },
			Signature = { Base = 10, Per = 2, PerLevel = { growth = 0.02 } },
		},
		granny_boom = {
			Cost = 30000,
			StartWeapon = "YarnBomb",
			Bonus = { area = 0.10 },
			Signature = { Base = 10, Per = 3, PerLevel = { area = 0.03 } },
		},
	},

	-- Ruckus, Loot Rush: chest / shrine / item pickups (not XP gems) charge one Scrap Barrage.
	LootRush = {
		PickupsPerCharge = 5,
		MaxStored = 1,
		RingCount = 8, -- scraps in the ring fired with the next volley
		RingBounces = 0, -- bounces of a ring scrap
	},
	-- Ruckus, dash: drops rolling cans (Dash.OnDash).
	DashCans = {
		Count = 2,
		Fuse = 0.8, -- seconds until a can explodes
		Radius = 6,
		DamageMult = 1.2, -- x the Scrap Toss damage
		RollSpeed = 16, -- studs/s, slows to a stop
		SpreadDegrees = 35, -- the two cans roll out to the sides, behind the dash
		MaxLive = 6, -- per player
	},

	-- Toastmaster, Overheat: Hits hits on the same enemy within Window s = a Burn.
	Overheat = {
		Hits = 3,
		Window = 4,
		BurnSeconds = 3, -- refresh only, never stacks
		TickEvery = 0.5,
		TickShare = 0.2, -- x the Toast Volley damage per tick
	},
	-- Toastmaster, landing blast (Dash.OnLanded).
	LandingBlast = {
		MinAirtime = 0.35,
		Radius = 8,
		DamageMult = 1.0, -- x the Toast Volley damage
		Cooldown = 2,
	},

	-- Captain Croak, Big Splash: a leap landing with an enemy near empowers the next bubble.
	BigSplash = {
		EnemyRange = 10,
		DamageMult = 1.8,
		RadiusMult = 1.4,
		MaxStored = 1,
	},

	-- Granny Boom, Tangled Up: a yarn explosion tangles what it hits (EnemyAI SlowUntil/SlowMult).
	TangledUp = {
		Seconds = 0.75,
		Slow = 0.35, -- 35% slower
		BossSeconds = 0.3,
		BossSlow = 0.15,
		CapSeconds = 1.5, -- most tangle time an enemy takes ...
		CapWindow = 3, -- ... per this many seconds
	},
	-- Granny Boom, Rocket Boost scorch trail (Dash.OnDash kind "boost" leaves patches along the path).
	Scorch = {
		DamageMult = 0.6, -- x the Yarn Bomb damage per tick
		Radius = 3,
		Life = 1.4,
		Spacing = 4, -- studs between patches
		Tick = 0.4,
		Duration = 0.35, -- seconds after OnDash the boost keeps dropping patches (the boost is 0.25 s)
		MaxPatches = 12, -- per player
	},
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
RunConfig.Director = {} -- [stream D] run clock, beacon, boss, enemy pressure
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
RunConfig.Economy = {} -- [stream E2] XP shards, team run gold, chests, class goals
RunConfig.UI = require(script.Parent.RunUIConfig) -- [stream F] run HUD layout and screens (own file: RunUIConfig.lua)

return RunConfig
