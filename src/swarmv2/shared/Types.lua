--!strict
--[[
	SwarmV2/Types.lua  (ReplicatedStorage.SwarmV2.Types)
	FROZEN shared contract between the lobby track (Chat 1) and the gameplay track (Chat 2).
	See docs/redesign/OWNERSHIP.md. Neither track changes these shapes on its own; a change
	needs both tracks and the owner's OK.

	Canonical class ids (immutable): "ruckus", "toastmaster", "captain_croak", "granny_boom".
]]

export type ClassId = string

-- What MatchAdmission.ResolvePlayer hands the run server for one admitted player.
export type PlayerRunContext = {
	schemaVersion: number, -- 1
	matchId: string, -- opaque, server-issued
	userId: number, -- the joining player's own UserId
	classId: ClassId, -- canonical, validated against ownership
	expectedUserIds: { number }, -- frozen admitted roster
	lobbyPlaceId: number, -- configured return place
}

export type AdmissionResult = {
	ok: boolean,
	context: PlayerRunContext?, -- set when ok
	errorCode: string?, -- set when not ok
	message: string?, -- safe text the player may see
}

export type ReturnResult = {
	userId: number,
	ok: boolean,
	errorCode: string?,
	message: string?,
}

-- Server-only match ticket (MemoryStore, keyed by matchId, ~180 s TTL). Never replicated.
export type MatchTicket = {
	schemaVersion: number, -- 1
	matchId: string,
	targetMatchPlaceId: number,
	reservedPrivateServerId: string,
	createdAt: number,
	expiresAt: number,
	expectedUserIds: { number },
	classesByUserId: { [string]: ClassId }, -- keys are tostring(userId)
	lobbyPlaceId: number,
	-- optional: the party that queued together (leader + members, all in expectedUserIds); the
	-- return trip uses it to put them back into one party (Lobby/PartyReturn)
	party: { leader: number, members: { number } }?,
}

-- The only TeleportData a client can see: a lookup hint, never proof of anything.
export type TeleportHint = {
	schemaVersion: number, -- 1
	matchId: string,
}

return {
	SchemaVersion = 1,
	ClassIds = { "ruckus", "toastmaster", "captain_croak", "granny_boom" },
}
