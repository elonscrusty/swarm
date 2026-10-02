--[[
	HeroPoses.lua
	Hand-set poses for the heroes (lobby showcase, previews), as rotations per Motor6D of the
	shared hero rig (ModelBuilder.Rig): "RootJoint", "Neck", "Left Shoulder", "Right Shoulder",
	"Left Hip", "Right Hip". Data only plus one helper.

	Angles are degrees for CFrame.Angles(x, y, z) applied as Motor6D.Transform, in the rig's
	axes (front = -Z, the hero's left = -X):
	  shoulder / hip  +X swings the limb forward (arm up in front at ~90, overhead at ~170)
	  Right Shoulder  +Z lifts the arm out to the side (Left Shoulder: -Z)
	  Right Hip       +Z spreads the leg (Left Hip: -Z)
	  Neck            +X lifts the chin, +Y turns the head to its left
	  RootJoint       rotates the whole body around the root centre (y = 3); Pos moves it
	Poses:
	  Showcase  the heroic stance for the lobby dais (Knight: sword raised, shield forward;
	            Ranger: longbow held out upright, drawing hand by the quiver; Alchemist: a
	            flask held up; Engineer: wrench raised; Necromancer: staff forward, a hand
	            calling souls)
	  Idle      a subtle breathing loop (also layered on top of Showcase)

	HeroPoses.Apply(model, poseName, t) poses a character built by ModelBuilder (it reads the
	model's CharacterId attribute). t = seconds (drives the breathing). Live characters and
	rigs inside a WorldModel get Motor6D.Transform (call it every frame after any other
	animation, e.g. in PreSimulation; VFX's walk cycle also writes these joints). Fully
	anchored copies (ViewportFrame previews) are re-placed directly from their rest pose.
	HeroPoses.Apply(model, nil) returns the model to its rest pose.
]]

local HeroPoses = {}

type Joint = { number }
export type Pose = { [string]: Joint }

local IDLE = {
	Period = 3.4, -- seconds per breath
	Joints = {
		Neck = { 2.5, 0, 0 },
		["Left Shoulder"] = { 0, 0, -2.5 },
		["Right Shoulder"] = { 0, 0, 2.5 },
	},
	Rise = 0.035, -- studs the body lifts on the in-breath
}

HeroPoses.Poses = {
	Knight = {
		Showcase = {
			RootJoint = { 0, -12, 0 },
			Neck = { 6, 8, 0 },
			["Right Shoulder"] = { 122, 0, 16 }, -- sword up
			["Left Shoulder"] = { 52, 0, 22 }, -- shield across the front
			["Left Hip"] = { 16, 0, -7 },
			["Right Hip"] = { -12, 0, 7 },
		},
	},
	Mage = {
		Showcase = {
			RootJoint = { 0, 10, 0 },
			Neck = { 8, -6, 0 },
			["Right Shoulder"] = { 34, 0, 18 }, -- staff lifted
			["Left Shoulder"] = { 78, 0, -18 }, -- casting hand forward
			["Left Hip"] = { 8, 0, -4 },
			["Right Hip"] = { -6, 0, 4 },
		},
	},
	Rogue = {
		Showcase = {
			RootJoint = { -9, 18, 0 },
			Neck = { 12, -14, 0 },
			["Right Shoulder"] = { 62, 0, 28 }, -- daggers out
			["Left Shoulder"] = { 38, 0, -34 },
			["Left Hip"] = { 30, 0, -9 },
			["Right Hip"] = { -14, 0, 9 },
		},
	},
	Priest = {
		Showcase = {
			RootJoint = { 0, -8, 0 },
			Neck = { 10, 0, 0 },
			["Right Shoulder"] = { 26, 0, 16 }, -- sun staff raised
			["Left Shoulder"] = { 72, 0, 8 }, -- book held up
			["Left Hip"] = { 6, 0, -3 },
			["Right Hip"] = { -4, 0, 3 },
		},
	},
	Ranger = {
		Showcase = {
			RootJoint = { 0, 16, 0 },
			Neck = { 6, -12, 0 },
			["Left Shoulder"] = { 40, 0, -22 }, -- longbow held out in front
			["Right Shoulder"] = { -22, 0, 18 }, -- hand back by the quiver
			["Left Hip"] = { 16, 0, -6 },
			["Right Hip"] = { -10, 0, 6 },
		},
	},
	Alchemist = {
		Showcase = {
			RootJoint = { 0, -14, 0 },
			Neck = { 4, 10, 0 },
			["Right Shoulder"] = { 108, 0, 10 }, -- flask held up to the light
			["Left Shoulder"] = { 24, 0, -20 }, -- other hand at the bandolier
			["Left Hip"] = { 12, 0, -6 },
			["Right Hip"] = { -8, 0, 5 },
		},
	},
	Engineer = {
		Showcase = {
			RootJoint = { 0, 12, 0 },
			Neck = { 4, -8, 0 },
			["Right Shoulder"] = { 58, 0, 14 }, -- wrench raised, ready to build
			["Left Shoulder"] = { 18, 0, -26 }, -- fist on the hip
			["Left Hip"] = { 14, 0, -8 },
			["Right Hip"] = { -10, 0, 8 },
		},
	},
	Necromancer = {
		Showcase = {
			RootJoint = { 0, -10, 0 },
			Neck = { -4, 6, 0 },
			["Right Shoulder"] = { 30, 0, 14 }, -- bone staff planted forward
			["Left Shoulder"] = { 48, 0, -42 }, -- a hand stretched out to the side, calling souls
			["Left Hip"] = { 8, 0, -4 },
			["Right Hip"] = { -6, 0, 4 },
		},
	},
}

-- body drops a little in wide stances so the feet stay on the ground
HeroPoses.Drop = { Knight = 0.06, Mage = 0.02, Rogue = 0.16, Priest = 0.01, Ranger = 0.07, Alchemist = 0.04, Engineer = 0.07, Necromancer = 0.02 }

local function angles(j: Joint?): CFrame
	if not j then
		return CFrame.identity
	end
	return CFrame.Angles(math.rad(j[1]), math.rad(j[2]), math.rad(j[3]))
end

--[[
	Joint transforms of a pose at time t: { [motorName]: CFrame }. poseName "Showcase" or
	"Idle" (unknown characters use the Knight's showcase).
]]
function HeroPoses.Get(characterId: string, poseName: string, t: number?): { [string]: CFrame }
	local set = HeroPoses.Poses[characterId] or HeroPoses.Poses.Knight
	local pose: Pose = (poseName ~= "Idle" and (set :: any)[poseName]) or {}
	local breath = math.sin((t or 0) * math.pi * 2 / IDLE.Period)
	local out: { [string]: CFrame } = {}
	for _, name in ipairs({ "RootJoint", "Neck", "Left Shoulder", "Right Shoulder", "Left Hip", "Right Hip" }) do
		local idle = IDLE.Joints[name]
		local cf = angles(pose[name])
		if idle then
			cf *= CFrame.Angles(math.rad(idle[1] * breath), math.rad(idle[2] * breath), math.rad(idle[3] * breath))
		end
		out[name] = cf
	end
	local drop = poseName == "Showcase" and (HeroPoses.Drop[characterId] or 0) or 0
	out.RootJoint = CFrame.new(0, IDLE.Rise * (breath + 1) * 0.5 - drop, 0) * out.RootJoint
	return out
end

-- Rest snapshots of anchored copies (weak keys: dropped with the model).
local rest: { [Model]: any } = setmetatable({}, { __mode = "k" }) :: any

local function snapshot(model: Model, root: BasePart)
	local s = { Rel = {}, Motors = {}, Welds = {} }
	for _, d in ipairs(model:GetDescendants()) do
		if d:IsA("BasePart") then
			s.Rel[d] = root.CFrame:ToObjectSpace(d.CFrame)
		elseif d:IsA("Motor6D") and d.Part0 and d.Part1 then
			table.insert(s.Motors, d)
		elseif d:IsA("WeldConstraint") and d.Part0 and d.Part1 then
			table.insert(s.Welds, d)
		end
	end
	rest[model] = s
	return s
end

-- Anchored rig: place every part from its rest pose and the joint transforms.
local function placeAnchored(model: Model, root: BasePart, transforms: { [string]: CFrame }?)
	local s = rest[model] or snapshot(model, root)
	local posed: { [BasePart]: CFrame } = { [root] = CFrame.identity }
	local left = table.clone(s.Motors)
	for _ = 1, #left + 1 do -- parents before children (RootJoint, then the torso's joints)
		for i = #left, 1, -1 do
			local m: Motor6D = left[i]
			local p0 = posed[m.Part0 :: BasePart]
			if p0 then
				local tr = transforms and transforms[m.Name] or CFrame.identity
				posed[m.Part1 :: BasePart] = p0 * m.C0 * tr * m.C1:Inverse()
				table.remove(left, i)
			end
		end
	end
	for _, w in ipairs(s.Welds) do
		local bone, g = w.Part0 :: BasePart, w.Part1 :: BasePart
		if posed[bone] and s.Rel[bone] and s.Rel[g] and not posed[g] then
			posed[g] = posed[bone] * s.Rel[bone]:Inverse() * s.Rel[g]
		end
	end
	for p, rel in pairs(posed) do
		if p ~= root then
			p.CFrame = root.CFrame * rel
		end
	end
end

--[[
	Poses a hero model. poseName = "Showcase" | "Idle" | nil (rest). t = seconds.
]]
function HeroPoses.Apply(model: Model, poseName: string?, t: number?)
	local root = model:FindFirstChild("HumanoidRootPart") :: BasePart?
	if not root then
		return
	end
	local id = model:GetAttribute("CharacterId")
	local transforms = poseName and HeroPoses.Get(typeof(id) == "string" and id or "Knight", poseName, t) or nil
	if root.Anchored then
		placeAnchored(model, root, transforms)
		return
	end
	for _, d in ipairs(model:GetDescendants()) do
		if d:IsA("Motor6D") then
			d.Transform = transforms and transforms[d.Name] or CFrame.identity
		end
	end
end

return HeroPoses
