--[[
	BossData.lua
	Data-driven boss encounters. The server's BossAI (src/server/Modules/BossAI.lua) runs
	whatever is described here; a new boss is a new entry plus (only if it needs a brand
	new move) a new attack in BossAI. StageManager picks the boss of each stage
	(Config.Boss.First on stage 1, then BossData.Rotation without a back-to-back repeat);
	HP and party / stage scaling stay in Config.Boss and Config.Stages.

	Every attack follows the same readable rhythm:
	  anticipation  the boss poses (crouch, tail raise, wings up, rearing) - "Act" on her body
	  telegraph     a shape on the floor (lane, filling circles, spokes, rings, a wave with
	                a gap, mines, a wind cone) that shows exactly where the damage will be,
	                drawn by the client (src/client/Telegraphs.lua)
	  active        the damage happens once, where the telegraph said, at its end
	  recovery      a pause where the boss stands (or is dizzy / stuck) and can be hit freely

	Times are seconds, distances studs, damage before Config.Stages.EnemyDamagePerStage.

	Entry fields:
	  Id, EnemyType (EnemyData id of the body), DisplayName (boss bar, banners, pill)
	  Title        the awaken banner ("THE SCORPION QUEEN AWAKENS!")
	  HPMult       x Config.Boss.HP (a fragile flyer has less, a heavy tank more)
	  ContactDamage  overrides Config.Boss.ContactDamage (walking into her / a charge)
	  Entrance { Seconds (rises out of the ground or flies down, invulnerable and
	             harmless), Grace (no attacks after the entrance), DustRadius, From =
	             "Ground" | "Sky" }
	  Collapse  seconds of the defeat collapse before the rewards and the surge
	  Chase     seconds she walks after the player between attacks
	  Phases    list, first = start. Above = HP share where the phase ends (the next one
	            starts below it); Speed divides Chase / Recover times (telegraphs keep their
	            length, so a faster phase is never less readable); Cycle = attack order;
	            Twist = one extra rule for the phase; Roar = pause + banner on entering it
	  Attacks   per attack name (see each entry); "Move" picks the BossAI move when the
	            name differs (Summon / BroodCall share one)
	  OnHit     optional reaction to heavy damage (the Hive Mother's pulse)
	  FrostArmor  optional phase-2 armour (the Frostbound Colossus): soaks hits until broken
]]

local BossData = {}

BossData.Bosses = {
	------------------------------------------------------------------------------------
	-- Scorpion Queen: the first stage's boss
	------------------------------------------------------------------------------------
	ScorpionQueen = {
		Id = "ScorpionQueen",
		EnemyType = "Boss",
		DisplayName = "Scorpion Queen",
		Title = "THE SCORPION QUEEN AWAKENS!",
		HPMult = 1,
		Entrance = { Seconds = 2.5, Grace = 2.0, DustRadius = 18, From = "Ground" },
		Collapse = 1.5,
		Chase = 3.0,
		Phases = {
			{
				Name = "Queen",
				Above = 0.5,
				Speed = 1,
				Cycle = { "Charge", "VenomBurst", "StingerRing", "Burrow", "Summon" },
			},
			{
				Name = "Enraged",
				Above = 0,
				Speed = 1.3,
				Cycle = { "Charge", "VenomBurst", "StingerRing", "Burrow", "Summon" },
				-- the twist: every charge is a double charge (a second lane is shown and run
				-- right after the first one, re-aimed at the nearest player)
				Twist = "DoubleCharge",
				Roar = 1.4,
				Message = "THE QUEEN IS ENRAGED!",
			},
		},
		Attacks = {
			-- directional: a lane that fills toward its end, a straight rush, then dizzy
			Charge = {
				Windup = 1.0, -- lane telegraph (she crouches and trembles)
				SecondWindup = 0.8, -- the phase-2 follow-up lane
				Speed = 70,
				Duration = 0.9, -- lane length = Speed x Duration
				Recover = 1.3, -- stunned (dizzy stars), no contact damage: punish window
			},
			-- area: filling circles under / near the players, then they erupt
			VenomBurst = {
				Windup = 0.5, -- claws raise
				Circles = 3, -- + 1 per extra player, at most MaxCircles
				MaxCircles = 5,
				Radius = 6,
				Fill = 1.1, -- circles fill over this long, then erupt
				Damage = 24,
				Recover = 0.9,
			},
			-- pressure: stingers fly out in every direction except a few visible gaps
			StingerRing = {
				Windup = 0.9, -- tail raises and glows; spokes show every stinger lane
				Count = 20, -- directions around her
				Gaps = 3, -- safe gaps, evenly spread, random rotation
				GapWidth = 3, -- directions left out per gap (3 of 20 = 54 degrees)
				Waves = 2,
				WaveGap = 0.55,
				Speed = 26,
				Damage = 15,
				ProjectileRadius = 1.4,
				Life = 5,
				Recover = 1.0,
			},
			-- repositioning: she dives, a dust trail hunts one player, a circle warns, she erupts
			Burrow = {
				Dive = 0.7, -- sinks (still visible, can be hit)
				Track = 2.0, -- underground: invulnerable, untargetable, harmless
				TrackSpeed = 19, -- a little faster than walking speed: keep moving
				Warn = 0.8, -- the circle where she will come up (it no longer moves)
				Radius = 7.5,
				Damage = 28,
				Recover = 1.1, -- emerges dizzy
			},
			-- eggs appear around her and crack first; the hatchlings fade in
			Summon = {
				Windup = 1.1,
				Count = 6,
				Type = "Skeleton",
				Distance = 7, -- studs beyond her radius
				Style = "egg",
			},
		},
	},

	------------------------------------------------------------------------------------
	-- Moth Matriarch: a flyer; waves with a gap, a swooping dive, glimmer mines, moths
	------------------------------------------------------------------------------------
	MothMatriarch = {
		Id = "MothMatriarch",
		EnemyType = "MothBoss",
		DisplayName = "Moth Matriarch",
		Title = "THE MOTH MATRIARCH DESCENDS!",
		HPMult = 0.85, -- fragile for a boss: she is harder to pin down
		ContactDamage = 26,
		Entrance = { Seconds = 2.5, Grace = 2.0, DustRadius = 16, From = "Sky" },
		Collapse = 1.6,
		Chase = 2.8,
		Phases = {
			{
				Name = "Matriarch",
				Above = 0.5,
				Speed = 1,
				Cycle = { "DustStorm", "Dive", "GlimmerMines", "Summon" },
			},
			{
				Name = "Tempest",
				Above = 0,
				Speed = 1.25,
				-- the twist: wing gusts join the cycle (a wind cone pushes players gently,
				-- no damage) and the Dust Storm sends a second wave with a turned gap
				Cycle = { "DustStorm", "WingGust", "Dive", "GlimmerMines", "WingGust", "Summon" },
				Twist = "Gusts",
				Roar = 1.4,
				Message = "THE MATRIARCH WHIPS UP A TEMPEST!",
			},
		},
		Attacks = {
			-- a ring of dust rolls outward from her; one gap in it is the safe way through
			DustStorm = {
				Windup = 1.1, -- wings raised and shaking; the gap marker shows the safe lane
				Speed = 21, -- studs/s the ring travels outward
				MaxRadius = 64,
				Width = 3.0, -- ring thickness (hit band)
				GapHalf = 30, -- degrees either side of the gap centre
				Damage = 18,
				Waves = 1,
				TwistWaves = 2, -- phase 2 ("Gusts" twist)
				WaveGap = 1.6, -- seconds between the waves (the next gap shows at once)
				TurnGap = 70, -- degrees the second wave's gap turns
				Recover = 0.9,
			},
			-- she rises, a lane shows her swoop, she dives through it and lands
			Dive = {
				Windup = 1.1, -- rises and leans back; the lane fills
				Speed = 64,
				Duration = 0.85,
				Recover = 1.4, -- grounded, wings down, harmless to touch: punish window
			},
			-- slow-blinking motes drift onto the floor around the players and pop
			GlimmerMines = {
				Windup = 0.7,
				Count = 5, -- + PerExtraPlayer each, at most MaxCount
				PerExtraPlayer = 2,
				MaxCount = 9,
				Radius = 4.2,
				Fuse = 2.6, -- they drift down, blink slowly, then faster, then pop
				Damage = 16,
				Recover = 0.8,
			},
			-- cocoons crack around her and Phase Moths flutter out
			Summon = {
				Windup = 1.1,
				Count = 4,
				PerExtraPlayer = 1,
				MaxCount = 6,
				Type = "Ghost",
				Distance = 6,
				Style = "egg",
			},
			-- phase 2: she rears back, a wind cone shows the push, then it blows (no damage)
			WingGust = {
				Windup = 0.9, -- wings pulled back; the cone with drifting arrows fills
				Length = 34,
				HalfAngle = 38, -- degrees
				Push = 20, -- studs/s for Blow seconds (gentle: about 12 studs in all)
				Blow = 0.6,
				Recover = 0.8,
			},
		},
	},

	------------------------------------------------------------------------------------
	-- Rhino Warlord: heavy; horn charge, ground pound, war banner, beetle warriors
	------------------------------------------------------------------------------------
	RhinoWarlord = {
		Id = "RhinoWarlord",
		EnemyType = "RhinoBoss",
		DisplayName = "Rhino Warlord",
		Title = "THE RHINO WARLORD CHARGES IN!",
		HPMult = 1.15, -- armoured
		ContactDamage = 32,
		Entrance = { Seconds = 2.5, Grace = 2.0, DustRadius = 20, From = "Ground" },
		Collapse = 1.6,
		Chase = 3.0,
		Phases = {
			{
				Name = "Warlord",
				Above = 0.5,
				Speed = 1,
				Cycle = { "HornCharge", "GroundPound", "WarBanner", "HornCharge", "GroundPound", "Summon" },
			},
			{
				Name = "Berserk",
				Above = 0,
				Speed = 1.25,
				Cycle = { "HornCharge", "GroundPound", "WarBanner", "HornCharge", "GroundPound", "Summon" },
				-- the twist: every pound is a double pound (the bands come back from the
				-- outside in, so the safe band changes)
				Twist = "DoublePound",
				Roar = 1.4,
				Message = "THE WARLORD GOES BERSERK!",
			},
		},
		Attacks = {
			-- lane; if the lane ends at a tree / rock / the fence, his horn sticks there
			HornCharge = {
				Windup = 1.1,
				Speed = 62,
				Duration = 1.0, -- lane length = Speed x Duration (shorter when blocked)
				Recover = 1.0,
				Stuck = 2.2, -- horn stuck in an obstacle: harmless, free hits
			},
			-- concentric bands around him fill one after another (the gap between them is
			-- the time to step into a band that already struck)
			GroundPound = {
				Windup = 0.8, -- rears up on his hind legs
				Bands = { 8, 15, 22 }, -- outer radius of each band (inner = the previous one)
				First = 1.0, -- the first band strikes after this long
				Gap = 0.6, -- each next band strikes this much later
				Damage = 22,
				Recover = 1.0,
				SecondWindup = 0.5, -- phase 2: the second pound (outside in) follows
			},
			-- plants a banner that rallies nearby beetles; destroy it to stop the buff
			WarBanner = {
				Windup = 0.9,
				Distance = 10, -- studs from his side
				Type = "WarBanner",
				HPShare = 0.035, -- of the boss's max HP (so it scales with stage and party)
				Radius = 22, -- the rally zone (drawn on the floor while it stands)
				SpeedMult = 1.3,
				DamageMult = 1.4,
				Escort = 2, -- Beetle Warriors that climb out with it
				Recover = 0.6,
			},
			-- Beetle Warriors climb out of the soil around him
			Summon = {
				Windup = 1.1,
				Count = 4,
				PerExtraPlayer = 1,
				MaxCount = 6,
				Type = "Skeleton",
				Distance = 7,
				Style = "emerge",
			},
		},
	},

	------------------------------------------------------------------------------------
	-- Hive Mother: slow; egg barrage, acid pools, brood call, a pulse when hit hard
	------------------------------------------------------------------------------------
	HiveMother = {
		Id = "HiveMother",
		EnemyType = "HiveBoss",
		DisplayName = "Hive Mother",
		Title = "THE HIVE MOTHER STIRS!",
		HPMult = 1.05,
		ContactDamage = 26,
		Entrance = { Seconds = 2.5, Grace = 2.0, DustRadius = 18, From = "Ground" },
		Collapse = 1.6,
		Chase = 3.2,
		Phases = {
			{
				Name = "Mother",
				Above = 0.5,
				Speed = 1,
				Cycle = { "EggBarrage", "AcidPools", "BroodCall", "EggBarrage", "AcidPools" },
			},
			{
				Name = "Swollen",
				Above = 0,
				Speed = 1.2,
				Cycle = { "EggBarrage", "AcidPools", "BroodCall", "EggBarrage", "AcidPools" },
				-- the twist: every acid pool drips a trail of smaller pools back toward her
				Twist = "Trails",
				Roar = 1.4,
				Message = "THE HIVE MOTHER SWELLS WITH ACID!",
			},
		},
		Attacks = {
			-- eggs are lobbed (landing markers), land (small splash), then sit and hatch
			-- Mites unless they are destroyed first
			EggBarrage = {
				Windup = 0.8, -- the egg sac heaves
				Count = 4, -- + PerExtraPlayer, at most MaxCount
				PerExtraPlayer = 1,
				MaxCount = 7,
				Stagger = 0.15, -- seconds between throws
				Flight = 1.1,
				Splash = 3,
				Damage = 12,
				Type = "BroodEgg",
				Hatch = 3.5, -- seconds on the ground before it hatches
				Hatchlings = 3, -- Mites
				Recover = 0.8,
			},
			-- dashed acid circles fill, then stay as lingering pools
			AcidPools = {
				Windup = 0.7, -- head down, spewing
				Count = 3,
				PerExtraPlayer = 1,
				MaxCount = 5,
				Radius = 5,
				Fill = 1.2,
				Life = 6, -- burning time after the fill
				Tick = 0.5,
				Damage = 5, -- per tick
				-- phase 2 ("Trails"): each pool drips TrailCount smaller pools toward her
				TrailCount = 3,
				TrailRadius = 2.4,
				TrailSpacing = 5,
				Recover = 0.9,
			},
			-- Spitters claw out of the soil around her (emerge telegraphs first)
			BroodCall = {
				Move = "Summon",
				Windup = 1.2,
				Count = 3,
				PerExtraPlayer = 1,
				MaxCount = 5,
				Type = "Spitter",
				Distance = 9,
				Style = "emerge",
			},
		},
		-- hit hard (Share of her max HP within Window seconds): a short pulse around her
		-- (Radius studs beyond her body), telegraphed for Warn seconds; once per Cooldown
		OnHit = { Share = 0.07, Window = 1.5, Cooldown = 9, Warn = 0.9, Radius = 5, Damage = 14 },
	},

	------------------------------------------------------------------------------------
	-- Briar Sentinel: a bramble treant; root lines, thorn volleys, a closing bramble
	-- ring, thorn sprouts
	------------------------------------------------------------------------------------
	BriarSentinel = {
		Id = "BriarSentinel",
		EnemyType = "BriarBoss",
		DisplayName = "Briar Sentinel",
		Title = "THE BRIAR SENTINEL TAKES ROOT!",
		HPMult = 1.1,
		ContactDamage = 28,
		Entrance = { Seconds = 2.5, Grace = 2.0, DustRadius = 18, From = "Ground" },
		Collapse = 1.7,
		Chase = 3.0,
		Phases = {
			{
				Name = "Sentinel",
				Above = 0.5,
				Speed = 1,
				Cycle = { "RootLines", "ThornVolley", "BrambleRing", "RootLines", "Sproutling" },
			},
			{
				Name = "Overgrown",
				Above = 0,
				Speed = 1.3,
				Cycle = { "RootLines", "ThornVolley", "BrambleRing", "RootLines", "Sproutling" },
				-- the twist: root lines come in two sets (the second re-aimed, shown at once
				-- after the first erupts) and the bramble ring closes twice, its gap turned
				Twist = "Overgrowth",
				Roar = 1.4,
				Message = "THE BRIAR SENTINEL IS ENRAGED!",
			},
		},
		Attacks = {
			-- lanes from her roots toward the players fill, then thorns erupt along them,
			-- travelling outward from her (only once the lane has filled)
			RootLines = {
				Windup = 1.1, -- arms sink into the soil; the lanes fill
				SecondWindup = 0.9, -- phase 2: the second set
				Lines = 3, -- one at each player first, the rest spread around
				PerExtraPlayer = 1,
				MaxLines = 5,
				Length = 44,
				Width = 4.4,
				Travel = 70, -- studs/s the eruption runs along the lane
				Damage = 22,
				Recover = 1.0,
			},
			-- a fan of thorns at the nearest player, three volleys along the same spokes
			-- (step out of the fan or between two spokes)
			ThornVolley = {
				Windup = 0.9, -- leans back, the spokes show
				Count = 5, -- thorns per volley
				Spread = 80, -- degrees, the whole fan
				Volleys = 3,
				VolleyGap = 0.45,
				Speed = 30,
				Damage = 13,
				ProjectileRadius = 1.3,
				Life = 2.6,
				Recover = 0.9,
			},
			-- a ring of brambles around her closes in; one gap is the way out
			BrambleRing = {
				Windup = 1.2, -- the ring and its gap lane show, then it closes
				StartRadius = 38,
				Speed = 9, -- studs/s inward
				Width = 3.2,
				GapHalf = 28, -- degrees either side of the gap centre
				Damage = 20,
				Rings = 1,
				TwistRings = 2, -- phase 2 ("Overgrowth")
				RingGap = 1.5, -- seconds between the rings
				TurnGap = 100, -- degrees the second ring's gap turns
				Recover = 0.8,
			},
			-- thorn sprouts push out of the soil around her
			Sproutling = {
				Move = "Summon",
				Windup = 1.1,
				Count = 4,
				PerExtraPlayer = 1,
				MaxCount = 6,
				Type = "ThornSprout",
				Distance = 8,
				Style = "emerge",
			},
		},
	},

	------------------------------------------------------------------------------------
	-- Frostbound Colossus: an icy giant; slam rings, ice-spike lanes, a freezing breath,
	-- shard rain; phase 2 grows a frost armour that must be broken
	------------------------------------------------------------------------------------
	FrostboundColossus = {
		Id = "FrostboundColossus",
		EnemyType = "FrostBoss",
		DisplayName = "Frostbound Colossus",
		Title = "THE FROSTBOUND COLOSSUS WAKES!",
		HPMult = 1.2, -- a slow giant
		ContactDamage = 32,
		Entrance = { Seconds = 2.5, Grace = 2.0, DustRadius = 22, From = "Ground" },
		Collapse = 1.8,
		Chase = 3.2,
		Phases = {
			{
				Name = "Colossus",
				Above = 0.5,
				Speed = 1,
				Cycle = { "GroundSlam", "IceLanes", "FrostBreath", "ShardRain", "GroundSlam", "IceLanes" },
			},
			{
				Name = "Frostbound",
				Above = 0,
				Speed = 1.2,
				Cycle = { "GroundSlam", "IceLanes", "FrostBreath", "ShardRain", "GroundSlam", "IceLanes" },
				-- the twist: a frost armour (FrostArmor below) soaks all damage until it is
				-- broken; breaking it staggers him, and it grows back after a while
				Twist = "FrostArmor",
				Roar = 1.6,
				Message = "THE COLOSSUS GROWS FROST ARMOUR! Break it!",
			},
		},
		Attacks = {
			-- he slams the ground; slow shockwave rings roll out, each with one gap that
			-- turns a little from ring to ring
			GroundSlam = {
				Windup = 1.2, -- both fists raised; the first gap lane shows
				Waves = 2,
				WaveGap = 1.2, -- seconds between the rings (the next gap shows at once)
				Speed = 15,
				MaxRadius = 46,
				Width = 3.0,
				GapHalf = 32,
				TurnGap = 55,
				Damage = 20,
				Recover = 1.1,
			},
			-- parallel lanes along his facing, one through the nearest player; spikes burst
			-- out of every lane at once (the strips between them are safe)
			IceLanes = {
				Windup = 1.2,
				Lanes = 4,
				Spacing = 9.5, -- lane centre to centre (Spacing - Width = the safe strip)
				Width = 4.4,
				Length = 64,
				Damage = 22,
				Recover = 0.9,
			},
			-- a freezing cone toward the nearest player: small hits and a slow while in it
			FrostBreath = {
				Windup = 1.0, -- rears back, the cone fills
				Length = 30,
				HalfAngle = 30, -- degrees
				Breath = 1.4, -- seconds it blows
				Tick = 0.35,
				Damage = 6, -- per tick
				Chill = 0.6, -- walk speed x this ...
				ChillTime = 2.0, -- ... for this long after the last tick
				Recover = 1.0,
			},
			-- ice shards fall on filling circles around the players, one after another
			ShardRain = {
				Windup = 0.7, -- arms up, a cold glow
				Count = 6,
				PerExtraPlayer = 2,
				MaxCount = 10,
				Radius = 3.6,
				Fall = 1.3, -- the first circle's fill
				Stagger = 0.16, -- each next one lands this much later
				Damage = 18,
				Recover = 0.8,
			},
		},
		-- phase 2 ("FrostArmor" twist): armour of Share x his max HP soaks every hit; when it
		-- breaks he is staggered for Stun seconds; it grows back Regrow seconds later
		FrostArmor = { Share = 0.07, Stun = 2.4, Regrow = 16 },
	},
}

-- Bosses that rotate on later stages (stage 1 is Config.Boss.First).
BossData.Rotation = { "ScorpionQueen", "MothMatriarch", "RhinoWarlord", "HiveMother", "BriarSentinel", "FrostboundColossus" }

-- The boss entry for an id, falling back to the Scorpion Queen.
function BossData.Get(id: string?)
	return (id and BossData.Bosses[id]) or BossData.Bosses.ScorpionQueen
end

-- Index of the phase for an HP share (1 = first phase).
function BossData.PhaseFor(boss, hpShare: number): number
	for i, phase in ipairs(boss.Phases) do
		if hpShare > phase.Above then
			return i
		end
	end
	return #boss.Phases
end

-- How many of something for a party: base + per extra player, capped.
function BossData.ForParty(base: number, perExtra: number?, max: number?, players: number): number
	local n = base + (perExtra or 0) * math.max(0, players - 1)
	return math.min(n, max or n)
end

return BossData
