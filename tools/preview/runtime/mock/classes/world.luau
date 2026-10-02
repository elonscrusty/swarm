--!nocheck
--[[
	classes/world.luau - 3D classes: parts, models, camera, workspace, attachments, joints,
	humanoids, lighting, sounds, InsertService (mesh assets) and effect instances.

	Joints: there is no physics. Setting a part's CFrame moves the unanchored parts joined
	to it as Part1 (Motor6D / Weld: Part0 * C0 * Transform * C1:Inverse(); WeldConstraint:
	the offset captured when both parts were set). Motor6D.Transform changes move Part1.
	Model:PivotTo / workspace:BulkMoveTo move every part at once without propagation.
]]

local roblox = require("@lune/roblox")
local R = require("../R")
local D = require("../datatypes")
local S = require("../scheduler")

local states = R.states
local CFrame, Vector3, Vector2, Color3 = roblox.CFrame, roblox.Vector3, roblox.Vector2, roblox.Color3
local Enum = roblox.Enum

local function getProp(st, key)
	local v = st.props[key]
	if v == nil then
		v = st.info.defaults[key]
	end
	return v
end
R.getProp = getProp

------------------------------------------------------------------------------------------
-- Joint propagation
------------------------------------------------------------------------------------------

R.batchMove = false

local function setCFrameRaw(part, st, cf)
	local old = getProp(st, "CFrame")
	st.props.CFrame = cf
	if old ~= cf then
		R.changed(part, st, "CFrame")
	end
end
R.setCFrameRaw = setCFrameRaw

local function applyJoint(joint)
	local jst = states[joint]
	if not jst or jst.destroyed then
		return
	end
	local p0, p1 = getProp(jst, "Part0"), getProp(jst, "Part1")
	if not p0 or not p1 then
		return
	end
	local s0, s1 = states[p0], states[p1]
	if not s0 or not s1 or getProp(s1, "Anchored") then
		return
	end
	if jst.info.isA.WeldConstraint then
		if getProp(jst, "Enabled") == false or not jst.x.offset then
			return
		end
		setCFrameRaw(p1, s1, getProp(s0, "CFrame") * jst.x.offset)
	elseif jst.info.isA.JointInstance then
		if getProp(jst, "Enabled") == false then
			return
		end
		local c0, c1 = getProp(jst, "C0"), getProp(jst, "C1")
		local transform = jst.info.isA.Motor6D and getProp(jst, "Transform") or CFrame.identity
		setCFrameRaw(p1, s1, getProp(s0, "CFrame") * c0 * transform * c1:Inverse())
	end
end

local function propagate(part, st)
	local joints = st.x.joints0
	if not joints or R.batchMove then
		return
	end
	for _, j in ipairs(joints) do
		applyJoint(j)
	end
end

local function registerJoint(joint, jst)
	-- remove from the old Part0's list
	local old = jst.x.registeredOn
	if old and states[old] then
		local list = states[old].x.joints0
		local i = list and table.find(list, joint)
		if i then
			table.remove(list, i)
		end
	end
	jst.x.registeredOn = nil
	local p0, p1 = getProp(jst, "Part0"), getProp(jst, "Part1")
	if p0 and p1 then
		local s0 = states[p0]
		s0.x.joints0 = s0.x.joints0 or {}
		table.insert(s0.x.joints0, joint)
		jst.x.registeredOn = p0
		if jst.info.isA.WeldConstraint then
			jst.x.offset = getProp(s0, "CFrame"):ToObjectSpace(getProp(states[p1], "CFrame"))
		end
	end
end

R.defineClass("JointInstance", {
	onChange = function(joint, jst, key)
		if key == "Part0" or key == "Part1" then
			registerJoint(joint, jst)
		elseif key == "Transform" or key == "C0" or key == "C1" then
			if jst.x.applyOnChange or key == "Transform" then
				applyJoint(joint)
			end
		end
	end,
	defaults = { Transform = CFrame.identity, Enabled = true },
	props = { Transform = { type = "CFrame" } },
	onClone = function(_, _, _, dstState)
		dstState.x.registeredOn = nil
		dstState.x.needsRegister = true
	end,
})

R.defineClass("WeldConstraint", {
	onChange = function(joint, jst, key)
		if key == "Part0" or key == "Part1" or key == "Enabled" then
			registerJoint(joint, jst)
		end
	end,
	onClone = function(_, _, _, dstState)
		dstState.x.registeredOn = nil
		dstState.x.needsRegister = true
	end,
})

-- Joints inside a clone are registered again after the clone is assembled.
local baseClone = R.clone
R.clone = function(proxy)
	local root = baseClone(proxy)
	if root then
		R.walk(root, function(d)
			local st = states[d]
			if st.x.needsRegister then
				st.x.needsRegister = nil
				registerJoint(d, st)
			end
		end)
	end
	return root
end
R.classDefs.Instance.methods.Clone = R.clone
R.classDefs.Instance.methods.clone = R.clone

------------------------------------------------------------------------------------------
-- PVInstance / BasePart
------------------------------------------------------------------------------------------

local function orientationOf(cf: CFrame): Vector3
	local rx, ry, rz = cf:ToOrientation()
	return Vector3.new(math.deg(rx), math.deg(ry), math.deg(rz))
end

local function partPivot(part, st)
	return getProp(st, "CFrame") * getProp(st, "PivotOffset")
end

R.defineClass("BasePart", {
	events = { "Touched", "TouchEnded", "LocalSimulationTouched", "OutfitChanged", "StoppedTouching" },
	defaults = {
		Material = Enum.Material.Plastic,
		LocalTransparencyModifier = 0,
		AssemblyLinearVelocity = Vector3.zero,
		AssemblyAngularVelocity = Vector3.zero,
		TopSurface = Enum.SurfaceType.Smooth,
		BottomSurface = Enum.SurfaceType.Smooth,
		FrontSurface = Enum.SurfaceType.Smooth,
		BackSurface = Enum.SurfaceType.Smooth,
		LeftSurface = Enum.SurfaceType.Smooth,
		RightSurface = Enum.SurfaceType.Smooth,
		Friction = 0.3,
		Elasticity = 0.5,
	},
	getters = {
		Position = function(_, st)
			return getProp(st, "CFrame").Position
		end,
		Orientation = function(_, st)
			return orientationOf(getProp(st, "CFrame"))
		end,
		Rotation = function(_, st)
			local rx, ry, rz = getProp(st, "CFrame"):ToEulerAnglesXYZ()
			return Vector3.new(math.deg(rx), math.deg(ry), math.deg(rz))
		end,
		BrickColor = function(_, st)
			return roblox.BrickColor.new(getProp(st, "Color"))
		end,
		ExtentsSize = function(_, st)
			return getProp(st, "Size")
		end,
		ExtentsCFrame = function(_, st)
			return getProp(st, "CFrame")
		end,
		Mass = function(_, st)
			local s = getProp(st, "Size")
			return s.X * s.Y * s.Z * 0.7
		end,
		AssemblyMass = function(_, st)
			local s = getProp(st, "Size")
			return s.X * s.Y * s.Z * 0.7
		end,
		AssemblyRootPart = function(part)
			return part
		end,
		CenterOfMass = function(_, st)
			return getProp(st, "CFrame").Position
		end,
		AssemblyCenterOfMass = function(_, st)
			return getProp(st, "CFrame").Position
		end,
		CurrentPhysicalProperties = function()
			return roblox.PhysicalProperties.new(Enum.Material.Plastic)
		end,
		ReceiveAge = function()
			return 0
		end,
	},
	setters = {
		Position = function(part, st, v)
			if D.typeof(v) ~= "Vector3" then
				error("Unable to assign property Position. Vector3 expected, got " .. D.typeof(v), 0)
			end
			part.CFrame = getProp(st, "CFrame").Rotation + v
		end,
		Orientation = function(part, st, v)
			part.CFrame = CFrame.new(getProp(st, "CFrame").Position) * CFrame.fromOrientation(math.rad(v.X), math.rad(v.Y), math.rad(v.Z))
		end,
		Rotation = function(part, st, v)
			part.CFrame = CFrame.new(getProp(st, "CFrame").Position) * CFrame.Angles(math.rad(v.X), math.rad(v.Y), math.rad(v.Z))
		end,
		BrickColor = function(part, _, v)
			part.Color = v.Color
		end,
	},
	onChange = function(part, st, key)
		if key == "CFrame" then
			if st.x.joints0 then
				propagate(part, st)
			end
		elseif key == "Size" then
			local s = st.props.Size
			if s and (s.X < 0.001 or s.Y < 0.001 or s.Z < 0.001) then
				st.props.Size = Vector3.new(math.max(s.X, 0.001), math.max(s.Y, 0.001), math.max(s.Z, 0.001))
			end
		end
	end,
	methods = {
		GetPivot = function(part)
			return partPivot(part, states[part])
		end,
		PivotTo = function(part, cf)
			local st = states[part]
			part.CFrame = cf * getProp(st, "PivotOffset"):Inverse()
		end,
		GetMass = function(part)
			return part.Mass
		end,
		SetNetworkOwner = function(part)
			if getProp(states[part], "Anchored") then
				error("Network Ownership API cannot be called on Anchored parts or parts welded to Anchored parts.", 2)
			end
		end,
		GetNetworkOwner = function()
			return nil
		end,
		SetNetworkOwnershipAuto = function() end,
		GetNetworkOwnershipAuto = function()
			return true
		end,
		CanSetNetworkOwnership = function(part)
			return not getProp(states[part], "Anchored"), nil
		end,
		GetConnectedParts = function()
			return {}
		end,
		GetJoints = function()
			return {}
		end,
		GetTouchingParts = function()
			return {}
		end,
		GetRootPart = function(part)
			return part
		end,
		IsGrounded = function(part)
			return getProp(states[part], "Anchored")
		end,
		ApplyImpulse = function() end,
		ApplyImpulseAtPosition = function() end,
		ApplyAngularImpulse = function() end,
		BreakJoints = function() end,
		MakeJoints = function() end,
		GetVelocityAtPosition = function()
			return Vector3.zero
		end,
		GetClosestPointOnSurface = function(part)
			return part.Position
		end,
		GetNoCollisionConstraints = function()
			return {}
		end,
	},
})

------------------------------------------------------------------------------------------
-- Model
------------------------------------------------------------------------------------------

local function modelParts(model)
	local out = {}
	R.walk(model, function(d)
		if d ~= model and states[d].info.isA.BasePart then
			table.insert(out, d)
		end
	end)
	return out
end
R.modelParts = modelParts

local function boundingBox(parts, orientation: CFrame?)
	local rot = orientation and orientation.Rotation or CFrame.identity
	local inv = rot:Inverse()
	local minV, maxV
	for _, p in ipairs(parts) do
		local st = states[p]
		local cf = getProp(st, "CFrame")
		local half = getProp(st, "Size") / 2
		for _, sx in ipairs({ -1, 1 }) do
			for _, sy in ipairs({ -1, 1 }) do
				for _, sz in ipairs({ -1, 1 }) do
					local corner = inv * (cf * Vector3.new(half.X * sx, half.Y * sy, half.Z * sz))
					minV = minV and minV:Min(corner) or corner
					maxV = maxV and maxV:Max(corner) or corner
				end
			end
		end
	end
	if not minV then
		return (orientation or CFrame.identity), Vector3.zero
	end
	local centre = rot * ((minV + maxV) / 2)
	return CFrame.new(centre) * rot, maxV - minV
end
R.boundingBox = boundingBox

local function modelPivot(model, st)
	local primary = getProp(st, "PrimaryPart")
	if primary and states[primary] and primary:IsDescendantOf(model) then
		return partPivot(primary, states[primary])
	end
	if st.x.worldPivot then
		return st.x.worldPivot
	end
	local parts = modelParts(model)
	if #parts == 0 then
		return CFrame.identity
	end
	local cf = boundingBox(parts, nil)
	return cf
end

local function moveParts(parts, delta: CFrame)
	R.batchMove = true
	for _, p in ipairs(parts) do
		local st = states[p]
		setCFrameRaw(p, st, delta * getProp(st, "CFrame"))
	end
	R.batchMove = false
end

R.defineClass("Model", {
	getters = {
		WorldPivot = function(model, st)
			return modelPivot(model, st)
		end,
	},
	setters = {
		WorldPivot = function(model, st, v)
			st.x.worldPivot = v
			R.changed(model, st, "WorldPivot")
		end,
	},
	onClone = function(_, _, src, dst)
		dst.x.worldPivot = src.x.worldPivot
	end,
	methods = {
		GetPivot = function(model)
			return modelPivot(model, states[model])
		end,
		PivotTo = function(model, cf)
			local st = states[model]
			local current = modelPivot(model, st)
			local delta = cf * current:Inverse()
			moveParts(modelParts(model), delta)
			if st.x.worldPivot then
				st.x.worldPivot = cf
			end
		end,
		GetBoundingBox = function(model)
			local st = states[model]
			local pivot = modelPivot(model, st)
			return boundingBox(modelParts(model), pivot)
		end,
		GetExtentsSize = function(model)
			local _, size = boundingBox(modelParts(model), modelPivot(model, states[model]))
			return size
		end,
		MoveTo = function(model, pos)
			local pivot = modelPivot(model, states[model])
			model:PivotTo(pivot.Rotation + pos)
		end,
		TranslateBy = function(model, offset)
			moveParts(modelParts(model), CFrame.new(offset))
		end,
		SetPrimaryPartCFrame = function(model, cf)
			local st = states[model]
			local primary = getProp(st, "PrimaryPart")
			if not primary then
				error("Model:SetPrimaryPartCFrame() failed because no PrimaryPart has been set", 2)
			end
			local delta = cf * getProp(states[primary], "CFrame"):Inverse()
			moveParts(modelParts(model), delta)
		end,
		GetPrimaryPartCFrame = function(model)
			local primary = getProp(states[model], "PrimaryPart")
			return primary and primary.CFrame or CFrame.identity
		end,
		GetModelCFrame = function(model)
			return modelPivot(model, states[model])
		end,
		GetScale = function()
			return 1
		end,
		ScaleTo = function(model, s)
			local pivot = modelPivot(model, states[model])
			R.batchMove = true
			for _, p in ipairs(modelParts(model)) do
				local pst = states[p]
				local rel = pivot:ToObjectSpace(getProp(pst, "CFrame"))
				setCFrameRaw(p, pst, pivot * (rel.Rotation + rel.Position * s))
				pst.props.Size = getProp(pst, "Size") * s
			end
			R.batchMove = false
		end,
		BreakJoints = function() end,
		MakeJoints = function() end,
		GetPersistentPlayers = function()
			return {}
		end,
		AddPersistentPlayer = function() end,
		RemovePersistentPlayer = function() end,
	},
})

------------------------------------------------------------------------------------------
-- Camera
------------------------------------------------------------------------------------------

local function viewportSize(): Vector2
	local d = R.options.device
	return Vector2.new(d.width, d.height)
end
R.viewportSize = viewportSize

local function project(cam, pos: Vector3)
	local st = states[cam]
	local cf = getProp(st, "CFrame")
	local fov = math.rad(getProp(st, "FieldOfView"))
	local size = viewportSize()
	local rel = cf:PointToObjectSpace(pos)
	local depth = -rel.Z
	local f = (size.Y / 2) / math.tan(fov / 2)
	local x = size.X / 2 + rel.X / math.max(depth, 1e-4) * f
	local y = size.Y / 2 - rel.Y / math.max(depth, 1e-4) * f
	local onScreen = depth > 0 and x >= 0 and x <= size.X and y >= 0 and y <= size.Y
	return Vector3.new(x, y, depth), onScreen
end
R.project = project

R.defineClass("Camera", {
	events = { "InterpolationFinished" },
	defaults = { FieldOfView = 70 },
	getters = {
		ViewportSize = function()
			return viewportSize()
		end,
		CoordinateFrame = function(_, st)
			return getProp(st, "CFrame")
		end,
		NearPlaneZ = function()
			return -0.1
		end,
		MaxAxisFieldOfView = function(_, st)
			local size = viewportSize()
			local fov = math.rad(getProp(st, "FieldOfView"))
			if size.X > size.Y then
				return math.deg(2 * math.atan(math.tan(fov / 2) * size.X / size.Y))
			end
			return math.deg(fov)
		end,
		DiagonalFieldOfView = function(_, st)
			local size = viewportSize()
			local fov = math.rad(getProp(st, "FieldOfView"))
			return math.deg(2 * math.atan(math.tan(fov / 2) * size.Magnitude / size.Y))
		end,
	},
	setters = {
		CoordinateFrame = function(cam, _, v)
			cam.CFrame = v
		end,
	},
	methods = {
		WorldToViewportPoint = function(cam, pos)
			return project(cam, pos)
		end,
		WorldToScreenPoint = function(cam, pos)
			local v, on = project(cam, pos)
			local inset = R.guiInset and R.guiInset() or Vector2.zero
			return Vector3.new(v.X, v.Y - inset.Y, v.Z), on
		end,
		ViewportPointToRay = function(cam, x, y, depth)
			local st = states[cam]
			local cf = getProp(st, "CFrame")
			local size = viewportSize()
			local fov = math.rad(getProp(st, "FieldOfView"))
			local f = (size.Y / 2) / math.tan(fov / 2)
			local dir = cf:VectorToWorldSpace(Vector3.new((x - size.X / 2) / f, -(y - size.Y / 2) / f, -1).Unit)
			return roblox.Ray.new(cf.Position + dir * (depth or 0), dir)
		end,
		ScreenPointToRay = function(cam, x, y, depth)
			local inset = R.guiInset and R.guiInset() or Vector2.zero
			return cam:ViewportPointToRay(x, y + inset.Y, depth)
		end,
		GetPartsObscuringTarget = function()
			return {}
		end,
		GetRenderCFrame = function(cam)
			return cam.CFrame
		end,
		Interpolate = function(cam, cf, focus)
			cam.CFrame = cf
			cam.Focus = focus
		end,
		ZoomToExtents = function() end,
		GetRoll = function()
			return 0
		end,
		SetRoll = function() end,
	},
})

------------------------------------------------------------------------------------------
-- Workspace / Terrain
------------------------------------------------------------------------------------------

R.defineClass("Workspace", {
	events = { "PersistentLoaded" },
	onCreate = function(ws, st)
		local cam = R.create("Camera")
		states[cam].name = "Camera"
		R.setParent(cam, states[cam], ws)
		st.props.CurrentCamera = cam
		local terrain = R.create("Terrain")
		states[terrain].name = "Terrain"
		R.setParent(terrain, states[terrain], ws)
		st.x.terrain = terrain
	end,
	getters = {
		Terrain = function(_, st)
			return st.x.terrain
		end,
		DistributedGameTime = function()
			return S.now
		end,
	},
	methods = {
		Raycast = function()
			return nil
		end,
		Blockcast = function()
			return nil
		end,
		Spherecast = function()
			return nil
		end,
		Shapecast = function()
			return nil
		end,
		FindPartOnRay = function(_, ray)
			return nil, ray.Origin + ray.Direction, Vector3.new(0, 1, 0), Enum.Material.Air
		end,
		FindPartOnRayWithIgnoreList = function(_, ray)
			return nil, ray.Origin + ray.Direction, Vector3.new(0, 1, 0), Enum.Material.Air
		end,
		FindPartOnRayWithWhitelist = function(_, ray)
			return nil, ray.Origin + ray.Direction, Vector3.new(0, 1, 0), Enum.Material.Air
		end,
		FindPartsInRegion3 = function()
			return {}
		end,
		GetPartBoundsInBox = function()
			return {}
		end,
		GetPartBoundsInRadius = function()
			return {}
		end,
		GetPartsInPart = function()
			return {}
		end,
		ArePartsTouchingOthers = function()
			return false
		end,
		BulkMoveTo = function(_, parts, cframes, _mode)
			if #parts ~= #cframes then
				error("BulkMoveTo: part and CFrame lists differ in length", 2)
			end
			for i = 1, #parts do
				local p = parts[i]
				local st = states[p]
				local old = st.props.CFrame
				local cf = cframes[i]
				st.props.CFrame = cf
				if old ~= cf and (st.propSigs or st.sigs or st.x.joints0) then
					R.changed(p, st, "CFrame")
				end
			end
		end,
		GetServerTimeNow = function()
			return R.epoch()
		end,
		GetRealPhysicsFPS = function()
			return 60
		end,
		GetNumAwakeParts = function()
			return 0
		end,
		GetPhysicsThrottling = function()
			return 100
		end,
		PGSIsEnabled = function()
			return true
		end,
		JoinToOutsiders = function() end,
		UnjoinFromOutsiders = function() end,
		SetInsertPoint = function() end,
		ZoomToExtents = function() end,
		IKMoveTo = function() end,
	},
})

R.defineClass("Terrain", {
	methods = (function()
		local m = {}
		for _, name in ipairs({ "FillBlock", "FillBall", "FillCylinder", "FillWedge", "FillRegion", "Clear", "ReplaceMaterial", "WriteVoxels", "SetMaterialColor", "FillRegion" }) do
			m[name] = function()
				R.note("Terrain is not rendered (Terrain:" .. name .. " was called)")
			end
		end
		m.GetMaterialColor = function()
			return Color3.new(0.5, 0.5, 0.5)
		end
		m.ReadVoxels = function()
			return {}, {}
		end
		return m
	end)(),
})

------------------------------------------------------------------------------------------
-- Attachment
------------------------------------------------------------------------------------------

local function attachmentParentCF(st): CFrame
	local p = st.parent
	if p and states[p].info.isA.BasePart then
		return getProp(states[p], "CFrame")
	elseif p and states[p].info.isA.Attachment then
		return p.WorldCFrame
	end
	return CFrame.identity
end

R.defineClass("Attachment", {
	getters = {
		Position = function(_, st)
			return getProp(st, "CFrame").Position
		end,
		Orientation = function(_, st)
			return orientationOf(getProp(st, "CFrame"))
		end,
		WorldCFrame = function(_, st)
			return attachmentParentCF(st) * getProp(st, "CFrame")
		end,
		WorldPosition = function(_, st)
			return (attachmentParentCF(st) * getProp(st, "CFrame")).Position
		end,
		WorldOrientation = function(_, st)
			return orientationOf(attachmentParentCF(st) * getProp(st, "CFrame"))
		end,
		Axis = function(_, st)
			return getProp(st, "CFrame").RightVector
		end,
		SecondaryAxis = function(_, st)
			return getProp(st, "CFrame").UpVector
		end,
		WorldAxis = function(_, st)
			return (attachmentParentCF(st) * getProp(st, "CFrame")).RightVector
		end,
		WorldSecondaryAxis = function(_, st)
			return (attachmentParentCF(st) * getProp(st, "CFrame")).UpVector
		end,
	},
	setters = {
		Position = function(a, st, v)
			a.CFrame = getProp(st, "CFrame").Rotation + v
		end,
		Orientation = function(a, st, v)
			a.CFrame = CFrame.new(getProp(st, "CFrame").Position) * CFrame.fromOrientation(math.rad(v.X), math.rad(v.Y), math.rad(v.Z))
		end,
		WorldCFrame = function(a, st, v)
			a.CFrame = attachmentParentCF(st):ToObjectSpace(v)
		end,
		WorldPosition = function(a, st, v)
			local local_ = attachmentParentCF(st):PointToObjectSpace(v)
			a.CFrame = getProp(st, "CFrame").Rotation + local_
		end,
	},
	methods = {
		GetConstraints = function()
			return {}
		end,
	},
})

------------------------------------------------------------------------------------------
-- Humanoid
------------------------------------------------------------------------------------------

R.defineClass("Humanoid", {
	events = { "Died", "Running", "StateChanged", "HealthChanged", "MoveToFinished", "Touched", "Jumping", "FreeFalling", "Seated", "Climbing", "GettingUp", "FallingDown", "Ragdoll", "Swimming", "PlatformStanding", "StateEnabledChanged", "AnimationPlayed", "ApplyDescriptionFinished", "ServerBreakJoints", "Strafing" },
	defaults = { Health = 100, MaxHealth = 100, WalkSpeed = 16, JumpPower = 50, JumpHeight = 7.2, HipHeight = 0 },
	getters = {
		RootPart = function(_, st)
			local model = st.parent
			return model and R.findChild(states[model], "HumanoidRootPart") or nil
		end,
		MoveDirection = function(_, st)
			return st.x.moveDir or Vector3.zero
		end,
		FloorMaterial = function()
			return Enum.Material.Plastic
		end,
		SeatPart = function()
			return nil
		end,
	},
	methods = {
		SetStateEnabled = function(h, state, on)
			local st = states[h]
			st.x.disabled = st.x.disabled or {}
			st.x.disabled[state] = not on
		end,
		GetStateEnabled = function(h, state)
			local d = states[h].x.disabled
			return not (d and d[state])
		end,
		ChangeState = function() end,
		GetState = function()
			return Enum.HumanoidStateType.Running
		end,
		Move = function(h, dir)
			states[h].x.moveDir = dir
		end,
		MoveTo = function() end,
		TakeDamage = function(h, amount)
			h.Health = math.max(0, h.Health - amount)
		end,
		EquipTool = function() end,
		UnequipTools = function() end,
		GetPlayingAnimationTracks = function()
			return {}
		end,
		GetAccessories = function()
			return {}
		end,
		AddAccessory = function() end,
		RemoveAccessories = function() end,
		BuildRigFromAttachments = function() end,
		ApplyDescription = function() end,
		ApplyDescriptionReset = function() end,
		GetAppliedDescription = function()
			return R.create("HumanoidDescription")
		end,
		GetLimb = function()
			return Enum.Limb.Unknown
		end,
		LoadAnimation = function()
			error("Humanoid:LoadAnimation is not supported by the preview mock (no animations)", 2)
		end,
	},
})

------------------------------------------------------------------------------------------
-- Lighting
------------------------------------------------------------------------------------------

local function clockToString(clock: number): string
	clock = clock % 24
	local h = math.floor(clock)
	local m = math.floor((clock - h) * 60)
	local s = math.floor(((clock - h) * 60 - m) * 60 + 0.5)
	if s >= 60 then
		s = 59
	end
	return string.format("%02d:%02d:%02d", h, m, s)
end

local function stringToClock(text: string): number
	local h, m, s = string.match(text, "^(%-?%d+):?(%d*):?(%d*)")
	return (tonumber(h) or 0) + (tonumber(m) or 0) / 60 + (tonumber(s) or 0) / 3600
end

-- Sun direction (unit vector toward the sun). Roblox-style: the sun rises in +X (east)
-- at 6:00, is highest at 12:00 and sets in -X; GeographicLatitude tilts its path toward
-- +Z (south) for positive latitudes. Approximation (no earth tilt / season).
function R.sunDirection(clock: number, latitude: number): Vector3
	local h = (clock / 24) * math.pi * 2
	local x, y = math.sin(h), -math.cos(h)
	local lat = math.rad(latitude)
	return Vector3.new(x, y * math.cos(lat), y * math.sin(lat)).Unit
end

R.defineClass("Lighting", {
	events = { "LightingChanged" },
	defaults = { ShadowColor = Color3.new(0.7, 0.7, 0.72) },
	getters = {
		ClockTime = function(_, st)
			return st.x.clock or stringToClock(getProp(st, "TimeOfDay"))
		end,
	},
	setters = {
		ClockTime = function(l, st, v)
			if type(v) ~= "number" then
				error("Unable to assign property ClockTime. number expected", 0)
			end
			st.x.settingClock = true
			R.rawset(l, "TimeOfDay", clockToString(v))
			st.x.settingClock = nil
			st.x.clock = v % 24
			R.changed(l, st, "ClockTime")
		end,
	},
	onChange = function(_, st, key)
		if key == "TimeOfDay" and not st.x.settingClock then
			st.x.clock = stringToClock(getProp(st, "TimeOfDay"))
		end
	end,
	methods = {
		GetSunDirection = function(l)
			return R.sunDirection(l.ClockTime, l.GeographicLatitude)
		end,
		GetMoonDirection = function(l)
			return -R.sunDirection(l.ClockTime, l.GeographicLatitude)
		end,
		GetMinutesAfterMidnight = function(l)
			return l.ClockTime * 60
		end,
		SetMinutesAfterMidnight = function(l, minutes)
			l.ClockTime = minutes / 60
		end,
		GetMoonPhase = function()
			return 0.75
		end,
	},
})

------------------------------------------------------------------------------------------
-- Sounds (silent)
------------------------------------------------------------------------------------------

R.defineClass("Sound", {
	events = { "Played", "Ended", "Stopped", "Paused", "Resumed", "Loaded", "DidLoop" },
	getters = {
		IsPlaying = function(_, st)
			return st.x.playing == true
		end,
		IsPaused = function(_, st)
			return st.x.playing ~= true
		end,
		IsLoaded = function()
			return true
		end,
		TimeLength = function()
			return 1
		end,
		PlaybackLoudness = function()
			return 0
		end,
	},
	methods = {
		Play = function(s)
			states[s].x.playing = true
		end,
		Stop = function(s)
			states[s].x.playing = false
		end,
		Pause = function(s)
			states[s].x.playing = false
		end,
		Resume = function(s)
			states[s].x.playing = true
		end,
		GetConnectedWires = function()
			return {}
		end,
	},
})

R.defineClass("SoundService", {
	methods = {
		PlayLocalSound = function() end,
		SetListener = function() end,
		GetListener = function()
			return Enum.ListenerType.Camera, nil
		end,
	},
})

------------------------------------------------------------------------------------------
-- Effects with methods
------------------------------------------------------------------------------------------

R.defineClass("ParticleEmitter", {
	methods = {
		Emit = function() end,
		Clear = function() end,
	},
})
R.defineClass("Trail", { methods = { Clear = function() end } })
R.defineClass("Beam", { methods = { SetTextureOffset = function() end } })
R.defineClass("ProximityPrompt", {
	events = { "Triggered", "TriggerEnded", "PromptButtonHoldBegan", "PromptButtonHoldEnded", "PromptShown", "PromptHidden" },
	methods = { InputHoldBegin = function() end, InputHoldEnd = function() end },
})
R.defineClass("ClickDetector", { events = { "MouseClick", "RightMouseClick", "MouseHoverEnter", "MouseHoverLeave" } })

------------------------------------------------------------------------------------------
-- InsertService: LoadAsset(id) is answered by R.loadAsset (meshes.luau)
------------------------------------------------------------------------------------------

R.defineClass("InsertService", {
	methods = {
		LoadAsset = function(_, id)
			if not R.loadAsset then
				error("InsertService:LoadAsset is not available in the preview", 2)
			end
			return R.loadAsset(id)
		end,
		LoadAssetVersion = function()
			error("InsertService:LoadAssetVersion is not supported by the preview mock", 2)
		end,
		CreateMeshPartAsync = function()
			error("InsertService:CreateMeshPartAsync is not supported by the preview mock", 2)
		end,
	},
})

R.defineClass("AssetService", {
	methods = {
		CreateEditableImage = function()
			error("AssetService:CreateEditableImage is not supported by the preview mock", 2)
		end,
		CreateEditableMesh = function()
			error("AssetService:CreateEditableMesh is not supported by the preview mock", 2)
		end,
		GetGamePlacesAsync = function()
			error("AssetService:GetGamePlacesAsync is not supported by the preview mock", 2)
		end,
	},
})

return true
