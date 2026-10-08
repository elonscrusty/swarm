--[[
	GroupBonus.lua (Config.Features.GroupBonus; docs/next/GROUP_BONUS.md)
	Members of the game's Roblox group (Config.Group.Id; 0 = off until the owner gives the
	id) get, while the switch is on:
	  * Config.Group.GoldBonus (+10 %) of the gold a run pays into the lobby (kept purse +
	    survival bonus, GoldSystem.SettleRun), at most Config.Group.GoldCap (+500) per run.
	    Paid ONLY at settlement into the save: in-run gold, chest and shrine prices never
	    change (they follow GoldMult, the passes only). Never for a DEV-tainted run.
	    The results ledger shows it on its own (RunResult.GoldGroup).
	  * the "Group Member" title (Titles.Owned; taken away again when a later join finds
	    the player is no longer a member) and a star on the name plate (player attribute
	    GroupMember, client TitlePlates).
	Membership: Player:IsInGroupAsync(id) on the server, asked once per session in the
	background (a failed lookup is retried a few times, then counts as "not a member" for
	this session). Nothing is decided by the client.
]]

local Players = game:GetService("Players")

local Shared = game:GetService("ReplicatedStorage").Shared
local Config = require(Shared.Config)
local MetaData = require(Shared.MetaData)

local GroupBonus = {}

local ctx
-- player → true / false once the lookup answered (nil = not known yet)
local members: { [Player]: boolean } = {}
local asking: { [Player]: boolean } = {}

local function cfg(): { [string]: any }
	return (Config :: any).Group or {}
end

-- The group id (0 = off).
function GroupBonus.GroupId(): number
	local id = cfg().Id
	return (type(id) == "number" and id == id and id > 0 and id < math.huge) and math.floor(id) or 0
end

-- True when the bonus is live: the switch is on and the owner gave a group id.
function GroupBonus.Active(): boolean
	return Config.FeatureOn("GroupBonus") and GroupBonus.GroupId() ~= 0
end

-- The Roblox lookup (yields). Tests replace it (the preview has no groups).
GroupBonus._Lookup = function(player: Player, groupId: number): boolean
	return (player :: any):IsInGroupAsync(groupId) -- newer API; older type definitions lack it
end

-- Never yields: the cached answer (unknown = not a member for now).
function GroupBonus.IsMember(player: Player): boolean
	return GroupBonus.Active() and members[player] == true
end

-- The bonus for `base` gold paid into the lobby: GoldBonus of it, at most GoldCap.
function GroupBonus.BonusFor(base: number): number
	if type(base) ~= "number" or base ~= base or base <= 0 or base == math.huge then
		return 0
	end
	local c = cfg()
	local rate = math.max(0, tonumber(c.GoldBonus) or 0)
	local cap = math.max(0, math.floor(tonumber(c.GoldCap) or 0))
	return math.clamp(math.floor(base * rate), 0, cap)
end

-- Settlement (GoldSystem.SettleRun): pays the member bonus into the save once per run.
-- base = the gold this run put into the lobby (kept + survival). Returns the bonus paid.
function GroupBonus.Settle(rp, base: number, data: { [string]: any }?): number
	if not data or not rp or rp.DevTainted == true or data.DevBoosted == true then
		return 0
	end
	if rp.GroupBonusPaid ~= nil then
		return rp.GroupBonusPaid
	end
	local player: Player? = rp.Player
	if not player or not GroupBonus.IsMember(player) then
		return 0
	end
	local bonus = GroupBonus.BonusFor(base)
	rp.GroupBonusPaid = bonus
	if bonus > 0 then
		data.Gold += bonus
	end
	return bonus
end

local function titleId(): string
	local id = cfg().Title
	return type(id) == "string" and id or "Title_Group Member"
end

-- The title and the plate star follow the session's answer.
function GroupBonus.Apply(player: Player)
	if not player.Parent then
		return
	end
	local member = GroupBonus.IsMember(player)
	if player:GetAttribute("GroupMember") ~= member then
		player:SetAttribute("GroupMember", member)
	end
	local data = ctx and ctx.DataService.GetData(player)
	if not data or not GroupBonus.Active() or members[player] == nil then
		return
	end
	if type(data.Titles) ~= "table" then
		data.Titles = { Owned = {} }
	end
	if type(data.Titles.Owned) ~= "table" then
		data.Titles.Owned = {}
	end
	local id = titleId()
	local def = MetaData.TitleById[id]
	local name = def and def.Name or (string.gsub(id, "^Title_", ""))
	local changed = false
	if member and data.Titles.Owned[id] ~= true then
		data.Titles.Owned[id] = true
		changed = true
		if ctx.RunManager then
			ctx.RunManager.Notify(player, "Group member: +" .. math.floor((tonumber(cfg().GoldBonus) or 0) * 100 + 0.5) .. "% run gold and the Group Member title!", Color3.fromRGB(255, 220, 120), { Id = "group.member" })
		end
	elseif not member and data.Titles.Owned[id] == true then
		-- left the group: the title goes (the gold already paid stays)
		data.Titles.Owned[id] = nil
		if data.Title == name then
			data.Title = ""
		end
		changed = true
	end
	if changed and ctx.GoldSystem then
		ctx.GoldSystem.SyncProfile(player)
	end
end

local function check(player: Player)
	if asking[player] or members[player] ~= nil or not GroupBonus.Active() then
		return
	end
	asking[player] = true
	local groupId = GroupBonus.GroupId()
	for attempt = 1, 3 do
		local ok, result = pcall(GroupBonus._Lookup, player, groupId)
		if not player.Parent then
			break
		end
		if ok then
			members[player] = result == true
			break
		end
		if attempt < 3 then
			task.wait(5 * attempt)
		end
	end
	asking[player] = nil
	if player.Parent then
		GroupBonus.Apply(player)
	end
end

-- Forgets the cached answer and asks again (tests; the owner changing the id live).
function GroupBonus.Recheck(player: Player)
	members[player] = nil
	task.spawn(check, player)
end

function GroupBonus.Init(c)
	ctx = c
end

function GroupBonus.Start()
	ctx.DataService.OnProfileLoaded(function(player)
		check(player)
	end)
	Players.PlayerRemoving:Connect(function(player)
		-- deferred: a leaver's run settles in a later PlayerRemoving handler (RunManager)
		-- and must still see the cached membership
		task.defer(function()
			members[player] = nil
			asking[player] = nil
		end)
	end)
end

return GroupBonus
