-- transactions-ui-regression (studio review SW-04 / SW-05 / SW-07, stream R5): what the real client
-- modules SAY about a chest purchase and the paid revive, fed by the shared-contract attributes and
-- remotes only (no server). Prints PASS / FAIL lines.
--   chest   RunInteract's prompt, LootUI.ChestStatus and the HUD purse hint use one price and one
--           balance: below / equal / above, the recording's frame (team 21, chest 54, personal run
--           gold 9 -> "need 33", never 45), choosing (no prompt, no purchase), opening, pending,
--           claimed ("paid 54 · next chest 73", HUD "NEXT CHEST 73"), failed (the server's reason),
--           gold arriving while the key is held (the hold starts once, by itself)
--   revive  the offer explains the real benefit, never opens Roblox's dialog by itself, REVIVE asks
--           the server (ReviveBuy), Prompting / Cancelled / Failed / Pending never read as success,
--           only the server's Close (Fulfilled) closes it; no offer = no overlay
local A = lib("arena")
local C = lib("common")
local s = A.build({ arena = "Forest", enemies = 0, swarm = false, seconds = 300 })
for _, name in ipairs({ "SwarmEnemies", "SwarmGems", "SwarmPickups" }) do
	if not workspace:FindFirstChild(name) then
		local f = Instance.new("Folder")
		f.Name = name
		f.Parent = workspace
	end
end
C.settle(1.5)

local Players = game:GetService("Players")
local RS = game:GetService("ReplicatedStorage")
local UIS = game:GetService("UserInputService")
local lp = Players.LocalPlayer
local state = C.state()
local fails = 0
local function check(ok: any, label: string)
	if not ok then
		fails += 1
	end
	preview.log((ok and "PASS " or "FAIL ") .. label)
end
local function settle(t: number?)
	preview.advance(t or 0.4, 6)
end
local function setS(k: string, v: any)
	state:SetAttribute(k, v)
end

local runFolder = lp.PlayerScripts.SwarmV2Client.Run
local RunInteract = preview.require(runFolder:FindFirstChild("RunInteract"))
local LootUI = preview.client("LootUI")
local Hud = preview.client("Hud")
local UIState = preview.client("UIState")

-- what the server got
local holds = {}
preview.remote("LootHold").OnServerEvent:Connect(function(_, id, on)
	table.insert(holds, { id, on })
end)
local buys = 0
preview.remote("ReviveBuy").OnServerEvent:Connect(function()
	buys += 1
end)

local root = lp.Character and lp.Character.PrimaryPart
assert(root, "local hero")
setS("RunStage", "Survive")
setS("TeamRunGold", 30)
setS("ChestCost", 54)
setS("TeamChestsBought", 1)
lp:SetAttribute("RunGold", 9) -- the personal run gold (escrow): never the chest's balance
lp:SetAttribute("InRun", true)
lp:SetAttribute("Alive", true)

local folder = workspace:FindFirstChild("SwarmLoot") or Instance.new("Folder")
folder.Name = "SwarmLoot"
folder.Parent = workspace
local nextId = 500
local function chest(): Model
	for _, m in ipairs(folder:GetChildren()) do
		m:Destroy()
	end
	nextId += 1
	local m = Instance.new("Model")
	m.Name = "Chest" .. nextId
	for k, v in pairs({ Pos = root.Position + Vector3.new(3, 0, 2), LootKind = "Chest", LootType = "Small", State = "Ready", Price = 54, LootId = nextId, Hold = 0.4, TeamGold = true, Title = "Chest" }) do
		m:SetAttribute(k, v)
	end
	m.Parent = folder
	settle(0.5)
	return m
end
local function words(): (string, string, boolean)
	local E = RunInteract.Elements()
	return E.Label.Text, E.Sub.Text, E.Panel.Visible
end
local function hint(): string
	local h = Hud.Elements().PurseHint
	return (h and h.Visible) and h.Text or ""
end
local function feedback(msg)
	C.fire("LootFeedback", msg)
	settle(0.2)
end

------------------------------------------------------------------------------------------
-- chest
------------------------------------------------------------------------------------------
local m = chest()
local label, sub, vis = words()
check(RunInteract.Priority() == "Chest" and vis, "chest in reach: the interact prompt shows it")
check(string.find(label, "not enough gold") ~= nil and string.find(sub, "54 team gold") ~= nil and string.find(sub, "need 24 more") ~= nil, "below: 54 vs 30 -> need 24 (" .. label .. " / " .. sub .. ")")
local cs = LootUI.ChestStatus(m)
check(cs.State == "Unaffordable" and cs.Price == 54 and cs.Balance == 30 and cs.Short == 24, "ChestStatus below: one price, one balance, shortfall from them")

-- the recording's frame: team 21, chest 54, personal run gold 9
setS("TeamRunGold", 21)
settle(0.3)
label, sub = words()
check(string.find(sub, "need 33 more") ~= nil and string.find(sub, "45") == nil, "recording frame: team 21 / chest 54 -> need 33, never the personal-gold 45 (" .. sub .. ")")
check(hint() == "NEXT CHEST 54" or hint() == "CHEST 54", "HUD hint shows the same price (" .. hint() .. ")")
check(Hud.Gold() == 21, "the HUD balance is the same team balance (" .. tostring(Hud.Gold()) .. ")")

setS("TeamRunGold", 54)
settle(0.3)
label, sub = words()
check(label == "Open chest" and string.find(sub, "54 team gold") ~= nil and string.find(sub, "team has 54") ~= nil, "equal: affordable (" .. sub .. ")")
setS("TeamRunGold", 100)
settle(0.3)
label, sub = words()
check(label == "Open chest" and string.find(sub, "team has 100") ~= nil, "above: affordable (" .. sub .. ")")

-- choosing: the live cards hold "Cards" (world input stays allowed)
UIState.SetHold("Cards", true)
settle(0.3)
local _, _, visC = words()
local before = #holds
RunInteract.Press()
settle(0.2)
RunInteract.Release()
settle(0.2)
check(not visC and LootUI.ChestStatus(m).State == "Choosing", "choosing: no chest prompt beside an open choice")
check(#holds == before, "choosing: no purchase starts")
UIState.SetHold("Cards", false)
settle(0.3)

-- opening -> pending
before = #holds
RunInteract.Press()
settle(0.15)
label, sub = words()
check(#holds == before + 1 and holds[#holds][2] == true and label == "Opening chest", "opening: one LootHold, 'Opening chest' (" .. label .. ")")
settle(0.5) -- past the 0.4 s hold, the server has not answered
label, sub = words()
check(label == "Opening chest..." and sub == "Waiting for the server", "pending: waits for the server (" .. label .. " / " .. sub .. ")")
RunInteract.Release()
settle(0.1)

-- claimed: the server's answer and attributes
m:SetAttribute("State", "Opened")
setS("TeamRunGold", 46)
setS("ChestCost", 73)
setS("TeamChestsBought", 2)
feedback({ Id = m:GetAttribute("LootId"), State = "Done", Paid = 54, Team = true, Next = 73 })
label, sub, vis = words()
check(vis and label == "Chest opened" and string.find(sub, "Paid 54 team gold") ~= nil and string.find(sub, "next chest 73") ~= nil, "claimed: the purchase and the next price apart (" .. label .. " / " .. sub .. ")")
check(hint() == "NEXT CHEST 73", "HUD: the raised price reads as the NEXT chest (" .. hint() .. ")")
UIState.SetHold("Cards", true) -- the chest's reward choice opens
settle(0.3)
_, _, vis = words()
check(not vis, "claimed + reward choice open: no chest prompt at all (no 'not enough gold' beside the choice)")
UIState.SetHold("Cards", false)
settle(3)
_, _, vis = words()
check(not vis, "an opened chest is no target once its claim line has gone")

-- failed (a refusal that is not about gold)
m = chest()
setS("TeamRunGold", 100)
feedback({ Id = m:GetAttribute("LootId"), State = "Cancel", Reason = "far" })
label, sub = words()
check(label == "Couldn't open the chest" and string.find(sub, "Too far away") ~= nil and string.find(sub, "try again") ~= nil, "failed: the server's reason, recoverable (" .. label .. " / " .. sub .. ")")
settle(3)
label = words()
check(label == "Open chest", "failed: back to the normal prompt afterwards (" .. label .. ")")

-- gold arriving while the key is held
setS("ChestCost", 73)
setS("TeamRunGold", 50)
m:SetAttribute("Price", 73)
settle(0.3)
before = #holds
RunInteract.Press() -- short: refused locally, the key stays held
settle(0.3)
check(#holds == before, "short while holding: no LootHold")
setS("TeamRunGold", 80) -- a kill lands
settle(0.4)
check(#holds == before + 1 and holds[#holds][1] == m:GetAttribute("LootId") and holds[#holds][2] == true, "the gold arrived while held: the hold starts once by itself")
settle(0.3)
check(#holds == before + 1, "...and only once")
RunInteract.Release()
settle(0.2)
m:Destroy()
settle(0.4)

------------------------------------------------------------------------------------------
-- revive
------------------------------------------------------------------------------------------
local pg = lp:FindFirstChildOfClass("PlayerGui")
local function reviveTexts(): string
	local out = {}
	for _, d in ipairs(pg:GetDescendants()) do
		if (d:IsA("TextLabel") or d:IsA("TextButton")) and d.Text ~= "" then
			local p: Instance? = d
			local shown = true
			while p and p ~= pg do
				if p:IsA("GuiObject") and not p.Visible then
					shown = false
					break
				end
				p = p.Parent
			end
			if shown then
				table.insert(out, d.Text)
			end
		end
	end
	return table.concat(out, " | ")
end
local function buyButton(): Instance?
	for _, d in ipairs(pg:GetDescendants()) do
		if d:IsA("TextLabel") and string.find(d.Text, "REVIVE  R%$") then
			local b = d:FindFirstAncestorWhichIsA("GuiButton")
			return b or d.Parent
		end
	end
	return nil
end
local prompts0 = #preview.marketPrompts()
check(string.find(reviveTexts(), "YOU FELL") == nil, "no offer: no revive overlay")
C.fire("ReviveOffer", { Seconds = 12, ProductId = 3716061270, HPShare = 0.5, Protect = 3, ClearRadius = 22, PerRun = 1 })
settle(0.6)
local t = reviveTexts()
check(string.find(t, "YOU FELL") ~= nil, "offer: the overlay shows")
check(string.find(t, "50%% HP") ~= nil and string.find(t, "3 s of protection") ~= nil and string.find(t, "Back where you fell") ~= nil, "offer: the real HP share, protection and place")
check(string.find(t, "Level, weapons and items are kept") ~= nil and string.find(t, "One paid revive per run") ~= nil, "offer: build kept, one per run")
check(string.find(t, "REVIVE  R%$%d") ~= nil, "offer: the platform price on REVIVE (" .. t .. ")")
check(#preview.marketPrompts() == prompts0, "offer: Roblox's dialog does NOT open by itself")
local b = buyButton()
check(b ~= nil, "REVIVE button found")
if b then
	preview.click(b)
	settle(0.3)
end
t = reviveTexts()
check(buys == 1 and #preview.marketPrompts() == prompts0, "REVIVE tap asks the server (ReviveBuy x" .. buys .. "), the client opens no dialog itself")
check(string.find(t, "WAITING") ~= nil and string.find(t, "Opening the Roblox purchase window") ~= nil, "requesting: waiting, not success")
C.fire("ReviveOffer", { State = "Prompting", Seconds = 90 })
settle(0.3)
t = reviveTexts()
check(string.find(t, "TIMER PAUSED") ~= nil and string.find(t, "Finish or cancel") ~= nil, "prompting: the timer waits")
C.fire("ReviveOffer", { State = "Cancelled", Seconds = 8 })
settle(0.3)
t = reviveTexts()
check(string.find(t, "Your run is unchanged") ~= nil and string.find(t, "REVIVE  R%$%d") ~= nil and string.find(t, "OFFER ENDS IN") ~= nil, "cancelled: neutral, REVIVE again, timer runs on")
C.fire("ReviveOffer", { State = "Failed", Reason = "The purchase window could not open. Try again.", Seconds = 7 })
settle(0.3)
t = reviveTexts()
check(string.find(t, "could not open") ~= nil, "failed: honest message")
C.fire("ReviveOffer", { State = "Pending", Seconds = 30 })
settle(0.3)
t = reviveTexts()
check(string.find(t, "Waiting for the server to revive you") ~= nil and string.find(t, "REVIVING") ~= nil and string.find(t, "YOU FELL") ~= nil, "pending: still the offer, waiting for the server (no success shown)")
local buys0 = buys
if b then
	preview.click(b)
	settle(0.3)
end
check(buys == buys0, "pending: REVIVE does nothing")
settle(4)
check(string.find(reviveTexts(), "YOU FELL") ~= nil, "pending: the client never closes it by its own timer")
C.fire("ReviveOffer", { Close = true, State = "Fulfilled" })
settle(0.4)
check(string.find(reviveTexts(), "YOU FELL") == nil, "fulfilled: the server's revive closes the offer")

preview.log(fails == 0 and "PASS transactions-ui-regression" or ("FAIL transactions-ui-regression: " .. fails .. " failed"))
