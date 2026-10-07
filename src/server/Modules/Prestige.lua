--[[
	Prestige.lua (Config.Features.Prestige, Config.Prestige, shared PrestigeData;
	docs/next/PRESTIGE.md)

	Remote "Prestige" (heroId, starsSeen), sent by the Characters screen only after its
	confirmation screen and a second tap on PRESTIGE <HERO>. Checked here, in this order:
	the switch, the lobby (not in a run), a known and owned hero, the per-player cooldown
	(Config.Prestige.CooldownSeconds, on top of the remote's rate limit), the stars the
	client saw (a repeated request after the first was applied carries the old count and is
	ignored: exactly once), fewer than MaxStars, and the whole mastery track maxed
	(PrestigeData.IsMaxed). Then, in one synchronous block (no yield, so one save update):
	that hero's own upgrade levels (MetaUpgradeData.HeroOrder) are cleared and its star
	count goes up by one. Gold, mastery XP, unlocks, skins, cosmetics and other heroes are
	not touched. There is no Robux path.

	Settlement (GoldSystem.SettleRun): Settle(rp, base, data) pays the hero's star bonus
	(PrestigeData.BonusFor: +GoldPerStar per star, GoldCap at most) of the gold the run put
	into the lobby (kept + survival), once per run, never for a DEV-tainted run or a
	DevBoosted profile. In-run gold, chest and shrine prices never change.

	Save: data.Prestige = { [heroId] = stars } (additive, no schema bump; cleaned on load).
]]

local Shared = game:GetService("ReplicatedStorage").Shared
local Config = require(Shared.Config)
local Remotes = require(Shared.Remotes)
local CharacterData = require(Shared.CharacterData)
local MetaUpgradeData = require(Shared.MetaUpgradeData)
local PrestigeData = require(Shared.PrestigeData)

local Prestige = {}

local ctx
local lastAt: { [Player]: number } = {}
local clock: () -> number = os.clock

local GOOD = Color3.fromRGB(255, 220, 120)
local BAD = Color3.fromRGB(255, 120, 120)

local function on(): boolean
	return Config.FeatureOn("Prestige")
end

local function K(): { [string]: any }
	return (Config :: any).Prestige or {}
end

-- Tests swap the clock (cooldown).
function Prestige._SetClock(fn: (() -> number)?)
	clock = fn or os.clock
end

-- The save's Prestige table, cleaned in place.
function Prestige.Ensure(data: { [string]: any }): { [string]: number }
	local t = PrestigeData.Clean(data.Prestige)
	data.Prestige = t
	return t
end

function Prestige.StarsOf(data: { [string]: any }?, heroId: string?): number
	if not data then
		return 0
	end
	return PrestigeData.Stars(data.Prestige, heroId)
end

local function notify(player: Player, text: string, color: Color3, id: string)
	if ctx and ctx.RunManager and player.Parent then
		ctx.RunManager.Notify(player, text, color, { Id = id })
	end
end

local function sync(player: Player)
	if ctx and ctx.GoldSystem and player.Parent then
		ctx.GoldSystem.SyncProfile(player)
	end
end

--[[
	The prestige itself. Returns true when applied, false (and the reason) when refused.
	Exposed for the regression (the remote calls it too).
]]
function Prestige.Request(player: Player, heroId: any, starsSeen: any): (boolean, string)
	if not on() then
		return false, "off"
	end
	local data = ctx.DataService.GetData(player)
	if not data then
		return false, "nodata"
	end
	if ctx.RunManager.IsParticipant(player) then
		return false, "inrun"
	end
	if type(heroId) ~= "string" or not CharacterData.Characters[heroId] then
		return false, "hero"
	end
	if type(data.OwnedCharacters) ~= "table" or data.OwnedCharacters[heroId] ~= true then
		return false, "notowned"
	end
	local now = clock()
	local last = lastAt[player]
	if last and now - last < (tonumber(K().CooldownSeconds) or 5) then
		return false, "cooldown"
	end
	local prestige = Prestige.Ensure(data)
	local stars = PrestigeData.Stars(prestige, heroId)
	if type(starsSeen) ~= "number" or starsSeen ~= stars then
		sync(player) -- a stale or repeated request: show the real state
		return false, "stale"
	end
	if stars >= PrestigeData.MaxStars() then
		return false, "max"
	end
	if type(data.HeroUpgrades) ~= "table" then
		data.HeroUpgrades = {}
	end
	local track = data.HeroUpgrades[heroId]
	if not PrestigeData.IsMaxed(heroId, track) then
		local name = CharacterData.Characters[heroId].Name
		notify(player, string.format("Max every %s upgrade first.", name), BAD, "prestige.notmaxed")
		sync(player)
		return false, "notmaxed"
	end
	-- one synchronous block: the reset and the star land in the same save update
	lastAt[player] = now
	for _, id in ipairs(MetaUpgradeData.HeroOrder()) do
		track[id] = nil
	end
	prestige[heroId] = stars + 1
	local name = CharacterData.Characters[heroId].Name
	notify(player, string.format("%s %s! %s gold from %s runs.", name, PrestigeData.StarText(stars + 1), PrestigeData.PercentText(stars + 1), name), GOOD, "prestige.done")
	if ctx.DataService.ForceSave then
		task.spawn(ctx.DataService.ForceSave, player)
	end
	sync(player)
	return true, "ok"
end

-- Settlement (GoldSystem.SettleRun): the star bonus on what this run paid into the lobby.
-- base = kept + survival gold. Once per run; never for DEV-tainted runs / boosted profiles.
function Prestige.Settle(rp, base: number, data: { [string]: any }?): number
	if not on() or not data or not rp or rp.DevTainted == true or data.DevBoosted == true then
		return 0
	end
	if rp.PrestigeBonusPaid ~= nil then
		return rp.PrestigeBonusPaid
	end
	local stars = PrestigeData.Stars(data.Prestige, rp.CharacterId)
	local bonus = PrestigeData.BonusFor(base, stars)
	rp.PrestigeBonusPaid = bonus
	if bonus > 0 then
		data.Gold += bonus
	end
	return bonus
end

function Prestige.Init(c)
	ctx = c
end

function Prestige.Start()
	Remotes.Listen("Prestige", function(player: Player, heroId: any, starsSeen: any)
		Prestige.Request(player, heroId, starsSeen)
	end, tonumber(K().Rate) or 2)
	ctx.DataService.OnProfileLoaded(function(player: Player)
		local data = ctx.DataService.GetData(player)
		if data and data.Prestige ~= nil then
			Prestige.Ensure(data)
		end
	end)
	game:GetService("Players").PlayerRemoving:Connect(function(player)
		lastAt[player] = nil
	end)
end

return Prestige
