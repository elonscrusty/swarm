--[[
	ChallengesUI.lua (features 3, 5, 7; docs/features/CHALLENGES.md)
	Client visuals for the server's challenge encounters. Reads replicated state only:

	  Champion (MiniBoss)  SwarmState MiniBossId / MiniBossName: a name plate over the
	                       guard (BillboardGui on its hidden server body) and a double violet
	                       and gold ring under it, drawn where EnemyRenderer draws the model.
	                       Its HP bar is the existing small bar (body attribute HPFrac).
	  Shrine of Trial      SwarmState TrialLeft (participants only: player TrialIn) →
	                       FeatureHud badge "TRIAL 24s"; player TrialAway → the announcer
	                       line "BACK TO THE RING! 1.4".
	  Cursed chest         SwarmState CurseLeft → FeatureHud badge "CURSED 42s".

	Every piece idles while its Config.Features switch is off.
]]

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local Shared = game:GetService("ReplicatedStorage"):WaitForChild("Shared")
local Config = require(Shared:WaitForChild("Config"))
local Remotes = require(Shared:WaitForChild("Remotes"))
local Theme = require(Shared:WaitForChild("Theme"))
local FeatureHud = require(script.Parent.FeatureHud)
local EnemyRenderer = require(script.Parent.EnemyRenderer)

local ChallengesUI = {}

local player = Players.LocalPlayer
local P = Theme.Palette
local VIOLET = Color3.fromRGB(190, 120, 255)
local VIOLET_DARK = Color3.fromRGB(110, 50, 170)
local DISC = CFrame.Angles(0, 0, math.rad(90))
local FLOOR_Y = Config.ArenaOrigin.Y
local PARK = CFrame.new(0, -500, 0)

local plate: BillboardGui? = nil
local plateName: TextLabel? = nil
local ringOuter: BasePart? = nil
local ringInner: BasePart? = nil

local function ensurePlate(): BillboardGui
	if plate then
		return plate
	end
	local g = Instance.new("BillboardGui")
	g.Name = "ChampionPlate"
	g.Size = UDim2.fromOffset(220, 30)
	g.StudsOffsetWorldSpace = Vector3.new(0, 5.4, 0)
	g.AlwaysOnTop = true
	g.LightInfluence = 0
	g.MaxDistance = 220
	local label = Instance.new("TextLabel")
	label.Name = "Name"
	label.BackgroundTransparency = 1
	label.Size = UDim2.fromScale(1, 1)
	label.FontFace = Theme.Font.Heading
	label.TextSize = 18
	label.TextColor3 = VIOLET
	label.TextStrokeColor3 = P.slate_950
	label.TextStrokeTransparency = 0.2
	label.Text = ""
	label.Parent = g
	g.Parent = player:WaitForChild("PlayerGui")
	plate, plateName = g, label
	return g
end

local function ensureRings()
	if ringOuter then
		return
	end
	local function disc(name: string, color: Color3, transparency: number): BasePart
		local p = Instance.new("Part")
		p.Name = name
		p.Shape = Enum.PartType.Cylinder
		p.Anchored = true
		p.CanCollide = false
		p.CanQuery = false
		p.CanTouch = false
		p.CastShadow = false
		p.Material = Enum.Material.Neon
		p.Color = color
		p.Transparency = transparency
		p.Size = Vector3.new(0.05, 8, 8)
		p.CFrame = PARK
		p.Parent = workspace.CurrentCamera or workspace
		return p
	end
	ringOuter = disc("ChampionRingOuter", P.gold_400, 0.35)
	ringInner = disc("ChampionRingInner", VIOLET_DARK, 0.2)
end

local function hideChampion()
	if plate then
		plate.Enabled = false
		(plate :: any).Adornee = nil
	end
	if ringOuter and ringInner then
		ringOuter.CFrame = PARK
		ringInner.CFrame = PARK
	end
end

local function stepChampion(clock: number)
	local state = Remotes.State()
	local id = tonumber(state:GetAttribute("MiniBossId")) or 0
	if id <= 0 or not Config.FeatureOn("MiniBosses") or player:GetAttribute("InRun") ~= true then
		hideChampion()
		return
	end
	local folder: Instance? = workspace:FindFirstChild("SwarmEnemies")
	local model: Instance? = if folder then folder:FindFirstChild("E" .. id) else nil
	local body: Instance? = if model then model:FindFirstChild("Body") else nil
	local pos = EnemyRenderer.Position(id)
	if not body or not pos then
		hideChampion()
		return
	end
	local g = ensurePlate()
	g.Adornee = body :: BasePart
	g.StudsOffsetWorldSpace = Vector3.new(0, (body :: BasePart).Size.Y / 2 + 3.4, 0)
	if plateName then
		plateName.Text = string.upper(tostring(state:GetAttribute("MiniBossName") or "Champion"))
	end
	g.Enabled = true
	ensureRings()
	local size = math.max((body :: BasePart).Size.X, (body :: BasePart).Size.Z) * 1.5 + 3
	local pulse = 0.06 * math.sin(clock * 4)
	local outer, inner = ringOuter :: BasePart, ringInner :: BasePart
	outer.Size = Vector3.new(0.05, size * (1.08 + pulse), size * (1.08 + pulse))
	inner.Size = Vector3.new(0.05, size * 0.92, size * 0.92)
	outer.CFrame = CFrame.new(pos.X, FLOOR_Y + 0.33, pos.Z) * DISC
	inner.CFrame = CFrame.new(pos.X, FLOOR_Y + 0.335, pos.Z) * DISC
end

local function stepBadges()
	local state = Remotes.State()
	local trialLeft = tonumber(state:GetAttribute("TrialLeft")) or -1
	if Config.FeatureOn("TrialShrine") and trialLeft >= 0 and player:GetAttribute("TrialIn") == true then
		FeatureHud.Badge("Trial", { Text = string.format("TRIAL %ds", trialLeft), Color = VIOLET, Order = 20 })
		local away = tonumber(player:GetAttribute("TrialAway"))
		if away then
			FeatureHud.Announce(string.format("BACK TO THE RING! %.1f", away), { Color = P.crimson_300, Seconds = 0.4 })
		end
	else
		FeatureHud.RemoveBadge("Trial")
	end
	local curse = tonumber(state:GetAttribute("CurseLeft")) or 0
	if Config.FeatureOn("CursedChests") and curse > 0 then
		FeatureHud.Badge("Curse", { Text = string.format("CURSED %ds", curse), Color = VIOLET, Order = 21 })
	else
		FeatureHud.RemoveBadge("Curse")
	end
end

function ChallengesUI.Init()
	local acc = 0
	RunService.RenderStepped:Connect(function(dt)
		local clock = os.clock()
		local ok, err = pcall(stepChampion, clock)
		if not ok then
			warn("[ChallengesUI] " .. tostring(err))
		end
		acc += dt
		if acc >= 0.2 then
			acc = 0
			pcall(stepBadges)
		end
	end)
end

return ChallengesUI
