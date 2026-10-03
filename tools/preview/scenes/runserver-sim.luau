-- runserver-sim: private run servers (RunServers.lua) against the TeleportService mock
-- (preview.teleport(): ReserveServer / TeleportAsync are recorded, failures on demand;
-- nothing really moves, the scene plays arrivals and departures itself). Prints PASS / FAIL.
--   --set role=lobby (default)  a published lobby server (PlaceId set, no --studio): ticket
--       building, one teleport per team, two solo starts at once each get their own server,
--       the save released before the teleport (store lock cleared), a blocked double start,
--       a party DUO ticket, TeleportInitFailed → one retry → a solo fallback run here (save
--       taken back), ReserveServer failing twice → the DUO plays here, Enabled = false →
--       here, and SanitizeTicket against hostile tickets.
--   --set role=run  a reserved run server (PrivateServerId set, owner 0) whose players carry
--       a TRIO ticket: the "Starting" wait, a lobby start ignored meanwhile, an intruder
--       without a ticket sent home, the automatic start after WaitForTeamSeconds with the two
--       who came (ticket curses sanitised, locked arena refused), a late member refused,
--       MAIN MENU → the go-home banner, STAY, GO NOW failing twice (save taken back, the
--       run server's lobby stays usable), a REPLAY here, and the timer sending the party home
--       together with SwarmReturn data.
-- Run: render.sh runserver-sim --devices pc --max-time 200 [--set role=run]
-- (Studio behaviour is unchanged: menu-sim / stage-sim run with --studio.)
local C = lib("common")
local Players = game:GetService("Players")
local DataStoreService = game:GetService("DataStoreService")
local T = preview.teleport()
local role = preview.args.role or "lobby"
local me = Players.LocalPlayer

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
local function ids(list: { number }?): string
	local out = {}
	for _, id in ipairs(list or {}) do
		table.insert(out, tostring(id))
	end
	return table.concat(out, ",")
end
local function lastCall()
	return T.calls[#T.calls]
end

T.placeId = 4242
local ticketFor -- run role: the TRIO ticket every member carries
if role == "run" then
	T.privateServerId = "ps-1"
	T.privateServerOwnerId = 0
	ticketFor = {
		SwarmRun = {
			V = 1,
			Mode = "Trio",
			Endless = false,
			Curses = { "Frenzy", "NotACurse", "Frenzy" },
			Arena = "Lava", -- nobody has reached the stage it needs: Forest instead
			Day = 20000,
			Members = { 1, 2, 3 },
			Starter = 1,
			Party = { Leader = 1, Members = { 1, 2 } },
		},
	}
	T.joinData[1] = ticketFor
end

local ava = preview.addPlayer("Ava", role == "lobby" and 2 or 4)
local ben = role == "lobby" and preview.addPlayer("Ben", 3) or nil
preview.forceMeshesUploaded()
preview.startServer()
preview.advance(2)
C.startClient()
if preview.args.headless == "on" then preview.client("TravelOverlay").Init() end
preview.advance(1)

local st = C.state()
local RM = preview.server("RunManager")
local RS = preview.server("RunServers")
local DS = preview.server("DataService")
local Config = preview.shared("Config")
local Remotes = preview.shared("Remotes")
local store = DataStoreService:GetDataStore(Config.Data.StoreName)
local function record(p: Player)
	return store:GetAsync(Config.Data.KeyPrefix .. p.UserId)
end

local notes: { [Player]: { string } } = {}
local origFire = Remotes.FireClient
Remotes.FireClient = function(name, p, ...)
	if name == "Notify" then
		local d = ...
		notes[p] = notes[p] or {}
		table.insert(notes[p], type(d) == "table" and d.Text or "?")
	end
	return origFire(name, p, ...)
end
local function lastNote(p: Player): string
	local list = notes[p] or {}
	return list[#list] or "-"
end

if role == "lobby" then
	check("lobby role", RS.Role() == "Lobby" and st:GetAttribute("RunServer") == false)

	-- 1. two players start SOLO at the same time: each gets their own reserved server
	as(me, "StartRun", "Solo")
	as(ava, "StartRun", "Solo")
	preview.advance(0.5)
	check("two solo starts → two teleports", #T.calls == 2, tostring(#T.calls))
	local c1, c2 = T.calls[1], T.calls[2]
	check("separate reserved servers", c1 and c2 and c1.Code ~= c2.Code and c1.Code ~= "", c1 and c2 and (c1.Code .. " / " .. c2.Code) or "-")
	local t1 = c1 and c1.Data and c1.Data.SwarmRun
	check("ticket: Solo, me only, starter me, v1", t1 and t1.Mode == "Solo" and ids(t1.Members) == "1" and t1.Starter == 1 and t1.V == 1, t1 and (t1.Mode .. " " .. ids(t1.Members)) or "no ticket")
	check("ticket: arena + day + curses", t1 and t1.Arena == st:GetAttribute("SelectedArena") and type(t1.Day) == "number" and type(t1.Curses) == "table")
	check("lobby stays in Lobby phase", st:GetAttribute("Phase") == "Lobby", tostring(st:GetAttribute("Phase")))
	check("travel cover attribute", me:GetAttribute("Travel") == "ToRun" and ava:GetAttribute("Travel") == "ToRun")
	local r = record(me)
	check("save released before the teleport (no lock, LastJob set)", DS.IsReleased(me) and type(r) == "table" and r.Lock == nil and r.LastJob ~= nil and type(r.Data) == "table")
	local overlay = preview.client("TravelOverlay").Debug()
	check("client cover shows", overlay.Cover and string.find(overlay.Title, "TRAVELLING") ~= nil, overlay.Title)

	-- 2. a second start while travelling does nothing
	as(me, "StartRun", "Solo")
	preview.advance(0.5)
	check("double start blocked", #T.calls == 2)

	-- 3. Ava's teleport worked: she leaves; the lobby writes nothing more for her
	local before = record(ava)
	preview.removePlayer(ava)
	preview.advance(0.5)
	local after = record(ava)
	check("left player's save untouched after the handoff", before and after and after.Lock == nil and after.Data.Gold == before.Data.Gold)

	-- 4. my teleport fails twice → one retry, then a solo run on this server
	preview.teleportInitFailed(me)
	preview.advance(1.5)
	check("retry once alone", #T.calls == 3 and ids(lastCall().UserIds) == "1" and lastCall().Code == c1.Code, tostring(#T.calls))
	preview.teleportInitFailed(me)
	preview.advance(1)
	check("fallback: the solo run plays here", st:GetAttribute("Phase") == "Running" and me:GetAttribute("InRun") == true, tostring(st:GetAttribute("Phase")))
	local r2 = record(me)
	check("save taken back (lock is ours again)", not DS.IsReleased(me) and r2.Lock ~= nil and r2.Lock.JobId == game.JobId)
	check("fallback toast", string.find(lastNote(me), "STAGE") ~= nil or string.find(table.concat(notes[me] or {}, "|"), "playing on this server") ~= nil, table.concat(notes[me] or {}, " | "))
	check("cover gone", me:GetAttribute("Travel") == "")
	as(me, "AbandonRun")
	preview.advance(1)
	check("back in the lobby (no run server: no home timer)", st:GetAttribute("Phase") == "Lobby" and me:GetAttribute("TravelHomeIn") == nil)

	-- 5. a party DUO: one teleport for both, the party in the ticket
	preview.advance(9)
	as(me, "Party", "Invite", ben.UserId)
	preview.advance(0.4)
	as(ben, "Party", "Accept", me.UserId)
	preview.advance(0.4)
	as(ben, "Party", "Ready", true)
	preview.advance(0.4)
	local n = #T.calls
	as(me, "StartRun", "Duo")
	preview.advance(0.6)
	local c = lastCall()
	local tk = c and c.Data and c.Data.SwarmRun
	check("party DUO → one teleport with both", #T.calls == n + 1 and ids(c.UserIds) ~= "" and #c.UserIds == 2, c and ids(c.UserIds) or "-")
	check("ticket carries the party", tk and tk.Mode == "Duo" and tk.Party and tk.Party.Leader == 1 and #tk.Party.Members == 2)
	-- both fail for good: me then Ben (multi-player team: told to start again, no run)
	for _ = 1, 2 do
		preview.teleportInitFailed(me)
		preview.teleportInitFailed(ben)
		preview.advance(1.5)
	end
	check("team member's failure: saves back, no hidden run", not DS.IsReleased(me) and not DS.IsReleased(ben) and st:GetAttribute("Phase") == "Lobby", lastNote(me))

	-- 6. ReserveServer fails twice → the DUO plays here with both
	T.reserveFails = 2
	n = #T.calls
	as(ben, "Party", "Ready", true)
	preview.advance(0.4)
	as(me, "StartRun", "Duo")
	preview.advance(3)
	check("ReserveServer down → DUO here", #T.calls == n and st:GetAttribute("Phase") == "Running" and st:GetAttribute("Participants") == 2, tostring(st:GetAttribute("Phase")) .. " " .. tostring(st:GetAttribute("Participants")))
	check("saves taken back", not DS.IsReleased(me) and not DS.IsReleased(ben))
	as(me, "AbandonRun")
	as(ben, "AbandonRun")
	preview.advance(1)

	-- 7. TeleportAsync throwing twice → here as well
	T.teleportFails = 2
	as(ben, "Party", "Leave")
	preview.advance(0.4)
	as(me, "StartRun", "Solo")
	preview.advance(3)
	check("TeleportAsync down → solo here", st:GetAttribute("Phase") == "Running" and not DS.IsReleased(me), tostring(st:GetAttribute("Phase")))
	as(me, "AbandonRun")
	preview.advance(1)

	-- 8. Enabled = false: today's in-server runs
	Config.RunServers.Enabled = false
	n = #T.calls
	as(me, "StartRun", "Solo")
	preview.advance(0.5)
	check("Enabled = false → no teleport, run here", #T.calls == n and st:GetAttribute("Phase") == "Running" and me:GetAttribute("Travel") == "")
	as(me, "AbandonRun")
	preview.advance(1)
	Config.RunServers.Enabled = true

	-- 9. SanitizeTicket against hostile tickets
	local S = RS.SanitizeTicket
	check("garbage refused", S(nil) == nil and S("x") == nil and S({}) == nil and S({ V = 99, Mode = "Solo", Members = { 1 } }) == nil)
	check("bad mode refused", S({ V = 1, Mode = "Order", Members = { 1 } }) == nil and S({ V = 1, Mode = "God", Members = { 1 } }) == nil)
	check("too many members refused", S({ V = 1, Mode = "Duo", Members = { 1, 2, 3 } }) == nil)
	check("bad ids refused", S({ V = 1, Mode = "Solo", Members = { 0 / 0 } }) == nil and S({ V = 1, Mode = "Solo", Members = { -4 } }) == nil and S({ V = 1, Mode = "Solo", Members = { 1.5 } }) == nil)
	local clean = S({ V = 1, Mode = "Trio", Members = { 7, 7, 8 }, Starter = 99, Arena = "Moon", Curses = { "Frenzy", 5 }, Endless = "yes", Party = { Leader = 50, Members = { 50 } } })
	check("dirty fields cleaned", clean ~= nil and ids(clean.Members) == "7,8" and clean.Starter == 7 and clean.Arena == Config.Arenas.Order[1] and #clean.Curses == 0 and clean.Endless == false and clean.Party == nil, clean and (ids(clean.Members) .. " " .. clean.Arena) or "nil")
	local daily = S({ V = 1, Mode = "Daily", Members = { 1 }, Endless = true })
	check("daily never endless", daily ~= nil and daily.Endless == false)
else
	-- run server
	check("run role", RS.Role() == "Run" and st:GetAttribute("RunServer") == true and st:GetAttribute("RunServerStatus") == "Waiting", tostring(st:GetAttribute("RunServerStatus")))
	check("expects three", st:GetAttribute("RunServerExpected") == 3)
	local overlay = preview.client("TravelOverlay").Debug()
	check("client 'Starting' cover", overlay.Cover and string.find(overlay.Title, "STARTING") ~= nil, overlay.Title .. " / " .. overlay.Line)
	as(me, "StartRun", "Solo")
	preview.advance(0.5)
	check("lobby start ignored while starting", st:GetAttribute("Phase") == "Lobby")
	-- Ava's account is not in the ticket; authorized member 2 arrives as Dee below.
	check("intruder sent home", lastCall() ~= nil and ids(lastCall().UserIds) == "4" and lastCall().Data.SwarmReturn ~= nil, lastCall() and ids(lastCall().UserIds) or "no call")
	preview.removePlayer(ava)
	T.joinData[2] = ticketFor
	local dee = preview.addPlayer("Dee", 2)
	preview.playerJoined(dee)
	preview.advance(3)
	check("still waiting for the third member", st:GetAttribute("RunServerStatus") == "Waiting" and st:GetAttribute("RunServerHere") == 2, tostring(st:GetAttribute("RunServerHere")))
	preview.advance(13)
	check("auto start after the wait", st:GetAttribute("Phase") == "Running" and st:GetAttribute("RunServerStatus") == "Started" and st:GetAttribute("Participants") == 2, tostring(st:GetAttribute("Phase")) .. " " .. tostring(st:GetAttribute("Participants")))
	check("mode Trio, arena Forest (Lava locked)", st:GetAttribute("Mode") == "Trio" and st:GetAttribute("SelectedArena") == "Forest", tostring(st:GetAttribute("SelectedArena")))
	check("curses sanitised", st:GetAttribute("Curses") == "Frenzy", tostring(st:GetAttribute("Curses")))
	preview.advance(0.5)
	check("cover gone", not preview.client("TravelOverlay").Debug().Cover)
	-- a late member is refused
	local n = #T.calls
	T.joinData[3] = ticketFor
	local cal = preview.addPlayer("Cal", 3)
	preview.playerJoined(cal)
	preview.advance(1)
	check("late member sent home", #T.calls == n + 1 and ids(lastCall().UserIds) == "3", lastNote(cal))

	-- MAIN MENU (pause) for both: results over the lobby, the go-home banner
	as(me, "AbandonRun")
	as(dee, "AbandonRun")
	preview.advance(1)
	check("home timer set", me:GetAttribute("TravelHomeIn") == Config.RunServers.HomeDelaySeconds - 1 or me:GetAttribute("TravelHomeIn") == Config.RunServers.HomeDelaySeconds, tostring(me:GetAttribute("TravelHomeIn")))
	local o = preview.client("TravelOverlay").Debug()
	check("client banner", o.Banner and string.find(o.BannerText, "Back to the lobby") ~= nil, o.BannerText)
	-- Dee stays
	as(dee, "TravelHome", "Stay")
	preview.advance(0.5)
	check("STAY clears Dee's timer", dee:GetAttribute("TravelHomeIn") == nil)
	-- GO NOW fails twice → save back, keeps playing here
	n = #T.calls
	T.teleportFails = 2
	as(me, "TravelHome", "Go")
	preview.advance(2)
	check("GO NOW failed: save back, no timer, cover gone", #T.calls == n and not DS.IsReleased(me) and me:GetAttribute("Travel") == "" and me:GetAttribute("TravelHomeIn") == nil, lastNote(me))
	-- REPLAY here: a local run on the run server
	as(me, "StartRun", "Solo")
	preview.advance(1)
	check("replay plays on the run server", st:GetAttribute("Phase") == "Running" and #T.calls == n)
	as(me, "AbandonRun")
	preview.advance(1)
	-- Dee waits again (as if back from her own run) → the timer sends both together
	preview.server("RunServers").OnBackInLobby(dee, "results")
	preview.advance(Config.RunServers.HomeDelaySeconds + 1)
	local c = lastCall()
	local back = c and c.Data and c.Data.SwarmReturn
	check("home teleports sent", #T.calls > n, tostring(#T.calls - n))
	check("return data names the party", back ~= nil and back.Party ~= nil and back.Party.Leader == 1, back and back.Party and ids(back.Party.Members) or "-")
	check("saves released before going home", DS.IsReleased(me) and record(me).Lock == nil)
	check("cover shows on the way", me:GetAttribute("Travel") == "ToLobby")
end

preview.log(fails == 0 and "ALL PASS" or (fails .. " FAIL"))
assert(fails == 0, tostring(fails) .. " run-server checks failed")
