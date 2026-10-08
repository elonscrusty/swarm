--!strict
--[[
	SwarmV2/Lobby/Avatars.lua  (ServerScriptService.SwarmV2.Lobby.Avatars)
	OWNER: lobby track (Chat 1). Players walk the basecamp as their own Roblox avatars.

	The place has CharacterAutoLoads = false and LoadCharacterAppearance = false, so the
	server spawns each avatar itself with the player's own HumanoidDescription
	(Players:GetHumanoidDescriptionFromUserId → LoadCharacterWithHumanoidDescription; a plain
	LoadCharacter when the description can't be fetched) at the bonfire. The avatar and the
	Player carry attribute SwarmClass (selected class id, UI only) and the avatar
	SwarmV2Avatar = true. Respawn after a death, and a fall below LobbyConfig.FallY goes back
	to the bonfire.

	Local role: Release(player) when a local match takes them (the run side owns the character
	then); Return(player) brings them back to the bonfire (MatchAdmission.ReturnToLobby).

	Until the gameplay track applies PATCH L1 (docs/redesign/PATCHES_lobby.md: RunManager stops
	building the old blocky lobby hero), the old code may replace the avatar; the guard below
	re-spawns the avatar when that happens to a player in the camp (at most once per 2 s).
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local LobbyConfig = require(ReplicatedStorage:WaitForChild("SwarmV2"):WaitForChild("Lobby"):WaitForChild("LobbyConfig"))

local Avatars = {}

local deps = {
	SpawnCFrame = function(_i: number): CFrame
		return CFrame.new(LobbyConfig.Origin + Vector3.new(0, 3, 0))
	end,
	ClassOf = function(_p: Player): string
		return "ruckus"
	end,
}

function Avatars._SetDeps(overrides: { [string]: any })
	for k, v in pairs(overrides) do
		(deps :: any)[k] = v
	end
end

local inCamp: { [Player]: boolean } = {}
local spawning: { [Player]: boolean } = {}
local lastGuard: { [Player]: number } = {}
local spawnIndex = 0

local function setClassAttr(p: Player)
	local id = deps.ClassOf(p)
	p:SetAttribute("SwarmClass", id)
	local char = p.Character
	if char and char:GetAttribute("SwarmV2Avatar") == true then
		char:SetAttribute("SwarmClass", id)
	end
end

local function root(p: Player): BasePart?
	local char = p.Character
	local r = char and char:FindFirstChild("HumanoidRootPart")
	return r and r:IsA("BasePart") and r or nil
end

-- Spawns (or respawns) the player's own avatar at the bonfire.
function Avatars.Spawn(p: Player)
	if p.Parent ~= Players or spawning[p] then
		return
	end
	inCamp[p] = true
	spawning[p] = true
	local okDesc, desc = pcall(function()
		return Players:GetHumanoidDescriptionFromUserId(math.max(1, p.UserId))
	end)
	local loaded = false
	if okDesc and desc then
		loaded = pcall(function()
			p:LoadCharacterWithHumanoidDescription(desc)
		end)
	end
	if not loaded then
		pcall(function()
			p:LoadCharacter()
		end)
	end
	spawning[p] = false
	local char = p.Character
	if not char or p.Parent ~= Players then
		return
	end
	char:SetAttribute("SwarmV2Avatar", true)
	spawnIndex += 1
	pcall(function()
		char:PivotTo(deps.SpawnCFrame(spawnIndex))
	end)
	setClassAttr(p)
	local hum = char:FindFirstChildOfClass("Humanoid")
	if hum then
		hum.Died:Connect(function()
			task.delay(3, function()
				if inCamp[p] and p.Parent == Players and p.Character == char then
					Avatars.Spawn(p)
				end
			end)
		end)
	end
end

-- Moves the avatar (queue pads, gate exits, bonfire).
function Avatars.MoveTo(p: Player, cf: CFrame)
	local char = p.Character
	if char and char:GetAttribute("SwarmV2Avatar") == true then
		pcall(function()
			char:PivotTo(cf)
		end)
	end
end

function Avatars.RefreshClass(p: Player)
	setClassAttr(p)
end

function Avatars.Position(p: Player): Vector3?
	local r = root(p)
	return r and r.Position
end

function Avatars.InCamp(p: Player): boolean
	return inCamp[p] == true
end

-- Local role: the run takes the player (its own character).
function Avatars.Release(p: Player)
	inCamp[p] = nil
end

-- Local role: back from a run on this server. True when the avatar is back at the bonfire.
function Avatars.Return(p: Player): boolean
	if p.Parent ~= Players then
		return false
	end
	Avatars.Spawn(p)
	return true
end

-- Falls and the pre-patch guard; called every few tenths of a second by LobbyBoot.
function Avatars.Step()
	local floor = LobbyConfig.Origin.Y + LobbyConfig.FallY
	for p in pairs(inCamp) do
		local r = root(p)
		if r and r.Position.Y < floor then
			Avatars.MoveTo(p, deps.SpawnCFrame(1))
		end
	end
end

function Avatars.Start()
	Players.PlayerRemoving:Connect(function(p)
		inCamp[p] = nil
		spawning[p] = nil
		lastGuard[p] = nil
	end)
	local function watch(p: Player)
		p.CharacterAdded:Connect(function(char)
			task.defer(function()
				if not inCamp[p] or spawning[p] or p.Character ~= char or char:GetAttribute("SwarmV2Avatar") == true then
					return
				end
				if p:GetAttribute("InRun") == true then
					inCamp[p] = nil -- the old run flow took them: not ours any more
					return
				end
				local now = os.clock()
				if now - (lastGuard[p] or -math.huge) < 2 then
					return
				end
				lastGuard[p] = now
				Avatars.Spawn(p)
			end)
		end)
	end
	Players.PlayerAdded:Connect(watch)
	for _, p in ipairs(Players:GetPlayers()) do
		watch(p)
	end
end

return Avatars
