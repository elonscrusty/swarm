--[[
	LevelUpSystem.lua
	Stat sheets, level-up offers (3 cards, reroll, skip, auto-pick), weapon / passive
	upgrades, evolutions and treasure chest rewards.

	A player with pending levels is "Paused": they stop moving, their weapons stop and
	(Config.Player.LevelUpInvulnerable) they can't be hurt. The rest of the server keeps
	running. If they don't choose within Config.LevelUp.AutoPickSeconds a random card
	is taken for them.

	Card types: WeaponNew, WeaponUp, Evolve, PassiveNew, PassiveUp, Gold, Heal.
	Only the card index comes from the client; the server owns the card list.
]]

local Config = require(game:GetService("ReplicatedStorage").Shared.Config)
local Remotes = require(game:GetService("ReplicatedStorage").Shared.Remotes)
local WeaponData = require(game:GetService("ReplicatedStorage").Shared.WeaponData)
local PassiveData = require(game:GetService("ReplicatedStorage").Shared.PassiveData)
local CharacterData = require(game:GetService("ReplicatedStorage").Shared.CharacterData)
local MetaUpgradeData = require(game:GetService("ReplicatedStorage").Shared.MetaUpgradeData)
local Fx = require(script.Parent.Fx)

local LevelUpSystem = {}

local ctx
local rng = Random.new()

------------------------------------------------------------------------------------------
-- Stats
------------------------------------------------------------------------------------------

local BONUS_KEYS = { "might", "armor", "maxHpMult", "maxHpFlat", "speed", "cooldown", "area", "amount", "pickup", "luck", "projSpeed", "duration", "growth", "damageTaken" }

-- Rebuilds rp.Stats from base config + character + meta upgrades + passives.
function LevelUpSystem.RecomputeStats(rp)
	local b = {}
	for _, k in ipairs(BONUS_KEYS) do
		b[k] = 0
	end
	local function addAll(t)
		if not t then
			return
		end
		for k, v in pairs(t) do
			if b[k] ~= nil then
				b[k] += v
			end
		end
	end

	local character = CharacterData.Characters[rp.CharacterId]
	addAll(character and character.Bonus)

	for upgradeId, level in pairs(rp.Meta) do
		local def = MetaUpgradeData.Upgrades[upgradeId]
		if def and def.PerLevel then
			for k, v in pairs(def.PerLevel) do
				if b[k] ~= nil then
					b[k] += v * level
				end
			end
		end
	end

	for passiveId, level in pairs(rp.Passives) do
		local def = PassiveData.Passives[passiveId]
		if def then
			addAll(def.Values[level])
		end
	end

	local P = Config.Player
	local oldMax = rp.Stats and rp.Stats.MaxHP or nil
	rp.Stats = {
		Might = 1 + b.might,
		Armor = P.BaseArmor + b.armor,
		MaxHP = math.floor((P.BaseMaxHP + b.maxHpFlat) * (1 + b.maxHpMult) + 0.5),
		Speed = P.BaseSpeed * (1 + b.speed),
		CooldownMult = math.max(0.4, 1 - b.cooldown),
		AreaMult = 1 + b.area,
		Amount = b.amount,
		PickupRadius = P.BasePickupRadius * (1 + b.pickup),
		Luck = P.BaseLuck + b.luck,
		ProjSpeedMult = 1 + b.projSpeed,
		DurationMult = 1 + b.duration,
		Growth = 1 + b.growth,
		DamageTaken = math.max(0.1, 1 + b.damageTaken),
	}
	-- Max HP increases also heal by the same amount.
	if oldMax and rp.Stats.MaxHP > oldMax then
		rp.HP += rp.Stats.MaxHP - oldMax
	end
	if rp.HP then
		rp.HP = math.min(rp.HP, rp.Stats.MaxHP)
	end
	local player: Player = rp.Player
	player:SetAttribute("MaxHP", rp.Stats.MaxHP)
	if rp.HP then
		player:SetAttribute("HP", rp.HP)
	end
	ctx.RunManager.ApplyMovement(rp)
end

------------------------------------------------------------------------------------------
-- Inventory
------------------------------------------------------------------------------------------

function LevelUpSystem.SendInventory(rp)
	local weapons = {}
	for _, id in ipairs(rp.WeaponOrder) do
		local w = rp.Weapons[id]
		local def = WeaponData.Weapons[id]
		table.insert(weapons, {
			Id = id,
			Name = w.Evolved and def.Evolution.Name or def.Name,
			Level = w.Level,
			Evolved = w.Evolved,
			Color = def.Color,
		})
	end
	local passives = {}
	for _, id in ipairs(rp.PassiveOrder) do
		local def = PassiveData.Passives[id]
		table.insert(passives, { Id = id, Name = def.Name, Level = rp.Passives[id], Color = def.Color })
	end
	Remotes.FireClient("Inventory", rp.Player, {
		Weapons = weapons,
		Passives = passives,
		Rerolls = rp.Rerolls,
		Skips = rp.Skips,
		WeaponSlots = Config.Slots.Weapons,
		PassiveSlots = Config.Slots.Passives,
	})
end

function LevelUpSystem.AddWeapon(rp, weaponId: string): boolean
	if rp.Weapons[weaponId] or not WeaponData.Weapons[weaponId] then
		return false
	end
	if #rp.WeaponOrder >= Config.Slots.Weapons then
		return false
	end
	rp.Weapons[weaponId] = { Id = weaponId, Level = 1, Evolved = false, Timer = 0.3, Live = {}, Growth = 0 }
	table.insert(rp.WeaponOrder, weaponId)
	return true
end

local function afterChange(rp)
	LevelUpSystem.RecomputeStats(rp)
	ctx.WeaponSystem.OnInventoryChanged(rp)
	LevelUpSystem.SendInventory(rp)
end

local function canEvolve(rp, weaponId: string): boolean
	local w = rp.Weapons[weaponId]
	local def = WeaponData.Weapons[weaponId]
	return w ~= nil and not w.Evolved and w.Level >= WeaponData.MaxLevel and def.Evolution ~= nil and (rp.Passives[def.Evolution.Passive] or 0) > 0
end

------------------------------------------------------------------------------------------
-- Cards
------------------------------------------------------------------------------------------

local function card(kind: string, id: string, level: number, weight: number)
	return { Type = kind, Id = id, Level = level, Weight = weight }
end

local function buildPool(rp)
	local L = Config.LevelUp
	local luck = 1 + rp.Stats.Luck
	local pool = {}
	for _, id in ipairs(rp.WeaponOrder) do
		local w = rp.Weapons[id]
		if canEvolve(rp, id) then
			table.insert(pool, card("Evolve", id, WeaponData.MaxLevel, L.WeightEvolution))
		elseif not w.Evolved and w.Level < WeaponData.MaxLevel then
			table.insert(pool, card("WeaponUp", id, w.Level + 1, L.WeightUpgradeWeapon))
		end
	end
	if #rp.WeaponOrder < Config.Slots.Weapons then
		for _, id in ipairs(WeaponData.Order) do
			if not rp.Weapons[id] then
				table.insert(pool, card("WeaponNew", id, 1, L.WeightNewWeapon * luck))
			end
		end
	end
	for _, id in ipairs(rp.PassiveOrder) do
		local level = rp.Passives[id]
		if level < PassiveData.MaxLevel then
			table.insert(pool, card("PassiveUp", id, level + 1, L.WeightUpgradePassive))
		end
	end
	if #rp.PassiveOrder < Config.Slots.Passives then
		for _, id in ipairs(PassiveData.Order) do
			if not rp.Passives[id] then
				table.insert(pool, card("PassiveNew", id, 1, L.WeightNewPassive * luck))
			end
		end
	end
	return pool
end

-- Adds display fields (name, text, rarity colour) to a card for the client.
local function decorate(c)
	local rarity = "Common"
	if c.Type == "WeaponNew" or c.Type == "WeaponUp" then
		local def = WeaponData.Weapons[c.Id]
		c.Name = def.Name
		c.Description = WeaponData.DescribeLevel(c.Id, c.Level)
		c.Color = def.Color
		if c.Type == "WeaponNew" then
			rarity = "Rare"
		elseif c.Level >= WeaponData.MaxLevel then
			rarity = "Epic"
			c.Description ..= string.format(" (Max. Evolves with %s)", PassiveData.Passives[def.Evolution.Passive].Name)
		end
	elseif c.Type == "Evolve" then
		local def = WeaponData.Weapons[c.Id]
		c.Name = def.Evolution.Name
		c.Description = def.Evolution.Description
		c.Color = def.Color
		rarity = "Legendary"
	elseif c.Type == "PassiveNew" or c.Type == "PassiveUp" then
		local def = PassiveData.Passives[c.Id]
		c.Name = def.Name
		c.Description = PassiveData.DescribeLevel(c.Id, c.Level)
		c.Color = def.Color
		if c.Type == "PassiveNew" then
			rarity = "Rare"
		elseif c.Level >= PassiveData.MaxLevel then
			rarity = "Epic"
		end
	elseif c.Type == "Gold" then
		c.Name = "Gold Pouch"
		c.Description = string.format("+%d gold.", Config.LevelUp.FallbackGold)
		c.Color = Color3.fromRGB(255, 210, 60)
	elseif c.Type == "Heal" then
		c.Name = "Roast Chicken"
		c.Description = string.format("Heal %d HP.", Config.LevelUp.FallbackHeal)
		c.Color = Color3.fromRGB(200, 120, 60)
	end
	c.Rarity = rarity
	c.RarityLabel = Config.LevelUp.Rarities[rarity].Label
	c.RarityColor = Config.LevelUp.Rarities[rarity].Color
	c.Weight = nil
	return c
end

local function rollChoices(rp)
	local pool = buildPool(rp)
	local choices = {}
	for _ = 1, Config.LevelUp.Choices do
		local total = 0
		for _, c in ipairs(pool) do
			total += c.Weight
		end
		if total <= 0 then
			break
		end
		local roll = rng:NextNumber() * total
		for i, c in ipairs(pool) do
			roll -= c.Weight
			if roll <= 0 then
				table.insert(choices, decorate(c))
				table.remove(pool, i)
				break
			end
		end
	end
	if #choices == 0 then
		table.insert(choices, decorate(card("Gold", "Gold", 0, 1)))
		table.insert(choices, decorate(card("Heal", "Heal", 0, 1)))
	end
	return choices
end

local function apply(rp, c)
	if c.Type == "WeaponNew" then
		LevelUpSystem.AddWeapon(rp, c.Id)
	elseif c.Type == "WeaponUp" then
		local w = rp.Weapons[c.Id]
		if w and not w.Evolved then
			w.Level = math.min(WeaponData.MaxLevel, w.Level + 1)
		end
	elseif c.Type == "Evolve" then
		if canEvolve(rp, c.Id) then
			rp.Weapons[c.Id].Evolved = true
			ctx.RunManager.Notify(rp.Player, WeaponData.Weapons[c.Id].Evolution.Name .. "!", Color3.fromRGB(255, 210, 60))
		end
	elseif c.Type == "PassiveNew" then
		if not rp.Passives[c.Id] and #rp.PassiveOrder < Config.Slots.Passives then
			rp.Passives[c.Id] = 1
			table.insert(rp.PassiveOrder, c.Id)
		end
	elseif c.Type == "PassiveUp" then
		if rp.Passives[c.Id] then
			rp.Passives[c.Id] = math.min(PassiveData.MaxLevel, rp.Passives[c.Id] + 1)
		end
	elseif c.Type == "Gold" then
		ctx.GoldSystem.AddRunGold(rp, Config.LevelUp.FallbackGold)
	elseif c.Type == "Heal" then
		ctx.RunManager.Heal(rp, Config.LevelUp.FallbackHeal)
	end
	afterChange(rp)
end

------------------------------------------------------------------------------------------
-- Offer flow
------------------------------------------------------------------------------------------

local function sendOffer(rp)
	Remotes.FireClient("LevelUpOffer", rp.Player, {
		Choices = rp.Offer,
		Rerolls = rp.Rerolls,
		Skips = rp.Skips,
		Seconds = math.max(0, rp.OfferDeadline - os.clock()),
		Level = rp.Level - rp.PendingLevels + 1,
		Pending = rp.PendingLevels,
	})
end

local function offerNext(rp)
	if rp.PendingLevels <= 0 or not rp.Alive then
		rp.PendingLevels = math.max(0, rp.PendingLevels)
		if rp.Offer then
			rp.Offer = nil
		end
		Remotes.FireClient("LevelUpClose", rp.Player)
		rp.Paused = false
		ctx.RunManager.ApplyMovement(rp)
		ctx.RunManager.RefreshFrozen()
		return
	end
	rp.Offer = rollChoices(rp)
	local group = #ctx.RunManager.GetRunPlayers() > 1
	rp.OfferDeadline = os.clock() + (group and Config.LevelUp.GroupAutoPickSeconds or Config.LevelUp.AutoPickSeconds)
	rp.Paused = true
	ctx.RunManager.ApplyMovement(rp)
	ctx.RunManager.RefreshFrozen()
	sendOffer(rp)
end

function LevelUpSystem.QueueLevels(rp, count: number)
	rp.PendingLevels += count
	Fx.PlayerEvent(rp.Player, "levelup")
	if not rp.Offer then
		offerNext(rp)
	end
end

local function choose(rp, index: number)
	local offer = rp.Offer
	if not offer then
		return
	end
	local c = offer[index]
	if not c then
		return
	end
	rp.Offer = nil
	rp.PendingLevels -= 1
	-- offerNext must always run (it releases the whole-run freeze), even if apply fails
	local ok, err = pcall(apply, rp, c)
	offerNext(rp)
	if not ok then
		warn("[LevelUpSystem] apply failed: " .. tostring(err))
	end
end

-- Ends any open offer without applying it (death, leaving, run end).
function LevelUpSystem.Cancel(rp)
	rp.Offer = nil
	rp.PendingLevels = 0
	rp.Paused = false
	if rp.Player.Parent then
		Remotes.FireClient("LevelUpClose", rp.Player)
	end
	ctx.RunManager.RefreshFrozen()
end

------------------------------------------------------------------------------------------
-- Chests
------------------------------------------------------------------------------------------

local function chestLevelUp(rp, rewards)
	-- 1) an available evolution
	for _, id in ipairs(rp.WeaponOrder) do
		if canEvolve(rp, id) then
			rp.Weapons[id].Evolved = true
			local def = WeaponData.Weapons[id]
			table.insert(rewards, { Name = def.Evolution.Name, Text = "EVOLVED!", Color = def.Color })
			return true
		end
	end
	-- 2) a random owned weapon below max
	local candidates = {}
	for _, id in ipairs(rp.WeaponOrder) do
		local w = rp.Weapons[id]
		if not w.Evolved and w.Level < WeaponData.MaxLevel then
			table.insert(candidates, id)
		end
	end
	if #candidates > 0 then
		local id = candidates[rng:NextInteger(1, #candidates)]
		local w = rp.Weapons[id]
		w.Level += 1
		local def = WeaponData.Weapons[id]
		table.insert(rewards, { Name = def.Name, Text = "Level " .. w.Level, Color = def.Color })
		return true
	end
	-- 3) a random owned passive below max
	table.clear(candidates)
	for _, id in ipairs(rp.PassiveOrder) do
		if rp.Passives[id] < PassiveData.MaxLevel then
			table.insert(candidates, id)
		end
	end
	if #candidates > 0 then
		local id = candidates[rng:NextInteger(1, #candidates)]
		rp.Passives[id] += 1
		local def = PassiveData.Passives[id]
		table.insert(rewards, { Name = def.Name, Text = "Level " .. rp.Passives[id], Color = def.Color })
		return true
	end
	return false
end

function LevelUpSystem.OpenChest(rp)
	local rewards = {}
	chestLevelUp(rp, rewards)
	if rng:NextNumber() < Config.Drops.ChestBonusLevelChance * (1 + rp.Stats.Luck) then
		chestLevelUp(rp, rewards)
	end
	local gold = ctx.GoldSystem.AddRunGold(rp, rng:NextInteger(Config.Gold.ChestGoldMin, Config.Gold.ChestGoldMax) + Config.Gold.Elite)
	afterChange(rp)
	Remotes.FireClient("ChestOpened", rp.Player, { Rewards = rewards, Gold = gold })
	Fx.Sound("Chest")
end

------------------------------------------------------------------------------------------
-- Lifecycle
------------------------------------------------------------------------------------------

function LevelUpSystem.Step(dt: number)
	-- Level-up pauses freeze the run too, but only the pause menu stops the auto-pick timer
	-- (otherwise a player could hold everyone's game paused forever).
	local menuPaused = ctx.RunManager.IsMenuPaused()
	local now = os.clock()
	for _, rp in ipairs(ctx.RunManager.GetRunPlayers()) do
		if rp.Offer then
			if menuPaused then
				rp.OfferDeadline += dt -- the solo pause menu also pauses the auto-pick timer
			elseif now >= rp.OfferDeadline then
				choose(rp, rng:NextInteger(1, #rp.Offer))
			end
		end
	end
end

function LevelUpSystem.Init(c)
	ctx = c
end

function LevelUpSystem.Start()
	Remotes.Listen("LevelUpChoose", function(player, index)
		local rp = ctx.RunManager.GetRunPlayer(player)
		if not rp or type(index) ~= "number" or index ~= index then
			return
		end
		index = math.floor(index)
		if index < 1 or index > Config.LevelUp.Choices + 1 then
			return
		end
		choose(rp, index)
	end, 6)

	Remotes.Listen("LevelUpReroll", function(player)
		local rp = ctx.RunManager.GetRunPlayer(player)
		if not rp or not rp.Offer or rp.Rerolls <= 0 then
			return
		end
		rp.Rerolls -= 1
		rp.Offer = rollChoices(rp)
		-- keep the original deadline: rerolling must not extend the protected pause
		sendOffer(rp)
		LevelUpSystem.SendInventory(rp)
	end, 3)

	Remotes.Listen("LevelUpSkip", function(player)
		local rp = ctx.RunManager.GetRunPlayer(player)
		if not rp or not rp.Offer or rp.Skips <= 0 then
			return
		end
		rp.Skips -= 1
		rp.Offer = nil
		rp.PendingLevels -= 1
		ctx.GoldSystem.AddRunGold(rp, Config.LevelUp.SkipGold)
		LevelUpSystem.SendInventory(rp)
		offerNext(rp)
	end, 3)
end

return LevelUpSystem
