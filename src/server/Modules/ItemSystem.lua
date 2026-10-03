--[[
	ItemSystem.lua
	Run items (src/shared/ItemData.lua): granting, rolling, the client list and every item
	behaviour. Items live on the run player record and die with it, so they are kept across
	stages and gone when the run ends (return, defeat, leaving):
	  rp.Items       { [itemId] = count }
	  rp.ItemOrder   ids in the order they were first found (HUD strip order)
	  rp.ItemState   proc timers / counters (cooldowns, shot counter, shield, regen)

	Stat items work through the normal stat sheet (LevelUpSystem.RecomputeStats reads
	ItemData.Bonus). Behaviour items hook into the game here:
	  ModifyHit / OnHit   EnemySpawner.Damage: critical hits, Storm Charm lightning
	  OnKill              EnemySpawner.Kill: Healing Herb, Volatile Spore
	  AbsorbHit / OnHurt  RunManager.DamagePlayer: Guardian Ward shield, Barbed Mail thorns
	  ExtraShot           WeaponSystem: Spare Quiver
	  TryRevive           RunManager (falling): Phoenix Feather (used up)
	  Step                regeneration, shield refill, Magnet Totem pulses
	Proc damage is dealt with isProc = true, so procs never crit or trigger more procs.

	Player attributes for the HUD: Shield, ShieldMax.
]]

local Config = require(game:GetService("ReplicatedStorage").Shared.Config)
local Remotes = require(game:GetService("ReplicatedStorage").Shared.Remotes)
local ItemData = require(game:GetService("ReplicatedStorage").Shared.ItemData)
local Palette = require(game:GetService("ReplicatedStorage").Shared.Palette)
local WeaponData = require(game:GetService("ReplicatedStorage").Shared.WeaponData)
local Fx = require(script.Parent.Fx)

local ItemSystem = {}

local ctx
local rng = Random.new()
local queryBuf = {}

local function count(rp, id: string): number
	local items = rp.Items
	return items and items[id] or 0
end
ItemSystem.Count = count

local function state(rp)
	local s = rp.ItemState
	if not s then
		s = { Shots = {}, LightningAt = 0, ExplodeAt = 0, ThornsAt = 0, LastHurt = 0, Shield = 0, ShownShield = -1, Regen = 0, RegenTimer = 0, MagnetTimer = 0 }
		rp.ItemState = s
	end
	return s
end

------------------------------------------------------------------------------------------
-- Inventory
------------------------------------------------------------------------------------------

-- { {Id, Count}, ... } in the order the items were found.
function ItemSystem.Summary(rp): { { Id: string, Count: number } }
	local list = {}
	for _, id in ipairs(rp.ItemOrder or {}) do
		local n = count(rp, id)
		if n > 0 then
			table.insert(list, { Id = id, Count = n })
		end
	end
	return list
end

function ItemSystem.Send(rp)
	local player: Player = rp.Player
	if player.Parent then
		Remotes.FireClient("Items", player, ItemSystem.Summary(rp))
	end
end

-- Recomputes the stat sheet after items (or the stage's team boon) changed.
function ItemSystem.Refresh(rp)
	ctx.LevelUpSystem.RecomputeStats(rp)
	ctx.WeaponSystem.OnInventoryChanged(rp)
	ItemSystem.UpdateShieldMax(rp)
end

-- Rolls an item id from a Config.Chests.Weights table with the player's luck.
function ItemSystem.Roll(weights: { [string]: number }, luck: number): string
	local rarity = ItemData.RollRarity(weights, luck, rng:NextNumber())
	local pool = ItemData.ByRarity[rarity]
	if not pool or #pool == 0 then
		pool = ItemData.Order
	end
	return pool[rng:NextInteger(1, #pool)]
end

--[[
	Gives one copy of `id` to the player: stats, the client's strip and an item popup.
	source = what it came from ("Small chest", "Shrine of Chance", ...), shown in the popup.
]]
-- Ordinary rewards stay compact; legendary finds and encounter finales get a showcase.
-- The second return value tells the caller whether to protect/pause for the showcase.
function ItemSystem.Grant(rp, id: string, source: string?, reward: boolean?, dramatic: boolean?): (boolean, boolean)
	local def = ItemData.Items[id]
	if not def or not rp.Items then
		return false, false
	end
	-- capped items (Phoenix Feather, MaxStacks 2): a copy past the cap re-rolls into another
	-- item of the same rarity that isn't capped out
	if def.MaxStacks and count(rp, id) >= def.MaxStacks then
		local options = {}
		for _, other in ipairs(ItemData.ByRarity[def.Rarity] or {}) do
			local o = ItemData.Items[other]
			if other ~= id and not (o.MaxStacks and count(rp, other) >= o.MaxStacks) then
				table.insert(options, other)
			end
		end
		if #options == 0 then
			return false, false
		end
		id = options[rng:NextInteger(1, #options)]
		def = ItemData.Items[id]
	end
	local n = count(rp, id) + 1
	rp.Items[id] = n
	if not table.find(rp.ItemOrder, id) then
		table.insert(rp.ItemOrder, id)
	end
	ItemSystem.Refresh(rp)
	ItemSystem.Send(rp)
	local showcase = reward == true and (dramatic == true or def.Rarity == "Legendary")
	local player: Player = rp.Player
	if player.Parent then
		Remotes.FireClient("ItemGained", player, { Id = id, Count = n, Source = source, Reward = reward == true, Dramatic = showcase })
	end
	if rp.Root then
		local color = def.Rarity == "Legendary" and Palette.gold_300 or (def.Rarity == "Uncommon" and Palette.slate_300 or Palette.ivory_200)
		Fx.Ring(rp.Root.Position, def.Rarity == "Legendary" and 14 or 8, color)
	end
	Fx.Sound("Item")
	return true, showcase
end

------------------------------------------------------------------------------------------
-- Damage hooks (EnemySpawner)
------------------------------------------------------------------------------------------

-- Critical hits: returns the (maybe multiplied) damage and whether it crit.
function ItemSystem.ModifyHit(rp, amount: number): (number, boolean)
	local stats = rp.Stats
	if stats and stats.CritChance > 0 and rng:NextNumber() < stats.CritChance then
		return amount * stats.CritDamage, true
	end
	return amount, false
end

-- Storm Charm: a hit may call lightning that jumps to more enemies near the target.
function ItemSystem.OnHit(rp, e, amount: number)
	local n = count(rp, "StormCharm")
	if n <= 0 then
		return
	end
	local I = Config.Items
	local s = state(rp)
	local now = os.clock()
	if now < s.LightningAt or rng:NextNumber() >= ItemData.Hyperbolic(ItemData.Items.StormCharm.K or 0.1, n) then
		return
	end
	s.LightningAt = now + I.LightningCooldown
	local grid = ctx.EnemySpawner.Grid
	local hit = { [e] = true }
	local from: Vector3 = e.Pos
	local damage = math.max(1, amount * I.LightningDamage)
	Fx.Bolt(from, 3, 1)
	for _ = 1, math.min(I.LightningMaxTargets, I.LightningTargets + n) do
		local nextE = grid:Nearest(from.X, from.Z, I.LightningRange, function(o)
			return hit[o] == true or not o.Alive
		end)
		if not nextE then
			break
		end
		hit[nextE] = true
		local to: Vector3 = nextE.Pos
		Fx.Chain(from, to)
		ctx.EnemySpawner.Damage(nextE, damage, rp, nil, 0, true)
		from = to
	end
	Fx.Sound("Lightning")
end

-- Kill procs. maxHP = the dead enemy's max HP; isProc = killed by another proc.
function ItemSystem.OnKill(rp, pos: Vector3, maxHP: number, isProc: boolean?)
	if not rp.Alive or rp.HP <= 0 or not rp.Items then
		return
	end
	local I = Config.Items
	-- Healing Herb
	local herb = count(rp, "HealingHerb")
	if herb > 0 and rng:NextNumber() < ItemData.Hyperbolic(ItemData.Items.HealingHerb.K or 0.05, herb) then
		ctx.RunManager.Heal(rp, I.HealOnKillAmount, true)
	end
	-- Volatile Spore (proc kills don't chain)
	local spore = count(rp, "VolatileSpore")
	if spore > 0 and not isProc then
		local s = state(rp)
		local now = os.clock()
		if now >= s.ExplodeAt and rng:NextNumber() < I.ExplodeChance then
			s.ExplodeAt = now + I.ExplodeCooldown
			local damage = maxHP * (I.ExplodeShare + I.ExplodeSharePerStack * (spore - 1))
			local r = I.ExplodeRadius
			local k = ctx.EnemySpawner.Grid:QueryCircle(pos.X, pos.Z, r, queryBuf)
			local victims = table.move(queryBuf, 1, k, 1, {})
			for _, o in ipairs(victims) do
				if o.Alive then
					-- bosses take at most ExplodeBossMaxShare of their max HP per burst
					local d = o.Boss and math.min(damage, (o.MaxHP or 0) * I.ExplodeBossMaxShare) or damage
					ctx.EnemySpawner.Damage(o, d, rp, nil, 0, true)
				end
			end
			Fx.Explosion(pos, r)
		end
	end
end

------------------------------------------------------------------------------------------
-- Player damage hooks (RunManager.DamagePlayer)
------------------------------------------------------------------------------------------

function ItemSystem.UpdateShieldMax(rp)
	local n = count(rp, "GuardianWard")
	local I = Config.Items
	local maxShield = 0
	if n > 0 and rp.Stats then
		maxShield = math.floor(rp.Stats.MaxHP * math.min(I.ShieldMax, I.ShieldPerStack * n) + 0.5)
	end
	rp.ShieldMax = maxShield
	local s = state(rp)
	s.Shield = math.min(s.Shield, maxShield)
	local player: Player = rp.Player
	player:SetAttribute("ShieldMax", maxShield)
	player:SetAttribute("Shield", math.ceil(s.Shield))
	s.ShownShield = math.ceil(s.Shield)
end

-- Guardian Ward: the shield takes what it can of a hit. Returns the damage left for HP.
function ItemSystem.AbsorbHit(rp, dmg: number): number
	local s = state(rp)
	s.LastHurt = os.clock()
	if s.Shield <= 0 then
		return dmg
	end
	local absorbed = math.min(s.Shield, dmg)
	s.Shield -= absorbed
	return dmg - absorbed
end

-- Barbed Mail: hit back around the player. raw = the enemy's hit before armor, taken =
-- the damage that got through armor / Iron Plate; thorns scale on max(raw x
-- ThornsRawShare, taken): what you really took, but never less than half the raw hit.
function ItemSystem.OnHurt(rp, raw: number, taken: number?)
	local n = count(rp, "BarbedMail")
	if n <= 0 or not rp.Root then
		return
	end
	local I = Config.Items
	local s = state(rp)
	local now = os.clock()
	if now < s.ThornsAt then
		return
	end
	s.ThornsAt = now + I.ThornsCooldown
	local base = math.max(raw * I.ThornsRawShare, taken or raw)
	local damage = base * (I.ThornsMult + I.ThornsPerStack * (n - 1)) * (rp.Stats and rp.Stats.Might or 1)
	local pos = rp.Root.Position
	local k = ctx.EnemySpawner.Grid:QueryCircle(pos.X, pos.Z, I.ThornsRadius, queryBuf)
	local victims = table.move(queryBuf, 1, k, 1, {})
	for _, o in ipairs(victims) do
		if o.Alive then
			ctx.EnemySpawner.Damage(o, damage, rp, nil, 0, true)
		end
	end
	Fx.Ring(pos, I.ThornsRadius, Palette.crimson_400)
end

-- Phoenix Feather: uses one up to stand back up. True when it did.
function ItemSystem.TryRevive(rp): boolean
	local n = count(rp, "PhoenixFeather")
	if n <= 0 then
		return false
	end
	rp.Items.PhoenixFeather = n - 1
	if n - 1 <= 0 then
		rp.Items.PhoenixFeather = nil
		local i = table.find(rp.ItemOrder, "PhoenixFeather")
		if i then
			table.remove(rp.ItemOrder, i)
		end
	end
	ItemSystem.Send(rp)
	if rp.Root then
		Fx.Ring(rp.Root.Position, 18, Palette.gold_300)
	end
	return true
end

-- Spare Quiver: 1 when this weapon attack gets an extra projectile, else 0. The attack
-- counter is kept per weapon (a fast weapon can't steal the bonus from a slow one), and
-- weapons that ignore the amount stat (Garlic Aura) never count or get it.
function ItemSystem.ExtraShot(rp, w): number
	local n = count(rp, "SpareQuiver")
	if n <= 0 or not w or not WeaponData.UsesStat(w.Id, "amount", w.Evolved) then
		return 0
	end
	local s = state(rp)
	local shots = (s.Shots[w.Id] or 0) + 1
	local every = math.max(Config.Items.QuiverMin, Config.Items.QuiverEvery - n)
	if shots >= every then
		s.Shots[w.Id] = 0
		return 1
	end
	s.Shots[w.Id] = shots
	return 0
end

------------------------------------------------------------------------------------------
-- Per frame: regeneration, shield refill, magnet pulses
------------------------------------------------------------------------------------------

local function stepPlayer(rp, dt: number, now: number)
	local stats = rp.Stats
	if not stats or not rp.Alive or rp.Paused then
		return
	end
	local I = Config.Items
	local s = state(rp)
	-- regeneration in small ticks (one HP attribute write per tick, not per frame)
	if stats.Regen > 0 then
		s.RegenTimer += dt
		s.Regen += stats.Regen * dt
		if s.RegenTimer >= I.RegenTick then
			s.RegenTimer = 0
			if rp.HP < stats.MaxHP then
				ctx.RunManager.Heal(rp, s.Regen, true)
			end
			s.Regen = 0
		end
	end
	-- Guardian Ward
	local maxShield = rp.ShieldMax or 0
	if maxShield > 0 and s.Shield < maxShield and now - s.LastHurt >= I.ShieldDelay then
		s.Shield = math.min(maxShield, s.Shield + maxShield / I.ShieldRefillSeconds * dt)
	end
	local shown = math.ceil(s.Shield)
	if shown ~= s.ShownShield then
		s.ShownShield = shown
		rp.Player:SetAttribute("Shield", shown)
	end
	-- Magnet Totem
	local magnets = count(rp, "MagnetTotem")
	if magnets > 0 and rp.Root then
		s.MagnetTimer += dt
		local interval = math.max(I.MagnetIntervalMin, I.MagnetInterval - I.MagnetIntervalPerStack * magnets)
		if s.MagnetTimer >= interval then
			s.MagnetTimer = 0
			local radius = I.MagnetRadius + I.MagnetRadiusPerStack * magnets
			ctx.XPSystem.MagnetRadius(rp, rp.Root.Position, radius)
			Fx.Ring(rp.Root.Position, radius, Palette.slate_300)
		end
	end
end

function ItemSystem.Step(dt: number)
	if not ctx.RunManager.IsSimulating() then
		return
	end
	local now = os.clock()
	for _, rp in ipairs(ctx.RunManager.GetRunPlayers()) do
		if rp.Items and next(rp.Items) ~= nil then
			stepPlayer(rp, dt, now)
		end
	end
end

-- Dev tool: `n` random items.
function ItemSystem.DevGive(rp, n: number)
	for _ = 1, n do
		ItemSystem.Grant(rp, ItemData.Order[rng:NextInteger(1, #ItemData.Order)], "Dev")
	end
end

function ItemSystem.Init(c)
	ctx = c
end

function ItemSystem.Start() end

return ItemSystem
