-- group-bonus-regression: the Roblox group bonus (docs/next/GROUP_BONUS.md) on the real
-- server modules. The preview has no Roblox groups: the membership lookup is replaced
-- (GroupBonus._Lookup) and the group id is set at run time (Config.Group.Id ships as 0).
--   1) id 0 = off: no lookup, no attribute, no bonus at settlement
--   2) member vs non-member payout at settlement (+10 % of kept + survival gold)
--   3) the cap (+500 per run), paid once per run, never for a DEV-tainted run
--   4) in-run prices are untouched (GoldMult is the same for members)
--   5) title + plate star follow membership; leaving the group takes the title away
--   6) a failing lookup counts as "not a member"; switch off = no bonus
-- Real group membership is BLOCKED offline (live game / Studio with the owner's group).
local Players = game:GetService("Players")

local friend = preview.addPlayer("Friend", 5201)
preview.startServer()
preview.advance(2)

local player = Players.LocalPlayer
local Config = preview.shared("Config")
local DS = preview.server("DataService")
local GS = preview.server("GoldSystem")
local GB = preview.server("GroupBonus")
local data = assert(DS.GetData(player), "profile missing")
local fdata = assert(DS.GetData(friend), "friend profile missing")
assert(Config.FeatureOn("GroupBonus"), "the GroupBonus switch must be on")
assert(Config.Group.Id == 0, "the shipped group id is 0 (off until the owner gives it)")

local lookups = 0
local memberSet: { [number]: boolean } = { [player.UserId] = true }
local failing = false
GB._Lookup = function(p, id)
	lookups += 1
	assert(id == Config.Group.Id, "the lookup asks for the configured group")
	if failing then
		error("mock: group service down")
	end
	return memberSet[p.UserId] == true
end

local n = 0
-- Settles a fake run for `who` with `kept` gold in the escrow (portal: all kept, no
-- survival time). Returns (settlement, gold added to the save, rp).
local function settle(who, kept: number, extra: { [string]: any }?)
	n += 1
	local d = DS.GetData(who)
	local rp = { Player = who, RunId = "group-" .. n, Gold = kept }
	for k, v in pairs(extra or {}) do
		rp[k] = v
	end
	d.RunEscrow = { Id = rp.RunId, Gold = kept, Stages = 0 }
	local before = d.Gold
	local s = GS.SettleRun(rp, true, 3, 0)
	return s, d.Gold - before, rp
end

------------------------------------------------------------------------------------------
-- 1) id 0 = off
------------------------------------------------------------------------------------------
do
	GB.Recheck(player)
	preview.advance(0.5)
	assert(lookups == 0, "id 0: no membership lookup")
	assert(not GB.Active() and not GB.IsMember(player), "id 0: not active")
	local s, added = settle(player, 1000)
	assert(s.Group == 0 and added == 1000, "id 0: no bonus at settlement")
	assert(player:GetAttribute("GroupMember") ~= true, "id 0: no plate star")
	preview.log("PASS id 0 = off")
end

------------------------------------------------------------------------------------------
-- 2) member vs non-member payout
------------------------------------------------------------------------------------------
Config.Group.Id = 4242
do
	GB.Recheck(player)
	GB.Recheck(friend)
	preview.advance(0.5)
	assert(lookups == 2, "one lookup per player: " .. lookups)
	assert(GB.IsMember(player) and not GB.IsMember(friend), "member / non-member cached")
	-- cached per session: settling again does not ask Roblox again
	local s, added = settle(player, 1000)
	assert(s.Group == 100 and added == 1100, "member: +10% of 1000 = 100, got " .. tostring(s.Group))
	local fs, fadded = settle(friend, 1000)
	assert(fs.Group == 0 and fadded == 1000, "non-member: no bonus")
	assert(lookups == 2, "the answer is cached for the session")
	preview.log("PASS member +10% / non-member 0, cached lookup")
end

------------------------------------------------------------------------------------------
-- 3) cap, once per run, DEV-tainted
------------------------------------------------------------------------------------------
do
	local s, added, rp = settle(player, 20000)
	assert(s.Group == Config.Group.GoldCap and added == 20000 + Config.Group.GoldCap, "capped at +" .. Config.Group.GoldCap .. ", got " .. tostring(s.Group))
	local before = data.Gold
	GS.SettleRun(rp, true, 3, 0)
	assert(data.Gold == before, "a settled run never pays the bonus twice")
	local ds = settle(player, 1000, { DevTainted = true })
	assert(ds.Group == 0, "a DEV-tainted run gets no group bonus")
	assert(GB.BonusFor(0) == 0 and GB.BonusFor(0 / 0) == 0 and GB.BonusFor(math.huge) == 0 and GB.BonusFor(-50) == 0, "bad bases pay nothing")
	preview.log("PASS cap +500, once per run, not for DEV-tainted runs")
end

------------------------------------------------------------------------------------------
-- 4) in-run prices untouched
------------------------------------------------------------------------------------------
do
	assert(GS.PublishGoldMult(player) == GS.PublishGoldMult(friend), "a member's in-run gold multiplier is unchanged")
	assert(GS.PriceMult(player) == GS.PriceMult(friend), "a member's chest prices are unchanged")
	preview.log("PASS in-run gold / chest prices unchanged for members")
end

------------------------------------------------------------------------------------------
-- 5) title + star
------------------------------------------------------------------------------------------
do
	local title = Config.Group.Title
	assert(player:GetAttribute("GroupMember") == true and friend:GetAttribute("GroupMember") == false, "plate star attribute")
	assert(data.Titles.Owned[title] == true, "members own the Group Member title")
	assert(not fdata.Titles.Owned[title], "non-members don't")
	data.Title = "Group Member"
	memberSet[player.UserId] = nil
	GB.Recheck(player)
	preview.advance(0.5)
	assert(not data.Titles.Owned[title] and data.Title == "", "leaving the group takes the title (and its wear) away")
	assert(player:GetAttribute("GroupMember") == false, "star gone")
	memberSet[player.UserId] = true
	GB.Recheck(player)
	preview.advance(0.5)
	assert(data.Titles.Owned[title] == true, "rejoining gives it back")
	preview.log("PASS title + plate star follow membership")
end

------------------------------------------------------------------------------------------
-- 6) failing lookup, switch off
------------------------------------------------------------------------------------------
do
	failing = true
	GB.Recheck(friend)
	preview.advance(20)
	assert(not GB.IsMember(friend), "a failing lookup counts as not a member")
	failing = false
	Config.Features.GroupBonus = false
	local s = settle(player, 1000)
	assert(s.Group == 0, "switch off: no bonus")
	Config.Features.GroupBonus = true
	Config.Group.Id = 0
	preview.log("PASS failing lookup = not a member; switch off = no bonus")
end

preview.note("BLOCKED offline: real group membership needs the owner's group id and a live / Studio server")
preview.log("PASS group-bonus-regression")
