-- party-quick-lines-regression: party quick lines (Config.Features.PartyQuickLines, PartyService
-- "Say", client PartyLines.lua, docs/next/PARTY_QUICK_LINES.md) against the real server.
--   1) party-only delivery: the sender and the sender's party members get PartySay, an outsider
--      and a player with no party get nothing; only the index travels (no text field)
--   2) validation: junk indexes (0, 7, 1.5, -1, NaN, inf, strings, tables, nil) deliver nothing
--   3) rate limit: 1 per Config.PartyQuickLines.MinGap s and PerMinute per 60 s, then free again
--   4) switch off: nothing is delivered; leaving the party ends it
--   5) client: the text comes from the config, the feed keeps FeedMax lines, a bubble holds
--      BubbleSeconds then fades and goes, the client's own gap lock matches the server
-- Prints PASS / FAIL lines; any FAIL fails the regression.
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

local Config = C.shared("Config")
local PS = preview.server("PartyService")
local Remotes = preview.shared("Remotes")
local PartyLines = preview.client("PartyLines")
local Q = Config.PartyQuickLines
-- no hero to talk over until section 5 (so earlier lines make no bubbles to count)
PartyLines._SetAnchorResolver(function()
	return nil
end)

local fails = 0
local function check(label: string, ok: boolean, detail: string?)
	if not ok then
		fails += 1
	end
	preview.log(string.format("%s  %s%s", ok and "PASS" or "FAIL", label, detail and ("  (" .. detail .. ")") or ""))
end

-- every PartySay / Notify the server sends, per player
local inbox: { [Player]: { any } } = {}
local origFire = Remotes.FireClient
Remotes.FireClient = function(name, p, ...)
	if name == "PartySay" or name == "Notify" then
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
local function said(p: Player, list: { any }): { any }
	local out = {}
	for _, m in ipairs(list) do
		if m[1] == "PartySay" then
			table.insert(out, m[2])
		end
	end
	return out
end
local function drainAll()
	for _, p in ipairs({ me, ava, ben, cal }) do
		drain(p)
	end
end
local function as(p: Player, remote: string, ...)
	if p == me then
		preview.remote(remote):FireServer(...)
	else
		preview.fireServerAs(p, remote, ...)
	end
end
local function wait(t: number?)
	preview.advance(t or 0.35)
end

check("PartyQuickLines switch on by default", Config.Features.PartyQuickLines == true)
check("six fixed lines in the spec order", #Q.Lines == 6 and Q.Lines[1] == "Ready?" and Q.Lines[2] == "Go!" and Q.Lines[3] == "GG" and Q.Lines[4] == "One more?" and Q.Lines[5] == "Wait for me" and Q.Lines[6] == "Thanks!")
check("limits are 1 per 2 s and 10 per minute", Q.MinGap == 2 and Q.PerMinute == 10)

-- a party of me (leader) + Ava; Ben and Cal stay outside
as(me, "Party", "Invite", ava.UserId)
wait()
as(ava, "Party", "Accept", me.UserId)
wait()
check("party formed", PS.PartyOf(me) ~= nil and PS.PartyOf(ava) == PS.PartyOf(me) and PS.PartyOf(ben) == nil)

-- 1) party-only delivery
drainAll()
as(ben, "Party", "Say", 1)
wait()
local nobody = #said(me, drain(me)) + #said(ava, drain(ava)) + #said(ben, drain(ben)) + #said(cal, drain(cal))
check("a player with no party delivers nothing", nobody == 0)
as(ava, "Party", "Say", 2)
wait()
local gotMe, gotAva, gotBen, gotCal = said(me, drain(me)), said(ava, drain(ava)), said(ben, drain(ben)), said(cal, drain(cal))
check("party member's line reaches the other member and the sender", #gotMe == 1 and #gotAva == 1)
check("outsiders get nothing", #gotBen == 0 and #gotCal == 0)
local first = gotMe[1] or {}
check("payload is FromId / FromName / Index only (no text)", first.Index == 2 and first.FromId == ava.UserId and first.FromName == "Ava" and first.Text == nil and first.Line == nil)
local keys = 0
for _ in pairs(first) do
	keys += 1
end
check("payload has exactly three fields", keys == 3, tostring(keys))
local avaFirstAt = os.clock()

-- 2) validation (each junk call is spaced past the remote's own rate limit)
drainAll()
for _, bad in ipairs({ 0, 7, 1.5, -1, 0 / 0, math.huge, "1", "Go!", { 1 }, true }) do
	as(me, "Party", "Say", bad)
	wait(0.3)
end
as(me, "Party", "Say")
wait(0.3)
check("junk indexes deliver nothing", #said(me, drain(me)) + #said(ava, drain(ava)) == 0)
check("CheckSay names the reason", PS.CheckSay(me, 0) == "index" and PS.CheckSay(me, 7) == "index" and PS.CheckSay(ben, 1) == "party" and PS.CheckSay(me, 3) == nil)

-- 3) rate limit: the gap
as(me, "Party", "Say", 1, "free text must never travel")
wait(0.3)
local one = said(ava, drain(ava))
check("a valid line goes (extra arguments are ignored)", #one == 1 and one[1].Index == 1 and one[1].Text == nil)
drain(me)
wait(0.4)
as(me, "Party", "Say", 3)
wait(0.3)
check("a second line inside the gap is refused", #said(ava, drain(ava)) == 0 and PS.CheckSay(me, 3) == "gap")
wait(1.6)
as(me, "Party", "Say", 3)
wait(0.3)
check("after the gap it goes", #said(ava, drain(ava)) == 1)

-- 3) rate limit: per minute (Ava already sent one at avaFirstAt)
drainAll()
local sent = 1
for _ = 1, 9 do
	wait(2.1)
	as(ava, "Party", "Say", 1 + (sent % 6))
	wait(0.2)
	sent += 1
end
check("ten lines in a minute all go", sent == 10 and #said(me, drain(me)) >= 9, tostring(sent))
wait(1.9)
as(ava, "Party", "Say", 4)
wait(0.3)
local after = drain(me)
check("the eleventh in the minute is refused", #said(me, after) == 0 and PS.CheckSay(ava, 4) == "minute")
local refusedNote = false
for _, m in ipairs(drain(ava)) do
	if m[1] == "Notify" and type(m[2]) == "table" and string.find(tostring(m[2].Text), "too many") then
		refusedNote = true
	end
end
check("the sender is told", refusedNote)
-- time passes: the window slides and she may talk again
wait(math.max(0, 61 - (os.clock() - avaFirstAt)))
as(ava, "Party", "Say", 6)
wait(0.3)
check("a minute later it goes again", #said(me, drain(me)) == 1)

-- 4) switch off
Config.Features.PartyQuickLines = false
wait(2.2)
drainAll()
as(me, "Party", "Say", 1)
wait(0.3)
check("switch off: nothing is delivered", #said(ava, drain(ava)) == 0 and PS.CheckSay(me, 1) == "feature")
Config.Features.PartyQuickLines = true
wait(2.2)

-- 5) client side
check("the client lock matches the gap", PartyLines.Say(4) == true and PartyLines.Locked() and PartyLines.Say(5) == false)
wait(0.4)
local lastLine = PartyLines.Feed()[#PartyLines.Feed()]
check("the client's line came back through the server", lastLine ~= nil and lastLine.Text == Q.Lines[4] and lastLine.FromId == me.UserId)
check("the shown text comes from the config, not the message", PartyLines.Receive({ Index = 5, FromId = ava.UserId, FromName = "Ava", Text = "evil" }) == Q.Lines[5])
check("junk messages are dropped", PartyLines.Receive({ Index = 99, FromId = 1 }) == nil and PartyLines.Receive({ Index = 1 }) == nil and PartyLines.Receive("x") == nil and PartyLines.Receive({ Index = 1.5, FromId = 1 }) == nil)
for i = 1, Q.FeedMax + 3 do
	PartyLines.Receive({ Index = 1 + (i % 6), FromId = ava.UserId, FromName = "Ava" })
end
check("the feed keeps FeedMax lines", #PartyLines.Feed() == Q.FeedMax, tostring(#PartyLines.Feed()))

-- the bubble over the sender's hero: holds, then fades, then goes
local hero = Instance.new("Part")
hero.Anchored = true
hero.Position = Vector3.new(0, 5, 0)
hero.Parent = workspace
PartyLines._SetAnchorResolver(function()
	return hero
end)
PartyLines.Receive({ Index = 3, FromId = ava.UserId, FromName = "Ava" })
check("a bubble appears", PartyLines.BubbleCount() == 1 and PartyLines.BubbleAlpha(ava.UserId) == 0)
wait(Q.BubbleSeconds - Q.FadeSeconds - 0.5)
check("it holds solid before the fade", (PartyLines.BubbleAlpha(ava.UserId) or 1) == 0)
wait(0.5 + Q.FadeSeconds / 2)
local mid = PartyLines.BubbleAlpha(ava.UserId)
check("it fades out", mid ~= nil and mid > 0 and mid < 1, tostring(mid))
wait(Q.FadeSeconds / 2 + 0.2)
check("then it is gone", PartyLines.BubbleCount() == 0 and PartyLines.BubbleAlpha(ava.UserId) == nil)
PartyLines.Receive({ Index = 1, FromId = ava.UserId, FromName = "Ava" })
PartyLines.Receive({ Index = 2, FromId = ava.UserId, FromName = "Ava" })
check("a newer line replaces the sender's bubble", PartyLines.BubbleCount() == 1)
PartyLines._SetAnchorResolver(nil)
hero:Destroy()

-- leaving the party ends it, on the server and in the client's feed
as(me, "Party", "Leave")
wait()
drainAll()
as(ava, "Party", "Say", 2)
wait(0.3)
check("after the party closes nobody hears a line", #said(me, drain(me)) == 0 and PS.CheckSay(ava, 2) == "party")
check("the client feed empties and the buttons stop", #PartyLines.Feed() == 0 and PartyLines.Available() == false and PartyLines.Say(1) == false)

preview.log(fails == 0 and "ALL PASS" or (fails .. " FAIL"))
