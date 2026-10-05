--[[
	EnemyRenderer.lua
	Puts a detailed, animated ModelLibrary model on every live enemy, on this client only.

	The server moves one plain Part per enemy ("Body", the hit body). Here we hide that
	part (LocalTransparencyModifier) and draw the model in its place, smoothing between
	network updates so movement looks fluid even at a low replication rate. All model
	pieces move with a single workspace:BulkMoveTo per frame.

	Level of detail (no enemy ever shows its plain server body; that "blob" look is gone):
	  * Screen culling: an enemy outside the camera view (plus Config.Graphics.CullMargin
	    studs, a little more before it leaves, so edge walkers do not flicker) has no model
	    and costs no CFrame updates; its hidden body is all there is, and nobody sees it.
	  * Detail budget among ON-SCREEN enemies only (Config.Graphics.MaxDetailedEnemies,
	    stepping down to MinDetailedEnemies while frames are slow): the nearest get the full
	    animated model (ranked a few times a second); the rest get the low-detail variant:
	    the same model cut to its LowDetailParts largest pieces (mirrored pairs kept whole)
	    in their own colours, posed rigidly (no leg / wing animation, no bob, no shadow).
	  * Update rate: when many enemies are on screen, only the FullRateEnemies nearest
	    update every frame; the others (and every low-detail model) every 2nd frame,
	    staggered so each frame moves half of them.
	Elites, static / support creatures and Burrowers are never low-detail (but culled off
	screen and half-rate past the nearest like the rest); a boss is never culled (its
	entrance starts in the sky) and always updates every frame. Models (full and low) are pooled per enemy
	type and go back to the pool when their enemy dies, leaves the screen or changes tier,
	so models exist only for drawn enemies (plus the pools) and a recycled body reuses
	parts instead of building new ones. Spawn dust puffs only for spawns on screen.

	Readability: Flash() gives a brief warm hit flash that keeps dark contours (full or
	low-detail model); elites stand on a crimson-rimmed dark ground ring (hostile, unlike the
	hero's pale-gold ring) under their bigger, gold-tinted model with its crown,
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
	attribute "BannerOut"); the Hive Mother heaves her egg sac and spews; the Briar Sentinel
	sinks her arms into the soil (root lines, bramble ring), stays rooted while they erupt
	and leans back to fling thorns; the Frostbound Colossus raises both fists and slams,
	stomps (ice lanes), inhales and breathes, calls the shard rain, and wears ice plates
	while his frost armour is on (body attribute "FrostArmor").
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
local ClientSettings = require(script.Parent.ClientSettings)
local Accessibility = require(script.Parent.Accessibility)
local Players = game:GetService("Players")

local EnemyRenderer = {}
-- WorldFx (fog): (position, shownLastFrame) -> true = keep this normal enemy hidden.
-- Bosses, elites and the always-detailed creatures are never passed to it.
EnemyRenderer.HideFilter = nil :: ((Vector3, boolean) -> boolean)?

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
	FlashNext: number, -- a boss re-flashes no sooner than this (no strobing under constant hits)
	Dist: number,
	Halo: BasePart?,
	HaloCore: BasePart?,
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
	FrostArmor: boolean,
	-- level of detail
	Low: boolean, -- the model in Pieces is the low-detail variant
	OnScreen: boolean, -- in the camera view (with the cull margin) last frame
	Stagger: number, -- 0 / 1: which frame of two a half-rate slot updates on
	StepAt: number, -- clock of the last pose update (half-rate slots skip frames)
}

type PooledModel = { Pieces: { any }, Motion: string, Scale: number, Type: string, Elite: boolean, Low: boolean }

local slots: { [number]: Slot } = {}
local PARK = CFrame.new(0, -150, 0)
local ACTIVE_Y = -100
local FLOOR_Y = Config.ArenaOrigin.Y
local DISC = CFrame.Angles(0, 0, math.rad(90)) -- cylinder axis X → Y (a flat disc)
local FLAT = Vector3.new(1, 0, 1)
local RANK_EVERY = 0.3 -- seconds between nearest-first detail rankings
local G = Config.Graphics
local LOW_PARTS: number = G.LowDetailParts or 4
local CULL_MARGIN: number = G.CullMargin or 8
local CULL_LEAVE = CULL_MARGIN + 6 -- an on-screen enemy is culled only this far outside
local FULL_RATE: number = G.FullRateEnemies or 50
-- Spare models kept per enemy type / in all while a run is on (a swarm of one type churns
-- through the detail budget, so a type may pool a full budget's worth; low-detail
-- variants up to the live cap) and the reserve kept per type once the run is over (the
-- rest is destroyed a few models per frame).
local POOL_CAP: number = G.MaxDetailedEnemies
local LOW_POOL_CAP: number = Config.Enemies.MaxLive
local POOL_TOTAL: number = math.floor(G.MaxDetailedEnemies * 1.5) + LOW_POOL_CAP
local POOL_KEEP = 12
local HALO_KEEP = 12 -- two discs per elite (rim + core)
local PROBE_EVERY = 4 -- seconds between checks whether a part-built type has its meshes now

local partsBuf: { BasePart } = {}
local cframesBuf: { CFrame } = {}
local clock = 0
local modelFolder: Instance? = nil
local localPlayer = Players.LocalPlayer
local trimming = false -- shedding pooled models after a run (see trimPools)

-- Bosses (their own entrance) and the creatures that are never culled nor low-detail:
-- static / support ones and the Burrower (its soil ring is a piece the cut would drop).
local function isBoss(typeId: string): boolean
	local def = EnemyData.Enemies[typeId]
	return def ~= nil and def.IsBoss == true
end
local function alwaysDetailed(typeId: string): boolean
	local def = EnemyData.Enemies[typeId]
	return def ~= nil and (def.IsBoss == true or def.Static == true or def.Support ~= nil or typeId == "Burrower")
end
local ELITE_GOLD = Palette.gold_400

------------------------------------------------------------------------------------------
-- Model pool (per enemy type + elite)
------------------------------------------------------------------------------------------

local modelPool: { [string]: { PooledModel } } = {}
local pooledTotal = 0 -- models in every pool together
-- keys whose uploaded meshes have loaded: their part-built fallbacks are no longer pooled
local meshSeen: { [string]: boolean } = {}
local probeTimer = PROBE_EVERY

local function modelKey(typeId: string, elite: boolean, low: boolean): string
	return (elite and (typeId .. "*") or typeId) .. (low and "~" or "")
end

--[[
	The low-detail variant of a model (in place): keeps its LOW_PARTS largest pieces by
	volume, a mirrored pair (WingL / WingR, LegsL / LegsR ...) counted as one unit that
	is kept whole or not at all, so the silhouette stays symmetric. The kept pieces lose
	their animation (posed rigidly) and their shadow; the rest are destroyed (this runs
	only when a pool is empty, never per frame).
]]
local function cutToLow(pieces: { any }): { any }
	local units: { { Pieces: { any }, Volume: number } } = {}
	local byKey: { [string]: { Pieces: { any }, Volume: number } } = {}
	local bands: { [string]: boolean } = {}
	for _, piece in ipairs(pieces) do
		local band = string.match(piece.Part.Name, "^(.+)Side$")
		if band then
			bands[band] = true
		end
	end
	for _, piece in ipairs(pieces) do
		local name = piece.Part.Name
		local stem, digits = string.match(name, "^(.-)[LR](%d*)$")
		-- a "<Name>Side" piece is the darker lower band of <Name> (the Mite's ShellSide):
		-- kept or dropped together with it, so far mites keep their two-tone shell
		local band = string.match(name, "^(.+)Side$")
		if band then
			stem, digits = band, ""
		elseif bands[name] then
			stem, digits = name, "" -- the piece a band joins
		end
		local size = piece.Part.Size
		local volume = size.X * size.Y * size.Z
		local key = (stem and stem ~= "") and (stem .. "|" .. digits) or nil
		local unit = key and byKey[key]
		if unit then
			table.insert(unit.Pieces, piece)
			unit.Volume += volume
		else
			unit = { Pieces = { piece }, Volume = volume }
			table.insert(units, unit)
			if key then
				byKey[key] = unit
			end
		end
	end
	table.sort(units, function(a, b)
		return a.Volume > b.Volume
	end)
	local keep: { any } = {}
	for _, unit in ipairs(units) do
		if #keep + #unit.Pieces <= LOW_PARTS then
			for _, piece in ipairs(unit.Pieces) do
				table.insert(keep, piece)
			end
		else
			for _, piece in ipairs(unit.Pieces) do
				piece.Part:Destroy()
			end
		end
	end
	for _, piece in ipairs(keep) do
		piece.Anim = nil
		piece.Part.CastShadow = false
	end
	return keep
end

-- Snow contrast (audit S-18): the pale Phase Moth and the pale Healer aphid almost vanish
-- on the grey-white Snow ground. On the Snow arena only, their pale pieces are drawn a few
-- shades darker (same hue, a little more colour): a slate moth, a sage aphid. Other
-- arenas, other enemies and dark pieces (eyes, stripes, contours) are unchanged.
local SnowContrast = {
	Types = { Ghost = true, Healer = true },
	On = false, -- SwarmState Arena == "Snow"
	PALE = 0.62, -- pieces brighter than this (0-1 luminance) are darkened
	VALUE = 0.5, -- their brightness is capped here
}

function SnowContrast.color(c: Color3): Color3
	local h, sat, v = c:ToHSV()
	return Color3.fromHSV(h, math.min(1, sat * 1.6 + 0.08), math.min(v, SnowContrast.VALUE))
end

-- Records each pale piece's snow colour on a fresh Ghost / Healer model.
function SnowContrast.mark(typeId: string, pieces: { any })
	if not SnowContrast.Types[typeId] then
		return
	end
	for _, piece in ipairs(pieces) do
		local c = piece.Color
		if typeof(c) == "Color3" and 0.299 * c.R + 0.587 * c.G + 0.114 * c.B > SnowContrast.PALE then
			piece.SnowColor = SnowContrast.color(c)
		end
	end
end

-- The colour a piece is normally drawn in (before accessibility and flashes).
function SnowContrast.base(piece: any): Color3
	return (SnowContrast.On and piece.SnowColor) or piece.Color
end

local function buildModel(typeId: string, elite: boolean, low: boolean): ({ any }, string, number)
	local pieces, motion, scale = ModelLibrary.Enemy(typeId, elite)
	if low then
		pieces = cutToLow(pieces)
	end
	SnowContrast.mark(typeId, pieces)
	return pieces, motion, scale
end

local flashColors: (slot: any) -> ()
local function restoreColors(pieces: { any })
	for _, piece in ipairs(pieces) do
		piece.Part.Color = Accessibility.Color(SnowContrast.base(piece))
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
	local key = slot.Type and modelKey(slot.Type, slot.Elite, slot.Low) or nil
	local list = key and modelPool[key] or nil
	if key and not list then
		list = {}
		modelPool[key] = list
	end
	if key and list and #list < (slot.Low and LOW_POOL_CAP or POOL_CAP) and pooledTotal < POOL_TOTAL and (isMesh(pieces) or not meshSeen[key]) then
		if slot.FlashUntil > 0 then
			restoreColors(pieces)
		end
		for _, piece in ipairs(pieces) do
			piece.Part.CFrame = PARK
		end
		table.insert(list, { Pieces = pieces, Motion = slot.Motion, Scale = slot.Scale, Type = slot.Type :: string, Elite = slot.Elite, Low = slot.Low })
		pooledTotal += 1
	else
		destroyPieces(pieces)
	end
end

local function rebuild(slot: Slot, typeId: string, elite: boolean, low: boolean)
	releaseModel(slot)
	local key = modelKey(typeId, elite, low)
	local list = modelPool[key]
	local spare = list and table.remove(list)
	if spare then
		pooledTotal -= 1
	end
	while spare and meshSeen[key] and not isMesh(spare.Pieces) do
		destroyPieces(spare.Pieces) -- a fallback left from before the meshes loaded
		spare = table.remove(list)
		if spare then
			pooledTotal -= 1
		end
	end
	if spare then
		slot.Pieces, slot.Motion, slot.Scale = spare.Pieces, spare.Motion, spare.Scale
	else
		local pieces, motion, scale = buildModel(typeId, elite, low)
		slot.Pieces, slot.Motion, slot.Scale = pieces, motion, scale
		if isMesh(pieces) then
			meshSeen[key] = true
		end
	end
	slot.Type = typeId
	slot.Elite = elite
	slot.Low = low
	slot.Render = nil
	slot.FlashUntil = 0
	slot.Phase = math.random() * math.pi * 2
	slot.Parked = false
	restoreColors(slot.Pieces)
end

-- Every few seconds: does a type whose pool holds part-built fallbacks have its meshes
-- now? One fresh build tells; if it is a mesh model the fallbacks go.
local function probeMeshes()
	for key, list in pairs(modelPool) do
		local last = list[#list]
		if not meshSeen[key] and last and not isMesh(last.Pieces) then
			local pieces, motion, scale = buildModel(last.Type, last.Elite, last.Low)
			if isMesh(pieces) then
				meshSeen[key] = true
				for i = #list, 1, -1 do
					if not isMesh(list[i].Pieces) then
						destroyPieces(list[i].Pieces)
						table.remove(list, i)
						pooledTotal -= 1
					end
				end
				for _, piece in ipairs(pieces) do
					piece.Part.CFrame = PARK
				end
				table.insert(list, { Pieces = pieces, Motion = motion, Scale = scale, Type = last.Type, Elite = last.Elite, Low = last.Low })
				pooledTotal += 1
			else
				destroyPieces(pieces)
			end
		end
	end
end

-- Hides the slot's model: back to the pool (dead, or off screen).
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
	local core = slot.HaloCore
	if core then
		slot.HaloCore = nil
		core.CFrame = PARK
		table.insert(haloPool, core)
	end
end

-- Once the run is over: destroys pooled models past the per-type reserve and spare halos,
-- a few per frame (no hitch); returns false when nothing is left to trim.
local function trimPools(): boolean
	local n = 0
	for _, list in pairs(modelPool) do
		while #list > POOL_KEEP and n < 3 do
			local spare = table.remove(list)
			if spare then
				destroyPieces(spare.Pieces)
				pooledTotal -= 1
			end
			n += 1
		end
		if n >= 3 then
			return true
		end
	end
	while #haloPool > HALO_KEEP and n < 6 do
		local halo = table.remove(haloPool)
		if halo then
			halo:Destroy()
		end
		n += 1
	end
	return n > 0
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
		FlashNext = 0,
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
		FrostArmor = body:GetAttribute("FrostArmor") == true,
		Low = false,
		OnScreen = false,
		Stagger = id % 2,
		StepAt = 0,
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
	body:GetAttributeChangedSignal("FrostArmor"):Connect(function()
		slot.FrostArmor = body:GetAttribute("FrostArmor") == true
	end)
	body:GetAttributeChangedSignal("Act"):Connect(readAct)
	body:GetAttributeChangedSignal("Affix"):Connect(readAffix)
	body:GetAttributeChangedSignal("Shield"):Connect(readShield)
	readAct()
	readAffix()
	readShield()
end

--[[
	Hit flash (overhaul 2026-10): no longer a full white-out. Each piece moves part of the way
	toward a warm ivory, dark pieces (legs, undersides, seams, the mite's shell sides) much less
	than pale ones, so the silhouette and shell segmentation stay readable on grass and snow.
	Strength: grunts 0.6, elites 0.45 (their gold tint, crown and affix aura stay), bosses 0.32
	and at most once per BOSS_FLASH_GAP. Length Config.Enemies.HitFlashSeconds; off with
	Reduce Flashes / Reduced Effects. Meanings stay separate: damage = this brief warm lift;
	attack preparation = the pose plus the floor telegraph (Telegraphs.lua), the Bomb Tick's
	amber blink and the Queen's tail glow; elite = crown, ring and affix aura (never a flash).
]]
local FLASH_TINT = Color3.fromRGB(255, 241, 216)
local BOSS_FLASH_GAP = 0.3
flashColors = function(slot: Slot)
	local typeId = slot.Type
	local k = (typeId and isBoss(typeId :: string)) and 0.32 or (slot.Elite and 0.45 or 0.6)
	for _, piece in ipairs(slot.Pieces) do
		local base = Accessibility.Color(SnowContrast.base(piece))
		local lum = 0.299 * base.R + 0.587 * base.G + 0.114 * base.B
		piece.Part.Color = base:Lerp(FLASH_TINT, k * (0.3 + 0.7 * lum))
	end
end

-- Hit flash on enemy `id` (its full or low-detail model; an off-screen enemy has
-- neither and its body is hidden: nothing to flash).
function EnemyRenderer.Flash(id: number): boolean
	if ClientSettings.Flashes() then return true end
	local slot = slots[id]
	if not slot then
		return false -- not tracked yet: VFX flashes the body itself
	end
	local now = os.clock()
	if not slot.Parked and #slot.Pieces > 0 then
		if now < slot.FlashNext then
			return true -- a boss under constant hits keeps its colours between flashes
		end
		if now >= slot.FlashUntil then
			flashColors(slot)
		end
		if slot.Type and isBoss(slot.Type :: string) then
			slot.FlashNext = now + BOSS_FLASH_GAP
		end
	else
		local body = slot.Body
		if not body.Parent or body.CFrame.Y < ACTIVE_Y or body.LocalTransparencyModifier >= 1 then
			return true
		end
		return false -- not drawn yet (first frame): VFX flashes the visible body itself
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
-- Screen culling and detail ranking (on-screen enemies, nearest to the camera focus first)
------------------------------------------------------------------------------------------

-- the camera view this frame: an enemy counts as on screen when its centre is inside the
-- view frustum widened by `margin` studs (sideways, measured at its depth)
local viewOk = false
local viewPos, viewLook, viewRight, viewUp = Vector3.zero, Vector3.zAxis, Vector3.xAxis, Vector3.yAxis
local tanH, tanV = 1, 1

local function prepView(cam: Camera?)
	if not cam then
		viewOk = false
		return
	end
	local cf = cam.CFrame
	viewPos, viewLook, viewRight, viewUp = cf.Position, cf.LookVector, cf.RightVector, cf.UpVector
	local vp = cam.ViewportSize
	local aspect = (vp.Y > 0) and vp.X / vp.Y or 16 / 9
	tanV = math.tan(math.rad(cam.FieldOfView) / 2)
	tanH = tanV * aspect
	viewOk = true
end

local function inView(p: Vector3, margin: number): boolean
	if not viewOk then
		return true
	end
	local d = p - viewPos
	local z = d:Dot(viewLook)
	if z < -margin then
		return false
	end
	return math.abs(d:Dot(viewRight)) <= z * tanH + margin and math.abs(d:Dot(viewUp)) <= z * tanV + margin
end

local detailed: { [Slot]: boolean } = {}
local nextDetailed: { [Slot]: boolean } = {}
local fullRate: { [Slot]: boolean } = {} -- the nearest FULL_RATE: updated every frame
local rankList: { Slot } = {}
local rankTimer = 0
local screenCount = 0 -- of those, ranked enemies on screen last frame (decides the budget)
local crowdCount = 0 -- non-boss enemies on screen last frame (decides half-rate updates)
local wasBudgeted = false
local frameNo = 0
-- Stats() for the benchmark: last frame's counts
local stats = { live = 0, onScreen = 0, culled = 0, full = 0, low = 0, always = 0, parts = 0, skipped = 0, budget = 0, pooled = 0 }
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
		local typeId = slot.Type
		-- only on-screen enemies compete (the boss always runs at full rate)
		if slot.OnScreen and body.Parent and body.CFrame.Y >= ACTIVE_Y and not (typeId and isBoss(typeId)) then
			slot.Dist = ((body.Position - focus) * FLAT).Magnitude
			table.insert(rankList, slot)
		end
	end
	table.sort(rankList, function(a, b)
		return a.Dist < b.Dist
	end)
	-- hysteresis: a slot that already has its model keeps it while it ranks within 1.3x
	-- the budget, so enemies milling at the edge of the budget do not swap models in and
	-- out (each swap parks and re-poses a whole model); the nearest others fill the rest
	local limit = budget
	local keep = math.min(#rankList, math.floor(budget * 1.3))
	local fresh = nextDetailed
	table.clear(fresh)
	local count = 0
	-- (elites and static / support creatures are always full: outside the budget)
	local function special(slot: Slot): boolean
		return slot.Elite or (slot.Type ~= nil and alwaysDetailed(slot.Type :: string))
	end
	for i = 1, keep do
		local slot = rankList[i]
		if detailed[slot] and count < limit and not special(slot) then
			fresh[slot] = true
			count += 1
		end
	end
	for _, slot in ipairs(rankList) do
		if count >= limit then
			break
		end
		if not fresh[slot] and not special(slot) then
			fresh[slot] = true
			count += 1
		end
	end
	nextDetailed = detailed
	detailed = fresh
	table.clear(fullRate)
	for i = 1, math.min(FULL_RATE, #rankList) do
		fullRate[rankList[i]] = true
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
	elseif typeId == "BriarBoss" then
		if act == "Root" then
			-- leans in and sinks her arms into the soil
			local u = math.clamp(t / 0.5, 0, 1)
			return CFrame.new(0, -0.8 * u, -0.4 * u) * CFrame.Angles(-0.22 * u, 0, 0) * tremble(0.08 * u, t), 1, false
		elseif act == "Rooted" then
			return CFrame.new(0, -0.8, -0.4) * CFrame.Angles(-0.22, 0, 0) * tremble(0.05, t), 1, false
		elseif act == "Volley" then
			local u = math.clamp(t / 0.5, 0, 1)
			return CFrame.new(0, 0.3 * u, 0.6 * u) * CFrame.Angles(0.3 * u, 0, 0) * tremble(0.05 * u, t), 1, false
		elseif act == "Fling" then
			local k = math.max(0, 1 - t / 0.3)
			return CFrame.new(0, 0, -0.5 * k) * CFrame.Angles(-0.2 * k, 0, 0), 1, false
		end
	elseif typeId == "FrostBoss" then
		if act == "SlamWindup" then
			local u = math.clamp(t / 0.6, 0, 1)
			return CFrame.new(0, 1.2 * u, 0.9 * u) * CFrame.Angles(0.35 * u, 0, 0) * tremble(0.08 * u, t), 1, false
		elseif act == "Slam" then
			local k = math.max(0, 1 - t / 0.6)
			return CFrame.new(0, -0.9 * k, -0.6 * k) * CFrame.Angles(-0.3 * k, 0, 0) * tremble(0.25 * k, t), 1, false
		elseif act == "Stomp" then
			local u = math.clamp(t / 0.5, 0, 1)
			local k = math.max(0, 1 - math.abs(t - 0.7) / 0.3)
			return CFrame.new(0, 0.6 * u - 0.8 * k, 0) * CFrame.Angles(0, 0, 0.12 * u) * tremble(0.2 * k, t), 1, false
		elseif act == "Inhale" then
			local u = math.clamp(t / 0.8, 0, 1)
			return CFrame.new(0, 0.5 * u, 0.7 * u) * CFrame.Angles(0.28 * u, 0, 0), 1 + 0.05 * u, false
		elseif act == "Breathe" then
			return CFrame.new(0, -0.2, -0.5) * CFrame.Angles(-0.2, 0, 0) * tremble(0.06, t), 1, false
		elseif act == "ShardCall" then
			local u = math.clamp(t / 0.5, 0, 1)
			return CFrame.new(0, 0.8 * u, 0.3 * u) * CFrame.Angles(0.18 * u, 0, 0) * tremble(0.05 * u, t), 1, false
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
-- it is out); the Warlord's banner leaves his back while it is planted; the Colossus's
-- ice plates show only while his frost armour is on.
local MOUND = ModelLibrary.PieceGroups.Mound
local BANNER = ModelLibrary.PieceGroups.Banner
local FROST = ModelLibrary.PieceGroups.Frost
local function pieceHidden(typeId: string, slot: Slot, name: string): boolean
	if typeId == "Burrower" then
		local under = slot.Act == "Tunnel" or slot.Act == "Surface"
		return (MOUND[name] == true) ~= under
	elseif typeId == "RhinoBoss" then
		return slot.BannerOut and BANNER[name] == true
	elseif typeId == "FrostBoss" then
		return not slot.FrostArmor and FROST[name] == true
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
	p.Color = Accessibility.Color(color)
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
	fill.BackgroundColor3 = Accessibility.Color(Palette.crimson_400, "Danger")
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
		gui.Size = UDim2.fromOffset(110, 20)
		gui.LightInfluence = 0
		gui.MaxDistance = 220
		local label = Instance.new("TextLabel")
		label.BackgroundTransparency = 1
		label.Size = UDim2.fromScale(1, 1)
		label.Font = Enum.Font.SourceSansBold
		label.TextSize = 13
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
		label.TextColor3 = Accessibility.Color(info.Color)
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
	frameNo += 1
	local now = os.clock()
	table.clear(partsBuf)
	table.clear(cframesBuf)
	local n = 0

	-- the budget only matters when more enemies are on screen than it allows (last frame's
	-- count: one loop over the bodies instead of two); half-rate updates only when more
	-- are on screen than FULL_RATE
	adaptBudget(dt)
	local budgeted = screenCount > budget
	local crowded = crowdCount > FULL_RATE
	rankTimer -= dt
	if (crowded or budgeted) and (rankTimer <= 0 or (budgeted and not wasBudgeted)) then
		rankTimer = RANK_EVERY
		rank()
	end
	wasBudgeted = budgeted
	probeTimer -= dt
	if probeTimer <= 0 then
		probeTimer = PROBE_EVERY
		probeMeshes()
	end
	if trimming then
		-- the run ended: shed the spare models a few per frame (stops when a run starts)
		trimming = localPlayer:GetAttribute("InRun") ~= true and trimPools()
	end
	local cam = workspace.CurrentCamera
	prepView(cam)
	local live, shown, culled, nFull, nLow, nAlways, nBoss, skipped = 0, 0, 0, 0, 0, 0, 0, 0

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
			slot.OnScreen = false
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
			local always = elite or alwaysDetailed(typeId)
			local boss = always and isBoss(typeId)
			-- the server body is never drawn: a model stands in for it, or nothing off screen
			if body.LocalTransparencyModifier ~= 1 then
				body.LocalTransparencyModifier = 1
			end
			local size = body.Size
			local visible = boss
				or inView(cf.Position, (slot.OnScreen and CULL_LEAVE or CULL_MARGIN) + math.max(size.X, size.Y, size.Z) * 0.5)
			-- a FOG map event (WorldFx): normal enemies far from every player stay hidden
			local hide = EnemyRenderer.HideFilter
			if visible and hide and not always and hide(cf.Position, slot.OnScreen) then
				visible = false
			end
			slot.OnScreen = visible
			if not visible then
				-- off screen: no model, no updates (back to the pool)
				culled += 1
				if not slot.Parked or #slot.Pieces > 0 then
					park(slot)
				end
				if slot.Halo then
					dropHalo(slot)
				end
				if slot.Aura or (slot.Tag and slot.Tag.Enabled) then
					dropAura(slot)
				end
				if slot.RallyRing and slot.RallyRing.CFrame.Y > ACTIVE_Y then
					slot.RallyRing.CFrame = PARK
				end
				if slot.HPBar and slot.HPBar.Enabled then
					hideHPBar(slot)
				end
				continue
			end
			if always then
				nAlways += 1
				if boss then
					nBoss += 1
				end
			else
				shown += 1
			end
			local low = not always and budgeted and not detailed[slot]
			local fresh = false
			if slot.Type ~= typeId or slot.Elite ~= elite or slot.Low ~= low or #slot.Pieces == 0 then
				rebuild(slot, typeId, elite, low)
				fresh = true
			end
			slot.Parked = false
			if low then
				nLow += 1
			else
				nFull += 1
			end
			-- update rate: the nearest (and the special ones) every frame, the rest every 2nd
			-- frame, half of them on each (a fresh model is posed at once)
			if crowded and not boss and not fresh and (low or not fullRate[slot]) and (frameNo + slot.Stagger) % 2 ~= 0 then
				skipped += 1
				continue
			end
			local sdt = math.min(clock - slot.StepAt, 0.25)
			slot.StepAt = clock
			local alpha = 1 - math.exp(-sdt * 18)
			do
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
				slot.Move += (math.clamp(slot.Speed / 10, 0, 1) - slot.Move) * math.min(1, sdt * 6)

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
				if slot.Act == "Fuse" and not ClientSettings.Flashes() then
					local hz = 4 + 14 * math.clamp(actT / (fuse or 0.7), 0, 1)
					blinkOn = math.sin(actT * hz * math.pi * 2) > 0.2
				end
				if blinkOn ~= slot.Blink and now >= slot.FlashUntil then
					slot.Blink = blinkOn
					if blinkOn then
						for _, piece in ipairs(slot.Pieces) do
							piece.Part.Color = SnowContrast.base(piece):Lerp(BLINK, 0.7)
						end
					else
						restoreColors(slot.Pieces)
					end
				end

				-- (a low-detail model skips the whole-body bob / sway: posed rigidly)
				local bodyCF = render * CFrame.new(0, (scale - 1) * halfH, 0)
				if not low then
					bodyCF *= ModelLibrary.Motion(slot.Motion, clock, slot.Phase, slot.Move, slot.Scale)
				end
				bodyCF *= pose
				if hidden then
					bodyCF = CFrame.new(render.Position.X, -60, render.Position.Z) -- underground
				end
				local filtered = typeId == "Burrower" or typeId == "RhinoBoss" or typeId == "FrostBoss"
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

				-- elites: a hostile base ring under them (overhaul 2026-10): a crimson rim around
				-- a dark core, so it never reads as the hero's pale-gold ring, gold loot or an
				-- amber fire pool; the rim breathes slowly (steady with Reduce Flashes)
				if elite then
					local halo = slot.Halo
					local core = slot.HaloCore
					if not halo or not core then
						halo = halo or takeHalo()
						core = core or takeHalo()
						slot.Halo = halo
						slot.HaloCore = core
						local d = math.max(body.Size.X, body.Size.Z) * 1.3 + 1.2
						halo.Size = Vector3.new(0.06, d, d)
						core.Size = Vector3.new(0.06, d - 1.1, d - 1.1)
						halo.Color = Accessibility.Color(Palette.crimson_500, "Danger")
						core.Color = Palette.chitin_900
					end
					local calm = ClientSettings.Flashes()
					halo.Transparency = calm and 0.3 or (0.3 + 0.1 * math.sin(clock * 2.4 + slot.Phase))
					core.Transparency = 0.5
					local p = render.Position
					n += 1
					partsBuf[n] = halo
					cframesBuf[n] = CFrame.new(p.X, FLOOR_Y + 0.34, p.Z) * DISC -- over the paths, under telegraphs
					n += 1
					partsBuf[n] = core :: BasePart
					cframesBuf[n] = CFrame.new(p.X, FLOOR_Y + 0.345, p.Z) * DISC
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
					ring.Color = Accessibility.Color(banner and Palette.gold_400 or Palette.crimson_400, "Danger")
					ring.Transparency = (banner and 0.3 or 0.45) + (ClientSettings.Flashes() and 0 or 0.15 * math.sin(clock * 6 + slot.Phase))
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
	stats.live = live
	screenCount = shown
	crowdCount = shown + nAlways - nBoss
	stats.onScreen = shown + nAlways
	stats.culled = culled
	stats.full = nFull
	stats.low = nLow
	stats.always = nAlways
	stats.parts = n
	stats.skipped = skipped
	stats.budget = budget
	stats.pooled = pooledTotal
	if n > 0 then
		workspace:BulkMoveTo(partsBuf, cframesBuf, Enum.BulkMoveMode.FireCFrameChanged)
	end
end

-- Last frame's level-of-detail counts (for the benchmark scenes): enemies on screen and
-- culled, full / low-detail / always-detailed models drawn, parts moved, half-rate slots
-- skipped, the current detail budget and the pooled models.
function EnemyRenderer.Stats(): { [string]: number }
	return table.clone(stats)
end

function EnemyRenderer.Init()
	ClientSettings.OnChanged(function(key)
		if key == "Colorblind" or key == "ReduceFlashes" or key == "ReducedEffects" then
			for _, slot in pairs(slots) do
				slot.FlashUntil = 0
				restoreColors(slot.Pieces)
				if slot.Halo then
					slot.Halo.Color = Accessibility.Color(Palette.crimson_500, "Danger")
				end
			end
		end
	end)
	local folder = Instance.new("Folder")
	folder.Name = "SwarmEnemyModels"
	folder.Parent = workspace
	modelFolder = folder
	ModelLibrary.SetFolder(folder)
	localPlayer:GetAttributeChangedSignal("InRun"):Connect(function()
		if localPlayer:GetAttribute("InRun") ~= true then
			trimming = true
		end
	end)
	-- Snow contrast follows the arena (SwarmState Arena); live models recolour at once
	task.spawn(function()
		local state = game:GetService("ReplicatedStorage"):WaitForChild("SwarmState")
		local function sync()
			local on = state:GetAttribute("Arena") == "Snow"
			if on ~= SnowContrast.On then
				SnowContrast.On = on
				for _, slot in pairs(slots) do
					if slot.Type and SnowContrast.Types[slot.Type] and slot.FlashUntil == 0 then
						restoreColors(slot.Pieces)
					end
				end
			end
		end
		state:GetAttributeChangedSignal("Arena"):Connect(sync)
		sync()
	end)
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
