--[[
	ResumeCard.lua (client; Config.Features.QuickResume, docs/next/QUICK_RESUME.md)
	The big RESUME RUN card. The server (QuickResume.lua) sets the player attributes
	  ResumeEndsAt  workspace:GetServerTimeNow() when the held solo run ends for good
	  ResumeInfo    "Stage 2  ·  Wave 7  ·  Level 14  ·  Knight"
	when the player joins (or is back in a lobby) within Config.RunServers.SoloResumeSeconds
	of dropping out of a solo run. While they are set (and the player is not in a run or
	travelling) this card shows first, over the menu: a UIState primary ("ResumeRun"), so
	other lobby cards (welcome back, walkthrough) wait behind it.
	  RESUME RUN (0:42)  remote QuickResume "Resume" (the server checks the owner, the run
	                     and the window; teleports back on the live game)
	  END RUN            needs a second tap within 3 s; remote QuickResume "End" (the run is
	                     settled like a normal loss / leave)
	The card closes by itself when the attributes go away (resumed, settled, too late).

	  ResumeCard.Init()   once (ClientMain)
	  ResumeCard.Debug() -> { Open, Button, Info, Sent }   (preview / tests)
]]

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")

local Shared = game:GetService("ReplicatedStorage"):WaitForChild("Shared")
local Config = require(Shared:WaitForChild("Config"))
local Remotes = require(Shared:WaitForChild("Remotes"))
local Theme = require(Shared:WaitForChild("Theme"))
local UIKit = require(script.Parent.UIKit)
local UIState = require(script.Parent.UIState)

local ResumeCard = {}

local player = Players.LocalPlayer
local new, text, TS = UIKit.new, UIKit.text, UIKit.TS
local C = Theme.Color
local HEADING = Theme.Font.Heading
local NAME = "ResumeRun"
local END_CONFIRM = 3 -- seconds: END RUN needs a second tap within this

type UI = {
	Gui: ScreenGui,
	Root: Frame,
	Scale: UIScale,
	Card: Frame,
	List: UIListLayout,
	Title: TextLabel,
	Info: TextLabel,
	Body: TextLabel,
	Resume: any,
	End: any,
}

local ui: UI? = nil
local open = false
local sending = false
local endArmedUntil = 0
local sent: { string } = {}

local function on(): boolean
	return Config.FeatureOn("QuickResume")
end

-- Seconds left on the held run (0 when none).
function ResumeCard.SecondsLeft(): number
	local at = player:GetAttribute("ResumeEndsAt")
	if type(at) ~= "number" or at ~= at then
		return 0
	end
	return math.max(0, at - workspace:GetServerTimeNow())
end

local function clockText(seconds: number): string
	local s = math.max(0, math.ceil(seconds))
	return string.format("%d:%02d", math.floor(s / 60), s % 60)
end

local function wanted(): boolean
	return on() and ResumeCard.SecondsLeft() > 0 and player:GetAttribute("InRun") ~= true
		and player:GetAttribute("Travel") == nil
end

local function layout()
	local u = ui
	if not u then
		return
	end
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
	u.Scale.Scale = s
	u.Root.Size = UDim2.fromScale(1 / s, 1 / s)
	local vw, vh = size.X / s, size.Y / s
	local w = math.floor(math.min(560, vw - 32))
	local contentH = u.List.AbsoluteContentSize.Y / math.max(0.01, s)
	local h = math.floor(math.min(contentH + 2 * 22, vh - 40))
	u.Card.Size = UDim2.fromOffset(w, math.max(200, h))
end

local function line(parent: Instance, order: number, name: string, color: Color3, size: number): TextLabel
	return text(parent, "Body", "", {
		Name = name,
		LayoutOrder = order,
		Size = UDim2.new(1, 0, 0, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		TextWrapped = true,
		LineHeight = 1.12,
		TextColor3 = color,
		TextXAlignment = Enum.TextXAlignment.Center,
		TextYAlignment = Enum.TextYAlignment.Top,
	}, size)
end

local function build(): UI
	local gui = new("ScreenGui", {
		Name = "ResumeCard",
		IgnoreGuiInset = true,
		ResetOnSpawn = false,
		DisplayOrder = 85, -- over the menu and its cards, under the travel cover (90)
		ZIndexBehavior = Enum.ZIndexBehavior.Sibling,
		Enabled = false,
	})
	local root = new("Frame", { Name = "Root", BackgroundTransparency = 1, Size = UDim2.fromScale(1, 1) }, gui)
	local scale = new("UIScale", { Scale = 1 }, root)
	new("Frame", {
		Name = "Dim",
		BackgroundColor3 = C.Backdrop,
		BackgroundTransparency = Theme.Alpha.Backdrop,
		BorderSizePixel = 0,
		Active = true,
		Size = UDim2.fromScale(1, 1),
	}, root)
	local holder, face = UIKit.Surface(root, {
		Name = "Card",
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.5),
		Size = UDim2.fromOffset(520, 320),
		Radius = Theme.Radius.L,
		ZIndex = 2,
	})
	local body = new("Frame", { Name = "Content", BackgroundTransparency = 1, Position = UDim2.fromOffset(22, 22), Size = UDim2.new(1, -44, 1, -44), ZIndex = 3, ClipsDescendants = true }, face)
	local list = UIKit.list(body, { Padding = UDim.new(0, 10), HorizontalAlignment = Enum.HorizontalAlignment.Center })
	local title = text(body, "H2", "YOUR RUN IS WAITING", {
		Name = "Title",
		LayoutOrder = 1,
		FontFace = HEADING,
		Size = UDim2.new(1, 0, 0, TS(24) + 6),
		TextXAlignment = Enum.TextXAlignment.Center,
		TextColor3 = C.BlueDeep,
		TextScaled = true,
	}, 24)
	local fit = Instance.new("UITextSizeConstraint")
	fit.MaxTextSize = TS(24)
	fit.MinTextSize = 12
	fit.Parent = title
	title:SetAttribute("NoTextFit", true)
	local info = line(body, 2, "Info", C.BlueDeep, 15)
	info.FontFace = HEADING
	UIKit.Hairline(body, { LayoutOrder = 3 })
	local blurb = line(body, 4, "Body", C.Text, 15)
	blurb.Text = "Your solo run is paused: nothing can hurt your hero. Resume before the time runs out, or the run ends like a normal loss (you keep the usual share of its gold)."
	local resume = UIKit.Button(body, {
		Name = "ResumeRun",
		Kind = "Primary",
		Title = "RESUME RUN",
		TitleStyle = "H3",
		Icon = "play",
		IconSize = 20,
		Align = "Center",
		Shrink = true,
		Size = UDim2.new(1, 0, 0, 56),
		LayoutOrder = 5,
		Glow = true,
		OnClick = function()
			ResumeCard._Resume()
		end,
	})
	local stop = UIKit.Button(body, {
		Name = "EndRun",
		Kind = "Ghost",
		Title = "END RUN",
		Align = "Center",
		Shrink = true,
		Size = UDim2.new(0.6, 0, 0, Theme.Size.TapMin),
		LayoutOrder = 6,
		Shadow = false,
		OnClick = function()
			ResumeCard._End()
		end,
	})
	gui.Parent = player:WaitForChild("PlayerGui")
	list:GetPropertyChangedSignal("AbsoluteContentSize"):Connect(layout)
	local cam = workspace.CurrentCamera
	if cam then
		cam:GetPropertyChangedSignal("ViewportSize"):Connect(layout)
	end
	local u: UI = { Gui = gui, Root = root, Scale = scale, Card = holder, List = list, Title = title, Info = info, Body = blurb, Resume = resume, End = stop }
	return u
end

local function handle()
	return {
		Blocks = true,
		Covers = false,
		Show = function()
			if ui then
				ui.Gui.Enabled = true
			end
		end,
		Hide = function()
			if ui then
				ui.Gui.Enabled = false
			end
		end,
	}
end

local function refresh()
	local u = ui
	if not u or not open then
		return
	end
	local left = ResumeCard.SecondsLeft()
	local infoText = player:GetAttribute("ResumeInfo")
	u.Info.Text = type(infoText) == "string" and infoText or ""
	u.Info.Visible = u.Info.Text ~= ""
	u.Resume.SetText(sending and "RESUMING..." or string.format("RESUME RUN (%s)", clockText(left)))
	u.Resume.SetEnabled(not sending)
	if endArmedUntil > 0 and os.clock() > endArmedUntil then
		endArmedUntil = 0
	end
	u.End.SetText(endArmedUntil > 0 and "TAP AGAIN TO END THE RUN" or "END RUN")
	u.End.SetEnabled(not sending)
end

local function show()
	if not ui then
		ui = build()
	end
	if not open then
		open = true
		sending = false
		endArmedUntil = 0
		UIState.Open(NAME, handle())
		if ui then
			ui.Gui.Enabled = UIState.IsShown(NAME)
		end
	end
	refresh()
	task.defer(layout)
end

local function close()
	if not open then
		return
	end
	open = false
	sending = false
	UIState.Close(NAME)
	if ui then
		ui.Gui.Enabled = false
	end
end

local function update()
	if wanted() then
		show()
	else
		close()
	end
end

function ResumeCard._Resume()
	if not open or sending or not UIState.IsShown(NAME) or ResumeCard.SecondsLeft() <= 0 then
		return
	end
	sending = true
	table.insert(sent, "Resume")
	UIKit.Click()
	Remotes.Get("QuickResume"):FireServer("Resume")
	refresh()
	-- no answer (a dropped request): the button comes back after a moment
	task.delay(6, function()
		if open and sending then
			sending = false
			refresh()
		end
	end)
end

function ResumeCard._End()
	if not open or sending or not UIState.IsShown(NAME) then
		return
	end
	if endArmedUntil > 0 and os.clock() <= endArmedUntil then
		endArmedUntil = 0
		table.insert(sent, "End")
		UIKit.Click()
		Remotes.Get("QuickResume"):FireServer("End")
		sending = true
		refresh()
		return
	end
	endArmedUntil = os.clock() + END_CONFIRM
	UIKit.Click()
	refresh()
end

function ResumeCard.Init()
	if not on() then
		return
	end
	for _, attr in ipairs({ "ResumeEndsAt", "InRun", "Travel" }) do
		player:GetAttributeChangedSignal(attr):Connect(update)
	end
	local acc = 0
	RunService.Heartbeat:Connect(function(dt)
		acc += dt
		if acc < 0.25 then
			return
		end
		acc = 0
		if open or player:GetAttribute("ResumeEndsAt") ~= nil then
			update()
			refresh()
		end
	end)
	update()
end

function ResumeCard.Debug(): { [string]: any }
	local u = ui
	return {
		Open = open and u ~= nil and u.Gui.Enabled,
		Button = u and string.format("RESUME RUN (%s)", clockText(ResumeCard.SecondsLeft())) or "",
		Info = u and u.Info.Text or "",
		Sent = table.clone(sent),
	}
end

return ResumeCard
