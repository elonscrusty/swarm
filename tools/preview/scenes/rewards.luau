-- rewards: gold and chest feedback in a run.
--   --set view=panel (default)  the chest reward reel (run paused): a Large Chest item,
--                               the reel spinning / landing / revealed at --set t=<s>
--                               after it arrived (default 2.0: the reveal; 0.4 mid-spin,
--                               1.2 slowing down); --set item=<ItemData id> (default
--                               StormCharm); --set queue=on: an elite chest's level-ups +
--                               gold first, then two chest items queued behind it
--                               (t counts from the first); --set reduced=on: Reduced effects
--   --set view=coins            kills paying gold: coins bursting out and flying to the
--                               hero, the purse over the ability bar counting up with "+N"
--   --set view=need             standing at a chest without enough gold after pressing E:
--                               the purse turns red with "NEED N"
--   --set view=other            a teammate is opening a chest: the "<Name> is opening a
--                               chest" pause line
--   --set t=<s>                 coins: seconds after the kills (default 0.3)
local A = lib("arena")
local C = lib("common")
local view = preview.args.view or "panel"
local s = A.build({ enemies = 70 })
C.settle(1)
local centre = s.centre
local uid = game:GetService("Players").LocalPlayer.UserId

if view == "coins" then
	-- six kills around the hero paid gold (FxBatch "g"); the purse goes 57 → 74
	local batch = { g = {} }
	local spots = { { 9, -4, 2 }, { -8, 3, 3 }, { 5, 9, 1 }, { -6, -9, 2 }, { 12, 6, 9 }, { -13, -2, 0 } }
	local gain = 0
	for _, sp in ipairs(spots) do
		local amount = sp[3] > 0 and sp[3] or 1
		gain += amount
		table.insert(batch.g, { centre.X + sp[1], centre.Z + sp[2], amount, uid })
	end
	C.fire("FxBatch", batch)
	C.setPlayer({ RunGold = 57 + gain })
	C.settle(tonumber(preview.args.t) or 0.3)
elseif view == "need" then
	C.setPlayer({ RunGold = 12 })
	C.settle(0.6)
	local Hud = preview.client("Hud")
	if Hud and Hud.SetPurseHint then
		C.try("Hud.SetPurseHint", Hud.SetPurseHint, 40, false, true)
	end
	C.settle(0.3)
elseif view == "other" then
	C.setState({ Frozen = true, LevelUpPause = false, RewardNames = "Ranger_Rex", RewardIds = ",9001," })
	C.settle(0.6)
else
	C.setState({ Frozen = true, LevelUpPause = false, RewardNames = "Player", RewardIds = "," .. tostring(uid) .. "," })
	if preview.args.reduced == "on" then
		local ClientSettings = preview.client("ClientSettings")
		if ClientSettings and ClientSettings.Set then
			C.try("ClientSettings.Set", ClientSettings.Set, "ReducedEffects", true)
		end
	end
	local t = tonumber(preview.args.t) or 2.0
	if preview.args.queue == "on" then
		C.fire("ChestOpened", {
			Rewards = {
				{ Name = "Whip", Text = "Level 6", Color = Color3.fromRGB(220, 220, 230) },
				{ Name = "Heart", Text = "Level 3", Color = Color3.fromRGB(220, 90, 90) },
			},
			Gold = 38,
		})
		C.settle(0.2)
		C.fire("ItemGained", { Id = "StormCharm", Count = 1, Source = "Large Chest", Reward = true })
		C.fire("ItemGained", { Id = "SunMedallion", Count = 1, Source = "Golden Chest", Reward = true })
		C.settle(math.max(0.05, t - 0.2))
	else
		C.fire("ItemGained", { Id = preview.args.item or "StormCharm", Count = 1, Source = "Large Chest", Reward = true })
		C.settle(t)
	end
end
