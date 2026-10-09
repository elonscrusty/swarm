--!strict
--[[
	SwarmV2/Lobby/PartyReturn.lua  (ServerScriptService.SwarmV2.Lobby.PartyReturn)
	OWNER: lobby track. Puts a party back together after a run (docs/redesign/PATCHES_lobby.md L6).

	Where the party comes from: the lobby writes it into the match ticket (`party`, validated by
	MatchAdmission.CleanParty). The run side's ReturnToLobby:
	  live   writes a short record "p/<matchId>" (TicketStore.WriteParty) and sends TeleportData
	         { SwarmV2Return = { schemaVersion, matchId } }: only a lookup hint.
	  local  the players come back on this server; Arrive is called directly.
	On the lobby server Arrive(player, matchId, party) runs for each arriving player. The party is
	re-created (PartyService.Regroup, "as before": automatic, no prompt) only for players who are
	listed in the stored record AND actually present, once the leader is present too (the leader
	arriving later pulls everyone already waiting; 60 s apart at most). A forged hint can only name a
	record that does not list the forger, so it changes nothing. Nobody is invited from the client.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local LobbyConfig = require(ReplicatedStorage:WaitForChild("SwarmV2"):WaitForChild("Lobby"):WaitForChild("LobbyConfig"))
local TicketStore = require(script.Parent:WaitForChild("TicketStore"))

local PartyReturn = {}

type Party = { leader: number, members: { number } }

local deps = {
	-- (leader, members): put these present players into the leader's party
	Regroup = nil :: ((Player, { Player }) -> ())?,
	PresentPlayer = function(userId: number): Player?
		return Players:GetPlayerByUserId(userId)
	end,
}

function PartyReturn._SetDeps(overrides: { [string]: any })
	for k, v in pairs(overrides) do
		(deps :: any)[k] = v
	end
end

local waiting: { [string]: { [number]: Player } } = {} -- matchId → arrived members

local function validParty(raw: any): Party?
	if type(raw) ~= "table" or type(raw.leader) ~= "number" or type(raw.members) ~= "table" then
		return nil
	end
	local members: { number } = {}
	for i = 1, LobbyConfig.MaxPlayers do
		local id = raw.members[i]
		if type(id) == "number" and id == id and not table.find(members, id) then
			table.insert(members, id)
		end
	end
	if not table.find(members, raw.leader) or #members < 2 then
		return nil
	end
	return { leader = raw.leader, members = members }
end

-- Run side (match server): remember the party for the way home. True when a record was written.
function PartyReturn.Record(kind: string, matchId: string, party: any): boolean
	local clean = validParty(party)
	if not clean then
		return false
	end
	return TicketStore.WriteParty(kind, matchId, clean :: any, LobbyConfig.PartyReturnTTLSeconds)
end

-- Lobby side: `player` arrived (or came back locally) from `matchId`'s run. `party` is the trusted
-- record (nil: it is read from the store). Returns the number of members regrouped now.
function PartyReturn.Arrive(player: Player, matchId: string, partyOrNil: any, kind: string?): number
	local party = validParty(partyOrNil) or validParty(TicketStore.ReadParty(kind or "live", matchId))
	if not party or not table.find(party.members, player.UserId) or player.Parent ~= Players then
		return 0
	end
	local here = waiting[matchId]
	if not here then
		here = {}
		waiting[matchId] = here
		task.delay(LobbyConfig.PartyReturnGraceSeconds, function()
			if waiting[matchId] == here then
				waiting[matchId] = nil
			end
		end)
	end
	(here :: any)[player.UserId] = player
	local leader = (here :: any)[party.leader]
	if not leader or leader.Parent ~= Players or not deps.Regroup then
		return 0 -- the leader arrives later: their arrival pulls the members in
	end
	local members = {}
	for _, id in ipairs(party.members) do
		local p = (here :: any)[id]
		if id ~= party.leader and p and p.Parent == Players then
			table.insert(members, p)
		end
	end
	if #members > 0 then
		deps.Regroup(leader, members)
	end
	return #members
end

return PartyReturn
