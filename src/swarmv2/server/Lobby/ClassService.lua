--!strict
--[[
	SwarmV2/Lobby/ClassService.lua  (ServerScriptService.SwarmV2.Lobby.ClassService)
	OWNER: lobby track (Chat 1). Class select / buy for the basecamp (remote ClassAction and
	the pedestal "Choose" prompts: both call Select, so they behave the same).

	Rules (ClassOwnership): only canonical ids; select only an owned class; buy with gold at
	ClassCatalog.Cost (owner prices 0 / 10k / 20k / 30k), never through the pedestal prompt
	(no accidental spending). Locked while the player's match is committed / travelling. A
	change while queued clears the player's READY, or cancels a running countdown
	(QueueService.OnClassChanged). The save is the existing one (OwnedCharacters,
	SelectedCharacter, Gold); GoldSystem.SyncProfile sends the profile as before.

	[stream L1] Confirmation: every ClassAction (and every Select / Buy) records an answer per
	player, ClassService.AckOf(p) = { N, Id, Action, Ok, Code? }, which LobbyBoot.View sends as
	LobbyView.ClassAck, and OnAction pushes one fresh LobbyState after the action whether it
	worked or not. The class browser keeps a choice "pending" until a state whose ClassAck.N
	moved on, and keeps the previous class when the answer says it failed.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local ClassCatalog = require(ReplicatedStorage:WaitForChild("SwarmV2"):WaitForChild("ClassCatalog"))
local ClassOwnership = require(script.Parent:WaitForChild("ClassOwnership"))
local Transfer = require(script.Parent:WaitForChild("Transfer"))
local QueueService = require(script.Parent:WaitForChild("QueueService"))

local ClassService = {}

local deps = {
	DataService = nil :: any,
	SyncProfile = nil :: ((Player) -> ())?,
	Notify = nil :: ((Player, string, string) -> ())?,
	Push = nil :: ((Player) -> ())?,
	OnClass = nil :: ((Player) -> ())?, -- avatar attribute refresh
}

function ClassService._SetDeps(overrides: { [string]: any })
	for k, v in pairs(overrides) do
		(deps :: any)[k] = v
	end
end

local function notify(p: Player, text: string, kind: string)
	if deps.Notify and p.Parent == Players then
		pcall(deps.Notify :: any, p, text, kind)
	end
end

-- [stream L1] last answer per player (ClassAck in the LobbyView)
export type Ack = { N: number, Id: string, Action: string, Ok: boolean, Code: string? }
local acks: { [Player]: Ack } = {}
local suppressPush = false -- OnAction pushes once at its end (not once per change plus once more)

local function setAck(p: Player, action: string, classId: any, code: string?)
	local prev = acks[p]
	acks[p] = {
		N = (prev and prev.N or 0) + 1,
		Id = type(classId) == "string" and classId or "",
		Action = action,
		Ok = code == nil,
		Code = code,
	}
end

function ClassService.AckOf(p: Player): Ack?
	return acks[p]
end

Players.PlayerRemoving:Connect(function(p: Player)
	acks[p] = nil
end)

local function changed(p: Player)
	if deps.SyncProfile then
		pcall(deps.SyncProfile :: any, p)
	end
	if deps.OnClass then
		pcall(deps.OnClass :: any, p)
	end
	QueueService.OnClassChanged(p)
	if deps.Push and not suppressPush then
		pcall(deps.Push :: any, p)
	end
end

local function fmt(n: number): string
	local s = tostring(math.floor(n))
	while true do
		local k
		s, k = string.gsub(s, "^(%d+)(%d%d%d)", "%1,%2")
		if k == 0 then
			break
		end
	end
	return s
end

-- The save may be changed only while DataService.IsReady: during a teleport handoff the profile
-- is released, and a change made then would stay in memory and never be saved.
local function notReady(p: Player): boolean
	local ds = deps.DataService
	return ds ~= nil and ds.IsReady ~= nil and not ds.IsReady(p)
end

-- Records the answer and passes the code on (nil = worked).
local function done(p: Player, action: string, classId: any, code: string?): string?
	setAck(p, action, classId, code)
	return code
end

-- Returns nil on success, else the error code (also told to the player).
function ClassService.Select(p: Player, classId: any): string?
	local data = deps.DataService and deps.DataService.GetData(p)
	if not data then
		return "NO_SAVE"
	end
	if not ClassCatalog.IsClassId(classId) then
		return done(p, "Select", classId, "UNKNOWN_CLASS")
	end
	if Transfer.IsBusy(p) then
		notify(p, "Your class is locked while you travel.", "warn")
		return done(p, "Select", classId, "LOCKED")
	end
	if notReady(p) then
		notify(p, "Your save is busy for a moment. Try again.", "warn")
		return done(p, "Select", classId, "NOT_READY")
	end
	if ClassOwnership.Selected(data) == classId then
		return done(p, "Select", classId, nil)
	end
	local err = ClassOwnership.Select(data, classId)
	if err == "NOT_OWNED" then
		local info = ClassCatalog.Get(classId)
		notify(p, string.format("%s costs %s gold: buy it in the class menu.", info and info.Name or "That class", fmt(info and info.Cost or 0)), "warn")
		return done(p, "Select", classId, err)
	elseif err then
		return done(p, "Select", classId, err)
	end
	done(p, "Select", classId, nil)
	changed(p)
	return nil
end

function ClassService.Buy(p: Player, classId: any): string?
	local data = deps.DataService and deps.DataService.GetData(p)
	if not data then
		return "NO_SAVE"
	end
	if Transfer.IsBusy(p) then
		notify(p, "Your class is locked while you travel.", "warn")
		return done(p, "Buy", classId, "LOCKED")
	end
	if notReady(p) then
		notify(p, "Your save is busy for a moment. Try again.", "warn")
		return done(p, "Buy", classId, "NOT_READY")
	end
	local err = ClassOwnership.Buy(data, classId)
	local info = ClassCatalog.Get(classId)
	if err == "NO_GOLD" then
		notify(p, "Not enough gold.", "bad")
	elseif err == "GOAL_ONLY" and info then
		notify(p, string.format("%s is earned in runs: %s.", info.Name, info.Goal and info.Goal.Text or "see the class details"), "warn")
	elseif err == "OWNED" then
		return ClassService.Select(p, classId)
	elseif err == nil and info then
		notify(p, info.Name .. " unlocked!", "good")
		done(p, "Buy", classId, nil)
		changed(p)
		return nil
	end
	return done(p, "Buy", classId, err)
end

function ClassService.OnAction(p: Player, action: any, classId: any)
	if action ~= "Select" and action ~= "Buy" then
		return
	end
	-- one fresh LobbyState at the end, worked or not: the class browser waits for it
	suppressPush = true
	local ok, err = pcall(function()
		if action == "Select" then
			ClassService.Select(p, classId)
		else
			ClassService.Buy(p, classId)
		end
	end)
	suppressPush = false
	if not ok then
		warn("[SwarmV2 ClassService] action: " .. tostring(err))
		setAck(p, action, classId, "ERROR")
	end
	if deps.Push and p.Parent == Players then
		pcall(deps.Push :: any, p)
	end
end

-- The pedestals' ProximityPrompts (attribute ClassId): select an owned class, else explain.
function ClassService.WirePrompts(model: Instance)
	for _, d in ipairs(model:GetDescendants()) do
		if d:IsA("ProximityPrompt") and d.Name == "ChoosePrompt" then
			local prompt = d :: ProximityPrompt
			prompt.Triggered:Connect(function(p)
				local ok, err = pcall(ClassService.Select, p, prompt:GetAttribute("ClassId"))
				if not ok then
					warn("[SwarmV2 ClassService] prompt: " .. tostring(err))
				end
			end)
		end
	end
end

function ClassService.Init(ctx: any)
	deps.DataService = ctx and ctx.DataService or deps.DataService
	if ctx and ctx.GoldSystem then
		deps.SyncProfile = ctx.GoldSystem.SyncProfile
	end
end

return ClassService
