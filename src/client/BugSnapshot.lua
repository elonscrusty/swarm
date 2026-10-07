--[[
	BugSnapshot.lua
	The automatic snapshot sent with a bug report (Config.Features.BugReportPlus,
	docs/next/BUG_REPORT_PLUS.md): open panel (UIState), stage / wave / arena, hero and
	build with levels, device, screen size, Roblox Text size, input type, average FPS, the
	last client warnings / errors (LogService) and game.PlaceVersion.

	Start() begins listening (FPS, log lines, the Inventory remote); Collect() returns the
	snapshot table. It holds no player-typed text. The server cleans every field again
	(BugSnapshotData.CleanSnapshot) and filters the log lines; nothing here is trusted.
]]

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local GuiService = game:GetService("GuiService")
local VRService = game:GetService("VRService")

local Shared = game:GetService("ReplicatedStorage"):WaitForChild("Shared")
local Remotes = require(Shared:WaitForChild("Remotes"))
local S = require(Shared:WaitForChild("BugSnapshotData"))
local UIState = require(script.Parent.UIState)

local BugSnapshot = {}

local player = Players.LocalPlayer
local started = false
local logs: { { [string]: any } } = {} -- newest last
local fpsWindows: { number } = {} -- frames per second of the last whole seconds
local frames, elapsed = 0, 0
local weapons: { { [string]: any } } = {}
local passives: { { [string]: any } } = {}

local FPS_WINDOWS = 10 -- seconds averaged

function BugSnapshot.DeviceType(): string
	local ok, vr = pcall(function()
		return VRService.VREnabled
	end)
	if ok and vr then
		return "VR"
	end
	if GuiService:IsTenFootInterface() then
		return "Console"
	end
	if UserInputService.TouchEnabled and not UserInputService.KeyboardEnabled then
		local cam = workspace.CurrentCamera
		local v = cam and cam.ViewportSize or Vector2.new(800, 600)
		return math.min(v.X, v.Y) < 700 and "Phone" or "Tablet"
	end
	return "Desktop"
end

local function inputType(): string
	local ok, t = pcall(function()
		return UserInputService:GetLastInputType()
	end)
	if not ok or typeof(t) ~= "EnumItem" then
		return "Unknown"
	end
	local name = (t :: EnumItem).Name
	if name == "Touch" then
		return "Touch"
	elseif string.sub(name, 1, 7) == "Gamepad" then
		return "Gamepad"
	elseif name == "Keyboard" or string.sub(name, 1, 5) == "Mouse" or name == "TextInput" then
		return "KeyboardMouse"
	end
	return UserInputService.TouchEnabled and "Touch" or "Unknown"
end

local function textSize(): string?
	local ok, v = pcall(function()
		return (GuiService :: any).PreferredTextSize
	end)
	if ok and typeof(v) == "EnumItem" then
		return (v :: EnumItem).Name
	end
	return nil
end

-- The panel the player was looking at (the report form itself sits over it).
local function currentPanel(): string
	local best, bestP = "None", -math.huge
	local ok, names = pcall(UIState.OpenNames)
	if ok and type(names) == "table" then
		for _, name in ipairs(names) do
			local p = UIState.Priority[name] or 10
			if name ~= "BugReport" and p > bestP then
				best, bestP = name, p
			end
		end
	end
	return best
end

local function onLog(message: string, kind: Enum.MessageType)
	local k = kind == Enum.MessageType.MessageError and "Error" or (kind == Enum.MessageType.MessageWarning and "Warn" or nil)
	if not k then
		return
	end
	local t = S.CleanLogText(message)
	if not t then
		return
	end
	table.insert(logs, { Kind = k, Text = t })
	while #logs > S.MaxLogs do
		table.remove(logs, 1)
	end
end

local function onInventory(data: any)
	if type(data) ~= "table" then
		return
	end
	local w, p = {}, {}
	for _, e in ipairs(type(data.Weapons) == "table" and data.Weapons or {}) do
		if type(e) == "table" then
			table.insert(w, { Id = e.Id, Level = e.Level, Evolved = e.Evolved == true })
		end
	end
	for _, e in ipairs(type(data.Passives) == "table" and data.Passives or {}) do
		if type(e) == "table" then
			table.insert(p, { Id = e.Id, Level = e.Level })
		end
	end
	weapons, passives = w, p
end

function BugSnapshot.Start()
	if started or not S.On() then
		return
	end
	started = true
	pcall(function()
		game:GetService("LogService").MessageOut:Connect(onLog)
	end)
	RunService.Heartbeat:Connect(function(dt: number)
		frames += 1
		elapsed += dt
		if elapsed >= 1 then
			table.insert(fpsWindows, frames / elapsed)
			if #fpsWindows > FPS_WINDOWS then
				table.remove(fpsWindows, 1)
			end
			frames, elapsed = 0, 0
		end
	end)
	pcall(function()
		Remotes.Get("Inventory").OnClientEvent:Connect(onInventory)
	end)
	player:GetAttributeChangedSignal("InRun"):Connect(function()
		if player:GetAttribute("InRun") ~= true then
			weapons, passives = {}, {}
		end
	end)
end

function BugSnapshot.AverageFps(): number?
	if #fpsWindows == 0 then
		return elapsed > 0 and frames / elapsed or nil
	end
	local sum = 0
	for _, f in ipairs(fpsWindows) do
		sum += f
	end
	return sum / #fpsWindows
end

function BugSnapshot.Collect(): { [string]: any }
	local state = Remotes.State()
	local inRun = player:GetAttribute("InRun") == true
	local cam = workspace.CurrentCamera
	local v = cam and cam.ViewportSize or Vector2.zero
	local logCopy = {}
	for i, e in ipairs(logs) do
		logCopy[i] = { Kind = e.Kind, Text = e.Text }
	end
	local fps = BugSnapshot.AverageFps()
	return {
		Panel = currentPanel(),
		Stage = inRun and state:GetAttribute("Stage") or nil,
		Wave = inRun and state:GetAttribute("Wave") or nil,
		Arena = inRun and state:GetAttribute("Arena") or nil,
		Hero = inRun and player:GetAttribute("CharacterId") or nil,
		Level = inRun and player:GetAttribute("Level") or nil,
		Weapons = inRun and weapons or {},
		Passives = inRun and passives or {},
		Device = BugSnapshot.DeviceType(),
		ScreenW = math.floor(v.X),
		ScreenH = math.floor(v.Y),
		TextSize = textSize(),
		Input = inputType(),
		Fps = fps and math.floor(fps + 0.5) or nil,
		PlaceVersion = game.PlaceVersion,
		Logs = logCopy,
	}
end

-- Test hook (regression scenes): records a log line as LogService.MessageOut would.
function BugSnapshot._AddLog(message: string, kind: Enum.MessageType)
	onLog(message, kind)
end

return BugSnapshot
