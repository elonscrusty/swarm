--[[
	TravelOverlay.lua
	The client side of private run servers (server RunServers.lua, Config.RunServers).

	Cover (full screen, blocks taps on the menu under it):
	  player attribute Travel = "ToRun"    "TRAVELING TO YOUR RUN"  (lobby: saving, teleporting)
	                   Travel = "ToLobby"  "TO THE MAIN LOBBY"       (run server: saving, teleporting;
	                   set by the server in the same frame the run ends, so the run server's
	                   own lobby menu is never shown as the destination)
	  SwarmState RunServer + RunServerStatus = "Waiting"  "STARTING YOUR RUN" with
	                   "Heroes ready: N / M" (RunServerHere / RunServerExpected)
	Notice (bottom-right corner, compact, inside the device safe area): player attribute
	  TravelHomeIn = seconds  "Return to lobby in Ns" with GO NOW / STAY (remote TravelHome
	  "Go" | "Stay"). It lives in its own ScreenGui, so it never sits in a menu's layout; the
	  Daily screen reserves the corner while it shows (TravelOverlay.NoticeReserve). Hidden
	  while the results panel is open (SetResultsOpen): the results footer shows the same
	  countdown then, so there is only ever one.
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
local noticeGui: ScreenGui
local noticeRoot: Frame
local noticeScale: UIScale
local banner: Frame
local bannerText: TextLabel
local NOTICE_HEIGHT = 56
local NOTICE_WIDTH = 440
local GO_WIDTH = 108
local STAY_WIDTH = 88
local shownCover = false
local resultsOpen = false -- UIBuilder: the results panel is up (it shows TravelHomeIn itself)

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
	noticeScale.Scale = math.max(s, 0.8) -- stays readable on small screens
	noticeRoot.Size = UDim2.fromScale(1 / noticeScale.Scale, 1 / noticeScale.Scale)
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

	-- the go-home notice (run server lobby, after a run): its own ScreenGui in the device
	-- safe area, anchored to the bottom-right corner
	noticeGui = new("ScreenGui", {
		Name = "TravelHomeNotice",
		IgnoreGuiInset = true,
		ResetOnSpawn = false,
		DisplayOrder = 90,
		ZIndexBehavior = Enum.ZIndexBehavior.Sibling,
	})
	noticeGui.ScreenInsets = Enum.ScreenInsets.DeviceSafeInsets
	noticeRoot = new("Frame", { Name = "Root", BackgroundTransparency = 1, Size = UDim2.fromScale(1, 1) }, noticeGui)
	noticeScale = new("UIScale", { Scale = 1 }, noticeRoot)
	banner = UIKit.Panel(noticeRoot, {
		Name = "HomeBanner",
		AnchorPoint = Vector2.new(1, 1),
		Position = UDim2.new(1, -12, 1, -12),
		Size = UDim2.new(1, -24, 0, NOTICE_HEIGHT),
		Visible = false,
		ZIndex = 5,
	})
	new("UISizeConstraint", { MaxSize = Vector2.new(NOTICE_WIDTH, NOTICE_HEIGHT) }, banner)
	UIKit.padding(banner, 4, 8, 4, 10)
	UIKit.list(banner, { FillDirection = Enum.FillDirection.Horizontal, VerticalAlignment = Enum.VerticalAlignment.Center, Padding = UDim.new(0, 8) })
	bannerText = UIKit.Role(banner, "Body", "", { Name = "Text", LayoutOrder = 1, Size = UDim2.new(1, -(GO_WIDTH + STAY_WIDTH + 16), 1, 0), TextWrapped = true, TextSize = 15 })
	UIKit.Button(banner, {
		Kind = "Primary",
		Title = "GO NOW",
		Name = "GoNow",
		Size = UDim2.fromOffset(GO_WIDTH, Theme.Size.TapMin),
		LayoutOrder = 2,
		OnClick = function()
			Remotes.Get("TravelHome"):FireServer("Go")
		end,
	})
	UIKit.Button(banner, {
		Kind = "Secondary",
		Title = "STAY",
		Name = "Stay",
		Size = UDim2.fromOffset(STAY_WIDTH, Theme.Size.TapMin),
		LayoutOrder = 3,
		OnClick = function()
			Remotes.Get("TravelHome"):FireServer("Stay")
		end,
	})

	gui.Parent = player:WaitForChild("PlayerGui")
	noticeGui.Parent = player:WaitForChild("PlayerGui")
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
		return "TO THE MAIN LOBBY", "Saving your progress…"
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
	local bannerOn = not show and not resultsOpen and type(left) == "number" and player:GetAttribute("InRun") ~= true
	banner.Visible = bannerOn
	if bannerOn then
		bannerText.Text = string.format("Return to lobby in %ds", left)
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

-- UIBuilder: the results panel is open (it shows the go-home countdown in its footer).
function TravelOverlay.SetResultsOpen(open: boolean)
	resultsOpen = open
end

-- The cover is up (or about to be): Travel is set.
function TravelOverlay.Covering(): boolean
	local travel = player:GetAttribute("Travel")
	return travel == "ToRun" or travel == "ToLobby"
end

-- Vertical room (in pixels, bottom of the screen) a menu panel must leave clear while the
-- go-home notice shows; 0 when it is hidden.
function TravelOverlay.NoticeReserve(): number
	local left = player:GetAttribute("TravelHomeIn")
	if type(left) == "number" and player:GetAttribute("InRun") ~= true and not resultsOpen then
		return NOTICE_HEIGHT + 24
	end
	return 0
end

-- Preview / tests: the cover's and banner's current state.
function TravelOverlay.Debug(): { Cover: boolean, Title: string, Line: string, Banner: boolean, BannerText: string }
	return { Cover = cover.Visible, Title = coverTitle.Text, Line = coverLine.Text, Banner = banner.Visible, BannerText = bannerText.Text }
end

return TravelOverlay
