--[[
	LootSystem.lua
	Exploration loot on every stage (Risk of Rain / Megabonk style), placed when a stage is
	built (StageManager → BuildStage) and removed on travel and when the run ends (Clear):

	  Chests (Config.Chests)   10-14 small, 2-3 large, 1 golden. Pay run gold, get one item
	                           (ItemSystem.Roll with the chest's rarity weights).
	  Shrine of Chance         pay gold, 50% chance of an item; each try costs more; goes
	  (Config.Shrines)         dark after 2 items or 6 tries.
	  Bargain Shrine           free, once per stage: the whole team gets +25% damage and
	                           +30% gold for the rest of the stage, the swarm gets +20% HP.
	  Guarded Altar            a free rare chest. Dormant until a living player comes near,
	  (Config.Guarded)         then elite guards climb out around it; when they are dead the
	                           chest unlocks and opening it gives EVERY living teammate an item.
	  Lost Caravan             placed here (Config.Caravan, far from the spawn like the altar),
	  (CaravanEvent.lua)       run by CaravanEvent: hold its ring while waves come.
	Every shrine / the altar says what it gives ("Benefit") and what it costs ("Tradeoff")
	before it is used, and shows its state afterwards.

	World: models in workspace.SwarmLoot, one per object, with attributes the client reads
	(LootUI): LootId, LootKind (Chest | Shrine | Altar), LootType (Small | Large | Golden |
	Chance | Bargain | Guarded), Title, State, Price (this stage's price before the player's
	gold multiplier; 0 = free), Hold (seconds), Benefit, Tradeoff, Detail, Pos.
	States: chests Ready → Opened; Chance Ready → Spent; Bargain Ready → Active;
	altar Dormant → Guarded → Claimable → Claimed (back to Dormant if its guards are
	removed without being killed, e.g. the Queen's arrival clears the field).

	Opening: the client sends LootHold(id, true) while the player holds E / gamepad X / the
	on-screen button next to it, and LootHold(id, false) on release. The server checks
	everything (in the run, alive, not choosing a card, in range, state, gold) when the hold
	starts and every frame; the hold completes on the SERVER after Hold seconds (frozen runs
	pause it), and the gold is taken at that moment. Two players on one chest: the first to
	finish opens it, the other's hold is cancelled ("Someone was faster"). A player who
	leaves, falls or walks away just loses the hold. Answers: LootFeedback (Done / Cancel).

	Gold: GoldSystem.SpendRunGold (only gold earned this run). Prices: ItemData.StagePrice x
	ItemData.PlayerPrice (the player's gold multiplier, attribute GoldMult).
]]

local Config = require(game:GetService("ReplicatedStorage").Shared.Config)
local Remotes = require(game:GetService("ReplicatedStorage").Shared.Remotes)
local ItemData = require(game:GetService("ReplicatedStorage").Shared.ItemData)
local EnemyData = require(game:GetService("ReplicatedStorage").Shared.EnemyData)
local MeshCatalog = require(game:GetService("ReplicatedStorage").Shared.MeshCatalog)
local Palette = require(game:GetService("ReplicatedStorage").Shared.Palette)
local MapBuilder = require(script.Parent.MapBuilder)
local ModelBuilder = require(script.Parent.ModelBuilder)
local Fx = require(script.Parent.Fx)
local Events = require(script.Parent.Events)

local LootSystem = {}

local P = Palette :: { [string]: Color3 }
local part = ModelBuilder.Part
local NEON = Enum.Material.Neon
local METAL = Enum.Material.Metal
local UPRIGHT = CFrame.Angles(0, 0, math.rad(90))
local FACE_CAMERA = CFrame.Angles(0, math.pi, 0) -- model front (-Z) toward the run camera
local FLAT = Vector3.new(1, 0, 1)

type Obj = {
	Id: number,
	Type: string,
	Kind: string,
	Pos: Vector3,
	CF: CFrame,
	Model: Model,
	Chest: Model?, -- the chest model (the altar's chest sits on the altar)
	State: string,
	Price: number,
	Tries: number,
	Found: number,
	Guards: { [any]: number }, -- guard enemy record → its Uid
	GuardTotal: number,
	Killed: number,
	Despawned: number,
	WakeAt: number,
	Glow: { BasePart },
	Light: PointLight?,
	Ring: BasePart?,
}

local ctx
local rng = Random.new()
local folder: Folder
local objects: { [number]: Obj } = {}
local list: { Obj } = {}
local nextId = 0
local holds: { [any]: { Obj: Obj, Elapsed: number } } = {}
local stageNo = 1
local teamBonus = { might = 0, goldGain = 0 } -- the Bargain Shrine (this stage)
local enemyHPMult = 1

local TITLES = {
	Small = "Small Chest",
	Large = "Large Chest",
	Golden = "Golden Chest",
	Chance = "Shrine of Chance",
	Bargain = "Bargain Shrine",
	Guarded = "Guarded Altar",
}

------------------------------------------------------------------------------------------
-- Queries (stats, enemies)
------------------------------------------------------------------------------------------

-- This stage's team boon (LevelUpSystem.RecomputeStats adds it to every player).
function LootSystem.TeamBonus(): { [string]: number }
	return teamBonus
end

-- Enemy HP multiplier of this stage (EnemySpawner.Spawn).
function LootSystem.EnemyHPMult(): number
	return enemyHPMult
end

function LootSystem.Objects(): { Obj }
	return list
end

local function goldMult(player: Player): number
	return ctx.MonetizationService.GoldMultiplier(player)
end

local function priceFor(rp, obj: Obj): number
	if obj.Price <= 0 then
		return 0
	end
	return ItemData.PlayerPrice(obj.Price, goldMult(rp.Player))
end

------------------------------------------------------------------------------------------
-- Models
------------------------------------------------------------------------------------------

local function add(m: Model, cf: CFrame, name: string, size: Vector3, at: Vector3, color: Color3, material: Enum.Material?, shape: Enum.PartType?, rot: CFrame?): BasePart
	local p = part({
		Name = name,
		Shape = shape,
		Size = size,
		CFrame = cf * CFrame.new(at) * (rot or CFrame.identity),
		Color = color,
		Material = material,
		CastShadow = name == "Box" or name == "Dais",
	})
	p.Parent = m
	return p
end

-- Part-built chests in the same pieces as blender/models/loot.py: Box, Lid (+ LidTrim),
-- Straps, Fittings. The Lid carries a "Hinge" attribute (back top edge, relative to the
-- Lid's centre in model space) so both looks open the same way.
local CHEST_LOOK = {
	Small = { W = 2.6, H = 1.2, D = 1.8, LidH = 0.6, Wood = P.wood_500, Lid = P.wood_400, Iron = P.steel_700, Trim = P.gold_500 },
	Large = { W = 3.6, H = 1.6, D = 2.4, LidH = 0.8, Wood = P.wood_600, Lid = P.wood_500, Iron = P.steel_600, Trim = P.gold_400 },
	Golden = { W = 3.0, H = 1.4, D = 2.1, LidH = 0.7, Wood = P.gold_600, Lid = P.gold_500, Iron = P.gold_700, Trim = P.ivory_100 },
}

local function chestFallback(kind: string)
	return function(m: Model, cf: CFrame, s: number, _pal, _sh)
		local L = CHEST_LOOK[kind] or CHEST_LOOK.Small
		local w, h, d, lh = L.W * s, L.H * s, L.D * s, L.LidH * s
		add(m, cf, "Box", Vector3.new(w, h, d), Vector3.new(0, h / 2, 0), L.Wood)
		add(m, cf, "Fittings", Vector3.new(w + 0.1, 0.18 * s, d + 0.1), Vector3.new(0, 0.09 * s, 0), L.Trim, kind == "Golden" and METAL or nil)
		local lid = add(m, cf, "Lid", Vector3.new(w + 0.06, lh, d + 0.06), Vector3.new(0, h + lh / 2, 0), L.Lid)
		lid:SetAttribute("Hinge", Vector3.new(0, -lh / 2, (d + 0.06) / 2))
		local trim = add(m, cf, "LidTrim", Vector3.new(w * 0.7, lh * 0.35, d * 0.7), Vector3.new(0, h + lh + lh * 0.17, 0), L.Lid:Lerp(L.Trim, 0.25))
		local _ = trim
		for _, x in ipairs({ -w * 0.3, w * 0.3 }) do
			add(m, cf, "Straps", Vector3.new(0.22 * s, h + 0.02, d + 0.04), Vector3.new(x, h / 2, 0), L.Iron, METAL)
		end
		add(m, cf, "Fittings", Vector3.new(0.42 * s, 0.5 * s, 0.12), Vector3.new(0, h - 0.1 * s, -d / 2 - 0.05), L.Trim, METAL)
		if kind == "Golden" then
			add(m, cf, "Gem", Vector3.new(0.3, 0.3, 0.3) * s, Vector3.new(0, h + lh + lh * 0.4, 0), P.crimson_400, NEON, nil, CFrame.Angles(0, math.rad(45), math.rad(45)))
		end
	end
end

-- Altar fallback (until the "Guard_Altar" mesh loads): a two-step stone dais with four
-- short standing stones and a gold inlay. Its top is at y = 0.9 (the mesh's Top too).
local ALTAR_TOP = 0.9
local function altarFallback(m: Model, cf: CFrame, s: number, _pal, _sh)
	add(m, cf, "Dais", Vector3.new(0.45 * s, 9 * s, 9 * s), Vector3.new(0, 0.225 * s, 0), P.stone_600, nil, Enum.PartType.Cylinder, UPRIGHT)
	add(m, cf, "Dais", Vector3.new(0.45 * s, 6.6 * s, 6.6 * s), Vector3.new(0, 0.675 * s, 0), P.stone_500, nil, Enum.PartType.Cylinder, UPRIGHT)
	add(m, cf, "Inlay", Vector3.new(0.04, 5.6 * s, 5.6 * s), Vector3.new(0, 0.91 * s, 0), P.gold_600, nil, Enum.PartType.Cylinder, UPRIGHT)
	add(m, cf, "Top", Vector3.new(0.05, 5.2 * s, 5.2 * s), Vector3.new(0, 0.92 * s, 0), P.stone_400, nil, Enum.PartType.Cylinder, UPRIGHT)
	for k = 0, 3 do
		local a = math.rad(45 + k * 90)
		local x, z = math.cos(a) * 3.9 * s, math.sin(a) * 3.9 * s
		add(m, cf, "Stone", Vector3.new(0.9, 2.6, 0.9) * s, Vector3.new(x, 1.75 * s, z), P.stone_400, nil, nil, CFrame.Angles(0, -a, 0))
		add(m, cf, "Cap", Vector3.new(1.1, 0.3, 1.1) * s, Vector3.new(x, 3.15 * s, z), P.stone_600, nil, nil, CFrame.Angles(0, -a, 0))
	end
end

local function kitTop(name: string, default: number): number
	local entry = (MeshCatalog.Models :: any)[name]
	local top = entry and entry.Top
	if type(top) == "number" then
		return top
	end
	return default
end

-- The lid hinge of a chest model, in world space (nil when it has no lid).
local function hingeOf(chest: Model, cf: CFrame, kitName: string): (BasePart?, Vector3?)
	local lid = chest:FindFirstChild("Lid") :: BasePart?
	if not lid then
		return nil, nil
	end
	local rel: Vector3? = lid:GetAttribute("Hinge")
	if typeof(rel) ~= "Vector3" then
		local entry = (MeshCatalog.Models :: any)[kitName]
		for _, piece in ipairs(entry and entry.Pieces or {}) do
			if piece.Name == "Lid" and piece.Pivot then
				rel = Vector3.new(piece.Pivot[1], piece.Pivot[2], piece.Pivot[3])
			end
		end
	end
	if typeof(rel) ~= "Vector3" then
		rel = Vector3.new(0, -lid.Size.Y / 2, lid.Size.Z / 2)
	end
	return lid, lid.Position + cf.Rotation * (rel :: Vector3)
end

-- Swings every "Lid*" piece of a chest open around the back hinge.
local function openLid(chest: Model?, cf: CFrame, kitName: string)
	if not chest then
		return
	end
	local _, hinge = hingeOf(chest, cf, kitName)
	if not hinge then
		return
	end
	local rot = cf.Rotation
	local swing = CFrame.new(hinge) * rot * CFrame.Angles(math.rad(105), 0, 0) * rot:Inverse() * CFrame.new(-hinge)
	for _, d in ipairs(chest:GetDescendants()) do
		if d:IsA("BasePart") and string.sub(d.Name, 1, 3) == "Lid" then
			d.CFrame = swing * d.CFrame
		end
	end
end

local function setAttrs(obj: Obj, attrs: { [string]: any })
	for k, v in pairs(attrs) do
		obj.Model:SetAttribute(k, v)
	end
end

local function setState(obj: Obj, newState: string)
	obj.State = newState
	obj.Model:SetAttribute("State", newState)
end

-- Neon glow pieces + an optional light and a faint ring showing where to stand.
local function addGlow(obj: Obj, at: Vector3, color: Color3, light: boolean, ring: boolean)
	local orb = part({ Name = "Orb", Shape = Enum.PartType.Ball, Size = Vector3.new(0.9, 0.9, 0.9), CFrame = CFrame.new(at), Color = color, Material = NEON })
	orb.Parent = obj.Model
	table.insert(obj.Glow, orb)
	if light then
		local l = Instance.new("PointLight")
		l.Color = color
		l.Range = 14
		l.Brightness = 1.1
		l.Shadows = false
		l.Parent = orb
		obj.Light = l
	end
	if ring then
		local r = Config.Chests.InteractRadius
		local disc = part({ Name = "Ring", Shape = Enum.PartType.Cylinder, Size = Vector3.new(0.06, r * 2, r * 2), CFrame = CFrame.new(obj.Pos + Vector3.new(0, 0.05, 0)) * UPRIGHT, Color = color, Transparency = 0.8 })
		disc.Parent = obj.Model
		obj.Ring = disc
	end
end

local function recolourGlow(obj: Obj, color: Color3?, transparency: number?)
	for _, g in ipairs(obj.Glow) do
		if color then
			g.Color = color
		end
		g.Transparency = transparency or 0
	end
	if obj.Light then
		obj.Light.Enabled = color ~= nil and (transparency or 0) < 1
		if color then
			obj.Light.Color = color
		end
	end
	if obj.Ring then
		if color then
			obj.Ring.Color = color
		end
		obj.Ring.Transparency = (transparency or 0) >= 1 and 1 or 0.8
	end
end

local function newObj(kind: string, typeName: string, pos: Vector3, cf: CFrame): Obj
	nextId += 1
	local model = Instance.new("Model")
	model.Name = typeName .. "_" .. nextId
	local obj: Obj = {
		Id = nextId,
		Type = typeName,
		Kind = kind,
		Pos = pos,
		CF = cf,
		Model = model,
		Chest = nil,
		State = "Ready",
		Price = 0,
		Tries = 0,
		Found = 0,
		Guards = {},
		GuardTotal = 0,
		Killed = 0,
		Despawned = 0,
		WakeAt = 0,
		Glow = {},
		Light = nil,
		Ring = nil,
	}
	objects[nextId] = obj
	table.insert(list, obj)
	setAttrs(obj, {
		LootId = nextId,
		LootKind = kind,
		LootType = typeName,
		Title = TITLES[typeName] or typeName,
		Pos = pos,
		Price = 0,
		Benefit = "",
		Tradeoff = "",
		Detail = "",
	})
	return obj
end

local function chestBenefit(typeName: string): string
	if typeName == "Small" then
		return "1 item (80% common, 19% uncommon, 1% legendary)"
	elseif typeName == "Large" then
		return "1 item: uncommon, or legendary (20%)"
	end
	return "1 legendary item"
end

local function buildChest(typeName: string, pos: Vector3, yawJitter: number)
	local cf = CFrame.new(pos) * FACE_CAMERA * CFrame.Angles(0, yawJitter, 0)
	local obj = newObj("Chest", typeName, pos, cf)
	obj.Price = ItemData.StagePrice(Config.Chests.Cost[typeName] or 25, stageNo, Config.Chests.CostExponent)
	local kit = "Chest_" .. typeName
	obj.Chest = MapBuilder.PlaceProp(obj.Model, kit, cf, 1, nil, { fallback = chestFallback(typeName) })
	if typeName == "Golden" then
		addGlow(obj, pos + Vector3.new(0, 3.4, 0), P.gold_300, true, false)
	end
	setAttrs(obj, {
		Price = obj.Price,
		Hold = Config.Chests.HoldSeconds[typeName] or 1,
		Benefit = chestBenefit(typeName),
		Tradeoff = "",
		Detail = "Pay run gold · hold to open",
		State = "Ready",
	})
	obj.Model.Parent = folder
end

local SHRINE_LOOK = {
	Chance = { Sigil = P.gold_300, Stone = P.stone_500, Base = P.stone_600 },
	Bargain = { Sigil = P.crimson_400, Stone = P.stone_700, Base = P.stone_800 },
}

local function chanceText(obj: Obj)
	local S = Config.Shrines
	local left = S.ChanceMaxItems - obj.Found
	setAttrs(obj, {
		Benefit = string.format("%d%% chance of an item (%d left)", math.floor(S.ChanceSuccess * 100 + 0.5), left),
		Tradeoff = string.format("Each try costs %d%% more gold", math.floor((S.ChanceCostGrowth - 1) * 100 + 0.5)),
		Detail = string.format("Tries left: %d", math.max(0, S.ChanceMaxTries - obj.Tries)),
	})
end

local function buildShrine(arena, typeName: string, pos: Vector3)
	local cf = CFrame.new(pos) * FACE_CAMERA
	local obj = newObj("Shrine", typeName, pos, cf)
	local look = SHRINE_LOOK[typeName] or SHRINE_LOOK.Chance
	local kit = "Shrine"
	if typeName == "Bargain" and MapBuilder.HasKit("Shrine_Bargain") then
		kit = "Shrine_Bargain"
	end
	local palette = kit == "Shrine" and { Gold = look.Sigil, Stone = look.Stone, Base = look.Base } or nil
	-- until the Bargain mesh is uploaded / loaded it is the Shrine fallback in crimson
	local shrineFallback = MapBuilder.FallbackFor("Shrine")
	local fallback = shrineFallback
		and function(fm: Model, fcf: CFrame, fs: number, _pal, sh: boolean)
			(shrineFallback :: any)(fm, fcf, fs, { Gold = look.Sigil, Stone = look.Stone, Base = look.Base }, sh)
		end
	local m = MapBuilder.PlaceProp(obj.Model, kit, cf, 1, palette, { fallback = fallback })
	for _, d in ipairs(m:GetDescendants()) do
		if d:IsA("BasePart") and (d.Name == "Sigil" or d.Name == "Glow" or d.Name == "Rune" or d.Name == "Runes") then
			d.Material = NEON
			d.Color = look.Sigil
			table.insert(obj.Glow, d)
		end
	end
	MapBuilder.AddCollider(arena, kit, cf, 1)
	addGlow(obj, pos + Vector3.new(0, kitTop(kit, 5.0) + 1.1, 0), look.Sigil, false, true)
	setAttrs(obj, { Hold = Config.Shrines.HoldSeconds, State = "Ready" })
	if typeName == "Chance" then
		obj.Price = ItemData.StagePrice(Config.Shrines.ChanceCost, stageNo, Config.Chests.CostExponent)
		obj.Model:SetAttribute("Price", obj.Price)
		chanceText(obj)
	else
		local S = Config.Shrines
		setAttrs(obj, {
			Benefit = string.format("Team: +%d%% damage, +%d%% gold this stage", math.floor(S.BargainDamage * 100 + 0.5), math.floor(S.BargainGold * 100 + 0.5)),
			Tradeoff = string.format("Enemies: +%d%% HP this stage", math.floor(S.BargainEnemyHP * 100 + 0.5)),
			Detail = "Free · once per stage",
		})
	end
	obj.Model.Parent = folder
end

local function guardCount(): number
	local G = Config.Guarded
	local players = 0
	for _, rp in ipairs(ctx.RunManager.GetRunPlayers()) do
		if rp.Alive or rp.AwaitingRevive then
			players += 1
		end
	end
	return math.min(G.MaxGuards, G.Guards + G.GuardsPerStage * stageNo + G.GuardsPerExtraPlayer * math.max(0, players - 1))
end

local function altarText(obj: Obj)
	local st = obj.State
	if st == "Dormant" then
		local n = obj.GuardTotal > 0 and (obj.GuardTotal - obj.Killed) or guardCount()
		setAttrs(obj, {
			Benefit = "Free rare item for every teammate",
			Tradeoff = string.format("Wakes %d elite guards when you come near", n),
			Detail = "Dormant",
		})
	elseif st == "Guarded" then
		local left = 0
		for _ in pairs(obj.Guards) do
			left += 1
		end
		setAttrs(obj, { Detail = string.format("Guards left: %d / %d", left, obj.GuardTotal) })
	elseif st == "Claimable" then
		setAttrs(obj, { Benefit = "Free: one item for every teammate", Tradeoff = "", Detail = "Unguarded: open it!" })
	elseif st == "Claimed" then
		setAttrs(obj, { Detail = "Claimed" })
	end
end

local function buildAltar(arena, pos: Vector3)
	local cf = CFrame.new(pos) * FACE_CAMERA
	local obj = newObj("Altar", "Guarded", pos, cf)
	local kit = "Guard_Altar"
	MapBuilder.PlaceProp(obj.Model, kit, cf, 1, nil, { fallback = altarFallback })
	if MapBuilder.HasKit(kit) then
		MapBuilder.AddCollider(arena, kit, cf, 1)
	end
	local top = kitTop(kit, ALTAR_TOP)
	local chestCF = CFrame.new(pos + Vector3.new(0, top, 0)) * FACE_CAMERA
	obj.Chest = MapBuilder.PlaceProp(obj.Model, "Chest_Large", chestCF, 0.9, nil, { fallback = chestFallback("Large") })
	addGlow(obj, pos + Vector3.new(0, top + 4.2, 0), P.slate_300, true, true)
	setState(obj, "Dormant")
	obj.Model:SetAttribute("Hold", Config.Chests.HoldSeconds.Guarded)
	altarText(obj)
	MapBuilder.ClearDecor(arena, pos, 6)
	obj.Model.Parent = folder
end

------------------------------------------------------------------------------------------
-- Stage lifecycle
------------------------------------------------------------------------------------------

local function refreshTeam()
	for _, rp in ipairs(ctx.RunManager.GetRunPlayers()) do
		if rp.Stats and not rp.Returned then
			ctx.ItemSystem.Refresh(rp)
		end
	end
end

-- Removes every loot object and ends the stage's bargain (travel, run end).
function LootSystem.Clear()
	for _, obj in ipairs(list) do
		obj.Model:Destroy()
		for e in pairs(obj.Guards) do
			if e.Guard == obj.Id then
				e.Guard = nil
			end
		end
	end
	table.clear(objects)
	table.clear(list)
	table.clear(holds)
	if ctx.CaravanEvent then
		ctx.CaravanEvent.Clear()
	end
	local hadBargain = teamBonus.might ~= 0 or teamBonus.goldGain ~= 0 or enemyHPMult ~= 1
	teamBonus.might = 0
	teamBonus.goldGain = 0
	enemyHPMult = 1
	if hadBargain then
		refreshTeam()
	end
end

--[[
	Places this stage's loot on `arena` (call before EnemyAI.SetArena: shrines and the
	altar add colliders). portalPos is kept clear.
]]
function LootSystem.BuildStage(arena, stage: number, portalPos: Vector3?)
	LootSystem.Clear()
	stageNo = math.max(1, stage)
	local C = Config.Chests
	local avoid: { Vector3 } = {}
	if portalPos then
		table.insert(avoid, portalPos)
	end
	local base = {
		MinDistance = Config.Arenas.ClearRadius + C.SpawnExtra,
		EdgeMargin = C.EdgeMargin,
		Clearance = C.Clearance,
		Spacing = C.Spacing,
		Avoid = avoid,
		KeepFrom = portalPos, -- PortalClearance holds even when Spacing relaxes
		KeepRadius = C.PortalClearance,
	}
	local function spot(over: { [string]: any }?): Vector3?
		local opts = table.clone(base)
		for k, v in pairs(over or {}) do
			(opts :: any)[k] = v
		end
		local at = MapBuilder.FindOpenSpot(arena, rng, opts)
		if at then
			table.insert(avoid, at)
		end
		return at
	end
	-- the guarded altar: far from the spawn
	local altarAt = spot({ MinDistance = Config.Guarded.MinDistance, Clearance = 7 })
	if altarAt then
		buildAltar(arena, altarAt)
	end
	-- the Lost Caravan (at most one): also far out, away from the altar
	if ctx.CaravanEvent and ctx.CaravanEvent.Roll() then
		local K = Config.Caravan
		local caravanAt = spot({ MinDistance = K.MinDistance, Clearance = K.Clearance, Spacing = math.max(C.Spacing, K.ZoneRadius * 2 + 10) })
		if caravanAt then
			ctx.CaravanEvent.Build(arena, caravanAt, stageNo)
		end
	end
	-- shrines
	local S = Config.Shrines
	local shrines = {}
	for _ = 1, rng:NextInteger(S.ChanceCount[1], S.ChanceCount[2]) do
		table.insert(shrines, "Chance")
	end
	for _ = 1, S.BargainCount do
		table.insert(shrines, "Bargain")
	end
	for _, t in ipairs(shrines) do
		local at = spot({ Clearance = 4.5 })
		if at then
			buildShrine(arena, t, at)
			MapBuilder.ClearDecor(arena, at, 3)
		end
	end
	-- chests
	local function chests(typeName: string, n: number)
		for _ = 1, n do
			local at = spot(nil)
			if at then
				buildChest(typeName, at, rng:NextNumber(-0.3, 0.3))
				MapBuilder.ClearDecor(arena, at, 2.2)
			end
		end
	end
	chests("Golden", C.GoldenCount)
	chests("Large", rng:NextInteger(C.LargeCount[1], C.LargeCount[2]))
	chests("Small", rng:NextInteger(C.SmallCount[1], C.SmallCount[2]))
end

------------------------------------------------------------------------------------------
-- Guarded altar
------------------------------------------------------------------------------------------

local function weightedPick(weights: { [string]: number }): string
	local total = 0
	for _, w in pairs(weights) do
		total += w
	end
	local roll = rng:NextNumber() * total
	local last = "Slime"
	for id, w in pairs(weights) do
		last = id
		roll -= w
		if roll <= 0 then
			return id
		end
	end
	return last
end

local function wake(obj: Obj)
	local G = Config.Guarded
	local want = obj.GuardTotal > 0 and math.max(1, obj.GuardTotal - obj.Killed) or guardCount()
	local row = EnemyData.GetSpawnRow(ctx.RunManager.GetRunTime())
	local made = 0
	local offset = rng:NextNumber(0, math.pi * 2)
	for i = 1, want do
		local typeId = weightedPick(row.Weights)
		local def = EnemyData.Enemies[typeId]
		for _ = 1, 4 do
			local a = offset + (i / want) * math.pi * 2 + rng:NextNumber(-0.3, 0.3)
			local r = rng:NextNumber(G.SpawnRadius[1], G.SpawnRadius[2])
			local x, z = ctx.EnemySpawner.ClampToArena(obj.Pos.X + math.cos(a) * r, obj.Pos.Z + math.sin(a) * r, 4)
			if def.Ghost or not ctx.EnemyAI.IsBlocked(x, z, def.Radius * Config.Enemies.EliteSizeMult) then
				local e = ctx.EnemySpawner.Spawn(typeId, Vector3.new(x, Config.ArenaOrigin.Y, z), { Elite = true })
				if e then
					e.Guard = obj.Id
					obj.Guards[e] = e.Uid
					made += 1
				end
				break
			end
		end
	end
	if made == 0 then
		obj.WakeAt = os.clock() + 2 -- the field is full: try again soon
		return
	end
	if obj.GuardTotal == 0 then
		obj.GuardTotal = made
	end
	obj.Despawned = 0
	setState(obj, "Guarded")
	recolourGlow(obj, P.crimson_400, 0)
	altarText(obj)
	Fx.Ring(obj.Pos, Config.Guarded.SpawnRadius[2], P.crimson_400)
	Fx.Sound("BossRoar")
	ctx.RunManager.Broadcast("The altar's guardians awaken! Defeat them to claim its treasure.", Color3.fromRGB(255, 120, 100))
end

-- A guard died (killed) or was removed (despawned: the Queen's arrival, the portal burn).
function LootSystem.OnGuardDown(e, killed: boolean)
	local obj = objects[e.Guard or -1]
	e.Guard = nil
	if not obj or obj.Guards[e] == nil then
		return
	end
	obj.Guards[e] = nil
	if killed then
		obj.Killed += 1
	else
		obj.Despawned += 1
	end
	if next(obj.Guards) ~= nil then
		altarText(obj)
		return
	end
	if obj.Despawned > 0 then
		-- the guards were swept away, not beaten: the altar sleeps again (the ones that
		-- were killed stay dead)
		setState(obj, "Dormant")
		obj.WakeAt = os.clock() + 5
		recolourGlow(obj, P.slate_300, 0)
		altarText(obj)
		return
	end
	setState(obj, "Claimable")
	recolourGlow(obj, P.gold_300, 0)
	altarText(obj)
	Fx.Ring(obj.Pos, 12, P.gold_300)
	ctx.RunManager.Broadcast("The altar is unguarded: open it for an item each!", Color3.fromRGB(255, 220, 120))
end

local function stepAltars(now: number)
	-- Any fighting phase: guards swept away by the Queen's arrival or the portal burn must
	-- be wakeable again on the same stage (Explore never comes back after the Queen).
	local phase = ctx.StageManager.GetPhase()
	if phase ~= "Explore" and phase ~= "Boss" and phase ~= "Surge" and phase ~= "Open" then
		return
	end
	local r2 = Config.Guarded.WakeRadius ^ 2
	for _, obj in ipairs(list) do
		if obj.Kind == "Altar" and obj.State == "Dormant" and now >= obj.WakeAt then
			for _, rp in ipairs(ctx.RunManager.GetRunPlayers()) do
				local root: BasePart? = rp.Root
				if rp.Alive and not rp.Paused and root then
					local d = (root.Position - obj.Pos) * FLAT
					if d.X * d.X + d.Z * d.Z <= r2 then
						wake(obj)
						break
					end
				end
			end
		end
	end
end

------------------------------------------------------------------------------------------
-- Using things
------------------------------------------------------------------------------------------

local function usable(obj: Obj): boolean
	local st = obj.State
	if obj.Kind == "Altar" then
		return st == "Claimable"
	end
	return st == "Ready"
end

local function feedback(rp, obj: Obj?, stateName: string, reason: string?)
	local player: Player = rp.Player
	if player.Parent then
		Remotes.FireClient("LootFeedback", player, { Id = obj and obj.Id or 0, State = stateName, Reason = reason })
	end
end

-- Can this player use obj right now? (false, reason) when not.
local function check(rp, obj: Obj): (boolean, string?)
	if not objects[obj.Id] then
		return false, "gone"
	end
	if not rp.Alive or rp.Returned or not rp.Root then
		return false, "down"
	end
	if rp.Paused then
		return false, "paused"
	end
	if not usable(obj) then
		return false, "used"
	end
	local d = ((rp.Root :: BasePart).Position - obj.Pos) * FLAT
	if d.Magnitude > Config.Chests.InteractRadius + 1.5 then
		return false, "far"
	end
	local price = priceFor(rp, obj)
	if price > 0 and ctx.GoldSystem.RunWallet(rp) < price then
		return false, "gold"
	end
	return true, nil
end

local REASON_TEXT = {
	gold = "Not enough gold.",
	used = "Someone was faster.",
	gone = "It's gone.",
}

local function openChest(rp, obj: Obj)
	local price = priceFor(rp, obj)
	if not ctx.GoldSystem.SpendRunGold(rp, price) then
		feedback(rp, obj, "Cancel", "gold")
		ctx.RunManager.Notify(rp.Player, REASON_TEXT.gold, Color3.fromRGB(255, 120, 120))
		return
	end
	setState(obj, "Opened")
	openLid(obj.Chest, obj.CF, "Chest_" .. obj.Type)
	recolourGlow(obj, nil, 1)
	local weights = Config.Chests.Weights[obj.Type] or Config.Chests.Weights.Small
	local id = ctx.ItemSystem.Roll(weights, rp.Stats.Luck)
	ctx.ItemSystem.Grant(rp, id, TITLES[obj.Type], true)
	ctx.RunManager.HoldReward(rp)
	Fx.Sound("Chest")
	if obj.Type == "Golden" then
		Events.Fire("GoldenChest", rp.Player)
	end
end

local function useChance(rp, obj: Obj)
	local S = Config.Shrines
	local price = priceFor(rp, obj)
	if not ctx.GoldSystem.SpendRunGold(rp, price) then
		feedback(rp, obj, "Cancel", "gold")
		ctx.RunManager.Notify(rp.Player, REASON_TEXT.gold, Color3.fromRGB(255, 120, 120))
		return
	end
	obj.Tries += 1
	obj.Price = math.floor(obj.Price * S.ChanceCostGrowth + 0.5)
	obj.Model:SetAttribute("Price", obj.Price)
	Fx.Sound("Shrine")
	if rng:NextNumber() < S.ChanceSuccess then
		obj.Found += 1
		local id = ctx.ItemSystem.Roll(Config.Chests.Weights.Chance, rp.Stats.Luck)
		ctx.ItemSystem.Grant(rp, id, TITLES.Chance, true)
		ctx.RunManager.HoldReward(rp)
		Fx.Ring(obj.Pos, 6, P.gold_300)
	else
		ctx.RunManager.Notify(rp.Player, "The shrine takes your gold... nothing this time.", Color3.fromRGB(200, 200, 210))
		Fx.Ring(obj.Pos, 4, P.stone_400)
	end
	if obj.Found >= S.ChanceMaxItems or obj.Tries >= S.ChanceMaxTries then
		setState(obj, "Spent")
		recolourGlow(obj, P.stone_500, 1)
		setAttrs(obj, { Detail = "The shrine has gone dark" })
	else
		chanceText(obj)
	end
end

local function useBargain(rp, obj: Obj)
	local S = Config.Shrines
	setState(obj, "Active")
	teamBonus.might += S.BargainDamage
	teamBonus.goldGain += S.BargainGold
	enemyHPMult = 1 + S.BargainEnemyHP
	setAttrs(obj, { Detail = "Sealed: active until the next stage" })
	recolourGlow(obj, P.crimson_300, 0)
	refreshTeam()
	Fx.Ring(obj.Pos, 30, P.crimson_400)
	Fx.Sound("Shrine")
	ctx.RunManager.Broadcast(
		string.format(
			"%s sealed a bargain: +%d%% damage and +%d%% gold, but enemies have +%d%% HP this stage!",
			rp.Player.DisplayName,
			math.floor(S.BargainDamage * 100 + 0.5),
			math.floor(S.BargainGold * 100 + 0.5),
			math.floor(S.BargainEnemyHP * 100 + 0.5)
		),
		Color3.fromRGB(255, 150, 130)
	)
end

local function claimAltar(rp, obj: Obj)
	setState(obj, "Claimed")
	openLid(obj.Chest, obj.CF, "Chest_Large")
	recolourGlow(obj, nil, 1)
	altarText(obj)
	Fx.Ring(obj.Pos, 16, P.gold_300)
	Fx.Sound("Chest")
	for _, other in ipairs(ctx.RunManager.GetRunPlayers()) do
		if other.Alive and not other.Returned and other.Stats then
			ctx.ItemSystem.Grant(other, ctx.ItemSystem.Roll(Config.Chests.Weights.Guarded, other.Stats.Luck), TITLES.Guarded, true)
			ctx.RunManager.HoldReward(other)
			Events.Fire("OptionalEvent", other.Player, { Kind = "Altar" })
		end
	end
	ctx.RunManager.Broadcast(rp.Player.DisplayName .. " opened the altar: an item for everyone!", Color3.fromRGB(255, 220, 120))
end

local function complete(rp, obj: Obj)
	if obj.Kind == "Chest" then
		openChest(rp, obj)
	elseif obj.Type == "Chance" then
		useChance(rp, obj)
	elseif obj.Type == "Bargain" then
		useBargain(rp, obj)
	elseif obj.Kind == "Altar" then
		claimAltar(rp, obj)
	end
	feedback(rp, obj, "Done", nil)
end

local function onHold(player: Player, id: any, holding: any)
	if type(id) ~= "number" or type(holding) ~= "boolean" then
		return
	end
	local rp = ctx.RunManager.GetRunPlayer(player)
	if not rp or rp.Returned then
		return
	end
	local current = holds[rp]
	if not holding then
		if current and current.Obj.Id == id then
			holds[rp] = nil
		end
		return
	end
	local obj = objects[id]
	if not obj then
		feedback(rp, nil, "Cancel", "gone")
		return
	end
	if not ctx.RunManager.IsSimulating() then
		feedback(rp, obj, "Cancel", "paused")
		return
	end
	local ok, reason = check(rp, obj)
	if not ok then
		feedback(rp, obj, "Cancel", reason)
		local msg = reason and REASON_TEXT[reason]
		if msg then
			ctx.RunManager.Notify(player, msg, Color3.fromRGB(255, 120, 120))
		end
		return
	end
	holds[rp] = { Obj = obj, Elapsed = 0 }
end

function LootSystem.Step(dt: number)
	if not ctx.RunManager.IsRunning() then
		return
	end
	local simulating = ctx.RunManager.IsSimulating()
	if simulating then
		stepAltars(os.clock())
	end
	if next(holds) == nil then
		return
	end
	local players = ctx.RunManager.GetRunPlayers()
	for rp, h in pairs(holds) do
		if not table.find(players, rp) then
			holds[rp] = nil -- left the run (portal, leaving the game)
		elseif simulating then
			local ok, reason = check(rp, h.Obj)
			if not ok then
				holds[rp] = nil
				feedback(rp, h.Obj, "Cancel", reason)
				local msg = reason and REASON_TEXT[reason]
				if msg and reason ~= "gold" then
					ctx.RunManager.Notify(rp.Player, msg, Color3.fromRGB(255, 200, 140))
				end
			else
				h.Elapsed += dt
				local need = h.Obj.Model:GetAttribute("Hold") or 1
				if h.Elapsed >= need then
					holds[rp] = nil
					local okDone, err = pcall(complete, rp, h.Obj)
					if not okDone then
						warn("[LootSystem] complete failed: " .. tostring(err))
						feedback(rp, h.Obj, "Cancel", "error")
					end
				end
			end
		end
		-- frozen runs (level-up, pause menu) keep the hold where it is
	end
end

function LootSystem.Init(c)
	ctx = c
	folder = Instance.new("Folder")
	folder.Name = "SwarmLoot"
	folder.Parent = workspace
end

function LootSystem.Start()
	-- Releases are never rate-limited: a dropped release would let the server finish a hold
	-- the player let go of (and charge gold). Presses go through the limiter.
	Remotes.Get("LootHold").OnServerEvent:Connect(function(player: Player, id: any, holding: any)
		if holding == false then
			local ok, err = pcall(onHold, player, id, false)
			if not ok then
				warn("[LootSystem] LootHold release error: " .. tostring(err))
			end
		end
	end)
	Remotes.Listen("LootHold", function(player: Player, id: any, holding: any)
		if holding ~= false then
			onHold(player, id, holding)
		end
	end, 8)
end

return LootSystem
