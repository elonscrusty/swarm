--[[
	SecretRoom.lua
	Feature 4, SECRET ROOMS (Config.Features.SecretRooms, Config.Explore.SecretRoom,
	docs/features/EXPLORE.md). A placed EncounterDirector encounter: a small walled alcove
	at an arena edge whose front is a CRACKED WALL with a glowing crack (the hint shimmer:
	the client ExploreUI pulses the parts named "Crack").

	  Sealed  the wall has HP. Every weapon attack a player makes within BreakRange studs
	          of it chips it (WeaponSystem.OnFired: the attack's damage x its projectile
	          count, capped at MaxShots). So "any attack" breaks it: no new input.
	  Open    the wall crumbles once (exactly once): its collider is removed (the enemy
	          obstacle grid is rebuilt) and the alcove holds either
	            Treasure   a free chest (LootSystem.AddTreasure, the Buried Cache rules:
	                       one item, hold to claim, exactly-once by LootSystem)
	            Challenge  a small elite pack climbs out (their usual elite drops are the
	                       reward; nothing extra is granted)

	Space: the alcove sits inside the fence (EdgeMargin..EdgeMargin+EdgeBand studs from it)
	on a spot the director reserved (FindSpot keeps the portal, loot, caravan and other
	encounters away, and the spot free of colliders and hazard pools). Its back and side
	walls are box colliders on the arena floor; the floor itself is the arena's, so there
	is nothing to fall through. Nothing is placed in the spawn clearing.

	World: model "SecretRoom" in workspace.SwarmEvents with attributes the client reads
	(ExploreUI): EventKind = "SecretRoom", Title, State (Sealed | Open), Pos (wall centre),
	HPFrac (0-1), Reward ("Treasure" | "Challenge", set when it opens).
]]

local Config = require(game:GetService("ReplicatedStorage").Shared.Config)
local EnemyData = require(game:GetService("ReplicatedStorage").Shared.EnemyData)
local Palette = require(game:GetService("ReplicatedStorage").Shared.Palette)
local ModelBuilder = require(script.Parent.ModelBuilder)
local MapBuilder = require(script.Parent.MapBuilder)
local Fx = require(script.Parent.Fx)
local EncounterDirector = require(script.Parent.EncounterDirector)

local SecretRoom = {}

local NAME = "SecretRoom"
local P = Palette :: { [string]: Color3 }
local part = ModelBuilder.Part
local NEON = Enum.Material.Neon
local FLAT = Vector3.new(1, 0, 1)

type Room = {
	Arena: any,
	Stage: number,
	Pos: Vector3, -- alcove centre (floor)
	WallPos: Vector3, -- cracked wall centre (floor)
	Out: Vector3, -- unit, toward the fence
	Model: Model,
	State: string,
	HP: number,
	MaxHP: number,
	FrontRecord: any?, -- the front wall's arena.Obstacles entry
	FrontPart: BasePart?, -- its collider part
	Front: { BasePart }, -- the visible cracked wall pieces
	Reward: string?,
	Shown: number,
}

local ctx
local room: Room? = nil
local listening = false

local function K()
	return Config.Explore.SecretRoom
end

local function eventsFolder(): Folder
	local f = workspace:FindFirstChild("SwarmEvents")
	if not f then
		f = Instance.new("Folder")
		f.Name = "SwarmEvents"
		f.Parent = workspace
	end
	return f :: Folder
end

------------------------------------------------------------------------------------------
-- Placement
------------------------------------------------------------------------------------------

-- Distance from the fence of a floor point (square arena).
local function fenceGap(arena, pos: Vector3): number
	local c = arena.Center
	return arena.Half - math.max(math.abs(pos.X - c.X), math.abs(pos.Z - c.Z))
end

-- A reserved spot near an arena edge (nil when the arena has none free).
local function edgeSpot(arena): Vector3?
	local k = K()
	local half = (k.Width / 2 + k.Wall) -- the alcove's half-size along the edge
	for _ = 1, 16 do
		local spot = EncounterDirector.FindSpot(NAME, {
			EdgeMargin = k.EdgeMargin,
			MinDistance = arena.Half - k.EdgeMargin - k.EdgeBand,
			Clearance = math.sqrt(half * half + (k.Depth / 2 + k.Wall) ^ 2) + 1.5,
		})
		if not spot then
			return nil
		end
		if fenceGap(arena, spot) <= k.EdgeMargin + k.EdgeBand then
			return spot
		end
		EncounterDirector.Release(NAME)
	end
	return nil
end

-- Unit vector (axis-aligned) from the arena centre toward the nearest fence side.
local function outward(arena, pos: Vector3): Vector3
	local d = pos - arena.Center
	if math.abs(d.X) >= math.abs(d.Z) then
		return Vector3.new(d.X >= 0 and 1 or -1, 0, 0)
	end
	return Vector3.new(0, 0, d.Z >= 0 and 1 or -1)
end

------------------------------------------------------------------------------------------
-- Model
------------------------------------------------------------------------------------------

local function wallColour(arenaName: string?): (Color3, Color3)
	if arenaName == "Snow" then
		return P.slate_400, P.slate_600
	elseif arenaName == "Desert" then
		return P.sand_500, P.sand_700
	elseif arenaName == "Lava" then
		return P.basalt_600, P.basalt_800
	end
	return P.stone_500, P.stone_700
end

-- A wall piece (visual) centred on floor point `centre`, `len` long along `along`,
-- `thick` deep and `h` high.
local function slab(m: Model, name: string, centre: Vector3, along: Vector3, len: number, thick: number, h: number, color: Color3): BasePart
	local cf = CFrame.fromMatrix(centre + Vector3.new(0, h / 2, 0), along, Vector3.yAxis)
	local p = part({ Name = name, Size = Vector3.new(len, h, thick), CFrame = cf, Color = color, Material = Enum.Material.Slate, CastShadow = true })
	p.Parent = m
	return p
end

-- A box collider (axis-aligned: `out` is an axis) centred on floor point `centre`.
local function collider(arena, centre: Vector3, alongLen: number, outLen: number, out: Vector3, h: number): (any, BasePart?)
	local sx = math.abs(out.X) > 0.5 and outLen or alongLen
	local sz = math.abs(out.X) > 0.5 and alongLen or outLen
	local before = #arena.Obstacles
	local kids = {}
	for _, ch in ipairs(arena.ObstacleFolder:GetChildren()) do
		kids[ch] = true
	end
	MapBuilder.AddCollider(arena, { Kind = "Box", Size = { sx, sz }, Height = h }, CFrame.new(centre))
	local record = #arena.Obstacles > before and arena.Obstacles[#arena.Obstacles] or nil
	local made: BasePart? = nil
	for _, ch in ipairs(arena.ObstacleFolder:GetChildren()) do
		if not kids[ch] and ch:IsA("BasePart") then
			made = ch
		end
	end
	return record, made
end

local function build(info, spot: Vector3): Room
	local k = K()
	local arena = info.Arena
	local out = outward(arena, spot)
	local along = Vector3.new(-out.Z, 0, out.X)
	local stage = math.max(1, info.Stage or 1)
	local stone, dark = wallColour(info.ArenaName)
	local m = Instance.new("Model")
	m.Name = NAME
	local w, d, t, h = k.Width, k.Depth, k.Wall, k.Height
	local wallPos = spot - out * (d / 2 + t / 2)
	local r: Room = {
		Arena = arena,
		Stage = stage,
		Pos = spot,
		WallPos = wallPos,
		Out = out,
		Model = m,
		State = "Sealed",
		HP = 0,
		MaxHP = 0,
		FrontRecord = nil,
		FrontPart = nil,
		Front = {},
		Reward = nil,
		Shown = -1,
	}
	r.MaxHP = math.floor(k.HP * (1 + k.HPPerStage * (stage - 1)) + 0.5)
	r.HP = r.MaxHP
	-- back and side walls (stay), a dark floor inside, a lintel stone
	slab(m, "Back", spot + out * (d / 2 + t / 2), along, w + t * 2, t, h, dark)
	slab(m, "Side", spot + along * (w / 2 + t / 2), out, d + t * 2, t, h, stone)
	slab(m, "Side", spot - along * (w / 2 + t / 2), out, d + t * 2, t, h, stone)
	-- (no roof: the run camera looks down into the alcove)
	local floor = part({ Name = "Floor", Size = Vector3.new(w, 0.1, d), CFrame = CFrame.fromMatrix(spot + Vector3.new(0, 0.05, 0), along, Vector3.yAxis), Color = dark, Material = Enum.Material.Slate })
	floor.Parent = m
	-- the cracked front: three blocks with a glowing crack between them
	local third = w / 3
	for i = -1, 1 do
		local piece = slab(m, "Front", wallPos + along * (i * third), along, third - 0.15, t, h - 0.6, stone)
		table.insert(r.Front, piece)
	end
	-- the crack: a zig-zag of thin neon strips across the front face (hint shimmer)
	local face = wallPos - out * (t / 2 + 0.06)
	local pts = { Vector2.new(-2.8, 0.6), Vector2.new(-1.4, 2.6), Vector2.new(-0.2, 1.8), Vector2.new(0.9, 4.2), Vector2.new(2.1, 3.4), Vector2.new(3.0, 5.8) }
	for i = 1, #pts - 1 do
		local a, b = pts[i], pts[i + 1]
		local pa = face + along * a.X + Vector3.new(0, a.Y, 0)
		local pb = face + along * b.X + Vector3.new(0, b.Y, 0)
		local mid = (pa + pb) / 2
		local len = (pb - pa).Magnitude
		local frame = CFrame.lookAt(mid, mid - out)
		local dir = pb - pa
		local turn = math.atan2(-dir:Dot(frame.RightVector), dir:Dot(frame.UpVector))
		local crack = part({ Name = "Crack", Size = Vector3.new(0.22, len + 0.1, 0.12), CFrame = frame * CFrame.Angles(0, 0, turn), Color = P.gold_300, Material = NEON, Transparency = 0.3 })
		crack.Parent = m
		table.insert(r.Front, crack)
	end
	-- the marker anchor the client hangs its pill on
	local anchor = part({ Name = "Anchor", Size = Vector3.new(0.2, 0.2, 0.2), CFrame = CFrame.new(wallPos + Vector3.new(0, h + 1.5, 0)), Transparency = 1 })
	anchor.Parent = m
	local light = Instance.new("PointLight")
	light.Color = P.gold_300
	light.Range = 12
	light.Brightness = 0.9
	light.Shadows = false
	light.Parent = anchor
	-- colliders: back, sides and the front (removed when it breaks)
	collider(arena, spot + out * (d / 2 + t / 2), w + t * 2, t, out, h)
	collider(arena, spot + along * (w / 2 + t / 2), t, d + t * 2, out, h)
	collider(arena, spot - along * (w / 2 + t / 2), t, d + t * 2, out, h)
	r.FrontRecord, r.FrontPart = collider(arena, wallPos, w, t, out, h)
	MapBuilder.ClearDecor(arena, spot, w)
	m:SetAttribute("EventKind", NAME)
	m:SetAttribute("Title", "Cracked Wall")
	m:SetAttribute("State", "Sealed")
	m:SetAttribute("Pos", wallPos)
	m:SetAttribute("HPFrac", 1)
	m:SetAttribute("Out", out)
	m.Parent = eventsFolder()
	return r
end

------------------------------------------------------------------------------------------
-- Breaking
------------------------------------------------------------------------------------------

-- An enemy type of this minute's mix that can stand in a pack (melee, walks).
local function packType(rng: Random): string
	local row = EnemyData.GetSpawnRow(ctx.EnemySpawner.ProgressionTime())
	local pool, total = {}, 0
	for id, w in pairs(row.Weights) do
		local def = EnemyData.Enemies[id]
		if def and not def.Ranged and not def.Support and not def.Burrow and not def.NoWave and not def.IsBoss and not def.Static and not def.Explode then
			table.insert(pool, { id, w })
			total += w
		end
	end
	table.sort(pool, function(a, b) return a[1] < b[1] end) -- stable order for the director's rng
	if total <= 0 then
		return "Slime"
	end
	local roll = rng:NextNumber() * total
	for _, e in ipairs(pool) do
		roll -= e[2]
		if roll <= 0 then
			return e[1]
		end
	end
	return pool[#pool][1]
end

local function spawnPack(r: Room, rng: Random): number
	local k = K()
	local n = math.min(k.PackMax, k.PackBase + math.floor((r.Stage - 1) / 2))
	local typeId = packType(rng)
	local made = 0
	local along = Vector3.new(-r.Out.Z, 0, r.Out.X)
	for i = 1, n do
		local x = (i - (n + 1) / 2) * (k.Width / (n + 1))
		local at = r.Pos + along * x
		if ctx.EnemySpawner.Spawn(typeId, Vector3.new(at.X, Config.ArenaOrigin.Y, at.Z), { Elite = true, Force = true }) then
			made += 1
		end
	end
	return made
end

local function open(r: Room, rng: Random)
	if r.State ~= "Sealed" then
		return -- exactly once
	end
	r.State = "Open"
	r.HP = 0
	-- the way in: remove the front collider and let the enemies' obstacle grid know
	local arena = r.Arena
	if r.FrontRecord then
		local i = table.find(arena.Obstacles, r.FrontRecord)
		if i then
			table.remove(arena.Obstacles, i)
		end
	end
	if r.FrontPart then
		r.FrontPart:Destroy()
	end
	if ctx.EnemyAI and ctx.EnemyAI.SetArena then
		ctx.EnemyAI.SetArena(arena)
	end
	for _, p in ipairs(r.Front) do
		p:Destroy()
	end
	table.clear(r.Front)
	-- rubble on the threshold (no collision)
	local along = Vector3.new(-r.Out.Z, 0, r.Out.X)
	local stone = wallColour(nil)
	for _ = 1, 5 do
		local at = r.WallPos + along * rng:NextNumber(-K().Width / 2, K().Width / 2) - r.Out * rng:NextNumber(0, 2.5)
		local s = rng:NextNumber(0.6, 1.3)
		local rock = part({ Name = "Rubble", Size = Vector3.new(s, s * 0.7, s), CFrame = CFrame.new(at + Vector3.new(0, s * 0.3, 0)) * CFrame.Angles(rng:NextNumber(0, 1), rng:NextNumber(0, 3), 0), Color = stone })
		rock.Parent = r.Model
	end
	Fx.Explosion(r.WallPos + Vector3.new(0, 2, 0), 5)
	Fx.Sound("Explosion")
	local challenge = rng:NextNumber() < K().ChallengeChance
	if challenge and spawnPack(r, rng) > 0 then
		r.Reward = "Challenge"
		Fx.Sound("EliteSpawn")
		ctx.RunManager.Broadcast("The wall breaks... elites were hiding inside!", Color3.fromRGB(255, 150, 120), nil, { Id = "secret.result" })
	else
		r.Reward = "Treasure"
		ctx.LootSystem.AddTreasure(arena, r.Pos, "Secret Cache")
		Fx.Sound("Chest")
		ctx.RunManager.Broadcast("The wall breaks: a secret cache!", Color3.fromRGB(255, 220, 120), nil, { Id = "secret.result" })
	end
	r.Model:SetAttribute("Reward", r.Reward)
	r.Model:SetAttribute("HPFrac", 0)
	r.Model:SetAttribute("State", "Open")
	EncounterDirector.Finish(NAME) -- frees the running slot; the alcove stays until the stage ends
end

local function onFired(rp, _w, s)
	local r = room
	if not r or r.State ~= "Sealed" or not rp.Alive or rp.Returned or not rp.Root then
		return
	end
	if not Config.FeatureOn("SecretRooms") then
		return
	end
	local d = (rp.Root.Position - r.WallPos) * FLAT
	if d.Magnitude > K().BreakRange then
		return
	end
	local hit = math.max(0, tonumber(s and s.damage) or 0) * math.clamp(tonumber(s and s.amount) or 1, 1, K().MaxShots)
	if hit ~= hit or hit == math.huge then
		return
	end
	r.HP -= hit
	local frac = math.max(0, math.floor(r.HP / r.MaxHP * 20 + 0.999) / 20)
	if frac ~= r.Shown then
		r.Shown = frac
		r.Model:SetAttribute("HPFrac", frac)
		Fx.Ring(r.WallPos, 3, P.gold_300)
	end
	if r.HP <= 0 then
		local info = EncounterDirector.Stage()
		open(r, info and info.Rng or Random.new())
	end
end

------------------------------------------------------------------------------------------
-- Director callbacks
------------------------------------------------------------------------------------------

local function cleanup(_reason: string?)
	local r = room
	room = nil
	if r then
		r.Model:Destroy()
		-- the arena (and its colliders) goes with the stage; nothing else to undo
	end
end

function SecretRoom.Get(): Room?
	return room
end

-- Tests: hit the wall like attacks would (amount per attack, attacks).
function SecretRoom.DebugHit(amount: number)
	local r = room
	if r and r.State == "Sealed" then
		r.HP -= amount
		if r.HP <= 0 then
			local info = EncounterDirector.Stage()
			open(r, info and info.Rng or Random.new())
		end
	end
end

function SecretRoom.Init(c)
	ctx = c
	EncounterDirector.Register(NAME, {
		Feature = "SecretRooms",
		Weight = Config.Explore.SecretRoom.Weight,
		OnStageStart = function(info)
			cleanup("Restart")
			local spot = edgeSpot(info.Arena)
			if not spot then
				return false
			end
			room = build(info, spot)
			return true
		end,
		OnCleanup = cleanup,
	})
	if not listening and ctx.WeaponSystem and ctx.WeaponSystem.OnFired then
		listening = true
		ctx.WeaponSystem.OnFired(function(rp, w, s)
			local ok, err = pcall(onFired, rp, w, s)
			if not ok then
				warn("[SecretRoom] " .. tostring(err))
			end
		end)
	end
end

return SecretRoom
