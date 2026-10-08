--!strict
--[[
	SwarmV2/Run/ClassAnimator.lua  (StarterPlayerScripts.SwarmV2Client.Run.ClassAnimator)
	OWNER: gameplay track (Chat 2).

	Procedural animation for the four class characters (ruckus, toastmaster, captain_croak,
	granny_boom). The models are rigid MeshParts joined with Motor6Ds (ModelBuilder
	buildMeshCharacter), so this module only writes Motor6D.Transform; C0 / C1 are never touched.

	Who: every player whose player attribute "CharacterId" is a class id (local player and
	others). Cheap by design: nobody beyond FAR studs is animated, and beyond NEAR studs a
	character updates at 30 Hz.

	Reads (player attributes): CharacterId, ClassFired (any change = the class weapon just
	fired; the server may bump a counter or set a timestamp), Leaping (bool, Captain Croak).
	Reads (character): Humanoid.FloorMaterial, HumanoidRootPart velocity.
	Reduced effects (ClientSettings.Reduced) damps every motion and drops the pops.

	Init() is called once from RunClient.
]]

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")

local Client = script.Parent.Parent.Parent:WaitForChild("SwarmClient")
local ClientSettings = require(Client:WaitForChild("ClientSettings"))

local ClassAnimator = {}

local FAR = 120
local NEAR = 40
local FAR_STEP = 1 / 30

local CLASS_IDS: { [string]: boolean } = { ruckus = true, toastmaster = true, captain_croak = true, granny_boom = true }

-- Per class tuning. Angles in radians, offsets in studs.
type Tune = {
	Cycle: number, -- walk phase speed per stud/second
	LegSwing: number,
	ArmSwing: number, -- 0 for Granny (hands hold the walker)
	Bob: number, -- vertical torso bob while walking
	Lean: number, -- forward lean at full speed
	Sway: number, -- torso roll with the stride
	HeadTilt: number,
	IdleBob: number,
	Hop: boolean, -- stiff hop: both legs together, bounce on every step
	Snap: boolean, -- sharp steps (Toastmaster)
}

local TUNE: { [string]: Tune } = {
	ruckus = { Cycle = 0.55, LegSwing = 0.75, ArmSwing = 0.8, Bob = 0.12, Lean = 0.12, Sway = 0.14, HeadTilt = 0.12, IdleBob = 0.04, Hop = false, Snap = false },
	toastmaster = { Cycle = 0.5, LegSwing = 0.35, ArmSwing = 0.15, Bob = 0.28, Lean = 0.04, Sway = 0.03, HeadTilt = 0.03, IdleBob = 0.02, Hop = true, Snap = true },
	captain_croak = { Cycle = 0.5, LegSwing = 0.7, ArmSwing = 0.6, Bob = 0.1, Lean = 0.1, Sway = 0.08, HeadTilt = 0.06, IdleBob = 0.05, Hop = false, Snap = false },
	granny_boom = { Cycle = 0.4, LegSwing = 0.4, ArmSwing = 0, Bob = 0.07, Lean = 0.05, Sway = 0.07, HeadTilt = 0.05, IdleBob = 0.03, Hop = false, Snap = false },
}

type Joints = {
	Root: Motor6D,
	Neck: Motor6D,
	LS: Motor6D,
	RS: Motor6D,
	LH: Motor6D,
	RH: Motor6D,
}

type State = {
	Player: Player,
	Char: Model,
	ClassId: string,
	Tune: Tune,
	Joints: Joints,
	Hum: Humanoid,
	Root: BasePart,
	Phase: number,
	Time: number,
	Acc: number, -- dt accumulated since the last update (far characters)
	Grounded: boolean,
	Squash: number, -- landing squash 0..1 (decays)
	Stretch: number, -- 0..1 while rising
	Crouch: number, -- Croak crouch 0..1 (eased)
	Leaping: boolean,
	Pop: number, -- Toastmaster head pop 0..1 (decays)
	Kick: number, -- Granny torso recoil 0..1 (decays)
	Boing: number, -- Croak landing boing 0..1 (decays)
	BoingT: number,
	Speed: number,
	Conns: { RBXScriptConnection },
}

local states: { [Model]: State } = {}
local playerConns: { [Player]: { RBXScriptConnection } } = {}

local function reduced(): boolean
	local ok, v = pcall(ClientSettings.Reduced)
	return ok and v == true
end

local function ease(cur: number, target: number, dt: number, rate: number): number
	return cur + (target - cur) * math.min(1, dt * rate)
end

local function stop(char: Model)
	local st = states[char]
	if not st then
		return
	end
	states[char] = nil
	for _, c in st.Conns do
		c:Disconnect()
	end
	-- leave the rig in its rest pose
	local j = st.Joints
	for _, m in { j.Root, j.Neck, j.LS, j.RS, j.LH, j.RH } do
		if m.Parent then
			m.Transform = CFrame.new()
		end
	end
end

local function findJoints(char: Model): Joints?
	local root = char:FindFirstChild("HumanoidRootPart")
	local torso = char:FindFirstChild("Torso")
	if not (root and torso) then
		return nil
	end
	local function m(parent: Instance, name: string): Motor6D?
		local x = parent:FindFirstChild(name)
		return if x and x:IsA("Motor6D") then x else nil
	end
	local r, n = m(root, "RootJoint"), m(torso, "Neck")
	local ls, rs = m(torso, "Left Shoulder"), m(torso, "Right Shoulder")
	local lh, rh = m(torso, "Left Hip"), m(torso, "Right Hip")
	if r and n and ls and rs and lh and rh then
		return { Root = r, Neck = n, LS = ls, RS = rs, LH = lh, RH = rh }
	end
	return nil
end

local function start(plr: Player, char: Model)
	if states[char] then
		return
	end
	local id = plr:GetAttribute("CharacterId")
	if type(id) ~= "string" or not CLASS_IDS[id] then
		return
	end
	local hum = char:FindFirstChildOfClass("Humanoid")
	local root = char:FindFirstChild("HumanoidRootPart")
	local joints = findJoints(char)
	if not (hum and root and root:IsA("BasePart") and joints) then
		return
	end
	local st: State = {
		Player = plr,
		Char = char,
		ClassId = id,
		Tune = TUNE[id],
		Joints = joints,
		Hum = hum,
		Root = root,
		Phase = 0,
		Time = math.random() * 10,
		Acc = 0,
		Grounded = true,
		Squash = 0,
		Stretch = 0,
		Crouch = 0,
		Leaping = plr:GetAttribute("Leaping") == true,
		Pop = 0,
		Kick = 0,
		Boing = 0,
		BoingT = 0,
		Speed = 0,
		Conns = {},
	}
	states[char] = st
	table.insert(st.Conns, plr:GetAttributeChangedSignal("ClassFired"):Connect(function()
		if reduced() then
			return
		end
		if st.ClassId == "toastmaster" then
			st.Pop = 1
		elseif st.ClassId == "granny_boom" then
			st.Kick = 1
		end
	end))
	table.insert(st.Conns, plr:GetAttributeChangedSignal("Leaping"):Connect(function()
		st.Leaping = plr:GetAttribute("Leaping") == true
	end))
	table.insert(st.Conns, char.AncestryChanged:Connect(function(_, parent)
		if parent == nil then
			stop(char)
		end
	end))
	table.insert(st.Conns, hum.Died:Connect(function()
		stop(char)
	end))
end

local function track(plr: Player)
	if playerConns[plr] then
		return
	end
	local conns: { RBXScriptConnection } = {}
	playerConns[plr] = conns
	local function try()
		local char = plr.Character
		if not (char and char.Parent) then
			return
		end
		-- a class change on the same character: restart with the new tuning
		local old = states[char]
		if old and old.ClassId ~= plr:GetAttribute("CharacterId") then
			stop(char)
		end
		task.spawn(function()
			-- the rig can arrive a moment after the character: wait for its joints
			local t0 = os.clock()
			while char.Parent and not findJoints(char) and os.clock() - t0 < 10 do
				task.wait(0.25)
			end
			if char.Parent and plr.Character == char then
				start(plr, char)
			end
		end)
	end
	table.insert(conns, plr.CharacterAdded:Connect(try))
	table.insert(conns, plr:GetAttributeChangedSignal("CharacterId"):Connect(try))
	table.insert(conns, plr.CharacterRemoving:Connect(function(char)
		stop(char)
	end))
	try()
end

local function untrack(plr: Player)
	local conns = playerConns[plr]
	if conns then
		for _, c in conns do
			c:Disconnect()
		end
		playerConns[plr] = nil
	end
	if plr.Character then
		stop(plr.Character)
	end
end

-- One pose update. dt is the time since this character's last update.
local function pose(st: State, dt: number, damp: number)
	local t = st.Tune
	local hum, root = st.Hum, st.Root
	st.Time += dt

	local vel = root.AssemblyLinearVelocity
	local speed = Vector3.new(vel.X, 0, vel.Z).Magnitude
	st.Speed = ease(st.Speed, speed, dt, 12)
	local grounded = hum.FloorMaterial ~= Enum.Material.Air
	local rising = (not grounded) and vel.Y > 2

	-- landing squash (by how fast we fell); Croak also boings
	if grounded and not st.Grounded then
		st.Squash = math.max(st.Squash, math.clamp(math.abs(vel.Y) / 50, 0.35, 1))
		if st.ClassId == "captain_croak" then
			st.Boing = 1
			st.BoingT = 0
		end
	end
	st.Grounded = grounded
	st.Squash = ease(st.Squash, 0, dt, 9)
	st.Stretch = ease(st.Stretch, rising and 1 or 0, dt, 14)
	st.Pop = math.max(0, st.Pop - dt * 5)
	st.Kick = math.max(0, st.Kick - dt * 4.5)
	if st.Boing > 0 then
		st.BoingT += dt
		st.Boing = math.max(0, st.Boing - dt * 2.2)
	end
	local crouchTarget = (st.ClassId == "captain_croak" and st.Leaping and grounded) and 1 or 0
	st.Crouch = ease(st.Crouch, crouchTarget, dt, 14)

	local walkAmt = math.clamp(st.Speed / 14, 0, 1.4) * (grounded and 1 or 0.25)
	st.Phase += dt * st.Speed * t.Cycle * 2
	local ph = st.Phase
	local swing = math.sin(ph)
	if t.Snap then
		swing = math.clamp(swing * 2.2, -1, 1)
	end
	local idle = 1 - math.min(1, walkAmt * 2)
	local breathe = math.sin(st.Time * 2.2)

	-- vertical body offset (studs): bob / hop, breathe, squash, crouch, boing
	local bounce = math.abs(math.sin(ph)) * (if t.Hop then 1 else 0.6)
	local y = bounce * t.Bob * walkAmt + breathe * t.IdleBob * idle
	if st.Boing > 0 then
		y += math.sin(st.BoingT * 18) * st.Boing * 0.25
	end
	y = y - st.Squash * 0.35 - st.Crouch * 0.45 + st.Stretch * 0.12

	-- body angles
	local pitch = -t.Lean * walkAmt + st.Squash * 0.12 + st.Crouch * 0.18 - st.Stretch * 0.08 + st.Kick * 0.28
	local roll = -swing * t.Sway * walkAmt + math.sin(st.Time * 1.3) * 0.02 * idle
	if st.ClassId == "ruckus" then
		roll += math.sin(st.Time * 1.7) * 0.03 * idle
	end

	local j = st.Joints
	j.Root.Transform = CFrame.new(0, y * damp, 0) * CFrame.Angles(pitch * damp, 0, roll * damp)

	-- head: counter-sway, tilt, Toastmaster pop
	local headRoll = roll * -0.6 + math.sin(st.Time * 1.9) * t.HeadTilt * 0.4 * idle
	local headPitch = -pitch * 0.5 + breathe * 0.015 * idle
	local headY = 0
	if st.ClassId == "ruckus" then
		headRoll += swing * t.HeadTilt * walkAmt
	elseif st.ClassId == "toastmaster" then
		headY = st.Pop * 0.3
		headPitch -= st.Pop * 0.12
	elseif st.ClassId == "captain_croak" then
		headPitch += st.Crouch * 0.2 - st.Stretch * 0.15
	end
	j.Neck.Transform = CFrame.new(0, headY * damp, 0) * CFrame.Angles(headPitch * damp, 0, headRoll * damp)

	-- legs
	local legA = t.LegSwing * walkAmt
	local lSwing, rSwing = swing, -swing
	if t.Hop then
		lSwing, rSwing = swing * 0.6, swing * 0.6
	end
	local legAir = 0
	if not grounded then
		legAir = if rising then 0.35 else -0.2
	end
	local tuck = st.Crouch * 0.7 + st.Squash * 0.35
	j.LH.Transform = CFrame.Angles((lSwing * legA + legAir - tuck) * damp, 0, 0)
	j.RH.Transform = CFrame.Angles((rSwing * legA + legAir - tuck) * damp, 0, 0)

	-- arms (Granny's hands hold the walker: tiny recoil only)
	if t.ArmSwing > 0 then
		local armA = t.ArmSwing * walkAmt
		local up = 0
		if not grounded then
			up = if rising then -1.1 else -0.6
		end
		local sx = breathe * 0.05 * idle
		j.LS.Transform = CFrame.Angles((-lSwing * armA + up + sx - st.Crouch * 0.4) * damp, 0, 0)
		j.RS.Transform = CFrame.Angles((-rSwing * armA + up - sx - st.Crouch * 0.4) * damp, 0, 0)
	else
		local r = (st.Kick * 0.12 + math.sin(ph) * 0.02 * walkAmt) * damp
		j.LS.Transform = CFrame.Angles(r, 0, 0)
		j.RS.Transform = CFrame.Angles(r, 0, 0)
	end
end

local function step(dt: number)
	local cam = workspace.CurrentCamera
	if not cam then
		return
	end
	local camPos = cam.CFrame.Position
	local damp = if reduced() then 0.35 else 1
	for char, st in states do
		if not (char.Parent and st.Root.Parent and st.Hum.Health > 0) then
			stop(char)
			continue
		end
		local dist = (st.Root.Position - camPos).Magnitude
		if dist > FAR then
			continue
		end
		st.Acc += dt
		if dist > NEAR and st.Acc < FAR_STEP then
			continue
		end
		local d = math.min(st.Acc, 0.1)
		st.Acc = 0
		pose(st, d, damp)
	end
end

local started = false

function ClassAnimator.Init()
	if started then
		return
	end
	started = true
	for _, p in Players:GetPlayers() do
		track(p)
	end
	Players.PlayerAdded:Connect(track)
	Players.PlayerRemoving:Connect(untrack)
	RunService.RenderStepped:Connect(step)
end

-- Number of characters being animated (checks).
function ClassAnimator.Count(): number
	local n = 0
	for _ in states do
		n += 1
	end
	return n
end

return ClassAnimator
