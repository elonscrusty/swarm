--!strict
--[[
	SwarmV2/Run/RunConfig.lua  (ReplicatedStorage.SwarmV2.Run.RunConfig)
	OWNER: gameplay track (Chat 2). Run numbers for the redesign (docs/redesign/OWNERSHIP.md).

	Sections:
	  Camera / Movement / Dash   third-person orbit camera, jump and air control, dash and leap
	                             (docs/redesign/gameplay/DESIGN.md sections 1 and 2).
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
	AirControl = 0.7, -- share of the live stick that steers in the air (the rest is the takeoff direction)
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
RunConfig.Builds = {} -- [stream B] ranks, offers, slots, evolutions
RunConfig.Combat = {} -- [stream B] damage formula, crit, armor, status caps, targeting
RunConfig.Director = {} -- [stream D] run clock, beacon, boss, enemy pressure
RunConfig.Survival = {} -- [stream E1] downed, revive, protection, falls, movement feel
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
