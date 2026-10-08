-- rewards-sim: boots the REAL server (GameServer, all modules) and opens chests through the
-- remotes for a solo player, printing what the server and the client reel do:
--   * the hold (Config.Chests.HoldSeconds): not open yet just before it, opened just after
--   * the item is owned the moment the chest opens (before the reel has shown anything)
--   * the run pause: the client reel ends it itself (RewardClose with its count) before
--     the server's RewardPauseSeconds, and the reel overlay closes on its own
--   * RewardClose with an older count is ignored; RewardPauseMax caps a burst of rewards
--   * a reel that is spinning is torn down when the player's InRun goes false, and the
--     item stays owned
-- A logic smoke test, not a picture: render.sh rewards-sim --devices pc (renders the end).
local C = lib("common")
local Players = game:GetService("Players")
preview.forceMeshesUploaded()
preview.startServer()
preview.advance(1)
C.startClient()
preview.advance(1)
local st = C.state()
local me = Players.LocalPlayer
local RM = preview.server("RunManager")
local Loot = preview.server("LootSystem")
local Gold = preview.server("GoldSystem")
local Config = C.shared("Config")
local advance = preview.advance

local function levelUps()
	for _ = 1, 20 do
		if not me:GetAttribute("Paused") then
			return
		end
		preview.remote("LevelUpChoose"):FireServer(1, game:GetService("Players").LocalPlayer:GetAttribute("ChoiceOfferId"))
		advance(0.3)
	end
end

local function overlay(): GuiObject?
	local pg = me:FindFirstChild("PlayerGui")
	local o = pg and pg:FindFirstChild("Reward", true)
	return o and o:IsA("GuiObject") and o or nil
end

local function itemCount(rp): number
	local n = 0
	for _, c in pairs(rp.Items or {}) do
		n += c
	end
	return n
end

local function log(label, rp)
	local o = overlay()
	preview.log(string.format("%-34s frozen=%s rewardIds=%s pauseLeft=%s seq=%s items=%d gold=%s reel=%s",
		label, tostring(st:GetAttribute("Frozen")), tostring(st:GetAttribute("RewardIds")),
		rp.RewardUntil and string.format("%.2f", rp.RewardUntil - os.clock()) or "-",
		tostring(rp.RewardSeq), itemCount(rp), tostring(me:GetAttribute("RunGold")),
		tostring(o ~= nil and o.Visible)))
end

preview.remote("StartRun"):FireServer("Solo")
advance(2)
levelUps()
local rp = RM.GetRunPlayer(me)
if not rp then
	preview.log("FAIL: no run player")
	return
end
rp.InvulnUntil = math.huge
Gold.AddRunGold(rp, 100000)

local function readyChest()
	for _, obj in pairs(Loot.Objects()) do
		if obj.Kind == "Chest" and obj.State == "Ready" then
			return obj
		end
	end
	return nil
end

local function standAt(obj)
	local root = rp.Root
	if root then
		root.CFrame = CFrame.new(obj.Pos + Vector3.new(2, 3, 0))
		rp.LastValidPos = root.Position
		rp.SpeedCheckTimer = 0
	end
end

-- 1) hold, open, ownership, the reel ends the pause itself
local chest = readyChest()
if not chest then
	preview.log("FAIL: no ready chest on the stage")
	return
end
local hold = Config.Chests.HoldSeconds[chest.Type]
preview.log("chest", chest.Type, "hold", hold, "pause", Config.Chests.RewardPauseSeconds, "max", Config.Chests.RewardPauseMax)
standAt(chest)
advance(0.1)
local before = itemCount(rp)
preview.remote("LootHold"):FireServer(chest.Id, true)
advance(hold - 0.15)
log("just before the hold ends", rp)
preview.log("state", chest.State, "(must still be Ready)")
advance(0.25)
local openedAt = os.clock()
log("hold done", rp)
preview.log("state", chest.State, "items +", itemCount(rp) - before, "(owned at once: must be 1)")
preview.remote("LootHold"):FireServer(chest.Id, false)
advance(1.0)
log("reel spinning (1.0s)", rp)
local unfrozenAt = nil
for _ = 1, 40 do
	advance(0.1)
	if not st:GetAttribute("Frozen") and not unfrozenAt then
		unfrozenAt = os.clock() - openedAt
	end
end
log("after 5s", rp)
preview.log(string.format("pause ended after %.2fs (server limit %.1fs: earlier = the reel's RewardClose)", unfrozenAt or -1, Config.Chests.RewardPauseSeconds))

-- 2) a stale RewardClose leaves a newer reward's pause; the right one ends it
RM.HoldReward(rp)
RM.HoldReward(rp)
local seq = rp.RewardSeq
advance(0.05)
preview.remote("RewardClose"):FireServer(seq - 1)
advance(0.1)
log("stale close (seq-1)", rp)
preview.remote("RewardClose"):FireServer(seq)
advance(0.1)
log("current close (seq)", rp)
advance(3)

-- 3) RewardPauseMax caps a burst
for _ = 1, 6 do
	RM.HoldReward(rp)
end
preview.log(string.format("burst of 6: pause %.2fs from its start (max %.1f)", (rp.RewardUntil or 0) - (rp.RewardStart or 0), Config.Chests.RewardPauseMax))
preview.remote("RewardClose"):FireServer(rp.RewardSeq)
advance(8)
log("burst closed", rp)

-- 4) leaving mid-reel tears the reel down; the item stays owned
local chest2 = readyChest()
if chest2 then
	standAt(chest2)
	advance(0.1)
	local n0 = itemCount(rp)
	preview.remote("LootHold"):FireServer(chest2.Id, true)
	advance(hold + 0.1)
	preview.remote("LootHold"):FireServer(chest2.Id, false)
	advance(0.3)
	log("second chest, reel spinning", rp)
	me:SetAttribute("InRun", false)
	advance(0.5)
	log("InRun=false mid-reel", rp)
	preview.log("items +", itemCount(rp) - n0, "(still owned: must be 1)")
	me:SetAttribute("InRun", true)
	advance(0.2)
end
advance(4)
log("end", rp)
