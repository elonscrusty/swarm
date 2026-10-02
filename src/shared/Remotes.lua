--[[
	Remotes.lua
	Creates (server) or finds (client) every RemoteEvent in ReplicatedStorage.Remotes,
	plus the "SwarmState" Configuration whose attributes carry global run state.

	Server:  Remotes.Setup() once at boot, then Remotes.Listen(name, handler, rate)
	         Remotes.FireClient / FireAllClients.
	Client:  Remotes.Get(name) (waits for the instance).

	Every client→server remote goes through Listen, which rate-limits per player and
	pcalls the handler so a bad request can never break the server loop. Handlers must
	still validate their arguments: nothing coming from a client is trusted.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Players = game:GetService("Players")

local Config = require(script.Parent.Config)

local Remotes = {}

-- Server → client
Remotes.ServerToClient = {
	"ProjectileBatch", -- buffer of projectile positions, once per sync tick
	"FxBatch", -- table of visual effects, once per flush tick
	"WeaponFx", -- weapon effects that are not projectiles (nova, flame patches, totem pulses, hook chains)
	"Inventory", -- this player's weapons / passives / run counters
	"LevelUpOffer", -- 3 cards + reroll / skip counts
	"LevelUpClose", -- the offer was resolved (auto-pick etc.)
	"ChestOpened", -- chest reward for the chest animation
	"Notify", -- toast / banner text
	"RunResult", -- win / lose stats
	"ProfileSync", -- lobby data: gold, owned, meta levels, stats, settings, passes
	"OpenPanel", -- "Joined" after joining a countdown (old: lobby board prompt → panel name)
	"ReviveOffer", -- died: offer the Revive product for N seconds
	"PortalOffer", -- the stage portal opened: NEXT STAGE / RETURN TO LOBBY panel (or Close / Chosen)
	"StageTravel", -- the group is travelling to the next stage: fade + "Stage N" banner
	"Items", -- this player's run items: { {Id, Count}, ... } (ItemSystem)
	"ItemGained", -- item popup: { Id, Count, Source }
	"LootFeedback", -- answer to LootHold: { Id, State = "Done" | "Cancel", Reason? }
	"AchievementUnlocked", -- { Id, Name, Reward, Icon } (AchievementService): toast
	"DamageNumbers", -- { enemyId, amount, crit (0/1), ... } summed hits (only with the setting on)
	"BugReportResult", -- { Ok, Message } answer to BugReport (BugReportService)
	"BugInboxData", -- DEV inbox: { Kind = "Page", Rows, Next?, Status } | { Kind = "Status", Id, Status, Ok }
	"LeaderboardData", -- { Board, Rows = { {Rank, Name, Value, Me} }, Status, Age, MyRank?, MyBest } (LeaderboardService)
	"PartyState", -- this player's party: { LeaderId, Members = { {UserId, Name, Ready} }, Max, Invites = { {FromId, FromName, Seconds} }, Sent = {userId} } (PartyService)
	"PartyInvite", -- a new invite: { FromId, FromName, Seconds } (PartyService): the ACCEPT / DECLINE card
}

-- Client → server
Remotes.ClientToServer = {
	"LevelUpChoose", -- (index)
	"LevelUpReroll",
	"LevelUpSkip",
	"JoinRun", -- join during the lobby countdown
	"StartRun", -- (mode) lobby SOLO / DUO / TRIO button, or "Daily" (the DAILY card); during a countdown it joins
	"StartNow", -- the countdown's starter skips the rest of the countdown
	"CycleArena", -- (arenaName?) lobby ARENA screen: pick that arena (unlocked), or the next unlocked one
	"DevCommand", -- (command, arg?) Studio / creator only, re-checked on the server (DevTools)
	"ReturnToLobby", -- leave the results screen early
	"AbandonRun", -- pause menu MAIN MENU (confirmed): leave the running run for the lobby menu
	"SelectCharacter", -- (characterId)
	"BuyCharacter", -- (characterId)
	"BuyMeta", -- (upgradeId, levelSeenByClient?) a stale second tap is ignored
	"EquipSkin", -- (characterId, skinId)
	"SetPause", -- (bool) pause menu open / closed
	"SaveSettings", -- ({ Music, Sfx, Shake = 0-1, ReducedEffects, DamageNumbers, Tips = bool }) any subset
	"Tutorial", -- ("Seen", tipId) | ("Skip") | ("Replay") first-run tips (GoldSystem)
	"ReviveDecline", -- close the revive offer early
	"RewardClose", -- (seq) the chest reward reel showed every reward up to seq (ends the reward pause)
	"RequestProfile", -- ask for a ProfileSync
	"PortalChoice", -- ("Next" | "Return") answer to PortalOffer, validated by StageManager
	"LootHold", -- (lootId, holding: boolean) start / stop holding a chest or shrine (LootSystem)
	"EquipCosmetic", -- ("Title" | "Color" | "Ring" | "Frame", id or "") an earned achievement / level-track cosmetic
	"SetCurses", -- ({curseId}) lobby curse pick, at most CurseData.MaxActive (RunModifiers)
	"SetEndless", -- (boolean) lobby ENDLESS switch for SOLO / DUO / TRIO runs (RunModifiers, Config.Endless)
	"BugReport", -- ({ Category, Text, Client }) player bug report, filtered and rate limited (BugReportService)
	"BugInbox", -- ("Page", cursor?) | ("SetStatus", id, status) DEV inbox, server-side allowlist
	"LeaderboardRequest", -- (boardId) a Config.Leaderboards.Order id (LeaderboardService)
	"Party", -- ("Invite" | "Accept" | "Decline" | "Kick", userId) | ("Ready", boolean) | ("Leave") | ("Sync") lobby PARTY screen (PartyService)
	"PartyFollow", -- (friendUserId) JOIN a friend's server: server-side teleport, friends only (PartyService)
	"TravelHome", -- ("Go" | "Stay") run server, back in its lobby: go to a public lobby now / stay and play here (RunServers)
}

local folder: Folder? = nil
local cache: { [string]: RemoteEvent } = {}

-- Server only: create every remote and the shared state object.
function Remotes.Setup()
	assert(RunService:IsServer(), "Remotes.Setup is server only")
	local f = ReplicatedStorage:FindFirstChild("Remotes")
	if not f then
		f = Instance.new("Folder")
		f.Name = "Remotes"
		f.Parent = ReplicatedStorage
	end
	folder = f :: Folder
	for _, list in ipairs({ Remotes.ServerToClient, Remotes.ClientToServer }) do
		for _, name in ipairs(list) do
			local remote = f:FindFirstChild(name)
			if not remote then
				remote = Instance.new("RemoteEvent")
				remote.Name = name
				remote.Parent = f
			end
			cache[name] = remote :: RemoteEvent
		end
	end
	local state = ReplicatedStorage:FindFirstChild("SwarmState")
	if not state then
		state = Instance.new("Configuration")
		state.Name = "SwarmState"
		state.Parent = ReplicatedStorage
	end
	return f
end

-- Both sides: the RemoteEvent with this name (client waits for replication).
function Remotes.Get(name: string): RemoteEvent
	local remote = cache[name]
	if remote then
		return remote
	end
	if not folder then
		folder = ReplicatedStorage:WaitForChild("Remotes") :: Folder
	end
	remote = (folder :: Folder):WaitForChild(name) :: RemoteEvent
	cache[name] = remote
	return remote
end

-- Both sides: the Configuration that holds global run state attributes.
function Remotes.State(): Configuration
	return ReplicatedStorage:WaitForChild("SwarmState") :: Configuration
end

-- Per-player token buckets: buckets[player][remoteName] = { tokens, last }
local buckets: { [Player]: { [string]: { tokens: number, last: number } } } = {}

local function allow(player: Player, name: string, rate: number): boolean
	local perPlayer = buckets[player]
	if not perPlayer then
		perPlayer = {}
		buckets[player] = perPlayer
	end
	local now = os.clock()
	local bucket = perPlayer[name]
	if not bucket then
		bucket = { tokens = rate, last = now }
		perPlayer[name] = bucket
	end
	bucket.tokens = math.min(rate, bucket.tokens + (now - bucket.last) * rate)
	bucket.last = now
	if bucket.tokens < 1 then
		return false
	end
	bucket.tokens -= 1
	return true
end

if RunService:IsServer() then
	Players.PlayerRemoving:Connect(function(player)
		buckets[player] = nil
	end)
end

-- Server only: connect a client→server handler with rate limiting and error isolation.
function Remotes.Listen(name: string, handler: (Player, ...any) -> (), ratePerSecond: number?)
	local rate = ratePerSecond or Config.Net.DefaultRate
	Remotes.Get(name).OnServerEvent:Connect(function(player, ...)
		if not allow(player, name, rate) then
			return
		end
		local ok, err = pcall(handler, player, ...)
		if not ok then
			warn(string.format("[Remotes] %s handler error for %s: %s", name, player.Name, tostring(err)))
		end
	end)
end

function Remotes.FireClient(name: string, player: Player, ...)
	Remotes.Get(name):FireClient(player, ...)
end

function Remotes.FireAllClients(name: string, ...)
	Remotes.Get(name):FireAllClients(...)
end

return Remotes
