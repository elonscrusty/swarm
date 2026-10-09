--!strict
--[[
	SwarmV2/Run/Dash.lua  (ServerScriptService.SwarmV2.Run.Dash)
	OWNER: gameplay track (Chat 2). Design: docs/redesign/gameplay/DESIGN.md section 2.

	Server-validated dash. The client sends one unit direction on ReplicatedStorage.SwarmV2Net.Run.Dash
	(no position, no speed); the server checks the player and answers on DashAck. The client (network
	owner of its character) then moves itself; RunManager.speedCheck allows the extra speed while
	rp.DashUntil is current.

	Checked: the remote's arguments (a finite Vector3, unit length, flat), a per-player rate limit,
	alive, in a run, not paused / frozen / travelling / in a chest reel, root free, cooldown passed.

	Per-class variants (RunConfig.Dash.Variants keyed by class id). Kind "Leap" is a ballistic arc.

	Run player fields set here (read by RunManager.speedCheck): rp.DashUntil (os.clock), rp.DashSpeed,
	rp.DashAllow (studs/s the speed check allows), rp.DashDir, rp.DashKind, rp.DashReadyAt (os.clock).
	Player attributes for the HUD: DashReadyAt (workspace:GetServerTimeNow() when ready), DashCd (seconds).

	Rules (stream E1, RunConfig.Dash + RunConfig.Survival): 70 studs/s for 0.22 s, the 2.5 s cooldown
	counted from the dash start, no invulnerability (RunManager.DamagePlayer knows nothing of
	dashes), the requested flat direction else facing (the client picks, the server checks it is
	a flat unit vector), a wall ends the forward travel and a ground dash gains no upward speed on
	a slope (DashClient). The landing check below also measures falls (RunManager.OnFallLanding).

	Server hooks (use :Connect(callback), which returns a connection with :Disconnect()):
	  Dash.OnDash        callback(rp, kind: "Dash" | "Leap", dir: Vector3)
	  Dash.OnLeapLanded  callback(rp)
	  Dash.OnLanded      callback(rp, airtime: number)   landings after at least RunConfig.Dash.LandMinAirtime in the air
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local RunConfig = require(ReplicatedStorage:WaitForChild("SwarmV2"):WaitForChild("Run"):WaitForChild("RunConfig"))

export type Connection = { Connected: boolean, Disconnect: (self: Connection) -> () }
export type Signal = {
	Connect: (self: Signal, callback: (...any) -> ()) -> Connection,
	Fire: (self: Signal, ...any) -> (),
}

local function newSignal(): Signal
	local callbacks: { (...any) -> () } = {}
	local sig = {} :: any
	function sig.Connect(_self: any, callback: (...any) -> ()): Connection
		table.insert(callbacks, callback)
		local conn = { Connected = true } :: any
		function conn.Disconnect(self: any)
			self.Connected = false
			local i = table.find(callbacks, callback)
			if i then
				table.remove(callbacks, i)
			end
		end
		return conn :: Connection
	end
	function sig.Fire(_self: any, ...)
		for _, cb in ipairs(table.clone(callbacks)) do
			local ok, err = (pcall :: any)(cb, ...)
			if not ok then
				warn("[Dash] hook failed: " .. tostring(err))
			end
		end
	end
	return sig :: Signal
end

local Dash = {}
Dash.OnDash = newSignal()
Dash.OnLeapLanded = newSignal()
Dash.OnLanded = newSignal()

local D = RunConfig.Dash
local ctx: any = nil
local launchRemote: RemoteEvent? = nil
local ackRemote: RemoteEvent? = nil

local buckets: { [Player]: { tokens: number, last: number } } = {}
type AirState = { AirSince: number?, PeakY: number?, Params: RaycastParams?, FilterFor: Instance? }
local airStates: { [Player]: AirState } = {}

-- Finds or creates a child (FindFirstChild before Instance.new, the lobby track may boot first).
local function ensure(parent: Instance, className: string, name: string): Instance
	local found = parent:FindFirstChild(name)
	if found then
		return found
	end
	local inst = Instance.new(className)
	inst.Name = name
	inst.Parent = parent
	return inst
end

local function allow(player: Player): boolean
	local now = os.clock()
	local rate = D.RequestRate
	local b = buckets[player]
	if not b then
		b = { tokens = rate, last = now }
		buckets[player] = b
	end
	b.tokens = math.min(rate, b.tokens + (now - b.last) * rate)
	b.last = now
	if b.tokens < 1 then
		return false
	end
	b.tokens -= 1
	return true
end

local function finite(n: number): boolean
	return n == n and n ~= math.huge and n ~= -math.huge
end

-- Canonical class id of a run player ("" when unknown). [stream E1] The run's hero comes first:
-- rp.CharacterId is set from the admitted class (never a client claim). The lobby's SwarmClass
-- attribute (the basecamp selection, UI only) is only a last fallback: it can differ from the
-- admitted class, and preferring it gave every class the default dash.
function Dash.GetClassId(rp: any): string
	local id = rp.ClassId
	if type(id) ~= "string" or id == "" then
		id = rp.CharacterId
	end
	if type(id) ~= "string" or id == "" then
		id = rp.Player and rp.Player:GetAttribute("SwarmClass")
	end
	return if type(id) == "string" then id else ""
end

-- The dash definition of a class id (the default when the class has no variant).
function Dash.GetDef(classId: string): RunConfig.DashDef
	return D.Variants[classId] or D.Default
end

-- Seconds until the player may dash again (0 = ready).
function Dash.CooldownRemaining(rp: any): number
	return math.max(0, (rp.DashReadyAt or 0) - os.clock())
end

-- Makes the dash ready at once (kits and pickups may call this).
function Dash.ResetCooldown(rp: any)
	rp.DashReadyAt = 0
	local player: Player? = rp.Player
	if player then
		player:SetAttribute("DashReadyAt", 0)
	end
end

-- True while the dash (or leap) of this run player is moving them.
function Dash.IsDashing(rp: any): boolean
	return rp.DashUntil ~= nil and os.clock() < rp.DashUntil
end

--[[
	A server-started ballistic launch (spring launch pads): the same arc as a leap from
	`from` to `target`, with the speed-check allowance, no cooldown change. The client
	(network owner) flies itself after the Launch remote. False when the player can't.
]]
function Dash.Launch(rp: any, from: Vector3, target: Vector3, extraApex: number): boolean
	local remote = launchRemote
	local root: BasePart? = rp.Root
	if not remote or not root or not rp.Alive or rp.Paused or rp.RewardUntil then
		return false
	end
	local flatV = Vector3.new(target.X - from.X, 0, target.Z - from.Z)
	local dist = flatV.Magnitude
	if dist < 4 then
		return false
	end
	local g = workspace.Gravity
	local rise = math.max(0, target.Y - from.Y)
	local apex = rise + math.max(4, extraApex)
	local vy = math.sqrt(2 * g * apex)
	-- time up to the apex, then down to the target height
	local duration = vy / g + math.sqrt(2 * (apex - rise) / g)
	local speed = dist / duration
	local now = os.clock()
	rp.DashKind = "Leap"
	rp.DashDir = flatV.Unit
	rp.DashSpeed = speed
	rp.DashAllow = speed * D.LeapAllowMult
	rp.DashUntil = now + duration
	rp.LeapUntil = now + duration + 1.5
	remote:FireClient(rp.Player, flatV.Unit, speed, duration, vy)
	return true
end

local function reply(player: Player, ok: boolean, kind: string, dir: Vector3, speed: number, duration: number, vy: number, cooldown: number)
	local ack = ackRemote
	if ack then
		ack:FireClient(player, ok, kind, dir, speed, duration, vy, cooldown)
	end
end

local function handleRequest(player: Player, dir: any)
	if not allow(player) then
		return
	end
	if typeof(dir) ~= "Vector3" then
		return
	end
	local d = dir :: Vector3
	if not (finite(d.X) and finite(d.Y) and finite(d.Z)) then
		return
	end
	local mag = d.Magnitude
	if mag < 0.95 or mag > 1.05 or math.abs(d.Y) > 0.05 then
		return
	end
	local flat = Vector3.new(d.X, 0, d.Z)
	if flat.Magnitude < 0.5 then
		return
	end
	flat = flat.Unit

	local RunManager = ctx.RunManager
	local rp = RunManager.GetRunPlayer(player)
	if not rp or rp.Returned or not rp.Alive then
		return
	end
	local root: BasePart? = rp.Root
	local hum: Humanoid? = rp.Humanoid
	if not root or not root.Parent or root.Anchored or not hum or hum.Health <= 0 then
		return
	end
	if rp.Paused or rp.RewardUntil or not RunManager.IsRunning() or RunManager.IsFrozen() or ctx.StageManager.IsHolding() then
		return
	end

	local now = os.clock()
	local classId = Dash.GetClassId(rp)
	local def = Dash.GetDef(classId)
	if (rp.DashReadyAt or 0) - D.CooldownSlack > now then
		-- too early: tell the client when it is ready so its ring stays right
		reply(player, false, def.Kind, flat, 0, 0, 0, math.max(0, (rp.DashReadyAt or 0) - now))
		return
	end

	local cooldown = def.Cooldown * (if type(rp.DashCooldownMult) == "number" then math.max(0.1, rp.DashCooldownMult) else 1)
	local speed, duration, vy = def.Speed, def.Duration, 0
	local allowSpeed = speed * D.AllowMult
	if def.Kind == "Leap" then
		-- ballistic: vy for the apex, horizontal speed so the arc covers Horizontal in its flight time
		local g = workspace.Gravity
		vy = math.sqrt(2 * g * (def.Apex or 7))
		duration = 2 * vy / g
		speed = (def.Horizontal or 31) / duration
		allowSpeed = speed * D.LeapAllowMult
		rp.LeapUntil = now + duration + 1.5
	end

	rp.DashKind = def.Kind
	rp.DashDir = flat
	rp.DashSpeed = speed
	rp.DashAllow = allowSpeed
	rp.DashUntil = now + duration
	rp.DashReadyAt = now + cooldown
	player:SetAttribute("DashCd", cooldown)
	player:SetAttribute("DashReadyAt", workspace:GetServerTimeNow() + cooldown)

	reply(player, true, def.Kind, flat, speed, duration, vy, cooldown)
	Dash.OnDash:Fire(rp, def.Kind, flat)
end

-- Landing detection from the server's view of the character: a short ray down from the root.
-- (Humanoid state is simulated by the client, so the ray is the dependable signal.)
local function groundedNow(rp: any, st: AirState): boolean
	local root: BasePart? = rp.Root
	local hum: Humanoid? = rp.Humanoid
	if not root or not hum then
		return true
	end
	local p: RaycastParams
	if st.Params then
		p = st.Params :: RaycastParams
	else
		p = RaycastParams.new()
		p.FilterType = Enum.RaycastFilterType.Exclude
		p.RespectCanCollide = true
		st.Params = p
	end
	-- [stream H] the filter list is set once per character, not rebuilt LandCheckHz times a
	-- second per player (a new table and a filter copy each check)
	local char = root.Parent :: Instance
	if st.FilterFor ~= char then
		st.FilterFor = char
		p.FilterDescendantsInstances = { char }
	end
	local reach = root.Size.Y / 2 + hum.HipHeight + D.GroundProbe
	return workspace:Raycast(root.Position, Vector3.new(0, -reach, 0), p) ~= nil
end

--[[
	[stream E1] One landing, recognized once: the air state runs grounded -> airborne (AirSince, the
	highest root height PeakY) -> grounded, and only that last transition is a landing. A teleport,
	travel or out-of-bounds rescue sets rp.AirReset (RunManager.TeleportPlayer): the state starts
	over, so the arrival is no landing (no fall damage, no landing ability). Falls hurt through
	RunManager.OnFallLanding(rp, drop) (Survival.Fall); a leap / launch-pad arc never does.
]]
local function landingStep()
	local now = os.clock()
	for _, rp in ipairs(ctx.RunManager.GetRunPlayers()) do
		local player: Player = rp.Player
		local st = airStates[player]
		if not st then
			st = { AirSince = nil, PeakY = nil, Params = nil, FilterFor = nil }
			airStates[player] = st
		end
		local root: BasePart? = rp.Root
		if rp.AirReset then
			rp.AirReset = nil
			st.AirSince = nil
			st.PeakY = nil
		elseif rp.Returned or not rp.Alive or not root or not root.Parent or root.Anchored then
			st.AirSince = nil
			st.PeakY = nil
		elseif groundedNow(rp, st) then
			local since = st.AirSince
			if since then
				local drop = (st.PeakY or root.Position.Y) - root.Position.Y
				st.AirSince = nil
				st.PeakY = nil
				local airtime = now - since
				local leaping = rp.LeapUntil ~= nil and now <= rp.LeapUntil
				if leaping and airtime >= D.LeapLandMinAirtime then
					rp.LeapUntil = nil
					Dash.OnLeapLanded:Fire(rp)
				end
				if airtime >= D.LandMinAirtime then
					Dash.OnLanded:Fire(rp, airtime)
				end
				if not leaping and ctx.RunManager.OnFallLanding then
					ctx.RunManager.OnFallLanding(rp, drop)
				end
			end
		elseif not st.AirSince then
			st.AirSince = now
			st.PeakY = root.Position.Y
		else
			st.PeakY = math.max(st.PeakY or root.Position.Y, root.Position.Y)
		end
		if rp.LeapUntil and now > rp.LeapUntil then
			rp.LeapUntil = nil
		end
	end
end

function Dash.Init(runCtx: any)
	ctx = runCtx
	local net = ensure(ReplicatedStorage, "Folder", "SwarmV2Net")
	local runFolder = ensure(net, "Folder", "Run")
	local request = ensure(runFolder, "RemoteEvent", "Dash") :: RemoteEvent
	ackRemote = ensure(runFolder, "RemoteEvent", "DashAck") :: RemoteEvent
	launchRemote = ensure(runFolder, "RemoteEvent", "Launch") :: RemoteEvent

	request.OnServerEvent:Connect(function(player: Player, dir: any)
		local ok, err = (pcall :: any)(handleRequest, player, dir)
		if not ok then
			warn("[Dash] request failed: " .. tostring(err))
		end
	end)

	Players.PlayerRemoving:Connect(function(player)
		buckets[player] = nil
		airStates[player] = nil
	end)

	local acc = 0
	local step = 1 / math.max(1, D.LandCheckHz)
	RunService.Heartbeat:Connect(function(dt)
		acc += dt
		if acc < step then
			return
		end
		acc = 0
		local ok, err = (pcall :: any)(landingStep)
		if not ok then
			warn("[Dash] landing check failed: " .. tostring(err))
		end
	end)
end

return Dash
