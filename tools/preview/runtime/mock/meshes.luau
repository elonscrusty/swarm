--!nocheck
--[[
	meshes.luau - InsertService:LoadAsset for the Blender mesh models.

	LoadAsset(id) returns what the Roblox importer gives MeshService: a Model holding a
	Model named after the catalog entry, holding one upright MeshPart per piece (named
	like the piece, sized like the piece). Each MeshPart carries the attribute
	PreviewMeshRef = "<Category>/<Model>.fbx#<Piece>", which the renderer resolves to the
	piece geometry inside meshes/<Category>/<Model>.fbx.

	Asset ids come from the live MeshCatalog module (so a scene can patch AssetId = 0
	entries to fake ids and preview models that are not uploaded yet).
]]

local roblox = require("@lune/roblox")
local R = require("./R")

local states = R.states
local Vector3, CFrame = roblox.Vector3, roblox.CFrame

local M = {}

R.meshTris = {} -- PreviewMeshRef → triangle estimate (catalog tris / pieces)

-- catalog.json (decoded list) → by name
function M.setCatalog(list)
	local byName = {}
	for _, entry in ipairs(list or {}) do
		byName[entry.name] = entry
	end
	R.catalogJson = byName
end

local function liveCatalog()
	local shared = R.services.ReplicatedStorage and R.findChild(states[R.services.ReplicatedStorage], "Shared")
	local mod = shared and R.findChild(states[shared], "MeshCatalog")
	if not mod then
		return nil
	end
	local ok, value = pcall(R.requireModule, mod)
	if ok and type(value) == "table" then
		return value
	end
	return nil
end
M.liveCatalog = liveCatalog

-- Gives every catalog model with AssetId 0 a fake id so MeshService loads it.
function M.forceUploaded(): { string }
	local mc = liveCatalog()
	local forced = {}
	if not mc then
		R.warn("MeshCatalog module not found; cannot force models as uploaded")
		return forced
	end
	local n = 0
	local names = {}
	for name in pairs(mc.Models) do
		table.insert(names, name)
	end
	table.sort(names)
	for _, name in ipairs(names) do
		local entry = mc.Models[name]
		n += 1
		if not entry.AssetId or entry.AssetId == 0 then
			entry.AssetId = 990000000 + n
			table.insert(forced, name)
		end
	end
	return forced
end

R.loadAsset = function(id)
	local mc = liveCatalog()
	local name, entry
	if mc then
		for n, e in pairs(mc.Models) do
			if e.AssetId == id then
				name, entry = n, e
				break
			end
		end
	end
	if not name then
		error(string.format("InsertService:LoadAsset(%s): no catalog model has this asset id (preview mock)", tostring(id)), 2)
	end
	local json = R.catalogJson and R.catalogJson[name]
	local category = (json and json.category) or entry.Category or "World"
	local container = R.create("Model")
	states[container].name = "Model"
	local model = R.create("Model")
	states[model].name = name
	R.setParent(model, states[model], container)
	-- pieces: the exported FBX's pieces (catalog.json) plus any the Lua catalog adds
	local pieces = {}
	local seen = {}
	if json then
		for _, p in ipairs(json.pieces) do
			table.insert(pieces, { name = p.name, size = p.size, offset = p.offset, fbx = true })
			seen[p.name] = true
		end
	end
	for _, p in ipairs(entry.Pieces or {}) do
		if not seen[p.Name] then
			table.insert(pieces, { name = p.Name, size = p.Size, offset = p.Offset, fbx = json == nil })
			if json then
				R.warn(string.format("%s: piece %s is in MeshCatalog.lua but not in meshes/catalog.json (drawn as a box)", name, p.Name))
			end
		end
	end
	local trisEach = json and json.tris and (json.tris / math.max(1, #json.pieces)) or 100
	for _, p in ipairs(pieces) do
		local mp = R.create("MeshPart")
		local st = states[mp]
		st.name = p.name
		st.props.Size = Vector3.new(p.size[1], p.size[2], p.size[3])
		st.props.CFrame = CFrame.new(p.offset[1], p.offset[2], p.offset[3])
		st.props.MeshId = "rbxassetid://" .. tostring(id)
		st.props.Anchored = true
		local ref = p.fbx and string.format("%s/%s.fbx#%s", category, name, p.name) or nil
		st.attrs = { PreviewMeshRef = ref }
		if ref then
			R.meshTris[ref] = trisEach
		end
		R.setParent(mp, st, model)
	end
	return container
end

R.meshes = M
return M
