-- party-quick-lines-layout: the party quick lines on screen (PartyLines, MenuParty, LobbyScreen),
-- for the phone/pc layout checks (check_layout.py). Other players are mock PartyState members.
--   --set view=panel   the PARTY screen with a party of 2: the six lines under the columns and the feed
--   --set view=home    the home screen with the SAY chip and its popup open
--   --set view=solo    the PARTY screen with no party: no quick-line strip, no SAY chip
-- Prints PASS / FAIL lines too.
local C = lib("common")
C.lobby()
local Players = game:GetService("Players")
local me = Players.LocalPlayer
local view = preview.args.view or "panel"
local ava = preview.addPlayer("Ava", 2)
C.startClient()
C.sendProfile()
C.settle(1)

local fails = 0
local function check(ok: any, label: string)
	if not ok then
		fails += 1
	end
	preview.log((ok and "PASS " or "FAIL ") .. label)
end

local PartyLines = preview.client("PartyLines")
local Config = C.shared("Config")
if view ~= "solo" then
	me:SetAttribute("PartyId", 1)
	ava:SetAttribute("PartyId", 1)
	C.fire("PartyState", {
		LeaderId = me.UserId,
		Members = { { UserId = me.UserId, Name = me.DisplayName }, { UserId = 2, Name = "Ava", Ready = true } },
		Max = 3,
		Invites = {},
		Sent = {},
	})
	C.settle(0.5)
	-- a few lines in the feed
	C.fire("PartySay", { FromId = 2, FromName = "Ava", Index = 1 })
	C.fire("PartySay", { FromId = me.UserId, FromName = me.DisplayName, Index = 2 })
	C.fire("PartySay", { FromId = 2, FromName = "Ava", Index = 5 })
	C.settle(0.5)
	check(#PartyLines.Feed() == 3, "three lines in the feed")
else
	C.fire("PartyState", { LeaderId = 0, Members = {}, Max = 3, Invites = {}, Sent = {} })
	C.settle(0.5)
end

local LobbyScreen = preview.client("LobbyScreen")
if view == "panel" or view == "solo" then
	LobbyScreen.Show("Party")
	C.settle(1.5)
	local row = preview.findGui(function(g)
		return g.Name == "QuickLines" and g:IsA("GuiObject") and preview.isShown(g)
	end)
	if view == "panel" then
		check(row[1] ~= nil, "the quick-line row shows on the PARTY screen")
		for _, line in ipairs(Config.PartyQuickLines.Lines) do
			local b = C.findText("^" .. string.upper(string.gsub(line, "%p", "%%%0")) .. "$", "TextButton")
			check(b ~= nil and preview.isShown(b), "button " .. line .. " is on screen")
		end
		local feedLine = preview.findGui(function(g)
			return g:IsA("TextLabel") and string.find(g.Text, "Ava: Ready%?") ~= nil and preview.isShown(g)
		end)
		check(feedLine[1] ~= nil, "the party feed shows Ava's line")
	else
		check(row[1] == nil, "no quick-line row without a party")
	end
else
	LobbyScreen.Show("Home")
	C.settle(1)
	local chip = preview.findGui(function(g)
		return g.Name == "SayChip" and g:IsA("GuiObject") and preview.isShown(g)
	end)
	check(chip[1] ~= nil, "the SAY chip shows on the home screen in a party")
	if chip[1] then
		preview.click(chip[1])
		C.settle(1)
		local pop = preview.findGui(function(g)
			return g.Name == "SayPopup" and g:IsA("GuiObject") and preview.isShown(g)
		end)
		check(pop[1] ~= nil, "a tap on SAY opens the popup")
		local go = preview.findGui(function(g)
			return g:IsA("TextButton") and g.Name == "Line2" and preview.isShown(g)
		end)
		check(go[1] ~= nil, "the popup has the lines")
	end
end
preview.log(fails == 0 and "ALL PASS" or (fails .. " FAIL"))
