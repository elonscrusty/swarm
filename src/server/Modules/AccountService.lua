--[[
	AccountService.lua
	The account level (AccountData.lua): a cosmetic track. RunManager calls AwardRun once
	per committed run (the same guard that writes the run stats, rp.Committed); the XP goes
	into data.Account.XP, the level is derived from it, and the rewards of every level
	passed unlock at once (the first title / colour / ring / frame earned is worn when
	nothing is worn yet). Nothing here touches a run's stats.

	Cosmetics are worn through the existing EquipCosmetic remote (AchievementService
	validates titles and colours from either source; rings and frames are checked here with
	CanWear). Player attributes for other clients: AccountLevel, Ring, Frame.
]]

local AccountData = require(game:GetService("ReplicatedStorage").Shared.AccountData)
local CharacterData = require(game:GetService("ReplicatedStorage").Shared.CharacterData)
local MetaUpgradeData = require(game:GetService("ReplicatedStorage").Shared.MetaUpgradeData)

local AccountService = {}

local ctx

local function account(data)
	if type(data.Account) ~= "table" then
		data.Account = { XP = 0, Level = 1 }
	end
	return data.Account
end

function AccountService.Level(data): number
	return (AccountData.LevelFor(account(data).XP or 0))
end

-- The profile view: total XP, level, XP into the level, XP the level needs.
function AccountService.View(data): { [string]: number }
	local a = account(data)
	local level, into, need = AccountData.LevelFor(a.XP or 0)
	return { XP = a.XP or 0, Level = level, Into = into, Need = need }
end

local function publish(player: Player, data)
	player:SetAttribute("AccountLevel", AccountService.Level(data))
	player:SetAttribute("Ring", data.Ring or "")
	player:SetAttribute("Frame", data.Frame or "")
end

-- True when the player may wear this track cosmetic (or "" = nothing).
function AccountService.CanWear(data, kind: string, id: string): boolean
	if id == "" then
		return true
	end
	return AccountData.Has(AccountService.Level(data), kind, id)
end

local WORN = { Title = "Title", Color = "NameColor", Ring = "Ring", Frame = "Frame" }

--[[
	Adds a run's XP. summary: AccountData.RunSummary. Returns the results-screen view:
	{ Gained, Parts, From, To, Into, Need, Rewards = { "Title: Recruit", ... } }.
]]
function AccountService.AwardRun(player: Player, summary: AccountData.RunSummary): { [string]: any }?
	local data = ctx.DataService.GetData(player)
	if not data then
		return nil
	end
	local a = account(data)
	local gained, parts = AccountData.RunXP(summary)
	local from = AccountData.LevelFor(a.XP or 0)
	a.XP = (a.XP or 0) + gained
	local to, into, need = AccountData.LevelFor(a.XP)
	a.Level = to
	local rewards = {}
	for _, r in ipairs(AccountData.RewardsBetween(from, to)) do
		table.insert(rewards, AccountData.RewardName(r))
		local key = WORN[r.Kind]
		if key and (data[key] == nil or data[key] == "") then
			data[key] = r.Id -- the first one earned is worn at once
		end
	end
	if player.Parent then
		publish(player, data)
	end
	return { Gained = gained, Parts = parts, From = from, To = to, Into = into, Need = need, Rewards = rewards }
end

--[[
	Hero Mastery (MetaUpgradeData, Config.HeroMastery): a committed run's XP (the same
	amount AwardRun gave the account) goes to the hero played, and its run count goes up.
	RunManager calls this after the DEV-taint return, so DEV runs never give mastery.
	Returns the results line { Hero, Gained, From, To } or nil.
]]
function AccountService.AwardMastery(player: Player, heroId: string, gained: number): { [string]: any }?
	local data = ctx.DataService.GetData(player)
	if not data or type(heroId) ~= "string" or not CharacterData.Characters[heroId] then
		return nil
	end
	if type(data.Heroes) ~= "table" then
		data.Heroes = {}
	end
	local h = data.Heroes[heroId]
	if type(h) ~= "table" then
		h = { XP = 0, Runs = 0 }
		data.Heroes[heroId] = h
	end
	gained = math.max(0, math.floor(tonumber(gained) or 0))
	local from = MetaUpgradeData.MasteryFor(h.XP)
	h.XP = math.max(0, math.floor(tonumber(h.XP) or 0)) + gained
	h.Runs = math.max(0, math.floor(tonumber(h.Runs) or 0)) + 1
	local to = MetaUpgradeData.MasteryFor(h.XP)
	return { Hero = heroId, Gained = gained, From = from, To = to }
end

-- EquipCosmetic for rings and frames (AchievementService forwards them here).
function AccountService.Equip(player: Player, kind: string, id: string): boolean
	local data = ctx.DataService.GetData(player)
	if not data or (kind ~= "Ring" and kind ~= "Frame") then
		return false
	end
	if not AccountService.CanWear(data, kind, id) then
		return false
	end
	data[kind] = id
	publish(player, data)
	return true
end

function AccountService.Init(c)
	ctx = c
end

function AccountService.Start()
	ctx.DataService.OnProfileLoaded(function(player)
		local data = ctx.DataService.GetData(player)
		if data then
			-- a worn track cosmetic must still be earned (hand-edited saves)
			for _, kind in ipairs({ "Ring", "Frame" }) do
				if not AccountService.CanWear(data, kind, data[kind] or "") then
					data[kind] = ""
				end
			end
			publish(player, data)
		end
	end)
end

return AccountService
