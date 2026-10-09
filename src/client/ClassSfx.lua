--[[
	ClassSfx.lua  (stream G: class feel and run-stage audio; docs/AUDIO.md "Second batch")

	Everything the new original sounds are attached to on the client, in one place:

	  Fire / Impact / Melee   a class's signature cue when a weapon of that class appears next to its
	                          hero (VFX: a new projectile, a slash) or a projectile of its own ends.
	                          Keyed by the hero's Player attribute CharacterId (the class id) and, for
	                          projectiles, the weapon visual id (WeaponData.Visuals), so a hero's other
	                          weapons keep the generic throw / swing sounds.
	  Dash / Jump / Land      movement hooks: DashClient.OnDash for the local hero, the DashReadyAt
	                          attribute for teammates, Humanoid jumps and JumpController.OnLanded.
	  Downed / ReviveBeat     Player attributes Downed and ReviveProgress.
	  Run stage               SwarmState RunStage (Survive, BeaconAvailable, Rally, Charge, Boss, Victory,
	                          Defeat): stingers, the beacon charge hum (follows BeaconCharge), a boss-kind
	                          camera shake at the Boss stage and the music intensity.
	  ChestBuy                the team pays for a chest (SwarmState ChestCost / TeamRunGold).

	Limits (Config.Feel.ClassSfx): a hero's cue repeats at most every PerUserGap s, all class cues
	together at most MaxPerSecond per second, a teammate's cue plays at OtherGain and only within
	OtherRange studs, and every one of them goes through Audio, whose Weapon category holds at most 3
	voices and is ducked by warnings. Nothing here changes gameplay and nothing is replicated.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared:WaitForChild("Config"))
local Remotes = require(Shared:WaitForChild("Remotes"))
local RunConfig = require(ReplicatedStorage:WaitForChild("SwarmV2"):WaitForChild("Run"):WaitForChild("RunConfig")) :: any
local Audio = require(script.Parent.Audio)
local CameraController = require(script.Parent.CameraController)

local ClassSfx = {}

local player = Players.LocalPlayer
local F = (Config.Feel :: any).ClassSfx

type Cue = { Name: string, Pitch: number, Gain: number }
type Kit = {
	Fire: Cue?, -- a signature projectile leaves the hero (Visuals = the visual ids that count)
	Visuals: { [number]: boolean }?,
	Impact: Cue?, -- one of the local hero's signature projectiles ends
	Melee: Cue?, -- a slash by this hero (VFX Fx.Slash)
	Uppercut: Cue?, -- ... with tier 3 (Knuckles' uppercut)
	Accent: Cue?, -- an extra every AccentEvery-th fire / melee
	AccentEvery: number?,
	Dash: Cue?,
	Jump: Cue?,
	Land: Cue?,
	Plant: Cue?, -- a plant appears (visual 51)
}

local function cue(name: string, pitch: number?, gain: number?): Cue
	return { Name = name, Pitch = pitch or 1, Gain = gain or 1 }
end

-- The visual ids are WeaponData.Visuals: 57 scrap, 58 / 62 toast, 59 / 63 bubble, 60 yarn, 45 the sling stone
-- (Dodgeball and Seed Slinger), 5 the boomerang (sneakers), 24 the bolt (confetti), 49 the saw (puck), 51 a plant.
local PLANT_VISUAL = 51
local KITS: { [string]: Kit } = {
	ruckus = { Fire = cue("ScrapClatter"), Visuals = { [57] = true }, Impact = cue("ScrapClatter", 1.35, 0.55), Dash = cue("ScrapClatter", 0.8, 0.9) },
	toastmaster = { Fire = cue("ToastPop"), Visuals = { [58] = true, [62] = true }, Jump = cue("ToastPop", 0.85, 1), Land = cue("ToastPop", 1.3, 0.9) },
	captain_croak = { Fire = cue("BubbleBloop"), Visuals = { [59] = true, [63] = true }, Impact = cue("BubbleBloop", 1.5, 0.6), Dash = cue("BubbleBloop", 0.7, 1) },
	granny_boom = { Fire = cue("YarnPop", 1.6, 0.5), Visuals = { [60] = true }, Impact = cue("YarnPop"), Dash = cue("YarnPop", 1.25, 0.8) },
	coach_crunch = { Fire = cue("DodgeballThump", 1.2, 0.6), Visuals = { [45] = true }, Impact = cue("DodgeballThump", 0.9, 1), Dash = cue("DodgeballWhistle") },
	doug_janitor = { Melee = cue("MopSwoosh"), Accent = cue("MopSqueak"), AccentEvery = F.SqueakEvery, Dash = cue("MopSqueak") },
	peter_parkour = { Fire = cue("ShoeBoing", 1.4, 0.5), Visuals = { [5] = true }, Jump = cue("ShoeBoing", 1.1, 1), Dash = cue("ShoeBoing", 1.2, 0.8) },
	barry_plotter = { Fire = cue("SeedSprout", 1.2, 0.5), Visuals = { [45] = true }, Plant = cue("SeedSprout"), Dash = cue("SeedSprout", 0.9, 0.9) },
	rambozo = { Fire = cue("ConfettiRattle"), Visuals = { [24] = true }, Accent = cue("ConfettiHonk"), AccentEvery = F.HonkEvery, Dash = cue("ConfettiHonk", 0.9, 1) },
	swolverine = { Melee = cue("GymScrape"), Dash = cue("GymScrape", 0.8, 0.8) },
	crash_cassidy = { Fire = cue("PuckClack"), Visuals = { [49] = true }, Impact = cue("PuckClack", 1.2, 0.6), Dash = cue("SkateRoll") },
	knuckles_mcgee = { Melee = cue("GloveThud"), Uppercut = cue("GloveBell"), Dash = cue("GloveThud", 1.3, 0.5) },
}
-- the local hero's dash when its class has no cue of its own (the old dash had no sound at all)
local PLAIN_DASH = cue("Swing", 0.75, 0.8)

local function enabled(): boolean
	return Config.FeatureOn("ClassSfx")
end

local stats = { Played = 0, Dropped = 0, Capped = 0 }
local lastBy: { [number]: { [string]: number } } = {} -- userId -> cue name -> os.clock() of its last start
local starts: { number } = {} -- start times inside the last second (the MaxPerSecond cap)
local counters: { [number]: number } = {} -- per hero: fire / melee count for the accents
local lastImpact = -math.huge

------------------------------------------------------------------------------------------
-- Helpers
------------------------------------------------------------------------------------------

local function heroPos(): Vector3?
	local char = player.Character
	local root = char and char.PrimaryPart
	return root and root.Position
end

local function rootPos(userId: number): Vector3?
	local p = Players:GetPlayerByUserId(userId)
	local char = p and p.Character
	local root = char and char.PrimaryPart
	return root and root.Position
end

-- The class kit of a hero who is in a run (nil otherwise).
local function kitOf(userId: number): Kit?
	local p = Players:GetPlayerByUserId(userId)
	if not p or p:GetAttribute("InRun") ~= true then
		return nil
	end
	local id = p:GetAttribute("CharacterId")
	return type(id) == "string" and KITS[id] or nil
end

--[[
	Plays one cue for `userId`. The local hero's plays at full gain; a teammate's only when within
	OtherRange of the hero and at OtherGain. Returns true when a sound started.
]]
local function play(userId: number, c: Cue, at: Vector3?): boolean
	if not enabled() then
		return false
	end
	local isLocal = userId == player.UserId
	if not isLocal then
		local hp = heroPos()
		if not hp or not at or (at - hp).Magnitude > F.OtherRange then
			return false
		end
	end
	local def = Config.Sounds[c.Name]
	if not def or def.Id == "" then
		return false
	end
	local now = os.clock()
	local mine = lastBy[userId]
	if not mine then
		mine = {}
		lastBy[userId] = mine
	end
	if now - (mine[c.Name] or -math.huge) < F.PerUserGap then
		stats.Dropped += 1
		return false
	end
	local n = #starts
	while n > 0 and now - starts[1] > 1 do
		table.remove(starts, 1)
		n -= 1
	end
	if n >= F.MaxPerSecond then
		stats.Capped += 1
		return false
	end
	local speed = (def.Pitch or 1) * c.Pitch + (math.random() * 2 - 1) * (def.PitchVar or 0.05)
	local started = Audio.Play(c.Name, speed, c.Gain * (isLocal and 1 or F.OtherGain))
	if started then
		mine[c.Name] = now
		table.insert(starts, now)
		stats.Played += 1
	else
		stats.Dropped += 1
	end
	return started
end

-- The living hero standing next to `pos` (a weapon that just appeared there was fired by them), or nil.
local function shooterAt(pos: Vector3, radius: number): (number?, Vector3?)
	local best: number? = nil
	local bestPos: Vector3? = nil
	local bestD = radius * radius
	for _, other in ipairs(Players:GetPlayers()) do
		local char = other.Character
		local root = char and char.PrimaryPart
		if root and other:GetAttribute("InRun") == true and other:GetAttribute("Alive") ~= false then
			local dx, dz = root.Position.X - pos.X, root.Position.Z - pos.Z
			local d2 = dx * dx + dz * dz
			if d2 <= bestD then
				best, bestPos, bestD = other.UserId, root.Position, d2
			end
		end
	end
	return best, bestPos
end

local function accent(userId: number, kit: Kit, at: Vector3?)
	local every = kit.AccentEvery
	if not (kit.Accent and every and every > 0) then
		return
	end
	local n = (counters[userId] or 0) + 1
	counters[userId] = n
	if n % every == 0 then
		local c = kit.Accent
		task.delay(0.06, function()
			play(userId, c :: Cue, at)
		end)
	end
end

------------------------------------------------------------------------------------------
-- Weapons (called by VFX)
------------------------------------------------------------------------------------------

--[[
	A projectile with weapon visual `visual` just appeared at `pos`. A class hero standing next to it fired
	it: its Fire cue plays (and the Seed Slinger's plant gets its sprout when it appears). Returns true when
	the class cue handled the sound, so VFX skips the generic throw sound.
]]
function ClassSfx.Spawned(visual: number, pos: Vector3): boolean
	if not enabled() then
		return false
	end
	if visual == PLANT_VISUAL then
		-- a plant takes root wherever the seed landed: the local Seed Slinger hears it sprout
		local mine = kitOf(player.UserId)
		local hp = heroPos()
		if mine and mine.Plant and hp and (pos - hp).Magnitude <= 60 then
			play(player.UserId, mine.Plant, hp)
		end
		return false
	end
	local userId, at = shooterAt(pos, 5)
	if userId then
		local kit = kitOf(userId)
		local fire = kit and kit.Fire
		if kit and fire and kit.Visuals and kit.Visuals[visual] then
			play(userId, fire, at)
			accent(userId, kit, at)
			return true
		end
		return false
	end
	return false
end

-- One of the local hero's projectiles with weapon visual `visual` ended at `pos` (a hit or its range).
function ClassSfx.Impact(visual: number, pos: Vector3)
	local kit = kitOf(player.UserId)
	local impact = kit and kit.Impact
	if not (kit and impact and kit.Visuals and kit.Visuals[visual]) then
		return
	end
	local now = os.clock()
	if now - lastImpact < F.ImpactGap then
		return
	end
	local hp = heroPos()
	if not hp or (pos - hp).Magnitude > F.OtherRange then
		return
	end
	lastImpact = now
	play(player.UserId, impact, hp)
end

-- A slash by `userId` (tier 0-3, 3 = evolved / the uppercut). True when the class cue handled the sound.
function ClassSfx.Swing(userId: number, tier: number): boolean
	if not enabled() then
		return false
	end
	local kit = kitOf(userId)
	local melee = kit and kit.Melee
	if not (kit and melee) then
		return false
	end
	local at = rootPos(userId)
	if kit.Uppercut and tier >= 3 then
		play(userId, kit.Uppercut, at)
	end
	play(userId, melee, at)
	accent(userId, kit, at)
	return true
end

------------------------------------------------------------------------------------------
-- Movement
------------------------------------------------------------------------------------------

-- A dash / leap by `userId` started (the local hero from DashClient, a teammate from DashReadyAt).
function ClassSfx.Dash(userId: number, _kind: string?, at: Vector3?)
	local kit = kitOf(userId)
	local dash = kit and kit.Dash
	if dash then
		play(userId, dash, at or rootPos(userId))
	elseif userId == player.UserId then
		play(userId, PLAIN_DASH, at or rootPos(userId))
	end
end

-- The local hero left the ground by a jump (the class's jump cue: Peter's boing, Toastmaster's spring).
function ClassSfx.Jump(charged: boolean?)
	local kit = kitOf(player.UserId)
	local jump = kit and kit.Jump
	if jump then
		play(player.UserId, charged and cue(jump.Name, jump.Pitch * 0.82, jump.Gain) or jump, heroPos())
	end
end

-- The local hero landed after `airtime` seconds in the air (Toastmaster's landing blast pops).
function ClassSfx.Landed(airtime: number)
	local kit = kitOf(player.UserId)
	local land = kit and kit.Land
	if land and airtime >= 0.35 then
		play(player.UserId, land, heroPos())
	end
end

------------------------------------------------------------------------------------------
-- Run stage
------------------------------------------------------------------------------------------

local state: Instance? = nil
local stage = "Survive"
local nextHum = 0
local humPending = false

local function inRun(): boolean
	return player:GetAttribute("InRun") == true
end

local function stopHum()
	Audio.SetLoop("BeaconCharge", nil)
end

-- The beacon charge hum: level = BeaconCharge, quieter when the hero is far from the beacon.
local humToken = 0
local function updateHum(force: boolean?)
	if stage ~= "Charge" or not state then
		return
	end
	local now = os.clock()
	if not force and now < nextHum then
		if not humPending then
			humPending = true
			task.delay(nextHum - now + 0.01, function()
				humPending = false
				updateHum(false)
			end)
		end
		return
	end
	nextHum = now + F.ChargeRefresh
	if force then
		-- the hero walks around the beacon without BeaconCharge changing: look again twice a second
		humToken += 1
		local token = humToken
		task.spawn(function()
			while token == humToken and stage == "Charge" and inRun() do
				task.wait(0.5)
				if token == humToken and stage == "Charge" then
					nextHum = 0
					updateHum(false)
				end
			end
		end)
	end
	local charge = math.clamp(tonumber((state :: Instance):GetAttribute("BeaconCharge")) or 0, 0, 1)
	local level = math.max(0.12, charge)
	local pos = (state :: Instance):GetAttribute("BeaconPos")
	local hp = heroPos()
	if typeof(pos) == "Vector3" and hp then
		local d = Vector3.new(pos.X - hp.X, 0, pos.Z - hp.Z).Magnitude
		if d > F.ChargeNear then
			level *= F.ChargeFar
		end
	end
	Audio.SetLoop("BeaconCharge", level)
end

--[[
	RunStage changed to `next`. `quiet` = the first reading (joining mid-run): set the state, play no stinger.
	BeaconAvailable: the portal-style reveal (the existing PortalAppear); Rally: the beacon is lit; Charge:
	the hum; Boss: the boss sting and a boss-kind shake; Victory / Defeat: the stinger, and the results
	fanfare waits for it.
]]
function ClassSfx.OnStage(next: string, quiet: boolean?)
	local prev = stage
	stage = next
	if not enabled() then
		return
	end
	local level = F.StageIntensity[next]
	Audio.SetIntensity(level or 0)
	if next ~= "Charge" then
		stopHum()
	end
	if quiet or prev == next then
		if next == "Charge" then
			updateHum(true)
		end
		return
	end
	if next == "BeaconAvailable" then
		Audio.Play("PortalAppear")
	elseif next == "Rally" then
		Audio.Play("BeaconActivate")
	elseif next == "Charge" then
		updateHum(true)
	elseif next == "Boss" then
		Audio.Play("BossSpawn")
		CameraController.Shake(F.StageShake, "boss")
	elseif next == "Victory" then
		Audio.Hold("Victory", F.VictoryHold)
		Audio.Play("RunVictory")
	elseif next == "Defeat" then
		Audio.Hold("ResultsLose", F.VictoryHold)
		Audio.Play("RunDefeat")
	end
end

function ClassSfx.Stage(): string
	return stage
end

------------------------------------------------------------------------------------------
-- Down and up
------------------------------------------------------------------------------------------

local reviveSeen: { [Player]: number } = {}
local reviveLast = -math.huge

local function onReviveProgress(p: Player)
	local v = math.clamp(tonumber(p:GetAttribute("ReviveProgress")) or 0, 0, 1)
	local before = reviveSeen[p] or 0
	reviveSeen[p] = v
	if v <= before or v >= 1 or v <= 0 or not inRun() or not enabled() then
		return
	end
	local now = os.clock()
	if now - reviveLast < F.ReviveBeatGap then
		return
	end
	if p ~= player then
		local at, hp = rootPos(p.UserId), heroPos()
		if not at or not hp or (at - hp).Magnitude > F.ReviveHearRange then
			return
		end
	end
	reviveLast = now
	Audio.Play("ReviveBeat", 0.9 + 0.55 * v)
end

local function onDowned(p: Player)
	if p == player and p:GetAttribute("Downed") == true and inRun() and enabled() then
		Audio.Play("Downed")
	end
	if p:GetAttribute("Downed") ~= true then
		reviveSeen[p] = 0
	end
end

------------------------------------------------------------------------------------------
-- Init
------------------------------------------------------------------------------------------

local function watchPlayer(p: Player)
	p:GetAttributeChangedSignal("Downed"):Connect(function()
		onDowned(p)
	end)
	p:GetAttributeChangedSignal("ReviveProgress"):Connect(function()
		onReviveProgress(p)
	end)
	if p ~= player then
		local last = tonumber(p:GetAttribute("DashReadyAt")) or 0
		p:GetAttributeChangedSignal("DashReadyAt"):Connect(function()
			local v = tonumber(p:GetAttribute("DashReadyAt")) or 0
			-- a dash sets it to now + cooldown; a reset to 0 or a smaller value is not a dash
			if v > last + 0.3 and p:GetAttribute("InRun") == true then
				ClassSfx.Dash(p.UserId, nil, rootPos(p.UserId))
			end
			last = v
		end)
	end
end

local function watchCharacter(char: Model)
	local hum = char:WaitForChild("Humanoid", 10) :: Humanoid?
	if not hum then
		return
	end
	pcall(function()
		hum.StateChanged:Connect(function(_old, new)
			if new ~= Enum.HumanoidStateType.Jumping or not inRun() then
				return
			end
			-- the takeoff speed tells a charged jump (Peter) from the class's plain one a frame later
			task.defer(function()
				local root = char.PrimaryPart
				local id = player:GetAttribute("CharacterId")
				local apex = (type(id) == "string" and RunConfig.Movement.JumpApexByClass[id]) or RunConfig.Movement.JumpApex
				local plain = math.sqrt(2 * workspace.Gravity * apex)
				local vy = root and root.AssemblyLinearVelocity.Y or 0
				ClassSfx.Jump(vy > plain * 1.05)
			end)
		end)
	end)
end

function ClassSfx.Init()
	state = Remotes.State()
	local st = state :: Instance

	-- run stage: stingers, hum, intensity
	stage = tostring(st:GetAttribute("RunStage") or "Survive")
	st:GetAttributeChangedSignal("RunStage"):Connect(function()
		if inRun() then
			ClassSfx.OnStage(tostring(st:GetAttribute("RunStage") or "Survive"), false)
		end
	end)
	st:GetAttributeChangedSignal("BeaconCharge"):Connect(function()
		updateHum(false)
	end)
	player:GetAttributeChangedSignal("InRun"):Connect(function()
		if not inRun() then
			stage = "Survive"
			stopHum()
			Audio.SetIntensity(0)
		else
			ClassSfx.OnStage(tostring(st:GetAttribute("RunStage") or "Survive"), true)
		end
	end)
	if inRun() then
		ClassSfx.OnStage(stage, true)
	end

	-- the team pays for a chest: the price steps up, or the balance drops by about a price
	local lastGold = tonumber(st:GetAttribute("TeamRunGold")) or 0
	local lastCost = tonumber(st:GetAttribute("ChestCost")) or 0
	st:GetAttributeChangedSignal("ChestCost"):Connect(function()
		local cost = tonumber(st:GetAttribute("ChestCost")) or 0
		if inRun() and enabled() and cost > lastCost and lastCost > 0 then
			Audio.Play("ChestBuy")
		end
		lastCost = cost
	end)
	st:GetAttributeChangedSignal("TeamRunGold"):Connect(function()
		local gold = tonumber(st:GetAttribute("TeamRunGold")) or 0
		if inRun() and enabled() and lastCost > 0 and lastGold - gold >= lastCost * 0.5 then
			Audio.Play("ChestBuy") -- (a price step in the same moment is dropped by ChestBuy's MinGap)
		end
		lastGold = gold
	end)

	-- down and up, dashes of teammates
	for _, p in ipairs(Players:GetPlayers()) do
		watchPlayer(p)
	end
	Players.PlayerAdded:Connect(watchPlayer)
	Players.PlayerRemoving:Connect(function(p)
		reviveSeen[p] = nil
		lastBy[p.UserId] = nil
		counters[p.UserId] = nil
	end)

	-- the local hero: jumps, landings, dashes (their modules start elsewhere; none of this blocks)
	if player.Character then
		task.spawn(watchCharacter, player.Character)
	end
	player.CharacterAdded:Connect(watchCharacter)
	task.spawn(function()
		local ok, jump = pcall(function()
			return require(script.Parent:WaitForChild("JumpController", 15) :: ModuleScript) :: any
		end)
		if ok and jump and jump.OnLanded then
			jump.OnLanded(function(airtime: number)
				if inRun() then
					ClassSfx.Landed(airtime)
				end
			end)
		end
	end)
	task.spawn(function()
		local ok, dash = pcall(function()
			local v2 = script.Parent.Parent:WaitForChild("SwarmV2Client", 15)
			return require(((v2 :: Instance):WaitForChild("Run") :: Instance):WaitForChild("DashClient") :: ModuleScript) :: any
		end)
		if ok and dash and dash.OnDash then
			dash.OnDash(function(kind: string, _dir: Vector3)
				if inRun() then
					ClassSfx.Dash(player.UserId, kind, heroPos())
				end
			end)
		end
	end)
end

-- For tests: counters since start { Played, Dropped (gap, no pool or a full mix), Capped (MaxPerSecond) }.
function ClassSfx.Stats(): { Played: number, Dropped: number, Capped: number }
	return table.clone(stats)
end

-- For tests: the kit table (read only) and a reset of the rate limits.
function ClassSfx.Kits(): { [string]: Kit }
	return KITS
end

function ClassSfx.ResetLimits()
	table.clear(lastBy)
	table.clear(starts)
	table.clear(counters)
	lastImpact = -math.huge
	reviveLast = -math.huge
	stats.Played, stats.Dropped, stats.Capped = 0, 0, 0
end

return ClassSfx
