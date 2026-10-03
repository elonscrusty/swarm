--[[
	MeshService.lua
	Loads the uploaded Blender mesh models (MeshCatalog AssetIds) with InsertService and
	keeps one template MeshPart per piece in ReplicatedStorage.SwarmMeshes/<Model>/<Piece>.
	Clients clone those templates for enemies / projectiles / crystals; the server clones
	them for characters, pickups, chests and map props.

	Models whose AssetId is 0 (not uploaded yet) or that fail to load are simply missing,
	and every caller falls back to its part-built model. Loading runs in the background,
	so the game starts instantly; ready models get the attribute Ready = true and the
	callers swap their fallbacks (MapBuilder props, character previews, lobby characters).

	Load order: a priority queue with at most MAX_CONCURRENT InsertService loads in flight
	(firing every LoadAsset at once made all of them finish late):
	  tier 1  what is on screen now: the lobby / castle kit, anything a builder had to
	          stand in with a fallback (MeshService.Prioritize), the player's own hero
	  tier 2  the heroes and hats (character select, showcase, skins)
	  tier 3  the selected arena's kit + the run's enemies, projectiles, pickups, fx
	  tier 4  everything else (the other biomes)
	SwarmMeshes attributes for the client: Loaded / Failed / Total (models), PriorityDone /
	PriorityTotal and PriorityReady (tiers 1-2 finished: the lobby's "Loading models" pill
	hides), AllReady.
]]

local InsertService = game:GetService("InsertService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local MeshCatalog = require(ReplicatedStorage.Shared.MeshCatalog)

local MeshService = {}

local MAX_CONCURRENT = 6
-- A failed InsertService load (throttled, timed out) is tried again after RETRY_DELAYS[n]
-- seconds; only after the last retry does the model count as failed (callers then keep
-- their part-built fallback for good). A model whose asset loaded but lacks pieces is not
-- retried: that is a catalog / upload mismatch, not a slow load.
local RETRY_DELAYS = { 3, 10 }
local PRIORITY_TIERS = 2 -- tiers counted for PriorityReady
-- default tier per catalog Category (lower loads first)
local CATEGORY_TIER = {
	Castle = 1,
	Heroes = 2,
	Hats = 2,
	Enemies = 3,
	Projectiles = 3,
	Pickups = 3,
	Fx = 3,
	Abilities = 3,
	Events = 3,
}
-- the biome kit of each arena (World holds the Forest / Ruins props)
local ARENA_CATEGORIES = {
	Forest = { "World" },
	Ruins = { "World" },
	Swamp = { "Swamp" },
	Snow = { "Snow" },
	Desert = { "Desert" },
	Lava = { "Lava" },
}

local root: Folder
local readyEvent = Instance.new("BindableEvent")
local pending = 0 -- models queued or loading
local started = false

type Job = { Name: string, Tier: number, Seq: number, State: string, Attempts: number } -- queued | loading | retry | done | failed
local jobs: { [string]: Job } = {}
local seq = 0
local active = 0
local startClock = 0
local loadedCount, failedCount, totalCount = 0, 0, 0
local lastError = "" -- the latest load failure, published for the DEV lobby note
local priorityReported = false

MeshService.Ready = readyEvent.Event -- fires (modelName) each time a model finishes

local MATERIALS = {
	SmoothPlastic = Enum.Material.SmoothPlastic,
	Neon = Enum.Material.Neon,
	Metal = Enum.Material.Metal,
	Glass = Enum.Material.Glass,
}

local function vec(t: { number }): Vector3
	return Vector3.new(t[1], t[2], t[3])
end

-- Import rotation recorded by loadModel (nil when the mesh came in upright, the normal case).
local function importRotation(template: Instance): CFrame?
	local r = template:GetAttribute("ImportRotation")
	if typeof(r) == "CFrame" then
		return r
	end
	return nil
end

-- Catalog sizes are in model (Roblox) axes; a rotated import needs them in its local axes.
local function localSize(size: Vector3, template: Instance): Vector3
	local r = importRotation(template)
	if not r then
		return size
	end
	local v = r:VectorToObjectSpace(size)
	return Vector3.new(math.abs(v.X), math.abs(v.Y), math.abs(v.Z))
end

-- Returns loaded, retryable (false + true: the asset request itself failed).
local function loadModel(name: string, entry): (boolean, boolean)
	local ok, asset = pcall(function()
		return InsertService:LoadAsset(entry.AssetId)
	end)
	if not ok or not asset then
		lastError = string.format("%s (%d): %s", name, entry.AssetId, tostring(asset))
		warn("[MeshService] could not load " .. lastError)
		return false, true
	end
	local folder = Instance.new("Folder")
	folder.Name = name
	-- index the imported MeshParts by name (ignoring any ".001" suffix); containers that
	-- share a piece's name (the importer wraps everything in a Model) are skipped
	local byName: { [string]: MeshPart } = {}
	for _, d in ipairs(asset:GetDescendants()) do
		if d:IsA("MeshPart") then
			local clean = string.gsub(d.Name, "%.%d+$", "")
			if not byName[clean] then
				byName[clean] = d
			end
		end
	end
	local found = 0
	for _, piece in ipairs(entry.Pieces) do
		local mesh = byName[piece.Name]
		if mesh then
			local template = mesh:Clone()
			for _, child in ipairs(template:GetChildren()) do
				child:Destroy() -- drop imported welds / attachments
			end
			template.Name = piece.Name
			template.Anchored = true
			template.CanCollide = false
			template.CanQuery = false
			template.CanTouch = false
			template.CastShadow = false
			-- (RenderFidelity is plugin-only: a script cannot set it, so the level of detail
			-- stays whatever the upload chose)
			-- The FBX nodes carry a Y-up axis rotation (Lcl Rotation 90, 0, 180) over Z-up
			-- vertex data. If the importer kept that rotation on the MeshPart instead of
			-- baking it, the geometry's local axes are not the catalog's (Roblox) axes and the
			-- piece would lie on its side. Remember the rotation so Build() can compensate.
			local rot = mesh.CFrame.Rotation
			if rot.UpVector.Y < 0.99 then
				template:SetAttribute("ImportRotation", rot)
				warn(string.format("[MeshService] %s.%s was imported rotated; compensating", name, piece.Name))
			end
			template.Size = localSize(vec(piece.Size), template)
			template.Material = MATERIALS[piece.Material] or Enum.Material.SmoothPlastic
			template.TextureID = ""
			template.Parent = folder
			found += 1
		else
			lastError = string.format("%s is missing piece %s", name, piece.Name)
			warn("[MeshService] " .. lastError)
		end
	end
	asset:Destroy()
	if found == #entry.Pieces then
		folder:SetAttribute("Ready", true)
		folder.Parent = root
		readyEvent:Fire(name)
		return true, false
	end
	folder:Destroy()
	return false, false
end

-- Template folder for a model, or nil when it isn't loaded.
function MeshService.Get(name: string): Folder?
	local f = root and root:FindFirstChild(name)
	if f and f:GetAttribute("Ready") then
		return f :: Folder
	end
	return nil
end

function MeshService.IsLoading(): boolean
	return pending > 0
end

-- True when model `name` can still finish loading (queued or in flight).
local function stillComing(name: string): boolean
	local job = jobs[name]
	return job ~= nil and (job.State == "queued" or job.State == "loading" or job.State == "retry")
end

-- True while model `name` is not loaded yet but still might be (uploaded, and loading has
-- not started or not finished). Callers use it to swap a fallback for the mesh later.
function MeshService.MayLoad(name: string): boolean
	if MeshService.Get(name) then
		return false
	end
	return stillComing(name)
end

--[[
	Builds an anchored Model of a mesh model at `cframe` (origin = ground centre).
	palette overrides slot colours; scale multiplies the whole model.
	Returns nil when the model isn't loaded.
]]
function MeshService.Build(name: string, cframe: CFrame, palette: { [string]: Color3 }?, scale: number?): Model?
	local folder = MeshService.Get(name)
	local entry = MeshCatalog.Models[name]
	if not folder or not entry then
		return nil
	end
	local s = scale or 1
	local model = Instance.new("Model")
	model.Name = name
	for _, piece in ipairs(entry.Pieces) do
		local template = folder:FindFirstChild(piece.Name) :: MeshPart?
		if template then
			local part = template:Clone()
			part.Size = localSize(vec(piece.Size), template) * s
			local color = (palette and palette[piece.Slot]) or (entry.Palette and entry.Palette[piece.Slot])
			if color then
				part.Color = color
			end
			part.Transparency = piece.Transparency or 0
			part.CastShadow = piece.Shadow == true
			-- piece centre in model space; an imported rotation (rare) keeps the mesh upright
			part.CFrame = cframe * CFrame.new(vec(piece.Offset) * s) * (importRotation(template) or CFrame.identity)
			part.Parent = model
		end
	end
	return model
end

--[[
	Calls fn when every listed model is loaded (or immediately when already loaded). A
	model that is not in the catalog, not uploaded (AssetId 0) or that failed to load will
	never be ready: fn is then never called and nothing stays connected (callers keep
	their part-built fallback).
]]
function MeshService.WhenReady(names: { string }, fn: () -> ())
	local function check(): boolean
		for _, n in ipairs(names) do
			if not MeshService.Get(n) then
				return false
			end
		end
		return true
	end
	local function possible(): boolean
		for _, n in ipairs(names) do
			if not MeshService.Get(n) and not stillComing(n) then
				return false
			end
		end
		return true
	end
	if check() then
		task.spawn(fn)
		return
	end
	if not possible() then
		return
	end
	local conn
	conn = readyEvent.Event:Connect(function()
		if check() then
			conn:Disconnect()
			fn()
		elseif not possible() then
			conn:Disconnect() -- one of them failed: the fallback stays
		end
	end)
end

------------------------------------------------------------------------------------------
-- Load queue
------------------------------------------------------------------------------------------

local function publish()
	if not root then
		return
	end
	root:SetAttribute("Loaded", loadedCount)
	root:SetAttribute("Failed", failedCount)
	root:SetAttribute("LastError", string.sub(lastError, 1, 160))
	root:SetAttribute("Total", totalCount)
	root:SetAttribute("AllReady", started and pending == 0)
	if not priorityReported and started then
		local prio, prioDone = 0, 0
		for _, job in pairs(jobs) do
			if job.Tier <= PRIORITY_TIERS then
				prio += 1
				if job.State == "done" or job.State == "failed" then
					prioDone += 1
				end
			end
		end
		root:SetAttribute("PriorityTotal", prio)
		root:SetAttribute("PriorityDone", prioDone)
		if prioDone < prio then
			return
		end
		priorityReported = true
		root:SetAttribute("PriorityReady", true)
		print(string.format("[MeshService] lobby + heroes ready in %.1f s (%d / %d models loaded)", os.clock() - startClock, loadedCount, totalCount))
	end
end

local pump: () -> ()

local function nextJob(): Job?
	local best: Job? = nil
	for _, job in pairs(jobs) do
		if job.State == "queued" and (not best or job.Tier < best.Tier or (job.Tier == best.Tier and job.Seq < best.Seq)) then
			best = job
		end
	end
	return best
end

local function run(job: Job)
	job.State = "loading"
	active += 1
	task.spawn(function()
		local ok, loaded, retryable = pcall(loadModel, job.Name, MeshCatalog.Models[job.Name])
		active -= 1
		job.Attempts = (job.Attempts or 0) + 1
		local delay = ok and not loaded and retryable and RETRY_DELAYS[job.Attempts]
		if delay then
			-- still coming (WhenReady callers keep waiting); back in the queue after the delay
			job.State = "retry"
			task.delay(delay, function()
				job.State = "queued"
				pump()
			end)
			pump()
			return
		end
		pending -= 1
		if ok and loaded then
			job.State = "done"
			loadedCount += 1
		else
			job.State = "failed"
			failedCount += 1
			if not ok then
				lastError = job.Name .. ": " .. tostring(loaded)
				warn("[MeshService] " .. lastError)
			end
		end
		publish()
		if pending == 0 then
			print(string.format("[MeshService] all models done in %.1f s (%d loaded, %d failed)", os.clock() - startClock, loadedCount, failedCount))
		end
		pump()
	end)
end

pump = function()
	if not started then
		return
	end
	while active < MAX_CONCURRENT do
		local job = nextJob()
		if not job then
			return
		end
		run(job)
	end
end

local function bump(name: string, tier: number)
	local job = jobs[name]
	if job and job.State == "queued" and tier < job.Tier then
		seq += 1
		job.Tier = tier
		job.Seq = seq
	end
end

--[[
	Moves models up the load queue (tier 1 = load next; default 1). Used for whatever is on
	screen with a fallback right now (MapBuilder props, the player's hero). Loaded or loading
	models are left alone.
]]
function MeshService.Prioritize(names: { string }, tier: number?)
	for _, name in ipairs(names) do
		bump(name, tier or 1)
	end
end

-- The kit of arena `arenaName` (the lobby's selected arena, the next stage) to tier 3.
function MeshService.PrioritizeArena(arenaName: string, tier: number?)
	local cats = ARENA_CATEGORIES[arenaName]
	if not cats then
		return
	end
	for name, entry in pairs(MeshCatalog.Models) do
		if table.find(cats, (entry :: any).Category) then
			bump(name, tier or 3)
		end
	end
end

-- { Loaded, Failed, Total, Pending, PriorityReady } for logs / the dev panel.
function MeshService.Progress()
	return { Loaded = loadedCount, Failed = failedCount, Total = totalCount, Pending = pending, PriorityReady = priorityReported }
end

function MeshService.Init(_ctx)
	root = Instance.new("Folder")
	root.Name = "SwarmMeshes"
	root.Parent = ReplicatedStorage
	-- every uploaded model gets a queue slot now, so builders that run before Start (the
	-- lobby is built in RunManager.Init) can already move their models to the front
	for name, entry in pairs(MeshCatalog.Models) do
		if entry.AssetId and entry.AssetId ~= 0 then
			seq += 1
			jobs[name] = { Name = name, Tier = CATEGORY_TIER[(entry :: any).Category] or 4, Seq = seq, State = "queued", Attempts = 0 }
			totalCount += 1
		end
	end
	MeshService.PrioritizeArena("Forest")
	root:SetAttribute("Total", totalCount)
end

function MeshService.Start()
	started = true
	startClock = os.clock()
	pending = totalCount
	-- the lobby's selected arena (stage 1) follows the heroes
	local state = ReplicatedStorage:FindFirstChild("SwarmState")
	if state then
		local arena = state:GetAttribute("SelectedArena")
		if type(arena) == "string" then
			MeshService.PrioritizeArena(arena)
		end
		state:GetAttributeChangedSignal("SelectedArena"):Connect(function()
			local a = state:GetAttribute("SelectedArena")
			if type(a) == "string" then
				MeshService.PrioritizeArena(a)
			end
		end)
	end
	publish()
	pump()
end

return MeshService
