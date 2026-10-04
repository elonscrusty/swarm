-- reward-card: the overhaul reward presentation (docs/overhaul/REWARD.md, approved screen 05).
--   --set case=common   (default) a Small Chest's common item: the compact side card,
--                       no reel, HUD and hero clear, --set t=<s> after it arrived (0.6)
--   --set case=queue    three rewards at once: the same item twice (coalesced "x2") and
--                       an uncommon one queued behind it
--   --set case=elite    a one-level elite chest: the card with the weapon level and gold
--   --set case=rare     a Legendary from a Large Chest in a solo run: the contained reveal
--                       (the reel, run paused), t=2.0 = revealed
--   --set case=group    the same Legendary in a live duo run: a rare card, no pause
--   --set case=history  the ITEMS list (run menu) with the recent-rewards history
-- The pre-purchase disclosure (name, run gold price, odds, hold) is the loot scene:
--   render.sh loot --set focus=Small|Large|Golden
local A = lib("arena")
local C = lib("common")
local case = preview.args.case or "common"
local s = A.build({ enemies = 60 })
C.settle(1)
local uid = game:GetService("Players").LocalPlayer.UserId
local t = tonumber(preview.args.t)

local function item(id, source, dramatic, count)
	C.fire("ItemGained", { Id = id, Count = count or 1, Source = source, Reward = true, Dramatic = dramatic == true })
end

if case == "group" then
	local p = preview.addPlayer("Ava", 2)
	p:SetAttribute("InRun", true)
	p:SetAttribute("Alive", true)
	p:SetAttribute("CharacterId", "Mage")
	C.setState({ Frozen = false, Mode = "Duo" })
	C.settle(0.2)
end

if case == "common" then
	item("HealingHerb", "Small Chest", false)
	C.settle(t or 0.6)
elseif case == "queue" then
	item("HealingHerb", "Small Chest", false)
	C.settle(0.2)
	item("HealingHerb", "Small Chest", false, 2)
	item("StormCharm", "Shrine of Chance", false)
	C.settle(t or 0.6)
elseif case == "elite" then
	C.fire("ChestOpened", { Dramatic = false, Rewards = { { Name = "Sword", Text = "Level 4", Color = Color3.fromRGB(220, 220, 230) } }, Gold = 31 })
	C.settle(t or 0.6)
elseif case == "rare" then
	C.setState({ Frozen = true, LevelUpPause = false, RewardNames = "Player", RewardIds = "," .. tostring(uid) .. "," })
	item("SunMedallion", "Large Chest", true)
	C.settle(t or 2.0)
elseif case == "group" then
	item("SunMedallion", "Large Chest", true)
	C.settle(t or 0.6)
elseif case == "history" then
	item("HealingHerb", "Small Chest", false)
	C.settle(0.3)
	item("StormCharm", "Shrine of Chance", false)
	C.settle(0.3)
	C.fire("ChestOpened", { Dramatic = false, Rewards = { { Name = "Sword", Text = "Level 4" } }, Gold = 31 })
	C.settle(6)
	local LootUI = preview.client("LootUI")
	C.try("LootUI.OpenItems", LootUI.OpenItems)
	C.settle(t or 0.8)
end
