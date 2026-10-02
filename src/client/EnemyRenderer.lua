--[[
	EnemyRenderer.lua
	Puts a detailed, animated ModelLibrary model on every live enemy, on this client only.

	The server moves one plain Part per enemy ("Body", the hit body). Here we hide that
	part (LocalTransparencyModifier) and draw the model in its place, smoothing between
	network updates so movement looks fluid even at a low replication rate. All model
	pieces move with a single workspace:BulkMoveTo per frame.

	Detail budget (Config.Graphics.MaxDetailedEnemies, stepping down to MinDetailedEnemies
	while frames are slow): when more enemies are alive than the budget, the ones nearest
	the camera focus get the full model (ranked a few times a second) and the rest show
	their plain body, restyled locally in the creature's palette colour. The boss and
	elites are always detailed. Models are pooled per enemy type and go back to the pool
	when their enemy dies or drops out of the budget, so models exist only for detailed
	enemies (plus the pools) and a recycled body reuses parts instead of building new ones.
	Spawn dust puffs only for spawns on screen.

	Readability: Flash() gives a brief white hit flash (model or plain body); elites stand
	on a soft gold ground ring on top of their bigger, gold-tinted model with its crown,
	wear their affix aura (EliteAura_* meshes or a part ring: flames, orbiting shield
	plates that shatter when the shield breaks, wind streaks) and a small affix tag.

	Spawns climb out of the ground (short emerge + dust puff). The server's "Act" body
	attribute drives readable poses: Spitter wind-up (swells, rears back), Bomb Tick fuse
	(swells and blinks faster and faster), Rhino rear-up / lunge / recover, and the
	Queen's entrance (rises from the ground), crouch before a charge, dizzy stars when
	stunned, raised claws, glowing raised tail, the dive and burrow (hidden, a dust trail
	follows her), the roar and the collapse. The rotating bosses have their own poses:
	the Moth Matriarch flies down from the sky, gathers (wings shaking), lifts and swoops,
	lands grounded, rears for a gust; the Rhino Warlord rears and slams, sticks his horn in
	an obstacle (stars), plants his banner (hidden on his back while it stands: body
	attribute "BannerOut"); the Hive Mother heaves her egg sac and spews.
	Creatures: a tunnelling Burrower is only its soil ring with a dust trail (the "Mound"
	piece; hidden once it is out), a Healer glows and swells while it channels, a Nest
	throbs before mites climb out, a Brood Egg wobbles harder until it hatches. Beetles
	rallied by a War Banner (body attribute "Rallied") stand on a crimson ring. Nests, the
	War Banner and Brood Eggs show a small HP bar (body attribute "HPFrac").
	Floor telegraphs live in Telegraphs.lua.
]]

local RunService = game:GetService("RunService")

local Shared = game:GetService("ReplicatedStorage"):WaitForChild("Shared")
local Config = require(Shared:WaitForChild("Config"))
local EnemyData = require(Shared:WaitForChild("EnemyData"))
local Palette = require(Shared:WaitForChild("Palette"))
local ModelLibrary = require(script.Parent.ModelLibrary)
local Telegraphs = require(script.Parent.Telegraphs)
local Players = game:GetService("Players")

local EnemyRenderer = {}

type Slot = {
	Body: BasePart,
	Type: string?,
	Elite: boolean,
	Pieces: { any },
	Motion: string,
	Scale: number,
	Phase: number,
	Render: CFrame?,
	LastPos: Vector3?,
	Move: number,
	Parked: boolean,
	FlashUntil: number,
	Dist: number,
	Halo: BasePart?,
	-- behaviour poses / affixes (from body attributes)
	Act: string?,
	ActAt: number,
	Affix: string?,
	ShieldUp: boolean,
	Live: boolean,
	SpawnAt: number,
	Scaled: number,
	Blink: boolean,
	Speed: number,
	LastAt: number,
	Aura: { any }?,
	AuraAffix: string?,
	Tag: BillboardGui?,
	Extras: { BasePart }?,
	DustAt: number,
	ShieldBroke: number?,
	HPBar: BillboardGui?,
	RallyRing: BasePart?,
	BannerOut: boolean,
}

type PooledModel = { Pieces: { any }, Motion: string, Scale: number, Type: string, Elite: boolean }

local slots: { [number]: Slot } = {}
local PARK = CFrame.new(0, -150, 0)
local ACTIVE_Y = -100
local FLOOR_Y = Config.ArenaOrigin.Y
local DISC = CFrame.Angles(0, 0, math.rad(90)) -- cylinder axis X → Y (a flat disc)
local FLAT = Vector3.new(1, 0, 1)
local WHITE = Color3.new(1, 1, 1)
local RANK_EVERY = 0.3 -- seconds between nearest-first detail rankings
local POOL_CAP = 48 -- spare models kept per enemy type
local PROBE_EVERY = 4 -- seconds between checks whether a part-built type has its meshes now

local partsBuf: { BasePart } = {}
local cframesBuf: { CFrame } = {}
local clock = 0
local modelFolder: Instance? = nil

-- Plain bodies (over the detail budget) in the creature colours of the art direction.
local PLAIN: { [string]: Color3 } = {
	Slime = Palette.beetle_300,
	Bat = Palette.wasp_500,
	Skeleton = Palette.beetle_600,
	Ghost = Palette.moth_300,
	Brute = Palette.slate_400,
	Bomber = Palette.tick_500,
	Spitter = Palette.crimson_500:Lerp(Palette.slate_400, 0.5),
	Boss = Palette.crimson_500,
	MothBoss = Palette.moth_300,
	RhinoBoss = Palette.slate_600,
	HiveBoss = Palette.ivory_300,
	Burrower = Palette.sand_400,
	Healer = Palette.ivory_200,
	Nest = Palette.wood_500,
	WarBanner = Palette.crimson_500,
	BroodEgg = Palette.ivory_200,
}

-- Bosses (always detailed, their own entrance) and things that never get the plain body.
local function isBoss(typeId: string): boolean
	local def = EnemyData.Enemies[typeId]
	return def ~= nil and def.IsBoss == true
end
local function alwaysDetailed(typeId: string): boolean
	local def = EnemyData.Enemies[typeId]
	return def ~= nil and (def.IsBoss == true or def.Static == true or def.Support ~= nil)
end
local ELITE_GOLD = Palette.gold_400

------------------------------------------------------------------------------------------
-- Model pool (per enemy type + elite)
------------------------------------------------------------------------------------------

local modelPool: { [string]: { PooledModel } } = {}
-- keys whose uploaded meshes have loaded: their part-built fallbacks are no longer pooled
local meshSeen: { [string]: boolean } = {}
local probeTimer = PROBE_EVERY

local function modelKey(typeId: string, elite: boolean): string
	return elite and (typeId .. "*") or typeId
end

local function restoreColors(pieces: { any })
	for _, piece in ipairs(pieces) do
		piece.Part.Color = piece.Color
	end
end

local function isMesh(pieces: { any }): boolean
	return pieces[1] ~= nil and pieces[1].Part:IsA("MeshPart")
end

local function destroyPieces(pieces: { any })
	for _, piece in ipairs(pieces) do
		piece.Part:Destroy()
	end
end

-- Takes the slot's model away into the pool of its type (an enemy died, or it dropped out
-- of the detail budget): models live only on detailed enemies plus the pools, so a huge
-- swarm never keeps one parked model per enemy body. Part-built fallbacks are pooled too
-- until that type's meshes have loaded (then they are dropped and replaced by meshes).
local function releaseModel(slot: Slot)
	local pieces = slot.Pieces
	if #pieces == 0 then
		return
	end
	if slot.Scaled ~= 1 then
		for _, piece in ipairs(pieces) do
			if piece.BaseSize then
				piece.Part.Size = piece.BaseSize
			end
		end
		slot.Scaled = 1
	end
	if slot.Blink then
		restoreColors(pieces)
		slot.Blink = false
	end
	slot.Pieces = {}
	local key = slot.Type and modelKey(slot.Type, slot.Elite) or nil
	local list = key and modelPool[key] or nil
	if key and not list then
		list = {}
		modelPool[key] = list
	end
	if key and list and #list < POOL_CAP and (isMesh(pieces) or not meshSeen[key]) then
		if slot.FlashUntil > 0 then
			restoreColors(pieces)
		end
		for _, piece in ipairs(pieces) do
			piece.Part.CFrame = PARK
		end
		table.insert(list, { Pieces = pieces, Motion = slot.Motion, Scale = slot.Scale, Type = slot.Type :: string, Elite = slot.Elite })
	else
		destroyPieces(pieces)
	end
end

local function rebuild(slot: Slot, typeId: string, elite: boolean)
	releaseModel(slot)
	local key = modelKey(typeId, elite)
	local list = modelPool[key]
	local spare = list and table.remove(list)
	while spare and meshSeen[key] and not isMesh(spare.Pieces) do
		destroyPieces(spare.Pieces) -- a fallback left from before the meshes loaded
		spare = table.remove(list)
	end
	if spare then
		slot.Pieces, slot.Motion, slot.Scale = spare.Pieces, spare.Motion, spare.Scale
	else
		local pieces, motion, scale = ModelLibrary.Enemy(typeId, elite)
		slot.Pieces, slot.Motion, slot.Scale = pieces, motion, scale
		if isMesh(pieces) then
			meshSeen[key] = true
		end
	end
	slot.Type = typeId
	slot.Elite = elite
	slot.Render = nil
	slot.FlashUntil = 0
	slot.Phase = math.random() * math.pi * 2
	slot.Parked = false
end

-- Every few seconds: does a type whose pool holds part-built fallbacks have its meshes
-- now? One fresh build tells; if it is a mesh model the fallbacks go.
local function probeMeshes()
	for key, list in pairs(modelPool) do
		local last = list[#list]
		if not meshSeen[key] and last and not isMesh(last.Pieces) then
			local pieces, motion, scale = ModelLibrary.Enemy(last.Type, last.Elite)
			if isMesh(pieces) then
				meshSeen[key] = true
				for i = #list, 1, -1 do
					if not isMesh(list[i].Pieces) then
						destroyPieces(list[i].Pieces)
						table.remove(list, i)
					end
				end
				for _, piece in ipairs(pieces) do
					piece.Part.CFrame = PARK
				end
				table.insert(list, { Pieces = pieces, Motion = motion, Scale = scale, Type = last.Type, Elite = last.Elite })
			else
				destroyPieces(pieces)
			end
		end
	end
end

-- Hides the slot's model: back to the pool (dead, or over the detail budget).
local function park(slot: Slot)
	if slot.Parked and #slot.Pieces == 0 then
		return
	end
	slot.Parked = true
	slot.Render = nil
	releaseModel(slot)
end

------------------------------------------------------------------------------------------
-- Elite ground ring
------------------------------------------------------------------------------------------

local haloPool: { BasePart } = {}

local function takeHalo(): BasePart
	local p = table.remove(haloPool)
	if p then
		return p
	end
	local part = Instance.new("Part")
	part.Shape = Enum.PartType.Cylinder
	part.Anchored = true
	part.CanCollide = false
	part.CanQuery = false
	part.CanTouch = false
	part.CastShadow = false
	part.Material = Enum.Material.SmoothPlastic
	part.Color = ELITE_GOLD
	part.Transparency = 0.6
	part.CFrame = PARK
	part.Parent = modelFolder
	return part
end

local function dropHalo(slot: Slot)
	local halo = slot.Halo
	if halo then
		slot.Halo = nil
		halo.CFrame = PARK
		table.insert(haloPool, halo)
	end
end

------------------------------------------------------------------------------------------
-- Plain bodies
------------------------------------------------------------------------------------------

local function plainLook(slot: Slot, typeId: string, elite: boolean, now: number)
	local body = slot.Body
	if body.LocalTransparencyModifier ~= 0 then
		body.LocalTransparencyModifier = 0
	end
	if now < slot.FlashUntil then
		return -- white hit flash on the body
	end
	local color = PLAIN[typeId]
	if not color then
		-- unknown type: keep the server's colour (undo a finished hit flash)
		local base = body:GetAttribute("BaseColor")
		if typeof(base) == "Color3" and body.Color ~= base then
			body.Color = base
		end
		return
	end
	if elite then
		color = color:Lerp(ELITE_GOLD, 0.4)
	end
	-- the server restyles recycled bodies; re-apply the local look whenever it differs
	if body.Color ~= color then
		body.Color = color
	end
	if body.Material ~= Enum.Material.SmoothPlastic then
		body.Material = Enum.Material.SmoothPlastic
	end
end

------------------------------------------------------------------------------------------
-- Tracking
------------------------------------------------------------------------------------------

local function track(model: Instance)
	local id = tonumber(string.sub(model.Name, 2))
	if not id then
		return
	end
	local body = model:WaitForChild("Body", 10) :: BasePart?
	if not body then
		return
	end
	slots[id] = {
		Body = body,
		Type = nil,
		Elite = false,
		Pieces = {},
		Motion = "Walk",
		Scale = 1,
		Phase = 0,
		Render = nil,
		LastPos = nil,
		Move = 0,
		Parked = true,
		FlashUntil = 0,
		Dist = 0,
		Halo = nil,
		Act = nil,
		ActAt = 0,
		Affix = nil,
		ShieldUp = false,
		Live = false,
		SpawnAt = -10,
		Scaled = 1,
		Blink = false,
		Speed = 0,
		LastAt = 0,
		Aura = nil,
		AuraAffix = nil,
		Tag = nil,
		Extras = nil,
		DustAt = 0,
		HPBar = nil,
		RallyRing = nil,
		BannerOut = false,
	}
	local slot = slots[id]
	local function readAct()
		local a = body:GetAttribute("Act")
		slot.Act = type(a) == "string" and a or nil
		slot.ActAt = clock
	end
	local function readAffix()
		local a = body:GetAttribute("Affix")
		slot.Affix = type(a) == "string" and a or nil
	end
	local function readShield()
		local up = body:GetAttribute("Shield") == true
		if slot.ShieldUp and not up then
			slot.ShieldBroke = clock
		end
		slot.ShieldUp = up
	end
	body:GetAttributeChangedSignal("BannerOut"):Connect(function()
		slot.BannerOut = body:GetAttribute("BannerOut") == true
	end)
	body:GetAttributeChangedSignal("Act"):Connect(readAct)
	body:GetAttributeChangedSignal("Affix"):Connect(readAffix)
	body:GetAttributeChangedSignal("Shield"):Connect(readShield)
	readAct()
	readAffix()
	readShield()
end

-- White hit flash on enemy `id` (its model, or its plain body over the detail budget).
function EnemyRenderer.Flash(id: number): boolean
	local slot = slots[id]
	if not slot then
		return false -- not tracked yet: VFX flashes the body itself
	end
	local now = os.clock()
	if not slot.Parked and #slot.Pieces > 0 then
		if now >= slot.FlashUntil then
			for _, piece in ipairs(slot.Pieces) do
				piece.Part.Color = WHITE
			end
		end
	else
		local body = slot.Body
		if not body.Parent or body.CFrame.Y < ACTIVE_Y then
			return true
		end
		body.Color = WHITE
	end
	slot.FlashUntil = now + Config.Enemies.HitFlashSeconds
	return true
end

-- Where enemy `id` is drawn right now (body centre), or nil when it is not alive.
function EnemyRenderer.Position(id: number): Vector3?
	local slot = slots[id]
	if not slot then
		return nil
	end
	local body = slot.Body
	if not body.Parent or body.CFrame.Y < ACTIVE_Y then
		return nil
	end
	local render = slot.Render
	if render and not slot.Parked then
		return render.Position
	end
	return body.Position
end

------------------------------------------------------------------------------------------
-- Detail ranking: nearest to the camera focus first
------------------------------------------------------------------------------------------

local detailed: { [Slot]: boolean } = {}
local rankList: { Slot } = {}
local rankTimer = 0
local liveCount = 0 -- live enemies seen last frame (decides whether the budget applies)
-- Adaptive detail budget: between Config.Graphics.MinDetailedEnemies and MaxDetailedEnemies,
-- lowered while frames are slow (smoothed frame time over 1/40 s), raised again when fast.
local budget = Config.Graphics.MaxDetailedEnemies
local frameTime = 1 / 60
local budgetTimer = 1

local function adaptBudget(dt: number)
	frameTime += (math.min(dt, 0.2) - frameTime) * 0.05
	budgetTimer -= dt
	if budgetTimer > 0 then
		return
	end
	budgetTimer = 1
	local G = Config.Graphics
	if frameTime > 1 / 40 then
		budget = math.max(G.MinDetailedEnemies, budget - 10)
	elseif frameTime < 1 / 55 then
		budget = math.min(G.MaxDetailedEnemies, budget + 5)
	end
end

local function rank()
	local cam = workspace.CurrentCamera
	local focus = cam and cam.Focus.Position or Vector3.zero
	table.clear(rankList)
	for _, slot in pairs(slots) do
		local body = slot.Body
		if body.Parent and body.CFrame.Y >= ACTIVE_Y then
			slot.Dist = ((body.Position - focus) * FLAT).Magnitude
			table.insert(rankList, slot)
		end
	end
	table.sort(rankList, function(a, b)
		return a.Dist < b.Dist
	end)
	table.clear(detailed)
	local limit = budget
	for i, slot in ipairs(rankList) do
		if i > limit then
			break
		end
		detailed[slot] = true
	end
end

------------------------------------------------------------------------------------------
-- Behaviour poses (server "Act"), spawn emerge, elite auras and tags
------------------------------------------------------------------------------------------

local EMERGE = 0.35 -- seconds a fresh spawn takes to climb out of the ground
local BLINK = Color3.fromRGB(255, 244, 214)
local AFFIX_TAG: { [string]: { Text: string, Color: Color3 } } = {
	Burning = { Text = "BURNING", Color = Palette.fx_fire },
	Shielded = { Text = "SHIELDED", Color = Palette.slate_200 },
	Swift = { Text = "SWIFT", Color = Palette.ivory_100 },
}

local function tremble(a: number, t: number): CFrame
	return CFrame.new(math.sin(t * 61) * a, 0, math.cos(t * 53) * a)
end

--[[
	Extra transform (body space, applied after the motion) and scale for the slot's
	current behaviour. halfH = half the body height. Returns pose, scale, hidden.
]]
-- How long a type's fuse burns: EnemyData Fuse (0.7 s), elites at least
-- Config.Enemies.EliteFuse (like EnemyAI), so the swell and blink end with the blast.
local function fuseSeconds(typeId: string, elite: boolean): number
	local def = EnemyData.Enemies[typeId]
	local fuse = (def and tonumber(def.Fuse)) or 0.7
	if elite then
		fuse = math.max(fuse, tonumber((Config.Enemies :: any).EliteFuse) or fuse)
	end
	return math.max(0.1, fuse)
end

local function actPose(typeId: string, act: string?, t: number, halfH: number, fuse: number?): (CFrame, number, boolean)
	if not act then
		return CFrame.identity, 1, false
	end
	-- the rotating bosses and the new creatures first (their own act names)
	if typeId == "MothBoss" then
		if act == "Emerge" then
			-- flies down from high above
			local u = math.clamp(t / 2.5, 0, 1)
			local k = (1 - u) ^ 2
			return CFrame.new(0, k * 38, 0) * CFrame.Angles(-0.3 * k, 0, 0), 1, false
		elseif act == "Gather" then
			local u = math.clamp(t / 0.4, 0, 1)
			return CFrame.new(0, 1.2 * u, 0) * CFrame.Angles(0.12 * u, 0, 0) * tremble(0.1 * u, t), 1, false
		elseif act == "Lift" then
			local u = math.clamp(t / 0.6, 0, 1)
			return CFrame.new(0, 2.6 * u, 0.8 * u) * CFrame.Angles(0.3 * u, 0, 0) * tremble(0.06 * u, t), 1, false
		elseif act == "Swoop" then
			return CFrame.new(0, -1.6, 0) * CFrame.Angles(-0.38, 0, 0), 1, false
		elseif act == "Grounded" then
			local u = math.clamp(t / 0.3, 0, 1)
			return CFrame.new(0, -3.0 * u, 0) * CFrame.Angles(-0.1 * u, 0, math.sin(t * 2) * 0.05), 1, false
		elseif act == "GustWindup" then
			local u = math.clamp(t / 0.5, 0, 1)
			return CFrame.new(0, 1.4 * u, 1.0 * u) * CFrame.Angles(0.4 * u, 0, 0) * tremble(0.05 * u, t), 1, false
		elseif act == "Gust" then
			return CFrame.new(0, 0.6, -0.8) * CFrame.Angles(-0.3, 0, 0) * tremble(0.08, t), 1, false
		end
	elseif typeId == "RhinoBoss" then
		if act == "Rear" then
			local u = math.clamp(t / 0.5, 0, 1)
			return CFrame.new(0, 1.6 * u, 1.2 * u) * CFrame.Angles(0.5 * u, 0, 0) * tremble(0.08 * u, t), 1, false
		elseif act == "Pound" then
			local k = math.max(0, 1 - t / 0.5)
			return CFrame.new(0, -0.5 * k, 0) * CFrame.Angles(-0.14 * k, 0, 0) * tremble(0.25 * k, t), 1, false
		elseif act == "Stuck" then
			return CFrame.new(0, -0.6, -0.6) * CFrame.Angles(-0.32, 0, math.sin(t * 7) * 0.05) * tremble(0.05, t), 1, false
		elseif act == "Plant" then
			local u = math.clamp(t / 0.5, 0, 1)
			return CFrame.new(0, 0.6 * u, 0) * CFrame.Angles(0.18 * u, 0, 0.08 * math.sin(t * 6) * u), 1, false
		end
	elseif typeId == "HiveBoss" then
		if act == "Heave" then
			local u = math.clamp(t / 0.6, 0, 1)
			return CFrame.new(0, 0.5 * u, 0) * CFrame.Angles(-0.12 * u, 0, 0) * tremble(0.06 * u, t), 1 + 0.06 * u, false
		elseif act == "Spew" then
			local u = math.clamp(t / 0.4, 0, 1)
			return CFrame.new(0, -0.2 * u, -0.3 * u) * CFrame.Angles(-0.16 * u, 0, 0) * tremble(0.08 * u, t), 1, false
		end
	elseif typeId == "Burrower" then
		if act == "Tunnel" then
			return CFrame.identity, 1, false -- only the soil ring shows (hiddenGroup)
		elseif act == "Surface" then
			return tremble(0.12, t), 1, false
		elseif act == "Popped" then
			local k = math.max(0, 1 - t / 0.3)
			return CFrame.new(0, -k * 1.2, 0) * CFrame.Angles(0.3 * k, 0, 0), 1, false
		end
	elseif typeId == "Healer" then
		if act == "Channel" then
			local u = math.clamp(t / 0.6, 0, 1)
			return CFrame.new(0, 0.3 * u, 0) * CFrame.Angles(0.2 * u, 0, 0) * tremble(0.03 * u, t), 1 + 0.15 * u, false
		end
	elseif typeId == "Nest" then
		if act == "Pulse" then
			return tremble(0.04, t), 1 + 0.05 * math.abs(math.sin(t * 9)), false
		end
	elseif typeId == "BroodEgg" then
		if act == "Incubate" then
			local u = math.clamp(t / 3.5, 0, 1)
			local amp = 0.04 + 0.22 * u * u
			return CFrame.Angles(math.sin(t * (8 + 16 * u)) * amp, 0, math.cos(t * (7 + 14 * u)) * amp), 1 + 0.08 * u, false
		end
	end
	local boss = isBoss(typeId)
	if act == "Windup" then
		if typeId == "Spitter" then
			local u = math.clamp(t / 0.7, 0, 1)
			return CFrame.Angles(0.28 * u, 0, 0) * tremble(0.05 * u, t), 1 + 0.24 * u, false
		elseif boss then
			local u = math.clamp(t / 0.4, 0, 1)
			return CFrame.new(0, -0.7 * u, 0.6 * u) * CFrame.Angles(-0.08 * u, 0, 0) * tremble(0.12 * u, t), 1, false
		end
		local u = math.clamp(t / 0.35, 0, 1) -- Rhino: rears up and trembles
		return CFrame.new(0, 0.3 * u, 0.3 * u) * CFrame.Angles(0.32 * u, 0, 0) * tremble(0.06 * u, t), 1, false
	elseif act == "Fuse" then
		local u = math.clamp(t / (fuse or 0.7), 0, 1)
		return tremble(0.04 + 0.1 * u, t), 1 + 0.38 * u, false
	elseif act == "Lunge" or act == "Charge" then
		return CFrame.Angles(-0.16, 0, 0), 1, false
	elseif act == "Recover" then
		return CFrame.new(0, -0.15, 0) * CFrame.Angles(-0.06, 0, 0), 1, false
	elseif act == "Emerge" then
		local u = math.clamp(t / 2.5, 0, 1)
		local k = (1 - u) ^ 1.6
		return CFrame.new(0, -k * halfH * 2.3, 0) * CFrame.Angles(0.25 * k, 0, 0) * tremble(0.18 * (1 - u), t), 1, false
	elseif act == "Stunned" then
		return CFrame.new(0, -0.35, 0) * CFrame.Angles(0, math.sin(t * 2.4) * 0.12, math.sin(t * 5) * 0.08), 1, false
	elseif act == "Claws" then
		local u = math.clamp(t / 0.3, 0, 1)
		return CFrame.new(0, 0.35 * u, 0) * CFrame.Angles(0.16 * u, 0, 0), 1, false
	elseif act == "TailRaise" then
		local u = math.clamp(t / 0.4, 0, 1)
		return CFrame.new(0, 0.3 * u, 0) * CFrame.Angles(-0.1 * u, 0, 0) * tremble(0.05 * u, t), 1, false
	elseif act == "Dive" then
		local u = math.clamp(t / 0.7, 0, 1)
		return CFrame.new(0, -u * u * halfH * 2.2, 0) * tremble(0.15, t), 1, false
	elseif act == "Burrow" then
		return CFrame.identity, 1, true
	elseif act == "Summon" then
		return CFrame.new(0, 0.2, 0) * CFrame.Angles(0.1, 0, 0) * tremble(0.03, t), 1, false
	elseif act == "Roar" then
		local u = math.sin(math.clamp(t / 0.35, 0, 1) * math.pi / 2)
		return CFrame.new(0, 0.6 * u, 0) * CFrame.Angles(0.3 * u, 0, 0) * tremble(0.1, t), 1, false
	elseif act == "Collapse" then
		local u = math.clamp(t / 1.5, 0, 1)
		return CFrame.new(0, -u * u * halfH * 0.9, 0) * CFrame.Angles(-0.12 * u, 0, 0.38 * u) * tremble(0.08 * (1 - u), t), 1, false
	end
	return CFrame.identity, 1, false
end

-- Pieces a pose hides: a tunnelling Burrower shows only its soil ring (and loses it once
-- it is out); the Warlord's banner leaves his back while it is planted.
local MOUND = ModelLibrary.PieceGroups.Mound
local BANNER = ModelLibrary.PieceGroups.Banner
local function pieceHidden(typeId: string, slot: Slot, name: string): boolean
	if typeId == "Burrower" then
		local under = slot.Act == "Tunnel" or slot.Act == "Surface"
		return (MOUND[name] == true) ~= under
	elseif typeId == "RhinoBoss" then
		return slot.BannerOut and BANNER[name] == true
	end
	return false
end

local function extraPart(shape: Enum.PartType, size: Vector3, color: Color3, material: Enum.Material): BasePart
	local p = Instance.new("Part")
	p.Shape = shape
	p.Anchored = true
	p.CanCollide = false
	p.CanQuery = false
	p.CanTouch = false
	p.CastShadow = false
	p.Size = size
	p.Color = color
	p.Material = material
	p.CFrame = PARK
	p.Parent = modelFolder
	return p
end

-- Boss extras: three dizzy stars and the tail glow (created once, parked when unused).
local function bossExtras(slot: Slot): { BasePart }
	local list = slot.Extras
	if not list then
		list = {}
		for k = 1, 3 do
			list[k] = extraPart(Enum.PartType.Ball, Vector3.one * 0.7, Palette.gold_300, Enum.Material.Neon)
		end
		list[4] = extraPart(Enum.PartType.Ball, Vector3.one * 1.6, Palette.amber_300, Enum.Material.Neon)
		slot.Extras = list
	end
	return list
end

local function parkExtras(slot: Slot)
	if slot.Extras then
		for _, p in ipairs(slot.Extras) do
			if p.CFrame.Y > ACTIVE_Y then
				p.CFrame = PARK
			end
		end
	end
end

-- Small HP bar over nests, the War Banner and Brood Eggs (body attribute "HPFrac").
local function ensureHPBar(slot: Slot): BillboardGui
	local gui = slot.HPBar
	if gui then
		return gui
	end
	local g = Instance.new("BillboardGui")
	g.Name = "HPBar"
	g.Size = UDim2.fromOffset(64, 9)
	g.LightInfluence = 0
	g.MaxDistance = 260
	g.AlwaysOnTop = false
	local back = Instance.new("Frame")
	back.Name = "Back"
	back.BackgroundColor3 = Palette.slate_950
	back.BackgroundTransparency = 0.15
	back.BorderSizePixel = 0
	back.Size = UDim2.fromScale(1, 1)
	back.Parent = g
	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, 3)
	corner.Parent = back
	local fill = Instance.new("Frame")
	fill.Name = "Fill"
	fill.BackgroundColor3 = Palette.crimson_400
	fill.BorderSizePixel = 0
	fill.Position = UDim2.fromOffset(1, 1)
	fill.Size = UDim2.new(1, -2, 1, -2)
	fill.Parent = back
	local c2 = Instance.new("UICorner")
	c2.CornerRadius = UDim.new(0, 2)
	c2.Parent = fill
	local player = Players.LocalPlayer
	local pg = player and player:FindFirstChildOfClass("PlayerGui")
	g.Parent = pg or modelFolder
	slot.HPBar = g
	return g
end

local function hideHPBar(slot: Slot)
	if slot.HPBar then
		slot.HPBar.Enabled = false
	end
end

local function dropAura(slot: Slot)
	local aura = slot.Aura
	if aura then
		for _, piece in ipairs(aura) do
			piece.Part:Destroy()
		end
		slot.Aura = nil
		slot.AuraAffix = nil
	end
	if slot.Tag then
		slot.Tag.Enabled = false
	end
end

local function ensureAura(slot: Slot, affix: string)
	local meshName = ModelLibrary.AuraMeshName(affix)
	local upgrade = slot.Aura ~= nil and meshName ~= nil and ModelLibrary.MeshFolder(meshName) ~= nil and not slot.Aura[1].Part:IsA("MeshPart")
	if slot.AuraAffix ~= affix or upgrade then
		dropAura(slot)
		local size = slot.Body.Size
		slot.Aura = ModelLibrary.Aura(affix, math.max(size.X, size.Z) / 2, size.Y / 2)
		slot.AuraAffix = affix
	end
	local tag = slot.Tag
	if not tag then
		local gui = Instance.new("BillboardGui")
		gui.Name = "AffixTag"
		gui.Size = UDim2.fromOffset(96, 18)
		gui.LightInfluence = 0
		gui.MaxDistance = 220
		local label = Instance.new("TextLabel")
		label.BackgroundTransparency = 1
		label.Size = UDim2.fromScale(1, 1)
		label.Font = Enum.Font.SourceSansBold
		label.TextSize = 11
		label.TextStrokeTransparency = 0.35
		label.TextStrokeColor3 = Palette.slate_950
		label.TextTransparency = 0.2
		label.Parent = gui
		local player = Players.LocalPlayer
		local pg = player and player:FindFirstChildOfClass("PlayerGui")
		gui.Parent = pg or modelFolder
		tag = gui
		slot.Tag = gui
	end
	local info = AFFIX_TAG[affix]
	local label = tag:FindFirstChildOfClass("TextLabel")
	if label and info and label.Text ~= info.Text then
		label.Text = info.Text
		label.TextColor3 = info.Color
	end
	tag.Adornee = slot.Body
	tag.StudsOffsetWorldSpace = Vector3.new(0, slot.Body.Size.Y / 2 + 3.4, 0)
	tag.Enabled = true
end

------------------------------------------------------------------------------------------
-- Frame
------------------------------------------------------------------------------------------

local function step(dt: number)
	clock += dt
	local now = os.clock()
	local alpha = 1 - math.exp(-dt * 18)
	table.clear(partsBuf)
	table.clear(cframesBuf)
	local n = 0

	-- the budget only matters when more enemies are alive than it allows (last frame's
	-- count: one loop over the bodies instead of two)
	adaptBudget(dt)
	local budgeted = liveCount > budget
	rankTimer -= dt
	if budgeted and rankTimer <= 0 then
		rankTimer = RANK_EVERY
		rank()
	end
	probeTimer -= dt
	if probeTimer <= 0 then
		probeTimer = PROBE_EVERY
		probeMeshes()
	end
	local cam = workspace.CurrentCamera
	local live = 0

	for _, slot in pairs(slots) do
		local body = slot.Body
		local cf = body.CFrame
		local typeId = cf.Y >= ACTIVE_Y and body.Parent and body:GetAttribute("Type") or nil
		if typeof(typeId) ~= "string" then
			-- pooled on the server (parked): nothing to draw; tidy up once
			if slot.Live or not slot.Parked or slot.Halo then
				park(slot)
				dropHalo(slot)
			end
			if slot.Live then
				slot.Live = false
				dropAura(slot)
				parkExtras(slot)
				hideHPBar(slot)
				if slot.RallyRing then
					slot.RallyRing.CFrame = PARK
				end
			end
		else
			live += 1
			if not slot.Live then
				-- a fresh spawn: it climbs out of the ground (the Queen has her own entrance);
				-- the dust puff only where it can be seen (most spawns are off-screen)
				slot.Live = true
				slot.SpawnAt = clock
				slot.Speed = 0
				slot.LastPos = nil
				if not isBoss(typeId) and typeId ~= "Burrower" then
					local _, onScreen = (cam :: Camera):WorldToViewportPoint(cf.Position)
					if onScreen then
						local r = math.max(body.Size.X, body.Size.Z) / 2
						Telegraphs.Puff(cf.Position.X, cf.Position.Z, r)
					end
				end
			end
			local elite = body:GetAttribute("Elite") == true
			if budgeted and not detailed[slot] and not alwaysDetailed(typeId) and not elite then
				-- over the detail budget: the plain server body in the creature's colour
				park(slot)
				dropHalo(slot)
				plainLook(slot, typeId, elite, now)
			else
				if slot.Type ~= typeId or slot.Elite ~= elite or #slot.Pieces == 0 then
					rebuild(slot, typeId, elite)
				end
				if body.LocalTransparencyModifier ~= 1 then
					body.LocalTransparencyModifier = 1
				end
				slot.Parked = false

				-- smooth toward the server position; snap on big jumps (spawn, recycle)
				local render = slot.Render
				if not render or (render.Position - cf.Position).Magnitude > 12 then
					render = cf
				else
					render = render:Lerp(cf, alpha)
				end
				slot.Render = render

				-- walk speed from the body's movement, measured between position updates (the
				-- server moves far bodies every few frames and replication is not per frame)
				local pos = cf.Position
				local last = slot.LastPos
				if last ~= pos then
					if last then
						slot.Speed = ((pos - last) * FLAT).Magnitude / math.max(clock - slot.LastAt, 1e-3)
					end
					slot.LastPos = pos
					slot.LastAt = clock
				elseif clock - slot.LastAt > 0.25 then
					slot.Speed = 0 -- no update for a while: standing still
				end
				slot.Move += (math.clamp(slot.Speed / 10, 0, 1) - slot.Move) * math.min(1, dt * 6)

				if slot.FlashUntil > 0 and now >= slot.FlashUntil then
					slot.FlashUntil = 0
					restoreColors(slot.Pieces)
				end

				local halfH = body.Size.Y / 2
				local actT = clock - slot.ActAt
				local fuse = slot.Act == "Fuse" and fuseSeconds(typeId, slot.Elite == true) or nil
				local pose, scale, hidden = actPose(typeId, slot.Act, actT, halfH, fuse)
				local sinceSpawn = clock - slot.SpawnAt
				if sinceSpawn < EMERGE and not isBoss(typeId) and typeId ~= "Burrower" then
					local k = 1 - sinceSpawn / EMERGE
					pose = CFrame.new(0, -k * k * halfH * 2, 0) * pose
				end
				-- swelling (Spitter wind-up, Bomb Tick fuse): pieces grow around the body
				-- centre, lifted so the feet stay on the ground
				if scale ~= slot.Scaled then
					for _, piece in ipairs(slot.Pieces) do
						local base = piece.BaseSize or piece.Part.Size
						piece.BaseSize = base
						piece.Part.Size = base * scale
					end
					slot.Scaled = scale
				end
				-- Bomb Tick fuse: blinks faster and faster
				local blinkOn = false
				if slot.Act == "Fuse" then
					local hz = 4 + 14 * math.clamp(actT / (fuse or 0.7), 0, 1)
					blinkOn = math.sin(actT * hz * math.pi * 2) > 0.2
				end
				if blinkOn ~= slot.Blink and now >= slot.FlashUntil then
					slot.Blink = blinkOn
					if blinkOn then
						for _, piece in ipairs(slot.Pieces) do
							piece.Part.Color = piece.Color:Lerp(BLINK, 0.7)
						end
					else
						restoreColors(slot.Pieces)
					end
				end

				local bodyCF = render * CFrame.new(0, (scale - 1) * halfH, 0) * ModelLibrary.Motion(slot.Motion, clock, slot.Phase, slot.Move, slot.Scale) * pose
				if hidden then
					bodyCF = CFrame.new(render.Position.X, -60, render.Position.Z) -- underground
				end
				local filtered = typeId == "Burrower" or typeId == "RhinoBoss"
				for _, piece in ipairs(slot.Pieces) do
					n += 1
					partsBuf[n] = piece.Part
					if filtered and pieceHidden(typeId, slot, piece.Part.Name) then
						cframesBuf[n] = PARK
					else
						cframesBuf[n] = scale == 1 and ModelLibrary.PieceCFrame(bodyCF, piece, clock, slot.Phase, slot.Move)
							or ModelLibrary.PieceCFrameScaled(bodyCF, piece, clock, slot.Phase, slot.Move, scale)
					end
				end

				-- a tunnelling Burrower leaves a dust trail
				if typeId == "Burrower" and slot.Act == "Tunnel" and clock >= slot.DustAt then
					slot.DustAt = clock + 0.09
					local p = render.Position
					Telegraphs.Dust(p.X + (math.random() - 0.5) * 1.5, p.Z + (math.random() - 0.5) * 1.5, 1.5)
				end

				-- bosses: the Queen's dust trail while she burrows, dizzy stars (stunned,
				-- stuck, grounded), the Queen's glowing raised tail
				if isBoss(typeId) then
					local act = slot.Act
					if typeId == "Boss" and (act == "Burrow" or act == "Dive") and clock >= slot.DustAt then
						slot.DustAt = clock + (act == "Burrow" and 0.06 or 0.12)
						local p = render.Position
						Telegraphs.Dust(p.X + (math.random() - 0.5) * 3, p.Z + (math.random() - 0.5) * 3, 2.6)
					end
					local extras = bossExtras(slot)
					if act == "Stunned" or act == "Stuck" or act == "Grounded" then
						local top = render.Position + Vector3.new(0, halfH + 1.6, 0)
						for k = 1, 3 do
							local a = clock * 3.2 + k * math.pi * 2 / 3
							n += 1
							partsBuf[n] = extras[k]
							cframesBuf[n] = CFrame.new(top + Vector3.new(math.cos(a) * 2.6, math.sin(clock * 4 + k) * 0.3, math.sin(a) * 2.6)) * CFrame.Angles(0, a, 0)
						end
					else
						for k = 1, 3 do
							if extras[k].CFrame.Y > ACTIVE_Y then
								extras[k].CFrame = PARK
							end
						end
					end
					if act == "TailRaise" and typeId == "Boss" then
						local g = extras[4]
						local u = math.clamp(actT / 0.9, 0, 1)
						g.Size = Vector3.one * (1.2 + 1.4 * u + 0.3 * math.sin(clock * 18))
						g.Transparency = 0.45 - 0.3 * u
						n += 1
						partsBuf[n] = g
						cframesBuf[n] = bodyCF * CFrame.new(0, halfH * 0.82, 2.0)
					elseif extras[4].CFrame.Y > ACTIVE_Y then
						extras[4].CFrame = PARK
					end
				end

				-- elite affix: aura (hidden once a shield broke) and the small tag
				local affix = slot.Affix
				if elite and affix then
					ensureAura(slot, affix)
					local showAura = not (affix == "Shielded" and not slot.ShieldUp) and not hidden
					local auraCF = CFrame.new(render.Position) * CFrame.new(0, (sinceSpawn < EMERGE) and -(1 - sinceSpawn / EMERGE) * halfH * 2 or 0, 0)
					for _, piece in ipairs(slot.Aura :: { any }) do
						n += 1
						partsBuf[n] = piece.Part
						cframesBuf[n] = showAura and ModelLibrary.PieceCFrame(auraCF, piece, clock, slot.Phase, 1) or PARK
					end
				elseif slot.Aura or (slot.Tag and slot.Tag.Enabled) then
					dropAura(slot)
				end

				-- elites: soft gold ring on the ground under them
				if elite then
					local halo = slot.Halo
					if not halo then
						halo = takeHalo()
						slot.Halo = halo
						local d = math.max(body.Size.X, body.Size.Z) * 1.3 + 1.2
						halo.Size = Vector3.new(0.06, d, d)
					end
					halo.Transparency = 0.62 + 0.08 * math.sin(clock * 3 + slot.Phase)
					n += 1
					partsBuf[n] = halo
					local p = render.Position
					cframesBuf[n] = CFrame.new(p.X, FLOOR_Y + 0.34, p.Z) * DISC -- over the paths, under telegraphs
				elseif slot.Halo then
					dropHalo(slot)
				end

				-- a War Banner's rally: a crimson ring under the rallied beetle (and a
				-- bigger one at the banner's foot, so the target is easy to spot)
				local banner = typeId == "WarBanner"
				if banner or body:GetAttribute("Rallied") == true then
					local ring = slot.RallyRing
					if not ring then
						ring = extraPart(Enum.PartType.Cylinder, Vector3.one, Palette.crimson_400, Enum.Material.SmoothPlastic)
						slot.RallyRing = ring
					end
					local d = banner and 7 or math.max(body.Size.X, body.Size.Z) * 1.2 + 1
					ring.Size = Vector3.new(0.05, d, d)
					ring.Color = banner and Palette.gold_400 or Palette.crimson_400
					ring.Transparency = (banner and 0.3 or 0.45) + 0.15 * math.sin(clock * 6 + slot.Phase)
					n += 1
					partsBuf[n] = ring
					local p = render.Position
					cframesBuf[n] = CFrame.new(p.X, FLOOR_Y + 0.345, p.Z) * DISC
				elseif slot.RallyRing and slot.RallyRing.CFrame.Y > ACTIVE_Y then
					slot.RallyRing.CFrame = PARK
				end

				-- small HP bar (nests, the War Banner, Brood Eggs)
				local frac = body:GetAttribute("HPFrac")
				if type(frac) == "number" then
					local bar = ensureHPBar(slot)
					bar.Adornee = body
					bar.StudsOffsetWorldSpace = Vector3.new(0, (slot.Type == "WarBanner" and 8.5 or halfH + 2.2), 0)
					local fill = (bar :: any).Back.Fill :: Frame
					fill.Size = UDim2.new(math.clamp(frac, 0, 1), -2, 1, -2)
					bar.Enabled = not hidden
				elseif slot.HPBar and slot.HPBar.Enabled then
					hideHPBar(slot)
				end
			end
		end
	end
	liveCount = live
	if n > 0 then
		workspace:BulkMoveTo(partsBuf, cframesBuf, Enum.BulkMoveMode.FireCFrameChanged)
	end
end

function EnemyRenderer.Init()
	local folder = Instance.new("Folder")
	folder.Name = "SwarmEnemyModels"
	folder.Parent = workspace
	modelFolder = folder
	ModelLibrary.SetFolder(folder)
	Telegraphs.Init() -- the floor warnings (started here so ClientMain stays unchanged)
	task.spawn(function()
		local enemies = workspace:WaitForChild("SwarmEnemies")
		enemies.ChildAdded:Connect(function(m)
			task.spawn(track, m)
		end)
		for _, m in ipairs(enemies:GetChildren()) do
			task.spawn(track, m)
		end
	end)
	RunService.RenderStepped:Connect(step)
end

return EnemyRenderer
