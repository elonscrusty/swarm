--[[
	InviteRewards.lua (Config.Features.InviteRewards; docs/next/INVITE_REWARDS.md)
	Invite friends; cosmetic rewards only.

	  Invite     the client opens Roblox's invite prompt (SocialService:PromptGameInvite after
	             CanSendGameInviteAsync; client InviteUI) from the PARTY screen and the
	             MORE screen's INVITE FRIENDS row. Nothing on the server.
	  Referral   only Player:GetJoinData().ReferredByPlayerId (set by Roblox for a join from
	             an invite). TeleportData / LaunchData are never trusted for rewards. It is
	             read once, on the first load of a brand-new save (save Invite.New, set by
	             DataService when there was no earlier save) and then never again
	             (Invite.Checked).
	  New player the referred player gets the "Friend Badge" nameplate (Config.Invite.Badge)
	             at once.
	  Inviter    credited once the referred player has finished Config.Invite.RunsNeeded clean
	             runs (RunManager calls OnRunCommitted after its DEV-taint return; a
	             DEV-boosted profile never sends a credit). One credit per new player:
	               * the inviter is in this server: credited straight into their save;
	               * otherwise a pending record (the referred user id) is added under the
	                 inviter's key in the Config.Invite.StoreName DataStore; the inviter's
	                 own server processes it on join and every Config.Invite.PollSeconds.
	             The referred save remembers it was sent (Invite.Sent); the inviter's save
	             keeps the credited ids (Invite.Credited, capped at MaxCredits), so a record
	             read twice (or a retry) never credits twice. Records are removed only after
	             the inviter's save with the credit was written.
	             Rewards: the "Recruiter" title on the first credit, Stats.Recruits counts
	             them, and the "Recruiter Trail" at Config.Invite.TrailAt credits.
	Player attribute "Recruits" (credited friends) for the lobby.
	Offline (preview) there are no real invites or referrals: tests swap _JoinData and the
	pending store is in memory when DataStores are unavailable.
]]

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local DataStoreService = game:GetService("DataStoreService")

local Shared = game:GetService("ReplicatedStorage").Shared
local Config = require(Shared.Config)
local MetaData = require(Shared.MetaData)

local InviteRewards = {}

local ctx
local GOOD = Color3.fromRGB(140, 230, 200)
local store: DataStore? = nil
local memory: { [string]: any } = {} -- pending records when DataStores are unavailable (Studio / preview)
local busy: { [Player]: boolean } = {}

local function cfg(): { [string]: any }
	return (Config :: any).Invite or {}
end

function InviteRewards.On(): boolean
	return Config.FeatureOn("InviteRewards")
end

-- Roblox's join data (tests replace it: the preview has no referrals).
InviteRewards._JoinData = function(player: Player): any
	return player:GetJoinData()
end

local function whole(x: any): number
	local n = tonumber(x)
	if not n or n ~= n or n == math.huge or n == -math.huge then
		return 0
	end
	return math.max(0, math.floor(n))
end

-- The save's Invite table, cleaned (always returns one).
local function invite(data: { [string]: any }): { [string]: any }
	local inv = data.Invite
	if type(inv) ~= "table" then
		inv = { New = false, ReferredBy = 0, Sent = false, Credited = {} }
		data.Invite = inv
	end
	inv.New = inv.New == true
	inv.Checked = inv.Checked == true
	inv.Sent = inv.Sent == true
	inv.ReferredBy = whole(inv.ReferredBy)
	inv.Runs = whole(inv.Runs)
	if type(inv.Credited) ~= "table" then
		inv.Credited = {}
	end
	return inv
end
InviteRewards._Invite = invite

local function count(t: { [any]: any }): number
	local n = 0
	for _ in pairs(t) do
		n += 1
	end
	return n
end

local function grantLook(data: { [string]: any }, kind: string, id: string): boolean
	local holder
	if kind == "Title" then
		if type(data.Titles) ~= "table" then
			data.Titles = { Owned = {} }
		end
		holder = data.Titles
	else
		if type(data.Cosmetics) ~= "table" then
			data.Cosmetics = { Owned = {}, Equipped = {} }
		end
		holder = data.Cosmetics
	end
	if type(holder.Owned) ~= "table" then
		holder.Owned = {}
	end
	if holder.Owned[id] == true then
		return false
	end
	holder.Owned[id] = true
	if kind == "Title" and (data.Title == nil or data.Title == "") then
		local def = MetaData.TitleById[id]
		data.Title = def and def.Name or (string.gsub(id, "^Title_", ""))
	end
	return true
end

local function notify(player: Player, text: string, id: string)
	if ctx.RunManager and player.Parent then
		ctx.RunManager.Notify(player, text, GOOD, { Id = id })
	end
end

local function publish(player: Player, data: { [string]: any }?)
	if not player.Parent then
		return
	end
	local n = data and InviteRewards.On() and whole(type(data.Stats) == "table" and data.Stats.Recruits) or 0
	if player:GetAttribute("Recruits") ~= n then
		player:SetAttribute("Recruits", n)
	end
end

local function sync(player: Player)
	if player.Parent and ctx.GoldSystem then
		ctx.GoldSystem.SyncProfile(player)
	end
	if ctx.StoreService and ctx.StoreService.Apply then
		pcall(ctx.StoreService.Apply, player)
	end
end

------------------------------------------------------------------------------------------
-- Pending store (keyed by the inviter)
------------------------------------------------------------------------------------------

local function key(inviterId: number): string
	return "Inviter_" .. inviterId
end

-- transform(old list) → new list; returns ok, the stored list.
local function updatePending(inviterId: number, transform: ({ number }) -> { number }): (boolean, { number })
	local k = key(inviterId)
	local function clean(v: any): { number }
		local out = {}
		if type(v) == "table" then
			for _, id in ipairs(v) do
				local n = whole(id)
				if n > 0 and not table.find(out, n) and #out < 200 then
					table.insert(out, n)
				end
			end
		end
		return out
	end
	if not store then
		memory[k] = transform(clean(memory[k]))
		return true, memory[k]
	end
	local s = store :: DataStore
	local ok, result = pcall(function()
		return s:UpdateAsync(k, function(old)
			return transform(clean(old))
		end)
	end)
	if ok then
		return true, clean(result)
	end
	warn("[InviteRewards] pending store failed: " .. tostring(result))
	return false, {}
end

local function readPending(inviterId: number): { number }?
	local k = key(inviterId)
	if not store then
		return memory[k] and table.clone(memory[k]) or {}
	end
	local s = store :: DataStore
	local ok, result = pcall(function()
		return s:GetAsync(k)
	end)
	if not ok then
		return nil
	end
	local out = {}
	if type(result) == "table" then
		for _, id in ipairs(result) do
			local n = whole(id)
			if n > 0 then
				table.insert(out, n)
			end
		end
	end
	return out
end
InviteRewards._ReadPending = readPending

------------------------------------------------------------------------------------------
-- Crediting the inviter
------------------------------------------------------------------------------------------

--[[
	Credits `referredId` to the inviter's save once. Returns true when it is credited now,
	false when it already was (or the set is full / the profile is missing).
]]
function InviteRewards.Credit(inviter: Player, referredId: number): boolean
	local data = ctx.DataService.GetData(inviter)
	referredId = whole(referredId)
	if not data or referredId <= 0 or referredId == inviter.UserId then
		return false
	end
	local inv = invite(data)
	local idKey = tostring(referredId)
	if inv.Credited[idKey] then
		return false
	end
	if count(inv.Credited) >= math.max(1, whole(cfg().MaxCredits)) then
		return false
	end
	inv.Credited[idKey] = true
	if type(data.Stats) ~= "table" then
		data.Stats = {}
	end
	local n = count(inv.Credited)
	data.Stats.Recruits = n
	-- cosmetics only; a DEV-boosted profile keeps the count but earns no looks (as the
	-- store's earned looks)
	if data.DevBoosted ~= true then
		local c = cfg()
		local got = {}
		if grantLook(data, "Title", type(c.Title) == "string" and c.Title or "Title_Recruiter") then
			table.insert(got, "the Recruiter title")
		end
		if n >= math.max(1, whole(c.TrailAt)) and grantLook(data, "Trail", type(c.Trail) == "string" and c.Trail or "Trail_Recruiter") then
			table.insert(got, "the Recruiter Trail")
		end
		local text = "A friend you invited finished a run!"
		if #got > 0 then
			text ..= " You earned " .. table.concat(got, " and ") .. "."
		end
		notify(inviter, text, "invite.credit")
	end
	publish(inviter, data)
	task.defer(sync, inviter)
	return true
end

-- Reads this inviter's pending records, credits each once, saves, then removes them.
function InviteRewards.ProcessPending(inviter: Player)
	if not InviteRewards.On() or busy[inviter] or not ctx.DataService.GetData(inviter) then
		return
	end
	busy[inviter] = true
	local list = readPending(inviter.UserId)
	if list and #list > 0 then
		for _, id in ipairs(list) do
			InviteRewards.Credit(inviter, id)
		end
		-- remove only what this save now holds (and only once it is written)
		local saved = ctx.DataService.ForceSave(inviter)
		local data = ctx.DataService.GetData(inviter)
		if saved and data then
			local credited = invite(data).Credited
			updatePending(inviter.UserId, function(old)
				local keep = {}
				for _, id in ipairs(old) do
					if not credited[tostring(id)] then
						table.insert(keep, id)
					end
				end
				return keep
			end)
		end
	end
	busy[inviter] = nil
end

------------------------------------------------------------------------------------------
-- The referred player
------------------------------------------------------------------------------------------

-- First load of a brand-new save: read the referral once.
local function checkReferral(player: Player, data: { [string]: any })
	local inv = invite(data)
	if not inv.New or inv.Checked then
		return
	end
	inv.Checked = true
	local ok, jd = pcall(InviteRewards._JoinData, player)
	local ref = ok and type(jd) == "table" and whole(jd.ReferredByPlayerId) or 0
	if ref <= 0 or ref == player.UserId then
		return
	end
	inv.ReferredBy = ref
	local badge = type(cfg().Badge) == "string" and cfg().Badge or "Plate_Friend"
	if grantLook(data, "Nameplate", badge) then
		notify(player, "A friend invited you! Friend Badge nameplate unlocked (wear it in the Store).", "invite.badge")
		task.defer(sync, player)
	end
end

-- Sends the inviter's credit once the referred player qualifies. Returns true when sent.
local function trySend(player: Player, data: { [string]: any }): boolean
	local inv = invite(data)
	if not inv.New or inv.Sent or inv.ReferredBy <= 0 or data.DevBoosted == true then
		return false
	end
	if inv.Runs < math.max(1, whole(cfg().RunsNeeded)) then
		return false
	end
	local inviter = Players:GetPlayerByUserId(inv.ReferredBy)
	local me = player.UserId
	if inviter and ctx.DataService.GetData(inviter) then
		-- the inviter is here: credit now; only a written inviter save counts as sent (else
		-- the pending record below is the fallback; their Credited set stops a second credit)
		InviteRewards.Credit(inviter, me)
		if ctx.DataService.ForceSave(inviter) then
			inv.Sent = true
			return true
		end
	end
	local ok = updatePending(inv.ReferredBy, function(old)
		if not table.find(old, me) then
			table.insert(old, me)
		end
		return old
	end)
	if ok then
		inv.Sent = true
	end
	return ok
end

-- RunManager (saveRunStats, after the DEV-taint return): a clean run was finished.
function InviteRewards.OnRunCommitted(player: Player, data: { [string]: any }?)
	if not InviteRewards.On() or not data then
		return
	end
	local inv = invite(data)
	if not inv.New or inv.ReferredBy <= 0 or inv.Sent then
		return
	end
	inv.Runs += 1
	-- the pending store yields: never inside the run's commit
	task.spawn(trySend, player, data)
end

------------------------------------------------------------------------------------------
-- Lifecycle
------------------------------------------------------------------------------------------

function InviteRewards.Init(c)
	ctx = c
	local ok, result = pcall(function()
		local name = cfg().StoreName or "SwarmInvites"
		if RunService:IsStudio() then
			name ..= "_Studio"
		end
		return DataStoreService:GetDataStore(name)
	end)
	store = ok and result or nil
	if store and RunService:IsStudio() then
		-- Studio without API access: keep the records in memory
		local probe = pcall(function()
			return (store :: DataStore):GetAsync("__probe")
		end)
		if not probe then
			store = nil
		end
	end
end
-- tests: force the in-memory pending store
function InviteRewards._UseMemory()
	store = nil
end

local function onLoaded(player: Player)
	local data = ctx.DataService.GetData(player)
	if not data or not InviteRewards.On() then
		return
	end
	checkReferral(player, data)
	publish(player, data)
	-- a credit that could not be sent before (store down) is retried
	trySend(player, data)
	InviteRewards.ProcessPending(player)
end

InviteRewards._OnLoaded = onLoaded -- (tests: invite-regression)
-- tests: add a pending record as another server would
function InviteRewards._AddPending(inviterId: number, referredId: number): boolean
	return (updatePending(inviterId, function(old)
		if not table.find(old, referredId) then
			table.insert(old, referredId)
		end
		return old
	end))
end

function InviteRewards.Start()
	ctx.DataService.OnProfileLoaded(function(player)
		onLoaded(player)
	end)
	Players.PlayerRemoving:Connect(function(player)
		busy[player] = nil
	end)
	task.spawn(function()
		while true do
			task.wait(math.max(30, tonumber(cfg().PollSeconds) or 300))
			if InviteRewards.On() then
				for _, player in ipairs(Players:GetPlayers()) do
					local data = ctx.DataService.GetData(player)
					if data then
						pcall(trySend, player, data)
						pcall(InviteRewards.ProcessPending, player)
					end
				end
			end
		end
	end)
end

return InviteRewards
