--!strict
--[[
	SwarmV2/Lobby/LobbyClient.lua  (StarterPlayerScripts.SwarmV2Client.Lobby.LobbyClient)
	OWNER: lobby track (Chat 1). Boot hook from the shared base: called once at startup, after
	the existing modules. When the server announces the walk-around basecamp (attribute
	Basecamp on ReplicatedStorage.SwarmV2Net.Lobby) it builds the basecamp UI: class chip and
	sheet, PLAY + gate sheet, queue panel, party strip, menu bar and toasts. Every action is a
	LobbyNet request; the server re-checks everything and answers with LobbyState.
	Without the attribute (match servers, old lobby) it does nothing.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")
local UserInputService = game:GetService("UserInputService")

local LobbyClient = {}

local WAIT_SECONDS = 15
local MAX_TOASTS = 3
local TOAST_SECONDS = 3.5

function LobbyClient.Init()
	task.spawn(function()
		local net = ReplicatedStorage:WaitForChild("SwarmV2Net", WAIT_SECONDS)
		local folder = net and net:WaitForChild("Lobby", WAIT_SECONDS)
		if not folder then
			return
		end
		local deadline = os.clock() + WAIT_SECONDS
		while folder:GetAttribute("Basecamp") ~= true and os.clock() < deadline do
			task.wait(0.25)
		end
		if folder:GetAttribute("Basecamp") ~= true then
			return
		end
		local ok, err = pcall(LobbyClient.Start)
		if not ok then
			warn("[SwarmV2 Lobby] client failed to start: " .. tostring(err))
		end
	end)
end

function LobbyClient.Start(): boolean
	local Kit = require(script.Parent.Kit)
	local ClassPanel = require(script.Parent.ClassPanel)
	local QueuePanel = require(script.Parent.QueuePanel)
	local PartyStrip = require(script.Parent.PartyStrip)
	local MenuBar = require(script.Parent.MenuBar)
	local LobbyNet = require(ReplicatedStorage:WaitForChild("SwarmV2"):WaitForChild("Lobby"):WaitForChild("LobbyNet"))
	local Config = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Config"))
	local clientRoot = script.Parent.Parent.Parent:WaitForChild("SwarmClient")
	local LobbyScreen = require(clientRoot:WaitForChild("LobbyScreen"))
	local UIBuilder = require(clientRoot:WaitForChild("UIBuilder"))

	local UIKit, Theme, C = Kit.UIKit, Kit.Theme, Kit.C
	local player = Players.LocalPlayer

	LobbyScreen.SetBasecamp(true)

	------------------------------------------------------------------ gui + scale
	local gui = Instance.new("ScreenGui")
	gui.Name = "SwarmV2Lobby"
	gui.ResetOnSpawn = false
	gui.IgnoreGuiInset = false
	gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
	gui.DisplayOrder = 8 -- under SwarmUI (10): the old lobby screens open over the camp
	gui.ScreenInsets = Enum.ScreenInsets.DeviceSafeInsets
	local root = Instance.new("Frame")
	root.Name = "Root"
	root.BackgroundTransparency = 1
	root.Size = UDim2.fromScale(1, 1)
	root.Parent = gui
	local uiScale = Instance.new("UIScale")
	uiScale.Parent = root
	local content = Instance.new("Frame")
	content.Name = "Content"
	content.BackgroundTransparency = 1
	content.Size = UDim2.fromScale(1, 1)
	content.Parent = root
	local toastHost = Instance.new("Frame")
	toastHost.Name = "Toasts"
	toastHost.BackgroundTransparency = 1
	toastHost.AnchorPoint = Vector2.new(0.5, 0)
	toastHost.Size = UDim2.fromOffset(380, 200)
	toastHost.ZIndex = 30
	toastHost.Parent = root
	local toastList = Instance.new("UIListLayout")
	toastList.SortOrder = Enum.SortOrder.LayoutOrder
	toastList.Padding = UDim.new(0, 6)
	toastList.HorizontalAlignment = Enum.HorizontalAlignment.Center
	toastList.Parent = toastHost

	local ctx: Kit.Ctx
	ctx = {
		Gui = gui,
		Root = content,
		W = 1000,
		H = 450,
		Portrait = false,
		Touch = UserInputService.TouchEnabled,
		View = nil,
		Fire = function(name: string, ...: any)
			LobbyNet.Get(name):FireServer(...)
		end,
		OpenSheet = function(_name: string?) end,
		Toast = function(_text: string, _kind: string?) end,
	}

	------------------------------------------------------------------ toasts
	local toastN = 0
	local function toast(text: string, kind: string?)
		toastN += 1
		local fill, ink = C.Panel, C.Text
		if kind == "good" then
			fill, ink = C.Selected, C.Text
		elseif kind == "warn" then
			fill, ink = C.Primary, C.TextOnGold
		elseif kind == "bad" then
			fill, ink = C.Danger, C.TextOnBlue
		end
		local g = Instance.new("CanvasGroup")
		g.Name = "Toast"
		g.LayoutOrder = toastN
		g.BackgroundColor3 = fill
		g.BorderSizePixel = 0
		g.Size = UDim2.fromOffset(360, 52)
		g.ZIndex = 31
		UIKit.corner(g, Theme.Radius.M)
		UIKit.stroke(g, C.Text, 2, 0.2)
		UIKit.text(g, "BodyStrong", text, {
			Size = UDim2.new(1, -16, 1, 0),
			Position = UDim2.fromOffset(8, 0),
			TextXAlignment = Enum.TextXAlignment.Center,
			TextWrapped = true,
			TextColor3 = ink,
			ZIndex = 32,
		}, 16)
		g.Parent = toastHost
		local kids = {}
		for _, ch in ipairs(toastHost:GetChildren()) do
			if ch:IsA("CanvasGroup") then
				table.insert(kids, ch)
			end
		end
		table.sort(kids, function(a, b)
			return a.LayoutOrder < b.LayoutOrder
		end)
		while #kids > MAX_TOASTS do
			local oldest = table.remove(kids, 1)
		if oldest then
			oldest:Destroy()
		end
		end
		task.delay(TOAST_SECONDS, function()
			if not g.Parent then
				return
			end
			local tw = TweenService:Create(g, TweenInfo.new(0.5), { GroupTransparency = 1 })
			tw.Completed:Once(function()
				g:Destroy()
			end)
			tw:Play()
		end)
	end
	ctx.Toast = toast

	------------------------------------------------------------------ panels
	local classes: ClassPanel.Panel
	local queue: QueuePanel.Panel
	local party: PartyStrip.Panel
	local menu: MenuBar.Panel

	local function openSheet(name: string?)
		classes.Sheet.Close()
		queue.Sheet.Close()
		if name == "Classes" then
			classes.Sheet.Open()
			classes.Render(ctx)
		elseif name == "Gates" then
			queue.Sheet.Open()
		end
	end
	ctx.OpenSheet = openSheet

	local function openScreen(screen: string)
		openSheet(nil)
		pcall(LobbyScreen.Show, screen)
	end

	classes = ClassPanel.Build(ctx)
	queue = QueuePanel.Build(ctx)
	party = PartyStrip.Build(ctx, function()
		openScreen("Party")
	end)
	menu = MenuBar.Build(ctx, openScreen, function()
		openSheet(nil)
		pcall(UIBuilder.OpenSettings)
	end)

	local function layout()
		local size = gui.AbsoluteSize
		if size.X < 8 or size.Y < 8 then
			return
		end
		local compact = UIKit.IsCompact()
		local portrait = size.Y > size.X
		local ref = Config.UI.ReferenceSize
		local phone = Config.UI.PhoneReferenceSize
		local refX, refY = ref.X, ref.Y
		if compact then
			refX, refY = phone.X, phone.Y
		end
		if portrait then
			refX, refY = refY, refX
		end
		local s = math.clamp(math.min(size.X / refX, size.Y / refY), Config.UI.MinScale, Config.UI.MaxScale)
		uiScale.Scale = s
		root.Size = UDim2.fromScale(1 / s, 1 / s)
		ctx.W, ctx.H, ctx.Portrait = size.X / s, size.Y / s, portrait
		local barBottom = menu.Layout(ctx)
		party.Layout(ctx, Kit.M, Kit.M + 64 + 8 + (portrait and 60 + 8 or 0))
		classes.Layout(ctx)
		queue.Layout(ctx)
		toastHost.Position = UDim2.fromOffset(ctx.W / 2, barBottom + 8)
		classes.Render(ctx)
		queue.Render(ctx)
		party.Render(ctx)
	end

	local function render()
		classes.Render(ctx)
		queue.Render(ctx)
		party.Render(ctx)
		if ctx.View and ctx.View.Queue then
			queue.Sheet.Close()
		end
	end

	------------------------------------------------------------------ server messages
	LobbyNet.Get("LobbyState").OnClientEvent:Connect(function(state: any)
		if type(state) ~= "table" then
			return
		end
		ctx.View = state
		render()
	end)
	LobbyNet.Get("LobbyNotice").OnClientEvent:Connect(function(text: any, kind: any)
		if type(text) == "string" then
			toast(text, if type(kind) == "string" then kind else "good")
		end
	end)

	------------------------------------------------------------------ visibility
	local function refreshVisible()
		local inRun = player:GetAttribute("InRun") == true
		gui.Enabled = not inRun
		local home = LobbyScreen.Current() == "Home"
		content.Visible = home
		if not home or inRun then
			openSheet(nil)
		end
	end
	player:GetAttributeChangedSignal("InRun"):Connect(refreshVisible)
	gui:GetPropertyChangedSignal("AbsoluteSize"):Connect(layout)
	gui.Parent = player:WaitForChild("PlayerGui")
	layout()
	refreshVisible()

	RunService.Heartbeat:Connect(function()
		refreshVisible()
		if gui.Enabled and content.Visible then
			queue.Step(ctx)
		end
	end)

	ctx.Fire("LobbySync")
	return true
end

return LobbyClient
