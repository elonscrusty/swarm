--!nocheck
--[[
	main.luau - runs one preview scene headlessly and writes the scene JSON.

	lune run tools/preview/runtime/main.luau -- --scene menu --device phone --out out.json
	    [--seed N] [--studio] [--repo PATH] [--root PATH] [--set key=value ...]

	The scene (tools/preview/scenes/<name>.luau) runs as the main thread of the simulated
	scheduler with the same globals as game code plus `preview` (mock/init.luau).
	Game errors are printed with their stack and the scene is still exported, so a broken
	module never stops the rest of the picture from rendering.
]]

local process = require("@lune/process")
local fs = require("@lune/fs")
local serde = require("@lune/serde")

local Mock = require("./mock")
local R = Mock.R
local S = Mock.S

local function parseArgs(argv)
	local out = { set = {} }
	local i = 1
	while i <= #argv do
		local a = argv[i]
		if a == "--" then
			i += 1
			continue
		end
		local key = string.match(a, "^%-%-(.+)$")
		if key == "studio" or key == "quiet" or key == "no-coreui" or key == "print-metrics" then
			out[key] = true
			i += 1
		elseif key == "set" then
			local k, v = string.match(argv[i + 1] or "", "^([^=]+)=(.*)$")
			if k then
				out.set[k] = v
			end
			i += 2
		elseif key then
			out[key] = argv[i + 1]
			i += 2
		else
			i += 1
		end
	end
	return out
end

local args = parseArgs(process.args)
local root = args.root or (process.cwd .. "/tools/preview")
local repo = args.repo or process.cwd
local sceneName = args.scene or "menu"
local deviceName = args.device or "pc"
local outPath = args.out or (root .. "/out/" .. sceneName .. "-" .. deviceName .. ".json")
local seed = tonumber(args.seed) or 1

local function readJson(path)
	if not fs.isFile(path) then
		return nil
	end
	return serde.decode("json", fs.readFile(path))
end

local metrics = readJson(root .. "/.cache/fonts/metrics.json")
if not metrics then
	print("[preview] fonts are missing: run bash tools/preview/setup.sh")
	process.exit(2)
end

local scenePath = root .. "/scenes/" .. sceneName .. ".luau"
if not fs.isFile(scenePath) then
	print("[preview] no scene " .. sceneName .. " (" .. scenePath .. ")")
	process.exit(2)
end

local preview = Mock.boot({
	device = deviceName,
	seed = seed,
	repo = repo,
	root = root,
	studio = args.studio == true,
	fontMetrics = metrics,
	catalog = readJson(repo .. "/meshes/catalog.json"),
	waitTimeout = tonumber(args["wait-timeout"]) or 10,
	sceneArgs = args.set,
})
if args["no-coreui"] then
	preview.render.hideCoreUi = true
end

-- scene helper libraries (scenes/lib/*.luau), compiled with the scene environment
local sceneSource = fs.readFile(scenePath)
local libSources = {}
if fs.isDir(root .. "/scenes/lib") then
	for _, f in ipairs(fs.readDir(root .. "/scenes/lib")) do
		local name = string.match(f, "^(.+)%.luau$")
		if name then
			libSources[name] = fs.readFile(root .. "/scenes/lib/" .. f)
		end
	end
end

local sceneEnv = R.envFor(nil)
sceneEnv.preview = preview
local libCache = {}
sceneEnv.lib = function(name: string)
	if libCache[name] == nil then
		local src = libSources[name] or error("no scene library " .. name)
		local fn = R.compile(src, "scenes/lib/" .. name .. ".luau", sceneEnv)
		libCache[name] = fn()
	end
	return libCache[name]
end

local started = os.clock()
local ok, err = S.runMain(function()
	local fn = R.compile(sceneSource, "scenes/" .. sceneName .. ".luau", sceneEnv)
	local result = fn()
	if type(result) == "function" then
		result(preview)
	elseif type(result) == "table" and type(result.run) == "function" then
		result.run(preview)
	end
end, tonumber(args["max-time"]) or 120)
if not ok then
	R.error("scene " .. sceneName .. " failed", tostring(err))
end

-- threads still waiting on WaitForChild etc. are listed by the warnings already
local data = Mock.export(sceneName)
data.realSeconds = os.clock() - started
local json = serde.encode("json", data, false)
local dir = string.match(outPath, "^(.*)/[^/]+$")
if dir and not fs.isDir(dir) then
	fs.writeDir(dir)
end
fs.writeFile(outPath, json)

-- scene metrics also go to <out>.metrics.json (and stdout with --print-metrics)
local metricsPath = string.gsub(outPath, "%.json$", "") .. ".metrics.json"
fs.writeFile(metricsPath, serde.encode("json", data.metrics, true))
if args["print-metrics"] then
	print(serde.encode("json", data.metrics, true))
end

local errs = #R.log.errors
print(string.format("[preview] %s on %s: %d parts, %d gui layers, %d errors, %d warnings, %.1fs simulated, %.1fs real -> %s",
	sceneName, deviceName, #data.world.parts, #data.gui.layers, errs, #R.log.warnings, S.now, os.clock() - started, outPath))
process.exit(0)
