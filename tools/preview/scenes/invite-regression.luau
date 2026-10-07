-- invite-regression: invite rewards (docs/next/INVITE_REWARDS.md) on the real server modules.
-- Runs WITHOUT --studio (live DataStores: brand-new saves and the pending store). The preview
-- has no real invites: Roblox's join data is replaced (InviteRewards._JoinData) so a few
-- players arrive "referred".
--   1) a brand-new save (no earlier save) is New; the referral is read once (Friend Badge)
--   2) no credit before the new player finishes a run; credit once after it (same server)
--   3) one credit per new player: a second run, a duplicate record and a re-sent record
--      never credit twice
--   4) inviter offline: a pending record in the store, processed by the inviter's server
--      when they join, then removed
--   5) Recruiter title on the first credit, the trail at TrailAt; the credit cap
--   6) refused: old accounts, self-referral, DEV-boosted players, switch off
-- Real invites / referrals are BLOCKED offline (Studio or a live server with two accounts).
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
assert(not RunService:IsStudio(), "invite-regression must run without --studio (live DataStores)")

local IR = preview.server("InviteRewards")
local Config = preview.shared("Config")
local inviter = Players.LocalPlayer
local OFFLINE = 7770001 -- an inviter who is not in this server yet
local refs: { [number]: number } = {}
IR._JoinData = function(p)
	local ref = refs[p.UserId]
	return ref and { ReferredByPlayerId = ref } or {}
end
local newbie = preview.addPlayer("Newbie", 5301)
local newbie2 = preview.addPlayer("Newbie2", 5302)
local selfRef = preview.addPlayer("SelfRef", 5303)
refs[5301] = inviter.UserId
refs[5302] = OFFLINE
refs[5303] = 5303
preview.startServer()
preview.advance(3)

local DS = preview.server("DataService")
local idata = assert(DS.GetData(inviter), "inviter profile missing")
local ndata = assert(DS.GetData(newbie), "newbie profile missing")
local n2data = assert(DS.GetData(newbie2), "newbie2 profile missing")
local sdata = assert(DS.GetData(selfRef), "self-referrer profile missing")
assert(Config.FeatureOn("InviteRewards"), "the InviteRewards switch must be on")

local function recruits(d): number
	return tonumber(d.Stats.Recruits) or 0
end

------------------------------------------------------------------------------------------
-- 1) new saves and the referral
------------------------------------------------------------------------------------------
do
	assert(ndata.Invite.New == true and ndata.Invite.Checked == true, "a brand-new save is New and its referral was read")
	assert(ndata.Invite.ReferredBy == inviter.UserId, "ReferredByPlayerId recorded")
	assert(ndata.Cosmetics.Owned[Config.Invite.Badge] == true, "the new player gets the Friend Badge nameplate")
	assert(sdata.Invite.ReferredBy == 0 and not sdata.Cosmetics.Owned[Config.Invite.Badge], "a self-referral counts for nothing")
	-- read once: a later join with other join data changes nothing
	refs[5301] = 999
	IR._OnLoaded(newbie)
	assert(ndata.Invite.ReferredBy == inviter.UserId, "the referral is read only on the first load")
	refs[5301] = inviter.UserId
	-- an old account (a save from before) is never New, so a referral never counts
	local old = DS.Migrate({ Version = Config.Data.SchemaVersion, Gold = 10 })
	assert(old.Invite.New == false and old.FirstJoin == 0, "an old save is not new to SWARM")
	preview.log("PASS referral: new saves only, read once, Friend Badge, no self-referral")
end

------------------------------------------------------------------------------------------
-- 2) credit after the first finished run (inviter in this server)
------------------------------------------------------------------------------------------
do
	assert(recruits(idata) == 0 and not idata.Titles.Owned[Config.Invite.Title], "no credit before a finished run")
	IR.OnRunCommitted(newbie, ndata)
	preview.advance(1)
	assert(recruits(idata) == 1, "credited once after the run: " .. recruits(idata))
	assert(idata.Invite.Credited[tostring(newbie.UserId)] == true, "the credit is keyed by the new player")
	assert(idata.Titles.Owned[Config.Invite.Title] == true, "the inviter earns the Recruiter title")
	assert(inviter:GetAttribute("Recruits") == 1, "Recruits published")
	assert(ndata.Invite.Sent == true, "the new player's save remembers it was sent")
	preview.log("PASS credit after the first finished run")
end

------------------------------------------------------------------------------------------
-- 3) exactly once
------------------------------------------------------------------------------------------
do
	IR.OnRunCommitted(newbie, ndata)
	preview.advance(1)
	assert(recruits(idata) == 1, "a second run never credits again")
	IR._AddPending(inviter.UserId, newbie.UserId)
	IR.ProcessPending(inviter)
	preview.advance(1)
	assert(recruits(idata) == 1, "a duplicate pending record never credits again")
	assert(#(IR._ReadPending(inviter.UserId) or { 0 }) == 0, "the processed record is removed")
	assert(IR.Credit(inviter, newbie.UserId) == false, "Credit itself refuses a second credit")
	preview.log("PASS exactly once: second run, duplicate record, direct call")
end

------------------------------------------------------------------------------------------
-- 4) inviter offline: pending record processed by the inviter's server
------------------------------------------------------------------------------------------
local late
do
	assert(n2data.Invite.ReferredBy == OFFLINE, "referred by an offline inviter")
	IR.OnRunCommitted(newbie2, n2data)
	preview.advance(1)
	local pending = IR._ReadPending(OFFLINE) or {}
	assert(#pending == 1 and pending[1] == newbie2.UserId, "a pending record waits under the inviter's key")
	assert(n2data.Invite.Sent == true, "sent once stored")
	late = preview.addPlayer("LateInviter", OFFLINE)
	preview.playerJoined(late)
	preview.advance(4)
	local ldata = assert(DS.GetData(late), "late inviter profile missing")
	assert(recruits(ldata) == 1 and ldata.Invite.Credited[tostring(newbie2.UserId)] == true, "credited on the inviter's next join")
	assert(#(IR._ReadPending(OFFLINE) or { 0 }) == 0, "the record is removed after the inviter's save")
	IR.OnRunCommitted(newbie2, n2data)
	IR.ProcessPending(late)
	preview.advance(1)
	assert(recruits(ldata) == 1, "still one credit")
	preview.log("PASS offline inviter: pending record, processed on join, removed")
end

------------------------------------------------------------------------------------------
-- 5) trail at TrailAt, cap
------------------------------------------------------------------------------------------
do
	assert(not idata.Cosmetics.Owned[Config.Invite.Trail], "no trail at 1")
	assert(IR.Credit(inviter, 880001) and IR.Credit(inviter, 880002), "two more friends")
	assert(recruits(idata) == Config.Invite.TrailAt, "count reaches TrailAt")
	assert(idata.Cosmetics.Owned[Config.Invite.Trail] == true, "the Recruiter Trail at " .. Config.Invite.TrailAt)
	local cap = Config.Invite.MaxCredits
	Config.Invite.MaxCredits = recruits(idata)
	assert(IR.Credit(inviter, 880003) == false and recruits(idata) == Config.Invite.MaxCredits, "the credited set is capped")
	Config.Invite.MaxCredits = cap
	assert(IR.Credit(inviter, inviter.UserId) == false and IR.Credit(inviter, 0) == false and IR.Credit(inviter, 0 / 0) == false, "self / bad ids refused")
	preview.log("PASS trail at TrailAt, capped credits, bad ids refused")
end

------------------------------------------------------------------------------------------
-- 6) DEV-boosted, switch off
------------------------------------------------------------------------------------------
do
	local before = recruits(idata)
	-- a DEV-boosted referred player never sends a credit
	sdata.Invite.ReferredBy = inviter.UserId -- (forged for the test; the real read refused it)
	sdata.DevBoosted = true
	IR.OnRunCommitted(selfRef, sdata)
	preview.advance(1)
	assert(recruits(idata) == before and sdata.Invite.Sent == false, "a DEV-boosted profile sends no credit")
	sdata.DevBoosted = false
	Config.Features.InviteRewards = false
	IR.OnRunCommitted(selfRef, sdata)
	preview.advance(1)
	assert(recruits(idata) == before and sdata.Invite.Sent == false, "switch off: nothing is sent")
	Config.Features.InviteRewards = true
	preview.log("PASS DEV-boosted and switch off send nothing")
end

preview.note("BLOCKED offline: real invites (SocialService prompt) and ReferredByPlayerId need a live server with two accounts")
preview.log("PASS invite-regression")
