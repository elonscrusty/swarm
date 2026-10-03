-- Preset team pings. Targets are replicated IDs; the server chooses recipients and positions.
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local Shared = game:GetService("ReplicatedStorage"):WaitForChild("Shared")
local Config = require(Shared:WaitForChild("Config"))
local Remotes = require(Shared:WaitForChild("Remotes"))
local Theme = require(Shared:WaitForChild("Theme"))
local UIKit = require(script.Parent.UIKit)
local TeamPings = {}
local player = Players.LocalPlayer
local kinds = { "Location", "Enemy", "Loot", "Help", "Regroup" }
local allowed = { Location = true, Enemy = true, Loot = true, Help = true, Regroup = true }
local gui: ScreenGui? = nil
local markers = {}
local opened = false

local function finite(v: Vector3): boolean
	return v.X == v.X and v.Y == v.Y and v.Z == v.Z and math.abs(v.X) < 1e6 and math.abs(v.Y) < 1e6 and math.abs(v.Z) < 1e6
end

local function root(): BasePart?
	return player.Character and player.Character.PrimaryPart
end

local function inTeamRun(): boolean
	local state = Remotes.State()
	local mode = (Config.Modes :: any)[state:GetAttribute("Mode")]
	return player:GetAttribute("InRun") == true and state:GetAttribute("Phase") == "Running" and type(mode) == "table" and (mode.MaxPlayers or 1) > 1
end

local function usable(): boolean
	return inTeamRun() and player:GetAttribute("Alive") == true and player:GetAttribute("Paused") ~= true and Remotes.State():GetAttribute("Frozen") ~= true
end

function TeamPings.Target(kind: string): any
	local body = root()
	if not body then return nil end
	if kind == "Location" then return body.Position end
	local folder = workspace:FindFirstChild(kind == "Enemy" and "SwarmEnemies" or "SwarmLoot")
	if not folder then return nil end
	local best, distance = nil, Config.TeamPings.MaxDistance + 0.001
	for _, object in ipairs(folder:GetChildren()) do
		local id = kind == "Enemy" and tonumber(string.match(object.Name, "^E(%d+)$")) or object:GetAttribute("LootId")
		local part = object:IsA("Model") and (object.PrimaryPart or object:FindFirstChild("Body")) or nil
		if type(id) == "number" and part and part:IsA("BasePart") and finite(part.Position) then
			local state = object:GetAttribute("State")
			local eligible = kind == "Enemy" or (state ~= "Opened" and state ~= "Claimed" and state ~= "Spent" and state ~= "Active")
			local d = (part.Position - body.Position).Magnitude
			if eligible and d < distance then best, distance = id, d end
		end
	end
	return best
end

function TeamPings.Send(kind: string): boolean
	if not allowed[kind] or not usable() then return false end
	if kind == "Help" or kind == "Regroup" then Remotes.Get("TeamPing"):FireServer(kind); return true end
	local target = TeamPings.Target(kind)
	if target == nil then return false end
	Remotes.Get("TeamPing"):FireServer(kind, target)
	return true
end

function TeamPings.Clear()
	opened = false
	for _, marker in ipairs(markers) do marker.Until = 0; marker.Billboard.Enabled = false end
end

function TeamPings.Init()
	if gui then return end
	local pingGui: ScreenGui = UIKit.new("ScreenGui", { Name = "TeamPings", ResetOnSpawn = false, IgnoreGuiInset = true, DisplayOrder = Theme.Z.Hud + 1, Enabled = false }, player:WaitForChild("PlayerGui"))
	gui = pingGui
	local frame = UIKit.new("Frame", { Name = "Controls", BackgroundTransparency = 1, Size = UDim2.fromScale(1, 1) }, pingGui)
	local panel = UIKit.new("Frame", { Name = "PingOptions", BackgroundColor3 = Theme.Palette.slate_900, AnchorPoint = Vector2.new(0.5, 1), Position = UDim2.new(0.5, 0, 1, -148), Size = UDim2.fromOffset(248, 172), Visible = false }, frame)
	UIKit.corner(panel, Theme.Radius.M)
	UIKit.stroke(panel, Theme.Palette.gold_400, 1, 0.3)
	local button = UIKit.Button(frame, { Name = "Ping", Title = "PING", Kind = "Secondary", AnchorPoint = Vector2.new(0.5, 1), Position = UDim2.new(0.5, 0, 1, -90), Size = UDim2.fromOffset(88, 48), Shadow = false, OnClick = function() opened = not opened; panel.Visible = opened end })
	for i, kind in ipairs(kinds) do
		UIKit.Button(panel, { Name = kind, Title = string.upper(kind), Kind = "Secondary", Position = UDim2.fromOffset(8 + ((i - 1) % 2) * 120, 8 + math.floor((i - 1) / 2) * 54), Size = UDim2.fromOffset(112, 48), Shadow = false, OnClick = function() TeamPings.Send(kind); opened = false; panel.Visible = false end })
	end
	for _ = 1, 12 do
		local anchor = UIKit.new("Part", { Name = "TeamPingMarker", Anchored = true, CanCollide = false, CanTouch = false, CanQuery = false, Transparency = 1, Size = Vector3.one }, workspace)
		local billboard = UIKit.new("BillboardGui", { Name = "Ping", Adornee = anchor, Size = UDim2.fromOffset(120, 44), StudsOffsetWorldSpace = Vector3.new(0, 4, 0), AlwaysOnTop = true, MaxDistance = 160, Enabled = false }, anchor)
		local label = UIKit.text(billboard, "Label", "", { Size = UDim2.fromScale(1, 1), TextXAlignment = Enum.TextXAlignment.Center, TextStrokeTransparency = 0.3, BackgroundColor3 = Theme.Palette.slate_950, BackgroundTransparency = 0.2 }, 14)
		UIKit.corner(label, Theme.Radius.M)
		table.insert(markers, { Anchor = anchor, Billboard = billboard, Label = label, Until = 0 })
	end
	Remotes.Get("TeamPingShown").OnClientEvent:Connect(function(payload)
		if not inTeamRun() or type(payload) ~= "table" or not allowed[payload.Kind] or typeof(payload.Position) ~= "Vector3" or not finite(payload.Position) or typeof(payload.Color) ~= "Color3" then return end
		local marker = markers[1]
		for _, candidate in ipairs(markers) do if candidate.Until < marker.Until then marker = candidate end end
		marker.Anchor.Position = payload.Position
		marker.Label.Text = string.upper(payload.Kind)
		marker.Label.TextColor3 = payload.Color
		marker.Until = os.clock() + Config.TeamPings.Duration
		marker.Billboard.Enabled = true
	end)
	UserInputService.InputBegan:Connect(function(input, processed)
		if not processed and input.KeyCode == Enum.KeyCode.G and usable() and not UserInputService:GetFocusedTextBox() then opened = not opened; panel.Visible = opened end
	end)
	UserInputService.WindowFocusReleased:Connect(function() opened = false; panel.Visible = false end)
	RunService.RenderStepped:Connect(function()
		local active = inTeamRun()
		pingGui.Enabled = active
		button.Instance.Visible = usable()
		if not active then TeamPings.Clear() end
		if not usable() then opened = false end
		panel.Visible = opened
		for _, marker in ipairs(markers) do if marker.Until <= os.clock() then marker.Billboard.Enabled = false end end
	end)
end

return TeamPings
