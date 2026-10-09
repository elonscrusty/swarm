-- class-browser-ui: stream L1 (docs/redesign/lobby/L1_STATUS.md). The basecamp home screen's class browser,
-- loading statuses, first-time guide and entry points on the real client (SwarmV2Client.Lobby), from
-- LobbyState / ProfileSync payloads. The server is faked like basecamp-ui: LobbyNet.Setup makes the folder,
-- Basecamp = true switches the UI on, LobbyState is fired through the real RemoteEvent. Every action the
-- client sends (ClassAction, QueueAction, LobbySync, RequestProfile) is recorded and checked.
--   --set view=home        the six entry points (default)
--   --set view=grid        the class browser, page 1 (desktop: grid + details; phone: grid)
--   --set view=details     a locked class opened (phones: the dedicated details view)
--   --set view=owned       the Owned filter
--   --set view=page2       page 2 of the grid
--   --set view=pending     SELECT pressed, no answer yet
--   --set view=refused     SELECT answered NOT_OWNED by the server: previous class kept, reason shown
--   --set view=queued      in a queue: class locked, LEAVE QUEUE offered
--   --set view=confirm     the gold purchase confirmation
--   --set view=loading     nothing answered yet (--set age=0|9|31 seconds)
--   --set view=guide       the first-time guide (--set step=1..5, --set device=Keyboard|Touch|Gamepad)
--   --set view=unavailable no class model built: loading, then unavailable portraits
--   --set longnames=on     very long class names
--   --set gold=low|rich    4,200 gold or 25,000 gold
--   --set owned=few|many   owned classes
local C = lib("common")
local Players = game:GetService("Players")
local RS = game:GetService("ReplicatedStorage")
local view = preview.args.view or "home"

local passes, fails = 0, 0
local function check(label: string, ok: boolean, detail: any?)
	if ok then
		passes += 1
	else
		fails += 1
	end
	local why = detail ~= nil and tostring(detail) or ""
	if #why > 240 then
		why = string.sub(why, 1, 240) .. "..."
	end
	preview.log(string.format("%s %s%s", ok and "PASS" or "FAIL", label, (not ok and why ~= "") and (" (" .. why .. ")") or ""))
end

local s = C.bootServer()
local CharacterData = C.shared("CharacterData")
local Roster = preview.require(RS.SwarmV2.Run.ClassRoster)
Roster.Register(CharacterData, C.shared("MetaUpgradeData"))
local ClassCatalog = preview.require(RS.SwarmV2.ClassCatalog)
if preview.args.longnames == "on" then
	-- the catalog and the roster both carry the display name
	local long = {
		doug_janitor = "Doug the Exhausted Janitor of the Eastern Cliffwood Basin",
		knuckles_mcgee = "Knuckles McGee the Undefeated Champion of Everywhere",
		captain_croak = "Captain Croak of the Long Expedition",
	}
	for id, name in pairs(long) do
		ClassCatalog.Get(id).Name = name
		Roster.Defs[id].Name = name
	end
end
if view ~= "unavailable" then
	C.buildPreviews(s.ModelBuilder)
end
C.setState({ Phase = "Lobby", SelectedArena = "Forest", Mode = "Solo", BossHP = 0, BossMaxHP = 0, Participants = 0, RunTime = 0 })
C.setPlayer({ InRun = false, Gold = 4200 })

local LobbyNet = preview.require(RS.SwarmV2.Lobby.LobbyNet)
local LobbyConfig = preview.require(RS.SwarmV2.Lobby.LobbyConfig)
local ids = {}
for _, g in ipairs(LobbyConfig.Gates) do
	table.insert(ids, g.Id)
end
LobbyNet.Setup(ids)
local me = Players.LocalPlayer
for id, b in pairs({ PublicA = { 2, "Open" }, Party = { 0, "Open" }, PublicB = { 4, "Full" } }) do
	local cfg = LobbyNet.Gate(id)
	cfg:SetAttribute("Count", b[1])
	cfg:SetAttribute("Capacity", 4)
	cfg:SetAttribute("State", b[2])
	cfg:SetAttribute("EndsAt", 0)
end
LobbyNet.Folder():SetAttribute("Basecamp", true)

-- record what the client asks the server
local sent: { { string } } = {}
local function record(name: string)
	local ev = LobbyNet.Get(name)
	ev.OnServerEvent:Connect(function(_p, ...)
		local parts = { name }
		for _, v in ipairs({ ... }) do
			table.insert(parts, tostring(v))
		end
		table.insert(sent, parts)
	end)
end
for _, n in ipairs({ "ClassAction", "QueueAction", "LobbySync" }) do
	record(n)
end
local Remotes = C.shared("Remotes")
local profileAsks = 0
Remotes.Get("RequestProfile").OnServerEvent:Connect(function()
	profileAsks += 1
end)
local function sentCount(name: string, a: string?, b: string?): number
	local n = 0
	for _, e in ipairs(sent) do
		if e[1] == name and (a == nil or e[2] == a) and (b == nil or e[3] == b) then
			n += 1
		end
	end
	return n
end

C.startClient()
C.settle(1)
C.settle(1)

local function profile(over)
	local p = C.profile({ Settings = { Music = 0.6, Sfx = 0.8 }, TutorialDone = false, TutorialStep = 0 })
	p.Stats = { BestTime = 754, TotalKills = 4821, Wins = 1, Runs = 0 }
	for k, v in pairs(over or {}) do
		if k == "Stats" then
			for sk, sv in pairs(v) do
				p.Stats[sk] = sv
			end
		else
			p[k] = v
		end
	end
	return p
end
local rich = preview.args.gold == "rich"
local many = preview.args.owned == "many"
local owned = { ruckus = true }
if many then
	owned = { ruckus = true, toastmaster = true, captain_croak = true, coach_crunch = true, peter_parkour = true }
elseif preview.args.owned == "few" then
	owned = { ruckus = true, toastmaster = true }
end
local progress = {
	toastmaster = { Have = 120, Need = 300, Stat = "XP" },
	captain_croak = { Have = 900, Need = 3000, Stat = "Distance" },
	granny_boom = { Have = 1, Need = 3, Stat = "Elites" },
	coach_crunch = { Have = 90, Need = 180, Stat = "BestSurvive" },
	doug_janitor = { Have = 2, Need = 5, Stat = "Chests" },
	peter_parkour = { Have = 12, Need = 30, Stat = "Dashes" },
	barry_plotter = { Have = 1, Need = 3, Stat = "MostWeapons" },
	rambozo = { Have = 140, Need = 300, Stat = "Kills" },
	swolverine = { Have = 31, Need = 100, Stat = "CloseKills" },
	crash_cassidy = { Have = 4100, Need = 10000, Stat = "Distance" },
	knuckles_mcgee = { Have = 0, Need = 1, Stat = "Bosses", Parts = { { Stat = "Bosses", Have = 0, Need = 1 }, { Stat = "Revives", Have = 0, Need = 1 } } },
}
for id in pairs(owned) do
	progress[id] = nil
end
local selected = many and "toastmaster" or "ruckus"
local base = {
	Role = "local",
	Gold = rich and 25000 or 4200,
	Owned = owned,
	Selected = selected,
	ClassLocked = false,
	PartySize = 1,
	IsLeader = true,
	Progress = progress,
}
local function members(n)
	local out = {}
	local names = { me.DisplayName, "Ava", "Cal", "Dee" }
	for i = 1, n do
		table.insert(out, { UserId = i == 1 and me.UserId or (100 + i), Name = names[i], ClassId = "ruckus", Ready = false, Leader = i == 1 })
	end
	return out
end
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
	C.settle(0.6)
	return g ~= nil
end
local function btn(name: string)
	return function(o)
		return o.Name == name
	end
end
local function texts(root: any?): string
	local out = {}
	for _, g in ipairs(preview.findGui(function(o)
		return (o.ClassName == "TextLabel" or o.ClassName == "TextButton") and o.Text ~= "" and o.Visible
	end)) do
		table.insert(out, g.Text)
	end
	return table.concat(out, " | ")
end
local function visible(name: string): boolean
	local g = preview.findGui(btn(name))[1]
	if not g then
		return false
	end
	local o: any = g
	while o do
		if o:IsA("GuiObject") and not o.Visible then
			return false
		end
		o = o.Parent
	end
	return true
end
local function openBrowser()
	press(function(o)
		return o.Name == "Hit" and o.Parent and o.Parent.Name == "ClassChip"
	end)
end
local function tapCard(id: string)
	return press(btn("Card_" .. id))
end

if view == "loading" then
	-- nothing answered: the load card, then the 8 s explanation and the 30 s retry
	local age = tonumber(preview.args.age) or 0
	check("loading: the load card shows from the start and the class chip does not guess", visible("LoadCard") and string.find(texts(), "Loading class") ~= nil, texts())
	check("loading: no guide, no purchase while nothing is loaded", not visible("Guide"))
	if age > 0 then
		preview.advance(age, 10)
		C.settle(0.3)
	end
	local t = texts()
	if age >= 31 then
		check("loading 31 s: a plain failure message and RETRY, progress called safe", string.find(t, "untouched") ~= nil and visible("Retry"), t)
		press(btn("Retry"))
		check("loading: RETRY asks again (RequestProfile + LobbySync), once", profileAsks == 1 and sentCount("LobbySync") >= 2, tostring(profileAsks) .. "/" .. tostring(sentCount("LobbySync")))
	elseif age >= 9 then
		check("loading 9 s: says what is still loading and that nothing is lost", string.find(t, "Still loading") ~= nil and string.find(t, "Nothing is lost") ~= nil and not visible("Retry"), t)
	else
		check("loading 0 s: plain 'Loading' line, no retry yet", string.find(t, "Loading your profile") ~= nil and not visible("Retry"), t)
	end
	if age < 31 then
		-- the data arrives: the card goes away and the real class shows
		C.sendProfile(profile())
		send(base)
		check("loading: the card is gone once profile and classes arrived", not visible("LoadCard"))
	end
elseif view == "unavailable" then
	C.sendProfile(profile())
	send(base)
	openBrowser()
	check("unavailable: portraits say PREVIEW LOADING at first", string.find(texts(), "PREVIEW LOADING") ~= nil, texts())
	preview.advance(13, 10)
	C.settle(0.8)
	check("unavailable: later PREVIEW UNAVAILABLE (an explicit state, not a finished picture)", string.find(texts(), "PREVIEW UNAVAILABLE") ~= nil, texts())
else
	-- a new account (no runs) gets the guide by itself; every other view starts from a returning player
	local newPlayer = view == "home" or view == "guide"
	C.sendProfile(newPlayer and profile() or profile({ Stats = { Runs = 3 } }))
	send(base)
	if view == "home" then
		for _, name in ipairs({ "ClassChip", "PartyButton", "PlayButton", "SHOP", "CODEX", "SETTINGS", "MORE", "HelpButton" }) do
			check("home: entry point " .. name .. " is on screen", visible(name))
		end
		check("home: first-time guide opened by itself for an account with no runs (and is dismissible)", visible("Guide") and visible("Skip"))
		press(btn("Skip"))
		check("home: SKIP closes the guide and saves LobbyGuideSeen", not visible("Guide"))
		check("home: HOW TO PLAY reopens it", press(btn("HelpButton")) and visible("Guide"))
	end
	if view == "grid" or view == "owned" or view == "page2" or view == "details" or view == "pending" or view == "refused" or view == "queued" or view == "confirm" then
		if view == "queued" then
			send(base)
			send(table.clone(base))
		end
		if view == "queued" then
			local v = table.clone(base)
			v.Queue = { GateId = "PublicA", Mode = "Public", State = "Waiting", Capacity = 4, Members = members(2), EndsAt = 0 }
			send(v)
		end
		openBrowser()
		if view == "owned" then
			press(btn("Tab_Owned"))
		elseif view == "page2" then
			press(btn("Next"))
		elseif view == "details" then
			tapCard("granny_boom")
		elseif view == "pending" or view == "refused" then
			tapCard("toastmaster")
			if many then
				-- already owned
			end
		elseif view == "queued" then
			tapCard(many and "peter_parkour" or "toastmaster")
		elseif view == "confirm" then
			tapCard("captain_croak")
			press(btn("Main"))
		end
	end
	if view == "pending" then
		press(btn("Main"))
		check("pending: SELECT sent exactly one ClassAction Select toastmaster", sentCount("ClassAction", "Select", "toastmaster") == 1)
		local t = texts()
		check("pending: the previous class stays SELECTED on the card until the server answers", string.find(t, "SELECTING") ~= nil and string.find(t, "Ruckus") ~= nil)
		check("pending: a second press cannot send twice", (function()
			press(btn("Main"))
			return sentCount("ClassAction", "Select", "toastmaster") == 1
		end)())
		preview.advance(7, 10)
		C.settle(0.5)
		check("pending: a silent server drops the choice after a few seconds, says so and keeps the old class", string.find(texts(), "did not confirm") ~= nil and string.find(texts(), "Still using Ruckus") ~= nil, string.sub(texts(), -300))
		-- the real answer arriving later with the class changed: shown as selected, no stale pending
		local v = table.clone(base)
		v.Selected = "toastmaster"
		v.ClassAck = { N = 1, Id = "toastmaster", Action = "Select", Ok = true }
		send(v)
		check("pending: a later confirmation selects the class", string.find(texts(), "SELECTED") ~= nil)
	elseif view == "refused" then
		press(btn("Main"))
		local v = table.clone(base)
		v.ClassAck = { N = 1, Id = "toastmaster", Action = "Select", Ok = false, Code = "NOT_OWNED" }
		send(v)
		check("refused: the reason is shown and the old class is kept", string.find(texts(), "do not own") ~= nil and string.find(texts(), "Still using Ruckus") ~= nil, texts())
	elseif view == "queued" then
		check("queued: explains the class lock and offers LEAVE QUEUE", string.find(texts(), "leave the queue") ~= nil or string.find(texts(), "Leave the queue") ~= nil, texts())
		check("queued: LEAVE QUEUE is visible and sends QueueAction Leave", visible("LeaveQueue") and press(btn("LeaveQueue")) and sentCount("QueueAction", "Leave") == 1)
	elseif view == "confirm" then
		local t = texts()
		check("confirm: the dialog names the class, the price and the outcome", string.find(t, "Buy Captain Croak") ~= nil and string.find(t, "20,000") ~= nil and string.find(t, "unlocked for good") ~= nil)
		check("confirm: nothing was sent before CONFIRM", sentCount("ClassAction") == 0)
		press(btn("ConfirmBuy"))
		check("confirm: CONFIRM sends exactly one ClassAction Buy captain_croak", sentCount("ClassAction", "Buy", "captain_croak") == 1)
		check("confirm: the purchase is pending (BUYING) until the server answers", string.find(texts(), "BUYING") ~= nil)
	elseif view == "guide" then
		-- the guide opened by itself for this new account
		local step = tonumber(preview.args.step) or 1
		for _ = 2, step do
			press(btn("Next"))
		end
		check("guide: open on the right step", visible("Guide"), texts())
	end
end

preview.log(string.format("class-browser-ui view=%s: %d PASS, %d FAIL", view, passes, fails))
if fails > 0 then
	error(string.format("class-browser-ui: %d checks failed", fails))
end
