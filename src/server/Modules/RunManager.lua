--[[
	RunManager.lua
	The run state machine and everything about players' bodies and lives.

	Phases (SwarmState attribute "Phase"):
	  Lobby      everyone sees the lobby menu screen (characters, shop, mode buttons)
	  Countdown  someone pressed DUO / TRIO; 10 s for others to join (JOIN button); the
	             starter may START NOW once someone joined, a full run starts at once
	  Running    the run: timer counts up, mini-waves every 30 s, boss at 15:00
	  Results    win / lose screen; everyone returns after Config.Run.ResultsSeconds
	SOLO skips the countdown. Modes live in Config.Modes; "Squad" (old 1-4 mode) is still
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
	  Facing, MoveDir, InvulnUntil, Returned
	HP lives here (not in the Humanoid): the Humanoid's Dead state is disabled.
]]

local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Config = require(game:GetService("ReplicatedStorage").Shared.Config)
local Remotes = require(game:GetService("ReplicatedStorage").Shared.Remotes)
local CharacterData = require(game:GetService("ReplicatedStorage").Shared.CharacterData)
local MetaUpgradeData = require(game:GetService("ReplicatedStorage").Shared.MetaUpgradeData)
local ModelBuilder = require(script.Parent.ModelBuilder)
local MapBuilder = require(script.Parent.MapBuilder)
local Fx = require(script.Parent.Fx)

local RunManager = {}

local ctx
local state: Configuration
local lobby
local rng = Random.new()
local FLAT = Vector3.new(1, 0, 1)

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
local miniWaveTimer = 0
local bossWarned = false
local bossSpawned = false
local endPending = false
local resultsTimer = 0
local totalKills = 0
local attrTimer = 0
local selectedArena = "Forest"
local currentArena = "Forest"
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

function RunManager.IsFrozen(): boolean
	return frozen
end

-- True only for the solo pause menu (level-up pauses keep their auto-pick timer running).
function RunManager.IsMenuPaused(): boolean
	return menuPaused
end

--[[
	The whole run freezes while the solo pause menu is open or while any player is choosing
	a level-up card (enemies, projectiles, damage and the timer all stop for everyone).
	Called whenever either source changes.
]]
function RunManager.RefreshFrozen()
	local choosing = false
	for _, rp in ipairs(runPlayers) do
		if rp.Offer and rp.Alive and not rp.Returned then
			choosing = true
		end
	end
	local newFrozen = phase == "Running" and (menuPaused or choosing)
	state:SetAttribute("LevelUpPause", phase == "Running" and choosing and not menuPaused)
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

-- True when the world should move: a run is going and it isn't solo-paused.
function RunManager.IsSimulating(): boolean
	return phase == "Running" and not frozen
end

function RunManager.IsBossPhase(): boolean
	return bossSpawned
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

function RunManager.Notify(player: Player, text: string, color: Color3?)
	if player.Parent then
		Remotes.FireClient("Notify", player, { Text = text, Color = color })
	end
end

function RunManager.Broadcast(text: string, color: Color3?, big: boolean?)
	Remotes.FireAllClients("Notify", { Text = text, Color = color, Big = big })
end

-- True for a mode name a client may ask for (the lobby's modes plus the old "Squad").
local function isMode(name: any): boolean
	return type(name) == "string" and (table.find(Config.Modes.Order, name) ~= nil or name == "Squad")
end

local function modeDef()
	return (Config.Modes :: any)[mode] or Config.Modes.Solo
end

local function maxPlayers(): number
	return math.min(Config.Run.MaxPlayers, modeDef().MaxPlayers)
end

-- Partner revive rules of the current mode (Duo / Trio), or nil.
local function reviveRules()
	return modeDef().PartnerRevive
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
local partnerRevives: (number) -> ()

local function lobbySpawnCFrame(): CFrame
	local a = rng:NextNumber(0, math.pi * 2)
	return lobby.SpawnCFrame * CFrame.new(math.cos(a) * 5, 0, math.sin(a) * 5)
end

--[[
	Builds the player's blocky character (selected character + skin) and places it.
	inLobby adds the VIP crown. Old characters are destroyed on purpose (not respawned).
]]
spawnCharacter = function(player: Player, cframe: CFrame, inLobby: boolean): Model?
	local data = ctx.DataService.GetData(player)
	if not data or not player.Parent then
		return nil
	end
	local characterId = data.SelectedCharacter
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
	humanoid:SetStateEnabled(Enum.HumanoidStateType.Jumping, false)
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
				local cf = CFrame.new((arena and arena.Center or Config.ArenaOrigin) + Vector3.new(0, 3.5, 0))
				local m = spawnCharacter(player, cf, false)
				RunManager.AttachCharacter(rp, m)
			else
				spawnCharacter(player, lobbySpawnCFrame(), true)
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

-- Sets WalkSpeed from state: 0 when paused, dead, downed or the run is frozen.
function RunManager.ApplyMovement(rp)
	local hum: Humanoid? = rp.Humanoid
	local canMove = rp.Alive and not rp.Paused and not frozen and phase == "Running"
	if hum and hum.Parent then
		hum.WalkSpeed = canMove and rp.Stats and rp.Stats.Speed or 0
	end
	rp.Player:SetAttribute("Paused", rp.Paused == true)
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

------------------------------------------------------------------------------------------
-- HP, death, revive
------------------------------------------------------------------------------------------

local function setHP(rp, hp: number)
	rp.HP = math.clamp(hp, 0, rp.Stats.MaxHP)
	rp.Player:SetAttribute("HP", math.ceil(rp.HP))
end

function RunManager.Heal(rp, amount: number, silent: boolean?)
	if not rp.Alive then
		return
	end
	setHP(rp, rp.HP + amount)
	if not silent then
		Fx.PlayerEvent(rp.Player, "heal")
	end
end

local function checkEnd()
	if phase ~= "Running" or endPending then
		return
	end
	for _, rp in ipairs(runPlayers) do
		if rp.Alive or rp.AwaitingRevive then
			return
		end
	end
	RunManager.EndRun(false)
end

local function revive(rp, message: string)
	rp.ReviveProgress = 0
	rp.Player:SetAttribute("ReviveProgress", 0)
	rp.Alive = true
	rp.AwaitingRevive = false
	setDownedLook(rp, false)
	setHP(rp, rp.Stats.MaxHP * Config.Player.ReviveHPFraction)
	rp.InvulnUntil = os.clock() + Config.Player.ReviveInvulnSeconds
	rp.Player:SetAttribute("Alive", true)
	if rp.Root then
		ctx.EnemySpawner.KillInRadius(rp.Root.Position, Config.Player.ReviveClearRadius, rp)
		Fx.Ring(rp.Root.Position, Config.Player.ReviveClearRadius, Color3.fromRGB(255, 230, 120))
	end
	Fx.PlayerEvent(rp.Player, "revive")
	Remotes.FireClient("ReviveOffer", rp.Player, { Close = true })
	RunManager.Notify(rp.Player, message, Color3.fromRGB(255, 230, 120))
	RunManager.ApplyMovement(rp)
	-- resume level-ups that were waiting
	if rp.PendingLevels > 0 and not rp.Offer then
		ctx.LevelUpSystem.QueueLevels(rp, 0)
	end
end

local function finalizeDeath(rp)
	if not rp.Alive and not rp.AwaitingRevive then
		return
	end
	rp.Alive = false
	rp.AwaitingRevive = false
	rp.TimeSurvived = runTime
	rp.Player:SetAttribute("Alive", false)
	ctx.LevelUpSystem.Cancel(rp)
	ctx.WeaponSystem.ClearOwner(rp)
	setDownedLook(rp, true)
	Remotes.FireClient("ReviveOffer", rp.Player, { Close = true })
	Fx.PlayerEvent(rp.Player, "die")
	Fx.Sound("Death")
	local rules = reviveRules()
	if rules and #runPlayers > 1 and (rp.PartnerRevives or 0) < rules.PerRun then
		RunManager.Broadcast(rp.Player.DisplayName .. " has fallen! Stand next to them to revive.", Color3.fromRGB(255, 90, 90))
	else
		RunManager.Broadcast(rp.Player.DisplayName .. " has fallen!", Color3.fromRGB(255, 90, 90))
	end
	checkEnd()
end

--[[
	DUO / TRIO: a fallen player (dead, not waiting on the revive offer) is revived when a
	living teammate stands next to them for PartnerRevive.Seconds. Progress decays when
	the teammate steps away. Each player can be partner-revived a few times per run.
]]
partnerRevives = function(dt: number)
	local D = reviveRules()
	if not D then
		return
	end
	for _, rp in ipairs(runPlayers) do
		if not rp.Alive and not rp.AwaitingRevive and not rp.Returned and rp.Root and (rp.PartnerRevives or 0) < D.PerRun then
			local helper = nil
			for _, other in ipairs(runPlayers) do
				if other ~= rp and other.Alive and other.Root then
					if ((other.Root.Position - rp.Root.Position) * FLAT).Magnitude <= D.Radius then
						helper = other
					end
				end
			end
			local before = rp.ReviveProgress or 0
			if helper then
				rp.ReviveProgress = before + dt / D.Seconds
			else
				rp.ReviveProgress = math.max(0, before - dt / D.Seconds)
			end
			if math.abs((rp.ReviveProgress or 0) - before) > 0 then
				rp.Player:SetAttribute("ReviveProgress", math.clamp(rp.ReviveProgress, 0, 1))
			end
			if rp.ReviveProgress >= 1 and helper then
				rp.ReviveProgress = 0
				rp.Player:SetAttribute("ReviveProgress", 0)
				rp.PartnerRevives = (rp.PartnerRevives or 0) + 1
				rp.Player:SetAttribute("PartnerRevivesLeft", D.PerRun - rp.PartnerRevives)
				rp.TimeSurvived = 0
				revive(rp, "Revived by " .. helper.Player.DisplayName .. "!")
				setHP(rp, rp.Stats.MaxHP * D.HPFraction)
				RunManager.Notify(helper.Player, "You revived " .. rp.Player.DisplayName .. "!", Color3.fromRGB(120, 255, 160))
			end
		end
	end
end

local function onDowned(rp)
	setHP(rp, 0)
	if rp.RevivesLeft > 0 then
		rp.RevivesLeft -= 1
		revive(rp, "Extra life used!")
		return
	end
	local data = ctx.DataService.GetData(rp.Player)
	if data and (data.ReviveTokens or 0) > 0 and not rp.ProductReviveUsed then
		data.ReviveTokens -= 1
		rp.ProductReviveUsed = true
		revive(rp, "Revive used!")
		return
	end
	if not rp.ProductReviveUsed and ctx.MonetizationService.ReviveAvailable() then
		-- Downed: wait for the player to buy (or decline) the revive.
		rp.Alive = false
		rp.AwaitingRevive = true
		rp.ReviveDeadline = os.clock() + Config.Monetization.RevivePromptSeconds
		rp.Player:SetAttribute("Alive", false)
		ctx.WeaponSystem.ClearOwner(rp)
		setDownedLook(rp, true)
		Remotes.FireClient("ReviveOffer", rp.Player, { Seconds = Config.Monetization.RevivePromptSeconds, ProductId = Config.Monetization.Products.Revive })
		ctx.MonetizationService.PromptRevive(rp.Player)
		return
	end
	finalizeDeath(rp)
end

-- Server-only damage entry point (enemy contact, explosions, boss projectiles).
function RunManager.DamagePlayer(rp, amount: number)
	if phase ~= "Running" or frozen or not rp.Alive or endPending then
		return
	end
	if rp.Paused and Config.Player.LevelUpInvulnerable then
		return
	end
	local now = os.clock()
	if now < rp.InvulnUntil then
		return
	end
	local dmg = math.max(Config.Player.MinDamagePerHit, amount * rp.Stats.DamageTaken - rp.Stats.Armor)
	setHP(rp, rp.HP - dmg)
	if now - (rp.LastHurtFx or 0) > Config.Player.HurtFlashSeconds then
		rp.LastHurtFx = now
		Fx.PlayerEvent(rp.Player, "hurt")
	end
	if rp.HP <= 0 then
		onDowned(rp)
	end
end

-- A revive product was bought (MonetizationService). Spend the token now if possible.
function RunManager.OnReviveTokenGranted(player: Player)
	local rp = byPlayer[player]
	local data = ctx.DataService.GetData(player)
	-- Also revive a player whose offer timed out while Roblox's purchase dialog was open.
	local fallen = rp and not rp.Alive and (rp.AwaitingRevive or not rp.ProductReviveUsed)
	if rp and fallen and not rp.Returned and phase == "Running" and not endPending and data and data.ReviveTokens > 0 then
		data.ReviveTokens -= 1
		rp.ProductReviveUsed = true
		revive(rp, "Revived!")
	else
		RunManager.Notify(player, "Revive saved. It will be used automatically next time you fall.", Color3.fromRGB(255, 230, 120))
	end
	ctx.GoldSystem.SyncProfile(player)
end

------------------------------------------------------------------------------------------
-- Run lifecycle
------------------------------------------------------------------------------------------

local function newRunPlayer(player: Player)
	local data = ctx.DataService.GetData(player)
	local meta = table.clone(data.Meta)
	local function perRun(id: string): number
		local def = MetaUpgradeData.Upgrades[id]
		return (meta[id] or 0) * (def.PerRun or 1)
	end
	local rp = {
		Player = player,
		CharacterId = data.SelectedCharacter,
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
		Kills = 0,
		Gold = 0,
		DamageDealt = 0,
		TimeSurvived = 0,
		InvulnUntil = 0,
		Facing = Vector3.new(0, 0, -1),
		MoveDir = Vector3.zero,
		SpeedCheckTimer = 0,
		Returned = false,
	}
	return rp
end

local function resetPlayerAttributes(player: Player)
	for _, name in ipairs({ "HP", "MaxHP", "Level", "XP", "XPNeeded", "Kills", "RunGold", "AuraRadius" }) do
		player:SetAttribute(name, nil)
	end
	player:SetAttribute("InRun", false)
	player:SetAttribute("Alive", nil)
	player:SetAttribute("Paused", false)
	player:SetAttribute("AuraEvo", nil)
	player:SetAttribute("ReviveProgress", nil)
	player:SetAttribute("PartnerRevivesLeft", nil)
end

local function beginRun()
	local list = {}
	for player in pairs(joined) do
		if player.Parent and ctx.DataService.GetData(player) and #list < maxPlayers() then
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

	currentArena = selectedArena
	local arena = MapBuilder.BuildArena(currentArena)
	ctx.EnemyAI.SetArena(arena)
	state:SetAttribute("Arena", currentArena)

	runTime = 0
	frozen = false
	menuPaused = false
	miniWaveTimer = 0
	bossWarned = false
	bossSpawned = false
	endPending = false
	totalKills = 0
	state:SetAttribute("Frozen", false)
	state:SetAttribute("RunTime", 0)
	setPhase("Running")

	for i, player in ipairs(list) do
		local rp = newRunPlayer(player)
		table.insert(runPlayers, rp)
		byPlayer[player] = rp
		local a = (i / #list) * math.pi * 2
		local pos = arena.Center + Vector3.new(math.cos(a), 0, math.sin(a)) * (#list > 1 and Config.Run.ArenaSpawnSpread or 0) + Vector3.new(0, 3.5, 0)
		local model = spawnCharacter(player, CFrame.new(pos), false)
		RunManager.AttachCharacter(rp, model)

		local character = CharacterData.Characters[rp.CharacterId] or CharacterData.Characters[CharacterData.Default]
		ctx.LevelUpSystem.AddWeapon(rp, character.StartWeapon)
		ctx.LevelUpSystem.RecomputeStats(rp)
		setHP(rp, rp.Stats.MaxHP)
		player:SetAttribute("InRun", true)
		player:SetAttribute("Alive", true)
		player:SetAttribute("Level", 1)
		player:SetAttribute("XP", 0)
		player:SetAttribute("XPNeeded", rp.XPNeeded)
		player:SetAttribute("Kills", 0)
		player:SetAttribute("RunGold", 0)
		local rules = reviveRules()
		player:SetAttribute("PartnerRevivesLeft", rules and #list > 1 and rules.PerRun or 0)
		ctx.WeaponSystem.OnInventoryChanged(rp)
		ctx.LevelUpSystem.SendInventory(rp)
		RunManager.ApplyMovement(rp)

		local data = ctx.DataService.GetData(player)
		if data then
			data.Stats.Runs += 1
		end
	end
	state:SetAttribute("Participants", #runPlayers)
	RunManager.Broadcast("Survive until 15:00!", Color3.fromRGB(255, 230, 120), true)
end

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
		if rp.Alive or rp.AwaitingRevive then
			rp.TimeSurvived = runTime
			rp.AwaitingRevive = false
		end
		RunManager.ApplyMovement(rp)
		local player: Player = rp.Player
		local data = ctx.DataService.GetData(player)
		if won then
			ctx.GoldSystem.AddRunGold(rp, Config.Gold.WinBonus)
		end
		local newBest = false
		local unlocked = nil
		if data then
			data.Stats.TotalKills += rp.Kills
			if rp.TimeSurvived > data.Stats.BestTime then
				data.Stats.BestTime = math.floor(rp.TimeSurvived)
				newBest = true
			end
			if won then
				local before = data.Stats.Wins
				data.Stats.Wins += 1
				for _, name in ipairs(Config.Arenas.Order) do
					local req = Config.Arenas[name].RequiredWins
					if before < req and data.Stats.Wins >= req then
						unlocked = Config.Arenas[name].DisplayName
					end
				end
			end
			task.spawn(ctx.DataService.ForceSave, player)
		end
		Remotes.FireClient("RunResult", player, {
			Won = won,
			Time = math.floor(rp.TimeSurvived),
			Kills = rp.Kills,
			Gold = rp.Gold,
			Level = rp.Level,
			Damage = math.floor(rp.DamageDealt),
			Arena = Config.Arenas[currentArena].DisplayName .. ((mode == "Duo" or mode == "Trio") and (" (" .. mode .. ")") or ""),
			NewBest = newBest,
			Unlocked = unlocked,
			Seconds = Config.Run.ResultsSeconds,
		})
	end
	RunManager.Broadcast(won and "VICTORY!" or "THE SWARM WINS...", won and Color3.fromRGB(255, 220, 80) or Color3.fromRGB(255, 80, 80), true)
end

local function returnPlayerToLobby(rp)
	if rp.Returned then
		return
	end
	rp.Returned = true
	local player: Player = rp.Player
	if player.Parent then
		resetPlayerAttributes(player)
		spawnCharacter(player, lobbySpawnCFrame(), true)
		ctx.GoldSystem.SyncProfile(player)
	end
end

local function returnAll()
	for _, rp in ipairs(runPlayers) do
		returnPlayerToLobby(rp)
	end
	table.clear(runPlayers)
	table.clear(byPlayer)
	ctx.EnemySpawner.DespawnAll()
	ctx.WeaponSystem.Clear()
	ctx.XPSystem.Clear()
	ctx.EnemyAI.SetArena(nil)
	MapBuilder.DestroyArena()
	MapBuilder.ApplyLighting("Lobby")
	state:SetAttribute("Participants", 0)
	state:SetAttribute("RunTime", 0)
	setPhase("Lobby")
end

function RunManager.OnBossKilled(_pos: Vector3)
	if endPending or phase ~= "Running" then
		return
	end
	endPending = true
	for _, rp in ipairs(runPlayers) do
		if rp.Alive then
			ctx.GoldSystem.AddRunGold(rp, Config.Gold.Boss)
		end
	end
	RunManager.Broadcast("BOSS DEFEATED!", Color3.fromRGB(255, 220, 80), true)
	task.delay(2.5, function()
		endPending = false
		RunManager.EndRun(true)
	end)
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

--[[
	A lobby mode button. Solo starts at once; Duo / Trio (and the old Squad) count down
	so others can join. During a countdown any mode button just joins it.
]]
local function startRun(player: Player, newMode: string)
	if phase == "Countdown" then
		tryJoin(player)
		return
	end
	if phase ~= "Lobby" or not ctx.DataService.GetData(player) or not isMode(newMode) then
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
		return
	end
	starter = player
	setPhase("Countdown")
	countdown = Config.Run.CountdownSeconds
	state:SetAttribute("Countdown", countdown)
	publishJoined()
	tryJoin(player)
	if (phase :: string) == "Countdown" then -- tryJoin may have started a full run
		RunManager.Broadcast(player.DisplayName .. " is starting a " .. string.upper(modeDef().DisplayName) .. " run! Tap JOIN to play.", Color3.fromRGB(120, 255, 160))
	end
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

local function cycleArena(player: Player)
	if phase ~= "Lobby" then
		return
	end
	local data = ctx.DataService.GetData(player)
	if not data then
		return
	end
	local order = Config.Arenas.Order
	local index = table.find(order, selectedArena) or 1
	for step = 1, #order do
		local name = order[((index - 1 + step) % #order) + 1]
		if data.Stats.Wins >= Config.Arenas[name].RequiredWins then
			if name == selectedArena then
				break
			end
			selectedArena = name
			state:SetAttribute("SelectedArena", name)
			if lobby.ArenaLabel then
				lobby.ArenaLabel.Text = "ARENA: " .. string.upper(Config.Arenas[name].DisplayName)
			end
			RunManager.Broadcast("Arena set to " .. Config.Arenas[name].DisplayName, Color3.fromRGB(255, 220, 120))
			return
		end
	end
	RunManager.Notify(player, "Win a run to unlock the next arena!", Color3.fromRGB(255, 200, 120))
end

------------------------------------------------------------------------------------------
-- Dev tools (Studio or the game's creator; the client button is only a shortcut)
------------------------------------------------------------------------------------------

local function isDev(player: Player): boolean
	if not Config.Dev.Enabled then
		return false
	end
	if RunService:IsStudio() then
		return true
	end
	return game.CreatorType == Enum.CreatorType.User and player.UserId == game.CreatorId
end

local function devCommand(player: Player, command: any)
	if type(command) ~= "string" or not isDev(player) then
		return
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
	elseif command == "AddLevels" then
		local rp = byPlayer[player]
		if rp and not rp.Returned and rp.Alive and phase == "Running" then
			for _ = 1, Config.Dev.AddLevels do
				ctx.XPSystem.GiveXP(rp, math.max(0, rp.XPNeeded - rp.XP))
			end
		end
	elseif command == "SkipToBoss" then
		local rp = byPlayer[player]
		if rp and not rp.Returned and phase == "Running" and not bossSpawned and runTime < Config.Dev.SkipToTime then
			runTime = Config.Dev.SkipToTime
			miniWaveTimer = 0
			state:SetAttribute("RunTime", runTime)
			RunManager.Broadcast("DEV: skipped to " .. string.format("%d:%02d", runTime // 60, runTime % 60), Color3.fromRGB(255, 160, 255))
		end
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
		-- rebuild with the uploaded meshes once they have loaded
		if ctx.MeshService and ctx.MeshService.WhenReady then
			ctx.MeshService.WhenReady({ id }, function()
				buildPreviews(id)
			end)
		end
	end
end

------------------------------------------------------------------------------------------
-- Per-frame
------------------------------------------------------------------------------------------

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
	local maxSpeed = (rp.Paused or frozen or not rp.Alive) and 0 or math.max(rp.Stats.Speed, Config.Player.BaseSpeed)
	local allowed = maxSpeed * elapsed * Config.Player.SpeedCheckTolerance + Config.Player.SpeedCheckAllowance
	if moved > allowed or pos.Y < Config.ArenaOrigin.Y - 20 then
		root.CFrame = CFrame.new(last + Vector3.new(0, 0.5, 0)) * root.CFrame.Rotation
		root.AssemblyLinearVelocity = Vector3.zero
	else
		rp.LastValidPos = pos
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
			returnAll()
		end
		return
	end

	if phase ~= "Running" then
		return
	end

	local now = os.clock()
	for _, rp in ipairs(runPlayers) do
		local root: BasePart? = rp.Root
		if root and root.Parent then
			local look = root.CFrame.LookVector * FLAT
			if look.Magnitude > 0.1 then
				rp.Facing = look.Unit
			end
			local v = root.AssemblyLinearVelocity * FLAT
			rp.MoveDir = v.Magnitude > 2 and v.Unit or Vector3.zero
		end
		if rp.Alive then
			speedCheck(rp, dt)
		end
		if rp.AwaitingRevive then
			-- only the pause menu stops this clock; the client counts down the same deadline
			if menuPaused then
				rp.ReviveDeadline += dt
			elseif now >= rp.ReviveDeadline then
				finalizeDeath(rp)
			end
		end
	end
	if reviveRules() and not frozen and not endPending then
		partnerRevives(dt)
	end

	if frozen then
		return
	end

	runTime += dt
	attrTimer += dt
	if attrTimer >= 0.2 then
		attrTimer = 0
		state:SetAttribute("RunTime", math.floor(runTime * 10) / 10)
	end

	if not bossSpawned then
		miniWaveTimer += dt
		if miniWaveTimer >= Config.Run.MiniWaveInterval then
			miniWaveTimer = 0
			ctx.EnemySpawner.MiniWave()
		end
		if not bossWarned and runTime >= Config.Run.BossTime - Config.Boss.SpawnWarningSeconds then
			bossWarned = true
			RunManager.Broadcast("THE BOSS IS COMING!", Color3.fromRGB(255, 60, 60), true)
		end
		if runTime >= Config.Run.BossTime then
			bossSpawned = true
			ctx.EnemySpawner.SpawnBoss()
		end
	end
end

------------------------------------------------------------------------------------------
-- Players joining / leaving
------------------------------------------------------------------------------------------

function RunManager.OnPlayerRemoving(player: Player)
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
	end
	local rp = byPlayer[player]
	if not rp then
		return
	end
	if phase == "Running" and not rp.Returned then
		local data = ctx.DataService.GetData(player)
		if data then
			data.Stats.TotalKills += rp.Kills
			local t = (rp.Alive or rp.AwaitingRevive) and runTime or rp.TimeSurvived
			if t > data.Stats.BestTime then
				data.Stats.BestTime = math.floor(t)
			end
		end
	end
	-- other systems may still hold this record (enemy targets, delayed whip slashes)
	rp.Alive = false
	rp.AwaitingRevive = false
	rp.Root = nil
	ctx.WeaponSystem.ClearOwner(rp)
	local i = table.find(runPlayers, rp)
	if i then
		table.remove(runPlayers, i)
	end
	byPlayer[player] = nil
	state:SetAttribute("Participants", #runPlayers)
	if menuPaused and #runPlayers > 1 then
		menuPaused = false
	end
	RunManager.RefreshFrozen()
	if phase == "Running" then
		if #runPlayers == 0 then
			RunManager.EndRun(false)
		else
			checkEnd()
		end
	end
end

-- Commits stats of everyone in a run (server shutdown).
function RunManager.CommitAll()
	for _, rp in ipairs(runPlayers) do
		if not rp.Returned then
			local data = ctx.DataService.GetData(rp.Player)
			if data and phase == "Running" then
				data.Stats.TotalKills += rp.Kills
				rp.Kills = 0
			end
		end
	end
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

	Remotes.Listen("StartNow", startNow, 2)
	Remotes.Listen("CycleArena", cycleArena, 3)
	Remotes.Listen("DevCommand", devCommand, 3)

	Remotes.Listen("JoinRun", function(player)
		if phase == "Countdown" then
			tryJoin(player)
		end
		-- in the Lobby phase JOIN does nothing: a late tap must not start a hidden run
	end, 2)

	Remotes.Listen("ReturnToLobby", function(player)
		local rp = byPlayer[player]
		if rp and phase == "Results" then
			returnPlayerToLobby(rp)
		end
	end, 2)

	Remotes.Listen("SetPause", function(player, open)
		local rp = byPlayer[player]
		if not rp or phase ~= "Running" or type(open) ~= "boolean" then
			return
		end
		menuPaused = open and Config.Run.SoloPauseFreezesRun and #runPlayers == 1
		RunManager.RefreshFrozen()
	end, 4)

	Remotes.Listen("ReviveDecline", function(player)
		local rp = byPlayer[player]
		if rp and rp.AwaitingRevive then
			finalizeDeath(rp)
		end
	end, 2)

	ctx.DataService.OnProfileLoaded(function(player)
		ctx.MonetizationService.RefreshAttributes(player)
		resetPlayerAttributes(player)
		spawnCharacter(player, lobbySpawnCFrame(), true)
	end)
end

return RunManager
