--[[
	WorldFx.lua
	Client side of MAP EVENTS (feature 2) and WEATHER (feature 9), docs/features/EVENTS.md.
	The server decides everything (WorldEvents.lua, Weather.lua); this module only draws
	what workspace.WorldFx's attributes say:

	  MapEvent      "Meteor" | "GoldRush" | "Fog" | nil: a headline through UIState's
	                headline lane when it starts, and a countdown badge (FeatureHud) while
	                it runs (MapEventLeft, whole seconds).
	  Meteor parts  children named "Meteor" (attribute Land = seconds to impact): a fireball
	                falls onto the warning ring the Telegraphs module already draws.
	  Fog           EnemyRenderer.HideFilter keeps normal enemies hidden beyond FogRadius
	                studs of every living run player (bosses, elites, telegraphs, pickups,
	                projectiles and the minimap stay), and a soft mist rings the screen
	                around the hero (dims, never hides).
	  World / Storm the ambient particles of the arena (Config.Weather.Ambient) around the
	                camera focus, a notice and a SNOW STORM badge in a storm.

	Reduced effects (ClientSettings): no decorative particles, a lighter snowfall, no
	meteor light, a lighter mist. Nothing here shows outside a run.
]]

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")

local Shared = game:GetService("ReplicatedStorage"):WaitForChild("Shared")
local Config = require(Shared:WaitForChild("Config"))
local Palette = require(Shared:WaitForChild("Palette"))
local ClientSettings = require(script.Parent.ClientSettings)
local EnemyRenderer = require(script.Parent.EnemyRenderer)
local FeatureHud = require(script.Parent.FeatureHud)
local UIState = require(script.Parent.UIState)

local WorldFx = {}

local P = Palette :: { [string]: Color3 }
local player = Players.LocalPlayer

local EVENTS = {
	Meteor = { Title = "METEOR SHOWER", Sub = "Step out of the red rings", Badge = "METEORS", Class = "Critical", Sound = "WaveHorn", Color = P.amber_500 },
	GoldRush = { Title = "GOLD RUSH", Sub = "More gold from kills for a minute", Badge = "GOLD RUSH", Class = "Info", Sound = "Coin", Color = P.gold_300 },
	Fog = { Title = "FOG ROLLS IN", Sub = "Enemies hide in the mist", Badge = "FOG", Class = "Info", Sound = "Tip", Color = P.ice_300 },
}
local WEATHER_NOTE = {
	Snow = "Snow storm: everyone moves slower",
	Lava = "Eruptions: glowing ground bursts into fire",
}

local folder: Instance? = nil
local fxFolder: Folder? = nil
local current: string? = nil -- the map event shown
local world: string? = nil -- the weather set up
local emitterPart: BasePart? = nil
local emitter: ParticleEmitter? = nil
local emitterKind: string? = nil
local falling: { { Part: BasePart, Light: PointLight?, From: Vector3, To: Vector3, T: number, Land: number } } = {}
local fog = { On = false, Alpha = 0, Radius = 42, Gui = nil :: ScreenGui?, Rings = {} :: { { Frame: Frame, Stroke: UIStroke, Scale: number, Alpha: number } } }
local fogPoints: { Vector3 } = {}

local function inRun(): boolean
	return player:GetAttribute("InRun") == true
end

local function attr(name: string): any
	return folder and folder:GetAttribute(name)
end

------------------------------------------------------------------------------------------
-- Ambient particles (Config.Weather.Ambient)
------------------------------------------------------------------------------------------

local function seq(a: number, b: number?): NumberSequence
	return NumberSequence.new(a, b or a)
end

local function styleEmitter(e: ParticleEmitter, kind: string)
	e.LightInfluence = 0.6
	e.LightEmission = 0
	e.SpreadAngle = Vector2.new(12, 12)
	e.Acceleration = Vector3.zero
	e.Rotation = NumberRange.new(0, 360)
	e.RotSpeed = NumberRange.new(0, 0)
	e.EmissionDirection = Enum.NormalId.Bottom
	if kind == "Snow" then
		e.Color = ColorSequence.new(P.ice_100)
		e.Size = seq(0.32, 0.22)
		e.Transparency = NumberSequence.new({ NumberSequenceKeypoint.new(0, 1), NumberSequenceKeypoint.new(0.15, 0.15), NumberSequenceKeypoint.new(1, 0.3) })
		e.Lifetime = NumberRange.new(3.2, 4.2)
		e.Speed = NumberRange.new(7, 10)
		e.Acceleration = Vector3.new(3, 0, 1)
	elseif kind == "Embers" then
		e.Color = ColorSequence.new(P.amber_500, P.crimson_400)
		e.LightEmission = 1
		e.LightInfluence = 0
		e.Size = seq(0.22, 0.05)
		e.Transparency = seq(0.1, 0.8)
		e.Lifetime = NumberRange.new(2, 3.4)
		e.Speed = NumberRange.new(3, 6)
		e.EmissionDirection = Enum.NormalId.Top
	elseif kind == "Leaves" then
		e.Color = ColorSequence.new(P.moss_300, P.gold_500)
		e.Size = seq(0.4)
		e.Transparency = seq(0.2, 0.6)
		e.Lifetime = NumberRange.new(6, 8)
		e.Speed = NumberRange.new(2, 3.5)
		e.RotSpeed = NumberRange.new(-90, 90)
		e.Acceleration = Vector3.new(2, -0.5, 0)
	elseif kind == "Dust" then
		e.Color = ColorSequence.new(P.dirt_300)
		e.Size = seq(0.35, 0.6)
		e.Transparency = seq(0.5, 1)
		e.Lifetime = NumberRange.new(4, 6)
		e.Speed = NumberRange.new(1, 2)
		e.Acceleration = Vector3.new(6, 0, 1)
	else -- Motes: slow pale specks of light
		e.Color = ColorSequence.new(P.gold_200)
		e.LightEmission = 0.8
		e.Size = seq(0.16, 0.1)
		e.Transparency = NumberSequence.new({ NumberSequenceKeypoint.new(0, 1), NumberSequenceKeypoint.new(0.5, 0.3), NumberSequenceKeypoint.new(1, 1) })
		e.Lifetime = NumberRange.new(5, 7)
		e.Speed = NumberRange.new(0.5, 1.5)
		e.SpreadAngle = Vector2.new(60, 60)
	end
end

-- The particle rate for `kind` now (0 = off), Reduced effects applied.
local function rateFor(def: any): number
	if not def or not def.Kind then
		return 0
	end
	if ClientSettings.Reduced() then
		return def.Kind == "Snow" and def.Rate * 0.4 or 0
	end
	return def.Rate
end
WorldFx._RateFor = rateFor

local function applyAmbient()
	local def = world and (Config.Weather.Ambient :: any)[world] or nil
	local rate = (inRun() and Config.FeatureOn("Weather")) and rateFor(def) or 0
	if rate <= 0 then
		if emitter then
			emitter.Enabled = false
		end
		return
	end
	if not emitterPart then
		local p = Instance.new("Part")
		p.Name = "WeatherEmitter"
		p.Anchored = true
		p.CanCollide = false
		p.CanQuery = false
		p.CanTouch = false
		p.Transparency = 1
		p.Size = Vector3.new(120, 1, 96)
		p.Parent = fxFolder
		emitterPart = p
		local e = Instance.new("ParticleEmitter")
		e.Parent = p
		emitter = e
	end
	local e = emitter :: ParticleEmitter
	if emitterKind ~= def.Kind then
		emitterKind = def.Kind
		styleEmitter(e, def.Kind)
	end
	e.Rate = rate
	e.Enabled = true
end

------------------------------------------------------------------------------------------
-- Fog
------------------------------------------------------------------------------------------

local function buildFog()
	if fog.Gui then
		return
	end
	local gui = Instance.new("ScreenGui")
	gui.Name = "WorldFxFog"
	gui.ResetOnSpawn = false
	gui.IgnoreGuiInset = true
	gui.DisplayOrder = 0 -- over the world, under every HUD / panel
	gui.Enabled = false
	gui.Parent = player:WaitForChild("PlayerGui")
	-- three soft rings: a circle with a huge outside stroke = mist everywhere but the hole
	for i, ring in ipairs({ { 1, 0.86 }, { 1.18, 0.84 }, { 1.4, 0.8 } }) do
		local f = Instance.new("Frame")
		f.Name = "Mist" .. i
		f.AnchorPoint = Vector2.new(0.5, 0.5)
		f.BackgroundTransparency = 1
		f.BorderSizePixel = 0
		f.Parent = gui
		local corner = Instance.new("UICorner")
		corner.CornerRadius = UDim.new(0.5, 0)
		corner.Parent = f
		local s = Instance.new("UIStroke")
		s.Color = P.ice_300:Lerp(P.slate_500, 0.35)
		s.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
		s.Thickness = 2400
		s.Transparency = 1
		s.Parent = f
		table.insert(fog.Rings, { Frame = f, Stroke = s, Scale = ring[1], Alpha = ring[2] })
	end
	fog.Gui = gui
end

local function fogFilter(pos: Vector3, shown: boolean): boolean
	local r = fog.Radius + (shown and (Config.WorldEvents.Fog.Hysteresis or 0) or 0)
	local r2 = r * r
	for _, p in ipairs(fogPoints) do
		local dx, dz = pos.X - p.X, pos.Z - p.Z
		if dx * dx + dz * dz <= r2 then
			return false
		end
	end
	return #fogPoints > 0 -- (no living player known: show everything)
end
WorldFx._FogFilter = fogFilter

local function setFog(on: boolean)
	fog.On = on
	fog.Radius = tonumber(attr("FogRadius")) or Config.WorldEvents.Fog.Radius
	if on then
		buildFog()
		EnemyRenderer.HideFilter = fogFilter
	elseif EnemyRenderer.HideFilter == fogFilter then
		EnemyRenderer.HideFilter = nil
	end
end

local function stepFog(dt: number)
	-- the living run players' floor points (the hide test)
	table.clear(fogPoints)
	if fog.On then
		for _, plr in ipairs(Players:GetPlayers()) do
			local char = plr.Character
			local root = char and char:FindFirstChild("HumanoidRootPart")
			if root and root:IsA("BasePart") and plr:GetAttribute("InRun") == true and plr:GetAttribute("Alive") ~= false then
				table.insert(fogPoints, root.Position)
			end
		end
	end
	local target = (fog.On and inRun()) and 1 or 0
	fog.Alpha += math.clamp(target - fog.Alpha, -dt, dt) -- a one-second fade
	local gui = fog.Gui
	if not gui then
		return
	end
	gui.Enabled = fog.Alpha > 0.001
	if not gui.Enabled then
		return
	end
	local cam = workspace.CurrentCamera
	local char = player.Character
	local root = char and char:FindFirstChild("HumanoidRootPart")
	if not (cam and root and root:IsA("BasePart")) then
		return
	end
	local floor = Vector3.new(root.Position.X, Config.ArenaOrigin.Y, root.Position.Z)
	local c = cam:WorldToViewportPoint(floor)
	local e = cam:WorldToViewportPoint(floor + Vector3.new(fog.Radius, 0, 0))
	local px = math.max(40, math.abs(e.X - c.X))
	local light = ClientSettings.Reduced() and 0.06 or 0
	for _, ring in ipairs(fog.Rings) do
		local d = px * 2 * ring.Scale
		ring.Frame.Position = UDim2.fromOffset(c.X, c.Y)
		ring.Frame.Size = UDim2.fromOffset(d, d)
		ring.Stroke.Transparency = 1 - (1 - ring.Alpha - light) * fog.Alpha
	end
end

------------------------------------------------------------------------------------------
-- Meteors
------------------------------------------------------------------------------------------

local function addMeteor(marker: Instance)
	if not marker:IsA("BasePart") or marker.Name ~= "Meteor" then
		return
	end
	local land = tonumber(marker:GetAttribute("Land")) or 1.2
	local to = marker.Position + Vector3.new(0, 1, 0)
	local from = to + Vector3.new(-22, 70, -14)
	local ball = Instance.new("Part")
	ball.Name = "Fireball"
	ball.Shape = Enum.PartType.Ball
	ball.Anchored = true
	ball.CanCollide = false
	ball.CanQuery = false
	ball.CanTouch = false
	ball.CastShadow = false
	ball.Material = Enum.Material.Neon
	ball.Color = P.amber_500:Lerp(P.crimson_400, 0.35)
	ball.Size = Vector3.new(3.2, 3.2, 3.2)
	ball.CFrame = CFrame.new(from)
	ball.Parent = fxFolder
	local light: PointLight? = nil
	if not ClientSettings.Reduced() then
		local l = Instance.new("PointLight")
		l.Color = P.amber_500
		l.Range = 16
		l.Brightness = 2
		l.Parent = ball
		light = l
	end
	table.insert(falling, { Part = ball, Light = light, From = from, To = to, T = 0, Land = math.max(0.3, land) })
end

local function stepMeteors(dt: number)
	for i = #falling, 1, -1 do
		local m = falling[i]
		m.T += dt
		local a = math.clamp(m.T / m.Land, 0, 1)
		m.Part.CFrame = CFrame.new(m.From:Lerp(m.To, a * a)) -- speeding up as it falls
		if a >= 1 then
			m.Part:Destroy()
			table.remove(falling, i)
		end
	end
end

------------------------------------------------------------------------------------------
-- Events and weather state
------------------------------------------------------------------------------------------

local function updateBadges()
	local show = inRun()
	local def = current and EVENTS[current]
	if show and def then
		local left = tonumber(attr("MapEventLeft"))
		FeatureHud.Badge("mapevent", { Text = left and string.format("%s %ds", def.Badge, left) or def.Badge, Color = def.Color, Order = 20 })
	else
		FeatureHud.RemoveBadge("mapevent")
	end
	if show and attr("Storm") == true and Config.FeatureOn("Weather") then
		FeatureHud.Badge("weather", { Text = "SNOW STORM", Color = P.ice_100, Order = 21 })
	else
		FeatureHud.RemoveBadge("weather")
	end
end

local function onEvent()
	local kind = attr("MapEvent")
	if type(kind) ~= "string" or not EVENTS[kind] then
		kind = nil
	end
	if kind == current then
		return
	end
	current = kind
	setFog(kind == "Fog")
	if kind and inRun() then
		local def = EVENTS[kind]
		UIState.Headline({ Id = "event." .. string.lower(kind), Title = def.Title, Sub = def.Sub, Color = def.Color, Sound = def.Sound, Class = def.Class, Prefer = true, Expire = 5 })
	end
	updateBadges()
end

local function onWorld()
	local w = attr("World")
	w = type(w) == "string" and w or nil
	if w ~= world then
		world = w
		local note = w and WEATHER_NOTE[w]
		if note and inRun() and Config.FeatureOn("Weather") then
			UIState.Notice({ Id = "weather." .. string.lower(w :: string), Text = note, Class = "Info" })
		end
	end
	applyAmbient()
	updateBadges()
end

local function step(dt: number)
	stepMeteors(dt)
	stepFog(dt)
	local p = emitterPart
	if p and emitter and emitter.Enabled then
		local char = player.Character
		local root = char and char:FindFirstChild("HumanoidRootPart")
		if root and root:IsA("BasePart") then
			local y = emitterKind == "Embers" and Config.ArenaOrigin.Y + 0.6 or root.Position.Y + 26
			p.CFrame = CFrame.new(root.Position.X, y, root.Position.Z)
		end
	end
end

function WorldFx.Init()
	local f = Instance.new("Folder")
	f.Name = "WorldFxClient"
	f.Parent = workspace
	fxFolder = f
	task.spawn(function()
		local src = workspace:WaitForChild("WorldFx")
		folder = src
		src:GetAttributeChangedSignal("MapEvent"):Connect(onEvent)
		src:GetAttributeChangedSignal("MapEventLeft"):Connect(updateBadges)
		src:GetAttributeChangedSignal("FogRadius"):Connect(function()
			fog.Radius = tonumber(attr("FogRadius")) or fog.Radius
		end)
		src:GetAttributeChangedSignal("World"):Connect(onWorld)
		src:GetAttributeChangedSignal("Storm"):Connect(updateBadges)
		src.ChildAdded:Connect(addMeteor)
		onEvent()
		onWorld()
	end)
	player:GetAttributeChangedSignal("InRun"):Connect(function()
		applyAmbient()
		updateBadges()
	end)
	ClientSettings.OnChanged(function(key)
		if key == "ReducedEffects" then
			applyAmbient()
		end
	end)
	RunService.RenderStepped:Connect(step)
end

-- Tests: the module's state.
function WorldFx.State(): { [string]: any }
	return {
		Event = current,
		World = world,
		Fog = fog.On,
		FogAlpha = fog.Alpha,
		Emitter = emitter and emitter.Enabled and emitterKind or nil,
		Rate = emitter and emitter.Enabled and emitter.Rate or 0,
		Falling = #falling,
	}
end

return WorldFx
