--[[
	FinalStandFx.lua (client)
	Final Stand's look (batch B, Config.Features.FinalStand; docs/next/FINAL_STAND.md). The
	server decides the buff (server FinalStand.lua) and sets the player attribute "FinalStand"
	(seconds) while it lasts.

	  aura      every hero with the attribute (co-op: teammates too) gets a crimson-gold aura
	            on the root part: embers + a soft light. Reduced effects: fewer embers, no
	            light. Removed the moment the attribute clears (timeout, death, stage end).
	  headline  the local hero only: "FINAL STAND!" through UIState's headline lane (Critical,
	            short expiry; dropped if the buff already ended), and one existing sound
	            (Config.FinalStand.Sound) when it starts.
	Idle while the switch is off (the server never sets the attribute then).
]]

local Players = game:GetService("Players")
local Shared = game:GetService("ReplicatedStorage"):WaitForChild("Shared")
local Config = require(Shared:WaitForChild("Config"))
local Palette = require(Shared:WaitForChild("Palette"))
local UIState = require(script.Parent.UIState)
local ClientSettings = require(script.Parent.ClientSettings)
local Audio = require(script.Parent.Audio)

local FinalStandFx = {}

local ATTR = "FinalStand"
local AURA = "FinalStandAura"
local HEADLINE_ID = "player.finalstand"
local auras: { [Player]: Attachment } = {}
local headlines = 0 -- local headlines raised (preview / tests)

local function F()
	return (Config :: any).FinalStand
end

local function rootOf(player: Player): BasePart?
	local char = player.Character
	if not char then
		return nil
	end
	local root = char:FindFirstChild("HumanoidRootPart") or char.PrimaryPart
	return (root and root:IsA("BasePart")) and root or nil
end

local function removeAura(player: Player)
	local a = auras[player]
	auras[player] = nil
	if a then
		a:Destroy()
	end
end

local function addAura(player: Player)
	local root = rootOf(player)
	if not root then
		return
	end
	local old = auras[player]
	if old and old.Parent == root then
		return
	end
	removeAura(player)
	local reduced = ClientSettings.Reduced()
	local a = Instance.new("Attachment")
	a.Name = AURA
	local embers = Instance.new("ParticleEmitter")
	embers.Name = "Embers"
	embers.Color = ColorSequence.new(Palette.crimson_400, Palette.gold_300)
	embers.LightEmission = 0.6
	embers.Size = NumberSequence.new({ NumberSequenceKeypoint.new(0, 0.5), NumberSequenceKeypoint.new(1, 0) })
	embers.Transparency = NumberSequence.new({ NumberSequenceKeypoint.new(0, 0.2), NumberSequenceKeypoint.new(1, 1) })
	embers.Lifetime = NumberRange.new(0.5, 0.9)
	embers.Speed = NumberRange.new(2, 5)
	embers.SpreadAngle = Vector2.new(180, 180)
	embers.Rate = reduced and 6 or 24
	embers.Parent = a
	if not reduced then
		local light = Instance.new("PointLight")
		light.Name = "Glow"
		light.Color = Palette.crimson_400
		light.Range = 10
		light.Brightness = 1.6
		light.Parent = a
	end
	a.Parent = root
	auras[player] = a
end

local function refresh(player: Player)
	if player:GetAttribute(ATTR) ~= nil and Config.FeatureOn("FinalStand") then
		addAura(player)
	else
		removeAura(player)
	end
end

local function announce()
	local player = Players.LocalPlayer
	headlines += 1
	UIState.Headline({
		Id = HEADLINE_ID,
		Title = "FINAL STAND!",
		Sub = string.format("+%d%% damage · +%d%% speed · %d s", math.floor(F().Damage * 100 + 0.5), math.floor(F().Speed * 100 + 0.5), F().Seconds),
		Color = Palette.crimson_300,
		Class = "Critical",
		Expire = 1.5,
		Valid = function()
			return player:GetAttribute(ATTR) ~= nil
		end,
	})
	pcall(Audio.Play, F().Sound)
end

local function watch(player: Player)
	local was = player:GetAttribute(ATTR) ~= nil
	player:GetAttributeChangedSignal(ATTR):Connect(function()
		local now = player:GetAttribute(ATTR) ~= nil
		refresh(player)
		if now and not was and player == Players.LocalPlayer and Config.FeatureOn("FinalStand") then
			announce()
		end
		was = now
	end)
	player.CharacterAdded:Connect(function()
		task.defer(refresh, player)
	end)
	refresh(player)
end

-- For the preview scenes: { Aura = boolean, Embers = rate, Light = boolean, Headlines = n }.
function FinalStandFx.Debug(player: Player?): { [string]: any }
	local p = player or Players.LocalPlayer
	local a = auras[p]
	local embers = a and a:FindFirstChild("Embers") :: ParticleEmitter?
	return { Aura = a ~= nil and a.Parent ~= nil, Embers = embers and embers.Rate or 0, Light = a ~= nil and a:FindFirstChild("Glow") ~= nil, Headlines = headlines }
end

function FinalStandFx.Init()
	for _, p in ipairs(Players:GetPlayers()) do
		watch(p)
	end
	Players.PlayerAdded:Connect(watch)
	Players.PlayerRemoving:Connect(removeAura)
	ClientSettings.OnChanged(function(key)
		if key == "ReducedEffects" then
			local list = {}
			for p in pairs(auras) do
				table.insert(list, p)
			end
			for _, p in ipairs(list) do
				removeAura(p)
				refresh(p)
			end
		end
	end)
end

return FinalStandFx
