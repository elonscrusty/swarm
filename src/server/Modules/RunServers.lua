--[[
	RunServers.lua  (server only)
	Private run servers: every run in the live game plays on its own reserved server, so a
	run can always start, whoever else is playing (Config.RunServers).

	Roles (decided once at boot):
	  Lobby  a public server (today's lobby). When a run would start (RunManager.beginRun:
	         SOLO, the Daily, a DUO / TRIO countdown's end or START NOW, a party leader's
	         start after READY) SendToRun takes the team instead of starting it here.
	  Run    a reserved server of this place (game.PrivateServerId ~= "" and
	         PrivateServerOwnerId == 0, never a Roblox VIP server) whose players carry a run
	         ticket in their join data. It starts that run by itself and sends everyone back
	         to a public lobby afterwards.
	  Studio, an unpublished place (PlaceId 0) and Enabled = false never leave the server:
	  runs play on the lobby server exactly as before (role Lobby, SendToRun says no).

	Lobby side (SendToRun → travel):
	  1. ticket { V, Mode, Endless, Curses, Arena, Day, Members {UserId}, Starter, Party }
	     (Day is informational: the run server's own UTC day picks the daily, as always)
	  2. every player's save is written and released (DataService.ReleaseForTeleport) so
	     the run server loads the latest save at once (no lost gold / unlocks, no double load)
	  3. TeleportService:ReserveServer, then ONE TeleportAsync for the whole team with
	     TeleportOptions { ReservedServerAccessCode, TeleportData { SwarmRun = ticket } }
	  Each step is tried twice. If it still fails, the saves are taken back
	  (DataService.Reclaim) and the run starts on this server as before (RunManager.
	  StartTeamRun), with a toast. A single player whose teleport fails (TeleportInitFailed,
	  or still here after TeleportTimeoutSeconds) is retried once alone, then taken back: a
	  solo / daily run then starts here, a team member is told to start again.
	  Player attribute "Travel" = "ToRun" shows the client's "Travelling to your run…" cover
	  (TravelOverlay); Blocks() keeps those players out of other starts and countdowns.

	Run server side:
	  The first valid ticket is the server's (every field sanitised again here: join data
	  passes through the client). Only its Members may stay; anyone else (or a member who
	  arrives after the run started) is sent back to a lobby with a toast. The run starts
	  when the whole team's saves are loaded, or after WaitForTeamSeconds (WaitForLoadSeconds
	  while someone who is here is still loading). Character ownership is the save's, as
	  in any run; the arena must be unlocked for someone in the team (else the first arena);
	  the starter's curses / Endless switch are the ticket's (sanitised: they are the
	  starter's own lobby pick). SwarmState "RunServer" (true), "RunServerStatus"
	  ("Waiting" | "Started" | "Failed"), "RunServerHere" / "RunServerExpected" drive the
	  client's "Starting…" cover; the lobby menu under it can't start anything meanwhile.
	  Back in the lobby after a run (RunManager.returnPlayerToLobby → OnBackInLobby) the
	  player goes home after HomeDelaySeconds (results over the lobby menu) or
	  HomeDelayAfterResultsSeconds (the defeat results already counted down); player
	  attribute "TravelHomeIn" shows the countdown with GO NOW / STAY (remote TravelHome).
	  Going home saves and releases first, then TeleportAsync(game.PlaceId, players) with
	  TeleportData { SwarmReturn = { Party } }: party mates waiting at the same moment go in
	  one teleport (same lobby server) and PartyService re-forms the party there. If the
	  teleport fails twice the save is taken back and the run server's own lobby stays
	  usable (runs started there play here). Roblox closes the reserved server when empty;
	  DataService's BindToClose saves anyone left.

	Leaderboards, the daily, achievements and DEV taint are per run already; DEV commands
	stay behind DevAccess on run servers too.
]]

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local TeleportService = game:GetService("TeleportService")

local Config = require(game:GetService("ReplicatedStorage").Shared.Config)
local Remotes = require(game:GetService("ReplicatedStorage").Shared.Remotes)
local CurseData = require(game:GetService("ReplicatedStorage").Shared.CurseData)
local DifficultyData = require(game:GetService("ReplicatedStorage").Shared.DifficultyData)

local RunServers = {}

export type Ticket = {
	V: number,
	Mode: string,
	Endless: boolean,
	Difficulty: string,
	Curses: { string },
	Arena: string,
	Day: number,
	Members: { number },
	Starter: number,
	Party: { Leader: number, Members: { number } }?,
}

type Travel = { Kind: string, Players: { Player }, Options: any, Ticket: Ticket?, Retried: { [Player]: boolean } }

local ctx
local state: Configuration
local role = "Lobby"

-- lobby + run: players on their way out through one of our teleports
local travelling: { [Player]: Travel } = {}
-- players whose teleport failures are ours to report (PartyService stays quiet)
local ownTeleport: { [Player]: number } = {}

-- run server
local ticket: Ticket? = nil
local expected: { [number]: boolean } = {}
local firstArrival = 0
local status = "Waiting"
local refused: { [Player]: string } = {} -- sent home once their save is loaded
local homeAt: { [Player]: number } = {} -- back in the run server's lobby: goes home at (os.clock)
local reconnecting: { [Player]: string } = {}

local GOOD = Color3.fromRGB(120, 255, 160)
local WARN = Color3.fromRGB(255, 200, 120)
local BAD = Color3.fromRGB(255, 120, 120)

local function cfg()
	return Config.RunServers
end

local function notify(player: Player, text: string, color: Color3?)
	if player.Parent then
		Remotes.FireClient("Notify", player, { Text = text, Color = color })
	end
end

-- Teleports are possible: the live game with the feature on.
local function live(): boolean
	return cfg() ~= nil and cfg().Enabled == true and not RunService:IsStudio() and game.PlaceId ~= 0
end

function RunServers.Role(): string
	return role
end

function RunServers.IsRunServer(): boolean
	return role == "Run"
end

-- This server-only saved pointer contains the reserved access code. Never replicate it.
function RunServers.HasPendingReconnect(data): boolean
	local r = data and data.RunReconnect
	return type(r) == "table" and type(r.AccessCode) == "string" and r.AccessCode ~= ""
		and type(r.PrivateId) == "string" and r.PrivateId ~= "" and type(r.Id) == "string" and r.Id ~= ""
		and type(r.Expires) == "number" and r.Expires > os.time()
		and r.Expires <= os.time() + cfg().RejoinGraceSeconds + 5
		and type(data.RunEscrow) == "table" and data.RunEscrow.Id == r.Id
end

function RunServers.RegisterRun(rp)
	local data = ctx.DataService.GetData(rp.Player)
	local r = data and data.RunReconnect
	if role == "Run" and type(r) == "table" and r.PrivateId == game.PrivateServerId then
		r.Id, r.Expires = rp.RunId, 0
	elseif data then
		data.RunReconnect = nil
	end
end

function RunServers.CanReconnect(rp): boolean
	local data = ctx.DataService.GetData(rp.Player)
	local r = data and data.RunReconnect
	return role == "Run" and ticket ~= nil and #ticket.Members > 1 and expected[rp.Player.UserId] == true
		and type(r) == "table" and r.PrivateId == game.PrivateServerId and r.Id == rp.RunId
		and type(r.AccessCode) == "string" and r.AccessCode ~= ""
end

local function endReconnect(player: Player)
	local data = ctx.DataService.GetData(player)
	if data then
		data.RunReconnect = nil
		ctx.GoldSystem.RecoverEscrow(data)
		ctx.GoldSystem.SyncProfile(player)
	end
end

------------------------------------------------------------------------------------------
-- Tickets
------------------------------------------------------------------------------------------

local function validMode(mode: any): boolean
	return type(mode) == "string" and type((Config.Modes :: any)[mode]) == "table" and mode ~= "Order"
end

local function cleanIds(list: any, max: number): { number }?
	if type(list) ~= "table" then
		return nil
	end
	local out, seen = {}, {}
	for i = 1, max do
		local id = list[i]
		if id == nil then
			break
		end
		if type(id) ~= "number" or id ~= id or id <= 0 or id % 1 ~= 0 or id > 2 ^ 53 then
			return nil
		end
		if not seen[id] then
			seen[id] = true
			table.insert(out, id)
		end
	end
	if list[max + 1] ~= nil then
		return nil
	end
	return out
end

local function cleanParty(raw: any, members: { number }?): { Leader: number, Members: { number } }?
	if type(raw) ~= "table" or type(raw.Leader) ~= "number" then
		return nil
	end
	local ids = cleanIds(raw.Members, Config.Run.MaxPlayers)
	if not ids or not table.find(ids, raw.Leader) then
		return nil
	end
	if members then
		for _, id in ipairs(ids) do
			if not table.find(members, id) then
				return nil
			end
		end
	end
	return { Leader = raw.Leader, Members = ids }
end

--[[
	Checks every field of a ticket that came back through join data (it passes through the
	client, so it is never trusted as is). Returns a clean copy or nil.
]]
function RunServers.SanitizeTicket(raw: any): Ticket?
	if type(raw) ~= "table" or raw.V ~= cfg().TicketVersion or not validMode(raw.Mode) then
		return nil
	end
	local modeDef = (Config.Modes :: any)[raw.Mode]
	local cap = math.min(Config.Run.MaxPlayers, modeDef.MaxPlayers or 1)
	local members = cleanIds(raw.Members, cap)
	if not members or #members == 0 then
		return nil
	end
	local starter = (type(raw.Starter) == "number" and table.find(members, raw.Starter)) and raw.Starter or members[1]
	local arena = (type(raw.Arena) == "string" and table.find(Config.Arenas.Order, raw.Arena)) and raw.Arena or Config.Arenas.Order[1]
	local day = (type(raw.Day) == "number" and raw.Day == raw.Day) and math.floor(raw.Day) or 0
	return {
		V = cfg().TicketVersion,
		Mode = raw.Mode,
		Difficulty = raw.Mode ~= CurseData.DailyMode and type(raw.Difficulty) == "string" and DifficultyData.Tiers[raw.Difficulty] ~= nil and raw.Difficulty or "Standard",
		Endless = raw.Endless == true and Config.Endless.Enabled == true and table.find(Config.Endless.Modes, raw.Mode) ~= nil,
		Curses = CurseData.Sanitize(raw.Curses) or {},
		Arena = arena,
		Day = day,
		Members = members,
		Starter = starter,
		Party = cleanParty(raw.Party, members),
	}
end

-- The ticket for a team about to start on this lobby server.
function RunServers.BuildTicket(list: { Player }, mode: string, starter: Player, arena: string): Ticket
	local members = {}
	for _, p in ipairs(list) do
		table.insert(members, p.UserId)
	end
	local data = ctx.DataService.GetData(starter)
	local party = nil
	local pt = ctx.PartyService and ctx.PartyService.PartyOf(starter)
	if pt then
		local ids = {}
		for _, m in ipairs(pt.Members) do
			if table.find(members, m.UserId) then
				table.insert(ids, m.UserId)
			end
		end
		if #ids > 1 and table.find(ids, pt.Leader.UserId) then
			party = { Leader = pt.Leader.UserId, Members = ids }
		end
	end
	return {
		V = cfg().TicketVersion,
		Mode = mode,
		Difficulty = mode ~= CurseData.DailyMode and DifficultyData.Selected(data) or "Standard",
		Endless = data ~= nil and data.Endless == true,
		Curses = data and CurseData.Sanitize(data.Curses) or {},
		Arena = arena,
		Day = ctx.RunModifiers.Today(),
		Members = members,
		Starter = starter.UserId,
		Party = party,
	}
end

local function joinTeleportData(player: Player): any
	local ok, data = pcall(function()
		return player:GetJoinData()
	end)
	if ok and type(data) == "table" and type(data.TeleportData) == "table" then
		return data.TeleportData
	end
	return nil
end

-- The SwarmReturn part of a player's join data (back from a run server), or nil.
function RunServers.ReturnData(player: Player): { Party: { Leader: number, Members: { number } }? }?
	local td = joinTeleportData(player)
	local raw = td and td.SwarmReturn
	if type(raw) ~= "table" then
		return nil
	end
	return { Party = cleanParty(raw.Party, nil) }
end

------------------------------------------------------------------------------------------
-- Teleports
------------------------------------------------------------------------------------------

local function setTravel(player: Player, kind: string?)
	if player.Parent then
		player:SetAttribute("Travel", kind or "")
	end
end

local function makeOptions(code: string?, data: { [string]: any }): any
	local options = Instance.new("TeleportOptions")
	if code then
		options.ReservedServerAccessCode = code
	end
	options:SetTeleportData(data)
	return options
end

-- One TeleportAsync for these players, tried twice. True when Roblox accepted it.
local function teleport(players: { Player }, options: any): boolean
	for attempt = 1, 2 do
		local here = {}
		for _, p in ipairs(players) do
			if p.Parent then
				table.insert(here, p)
			end
		end
		if #here == 0 then
			return true
		end
		local ok, err = pcall(function()
			TeleportService:TeleportAsync(game.PlaceId, here, options)
		end)
		if ok then
			return true
		end
		warn("[RunServers] TeleportAsync failed: " .. tostring(err))
		if attempt < 2 then
			task.wait(1)
		end
	end
	return false
end

-- Takes a released save back (the player stays). False: the player is kicked to rejoin
-- (their save from just before the teleport is safe in the store).
local function takeBack(player: Player): boolean
	if not player.Parent then
		return false
	end
	if not ctx.DataService.IsReleased(player) then
		return ctx.DataService.GetData(player) ~= nil
	end
	if ctx.DataService.Reclaim(player) then
		ctx.GoldSystem.SyncProfile(player)
		return true
	end
	if player.Parent then
		player:Kick("Couldn't reach your run's server. Please rejoin: your progress is saved.")
	end
	return false
end

local function settle(player: Player)
	travelling[player] = nil
	setTravel(player, nil)
	ownTeleport[player] = os.clock()
	task.delay(10, function()
		if ownTeleport[player] and os.clock() - ownTeleport[player] >= 9 then
			ownTeleport[player] = nil
		end
	end)
end

-- Lobby: the team could not travel. Saves back, and the run starts on this server.
local function fallbackHere(players: { Player }, t: Ticket, starter: Player?)
	local back = {}
	for _, p in ipairs(players) do
		settle(p)
		if takeBack(p) then
			local data = ctx.DataService.GetData(p)
			if data then data.RunReconnect = nil end
			table.insert(back, p)
		end
	end
	if #back == 0 then
		return
	end
	for _, p in ipairs(back) do
		notify(p, "Couldn't reach a run server: playing on this server.", WARN)
	end
	if not ctx.RunManager.StartTeamRun(back, t.Mode, t.Arena, starter) then
		for _, p in ipairs(back) do
			notify(p, "Couldn't start the run right now: try again.", BAD)
		end
	end
end

-- One player's teleport failed for good (after its retry).
local function failOne(player: Player)
	local tr = travelling[player]
	if not tr then
		return
	end
	settle(player)
	if not player.Parent then
		return
	end
	if tr.Kind == "Run" then
		local t = tr.Ticket :: Ticket
		if #t.Members == 1 then
			fallbackHere({ player }, t, player)
		elseif takeBack(player) then
			local data = ctx.DataService.GetData(player)
			if data then data.RunReconnect = nil end -- the reserved route never became a run
			notify(player, "Couldn't reach your team's run server. Start a new run.", BAD)
		end
	elseif tr.Kind == "Rejoin" then
		if takeBack(player) then
			endReconnect(player)
			notify(player, "Couldn't reconnect. Your gold is safe; you can start a new run.", WARN)
		end
	elseif takeBack(player) then
		homeAt[player] = nil
		player:SetAttribute("TravelHomeIn", nil)
		notify(player, "Couldn't reach a lobby server: you can keep playing here.", WARN)
	end
end

local function onTeleportFailed(player: Player, result: any, message: any)
	local tr = travelling[player]
	if not tr then
		return
	end
	warn(string.format("[RunServers] teleport failed for %s: %s %s", player.Name, tostring(result), tostring(message)))
	if not tr.Retried[player] then
		tr.Retried[player] = true
		task.spawn(function()
			task.wait(1)
			if travelling[player] == tr and player.Parent then
				local ok = pcall(function()
					TeleportService:TeleportAsync(game.PlaceId, { player }, tr.Options)
				end)
				if not ok then
					failOne(player)
				end
			end
		end)
		return
	end
	failOne(player)
end

-- Players still here long after their teleport: it failed silently.
local function watchTimeout(tr: Travel)
	task.delay(cfg().TeleportTimeoutSeconds, function()
		for _, p in ipairs(tr.Players) do
			if travelling[p] == tr and p.Parent then
				warn("[RunServers] teleport timed out for " .. p.Name)
				failOne(p)
			end
		end
	end)
end

-- True while RunServers reports this player's teleport problems (PartyService stays quiet).
function RunServers.OwnsTeleport(player: Player): boolean
	return travelling[player] ~= nil or ownTeleport[player] ~= nil
end

------------------------------------------------------------------------------------------
-- Lobby: send a team to a fresh run server
------------------------------------------------------------------------------------------

local function travelToRun(list: { Player }, t: Ticket, starter: Player)
	-- Reserve first so the secret reconnect route is saved before profile release.
	local code: string? = nil
	local privateId: string? = nil
	for attempt = 1, 2 do
		local ok, result, reservedId = pcall(function()
			return TeleportService:ReserveServerAsync(game.PlaceId)
		end)
		if ok and type(result) == "string" and result ~= "" then
			code = result
			privateId = type(reservedId) == "string" and reservedId or nil
			break
		end
		warn("[RunServers] ReserveServer failed: " .. tostring(result))
		if attempt < 2 then
			task.wait(1)
		end
	end
	if not code then
		fallbackHere(list, t, starter)
		return
	end
	local released = true
	for _, p in ipairs(list) do
		local data = ctx.DataService.GetData(p)
		if data then
			data.RunReconnect = privateId and { AccessCode = code, PrivateId = privateId, Id = "", Expires = 0 } or nil
		end
		if p.Parent and not ctx.DataService.ReleaseForTeleport(p) then released = false end
	end
	if not released then
		fallbackHere(list, t, starter)
		return
	end
	-- 3. the whole team in one teleport
	local tr: Travel = { Kind = "Run", Players = list, Options = makeOptions(code, { SwarmRun = t }), Ticket = t, Retried = {} }
	for _, p in ipairs(list) do
		travelling[p] = tr
	end
	if not teleport(list, tr.Options) then
		fallbackHere(list, t, starter)
		return
	end
	watchTimeout(tr)
end

--[[
	RunManager.beginRun asks first: true = the team is on its way to a private run server
	(this lobby goes straight back to its Lobby phase); false = play here (Studio, feature
	off, a run server's own lobby).
]]
function RunServers.SendToRun(list: { Player }, mode: string, starter: Player, arena: string): boolean
	if role ~= "Lobby" or not live() or #list == 0 then
		return false
	end
	local t = RunServers.BuildTicket(list, mode, starter, arena)
	for _, p in ipairs(list) do
		travelling[p] = { Kind = "Run", Players = list, Options = nil, Ticket = t, Retried = {} }
		setTravel(p, "ToRun")
	end
	task.spawn(travelToRun, list, t, starter)
	return true
end

-- On the way to a run server (or home from one) right now.
function RunServers.IsTravelling(player: Player): boolean
	return travelling[player] ~= nil
end

-- RunManager: this player may not start or join a run now (travelling, or this run
-- server is still starting its own run).
function RunServers.Blocks(player: Player): boolean
	if travelling[player] or reconnecting[player] or RunServers.HasPendingReconnect(ctx.DataService.GetData(player)) then
		return true
	end
	return role == "Run" and status == "Waiting"
end

------------------------------------------------------------------------------------------
-- Run server: back to a public lobby
------------------------------------------------------------------------------------------

local function sendHome(list: { Player }, why: string?)
	local group = {}
	for _, p in ipairs(list) do
		if p.Parent and not travelling[p] then
			table.insert(group, p)
		end
	end
	if #group == 0 then
		return
	end
	local t = ticket
	local data = { SwarmReturn = { V = cfg().TicketVersion, Party = t and t.Party or nil } }
	local tr: Travel = { Kind = "Home", Players = group, Options = makeOptions(nil, data), Ticket = t, Retried = {} }
	local ready = {}
	for _, p in ipairs(group) do
		homeAt[p] = nil
		p:SetAttribute("TravelHomeIn", nil)
		if why then
			notify(p, why, WARN)
		end
		-- a save that never loaded here (refused before loading) has nothing to hand over
		if ctx.DataService.GetData(p) == nil or ctx.DataService.ReleaseForTeleport(p) then
			travelling[p] = tr
			setTravel(p, "ToLobby")
			table.insert(ready, p)
		else
			notify(p, "Couldn't save before traveling: you can keep playing here.", WARN)
		end
	end
	if #ready == 0 then
		return
	end
	tr.Players = ready
	if not teleport(ready, tr.Options) then
		for _, p in ipairs(ready) do
			failOne(p)
		end
		return
	end
	watchTimeout(tr)
end

-- Everyone waiting to go home at this moment who shares a party with `player` (one teleport
-- keeps them together).
local function withPartyMates(player: Player): { Player }
	local list = { player }
	local party = ticket and ticket.Party
	if party and table.find(party.Members, player.UserId) then
		for other in pairs(homeAt) do
			if other ~= player and other.Parent and table.find(party.Members, other.UserId) then
				table.insert(list, other)
			end
		end
	end
	return list
end

--[[
	RunManager.returnPlayerToLobby: the player's run is over. On a run server they go back
	to a public lobby after a short wait (the results stay readable; GO NOW / STAY).
]]
function RunServers.OnBackInLobby(player: Player, how: string)
	if role ~= "Run" or not live() then
		return
	end
	local delay = how == "portal" and cfg().HomeDelaySeconds or cfg().HomeDelayAfterResultsSeconds
	homeAt[player] = os.clock() + delay
	player:SetAttribute("TravelHomeIn", math.ceil(delay))
end

local function homeStep()
	local now = os.clock()
	local due: { Player } = {}
	for player, at in pairs(homeAt) do
		if not player.Parent then
			homeAt[player] = nil
		elseif player:GetAttribute("InRun") == true then
			-- REPLAY started a new run here: it goes home after that one
			homeAt[player] = nil
			player:SetAttribute("TravelHomeIn", nil)
		else
			local left = math.max(0, math.ceil(at - now))
			if player:GetAttribute("TravelHomeIn") ~= left then
				player:SetAttribute("TravelHomeIn", left)
			end
			if now >= at then
				table.insert(due, player)
			end
		end
	end
	local sent: { [Player]: boolean } = {}
	for _, player in ipairs(due) do
		if not sent[player] then
			local group = withPartyMates(player)
			for _, p in ipairs(group) do
				sent[p] = true
			end
			task.spawn(sendHome, group)
		end
	end
end

local function onTravelHome(player: Player, choice: any)
	if role ~= "Run" or not homeAt[player] then
		return
	end
	if choice == "Go" then
		local group = withPartyMates(player)
		for _, p in ipairs(group) do
			homeAt[p] = nil
		end
		task.spawn(sendHome, group)
	elseif choice == "Stay" then
		homeAt[player] = nil
		player:SetAttribute("TravelHomeIn", nil)
		notify(player, "Staying here: start another run from the menu, or leave any time.", GOOD)
	end
end

------------------------------------------------------------------------------------------
-- Run server: arrivals and the automatic start
------------------------------------------------------------------------------------------

local function setStatus(s: string)
	status = s
	state:SetAttribute("RunServerStatus", s)
end

local function arenaFor(t: Ticket, players: { Player }): string
	local def = (Config.Arenas :: any)[t.Arena]
	local need = def and def.RequiredBestStage or 0
	for _, p in ipairs(players) do
		local data = ctx.DataService.GetData(p)
		if data and (data.Stats.BestStage or 0) >= need then
			return t.Arena
		end
	end
	return Config.Arenas.Order[1]
end

local function startTicketRun()
	local t = ticket :: Ticket
	local list, starter = {}, nil
	for _, id in ipairs(t.Members) do
		local p = Players:GetPlayerByUserId(id)
		if p and ctx.DataService.GetData(p) then
			table.insert(list, p)
			if id == t.Starter then
				starter = p
			end
		end
	end
	starter = starter or list[1]
	if not starter then
		return
	end
	-- the starter's lobby pick travelled with the ticket (their own choice: sanitised)
	if t.Mode ~= CurseData.DailyMode then
		local data = ctx.DataService.GetData(starter)
		if data then
			data.Curses = table.clone(t.Curses)
			data.Endless = t.Endless
			-- Join data is not authority. Validate the transported choice against the
			-- original host's loaded save, or the replacement host if they never arrived.
			local allowed = DifficultyData.IsUnlocked(data, t.Difficulty)
			data.Difficulty = allowed and t.Difficulty or "Standard"
			starter:SetAttribute("Difficulty", data.Difficulty)
			if not allowed then notify(starter, "That difficulty is locked. Starting Standard.", WARN) end
			starter:SetAttribute("Curses", CurseData.ToString(t.Curses))
			starter:SetAttribute("Endless", t.Endless)
		end
	end
	setStatus("Started")
	if not ctx.RunManager.StartTeamRun(list, t.Mode, arenaFor(t, list), starter) then
		setStatus("Failed")
		sendHome(list, "The run couldn't start: back to the lobby.")
	end
end

local function waitAndStart()
	while status == "Waiting" do
		local t = ticket :: Ticket
		local here, loaded = 0, 0
		for _, id in ipairs(t.Members) do
			local p = Players:GetPlayerByUserId(id)
			if p then
				here += 1
				if ctx.DataService.GetData(p) then
					loaded += 1
				end
			end
		end
		state:SetAttribute("RunServerHere", loaded)
		local waited = os.clock() - firstArrival
		if loaded >= #t.Members or (loaded > 0 and waited >= cfg().WaitForTeamSeconds and here <= loaded) or (loaded > 0 and waited >= cfg().WaitForLoadSeconds) then
			startTicketRun()
			return
		end
		if waited >= cfg().GiveUpSeconds then
			setStatus("Failed")
			sendHome(Players:GetPlayers(), "The run couldn't start: back to the lobby.")
			return
		end
		task.wait(0.25)
	end
end

local function refuse(player: Player, why: string)
	refused[player] = why
	if ctx.DataService.GetData(player) then
		refused[player] = nil
		sendHome({ player }, why)
	end
end

local function onArrival(player: Player)
	local td = joinTeleportData(player)
	if type(td) == "table" and type(td.SwarmRejoin) == "table" and type(td.SwarmRejoin.Id) == "string" then
		reconnecting[player] = td.SwarmRejoin.Id
		return
	end
	local t = td and RunServers.SanitizeTicket(td.SwarmRun)
	if not ticket and t and table.find(t.Members, player.UserId) then
		ticket = t
		for _, id in ipairs(t.Members) do
			expected[id] = true
		end
		firstArrival = os.clock()
		state:SetAttribute("RunServerExpected", #t.Members)
		state:SetAttribute("RunServerMode", t.Mode)
		task.spawn(waitAndStart)
	end
	if not expected[player.UserId] then
		refuse(player, "That run is private: back to the lobby.")
	elseif status ~= "Waiting" and not ctx.RunManager.IsParticipant(player) then
		refuse(player, "Your team's run already started: back to the lobby.")
	end
end

------------------------------------------------------------------------------------------
-- Lifecycle
------------------------------------------------------------------------------------------

function RunServers.Init(c)
	ctx = c
	state = Remotes.State()
	if live() and game.PrivateServerId ~= "" and game.PrivateServerOwnerId == 0 then
		role = "Run"
	end
	state:SetAttribute("RunServer", role == "Run")
	if role == "Run" then
		setStatus("Waiting")
		state:SetAttribute("RunServerHere", 0)
		state:SetAttribute("RunServerExpected", 0)
	end
end

function RunServers.Start()
	pcall(function()
		TeleportService.TeleportInitFailed:Connect(onTeleportFailed)
	end)
	Players.PlayerRemoving:Connect(function(player)
		travelling[player] = nil
		ownTeleport[player] = nil
		homeAt[player] = nil
		refused[player] = nil
		reconnecting[player] = nil
	end)
	ctx.DataService.OnProfileLoaded(function(player)
		-- Other load callbacks may create the lobby character; resume after those finish.
		task.defer(function()
			if not player.Parent then return end
			local data = ctx.DataService.GetData(player)
			if role == "Run" then
				local id = reconnecting[player]
				if id then
					reconnecting[player] = nil
					if expected[player.UserId] and RunServers.HasPendingReconnect(data)
						and data.RunReconnect.PrivateId == game.PrivateServerId and status == "Started"
						and ctx.RunManager.TryReconnect(player, id) then
						ctx.GoldSystem.SyncProfile(player)
						return
					end
					if not ticket then setStatus("Failed") end
					endReconnect(player)
					refuse(player, "That run has ended or your reconnect window expired. Back to the lobby.")
				end
				return
			end
			if not RunServers.HasPendingReconnect(data) then
				if data and data.RunReconnect then endReconnect(player) end
				return
			end
			if not live() then endReconnect(player); return end
			local r = data.RunReconnect
			local tr: Travel = { Kind = "Rejoin", Players = { player }, Options = makeOptions(r.AccessCode, { SwarmRejoin = { Id = r.Id } }), Retried = {} }
			travelling[player] = tr
			setTravel(player, "ToRun")
			if not ctx.DataService.ReleaseForTeleport(player) or not teleport({ player }, tr.Options) then
				failOne(player)
				return
			end
			watchTimeout(tr)
		end)
	end)
	if role ~= "Run" then
		return
	end
	Remotes.Listen("TravelHome", onTravelHome, 2)
	Players.PlayerAdded:Connect(onArrival)
	for _, p in ipairs(Players:GetPlayers()) do
		task.spawn(onArrival, p)
	end
	ctx.DataService.OnProfileLoaded(function(player)
		local why = refused[player]
		if why then
			refused[player] = nil
			sendHome({ player }, why)
		end
	end)
	task.spawn(function()
		while true do
			task.wait(0.25)
			homeStep()
		end
	end)
end

return RunServers
