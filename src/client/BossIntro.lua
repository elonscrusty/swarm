--[[
	BossIntro.lua (feature 10, Config.Features.BossIntro; docs/features/FEEL.md)
	When a boss arrives (SwarmState BossName set) or enters a new phase (BossPhase counts
	up), the local client:
	  * shows a name card through UIState's headline lane, under the same semantic id the
	    server's banner uses ("boss.arrive", "big:<phase message>"), so the two merge into
	    one banner (this one adds the "STAGE N BOSS" / "PHASE 2" line);
	  * solo: slides the camera a little toward the boss and in (Config.Feel.BossIntro, at
	    most 1.2 s, eased in and out). Only the camera position moves: its angle, and with it
	    the camera-relative controls, never change, and the hero stays on screen;
	  * co-op (another player in the run): no camera move at all, only a short zoom (field
	    of view) and a dark vignette, so nobody loses sight of their hero;
	  * Reduced effects or Screen shake 0: the card only.
	The world never pauses and nothing here touches damage or input.
]]

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")

local Shared = game:GetService("ReplicatedStorage"):WaitForChild("Shared")
local Config = require(Shared:WaitForChild("Config"))
local Remotes = require(Shared:WaitForChild("Remotes"))
local BossData = require(Shared:WaitForChild("BossData"))
local EnemyData = require(Shared:WaitForChild("EnemyData"))
local ClientSettings = require(script.Parent.ClientSettings)
local UIState = require(script.Parent.UIState)

local BossIntro = {}

local player = Players.LocalPlayer
local B = Config.Feel.BossIntro
local MAX_SECONDS = 1.2
local PARKED_Y = -100
local CRIMSON = Color3.fromRGB(255, 90, 80)

-- the running intro: Mode "Push" (solo camera) | "Zoom" (co-op), when it started, the boss body
local active: { Mode: string, Start: number, Dur: number, Body: BasePart?, NextSearch: number? }? = nil
local vignette: { Gui: ScreenGui, Strips: { Frame } }? = nil
local stats = { Cards = 0, Pushes = 0, Zooms = 0, CardOnly = 0, MaxOffset = 0 }

local function on(): boolean
	return Config.FeatureOn("BossIntro")
end

-- Reduced motion: Reduced effects, or the Screen shake setting at 0.
local function reducedMotion(): boolean
	return ClientSettings.Reduced() or (tonumber(ClientSettings.Get("Shake")) or 1) <= 0
end

-- Another player in this run (co-op): the camera must not move.
local function coop(): boolean
	for _, p in ipairs(Players:GetPlayers()) do
		if p ~= player and p:GetAttribute("InRun") == true then
			return true
		end
	end
	return false
end

-- The live boss body (EnemyData IsBoss), like MiniMap finds it.
local function findBoss(): BasePart?
	local folder = workspace:FindFirstChild("SwarmEnemies")
	if not folder then
		return nil
	end
	for _, m in ipairs(folder:GetChildren()) do
		local body = m:FindFirstChild("Body")
		if body and body:IsA("BasePart") and body.Position.Y > PARKED_Y then
			local typeId = body:GetAttribute("Type")
			local def = type(typeId) == "string" and EnemyData.Enemies[typeId] or nil
			if def and def.IsBoss then
				return body
			end
		end
	end
	return nil
end

-- 0..1 envelope: smooth in over In, hold, smooth out over Out.
local function envelope(t: number, dur: number): number
	if t <= 0 or t >= dur then
		return 0
	end
	local inT = math.min(B.In, dur / 2)
	local outT = math.min(B.Out, dur / 2)
	local w = 1
	if t < inT then
		w = t / inT
	elseif t > dur - outT then
		w = (dur - t) / outT
	end
	return w * w * (3 - 2 * w)
end

local function buildVignette()
	local gui = Instance.new("ScreenGui")
	gui.Name = "SwarmBossVignette"
	gui.IgnoreGuiInset = true
	gui.ScreenInsets = Enum.ScreenInsets.None
	gui.ResetOnSpawn = false
	gui.DisplayOrder = 1 -- over the world, under the HUD
	gui.Enabled = false
	local strips = {}
	local sides = {
		{ Vector2.new(0, 0), UDim2.fromScale(0, 0), UDim2.fromScale(1, 0.22), 90 },
		{ Vector2.new(0, 1), UDim2.fromScale(0, 1), UDim2.fromScale(1, 0.22), -90 },
		{ Vector2.new(0, 0), UDim2.fromScale(0, 0), UDim2.fromScale(0.16, 1), 0 },
		{ Vector2.new(1, 0), UDim2.fromScale(1, 0), UDim2.fromScale(0.16, 1), 180 },
	}
	for _, sd in ipairs(sides) do
		local f = Instance.new("Frame")
		f.AnchorPoint = sd[1]
		f.Position = sd[2]
		f.Size = sd[3]
		f.BorderSizePixel = 0
		f.BackgroundColor3 = Color3.new(0, 0, 0)
		f.BackgroundTransparency = 1
		f.Active = false
		local g = Instance.new("UIGradient")
		g.Rotation = sd[4]
		g.Transparency = NumberSequence.new({ NumberSequenceKeypoint.new(0, 0), NumberSequenceKeypoint.new(1, 1) })
		g.Parent = f
		f.Parent = gui
		table.insert(strips, f)
	end
	gui.Parent = player:WaitForChild("PlayerGui")
	vignette = { Gui = gui, Strips = strips }
end

local function setVignette(alpha: number)
	if alpha <= 0.001 then
		if vignette and vignette.Gui.Enabled then
			vignette.Gui.Enabled = false
		end
		return
	end
	if not vignette then
		buildVignette()
	end
	local v = vignette :: any
	v.Gui.Enabled = true
	for _, f in ipairs(v.Strips) do
		f.BackgroundTransparency = 1 - alpha
	end
end

-- The name card (headline lane). kind = "arrive" | "phase".
local function card(kind: string, phase: number)
	local state = Remotes.State()
	local id = state:GetAttribute("BossId")
	local def = type(id) == "string" and BossData.Bosses[id] or nil
	local name = string.upper(tostring(state:GetAttribute("BossName") or (def and def.DisplayName) or "BOSS"))
	local item
	if kind == "arrive" then
		local stage = tonumber(state:GetAttribute("Stage"))
		item = {
			Id = "boss.arrive",
			Title = def and def.Title or name,
			Sub = stage and string.format("STAGE %d BOSS · %s", stage, name) or name,
			Color = CRIMSON,
			Class = "Critical",
			Prefer = true,
		}
	else
		local p = def and def.Phases and def.Phases[phase]
		local message = p and p.Message
		local sub = string.format("PHASE %d", phase)
		if p and type(p.Name) == "string" and p.Name ~= "" then
			sub ..= " · " .. string.upper(p.Name)
		end
		item = {
			Id = message and ("big:" .. string.lower(message)) or ("boss.phase." .. tostring(phase)),
			Title = message or name,
			Sub = sub,
			Color = CRIMSON,
			Class = "Critical",
			Prefer = true,
		}
	end
	UIState.Headline(item)
	stats.Cards += 1
end

-- Starts the intro for an arrival or a phase change.
function BossIntro.Trigger(kind: string, phase: number?)
	if not on() or player:GetAttribute("InRun") ~= true then
		return
	end
	card(kind, phase or 1)
	if reducedMotion() or UIState.Covered() then
		stats.CardOnly += 1
		return
	end
	local dur = math.min(B.Seconds, MAX_SECONDS)
	if coop() then
		active = { Mode = "Zoom", Start = os.clock(), Dur = dur, Body = nil }
		stats.Zooms += 1
	else
		active = { Mode = "Push", Start = os.clock(), Dur = dur, Body = findBoss() }
		stats.Pushes += 1
	end
end

-- Stops a running intro at once (travel, run end, death).
function BossIntro.Stop()
	active = nil
	setVignette(0)
end

function BossIntro.Active(): string?
	return active and active.Mode or nil
end

function BossIntro.Stats(): { [string]: number }
	return table.clone(stats)
end

local function step()
	local a = active
	if not a then
		return
	end
	local t = os.clock() - a.Start
	if t >= a.Dur or not on() or player:GetAttribute("InRun") ~= true or reducedMotion() then
		BossIntro.Stop()
		return
	end
	local w = envelope(t, a.Dur)
	local cam = workspace.CurrentCamera
	if not cam then
		return
	end
	if a.Mode == "Zoom" then
		cam.FieldOfView = cam.FieldOfView * (1 - (1 - B.CoopZoom) * w)
		setVignette(B.Vignette * w)
		return
	end
	-- solo push: CameraController has placed the camera this frame; slide it (same angle)
	local body = a.Body
	if (not body or not body.Parent or body.Position.Y <= PARKED_Y) and os.clock() >= (a.NextSearch or 0) then
		-- the boss may still be on its way to this client: look again 5x a second
		a.NextSearch = os.clock() + 0.2
		body = findBoss()
		a.Body = body
	end
	local cf = cam.CFrame
	local look = cam.Focus.Position
	local shift = Vector3.zero
	if body then
		local d = (body.Position - look) * Vector3.new(1, 0, 1)
		shift = d * B.Shift
		if shift.Magnitude > B.MaxShift then
			shift = shift.Unit * B.MaxShift
		end
	end
	local pull = (look - cf.Position) * B.Pull
	local offset = (shift + pull) * w
	stats.MaxOffset = math.max(stats.MaxOffset, offset.Magnitude)
	cam.CFrame = cf + offset
	cam.Focus = CFrame.new(look + shift * w)
end

function BossIntro.Init()
	local state = Remotes.State()
	local lastName = state:GetAttribute("BossName")
	local lastPhase = tonumber(state:GetAttribute("BossPhase")) or 0
	state:GetAttributeChangedSignal("BossName"):Connect(function()
		local name = state:GetAttribute("BossName")
		if type(name) == "string" and name ~= "" and name ~= lastName then
			BossIntro.Trigger("arrive", 1)
		elseif name == nil then
			BossIntro.Stop()
		end
		lastName = name
	end)
	state:GetAttributeChangedSignal("BossPhase"):Connect(function()
		local phase = tonumber(state:GetAttribute("BossPhase")) or 0
		if lastPhase >= 1 and phase > lastPhase then
			BossIntro.Trigger("phase", phase)
		end
		lastPhase = phase
	end)
	player:GetAttributeChangedSignal("InRun"):Connect(function()
		if player:GetAttribute("InRun") ~= true then
			BossIntro.Stop()
		end
	end)
	-- after SwarmCamera (Camera + 1): adjusts the camera it just placed
	RunService:BindToRenderStep("SwarmBossIntro", Enum.RenderPriority.Camera.Value + 2, step)
end

return BossIntro
