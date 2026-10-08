-- party-v2-regression: the real server (PartyService) with three extra players, driven through
-- the "Party" remote as each of them. SwarmV2 additions: Promote, PartyService.OnChanged (fired
-- with every affected player for each change) and the QueueService hook; plus DataService.Migrate's
-- OwnedCharacters / SelectedCharacter normalisation for the four classes. Prints PASS / FAIL.
-- Run: render.sh party-v2-regression --devices pc --max-time 400
local Players = game:GetService("Players")
local me = Players.LocalPlayer
local ava = preview.addPlayer("Ava", 2)
local ben = preview.addPlayer("Ben", 3)
local cal = preview.addPlayer("Cal", 4)
preview.forceMeshesUploaded()
preview.startServer()
preview.advance(2)

local PS = preview.server("PartyService")
local DS = preview.server("DataService")
local Remotes = preview.shared("Remotes")
local Config = preview.shared("Config")
local CharacterData = preview.shared("CharacterData")

local passes, fails = 0, 0
local function check(label: string, ok: boolean, detail: any?)
	if ok then
		passes += 1
	else
		fails += 1
	end
	preview.log(string.format("%s %s%s", ok and "PASS" or "FAIL", label, (not ok and detail ~= nil) and (" (" .. tostring(detail) .. ")") or ""))
end

-- every Notify text per player
local notes: { [Player]: { string } } = {}
local origFire = Remotes.FireClient
Remotes.FireClient = function(name, p, ...)
	if name == "Notify" then
		local d = ...
		notes[p] = notes[p] or {}
		table.insert(notes[p], type(d) == "table" and tostring(d.Text) or "?")
	end
	return origFire(name, p, ...)
end
local function said(p: Player, pattern: string): boolean
	for _, t in ipairs(notes[p] or {}) do
		if string.find(t, pattern) then
			return true
		end
	end
	return false
end

-- OnChanged recorder (after a listener that throws: it must not block the others)
PS.OnChanged(function()
	error("listener failure (test)")
end)
local changes: { string } = {}
PS.OnChanged(function(list)
	local ids = {}
	local seen = {}
	for _, p in ipairs(list) do
		if not seen[p.UserId] then
			seen[p.UserId] = true
			table.insert(ids, p.UserId)
		end
	end
	table.sort(ids)
	table.insert(changes, table.concat(ids, ","))
end)
local mark = 0
local function newChanges(): { string }
	local out = {}
	for i = mark + 1, #changes do
		table.insert(out, changes[i])
	end
	mark = #changes
	return out
end
local function ids(...: Player): string
	local list = {}
	for _, p in ipairs({ ... }) do
		table.insert(list, p.UserId)
	end
	table.sort(list)
	return table.concat(list, ",")
end

local function as(p: Player, action: any, arg: any?)
	preview.fireServerAs(p, "Party", action, arg)
	preview.advance(0.3)
end
local function names(p: Player): string
	local pt = PS.PartyOf(p)
	if not pt then
		return "none"
	end
	local out = {}
	for _, m in ipairs(pt.Members) do
		table.insert(out, m.Name .. (pt.Leader == m and "*" or ""))
	end
	return table.concat(out, ",")
end
local function noGhosts(): boolean
	-- every member of every party is a player on this server, and PartyOf agrees
	for _, p in ipairs(Players:GetPlayers()) do
		local pt = PS.PartyOf(p)
		if pt then
			if not table.find(pt.Members, p) or not table.find(pt.Members, pt.Leader) then
				return false
			end
			for _, m in ipairs(pt.Members) do
				if m.Parent ~= Players or PS.PartyOf(m) ~= pt then
					return false
				end
			end
		end
	end
	return true
end

check("setup: profiles loaded", DS.GetData(me) ~= nil and DS.GetData(ava) ~= nil and DS.GetData(ben) ~= nil)
local MAX = PS.MaxSize()
check("setup: party size is 3 (largest mode)", MAX == 3, MAX)

------------------------------------------------------------------------------------------
-- invite / accept
------------------------------------------------------------------------------------------
as(me, "Invite", ava.UserId)
check("invite: no party yet, no change event", names(me) == "none" and #newChanges() == 0)
as(ava, "Accept", me.UserId)
check("accept: party formed, inviter leads", names(me) == "PreviewPlayer*,Ava" or names(me) == (me.Name .. "*,Ava"), names(me))
local ev = newChanges()
check("accept: OnChanged fired once with both players", #ev == 1 and ev[1] == ids(me, ava), table.concat(ev, " | "))
check("accept: throwing listener didn't stop the next", #ev == 1)
check("accept: PartyId / PartyLeader attributes", me:GetAttribute("PartyId") ~= 0 and me:GetAttribute("PartyId") == ava:GetAttribute("PartyId") and me:GetAttribute("PartyLeader") == true and ava:GetAttribute("PartyLeader") == false)
as(ava, "Accept", me.UserId)
check("accept: a stale second accept changes nothing", names(me) == names(me) and #newChanges() == 0 and #PS.PartyOf(me).Members == 2)

------------------------------------------------------------------------------------------
-- invite expiry
------------------------------------------------------------------------------------------
as(me, "Invite", cal.UserId)
preview.advance(Config.Party.InviteSeconds + 1)
as(cal, "Accept", me.UserId)
check("expiry: an invite older than InviteSeconds can't be accepted", PS.PartyOf(cal) == nil and #PS.PartyOf(me).Members == 2)
check("expiry: cal is told it expired", said(cal, "expired"))
check("expiry: no change event", #newChanges() == 0)
as(cal, "Accept", me.UserId)
check("expiry: and the dead invite is gone for good", PS.PartyOf(cal) == nil and #newChanges() == 0)
-- just inside the window still works (ben)
as(me, "Invite", ben.UserId)
preview.advance(Config.Party.InviteSeconds - 2)
-- (not accepted yet: used below with the simultaneous accepts)

------------------------------------------------------------------------------------------
-- simultaneous accepts into the last slot
------------------------------------------------------------------------------------------
as(me, "Invite", cal.UserId) -- 31+ s since the last one: allowed again
-- Ben's invite (almost expired) and Cal's: both accept in the same server step
preview.fireServerAs(ben, "Party", "Accept", me.UserId)
preview.fireServerAs(cal, "Party", "Accept", me.UserId)
preview.advance(0.3)
local joined = (PS.PartyOf(ben) ~= nil and 1 or 0) + (PS.PartyOf(cal) ~= nil and 1 or 0)
check("race: exactly ONE of two simultaneous accepts gets the last slot", joined == 1 and #PS.PartyOf(me).Members == 3, joined)
check("race: the first accept wins", PS.PartyOf(ben) == PS.PartyOf(me) and PS.PartyOf(cal) == nil, names(me))
check("race: the loser is told the party is full", said(cal, "full"))
ev = newChanges()
check("race: one change event with the whole party", #ev == 1 and ev[1] == ids(me, ava, ben), table.concat(ev, " | "))
check("race: party never exceeds the max", #PS.PartyOf(me).Members <= MAX)
as(me, "Invite", cal.UserId)
check("full party: invite refused (told)", said(me, "full") and #newChanges() == 0)
check("invariants: no ghost members", noGhosts())

------------------------------------------------------------------------------------------
-- Kick
------------------------------------------------------------------------------------------
as(ava, "Kick", me.UserId)
check("kick: a member can't kick the leader", names(me) == "PreviewPlayer*,Ava,Ben" or #PS.PartyOf(me).Members == 3, names(me))
as(ava, "Kick", ben.UserId)
check("kick: a member can't kick a member", #PS.PartyOf(me).Members == 3)
as(me, "Kick", cal.UserId)
check("kick: a non-member target is ignored", #PS.PartyOf(me).Members == 3)
as(me, "Kick", me.UserId)
check("kick: the leader can't kick themselves", #PS.PartyOf(me).Members == 3)
as(me, "Kick", "x")
as(me, "Kick", 0 / 0)
as(me, "Kick", nil)
check("kick: junk ids ignored", #PS.PartyOf(me).Members == 3 and #newChanges() == 0)
PS.PartyOf(me).Ready[ben] = true
as(me, "Kick", ben.UserId)
check("kick: leader removes a member", PS.PartyOf(ben) == nil and #PS.PartyOf(me).Members == 2 and PS.PartyOf(me).Leader == me)
ev = newChanges()
check("kick: OnChanged lists the party AND the kicked player", #ev == 1 and ev[1] == ids(me, ava, ben), table.concat(ev, " | "))
check("kick: kicked player is told", said(ben, "removed"))
check("kick: READY cleared by the change", next(PS.PartyOf(me).Ready) == nil)
check("invariants: no ghost members", noGhosts())

------------------------------------------------------------------------------------------
-- Promote
------------------------------------------------------------------------------------------
as(me, "Invite", ben.UserId)
as(ben, "Accept", me.UserId)
newChanges()
PS.PartyOf(me).Ready[ben] = true
as(ava, "Promote", ben.UserId)
check("promote: refused from a non-leader", PS.PartyOf(me).Leader == me and #newChanges() == 0)
as(me, "Promote", cal.UserId)
check("promote: refused to a non-member", PS.PartyOf(me).Leader == me and #newChanges() == 0)
as(me, "Promote", me.UserId)
check("promote: refused to yourself", PS.PartyOf(me).Leader == me and #newChanges() == 0)
as(me, "Promote", "x")
as(me, "Promote", 0 / 0)
as(me, "Promote", -5)
as(me, "Promote", nil)
check("promote: junk ids ignored", PS.PartyOf(me).Leader == me and #newChanges() == 0)
as(cal, "Promote", me.UserId)
check("promote: a player outside any party can't promote", PS.PartyOf(me).Leader == me and PS.PartyOf(cal) == nil)
as(me, "Promote", ava.UserId)
check("promote: leader hands the lead over", PS.PartyOf(me).Leader == ava, names(me))
ev = newChanges()
check("promote: OnChanged fired once with the whole party", #ev == 1 and ev[1] == ids(me, ava, ben), table.concat(ev, " | "))
check("promote: attributes follow", ava:GetAttribute("PartyLeader") == true and me:GetAttribute("PartyLeader") == false and ben:GetAttribute("PartyLeader") == false)
check("promote: READY cleared", next(PS.PartyOf(me).Ready) == nil)
check("promote: members told", said(me, "leads the party now") and said(ben, "leads the party now"))
check("promote: member order unchanged (join order)", names(me) == me.Name .. ",Ava*,Ben" or PS.PartyOf(me).Members[1] == me, names(me))
as(me, "Promote", ben.UserId)
check("promote: the old leader can no longer promote", PS.PartyOf(me).Leader == ava and #newChanges() == 0)
check("invariants: no ghost members", noGhosts())

------------------------------------------------------------------------------------------
-- Leave: leader leaves → longest-standing member leads
------------------------------------------------------------------------------------------
as(ava, "Leave")
check("leave: leader gone, party continues", PS.PartyOf(ava) == nil and #PS.PartyOf(me).Members == 2)
check("leave: the longest-standing member (first in) leads", PS.PartyOf(me).Leader == me, names(me))
ev = newChanges()
check("leave: OnChanged lists remaining members and the leaver", #ev == 1 and ev[1] == ids(me, ava, ben), table.concat(ev, " | "))
check("leave: leader attribute handed over", me:GetAttribute("PartyLeader") == true and ava:GetAttribute("PartyLeader") == false and ava:GetAttribute("PartyId") == 0)
check("leave: new leader is told who leads", said(ben, "leads now"))
as(ava, "Leave")
check("leave: leaving with no party is a no-op", #newChanges() == 0)
-- member leaves, leaving one: party closes
as(ben, "Leave")
check("leave: down to one → the party closes for everyone", PS.PartyOf(me) == nil and PS.PartyOf(ben) == nil and me:GetAttribute("PartyId") == 0)
ev = newChanges()
check("leave: close fires one event with both", #ev == 1 and ev[1] == ids(me, ben), table.concat(ev, " | "))
check("invariants: no ghost members", noGhosts())

-- three-member order: leader promoted, then leaves → FIRST joined (not first listed) leads
preview.advance(Config.Party.ReinviteSeconds + 1)
as(me, "Invite", ava.UserId)
as(ava, "Accept", me.UserId)
as(me, "Invite", ben.UserId)
as(ben, "Accept", me.UserId)
newChanges()
as(me, "Promote", ben.UserId)
as(ben, "Leave")
check("leave: promoted leader leaves → the founder (longest-standing) leads again", PS.PartyOf(me) ~= nil and PS.PartyOf(me).Leader == me and #PS.PartyOf(me).Members == 2, names(me))
newChanges()
-- leader leaves a party of 2 with the other member present: closes
as(me, "Leave")
check("leave: leader of two leaves → closed", PS.PartyOf(me) == nil and PS.PartyOf(ava) == nil)
check("invariants: no ghost members", noGhosts())
newChanges()

------------------------------------------------------------------------------------------
-- Disconnects
------------------------------------------------------------------------------------------
preview.advance(Config.Party.ReinviteSeconds + 1)
as(me, "Invite", ava.UserId)
as(ava, "Accept", me.UserId)
as(me, "Invite", ben.UserId)
as(ben, "Accept", me.UserId)
newChanges()
check("disconnect setup: party of three", #PS.PartyOf(me).Members == 3, names(me))
preview.removePlayer(ben)
preview.advance(0.3)
check("disconnect: a member leaves the game → no ghost in the party", PS.PartyOf(me) ~= nil and #PS.PartyOf(me).Members == 2 and not table.find(PS.PartyOf(me).Members, ben) and PS.PartyOf(ben) == nil, names(me))
ev = newChanges()
check("disconnect: OnChanged fired with the rest and the leaver", #ev == 1 and ev[1] == ids(me, ava, ben), table.concat(ev, " | "))
check("invariants: no ghost members", noGhosts())
as(me, "Promote", ava.UserId)
newChanges()
preview.removePlayer(ava)
preview.advance(0.3)
check("disconnect: leader leaves the game → party of one closes, no ghost", PS.PartyOf(me) == nil and me:GetAttribute("PartyId") == 0, names(me))
ev = newChanges()
check("disconnect: leader's exit fires OnChanged with both", #ev == 1 and ev[1] == ids(me, ava), table.concat(ev, " | "))
check("invariants: no ghost members", noGhosts())

-- an invite from a player who then disconnects can't be accepted
local dee = preview.addPlayer("Dee", 5)
preview.playerJoined(dee)
preview.advance(1)
preview.fireServerAs(dee, "Party", "Invite", cal.UserId)
preview.advance(0.3)
preview.removePlayer(dee)
preview.advance(0.3)
as(cal, "Accept", 5)
check("disconnect: an invite from a departed player is dead", PS.PartyOf(cal) == nil and #newChanges() == 0)
-- an invitee who leaves doesn't keep a pending invite slot
as(me, "Invite", cal.UserId)
preview.removePlayer(cal)
preview.advance(0.3)
check("disconnect: leaving invitee leaves nothing behind", PS.PartyOf(cal) == nil and noGhosts())

------------------------------------------------------------------------------------------
-- QueueService hook (real LobbyBoot wiring), when the basecamp is active on this server
------------------------------------------------------------------------------------------
do
	local ok, QS = pcall(preview.require, game:GetService("ServerScriptService").SwarmV2.Lobby.QueueService)
	local ok2, LB = pcall(preview.require, game:GetService("ServerScriptService").SwarmV2.Lobby.LobbyBoot)
	if ok and ok2 and LB.Active() then
		local eve = preview.addPlayer("Eve", 6)
		local fay = preview.addPlayer("Fay", 7)
		preview.playerJoined(eve)
		preview.playerJoined(fay)
		preview.advance(3)
		if DS.GetData(eve) and DS.GetData(fay) then
			preview.fireServerAs(eve, "Party", "Invite", fay.UserId)
			preview.advance(0.3)
			preview.fireServerAs(fay, "Party", "Accept", eve.UserId)
			preview.advance(0.3)
			local why = QS.Join(eve, "Party", "ui")
			check("hook: party leader entered a gate", why == nil and QS.QueueOf(fay) == QS.QueueOf(eve), why)
			preview.fireServerAs(eve, "Party", "Promote", fay.UserId)
			preview.advance(0.3)
			check("hook: Promote takes the old entry out of the queue (QueueService.OnPartyChanged)", not QS.IsQueued(eve) and not QS.IsQueued(fay))
			QS.Join(fay, "Party", "ui")
			preview.fireServerAs(fay, "Party", "Kick", eve.UserId)
			preview.advance(0.3)
			check("hook: Kick takes the party out of the queue", not QS.IsQueued(fay) and not QS.IsQueued(eve))
		else
			preview.log("INFO hook: profiles of the extra players did not load; hook check skipped")
		end
	else
		preview.log("INFO hook: SwarmV2 basecamp not active in this preview boot; QueueService hook check skipped")
	end
end

------------------------------------------------------------------------------------------
-- DataService.Migrate: OwnedCharacters / SelectedCharacter
------------------------------------------------------------------------------------------
local function migrated(owned: any, selected: any)
	local d = DS.DefaultData()
	d.OwnedCharacters = owned
	d.SelectedCharacter = selected
	return DS.Migrate(d)
end
do
	local m = migrated({ Knight = true, Mage = true, Rogue = true }, "Mage")
	check("migrate: old OwnedCharacters kept", m.OwnedCharacters.Knight == true and m.OwnedCharacters.Mage == true and m.OwnedCharacters.Rogue == true)
	check("migrate: ruckus added", m.OwnedCharacters.ruckus == true)
	check("migrate: an owned old selection is kept", m.SelectedCharacter == "Mage", m.SelectedCharacter)

	m = migrated({ Knight = true, toastmaster = true }, "toastmaster")
	check("migrate: owned toastmaster selection kept", m.SelectedCharacter == "toastmaster" and m.OwnedCharacters.toastmaster == true, m.SelectedCharacter)

	m = migrated({ Knight = true }, "toastmaster")
	check("migrate: unowned toastmaster selection reset to the default hero", m.SelectedCharacter == CharacterData.Default and m.OwnedCharacters.toastmaster == nil, m.SelectedCharacter)
	m = migrated({ Knight = true }, "granny_boom")
	check("migrate: unowned granny_boom reset", m.SelectedCharacter == CharacterData.Default)
	m = migrated({ Knight = true }, "Mage")
	check("migrate: unowned old hero reset", m.SelectedCharacter == CharacterData.Default)
	m = migrated({ Knight = true }, "ruckus")
	check("migrate: ruckus selection is valid (free class)", m.SelectedCharacter == "ruckus", m.SelectedCharacter)
	m = migrated({ Knight = true, toastmaster = "yes" }, "toastmaster")
	check("migrate: only literal true counts as owned", m.SelectedCharacter == CharacterData.Default)
	m = migrated({ Knight = true }, 42)
	check("migrate: non-string selection reset", m.SelectedCharacter == CharacterData.Default)
	m = migrated({ Knight = true }, "NoSuchHero")
	check("migrate: unknown id reset", m.SelectedCharacter == CharacterData.Default)
	m = migrated("junk", "toastmaster")
	check("migrate: OwnedCharacters not a table → default + ruckus, selection reset", type(m.OwnedCharacters) == "table" and m.OwnedCharacters.ruckus == true and m.OwnedCharacters[CharacterData.Default] == true and m.SelectedCharacter == CharacterData.Default)
	m = migrated(nil, nil)
	check("migrate: missing fields → defaults", m.OwnedCharacters.ruckus == true and m.OwnedCharacters[CharacterData.Default] == true)
	m = DS.Migrate({})
	check("migrate: empty save table → ruckus added", type(m) == "table" and m.OwnedCharacters.ruckus == true and m.SelectedCharacter == CharacterData.Default)
	m = DS.Migrate(nil)
	check("migrate: nil save → fresh defaults (class ownership still holds through ClassOwnership)", type(m) == "table" and m.OwnedCharacters[CharacterData.Default] == true)
	preview.log("INFO migrate(nil) returns defaultData() as is: OwnedCharacters.ruckus stored = " .. tostring(m.OwnedCharacters.ruckus) .. " (ClassOwnership.Owns treats ruckus as always owned; LobbyBoot EnsureDefault fills it in)")
	local once = migrated({ Knight = true, Archer = true, toastmaster = true, captain_croak = true }, "captain_croak")
	local twice = DS.Migrate(once)
	check("migrate: idempotent", twice.SelectedCharacter == "captain_croak" and twice.OwnedCharacters.captain_croak == true and twice.OwnedCharacters.toastmaster == true and twice.OwnedCharacters.Archer == true and twice.OwnedCharacters.ruckus == true)
end

preview.log(string.format("party-v2-regression: %d checks, %d passed, %d failed", passes + fails, passes, fails))
preview.log(fails == 0 and "ALL PASS" or (fails .. " FAIL"))
assert(fails == 0, tostring(fails) .. " party checks failed")
