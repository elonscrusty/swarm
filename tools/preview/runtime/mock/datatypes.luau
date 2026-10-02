--!nocheck
--[[
	datatypes.luau - Roblox datatypes for game code.

	Math types come from Lune's @lune/roblox (real CFrame / Vector3 / Color3 / UDim2 ...).
	Added here because Lune lacks them: TweenInfo, Random (deterministic, seeded by the
	scene), RaycastParams, OverlapParams, Path2DControlPoint, DateTime (minimal),
	CFrame.lookAlong, and a ColorSequence.new(c0, c1) fix (Lune 0.10.4 repeats c0).
]]

local roblox = require("@lune/roblox")
local R = require("./R")

local D = {}

for _, name in ipairs({
	"Vector3", "Vector2", "Vector3int16", "Vector2int16", "Color3", "UDim", "UDim2", "Rect", "Font",
	"NumberSequenceKeypoint", "ColorSequenceKeypoint", "NumberRange", "BrickColor",
	"PhysicalProperties", "Faces", "Axes", "Region3", "Region3int16", "Ray", "Content",
}) do
	D[name] = roblox[name]
end
D.Enum = roblox.Enum

-- Lune 0.10.4's CFrame.lookAt faces the wrong way (LookVector points away from the
-- target) and CFrame.new(pos, lookAt) is missing: both are rebuilt with fromMatrix.
local LCFrame = roblox.CFrame
local LVector3 = roblox.Vector3
local function lookAlong(at, direction, up)
	local look = direction.Magnitude > 1e-9 and direction.Unit or LVector3.new(0, 0, -1)
	up = up or LVector3.new(0, 1, 0)
	local right = look:Cross(up)
	if right.Magnitude < 1e-6 then
		right = look:Cross(LVector3.new(0, 0, look.Y > 0 and 1 or -1))
		if right.Magnitude < 1e-6 then
			right = LVector3.new(1, 0, 0)
		end
	end
	right = right.Unit
	return LCFrame.fromMatrix(at, right, right:Cross(look).Unit)
end
local function lookAt(at, target, up)
	return lookAlong(at, target - at, up)
end
D.CFrame = setmetatable({
	lookAt = lookAt,
	lookAlong = lookAlong,
	new = function(...)
		local n = select("#", ...)
		if n == 2 then
			local a, b = ...
			if typeof(a) == "Vector3" and typeof(b) == "Vector3" then
				return lookAt(a, b)
			end
		end
		return LCFrame.new(...)
	end,
}, { __index = LCFrame })

local LColorSequence = roblox.ColorSequence
local CSK = roblox.ColorSequenceKeypoint
D.ColorSequence = setmetatable({
	new = function(a, b)
		if typeof(a) == "Color3" then
			return LColorSequence.new({ CSK.new(0, a), CSK.new(1, b or a) })
		end
		return LColorSequence.new(a)
	end,
}, { __index = LColorSequence })

local LNumberSequence = roblox.NumberSequence
local NSK = roblox.NumberSequenceKeypoint
D.NumberSequence = setmetatable({
	new = function(a, b)
		if type(a) == "number" then
			return LNumberSequence.new({ NSK.new(0, a), NSK.new(1, b or a) })
		end
		return LNumberSequence.new(a)
	end,
}, { __index = LNumberSequence })

------------------------------------------------------------------------------------------
-- Small helper for read-only value types implemented in Luau
------------------------------------------------------------------------------------------

local function valueType(typeName: string, fields: { string }?)
	local mt = {}
	mt.__type = typeName
	mt.__tostring = function(self)
		local parts = {}
		for _, f in ipairs(fields or {}) do
			table.insert(parts, f .. "=" .. tostring(rawget(self, "_" .. f)))
		end
		return typeName .. "(" .. table.concat(parts, ", ") .. ")"
	end
	return mt
end

------------------------------------------------------------------------------------------
-- TweenInfo
------------------------------------------------------------------------------------------

local TweenInfoMT = valueType("TweenInfo", { "Time", "EasingStyle", "EasingDirection", "RepeatCount", "Reverses", "DelayTime" })
TweenInfoMT.__index = function(self, k)
	local v = rawget(self, "_" .. k)
	if v == nil and not rawget(self, "_has_" .. k) then
		error(k .. " is not a valid member of TweenInfo", 2)
	end
	return v
end
TweenInfoMT.__newindex = function(_, k)
	error("Unable to assign property " .. tostring(k) .. ". Property is read only", 2)
end

D.TweenInfo = {
	new = function(time, style, direction, repeatCount, reverses, delayTime)
		local t = {
			_Time = time or 1,
			_EasingStyle = style or roblox.Enum.EasingStyle.Quad,
			_EasingDirection = direction or roblox.Enum.EasingDirection.Out,
			_RepeatCount = repeatCount or 0,
			_Reverses = reverses == true,
			_DelayTime = delayTime or 0,
		}
		for _, k in ipairs({ "Time", "EasingStyle", "EasingDirection", "RepeatCount", "Reverses", "DelayTime" }) do
			t["_has_" .. k] = true
		end
		return setmetatable(t, TweenInfoMT)
	end,
}

------------------------------------------------------------------------------------------
-- Random: xorshift128, deterministic. Random.new() without a seed takes the next seed of
-- the scene's seed sequence (R.nextSeed), so a scene with --seed N is reproducible.
------------------------------------------------------------------------------------------

local band, bxor, lshift, rshift = bit32.band, bit32.bxor, bit32.lshift, bit32.rshift

local function mix32(x: number): number
	-- murmur3 finaliser on 32-bit values (multiplications split to stay exact)
	local function mul(a, b)
		local ah, al = rshift(a, 16), band(a, 0xFFFF)
		return band(al * b + lshift(band(ah * b, 0xFFFF), 16), 0xFFFFFFFF)
	end
	x = band(x, 0xFFFFFFFF)
	x = bxor(x, rshift(x, 16))
	x = mul(x, 0x85EBCA6B)
	x = bxor(x, rshift(x, 13))
	x = mul(x, 0xC2B2AE35)
	x = bxor(x, rshift(x, 16))
	return x
end

local RandomMT = {}
RandomMT.__type = "Random"
RandomMT.__index = RandomMT
RandomMT.__tostring = function()
	return "Random"
end

local function seedState(seed: number)
	local lo = band(math.floor(math.abs(seed)) % 4294967296, 0xFFFFFFFF)
	local hi = band(math.floor(math.abs(seed) / 4294967296), 0xFFFFFFFF)
	local frac = math.floor((math.abs(seed) % 1) * 4294967296)
	local s = {
		mix32(lo + 0x9E3779B9),
		mix32(bxor(hi, 0x7F4A7C15) + 1),
		mix32(bxor(frac, 0x2545F491) + 2),
		mix32(lo + hi + frac + 0x6C078965),
	}
	if s[1] == 0 and s[2] == 0 and s[3] == 0 and s[4] == 0 then
		s[1] = 1
	end
	return s
end

local function nextU32(self): number
	local s = self._s
	local t = s[4]
	local x = s[1]
	t = bxor(t, lshift(t, 11))
	t = bxor(t, rshift(t, 8))
	s[4], s[3], s[2] = s[3], s[2], x
	x = bxor(x, rshift(x, 19))
	s[1] = bxor(t, x)
	return s[1]
end

local function nextUnit(self): number
	-- 53-bit mantissa from two draws
	local a = rshift(nextU32(self), 5)
	local b = rshift(nextU32(self), 6)
	return (a * 67108864 + b) / 9007199254740992
end

function RandomMT:NextNumber(min, max)
	local u = nextUnit(self)
	if min == nil then
		return u
	end
	max = max or 1
	return min + (max - min) * u
end

function RandomMT:NextInteger(min, max)
	assert(type(min) == "number" and type(max) == "number", "Random:NextInteger expects two numbers")
	min, max = math.floor(min), math.floor(max)
	if max < min then
		error("invalid argument #2 to 'NextInteger' (interval is empty)", 2)
	end
	return min + math.floor(nextUnit(self) * (max - min + 1))
end

function RandomMT:NextUnitVector()
	local z = nextUnit(self) * 2 - 1
	local a = nextUnit(self) * math.pi * 2
	local r = math.sqrt(1 - z * z)
	return roblox.Vector3.new(r * math.cos(a), r * math.sin(a), z)
end

function RandomMT:Shuffle(t)
	for i = #t, 2, -1 do
		local j = self:NextInteger(1, i)
		t[i], t[j] = t[j], t[i]
	end
end

function RandomMT:Clone()
	return setmetatable({ _s = table.clone(self._s) }, RandomMT)
end

local seedCounter = 0
function R.nextSeed(): number
	seedCounter += 1
	return (R.options.seed or 1) * 1000003 + seedCounter * 7919
end

D.Random = {
	new = function(seed)
		if seed == nil then
			seed = R.nextSeed()
		end
		return setmetatable({ _s = seedState(seed) }, RandomMT)
	end,
}

------------------------------------------------------------------------------------------
-- RaycastParams / OverlapParams (data holders; the mock's raycasts hit nothing)
------------------------------------------------------------------------------------------

local function paramsType(typeName: string, defaults: { [string]: any })
	local mt = {}
	mt.__type = typeName
	mt.__tostring = function()
		return typeName
	end
	mt.__index = function(self, k)
		if k == "AddToFilter" then
			return function(this, v)
				local list = rawget(this, "_v").FilterDescendantsInstances
				if typeof(v) == "Instance" then
					table.insert(list, v)
				else
					for _, x in ipairs(v) do
						table.insert(list, x)
					end
				end
			end
		end
		local store = rawget(self, "_v")
		if store[k] == nil and defaults[k] == nil then
			error(k .. " is not a valid member of " .. typeName, 2)
		end
		return store[k]
	end
	mt.__newindex = function(self, k, v)
		if defaults[k] == nil then
			error(k .. " is not a valid member of " .. typeName, 2)
		end
		rawget(self, "_v")[k] = v
	end
	return {
		new = function()
			local store = {}
			for k, v in pairs(defaults) do
				store[k] = type(v) == "table" and {} or v
			end
			return setmetatable({ _v = store }, mt)
		end,
	}
end

D.RaycastParams = paramsType("RaycastParams", {
	FilterDescendantsInstances = {},
	FilterType = roblox.Enum.RaycastFilterType.Exclude,
	IgnoreWater = false,
	CollisionGroup = "Default",
	RespectCanCollide = false,
	BruteForceAllSlow = false,
})
D.OverlapParams = paramsType("OverlapParams", {
	FilterDescendantsInstances = {},
	FilterType = roblox.Enum.RaycastFilterType.Exclude,
	MaxParts = 0,
	CollisionGroup = "Default",
	RespectCanCollide = false,
	BruteForceAllSlow = false,
})

------------------------------------------------------------------------------------------
-- Path2DControlPoint
------------------------------------------------------------------------------------------

local CPMT = valueType("Path2DControlPoint", { "Position", "LeftTangent", "RightTangent" })
CPMT.__index = function(self, k)
	if k == "Position" or k == "LeftTangent" or k == "RightTangent" then
		return rawget(self, "_" .. k)
	end
	error(tostring(k) .. " is not a valid member of Path2DControlPoint", 2)
end
D.Path2DControlPoint = {
	new = function(position, left, right)
		local zero = roblox.UDim2.new()
		return setmetatable({ _Position = position or zero, _LeftTangent = left or zero, _RightTangent = right or zero }, CPMT)
	end,
}

------------------------------------------------------------------------------------------
-- DateTime (minimal; based on the simulated clock's start time)
------------------------------------------------------------------------------------------

local DateTimeMT = {}
DateTimeMT.__type = "DateTime"
DateTimeMT.__index = function(self, k)
	if k == "UnixTimestamp" then
		return math.floor(rawget(self, "_ms") / 1000)
	elseif k == "UnixTimestampMillis" then
		return rawget(self, "_ms")
	elseif k == "ToIsoDate" then
		return function(this)
			return os.date("!%Y-%m-%dT%H:%M:%SZ", math.floor(rawget(this, "_ms") / 1000))
		end
	elseif k == "FormatUniversalTime" or k == "FormatLocalTime" then
		return function(this)
			return os.date("!%Y-%m-%d %H:%M", math.floor(rawget(this, "_ms") / 1000))
		end
	elseif k == "ToUniversalTime" or k == "ToLocalTime" then
		return function(this)
			local t = os.date("!*t", math.floor(rawget(this, "_ms") / 1000))
			return { Year = t.year, Month = t.month, Day = t.day, Hour = t.hour, Minute = t.min, Second = t.sec, Millisecond = rawget(this, "_ms") % 1000 }
		end
	end
	error(tostring(k) .. " is not a valid member of DateTime", 2)
end
D.DateTime = {
	now = function()
		return setmetatable({ _ms = math.floor(R.epoch() * 1000) }, DateTimeMT)
	end,
	fromUnixTimestamp = function(s)
		return setmetatable({ _ms = math.floor(s * 1000) }, DateTimeMT)
	end,
	fromUnixTimestampMillis = function(ms)
		return setmetatable({ _ms = math.floor(ms) }, DateTimeMT)
	end,
}

------------------------------------------------------------------------------------------
-- typeof for game code: "Instance" for mock instances, our Luau-made types by __type.
------------------------------------------------------------------------------------------

local nativeTypeof = typeof
function D.typeof(v): string
	local t = type(v)
	if t == "userdata" then
		if R.isInstance and R.isInstance(v) then
			return "Instance"
		end
		return nativeTypeof(v)
	elseif t == "table" then
		local mt = getmetatable(v)
		if type(mt) == "table" then
			local tn = rawget(mt, "__type")
			if tn then
				return tn
			end
		end
		return "table"
	end
	return nativeTypeof(v)
end

R.D = D
return D
