--[[
	TravelOverlay.lua
	The client side of private run servers (server RunServers.lua, Config.RunServers).

	Cover (full screen, blocks taps on the menu under it):
	  player attribute Travel = "ToRun"    "TRAVELLING TO YOUR RUN"  (lobby: saving, teleporting)
	                   Travel = "ToLobby"  "BACK TO THE LOBBY"       (run server: saving, teleporting)
	  SwarmState RunServer + RunServerStatus = "Waiting"  "STARTING YOUR RUN" with
	                   "Heroes ready: N / M" (RunServerHere / RunServerExpected)
	Banner (top centre, small, the results panel stays readable):
	  player attribute TravelHomeIn = seconds  "Back to the lobby in Ns" with GO NOW / STAY
	  (remote TravelHome "Go" | "Stay").
	Nothing shows in Studio or on a lobby server that never teleports. Reduced effects: no
	dot animation, no fades.
]]

local Players = game:GetService("Players")
local TweenService = game:GetService("TweenService")

local Shared = game:GetService("ReplicatedStorage"):WaitForChild("Shared")
local Remotes = require(Shared:WaitForChild("Remotes"))
local Config = require(Shared:WaitForChild("Config"))
local Theme = require(Shared:WaitForChild("Theme"))
local UIKit = require(script.Parent:WaitForChild("UIKit"))
local ClientSettings = require(script.Parent:WaitForChild("ClientSettings"))

local TravelOverlay = {}

local player = Players.LocalPlayer
local C = Theme.Color
local new = UIKit.new

local gui: ScreenGui
local scale: UIScale
local root: Frame
local cover: Frame
local coverTitle: TextLabel
local coverLine: TextLabel
local coverDots: TextLabel
local banner: Frame
local bannerText: TextLabel
local shownCover = false

local function fit()
	local cam = workspace.CurrentCamera
	local size = cam and cam.ViewportSize or Vector2.new(1280, 720)
	if size.X < 1 or size.Y < 1 then
		return
	end
	local ref = Config.UI.ReferenceSize
	local refX, refY = ref.X, ref.Y
	if size.Y > size.X then
		refX, refY = ref.Y, ref.X
	end
	local s = math.clamp(math.min(size.X / refX, size.Y / refY), Config.UI.MinScale, Config.UI.MaxScale)
	scale.Scale = s
	root.Size = UDim2.fromScale(1 / s, 1 / s)
end

local function build()
	gui = new("ScreenGui", {
		Name = "TravelOverlay",
		IgnoreGuiInset = true,
		ResetOnSpawn = false,
		DisplayOrder = 90, -- over the menu and HUD, under the first-join loading picture
		ZIndexBehavior = Enum.ZIndexBehavior.Sibling,
	})
	root = new("Frame", { Name = "Root", BackgroundTransparency = 1, Size = UDim2.fromScale(1, 1) }, gui)
	scale = new("UIScale", { Scale = 1 }, root)

	-- the cover: a dark full-screen plate with one panel in the middle
	cover = new("Frame", {
		Name = "Cover",
		BackgroundColor3 = C.Backdrop,
		BackgroundTransparency = 0.12,
		BorderSizePixel = 0,
		Size = UDim2.fromScale(1, 1),
		Active = true, -- the menu under it is not tapped blind
		Visible = false,
	}, root)
	local panel = UIKit.Panel(cover, {
		Name = "Panel",
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.5),
		Size = UDim2.fromOffset(460, 170),
	})
	UIKit.pad(panel, 20)
	UIKit.list(panel, { HorizontalAlignment = Enum.HorizontalAlignment.Center, VerticalAlignment = Enum.VerticalAlignment.Center, Padding = UDim.new(0, 8) })
	coverTitle = UIKit.Role(panel, "Title", "", { Name = "Title", LayoutOrder = 1, TextXAlignment = Enum.TextXAlignment.Center, TextColor3 = C.GoldLight, Size = UDim2.new(1, 0, 0, 34) })
	UIKit.Divider(panel, 220, { LayoutOrder = 2 })
	coverLine = UIKit.Role(panel, "Body", "", { Name = "Line", LayoutOrder = 3, TextXAlignment = Enum.TextXAlignment.Center, TextColor3 = C.TextMuted, TextWrapped = true, Size = UDim2.new(1, 0, 0, 44) })
	coverDots = UIKit.Role(panel, "Heading", "• • •", { Name = "Dots", LayoutOrder = 4, TextXAlignment = Enum.TextXAlignment.Center, TextColor3 = C.Gold, Size = UDim2.new(1, 0, 0, 24) })

	-- the go-home banner (run server lobby, after a run)
	banner = UIKit.Panel(root, {
		Name = "HomeBanner",
		AnchorPoint = Vector2.new(0.5, 0),
		Position = UDim2.new(0.5, 0, 0, 64),
		Size = UDim2.fromOffset(560, 64),
		Visible = false,
		ZIndex = 5,
	})
	UIKit.padding(banner, 6, 8, 6, 16)
	UIKit.list(banner, { FillDirection = Enum.FillDirection.Horizontal, VerticalAlignment = Enum.VerticalAlignment.Center, Padding = UDim.new(0, 10) })
	bannerText = UIKit.Role(banner, "Body", "", { Name = "Text", LayoutOrder = 1, Size = UDim2.new(1, -290, 1, 0), TextWrapped = true })
	UIKit.Button(banner, {
		Kind = "Primary",
		Title = "GO NOW",
		Name = "GoNow",
		Size = UDim2.fromOffset(140, Theme.Size.TapMin),
		LayoutOrder = 2,
		OnClick = function()
			Remotes.Get("TravelHome"):FireServer("Go")
		end,
	})
	UIKit.Button(banner, {
		Kind = "Secondary",
		Title = "STAY",
		Name = "Stay",
		Size = UDim2.fromOffset(120, Theme.Size.TapMin),
		LayoutOrder = 3,
		OnClick = function()
			Remotes.Get("TravelHome"):FireServer("Stay")
		end,
	})

	gui.Parent = player:WaitForChild("PlayerGui")
	fit()
	local cam = workspace.CurrentCamera
	if cam then
		cam:GetPropertyChangedSignal("ViewportSize"):Connect(fit)
	end
end

-- What the cover says now, or nil when it is hidden.
local function coverText(state: Configuration): (string?, string?)
	local travel = player:GetAttribute("Travel")
	if travel == "ToRun" then
		return "TRAVELING TO YOUR RUN", "Saving your progress and opening your own server…"
	elseif travel == "ToLobby" then
		return "BACK TO THE LOBBY", "Saving your progress…"
	end
	if state:GetAttribute("RunServer") == true and state:GetAttribute("RunServerStatus") == "Waiting" then
		local here = tonumber(state:GetAttribute("RunServerHere")) or 0
		local want = tonumber(state:GetAttribute("RunServerExpected")) or 0
		if want > 1 then
			return "STARTING YOUR RUN", string.format("Heroes ready: %d / %d", here, want)
		end
		return "STARTING YOUR RUN", "Loading your hero…"
	end
	return nil, nil
end

local function update(state: Configuration, t: number)
	local title, line = coverText(state)
	local show = title ~= nil
	if show then
		coverTitle.Text = title :: string
		coverLine.Text = line or ""
		if ClientSettings.Reduced() then
			coverDots.Text = "• • •"
		else
			local n = math.floor(t * 3) % 3
			coverDots.Text = n == 0 and "•  ·  ·" or n == 1 and "·  •  ·" or "·  ·  •"
		end
	end
	if show ~= shownCover then
		shownCover = show
		cover.Visible = show
		if show and not ClientSettings.Reduced() then
			cover.BackgroundTransparency = 1
			TweenService:Create(cover, TweenInfo.new(0.25), { BackgroundTransparency = 0.12 }):Play()
		else
			cover.BackgroundTransparency = 0.12
		end
	end
	local left = player:GetAttribute("TravelHomeIn")
	local bannerOn = not show and type(left) == "number"
	banner.Visible = bannerOn
	if bannerOn then
		bannerText.Text = string.format("Back to the lobby in %ds", left)
	end
end

function TravelOverlay.Init()
	build()
	local state = Remotes.State()
	task.spawn(function()
		local t0 = os.clock()
		while gui.Parent do
			update(state, os.clock() - t0)
			task.wait(0.1)
		end
	end)
end

-- Preview / tests: the cover's and banner's current state.
function TravelOverlay.Debug(): { Cover: boolean, Title: string, Line: string, Banner: boolean, BannerText: string }
	return { Cover = cover.Visible, Title = coverTitle.Text, Line = coverLine.Text, Banner = banner.Visible, BannerText = bannerText.Text }
end

return TravelOverlay
