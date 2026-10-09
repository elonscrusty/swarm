--!nonstrict
--[[
	SwarmV2/Run/RunDowned.lua  (StarterPlayerScripts.SwarmV2Client.Run.RunDowned)
	OWNER: stream F (run UI).

	What the local player sees when they are not in the fight, from the shared contract (player
	attributes set by stream E1):

	  Downed (bool)  BleedLeft (s)  ReviveProgress (0..1)  Eliminated (bool)  Spectating (bool)
	  ReviveProtectUntil (server time, 1 s after a revive)

	  DOWNED       a panel under the top stack: one big bleed-out ring with the seconds left (the only
	               big timer: BleedLeft is continued between server updates), "YOU ARE DOWN", where the
	               nearest living teammate is (an arrow turned toward them, their name and the distance),
	               and the revive state: "Reviving 40%" with a bar while a teammate holds, "Interrupted"
	               when the progress was lost (incoming damage or the reviver left range)
	  REVIVED      "REVIVED" with the protection line for a moment after Downed turns false (no new timer:
	               the 1 s protection is a word, not a ring)
	  OUT          Eliminated or Spectating: "YOU ARE OUT", how many teammates are still fighting and
	               their names, WATCHING <name> with previous / next buttons (the spectate cycle), the plain
	               fact that results come when the run ends and nothing is awarded early, and a RUN MENU
	               button (leave options live there, with their confirmation)

	No attribute set = nothing shown (the older fallen screens keep serving older servers: Hud and
	Spectate step aside only when Downed / Eliminated exist). Reduced motion: no pop, no tint pulse.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Theme = require(Shared:WaitForChild("Theme"))
local RunConfig = require(ReplicatedStorage:WaitForChild("SwarmV2"):WaitForChild("Run"):WaitForChild("RunConfig"))
local Client = script.Parent.Parent.Parent:WaitForChild("SwarmClient")
local UIKit = require(Client:WaitForChild("UIKit"))
local UIAnim = require(Client:WaitForChild("UIAnim"))
local Icons = require(Client:WaitForChild("Icons"))
local ClientSettings = require(Client:WaitForChild("ClientSettings"))
local CameraController = require(Client:WaitForChild("CameraController"))
local SpectateBar = require(Client:WaitForChild("Spectate")) -- the older bar (WATCHING, < >, REVIVE ME) still serves team runs
local RunTheme = require(script.Parent.RunTheme)
local W = require(script.Parent.RunWidgets)
local RunObjective = require(script.Parent.RunObjective)

local RunDowned = {}

local CFG = RunConfig.UI.Downed
local LAYOUT = RunConfig.UI.Layout
local player = Players.LocalPlayer
local new = UIKit.new
local FLAT = Vector3.new(1, 0, 1)

local ui: { [string]: any } = {}
local kit: { [string]: any } = {}
local mode = "Alive" -- "Alive" | "Downed" | "Revived" | "Out"
local bleedTick = RunObjective.Ticker()
local bleedMax = CFG.BleedSeconds
local lastProgress = 0
local interruptedUntil = 0
local revivedUntil = 0
local wasDowned = false

-- Which state is the local player in (pure of UI; used by the tests too).
function RunDowned.StateOf(p: Player): string
	if p:GetAttribute("Eliminated") == true or p:GetAttribute("Spectating") == true then
		return "Out"
	elseif p:GetAttribute("Downed") == true then
		return "Downed"
	end
	return "Alive"
end

function RunDowned.Mode(): string
	return mode
end

------------------------------------------------------------------------------------------
-- Build
------------------------------------------------------------------------------------------

function RunDowned.Build(root: Instance, k: any)
	kit = k
	-- a faint red wash while down (never flashing)
	local tint = new("Frame", { Name = "DownTint", BackgroundColor3 = RunTheme.DangerDeep, BackgroundTransparency = 0.88, BorderSizePixel = 0, Visible = false, Active = false, ZIndex = 1 }, root)
	UIKit.Bleed(tint)
	ui.Tint = tint
	local holder, face = W.Panel(root, { Name = "RunDowned", Visible = false, ZIndex = Theme.Z.Loot, Edge = RunTheme.DangerDeep })
	holder.Active = false
	ui.Panel, ui.Face = holder, face
	-- bleed-out ring
	ui.Ring = W.Ring(face, { Name = "Bleed", Size = 92, Segments = 30, Color = RunTheme.Danger, Position = UDim2.fromOffset(10, 12), ZIndex = 3 })
	ui.Seconds = W.Text(ui.Ring.Frame, "20", { Name = "Seconds", Size = 30, Font = "Number", Align = "Center", Box = UDim2.fromScale(1, 1), Color = RunTheme.Cream, ZIndex = 5 })
	ui.Caption = W.Text(face, "BLEEDING OUT", { Name = "Caption", Size = 12, Font = "Label", Align = "Center", Position = UDim2.fromOffset(10, 106), Box = UDim2.fromOffset(92, 18), Fit = 8, Color = RunTheme.CreamMuted })
	-- words
	ui.Title = W.Text(face, "YOU ARE DOWN", { Name = "Title", Size = RunTheme.Size.Section, Font = "Heading", Position = UDim2.fromOffset(116, 8), Box = UDim2.new(1, -126, 0, 30), Fit = 14, Color = RunTheme.Danger })
	ui.Line = W.Text(face, "", { Name = "Line", Size = 16, Font = "Body", Position = UDim2.fromOffset(116, 40), Box = UDim2.new(1, -126, 0, 40), Fit = 11, Color = RunTheme.CreamMuted, Wrap = true, VAlign = "Top" })
	-- the nearest teammate: an arrow, the name and the distance
	local mate = new("Frame", { Name = "Mate", BackgroundColor3 = RunTheme.NavyDeep, BorderSizePixel = 0, Position = UDim2.fromOffset(116, 84), Size = UDim2.new(1, -126, 0, 34), Active = false }, face)
	UIKit.corner(mate, 8)
	ui.Mate = mate
	ui.ArrowPivot = new("Frame", { Name = "Pivot", BackgroundTransparency = 1, AnchorPoint = Vector2.new(0, 0.5), Position = UDim2.new(0, 6, 0.5, 0), Size = UDim2.fromOffset(26, 26), Active = false }, mate)
	Icons.Draw(ui.ArrowPivot, "arrowRight", { Size = 26, Color = RunTheme.Cyan, Back = RunTheme.NavyDeep })
	ui.MateText = W.Text(mate, "", { Name = "MateText", Size = 16, Font = "Strong", Position = UDim2.fromOffset(40, 0), Box = UDim2.new(1, -46, 1, 0), Fit = 11, Color = RunTheme.Cream })
	-- revive progress bar (shown while someone holds)
	ui.Revive = W.Bar(face, { Name = "ReviveBar", Size = UDim2.new(1, -126, 0, 12), Position = UDim2.fromOffset(116, 124), Color = RunTheme.Cyan, Trail = false })
	ui.Revive.Frame.Visible = false

	-- spectate controls (Out): previous, next, run menu
	ui.Prev = W.Button(face, { Name = "Prev", Text = "<", Kind = "Secondary", TextSize = 24, Size = UDim2.fromOffset(LAYOUT.TouchMin, LAYOUT.TouchMin), Position = UDim2.fromOffset(10, 8), ZIndex = 4, OnClick = function()
		CameraController.SpectateCycle(-1)
	end })
	ui.Next = W.Button(face, { Name = "Next", Text = ">", Kind = "Secondary", TextSize = 24, Size = UDim2.fromOffset(LAYOUT.TouchMin, LAYOUT.TouchMin), Position = UDim2.fromOffset(66, 8), ZIndex = 4, OnClick = function()
		CameraController.SpectateCycle(1)
	end })
	ui.Menu = W.Button(face, { Name = "RunMenu", Text = "RUN MENU", Kind = "Primary", TextSize = 18, Size = UDim2.fromOffset(150, LAYOUT.TouchMin), AnchorPoint = Vector2.new(1, 0), Position = UDim2.new(1, -10, 0, 8), ZIndex = 4, OnClick = function()
		if kit.OpenMenu then
			kit.OpenMenu()
		end
	end })
	kit.OnRelayout(function()
		RunDowned.Layout()
	end)
end

function RunDowned.Layout()
	if not ui.Panel then
		return
	end
	local v = kit.VirtualSize()
	local phone = UIKit.IsCompact()
	local margin = phone and LAYOUT.MarginPhone or LAYOUT.MarginDesktop
	local w = math.min(440, v.X - 2 * margin)
	local tp = W.TouchPx(kit.Scale and kit.Scale() or 1)
	ui.TouchPx = tp
	ui.Prev.Instance.Size = UDim2.fromOffset(tp, tp)
	ui.Next.Instance.Size = UDim2.fromOffset(tp, tp)
	ui.Next.Instance.Position = UDim2.fromOffset(16 + tp, 8)
	ui.Menu.Instance.Size = UDim2.fromOffset(150, tp)
	local h = mode == "Out" and (tp + 70) or 146
	local top = (kit.TopBottom and kit.TopBottom() or 140) + 10
	ui.Panel.Size = UDim2.fromOffset(w, h)
	ui.Panel.Position = UDim2.fromOffset(math.floor((v.X - w) / 2 + 0.5), math.floor(top + 0.5))
end

------------------------------------------------------------------------------------------
-- Helpers
------------------------------------------------------------------------------------------

local function myRoot(): BasePart?
	local c = player.Character
	return c and c.PrimaryPart or nil
end

-- Teammates in the run: { living = {...}, down = {...} } (players, not me).
local function team(): ({ Player }, number)
	local living, down = {}, 0
	for _, p in ipairs(Players:GetPlayers()) do
		if p ~= player and p:GetAttribute("InRun") == true and p:GetAttribute("Eliminated") ~= true then
			if p:GetAttribute("Downed") == true then
				down += 1
			else
				table.insert(living, p)
			end
		end
	end
	table.sort(living, function(a, b)
		return a.UserId < b.UserId
	end)
	return living, down
end

-- The arrow's turn (degrees, 0 = right) toward a world point, seen from the camera.
local function arrowAngle(from: Vector3, to: Vector3): number
	local cam = workspace.CurrentCamera
	local flat = (to - from) * FLAT
	local r = cam.CFrame.RightVector * FLAT
	local f = cam.CFrame.LookVector * FLAT
	if flat.Magnitude < 0.01 or r.Magnitude < 0.01 or f.Magnitude < 0.01 then
		return 0
	end
	-- screen x = along camera right, screen y (down) = against camera forward
	local x, y = flat:Dot(r.Unit), -flat:Dot(f.Unit)
	return math.deg(math.atan2(y, x))
end

local function show(on: boolean)
	if ui.Panel.Visible ~= on then
		ui.Panel.Visible = on
		if on and not ClientSettings.Reduced() then
			UIAnim.Pop(ui.Panel, 0, 0.85)
		end
	end
end

local function setMode(m: string)
	if m == mode then
		return
	end
	mode = m
	RunDowned.Layout()
end

------------------------------------------------------------------------------------------
-- Per frame
------------------------------------------------------------------------------------------

-- Teammates inside their disconnect window (SwarmState AwayIds ",id,id," from stream E1).
local function awayCount(state: Instance): number
	local n = 0
	local text = state:GetAttribute("AwayIds")
	if type(text) == "string" then
		for id in string.gmatch(text, "%d+") do
			local uid = tonumber(id)
			if uid and uid ~= player.UserId and not Players:GetPlayerByUserId(uid) then
				n += 1
			end
		end
	end
	return n
end

function RunDowned.Update(_dt: number, state: Instance, inRun: boolean)
	if not ui.Panel then
		return
	end
	local now = os.clock()
	if not inRun then
		setMode("Alive")
		wasDowned = false
		ui.Tint.Visible = false
		show(false)
		return
	end
	local base = RunDowned.StateOf(player)
	-- a revive: Downed turned false after being true
	if base == "Alive" and wasDowned and player:GetAttribute("Eliminated") ~= true then
		revivedUntil = now + CFG.RevivedShow
	end
	wasDowned = base == "Downed"
	local m = base
	if m == "Alive" and now < revivedUntil then
		m = "Revived"
	end
	setMode(m)
	ui.Tint.Visible = m == "Downed"
	if m == "Alive" then
		show(false)
		return
	end
	local roster, downCount = team()
	local root = myRoot()
	local isOut = m == "Out"
	local isRevived = m == "Revived"
	ui.Ring.Frame.Visible = not isOut
	ui.Seconds.Visible = not isOut
	ui.Caption.Visible = not isOut
	-- the older spectate bar carries WATCHING, < > and REVIVE ME while it is up; this screen adds them only without it
	local ownNav = isOut and not SpectateBar.Active()
	ui.Prev.Instance.Visible = ownNav
	ui.Next.Instance.Visible = ownNav
	ui.Menu.Instance.Visible = isOut
	local tp = ui.TouchPx or 48
	-- Out: the title and the RUN MENU button share the first row (with < > before it when this screen owns them)
	local navW = ownNav and (2 * tp + 24) or 0
	ui.Title.Position = UDim2.fromOffset(isOut and (12 + navW) or 116, isOut and (8 + math.max(0, (tp - 30) / 2)) or 8)
	ui.Title.Size = UDim2.new(1, isOut and (-12 - navW - 170) or -126, 0, 30)
	ui.Line.Position = UDim2.fromOffset(isOut and 12 or 116, isOut and (tp + 14) or 40)
	ui.Line.Size = UDim2.new(1, isOut and -24 or -126, 0, 44)
	if isOut then
		ui.Title.Text = "YOU ARE OUT"
		ui.Title.TextColor3 = RunTheme.Cream
		local names = {}
		for _, p in ipairs(roster) do
			table.insert(names, p.DisplayName)
		end
		local watched = CameraController.Spectated()
		local fighting = #roster
		local tail = "Results come when the run ends. Nothing is awarded early."
		local head
		if fighting > 0 then
			head = string.format("%d teammate%s still fighting: %s", fighting, fighting == 1 and "" or "s", table.concat(names, ", "))
		elseif downCount > 0 then
			head = string.format("%d teammate%s down. Waiting for a revive", downCount, downCount == 1 and " is" or "s are")
		else
			head = "No teammates are left"
		end
		local away = awayCount(state)
		if away > 0 then
			head = head .. string.format(" (%d reconnecting)", away)
		end
		W.Set(ui.Line, head .. ". " .. tail)
		ui.Mate.Visible = false
		ui.Revive.Frame.Visible = false
		-- "WATCHING NAME" sits between the arrows and the menu button
		ui.Caption.Visible = false
		show(true)
		-- watched teammate in the title row
		local wname = watched and string.upper(watched.DisplayName) or "NO ONE TO WATCH"
		ui.WatchLabel = ui.WatchLabel or W.Text(ui.Face, "", { Name = "Watching", Size = 16, Font = "Label", Position = UDim2.fromOffset(40 + 2 * (ui.TouchPx or 48), 8), Box = UDim2.new(1, -(40 + 2 * (ui.TouchPx or 48)) - 170, 0, ui.TouchPx or LAYOUT.TouchMin), Fit = 10, Color = RunTheme.Cyan, ZIndex = 4 })
		ui.WatchLabel.Visible = false -- the title row stays "YOU ARE OUT"; WATCHING sits in the older bar / on the camera
		if ownNav then
			ui.WatchLabel.Visible = true
			ui.Title.Visible = false
			W.Set(ui.WatchLabel, "WATCHING  " .. wname)
		else
			ui.Title.Visible = true
		end
		return
	end
	if ui.WatchLabel then
		ui.WatchLabel.Visible = false
	end
	ui.Title.Visible = true
	if isRevived then
		-- "REVIVED": the heart is back, the protection is a word, not another timer
		ui.Title.Text = "REVIVED"
		ui.Title.TextColor3 = RunTheme.Good
		W.Set(ui.Line, "Back on your feet with a little health and one second of protection")
		ui.Ring.Set(1)
		ui.Ring.SetColor(RunTheme.Good)
		W.Set(ui.Seconds, "OK")
		ui.Mate.Visible = false
		ui.Revive.Frame.Visible = false
		show(true)
		return
	end
	-- DOWNED
	ui.Title.Text = "YOU ARE DOWN"
	ui.Title.TextColor3 = RunTheme.Danger
	local bleedRaw = tonumber(player:GetAttribute("BleedLeft"))
	local bleed = bleedRaw and math.max(0, bleedTick(bleedRaw, -1, now)) or nil
	if bleed then
		bleedMax = math.max(bleedMax, bleed)
		ui.Ring.Set(bleed / bleedMax)
		ui.Ring.SetColor(bleed <= 5 and RunTheme.Danger or RunTheme.Warn)
		W.Set(ui.Seconds, tostring(math.ceil(bleed)))
	else
		ui.Ring.Set(1)
		W.Set(ui.Seconds, "--")
	end
	local progress = math.clamp(tonumber(player:GetAttribute("ReviveProgress")) or 0, 0, 1)
	if lastProgress > 0.05 and progress <= 0 then
		interruptedUntil = now + CFG.InterruptedShow
	end
	lastProgress = progress
	local line
	if progress > 0 then
		line = string.format("Reviving  %d%%. Hold on", math.floor(progress * 100))
	elseif now < interruptedUntil then
		line = "Interrupted. A teammate has to hold again"
	elseif #roster == 0 then
		line = "Every teammate is down. Stay still"
	else
		line = string.format("A teammate can revive you from within %d studs", RunConfig.UI.Interact.ReviveRange)
	end
	W.Set(ui.Line, line)
	ui.Line.TextColor3 = (now < interruptedUntil and progress <= 0) and RunTheme.Warn or RunTheme.CreamMuted
	ui.Revive.Frame.Visible = progress > 0
	if progress > 0 then
		ui.Revive.Set(progress)
	end
	-- nearest living teammate: arrow, name, distance
	local nearest, nd = nil, math.huge
	if root then
		for _, p in ipairs(roster) do
			local r = p.Character and p.Character.PrimaryPart
			if r then
				local d = ((r.Position - root.Position) * FLAT).Magnitude
				if d < nd then
					nearest, nd = p, d
				end
			end
		end
	end
	ui.Mate.Visible = nearest ~= nil
	if nearest and root then
		local r = nearest.Character.PrimaryPart
		ui.ArrowPivot.Rotation = math.floor(arrowAngle(root.Position, r.Position) + 0.5)
		W.Set(ui.MateText, string.format("%s  ·  %d m", nearest.DisplayName, math.floor(nd + 0.5)))
	end
	show(true)
end

function RunDowned.Elements(): { [string]: any }
	return { Panel = ui.Panel, Title = ui.Title, Line = ui.Line, Ring = ui.Ring, Seconds = ui.Seconds, Mate = ui.Mate, MateText = ui.MateText, Revive = ui.Revive, Prev = ui.Prev, Next = ui.Next, Menu = ui.Menu, Tint = ui.Tint, Mode = mode }
end

return RunDowned
