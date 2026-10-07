--[[
	ComebackGift.lua
	The welcome-back gift (Config.Features.ComebackGift, Config.Comeback;
	docs/next/COMEBACK_GIFT.md). With the switch off nothing here runs: no save field is
	written and the remote does nothing.

	  LastSeen   data.LastSeen (os.time) is refreshed every SeenEvery seconds while the
	             player is on this server and when they leave, so a save always holds
	             roughly when the player was last here.
	  Offer      when a profile loads: away = now - LastSeen (read BEFORE it is refreshed).
	             AwayDays+ days away, the account has MinRuns finished runs (never a brand-new
	             account; a profile without LastSeen never gets one), no gift is waiting and
	             the last one was offered at least CooldownHours ago: the gift is decided here
	             and kept in the save (Comeback.Pending = { Days, Gold, Look? }, LastGift = now).
	             3-6 days: Gold; LongDays+ days: LongGold and the LongCosmetic look.
	  Claim      remote "Comeback" ("Claim"), lobby only: Pending is cleared first, then the
	             gold (and the look; an owned look pays CosmeticOwnedGold instead) is paid, the
	             save is written. Exactly once.
	The lobby shows a waiting gift as its own WELCOME BACK card (MenuComeback), before the
	login streak's DAILY REWARD card, which stays separate.

	Save (additive, no schema bump): data.LastSeen = os.time, data.Comeback = { LastGift =
	os.time, Pending = { Days, Gold, Look } | nil }.
]]

local Players = game:GetService("Players")
local Shared = game:GetService("ReplicatedStorage").Shared
local Config = require(Shared.Config)
local Remotes = require(Shared.Remotes)
local CosmeticData = require(Shared.CosmeticData)

local ComebackGift = {}

local ctx
local seenTimer = 0
local clock: () -> number = os.time

local GOOD = Color3.fromRGB(255, 220, 120)

local function on(): boolean
	return Config.FeatureOn("ComebackGift")
end

local function K()
	return Config.Comeback
end

function ComebackGift._SetClock(fn: (() -> number)?)
	clock = fn or os.time
end

local function whole(v: any): number
	local n = tonumber(v)
	if not n or n ~= n or n == math.huge or n == -math.huge then
		return 0
	end
	return math.max(0, math.floor(n))
end

local function store(data): { [string]: any }
	local c = data.Comeback
	if type(c) ~= "table" then
		c = {}
		data.Comeback = c
	end
	c.LastGift = whole(c.LastGift)
	local p = c.Pending
	if type(p) == "table" then
		local look = type(p.Look) == "string" and CosmeticData.Get(p.Look) ~= nil and p.Look or nil
		c.Pending = { Days = whole(p.Days), Gold = math.min(whole(p.Gold), math.max(K().Gold, K().LongGold)), Look = look }
	else
		c.Pending = nil
	end
	return c
end

-- The gift for `days` away: { Days, Gold, Look? }.
function ComebackGift.GiftFor(days: number): { [string]: any }
	local long = days >= K().LongDays
	return {
		Days = days,
		Gold = long and K().LongGold or K().Gold,
		Look = long and K().LongCosmetic or nil,
	}
end

--[[
	Decides an offer for a loaded profile and then refreshes LastSeen. Returns the new
	Pending gift, or nil. (Exposed for the regression.)
]]
function ComebackGift.Evaluate(data): { [string]: any }?
	if not on() then
		return nil
	end
	local now = clock()
	local last = whole(data.LastSeen)
	data.LastSeen = now
	local c = store(data)
	if last <= 0 or c.Pending ~= nil then
		return nil
	end
	local runs = type(data.Stats) == "table" and whole(data.Stats.Runs) or 0
	if runs < (K().MinRuns or 1) then
		return nil
	end
	local days = math.floor((now - last) / 86400)
	if days < K().AwayDays then
		return nil
	end
	if c.LastGift > 0 and now - c.LastGift < K().CooldownHours * 3600 then
		return nil
	end
	c.LastGift = now
	c.Pending = ComebackGift.GiftFor(days)
	return c.Pending
end

local function grantLook(data, id: string): boolean
	local e = CosmeticData.Get(id)
	if not e or e.Source ~= "Earned" then
		return false
	end
	if type(data.Cosmetics) ~= "table" then
		data.Cosmetics = {}
	end
	if type(data.Cosmetics.Owned) ~= "table" then
		data.Cosmetics.Owned = {}
	end
	local owned = data.Cosmetics.Owned
	if owned[id] == true then
		return false
	end
	local n = 0
	for _ in pairs(owned) do
		n += 1
	end
	if n >= Config.Data.Caps.SetEntries then
		return false
	end
	owned[id] = true
	return true
end

-- Pays the waiting gift once. Returns the toast line, or nil when nothing was waiting.
function ComebackGift.Claim(player: Player, data): string?
	if not on() then
		return nil
	end
	local c = store(data)
	local gift = c.Pending
	if not gift then
		return nil
	end
	c.Pending = nil -- first: nothing below can pay twice
	local gold = whole(gift.Gold)
	local parts = {}
	if gift.Look then
		if grantLook(data, gift.Look) then
			local e = CosmeticData.Get(gift.Look)
			table.insert(parts, "New look: " .. (e and e.Name or gift.Look))
		else
			gold += whole(K().CosmeticOwnedGold)
		end
	end
	data.Gold += gold
	table.insert(parts, 1, "+" .. gold .. " gold")
	local line = "Welcome back! " .. table.concat(parts, ", ")
	if ctx.RunManager and player.Parent then
		ctx.RunManager.Notify(player, line, GOOD, { Id = "comeback.claim" })
	end
	if ctx.DataService.ForceSave then
		task.spawn(function()
			pcall(ctx.DataService.ForceSave, player)
		end)
	end
	if player.Parent and ctx.GoldSystem then
		ctx.GoldSystem.SyncProfile(player)
	end
	return line
end

local function onComeback(player: Player, action: any)
	if not on() or action ~= "Claim" then
		return
	end
	local data = ctx.DataService.GetData(player)
	if not data or ctx.RunManager.IsParticipant(player) then
		return
	end
	ComebackGift.Claim(player, data)
end

local function touch(player: Player)
	local data = ctx.DataService.GetData(player)
	if data then
		data.LastSeen = clock()
	end
end

function ComebackGift.Step(dt: number)
	if not on() then
		return
	end
	seenTimer += dt
	if seenTimer < (K().SeenEvery or 60) then
		return
	end
	seenTimer = 0
	for _, player in ipairs(Players:GetPlayers()) do
		touch(player)
	end
end

function ComebackGift.Init(c)
	ctx = c
end

function ComebackGift.Start()
	Remotes.Listen("Comeback", onComeback, Config.Comeback.Rate or 2)
	ctx.DataService.OnProfileLoaded(function(player)
		local data = ctx.DataService.GetData(player)
		if data and on() then
			if ComebackGift.Evaluate(data) and player.Parent and ctx.GoldSystem then
				ctx.GoldSystem.SyncProfile(player)
			end
		end
	end)
	Players.PlayerRemoving:Connect(function(player)
		if on() then
			touch(player)
		end
	end)
end

return ComebackGift
