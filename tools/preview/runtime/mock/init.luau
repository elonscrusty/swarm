--!nocheck
--[[
	mock/init.luau - assembles the mock Roblox runtime.

	local mock = require("@self/mock")
	mock.boot({ device = "phone", seed = 1, repo = "/path/to/swarm", ... })
	→ game tree from default.project.json, services, one LocalPlayer, the global environment,
	  and `preview` (the scene API, also available to scenes as the global `preview`).
]]

local roblox = require("@lune/roblox")
local R = require("@self/R")
local D = require("@self/datatypes")
local S = require("@self/scheduler")
require("@self/signal")
local Prof = require("@self/profile")
require("@self/instance")
require("@self/classes/core")
require("@self/classes/world")
require("@self/classes/services")
local T = require("@self/text")
local L = require("@self/layout")
local E = require("@self/exporter")
local M = require("@self/meshes")
local DM = require("@self/datamodel")

local states = R.states
local Vector2, Vector3, CFrame = roblox.Vector2, roblox.Vector3, roblox.CFrame

local Mock = {}

Mock.DEVICES = {
	pc = { name = "pc", width = 1920, height = 1080, dpr = 1, touch = false, keyboard = true, mouse = true, safe = { left = 0, right = 0, top = 0, bottom = 0 }, topbar = 58 },
	laptop = { name = "laptop", width = 1366, height = 768, dpr = 1, touch = false, keyboard = true, mouse = true, safe = { left = 0, right = 0, top = 0, bottom = 0 }, topbar = 58 },
	phone = { name = "phone", width = 844, height = 390, dpr = 2, touch = true, keyboard = false, mouse = false, safe = { left = 47, right = 47, top = 0, bottom = 21 }, topbar = 58 },
	["phone-portrait"] = { name = "phone-portrait", width = 390, height = 844, dpr = 2, touch = true, keyboard = false, mouse = false, safe = { left = 0, right = 0, top = 47, bottom = 34 }, topbar = 58, topbarBelowSafeTop = true },
	-- A real iPhone 15 Pro in landscape, as the Roblox app reports it: notch / rounded-corner
	-- insets left and right, AbsolutePosition in "inset space" (y = 0 is the bottom of the
	-- 58 px top bar, so an IgnoreGuiInset ScreenGui starts at y = -58, same space as
	-- Camera:WorldToScreenPoint) and ScreenGuis with safe-area insets clip their descendants
	-- to the safe area unless ClipToDeviceSafeArea = false.
	--
	-- Calibrated again against the owner's 2026-10-06 iPhone screenshots (2556 x 1179):
	--  * the new Roblox top bar: a round Roblox button and a menu + chat pill, drawn at
	--    x 77-222 / y 13-55 (coreButtons), and GuiService.TopbarInset reported in safe-area
	--    space (X 59 px left of the screen position the game computes from AbsolutePosition:
	--    topbarSafeSpace), so a layout trusting it lands its header under the chat button
	--    and thinks the top bar's right side is taken;
	--  * the player's Roblox "Text size" accessibility setting (GuiService.PreferredTextSize)
	--    scales every TextSize-sized label at render time (not TextScaled ones, and never
	--    past a UITextSizeConstraint.MaxTextSize). The owner's phone measures about 1.6x
	--    (textSize = "Largest", see TEXT_SCALES); `--set textsize=Medium` turns it off.
	iphone = {
		name = "iphone", width = 852, height = 393, dpr = 3, touch = true, keyboard = false, mouse = false,
		safe = { left = 59, right = 59, top = 0, bottom = 0 }, topbar = 58, insetSpace = true, clipSafe = true,
		topbarSafeSpace = true, textSize = "Largest",
		coreButtons = { { x = 77, y = 13, w = 42, h = 42, kind = "roblox" }, { x = 128, y = 13, w = 94, h = 42, kind = "pill" } },
	},
	-- the owner's 2026-10-07 landscape phone recording (1108 x 512, an Android-style phone with
	-- no notch inset reported) and a small landscape phone (iPhone SE class, 667 x 375)
	["phone-1108"] = { name = "phone-1108", width = 1108, height = 512, dpr = 2.5, touch = true, keyboard = false, mouse = false, safe = { left = 0, right = 0, top = 0, bottom = 0 }, topbar = 58 },
	["phone-small"] = { name = "phone-small", width = 667, height = 375, dpr = 2, touch = true, keyboard = false, mouse = false, safe = { left = 0, right = 0, top = 0, bottom = 0 }, topbar = 58 },
	tablet = { name = "tablet", width = 1024, height = 768, dpr = 1.5, touch = true, keyboard = false, mouse = false, safe = { left = 0, right = 0, top = 0, bottom = 20 }, topbar = 58 },
}

-- Render-time text scale per GuiService.PreferredTextSize. Roblox does not publish the
-- factors. The owner's iPhone shots measure 1.57-1.60x (widths of the same Source Sans
-- labels against a Medium render: "Open slot", "THIS SERVER", "Not in a party yet"), taken
-- here as Largest; Large / Larger are spaced evenly below it (estimates).
Mock.TEXT_SCALES = { Medium = 1, Large = 1.2, Larger = 1.4, Largest = 1.6 }

function Mock.boot(options)
	R.options = options
	options.device = type(options.device) == "table" and options.device or Mock.DEVICES[options.device or "pc"]
	if not options.device then
		error("unknown device profile")
	end
	-- the player's Roblox Text size setting (GuiService.PreferredTextSize): `--set textsize=`
	-- overrides the device profile's
	local ts = (options.sceneArgs and options.sceneArgs.textsize) or options.device.textSize or "Medium"
	if not Mock.TEXT_SCALES[ts] then
		error("unknown textsize " .. tostring(ts) .. " (Medium, Large, Larger, Largest)")
	end
	R.textSize = ts
	R.textScale = Mock.TEXT_SCALES[ts]
	math.randomseed(options.seed or 1)
	T.setMetrics(options.fontMetrics)
	M.setCatalog(options.catalog)

	-- the DataModel and its services
	local game = R.create("DataModel")
	states[game].name = "Game"
	R.game = game
	for _, name in ipairs({
		"Workspace", "Players", "Lighting", "ReplicatedStorage", "ReplicatedFirst", "ServerScriptService", "ServerStorage",
		"StarterGui", "StarterPack", "StarterPlayer", "SoundService", "Teams", "RunService", "TweenService",
		"UserInputService", "GuiService", "CollectionService", "TextService", "HttpService", "TextChatService",
	}) do
		R.getService(game, name)
	end
	R.installRunService(R.services.RunService)
	local lighting = R.services.Lighting
	lighting.ClockTime = 14

	-- settings() / UserSettings()
	R.settingsObject = setmetatable({
		Rendering = { QualityLevel = roblox.Enum.QualityLevel.Automatic },
		Physics = { AllowSleep = true },
		Network = { IncomingReplicationLag = 0 },
		Studio = {},
	}, { __type = "GlobalSettings" })
	local ugs = R.create("UserGameSettings")
	R.userSettings = setmetatable({
		GetService = function(_, name)
			if name == "UserGameSettings" then
				return ugs
			end
			error("UserSettings():GetService(" .. tostring(name) .. ") is not supported by the preview mock", 2)
		end,
	}, { __type = "UserSettings" })

	-- StarterPlayer containers Rojo leaves out
	DM.makeGlobals()
	DM.loadProject(options.repo, options.project or "default.project.json")
	local sp = R.services.StarterPlayer
	if not R.findChild(states[sp], "StarterPlayerScripts") then
		local f = R.create("StarterPlayerScripts")
		states[f].name = "StarterPlayerScripts"
		R.setParent(f, states[f], sp)
	end
	if not R.findChild(states[sp], "StarterCharacterScripts") then
		local f = R.create("StarterCharacterScripts")
		states[f].name = "StarterCharacterScripts"
		R.setParent(f, states[f], sp)
	end

	-- the local player
	local player = R.create("Player")
	local pst = states[player]
	pst.name = options.playerName or "PreviewPlayer"
	pst.props.UserId = options.userId or 1
	pst.props.DisplayName = pst.name
	R.localPlayer = player
	for _, cls in ipairs({ "PlayerGui", "PlayerScripts", "Backpack" }) do
		local c = R.create(cls)
		states[c].name = cls
		R.setParent(c, states[c], player)
	end
	R.setParent(player, pst, R.services.Players)
	-- StarterGui contents are copied into PlayerGui (as Roblox does on join)
	local pg = R.findChild(pst, "PlayerGui")
	for _, c in ipairs(states[R.services.StarterGui].children) do
		local copy = R.clone(c)
		if copy then
			R.setParent(copy, states[copy], pg)
		end
	end

	local cam = R.getProp(states[R.services.Workspace], "CurrentCamera")
	cam.CFrame = D.CFrame.lookAt(Vector3.new(0, 20, 20), Vector3.zero)

	return Mock.api()
end

------------------------------------------------------------------------------------------
-- Scene API (global `preview` in scenes)
------------------------------------------------------------------------------------------

function Mock.api()
	local api = {}
	api.device = R.options.device
	api.seed = R.options.seed or 1
	api.repo = R.options.repo
	api.args = R.options.sceneArgs or {}
	api.metrics = {}
	api.overlays = {}
	api.camera = nil -- override: { cf = CFrame, fov = number, ortho = { height = studs } }
	api.rng = D.Random.new((R.options.seed or 1) * 7 + 3)
	api.render = { background = nil, hideCoreUi = false }

	function api.now()
		return S.now
	end

	-- Advances simulated time (frames at `fps`, default 60).
	function api.advance(seconds: number, fps: number?)
		local old = S.dt
		if fps then
			S.dt = 1 / fps
		end
		S.wait(seconds)
		S.dt = old
	end

	function api.player()
		return R.localPlayer
	end

	-- Another player in the server (teammates for co-op scenes): a Player under Players
	-- with a name, DisplayName and UserId; no PlayerGui / scripts (it is not this client).
	function api.addPlayer(name: string, userId: number)
		local p = R.create("Player")
		local pst = states[p]
		pst.name = name
		pst.props.UserId = userId
		pst.props.DisplayName = name
		R.setParent(p, pst, R.services.Players)
		return p
	end

	-- Player:LoadCharacter / LoadCharacterWithHumanoidDescription build a plain avatar from
	-- now on (the SwarmV2 basecamp spawns the players' own avatars); off by default.
	function api.enableAvatars(on: boolean?)
		R.avatarLoads = on ~= false
	end

	function api.playerGui()
		return R.findChild(states[R.localPlayer], "PlayerGui")
	end

	function api.require(inst)
		return R.requireModule(inst)
	end

	-- ReplicatedStorage.Shared.<name> / ServerScriptService.Modules.<name>
	function api.shared(name: string)
		local shared = R.findChild(states[R.services.ReplicatedStorage], "Shared")
		return R.requireModule(R.findChild(states[shared], name) or error("no shared module " .. name))
	end

	function api.server(name: string)
		local modules = R.findChild(states[R.services.ServerScriptService], "Modules")
		local m = modules and R.findChild(states[modules], name)
		if not m then
			error("no server module " .. name)
		end
		return R.requireModule(m)
	end

	function api.failDataStores(reads: boolean, writes: boolean, opening: boolean?)
		R.dataStoreFailure = { Reads = reads, Writes = writes, Open = opening == true }
	end

	-- The client modules folder the running client uses (PlayerScripts copy).
	function api.clientFolder()
		local ps = R.findChild(states[R.localPlayer], "PlayerScripts")
		return R.findChild(states[ps], "SwarmClient")
	end

	function api.client(name: string)
		local folder = api.clientFolder()
		local m = folder and R.findChild(states[folder], name)
		if not m then
			error("no client module " .. name .. " (call preview.startClient first)")
		end
		return R.requireModule(m)
	end

	-- A brand-new save would drop every sim straight into the automatic first run
	-- (Config.FirstRun): scenes keep the lobby unless --set firstrun=on.
	local function firstRunSwitch()
		local ok, cfg = pcall(api.shared, "Config")
		if ok and type(cfg) == "table" and type(cfg.FirstRun) == "table" then
			cfg.FirstRun.AutoStart = api.args.firstrun == "on"
		end
	end

	-- Copies StarterPlayerScripts into PlayerScripts and runs the LocalScripts there
	-- (ClientMain), like Roblox does when the player joins.
	function api.startClient(runScripts: boolean?)
		firstRunSwitch()
		local sps = R.findChild(states[R.services.StarterPlayer], "StarterPlayerScripts")
		local ps = R.findChild(states[R.localPlayer], "PlayerScripts")
		for _, c in ipairs(states[sps].children) do
			local copy = R.clone(c)
			R.setParent(copy, states[copy], ps)
		end
		if runScripts ~= false then
			R.walk(ps, function(d)
				local st = states[d]
				if st.info.isA.LocalScript or (st.info.isA.Script and st.props.RunContext == roblox.Enum.RunContext.Client) then
					R.runScript(d)
				end
			end)
		end
	end

	-- Opt-in workspace:Raycast for a scene: fn(origin, direction, params) -> hit table or
	-- nil (Instance, Position, Normal, Distance, Material). nil restores "hits nothing".
	function api.setRaycast(fn)
		R.raycastHook = fn
	end

	-- Opt-in MarketplaceService:UserOwnsGamePassAsync for a scene: fn(userId, passId) ->
	-- boolean (may task.wait to model a slow lookup). nil restores "owns nothing".
	function api.setPassLookup(fn)
		R.passLookupHook = fn
	end

	-- MarketplaceService prompts opened so far: { {kind, id, t} } (store tests).
	function api.marketPrompts()
		local out = {}
		for _, e in ipairs(R.log.fired) do
			if e.remote == "MarketplaceService" then
				table.insert(out, { kind = e.direction, id = tonumber(e.args), t = e.t })
			end
		end
		return out
	end

	-- Fires a MarketplaceService event, e.g. ("PromptProductPurchaseFinished", userId, id, false).
	function api.marketEvent(name: string, ...)
		R.fire(states[R.services.MarketplaceService], name, ...)
	end

	-- Runs the server Scripts (GameServer) - the full server; needs more mocking.
	function api.startServer()
		firstRunSwitch()
		R.walk(R.services.ServerScriptService, function(d)
			local st = states[d]
			if st.info.name == "Script" then
				R.runScript(d)
			end
		end)
	end

	-- InsertService:LoadAsset downloads at most `slots` assets at once (first come, first
	-- served), `base` simulated seconds each (nil = instant, the default).
	function api.setLoadLatency(base: number?, slots: number?)
		R.loadLatency = base and { base = base, slots = slots or 6 } or nil
	end

	-- UserInputService:GetLastInputType() answers this (e.g. Enum.UserInputType.Gamepad1);
	-- nil = the device default (Touch on phones, MouseMovement otherwise).
	function api.setLastInput(kind: any)
		R.lastInput = kind
	end

	function api.forceMeshesUploaded()
		return M.forceUploaded()
	end

	function api.remote(name: string)
		local folder = R.findChild(states[R.services.ReplicatedStorage], "Remotes")
		local r = folder and R.findChild(states[folder], name)
		if not r then
			error("remote " .. name .. " does not exist (call Remotes.Setup first)")
		end
		return r
	end

	-- Another player's client → server call (co-op sims): fires OnServerEvent as `player`.
	function api.fireServerAs(player, name: string, ...)
		R.fire(states[api.remote(name)], "OnServerEvent", player, ...)
	end

	-- The teleport mock's state (classes/services.luau): placeId, privateServerId,
	-- privateServerOwnerId, joinData[UserId], reserveFails, teleportFails, calls.
	function api.teleport()
		return R.teleport
	end

	-- The AnalyticsService mock's record (classes/services.luau): calls, fails.
	function api.analytics()
		return R.analytics
	end

	-- TeleportService.TeleportInitFailed for a player (a teleport that failed after the call).
	function api.teleportInitFailed(p, message: string?)
		R.fire(states[R.services.TeleportService], "TeleportInitFailed", p, roblox.Enum.TeleportResult.Failure, message or "mock failure")
	end

	-- Players.PlayerAdded / PlayerRemoving for an addPlayer player (removal also unparents).
	function api.playerJoined(p)
		R.fire(states[R.services.Players], "PlayerAdded", p)
	end
	function api.removePlayer(p)
		R.fire(states[R.services.Players], "PlayerRemoving", p)
		p.Parent = nil
	end

	-- Server → this client, through the real RemoteEvent (logged).
	function api.fireClient(name: string, ...)
		api.remote(name):FireClient(R.localPlayer, ...)
	end

	-- Simulates a tap / click on a GuiButton.
	function api.click(button)
		local st = states[button]
		for _, ev in ipairs({ "MouseButton1Down", "MouseButton1Up", "MouseButton1Click", "Activated" }) do
			R.fire(st, ev)
		end
	end

	--[[
		Simulates one finger: a touch that begins at `opts.at` (screen px, default the
		button's centre), optionally drags `opts.drag` px and is held `opts.hold` seconds
		(the clock advances), then lifts. UserInputService InputBegan / Changed / Ended get
		a Touch input object; `button` (when the touch began on it and did not leave it)
		gets InputBegan / MouseButton1Down, then InputEnded / Activated(input) like a
		real tap. Returns the input object.
	]]
	function api.touch(button, opts)
		opts = opts or {}
		local uis = R.services.UserInputService
		local ust = uis and states[uis]
		local pos = opts.at
		if not pos and button then
			local l = api.layoutOf(button)
			pos = Vector2.new(l.x + l.w / 2, l.y + l.h / 2)
		end
		pos = pos or Vector2.zero
		local input = {
			UserInputType = Enum.UserInputType.Touch,
			UserInputState = Enum.UserInputState.Begin,
			KeyCode = Enum.KeyCode.Unknown,
			Position = Vector3.new(pos.X, pos.Y, 0),
			Delta = Vector3.zero,
		}
		local onButton = button ~= nil and opts.at == nil
		if ust then
			R.fire(ust, "InputBegan", input, onButton)
		end
		if onButton then
			R.fire(states[button], "InputBegan", input)
			R.fire(states[button], "MouseButton1Down", pos.X, pos.Y)
		end
		local drag = opts.drag or 0
		if drag ~= 0 then
			input.UserInputState = Enum.UserInputState.Change
			input.Position = Vector3.new(pos.X + drag, pos.Y, 0)
			input.Delta = Vector3.new(drag, 0, 0)
			if ust then
				R.fire(ust, "InputChanged", input, onButton)
			end
		end
		api.advance(opts.hold or 0.08)
		input.UserInputState = Enum.UserInputState.End
		if ust then
			R.fire(ust, "InputEnded", input, onButton)
		end
		if button and (opts.endOn or onButton) then
			R.fire(states[button], "InputEnded", input)
			-- a button only activates for a touch that began on it, or (opts.endOn) one
			-- that Roblox routes to it anyway (worst case for the level-up guard)
			R.fire(states[button], "MouseButton1Up", pos.X, pos.Y)
			R.fire(states[button], "Activated", input, 1)
		end
		return input
	end

	-- GuiObjects under PlayerGui whose Text (or Name) matches.
	function api.findGui(match)
		local out = {}
		R.walk(api.playerGui(), function(d)
			local st = states[d]
			if st.info.isA.GuiObject then
				local ok = false
				if type(match) == "function" then
					ok = match(d, st)
				else
					ok = st.name == match or (st.info.props.Text and R.getProp(st, "Text") == match)
				end
				if ok then
					table.insert(out, d)
				end
			end
		end)
		return out
	end

	function api.isShown(obj): boolean
		L.update(true)
		local l = states[obj].x.layout
		return l ~= nil and l.visible == true
	end

	function api.layoutOf(obj)
		L.update(true)
		return states[obj].x.layout
	end

	function api.overlay(shape)
		table.insert(api.overlays, shape)
	end

	function api.note(msg)
		R.note(msg)
	end

	function api.warn(msg)
		R.warn(msg)
	end

	function api.log(...)
		local parts = {}
		for i = 1, select("#", ...) do
			parts[i] = tostring((select(i, ...)))
		end
		print("[scene] " .. table.concat(parts, " "))
	end

	function api.worldCounts(root)
		return E.worldCounts(root or R.services.Workspace)
	end

	-- meshes/catalog.json by model name (tris, pieces, notes)
	function api.catalog()
		return R.catalogJson or {}
	end

	function api.state(inst)
		return states[inst]
	end

	-- Perf profiler (mock/profile.luau): scenes/perf-sim.luau.
	function api.profile(on: boolean)
		Prof.on = on == true
		Prof.reset()
	end
	-- Per-frame GUI layout off (it still runs whenever game code reads AbsoluteSize etc.):
	-- the mock's layout is far slower than Roblox's and is not game code.
	function api.setFrameLayout(on: boolean)
		R.skipFrameLayout = not on
	end
	api.realClock = os.clock -- the host clock (game code's os.clock is simulated time)
	api.profileEnter = Prof.enter
	api.profileLeave = Prof.leave
	api.profileReport = Prof.report

	-- Instances alive in the mock: in the DataModel tree, and all not destroyed (also
	-- unparented ones not yet garbage collected: Luau has no forced collection here).
	function api.liveInstances()
		local inTree, notDestroyed = 0, 0
		for _, st in pairs(states) do
			if not st.destroyed then
				notDestroyed += 1
			end
		end
		R.walk(R.game, function()
			inTree += 1
		end)
		return inTree, notDestroyed
	end

	-- Leak probes: connections still connected (by signal name), threads waiting on
	-- task.wait / task.delay, deferred threads, tweens in the active list, live Sounds
	-- (playing / all) not destroyed.
	function api.liveCounts()
		local out = { connections = 0, waiting = #S.waiting, deferred = #S.deferred, tweens = 0, sounds = 0, soundsPlaying = 0, bySignal = {}, byFn = {} }
		for c in pairs(R.connRegistry or {}) do
			if c.Connected then
				out.connections += 1
				local n = tostring(c._signal and c._signal._name)
				out.bySignal[n] = (out.bySignal[n] or 0) + 1
				-- the connected function's "Script:line" (where a growing count comes from)
				local f = type(c._fn) == "function" and Prof.fnLabel(c._fn) or "?"
				out.byFn[f] = (out.byFn[f] or 0) + 1
			end
		end
		out.tweens = R.activeTweens and #R.activeTweens or 0
		for _, st in pairs(states) do
			if not st.destroyed and st.info and st.info.name == "Sound" then
				out.sounds += 1
				if st.x and st.x.playing then
					out.soundsPlaying += 1
				end
			end
		end
		return out
	end

	-- forced GUI layouts per game line since the last reset (see layout.luau L.update)
	function api.forcedLayouts(reset: boolean?)
		local out = R.forcedLayouts or {}
		if reset then
			R.forcedLayouts = {}
		end
		return out
	end
	api.Mock = Mock
	R.api = api
	return api
end

------------------------------------------------------------------------------------------
-- Export
------------------------------------------------------------------------------------------

-- Converts Roblox values to JSON-friendly ones (scene metrics, overlays, render opts).
local function jsonSafe(v, depth)
	depth = depth or 0
	local t = D.typeof(v)
	if t == "table" then
		if depth > 12 then
			return nil
		end
		local out = {}
		for k, x in pairs(v) do
			out[k] = jsonSafe(x, depth + 1)
		end
		return out
	elseif t == "Color3" then
		return { v.R, v.G, v.B }
	elseif t == "Vector3" then
		return { v.X, v.Y, v.Z }
	elseif t == "Vector2" then
		return { v.X, v.Y }
	elseif t == "CFrame" then
		return { v:GetComponents() }
	elseif t == "EnumItem" or t == "Instance" or t == "UDim2" or t == "UDim" then
		return tostring(v)
	elseif t == "number" or t == "string" or t == "boolean" then
		return v
	end
	return nil
end

function Mock.export(sceneName: string)
	local api = R.api
	local ws = R.services.Workspace
	local cam = R.getProp(states[ws], "CurrentCamera")
	local camRec = { cf = { R.getProp(states[cam], "CFrame"):GetComponents() }, fov = R.getProp(states[cam], "FieldOfView") }
	if api.camera then
		if api.camera.cf then
			camRec.cf = { api.camera.cf:GetComponents() }
		end
		if api.camera.fov then
			camRec.fov = api.camera.fov
		end
		camRec.ortho = api.camera.ortho
		camRec.near = api.camera.near
		camRec.far = api.camera.far
	end
	local world = E.collectWorld(ws)
	local gui = E.gui()
	local counts = E.worldCounts(ws)
	local metrics = api.metrics
	metrics.scene = metrics.scene or counts
	local function list(entries)
		local out = {}
		for _, e in ipairs(entries) do
			table.insert(out, e)
		end
		return out
	end
	return {
		version = 1,
		scene = sceneName,
		seed = R.options.seed or 1,
		time = S.now,
		device = R.options.device,
		camera = camRec,
		lighting = E.lighting(),
		world = world,
		gui = gui,
		overlays = jsonSafe(api.overlays),
		render = jsonSafe(api.render),
		metrics = jsonSafe(metrics),
		log = {
			errors = list(R.log.errors),
			warnings = list(R.log.warnings),
			notes = list(R.log.notes),
			remotes = R.log.fired,
		},
	}
end

Mock.R = R
Mock.S = S
return Mock
