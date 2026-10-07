-- revive-thanks-layout: the THANKS! button (client ReviveThanks.lua, Config.Features.ReviveThanks)
-- over a Duo run's HUD with the touch controls, the team list and the ULT button, for the
-- phone/pc layout checks (check_layout.py). The reviver has a long display name.
--   --set covered=on   a panel is open: the button must stay hidden
-- Prints PASS / FAIL lines too.
local A = lib("arena")
local C = lib("common")
local s = A.build({ enemies = 40 })
C.settle(0.5)
local fails = 0
local function check(ok: any, label: string)
	if not ok then
		fails += 1
	end
	preview.log((ok and "PASS " or "FAIL ") .. label)
end

C.setState({ Mode = "Duo", Participants = 2 })
local name = "MaximilianTheVeryLongName"
local mate = preview.addPlayer(name, 2)
local model = C.try("BuildCharacter", s.ModelBuilder.BuildCharacter, "Mage", "Default")
if model then
	model.Name = name
	model:PivotTo(CFrame.new(s.centre + Vector3.new(6, 3.5, 0)))
	model.Parent = workspace
	mate.Character = model
end
mate:SetAttribute("InRun", true)
mate:SetAttribute("CharacterId", "Mage")
mate:SetAttribute("Alive", true)
mate:SetAttribute("HP", 90)
mate:SetAttribute("MaxHP", 110)
C.settle(0.5)

local RTc = preview.client("ReviveThanks")
local Config = C.shared("Config")
check(Config.Features.ReviveThanks == true, "ReviveThanks switch on by default")
check(RTc.Receive({ Id = 1, Seconds = Config.Revive.ThanksSeconds, FromName = name }) == true, "the client takes the offer")
if preview.args.covered == "on" then
	-- a panel owns the screen: the button must hide (UIState / FeatureHud)
	preview.client("UIState").Open("Results", { Hide = function() end })
	C.settle(0.4)
	check(RTc.Showing() == false, "the button hides under a panel")
else
	C.settle(0.6)
	check(RTc.Showing() == true, "the THANKS! button is on screen")
	local b = preview.findGui(function(g)
		return g.Name == "ThanksButton" and g:IsA("GuiObject") and preview.isShown(g)
	end)
	check(b[1] ~= nil, "the button is a shown GUI object")
end
preview.log(fails == 0 and "ALL PASS" or (fails .. " FAIL"))
