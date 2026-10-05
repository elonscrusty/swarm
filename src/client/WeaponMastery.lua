--[[
	WeaponMastery.lua (client; feature 15, Config.Features.WeaponMastery, docs/features/LOBBY.md)
	Weapon mastery glows: the menu and the drawing. Server side: src/server/Modules/WeaponMastery.lua.

	  Glow     VFX asks (VFX.SetMasteryColor) for the colour of a new projectile trail and of
	           every sword slash. Only YOUR effects are tinted, on your screen: a slash is
	           always the owner's (VFX only asks for the local player's), a projectile counts
	           as yours in a solo run, or in co-op when it appears next to your hero. The
	           colour is the milestone the weapon wears (save field WeaponMastery
	           "Glow:<weaponId>", from ProfileSync.Features). Looks only.
	  Menu     WeaponMastery.Open(): a panel (its own ScreenGui) listing every weapon with its
	           kills, the next milestone and one swatch per glow (own colour + each
	           milestone; locked ones show the kills they need). A tap sends
	           SetMasteryGlow(weaponId, index); the server checks the kills, and the next
	           ProfileSync shows the real choice. Opened from MORE (MenuMore).

	WeaponMastery.Init() (ClientMain), .Open(), .Close(), .IsOpen(), .ColorFor(visual, pos?)
]]

local Players = game:GetService("Players")
local UserInputService = game:GetService("UserInputService")

local Shared = game:GetService("ReplicatedStorage"):WaitForChild("Shared")
local Config = require(Shared:WaitForChild("Config"))
local Remotes = require(Shared:WaitForChild("Remotes"))
local Theme = require(Shared:WaitForChild("Theme"))
local WeaponData = require(Shared:WaitForChild("WeaponData"))
local UIKit = require(script.Parent.UIKit)
local Icons = require(script.Parent.Icons)
local VFX = require(script.Parent.VFX)

local WeaponMastery = {}

local player = Players.LocalPlayer
local new, text = UIKit.new, UIKit.text
local P = Theme.Palette
local C = Theme.Color
local M = Config.WeaponMastery
local OWN_RANGE = 4.5 -- studs: a projectile appearing this close to your hero is yours

local counts: { [string]: number } = {} -- weaponId → kills (last ProfileSync)
local glows: { [string]: number } = {} -- weaponId → milestone worn
local pending: { [string]: number } = {} -- weaponId → index asked for (until the next sync)
local byVisual: { [number]: string } = {} -- projectile visual index → weapon id

local gui: ScreenGui? = nil
local ui: { [string]: any } = {}

for id, def in pairs(WeaponData.Weapons) do
	local p = def.Params
	if type(p) == "table" then
		for _, k in ipairs({ "Visual", "EvoVisual", "ShotVisual" }) do
			if type(p[k]) == "number" then
				byVisual[p[k]] = id
			end
		end
	end
end

local function fmt(n: number): string
	return UIKit.formatNumber(n)
end

-- The milestone a weapon wears (pending choice first), 0 = its own colour.
local function wornIndex(weaponId: string): number
	return pending[weaponId] or glows[weaponId] or 0
end

-- True when the projectile at `pos` is the local player's (see the header).
local function ownShot(pos: Vector3?): boolean
	if player:GetAttribute("InRun") ~= true then
		return false
	end
	local others = false
	for _, other in ipairs(Players:GetPlayers()) do
		if other ~= player and other:GetAttribute("InRun") == true then
			others = true
			break
		end
	end
	if not others then
		return true
	end
	local char = player.Character
	local root = char and char.PrimaryPart
	if not root or not pos then
		return false
	end
	local d = Vector3.new(root.Position.X - pos.X, 0, root.Position.Z - pos.Z)
	return d.Magnitude <= OWN_RANGE
end

-- The glow colour for a new effect: `visual` = projectile visual index or "Whip".
function WeaponMastery.ColorFor(visual: any, pos: Vector3?): Color3?
	if not Config.FeatureOn("WeaponMastery") then
		return nil
	end
	local weaponId = if visual == "Whip" then "Whip" elseif type(visual) == "number" then byVisual[visual] else nil
	if not weaponId then
		return nil
	end
	local idx = glows[weaponId] or 0
	local m = idx > 0 and M.Milestones[idx] or nil
	if not m then
		return nil
	end
	if visual ~= "Whip" and not ownShot(pos) then
		return nil
	end
	return m.Color
end

local function onProfile(profile: any)
	local f = type(profile) == "table" and profile.Features
	local t = type(f) == "table" and f.WeaponMastery
	table.clear(counts)
	table.clear(glows)
	table.clear(pending)
	if type(t) == "table" then
		for k, v in pairs(t) do
			if type(k) == "string" and type(v) == "number" then
				local glowOf = string.match(k, "^Glow:(.+)$")
				if glowOf then
					glows[glowOf] = v
				else
					counts[k] = v
				end
			end
		end
	end
	if ui.Refresh then
		ui.Refresh()
	end
end

------------------------------------------------------------------------------------------
-- Menu
------------------------------------------------------------------------------------------

local SW = 34 -- swatch size (px)

local function swatch(parent: Instance, color: Color3?, order: number): (TextButton, Frame)
	local b = new("TextButton", {
		Name = "Swatch" .. order,
		Text = "",
		AutoButtonColor = false,
		BackgroundColor3 = color or P.slate_700,
		BorderSizePixel = 0,
		Size = UDim2.fromOffset(SW, SW),
		LayoutOrder = order,
	}, parent)
	UIKit.corner(b, 999)
	local ring = new("Frame", { Name = "Ring", BackgroundTransparency = 1, AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.5), Size = UDim2.new(1, 8, 1, 8), Visible = false }, b)
	UIKit.corner(ring, 999)
	UIKit.stroke(ring, P.gold_300, 2.5, 0)
	UIKit.stroke(b, P.slate_950, 1.5, 0.2)
	return b, ring
end

local function buildRow(list: Frame, weaponId: string, order: number)
	local def = WeaponData.Weapons[weaponId]
	local row = new("Frame", { Name = weaponId, BackgroundColor3 = P.slate_800, BackgroundTransparency = 0.15, BorderSizePixel = 0, Size = UDim2.new(1, 0, 0, 64), LayoutOrder = order }, list)
	UIKit.corner(row, 10)
	local icon = new("Frame", { Name = "Icon", BackgroundTransparency = 1, Position = UDim2.fromOffset(10, 12), Size = UDim2.fromOffset(40, 40) }, row)
	pcall(Icons.Upgrade, icon, weaponId)
	local name = text(row, "Label", string.upper(def.Name or weaponId), { Name = "Name", Position = UDim2.fromOffset(58, 8), Size = UDim2.new(1, -58, 0, 20), TextTruncate = Enum.TextTruncate.AtEnd }, 15)
	local sub = text(row, "Small", "", { Name = "Sub", Position = UDim2.fromOffset(58, 30), Size = UDim2.new(1, -58, 0, 18), TextColor3 = C.TextMuted, TextTruncate = Enum.TextTruncate.AtEnd }, 12)
	local swatches = new("Frame", { Name = "Swatches", BackgroundTransparency = 1, AnchorPoint = Vector2.new(1, 0.5), Position = UDim2.new(1, -10, 0.5, 0), Size = UDim2.fromOffset((#M.Milestones + 1) * (SW + 6), SW + 8) }, row)
	local lay = UIKit.list(swatches, { FillDirection = Enum.FillDirection.Horizontal, VerticalAlignment = Enum.VerticalAlignment.Center, HorizontalAlignment = Enum.HorizontalAlignment.Right, Padding = UDim.new(0, 6) })
	local cells = {}
	for slot = 1, #M.Milestones + 1 do
		local i = slot - 1 -- 0 = the weapon's own colour
		local m = M.Milestones[i]
		local b, ring = swatch(swatches, m and m.Color or (def.Color or P.steel_300), i)
		local lock = new("Frame", { Name = "Lock", BackgroundTransparency = 1, AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.5), Size = UDim2.fromOffset(16, 16), Visible = false }, b)
		pcall(Icons.Draw, lock, "lock", { Color = P.ivory_100 })
		b.Activated:Connect(function()
			local need = m and m.Kills or 0
			if (counts[weaponId] or 0) < need then
				ui.Hint.Text = string.format("%s needs %s kills with the %s.", m.Name, fmt(need), def.Name or weaponId)
				return
			end
			pending[weaponId] = i
			Remotes.Get("SetMasteryGlow"):FireServer(weaponId, i)
			ui.Hint.Text = i == 0 and ((def.Name or weaponId) .. ": its own colour.") or string.format("%s wears %s.", def.Name or weaponId, m.Name)
			ui.Refresh()
		end)
		cells[i] = { Button = b, Ring = ring, Lock = lock }
	end
	return { Row = row, Name = name, Sub = sub, Cells = cells, Swatches = swatches, Layout = lay }
end

local function layout()
	local root = ui.Root :: Frame?
	if not root then
		return
	end
	local w, h = root.AbsoluteSize.X, root.AbsoluteSize.Y
	if w < 50 then
		local cam = workspace.CurrentCamera
		w, h = cam.ViewportSize.X, cam.ViewportSize.Y
	end
	local pw = math.min(640, w - 24)
	local ph = math.min(560, h - 24)
	ui.Panel.Size = UDim2.fromOffset(pw, ph)
	-- narrow: the swatches go under the name
	local narrow = pw < 470
	local rowH = narrow and 94 or 64
	for _, r in pairs(ui.Rows) do
		r.Row.Size = UDim2.new(1, 0, 0, rowH)
		r.Swatches.AnchorPoint = narrow and Vector2.new(0, 1) or Vector2.new(1, 0.5)
		r.Swatches.Position = narrow and UDim2.new(0, 54, 1, -4) or UDim2.new(1, -10, 0.5, 0)
		local right = narrow and 10 or (#M.Milestones + 1) * (SW + 6) + 16
		r.Name.Size = UDim2.new(1, -(58 + right), 0, 20)
		r.Sub.Size = UDim2.new(1, -(58 + right), 0, 18)
		r.Layout.HorizontalAlignment = narrow and Enum.HorizontalAlignment.Left or Enum.HorizontalAlignment.Right
	end
	ui.List.CanvasSize = UDim2.fromOffset(0, #WeaponData.Order * (rowH + 8))
end

local function build()
	local playerGui = player:WaitForChild("PlayerGui")
	local screen = new("ScreenGui", { Name = "WeaponMasteryUI", ResetOnSpawn = false, IgnoreGuiInset = true, ScreenInsets = Enum.ScreenInsets.DeviceSafeInsets, DisplayOrder = 15, Enabled = false }, playerGui) :: ScreenGui
	gui = screen
	local root = new("Frame", { Name = "Root", BackgroundTransparency = 1, Size = UDim2.fromScale(1, 1) }, screen)
	ui.Root = root
	local dim = new("TextButton", { Name = "Dim", Text = "", AutoButtonColor = false, BackgroundColor3 = C.Backdrop, BackgroundTransparency = Theme.Alpha.Backdrop, BorderSizePixel = 0, Size = UDim2.fromScale(1, 1) }, root)
	dim.Activated:Connect(function()
		WeaponMastery.Close()
	end)
	local holder, face = UIKit.Surface(root, { Name = "Panel", Size = UDim2.fromOffset(600, 520), AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.5), Radius = Theme.Radius.L, Transparency = 0.04, ZIndex = 2 })
	ui.Panel = holder
	text(face, "H2", "WEAPON MASTERY", { Name = "Title", Position = UDim2.fromOffset(18, 12), Size = UDim2.new(1, -90, 0, 30) }, 22)
	ui.Hint = text(face, "Small", "Kills with a weapon earn glow colours for it. Looks only.", { Name = "Hint", Position = UDim2.fromOffset(18, 44), Size = UDim2.new(1, -36, 0, 18), TextColor3 = C.TextMuted, TextTruncate = Enum.TextTruncate.AtEnd }, 12)
	local close = UIKit.IconButton(face, { Icon = "close", Name = "Close", Size = 44, AnchorPoint = Vector2.new(1, 0), Position = UDim2.new(1, -10, 0, 10), OnClick = function()
		WeaponMastery.Close()
	end })
	ui.Close = close
	local list = new("ScrollingFrame", {
		Name = "List",
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		Position = UDim2.fromOffset(12, 70),
		Size = UDim2.new(1, -24, 1, -82),
		ScrollBarThickness = 4,
		ScrollBarImageColor3 = P.gold_500,
		CanvasSize = UDim2.new(),
		ScrollingDirection = Enum.ScrollingDirection.Y,
	}, face)
	ui.List = list
	UIKit.list(list, { Padding = UDim.new(0, 8) })
	ui.Rows = {}
	for i, id in ipairs(WeaponData.Order) do
		if WeaponData.Weapons[id] then
			ui.Rows[id] = buildRow(list, id, i)
		end
	end
	ui.Refresh = function()
		for id, r in pairs(ui.Rows) do
			local n = counts[id] or 0
			local nextM = nil
			for _, m in ipairs(M.Milestones) do
				if n < m.Kills then
					nextM = m
					break
				end
			end
			r.Sub.Text = fmt(n) .. " kills" .. (nextM and string.format(" · %s at %s", nextM.Name, fmt(nextM.Kills)) or " · every glow earned")
			local worn = wornIndex(id)
			for i, cell in pairs(r.Cells) do
				local m = M.Milestones[i]
				local open = not m or n >= m.Kills
				cell.Lock.Visible = not open
				cell.Button.BackgroundTransparency = open and 0 or 0.55
				cell.Ring.Visible = i == worn
			end
		end
	end
	root:GetPropertyChangedSignal("AbsoluteSize"):Connect(layout)
	layout()
	ui.Refresh()
end

function WeaponMastery.Open()
	if not Config.FeatureOn("WeaponMastery") then
		return
	end
	if not gui then
		build()
	end
	ui.Hint.Text = "Kills with a weapon earn glow colours for it. Looks only."
	ui.Refresh()
	layout()
	local g = gui :: ScreenGui
	g.Enabled = true
	UIKit.FocusIfGamepad(ui.Close.Instance)
end

function WeaponMastery.Close()
	if gui then
		gui.Enabled = false
	end
end

function WeaponMastery.IsOpen(): boolean
	return gui ~= nil and gui.Enabled
end

function WeaponMastery.Init()
	VFX.SetMasteryColor(WeaponMastery.ColorFor)
	Remotes.Get("ProfileSync").OnClientEvent:Connect(onProfile)
	player:GetAttributeChangedSignal("InRun"):Connect(function()
		if player:GetAttribute("InRun") == true then
			WeaponMastery.Close()
		end
	end)
	UserInputService.InputBegan:Connect(function(input, processed)
		if not processed and WeaponMastery.IsOpen() and (input.KeyCode == Enum.KeyCode.Escape or input.KeyCode == Enum.KeyCode.ButtonB) then
			WeaponMastery.Close()
		end
	end)
end

-- (tests) feed a profile directly
WeaponMastery._OnProfile = onProfile

return WeaponMastery
