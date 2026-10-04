-- ui-stack: the proven overlap cases of the review (docs/overhaul/UI_STATE_CONTRACT.md §6)
-- played through the real client UI and UIState, so the render shows what the player gets
-- now. Logs "[ui-stack] ..." lines with what is on screen.
--   --set case=portal    server "THE PORTAL HAS APPEARED" broadcast + the PortalReveal
--                        attribute in the same moment (Short 0:13, Long 9:10): one headline
--   --set case=caravan   caravan defence starts with a loud wave (Short 0:50): bar + wave
--                        headline, no caravan toast on top of the bar
--   --set case=elite     swarm-pressure headline + an elite wave toast + an info toast
--                        (Short 1:25): the threat sits under the headline, info waits
--   --set case=stack     four messages at once (Long 8:12): two elites coalesce, at most
--                        2 (phone) / 3 (pc) pills
--   --set case=levelup   stage clear panel, then a level-up offer (Long 9:02): only the
--                        upgrade shows; --set closeup=on then closes it: stage clear returns
--   --set case=reel      a chest reward + portal reveal next to the opened chest (Long 9:10):
--                        reward feedback only, the portal headline waits, no chest prompt
--   --set at=<s>         seconds to settle before the picture (default 0.8)
local A = lib("arena")
local C = lib("common")
local case = preview.args.case or "portal"
local Players = game:GetService("Players")
local player = Players.LocalPlayer

local s = A.build({ enemies = 40, seconds = 300, portal = true, portalState = case == "levelup" and "Open" or "Idle", stage = 2, swarm = true, stagePhase = case == "levelup" and "Open" or nil, choiceLeft = 12 })
C.fire("Inventory", A.inventory())
C.setState({ WaveSeq = 1, Wave = 5, PortalReveal = 0, SwarmWarn = 0 })
C.settle(4) -- past the stage card

local function log(fmt: string, ...)
	preview.log("[ui-stack] " .. string.format(fmt, ...))
end

local function visibleTexts(pattern: string): number
	local n = 0
	for _, g in ipairs(preview.findGui(function(obj, _st)
		local ok, text = pcall(function()
			return obj.Text
		end)
		return ok and type(text) == "string" and string.find(string.upper(text), pattern) ~= nil
	end)) do
		local ok, tt = pcall(function()
			return (g :: any).TextTransparency
		end)
		if preview.isShown(g) and not (ok and type(tt) == "number" and tt >= 0.95) then
			n += 1
		end
	end
	return n
end

local function shownPanels(): string
	local UIState = preview.client("UIState")
	local names = UIState and UIState.OpenNames() or {}
	local out = {}
	for _, name in ipairs(names) do
		table.insert(out, name .. (UIState.IsShown(name) and "(shown)" or "(suspended)"))
	end
	return table.concat(out, ", ")
end

local function pills(): number
	local UIState = preview.client("UIState")
	return UIState and #UIState.VisibleNotices() or -1
end

if case == "portal" then
	C.setState({ PortalHint = true, PortalReveal = 1 })
	C.fire("Notify", { Text = "THE PORTAL HAS APPEARED", Color = Color3.fromRGB(190, 210, 255), Big = true })
	C.settle(tonumber(preview.args.at) or 0.8)
	log("portal headings on screen: %d", visibleTexts("THE PORTAL HAS APPEARED"))
elseif case == "caravan" then
	local folder = workspace:FindFirstChild("SwarmEvents") or Instance.new("Folder")
	folder.Name = "SwarmEvents"
	folder.Parent = workspace
	local m = Instance.new("Model")
	m.Name = "Caravan"
	m:SetAttribute("Pos", s.centre + Vector3.new(-6, 0, 2))
	m:SetAttribute("State", "Defending")
	m:SetAttribute("Left", 18)
	m:SetAttribute("Progress", 0.1)
	m.Parent = folder
	C.fire("Notify", { Text = "Defend the caravan! Hold its ring for 20 seconds.", Color = Color3.fromRGB(255, 200, 120) })
	C.setState({ Wave = 4, WaveSides = "north,south", WaveAngle = 0, WaveLoud = true, WaveBig = false, WaveSeq = 2 })
	C.settle(tonumber(preview.args.at) or 0.8)
	log("caravan toasts: %d, wave headings: %d, pills: %d", visibleTexts("DEFEND THE CARAVAN"), visibleTexts("^WAVE 4"), pills())
elseif case == "elite" then
	C.setState({ SwarmWarn = 1 })
	C.settle(0.3)
	C.fire("Notify", { Text = "Wave 6: an elite leads it!", Color = Color3.fromRGB(255, 205, 120) })
	C.fire("Notify", { Text = "MrCarter opened the altar: an item for everyone!", Color = Color3.fromRGB(255, 220, 120) })
	C.settle(tonumber(preview.args.at) or 0.8)
	log("headline: %s, pills: %d (elite: %d, altar: %d)", tostring(visibleTexts("SWARM IS GROWING")), pills(), visibleTexts("ELITE LEADS"), visibleTexts("OPENED THE ALTAR"))
elseif case == "stack" then
	C.fire("Notify", { Text = "An elite Shielded Mite hunts you!", Color = Color3.fromRGB(255, 205, 120) })
	C.fire("Notify", { Text = "An elite Burning Phase Moth hunts you!", Color = Color3.fromRGB(255, 205, 120) })
	C.fire("AchievementUnlocked", { Name = "Field Engineer", Reward = "Unlocks the Engineer · 150 gold" })
	C.fire("Notify", { Text = "MrCarter opened the altar: an item for everyone!", Color = Color3.fromRGB(255, 220, 120) })
	C.settle(tonumber(preview.args.at) or 0.8)
	log("pills on screen: %d (max %s)", pills(), tostring(preview.args.device))
elseif case == "levelup" then
	C.fire("PortalOffer", { CountsAsWin = false, Stage = 2, StagesCleared = 2, NextStage = 3, NextArena = "Forest", ReturnBonus = 1000, Gold = 2403, Kills = 1454, Level = 28, Time = 540, Seconds = 15, Group = false })
	C.settle(0.6)
	local WeaponData = C.shared("WeaponData")
	local function card(id, level)
		local def = WeaponData.Weapons[id]
		return { Type = "WeaponUp", Id = id, Level = level, Name = def.Name, Rank = string.format("Lv %d → %d / %d", level - 1, level, WeaponData.MaxLevel), Lines = WeaponData.CardLines(id, level - 1, level), Rarity = "Common" }
	end
	C.fire("LevelUpOffer", { Choices = { card("Whip", 2), card("MagicOrb", 1), card("Knives", 3) }, Seconds = 25, Pending = 1, Rerolls = 1, Skips = 0, RerollsMax = 1, SkipsMax = 0, SkipGold = 10, PanelId = 1, BatchRemaining = 1, BatchTotal = 1 })
	C.setState({ Frozen = true })
	C.settle(tonumber(preview.args.at) or 1.2)
	log("panels: %s", shownPanels())
	if preview.args.closeup == "on" then
		C.fire("LevelUpClose")
		C.settle(0.8)
		log("after the choice: %s", shownPanels())
	end
elseif case == "reel" then
	local folder = workspace:FindFirstChild("SwarmLoot") or Instance.new("Folder")
	folder.Name = "SwarmLoot"
	folder.Parent = workspace
	local m = Instance.new("Model")
	m.Name = "Chest"
	m:SetAttribute("Pos", s.centre + Vector3.new(2, 0, -2))
	m:SetAttribute("LootKind", "Chest")
	m:SetAttribute("LootType", "Large")
	m:SetAttribute("LootId", 7)
	m:SetAttribute("Title", "Large Chest")
	m:SetAttribute("State", "Opened")
	m:SetAttribute("Price", 0)
	m.Parent = folder
	C.fire("ItemGained", { Id = "StormCharm", Count = 1, Source = "Large Chest", Reward = true })
	C.settle(0.2)
	C.setState({ PortalHint = true, PortalReveal = 1 })
	C.fire("Notify", { Text = "THE PORTAL HAS APPEARED", Color = Color3.fromRGB(190, 210, 255), Big = true })
	C.settle(tonumber(preview.args.at) or 0.6)
	local LootUI = preview.client("LootUI")
	local prompt = LootUI and LootUI.Elements().Prompt
	log("during the reward: portal headings %d, chest prompt %s", visibleTexts("THE PORTAL HAS APPEARED"), tostring(prompt and prompt.Visible))
	if preview.args.after == "on" then
		C.settle(2.5)
		log("after the reward: portal headings %d, chest prompt %s", visibleTexts("THE PORTAL HAS APPEARED"), tostring(prompt and prompt.Visible))
	end
end
local _ = player
