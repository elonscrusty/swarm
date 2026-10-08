--!strict
--[[
	SwarmV2/Run/RunConfig.lua  (ReplicatedStorage.SwarmV2.Run.RunConfig)
	OWNER: gameplay track (Chat 2). Run-side tuning numbers of the redesign.

	Other helpers add their own sections here (Dash, Camera, ...). The Classes section below is
	the class kits: roster stats and every number of the passives and movement reactions
	(server ClassKits.lua / ClassRegistry.lua). The signature weapons' 12 level rows and their
	evolutions are weapon data and live in src/shared/WeaponData.lua. Text and the full table:
	docs/redesign/gameplay/CLASSES.md.
]]

local RunConfig = {}

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

return RunConfig
