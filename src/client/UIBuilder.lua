--[[
	UIBuilder.lua
	Hosts every screen and builds the in-run ones: HUD (Hud.lua), the stage loop's arrow,
	charge ring, portal choice and travel fade (StageUI.lua), run items and map loot (item
	strip, item popups, chest / shrine prompts, items list: LootUI.lua), the minimap (MiniMap.lua), toasts and banners, level-up
	cards, chest reward, pause / settings menu, revive offer and the results screen. It also hosts the lobby menu (LobbyScreen), the hero on the dais (Showcase) and
	the Studio dev tools (DevPanel). Components come from UIKit, icons from Icons, tokens
	from Theme.

	Scaling: all UI lives under one "Root" frame with a UIScale. The design is done in
	"reference pixels" (1280x720 landscape, 720x1280 portrait; phones in landscape use the
	smaller Config.UI.PhoneReferenceSize so text and buttons stay readable); Root is sized
	1/scale so the scaled result always fills the screen exactly. The ScreenGui uses the
	device safe area (notches, rounded corners, home bar) without clipping to it; modal
	dimmers and backdrops still cover the whole screen (UIKit.Bleed, measured against the
	full-screen SwarmFx ScreenGui because AbsolutePosition is reported in Roblox's inset
	space). Full-screen modals hide the HUD while open (Hud.SetCovered). The Roblox topbar
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
local IdleFx = require(script.Parent.IdleFx)
local AssetPreload = require(script.Parent.AssetPreload)
local ArtImage = require(script.Parent.ArtImage)
local UIKit = require(script.Parent.UIKit)
local Icons = require(script.Parent.Icons)
local Hud = require(script.Parent.Hud)
local StageUI = require(script.Parent.StageUI)
local LootUI = require(script.Parent.LootUI)
local LobbyScreen = require(script.Parent.LobbyScreen)
local DevPanel = require(script.Parent.DevPanel)
local DevInbox = require(script.Parent.DevInbox)
local BugReportUI = require(script.Parent.BugReportUI)
local TravelOverlay = require(script.Parent.TravelOverlay)
local Showcase = require(script.Parent.Showcase)
local ClientSettings = require(script.Parent.ClientSettings)
local ClientPerformance = require(script.Parent.ClientPerformance)
local TeamUI = require(script.Parent.TeamUI)
local MiniMap = require(script.Parent.MiniMap)
local Tutorial = require(script.Parent.Tutorial)
local RunIntro = require(script.Parent.RunIntro)
local UIState = require(script.Parent.UIState)
local Cosmetics = require(script.Parent.Cosmetics)
local CurseData = require(Shared:WaitForChild("CurseData"))
local ItemData = require(Shared:WaitForChild("ItemData"))
local IconData = require(Shared:WaitForChild("IconData"))

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

-- Reduce flashes (or Reduced effects, or the performance governor): no bright fills that
-- pop over the UI for a frame or two (pick flash, reel landing flash and burst).
local function noFlashes(): boolean
	return ClientSettings.Flashes() or ClientPerformance.Reduced()
end

--[[
	Overlay ownership goes through UIState (docs/overhaul/UI_STATE_CONTRACT.md): every
	panel opened with show() is a primary; only the highest-priority open one is visible,
	the others are suspended (hidden, not resolved) until it closes. The shown owner decides
	whether the thumbstick works (Blocks) and whether the HUD hides under it (Covers).
	`blocking` here only holds the non-panel blocks (the lobby menu).
]]
local function refreshControls()
	if deps.MobileControls then
		deps.MobileControls.SetEnabled(next(blocking) == nil and not UIState.Blocking())
	end
end

local function setBlocking(name: string, on: boolean)
	if on then
		blocking[name] = true
	else
		blocking[name] = nil
	end
	refreshControls()
end

-- Modals that cover the HUD while they own the screen (Hud.SetCovered hides it under them).
local COVERS_HUD = { LevelUp = true, Reward = true, Pause = true, Revive = true, Results = true, Portal = true, Items = true, BugReport = true }
-- Sub-panels opened from another panel: the parent stays on screen under them.
local STACKS = { Items = true, BugReport = true }
local overlays: { [string]: GuiObject } = {} -- name -> its overlay (UIState.Audit, setCovering)
local function applyOwner()
	local covered = UIState.Covered()
	Hud.SetCovered(covered)
	MiniMap.SetCovered(covered)
	LootUI.SetCovered(covered)
	refreshControls()
end
UIState.OnOwnerChanged(function()
	applyOwner()
	LootUI.Release() -- a panel took input: a chest / shrine hold in progress lets go
end)

-- Makes an overlay visible: the dimmer fades in and the panel pops up with a little
-- overshoot (only when it was hidden: a re-show keeps it still).
local function revealOverlay(overlay: GuiObject)
	local wasVisible = overlay.Visible and not overlay:GetAttribute("Hiding")
	overlay:SetAttribute("AnimToken", (tonumber(overlay:GetAttribute("AnimToken")) or 0) + 1)
	overlay:SetAttribute("Hiding", nil)
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
end

local function primaryHandle(overlay: GuiObject, name: string, blocks: boolean, covers: boolean): UIState.Handle
	return {
		Blocks = blocks,
		Covers = covers,
		Stacks = STACKS[name] == true,
		Show = function()
			revealOverlay(overlay)
		end,
		Hide = function()
			-- suspended under a higher panel: out of sight at once, nothing resolved
			overlay:SetAttribute("AnimToken", (tonumber(overlay:GetAttribute("AnimToken")) or 0) + 1)
			overlay:SetAttribute("Hiding", nil)
			overlay.Visible = false
		end,
	}
end

-- Opening a panel: it becomes an open primary in UIState and shows when it owns the
-- screen. The chest reward overlay starts as automatic feedback (the mini reel, never an
-- input owner); setCovering("Reward", true) turns its full reveal into a primary.
-- `covers` overrides COVERS_HUD for this opening (the run menu drawer leaves the HUD visible).
local function show(overlay: GuiObject, name: string, blocks: boolean, covers: boolean?)
	overlays[name] = overlay
	if name == "Reward" then
		revealOverlay(overlay)
		UIState.SetFeedback(true)
		return
	end
	if covers == nil then
		covers = COVERS_HUD[name] == true
	end
	UIState.Open(name, primaryHandle(overlay, name, blocks, covers == true))
	applyOwner() -- a re-show may change what the owner blocks
end

-- The reward reel switching between its mini (feedback, the run goes on) and full (a
-- primary that covers the HUD) presentation.
local function setCovering(name: string, on: boolean)
	local overlay = overlays[name]
	if not overlay then
		return
	end
	if on then
		UIState.SetFeedback(false)
		UIState.Open(name, primaryHandle(overlay, name, false, true))
	else
		UIState.Close(name)
		UIState.SetFeedback(overlay.Visible)
	end
	applyOwner()
end

-- Closing: the panel shrinks away, then the overlay hides (unless reopened meanwhile).
-- Safe to call every frame: a close that is already animating is left to finish
-- (restarting it each frame used to keep the results screen on forever).
local function hide(overlay: GuiObject, name: string)
	if name == "Reward" then
		UIState.SetFeedback(false)
	end
	UIState.Close(name)
	applyOwner()
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

-- Where the safe-area ScreenGui really sits on the screen. AbsolutePosition is reported in
-- Roblox's "inset space" (y = 0 at the bottom of the top bar, so a full-screen
-- IgnoreGuiInset gui reads y = -58 on a phone); fxGui covers the whole screen, so the
-- difference of the two readings is the true offset whatever the space.
local function guiScreenPos(): Vector2
	return gui.AbsolutePosition - fxGui.AbsolutePosition
end

-- Room the Roblox topbar buttons take, in root (virtual) pixels.
local function computeInsets()
	local s = math.max(0.01, uiScale.Scale)
	local pos, size = guiScreenPos(), gui.AbsoluteSize
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
	local s
	if UIKit.IsCompact() and not portrait then
		-- phones in landscape: a smaller design space (PhoneReferenceSize) so text and
		-- buttons come out readable / tappable; layouts reflow into it
		local phone = Config.UI.PhoneReferenceSize
		s = math.min(size.X / phone.X, size.Y / phone.Y, Config.UI.MaxScale)
	else
		s = math.clamp(math.min(size.X / refX, size.Y / refY), Config.UI.MinScale, Config.UI.MaxScale)
	end
	uiScale.Scale = s
	root.Size = UDim2.fromScale(1 / s, 1 / s)
	computeInsets()
	-- full-bleed layers: the whole screen in root coordinates. fxGui is the whole screen;
	-- the layer also reaches past it by the total inset on every side (harmless off
	-- screen), so it still covers notches if a reading is off.
	local full = fxGui.AbsoluteSize
	local viewport = workspace.CurrentCamera.ViewportSize
	full = Vector2.new(math.max(full.X, viewport.X, size.X), math.max(full.Y, viewport.Y, size.Y))
	local extra = (full - size) + Vector2.new(8, 8)
	UIKit.SetBleed((-guiScreenPos() - extra) / s, (full + extra * 2) / s)
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

-- Width of a centred modal that reaches the top of the screen (pause, results): in
-- landscape it stays clear of the Roblox buttons at the top left (insets.Left).
local function tallModalWidth(maxW: number): number
	local v = virtualSize()
	local w = math.min(maxW, v.X - 32)
	if not portrait and insets.Left > 0 then
		w = math.min(w, math.max(480, v.X - 2 * (insets.Left + 8)))
	end
	return w
end

------------------------------------------------------------------------------------------
-- Toasts and banners
------------------------------------------------------------------------------------------

local toastList: Frame
local placeToasts: () -> () -- the notice lane's spot (below)

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
	onRelayout(function()
		local v = virtualSize()
		toastList.Size = UDim2.fromOffset(math.min(560, v.X - 32), 260)
		-- phones: two notices at most, so the stack never reaches the hero
		UIState.SetMaxNotices(UIKit.IsCompact() and 2 or 3)
		placeToasts()
	end)
end

--[[
	The notice lane's slot (UIState): under the top HUD, below any reserved top-centre bar
	(the caravan defence bar) and, while a centre headline shows, below the headline.
	Called every frame; only writes when the spot changes.
]]
function placeToasts()
	if not toastList or not root then
		return
	end
	local v = virtualSize()
	local y
	if player:GetAttribute("InRun") == true then
		y = Hud.TopBottom() + 6
		for _, g in ipairs(Hud.CentreBars()) do
			if g.Visible and g.Parent then
				local gh = g.Size.Y.Offset
				local bottom = g.Position.Y.Offset + (1 - g.AnchorPoint.Y) * gh
				y = math.max(y, bottom + 6)
			end
		end
		local hb = Hud.HeadlineBottom()
		if hb then
			y = math.max(y, hb + 6)
		end
	else
		y = insets.Top + 70
	end
	local at = UDim2.fromOffset(math.floor(v.X / 2), math.floor(y))
	if toastList.Position ~= at then
		toastList.Position = at
	end
end

local toastOrder = 0

-- Icon for a toast by what it is about (portal / surge / boss / loot ...); nil = a dot.
local TOAST_ICONS = {
	{ "portal", "portal" },
	{ "surge", "skull" },
	{ "swarm", "skull" },
	{ "horde", "skull" },
	{ "boss", "crown" },
	{ "queen", "crown" },
	{ "achievement", "ach_Badge" },
	{ "chest", "reward_ChestLarge" },
	{ "shrine", "shrine" },
	{ "curse", "curse" },
	{ "revive", "heart" },
	{ "gold", "coin" },
}
local function toastIcon(str: string): string?
	local low = string.lower(str)
	for _, pair in ipairs(TOAST_ICONS) do
		if string.find(low, pair[1], 1, true) then
			return pair[2]
		end
	end
	return nil
end

--[[
	A client message. Client callers are answers to the player's own action ("Not enough
	gold yet", a bug report sent): class "Player", shown even under a panel. `big` sends it
	to the centre headline lane instead. Server messages come through UIState.FromServer.
]]
function UIBuilder.Toast(str: string, color: Color3?, big: boolean?)
	if big then
		UIState.Headline({ Id = UIState.Classify(str, true).Id, Title = str, Sub = "", Color = color, Class = "Info" })
		return
	end
	local low = string.lower(str)
	-- repeated "X upgraded to level N" answers (quick taps on upgrade rows) share one id, so
	-- they fold into one pill (latest text, "x2") instead of stacking
	local id = string.find(low, "upgraded to level", 1, true) and "upgraded" or ("text:" .. low)
	UIState.Notice({ Id = id, Text = str, Color = color, Class = "Player", Seconds = Config.UI.ToastSeconds })
end

-- UIState's notice renderer: one gold-rimmed pill in the toast list; UIState says when it
-- goes (Dismiss) and when a repeat folds into it (Set: "x2").
local function renderNotice(item: UIState.Notice): UIState.NoticeHandle
	local str, color = item.Text, item.Color :: Color3?
	toastOrder += 1
	placeToasts()
	local holder, face = UIKit.Surface(toastList, {
		Name = "Toast",
		Size = UDim2.fromOffset(0, TS(Theme.Type.Body.Size) + 22),
		Radius = 999,
		Transparency = 0.12,
		-- the thin gold rim of the HUD pills
		Edge = P.gold_500,
		EdgeTransparency = 0.35,
		LayoutOrder = toastOrder,
	})
	holder.AutomaticSize = Enum.AutomaticSize.X
	face.AutomaticSize = Enum.AutomaticSize.X
	face.Size = UDim2.fromScale(0, 1)
	UIKit.padding(face, 0, 18, 0, 14)
	UIKit.list(face, { FillDirection = Enum.FillDirection.Horizontal, VerticalAlignment = Enum.VerticalAlignment.Center, Padding = UDim.new(0, 10) })
	local iconName = toastIcon(str)
	local dotFrame
	if iconName then
		dotFrame = new("Frame", { BackgroundTransparency = 1, Size = UDim2.fromOffset(22, 22), LayoutOrder = 1 }, face)
		Icons.Draw(dotFrame, iconName, { Size = 22, Back = P.slate_900 })
		if not (ClientSettings.Reduced() or ClientPerformance.Reduced()) then
			-- the icon pops with a little spin
			dotFrame.Rotation = -25
			UIAnim.Tween(dotFrame, 0.4, { Rotation = 0 }, Enum.EasingStyle.Back)
		end
		UIAnim.Pop(dotFrame, 0.05, 0.2)
	else
		dotFrame = new("Frame", { BackgroundColor3 = accentOf(color), Size = UDim2.fromOffset(8, 8), LayoutOrder = 1 }, face)
		UIKit.corner(dotFrame, 999)
	end
	local l = UIKit.Role(face, "Body", str, {
		LayoutOrder = 2,
		Size = UDim2.fromOffset(0, TS(Theme.Type.Body.Size) + 22),
		TextTruncate = Enum.TextTruncate.AtEnd,
		AutomaticSize = Enum.AutomaticSize.X,
		TextColor3 = C.Text,
	})
	new("UISizeConstraint", { MaxSize = Vector2.new(math.max(120, virtualSize().X - 2 * margin() - 72), TS(Theme.Type.Body.Size) + 22) }, l)
	UIAnim.Pop(holder, 0, 0.5)
	if not (ClientSettings.Reduced() or ClientPerformance.Reduced()) then
		-- a colour flash fades off the pill as it pops in
		local glow = new("Frame", { Name = "Glow", BackgroundColor3 = accentOf(color), BackgroundTransparency = 0.5, BorderSizePixel = 0, Size = UDim2.fromScale(1, 1), ZIndex = 3 }, holder)
		UIKit.corner(glow, 999)
		UIAnim.Tween(glow, 0.6, { BackgroundTransparency = 1 }).Completed:Once(function()
			glow:Destroy()
		end)
	end
	local gone = false
	return {
		Set = function(newText: string, count: number)
			if gone then
				return
			end
			l.Text = count > 1 and string.format("%s  x%d", newText, count) or newText
			UIAnim.Punch(holder, 0.08)
		end,
		Dismiss = function()
			if gone then
				return
			end
			gone = true
			if holder.Parent then
				UIAnim.PopOut(holder, function()
					holder:Destroy()
				end)
			end
		end,
	}
end

------------------------------------------------------------------------------------------
-- Level-up screen
------------------------------------------------------------------------------------------

local levelUp: { [string]: any } = {}
local offerDeadline = 0
local offerOpen = false
local lastOffer: { [string]: any }? = nil
local offerHint: string? = nil -- first-run explanation under the title (Tutorial)
-- Level-up helpers live in one table (UIBuilder is close to Luau's 200-local limit).
local Choice: { [string]: any } = {
	Prompts = require(script.Parent.InputPrompts), -- device-aware "how to choose" (COPY)
	FrozenLeft = nil :: number?, -- seconds shown while the server clock is stopped (ChoiceTimerPaused)
}

-- Upgrade choice sounds (Config.Sounds, docs/overhaul/AUDIO_MIX.md).
function Choice.choiceSound(name: string)
	if deps.Audio and deps.Audio.Play then
		pcall(deps.Audio.Play, name)
	end
end

--[[
	Seconds until the server auto-picks: the player attribute ChoiceProtectedUntil
	(workspace:GetServerTimeNow() time, docs/overhaul/CHOICE_STATE.md), frozen while
	ChoiceTimerPaused (solo run menu, stage travel). Without the attribute (older server,
	offline preview) the offer's own Seconds count down locally.
]]
function Choice.choiceSecondsLeft(): number
	local untilAt = player:GetAttribute("ChoiceProtectedUntil")
	local left
	if type(untilAt) == "number" then
		local ok, now = pcall(function()
			return workspace:GetServerTimeNow()
		end)
		left = ok and (untilAt - now) or (offerDeadline - os.clock())
	else
		left = offerDeadline - os.clock()
	end
	left = math.max(0, left)
	if player:GetAttribute("ChoiceTimerPaused") == true then
		Choice.FrozenLeft = Choice.FrozenLeft or left
		return Choice.FrozenLeft :: number
	end
	Choice.FrozenLeft = nil
	return left
end

-- A live group choice (duo / trio): the world keeps running for the team.
function Choice.choiceGroup(): boolean
	local attr = player:GetAttribute("ChoiceGroup")
	if attr ~= nil then
		return attr == true
	end
	return lastOffer ~= nil and lastOffer.Group == true
end

-- The countdown pill: "AUTO-PICK IN 24s"; every round left in the panel is auto-picked at
-- zero ("AUTO-PICK ALL 3 IN 24s"); "TIMER PAUSED" while the clock is stopped; group runs
-- say the team keeps playing.
function Choice.choicePillText(left: number, narrow: boolean): string
	local secs = math.ceil(left)
	local rounds = lastOffer and tonumber(lastOffer.BatchRemaining) or 1
	local s
	if player:GetAttribute("ChoiceTimerPaused") == true then
		s = string.format("TIMER PAUSED · %ds", secs)
	elseif rounds and rounds > 1 and not narrow then
		s = string.format("AUTO-PICK ALL %d IN %ds", rounds, secs)
	else
		s = string.format("AUTO-PICK IN %ds", secs)
	end
	if Choice.choiceGroup() then
		s = narrow and string.format("%ds · TEAM KEEPS PLAYING", secs) or (s .. " · TEAM KEEPS PLAYING")
	end
	return s
end

--[[
	Offer flow: the offer's icon pictures are staged first (AssetPreload, at most Stage
	seconds; the background preload has usually done it already) so art and text appear
	together, then the cards come in one after another (entrance under ~0.45 s).
	Safe input: a card, REROLL or SKIP only counts once the cards have been on screen for
	Arm seconds AND the press itself started after that, so a key, gamepad button or touch
	held from gameplay never confirms a card. Fx holds the cards' idle tweens and
	connections; it is cleared on every rebuild and on close.
	Touch is stricter (thumbs rest on the stick and JUMP while playing): a pick needs a whole
	tap on the same card (no drag past TouchSlop px, lifted within TouchHold s) that began
	TouchArm s after the cards appeared; a touch that began in the thumbstick zone (left
	40 %, lower half) or on JUMP is ignored until TouchGuard s. Until TouchArm the cards are
	dimmed with a thin gold sweep along their bottom edge, so it is clear when taps count.
]]
local offerArm = {
	Arm = 0.35,
	TouchArm = 0.8,
	TouchGuard = 1.2,
	TouchHold = 0.6,
	TouchSlop = 24,
	ShownAt = math.huge, -- when the cards appeared
	Touches = setmetatable({}, { __mode = "k" }) :: any, -- touch input → record
	LastTouch = nil :: any, -- the touch that ended last
	Stage = 0.25,
	Stagger = 0.06,
	At = math.huge, -- input counts from this os.clock()
	Press = 0, -- when the last confirm press (click / tap / A / Enter / 1-4) began
	Token = 0, -- bumped by every offer and close (cancels a pending reveal)
	Revealed = false,
	Fx = UIAnim.Track(),
}

-- True when a confirm may be taken (see offerArm above).
local function offerArmed(): boolean
	return offerOpen and os.clock() >= offerArm.At and offerArm.Press >= offerArm.At
end

-- Is the player on touch right now (the stricter touch rules and the locked look)?
local function touchMode(): boolean
	local last = UserInputService:GetLastInputType()
	if last == Enum.UserInputType.Touch then
		return true
	end
	return UserInputService.TouchEnabled and not UserInputService.KeyboardEnabled and last ~= Enum.UserInputType.Gamepad1
end

-- A touch that began where the thumbs rest while playing: the thumbstick zone or JUMP.
local function touchGuarded(pos: Vector2): boolean
	local cam = workspace.CurrentCamera
	local vp = cam and cam.ViewportSize or Vector2.new(1, 1)
	if pos.X < vp.X * 0.4 and pos.Y > vp.Y * 0.5 then
		return true
	end
	local jump = levelUp.JumpButton
	if not (jump and jump.Parent) then
		jump = player:FindFirstChildOfClass("PlayerGui") and player.PlayerGui:FindFirstChild("JumpButton", true)
		levelUp.JumpButton = jump
	end
	if jump and jump:IsA("GuiObject") and jump.Visible then
		local a, size = jump.AbsolutePosition, jump.AbsoluteSize
		-- touch positions and GUI positions may differ by the topbar inset: check both
		for _, p in ipairs({ pos, pos - GuiService:GetGuiInset() }) do
			if p.X >= a.X - 16 and p.X <= a.X + size.X + 16 and p.Y >= a.Y - 16 and p.Y <= a.Y + size.Y + 16 then
				return true
			end
		end
	end
	return false
end

-- A complete, deliberate tap made after the cards armed (see offerArm above).
local function touchTapOk(rec): boolean
	local began = rec.At
	if began < offerArm.ShownAt + offerArm.TouchArm then
		return false
	elseif rec.Guarded and began < offerArm.ShownAt + offerArm.TouchGuard then
		return false
	elseif (rec.EndedAt or os.clock()) - began > offerArm.TouchHold then
		return false
	end
	return rec.Moved <= offerArm.TouchSlop
end

--[[
	May this confirm (a card, REROLL, SKIP) be taken? `input` is the activating input when
	known. Touch goes by touchTapOk (a touch never seen beginning is refused); a button
	that does not say which input fired uses the touch that just ended; mouse, keys and
	gamepad use offerArmed.
]]
local function confirmInput(input: InputObject?): boolean
	if not offerOpen then
		return false
	end
	if input and input.UserInputType == Enum.UserInputType.Touch then
		local rec = offerArm.Touches[input]
		return rec ~= nil and touchTapOk(rec)
	end
	local last = offerArm.LastTouch
	if input == nil and last and os.clock() - (last.EndedAt or 0) < 0.25 then
		return touchTapOk(last)
	end
	return offerArmed()
end

local function cardIconId(c): string
	if c.Type == "Evolve" then
		local def = WeaponData.Weapons[c.Id]
		return def and def.Evolution and def.Evolution.Id or c.Id
	elseif c.Type == "Gold" or c.Type == "Heal" then
		return c.Type
	end
	return c.Id
end

-- Header band colours: (band fill, accent). The accent rims the card and its icon tile.
local function cardBand(c): (Color3, Color3)
	if c.Type == "Gold" or c.Type == "Heal" then
		return P.moss_700, P.moss_200
	end
	local r = Theme.Rarity[c.Rarity] or Theme.Rarity.Common
	if c.Rarity == "Rare" then
		-- NEW cards read cool ice-blue next to the slate upgrades
		return P.ice_500:Lerp(P.slate_800, 0.55), P.ice_300
	elseif c.Rarity == "Legendary" then
		return r.Band, r.Color
	end
	return r.Band:Lerp(P.slate_900, 0.35), r.Color
end

-- An upgrade's rank change: ("LV 5 → 6", "12") from the server's Rank ("Lv 5 → 6 / 12"),
-- or from Level for older servers; nil on other cards.
function Choice.rankLevels(c): (string?, string?)
	if c.Type ~= "WeaponUp" and c.Type ~= "PassiveUp" then
		return nil, nil
	end
	local a, b, m = string.match(tostring(c.Rank or ""), "(%d+)%s*→%s*(%d+)%s*/%s*(%d+)")
	if a then
		return string.format("LV %s → %s", a, b), m
	end
	local level = tonumber(c.Level) or 1
	local max = c.Type == "WeaponUp" and WeaponData.MaxLevel or PassiveData.MaxLevelOf(c.Id)
	return string.format("LV %d → %d", level - 1, level), tostring(max)
end

-- The card takes its item to the last rank. It is still a choice, so it reads "Final
-- upgrade"; "Maxed" is only for an item that has no upgrade left (never offered).
function Choice.finalRank(c): boolean
	if c.Type ~= "WeaponUp" and c.Type ~= "PassiveUp" then
		return false
	end
	local max = c.Type == "WeaponUp" and WeaponData.MaxLevel or PassiveData.MaxLevelOf(c.Id)
	return c.Rarity == "Epic" or (tonumber(c.Level) or 0) >= max
end

-- Small caps on the card's tab: what kind of card this is, with the rank change on
-- upgrades ("UPGRADE · LV 5 → 6", "FINAL UPGRADE · LV 11 → 12"); withMax adds "/ 12".
local function cardKind(c, withMax: boolean?): string
	if c.Type == "WeaponNew" then
		return "NEW WEAPON"
	elseif c.Type == "PassiveNew" then
		return "NEW PASSIVE"
	elseif c.Type == "Evolve" then
		return "EVOLUTION"
	elseif c.Type == "Gold" or c.Type == "Heal" then
		return "BONUS"
	end
	local head = Choice.finalRank(c) and "FINAL UPGRADE" or "UPGRADE"
	local lv, max = Choice.rankLevels(c)
	if lv then
		return head .. "  ·  " .. lv .. ((withMax and max) and (" / " .. max) or "")
	end
	return head
end

-- Line under the card name: "LV 3 → 4 / 8", "LONGBOW EVOLVES"; nothing on NEW cards (the
-- server sends Rank; older servers only sent Level).
local function cardLevelText(c): string
	if c.Type == "WeaponNew" or c.Type == "PassiveNew" then
		return ""
	elseif c.Type == "Evolve" then
		local def = WeaponData.Weapons[c.Id]
		return string.upper((def and def.Name or "Weapon") .. " evolves")
	elseif c.Rank and c.Rank ~= "NEW" then
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
	What a card says, split for the card layout:
	  Desc     the short description (a weapon upgrade shows its new perk, or the weapon's
	           own description)
	  Stats    starting stats of a NEW weapon ({ Label, To }): a table of rows
	  Changes  stat changes ({ Label, From, To }): the first is the boxed highlight, the
	           rest small rows under it
	From the server's Lines (real StatSheet / WeaponData values); bonus cards and older
	servers fall back to the plain Description.
]]
local function cardContent(c): (string?, { any }, { any })
	local lines = type(c.Lines) == "table" and c.Lines or {}
	local stats, changes = {}, {}
	local perk: string? = nil
	for _, line in ipairs(lines) do
		if line.Text then
			perk = string.format('<font color="%s"><b>%s</b></font> %s', hex(P.gold_300), tostring(line.Label), tostring(line.Text))
		elseif line.From then
			table.insert(changes, line)
		elseif line.To then
			table.insert(stats, line)
		end
	end
	-- upgrade cards lead with the server's one-line gain summary ("+10 damage, +1 arrow",
	-- or the new perk); NEW / evolution / bonus cards with their short description
	local summary = type(c.Summary) == "string" and c.Summary ~= "" and c.Summary or nil
	local desc: string? = nil
	if c.Type == "WeaponUp" then
		local def = WeaponData.Weapons[c.Id]
		desc = perk or summary or (def and def.Description)
	elseif c.Type == "PassiveUp" and summary then
		desc = summary
	elseif c.Description and c.Description ~= "" then
		desc = c.Description
	elseif summary then
		desc = summary
	end
	return desc, stats, changes
end

-- Icon for a stat label (Icons names); amount stats ("Arrows", "Strikes") use the weapon.
local STAT_ICONS = {
	{ "projectile speed", "arrowFast" },
	{ "projectiles", "duplicate" },
	{ "cooldown", "clock" },
	{ "duration", "hourglass" },
	{ "area", "area" },
	{ "pierce", "arrowFast" },
	{ "regen", "plus" },
	{ "heal", "plus" },
	{ "hp", "heart" },
	{ "armor", "shield" },
	{ "speed", "boot" },
	{ "knockback", "chevronRight" },
	{ "luck", "clover" },
	{ "crit", "aim" },
	{ "pickup", "magnet" },
	{ "xp", "sprout" },
	{ "gold", "coin" },
	{ "damage", "sparkle" },
}
local function statIcon(parent: Instance, label: string, c, size: number): Frame
	local l = string.lower(label)
	for _, pair in ipairs(STAT_ICONS) do
		if string.find(l, pair[1], 1, true) then
			return Icons.Draw(parent, pair[2], { Size = size, Color = P.gold_300 })
		end
	end
	if WeaponData.Weapons[c.Id] then
		return Icons.Upgrade(parent, cardIconId(c), { Size = size })
	end
	return Icons.Draw(parent, "chevronsUp", { Size = size, Color = P.gold_300 })
end

-- "Synergy: Elemental Trinity 2/3" → "ELEMENTAL TRINITY · 2 / 3" (the server's card text).
local function synergyText(c): string
	local s = tostring(c.Synergy)
	s = string.gsub(s, "^Synergy:%s*", "")
	local name, have, need = string.match(s, "^(.-)%s+(%d+)%s*/%s*(%d+)$")
	if name then
		return string.upper(name) .. "  ·  " .. have .. " / " .. need
	end
	return string.upper(s)
end

local pickedAt = 0 -- when a card was last picked (its punch plays before the close)

-- Selection: the picked card turns gold (focus look), punches up with a quick flash, the
-- others shrink and dim; the overlay closes right after (closeOffer).
local function pickAnimation(index: number)
	pickedAt = os.clock()
	local reduced = (ClientSettings.Reduced() or ClientPerformance.Reduced())
	local focus = levelUp.Focus[index]
	if focus then
		focus(true)
	end
	for _, card in ipairs(levelUp.Cards:GetChildren()) do
		if card:IsA("GuiObject") then
			local s = UIAnim.ScaleOf(card)
			local face = card:FindFirstChild("Face")
			if card.Name == "Card" .. index then
				s.Scale = reduced and 1.03 or 1.09
				UIAnim.Tween(s, 0.14, { Scale = 1.04 }, Enum.EasingStyle.Quad)
				if face and face:IsA("GuiObject") and not noFlashes() then
					local flash = new("Frame", { Name = "PickFlash", BackgroundColor3 = P.gold_200, BackgroundTransparency = 0.6, BorderSizePixel = 0, Size = UDim2.fromScale(1, 1), ZIndex = 60 }, face)
					UIKit.corner(flash, Theme.Radius.L)
					TweenService:Create(flash, TweenInfo.new(0.22), { BackgroundTransparency = 1 }):Play()
				end
			else
				UIAnim.Tween(s, 0.14, { Scale = 0.93 })
				if face and face:IsA("GuiObject") then
					local shade = new("Frame", { Name = "PickShade", BackgroundColor3 = C.Backdrop, BackgroundTransparency = 1, BorderSizePixel = 0, Size = UDim2.fromScale(1, 1), ZIndex = 60 }, face)
					UIKit.corner(shade, Theme.Radius.L)
					UIAnim.Tween(shade, 0.14, { BackgroundTransparency = 0.45 })
				end
			end
		end
	end
end

local function chooseCard(index: number, input: InputObject?)
	if not confirmInput(input) then
		return
	end
	offerOpen = false
	offerArm.At = math.huge
	Choice.choiceSound("ChoicePick")
	pickAnimation(index)
	-- the card set id: a double tap or a late packet for an older set is ignored (CHOICE_STATE)
	Remotes.Get("LevelUpChoose"):FireServer(index, lastOffer and lastOffer.OfferId)
end

-- A one-shot light streak across a card face (clipped to the card).
local function cardSweep(face: GuiObject, delay: number, color: Color3)
	local clip = new("Frame", { Name = "Sweep", BackgroundTransparency = 1, Size = UDim2.fromScale(1, 1), ClipsDescendants = true, ZIndex = 40 }, face)
	local streak = new("Frame", { BackgroundColor3 = color, BackgroundTransparency = 0.65, BorderSizePixel = 0, AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(-0.3, 0.5), Size = UDim2.new(0.22, 0, 1.6, 0), Rotation = 18, ZIndex = 40, Visible = false }, clip)
	new("UIGradient", { Transparency = NumberSequence.new({ NumberSequenceKeypoint.new(0, 1), NumberSequenceKeypoint.new(0.5, 0.2), NumberSequenceKeypoint.new(1, 1) }) }, streak)
	task.delay(delay, function()
		if streak.Parent then
			streak.Visible = true
			local tw = TweenService:Create(streak, TweenInfo.new(0.4, Enum.EasingStyle.Quad, Enum.EasingDirection.InOut), { Position = UDim2.fromScale(1.3, 0.5) })
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

-- A thin gold rule fading out towards `fadeLeft`'s side (flanks the buttons and hint).
local function goldRule(parent: Instance, width: number, fadeLeft: boolean, order: number): Frame
	local r = new("Frame", { Name = "Rule", BackgroundColor3 = P.gold_400, BorderSizePixel = 0, Size = UDim2.fromOffset(width, 1), LayoutOrder = order }, parent)
	new("UIGradient", { Transparency = NumberSequence.new(fadeLeft and 1 or 0.25, fadeLeft and 0.25 or 1) }, r)
	return r
end

-- How to choose with the device in hand ("Press 1, 2 or 3 to choose" / tap / gamepad).
local function choiceHint(count: number): string
	return Choice.Prompts.Choose(count)
end

--[[
	Layout (owner mockup): big serif LEVEL UP! over a gold rule with a diamond, "Choose one
	upgrade", an AUTO-PICK pill and the gold countdown bar; the cards; REROLL / SKIP
	flanked by thin gold rules; a hint line on how to choose with the current device.
]]
local function buildLevelUp()
	local overlay = new("Frame", {
		Name = "LevelUp",
		Size = UDim2.fromScale(1, 1),
		BackgroundTransparency = 1,
		Active = true,
		Visible = false,
		ZIndex = Theme.Z.LevelUp,
	}, root)
	overlay:SetAttribute("BackdropTransparency", 0.2)
	levelUp.Overlay = overlay
	levelUp.Focus = {}
	local dim = new("Frame", { Name = "Dim", BackgroundColor3 = C.Backdrop, BackgroundTransparency = 0.2, BorderSizePixel = 0, Active = true, ZIndex = 1 }, overlay)
	UIKit.Bleed(dim)
	-- "Panel" is what show() pops in: here the whole content block
	local panel = new("Frame", { Name = "Panel", BackgroundTransparency = 1, ZIndex = 2 }, overlay)
	levelUp.Panel = panel
	-- approved screen 04: CHOOSE YOUR UPGRADE, a gold rule with a diamond, LEVEL N • PICK ONE,
	-- the AUTO-PICK pill (the countdown; no separate bar)
	levelUp.Title = text(panel, "Display", "CHOOSE YOUR UPGRADE", {
		Name = "Title",
		TextXAlignment = Enum.TextXAlignment.Center,
		TextColor3 = P.gold_300,
		TextStrokeColor3 = C.Shadow,
		TextStrokeTransparency = 0.45,
	}, 46)
	new("UIGradient", { Rotation = 90, Color = ColorSequence.new(P.gold_200, P.gold_400) }, levelUp.Title)
	levelUp.Divider = UIKit.Divider(panel, 460)
	levelUp.Sub = text(panel, "Label", "PICK ONE", { TextXAlignment = Enum.TextXAlignment.Center, TextColor3 = P.ivory_100, TextTruncate = Enum.TextTruncate.AtEnd }, 18)
	levelUp.Pill = UIKit.IconPill(panel, "clock", "AUTO-PICK IN 25s", { AnchorPoint = Vector2.new(0.5, 0) })
	levelUp.Pill.Label.TextColor3 = C.Text
	levelUp.Cards = new("Frame", { Name = "Cards", BackgroundTransparency = 1 }, panel)
	levelUp.Layout = UIKit.list(levelUp.Cards, {
		FillDirection = Enum.FillDirection.Horizontal,
		HorizontalAlignment = Enum.HorizontalAlignment.Center,
		VerticalAlignment = Enum.VerticalAlignment.Center,
		Padding = UDim.new(0, 18),
	})
	local actions = new("Frame", { Name = "Actions", BackgroundTransparency = 1 }, panel)
	levelUp.Actions = actions
	UIKit.list(actions, { FillDirection = Enum.FillDirection.Horizontal, HorizontalAlignment = Enum.HorizontalAlignment.Center, VerticalAlignment = Enum.VerticalAlignment.Center, Padding = UDim.new(0, 18) })
	levelUp.RuleL = goldRule(actions, 110, true, 0)
	levelUp.RuleR = goldRule(actions, 110, false, 3)
	-- REROLL: Config.LevelUp.Choices new cards; SKIP: no card, a little run gold. Both show what is left this
	-- run (permanent upgrades / VIP give them); with none bought they say where to get them.
	levelUp.Reroll = UIKit.Button(actions, {
		Kind = "Outline",
		Title = "REROLL",
		Subtitle = "New cards",
		TitleStyle = "H3",
		Icon = "cycle",
		IconSize = 26,
		Size = UDim2.fromOffset(230, 60),
		Align = "Left",
		LayoutOrder = 1,
		OnClick = function(input)
			task.defer(function()
				if not confirmInput(input) then
					return
				end
				-- no picks until the new cards are in (re-armed if the server sends none)
				offerArm.At = math.huge
				local shown = offerArm.ShownAt
				offerArm.ShownAt = math.huge
				local token = offerArm.Token
				task.delay(1, function()
					if offerArm.Token == token and offerOpen then
						offerArm.At = os.clock()
						offerArm.ShownAt = shown
					end
				end)
				Remotes.Get("LevelUpReroll"):FireServer(lastOffer and lastOffer.OfferId)
			end)
		end,
	})
	levelUp.Skip = UIKit.Button(actions, {
		Kind = "Outline",
		Title = "SKIP",
		Subtitle = "No card",
		TitleStyle = "H3",
		Icon = "skip",
		IconSize = 26,
		Size = UDim2.fromOffset(230, 60),
		Align = "Left",
		LayoutOrder = 2,
		OnClick = function(input)
			task.defer(function()
				if confirmInput(input) then
					offerOpen = false
					offerArm.At = math.huge
					Remotes.Get("LevelUpSkip"):FireServer(lastOffer and lastOffer.OfferId)
				end
			end)
		end,
	})
	-- how to choose (keyboard / touch / gamepad), between two short rules
	local hint = new("Frame", { Name = "Hint", BackgroundTransparency = 1 }, panel)
	UIKit.list(hint, { FillDirection = Enum.FillDirection.Horizontal, HorizontalAlignment = Enum.HorizontalAlignment.Center, VerticalAlignment = Enum.VerticalAlignment.Center, Padding = UDim.new(0, 14) })
	goldRule(hint, 90, true, 0)
	levelUp.HintText = text(hint, "Body", "", { Size = UDim2.fromOffset(0, TS(15) + 6), AutomaticSize = Enum.AutomaticSize.X, TextColor3 = C.TextMuted, LayoutOrder = 1 }, 15)
	goldRule(hint, 90, false, 2)
	levelUp.Hint = hint
	UserInputService.LastInputTypeChanged:Connect(function()
		if overlay.Visible and lastOffer then
			levelUp.HintText.Text = choiceHint(#lastOffer.Choices)
		end
	end)

	-- keyboard: 1 / 2 / 3 pick a card. Every confirm-type press is timed here (also when
	-- the GUI took it: gamepad A on a selected card) for the fresh-press rule.
	local keys = { [Enum.KeyCode.One] = 1, [Enum.KeyCode.Two] = 2, [Enum.KeyCode.Three] = 3, [Enum.KeyCode.Four] = 4 }
	local confirmKeys = { [Enum.KeyCode.ButtonA] = true, [Enum.KeyCode.Return] = true, [Enum.KeyCode.KeypadEnter] = true, [Enum.KeyCode.Space] = true }
	-- every touch is tracked (also during play: a thumb already down when the cards
	-- appear must stay refused): when it began, where, how far it moved, when it lifted
	UserInputService.InputChanged:Connect(function(input)
		local rec = offerArm.Touches[input]
		if rec then
			local p = input.Position
			rec.Moved = math.max(rec.Moved, (Vector2.new(p.X, p.Y) - rec.Pos).Magnitude)
		end
	end)
	UserInputService.InputEnded:Connect(function(input)
		local rec = offerArm.Touches[input]
		if rec then
			local p = input.Position
			rec.Moved = math.max(rec.Moved, (Vector2.new(p.X, p.Y) - rec.Pos).Magnitude)
			rec.EndedAt = os.clock()
			offerArm.LastTouch = rec
		end
	end)
	UserInputService.InputBegan:Connect(function(input, processed)
		local t = input.UserInputType
		if t == Enum.UserInputType.Touch then
			local p = Vector2.new(input.Position.X, input.Position.Y)
			offerArm.Touches[input] = { At = os.clock(), Pos = p, Moved = 0, Guarded = touchGuarded(p) }
		end
		if t == Enum.UserInputType.MouseButton1 or t == Enum.UserInputType.Touch or confirmKeys[input.KeyCode] or keys[input.KeyCode] then
			offerArm.Press = os.clock()
		end
		if processed or not offerOpen or not overlay.Visible then
			return
		end
		local index = keys[input.KeyCode]
		if index and lastOffer and lastOffer.Choices[index] then
			chooseCard(index)
		end
	end)
end

-- Fixed parts of a card (reference px).
local CARD = { Pad = 14, Band = 30, Tile = 62, Row = 30, Box = 76, Syn = 30, Foot = 44, FootPad = 12, Inset = 6, TabH = 26, PBand = 26, PTile = 56, PRow = 28 }

-- Phones (landscape) get a smaller footer and title so the rows keep their room.
function Choice.cardFootH(): number
	return UIKit.IsCompact() and 38 or CARD.Foot
end
-- "CHOOSE YOUR UPGRADE" at the biggest size that fits the screen width.
function Choice.titleSize(): number
	local base = UIKit.IsCompact() and 34 or 46
	local fit = (virtualSize().X - 2 * margin()) / (19 * 0.8) / (UIKit.IsCompact() and Theme.TextScaleCompact or 1)
	return math.max(18, math.min(base, math.floor(fit)))
end
-- The card name (serif, centred under the art).
function Choice.cardNameH(): number
	return TS(UIKit.IsCompact() and 22 or 26) + 6
end

-- Phones in landscape have the shortest cards: one description line and a one-line hint.
function Choice.compactLandscape(): boolean
	return UIKit.IsCompact() and not portrait
end

-- Is this card's description line the one-line gain summary (an upgrade) rather than
-- the weapon / passive text?
function Choice.summaryCard(c): boolean
	return c.Type == "WeaponUp" or c.Type == "PassiveUp"
end

-- Height of a description on a card `w` wide: one or two lines (a rough width estimate;
-- the label wraps and truncates for real); an upgrade's summary line takes one line on
-- phones in landscape.
local function descHeight(desc: string?, w: number, c): number
	local plain = string.gsub(desc or "", "<[^>]+>", "")
	local maxLines = (Choice.compactLandscape() and Choice.summaryCard(c)) and 1 or 2
	local lines = math.clamp(math.ceil((utf8.len(plain) or #plain) * TS(14) * 0.44 / math.max(1, w - 2 * CARD.Pad)), 1, maxLines)
	return TS(14) * lines + 8
end

-- Height of the evolution hint under the rows (two wrapped lines; it keeps its room on
-- phones, where a stat row gives way: the description line already sums up the gain).
local function hintHeight(): number
	return TS(13) * 2 + 6
end

-- The boxed highlight: shorter on phones.
local function boxHeight(): number
	return UIKit.IsCompact() and 62 or CARD.Box
end

-- Height a landscape card needs for everything but its art panel.
local function cardNeeds(c, w: number): number
	local desc, stats, changes = cardContent(c)
	local h = CARD.Inset + 8 + Choice.cardNameH() + (desc and descHeight(desc, w, c) + 6 or 0) + 4
	if #changes > 0 then
		h += boxHeight() + 6 + (#changes - 1) * (CARD.Row - 2)
	else
		h += #stats * CARD.Row
	end
	if c.Synergy then
		h += CARD.Syn + 10
	end
	if c.Hint then
		h += hintHeight() + 2
	end
	return h + 10 + Choice.cardFootH() + CARD.FootPad
end

-- The art panel's height: what it would like, and the least it keeps before rows give way.
function Choice.artPref(w: number): number
	return UIKit.IsCompact() and math.floor(math.min(110, w * 0.42)) or math.floor(math.min(230, w * 0.72))
end
function Choice.artMin(): number
	return UIKit.IsCompact() and 56 or 120
end

-- Height a wide portrait card needs.
local function cardNeedsPortrait(c): number
	local _, stats, changes = cardContent(c)
	local rows = #changes > 0 and math.min(#changes, 2) or math.min(#stats, 3)
	local h = CARD.PBand + 10 + CARD.PTile + 10 + rows * CARD.PRow
	if c.Synergy then
		h += CARD.Syn + 4
	end
	if c.Hint then
		h += TS(13) + 6
	end
	return math.max(120, h + 8)
end

-- Room left for the cards under the header and above the buttons (landscape).
local function headerHeight(): number
	local subH = (portrait or not UIKit.IsCompact() or offerHint ~= nil) and TS(18) + 6 or 0
	return TS(Choice.titleSize()) + 6 + 16 + subH + 6 + (Theme.Size.Badge + 14) + 16
end
-- Phones in landscape: lower reroll / skip buttons and no "Tap a card" hint line (each
-- card's own footer says it), so the cards keep their height in the short screen.
local function phoneLandscape(): boolean
	return UIKit.IsCompact() and not portrait
end
local function actionH(): number
	return phoneLandscape() and 52 or 60
end
local function footerHeight(): number
	if phoneLandscape() then
		return 12 + actionH() + 8
	end
	return 16 + 60 + 8 + (TS(15) + 6)
end
-- Top of the level-up block: the HUD is hidden under the overlay, so only the Roblox
-- buttons (top left) matter, and the centred title clears them.
local function levelUpTop(): number
	return phoneLandscape() and 4 or insets.Top * 0.5 + 6
end

-- Card sizes for the current screen.
local function cardMetrics(count: number): (number, number)
	local v = virtualSize()
	local m = margin()
	local choices = lastOffer and lastOffer.Choices or {}
	if portrait then
		-- tall enough for the busiest card of this offer
		local most = 120
		for _, c in ipairs(choices) do
			most = math.max(most, cardNeedsPortrait(c))
		end
		return math.min(v.X - 2 * m, 600), math.min(most, 320)
	end
	local w = math.min(300, (v.X - 2 * m - (count - 1) * 18) / math.max(1, count))
	local most = 300
	for _, c in ipairs(choices) do
		most = math.max(most, cardNeeds(c, w) + Choice.artPref(w))
	end
	local room = v.Y - headerHeight() - footerHeight() - levelUpTop() - 6
	return w, math.max(phoneLandscape() and 180 or 260, math.min(most, room, 640))
end

-- Card icon: the upgrade tile framed in the card's accent (rim + a soft halo that breathes
-- gently while the offer is open). popDelay pops it in during the entrance. A picture
-- that has not loaded shows its vector icon meanwhile (Icons), never an empty tile.
local function cardTile(face: GuiObject, c, size: number, accent: Color3, popDelay: number?): Frame
	local id = cardIconId(c)
	local holder = new("Frame", { Name = "IconHolder", BackgroundTransparency = 1, Size = UDim2.fromOffset(size, size) }, face)
	local halo = new("Frame", {
		Name = "Halo",
		BackgroundColor3 = accent,
		BackgroundTransparency = 0.88,
		BorderSizePixel = 0,
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.5),
		Size = UDim2.fromScale(1.25, 1.25),
	}, holder)
	UIKit.corner(halo, 999)
	local tile = UIKit.Tile(holder, { Id = id, Size = size, Evolved = c.Type == "Evolve" })
	local glyph = tile:FindFirstChild("Icon")
	if glyph and glyph:IsA("GuiObject") then
		offerArm.Fx.Add(IdleFx.Attach(glyph, "Float"))
	end
	local rim = c.Type ~= "Evolve" and tile:FindFirstChildOfClass("UIStroke")
	if rim then
		rim.Color = accent
		rim.Thickness = 1.5
		rim.Transparency = 0.3
	end
	-- the painted rarity frame (ui/frames, 9-slice) around the tile; the drawn rim stays
	-- under it and is all there is when the frame is not uploaded
	ArtImage.Frame(tile, ArtImage.CardBand(c), math.max(6, math.floor(size * 0.1)))
	if not (ClientSettings.Reduced() or ClientPerformance.Reduced()) then
		offerArm.Fx.Add(UIAnim.Glow(halo, "BackgroundTransparency", 0.86, 0.95, 1.8))
		if popDelay then
			local s = UIAnim.ScaleOf(holder)
			s.Scale = 0.6
			task.delay(popDelay, function()
				if holder.Parent then
					UIAnim.Tween(s, 0.25, { Scale = 1 }, Enum.EasingStyle.Back)
				end
			end)
		end
	end
	return holder
end

-- One stat row: icon, caps label, right-aligned value (RichText). Returns its height.
local function statRow(parent: Instance, c, line, x: number, y: number, w: number, h: number, value: string): number
	local row = new("Frame", { Name = "Row", BackgroundColor3 = P.slate_950, BackgroundTransparency = 0.55, BorderSizePixel = 0, Position = UDim2.fromOffset(x, y), Size = UDim2.fromOffset(w, h - 2) }, parent)
	UIKit.corner(row, 6)
	local icon = statIcon(row, tostring(line.Label), c, 18)
	icon.AnchorPoint = Vector2.new(0, 0.5)
	icon.Position = UDim2.new(0, 8, 0.5, 0)
	text(row, "Caption", UIKit.track(tostring(line.Label)), {
		Position = UDim2.fromOffset(34, 0),
		Size = UDim2.new(0.55, -34, 1, 0),
		TextColor3 = P.ivory_300,
		TextTruncate = Enum.TextTruncate.AtEnd,
	}, 13)
	text(row, "Number", value, {
		AnchorPoint = Vector2.new(1, 0),
		Position = UDim2.new(1, -10, 0, 0),
		Size = UDim2.new(0.45, 0, 1, 0),
		TextXAlignment = Enum.TextXAlignment.Right,
		RichText = true,
	}, 16)
	return h
end

local function changeValue(line): string
	return string.format('%s <font color="%s">→</font> <font color="%s">%s</font>', tostring(line.From), hex(P.gold_400), hex(P.fx_heal), tostring(line.To))
end

-- The boxed highlight of a card's main change: icon + caps stat, big "From → To".
local function changeBox(parent: Instance, c, line, x: number, y: number, w: number)
	local box = new("Frame", { Name = "Highlight", BackgroundColor3 = P.slate_950, BackgroundTransparency = 0.35, BorderSizePixel = 0, Position = UDim2.fromOffset(x, y), Size = UDim2.fromOffset(w, boxHeight()) }, parent)
	UIKit.corner(box, 8)
	UIKit.stroke(box, P.slate_600, 1, 0.35)
	local compact = UIKit.IsCompact()
	local head = new("Frame", { BackgroundTransparency = 1, Position = UDim2.fromOffset(0, compact and 5 or 8), Size = UDim2.new(1, 0, 0, 22) }, box)
	UIKit.list(head, { FillDirection = Enum.FillDirection.Horizontal, HorizontalAlignment = Enum.HorizontalAlignment.Center, VerticalAlignment = Enum.VerticalAlignment.Center, Padding = UDim.new(0, 8) })
	statIcon(head, tostring(line.Label), c, 18).LayoutOrder = 1
	text(head, "Caption", UIKit.track(tostring(line.Label)), { Size = UDim2.fromOffset(0, 22), AutomaticSize = Enum.AutomaticSize.X, TextColor3 = P.gold_300, LayoutOrder = 2 }, 14)
	text(box, "Number", string.format('%s  <font color="%s">→</font>  <font color="%s">%s</font>', tostring(line.From), hex(P.gold_400), hex(P.fx_heal), tostring(line.To)), {
		Position = UDim2.fromOffset(6, compact and 27 or 32),
		Size = UDim2.new(1, -12, 0, compact and 32 or 36),
		TextXAlignment = Enum.TextXAlignment.Center,
		RichText = true,
		TextScaled = false,
		TextTruncate = Enum.TextTruncate.AtEnd,
	}, compact and 22 or 26)
end

-- Green rounded bar: the synergy this card advances / completes (SynergyData).
local function synergyBar(parent: Instance, c, x: number, y: number, w: number, h: number)
	local ready = c.SynergyReady == true
	local bar = new("Frame", { Name = "Synergy", BackgroundColor3 = ready and P.moss_600 or P.moss_800, BackgroundTransparency = 0.1, BorderSizePixel = 0, Position = UDim2.fromOffset(x, y), Size = UDim2.fromOffset(w, h) }, parent)
	UIKit.corner(bar, 6)
	UIKit.stroke(bar, ready and P.moss_200 or P.moss_400, 1, 0.2)
	local row = new("Frame", { BackgroundTransparency = 1, Size = UDim2.fromScale(1, 1) }, bar)
	UIKit.list(row, { FillDirection = Enum.FillDirection.Horizontal, HorizontalAlignment = Enum.HorizontalAlignment.Center, VerticalAlignment = Enum.VerticalAlignment.Center, Padding = UDim.new(0, 8) })
	Icons.Draw(row, "sparkle", { Size = h - 12, Color = P.fx_heal }).LayoutOrder = 1
	text(row, "Caption", synergyText(c), { Size = UDim2.fromOffset(0, h), AutomaticSize = Enum.AutomaticSize.X, TextColor3 = P.fx_heal, LayoutOrder = 2, TextTruncate = Enum.TextTruncate.AtEnd }, 13)
end

-- Small gold diamonds at the four corners of a card (the sculpted frame of screen 04).
function Choice.cornerGems(face: GuiObject, color: Color3)
	for _, at in ipairs({ { 0, 0 }, { 1, 0 }, { 0, 1 }, { 1, 1 } }) do
		local gem = new("Frame", {
			Name = "Gem",
			BackgroundColor3 = color,
			BorderSizePixel = 0,
			AnchorPoint = Vector2.new(0.5, 0.5),
			Position = UDim2.new(at[1], at[1] == 0 and 9 or -9, at[2], at[2] == 0 and 9 or -9),
			Size = UDim2.fromOffset(7, 7),
			Rotation = 45,
			ZIndex = 5,
		}, face)
		UIKit.stroke(gem, P.slate_950, 1, 0.3)
	end
end

--[[
	The art panel at the top of a landscape card: the item's picture large over a backdrop
	tinted with the item's own colour (a visual theme, not a rarity), a soft glow and a dark
	plinth. popDelay pops the picture in during the entrance; it floats gently while the
	offer is open. A picture that has not loaded shows its vector icon (Icons).
]]
function Choice.cardArt(face: GuiObject, c, x: number, y: number, w: number, h: number, accent: Color3, popDelay: number?): Frame
	local tint = typeof(c.Color) == "Color3" and c.Color or accent
	local art = new("Frame", {
		Name = "Art",
		BackgroundColor3 = Color3.new(1, 1, 1),
		BorderSizePixel = 0,
		Position = UDim2.fromOffset(x, y),
		Size = UDim2.fromOffset(w, h),
		ClipsDescendants = true,
		ZIndex = 2,
	}, face)
	UIKit.corner(art, Theme.Radius.L - 2)
	new("UIGradient", { Rotation = 90, Color = ColorSequence.new(tint:Lerp(P.slate_800, 0.5), tint:Lerp(P.slate_950, 0.82)) }, art)
	local rim = UIKit.stroke(art, accent, 1, 0.5)
	local glowS = math.floor(math.min(w, h) * 1.05)
	local glow = new("Frame", {
		Name = "Glow",
		BackgroundColor3 = tint:Lerp(P.ivory_100, 0.35),
		BackgroundTransparency = 0.8,
		BorderSizePixel = 0,
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.new(0.5, 0, 0.5, 6),
		Size = UDim2.fromOffset(glowS, glowS),
		ZIndex = 2,
	}, art)
	UIKit.corner(glow, 999)
	local plinth = new("Frame", {
		Name = "Plinth",
		BackgroundColor3 = P.slate_950,
		BackgroundTransparency = 0.45,
		BorderSizePixel = 0,
		AnchorPoint = Vector2.new(0.5, 1),
		Position = UDim2.new(0.5, 0, 1, -6),
		Size = UDim2.fromOffset(math.floor(w * 0.6), math.max(8, math.floor(h * 0.1))),
		ZIndex = 2,
	}, art)
	UIKit.corner(plinth, 999)
	local iconS = math.max(32, math.floor(math.min(h - 30, w * 0.62)))
	local holder = new("Frame", {
		Name = "IconHolder",
		BackgroundTransparency = 1,
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.new(0.5, 0, 0.5, 6),
		Size = UDim2.fromOffset(iconS, iconS),
		ZIndex = 3,
	}, art)
	local icon = Icons.Upgrade(holder, cardIconId(c), { Size = iconS, Name = "Icon" })
	icon.ZIndex = 3
	if not (ClientSettings.Reduced() or ClientPerformance.Reduced()) then
		offerArm.Fx.Add(IdleFx.Attach(icon, "Float"))
		offerArm.Fx.Add(UIAnim.Glow(glow, "BackgroundTransparency", 0.74, 0.86, 1.8))
		if popDelay then
			local s = UIAnim.ScaleOf(holder)
			s.Scale = 0.6
			task.delay(popDelay, function()
				if holder.Parent then
					UIAnim.Tween(s, 0.25, { Scale = 1 }, Enum.EasingStyle.Back)
				end
			end)
		end
	end
	if c.Type == "Evolve" then
		rim.Color = P.gold_400
		rim.Thickness = 2
		rim.Transparency = 0
	end
	return art
end

--[[
	One card (approved screen 04). Landscape (tall): a sculpted slate frame with corner gems;
	a tab with the card kind and rank change ("NEW PASSIVE", "UPGRADE · LV 1 → 2", "FINAL
	UPGRADE · LV 11 → 12"); the art panel; the serif name; the one-line effect; the boxed main
	change (stat, big "From → To", the new value green) with any other changes as rows, or a
	NEW weapon's starting stats; the synergy bar; the evolution hint; and a CHOOSE plate with
	the 1 / 2 / 3 key. Portrait (wide, stacked): band with kind + rank + number, icon left,
	name / description right, the rows under it. Hover / gamepad focus / the pick give the
	card a thicker gold border and a warm tint (Focus[index]): visible as shape, not only
	colour.
]]
local function makeCard(c, index: number, count: number, animate: boolean)
	local w, h = cardMetrics(count)
	if portrait then
		h = math.min(cardNeedsPortrait(c), h) -- stacked cards each take what they need
	end
	local bandColor, edgeColor = cardBand(c)
	local legendary = c.Rarity == "Legendary" or c.Type == "Evolve"
	local desc, stats, changes = cardContent(c)
	local pad = CARD.Pad
	local hit = new("TextButton", {
		Name = "Card" .. index,
		Text = "",
		AutoButtonColor = false,
		BackgroundTransparency = 1,
		Size = UDim2.fromOffset(w, h),
		LayoutOrder = index,
	}, levelUp.Cards)
	hit:SetAttribute("Legendary", legendary)
	UIKit.Focusable(hit)
	UIKit.Shadow(hit, Theme.Radius.L, 5, 0)
	-- gold glow behind the card: always on an evolution, on focus for the others
	local glow = new("Frame", {
		Name = "Glow",
		BackgroundColor3 = P.gold_300,
		BackgroundTransparency = legendary and 0.75 or 1,
		BorderSizePixel = 0,
		Position = UDim2.fromOffset(-7, -7),
		Size = UDim2.new(1, 14, 1, 14),
		ZIndex = 0,
	}, hit)
	UIKit.corner(glow, Theme.Radius.L + 7)
	if legendary then
		offerArm.Fx.Add(UIAnim.Glow(glow, "BackgroundTransparency", 0.72, 0.9, 1.1))
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
	new("UIGradient", { Rotation = 90, Color = ColorSequence.new(P.slate_800, P.slate_950) }, face)
	-- warm gold tint of the focused / picked card
	local warm = new("Frame", { Name = "Warm", BackgroundColor3 = P.gold_600, BackgroundTransparency = 1, BorderSizePixel = 0, Size = UDim2.fromScale(1, 1) }, face)
	UIKit.corner(warm, Theme.Radius.L)
	new("UIGradient", { Rotation = 90, Transparency = NumberSequence.new(0.2, 0.75) }, warm)
	local edgeRest = portrait and edgeColor or edgeColor:Lerp(P.slate_400, 0.5)
	local edge = UIKit.stroke(face, legendary and P.gold_400 or edgeRest, legendary and 2.5 or 2, legendary and 0 or 0.3)
	if legendary then
		offerArm.Fx.Add(UIAnim.PulseStroke(edge, 2, 3.5))
	end
	local plateStroke: UIStroke? = nil -- the CHOOSE plate's rim (landscape)
	local bandLabel: TextLabel
	local labelColor = legendary and P.gold_900 or edgeColor:Lerp(P.ivory_100, 0.45)
	local shineOn: GuiObject

	if portrait then
		-- header band
		local bandH = CARD.PBand
		local band = new("Frame", { Name = "Band", BackgroundColor3 = bandColor, BorderSizePixel = 0, Size = UDim2.new(1, 0, 0, bandH), ZIndex = 2, ClipsDescendants = true }, face)
		UIKit.corner(band, Theme.Radius.L)
		new("Frame", { BackgroundColor3 = bandColor, BorderSizePixel = 0, Position = UDim2.new(0, 0, 1, -Theme.Radius.L), Size = UDim2.new(1, 0, 0, Theme.Radius.L), ZIndex = 2 }, band)
		new("Frame", { Name = "Line", BackgroundColor3 = legendary and P.gold_300 or edgeColor, BackgroundTransparency = 0.6, BorderSizePixel = 0, Position = UDim2.new(0, 0, 1, -1), Size = UDim2.new(1, 0, 0, 1), ZIndex = 3 }, band)
		bandLabel = text(band, "Label", UIKit.track(cardKind(c, true)), {
			Position = UDim2.fromOffset(pad, 0),
			Size = UDim2.new(1, -pad * 2 - 28, 1, 0),
			TextXAlignment = Enum.TextXAlignment.Left,
			TextColor3 = labelColor,
			TextTruncate = Enum.TextTruncate.AtEnd,
			ZIndex = 3,
		}, Theme.TextSize.Caption + 1)
		shineOn = band
	else
		-- the tab on the top edge: kind + rank change (the "/ max" while it fits)
		local long = UIKit.track(cardKind(c, true))
		local tabText = (utf8.len(long) or #long) * TS(13) * 0.62 + 28 <= w - 2 * pad and long or UIKit.track(cardKind(c, false))
		local tab = text(face, "Label", tabText, {
			Name = "Tab",
			AnchorPoint = Vector2.new(0.5, 0),
			Position = UDim2.new(0.5, 0, 0, 2),
			Size = UDim2.fromOffset(0, CARD.TabH),
			AutomaticSize = Enum.AutomaticSize.X,
			TextXAlignment = Enum.TextXAlignment.Center,
			BackgroundColor3 = legendary and P.gold_400 or bandColor:Lerp(P.slate_950, 0.25),
			BackgroundTransparency = 0.04,
			TextColor3 = labelColor,
			ClipsDescendants = true,
			ZIndex = 6,
		}, 13)
		new("UIPadding", { PaddingLeft = UDim.new(0, 12), PaddingRight = UDim.new(0, 12) }, tab)
		UIKit.corner(tab, 8)
		UIKit.stroke(tab, legendary and P.gold_200 or edgeColor, 1, 0.25).ApplyStrokeMode = Enum.ApplyStrokeMode.Border
		bandLabel = tab
		shineOn = tab
		Choice.cornerGems(face, legendary and P.gold_300 or P.gold_500)
	end
	if (c.Rarity == "Rare" or c.Rarity == "Epic" or legendary) and not (ClientSettings.Reduced() or ClientPerformance.Reduced()) then
		-- the rarer tabs shine now and then (started once the card has landed level:
		-- Roblox does not clip inside a rotated card)
		task.delay(animate and (offerArm.Stagger * (index - 1) + 0.32) or 0, function()
			if shineOn.Parent then
				offerArm.Fx.Add(UIAnim.Shine(shineOn, legendary and 1.8 or 2.8, legendary and 0.6 or 0.8))
			end
		end)
	end

	-- focus look (hover, gamepad selection, the pick): thicker gold border, glow, warm tint
	local focused = false
	local function setFocus(on: boolean)
		if focused == on then
			return
		end
		focused = on
		local t = Theme.Motion.Fast
		UIAnim.Tween(warm, t, { BackgroundTransparency = on and 0.82 or 1 })
		if not legendary then
			UIAnim.Tween(edge, t, { Color = on and P.gold_300 or edgeRest, Thickness = on and 3.5 or 2, Transparency = on and 0 or 0.3 })
			UIAnim.Tween(glow, t, { BackgroundTransparency = on and 0.8 or 1 })
			bandLabel.TextColor3 = on and P.gold_200 or labelColor
		end
		if plateStroke then
			UIAnim.Tween(plateStroke, t, { Color = on and P.gold_200 or P.gold_500, Transparency = on and 0 or 0.35, Thickness = on and 2 or 1.5 })
		end
	end
	levelUp.Focus[index] = setFocus
	UIKit.AttachStates(hit, face, Theme.Radius.L, function(on: boolean)
		-- the card lifts (AttachStates), grows a touch and turns gold
		if offerOpen then
			UIAnim.Tween(UIAnim.ScaleOf(hit), Theme.Motion.Fast, { Scale = on and 1.03 or 1 })
			setFocus(on)
		end
	end)
	local delay = offerArm.Stagger * (index - 1) -- this card's entrance delay
	local sub = (c.Type == "WeaponUp" or c.Type == "PassiveUp") and "" or cardLevelText(c)

	if portrait then
		local bandH = CARD.PBand
		-- number badge at the band's right end
		local num = text(face, "Number", tostring(index), {
			AnchorPoint = Vector2.new(1, 0.5),
			Position = UDim2.new(1, -pad, 0, bandH / 2),
			Size = UDim2.fromOffset(20, 20),
			TextXAlignment = Enum.TextXAlignment.Center,
			BackgroundColor3 = P.slate_950,
			BackgroundTransparency = 0.3,
			ZIndex = 4,
		}, 13)
		UIKit.corner(num, 999)
		UIKit.stroke(num, P.ivory_300, 1, 0.3).ApplyStrokeMode = Enum.ApplyStrokeMode.Border
		local y = bandH + 10
		cardTile(face, c, CARD.PTile, edgeColor, animate and delay + 0.08 or nil).Position = UDim2.fromOffset(pad, y)
		local x = pad + CARD.PTile + 12
		text(face, "H2", c.Name, { Position = UDim2.fromOffset(x, y - 2), Size = UDim2.new(0.6, -x, 0, TS(22) + 4), TextTruncate = Enum.TextTruncate.AtEnd })
		if sub ~= "" then
			text(face, "Caption", UIKit.track(sub), {
				AnchorPoint = Vector2.new(1, 0),
				Position = UDim2.new(1, -pad, 0, y + 2),
				Size = UDim2.new(0.4, -pad, 0, TS(13) + 4),
				TextXAlignment = Enum.TextXAlignment.Right,
				TextColor3 = legendary and P.gold_300 or P.ivory_300,
			}, 13)
		end
		if desc then
			text(face, "Small", desc, {
				Position = UDim2.fromOffset(x, y + TS(22) + 4),
				Size = UDim2.new(1, -x - pad, 0, CARD.PTile + 4 - TS(22)),
				TextWrapped = true,
				RichText = true,
				TextYAlignment = Enum.TextYAlignment.Top,
				TextTruncate = Enum.TextTruncate.AtEnd,
			}, 14)
		end
		y += CARD.PTile + 10
		local rw = w - 2 * pad
		if #changes > 0 then
			for i = 1, math.min(#changes, 2) do
				y += statRow(face, c, changes[i], pad, y, rw, CARD.PRow, changeValue(changes[i]))
			end
		else
			for i = 1, math.min(#stats, 3) do
				y += statRow(face, c, stats[i], pad, y, rw, CARD.PRow, tostring(stats[i].To))
			end
		end
		if c.Synergy then
			synergyBar(face, c, pad, y + 4, rw, CARD.Syn - 4)
			y += CARD.Syn + 4
		end
		if c.Hint then
			text(face, "Small", tostring(c.Hint), {
				Position = UDim2.fromOffset(pad, y + 2),
				Size = UDim2.new(1, -2 * pad, 0, TS(13) + 4),
				TextXAlignment = Enum.TextXAlignment.Center,
				TextColor3 = c.HintReady and P.gold_300 or C.TextMuted,
				TextTruncate = Enum.TextTruncate.AtEnd,
			}, 13)
		end
	else
		-- the CHOOSE plate at the bottom: the 1 / 2 / 3 key and CHOOSE
		local footH = Choice.cardFootH()
		local footY = h - footH - CARD.FootPad
		local plate = new("Frame", {
			Name = "ChoosePlate",
			BackgroundColor3 = P.slate_950,
			BackgroundTransparency = 0.2,
			BorderSizePixel = 0,
			Position = UDim2.fromOffset(pad + 4, footY),
			Size = UDim2.new(1, -2 * (pad + 4), 0, footH),
			ZIndex = 2,
		}, face)
		UIKit.corner(plate, 10)
		plateStroke = UIKit.stroke(plate, P.gold_500, 1.5, 0.35)
		UIKit.list(plate, { FillDirection = Enum.FillDirection.Horizontal, HorizontalAlignment = Enum.HorizontalAlignment.Center, VerticalAlignment = Enum.VerticalAlignment.Center, Padding = UDim.new(0, 12) })
		local keySize = footH - 12
		local num = text(plate, "Number", tostring(index), {
			Size = UDim2.fromOffset(keySize, keySize),
			TextXAlignment = Enum.TextXAlignment.Center,
			BackgroundColor3 = P.slate_900,
			BackgroundTransparency = 0,
			LayoutOrder = 1,
			ZIndex = 3,
		}, 16)
		UIKit.corner(num, 6)
		UIKit.stroke(num, P.ivory_200, 1.5, 0.15).ApplyStrokeMode = Enum.ApplyStrokeMode.Border
		text(plate, "Label", "CHOOSE", {
			Size = UDim2.fromOffset(0, footH),
			AutomaticSize = Enum.AutomaticSize.X,
			TextColor3 = P.ivory_100,
			LayoutOrder = 2,
			ZIndex = 3,
		}, 16)

		-- the art panel takes what the text leaves (between Choice.artMin and Choice.artPref)
		local artH = math.clamp(h - cardNeeds(c, w), Choice.artMin(), Choice.artPref(w))
		local y = CARD.Inset
		Choice.cardArt(face, c, CARD.Inset, y, w - 2 * CARD.Inset, artH, edgeColor, animate and delay + 0.08 or nil)
		y += artH + 8
		text(face, "H2", c.Name, {
			Position = UDim2.fromOffset(pad, y),
			Size = UDim2.new(1, -2 * pad, 0, Choice.cardNameH()),
			TextXAlignment = Enum.TextXAlignment.Center,
			TextTruncate = Enum.TextTruncate.AtEnd,
			ZIndex = 2,
		}, UIKit.IsCompact() and 22 or 26)
		y += Choice.cardNameH()
		if sub ~= "" then
			-- evolution / bonus cards: what happens ("LONGBOW EVOLVES", "RUN GOLD") in the
			-- line the effect would take when there is no description
			if not desc then
				text(face, "Label", UIKit.track(sub), {
					Position = UDim2.fromOffset(pad, y),
					Size = UDim2.new(1, -2 * pad, 0, TS(13) + 4),
					TextXAlignment = Enum.TextXAlignment.Center,
					TextColor3 = legendary and P.gold_300 or P.ivory_300,
					TextTruncate = Enum.TextTruncate.AtEnd,
					ZIndex = 2,
				}, 13)
				y += TS(13) + 8
			end
		end
		if desc then
			local dh = descHeight(desc, w, c)
			text(face, "Body", desc, {
				Position = UDim2.fromOffset(pad, y),
				Size = UDim2.new(1, -2 * pad, 0, dh),
				TextXAlignment = Enum.TextXAlignment.Center,
				TextWrapped = true,
				RichText = true,
				TextColor3 = P.ivory_200,
				TextTruncate = Enum.TextTruncate.AtEnd,
				ZIndex = 2,
			}, 14)
			y += dh + 6
		end
		y += 4
		-- top-down under the effect: the rows (what the card does comes first), then the
		-- synergy bar and the evolution hint while they fit above the plate
		local bottom = footY - 8
		local rw = w - 2 * pad
		-- the synergy bar and the evolution hint keep their room (rows that do not fit are
		-- dropped instead: the effect line already sums up the gain)
		local synRoom = c.Synergy and CARD.Syn + 8 or 0
		local hintRoom = c.Hint and hintHeight() + 4 or 0
		local function fits(hh: number): boolean
			return y + hh <= bottom - synRoom - hintRoom
		end
		if #changes > 0 then
			local start = 1
			if fits(boxHeight()) then
				changeBox(face, c, changes[1], pad, y, rw)
				y += boxHeight() + 6
				start = 2
			end
			for i = start, #changes do
				if not fits(CARD.Row - 2) then
					break
				end
				y += statRow(face, c, changes[i], pad, y, rw, CARD.Row - 2, changeValue(changes[i]))
			end
		else
			-- slimmer rows on phones in landscape, so a NEW weapon keeps its third stat
			local rowH = Choice.compactLandscape() and CARD.Row - 4 or CARD.Row
			for _, line in ipairs(stats) do
				if not fits(rowH) then
					break
				end
				y += statRow(face, c, line, pad, y, rw, rowH, tostring(line.To))
			end
		end
		synRoom = 0
		if c.Synergy and fits(CARD.Syn + 4) then
			synergyBar(face, c, pad, y + 4, rw, CARD.Syn)
			y += CARD.Syn + 8
		end
		hintRoom = 0
		local hh = hintHeight()
		if c.Hint and fits(hh) then
			text(face, "Small", tostring(c.Hint), {
				Position = UDim2.fromOffset(pad, bottom - hh),
				Size = UDim2.new(1, -2 * pad, 0, hh),
				TextXAlignment = Enum.TextXAlignment.Center,
				TextYAlignment = Enum.TextYAlignment.Bottom,
				TextWrapped = true,
				TextTruncate = Enum.TextTruncate.AtEnd,
				TextColor3 = c.HintReady and P.gold_300 or C.TextMuted,
			}, 13)
		end
	end

	if animate then
		-- cards come in one after another (Stagger apart): up from below, settling from a
		-- slight tilt and growing to full size in 0.3 s, then a light sweeps across; an
		-- evolution lands with a gold burst. Reduced effects: a quick settle, no tilt.
		local s = UIAnim.ScaleOf(hit)
		if (ClientSettings.Reduced() or ClientPerformance.Reduced()) then
			s.Scale = 0.97
			UIAnim.Tween(s, 0.12, { Scale = 1 })
		else
			s.Scale = 0 -- hidden (but keeping its layout slot) until its turn
			hit.Rotation = (index % 2 == 0) and 4 or -4
			local home = face.Position
			face.Position = home + UDim2.fromOffset(0, 36)
			task.delay(delay, function()
				if not hit.Parent then
					return
				end
				s.Scale = 0.86
				UIAnim.Tween(s, 0.3, { Scale = 1 }, Enum.EasingStyle.Back)
				UIAnim.Tween(hit, 0.3, { Rotation = 0 }, Enum.EasingStyle.Quint)
				UIAnim.Tween(face, 0.28, { Position = home }, Enum.EasingStyle.Quint)
			end)
			-- the sweep waits until the tilt has settled (no clipping inside rotated frames)
			cardSweep(face, delay + 0.32, legendary and P.gold_200 or P.ivory_100)
			if c.Type == "Evolve" then
				goldBurst(hit, delay + 0.12)
			end
		end
	end
	-- touch: dimmed with a thin gold sweep along the bottom until taps count (TouchArm)
	local lockLeft = offerArm.ShownAt + offerArm.TouchArm - os.clock()
	if lockLeft > 0.05 and lockLeft < 5 and touchMode() then
		local lock = new("Frame", { Name = "Lock", BackgroundColor3 = C.Backdrop, BackgroundTransparency = 0.45, BorderSizePixel = 0, Size = UDim2.fromScale(1, 1), ZIndex = 55 }, face)
		UIKit.corner(lock, Theme.Radius.L)
		local bar = new("Frame", { Name = "ArmBar", BackgroundColor3 = P.gold_300, BorderSizePixel = 0, AnchorPoint = Vector2.new(0, 1), Position = UDim2.new(0, 12, 1, -5), Size = UDim2.new(0, 0, 0, 3), ZIndex = 56 }, face)
		UIKit.corner(bar, 999)
		local sweep = TweenService:Create(bar, TweenInfo.new(lockLeft, Enum.EasingStyle.Linear), { Size = UDim2.new(1, -24, 0, 3) })
		sweep:Play()
		offerArm.Fx.Add(sweep)
		task.delay(lockLeft, function()
			if lock.Parent then
				UIAnim.Tween(lock, 0.15, { BackgroundTransparency = 1 })
				UIAnim.Tween(bar, 0.15, { BackgroundTransparency = 1 })
			end
		end)
	end
	-- a press that starts on the card counts as fresh (touch and mouse)
	hit.MouseButton1Down:Connect(function()
		offerArm.Press = os.clock()
	end)
	hit.Activated:Connect(function(input: InputObject?)
		-- deferred: the press timing (InputBegan / Ended) of this same input is recorded first
		task.defer(chooseCard, index, input)
	end)
	return hit
end

local function layoutLevelUp()
	local v = virtualSize()
	local count = lastOffer and #lastOffer.Choices or 3
	local cw, ch = cardMetrics(count)
	local titleH = TS(Choice.titleSize()) + 6
	-- phones (landscape) drop "Choose one upgrade" (the cards need the room) unless the
	-- tutorial has something to say there
	local showSub = portrait or not UIKit.IsCompact() or offerHint ~= nil
	local subH = showSub and TS(18) + 6 or 0
	levelUp.Sub.Visible = showSub
	levelUp.Title.TextSize = TS(Choice.titleSize())
	local pillH = Theme.Size.Badge + 14
	local cardsW = portrait and cw or (count * cw + (count - 1) * 18)
	local cardsH = ch
	if portrait then
		cardsH = (count - 1) * 12
		for _, c in ipairs(lastOffer and lastOffer.Choices or {}) do
			cardsH += math.min(cardNeedsPortrait(c), ch)
		end
	end
	local showHint = not phoneLandscape()
	local hintH = showHint and TS(15) + 6 or 0
	local headH = titleH + 16 + subH + 6 + pillH + 16
	local blockH = headH + cardsH + footerHeight()
	local top = math.max(levelUpTop(), (v.Y - blockH) / 2)
	local panel = levelUp.Panel :: Frame
	panel.Position = UDim2.fromOffset(0, 0)
	panel.Size = UDim2.fromOffset(v.X, v.Y)
	levelUp.Title.Position = UDim2.fromOffset(0, top)
	levelUp.Title.Size = UDim2.new(1, 0, 0, titleH)
	local y = top + titleH
	levelUp.Divider.AnchorPoint = Vector2.new(0.5, 0)
	levelUp.Divider.Position = UDim2.new(0.5, 0, 0, y)
	levelUp.Divider.Size = UDim2.fromOffset(math.min(460, v.X - 2 * margin()), 10)
	y += 16
	levelUp.Sub.Position = UDim2.fromOffset(margin(), y)
	levelUp.Sub.Size = UDim2.new(1, -2 * margin(), 0, subH)
	y += subH + 6
	levelUp.Pill.Frame.Position = UDim2.new(0.5, 0, 0, y)
	y += pillH + 16
	levelUp.Layout.FillDirection = portrait and Enum.FillDirection.Vertical or Enum.FillDirection.Horizontal
	levelUp.Layout.Padding = UDim.new(0, portrait and 12 or 18)
	levelUp.Cards.Position = UDim2.fromOffset((v.X - cardsW) / 2, y)
	levelUp.Cards.Size = UDim2.fromOffset(cardsW, cardsH)
	y += cardsH + (showHint and 16 or 12)
	local ah = actionH()
	levelUp.Actions.Position = UDim2.fromOffset(0, y)
	levelUp.Actions.Size = UDim2.new(1, 0, 0, ah)
	local bw = math.clamp(math.floor((v.X - 2 * margin() - 18) / 2), 150, 240)
	levelUp.Reroll.Instance.Size = UDim2.fromOffset(bw, ah)
	levelUp.Skip.Instance.Size = UDim2.fromOffset(bw, ah)
	-- the flanking rules only where there is room for them
	local ruleW = math.floor((v.X - 2 * margin() - 2 * bw - 3 * 18) / 2)
	levelUp.RuleL.Visible = ruleW >= 40
	levelUp.RuleR.Visible = ruleW >= 40
	levelUp.RuleL.Size = UDim2.fromOffset(math.min(ruleW, 140), 1)
	levelUp.RuleR.Size = UDim2.fromOffset(math.min(ruleW, 140), 1)
	y += ah + 8
	levelUp.Hint.Visible = showHint
	levelUp.Hint.Position = UDim2.fromOffset(0, y)
	levelUp.Hint.Size = UDim2.new(1, 0, 0, hintH)
	levelUp.HintText.Text = choiceHint(count)
end

local function clearCards()
	offerArm.Fx.Clear()
	for _, c in ipairs(levelUp.Cards:GetChildren()) do
		if c:IsA("GuiObject") then
			c:Destroy()
		end
	end
end

-- (Re)builds the cards of lastOffer; a relayout before the reveal only lays out.
local function buildCards(animate: boolean)
	if not animate and not offerArm.Revealed then
		layoutLevelUp()
		return nil
	end
	-- a relayout rebuilds the cards: the gamepad selection stays on the same card
	local selected = GuiService.SelectedObject
	local keep = (selected and selected.Parent == levelUp.Cards) and selected.Name or nil
	clearCards()
	local offer = lastOffer
	if not offer then
		return nil
	end
	local first
	for i, c in ipairs(offer.Choices) do
		local card = makeCard(c, i, #offer.Choices, animate)
		first = first or card
		if keep == card.Name then
			GuiService.SelectedObject = card
		end
	end
	layoutLevelUp()
	return first
end

-- Picture ids on an offer's cards that are not cached yet.
local function offerImages(offer): { string }
	local out = {}
	for _, c in ipairs(offer.Choices) do
		local image = IconData.Image(cardIconId(c))
		if image and not AssetPreload.Ready(image) and not AssetPreload.Failed(image) then
			table.insert(out, image)
		end
	end
	return out
end

local function showOffer(offer)
	local samePanel = offer.PanelId ~= nil and lastOffer ~= nil and offer.PanelId == lastOffer.PanelId and levelUp.Overlay.Visible
	offerArm.Token += 1
	local token = offerArm.Token
	lastOffer = offer
	offerArm.Revealed = false
	offerArm.At = math.huge
	offerArm.ShownAt = math.huge
	clearCards()
	local rerolls, skips = tonumber(offer.Rerolls) or 0, tonumber(offer.Skips) or 0
	local rerollMax, skipMax = tonumber(offer.RerollsMax) or rerolls, tonumber(offer.SkipsMax) or skips
	local skipGold = tonumber(offer.SkipGold) or Config.LevelUp.SkipGold
	levelUp.Reroll.SetText(
		"REROLL",
		rerolls > 0 and string.format("%d left · %d new cards", rerolls, Config.LevelUp.Choices) or (rerollMax > 0 and "None left this run" or "Buy rerolls in the Shop")
	)
	levelUp.Reroll.SetEnabled(rerolls > 0)
	levelUp.Skip.SetText(
		"SKIP",
		skips > 0 and string.format("%d left · +%d gold", skips, skipGold) or (skipMax > 0 and "None left this run" or "Buy skips in the Shop")
	)
	levelUp.Skip.SetEnabled(skips > 0)
	local total = tonumber(offer.BatchTotal) or 1
	local remaining = tonumber(offer.BatchRemaining) or 1
	-- "LEVEL 14  •  PICK ONE", with the round when the panel holds several ("•  1 OF 4")
	local level = tonumber(offer.Level)
	local parts = {}
	if level then
		table.insert(parts, "LEVEL " .. level)
	end
	table.insert(parts, "PICK ONE")
	if total > 1 then
		table.insert(parts, string.format("%d OF %d", total - remaining + 1, total))
	end
	levelUp.SubText = UIKit.track(table.concat(parts, "  •  "))
	if not samePanel then
		UIAnim.Punch(levelUp.Title, (ClientSettings.Reduced() or ClientPerformance.Reduced()) and 0.1 or 0.25)
		Choice.choiceSound("ChoiceOpen")
		offerDeadline = os.clock() + offer.Seconds
		Choice.FrozenLeft = nil
	else
		-- the next round of the same panel (or a reroll): new cards, no second opening sound
		Choice.choiceSound("CardAppear")
		offerDeadline = math.min(offerDeadline, os.clock() + offer.Seconds)
	end
	offerHint = Tutorial.LevelUpHint() or offerHint
	offerOpen = true
	show(levelUp.Overlay, "LevelUp", true)
	local function reveal()
		if token ~= offerArm.Token or not offerOpen then
			return
		end
		offerArm.Revealed = true
		offerArm.ShownAt = os.clock()
		local first = buildCards(not samePanel)
		offerArm.At = os.clock() + offerArm.Arm
		UIKit.FocusIfGamepad(first)
	end
	local pending = offerImages(offer)
	if #pending == 0 then
		reveal()
	else
		-- the dimmer and title are already up; the cards follow within Stage seconds
		task.spawn(function()
			AssetPreload.Stage(pending, offerArm.Stage)
			reveal()
		end)
	end
end

local function closeOffer()
	offerOpen = false
	offerHint = nil
	offerArm.Token += 1
	offerArm.At = math.huge
	offerArm.ShownAt = math.huge
	offerArm.Fx.Clear()
	-- let the picked card's punch play first (unless a new offer opens meanwhile)
	local wait = 0.12 - (os.clock() - pickedAt)
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

--[[
	Chest reward reel: what a chest / shrine / altar pays (ItemGained with Reward = true: an
	item; ChestOpened from an elite chest: level-ups + gold) is shown as a quick horizontal
	case-opening reel. A strip of tiles (icon + rarity rim) scrolls past a fixed gold marker,
	ticking softly as tiles pass, slows down and lands on the reward; then a short reveal
	(name in the rarity colour, rarity, what it does) and it closes by itself. A tap /
	click / gamepad A skips ahead (spinning → landed, revealed → next reward or close).
	The server granted the reward before sending it: the landing tile is the server's
	result, the other tiles are cosmetic filler, and closing, skipping or timing never
	change what the player owns.
	Several rewards queue one after another (queued ones spin faster). The server pauses the
	whole run meanwhile (RunManager.HoldReward); when the queue is done the reel sends
	RewardClose(seq) (seq = rewards received this run, so a close never ends the pause of a
	reward it hasn't shown yet). Timings come from Config.Chests.Reel and the whole
	sequence is squeezed to fit Config.Chests.RewardPauseMax (the server's limit). Reduced
	effects: no spin, just the reveal. Torn down without a close when the player leaves
	the run (InRun), the results show or the hero goes down.
	Built once: a fixed ring of slot tiles is recycled as the strip moves (one slot changes
	per tile passed) and item icons are pooled by id.
	Overhaul (docs/overhaul/REWARD.md, approved screen 05; replaces "every chest rolls"):
	only RARE rewards in a solo run use this reel (a Legendary item, the Golden Chest, the
	guarded altar / rune stones, an elite chest with several levels or an evolution: what
	the server pauses for). Every other reward, and every reward in a live duo / trio run,
	is the compact reward card below (no reel, no pause, no confirmation).
]]
local closeReward: (boolean) -> ()
local buildChest: () -> ()
local showItemReward: (any) -> ()
do
	-- required here, not at the top: the main chunk is at Luau's 200-local limit
	local InputPrompts = require(script.Parent.InputPrompts)
	local RARITY = Theme.ItemRarity
	local TILE, GAP, ICON, SLOTS = 54, 8, 38, 9
	local PITCH = TILE + GAP
	local MID = math.ceil(SLOTS / 2)
	local WIN_H = TILE + 16
	local SETTLE = 0.16
	local rng = Random.new()
	local chest: { [string]: any } = {}
	-- Entry: { Land = icon id, Fill = filler ids, Accent, Name, NameColor, Sub, Detail, Big, Source }
	local reward = {
		Open = false,
		Seq = 0, -- rewards received this run (RewardClose answers with it)
		Started = 0,
		Deadline = 0,
		Shown = 0,
		Total = 0,
		Queue = {} :: { any },
		Current = nil :: any,
		Phase = "", -- "spin" | "settle" | "reveal"
		T0 = 0,
		Spin = 0,
		Reveal = 0,
		RevealEnd = 0,
		LandAt = 0,
		P0 = 0,
		Land = 0,
		Jitter = 0,
		P = 0,
		LastTick = 0,
		Ids = {} :: { string },
	}
	-- Slot: { Frame, Rim (UIStroke), Bar, Flash, Art (painted rarity frame or nil), Index, Icon, IconId }
	local slots: { any } = {}
	local iconPool: { [string]: { GuiObject } } = {}

	-- Display name → icon id (elite chest rewards only carry names).
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

	-- Cosmetic filler: items weighted towards commons (chests), weapons + passives (elite).
	local itemFill: { string } = {}
	for _, id in ipairs(ItemData.Order) do
		local def = ItemData.Items[id]
		local n = def.Rarity == "Legendary" and 1 or (def.Rarity == "Uncommon" and 2 or 3)
		for _ = 1, n do
			table.insert(itemFill, id)
		end
	end
	local upgradeFill: { string } = {}
	for _, id in ipairs(WeaponData.Order) do
		table.insert(upgradeFill, id)
	end
	for _, id in ipairs(PassiveData.Order) do
		table.insert(upgradeFill, id)
	end

	local function accentOf(id: string?): Color3
		local def = id and ItemData.Items[id]
		if def then
			return (RARITY[def.Rarity] or RARITY.Common).Color
		end
		return P.slate_400
	end

	local function layoutChest()
		local v = virtualSize()
		local w = math.min(chest.Mini and 340 or 380, v.X - 2 * margin())
		local winW = w - 24
		chest.WinW = winW
		local y = 10
		chest.Header.Position = UDim2.fromOffset(0, y)
		y += 30
		chest.Source.Position = UDim2.fromOffset(0, y)
		y += TS(12) + 8
		chest.Window.Position = UDim2.fromOffset(12, y)
		chest.Window.Size = UDim2.fromOffset(winW, WIN_H)
		chest.Glow.Position = UDim2.fromOffset(math.floor(w / 2), y + WIN_H / 2)
		y += WIN_H + 10
		chest.Name.Position = UDim2.fromOffset(12, y)
		chest.Name.Size = UDim2.new(1, -24, 0, TS(18) + 6)
		y += TS(18) + 6
		chest.Sub.Position = UDim2.fromOffset(12, y)
		y += TS(12) + 6
		chest.Detail.Position = UDim2.fromOffset(16, y)
		chest.Detail.Size = UDim2.new(1, -32, 0, TS(14) * 2 + 6)
		local mini = chest.Mini == true
		if not mini then
			y += TS(14) * 2 + 10
		end
		local h = y + (mini and 16 or 8 + TS(12) + 8)
		chest.Panel.Size = UDim2.fromOffset(w, h)
		-- the draining bar sits right under the reveal in the mini (no TAP TO SKIP line)
		chest.Timer.Frame.Position = mini and UDim2.new(0.5, 0, 1, -8) or UDim2.new(0.5, 0, 1, -TS(12) - 10)
		if mini then
			-- the run goes on: beside the hero (left of centre in landscape, under the top
			-- HUD in portrait), never over him
			local m = margin()
			if portrait then
				-- under the hero (the top holds the timer, health and weapons panels)
				local cy = math.min(v.Y * 0.5 + 80 + h / 2, v.Y - h / 2 - 8)
				chest.Panel.Position = UDim2.fromOffset(math.floor(v.X / 2), math.floor(cy))
			else
				-- left of the hero, under the timer / health cluster, over the ability bar
				-- (under the top bar row, so only the margin matters on the left)
				local x = math.max(m + w / 2, math.min(v.X / 2 - 60 - w / 2, v.X * 0.25))
				local top = (Hud.TopBottom() or 0) + 8
				local bottom = (Hud.BarTop() or v.Y) - 8
				local cy = math.max(top + h / 2, math.min(v.Y * 0.42, bottom - h / 2))
				chest.Panel.Position = UDim2.fromOffset(math.floor(x), math.floor(cy))
			end
		else
			-- centred on the hero's spot, a touch high so the bottom HUD stays readable
			chest.Panel.Position = UDim2.fromOffset(math.floor(v.X / 2), math.floor(math.clamp(v.Y * 0.45, h / 2 + insets.Top + 8, v.Y - h / 2 - 8)))
		end
	end

	-- Puts sequence index idx (its icon from the pool, its rarity rim) into slot s.
	local function setSlot(s, idx: number)
		s.Index = idx
		local id = reward.Ids[idx]
		if s.IconId ~= id then
			if s.Icon then
				s.Icon.Parent = nil
				local list = iconPool[s.IconId]
				if not list then
					list = {}
					iconPool[s.IconId] = list
				end
				table.insert(list, s.Icon)
			end
			s.Icon, s.IconId = nil, nil
			if id then
				local list = iconPool[id]
				local icon = list and table.remove(list)
				if not icon then
					icon = Icons.Upgrade(nil, id, { Size = ICON, AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.45), Back = P.slate_800 })
				end
				icon.Parent = s.Frame
				s.Icon, s.IconId = icon, id
			end
		end
		s.Frame.Visible = id ~= nil
		local cur = reward.Current
		local color = (cur and idx == reward.Land) and cur.Accent or accentOf(id)
		local common = id ~= nil and ItemData.Items[id] ~= nil and ItemData.Items[id].Rarity == "Common"
		s.Rim.Color = color
		s.Rim.Transparency = common and 0.45 or 0.05
		s.Bar.BackgroundColor3 = color
		if s.Art then
			local landed = cur ~= nil and idx == reward.Land
			ArtImage.SetFrame(s.Art, ArtImage.ItemBand(id, landed and cur.Big == true))
		end
		s.Flash.BackgroundTransparency = 1
	end

	-- Draws the strip with sequence index p (fractional) under the marker. Slot k always
	-- holds the indices ≡ k (mod SLOTS), so one slot changes per tile passed.
	local function render(p: number)
		reward.P = p
		local cx = (chest.WinW or 300) / 2
		local first = math.floor(p + 0.5) - MID + 1
		for k, s in ipairs(slots) do
			local idx = first + ((k - 1 - first) % SLOTS)
			if s.Index ~= idx then
				setSlot(s, idx)
			end
			s.Frame.Position = UDim2.fromOffset(math.floor(cx + (idx - p) * PITCH + 0.5), WIN_H / 2)
		end
		local centre = math.floor(p + 0.5)
		if centre ~= reward.LastTick then
			reward.LastTick = centre
			if reward.Phase == "spin" and deps.Audio and deps.Audio.Play then
				pcall(deps.Audio.Play, "ReelTick")
			end
		end
	end

	local function setCaption()
		local cur = reward.Current
		local src = string.upper(cur and cur.Source or "Chest")
		if reward.Total > 1 then
			src ..= "  ·  " .. reward.Shown .. "/" .. reward.Total
		end
		chest.Source.Text = UIKit.track(src)
	end

	local function setRevealAlpha(a: number, tween: boolean)
		for _, l in ipairs({ chest.Name, chest.Sub, chest.Detail }) do
			if tween then
				TweenService:Create(l, TweenInfo.new(0.18), { TextTransparency = a }):Play()
			else
				l.TextTransparency = a
			end
		end
	end

	-- Light burst behind the reel on landing; bigger and gold for legendaries.
	local function burst(big: boolean, color: Color3)
		local g = chest.Glow :: Frame
		g.Size = UDim2.fromOffset(10, 10)
		g.BackgroundColor3 = big and P.gold_200 or color
		g.BackgroundTransparency = big and 0.15 or 0.45
		local size = big and 340 or 220
		TweenService:Create(g, TweenInfo.new(big and 0.7 or 0.45, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), { Size = UDim2.fromOffset(size, size), BackgroundTransparency = 1 }):Play()
	end

	local function finish(send: boolean)
		if not reward.Open then
			return
		end
		reward.Open = false
		reward.Current = nil
		reward.Phase = ""
		table.clear(reward.Queue)
		chest.ModeSet = false
		hide(chest.Overlay, "Reward")
		if send then
			Remotes.Get("RewardClose"):FireServer(reward.Seq)
		end
	end
	closeReward = finish

	-- The reel stops on the reward: name, rarity and text fade in, the tile punches.
	local function reveal(now: number)
		local e = reward.Current
		render(reward.Land)
		reward.Phase = "reveal"
		reward.LandAt = now
		reward.RevealEnd = now + reward.Reveal
		chest.Name.Text = e.Name
		chest.Name.TextColor3 = e.NameColor
		chest.Sub.Text = e.Sub
		chest.Sub.TextColor3 = e.NameColor:Lerp(C.TextMuted, 0.35)
		chest.Detail.Text = e.Detail
		chest.Marker.Color = e.Accent
		local reduced = (ClientSettings.Reduced() or ClientPerformance.Reduced())
		local flashes = not noFlashes()
		setRevealAlpha(0, not reduced)
		if not reduced then
			for _, s in ipairs(slots) do
				if s.Index == reward.Land then
					UIAnim.Punch(s.Frame, e.Big and 0.24 or 0.14)
					if flashes then
						s.Flash.BackgroundColor3 = e.Big and P.gold_200 or P.ivory_100
						s.Flash.BackgroundTransparency = 0.35
						TweenService:Create(s.Flash, TweenInfo.new(0.4), { BackgroundTransparency = 1 }):Play()
					end
				end
			end
			UIAnim.Punch(chest.Name, 0.12)
			if flashes then
				burst(e.Big, e.Accent)
			end
		end
		if deps.Audio and deps.Audio.Play then
			pcall(deps.Audio.Play, "Item", e.Big and 0.9 or nil)
		end
	end

	-- Mini (the run goes on) or full (the run is paused) presentation for this entry.
	local function setMode(mini: boolean)
		if chest.Mini == mini and chest.ModeSet then
			return
		end
		chest.ModeSet = true
		chest.Mini = mini
		chest.Dim.Visible = not mini
		chest.Detail.Visible = not mini
		chest.Hint.Visible = not mini
		setCovering("Reward", not mini)
		layoutChest()
	end

	-- Next reward in the queue (or the end): its sequence, timings and the spin.
	local function startNext(now: number)
		local e = table.remove(reward.Queue, 1)
		if not e then
			finish(true)
			return
		end
		reward.Current = e
		reward.Shown += 1
		setMode(e.Mini == true)
		if e.Mini then
			layoutChest() -- follows the HUD as it is now (boss bar, team rows)
		end
		local R = (Config.Chests :: any).Reel or {}
		local baseSpin = R.Spin or 1.3
		local first = reward.Shown == 1
		local spin = first and baseSpin or (R.QueuedSpin or 0.8)
		local revealT = first and (R.Reveal or 1.3) or (R.QueuedReveal or 1)
		if e.Mini then
			spin = math.min(spin, R.MiniSpin or 0.7)
			revealT = math.min(revealT, R.MiniReveal or 0.8)
		end
		-- keep this and everything queued behind it inside the server's pause limit
		local need = (spin + revealT) * (1 + #reward.Queue)
		local left = reward.Deadline - now
		if need > left then
			local k = math.max(0, left) / need
			spin *= k
			revealT = math.max(0.6, revealT * k)
		end
		if spin < (e.Mini and 0.25 or 0.3) or (ClientSettings.Reduced() or ClientPerformance.Reduced()) then
			spin = 0
		end
		local travel = spin > 0 and math.max(8, math.floor((R.Tiles or 26) * spin / baseSpin + 0.5)) or 0
		reward.P0 = MID
		reward.Land = MID + travel
		-- filler: no tile repeats its close neighbours or the reward
		local ids = reward.Ids
		table.clear(ids)
		local pool = e.Fill
		for i = 1, reward.Land + SLOTS do
			local id = pool[rng:NextInteger(1, #pool)]
			for _ = 1, 6 do
				if id ~= e.Land and id ~= ids[i - 1] and id ~= ids[i - 2] and id ~= ids[i - 3] then
					break
				end
				id = pool[rng:NextInteger(1, #pool)]
			end
			ids[i] = id
		end
		ids[reward.Land] = e.Land
		reward.Jitter = spin > 0 and (rng:NextNumber() - 0.5) * 0.6 or 0
		reward.Spin, reward.Reveal, reward.T0 = spin, revealT, now
		for _, s in ipairs(slots) do
			s.Index = -1
		end
		setCaption()
		setRevealAlpha(1, false)
		chest.Marker.Color = P.gold_300
		chest.Timer.Set(1)
		reward.LastTick = reward.P0
		if spin > 0 then
			reward.Phase = "spin"
			render(reward.P0)
		else
			reveal(now)
		end
	end

	-- Tap / click / gamepad A: a spinning reel lands now; a revealed one moves on.
	local function skip()
		if not reward.Open then
			return
		end
		local now = os.clock()
		if reward.Phase == "spin" or reward.Phase == "settle" then
			reveal(now)
		elseif reward.Phase == "reveal" and now - reward.LandAt > 0.25 then
			startNext(now)
		end
	end

	local function enqueue(e)
		local now = os.clock()
		table.insert(reward.Queue, e)
		if reward.Open then
			reward.Total += 1
			setCaption()
			return
		end
		reward.Open = true
		reward.Started = now
		-- a little inside the server's limit (it counts from the reward, we from its arrival)
		reward.Deadline = now + ((Config.Chests :: any).RewardPauseMax or 7) - 0.3
		reward.Shown = 0
		reward.Total = 1
		chest.ModeSet = false
		setMode(e.Mini == true)
		chest.Hint.Text = UIKit.track(string.upper(InputPrompts.ToSkip()))
		show(chest.Overlay, "Reward", false)
		setCovering("Reward", e.Mini ~= true)
		if not (ClientSettings.Reduced() or ClientPerformance.Reduced()) then
			-- the panel lands with a little tilt
			local panel = chest.Panel :: Frame
			panel.Rotation = -4
			UIAnim.Tween(panel, 0.3, { Rotation = 0 }, Enum.EasingStyle.Back)
			UIAnim.Punch(chest.Icon, 0.35)
		end
		startNext(now)
	end

	-- Counts a reward message; an unreadable one still answers the server's pause.
	local function received()
		reward.Seq += 1
	end
	local function releaseIfIdle()
		if not reward.Open then
			Remotes.Get("RewardClose"):FireServer(reward.Seq)
		end
	end

	--[[
		Compact reward card (approved screen 05): an automatic reward (a common chest /
		shrine item, a one-level elite chest, and in a live duo / trio run every reward) is
		reported by a contained side card: header "SMALL CHEST · REWARD", the reward in a
		medallion, its name, rarity / count and what it does, and a draining bar
		("Auto-added · 3s"). No reel, no dimmer, no confirmation: the server already granted
		it, the card is presentation only. It never owns input (not a UIState primary): it
		holds informational headlines (UIState hold "RewardCard") but leaves movement and
		chest prompts alone, so the next chest can be opened while it shows. The x closes it
		early. Repeats of the same reward from the same source coalesce ("x2") instead of
		queueing; different rewards queue and show faster while others wait. Hidden (its
		clock stopped) while a covering panel owns the screen. Every reward also lands in the
		recent-rewards history (LootUI.RecordReward, the ITEMS list).
	]]
	local CARD_SECONDS = 3 -- on screen when nothing waits
	local CARD_QUEUED = 1.6 -- when more are waiting
	local CARD_RARE = 4 -- a rare reward shown as a card (live duo / trio run)
	local CARD_W = 340
	local card: { [string]: any } = { Queue = {}, Cur = nil, Left = 0, Total = 0, Held = false }

	-- More than one living fighter in the run: the world is live, so even a rare reward is
	-- a card (the server never holds a group run for a reward: RunManager.HoldReward).
	local function groupLive(): boolean
		local n = 0
		for _, p in ipairs(Players:GetPlayers()) do
			if p:GetAttribute("InRun") == true and p:GetAttribute("Alive") ~= false then
				n += 1
			end
		end
		return n > 1
	end

	local function setCardHold(on: boolean)
		if card.Held ~= on then
			card.Held = on
			UIState.SetHold("RewardCard", on)
		end
	end

	local function layoutCard()
		if not card.Panel then
			return
		end
		local v = virtualSize()
		local w = math.min(CARD_W, v.X - 2 * margin())
		local nameH = TS(18) + 6
		local subH = TS(12) + 4
		local bodyH = TS(13) + 4
		local mid = math.max(64, nameH + subH + bodyH + 4)
		local headH = TS(12) + 12
		local h = 8 + headH + 8 + mid + 10 + TS(12) + 6 + 10
		card.Panel.Size = UDim2.fromOffset(w, h)
		card.Head.Size = UDim2.new(1, -54, 0, headH)
		card.Close.Size = UDim2.fromOffset(headH + 6, headH + 6)
		card.Rule.Position = UDim2.fromOffset(12, 8 + headH + 2)
		local y = 8 + headH + 8
		card.Medal.Position = UDim2.fromOffset(14, y + math.floor((mid - 64) / 2))
		local tx = 14 + 64 + 14
		local ty = y + math.floor((mid - (nameH + subH + bodyH)) / 2)
		card.Name.Position = UDim2.fromOffset(tx, ty)
		card.Name.Size = UDim2.new(1, -tx - 12, 0, nameH)
		card.Sub.Position = UDim2.fromOffset(tx, ty + nameH)
		card.Sub.Size = UDim2.new(1, -tx - 12, 0, subH)
		card.Body.Position = UDim2.fromOffset(tx, ty + nameH + subH)
		card.Body.Size = UDim2.new(1, -tx - 12, 0, bodyH)
		y += mid + 10
		card.Bar.Frame.Position = UDim2.fromOffset(14, y + math.floor((TS(12) + 6 - 6) / 2))
		card.Bar.Frame.Size = UDim2.new(1, -28 - 118, 0, 6)
		card.When.Position = UDim2.new(1, -12, 0, y)
		card.When.Size = UDim2.fromOffset(112, TS(12) + 6)
		-- beside the hero, never over him: left of centre under the top HUD in landscape
		-- (the approved screen), under the hero in portrait
		local m = margin()
		if portrait then
			local cy = math.min(v.Y * 0.5 + 80 + h / 2, v.Y - h / 2 - 8)
			card.Panel.Position = UDim2.fromOffset(math.floor(v.X / 2), math.floor(cy))
		else
			local x = math.max(m + w / 2, math.min(v.X / 2 - 60 - w / 2, v.X * 0.25))
			local top = (Hud.TopBottom() or 0) + 8
			local bottom = (Hud.BarTop() or v.Y) - 8
			local cy = math.max(top + h / 2, math.min(v.Y * 0.45, bottom - h / 2))
			card.Panel.Position = UDim2.fromOffset(math.floor(x), math.floor(cy))
		end
	end

	local function fillCard(e)
		card.Head.Text = UIKit.track(string.upper(e.Source or "Chest") .. "  ·  REWARD")
		card.Name.Text = e.Name .. ((e.Count or 1) > 1 and ("  x" .. e.Count) or "")
		card.Name.TextColor3 = e.NameColor
		card.Sub.Text = e.Sub
		card.Sub.TextColor3 = e.NameColor:Lerp(C.TextMuted, 0.35)
		card.Body.Text = e.Detail or ""
		card.MedalRim.Color = e.Accent
		card.MedalRim.Transparency = e.Big and 0 or 0.15
		if card.Edge then
			card.Edge.Color = e.Big and P.gold_300 or P.gold_400
		end
		if card.IconId ~= e.Land then
			if card.Icon then
				card.Icon:Destroy()
			end
			card.IconId = e.Land
			local land = e.Land
			card.Icon = (land == "Gold") and Icons.Draw(card.Medal, "coin", { Size = 40, AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.5), Back = P.slate_900 })
				or Icons.Upgrade(card.Medal, land, { Size = 42, AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.5), Back = P.slate_900 })
		end
	end

	local function showCard(e)
		card.Cur = e
		card.Total = (#card.Queue > 0) and CARD_QUEUED or (e.Big and CARD_RARE or CARD_SECONDS)
		card.Left = card.Total
		fillCard(e)
		layoutCard()
		card.Overlay.Visible = true
		setCardHold(true)
		if not (ClientSettings.Reduced() or ClientPerformance.Reduced()) then
			UIAnim.Pop(card.Panel, 0, 0.85)
			if e.Big and not noFlashes() then
				local g = card.Sheen :: Frame
				g.BackgroundColor3 = e.Accent
				g.BackgroundTransparency = 0.6
				TweenService:Create(g, TweenInfo.new(0.9), { BackgroundTransparency = 1 }):Play()
			end
		end
		if deps.Audio and deps.Audio.Play then
			pcall(deps.Audio.Play, "Item", e.Big and 0.9 or 0.6)
		end
	end

	local function nextCard()
		local e = table.remove(card.Queue, 1)
		if e then
			showCard(e)
		else
			card.Cur = nil
			card.Overlay.Visible = false
			setCardHold(false)
		end
	end

	local function clearCards()
		table.clear(card.Queue)
		card.Cur = nil
		if card.Overlay then
			card.Overlay.Visible = false
		end
		setCardHold(false)
	end

	-- A reward for the card: the same reward from the same source coalesces ("x2").
	local function pushCard(e)
		e.Key = tostring(e.Land) .. "|" .. tostring(e.Source) .. "|" .. tostring(e.Name)
		e.Count = e.Count or 1
		local cur = card.Cur
		if cur and cur.Key == e.Key and not e.NoMerge then
			cur.Count += e.Count
			fillCard(cur)
			card.Left = math.max(card.Left, math.min(card.Total, CARD_QUEUED))
			return
		end
		for _, q in ipairs(card.Queue) do
			if q.Key == e.Key and not e.NoMerge then
				q.Count += e.Count
				return
			end
		end
		table.insert(card.Queue, e)
		if not cur then
			nextCard()
		elseif card.Left > CARD_QUEUED then
			-- something waits: the one on screen hurries up
			card.Left = CARD_QUEUED
			card.Total = math.max(card.Total, CARD_QUEUED)
		end
	end

	local function buildCard()
		local overlay = new("Frame", { Name = "RewardCard", Size = UDim2.fromScale(1, 1), BackgroundTransparency = 1, Active = false, Visible = false, ZIndex = Theme.Z.Loot - 1 }, root)
		card.Overlay = overlay
		local holder, face = UIKit.Surface(overlay, {
			Name = "Panel",
			Size = UDim2.fromOffset(CARD_W, 140),
			AnchorPoint = Vector2.new(0.5, 0.5),
			Radius = Theme.Radius.L,
			Edge = P.gold_400,
			EdgeTransparency = 0.2,
			Transparency = 0.06,
			ZIndex = 2,
		})
		holder.Active = false
		face.Active = false
		card.Panel = holder
		card.Edge = face:FindFirstChildOfClass("UIStroke") :: UIStroke
		card.Sheen = new("Frame", { Name = "Sheen", Size = UDim2.fromScale(1, 1), BackgroundColor3 = P.gold_300, BackgroundTransparency = 1, BorderSizePixel = 0, ZIndex = 2 }, face)
		UIKit.corner(card.Sheen, Theme.Radius.L)
		card.Head = text(face, "Caption", "", { Name = "Head", Position = UDim2.fromOffset(14, 8), TextColor3 = P.gold_300, TextTruncate = Enum.TextTruncate.AtEnd, ZIndex = 3 })
		-- the x: closes this card early (nothing to confirm; the reward is already owned)
		local close = new("TextButton", { Name = "Close", Text = "", AutoButtonColor = false, BackgroundTransparency = 1, AnchorPoint = Vector2.new(1, 0), Position = UDim2.new(1, -6, 0, 5), ZIndex = 4 }, face)
		Icons.Draw(close, "close", { Size = 16, AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.5), Color = P.gold_300 })
		close.Activated:Connect(function()
			if card.Cur then
				nextCard()
			end
		end)
		card.Close = close
		card.Rule = new("Frame", { Name = "Rule", BackgroundColor3 = P.gold_500, BackgroundTransparency = 0.55, BorderSizePixel = 0, Size = UDim2.new(1, -24, 0, 1), ZIndex = 3 }, face)
		-- the reward in a round medallion with a rarity rim
		local medal = new("Frame", { Name = "Medal", BackgroundColor3 = P.slate_900, BorderSizePixel = 0, Size = UDim2.fromOffset(64, 64), ZIndex = 3 }, face)
		UIKit.corner(medal, 999)
		card.MedalRim = UIKit.stroke(medal, P.gold_400, 2, 0.15)
		card.Medal = medal
		card.Name = text(face, "H3", "", { Name = "RewardName", TextTruncate = Enum.TextTruncate.AtEnd, ZIndex = 3 }, 19)
		card.Sub = text(face, "Caption", "", { Name = "RewardSub", TextTruncate = Enum.TextTruncate.AtEnd, ZIndex = 3 })
		card.Body = text(face, "Small", "", { Name = "RewardBody", TextTruncate = Enum.TextTruncate.AtEnd, TextColor3 = C.Text, ZIndex = 3 }, 13)
		card.Bar = UIKit.Meter(face, { Gradient = ColorSequence.new(P.moss_300, P.moss_200), Size = UDim2.new(1, -146, 0, 6) })
		card.Bar.Frame.ZIndex = 3
		card.When = text(face, "Caption", "", { Name = "When", AnchorPoint = Vector2.new(1, 0), TextXAlignment = Enum.TextXAlignment.Right, TextColor3 = C.TextMuted, ZIndex = 3 })
		onRelayout(layoutCard)
		layoutCard()
		RunService.RenderStepped:Connect(function(dt)
			if not card.Cur then
				return
			end
			-- a covering panel (level-up, rare reveal, run menu, results) owns the screen:
			-- out of sight and its clock stopped until it closes
			local covered = UIState.Covered()
			card.Overlay.Visible = not covered
			if covered then
				return
			end
			card.Left -= dt
			if card.Left <= 0 then
				nextCard()
				return
			end
			card.Bar.Set(math.clamp(card.Left / math.max(0.1, card.Total), 0, 1))
			card.When.Text = UIKit.track(string.format("Auto-added  ·  %ds", math.ceil(card.Left)))
		end)
		-- leaving the run, results, going down: the cards go (the rewards stay owned)
		player:GetAttributeChangedSignal("InRun"):Connect(clearCards)
		player:GetAttributeChangedSignal("Alive"):Connect(function()
			if player:GetAttribute("Alive") == false then
				clearCards()
			end
		end)
		Remotes.Get("RunResult").OnClientEvent:Connect(clearCards)
	end

	-- Every reward goes to the history (ITEMS list) when it arrives, whatever shows it.
	local function record(e)
		if LootUI.RecordReward then
			LootUI.RecordReward({ Id = e.Land, Name = e.Name, Sub = e.Sub, Source = e.Source, Color = e.NameColor, Count = e.Count or 1 })
		end
	end

	-- Routes a reward: rare and solo (the server paused the run) → the contained reveal
	-- (the reel); everything else → the compact card, and any pause the server may still
	-- hold for it is released at once (the card never roots the hero).
	local function present(e, rare: boolean)
		record(e)
		if rare and not groupLive() then
			e.Mini = false
			enqueue(e)
			return
		end
		e.Mini = true
		e.Big = rare
		pushCard(e)
		releaseIfIdle()
	end

	buildChest = function()
		local overlay = new("Frame", { Name = "Reward", Size = UDim2.fromScale(1, 1), BackgroundTransparency = 1, Visible = false, ZIndex = Theme.Z.Chest }, root)
		overlay:SetAttribute("BackdropTransparency", 0.6)
		chest.Overlay = overlay
		-- the dimmer is the skip target (the run is paused, so it may take the whole screen)
		local dim = new("TextButton", { Name = "Dim", Text = "", AutoButtonColor = false, BackgroundColor3 = C.Backdrop, BackgroundTransparency = 0.6, BorderSizePixel = 0, ZIndex = 1 }, overlay)
		UIKit.Bleed(dim)
		chest.Dim = dim
		dim.Activated:Connect(skip)
		local holder, face = UIKit.Surface(overlay, {
			Name = "Panel",
			Size = UDim2.fromOffset(360, 260),
			AnchorPoint = Vector2.new(0.5, 0.5),
			Radius = Theme.Radius.L,
			Edge = P.gold_400,
			EdgeTransparency = 0.15,
			Transparency = 0.04,
			ZIndex = 2,
		})
		chest.Panel = holder
		chest.Face = face
		chest.Glow = new("Frame", { Name = "Glow", AnchorPoint = Vector2.new(0.5, 0.5), Size = UDim2.fromOffset(10, 10), BackgroundColor3 = P.gold_300, BackgroundTransparency = 1, ZIndex = 2 }, face)
		UIKit.corner(chest.Glow, 999)
		local header = new("Frame", { Name = "Header", BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 30), ZIndex = 3 }, face)
		UIKit.list(header, { FillDirection = Enum.FillDirection.Horizontal, HorizontalAlignment = Enum.HorizontalAlignment.Center, VerticalAlignment = Enum.VerticalAlignment.Center, Padding = UDim.new(0, 8) })
		chest.Header = header
		chest.Icon = Icons.Draw(header, "reward_ChestLarge", { Size = 26, LayoutOrder = 1 })
		chest.Title = text(header, "H1", "TREASURE!", { LayoutOrder = 2, Size = UDim2.fromOffset(0, 30), AutomaticSize = Enum.AutomaticSize.X, TextColor3 = P.gold_300, ZIndex = 3 }, 22)
		chest.Source = text(face, "Caption", "", { Size = UDim2.new(1, 0, 0, TS(12) + 4), TextXAlignment = Enum.TextXAlignment.Center, TextColor3 = C.TextMuted, ZIndex = 3 })

		-- the reel window: slots scroll inside it, the marker frames the centre one
		local win = new("Frame", { Name = "Reel", BackgroundColor3 = P.slate_950, BackgroundTransparency = 0.35, BorderSizePixel = 0, ClipsDescendants = true, ZIndex = 3 }, face)
		UIKit.corner(win, Theme.Radius.M)
		UIKit.stroke(win, P.slate_600, 1, 0.3)
		chest.Window = win
		for k = 1, SLOTS do
			local f = new("Frame", { Name = "Slot" .. k, AnchorPoint = Vector2.new(0.5, 0.5), Size = UDim2.fromOffset(TILE, TILE), BackgroundColor3 = Color3.new(1, 1, 1), BackgroundTransparency = 0.05, BorderSizePixel = 0, Visible = false, ZIndex = 3 }, win)
			UIKit.corner(f, Theme.Radius.M)
			new("UIGradient", { Rotation = 90, Color = ColorSequence.new(P.slate_700, P.slate_900) }, f)
			local rim = UIKit.stroke(f, P.slate_500, 2, 0.05)
			local bar = new("Frame", { Name = "Bar", AnchorPoint = Vector2.new(0.5, 1), Position = UDim2.new(0.5, 0, 1, -4), Size = UDim2.new(1, -18, 0, 3), BorderSizePixel = 0, ZIndex = 4 }, f)
			UIKit.corner(bar, 999)
			local flash = new("Frame", { Name = "Flash", Size = UDim2.fromScale(1, 1), BackgroundColor3 = P.ivory_100, BackgroundTransparency = 1, BorderSizePixel = 0, ZIndex = 6 }, f)
			UIKit.corner(flash, Theme.Radius.M)
			-- painted rarity frame (ui/frames, 9-slice) over the rim; nil when not uploaded
			local art = ArtImage.Frame(f, "Common", 6, { ZIndex = 5 })
			slots[k] = { Frame = f, Rim = rim, Bar = bar, Flash = flash, Art = art, Index = -1, Icon = nil, IconId = nil }
		end
		-- soft edges so tiles slide in and out of view
		for side = 0, 1 do
			local edge = new("Frame", { Name = "Edge", AnchorPoint = Vector2.new(side, 0), Position = UDim2.fromScale(side, 0), Size = UDim2.new(0, 46, 1, 0), BackgroundColor3 = P.slate_950, BorderSizePixel = 0, ZIndex = 7 }, win)
			new("UIGradient", { Rotation = side == 0 and 0 or 180, Transparency = NumberSequence.new(0.05, 1) }, edge)
		end
		local marker = new("Frame", { Name = "Marker", AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.5), Size = UDim2.fromOffset(TILE + 8, TILE + 8), BackgroundTransparency = 1, ZIndex = 8 }, win)
		UIKit.corner(marker, Theme.Radius.M + 2)
		chest.Marker = UIKit.stroke(marker, P.gold_300, 2.5, 0)
		-- pointer notches above and below the marker
		for side = 0, 1 do
			local notch = new("Frame", { Name = "Notch", AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.new(0.5, 0, side, 0), Size = UDim2.fromOffset(12, 12), Rotation = 45, BackgroundColor3 = P.gold_300, BorderSizePixel = 0, ZIndex = 9 }, win)
			UIKit.corner(notch, 2)
		end

		-- the reveal under the reel (invisible while it spins, so nothing jumps)
		chest.Name = text(face, "H3", "", { TextXAlignment = Enum.TextXAlignment.Center, TextTruncate = Enum.TextTruncate.AtEnd, ZIndex = 3 }, 20)
		chest.Sub = text(face, "Caption", "", { Size = UDim2.new(1, -24, 0, TS(12) + 4), TextXAlignment = Enum.TextXAlignment.Center, ZIndex = 3 })
		chest.Detail = text(face, "Small", "", { TextXAlignment = Enum.TextXAlignment.Center, TextYAlignment = Enum.TextYAlignment.Top, TextWrapped = true, TextColor3 = C.Text, ZIndex = 3 }, 14)
		-- footer: the reveal's time left as a draining bar + "TAP TO SKIP"
		chest.Timer = UIKit.Meter(face, { Gradient = ColorSequence.new(P.gold_500, P.gold_300), AnchorPoint = Vector2.new(0.5, 1), Position = UDim2.new(0.5, 0, 1, -TS(12) - 10), Size = UDim2.fromOffset(120, 3) })
		chest.Hint = text(face, "Caption", UIKit.track(string.upper(InputPrompts.ToSkip())), { AnchorPoint = Vector2.new(0, 1), Position = UDim2.new(0, 0, 1, -5), Size = UDim2.new(1, 0, 0, TS(12) + 4), TextXAlignment = Enum.TextXAlignment.Center, TextColor3 = C.TextMuted, ZIndex = 3 })
		onRelayout(layoutChest)
		layoutChest()
		buildCard()

		UserInputService.InputBegan:Connect(function(input, processed)
			if not reward.Open or processed or chest.Mini then
				return
			end
			local k = input.KeyCode
			if k == Enum.KeyCode.ButtonA or k == Enum.KeyCode.Return or k == Enum.KeyCode.Space or k == Enum.KeyCode.E then
				-- E opens chests: only a fresh press a moment after the reel started skips
				if k ~= Enum.KeyCode.E or os.clock() - reward.Started > 0.5 then
					skip()
				end
			end
		end)
		RunService.RenderStepped:Connect(function()
			if not reward.Open then
				return
			end
			local now = os.clock()
			if now > reward.Deadline + 0.3 then
				finish(true) -- past the server's limit: the run is moving again
				return
			end
			if reward.Phase == "spin" then
				local t = (now - reward.T0) / math.max(0.05, reward.Spin)
				if t >= 1 then
					reward.Phase = "settle"
					reward.T0 = now
					render(reward.Land + reward.Jitter)
				else
					-- fast start, long ease-out: overshoots a little (Jitter), then settles
					local ease = 1 - (1 - t) ^ 3
					render(reward.P0 + (reward.Land + reward.Jitter - reward.P0) * ease)
				end
			elseif reward.Phase == "settle" then
				local t = (now - reward.T0) / SETTLE
				if t >= 1 then
					reveal(now)
				else
					render(reward.Land + reward.Jitter * (1 - t) ^ 2)
				end
			elseif reward.Phase == "reveal" then
				chest.Timer.Set(math.clamp((reward.RevealEnd - now) / math.max(0.1, reward.Reveal), 0, 1))
				if now >= reward.RevealEnd then
					startNext(now)
				end
			end
		end)

		-- leaving the run (pause menu MAIN MENU, portal home, run end), the results screen and
		-- going down tear the reel down; the rewards are already the player's
		player:GetAttributeChangedSignal("InRun"):Connect(function()
			finish(false)
			reward.Seq = 0 -- the next run's RunManager record counts from 0 again
		end)
		player:GetAttributeChangedSignal("Alive"):Connect(function()
			if player:GetAttribute("Alive") == false then
				finish(false)
			end
		end)
		Remotes.Get("RunResult").OnClientEvent:Connect(function()
			finish(false)
		end)
	end

	-- Elite chest (remote ChestOpened): the reel lands on the first level-up; the reveal
	-- lists the rest and the gold.
	function UIBuilder.ShowChest(data)
		received()
		if type(data) ~= "table" then
			releaseIfIdle()
			return
		end
		local list = {}
		for _, r in ipairs(type(data.Rewards) == "table" and data.Rewards or {}) do
			if type(r) == "table" then
				table.insert(list, r)
			end
		end
		local gold = tonumber(data.Gold) or 0
		-- several levels or an evolution: the contained reveal (solo); one level: the card
		local rare = data.Dramatic == true
		local extras = {}
		for i = 2, #list do
			table.insert(extras, tostring(list[i].Name) .. " " .. tostring(list[i].Text))
		end
		if gold > 0 then
			table.insert(extras, "+" .. UIKit.formatNumber(gold) .. " gold")
		end
		local top = list[1]
		local e
		if top then
			local evolved = tostring(top.Text) == "EVOLVED!"
			e = {
				Land = nameToId[tostring(top.Name)] or tostring(top.Name),
				Fill = upgradeFill,
				Accent = evolved and P.gold_300 or P.slate_300,
				Name = tostring(top.Name),
				NameColor = evolved and P.gold_200 or C.Text,
				Sub = UIKit.track(string.upper(tostring(top.Text))),
				Detail = #extras > 0 and ("Also: " .. table.concat(extras, "  ·  ")) or "A free level from the chest",
				Big = evolved,
				Source = "Elite chest",
			}
		elseif gold > 0 then
			e = {
				Land = "Gold",
				Fill = upgradeFill,
				Accent = P.gold_300,
				Name = "+" .. UIKit.formatNumber(gold) .. " gold",
				NameColor = P.gold_200,
				Sub = UIKit.track("GOLD"),
				Detail = "Added to your purse",
				Big = false,
				Source = "Elite chest",
			}
		end
		if e then
			e.NoMerge = true -- each elite chest is its own grant
			present(e, rare)
		else
			releaseIfIdle()
		end
	end

	-- An item from a chest / shrine / altar (LootUI → ItemGained with Reward = true).
	showItemReward = function(data)
		received()
		local def = type(data) == "table" and ItemData.Items[tostring(data.Id)]
		if not def then
			releaseIfIdle()
			return
		end
		local r = RARITY[def.Rarity] or RARITY.Common
		local n = tonumber(data.Count) or 1
		local source = type(data.Source) == "string" and data.Source or "Chest"
		-- rare: what the server showcases (Legendary, the guarded altar / rune stones) and
		-- the Golden Chest; the rest is a common automatic reward
		local rare = data.Dramatic == true or def.Rarity == "Legendary" or source == "Golden Chest"
		local e = {
			Land = def.Id,
			Fill = itemFill,
			Accent = r.Color,
			Name = def.Name,
			NameColor = r.Color,
			Sub = UIKit.track(string.upper(r.Label) .. " ITEM" .. (n > 1 and ("  ·  x" .. n) or "")),
			Detail = def.Text,
			Big = def.Rarity == "Legendary",
			Source = source,
		}
		if not (rare and not groupLive()) then
			-- the card says where it went (approved screen 05); the count owned is in the
			-- items strip and the ITEMS list
			e.Sub = UIKit.track(string.upper(r.Label)) .. "  ·  Added to your items" .. (n > 1 and string.format(" (%d owned)", n) or "")
		end
		present(e, rare)
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

-- The tallest cut (<= h, >= floor) through the stacked settings columns that splits no
-- row: the columns' rows laid out as their UIListLayout does (COLUMN_PAD - 4 on top, 6
-- between). Returns h when there is no such cut.
local function snapToRows(cols: { Frame }, h: number, floor: number): number
	local rows: { { number } } = {}
	for _, col in ipairs(cols) do
		local list = {}
		for _, ch in ipairs(col:GetChildren()) do
			if ch:IsA("GuiObject") and ch.Visible then
				table.insert(list, ch)
			end
		end
		table.sort(list, function(a, b)
			return a.LayoutOrder < b.LayoutOrder
		end)
		local y = col.Position.Y.Offset + 12
		for _, ch in ipairs(list) do
			table.insert(rows, { y, y + ch.Size.Y.Offset })
			y += ch.Size.Y.Offset + 6
		end
	end
	local best = nil
	for _, r in ipairs(rows) do
		for _, cut in ipairs({ r[1] - 2, r[2] + 3 }) do
			if cut <= h and cut >= floor and (best == nil or cut > best) then
				local ok = true
				for _, o in ipairs(rows) do
					if o[1] < cut and cut < o[2] then
						ok = false
						break
					end
				end
				if ok then
					best = cut
				end
			end
		end
	end
	return best or h
end

-- A settings column heading: serif caps in gold over a hairline.
local function sectionCaption(parent: Instance, str: string, order: number)
	local h = TS(18) + 14
	local f = new("Frame", { Name = "Heading", BackgroundTransparency = 1, LayoutOrder = order, Size = UDim2.new(1, 0, 0, h) }, parent)
	text(f, "H3", string.upper(str), { Size = UDim2.new(1, 0, 1, -6), TextColor3 = P.gold_200 })
	UIKit.Hairline(f, { AnchorPoint = Vector2.new(0, 1), Position = UDim2.fromScale(0, 1) })
end

-- The settings columns sit on charcoal cards with a thin gold edge (COLUMN_PAD inside).
local COLUMN_PAD = 16
local function settingsColumn(parent: Instance, name: string): Frame
	local col = new("Frame", { Name = name, BackgroundColor3 = P.slate_950, BackgroundTransparency = 0.35, BorderSizePixel = 0, Size = UDim2.fromOffset(300, 300) }, parent)
	UIKit.corner(col, Theme.Radius.M)
	UIKit.stroke(col, P.gold_500, 1, 0.6)
	UIKit.padding(col, COLUMN_PAD - 4, COLUMN_PAD, COLUMN_PAD, COLUMN_PAD)
	UIKit.list(col, { Padding = UDim.new(0, 6) })
	return col
end

-- One line under the options: where settings live and whether saving works right now.
local function settingsNote(): string
	local status = player:GetAttribute("SaveStatus")
	if status == "failing" or status == "memory" then
		return "Progress isn't being saved right now, so changes may not be kept."
	end
	return "Settings are saved with your progress."
end

-- An enum setting's value as words: "RightHanded" → "RIGHT HANDED".
local function settingWord(value: any): string
	return string.upper((string.gsub(tostring(value), "(%l)(%u)", "%1 %2")))
end

-- The same menu is the in-run pause menu and the lobby SETTINGS screen.
local pauseMode = "Settings" -- "Settings" (lobby) | "RunSettings" (opened from the run menu)

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
	local colA = settingsColumn(options, "Sound")
	local colB = settingsColumn(options, "Comfort")
	pause.ColA, pause.ColB = colA, colB

	sectionCaption(colA, "Sound", 1)
	pause.Music = UIKit.Slider(colA, "Music", "music", ClientSettings.Get("Music"), function(v)
		ClientSettings.Set("Music", v)
	end, function() end, { LayoutOrder = 2 })
	pause.Sfx = UIKit.Slider(colA, "Effects", "speaker", ClientSettings.Get("Sfx"), function(v)
		ClientSettings.Set("Sfx", v)
	end, function() end, { LayoutOrder = 3 })
	pause.ChannelSliders = {}
	for i, option in ipairs({ { "CombatVolume", "Combat" }, { "InterfaceVolume", "Interface" }, { "WarningVolume", "Warnings" } }) do
		local key = option[1]
		pause.ChannelSliders[key] = UIKit.Slider(colA, option[2], "speaker", ClientSettings.Get(key), function(v)
			ClientSettings.Set(key, v)
		end, function() end, { LayoutOrder = i + 3 })
	end
	pause.Mute = UIKit.Toggle(colA, "Mute all", "speaker", "Silence every audio channel.", ClientSettings.Get("MuteAll") == true, function(on)
		ClientSettings.Set("MuteAll", on)
	end, { LayoutOrder = 7 })
	pause.SoundCues = UIKit.Toggle(colA, "Visual sound cues", "info", "Words and direction for attack warnings and player sounds.", ClientSettings.Get("VisualAudioCues") == true, function(on)
		ClientSettings.Set("VisualAudioCues", on)
	end, { LayoutOrder = 8 })
	pause.Shake = UIKit.Slider(colA, "Screen shake", "area", ClientSettings.Get("Shake"), function(v)
		ClientSettings.Set("Shake", v)
	end, function() end, { LayoutOrder = 9 })

	sectionCaption(colB, "Comfort & help", 1)
	pause.Reduced = UIKit.Toggle(colB, "Reduced effects", "sparkle", "Fewer particles and trails. No screen flashes.", ClientSettings.Get("ReducedEffects") == true, function(on)
		ClientSettings.Set("ReducedEffects", on)
	end, { LayoutOrder = 2 })
	pause.Numbers = UIKit.Toggle(colB, "Damage numbers", "sword", "Totals over enemies, kept short in big fights.", ClientSettings.Get("DamageNumbers") == true, function(on)
		ClientSettings.Set("DamageNumbers", on)
	end, { LayoutOrder = 3 })
	pause.Tips = UIKit.Toggle(colB, "Show tips", "info", "Short hints while you play.", ClientSettings.Get("Tips") ~= false, function(on)
		ClientSettings.Set("Tips", on)
	end, { LayoutOrder = 4 })
	pause.Minimap = UIKit.Toggle(colB, "Minimap", "area", "A small map of the arena during runs.", ClientSettings.Get("Minimap") ~= false, function(on)
		ClientSettings.Set("Minimap", on)
	end, { LayoutOrder = 5 })
	pause.Flashes = UIKit.Toggle(colB, "Reduce flashes", "sparkle", "Keep attack warnings; suppress bright hit and screen flashes.", ClientSettings.Get("ReduceFlashes") == true, function(on)
		ClientSettings.Set("ReduceFlashes", on)
	end, { LayoutOrder = 6 })
	pause.Choices = {}
	for i, option in ipairs({ { "Colorblind", "COLORS" }, { "TouchLayout", "TOUCH LAYOUT" } }) do
		local key, label = option[1], option[2]
		local b
		b = UIKit.Button(colB, {
			Title = label .. ": " .. settingWord(ClientSettings.Get(key)), Kind = "Outline", Icon = "cycle", IconSize = 18,
			Shrink = true,
			Size = UDim2.new(1, 0, 0, 46), LayoutOrder = i + 6,
			OnClick = function()
				local choices = (Config.Settings :: any).Enums[key]
				local at = table.find(choices, ClientSettings.Get(key)) or 1
				ClientSettings.Set(key, choices[at % #choices + 1])
				b.SetText(label .. ": " .. settingWord(ClientSettings.Get(key)))
				UIAnim.Bump(b.Face)
			end,
		})
		pause.Choices[key] = { Button = b, Label = label }
	end
	pause.ReplayTips = UIKit.Button(colB, {
		Kind = "Secondary",
		Title = "REPLAY TIPS",
		Icon = "cycle",
		IconSize = 18,
		Align = "Center",
		Size = UDim2.new(1, 0, 0, 46),
		LayoutOrder = 10,
		OnClick = function()
			Tutorial.Replay()
			ClientSettings.Set("Tips", true)
			pause.Tips.Set(true)
			UIBuilder.Toast("Tips are on again: they show as you play.", P.gold_300)
		end,
	})
	UIKit.Button(colB, {
		Kind = "Secondary",
		Title = "REPORT A BUG",
		Icon = "warning",
		IconSize = 18,
		Align = "Center",
		Size = UDim2.new(1, 0, 0, 46),
		LayoutOrder = 11,
		OnClick = function()
			BugReportUI.Open()
		end,
	})

	-- one button: DONE (lobby SETTINGS) / BACK (settings opened from the run menu). The run
	-- menu itself (resume, build, leave) is the side drawer below (buildRunMenu).
	local row = new("Frame", { Name = "Buttons", BackgroundTransparency = 1, LayoutOrder = 5, Size = UDim2.new(1, 0, 0, Theme.Size.Button) }, content)
	UIKit.list(row, { FillDirection = Enum.FillDirection.Horizontal, HorizontalAlignment = Enum.HorizontalAlignment.Center, VerticalAlignment = Enum.VerticalAlignment.Center, Padding = UDim.new(0, 12) })
	pause.Resume = UIKit.Button(row, {
		Kind = "Primary",
		Title = "DONE",
		Icon = "check",
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
		local w = tallModalWidth(760)
		m.Panel.Size = UDim2.new(UDim.new(0, w), m.Panel.Size.Y)
		local inner = w - 2 * Theme.Space.XL
		local twoCol = inner >= 540 and not (UIKit.IsCompact() and v.Y > v.X)
		local gap = 20
		local side = 2 -- the columns' padding keeps the slider knobs inside the scroll clip
		local colW = twoCol and math.floor((inner - gap - 2 * side) / 2) or (inner - 2 * side)
		local hA, hB = stackHeight(colA, 6) + 2 * COLUMN_PAD - 4, stackHeight(colB, 6) + 2 * COLUMN_PAD - 4
		if twoCol then
			hA = math.max(hA, hB) -- two cards of one height
			hB = hA
		end
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
		if contentH > h + 1 then
			-- the scroll edge falls between rows, not through a title or its description
			h = snapToRows({ colA, colB }, h, math.max(140, h - 140))
		end
		options.Size = UDim2.new(1, 0, 0, h)
		options.CanvasSize = UDim2.fromOffset(0, contentH)
		options.ScrollBarThickness = contentH > h + 1 and 4 or 0
		pause.Resume.Instance.Size = UDim2.fromOffset(math.clamp(inner, 120, 240), Theme.Size.Button)
	end
	pause.Layout = layoutOptions
	onRelayout(layoutOptions)

	-- gamepad B backs out (not while the bug report sits on top of it, or a text box has
	-- the input); from the run menu's SETTINGS it goes back to the run menu
	UserInputService.InputBegan:Connect(function(input)
		if input.KeyCode ~= Enum.KeyCode.ButtonB or not pause.Overlay.Visible or pause.Overlay:GetAttribute("Hiding") then
			return
		end
		if UIState.IsOpen("Items") or UIState.IsOpen("BugReport") or UserInputService:GetFocusedTextBox() then
			return
		end
		UIBuilder.ClosePause()
	end)
end

local function syncOptions()
	pause.Music.Set(ClientSettings.Get("Music"))
	pause.Sfx.Set(ClientSettings.Get("Sfx"))
	pause.Shake.Set(ClientSettings.Get("Shake"))
	pause.Reduced.Set(ClientSettings.Get("ReducedEffects") == true)
	pause.Numbers.Set(ClientSettings.Get("DamageNumbers") == true)
	pause.Tips.Set(ClientSettings.Get("Tips") ~= false)
	pause.Minimap.Set(ClientSettings.Get("Minimap") ~= false)
	pause.Flashes.Set(ClientSettings.Get("ReduceFlashes") == true)
	pause.Mute.Set(ClientSettings.Get("MuteAll") == true)
	pause.SoundCues.Set(ClientSettings.Get("VisualAudioCues") == true)
	for key, slider in pairs(pause.ChannelSliders) do slider.Set(ClientSettings.Get(key)) end
	for key, option in pairs(pause.Choices) do
		option.Button.SetText(option.Label .. ": " .. settingWord(ClientSettings.Get(key)))
	end
	pause.Layout()
end

------------------------------------------------------------------------------------------
-- Run menu: the side drawer (approved screen 07) for solo and group runs
------------------------------------------------------------------------------------------
--[[
	The in-run menu is a drawer on the right edge that leaves most of the arena (and the HUD:
	HP, timer, build strip) in view. RETURN TO RUN, SETTINGS (the existing settings screen,
	unchanged; BACK returns here), VIEW BUILD (the items / combos list) and LEAVE RUN, which
	asks first (what leaving costs) before it sends AbandonRun.

	What the run does while it is open is decided by the server only (RunManager SetPause):
	solo (one player in the run, Config.Run.SoloPauseFreezesRun) freezes the run; in a group
	run nothing pauses and the menu gives NO protection, so the drawer says "Game not paused,
	you can be hit". This menu never grants protection itself and must not be made to.
	It is the UIState primary "Pause" (priority 50): it never opens over a higher panel and a
	level-up / revive / results opening on top suspends it.
]]

-- (one top-level local: UIBuilder is near Luau's 200-locals limit, so the helpers live in it)
local runMenu: { [string]: any } = { Prompts = require(script.Parent.InputPrompts) }
runMenu.ARM = 0.35 -- a press must begin this long after a state shows (no stale taps)

-- True when the server freezes the run for this menu (its own rule, RunManager SetPause).
function runMenu.menuFreezesRun(): boolean
	local participants = tonumber(Remotes.State():GetAttribute("Participants")) or 1
	return participants <= 1 and Config.Run.SoloPauseFreezesRun == true
end

function runMenu.teamWord(): string
	local participants = tonumber(Remotes.State():GetAttribute("Participants")) or 1
	return participants <= 1 and "SOLO" or participants == 2 and "DUO" or participants == 3 and "TRIO" or "TEAM"
end

function runMenu.saveWarning(): string?
	local status = player:GetAttribute("SaveStatus")
	if status == "failing" or status == "memory" then
		return "Progress isn't being saved right now."
	end
	return nil
end

-- The line under the title: what the run is doing while this menu is open.
function runMenu.runMenuNote(): string
	local note = runMenu.menuFreezesRun() and "The run is paused while this menu is open." or "Game not paused, you can be hit."
	local warn = runMenu.saveWarning()
	return warn and (note .. " " .. warn) or note
end

-- LEAVE RUN's confirm text: the real cost (Config.Gold failure rule, team keeps playing).
function runMenu.leaveNote(): string
	local g = Config.Gold :: any
	local note = string.format(
		"You go back to the main menu and this run ends as a loss. You keep %d%% of this run's gold (+%d%% per stage cleared); kills and account XP so far still count.",
		math.floor((g.FailureRetainBase or 0) * 100 + 0.5),
		math.floor((g.FailureRetainPerStage or 0) * 100 + 0.5)
	)
	local participants = tonumber(Remotes.State():GetAttribute("Participants")) or 1
	if participants > 1 then
		note ..= " Your team keeps playing."
	end
	return note
end

function runMenu.backHint(): string
	local mode = runMenu.Prompts.Mode()
	if mode == "Gamepad" then
		return "Press B to return"
	elseif mode == "Touch" then
		return "Tap the arena to return"
	end
	return "Click the arena to return"
end

function runMenu.buildRunMenu()
	local overlay = new("Frame", {
		Name = "RunMenu",
		Size = UDim2.fromScale(1, 1),
		BackgroundTransparency = 1,
		Active = true,
		Visible = false,
		ZIndex = Theme.Z.Pause,
	}, root)
	-- a light tint: the arena stays readable (solo gets a darker one: it is paused)
	overlay:SetAttribute("BackdropTransparency", 0.82)
	local dim = new("Frame", { Name = "Dim", BackgroundColor3 = C.Backdrop, BackgroundTransparency = 0.82, BorderSizePixel = 0, Active = true, ZIndex = 1 }, overlay)
	UIKit.Bleed(dim)
	runMenu.Overlay, runMenu.Dim = overlay, dim
	-- a tap / click on the arena returns to the run (cancels the leave question first)
	local outside = new("TextButton", {
		Name = "Outside",
		Text = "",
		AutoButtonColor = false,
		BackgroundTransparency = 1,
		Selectable = false,
		Size = UDim2.fromScale(1, 1),
		ZIndex = 1,
	}, overlay)
	UIKit.Bleed(outside)
	outside.Activated:Connect(function()
		if os.clock() - (runMenu.ArmedAt or 0) < runMenu.ARM then
			return
		end
		if runMenu.Confirming then
			runMenu.setConfirm(false)
		else
			UIBuilder.ClosePause()
		end
	end)

	local drawer = new("Frame", {
		Name = "Drawer",
		BackgroundColor3 = P.slate_900,
		BackgroundTransparency = 0.02,
		BorderSizePixel = 0,
		Active = true,
		AnchorPoint = Vector2.new(1, 0),
		ZIndex = 2,
	}, overlay)
	runMenu.Drawer = drawer
	-- the gold edge toward the arena
	new("Frame", { Name = "Edge", BackgroundColor3 = P.gold_500, BackgroundTransparency = 0.25, BorderSizePixel = 0, Size = UDim2.new(0, 2, 1, 0), ZIndex = 3 }, drawer)

	-- run gold and kills (the numbers the HUD shows)
	local function chip(name: string, icon: string): (Frame, TextLabel)
		local f = new("Frame", { Name = name, BackgroundColor3 = P.slate_950, BackgroundTransparency = 0.1, BorderSizePixel = 0, ZIndex = 3 }, drawer)
		UIKit.corner(f, Theme.Radius.M)
		UIKit.stroke(f, P.gold_500, 1, 0.55)
		Icons.Draw(f, icon, { Size = 22, Color = P.gold_300, AnchorPoint = Vector2.new(0, 0.5), Position = UDim2.new(0, 10, 0.5, 0) })
		local l = text(f, "Number", "0", { Position = UDim2.fromOffset(38, 0), Size = UDim2.new(1, -44, 1, 0), ZIndex = 3 })
		return f, l
	end
	runMenu.GoldChip, runMenu.GoldText = chip("Gold", "coin")
	runMenu.KillsChip, runMenu.KillsText = chip("Kills", "skull")

	runMenu.Crest = Icons.Draw(drawer, "helmet", { Size = 52, Color = P.gold_400 })
	runMenu.Crest.AnchorPoint = Vector2.new(0.5, 0)
	runMenu.Title = text(drawer, "H1", "RUN MENU", { TextXAlignment = Enum.TextXAlignment.Center, ZIndex = 3 })
	-- "DUO · RUN CONTINUES" / "SOLO · GAME PAUSED"
	local pill = new("Frame", { Name = "Status", BackgroundColor3 = P.slate_950, BackgroundTransparency = 0.1, BorderSizePixel = 0, AnchorPoint = Vector2.new(0.5, 0), ZIndex = 3 }, drawer)
	UIKit.corner(pill, 999)
	runMenu.PillStroke = UIKit.stroke(pill, P.gold_400, 1.5, 0.1)
	runMenu.PillText = text(pill, "Label", "", { Size = UDim2.fromScale(1, 1), TextXAlignment = Enum.TextXAlignment.Center, TextColor3 = P.gold_200, ZIndex = 3 })
	runMenu.Pill = pill
	runMenu.Rule = UIKit.Hairline(drawer, { AnchorPoint = Vector2.new(0.5, 0), ZIndex = 3 })
	runMenu.Rule.Parent = drawer
	runMenu.Note = text(drawer, "Body", "", { TextXAlignment = Enum.TextXAlignment.Center, TextWrapped = true, TextColor3 = C.Text, ZIndex = 3 })

	runMenu.Return = UIKit.Button(drawer, {
		Kind = "Primary",
		Title = "RETURN TO RUN",
		Icon = "play",
		IconSize = 22,
		Align = "Center",
		Shrink = true,
		ZIndex = 3,
		OnClick = function()
			if runMenu.Confirming then
				runMenu.setConfirm(false)
			else
				UIBuilder.ClosePause()
			end
		end,
	})
	runMenu.Settings = UIKit.Button(drawer, {
		Kind = "Secondary",
		Title = "SETTINGS",
		Icon = "gear",
		IconSize = 22,
		Align = "Center",
		Shrink = true,
		ZIndex = 3,
		OnClick = function()
			UIBuilder.OpenRunSettings()
		end,
	})
	runMenu.Build = UIKit.Button(drawer, {
		Kind = "Secondary",
		Title = "VIEW BUILD",
		Icon = "bars",
		IconSize = 22,
		Align = "Center",
		Shrink = true,
		ZIndex = 3,
		OnClick = function()
			LootUI.OpenItems()
		end,
	})
	runMenu.Rule2 = UIKit.Hairline(drawer, { AnchorPoint = Vector2.new(0.5, 0), ZIndex = 3 })
	runMenu.Rule2.Parent = drawer
	-- LEAVE RUN: crimson; the first press asks, the confirm press (armed) leaves
	local leave = UIKit.Button(drawer, {
		Kind = "Outline",
		Title = "LEAVE RUN",
		Align = "Center",
		Shrink = true,
		ZIndex = 3,
		OnClick = function()
			if os.clock() - (runMenu.ArmedAt or 0) < runMenu.ARM then
				return
			end
			if runMenu.Confirming then
				runMenu.Confirming = false
				Remotes.Get("AbandonRun"):FireServer()
				UIBuilder.ClosePause()
			else
				runMenu.setConfirm(true)
			end
		end,
	})
	runMenu.Leave = leave
	Icons.Draw(leave.Face, "arrowRight", { Size = 22, Color = P.crimson_300, AnchorPoint = Vector2.new(0, 0.5), Position = UDim2.new(0, 16, 0.5, 0) })
	-- the button repaints its edge / title on hover: keep them crimson
	local edge = leave.Face:FindFirstChildOfClass("UIStroke")
	local function crimson()
		if edge and edge.Color ~= P.crimson_400 then
			edge.Color = P.crimson_400
		end
		if leave.Title and leave.Title.TextColor3 ~= P.crimson_300 then
			leave.Title.TextColor3 = P.crimson_300
		end
	end
	crimson()
	if edge then
		edge:GetPropertyChangedSignal("Color"):Connect(crimson)
	end
	if leave.Title then
		leave.Title:GetPropertyChangedSignal("TextColor3"):Connect(crimson)
	end
	local tint = new("Frame", { Name = "Tint", BackgroundColor3 = P.crimson_700, BackgroundTransparency = 0.78, BorderSizePixel = 0, Size = UDim2.fromScale(1, 1), ZIndex = 1, Active = false }, leave.Face)
	UIKit.corner(tint, Theme.Radius.M)

	runMenu.Hint = text(drawer, "Small", "", { TextXAlignment = Enum.TextXAlignment.Center, TextColor3 = C.TextMuted, ZIndex = 3 })

	local function layout()
		local v = virtualSize()
		local compact = UIKit.IsCompact()
		local w
		if portrait then
			w = math.min(v.X - 24, 380)
		else
			w = math.clamp(math.floor(v.X * (compact and 0.4 or 0.3)), 300, 420)
		end
		w = math.min(w, v.X)
		-- the Roblox buttons sit on the top right in some layouts: start below them
		local top = (insets.Right > 0 and insets.Top or 0) + 14
		drawer.Position = UDim2.new(1, 0, 0, 0)
		drawer.Size = UDim2.fromOffset(w, v.Y)
		runMenu.Width = w
		local pad = compact and 16 or 22
		local inner = w - 2 * pad
		local gap = compact and 8 or 12
		local bh = Theme.Size.Button
		local chipH = 40
		local titleH = TS(30) + 6
		local pillH = TS(14) + 14
		local hintH = TS(14) + 8
		-- note lines (rough: ~0.5 em per character)
		local perLine = math.max(10, math.floor(inner / (TS(16) * 0.5)))
		local lines = math.clamp(math.ceil(#runMenu.Note.Text / perLine), 1, 6)
		local noteH = lines * (TS(16) + 3) + 4
		local confirming = runMenu.Confirming == true
		local buttons = confirming and 2 or 4
		local crest = 52
		local function need(): number
			return top + chipH + gap + (crest > 0 and crest + 4 or 0) + titleH + 6 + pillH + gap + 1 + gap + noteH + gap * 2
				+ buttons * bh + (buttons - 1) * gap + gap + 1 + hintH + 12
		end
		-- short screens: drop the crest, then tighter buttons
		if need() > v.Y then
			crest = 0
		end
		if need() > v.Y then
			bh = math.max(Theme.Size.TapMin, bh - 8)
		end
		local showHint = need() <= v.Y
		local y = top
		local half = math.floor((inner - gap) / 2)
		runMenu.GoldChip.Position = UDim2.fromOffset(pad, y)
		runMenu.GoldChip.Size = UDim2.fromOffset(half, chipH)
		runMenu.KillsChip.Position = UDim2.fromOffset(pad + half + gap, y)
		runMenu.KillsChip.Size = UDim2.fromOffset(inner - half - gap, chipH)
		y += chipH + gap
		runMenu.Crest.Visible = crest > 0
		if crest > 0 then
			runMenu.Crest.Position = UDim2.fromOffset(math.floor(w / 2), y)
			y += crest + 4
		end
		runMenu.Title.Position = UDim2.fromOffset(pad, y)
		runMenu.Title.Size = UDim2.fromOffset(inner, titleH)
		y += titleH + 6
		local pw = math.min(inner, math.floor(utf8.len(runMenu.PillText.Text) or 0) * math.floor(TS(14) * 0.66) + 40)
		runMenu.Pill.Position = UDim2.fromOffset(math.floor(w / 2), y)
		runMenu.Pill.Size = UDim2.fromOffset(pw, pillH)
		y += pillH + gap
		runMenu.Rule.Position = UDim2.fromOffset(math.floor(w / 2), y)
		runMenu.Rule.Size = UDim2.fromOffset(math.min(120, inner), 1)
		y += 1 + gap
		runMenu.Note.Position = UDim2.fromOffset(pad, y)
		runMenu.Note.Size = UDim2.fromOffset(inner, noteH)
		y += noteH + gap * 2
		local function place(b: any, on: boolean)
			b.Instance.Visible = on
			if on then
				b.Instance.Position = UDim2.fromOffset(pad, y)
				b.Instance.Size = UDim2.fromOffset(inner, bh)
				y += bh + gap
			end
		end
		place(runMenu.Return, true)
		place(runMenu.Settings, not confirming)
		place(runMenu.Build, not confirming)
		runMenu.Rule2.Visible = not confirming
		if not confirming then
			runMenu.Rule2.Position = UDim2.fromOffset(math.floor(w / 2), y)
			runMenu.Rule2.Size = UDim2.fromOffset(math.floor(inner * 0.7), 1)
			y += 1 + gap
		end
		place(runMenu.Leave, true)
		runMenu.Hint.Visible = showHint
		runMenu.Hint.Position = UDim2.fromOffset(pad, v.Y - hintH - 12)
		runMenu.Hint.Size = UDim2.fromOffset(inner, hintH)
	end
	runMenu.Layout = layout
	onRelayout(layout)

	-- live numbers while open
	local function refreshNumbers()
		runMenu.GoldText.Text = tostring(math.floor(tonumber(player:GetAttribute("RunGold")) or 0))
		runMenu.KillsText.Text = tostring(math.floor(tonumber(player:GetAttribute("Kills")) or 0))
	end
	runMenu.RefreshNumbers = refreshNumbers
	for _, attr in ipairs({ "RunGold", "Kills" }) do
		player:GetAttributeChangedSignal(attr):Connect(function()
			if overlay.Visible then
				refreshNumbers()
			end
		end)
	end
	-- a teammate leaves / joins while it is open: ask the server again (it decides the
	-- freeze from the run's size) and relabel
	Remotes.State():GetAttributeChangedSignal("Participants"):Connect(function()
		if UIState.IsOpen("Pause") and pauseMode ~= "Settings" and player:GetAttribute("InRun") == true then
			Remotes.Get("SetPause"):FireServer(true)
			if overlay.Visible and not runMenu.Confirming then
				runMenu.setConfirm(false)
			end
		end
	end)
	runMenu.Prompts.OnChanged(function()
		runMenu.Hint.Text = runMenu.backHint()
	end)

	-- gamepad B: the leave question first, then the menu (not under ITEMS / bug report)
	UserInputService.InputBegan:Connect(function(input)
		if input.KeyCode ~= Enum.KeyCode.ButtonB or not overlay.Visible or not UIState.IsShown("Pause") then
			return
		end
		if UIState.IsOpen("Items") or UIState.IsOpen("BugReport") or UserInputService:GetFocusedTextBox() then
			return
		end
		if runMenu.Confirming then
			runMenu.setConfirm(false)
		else
			UIBuilder.ClosePause()
		end
	end)
end

-- Fills the drawer for the normal state (on) = false, or the LEAVE RUN question (true).
function runMenu.setConfirm(on: boolean)
	runMenu.Confirming = on
	runMenu.ArmedAt = os.clock()
	local frozen = runMenu.menuFreezesRun()
	if on then
		runMenu.Title.Text = "LEAVE RUN?"
		runMenu.PillText.Text = UIKit.track("This run ends")
		runMenu.PillStroke.Color = P.crimson_400
		runMenu.PillText.TextColor3 = P.crimson_300
		runMenu.Note.Text = runMenu.leaveNote()
		runMenu.Return.SetText("KEEP PLAYING")
		runMenu.Leave.SetText("YES, LEAVE RUN")
		UIKit.FocusIfGamepad(runMenu.Return.Instance)
	else
		runMenu.Title.Text = "RUN MENU"
		runMenu.PillText.Text = UIKit.track(runMenu.teamWord() .. " · " .. (frozen and "Game paused" or "Run continues"))
		runMenu.PillStroke.Color = frozen and P.gold_400 or P.crimson_400
		runMenu.PillText.TextColor3 = frozen and P.gold_200 or P.ivory_100
		runMenu.Note.Text = runMenu.runMenuNote()
		runMenu.Return.SetText("RETURN TO RUN")
		runMenu.Leave.SetText("LEAVE RUN")
		local n = LootUI.ItemCount()
		runMenu.Build.SetText(n > 0 and string.format("VIEW BUILD (%d)", n) or "VIEW BUILD")
	end
	-- solo is paused: a darker tint; a live group run keeps the arena clear
	local dimT = frozen and 0.55 or 0.82
	runMenu.Overlay:SetAttribute("BackdropTransparency", dimT)
	runMenu.Dim.BackgroundTransparency = dimT
	runMenu.Hint.Text = runMenu.backHint()
	runMenu.Layout()
end

-- Slides the drawer in from the right edge (reduced motion: no slide).
function runMenu.slideRunMenuIn()
	local d = runMenu.Drawer
	if ClientSettings.Reduced() then
		d.Position = UDim2.new(1, 0, 0, 0)
		return
	end
	d.Position = UDim2.new(1, math.floor(runMenu.Width or 360), 0, 0)
	UIAnim.Tween(d, 0.22, { Position = UDim2.new(1, 0, 0, 0) }, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
end

-- The run menu (HUD pause button). Never over a decision, results or travel.
function UIBuilder.OpenPause()
	if not UIState.CanOpen("Pause") or player:GetAttribute("InRun") ~= true then
		return
	end
	local fromSettings = pauseMode == "RunSettings" and pause.Overlay.Visible
	if fromSettings then
		pauseMode = "Settings"
		hide(pause.Overlay, "Pause")
	end
	runMenu.RefreshNumbers()
	runMenu.setConfirm(false)
	show(runMenu.Overlay, "Pause", true, false)
	if not fromSettings then
		runMenu.slideRunMenuIn()
	end
	UIKit.FocusIfGamepad(runMenu.Return.Instance)
	Remotes.Get("SetPause"):FireServer(true)
end

-- The existing settings screen, opened from the run menu: BACK returns to the drawer and
-- the run stays as the menu left it (solo paused, group live: the note says so).
function UIBuilder.OpenRunSettings()
	if player:GetAttribute("InRun") ~= true then
		UIBuilder.OpenSettings()
		return
	end
	if runMenu.Overlay.Visible then
		runMenu.Confirming = false
		hide(runMenu.Overlay, "Pause")
	end
	pauseMode = "RunSettings"
	pause.Title.Text = "SETTINGS"
	pause.Resume.SetText("BACK")
	pause.Resume.SetIcon("chevronLeft")
	pause.Note.Text = runMenu.menuFreezesRun() and settingsNote() or ("Game not paused, you can be hit. " .. settingsNote())
	pause.Options.Visible = true
	syncOptions()
	show(pause.Overlay, "Pause", true)
	UIKit.FocusIfGamepad(pause.Resume.Instance)
	-- straight here (no drawer first): the server still hears that the menu is open
	Remotes.Get("SetPause"):FireServer(true)
end

-- Lobby SETTINGS (during a run it is the run menu's settings).
function UIBuilder.OpenSettings()
	if player:GetAttribute("InRun") == true then
		UIBuilder.OpenRunSettings()
		return
	end
	pauseMode = "Settings"
	pause.Title.Text = "SETTINGS"
	pause.Resume.SetText("DONE")
	pause.Resume.SetIcon("check")
	pause.Note.Text = settingsNote()
	pause.Options.Visible = true
	syncOptions()
	show(pause.Overlay, "Pause", true)
	UIKit.FocusIfGamepad(pause.Resume.Instance)
end

-- Closes whichever menu is up: run settings go back to the drawer, the drawer resumes the
-- run (SetPause false), lobby settings just close.
function UIBuilder.ClosePause()
	BugReportUI.Close()
	if pauseMode == "RunSettings" and pause.Overlay.Visible and player:GetAttribute("InRun") == true then
		UIBuilder.OpenPause()
		if not runMenu.Overlay.Visible then
			-- the drawer could not open (a higher panel): leave the menu entirely
			pauseMode = "Settings"
			hide(pause.Overlay, "Pause")
			Remotes.Get("SetPause"):FireServer(false)
		end
		return
	end
	local wasRun = runMenu.Overlay.Visible or pauseMode == "RunSettings"
	runMenu.Confirming = false
	if runMenu.Overlay.Visible then
		hide(runMenu.Overlay, "Pause")
	end
	if pause.Overlay.Visible then
		hide(pause.Overlay, "Pause")
	end
	pauseMode = "Settings"
	if wasRun then
		Remotes.Get("SetPause"):FireServer(false)
	end
end

-- Leaving the run / results: both menus close without telling the server (it ended it).
function runMenu.closeRunMenusSilently()
	runMenu.Confirming = false
	-- also when suspended under a higher panel (open in UIState, not visible)
	if runMenu.Overlay and (runMenu.Overlay.Visible or (overlays.Pause == runMenu.Overlay and UIState.IsOpen("Pause"))) then
		hide(runMenu.Overlay, "Pause")
	end
	if pauseMode == "RunSettings" then
		pauseMode = "Settings"
		hide(pause.Overlay, "Pause")
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
	-- the fallen hero's painted bust (greyed, in a crimson ring) with the heart on its
	-- corner; just the heart when the hero has no portrait (onReviveOffer)
	local hero = new("Frame", { Name = "Hero", BackgroundColor3 = P.slate_950, BorderSizePixel = 0, Size = UDim2.fromOffset(84, 84), LayoutOrder = 1, Visible = false }, content)
	UIKit.corner(hero, 999)
	UIKit.stroke(hero, P.crimson_400, 2.5, 0.05)
	revive.Hero = hero
	revive.Heart = Icons.Draw(content, "heart", { Size = 48, LayoutOrder = 1 })
	revive.Title = text(content, "H1", "YOU FELL!", { LayoutOrder = 2, TextXAlignment = Enum.TextXAlignment.Center, TextColor3 = P.crimson_300 })
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
	-- the hero's portrait when there is one: the heart moves onto its corner
	local heroId = tostring(player:GetAttribute("CharacterId") or (profile and profile.SelectedCharacter) or CharacterData.Default)
	local bust = ArtImage.RoundPortrait(revive.Hero, ArtImage.Portrait(heroId), nil)
	revive.Hero.Visible = bust ~= nil
	if bust then
		bust.ImageColor3 = Color3.fromRGB(150, 140, 145)
		revive.Heart.Parent = revive.Hero
		revive.Heart.AnchorPoint = Vector2.new(1, 1)
		revive.Heart.Position = UDim2.new(1, 10, 1, 6)
		revive.Heart.Size = UDim2.fromOffset(40, 40)
		revive.Heart.ZIndex = 4
	else
		revive.Heart.Parent = revive.Hero.Parent
		revive.Heart.AnchorPoint = Vector2.zero
		revive.Heart.Position = UDim2.new()
		revive.Heart.Size = UDim2.fromOffset(48, 48)
	end
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
	-- the title slams in and the heart beats a few times (event-driven, no endless loop)
	UIAnim.Pop(revive.Title, 0.05, 1.8)
	if not (ClientSettings.Reduced() or ClientPerformance.Reduced()) then
		revive.BeatToken = (revive.BeatToken or 0) + 1
		local token = revive.BeatToken
		for i = 0, 3 do
			task.delay(0.15 + i * 0.7, function()
				if token == revive.BeatToken and revive.Overlay.Visible then
					UIAnim.Punch(revive.Heart, 0.3)
				end
			end)
		end
		UIAnim.Pop(revive.Buy.Instance, 0.3, 0.7)
	end
end

------------------------------------------------------------------------------------------
-- Results
------------------------------------------------------------------------------------------

local results: { [string]: any } = {}
local MORE_H = 18 -- the results' MORE BELOW row
local resultsDeadline = 0
-- REPLAY: start the same mode again once this client is back in the lobby
local pendingReplay: { Mode: string, Until: number, Waited: boolean }? = nil

-- Results screen tokens (approved screen 06 / SWARM_UI_reference_guide shared language)
local RES_CYAN = Color3.fromRGB(100, 183, 203) -- account level (cosmetic) bar
local RES_CYAN_DARK = Color3.fromRGB(58, 128, 148)
local RES_MINT = Color3.fromRGB(159, 206, 152)

-- A summary tile (screen 06: icon, big number, caption). Fixed size from layoutResults.
local function statTile(parent: Instance, icon: string, caption: string, order: number): (TextLabel, TextLabel)
	local f = UIKit.Panel(parent, { Name = caption, LayoutOrder = order, Size = UDim2.fromOffset(140, 104) }, true)
	UIKit.stroke(f, P.gold_600, 1, 0.45)
	local glyph = Icons.Draw(f, icon, { Size = 26, AnchorPoint = Vector2.new(0.5, 0), Position = UDim2.new(0.5, 0, 0, 12), Color = if icon == "coin" or icon == "portal" then nil else P.gold_400, Back = P.slate_950 })
	glyph.Name = "TileIcon" -- hidden on phones in landscape (slim tiles)
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

-- One column of the gold ledger: a number over its caption (and an optional note).
local function ledgerCell(parent: Instance, name: string, order: number, color: Color3): { [string]: any }
	local f = new("Frame", { Name = name, BackgroundTransparency = 1, LayoutOrder = order, Size = UDim2.fromOffset(110, 52) }, parent)
	local value = text(f, "Number", "0", {
		Name = "Value",
		Size = UDim2.new(1, 0, 0, TS(20) + 4),
		TextXAlignment = Enum.TextXAlignment.Center,
		TextTruncate = Enum.TextTruncate.AtEnd,
		TextColor3 = color,
	}, 20)
	local cap = text(f, "Caption", "", {
		Name = "Caption",
		Position = UDim2.fromOffset(0, TS(20) + 6),
		Size = UDim2.new(1, 0, 0, TS(11) + 4),
		TextXAlignment = Enum.TextXAlignment.Center,
		TextTruncate = Enum.TextTruncate.AtEnd,
	}, 11)
	return { Frame = f, Value = value, Caption = cap }
end

-- One progress card (run level / hero mastery / account level): its own label, level,
-- gain line and bar. The three are never merged into one bar.
local function progressCard(parent: Instance, name: string, order: number, gradient: ColorSequence, accent: Color3): { [string]: any }
	local f = UIKit.Panel(parent, { Name = name, LayoutOrder = order, Size = UDim2.fromOffset(200, 84) }, true)
	local stroke = UIKit.stroke(f, accent, 1, 0.55)
	local title = text(f, "Label", "", {
		Name = "Title",
		Position = UDim2.fromOffset(12, 8),
		Size = UDim2.new(1, -24, 0, TS(13) + 4),
		TextXAlignment = Enum.TextXAlignment.Left,
		TextTruncate = Enum.TextTruncate.AtEnd,
		TextColor3 = C.Text,
	}, 13)
	local levelLabel = text(f, "BodyStrong", "", {
		Name = "Level",
		Position = UDim2.fromOffset(12, 8),
		Size = UDim2.new(1, -24, 0, TS(13) + 4),
		TextXAlignment = Enum.TextXAlignment.Right,
		TextTruncate = Enum.TextTruncate.AtEnd,
		RichText = true,
		TextColor3 = C.Text,
	}, 13)
	local gain = text(f, "Small", "", {
		Name = "Gain",
		Position = UDim2.fromOffset(12, TS(13) + 14),
		Size = UDim2.new(1, -24, 0, TS(12) + 4),
		TextXAlignment = Enum.TextXAlignment.Left,
		TextTruncate = Enum.TextTruncate.AtEnd,
		RichText = true,
		TextColor3 = C.TextMuted,
	}, 12)
	local meter = UIKit.Meter(f, {
		Gradient = gradient,
		TextStyle = "Number",
		TextSize = 11,
		AnchorPoint = Vector2.new(0, 1),
		Position = UDim2.new(0, 12, 1, -10),
		Size = UDim2.new(1, -24, 0, 16),
	})
	return { Frame = f, Stroke = stroke, Title = title, Level = levelLabel, Gain = gain, Meter = meter }
end

-- A live private run server (RunServers): the results lead to the main lobby by teleport.
local function onRunServer(): boolean
	return Remotes.State():GetAttribute("RunServer") == true
end

-- STAY / REPORT A BUG on the results: no automatic return or close any more. On a run
-- server the server holds the trip home too (TravelHome "Hold") until MAIN MENU.
local function holdResults()
	if results.Held or results.Leaving or TravelOverlay.Covering() then
		return
	end
	results.Held = true
	if onRunServer() then
		Remotes.Get("TravelHome"):FireServer("Hold")
	end
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

-- Hero Mastery level, XP into it and XP it needs (0 at max) for a hero's total XP: the
-- same rule as MetaUpgradeData.MasteryFor (Config.HeroMastery).
local function masteryFor(totalXP: number): (number, number, number)
	local M = Config.HeroMastery
	local xp = math.max(0, math.floor(totalXP))
	local level = 1
	while level < M.MaxLevel do
		local need = M.Base + M.PerLevel * (level - 1)
		if xp < need then
			return level, xp, need
		end
		xp -= need
		level += 1
	end
	return M.MaxLevel, 0, 0
end

local fillMastery: (any) -> () -- defined below (the profile listener calls it)

local function buildResults()
	local m = UIKit.Modal(root, "Results", 760, 460, Theme.Z.Results)
	results.Overlay = m.Overlay
	results.Modal = m
	local content = m.Content
	fitModal(m, UIKit.list(content, { Padding = UDim.new(0, 10), HorizontalAlignment = Enum.HorizontalAlignment.Center }))

	-- header: the hero's medallion, the verdict, "HERO · ARENA · STAGE", damage and score
	local head = new("Frame", { Name = "Head", BackgroundTransparency = 1, LayoutOrder = 1, Size = UDim2.new(1, 0, 0, 92) }, content)
	UIKit.list(head, { FillDirection = Enum.FillDirection.Horizontal, HorizontalAlignment = Enum.HorizontalAlignment.Center, VerticalAlignment = Enum.VerticalAlignment.Center, Padding = UDim.new(0, 16) })
	local medal = new("Frame", { Name = "Hero", BackgroundColor3 = C.PanelInset, BackgroundTransparency = 0.05, Size = UDim2.fromOffset(80, 80), LayoutOrder = 1 }, head)
	UIKit.corner(medal, 999)
	results.MedalStroke = UIKit.stroke(medal, P.gold_400, 2.5, 0.05)
	results.Medal = medal
	-- the boss that ended the run (bosses/<id>), a small crimson disc on the medal's
	-- bottom-left (clear of the title column)
	local bossBadge = new("Frame", { Name = "BossBadge", BackgroundColor3 = P.slate_950, BorderSizePixel = 0, AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.new(0, 4, 1, -6), Size = UDim2.fromOffset(40, 40), ZIndex = 6, Visible = false }, medal)
	UIKit.corner(bossBadge, 999)
	UIKit.stroke(bossBadge, P.crimson_400, 2, 0.05)
	results.BossBadge = bossBadge
	local stateFolder = Remotes.State()
	local function noteBoss()
		local id = stateFolder:GetAttribute("BossId")
		if type(id) == "string" and id ~= "" then
			results.LastBoss = id
		end
	end
	stateFolder:GetAttributeChangedSignal("BossId"):Connect(noteBoss)
	noteBoss()
	-- painted backdrop by outcome (screens/victory, defeat, results_bg) behind the dimmer
	if ArtImage.Image("screens/victory") or ArtImage.Image("screens/defeat") or ArtImage.Image("screens/results_bg") then
		local back = new("ImageLabel", { Name = "Backdrop", BackgroundTransparency = 1, BorderSizePixel = 0, ScaleType = Enum.ScaleType.Crop, ZIndex = 0, Visible = false }, results.Overlay)
		UIKit.Bleed(back)
		results.Backdrop = back
	end
	local titleCol = new("Frame", { Name = "TitleCol", BackgroundTransparency = 1, Size = UDim2.fromOffset(420, 92), LayoutOrder = 2 }, head)
	results.TitleCol = titleCol
	results.Title = text(titleCol, "Display", "VICTORY!", { Position = UDim2.fromOffset(0, 2), Size = UDim2.new(1, 0, 0, TS(44) + 6) }, 44)
	results.Arena = text(titleCol, "Label", "", { Position = UDim2.fromOffset(0, TS(44) + 10), Size = UDim2.new(1, 0, 0, TS(13) + 6), TextColor3 = C.Text, TextTruncate = Enum.TextTruncate.AtEnd }, 13)
	results.Hero = text(titleCol, "BodyStrong", "", { Position = UDim2.fromOffset(0, TS(44) + TS(12) + 18), Size = UDim2.new(1, 0, 0, TS(15) + 4), TextColor3 = P.gold_200, TextTruncate = Enum.TextTruncate.AtEnd }, 15)
	UIKit.Divider(content, 260, { LayoutOrder = 2 })

	-- body (scrolls on short screens): tiles, gold ledger, progress, rewards, RUN DETAILS
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

	-- 1. summary tiles: survived, enemies defeated, stages cleared, boss state
	local grid = new("Frame", { Name = "Stats", BackgroundTransparency = 1, LayoutOrder = 1, Size = UDim2.new(1, 0, 0, 104) }, body)
	results.Grid = grid
	results.GridLayout = UIKit.list(grid, { FillDirection = Enum.FillDirection.Horizontal, HorizontalAlignment = Enum.HorizontalAlignment.Center, Padding = UDim.new(0, 8), Wraps = true })
	results.Time = statTile(grid, "clock", "Survived", 1)
	results.Kills = statTile(grid, "stat_Kills", "Enemies defeated", 2)
	results.Stages, results.StagesCaption = statTile(grid, "portal", "Stages cleared", 3)
	results.Boss, results.BossCaption = statTile(grid, "crown", "Bosses", 4)

	-- 2. the gold ledger (RunResult: GoldEarned = the unspent run purse at the end,
	-- GoldSpent = chests / shrines, Gold = kept, GoldLost, GoldSurvival + FirstRun = bonuses)
	local ledger = UIKit.Panel(body, { Name = "GoldLedger", LayoutOrder = 2, Size = UDim2.new(1, 0, 0, 96) }, true)
	UIKit.stroke(ledger, P.gold_600, 1, 0.45)
	results.Ledger = ledger
	local cellsRow = new("Frame", { Name = "Cells", BackgroundTransparency = 1, Position = UDim2.fromOffset(8, 8), Size = UDim2.new(1, -16, 0, 52) }, ledger)
	results.LedgerRow = cellsRow
	results.LedgerList = UIKit.list(cellsRow, { FillDirection = Enum.FillDirection.Horizontal, HorizontalAlignment = Enum.HorizontalAlignment.Center, Padding = UDim.new(0, 6), Wraps = true })
	results.LedgerCells = {
		Earned = ledgerCell(cellsRow, "Earned", 1, P.gold_200),
		Spent = ledgerCell(cellsRow, "Spent", 2, C.Text),
		Unspent = ledgerCell(cellsRow, "Unspent", 3, C.Text),
		Kept = ledgerCell(cellsRow, "Kept", 4, RES_MINT),
		Bonus = ledgerCell(cellsRow, "Bonuses", 5, RES_MINT),
	}
	results.LedgerNote = text(ledger, "Small", "", {
		Name = "Note",
		AnchorPoint = Vector2.new(0, 1),
		Position = UDim2.new(0, 10, 1, -6),
		Size = UDim2.new(1, -20, 0, TS(12) + 6),
		TextXAlignment = Enum.TextXAlignment.Center,
		TextWrapped = true,
		RichText = true,
		TextColor3 = C.TextMuted,
	}, 12)

	-- 3. progress: run level (temporary), hero mastery, account level (cosmetic). Three
	-- separate cards and bars; never one merged bar.
	local prog = new("Frame", { Name = "Progress", BackgroundTransparency = 1, LayoutOrder = 3, Size = UDim2.new(1, 0, 0, 84) }, body)
	results.Progress = prog
	results.ProgList = UIKit.list(prog, { FillDirection = Enum.FillDirection.Horizontal, HorizontalAlignment = Enum.HorizontalAlignment.Center, Padding = UDim.new(0, 8), Wraps = true })
	results.RunCard = progressCard(prog, "RunLevel", 1, ColorSequence.new(P.crimson_300, P.crimson_500), P.crimson_400)
	results.MasteryCard = progressCard(prog, "HeroMastery", 2, ColorSequence.new(P.gold_300, P.gold_500), P.gold_400)
	results.AccountCard = progressCard(prog, "AccountLevel", 3, ColorSequence.new(RES_CYAN, RES_CYAN_DARK), RES_CYAN)
	-- the account bar animation (animateAccountXP) works on these
	results.XPMeter = results.AccountCard.Meter
	results.XPText = results.AccountCard.Level
	results.AccountFrame = results.AccountCard.Frame

	-- 4. rewards (new best, arena unlocked, achievements, first-run bonus, cosmetics)
	results.Best = UIKit.Badge(body, "NEW BEST TIME!", "Gold", { LayoutOrder = 4, Visible = false })
	results.Unlocked = text(body, "BodyStrong", "", { LayoutOrder = 5, Size = UDim2.new(1, 0, 0, TS(16) + 6), TextXAlignment = Enum.TextXAlignment.Center, TextColor3 = P.gold_300, Visible = false })
	results.Achievements = text(body, "Small", "", {
		Name = "Achievements",
		LayoutOrder = 6,
		Size = UDim2.new(1, 0, 0, 0),
		TextXAlignment = Enum.TextXAlignment.Center,
		TextYAlignment = Enum.TextYAlignment.Top,
		TextWrapped = true,
		RichText = true,
		TextColor3 = C.Text,
		Visible = false,
	})

	-- 5. RUN DETAILS (collapsed by default, the choice is kept for the session): the
	-- difficulty, curses, daily, bonus breakdown, recent damage, the build and the items
	local toggle = new("TextButton", {
		Name = "RunDetails",
		LayoutOrder = 7,
		Text = "",
		AutoButtonColor = false,
		BackgroundColor3 = C.PanelInset,
		BackgroundTransparency = Theme.Alpha.PanelSoft,
		BorderSizePixel = 0,
		Size = UDim2.new(1, 0, 0, 44),
	}, body)
	UIKit.corner(toggle, 10)
	UIKit.stroke(toggle, P.gold_600, 1, 0.45)
	results.DetailsToggle = toggle
	Icons.Draw(toggle, "info", { Size = 20, AnchorPoint = Vector2.new(0, 0.5), Position = UDim2.new(0, 12, 0.5, 0), Color = P.gold_300 })
	results.DetailsTitle = text(toggle, "Label", UIKit.track("Run details"), { Name = "Title", AnchorPoint = Vector2.new(0, 0.5), Position = UDim2.new(0, 42, 0.5, 0), Size = UDim2.fromOffset(TS(13) * 8, TS(13) + 6), TextXAlignment = Enum.TextXAlignment.Left }, 13)
	results.DetailsSub = text(toggle, "Small", "Build, gold earned and spent, recent damage", { Name = "Sub", AnchorPoint = Vector2.new(0, 0.5), Position = UDim2.new(0, 42 + TS(13) * 8 + 10, 0.5, 0), Size = UDim2.new(1, -(42 + TS(13) * 8 + 10 + 80), 0, TS(12) + 6), TextXAlignment = Enum.TextXAlignment.Left, TextTruncate = Enum.TextTruncate.AtEnd, TextColor3 = C.TextMuted }, 12)
	results.DetailsState = text(toggle, "Caption", "SHOW", { Name = "State", AnchorPoint = Vector2.new(1, 0.5), Position = UDim2.new(1, -14, 0.5, 0), Size = UDim2.fromOffset(64, TS(12) + 6), TextXAlignment = Enum.TextXAlignment.Right, TextColor3 = P.gold_200 }, 12)
	results.Details = text(body, "Small", "", {
		Name = "DetailsText",
		LayoutOrder = 8,
		Size = UDim2.new(1, 0, 0, 0),
		TextWrapped = true,
		RichText = true,
		TextXAlignment = Enum.TextXAlignment.Center,
		TextYAlignment = Enum.TextYAlignment.Top,
		TextColor3 = C.TextMuted,
		Visible = false,
	})
	results.BuildHolder = new("Frame", { Name = "Build", BackgroundTransparency = 1, LayoutOrder = 9, Size = UDim2.new(1, 0, 0, 0), Visible = false }, body)
	results.ItemsHolder = new("Frame", { Name = "ItemsHolder", BackgroundTransparency = 1, LayoutOrder = 10, Size = UDim2.new(1, 0, 0, 0), Visible = false }, body)
	results.DetailsOpen = false
	toggle.Activated:Connect(function()
		results.DetailsOpen = not results.DetailsOpen
		results.Layout()
		if results.DetailsOpen then
			-- bring the opened details into view
			task.defer(function()
				local maxY = math.max(0, body.CanvasSize.Y.Offset - body.Size.Y.Offset)
				body.CanvasPosition = Vector2.new(0, math.min(maxY, toggle.Position.Y.Offset))
			end)
		end
	end)

	-- the scroll hint row (shown only while the body scrolls; see results.MoreHint)
	results.More = text(content, "Caption", UIKit.track("More below"), { Name = "MoreHint", LayoutOrder = 4, Size = UDim2.new(1, 0, 0, MORE_H), TextXAlignment = Enum.TextXAlignment.Center, TextColor3 = P.gold_200, Visible = false }, 11)
	-- NEXT GOAL (RunResult.NextGoal, picked by the server from the settled save): the
	-- reason to play again, pinned just above REPLAY / MAIN MENU so it never scrolls away:
	-- icon, one line, a progress bar (beside the line when wide, under it when narrow)
	local goal = new("Frame", { Name = "NextGoal", BackgroundColor3 = C.PanelInset, BackgroundTransparency = 0.15, BorderSizePixel = 0, LayoutOrder = 5, Size = UDim2.new(1, 0, 0, 0), Visible = false }, content)
	UIKit.corner(goal, 10)
	UIKit.stroke(goal, P.moss_400, 1.5, 0.25)
	results.Goal = goal
	results.GoalIcon = new("Frame", { Name = "Icon", BackgroundTransparency = 1, AnchorPoint = Vector2.new(0, 0.5), Position = UDim2.new(0, 10, 0.5, 0), Size = UDim2.fromOffset(28, 28) }, goal)
	results.GoalText = text(goal, "Small", "", { Name = "Line", RichText = true, TextTruncate = Enum.TextTruncate.AtEnd, TextXAlignment = Enum.TextXAlignment.Left, TextYAlignment = Enum.TextYAlignment.Center })
	results.GoalMeter = UIKit.Meter(goal, {
		Gradient = ColorSequence.new(P.moss_400, P.moss_200),
		TextStyle = "Number",
		TextSize = 11,
		Size = UDim2.fromOffset(160, 16),
	})

	-- actions: REPLAY (same mode) and MAIN MENU, fixed under the body
	local row = new("Frame", { Name = "Buttons", BackgroundTransparency = 1, LayoutOrder = 5, Size = UDim2.new(1, 0, 0, Theme.Size.Button) }, content)
	results.ButtonRow = row
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
			-- "Replay": a private run server keeps the player for the new run (no trip home)
			if not results.InLobby and player:GetAttribute("InRun") then
				Remotes.Get("ReturnToLobby"):FireServer("Replay")
			elseif onRunServer() then
				Remotes.Get("TravelHome"):FireServer("Replay")
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
			elseif onRunServer() then
				Remotes.Get("TravelHome"):FireServer("Go")
			end
			if onRunServer() then
				-- a private run server: its own lobby menu is not where MAIN MENU goes. The
				-- results stay until the travel cover is up (FLOW: no lobby, then a second
				-- countdown, then another loading screen)
				results.Leaving = os.clock()
				results.Replay.SetEnabled(false)
				results.Button.SetEnabled(false)
			else
				hide(results.Overlay, "Results")
			end
		end,
	})
	-- footer: the one countdown, STAY and a quiet REPORT A BUG (the same form as the pause
	-- menu's, opened over the results; the results wait while it is open)
	local footer = new("Frame", { Name = "Footer", BackgroundTransparency = 1, LayoutOrder = 6, Size = UDim2.new(1, 0, 0, 44) }, content)
	results.Footer = footer
	results.FooterList = UIKit.list(footer, { FillDirection = Enum.FillDirection.Horizontal, HorizontalAlignment = Enum.HorizontalAlignment.Center, VerticalAlignment = Enum.VerticalAlignment.Center, Padding = UDim.new(0, 14) })
	results.Timer = text(footer, "Caption", "", { LayoutOrder = 1, Size = UDim2.fromOffset(0, TS(12) + 6), AutomaticSize = Enum.AutomaticSize.X, TextXAlignment = Enum.TextXAlignment.Center })
	-- STAY stops the automatic return / close (the results stay until REPLAY or MAIN MENU)
	local actions = new("Frame", { Name = "Actions", BackgroundTransparency = 1, LayoutOrder = 2, AutomaticSize = Enum.AutomaticSize.X, Size = UDim2.fromOffset(0, 44) }, footer)
	results.Actions = actions
	UIKit.list(actions, { FillDirection = Enum.FillDirection.Horizontal, VerticalAlignment = Enum.VerticalAlignment.Center, Padding = UDim.new(0, 8) })
	results.Stay = UIKit.Button(actions, {
		Kind = "Secondary",
		Title = "STAY",
		Name = "Stay",
		Align = "Center",
		Shadow = false,
		Size = UDim2.fromOffset(110, 44),
		LayoutOrder = 1,
		OnClick = function()
			holdResults()
		end,
	})
	results.Bug = UIKit.Button(actions, {
		Kind = "Secondary",
		Title = "REPORT A BUG",
		Icon = "warning",
		IconSize = 16,
		Align = "Center",
		Shadow = false,
		Size = UDim2.fromOffset(190, 44),
		LayoutOrder = 2,
		OnClick = function()
			holdResults() -- the report takes a while: nothing automatic meanwhile
			BugReportUI.Open()
		end,
	})

	-- a later profile sync carries the settled hero XP (mastery bar fallback)
	Remotes.Get("ProfileSync").OnClientEvent:Connect(function()
		task.defer(function()
			if results.Overlay.Visible and results.Data then
				fillMastery(results.Data)
			end
		end)
	end)

	local function lineCount(str: string, size: number, width: number): number
		local n = 0
		for line in string.gmatch(str .. "\n", "([^\n]*)\n") do
			local plain = string.gsub(line, "<[^>]+>", "")
			n += math.max(1, math.ceil(utf8.len(plain) or #plain) * size * 0.55 / math.max(1, width))
		end
		return n
	end

	local function layoutResults()
		local v = virtualSize()
		local w = tallModalWidth(760)
		m.Panel.Size = UDim2.new(UDim.new(0, w), m.Panel.Size.Y)
		local inner = w - 2 * Theme.Space.XL
		-- phones in landscape: a smaller title, slim tiles without icons, lower buttons
		local slim = UIKit.IsCompact() and not portrait
		local titleSize = TS(slim and 34 or 44)
		results.Title.TextSize = titleSize
		results.Title.Size = UDim2.new(1, 0, 0, titleSize + 6)
		results.Arena.Position = UDim2.fromOffset(0, titleSize + 10)
		results.Hero.Position = UDim2.fromOffset(0, titleSize + TS(13) + 18)
		local tileH = slim and 72 or 104
		local btnH = slim and 48 or Theme.Size.Button
		local headH = math.max(84, titleSize + 6 + TS(13) + 8 + TS(15) + 8)
		head.Size = UDim2.new(1, 0, 0, headH)
		results.TitleCol.Size = UDim2.fromOffset(math.max(160, math.min(480, inner - 96)), headH)
		-- four tiles in one row (stable widths), two rows of two when very narrow
		local cols = inner >= 360 and 4 or 2
		local tileW = math.floor((inner - (cols - 1) * 8) / cols)
		for _, tile in ipairs(grid:GetChildren()) do
			if tile:IsA("GuiObject") then
				tile.Size = UDim2.fromOffset(tileW, tileH)
				local glyph = tile:FindFirstChild("TileIcon")
				if glyph and glyph:IsA("GuiObject") then
					glyph.Visible = not slim
				end
				local value = tile:FindFirstChild("Value")
				if value and value:IsA("GuiObject") then
					value.Position = UDim2.fromOffset(4, slim and 8 or 42)
				end
			end
		end
		local rows = math.ceil(4 / cols)
		grid.Size = UDim2.fromOffset(inner, rows * tileH + (rows - 1) * 8)
		-- the gold ledger: five cells in a row, or 3 + 2 when narrow
		local lcols = inner >= 560 and 5 or 3
		local cellW = math.floor((inner - 16 - (lcols - 1) * 6) / lcols)
		local cellH = TS(20) + 6 + TS(11) + 6
		for _, cell in pairs(results.LedgerCells) do
			cell.Frame.Size = UDim2.fromOffset(cellW, cellH)
		end
		local lrows = math.ceil(5 / lcols)
		local rowsH = lrows * cellH + (lrows - 1) * 6
		results.LedgerRow.Size = UDim2.new(1, -16, 0, rowsH)
		results.LedgerCells.Unspent.Caption.Text = UIKit.track(results.UnspentLong and lcols == 5 and results.UnspentLong or results.UnspentShort or "Unspent")
		local noteSize = results.LedgerNote.TextSize
		local noteLines = lineCount(results.LedgerNote.Text, noteSize, inner - 20)
		local noteH = noteLines * (noteSize + 4) + 2
		results.LedgerNote.Size = UDim2.new(1, -20, 0, noteH)
		results.Ledger.Size = UDim2.new(1, 0, 0, 8 + rowsH + 6 + noteH + 8)
		-- progress cards: three side by side, stacked when narrow
		local pcols = inner >= 520 and 3 or 1
		local cardW = math.floor((inner - (pcols - 1) * 8) / pcols)
		local cardH = 8 + TS(13) + 6 + TS(12) + 6 + 16 + 12
		for _, card in ipairs({ results.RunCard, results.MasteryCard, results.AccountCard }) do
			card.Frame.Size = UDim2.fromOffset(cardW, cardH)
			card.Gain.Position = UDim2.fromOffset(12, TS(13) + 14)
		end
		local prow = math.ceil(3 / pcols)
		results.Progress.Size = UDim2.new(1, 0, 0, prow * cardH + (prow - 1) * 8)
		-- RUN DETAILS row and its contents
		local open = results.DetailsOpen == true
		local togH = slim and 40 or 44
		results.DetailsToggle.Size = UDim2.new(1, 0, 0, togH)
		results.DetailsSub.Visible = inner >= 460
		results.DetailsState.Text = open and "HIDE" or "SHOW"
		local lineH = TS(Theme.TextSize.Small) + 4
		local recent = results.Recent :: { string }?
		local detailText = results.DetailsBase or ""
		if recent and #recent > 0 then
			local reviewRows = {}
			local step = slim and 2 or 1
			for i = 1, #recent, step do
				table.insert(reviewRows, slim and table.concat(recent, "      ", i, math.min(i + 1, #recent)) or recent[i])
			end
			detailText ..= (detailText ~= "" and "\n" or "") .. string.format('<font color="%s"><b>RECENT DAMAGE</b></font> (latest first)\n', hex(P.crimson_300)) .. table.concat(reviewRows, "\n")
		end
		results.Details.Text = detailText
		results.Details.Visible = open and detailText ~= ""
		results.Details.Size = UDim2.new(1, 0, 0, lineCount(detailText, results.Details.TextSize, inner) * (results.Details.TextSize + 5) + 6)
		results.BuildHolder.Visible = open and results.HasBuild == true
		results.ItemsHolder.Visible = open and results.HasItems == true
		-- the pinned NEXT GOAL row (above the buttons): one row with the bar on the right
		-- when there is room, otherwise the bar under the line
		local bw = math.clamp(math.floor((inner - 12) / 2), 140, 320)
		results.ButtonRow.Size = UDim2.new(1, 0, 0, btnH)
		results.Replay.Instance.Size = UDim2.fromOffset(bw, btnH)
		results.Button.Instance.Size = UDim2.fromOffset(bw, btnH)
		results.ButtonRow.LayoutOrder = 6
		results.Footer.LayoutOrder = 7
		local goalH = 0
		if results.Goal.Visible then
			local meterShown = results.GoalMeter.Frame.Visible
			local oneRow = inner >= 420 or not meterShown
			local textX = 46
			if oneRow then
				goalH = math.max(slim and 34 or 40, lineH + 14)
				local barW = meterShown and math.clamp(math.floor(inner * 0.3), 120, 200) or 0
				results.GoalText.Position = UDim2.fromOffset(textX, 0)
				results.GoalText.Size = UDim2.new(1, -(textX + barW + (meterShown and 20 or 10)), 1, 0)
				results.GoalMeter.Frame.AnchorPoint = Vector2.new(1, 0.5)
				results.GoalMeter.Frame.Position = UDim2.new(1, -10, 0.5, 0)
				results.GoalMeter.Frame.Size = UDim2.fromOffset(barW, 16)
			else
				goalH = 8 + lineH + 4 + 16 + 8
				results.GoalText.Position = UDim2.fromOffset(textX, 6)
				results.GoalText.Size = UDim2.new(1, -(textX + 10), 0, lineH + 2)
				results.GoalMeter.Frame.AnchorPoint = Vector2.new(0, 0)
				results.GoalMeter.Frame.Position = UDim2.fromOffset(textX, 8 + lineH + 4)
				results.GoalMeter.Frame.Size = UDim2.new(1, -(textX + 10), 0, 16)
			end
			-- the extra line ("about 2 more runs") only where it fits beside the goal
			results.GoalText.Text = (oneRow and inner < 600) and results.GoalShort or results.GoalLong
			results.Goal.Size = UDim2.new(1, 0, 0, goalH)
		end
		local bodyH = stackHeight(body, 10)
		-- footer: countdown, STAY and REPORT A BUG side by side, stacked when narrow
		local bugH = slim and 40 or 44
		results.Bug.Instance.Size = UDim2.fromOffset(TS(12) * 8 + 74, bugH)
		results.Stay.Instance.Size = UDim2.fromOffset(TS(12) * 4 + 62, bugH)
		results.Actions.Size = UDim2.fromOffset(0, bugH)
		local stacked = inner < 470
		results.FooterList.FillDirection = stacked and Enum.FillDirection.Vertical or Enum.FillDirection.Horizontal
		results.FooterList.Padding = UDim.new(0, stacked and 4 or 14)
		local footH = stacked and (TS(12) + 6 + 4 + bugH) or bugH
		results.Footer.Size = UDim2.new(1, 0, 0, footH)
		local fixed = headH + 10 + btnH + footH + 4 * 10 + 2 * Theme.Space.XL + 8 + (goalH > 0 and goalH + 10 or 0)
		-- the scroll area may shrink a little for the pinned NEXT GOAL (the tiles still show)
		local minRoom = goalH > 0 and 96 or 140
		local room = math.max(minRoom, v.Y - 24 - fixed)
		local scrolls = bodyH > room
		if scrolls then
			room = math.max(minRoom, room - MORE_H - 10) -- the MORE BELOW row and its gap
		end
		results.More.Visible = scrolls
		local h = math.min(bodyH, room)
		if bodyH > room then
			-- the scroll area ends between two blocks, never through a line of text
			local parts = {}
			for _, ch in ipairs(body:GetChildren()) do
				if ch:IsA("GuiObject") and ch.Visible then
					table.insert(parts, ch)
				end
			end
			table.sort(parts, function(a, b)
				return a.LayoutOrder < b.LayoutOrder
			end)
			local y, best = 0, 0
			for _, ch in ipairs(parts) do
				y += ch.Size.Y.Offset
				if y > room then
					break
				end
				best = y
				y += 10
			end
			if best >= minRoom then
				h = best
			end
		end
		body.Size = UDim2.new(1, 0, 0, h)
		body.CanvasSize = UDim2.fromOffset(0, bodyH)
		body.ScrollBarThickness = bodyH > h + 1 and 4 or 0
		results.MoreHint()
	end
	-- "MORE BELOW" under the body while it scrolls: its own row, so it never covers a
	-- line; dimmed once scrolled to the end; event-driven
	function results.MoreHint()
		local hidden = body.CanvasSize.Y.Offset - body.Size.Y.Offset - body.CanvasPosition.Y
		results.More.TextTransparency = hidden > 8 and 0 or 0.65
	end
	body:GetPropertyChangedSignal("CanvasPosition"):Connect(results.MoreHint)
	results.Layout = layoutResults
	onRelayout(layoutResults)
end

local function safeNumber(x: any): number
	local n = tonumber(x) or 0
	if n ~= n or n == math.huge or n == -math.huge then
		return 0
	end
	return n
end

--[[
	The gold ledger, from RunResult (server definitions, GoldSystem.SettleRun):
	  Earned (gross)  = GoldEarned + GoldSpent: all run gold collected (portal bonus included)
	  Spent           = GoldSpent: chests and shrines bought during the run
	  Unspent         = GoldEarned: the run purse at the end ("gold at defeat" on a loss)
	  Kept            = Gold: unspent x GoldRetention (all of it through the portal)
	  Lost            = GoldLost
	  Bonuses         = GoldSurvival + FirstRun.Bonus: paid outside the purse, always kept
]]
local function fillLedger(data: any)
	local unspent = math.floor(safeNumber(data.GoldEarned or data.Gold))
	local spent = math.floor(safeNumber(data.GoldSpent))
	local kept = math.floor(safeNumber(data.Gold))
	local lost = math.floor(safeNumber(data.GoldLost))
	local survival = math.floor(safeNumber(data.GoldSurvival))
	local first = type(data.FirstRun) == "table" and math.floor(safeNumber(data.FirstRun.Bonus)) or 0
	local bonus = math.max(0, survival) + math.max(0, first)
	local rate = data.GoldRetention ~= nil and safeNumber(data.GoldRetention) or (unspent > 0 and kept / unspent or 1)
	local lostRun = not data.Won and not data.Portal
	local cells = results.LedgerCells
	cells.Earned.Value.Text = UIKit.formatNumber(unspent + spent)
	cells.Earned.Caption.Text = UIKit.track("Earned")
	cells.Spent.Value.Text = UIKit.formatNumber(spent)
	cells.Spent.Caption.Text = UIKit.track("Spent")
	cells.Unspent.Value.Text = UIKit.formatNumber(unspent)
	results.UnspentLong = lostRun and "Gold at defeat" or "Unspent"
	results.UnspentShort = lostRun and "At defeat" or "Unspent"
	cells.Kept.Value.Text = UIKit.formatNumber(kept)
	cells.Kept.Caption.Text = UIKit.track(rate >= 1 and "Kept · all" or string.format("Kept · %d%%", math.floor(rate * 100 + 0.5)))
	cells.Bonus.Value.Text = (bonus > 0 and "+" or "") .. UIKit.formatNumber(bonus)
	cells.Bonus.Caption.Text = UIKit.track("Bonuses")
	results.LedgerKept = kept
	local banked = kept + bonus
	local note = string.format('Added to your gold: <font color="%s"><b>%s</b></font>', hex(RES_MINT), UIKit.formatNumber(banked))
	if bonus > 0 then
		note ..= string.format(" (%s kept + %s bonuses)", UIKit.formatNumber(kept), UIKit.formatNumber(bonus))
	end
	if lost > 0 then
		note ..= string.format('  ·  <font color="%s">%s lost</font> on %s', hex(P.crimson_300), UIKit.formatNumber(lost), data.Abandoned and "leaving early" or "defeat")
	elseif data.Portal then
		note ..= "  ·  portal: all unspent gold kept"
	end
	results.LedgerNote.Text = note
end

local function setCard(card: { [string]: any }, title: string, level: string, gain: string, share: number?, barText: string?)
	card.Title.Text = UIKit.track(title)
	card.Level.Text = level
	card.Gain.Text = gain
	card.Meter.Frame.Visible = share ~= nil
	if share ~= nil then
		card.Meter.Set(math.clamp(share, 0, 1), barText)
	end
end

-- Hero Mastery card. RunResult.Mastery = { Hero, Gained, From, To } (+ Into, Need when the
-- server sends them); otherwise the bar comes from the synced profile's hero XP and is
-- shown only when it agrees with the level the server reported.
function fillMastery(data: any)
	local mst = type(data.Mastery) == "table" and data.Mastery or nil
	local heroId = mst and mst.Hero or data.CharacterId
	local hero = CharacterData.Characters[heroId]
	local title = string.format("%s mastery", hero and hero.Name or "Hero")
	if not mst then
		setCard(results.MasteryCard, title, "", data.DevRun and "Not recorded (DEV run)" or "No mastery XP this run", nil)
		return
	end
	local from, to = math.floor(safeNumber(mst.From)), math.floor(safeNumber(mst.To))
	local levelText = from ~= to and string.format('<font color="%s">Level %d → %d</font>', hex(RES_MINT), from, to) or ("Level " .. to)
	local gain = string.format('<font color="%s"><b>+%s XP</b></font>', hex(P.gold_200), UIKit.formatNumber(math.floor(safeNumber(mst.Gained))))
	local into, need = tonumber(mst.Into), tonumber(mst.Need)
	if not (into and need) then
		local heroes = profile and type(profile.Heroes) == "table" and profile.Heroes or nil
		local h = heroes and type(heroes[heroId]) == "table" and heroes[heroId] or nil
		if h then
			local lvl, i, n = masteryFor(safeNumber(h.XP))
			if lvl == to then
				into, need = i, n
			end
		end
	end
	if into and need and need > 0 then
		setCard(results.MasteryCard, title, levelText, gain, into / need, string.format("%s / %s", UIKit.formatNumber(math.floor(into)), UIKit.formatNumber(math.floor(need))))
	elseif to >= Config.HeroMastery.MaxLevel then
		setCard(results.MasteryCard, title, levelText, gain, 1, "MAX LEVEL")
	else
		setCard(results.MasteryCard, title, levelText, gain, nil)
	end
end

--[[
	The three progress cards: RUN LEVEL (temporary, this run only; the hero's XP bar at the
	end), HERO MASTERY (per hero, permanent), ACCOUNT LEVEL (cosmetic rewards only).
]]
local function fillProgress(data: any)
	-- run level: RunResult.Level; the bar from RunXP / RunXPNeed when the server sends
	-- them, else from the player's run attributes (set by RunManager, reset only when the
	-- next run starts) when they belong to this result
	local lvl = math.floor(safeNumber(data.Level))
	local xp, need = tonumber(data.RunXP), tonumber(data.RunXPNeed)
	if not (xp and need) and player:GetAttribute("Level") == lvl then
		xp, need = tonumber(player:GetAttribute("XP")), tonumber(player:GetAttribute("XPNeeded"))
	end
	local runShare = (xp and need and need > 0) and xp / need or nil
	setCard(results.RunCard, "Run level", "Level " .. lvl, "This run only: resets next run", runShare,
		runShare and string.format("%s / %s", UIKit.formatNumber(math.floor(xp :: number)), UIKit.formatNumber(math.floor(need :: number))) or nil)
	fillMastery(data)
	-- account level (cosmetic)
	local a = type(data.Account) == "table" and data.Account or nil
	if a then
		local from, to = math.floor(safeNumber(a.From)), math.floor(safeNumber(a.To))
		local levelText = from ~= to and string.format('<font color="%s">Level %d → %d</font>', hex(RES_MINT), from, to) or ("Level " .. to)
		local gain = string.format('<font color="%s"><b>+%s XP</b></font>  ·  cosmetic rewards only', hex(RES_CYAN), UIKit.formatNumber(math.floor(safeNumber(a.Gained))))
		local an = safeNumber(a.Need)
		if an > 0 then
			setCard(results.AccountCard, "Account level", levelText, gain, safeNumber(a.Into) / an, string.format("%s / %s", UIKit.formatNumber(math.floor(safeNumber(a.Into))), UIKit.formatNumber(math.floor(an))))
		else
			setCard(results.AccountCard, "Account level", levelText, gain, 1, "MAX LEVEL")
		end
	else
		setCard(results.AccountCard, "Account level", "", data.DevRun and "Not recorded (DEV run)" or "Cosmetic progression", nil)
	end
end

-- RUN DETAILS text: difficulty, curses, daily, bonus breakdown (recent damage is added by
-- results.Layout, two hits per line on landscape phones).
local function fillDetails(data: any)
	local lines = {}
	local diff = tostring(data.Difficulty or "Standard")
	table.insert(lines, string.format('<font color="%s"><b>DIFFICULTY</b></font>  %s', hex(P.gold_300), diff))
	local curses = type(data.Curses) == "table" and data.Curses or {}
	if #curses > 0 then
		local names = {}
		for _, id in ipairs(curses) do
			local def = CurseData.Curses[id]
			table.insert(names, def and def.Name or tostring(id))
		end
		table.insert(lines, string.format('<font color="%s"><b>CURSES</b></font>  %s  ·  %s gold', hex(P.crimson_300), table.concat(names, " · "), CurseData.GoldText(tonumber(data.CurseGold) or CurseData.GoldMult(curses))))
	end
	local d = type(data.Daily) == "table" and data.Daily or nil
	if d then
		if d.Scored then
			table.insert(lines, string.format('<font color="%s"><b>DAILY · SCORED</b></font>  %s%s', hex(P.gold_300), tostring(d.Text or ""), d.NewBest and "  ·  NEW DAILY BEST" or ""))
		else
			table.insert(lines, string.format('<font color="%s"><b>DAILY · PRACTICE</b></font>  %s  (not scored)', hex(P.gold_300), tostring(d.Text or "")))
		end
	end
	-- gold: where the numbers come from
	local unspent = math.floor(safeNumber(data.GoldEarned or data.Gold))
	local spent = math.floor(safeNumber(data.GoldSpent))
	table.insert(lines, string.format('<font color="%s"><b>GOLD</b></font>  %s earned · %s spent on chests and shrines · %s left at the end', hex(P.gold_300),
		UIKit.formatNumber(unspent + spent), UIKit.formatNumber(spent), UIKit.formatNumber(unspent)))
	if data.Portal then
		table.insert(lines, "Earned includes the portal bonus for the stages cleared")
	end
	local survival = math.floor(safeNumber(data.GoldSurvival))
	if survival > 0 then
		table.insert(lines, string.format("Survival bonus +%s gold · %d min (always kept)", UIKit.formatNumber(survival), math.min(Config.Gold.SurvivalMaxMinutes or 30, math.floor(safeNumber(data.Time) / 60))))
	end
	local first = type(data.FirstRun) == "table" and math.floor(safeNumber(data.FirstRun.Bonus)) or 0
	if first > 0 then
		table.insert(lines, string.format("First run bonus +%s gold (one time)", UIKit.formatNumber(first)))
	end
	if data.DevRun then
		table.insert(lines, "DEV tools were used: nothing public was recorded")
	end
	results.DetailsBase = table.concat(lines, "\n")
end

-- The NEXT GOAL row (display only; the server picked it from the settled save).
local function fillGoal(data: any)
	local g = type(data.NextGoal) == "table" and data.NextGoal or nil
	local goalText = g and type(g.Text) == "string" and g.Text or nil
	results.Goal.Visible = goalText ~= nil
	if not g or not goalText then
		return
	end
	for _, ch in ipairs(results.GoalIcon:GetChildren()) do
		ch:Destroy()
	end
	local icon = type(g.Icon) == "string" and g.Icon or "flag"
	local heroId = string.match(icon, "^hero:(.+)$")
	local iconOpts = { Size = 28, Back = C.PanelInset }
	if heroId and CharacterData.Characters[heroId] then
		Icons.Character(results.GoalIcon, heroId, iconOpts)
	else
		Icons.Draw(results.GoalIcon, Icons.Has(icon) and icon or "flag", iconOpts)
	end
	local sub = type(g.Sub) == "string" and g.Sub ~= "" and string.format('  <font color="%s">· %s</font>', hex(C.TextMuted), g.Sub) or ""
	results.GoalLong = string.format('<font color="%s"><b>NEXT GOAL</b></font>  %s%s', hex(P.moss_200), goalText, sub)
	results.GoalShort = string.format('<font color="%s"><b>NEXT GOAL</b></font>  %s', hex(P.moss_200), goalText)
	results.GoalText.Text = results.GoalLong
	local share = math.clamp(tonumber(g.Progress) or 0, 0, 1)
	local barText = type(g.ProgressText) == "string" and g.ProgressText or nil
	results.GoalMeter.Frame.Visible = barText ~= nil
	if barText then
		results.GoalMeter.Set(share, barText)
	end
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
		results.HasBuild = false
		return
	end
	results.HasBuild = true
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

-- Account XP bar: fills up from where the run started; a level up fills it, bursts, and
-- carries on from 0. Cancelled by a newer result (token).
local function animateAccountXP(data: any)
	local a = type(data.Account) == "table" and data.Account or nil
	local meter = results.XPMeter
	local need = a and tonumber(a.Need) or 0
	results.XPToken = (results.XPToken or 0) + 1
	if not a or need <= 0 or (ClientSettings.Reduced() or ClientPerformance.Reduced()) then
		return
	end
	local token = results.XPToken
	local into = math.clamp((tonumber(a.Into) or 0) / need, 0, 1)
	local levelled = (tonumber(a.To) or 1) > (tonumber(a.From) or 1)
	local start = levelled and 0 or math.clamp(((tonumber(a.Into) or 0) - (tonumber(a.Gained) or 0)) / need, 0, into)
	local nv = Instance.new("NumberValue")
	nv.Value = start
	nv.Changed:Connect(function(v)
		if token == results.XPToken and meter.Frame.Parent then
			meter.Set(v)
		end
	end)
	meter.Set(start)
	task.delay(1.0, function()
		if token ~= results.XPToken or not results.Overlay.Visible then
			nv:Destroy()
			return
		end
		if levelled then
			UIAnim.Tween(nv, 0.7, { Value = 1 }, Enum.EasingStyle.Quad, Enum.EasingDirection.In).Completed:Wait()
			if token ~= results.XPToken then
				nv:Destroy()
				return
			end
			-- level up: flash, ring and sparks on the bar, the text punches
			meter.Set(1)
			UIAnim.SweepOnce(meter.Frame, P.ivory_100, 0.4, 0.1)
			UIAnim.Ring(results.AccountFrame, UDim2.new(1, -40, 0, 30), RES_CYAN, 120, 0.6)
			UIAnim.Sparks(results.AccountFrame, UDim2.new(1, -40, 0, 30), RES_CYAN, 12, 70, 0.6)
			UIAnim.Punch(results.XPText, 0.12)
			task.wait(0.2)
			nv.Value = 0
		end
		if token == results.XPToken then
			UIAnim.Tween(nv, 0.7, { Value = into }, Enum.EasingStyle.Quart).Completed:Wait()
		end
		nv:Destroy()
		if token == results.XPToken then
			meter.Set(into)
			UIAnim.SweepOnce(meter.Frame, P.ivory_100, 0.4, 0.5)
		end
	end)
end

local function onRunResult(data)
	closeOffer()
	hide(revive.Overlay, "Revive")
	hide(pause.Overlay, "Pause")
	Tutorial.Clear()
	pendingReplay = nil
	results.Data = data
	-- InLobby: the player left through a portal and is back at the menu already; the
	-- panel then sits over the lobby until closed (or its timer runs out)
	results.InLobby = data.InLobby == true
	-- the return flow of this results screen (STAY, MAIN MENU on a run server)
	results.Held = false
	results.Leaving = nil
	results.ReturnedAt = nil
	results.Button.SetEnabled(true)
	results.Mode = type(data.Mode) == "string" and data.Mode or "Solo"
	fillLedger(data)
	fillDetails(data)
	-- recent damage, for RUN DETAILS (the cause of death is not a headline: owner request)
	local history = type(data.DamageHistory) == "table" and data.DamageHistory or {}
	local recent = {}
	if not data.Won and not data.Portal and not data.Abandoned then
		for i = #history, math.max(1, #history - 5), -1 do
			local hit = history[i]
			if type(hit) == "table" and type(hit.Cause) == "string" and type(hit.Damage) == "number"
				and hit.Damage > 0 and hit.Damage < math.huge and type(hit.Time) == "number" and hit.Time == hit.Time then
				local age = math.max(0, (tonumber(data.Time) or 0) - hit.Time)
				if age <= 15 then
					table.insert(recent, string.format("%s · -%s HP · %ds ago", string.sub(hit.Cause, 1, 70), UIKit.formatNumber(math.ceil(hit.Damage)), math.floor(age)))
				end
			end
		end
	end
	results.Recent = recent
	-- portal returns before WinMinStages stages are a safe escape, not a win
	-- Abandoned: left from the pause menu's MAIN MENU (counted as a loss)
	results.Title.Text = data.Won and "VICTORY!" or (data.Portal and "ESCAPED" or (data.Abandoned and "RUN ENDED" or "DEFEATED"))
	results.Title.TextColor3 = (data.Won or data.Portal) and P.gold_300 or P.crimson_300
	results.MedalStroke.Color = (data.Won or data.Portal) and P.gold_400 or P.crimson_400
	local cleared = tonumber(data.StagesCleared) or 0
	local heroId = type(data.CharacterId) == "string" and data.CharacterId or CharacterData.Default
	local heroDef = CharacterData.Characters[heroId]
	-- "KNIGHT · FOREST · STAGE 1" (Endless: "ENDLESS STAGE 9")
	local stageText = (data.Endless and "Endless stage " or "Stage ") .. tostring(tonumber(data.Stage) or 1)
	results.Arena.Text = UIKit.track(string.format("%s · %s · %s", heroDef and heroDef.Name or heroId, tostring(data.Arena), stageText))
	-- the hero who played
	for _, ch in ipairs(results.Medal:GetChildren()) do
		if ch:IsA("Frame") and ch ~= results.BossBadge then
			ch:Destroy()
		end
	end
	local classIcon = Icons.Character(results.Medal, heroId, { Size = 48, AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.5), Back = P.slate_950 })
	-- the hero's painted bust in the medal (the class icon while it loads / without one)
	ArtImage.RoundPortrait(results.Medal, ArtImage.Portrait(heroId), { classIcon })
	-- fell in a boss fight: that boss on the medal's corner
	local badge = results.BossBadge
	local bossKey = ArtImage.Boss(results.LastBoss or "ScorpionQueen")
	local showBoss = data.BossFight == true and not data.Won and ArtImage.Image(bossKey) ~= nil
	badge.Visible = showBoss
	if showBoss then
		if results.BossArt then
			ArtImage.Set(results.BossArt, bossKey)
		else
			results.BossArt = ArtImage.Place(badge, bossKey, { AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.5), Size = UDim2.fromScale(1.25, 1.25), ZIndex = 7 })
		end
	end
	-- the backdrop: victory, defeat, or the neutral hall for an escape / a run left early
	local back = results.Backdrop
	if back then
		local key = data.Won and "screens/victory" or ((data.Portal or data.Abandoned) and "screens/results_bg" or "screens/defeat")
		if not ArtImage.Image(key) then
			key = "screens/results_bg"
		end
		local image = ArtImage.Image(key)
		back.Visible = image ~= nil
		results.Overlay:SetAttribute("BackdropTransparency", image and 0.5 or Theme.Alpha.Backdrop)
		if image then
			back.Image = image
			if not results.Overlay.Visible and not (ClientSettings.Reduced() or ClientPerformance.Reduced()) then
				back.ImageTransparency = 1
				UIAnim.Tween(back, 0.5, { ImageTransparency = 0 })
			else
				back.ImageTransparency = 0
			end
		end
	end
	-- the worn portrait frame (level track)
	local framed = Cosmetics.Frame(results.Medal, profile and profile.Frame or "")
	results.MedalStroke.Transparency = framed and 1 or 0.05
	fillProgress(data)
	fillGoal(data)
	local damage = tonumber(data.Damage) or 0
	results.Hero.Text = string.format("%s damage dealt", UIKit.formatNumber(math.floor(damage)))
		.. (type(data.Score) == "number" and ((data.Endless and "  ·  Endless score " or "  ·  Score ") .. UIKit.formatNumber(data.Score)) or "")
	-- numbers
	results.Stages.Text = tostring(cleared)
	results.Time.Text = formatTime(data.Time)
	local queens = tonumber(data.BossKills) or 0
	if queens > 0 then
		results.Boss.Text = tostring(queens)
		results.BossCaption.Text = UIKit.track(queens == 1 and "Boss slain" or "Bosses slain")
	elseif data.BossFight then
		results.Boss.Text = "-"
		results.BossCaption.Text = UIKit.track("Fell to the boss")
	else
		results.Boss.Text = "-"
		results.BossCaption.Text = UIKit.track("Boss not reached")
	end
	results.Best.Text = (data.NewBest and data.NewBestStage) and "NEW BEST TIME AND STAGE!"
		or (data.NewBestStage and "NEW BEST STAGE!" or (data.NewBest and "NEW BEST TIME!" or "NEW BEST LEVEL!"))
	data.NewBest = data.NewBest == true or data.NewBestStage == true or data.NewBestLevel == true
	results.Best.Visible = data.NewBest == true
	results.Unlocked.Visible = data.Unlocked ~= nil
	results.Unlocked.Text = data.Unlocked and ("Unlocked: " .. data.Unlocked .. " arena!") or ""
	local earned = type(data.Achievements) == "table" and data.Achievements or {}
	local lines = {}
	for _, a in ipairs(earned) do
		table.insert(lines, string.format('<font color="%s"><b>ACHIEVEMENT · %s</b></font>  %s', hex(P.gold_300), string.upper(tostring(a.Name)), tostring(a.Reward or "")))
	end
	-- the first run's one-time welcome bonus (server-paid, Config.FirstRun.BonusGold)
	local firstBonus = type(data.FirstRun) == "table" and tonumber(data.FirstRun.Bonus) or nil
	if firstBonus and firstBonus == firstBonus and firstBonus > 0 and firstBonus < math.huge then
		table.insert(lines, 1, string.format('<font color="%s"><b>FIRST RUN BONUS</b></font>  +%s gold', hex(P.gold_300), UIKit.formatNumber(math.floor(firstBonus))))
	end
	-- account level rewards are cosmetic (frames, rings): never shown as combat upgrades
	local a = type(data.Account) == "table" and data.Account or nil
	if a and type(a.Rewards) == "table" and #a.Rewards > 0 then
		local r = {}
		for _, name in ipairs(a.Rewards) do
			table.insert(r, tostring(name))
		end
		table.insert(lines, string.format('<font color="%s"><b>COSMETIC UNLOCKED</b></font>  %s  (wear it in ACCOUNT LEVEL)', hex(RES_CYAN), table.concat(r, " · ")))
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
	results.HasItems = #runItems > 0
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
	local canReplay = replayState()
	results.Replay.SetEnabled(canReplay)
	UIKit.FocusIfGamepad(canReplay and results.Replay.Instance or results.Button.Instance)
	if deps.Audio then
		if data.Won then
			pcall(deps.Audio.Play, "Victory")
		elseif not data.Portal then
			pcall(deps.Audio.Play, "ResultsLose") -- a defeat or a run left early
		end
	end
	-- a short, contained entrance (guide: 180-240 ms panels, no bouncy type): the title
	-- drops in, the medal turns, the tiles land in order and their numbers count up
	local reduced = ClientSettings.Reduced() or ClientPerformance.Reduced()
	local good = data.Won or data.Portal
	UIAnim.Pop(results.Title, 0.1, reduced and 1.2 or 1.6)
	if not reduced and good then
		task.delay(0.3, function()
			if results.Overlay.Visible then
				UIAnim.Sparks(results.TitleCol, UDim2.new(0, 120, 0, 28), P.gold_200, 14, 120, 0.7)
				UIAnim.Ring(results.TitleCol, UDim2.new(0, 120, 0, 28), P.gold_300, 200, 0.6)
			end
		end)
	end
	animateAccountXP(data)
	if not reduced then
		local medal = results.Medal :: GuiObject
		medal.Rotation = -160
		UIAnim.Pop(medal, 0.05, 0.3)
		task.delay(0.05, function()
			UIAnim.Tween(medal, 0.55, { Rotation = 0 }, Enum.EasingStyle.Back)
		end)
		for i, label in ipairs({ results.Time, results.Kills, results.Stages, results.Boss }) do
			local tile = label and label.Parent
			if tile and tile:IsA("GuiObject") then
				UIAnim.Pop(tile, 0.3 + 0.1 * i, 0.3)
			end
		end
	end
	-- the numbers count up one after another
	local clockText = function(n: number): string
		return formatTime(n)
	end
	UIAnim.CountTo(results.Time, 0, tonumber(data.Time) or 0, clockText, 0.9)
	UIAnim.CountTo(results.Kills, 0, tonumber(data.Kills) or 0, UIKit.formatNumber, 0.9)
	UIAnim.CountTo(results.Stages, 0, cleared, "%d", 0.6)
	UIAnim.CountTo(results.LedgerCells.Kept.Value, 0, results.LedgerKept or 0, UIKit.formatNumber, 0.9)
	if data.NewBest then
		-- new best: the badge pops with a starburst
		UIAnim.Pop(results.Best, 1.5, 0.3)
		UIAnim.Punch(results.Time, 0.3)
		if not reduced then
			task.delay(1.55, function()
				local panel = results.Modal.Panel :: Frame
				local best = results.Best :: GuiObject
				if not (results.Overlay.Visible and best.Visible) then
					return
				end
				local k = panel.AbsoluteSize.X / math.max(1, panel.Size.X.Offset)
				local c = (best.AbsolutePosition - panel.AbsolutePosition + best.AbsoluteSize / 2) / math.max(0.01, k)
				local at = UDim2.fromOffset(c.X, c.Y)
				UIAnim.Sparks(panel, at, P.gold_200, 16, 110, 0.8)
				UIAnim.Ring(panel, at, P.gold_300, 200, 0.6)
			end)
		end
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
		if bad then
			-- a toast when it starts (run or lobby); the lobby keeps the line in MORE
			UIBuilder.Toast(saveNotice.Text.Text .. ". We'll keep trying.", P.crimson_300)
		elseif not bad and (was == "failing") then
			UIBuilder.Toast("Saving works again. Your progress is safe.", P.moss_300)
		end
	end
	-- never over the lobby: session notices stay out of the home screen's composition (the
	-- toast above says it once when it starts; MenuMore lists it as a row while it lasts)
	local shown = false
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
		-- server clock (ChoiceProtectedUntil), frozen while ChoiceTimerPaused
		levelUp.Sub.Text = offerHint or levelUp.SubText or "PICK ONE"
		levelUp.Pill.SetText(Choice.choicePillText(Choice.choiceSecondsLeft(), virtualSize().X < 520))
	end
	if revive.Overlay.Visible then
		local left = math.max(0, reviveDeadline - os.clock())
		revive.Timer.Text = UIKit.track(string.format("Offer ends in %ds", math.ceil(left)))
		revive.Meter.Set(left / reviveSeconds)
		if left <= 0 then
			hide(revive.Overlay, "Revive")
		end
	end
	TravelOverlay.SetResultsOpen(results.Overlay.Visible)
	if results.Overlay.Visible then
		local left = math.max(0, math.ceil(resultsDeadline - os.clock()))
		local canReplay, why = replayState()
		local covered = TravelOverlay.Covering() -- the server is sending us to the main lobby
		if results.Leaving or covered then
			canReplay = false
		end
		if results.Replay.IsEnabled() ~= canReplay then
			results.Replay.SetEnabled(canReplay)
			if canReplay then
				UIAnim.Bump(results.Replay.Face, 0.08) -- REPLAY just became available
			end
		end
		-- why REPLAY is off goes on the timer line (inside the button it would truncate)
		local tail = (not canReplay and why ~= "" and not results.Leaving and not covered) and ("  ·  " .. why) or ""
		local reporting = BugReportUI.IsOpen()
		if reporting then
			holdResults() -- a bug report is never cut off by a timer or a teleport
		end
		-- one countdown: a private run server's trip home (TravelHomeIn) when one runs
		local homeIn = player:GetAttribute("TravelHomeIn")
		results.Stay.Instance.Visible = not results.Held and not results.Leaving and not covered
		if results.Leaving or covered then
			-- the results stay under the travel cover; the run server's own lobby menu is
			-- never shown as the destination
			results.Timer.Text = UIKit.track("Going to the main lobby…")
			if not covered and results.Leaving and os.clock() - results.Leaving > 4 then
				-- the trip did not start (or failed: the server said why): this server's lobby
				results.Leaving = nil
				results.Button.SetEnabled(true)
				hide(results.Overlay, "Results")
			end
		elseif results.Held then
			if not inRun and not results.InLobby then
				results.InLobby = true -- back in the lobby: the panel stays over the menu
			end
			results.Timer.Text = UIKit.track("Stays open until you choose" .. tail)
			if inRun and results.InLobby then
				hide(results.Overlay, "Results") -- a new run started (a teammate's start)
			end
		elseif results.InLobby then
			if type(homeIn) == "number" then
				-- results over a run server's lobby menu: they close when the trip starts
				results.Timer.Text = UIKit.track("Main lobby in " .. homeIn .. "s" .. tail)
				if inRun then
					hide(results.Overlay, "Results")
				end
			else
				results.Timer.Text = UIKit.track("Closes in " .. left .. "s" .. tail)
				if left <= 0 or inRun then
					hide(results.Overlay, "Results")
					results.InLobby = false
				end
			end
		else
			local where = onRunServer() and "Main lobby in " or "Back to the lobby in "
			results.Timer.Text = UIKit.track(where .. left .. "s" .. tail)
			if not inRun then
				if onRunServer() then
					-- the server raises the travel cover in the same frame; a short grace in
					-- case it arrives a moment later, then this server's lobby (no trip)
					results.ReturnedAt = results.ReturnedAt or os.clock()
					if os.clock() - results.ReturnedAt > 2 then
						hide(results.Overlay, "Results")
					end
				else
					hide(results.Overlay, "Results")
				end
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
	MiniMap.Update(dt, state, inRun)
	local modalOpen = UIState.Owner() ~= nil
	RunIntro.Update(dt, state, inRun)
	-- UIState lanes: informational headlines wait for the stage-start card
	UIState.SetHold("Intro", RunIntro.Active())
	UIState.Step()
	placeToasts()
	UIState.Audit(function(name: string): boolean?
		local o = overlays[name]
		if not o then
			return nil -- not a UIBuilder overlay (StageUI's travel fade)
		end
		return o.Visible
	end)
	Tutorial.Update(dt, state, inRun, modalOpen or RunIntro.Active())
	updateSaveNotice(inRun)
	-- the run menu and its settings belong to the run, the settings menu to the lobby; a
	-- drawer whose "Pause" entry was closed elsewhere (results) goes too
	if pause.Overlay.Visible and not pause.Overlay:GetAttribute("Hiding") and (pauseMode == "RunSettings") ~= inRun then
		if pauseMode == "RunSettings" then
			runMenu.closeRunMenusSilently()
		else
			hide(pause.Overlay, "Pause")
		end
	end
	if runMenu.Overlay.Visible and (not inRun or not UIState.IsOpen("Pause")) then
		runMenu.closeRunMenusSilently()
		runMenu.Overlay.Visible = false
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
	-- panels stay in the safe area, but dimmers / backdrops (UIKit.Bleed) must reach the
	-- notch strips, so the gui must not clip to the safe area
	pcall(function()
		(gui :: any).ClipToDeviceSafeArea = false
	end)
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
	-- phones (short side under 560 px): compact layouts and the phone design space. The
	-- full-screen gui's size is the most reliable reading; the camera viewport can still be
	-- a placeholder this early.
	do
		local screen = fxGui.AbsoluteSize
		if screen.X < 50 or screen.Y < 50 then
			screen = viewport
		end
		UIKit.SetCompact(math.min(screen.X, screen.Y) < 560)
	end

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
	UIState.SetRenderer("Notice", renderNotice)
	buildLevelUp()
	buildChest()
	LootUI.OnReward = showItemReward
	buildPause()
	runMenu.buildRunMenu()
	BugReportUI.Build(root, { Show = show, Hide = hide, FitModal = fitModal, OnRelayout = onRelayout, VirtualSize = virtualSize, Toast = UIBuilder.Toast })
	buildRevive()
	buildResults()
	do
		-- REPORT A BUG opens from the pause menu and the results: the form sits above both
		local form = root:FindFirstChild("BugReport")
		if form and form:IsA("GuiObject") then
			form.ZIndex = Theme.Z.Results + 2
		end
	end
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
		CanRevive = TeamUI.CanRevive,
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
	MiniMap.Build(root, {
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
	})
	RunIntro.Build(root, { OnRelayout = onRelayout, VirtualSize = virtualSize, IsPortrait = function(): boolean
		return portrait
	end })
	Tutorial.Build(root, {
		OnRelayout = onRelayout,
		VirtualSize = virtualSize,
		IsPortrait = function(): boolean
			return portrait
		end,
		Audio = deps.Audio,
	})
	DevPanel.Init(root, hostApi)
	DevInbox.Init(root, { Show = show, Hide = hide, OnRelayout = onRelayout, VirtualSize = virtualSize, IsPortrait = hostApi.IsPortrait, Toast = UIBuilder.Toast })
	onRelayout(function()
		if levelUp.Overlay.Visible and lastOffer then
			buildCards(false)
		else
			layoutLevelUp()
		end
	end)

	gui:GetPropertyChangedSignal("AbsoluteSize"):Connect(updateScale)
	gui:GetPropertyChangedSignal("AbsolutePosition"):Connect(updateScale)
	fxGui:GetPropertyChangedSignal("AbsoluteSize"):Connect(updateScale)
	fxGui:GetPropertyChangedSignal("AbsolutePosition"):Connect(updateScale)
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
		UIState.Notice({ Id = "achievement", Text = "Achievement: " .. tostring(info.Name) .. reward, Color = P.gold_300, Class = "Info", Seconds = Config.UI.ToastSeconds })
		if deps.Audio and deps.Audio.Play then
			pcall(deps.Audio.Play, "Evolve") -- its own swell, not the level-up arpeggio
		end
	end)
	Remotes.Get("LevelUpClose").OnClientEvent:Connect(closeOffer)
	Remotes.Get("ChestOpened").OnClientEvent:Connect(UIBuilder.ShowChest)
	-- server messages: semantic id, lane and class (UIState.Classify, or the payload's Id)
	Remotes.Get("Notify").OnClientEvent:Connect(function(data)
		if type(data) == "table" and type(data.Text) == "string" then
			UIState.FromServer(data)
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
	-- the hero went down: queued headlines / notices are about the moment that ended
	player:GetAttributeChangedSignal("Alive"):Connect(function()
		UIState.Reset(player:GetAttribute("Alive") == false and "death" or "respawn")
	end)
	player:GetAttributeChangedSignal("InRun"):Connect(function()
		-- headlines / notices belong to the moment that just ended (UIState contract §5)
		UIState.Reset(player:GetAttribute("InRun") and "enter" or "leave")
		if not player:GetAttribute("InRun") then
			Hud.SetInventory(nil)
			closeOffer()
			hide(revive.Overlay, "Revive")
			closeReward(false)
			if pauseMode == "RunSettings" or overlays.Pause == runMenu.Overlay then
				-- the server already ended this player's run: no SetPause, just close
				runMenu.closeRunMenusSilently()
				-- (a bug report written from the results screen stays open)
				if not results.Overlay.Visible then
					BugReportUI.Close()
				end
			end
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
