-- party-sim: boots the REAL server (PartyService + RunManager) with three extra players
-- (preview.addPlayer, joined before the server starts so DataService loads them) and drives
-- the "Party" remote as each of them (preview.fireServerAs): invite / decline / re-invite
-- cooldown / accept / expiry / full party / kick / leave, invalid and spammed calls, a
-- non-leader start (refused), the leader's DUO (both in the run at once), TRIO with a party
-- of two (countdown, an outsider JOINs to fill it), DUO with a party of three (one left out)
-- and a member leaving the game. Prints PASS / FAIL lines.
-- Run: render.sh party-sim --devices pc --max-time 400 (no PNG worth looking at)
local C = lib("common")
local Players = game:GetService("Players")
local me = Players.LocalPlayer
local ava = preview.addPlayer("Ava", 2)
local ben = preview.addPlayer("Ben", 3)
local cal = preview.addPlayer("Cal", 4)
preview.forceMeshesUploaded()
preview.startServer()
preview.advance(2)
C.startClient()
preview.advance(1)

local st = C.state()
local RM = preview.server("RunManager")
local PS = preview.server("PartyService")
local Remotes = preview.shared("Remotes")

-- every server → client message, per player
local inbox: { [Player]: { any } } = {}
local origFire = Remotes.FireClient
Remotes.FireClient = function(name, p, ...)
	if name == "Notify" or name == "PartyState" or name == "PartyInvite" then
		inbox[p] = inbox[p] or {}
		table.insert(inbox[p], { name, ... })
	end
	return origFire(name, p, ...)
end
local function drain(p: Player): { any }
	local list = inbox[p] or {}
	inbox[p] = {}
	return list
end
local function count(p: Player, name: string, list: { any }?): number
	local n = 0
	for _, m in ipairs(list or inbox[p] or {}) do
		if m[1] == name then
			n += 1
		end
	end
	return n
end
local function lastNote(list: { any }): string
	local t = "-"
	for _, m in ipairs(list) do
		if m[1] == "Notify" and type(m[2]) == "table" then
			t = m[2].Text
		end
	end
	return t
end

local fails = 0
local function check(label: string, ok: boolean, detail: string?)
	if not ok then
		fails += 1
	end
	preview.log(string.format("%s  %s%s", ok and "PASS" or "FAIL", label, detail and ("  (" .. detail .. ")") or ""))
end
local function as(p: Player, remote: string, ...)
	if p == me then
		preview.remote(remote):FireServer(...)
	else
		preview.fireServerAs(p, remote, ...)
	end
end
local function party(p: Player)
	local pt = PS.PartyOf(p)
	if not pt then
		return "none"
	end
	local names = {}
	for _, m in ipairs(pt.Members) do
		table.insert(names, m.Name .. (pt.Leader == m and "*" or ""))
	end
	return table.concat(names, ",")
end
local step = 0.35
local function wait(t: number?)
	preview.advance(t or step)
end

-- 0. profiles loaded for everyone
check("profiles loaded", preview.server("DataService").GetData(ava) ~= nil and preview.server("DataService").GetData(me) ~= nil)
check("max party size = largest lobby mode", PS.MaxSize() == 3, tostring(PS.MaxSize()))

-- 1. invite → decline
drain(me) drain(ava)
as(me, "Party", "Invite", ava.UserId)
wait()
local a = drain(ava)
check("invite reaches Ava (PartyInvite)", count(ava, "PartyInvite", a) == 1)
as(ava, "Party", "Decline", me.UserId)
wait()
check("decline tells the inviter", string.find(lastNote(drain(me)), "declined") ~= nil)
check("no party after decline", party(me) == "none" and party(ava) == "none")

-- 2. re-invite cooldown
as(me, "Party", "Invite", ava.UserId)
wait()
check("re-invite within cooldown refused", count(ava, "PartyInvite", drain(ava)) == 0, lastNote(drain(me)))

-- 3. accept
wait(9)
as(me, "Party", "Invite", ava.UserId)
wait()
as(ava, "Party", "Accept", me.UserId)
wait()
check("accept makes a party, inviter leads", party(me) == "PreviewPlayer*,Ava", party(me))
check("PartyId attributes match", (me:GetAttribute("PartyId") or 0) ~= 0 and me:GetAttribute("PartyId") == ava:GetAttribute("PartyId"))
check("leader attribute", me:GetAttribute("PartyLeader") == true and ava:GetAttribute("PartyLeader") == false)
-- accepting twice / a stale accept does nothing
as(ava, "Party", "Accept", me.UserId)
wait()
check("stale accept ignored", party(me) == "PreviewPlayer*,Ava")

-- 4. invalid and hostile calls
drain(me) drain(ava) drain(ben) drain(cal)
local bad = {
	{ ben, "Party", "Invite", "abc" },
	{ ben, "Party", "Invite", -1 },
	{ ben, "Party", "Invite", 0 / 0 },
	{ ben, "Party", "Invite", ben.UserId },
	{ ben, "Party", "Invite", 999999 },
	{ ben, "Party", "Accept", me.UserId }, -- no invite
	{ ben, "Party", "Kick", ava.UserId }, -- not the leader
	{ ava, "Party", "Kick", me.UserId }, -- a member kicking the leader
	{ ben, "Party", "Boom", 1 },
	{ ben, "Party", nil },
	{ ben, "Party", { "Invite" }, { 2 } },
	{ ben, "PartyFollow", "x" },
	{ ben, "PartyFollow", ben.UserId },
	{ ben, "PartyFollow", ava.UserId }, -- on this server already
}
for _, b in ipairs(bad) do
	as(table.unpack(b))
	wait(0.3)
end
check("invalid calls change nothing", party(me) == "PreviewPlayer*,Ava" and party(ben) == "none")
check("no invite sent by invalid calls", count(me, "PartyInvite") + count(ava, "PartyInvite") + count(cal, "PartyInvite") == 0)
-- a member can't invite
as(ava, "Party", "Invite", cal.UserId)
wait()
check("member can't invite", count(cal, "PartyInvite", drain(cal)) == 0, lastNote(drain(ava)))

-- 5. spam: 60 invites in one frame from Ben to Cal → one invite, rate limited
for _ = 1, 60 do
	as(ben, "Party", "Invite", cal.UserId)
end
wait()
check("spam → exactly one invite", count(cal, "PartyInvite", drain(cal)) == 1)
-- expiry: the invite runs out
wait(31)
as(cal, "Party", "Accept", ben.UserId)
wait()
check("expired invite can't be accepted", party(cal) == "none" and party(ben) == "none", lastNote(drain(cal)))

-- 6. full party (max 3): Cal joins, Ben is refused
as(me, "Party", "Invite", cal.UserId)
wait()
as(cal, "Party", "Accept", me.UserId)
wait()
check("party of three", party(me) == "PreviewPlayer*,Ava,Cal", party(me))
as(me, "Party", "Invite", ben.UserId)
wait()
check("inviting into a full party refused", count(ben, "PartyInvite", drain(ben)) == 0, lastNote(drain(me)))

-- 7. kick and leave
as(me, "Party", "Kick", cal.UserId)
wait()
check("leader kicks Cal", party(me) == "PreviewPlayer*,Ava" and party(cal) == "none", party(me))
as(ava, "Party", "Leave")
wait()
check("Ava leaves: party of one closes", party(me) == "none" and party(ava) == "none" and (me:GetAttribute("PartyId") or 0) == 0)

-- 8. party of two: the member can't start; the leader's DUO takes both
wait(9)
as(me, "Party", "Invite", ava.UserId)
wait()
as(ava, "Party", "Accept", me.UserId)
wait()
drain(ava)
as(ava, "StartRun", "Solo")
wait()
check("member's start refused", st:GetAttribute("Phase") == "Lobby", lastNote(drain(ava)))
as(me, "StartRun", "Duo")
wait(1)
check("leader's DUO starts at once with the party", st:GetAttribute("Phase") == "Running" and RM.IsParticipant(me) and RM.IsParticipant(ava) and not RM.IsParticipant(ben),
	string.format("phase=%s me=%s ava=%s ben=%s", tostring(st:GetAttribute("Phase")), tostring(RM.IsParticipant(me)), tostring(RM.IsParticipant(ava)), tostring(RM.IsParticipant(ben))))
as(me, "AbandonRun")
as(ava, "AbandonRun")
wait(3)
check("back in the lobby", st:GetAttribute("Phase") == "Lobby", tostring(st:GetAttribute("Phase")))

-- 9. TRIO with a party of two: countdown with both joined; an outsider JOINs and fills it
as(me, "StartRun", "Trio")
wait()
check("TRIO countdown, party joined", st:GetAttribute("Phase") == "Countdown" and st:GetAttribute("Joined") == 2, string.format("phase=%s joined=%s", tostring(st:GetAttribute("Phase")), tostring(st:GetAttribute("Joined"))))
as(ben, "JoinRun")
wait(1)
check("outsider JOIN fills the TRIO", st:GetAttribute("Phase") == "Running" and RM.IsParticipant(ben) and RM.IsParticipant(ava))
for _, p in ipairs({ me, ava, ben }) do
	as(p, "AbandonRun")
end
wait(3)

-- 10. DUO with a party of three: one member is left out and told
wait(9)
as(me, "Party", "Invite", cal.UserId)
wait()
as(cal, "Party", "Accept", me.UserId)
wait()
drain(cal)
as(me, "StartRun", "Duo")
wait(1)
local calNote = lastNote(drain(cal))
check("DUO with party of 3: two in, one told", st:GetAttribute("Phase") == "Running" and RM.IsParticipant(ava) and not RM.IsParticipant(cal) and string.find(calNote, "no room") ~= nil, calNote)
as(me, "AbandonRun")
as(ava, "AbandonRun")
wait(3)

-- 11. a member leaves the game: cleanup; then the leader leaves: Ava leads
preview.removePlayer(cal)
wait()
check("Cal left the game: removed", party(me) == "PreviewPlayer*,Ava", party(me))
as(ben, "Party", "Invite", ava.UserId) -- an open invite to Ava from Ben
wait()
preview.removePlayer(ben)
wait()
local stateMsgs = drain(ava)
local lastState
for _, m in ipairs(stateMsgs) do
	if m[1] == "PartyState" then
		lastState = m[2]
	end
end
check("inviter left: Ava's invite list cleared", lastState ~= nil and #lastState.Invites == 0)

preview.log(fails == 0 and "ALL PASS" or (fails .. " FAIL"))
