--!strict
--[[
	SwarmV2/Lobby/LobbyBoot.lua  (ServerScriptService.SwarmV2.Lobby.LobbyBoot)
	OWNER: lobby track (Chat 1). Boot hook (GameServer calls Init(ctx) once, after every
	existing module started). See docs/redesign/OWNERSHIP.md and docs/redesign/lobby/HANDOFF.md.

	match role : MatchAdmission only (ResolvePlayer / ReturnToLobby for the run side).
	lobby/local: the basecamp (Basecamp), the players' own avatars (Avatars), classes
	             (ClassService), gate queues (QueueService) and transfers (Transfer), the
	             lobby remotes (LobbyNet, SwarmV2Net.Lobby with attribute Basecamp = true) and
	             one LobbyState push per change. Local role also wires MatchAdmission's
	             in-memory return to the bonfire.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local SwarmV2Shared = ReplicatedStorage:WaitForChild("SwarmV2")
local LobbyConfig = require(SwarmV2Shared:WaitForChild("Lobby"):WaitForChild("LobbyConfig"))
local LobbyNet = require(SwarmV2Shared:WaitForChild("Lobby"):WaitForChild("LobbyNet"))
local MatchAdmission = require(script.Parent.Parent:WaitForChild("MatchAdmission"))
local ClassOwnership = require(script.Parent:WaitForChild("ClassOwnership"))
local Transfer = require(script.Parent:WaitForChild("Transfer"))
local PartyReturn = require(script.Parent:WaitForChild("PartyReturn"))
local QueueService = require(script.Parent:WaitForChild("QueueService"))
local ClassService = require(script.Parent:WaitForChild("ClassService"))
local Avatars = require(script.Parent:WaitForChild("Avatars"))

local LobbyBoot = {}

local ctx: any = nil
local netReady = false
local active = false

-- True once the basecamp runs on this server (lobby / local role). The old lobby code uses
-- it to stand aside (docs/redesign/PATCHES_lobby.md).
function LobbyBoot.Active(): boolean
	return active
end
local GOOD = Color3.fromRGB(120, 255, 160)
local WARN = Color3.fromRGB(255, 200, 120)
local BAD = Color3.fromRGB(255, 120, 120)

local function notify(p: Player, text: string, kind: string)
	if p.Parent ~= Players then
		return
	end
	if netReady then
		LobbyNet.Get("LobbyNotice"):FireClient(p, text, kind)
	elseif ctx and ctx.RunManager and ctx.RunManager.Notify then
		ctx.RunManager.Notify(p, text, kind == "good" and GOOD or kind == "bad" and BAD or WARN)
	end
end

-- The player's LobbyNet.LobbyView.
function LobbyBoot.View(p: Player): { [string]: any }?
	local data = ctx and ctx.DataService and ctx.DataService.GetData(p)
	if not data then
		return nil
	end
	local party = ctx.PartyService and ctx.PartyService.PartyOf and ctx.PartyService.PartyOf(p)
	return {
		Role = MatchAdmission.ServerRole(),
		Gold = type(data.Gold) == "number" and data.Gold or 0,
		Owned = ClassOwnership.OwnedSet(data),
		Selected = ClassOwnership.Selected(data),
		ClassLocked = Transfer.IsBusy(p),
		Queue = QueueService.View(p),
		PartySize = party and #party.Members or 1,
		IsLeader = party == nil or party.Leader == p,
	}
end

local function push(p: Player)
	if not netReady or p.Parent ~= Players then
		return
	end
	local view = LobbyBoot.View(p)
	if view then
		LobbyNet.Get("LobbyState"):FireClient(p, view)
	end
end

local function startMatchServer()
	MatchAdmission.Start()
end

local function startBasecamp(role: string)
	local Basecamp = require(script.Parent:WaitForChild("Basecamp")) :: any
	local gateIds = {}
	for _, g in ipairs(LobbyConfig.Gates) do
		table.insert(gateIds, g.Id)
	end
	LobbyNet.Setup(gateIds)
	local built = Basecamp.Build()

	Avatars._SetDeps({
		SpawnCFrame = Basecamp.SpawnCFrame,
		ClassOf = function(p: Player): string
			local data = ctx.DataService.GetData(p)
			return ClassOwnership.Selected(data)
		end,
	})
	Transfer.Init(ctx)
	Transfer._SetDeps({
		Notify = notify,
		OnLocalStart = Avatars.Release,
		OnLocalCancel = Avatars.Return,
	})
	QueueService.Init(ctx)
	QueueService._SetDeps({
		Role = MatchAdmission.ServerRole,
		Push = push,
		Notify = notify,
		Move = Avatars.MoveTo,
		PadCFrame = Basecamp.PadCFrame,
		ExitCFrame = function(gateId: string): CFrame
			return built.Gates[gateId].Exit
		end,
		InGate = function(p: Player): string?
			if not Avatars.InCamp(p) then
				return nil
			end
			local pos = Avatars.Position(p)
			return pos and Basecamp.InGate(pos) or nil
		end,
		InMatch = function(p: Player): boolean
			return MatchAdmission.LocalMatchOf(p.UserId) ~= nil
		end,
		Board = function(gateId: string, info: { [string]: any })
			local cfgObj = LobbyNet.Gate(gateId)
			if cfgObj then
				for k, v in pairs(info) do
					cfgObj:SetAttribute(k, v)
				end
			end
			local text = info.Mode == "Party" and (info.Count > 0 and string.format("%d PARTY GETTING READY", info.Count) or "OPEN")
				or info.State == "Countdown" and "LAUNCHING"
				or string.format("%d / %d  %s", info.Count, info.Capacity, info.State == "Full" and "FULL" or "OPEN")
			Basecamp.SetBoard(gateId, text, info.State == "Countdown" and Color3.fromRGB(255, 210, 80) or nil)
		end,
	})
	ClassService.Init(ctx)
	ClassService._SetDeps({
		Notify = notify,
		Push = push,
		OnClass = Avatars.RefreshClass,
	})
	MatchAdmission._SetDeps({
		Notify = notify,
		LocalReturn = function(p: Player): boolean
			local ok = Avatars.Return(p)
			push(p)
			return ok
		end,
	})

	LobbyNet.Listen("ClassAction", LobbyConfig.Rates.Class, ClassService.OnAction)
	LobbyNet.Listen("QueueAction", LobbyConfig.Rates.Queue, function(p: Player, action: any, arg: any)
		local why: string? = nil
		if action == "Join" then
			why = QueueService.Join(p, arg, "ui")
		elseif action == "Leave" then
			why = QueueService.Leave(p)
		elseif action == "Ready" then
			why = QueueService.SetReady(p, arg)
		end
		if why then
			notify(p, why, "warn")
		end
		push(p)
	end)
	LobbyNet.Listen("LobbySync", LobbyConfig.Rates.Sync, push)
	ClassService.WirePrompts(built.Model)

	-- party changes (PartyService.OnChanged, added for the redesign)
	local ps = ctx.PartyService
	if ps and ps.OnChanged then
		ps.OnChanged(function(changed: { Player })
			QueueService.OnPartyChanged(changed)
			for _, p in ipairs(changed) do
				push(p)
			end
		end)
	end

	PartyReturn._SetDeps({
		Regroup = ctx.PartyService and ctx.PartyService.Regroup or nil,
	})
	Transfer.Start()
	Avatars.Start()
	Players.PlayerRemoving:Connect(QueueService.OnPlayerRemoving)
	local function onLoaded(p: Player)
		local data = ctx.DataService.GetData(p)
		ClassOwnership.EnsureDefault(data)
		-- back from a run with a party record: put the party together again (lookup hint only)
		local returnedFrom = MatchAdmission.ReturnHint(p)
		if returnedFrom then
			task.spawn(function()
				local ok, err = pcall(PartyReturn.Arrive, p, returnedFrom, nil, nil)
				if not ok then
					warn("[SwarmV2 LobbyBoot] party return: " .. tostring(err))
				end
			end)
		end
		-- after the other load callbacks (the old lobby hero), the avatar wins
		task.defer(function()
			if p.Parent == Players and not Transfer.IsBusy(p) and MatchAdmission.LocalMatchOf(p.UserId) == nil then
				Avatars.Spawn(p)
				push(p)
			end
		end)
	end
	ctx.DataService.OnProfileLoaded(onLoaded)
	for _, p in ipairs(Players:GetPlayers()) do
		if ctx.DataService.GetData(p) then
			task.spawn(onLoaded, p)
		end
	end
	QueueService.RefreshBoards()
	local folder = LobbyNet.Folder()
	folder:SetAttribute("Role", role)
	folder:SetAttribute("Basecamp", true)
	netReady = true
	active = true
	task.spawn(function()
		while true do
			task.wait(LobbyConfig.PadPollSeconds)
			local ok: boolean, err: any = pcall(QueueService.Step)
			if not ok then
				warn("[SwarmV2 LobbyBoot] queue step: " .. tostring(err))
			end
			pcall(Avatars.Step)
		end
	end)
end

function LobbyBoot.Init(c: any)
	ctx = c
	MatchAdmission.Init(ctx)
	local role = MatchAdmission.ServerRole()
	if role == "match" then
		startMatchServer()
		return
	end
	if not LobbyConfig.Enabled then
		return
	end
	startBasecamp(role)
	-- integration: the run side (RunEntry, CameraController) keys off this flag
	workspace:SetAttribute("SwarmV2Lobby", true)
end

return LobbyBoot
