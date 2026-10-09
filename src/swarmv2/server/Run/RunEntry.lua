--!strict
--[[
	SwarmV2/Run/RunEntry.lua  (ServerScriptService.SwarmV2.Run.RunEntry)
	OWNER: gameplay track. Contract: docs/redesign/OWNERSHIP.md, DESIGN.md section 7.

	Turns admitted players into a run:
	  * "match" role (a reserved run server reached by teleport): every arriving player is
	    resolved through MatchAdmission.ResolvePlayer (bounded retries behind the loading
	    overlay), then the ArrivalBarrier decides: wait for the group (start at once when
	    all are in, else after GroupWait), join late inside LateGrace, or reject with the
	    reason and a safe return to the lobby. No default avatar is ever spawned here.
	  * "local" role (Studio / unpublished / transfer off): the lobby calls
	    BeginLocalMatch(matchId, players) and the run starts on this same server.
	The class always comes from the admission context, never from a client.

	Loading overlay state for the client (player attributes, read by EntryOverlay):
	  SwarmV2Entry      "Admitting" | "Waiting" | "Starting" | "InRun" | "Rejected" | nil
	  SwarmV2EntryMsg   short text to show
	  SwarmV2EntryWait  seconds left in the group wait
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local SwarmV2Shared = ReplicatedStorage:WaitForChild("SwarmV2")
local Types = require(SwarmV2Shared:WaitForChild("Types"))
local RunConfig = require(SwarmV2Shared:WaitForChild("Run"):WaitForChild("RunConfig"))
local Config = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Config"))
local ArrivalBarrier = require(script.Parent:WaitForChild("ArrivalBarrier"))

type PlayerRunContext = Types.PlayerRunContext
type AdmissionResult = Types.AdmissionResult
type ReturnResult = Types.ReturnResult

-- The admission provider: the real MatchAdmission in the game; tests swap in DevAdmission.
type Admission = {
	ServerRole: () -> string,
	ResolvePlayer: (Player) -> AdmissionResult,
	ReturnToLobby: ({ Player }) -> { ReturnResult },
}

local E = RunConfig.Entry :: any

local RunEntry = {}

local ctx: any = nil
local admission: Admission? = nil
local role = "local"
local barrier: ArrivalBarrier.Barrier? = nil
local contexts: { [Player]: PlayerRunContext } = {}
local resolving: { [Player]: boolean } = {}
local waiting: { Player } = {}
local runStarted = false

local function setEntry(player: Player, status: string?, msg: string?)
	if player.Parent then
		player:SetAttribute("SwarmV2Entry", status)
		player:SetAttribute("SwarmV2EntryMsg", msg)
	end
end

-- Config.Modes key for a roster of n players (the existing run modes).
local function modeFor(n: number): string
	if n <= 1 then
		return "Solo"
	elseif n == 2 then
		return "Duo"
	elseif n == 3 then
		return "Trio"
	end
	return "Squad"
end

local function runArena(): string?
	local name = E.Arena or "Cliffwood"
	if table.find(Config.Arenas.Order, name) then
		return name
	end
	return nil -- the map isn't built yet: StartTeamRun keeps the lobby's arena
end

local function isTerminal(code: string?): boolean
	return code == nil or table.find(E.RetryCodes, code) == nil
end

-- Waits (bounded) for the player's save to load: the run reads it.
local function waitForProfile(player: Player): boolean
	local deadline = os.clock() + E.ProfileWaitSeconds
	while player.Parent and os.clock() < deadline do
		if ctx.DataService.GetData(player) then
			return true
		end
		task.wait(0.25)
	end
	return player.Parent ~= nil and ctx.DataService.GetData(player) ~= nil
end

-- ResolvePlayer with bounded retries for transient failures (it is idempotent per player).
local function resolve(player: Player): AdmissionResult
	local adm = admission :: Admission
	local last: AdmissionResult = { ok = false, errorCode = "NO_ATTEMPT", message = "Couldn't join the match." }
	for attempt = 1, #E.ResolveRetryDelays + 1 do
		local ok, result = pcall(adm.ResolvePlayer, player)
		if ok and type(result) == "table" then
			last = result
			if result.ok then
				return result
			end
			if isTerminal(result.errorCode) then
				return result
			end
		else
			last = { ok = false, errorCode = "ADMISSION_ERROR", message = "Couldn't reach the match service." }
		end
		if attempt > (E.RetryAttempts or 2) then
			break
		end
		local delay = E.ResolveRetryDelays[attempt]
		if not delay or not player.Parent then
			break
		end
		task.wait(delay)
	end
	return last
end

-- A context is usable only for this very player with a class the run knows.
local function validContext(player: Player, c: PlayerRunContext?): boolean
	if type(c) ~= "table" then
		return false
	end
	return c.userId == player.UserId and type(c.matchId) == "string" and type(c.classId) == "string"
		and type(c.expectedUserIds) == "table" and c.schemaVersion == Types.SchemaVersion
end

-- Shows the reason, then sends the player home (bounded retries; last resort a kick with
-- the reason so nobody is stuck on a dead match server).
local function rejectAndReturn(player: Player, message: string?)
	setEntry(player, "Rejected", message or "This match can't be joined.")
	task.delay(E.RejectShowSeconds, function()
		if not player.Parent then
			return
		end
		for attempt = 1, E.ReturnAttempts do
			local ok, results = pcall((admission :: Admission).ReturnToLobby, { player })
			if ok and type(results) == "table" and results[1] and results[1].ok then
				return
			end
			task.wait(2 * attempt)
			if not player.Parent then
				return
			end
		end
		player:Kick(message or "This match can't be joined. Please rejoin SWARM.")
	end)
end

local function startRun()
	local list = {}
	for _, p in ipairs(waiting) do
		if p.Parent and contexts[p] then
			table.insert(list, p)
		end
	end
	table.clear(waiting)
	if #list == 0 then
		return
	end
	for _, p in ipairs(list) do
		setEntry(p, "Starting", "Here we go!")
	end
	local ok = ctx.RunManager.StartTeamRun(list, modeFor(#list), runArena(), list[1])
	if ok then
		runStarted = true
		for _, p in ipairs(list) do
			setEntry(p, "InRun", nil)
		end
	else
		for _, p in ipairs(list) do
			rejectAndReturn(p, "The run couldn't start. Taking you back to camp.")
		end
	end
end

-- Match role: one arriving player.
local function admit(player: Player)
	if resolving[player] or contexts[player] then
		return
	end
	resolving[player] = true
	setEntry(player, "Admitting", "Joining your team...")
	if not waitForProfile(player) then
		resolving[player] = nil
		if player.Parent then
			rejectAndReturn(player, "Your save didn't load in time. Taking you back to camp.")
		end
		return
	end
	local result = resolve(player)
	resolving[player] = nil
	if not player.Parent then
		return
	end
	local c = result.context
	if not result.ok or not c or not validContext(player, c) then
		rejectAndReturn(player, result.message)
		return
	end
	local b = barrier :: ArrivalBarrier.Barrier
	local decision = b:Arrive(c.matchId, player.UserId, c.expectedUserIds, os.clock())
	if decision == "reject" then
		rejectAndReturn(player, "This match has already started without you.")
		return
	elseif decision == "duplicate" then
		return
	end
	contexts[player] = c
	ctx.RunManager.SetAdmittedClass(player, c.classId)
	if decision == "late" then
		if ctx.RunManager.AddLatePlayer(player) then
			setEntry(player, "InRun", nil)
		else
			contexts[player] = nil
			rejectAndReturn(player, "Your team's run is full or over.")
		end
		return
	end
	table.insert(waiting, player)
	setEntry(player, "Waiting", "Waiting for your team...")
end

local function step()
	local b = barrier
	if not b then
		return
	end
	local now = os.clock()
	if not runStarted and b:ShouldStart(now) then
		startRun()
		return
	end
	if not runStarted then
		local left = math.ceil(b:WaitLeft(now))
		for _, p in ipairs(waiting) do
			if p.Parent and p:GetAttribute("SwarmV2EntryWait") ~= left then
				p:SetAttribute("SwarmV2EntryWait", left)
			end
		end
	end
end

------------------------------------------------------------------------------------------
-- Public API
------------------------------------------------------------------------------------------

--[[
	"local" role only: the lobby froze the roster and wrote its local ticket; resolve every
	player through MatchAdmission exactly like a match server and start the run here.
	Yields (bounded). False when no run starts (the lobby releases its queue).
]]
function RunEntry.BeginLocalMatch(matchId: string, players: { Player }): boolean
	if role ~= "local" or not admission or not ctx then
		return false
	end
	if type(matchId) ~= "string" or type(players) ~= "table" then
		return false
	end
	local list = {}
	for _, p in ipairs(players) do
		if typeof(p) == "Instance" and p:IsA("Player") and p.Parent and waitForProfile(p) then
			local result = resolve(p)
			local c = result.context
			if result.ok and c and validContext(p, c) and c.matchId == matchId then
				contexts[p] = c
				ctx.RunManager.SetAdmittedClass(p, c.classId)
				table.insert(list, p)
			else
				ctx.RunManager.Notify(p, result.message or "Couldn't join the match.", Color3.fromRGB(255, 200, 120))
			end
		end
	end
	if #list == 0 then
		return false
	end
	local ok = ctx.RunManager.StartTeamRun(list, modeFor(#list), runArena(), list[1])
	if not ok then
		for _, p in ipairs(list) do
			contexts[p] = nil
			ctx.RunManager.SetAdmittedClass(p, nil)
		end
	end
	return ok
end

-- The admitted context for a player in this run (or nil).
function RunEntry.Context(player: Player): PlayerRunContext?
	return contexts[player]
end

function RunEntry.Role(): string
	return role
end

-- Tests / offline preview only: replace the admission provider (DevAdmission).
function RunEntry._SetAdmission(provider: Admission)
	admission = provider
	local ok, r = pcall(provider.ServerRole)
	role = ok and type(r) == "string" and r or "local"
end

function RunEntry.Init(c: any, provider: Admission?)
	ctx = c
	if provider then
		RunEntry._SetAdmission(provider)
	else
		local SwarmV2Server = script.Parent.Parent
		RunEntry._SetAdmission(require(SwarmV2Server:WaitForChild("MatchAdmission")) :: any)
		local LobbyConfig = require(SwarmV2Shared:WaitForChild("Lobby"):WaitForChild("LobbyConfig")) :: any
		if role == "match" and LobbyConfig.Enabled == false then
			-- the SwarmV2 lobby is switched off: reserved servers come from the old lobby's
			-- RunServers trip, which runs them itself (no admission, no barrier)
			role = "legacy"
		end
	end

	-- after the run: home through MatchAdmission (rewards are already committed)
	if role == "match" or role == "local" then
		ctx.RunManager.OnReturnHome = function(player: Player, _how: string)
			contexts[player] = nil
			if role == "local" and workspace:GetAttribute("SwarmV2Lobby") ~= true then
				return -- no SwarmV2 lobby on this server: the old lobby takes them back
			end
			task.spawn(function()
				local ok, results = pcall((admission :: Admission).ReturnToLobby, { player })
				if not (ok and type(results) == "table" and results[1] and results[1].ok) and player.Parent then
					ctx.RunManager.Notify(player, "Couldn't get back to camp yet. Trying again...", Color3.fromRGB(255, 200, 120))
					task.wait(3)
					if player.Parent then
						pcall((admission :: Admission).ReturnToLobby, { player })
					end
				end
			end)
		end
	end

	if role == "match" then
		-- never a default avatar or the old lobby hero on a match server
		ctx.RunManager.SetLobbySpawnSuppressed(true)
		barrier = ArrivalBarrier.new(E.GroupWaitSeconds, E.LateGraceSeconds)
		Players.PlayerAdded:Connect(function(p)
			task.spawn(admit, p)
		end)
		for _, p in ipairs(Players:GetPlayers()) do
			task.spawn(admit, p)
		end
		Players.PlayerRemoving:Connect(function(p)
			contexts[p] = nil
			resolving[p] = nil
			local i = table.find(waiting, p)
			if i then
				table.remove(waiting, i)
			end
		end)
		RunService.Heartbeat:Connect(step)
	elseif workspace:GetAttribute("SwarmV2Lobby") == true then
		-- the new basecamp owns lobby avatars on this server
		ctx.RunManager.SetLobbySpawnSuppressed(true)
	end
end

return RunEntry
