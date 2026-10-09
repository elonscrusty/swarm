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

local function changed(p: Player)
	if deps.SyncProfile then
		pcall(deps.SyncProfile :: any, p)
	end
	if deps.OnClass then
		pcall(deps.OnClass :: any, p)
	end
	QueueService.OnClassChanged(p)
	if deps.Push then
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

-- Returns nil on success, else the error code (also told to the player).
function ClassService.Select(p: Player, classId: any): string?
	local data = deps.DataService and deps.DataService.GetData(p)
	if not data then
		return "NO_SAVE"
	end
	if not ClassCatalog.IsClassId(classId) then
		return "UNKNOWN_CLASS"
	end
	if Transfer.IsBusy(p) then
		notify(p, "Your class is locked while you travel.", "warn")
		return "LOCKED"
	end
	if ClassOwnership.Selected(data) == classId then
		return nil
	end
	local err = ClassOwnership.Select(data, classId)
	if err == "NOT_OWNED" then
		local info = ClassCatalog.Get(classId)
		notify(p, string.format("%s costs %s gold: buy it in the class menu.", info and info.Name or "That class", fmt(info and info.Cost or 0)), "warn")
		return err
	elseif err then
		return err
	end
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
		return "LOCKED"
	end
	local err = ClassOwnership.Buy(data, classId)
	local info = ClassCatalog.Get(classId)
	if err == "NO_GOLD" then
		notify(p, "Not enough gold.", "bad")
	elseif err == "OWNED" then
		return ClassService.Select(p, classId)
	elseif err == nil and info then
		notify(p, info.Name .. " unlocked!", "good")
		changed(p)
	end
	return err
end

function ClassService.OnAction(p: Player, action: any, classId: any)
	if action == "Select" then
		ClassService.Select(p, classId)
	elseif action == "Buy" then
		ClassService.Buy(p, classId)
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
