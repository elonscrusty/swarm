--!strict
--[[
	SwarmV2/Lobby/LobbyConfig.lua  (ReplicatedStorage.SwarmV2.Lobby.LobbyConfig)
	OWNER: lobby track (Chat 1). Every number of the basecamp, parties, queues and transfers.
	Visible to clients: it holds no secrets (no access codes, no tickets).
	Design notes: docs/redesign/lobby/DESIGN.md.
]]

local LobbyConfig = {}

-- Master switch: the walk-around basecamp replaces the old menu lobby on lobby servers.
LobbyConfig.Enabled = true

-- Live reserved-server transfer. Off (or Studio / unpublished place) = role "local": the
-- lobby hands its match to SwarmV2.Run.RunEntry.BeginLocalMatch on the same server.
LobbyConfig.TransferEnabled = true

-- Basecamp world (workspace.SwarmV2Lobby), far from the old lobby (Config.Lobby.Origin,
-- x = 1200) and from every arena (around the origin): ground top surface at Origin.Y.
LobbyConfig.Origin = Vector3.new(0, 0, 4000)
LobbyConfig.Size = 220 -- studs across the walkable floor (the brief: 180-240)
LobbyConfig.FallY = -60 -- an avatar below Origin.Y + FallY is put back at the bonfire

-- Parties and matches: 1..MaxPlayers (capped again by PartyService.MaxSize()).
LobbyConfig.MaxPlayers = 4
LobbyConfig.MinPlayers = 1

-- Gates. "Public" = recruiting: solos and whole parties from this lobby server fill the free
-- slots of one forming match. "Party" = party-only: the leader's own party (or a solo)
-- gets a private queue; nobody else can join it. Order = left to right in the basecamp.
export type GateDef = { Id: string, Mode: string, Label: string, Hint: string }
LobbyConfig.Gates = {
	{ Id = "PublicA", Mode = "Public", Label = "RECRUIT GATE A", Hint = "Anyone here can join. Fills up to 4." },
	{ Id = "Party", Mode = "Party", Label = "PARTY GATE", Hint = "Only your party. Solo players go alone." },
	{ Id = "PublicB", Mode = "Public", Label = "RECRUIT GATE B", Hint = "Anyone here can join. Fills up to 4." },
} :: { GateDef }

LobbyConfig.CountdownSeconds = 10 -- after everyone in the queue is READY
LobbyConfig.PadCooldownSeconds = 1.5 -- a player's pad enter/leave is ignored this soon after their last queue change
LobbyConfig.PadPollSeconds = 0.25 -- how often the server checks who stands on a gate pad

-- Transfer (reserved server of this same place; both place ids = game.PlaceId).
LobbyConfig.TicketTTLSeconds = 180 -- MemoryStore ticket lifetime (admission window)
LobbyConfig.ReserveAttempts = 2 -- ReserveServerAsync tries
LobbyConfig.StoreAttempts = 3 -- MemoryStore read / write tries per call
LobbyConfig.StoreRetryDelay = 0.5 -- seconds, doubled after each failed try
LobbyConfig.TeleportRetries = 2 -- extra TeleportAsync tries for players whose teleport failed
LobbyConfig.TeleportRetryDelays = { 1, 3 } -- seconds before retry 1, retry 2
LobbyConfig.TeleportTimeoutSeconds = 25 -- still here this long after a teleport call: failed
LobbyConfig.PartyReturnTTLSeconds = 300 -- how long a "party went home together" record lives
LobbyConfig.PartyReturnGraceSeconds = 60 -- the leader / members may arrive this far apart
LobbyConfig.ReturnRetries = 2 -- match server: extra tries of the return-to-lobby teleport

-- Destination admission (match server).
LobbyConfig.ProfileWaitSeconds = 20 -- wait at most this long for the arriving player's save
LobbyConfig.ResolveWaitSeconds = 30 -- a second ResolvePlayer call waits at most this long for the first

-- Remote rate limits (calls per second per player).
LobbyConfig.Rates = { Class = 3, Queue = 4, Sync = 2 }

-- [stream L1] Home screen: the first-time guide (opens once for an account that never started a run;
-- reopenable from HOW TO PLAY and Settings) and the loading statuses (docs/redesign/lobby/L1_STATUS.md).
LobbyConfig.Home = {
	Guide = true, -- false: the guide never opens by itself (HOW TO PLAY still reopens it)
	ExplainLoadingAfter = 8, -- seconds until the load card says what is still loading
	OfferRetryAfter = 30, -- seconds until it offers RETRY with a failure message
}

return LobbyConfig
