--[[
	RunManager.lua
	The run state machine and everything about players' bodies and lives.

	Phases (SwarmState attribute "Phase"):
	  Lobby      everyone sees the lobby menu screen (characters, shop, mode buttons)
	  Countdown  someone pressed DUO / TRIO; 10 s for others to join (JOIN button); the
	             starter may START NOW once someone joined, a full run starts at once
	  Running    the run: a series of stages (StageManager: explore, portal boss, surge,
	             NEXT STAGE / RETURN TO LOBBY, travel); the timer counts the whole run
	  Results    defeat screen (everyone fell); everyone returns after ResultsSeconds
	A player who leaves through an open portal ends their run as a win at once
	(ReturnThroughPortal: results over the lobby menu); when nobody goes on, the run ends
	straight back to the Lobby phase (FinishFromPortal).
	Endless (Config.Endless, the starter's lobby switch via RunModifiers): no portal
	return and never a win; the run ends by defeat or the pause menu's MAIN MENU
	(AbandonRun). Its score goes to the "ScoreEndless" board instead of "Score"; the
	"Level" board (highest level in one run) takes every mode.
	Parties (PartyService): only a party's leader starts runs (once every member is READY), and that start brings the
	members in at once up to the mode's size (joinParty); others still JOIN the countdown.
	SOLO skips the countdown. Live game (RunServers, Config.RunServers): beginRun hands the
	team to RunServers.SendToRun, which saves them and teleports them to their own private
	run server; that server starts the run through StartTeamRun and sends everyone back to
	a public lobby after it (OnBackInLobby). Studio / a failed teleport play here as before.
	Modes live in Config.Modes; "Squad" (old 1-4 mode) is still
	accepted from old clients. The lobby's ProximityPrompts are switched off: the 2D lobby
	screen (UIBuilder / LobbyScreen) sends StartRun / StartNow / CycleArena instead.

	SwarmState attributes for the lobby screen: Phase, Mode, Countdown, Joined, MaxJoin,
	JoinedNames, Starter (UserId), SelectedArena, LobbySpawn (CFrame).
	ReplicatedStorage.CharacterPreviews holds one model per character + skin for the
	client's 3D previews (rebuilt when the uploaded meshes finish loading).

	Each participant gets a "run player" record (rp) that every other system uses:
	  Player, Character, Root, Humanoid, CharacterId, Meta, Stats, HP, Level, XP, XPNeeded,
	  Weapons, WeaponOrder, Passives, PassiveOrder, PendingLevels, Offer, Paused, Alive,
	  AwaitingRevive, RevivesLeft, Rerolls, Skips, Kills, Gold, DamageDealt, TimeSurvived,
	  Facing, MoveDir, InvulnUntil, Returned, PortalChoice, PortalOffered, Committed, WinPaid,
	  Items, ItemOrder, ItemState, ShieldMax, GoldSpent (run items: ItemSystem / LootSystem),
	  Downed, BleedLeft, Eliminated, Reviver, ReviveTarget, ReviveHeldAt, Revives,
	  HitProtectUntil, SpeedBoost, SpeedBoostUntil, AirReset (survival rules, stream E1: see the
	  "HP, downed, revive, elimination" and "Disconnect window" sections)
	HP lives here (not in the Humanoid): the Humanoid's Dead state is disabled.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Config = require(game:GetService("ReplicatedStorage").Shared.Config)
local Remotes = require(game:GetService("ReplicatedStorage").Shared.Remotes)
local CharacterData = require(game:GetService("ReplicatedStorage").Shared.CharacterData)
local MetaUpgradeData = require(game:GetService("ReplicatedStorage").Shared.MetaUpgradeData)
local CurseData = require(game:GetService("ReplicatedStorage").Shared.CurseData)
local NextGoal = require(game:GetService("ReplicatedStorage").Shared.NextGoal)
local ModelBuilder = require(script.Parent.ModelBuilder)
local MapBuilder = require(script.Parent.MapBuilder)
local Fx = require(script.Parent.Fx)
local Events = require(script.Parent.Events)
local DevTools = require(script.Parent.DevTools)
local EncounterDirector = require(script.Parent.EncounterDirector) -- feature encounters: PlayerOut on death / portal / abandon
local HeightGrid = require(script.Parent.HeightGrid) -- ground height (flat FLOOR_Y without a height grid)
local Nav = require(game:GetService("ReplicatedStorage").SwarmV2.Run.RunConfig).Nav
-- [stream E1] survival rules: downed / revive / protection / falls / disconnects / movement caps
local Survival = require(game:GetService("ReplicatedStorage").SwarmV2.Run.RunConfig).Survival
local SurvivalRules = require(game:GetService("ReplicatedStorage").SwarmV2.Run.SurvivalRules)
local DashRules = require(game:GetService("ReplicatedStorage").SwarmV2.Run.RunConfig).Dash
local BuildRules = require(game:GetService("ReplicatedStorage").SwarmV2.Run.BuildRules) -- [stream B] armor A / (100 + A)

local RunManager = {}

-- SwarmV2 run entry (src/swarmv2/server/Run/RunEntry.lua): admitted class per player,
-- and whether this server shows the old lobby hero (off on match servers / the new lobby).
local admittedClass: { [Player]: string? } = {}
local lobbySpawnSuppressed = false

function RunManager.SetAdmittedClass(player: Player, classId: string?)
	admittedClass[player] = classId
end

-- Set by SwarmV2 RunEntry: called once per player whose run is over (after the commit).
RunManager.OnReturnHome = nil :: ((Player, string) -> ())?

function RunManager.SetLobbySpawnSuppressed(on: boolean)
	lobbySpawnSuppressed = on
end

local disconnected: { [number]: any } = {}

local ctx
local state: Configuration
local lobby
local rng = Random.new()
local FLAT = Vector3.new(1, 0, 1)
local FLOOR_Y = Config.ArenaOrigin.Y -- every arena's floor top (MapBuilder biomeGround / buildForest)

local phase = "Lobby"
local countdown = 0
local joined: { [Player]: boolean } = {}
local joinedOrder: { Player } = {} -- join order, for the names shown on the lobby screen
local starter: Player? = nil -- who started the countdown (may press START NOW)
local runPlayers: { any } = {} -- array of rp
local byPlayer: { [Player]: any } = {}
local runTime = 0
local frozen = false -- the whole run is paused (menuPaused or someone is choosing a level-up)
local menuPaused = false -- the solo pause menu is open
local resultsTimer = 0
local totalKills = 0
local bossKills = 0 -- Scorpion Queens beaten this run (results screen)
-- Run identity and dev taint: every run gets a fresh id (leaderboard submissions are once
-- per run id). A DEV command used during a run taints it and everyone in it: no records,
-- leaderboard entries, daily score, account XP or achievement progress are written.
local runSerial = 0
local runId = ""
local runDevTainted = false
local attrTimer = 0
local selectedArena = "Forest"
local mode = "Solo" -- a Config.Modes key: "Solo" | "Duo" | "Trio" (or the old "Squad")
local expectedRemoval: { [Model]: boolean } = {}

------------------------------------------------------------------------------------------
-- Queries used by other systems
------------------------------------------------------------------------------------------

function RunManager.GetRunPlayers()
	return runPlayers
end

function RunManager.GetRunPlayer(player: Player)
	return byPlayer[player]
end

-- True while the player is in the current run (and hasn't gone back to the lobby).
function RunManager.IsParticipant(player: Player): boolean
	local rp = byPlayer[player]
	return rp ~= nil and not rp.Returned
end

-- True when a DEV command was used in the player's current run (nothing public is written).
-- Joined this server's lobby countdown (DUO / TRIO / party start): RunServers keeps them.
function RunManager.IsQueued(player: Player): boolean
	return phase == "Countdown" and joined[player] == true
end

function RunManager.IsDevTainted(player: Player): boolean
	local rp = byPlayer[player]
	return rp ~= nil and rp.DevTainted == true
end

function RunManager.IsFrozen(): boolean
	return frozen
end

-- True only for the solo pause menu (level-up pauses keep their auto-pick timer running).
function RunManager.IsMenuPaused(): boolean
	return menuPaused
end

--[[
	The whole run freezes while the solo pause menu is open, while any player is choosing
	a level-up card or while a chest reward panel shows (enemies, projectiles, damage and
	the timer all stop for everyone). Called whenever any source changes.
]]
function RunManager.RefreshFrozen()
	local choosing, rewarding = false, false
	local ids, names = {}, {}
	local rewardIds, rewardNames = {}, {}
	for _, rp in ipairs(runPlayers) do
		-- (a live team-run choice, rp.LiveChoice, never freezes anything: [stream B] LevelUpSystem)
		if rp.Offer and rp.Alive and not rp.Returned and not rp.LiveChoice then
			choosing = true
			table.insert(ids, tostring(rp.Player.UserId))
			table.insert(names, rp.Player.DisplayName)
		end
		if rp.RewardUntil and rp.Alive and not rp.Returned then
			rewarding = true
			table.insert(rewardIds, tostring(rp.Player.UserId))
			table.insert(rewardNames, rp.Player.DisplayName)
		end
	end
	rewarding = rewarding and phase == "Running"
	-- group runs: a choice or a reward protects that player only (DamagePlayer), the rest
	-- of the team keeps playing; with one fighter left it freezes the world as before
	local fighters = 0
	for _, rp in ipairs(runPlayers) do
		if rp.Alive and not rp.Returned then
			fighters += 1
		end
	end
	local choiceFreezes = fighters <= 1 or Config.Run.CoopChoiceFreezesRun == true
	-- [stream E1] no connected living hero, but someone is inside their disconnect window: the
	-- world waits for them (bounded by the window, Survival.Disconnect)
	local awayHold = fighters == 0 and RunManager.AwayInWindow() > 0
	-- who is opening a chest ("<Name> is opening a chest" on everyone else's HUD)
	state:SetAttribute("RewardIds", rewarding and ("," .. table.concat(rewardIds, ",") .. ",") or "")
	state:SetAttribute("RewardNames", rewarding and table.concat(rewardNames, ", ") or "")
	-- QuickResume: a held solo run (its player disconnected) stays frozen until resumed / settled
	local newFrozen = phase == "Running" and (menuPaused or RunManager.SoloAway ~= nil or awayHold or (choiceFreezes and (choosing or rewarding)))
	-- who is choosing, so the HUD can say "<Name> is choosing an upgrade" to everyone else
	-- (the chooser sees the cards instead); set before LevelUpPause so both arrive together
	state:SetAttribute("ChoosingIds", (phase == "Running" and choosing) and ("," .. table.concat(ids, ",") .. ",") or "")
	state:SetAttribute("ChoosingNames", (phase == "Running" and choosing) and table.concat(names, ", ") or "")
	state:SetAttribute("LevelUpPause", phase == "Running" and choosing and choiceFreezes and not menuPaused)
	if newFrozen == frozen then
		return
	end
	frozen = newFrozen
	state:SetAttribute("Frozen", frozen)
	for _, rp in ipairs(runPlayers) do
		RunManager.ApplyMovement(rp)
		-- start a fresh speed-check window so movement just before the freeze isn't
		-- judged against the frozen limit of 0 (that snapped players back)
		rp.SpeedCheckTimer = 0
		rp.LastValidPos = rp.Root and rp.Root.Position
	end
end

-- A live group run: more than one fighter and the world not frozen or travelling.
local function groupLive(): boolean
	if phase ~= "Running" or frozen or ctx.StageManager.IsHolding() then
		return false
	end
	local fighters = 0
	for _, rp in ipairs(runPlayers) do
		if rp.Alive and not rp.Returned then
			fighters += 1
		end
	end
	return fighters > 1
end

--[[
	Chest rewards: a chest / shrine / altar paid this player an item (or an elite chest its
	level-ups): the run pauses while the client's reel spins and reveals it (UIBuilder).
	RewardSeq counts the rewards sent to this player; the client answers RewardClose(seq)
	when it has shown them all, and a close that hasn't seen the latest reward yet is
	ignored (so a reward granted while the previous close was in flight keeps its pause).
	Server limits whatever the client does: Config.Chests.RewardPauseSeconds after a reward
	(+ RewardQueueSeconds per reward queued behind it), never past RewardPauseMax from the
	first one (Step). Not while travelling. The item itself was granted before this is
	called: closing, skipping or timing never changes what the player owns.
]]
function RunManager.HoldReward(rp, dramatic: boolean?)
	rp.RewardSeq = (rp.RewardSeq or 0) + 1
	if dramatic == false then
		return
	end
	if phase ~= "Running" or ctx.StageManager.IsHolding() or not rp.Alive or rp.Returned then
		return
	end
	-- Duo/Trio with the world live: a reward is not a choice. No hold, no rooting, no
	-- protection (docs/overhaul/CHOICE_STATE.md); the client shows it without blocking.
	if groupLive() then
		return
	end
	local C = Config.Chests
	local now = os.clock()
	local untilT = now + (C.RewardPauseSeconds or 3.2)
	local first = rp.RewardUntil == nil
	if rp.RewardUntil then
		-- queued behind the reward being shown
		untilT = math.max(untilT, rp.RewardUntil + (C.RewardQueueSeconds or 2.2))
	else
		rp.RewardStart = now
	end
	rp.RewardUntil = math.min(untilT, (rp.RewardStart or now) + (C.RewardPauseMax or 7))
	if first then
		-- rooted from here: a fresh speed-check window so the run-up isn't judged against 0
		rp.SpeedCheckTimer = 0
		rp.LastValidPos = rp.Root and rp.Root.Position
		RunManager.ApplyMovement(rp)
	end
	RunManager.RefreshFrozen()
end

--[[
	Choice protection budget (docs/overhaul/CHOICE_STATE.md). In a live group run (world not
	frozen, more than one fighter) a player's protected time (open level-up panel, chest reel,
	close grace) drains rp.ProtectBudget; unprotected time refills it at
	Config.LevelUp.ProtectBudgetRefillPerMinute up to ProtectBudgetSeconds. Solo choices
	freeze the world, so they never drain it. LevelUpSystem caps a group panel's deadline at
	the budget left and waits to open one until GroupMinPanelSeconds are available.
]]

function RunManager.ChoiceBudget(rp): number
	local cap = Config.LevelUp.ProtectBudgetSeconds or math.huge
	if rp.ProtectBudget == nil then
		rp.ProtectBudget = cap
	end
	return math.clamp(rp.ProtectBudget, 0, cap)
end

-- True when a choice by this player runs over live combat (Duo/Trio, world not frozen).
function RunManager.IsGroupChoice(): boolean
	return groupLive()
end

local function stepProtectBudget(rp, dt: number, live: boolean)
	local L = Config.LevelUp
	local cap = L.ProtectBudgetSeconds or math.huge
	local budget = RunManager.ChoiceBudget(rp)
	if live and rp.Paused and rp.Offer ~= nil then
		budget -= dt
	else
		budget += dt * (L.ProtectBudgetRefillPerMinute or 0) / 60
	end
	rp.ProtectBudget = math.clamp(budget, 0, cap)
end

-- A short invulnerability after a choice / reward closes (Config.Player.ChoiceGraceSeconds).
-- In a live group run it is paid from the protection budget like the choice itself.
function RunManager.GrantChoiceGrace(rp)
	if rp.Alive then
		local grace = Config.Player.ChoiceGraceSeconds or 0
		if groupLive() then
			grace = math.min(grace, RunManager.ChoiceBudget(rp))
			rp.ProtectBudget = RunManager.ChoiceBudget(rp) - grace
		end
		rp.InvulnUntil = math.max(rp.InvulnUntil or 0, runTime + grace)
	end
end

function RunManager.EndReward(rp)
	if rp.RewardUntil then
		rp.RewardUntil = nil
		rp.RewardStart = nil
		RunManager.GrantChoiceGrace(rp)
		RunManager.ApplyMovement(rp)
		RunManager.RefreshFrozen()
	end
end

-- True when the world should move: a run is going, it isn't paused and the group isn't
-- travelling to the next stage.
function RunManager.IsSimulating(): boolean
	return phase == "Running" and not frozen and not ctx.StageManager.IsHolding()
end

-- True while a run is in progress (any stage sub-phase, paused or not).
function RunManager.IsRunning(): boolean
	return phase == "Running"
end

-- Kept for older callers: true during a stage's Scorpion Queen fight.
function RunManager.IsBossPhase(): boolean
	return ctx.StageManager.IsBossFight()
end

function RunManager.GetRunTime(): number
	return runTime
end

function RunManager.GetTier(): number
	return math.floor(runTime / 60)
end

function RunManager.AddTotalKill()
	totalKills += 1
end

------------------------------------------------------------------------------------------
-- Messages
------------------------------------------------------------------------------------------

--[[
	Every Notify payload carries the client's lane routing (docs/overhaul/UI_STATE_CONTRACT.md
	section 3): Id (semantic id; the same id from two producers shows once), Lane
	("Headline" | "Notice") and Class ("Critical" | "Info"). Senders pass `meta` with the id
	from the contract's table; without it a personal message is an Info notice keyed by its
	text and a broadcast is a notice (Info) or, when big, a Critical headline, which is what
	the client's classifier would pick for an unknown text.
]]
export type NotifyMeta = { Id: string?, Lane: string?, Class: string? }

local function payload(text: string, color: Color3?, big: boolean?, meta: NotifyMeta?)
	local lane = meta and meta.Lane or (big and "Headline" or "Notice")
	local class = meta and meta.Class or (big and "Critical" or "Info")
	local id = meta and meta.Id or ((big and "big:" or "text:") .. string.lower(text))
	return { Text = text, Color = color, Big = big, Id = id, Lane = lane, Class = class }
end
RunManager.NotifyPayload = payload -- (RunServers / PartyService / tests)

function RunManager.Notify(player: Player, text: string, color: Color3?, meta: NotifyMeta?)
	if player.Parent then
		Remotes.FireClient("Notify", player, payload(text, color, nil, meta))
	end
end

function RunManager.Broadcast(text: string, color: Color3?, big: boolean?, meta: NotifyMeta?)
	Remotes.FireAllClients("Notify", payload(text, color, big, meta))
end

-- True for a mode name a client may ask for (the lobby's modes, the Daily Challenge and
-- the old "Squad").
local function isMode(name: any): boolean
	return type(name) == "string" and (table.find(Config.Modes.Order, name) ~= nil or name == "Squad" or name == "Daily"
		or (name == "Weekly" and Config.FeatureOn("WeeklyChallenge"))) -- META: the Weekly Challenge
end

local function modeDef()
	return (Config.Modes :: any)[mode] or Config.Modes.Solo
end

local function maxPlayers(): number
	return math.min(Config.Run.MaxPlayers, modeDef().MaxPlayers)
end

local function setPhase(newPhase: string)
	phase = newPhase
	state:SetAttribute("Phase", newPhase)
end

-- The lobby is a 2D menu now: its world prompts stay in the map but never fire.
local function disableLobbyPrompts()
	if not lobby then
		return
	end
	for _, v in pairs(lobby) do
		if typeof(v) == "Instance" and v:IsA("ProximityPrompt") then
			v.Enabled = false
		end
	end
	local model = lobby.Model
	if typeof(model) == "Instance" then
		for _, d in ipairs(model:GetDescendants()) do
			if d:IsA("ProximityPrompt") then
				d.Enabled = false
			end
		end
	end
end

-- Who has joined the countdown, for the lobby screen.
local function publishJoined()
	local names = {}
	for _, p in ipairs(joinedOrder) do
		if joined[p] and p.Parent then
			table.insert(names, p.DisplayName)
		end
	end
	state:SetAttribute("Joined", #names)
	state:SetAttribute("JoinedNames", table.concat(names, ", "))
	state:SetAttribute("MaxJoin", maxPlayers())
	state:SetAttribute("Starter", starter and starter.UserId or 0)
end

------------------------------------------------------------------------------------------
-- Characters
------------------------------------------------------------------------------------------

local spawnCharacter -- forward declaration
-- [stream E1] disconnect window helpers (defined in the "Disconnect window" section)
local settleAway: (any, number) -> Player?
local publishAway: () -> ()

local function lobbySpawnCFrame(): CFrame
	local a = rng:NextNumber(0, math.pi * 2)
	return lobby.SpawnCFrame * CFrame.new(math.cos(a) * 5, 0, math.sin(a) * 5)
end

--[[
	Builds the player's blocky character (selected character + skin) and places it.
	inLobby adds the VIP crown. Old characters are destroyed on purpose (not respawned).
]]
spawnCharacter = function(player: Player, cframe: CFrame, inLobby: boolean, runCharacterId: string?): Model?
	if inLobby and lobbySpawnSuppressed then
		-- the SwarmV2 basecamp (or a match server) owns lobby characters (Lobby.Avatars)
		return player.Character
	end
	local data = ctx.DataService.GetData(player)
	if not data or not player.Parent then
		return nil
	end
	local characterId = runCharacterId or data.SelectedCharacter
	if not CharacterData.Characters[characterId] then
		characterId = CharacterData.Default
	end
	local skinId = data.Skins[characterId] or "Default"
	if not ctx.MonetizationService.OwnsSkin(player, skinId) then
		skinId = "Default"
	end
	local crown = inLobby and ctx.MonetizationService.OwnsPass(player, "VIP")
	local model = ModelBuilder.BuildCharacter(characterId, skinId, { Crown = crown })
	model.Name = player.Name
	-- built from the part fallback because the hero's meshes are still loading: load them
	-- next and swap the character for the mesh hero the moment they arrive. Lobby: the
	-- lobby character (and the menu showcase that copies it). Run: the run character in
	-- place. A run on a fresh private run server starts within seconds, before the hero
	-- meshes are in, and without this swap the whole run showed the part-built stand-in.
	local meshNames = ModelBuilder.MeshesFor(characterId, skinId)
	local ms = ctx.MeshService
	local waiting = false
	for _, n in ipairs(meshNames) do
		waiting = waiting or ms.MayLoad(n)
	end
	if waiting then
		ms.Prioritize(meshNames)
		ms.WhenReady(meshNames, function()
			if not (player.Parent and player.Character == model and model.Parent) then
				return
			end
			if inLobby then
				RunManager.RefreshLobbyCharacter(player)
			else
				RunManager.SwapRunCharacter(player, model)
			end
		end)
	end

	local old = player.Character
	if old then
		expectedRemoval[old] = true
		old:Destroy()
	end

	model:PivotTo(cframe)
	local humanoid = model:FindFirstChildOfClass("Humanoid") :: Humanoid
	humanoid:SetStateEnabled(Enum.HumanoidStateType.Dead, false)
	humanoid:SetStateEnabled(Enum.HumanoidStateType.FallingDown, false)
	humanoid:SetStateEnabled(Enum.HumanoidStateType.Ragdoll, false)
	-- Jumping stays enabled: JumpController (client) jumps, speedCheck caps hop speed
	-- the lobby is a menu screen: lobby characters stand still
	humanoid.WalkSpeed = inLobby and 0 or Config.Player.BaseSpeed
	player.Character = model
	model.Parent = workspace
	local root = model.PrimaryPart :: BasePart
	pcall(function()
		root:SetNetworkOwner(player)
	end)

	-- Unexpected removal (fell out of the world, destroyed by physics): respawn.
	model.AncestryChanged:Connect(function()
		if model:IsDescendantOf(workspace) then
			return
		end
		if expectedRemoval[model] then
			expectedRemoval[model] = nil
			return
		end
		task.delay(0.5, function()
			if not player.Parent or player.Character ~= model then
				return
			end
			local rp = byPlayer[player]
			if rp and not rp.Returned and phase ~= "Lobby" then
				local arena = MapBuilder.GetArena()
				local cf = CFrame.new(HeightGrid.Ground(arena and arena.Center or Config.ArenaOrigin) + Vector3.new(0, 3.5, 0))
				local m = spawnCharacter(player, cf, false, rp.CharacterId)
				RunManager.AttachCharacter(rp, m)
			else
				if not lobbySpawnSuppressed then spawnCharacter(player, lobbySpawnCFrame(), true) end
			end
		end)
	end)
	return model
end

function RunManager.AttachCharacter(rp, model: Model?)
	if not model then
		return
	end
	rp.Character = model
	rp.Root = model.PrimaryPart
	rp.Humanoid = model:FindFirstChildOfClass("Humanoid")
	rp.LastValidPos = rp.Root and rp.Root.Position
	RunManager.ApplyMovement(rp)
end

-- Rebuilds a lobby player's character (character select, skin, VIP purchase).
function RunManager.RefreshLobbyCharacter(player: Player)
	if RunManager.IsParticipant(player) then
		return
	end
	local cf = lobbySpawnCFrame()
	local char = player.Character
	if char and char.PrimaryPart and char:IsDescendantOf(workspace) then
		cf = char.PrimaryPart.CFrame
	end
	spawnCharacter(player, cf, true)
end

-- Sets WalkSpeed from state: 0 when paused, dead, downed, frozen or travelling.
-- rp.TerrainSpeedMult: the biome floor under the player (mud, quicksand, ice; BiomeHazards).
function RunManager.ApplyMovement(rp)
	local hum: Humanoid? = rp.Humanoid
	-- a chest reward reel (RewardUntil) roots the opener; it only exists while the world
	-- is frozen (solo), never over live group combat (HoldReward)
	local canMove = rp.Alive and not rp.Paused and not rp.RewardUntil and not frozen and phase == "Running" and not ctx.StageManager.IsHolding()
	if hum and hum.Parent then
		-- rp.RushMult: Windstep's short burst after a kill (ItemSystem); rp.WeatherSpeedMult:
		-- a snow storm (Weather). [stream E1] never above the generic cap (34) unless an explicit
		-- class boost is active (RunManager.SetSpeedBoost)
		local walk = canMove and rp.Stats and rp.Stats.Speed * (rp.TerrainSpeedMult or 1) * RunManager.RushMult(rp) * (rp.WeatherSpeedMult or 1) or 0
		hum.WalkSpeed = math.min(walk, RunManager.SpeedLimit(rp))
	end
	rp.Player:SetAttribute("Paused", rp.Paused == true)
end

-- [stream E1] The most horizontal speed a hero may have outside a dash: the generic cap
-- (Survival.Move.HorizontalCap, 34) or an explicit class boost while it lasts.
function RunManager.SpeedLimit(rp): number
	local cap = Survival.Move.HorizontalCap
	local boost, untilT = rp.SpeedBoost, rp.SpeedBoostUntil
	if type(boost) == "number" and type(untilT) == "number" and os.clock() < untilT then
		cap = math.max(cap, boost)
	end
	return cap
end

--[[
	[stream E1] An explicit class boost (class kits, stream C): for `seconds` the hero may move up
	to `speed` studs/s (WalkSpeed, the client's speed cap and the server speed check all allow it).
	The kit still sets the speed itself (rp.Stats / its own multiplier); this only lifts the cap.
]]
function RunManager.SetSpeedBoost(rp, speed: number, seconds: number)
	if not (speed == speed and seconds == seconds) or speed <= 0 or seconds <= 0 or seconds > 60 then
		return
	end
	rp.SpeedBoost = math.min(speed, 200)
	rp.SpeedBoostUntil = os.clock() + seconds
	rp.Player:SetAttribute("SpeedBoost", rp.SpeedBoost)
	rp.Player:SetAttribute("SpeedBoostUntil", workspace:GetServerTimeNow() + seconds)
	RunManager.ApplyMovement(rp)
	task.delay(seconds + 0.05, function()
		if byPlayer[rp.Player] == rp then
			RunManager.ApplyMovement(rp)
		end
	end)
end

-- Windstep's burst, capped with the speed of now (MATH-17): the burst stores its multiplier
-- when it starts, so a speed gain during the burst must not push Speed x Rush past
-- BaseSpeed x Items.MaxSpeedMult. Never below 1 (a burst never slows).
function RunManager.RushMult(rp): number
	local mult = rp.RushMult
	if not mult or not rp.Stats then
		return 1
	end
	local cap = Config.Player.BaseSpeed * Config.Items.MaxSpeedMult / math.max(1, rp.Stats.Speed)
	return math.max(1, math.min(mult, cap))
end

function RunManager.ApplyMovementAll()
	for _, rp in ipairs(runPlayers) do
		RunManager.ApplyMovement(rp)
		rp.SpeedCheckTimer = 0
		rp.LastValidPos = rp.Root and rp.Root.Position
	end
end

local function setDownedLook(rp, downed: boolean)
	local char: Model? = rp.Character
	if not char then
		return
	end
	for _, d in ipairs(char:GetDescendants()) do
		if d:IsA("BasePart") and d.Name ~= "HumanoidRootPart" then
			if downed then
				if d:GetAttribute("BaseTransparency") == nil then
					d:SetAttribute("BaseTransparency", d.Transparency)
				end
				d.Transparency = 0.75
			else
				d.Transparency = d:GetAttribute("BaseTransparency") or 0
			end
		end
	end
	if rp.Root then
		rp.Root.Anchored = downed
		if not downed then
			-- anchoring dropped the explicit owner; give physics back to the player
			local root = rp.Root
			pcall(function()
				root:SetNetworkOwner(rp.Player)
			end)
		end
	end
end

--[[
	Replaces a run character built from the part fallback with the mesh hero (same hero,
	skin, place and facing) once its meshes have loaded. Only while `old` is still the
	player's run character; a fallen hero keeps its downed look.
]]
function RunManager.SwapRunCharacter(player: Player, old: Model)
	local rp = byPlayer[player]
	if not rp or rp.Returned or rp.Character ~= old or player.Character ~= old or not old.Parent then
		return
	end
	local root = old.PrimaryPart
	local cf = root and root.CFrame or old:GetPivot()
	local m = spawnCharacter(player, cf, false, rp.CharacterId)
	if not m then
		return
	end
	RunManager.AttachCharacter(rp, m)
	rp.LastValidPos = m.PrimaryPart and m.PrimaryPart.Position
	rp.SpeedCheckTimer = 0
	if not rp.Alive then
		setDownedLook(rp, true)
	end
end

------------------------------------------------------------------------------------------
-- HP, downed, revive, elimination  [stream E1: RunConfig.Survival, docs in this header]
------------------------------------------------------------------------------------------
--[[
	A hero at 0 HP goes through, in this order:
	  1. an extra life (the account's Revive upgrade, rp.RevivesLeft) or a Phoenix Feather run
	     item: back at once (unchanged).
	  2. DOWNED for Survival.Downed.BleedSeconds (20) while someone could still revive them: a
	     living connected teammate, a living teammate inside the disconnect window, or a teammate
	     deciding on the paid revive. Downed heroes do not attack, gain XP or heal, and their level
	     choices wait (LevelUpSystem.Cancel keeps the banked levels). A living teammate holding
	     interact (remote "ReviveHold", E / gamepad X / the touch REVIVE button) within ReviveRange
	     (8) for ReviveSeconds (3) without a break revives them at ReviveHPShare (25%) of max HP with
	     ReviveProtectSeconds (1) of protection and a visible ring. Letting go, leaving range, the
	     reviver taking damage or going down resets the progress. The bleed only runs while the
	     world runs (not during a freeze or a stage travel).
	  3. ELIMINATED when the bleed runs out, or at once when nobody could revive them. The existing
	     paid path runs first (DECISIONS C8, unchanged and receipt-backed): a saved revive token is
	     spent, else the Revive product is offered (AwaitingRevive, RevivePromptSeconds). Declined or
	     timed out: out for the rest of the run, spectating teammates.
	Defeat is declared once (EndRun) when no living connected hero remains, nobody is inside the
	disconnect window and no paid-revive offer is open. Downed heroes nobody can reach are
	eliminated at that moment (resolveRescue) instead of waiting out their bleed.

	Protection: one shared HitProtectSeconds (0.35) window after an ordinary incoming hit
	(rp.HitProtectUntil, run clock; Player attribute HitProtectUntil, server time). It never stacks
	per attacker and is separate from the revive protection (rp.InvulnUntil; attribute
	ReviveProtectUntil). Dashes and open menus grant none (Survival.MenuProtection = false).
	Falls (kind "fall", RunManager.OnFallLanding) skip the hit protection and armor.

	Player attributes: Alive, Downed, BleedLeft (s), ReviveProgress (0..1), Eliminated, Spectating,
	AwaitingRevive, HitProtectUntil, ReviveProtectUntil, PartnerRevivesLeft (old team UI: 1 while
	revivable). rp fields: Downed, BleedLeft, Eliminated, Reviver / ReviveTarget (the link while a
	revive is held), ReviveHeldAt (os.clock of the last fresh hold), Revives (teammates revived,
	class goal "Revives"), PartnerRevives (times this hero was revived).
]]

local SD = Survival.Downed
local resolvingRescue = false -- ResolveRescue is running (its eliminations check the end once, after it)

-- Player attribute "AwaitingRevive": out of action and deciding on the revive product.
local function setAwaiting(rp, on: boolean)
	rp.AwaitingRevive = on
	rp.Player:SetAttribute("AwaitingRevive", on or nil)
end

local function setHP(rp, hp: number)
	rp.HP = math.clamp(hp, 0, rp.Stats.MaxHP)
	rp.Player:SetAttribute("HP", math.ceil(rp.HP))
end

-- The downed / eliminated attributes the HUD reads (stream F).
local function publishDown(rp)
	local p: Player = rp.Player
	if not p.Parent then
		return
	end
	p:SetAttribute("Downed", rp.Downed == true)
	p:SetAttribute("BleedLeft", rp.Downed == true and math.max(0, math.ceil((rp.BleedLeft or 0) * 10) / 10) or 0)
	p:SetAttribute("Eliminated", rp.Eliminated == true)
	p:SetAttribute("Spectating", rp.Eliminated == true and not rp.Returned)
	p:SetAttribute("PartnerRevivesLeft", rp.Downed == true and 1 or 0) -- old team UI: "down" vs "out"
end

local function setProgress(rp, value: number)
	rp.ReviveProgress = value
	if rp.Player.Parent then
		rp.Player:SetAttribute("ReviveProgress", math.clamp(value, 0, 1))
	end
end

-- Ends a revive in progress on `target` (the downed hero): progress back to 0, link cleared.
local function cancelRevive(target)
	local helper = target.Reviver
	if helper and helper.ReviveTarget == target then
		helper.ReviveTarget = nil
	end
	target.Reviver = nil
	if (target.ReviveProgress or 0) ~= 0 then
		setProgress(target, 0)
	end
end

-- Clears every revive link of `rp` (as the downed hero and as a reviver).
local function clearReviveLinks(rp)
	cancelRevive(rp)
	local target = rp.ReviveTarget
	if target then
		cancelRevive(target)
	end
	rp.ReviveTarget = nil
end

function RunManager.Heal(rp, amount: number, silent: boolean?)
	-- a heal only ever adds: NaN would stick in HP (never dies), a negative amount would be
	-- damage that skips armor and the downed check (an alive hero at 0 HP). Downed and
	-- eliminated heroes are not Alive: heals and heal triggers never reach them.
	if not rp.Alive or not (amount > 0 and amount < math.huge) then
		return
	end
	setHP(rp, rp.HP + amount)
	if not silent then
		Fx.PlayerEvent(rp.Player, "heal")
	end
end

-- True while `rp` is downed (bleeding out, revivable).
function RunManager.IsDowned(rp): boolean
	return rp ~= nil and rp.Downed == true
end

-- True once `rp` is out for the rest of the run (spectating).
function RunManager.IsEliminated(rp): boolean
	return rp ~= nil and rp.Eliminated == true
end

--[[
	Back on their feet. opts.HPShare (default Config.Player.ReviveHPFraction), opts.Protect
	(seconds, default Config.Player.ReviveInvulnSeconds), opts.Clear (default true: the old
	extra-life / paid revive clears non-boss enemies around them; a teammate revive never does,
	so it can't farm kills or XP).
]]
type ReviveOpts = { HPShare: number?, Protect: number?, Clear: boolean? }
local function revive(rp, message: string, opts: ReviveOpts?)
	local o: ReviveOpts = opts or {}
	clearReviveLinks(rp)
	setProgress(rp, 0)
	rp.Alive = true
	rp.Downed = false
	rp.Eliminated = false
	rp.BleedLeft = nil
	setAwaiting(rp, false)
	setDownedLook(rp, false)
	setHP(rp, rp.Stats.MaxHP * (o.HPShare or Config.Player.ReviveHPFraction))
	local protect = o.Protect or Config.Player.ReviveInvulnSeconds
	rp.InvulnUntil = math.max(rp.InvulnUntil or 0, runTime + protect)
	rp.RevivedAt = runTime -- Final Stand's revive grace (FinalStand.lua)
	rp.Player:SetAttribute("Alive", true)
	rp.Player:SetAttribute("ReviveProtectUntil", workspace:GetServerTimeNow() + protect)
	publishDown(rp)
	if rp.Root then
		if o.Clear ~= false then
			ctx.EnemySpawner.KillInRadius(rp.Root.Position, Config.Player.ReviveClearRadius, rp)
			Fx.Ring(rp.Root.Position, Config.Player.ReviveClearRadius, Color3.fromRGB(255, 230, 120))
		else
			Fx.Ring(rp.Root.Position, SD.ReviveRange, Color3.fromRGB(255, 230, 120)) -- the visible cue only
		end
	end
	Fx.PlayerEvent(rp.Player, "revive")
	Remotes.FireClient("ReviveOffer", rp.Player, { Close = true })
	RunManager.Notify(rp.Player, message, Color3.fromRGB(255, 230, 120))
	RunManager.ApplyMovement(rp)
	RunManager.RefreshFrozen()
	-- resume level-ups that were waiting
	if rp.PendingLevels > 0 and not rp.Offer then
		ctx.LevelUpSystem.QueueLevels(rp, 0)
	end
end

-- Out of action (downed or eliminated straight away): attacks stop, choices wait, the body
-- lies faded and anchored. Once per fall.
local function takeDown(rp)
	rp.Alive = false
	rp.TimeSurvived = runTime
	rp.ReviveHeldAt = nil
	clearReviveLinks(rp)
	rp.Player:SetAttribute("Alive", false)
	ctx.LevelUpSystem.Cancel(rp, true) -- banked levels stay for after a revive
	ctx.WeaponSystem.ClearOwner(rp)
	setDownedLook(rp, true)
	EncounterDirector.PlayerOut(rp, "Death")
	Fx.PlayerEvent(rp.Player, "die")
	Fx.Sound("Death")
end

-- True when a teammate who could still revive `rp` exists: living and connected, living and
-- inside the disconnect window, or deciding on the paid revive (they may come back).
local function canBeRescued(rp): boolean
	for _, other in ipairs(runPlayers) do
		if other ~= rp and not other.Returned and ((other.Alive and other.Player.Parent ~= nil) or other.AwaitingRevive) then
			return true
		end
	end
	return RunManager.AwayInWindow() > 0
end

-- Defeat, declared once (EndRun's phase guard): no living connected hero, nobody living inside
-- the disconnect window and no paid-revive offer open. Downed heroes do not hold it up: the ones
-- nobody can reach were eliminated by ResolveRescue before this runs.
local function checkEnd()
	if phase ~= "Running" then
		return
	end
	-- an open portal ends through StageManager (FinishFromPortal: a portal result, not a
	-- defeat), even when the last living player just left through it
	if ctx.StageManager.GetPhase() == "Open" then
		return
	end
	for _, rp in ipairs(runPlayers) do
		if rp.Alive or rp.AwaitingRevive then
			return
		end
	end
	if RunManager.AwayInWindow() > 0 then
		return
	end
	RunManager.EndRun(false)
end

local function finalizeElimination(rp)
	if rp.Eliminated or rp.Returned then
		return
	end
	rp.Alive = false
	rp.Downed = false
	rp.BleedLeft = nil
	rp.Eliminated = true
	setAwaiting(rp, false)
	clearReviveLinks(rp)
	setProgress(rp, 0)
	rp.Player:SetAttribute("Alive", false)
	publishDown(rp)
	Remotes.FireClient("ReviveOffer", rp.Player, { Close = true })
	RunManager.Broadcast(rp.Player.DisplayName .. " is out!", Color3.fromRGB(255, 90, 90), nil, { Id = "team.fallen." .. rp.Player.UserId, Class = "Critical" })
	ctx.StageManager.OnRosterChanged() -- first: an open portal may finish the run as a win
	RunManager.RefreshFrozen()
	if not resolvingRescue then
		RunManager.ResolveRescue()
		checkEnd()
	end
end

--[[
	Elimination: the bleed ran out, or nobody could revive. The established paid path first
	(C8): a saved revive token, else the Revive product offer (bounded wait). Otherwise out.
]]
local function eliminate(rp)
	if rp.Eliminated or rp.AwaitingRevive or rp.Returned then
		return
	end
	clearReviveLinks(rp)
	setProgress(rp, 0)
	rp.Downed = false
	rp.BleedLeft = nil
	local data = rp.Player.Parent and ctx.DataService.GetData(rp.Player)
	if data and (data.ReviveTokens or 0) > 0 and not rp.ProductReviveUsed then
		data.ReviveTokens -= 1
		rp.ProductReviveUsed = true
		revive(rp, "Revive used!")
		return
	end
	if data and not rp.ProductReviveUsed and ctx.MonetizationService.ReviveAvailable() then
		setAwaiting(rp, true)
		rp.ReviveDeadline = os.clock() + Config.Monetization.RevivePromptSeconds
		publishDown(rp)
		Remotes.FireClient("ReviveOffer", rp.Player, { Seconds = Config.Monetization.RevivePromptSeconds, ProductId = Config.Monetization.Products.Revive })
		ctx.MonetizationService.PromptRevive(rp.Player)
		return
	end
	finalizeElimination(rp)
end

-- Downed heroes nobody can reach any more are eliminated now (no waiting out the bleed).
-- One at a time: a revive token spent by one of them makes them a rescuer for the rest.
function RunManager.ResolveRescue()
	if resolvingRescue or phase ~= "Running" then
		return
	end
	resolvingRescue = true
	for _ = 1, #runPlayers + 1 do
		local victim = nil
		for _, rp in ipairs(runPlayers) do
			if rp.Downed and not rp.Returned and not canBeRescued(rp) then
				victim = rp
				break
			end
		end
		if not victim or phase ~= "Running" then
			break
		end
		eliminate(victim)
	end
	resolvingRescue = false
end

local function enterDowned(rp)
	rp.Downed = true
	rp.Eliminated = false
	rp.BleedLeft = SD.BleedSeconds
	setProgress(rp, 0)
	publishDown(rp)
	RunManager.Broadcast(rp.Player.DisplayName .. " is down! Hold interact beside them to revive.", Color3.fromRGB(255, 90, 90), nil, { Id = "team.fallen." .. rp.Player.UserId, Class = "Critical" })
	ctx.StageManager.OnRosterChanged()
	RunManager.RefreshFrozen()
end

local function onDowned(rp)
	rp.LastDownTime = runTime
	rp.ReviveHeld = false
	setHP(rp, 0)
	if rp.RevivesLeft > 0 then
		rp.RevivesLeft -= 1
		revive(rp, "Extra life used!")
		return
	end
	-- a run item (Phoenix Feather) comes before going down
	if ctx.ItemSystem.TryRevive(rp) then
		revive(rp, "The Phoenix Feather burns: you rise again!")
		return
	end
	takeDown(rp)
	if canBeRescued(rp) then
		enterDowned(rp)
	else
		eliminate(rp)
	end
	RunManager.ResolveRescue()
	checkEnd()
end

-- A revive held by `helper` on `target` may go on this frame.
local function holdValid(helper, target): boolean
	if helper == target or not helper.Alive or helper.Returned or not helper.Player.Parent then
		return false
	end
	if helper.ReviveTarget ~= nil and helper.ReviveTarget ~= target then
		return false
	end
	local at = helper.ReviveHeldAt
	if not at or os.clock() - at > SD.HoldFreshSeconds then
		return false
	end
	local a: BasePart? = helper.Root
	local b: BasePart? = target.Root
	return a ~= nil and b ~= nil and (a.Position - b.Position).Magnitude <= SD.ReviveRange
end

local function completeRevive(target, helper)
	cancelRevive(target)
	target.PartnerRevives = (target.PartnerRevives or 0) + 1
	helper.Revives = (helper.Revives or 0) + 1 -- class goal "Revives" (stream E2 counts it at settlement)
	revive(target, "Revived by " .. helper.Player.DisplayName .. "!", { HPShare = SD.ReviveHPShare, Protect = SD.ReviveProtectSeconds, Clear = false })
	Events.Fire("PartnerRevive", helper.Player)
	RunManager.Notify(helper.Player, "You revived " .. target.Player.DisplayName .. "!", Color3.fromRGB(120, 255, 160), { Id = "team.revived." .. target.Player.UserId })
	if ctx.ReviveThanks then
		ctx.ReviveThanks.OnRevived(target, helper) -- ReviveThanks: the THANKS! offer (docs/next/REVIVE_THANKS.md)
	end
end

--[[
	Per frame: bleed timers and held revives. `live` = the world is running (the bleed and the
	revive progress pause while it is frozen or travelling; a held revive is not reset by that).
]]
local function stepDowned(dt: number, live: boolean)
	for _, rp in ipairs(table.clone(runPlayers)) do
		if rp.Downed and not rp.Returned and phase == "Running" then
			if live then
				local before = math.ceil((rp.BleedLeft or 0) * 10)
				rp.BleedLeft = (rp.BleedLeft or SD.BleedSeconds) - dt
				if rp.BleedLeft <= 0 then
					eliminate(rp)
					continue
				end
				if math.ceil(rp.BleedLeft * 10) ~= before then
					rp.Player:SetAttribute("BleedLeft", math.ceil(rp.BleedLeft * 10) / 10)
				end
			end
			local helper = rp.Reviver
			if helper and not holdValid(helper, rp) then
				cancelRevive(rp) -- let go, walked off, went down or left: start again
				helper = nil
			end
			if not helper then
				local best, bestD = nil, math.huge
				for _, other in ipairs(runPlayers) do
					if other.ReviveTarget == nil and holdValid(other, rp) then
						local d = (other.Root.Position - rp.Root.Position).Magnitude
						if d < bestD then
							best, bestD = other, d
						end
					end
				end
				if best then
					rp.Reviver = best
					best.ReviveTarget = rp
					helper = best
				end
			end
			if helper and live then
				setProgress(rp, math.min(1, (rp.ReviveProgress or 0) + dt / SD.ReviveSeconds))
				if rp.ReviveProgress >= 1 then
					completeRevive(rp, helper)
				end
			end
		end
	end
end

-- What kind of hit a cause string is (callers that do not pass one): "contact" | "projectile"
-- | "hazard" (lingering ground: fire, acid pools, lava) | "area" (strikes, waves, eruptions).
local function hitKind(cause: string?): string
	local c = string.lower(cause or "")
	if string.find(c, "contact", 1, true) then
		return "contact"
	elseif string.find(c, "projectile", 1, true) then
		return "projectile"
	elseif string.find(c, "pool", 1, true) or string.find(c, "fire", 1, true) or string.find(c, "lava", 1, true) then
		return "hazard"
	end
	return "area"
end

--[[
	DEV combat trace (DevTools "CombatTrace" sets rp.CombatTrace, only for devs, for one
	run): one server Output line per hit on that player, never shown to players. Using it
	is a DEV command, so the run is dev-tainted like every other one.
	  [combat] t=<run time> src=<cause> kind=<contact|projectile|area|hazard|fall> dmg=<n>
	           hp=<before>-><after> phase=<boss state | none> (blocked=<why> when ignored)
]]
local function trace(rp, cause: string?, kind: string, dmg: number, before: number, after: number, blocked: string?)
	local boss = ctx.EnemySpawner and ctx.EnemySpawner.Boss
	local phaseName = boss and boss.Alive and boss.BossState and (tostring(boss.BossState) .. "/p" .. tostring(boss.PhaseIndex or 1)) or "none"
	print(string.format("[combat] t=%.2f src=%s kind=%s dmg=%.1f hp=%.1f->%.1f phase=%s%s", runTime, cause or "Swarm damage", kind, dmg, before, after, phaseName, blocked and (" blocked=" .. blocked) or ""))
end

-- Server-only damage entry point (enemy contact, explosions, boss projectiles, falls).
-- kind: "contact" | "projectile" | "area" | "hazard" | "fall" (nil = read from the cause).
-- Every ordinary hit starts the shared hit protection (Survival.HitProtectSeconds); a hit
-- inside it is ignored, whoever lands it. Falls skip the hit protection and armor.
function RunManager.DamagePlayer(rp, amount: number, cause: string?, kind: string?)
	if amount ~= amount or math.abs(amount) == math.huge or amount <= 0 then return end
	if not RunManager.IsSimulating() or not rp.Alive then
		return
	end
	local tracing = rp.CombatTrace == true -- DEV only (DevTools "CombatTrace")
	local k = kind or hitKind(cause)
	local fall = k == "fall"
	-- an open upgrade / reward panel protects only while Survival.MenuProtection is on (off:
	-- live menus never pause the world nor shield the chooser), or with the old 12-level system
	-- switched back on (RunConfig.Builds.Enabled = false keeps its duo choice protection). A solo
	-- reward hold freezes the whole world instead (RefreshFrozen).
	if (Survival.MenuProtection or not BuildRules.On()) and rp.Paused and rp.Offer ~= nil and Config.Player.LevelUpInvulnerable then
		if tracing then
			trace(rp, cause, k, 0, rp.HP, rp.HP, "choice")
		end
		return
	end
	-- dev godmode (DevTools sets it only for isDev players)
	if rp.Player:GetAttribute("DevGod") == true then
		if tracing then
			trace(rp, cause, k, 0, rp.HP, rp.HP, "god")
		end
		return
	end
	local now = os.clock()
	-- revive protection, a rescue's lockout, a return from a disconnect, an ultimate's guard
	if runTime < rp.InvulnUntil then
		if tracing then
			trace(rp, cause, k, 0, rp.HP, rp.HP, "invulnerable")
		end
		return
	end
	if not fall then
		-- the shared hit protection: one window for every attacker (a crowd can't stack hits)
		if runTime < (rp.HitProtectUntil or 0) then
			if tracing then
				trace(rp, cause, k, 0, rp.HP, rp.HP, "hit-protect")
			end
			return
		end
		rp.HitProtectUntil = runTime + Survival.HitProtectSeconds
		rp.Player:SetAttribute("HitProtectUntil", workspace:GetServerTimeNow() + Survival.HitProtectSeconds)
	end
	-- a reviver who is hit lets go: the revive starts again (Survival.Downed)
	if rp.ReviveTarget then
		cancelRevive(rp.ReviveTarget)
	end
	local hpBefore = rp.HP
	local dmg, taken
	if fall then
		dmg = amount
		taken = amount
	else
		if BuildRules.On() then
			-- the rank system's armor: A / (100 + A) less, A clamped 0..100 (never negative)
			dmg = math.max(Config.Player.MinDamagePerHit, amount * rp.Stats.DamageTaken * BuildRules.ArmorMult(rp.Stats.Armor))
		else
			dmg = math.max(Config.Player.MinDamagePerHit, amount * rp.Stats.DamageTaken - rp.Stats.Armor)
		end
		taken = dmg -- after armor / Iron Plate, before the shield (Barbed Mail scales on it)
		dmg = ctx.ItemSystem.AbsorbHit(rp, dmg) -- Guardian Ward shield first
	end
	if dmg > 0 then
		rp.DamageHistory = rp.DamageHistory or {}
		table.insert(rp.DamageHistory, { Cause = cause or "Swarm damage", Damage = math.min(dmg, rp.HP), Time = runTime })
		while #rp.DamageHistory > 6 or (#rp.DamageHistory > 0 and runTime - rp.DamageHistory[1].Time > 15) do
			table.remove(rp.DamageHistory, 1)
		end
	end
	setHP(rp, rp.HP - dmg)
	if tracing then
		trace(rp, cause, k, dmg, hpBefore, rp.HP, dmg <= 0 and "shield" or nil)
	end
	if dmg > 0 and rp.HP <= 0 then
		rp.DeathCause = cause or "Swarm damage"
	end
	if now - (rp.LastHurtFx or 0) > Config.Player.HurtFlashSeconds then
		rp.LastHurtFx = now
		Fx.PlayerEvent(rp.Player, "hurt")
	end
	if rp.HP <= 0 then
		-- Go down before any on-hurt proc: thorns kills must not Herb-heal a 0 HP player.
		onDowned(rp)
		return
	end
	if fall then
		return -- no on-hurt procs from the ground
	end
	if ctx.FinalStand then ctx.FinalStand.OnHurt(rp) end -- under 10% HP: Final Stand (once per stage)
	ctx.ItemSystem.OnHurt(rp, amount, taken) -- Barbed Mail
end

--[[
	A landing the server saw (Dash.lua's landing check): `drop` = studs from the highest point
	of the fall to the landing. No damage up to Survival.Fall.SafeDrop (18), then PerStud (2%) of
	max HP per extra stud, at most MaxShare (35%) per landing; the Spring Stitch passive (stream B:
	rp.Stats.FallDamageMult = 1 - its reduction) scales it down. Leaps, launch pads, rescues and
	teleports never count (Dash.lua skips those landings).
]]
function RunManager.OnFallLanding(rp, drop: number)
	if phase ~= "Running" or not rp.Alive or rp.Returned or not rp.Stats then
		return
	end
	local stats: any = rp.Stats
	local mult = tonumber(stats.FallDamageMult)
	local reduction = if mult and mult == mult then 1 - mult else tonumber(stats.FallDamageReduction)
	local dmg = SurvivalRules.FallDamage(drop, rp.Stats.MaxHP, reduction)
	rp.LastLanding = { Drop = drop, Damage = dmg, At = runTime }
	if dmg > 0 then
		RunManager.DamagePlayer(rp, dmg, "Fall", "fall")
	end
end

-- A revive product was bought (MonetizationService). Spend the token now if possible: on a
-- hero deciding on the offer, or one eliminated while Roblox's purchase dialog was still open.
-- A downed hero keeps it: it is spent automatically if their bleed runs out.
function RunManager.OnReviveTokenGranted(player: Player)
	local rp = byPlayer[player]
	local data = ctx.DataService.GetData(player)
	local fallen = rp and not rp.Alive and not rp.Downed and (rp.AwaitingRevive or (rp.Eliminated and not rp.ProductReviveUsed))
	if rp and fallen and not rp.Returned and phase == "Running" and data and data.ReviveTokens > 0 then
		data.ReviveTokens -= 1
		rp.ProductReviveUsed = true
		revive(rp, "Revived!")
	else
		RunManager.Notify(player, "Revive saved. It will be used automatically next time you are out.", Color3.fromRGB(255, 230, 120))
	end
	ctx.GoldSystem.SyncProfile(player)
end

------------------------------------------------------------------------------------------
-- Run lifecycle
------------------------------------------------------------------------------------------

local function newRunPlayer(player: Player)
	local data = ctx.DataService.GetData(player)
	-- the hero this run plays: the selected one, or the Weekly Challenge's lent hero (META)
	local heroId = ctx.MetaService and ctx.MetaService.RunHero(mode, data) or data.SelectedCharacter
	-- SwarmV2: the 11 old heroes are hidden; a save that still selects one plays the default class
	if ctx.ClassRegistry then
		heroId = ctx.ClassRegistry.RunHero(heroId)
	end
	-- SwarmV2: the class admitted by MatchAdmission (never a client claim) wins
	local admitted = admittedClass[player]
	if admitted and CharacterData.Characters[admitted] then
		heroId = admitted
	end
	-- the stat sheet's permanent levels: the account upgrades (Revive / Reroll / Skip) from
	-- Meta, the selected hero's own stat track and its Signature (Hero Mastery); the old
	-- shared stat levels left in Meta are never read
	local meta = {}
	for _, id in ipairs(MetaUpgradeData.AccountOrder) do
		local n = tonumber(data.Meta[id])
		if n and n > 0 then
			meta[id] = n
		end
	end
	local track = type(data.HeroUpgrades) == "table" and data.HeroUpgrades[heroId]
	if type(track) == "table" then
		for _, id in ipairs(MetaUpgradeData.HeroOrder()) do
			local n = tonumber(track[id])
			if n and n > 0 then
				meta[id] = n
			end
		end
	end
	-- HEROPOWER second signature skill: free, on once the hero's mastery reaches the rank
	local heroXP = type(data.Heroes) == "table" and type(data.Heroes[heroId]) == "table" and data.Heroes[heroId].XP or 0
	if CharacterData.SecondSkillOn(heroId, (MetaUpgradeData.MasteryFor(heroXP))) then
		meta.SecondSkill = 1
	end
	local function perRun(id: string): number
		local def = MetaUpgradeData.Upgrades[id]
		return (meta[id] or 0) * (def.PerRun or 1)
	end
	local rp = {
		Player = player,
		CharacterId = heroId,
		Meta = meta,
		Weapons = {},
		WeaponOrder = {},
		Passives = {},
		PassiveOrder = {},
		Stats = nil,
		HP = 0,
		Level = 1,
		XP = 0,
		XPNeeded = ctx.XPSystem.XPNeeded(1),
		PendingLevels = 0,
		Offer = nil,
		OfferDeadline = 0,
		Paused = false,
		Alive = true,
		AwaitingRevive = false,
		ReviveDeadline = 0,
		ProductReviveUsed = false,
		RevivesLeft = perRun("Revive"),
		Rerolls = perRun("Reroll") + ctx.MonetizationService.ExtraRerolls(player),
		Skips = perRun("Skip"),
		RerollsMax = perRun("Reroll") + ctx.MonetizationService.ExtraRerolls(player),
		-- VIP rerolls granted so far (a late pass lookup tops up the rest, MonetizationService)
		PassRerolls = ctx.MonetizationService.ExtraRerolls(player),
		SkipsMax = perRun("Skip"),
		Kills = 0,
		Gold = 0, -- gold banked this run (earned minus spent at chests / shrines)
		GoldSpent = 0,
		LastDownTime = 0,
		DamageHistory = {},
		ReviveHeld = false,
		Items = {}, -- run items { [id] = count } (ItemSystem)
		ItemOrder = {},
		ShieldMax = 0,
		DamageDealt = 0,
		TimeSurvived = 0,
		InvulnUntil = 0,
		Facing = Vector3.new(0, 0, -1),
		MoveDir = Vector3.zero,
		SpeedCheckTimer = 0,
		OnObstacleFor = 0, -- seconds the root has been inside an obstacle footprint (on top of it)
		Returned = false,
		PortalChoice = nil :: string?, -- "Next" while the stage portal is open
		PortalOffered = false,
		Committed = false, -- run stats are in the save (results, leaving, shutdown)
		RunId = runId,
		DevTainted = runDevTainted, -- a DEV command was used in this run (see devCommand)
		WinPaid = false,
	}
	ctx.GoldSystem.BeginRun(rp)
	return rp
end

local function resetPlayerAttributes(player: Player)
	for _, name in ipairs({ "HP", "MaxHP", "Level", "XP", "XPNeeded", "Kills", "RunGold", "AuraRadius", "Shield", "ShieldMax", "GoldMult", "FirstRunBoost" }) do
		player:SetAttribute(name, nil)
	end
	player:SetAttribute("InRun", false)
	player:SetAttribute("Alive", nil)
	player:SetAttribute("Paused", false)
	for _, name in ipairs({ "ChoiceOpen", "ChoiceId", "ChoiceOfferId", "ChoiceProtectedUntil", "ChoiceTimerPaused", "ChoiceDeferred", "ChoiceGroup" }) do
		player:SetAttribute(name, nil)
	end
	player:SetAttribute("AuraEvo", nil)
	player:SetAttribute("SteadyAim", nil)
	player:SetAttribute("SteadyAimBonus", nil)
	player:SetAttribute("ReviveProgress", nil)
	player:SetAttribute("PartnerRevivesLeft", nil)
	player:SetAttribute("AwaitingRevive", nil)
	player:SetAttribute("CharacterId", nil)
	-- [stream E1] survival state
	for _, name in ipairs({ "Downed", "BleedLeft", "Eliminated", "Spectating", "HitProtectUntil", "ReviveProtectUntil", "SpeedBoost", "SpeedBoostUntil" }) do
		player:SetAttribute(name, nil)
	end
end

local function placeOnArena(arena, i: number, n: number): Vector3
	local a = (i / n) * math.pi * 2
	return arena.Center + Vector3.new(math.cos(a), 0, math.sin(a)) * (n > 1 and Config.Run.ArenaSpawnSpread or 0)
end

--[[
	The first run's welcome (Config.FirstRun.Boost): an account's very first run, Solo, no
	curses / Endless / harder difficulty, not DEV-tainted. Then: a cheap first level, a
	showcase first offer (LevelUpSystem), gentle first waves (EnemySpawner) and a one-time
	gold bonus on the results (saveRunStats, save flag FirstRunBonus). Called before
	Stats.Runs counts the run, so it can happen once per account.
]]
local function firstRunWelcome(rp, data, teamSize: number): boolean
	local cfg = (Config :: any).FirstRun
	if not cfg or cfg.AutoStart ~= true or cfg.Boost ~= true or teamSize ~= 1 or mode ~= cfg.Mode then
		return false
	end
	if data.TutorialDone == true or data.FirstRunBonus == true or type(data.Stats) ~= "table" or (tonumber(data.Stats.Runs) or 0) > 0 then
		return false
	end
	if rp.DevTainted or rp.Endless or rp.Daily or #ctx.RunModifiers.Active() > 0 or ctx.RunModifiers.IsEndless() then
		return false
	end
	local difficulty = ctx.RunModifiers.DifficultyId and ctx.RunModifiers.DifficultyId() or "Standard"
	return difficulty == "Standard"
end

-- The run's first-run welcome is on (Solo: the only run player has rp.FirstRun).
function RunManager.IsFirstRunWelcome(): boolean
	local rp = runPlayers[1]
	return #runPlayers == 1 and rp ~= nil and rp.FirstRun == true and not rp.DevTainted
end

--[[
	The tutorial run's portal reveal waits (Config.FirstRun.RevealCapSeconds, StageManager):
	with the first-run flow on (Config.FirstRun.AutoStart, RevealWaitsForPick), true while a Solo run's only player still has the tutorial to finish (save TutorialDone
	not true, tips not switched off, not DEV-tainted) and has not picked a first level-up
	card yet (a level banked behind an open or deferred panel does not count). Read live, so
	SKIP TIPS or switching tips off mid-run ends the wait at once. Co-op: never.
]]
function RunManager.TutorialRevealHold(): boolean
	local cfg = (Config :: any).FirstRun
	-- the first-run flow's switch (AutoStart; the preview keeps it off unless --set firstrun=on)
	if not cfg or cfg.AutoStart ~= true or cfg.RevealWaitsForPick == false then
		return false
	end
	local rp = runPlayers[1]
	if #runPlayers ~= 1 or rp == nil or rp.DevTainted or not rp.Alive then
		return false
	end
	local data = ctx.DataService.GetData(rp.Player)
	if not data or data.TutorialDone == true then
		return false
	end
	if type(data.Settings) == "table" and data.Settings.Tips == false then
		return false
	end
	return (tonumber(rp.Level) or 1) - (tonumber(rp.PendingLevels) or 0) < 2
end

-- The lobby arena is one global pick checked only against whoever changed it, so a run's
-- arena is re-checked against the STARTER's own BestStage; otherwise the first arena.
local function arenaForStarter(who: Player?, name: string): string
	local def = (Config.Arenas :: any)[name]
	local data = who and ctx.DataService.GetData(who)
	if def and data and (data.Stats.BestStage or 0) >= (def.RequiredBestStage or 0) then
		return name
	end
	return Config.Arenas.Order[1]
end

-- One player's run setup (beginRun for each starter; AddLatePlayer for a late admitted
-- arrival). `count` = team size used for team-only rules; `pos` overrides the spawn spot.
local function setupRunPlayer(player: Player, i: number, count: number, arena: any, pos: Vector3?, team: { Player })
	local rp = newRunPlayer(player)
	if ctx.TeamPingService then ctx.TeamPingService.Assign(rp, i) end
	if ctx.RunServers and ctx.RunServers.RegisterRun then ctx.RunServers.RegisterRun(rp) end
	ctx.AchievementService.OnRunStart(player)
	table.insert(runPlayers, rp)
	byPlayer[player] = rp
	local spawnPos = pos or (placeOnArena(arena, i, count) + Vector3.new(0, 3.5, 0))
	local model = spawnCharacter(player, CFrame.new(spawnPos), false, rp.CharacterId)
	RunManager.AttachCharacter(rp, model)

	local character = CharacterData.Characters[rp.CharacterId] or CharacterData.Characters[CharacterData.Default]
	ctx.LevelUpSystem.AddWeapon(rp, character.StartWeapon)
	ctx.RunModifiers.SetupRunPlayer(rp) -- daily: scored / practice + the starting bonus
	if ctx.MetaService then
		ctx.MetaService.SetupRunPlayer(rp, mode, team) -- META: worn Sigils, the run's team
	end
	ctx.LevelUpSystem.RecomputeStats(rp)
	setHP(rp, rp.Stats.MaxHP)
	player:SetAttribute("CharacterId", rp.CharacterId) -- the HUD's team list shows the hero
	player:SetAttribute("InRun", true)
	player:SetAttribute("Alive", true)
	player:SetAttribute("Level", 1)
	player:SetAttribute("XP", 0)
	player:SetAttribute("XPNeeded", rp.XPNeeded)
	player:SetAttribute("Kills", 0)
	player:SetAttribute("RunGold", 0)
	-- chest / shrine prices are shown x this (gamepass owners earn and pay more)
	player:SetAttribute("GoldMult", ctx.MonetizationService.GoldMultiplier(player))
	ctx.ItemSystem.Send(rp)
	-- [stream E1] downed / eliminated state (all false at the start)
	publishDown(rp)
	setProgress(rp, 0)
	player:SetAttribute("HitProtectUntil", 0)
	player:SetAttribute("ReviveProtectUntil", 0)
	ctx.WeaponSystem.OnInventoryChanged(rp)
	ctx.LevelUpSystem.SendInventory(rp)
	RunManager.ApplyMovement(rp)
	ctx.RunModifiers.AfterSetup(rp) -- daily Head Start: its level-ups

	local data = ctx.DataService.GetData(player)
	if data then
		-- before Runs counts this run: an account's very first run gets the welcome
		if firstRunWelcome(rp, data, count) then
			rp.FirstRun = true
			rp.XPNeeded = math.max(1, math.floor(tonumber((Config :: any).FirstRun.FirstLevelXP) or rp.XPNeeded))
			player:SetAttribute("XPNeeded", rp.XPNeeded)
			player:SetAttribute("FirstRunBoost", true)
		end
		-- the interactive first-run walkthrough (Walkthrough.lua; Solo only, once)
		if ctx.Walkthrough then
			ctx.Walkthrough.Consider(rp, data, count, mode)
		end
		-- funnel analytics: the account's first / second run really started (pcalled inside)
		if ctx.Analytics then
			ctx.Analytics.OnRunStart(player, tonumber(data.Stats.Runs) or 0)
		end
		data.Stats.Runs += 1
	end
	return byPlayer[player]
end

local function beginRun(here: boolean?)
	local runStarter = starter -- whose curses the run uses (Solo / Daily: the only player)
	local list = {}
	-- join order (not pairs order): the starter is list[1] and spawn spots are stable
	for _, player in ipairs(joinedOrder) do
		if joined[player] and player.Parent and ctx.DataService.GetData(player) and #list < maxPlayers() then
			table.insert(list, player)
		end
	end
	table.clear(joined)
	table.clear(joinedOrder)
	starter = nil
	publishJoined()
	if #list == 0 then
		setPhase("Lobby")
		return
	end
	local runArena = arenaForStarter(runStarter or list[1], selectedArena)
	-- live game: the team plays on its own private run server (RunServers saves and
	-- teleports them; this lobby is free again at once). `here` = play on this server.
	if not here and ctx.RunServers and ctx.RunServers.SendToRun(list, mode, runStarter or list[1], runArena) then
		setPhase("Lobby")
		return
	end

	-- curses (the starter's pick) or the Daily Challenge's fixed setup
	local daily = ctx.RunModifiers.BeginRun(mode, runStarter or list[1])
	-- stage 1: the lobby's arena with its portal (StageManager also sets EnemyAI's arena);
	-- the daily has its own arena tour and boss order
	local arena = ctx.StageManager.BeginRun(daily and daily.Arenas[1] or ctx.RunModifiers.WeeklyArena() or runArena, daily)

	runTime = 0
	table.clear(disconnected)
	frozen = false
	menuPaused = false
	totalKills = 0
	bossKills = 0
	runSerial += 1
	runId = string.format("%s:%d:%d", game.JobId, os.time(), runSerial)
	runDevTainted = false
	-- dev state left over from an earlier run (god mode, forced boss) taints this one
	if ctx.StageManager.HasForcedBoss() then
		runDevTainted = true
	end
	for _, player in ipairs(list) do
		if player:GetAttribute("DevGod") == true then
			runDevTainted = true
		end
		-- a profile boosted by lobby DEV commands taints the run like a DEV tool would
		-- (owner OK 2026-10-05, audit SEC-13)
		local pdata = ctx.DataService.GetData(player)
		if pdata and pdata.DevBoosted == true then
			runDevTainted = true
		end
	end
	state:SetAttribute("Frozen", false)
	state:SetAttribute("RunTime", 0)
	setPhase("Running")

	for i, player in ipairs(list) do
		setupRunPlayer(player, i, #list, arena, nil, list)
	end
	state:SetAttribute("Participants", #runPlayers)
	ctx.RunModifiers.Publish()
	if daily then
		local first = runPlayers[1]
		RunManager.Broadcast("DAILY CHALLENGE", Color3.fromRGB(255, 230, 150), true, { Id = "run.start.daily", Class = "Info" })
		RunManager.Broadcast(first and first.DailyScored and "Scored attempt: make it count!" or "Practice run: not scored.", Color3.fromRGB(255, 220, 120), nil, { Id = "run.daily.scored" })
	end
	-- "STAGE 1" itself is the client HUD's stage banner (Hud.lua), not a broadcast
	local curses = ctx.RunModifiers.Active()
	if #curses > 0 then
		local names = {}
		for _, id in ipairs(curses) do
			table.insert(names, CurseData.Curses[id].Name)
		end
		RunManager.Broadcast(string.format("Curses: %s · %s gold", table.concat(names, ", "), CurseData.GoldText(CurseData.GoldMult(ctx.RunModifiers.Active()))), Color3.fromRGB(230, 150, 160), nil, { Id = "run.curses" })
	end
	if ctx.RunModifiers.IsEndless() then
		RunManager.Broadcast("ENDLESS: no way home, only deeper.", Color3.fromRGB(190, 160, 255), true, { Id = "run.start.endless", Class = "Info" })
	end
	-- no portal objective notice here: before the reveal the portal can't be found yet (the
	-- HUD pill says "Survive until the portal opens"); the reveal headline (StageUI, id
	-- portal.reveal) carries the instruction and the real stage boss's name
end

--[[
	SwarmV2 late arrival: an admitted player who reached this match server after the run
	started (inside the arrival grace). Joins the running run once, next to a living
	teammate (or the arena spawn), with the same setup as a starter. The run clock is not
	reset. False when the run isn't running, the team is full or they're already in.
]]
function RunManager.AddLatePlayer(player: Player): boolean
	if phase ~= "Running" or byPlayer[player] or not player.Parent or not ctx.DataService.GetData(player) then
		return false
	end
	if #runPlayers >= math.max(maxPlayers(), 4) then
		return false
	end
	local pos: Vector3? = nil
	for _, other in ipairs(runPlayers) do
		if other.Alive and other.Root then
			pos = other.Root.Position + Vector3.new(4, 3.5, 0)
			break
		end
	end
	local arena = MapBuilder.GetArena()
	if not pos and not arena then
		return false
	end
	local team = { player }
	for _, other in ipairs(runPlayers) do
		table.insert(team, other.Player)
	end
	setupRunPlayer(player, #runPlayers + 1, #runPlayers + 1, arena, pos, team)
	state:SetAttribute("Participants", #runPlayers)
	return true
end

-- Who started the countdown (their curses are on show), or nil.
function RunManager.GetStarter(): Player?
	return starter
end

-- Arena `name` may be picked in the lobby (Config.Arenas[name].RequiredBestStage).
local function arenaUnlocked(stats, name: string): boolean
	local def = (Config.Arenas :: any)[name]
	return def ~= nil and (stats.BestStage or 0) >= (def.RequiredBestStage or 0)
end

--[[
	Writes a player's run into their save once (kills, best time, furthest stage, a win
	with the arena unlocks it brings). Returns (newBestTime, unlockedArenaName?).
	Leaving, shutdown, defeat and the portal all go through here; rp.Committed keeps a
	run from being counted twice.
]]
local function saveRunStats(rp, won: boolean): (boolean, string?)
	if rp.Committed then
		return false, nil
	end
	rp.Committed = true
	local data = ctx.DataService.GetData(rp.Player)
	if not data then
		return false, nil
	end
	local t = (rp.Alive or rp.AwaitingRevive) and runTime or rp.TimeSurvived
	ctx.GoldSystem.SettleRun(rp, rp.Extracted == true, ctx.StageManager.StagesCleared(), t)
	data.RunReconnect = nil
	local newBest, unlocked = false, nil
	if rp.DevTainted then
		-- a DEV command was used: no records, unlocks, daily score, account XP or boards
		data.TutorialDone = true
		rp.CommitInfo = {}
		return false, nil
	end
	-- the first run's one-time welcome bonus (Config.FirstRun.BonusGold; save flag)
	if rp.FirstRun and data.FirstRunBonus ~= true then
		data.FirstRunBonus = true
		local bonus = math.max(0, math.floor(tonumber((Config :: any).FirstRun.BonusGold) or 0))
		data.Gold += bonus
		rp.FirstRunBonusPaid = bonus
	end
	data.Stats.TotalKills += math.max(0, rp.Kills - (rp.DisconnectRecordedKills or 0))
	data.Stats.MostKills = math.max(data.Stats.MostKills or 0, rp.Kills)
	if t > data.Stats.BestTime then
		data.Stats.BestTime = math.floor(t)
		newBest = true
	end
	local lockedBefore = {}
	for _, name in ipairs(Config.Arenas.Order) do
		lockedBefore[name] = not arenaUnlocked(data.Stats, name)
	end
	data.Stats.BestStage = math.max(data.Stats.BestStage or 0, ctx.StageManager.GetStage())
	for _, name in ipairs(Config.Arenas.Order) do
		if lockedBefore[name] and arenaUnlocked(data.Stats, name) then
			unlocked = Config.Arenas[name].DisplayName
		end
	end
	if won then
		data.Stats.Wins += 1
	end
	-- the first run is the tutorial run: tips stop after it (Settings > Replay tips);
	-- SmartTutorial: after Config.Tutorial.Smart.Runs runs (save TutorialStep counts them)
	if (Config :: any).Features.SmartTutorial == true and data.TutorialDone ~= true then
		data.TutorialStep = (tonumber(data.TutorialStep) or 0) + 1
		data.TutorialDone = data.TutorialStep >= ((Config :: any).Tutorial.Smart.Runs or 2)
	else
		data.TutorialDone = true
	end
	-- retention: the daily score, account XP, the leaderboards (results show the first two)
	local cleared = ctx.StageManager.StagesCleared()
	if ctx.RunModifiers.CompleteDifficulty then
		ctx.RunModifiers.CompleteDifficulty(rp.Player, cleared, won and not rp.Endless)
	end
	local dailyInfo = ctx.RunModifiers.CommitDaily(rp, cleared, ctx.StageManager.LastClearTime(), t)
	local accountInfo = ctx.AccountService.AwardRun(rp.Player, {
		Seconds = t,
		Stages = cleared,
		Kills = rp.Kills,
		Bosses = bossKills,
		Won = won,
		CurseMult = ctx.RunModifiers.GoldMult(),
		DailyScored = rp.DailyScored == true,
	})
	-- Hero Mastery: the same XP, only for the hero played (DEV runs returned above)
	local masteryInfo = ctx.AccountService.AwardMastery and ctx.AccountService.AwardMastery(rp.Player, rp.CharacterId, accountInfo and accountInfo.Gained or 0) or nil
	-- the same score formula for both modes; Standard and Endless rank on separate boards
	local score = ctx.LeaderboardService.RunScore({ Cleared = cleared, Bosses = bossKills, Level = rp.Level, Kills = rp.Kills, Seconds = t })
	local scoreBoard = rp.Endless and "ScoreEndless" or "Score"
	local bestKey = rp.Endless and "BestScoreEndless" or "BestScore"
	local scoreBefore = tonumber(data.Stats[bestKey]) or 0
	data.Stats[bestKey] = math.max(scoreBefore, score)
	local levelBefore = data.Stats.BestLevel or 0
	data.Stats.BestLevel = math.max(levelBefore, rp.Level or 1)
	ctx.LeaderboardService.Submit(rp.Player, scoreBoard, score, nil, rp.RunId)
	ctx.LeaderboardService.Submit(rp.Player, "BestStage", ctx.StageManager.GetStage(), nil, rp.RunId)
	ctx.LeaderboardService.Submit(rp.Player, "Kills", rp.Kills, nil, rp.RunId)
	ctx.LeaderboardService.Submit(rp.Player, "Level", rp.Level or 1, nil, rp.RunId)
	-- total time played (the lobby PLAYTIME board): seconds of clean runs only, counted
	-- here by the server; DEV-tainted runs returned above and never add to it
	data.Stats.TimePlayed = math.floor((tonumber(data.Stats.TimePlayed) or 0) + math.max(0, t))
	ctx.LeaderboardService.Submit(rp.Player, "Playtime", data.Stats.TimePlayed, nil, rp.RunId)
	-- META (docs/features/META.md): Sigils found, the weekly / team boards, season XP, the
	-- collection, titles. Clean runs only (DEV-tainted runs returned above).
	local metaInfo = ctx.MetaService and ctx.MetaService.CommitRun(rp, {
		Won = won, Score = score, Cleared = cleared, AccountXP = accountInfo and accountInfo.Gained or 0, Mode = mode,
	}) or nil
	-- daily quests (docs/next/DAILY_QUESTS.md): this run's progress, clean runs only
	if ctx.DailyQuests then
		ctx.DailyQuests.CommitRun(rp, { Won = won, Mode = mode, Seconds = t })
	end
	-- invite rewards (InviteRewards.lua): a referred new player finished a clean run
	if ctx.InviteRewards then
		ctx.InviteRewards.OnRunCommitted(rp.Player, data, { Seconds = t, Won = won })
	end
	rp.CommitInfo = { Daily = dailyInfo, Account = accountInfo, Mastery = masteryInfo, Score = score, ScoreBoard = scoreBoard, NewBestLevel = (rp.Level or 1) > levelBefore and levelBefore > 0,
		-- beat the saved personal best score of this board (not on the first scored run)
		NewBestScore = score > scoreBefore and scoreBefore > 0, Meta = metaInfo }
	return newBest, unlocked
end

-- The run's build for the results screen: weapons (level, evolved), passives (level).
local function buildSummary(rp)
	local weapons, passives = {}, {}
	for _, id in ipairs(rp.WeaponOrder or {}) do
		local w = rp.Weapons[id]
		if w then
			table.insert(weapons, { Id = id, Level = w.Level, Evolved = w.Evolved == true })
		end
	end
	for _, id in ipairs(rp.PassiveOrder or {}) do
		local level = rp.Passives[id]
		if level then
			table.insert(passives, { Id = id, Level = level })
		end
	end
	return { Weapons = weapons, Passives = passives }
end

local function commas(n: number): string
	local out = tostring(math.floor(n)):reverse():gsub("(%d%d%d)", "%1,"):reverse()
	return (out:gsub("^,", ""))
end

-- The first run's results: the one-time bonus paid ({ Bonus }) and a NEXT GOAL that
-- points at the first hero sold for gold (same shape as NextGoal.Pick), or nil, nil
-- when this was not the first run.
local function firstRunResult(rp, data): ({ [string]: any }?, { [string]: any }?)
	if not rp.FirstRun or not rp.FirstRunBonusPaid or not data then
		return nil, nil
	end
	local gold = math.max(0, tonumber(data.Gold) or 0)
	local owned = type(data.OwnedCharacters) == "table" and data.OwnedCharacters or {}
	local goal = nil
	for _, id in ipairs(CharacterData.Order) do
		local def = CharacterData.Characters[id]
		if def and (tonumber(def.Cost) or 0) > 0 and not def.Unlock and not owned[id] then
			local cost = def.Cost
			goal = {
				Kind = "BuyHero", Icon = "hero:" .. id,
				Text = string.format("Unlock %s at %s gold", def.Name, commas(cost)),
				Sub = "or play again",
				Progress = math.clamp(gold / cost, 0, 1),
				ProgressText = string.format("%s / %s gold", commas(gold), commas(cost)),
			}
			break
		end
	end
	return { Bonus = rp.FirstRunBonusPaid }, goal
end

--[[
	Commits a finished run and shows the results screen. portal = left through an open
	portal (WinBonus + StageClearBonus per cleared stage, always paid); it counts as a WIN
	only with Config.Stages.WinMinStages stages cleared. inLobby = the player is going
	straight back to the lobby menu (the results panel then sits over the menu).
]]
local function finishPlayer(rp, portal: boolean, inLobby: boolean)
	local player: Player = rp.Player
	local cleared = ctx.StageManager.StagesCleared()
	local reached = math.max(1, ctx.StageManager.GetStage())
	local won = portal and not rp.Endless and cleared >= Config.Stages.WinMinStages
	if rp.Alive or rp.AwaitingRevive then
		rp.TimeSurvived = runTime
	end
	if portal and not rp.WinPaid then
		rp.WinPaid = true
		ctx.GoldSystem.AddRunGold(rp, Config.Gold.WinBonus + Config.Gold.StageClearBonus * cleared)
	end
	rp.Extracted = portal
	local data = ctx.DataService.GetData(player)
	local bestStageBefore = data and (data.Stats.BestStage or 0) or 0
	local newBest, unlocked = saveRunStats(rp, won)
	local info = rp.CommitInfo
	if won then
		Events.Fire("RunWon", player, { Stages = cleared })
	end
	local achievements = ctx.AchievementService.TakeRunUnlocks(player)
	if data then
		data.LastRun = {
			Won = won, Portal = portal, Mode = mode, CharacterId = rp.CharacterId,
			Time = math.floor(rp.TimeSurvived), Stage = reached, StagesCleared = cleared,
			Kills = rp.Kills, Level = rp.Level, Gold = rp.GoldSettlement and (rp.GoldSettlement.Retained + (rp.GoldSettlement.Survival or 0)) or 0,
			Difficulty = ctx.RunModifiers.DifficultyId and ctx.RunModifiers.DifficultyId() or "Standard",
			DeathCause = not portal and not rp.Abandoned and not rp.Alive and rp.DeathCause or nil,
		}
		task.spawn(ctx.DataService.ForceSave, player)
	end
	if not player.Parent then
		return
	end
	Remotes.FireClient("PortalOffer", player, { Close = true })
	local firstInfo, firstGoal = firstRunResult(rp, data)
	Remotes.FireClient("RunResult", player, {
		Won = won,
		Portal = portal, -- left through the portal (a win only from WinMinStages)
		WinMinStages = Config.Stages.WinMinStages,
		Time = math.floor(rp.TimeSurvived),
		Kills = rp.Kills,
		Gold = rp.GoldSettlement and rp.GoldSettlement.Retained or rp.Gold,
		GoldEarned = rp.GoldSettlement and rp.GoldSettlement.Earned or rp.Gold,
		GoldLost = rp.GoldSettlement and rp.GoldSettlement.Lost or 0,
		GoldRetention = rp.GoldSettlement and rp.GoldSettlement.Rate or 1,
		GoldSurvival = rp.GoldSettlement and rp.GoldSettlement.Survival or 0, -- always kept (own line)
		GoldGroup = rp.GoldSettlement and rp.GoldSettlement.Group or 0, -- Roblox group member bonus (GroupBonus, own line)
		GoldPrestige = rp.GoldSettlement and rp.GoldSettlement.Prestige or 0, -- the hero's prestige stars (Prestige.lua, own line)
		DeathCause = not portal and not rp.Abandoned and not rp.Alive and rp.DeathCause or nil,
		DamageHistory = not portal and not rp.Abandoned and rp.DamageHistory or {},
		Difficulty = ctx.RunModifiers.DifficultyId and ctx.RunModifiers.DifficultyId() or "Standard",
		GoldSpent = rp.GoldSpent or 0,
		Items = ctx.ItemSystem.Summary(rp),
		Level = rp.Level,
		Damage = math.floor(rp.DamageDealt),
		Arena = ctx.StageManager.ArenaDisplayName() .. ((mode == "Duo" or mode == "Trio" or mode == "Daily" or mode == "Weekly") and (" (" .. mode .. ")") or ""),
		Endless = rp.Endless == true, -- an Endless run (no win; scored on ScoreEndless)
		Mode = mode, -- REPLAY starts this mode again (StartRun from the lobby)
		CharacterId = rp.CharacterId,
		Build = buildSummary(rp),
		BossKills = bossKills, -- Queens beaten this run (the whole team's)
		BossFight = ctx.StageManager.IsBossFight(), -- the run ended during a Queen fight
		Stage = reached,
		StagesCleared = cleared,
		NewBest = newBest,
		NewBestStage = data ~= nil and not rp.DevTainted and reached > bestStageBefore and reached > 1,
		DevRun = rp.DevTainted == true, -- a DEV command was used: nothing public was recorded
		Abandoned = rp.Abandoned == true, -- left from the pause menu (MAIN MENU)
		Score = info and info.Score or nil, -- the run's high-score value (none for dev runs)
		ScoreBoard = info and info.ScoreBoard or nil, -- "Score" | "ScoreEndless"
		NewBestLevel = info and info.NewBestLevel or nil, -- beat the saved highest level
		NewBestScore = info and info.NewBestScore or nil, -- beat the saved personal best score (Score / ScoreEndless)
		Unlocked = unlocked,
		Achievements = achievements, -- unlocked this run: { {Id, Name, Reward, Icon} }
		Curses = table.clone(ctx.RunModifiers.Active()), -- the run's curses (CurseData ids)
		CurseGold = CurseData.GoldMult(ctx.RunModifiers.Active()), -- curses only (difficulty gold is separate)
		Account = info and info.Account or nil, -- { Gained, Parts, From, To, Into, Need, Rewards }
		Mastery = info and info.Mastery or nil, -- { Hero, Gained, From, To } (Hero Mastery)
		Daily = info and info.Daily or nil, -- { Scored, Score, Text, NewBest, Best }
		-- the results NEXT GOAL card, from the settled save (display only; nil for DEV runs)
		FirstRun = firstInfo, -- { Bonus }: the first run's one-time gold bonus (Config.FirstRun)
		NextGoal = firstGoal or data and not rp.DevTainted and NextGoal.Pick(data, { Hero = rp.CharacterId, RunGold = rp.GoldSettlement and (rp.GoldSettlement.Retained + (rp.GoldSettlement.Survival or 0)) or 0 }) or nil,
		Seconds = Config.Run.ResultsSeconds,
		InLobby = inLobby,
	})
end

-- Everyone fell (won = false). A portal win never comes through here.
function RunManager.EndRun(won: boolean)
	if phase ~= "Running" then
		return
	end
	frozen = false
	menuPaused = false
	state:SetAttribute("Frozen", false)
	state:SetAttribute("LevelUpPause", false)
	setPhase("Results")
	resultsTimer = Config.Run.ResultsSeconds

	for _, rp in ipairs(runPlayers) do
		ctx.LevelUpSystem.Cancel(rp)
		finishPlayer(rp, won, false)
		setAwaiting(rp, false)
		RunManager.ApplyMovement(rp)
	end
	ctx.StageManager.EndRun() -- the results are out: the stage loop stops here
	RunManager.Broadcast(won and "VICTORY!" or "THE SWARM WINS...", won and Color3.fromRGB(255, 220, 80) or Color3.fromRGB(255, 80, 80), true, { Id = "run.end", Class = "Info" })
end

-- `how` (RunServers: when a run server sends the player home): "results" (the defeat
-- results counted down), "menu" (MAIN MENU on the results), "replay" (REPLAY on the
-- results: stays for the new run) or "portal" (the results sit over the lobby menu: portal
-- return, pause MAIN MENU). Attributes set here and in OnBackInLobby replicate together,
-- so the client sees InRun = false and the travel cover in the same frame.
local function returnPlayerToLobby(rp, how: string?)
	if rp.Returned then
		return
	end
	rp.Returned = true
	local player: Player = rp.Player
	player:SetAttribute("DevGod", nil) -- invincibility lasts one run
	if player.Parent then
		resetPlayerAttributes(player)
		if not lobbySpawnSuppressed then spawnCharacter(player, lobbySpawnCFrame(), true) end
		ctx.GoldSystem.SyncProfile(player)
		if RunManager.OnReturnHome then
			-- SwarmV2: rewards are committed by now (rp.Committed); the entry module sends
			-- the player back through MatchAdmission.ReturnToLobby
			admittedClass[player] = nil
			RunManager.OnReturnHome(player, how or "portal")
		elseif ctx.RunServers then
			ctx.RunServers.OnBackInLobby(player, how or "portal")
		end
	end
end

-- Clears the run world and goes back to the Lobby phase.
local function returnAll(how: string?)
	-- [stream E1] a hero still inside their disconnect window when the run ends: settled once
	for userId, entry in pairs(disconnected) do
		if entry.Window and entry.Player and not entry.Player.Committed and entry.Player.RunId == runId then
			settleAway(entry.Player, userId)
		end
	end
	table.clear(disconnected)
	state:SetAttribute("AwayIds", "")
	state:SetAttribute("AwayUntil", 0)
	RunManager.SoloAway = nil -- QuickResume: a held solo run ends with the world
	for _, rp in ipairs(runPlayers) do
		returnPlayerToLobby(rp, how)
	end
	table.clear(runPlayers)
	table.clear(byPlayer)
	ctx.EnemySpawner.DespawnAll()
	ctx.WeaponSystem.Clear()
	ctx.XPSystem.Clear()
	ctx.EnemyAI.SetArena(nil)
	ctx.StageManager.EndRun()
	ctx.StageManager.ForceBoss(nil)
	ctx.RunModifiers.EndRun()
	MapBuilder.DestroyArena()
	HeightGrid.Clear() -- no arena: every height query is flat again
	MapBuilder.ApplyLighting("Lobby")
	frozen = false
	menuPaused = false
	state:SetAttribute("Frozen", false)
	state:SetAttribute("LevelUpPause", false)
	state:SetAttribute("ChoosingIds", "")
	state:SetAttribute("ChoosingNames", "")
	state:SetAttribute("Participants", 0)
	state:SetAttribute("RunTime", 0)
	setPhase("Lobby")
end

-- Takes a record out of the running run (portal return, leaving the game). Other
-- systems may still hold it (enemy targets, delayed whip slashes), so it is made inert.
local function removeFromRun(rp)
	clearReviveLinks(rp) -- [stream E1] a revive they held (or received) stops
	rp.Alive = false
	rp.AwaitingRevive = false
	ctx.WeaponSystem.ClearOwner(rp)
	local i = table.find(runPlayers, rp)
	if i then
		table.remove(runPlayers, i)
	end
	if byPlayer[rp.Player] == rp then
		byPlayer[rp.Player] = nil
	end
	state:SetAttribute("Participants", #runPlayers)
	if menuPaused and #runPlayers > 1 then
		menuPaused = false
	end
	RunManager.RefreshFrozen()
end

function RunManager.OnBossKilled(pos: Vector3)
	if phase ~= "Running" then
		return
	end
	bossKills += 1
	for _, rp in ipairs(runPlayers) do
		if not rp.Returned then
			Events.Fire("BossKilled", rp.Player) -- the whole team beat her (fallen ones too)
		end
	end
	ctx.StageManager.OnBossKilled(pos)
end

--[[
	RETURN TO LOBBY at an open portal: the player's run ends as a win right now (gold
	bonus, stats, results over the lobby menu) while the others may go on. The last one
	out closes the run.
]]
function RunManager.ReturnThroughPortal(rp)
	if phase ~= "Running" or rp.Returned or not byPlayer[rp.Player] then
		return
	end
	ctx.LevelUpSystem.Cancel(rp)
	EncounterDirector.PlayerOut(rp, "Portal")
	finishPlayer(rp, true, true)
	removeFromRun(rp)
	rp.Root = nil
	returnPlayerToLobby(rp)
	local cleared = ctx.StageManager.StagesCleared()
	RunManager.Broadcast(string.format("%s left through the portal (%d stage%s cleared).", rp.Player.DisplayName, cleared, cleared == 1 and "" or "s"), Color3.fromRGB(255, 220, 120), nil, { Id = "team.left." .. rp.Player.UserId })
	if #runPlayers == 0 then
		returnAll()
	end
end

--[[
	MAIN MENU in the pause menu (confirmed on the client): the player gives up the run now.
	It is committed like leaving the game (saveRunStats as a loss: kills, time, account XP
	and gold already banked stay; no win, no win bonus, no portal), the results sit over
	the lobby menu, and the player is taken out of the run. Teammates go on; the last one
	out clears the run world (enemies, projectiles, gems, arena) through returnAll.
]]
function RunManager.AbandonRun(rp)
	if phase ~= "Running" or rp.Returned or not byPlayer[rp.Player] then
		return
	end
	ctx.LevelUpSystem.Cancel(rp)
	RunManager.EndReward(rp)
	Remotes.FireClient("ReviveOffer", rp.Player, { Close = true })
	rp.Abandoned = true
	EncounterDirector.PlayerOut(rp, "Abandon")
	finishPlayer(rp, false, true)
	removeFromRun(rp)
	rp.Root = nil
	returnPlayerToLobby(rp)
	if #runPlayers == 0 then
		returnAll()
	else
		RunManager.Broadcast(rp.Player.DisplayName .. " returned to the main menu.", Color3.fromRGB(255, 200, 120), nil, { Id = "team.left." .. rp.Player.UserId })
		ctx.StageManager.OnRosterChanged()
		RunManager.ResolveRescue() -- [stream E1] downed teammates nobody can reach now are out
		checkEnd() -- only fallen teammates left: their run ends as a defeat
	end
end

-- Nobody living goes on: everyone still listed (fallen teammates) finishes as a win.
function RunManager.FinishFromPortal()
	if phase ~= "Running" then
		return
	end
	for _, rp in ipairs(runPlayers) do
		ctx.LevelUpSystem.Cancel(rp)
		Remotes.FireClient("ReviveOffer", rp.Player, { Close = true })
		finishPlayer(rp, true, true)
	end
	returnAll()
end

-- Moves a run player to a floor point (travel, dev teleport) without the speed check
-- snapping them back.
function RunManager.TeleportPlayer(rp, floorPos: Vector3)
	if HeightGrid.IsActive() then
		floorPos = HeightGrid.Ground(floorPos) -- onto the ground at that x, z (terraces, ramps)
	end
	local pos = floorPos + Vector3.new(0, 3.5, 0)
	local char: Model? = rp.Character
	local root: BasePart? = rp.Root
	if char and root and root.Parent and char.Parent then
		char:PivotTo(CFrame.new(pos) * root.CFrame.Rotation)
		root.AssemblyLinearVelocity = Vector3.zero
	else
		local m = spawnCharacter(rp.Player, CFrame.new(pos), false, rp.CharacterId)
		RunManager.AttachCharacter(rp, m)
	end
	rp.LastValidPos = pos
	rp.SafePos = pos
	rp.SpeedCheckTimer = 0
	-- [stream E1] a teleport is no fall: Dash.lua's landing check starts over (no fall damage,
	-- no landing ability from the arrival)
	rp.AirReset = true
end

--[[
	Travel to the next stage (StageManager, behind the fade): everyone left in the run
	moves to the new arena's spawn ring, living players are healed to at least
	TravelHealFraction, fallen ones (also those still on the revive offer) stand up with
	ReviveOnTravelHPFraction. Level, XP, weapons, passives and gold are kept.
]]
-- stay: single-map stage change, nobody is teleported (the heal / revive still happens).
function RunManager.TravelPlayers(arena, stay: boolean?)
	local S = Config.Stages
	local n = #runPlayers
	for i, rp in ipairs(runPlayers) do
		rp.PortalChoice = nil
		rp.PortalOffered = false
		if not rp.Alive then
			if rp.AwaitingRevive then
				Remotes.FireClient("ReviveOffer", rp.Player, { Close = true })
			end
			rp.Alive = true
			setAwaiting(rp, false)
			clearReviveLinks(rp)
			rp.Downed, rp.Eliminated, rp.BleedLeft = false, false, nil -- [stream E1] (old stage loop only)
			publishDown(rp)
			rp.ReviveProgress = 0
			rp.TimeSurvived = 0
			rp.Player:SetAttribute("ReviveProgress", 0)
			rp.Player:SetAttribute("Alive", true)
			setDownedLook(rp, false)
			setHP(rp, rp.Stats.MaxHP * S.ReviveOnTravelHPFraction)
		else
			setHP(rp, math.max(rp.HP, rp.Stats.MaxHP * S.TravelHealFraction))
		end
		rp.InvulnUntil = runTime + Config.Player.ReviveInvulnSeconds
		if not stay then
			RunManager.TeleportPlayer(rp, placeOnArena(arena, i, n))
		end
		if not stay and rp.TravelHold and rp.Root then
			rp.Root.Anchored = true -- held until the travel ends (see travelHold)
		end
		RunManager.ApplyMovement(rp)
	end
	RunManager.RefreshFrozen()
end

------------------------------------------------------------------------------------------
-- Lobby interactions
------------------------------------------------------------------------------------------

local function joinedCount(): number
	local n = 0
	for p in pairs(joined) do
		if p.Parent then
			n += 1
		end
	end
	return n
end

local function tryJoin(player: Player)
	if phase ~= "Countdown" or joined[player] or not ctx.DataService.GetData(player) then
		return
	end
	if ctx.RunServers and ctx.RunServers.Blocks(player) then
		return -- on the way to a run server, or this run server is starting its run
	end
	local n = joinedCount()
	if n >= maxPlayers() then
		RunManager.Notify(player, "This run is full.", Color3.fromRGB(255, 120, 120))
		return
	end
	joined[player] = true
	table.insert(joinedOrder, player)
	publishJoined()
	RunManager.Notify(player, "You joined the run!", Color3.fromRGB(120, 255, 160))
	Remotes.FireClient("OpenPanel", player, "Joined")
	-- a full run starts right away
	if n + 1 >= maxPlayers() then
		beginRun()
	end
end

-- The starter's party (PartyService) joins at once, up to the mode's size; a member
-- left out (full run, SOLO, Daily) is told why. Others still use the countdown's JOIN.
local function joinParty(player: Player)
	local members = ctx.PartyService and ctx.PartyService.MembersOf(player) or {}
	for _, member in ipairs(members) do
		if phase == "Countdown" then
			tryJoin(member)
		end
		local went = byPlayer[member] ~= nil or (ctx.RunServers and ctx.RunServers.IsTravelling(member))
		if not joined[member] and phase ~= "Countdown" and not went then
			RunManager.Notify(member, player.DisplayName .. " started a " .. string.upper(modeDef().DisplayName) .. " run with no room for you.", Color3.fromRGB(255, 200, 120))
		end
	end
end

--[[
	A lobby mode button. Solo starts at once; Duo / Trio (and the old Squad) count down
	so others can join. During a countdown any mode button just joins it.
]]
local function startRun(player: Player, newMode: string)
	if ctx.RunServers and ctx.RunServers.Blocks(player) then
		return -- on the way to a run server, or this run server is starting its run
	end
	if phase == "Countdown" then
		if newMode == "Daily" or newMode == "Weekly" then
			RunManager.Notify(player, "A group run is starting: join it, or play the " .. newMode .. " after it.", Color3.fromRGB(255, 200, 120))
			return
		end
		tryJoin(player)
		return
	end
	if phase ~= "Lobby" or not ctx.DataService.GetData(player) or not isMode(newMode) then
		return
	end
	local partyBlock = ctx.PartyService and ctx.PartyService.StartBlocked(player)
	if partyBlock then
		RunManager.Notify(player, partyBlock, Color3.fromRGB(255, 200, 120))
		return
	end
	mode = newMode
	state:SetAttribute("Mode", mode)
	table.clear(joined)
	table.clear(joinedOrder)
	if not modeDef().Countdown then
		joined[player] = true
		table.insert(joinedOrder, player)
		beginRun()
		joinParty(player)
		return
	end
	starter = player
	setPhase("Countdown")
	countdown = Config.Run.CountdownSeconds
	state:SetAttribute("Countdown", countdown)
	publishJoined()
	tryJoin(player)
	joinParty(player)
	if (phase :: string) == "Countdown" then -- tryJoin may have started a full run
		RunManager.Broadcast(player.DisplayName .. " is starting a " .. string.upper(modeDef().DisplayName) .. " run! Tap JOIN to play.", Color3.fromRGB(120, 255, 160), nil, { Id = "lobby.run.starting" })
	end
end

--[[
	A brand-new player's first join (Config.FirstRun): the client asks once its lobby is
	up (remote StartFirstRun) and the server decides. Only a player with no run ever
	started (Stats.Runs counts a run at its start, so leaving mid-run still counts) and the
	tutorial not done, once per server session, from the Lobby phase, on a lobby server,
	not travelling or reconnecting, not in a party, with no curses / Endless picked. Then
	it is the plain SOLO start (same rules as the button). Everyone else stays in the lobby.
]]
local firstRunAsked: { [Player]: boolean } = {}
-- true when `player` may get the automatic first run now (see above)
local function firstRunAllowed(player: Player): boolean
	local cfg = (Config :: any).FirstRun
	if not cfg or cfg.AutoStart ~= true or not isMode(cfg.Mode) then
		return false
	end
	if lobbySpawnSuppressed then
		return false -- the SwarmV2 basecamp starts runs through its gates (RunEntry), never the old auto start
	end
	local data = ctx.DataService.GetData(player)
	if not data or data.TutorialDone == true or type(data.Stats) ~= "table" or (tonumber(data.Stats.Runs) or 0) > 0 then
		return false
	end
	if (type(data.Curses) == "table" and #data.Curses > 0) or player:GetAttribute("Endless") == true then
		return false
	end
	if phase ~= "Lobby" or byPlayer[player] or player:GetAttribute("InRun") == true then
		return false
	end
	if ctx.RunServers and (ctx.RunServers.IsRunServer() or ctx.RunServers.Blocks(player)) then
		return false
	end
	if ctx.PartyService and ctx.PartyService.PartyOf(player) then
		return false
	end
	return true
end

local function startFirstRun(player: Player)
	if firstRunAsked[player] then
		return
	end
	firstRunAsked[player] = true
	-- the answer (player attribute FirstRun): "Start" (a run is starting) or "Lobby"
	if firstRunAllowed(player) then
		player:SetAttribute("FirstRun", "Start")
		startRun(player, (Config :: any).FirstRun.Mode)
	else
		player:SetAttribute("FirstRun", "Lobby")
	end
end

--[[
	Starts a run on THIS server for `players` (RunServers: a run server's ticket, or the
	lobby's fallback when the teleport failed): the mode, the arena (already validated) and
	the starter whose curses / Endless switch it uses. Only from the Lobby phase; returns
	true when the run is running.
]]
function RunManager.StartTeamRun(players: { Player }, newMode: string, arena: string?, startPlayer: Player?): boolean
	if phase ~= "Lobby" or not isMode(newMode) then
		return false
	end
	mode = newMode
	state:SetAttribute("Mode", mode)
	if arena and arena ~= selectedArena and table.find(Config.Arenas.Order, arena) then
		selectedArena = arena
		state:SetAttribute("SelectedArena", arena)
		if lobby.ArenaLabel then
			lobby.ArenaLabel.Text = "ARENA: " .. string.upper(Config.Arenas[arena].DisplayName)
		end
	end
	table.clear(joined)
	table.clear(joinedOrder)
	for _, p in ipairs(players) do
		if p.Parent and ctx.DataService.GetData(p) and not joined[p] then
			joined[p] = true
			table.insert(joinedOrder, p)
		end
	end
	if #joinedOrder == 0 then
		return false
	end
	starter = (startPlayer and joined[startPlayer]) and startPlayer or joinedOrder[1]
	beginRun(true)
	return (phase :: string) == "Running"
end

-- The starter skips the rest of the countdown once someone else has joined.
local function startNow(player: Player)
	if phase ~= "Countdown" or player ~= starter or not joined[player] then
		return
	end
	if joinedCount() < 2 then
		RunManager.Notify(player, "Wait for someone to join, or play SOLO.", Color3.fromRGB(255, 200, 120))
		return
	end
	beginRun()
end

local function setArena(name: string)
	selectedArena = name
	state:SetAttribute("SelectedArena", name)
	if lobby.ArenaLabel then
		lobby.ArenaLabel.Text = "ARENA: " .. string.upper(Config.Arenas[name].DisplayName)
	end
	RunManager.Broadcast("Arena set to " .. Config.Arenas[name].DisplayName, Color3.fromRGB(255, 220, 120), nil, { Id = "lobby.arena" })
end

--[[
	CycleArena(name?): with an arena name (the lobby's ARENA screen) picks that arena when it
	exists, is in Config.Arenas.Order and is unlocked for this player; without one, the next
	unlocked arena in order (the old cycling card).
]]
local function cycleArena(player: Player, wanted: any)
	if phase ~= "Lobby" then
		return
	end
	local data = ctx.DataService.GetData(player)
	if not data then
		return
	end
	if wanted ~= nil then
		if type(wanted) ~= "string" or not table.find(Config.Arenas.Order, wanted) then
			return
		end
		if not arenaUnlocked(data.Stats, wanted) then
			local def = (Config.Arenas :: any)[wanted]
			RunManager.Notify(player, string.format("Reach stage %d in a run to unlock %s.", def.RequiredBestStage or 0, def.DisplayName), Color3.fromRGB(255, 200, 120))
			return
		end
		if wanted ~= selectedArena then
			setArena(wanted)
		end
		return
	end
	local order = Config.Arenas.Order
	local index = table.find(order, selectedArena) or 1
	for step = 1, #order do
		local name = order[((index - 1 + step) % #order) + 1]
		if arenaUnlocked(data.Stats, name) then
			if name == selectedArena then
				break
			end
			setArena(name)
			return
		end
	end
	-- nothing else unlocked yet: name the next arena and the stage it needs
	local need, needName = math.huge, nil
	for _, name in ipairs(order) do
		local def = (Config.Arenas :: any)[name]
		if def and not arenaUnlocked(data.Stats, name) and (def.RequiredBestStage or 0) < need then
			need, needName = def.RequiredBestStage or 0, def.DisplayName
		end
	end
	if needName then
		RunManager.Notify(player, string.format("Reach stage %d in a run to unlock %s.", need, needName), Color3.fromRGB(255, 200, 120))
	end
end

------------------------------------------------------------------------------------------
-- Dev tools (DevAccess decides who; the client button is only a shortcut)
------------------------------------------------------------------------------------------

-- Studio, DevAllowlist UserIds (the owner, in live servers) or the creator (DevAccess.lua)
local function isDev(player: Player): boolean
	return ctx.DevAccess.IsDev(player)
end

function RunManager.IsDev(player: Player): boolean
	return isDev(player)
end

local function devCommand(player: Player, command: any, arg: any)
	if type(command) ~= "string" or not isDev(player) then
		return
	end
	-- any DEV command by a player IN the run taints the whole run (everyone in it, and
	-- anyone the run still adds): it then writes no records, boards, daily score or
	-- achievements. A dev outside the run (lobby side of the same server) cannot touch it:
	-- DevTools' run commands need a live run player, the rest change only the dev's own
	-- save, so another group's run stays clean (audit SEC-15).
	local devRp = byPlayer[player]
	if phase == "Running" and not runDevTainted and devRp ~= nil and not devRp.Returned then
		runDevTainted = true
		for _, other in ipairs(runPlayers) do
			other.DevTainted = true
		end
		warn("[RunManager] DEV command used: this run is dev-tainted (no records or leaderboards)")
	end
	if command == "StartSolo" then
		if phase == "Lobby" then
			startRun(player, "Solo")
		elseif phase == "Countdown" then
			tryJoin(player)
			if joined[player] then
				beginRun()
			end
		end
		return
	end
	if DevTools.Knows(command) then
		local rp = byPlayer[player]
		DevTools.Handle(ctx, player, command, arg, not RunManager.IsParticipant(player), rp, phase == "Running")
	end
end

------------------------------------------------------------------------------------------
-- Character previews (3D models for the lobby screen's ViewportFrames)
------------------------------------------------------------------------------------------

local previewFolder: Folder? = nil

-- Builds the preview models of one character (every skin). Anchored, no Humanoid.
local function buildPreviews(characterId: string)
	local folder = previewFolder
	if not folder then
		return
	end
	for _, skinId in ipairs(CharacterData.SkinsFor(characterId)) do
		local name = characterId .. "|" .. skinId
		local ok, model = pcall(ModelBuilder.BuildCharacter, characterId, skinId)
		if ok and model then
			local hum = model:FindFirstChildOfClass("Humanoid")
			if hum then
				hum:Destroy()
			end
			for _, d in ipairs(model:GetDescendants()) do
				if d:IsA("BasePart") then
					d.Anchored = true
					d.CanCollide = false
					d.CanQuery = false
					d.CanTouch = false
				end
			end
			model.Name = name
			local old = folder:FindFirstChild(name)
			if old then
				old:Destroy()
			end
			model.Parent = folder
		else
			warn("[RunManager] preview " .. name .. " failed: " .. tostring(model))
		end
	end
end

local function setupPreviews()
	local f = Instance.new("Folder")
	f.Name = "CharacterPreviews"
	f.Parent = ReplicatedStorage
	previewFolder = f
	for _, id in ipairs(CharacterData.Order) do
		buildPreviews(id)
		-- rebuild with the uploaded meshes once they have loaded: the hero mesh plus the hat
		-- mesh of every skin that swaps its headgear (otherwise a preview built before its
		-- hat arrives keeps the part-built stand-in hat)
		if ctx.MeshService and ctx.MeshService.WhenReady then
			for _, skinId in ipairs(CharacterData.SkinsFor(id)) do
				ctx.MeshService.WhenReady(ModelBuilder.MeshesFor(id, skinId), function()
					buildPreviews(id)
				end)
			end
		end
	end
	-- the VIP lobby crown is a mesh too: rebuild lobby characters once it has loaded
	if ctx.MeshService and ctx.MeshService.WhenReady then
		ctx.MeshService.WhenReady({ "Hat_Crown" }, function()
			for _, player in ipairs(game:GetService("Players"):GetPlayers()) do
				if ctx.DataService.GetData(player) then
					RunManager.RefreshLobbyCharacter(player)
				end
			end
		end)
	end
end

------------------------------------------------------------------------------------------
-- Disconnect window  [stream E1, RunConfig.Survival.Disconnect]
------------------------------------------------------------------------------------------
--[[
	A living hero who drops out of a run that goes on (another member is still connected) keeps
	their record for Survival.Disconnect.WindowSeconds (60): HP, build, levels, cooldown clocks
	(rp.DashReadyAt ...) and escrow. Meanwhile they are out of runPlayers, so they cannot attack,
	be hit or collect XP. Coming back inside the window resumes that same record (SwarmV2 matches:
	RunManager.ReconnectAdmitted from RunEntry; the old run-server route: TryReconnect). When the
	window ends they are eliminated and settled once (saveRunStats when they are on this server,
	else the boards here and their escrow on their next load, GoldSystem.RecoverEscrow); a later
	authorized return can only watch. A hero who was downed or eliminated when they dropped is
	settled at once and may also come back to watch. Lifetime stats are checkpointed at the drop
	(as the old co-op rejoin did): a hero who never returns keeps those and the escrow's kept
	share, not the run's account / mastery XP.
	A wipe waits only for living heroes inside a window. While no connected living hero remains
	and someone is inside one, the world is held (RefreshFrozen), so nobody returns into a run
	that went on without anyone; the bleed timers wait with it.
	SwarmState: AwayIds (",userId,"), AwayUntil (server time the last window ends, 0 = none).
]]

-- Living heroes inside their disconnect window right now.
function RunManager.AwayInWindow(): number
	local n, now = 0, os.clock()
	for _, entry in pairs(disconnected) do
		if entry.Window and not entry.Expired and now < (entry.Until or 0) then
			n += 1
		end
	end
	return n
end

-- True when this server holds a resumable record for this user (GoldSystem keeps their escrow
-- on a profile load here instead of settling it).
function RunManager.HoldsReconnect(userId: number): boolean
	local entry = disconnected[userId]
	if phase ~= "Running" or entry == nil then
		return false
	end
	if entry.Window and not entry.Expired and os.clock() < (entry.Until or 0) then
		return true
	end
	return RunManager.SoloAway ~= nil and RunManager.SoloAway.UserId == userId
end

publishAway = function()
	local ids, last = {}, 0
	local now = os.clock()
	for userId, entry in pairs(disconnected) do
		if entry.Window and not entry.Expired and now < (entry.Until or 0) then
			table.insert(ids, tostring(userId))
			last = math.max(last, (entry.Until or 0) - now)
		end
	end
	table.sort(ids)
	state:SetAttribute("AwayIds", #ids > 0 and ("," .. table.concat(ids, ",") .. ",") or "")
	state:SetAttribute("AwayUntil", #ids > 0 and (workspace:GetServerTimeNow() + last) or 0)
end

--[[
	Settles an away record once (its window ended, a held solo run ended, shutdown, the run
	ended without them). The player back on this server (not in the run): the normal leave
	commit (saveRunStats). Away: the boards get the run's score here; the gold settles on their
	next load. Returns the player when they were here.
]]
settleAway = function(rp, userId: number): Player?
	if rp.Committed then
		return nil
	end
	local here = game:GetService("Players"):GetPlayerByUserId(userId)
	local data = here and not byPlayer[here] and not ctx.DataService.IsReleased(here) and ctx.DataService.GetData(here)
	if here and data then
		rp.Player = here
		saveRunStats(rp, false)
		return here
	end
	rp.Committed = true
	if not rp.DevTainted then
		local cleared = ctx.StageManager.StagesCleared()
		local score = ctx.LeaderboardService.RunScore({ Cleared = cleared, Bosses = bossKills, Level = rp.Level, Kills = rp.Kills, Seconds = runTime })
		local board = rp.Endless and "ScoreEndless" or "Score"
		ctx.LeaderboardService.Submit(rp.Player, board, score, nil, rp.RunId)
		ctx.LeaderboardService.Submit(rp.Player, "BestStage", ctx.StageManager.GetStage(), nil, rp.RunId)
		ctx.LeaderboardService.Submit(rp.Player, "Kills", rp.Kills, nil, rp.RunId)
		ctx.LeaderboardService.Submit(rp.Player, "Level", rp.Level or 1, nil, rp.RunId)
	end
	return nil
end

-- Per frame: windows that ran out eliminate their hero (once).
local function stepAway()
	local now = os.clock()
	local changed = false
	for userId, entry in pairs(disconnected) do
		if entry.Window and not entry.Expired and now >= (entry.Until or 0) then
			entry.Expired = true
			entry.Spectate = true
			changed = true
			local rp = entry.Player
			rp.Alive, rp.Downed, rp.Eliminated = false, false, true
			local here = settleAway(rp, userId)
			if here then
				ctx.GoldSystem.SyncProfile(here)
			end
			if phase == "Running" then
				RunManager.Broadcast(rp.Player.DisplayName .. " didn't make it back in time.", Color3.fromRGB(255, 200, 120), nil, { Id = "team.left." .. tostring(userId) })
			end
		end
	end
	if changed then
		publishAway()
		RunManager.ResolveRescue()
		RunManager.RefreshFrozen()
		checkEnd()
	end
end

------------------------------------------------------------------------------------------
-- Per-frame
------------------------------------------------------------------------------------------

-- Players can jump onto the low obstacles, where enemies (which keep out of the
-- footprints) cannot reach them. After a short stay on top they are moved to the nearest edge.
local OBSTACLE_PERCH_SECONDS = 0.5
local function obstaclePerchCheck(rp, dt: number)
	local root: BasePart? = rp.Root
	if not root or not root.Parent or root.Anchored then
		rp.OnObstacleFor = 0
		return
	end
	local p = root.Position
	if not ctx.EnemyAI.IsBlocked(p.X, p.Z, 0) then
		rp.OnObstacleFor = 0
		return
	end
	rp.OnObstacleFor += dt
	if rp.OnObstacleFor < OBSTACLE_PERCH_SECONDS then
		return
	end
	rp.OnObstacleFor = 0
	local out = ctx.EnemyAI.PushOut(p, 1.7)
	root.CFrame = CFrame.new(out.X, p.Y, out.Z) * root.CFrame.Rotation
	rp.LastValidPos = nil -- the speed check restarts from the new spot
end

local function speedCheck(rp, dt: number)
	local root: BasePart? = rp.Root
	if not root or not root.Parent or root.Anchored then
		return
	end
	rp.SpeedCheckTimer += dt
	if rp.SpeedCheckTimer < 0.5 then
		return
	end
	local elapsed = rp.SpeedCheckTimer
	rp.SpeedCheckTimer = 0
	local pos = root.Position
	local last: Vector3? = rp.LastValidPos
	if not last then
		rp.LastValidPos = pos
		return
	end
	local moved = ((pos - last) * FLAT).Magnitude
	-- paused (level-up), frozen or downed players may not travel at all
	-- (ice makes players faster: BiomeHazards' TerrainSpeedMult > 1)
	-- [stream E1] never above the generic cap (Survival.Move.HorizontalCap, 34) or an explicit
	-- class boost (RunManager.SetSpeedBoost). No bunny-hop multiplier: chained jumps add nothing.
	local SM = Survival.Move
	local maxSpeed = (rp.Paused or rp.RewardUntil or frozen or not rp.Alive) and 0
		or math.min(math.max(rp.Stats.Speed, Config.Player.BaseSpeed) * math.max(1, rp.TerrainSpeedMult or 1) * (rp.RushMult or 1), RunManager.SpeedLimit(rp))
	local allowed = maxSpeed * SM.ServerTolerance * elapsed + SM.SpeedAllowance
	-- dash / leap (SwarmV2 Run.Dash, validated there): the same pattern as RushMult. While the
	-- dash is current, or ended less than AllowTail ago (plus this check window, which may have
	-- started before it ended), max(normal, DashSpeed * AllowMult) is allowed. A leap carries its
	-- own rp.DashAllow (horizontal speed * LeapAllowMult). Never for a paused, frozen or downed player.
	local dashUntil: number? = rp.DashUntil
	if maxSpeed > 0 and dashUntil and os.clock() < dashUntil + DashRules.AllowTail + elapsed then
		local dashSpeed: number = rp.DashAllow or (rp.DashSpeed or 0) * DashRules.AllowMult
		allowed = math.max(allowed, dashSpeed * elapsed + SM.SpeedAllowance)
	end
	if moved > allowed then
		root.CFrame = CFrame.new(last + Vector3.new(0, 0.5, 0)) * root.CFrame.Rotation
		root.AssemblyLinearVelocity = Vector3.zero
	elseif pos.Y >= HeightGrid.GroundY(pos.X, pos.Z) - 1 then
		-- (a spot under the floor is never "valid": snapping back to it kept a player who
		-- fell through the floor falling forever; fallRescue handles that case)
		rp.LastValidPos = pos
	end
end

--[[
	Safety net against falling through the map (a floor that had not reached the client
	yet after travel, a physics push through the thin floor) and out-of-bounds rescue: a run
	player whose root is RESCUE_BELOW studs under the floor top, or well outside the arena, is
	put back on the last verified safe surface (rp.SafePos: standing height on walkable ground,
	inside the arena) or the arena spawn. [stream E1, Survival.Rescue] A living hero pays at most
	MaxHPShare (10%) of max HP (never their last hit point, nothing during an earlier rescue's
	lockout) and gets LockoutSeconds (3) without damage. No XP or healing; the arrival is no
	landing (no fall damage, no landing ability: rp.AirReset via TeleportPlayer). Downed
	(anchored) players are moved too, for free, so teammates can still reach them.
]]
local RESCUE_BELOW = 4
local function arenaHalf(): number
	return ((Config.Arenas :: any).Size or 400) / 2
end

function RunManager.NeedsRescue(pos: Vector3): boolean
	if HeightGrid.IsActive() then
		-- a map with height: RescueBelow under the ground at this x, z (a drop from a terrace
		-- is not a fall out of the map), or well outside the arena bounds
		local minX, minZ, maxX, maxZ = HeightGrid.Bounds()
		return pos.Y < HeightGrid.GroundY(pos.X, pos.Z) - Nav.RescueBelow
			or pos.X < minX - 30 or pos.X > maxX + 30 or pos.Z < minZ - 30 or pos.Z > maxZ + 30
	end
	local c, h = Config.ArenaOrigin, arenaHalf() + 30
	return pos.Y < FLOOR_Y - RESCUE_BELOW or math.abs(pos.X - c.X) > h or math.abs(pos.Z - c.Z) > h
end

-- True when a root at pos stands on good ground: the last safe spot a fall rescue returns to.
local function standingSafe(pos: Vector3): boolean
	if HeightGrid.IsActive() then
		local minX, minZ, maxX, maxZ = HeightGrid.Bounds()
		local g = HeightGrid.GroundY(pos.X, pos.Z)
		return pos.Y > g + 0.5 and pos.Y < g + Nav.SafeAbove and HeightGrid.IsWalkable(pos.X, pos.Z)
			and pos.X >= minX and pos.X <= maxX and pos.Z >= minZ and pos.Z <= maxZ
	end
	local c, h = Config.ArenaOrigin, arenaHalf()
	return pos.Y > FLOOR_Y + 0.5 and pos.Y < FLOOR_Y + 8 and math.abs(pos.X - c.X) <= h and math.abs(pos.Z - c.Z) <= h
end

local function fallRescue(rp): boolean
	local root: BasePart? = rp.Root
	if not root or not root.Parent then
		return false
	end
	local pos = root.Position
	if not RunManager.NeedsRescue(pos) then
		if not root.Anchored and standingSafe(pos) then
			rp.SafePos = pos -- the last good ground position (per run player)
		end
		return false
	end
	local fallback = HeightGrid.Ground(Config.ArenaOrigin)
	local arena = MapBuilder.GetArena()
	if HeightGrid.IsActive() and arena then
		local spawn = arena.Spawn
		local at = (typeof(spawn) == "Vector3" and spawn) or (typeof(spawn) == "CFrame" and spawn.Position) or arena.Center or Config.ArenaOrigin
		fallback = HeightGrid.Ground(at)
	end
	local safe: Vector3 = rp.SafePos or fallback
	if RunManager.NeedsRescue(safe) then
		safe = fallback
	end
	RunManager.TeleportPlayer(rp, Vector3.new(safe.X, HeightGrid.GroundY(safe.X, safe.Z), safe.Z))
	if rp.Alive then
		local lockout = Survival.Rescue.LockoutSeconds
		-- the cost (inside an earlier rescue's lockout, or any other protection, there is none)
		if runTime >= (rp.InvulnUntil or 0) and rp.Player:GetAttribute("DevGod") ~= true then
			local cost = SurvivalRules.RescueCost(rp.Stats.MaxHP, rp.HP)
			if cost > 0 then
				setHP(rp, rp.HP - cost)
				rp.RescueCost = (rp.RescueCost or 0) + cost
				Fx.PlayerEvent(rp.Player, "hurt")
			end
		end
		rp.InvulnUntil = math.max(rp.InvulnUntil or 0, runTime + lockout)
	end
	rp.FallRescues = (rp.FallRescues or 0) + 1
	warn(string.format("[RunManager] %s fell out of the arena at (%.0f, %.0f, %.0f); put back on the floor", rp.Player.Name, pos.X, pos.Y, pos.Z))
	return true
end

--[[
	Travel hold: from the first frame of the travel fade until it ends, run roots are
	anchored. The old arena is destroyed and the new one built while the screens are dark;
	the client simulates its own character, so without the hold it could fall through the
	gap before the new floor reached it. Released (and physics handed back) once the
	travel is over.
]]
local function travelHold(rp, holding: boolean)
	local root: BasePart? = rp.Root
	if holding then
		-- re-asserted every frame (a revive or a swapped character model unanchors)
		if root and root.Parent then
			rp.TravelHold = true
			if not root.Anchored then
				root.AssemblyLinearVelocity = Vector3.zero
				root.Anchored = true
			end
		end
	elseif rp.TravelHold then
		rp.TravelHold = nil
		if root and root.Parent and rp.Alive then
			root.Anchored = false
			pcall(function()
				root:SetNetworkOwner(rp.Player)
			end)
			rp.LastValidPos = root.Position
			rp.SpeedCheckTimer = 0
		end
	end
end

function RunManager.Step(dt: number)
	if phase == "Countdown" then
		countdown -= dt
		state:SetAttribute("Countdown", math.max(0, math.ceil(countdown)))
		if countdown <= 0 then
			beginRun()
		end
		return
	end

	if phase == "Results" then
		resultsTimer -= dt
		local anyoneWaiting = false
		for _, rp in ipairs(runPlayers) do
			if not rp.Returned and rp.Player.Parent then
				anyoneWaiting = true
			end
		end
		if resultsTimer <= 0 or not anyoneWaiting then
			returnAll("results")
		end
		return
	end

	if phase ~= "Running" then
		return
	end
	-- QuickResume: a held solo run whose player did not come back in time is settled once
	if RunManager.SoloAway and os.time() >= RunManager.SoloAway.Expires then
		RunManager.ExpireSoloHold(false)
		return
	end

	local now = os.clock()
	local live = groupLive()
	for _, rp in ipairs(runPlayers) do
		-- a hold that began solo ends at once if the run becomes a live group run (a
		-- teammate rejoined): rooted-but-unprotected must never happen
		if rp.RewardUntil and (now >= rp.RewardUntil or not rp.Alive or live) then
			RunManager.EndReward(rp)
		end
		stepProtectBudget(rp, dt, live)
		ctx.GoldSystem.UpdateRunProgress(rp, ctx.StageManager.StagesCleared())
		local root: BasePart? = rp.Root
		if root and root.Parent then
			local look = root.CFrame.LookVector * FLAT
			if look.Magnitude > 0.1 then
				rp.Facing = look.Unit
			end
			local v = root.AssemblyLinearVelocity * FLAT
			rp.MoveDir = v.Magnitude > 2 and v.Unit or Vector3.zero
		end
		travelHold(rp, ctx.StageManager.IsHolding())
		fallRescue(rp)
		if rp.Alive then
			obstaclePerchCheck(rp, dt)
			speedCheck(rp, dt)
		end
		if rp.AwaitingRevive then
			-- the pause menu and the frozen / holding states (chest, level-up, stage hold)
			-- stop this clock; revives are skipped meanwhile, so the offer must not run out
			if menuPaused or frozen or ctx.StageManager.IsHolding() then
				rp.ReviveDeadline += dt
			elseif now >= rp.ReviveDeadline then
				finalizeElimination(rp)
			end
		end
	end
	local holding = ctx.StageManager.IsHolding()
	-- [stream E1] bleed timers and held revives (paused while the world is frozen / travelling),
	-- then the disconnect windows
	stepDowned(dt, phase == "Running" and not frozen and not holding)
	stepAway()
	if phase ~= "Running" then
		return
	end

	if frozen or holding then
		return
	end

	runTime += dt
	attrTimer += dt
	if attrTimer >= 0.2 then
		attrTimer = 0
		state:SetAttribute("RunTime", math.floor(runTime * 10) / 10)
	end
	-- mini-waves, the portal, the Queen and the surge: StageManager.Step
end

------------------------------------------------------------------------------------------
-- Players joining / leaving
------------------------------------------------------------------------------------------

function RunManager.OnPlayerRemoving(player: Player)
	firstRunAsked[player] = nil
	if joined[player] then
		joined[player] = nil
		local i = table.find(joinedOrder, player)
		if i then
			table.remove(joinedOrder, i)
		end
		if starter == player then
			starter = joinedOrder[1]
		end
		publishJoined()
		-- the last joined player left: the countdown has nobody to start for
		if phase == "Countdown" and joinedCount() == 0 then
			starter = nil
			setPhase("Lobby")
			publishJoined()
		end
	end
	local rp = byPlayer[player]
	if not rp then
		return
	end
	local wasInRun = phase == "Running" and not rp.Returned
	clearReviveLinks(rp)
	-- [stream E1] the run goes on without this hero for now: another member is still connected
	local others = false
	for _, other in ipairs(runPlayers) do
		if other ~= rp and not other.Returned and other.Player ~= player and other.Player.Parent then
			others = true
			break
		end
	end
	-- a living hero keeps their record for the disconnect window (Survival.Disconnect)
	local windowed = wasInRun and rp.Alive and not rp.Committed and others and Survival.Disconnect.WindowSeconds > 0
	-- QuickResume (docs/next/QUICK_RESUME.md): a solo run waits, frozen, for its player
	local soloHold = not windowed and wasInRun and ctx.QuickResume ~= nil and ctx.QuickResume.CanHold(rp, #runPlayers, maxPlayers())
	local data = ctx.DataService.GetData(player)
	if windowed or soloHold then
		ctx.LevelUpSystem.Cancel(rp, true)
		-- Preserve lifetime progress even if reconnect never succeeds. Completion rewards
		-- wait until the run actually ends; the kill delta prevents counting this twice.
		if data and not rp.DevTainted then
			data.Stats.TotalKills += math.max(0, rp.Kills - (rp.DisconnectRecordedKills or 0))
			rp.DisconnectRecordedKills = rp.Kills
			data.Stats.MostKills = math.max(data.Stats.MostKills or 0, rp.Kills)
			data.Stats.BestTime = math.max(data.Stats.BestTime or 0, math.floor(runTime))
			data.Stats.BestStage = math.max(data.Stats.BestStage or 0, ctx.StageManager.GetStage())
			data.Stats.BestLevel = math.max(data.Stats.BestLevel or 0, rp.Level)
		end
		local snapshot = table.clone(rp)
		snapshot.Root, snapshot.Character, snapshot.Humanoid = nil, nil, nil
		snapshot.ReviveHeld, snapshot.RewardUntil, snapshot.RewardSeq = false, nil, 0
		snapshot.ReviveHeldAt, snapshot.ReviveTarget, snapshot.Reviver = nil, nil, nil
		snapshot.ResumePos = rp.Root and rp.Root.Position or nil
		if soloHold then
			if data then
				local expires = ctx.QuickResume.Mark(rp, data)
				RunManager.SoloAway = { UserId = player.UserId, Expires = expires, RunId = rp.RunId }
				disconnected[player.UserId] = { Player = snapshot, Expires = expires }
			end
		else
			local window = Survival.Disconnect.WindowSeconds
			local expires = os.time() + window
			if data and data.RunReconnect and ctx.RunServers and ctx.RunServers.CanReconnect(rp) then
				data.RunReconnect.Expires = expires -- the old run-server route (lobby RESUME / auto rejoin)
			end
			disconnected[player.UserId] = { Player = snapshot, Expires = expires, Until = os.clock() + window, Window = true }
		end
	elseif wasInRun then
		saveRunStats(rp, false)
		if others then
			-- [stream E1] downed / eliminated when they dropped: settled now; a later authorized
			-- return may watch the rest of the run, never play it again
			local snapshot = table.clone(rp)
			snapshot.Root, snapshot.Character, snapshot.Humanoid = nil, nil, nil
			snapshot.ReviveHeldAt, snapshot.ReviveTarget, snapshot.Reviver, snapshot.RewardUntil = nil, nil, nil, nil
			snapshot.Alive, snapshot.Downed, snapshot.Eliminated, snapshot.AwaitingRevive = false, false, true, false
			disconnected[player.UserId] = { Player = snapshot, Expires = math.huge, Spectate = true }
		end
	end
	-- other systems may still hold this record (enemy targets, delayed whip slashes)
	if wasInRun then
		EncounterDirector.PlayerOut(rp, "Leave")
	end
	removeFromRun(rp)
	if wasInRun and #runPlayers > 0 then
		-- teammates see who dropped out (their HUD team list removes the row by itself)
		if windowed then
			RunManager.Broadcast(string.format("%s disconnected: %d s to come back.", player.DisplayName, Survival.Disconnect.WindowSeconds), Color3.fromRGB(255, 200, 120), nil, { Id = "team.left." .. player.UserId })
		else
			RunManager.Broadcast(player.DisplayName .. " left the run.", Color3.fromRGB(255, 200, 120), nil, { Id = "team.left." .. player.UserId })
		end
	end
	rp.Root = nil
	publishAway()
	if phase == "Running" then
		if #runPlayers == 0 then
			-- nobody is left to see results: clear the run world straight away (a held solo
			-- run stays, frozen, for QuickResume; a run with someone inside the disconnect
			-- window stays, held, until they return or the window ends)
			if not RunManager.SoloAway and RunManager.AwayInWindow() == 0 then
				returnAll()
			else
				RunManager.RefreshFrozen()
			end
		else
			ctx.StageManager.OnRosterChanged()
			RunManager.ResolveRescue()
			RunManager.RefreshFrozen()
			checkEnd()
		end
	end
end

--[[
	Puts a held record back into the run for its returning player (same HP, build, levels,
	cooldown clocks and escrow; never healed, never a new life). The record is consumed first.
	solo = a QuickResume hold. False when the character can't be built.
]]
local function restoreRecord(player: Player, saved, solo: boolean, data): boolean
	local rp = saved.Player
	-- Consume before callbacks or any operation that may yield.
	disconnected[player.UserId] = nil
	if data.RunReconnect then
		data.RunReconnect.Expires = 0
	end
	if solo then
		RunManager.SoloAway = nil
		menuPaused = false -- a pause menu left open when the player dropped has no owner now
	end
	rp.Player = player
	rp.Gold = data.RunEscrow.Gold
	if data.DevBoosted == true and not runDevTainted then
		-- a boosted profile coming back taints the run like a DEV command (SEC-13)
		runDevTainted = true
		for _, other in ipairs(runPlayers) do
			other.DevTainted = true
		end
	end
	rp.DevTainted = rp.DevTainted or runDevTainted
	rp.LastValidPos, rp.SpeedCheckTimer, rp.OnObstacleFor = nil, 0, 0
	rp.ReviveHeld, rp.ReviveHeldAt, rp.ReviveTarget, rp.Reviver = false, nil, nil, nil
	rp.RewardUntil, rp.Paused = nil, false
	rp.PortalChoice, rp.PortalOffered = nil, false
	rp.Alive, rp.Downed, rp.Eliminated, rp.BleedLeft = true, false, false, nil
	local arena = MapBuilder.GetArena()
	local position = HeightGrid.Ground(arena and arena.Center or Config.ArenaOrigin)
	for _, teammate in ipairs(runPlayers) do
		if teammate.Alive and teammate.Root then position = teammate.Root.Position; break end
	end
	if solo and rp.ResumePos then
		position = rp.ResumePos -- a resumed solo hero comes back where it stood
	end
	rp.ResumePos = nil
	local model = spawnCharacter(player, CFrame.new(position + Vector3.new(3, 3.5, 0)), false, rp.CharacterId)
	if not model then
		if solo and #runPlayers == 0 then
			returnAll() -- the held solo run can't come back: free the world (QuickResume settles the save)
		end
		return false
	end
	if solo then
		data.SoloResume = nil -- QuickResume: consumed (one resume per disconnect)
	end
	table.insert(runPlayers, rp)
	byPlayer[player] = rp
	RunManager.AttachCharacter(rp, model)
	-- a short landing grace, not a new life (Survival.Disconnect.ReturnProtectSeconds)
	rp.InvulnUntil = runTime + Survival.Disconnect.ReturnProtectSeconds
	if ctx.TeamPingService then ctx.TeamPingService.Assign(rp, 1) end
	ctx.LevelUpSystem.RecomputeStats(rp)
	setHP(rp, rp.HP)
	player:SetAttribute("CharacterId", rp.CharacterId)
	player:SetAttribute("InRun", true)
	player:SetAttribute("Alive", true)
	player:SetAttribute("Level", rp.Level)
	player:SetAttribute("XP", rp.XP)
	player:SetAttribute("XPNeeded", rp.XPNeeded)
	player:SetAttribute("Kills", rp.Kills)
	player:SetAttribute("RunGold", rp.Gold)
	player:SetAttribute("GoldMult", ctx.MonetizationService.GoldMultiplier(player))
	-- [stream E1] the same cooldown clocks as before the drop (os.clock based, same server)
	local dashLeft = math.max(0, (rp.DashReadyAt or 0) - os.clock())
	player:SetAttribute("DashReadyAt", dashLeft > 0 and workspace:GetServerTimeNow() + dashLeft or 0)
	if type(rp.DashCd) == "number" then
		player:SetAttribute("DashCd", rp.DashCd)
	end
	publishDown(rp)
	setProgress(rp, 0)
	player:SetAttribute("HitProtectUntil", 0)
	player:SetAttribute("ReviveProtectUntil", 0)
	ctx.ItemSystem.Send(rp)
	ctx.WeaponSystem.OnInventoryChanged(rp)
	ctx.LevelUpSystem.SendInventory(rp)
	ctx.LevelUpSystem.QueueLevels(rp, 0)
	state:SetAttribute("Participants", #runPlayers)
	publishAway()
	-- the teammate's solo pause menu froze the world while they were alone: a group run
	-- again, so nobody can hold the rejoined player frozen
	if menuPaused and #runPlayers > 1 then
		menuPaused = false
	end
	RunManager.RefreshFrozen()
	ctx.StageManager.OnRosterChanged()
	RunManager.Broadcast(player.DisplayName .. " rejoined the run.", Color3.fromRGB(120, 255, 160), nil, { Id = "team.rejoined." .. player.UserId })
	return true
end

-- [stream E1] An eliminated (or settled) member came back: they watch the rest of the run.
-- Never alive again and never a second settlement (the record is already committed).
local function spectateRecord(player: Player, saved): boolean
	local rp = saved.Player
	if not rp.Committed then
		rp.Player = player
		saveRunStats(rp, false) -- (normally done when they left or when their window ended)
	end
	local arena = MapBuilder.GetArena()
	local position = HeightGrid.Ground(arena and arena.Center or Config.ArenaOrigin)
	for _, teammate in ipairs(runPlayers) do
		if teammate.Alive and teammate.Root then position = teammate.Root.Position; break end
	end
	local model = spawnCharacter(player, CFrame.new(position + Vector3.new(3, 3.5, 0)), false, rp.CharacterId)
	if not model then
		return false
	end
	disconnected[player.UserId] = nil
	rp.Player = player
	rp.Alive, rp.Downed, rp.Eliminated, rp.BleedLeft = false, false, true, nil
	rp.AwaitingRevive, rp.ReviveHeld, rp.ReviveHeldAt, rp.ReviveTarget, rp.Reviver = false, false, nil, nil, nil
	rp.RewardUntil, rp.Paused, rp.Offer, rp.ResumePos = nil, false, nil, nil
	rp.LastValidPos, rp.SpeedCheckTimer = nil, 0
	table.insert(runPlayers, rp)
	byPlayer[player] = rp
	RunManager.AttachCharacter(rp, model)
	setDownedLook(rp, true)
	player:SetAttribute("CharacterId", rp.CharacterId)
	player:SetAttribute("InRun", true)
	player:SetAttribute("Alive", false)
	player:SetAttribute("AwaitingRevive", nil)
	player:SetAttribute("Level", rp.Level)
	player:SetAttribute("XP", rp.XP)
	player:SetAttribute("XPNeeded", rp.XPNeeded)
	player:SetAttribute("Kills", rp.Kills)
	player:SetAttribute("HP", 0)
	publishDown(rp)
	setProgress(rp, 0)
	state:SetAttribute("Participants", #runPlayers)
	RunManager.RefreshFrozen()
	RunManager.Broadcast(player.DisplayName .. " is back, watching the run.", Color3.fromRGB(200, 220, 255), nil, { Id = "team.rejoined." .. player.UserId })
	return true
end

-- Restores only a server-held record from this same still-running expedition.
-- The saved ledger must still match; a lobby settlement makes a stale replay fail closed.
-- (The old run-server route and QuickResume; SwarmV2 matches use ReconnectAdmitted.)
function RunManager.TryReconnect(player: Player, id: string): boolean
	local saved = disconnected[player.UserId]
	local data = ctx.DataService.GetData(player)
	-- QuickResume: this player's held solo run (no co-op route needed on the same server)
	local solo = RunManager.SoloAway ~= nil and RunManager.SoloAway.UserId == player.UserId
	if phase ~= "Running" or byPlayer[player] or not saved or saved.Spectate or saved.Expired or saved.Expires <= os.time()
		or (saved.Until ~= nil and os.clock() >= saved.Until)
		or saved.Player.RunId ~= runId or id ~= runId or not data or not data.RunEscrow
		or data.RunEscrow.Id ~= runId or not (solo or (data.RunReconnect and data.RunReconnect.Id == runId))
		or saved.Player.Committed or #runPlayers >= maxPlayers() then return false end
	return restoreRecord(player, saved, solo, data)
end

--[[
	[stream E1] SwarmV2: a member MatchAdmission already admitted to this match came back
	(RunEntry: the arrival barrier says "duplicate"). Inside their disconnect window, with their
	escrow still this run's: the same hero resumes ("resumed"). After the window, or when they
	were downed / eliminated when they dropped: they watch ("spectating"). Otherwise "refused"
	(RunEntry sends them back to the lobby with the reason). Never trusts anything the client sent.
]]
function RunManager.ReconnectAdmitted(player: Player): string
	local saved = disconnected[player.UserId]
	if phase ~= "Running" or byPlayer[player] or not saved or saved.Player.RunId ~= runId then
		return "refused"
	end
	local data = ctx.DataService.GetData(player)
	if not data then
		return "refused"
	end
	local open = saved.Window == true and not saved.Expired and os.clock() < (saved.Until or 0)
	if open and not saved.Player.Committed and type(data.RunEscrow) == "table" and data.RunEscrow.Id == runId then
		return restoreRecord(player, saved, false, data) and "resumed" or "refused"
	end
	if open then
		-- their escrow was settled elsewhere meanwhile (they loaded into a lobby): that was a
		-- departure; no second settlement, they may only watch
		saved.Expired, saved.Spectate = true, true
		saved.Player.Committed = true
		publishAway()
	end
	if saved.Spectate or saved.Expired or saved.Window then
		return spectateRecord(player, saved) and "spectating" or "refused"
	end
	return "refused"
end

-- Commits stats of everyone in a run (server shutdown).
function RunManager.CommitAll()
	for _, rp in ipairs(runPlayers) do
		if not rp.Returned and phase == "Running" then
			saveRunStats(rp, false)
		end
	end
	-- [stream E1] heroes inside their disconnect window: settled once (boards here, escrow on load)
	for userId, entry in pairs(disconnected) do
		if entry.Window and not entry.Player.Committed then
			settleAway(entry.Player, userId)
		end
	end
	if RunManager.SoloAway then
		RunManager.ExpireSoloHold(true) -- QuickResume: the held run's boards, once
	end
end

------------------------------------------------------------------------------------------
-- QuickResume (Config.Features.QuickResume, QuickResume.lua, docs/next/QUICK_RESUME.md)
------------------------------------------------------------------------------------------

-- The solo run held on this server for this UserId ({ UserId, Expires, RunId }), or nil.
function RunManager.SoloHoldFor(userId: number): { [string]: any }?
	local hold = RunManager.SoloAway
	return (hold and hold.UserId == userId) and hold or nil
end

--[[
	Ends a held solo run that will not be resumed (its time ran out, END RUN, a failed
	resume, shutdown), once. The player back on this server: the normal leave commit
	(saveRunStats: the loss / leave gold-kept rule, stats, boards, account XP). The player
	away (their save is elsewhere): the boards get the run's final score once here, and the
	gold settles on their next load (GoldSystem.RecoverEscrow, the same kept rule). Then the
	run world is cleared (not at shutdown). Returns true when a hold was ended.
]]
function RunManager.ExpireSoloHold(atShutdown: boolean?): boolean
	local hold = RunManager.SoloAway
	if not hold then
		return false
	end
	RunManager.SoloAway = nil
	local saved = disconnected[hold.UserId]
	disconnected[hold.UserId] = nil
	local rp = saved and saved.Player
	if rp and phase == "Running" and rp.RunId == runId and not rp.Committed then
		local here = settleAway(rp, hold.UserId)
		if here then
			local data = ctx.DataService.GetData(here)
			if ctx.QuickResume and data then
				ctx.QuickResume.Clear(here, data)
			end
			local s = rp.GoldSettlement
			local kept = s and (s.Retained + (s.Survival or 0) + (s.Group or 0) + (s.Prestige or 0)) or 0
			ctx.GoldSystem.SyncProfile(here)
			RunManager.Notify(here, string.format("Your run ended. %d gold kept.", kept), Color3.fromRGB(255, 200, 120), { Id = "resume.settled" })
		end
	end
	if not atShutdown and phase == "Running" and #runPlayers == 0 then
		returnAll()
	else
		RunManager.RefreshFrozen()
	end
	return true
end

------------------------------------------------------------------------------------------
-- Lifecycle
------------------------------------------------------------------------------------------

function RunManager.Init(c)
	ctx = c
	state = Remotes.State()
	state:SetAttribute("SelectedArena", selectedArena)
	state:SetAttribute("BossHP", 0)
	state:SetAttribute("BossMaxHP", 0)
	lobby = MapBuilder.BuildLobby()
	ctx.Lobby = lobby
	state:SetAttribute("LobbySpawn", lobby.SpawnCFrame)
	state:SetAttribute("Mode", mode)
	disableLobbyPrompts()
	setPhase("Lobby")
	publishJoined()
end

function RunManager.Start()
	setupPreviews()
	-- prompts the world builder adds later are switched off too
	if typeof(lobby.Model) == "Instance" then
		lobby.Model.DescendantAdded:Connect(function(d)
			if d:IsA("ProximityPrompt") then
				d.Enabled = false
			end
		end)
	end

	Remotes.Listen("StartRun", function(player, newMode)
		if isMode(newMode) then
			startRun(player, newMode)
		end
	end, 2)

	Remotes.Listen("StartFirstRun", function(player)
		startFirstRun(player)
	end, 1)
	Remotes.Listen("StartNow", startNow, 2)
	Remotes.Listen("CycleArena", cycleArena, 3)
	Remotes.Listen("DevCommand", devCommand, 6)

	Remotes.Listen("JoinRun", function(player)
		if phase == "Countdown" then
			tryJoin(player)
		end
		-- in the Lobby phase JOIN does nothing: a late tap must not start a hidden run
	end, 2)

	-- MAIN MENU / REPLAY on the defeat results (arg "Replay": the player starts the same
	-- mode again right away, so a run server keeps them for it instead of sending them home)
	Remotes.Listen("ReturnToLobby", function(player, why)
		local rp = byPlayer[player]
		if rp and phase == "Results" then
			returnPlayerToLobby(rp, why == "Replay" and "replay" or "menu")
		end
	end, 2)

	Remotes.Listen("AbandonRun", function(player)
		local rp = byPlayer[player]
		if rp then
			RunManager.AbandonRun(rp)
		end
	end, 1)

	Remotes.Listen("SetPause", function(player, open)
		local rp = byPlayer[player]
		if not rp or phase ~= "Running" or type(open) ~= "boolean" then
			return
		end
		menuPaused = open and Config.Run.SoloPauseFreezesRun and #runPlayers == 1
		RunManager.RefreshFrozen()
	end, 4)

	Remotes.Listen("RewardClose", function(player, seq)
		local rp = byPlayer[player]
		-- seq = rewards the client has shown; an older close leaves a newer reward's pause
		if rp and (type(seq) ~= "number" or seq >= (rp.RewardSeq or 0)) then
			RunManager.EndReward(rp)
		end
	end, 4)

	Remotes.Listen("ReviveDecline", function(player)
		local rp = byPlayer[player]
		if rp and rp.AwaitingRevive then
			finalizeElimination(rp)
		end
	end, 2)

	-- [stream E1] Hold-to-revive (Survival.Downed): ReviveHold(true) while interact is held (the
	-- client repeats it every HoldRefresh s), ReviveHold(false) on release. The server only
	-- notes a fresh hold from a living run player; who is revived, the range (from server
	-- positions), the 3 s and every cancel are decided in stepDowned. A release must clear held
	-- input even when repeated presses exhaust the limiter, so it bypasses it.
	Remotes.Get("ReviveHold").OnServerEvent:Connect(function(player, held)
		if held == false then
			local rp = byPlayer[player]
			if rp then
				rp.ReviveHeld = false
				rp.ReviveHeldAt = nil
				if rp.ReviveTarget then
					cancelRevive(rp.ReviveTarget) -- letting go breaks the 3 uninterrupted seconds
				end
			end
		end
	end)
	Remotes.Listen("ReviveHold", function(player, held)
		local rp = byPlayer[player]
		if rp and held == true then
			local ok = rp.Alive and not rp.Returned and phase == "Running"
			rp.ReviveHeld = ok
			rp.ReviveHeldAt = ok and os.clock() or nil
		end
	end, SD.HoldRate)

	ctx.DataService.OnProfileLoaded(function(player)
		ctx.MonetizationService.RefreshAttributes(player)
		if not RunManager.IsParticipant(player) then
			resetPlayerAttributes(player)
			if not lobbySpawnSuppressed then spawnCharacter(player, lobbySpawnCFrame(), true) end
		end
	end)
end

return RunManager
