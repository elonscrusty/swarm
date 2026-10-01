--[[
	RunManager.lua
	The run state machine and everything about players' bodies and lives.

	Phases (SwarmState attribute "Phase"):
	  Lobby      players walk around the lobby, shop, pick characters
	  Countdown  someone pressed Start; 10 s for others to join (prompt or HUD button)
	  Running    the run: timer counts up, mini-waves every 30 s, boss at 15:00
	  Results    win / lose screen; everyone returns after Config.Run.ResultsSeconds

	Each participant gets a "run player" record (rp) that every other system uses:
	  Player, Character, Root, Humanoid, CharacterId, Meta, Stats, HP, Level, XP, XPNeeded,
	  Weapons, WeaponOrder, Passives, PassiveOrder, PendingLevels, Offer, Paused, Alive,
	  AwaitingRevive, RevivesLeft, Rerolls, Skips, Kills, Gold, DamageDealt, TimeSurvived,
	  Facing, MoveDir, InvulnUntil, Returned
	HP lives here (not in the Humanoid): the Humanoid's Dead state is disabled.
]]

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
local runPlayers: { any } = {} -- array of rp
local byPlayer: { [Player]: any } = {}
local runTime = 0
local frozen = false
local miniWaveTimer = 0
local bossWarned = false
local bossSpawned = false
local endPending = false
local resultsTimer = 0
local totalKills = 0
local attrTimer = 0
local selectedArena = "Backyard"
local currentArena = "Backyard"
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

local function setPhase(newPhase: string)
	phase = newPhase
	state:SetAttribute("Phase", newPhase)
	if lobby then
		local p: ProximityPrompt = lobby.StartPrompt
		if newPhase == "Lobby" then
			p.Enabled = true
			p.ActionText = "Start Run"
		elseif newPhase == "Countdown" then
			p.Enabled = true
			p.ActionText = "Join Run"
		else
			p.Enabled = false
		end
	end
end

------------------------------------------------------------------------------------------
-- Characters
------------------------------------------------------------------------------------------

local spawnCharacter -- forward declaration

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
	humanoid.WalkSpeed = inLobby and Config.Player.BaseSpeed + 2 or Config.Player.BaseSpeed
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
	RunManager.Broadcast(rp.Player.DisplayName .. " has fallen!", Color3.fromRGB(255, 90, 90))
	checkEnd()
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
end

local function beginRun()
	local list = {}
	for player in pairs(joined) do
		if player.Parent and ctx.DataService.GetData(player) and #list < Config.Run.MaxPlayers then
			table.insert(list, player)
		end
	end
	table.clear(joined)
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
	state:SetAttribute("Frozen", false)
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
			Arena = Config.Arenas[currentArena].DisplayName,
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

local function tryJoin(player: Player)
	if phase ~= "Countdown" or joined[player] or not ctx.DataService.GetData(player) then
		return
	end
	local n = 0
	for _ in pairs(joined) do
		n += 1
	end
	if n >= Config.Run.MaxPlayers then
		RunManager.Notify(player, "This run is full.", Color3.fromRGB(255, 120, 120))
		return
	end
	joined[player] = true
	state:SetAttribute("Joined", n + 1)
	RunManager.Notify(player, "You joined the run!", Color3.fromRGB(120, 255, 160))
	Remotes.FireClient("OpenPanel", player, "Joined")
end

local function startCountdown(player: Player)
	if phase == "Countdown" then
		tryJoin(player)
		return
	end
	if phase ~= "Lobby" or not ctx.DataService.GetData(player) then
		return
	end
	setPhase("Countdown")
	countdown = Config.Run.CountdownSeconds
	state:SetAttribute("Countdown", countdown)
	table.clear(joined)
	tryJoin(player)
	RunManager.Broadcast(player.DisplayName .. " is starting a run! Tap JOIN to play.", Color3.fromRGB(120, 255, 160))
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
	RunManager.Notify(player, "Win a run to unlock the Mall arena!", Color3.fromRGB(255, 200, 120))
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
			if frozen then
				rp.ReviveDeadline += dt
			elseif now >= rp.ReviveDeadline then
				finalizeDeath(rp)
			end
		end
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
	joined[player] = nil
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
	if frozen and #runPlayers <= 1 then
		frozen = false
		state:SetAttribute("Frozen", false)
	end
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
	setPhase("Lobby")
end

function RunManager.Start()
	lobby.StartPrompt.Triggered:Connect(startCountdown)
	lobby.ArenaPrompt.Triggered:Connect(cycleArena)
	lobby.CharacterPrompt.Triggered:Connect(function(player)
		Remotes.FireClient("OpenPanel", player, "Characters")
	end)
	lobby.ShopPrompt.Triggered:Connect(function(player)
		Remotes.FireClient("OpenPanel", player, "Shop")
	end)

	Remotes.Listen("JoinRun", function(player)
		if phase == "Countdown" then
			tryJoin(player)
		elseif phase == "Lobby" then
			startCountdown(player)
		end
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
		if open and Config.Run.SoloPauseFreezesRun and #runPlayers == 1 then
			frozen = true
		elseif not open then
			frozen = false
		end
		state:SetAttribute("Frozen", frozen)
		for _, other in ipairs(runPlayers) do
			RunManager.ApplyMovement(other)
		end
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
