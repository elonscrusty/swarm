--[[
	ReviveThanks.lua  (server only; Config.Features.ReviveThanks, Config.Revive;
	docs/next/REVIVE_THANKS.md)
	After a teammate revives you (RunManager's proximity partner revive), you get a short
	THANKS! offer. Tapping it tells the reviver "<name> says thanks!" and gives them
	Config.Revive.ThanksXP run XP through XPSystem.GiveXP (exact amount, no multipliers).

	  Offer    ReviveThanks.OnRevived(revivedRp, helperRp) is called by RunManager right after a
	           partner revive. It makes one offer per revive (a fresh Id; a newer revive
	           replaces an older open offer) and sends it to the revived player only
	           (ReviveThanksOffer { Id, Seconds, FromName }). Nothing is offered in a solo
	           run, to a DEV-tainted run or for a self-revive.
	  Thank    remote "ReviveThanks" (offerId). Checked here, never trusted from the client:
	           the feature is on, the run is a group run, the offer is yours and open (not
	           used, not older than ThanksSeconds + ThanksGrace), the reviver is still in the
	           run and is not you, the pair has fewer than ThanksPerPair thank-yous this run,
	           and neither player's run is DEV-tainted. The offer is marked used BEFORE
	           anything is paid, so a repeated tap does nothing (exactly once).
	  Reward   the reviver gets the notice (RunManager.Notify, own id per sender) and, when
	           alive, ThanksXP run XP. Run XP only: nothing is saved, nothing goes to a board.
	All counters live on the run player record, so they reset with every run.
]]

local Shared = game:GetService("ReplicatedStorage").Shared
local Config = require(Shared.Config)
local Remotes = require(Shared.Remotes)

local ReviveThanks = {}

local ctx
local nextId = 0

local GOOD = Color3.fromRGB(120, 255, 160)

local function on(): boolean
	return Config.FeatureOn("ReviveThanks")
end

local function cfg(): { [string]: any }
	return (Config :: any).Revive
end

local function tainted(rp): boolean
	if rp.DevTainted == true then
		return true
	end
	local data = ctx.DataService and ctx.DataService.GetData(rp.Player)
	return data ~= nil and data.DevBoosted == true
end

-- A group run: more than one run participant.
local function groupRun(): boolean
	return #ctx.RunManager.GetRunPlayers() > 1
end

-- Called by RunManager right after `rp` was revived by `helper` (both run player records).
-- Returns the offer id, or nil when no offer was made.
function ReviveThanks.OnRevived(rp, helper): number?
	if not on() or rp == nil or helper == nil or rp == helper or rp.Player == helper.Player then
		return nil
	end
	if not groupRun() or tainted(rp) or tainted(helper) then
		rp.ThanksOffer = nil
		return nil
	end
	nextId += 1
	rp.ThanksOffer = { Id = nextId, Helper = helper, At = os.clock(), Used = false }
	Remotes.FireClient("ReviveThanksOffer", rp.Player, {
		Id = nextId,
		Seconds = cfg().ThanksSeconds,
		FromName = helper.Player.DisplayName,
	})
	return nextId
end

-- Why `player`'s thank-you for `offerId` is refused, or nil when it would go through.
function ReviveThanks.Check(player: Player, offerId: any): string?
	if not on() then
		return "feature"
	end
	if type(offerId) ~= "number" or offerId ~= offerId then
		return "id"
	end
	local rp = ctx.RunManager.GetRunPlayer(player)
	if not rp or rp.Returned or not ctx.RunManager.IsParticipant(player) then
		return "run"
	end
	if not groupRun() then
		return "solo"
	end
	local offer = rp.ThanksOffer
	if not offer or offer.Id ~= offerId then
		return "offer"
	end
	if offer.Used then
		return "used"
	end
	if os.clock() - offer.At > cfg().ThanksSeconds + cfg().ThanksGrace then
		return "expired"
	end
	local helper = offer.Helper
	if not helper or helper == rp or helper.Player == player or helper.Returned or not helper.Player.Parent or not ctx.RunManager.IsParticipant(helper.Player) then
		return "helper"
	end
	local given = rp.ThanksGiven
	if given and (given[helper.Player.UserId] or 0) >= cfg().ThanksPerPair then
		return "pair"
	end
	if tainted(rp) or tainted(helper) then
		return "dev"
	end
	return nil
end

-- A thank-you from `player`. Returns true when it was accepted (and paid).
function ReviveThanks.Thank(player: Player, offerId: any): boolean
	if ReviveThanks.Check(player, offerId) ~= nil then
		return false
	end
	local rp = ctx.RunManager.GetRunPlayer(player)
	local offer = rp.ThanksOffer
	local helper = offer.Helper
	-- marked first: nothing below can run twice for this revive
	offer.Used = true
	rp.ThanksGiven = rp.ThanksGiven or {}
	rp.ThanksGiven[helper.Player.UserId] = (rp.ThanksGiven[helper.Player.UserId] or 0) + 1
	local xp = cfg().ThanksXP
	local paid = false
	if helper.Alive and type(xp) == "number" and xp > 0 then
		ctx.XPSystem.GiveXP(helper, xp)
		paid = true
	end
	ctx.RunManager.Notify(
		helper.Player,
		player.DisplayName .. " says thanks!" .. (paid and (" +" .. tostring(math.floor(xp)) .. " XP") or ""),
		GOOD,
		{ Id = "thanks." .. player.UserId, Class = "Info" }
	)
	return true
end

function ReviveThanks.Init(c)
	ctx = c
end

function ReviveThanks.Start()
	Remotes.Listen("ReviveThanks", function(player, offerId)
		ReviveThanks.Thank(player, offerId)
	end, cfg().ThanksRate or 2)
end

return ReviveThanks
