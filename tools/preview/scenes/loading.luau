-- loading: mesh loading order with simulated InsertService downloads (the mock fetches at
-- most `slots` assets at once, first come first served, `base` seconds each: a rough model
-- of the engine's limited asset fetches).
--   --set base=0.4 --set slots=6    the download model (simulated seconds)
--   --set mode=new|old              new: the real MeshService (priority queue, 6 at a time)
--                                   + the lobby; old: every LoadAsset at once (the previous
--                                   MeshService.Start), timing only
--   --set at=1.5                    new mode: render the menu at this time (the "Loading
--                                   models" pill); without it the scene runs until every
--                                   model is in and prints the timings
-- Prints when the lobby set (Castle + Heroes + Hats categories) and everything were loaded.
local C = lib("common")
local base = tonumber(preview.args.base) or 0.4
local slots = tonumber(preview.args.slots) or 6
preview.setLoadLatency(base, slots)
local MeshCatalog = C.shared("MeshCatalog")
local LOBBY = { Castle = true, Heroes = true, Hats = true }
local lobbySet, all = {}, {}
for name, e in pairs(MeshCatalog.Models) do
	all[name] = true
	if LOBBY[e.Category] then
		lobbySet[name] = true
	end
end

local t0 = os.clock()
local done: { [string]: number } = {}
local function report()
	local lobbyAt, allAt, nLobby, nAll = 0, 0, 0, 0
	for name in pairs(all) do
		local t = done[name]
		if t then
			nAll += 1
			allAt = math.max(allAt, t)
			if lobbySet[name] then
				nLobby += 1
				lobbyAt = math.max(lobbyAt, t)
			end
		end
	end
	local totalLobby = 0
	for _ in pairs(lobbySet) do
		totalLobby += 1
	end
	preview.log(string.format("[loading] %s: lobby set (%d/%d models) at %.2f s, all (%d models) at %.2f s (%d downloads at once, %.2f s each)", preview.args.mode or "new", nLobby, totalLobby, lobbyAt, nAll, allAt, slots, base))
end

if preview.args.mode == "old" then
	C.shared("Remotes").Setup()
	preview.forceMeshesUploaded()
	local InsertService = game:GetService("InsertService")
	for name, e in pairs(MeshCatalog.Models) do
		task.spawn(function()
			local ok = pcall(function()
				return InsertService:LoadAsset(e.AssetId)
			end)
			if ok then
				done[name] = os.clock() - t0
			end
		end)
	end
	preview.advance(60)
	report()
	return
end

local s = C.lobby()
local folder = game:GetService("ReplicatedStorage"):FindFirstChild("SwarmMeshes")
if folder then
	for _, f in ipairs(folder:GetChildren()) do
		done[f.Name] = 0
	end
	folder.ChildAdded:Connect(function(f)
		done[f.Name] = os.clock() - t0
	end)
end
if preview.args.at then
	C.startClient()
	C.sendProfile()
	C.settle(tonumber(preview.args.at) or 1.5)
	report()
else
	-- timing only (no client: much faster to simulate)
	for _ = 1, 120 do
		preview.advance(0.5, 4)
		if folder and folder:GetAttribute("AllReady") then
			break
		end
	end
	report()
end
local _ = s
