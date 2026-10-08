--!strict
--[[
	SwarmV2Client/Lobby/Kit.lua  (StarterPlayerScripts.SwarmV2Client.Lobby.Kit)
	OWNER: lobby track (Chat 1). Shared bits of the basecamp lobby UI: the existing client
	modules (UIKit, Theme), debounced buttons, tap panels and the centred sheet (modal).
	Nothing here talks to the server.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Theme = require(Shared:WaitForChild("Theme"))
local clientRoot = script.Parent.Parent.Parent:WaitForChild("SwarmClient")
local UIKit = require(clientRoot:WaitForChild("UIKit"))
local Icons = require(clientRoot:WaitForChild("Icons"))

local C = Theme.Color

export type Ctx = {
	Gui: ScreenGui,
	Root: Frame,
	W: number, -- usable width in root (virtual) pixels
	H: number,
	Portrait: boolean,
	Touch: boolean,
	View: any?, -- LobbyNet.LobbyView
	Fire: (name: string, ...any) -> (),
	OpenSheet: (name: string?) -> (),
	Toast: (text: string, kind: string?) -> (),
}

local Kit = {}
Kit.UIKit = UIKit
Kit.Icons = Icons
Kit.Theme = Theme
Kit.C = C
Kit.M = 12 -- screen margin (virtual px)
Kit.TAP = 48

-- A function that ignores calls for 0.4 s after one went through (double taps).
function Kit.debounced(fn: (...any) -> ()): (...any) -> ()
	local busy = false
	return function(...)
		if busy then
			return
		end
		busy = true
		task.delay(0.4, function()
			busy = false
		end)
		fn(...)
	end
end

function Kit.txt(parent: Instance?, style: string, str: string, props: { [string]: any }?, size: number?): TextLabel
	return UIKit.text(parent, style, str, props, size)
end

-- UIKit.Button with a debounced OnClick. `o.Size` defaults to a finger-sized button.
function Kit.btn(parent: Instance?, o: { [string]: any }): any
	local click = o.OnClick
	if click then
		o.OnClick = Kit.debounced(click)
	end
	if not o.Size then
		o.Size = UDim2.fromOffset(160, Theme.Size.Button)
	end
	if not o.Depth then
		o.Depth = "Medium"
	end
	return UIKit.Button(parent, o)
end

-- A tappable panel (chip / card): holder, face and a transparent full-size TextButton on top.
function Kit.tapPanel(parent: Instance?, props: { [string]: any }, onClick: (() -> ())?): (Frame, Frame, TextButton)
	local holder, face = UIKit.Surface(parent, props)
	local hit = UIKit.new("TextButton", {
		Name = "Hit",
		Text = "",
		BackgroundTransparency = 1,
		Size = UDim2.fromScale(1, 1),
		ZIndex = 20,
		AutoButtonColor = false,
	}, holder)
	if onClick then
		hit.Activated:Connect(Kit.debounced(onClick))
	end
	return holder, face, hit
end

function Kit.clear(parent: Instance)
	for _, ch in ipairs(parent:GetChildren()) do
		if not ch:IsA("UIListLayout") and not ch:IsA("UIGridLayout") and not ch:IsA("UIPadding") then
			ch:Destroy()
		end
	end
end

export type Sheet = {
	Overlay: Frame,
	Body: Frame, -- below the header; fill it
	Head: Frame, -- the title row (extra labels can go here)
	Title: TextLabel,
	Open: () -> (),
	Close: () -> (),
	IsOpen: () -> boolean,
	Resize: (w: number, h: number) -> (),
}

-- A centred sheet over a dimmer: title, close X, a body frame. Tapping outside closes it.
function Kit.sheet(parent: Instance, name: string, title: string, onClose: () -> ()): Sheet
	local overlay = UIKit.new("Frame", {
		Name = name,
		Size = UDim2.fromScale(1, 1),
		BackgroundTransparency = 1,
		Visible = false,
		Active = true,
		ZIndex = 10,
	}, parent)
	local dim = UIKit.new("TextButton", {
		Name = "Dim",
		Text = "",
		AutoButtonColor = false,
		BackgroundColor3 = C.Backdrop,
		BackgroundTransparency = 0.45,
		BorderSizePixel = 0,
		Size = UDim2.fromScale(1, 1),
		ZIndex = 10,
	}, overlay)
	dim.Activated:Connect(onClose)
	local holder, face = UIKit.Surface(overlay, {
		Name = "Panel",
		Size = UDim2.fromOffset(600, 300),
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.5),
		Radius = Theme.Radius.L,
		Transparency = 0.02,
		ZIndex = 11,
	})
	local pad = UIKit.new("Frame", { Name = "Pad", BackgroundTransparency = 1, Size = UDim2.fromScale(1, 1), ZIndex = 12 }, face)
	UIKit.pad(pad, 14)
	local head = UIKit.new("Frame", { Name = "Head", BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 52), ZIndex = 12 }, pad)
	local ttl = UIKit.text(head, "H2", title, {
		Size = UDim2.new(1, -64, 1, 0),
		TextXAlignment = Enum.TextXAlignment.Left,
		FontFace = Theme.Font.Display,
		ZIndex = 12,
	}, 26)
	local close = Kit.btn(head, {
		Kind = "Danger",
		Icon = "close",
		IconSize = 22,
		Size = UDim2.fromOffset(52, 52),
		AnchorPoint = Vector2.new(1, 0.5),
		Position = UDim2.fromScale(1, 0.5),
		Name = "Close",
		Depth = "Light",
		ZIndex = 14,
		OnClick = onClose,
	})
	close.Instance.ZIndex = 14
	local body = UIKit.new("Frame", {
		Name = "Body",
		BackgroundTransparency = 1,
		Position = UDim2.fromOffset(0, 58),
		Size = UDim2.new(1, 0, 1, -58),
		ZIndex = 12,
	}, pad)
	holder.Parent = overlay
	local open = false
	local sheet: Sheet
	sheet = {
		Overlay = overlay,
		Body = body,
		Head = head,
		Title = ttl,
		Open = function()
			open = true
			overlay.Visible = true
		end,
		Close = function()
			open = false
			overlay.Visible = false
		end,
		IsOpen = function(): boolean
			return open
		end,
		Resize = function(w: number, h: number)
			holder.Size = UDim2.fromOffset(w, h)
		end,
	}
	return sheet
end

function Kit.me(): Player
	return Players.LocalPlayer
end

function Kit.gold(n: number): string
	return UIKit.formatNumber(n)
end

return Kit
