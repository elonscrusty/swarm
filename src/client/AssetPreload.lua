--[[
	AssetPreload.lua
	Warms the image cache so uploaded pictures appear together with the UI they sit in
	(level-up card icons used to pop in a moment after the cards).

	AssetPreload.Start()               background preload of the compact, frequently used
	                                   set: the home-screen art (ArtImage.PreloadList), then
	                                   the upgrade / item pictures from IconData.
	                                   Never blocks; gives up waiting after a timeout.
	AssetPreload.Stage(ids, maxWait)   preloads `ids` (skipping ones already done) and waits
	                                   at most `maxWait` seconds; true when all are ready.
	AssetPreload.Ready(id) / Failed(id) what is known about one content id.

	Every id is requested at most once (failed ones are not retried in a loop), so opening
	the same card twice never loads again.
]]

local ContentProvider = game:GetService("ContentProvider")
local Shared = game:GetService("ReplicatedStorage"):WaitForChild("Shared")
local IconData = require(Shared:WaitForChild("IconData"))

local AssetPreload = {}

-- content id → "pending" | "ready" | "failed"
local status: { [string]: string } = {}

local function request(ids: { string })
	local batch = {}
	for _, id in ipairs(ids) do
		if type(id) == "string" and id ~= "" and status[id] == nil then
			status[id] = "pending"
			table.insert(batch, id)
		end
	end
	if #batch == 0 then
		return
	end
	task.spawn(function()
		local ok, err = pcall(function()
			ContentProvider:PreloadAsync(batch, function(contentId: string, fetch: Enum.AssetFetchStatus)
				if fetch == Enum.AssetFetchStatus.Success then
					status[contentId] = "ready"
				elseif fetch == Enum.AssetFetchStatus.Failure or fetch == Enum.AssetFetchStatus.TimedOut then
					status[contentId] = "failed"
				end
			end)
		end)
		-- PreloadAsync has returned: whatever it did not report is as loaded as it gets
		for _, id in ipairs(batch) do
			if status[id] == "pending" then
				status[id] = ok and "ready" or "failed"
			end
		end
		if not ok then
			warn("[AssetPreload] " .. tostring(err))
		end
	end)
end

local function allSettled(ids: { string }): boolean
	for _, id in ipairs(ids) do
		if status[id] == "pending" then
			return false
		end
	end
	return true
end

-- The compact startup set: the home-screen / loading art first (ArtImage.PreloadList:
-- loading picture, logo, menu buttons, portraits, frames, arenas, bosses, results
-- backdrops), then every picture in IconData (weapons, evolutions, passives, bonus cards,
-- run items). Uses Icons.PreloadList when that module offers one.
local iconList: () -> { string }
local function startupList(): { string }
	local ok, ArtImage = pcall(require, script.Parent:WaitForChild("ArtImage", 5))
	local art = {}
	if ok and type(ArtImage) == "table" then
		local got, list = pcall((ArtImage :: any).PreloadList)
		if got and type(list) == "table" then
			art = list
		end
	end
	local rest = iconList()
	for _, id in ipairs(rest) do
		if not table.find(art, id) then
			table.insert(art, id)
		end
	end
	return art
end

iconList = function(): { string }
	local ok, Icons = pcall(require, script.Parent:WaitForChild("Icons", 5))
	if ok and type(Icons) == "table" and type((Icons :: any).PreloadList) == "function" then
		local got, list = pcall((Icons :: any).PreloadList)
		if got and type(list) == "table" then
			return list
		end
	end
	local list = {}
	for id in pairs(IconData.Icons) do
		local image = IconData.Image(id)
		if image then
			table.insert(list, image)
		end
	end
	table.sort(list)
	return list
end

local started = false
function AssetPreload.Start()
	if started then
		return
	end
	started = true
	task.spawn(function()
		request(startupList())
	end)
end

function AssetPreload.Ready(id: string?): boolean
	return id ~= nil and status[id] == "ready"
end

function AssetPreload.Failed(id: string?): boolean
	return id ~= nil and status[id] == "failed"
end

-- Preloads `ids` and yields until they are settled or `maxWait` seconds have passed.
function AssetPreload.Stage(ids: { string }, maxWait: number): boolean
	request(ids)
	local deadline = os.clock() + maxWait
	while not allSettled(ids) and os.clock() < deadline do
		task.wait()
	end
	for _, id in ipairs(ids) do
		if status[id] ~= "ready" then
			return false
		end
	end
	return true
end

return AssetPreload
