--[[
	LootSystem.lua
	Exploration loot on every stage (Risk of Rain / Megabonk style), placed when a stage is
	built (StageManager → BuildStage) and removed on travel and when the run ends (Clear):

	  Chests (Config.Chests)   10-14 small, 2-3 large, 1 golden. Pay run gold, get one item
	                           (ItemSystem.Roll with the chest's rarity weights).
	  Shrine of Chance         pay gold, 50% chance of an item; each try costs more; goes
	  (Config.Shrines)         dark after 2 items or 6 tries.
	  Bargain Shrine           free, once per stage: the whole team gets +25% added to the
	                           damage bonus and +30% gold (kills, elite chests, bosses, nests,
	                           caravan) for the rest of the stage, the swarm gets +20% HP.
	  Guarded Altar            a free rare chest. Hold its prompt to awaken the elite guards;
	  (Config.Guarded)         when they are dead the
	                           chest unlocks and opening it gives EVERY living teammate an item.
	  Lost Caravan             placed here (Config.Caravan, far from the spawn like the altar),
	  (CaravanEvent.lua)       run by CaravanEvent: hold its ring while waves come.
	Every shrine / the altar says what it gives ("Benefit") and what it costs ("Tradeoff")
	before it is used, and shows its state afterwards.

	World: models in workspace.SwarmLoot, one per object, with attributes the client reads
	(LootUI): LootId, LootKind (Chest | Shrine | Altar), LootType (Small | Large | Golden |
	Chance | Bargain | Guarded), Title, State, Price (this stage's price before the player's
	gold multiplier; 0 = free), Hold (seconds), Benefit, Tradeoff, Detail, Pos; a Shrine of
	Chance also Odds (0-1), ItemsLeft, TriesLeft.
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
local RING_T = 0.88 -- the faint "stand here" disc of shrines, the altar and rune stones

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
	Rune: number?,
	Puzzle: any?,
	Scale: any?, -- the Bargain Shrine's balance (tips when sealed)
	-- feature hooks (docs/features/CHALLENGES.md): set by feature modules, nil otherwise
	Weights: { [string]: number }?, -- item rarity weights instead of the type's
	Title: string?, -- reward popup source instead of TITLES[Type]
	OnOpened: ((any, any) -> ())?, -- after a chest's item was granted (rp, obj)
	OnComplete: ((any, any) -> ())?, -- a finished hold on a feature object (rp, obj)
	OnGuardDown: ((any, boolean) -> ())?, -- its guard died / was removed (e, killed)
}

local ctx
local rng = Random.new()
local folder: Folder
local objects: { [number]: Obj } = {}
local list: { Obj } = {}
local nextId = 0
local holds: { [any]: { Obj: Obj, Elapsed: number } } = {}
local stageNo = 1
local builtHooks: { (any, number) -> () } = {} -- feature hooks after BuildStage (CHALLENGES)
local teamBonus = { might = 0, goldGain = 0 } -- the Bargain Shrine (this stage)
local enemyHPMult = 1

local TITLES = {
	Small = "Small Chest",
	Large = "Large Chest",
	Golden = "Golden Chest",
	Chance = "Shrine of Chance",
	Bargain = "Bargain Shrine",
	Guarded = "Guarded Altar",
	Treasure = "Buried Cache",
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
	-- the multiplier the client was shown (GoldSystem.PriceMult), so shown price == charged price
	return ctx.GoldSystem.PriceMult(player)
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

-- Part-built chests in the same pieces as blender/models/loot.py: Box, Lid (+ Lid*
-- pieces that swing with it), Straps, Fittings. The Lid carries a "Hinge" attribute (back
-- bottom edge, relative to the Lid's centre in model space) so both looks open the same way.
-- One construction for every tier, matching the chest icons: a faceted lid (flat top and
-- two bevels), two bands running over body and lid, a rim at the seam, corner posts and a
-- lock plate with a hasp on the front (-Z, toward the camera). Tiers differ in material:
--   Small   brown wood, gold bands and posts          (icons/chest)
--   Large   crimson panels, steel frame, gold studs    (reward_ChestLarge)
--   Golden  slate panels, gold frame, red gems         (reward_ChestGolden)
--   Plain   the free cache: weathered wood and iron, no gold, no posts
local CHEST_LOOK = {
	Small = { W = 2.6, H = 1.2, D = 1.8, LidH = 0.7, Wood = P.wood_500, Lid = P.wood_400, Band = P.gold_400, Frame = P.gold_400, Lock = P.gold_300 },
	Large = { W = 3.6, H = 1.6, D = 2.4, LidH = 0.9, Wood = P.crimson_600, Lid = P.crimson_500, Band = P.steel_500, Frame = P.steel_500, Lock = P.gold_400, Stud = P.gold_400 },
	Golden = { W = 3.0, H = 1.4, D = 2.1, LidH = 0.8, Wood = P.slate_700, Lid = P.slate_600, Band = P.gold_400, Frame = P.gold_400, Lock = P.gold_300, Stud = P.gold_300, Gem = P.crimson_400 },
	Plain = { W = 2.5, H = 1.15, D = 1.7, LidH = 0.6, Wood = P.wood_600, Lid = P.wood_500, Band = P.steel_700, Frame = P.steel_600, Lock = P.steel_600, Plain = true },
}

local function chestFallback(kind: string)
	return function(m: Model, cf: CFrame, s: number, _pal, _sh)
		local L = CHEST_LOOK[kind] or CHEST_LOOK.Small
		local w, h, d, lh = L.W * s, L.H * s, L.D * s, L.LidH * s
		local lw, ld = w + 0.06, d + 0.06 -- the lid overhangs the box a little
		local half = lh * 0.5
		local topD = ld * 0.52 -- the flat top of the faceted lid
		local bevel = (ld - topD) / 2
		local back = CFrame.Angles(0, math.pi, 0)
		add(m, cf, "Box", Vector3.new(w, h, d), Vector3.new(0, h / 2, 0), L.Wood)
		-- lid: a block, a narrower top and two bevels (front wedge low toward -Z)
		local lid = add(m, cf, "Lid", Vector3.new(lw, half, ld), Vector3.new(0, h + half / 2, 0), L.Lid)
		lid:SetAttribute("Hinge", Vector3.new(0, -half / 2, ld / 2))
		add(m, cf, "LidTop", Vector3.new(lw, half, topD), Vector3.new(0, h + half * 1.5, 0), L.Lid)
		local wedge = function(name: string, size: Vector3, z: number, color: Color3, material: Enum.Material?, rot: CFrame?)
			local p = part({
				Name = name,
				Wedge = true,
				Size = size,
				CFrame = cf * CFrame.new(0, h + half * 1.5, z) * (rot or CFrame.identity),
				Color = color,
				Material = material,
			})
			p.Parent = m
			return p
		end
		wedge("LidBevel", Vector3.new(lw, half, bevel), -(topD + bevel) / 2, L.Lid)
		wedge("LidBevel", Vector3.new(lw, half, bevel), (topD + bevel) / 2, L.Lid, nil, back)
		-- bands over body and lid (the lid's parts swing with it)
		local bw = (kind == "Large" and 0.32 or 0.24) * s
		for _, x in ipairs({ -w * 0.32, w * 0.32 }) do
			add(m, cf, "Straps", Vector3.new(bw, h + 0.02, d + 0.06), Vector3.new(x, h / 2, 0), L.Band, METAL)
			add(m, cf, "LidBand", Vector3.new(bw, half + 0.02, ld + 0.05), Vector3.new(x, h + half / 2, 0), L.Band, METAL)
			add(m, cf, "LidBand", Vector3.new(bw, half + 0.03, topD + 0.02), Vector3.new(x, h + half * 1.5 + 0.015, 0), L.Band, METAL)
			for _, sign in ipairs({ -1, 1 }) do
				local bp = part({
					Name = "LidBand",
					Wedge = true,
					Size = Vector3.new(bw, half + 0.03, bevel + 0.03),
					CFrame = cf * CFrame.new(x, h + half * 1.5 + 0.015, sign * ((topD + bevel) / 2 + 0.012)) * (sign > 0 and back or CFrame.identity),
					Color = L.Band,
					Material = METAL,
				})
				bp.Parent = m
			end
		end
		-- rim at the seam and the foot band
		add(m, cf, "Fittings", Vector3.new(w + 0.12, 0.16 * s, d + 0.12), Vector3.new(0, h - 0.08 * s, 0), L.Frame, METAL)
		add(m, cf, "Fittings", Vector3.new(w + 0.1, 0.18 * s, d + 0.1), Vector3.new(0, 0.09 * s, 0), L.Frame, METAL)
		if not L.Plain then
			-- corner posts (paid chests; the free cache has none)
			for _, x in ipairs({ -w / 2, w / 2 }) do
				for _, z in ipairs({ -d / 2, d / 2 }) do
					add(m, cf, "Fittings", Vector3.new(0.3 * s, h + 0.04, 0.3 * s), Vector3.new(x, h / 2, z), L.Frame, METAL)
					if L.Stud and z < 0 then
						add(m, cf, "Fittings", Vector3.new(0.22, 0.22, 0.22) * s, Vector3.new(x, h * 0.5, z - 0.16 * s), L.Stud, METAL, nil, CFrame.Angles(0, 0, math.rad(45)))
					end
				end
			end
		end
		-- lock plate with a keyhole on the body, the hasp on the lid
		add(m, cf, "Fittings", Vector3.new(0.6 * s, 0.66 * s, 0.14), Vector3.new(0, h - 0.3 * s, -d / 2 - 0.07), L.Lock, METAL)
		add(m, cf, "Fittings", Vector3.new(0.13 * s, 0.24 * s, 0.05), Vector3.new(0, h - 0.36 * s, -d / 2 - 0.16), P.slate_950)
		add(m, cf, "LidHasp", Vector3.new(0.34 * s, half * 0.8, 0.12), Vector3.new(0, h + half * 0.4, -ld / 2 - 0.06), L.Lock, METAL)
		if L.Gem then
			add(m, cf, "Gem", Vector3.new(0.3, 0.3, 0.3) * s, Vector3.new(0, h - 0.3 * s, -d / 2 - 0.2), L.Gem, NEON, nil, CFrame.Angles(0, 0, math.rad(45)))
			add(m, cf, "LidGem", Vector3.new(0.34, 0.34, 0.34) * s, Vector3.new(0, h + lh + 0.1 * s, 0), L.Gem, NEON, nil, CFrame.Angles(0, math.rad(45), math.rad(45)))
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

-- An opened chest steps back: its gems stop glowing and the plinth's gold trim dulls, so
-- the ones still worth walking to stand out (the lid is already open).
local function quietOpened(obj: Obj)
	for _, d in ipairs(obj.Model:GetDescendants()) do
		if d:IsA("BasePart") then
			if d.Material == NEON and (d.Name == "Gem" or d.Name == "LidGem") then
				d.Material = Enum.Material.SmoothPlastic
				d.Color = d.Color:Lerp(P.stone_700, 0.5)
			elseif d.Name == "PlinthTrim" then
				d.Color = P.stone_400
				d.Material = Enum.Material.SmoothPlastic
			end
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
		local disc = part({ Name = "Ring", Shape = Enum.PartType.Cylinder, Size = Vector3.new(0.06, r * 2, r * 2), CFrame = CFrame.new(obj.Pos + Vector3.new(0, 0.05, 0)) * UPRIGHT, Color = color, Transparency = RING_T })
		disc.Parent = obj.Model
		obj.Ring = disc
	end
end

-- Shrine pieces that glow in the sigil colour (fallback parts and the kit mesh alike).
local GLOW_PIECES = { Sigil = true, Glow = true, Rune = true, Runes = true }

local function recolourGlow(obj: Obj, color: Color3?, transparency: number?)
	for _, g in ipairs(obj.Glow) do
		if color then
			g.Color = color
		end
		g.Transparency = transparency or 0
	end
	if obj.Kind == "Shrine" and obj.Type ~= "Rune" then
		-- the mesh may have replaced the part fallback since the shrine was built: its
		-- own sigil pieces are not in obj.Glow, so look them up now
		for _, d in ipairs(obj.Model:GetDescendants()) do
			if d:IsA("BasePart") and GLOW_PIECES[d.Name] and not table.find(obj.Glow, d) then
				if color then
					d.Color = color
				end
				d.Transparency = transparency or 0
			end
		end
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
		obj.Ring.Transparency = (transparency or 0) >= 1 and 1 or RING_T
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

-- "1 item (80% common, 19% uncommon, 1% legendary before luck)" from the chest's rarity
-- weights (Config.Chests.Weights), so the prompt never drifts from the tuning. The prompt is
-- one shared world label, so it shows the base odds; Luck (ItemSystem.Roll) raises the
-- rarer shares per player, hence "before luck".
local function chestBenefit(typeName: string): string
	local weights = Config.Chests.Weights[typeName] or Config.Chests.Weights.Small
	local total = 0
	for _, w in pairs(weights) do
		total += w
	end
	local parts = {}
	for _, rarity in ipairs({ "Common", "Uncommon", "Legendary" }) do
		local w = weights[rarity] or 0
		if w > 0 and total > 0 then
			table.insert(parts, string.format("%d%% %s", math.floor(w / total * 100 + 0.5), string.lower(rarity)))
		end
	end
	if #parts == 1 then
		local space = string.find(parts[1], " ") or 0
		return "1 " .. string.sub(parts[1], space + 1) .. " item"
	end
	return "1 item (" .. table.concat(parts, ", ") .. " before luck)"
end

--[[
	Paid chests read as premium from across the map (owner: "a chest you pay for and a
	chest you pick up look identical"): the chest stands on a gold-ringed stone plinth,
	a gold coin hangs over it (it costs gold) and a soft light beam rises from it, wider
	and brighter per tier. The coin and the beam are glow pieces: they vanish when the
	chest is opened. Free chests (the Buried Cache, elite drops) stay plain wood.
]]
local PLINTH_H = 0.35
local BEAM_FROM = 4.9 -- studs above the floor
local PREMIUM = {
	Small = { R = 2.2, Beam = 0.3, BeamH = 7, BeamT = 0.84, Color = P.gold_300 },
	Large = { R = 2.8, Beam = 0.45, BeamH = 10, BeamT = 0.8, Color = P.gold_300 },
	Golden = { R = 2.6, Beam = 0.65, BeamH = 14, BeamT = 0.74, Color = P.gold_200 },
}

local function premiumDressing(obj: Obj, typeName: string, pos: Vector3, cf: CFrame)
	local L = PREMIUM[typeName] or PREMIUM.Small
	local plinth = part({ Name = "Plinth", Shape = Enum.PartType.Cylinder, Size = Vector3.new(PLINTH_H, L.R * 2, L.R * 2), CFrame = CFrame.new(pos + Vector3.new(0, PLINTH_H / 2, 0)) * UPRIGHT, Color = P.stone_500 })
	plinth.Parent = obj.Model
	local ring = part({ Name = "PlinthTrim", Shape = Enum.PartType.Cylinder, Size = Vector3.new(PLINTH_H * 0.6, L.R * 2 + 0.35, L.R * 2 + 0.35), CFrame = CFrame.new(pos + Vector3.new(0, PLINTH_H * 0.3, 0)) * UPRIGHT, Color = P.gold_500, Material = METAL })
	ring.Parent = obj.Model
	-- the beam starts above the coin / orb, so it never paints over the chest itself
	local beam = part({ Name = "Beam", Shape = Enum.PartType.Cylinder, Size = Vector3.new(L.BeamH, L.Beam * 2, L.Beam * 2), CFrame = CFrame.new(pos + Vector3.new(0, BEAM_FROM + L.BeamH / 2, 0)) * UPRIGHT, Color = L.Color, Material = NEON, Transparency = L.BeamT })
	beam.Parent = obj.Model
	table.insert(obj.Glow, beam)
	if typeName ~= "Golden" then -- the golden chest already wears its glowing orb up there
		local coin = part({ Name = "Coin", Shape = Enum.PartType.Cylinder, Size = Vector3.new(0.22, 1.25, 1.25), CFrame = CFrame.new(pos + Vector3.new(0, typeName == "Large" and 4.2 or 3.6, 0)) * cf.Rotation * CFrame.Angles(0, math.rad(90), 0), Color = P.gold_400, Material = METAL })
		coin.Parent = obj.Model
		table.insert(obj.Glow, coin)
	end
end

local function buildChest(typeName: string, pos: Vector3, yawJitter: number, free: boolean?)
	local cf = CFrame.new(pos) * FACE_CAMERA * CFrame.Angles(0, yawJitter, 0)
	local obj = newObj("Chest", typeName, pos, cf)
	obj.Price = ItemData.StagePrice(Config.Chests.Cost[typeName] or 25, stageNo, Config.Chests.CostExponent)
	if free then
		-- a plain wooden chest straight on the ground (part look; no kit mesh for it)
		obj.Chest = MapBuilder.PlaceProp(obj.Model, "Chest_Plain", cf, 1, nil, { fallback = chestFallback("Plain") })
	else
		premiumDressing(obj, typeName, pos, cf)
		local kit = "Chest_" .. typeName
		obj.Chest = MapBuilder.PlaceProp(obj.Model, kit, cf + Vector3.new(0, PLINTH_H, 0), 1, nil, { fallback = chestFallback(typeName) })
	end
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
	return obj
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
		-- numbers for the client's odds row (LootUI)
		Odds = S.ChanceSuccess,
		ItemsLeft = math.max(0, left),
		TriesLeft = math.max(0, S.ChanceMaxTries - obj.Tries),
	})
end

--[[
	What stands on top of a shrine tells its deal before any panel is read:
	  Shrine of Chance   a large gold coin on its edge with a glowing core: it takes gold
	                     (the same coin the paid chests wear)
	  Bargain Shrine     an iron balance with a gold pan (the team's boon) and a crimson
	                     pan (the swarm's extra HP): a trade. Sealing it tips the balance
	                     and the shrine goes quiet (no glow, no ring; the HUD chip stays).
	Both keep the faint ring showing where to stand.
]]
local function shrineCrown(obj: Obj, typeName: string, cf: CFrame, top: number)
	local m = obj.Model
	local face = CFrame.Angles(0, math.rad(90), 0) -- a cylinder's flat side toward the camera
	if typeName == "Chance" then
		local at = cf * CFrame.new(0, top + 1.3, 0)
		local coin = part({ Name = "Coin", Shape = Enum.PartType.Cylinder, Size = Vector3.new(0.3, 1.9, 1.9), CFrame = at * face, Color = P.gold_400, Material = METAL })
		coin.Parent = m
		local core = part({ Name = "Glow", Shape = Enum.PartType.Cylinder, Size = Vector3.new(0.34, 1.1, 1.1), CFrame = at * face, Color = P.gold_300, Material = NEON })
		core.Parent = m
		table.insert(obj.Glow, coin)
		table.insert(obj.Glow, core)
	else
		local iron = P.steel_700
		local function piece(name: string, size: Vector3, at: CFrame, color: Color3, material: Enum.Material?, shape: Enum.PartType?)
			local p = part({ Name = name, Shape = shape, Size = size, CFrame = cf * at, Color = color, Material = material })
			p.Parent = m
			return p
		end
		piece("Scale", Vector3.new(0.22, 1.9, 0.22), CFrame.new(0, top + 0.95, 0), iron, METAL)
		piece("Scale", Vector3.new(0.4, 0.4, 0.4), CFrame.new(0, top + 1.95, 0) * CFrame.Angles(0, math.rad(45), math.rad(45)), P.gold_500, METAL)
		local arm = {}
		table.insert(arm, piece("ScaleArm", Vector3.new(3.2, 0.16, 0.16), CFrame.new(0, top + 1.75, 0), iron, METAL))
		for _, side in ipairs({ -1, 1 }) do
			local x = side * 1.45
			table.insert(arm, piece("ScaleArm", Vector3.new(0.06, 0.8, 0.06), CFrame.new(x, top + 1.35, 0), iron, METAL))
			local pan = piece("ScaleArm", Vector3.new(0.14, 1.0, 1.0), CFrame.new(x, top + 0.95, 0) * UPRIGHT, side < 0 and P.gold_300 or P.crimson_400, NEON, Enum.PartType.Cylinder)
			table.insert(arm, pan)
		end
		obj.Scale = { Parts = arm, Pivot = cf * CFrame.new(0, top + 1.75, 0) }
	end
	local r = Config.Chests.InteractRadius
	local disc = part({ Name = "Ring", Shape = Enum.PartType.Cylinder, Size = Vector3.new(0.06, r * 2, r * 2), CFrame = CFrame.new(obj.Pos + Vector3.new(0, 0.05, 0)) * UPRIGHT, Color = typeName == "Chance" and P.gold_300 or P.crimson_400, Transparency = RING_T })
	disc.Parent = m
	obj.Ring = disc
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
	shrineCrown(obj, typeName, cf, kitTop(kit, 5.0))
	setAttrs(obj, { Hold = Config.Shrines.HoldSeconds, State = "Ready" })
	if typeName == "Chance" then
		obj.Price = ItemData.StagePrice(Config.Shrines.ChanceCost, stageNo, Config.Chests.CostExponent)
		obj.Model:SetAttribute("Price", obj.Price)
		chanceText(obj)
	else
		local S = Config.Shrines
		setAttrs(obj, {
			-- the damage is added to the build's damage bonus (Might, additive), the gold to
			-- the gold bonus; it pays on kills, elite chests and bosses (also nests and the
			-- caravan), not on the return bonus, full-build coins or survival gold
			Benefit = string.format("Team: +%d%% added to damage bonus, +%d%% gold from kills, elite chests and bosses this stage", math.floor(S.BargainDamage * 100 + 0.5), math.floor(S.BargainGold * 100 + 0.5)),
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

-- A run with one player: rewards say "you", not "every teammate" (COPY CP-02).
local function soloRun(): boolean
	return #ctx.RunManager.GetRunPlayers() <= 1
end

local function altarText(obj: Obj)
	local st = obj.State
	if st == "Dormant" then
		local n = obj.GuardTotal > 0 and (obj.GuardTotal - obj.Killed) or guardCount()
		setAttrs(obj, {
			Benefit = soloRun() and "Free uncommon or legendary item" or "Free uncommon or legendary item for every teammate",
			Tradeoff = string.format("Hold to awaken %d elite guards", n),
			Detail = "Dormant · activate when ready",
		})
	elseif st == "Guarded" then
		local left = 0
		for _ in pairs(obj.Guards) do
			left += 1
		end
		setAttrs(obj, { Detail = string.format("Guards left: %d / %d", left, obj.GuardTotal) })
	elseif st == "Claimable" then
		setAttrs(obj, { Benefit = soloRun() and "Free: one item for you" or "Free: one item for every teammate", Tradeoff = "", Detail = "Unguarded: open it!" })
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

--[[
	Star / Sun / Moon rune stones. Each stone is a small monument: a round plinth, a short
	pillar and a tablet leaning back toward the run camera (its face is square to the
	camera's 55° pitch) with the rune's glyph raised on it: a crescent (Moon), a disc with
	rays (Sun), a five-pointed star (Star). The same stone family as the portal's masonry.
	A low order tablet in the middle shows the sequence left to right as three small flat
	glyphs. States (runeLook):
	  ready      glyphs carved in a muted tone, no light
	  correct    a stone pressed in the right order: its glyph and its order token glow
	  reset      a wrong stone: every glyph flashes crimson for a moment, then back to ready
	  completed  every glyph and token turns quiet gold (no glow, no light, no rings)
	The stones stand RUNE_RADIUS from the centre, far enough apart that their interact
	circles (Config.Chests.InteractRadius) never overlap: at most one stone is in reach, so
	the nearest-target prompt can never pick a stone the player did not walk to.
]]
local RUNE_NAMES = { "Moon", "Sun", "Star" }
local RUNE_COLORS = { P.fx_arcane, P.gold_300, P.fx_ivory }
local RUNE_RADIUS = 9
local RUNE_TILT = math.rad(Config.Camera.Pitch) -- the tablet leans back until it faces the camera
local RUNE_FLASH = 0.7

-- Raised glyph pieces for rune `id` on a face frame `f` (X right, Y up the face, Z out of
-- the face), `size` studs across. Returns the pieces (they are recoloured by state).
local function runeGlyph(m: Model, f: CFrame, id: number, size: number, faceColor: Color3): { BasePart }
	local out: { BasePart } = {}
	local t = math.max(0.06, size * 0.05)
	local function piece(name: string, sz: Vector3, at: CFrame, shape: Enum.PartType?, color: Color3?)
		local p = part({ Name = name, Shape = shape, Size = sz, CFrame = f * at, Color = color or RUNE_COLORS[id] })
		p.Parent = m
		if not color then
			table.insert(out, p)
		end
		return p
	end
	local DISC = CFrame.Angles(0, math.rad(90), 0) -- a cylinder's axis (X) out of the face
	if id == 1 then
		-- crescent: a disc with a face-coloured disc over its upper right
		piece("Glyph", Vector3.new(t, size * 0.86, size * 0.86), CFrame.new(0, 0, t / 2) * DISC, Enum.PartType.Cylinder)
		piece("GlyphCut", Vector3.new(t * 1.2, size * 0.72, size * 0.72), CFrame.new(size * 0.22, size * 0.12, t * 0.7) * DISC, Enum.PartType.Cylinder, faceColor)
	elseif id == 2 then
		-- sun: a disc and eight rays
		piece("Glyph", Vector3.new(t, size * 0.5, size * 0.5), CFrame.new(0, 0, t / 2) * DISC, Enum.PartType.Cylinder)
		for k = 0, 7 do
			local a = k * math.pi / 4
			piece("Glyph", Vector3.new(size * 0.1, size * 0.2, t), CFrame.new(math.cos(a) * size * 0.4, math.sin(a) * size * 0.4, t / 2) * CFrame.Angles(0, 0, a - math.pi / 2))
		end
	else
		-- star: five tapering points around a small centre
		piece("Glyph", Vector3.new(size * 0.3, size * 0.3, t), CFrame.new(0, 0, t / 2) * CFrame.Angles(0, 0, math.rad(45)))
		for k = 0, 4 do
			local a = math.pi / 2 + k * math.pi * 2 / 5
			local rot = CFrame.Angles(0, 0, a - math.pi / 2)
			piece("Glyph", Vector3.new(size * 0.17, size * 0.22, t), CFrame.new(math.cos(a) * size * 0.2, math.sin(a) * size * 0.2, t / 2) * rot)
			piece("Glyph", Vector3.new(size * 0.08, size * 0.18, t), CFrame.new(math.cos(a) * size * 0.38, math.sin(a) * size * 0.38, t / 2) * rot)
		end
	end
	return out
end

local function runeText(puzzle)
	local names = {}
	for _, id in ipairs(puzzle.Order) do table.insert(names, RUNE_NAMES[id]) end
	for _, obj in ipairs(puzzle.Nodes) do
		setAttrs(obj, { Detail = "Order: " .. table.concat(names, " > ") .. " · " .. puzzle.Progress .. "/3" })
	end
end

local function paintGlyph(pieces: { BasePart }, color: Color3, lit: boolean)
	for _, p in ipairs(pieces) do
		p.Color = color
		p.Material = lit and NEON or Enum.Material.SmoothPlastic
	end
end

-- Paints every stone and order token for the puzzle's state ("flash" = a wrong stone).
local function runeLook(puzzle, flash: boolean?)
	local muted = function(c: Color3): Color3 return c:Lerp(P.stone_500, 0.5) end
	for _, obj in ipairs(puzzle.Nodes) do
		local id = obj.Rune :: number
		local step = table.find(puzzle.Order, id) or 3
		local lit = not puzzle.Solved and step <= puzzle.Progress
		local color = puzzle.Solved and P.gold_500 or flash and P.crimson_400 or lit and RUNE_COLORS[id] or muted(RUNE_COLORS[id])
		paintGlyph(obj.Glow, color, (lit or flash == true) and not puzzle.Solved)
		if obj.Light then
			obj.Light.Enabled = lit or flash == true
			obj.Light.Color = flash and P.crimson_400 or RUNE_COLORS[id]
		end
		if obj.Ring then
			obj.Ring.Color = lit and RUNE_COLORS[id] or P.stone_300
			obj.Ring.Transparency = puzzle.Solved and 1 or RING_T
		end
	end
	for k, pieces in ipairs(puzzle.Tokens) do
		local id = puzzle.Order[k]
		local lit = not puzzle.Solved and k <= puzzle.Progress
		paintGlyph(pieces, puzzle.Solved and P.gold_500 or flash and P.crimson_400 or lit and RUNE_COLORS[id] or muted(RUNE_COLORS[id]), lit or flash == true)
	end
end

local function buildRunes(arena, centre: Vector3)
	local puzzle = { Order = { 1, 2, 3 }, Progress = 0, Nodes = {}, Tokens = {}, Solved = false, Flash = 0, Tablet = nil :: Model? }
	for i = 3, 2, -1 do
		local j = rng:NextInteger(1, i)
		puzzle.Order[i], puzzle.Order[j] = puzzle.Order[j], puzzle.Order[i]
	end
	MapBuilder.ClearDecor(arena, centre, RUNE_RADIUS + 3)
	local lean = CFrame.Angles(-RUNE_TILT, 0, 0) -- top edge away from the camera (-Z)
	for i = 1, 3 do
		-- one stone left, one right, one at the back (the camera sees all three faces)
		local angle = math.rad(-90) + (i - 1) * math.pi * 2 / 3
		local pos = centre + Vector3.new(math.cos(angle) * RUNE_RADIUS, 0, math.sin(angle) * RUNE_RADIUS)
		local cf = CFrame.new(pos)
		local obj = newObj("Shrine", "Rune", pos, cf)
		obj.Rune, obj.Puzzle = i, puzzle
		local m = obj.Model
		add(m, cf, "Dais", Vector3.new(0.5, 3.6, 3.6), Vector3.new(0, 0.25, 0), P.stone_600, nil, Enum.PartType.Cylinder, UPRIGHT)
		add(m, cf, "Stone", Vector3.new(1.7, 1.9, 1.3), Vector3.new(0, 1.45, 0.15), P.stone_500)
		add(m, cf, "Cap", Vector3.new(2.0, 0.25, 1.5), Vector3.new(0, 2.45, 0.15), P.stone_400)
		-- the leaning tablet on the cap; its face (+Z of `face`) looks at the camera
		local face = cf * CFrame.new(0, 3.2, 0.25) * lean
		local slab = part({ Name = "Box", Size = Vector3.new(2.9, 2.9, 0.45), CFrame = face * CFrame.new(0, 0, -0.225), Color = P.stone_600, CastShadow = true })
		slab.Parent = m
		local rim = part({ Name = "Trim", Size = Vector3.new(3.15, 3.15, 0.3), CFrame = face * CFrame.new(0, 0, -0.42), Color = P.stone_400 })
		rim.Parent = m
		obj.Glow = runeGlyph(m, face, i, 2.3, P.stone_600)
		local l = Instance.new("PointLight")
		l.Range = 12
		l.Brightness = 1.2
		l.Shadows = false
		l.Enabled = false
		l.Parent = obj.Glow[1]
		obj.Light = l
		local r = Config.Chests.InteractRadius
		local disc = part({ Name = "Ring", Shape = Enum.PartType.Cylinder, Size = Vector3.new(0.06, r * 2, r * 2), CFrame = CFrame.new(pos + Vector3.new(0, 0.05, 0)) * UPRIGHT, Color = P.stone_300, Transparency = RING_T })
		disc.Parent = m
		obj.Ring = disc
		setAttrs(obj, { Title = RUNE_NAMES[i] .. " rune", Hold = 0.4, State = "Ready", Benefit = "Complete the sequence for a team item", Tradeoff = "Wrong rune resets the sequence" })
		m.Parent = folder
		table.insert(puzzle.Nodes, obj)
	end
	-- the order tablet in the middle: three flat glyphs, first on the left (screen left = -X)
	local tablet = Instance.new("Model")
	tablet.Name = "RuneOrder"
	local tcf = CFrame.new(centre)
	add(tablet, tcf, "Dais", Vector3.new(0.3, 6, 6), Vector3.new(0, 0.15, 0), P.stone_400, nil, Enum.PartType.Cylinder, UPRIGHT)
	add(tablet, tcf, "Top", Vector3.new(5.2, 0.12, 2), Vector3.new(0, 0.34, 0), P.stone_600)
	local flat = CFrame.fromMatrix(Vector3.zero, Vector3.new(1, 0, 0), Vector3.new(0, 0, -1)) -- face up, glyph "up" = away from the camera
	for k, id in ipairs(puzzle.Order) do
		local x = (k - 2) * 1.7
		if k > 1 then
			-- a small chevron between tokens: the sequence reads left to right
			add(tablet, tcf, "Mark", Vector3.new(0.12, 0.06, 0.12), Vector3.new(x - 0.85, 0.43, 0), P.stone_200, nil, nil, CFrame.Angles(0, math.rad(45), 0))
		end
		puzzle.Tokens[k] = runeGlyph(tablet, tcf * CFrame.new(x, 0.4, 0) * flat, id, 1.45, P.stone_600)
	end
	tablet.Parent = puzzle.Nodes[1].Model -- removed with the stones (LootSystem.Clear)
	puzzle.Tablet = tablet
	runeLook(puzzle)
	runeText(puzzle)
end

local function buildTreasure(arena, pos: Vector3)
	local obj = buildChest("Small", pos, 0, true)
	obj.Type, obj.Price = "Treasure", 0
	setAttrs(obj, { LootType = "Treasure", Title = TITLES.Treasure, Price = 0, Benefit = "Free uncommon or legendary item", Detail = "Discovered cache · hold to claim" })
	addGlow(obj, pos + Vector3.new(0, 2.7, 0), P.gold_300, true, false)
	MapBuilder.ClearDecor(arena, pos, 3)
	return obj
end

--[[
	EXPLORE hook (docs/features/EXPLORE.md, SecretRoom.lua): a free treasure chest placed
	mid-stage, exactly like the Buried Cache (same weights, hold, exactly-once opening);
	`title` renames it. Removed with the rest of the loot by Clear (travel, run end).
]]
function LootSystem.AddTreasure(arena, pos: Vector3, title: string?): number
	local obj = buildTreasure(arena, pos)
	if title then
		setAttrs(obj, { Title = title })
	end
	return obj.Id
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
	-- Draw distinct optional locations; their rewards belong to this run only.
	local kinds = table.clone(Config.Encounters.Types)
	if not ctx.CaravanEvent then
		local index = table.find(kinds, "Caravan")
		if index then table.remove(kinds, index) end
	end
	local count = math.min(#kinds, rng:NextInteger(Config.Encounters.Count[1], Config.Encounters.Count[2]))
	for _ = 1, count do
		local kind = table.remove(kinds, rng:NextInteger(1, #kinds))
		local K = Config.Caravan
		local at = spot({
			MinDistance = kind == "Caravan" and K.MinDistance or Config.Guarded.MinDistance,
			Clearance = kind == "Caravan" and K.Clearance or 11,
			Spacing = math.max(C.Spacing, K.ZoneRadius * 2 + 10),
		})
		if at then
			if kind == "Guarded" then buildAltar(arena, at)
			elseif kind == "Runes" then buildRunes(arena, at)
			elseif kind == "Treasure" then buildTreasure(arena, at)
			elseif kind == "Caravan" then ctx.CaravanEvent.Build(arena, at, stageNo) end
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
	for _, fn in ipairs(builtHooks) do
		local ok, err = pcall(fn, arena, stageNo) -- feature variants (cursed chests); own rng
		if not ok then
			warn("[LootSystem] stage hook failed: " .. tostring(err))
		end
	end
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
	local row = EnemyData.GetSpawnRow(ctx.EnemySpawner.ProgressionTime())
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
		obj.WakeAt = ctx.RunManager.GetRunTime() + 2 -- the field is full: try again soon
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
	ctx.RunManager.Broadcast("The altar's guardians awaken! Defeat them to claim its treasure.", Color3.fromRGB(255, 120, 100), nil, { Id = "altar.guardians", Class = "Critical" })
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
	if obj.OnGuardDown then
		obj.OnGuardDown(e, killed) -- a feature's guard (MiniBoss): it decides
		return
	end
	if next(obj.Guards) ~= nil then
		altarText(obj)
		return
	end
	if obj.Despawned > 0 then
		-- the guards were swept away, not beaten: the altar sleeps again (the ones that
		-- were killed stay dead)
		setState(obj, "Dormant")
		obj.WakeAt = ctx.RunManager.GetRunTime() + 5
		recolourGlow(obj, P.slate_300, 0)
		altarText(obj)
		return
	end
	setState(obj, "Claimable")
	recolourGlow(obj, P.gold_300, 0)
	altarText(obj)
	Fx.Ring(obj.Pos, 12, P.gold_300)
	ctx.RunManager.Broadcast(soloRun() and "The altar is unguarded: open it for a free item!" or "The altar is unguarded: open it for an item each!", Color3.fromRGB(255, 220, 120), nil, { Id = "altar.unguarded" })
end

------------------------------------------------------------------------------------------
-- Using things
------------------------------------------------------------------------------------------

local function usable(obj: Obj): boolean
	local st = obj.State
	if obj.Kind == "Altar" then
		return st == "Claimable" or (st == "Dormant" and ctx.RunManager.GetRunTime() >= obj.WakeAt)
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
	if obj.State == "Locked" then
		return false, "locked" -- a feature chest still guarded (MiniBoss)
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
	locked = "Defeat its guard first.",
}

local function openChest(rp, obj: Obj)
	local price = priceFor(rp, obj)
	if not ctx.GoldSystem.SpendRunGold(rp, price) then
		feedback(rp, obj, "Cancel", "gold")
		ctx.RunManager.Notify(rp.Player, REASON_TEXT.gold, Color3.fromRGB(255, 120, 120))
		return
	end
	if ctx.MetaService then
		ctx.MetaService.OnGoldPaid(rp, price) -- Haggler's Coin Sigil: part of the price back
	end
	-- Exactly once (ISSUE TS-02): the chest leaves "Ready" before anything else, so no
	-- second hold (this player's or a teammate's) can complete it, and the item is granted
	-- right after the gold is taken, before any cosmetic step that could fail. What the
	-- client shows afterwards (card, reveal, skip, close, death) never touches the grant.
	setState(obj, "Opened")
	local weights = obj.Weights or Config.Chests.Weights[obj.Type] or (obj.Type == "Treasure" and Config.Chests.Weights.Large) or Config.Chests.Weights.Small
	local id = ctx.ItemSystem.Roll(weights, rp.Stats.Luck)
	local granted, dramatic = ctx.ItemSystem.Grant(rp, id, obj.Title or TITLES[obj.Type], true)
	if granted then
		-- the Golden Chest always gets the contained reveal (it pays a Legendary anyway)
		ctx.RunManager.HoldReward(rp, dramatic == true or obj.Type == "Golden")
	else
		warn(string.format("[LootSystem] %s paid %d for a %s but no item could be granted", rp.Player.Name, price, obj.Type))
	end
	local okFx, err = pcall(function()
		openLid(obj.Chest, obj.CF, "Chest_" .. (obj.Type == "Treasure" and "Small" or obj.Type))
		recolourGlow(obj, nil, 1)
		quietOpened(obj)
	end)
	if not okFx then
		warn("[LootSystem] chest open effect failed: " .. tostring(err))
	end
	Fx.Sound("Chest")
	if obj.Type == "Golden" then
		Events.Fire("GoldenChest", rp.Player)
	end
	if obj.OnOpened then
		local okHook, hookErr = pcall(obj.OnOpened, rp, obj) -- after the grant (cursed chest)
		if not okHook then
			warn("[LootSystem] chest hook failed: " .. tostring(hookErr))
		end
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
	if ctx.MetaService then
		ctx.MetaService.OnGoldPaid(rp, price) -- Haggler's Coin Sigil: part of the price back
	end
	obj.Tries += 1
	obj.Price = math.floor(obj.Price * S.ChanceCostGrowth + 0.5)
	obj.Model:SetAttribute("Price", obj.Price)
	Fx.Sound("Shrine")
	if rng:NextNumber() < S.ChanceSuccess then
		obj.Found += 1
		local id = ctx.ItemSystem.Roll(Config.Chests.Weights.Chance, rp.Stats.Luck)
		local granted, dramatic = ctx.ItemSystem.Grant(rp, id, TITLES.Chance, true)
		if granted then ctx.RunManager.HoldReward(rp, dramatic == true) end
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
	-- sealed: the balance tips toward the crimson pan and the shrine goes quiet (the HUD
	-- chip carries the active bargain from here)
	recolourGlow(obj, P.crimson_600, 0)
	for _, d in ipairs(obj.Model:GetDescendants()) do
		if d:IsA("BasePart") and d.Material == NEON then
			d.Material = Enum.Material.SmoothPlastic
		end
	end
	if obj.Light then
		obj.Light.Enabled = false
	end
	if obj.Ring then
		obj.Ring.Transparency = 1
	end
	local scale = obj.Scale
	if scale then
		local pivot: CFrame = scale.Pivot
		local tip = pivot * CFrame.Angles(0, 0, math.rad(-14)) * pivot:Inverse()
		for _, p in ipairs(scale.Parts) do
			local level = p.Shape == Enum.PartType.Cylinder
			local moved = tip * p.CFrame
			-- pans hang level: move them with the arm, keep their own rotation
			p.CFrame = level and (CFrame.new(moved.Position) * p.CFrame.Rotation) or moved
			if level then
				p.Color = p.Color:Lerp(P.stone_700, 0.35)
			end
		end
	end
	refreshTeam()
	Fx.Ring(obj.Pos, 30, P.crimson_400)
	Fx.Sound("Shrine")
	ctx.RunManager.Broadcast(
		string.format(
			"%s sealed a bargain: +%d%% added to damage bonus, +%d%% gold from kills, elite chests and bosses, but enemies have +%d%% HP this stage!",
			rp.Player.DisplayName,
			math.floor(S.BargainDamage * 100 + 0.5),
			math.floor(S.BargainGold * 100 + 0.5),
			math.floor(S.BargainEnemyHP * 100 + 0.5)
		),
		Color3.fromRGB(255, 150, 130),
		nil,
		{ Id = "shrine.bargain" }
	)
end

local function claimAltar(rp, obj: Obj)
	-- claimed first (no second claim), grants next, cosmetics last (TS-02)
	setState(obj, "Claimed")
	for _, other in ipairs(ctx.RunManager.GetRunPlayers()) do
		if other.Alive and not other.Returned and other.Stats then
			local granted, dramatic = ctx.ItemSystem.Grant(other, ctx.ItemSystem.Roll(Config.Chests.Weights.Guarded, other.Stats.Luck), TITLES.Guarded, true, true)
			if granted then ctx.RunManager.HoldReward(other, dramatic == true) end
			Events.Fire("OptionalEvent", other.Player, { Kind = "Altar" })
		end
	end
	local okFx, err = pcall(function()
		openLid(obj.Chest, obj.CF, "Chest_Large")
		recolourGlow(obj, nil, 1)
		quietOpened(obj)
		altarText(obj)
	end)
	if not okFx then
		warn("[LootSystem] altar open effect failed: " .. tostring(err))
	end
	Fx.Ring(obj.Pos, 16, P.gold_300)
	Fx.Sound("Chest")
	ctx.RunManager.Broadcast(soloRun() and "You opened the altar: a free item!" or (rp.Player.DisplayName .. " opened the altar: an item for everyone!"), Color3.fromRGB(255, 220, 120), nil, { Id = "altar.opened" })
end

local function useRune(rp, obj: Obj)
	local puzzle = obj.Puzzle
	if not puzzle or puzzle.Solved then return end
	if obj.Rune ~= puzzle.Order[puzzle.Progress + 1] then
		-- a wrong rune resets the sequence; the first rune pressed again starts it over
		puzzle.Progress = obj.Rune == puzzle.Order[1] and 1 or 0
		ctx.RunManager.Notify(rp.Player, "The rune sequence resets. Read the stones' order.", P.crimson_400)
		-- every glyph flashes crimson for a moment, then shows the restarted sequence
		puzzle.Flash += 1
		local flash = puzzle.Flash
		runeLook(puzzle, true)
		task.delay(RUNE_FLASH, function()
			if puzzle.Flash == flash and not puzzle.Solved then
				runeLook(puzzle)
			end
		end)
	else
		puzzle.Progress += 1
		Fx.Ring(obj.Pos, 6, RUNE_COLORS[obj.Rune :: number])
		Fx.Sound("Shrine")
		runeLook(puzzle)
	end
	runeText(puzzle)
	if puzzle.Progress < 3 then return end
	puzzle.Solved = true
	for _, node in ipairs(puzzle.Nodes) do
		setState(node, "Spent")
		setAttrs(node, { Detail = "Sequence complete · item claimed" })
	end
	runeLook(puzzle) -- completed: quiet gold, no light, no rings
	Fx.Ring(obj.Pos, 10, P.gold_300)
	for _, other in ipairs(ctx.RunManager.GetRunPlayers()) do
		if other.Alive and not other.Returned and other.Stats then
			local granted, dramatic = ctx.ItemSystem.Grant(other, ctx.ItemSystem.Roll(Config.Chests.Weights.Guarded, other.Stats.Luck), "Rune stones", true, true)
			if granted then ctx.RunManager.HoldReward(other, dramatic == true) end
		end
	end
end

local function complete(rp, obj: Obj)
	if obj.OnComplete then
		obj.OnComplete(rp, obj) -- a feature object (Shrine of Trial)
	elseif obj.Kind == "Chest" then
		openChest(rp, obj)
	elseif obj.Type == "Rune" then
		useRune(rp, obj)
	elseif obj.Type == "Chance" then
		useChance(rp, obj)
	elseif obj.Type == "Bargain" then
		useBargain(rp, obj)
	elseif obj.Kind == "Altar" then
		if obj.State == "Dormant" then wake(obj) else claimAltar(rp, obj) end
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

------------------------------------------------------------------------------------------
-- Feature hooks (docs/features/CHALLENGES.md): objects that use the hold / prompt /
-- reward pipeline above. The owning module sets obj.Weights / Title / OnOpened /
-- OnComplete / OnGuardDown; everything is removed with the stage (Clear).
------------------------------------------------------------------------------------------

-- fn(arena, stage) after every BuildStage (the stage's chests are in Objects()).
function LootSystem.OnBuilt(fn: (any, number) -> ())
	table.insert(builtHooks, fn)
end

-- A chest of a normal type at pos (free = the plain wooden look, no price).
function LootSystem.AddFeatureChest(arena, typeName: string, pos: Vector3, free: boolean?): Obj
	local obj = buildChest(typeName, pos, 0, free)
	if free then
		obj.Price = 0
		setAttrs(obj, { Price = 0 })
	end
	MapBuilder.ClearDecor(arena, pos, 3)
	return obj
end

-- A stone shrine (the Shrine kit) with a sigil colour, a light and the stand-here ring.
function LootSystem.AddFeatureShrine(arena, typeName: string, pos: Vector3, sigil: Color3, stone: Color3?): Obj
	local cf = CFrame.new(pos) * FACE_CAMERA
	local obj = newObj("Shrine", typeName, pos, cf)
	local look = { Gold = sigil, Stone = stone or P.stone_600, Base = P.stone_800 }
	local shrineFallback = MapBuilder.FallbackFor("Shrine")
	local fallback = shrineFallback
		and function(fm: Model, fcf: CFrame, fs: number, _pal, sh: boolean)
			(shrineFallback :: any)(fm, fcf, fs, look, sh)
		end
	local m = MapBuilder.PlaceProp(obj.Model, "Shrine", cf, 1, look, { fallback = fallback })
	for _, d in ipairs(m:GetDescendants()) do
		if d:IsA("BasePart") and GLOW_PIECES[d.Name] then
			d.Material = NEON
			d.Color = sigil
			table.insert(obj.Glow, d)
		end
	end
	MapBuilder.AddCollider(arena, "Shrine", cf, 1)
	addGlow(obj, pos + Vector3.new(0, kitTop("Shrine", 5.0) + 1.4, 0), sigil, true, true)
	MapBuilder.ClearDecor(arena, pos, 3)
	setAttrs(obj, { Hold = Config.Shrines.HoldSeconds, State = "Ready" })
	obj.Model.Parent = folder
	return obj
end

function LootSystem.SetObjState(obj: Obj, newState: string, attrs: { [string]: any }?)
	setState(obj, newState)
	if attrs then
		setAttrs(obj, attrs)
	end
end

-- Recolours the glow pieces (nil colour = keep it; transparency 1 = off).
function LootSystem.SetGlow(obj: Obj, color: Color3?, transparency: number?)
	recolourGlow(obj, color, transparency)
end

-- Makes enemy e a guard of obj (its death calls obj.OnGuardDown).
function LootSystem.AddGuard(obj: Obj, e)
	e.Guard = obj.Id
	obj.Guards[e] = e.Uid
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
