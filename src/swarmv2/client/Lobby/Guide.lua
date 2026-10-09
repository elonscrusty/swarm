--!strict
--[[
	SwarmV2Client/Lobby/Guide.lua
	OWNER: lobby track (Chat 1), stream L1. The first-time guide: five short steps (about 40 seconds
	to read): choose a class, optionally form a party, join a queue, the controls of THIS device, and
	how a run goes (attacks are automatic, defeated enemies give XP, levelling offers three upgrades).

	Skippable at every step (SKIP, Escape, gamepad B closes it), BACK / NEXT, a step counter. It opens by
	itself once for a player whose save says they have never started a run (LobbyClient decides, from
	the real profile, never from missing data) and can be reopened any time from HOW TO PLAY on the
	home screen or Settings > How to play. Reopening never changes any flag.
]]

local UserInputService = game:GetService("UserInputService")

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Kit = require(script.Parent.Kit)
local Brief = require(script.Parent.Brief)
local CodexData = require(ReplicatedStorage:WaitForChild("SwarmV2"):WaitForChild("Lobby"):WaitForChild("CodexData"))

local UIKit = Kit.UIKit
local new = UIKit.new
local T = Brief.T

local Guide = {}

export type Panel = {
	Open: (reopen: boolean?, device: string?) -> (),
	Close: () -> (),
	IsOpen: () -> boolean,
	Layout: (ctx: Kit.Ctx) -> (),
	Back: () -> boolean,
	State: () -> { [string]: any },
}

-- The device whose controls the guide shows: "Gamepad" | "Touch" | "Keyboard".
function Guide.Device(): string
	local last = UserInputService:GetLastInputType()
	if last == Enum.UserInputType.Gamepad1 or last == Enum.UserInputType.Gamepad2 then
		return "Gamepad"
	end
	if UserInputService.TouchEnabled and not UserInputService.KeyboardEnabled then
		return "Touch"
	end
	return "Keyboard"
end

-- one list of controls for the guide and the codex (SwarmV2.Lobby.CodexData)
Guide.Controls = CodexData.Controls

type Step = { Title: string, Where: string?, Lines: { string }, Controls: boolean? }

Guide.Steps = {
	{
		Title = "1. Choose your class",
		Where = "Top left: CLASSES",
		Lines = { "Open CLASSES, pick a class you own and press SELECT. Ruckus is free. Locked classes show how to earn them." },
	},
	{
		Title = "2. Bring friends (optional)",
		Where = "Top left: PARTY",
		Lines = { "Use PARTY to invite players who are in this camp. Playing solo is fine too." },
	},
	{
		Title = "3. Join a queue",
		Where = "Bottom right: PLAY",
		Lines = { "Press PLAY, pick a gate, then press READY. When everyone is ready a 10 second countdown starts." },
	},
	{
		Title = "4. Controls",
		Lines = {},
		Controls = true,
	},
	{
		Title = "5. How a run goes",
		Lines = { "Defeated enemies drop XP. Fill the bar to level up and pick one of three upgrades. In a team run the fight keeps going while you choose." },
	},
} :: { Step }

function Guide.Build(ctx: Kit.Ctx, onDone: (completed: boolean, reopened: boolean) -> ()): Panel
	local isOpen = false
	local reopened = false
	local step = 1
	local deviceName = "Keyboard"
	local compact = ctx.Compact

	local overlay = new("Frame", {
		Name = "LobbyGuide",
		BackgroundTransparency = 1,
		Size = UDim2.fromScale(1, 1),
		Visible = false,
		Active = true,
		ZIndex = 40,
	}, ctx.Root)
	local dim = new("TextButton", {
		Name = "Dim",
		Text = "",
		AutoButtonColor = false,
		BackgroundColor3 = T.NavyDeep,
		BackgroundTransparency = 0.35,
		BorderSizePixel = 0,
		Size = UDim2.fromScale(1, 1),
		ZIndex = 40,
		Selectable = false,
	}, overlay)
	local card = Brief.panel(overlay, {
		Name = "Card",
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.5),
		Size = UDim2.fromOffset(560, 330),
		ZIndex = 41,
		Active = true,
	})
	local counter = Brief.label(card, "Caption", "", { Name = "Counter", Position = UDim2.fromOffset(20, 14), Size = UDim2.new(1, -40, 0, 20), TextColor3 = T.Gold, ZIndex = 42 }, compact)
	local title = Brief.label(card, "Section", "", { Name = "StepTitle", Position = UDim2.fromOffset(20, 36), Size = UDim2.new(1, -40, 0, 34), TextTruncate = Enum.TextTruncate.AtEnd, ZIndex = 42 }, compact)
	local where = Brief.label(card, "Label", "", { Name = "Where", Position = UDim2.fromOffset(20, 72), Size = UDim2.new(1, -40, 0, 22), TextColor3 = T.Cyan, ZIndex = 42 }, compact)
	local body = Brief.label(card, "Body", "", { Name = "Body", Position = UDim2.fromOffset(20, 98), Size = UDim2.new(1, -40, 0, 120), TextWrapped = true, TextYAlignment = Enum.TextYAlignment.Top, ZIndex = 42 }, compact)
	body.FontFace = Brief.Weight.Regular
	local dots = new("Frame", { Name = "Dots", BackgroundTransparency = 1, AnchorPoint = Vector2.new(0.5, 1), Position = UDim2.new(0.5, 0, 1, -82), Size = UDim2.fromOffset(120, 12), ZIndex = 42 }, card)
	new("UIListLayout", { FillDirection = Enum.FillDirection.Horizontal, HorizontalAlignment = Enum.HorizontalAlignment.Center, VerticalAlignment = Enum.VerticalAlignment.Center, SortOrder = Enum.SortOrder.LayoutOrder, Padding = UDim.new(0, 8) }, dots)
	local skip: Brief.Button
	local back: Brief.Button
	local nextBtn: Brief.Button

	local function finish(completed: boolean)
		if not isOpen then
			return
		end
		isOpen = false
		overlay.Visible = false
		onDone(completed, reopened)
	end

	local function paint()
		local s = Guide.Steps[step]
		counter.Text = string.format("HOW TO PLAY  |  STEP %d OF %d  |  ABOUT 40 SECONDS", step, #Guide.Steps)
		title.Text = s.Title
		where.Text = s.Where or ""
		where.Visible = s.Where ~= nil
		local lines = {}
		if s.Controls then
			local deviceLabel = ({ Keyboard = "keyboard and mouse", Touch = "touch screen", Gamepad = "gamepad" } :: any)[deviceName]
			table.insert(lines, "Controls for your " .. deviceLabel .. ":")
			for _, l in ipairs(Guide.Controls[deviceName] or Guide.Controls.Keyboard) do
				table.insert(lines, l)
			end
			table.insert(lines, "Attacks are automatic: you only move, jump and dash.")
		else
			lines = s.Lines
		end
		body.Text = table.concat(lines, "\n")
		for _, ch in ipairs(dots:GetChildren()) do
			if ch:IsA("Frame") then
				ch:Destroy()
			end
		end
		for i = 1, #Guide.Steps do
			local d = new("Frame", { Name = "Dot" .. i, BackgroundColor3 = i == step and T.Cyan or T.Line, BorderSizePixel = 0, Size = UDim2.fromOffset(i == step and 24 or 12, 12), LayoutOrder = i, ZIndex = 43 }, dots)
			UIKit.corner(d, 6)
		end
		back.Instance.Visible = step > 1
		nextBtn.SetText(step == #Guide.Steps and "GOT IT" or "NEXT")
		skip.SetText(step == #Guide.Steps and "CLOSE" or "SKIP")
	end

	skip = Brief.button(card, { Name = "GuideSkip", Title = "SKIP", Size = UDim2.fromOffset(110, 56), AnchorPoint = Vector2.new(0, 1), Position = UDim2.new(0, 20, 1, -16), ZIndex = 43, Kind = "Quiet", OnClick = function()
		finish(false)
	end })
	back = Brief.button(card, { Name = "GuideBack", Title = "BACK", Size = UDim2.fromOffset(110, 56), AnchorPoint = Vector2.new(1, 1), Position = UDim2.new(1, -150, 1, -16), ZIndex = 43, Kind = "Secondary", OnClick = function()
		step = math.max(1, step - 1)
		paint()
	end })
	nextBtn = Brief.button(card, { Name = "GuideNext", Title = "NEXT", Size = UDim2.fromOffset(122, 56), AnchorPoint = Vector2.new(1, 1), Position = UDim2.new(1, -20, 1, -16), ZIndex = 43, Kind = "Primary", TitleSize = 20, OnClick = function()
		if step >= #Guide.Steps then
			finish(true)
		else
			step += 1
			paint()
			Brief.focusIfGamepad(nextBtn.Instance)
		end
	end })
	dim.Activated:Connect(function() end) -- the dimmer swallows taps; the guide closes with its buttons

	local panel: Panel
	panel = {
		Open = function(reopen: boolean?, device: string?)
			if isOpen then
				return
			end
			isOpen = true
			reopened = reopen == true
			step = 1
			deviceName = device or Guide.Device()
			overlay.Visible = true
			paint()
			Brief.focusIfGamepad(nextBtn.Instance)
		end,
		Close = function()
			finish(false)
		end,
		IsOpen = function(): boolean
			return isOpen
		end,
		Layout = function(c: Kit.Ctx)
			compact = c.Compact
			local w = math.min(560, c.W - 24)
			local h = c.Compact and (c.Portrait and 420 or 330) or 380
			card.Size = UDim2.fromOffset(w, h)
			local size = Brief.size("Body", compact)
			body.TextSize = size
			body.Size = UDim2.new(1, -40, 0, h - 98 - 100)
			title.TextSize = Brief.size("Section", compact)
			counter.TextSize = Brief.size("Caption", compact)
			where.TextSize = Brief.size("Label", compact)
			-- keep the three buttons inside narrow cards
			local bw = math.floor((w - 40 - 16) / 3)
			skip.Instance.Size = UDim2.fromOffset(math.min(110, bw), 56)
			back.Instance.Size = UDim2.fromOffset(math.min(110, bw), 56)
			nextBtn.Instance.Size = UDim2.fromOffset(math.min(122, bw + 12), 56)
			back.Instance.Position = UDim2.new(1, -(20 + nextBtn.Instance.Size.X.Offset + 10), 1, -16)
		end,
		Back = function(): boolean
			if not isOpen then
				return false
			end
			finish(false) -- Escape / B skips the guide
			return true
		end,
		State = function(): { [string]: any }
			return { Open = isOpen, Step = step, Steps = #Guide.Steps, Device = deviceName, Reopened = reopened, Body = body.Text, Title = title.Text }
		end,
	}
	return panel
end

return Guide
