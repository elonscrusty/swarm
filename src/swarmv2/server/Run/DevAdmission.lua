--!strict
--[[
	SwarmV2/Run/DevAdmission.lua  (ServerScriptService.SwarmV2.Run.DevAdmission)
	DEV / TEST ONLY. A fake admission provider with MatchAdmission's shape, for Lune tests
	and the offline preview. Never required by live code: RunEntry uses it only when a test
	passes it in. It refuses to run in a live, published server.
]]

local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Types = require(ReplicatedStorage:WaitForChild("SwarmV2"):WaitForChild("Types"))

local DevAdmission = {}

local role = "local"
local tickets: { [number]: Types.PlayerRunContext } = {}

local function guard()
	if not RunService:IsStudio() and game.PlaceId ~= 0 then
		error("DevAdmission is test-only and disabled on live servers")
	end
end

-- Test setup: the role to report and one ticket for a whole roster.
function DevAdmission.Setup(newRole: string, matchId: string, classesByUserId: { [number]: string })
	guard()
	role = newRole
	table.clear(tickets)
	local roster = {}
	for id in pairs(classesByUserId) do
		table.insert(roster, id)
	end
	table.sort(roster)
	for id, class in pairs(classesByUserId) do
		tickets[id] = { schemaVersion = Types.SchemaVersion, matchId = matchId, userId = id, classId = class, expectedUserIds = roster, lobbyPlaceId = game.PlaceId }
	end
end

function DevAdmission.ServerRole(): string
	return role
end

function DevAdmission.ResolvePlayer(player: Player): Types.AdmissionResult
	guard()
	local c = tickets[player.UserId]
	if not c then
		return { ok = false, errorCode = "NOT_EXPECTED", message = "You're not on this match's team." }
	end
	return { ok = true, context = c }
end

function DevAdmission.ReturnToLobby(players: { Player }): { Types.ReturnResult }
	local out = {}
	for _, p in ipairs(players) do
		table.insert(out, { userId = p.UserId, ok = true })
	end
	return out
end

return DevAdmission
