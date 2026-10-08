--[[
	ReviveThanks.lua (client; Config.Features.ReviveThanks, Config.Revive;
	docs/next/REVIVE_THANKS.md)
	After a teammate revives you the server sends ReviveThanksOffer { Id, Seconds, FromName }.
	This shows a yellow THANKS! button for Seconds (6) low in the middle of the screen, away
	from JUMP and ULT (bottom right, or bottom left when left-handed) and from the movement
	stick, in its own ScreenGui. A tap sends only the offer id (remote ReviveThanks); the
	server decides everything (the reviver's notice and run XP, the limits). The button hides
	after one tap, when the time is up, when the run ends / you go down again, and under any
	panel (it follows FeatureHud.Visible, which is UIState aware).

	ReviveThanks.Active() -> boolean, ReviveThanks.Tap() -> boolean (tests drive both),
	ReviveThanks.Receive(d) takes a ReviveThanksOffer payload.
]]

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")

local Shared = game:GetService("ReplicatedStorage"):WaitForChild("Shared")
local Config = require(Shared:WaitForChild("Config"))
local Remotes = require(Shared:WaitForChild("Remotes"))
local UIKit = require(script.Parent.UIKit)
local UIAnim = require(script.Parent.UIAnim)
local UIState = require(script.Parent.UIState)
local FeatureHud = require(script.Parent.FeatureHud)

local ReviveThanks = {}

local player = Players.LocalPlayer

local WIDTH, HEIGHT = 168, 52

local offer: { Id: number, Until: number, From: string }? = nil
local screen: ScreenGui? = nil
local holder: Frame? = nil
local root: Frame? = nil
local nextPlace = 0
local started = false

local function cfg(): { [string]: any }
	return (Config :: any).Revive
end

function ReviveThanks.Enabled(): boolean
	return Config.FeatureOn("ReviveThanks")
end

-- True while a THANKS! offer is open (its 6 s have not run out and it was not used).
function ReviveThanks.Active(): boolean
	local o = offer
	return o ~= nil and os.clock() < o.Until
end

-- Whether the button is on screen now (open offer, in a run, no panel over the HUD).
function ReviveThanks.Showing(): boolean
	return ReviveThanks.Active() and holder ~= nil and holder.Visible
end

local function clear()
	offer = nil
	if holder then
		holder.Visible = false
	end
	if screen then
		screen.Enabled = false
	end
end

-- A ReviveThanksOffer payload from the server.
function ReviveThanks.Receive(d: any): boolean
	if not ReviveThanks.Enabled() or type(d) ~= "table" then
		return false
	end
	local id, seconds = d.Id, d.Seconds
	if type(id) ~= "number" or id ~= id or type(seconds) ~= "number" or seconds ~= seconds or seconds <= 0 then
		return false
	end
	-- never longer than our own config says, whatever the message claims
	seconds = math.min(seconds, cfg().ThanksSeconds)
	local from = type(d.FromName) == "string" and string.sub(d.FromName, 1, 40) or ""
	offer = { Id = id, Until = os.clock() + seconds, From = from }
	if holder then
		UIAnim.Pop(holder, 0, 0.5)
	end
	return true
end

-- Taps THANKS!: sends the offer id once and hides the button. False when nothing is open.
function ReviveThanks.Tap(): boolean
	local o = offer
	if not o or not ReviveThanks.Active() then
		return false
	end
	offer = nil -- once per revive: the button is gone before the server answers
	Remotes.Get("ReviveThanks"):FireServer(o.Id)
	clear()
	return true
end

-- Bottom centre, just above whatever sits low in the middle: the HUD's weapon / passive tray
-- (AbilityBar) and a tutorial tip (TipBubble / TipCard). Where nothing is there (portrait)
-- it sits a little above the edge.
local OBSTACLES = { "AbilityBar", "TipBubble", "TipCard" }
local function place()
	local r, h = root, holder
	if not r or not h then
		return
	end
	local size = r.AbsoluteSize
	if size.X <= 1 then
		return
	end
	local origin = r.AbsolutePosition
	local cx = origin.X + size.X / 2
	local y = size.Y - 28
	local pg = player:FindFirstChild("PlayerGui")
	local main = pg and pg:FindFirstChild("SwarmUI")
	if main then
		for _, name in ipairs(OBSTACLES) do
			local g = main:FindFirstChild(name, true)
			if g and g:IsA("GuiObject") and g.Visible and g.AbsoluteSize.X > 1 then
				local p, sz = g.AbsolutePosition, g.AbsoluteSize
				-- only what is in the lower half and under the button's column
				if p.Y > origin.Y + size.Y * 0.4 and p.X < cx + WIDTH / 2 and p.X + sz.X > cx - WIDTH / 2 then
					y = math.min(y, p.Y - origin.Y - 8)
				end
			end
		end
	end
	h.Position = UDim2.fromOffset(math.floor(size.X / 2 + 0.5), math.max(HEIGHT, math.floor(y + 0.5)))
end

local function step()
	local o = offer
	if o == nil then
		return
	end
	local covered = UIState.Covered() or UIState.Owner() ~= nil
	local inRun = player:GetAttribute("InRun") == true
	if os.clock() >= o.Until or not inRun or player:GetAttribute("Alive") == false then
		clear()
		return
	end
	local show = FeatureHud.Visible() and not covered and player:GetAttribute("Paused") ~= true
	if holder and holder.Visible ~= show then
		holder.Visible = show
		nextPlace = 0
	end
	if show and os.clock() >= nextPlace then
		nextPlace = os.clock() + 0.5
		place()
	end
	if screen and screen.Enabled ~= show then
		screen.Enabled = show
	end
end

function ReviveThanks.Init()
	if started then
		return
	end
	started = true
	local playerGui = player:WaitForChild("PlayerGui")
	local gui = UIKit.new("ScreenGui", { Name = "ReviveThanks", ResetOnSpawn = false, IgnoreGuiInset = true, ScreenInsets = Enum.ScreenInsets.DeviceSafeInsets, DisplayOrder = 12, Enabled = false }, playerGui) :: ScreenGui
	screen = gui
	-- bottom centre, a little above the edge: JUMP / ULT are on the right (or left when
	-- left-handed), the stick is a left thumb zone, the HUD panels are at the top
	local r = UIKit.new("Frame", { Name = "Root", BackgroundTransparency = 1, Size = UDim2.fromScale(1, 1) }, gui) :: Frame
	root = r
	local h = UIKit.new("Frame", {
		Name = "Holder",
		BackgroundTransparency = 1,
		AnchorPoint = Vector2.new(0.5, 1),
		Position = UDim2.new(0.5, 0, 1, -28),
		Size = UDim2.fromOffset(WIDTH, HEIGHT),
		Visible = false,
	}, r) :: Frame
	holder = h
	UIKit.Button(h, {
		Kind = "Primary",
		Title = "THANKS!",
		TitleStyle = "Label",
		TitleSize = 20,
		Align = "Center",
		Shrink = true,
		Glow = true,
		Name = "ThanksButton",
		Size = UDim2.fromOffset(WIDTH, HEIGHT),
		Position = UDim2.fromOffset(0, 0),
		OnClick = function()
			ReviveThanks.Tap()
		end,
	})
	Remotes.Get("ReviveThanksOffer").OnClientEvent:Connect(function(d)
		ReviveThanks.Receive(d)
	end)
	RunService.RenderStepped:Connect(step)
end

return ReviveThanks
