--[[
	HitFeel.lua (feature 27, Config.Features.HitFeel; docs/features/FEEL.md)
	Client-only weight on top of VFX / CombatFx, read from the same FxBatch remote:
	  * Hit-stop: on a crit near the local hero or a huge kill (boss / large elite,
	    Config.Graphics.CombatFx.HugeKillSize) the camera holds still for StopSeconds
	    (<= 40 ms), then carries on. It is a visual freeze of the view only: the server, the
	    enemies and the controls never stop. At most MaxPerSecond in any second, MinGap apart.
	  * Death burst: a few chunks in the creature's colour fly out of a dead enemy, tumble,
	    land and fade. Pooled parts (no Instance churn once warm), MaxPieces alive, a token
	    bucket (PiecesPerSecond), only within BurstRange of the hero, BurstsPerBatch per batch.
	Reduced effects: no hit-stop; bursts only for big kills, with fewer chunks. Screen shake
	0 also turns the hit-stop off. Nothing here flashes.
]]

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")

local Shared = game:GetService("ReplicatedStorage"):WaitForChild("Shared")
local Config = require(Shared:WaitForChild("Config"))
local Remotes = require(Shared:WaitForChild("Remotes"))
local ClientSettings = require(script.Parent.ClientSettings)
local EnemyRenderer = require(script.Parent.EnemyRenderer)

local HitFeel = {}

local player = Players.LocalPlayer
local H = Config.Feel.HitFeel
local CFX = (Config.Graphics :: any).CombatFx or {}
local BIG: number = CFX.BigKillSize or 4.6
local HUGE: number = CFX.HugeKillSize or 9.5
local MAX_STOP = 0.04
local PARK = CFrame.new(0, -150, 0)
local FLOOR_Y = Config.ArenaOrigin.Y
local TAU = math.pi * 2

local folder: Folder? = nil
local pool: { BasePart } = {}
type Piece = { Part: BasePart, Start: number, Life: number, From: Vector3, Vel: Vector3, Spin: Vector3, Size: Vector3 }
local pieces: { Piece } = {}
local spare: { Piece } = {}
local tokens = 0
local stops: { number } = {} -- start times of recent hit-stops
local holdUntil = 0
local holdCF: CFrame? = nil
local holdFocus: CFrame? = nil
local holdFov = 70
local wantHold = false
local stats = { Stops = 0, StopsSkipped = 0, Bursts = 0, Pieces = 0, PiecesSkipped = 0, PoolSize = 0, Alive = 0, Peak = 0 }

local moveParts: { BasePart } = {}
local moveCFrames: { CFrame } = {}

local function on(): boolean
	return Config.FeatureOn("HitFeel")
end

local function heroPos(): Vector3?
	local char = player.Character
	local root = char and char.PrimaryPart
	return root and root.Position
end

local function near(x: number, z: number, range: number): boolean
	local hp = heroPos()
	if not hp then
		return false
	end
	local dx, dz = x - hp.X, z - hp.Z
	return dx * dx + dz * dz <= range * range
end

------------------------------------------------------------------------------------------
-- Hit-stop
------------------------------------------------------------------------------------------

-- Asks for a hit-stop now; true when one starts (caps: MaxPerSecond, MinGap, settings).
function HitFeel.Stop(): boolean
	if not on() or player:GetAttribute("InRun") ~= true then
		return false
	end
	if ClientSettings.Reduced() or (tonumber(ClientSettings.Get("Shake")) or 1) <= 0 then
		return false
	end
	local now = os.clock()
	for i = #stops, 1, -1 do
		if now - stops[i] > 1 then
			table.remove(stops, i)
		end
	end
	local last = stops[#stops]
	if #stops >= H.MaxPerSecond or (last and now - last < H.MinGap) then
		stats.StopsSkipped += 1
		return false
	end
	table.insert(stops, now)
	holdUntil = now + math.min(H.StopSeconds, MAX_STOP)
	holdCF = nil -- captured on the next camera frame
	wantHold = true
	stats.Stops += 1
	return true
end

-- True while the view is held.
function HitFeel.Holding(): boolean
	return os.clock() < holdUntil
end

local function stepHold()
	if os.clock() >= holdUntil then
		if wantHold then
			wantHold = false
			holdCF = nil
		end
		return
	end
	local cam = workspace.CurrentCamera
	if not cam then
		return
	end
	if not holdCF then
		holdCF = cam.CFrame
		holdFocus = cam.Focus
		holdFov = cam.FieldOfView
		return
	end
	cam.CFrame = holdCF :: CFrame
	cam.Focus = holdFocus :: CFrame
	cam.FieldOfView = holdFov
end

------------------------------------------------------------------------------------------
-- Death burst
------------------------------------------------------------------------------------------

local function newPart(): BasePart
	local p = Instance.new("Part")
	p.Anchored = true
	p.CanCollide = false
	p.CanQuery = false
	p.CanTouch = false
	p.CastShadow = false
	p.Material = Enum.Material.SmoothPlastic
	p.TopSurface = Enum.SurfaceType.Smooth
	p.BottomSurface = Enum.SurfaceType.Smooth
	p.CFrame = PARK
	p.Parent = folder
	stats.PoolSize += 1
	return p
end

-- Chunks out of an enemy that died at (x, z): colour, size = its death size (studs).
function HitFeel.Burst(x: number, z: number, color: Color3, size: number): number
	if not on() or not folder then
		return 0
	end
	local big = size >= BIG
	local reduced = ClientSettings.Reduced()
	if reduced and not big then
		return 0
	end
	local n = H.Pieces * (big and 2 or 1)
	if reduced then
		n = math.max(2, math.floor(n / 3))
	end
	n = math.min(n, math.floor(tokens), H.MaxPieces - #pieces)
	if n <= 0 then
		stats.PiecesSkipped += 1
		return 0
	end
	tokens -= n
	local now = os.clock()
	local r = math.clamp(size, 1.5, 12)
	local chunk = math.clamp(r * 0.22, 0.35, 1.6)
	local from = Vector3.new(x, FLOOR_Y + r * 0.45, z)
	local dark = color:Lerp(Color3.new(0, 0, 0), 0.25)
	for i = 1, n do
		local p = table.remove(pool) or newPart()
		local a = (i / n) * TAU + math.random() * 0.6
		local speed = (9 + math.random() * 8) * math.clamp(r / 3, 0.8, 1.8)
		local vel = Vector3.new(math.cos(a) * speed, 14 + math.random() * 10, math.sin(a) * speed)
		local s = Vector3.new(chunk, chunk * (0.6 + math.random() * 0.5), chunk * (0.7 + math.random() * 0.6))
		p.Color = i % 3 == 0 and dark or color
		p.Size = s
		p.Transparency = 0
		local pc: Piece = table.remove(spare) or ({} :: any)
		pc.Part = p
		pc.Start = now
		pc.Life = H.Life * (0.8 + math.random() * 0.4)
		pc.From = from
		pc.Vel = vel
		pc.Spin = Vector3.new(math.random() * 14 - 7, math.random() * 14 - 7, math.random() * 14 - 7)
		pc.Size = s
		pieces[#pieces + 1] = pc
	end
	stats.Bursts += 1
	stats.Pieces += n
	stats.Peak = math.max(stats.Peak, #pieces)
	return n
end

local function stepPieces(now: number)
	local n = 0
	local i = 1
	local g = H.Gravity
	while i <= #pieces do
		local pc = pieces[i]
		local t = now - pc.Start
		if t >= pc.Life then
			local p = pc.Part
			p.CFrame = PARK
			table.insert(pool, p)
			pieces[i] = pieces[#pieces]
			pieces[#pieces] = nil
			spare[#spare + 1] = pc
		else
			local pos = pc.From + pc.Vel * t - Vector3.new(0, 0.5 * g * t * t, 0)
			local floor = FLOOR_Y + pc.Size.Y * 0.5
			local spin = pc.Spin * t
			if pos.Y < floor then
				-- landed: rests on the floor, stops tumbling
				pos = Vector3.new(pos.X, floor, pos.Z)
				spin = Vector3.new(0, spin.Y, 0)
			end
			local u = t / pc.Life
			if u > 0.6 then
				local k = (u - 0.6) / 0.4
				pc.Part.Transparency = k
				pc.Part.Size = pc.Size * (1 - 0.5 * k)
			end
			n += 1
			moveParts[n] = pc.Part
			moveCFrames[n] = CFrame.new(pos) * CFrame.Angles(spin.X, spin.Y, spin.Z)
			i += 1
		end
	end
	for k = #moveParts, n + 1, -1 do
		moveParts[k] = nil
		moveCFrames[k] = nil
	end
	if n > 0 then
		workspace:BulkMoveTo(moveParts, moveCFrames, Enum.BulkMoveMode.FireCFrameChanged)
	end
	stats.Alive = #pieces
end

-- Parks every chunk (run end / travel / switch off).
function HitFeel.Clear()
	for _, pc in ipairs(pieces) do
		pc.Part.CFrame = PARK
		table.insert(pool, pc.Part)
		spare[#spare + 1] = pc
	end
	table.clear(pieces)
	holdUntil = 0
	holdCF = nil
	wantHold = false
end

function HitFeel.Stats(): { [string]: number }
	return table.clone(stats)
end

------------------------------------------------------------------------------------------
-- FxBatch
------------------------------------------------------------------------------------------

local function onBatch(batch)
	if type(batch) ~= "table" or not on() or player:GetAttribute("InRun") ~= true then
		return
	end
	local stop = false
	if type(batch.d) == "table" then
		local bursts = 0
		for _, d in ipairs(batch.d) do
			if type(d) == "table" and type(d[1]) == "number" and type(d[2]) == "number" then
				local size = tonumber(d[4]) or 2.5
				if size >= HUGE and near(d[1], d[2], H.BurstRange) then
					stop = true
				end
				if bursts < H.BurstsPerBatch and near(d[1], d[2], H.BurstRange) then
					local color = typeof(d[3]) == "Color3" and d[3] or Color3.fromRGB(150, 140, 130)
					if HitFeel.Burst(d[1], d[2], color, size) > 0 then
						bursts += 1
					end
				end
			end
		end
	end
	if not stop and type(batch.k) == "table" and #batch.k > 0 then
		-- crits: only when one is near the local hero (the enemy's body position)
		for i, id in ipairs(batch.k) do
			if i > 4 then
				break
			end
			local pos = type(id) == "number" and EnemyRenderer.Position(id)
			if pos and near(pos.X, pos.Z, H.CritRange) then
				stop = true
				break
			end
		end
	end
	if stop then
		HitFeel.Stop()
	end
end

function HitFeel.Init()
	local f = Instance.new("Folder")
	f.Name = "SwarmHitFeel"
	f.Parent = workspace
	folder = f
	tokens = H.MaxPieces
	Remotes.Get("FxBatch").OnClientEvent:Connect(onBatch)
	player:GetAttributeChangedSignal("InRun"):Connect(function()
		if player:GetAttribute("InRun") ~= true then
			HitFeel.Clear()
		end
	end)
	RunService.RenderStepped:Connect(function(dt)
		if #pieces == 0 and tokens >= H.MaxPieces then
			return
		end
		tokens = math.min(H.MaxPieces, tokens + H.PiecesPerSecond * math.min(dt, 0.25))
		stepPieces(os.clock())
	end)
	-- after SwarmCamera and SwarmBossIntro: holds the view they placed
	RunService:BindToRenderStep("SwarmHitStop", Enum.RenderPriority.Camera.Value + 3, function()
		if wantHold then
			stepHold()
		end
	end)
end

return HitFeel
