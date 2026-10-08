--[[
	TeamPings.lua
	Preset team pings (Duo / Trio): a PING button opens five options (LOCATION, ENEMY,
	LOOT, HELP, REGROUP); the server picks the recipients and the position and every
	client shows a short billboard at it (TeamPingShown). Targets are replicated ids.
	Its own ScreenGui, in real pixels: the button sits in the bottom-left corner (inside
	the safe area), the options panel above it, clear of the ability panel (bottom
	centre), the JUMP button (bottom right) and the thumbstick (any other touch). It is
	drawn over the HUD gui (DisplayOrder 10) so the ability panel never hides it. Only in
	a team run, while alive and not paused / frozen; keyboard G toggles the panel.
]]
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
-- Quick pings / emotes (feature 17) and REVIVE ME (feature 20), docs/features/TEAM.md
local quick = { Portal = true, OnMyWay = true, Wave = true, Cheer = true }
local down = { ReviveMe = true }
local function kindAllowed(kind: any): boolean
	if allowed[kind] then return true end
	if quick[kind] then return Config.FeatureOn("QuickPings") end
	if down[kind] then return Config.FeatureOn("Spectate") end
	return false
end
-- The marker text: the quick-ping labels while a TEAM switch is on, else the old words.
local function labelFor(kind: string): string
	local labels = Config.QuickPings and Config.QuickPings.Labels
	if labels and labels[kind] and (not allowed[kind] or Config.FeatureOn("QuickPings")) then return labels[kind] end
	return string.upper(kind)
end
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
TeamPings.Usable = usable
-- Set by PingWheel (feature 17): the PING button and G open the wheel instead of the panel.
TeamPings.ToggleHook = nil :: (() -> ())?

-- Down in a team run and still revivable (REVIVE ME, feature 20).
function TeamPings.CanAskRevive(): boolean
	return Config.FeatureOn("Spectate") and inTeamRun() and player:GetAttribute("Alive") == false
		and player:GetAttribute("AwaitingRevive") ~= true and (tonumber(player:GetAttribute("PartnerRevivesLeft")) or 0) > 0
end

local function toggle(panel: Frame)
	local hook = TeamPings.ToggleHook
	if hook and Config.FeatureOn("QuickPings") then
		opened = false
		hook()
		return
	end
	opened = not opened
	panel.Visible = opened
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
	if not kindAllowed(kind) then return false end
	if down[kind] then
		if not TeamPings.CanAskRevive() then return false end
		Remotes.Get("TeamPing"):FireServer(kind)
		return true
	end
	if not usable() then return false end
	if kind == "Portal" and typeof(Remotes.State():GetAttribute("PortalPos")) ~= "Vector3" then return false end
	if kind == "Help" or kind == "Regroup" or quick[kind] then Remotes.Get("TeamPing"):FireServer(kind); return true end
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
	-- DisplayOrder: over the main UI gui (10) so the ability panel never covers the button
	local pingGui: ScreenGui = UIKit.new("ScreenGui", { Name = "TeamPings", ResetOnSpawn = false, IgnoreGuiInset = true, DisplayOrder = 11, Enabled = false }, player:WaitForChild("PlayerGui"))
	gui = pingGui
	local frame = UIKit.new("Frame", { Name = "Controls", BackgroundTransparency = 1, Size = UDim2.fromScale(1, 1) }, pingGui)
	local M = Theme.Layout.Margin
	local panel = UIKit.new("Frame", { Name = "PingOptions", BackgroundColor3 = Theme.Color.Panel, AnchorPoint = Vector2.new(0, 1), Position = UDim2.new(0, M, 1, -(M + 48 + 8)), Size = UDim2.fromOffset(248, 172), Visible = false }, frame)
	UIKit.corner(panel, Theme.Radius.M)
	UIKit.stroke(panel, Theme.Color.PanelEdge, 2, 0)
	local button = UIKit.Button(frame, { Name = "Ping", Title = "PING", Icon = "bars", IconSize = 20, Kind = "Secondary", AnchorPoint = Vector2.new(0, 1), Position = UDim2.new(0, M, 1, -M), Size = UDim2.fromOffset(88, 48), Shadow = false, OnClick = function() toggle(panel) end })
	for i, kind in ipairs(kinds) do
		UIKit.Button(panel, { Name = kind, Title = string.upper(kind), Kind = "Secondary", Position = UDim2.fromOffset(8 + ((i - 1) % 2) * 120, 8 + math.floor((i - 1) / 2) * 54), Size = UDim2.fromOffset(112, 48), Shadow = false, OnClick = function() TeamPings.Send(kind); opened = false; panel.Visible = false end })
	end
	for _ = 1, 12 do
		local anchor = UIKit.new("Part", { Name = "TeamPingMarker", Anchored = true, CanCollide = false, CanTouch = false, CanQuery = false, Transparency = 1, Size = Vector3.one }, workspace)
		local billboard = UIKit.new("BillboardGui", { Name = "Ping", Adornee = anchor, Size = UDim2.fromOffset(120, 44), StudsOffsetWorldSpace = Vector3.new(0, 4, 0), AlwaysOnTop = true, MaxDistance = 160, Enabled = false }, anchor)
		local label = UIKit.text(billboard, "Label", "", { Size = UDim2.fromScale(1, 1), TextXAlignment = Enum.TextXAlignment.Center, TextStrokeTransparency = 1, BackgroundColor3 = Theme.Color.Text, BackgroundTransparency = 0.08 }, 14)
		UIKit.corner(label, Theme.Radius.M)
		UIKit.stroke(label, Theme.Color.PanelEdge, 2, 0)
		table.insert(markers, { Anchor = anchor, Billboard = billboard, Label = label, Until = 0 })
	end
	Remotes.Get("TeamPingShown").OnClientEvent:Connect(function(payload)
		if not inTeamRun() or type(payload) ~= "table" or not kindAllowed(payload.Kind) or typeof(payload.Position) ~= "Vector3" or not finite(payload.Position) or typeof(payload.Color) ~= "Color3" then return end
		local marker = markers[1]
		for _, candidate in ipairs(markers) do if candidate.Until < marker.Until then marker = candidate end end
		marker.Anchor.Position = payload.Position
		marker.Label.Text = labelFor(payload.Kind)
		marker.Label.TextColor3 = payload.Color
		marker.Until = os.clock() + Config.TeamPings.Duration
		marker.Billboard.Enabled = true
	end)
	UserInputService.InputBegan:Connect(function(input, processed)
		if not processed and input.KeyCode == Enum.KeyCode.G and usable() and not UserInputService:GetFocusedTextBox() then toggle(panel) end
	end)
	UserInputService.WindowFocusReleased:Connect(function() opened = false; panel.Visible = false end)
	-- per frame: only property writes that change something (no churn in the lobby)
	local wasActive = false
	RunService.RenderStepped:Connect(function()
		local active = inTeamRun()
		if pingGui.Enabled ~= active then pingGui.Enabled = active end
		local ok = active and usable()
		if button.Instance.Visible ~= ok then button.Instance.Visible = ok end
		if not active and wasActive then TeamPings.Clear() end
		wasActive = active
		if not ok then opened = false end
		if panel.Visible ~= opened then panel.Visible = opened end
		local now = os.clock()
		for _, marker in ipairs(markers) do if marker.Billboard.Enabled and marker.Until <= now then marker.Billboard.Enabled = false end end
	end)
end

return TeamPings
