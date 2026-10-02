--!nocheck
--[[
	classes/services.luau - Players / Player, RunService, TweenService + Tween,
	UserInputService, GuiService, StarterGui, MarketplaceService and the other services
	game code touches. Unknown members still fail loudly (instance.luau).
]]

local roblox = require("@lune/roblox")
local R = require("../R")
local D = require("../datatypes")
local S = require("../scheduler")

local states = R.states
local Vector2, Vector3, Color3, UDim, UDim2, CFrame = roblox.Vector2, roblox.Vector3, roblox.Color3, roblox.UDim, roblox.UDim2, roblox.CFrame
local Enum = roblox.Enum
local getProp = R.getProp

------------------------------------------------------------------------------------------
-- Players / Player
------------------------------------------------------------------------------------------

R.defineClass("Players", {
	events = { "PlayerAdded", "PlayerRemoving", "PlayerMembershipChanged", "UserSubscriptionStatusChanged", "PlayerChatted" },
	defaults = { MaxPlayers = 4, RespawnTime = 5 },
	getters = {
		LocalPlayer = function()
			return R.localPlayer
		end,
		NumPlayers = function(p)
			return #p:GetPlayers()
		end,
	},
	methods = {
		GetPlayers = function(p)
			local out = {}
			for _, c in ipairs(states[p].children) do
				if states[c].info.isA.Player then
					table.insert(out, c)
				end
			end
			return out
		end,
		GetNameFromUserIdAsync = function(_, id)
			return "Hero" .. tostring(id)
		end,
		GetPlayerByUserId = function(p, id)
			for _, c in ipairs(p:GetPlayers()) do
				if c.UserId == id then
					return c
				end
			end
			return nil
		end,
		GetPlayerFromCharacter = function(p, model)
			for _, c in ipairs(p:GetPlayers()) do
				if c.Character == model and model ~= nil then
					return c
				end
			end
			return nil
		end,
		GetUserThumbnailAsync = function(_, userId)
			return "rbxthumb://type=AvatarHeadShot&id=" .. tostring(userId) .. "&w=150&h=150", true
		end,
		GetNameFromUserIdAsync = function(_, userId)
			return "Player" .. tostring(userId)
		end,
		GetUserIdFromNameAsync = function()
			return 1
		end,
		GetHumanoidDescriptionFromUserId = function()
			return R.create("HumanoidDescription")
		end,
		BanAsync = function() end,
		UnbanAsync = function() end,
	},
})

local mouse = nil
R.defineClass("Player", {
	events = { "CharacterAdded", "CharacterRemoving", "CharacterAppearanceLoaded", "Chatted", "Idled", "OnTeleport", "SimulationRadiusChanged" },
	defaults = { AccountAge = 365, LocaleId = "en-us", MembershipType = Enum.MembershipType.None },
	setters = {
		Character = function(player, st, model)
			if model ~= nil and not R.isInstance(model) then
				error("Unable to assign property Character. Instance expected", 0)
			end
			local old = st.props.Character
			if old == model then
				return
			end
			if old then
				R.fire(st, "CharacterRemoving", old)
			end
			st.props.Character = model
			R.changed(player, st, "Character")
			if model then
				R.fire(st, "CharacterAdded", model)
			end
		end,
	},
	methods = {
		GetMouse = function()
			if not mouse then
				mouse = R.create("PlayerMouse")
			end
			return mouse
		end,
		Kick = function(_, msg)
			R.warn("Player:Kick(" .. tostring(msg) .. ") called")
		end,
		GetRankInGroup = function()
			return 0
		end,
		GetRoleInGroup = function()
			return "Guest"
		end,
		IsInGroup = function()
			return false
		end,
		IsFriendsWith = function()
			return false
		end,
		LoadCharacter = function()
			R.warn("Player:LoadCharacter() is ignored by the preview mock (no default avatar)")
		end,
		HasAppearanceLoaded = function()
			return true
		end,
		GetNetworkPing = function()
			return 0.05
		end,
		GetFriendsOnline = function()
			return {}
		end,
		GetJoinData = function()
			return {}
		end,
		RequestStreamAroundAsync = function() end,
		DistanceFromCharacter = function(player, pos)
			local char = player.Character
			local root = char and char:FindFirstChild("HumanoidRootPart")
			return root and (root.Position - pos).Magnitude or 0
		end,
		IsVerified = function()
			return false
		end,
		ClearCharacterAppearance = function() end,
	},
})

R.defineClass("PlayerMouse", {
	events = { "Button1Down", "Button1Up", "Button2Down", "Button2Up", "Move", "Idle", "WheelForward", "WheelBackward" },
	getters = {
		Hit = function()
			return CFrame.identity
		end,
		Target = function()
			return nil
		end,
		X = function()
			return R.options.device.width / 2
		end,
		Y = function()
			return R.options.device.height / 2
		end,
		ViewSizeX = function()
			return R.options.device.width
		end,
		ViewSizeY = function()
			return R.options.device.height
		end,
	},
})

------------------------------------------------------------------------------------------
-- RunService
------------------------------------------------------------------------------------------

local bound = {} -- { name, priority, fn }

R.defineClass("RunService", {
	events = { "Heartbeat", "RenderStepped", "Stepped", "PreSimulation", "PostSimulation", "PreRender", "PreAnimation" },
	methods = {
		IsServer = function()
			return R.options.isServer ~= false
		end,
		IsClient = function()
			return R.options.isClient ~= false
		end,
		IsStudio = function()
			return R.options.studio == true
		end,
		IsRunning = function()
			return true
		end,
		IsRunMode = function()
			return false
		end,
		IsEdit = function()
			return false
		end,
		BindToRenderStep = function(_, name, priority, fn)
			for i = #bound, 1, -1 do
				if bound[i].name == name then
					table.remove(bound, i)
				end
			end
			table.insert(bound, { name = name, priority = priority, fn = fn, order = #bound })
			table.sort(bound, function(a, b)
				if a.priority == b.priority then
					return a.order < b.order
				end
				return a.priority < b.priority
			end)
		end,
		UnbindFromRenderStep = function(_, name)
			for i = #bound, 1, -1 do
				if bound[i].name == name then
					table.remove(bound, i)
				end
			end
		end,
		Set3dRenderingEnabled = function() end,
		GetRobloxClientChannel = function()
			return "LIVE"
		end,
	},
})

function R.installRunService(rs)
	local st = states[rs]
	S.frameHooks.render = function(dt)
		for _, b in ipairs(table.clone(bound)) do
			S.spawn(b.fn, dt)
		end
		R.fire(st, "PreRender", dt)
		R.fire(st, "RenderStepped", dt)
	end
	S.frameHooks.simulate = function(dt)
		R.fire(st, "PreAnimation", dt)
		R.fire(st, "Stepped", S.now, dt)
		R.fire(st, "PreSimulation", dt)
		R.fire(st, "PostSimulation", dt)
		R.fire(st, "Heartbeat", dt)
	end
end

------------------------------------------------------------------------------------------
-- TweenService + Tween
------------------------------------------------------------------------------------------

local function bounceOut(t)
	if t < 1 / 2.75 then
		return 7.5625 * t * t
	elseif t < 2 / 2.75 then
		t -= 1.5 / 2.75
		return 7.5625 * t * t + 0.75
	elseif t < 2.5 / 2.75 then
		t -= 2.25 / 2.75
		return 7.5625 * t * t + 0.9375
	end
	t -= 2.625 / 2.75
	return 7.5625 * t * t + 0.984375
end

local EASE_IN = {
	Linear = function(t)
		return t
	end,
	Sine = function(t)
		return 1 - math.cos(t * math.pi / 2)
	end,
	Quad = function(t)
		return t * t
	end,
	Cubic = function(t)
		return t * t * t
	end,
	Quart = function(t)
		return t ^ 4
	end,
	Quint = function(t)
		return t ^ 5
	end,
	Exponential = function(t)
		return t == 0 and 0 or 2 ^ (10 * t - 10)
	end,
	Circular = function(t)
		return 1 - math.sqrt(math.max(0, 1 - t * t))
	end,
	Back = function(t)
		local s = 1.70158
		return t * t * ((s + 1) * t - s)
	end,
	Elastic = function(t)
		if t == 0 or t == 1 then
			return t
		end
		return -(2 ^ (10 * t - 10)) * math.sin((t * 10 - 10.75) * (2 * math.pi) / 3)
	end,
	Bounce = function(t)
		return 1 - bounceOut(1 - t)
	end,
}

local function ease(alpha: number, style, direction): number
	local name = style and style.Name or "Quad"
	local fIn = EASE_IN[name] or EASE_IN.Quad
	local dir = direction and direction.Name or "Out"
	if dir == "In" then
		return fIn(alpha)
	elseif dir == "Out" then
		return 1 - fIn(1 - alpha)
	end
	if alpha < 0.5 then
		return fIn(alpha * 2) / 2
	end
	return 1 - fIn((1 - alpha) * 2) / 2
end
R.ease = ease

local function lerpValue(a, b, t)
	local ta = D.typeof(a)
	if ta == "number" then
		return a + (b - a) * t
	elseif ta == "Vector3" or ta == "Vector2" or ta == "CFrame" or ta == "Color3" or ta == "UDim2" then
		return a:Lerp(b, t)
	elseif ta == "UDim" then
		return UDim.new(a.Scale + (b.Scale - a.Scale) * t, a.Offset + (b.Offset - a.Offset) * t)
	elseif ta == "Rect" then
		return roblox.Rect.new(a.Min:Lerp(b.Min, t), a.Max:Lerp(b.Max, t))
	elseif ta == "NumberRange" then
		return roblox.NumberRange.new(a.Min + (b.Min - a.Min) * t, a.Max + (b.Max - a.Max) * t)
	end
	return t >= 1 and b or a
end

local active = {} -- array of tween states
local owners = setmetatable({}, { __mode = "k" }) -- instance -> { prop -> tween }

local function finish(tween, st, stateItem)
	local x = st.x
	x.playing = false
	local i = table.find(active, tween)
	if i then
		table.remove(active, i)
	end
	local inst = x.instance
	local own = owners[inst]
	if own then
		for prop, t in pairs(own) do
			if t == tween then
				own[prop] = nil
			end
		end
	end
	R.rawset(tween, "PlaybackState", stateItem)
	R.fire(st, "Completed", stateItem)
end

local function applyAlpha(tween, st, alpha)
	local x = st.x
	local inst = x.instance
	if not states[inst] or states[inst].destroyed then
		return
	end
	for prop, goal in pairs(x.goals) do
		local start = x.starts[prop]
		local v = lerpValue(start, goal, alpha)
		local ok, err = pcall(function()
			inst[prop] = v
		end)
		if not ok then
			R.error("Tween could not set " .. prop .. ": " .. tostring(err))
			x.goals[prop] = nil
		end
	end
end

local function updateTween(tween, dt)
	local st = states[tween]
	local x = st.x
	x.elapsed += dt
	local info = x.info
	local T = math.max(info.Time, 0)
	local delay = math.max(info.DelayTime, 0)
	local reverses = info.Reverses
	local repeats = info.RepeatCount
	local cycleLen = delay + T * (reverses and 2 or 1)
	if cycleLen <= 0 then
		applyAlpha(tween, st, reverses and 0 or 1)
		finish(tween, st, Enum.PlaybackState.Completed)
		return
	end
	local cycle = math.floor(x.elapsed / cycleLen)
	if repeats >= 0 and cycle > repeats then
		applyAlpha(tween, st, reverses and 0 or 1)
		finish(tween, st, Enum.PlaybackState.Completed)
		return
	end
	local t = x.elapsed - cycle * cycleLen
	if t < delay then
		if cycle == 0 then
			return -- still waiting to start
		end
		applyAlpha(tween, st, 0)
		return
	end
	local u = T > 0 and (t - delay) / T or 1
	local alpha
	if u <= 1 then
		alpha = ease(math.clamp(u, 0, 1), info.EasingStyle, info.EasingDirection)
	else
		alpha = ease(math.clamp(2 - u, 0, 1), info.EasingStyle, info.EasingDirection)
	end
	applyAlpha(tween, st, alpha)
end

S.frameHooks.tweens = function(dt)
	if #active == 0 then
		return
	end
	for _, tween in ipairs(table.clone(active)) do
		local st = states[tween]
		if st and st.x.playing then
			updateTween(tween, dt)
		end
	end
end

R.defineClass("TweenBase", {
	events = { "Completed" },
	defaults = { PlaybackState = Enum.PlaybackState.Begin },
	methods = {
		Play = function(tween)
			local st = states[tween]
			local x = st.x
			if x.playing then
				return
			end
			local inst = x.instance
			if not x.paused then
				x.elapsed = 0
				x.starts = {}
				for prop in pairs(x.goals) do
					x.starts[prop] = inst[prop]
				end
			end
			x.paused = false
			x.playing = true
			-- the newest tween owns a property; older tweens on it are cancelled
			local own = owners[inst]
			if not own then
				own = {}
				owners[inst] = own
			end
			for prop in pairs(x.goals) do
				local other = own[prop]
				if other and other ~= tween and states[other].x.playing then
					finish(other, states[other], Enum.PlaybackState.Cancelled)
				end
				own[prop] = tween
			end
			table.insert(active, tween)
			R.rawset(tween, "PlaybackState", Enum.PlaybackState.Playing)
			if x.info.Time <= 0 and x.info.DelayTime <= 0 and x.info.RepeatCount == 0 then
				updateTween(tween, 0)
			end
		end,
		Pause = function(tween)
			local st = states[tween]
			if not st.x.playing then
				return
			end
			st.x.playing = false
			st.x.paused = true
			local i = table.find(active, tween)
			if i then
				table.remove(active, i)
			end
			R.rawset(tween, "PlaybackState", Enum.PlaybackState.Paused)
		end,
		Cancel = function(tween)
			local st = states[tween]
			st.x.paused = false
			if st.x.playing then
				finish(tween, st, Enum.PlaybackState.Cancelled)
			else
				R.rawset(tween, "PlaybackState", Enum.PlaybackState.Cancelled)
			end
		end,
	},
})

R.defineClass("Tween", {
	getters = {
		Instance = function(_, st)
			return st.x.instance
		end,
		TweenInfo = function(_, st)
			return st.x.info
		end,
	},
})

R.defineClass("TweenService", {
	methods = {
		Create = function(_, inst, info, goals)
			if not R.isInstance(inst) then
				error("TweenService:Create: argument 1 must be an Instance", 2)
			end
			if D.typeof(info) ~= "TweenInfo" then
				error("TweenService:Create: argument 2 must be a TweenInfo", 2)
			end
			local checked = {}
			for prop, goal in pairs(goals) do
				local ok, current = pcall(function()
					return inst[prop]
				end)
				if not ok then
					error(string.format("TweenService:Create property named '%s' cannot be tweened due to type mismatch (property is a 'nil', but given type is '%s')", tostring(prop), D.typeof(goal)), 2)
				end
				if D.typeof(current) ~= D.typeof(goal) then
					error(string.format("TweenService:Create property named '%s' cannot be tweened due to type mismatch (property is a '%s', but given type is '%s')", tostring(prop), D.typeof(current), D.typeof(goal)), 2)
				end
				checked[prop] = goal
			end
			local tween = R.create("Tween")
			local st = states[tween]
			st.x.instance = inst
			st.x.info = info
			st.x.goals = checked
			st.x.elapsed = 0
			return tween
		end,
		GetValue = function(_, alpha, style, direction)
			return ease(math.clamp(alpha, 0, 1), style, direction)
		end,
		SmoothDamp = function(_, current, target, velocity, smoothTime, _maxSpeed, dt)
			local t = math.clamp((dt or S.dt) / math.max(smoothTime, 1e-4), 0, 1)
			return lerpValue(current, target, t), velocity
		end,
	},
})

------------------------------------------------------------------------------------------
-- UserInputService, GuiService, StarterGui, PlayerGui
------------------------------------------------------------------------------------------

local function device()
	return R.options.device
end

R.defineClass("UserInputService", {
	events = {
		"InputBegan", "InputChanged", "InputEnded", "TouchStarted", "TouchMoved", "TouchEnded", "TouchTap",
		"TouchLongPress", "TouchPan", "TouchPinch", "TouchSwipe", "TouchRotate", "TouchTapInWorld", "WindowFocused",
		"WindowFocusReleased", "LastInputTypeChanged", "GamepadConnected", "GamepadDisconnected", "TextBoxFocused",
		"TextBoxFocusReleased", "JumpRequest", "DeviceOrientationChanged", "PointerAction", "DeviceAccelerationChanged",
		"DeviceGravityChanged", "DeviceRotationChanged", "UserCFrameChanged",
	},
	getters = {
		TouchEnabled = function()
			return device().touch == true
		end,
		KeyboardEnabled = function()
			return device().keyboard == true
		end,
		MouseEnabled = function()
			return device().mouse == true
		end,
		GamepadEnabled = function()
			return false
		end,
		AccelerometerEnabled = function()
			return device().touch == true
		end,
		GyroscopeEnabled = function()
			return device().touch == true
		end,
		VREnabled = function()
			return false
		end,
		PreferredInput = function()
			return device().touch and Enum.PreferredInput.Touch or Enum.PreferredInput.KeyboardAndMouse
		end,
		OnScreenKeyboardVisible = function()
			return false
		end,
	},
	methods = {
		GetLastInputType = function()
			return device().touch and Enum.UserInputType.Touch or Enum.UserInputType.MouseMovement
		end,
		GetMouseLocation = function()
			return Vector2.new(device().width / 2, device().height / 2)
		end,
		GetMouseDelta = function()
			return Vector2.zero
		end,
		GetKeysPressed = function()
			return {}
		end,
		IsKeyDown = function()
			return false
		end,
		IsMouseButtonPressed = function()
			return false
		end,
		IsGamepadButtonDown = function()
			return false
		end,
		GetGamepadConnected = function()
			return false
		end,
		GetConnectedGamepads = function()
			return {}
		end,
		GetNavigationGamepads = function()
			return {}
		end,
		GetSupportedGamepadKeyCodes = function()
			return {}
		end,
		GetGamepadState = function()
			return {}
		end,
		GetFocusedTextBox = function()
			return nil
		end,
		GetStringForKeyCode = function(_, kc)
			return kc and kc.Name or ""
		end,
		GetImageForKeyCode = function()
			return ""
		end,
		GetDeviceRotation = function()
			return CFrame.identity
		end,
		GetDeviceGravity = function()
			return nil
		end,
		GetMouseButtonsPressed = function()
			return {}
		end,
	},
})

-- Top inset of the Roblox top bar in GUI pixels for the current device.
function R.guiInset(): Vector2
	local d = device()
	return Vector2.new(0, (d.topbarBelowSafeTop and d.safe.top or 0) + d.topbar)
end

R.defineClass("GuiService", {
	events = { "MenuOpened", "MenuClosed", "UiMessageChanged", "ErrorMessageChanged", "NativeClose", "KeyPressed", "SpecialKeyPressed", "ShowLeaveConfirmation" },
	getters = {
		MenuIsOpen = function()
			return false
		end,
		TopbarInset = function()
			local d = device()
			local top = (d.topbarBelowSafeTop and d.safe.top or 0)
			return roblox.Rect.new(d.safe.left + 120, top, d.width - d.safe.right - 60, top + d.topbar)
		end,
		IsWindows = function()
			return false
		end,
		ReducedMotionEnabled = function()
			return false
		end,
		PreferredTransparency = function()
			return 1
		end,
		PreferredTextSize = function()
			return Enum.PreferredTextSize.Medium
		end,
	},
	methods = {
		GetGuiInset = function()
			return R.guiInset(), Vector2.zero
		end,
		IsTenFootInterface = function()
			return false
		end,
		AddSelectionParent = function() end,
		AddSelectionTuple = function() end,
		RemoveSelectionGroup = function() end,
		Select = function() end,
		InspectPlayerFromUserId = function() end,
		CloseInspectMenu = function() end,
		GetEmotesMenuOpen = function()
			return false
		end,
		SetEmotesMenuOpen = function() end,
		GetInspectMenuEnabled = function()
			return false
		end,
		SetInspectMenuEnabled = function() end,
		GetGameplayPausedNotificationEnabled = function()
			return false
		end,
		SetGameplayPausedNotificationEnabled = function() end,
		OpenBrowserWindow = function() end,
		DismissNotification = function() end,
		SendNotification = function() end,
	},
})

R.coreGui = {}
R.defineClass("StarterGui", {
	methods = {
		SetCoreGuiEnabled = function(_, kind, on)
			R.coreGui[kind.Name] = on
			if kind == Enum.CoreGuiType.All then
				for _, item in ipairs(Enum.CoreGuiType:GetEnumItems()) do
					R.coreGui[item.Name] = on
				end
			end
		end,
		GetCoreGuiEnabled = function(_, kind)
			return R.coreGui[kind.Name] ~= false
		end,
		SetCore = function(_, name, value)
			R.coreGui["Core:" .. tostring(name)] = value
		end,
		GetCore = function(_, name)
			return R.coreGui["Core:" .. tostring(name)]
		end,
		RegisterGetCore = function() end,
		RegisterSetCore = function() end,
	},
})

R.defineClass("PlayerGui", {
	events = { "TopbarTransparencyChangedSignal" },
	getters = {
		CurrentScreenOrientation = function()
			local d = device()
			return d.width >= d.height and Enum.ScreenOrientation.LandscapeRight or Enum.ScreenOrientation.Portrait
		end,
	},
	methods = {
		SetTopbarTransparency = function() end,
		GetTopbarTransparency = function()
			return 0
		end,
	},
})

------------------------------------------------------------------------------------------
-- Commerce and platform stubs
------------------------------------------------------------------------------------------

local function logPrompt(kind: string, id)
	table.insert(R.log.fired, { remote = "MarketplaceService", direction = kind, args = tostring(id), t = S.now })
end

R.defineClass("MarketplaceService", {
	events = { "PromptGamePassPurchaseFinished", "PromptProductPurchaseFinished", "PromptPurchaseFinished", "PromptBundlePurchaseFinished", "PromptPremiumPurchaseFinished", "PromptSubscriptionPurchaseFinished", "ThirdPartyPurchaseFinished" },
	props = { ProcessReceipt = { type = "Function" } },
	getters = {
		ProcessReceipt = function(_, st)
			return st.x.processReceipt
		end,
	},
	setters = {
		ProcessReceipt = function(_, st, fn)
			st.x.processReceipt = fn
		end,
	},
	methods = {
		PromptProductPurchase = function(_, _, id)
			logPrompt("PromptProductPurchase", id)
		end,
		PromptGamePassPurchase = function(_, _, id)
			logPrompt("PromptGamePassPurchase", id)
		end,
		PromptPurchase = function(_, _, id)
			logPrompt("PromptPurchase", id)
		end,
		PromptBundlePurchase = function(_, _, id)
			logPrompt("PromptBundlePurchase", id)
		end,
		PromptPremiumPurchase = function()
			logPrompt("PromptPremiumPurchase", "")
		end,
		PromptSubscriptionPurchase = function(_, _, id)
			logPrompt("PromptSubscriptionPurchase", id)
		end,
		GetProductInfo = function(_, id)
			return { Name = "Product " .. tostring(id), Description = "", PriceInRobux = 49, IconImageAssetId = 0, ProductId = id, AssetId = id, IsForSale = true }
		end,
		GetProductInfoAsync = function(_, id)
			return { Name = "Product " .. tostring(id), Description = "", PriceInRobux = 49, IconImageAssetId = 0, ProductId = id, AssetId = id, IsForSale = true }
		end,
		UserOwnsGamePassAsync = function()
			return false
		end,
		PlayerOwnsAsset = function()
			return false
		end,
		PlayerOwnsBundle = function()
			return false
		end,
		GetUserSubscriptionStatusAsync = function()
			return { IsSubscribed = false, IsRenewing = false }
		end,
	},
})

R.defineClass("BadgeService", {
	methods = {
		AwardBadge = function()
			return true
		end,
		UserHasBadgeAsync = function()
			return false
		end,
		UserHasBadge = function()
			return false
		end,
		GetBadgeInfoAsync = function(_, id)
			return { Name = "Badge " .. tostring(id), Description = "", IconImageId = 0, IsEnabled = true }
		end,
		CheckUserBadgesAsync = function()
			return {}
		end,
	},
})

R.defineClass("SocialService", {
	events = { "GameInvitePromptClosed", "CallInviteStateChanged", "PromptInviteRequested", "OnCallInviteInvoked" },
	methods = {
		PromptGameInvite = function() end,
		CanSendGameInviteAsync = function()
			return false
		end,
		PromptPhoneBook = function() end,
		CanSendCallInviteAsync = function()
			return false
		end,
	},
})

R.defineClass("ContentProvider", {
	getters = {
		RequestQueueSize = function()
			return 0
		end,
	},
	methods = {
		PreloadAsync = function(_, list, callback)
			if callback then
				for _, item in ipairs(list) do
					callback(typeof(item) == "string" and item or tostring(item), Enum.AssetFetchStatus.Success)
				end
			end
		end,
		GetAssetFetchStatus = function()
			return Enum.AssetFetchStatus.Success
		end,
		Preload = function() end,
	},
})

R.defineClass("TextChatService", {
	events = { "MessageReceived", "SendingMessage", "BubbleDisplayed" },
	props = {
		OnIncomingMessage = { type = "Function" },
		OnBubbleAdded = { type = "Function" },
		OnChatWindowAdded = { type = "Function" },
	},
	getters = {
		OnIncomingMessage = function(_, st)
			return st.x.onIncoming
		end,
		OnBubbleAdded = function(_, st)
			return st.x.onBubble
		end,
		OnChatWindowAdded = function(_, st)
			return st.x.onWindow
		end,
	},
	setters = {
		OnIncomingMessage = function(_, st, fn)
			st.x.onIncoming = fn
		end,
		OnBubbleAdded = function(_, st, fn)
			st.x.onBubble = fn
		end,
		OnChatWindowAdded = function(_, st, fn)
			st.x.onWindow = fn
		end,
	},
	methods = {
		CanUserChatAsync = function()
			return true
		end,
		CanUsersChatAsync = function()
			return true
		end,
		DisplayBubble = function() end,
	},
})

R.defineClass("Teams", {
	methods = {
		GetTeams = function(t)
			local out = {}
			for _, c in ipairs(states[t].children) do
				if states[c].info.isA.Team then
					table.insert(out, c)
				end
			end
			return out
		end,
	},
})
R.defineClass("Team", {
	events = { "PlayerAdded", "PlayerRemoved" },
	methods = {
		GetPlayers = function()
			return {}
		end,
	},
})

-- Text filter stand-in (BugReportService): "badword" comes back as hashes, like Roblox's
-- filter would; anything else passes unchanged.
R.defineClass("TextService", {
	methods = {
		FilterStringAsync = function(_, text)
			local filtered = (string.gsub(tostring(text), "[Bb]adword", "#######"))
			return {
				GetNonChatStringForBroadcastAsync = function()
					return filtered
				end,
			}
		end,
	},
})

-- In-memory DataStores (only needed when a scene runs the full server).
local stores = {}
R.defineClass("DataStoreService", {
	methods = {
		GetDataStore = function(_, name, scope)
			local key = tostring(name) .. "/" .. tostring(scope or "global")
			if not stores[key] then
				local ds = R.create("DataStore")
				states[ds].name = tostring(name)
				states[ds].x.data = {}
				stores[key] = ds
			end
			return stores[key]
		end,
		GetOrderedDataStore = function(_, name, scope)
			local key = "ordered:" .. tostring(name) .. "/" .. tostring(scope or "global")
			if not stores[key] then
				local ds = R.create("OrderedDataStore")
				states[ds].name = tostring(name)
				states[ds].x.data = {}
				stores[key] = ds
			end
			return stores[key]
		end,
		GetGlobalDataStore = function(svc)
			return svc:GetDataStore("global")
		end,
		GetRequestBudgetForRequestType = function()
			return 100
		end,
	},
})
R.defineClass("GlobalDataStore", {
	methods = {
		GetAsync = function(ds, key)
			return R.copyValue(states[ds].x.data[key]), nil
		end,
		SetAsync = function(ds, key, value)
			states[ds].x.data[key] = R.copyValue(value)
		end,
		UpdateAsync = function(ds, key, fn)
			local data = states[ds].x.data
			local new = fn(R.copyValue(data[key]), nil)
			if new ~= nil then
				data[key] = R.copyValue(new)
			end
			return new, nil
		end,
		RemoveAsync = function(ds, key)
			local data = states[ds].x.data
			local old = data[key]
			data[key] = nil
			return old
		end,
		IncrementAsync = function(ds, key, delta)
			local data = states[ds].x.data
			data[key] = (data[key] or 0) + (delta or 1)
			return data[key]
		end,
	},
})

-- OrderedDataStore: integer values, GetSortedAsync → a one-page DataStorePages stand-in
-- ({ key, value } rows sorted by value) for the leaderboards.
R.defineClass("OrderedDataStore", {
	methods = {
		GetSortedAsync = function(ds, ascending, pageSize)
			local rows = {}
			for k, v in pairs(states[ds].x.data) do
				if type(v) == "number" then
					table.insert(rows, { key = k, value = v })
				end
			end
			table.sort(rows, function(a, b)
				if a.value == b.value then
					return a.key < b.key
				end
				if ascending then
					return a.value < b.value
				end
				return a.value > b.value
			end)
			local page = {}
			for i = 1, math.min(#rows, pageSize or 50) do
				page[i] = rows[i]
			end
			return {
				IsFinished = true,
				GetCurrentPage = function()
					return page
				end,
				AdvanceToNextPageAsync = function() end,
			}
		end,
	},
})

R.defineClass("PhysicsService", {
	methods = {
		RegisterCollisionGroup = function() end,
		UnregisterCollisionGroup = function() end,
		CreateCollisionGroup = function()
			return 1
		end,
		CollisionGroupSetCollidable = function() end,
		CollisionGroupsAreCollidable = function()
			return true
		end,
		IsCollisionGroupRegistered = function()
			return true
		end,
		GetRegisteredCollisionGroups = function()
			return {}
		end,
		SetPartCollisionGroup = function() end,
		GetMaxCollisionGroups = function()
			return 32
		end,
	},
})

R.defineClass("PolicyService", {
	methods = {
		GetPolicyInfoForPlayerAsync = function()
			return { AreAdsAllowed = true, ArePaidRandomItemsRestricted = false, AllowedExternalLinkReferences = {}, IsPaidItemTradingAllowed = true, IsSubjectToChinaPolicies = false, IsContentSharingAllowed = true }
		end,
	},
})

R.defineClass("LocalizationService", {
	getters = {
		RobloxLocaleId = function()
			return "en-us"
		end,
		SystemLocaleId = function()
			return "en-us"
		end,
	},
	methods = {
		GetCountryRegionForPlayerAsync = function()
			return "US"
		end,
		GetTranslatorForPlayerAsync = function()
			error("LocalizationService translators are not supported by the preview mock", 2)
		end,
	},
})

R.defineClass("GroupService", {
	methods = {
		GetGroupInfoAsync = function(_, id)
			return { Name = "Group " .. tostring(id), Id = id, Owner = { Name = "Owner", Id = 1 }, Roles = {} }
		end,
		GetGroupsAsync = function()
			return {}
		end,
	},
})

R.defineClass("ContextActionService", {
	events = { "LocalToolEquipped", "LocalToolUnequipped" },
	methods = {
		BindAction = function() end,
		BindActionAtPriority = function() end,
		UnbindAction = function() end,
		UnbindAllActions = function() end,
		SetTitle = function() end,
		SetImage = function() end,
		SetPosition = function() end,
		SetDescription = function() end,
		GetButton = function()
			return nil
		end,
		GetAllBoundActionInfo = function()
			return {}
		end,
		GetBoundActionInfo = function()
			return {}
		end,
	},
})

R.defineClass("HapticService", {
	methods = {
		IsVibrationSupported = function()
			return false
		end,
		IsMotorSupported = function()
			return false
		end,
		SetMotor = function() end,
		GetMotor = function()
			return 0
		end,
	},
})

R.defineClass("VRService", {
	getters = {
		VREnabled = function()
			return false
		end,
	},
	methods = {
		GetUserCFrameEnabled = function()
			return false
		end,
		GetUserCFrame = function()
			return CFrame.identity
		end,
	},
})

R.defineClass("ProximityPromptService", {
	events = { "PromptTriggered", "PromptTriggerEnded", "PromptButtonHoldBegan", "PromptButtonHoldEnded", "PromptShown", "PromptHidden" },
})

R.defineClass("AnalyticsService", {
	methods = (function()
		local m = {}
		for _, name in ipairs({ "LogCustomEvent", "LogEconomyEvent", "LogFunnelStepEvent", "LogOnboardingFunnelStepEvent", "LogProgressionEvent", "LogProgressionStartEvent", "LogProgressionCompleteEvent", "LogProgressionFailEvent", "FireCustomEvent", "FireInGameEconomyEvent", "FirePlayerProgressionEvent", "FireLogEvent" }) do
			m[name] = function() end
		end
		return m
	end)(),
})

R.defineClass("TeleportService", {
	events = { "TeleportInitFailed", "LocalPlayerArrivedFromTeleport" },
	methods = {
		Teleport = function() end,
		TeleportAsync = function() end,
		GetLocalPlayerTeleportData = function()
			return nil
		end,
		SetTeleportGui = function() end,
	},
})

return true
