-- quick-resume-regression: Quick resume (Config.Features.QuickResume; docs/next/QUICK_RESUME.md).
-- Real teleports and separate servers need Studio / the live game (BLOCKED offline); like the
-- existing reconnect scenes (coop-regression, reconnect-lobby) this mocks them.
--   --set case=local   (default; Studio, the run plays on this server)
--       1) a solo disconnect holds the run: frozen (run clock stopped, nothing simulates),
--          the hero out of the run (nothing can damage it), escrow kept, SoloResume saved
--       2) a wrong user can't resume (remote and TryReconnect)
--       3) the same UserId back within the window: the RESUME RUN offer first, then the same
--          run id, build, HP, gold, XP, level, kills and stage; DEV taint kept; one resume
--          per disconnect; the clock runs again; ending it settles once
--       4) nobody back in time: the hold ends once, the boards get the run's score once,
--          the world is freed; the next join settles the gold once (kept rule), no card
--       5) back on this server but no tap: the full leave commit once at expiry
--       6) switch off: a solo disconnect ends the run at once, as before
--   --set case=run [--set rejoin=expired]   a reserved run server with a solo ticket: hold on
--       disconnect, no auto-route saved, a stranger with the run id is refused, the owner's
--       SwarmRejoin restores the same run (expired: refused and settled once)
--   --set case=lobby --set flow=resume|end|timeout|expired   a public lobby: the card first
--       (no teleport), a stranger's tap does nothing, RESUME teleports once with the saved
--       access code (never in teleport data), END settles once, the window running out
--       settles once, an expired save settles on load with no card
--   --set case=card   (client; registered as a layout check on iphone / phone-portrait / pc)
--       the RESUME RUN (0:42) card: shown first as a UIState primary, END RUN needs two taps,
--       RESUME sends once, hides with the attribute / in a run. The last frame shows it.
-- PASS / FAIL lines; any FAIL fails the regression.
local C = lib("common")
local Players = game:GetService("Players")
local me = Players.LocalPlayer
local case = preview.args.case or "local"

local fails = 0
local function check(label: string, ok: any, detail: string?)
	if not ok then
		fails += 1
	end
	preview.log(string.format("%s  %s%s", ok and "PASS" or "FAIL", label, detail and ("  (" .. detail .. ")") or ""))
end
local function finish(name: string)
	preview.log(fails == 0 and ("PASS quick resume " .. name) or ("FAIL quick resume " .. name .. ": " .. fails .. " failed"))
end

------------------------------------------------------------------------------------------
-- case=card: the client card (layout)
------------------------------------------------------------------------------------------
if case == "card" then
	C.lobby()
	C.startClient()
	C.sendProfile(C.profile())
	C.settle(1)
	local sent = {}
	preview.remote("QuickResume").OnServerEvent:Connect(function(_p, action)
		table.insert(sent, action)
	end)
	local Card = preview.client("ResumeCard")
	local UIState = preview.client("UIState")
	check("card hidden without a held run", not Card.Debug().Open)
	me:SetAttribute("ResumeInfo", "Stage 2  ·  Wave 7  ·  Level 14  ·  Knight")
	me:SetAttribute("ResumeEndsAt", workspace:GetServerTimeNow() + 42.5)
	C.settle(0.6)
	local d = Card.Debug()
	check("card shows first (UIState primary ResumeRun)", d.Open and UIState.IsShown("ResumeRun"))
	local resume = preview.findGui(function(g) return g:IsA("GuiButton") and g.Name == "ResumeRun" end)[1]
	check("button reads RESUME RUN (0:42)", resume ~= nil and resume.Text == "RESUME RUN (0:42)", resume and resume.Text or "none")
	check("info line", d.Info == "Stage 2  ·  Wave 7  ·  Level 14  ·  Knight", d.Info)
	local stop = preview.findGui(function(g) return g:IsA("GuiButton") and g.Name == "EndRun" end)[1]
	if stop then
		preview.click(stop)
		C.settle(0.3)
		check("END RUN: the first tap sends nothing", #sent == 0 and stop.Text == "TAP AGAIN TO END THE RUN", stop.Text)
		preview.advance(3.5, 20)
		check("END RUN: the armed tap expires", stop.Text == "END RUN", stop.Text)
	else
		check("END RUN button exists", false)
	end
	if resume then
		preview.click(resume)
		C.settle(0.2)
		preview.click(resume)
		C.settle(0.2)
		check("RESUME sends once", #sent == 1 and sent[1] == "Resume", table.concat(sent, ","))
	end
	me:SetAttribute("InRun", true)
	C.settle(0.5)
	check("card hides in a run", not Card.Debug().Open and not UIState.IsOpen("ResumeRun"))
	me:SetAttribute("InRun", false)
	me:SetAttribute("ResumeEndsAt", nil)
	C.settle(0.5)
	check("card stays hidden without the attribute", not Card.Debug().Open)
	-- the layout frame: a fresh offer
	me:SetAttribute("ResumeEndsAt", workspace:GetServerTimeNow() + 42.5)
	C.settle(1)
	check("card open for the layout frame", Card.Debug().Open)
	finish("card")
	return
end

------------------------------------------------------------------------------------------
-- case=lobby: a public lobby server with a saved held solo run (live mock)
------------------------------------------------------------------------------------------
if case == "lobby" then
	local flow = preview.args.flow or "resume"
	local T = preview.teleport()
	T.placeId = 4242
	local Data = preview.server("DataService")
	local Config = preview.shared("Config")
	local store = game:GetService("DataStoreService"):GetDataStore(Config.Data.StoreName)
	local stranger = preview.addPlayer("Stranger", 9)
	local data = Data.DefaultData()
	data.Gold = 600
	data.TutorialDone = true
	data.FirstRunBonus = true
	data.RunEscrow = { Id = "solo-run", Gold = 120, Stages = 1 }
	data.RunReconnect = { AccessCode = "secret-solo-code", PrivateId = "ps-solo", Id = "solo-run", Expires = 0 }
	data.SoloResume = { Id = "solo-run", Expires = os.time() + (flow == "expired" and -1 or flow == "timeout" and 6 or 42), Stage = 2, Level = 14, Hero = "Knight", Wave = 7 }
	store:SetAsync(Config.Data.KeyPrefix .. me.UserId, { Data = data })
	local other = Data.DefaultData()
	other.Gold = 50
	store:SetAsync(Config.Data.KeyPrefix .. stranger.UserId, { Data = other })
	preview.startServer()
	preview.playerJoined(stranger)
	preview.advance(3)
	local loaded = assert(Data.GetData(me))
	local kept = 600 + math.floor(120 * 0.5) -- 0.35 + 1 stage x 0.15
	if flow == "expired" then
		check("expired save: settled once on load (kept rule)", loaded.Gold == kept and not loaded.RunEscrow, tostring(loaded.Gold))
		check("expired save: route and resume cleared, no card", not loaded.RunReconnect and not loaded.SoloResume and me:GetAttribute("ResumeEndsAt") == nil)
		check("expired save: no teleport", #T.calls == 0)
		finish("lobby expired")
		return
	end
	check("card first: no teleport on join", #T.calls == 0 and not Data.IsReleased(me))
	check("escrow kept while the card shows", loaded.Gold == 600 and loaded.RunEscrow and loaded.RunEscrow.Gold == 120)
	local endsAt = me:GetAttribute("ResumeEndsAt")
	check("offer attribute set", type(endsAt) == "number" and endsAt > workspace:GetServerTimeNow())
	check("offer info", me:GetAttribute("ResumeInfo") == "Stage 2  ·  Wave 7  ·  Level 14  ·  Knight", tostring(me:GetAttribute("ResumeInfo")))
	check("auto co-op route not armed", loaded.RunReconnect and loaded.RunReconnect.Expires == 0)
	preview.fireServerAs(stranger, "QuickResume", "Resume")
	preview.advance(0.6)
	check("a stranger's RESUME does nothing", #T.calls == 0 and Data.GetData(stranger).Gold == 50 and stranger:GetAttribute("ResumeEndsAt") == nil)
	if flow == "resume" then
		preview.fireServerAs(me, "QuickResume", "Resume")
		preview.advance(0.6)
		check("RESUME teleports once", #T.calls == 1 and T.reserved == 0, tostring(#T.calls))
		local call = T.calls[1]
		check("to the saved reserved server, rejoin ticket only", call and call.Code == "secret-solo-code" and call.Data.SwarmRejoin and call.Data.SwarmRejoin.Id == "solo-run" and not call.Data.SwarmRun and not call.Data.AccessCode)
		check("save released with escrow unspent", Data.IsReleased(me) and loaded.Gold == 600 and loaded.RunEscrow.Gold == 120)
		check("route armed for the run server only now", loaded.RunReconnect.Expires == loaded.SoloResume.Expires)
		preview.fireServerAs(me, "QuickResume", "Resume")
		preview.advance(0.6)
		check("a second tap does not teleport again", #T.calls == 1)
	elseif flow == "end" then
		preview.fireServerAs(me, "QuickResume", "End")
		preview.advance(0.6)
		check("END RUN settles once (kept rule)", loaded.Gold == kept and not loaded.RunEscrow and not loaded.SoloResume and not loaded.RunReconnect, tostring(loaded.Gold))
		preview.fireServerAs(me, "QuickResume", "End")
		preview.advance(1.2)
		check("END again pays nothing", loaded.Gold == kept and #T.calls == 0)
	elseif flow == "timeout" then
		preview.advance(8, 10)
		check("window ran out in the lobby: settled once", loaded.Gold == kept and not loaded.RunEscrow and not loaded.SoloResume, tostring(loaded.Gold))
		check("card removed", me:GetAttribute("ResumeEndsAt") == nil and #T.calls == 0)
		preview.fireServerAs(me, "QuickResume", "Resume")
		preview.advance(1)
		check("a late RESUME does nothing", loaded.Gold == kept and #T.calls == 0)
	end
	finish("lobby " .. flow)
	return
end

------------------------------------------------------------------------------------------
-- case=run: a reserved run server with a solo ticket (live mock)
------------------------------------------------------------------------------------------
if case == "run" then
	local T = preview.teleport()
	T.placeId, T.privateServerId, T.privateServerOwnerId = 4242, "ps-solo", 0
	T.joinData[1] = { SwarmRun = { V = 1, Mode = "Solo", Members = { 1 }, Starter = 1, Arena = "Forest" } }
	local Data = preview.server("DataService")
	local Config = preview.shared("Config")
	local store = game:GetService("DataStoreService"):GetDataStore(Config.Data.StoreName)
	local data = Data.DefaultData()
	data.Gold = 500
	data.TutorialDone = true
	data.FirstRunBonus = true
	data.RunReconnect = { AccessCode = "secret-code", PrivateId = "ps-solo", Id = "", Expires = 0 }
	store:SetAsync(Config.Data.KeyPrefix .. me.UserId, { Data = data })
	preview.startServer()
	preview.advance(2)
	local RM, RS, Gold = preview.server("RunManager"), preview.server("RunServers"), preview.server("GoldSystem")
	local rp = RM.GetRunPlayer(me)
	check("the solo ticket starts the run", rp ~= nil)
	if not rp then
		finish("run")
		return
	end
	rp.InvulnUntil = math.huge
	Gold.AddRunGold(rp, 100)
	local oldId, oldLevel, oldGold, oldHP = rp.RunId, rp.Level, rp.Gold, rp.HP
	check("co-op route not used for solo", not RS.CanReconnect(rp))
	preview.removePlayer(me)
	preview.advance(0.2)
	local saved = store:GetAsync(Config.Data.KeyPrefix .. me.UserId).Data
	check("disconnect holds the run (frozen, world kept)", RM.SoloHoldFor(1) ~= nil and RM.IsRunning() and RM.IsFrozen())
	check("save keeps escrow + SoloResume, no auto-route", saved.Gold == 500 and saved.RunEscrow and saved.RunEscrow.Gold == oldGold
		and type(saved.SoloResume) == "table" and saved.SoloResume.Id == oldId and not RS.HasPendingReconnect(saved))
	-- what the lobby's RESUME does before the teleport (RunServers.ResumeSolo): arm the route
	saved.RunReconnect.Expires = saved.SoloResume.Expires
	if preview.args.rejoin == "expired" then
		saved.SoloResume.Expires = os.time() - 1
		saved.RunReconnect.Expires = os.time() - 1
	end
	store:SetAsync(Config.Data.KeyPrefix .. me.UserId, { Data = saved })
	-- a stranger carrying the run id
	local strangerSave = Data.DefaultData()
	store:SetAsync(Config.Data.KeyPrefix .. 9, { Data = strangerSave })
	T.joinData[9] = { SwarmRejoin = { Id = oldId } }
	local stranger = preview.addPlayer("Stranger", 9)
	preview.playerJoined(stranger)
	preview.advance(1)
	check("a stranger with the run id is refused", RM.GetRunPlayer(stranger) == nil and RM.SoloHoldFor(1) ~= nil and not RM.TryReconnect(stranger, oldId))
	T.joinData[1] = { SwarmRejoin = { Id = oldId } }
	local returned = preview.addPlayer("Returned", 1)
	preview.playerJoined(returned)
	preview.advance(1)
	if preview.args.rejoin == "expired" then
		check("expired rejoin: not restored", RM.GetRunPlayer(returned) == nil)
		local d = Data.GetData(returned)
		check("expired rejoin: escrow settled once", d and d.Gold == 500 + math.floor(oldGold * Config.Gold.FailureRetainBase) and not d.RunEscrow, d and tostring(d.Gold) or "no data")
		RM.SoloAway.Expires = 0
		preview.advance(0.5)
		check("the hold ends and frees the run", RM.SoloHoldFor(1) == nil and not RM.IsRunning())
		check("no second payout", d and d.Gold == 500 + math.floor(oldGold * Config.Gold.FailureRetainBase))
		finish("run expired")
		return
	end
	local resumed = RM.GetRunPlayer(returned)
	check("the owner's rejoin restores the same run", resumed ~= nil and resumed.RunId == oldId and resumed.Level == oldLevel and resumed.Gold == oldGold and resumed.HP == oldHP)
	check("hold cleared, world running", RM.SoloHoldFor(1) == nil and not RM.IsFrozen())
	local d = Data.GetData(returned)
	check("save: SoloResume consumed, no payout", d and d.SoloResume == nil and d.Gold == 500)
	check("one resume per disconnect", not RM.TryReconnect(returned, oldId))
	finish("run")
	return
end

------------------------------------------------------------------------------------------
-- case=local: the run on this server (Studio / offline)
------------------------------------------------------------------------------------------
preview.forceMeshesUploaded()
preview.startServer()
preview.advance(2)
local Config = C.shared("Config")
local RM = preview.server("RunManager")
local DS = preview.server("DataService")
local GS = preview.server("GoldSystem")
local QR = preview.server("QuickResume")
local LB = preview.server("LeaderboardService")
local SM = preview.server("StageManager")

check("QuickResume switch on by default", Config.Features.QuickResume == true)
check("window is 60 s", Config.RunServers.SoloResumeSeconds == 60 and QR.Window() == 60)

local submits: { [string]: number } = {}
local realSubmit = LB.Submit
LB.Submit = function(player, board, value, day, runId)
	local key = tostring(runId) .. "|" .. tostring(board)
	submits[key] = (submits[key] or 0) + 1
	return realSubmit(player, board, value, day, runId)
end

local function setup(d)
	d.OwnedCharacters = { Knight = true }
	d.SelectedCharacter = "Knight"
	d.TutorialDone = true
	d.FirstRunBonus = true
	d.Gold = 500
end
setup(assert(DS.GetData(me)))

local function startSolo(p)
	local ok = RM.StartTeamRun({ p }, "Solo", "Forest", p)
	preview.advance(3)
	local rp = RM.GetRunPlayer(p)
	if rp then
		rp.InvulnUntil = 0
		rp.Offer = nil
	end
	return ok and rp or nil
end

local function join(name: string)
	local p = preview.addPlayer(name, 1)
	preview.playerJoined(p)
	preview.advance(1.5)
	return p
end

-- 1) hold
local rp = startSolo(me)
check("solo run started", rp ~= nil)
if not rp then
	finish("local")
	return
end
GS.AddRunGold(rp, 200)
rp.Kills, rp.PendingLevels = 37, 0
rp.DevTainted = true -- DEV taint must survive the resume
RM.RefreshFrozen()
local before = { Id = rp.RunId, Level = rp.Level, XP = rp.XP, Gold = rp.Gold, HP = rp.HP, Kills = rp.Kills, Stage = SM.GetStage(), Weapons = #(rp.WeaponOrder or {}) }
preview.removePlayer(me)
preview.advance(0.3)
local hold = RM.SoloHoldFor(1)
check("a solo disconnect holds the run", hold ~= nil and RM.IsRunning())
check("the held run is frozen (nothing simulates)", RM.IsFrozen() and not RM.IsSimulating())
check("the hero is out of the run (nothing can damage it)", #RM.GetRunPlayers() == 0)
local t0 = RM.GetRunTime()
preview.advance(4, 10)
check("the run clock is paused", RM.GetRunTime() == t0, string.format("%.2f -> %.2f", t0, RM.GetRunTime()))

-- 2) a wrong user
local stranger = preview.addPlayer("Stranger", 7)
preview.playerJoined(stranger)
preview.advance(1.5)
preview.fireServerAs(stranger, "QuickResume", "Resume")
preview.advance(0.5)
check("a wrong user can't resume", RM.GetRunPlayer(stranger) == nil and RM.SoloHoldFor(1) ~= nil and not RM.TryReconnect(stranger, before.Id))
check("a wrong user gets no card", stranger:GetAttribute("ResumeEndsAt") == nil)

-- 3) back within the window
local returned = join("Returned")
local d = DS.GetData(returned)
check("back in time: the RESUME RUN offer first", type(returned:GetAttribute("ResumeEndsAt")) == "number" and RM.GetRunPlayer(returned) == nil)
check("escrow kept while the card shows", d and d.Gold == 500 and d.RunEscrow and d.RunEscrow.Id == before.Id and QR.Pending(d))
preview.fireServerAs(returned, "QuickResume", "Resume")
preview.advance(0.6)
local resumed = RM.GetRunPlayer(returned)
check("resume restores the same run", resumed ~= nil and resumed.RunId == before.Id)
if resumed then
	check("same build, HP, gold, XP, level, kills and stage", resumed.Level == before.Level and resumed.XP == before.XP and resumed.Gold == before.Gold
		and resumed.HP == before.HP and resumed.Kills == before.Kills and SM.GetStage() == before.Stage and #(resumed.WeaponOrder or {}) == before.Weapons)
	check("DEV taint kept", resumed.DevTainted == true)
end
check("hold and card cleared", RM.SoloHoldFor(1) == nil and not RM.IsFrozen() and returned:GetAttribute("ResumeEndsAt") == nil and d and d.SoloResume == nil)
check("one resume per disconnect", not RM.TryReconnect(returned, before.Id))
local t1 = RM.GetRunTime()
preview.advance(1)
check("the run clock runs again", RM.GetRunTime() > t1)
local escrowNow = d and d.RunEscrow and d.RunEscrow.Gold or before.Gold -- kills after the resume may add gold
if resumed then
	RM.AbandonRun(resumed)
	preview.advance(1)
end
local expectGold = 500 + math.floor(escrowNow * GS.RetentionRate(0))
check("ending it settles once (kept rule)", d and d.Gold == expectGold and not d.RunEscrow, d and tostring(d.Gold) or "")
check("no second settlement", d and GS.RecoverEscrow(d) == 0 and QR.Settle(returned, d) == 0 and d.Gold == expectGold)
check("a DEV-tainted run sends no boards", (submits[before.Id .. "|Score"] or 0) == 0)

-- 4) nobody back in time (a short window for the test; 60 s is checked above)
Config.RunServers.SoloResumeSeconds = 6
local rp2 = startSolo(returned)
check("second solo run started", rp2 ~= nil)
if rp2 then
	GS.AddRunGold(rp2, 300)
	rp2.Kills = 12
	local id2, gold2 = rp2.RunId, rp2.Gold
	preview.removePlayer(returned)
	preview.advance(0.3)
	check("held again", RM.SoloHoldFor(1) ~= nil)
	preview.advance(8, 10)
	check("not back in time: the hold ends and frees the run", RM.SoloHoldFor(1) == nil and not RM.IsRunning())
	check("boards get the final score once", (submits[id2 .. "|Score"] or 0) == 1 and (submits[id2 .. "|Kills"] or 0) == 1, tostring(submits[id2 .. "|Score"]))
	local back = join("Back")
	local d2 = DS.GetData(back)
	local expect2 = expectGold + math.floor(gold2 * GS.RetentionRate(0))
	check("the next join settles the gold once (kept rule)", d2 and d2.Gold == expect2 and not d2.RunEscrow and not d2.SoloResume, d2 and tostring(d2.Gold) or "")
	check("no card after the window", back:GetAttribute("ResumeEndsAt") == nil)
	preview.advance(1.5)
	check("no double settlement", d2 and d2.Gold == expect2 and GS.RecoverEscrow(d2) == 0)

	-- 5) back on this server but no tap: the full leave commit at expiry
	local rp3 = startSolo(back)
	check("third solo run started", rp3 ~= nil)
	if rp3 then
		GS.AddRunGold(rp3, 150)
		local id3, gold3 = rp3.RunId, rp3.Gold
		preview.removePlayer(back)
		preview.advance(0.3)
		local again = join("Again")
		local d3 = DS.GetData(again)
		check("offer shown again", type(again:GetAttribute("ResumeEndsAt")) == "number")
		preview.advance(8, 10)
		local expect3 = expect2 + math.floor(gold3 * GS.RetentionRate(0))
		check("expiry with the player here: settled once by the leave rule", RM.SoloHoldFor(1) == nil and not RM.IsRunning() and d3 and d3.Gold >= expect3 and not d3.RunEscrow, d3 and tostring(d3.Gold) or "")
		local goldAfter = d3 and d3.Gold or 0
		check("card removed, boards once", again:GetAttribute("ResumeEndsAt") == nil and (submits[id3 .. "|Score"] or 0) == 1)
		preview.advance(1.5)
		check("no double settlement", d3 and d3.Gold == goldAfter and GS.RecoverEscrow(d3) == 0)

		-- 6) switch off: as before (the run ends at once)
		Config.Features.QuickResume = false
		local rp4 = startSolo(again)
		if rp4 then
			preview.removePlayer(again)
			preview.advance(0.5)
			check("switch off: a solo disconnect ends the run at once", RM.SoloHoldFor(1) == nil and not RM.IsRunning())
		else
			check("fourth solo run started", false)
		end
		Config.Features.QuickResume = true
	end
end
Config.RunServers.SoloResumeSeconds = 60
LB.Submit = realSubmit
finish("local")
