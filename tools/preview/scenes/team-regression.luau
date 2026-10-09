-- team-regression: the TEAM features (docs/features/TEAM.md) on the REAL server and the
-- client modules (headless), with 2-4 players (Players added with preview.addPlayer):
--   16 team combo   the shared meter fills only while two free players stand together,
--                   not while one is choosing a card (protected); the full meter fires
--                   through the remote (client button / F key path), clears normal enemies,
--                   caps elites, leaves far ones; cooldown, stage cap, outsider and dead
--                   senders refused; the badge and "TEAM COMBO!" line on the client
--   17 quick pings  On my way / emotes / Go portal / Chest here through the server rules
--                   (cooldown, alive, presets only); the wheel opens from PING / G / DPadUp,
--                   six 44px+ options, keys 1-6 and gamepad highlight + send, closes after
--   18 co-op boss   Scorpion Queen in a Duo: the aggro holder keeps it HoldSeconds, the weak
--                   spot opens behind it (state + notice + client marker / badge), hits from
--                   the partner behind deal Mult, from the holder or in front do not, the
--                   bonus is capped, it closes when the aggro moves; other bosses unchanged
--   20 spectate     Trio: a fallen player cycles the camera through the two living
--                   teammates (arrows and keys), REVIVE ME pings teammates at the body (not
--                   while alive), revived = bar gone and the camera back on the own hero
--   solo + off      a solo run and every switch off: nothing of the above happens
-- run: render.sh team-regression --studio --devices pc --max-time 600 --set headless=on
local C = lib("common")
local Players = game:GetService("Players")
local UIS = game:GetService("UserInputService")
local me = Players.LocalPlayer
local ava = preview.addPlayer("Ava", 2)
local ben = preview.addPlayer("Ben", 3)
local cy = preview.addPlayer("Cy", 4) -- the 4th player: in the server, never in the run
preview.startServer()
preview.advance(1)
C.startClient()
preview.advance(0.5)
local RM = preview.server("RunManager")
local LUS = preview.server("LevelUpSystem")
local ES = preview.server("EnemySpawner")
local Ping = preview.server("TeamPingService")
local Combo = preview.server("TeamCombo")
local Coop = preview.server("CoopBoss")
local SM = preview.server("StageManager")
local Remotes = C.shared("Remotes")
local Config = C.shared("Config")
local T = Config.TeamCombo
local advance = preview.advance
local FLAT = Vector3.new(1, 0, 1)
local state = Remotes.State()

-- the client pieces ClientMain starts (headless: no full UI)
local Camera = preview.client("CameraController")
local FeatureHud = preview.client("FeatureHud")
local TeamPingsC = preview.client("TeamPings")
local ComboC = preview.client("TeamCombo")
local Wheel = preview.client("PingWheel")
local SpectateC = preview.client("Spectate")
local WeakSpotC = preview.client("WeakSpot")
Camera.Init()
FeatureHud.Init()
TeamPingsC.Init()
ComboC.Init()

local fails = 0
local function check(ok: any, label: string, detail: any?)
	if not ok then
		fails += 1
	end
	preview.log((ok and "PASS " or "FAIL ") .. label .. (detail ~= nil and ("  (" .. tostring(detail) .. ")") or ""))
end

local shown, notices = {}, {}
local fireClient, fireAll = Remotes.FireClient, Remotes.FireAllClients
Remotes.FireClient = function(name, player, payload, ...)
	if name == "TeamPingShown" then table.insert(shown, { Player = player, Data = payload }) end
	return fireClient(name, player, payload, ...)
end
Remotes.FireAllClients = function(name, payload, ...)
	if name == "Notify" and type(payload) == "table" then table.insert(notices, payload) end
	return fireAll(name, payload, ...)
end

local function key(code, pad: boolean?)
	local input = { UserInputType = pad and Enum.UserInputType.Gamepad1 or Enum.UserInputType.Keyboard, UserInputState = Enum.UserInputState.Begin, KeyCode = code, Position = Vector3.zero, Delta = Vector3.zero }
	UIS.InputBegan:_fire(input, false)
	advance(0.15)
end

local function place(rp, pos: Vector3)
	local y = rp.Root.Position.Y
	rp.Root.CFrame = CFrame.new(pos.X, y, pos.Z)
	-- a fixture move, not walking: the server's speed check starts from the new spot
	rp.LastValidPos = rp.Root.Position
end

local function tough(rp)
	LUS.Cancel(rp)
	rp.InvulnUntil = math.huge
	rp.Stats.MaxHP = 1e7
	RM.Heal(rp, 1e7, true)
end

local function clearEnemies()
	for i = #ES.Active, 1, -1 do
		ES.Despawn(ES.Active[i])
	end
end

-- run time only moves while the world runs: keep cancelling level-ups on the way
local function run(seconds: number, each: (() -> ())?)
	local steps = math.ceil(seconds / 0.1)
	for _ = 1, steps do
		for _, rp in ipairs(RM.GetRunPlayers()) do
			if rp.Offer then LUS.Cancel(rp) end
		end
		if each then each() end
		advance(0.1)
	end
end

local function endRun()
	for _, rp in ipairs(table.clone(RM.GetRunPlayers())) do
		if not rp.Returned then RM.AbandonRun(rp) end
	end
	for _ = 1, 60 do
		advance(1)
		if state:GetAttribute("Phase") == "Lobby" then break end
	end
	advance(1)
end

local function startTeam(players, mode)
	assert(RM.StartTeamRun(players, mode, "Forest", players[1]), "team run " .. mode)
	advance(6)
	local list = {}
	for _, p in ipairs(players) do
		local rp = assert(RM.GetRunPlayer(p), "run player " .. p.Name)
		tough(rp)
		table.insert(list, rp)
	end
	clearEnemies()
	return list
end

------------------------------------------------------------------------------------------
-- 16) team combo (Duo)
------------------------------------------------------------------------------------------
T.ChargeSeconds = 4
T.DrainSeconds = 8
local rps = startTeam({ me, ava }, "Duo")
local rp, mate = rps[1], rps[2]
local base = rp.Root.Position
place(rp, base)
place(mate, base + Vector3.new(40, 0, 0))
run(1.5, function() place(rp, base); place(mate, base + Vector3.new(40, 0, 0)) end)
check((state:GetAttribute("TeamCombo") or -1) == 0 and state:GetAttribute("TeamComboPair") == nil, "combo: apart, the meter stays empty", state:GetAttribute("TeamCombo"))
local function together() place(rp, base); place(mate, base + Vector3.new(6, 0, 0)) end
run(2, together)
local half = state:GetAttribute("TeamCombo") or 0
check(half > 0.35 and half < 0.65, "combo: together half the time = half a meter", half)
check(state:GetAttribute("TeamComboPair") == ",1,2,", "combo: pair published", state:GetAttribute("TeamComboPair"))
local badge = preview.playerGui().FeatureHud.Root.Badges:FindFirstChild("Badge_TeamCombo")
local badgeText = badge and badge:FindFirstChild("Text") and badge:FindFirstChild("Text").Text or ""
check(string.find(badgeText, "TEAM", 1, true), "combo: client badge shows the meter", badgeText)
-- choosing a card: protected, so no charge and no fire
LUS.QueueLevels(rp, 1)
check(rp.Offer ~= nil and rp.Paused, "combo: a level-up panel is open")
local before = Combo.Meter()
for _ = 1, 15 do together(); advance(0.1) end
check(Combo.Meter() <= before + 1e-6, "combo: no charge while a player is choosing", string.format("%.3f -> %.3f", before, Combo.Meter()))
LUS.Cancel(rp)
run(3, together)
check(Combo.Meter() >= 1, "combo: full meter", Combo.Meter())
local ok, why = Combo.Fire(cy)
check(not ok and why == "norun", "combo: a player outside the run is refused", why)
-- protected sender
LUS.QueueLevels(rp, 1)
ok, why = Combo.Fire(me)
check(not ok and why == "state", "combo: refused while choosing", why)
LUS.Cancel(rp)
place(mate, base + Vector3.new(30, 0, 0))
ok, why = Combo.Fire(me)
check(not ok and why == "partner", "combo: refused without a partner in range", why)
together()
advance(0.2)
check(ComboC.CanFire(), "combo: client can fire (button / F)")
local button = preview.playerGui().FeatureHud.Root:FindFirstChild("TeamCombo")
check(button and button.Visible and button.AbsoluteSize.X >= 44, "combo: touch button shown, 44px+", button and button.AbsoluteSize.X)
-- targets
local crowd = {}
for i = 1, 8 do
	local a = i / 8 * math.pi * 2
	local e = ES.Spawn("Skeleton", base + Vector3.new(3 + math.cos(a) * 9, 0, math.sin(a) * 9), { Force = true })
	if e then table.insert(crowd, e) end
end
local elite = ES.Spawn("Brute", base + Vector3.new(-8, 0, 4), { Elite = true, Force = true })
local far = ES.Spawn("Skeleton", base + Vector3.new(T.BurstRadius * 2.5, 0, 0), { Force = true })
local eliteHP = elite and elite.HP
-- the heroes' own weapons keep hitting the elite meanwhile: count only the combo's hits
local comboEliteDamage, inCombo = 0, false
local realDamage, realFire = ES.Damage, Combo.Fire
ES.Damage = function(e, amount, ...)
	if inCombo and e == elite then
		comboEliteDamage += amount
	end
	return realDamage(e, amount, ...)
end
Combo.Fire = function(...)
	inCombo = true
	local okFire, whyFire = realFire(...)
	inCombo = false
	return okFire, whyFire
end
key(T.Key)
advance(0.1)
ES.Damage, Combo.Fire = realDamage, realFire
check(state:GetAttribute("TeamComboUsed") == 1, "combo: F key fired it through the remote", state:GetAttribute("TeamComboUsed"))
local dead = 0
for _, e in ipairs(crowd) do if not e.Alive then dead += 1 end end
check(#crowd >= 6 and dead == #crowd, "combo: the crowd in range falls", string.format("%d/%d", dead, #crowd))
check(far and far.Alive, "combo: enemy out of range untouched")
check(elite and elite.Alive and comboEliteDamage > 0 and comboEliteDamage <= elite.MaxHP * T.EliteShare + 0.01, "combo: elite capped", elite and string.format("%.0f of %.0f (all hits %.0f)", comboEliteDamage, elite.MaxHP, eliteHP - elite.HP))
check(Combo.Meter() == 0, "combo: the meter empties")
advance(0.2)
local line = preview.playerGui().FeatureHud.Root.Announcer.Line
check(line.Text == "TEAM COMBO!", "combo: client announces it", line.Text)
run(2, together)
check(Combo.Meter() == 0, "combo: cooldown holds the meter", Combo.Meter())
ok, why = Combo.Fire(me)
check(not ok and why == "charge", "combo: refused during the cooldown", why)
-- stage cap
T.Cooldown, T.MaxPerStage = 0, 2
run(4.5, together)
ok = Combo.Fire(ava)
check(ok, "combo: the partner may fire it too")
run(4.5, together)
check(Combo.Meter() == 0, "combo: stage cap stops the charge", Combo.Meter())
ok, why = Combo.Fire(me)
check(not ok, "combo: refused at the stage cap", why)
T.Cooldown, T.MaxPerStage = 40, 3
clearEnemies()

------------------------------------------------------------------------------------------
-- 17) quick pings and the wheel (same Duo)
------------------------------------------------------------------------------------------
advance(2.1)
table.clear(shown)
check(Ping.Send(me, "OnMyWay"), "pings: On my way accepted")
check(#shown == 2 and shown[1].Data.Kind == "OnMyWay", "pings: both teammates get it", #shown)
check(not Ping.Send(me, "Wave"), "pings: cooldown rejects spam")
advance(2.1)
check(not Ping.Send(me, "say anything"), "pings: no free text")
check(not Ping.Send(me, "ReviveMe"), "pings: REVIVE ME refused while alive")
local portal = SM.PortalPosition()
local sentPortal = Ping.Send(me, "Portal")
check(sentPortal == (portal ~= nil), "pings: Go portal only with a portal", tostring(portal))
if sentPortal then
	check(shown[#shown].Data.Position == portal, "pings: Go portal marks the portal itself")
	advance(2.1)
end
advance(0.2)
local markerText = nil
for _, part in ipairs(workspace:GetChildren()) do
	if part.Name == "TeamPingMarker" and part.Ping.Enabled then markerText = part.Ping.Label.Text end
end
check(markerText == "ON MY WAY" or markerText == "GO PORTAL", "pings: marker uses the quick label", markerText)
-- the wheel
Wheel.Init()
local controls = preview.playerGui().TeamPings.Controls
controls.Ping.Activated:_fire()
advance(0.1)
local slot = preview.playerGui().FeatureHud.Root.PingWheel
check(Wheel.IsOpen() and slot.Visible and not controls.PingOptions.Visible, "wheel: PING opens the wheel, not the old panel")
local small, count = 0, 0
for _, kind in ipairs(Config.QuickPings.Order) do
	local b = slot:FindFirstChild(kind)
	if b then
		count += 1
		if b.AbsoluteSize.X < 44 or b.AbsoluteSize.Y < 44 then small += 1 end
	end
end
check(count == 6 and small == 0, "wheel: six options, all 44px+", string.format("%d options, %d small", count, small))
table.clear(shown)
slot.Cheer.Activated:_fire()
advance(0.1)
check(#shown == 2 and shown[1].Data.Kind == "Cheer" and not Wheel.IsOpen(), "wheel: tap sends the emote and closes")
advance(2.1)
key(Config.QuickPings.OpenKey)
check(Wheel.IsOpen(), "wheel: G opens it")
table.clear(shown)
key(Enum.KeyCode.Four)
check(#shown == 2 and shown[1].Data.Kind == "OnMyWay" and not Wheel.IsOpen(), "wheel: key 4 = ON MY WAY")
advance(2.1)
key(Config.QuickPings.PadOpen, true)
key(Config.QuickPings.PadNext, true)
table.clear(shown)
key(Config.QuickPings.PadSend, true)
check(#shown == 2 and shown[1].Data.Kind == "Loot" or (#shown == 0 and not Wheel.IsOpen()), "wheel: gamepad highlight + send (option 2: CHEST HERE)", shown[1] and shown[1].Data.Kind or "no chest near")
-- choosing: the wheel closes
key(Config.QuickPings.OpenKey)
me:SetAttribute("Paused", true)
advance(0.1)
check(not Wheel.IsOpen(), "wheel: closes while paused / choosing")
me:SetAttribute("Paused", nil)

------------------------------------------------------------------------------------------
-- 18) co-op boss (same Duo): Scorpion Queen weak spot
------------------------------------------------------------------------------------------
advance(2.1)
clearEnemies()
local boss = assert(ES.SpawnBoss(base + Vector3.new(0, 0, 20), "ScorpionQueen"), "boss")
-- RM.TeleportPlayer, not a raw CFrame: a charging boss moves fast, and following it with
-- raw jumps trips the server's speed check, which snaps the hero back to the spawn
local function hold(dist: number, mateSide: number)
	local y = rp.Root.Position.Y - 3.5
	RM.TeleportPlayer(rp, Vector3.new(boss.Pos.X - dist, y, boss.Pos.Z))
	RM.TeleportPlayer(mate, Vector3.new(boss.Pos.X + mateSide, y, boss.Pos.Z))
end
for _ = 1, 120 do
	if not boss.Invulnerable and boss.BossState ~= "Entrance" then break end
	hold(10, 16)
	advance(0.1)
end
table.clear(notices)
local opened = false
for _ = 1, math.ceil((Config.CoopBoss.HoldSeconds + 3) / 0.1) do
	hold(10, 16)
	advance(0.1)
	if state:GetAttribute("BossWeakSpot") then
		opened = true
		break
	end
end
-- the side is measured on the tick the spot opened: a charging boss moves on afterwards
local openDot = nil
do
	local spot0 = state:GetAttribute("BossWeakSpot")
	if typeof(spot0) == "Vector3" then
		openDot = ((spot0 - boss.Pos) * FLAT).Unit:Dot(((rp.Root.Position - boss.Pos) * FLAT).Unit)
	end
end
check(opened, "boss: the weak spot opens after the holder keeps aggro", boss.BossState)
check(state:GetAttribute("BossAggroId") == me.UserId, "boss: aggro holder published", state:GetAttribute("BossAggroId"))
local noticed = false
for _, n in ipairs(notices) do if n.Id == "boss.weakspot" then noticed = true end end
check(noticed, "boss: telegraphed with a notice")
advance(0.1)
check(WeakSpotC.BadgeText() == "HOLD AGGRO", "boss: holder's badge", WeakSpotC.BadgeText())
local marker = WeakSpotC.Marker()
check(marker and marker.Transparency < 1, "boss: client marker behind the boss")
check(openDot ~= nil and openDot < -0.5, "boss: the spot is on the far side from the holder", openDot and string.format("dot %.2f", openDot))
local function hit(who, amount)
	local hp = boss.HP
	ES.Damage(boss, amount, who, nil, nil, true)
	return hp - boss.HP
end
hold(10, 16)
local back = hit(mate, 100)
check(math.abs(back - 100 * Config.CoopBoss.Mult) < 0.01, "boss: partner behind deals Mult", back)
check(math.abs(hit(rp, 100) - 100) < 0.01, "boss: the holder deals normal damage")
place(mate, boss.Pos + Vector3.new(-14, 0, 3))
check(math.abs(hit(mate, 100) - 100) < 0.01, "boss: partner in front deals normal damage")
place(mate, boss.Pos + Vector3.new(16, 0, 0))
for _ = 1, 40 do hit(mate, 1000) end
check(boss.WeakBonus <= boss.MaxHP * Config.CoopBoss.MaxBonusShare + 0.01, "boss: bonus capped per opening", string.format("%.0f <= %.0f", boss.WeakBonus, boss.MaxHP * Config.CoopBoss.MaxBonusShare))
-- the aggro moves: closes
local closed = false
for _ = 1, 40 do
	place(rp, boss.Pos + Vector3.new(-60, 0, 0))
	place(mate, boss.Pos + Vector3.new(8, 0, 0))
	advance(0.1)
	if state:GetAttribute("BossWeakSpot") == nil then closed = true break end
end
check(closed, "boss: the spot closes when the aggro moves")
ES.Despawn(boss)
advance(0.2)
check(state:GetAttribute("BossWeakSpot") == nil and state:GetAttribute("BossAggroId") == nil, "boss: state cleared with the boss")
-- another boss: no variant
local moth = assert(ES.SpawnBoss(base + Vector3.new(0, 0, 20), "MothMatriarch"), "moth")
for _ = 1, 150 do
	place(rp, moth.Pos + Vector3.new(-10, 0, 0)); place(mate, moth.Pos + Vector3.new(16, 0, 0))
	advance(0.1)
end
check(state:GetAttribute("BossWeakSpot") == nil and not Coop.Active(moth), "boss: other bosses unchanged")
ES.Despawn(moth)
endRun()
check(state:GetAttribute("TeamCombo") == nil and state:GetAttribute("TeamComboPair") == nil, "combo: attributes cleared after the run")

------------------------------------------------------------------------------------------
-- 20) spectate (Trio)
------------------------------------------------------------------------------------------
rps = startTeam({ me, ava, ben }, "Trio")
rp = rps[1]
local a, b = rps[2], rps[3]
base = rp.Root.Position
place(a, base + Vector3.new(30, 0, 0))
place(b, base + Vector3.new(-30, 0, 10))
rp.InvulnUntil = 0
rp.RevivesLeft = 0
rp.Stats.MaxHP = 50
rp.HP = 1
LUS.Cancel(rp)
RM.DamagePlayer(rp, 1e6, "Test")
advance(0.2)
if rp.AwaitingRevive then
	preview.fireServerAs(me, "ReviveDecline")
	advance(0.5)
end
local function stay() place(a, base + Vector3.new(30, 0, 0)); place(b, base + Vector3.new(-30, 0, 10)) end
run(0.5, stay)
check(me:GetAttribute("Alive") == false, "spectate: the local player is down")
check(SpectateC.Active() and preview.playerGui().Spectate.Enabled, "spectate: the bar shows")
local first = Camera.Spectated()
check(first == ava or first == ben, "spectate: the camera follows a living teammate", first and first.Name)
local second = SpectateC.Cycle(1)
check(second ~= nil and second ~= first, "spectate: next teammate", second and second.Name)
advance(0.1)
check(preview.playerGui().Spectate.Row.Watching.Who.Text == "WATCHING " .. string.upper(second.DisplayName), "spectate: name shown", preview.playerGui().Spectate.Row.Watching.Who.Text)
key(Enum.KeyCode.Right)
check(Camera.Spectated() == first, "spectate: Right key cycles back")
preview.playerGui().Spectate.Row.Prev.Activated:_fire()
advance(0.1)
check(Camera.Spectated() == second, "spectate: the < arrow cycles")
run(1, stay)
local cam = workspace.CurrentCamera
local watched = assert(Camera.Spectated())
local wroot = watched.Character and watched.Character:FindFirstChild("HumanoidRootPart")
check(wroot and ((cam.Focus.Position - wroot.Position) * FLAT).Magnitude < 3, "spectate: camera is on the watched teammate")
table.clear(shown)
check(SpectateC.AskRevive(), "spectate: REVIVE ME sent")
advance(0.1)
local toMates = 0
for _, s in ipairs(shown) do
	if s.Data.Kind == "ReviveMe" and ((s.Data.Position - rp.Root.Position) * FLAT).Magnitude < 1 then toMates += 1 end
end
check(toMates == 3, "spectate: teammates see REVIVE ME at the body", toMates)
check(not SpectateC.AskRevive(), "spectate: REVIVE ME rate limited")
check(not Ping.Send(ava, "ReviveMe"), "spectate: a living player cannot send REVIVE ME")
-- revived: the bar goes, the camera comes home (stream E1: the teammate holds interact for 3 s)
run(4, function() place(a, base + Vector3.new(2, 0, 0)); place(b, base + Vector3.new(-30, 0, 10)); preview.fireServerAs(ava, "ReviveHold", true) end)
preview.fireServerAs(ava, "ReviveHold", false)
check(me:GetAttribute("Alive") == true, "spectate: partner revive works")
run(1.5)
check(not SpectateC.Active() and not preview.playerGui().Spectate.Enabled, "spectate: bar gone after the revive")
check(Camera.Spectated() == nil and ((cam.Focus.Position - rp.Root.Position) * FLAT).Magnitude < 3, "spectate: camera back on the own hero")
endRun()
check(not preview.playerGui().Spectate.Enabled and me:GetAttribute("InRun") ~= true, "spectate: nothing left after the run")

------------------------------------------------------------------------------------------
-- solo: nothing
------------------------------------------------------------------------------------------
preview.remote("StartRun"):FireServer("Solo")
advance(4)
rp = assert(RM.GetRunPlayer(me), "solo run")
tough(rp)
run(3)
check(state:GetAttribute("TeamCombo") == nil, "solo: no combo meter")
ok, why = Combo.Fire(me)
check(not ok and why == "norun", "solo: combo refused", why)
advance(2.1)
check(not Ping.Send(me, "OnMyWay") and not Ping.Send(me, "Wave"), "solo: no quick pings")
clearEnemies()
boss = assert(ES.SpawnBoss(rp.Root.Position + Vector3.new(0, 0, 20), "ScorpionQueen"), "solo boss")
for _ = 1, 150 do
	place(rp, boss.Pos + Vector3.new(-10, 0, 0))
	advance(0.1)
end
check(state:GetAttribute("BossWeakSpot") == nil and not Coop.Active(boss), "solo: the Queen has no weak spot")
check(math.abs(hit(rp, 100) - 100) < 0.01, "solo: boss damage unchanged")
ES.Despawn(boss)
endRun()

------------------------------------------------------------------------------------------
-- every TEAM switch off (Duo)
------------------------------------------------------------------------------------------
for _, f in ipairs({ "TeamCombo", "QuickPings", "CoopBoss", "Spectate" }) do
	Config.Features[f] = false
end
rps = startTeam({ me, ava }, "Duo")
rp, mate = rps[1], rps[2]
base = rp.Root.Position
run(5, function() place(rp, base); place(mate, base + Vector3.new(5, 0, 0)) end)
check(state:GetAttribute("TeamCombo") == nil, "off: no combo meter")
ok, why = Combo.Fire(me)
check(not ok and why == "off", "off: combo refused", why)
advance(2.1)
check(not Ping.Send(me, "OnMyWay") and not Ping.Send(me, "Portal"), "off: quick pings refused")
check(Ping.Send(me, "Help"), "off: the old pings still work")
controls.Ping.Activated:_fire()
advance(0.1)
check(controls.PingOptions.Visible and not Wheel.IsOpen(), "off: PING opens the old panel")
controls.Ping.Activated:_fire()
advance(0.1)
clearEnemies()
boss = assert(ES.SpawnBoss(base + Vector3.new(0, 0, 20), "ScorpionQueen"), "boss off")
for _ = 1, 150 do
	place(rp, boss.Pos + Vector3.new(-10, 0, 0)); place(mate, boss.Pos + Vector3.new(16, 0, 0))
	advance(0.1)
end
check(state:GetAttribute("BossWeakSpot") == nil, "off: no weak spot")
check(math.abs(hit(mate, 100) - 100) < 0.01, "off: boss damage unchanged")
ES.Despawn(boss)
rp.InvulnUntil = 0
rp.RevivesLeft = 0
rp.Stats.MaxHP = 50
rp.HP = 1
LUS.Cancel(rp)
RM.DamagePlayer(rp, 1e6, "Test")
advance(0.2)
if rp.AwaitingRevive then preview.fireServerAs(me, "ReviveDecline"); advance(0.5) end
run(0.5, function() place(mate, base + Vector3.new(40, 0, 0)) end)
check(me:GetAttribute("Alive") == false and not SpectateC.Active() and not preview.playerGui().Spectate.Enabled, "off: no spectate bar (the old auto-follow stays)")
check(Camera.Spectated() == ava, "off: camera still follows the teammate")
check(not TeamPingsC.Send("ReviveMe"), "off: no REVIVE ME")
endRun()
preview.log(string.format("team-regression: %d failure(s)", fails))
if fails > 0 then
	preview.log("FAIL team-regression")
end
