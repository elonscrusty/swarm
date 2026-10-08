-- basecamp-ui: the walk-around basecamp's client UI (SwarmV2Client.Lobby) from LobbyState payloads.
-- The server is faked: LobbyNet.Setup makes the folder, Basecamp = true switches the client UI on,
-- LobbyState / LobbyNotice are fired through the real RemoteEvents.
--   --set view=idle         class chip, party strip, menu bar, PLAY (default)
--   --set view=classes      the class sheet (a locked class needs gold: gold=low)
--   --set view=gates        the gate sheet (PLAY tapped)
--   --set view=queue        waiting in a Public gate with a teammate (you are not READY)
--   --set view=ready        same, you are READY
--   --set view=countdown    countdown running (7 s left)
--   --set view=teleporting  committed / teleporting (READY and LEAVE hidden)
--   --set view=failed       the queue failed, with a message
--   --set view=party        Party gate, 3 members, longer names
--   --set view=toasts       idle + three notices
--   --set view=screen       the old PARTY screen opened over the camp (menu bar PARTY)
--   --set view=locked       class locked (committed): the class sheet disabled
--   --set gold=low|rich     gold below / above the 10,000 class price (default low)
--   --set party=on          a party of 2 (strip shows it)
local C = lib("common")
local Players = game:GetService("Players")
local RS = game:GetService("ReplicatedStorage")
C.lobby()
local LobbyNet = preview.require(RS.SwarmV2.Lobby.LobbyNet)
local LobbyConfig = preview.require(RS.SwarmV2.Lobby.LobbyConfig)
local ids = {}
for _, g in ipairs(LobbyConfig.Gates) do
	table.insert(ids, g.Id)
end
LobbyNet.Setup(ids)
local me = Players.LocalPlayer
local view = preview.args.view or "idle"
local boards = {
	PublicA = { Count = 2, State = "Open" },
	Party = { Count = 0, State = "Open" },
	PublicB = { Count = 4, State = "Full" },
}
for id, b in pairs(boards) do
	local cfg = LobbyNet.Gate(id)
	cfg:SetAttribute("Count", b.Count)
	cfg:SetAttribute("Capacity", 4)
	cfg:SetAttribute("State", b.State)
	cfg:SetAttribute("EndsAt", 0)
end
LobbyNet.Folder():SetAttribute("Basecamp", true)

C.startClient()
C.sendProfile()
C.settle(1)
-- the client waits for the attribute in a polling task
C.settle(1)

local function send(state)
	LobbyNet.Get("LobbyState"):FireClient(me, state)
	C.settle(0.6)
end
local function press(pred)
	local g = preview.findGui(pred)[1]
	if g then
		preview.click(g)
	else
		preview.warn("button not found")
	end
	C.settle(0.8)
end

local rich = preview.args.gold == "rich"
local base = {
	Role = "local",
	Gold = rich and 25000 or 4200,
	Owned = { ruckus = true },
	Selected = "ruckus",
	ClassLocked = false,
	PartySize = preview.args.party == "on" and 2 or 1,
	IsLeader = true,
}
local function members(n, longNames, readyAll)
	local names = longNames and { me.DisplayName, "MaximilianTheVeryLongName", "Cal" } or { me.DisplayName, "Ava", "Cal", "Dee" }
	local classes = { "ruckus", "toastmaster", "captain_croak", "granny_boom" }
	local out = {}
	for i = 1, n do
		table.insert(out, {
			UserId = i == 1 and me.UserId or (100 + i),
			Name = names[i],
			ClassId = classes[i],
			Ready = (readyAll == true) or (i == 2 and view ~= "queue"),
			Leader = i == 1,
		})
	end
	return out
end
local function queue(mode, gate, state, n, extra)
	local q = {
		GateId = gate,
		Mode = mode,
		State = state,
		Capacity = 4,
		Members = members(n, gate == "Party"),
		EndsAt = 0,
		Message = nil,
	}
	for k, v in pairs(extra or {}) do
		q[k] = v
	end
	return q
end

local function with(q, over)
	local s = table.clone(base)
	s.Queue = q
	for k, v in pairs(over or {}) do
		s[k] = v
	end
	return s
end

if view == "idle" or view == "toasts" or view == "screen" then
	send(base)
elseif view == "classes" then
	send(base)
	press(function(o)
		return o.Name == "Hit" and o.Parent and o.Parent.Name == "ClassChip"
	end)
elseif view == "locked" then
	send(with(nil, { ClassLocked = true }))
	press(function(o)
		return o.Name == "Hit" and o.Parent and o.Parent.Name == "ClassChip"
	end)
elseif view == "gates" then
	send(base)
	press(function(o)
		return o.Name == "PlayButton"
	end)
elseif view == "queue" then
	send(with(queue("Public", "PublicA", "Waiting", 2)))
elseif view == "ready" then
	local q = queue("Public", "PublicA", "Waiting", 3, nil)
	q.Members[1].Ready = true
	send(with(q))
elseif view == "countdown" then
	local q = queue("Public", "PublicA", "Countdown", 4, { EndsAt = workspace:GetServerTimeNow() + 7 })
	for _, m in ipairs(q.Members) do
		m.Ready = true
	end
	send(with(q))
elseif view == "teleporting" then
	local q = queue("Public", "PublicA", "Teleporting", 4)
	for _, m in ipairs(q.Members) do
		m.Ready = true
	end
	send(with(q, { ClassLocked = true }))
elseif view == "failed" then
	send(with(queue("Public", "PublicA", "Failed", 2, { Message = "Could not reach the match server. Try again." })))
elseif view == "party" then
	send(with(queue("Party", "Party", "Waiting", 3), { PartySize = 3 }))
end

if view == "toasts" then
	LobbyNet.Get("LobbyNotice"):FireClient(me, "Class bought: Toastmaster", "good")
	LobbyNet.Get("LobbyNotice"):FireClient(me, "Not enough gold for that class", "warn")
	LobbyNet.Get("LobbyNotice"):FireClient(me, "Could not join: that gate is full", "bad")
	C.settle(0.8)
elseif view == "screen" then
	press(function(o)
		return o.Name == "PartyButton"
	end)
	C.settle(1)
end

local fired = {}
for _, e in ipairs({}) do
	table.insert(fired, e)
end
preview.log("basecamp-ui view=" .. view)
