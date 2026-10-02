--[[
	UIBuilder.lua
	Hosts every screen and builds the in-run ones: HUD (Hud.lua), the stage loop's arrow,
	charge ring, portal choice and travel fade (StageUI.lua), run items and map loot (item
	strip, item popups, chest / shrine prompts, items list: LootUI.lua), toasts and banners, level-up
	cards, chest reward, pause / settings menu, revive offer and the results screen. It also hosts the lobby menu (LobbyScreen), the hero on the dais (Showcase) and
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
local CharacterData = require(Shared:WaitForChild("CharacterData"))
local UIAnim = require(script.Parent.UIAnim)
local UIKit = require(script.Parent.UIKit)
local Icons = require(script.Parent.Icons)
local Hud = require(script.Parent.Hud)
local StageUI = require(script.Parent.StageUI)
local LootUI = require(script.Parent.LootUI)
local LobbyScreen = require(script.Parent.LobbyScreen)
local DevPanel = require(script.Parent.DevPanel)
local Showcase = require(script.Parent.Showcase)
local ClientSettings = require(script.Parent.ClientSettings)
local TeamUI = require(script.Parent.TeamUI)
local Tutorial = require(script.Parent.Tutorial)
local Cosmetics = require(script.Parent.Cosmetics)
local CurseData = require(Shared:WaitForChild("CurseData"))
local ItemData = require(Shared:WaitForChild("ItemData"))

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
local updateSaveNotice: (boolean) -> () -- defined with the save notice below

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
local offerHint: string? = nil -- first-run explanation under LEVEL UP! (Tutorial)

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

-- Rank line under the card name: "NEW WEAPON", "LV 3 → 4 / 8", "EVOLUTION" (the server
-- sends Rank; older servers only sent Level).
local function cardLevelText(c): string
	if c.Type == "WeaponNew" then
		return "NEW WEAPON"
	elseif c.Type == "PassiveNew" then
		return "NEW PASSIVE"
	elseif c.Type == "Evolve" then
		local def = WeaponData.Weapons[c.Id]
		return string.upper((def and def.Name or "Weapon") .. " evolves")
	elseif c.Rank then
		return string.upper(c.Rank)
	elseif c.Type == "WeaponUp" then
		return string.format("LV %d → %d / %d", c.Level - 1, c.Level, WeaponData.MaxLevel)
	elseif c.Type == "PassiveUp" then
		return string.format("LV %d → %d / %d", c.Level - 1, c.Level, PassiveData.MaxLevelOf(c.Id))
	elseif c.Type == "Heal" then
		return "RESTORE HEALTH"
	elseif c.Type == "Gold" then
		return "RUN GOLD"
	end
	return ""
end

local function hex(c: Color3): string
	return string.format("#%02X%02X%02X", math.floor(c.R * 255 + 0.5), math.floor(c.G * 255 + 0.5), math.floor(c.B * 255 + 0.5))
end

--[[
	What the card changes, as RichText lines ("Damage 10 → 15" with the new value bright):
	the server's Lines, or the plain Description for older servers / bonus cards.
	New cards start with their short description.
]]
local function cardRichLines(c, sep: string): string
	local out = {}
	local isNew = c.Type == "WeaponNew" or c.Type == "PassiveNew" or c.Type == "PassiveUp" or c.Type == "Evolve"
	if isNew and c.Description and c.Description ~= "" then
		table.insert(out, string.format('<font color="%s">%s</font>', hex(C.TextMuted), c.Description))
	end
	local lines = type(c.Lines) == "table" and c.Lines or {}
	if c.Type == "WeaponNew" then
		-- starting stats of a new weapon on one line: "Damage 22 · Arrows 1 · Cooldown 1.70s"
		local parts = {}
		for _, line in ipairs(lines) do
			if line.To and not line.From and not line.Text then
				table.insert(parts, string.format('%s <font color="%s"><b>%s</b></font>', tostring(line.Label), hex(C.Text), tostring(line.To)))
			end
		end
		if #parts > 0 then
			table.insert(out, table.concat(parts, "  ·  "))
		end
		return table.concat(out, sep)
	end
	for _, line in ipairs(lines) do
		if line.Text then
			table.insert(out, string.format('<font color="%s"><b>%s</b></font> %s', hex(P.gold_300), tostring(line.Label), tostring(line.Text)))
		elseif line.From then
			table.insert(out, string.format('%s %s → <font color="%s"><b>%s</b></font>', tostring(line.Label), tostring(line.From), hex(P.moss_200), tostring(line.To)))
		elseif line.To then
			table.insert(out, string.format('%s <font color="%s"><b>%s</b></font>', tostring(line.Label), hex(C.Text), tostring(line.To)))
		end
	end
	if #out == 0 and c.Description then
		table.insert(out, c.Description)
	end
	return table.concat(out, sep)
end

local pickedAt = 0 -- when a card was last picked (its punch plays before the close)

-- The picked card punches and flashes, the others sink back.
local function pickAnimation(index: number)
	pickedAt = os.clock()
	for _, card in ipairs(levelUp.Cards:GetChildren()) do
		if card:IsA("GuiObject") then
			local s = UIAnim.ScaleOf(card)
			if card.Name == "Card" .. index then
				s.Scale = 1.12
				UIAnim.Tween(s, 0.22, { Scale = 1.04 }, Enum.EasingStyle.Back)
				local face = card:FindFirstChild("Face")
				if face and face:IsA("GuiObject") and not ClientSettings.Reduced() then
					local flash = new("Frame", { Name = "PickFlash", BackgroundColor3 = P.ivory_100, BackgroundTransparency = 0.25, BorderSizePixel = 0, Size = UDim2.fromScale(1, 1), ZIndex = 60 }, face)
					UIKit.corner(flash, Theme.Radius.L)
					TweenService:Create(flash, TweenInfo.new(0.3), { BackgroundTransparency = 1 }):Play()
				end
			else
				UIAnim.Tween(s, 0.18, { Scale = 0.9 })
			end
		end
	end
end

local function chooseCard(index: number)
	if not offerOpen then
		return
	end
	offerOpen = false
	UIKit.Click()
	pickAnimation(index)
	Remotes.Get("LevelUpChoose"):FireServer(index)
end

-- A one-shot light streak across a card face (clipped to the card).
local function cardSweep(face: GuiObject, delay: number, color: Color3)
	local clip = new("Frame", { Name = "Sweep", BackgroundTransparency = 1, Size = UDim2.fromScale(1, 1), ClipsDescendants = true, ZIndex = 40 }, face)
	local streak = new("Frame", { BackgroundColor3 = color, BackgroundTransparency = 0.55, BorderSizePixel = 0, AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(-0.3, 0.5), Size = UDim2.new(0.22, 0, 1.6, 0), Rotation = 18, ZIndex = 40, Visible = false }, clip)
	new("UIGradient", { Transparency = NumberSequence.new({ NumberSequenceKeypoint.new(0, 1), NumberSequenceKeypoint.new(0.5, 0.2), NumberSequenceKeypoint.new(1, 1) }) }, streak)
	task.delay(delay, function()
		if streak.Parent then
			streak.Visible = true
			local tw = TweenService:Create(streak, TweenInfo.new(0.5, Enum.EasingStyle.Quad, Enum.EasingDirection.InOut), { Position = UDim2.fromScale(1.3, 0.5) })
			tw.Completed:Once(function()
				clip:Destroy()
			end)
			tw:Play()
		end
	end)
end

-- Evolution card: a gold burst (ring + rays) behind it as it lands.
local function goldBurst(hit: GuiObject, delay: number)
	local holder = new("Frame", { Name = "Burst", BackgroundTransparency = 1, AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.5), Size = UDim2.fromOffset(10, 10), ZIndex = 0 }, hit)
	local ring = new("Frame", { BackgroundColor3 = P.gold_300, BackgroundTransparency = 1, AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.5), Size = UDim2.fromOffset(40, 40), ZIndex = 0 }, holder)
	UIKit.corner(ring, 999)
	local rays = {}
	for i = 0, 7 do
		local ray = new("Frame", { BackgroundColor3 = P.gold_200, BackgroundTransparency = 1, BorderSizePixel = 0, AnchorPoint = Vector2.new(0.5, 1), Position = UDim2.fromScale(0.5, 0.5), Size = UDim2.fromOffset(6, 20), Rotation = i * 45, ZIndex = 0 }, holder)
		UIKit.corner(ray, 3)
		table.insert(rays, ray)
	end
	task.delay(delay, function()
		if not holder.Parent then
			return
		end
		local w = hit.AbsoluteSize.X / math.max(0.01, uiScale.Scale)
		ring.BackgroundTransparency = 0.25
		TweenService:Create(ring, TweenInfo.new(0.6, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), { Size = UDim2.fromOffset(w * 1.5, w * 1.5), BackgroundTransparency = 1 }):Play()
		for _, ray in ipairs(rays) do
			ray.BackgroundTransparency = 0.1
			TweenService:Create(ray, TweenInfo.new(0.55, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), { Size = UDim2.fromOffset(4, w * 0.95), BackgroundTransparency = 1 }):Play()
		end
		task.delay(0.7, function()
			holder:Destroy()
		end)
	end)
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
	-- REROLL: 3 new cards; SKIP: no card, a little run gold. Both show what is left this
	-- run (permanent upgrades / VIP give them); with none bought they say where to get them.
	levelUp.Reroll = UIKit.Button(actions, {
		Title = "REROLL",
		Subtitle = "New cards",
		TitleStyle = "H3",
		Icon = "cycle",
		IconSize = 20,
		Size = UDim2.fromOffset(230, 60),
		Align = "Left",
		LayoutOrder = 1,
		OnClick = function()
			if offerOpen then
				Remotes.Get("LevelUpReroll"):FireServer()
			end
		end,
	})
	levelUp.Skip = UIKit.Button(actions, {
		Title = "SKIP",
		Subtitle = "No card",
		TitleStyle = "H3",
		Icon = "skip",
		IconSize = 20,
		Size = UDim2.fromOffset(230, 60),
		Align = "Left",
		LayoutOrder = 2,
		OnClick = function()
			if offerOpen then
				offerOpen = false
				Remotes.Get("LevelUpSkip"):FireServer()
			end
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
		-- tall enough for the busiest card of this offer (one line per stat change)
		local most = 0
		for _, c in ipairs(lastOffer and lastOffer.Choices or {}) do
			local n = type(c.Lines) == "table" and #c.Lines or 1
			if c.Type == "WeaponNew" then
				n = 1
			end
			if c.Type == "WeaponNew" or c.Type == "PassiveNew" or c.Type == "PassiveUp" or c.Type == "Evolve" then
				n += 1 -- the short description
			end
			if c.Hint then
				n += 1
			end
			most = math.max(most, n)
		end
		local lineH = TS(Theme.TextSize.Small) + 5
		return math.min(v.X - 2 * m, 600), math.clamp(78 + TS(22) + most * lineH, UIKit.IsCompact() and 150 or 136, 300)
	end
	local w = math.min(290, (v.X - 2 * m - (count - 1) * 18) / math.max(1, count))
	local h = math.clamp(v.Y - 290, 300, 400)
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
	UIKit.AttachStates(hit, face, Theme.Radius.L, function(on: boolean)
		-- hover: the card lifts (AttachStates) and grows a touch
		if offerOpen then
			UIAnim.Tween(UIAnim.ScaleOf(hit), Theme.Motion.Fast, { Scale = on and 1.03 or 1 })
		end
	end)

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
		local hintH = c.Hint and (TS(13) + 4) or 0
		text(face, "Body", cardRichLines(c, "\n"), {
			Position = UDim2.fromOffset(x, 46 + TS(22) + TS(12) + 4),
			Size = UDim2.new(1, -x - 16, 1, -(52 + TS(22) + TS(12) + 4 + hintH)),
			TextWrapped = true,
			RichText = true,
			TextColor3 = C.Text,
			TextYAlignment = Enum.TextYAlignment.Top,
			TextTruncate = Enum.TextTruncate.AtEnd,
		}, Theme.TextSize.Small)
		if c.Hint then
			text(face, "Small", tostring(c.Hint), {
				AnchorPoint = Vector2.new(0, 1),
				Position = UDim2.new(0, x, 1, -8),
				Size = UDim2.new(1, -x - 16, 0, TS(13) + 2),
				TextColor3 = c.HintReady and P.gold_300 or C.TextMuted,
				TextTruncate = Enum.TextTruncate.AtEnd,
			}, 13)
		end
	else
		-- rarity band
		local band = new("Frame", { Name = "Band", BackgroundColor3 = bandColor, BorderSizePixel = 0, Size = UDim2.new(1, 0, 0, 34), ZIndex = 2, ClipsDescendants = true }, face)
		UIKit.corner(band, Theme.Radius.L)
		if c.Rarity == "Rare" or c.Rarity == "Epic" or legendary or c.Type == "Evolve" then
			-- the rarer bands shine now and then (started once the card has landed level:
			-- Roblox does not clip inside a rotated card)
			if not ClientSettings.Reduced() then
				task.delay(animate and (0.08 * (index - 1) + 0.5) or 0, function()
					if band.Parent then
						UIAnim.Shine(band, legendary and 1.8 or 2.8, legendary and 0.6 or 0.75)
					end
				end)
			end
		end
		new("Frame", { BackgroundColor3 = bandColor, BorderSizePixel = 0, Position = UDim2.new(0, 0, 1, -Theme.Radius.L), Size = UDim2.new(1, 0, 0, Theme.Radius.L), ZIndex = 2 }, band)
		text(band, "Label", UIKit.track(bandText), {
			Size = UDim2.fromScale(1, 1),
			TextXAlignment = Enum.TextXAlignment.Center,
			TextColor3 = legendary and P.gold_900 or P.ivory_100,
			ZIndex = 3,
		}, Theme.TextSize.Caption + 1)
		-- header: big centred icon on tall cards; on short ones (phones) the icon sits left
		-- of the name so the lines below keep their room
		local y
		local tall = h >= 380 and not UIKit.IsCompact()
		if tall then
			local tileSize = 76
			local tile = UIKit.Tile(face, { Id = iconId, Size = tileSize, Evolved = c.Type == "Evolve" })
			tile.AnchorPoint = Vector2.new(0.5, 0)
			tile.Position = UDim2.new(0.5, 0, 0, 48)
			if animate then
				UIAnim.Pop(tile, 0.08 * index + 0.15, 0.4)
			end
			y = 48 + tileSize + 10
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
			y += TS(12) + 8
		else
			local tileSize = 58
			local tile = UIKit.Tile(face, { Id = iconId, Size = tileSize, Evolved = c.Type == "Evolve" })
			tile.Position = UDim2.fromOffset(12, 44)
			if animate then
				UIAnim.Pop(tile, 0.08 * index + 0.15, 0.4)
			end
			local x = 12 + tileSize + 10
			text(face, "H2", c.Name, {
				Position = UDim2.fromOffset(x, 44),
				Size = UDim2.new(1, -x - 8, 0, TS(22) + 6),
				TextTruncate = Enum.TextTruncate.AtEnd,
			})
			text(face, "Caption", UIKit.track(cardLevelText(c)), {
				Position = UDim2.fromOffset(x, 44 + TS(22) + 6),
				Size = UDim2.new(1, -x - 8, 0, TS(12) + 6),
				TextColor3 = edgeColor,
				TextTruncate = Enum.TextTruncate.AtEnd,
			})
			y = 44 + math.max(tileSize, TS(22) + TS(12) + 12) + 8
		end
		UIKit.Divider(face, 120, { AnchorPoint = Vector2.new(0.5, 0), Position = UDim2.new(0.5, 0, 0, y) })
		y += 12
		local keyRoom = (UserInputService.KeyboardEnabled and not UserInputService.TouchEnabled) and 34 or 12
		local hintH = c.Hint and (TS(13) * 2 + 8) or 0
		text(face, "Body", cardRichLines(c, "\n"), {
			Position = UDim2.fromOffset(14, y),
			Size = UDim2.new(1, -28, 1, -(y + keyRoom + hintH)),
			TextXAlignment = Enum.TextXAlignment.Center,
			TextYAlignment = Enum.TextYAlignment.Top,
			TextWrapped = true,
			RichText = true,
			TextColor3 = C.Text,
			LineHeight = 1.12,
			TextTruncate = Enum.TextTruncate.AtEnd,
		}, Theme.TextSize.Small + 1)
		if c.Hint then
			text(face, "Small", tostring(c.Hint), {
				AnchorPoint = Vector2.new(0, 1),
				Position = UDim2.new(0, 14, 1, -keyRoom),
				Size = UDim2.new(1, -28, 0, hintH),
				TextXAlignment = Enum.TextXAlignment.Center,
				TextYAlignment = Enum.TextYAlignment.Bottom,
				TextWrapped = true,
				TextColor3 = c.HintReady and P.gold_300 or C.TextMuted,
			}, 13)
		end
		if UserInputService.KeyboardEnabled and not UserInputService.TouchEnabled then
			local key = UIKit.Badge(face, tostring(index), "Dark", { AnchorPoint = Vector2.new(0.5, 1), Position = UDim2.new(0.5, 0, 1, -10) })
			key.Size = UDim2.fromOffset(22, 22)
			key.AutomaticSize = Enum.AutomaticSize.None
		end
	end

	if animate then
		-- cards fly in one after another: up from below, flipping from a tilt and growing
		-- from small, then a glow sweeps across; an evolution lands with a gold burst
		local delay = 0.08 * (index - 1)
		if ClientSettings.Reduced() then
			UIAnim.Pop(hit, delay, 0.85)
		else
			UIAnim.Pop(hit, delay, 0.35)
			hit.Rotation = (index % 2 == 0) and 12 or -12
			local home = face.Position
			face.Position = home + UDim2.fromOffset(0, 70)
			task.delay(delay, function()
				UIAnim.Tween(hit, 0.42, { Rotation = 0 }, Enum.EasingStyle.Back)
				UIAnim.Tween(face, 0.38, { Position = home }, Enum.EasingStyle.Quint)
			end)
			-- the sweep waits until the tilt has settled (no clipping inside rotated frames)
			cardSweep(face, delay + 0.46, legendary and P.gold_200 or P.ivory_100)
			if c.Type == "Evolve" then
				goldBurst(hit, delay + 0.18)
			end
		end
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
	local blockH = titleH + 12 + 26 + 16 + cardsH + 20 + 60
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
	levelUp.Actions.Position = UDim2.fromOffset(0, cardsY + cardsH + 20)
	levelUp.Actions.Size = UDim2.new(1, 0, 0, 60)
	local bw = math.clamp(math.floor((v.X - 2 * margin() - 16) / 2), 150, 240)
	levelUp.Reroll.Instance.Size = UDim2.fromOffset(bw, 60)
	levelUp.Skip.Instance.Size = UDim2.fromOffset(bw, 60)
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
	local rerolls, skips = tonumber(offer.Rerolls) or 0, tonumber(offer.Skips) or 0
	local rerollMax, skipMax = tonumber(offer.RerollsMax) or rerolls, tonumber(offer.SkipsMax) or skips
	local skipGold = tonumber(offer.SkipGold) or Config.LevelUp.SkipGold
	levelUp.Reroll.SetText(
		"REROLL",
		rerolls > 0 and string.format("%d left · 3 new cards", rerolls) or (rerollMax > 0 and "None left this run" or "Buy rerolls in Upgrades")
	)
	levelUp.Reroll.SetEnabled(rerolls > 0)
	levelUp.Skip.SetText(
		skips > 0 and string.format("SKIP  +%d GOLD", skipGold) or "SKIP",
		skips > 0 and string.format("%d left · no card", skips) or (skipMax > 0 and "None left this run" or "Buy skips in Upgrades")
	)
	levelUp.Skip.SetEnabled(skips > 0)
	levelUp.Title.Text = offer.Pending > 1 and string.format("LEVEL UP!  +%d", offer.Pending) or "LEVEL UP!"
	UIAnim.Punch(levelUp.Title, 0.35)
	offerSeconds = math.max(1, offer.Seconds)
	offerDeadline = os.clock() + offer.Seconds
	offerHint = Tutorial.LevelUpHint() or offerHint
	offerOpen = true
	show(levelUp.Overlay, "LevelUp", true)
	UIKit.FocusIfGamepad(first)
end

local function closeOffer()
	offerOpen = false
	offerHint = nil
	-- let the picked card's punch play first (unless a new offer opens meanwhile)
	local wait = 0.22 - (os.clock() - pickedAt)
	if wait > 0 and levelUp.Overlay.Visible then
		task.delay(wait, function()
			if not offerOpen then
				hide(levelUp.Overlay, "LevelUp")
			end
		end)
		return
	end
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

--[[
	Chest reward panel: a compact panel in the middle of the screen for everything a chest /
	shrine / altar pays (ChestOpened from an elite chest: level-ups + gold; ItemGained with
	Reward = true: an item). The server pauses the whole run meanwhile (RunManager
	.HoldReward, same freeze as a level-up). Several rewards in a row go into the same panel
	(the oldest rows drop out past MAX_ROWS) and extend it, but never past
	Config.Chests.RewardPauseMax from the first one. It closes after RewardPauseSeconds, or
	on a tap / click / gamepad A anywhere (remote RewardClose ends the pause sooner).
]]
local REWARD_ROW_H = 46
local MAX_ROWS = 4
local reward = { Open = false, Started = 0, Deadline = 0, Rows = 0, Order = 0, Sources = {} :: { [string]: boolean } }
local closeReward: (boolean) -> ()

local function layoutChest()
	local v = virtualSize()
	local w = math.min(340, v.X - 2 * margin())
	local rows = math.max(1, reward.Rows)
	local h = 14 + 34 + TS(12) + 10 + rows * (REWARD_ROW_H + 6) + 6 + 30
	chest.Panel.Size = UDim2.fromOffset(w, h)
	-- centred on the hero's spot, a touch high so the bottom HUD stays readable
	chest.Panel.Position = UDim2.fromOffset(math.floor(v.X / 2), math.floor(math.clamp(v.Y * 0.45, h / 2 + insets.Top + 8, v.Y - h / 2 - 8)))
end

local function buildChest()
	local overlay = new("Frame", { Name = "Reward", Size = UDim2.fromScale(1, 1), BackgroundTransparency = 1, Visible = false, ZIndex = Theme.Z.Chest }, root)
	overlay:SetAttribute("BackdropTransparency", 0.6)
	chest.Overlay = overlay
	-- the dimmer is the tap target (the run is paused, so it may take the whole screen)
	local dim = new("TextButton", { Name = "Dim", Text = "", AutoButtonColor = false, BackgroundColor3 = C.Backdrop, BackgroundTransparency = 0.6, BorderSizePixel = 0, ZIndex = 1 }, overlay)
	UIKit.Bleed(dim)
	dim.Activated:Connect(function()
		closeReward(true)
	end)
	local holder, face = UIKit.Surface(overlay, {
		Name = "Panel",
		Size = UDim2.fromOffset(340, 220),
		AnchorPoint = Vector2.new(0.5, 0.5),
		Radius = Theme.Radius.L,
		Edge = P.gold_400,
		EdgeTransparency = 0.15,
		Transparency = 0.04,
		ZIndex = 2,
	})
	chest.Panel = holder
	chest.Face = face
	-- burst of light behind the header when the panel opens / gets a new reward
	chest.Glow = new("Frame", { Name = "Glow", AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.new(0.5, 0, 0, 30), Size = UDim2.fromOffset(10, 10), BackgroundColor3 = P.gold_300, BackgroundTransparency = 1, ZIndex = 2 }, face)
	UIKit.corner(chest.Glow, 999)
	local header = new("Frame", { Name = "Header", BackgroundTransparency = 1, Position = UDim2.fromOffset(0, 12), Size = UDim2.new(1, 0, 0, 34), ZIndex = 3 }, face)
	UIKit.list(header, { FillDirection = Enum.FillDirection.Horizontal, HorizontalAlignment = Enum.HorizontalAlignment.Center, VerticalAlignment = Enum.VerticalAlignment.Center, Padding = UDim.new(0, 8) })
	chest.Icon = Icons.Draw(header, "chest", { Size = 30, LayoutOrder = 1 })
	chest.Title = text(header, "H1", "TREASURE!", { LayoutOrder = 2, Size = UDim2.fromOffset(0, 34), AutomaticSize = Enum.AutomaticSize.X, TextColor3 = P.gold_300, ZIndex = 3 }, 26)
	chest.Source = text(face, "Caption", "", { Position = UDim2.fromOffset(0, 46), Size = UDim2.new(1, 0, 0, TS(12) + 4), TextXAlignment = Enum.TextXAlignment.Center, TextColor3 = C.TextMuted, ZIndex = 3 })
	chest.Rewards = new("Frame", { Name = "Rewards", BackgroundTransparency = 1, Position = UDim2.fromOffset(16, 56 + TS(12)), Size = UDim2.new(1, -32, 0, MAX_ROWS * (REWARD_ROW_H + 6)), ZIndex = 3 }, face)
	UIKit.list(chest.Rewards, { Padding = UDim.new(0, 6), HorizontalAlignment = Enum.HorizontalAlignment.Center })
	-- footer: the time left as a draining bar + "TAP TO CONTINUE"
	chest.Timer = UIKit.Meter(face, { Gradient = ColorSequence.new(P.gold_500, P.gold_300), AnchorPoint = Vector2.new(0.5, 1), Position = UDim2.new(0.5, 0, 1, -26), Size = UDim2.fromOffset(160, 4) })
	chest.Hint = text(face, "Caption", UIKit.track("TAP TO CONTINUE"), { AnchorPoint = Vector2.new(0, 1), Position = UDim2.new(0, 0, 1, -6), Size = UDim2.new(1, 0, 0, TS(12) + 4), TextXAlignment = Enum.TextXAlignment.Center, TextColor3 = C.TextMuted, ZIndex = 3 })
	onRelayout(layoutChest)
	layoutChest()

	UserInputService.InputBegan:Connect(function(input, processed)
		if not reward.Open or processed then
			return
		end
		local k = input.KeyCode
		if k == Enum.KeyCode.ButtonA or k == Enum.KeyCode.Return or k == Enum.KeyCode.Space or k == Enum.KeyCode.E then
			-- E opens chests: only a fresh press long after the panel opened closes it
			if k ~= Enum.KeyCode.E or os.clock() - reward.Started > 0.6 then
				closeReward(true)
			end
		end
	end)
	RunService.RenderStepped:Connect(function()
		if not reward.Open then
			return
		end
		local now = os.clock()
		local total = math.max(0.1, reward.Deadline - reward.Started)
		chest.Timer.Set(math.clamp((reward.Deadline - now) / total, 0, 1))
		if now >= reward.Deadline then
			closeReward(false)
		end
	end)
end

closeReward = function(tapped: boolean)
	if not reward.Open then
		return
	end
	reward.Open = false
	hide(chest.Overlay, "Reward")
	if tapped then
		UIKit.Click()
		Remotes.Get("RewardClose"):FireServer()
	end
end

-- Light burst behind the header (new panel / new reward); bigger and gold for legendaries.
local function rewardBurst(big: boolean)
	if ClientSettings.Reduced() then
		return
	end
	local g = chest.Glow :: Frame
	g.Size = UDim2.fromOffset(10, 10)
	g.BackgroundColor3 = big and P.gold_200 or P.gold_300
	g.BackgroundTransparency = big and 0.1 or 0.3
	local size = big and 360 or 240
	TweenService:Create(g, TweenInfo.new(big and 0.7 or 0.5, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), { Size = UDim2.fromOffset(size, size), BackgroundTransparency = 1 }):Play()
end

-- Opens the panel (or adds to the one showing) and gives the reward time to be read.
local function openReward(source: string)
	local now = os.clock()
	local C2 = Config.Chests :: any
	if not reward.Open then
		reward.Open = true
		reward.Started = now
		reward.Rows = 0
		table.clear(reward.Sources)
		for _, c in ipairs(chest.Rewards:GetChildren()) do
			if c:IsA("GuiObject") then
				c:Destroy()
			end
		end
		show(chest.Overlay, "Reward", false)
		if not ClientSettings.Reduced() then
			-- the panel lands with a little tilt
			local panel = chest.Panel :: Frame
			panel.Rotation = -5
			UIAnim.Tween(panel, 0.35, { Rotation = 0 }, Enum.EasingStyle.Back)
		end
		UIAnim.Punch(chest.Icon, 0.45)
		UIAnim.Punch(chest.Title, 0.25)
	else
		UIAnim.Punch(chest.Panel, 0.05)
	end
	reward.Sources[source] = true
	local n = 0
	for _ in pairs(reward.Sources) do
		n += 1
	end
	chest.Source.Text = UIKit.track(n > 1 and "SEVERAL CHESTS" or string.upper(source))
	reward.Deadline = math.min(now + (C2.RewardPauseSeconds or 2.5), reward.Started + (C2.RewardPauseMax or 5))
end

-- One reward row: tile, name and what it gives. Old rows drop out past MAX_ROWS.
local function rewardRow(makeTile: (Frame) -> (), title: string, titleColor: Color3, detail: string, detailColor: Color3, legendary: boolean)
	reward.Order += 1
	local rows = {}
	for _, c in ipairs(chest.Rewards:GetChildren()) do
		if c:IsA("GuiObject") then
			table.insert(rows, c)
		end
	end
	table.sort(rows, function(a, b)
		return a.LayoutOrder < b.LayoutOrder
	end)
	-- phones keep the panel short: three rows
	local maxRows = UIKit.IsCompact() and MAX_ROWS - 1 or MAX_ROWS
	while #rows >= maxRows do
		local old = table.remove(rows, 1)
		if old then
			old:Destroy()
		end
	end
	reward.Rows = #rows + 1
	layoutChest()
	local row = new("Frame", { Name = "Row", BackgroundColor3 = P.slate_800, BackgroundTransparency = 0.35, Size = UDim2.new(1, 0, 0, REWARD_ROW_H), LayoutOrder = reward.Order, ClipsDescendants = true, ZIndex = 3 }, chest.Rewards)
	UIKit.corner(row, Theme.Radius.M)
	if legendary then
		UIKit.stroke(row, P.gold_400, 1.5, 0.1)
	end
	local tileHolder = new("Frame", { BackgroundTransparency = 1, Position = UDim2.fromOffset(5, 4), Size = UDim2.fromOffset(38, 38), ZIndex = 4 }, row)
	makeTile(tileHolder)
	text(row, "BodyStrong", title, { Position = UDim2.fromOffset(52, 4), Size = UDim2.new(1, -60, 0, 20), TextColor3 = titleColor, TextTruncate = Enum.TextTruncate.AtEnd, ZIndex = 4 }, Theme.TextSize.H3 - 1)
	text(row, "Small", detail, { Position = UDim2.fromOffset(52, 24), Size = UDim2.new(1, -60, 0, 18), TextColor3 = detailColor, TextTruncate = Enum.TextTruncate.AtEnd, ZIndex = 4 }, 13)
	UIAnim.Pop(row, 0, 0.6)
	if not ClientSettings.Reduced() then
		-- a quick flash and a shine across the new row
		local flash = new("Frame", { BackgroundColor3 = legendary and P.gold_200 or P.ivory_100, BackgroundTransparency = 0.55, BorderSizePixel = 0, Size = UDim2.fromScale(1, 1), ZIndex = 5 }, row)
		TweenService:Create(flash, TweenInfo.new(0.45), { BackgroundTransparency = 1 }):Play()
		local streak = new("Frame", { BackgroundColor3 = P.ivory_100, BackgroundTransparency = 0.6, BorderSizePixel = 0, AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(-0.2, 0.5), Size = UDim2.new(0, 26, 2, 0), Rotation = 20, ZIndex = 5 }, row)
		TweenService:Create(streak, TweenInfo.new(0.55, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), { Position = UDim2.fromScale(1.2, 0.5) }):Play()
	end
	rewardBurst(legendary)
end

-- Elite chest (remote ChestOpened): level-ups and gold.
function UIBuilder.ShowChest(data)
	if type(data) ~= "table" then
		return
	end
	openReward("Elite chest")
	local list = type(data.Rewards) == "table" and data.Rewards or {}
	for i, r in ipairs(list) do
		if type(r) == "table" then
			task.delay(0.12 * (i - 1), function()
				if reward.Open then
					rewardRow(function(holder)
						UIKit.Tile(holder, { Id = nameToId[tostring(r.Name)] or "", Size = 38 })
					end, tostring(r.Name), C.Text, string.upper(tostring(r.Text)), P.gold_300, false)
				end
			end)
		end
	end
	local gold = tonumber(data.Gold) or 0
	if gold > 0 then
		task.delay(0.12 * #list, function()
			if reward.Open then
				rewardRow(function(holder)
					Icons.Draw(holder, "coin", { Size = 34, AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.5) })
				end, "+" .. UIKit.formatNumber(gold) .. " gold", P.gold_200, "Added to your purse", C.TextMuted, false)
			end
		end)
	end
end

-- An item from a chest / shrine / altar (LootUI → ItemGained with Reward = true).
local function showItemReward(data)
	local def = ItemData.Items[tostring(data.Id)]
	if not def then
		return
	end
	local r = Theme.ItemRarity[def.Rarity] or Theme.ItemRarity.Common
	openReward(type(data.Source) == "string" and data.Source or "Chest")
	local n = tonumber(data.Count) or 1
	rewardRow(function(holder)
		LootUI.ItemTile(holder, def.Id, 38, n)
	end, def.Name .. (n > 1 and ("  x" .. n) or ""), r.Color, def.Text, C.Text, def.Rarity == "Legendary")
	if deps.Audio and deps.Audio.Play then
		pcall(deps.Audio.Play, "Item")
	end
end

------------------------------------------------------------------------------------------
-- Pause / settings menu (one modal: the in-run pause menu and the lobby SETTINGS)
------------------------------------------------------------------------------------------

local pause: { [string]: any } = {}

-- Total height of a list's children (offset sizes) plus the gaps between them.
local function stackHeight(frame: Instance, gap: number): number
	local h, n = 0, 0
	for _, ch in ipairs(frame:GetChildren()) do
		if ch:IsA("GuiObject") and ch.Visible then
			h += ch.Size.Y.Offset
			n += 1
		end
	end
	return h + math.max(0, n - 1) * gap
end

local function sectionCaption(parent: Instance, str: string, order: number)
	text(parent, "Caption", UIKit.track(str), { LayoutOrder = order, Size = UDim2.new(1, 0, 0, TS(12) + 8), TextColor3 = P.gold_300 })
end

-- One line under the options: where settings live and whether saving works right now.
local function settingsNote(): string
	local status = player:GetAttribute("SaveStatus")
	if status == "failing" or status == "memory" then
		return "Progress isn't being saved right now, so changes may not be kept."
	end
	return "Settings are saved with your progress."
end

local function buildPause()
	local m = UIKit.Modal(root, "Pause", 760, 470, Theme.Z.Pause)
	pause.Overlay = m.Overlay
	pause.Modal = m
	local content = m.Content
	fitModal(m, UIKit.list(content, { Padding = UDim.new(0, 10), HorizontalAlignment = Enum.HorizontalAlignment.Center }))
	pause.Title = text(content, "H1", "PAUSED", { LayoutOrder = 1, TextXAlignment = Enum.TextXAlignment.Center })
	UIKit.Divider(content, 220, { LayoutOrder = 2 })
	pause.Note = text(content, "Body", "", {
		LayoutOrder = 3,
		TextXAlignment = Enum.TextXAlignment.Center,
		TextWrapped = true,
		TextColor3 = C.TextMuted,
		Size = UDim2.new(1, 0, 0, TS(16) + 8),
	})

	-- options: sound sliders (left) and comfort / help switches (right); one column and a
	-- scroll on narrow or short screens
	local options = new("ScrollingFrame", {
		Name = "Options",
		LayoutOrder = 4,
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		Size = UDim2.new(1, 0, 0, 300),
		CanvasSize = UDim2.fromOffset(0, 300),
		ScrollBarThickness = 4,
		ScrollBarImageColor3 = P.gold_400,
		ScrollingDirection = Enum.ScrollingDirection.Y,
		ElasticBehavior = Enum.ElasticBehavior.Never,
	}, content)
	pause.Options = options
	local colA = new("Frame", { Name = "Sound", BackgroundTransparency = 1, Size = UDim2.fromOffset(300, 300) }, options)
	local colB = new("Frame", { Name = "Comfort", BackgroundTransparency = 1, Size = UDim2.fromOffset(300, 300) }, options)
	pause.ColA, pause.ColB = colA, colB
	UIKit.list(colA, { Padding = UDim.new(0, 6) })
	UIKit.list(colB, { Padding = UDim.new(0, 6) })

	sectionCaption(colA, "Sound", 1)
	pause.Music = UIKit.Slider(colA, "Music", "music", ClientSettings.Get("Music"), function(v)
		ClientSettings.Set("Music", v)
	end, function() end, { LayoutOrder = 2 })
	pause.Sfx = UIKit.Slider(colA, "Effects", "speaker", ClientSettings.Get("Sfx"), function(v)
		ClientSettings.Set("Sfx", v)
	end, function() end, { LayoutOrder = 3 })
	pause.Shake = UIKit.Slider(colA, "Screen shake", "area", ClientSettings.Get("Shake"), function(v)
		ClientSettings.Set("Shake", v)
	end, function() end, { LayoutOrder = 4 })

	sectionCaption(colB, "Comfort and help", 1)
	pause.Reduced = UIKit.Toggle(colB, "Reduced effects", "sparkle", "Fewer particles and trails, no screen flashes", ClientSettings.Get("ReducedEffects") == true, function(on)
		ClientSettings.Set("ReducedEffects", on)
	end, { LayoutOrder = 2 })
	pause.Numbers = UIKit.Toggle(colB, "Damage numbers", "sword", "Totals over enemies, kept short in big fights", ClientSettings.Get("DamageNumbers") == true, function(on)
		ClientSettings.Set("DamageNumbers", on)
	end, { LayoutOrder = 3 })
	pause.Tips = UIKit.Toggle(colB, "Show tips", "info", "Short hints while you play", ClientSettings.Get("Tips") ~= false, function(on)
		ClientSettings.Set("Tips", on)
	end, { LayoutOrder = 4 })
	pause.ReplayTips = UIKit.Button(colB, {
		Kind = "Outline",
		Title = "REPLAY TIPS",
		Icon = "cycle",
		IconSize = 18,
		Align = "Center",
		Size = UDim2.new(1, 0, 0, 46),
		LayoutOrder = 5,
		OnClick = function()
			Tutorial.Replay()
			ClientSettings.Set("Tips", true)
			pause.Tips.Set(true)
			UIBuilder.Toast("Tips are on again: they show as you play.", P.gold_300)
		end,
	})

	local row = new("Frame", { Name = "Buttons", BackgroundTransparency = 1, LayoutOrder = 5, Size = UDim2.new(1, 0, 0, Theme.Size.Button) }, content)
	UIKit.list(row, { FillDirection = Enum.FillDirection.Horizontal, HorizontalAlignment = Enum.HorizontalAlignment.Center, VerticalAlignment = Enum.VerticalAlignment.Center, Padding = UDim.new(0, 12) })
	pause.ItemsButton = UIKit.Button(row, {
		Kind = "Secondary",
		Title = "ITEMS",
		Icon = "chest",
		IconSize = 20,
		Align = "Center",
		Size = UDim2.fromOffset(200, Theme.Size.Button - 4),
		LayoutOrder = 1,
		OnClick = function()
			LootUI.OpenItems()
		end,
	})
	pause.Resume = UIKit.Button(row, {
		Kind = "Primary",
		Title = "RESUME",
		Icon = "play",
		IconSize = 20,
		Align = "Center",
		Size = UDim2.fromOffset(240, Theme.Size.Button),
		LayoutOrder = 2,
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
	local function layoutOptions()
		local v = virtualSize()
		local w = math.min(760, v.X - 32)
		m.Panel.Size = UDim2.new(UDim.new(0, w), m.Panel.Size.Y)
		local inner = w - 2 * Theme.Space.XL
		local twoCol = inner >= 600
		local gap = 28
		local side = 14 -- slider knobs reach past their track: keep them inside the scroll clip
		local colW = twoCol and math.floor((inner - gap - 2 * side) / 2) or (inner - 2 * side)
		local hA, hB = stackHeight(colA, 6), stackHeight(colB, 6)
		colA.Size = UDim2.fromOffset(colW, hA)
		colB.Size = UDim2.fromOffset(colW, hB)
		colA.Position = UDim2.fromOffset(side, 0)
		colB.Position = twoCol and UDim2.fromOffset(side + colW + gap, 0) or UDim2.fromOffset(side, hA + 18)
		local contentH = (twoCol and math.max(hA, hB) or (hA + 18 + hB)) + 6
		-- the note takes as many lines as its text needs (rough: ~0.5 em per character)
		local perLine = math.max(10, math.floor(inner / (TS(16) * 0.5)))
		local lines = math.clamp(math.ceil(#pause.Note.Text / perLine), 1, 3)
		pause.Note.Size = UDim2.new(1, 0, 0, lines * (TS(16) + 2) + 6)
		-- what the rest of the panel takes: title, divider, note, buttons, gaps, padding
		local fixed = (TS(30) + 6) + 10 + pause.Note.Size.Y.Offset + Theme.Size.Button + 4 * 10 + 2 * Theme.Space.XL + 8
		local room = math.max(160, v.Y - 24 - fixed)
		local h = math.min(contentH, room)
		options.Size = UDim2.new(1, 0, 0, h)
		options.CanvasSize = UDim2.fromOffset(0, contentH)
		options.ScrollBarThickness = contentH > h + 1 and 4 or 0
		local bw = math.clamp(math.floor((inner - 12) / 2), 150, 240)
		pause.ItemsButton.Instance.Size = UDim2.fromOffset(math.min(200, bw), Theme.Size.Button - 4)
		pause.Resume.Instance.Size = UDim2.fromOffset(bw, Theme.Size.Button)
	end
	pause.Layout = layoutOptions
	onRelayout(layoutOptions)
end

-- The same menu is the in-run pause menu and the lobby SETTINGS screen.
local pauseMode = "Pause" -- "Pause" | "Settings"

local function syncOptions()
	pause.Music.Set(ClientSettings.Get("Music"))
	pause.Sfx.Set(ClientSettings.Get("Sfx"))
	pause.Shake.Set(ClientSettings.Get("Shake"))
	pause.Reduced.Set(ClientSettings.Get("ReducedEffects") == true)
	pause.Numbers.Set(ClientSettings.Get("DamageNumbers") == true)
	pause.Tips.Set(ClientSettings.Get("Tips") ~= false)
	pause.Layout()
end

function UIBuilder.OpenPause()
	pauseMode = "Pause"
	pause.Title.Text = "PAUSED"
	pause.Resume.SetText("RESUME")
	pause.Resume.SetIcon("play")
	local participants = Remotes.State():GetAttribute("Participants") or 1
	local note = (participants <= 1 and Config.Run.SoloPauseFreezesRun) and "The run is paused." or "Group run: the swarm keeps coming while this menu is open!"
	local status = player:GetAttribute("SaveStatus")
	if status == "failing" or status == "memory" then
		note ..= "  Progress isn't being saved right now."
	end
	pause.Note.Text = note
	local n = LootUI.ItemCount()
	pause.ItemsButton.Instance.Visible = true
	pause.ItemsButton.SetText(n > 0 and string.format("ITEMS (%d)", n) or "ITEMS")
	syncOptions()
	show(pause.Overlay, "Pause", true)
	UIKit.FocusIfGamepad(pause.Resume.Instance)
	Remotes.Get("SetPause"):FireServer(true)
end

function UIBuilder.OpenSettings()
	pauseMode = "Settings"
	pause.Title.Text = "SETTINGS"
	pause.Resume.SetText("DONE")
	pause.Resume.SetIcon("check")
	pause.Note.Text = settingsNote()
	pause.ItemsButton.Instance.Visible = false
	syncOptions()
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
-- REPLAY: start the same mode again once this client is back in the lobby
local pendingReplay: { Mode: string, Until: number, Waited: boolean }? = nil

local function statTile(parent: Instance, icon: string, caption: string, order: number): (TextLabel, TextLabel)
	local f = UIKit.Panel(parent, { Name = caption, LayoutOrder = order, Size = UDim2.fromOffset(94, 104) }, true)
	Icons.Draw(f, icon, { Size = 26, AnchorPoint = Vector2.new(0.5, 0), Position = UDim2.new(0.5, 0, 0, 12), Color = if icon == "coin" or icon == "portal" then nil else P.gold_400, Back = P.slate_950 })
	local value = text(f, "Number", "0", {
		Name = "Value",
		Position = UDim2.fromOffset(4, 42),
		Size = UDim2.new(1, -8, 0, TS(24) + 4),
		TextXAlignment = Enum.TextXAlignment.Center,
		TextTruncate = Enum.TextTruncate.AtEnd,
	}, 24)
	local cap = text(f, "Caption", UIKit.track(caption), {
		Name = "Caption",
		AnchorPoint = Vector2.new(0, 1),
		Position = UDim2.new(0, 2, 1, -10),
		Size = UDim2.new(1, -4, 0, TS(12) + 2),
		TextXAlignment = Enum.TextXAlignment.Center,
		TextTruncate = Enum.TextTruncate.AtEnd,
	}, 11)
	return value, cap
end

-- Can REPLAY start a new run from here? (one run per server: not while others play on)
local function replayState(): (boolean, string)
	local phase = Remotes.State():GetAttribute("Phase") or "Lobby"
	if phase == "Lobby" or phase == "Countdown" then
		return true, ""
	end
	if phase == "Results" and player:GetAttribute("InRun") == true then
		return true, "" -- our own defeat screen: back to the lobby first, then start
	end
	return false, "Your team is still playing"
end

local function buildResults()
	local m = UIKit.Modal(root, "Results", 680, 460, Theme.Z.Results)
	results.Overlay = m.Overlay
	results.Modal = m
	local content = m.Content
	fitModal(m, UIKit.list(content, { Padding = UDim.new(0, 10), HorizontalAlignment = Enum.HorizontalAlignment.Center }))

	-- header: the hero's medallion, the verdict, where and how
	local head = new("Frame", { Name = "Head", BackgroundTransparency = 1, LayoutOrder = 1, Size = UDim2.new(1, 0, 0, 92) }, content)
	UIKit.list(head, { FillDirection = Enum.FillDirection.Horizontal, HorizontalAlignment = Enum.HorizontalAlignment.Center, VerticalAlignment = Enum.VerticalAlignment.Center, Padding = UDim.new(0, 16) })
	local medal = new("Frame", { Name = "Hero", BackgroundColor3 = C.PanelInset, BackgroundTransparency = 0.05, Size = UDim2.fromOffset(80, 80), LayoutOrder = 1 }, head)
	UIKit.corner(medal, 999)
	results.MedalStroke = UIKit.stroke(medal, P.gold_400, 2.5, 0.05)
	results.Medal = medal
	local titleCol = new("Frame", { Name = "TitleCol", BackgroundTransparency = 1, Size = UDim2.fromOffset(420, 92), LayoutOrder = 2 }, head)
	results.TitleCol = titleCol
	results.Title = text(titleCol, "Display", "VICTORY!", { Position = UDim2.fromOffset(0, 2), Size = UDim2.new(1, 0, 0, TS(44) + 6) }, 44)
	results.Arena = text(titleCol, "Label", "", { Position = UDim2.fromOffset(0, TS(44) + 10), Size = UDim2.new(1, 0, 0, TS(12) + 6), TextColor3 = C.TextMuted, TextTruncate = Enum.TextTruncate.AtEnd })
	results.Hero = text(titleCol, "BodyStrong", "", { Position = UDim2.fromOffset(0, TS(44) + TS(12) + 18), Size = UDim2.new(1, 0, 0, TS(15) + 4), TextColor3 = P.gold_200, TextTruncate = Enum.TextTruncate.AtEnd }, 15)
	UIKit.Divider(content, 260, { LayoutOrder = 2 })

	-- body (scrolls on short screens): numbers, build, rewards
	local body = new("ScrollingFrame", {
		Name = "Body",
		LayoutOrder = 3,
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		Size = UDim2.new(1, 0, 0, 300),
		ScrollBarThickness = 0,
		ScrollBarImageColor3 = P.gold_400,
		ScrollingDirection = Enum.ScrollingDirection.Y,
		ElasticBehavior = Enum.ElasticBehavior.Never,
	}, content)
	results.Body = body
	UIKit.list(body, { Padding = UDim.new(0, 10), HorizontalAlignment = Enum.HorizontalAlignment.Center })

	local grid = new("Frame", { Name = "Stats", BackgroundTransparency = 1, LayoutOrder = 1, Size = UDim2.new(1, 0, 0, 104) }, body)
	results.Grid = grid
	results.GridLayout = UIKit.list(grid, { FillDirection = Enum.FillDirection.Horizontal, HorizontalAlignment = Enum.HorizontalAlignment.Center, Padding = UDim.new(0, 8), Wraps = true })
	results.Time = statTile(grid, "clock", "Survived", 1)
	results.Kills = statTile(grid, "skull", "Defeated", 2)
	results.Boss, results.BossCaption = statTile(grid, "crown", "Queens", 3)
	results.Stages = statTile(grid, "portal", "Stages", 4)
	results.Gold = statTile(grid, "coin", "Gold", 5)
	results.Level = statTile(grid, "chevronsUp", "Level", 6)

	-- rewards first (new best, unlocks, achievements: what a short screen must not hide),
	-- then the build and the items
	results.Best = UIKit.Badge(body, "NEW BEST TIME!", "Gold", { LayoutOrder = 2, Visible = false })
	results.BuildHolder = new("Frame", { Name = "Build", BackgroundTransparency = 1, LayoutOrder = 6, Size = UDim2.new(1, 0, 0, 0) }, body)
	results.ItemsHolder = new("Frame", { Name = "ItemsHolder", BackgroundTransparency = 1, LayoutOrder = 7, Size = UDim2.new(1, 0, 0, 0), Visible = false }, body)
	-- progress: account XP and level, the run's curses, the daily score
	local prog = UIKit.Panel(body, { Name = "Progress", LayoutOrder = 5, Size = UDim2.new(1, 0, 0, 96) }, true)
	results.Progress = prog
	Icons.Draw(prog, "medal", { Size = 34, Position = UDim2.fromOffset(14, 12), Back = C.PanelInset })
	results.XPText = text(prog, "H3", "", { Name = "XP", Position = UDim2.fromOffset(60, 8), Size = UDim2.new(1, -74, 0, TS(18) + 6), RichText = true, TextTruncate = Enum.TextTruncate.AtEnd })
	results.XPMeter = UIKit.Meter(prog, {
		Gradient = ColorSequence.new(P.gold_500, P.gold_300),
		TextStyle = "Number",
		TextSize = 12,
		Position = UDim2.fromOffset(60, TS(18) + 18),
		Size = UDim2.new(1, -74, 0, 18),
	})
	results.ProgLines = text(prog, "Small", "", { Name = "Lines", Position = UDim2.fromOffset(14, TS(18) + 44), Size = UDim2.new(1, -28, 0, 0), RichText = true, TextWrapped = true, TextYAlignment = Enum.TextYAlignment.Top, TextXAlignment = Enum.TextXAlignment.Center })
	results.Unlocked = text(body, "BodyStrong", "", { LayoutOrder = 3, Size = UDim2.new(1, 0, 0, TS(16) + 6), TextXAlignment = Enum.TextXAlignment.Center, TextColor3 = P.gold_300, Visible = false })
	-- achievements unlocked this run (one line each: trophy, name, reward)
	results.Achievements = text(body, "Small", "", {
		Name = "Achievements",
		LayoutOrder = 4,
		Size = UDim2.new(1, 0, 0, 0),
		TextXAlignment = Enum.TextXAlignment.Center,
		TextYAlignment = Enum.TextYAlignment.Top,
		TextWrapped = true,
		RichText = true,
		TextColor3 = C.Text,
		Visible = false,
	})

	-- actions: REPLAY (same mode) and MAIN MENU
	local row = new("Frame", { Name = "Buttons", BackgroundTransparency = 1, LayoutOrder = 4, Size = UDim2.new(1, 0, 0, Theme.Size.Button) }, content)
	UIKit.list(row, { FillDirection = Enum.FillDirection.Horizontal, HorizontalAlignment = Enum.HorizontalAlignment.Center, VerticalAlignment = Enum.VerticalAlignment.Center, Padding = UDim.new(0, 12) })
	results.Replay = UIKit.Button(row, {
		Kind = "Primary",
		Title = "REPLAY",
		Icon = "cycle",
		IconSize = 22,
		Align = "Center",
		Size = UDim2.fromOffset(250, Theme.Size.Button),
		LayoutOrder = 1,
		OnClick = function()
			local ok = replayState()
			if not ok then
				return
			end
			pendingReplay = { Mode = results.Mode or "Solo", Until = os.clock() + 45, Waited = false }
			if not results.InLobby and player:GetAttribute("InRun") then
				Remotes.Get("ReturnToLobby"):FireServer()
			end
			hide(results.Overlay, "Results")
		end,
	})
	results.Button = UIKit.Button(row, {
		Kind = "Secondary",
		Title = "MAIN MENU",
		Icon = "castle",
		IconSize = 22,
		Align = "Center",
		Size = UDim2.fromOffset(250, Theme.Size.Button),
		LayoutOrder = 2,
		OnClick = function()
			pendingReplay = nil
			if not results.InLobby then
				Remotes.Get("ReturnToLobby"):FireServer()
			end
			hide(results.Overlay, "Results")
		end,
	})
	results.Timer = text(content, "Caption", "", { LayoutOrder = 5, TextXAlignment = Enum.TextXAlignment.Center })

	local function layoutResults()
		local v = virtualSize()
		local w = math.min(680, v.X - 32)
		m.Panel.Size = UDim2.new(UDim.new(0, w), m.Panel.Size.Y)
		local inner = w - 2 * Theme.Space.XL
		-- header height follows the text sizes (phones set text 20% bigger)
		local headH = math.max(84, TS(44) + 6 + TS(12) + 8 + TS(15) + 8)
		head.Size = UDim2.new(1, 0, 0, headH)
		results.TitleCol.Size = UDim2.fromOffset(math.max(160, math.min(440, inner - 96)), headH)
		-- six tiles in one row when they fit, otherwise two rows of three
		local tileW = 94
		local perRow = math.max(1, math.floor((inner + 8) / (tileW + 8)))
		local cols = perRow >= 6 and 6 or (perRow >= 3 and 3 or 2)
		local rows = math.ceil(6 / cols)
		grid.Size = UDim2.fromOffset(cols * (tileW + 8) - 8, rows * 104 + (rows - 1) * 8)
		local bw = math.clamp(math.floor((inner - 12) / 2), 140, 250)
		results.Replay.Instance.Size = UDim2.fromOffset(bw, Theme.Size.Button)
		results.Button.Instance.Size = UDim2.fromOffset(bw, Theme.Size.Button)
		-- the progress block grows with its lines (wrapped on narrow screens)
		local lineH = TS(Theme.TextSize.Small) + 4
		local perLine = inner < 520 and 2 or 1
		local nLines = (results.ProgLineCount or 0) * perLine
		results.ProgLines.Size = UDim2.new(1, -28, 0, nLines * lineH)
		results.Progress.Size = UDim2.new(1, 0, 0, TS(18) + 44 + nLines * lineH + (nLines > 0 and 10 or 0))
		local bodyH = stackHeight(body, 10)
		local fixed = headH + 10 + Theme.Size.Button + (TS(12) + 4) + 4 * 10 + 2 * Theme.Space.XL + 8
		local room = math.max(140, v.Y - 24 - fixed)
		local h = math.min(bodyH, room)
		body.Size = UDim2.new(1, 0, 0, h)
		body.CanvasSize = UDim2.fromOffset(0, bodyH)
		body.ScrollBarThickness = bodyH > h + 1 and 4 or 0
	end
	results.Layout = layoutResults
	onRelayout(layoutResults)
end

--[[
	The progress block: "+340 XP · Level 7 → 8" over the XP bar (account level), then one
	line each for the run's curses, the daily score and track rewards unlocked.
]]
local function fillProgress(data: any)
	local a = type(data.Account) == "table" and data.Account or nil
	local lines = {}
	local curses = type(data.Curses) == "table" and data.Curses or {}
	if #curses > 0 then
		local names = {}
		for _, id in ipairs(curses) do
			local def = CurseData.Curses[id]
			table.insert(names, def and def.Name or tostring(id))
		end
		table.insert(lines, string.format('<font color="%s"><b>CURSES</b></font>  %s  ·  <font color="%s">%s gold</font>', hex(P.crimson_300), table.concat(names, " · "), hex(P.gold_300), CurseData.GoldText(tonumber(data.CurseGold) or CurseData.GoldMult(curses))))
	end
	local d = type(data.Daily) == "table" and data.Daily or nil
	if d then
		if d.Scored then
			table.insert(lines, string.format('<font color="%s"><b>DAILY · SCORED</b></font>  %s%s', hex(P.gold_300), tostring(d.Text or ""), d.NewBest and string.format('  ·  <font color="%s">NEW DAILY BEST</font>', hex(P.moss_200)) or ""))
		else
			table.insert(lines, string.format('<font color="%s"><b>DAILY · PRACTICE</b></font>  %s  (not scored)', hex(P.gold_300), tostring(d.Text or "")))
		end
	end
	if a and type(a.Rewards) == "table" and #a.Rewards > 0 then
		local r = {}
		for _, name in ipairs(a.Rewards) do
			table.insert(r, tostring(name))
		end
		table.insert(lines, string.format('<font color="%s"><b>UNLOCKED</b></font>  %s  (wear it in TRACK)', hex(P.gold_300), table.concat(r, " · ")))
	end
	results.Progress.Visible = a ~= nil or #lines > 0
	if a then
		local from, to = tonumber(a.From) or 1, tonumber(a.To) or 1
		local levelText = from ~= to and string.format("Level %d → %d", from, to) or ("Level " .. to)
		results.XPText.Text = string.format('<font color="%s">+%s XP</font>  ·  %s', hex(P.gold_200), UIKit.formatNumber(tonumber(a.Gained) or 0), levelText)
		local need = tonumber(a.Need) or 0
		if need > 0 then
			results.XPMeter.Set((tonumber(a.Into) or 0) / need, string.format("%s / %s XP", UIKit.formatNumber(tonumber(a.Into) or 0), UIKit.formatNumber(need)))
		else
			results.XPMeter.Set(1, "MAX LEVEL")
		end
		results.XPMeter.Frame.Visible = true
	else
		results.XPText.Text = "Run progress"
		results.XPMeter.Frame.Visible = false
	end
	results.ProgLines.Text = table.concat(lines, "\n")
	results.ProgLineCount = #lines
end

-- Weapons (with levels / evolutions) and passives of the run, as tiles.
local function fillBuild(build: any)
	local holder = results.BuildHolder :: Frame
	for _, ch in ipairs(holder:GetChildren()) do
		ch:Destroy()
	end
	local weapons = type(build) == "table" and type(build.Weapons) == "table" and build.Weapons or {}
	local passives = type(build) == "table" and type(build.Passives) == "table" and build.Passives or {}
	if #weapons + #passives == 0 then
		holder.Size = UDim2.new(1, 0, 0, 0)
		holder.Visible = false
		return
	end
	holder.Visible = true
	local inner = results.Modal.Panel.Size.X.Offset - 2 * Theme.Space.XL
	text(holder, "Caption", UIKit.track("Build"), { Size = UDim2.new(1, 0, 0, TS(12) + 4), TextXAlignment = Enum.TextXAlignment.Center })
	local row = new("Frame", { Name = "Tiles", BackgroundTransparency = 1, Position = UDim2.fromOffset(0, TS(12) + 8) }, holder)
	UIKit.list(row, { FillDirection = Enum.FillDirection.Horizontal, HorizontalAlignment = Enum.HorizontalAlignment.Center, VerticalAlignment = Enum.VerticalAlignment.Center, Padding = UDim.new(0, 6), Wraps = true })
	local order, width = 0, 0
	for _, w in ipairs(weapons) do
		local def = WeaponData.Weapons[w.Id]
		if def then
			order += 1
			local level = tonumber(w.Level) or 1
			local iconId = (w.Evolved and def.Evolution) and def.Evolution.Id or w.Id
			UIKit.Tile(row, { Id = iconId, Size = 42, Level = level, Evolved = w.Evolved == true, Max = level >= WeaponData.MaxLevel }).LayoutOrder = order
			width += 48
		end
	end
	if #passives > 0 and order > 0 then
		order += 1
		new("Frame", { Name = "Gap", BackgroundColor3 = P.gold_600, BackgroundTransparency = 0.4, BorderSizePixel = 0, Size = UDim2.fromOffset(2, 30), LayoutOrder = order }, row)
		width += 8
	end
	for _, pv in ipairs(passives) do
		if PassiveData.Passives[pv.Id] then
			order += 1
			local level = tonumber(pv.Level) or 1
			UIKit.Tile(row, { Id = pv.Id, Size = 36, Level = level, Max = level >= PassiveData.MaxLevelOf(pv.Id) }).LayoutOrder = order
			width += 42
		end
	end
	local rows = math.max(1, math.ceil(width / math.max(1, inner)))
	row.Size = UDim2.new(1, 0, 0, rows * 48)
	holder.Size = UDim2.new(1, 0, 0, TS(12) + 8 + rows * 48)
end

local function onRunResult(data)
	closeOffer()
	hide(revive.Overlay, "Revive")
	hide(pause.Overlay, "Pause")
	Tutorial.Clear()
	pendingReplay = nil
	-- InLobby: the player left through a portal and is back at the menu already; the
	-- panel then sits over the lobby until closed (or its timer runs out)
	results.InLobby = data.InLobby == true
	results.Mode = type(data.Mode) == "string" and data.Mode or "Solo"
	-- portal returns before WinMinStages stages are a safe escape, not a win
	results.Title.Text = data.Won and "VICTORY!" or (data.Portal and "ESCAPED" or "DEFEATED")
	results.Title.TextColor3 = (data.Won or data.Portal) and P.gold_300 or P.crimson_300
	results.MedalStroke.Color = (data.Won or data.Portal) and P.gold_400 or P.crimson_400
	local cleared = tonumber(data.StagesCleared) or 0
	local where = (data.Won or data.Portal) and string.format("%d stage%s cleared", cleared, cleared == 1 and "" or "s") or string.format("Fell on stage %d", tonumber(data.Stage) or 1)
	results.Arena.Text = UIKit.track(where .. " · " .. tostring(data.Arena))
	-- the hero who played
	for _, ch in ipairs(results.Medal:GetChildren()) do
		if ch:IsA("Frame") then
			ch:Destroy()
		end
	end
	local heroId = type(data.CharacterId) == "string" and data.CharacterId or CharacterData.Default
	local heroDef = CharacterData.Characters[heroId]
	Icons.Character(results.Medal, heroId, { Size = 48, AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.5), Back = P.slate_950 })
	-- the worn portrait frame (level track)
	local framed = Cosmetics.Frame(results.Medal, profile and profile.Frame or "")
	results.MedalStroke.Transparency = framed and 1 or 0.05
	fillProgress(data)
	local damage = tonumber(data.Damage) or 0
	results.Hero.Text = string.format("%s  ·  %s damage dealt", heroDef and heroDef.Name or heroId, UIKit.formatNumber(math.floor(damage)))
	-- numbers
	results.Stages.Text = tostring(cleared)
	results.Time.Text = formatTime(data.Time)
	local queens = tonumber(data.BossKills) or 0
	if queens > 0 then
		results.Boss.Text = tostring(queens)
		results.BossCaption.Text = UIKit.track(queens == 1 and "Queen slain" or "Queens slain")
	elseif data.BossFight then
		results.Boss.Text = "-"
		results.BossCaption.Text = UIKit.track("Fell to her")
	else
		results.Boss.Text = "-"
		results.BossCaption.Text = UIKit.track("Not reached")
	end
	results.Best.Text = (data.NewBest and data.NewBestStage) and "NEW BEST TIME AND STAGE!" or (data.NewBestStage and "NEW BEST STAGE!" or "NEW BEST TIME!")
	data.NewBest = data.NewBest == true or data.NewBestStage == true
	results.Best.Visible = data.NewBest == true
	results.Unlocked.Visible = data.Unlocked ~= nil
	results.Unlocked.Text = data.Unlocked and ("Unlocked: " .. data.Unlocked .. " arena!") or ""
	local earned = type(data.Achievements) == "table" and data.Achievements or {}
	local lines = {}
	for _, a in ipairs(earned) do
		table.insert(lines, string.format('<font color="%s"><b>ACHIEVEMENT · %s</b></font>  %s', hex(P.gold_300), string.upper(tostring(a.Name)), tostring(a.Reward or "")))
	end
	results.Achievements.Visible = #lines > 0
	results.Achievements.Text = table.concat(lines, "\n")
	results.Achievements.Size = UDim2.new(1, 0, 0, #lines * (TS(Theme.TextSize.Small) + 6))
	-- the build, then the run's items (they are gone now; this is the last look at them)
	results.Layout()
	fillBuild(data.Build)
	for _, ch in ipairs(results.ItemsHolder:GetChildren()) do
		ch:Destroy()
	end
	local runItems = type(data.Items) == "table" and data.Items or {}
	results.ItemsHolder.Visible = #runItems > 0
	if #runItems > 0 then
		local w = results.Modal.Panel.Size.X.Offset - 2 * Theme.Space.XL
		local perRow = math.max(1, math.floor((w + 6) / 40))
		local rows = math.ceil(#runItems / perRow)
		results.ItemsHolder.Size = UDim2.new(1, 0, 0, TS(12) + 8 + rows * 40)
		text(results.ItemsHolder, "Caption", UIKit.track(string.format("Items found · %d", #runItems)), { Size = UDim2.new(1, 0, 0, TS(12) + 4), TextXAlignment = Enum.TextXAlignment.Center })
		LootUI.ItemRow(results.ItemsHolder, runItems, 34, { Position = UDim2.fromOffset(0, TS(12) + 8), Size = UDim2.new(1, 0, 0, rows * 40) })
	end
	results.Layout()
	resultsDeadline = os.clock() + (data.Seconds or 20)
	results.Body.CanvasPosition = Vector2.zero
	show(results.Overlay, "Results", true)
	UIKit.FocusIfGamepad(results.Replay.Instance)
	if data.Won and deps.Audio then
		pcall(deps.Audio.Play, "Victory")
	end
	-- title drops in, the medal flips round, the stat tiles land one after another and
	-- their numbers count up
	UIAnim.Pop(results.Title, 0.1, 1.6)
	if not ClientSettings.Reduced() then
		local medal = results.Medal :: GuiObject
		medal.Rotation = -160
		UIAnim.Pop(medal, 0.05, 0.3)
		task.delay(0.05, function()
			UIAnim.Tween(medal, 0.55, { Rotation = 0 }, Enum.EasingStyle.Back)
		end)
		for i, label in ipairs({ results.Stages, results.Time, results.Kills, results.Boss, results.Gold, results.Level }) do
			local tile = label and label.Parent
			if tile and tile:IsA("GuiObject") then
				UIAnim.Pop(tile, 0.2 + 0.06 * i, 0.55)
			end
		end
	end
	UIAnim.CountUp(results.Kills, data.Kills, "%d", 0.8, 0.4)
	UIAnim.CountUp(results.Gold, data.Gold, "%d", 0.8, 0.6)
	UIAnim.CountUp(results.Level, data.Level, "%d", 0.6, 0.8)
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
	if type(data.Settings) == "table" then
		ClientSettings.Apply(data.Settings)
		if pause.Music and not pause.Overlay.Visible then
			syncOptions()
		end
	end
	Tutorial.SetProfile(data)
	UIBuilder.RefreshProfileViews()
end

------------------------------------------------------------------------------------------
-- Save notice (never pretend saving works)
------------------------------------------------------------------------------------------

local saveNotice: { [string]: any } = {}

--[[
	A small crimson-edged pill when the server says progress isn't being written (player
	attribute SaveStatus: "failing" = a save failed after its retries, "memory" = no
	DataStores this session). Lobby: top centre, always while it lasts. In a run: a toast
	when it starts (the pause menu repeats it), so the HUD stays clear.
]]
local function buildSaveNotice()
	local holder, face = UIKit.Surface(root, { Name = "SaveNotice", Radius = 999, Transparency = 0.06, Edge = P.crimson_400, EdgeTransparency = 0.15, Shadow = true, Visible = false, ZIndex = Theme.Z.Toast, AnchorPoint = Vector2.new(0.5, 0), Size = UDim2.fromOffset(0, TS(15) + 20) })
	holder.AutomaticSize = Enum.AutomaticSize.X
	holder.Active = false
	face.AutomaticSize = Enum.AutomaticSize.X
	face.Size = UDim2.fromScale(0, 1)
	UIKit.padding(face, 0, 16, 0, 10)
	UIKit.list(face, { FillDirection = Enum.FillDirection.Horizontal, VerticalAlignment = Enum.VerticalAlignment.Center, Padding = UDim.new(0, 8) })
	Icons.Draw(face, "warning", { Size = 20, LayoutOrder = 1, Back = P.slate_900 })
	saveNotice.Text = text(face, "BodyStrong", "Progress isn't being saved right now", { LayoutOrder = 2, Size = UDim2.fromOffset(0, TS(15) + 20), AutomaticSize = Enum.AutomaticSize.X }, 15)
	saveNotice.Holder = holder
	saveNotice.Status = "ok"
	onRelayout(function()
		local v = virtualSize()
		if portrait then
			-- portrait menu: over the dais under the hero (the top holds the logo and stats,
			-- the bottom the buttons); it is not Active, taps go through
			holder.AnchorPoint = Vector2.new(0.5, 0.5)
			holder.Position = UDim2.fromOffset(v.X / 2, v.Y * 0.555)
		else
			holder.AnchorPoint = Vector2.new(0.5, 0)
			holder.Position = UDim2.fromOffset(v.X / 2, math.max(insets.Top, 0) + 10)
		end
	end)
end

updateSaveNotice = function(inRun: boolean)
	local status = tostring(player:GetAttribute("SaveStatus") or "ok")
	local bad = status == "failing" or status == "memory"
	if status ~= saveNotice.Status then
		local was = saveNotice.Status
		saveNotice.Status = status
		saveNotice.Text.Text = status == "memory" and "Progress isn't being saved in this session" or "Progress isn't being saved right now"
		if bad and inRun then
			UIBuilder.Toast(saveNotice.Text.Text .. ". We'll keep trying.", P.crimson_300)
		elseif not bad and (was == "failing") then
			UIBuilder.Toast("Saving works again. Your progress is safe.", P.moss_300)
		end
	end
	local shown = bad and not inRun
	if saveNotice.Holder.Visible ~= shown then
		saveNotice.Holder.Visible = shown
		if shown then
			UIAnim.Pop(saveNotice.Holder, 0, 0.8)
		end
	end
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
		levelUp.Sub.Text = string.format("%s  ·  auto-pick in %ds", offerHint or "Choose an upgrade", math.ceil(left))
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
		local left = math.max(0, math.ceil(resultsDeadline - os.clock()))
		local canReplay, why = replayState()
		if results.Replay.IsEnabled() ~= canReplay then
			results.Replay.SetEnabled(canReplay)
			results.Replay.SetText(canReplay and "REPLAY" or string.upper(why))
		end
		if results.InLobby then
			results.Timer.Text = UIKit.track("Closes in " .. left .. "s")
			if left <= 0 or inRun then
				hide(results.Overlay, "Results")
				results.InLobby = false
			end
		else
			results.Timer.Text = UIKit.track("Back to the lobby in " .. left .. "s")
			if not inRun then
				hide(results.Overlay, "Results")
			end
		end
	end
	-- REPLAY: once back in the lobby, start the same mode (a countdown is joined)
	if pendingReplay and not inRun then
		local phase = state:GetAttribute("Phase") or "Lobby"
		local pr = pendingReplay :: { Mode: string, Until: number, Waited: boolean }
		if phase == "Lobby" or phase == "Countdown" then
			pendingReplay = nil
			Remotes.Get("StartRun"):FireServer(pr.Mode)
		elseif os.clock() > pr.Until or (phase == "Running" and pr.Waited) then
			pendingReplay = nil
			UIBuilder.Toast("A run is in progress. Start a new one when it ends.", P.gold_300)
		elseif not pr.Waited then
			pr.Waited = true -- the last run is still closing (others on its results screen)
		end
	end
	StageUI.Update(dt, state, inRun)
	LootUI.Update(dt, inRun)
	TeamUI.Update(dt, state, inRun)
	local modalOpen = levelUp.Overlay.Visible or pause.Overlay.Visible or revive.Overlay.Visible or results.Overlay.Visible
	if not modalOpen then
		for name in pairs(blocking) do
			if name ~= "Lobby" then
				modalOpen = true
				break
			end
		end
	end
	Tutorial.Update(dt, state, inRun, modalOpen)
	updateSaveNotice(inRun)
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
	LootUI.OnReward = showItemReward
	buildPause()
	buildRevive()
	buildResults()
	buildSaveNotice()
	StageUI.Build(root, {
		Show = show,
		Hide = hide,
		FitModal = fitModal,
		OnRelayout = onRelayout,
		VirtualSize = virtualSize,
		IsPortrait = function(): boolean
			return portrait
		end,
		Scale = function(): number
			return uiScale.Scale
		end,
		-- top-left of the safe-area GUI on the screen (world → GUI projection)
		GuiOffset = function(): Vector2
			return gui.AbsolutePosition
		end,
	})
	LootUI.Build(root, {
		Show = show,
		Hide = hide,
		OnRelayout = onRelayout,
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
		GuiOffset = function(): Vector2
			return gui.AbsolutePosition
		end,
	})
	TeamUI.Build(root, {
		OnRelayout = onRelayout,
		VirtualSize = virtualSize,
		IsPortrait = function(): boolean
			return portrait
		end,
		Scale = function(): number
			return uiScale.Scale
		end,
		GuiOffset = function(): Vector2
			return gui.AbsolutePosition
		end,
	})
	Tutorial.Build(root, {
		OnRelayout = onRelayout,
		VirtualSize = virtualSize,
		IsPortrait = function(): boolean
			return portrait
		end,
		Audio = deps.Audio,
	})
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
	Remotes.Get("AchievementUnlocked").OnClientEvent:Connect(function(info)
		if type(info) ~= "table" then
			return
		end
		local reward = (info.Reward and info.Reward ~= "") and (" · " .. tostring(info.Reward)) or ""
		UIBuilder.Toast("Achievement: " .. tostring(info.Name) .. reward, P.gold_300)
		if deps.Audio and deps.Audio.Play then
			pcall(deps.Audio.Play, "LevelUp")
		end
	end)
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

	-- Leaving a run clears the HUD inventory and every in-run overlay / sound; entering
	-- one starts a clean HUD.
	player:GetAttributeChangedSignal("InRun"):Connect(function()
		if not player:GetAttribute("InRun") then
			Hud.SetInventory(nil)
			closeOffer()
			hide(revive.Overlay, "Revive")
			closeReward(false)
			Tutorial.Clear()
			if deps.Audio and deps.Audio.StopEffects then
				deps.Audio.StopEffects()
			end
		else
			Hud.Reset()
		end
	end)

	-- settings → the systems that read them right away
	local function applyVolumes()
		if deps.Audio then
			deps.Audio.SetVolumes(ClientSettings.Get("Music"), ClientSettings.Get("Sfx"))
		end
	end
	ClientSettings.OnChanged(function(key)
		if key == "Music" or key == "Sfx" then
			applyVolumes()
		end
	end)
	applyVolumes()

	RunService.RenderStepped:Connect(updateFrame)
	Remotes.Get("RequestProfile"):FireServer()
end

-- Crimson screen-edge pulse when the local player is hurt (ClientMain → VFX "hurt").
function UIBuilder.HurtFlash()
	Hud.Hurt()
end

return UIBuilder
