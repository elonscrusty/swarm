--[[
	BugReportUI.lua
	The "Report a bug" form, opened from the pause menu (in a run) and from SETTINGS (in
	the lobby): a category, a short text (BugReportData.MaxLength characters) and a line
	showing the context that is attached automatically (stage, arena, hero, level, device,
	version). SEND fires the BugReport remote and waits for BugReportResult: the form only
	says "sent" when the server says the report was saved; a failure or no answer is shown
	as such, never as a success.

	The server (BugReportService) cleans and filters the text, re-derives the context itself
	and rate limits; the client side here is only convenience.
]]

local Players = game:GetService("Players")
local UserInputService = game:GetService("UserInputService")
local GuiService = game:GetService("GuiService")
local VRService = game:GetService("VRService")

local Shared = game:GetService("ReplicatedStorage"):WaitForChild("Shared")
local Config = require(Shared:WaitForChild("Config"))
local Remotes = require(Shared:WaitForChild("Remotes"))
local Theme = require(Shared:WaitForChild("Theme"))
local B = require(Shared:WaitForChild("BugReportData"))
local UIKit = require(script.Parent.UIKit)

local BugReportUI = {}

local player = Players.LocalPlayer
local new, text, TS = UIKit.new, UIKit.text, UIKit.TS
local C = Theme.Color

local ANSWER_TIMEOUT = 25 -- seconds to wait for the server's answer

local host: { [string]: any } = {}
local ui: { [string]: any } = {}
local category = B.Categories[1].Id
local sending = false
local sendToken = 0
local relayout: () -> () = function() end

-- "Phone" | "Tablet" | "Desktop" | "Console" | "VR"
local function deviceType(): string
	local ok, vr = pcall(function()
		return VRService.VREnabled
	end)
	if ok and vr then
		return "VR"
	end
	if GuiService:IsTenFootInterface() then
		return "Console"
	end
	if UserInputService.TouchEnabled and not UserInputService.KeyboardEnabled then
		local cam = workspace.CurrentCamera
		local v = cam and cam.ViewportSize or Vector2.new(800, 600)
		return math.min(v.X, v.Y) < 700 and "Phone" or "Tablet"
	end
	return "Desktop"
end

-- What the client knows; the server keeps this apart from its own context.
local function clientContext(): { [string]: any }
	local state = Remotes.State()
	local inRun = player:GetAttribute("InRun") == true
	local cam = workspace.CurrentCamera
	local v = cam and cam.ViewportSize or Vector2.zero
	return {
		InRun = inRun,
		Stage = inRun and state:GetAttribute("Stage") or nil,
		Arena = inRun and state:GetAttribute("Arena") or nil,
		Character = inRun and player:GetAttribute("CharacterId") or nil,
		Level = inRun and player:GetAttribute("Level") or nil,
		Device = deviceType(),
		Version = Config.Version,
		Screen = string.format("%dx%d", math.floor(v.X), math.floor(v.Y)),
	}
end

local function setStatus(str: string, color: Color3?)
	ui.Status.Text = str
	ui.Status.TextColor3 = color or C.TextMuted
end

local function length(): number
	return utf8.len(ui.Box.Text) or #ui.Box.Text
end

local function refreshCount()
	local n = length()
	ui.Count.Text = string.format("%d / %d", n, B.MaxLength)
	ui.Count.TextColor3 = n > B.MaxLength * 0.9 and C.Warning or C.TextFaint
	ui.Send.SetEnabled(not sending and n >= B.MinLength)
end

local function setSending(on: boolean)
	sending = on
	ui.Send.SetText(on and "SENDING..." or "SEND")
	ui.Box.TextEditable = not on
	refreshCount()
end

local function send()
	if sending then
		return
	end
	local clean, why = B.CleanText(ui.Box.Text)
	if not clean then
		setStatus(why or "Write what happened first.", C.Danger)
		return
	end
	setSending(true)
	setStatus("Sending your report...", C.TextMuted)
	sendToken += 1
	local token = sendToken
	Remotes.Get("BugReport"):FireServer({ Category = category, Text = clean, Client = clientContext() })
	task.delay(ANSWER_TIMEOUT, function()
		if sending and sendToken == token then
			setSending(false)
			setStatus("No answer from the server, so the report may not have been saved. Try again later.", C.Danger)
		end
	end)
end

local function onResult(data: any)
	if type(data) ~= "table" or not sending then
		return
	end
	sendToken += 1
	setSending(false)
	local message = type(data.Message) == "string" and data.Message or "Report could not be saved."
	if data.Ok == true then
		ui.Box.Text = ""
		setStatus("", nil)
		BugReportUI.Close()
		if host.Toast then
			host.Toast(message, C.Success)
		end
	else
		setStatus(message, C.Danger)
	end
end

function BugReportUI.Open()
	if not ui.Overlay then
		return
	end
	ui.Context.Text = "Attached: " .. B.ContextLine(clientContext())
	if not sending then
		setStatus("Please don't include personal info. Reports are text filtered.", C.TextFaint)
	end
	refreshCount()
	relayout()
	host.Show(ui.Overlay, "BugReport", true)
	UIKit.FocusIfGamepad(ui.Box)
end

function BugReportUI.Close()
	if ui.Overlay then
		ui.Box:ReleaseFocus()
		host.Hide(ui.Overlay, "BugReport")
	end
end

function BugReportUI.IsOpen(): boolean
	return ui.Overlay ~= nil and ui.Overlay.Visible
end

--[[
	h: Show(overlay, name, blocks), Hide(overlay, name), FitModal(modal, list),
	   OnRelayout(fn), VirtualSize(), Toast(str, color)
]]
function BugReportUI.Build(root: Instance, h: { [string]: any })
	host = h
	local m = UIKit.Modal(root, "BugReport", 600, 520, Theme.Z.Pause + 3)
	ui.Overlay = m.Overlay
	local content = m.Content
	h.FitModal(m, UIKit.list(content, { Padding = UDim.new(0, 10), HorizontalAlignment = Enum.HorizontalAlignment.Center }))

	text(content, "H1", "REPORT A BUG", { LayoutOrder = 1, TextXAlignment = Enum.TextXAlignment.Center })
	text(content, "Body", "What happened, and what were you doing?", {
		LayoutOrder = 2,
		TextXAlignment = Enum.TextXAlignment.Center,
		TextWrapped = true,
		Size = UDim2.new(1, 0, 0, TS(16) + 8),
	})

	local items = {}
	for _, c in ipairs(B.Categories) do
		table.insert(items, { Id = c.Id, Title = c.Title })
	end
	ui.Tabs = UIKit.Tabs(content, items, function(id)
		category = id
	end, { LayoutOrder = 3 })

	-- text well
	local well = new("Frame", {
		Name = "Well",
		LayoutOrder = 4,
		BackgroundColor3 = C.PanelInset,
		BackgroundTransparency = 0.15,
		BorderSizePixel = 0,
		Size = UDim2.new(1, 0, 0, 150),
	}, content)
	UIKit.corner(well, Theme.Radius.M)
	ui.WellStroke = UIKit.stroke(well, C.PanelEdge, Theme.Stroke.Thin, Theme.Alpha.Edge)
	UIKit.pad(well, 10)
	ui.Box = new("TextBox", {
		Name = "ReportText",
		BackgroundTransparency = 1,
		Size = UDim2.fromScale(1, 1),
		ClearTextOnFocus = false,
		MultiLine = true,
		TextWrapped = true,
		RichText = false,
		Text = "",
		PlaceholderText = "e.g. The portal didn't open after I killed the boss on stage 2.",
		PlaceholderColor3 = C.TextFaint,
		TextColor3 = C.Text,
		FontFace = Theme.Font.Body,
		TextSize = TS(Theme.TextSize.Body),
		TextXAlignment = Enum.TextXAlignment.Left,
		TextYAlignment = Enum.TextYAlignment.Top,
	}, well)
	ui.Box:GetPropertyChangedSignal("Text"):Connect(function()
		local s = ui.Box.Text
		local n = utf8.len(s)
		if n and n > B.MaxLength then
			local cut = utf8.offset(s, B.MaxLength + 1)
			if cut then
				ui.Box.Text = string.sub(s, 1, cut - 1)
				return
			end
		end
		refreshCount()
	end)
	ui.Box.Focused:Connect(function()
		ui.WellStroke.Color = C.Focus
		ui.WellStroke.Transparency = Theme.Alpha.EdgeStrong
	end)
	ui.Box.FocusLost:Connect(function()
		ui.WellStroke.Color = C.PanelEdge
		ui.WellStroke.Transparency = Theme.Alpha.Edge
	end)

	-- attached context + character count
	local meta = new("Frame", { Name = "Meta", BackgroundTransparency = 1, LayoutOrder = 5, Size = UDim2.new(1, 0, 0, TS(14) + 8) }, content)
	ui.Context = text(meta, "Small", "", {
		Size = UDim2.new(1, -96, 1, 0),
		TextTruncate = Enum.TextTruncate.AtEnd,
		TextColor3 = C.TextFaint,
	})
	ui.Count = text(meta, "Small", "0 / " .. B.MaxLength, {
		AnchorPoint = Vector2.new(1, 0),
		Position = UDim2.fromScale(1, 0),
		Size = UDim2.new(0, 90, 1, 0),
		TextXAlignment = Enum.TextXAlignment.Right,
	})

	ui.Status = text(content, "Small", "", {
		LayoutOrder = 6,
		TextWrapped = true,
		TextXAlignment = Enum.TextXAlignment.Center,
		Size = UDim2.new(1, 0, 0, 2 * (TS(14) + 2) + 4),
	})

	local row = new("Frame", { Name = "Buttons", BackgroundTransparency = 1, LayoutOrder = 7, Size = UDim2.new(1, 0, 0, Theme.Size.Button) }, content)
	UIKit.list(row, { FillDirection = Enum.FillDirection.Horizontal, HorizontalAlignment = Enum.HorizontalAlignment.Center, VerticalAlignment = Enum.VerticalAlignment.Center, Padding = UDim.new(0, 12) })
	ui.Cancel = UIKit.Button(row, {
		Kind = "Secondary",
		Title = "CANCEL",
		Align = "Center",
		Size = UDim2.fromOffset(200, Theme.Size.Button - 4),
		LayoutOrder = 1,
		OnClick = BugReportUI.Close,
	})
	ui.Send = UIKit.Button(row, {
		Kind = "Primary",
		Title = "SEND",
		Icon = "check",
		IconSize = 20,
		Align = "Center",
		Size = UDim2.fromOffset(220, Theme.Size.Button),
		LayoutOrder = 2,
		OnClick = send,
	})
	UIKit.IconButton(m.Face, {
		Icon = "close",
		Size = 40,
		Kind = "Ghost",
		AnchorPoint = Vector2.new(1, 0),
		Position = UDim2.new(1, -10, 0, 10),
		ZIndex = 5,
		OnClick = BugReportUI.Close,
	})

	local function layout()
		local v: Vector2 = h.VirtualSize()
		local w = math.min(600, v.X - 32)
		m.Panel.Size = UDim2.new(UDim.new(0, w), m.Panel.Size.Y)
		local inner = w - 2 * Theme.Space.XL
		-- the text well gives way first on short (landscape phone) screens
		local fixed = (TS(30) + 6) + (TS(16) + 8) + Theme.Size.TapMin + (TS(14) + 8) + ui.Status.Size.Y.Offset + Theme.Size.Button + 6 * 10 + 2 * Theme.Space.XL + 8
		well.Size = UDim2.new(1, 0, 0, math.clamp(v.Y - 24 - fixed, 84, 170))
		local bw = math.clamp(math.floor((inner - 12) / 2), 120, 220)
		ui.Cancel.Instance.Size = UDim2.fromOffset(bw, Theme.Size.Button - 4)
		ui.Send.Instance.Size = UDim2.fromOffset(bw, Theme.Size.Button)
	end
	relayout = layout
	h.OnRelayout(layout)
	layout()

	Remotes.Get("BugReportResult").OnClientEvent:Connect(onResult)
	-- leaving / entering a run closes the form (the pause menu closes with it)
	player:GetAttributeChangedSignal("InRun"):Connect(function()
		if BugReportUI.IsOpen() then
			BugReportUI.Close()
		end
	end)
	refreshCount()
	setStatus("", nil)
end

return BugReportUI
