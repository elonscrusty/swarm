--[[
	MiniBoss.lua (feature 3, Config.Features.MiniBosses; docs/features/CHALLENGES.md)
	A placed encounter from stage Config.MiniBoss.MinStage: a big free chest that stays
	locked behind a champion. The champion is a buffed existing elite (Config.MiniBoss.Types)
	with a name plate and its own ring (client ChallengesUI), woken when a player walks
	within WakeRadius of the chest.

	  Locked chest   LootSystem feature chest (state "Locked": the prompt says why, no hold)
	  Guard killed   by a player: the chest unlocks (state "Ready"); opening it is the normal
	                 chest pipeline (gold-free, ChestWeights, exactly once: LootSystem.openChest)
	  Guard removed  without a killer (portal sweep, a boss clearing the field, recycling):
	                 nothing drops, the chest stays locked and the guard returns after
	                 RetrySeconds while the stage is still exploring (WORLD audit W-04)

	Replicated: SwarmState MiniBossId (the guard's pool id, 0 = none) and MiniBossName; the
	guard's body carries "MiniBoss" (its name) and "HPFrac" (the existing small HP bar).
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Config = require(ReplicatedStorage.Shared.Config)
local Remotes = require(ReplicatedStorage.Shared.Remotes)
local EnemyData = require(ReplicatedStorage.Shared.EnemyData)
local Palette = require(ReplicatedStorage.Shared.Palette)
local ModelBuilder = require(script.Parent.ModelBuilder)
local EncounterDirector = require(script.Parent.EncounterDirector)
local Fx = require(script.Parent.Fx)

local MiniBoss = {}

local P = Palette :: { [string]: Color3 }
local NAME = "MiniBoss"
local LOCK_COLOR = Color3.fromRGB(170, 80, 230) -- the champion's violet (ring, lock, beam)
local OPEN_COLOR = P.gold_300
local FLAT = Vector3.new(1, 0, 1)

local ctx
local rng = Random.new()
local cur: any = nil -- { Chest, Guard, Uid, Name, Type, Phase ("Dormant" | "Awake" | "Open"), RetryAt, Lock {parts} }
local hpTimer = 0

local function C()
	return Config.MiniBoss
end

local function now(): number
	return ctx.RunManager.GetRunTime()
end

local function publish(e, name: string?)
	local state = Remotes.State()
	state:SetAttribute("MiniBossId", e and e.Id or 0)
	state:SetAttribute("MiniBossName", name or "")
end

local function clearBody(e)
	if e and e.Part then
		e.Part:SetAttribute("MiniBoss", nil)
		if not (e.Def and e.Def.ShowHP) then
			e.Part:SetAttribute("HPFrac", nil)
		end
	end
end

-- The lock pieces on the chest (violet while guarded, gold once unlocked).
local function paintLock(color: Color3, beamT: number?)
	if not cur then
		return
	end
	for _, p in ipairs(cur.Lock) do
		if p.Parent then
			p.Color = color
		end
	end
	local beam = cur.Chest.Model:FindFirstChild("Beam", true)
	if beam and beam:IsA("BasePart") then
		beam.Color = color
		if beamT then
			beam.Transparency = beamT
		end
	end
end

local function dress(obj)
	-- a free "big chest": no price coin (it is free), a violet seal ring and lock bar
	for _, d in ipairs(obj.Model:GetDescendants()) do
		if d:IsA("BasePart") and d.Name == "Coin" then
			local i = table.find(obj.Glow, d)
			if i then
				table.remove(obj.Glow, i)
			end
			d:Destroy()
		end
	end
	local lock = {}
	local pos = obj.Pos
	local seal = ModelBuilder.Part({
		Name = "SealRing",
		Shape = Enum.PartType.Cylinder,
		Size = Vector3.new(0.08, 11, 11),
		CFrame = CFrame.new(pos + Vector3.new(0, 0.07, 0)) * CFrame.Angles(0, 0, math.rad(90)),
		Color = LOCK_COLOR,
		Material = Enum.Material.Neon,
		Transparency = 0.6,
	})
	seal.Parent = obj.Model
	table.insert(lock, seal)
	local bar = ModelBuilder.Part({
		Name = "SealBar",
		Size = Vector3.new(4.2, 0.35, 0.35),
		CFrame = obj.CF * CFrame.new(0, 1.55, -1.35),
		Color = LOCK_COLOR,
		Material = Enum.Material.Neon,
	})
	bar.Parent = obj.Model
	table.insert(lock, bar)
	local orb = ModelBuilder.Part({
		Name = "Orb",
		Shape = Enum.PartType.Ball,
		Size = Vector3.new(1, 1, 1),
		CFrame = CFrame.new(pos + Vector3.new(0, 4.3, 0)),
		Color = LOCK_COLOR,
		Material = Enum.Material.Neon,
	})
	orb.Parent = obj.Model
	table.insert(lock, orb)
	table.insert(obj.Glow, orb) -- hidden when the chest is opened (LootSystem)
	local light = Instance.new("PointLight")
	light.Color = LOCK_COLOR
	light.Range = 16
	light.Brightness = 1.2
	light.Shadows = false
	light.Parent = orb
	return lock
end

local function chestText(phase: string)
	if not cur then
		return
	end
	local obj = cur.Chest
	local w = C().ChestWeights
	local total = (w.Common or 0) + (w.Uncommon or 0) + (w.Legendary or 0)
	local benefit = string.format("Free item (%d%% uncommon, %d%% legendary before luck)", math.floor((w.Uncommon or 0) / total * 100 + 0.5), math.floor((w.Legendary or 0) / total * 100 + 0.5))
	if phase == "Open" then
		ctx.LootSystem.SetObjState(obj, "Ready", { Benefit = benefit, Tradeoff = "", Detail = "Free · hold to open" })
	elseif phase == "Awake" then
		ctx.LootSystem.SetObjState(obj, "Locked", { Benefit = benefit, Tradeoff = "", Detail = "Locked · defeat " .. cur.Name })
	else
		ctx.LootSystem.SetObjState(obj, "Locked", { Benefit = benefit, Tradeoff = "A champion guards it", Detail = "Locked · a champion guards it" })
	end
end

local function pickType(): string?
	local options = {}
	for _, id in ipairs(C().Types) do
		local def = EnemyData.Enemies[id]
		if def and not def.Explode and not def.Static and not def.Object and not def.IsBoss then
			table.insert(options, id)
		end
	end
	if #options == 0 then
		return nil
	end
	return options[rng:NextInteger(1, #options)]
end

local function wake()
	local typeId = cur.Type
	local def = EnemyData.Enemies[typeId]
	local es = ctx.EnemySpawner
	local at: Vector3? = nil
	for k = 0, 7 do
		local a = cur.Angle + k * math.pi / 4
		local x, z = es.ClampToArena(cur.Chest.Pos.X + math.cos(a) * 7, cur.Chest.Pos.Z + math.sin(a) * 7, 4)
		if def.Ghost or not ctx.EnemyAI.IsBlocked(x, z, def.Radius * Config.Enemies.EliteSizeMult) then
			at = Vector3.new(x, Config.ArenaOrigin.Y, z)
			break
		end
	end
	local e = at and es.Spawn(typeId, at :: Vector3, { Elite = true, Force = true }) or nil
	if not e then
		cur.RetryAt = now() + 2 -- the pool is full: try again soon
		return
	end
	local M = C()
	e.MaxHP *= M.HPMult
	e.HP = e.MaxHP
	e.Damage *= M.DamageMult
	e.DmgScale = (e.DmgScale or 1) * M.DamageMult
	e.Speed *= M.SpeedMult
	if e.Shield and e.Shield > 0 then
		e.Shield *= M.HPMult -- the Shielded affix keeps its share of the bigger HP
	end
	e.Part:SetAttribute("MiniBoss", cur.Name)
	e.Part:SetAttribute("HPFrac", 1)
	e.HPShown = 1
	ctx.LootSystem.AddGuard(cur.Chest, e)
	cur.Guard, cur.Uid, cur.Phase = e, e.Uid, "Awake"
	publish(e, cur.Name)
	chestText("Awake")
	Fx.Ring(cur.Chest.Pos, 14, LOCK_COLOR)
	Fx.Sound("BossRoar")
	ctx.RunManager.Broadcast(cur.Name .. " guards a chest! Defeat it to open the chest.", Color3.fromRGB(205, 150, 255), nil, { Id = "miniboss.awake" })
end

-- LootSystem.OnGuardDown → here (killed = a player killed it).
local function onGuardDown(e, killed: boolean)
	if not cur or e ~= cur.Guard then
		return
	end
	clearBody(e)
	publish(nil)
	cur.Guard, cur.Uid = nil, nil
	if killed then
		cur.Phase = "Open"
		chestText("Open")
		paintLock(OPEN_COLOR, 0.74)
		for _, p in ipairs(cur.Lock) do
			if p.Name == "SealBar" then
				p.Transparency = 1
			end
		end
		Fx.Ring(cur.Chest.Pos, 12, OPEN_COLOR)
		ctx.RunManager.Broadcast(cur.Name .. " is down! Its chest is open.", Color3.fromRGB(255, 220, 120), nil, { Id = "miniboss.down" })
	else
		-- swept away, not beaten: no reward; it guards again later (W-04)
		cur.Phase = "Dormant"
		cur.RetryAt = now() + C().RetrySeconds
		chestText("Dormant")
	end
end

local function nearestDistance(pos: Vector3): number
	local best = math.huge
	for _, rp in ipairs(ctx.RunManager.GetRunPlayers()) do
		local root = rp.Root
		if rp.Alive and not rp.Returned and root then
			best = math.min(best, (((root :: BasePart).Position - pos) * FLAT).Magnitude)
		end
	end
	return best
end

------------------------------------------------------------------------------------------
-- EncounterDirector callbacks
------------------------------------------------------------------------------------------

local function cleanup(_reason: string?)
	if not cur then
		return
	end
	local e = cur.Guard
	if e and e.Alive and e.Uid == cur.Uid then
		e.Guard = nil -- the stage is going: no callback into a chest that is gone
	end
	clearBody(e)
	cur.Chest.OnGuardDown = nil
	cur = nil
	publish(nil)
end

local function onStageStart(info): boolean
	cleanup()
	if info.Stage < C().MinStage then
		return false
	end
	local typeId = pickType()
	local pos = typeId and EncounterDirector.FindSpot(NAME)
	if not pos then
		return false
	end
	local obj = ctx.LootSystem.AddFeatureChest(info.Arena, "Large", pos, false)
	obj.Price = 0
	obj.Model:SetAttribute("Price", 0)
	obj.Model:SetAttribute("Title", "Champion's Chest")
	obj.Model:SetAttribute("MiniBossChest", true)
	obj.Weights = C().ChestWeights
	obj.Title = "Champion's chest"
	obj.OnGuardDown = onGuardDown
	cur = {
		Chest = obj,
		Type = typeId,
		Name = (C().Names :: any)[typeId] or ("Champion " .. tostring(EnemyData.Enemies[typeId :: string].DisplayName)),
		Phase = "Dormant",
		RetryAt = 0,
		Angle = rng:NextNumber(0, math.pi * 2),
		Lock = {},
	}
	cur.Lock = dress(obj)
	chestText("Dormant")
	return true
end

local function onTick(dt: number, info)
	if not cur then
		return
	end
	if cur.Phase == "Dormant" then
		if info.Phase == "Explore" and now() >= cur.RetryAt and nearestDistance(cur.Chest.Pos) <= C().WakeRadius then
			wake()
		end
	elseif cur.Phase == "Awake" then
		local e = cur.Guard
		if not e or not e.Alive or e.Uid ~= cur.Uid then
			-- gone without the LootSystem callback (a bulk despawn): treat as swept away
			if e then
				cur.Chest.Guards[e] = nil
				if e.Guard == cur.Chest.Id then
					e.Guard = nil
				end
				onGuardDown(e, false)
			end
			return
		end
		hpTimer += dt
		if hpTimer >= 0.1 then
			hpTimer = 0
			local frac = math.clamp(math.ceil(e.HP / math.max(1, e.MaxHP) * 50) / 50, 0, 1)
			if frac ~= e.HPShown then
				e.HPShown = frac
				e.Part:SetAttribute("HPFrac", frac)
			end
		end
	end
end

-- Tests / tools: the live encounter (nil when none).
function MiniBoss.Get()
	return cur
end

function MiniBoss.Init(c)
	ctx = c
	EncounterDirector.Register(NAME, {
		Feature = "MiniBosses",
		Weight = Config.MiniBoss.Weight,
		Allow = function(info)
			return info.Stage >= Config.MiniBoss.MinStage
		end,
		OnStageStart = onStageStart,
		OnTick = onTick,
		OnCleanup = cleanup,
	})
end

return MiniBoss
