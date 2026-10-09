-- revive-thanks-regression: the THANKS! button after a teammate revive (Config.Features.ReviveThanks,
-- server ReviveThanks.lua, client ReviveThanks.lua, docs/next/REVIVE_THANKS.md) against the real server.
--   1) a real proximity revive makes one offer for the revived player only; the client shows it
--      for Config.Revive.ThanksSeconds and a tap sends the offer id; the reviver gets the
--      "<name> says thanks!" notice and exactly Config.Revive.ThanksXP run XP, once
--   2) refusals: repeated tap, wrong / junk ids, a player with no offer, an expired offer,
--      a replaced offer, no self-revive offer, no offer in a solo run
--   3) pair limit: at most Config.Revive.ThanksPerPair per run for one pair
--   4) DEV taint: no offer for a tainted run; a taint after the offer blocks the payout
--   5) switch off: no offer, nothing paid
--   6) client: the button shows for the offer's time, hides after use and after the time is up
-- Prints PASS / FAIL lines; any FAIL fails the regression.
local C = lib("common")
local Players = game:GetService("Players")
local me = Players.LocalPlayer
local ava = preview.addPlayer("Ava", 2)
local ben = preview.addPlayer("Ben", 3)
preview.forceMeshesUploaded()
preview.startServer()
preview.advance(1)
C.startClient() -- headless: the client module is required but ClientMain does not run (a full client sim is far too slow), so the offer is handed to RTc.Receive below; the layout scene covers the button on screen
preview.advance(1)

local RM = preview.server("RunManager")
local RT = preview.server("ReviveThanks")
local XP = preview.server("XPSystem")
local Remotes = preview.shared("Remotes")
local Config = preview.shared("Config")
local RTc = preview.client("ReviveThanks")
local R = Config.Revive

local fails = 0
local function check(label: string, ok: boolean, detail: string?)
	if not ok then
		fails += 1
	end
	preview.log(string.format("%s  %s%s", ok and "PASS" or "FAIL", label, detail and ("  (" .. detail .. ")") or ""))
end

-- every offer / notice the server sends, and every GiveXP call
local offers: { [Player]: { any } } = {}
local notices: { [Player]: { any } } = {}
local origFire = Remotes.FireClient
Remotes.FireClient = function(name, p, ...)
	if name == "ReviveThanksOffer" then
		offers[p] = offers[p] or {}
		table.insert(offers[p], (...))
		if p == me then
			RTc.Receive((...)) -- the OnClientEvent connection
		end
	elseif name == "Notify" then
		notices[p] = notices[p] or {}
		table.insert(notices[p], (...))
	end
	return origFire(name, p, ...)
end
local xpCalls: { { Who: any, Amount: number } } = {}
local origGive = XP.GiveXP
XP.GiveXP = function(rp, amount)
	table.insert(xpCalls, { Who = rp, Amount = amount })
	return origGive(rp, amount)
end
local function thanksNotes(p: Player): number
	local n = 0
	for _, d in ipairs(notices[p] or {}) do
		if type(d) == "table" and type(d.Text) == "string" and string.find(d.Text, "says thanks!", 1, true) then
			n += 1
		end
	end
	return n
end
local function paid(rp): number
	local n = 0
	for _, c in ipairs(xpCalls) do
		if c.Who == rp and c.Amount == R.ThanksXP then
			n += 1
		end
	end
	return n
end
local function tap(p: Player, id: any)
	if p == me then
		preview.remote("ReviveThanks"):FireServer(id)
	else
		preview.fireServerAs(p, "ReviveThanks", id)
	end
	preview.advance(0.6)
end

check("ReviveThanks switch on by default", Config.Features.ReviveThanks == true)
check("proposed numbers: 25 XP, 6 s, 3 per pair", R.ThanksXP == 25 and R.ThanksSeconds == 6 and R.ThanksPerPair == 3)

-- a Duo run: me (revived) and Ava (the reviver)
assert(RM.StartTeamRun({ me, ava }, "Duo", "Forest", me))
preview.advance(6)
local rp, helper = assert(RM.GetRunPlayer(me)), assert(RM.GetRunPlayer(ava))
rp.InvulnUntil, helper.InvulnUntil = 0, math.huge
-- no kill-XP level-ups in this scene (the redesign economy's personal shards and its
-- 20-XP first level open panels every few seconds; a chooser can't be hit): only the
-- thank-you XP is measured here, through GiveXP
rp.XPNeeded, helper.XPNeeded = 1e12, 1e12
rp.RevivesLeft, rp.ProductReviveUsed = 0, true
local function stand(distance: number)
	helper.Root.CFrame = CFrame.new(rp.Root.Position + Vector3.new(distance, 0, 0))
	helper.Root.AssemblyLinearVelocity = Vector3.zero
	helper.LastValidPos = helper.Root.Position
	helper.SpeedCheckTimer = 0
end
local LU = preview.server("LevelUpSystem")
local function reviveByHelper()
	-- thank-you XP can level the reviver up: an open card panel pauses them (no reviving), so clear it
	for _, who in ipairs({ { me, rp }, { ava, helper } }) do
		for _ = 1, 40 do
			if who[2].Offer == nil and not who[2].Paused and (who[2].PendingLevels or 0) == 0 then
				break
			end
			if who[2].Offer ~= nil then
				if who[1] == me then
					preview.remote("LevelUpChoose"):FireServer(1, game:GetService("Players").LocalPlayer:GetAttribute("ChoiceOfferId"))
				else
					preview.fireServerAs(who[1], "LevelUpChoose", 1, who[1]:GetAttribute("ChoiceOfferId"))
				end
			else
				LU.Cancel(who[2])
			end
			preview.advance(0.3)
		end
	end
	rp.InvulnUntil = 0
	RM.DamagePlayer(rp, 1e6, "Test boss strike")
	stand(25)
	preview.advance(0.3)
	stand(2)
	preview.advance(2.4)
end

-- 1) a real revive makes the offer; the client shows it; the tap pays once
reviveByHelper()
check("the revive happened", rp.Alive == true and rp.PartnerRevives == 1)
check("one offer, to the revived player only", #(offers[me] or {}) == 1 and #(offers[ava] or {}) == 0)
local offer = (offers[me] or {})[1] or {}
check("offer carries id, 6 s and the reviver's name", type(offer.Id) == "number" and offer.Seconds == R.ThanksSeconds and offer.FromName == "Ava")
check("the client holds the offer", RTc.Active() == true)
preview.advance(0.3)
check("nothing was paid before the tap", paid(helper) == 0 and thanksNotes(ava) == 0)
check("the client tap sends the offer", RTc.Tap() == true)
preview.advance(0.6)
check("the reviver got '<name> says thanks!'", thanksNotes(ava) == 1)
check("and exactly ThanksXP run XP, once", paid(helper) == 1)
check("the button is gone after the tap", RTc.Active() == false and RTc.Tap() == false)
-- a repeat from a modified client
tap(me, offer.Id)
tap(me, offer.Id)
check("a repeated tap pays nothing more", thanksNotes(ava) == 1 and paid(helper) == 1)
check("the pair count is 1", rp.ThanksGiven ~= nil and rp.ThanksGiven[ava.UserId] == 1)

-- 2) refusals
local id2 = RT.OnRevived(rp, helper)
check("a second revive makes a new offer id", type(id2) == "number" and id2 ~= offer.Id)
for _, bad in ipairs({ 0, -1, id2 + 1, id2 - 1, "x", 0 / 0, math.huge, { id2 }, true }) do
	tap(me, bad)
end
tap(me, nil)
check("junk and wrong ids pay nothing", paid(helper) == 1 and thanksNotes(ava) == 1)
tap(ben, id2) -- not in the run
tap(ava, id2) -- the reviver has no offer: can't thank themselves
check("outsiders and the reviver can't use someone else's offer", paid(helper) == 1)
check("no self-revive offer", RT.OnRevived(rp, rp) == nil)
local idOld = RT.OnRevived(rp, helper)
local id3 = RT.OnRevived(rp, helper)
check("a newer offer replaces an older open one", RT.Check(me, idOld) == "offer" and RT.Check(me, id3) == nil)
tap(me, idOld)
check("the replaced offer pays nothing", paid(helper) == 1)
-- expiry: ThanksSeconds + grace
preview.advance(R.ThanksSeconds + R.ThanksGrace + 0.5)
check("an expired offer is refused", RT.Check(me, id3) == "expired")
tap(me, id3)
check("an expired tap pays nothing", paid(helper) == 1 and thanksNotes(ava) == 1)
-- the reviver left the run
local id4 = RT.OnRevived(rp, helper)
helper.Returned = true
check("a reviver who left the run can't be thanked", RT.Check(me, id4) == "helper")
helper.Returned = nil

-- 3) pair limit: three thank-yous, the fourth is refused
rp.ThanksGiven = nil
local before = paid(helper)
local okCount = 0
for _ = 1, R.ThanksPerPair do
	local id = RT.OnRevived(rp, helper)
	if RT.Thank(me, id) then
		okCount += 1
	end
end
check("three thank-yous go through", okCount == R.ThanksPerPair and paid(helper) == before + R.ThanksPerPair)
local idPair = RT.OnRevived(rp, helper)
check("the fourth for the same pair is refused", RT.Check(me, idPair) == "pair" and RT.Thank(me, idPair) == false and paid(helper) == before + R.ThanksPerPair)

-- 4) DEV taint
rp.ThanksGiven = nil
helper.DevTainted = true
check("no offer when the reviver's run is DEV-tainted", RT.OnRevived(rp, helper) == nil)
helper.DevTainted = nil
local idDev = RT.OnRevived(rp, helper)
helper.DevTainted = true
check("a taint after the offer blocks the payout", RT.Check(me, idDev) == "dev" and RT.Thank(me, idDev) == false and paid(helper) == before + R.ThanksPerPair)
helper.DevTainted = nil
rp.DevTainted = true
check("no offer when the revived player's run is DEV-tainted", RT.OnRevived(rp, helper) == nil)
rp.DevTainted = nil

-- 5) switch off
Config.Features.ReviveThanks = false
check("switch off: no offer", RT.OnRevived(rp, helper) == nil)
local idOff = nil
Config.Features.ReviveThanks = true
idOff = RT.OnRevived(rp, helper)
Config.Features.ReviveThanks = false
check("switch off: a tap pays nothing", RT.Check(me, idOff) == "feature" and RT.Thank(me, idOff) == false)
Config.Features.ReviveThanks = true

-- 6) client: the button hides when the time is up (a real second revive, not tapped)
local clientBefore = #(offers[me] or {})
reviveByHelper()
check("the second real revive made an offer", #(offers[me] or {}) == clientBefore + 1 and rp.PartnerRevives == 2, string.format("offers %d->%d revives=%s alive=%s hpaused=%s hoffer=%s hpend=%s halive=%s prog=%s", clientBefore, #(offers[me] or {}), tostring(rp.PartnerRevives), tostring(rp.Alive), tostring(helper.Paused), tostring(helper.Offer ~= nil), tostring(helper.PendingLevels), tostring(helper.Alive), tostring(rp.ReviveProgress)))
preview.advance(0.3)
check("the client holds the second offer", RTc.Active() == true)
preview.advance(R.ThanksSeconds + 0.4)
check("after 6 s the button hides", RTc.Active() == false and RTc.Tap() == false)
preview.advance(R.ThanksGrace + 0.5)
check("a late tap from a modified client pays nothing", (function()
	local n = paid(helper)
	tap(me, (offers[me] or {})[#(offers[me] or {})].Id)
	return paid(helper) == n
end)())

-- the client ignores junk offers and clamps long ones
check("client drops junk offers", RTc.Receive({ Id = "x", Seconds = 6 }) == false and RTc.Receive({ Id = 1, Seconds = -3 }) == false and RTc.Receive(nil) == false and RTc.Active() == false)
check("client never shows longer than the config", RTc.Receive({ Id = 77, Seconds = 600, FromName = "Ava" }) == true)
preview.advance(R.ThanksSeconds + 0.4)
check("...so it is gone after ThanksSeconds", RTc.Active() == false)

-- not solo: end the Duo, play alone
preview.remote("AbandonRun"):FireServer()
preview.fireServerAs(ava, "AbandonRun")
preview.advance(3)
assert(RM.StartTeamRun({ me }, "Solo", "Forest", me))
preview.advance(4)
local solo = assert(RM.GetRunPlayer(me))
check("no offer in a solo run", RT.OnRevived(solo, helper) == nil and RT.Check(me, 1) == "solo" and RT.Thank(me, 1) == false)

preview.log(fails == 0 and "ALL PASS" or (fails .. " FAIL"))
