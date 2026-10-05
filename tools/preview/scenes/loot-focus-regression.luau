-- loot-focus-regression (audit 2026-10-05, docs/audit/JOURNEY.md J-07): a chest hold that
-- loses window focus (alt-tab, the Roblox menu, a phone notification) lets go: the key's
-- InputEnded may never arrive, so before the fix the server finished the hold and charged
-- the gold. Real server + real client (LootUI):
--   control  E held next to a priced chest: it opens once, gold charged once
--   focus    E pressed, then focus lost before the hold time: nothing opens, no gold taken
-- Lune sim, NOT Studio. Prints PASS / FAIL lines; any FAIL fails tools/run_regressions.py.
local Players = game:GetService("Players")
local UIS = game:GetService("UserInputService")
preview.forceMeshesUploaded()
preview.startServer()
preview.advance(1)
local okClient = pcall(preview.startClient)
preview.advance(1)
local me = Players.LocalPlayer
local RM = preview.server("RunManager")
local Loot = preview.server("LootSystem")
local Gold = preview.server("GoldSystem")
local Items = preview.server("ItemSystem")
local function advance(seconds: number)
	preview.advance(seconds, 10)
end
local fails = 0
local function check(cond: any, label: string)
	if cond then
		preview.log("PASS " .. label)
	else
		fails += 1
		preview.log("FAIL " .. label)
	end
end
check(okClient, "client started")
local grants = 0
local realGrant = Items.Grant
Items.Grant = function(...)
	local ok, d = realGrant(...)
	if ok then
		grants += 1
	end
	return ok, d
end

preview.remote("StartRun"):FireServer("Solo")
advance(2)
for _ = 1, 20 do
	if not me:GetAttribute("Paused") then
		break
	end
	preview.remote("LevelUpChoose"):FireServer(1)
	advance(0.3)
end
local rp = assert(RM.GetRunPlayer(me), "run player")
rp.InvulnUntil = math.huge
Gold.AddRunGold(rp, 100000)
advance(0.5)

local function readyChest()
	for _, obj in ipairs(Loot.Objects()) do
		if obj.Kind == "Chest" and obj.State == "Ready" and (obj.Model:GetAttribute("Price") or 0) > 0 then
			return obj
		end
	end
	return nil
end
local function standAt(obj)
	rp.Root.CFrame = CFrame.new(obj.Pos + Vector3.new(2, 3, 0))
	rp.LastValidPos, rp.SpeedCheckTimer = rp.Root.Position, 0
end
local function key(state: string)
	local input = { UserInputType = Enum.UserInputType.Keyboard, KeyCode = Enum.KeyCode.E, UserInputState = state == "Begin" and Enum.UserInputState.Begin or Enum.UserInputState.End, Position = Vector3.zero }
	if state == "Begin" then
		UIS.InputBegan:_fire(input, false)
	else
		UIS.InputEnded:_fire(input, false)
	end
end

-- control: a normal hold opens the chest once
local a = assert(readyChest(), "a ready chest")
standAt(a)
advance(0.5) -- LootUI picks the nearest chest as its target
local wallet0 = Gold.RunWallet(rp)
key("Begin")
advance((a.Model:GetAttribute("Hold") or 0.4) + 0.6)
key("End")
advance(0.3)
check(a.State == "Opened" and grants == 1, "control: E held opens the chest (state " .. tostring(a.State) .. ", grants " .. grants .. ")")
check(Gold.RunWallet(rp) < wallet0, "control: the chest was paid for")
advance(5) -- the compact card and its prompt hold

-- focus loss mid-hold: no open, no charge
local b = readyChest()
check(b ~= nil, "a second ready chest")
if b then
	standAt(b)
	advance(0.5)
	local wallet1 = Gold.RunWallet(rp)
	key("Begin")
	advance(0.1)
	UIS.WindowFocusReleased:_fire()
	advance((b.Model:GetAttribute("Hold") or 0.4) + 1)
	check(b.State == "Ready", "focus loss: the chest is not opened (state " .. tostring(b.State) .. ")")
	check(Gold.RunWallet(rp) == wallet1 and grants == 1, "focus loss: no gold taken, no item granted")
	key("End") -- the late release (or none) changes nothing
	advance(0.3)
	check(b.State == "Ready" and grants == 1, "focus loss: a late release changes nothing")
end
preview.log(fails == 0 and "loot-focus-regression: ALL PASS" or ("loot-focus-regression: " .. fails .. " FAIL"))
