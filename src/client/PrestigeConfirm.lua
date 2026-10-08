--[[
	PrestigeConfirm.lua (client; Config.Features.Prestige, docs/next/PRESTIGE.md)
	The confirmation screen opened by PRESTIGE <HERO> on the Characters screen (MenuPrestige).
	Its own ScreenGui over the menu; a UIState primary ("PrestigeConfirm"), so nothing else
	takes input while it shows and a higher panel suspends it.

	It says exactly what happens, in the owner's words:
	  "Your Knight's upgrades go back to level 0. You keep your gold, skins and other heroes.
	   You get ★1 and +5% gold with the Knight."
	then RESETS / STAYS / YOU GET rows, and two buttons: PRESTIGE KNIGHT and CANCEL.
	PRESTIGE KNIGHT needs a second tap within Config.Prestige.ConfirmSeconds (3 s): the first
	tap only arms it (the hint line counts down), a tap in the first moment after the screen
	opened never counts, and the request is sent once. The server (Prestige.lua) checks the
	track, the stars and the cooldown again; nothing resets without that second tap.

	  PrestigeConfirm.Open(heroId, stars)  stars = the hero's stars now
	  PrestigeConfirm.Close()
	  PrestigeConfirm.Debug() -> { Open, Text, Button, Hint, Sent }   (preview / tests)
]]

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")

local Shared = game:GetService("ReplicatedStorage"):WaitForChild("Shared")
local Config = require(Shared:WaitForChild("Config"))
local Remotes = require(Shared:WaitForChild("Remotes"))
local Theme = require(Shared:WaitForChild("Theme"))
local CharacterData = require(Shared:WaitForChild("CharacterData"))
local MetaUpgradeData = require(Shared:WaitForChild("MetaUpgradeData"))
local PrestigeData = require(Shared:WaitForChild("PrestigeData"))
local UIKit = require(script.Parent.UIKit)
local UIState = require(script.Parent.UIState)

local PrestigeConfirm = {}

local player = Players.LocalPlayer
local new, text, TS = UIKit.new, UIKit.text, UIKit.TS
local C, P = Theme.Color, Theme.Palette
local HEADING = Font.fromEnum(Enum.Font.GothamBold)
local NAME = "PrestigeConfirm"
local OPEN_GUARD = 0.35 -- seconds after opening in which a tap never counts

type UI = {
	Gui: ScreenGui,
	Root: Frame,
	Scale: UIScale,
	Card: Frame,
	Scroll: ScrollingFrame,
	List: UIListLayout,
	Title: TextLabel,
	Body: TextLabel,
	Resets: TextLabel,
	Stays: TextLabel,
	Gets: TextLabel,
	Hint: TextLabel,
	Confirm: any,
	Cancel: any,
}

local ui: UI? = nil
local state = { Open = false, Hero = "", Stars = 0, OpenedAt = 0, ArmedUntil = 0, Sent = 0 }
local stepConn: RBXScriptConnection? = nil

local function seconds(): number
	return math.max(1, tonumber(((Config :: any).Prestige or {}).ConfirmSeconds) or 3)
end

local function virtualSize(): Vector2
	local cam = workspace.CurrentCamera
	local size = cam and cam.ViewportSize or Vector2.new(1280, 720)
	local s = ui and ui.Scale.Scale or 1
	return Vector2.new(size.X / s, size.Y / s)
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
	local v = virtualSize()
	local w = math.floor(math.min(560, v.X - 32))
	local contentH = u.List.AbsoluteContentSize.Y / math.max(0.01, s)
	local h = math.floor(math.min(contentH + 2 * 22, v.Y - 40))
	u.Card.Size = UDim2.fromOffset(w, math.max(160, h))
	u.Scroll.CanvasSize = UDim2.fromOffset(0, math.ceil(contentH))
end

local function row(parent: Instance, order: number, name: string): TextLabel
	return text(parent, "Body", "", {
		Name = name,
		LayoutOrder = order,
		Size = UDim2.new(1, 0, 0, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		TextWrapped = true,
		RichText = true,
		LineHeight = 1.12,
		TextColor3 = P.ivory_200,
		TextYAlignment = Enum.TextYAlignment.Top,
	}, 15)
end

local function build(): UI
	local gui = new("ScreenGui", {
		Name = "PrestigeConfirm",
		IgnoreGuiInset = true,
		ResetOnSpawn = false,
		DisplayOrder = 80, -- over the menu, under the travel cover (90)
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
		Active = true, -- the menu under it is not tapped blind
		Size = UDim2.fromScale(1, 1),
	}, root)
	local holder, face = UIKit.Surface(root, {
		Name = "Card",
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.5),
		Size = UDim2.fromOffset(520, 360),
		Radius = Theme.Radius.L,
		Transparency = 0.04,
		ZIndex = 2,
	})
	local scroll = new("ScrollingFrame", {
		Name = "Scroll",
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		Position = UDim2.fromOffset(22, 22),
		Size = UDim2.new(1, -44, 1, -44),
		ScrollBarThickness = 4,
		ScrollingDirection = Enum.ScrollingDirection.Y,
		CanvasSize = UDim2.fromOffset(0, 0),
		ZIndex = 3,
	}, face)
	local list = UIKit.list(scroll, { Padding = UDim.new(0, 10), HorizontalAlignment = Enum.HorizontalAlignment.Center })
	local title = text(scroll, "H2", "PRESTIGE", {
		Name = "Title",
		LayoutOrder = 1,
		FontFace = HEADING,
		Size = UDim2.new(1, 0, 0, TS(24) + 6),
		TextXAlignment = Enum.TextXAlignment.Center,
		TextColor3 = P.gold_200,
		TextScaled = true,
	}, 24)
	local fit = Instance.new("UITextSizeConstraint")
	fit.MaxTextSize = TS(24)
	fit.MinTextSize = 12
	fit.Parent = title
	title:SetAttribute("NoTextFit", true)
	UIKit.Hairline(scroll, { LayoutOrder = 2 })
	local body = row(scroll, 3, "Body")
	body.TextColor3 = P.ivory_100
	body.TextXAlignment = Enum.TextXAlignment.Center
	local resets = row(scroll, 4, "Resets")
	local stays = row(scroll, 5, "Stays")
	local gets = row(scroll, 6, "Gets")
	local buttons = new("Frame", { Name = "Buttons", BackgroundTransparency = 1, LayoutOrder = 7, Size = UDim2.new(1, 0, 0, Theme.Size.TapMin + 4) }, scroll)
	local confirm = UIKit.Button(buttons, {
		Name = "PrestigeConfirmButton",
		Kind = "Primary",
		Title = "PRESTIGE",
		Align = "Center",
		Shrink = true,
		Size = UDim2.new(0.6, -6, 1, 0),
		Position = UDim2.fromScale(0, 0),
		Shadow = false,
		OnClick = function()
			PrestigeConfirm._Tap()
		end,
	})
	local cancel = UIKit.Button(buttons, {
		Name = "PrestigeCancel",
		Kind = "Secondary",
		Title = "CANCEL",
		Align = "Center",
		Shrink = true,
		Size = UDim2.new(0.4, -6, 1, 0),
		Position = UDim2.fromScale(1, 0),
		AnchorPoint = Vector2.new(1, 0),
		Shadow = false,
		OnClick = function()
			PrestigeConfirm.Close()
		end,
	})
	local hint = row(scroll, 8, "Hint")
	hint.TextColor3 = P.ivory_300
	hint.TextXAlignment = Enum.TextXAlignment.Center
	holder.ZIndex = 2
	gui.Parent = player:WaitForChild("PlayerGui")
	local u: UI = {
		Gui = gui, Root = root, Scale = scale, Card = holder, Scroll = scroll, List = list, Title = title, Body = body,
		Resets = resets, Stays = stays, Gets = gets, Hint = hint, Confirm = confirm, Cancel = cancel,
	}
	list:GetPropertyChangedSignal("AbsoluteContentSize"):Connect(layout)
	local cam = workspace.CurrentCamera
	if cam then
		cam:GetPropertyChangedSignal("ViewportSize"):Connect(layout)
	end
	return u
end

local function hintText(): string
	local left = state.ArmedUntil - os.clock()
	local def = CharacterData.Characters[state.Hero]
	local button = PrestigeData.ButtonText(def and def.Name or state.Hero)
	if left > 0 then
		return string.format('<font color="%s"><b>Tap %s again to confirm (%d)</b></font>', UIKit.hex(P.gold_200), button, math.ceil(left))
	end
	return string.format("Tap %s twice within %d s to confirm. Nothing changes until then.", button, seconds())
end

local function refreshHint()
	local u = ui
	if u then
		u.Hint.Text = hintText()
	end
end

local function fill()
	local u = ui
	if not u then
		return
	end
	local def = CharacterData.Characters[state.Hero]
	local name = def and def.Name or state.Hero
	local nextStars = state.Stars + 1
	u.Title.Text = string.format("PRESTIGE %s  %s", string.upper(name), PrestigeData.StarText(nextStars))
	u.Body.Text = PrestigeData.ConfirmText(name, nextStars)
	local gold, muted = UIKit.hex(P.gold_300), UIKit.hex(P.ivory_300)
	local n = #MetaUpgradeData.HeroOrder()
	u.Resets.Text = string.format('<font color="%s"><b>RESETS</b></font>  The %s\'s %d upgrades go to level 0 (you can buy them again).', UIKit.hex(P.crimson_300), name, n)
	u.Stays.Text = string.format('<font color="%s"><b>STAYS</b></font>  Gold, mastery level, skins, looks, unlocks and every other hero.', UIKit.hex(P.moss_300))
	u.Gets.Text = string.format('<font color="%s"><b>YOU GET</b></font>  %s and %s gold from %s runs <font color="%s">(paid when a run ends; no combat power)</font>.', gold, PrestigeData.StarText(nextStars), PrestigeData.PercentText(nextStars), name, muted)
	u.Confirm.SetText(PrestigeData.ButtonText(name))
	refreshHint()
	task.defer(layout)
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

function PrestigeConfirm.Open(heroId: string, stars: number)
	if not Config.FeatureOn("Prestige") or type(heroId) ~= "string" or not CharacterData.Characters[heroId] then
		return
	end
	if stars >= PrestigeData.MaxStars() then
		return
	end
	if not ui then
		ui = build()
	end
	state.Open = true
	state.Hero = heroId
	state.Stars = math.max(0, math.floor(stars))
	state.OpenedAt = os.clock()
	state.ArmedUntil = 0
	fill()
	UIState.Open(NAME, handle())
	if ui then
		ui.Gui.Enabled = UIState.IsShown(NAME)
		ui.Scroll.CanvasPosition = Vector2.zero
	end
	if not stepConn then
		stepConn = RunService.Heartbeat:Connect(function()
			if state.Open and state.ArmedUntil > 0 then
				if os.clock() > state.ArmedUntil then
					state.ArmedUntil = 0
				end
				refreshHint()
			end
		end)
	end
	layout()
end

function PrestigeConfirm.Close()
	state.Open = false
	state.ArmedUntil = 0
	UIState.Close(NAME)
	if ui then
		ui.Gui.Enabled = false
	end
end

-- PRESTIGE <HERO>: the first tap arms it, a second within ConfirmSeconds sends the request.
function PrestigeConfirm._Tap()
	if not state.Open or not UIState.IsShown(NAME) then
		return
	end
	local now = os.clock()
	if now - state.OpenedAt < OPEN_GUARD then
		return
	end
	if state.ArmedUntil > 0 and now <= state.ArmedUntil then
		state.ArmedUntil = 0
		state.Sent += 1
		UIKit.Click()
		Remotes.Get("Prestige"):FireServer(state.Hero, state.Stars)
		PrestigeConfirm.Close()
		return
	end
	state.ArmedUntil = now + seconds()
	UIKit.Click()
	refreshHint()
end

function PrestigeConfirm.IsOpen(): boolean
	return state.Open
end

function PrestigeConfirm.Debug(): { [string]: any }
	local u = ui
	return {
		Open = state.Open and u ~= nil and u.Gui.Enabled,
		Title = u and u.Title.Text or "",
		Text = u and u.Body.Text or "",
		Button = PrestigeData.ButtonText((CharacterData.Characters[state.Hero] or { Name = state.Hero }).Name),
		Hint = u and u.Hint.Text or "",
		Armed = state.ArmedUntil > 0,
		Sent = state.Sent,
	}
end

return PrestigeConfirm
