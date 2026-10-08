--[[
	GroundHeight.lua (client)
	Ground height for client drawings (telegraphs, weapon effects, rings under enemies) on
	maps with terraces, ramps, caves and bridges (docs/redesign/gameplay/DESIGN.md section
	3). The server's HeightGrid decides gameplay; this only places visuals on the ground.

	GroundHeight.At(x, z) casts one ray down onto parts tagged NavGround / NavBlock (the same
	tags as HeightGrid) and caches the answer per 2-stud cell. With no NavGround part in the
	workspace (every arena built before the redesign) it returns Config.ArenaOrigin.Y at once,
	so the flat arenas draw exactly as before. A miss (a part not streamed in yet) returns the
	flat floor and is retried after a second.
]]

local CollectionService = game:GetService("CollectionService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Config = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Config"))
local RunConfig = require(ReplicatedStorage:WaitForChild("SwarmV2"):WaitForChild("Run"):WaitForChild("RunConfig"))

local Nav = RunConfig.Nav
local GROUND_TAG: string = Nav.GroundTag
local BLOCK_TAG: string = Nav.BlockTag
local FLOOR: number = Config.ArenaOrigin.Y
local CELL = 2
local OFFSET = 32768
local TOP = 1500 -- rays start this far above the flat floor ...
local DEPTH = 3000 -- ... and reach this far down
local MAX_CACHE = 30000
local MISS_RETRY = 1

local GroundHeight = {}

local dirty = true
local active = false
local params: RaycastParams? = nil
local cache: { [number]: number } = {}
local cached = 0
local misses: { [number]: number } = {} -- key -> os.clock() of the next retry

local nextRefresh = 0

-- Re-reads the tagged parts (at most once a second: streaming adds and removes them all
-- the time). Known heights stay cached; misses are retried with the new list.
local function refresh()
	local now = os.clock()
	if now < nextRefresh and params ~= nil then
		return
	end
	nextRefresh = now + 1
	dirty = false
	table.clear(misses)
	local include: { Instance } = {}
	local grounds = 0
	for _, tag in ipairs({ GROUND_TAG, BLOCK_TAG }) do
		for _, inst in ipairs(CollectionService:GetTagged(tag)) do
			if inst:IsDescendantOf(workspace) then
				table.insert(include, inst)
				if tag == GROUND_TAG then
					grounds += 1
				end
			end
		end
	end
	if (grounds > 0) ~= active then
		table.clear(cache) -- a map came or went
		cached = 0
	end
	active = grounds > 0
	if active then
		local p = RaycastParams.new()
		p.FilterType = Enum.RaycastFilterType.Include
		p.FilterDescendantsInstances = include
		params = p
	else
		params = nil
	end
end

-- True when the workspace has tagged ground (a map with height).
function GroundHeight.Active(): boolean
	if dirty then
		refresh()
	end
	return active
end

-- Ground top at (x, z): the flat floor when there is no tagged ground.
function GroundHeight.At(x: number, z: number): number
	if dirty then
		refresh()
	end
	local rp = params
	if not active or not rp then
		return FLOOR
	end
	local cx, cz = math.floor(x / CELL), math.floor(z / CELL)
	local key = (cx + OFFSET) * 65536 + (cz + OFFSET)
	local y = cache[key]
	if y then
		return y
	end
	local retry = misses[key]
	if retry and os.clock() < retry then
		return FLOOR
	end
	local hit = workspace:Raycast(Vector3.new((cx + 0.5) * CELL, FLOOR + TOP, (cz + 0.5) * CELL), Vector3.new(0, -DEPTH, 0), rp)
	if not hit then
		misses[key] = os.clock() + MISS_RETRY
		return FLOOR
	end
	misses[key] = nil
	if cached >= MAX_CACHE then
		table.clear(cache)
		cached = 0
	end
	cache[key] = hit.Position.Y
	cached += 1
	return hit.Position.Y
end

local function markDirty()
	dirty = true
end

for _, tag in ipairs({ GROUND_TAG, BLOCK_TAG }) do
	CollectionService:GetInstanceAddedSignal(tag):Connect(markDirty)
	CollectionService:GetInstanceRemovedSignal(tag):Connect(markDirty)
end

return GroundHeight
