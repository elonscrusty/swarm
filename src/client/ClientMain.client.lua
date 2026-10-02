--[[
	ClientMain.client.lua
	Starts every client module in order and wires the few things that span modules:
	music per phase, the hurt flash, the [VIP] chat tag and the background image preload
	(AssetPreload). Player settings live in ClientSettings (filled from the profile by
	UIBuilder).
]]

local Players = game:GetService("Players")
local TextChatService = game:GetService("TextChatService")

local Shared = game:GetService("ReplicatedStorage"):WaitForChild("Shared")
local Remotes = require(Shared:WaitForChild("Remotes"))

local Audio = require(script.Parent:WaitForChild("Audio"))
local CameraController = require(script.Parent:WaitForChild("CameraController"))
local MobileControls = require(script.Parent:WaitForChild("MobileControls"))
local EnemyRenderer = require(script.Parent:WaitForChild("EnemyRenderer"))
local VFX = require(script.Parent:WaitForChild("VFX"))
local UIBuilder = require(script.Parent:WaitForChild("UIBuilder"))
local DamageText = require(script.Parent:WaitForChild("DamageText"))
local AssetPreload = require(script.Parent:WaitForChild("AssetPreload"))

local player = Players.LocalPlayer

-- warm the upgrade / item pictures in the background (level-up cards show them at once)
AssetPreload.Start()
Audio.Init()
CameraController.Init()
MobileControls.Init()
EnemyRenderer.Init() -- before VFX: it sets up the folder the 3D models live in
VFX.Init({
	OnLocalEvent = function(kind)
		if kind == "hurt" then
			UIBuilder.HurtFlash()
		end
	end,
})
UIBuilder.Init({ Audio = Audio, MobileControls = MobileControls })
DamageText.Init() -- optional damage numbers (Settings), after EnemyRenderer

-- Humanoid state switches don't replicate and the client owns its character, so the
-- server's settings are repeated here: no tripping, ragdolling or dying (jumps: JumpController).
local function setupCharacter(char: Model)
	local hum = char:WaitForChild("Humanoid", 10) :: Humanoid?
	if hum then
		for _, s in ipairs({ Enum.HumanoidStateType.FallingDown, Enum.HumanoidStateType.Ragdoll, Enum.HumanoidStateType.Dead }) do
			hum:SetStateEnabled(s, false)
		end
	end
end
player.CharacterAdded:Connect(setupCharacter)
if player.Character then
	task.spawn(setupCharacter, player.Character)
end

-- Music follows the game phase.
local state = Remotes.State()
local function updateMusic()
	local inRun = player:GetAttribute("InRun") == true
	if not inRun then
		Audio.SetMusic("LobbyMusic")
	elseif (state:GetAttribute("BossMaxHP") or 0) > 0 then
		Audio.SetMusic("BossMusic")
	else
		Audio.SetMusic("BattleMusic")
	end
end
player:GetAttributeChangedSignal("InRun"):Connect(updateMusic)
state:GetAttributeChangedSignal("BossMaxHP"):Connect(updateMusic)
updateMusic()

-- [VIP] chat tag (TextChatService). The VIP attribute is set by the server.
TextChatService.OnIncomingMessage = function(message: TextChatMessage)
	local props = Instance.new("TextChatMessageProperties")
	local source = message.TextSource
	if source then
		local speaker = Players:GetPlayerByUserId(source.UserId)
		if speaker and speaker:GetAttribute("VIP") then
			props.PrefixText = '<font color="#FFD24A">[VIP]</font> ' .. message.PrefixText
		end
	end
	return props
end
