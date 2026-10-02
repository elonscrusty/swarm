--!nocheck
--[[
	datamodel.luau - builds the game tree from default.project.json (Rojo rules) and runs
	game code: require(ModuleScript), Scripts / LocalScripts, and the global environment
	every chunk gets (game, workspace, Instance, Enum, datatypes, task, wait, tick, ...).

	All files are read up front (in the main Lune thread); game code then runs inside the
	simulated scheduler, so yields (WaitForChild, task.wait) work anywhere.
]]

local fs = require("@lune/fs")
local serde = require("@lune/serde")
local luau = require("@lune/luau")
local roblox = require("@lune/roblox")
local R = require("./R")
local D = require("./datatypes")
local S = require("./scheduler")

local states = R.states
local Enum = roblox.Enum

local DM = {}

------------------------------------------------------------------------------------------
-- Global environment for game chunks
------------------------------------------------------------------------------------------

local baseEnv = getfenv(1)

local function makeOs()
	return {
		clock = function()
			return 1000 + S.now
		end,
		time = function(t)
			if t then
				return os.time(t)
			end
			return math.floor(R.epoch())
		end,
		date = function(fmt, t)
			return os.date(fmt, t or math.floor(R.epoch()))
		end,
		difftime = os.difftime,
	}
end

local function makeDebug()
	return {
		traceback = debug.traceback,
		info = debug.info,
		-- MicroProfiler labels: timed by the perf profiler (mock/profile.luau) when it is on
		profilebegin = function(label)
			local P = R.prof
			if P and P.on then
				P.enter("[label] " .. tostring(label))
			end
		end,
		profileend = function()
			local P = R.prof
			if P and P.on then
				local top = P.stack[#P.stack]
				if top and string.sub(top[1], 1, 8) == "[label] " then
					P.leave()
				end
			end
		end,
		setmemorycategory = function() end,
		resetmemorycategory = function() end,
		dumpcodesize = function() end,
	}
end

local function argsToString(...)
	local n = select("#", ...)
	local parts = {}
	for i = 1, n do
		parts[i] = tostring((select(i, ...)))
	end
	return table.concat(parts, " ")
end

function DM.makeGlobals()
	local G = {}
	for k, v in pairs(D) do
		if k ~= "typeof" then
			G[k] = v
		end
	end
	G.Enum = Enum
	G.typeof = D.typeof
	G.game = R.game
	G.Game = R.game
	G.workspace = R.services.Workspace
	G.Workspace = R.services.Workspace
	G.Instance = {
		new = R.new,
		fromExisting = function(inst)
			local copy = R.create(states[inst].info.name)
			local cs = states[copy]
			for k, v in pairs(states[inst].props) do
				cs.props[k] = v
			end
			cs.name = states[inst].name
			return copy
		end,
	}
	G.task = S.taskLibrary()
	G.wait = function(t)
		local elapsed = S.wait(t or 0.03)
		return elapsed, S.now
	end
	G.delay = function(t, f)
		S.delay(t or 0, f)
	end
	G.Delay = G.delay
	G.spawn = function(f)
		S.delay(0, f)
	end
	G.Spawn = G.spawn
	G.tick = function()
		return R.epoch()
	end
	G.time = function()
		return S.now
	end
	G.elapsedTime = function()
		return S.now
	end
	G.print = function(...)
		print("[game] " .. argsToString(...))
	end
	G.warn = function(...)
		R.warn(argsToString(...))
	end
	G.shared = {}
	G._G = {}
	G.os = makeOs()
	G.debug = makeDebug()
	G.version = function()
		return "0.694.0.6940982"
	end
	G.settings = function()
		return R.settingsObject
	end
	G.UserSettings = function()
		return R.userSettings
	end
	G.stats = function()
		return R.getService(R.game, "Stats")
	end
	G.ypcall = pcall
	G.unpack = table.unpack
	G.collectgarbage = function(opt)
		if opt == "count" then
			return collectgarbage("count")
		end
		return 0
	end
	G.newproxy = newproxy
	setmetatable(G, { __index = baseEnv })
	R.globals = G
	return G
end

local function envFor(script)
	local env = { script = script }
	env.require = function(target)
		return R.requireModule(target, script)
	end
	return setmetatable(env, { __index = R.globals })
end
R.envFor = envFor

local function compile(source: string, name: string, env)
	return luau.load(source, { debugName = name, environment = env, injectGlobals = false })
end
R.compile = compile

------------------------------------------------------------------------------------------
-- require
------------------------------------------------------------------------------------------

local moduleCache = setmetatable({}, { __mode = "k" })

local function resolveStringRequire(path: string, caller)
	-- string requires: "./Sibling", "../Folder/Module", "@game/ReplicatedStorage/Shared/Config"
	local cur
	local rest = path
	if string.sub(path, 1, 6) == "@game/" then
		cur = R.game
		rest = string.sub(path, 7)
	elseif string.sub(path, 1, 7) == "@self/" then
		cur = caller
		rest = string.sub(path, 7)
	else
		cur = caller and states[caller].parent
	end
	for part in string.gmatch(rest, "[^/]+") do
		if not cur then
			return nil
		end
		if part == "." then
			continue
		elseif part == ".." then
			cur = states[cur].parent
		else
			cur = R.findChild(states[cur], part)
		end
	end
	return cur
end

function R.requireModule(target, caller)
	if type(target) == "string" then
		local resolved = resolveStringRequire(target, caller)
		if not resolved then
			error(string.format("require(\"%s\"): module not found (preview mock)", target), 2)
		end
		target = resolved
	end
	if type(target) == "number" then
		error("require(assetId) is not supported in the preview", 2)
	end
	local st = R.isInstance(target) and states[target]
	if not st or not st.info.isA.ModuleScript then
		error("Attempted to call require with invalid argument(s).", 2)
	end
	local cached = moduleCache[target]
	if cached then
		if cached.state == "loading" then
			error(string.format("Requested module was required recursively (%s)", R.fullName(target)), 2)
		elseif cached.state == "error" then
			error(string.format("Requested module experienced an error while loading: %s", R.fullName(target)), 2)
		end
		return cached.value
	end
	if not st.x.source then
		error(string.format("ModuleScript %s has no source (preview mock)", R.fullName(target)), 2)
	end
	moduleCache[target] = { state = "loading" }
	local ok, fn = pcall(compile, st.x.source, st.x.path or R.fullName(target), envFor(target))
	if not ok then
		moduleCache[target] = { state = "error" }
		R.error("syntax error in " .. tostring(st.x.path) .. ": " .. tostring(fn))
		error("Requested module experienced an error while loading", 2)
	end
	local results
	local success, err = xpcall(function()
		results = table.pack(fn())
	end, function(e)
		return debug.traceback(tostring(e), 2)
	end)
	if not success then
		moduleCache[target] = { state = "error" }
		R.error("error while loading module " .. tostring(st.x.path or R.fullName(target)), err)
		error(string.format("Requested module experienced an error while loading: %s", tostring(st.x.path or R.fullName(target))), 2)
	end
	if results.n ~= 1 then
		moduleCache[target] = { state = "error" }
		error(string.format("Module code did not return exactly one value (%s)", R.fullName(target)), 2)
	end
	moduleCache[target] = { state = "done", value = results[1] }
	return results[1]
end

-- Runs a Script / LocalScript in its own thread.
function R.runScript(script)
	local st = states[script]
	local ok, fn = pcall(compile, st.x.source, st.x.path or R.fullName(script), envFor(script))
	if not ok then
		R.error("syntax error in " .. tostring(st.x.path) .. ": " .. tostring(fn))
		return
	end
	S.spawn(function()
		local success, err = xpcall(fn, function(e)
			return debug.traceback(tostring(e), 2)
		end)
		if not success then
			R.error("script " .. tostring(st.x.path or R.fullName(script)) .. " errored", err)
		end
	end)
end

------------------------------------------------------------------------------------------
-- Rojo project → instances
------------------------------------------------------------------------------------------

local function setPropertyFromJson(inst, key: string, value)
	local st = states[inst]
	local p = st.info.props[key]
	if not p then
		R.warn(string.format("project property %s.%s is unknown to the preview mock (ignored)", st.info.name, key))
		return
	end
	local dt = p.type
	local v = value
	if type(value) == "table" and value[1] == nil then
		-- explicit form { "Vector3": [...] } / { "Enum": 3 }
		local k, inner = next(value)
		dt = k == "Enum" and dt or k
		v = inner
	end
	local converted = v
	if p.enum then
		converted = R.enumFromValue(p.enum, v)
	elseif dt == "Color3" or dt == "Color3uint8" then
		converted = roblox.Color3.new(v[1], v[2], v[3])
	elseif dt == "Vector3" then
		converted = roblox.Vector3.new(v[1], v[2], v[3])
	elseif dt == "Vector2" then
		converted = roblox.Vector2.new(v[1], v[2])
	elseif dt == "UDim2" then
		converted = roblox.UDim2.new(v[1][1], v[1][2], v[2][1], v[2][2])
	elseif dt == "UDim" then
		converted = roblox.UDim.new(v[1], v[2])
	elseif dt == "CFrame" then
		local pos, rot = v.position or v[1], v.orientation or v[2]
		converted = roblox.CFrame.new(pos[1], pos[2], pos[3], rot[1][1], rot[1][2], rot[1][3], rot[2][1], rot[2][2], rot[2][3], rot[3][1], rot[3][2], rot[3][3])
	end
	local ok, err = pcall(function()
		inst[key] = converted
	end)
	if not ok then
		R.warn(string.format("project property %s.%s could not be set: %s", st.info.name, key, tostring(err)))
	end
end

local function stripExt(fileName: string)
	for _, suffix in ipairs({ ".server.luau", ".server.lua", ".client.luau", ".client.lua", ".luau", ".lua" }) do
		if string.sub(fileName, -#suffix) == suffix then
			local kind = (string.find(suffix, "server") and "Script") or (string.find(suffix, "client") and "LocalScript") or "ModuleScript"
			return string.sub(fileName, 1, -#suffix - 1), kind
		end
	end
	return nil, nil
end

local function makeScript(className: string, name: string, source: string, relPath: string)
	local inst = R.create(className)
	local st = states[inst]
	st.name = name
	st.x.source = source
	st.x.path = relPath
	return inst
end

local loadPath -- forward

local function loadDirectory(dirPath: string, relPath: string, name: string)
	local entries = fs.readDir(dirPath)
	table.sort(entries)
	-- init script?
	local inst
	for _, initName in ipairs({ "init.server.luau", "init.server.lua", "init.client.luau", "init.client.lua", "init.luau", "init.lua" }) do
		if table.find(entries, initName) then
			local _, kind = stripExt(initName)
			inst = makeScript(kind, name, fs.readFile(dirPath .. "/" .. initName), relPath .. "/" .. initName)
			break
		end
	end
	if not inst then
		inst = R.create("Folder")
		states[inst].name = name
	end
	for _, entry in ipairs(entries) do
		if not string.match(entry, "^init%.") and not string.match(entry, "^%.") then
			local child = loadPath(dirPath .. "/" .. entry, relPath .. "/" .. entry, nil)
			if child then
				R.setParent(child, states[child], inst)
			end
		end
	end
	return inst
end

loadPath = function(fullPath: string, relPath: string, overrideName: string?)
	if fs.isDir(fullPath) then
		local name = overrideName or string.match(fullPath, "([^/]+)$")
		return loadDirectory(fullPath, relPath, name)
	end
	local fileName = string.match(fullPath, "([^/]+)$")
	local base, kind = stripExt(fileName)
	if base then
		return makeScript(kind, overrideName or base, fs.readFile(fullPath), relPath)
	end
	if string.sub(fileName, -10) == ".meta.json" then
		return nil
	end
	if string.sub(fileName, -5) == ".json" and string.sub(fileName, -11) ~= ".model.json" then
		local data = fs.readFile(fullPath)
		local inst = R.create("ModuleScript")
		states[inst].name = overrideName or string.sub(fileName, 1, -6)
		states[inst].x.path = relPath
		states[inst].x.source = "return game:GetService('HttpService'):JSONDecode([==[" .. data .. "]==])"
		return inst
	end
	if string.sub(fileName, -4) == ".txt" then
		local inst = R.create("StringValue")
		states[inst].name = overrideName or string.sub(fileName, 1, -5)
		inst.Value = fs.readFile(fullPath)
		return inst
	end
	R.warn("project file type not supported by the preview mock: " .. relPath)
	return nil
end

local function buildNode(node, name: string, parent, repo: string)
	local inst
	local className = node["$className"]
	if node["$path"] then
		local rel = node["$path"]
		inst = loadPath(repo .. "/" .. rel, rel, name)
		if not inst then
			return nil
		end
	elseif className then
		local info = R.classInfo(className)
		if info and info.service then
			inst = R.getService(R.game, className)
		else
			inst = R.create(className)
			states[inst].name = name
		end
	else
		inst = R.create("Folder")
		states[inst].name = name
	end
	if node["$properties"] then
		for k, v in pairs(node["$properties"]) do
			setPropertyFromJson(inst, k, v)
		end
	end
	for key, child in pairs(node) do
		if string.sub(key, 1, 1) ~= "$" and type(child) == "table" then
			buildNode(child, key, inst, repo)
		end
	end
	if parent and states[inst].parent ~= parent then
		R.setParent(inst, states[inst], parent)
	end
	return inst
end

function DM.loadProject(repo: string, projectFile: string)
	local project = serde.decode("json", fs.readFile(repo .. "/" .. projectFile))
	local tree = project.tree
	for key, child in pairs(tree) do
		if string.sub(key, 1, 1) ~= "$" then
			buildNode(child, key, R.game, repo)
		end
	end
	if tree["$properties"] then
		for k, v in pairs(tree["$properties"]) do
			setPropertyFromJson(R.game, k, v)
		end
	end
	return project
end

R.datamodel = DM
return DM
