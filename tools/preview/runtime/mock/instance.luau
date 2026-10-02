--!nocheck
--[[
	instance.luau - the mock Instance.

	Instances are real userdata (newproxy) whose state lives in R.states[proxy]:
	  info      class info (reflection DB chain + behaviour from classes/*.luau)
	  props     explicitly set property values (reads fall back to class defaults)
	  name, parent, children (ordered), attrs, tags, sigs / propSigs / attrSigs (lazy)
	  x         class-private data (layout results, script source, joint offsets, ...)

	Property reads: method > getter > stored/default property > event > child by name,
	otherwise "X is not a valid member of Class". Writes are type-checked against the
	reflection database ("Unable to assign property ..."), fire Changed /
	GetPropertyChangedSignal only on a real change, and run the class change hooks.
]]

local roblox = require("@lune/roblox")
local R = require("./R")
local D = require("./datatypes")
local Signal = require("./signal")
local S = require("./scheduler")

local Enum = roblox.Enum
local db = roblox.getReflectionDatabase()
R.db = db

local states = setmetatable({}, { __mode = "k" })
R.states = states

function R.isInstance(v): boolean
	return type(v) == "userdata" and states[v] ~= nil
end

function R.state(v)
	return states[v]
end

------------------------------------------------------------------------------------------
-- Class info
------------------------------------------------------------------------------------------

local classDefs = {}
R.classDefs = classDefs
local infoCache = {}

-- Registers behaviour for a class (and, through the chain, its subclasses).
--   methods, getters, setters: name -> function
--   events: { "Name", ... }   defaults: name -> value   props: name -> { type = ..., readOnly = ... }
--   onCreate(proxy, st), onChange(proxy, st, key), onParent(proxy, st, old, new), onClone(src, dst)
function R.defineClass(name: string, def)
	local existing = classDefs[name]
	if existing then
		for k, v in pairs(def) do
			if type(v) == "table" and type(existing[k]) == "table" and k ~= "events" then
				for kk, vv in pairs(v) do
					existing[k][kk] = vv
				end
			elseif k == "events" and existing.events then
				for _, e in ipairs(v) do
					table.insert(existing.events, e)
				end
			else
				existing[k] = v
			end
		end
	else
		classDefs[name] = def
	end
	table.clear(infoCache)
end

local zeroByType = {
	Bool = false,
	Float32 = 0,
	Float64 = 0,
	Int32 = 0,
	Int64 = 0,
	String = "",
	Content = "",
	ContentId = "",
	Vector3 = roblox.Vector3.zero,
	Vector2 = roblox.Vector2.zero,
	CFrame = roblox.CFrame.identity,
	Color3 = roblox.Color3.new(0, 0, 0),
	UDim2 = roblox.UDim2.new(),
	UDim = roblox.UDim.new(),
	Rect = roblox.Rect.new(0, 0, 0, 0),
	NumberRange = roblox.NumberRange.new(0),
	NumberSequence = roblox.NumberSequence.new(0),
	ColorSequence = roblox.ColorSequence.new(roblox.Color3.new(1, 1, 1)),
	Font = roblox.Font.fromEnum(Enum.Font.SourceSans),
	Vector3int16 = roblox.Vector3int16.new(0, 0, 0),
	Vector2int16 = roblox.Vector2int16.new(0, 0),
}

-- Lune typeof names for DB datatype names that differ.
local typeAlias = { Color3uint8 = "Color3", Bool = "boolean", String = "string", Float32 = "number", Float64 = "number", Int32 = "number", Int64 = "number" }

local enumCache = {}
local function enumOf(name: string)
	local e = enumCache[name]
	if e == nil then
		local ok, v = pcall(function()
			return Enum[name]
		end)
		e = ok and v or false
		enumCache[name] = e
	end
	return e or nil
end
R.enumOf = enumOf

local function firstEnumItem(enumObj)
	local best
	for _, item in ipairs(enumObj:GetEnumItems()) do
		if not best or item.Value < best.Value then
			best = item
		end
	end
	return best
end

local function buildInfo(name: string)
	local ok, dbc = pcall(function()
		return db:GetClass(name)
	end)
	if not ok or not dbc then
		return nil
	end
	local chain = {}
	local c = dbc
	while c do
		table.insert(chain, 1, c)
		c = c.Superclass and db:GetClass(c.Superclass) or nil
	end
	local info = {
		name = name,
		chain = {},
		isA = {},
		props = {},
		defaults = {},
		methods = {},
		getters = {},
		setters = {},
		events = {},
		onCreate = {},
		onChange = {},
		onParent = {},
		onClone = {},
		tags = {},
	}
	for _, t in ipairs(dbc.Tags or {}) do
		info.tags[t] = true
	end
	info.service = info.tags.Service == true
	info.creatable = not info.tags.NotCreatable and not info.service
	for _, cl in ipairs(chain) do
		table.insert(info.chain, cl.Name)
		info.isA[cl.Name] = true
		for pname, p in pairs(cl.Properties) do
			local first = string.sub(pname, 1, 1)
			if p.Scriptability ~= "None" and first == string.upper(first) and not string.find(pname, " ") then
				local dt = p.Datatype
				local enumName = string.sub(dt, 1, 5) == "Enum." and string.sub(dt, 6) or nil
				info.props[pname] = { type = dt, readOnly = p.Scriptability == "Read", enum = enumName and enumOf(enumName) or nil }
			end
		end
		for k, v in pairs(cl.DefaultProperties) do
			info.defaults[k] = v
		end
		local def = classDefs[cl.Name]
		if def then
			for k, v in pairs(def.props or {}) do
				info.props[k] = v
			end
			for k, v in pairs(def.defaults or {}) do
				info.defaults[k] = v
			end
			for k, v in pairs(def.methods or {}) do
				info.methods[k] = v
			end
			for k, v in pairs(def.getters or {}) do
				info.getters[k] = v
			end
			for k, v in pairs(def.setters or {}) do
				info.setters[k] = v
			end
			for _, e in ipairs(def.events or {}) do
				info.events[e] = true
			end
			if def.onCreate then
				table.insert(info.onCreate, def.onCreate)
			end
			if def.onChange then
				table.insert(info.onChange, def.onChange)
			end
			if def.onParent then
				table.insert(info.onParent, def.onParent)
			end
			if def.onClone then
				table.insert(info.onClone, def.onClone)
			end
		end
	end
	-- fill defaults the database leaves out
	for pname, p in pairs(info.props) do
		if info.defaults[pname] == nil and not info.getters[pname] then
			if p.enum then
				info.defaults[pname] = firstEnumItem(p.enum)
			else
				local z = zeroByType[p.type]
				if z ~= nil then
					info.defaults[pname] = z
				end
			end
		end
	end
	info.isValueBase = info.isA.ValueBase == true
	info.isGui = info.isA.GuiBase2d == true or info.isA.UIComponent == true or info.isA.UIBase == true or name == "Path2D"
	return info
end

function R.classInfo(name: string)
	local info = infoCache[name]
	if info == nil then
		info = buildInfo(name) or false
		infoCache[name] = info
	end
	return info or nil
end

------------------------------------------------------------------------------------------
-- Errors that point at the caller
------------------------------------------------------------------------------------------

local function fullName(proxy): string
	local st = states[proxy]
	if not st then
		return "?"
	end
	local parts = {}
	local p = proxy
	while p do
		local s = states[p]
		if s.info.name == "DataModel" then
			break
		end
		table.insert(parts, 1, s.name)
		p = s.parent
	end
	return table.concat(parts, ".")
end
R.fullName = fullName

local function typeName(v): string
	return D.typeof(v)
end

------------------------------------------------------------------------------------------
-- Signals on instances
------------------------------------------------------------------------------------------

local function getSignal(st, name: string)
	local sigs = st.sigs
	if not sigs then
		sigs = {}
		st.sigs = sigs
	end
	local s = sigs[name]
	if not s then
		if name == "AncestryChanged" then
			s = Signal.new(name, function()
				R.ancestryListeners += 1
			end)
		else
			s = Signal.new(name)
		end
		sigs[name] = s
	end
	return s
end
R.getSignal = getSignal

-- Fires event `name` on an instance if anything listens.
local function fire(st, name: string, ...)
	local sigs = st.sigs
	if sigs then
		local s = sigs[name]
		if s and #s._conns > 0 then
			s:_fire(...)
		end
	end
end
R.fire = fire

local function hasListeners(st, name: string): boolean
	local sigs = st.sigs
	local s = sigs and sigs[name]
	return s ~= nil and #s._conns > 0
end

------------------------------------------------------------------------------------------
-- Change notification
------------------------------------------------------------------------------------------

R.guiDirty = true

local function changed(proxy, st, key: string)
	local info = st.info
	if info.isGui then
		R.guiDirty = true
	end
	local hooks = info.onChange
	for i = 1, #hooks do
		hooks[i](proxy, st, key)
	end
	local ps = st.propSigs
	if ps then
		local s = ps[key]
		if s and #s._conns > 0 then
			s:_fire()
		end
	end
	local sigs = st.sigs
	if sigs then
		local ch = sigs.Changed
		if ch and #ch._conns > 0 then
			if info.isValueBase then
				if key == "Value" then
					ch:_fire(st.props.Value)
				end
			else
				ch:_fire(key)
			end
		end
	end
end
R.changed = changed

-- Internal property write (no type check, no read-only check), fires change signals.
function R.rawset(proxy, key: string, value)
	local st = states[proxy]
	local old = st.props[key]
	if old == nil then
		old = st.info.defaults[key]
	end
	st.props[key] = value
	if old ~= value then
		changed(proxy, st, key)
	end
end

function R.rawget(proxy, key: string)
	local st = states[proxy]
	local v = st.props[key]
	if v == nil then
		v = st.info.defaults[key]
	end
	return v
end

------------------------------------------------------------------------------------------
-- Type coercion for property writes
------------------------------------------------------------------------------------------

local function enumFromValue(enumObj, value)
	local t = D.typeof(value)
	if t == "EnumItem" then
		if value.EnumType == enumObj then
			return value
		end
		return nil
	elseif t == "string" then
		local ok, item = pcall(function()
			return enumObj[value]
		end)
		return ok and item or nil
	elseif t == "number" then
		for _, item in ipairs(enumObj:GetEnumItems()) do
			if item.Value == value then
				return item
			end
		end
	end
	return nil
end
R.enumFromValue = enumFromValue

local function coerce(info, key: string, p, value)
	local dt = p.type
	if p.enum then
		local item = enumFromValue(p.enum, value)
		if item == nil then
			error(string.format("Unable to assign property %s. %s expected, got %s", key, dt, typeName(value)), 0)
		end
		return item
	end
	if dt == "Ref" then
		if value ~= nil and not states[value] then
			error(string.format("Unable to assign property %s. Instance expected, got %s", key, typeName(value)), 0)
		end
		return value
	end
	local vt = typeName(value)
	if dt == "Bool" then
		if vt ~= "boolean" then
			error(string.format("Unable to assign property %s. bool expected, got %s", key, vt), 0)
		end
		return value
	elseif dt == "Float32" or dt == "Float64" or dt == "Int32" or dt == "Int64" then
		if vt ~= "number" then
			local n = vt == "string" and tonumber(value) or nil
			if n == nil then
				error(string.format("Unable to assign property %s. number expected, got %s", key, vt), 0)
			end
			value = n
		end
		if value ~= value then
			return 0
		end
		if dt == "Int32" or dt == "Int64" then
			if value >= 0 then
				value = math.floor(value + 0.5 - 1e-9)
			else
				value = math.ceil(value - 0.5 + 1e-9)
			end
		end
		return value
	elseif dt == "String" then
		if vt == "number" then
			return tostring(value)
		elseif vt ~= "string" then
			error(string.format("Unable to assign property %s. string expected, got %s", key, vt), 0)
		end
		return value
	elseif dt == "Content" or dt == "ContentId" then
		if vt == "string" then
			return value
		elseif vt == "Content" then
			local uri = value.Uri
			return uri or ""
		elseif vt == "number" then
			return "rbxassetid://" .. tostring(value)
		end
		error(string.format("Unable to assign property %s. Content expected, got %s", key, vt), 0)
	end
	local want = typeAlias[dt] or dt
	if vt ~= want then
		if want == "ColorSequence" and vt == "Color3" then
			return D.ColorSequence.new(value)
		elseif want == "NumberSequence" and vt == "number" then
			return D.NumberSequence.new(value)
		elseif want == "NumberRange" and vt == "number" then
			return roblox.NumberRange.new(value)
		end
		error(string.format("Unable to assign property %s. %s expected, got %s", key, want, vt), 0)
	end
	return value
end
R.coerce = coerce

------------------------------------------------------------------------------------------
-- The proxy metatable functions
------------------------------------------------------------------------------------------

local function findChild(st, name: string)
	local children = st.children
	for i = 1, #children do
		local c = children[i]
		if states[c].name == name then
			return c
		end
	end
	return nil
end
R.findChild = findChild

local function index(proxy, key)
	local st = states[proxy]
	local info = st.info
	local m = info.methods[key]
	if m then
		return m
	end
	local g = info.getters[key]
	if g then
		return g(proxy, st)
	end
	local p = info.props[key]
	if p then
		local v = st.props[key]
		if v == nil then
			v = info.defaults[key]
		end
		return v
	end
	if info.events[key] then
		return getSignal(st, key)
	end
	if type(key) == "string" then
		local child = findChild(st, key)
		if child then
			return child
		end
	end
	error(string.format("%s is not a valid member of %s \"%s\"", tostring(key), info.name, fullName(proxy)), 2)
end

local function newindex(proxy, key, value)
	local st = states[proxy]
	local info = st.info
	local setter = info.setters[key]
	if setter then
		local ok, err = pcall(setter, proxy, st, value)
		if not ok then
			error(err, 2)
		end
		return
	end
	local p = info.props[key]
	if not p then
		error(string.format("%s is not a valid member of %s \"%s\"", tostring(key), info.name, fullName(proxy)), 2)
	end
	if p.readOnly then
		error(string.format("Unable to assign property %s. Property is read only", key), 2)
	end
	local ok, v = pcall(coerce, info, key, p, value)
	if not ok then
		error(v, 2)
	end
	local old = st.props[key]
	if old == nil then
		old = info.defaults[key]
	end
	st.props[key] = v
	if old ~= v then
		changed(proxy, st, key)
	end
end

local function tostr(proxy)
	local st = states[proxy]
	return st and st.name or "<dead instance>"
end

------------------------------------------------------------------------------------------
-- Creation
------------------------------------------------------------------------------------------

local idCounter = 0

-- Creates an instance of `className` without the creatable check (services, internals).
local function create(className: string)
	local info = R.classInfo(className)
	if not info then
		error(string.format("Unable to create an Instance of type \"%s\" (unknown class in the preview mock)", tostring(className)), 3)
	end
	local proxy = newproxy(true)
	local mt = getmetatable(proxy)
	mt.__index = index
	mt.__newindex = newindex
	mt.__tostring = tostr
	idCounter += 1
	local st = {
		info = info,
		props = {},
		name = className,
		parent = nil,
		children = {},
		attrs = nil,
		tags = nil,
		sigs = nil,
		propSigs = nil,
		attrSigs = nil,
		x = {},
		id = idCounter,
		destroyed = false,
	}
	states[proxy] = st
	for _, h in ipairs(info.onCreate) do
		h(proxy, st)
	end
	return proxy
end
R.create = create

function R.new(className: string, parent)
	local info = R.classInfo(className)
	if not info then
		error(string.format("Unable to create an Instance of type \"%s\"", tostring(className)), 2)
	end
	if not info.creatable then
		error(string.format("Unable to create an Instance of type \"%s\"", className), 2)
	end
	local inst = create(className)
	if parent ~= nil then
		inst.Parent = parent
	end
	return inst
end

------------------------------------------------------------------------------------------
-- Parenting
------------------------------------------------------------------------------------------

R.ancestryListeners = 0 -- skip subtree walks when nobody listens to AncestryChanged

local function walk(proxy, fn)
	fn(proxy)
	local children = states[proxy].children
	for i = 1, #children do
		walk(children[i], fn)
	end
end
R.walk = walk

local function descendantListeners(start)
	local list = nil
	local p = start
	while p do
		local s = states[p]
		if s.sigs then
			for _, name in ipairs({ "DescendantAdded", "DescendantRemoving" }) do
				if hasListeners(s, name) then
					list = list or {}
					table.insert(list, { p = p, s = s })
					break
				end
			end
		end
		p = s.parent
	end
	return list
end

local function setParent(proxy, st, newParent)
	if newParent ~= nil and not states[newParent] then
		error(string.format("Unable to assign property Parent. Instance expected, got %s", typeName(newParent)), 0)
	end
	local old = st.parent
	if old == newParent then
		return
	end
	if st.parentLocked then
		error(string.format("The Parent property of %s is locked, current parent: %s, new parent %s", st.name, old and states[old].name or "NULL", newParent and states[newParent].name or "NULL"), 0)
	end
	local p = newParent
	while p do
		if p == proxy then
			error(string.format("Attempt to set parent of %s to %s would result in circular reference", fullName(proxy), fullName(newParent)), 0)
		end
		p = states[p].parent
	end
	if old then
		local ost = states[old]
		local listeners = descendantListeners(old)
		if listeners then
			walk(proxy, function(d)
				for _, l in ipairs(listeners) do
					fire(l.s, "DescendantRemoving", d)
				end
			end)
		end
		local i = table.find(ost.children, proxy)
		if i then
			table.remove(ost.children, i)
		end
		st.parent = nil
		fire(ost, "ChildRemoved", proxy)
	end
	st.parent = newParent
	if newParent then
		local nst = states[newParent]
		table.insert(nst.children, proxy)
		fire(nst, "ChildAdded", proxy)
		local listeners = descendantListeners(newParent)
		if listeners then
			walk(proxy, function(d)
				for _, l in ipairs(listeners) do
					fire(l.s, "DescendantAdded", d)
				end
			end)
		end
	end
	for _, h in ipairs(st.info.onParent) do
		h(proxy, st, old, newParent)
	end
	if st.info.isGui or (newParent and states[newParent].info.isGui) or (old and states[old].info.isGui) then
		R.guiDirty = true
	end
	if R.ancestryListeners > 0 then
		walk(proxy, function(d)
			fire(states[d], "AncestryChanged", proxy, newParent)
		end)
	end
	changed(proxy, st, "Parent")
end
R.setParent = setParent

------------------------------------------------------------------------------------------
-- Instance base class behaviour
------------------------------------------------------------------------------------------

local ATTRIBUTE_TYPES = {
	boolean = true, number = true, string = true, UDim = true, UDim2 = true, BrickColor = true, Color3 = true,
	Vector2 = true, Vector3 = true, CFrame = true, NumberSequence = true, ColorSequence = true,
	NumberRange = true, Rect = true, Font = true, EnumItem = true,
}

local function destroy(proxy)
	local st = states[proxy]
	if not st or st.destroyed then
		return
	end
	if st.sigs and st.sigs.Destroying then
		st.sigs.Destroying:_fireSync()
	end
	local children = table.clone(st.children)
	for _, c in ipairs(children) do
		destroy(c)
	end
	if st.parent then
		setParent(proxy, st, nil)
	end
	st.parentLocked = true
	st.destroyed = true
	for _, group in ipairs({ st.sigs, st.propSigs, st.attrSigs }) do
		if group then
			for _, sig in pairs(group) do
				for _, c in ipairs(sig._conns) do
					c.Connected = false
				end
				table.clear(sig._conns)
			end
		end
	end
	if st.x.onDestroy then
		st.x.onDestroy(proxy, st)
	end
end
R.destroy = destroy

local function deepCopyTable(t)
	local out = {}
	for k, v in pairs(t) do
		out[k] = v
	end
	return out
end

local function clone(proxy)
	local st = states[proxy]
	if st.props.Archivable == false then
		return nil
	end
	local map = {}
	local function copy(src)
		local sst = states[src]
		if sst.props.Archivable == false then
			return nil
		end
		local dst = create(sst.info.name)
		local dstState = states[dst]
		dstState.props = deepCopyTable(sst.props)
		dstState.name = sst.name
		if sst.attrs then
			dstState.attrs = deepCopyTable(sst.attrs)
		end
		if sst.tags then
			dstState.tags = deepCopyTable(sst.tags)
		end
		for k, v in pairs(sst.x) do
			if k ~= "layout" and k ~= "onDestroy" then
				dstState.x[k] = type(v) == "table" and deepCopyTable(v) or v
			end
		end
		-- children made by onCreate (e.g. a default Camera) are replaced by the copies
		for _, c in ipairs(table.clone(dstState.children)) do
			destroy(c)
		end
		map[src] = dst
		for _, c in ipairs(sst.children) do
			local cc = copy(c)
			if cc then
				states[cc].parent = dst
				table.insert(dstState.children, cc)
			end
		end
		for _, h in ipairs(sst.info.onClone) do
			h(src, dst, sst, dstState)
		end
		return dst
	end
	local root = copy(proxy)
	for _, dst in pairs(map) do
		local ds = states[dst]
		for k, v in pairs(ds.props) do
			if type(v) == "userdata" and states[v] and map[v] then
				ds.props[k] = map[v]
			end
		end
		if ds.x.refs then
			for k, v in pairs(ds.x.refs) do
				if map[v] then
					ds.x.refs[k] = map[v]
				end
			end
		end
	end
	return root
end
R.clone = clone

local function isA(proxy, className: string): boolean
	return states[proxy].info.isA[className] == true
end

local function findFirstChild(proxy, name: string, recursive: boolean?)
	local st = states[proxy]
	if type(name) ~= "string" then
		error("Argument 1 missing or nil", 2)
	end
	local c = findChild(st, name)
	if c or not recursive then
		return c
	end
	for _, child in ipairs(st.children) do
		local found = findFirstChild(child, name, true)
		if found then
			return found
		end
	end
	return nil
end
R.findFirstChild = findFirstChild

local function descendants(proxy, out)
	for _, c in ipairs(states[proxy].children) do
		table.insert(out, c)
		descendants(c, out)
	end
	return out
end
R.descendants = function(proxy)
	return descendants(proxy, {})
end

local function attrSignal(st, name: string)
	local list = st.attrSigs
	if not list then
		list = {}
		st.attrSigs = list
	end
	local s = list[name]
	if not s then
		s = Signal.new("AttributeChanged:" .. name)
		list[name] = s
	end
	return s
end

R.defineClass("Instance", {
	events = { "Changed", "ChildAdded", "ChildRemoved", "DescendantAdded", "DescendantRemoving", "AncestryChanged", "Destroying", "AttributeChanged" },
	defaults = { Archivable = true },
	getters = {
		Name = function(_, st)
			return st.name
		end,
		Parent = function(_, st)
			return st.parent
		end,
		ClassName = function(_, st)
			return st.info.name
		end,
		className = function(_, st)
			return st.info.name
		end,
	},
	setters = {
		Name = function(proxy, st, v)
			if type(v) == "number" then
				v = tostring(v)
			end
			if type(v) ~= "string" then
				error("Unable to assign property Name. string expected, got " .. typeName(v), 0)
			end
			if st.name ~= v then
				st.name = v
				changed(proxy, st, "Name")
			end
		end,
		Parent = function(proxy, st, v)
			setParent(proxy, st, v)
		end,
		ClassName = function()
			error("Unable to assign property ClassName. Property is read only", 0)
		end,
	},
	methods = {
		IsA = isA,
		isA = isA,
		FindFirstChild = findFirstChild,
		findFirstChild = findFirstChild,
		FindFirstChildOfClass = function(proxy, className)
			for _, c in ipairs(states[proxy].children) do
				if states[c].info.name == className then
					return c
				end
			end
			return nil
		end,
		FindFirstChildWhichIsA = function(proxy, className, recursive)
			local list = recursive and descendants(proxy, {}) or states[proxy].children
			for _, c in ipairs(list) do
				if states[c].info.isA[className] then
					return c
				end
			end
			return nil
		end,
		FindFirstAncestor = function(proxy, name)
			local p = states[proxy].parent
			while p do
				if states[p].name == name then
					return p
				end
				p = states[p].parent
			end
			return nil
		end,
		FindFirstAncestorOfClass = function(proxy, className)
			local p = states[proxy].parent
			while p do
				if states[p].info.name == className then
					return p
				end
				p = states[p].parent
			end
			return nil
		end,
		FindFirstAncestorWhichIsA = function(proxy, className)
			local p = states[proxy].parent
			while p do
				if states[p].info.isA[className] then
					return p
				end
				p = states[p].parent
			end
			return nil
		end,
		FindFirstDescendant = function(proxy, name)
			for _, d in ipairs(descendants(proxy, {})) do
				if states[d].name == name then
					return d
				end
			end
			return nil
		end,
		GetChildren = function(proxy)
			return table.clone(states[proxy].children)
		end,
		getChildren = function(proxy)
			return table.clone(states[proxy].children)
		end,
		GetDescendants = function(proxy)
			return descendants(proxy, {})
		end,
		IsDescendantOf = function(proxy, ancestor)
			if ancestor == nil then
				return false
			end
			local p = states[proxy].parent
			while p do
				if p == ancestor then
					return true
				end
				p = states[p].parent
			end
			return false
		end,
		IsAncestorOf = function(proxy, descendant)
			if descendant == nil then
				return false
			end
			local p = states[descendant].parent
			while p do
				if p == proxy then
					return true
				end
				p = states[p].parent
			end
			return false
		end,
		GetFullName = function(proxy)
			return fullName(proxy)
		end,
		Clone = clone,
		clone = clone,
		Destroy = destroy,
		destroy = destroy,
		Remove = function(proxy)
			setParent(proxy, states[proxy], nil)
		end,
		ClearAllChildren = function(proxy)
			for _, c in ipairs(table.clone(states[proxy].children)) do
				destroy(c)
			end
		end,
		WaitForChild = function(proxy, name, timeout)
			local st = states[proxy]
			if type(name) ~= "string" then
				error("Argument 1 missing or nil", 2)
			end
			local c = findChild(st, name)
			if c then
				return c
			end
			if not coroutine.isyieldable() then
				error(string.format("WaitForChild(\"%s\") on %s cannot yield here and the child is missing", name, fullName(proxy)), 2)
			end
			local limit = tonumber(timeout)
			local warned = false
			local hardLimit = R.options.waitTimeout or 10
			local start = S.now
			while true do
				S.wait(0)
				c = findChild(st, name)
				if c then
					return c
				end
				local waited = S.now - start
				if limit and waited >= limit then
					return nil
				end
				if not limit and not warned and waited >= 5 then
					warned = true
					R.warn(string.format("Infinite yield possible on '%s:WaitForChild(\"%s\")'", fullName(proxy), name))
				end
				if not limit and waited >= hardLimit then
					error(string.format("[preview mock] WaitForChild timed out after %gs: %s has no child \"%s\" (the scene never created it)", hardLimit, fullName(proxy), name), 2)
				end
			end
		end,
		GetAttribute = function(proxy, name)
			local attrs = states[proxy].attrs
			return attrs and attrs[name]
		end,
		SetAttribute = function(proxy, name, value)
			local st = states[proxy]
			if type(name) ~= "string" then
				error("Argument 1 missing or nil", 2)
			end
			if value ~= nil and not ATTRIBUTE_TYPES[D.typeof(value)] then
				error(string.format("%s is not a supported attribute type", D.typeof(value)), 2)
			end
			local attrs = st.attrs
			if not attrs then
				attrs = {}
				st.attrs = attrs
			end
			local old = attrs[name]
			attrs[name] = value
			if old ~= value then
				if st.info.isGui then
					R.guiDirty = true
				end
				local list = st.attrSigs
				local s = list and list[name]
				if s and #s._conns > 0 then
					s:_fire()
				end
				fire(st, "AttributeChanged", name)
			end
		end,
		GetAttributes = function(proxy)
			return table.clone(states[proxy].attrs or {})
		end,
		GetAttributeChangedSignal = function(proxy, name)
			return attrSignal(states[proxy], name)
		end,
		GetPropertyChangedSignal = function(proxy, prop)
			local st = states[proxy]
			local info = st.info
			if not info.props[prop] and not info.getters[prop] then
				error(string.format("%s is not a valid property name.", tostring(prop)), 2)
			end
			local list = st.propSigs
			if not list then
				list = {}
				st.propSigs = list
			end
			local s = list[prop]
			if not s then
				s = Signal.new("PropertyChanged:" .. prop)
				list[prop] = s
				if R.onPropertySignal then
					R.onPropertySignal(proxy, st, prop)
				end
			end
			return s
		end,
		AddTag = function(proxy, tag)
			local st = states[proxy]
			st.tags = st.tags or {}
			if not st.tags[tag] then
				st.tags[tag] = true
				if R.onTagAdded then
					R.onTagAdded(proxy, tag)
				end
			end
		end,
		RemoveTag = function(proxy, tag)
			local st = states[proxy]
			if st.tags and st.tags[tag] then
				st.tags[tag] = nil
				if R.onTagRemoved then
					R.onTagRemoved(proxy, tag)
				end
			end
		end,
		HasTag = function(proxy, tag)
			local tags = states[proxy].tags
			return tags ~= nil and tags[tag] == true
		end,
		GetTags = function(proxy)
			local out = {}
			for t in pairs(states[proxy].tags or {}) do
				table.insert(out, t)
			end
			table.sort(out)
			return out
		end,
		GetActor = function()
			return nil
		end,
		GetDebugId = function(proxy)
			return tostring(states[proxy].id)
		end,
		IsPropertyModified = function(proxy, prop)
			return states[proxy].props[prop] ~= nil
		end,
		ResetPropertyToDefault = function(proxy, prop)
			local st = states[proxy]
			st.props[prop] = nil
			changed(proxy, st, prop)
		end,
		GetStyled = function(proxy, prop)
			return proxy[prop]
		end,
	},
})

return {
	new = R.new,
}
