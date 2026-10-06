local process = require("@lune/process")
local Mock = require("./preview/runtime/mock")
local R, S = Mock.R, Mock.S
local preview = Mock.boot({ device = process.args[1] or "phone", seed = 7, repo = process.cwd, root = process.cwd .. "/tools/preview", fontMetrics = nil })
local ok, err = S.runMain(function()
	preview.startClient(false)
	preview.shared("Remotes").Setup()
	preview.client("UIBuilder").Init({})
	preview.advance(0.2)
	local Lay = require("./preview/runtime/mock/layout")
	local sw = preview.playerGui():FindFirstChild("SwarmUI")
	local function timeIt()
		local best = math.huge
		for _ = 1, 3 do
			R.guiDirty = true
			local t = os.clock(); Lay.update(true); best = math.min(best, os.clock() - t)
		end
		return best
	end
	local full = timeIt()
	print("PROBE full", full, sw, #Lay.roots())
	local function probe(container, depth)
		for _, r in ipairs(container:GetChildren()) do
			local n = #r:GetDescendants()
			if n > 40 then
				local par = r.Parent
				r.Parent = nil
				local dt = full - timeIt()
				r.Parent = par
				print(string.format("PROBE %s%-30s %-12s n=%5d saves %.3fs", string.rep("  ", depth), r.Name, r.ClassName, n, dt))
				if dt > 0.05 and depth < 12 then probe(r, depth + 1) end
			end
		end
	end
	probe(sw, 0)
end, 10)
