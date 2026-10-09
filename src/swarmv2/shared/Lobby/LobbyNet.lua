--!strict
--[[
	SwarmV2/Lobby/LobbyNet.lua  (ReplicatedStorage.SwarmV2.Lobby.LobbyNet)
	OWNER: lobby track (Chat 1). The lobby's own RemoteEvents, in
	ReplicatedStorage.SwarmV2Net.Lobby (docs/redesign/OWNERSHIP.md rule "Remotes"). The server
	creates them (Setup) and listens with a per-player rate limit and a pcall (Listen); the
	client waits for them (Get). Nothing here grants anything: every request is checked again
	on the server.

	Client → server
	  ClassAction  ("Select", classId) | ("Buy", classId)
	  QueueAction  ("Join", gateId) | ("Leave") | ("Ready", boolean)
	  LobbySync    () ask for a fresh LobbyState
	  (party actions use the existing "Party" remote of PartyService, plus "Promote")
	Server → client
	  LobbyState   (state: LobbyView) the player's own view, pushed on every change
	  LobbyNotice  (text: string, kind: "good" | "warn" | "bad")
	Gate boards: SwarmV2Net.Lobby.Gates.<gateId> (Configuration) attributes
	  Mode, Label, Count, Capacity, State ("Open" | "Countdown" | "Launching" | "Full"), EndsAt
	  (workspace:GetServerTimeNow() when the countdown ends, 0 = none).
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Players = game:GetService("Players")

export type MemberView = { UserId: number, Name: string, ClassId: string, Ready: boolean, Leader: boolean }
export type QueueView = {
	GateId: string,
	Mode: string, -- "Public" | "Party"
	State: string, -- "Waiting" | "Countdown" | "Committed" | "Teleporting" | "Failed"
	Capacity: number,
	Members: { MemberView },
	EndsAt: number, -- server time the countdown ends, 0 = none
	Message: string?,
}
export type LobbyView = {
	Role: string, -- MatchAdmission.ServerRole()
	Gold: number,
	Owned: { [string]: boolean },
	Selected: string,
	ClassLocked: boolean, -- true while committed / travelling (class frozen)
	Queue: QueueView?,
	PartySize: number,
	IsLeader: boolean,
	-- [stream L1] goal progress of the classes this save does not own yet (class browser)
	Progress: { [string]: { Have: number, Need: number, Stat: string, Parts: { { Stat: string, Have: number, Need: number } }? } }?,
	-- [stream L1] the server's answer to the player's latest ClassAction: N counts up with every answer
	ClassAck: { N: number, Id: string, Action: string, Ok: boolean, Code: string? }?,
}

local LobbyNet = {}

LobbyNet.Events = { "ClassAction", "QueueAction", "LobbySync", "LobbyState", "LobbyNotice" }

local folder: Folder? = nil

local function root(create: boolean): Folder?
	if folder and folder.Parent then
		return folder
	end
	local net = ReplicatedStorage:FindFirstChild("SwarmV2Net")
	if not net then
		if not create then
			net = ReplicatedStorage:WaitForChild("SwarmV2Net")
		else
			-- whoever boots first creates SwarmV2Net (contract addition 5)
			net = Instance.new("Folder")
			net.Name = "SwarmV2Net"
			net.Parent = ReplicatedStorage
		end
	end
	local lobby = (net :: Instance):FindFirstChild("Lobby")
	if not lobby then
		if not create then
			lobby = (net :: Instance):WaitForChild("Lobby")
		else
			local made = Instance.new("Folder")
			made.Name = "Lobby"
			made.Parent = net
			lobby = made
		end
	end
	folder = lobby :: Folder
	return folder
end

-- Server: makes the folder, the events and the gate boards. Safe to call twice.
function LobbyNet.Setup(gateIds: { string })
	assert(RunService:IsServer(), "LobbyNet.Setup is server only")
	local f = root(true) :: Folder
	for _, name in ipairs(LobbyNet.Events) do
		if not f:FindFirstChild(name) then
			local e = Instance.new("RemoteEvent")
			e.Name = name
			e.Parent = f
		end
	end
	local gates = f:FindFirstChild("Gates")
	if not gates then
		local made = Instance.new("Folder")
		made.Name = "Gates"
		made.Parent = f
		gates = made
	end
	for _, id in ipairs(gateIds) do
		if not (gates :: Instance):FindFirstChild(id) then
			local c = Instance.new("Configuration")
			c.Name = id
			c.Parent = gates
		end
	end
end

function LobbyNet.Folder(): Folder
	return root(RunService:IsServer()) :: Folder
end

function LobbyNet.Get(name: string): RemoteEvent
	return LobbyNet.Folder():WaitForChild(name) :: RemoteEvent
end

function LobbyNet.Gate(id: string): Configuration?
	local gates = LobbyNet.Folder():FindFirstChild("Gates")
	return gates and gates:FindFirstChild(id) :: Configuration?
end

-- Per-player token buckets (same pattern as Remotes.Listen).
local buckets: { [Player]: { [string]: { tokens: number, last: number } } } = {}
if RunService:IsServer() then
	Players.PlayerRemoving:Connect(function(p)
		buckets[p] = nil
	end)
end

local function allow(player: Player, name: string, rate: number): boolean
	local mine = buckets[player]
	if not mine then
		mine = {}
		buckets[player] = mine
	end
	local now = os.clock()
	local b = mine[name]
	if not b then
		b = { tokens = rate, last = now }
		mine[name] = b
	end
	b.tokens = math.min(rate, b.tokens + (now - b.last) * rate)
	b.last = now
	if b.tokens < 1 then
		return false
	end
	b.tokens -= 1
	return true
end

-- Server: rate-limited, pcall'd handler for one client → server event.
function LobbyNet.Listen(name: string, rate: number, handler: (Player, ...any) -> ())
	LobbyNet.Get(name).OnServerEvent:Connect(function(player, ...)
		if not allow(player, name, rate) then
			return
		end
		local ok: boolean, err: any = pcall(handler, player, ...)
		if not ok then
			warn(string.format("[SwarmV2 Lobby] %s handler error for %s: %s", name, player.Name, tostring(err)))
		end
	end)
end

return LobbyNet
