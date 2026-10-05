--[[
	WeakSpot.lua
	Feature 18, the co-op boss weak spot telegraph (Config.Features.CoopBoss;
	docs/features/TEAM.md). The server (CoopBoss.lua) publishes SwarmState BossWeakSpot
	(Vector3, only while the spot is open) and BossAggroId (the holder's UserId).

	While open: a glowing gold ring on the floor behind the boss with a "HIT HERE" tag
	(pooled, one part), and a FeatureHud badge: "HIT ITS BACK" for the other players,
	"KEEP ITS AGGRO" for the holder. Nothing flashes; the ring pulses slowly. Gone when the
	spot closes, the boss dies, the run ends or the switch is off.
]]

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local Shared = game:GetService("ReplicatedStorage"):WaitForChild("Shared")
local Config = require(Shared:WaitForChild("Config"))
local Remotes = require(Shared:WaitForChild("Remotes"))
local Theme = require(Shared:WaitForChild("Theme"))
local UIKit = require(script.Parent.UIKit)
local FeatureHud = require(script.Parent.FeatureHud)

local WeakSpot = {}

local player = Players.LocalPlayer
local P = Theme.Palette
local started = false
local marker: BasePart? = nil
local badge = ""

-- The open spot's position, or nil (switch off, not in a run, closed).
function WeakSpot.Spot(): Vector3?
	local v = Remotes.State():GetAttribute("BossWeakSpot")
	if not Config.FeatureOn("CoopBoss") or player:GetAttribute("InRun") ~= true or typeof(v) ~= "Vector3" then
		return nil
	end
	return v
end

function WeakSpot.BadgeText(): string
	if not WeakSpot.Spot() then
		return ""
	end
	return Remotes.State():GetAttribute("BossAggroId") == player.UserId and "KEEP ITS AGGRO" or "HIT ITS BACK"
end

function WeakSpot.Marker(): BasePart?
	return marker
end

function WeakSpot.Init()
	if started then
		return
	end
	started = true
	local part = UIKit.new("Part", {
		Name = "BossWeakSpot",
		Anchored = true,
		CanCollide = false,
		CanTouch = false,
		CanQuery = false,
		Material = Enum.Material.Neon,
		Color = Color3.fromRGB(255, 215, 120),
		Shape = Enum.PartType.Cylinder,
		Size = Vector3.new(0.3, 7, 7),
		Transparency = 1,
	}, workspace) :: BasePart
	marker = part
	local bb = UIKit.new("BillboardGui", { Name = "Tag", Adornee = part, Size = UDim2.fromOffset(110, 34), StudsOffsetWorldSpace = Vector3.new(0, 5, 0), AlwaysOnTop = true, MaxDistance = 220, Enabled = false }, part) :: BillboardGui
	local label = UIKit.text(bb, "Label", "HIT HERE", { Size = UDim2.fromScale(1, 1), TextXAlignment = Enum.TextXAlignment.Center, TextColor3 = P.gold_200, TextStrokeTransparency = 0.3, BackgroundColor3 = P.slate_950, BackgroundTransparency = 0.25 }, 15)
	UIKit.corner(label, Theme.Radius.M)
	RunService.RenderStepped:Connect(function()
		local spot = WeakSpot.Spot()
		if spot then
			local t = os.clock()
			-- a slow pulse (about 1.2 s), never a flash
			local alpha = 0.35 + 0.15 * math.sin(t * 5)
			local cf = CFrame.new(spot + Vector3.new(0, 0.2, 0)) * CFrame.Angles(0, 0, math.pi / 2)
			if part.CFrame ~= cf then
				part.CFrame = cf
			end
			part.Transparency = alpha
			if not bb.Enabled then
				bb.Enabled = true
			end
		elseif part.Transparency ~= 1 or bb.Enabled then
			part.Transparency = 1
			bb.Enabled = false
		end
		local text = WeakSpot.BadgeText()
		if text ~= badge then
			badge = text
			if text == "" then
				FeatureHud.RemoveBadge("WeakSpot")
			else
				FeatureHud.Badge("WeakSpot", { Text = text, Color = P.gold_300, Order = 10 })
			end
		end
	end)
end

return WeakSpot
