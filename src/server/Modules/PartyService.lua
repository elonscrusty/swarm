--[[
	PartyService.lua  (server only)
	Parties of friends who want to play the same run (lobby PARTY screen, MenuParty).

	Same server:
	  Invite   a player on this server (only the leader of a party, or someone not in one);
	           the target gets PartyInvite (an ACCEPT / DECLINE card) that expires after
	           Config.Party.InviteSeconds. One open invite per pair, a short re-invite
	           cooldown and a cap on open invites per sender.
	  Accept   joins the inviter's party (made on the spot with the inviter as leader),
	           leaving any old party; refused when the party is full.
	  Decline, Leave, Kick (leader only). When the leader leaves, the next member leads;
	           a party of one closes.
	  Size     at most the largest lobby mode (Config.Modes.Order) and Config.Run.MaxPlayers.
	READY: each member toggles READY ("Ready", PartyState Members[i].Ready); the leader's
	start only goes when every member is ready (StartBlocked: "Waiting for N to ready up",
	a nudge toast to the others). READY clears when someone joins / leaves and when a run
	starts or ends (SwarmState Phase).
	RunManager asks StartBlocked (only the leader starts, everyone ready) and MembersOf (the
	leader's start pulls the members into that run, up to the mode's size; everyone else
	keeps the normal countdown JOIN).

	Other servers (live game only, never in Studio):
	  PartyFollow (friendUserId)  JOIN a friend's server: friendship and the friend's place
	           are checked here, then TeleportAsync with TeleportOptions.ServerInstanceId and
	           TeleportData { PartyInviter }. Failures (full server, not in this game) toast.
	  Arrival  a player who came through that teleport, a Roblox game invite (LaunchData
	           "party:<userId>", MenuParty's ExperienceInviteOptions) or by following a friend
	           (Player.FollowUserId) joins the inviter's party when the inviter is on this
	           server and they are friends (join data can be forged, friendship cannot).
	  Run servers (RunServers): a party plays its run on a private reserved server; JOIN
	           can't follow anyone there (Roblox refuses the teleport: a toast says so).
	           Coming back, party mates who go home together land on one lobby server with
	           TeleportData { SwarmReturn = { Party = { Leader, Members } } } and the party
	           re-forms when BOTH sides agree: the leader's own return data lists the member
	           and the member's names that leader (one forged side can't pull anyone in).

	Quick lines (Config.Features.PartyQuickLines, docs/next/PARTY_QUICK_LINES.md): ("Say",
	lineIndex) through the Party remote. FIXED text only: the client sends an index into
	Config.PartyQuickLines.Lines, never text, so there is nothing to filter. The index is
	validated, the sender must be in a party of two or more, and a player may say one line
	per MinGap seconds and PerMinute per minute; the line goes (PartySay, index only) to
	the sender's own party members and nobody else.

	Every client request comes through Remotes.Listen (rate limited, pcall'd) and is
	validated: ids must be players on this server, actions must make sense for the sender.
	Player attributes PartyId (0 = none) and PartyLeader tell every client who is grouped
	(the PARTY screen's server list). Names shown are Roblox display names only.
]]

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local TeleportService = game:GetService("TeleportService")

local Config = require(game:GetService("ReplicatedStorage").Shared.Config)
local Remotes = require(game:GetService("ReplicatedStorage").Shared.Remotes)

local PartyService = {}

type Party = { Id: number, Leader: Player, Members: { Player }, Ready: { [Player]: boolean } }

local ctx
local nextId = 0
local partyOf: { [Player]: Party } = {}
-- invites[invitee][inviter] = expiry (os.clock)
local invites: { [Player]: { [Player]: number } } = {}
-- lastInvite[inviter][targetUserId] = os.clock of the last invite sent
local lastInvite: { [Player]: { [number]: number } } = {}
local followAt: { [Player]: number } = {}

local GOOD = Color3.fromRGB(120, 255, 160)
local WARN = Color3.fromRGB(255, 200, 120)
local BAD = Color3.fromRGB(255, 120, 120)

local function cfg()
	return Config.Party
end

-- The biggest party that can play together: the largest lobby mode, capped by the run size.
function PartyService.MaxSize(): number
	local biggest = 1
	for _, id in ipairs(Config.Modes.Order) do
		local def = (Config.Modes :: any)[id]
		if def and def.MaxPlayers > biggest then
			biggest = def.MaxPlayers
		end
	end
	return math.min(Config.Run.MaxPlayers, biggest)
end

local function notify(player: Player, text: string, color: Color3?)
	if player.Parent then
		-- lane routing as RunManager.Notify (UI_STATE_CONTRACT section 3): an Info notice
		Remotes.FireClient("Notify", player, { Text = text, Color = color, Id = "text:" .. string.lower(text), Lane = "Notice", Class = "Info" })
	end
end

local function playerById(userId: any): Player?
	if type(userId) ~= "number" or userId ~= userId or userId <= 0 then
		return nil
	end
	for _, p in ipairs(Players:GetPlayers()) do
		if p.UserId == userId then
			return p
		end
	end
	return nil
end

local function isFriends(player: Player, userId: number): boolean
	local ok, res = pcall(function()
		return (player :: any):IsFriendsWithAsync(userId)
	end)
	if not ok then
		ok, res = pcall(function()
			return (player :: any):IsFriendsWith(userId) -- older engines / the preview mock
		end)
	end
	return ok and res == true
end

-- Open, unexpired invites to `player`: { {inviter, secondsLeft} }, oldest first.
local function openInvites(player: Player): { { any } }
	local list = {}
	local now = os.clock()
	local mine = invites[player]
	if mine then
		for from, expires in pairs(mine) do
			if expires <= now or not from.Parent then
				mine[from] = nil
			else
				table.insert(list, { from, expires - now })
			end
		end
	end
	table.sort(list, function(a, b)
		return a[2] < b[2]
	end)
	return list
end

-- UserIds this player has open invites out to.
local function sentInvites(player: Player): { number }
	local list = {}
	local now = os.clock()
	for target, map in pairs(invites) do
		local expires = map[player]
		if expires and expires > now and target.Parent then
			table.insert(list, target.UserId)
		end
	end
	return list
end

local function push(player: Player)
	if not player.Parent then
		return
	end
	local party = partyOf[player]
	local members = {}
	if party then
		for _, m in ipairs(party.Members) do
			table.insert(members, { UserId = m.UserId, Name = m.DisplayName, Ready = party.Ready[m] == true })
		end
	end
	local incoming = {}
	for _, inv in ipairs(openInvites(player)) do
		table.insert(incoming, { FromId = inv[1].UserId, FromName = inv[1].DisplayName, Seconds = math.ceil(inv[2]) })
	end
	player:SetAttribute("PartyId", party and party.Id or 0)
	player:SetAttribute("PartyLeader", party ~= nil and party.Leader == player)
	Remotes.FireClient("PartyState", player, {
		LeaderId = party and party.Leader.UserId or 0,
		Members = members,
		Max = PartyService.MaxSize(),
		Invites = incoming,
		Sent = sentInvites(player),
	})
end

local function pushParty(party: Party)
	for _, m in ipairs(party.Members) do
		push(m)
	end
end

local function tellParty(party: Party, text: string, except: Player?)
	for _, m in ipairs(party.Members) do
		if m ~= except then
			notify(m, text, GOOD)
		end
	end
end

-- Takes `player` out of their party (leader passes on; a party of one closes).
local function removeMember(player: Player, why: string)
	local party = partyOf[player]
	if not party then
		return
	end
	partyOf[player] = nil
	table.clear(party.Ready) -- the line-up changed: everyone readies again
	local i = table.find(party.Members, player)
	if i then
		table.remove(party.Members, i)
	end
	if #party.Members <= 1 then
		for _, m in ipairs(party.Members) do
			partyOf[m] = nil
			notify(m, "Your party closed: " .. player.DisplayName .. " " .. why .. ".", WARN)
			push(m)
		end
		table.clear(party.Members)
	else
		local wasLeader = party.Leader == player
		if wasLeader then
			party.Leader = party.Members[1]
		end
		for _, m in ipairs(party.Members) do
			notify(m, player.DisplayName .. " " .. why .. (wasLeader and (" · " .. party.Leader.DisplayName .. " leads now.") or "."), WARN)
		end
		pushParty(party)
	end
	push(player)
end

-- Puts `player` into `inviter`'s party (a new one when the inviter has none). Returns why not.
local function joinParty(player: Player, inviter: Player): string?
	if player == inviter or not inviter.Parent or not player.Parent then
		return "gone"
	end
	local party = partyOf[inviter]
	if party and partyOf[player] == party then
		return "already"
	end
	local size = party and #party.Members or 1
	if size >= PartyService.MaxSize() then
		return "full"
	end
	removeMember(player, "left the party")
	if not party then
		nextId += 1
		local fresh: Party = { Id = nextId, Leader = inviter, Members = { inviter }, Ready = {} }
		party = fresh
		partyOf[inviter] = fresh
	end
	local p = party :: Party
	table.insert(p.Members, player)
	partyOf[player] = p
	table.clear(p.Ready)
	-- invites to this player are settled; the inviter's open invite to them too
	if invites[player] then
		table.clear(invites[player])
	end
	tellParty(p, player.DisplayName .. " joined the party!", player)
	notify(player, "You joined " .. p.Leader.DisplayName .. "'s party.", GOOD)
	pushParty(p)
	return nil
end

------------------------------------------------------------------------------------------
-- Actions (remote "Party")
------------------------------------------------------------------------------------------

local function invite(from: Player, userId: any)
	local target = playerById(userId)
	if not target or target == from then
		return
	end
	local party = partyOf[from]
	if party and party.Leader ~= from then
		notify(from, "Only the party leader can invite.", WARN)
		return
	end
	if party and partyOf[target] == party then
		return
	end
	if party and #party.Members >= PartyService.MaxSize() then
		notify(from, "Your party is full.", WARN)
		return
	end
	local now = os.clock()
	local sent = lastInvite[from]
	if not sent then
		sent = {}
		lastInvite[from] = sent
	end
	local map = invites[target]
	if map and map[from] and map[from] > now then
		return -- already open
	end
	if sent[target.UserId] and now - sent[target.UserId] < cfg().ReinviteSeconds then
		notify(from, "Wait a moment before inviting " .. target.DisplayName .. " again.", WARN)
		return
	end
	if #sentInvites(from) >= cfg().MaxPendingInvites then
		notify(from, "Too many open invites: wait for answers.", WARN)
		return
	end
	if not map then
		map = {}
		invites[target] = map
	end
	map[from] = now + cfg().InviteSeconds
	sent[target.UserId] = now
	Remotes.FireClient("PartyInvite", target, { FromId = from.UserId, FromName = from.DisplayName, Seconds = cfg().InviteSeconds })
	notify(from, "Invite sent to " .. target.DisplayName .. ".", GOOD)
	push(from)
	push(target)
end

local function accept(player: Player, userId: any)
	local from = playerById(userId)
	local map = invites[player]
	local expires = from and map and map[from]
	if not from or not map or not expires then
		push(player)
		return
	end
	map[from] = nil
	if expires <= os.clock() then
		notify(player, "That invite has expired.", WARN)
		push(player)
		push(from)
		return
	end
	local theirs = partyOf[from]
	if theirs and theirs.Leader ~= from then
		-- the inviter joined someone else's party since: their invite can't pull anyone in
		notify(player, from.DisplayName .. "'s invite is no longer valid.", WARN)
		push(player)
		push(from)
		return
	end
	local why = joinParty(player, from)
	if why == "full" then
		notify(player, from.DisplayName .. "'s party is full.", WARN)
	end
	push(player)
	push(from)
end

local function decline(player: Player, userId: any)
	local from = playerById(userId)
	local map = invites[player]
	if not from or not map or not map[from] then
		return
	end
	map[from] = nil
	notify(from, player.DisplayName .. " declined your invite.", WARN)
	push(player)
	push(from)
end

local function kick(leader: Player, userId: any)
	local party = partyOf[leader]
	local target = playerById(userId)
	if not party or party.Leader ~= leader or not target or target == leader or partyOf[target] ~= party then
		return
	end
	notify(target, "You were removed from the party.", WARN)
	removeMember(target, "was removed")
end

------------------------------------------------------------------------------------------
-- Quick lines (PartyQuickLines)
------------------------------------------------------------------------------------------

-- say[player] = { Last = os.clock() of the last line, Times = { os.clock() of lines in the last 60 s } }
local say: { [Player]: { Last: number, Times: { number } } } = {}

-- Why `index` from `player` can't go out now ("feature" | "index" | "party" | "gap" | "minute"),
-- or nil. Records nothing (PartyService.Say does, when it sends).
function PartyService.CheckSay(player: Player, index: any): string?
	if not Config.FeatureOn("PartyQuickLines") then
		return "feature"
	end
	local lines = Config.PartyQuickLines.Lines
	if type(index) ~= "number" or index ~= index or index < 1 or index > #lines or index % 1 ~= 0 then
		return "index"
	end
	local party = partyOf[player]
	if not party or #party.Members < 2 then
		return "party"
	end
	local now = os.clock()
	local rec = say[player]
	if rec then
		if now - rec.Last < Config.PartyQuickLines.MinGap then
			return "gap"
		end
		local recent = 0
		for _, t in ipairs(rec.Times) do
			if now - t < 60 then
				recent += 1
			end
		end
		if recent >= Config.PartyQuickLines.PerMinute then
			return "minute"
		end
	end
	return nil
end

-- A member's quick line: validated, rate limited, delivered to the sender's party only.
-- Returns true when it was sent.
function PartyService.Say(player: Player, index: any): boolean
	local why = PartyService.CheckSay(player, index)
	if why then
		if why == "minute" then
			notify(player, "Easy there: too many quick lines. Try again in a moment.", WARN)
		end
		return false
	end
	local party = partyOf[player] :: Party
	local now = os.clock()
	local rec = say[player]
	if not rec then
		rec = { Last = now, Times = {} }
		say[player] = rec
	end
	rec.Last = now
	local kept = {}
	for _, t in ipairs(rec.Times) do
		if now - t < 60 then
			table.insert(kept, t)
		end
	end
	table.insert(kept, now)
	rec.Times = kept
	for _, m in ipairs(party.Members) do
		if m.Parent then
			Remotes.FireClient("PartySay", m, { FromId = player.UserId, FromName = player.DisplayName, Index = index })
		end
	end
	return true
end

local ACTIONS: { [string]: (Player, any) -> () } = {
	Invite = invite,
	Accept = accept,
	Decline = decline,
	Kick = kick,
	Leave = function(player)
		if partyOf[player] then
			notify(player, "You left the party.", WARN)
			removeMember(player, "left the party")
		end
	end,
	-- (on: boolean) a member's READY toggle (the leader is ready by starting)
	Ready = function(player, on)
		local party = partyOf[player]
		if not party or type(on) ~= "boolean" or party.Leader == player then
			return
		end
		if (party.Ready[player] == true) ~= on then
			party.Ready[player] = on or nil
			pushParty(party)
		end
	end,
	-- (lineIndex: number) a fixed quick line for the party (PartyQuickLines)
	Say = function(player, index)
		PartyService.Say(player, index)
	end,
	Sync = function(player)
		push(player)
	end,
}

------------------------------------------------------------------------------------------
-- Friends on other servers
------------------------------------------------------------------------------------------

local function follow(player: Player, friendId: any)
	if type(friendId) ~= "number" or friendId ~= friendId or friendId <= 0 or friendId == player.UserId then
		return
	end
	local now = os.clock()
	if now - (followAt[player] or -math.huge) < cfg().FollowCooldown then
		return
	end
	followAt[player] = now
	if ctx.RunManager and ctx.RunManager.IsParticipant(player) then
		notify(player, "Finish your run first.", WARN)
		return
	end
	local here = playerById(friendId)
	if here then
		notify(player, here.DisplayName .. " is on this server: invite them to your party.", WARN)
		return
	end
	if RunService:IsStudio() then
		notify(player, "Joining a friend's server works in the live game only.", WARN)
		return
	end
	if not isFriends(player, friendId) then
		notify(player, "You can only join friends.", BAD)
		return
	end
	local ok, isHere, _err, placeId, jobId = pcall(function()
		return TeleportService:GetPlayerPlaceInstanceAsync(friendId)
	end)
	if not ok or isHere or placeId ~= game.PlaceId or type(jobId) ~= "string" or jobId == "" or jobId == game.JobId then
		notify(player, "Couldn't find your friend's SWARM server. Try again soon.", WARN)
		return
	end
	notify(player, "Joining your friend's server...", GOOD)
	local sent = pcall(function()
		local options = Instance.new("TeleportOptions")
		options.ServerInstanceId = jobId
		options:SetTeleportData({ PartyInviter = friendId })
		TeleportService:TeleportAsync(game.PlaceId, { player }, options)
	end)
	if not sent then
		notify(player, "Couldn't join that server. It may be full, or your friend is in a private run.", BAD)
	end
end

-- Back from a private run server: { [Player] = { Leader = userId, Members = { [userId] = true } } }
local returning: { [Player]: { Leader: number, Members: { [number]: boolean } } } = {}

-- Re-forms a party that went home from a run server together (see the header).
local function reformAfterRun(player: Player)
	local rs = ctx.RunServers
	local back = rs and rs.ReturnData(player)
	local party = back and back.Party
	if not party then
		return
	end
	local set = {}
	for _, id in ipairs(party.Members) do
		set[id] = true
	end
	returning[player] = { Leader = party.Leader, Members = set }
	task.delay(60, function()
		returning[player] = nil
	end)
	local leader = playerById(party.Leader)
	local mine = leader and returning[leader]
	if not leader or not mine or mine.Leader ~= leader.UserId then
		return -- the leader arrives later: their arrival pulls the members in
	end
	if player == leader then
		for _, other in ipairs(Players:GetPlayers()) do
			local theirs = returning[other]
			if other ~= leader and theirs and theirs.Leader == leader.UserId and mine.Members[other.UserId] then
				joinParty(other, leader)
			end
		end
	elseif mine.Members[player.UserId] then
		joinParty(player, leader)
	end
end

-- A player who came through JOIN, a game invite or by following a friend: the inviter's id.
local function arrivalInviters(player: Player): { number }
	local ids = {}
	local ok, data = pcall(function()
		return player:GetJoinData()
	end)
	if ok and type(data) == "table" then
		local td = data.TeleportData
		if type(td) == "table" and type((td :: any).PartyInviter) == "number" then
			table.insert(ids, (td :: any).PartyInviter)
		end
		local launch = data.LaunchData
		local id = type(launch) == "string" and tonumber(string.match(launch, "^party:(%d+)$")) or nil
		if id then
			table.insert(ids, id)
		end
	end
	local okF, followId = pcall(function()
		return player.FollowUserId
	end)
	if okF and type(followId) == "number" and followId > 0 then
		table.insert(ids, followId)
	end
	return ids
end

local function onArrival(player: Player)
	reformAfterRun(player)
	for _, id in ipairs(arrivalInviters(player)) do
		local inviter = playerById(id)
		if inviter and inviter ~= player and isFriends(player, id) then
			local why = joinParty(player, inviter)
			if why == "full" then
				notify(player, inviter.DisplayName .. "'s party is full: join a run's countdown instead.", WARN)
			end
			return
		end
	end
end

------------------------------------------------------------------------------------------
-- RunManager hooks
------------------------------------------------------------------------------------------

-- False for a party member who is not the leader (the leader starts the party's runs).
-- Why `player` can't start a run now (a member, or members not ready: they get a nudge),
-- or nil. RunManager shows the text to the starter.
function PartyService.StartBlocked(player: Player): string?
	local party = partyOf[player]
	if not party then
		return nil
	end
	if party.Leader ~= player then
		return "Your party leader starts the runs (or leave the party)."
	end
	local waiting = 0
	for _, m in ipairs(party.Members) do
		if m ~= player and m.Parent and not party.Ready[m] then
			waiting += 1
			notify(m, player.DisplayName .. " wants to start: tap READY!", WARN)
		end
	end
	if waiting > 0 then
		return string.format("Waiting for %d to ready up.", waiting)
	end
	return nil
end

-- Clears every party's READY (a run started or ended: ready again for the next one).
local function resetAllReady()
	local seen: { [Party]: boolean } = {}
	for _, party in pairs(partyOf) do
		if not seen[party] then
			seen[party] = true
			if next(party.Ready) then
				table.clear(party.Ready)
				pushParty(party)
			end
		end
	end
end

function PartyService.CanStart(player: Player): boolean
	local party = partyOf[player]
	return party == nil or party.Leader == player
end

-- The other members of `player`'s party when `player` leads it (join order), else {}.
function PartyService.MembersOf(player: Player): { Player }
	local party = partyOf[player]
	local list = {}
	if party and party.Leader == player then
		for _, m in ipairs(party.Members) do
			if m ~= player and m.Parent then
				table.insert(list, m)
			end
		end
	end
	return list
end

function PartyService.PartyOf(player: Player): Party?
	return partyOf[player]
end

local function onRemoving(player: Player)
	returning[player] = nil
	removeMember(player, "left the game")
	invites[player] = nil
	for target, map in pairs(invites) do
		if map[player] then
			map[player] = nil
			push(target)
		end
	end
	lastInvite[player] = nil
	followAt[player] = nil
	say[player] = nil
end

------------------------------------------------------------------------------------------
-- Lifecycle
------------------------------------------------------------------------------------------

function PartyService.Init(c)
	ctx = c
end

function PartyService.Start()
	if not cfg() or cfg().Enabled == false then
		return
	end
	Remotes.Listen("Party", function(player, action, arg)
		local fn = type(action) == "string" and ACTIONS[action]
		if fn then
			fn(player, arg)
		end
	end, cfg().ActionRate)
	Remotes.Listen("PartyFollow", follow, 1)
	-- READY lasts one start: cleared when a run begins and when it ends
	local state = Remotes.State()
	state:GetAttributeChangedSignal("Phase"):Connect(function()
		local phase = state:GetAttribute("Phase")
		if phase == "Lobby" or phase == "Running" then
			resetAllReady()
		end
	end)
	Players.PlayerRemoving:Connect(onRemoving)
	Players.PlayerAdded:Connect(function(player)
		task.spawn(onArrival, player)
	end)
	pcall(function()
		TeleportService.TeleportInitFailed:Connect(function(player, result)
			if ctx.RunServers and ctx.RunServers.OwnsTeleport(player) then
				return -- a run-server trip: RunServers retries and reports it
			end
			local full = result == Enum.TeleportResult.GameFull
			notify(player, full and "That server is full." or "Couldn't join that server. Try again.", BAD)
		end)
	end)
end

return PartyService
