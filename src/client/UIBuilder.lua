--[[
	UIBuilder.lua
	Hosts every screen and builds the in-run ones: HUD (Hud.lua), toasts and banners,
	level-up cards, chest reward, pause / settings menu, revive offer and the results
	screen. It also hosts the lobby menu (LobbyScreen), the hero on the dais (Showcase) and
	the Studio dev tools (DevPanel). Components come from UIKit, icons from Icons, tokens
	from Theme.

	Scaling: all UI lives under one "Root" frame with a UIScale. The design is done in
	"reference pixels" (1280x720 landscape, 720x1280 portrait); Root is sized 1/scale so
	the scaled result always fills the screen exactly. The ScreenGui uses the device safe
	area (notches, rounded corners, home bar); modal dimmers and the screen-edge effects
	still cover the whole screen (UIKit.Bleed / the SwarmFx ScreenGui). The Roblox topbar
	buttons are kept clear using GuiService.TopbarInset (Insets()).
]]

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")
local UserInputService = game:GetService("UserInputService")
local MarketplaceService = game:GetService("MarketplaceService")
local GuiService = game:GetService("GuiService")
local StarterGui = game:GetService("StarterGui")

local Shared = game:GetService("ReplicatedStorage"):WaitForChild("Shared")
local Config = require(Shared:WaitForChild("Config"))
local Remotes = require(Shared:WaitForChild("Remotes"))
local Theme = require(Shared:WaitForChild("Theme"))
local WeaponData = require(Shared:WaitForChild("WeaponData"))
local PassiveData = require(Shared:WaitForChild("PassiveData"))
local UIAnim = require(script.Parent.UIAnim)
local UIKit = require(script.Parent.UIKit)
local Icons = require(script.Parent.Icons)
local Hud = require(script.Parent.Hud)
local LobbyScreen = require(script.Parent.LobbyScreen)
local DevPanel = require(script.Parent.DevPanel)
local Showcase = require(script.Parent.Showcase)

local UIBuilder = {}

local player = Players.LocalPlayer
local deps: { [string]: any } = {}

local gui: ScreenGui
local fxGui: ScreenGui
local root: Frame
local uiScale: UIScale
local portrait = false
local insets: Hud.Insets = { Top = 0, Left = 0, Right = 0 }

local profile: { [string]: any }? = nil

-- Open modals that should stop movement.
local blocking: { [string]: boolean } = {}

local new, text, TS = UIKit.new, UIKit.text, UIKit.TS
local C, P = Theme.Color, Theme.Palette
local formatTime = UIKit.formatTime

local function setBlocking(name: string, on: boolean)
	if on then
		blocking[name] = true
	else
		blocking[name] = nil
	end
	if deps.MobileControls then
		deps.MobileControls.SetEnabled(next(blocking) == nil)
	end
end

-- Opening: the dimmer fades in and the panel pops up with a little overshoot.
local function show(overlay: GuiObject, name: string, blocks: boolean)
	overlay:SetAttribute("AnimToken", (tonumber(overlay:GetAttribute("AnimToken")) or 0) + 1)
	overlay:SetAttribute("Hiding", nil)
	local wasVisible = overlay.Visible
	overlay.Visible = true
	if not wasVisible then
		local dim = overlay:FindFirstChild("Dim")
		if dim and dim:IsA("GuiObject") then
			UIAnim.FadeIn(dim, tonumber(overlay:GetAttribute("BackdropTransparency")) or Theme.Alpha.Backdrop)
		end
		local panel = overlay:FindFirstChild("Panel")
		if panel and panel:IsA("GuiObject") then
			UIAnim.Pop(panel, 0, 0.82)
		end
	end
	if blocks then
		setBlocking(name, true)
	end
end

-- Closing: the panel shrinks away, then the overlay hides (unless reopened meanwhile).
-- Safe to call every frame: a close that is already animating is left to finish
-- (restarting it each frame used to keep the results screen on forever).
local function hide(overlay: GuiObject, name: string)
	setBlocking(name, false)
	if not overlay.Visible or overlay:GetAttribute("Hiding") then
		return
	end
	local token = (tonumber(overlay:GetAttribute("AnimToken")) or 0) + 1
	overlay:SetAttribute("AnimToken", token)
	local panel = overlay:FindFirstChild("Panel")
	if panel and panel:IsA("GuiObject") then
		overlay:SetAttribute("Hiding", true)
		UIAnim.PopOut(panel, function()
			if overlay:GetAttribute("AnimToken") == token then
				overlay:SetAttribute("Hiding", nil)
				overlay.Visible = false
			end
		end)
	else
		overlay.Visible = false
	end
end

------------------------------------------------------------------------------------------
-- Root + scaling
------------------------------------------------------------------------------------------

local relayoutCallbacks: { () -> () } = {}

local function virtualSize(): Vector2
	return gui.AbsoluteSize / math.max(0.01, uiScale.Scale)
end

-- Room the Roblox topbar buttons take, in root (virtual) pixels.
local function computeInsets()
	local s = math.max(0.01, uiScale.Scale)
	local pos, size = gui.AbsolutePosition, gui.AbsoluteSize
	local top, left, right = 0, 0, 0
	local ok, rect = pcall(function()
		return GuiService.TopbarInset
	end)
	if ok and typeof(rect) == "Rect" and rect.Height > 0 then
		top = math.max(0, rect.Max.Y - pos.Y) / s
		left = math.max(0, rect.Min.X - pos.X) / s
		right = math.max(0, (pos.X + size.X) - rect.Max.X) / s
	end
	insets = { Top = top, Left = left, Right = right }
end

local function updateScale()
	local size = gui.AbsoluteSize
	if size.X < 1 or size.Y < 1 then
		return
	end
	portrait = size.Y > size.X
	local ref = Config.UI.ReferenceSize
	local refX, refY = ref.X, ref.Y
	if portrait then
		refX, refY = ref.Y, ref.X
	end
	local s = math.clamp(math.min(size.X / refX, size.Y / refY), Config.UI.MinScale, Config.UI.MaxScale)
	uiScale.Scale = s
	root.Size = UDim2.fromScale(1 / s, 1 / s)
	computeInsets()
	-- full-bleed layers: the whole screen in root coordinates
	local viewport = workspace.CurrentCamera.ViewportSize
	UIKit.SetBleed(-gui.AbsolutePosition / s, Vector2.new(math.max(viewport.X, size.X), math.max(viewport.Y, size.Y)) / s)
	for _, fn in ipairs(relayoutCallbacks) do
		local ok, err = pcall(fn)
		if not ok then
			warn("[UIBuilder] relayout: " .. tostring(err))
		end
	end
end

local function onRelayout(fn: () -> ())
	table.insert(relayoutCallbacks, fn)
end

-- A modal's panel takes the height of its content (UIListLayout in Content) + padding.
local function fitModal(m: UIKit.Modal, list: UIListLayout)
	local function fit()
		-- every child of a modal's content has an offset height, so add them up
		local h, n = 0, 0
		for _, ch in ipairs(m.Content:GetChildren()) do
			if ch:IsA("GuiObject") and ch.Visible then
				h += ch.Size.Y.Offset
				n += 1
			end
		end
		h += math.max(0, n - 1) * list.Padding.Offset
		if h > 10 then
			m.Panel.Size = UDim2.new(m.Panel.Size.X, UDim.new(0, math.floor(h + 2 * Theme.Space.XL + 4)))
		end
	end
	list:GetPropertyChangedSignal("AbsoluteContentSize"):Connect(fit)
	-- after this pass's other callbacks have resized the content
	onRelayout(function()
		task.defer(fit)
	end)
	m.Overlay:GetPropertyChangedSignal("Visible"):Connect(function()
		task.defer(fit)
	end)
end

local function margin(): number
	return UIKit.IsCompact() and Theme.Layout.MarginCompact or Theme.Layout.Margin
end

------------------------------------------------------------------------------------------
-- Toasts and banners
------------------------------------------------------------------------------------------

local toastList: Frame
local banner: { [string]: any } = {}

-- Server colours are bright; bring them into the palette.
local function accentOf(color: Color3?): Color3
	if not color then
		return P.gold_300
	end
	return Theme.Tint(color, 0.5, 0.88)
end

local function buildToasts()
	toastList = new("Frame", {
		Name = "Toasts",
		AnchorPoint = Vector2.new(0.5, 0),
		Size = UDim2.fromOffset(560, 260),
		BackgroundTransparency = 1,
		ZIndex = Theme.Z.Toast,
	}, root)
	UIKit.list(toastList, { Padding = UDim.new(0, 6), HorizontalAlignment = Enum.HorizontalAlignment.Center })

	-- big banner: serif title on a soft dark band that fades out at both ends
	local band = new("Frame", {
		Name = "Banner",
		AnchorPoint = Vector2.new(0.5, 0.5),
		Size = UDim2.new(1, 0, 0, 120),
		BackgroundColor3 = C.Backdrop,
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		ZIndex = Theme.Z.Toast,
		Visible = false,
	}, root)
	new("UIGradient", {
		Transparency = NumberSequence.new({
			NumberSequenceKeypoint.new(0, 1),
			NumberSequenceKeypoint.new(0.3, 0.45),
			NumberSequenceKeypoint.new(0.7, 0.45),
			NumberSequenceKeypoint.new(1, 1),
		}),
	}, band)
	banner.Band = band
	banner.Text = text(band, "Display", "", {
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.45),
		Size = UDim2.new(1, -40, 0, TS(52) + 8),
		TextXAlignment = Enum.TextXAlignment.Center,
		TextStrokeColor3 = C.Shadow,
		TextStrokeTransparency = 0.5,
		ZIndex = 2,
	}, 52)
	banner.Divider = UIKit.Divider(band, 260, { AnchorPoint = Vector2.new(0.5, 0), Position = UDim2.new(0.5, 0, 0.45, TS(52) / 2 + 8), ZIndex = 2 })
	onRelayout(function()
		local v = virtualSize()
		local inRun = player:GetAttribute("InRun") == true
		toastList.Position = UDim2.fromOffset(v.X / 2, inRun and (Hud.TopBottom() + 6) or (insets.Top + 70))
		toastList.Size = UDim2.fromOffset(math.min(560, v.X - 32), 260)
		band.Position = UDim2.fromOffset(v.X / 2, v.Y * 0.36)
	end)
end

local bannerToken = 0
local toastOrder = 0
function UIBuilder.Toast(str: string, color: Color3?, big: boolean?)
	if big then
		bannerToken += 1
		local token = bannerToken
		local band = banner.Band :: Frame
		local label = banner.Text :: TextLabel
		label.Text = str
		label.TextColor3 = Theme.Tint(color or P.gold_300, 0.45, 0.92)
		label.TextTransparency = 0
		label.TextStrokeTransparency = 0.5
		band.BackgroundTransparency = 0.25
		band.Visible = true
		UIAnim.Pop(label, 0, 1.25)
		task.delay(2.2, function()
			if token == bannerToken then
				TweenService:Create(label, TweenInfo.new(0.5), { TextTransparency = 1, TextStrokeTransparency = 1 }):Play()
				local tw = TweenService:Create(band, TweenInfo.new(0.5), { BackgroundTransparency = 1 })
				tw.Completed:Once(function()
					if token == bannerToken then
						band.Visible = false
					end
				end)
				tw:Play()
			end
		end)
		return
	end
	toastOrder += 1
	if player:GetAttribute("InRun") then
		-- below the timer / plates / boss bar as they are right now
		toastList.Position = UDim2.fromOffset(toastList.Position.X.Offset, Hud.TopBottom() + 6)
	end
	local holder, face = UIKit.Surface(toastList, {
		Name = "Toast",
		Size = UDim2.fromOffset(0, TS(16) + 22),
		Radius = 999,
		Transparency = 0.12,
		LayoutOrder = toastOrder,
	})
	holder.AutomaticSize = Enum.AutomaticSize.X
	face.AutomaticSize = Enum.AutomaticSize.X
	face.Size = UDim2.fromScale(0, 1)
	UIKit.padding(face, 0, 18, 0, 14)
	UIKit.list(face, { FillDirection = Enum.FillDirection.Horizontal, VerticalAlignment = Enum.VerticalAlignment.Center, Padding = UDim.new(0, 10) })
	local dotFrame = new("Frame", { BackgroundColor3 = accentOf(color), Size = UDim2.fromOffset(8, 8), LayoutOrder = 1 }, face)
	UIKit.corner(dotFrame, 999)
	local l = text(face, "BodyStrong", str, {
		LayoutOrder = 2,
		Size = UDim2.fromOffset(0, TS(16) + 22),
		AutomaticSize = Enum.AutomaticSize.X,
		TextColor3 = C.Text,
	})
	local _ = l
	UIAnim.Pop(holder, 0, 0.7)
	-- keep the stack short
	local toasts = {}
	for _, ch in ipairs(toastList:GetChildren()) do
		if ch:IsA("GuiObject") then
			table.insert(toasts, ch)
		end
	end
	table.sort(toasts, function(a, b)
		return a.LayoutOrder < b.LayoutOrder
	end)
	while #toasts > 4 do
		local oldest = table.remove(toasts, 1)
		if oldest then
			oldest:Destroy()
		end
	end
	task.delay(Config.UI.ToastSeconds, function()
		if holder.Parent then
			UIAnim.PopOut(holder, function()
				holder:Destroy()
			end)
		end
	end)
end

------------------------------------------------------------------------------------------
-- Level-up screen
------------------------------------------------------------------------------------------

local levelUp: { [string]: any } = {}
local offerDeadline = 0
local offerSeconds = 1
local offerOpen = false
local lastOffer: { [string]: any }? = nil

local function cardIconId(c): string
	if c.Type == "Evolve" then
		local def = WeaponData.Weapons[c.Id]
		return def and def.Evolution and def.Evolution.Id or c.Id
	elseif c.Type == "Gold" or c.Type == "Heal" then
		return c.Type
	end
	return c.Id
end

local function cardBand(c): (string, Color3, Color3)
	if c.Type == "Gold" or c.Type == "Heal" then
		return "BONUS", P.moss_600, P.moss_200
	end
	local r = Theme.Rarity[c.Rarity] or Theme.Rarity.Common
	return string.upper(r.Label), r.Band, r.Color
end

local function cardLevelText(c): string
	if c.Type == "WeaponNew" then
		return "NEW WEAPON"
	elseif c.Type == "PassiveNew" then
		return "NEW PASSIVE"
	elseif c.Type == "Evolve" then
		local def = WeaponData.Weapons[c.Id]
		return string.upper((def and def.Name or "Weapon") .. " evolves")
	elseif c.Type == "WeaponUp" then
		return c.Level >= WeaponData.MaxLevel and ("MAX LEVEL " .. c.Level) or ("LEVEL " .. c.Level)
	elseif c.Type == "PassiveUp" then
		return c.Level >= PassiveData.MaxLevel and ("MAX LEVEL " .. c.Level) or ("LEVEL " .. c.Level)
	elseif c.Type == "Heal" then
		return "RESTORE HEALTH"
	elseif c.Type == "Gold" then
		return "RUN GOLD"
	end
	return ""
end

local function chooseCard(index: number)
	if not offerOpen then
		return
	end
	offerOpen = false
	UIKit.Click()
	Remotes.Get("LevelUpChoose"):FireServer(index)
end

local function buildLevelUp()
	local overlay = new("Frame", {
		Name = "LevelUp",
		Size = UDim2.fromScale(1, 1),
		BackgroundTransparency = 1,
		Active = true,
		Visible = false,
		ZIndex = Theme.Z.LevelUp,
	}, root)
	overlay:SetAttribute("BackdropTransparency", 0.15)
	levelUp.Overlay = overlay
	local dim = new("Frame", { Name = "Dim", BackgroundColor3 = C.Backdrop, BackgroundTransparency = 0.15, BorderSizePixel = 0, Active = true, ZIndex = 1 }, overlay)
	UIKit.Bleed(dim)
	-- "Panel" is what show() pops in: here the whole content block
	local panel = new("Frame", { Name = "Panel", BackgroundTransparency = 1, ZIndex = 2 }, overlay)
	levelUp.Panel = panel
	levelUp.Title = text(panel, "Display", "LEVEL UP!", {
		Name = "Title",
		TextXAlignment = Enum.TextXAlignment.Center,
		TextColor3 = P.gold_300,
		TextStrokeColor3 = C.Shadow,
		TextStrokeTransparency = 0.5,
	}, 44)
	levelUp.Divider = UIKit.Divider(panel, 300)
	levelUp.Sub = text(panel, "BodyStrong", "Choose an upgrade", { TextXAlignment = Enum.TextXAlignment.Center, TextColor3 = C.TextMuted })
	levelUp.Timer = UIKit.Meter(panel, { Gradient = ColorSequence.new(P.gold_500, P.gold_300), Size = UDim2.fromOffset(240, 5) })
	levelUp.Cards = new("Frame", { Name = "Cards", BackgroundTransparency = 1 }, panel)
	levelUp.Layout = UIKit.list(levelUp.Cards, {
		FillDirection = Enum.FillDirection.Horizontal,
		HorizontalAlignment = Enum.HorizontalAlignment.Center,
		VerticalAlignment = Enum.VerticalAlignment.Center,
		Padding = UDim.new(0, 18),
	})
	local actions = new("Frame", { Name = "Actions", BackgroundTransparency = 1 }, panel)
	levelUp.Actions = actions
	UIKit.list(actions, { FillDirection = Enum.FillDirection.Horizontal, HorizontalAlignment = Enum.HorizontalAlignment.Center, Padding = UDim.new(0, 16) })
	levelUp.Reroll = UIKit.Button(actions, {
		Title = "REROLL",
		Icon = "cycle",
		IconSize = 20,
		Size = UDim2.fromOffset(200, 52),
		Align = "Center",
		LayoutOrder = 1,
		OnClick = function()
			Remotes.Get("LevelUpReroll"):FireServer()
		end,
	})
	levelUp.Skip = UIKit.Button(actions, {
		Title = "SKIP",
		Icon = "skip",
		IconSize = 20,
		Size = UDim2.fromOffset(200, 52),
		Align = "Center",
		LayoutOrder = 2,
		OnClick = function()
			Remotes.Get("LevelUpSkip"):FireServer()
		end,
	})

	-- keyboard: 1 / 2 / 3 pick a card
	UserInputService.InputBegan:Connect(function(input, processed)
		if processed or not offerOpen or not overlay.Visible then
			return
		end
		local keys = { [Enum.KeyCode.One] = 1, [Enum.KeyCode.Two] = 2, [Enum.KeyCode.Three] = 3, [Enum.KeyCode.Four] = 4 }
		local index = keys[input.KeyCode]
		if index and lastOffer and lastOffer.Choices[index] then
			chooseCard(index)
		end
	end)
end

-- Card sizes for the current screen.
local function cardMetrics(count: number): (number, number)
	local v = virtualSize()
	local m = margin()
	if portrait then
		return math.min(v.X - 2 * m, 600), UIKit.IsCompact() and 150 or 136
	end
	local w = math.min(290, (v.X - 2 * m - (count - 1) * 18) / math.max(1, count))
	local h = math.clamp(v.Y - 330, 300, 350)
	return w, h
end

local function makeCard(c, index: number, count: number, animate: boolean)
	local w, h = cardMetrics(count)
	local bandText, bandColor, edgeColor = cardBand(c)
	local legendary = c.Rarity == "Legendary"
	local hit = new("TextButton", {
		Name = "Card" .. index,
		Text = "",
		AutoButtonColor = false,
		BackgroundTransparency = 1,
		Size = UDim2.fromOffset(w, h),
		LayoutOrder = index,
	}, levelUp.Cards)
	UIKit.Focusable(hit)
	UIKit.Shadow(hit, Theme.Radius.L, 5, 0)
	if legendary then
		local glow = new("Frame", {
			Name = "Glow",
			BackgroundColor3 = P.gold_300,
			BackgroundTransparency = 0.7,
			BorderSizePixel = 0,
			Position = UDim2.fromOffset(-8, -8),
			Size = UDim2.new(1, 16, 1, 16),
			ZIndex = 0,
		}, hit)
		UIKit.corner(glow, Theme.Radius.L + 8)
		UIAnim.Glow(glow, "BackgroundTransparency", 0.65, 0.88, 1.1)
	end
	local face = new("Frame", {
		Name = "Face",
		BackgroundColor3 = Color3.new(1, 1, 1),
		BorderSizePixel = 0,
		Size = UDim2.fromScale(1, 1),
		ZIndex = 1,
		ClipsDescendants = false,
	}, hit)
	UIKit.corner(face, Theme.Radius.L)
	new("UIGradient", { Rotation = 90, Color = ColorSequence.new(P.slate_800, P.slate_900) }, face)
	local edge = UIKit.stroke(face, edgeColor, legendary and 2.5 or 1.5, legendary and 0 or 0.25)
	if legendary then
		UIAnim.PulseStroke(edge, 2, 4)
	end
	UIKit.AttachStates(hit, face, Theme.Radius.L)

	local iconId = cardIconId(c)
	if portrait then
		-- horizontal card: icon left, text right, rarity pill top right
		local tileSize = 84
		UIKit.Tile(face, { Id = iconId, Size = tileSize, Evolved = c.Type == "Evolve" }).Position = UDim2.new(0, 18, 0.5, -tileSize / 2)
		local x = 18 + tileSize + 16
		local badge = UIKit.Badge(face, bandText, legendary and "Gold" or "Slate", { Position = UDim2.fromOffset(x, 14) })
		badge.BackgroundColor3 = bandColor
		badge.TextColor3 = legendary and P.gold_900 or P.ivory_100
		text(face, "H2", c.Name, { Position = UDim2.fromOffset(x, 38), Size = UDim2.new(1, -x - 16, 0, TS(22) + 4), TextTruncate = Enum.TextTruncate.AtEnd })
		text(face, "Caption", cardLevelText(c), {
			Position = UDim2.fromOffset(x, 40 + TS(22) + 2),
			Size = UDim2.new(1, -x - 16, 0, TS(12) + 4),
			TextColor3 = edgeColor,
		})
		text(face, "Body", c.Description, {
			Position = UDim2.fromOffset(x, 46 + TS(22) + TS(12) + 4),
			Size = UDim2.new(1, -x - 16, 1, -(52 + TS(22) + TS(12) + 4)),
			TextWrapped = true,
			TextYAlignment = Enum.TextYAlignment.Top,
			TextTruncate = Enum.TextTruncate.AtEnd,
		}, Theme.TextSize.Small)
	else
		-- rarity band
		local band = new("Frame", { Name = "Band", BackgroundColor3 = bandColor, BorderSizePixel = 0, Size = UDim2.new(1, 0, 0, 34), ZIndex = 2 }, face)
		UIKit.corner(band, Theme.Radius.L)
		new("Frame", { BackgroundColor3 = bandColor, BorderSizePixel = 0, Position = UDim2.new(0, 0, 1, -Theme.Radius.L), Size = UDim2.new(1, 0, 0, Theme.Radius.L), ZIndex = 2 }, band)
		text(band, "Label", UIKit.track(bandText), {
			Size = UDim2.fromScale(1, 1),
			TextXAlignment = Enum.TextXAlignment.Center,
			TextColor3 = legendary and P.gold_900 or P.ivory_100,
			ZIndex = 3,
		}, Theme.TextSize.Caption + 1)
		local tileSize = math.clamp(math.floor(h * 0.27), 80, 104)
		local tile = UIKit.Tile(face, { Id = iconId, Size = tileSize, Evolved = c.Type == "Evolve" })
		tile.AnchorPoint = Vector2.new(0.5, 0)
		tile.Position = UDim2.new(0.5, 0, 0, 50)
		if animate then
			UIAnim.Pop(tile, 0.08 * index + 0.15, 0.4)
		end
		local y = 50 + tileSize + 12
		text(face, "H2", c.Name, {
			Position = UDim2.fromOffset(12, y),
			Size = UDim2.new(1, -24, 0, TS(22) + 6),
			TextXAlignment = Enum.TextXAlignment.Center,
			TextTruncate = Enum.TextTruncate.AtEnd,
		})
		y += TS(22) + 6
		text(face, "Caption", UIKit.track(cardLevelText(c)), {
			Position = UDim2.fromOffset(12, y),
			Size = UDim2.new(1, -24, 0, TS(12) + 6),
			TextXAlignment = Enum.TextXAlignment.Center,
			TextColor3 = edgeColor,
		})
		y += TS(12) + 10
		UIKit.Divider(face, 120, { AnchorPoint = Vector2.new(0.5, 0), Position = UDim2.new(0.5, 0, 0, y) })
		y += 16
		text(face, "Body", c.Description, {
			Position = UDim2.fromOffset(16, y),
			Size = UDim2.new(1, -32, 1, -(y + 36)),
			TextXAlignment = Enum.TextXAlignment.Center,
			TextYAlignment = Enum.TextYAlignment.Top,
			TextWrapped = true,
			TextTruncate = Enum.TextTruncate.AtEnd,
		})
		if UserInputService.KeyboardEnabled and not UserInputService.TouchEnabled then
			local key = UIKit.Badge(face, tostring(index), "Dark", { AnchorPoint = Vector2.new(0.5, 1), Position = UDim2.new(0.5, 0, 1, -10) })
			key.Size = UDim2.fromOffset(22, 22)
			key.AutomaticSize = Enum.AutomaticSize.None
		end
	end

	if animate then
		-- cards rise in one after another
		UIAnim.Pop(hit, 0.07 * (index - 1), 0.5)
		hit.Rotation = (index % 2 == 0) and 4 or -4
		task.delay(0.07 * (index - 1), function()
			UIAnim.Tween(hit, 0.4, { Rotation = 0 }, Enum.EasingStyle.Back)
		end)
	end
	hit.Activated:Connect(function()
		chooseCard(index)
	end)
	return hit
end

local function layoutLevelUp()
	local v = virtualSize()
	local count = lastOffer and #lastOffer.Choices or 3
	local cw, ch = cardMetrics(count)
	local titleH = TS(44) + 8
	local cardsW = portrait and cw or (count * cw + (count - 1) * 18)
	local cardsH = portrait and (count * ch + (count - 1) * 12) or ch
	local blockH = titleH + 12 + 26 + 16 + cardsH + 24 + 52
	local top = math.max(insets.Top * 0.5 + 6, (v.Y - blockH) / 2)
	local panel = levelUp.Panel :: Frame
	panel.Position = UDim2.fromOffset(0, 0)
	panel.Size = UDim2.fromOffset(v.X, v.Y)
	levelUp.Title.Position = UDim2.fromOffset(0, top)
	levelUp.Title.Size = UDim2.new(1, 0, 0, titleH)
	levelUp.Divider.AnchorPoint = Vector2.new(0.5, 0)
	levelUp.Divider.Position = UDim2.new(0.5, 0, 0, top + titleH)
	levelUp.Sub.Position = UDim2.fromOffset(0, top + titleH + 12)
	levelUp.Sub.Size = UDim2.new(1, 0, 0, TS(16) + 6)
	levelUp.Timer.Frame.AnchorPoint = Vector2.new(0.5, 0)
	levelUp.Timer.Frame.Position = UDim2.new(0.5, 0, 0, top + titleH + 12 + TS(16) + 8)
	local cardsY = top + titleH + 12 + 26 + 16
	levelUp.Layout.FillDirection = portrait and Enum.FillDirection.Vertical or Enum.FillDirection.Horizontal
	levelUp.Layout.Padding = UDim.new(0, portrait and 12 or 18)
	levelUp.Cards.Position = UDim2.fromOffset((v.X - cardsW) / 2, cardsY)
	levelUp.Cards.Size = UDim2.fromOffset(cardsW, cardsH)
	levelUp.Actions.Position = UDim2.fromOffset(0, cardsY + cardsH + 24)
	levelUp.Actions.Size = UDim2.new(1, 0, 0, 52)
end

local function buildCards(animate: boolean)
	for _, c in ipairs(levelUp.Cards:GetChildren()) do
		if c:IsA("GuiObject") then
			c:Destroy()
		end
	end
	local offer = lastOffer
	if not offer then
		return
	end
	local first
	for i, c in ipairs(offer.Choices) do
		local card = makeCard(c, i, #offer.Choices, animate)
		first = first or card
	end
	layoutLevelUp()
	return first
end

local function showOffer(offer)
	lastOffer = offer
	local first = buildCards(true)
	levelUp.Reroll.SetText("REROLL (" .. offer.Rerolls .. ")")
	levelUp.Reroll.Instance.Visible = offer.Rerolls > 0
	levelUp.Skip.SetText("SKIP (" .. offer.Skips .. ")")
	levelUp.Skip.Instance.Visible = offer.Skips > 0
	levelUp.Title.Text = offer.Pending > 1 and string.format("LEVEL UP!  +%d", offer.Pending) or "LEVEL UP!"
	UIAnim.Punch(levelUp.Title, 0.35)
	offerSeconds = math.max(1, offer.Seconds)
	offerDeadline = os.clock() + offer.Seconds
	offerOpen = true
	show(levelUp.Overlay, "LevelUp", true)
	UIKit.FocusIfGamepad(first)
end

local function closeOffer()
	offerOpen = false
	hide(levelUp.Overlay, "LevelUp")
end

------------------------------------------------------------------------------------------
-- Chest reward
------------------------------------------------------------------------------------------

local chest: { [string]: any } = {}

-- Display name → icon id (chest rewards only carry names).
local nameToId: { [string]: string } = {}
for id, def in pairs(WeaponData.Weapons) do
	nameToId[def.Name] = id
	if def.Evolution then
		nameToId[def.Evolution.Name] = def.Evolution.Id
	end
end
for id, def in pairs(PassiveData.Passives) do
	nameToId[def.Name] = id
end

local function buildChest()
	local holder, face = UIKit.Surface(root, {
		Name = "Chest",
		Size = UDim2.fromOffset(420, 318),
		AnchorPoint = Vector2.new(0.5, 0),
		Radius = Theme.Radius.L,
		Edge = P.gold_400,
		EdgeTransparency = 0.2,
		Transparency = 0.04,
		Visible = false,
		ZIndex = Theme.Z.Chest,
	})
	chest.Panel = holder
	text(face, "H1", "TREASURE!", { Position = UDim2.fromOffset(0, 14), Size = UDim2.new(1, 0, 0, TS(30) + 6), TextXAlignment = Enum.TextXAlignment.Center, TextColor3 = P.gold_300 })
	UIKit.Divider(face, 220, { AnchorPoint = Vector2.new(0.5, 0), Position = UDim2.new(0.5, 0, 0, 18 + TS(30) + 6) })
	-- the chest: a glow, the box and a lid that pops open
	local stage = new("Frame", { Name = "Stage", BackgroundTransparency = 1, AnchorPoint = Vector2.new(0.5, 0), Position = UDim2.new(0.5, 0, 0, 30 + TS(30)), Size = UDim2.fromOffset(160, 96) }, face)
	chest.Glow = new("Frame", { AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.55), Size = UDim2.fromOffset(10, 10), BackgroundColor3 = P.gold_300, BackgroundTransparency = 1 }, stage)
	UIKit.corner(chest.Glow, 999)
	local box = new("Frame", { Name = "Box", AnchorPoint = Vector2.new(0.5, 1), Position = UDim2.new(0.5, 0, 1, 0), Size = UDim2.fromOffset(140, 64), BackgroundColor3 = Color3.new(1, 1, 1) }, stage)
	UIKit.corner(box, 6)
	new("UIGradient", { Rotation = 90, Color = ColorSequence.new(P.wood_500, P.wood_700) }, box)
	UIKit.stroke(box, P.gold_500, 2, 0)
	for _, x in ipairs({ 0.18, 0.82 }) do
		new("Frame", { AnchorPoint = Vector2.new(0.5, 0), Position = UDim2.fromScale(x, 0), Size = UDim2.new(0, 8, 1, 0), BackgroundColor3 = P.gold_500, BorderSizePixel = 0 }, box)
	end
	local lock = new("Frame", { AnchorPoint = Vector2.new(0.5, 0), Position = UDim2.new(0.5, 0, 0, 4), Size = UDim2.fromOffset(18, 22), BackgroundColor3 = P.gold_400 }, box)
	UIKit.corner(lock, 4)
	chest.Box = box
	local lid = new("Frame", { Name = "Lid", AnchorPoint = Vector2.new(0.5, 1), Position = UDim2.new(0.5, 0, 1, -62), Size = UDim2.fromOffset(150, 34), BackgroundColor3 = Color3.new(1, 1, 1) }, stage)
	UIKit.corner(lid, 12)
	new("UIGradient", { Rotation = 90, Color = ColorSequence.new(P.wood_400, P.wood_600) }, lid)
	UIKit.stroke(lid, P.gold_500, 2, 0)
	chest.Lid = lid
	chest.LidHome = lid.Position
	chest.Rewards = new("Frame", { Name = "Rewards", BackgroundTransparency = 1, Position = UDim2.fromOffset(20, 134 + TS(30)), Size = UDim2.new(1, -40, 0, 130) }, face)
	UIKit.list(chest.Rewards, { Padding = UDim.new(0, 6), HorizontalAlignment = Enum.HorizontalAlignment.Center })
	onRelayout(function()
		local v = virtualSize()
		local h = 290 + TS(30)
		holder.Size = UDim2.fromOffset(420, h)
		-- under the HUD top cluster, never over the ability bar (landscape)
		local x = v.X / 2
		local y = math.max(Hud.TopBottom() + 8, v.Y * 0.2)
		if not portrait and y + h > Hud.BarTop() - 8 then
			-- short landscape screens: the right side, under the pause button
			x = v.X - margin() - 210
			y = math.min(insets.Top + 80, Hud.BarTop() - 8 - h)
		end
		holder.Position = UDim2.fromOffset(x, y)
	end)
end

local function rewardRow(icon: string?, title: string, detail: string, color: Color3, isUpgrade: boolean)
	local row = new("Frame", { BackgroundTransparency = 1, Size = UDim2.fromOffset(0, 34), AutomaticSize = Enum.AutomaticSize.X }, chest.Rewards)
	UIKit.list(row, { FillDirection = Enum.FillDirection.Horizontal, VerticalAlignment = Enum.VerticalAlignment.Center, Padding = UDim.new(0, 10) })
	if icon then
		if isUpgrade then
			UIKit.Tile(row, { Id = icon, Size = 32 }).LayoutOrder = 1
		else
			Icons.Draw(row, icon, { Size = 26, LayoutOrder = 1 })
		end
	end
	text(row, "BodyStrong", title, { LayoutOrder = 2, Size = UDim2.fromOffset(0, 34), AutomaticSize = Enum.AutomaticSize.X, TextColor3 = C.Text }, Theme.TextSize.H3)
	text(row, "Label", detail, { LayoutOrder = 3, Size = UDim2.fromOffset(0, 34), AutomaticSize = Enum.AutomaticSize.X, TextColor3 = color })
	UIAnim.Pop(row, 0, 0.5)
end

local chestToken = 0
function UIBuilder.ShowChest(data)
	chestToken += 1
	local token = chestToken
	for _, c in ipairs(chest.Rewards:GetChildren()) do
		if c:IsA("GuiObject") then
			c:Destroy()
		end
	end
	chest.Panel.Visible = true
	UIAnim.Pop(chest.Panel, 0, 0.5)
	chest.Lid.Position = chest.LidHome
	chest.Lid.Rotation = 0
	chest.Glow.Size = UDim2.fromOffset(10, 10)
	chest.Glow.BackgroundTransparency = 1
	-- shake, pop the lid, burst of light, then list the rewards
	TweenService:Create(chest.Box, TweenInfo.new(0.06, Enum.EasingStyle.Linear, Enum.EasingDirection.InOut, 5, true), { Rotation = 5 }):Play()
	task.delay(0.4, function()
		chest.Box.Rotation = 0
		TweenService:Create(chest.Lid, TweenInfo.new(0.35, Enum.EasingStyle.Back), { Position = chest.LidHome + UDim2.fromOffset(52, 10), Rotation = 16 }):Play()
		chest.Glow.BackgroundTransparency = 0.25
		TweenService:Create(chest.Glow, TweenInfo.new(0.55), { Size = UDim2.fromOffset(240, 240), BackgroundTransparency = 1 }):Play()
		for i, r in ipairs(data.Rewards) do
			task.delay(0.15 * i, function()
				if token == chestToken then
					rewardRow(nameToId[r.Name], r.Name, string.upper(r.Text), P.gold_300, true)
				end
			end)
		end
		task.delay(0.15 * (#data.Rewards + 1), function()
			if token == chestToken then
				rewardRow("coin", "+" .. UIKit.formatNumber(data.Gold), "GOLD", P.gold_300, false)
			end
		end)
	end)
	task.delay(3.4, function()
		if token == chestToken then
			UIAnim.PopOut(chest.Panel, function()
				if token == chestToken then
					chest.Panel.Visible = false
				end
			end)
		end
	end)
end

------------------------------------------------------------------------------------------
-- Pause / settings menu (one modal: the in-run pause menu and the lobby SETTINGS)
------------------------------------------------------------------------------------------

local pause: { [string]: any } = {}
local volumes = { Music = 0.6, Sfx = 0.8 }

local function saveVolumes()
	Remotes.Get("SaveSettings"):FireServer({ Music = volumes.Music, Sfx = volumes.Sfx })
end

local function buildPause()
	local m = UIKit.Modal(root, "Pause", 480, 470, Theme.Z.Pause)
	pause.Overlay = m.Overlay
	pause.Modal = m
	local content = m.Content
	fitModal(m, UIKit.list(content, { Padding = UDim.new(0, 12), HorizontalAlignment = Enum.HorizontalAlignment.Center }))
	pause.Title = text(content, "H1", "PAUSED", { LayoutOrder = 1, TextXAlignment = Enum.TextXAlignment.Center })
	UIKit.Divider(content, 220, { LayoutOrder = 2 })
	local function apply()
		if deps.Audio then
			deps.Audio.SetVolumes(volumes.Music, volumes.Sfx)
		end
	end
	pause.Music = UIKit.Slider(content, "Music", "music", volumes.Music, function(v)
		volumes.Music = v
		apply()
	end, saveVolumes, { LayoutOrder = 3 })
	pause.Sfx = UIKit.Slider(content, "Sound effects", "speaker", volumes.Sfx, function(v)
		volumes.Sfx = v
		apply()
	end, saveVolumes, { LayoutOrder = 4 })
	pause.Note = text(content, "Body", "", {
		LayoutOrder = 5,
		TextXAlignment = Enum.TextXAlignment.Center,
		TextWrapped = true,
		Size = UDim2.new(1, 0, 0, TS(16) * 2 + 8),
	})
	pause.Resume = UIKit.Button(content, {
		Kind = "Primary",
		Title = "RESUME",
		Icon = "play",
		IconSize = 20,
		Align = "Center",
		Size = UDim2.fromOffset(240, Theme.Size.Button),
		LayoutOrder = 6,
		OnClick = function()
			UIBuilder.ClosePause()
		end,
	})
	pause.Close = UIKit.IconButton(m.Face, {
		Icon = "close",
		Size = 40,
		Kind = "Ghost",
		AnchorPoint = Vector2.new(1, 0),
		Position = UDim2.new(1, -10, 0, 10),
		ZIndex = 5,
		OnClick = function()
			UIBuilder.ClosePause()
		end,
	})
	onRelayout(function()
		local v = virtualSize()
		m.Panel.Size = UDim2.new(UDim.new(0, math.min(480, v.X - 32)), m.Panel.Size.Y)
	end)
end

-- The same menu is the in-run pause menu and the lobby SETTINGS screen.
local pauseMode = "Pause" -- "Pause" | "Settings"

function UIBuilder.OpenPause()
	pauseMode = "Pause"
	pause.Title.Text = "PAUSED"
	pause.Resume.SetText("RESUME")
	pause.Resume.SetIcon("play")
	local participants = Remotes.State():GetAttribute("Participants") or 1
	pause.Note.Text = (participants <= 1 and Config.Run.SoloPauseFreezesRun) and "The run is paused." or "Group run: the swarm keeps coming while this menu is open!"
	show(pause.Overlay, "Pause", true)
	UIKit.FocusIfGamepad(pause.Resume.Instance)
	Remotes.Get("SetPause"):FireServer(true)
end

function UIBuilder.OpenSettings()
	pauseMode = "Settings"
	pause.Title.Text = "SETTINGS"
	pause.Resume.SetText("DONE")
	pause.Resume.SetIcon("check")
	pause.Note.Text = "Volume is saved with your progress."
	show(pause.Overlay, "Pause", true)
	UIKit.FocusIfGamepad(pause.Resume.Instance)
end

function UIBuilder.ClosePause()
	hide(pause.Overlay, "Pause")
	if pauseMode == "Pause" then
		Remotes.Get("SetPause"):FireServer(false)
	end
end

------------------------------------------------------------------------------------------
-- Revive offer
------------------------------------------------------------------------------------------

local revive: { [string]: any } = {}
local reviveDeadline = 0
local reviveSeconds = 10

local function buildRevive()
	local m = UIKit.Modal(root, "Revive", 460, 340, Theme.Z.Revive)
	revive.Overlay = m.Overlay
	local content = m.Content
	fitModal(m, UIKit.list(content, { Padding = UDim.new(0, 10), HorizontalAlignment = Enum.HorizontalAlignment.Center }))
	Icons.Draw(content, "heart", { Size = 48, LayoutOrder = 1 })
	text(content, "H1", "YOU FELL!", { LayoutOrder = 2, TextXAlignment = Enum.TextXAlignment.Center, TextColor3 = P.crimson_300 })
	revive.Text = text(content, "Body", "Revive and keep fighting?", { LayoutOrder = 3, TextXAlignment = Enum.TextXAlignment.Center })
	local row = new("Frame", { Size = UDim2.new(1, 0, 0, Theme.Size.Button), BackgroundTransparency = 1, LayoutOrder = 4 }, content)
	UIKit.list(row, { FillDirection = Enum.FillDirection.Horizontal, HorizontalAlignment = Enum.HorizontalAlignment.Center, Padding = UDim.new(0, 12) })
	revive.Buy = UIKit.Button(row, {
		Kind = "Primary",
		Title = "REVIVE",
		Icon = "revive",
		IconSize = 22,
		Align = "Center",
		Size = UDim2.fromOffset(200, Theme.Size.Button),
		LayoutOrder = 1,
		OnClick = function()
			local id = Config.Monetization.Products.Revive
			if id and id ~= 0 then
				MarketplaceService:PromptProductPurchase(player, id)
			end
		end,
	})
	revive.No = UIKit.Button(row, {
		Title = "NO THANKS",
		Align = "Center",
		Size = UDim2.fromOffset(170, Theme.Size.Button),
		LayoutOrder = 2,
		OnClick = function()
			Remotes.Get("ReviveDecline"):FireServer()
			hide(revive.Overlay, "Revive")
		end,
	})
	revive.Timer = text(content, "Caption", "", { LayoutOrder = 5, TextXAlignment = Enum.TextXAlignment.Center })
	revive.Meter = UIKit.Meter(content, { Gradient = ColorSequence.new(P.crimson_500, P.crimson_300), Size = UDim2.fromOffset(260, 5), LayoutOrder = 6 })
	onRelayout(function()
		local v = virtualSize()
		m.Panel.Size = UDim2.new(UDim.new(0, math.min(460, v.X - 32)), m.Panel.Size.Y)
	end)
end

local function onReviveOffer(data)
	if data.Close then
		hide(revive.Overlay, "Revive")
		return
	end
	reviveSeconds = math.max(1, data.Seconds or 10)
	reviveDeadline = os.clock() + reviveSeconds
	revive.Buy.SetText("REVIVE")
	task.spawn(function()
		local ok, info = pcall(function()
			return MarketplaceService:GetProductInfo(data.ProductId, Enum.InfoType.Product)
		end)
		if ok and info and info.PriceInRobux then
			revive.Buy.SetText("REVIVE  R$" .. tostring(info.PriceInRobux))
		end
	end)
	show(revive.Overlay, "Revive", true)
	UIKit.FocusIfGamepad(revive.Buy.Instance)
end

------------------------------------------------------------------------------------------
-- Results
------------------------------------------------------------------------------------------

local results: { [string]: any } = {}
local resultsDeadline = 0

local function statTile(parent: Instance, icon: string, caption: string, order: number): TextLabel
	local f = UIKit.Panel(parent, { Name = caption, LayoutOrder = order, Size = UDim2.fromOffset(112, 104) }, true)
	Icons.Draw(f, icon, { Size = 26, AnchorPoint = Vector2.new(0.5, 0), Position = UDim2.new(0.5, 0, 0, 12), Color = if icon == "coin" then nil else P.gold_400, Back = P.slate_950 })
	local value = text(f, "Number", "0", {
		Name = "Value",
		Position = UDim2.fromOffset(0, 42),
		Size = UDim2.new(1, 0, 0, TS(24) + 4),
		TextXAlignment = Enum.TextXAlignment.Center,
	}, 24)
	text(f, "Caption", UIKit.track(caption), {
		AnchorPoint = Vector2.new(0, 1),
		Position = UDim2.new(0, 0, 1, -10),
		Size = UDim2.new(1, 0, 0, TS(12) + 2),
		TextXAlignment = Enum.TextXAlignment.Center,
	}, 11)
	return value
end

local function buildResults()
	local m = UIKit.Modal(root, "Results", 660, 460, Theme.Z.Results)
	results.Overlay = m.Overlay
	results.Modal = m
	local content = m.Content
	fitModal(m, UIKit.list(content, { Padding = UDim.new(0, 10), HorizontalAlignment = Enum.HorizontalAlignment.Center }))
	results.Title = text(content, "Display", "VICTORY!", { LayoutOrder = 1, TextXAlignment = Enum.TextXAlignment.Center }, 48)
	UIKit.Divider(content, 260, { LayoutOrder = 2 })
	results.Arena = text(content, "Label", "", { LayoutOrder = 3, TextXAlignment = Enum.TextXAlignment.Center, TextColor3 = C.TextMuted })
	local grid = new("Frame", { Name = "Stats", BackgroundTransparency = 1, LayoutOrder = 4, Size = UDim2.new(1, 0, 0, 104) }, content)
	results.Grid = grid
	results.GridLayout = UIKit.list(grid, { FillDirection = Enum.FillDirection.Horizontal, HorizontalAlignment = Enum.HorizontalAlignment.Center, Padding = UDim.new(0, 8), Wraps = true })
	results.Time = statTile(grid, "clock", "Time", 1)
	results.Kills = statTile(grid, "skull", "Kills", 2)
	results.Gold = statTile(grid, "coin", "Gold", 3)
	results.Level = statTile(grid, "chevronsUp", "Level", 4)
	results.Damage = statTile(grid, "sword", "Damage", 5)
	results.Best = UIKit.Badge(content, "NEW BEST TIME!", "Gold", { LayoutOrder = 5, Visible = false })
	results.Unlocked = text(content, "BodyStrong", "", { LayoutOrder = 6, TextXAlignment = Enum.TextXAlignment.Center, TextColor3 = P.gold_300, Visible = false })
	results.Button = UIKit.Button(content, {
		Kind = "Primary",
		Title = "RETURN TO LOBBY",
		Icon = "castle",
		IconSize = 22,
		Align = "Center",
		Size = UDim2.fromOffset(300, Theme.Size.Button),
		LayoutOrder = 7,
		OnClick = function()
			Remotes.Get("ReturnToLobby"):FireServer()
			hide(results.Overlay, "Results")
		end,
	})
	results.Timer = text(content, "Caption", "", { LayoutOrder = 8, TextXAlignment = Enum.TextXAlignment.Center })
	onRelayout(function()
		local v = virtualSize()
		local w = math.min(660, v.X - 32)
		local twoRows = w < 640
		results.Grid.Size = UDim2.new(1, 0, 0, twoRows and 216 or 104)
		m.Panel.Size = UDim2.new(UDim.new(0, w), m.Panel.Size.Y)
	end)
end

local function onRunResult(data)
	closeOffer()
	hide(revive.Overlay, "Revive")
	hide(pause.Overlay, "Pause")
	results.Title.Text = data.Won and "VICTORY!" or "DEFEATED"
	results.Title.TextColor3 = data.Won and P.gold_300 or P.crimson_300
	results.Arena.Text = UIKit.track("Arena: " .. tostring(data.Arena))
	results.Time.Text = formatTime(data.Time)
	results.Best.Visible = data.NewBest == true
	results.Unlocked.Visible = data.Unlocked ~= nil
	results.Unlocked.Text = data.Unlocked and ("Unlocked: " .. data.Unlocked .. " arena!") or ""
	resultsDeadline = os.clock() + (data.Seconds or 20)
	show(results.Overlay, "Results", true)
	UIKit.FocusIfGamepad(results.Button.Instance)
	-- title drops in, then the numbers count up one after another
	UIAnim.Pop(results.Title, 0.1, 1.6)
	UIAnim.CountUp(results.Kills, data.Kills, "%d", 0.8, 0.4)
	UIAnim.CountUp(results.Gold, data.Gold, "%d", 0.8, 0.6)
	UIAnim.CountUp(results.Level, data.Level, "%d", 0.6, 0.8)
	UIAnim.CountUp(results.Damage, data.Damage, "%d", 0.8, 1.0)
	if data.NewBest then
		UIAnim.Pop(results.Best, 1.2, 0.4)
		UIAnim.Punch(results.Time, 0.3)
	end
end

------------------------------------------------------------------------------------------
-- Lobby (LobbyScreen) entry points kept for older callers
------------------------------------------------------------------------------------------

-- "Characters" | "Shop" / "Upgrades" | "Stats": jumps to that lobby screen.
function UIBuilder.OpenPanel(name: string)
	if player:GetAttribute("InRun") then
		return
	end
	LobbyScreen.Show(name)
end

function UIBuilder.ClosePanels()
	LobbyScreen.Show("Home")
end

------------------------------------------------------------------------------------------
-- Profile + state driven refresh
------------------------------------------------------------------------------------------

function UIBuilder.RefreshProfileViews()
	if profile then
		LobbyScreen.SetProfile(profile)
	end
end

local function onProfile(data)
	profile = data
	if data.Settings then
		volumes.Music = data.Settings.Music
		volumes.Sfx = data.Settings.Sfx
		if pause.Music then
			pause.Music.Set(volumes.Music)
			pause.Sfx.Set(volumes.Sfx)
		end
		if deps.Audio then
			deps.Audio.SetVolumes(volumes.Music, volumes.Sfx)
		end
	end
	UIBuilder.RefreshProfileViews()
end

local wasInRun: boolean? = nil

local function updateFrame(dt: number)
	local state = Remotes.State()
	local inRun = player:GetAttribute("InRun") == true

	if wasInRun ~= inRun then
		wasInRun = inRun
		Hud.SetVisible(inRun)
		-- the lobby is a menu: no thumbstick / walking there
		setBlocking("Lobby", not inRun)
		LobbyScreen.SetVisible(not inRun)
		Showcase.SetVisible(not inRun)
		updateScale()
	end

	if inRun then
		Hud.Update(dt, state, revive.Overlay.Visible)
	else
		LobbyScreen.Update(dt)
	end

	if levelUp.Overlay.Visible then
		local left = math.max(0, offerDeadline - os.clock())
		levelUp.Sub.Text = string.format("Choose an upgrade  ·  auto-pick in %ds", math.ceil(left))
		levelUp.Timer.Set(left / offerSeconds)
	end
	if revive.Overlay.Visible then
		local left = math.max(0, reviveDeadline - os.clock())
		revive.Timer.Text = UIKit.track(string.format("Offer ends in %ds", math.ceil(left)))
		revive.Meter.Set(left / reviveSeconds)
		if left <= 0 then
			hide(revive.Overlay, "Revive")
		end
	end
	if results.Overlay.Visible then
		results.Timer.Text = UIKit.track("Back to the lobby in " .. math.max(0, math.ceil(resultsDeadline - os.clock())) .. "s")
		if not inRun then
			hide(results.Overlay, "Results")
		end
	end
	-- the pause menu belongs to the run, the settings menu to the lobby
	if pause.Overlay.Visible and (pauseMode == "Pause") ~= inRun then
		hide(pause.Overlay, "Pause")
	end
end

------------------------------------------------------------------------------------------
-- Init
------------------------------------------------------------------------------------------

-- The Roblox player list and backpack would cover the stats chip / pause button and the
-- game has no tools or emotes; chat stays.
local function setupCoreGui()
	for _, t in ipairs({ Enum.CoreGuiType.PlayerList, Enum.CoreGuiType.Backpack, Enum.CoreGuiType.EmotesMenu }) do
		pcall(function()
			StarterGui:SetCoreGuiEnabled(t, false)
		end)
	end
end

function UIBuilder.Init(d: { [string]: any })
	deps = d
	setupCoreGui()
	local viewport = workspace.CurrentCamera.ViewportSize
	UIKit.SetCompact(math.min(viewport.X, viewport.Y) < 560)

	gui = new("ScreenGui", {
		Name = "SwarmUI",
		ResetOnSpawn = false,
		ZIndexBehavior = Enum.ZIndexBehavior.Sibling,
		DisplayOrder = 10,
	}, nil)
	gui.IgnoreGuiInset = true
	gui.ScreenInsets = Enum.ScreenInsets.DeviceSafeInsets
	gui.Parent = player:WaitForChild("PlayerGui")
	-- full-screen effects (hurt vignette, menu vignette) under the UI, over the 3D world
	fxGui = new("ScreenGui", {
		Name = "SwarmFx",
		ResetOnSpawn = false,
		ZIndexBehavior = Enum.ZIndexBehavior.Sibling,
		DisplayOrder = 9,
	}, nil)
	fxGui.IgnoreGuiInset = true
	fxGui.ScreenInsets = Enum.ScreenInsets.None
	fxGui.Parent = player:WaitForChild("PlayerGui")

	root = new("Frame", { Name = "Root", Size = UDim2.fromScale(1, 1), BackgroundTransparency = 1 }, gui)
	uiScale = new("UIScale", { Scale = 1 }, root)
	if deps.MobileControls then
		deps.MobileControls.SetScale(uiScale)
	end
	UIKit.SetAudio(deps.Audio)

	local hostApi = {
		Root = root,
		FxGui = fxGui,
		Audio = deps.Audio,
		VirtualSize = virtualSize,
		IsPortrait = function(): boolean
			return portrait
		end,
		Insets = function(): Hud.Insets
			return insets
		end,
		Scale = function(): number
			return uiScale.Scale
		end,
		OnRelayout = onRelayout,
		OpenSettings = function()
			UIBuilder.OpenSettings()
		end,
		Toast = function(str: string, color: Color3?)
			UIBuilder.Toast(str, color)
		end,
		OnPause = function()
			UIBuilder.OpenPause()
		end,
	}

	Showcase.Init()
	Hud.Build(root, fxGui, hostApi)
	LobbyScreen.Init(hostApi)
	buildToasts()
	buildLevelUp()
	buildChest()
	buildPause()
	buildRevive()
	buildResults()
	DevPanel.Init(root, hostApi)
	onRelayout(function()
		if levelUp.Overlay.Visible and lastOffer then
			buildCards(false)
		else
			layoutLevelUp()
		end
	end)

	gui:GetPropertyChangedSignal("AbsoluteSize"):Connect(updateScale)
	gui:GetPropertyChangedSignal("AbsolutePosition"):Connect(updateScale)
	pcall(function()
		GuiService:GetPropertyChangedSignal("TopbarInset"):Connect(updateScale)
	end)
	updateScale()

	Remotes.Get("Inventory").OnClientEvent:Connect(function(data)
		Hud.SetInventory(data)
	end)
	Remotes.Get("LevelUpOffer").OnClientEvent:Connect(showOffer)
	Remotes.Get("LevelUpClose").OnClientEvent:Connect(closeOffer)
	Remotes.Get("ChestOpened").OnClientEvent:Connect(UIBuilder.ShowChest)
	Remotes.Get("Notify").OnClientEvent:Connect(function(data)
		if type(data) == "table" and type(data.Text) == "string" then
			UIBuilder.Toast(data.Text, data.Color, data.Big)
		end
	end)
	Remotes.Get("RunResult").OnClientEvent:Connect(onRunResult)
	Remotes.Get("ProfileSync").OnClientEvent:Connect(onProfile)
	Remotes.Get("ReviveOffer").OnClientEvent:Connect(onReviveOffer)
	Remotes.Get("OpenPanel").OnClientEvent:Connect(function(name)
		if name == "Joined" then
			LobbyScreen.SetJoined(true)
		elseif type(name) == "string" then
			UIBuilder.OpenPanel(name)
		end
	end)

	-- Leaving a run clears the HUD inventory; entering one starts a clean HUD.
	player:GetAttributeChangedSignal("InRun"):Connect(function()
		if not player:GetAttribute("InRun") then
			Hud.SetInventory(nil)
			closeOffer()
		else
			Hud.Reset()
		end
	end)

	RunService.RenderStepped:Connect(updateFrame)
	Remotes.Get("RequestProfile"):FireServer()
end

-- Crimson screen-edge pulse when the local player is hurt (ClientMain → VFX "hurt").
function UIBuilder.HurtFlash()
	Hud.Hurt()
end

return UIBuilder
