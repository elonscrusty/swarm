-- survival-sim: stream E1 survival rules against the real server (RunManager, Dash, RunConfig.Survival).
--   A) hold-to-revive in a trio: nearest holder revives, letting go / another holder starts over,
--      a reviver going down resets, 3 held s -> 25% max HP + 1 s protection, attributes
--   B) bleed-out: 20 s, no XP / heals while downed, then the paid revive offer (C8), declined ->
--      eliminated + spectating; a saved revive token is spent at the end of the bleed instead
--   C) wipe once: the last living hero falls while a teammate is downed: everyone is out at once,
--      EndRun runs once, one result per player, no waiting for the remaining bleed
--   D) hit protection: one shared 0.35 s window for every attacker, falls skip it, menus and
--      dashes grant none, revive protection is separate
--   E) falls: the damage table (SurvivalRules) and a real landing through Dash.lua's landing
--      check (one landing once; leaps and teleports never hurt)
--   F) out-of-bounds rescue: <= 10% max HP, never the last hit point, 3 s lockout, no XP / heal,
--      not a landing
--   G) movement: the generic cap 34 (WalkSpeed + server speed check), no bunny-hop multiplier,
--      a dash and a class boost allowed, the client move driver's accel / decel, one jump source
--   H) disconnect window: a dropped living hero resumes the same state inside 60 s (escrow kept
--      on the reload); the world waits while nobody connected is alive; after the window they
--      are eliminated and settled once; a later return only spectates; then a wipe ends the run once
-- Prints PASS / FAIL lines; any FAIL fails the regression. Run headless with --studio.
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local me = Players.LocalPlayer
local ava = preview.addPlayer("Ava", 2)
local ben = preview.addPlayer("Ben", 3)
preview.startServer()
preview.advance(1)

local RM = preview.server("RunManager")
local LU = preview.server("LevelUpSystem")
local XP = preview.server("XPSystem")
local DS = preview.server("DataService")
local HG = preview.server("HeightGrid")
local Remotes = preview.shared("Remotes")
local Config = preview.shared("Config")
local RunConfig = preview.require(ReplicatedStorage.SwarmV2.Run.RunConfig)
local Rules = preview.require(ReplicatedStorage.SwarmV2.Run.SurvivalRules)
local S = RunConfig.Survival
local SD = S.Downed
local state = ReplicatedStorage:WaitForChild("SwarmState")

local fails = 0
local function check(label: string, ok: any, detail: string?)
	if not ok then
		fails += 1
	end
	preview.log(string.format("%s  %s%s", ok and "PASS" or "FAIL", label, detail and ("  (" .. detail .. ")") or ""))
end

-- every RunResult per player, every EndRun call
local results: { [number]: number } = {}
local origFire = Remotes.FireClient
Remotes.FireClient = function(name, p, ...)
	if name == "RunResult" and typeof(p) == "Instance" then
		results[p.UserId] = (results[p.UserId] or 0) + 1
	end
	return origFire(name, p, ...)
end
local endRuns = 0
local origEnd = RM.EndRun
RM.EndRun = function(...)
	endRuns += 1
	return origEnd(...)
end

local function as(p: Player, name: string, ...)
	if p == me then
		preview.remote(name):FireServer(...)
	else
		preview.fireServerAs(p, name, ...)
	end
end

local function startRun(list: { Player }, mode: string): boolean
	for _ = 1, 60 do
		if RM.StartTeamRun(list, mode, "Forest", list[1]) then
			preview.advance(6)
			return true
		end
		preview.advance(0.5)
	end
	return false
end

-- keeps a hero out of the way of the tests: no panels, no level-ups, no stray hits
local function calm(rp, invulnerable: boolean?)
	LU.Cancel(rp)
	rp.PendingLevels = 0
	rp.InvulnUntil = invulnerable and math.huge or 0
	rp.HitProtectUntil = 0
	rp.RevivesLeft = 0
end

-- advances while closing level-up panels as they open (one fighter left: an open panel would
-- freeze the world, and the bleed waits while the world is frozen)
local function waitLive(seconds: number)
	local t = 0
	while t < seconds - 1e-6 do
		for _, rp in ipairs(RM.GetRunPlayers()) do
			if rp.Alive and (rp.Offer ~= nil or (rp.PendingLevels or 0) > 0) then
				LU.Cancel(rp)
				rp.PendingLevels = 0
			end
		end
		local step = math.min(0.25, seconds - t)
		preview.advance(step)
		t += step
	end
end

local function place(rp, target, distance: number)
	rp.Root.CFrame = CFrame.new(target.Root.Position + Vector3.new(distance, 0, 0))
	rp.LastValidPos = rp.Root.Position
	rp.SpeedCheckTimer = 0
end

-- holds interact for `seconds` (every listed player), refreshing like the client does
local function hold(list: { Player }, seconds: number)
	local t = 0
	while t < seconds - 1e-6 do
		for _, p in ipairs(list) do
			as(p, "ReviveHold", true)
		end
		local step = math.min(SD.HoldRefresh, seconds - t)
		preview.advance(step)
		t += step
	end
end
local function release(list: { Player })
	for _, p in ipairs(list) do
		as(p, "ReviveHold", false)
	end
	preview.advance(0.05)
end

local function kill(rp, cause: string?)
	rp.InvulnUntil = 0
	rp.HitProtectUntil = 0
	RM.DamagePlayer(rp, 1e7, cause or "Test strike")
end

check("config: 20 s bleed, 3 s hold within 8 studs, 25% HP, 1 s protection", SD.BleedSeconds == 20 and SD.ReviveSeconds == 3 and SD.ReviveRange == 8 and SD.ReviveHPShare == 0.25 and SD.ReviveProtectSeconds == 1)
check("config: 0.35 s hit protection, falls 18 / 2% / 35%, rescue 10% / 3 s, window 60 s", S.HitProtectSeconds == 0.35 and S.Fall.SafeDrop == 18 and S.Fall.PerStud == 0.02 and S.Fall.MaxShare == 0.35 and S.Rescue.MaxHPShare == 0.10 and S.Rescue.LockoutSeconds == 3 and S.Disconnect.WindowSeconds == 60)

------------------------------------------------------------------------------------------
-- A) hold-to-revive (trio)
------------------------------------------------------------------------------------------
assert(startRun({ me, ava, ben }, "Trio"), "trio run must start")
local rMe, rAva, rBen = assert(RM.GetRunPlayer(me)), assert(RM.GetRunPlayer(ava)), assert(RM.GetRunPlayer(ben))
for _, rp in ipairs({ rMe, rAva, rBen }) do
	calm(rp, true)
	rp.ProductReviveUsed = true -- the paid path is tested in B
end
rAva.PendingLevels = 4
kill(rAva)
check("0 HP with living teammates: downed, not eliminated", rAva.Downed == true and rAva.Alive == false and not rAva.Eliminated and not rAva.AwaitingRevive)
check("downed attributes", ava:GetAttribute("Downed") == true and ava:GetAttribute("Alive") == false and (ava:GetAttribute("BleedLeft") or 0) > 19 and ava:GetAttribute("Eliminated") == false)
check("banked level choices wait (kept, no panel)", rAva.PendingLevels == 4 and rAva.Offer == nil)
place(rMe, rAva, 3)
place(rBen, rAva, 6)
hold({ me, ben }, 1)
check("two holders: the nearest revives", rAva.Reviver == rMe and rAva.ReviveProgress > 0.25 and rAva.ReviveProgress < 0.45, tostring(rAva.ReviveProgress))
release({ me })
check("the reviver lets go: progress starts over", rAva.ReviveProgress < 0.05 and rAva.Reviver ~= rMe)
hold({ ben }, 1.5)
check("the other holder takes over from zero", rAva.Reviver == rBen and rAva.ReviveProgress > 0.4 and rAva.ReviveProgress < 0.6, tostring(rAva.ReviveProgress))
-- the reviver goes down: progress resets (and they are downed themselves)
kill(rBen)
preview.advance(0.05)
check("a reviver going down resets the progress", rAva.ReviveProgress == 0 and rBen.Downed == true)
place(rMe, rAva, 3)
hold({ me }, SD.ReviveSeconds + 0.2)
local mx = rAva.Stats.MaxHP
check("three held seconds revive at 25% max HP", rAva.Alive and math.abs(rAva.HP - mx * SD.ReviveHPShare) < 1, string.format("%.1f / %.1f", rAva.HP, mx))
check("revive protection is 1 s (separate from hit protection)", rAva.InvulnUntil > RM.GetRunTime() and rAva.InvulnUntil <= RM.GetRunTime() + SD.ReviveProtectSeconds + 0.01 and (ava:GetAttribute("ReviveProtectUntil") or 0) > workspace:GetServerTimeNow())
check("revived attributes", ava:GetAttribute("Downed") == false and ava:GetAttribute("Alive") == true and ava:GetAttribute("ReviveProgress") == 0)
check("the reviver's Revives count went up once", rMe.Revives == 1)
check("the banked levels come back after the revive", rAva.PendingLevels == 4 or rAva.Offer ~= nil)
calm(rAva, true)
place(rMe, rBen, 2)
hold({ me }, SD.ReviveSeconds + 0.2)
release({ me })
check("the second downed teammate revived too", rBen.Alive == true and rMe.Revives == 2)
calm(rBen, true)

------------------------------------------------------------------------------------------
-- B) bleed-out, no XP / heals while downed, paid offer, elimination, spectate, token
------------------------------------------------------------------------------------------
kill(rAva)
local xpBefore, xpAlive = rAva.XP, rMe.XP
XP.GiveSharedXP(40)
RM.Heal(rAva, 50)
check("no XP and no heals while downed", rAva.XP == xpBefore and rAva.HP == 0 and rMe.XP > xpAlive)
waitLive(10)
local bleedMid = ava:GetAttribute("BleedLeft") or -1
check("the bleed counts down while the world runs", bleedMid > 9 and bleedMid < 11, tostring(bleedMid))
rAva.ProductReviveUsed = false -- the established paid revive is offered at the end of the bleed
waitLive(10.5)
check("bleed over: the Revive product is offered (C8)", rAva.AwaitingRevive == true and not rAva.Downed and not rAva.Eliminated)
as(ava, "ReviveDecline")
preview.advance(0.1)
check("declined: eliminated and spectating", rAva.Eliminated == true and ava:GetAttribute("Eliminated") == true and ava:GetAttribute("Spectating") == true and ava:GetAttribute("Alive") == false)
place(rMe, rAva, 2)
hold({ me }, SD.ReviveSeconds + 0.5)
release({ me })
check("an eliminated hero can't be revived by holding", rAva.Alive == false and rAva.Eliminated == true)
check("the run goes on (no defeat with living teammates)", state:GetAttribute("Phase") == "Running" and endRuns == 0)
-- a saved revive token is spent when the bleed runs out
local benData = DS.GetData(ben)
benData.ReviveTokens = 1
rBen.ProductReviveUsed = false
kill(rBen)
check("token holder goes down first (token kept while a teammate can help)", rBen.Downed == true and benData.ReviveTokens == 1)
waitLive(SD.BleedSeconds + 0.5)
check("bleed over with a token: spent once, back up", rBen.Alive == true and benData.ReviveTokens == 0 and rBen.ProductReviveUsed == true)
calm(rBen, true)

------------------------------------------------------------------------------------------
-- C) wipe once
------------------------------------------------------------------------------------------
kill(rBen)
waitLive(1)
local bleedLeft = rBen.BleedLeft or 0
rMe.ProductReviveUsed = true
kill(rMe)
check("last living hero falls: out at once (nobody can revive)", rMe.Eliminated == true and not rMe.Downed)
check("the downed teammate is out at once too (no waiting out the bleed)", rBen.Eliminated == true and bleedLeft > 15, string.format("bleed left %.1f", bleedLeft))
check("defeat declared once", endRuns == 1 and state:GetAttribute("Phase") == "Results")
preview.advance(1)
check("one result per player", results[1] == 1 and results[2] == 1 and results[3] == 1, string.format("%s/%s/%s", tostring(results[1]), tostring(results[2]), tostring(results[3])))
preview.advance(Config.Run.ResultsSeconds + 2)

------------------------------------------------------------------------------------------
-- D) hit protection (duo me + ava)
------------------------------------------------------------------------------------------
assert(startRun({ me, ava }, "Duo"), "duo run must start")
rMe, rAva = assert(RM.GetRunPlayer(me)), assert(RM.GetRunPlayer(ava))
calm(rMe)
calm(rAva, true)
rMe.ProductReviveUsed, rAva.ProductReviveUsed = true, true
local hp0 = rMe.HP
RM.DamagePlayer(rMe, 10, "Beetle contact", "contact")
local hp1 = rMe.HP
RM.DamagePlayer(rMe, 10, "Root Runner contact", "contact")
RM.DamagePlayer(rMe, 10, "Sap Lobber projectile", "projectile")
RM.DamagePlayer(rMe, 10, "Boss slam", "area")
check("one shared window: the first hit lands, three more in the same frame do not", hp1 < hp0 and rMe.HP == hp1, string.format("%.1f -> %.1f -> %.1f", hp0, hp1, rMe.HP))
check("HitProtectUntil about 0.35 s ahead (server time)", math.abs((me:GetAttribute("HitProtectUntil") or 0) - workspace:GetServerTimeNow() - S.HitProtectSeconds) < 0.1)
RM.DamagePlayer(rMe, 5, "Fall", "fall")
check("a fall is not an ordinary hit (skips the window)", rMe.HP < hp1)
local hp2 = rMe.HP
preview.advance(0.2)
RM.DamagePlayer(rMe, 10, "Beetle contact", "contact")
check("still inside 0.35 s: blocked", rMe.HP == hp2)
preview.advance(0.2)
RM.DamagePlayer(rMe, 10, "Beetle contact", "contact")
check("after 0.35 s the next hit lands (protection did not stack per attacker)", rMe.HP < hp2)
-- menus and dashes give no protection
rMe.HitProtectUntil = 0
rMe.Paused, rMe.Offer = true, { {}, {}, {} }
local hp3 = rMe.HP
RM.DamagePlayer(rMe, 10, "Beetle contact", "contact")
rMe.Paused, rMe.Offer = false, nil
check("an open upgrade panel grants no protection", rMe.HP < hp3)
rMe.HitProtectUntil = 0
rMe.DashUntil = os.clock() + 0.2
local hp4 = rMe.HP
RM.DamagePlayer(rMe, 10, "Beetle contact", "contact")
check("a dash grants no invulnerability", rMe.HP < hp4)
rMe.HitProtectUntil = 0
rMe.InvulnUntil = RM.GetRunTime() + 1
local hp5 = rMe.HP
RM.DamagePlayer(rMe, 10, "Fall", "fall")
RM.DamagePlayer(rMe, 10, "Beetle contact", "contact")
check("revive-style protection blocks everything, falls included", rMe.HP == hp5)
rMe.InvulnUntil = 0
-- player armor with the rank system: A / (100 + A) less (stream B's BuildRules.ArmorMult)
if RunConfig.Builds.Enabled then
	rMe.HitProtectUntil = 0
	local oldArmor = rMe.Stats.Armor
	rMe.Stats.Armor = 50
	local hpA = rMe.HP
	RM.DamagePlayer(rMe, 30, "Beetle contact", "contact")
	check("rank armor: A 50 takes a third off a hit", math.abs((hpA - rMe.HP) - 30 * rMe.Stats.DamageTaken * (1 - 50 / 150)) < 0.01, string.format("%.2f", hpA - rMe.HP))
	rMe.Stats.Armor = oldArmor
end
calm(rMe)

------------------------------------------------------------------------------------------
-- E) falls
------------------------------------------------------------------------------------------
local function near(a: number, b: number): boolean
	return math.abs(a - b) < 1e-6
end
check("fall table: 10 and 18 studs are free", Rules.FallDamage(10, 100) == 0 and Rules.FallDamage(18, 100) == 0)
check("fall table: 20 studs = 4%, 30 = 24%", near(Rules.FallDamage(20, 100), 4) and near(Rules.FallDamage(30, 100), 24))
check("fall table: 35% cap per landing (40 and 200 studs)", near(Rules.FallDamage(40, 100), 35) and near(Rules.FallDamage(200, 100), 35))
check("fall table: a reduction (Spring Stitch hook) scales it", near(Rules.FallDamage(30, 100, 0.5), 12) and Rules.FallDamage(30, 100, 2) == 0)
check("fall table: junk input is harmless", Rules.FallDamage(0 / 0, 100) == 0 and Rules.FallDamage(math.huge, 100) == 0 and Rules.FallDamage(30, -5) == 0)
-- a real landing: Dash.lua's landing check with a ground ray (the mock's rays hit nothing by default)
local anyPart: BasePart? = nil
for _, d in ipairs(workspace:GetDescendants()) do
	if d:IsA("BasePart") then
		anyPart = d
		break
	end
end
preview.setRaycast(function(origin: Vector3, direction: Vector3, _params)
	if math.abs(direction.X) > 1e-6 or math.abs(direction.Z) > 1e-6 or direction.Y >= 0 then
		return nil
	end
	local g = HG.GroundY(origin.X, origin.Z)
	if origin.Y >= g - 0.01 and origin.Y + direction.Y <= g then
		return { Instance = anyPart, Position = Vector3.new(origin.X, g, origin.Z), Normal = Vector3.new(0, 1, 0), Distance = origin.Y - g, Material = Enum.Material.Grass }
	end
	return nil
end)
local function groundAt(rp): Vector3
	local p = rp.Root.Position
	return Vector3.new(p.X, HG.GroundY(p.X, p.Z) + 3, p.Z)
end
local function fallFrom(rp, height: number)
	local stand = groundAt(rp)
	rp.Root.CFrame = CFrame.new(stand)
	preview.advance(0.2) -- grounded
	rp.Root.CFrame = CFrame.new(stand + Vector3.new(0, height * 0.5, 0))
	preview.advance(0.1)
	rp.Root.CFrame = CFrame.new(stand + Vector3.new(0, height, 0)) -- the highest point
	preview.advance(0.1)
	rp.Root.CFrame = CFrame.new(stand + Vector3.new(0, height * 0.3, 0))
	preview.advance(0.1)
	rp.Root.CFrame = CFrame.new(stand) -- landed
	rp.LastValidPos = stand
	preview.advance(0.15)
end
calm(rMe)
rMe.LastLanding = nil
local hpF = rMe.HP
fallFrom(rMe, 30)
local landing = rMe.LastLanding
check("a 30-stud fall: one landing seen by the server", landing ~= nil and math.abs(landing.Drop - 30) < 0.5, landing and string.format("drop %.1f", landing.Drop) or "none")
check("...costs 24% max HP", math.abs((hpF - rMe.HP) - rMe.Stats.MaxHP * 0.24) < 0.6, string.format("%.1f of %.1f", hpF - rMe.HP, rMe.Stats.MaxHP))
local hpAfter = rMe.HP
preview.advance(1)
check("one landing counted once", rMe.HP == hpAfter and rMe.LastLanding == landing)
calm(rMe)
rMe.LastLanding = nil
fallFrom(rMe, 12)
check("a 12-stud drop is free", rMe.LastLanding ~= nil and rMe.LastLanding.Damage == 0 and rMe.HP == hpAfter)
-- Spring Stitch (stream B puts its reduction on the stat sheet as FallDamageMult)
rMe.Stats.FallDamageMult = 0.6
calm(rMe)
rMe.LastLanding = nil
local hpS = rMe.HP
fallFrom(rMe, 30)
check("Spring Stitch (Stats.FallDamageMult 0.6): a 30-stud fall costs 14.4%", math.abs((hpS - rMe.HP) - rMe.Stats.MaxHP * 0.144) < 0.6, string.format("%.1f", hpS - rMe.HP))
rMe.Stats.FallDamageMult = 1
hpAfter = rMe.HP
check("post-landing jump restriction 0.12 s (Spring Stitch shortens it on the client)", S.Move.LandLockSeconds == 0.12)
rMe.LeapUntil = os.clock() + 5
rMe.LastLanding = nil
fallFrom(rMe, 40)
check("a leap / launch-pad arc never takes fall damage", rMe.LastLanding == nil and rMe.HP == hpAfter)
rMe.LeapUntil = nil
local stand = groundAt(rMe)
rMe.Root.CFrame = CFrame.new(stand)
preview.advance(0.2)
rMe.Root.CFrame = CFrame.new(stand + Vector3.new(0, 40, 0))
preview.advance(0.1)
RM.TeleportPlayer(rMe, stand - Vector3.new(0, 3, 0))
preview.advance(0.3)
check("a teleport mid-air is no landing (no fall damage)", rMe.LastLanding == nil and rMe.HP == hpAfter)
preview.setRaycast(nil)

------------------------------------------------------------------------------------------
-- F) out-of-bounds rescue
------------------------------------------------------------------------------------------
calm(rMe)
rMe.HP = rMe.Stats.MaxHP
local before = rMe.HP
local xpR = rMe.XP
local safe = groundAt(rMe)
rMe.SafePos = safe
rMe.Root.CFrame = CFrame.new(safe.X, HG.GroundY(safe.X, safe.Z) - 60, safe.Z)
preview.advance(0.3)
check("rescued back to the last safe surface", (rMe.Root.Position - safe).Magnitude < 6, tostring(rMe.Root.Position))
check("the rescue costs 10% of max HP", math.abs((before - rMe.HP) - rMe.Stats.MaxHP * S.Rescue.MaxHPShare) < 0.01, string.format("%.1f", before - rMe.HP))
check("no XP and no healing from a rescue", rMe.XP == xpR and rMe.HP < before)
check("3 s damage lockout", rMe.InvulnUntil >= RM.GetRunTime() + 2.5)
local afterRescue = rMe.HP
rMe.HitProtectUntil = 0
RM.DamagePlayer(rMe, 10, "Beetle contact", "contact")
check("no damage inside the lockout", rMe.HP == afterRescue)
rMe.Root.CFrame = CFrame.new(safe.X + 2, HG.GroundY(safe.X, safe.Z) - 60, safe.Z)
preview.advance(0.3)
check("a second rescue inside the lockout costs nothing", rMe.HP == afterRescue)
preview.advance(S.Rescue.LockoutSeconds)
rMe.HitProtectUntil = 0
RM.DamagePlayer(rMe, 10, "Beetle contact", "contact")
check("the lockout ends after 3 s", rMe.HP < afterRescue)
rMe.HP = 3
rMe.InvulnUntil = 0
rMe.Root.CFrame = CFrame.new(safe.X, HG.GroundY(safe.X, safe.Z) - 60, safe.Z)
preview.advance(0.3)
check("a rescue never takes the last hit point", rMe.Alive and rMe.HP >= 1 and rMe.HP < 3)
check("the rescue arrival is no landing", rMe.LastLanding == nil)
rMe.HP = rMe.Stats.MaxHP
rMe.InvulnUntil = 0
calm(rMe)

------------------------------------------------------------------------------------------
-- G) movement: cap 34, no hop multiplier, dash, class boost, move driver, jump source
------------------------------------------------------------------------------------------
local M = S.Move
check("no bunny-hop multiplier left in the legacy config", Config.Movement.HopSpeedCap == 1 and Config.Movement.HopBonus == 0)
local function speedTrial(rp, studs: number): boolean
	calm(rp)
	local p0 = rp.Root.Position
	rp.LastValidPos = p0
	rp.SpeedCheckTimer = 0
	rp.Root.CFrame = CFrame.new(p0 + Vector3.new(studs, 0, 0))
	preview.advance(0.52)
	local moved = ((rp.Root.Position - p0) * Vector3.new(1, 0, 1)).Magnitude
	rp.Root.CFrame = CFrame.new(p0)
	rp.LastValidPos = p0
	rp.SpeedCheckTimer = 0
	return moved > studs - 0.5 -- true = kept, false = snapped back
end
local base = rMe.Stats.Speed
check("walking at base speed passes the speed check", speedTrial(rMe, base * 0.5))
check("chained-hop speed (old 1.24 x 1.35) no longer passes", not speedTrial(rMe, base * 1.24 * 1.35 * 0.5 + 6.5))
rMe.Stats.Speed = 60 -- generic buffs past the cap
RM.ApplyMovement(rMe)
check("WalkSpeed never above the generic cap", rMe.Humanoid.WalkSpeed == M.HorizontalCap, tostring(rMe.Humanoid.WalkSpeed))
check("the speed check allows the cap", speedTrial(rMe, M.HorizontalCap * 0.5))
check("...but not 60 studs/s", not speedTrial(rMe, 60 * 1.3 * 0.5 + 7))
RM.SetSpeedBoost(rMe, 50, 2)
check("an explicit class boost lifts the cap", rMe.Humanoid.WalkSpeed == 50 and (me:GetAttribute("SpeedBoost") or 0) == 50)
check("the speed check allows the boost", speedTrial(rMe, 50 * 0.5))
preview.advance(2.2)
check("the boost ends", rMe.Humanoid.WalkSpeed == M.HorizontalCap)
rMe.Stats.Speed = base
RM.ApplyMovement(rMe)
-- a validated dash: 70 studs/s for 0.22 s, cooldown from the start, allowed by the speed check
calm(rMe)
local dashRemote = ReplicatedStorage:WaitForChild("SwarmV2Net"):WaitForChild("Run"):WaitForChild("Dash")
dashRemote:FireServer(Vector3.new(1, 0, 0))
preview.advance(0.02)
local D = RunConfig.Dash.Default
check("the dash is accepted (70 / 0.22 / 2.5 from the start)", rMe.DashUntil ~= nil and rMe.DashSpeed == D.Speed and math.abs((rMe.DashReadyAt - rMe.DashUntil) - (D.Cooldown - D.Duration)) < 0.05)
do
	local p0 = rMe.Root.Position
	rMe.LastValidPos = p0
	rMe.SpeedCheckTimer = 0
	rMe.Root.CFrame = CFrame.new(p0 + Vector3.new(D.Speed * D.Duration + base * 0.25, 0, 0))
	preview.advance(0.5)
	local moved = ((rMe.Root.Position - p0) * Vector3.new(1, 0, 1)).Magnitude
	check("the speed check allows a dash's travel", moved > D.Speed * D.Duration)
end
-- the dash variant follows the run's admitted hero, never the lobby's SwarmClass pick
local DashMod = preview.require(game:GetService("ServerScriptService").SwarmV2.Run.Dash)
local oldPick = me:GetAttribute("SwarmClass")
me:SetAttribute("SwarmClass", "ruckus")
check("dash variant from the run hero, not the lobby pick", DashMod.GetClassId({ CharacterId = "granny_boom", Player = me }) == "granny_boom")
me:SetAttribute("SwarmClass", oldPick)
dashRemote:FireServer(Vector3.new(1, 0, 0))
preview.advance(0.02)
check("a second dash inside the cooldown is refused", os.clock() < rMe.DashReadyAt and rMe.DashUntil < os.clock())
-- the client move driver and the jump source (pure rules, the same module the client runs)
local v = Vector3.zero
local t = 0
while v.Magnitude < 0.999 and t < 1 do
	v = Rules.StepMove(v, Vector3.new(1, 0, 0), 1 / 60)
	t += 1 / 60
end
check("move driver: standing to full speed in about 0.18 s", math.abs(t - M.AccelSeconds) < 0.03, string.format("%.3f s", t))
t = 0
while v.Magnitude > 0.001 and t < 1 do
	v = Rules.StepMove(v, Vector3.zero, 1 / 60)
	t += 1 / 60
end
check("move driver: a release stops in about 0.15 s", math.abs(t - M.DecelSeconds) < 0.03, string.format("%.3f s", t))
check("one jump source: sqrt(2 g h) for a 9-stud apex", math.abs(Rules.JumpVelocity(196.2, RunConfig.Movement.JumpApex) - 59.42) < 0.05 and RunConfig.Movement.AirControl == 0.65)
check("jump buffer and coyote 0.10 s", M.BufferSeconds == 0.10 and M.CoyoteSeconds == 0.10)
check("CapHorizontal keeps the vertical part", Rules.CapHorizontal(Vector3.new(60, -20, 0), 34) == Vector3.new(34, -20, 0))

------------------------------------------------------------------------------------------
-- H) disconnect window
------------------------------------------------------------------------------------------
calm(rMe)
calm(rAva)
rAva.HP = math.floor(rAva.Stats.MaxHP * 0.6)
ava:SetAttribute("HP", rAva.HP)
local avaLevel, avaHP, avaWeapons = rAva.Level, rAva.HP, #rAva.WeaponOrder
rAva.DashReadyAt = os.clock() + 30 -- a cooldown clock that must survive the drop
local avaData = DS.GetData(ava)
local goldBank = avaData.Gold
local escrowId = avaData.RunEscrow and avaData.RunEscrow.Id
preview.removePlayer(ava)
preview.advance(0.2)
check("a dropped living hero is held for the window", RM.AwayInWindow() == 1 and RM.HoldsReconnect(2) == true and string.find(state:GetAttribute("AwayIds") or "", ",2,", 1, true) ~= nil)
check("...and is out of the run meanwhile (no attacks, hits or XP)", RM.GetRunPlayer(ava) == nil and #RM.GetRunPlayers() == 1)
-- the last connected hero goes down: no defeat while someone is inside the window
rMe.ProductReviveUsed = true
kill(rMe)
check("downed while a teammate is inside the window (they may come back)", rMe.Downed == true and endRuns == 1 and state:GetAttribute("Phase") == "Running")
check("the world waits: nobody connected is alive", state:GetAttribute("Frozen") == true)
local held = rMe.BleedLeft
preview.advance(2)
check("the bleed waits with the world", rMe.BleedLeft == held)
-- back inside the window: the same hero, not a new life
local ava2 = preview.addPlayer("Ava", 2)
preview.playerJoined(ava2)
preview.advance(1.5)
local data2 = DS.GetData(ava2)
check("the reload keeps the run's escrow (no early settlement)", data2 ~= nil and data2.RunEscrow ~= nil and data2.RunEscrow.Id == escrowId and data2.Gold == goldBank)
local how = RM.ReconnectAdmitted(ava2)
local rAva2 = RM.GetRunPlayer(ava2)
check("inside the window: resumed", how == "resumed" and rAva2 ~= nil and rAva2.Alive == true, how)
if rAva2 then
	check("same level, HP (not healed) and build", rAva2.Level == avaLevel and math.abs(rAva2.HP - avaHP) < 0.01 and #rAva2.WeaponOrder == avaWeapons, string.format("HP %.1f vs %.1f", rAva2.HP, avaHP))
	check("cooldown clocks kept (dash still cooling down)", rAva2.DashReadyAt > os.clock() + 20 and (ava2:GetAttribute("DashReadyAt") or 0) > workspace:GetServerTimeNow() + 20)
	check("the world runs again", state:GetAttribute("Frozen") == false and RM.AwayInWindow() == 0)
	check("a second resume is refused", RM.ReconnectAdmitted(ava2) == "refused")
	calm(rAva2, true)
	place(rAva2, rMe, 2)
	hold({ ava2 }, SD.ReviveSeconds + 0.3)
	release({ ava2 })
	check("the returned hero revives the downed one", rMe.Alive == true)
	calm(rMe, true)
	-- drop again and stay away past the window
	rAva2.InvulnUntil = 0
	local gold3 = data2.Gold
	preview.removePlayer(ava2)
	preview.advance(0.2)
	check("held again", RM.AwayInWindow() == 1)
	preview.advance(S.Disconnect.WindowSeconds + 1)
	check("after 60 s: eliminated, nobody held", RM.AwayInWindow() == 0 and RM.HoldsReconnect(2) == false and state:GetAttribute("Phase") == "Running")
	local ava3 = preview.addPlayer("Ava", 2)
	preview.playerJoined(ava3)
	preview.advance(1.5)
	local data3 = DS.GetData(ava3)
	local goldLoaded = data3 and data3.Gold or -1
	local kept = goldLoaded - gold3
	check("the expired run settles once on the reload (escrow kept share)", data3 ~= nil and data3.RunEscrow == nil and kept >= 0, "kept " .. tostring(kept))
	local runsBefore = data3 and data3.Stats.Runs or -1
	local how3 = RM.ReconnectAdmitted(ava3)
	local rAva3 = RM.GetRunPlayer(ava3)
	check("a later return only spectates", how3 == "spectating" and rAva3 ~= nil and rAva3.Alive == false and rAva3.Eliminated == true, how3)
	check("spectate attributes", ava3:GetAttribute("InRun") == true and ava3:GetAttribute("Spectating") == true and ava3:GetAttribute("Eliminated") == true and ava3:GetAttribute("Alive") == false)
	check("no second settlement (gold, runs, committed)", data3 ~= nil and data3.Gold == goldLoaded and data3.Stats.Runs == runsBefore and rAva3 ~= nil and rAva3.Committed == true)
	place(rMe, rAva3, 2)
	as(me, "ReviveHold", true)
	hold({ me }, SD.ReviveSeconds + 0.5)
	release({ me })
	check("a spectator is never revived", rAva3 ~= nil and rAva3.Alive == false)
	-- the last living hero falls: nobody left, nobody inside a window -> one defeat
	local resultsBefore = results[1] or 0
	kill(rMe)
	check("wipe: defeat once", endRuns == 2 and state:GetAttribute("Phase") == "Results")
	preview.advance(0.5)
	check("one result each for the wipe", (results[1] or 0) == resultsBefore + 1)
end

preview.log(fails == 0 and "ALL PASS" or (fails .. " FAIL"))
