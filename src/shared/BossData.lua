--[[
	BossData.lua
	Data-driven boss encounters. The server's BossAI (src/server/Modules/BossAI.lua) runs
	whatever is described here; a new boss is a new entry plus (only if it needs a brand
	new move) a new attack function in BossAI. Config.Boss.Id picks the stage boss; HP and
	party / stage scaling stay in Config.Boss and Config.Stages.

	Every attack follows the same readable rhythm:
	  anticipation  the boss poses (crouch, tail raise, claws up, sinking) - "Act" on her body
	  telegraph     a shape on the floor (lane, filling circles, spokes) that shows exactly
	                where the damage will be, drawn by the client (src/client/Telegraphs.lua)
	  active        the damage happens once, where the telegraph said, at its end
	  recovery      a pause where she stands (or is dizzy) and can be hit freely

	Times are seconds, distances studs, damage before Config.Stages.EnemyDamagePerStage.

	Entry fields:
	  Id, EnemyType (EnemyData id of her body), DisplayName (boss bar + banners)
	  Entrance { Seconds (rises out of the ground, invulnerable and harmless), Grace (no
	             attacks after the entrance), DustRadius }
	  Collapse  seconds of the defeat collapse before the rewards and the surge
	  Chase     seconds she walks after the player between attacks
	  Phases    list, first = start. Above = HP share where the phase ends (the next one
	            starts below it); Speed divides Chase / Recover times (telegraphs keep their
	            length, so a faster phase is never less readable); Cycle = attack order;
	            Twist = one extra rule for the phase; Roar = pause + banner on entering it
	  Attacks   per attack name (see each entry)
]]

local BossData = {}

BossData.Bosses = {
	ScorpionQueen = {
		Id = "ScorpionQueen",
		EnemyType = "Boss",
		DisplayName = "Scorpion Queen",
		Entrance = { Seconds = 2.5, Grace = 2.0, DustRadius = 18 },
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
			},
		},
	},
}

-- The boss entry for an id (Config.Boss.Id), falling back to the Scorpion Queen.
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

return BossData
