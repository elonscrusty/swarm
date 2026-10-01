--[[
	VFX.lua
	All client-side visuals. Nothing here affects gameplay.

	* Projectiles: decodes the ProjectileBatch buffer (see WeaponSystem) and moves pooled
	  local parts with interpolation between batches (one workspace:BulkMoveTo per frame).
	* Effects: FxBatch (hit flashes, death poofs, slashes, lightning, pools, explosions,
	  shockwaves, boss telegraphs, player events, sounds) with pooled parts and tweens.
	* Gems: local bob/spin on top of the server position (attribute "Base").
	* Garlic aura rings, HP bars over players, procedural limb swing for characters.
]]

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")

local Shared = game:GetService("ReplicatedStorage"):WaitForChild("Shared")
local Config = require(Shared:WaitForChild("Config"))
local Remotes = require(Shared:WaitForChild("Remotes"))
local WeaponData = require(Shared:WaitForChild("WeaponData"))
local Audio = require(script.Parent.Audio)
local CameraController = require(script.Parent.CameraController)

local VFX = {}

local player = Players.LocalPlayer
local PARK = CFrame.new(0, -150, 0) -- under the floor, above FallenPartsDestroyHeight
local FLOOR_Y = Config.ArenaOrigin.Y

local fxFolder: Folder
local onLocalEvent: ((string) -> ())? = nil

------------------------------------------------------------------------------------------
-- Part pools
------------------------------------------------------------------------------------------

local function newPart(shape: Enum.PartType?, color: Color3, material: Enum.Material, size: Vector3): Part
	local p = Instance.new("Part")
	if shape then
		p.Shape = shape
	end
	p.Anchored = true
	p.CanCollide = false
	p.CanQuery = false
	p.CanTouch = false
	p.CastShadow = false
	p.Material = material
	p.Color = color
	p.Size = size
	p.TopSurface = Enum.SurfaceType.Smooth
	p.BottomSurface = Enum.SurfaceType.Smooth
	p.CFrame = PARK
	p.Parent = fxFolder
	return p
end

-- Generic effect pools keyed by shape name ("Ball", "Block", "Cylinder").
local effectPools: { [string]: { Part } } = { Ball = {}, Block = {}, Cylinder = {} }
local SHAPES = { Ball = Enum.PartType.Ball, Block = Enum.PartType.Block, Cylinder = Enum.PartType.Cylinder }

local function getEffectPart(shape: string): Part
	local list = effectPools[shape]
	local p = table.remove(list)
	if not p then
		p = newPart(SHAPES[shape], Color3.new(1, 1, 1), Enum.Material.Neon, Vector3.one)
	end
	p.Transparency = 0
	return p
end

local function releaseEffectPart(shape: string, p: Part)
	p.CFrame = PARK
	table.insert(effectPools[shape], p)
end

-- Tween an effect part, then return it to the pool.
local function play(shape: string, p: Part, seconds: number, goal: { [string]: any }, style: Enum.EasingStyle?)
	local tween = TweenService:Create(p, TweenInfo.new(seconds, style or Enum.EasingStyle.Quad, Enum.EasingDirection.Out), goal)
	tween.Completed:Once(function()
		releaseEffectPart(shape, p)
	end)
	tween:Play()
end

-- Flat disc lying on the floor (cylinder axis is X, so rotate it upright).
local DISC = CFrame.Angles(0, 0, math.rad(90))

------------------------------------------------------------------------------------------
-- Projectiles
------------------------------------------------------------------------------------------

type Entry = { Part: Part, Visual: number, Seq: number, From: Vector3, To: Vector3, Yaw: number, T: number, Spin: number, Seen: number }

local projectilePools: { [number]: { Part } } = {}
local entries: { [number]: Entry } = {}
local batchCounter = 0
local syncInterval = 1 / Config.Net.ProjectileSyncHz
local projParts: { BasePart } = {}
local projCFrames: { CFrame } = {}

local function getProjectilePart(visual: number): Part
	local list = projectilePools[visual]
	if not list then
		list = {}
		projectilePools[visual] = list
	end
	local p = table.remove(list)
	if p then
		return p
	end
	local def = WeaponData.Visuals[visual] or WeaponData.Visuals[1]
	return newPart(SHAPES[def.Shape], def.Color, (Enum.Material :: any)[def.Material] or Enum.Material.Neon, def.Size)
end

local function releaseProjectile(id: number)
	local e = entries[id]
	if not e then
		return
	end
	e.Part.CFrame = PARK
	table.insert(projectilePools[e.Visual], e.Part)
	entries[id] = nil
end

local function onProjectileBatch(b: buffer)
	if typeof(b) ~= "buffer" then
		return
	end
	batchCounter += 1
	local count = buffer.readu16(b, 0)
	local o = 2
	for _ = 1, count do
		local id = buffer.readu16(b, o)
		local visual = buffer.readu8(b, o + 2)
		local seq = buffer.readu8(b, o + 3)
		local x = buffer.readi16(b, o + 4) / 10
		local y = buffer.readi16(b, o + 6) / 10
		local z = buffer.readi16(b, o + 8) / 10
		local yaw = buffer.readu8(b, o + 10) / 255 * math.pi * 2
		o += 11
		local pos = Vector3.new(x, y, z)
		local e = entries[id]
		if e and (e.Seq ~= seq or e.Visual ~= visual) then
			releaseProjectile(id)
			e = nil
		end
		if not e then
			local def = WeaponData.Visuals[visual] or WeaponData.Visuals[1]
			entries[id] = {
				Part = getProjectilePart(visual),
				Visual = visual,
				Seq = seq,
				From = pos,
				To = pos,
				Yaw = yaw,
				T = 1,
				Spin = def.Spin or 0,
				Seen = batchCounter,
			}
		else
			-- continue from where it is drawn now
			local alpha = math.clamp(e.T, 0, 1)
			e.From = e.From:Lerp(e.To, alpha)
			e.To = pos
			e.T = 0
			e.Yaw = yaw
			e.Seen = batchCounter
		end
	end
	for id, e in pairs(entries) do
		if e.Seen ~= batchCounter then
			releaseProjectile(id)
		end
	end
end

local spinClock = 0
local function renderProjectiles(dt: number)
	spinClock += dt
	table.clear(projParts)
	table.clear(projCFrames)
	local n = 0
	for _, e in pairs(entries) do
		e.T += dt / syncInterval
		local alpha = math.min(e.T, 1.5) -- small extrapolation hides jitter
		local pos = e.From:Lerp(e.To, alpha)
		local cf = CFrame.new(pos) * CFrame.Angles(0, e.Yaw + (e.Spin ~= 0 and spinClock * e.Spin or 0), 0)
		n += 1
		projParts[n] = e.Part
		projCFrames[n] = cf
	end
	if n > 0 then
		workspace:BulkMoveTo(projParts, projCFrames, Enum.BulkMoveMode.FireCFrameChanged)
	end
end

------------------------------------------------------------------------------------------
-- Enemy hit flashes
------------------------------------------------------------------------------------------

local enemyFolder: Folder? = nil
local enemyBodies: { [number]: BasePart } = {}
local flashing: { [BasePart]: number } = {}

local function enemyBody(id: number): BasePart?
	local body = enemyBodies[id]
	if body and body.Parent then
		return body
	end
	if not enemyFolder then
		enemyFolder = workspace:FindFirstChild("SwarmEnemies") :: Folder?
		if not enemyFolder then
			return nil
		end
	end
	local model = (enemyFolder :: Folder):FindFirstChild("E" .. id)
	body = model and model:FindFirstChild("Body") :: BasePart?
	if body then
		enemyBodies[id] = body
	end
	return body
end

local function flash(id: number)
	local body = enemyBody(id)
	if not body then
		return
	end
	if not flashing[body] then
		body.Color = Color3.new(1, 1, 1)
	end
	flashing[body] = os.clock() + Config.Enemies.HitFlashSeconds
end

local function updateFlashes()
	local now = os.clock()
	for body, untilTime in pairs(flashing) do
		if now >= untilTime then
			flashing[body] = nil
			local base = body:GetAttribute("BaseColor")
			if typeof(base) == "Color3" then
				body.Color = base
			end
		end
	end
end

------------------------------------------------------------------------------------------
-- Effects from FxBatch
------------------------------------------------------------------------------------------

local function deathPoof(x: number, z: number, color: Color3, size: number)
	local p = getEffectPart("Ball")
	p.Color = color
	p.Size = Vector3.one * size
	p.Transparency = 0.2
	p.CFrame = CFrame.new(x, FLOOR_Y + size / 2, z)
	play("Ball", p, 0.3, { Size = Vector3.one * size * 1.8, Transparency = 1 })
end

local function slash(x, z, yaw, length, width, color)
	local p = getEffectPart("Block")
	p.Color = color
	p.Size = Vector3.new(width * 0.6, 0.2, length)
	p.Transparency = 0.15
	p.CFrame = CFrame.new(x, FLOOR_Y + 2.5, z) * CFrame.Angles(0, yaw, 0)
	play("Block", p, 0.22, { Size = Vector3.new(width, 0.05, length * 1.05), Transparency = 1 })
end

local function bolt(x, z, radius)
	local beam = getEffectPart("Cylinder")
	beam.Color = Color3.fromRGB(255, 250, 150)
	beam.Size = Vector3.new(40, 0.8, 0.8)
	beam.CFrame = CFrame.new(x, FLOOR_Y + 20, z) * DISC
	play("Cylinder", beam, 0.25, { Transparency = 1, Size = Vector3.new(40, 0.1, 0.1) })
	local ring = getEffectPart("Cylinder")
	ring.Color = Color3.fromRGB(255, 240, 90)
	ring.Size = Vector3.new(0.2, radius * 2, radius * 2)
	ring.Transparency = 0.3
	ring.CFrame = CFrame.new(x, FLOOR_Y + 0.15, z) * DISC
	play("Cylinder", ring, 0.3, { Transparency = 1 })
end

local function chain(x1, z1, x2, z2)
	local a = Vector3.new(x1, FLOOR_Y + 2, z1)
	local b = Vector3.new(x2, FLOOR_Y + 2, z2)
	local len = (b - a).Magnitude
	if len < 0.1 then
		return
	end
	local p = getEffectPart("Block")
	p.Color = Color3.fromRGB(200, 240, 255)
	p.Size = Vector3.new(0.35, 0.35, len)
	p.CFrame = CFrame.lookAt((a + b) / 2, b)
	play("Block", p, 0.2, { Transparency = 1 })
end

local function pool(x, z, radius, seconds, evo)
	local p = getEffectPart("Cylinder")
	p.Color = evo and Color3.fromRGB(255, 110, 30) or Color3.fromRGB(70, 150, 255)
	p.Size = Vector3.new(0.25, 0.5, 0.5)
	p.Transparency = 0.35
	p.CFrame = CFrame.new(x, FLOOR_Y + 0.12, z) * DISC
	-- grow quickly, hold, then fade
	TweenService:Create(p, TweenInfo.new(0.15), { Size = Vector3.new(0.25, radius * 2, radius * 2) }):Play()
	task.delay(math.max(0.1, seconds - 0.3), function()
		play("Cylinder", p, 0.3, { Transparency = 1 })
	end)
end

local function explosion(x, z, radius)
	local p = getEffectPart("Ball")
	p.Color = Color3.fromRGB(255, 140, 40)
	p.Size = Vector3.one * 2
	p.Transparency = 0.1
	p.CFrame = CFrame.new(x, FLOOR_Y + 1, z)
	play("Ball", p, 0.35, { Size = Vector3.one * radius * 2, Transparency = 1 })
	local root = player.Character and player.Character.PrimaryPart
	if root and (root.Position - Vector3.new(x, root.Position.Y, z)).Magnitude < radius + 25 then
		CameraController.Shake(0.8)
	end
end

local function ring(x, z, radius, color)
	local p = getEffectPart("Cylinder")
	p.Color = color
	p.Size = Vector3.new(0.3, 1, 1)
	p.Transparency = 0.2
	p.CFrame = CFrame.new(x, FLOOR_Y + 0.3, z) * DISC
	play("Cylinder", p, 0.5, { Size = Vector3.new(0.3, radius * 2, radius * 2), Transparency = 1 })
end

local function telegraph(x, z, yaw, length, width, seconds)
	local p = getEffectPart("Block")
	p.Color = Color3.fromRGB(255, 40, 40)
	p.Size = Vector3.new(width, 0.1, length)
	p.Transparency = 0.6
	p.CFrame = CFrame.new(x, FLOOR_Y + 0.1, z) * CFrame.Angles(0, yaw, 0)
	play("Block", p, seconds, { Transparency = 0.95 }, Enum.EasingStyle.Linear)
end

local function characterRoot(userId: number): BasePart?
	local other = Players:GetPlayerByUserId(userId)
	local char = other and other.Character
	return char and char.PrimaryPart
end

local function playerEvent(userId: number, kind: string)
	local root = characterRoot(userId)
	local isLocal = userId == player.UserId
	if kind == "hurt" then
		if isLocal then
			CameraController.Shake(0.35)
			Audio.Play("Hit", 0.7)
		end
	elseif kind == "heal" and root then
		ring(root.Position.X, root.Position.Z, 5, Color3.fromRGB(90, 255, 120))
	elseif kind == "levelup" and root then
		ring(root.Position.X, root.Position.Z, 8, Color3.fromRGB(255, 220, 80))
		if isLocal then
			Audio.Play("LevelUp")
		end
	elseif kind == "die" then
		if root then
			deathPoof(root.Position.X, root.Position.Z, Color3.fromRGB(200, 200, 220), 5)
		end
		if isLocal then
			Audio.Play("Death")
		end
	elseif kind == "revive" and root then
		ring(root.Position.X, root.Position.Z, 12, Color3.fromRGB(255, 240, 150))
	end
	if isLocal and onLocalEvent then
		onLocalEvent(kind)
	end
end

local function onFxBatch(batch)
	if type(batch) ~= "table" then
		return
	end
	if batch.h then
		for _, id in ipairs(batch.h) do
			flash(id)
		end
		Audio.Play("Hit")
	end
	if batch.d then
		for _, d in ipairs(batch.d) do
			deathPoof(d[1], d[2], d[3], d[4])
		end
	end
	if batch.s then
		for _, s in ipairs(batch.s) do
			slash(s[1], s[2], s[3], s[4], s[5], s[6])
		end
	end
	if batch.b then
		for _, b in ipairs(batch.b) do
			bolt(b[1], b[2], b[3])
		end
	end
	if batch.c then
		for _, c in ipairs(batch.c) do
			chain(c[1], c[2], c[3], c[4])
		end
	end
	if batch.p then
		for _, p in ipairs(batch.p) do
			pool(p[1], p[2], p[3], p[4], p[5])
		end
	end
	if batch.e then
		for _, e in ipairs(batch.e) do
			explosion(e[1], e[2], e[3])
		end
	end
	if batch.r then
		for _, r in ipairs(batch.r) do
			ring(r[1], r[2], r[3], r[4])
		end
	end
	if batch.t then
		for _, t in ipairs(batch.t) do
			telegraph(t[1], t[2], t[3], t[4], t[5], t[6])
		end
	end
	if batch.u then
		for _, u in ipairs(batch.u) do
			playerEvent(u[1], u[2])
		end
	end
	if batch.n then
		for _, name in ipairs(batch.n) do
			Audio.Play(name)
			if name == "BossRoar" then
				CameraController.Shake(1.2)
			end
		end
	end
end

------------------------------------------------------------------------------------------
-- Gems (local bob / spin)
------------------------------------------------------------------------------------------

local gemState: { [BasePart]: Vector3 } = {} -- active gem → server base position
local gemParts: { BasePart } = {}
local gemCFrames: { CFrame } = {}

local function trackGem(gem: Instance)
	if not gem:IsA("BasePart") then
		return
	end
	local part = gem :: BasePart
	local function refresh()
		local active = part:GetAttribute("Active") == true
		local base = part:GetAttribute("Base")
		if active and typeof(base) == "Vector3" then
			gemState[part] = base
		else
			local last = gemState[part]
			gemState[part] = nil
			-- collected near me → pickup sound
			local root = player.Character and player.Character.PrimaryPart
			if last and root and (root.Position - last).Magnitude < 8 then
				Audio.Play("GemPickup")
			end
		end
	end
	part:GetAttributeChangedSignal("Active"):Connect(refresh)
	part:GetAttributeChangedSignal("Base"):Connect(refresh)
	refresh()
end

local gemClock = 0
local function renderGems(dt: number)
	gemClock += dt
	table.clear(gemParts)
	table.clear(gemCFrames)
	local n = 0
	for part, base in pairs(gemState) do
		n += 1
		local phase = base.X * 0.37 + base.Z * 0.21
		gemParts[n] = part
		gemCFrames[n] = CFrame.new(base + Vector3.new(0, math.sin(gemClock * 3 + phase) * 0.3, 0)) * CFrame.Angles(0, gemClock * 2 + phase, 0)
	end
	if n > 0 then
		workspace:BulkMoveTo(gemParts, gemCFrames, Enum.BulkMoveMode.FireCFrameChanged)
	end
end

------------------------------------------------------------------------------------------
-- Player decorations: aura rings, HP bars, limb swing
------------------------------------------------------------------------------------------

type Deco = { Ring: Part?, Bar: BillboardGui?, Fill: Frame?, Character: Model? }
local decos: { [Player]: Deco } = {}

local function buildBar(char: Model): (BillboardGui, Frame)
	local gui = Instance.new("BillboardGui")
	gui.Name = "SwarmHP"
	gui.Size = UDim2.fromOffset(60, 8)
	gui.StudsOffset = Vector3.new(0, 4.2, 0)
	gui.AlwaysOnTop = true
	gui.LightInfluence = 0
	gui.ResetOnSpawn = false
	gui.Adornee = char:FindFirstChild("HumanoidRootPart") :: BasePart
	local back = Instance.new("Frame")
	back.Size = UDim2.fromScale(1, 1)
	back.BackgroundColor3 = Color3.fromRGB(30, 10, 10)
	back.BorderSizePixel = 0
	back.Parent = gui
	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, 3)
	corner.Parent = back
	local fill = Instance.new("Frame")
	fill.Name = "Fill"
	fill.Size = UDim2.fromScale(1, 1)
	fill.BackgroundColor3 = Color3.fromRGB(80, 230, 90)
	fill.BorderSizePixel = 0
	fill.Parent = back
	local c2 = Instance.new("UICorner")
	c2.CornerRadius = UDim.new(0, 3)
	c2.Parent = fill
	gui.Parent = fxFolder
	return gui, fill
end

local function updateDecos(_dt: number)
	local t = os.clock()
	for _, other in ipairs(Players:GetPlayers()) do
		local deco = decos[other]
		if not deco then
			deco = {}
			decos[other] = deco
		end
		local char = other.Character
		local root = char and char.PrimaryPart
		local inRun = other:GetAttribute("InRun") == true

		-- HP bar
		if deco.Character ~= char then
			if deco.Bar then
				deco.Bar:Destroy()
				deco.Bar = nil
			end
			deco.Character = char
		end
		if inRun and char and root then
			if not deco.Bar then
				deco.Bar, deco.Fill = buildBar(char)
			end
			local hp = other:GetAttribute("HP") or 0
			local maxHp = math.max(1, other:GetAttribute("MaxHP") or 1)
			local frac = math.clamp(hp / maxHp, 0, 1)
			local fill = deco.Fill :: Frame
			fill.Size = UDim2.fromScale(frac, 1)
			fill.BackgroundColor3 = frac > 0.5 and Color3.fromRGB(80, 230, 90) or (frac > 0.25 and Color3.fromRGB(255, 200, 60) or Color3.fromRGB(255, 70, 70))
			local bar = deco.Bar :: BillboardGui
			bar.Enabled = other:GetAttribute("Alive") ~= false
		elseif deco.Bar then
			deco.Bar.Enabled = false
		end

		-- Garlic aura ring
		local radius = other:GetAttribute("AuraRadius") or 0
		if inRun and root and radius > 0 and other:GetAttribute("Alive") ~= false then
			if not deco.Ring then
				deco.Ring = newPart(Enum.PartType.Cylinder, Color3.fromRGB(240, 240, 190), Enum.Material.Neon, Vector3.one)
			end
			local ringPart = deco.Ring :: Part
			local evo = other:GetAttribute("AuraEvo") == true
			ringPart.Color = evo and Color3.fromRGB(200, 90, 255) or Color3.fromRGB(240, 240, 190)
			local pulse = 1 + math.sin(t * 4) * 0.03
			ringPart.Size = Vector3.new(0.15, radius * 2 * pulse, radius * 2 * pulse)
			ringPart.Transparency = 0.8
			ringPart.CFrame = CFrame.new(root.Position.X, FLOOR_Y + 0.2, root.Position.Z) * DISC
		elseif deco.Ring then
			deco.Ring.CFrame = PARK
		end
	end
	for other, deco in pairs(decos) do
		if not other.Parent then
			if deco.Ring then
				deco.Ring:Destroy()
			end
			if deco.Bar then
				deco.Bar:Destroy()
			end
			decos[other] = nil
		end
	end
end

-- Procedural walk cycle: swing arms/legs from the root's speed (no animation assets).
local swingClock = 0
local function animateLimbs(dt: number)
	swingClock += dt
	for _, other in ipairs(Players:GetPlayers()) do
		local char = other.Character
		local root = char and char.PrimaryPart
		local torso = char and char:FindFirstChild("Torso")
		if root and torso then
			local speed = (root.AssemblyLinearVelocity * Vector3.new(1, 0, 1)).Magnitude
			local amount = math.clamp(speed / 16, 0, 1) * 0.8
			local swing = math.sin(swingClock * 10) * amount
			local function set(name: string, angle: number)
				local m = torso:FindFirstChild(name)
				if m and m:IsA("Motor6D") then
					m.Transform = CFrame.Angles(angle, 0, 0)
				end
			end
			set("Left Shoulder", swing)
			set("Right Shoulder", -swing)
			set("Left Hip", -swing)
			set("Right Hip", swing)
		end
	end
end

------------------------------------------------------------------------------------------
-- Init
------------------------------------------------------------------------------------------

function VFX.Init(opts: { OnLocalEvent: ((string) -> ())? }?)
	onLocalEvent = opts and opts.OnLocalEvent or nil
	fxFolder = Instance.new("Folder")
	fxFolder.Name = "SwarmClientFx"
	fxFolder.Parent = workspace

	Remotes.Get("ProjectileBatch").OnClientEvent:Connect(onProjectileBatch)
	Remotes.Get("FxBatch").OnClientEvent:Connect(onFxBatch)

	task.spawn(function()
		local gems = workspace:WaitForChild("SwarmGems")
		gems.ChildAdded:Connect(trackGem)
		for _, g in ipairs(gems:GetChildren()) do
			trackGem(g)
		end
	end)

	RunService.RenderStepped:Connect(function(dt)
		renderProjectiles(dt)
		renderGems(dt)
		updateFlashes()
		updateDecos(dt)
	end)
	RunService.PreSimulation:Connect(animateLimbs)
end

return VFX
