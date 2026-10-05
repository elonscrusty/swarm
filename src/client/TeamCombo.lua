--[[
	TeamCombo.lua (client)
	Feature 16, the team combo (Config.Features.TeamCombo; docs/features/TEAM.md).
	Also starts PingWheel (17), Spectate (20) and WeakSpot (18), the other TEAM pieces.

	Shows the shared meter the server publishes (SwarmState TeamCombo 0..1, TeamComboPair,
	TeamComboUsed) as a FeatureHud badge in a group run: "TEAM 40%" while it fills,
	"COMBO READY" when it is full and you stand with a teammate, "COMBO: GET CLOSE" when it
	is full but you are apart. When you can fire it a round COMBO touch button shows left of
	the ULT button; keyboard F, gamepad ButtonL1. Pressing only asks the server
	(TeamComboFire); the server checks the meter, the partner and the run. Each new
	TeamComboUsed announces "TEAM COMBO!".
]]

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local Shared = game:GetService("ReplicatedStorage"):WaitForChild("Shared")
local Config = require(Shared:WaitForChild("Config"))
local Remotes = require(Shared:WaitForChild("Remotes"))
local Theme = require(Shared:WaitForChild("Theme"))
local UIKit = require(script.Parent.UIKit)
local FeatureHud = require(script.Parent.FeatureHud)

local TeamCombo = {}

local player = Players.LocalPlayer
local P = Theme.Palette
local T = Config.TeamCombo
local started = false
local lastUsed: number? = nil
local button: TextButton? = nil
local badgeText = ""

local function on(): boolean
	return Config.FeatureOn("TeamCombo")
end

-- The meter (0..1) while a co-op run publishes it, else nil.
function TeamCombo.Meter(): number?
	local v = Remotes.State():GetAttribute("TeamCombo")
	if not on() or player:GetAttribute("InRun") ~= true or type(v) ~= "number" then
		return nil
	end
	return math.clamp(v, 0, 1)
end

-- True when the local player stands in the pair the server counts now.
function TeamCombo.InPair(): boolean
	local pair = Remotes.State():GetAttribute("TeamComboPair")
	return type(pair) == "string" and string.find(pair, "," .. tostring(player.UserId) .. ",", 1, true) ~= nil
end

function TeamCombo.CanFire(): boolean
	local m = TeamCombo.Meter()
	return m ~= nil and m >= 1 and TeamCombo.InPair() and player:GetAttribute("Alive") == true
		and player:GetAttribute("Paused") ~= true and FeatureHud.Visible()
end

function TeamCombo.Fire(): boolean
	if not TeamCombo.CanFire() then
		return false
	end
	Remotes.Get("TeamComboFire"):FireServer()
	return true
end

-- The badge words for meter `m` (tests read them).
function TeamCombo.BadgeText(m: number, together: boolean): string
	if m >= 1 then
		return together and "COMBO READY" or "COMBO: GET CLOSE"
	end
	return string.format("TEAM %d%%", math.floor(m * 100))
end

local function refresh()
	local m = TeamCombo.Meter()
	if m == nil then
		if badgeText ~= "" then
			FeatureHud.RemoveBadge("TeamCombo")
			badgeText = ""
		end
		return
	end
	local together = TeamCombo.InPair()
	local text = TeamCombo.BadgeText(m, together)
	if text ~= badgeText then
		badgeText = text
		FeatureHud.Badge("TeamCombo", { Text = text, Color = m >= 1 and P.gold_300 or P.moss_400, Order = 20 })
	end
end

local function onUsed()
	local n = Remotes.State():GetAttribute("TeamComboUsed")
	if type(n) ~= "number" then
		lastUsed = nil
		return
	end
	if lastUsed ~= nil and n > lastUsed and on() then
		FeatureHud.Announce("TEAM COMBO!", { Color = P.gold_200, Seconds = 1.6 })
	end
	lastUsed = n
end

function TeamCombo.Init()
	if started then
		return
	end
	started = true
	local slot = FeatureHud.Slot("Ultimate")
	local root = slot and slot.Parent
	if root then
		local size = T.ButtonSize
		local b = UIKit.new("TextButton", {
			Name = "TeamCombo",
			Text = "",
			AutoButtonColor = true,
			BackgroundColor3 = P.gold_300,
			BackgroundTransparency = 0.05,
			AnchorPoint = Vector2.new(1, 1),
			Size = UDim2.fromOffset(size, size),
			Visible = false,
		}, root) :: TextButton
		UIKit.corner(b, 999)
		UIKit.stroke(b, P.gold_200, 2, 0.1)
		UIKit.text(b, "Label", "COMBO", { Name = "Label", Size = UDim2.fromScale(1, 1), TextXAlignment = Enum.TextXAlignment.Center, TextColor3 = P.slate_950 }, 13)
		b.Activated:Connect(function()
			TeamCombo.Fire()
		end)
		button = b
	end
	UserInputService.InputBegan:Connect(function(input, processed)
		if processed or UserInputService:GetFocusedTextBox() then
			return
		end
		if input.KeyCode == T.Key or input.KeyCode == T.Pad then
			TeamCombo.Fire()
		end
	end)
	local state = Remotes.State()
	state:GetAttributeChangedSignal("TeamComboUsed"):Connect(onUsed)
	lastUsed = state:GetAttribute("TeamComboUsed")
	local acc = 0
	RunService.RenderStepped:Connect(function(dt)
		acc += dt
		if acc < 0.1 then
			return
		end
		acc = 0
		refresh()
		local b = button
		if b then
			local show = TeamCombo.CanFire()
			if b.Visible ~= show then
				b.Visible = show
			end
			if show then
				-- left of the ULT button (FeatureHud places that one above JUMP)
				local cam = workspace.CurrentCamera
				local w = cam and cam.ViewportSize.X or 800
				local h = cam and cam.ViewportSize.Y or 600
				local margin = Config.Movement.ButtonMargin or 26
				local jump = (Config.Movement.ButtonSize or 84) + margin
				local pos = UDim2.fromOffset(w - margin - Config.FeatureHud.UltimateSize - 12, h - jump - 12)
				if b.Position ~= pos then
					b.Position = pos
				end
			end
		end
	end)
	require(script.Parent.PingWheel).Init()
	require(script.Parent.Spectate).Init()
	require(script.Parent.WeakSpot).Init()
end

return TeamCombo
