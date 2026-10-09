--[[
	WalkthroughClient.lua
	The client side of the interactive first-run walkthrough (server Walkthrough.lua,
	Config.Features.Walkthrough, docs/next/WALKTHROUGH.md). The server owns the steps and
	writes them on the local player:
	  Walkthrough   "Move" | "Dash" | "Fight" | "Gems" | "Upgrade" | "Chest" | "Beacon" on a
	                Cliffwood beacon run; "Move" | "Fight" | "Gems" | "Upgrade" | "Chest" | "Go"
	                on the old stage loop (nil = none)
	  WalkMode      "Beacon" on a beacon run (nil on the old stage loop)
	  WalkCount / WalkTotal   Fight progress ("2/5")
	  WalkTarget    the world point of the step (the ring, the nearest enemy, the chest)
	  WalkFree      the Chest step's chest is the free gift chest (first walkthrough only)
	The lines name the controls of the device in hand (InputPrompts.Mode): WASD / Space /
	Shift / right-drag on a computer, the stick / JUMP / DASH / swipe on a touch screen, the
	sticks / A / B on a gamepad.

	This module shows each step's short line in the tutorial speech bubble
	(TutorialBubble.lua, owned by Tutorial.lua while the walkthrough runs), aims its pointer
	at the world target (projected to the screen every frame), and draws a world marker
	(a glowing gold ground ring and a bouncing arrow) at the ring and the chest. Nothing here
	is Active: it never blocks a touch.

	Tutorial.Update calls Update every frame; while it returns true the walkthrough owns
	the bubble and the SmartTutorial tips that teach the same things are skipped.
]]

local Players = game:GetService("Players")
local GuiService = game:GetService("GuiService")

local Shared = game:GetService("ReplicatedStorage"):WaitForChild("Shared")
local Config = require(Shared:WaitForChild("Config"))
local Theme = require(Shared:WaitForChild("Theme"))
local InputPrompts = require(script.Parent.InputPrompts)
local TutorialBubble = require(script.Parent.TutorialBubble)
local StageUI = require(script.Parent.StageUI)
local ClientSettings = require(script.Parent.ClientSettings)
local GroundHeight = require(script.Parent.GroundHeight) -- ground under effects on maps with height

local WalkthroughClient = {}

local player = Players.LocalPlayer
local GOLD = Theme.Color.Primary -- the yellow guide ring / arrow (a gameplay cue, readable on every arena)
local RING_PIECES = 20

local kit: { [string]: any } = {}
local rootFrame: Frame? = nil
local shown: string? = nil -- the step whose line is in the bubble
local shownText = ""
local markerFolder: Folder? = nil
local markerAt: Vector3? = nil
local markerRing = false
local clock = 0

local ICONS = { Move = "boot", Dash = "arrowFast", Fight = "sword", Gems = "gem", Upgrade = "chevronsUp", Chest = "chest", Go = "portal", Beacon = "flag" }

local function step(): string?
	if (Config :: any).Features.Walkthrough ~= true then
		return nil
	end
	local s = player:GetAttribute("Walkthrough")
	return type(s) == "string" and s ~= "" and s or nil
end

local HOLD_KEY = { Touch = "", Mouse = "E", Gamepad = "X" } -- the interact key per device (LootUI)

local function holdWord(mode: string?): string
	local key = if mode then (HOLD_KEY[mode] or "") else InputPrompts.HoldKey()
	return key ~= "" and ("Hold " .. key) or "Hold the button"
end

local function beaconRun(): boolean
	return player:GetAttribute("WalkMode") == "Beacon"
end

-- The step's line (tiny and friendly; the device in hand decides the control words).
-- forceMode: "Touch" | "Mouse" | "Gamepad" instead of the device in hand (tests).
local function lineFor(s: string, forceMode: string?): string
	local mode = forceMode or InputPrompts.Mode()
	local beacon = beaconRun()
	if s == "Move" then
		if beacon then
			if mode == "Touch" then
				return "Drag on the left to walk, swipe on the right to look. Walk into the gold ring!"
			elseif mode == "Gamepad" then
				return "Left stick to walk, right stick to look. Walk into the gold ring!"
			end
			return "WASD to walk, right-drag to look. Walk into the gold ring!"
		end
		if mode == "Touch" then
			return "Drag to walk into the gold ring!"
		elseif mode == "Gamepad" then
			return "Use the left stick to walk into the gold ring!"
		end
		return "Use WASD to walk into the gold ring!"
	elseif s == "Dash" then
		if mode == "Touch" then
			return "Tap JUMP to hop, DASH to zoom ahead. Try a dash!"
		elseif mode == "Gamepad" then
			return "A jumps, B dashes. Try a dash!"
		end
		return "Space jumps, Shift dashes. Try a dash!"
	elseif s == "Fight" then
		local n, total = tonumber(player:GetAttribute("WalkCount")) or 0, tonumber(player:GetAttribute("WalkTotal")) or 5
		return string.format("Your weapon attacks by itself. Beat the bugs! %d/%d", math.min(n, total), total)
	elseif s == "Gems" then
		return beacon and "Grab your blue XP shards!" or "Pick up the blue gems!"
	elseif s == "Upgrade" then
		return "Pick an upgrade!"
	elseif s == "Chest" then
		if beacon then
			if player:GetAttribute("WalkFree") == true then
				return "Kills earn team gold for chests. This one's free: " .. holdWord(forceMode) .. "!"
			end
			return "Kills earn team gold. Open a chest when you have enough: " .. holdWord(forceMode)
		end
		return "Open the chest! " .. holdWord(forceMode)
	elseif s == "Beacon" then
		return "Survive and grow strong! At 12:30 a beacon appears: light it and beat the boss."
	elseif s == "Go" then
		return "Waves are coming! Find the portal and stand in its ring."
	end
	return ""
end

local function heroPos(): Vector3?
	local char = player.Character
	local root = char and char.PrimaryPart
	return root and root.Position or nil
end

-- A world point in root (virtual) pixels, clamped to the screen; nil behind the camera.
local function project(p: Vector3?): Vector2?
	local cam = workspace.CurrentCamera
	local root = rootFrame
	if not p or not cam or not root then
		return nil
	end
	local vp = cam:WorldToViewportPoint(p)
	if vp.Z <= 0 then
		return nil
	end
	local sg = root:FindFirstAncestorOfClass("ScreenGui")
	local inset = Vector2.zero
	if sg and not sg.IgnoreGuiInset then
		inset = GuiService:GetGuiInset()
	end
	local pt = TutorialBubble.ToRoot(Vector2.new(vp.X, vp.Y) - inset)
	if not pt then
		return nil
	end
	local v: Vector2 = kit.VirtualSize and kit.VirtualSize() or Vector2.new(1280, 720)
	return Vector2.new(math.clamp(pt.X, 8, v.X - 8), math.clamp(pt.Y, 8, v.Y - 8))
end

local function target(): Vector3?
	local t = player:GetAttribute("WalkTarget")
	return typeof(t) == "Vector3" and t or nil
end

-- The nearest live XP gem (workspace.SwarmGems, attribute Base) within 60 studs.
local function nearestGem(): Vector3?
	local folder = workspace:FindFirstChild("SwarmGems")
	local hp = heroPos()
	if not folder or not hp then
		return nil
	end
	local best, bd = nil, 60 * 60
	for _, g in ipairs(folder:GetChildren()) do
		local owner = g:GetAttribute("Owner") -- [stream E2] a teammate's personal shard is not mine
		if g:IsA("BasePart") and g:GetAttribute("Active") == true and (type(owner) ~= "number" or owner == game:GetService("Players").LocalPlayer.UserId) then
			local b = g:GetAttribute("Base")
			if typeof(b) == "Vector3" then
				local dx, dz = b.X - hp.X, b.Z - hp.Z
				local d = dx * dx + dz * dz
				if d <= bd then
					best, bd = b, d
				end
			end
		end
	end
	return best
end

-- Where the bubble's pointer aims for step s (root pixels), or nil.
local function aimFor(s: string): (() -> Vector2?)?
	if s == "Move" or s == "Chest" or s == "Fight" then
		return function()
			local t = target()
			return project(t and (t + Vector3.new(0, s == "Chest" and 2 or 1, 0)) or nil)
		end
	elseif s == "Gems" then
		return function()
			return project(nearestGem())
		end
	elseif s == "Go" then
		return function()
			local arrow = StageUI.Elements().Arrow
			if typeof(arrow) == "Instance" and arrow:IsA("GuiObject") and arrow.Visible then
				return TutorialBubble.ToRoot(arrow.AbsolutePosition + arrow.AbsoluteSize / 2)
			end
			local st = game:GetService("ReplicatedStorage"):FindFirstChild("SwarmState")
			local pos = st and st:GetAttribute("PortalPos")
			return project(typeof(pos) == "Vector3" and pos or nil)
		end
	end
	return nil
end

------------------------------------------------------------------------------------------
-- World marker: a glowing gold ground ring (MOVE) and a bouncing arrow (MOVE, CHEST)
------------------------------------------------------------------------------------------

local function clearMarker()
	if markerFolder then
		markerFolder:Destroy()
		markerFolder = nil
	end
	markerAt = nil
end

local function piece(parent: Instance, name: string, size: Vector3, cf: CFrame, transparency: number): Part
	local p = Instance.new("Part")
	p.Name = name
	p.Anchored = true
	p.CanCollide = false
	p.CanQuery = false
	p.CanTouch = false
	p.CastShadow = false
	p.Material = Enum.Material.Neon
	p.Color = GOLD
	p.Transparency = transparency
	p.Size = size
	p.CFrame = cf
	p.Parent = parent
	return p
end

local function buildMarker(at: Vector3, ring: boolean)
	clearMarker()
	local folder = Instance.new("Folder")
	folder.Name = "WalkthroughMarker"
	local radius = ring and ((Config :: any).Walkthrough.RingRadius or 4.5) or 2.6
	local ground = Vector3.new(at.X, GroundHeight.At(at.X, at.Z) + 0.15, at.Z)
	if ring then
		for i = 1, RING_PIECES do
			local a = (i / RING_PIECES) * math.pi * 2
			local len = 2 * math.pi * radius / RING_PIECES + 0.15
			local pos = ground + Vector3.new(math.cos(a) * radius, 0, math.sin(a) * radius)
			piece(folder, "Ring", Vector3.new(len, 0.3, 0.55), CFrame.lookAt(pos, ground), 0.15)
		end
		-- the faint gold floor inside the ring
		local disc = piece(folder, "Disc", Vector3.new(0.1, radius * 2, radius * 2), CFrame.new(ground) * CFrame.Angles(0, 0, math.rad(90)), 0.75)
		disc.Shape = Enum.PartType.Cylinder
	end
	-- the arrow: a gold "V" over the spot (BillboardGui: always faces the camera)
	local anchor = piece(folder, "ArrowAnchor", Vector3.new(0.2, 0.2, 0.2), CFrame.new(ground + Vector3.new(0, ring and 5 or 6.5, 0)), 1)
	local bb = Instance.new("BillboardGui")
	bb.Name = "Arrow"
	bb.Size = UDim2.fromOffset(56, 56)
	bb.AlwaysOnTop = true
	bb.LightInfluence = 0
	bb.Adornee = anchor
	bb.Parent = anchor
	local label = Instance.new("TextLabel")
	label.Name = "Glyph"
	label.BackgroundTransparency = 1
	label.Size = UDim2.fromScale(1, 1)
	label.Text = "▼"
	label.TextScaled = true
	label.Font = Enum.Font.GothamBlack
	label.TextColor3 = GOLD
	label.TextStrokeTransparency = 0.2
	label.TextStrokeColor3 = Theme.Color.Text
	label.Parent = bb
	folder.Parent = workspace
	markerFolder = folder
	markerAt = at
	markerRing = ring
end

local function stepMarker(s: string?)
	local want = (s == "Move" or s == "Chest") and target() or nil
	if not want then
		if markerFolder then
			clearMarker()
		end
		return
	end
	if not markerAt or (markerAt - want).Magnitude > 0.5 or markerRing ~= (s == "Move") then
		buildMarker(want, s == "Move")
	end
	local folder = markerFolder
	if not folder then
		return
	end
	-- the arrow bobs, the ring breathes (still with Reduced effects)
	local reduced = ClientSettings.Reduced()
	local anchor = folder:FindFirstChild("ArrowAnchor") :: BasePart?
	local bb = anchor and anchor:FindFirstChild("Arrow") :: BillboardGui?
	if bb then
		bb.StudsOffset = Vector3.new(0, reduced and 0 or math.abs(math.sin(clock * 3)) * 1.2, 0)
	end
	if markerRing and not reduced then
		local t = 0.15 + (math.sin(clock * 4) + 1) * 0.15
		for _, p in ipairs(folder:GetChildren()) do
			if p.Name == "Ring" and p:IsA("BasePart") then
				p.Transparency = t
			end
		end
	end
end

------------------------------------------------------------------------------------------
-- Public
------------------------------------------------------------------------------------------

-- The walkthrough is running for the local player.
function WalkthroughClient.Active(): boolean
	return step() ~= nil and player:GetAttribute("InRun") == true
end

-- The line under LEVEL UP! while the walkthrough waits for the first pick (nil otherwise).
function WalkthroughClient.LevelUpHint(): string?
	local s = step()
	if s == "Gems" or s == "Upgrade" then
		return "Pick an upgrade!"
	end
	return nil
end

--[[
	Per frame (Tutorial.Update). inRun = the player is in a run; blocked = a panel covers
	the screen (the bubble waits hidden). Returns (owns, started): owns = the walkthrough
	owns the bubble this frame; started = it just began (Tutorial drops the tips it
	replaces).
]]
function WalkthroughClient.Update(dt: number, inRun: boolean, blocked: boolean): (boolean, boolean)
	clock += dt
	local s = inRun and step() or nil
	stepMarker(s)
	if not s then
		if shown then
			shown = nil
			shownText = ""
			TutorialBubble.Hide()
		end
		return false, false
	end
	local started = shown == nil
	local text = lineFor(s)
	if s ~= shown then
		shown = s
		shownText = text
		TutorialBubble.Show(text, ICONS[s] or "info", aimFor(s))
		if kit.Audio then
			pcall(kit.Audio.Play, "Tip")
		end
	elseif text ~= shownText then
		shownText = text
		TutorialBubble.SetText(text)
	end
	TutorialBubble.SetCovered(blocked)
	if not blocked then
		TutorialBubble.Step(dt)
	end
	return true, started
end

function WalkthroughClient.Build(root: Frame, k: { [string]: any })
	rootFrame = root
	kit = k
end

-- For tests: the line of step `s` for the local player's walkthrough attributes, worded for
-- `mode` ("Touch" | "Mouse" | "Gamepad"; default: the device in hand).
function WalkthroughClient.LineFor(s: string, mode: string?): string
	return lineFor(s, mode)
end

-- For tests: the step on screen, its line and the world marker folder.
function WalkthroughClient.Current(): (string?, string, Folder?)
	return shown, shownText, markerFolder
end

return WalkthroughClient
