--[[
	EnemyRenderer.lua
	Puts a detailed, animated ModelLibrary model on every live enemy, on this client only.

	The server moves one plain Part per enemy ("Body", the hit body). Here we hide that
	part (LocalTransparencyModifier) and draw the model in its place, smoothing between
	network updates so movement looks fluid even at a low replication rate. All model
	pieces move with a single workspace:BulkMoveTo per frame.

	Detail budget (Config.Graphics.MaxDetailedEnemies): when more enemies are alive than
	the budget, the ones nearest the camera focus get the full model (ranked a few times a
	second) and the rest show their plain body, restyled locally in the creature's palette
	colour. The boss and elites are always detailed. Models are pooled per enemy type, so
	a recycled body reuses parts instead of building new ones.

	Readability: Flash() gives a brief white hit flash (model or plain body); elites stand
	on a soft gold ground ring on top of their bigger, gold-tinted model with its crown,
	wear their affix aura (EliteAura_* meshes or a part ring: flames, orbiting shield
	plates that shatter when the shield breaks, wind streaks) and a small affix tag.

	Spawns climb out of the ground (short emerge + dust puff). The server's "Act" body
	attribute drives readable poses: Spitter wind-up (swells, rears back), Bomb Tick fuse
	(swells and blinks faster and faster), Rhino rear-up / lunge / recover, and the
	Queen's entrance (rises from the ground), crouch before a charge, dizzy stars when
	stunned, raised claws, glowing raised tail, the dive and burrow (hidden, a dust trail
	follows her), the roar and the collapse. Floor telegraphs live in Telegraphs.lua.
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
	Aura: { any }?,
	AuraAffix: string?,
	Tag: BillboardGui?,
	Extras: { BasePart }?,
	DustAt: number,
	ShieldBroke: number?,
}

type PooledModel = { Pieces: { any }, Motion: string, Scale: number }

local slots: { [number]: Slot } = {}
local PARK = CFrame.new(0, -150, 0)
local ACTIVE_Y = -100
local FLOOR_Y = Config.ArenaOrigin.Y
local DISC = CFrame.Angles(0, 0, math.rad(90)) -- cylinder axis X → Y (a flat disc)
local FLAT = Vector3.new(1, 0, 1)
local WHITE = Color3.new(1, 1, 1)
local RANK_EVERY = 0.3 -- seconds between nearest-first detail rankings
local POOL_CAP = 48 -- spare models kept per enemy type

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
}
local ELITE_GOLD = Palette.gold_400

------------------------------------------------------------------------------------------
-- Model pool (per enemy type + elite)
------------------------------------------------------------------------------------------

local modelPool: { [string]: { PooledModel } } = {}

local function modelKey(typeId: string, elite: boolean): string
	return elite and (typeId .. "*") or typeId
end

local function restoreColors(pieces: { any })
	for _, piece in ipairs(pieces) do
		piece.Part.Color = piece.Color
	end
end

-- Takes the slot's model away: kept for reuse when it is built from the uploaded meshes
-- (its final look); part-built fallbacks are dropped so they get replaced by meshes.
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
	if list and #list < POOL_CAP and pieces[1].Part:IsA("MeshPart") then
		if slot.FlashUntil > 0 then
			restoreColors(pieces)
		end
		for _, piece in ipairs(pieces) do
			piece.Part.CFrame = PARK
		end
		table.insert(list, { Pieces = pieces, Motion = slot.Motion, Scale = slot.Scale })
	else
		for _, piece in ipairs(pieces) do
			piece.Part:Destroy()
		end
	end
end

local function rebuild(slot: Slot, typeId: string, elite: boolean)
	releaseModel(slot)
	local list = modelPool[modelKey(typeId, elite)]
	local spare = list and table.remove(list)
	if spare then
		slot.Pieces, slot.Motion, slot.Scale = spare.Pieces, spare.Motion, spare.Scale
	else
		local pieces, motion, scale = ModelLibrary.Enemy(typeId, elite)
		slot.Pieces, slot.Motion, slot.Scale = pieces, motion, scale
	end
	slot.Type = typeId
	slot.Elite = elite
	slot.Render = nil
	slot.FlashUntil = 0
	slot.Phase = math.random() * math.pi * 2
	slot.Parked = false
end

local function park(slot: Slot)
	if slot.Parked then
		return
	end
	slot.Parked = true
	slot.Render = nil
	for _, piece in ipairs(slot.Pieces) do
		piece.Part.CFrame = PARK
	end
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
		Aura = nil,
		AuraAffix = nil,
		Tag = nil,
		Extras = nil,
		DustAt = 0,
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
	local limit = Config.Graphics.MaxDetailedEnemies
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
	local boss = typeId == "Boss"
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

	-- the budget only matters when more enemies are alive than it allows
	local live = 0
	for _, slot in pairs(slots) do
		if slot.Body.Parent and slot.Body.CFrame.Y >= ACTIVE_Y then
			live += 1
		end
	end
	local budgeted = live > Config.Graphics.MaxDetailedEnemies
	rankTimer -= dt
	if budgeted and rankTimer <= 0 then
		rankTimer = RANK_EVERY
		rank()
	end

	for _, slot in pairs(slots) do
		local body = slot.Body
		local cf = body.CFrame
		local typeId = body:GetAttribute("Type")
		if cf.Y < ACTIVE_Y or not body.Parent or typeof(typeId) ~= "string" then
			park(slot)
			dropHalo(slot)
			if slot.Live then
				slot.Live = false
				dropAura(slot)
				parkExtras(slot)
			end
		else
			if not slot.Live then
				-- a fresh spawn: it climbs out of the ground (the Queen has her own entrance)
				slot.Live = true
				slot.SpawnAt = clock
				if typeId ~= "Boss" then
					local r = math.max(body.Size.X, body.Size.Z) / 2
					Telegraphs.Puff(cf.Position.X, cf.Position.Z, r)
				end
			end
			local elite = body:GetAttribute("Elite") == true
			if budgeted and not detailed[slot] and typeId ~= "Boss" and not elite then
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

				local last = slot.LastPos
				local speed = last and ((cf.Position - last) * FLAT).Magnitude / math.max(dt, 1e-3) or 0
				slot.LastPos = cf.Position
				slot.Move += (math.clamp(speed / 10, 0, 1) - slot.Move) * math.min(1, dt * 6)

				if slot.FlashUntil > 0 and now >= slot.FlashUntil then
					slot.FlashUntil = 0
					restoreColors(slot.Pieces)
				end

				local halfH = body.Size.Y / 2
				local actT = clock - slot.ActAt
				local fuse = slot.Act == "Fuse" and fuseSeconds(typeId, slot.Elite == true) or nil
				local pose, scale, hidden = actPose(typeId, slot.Act, actT, halfH, fuse)
				local sinceSpawn = clock - slot.SpawnAt
				if sinceSpawn < EMERGE and typeId ~= "Boss" then
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
				for _, piece in ipairs(slot.Pieces) do
					n += 1
					partsBuf[n] = piece.Part
					cframesBuf[n] = scale == 1 and ModelLibrary.PieceCFrame(bodyCF, piece, clock, slot.Phase, slot.Move)
						or ModelLibrary.PieceCFrameScaled(bodyCF, piece, clock, slot.Phase, slot.Move, scale)
				end

				-- the Queen: dust trail while she burrows, dizzy stars, glowing raised tail
				if typeId == "Boss" then
					local act = slot.Act
					if (act == "Burrow" or act == "Dive") and clock >= slot.DustAt then
						slot.DustAt = clock + (act == "Burrow" and 0.06 or 0.12)
						local p = render.Position
						Telegraphs.Dust(p.X + (math.random() - 0.5) * 3, p.Z + (math.random() - 0.5) * 3, 2.6)
					end
					local extras = bossExtras(slot)
					if act == "Stunned" then
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
					if act == "TailRaise" then
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
			end
		end
	end
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
