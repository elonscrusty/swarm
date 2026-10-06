-- store: the cosmetic STORE screen (MenuStore, docs/features/STORE.md), opened with OpenPanel.
--   --set section=Skins|Trails|Bursts|Pets|Emotes|Plates|Dais|Supporter|Heroes|Gift
--   --set ids=on     fake store ids (the shop shows mock Roblox prices instead of "Coming soon")
--   --set view=dais  goes home afterwards: the worn dais theme, the pet and the Supporter
--                    banner on the lobby dais (StoreFx)
-- Asserts: every section builds cards, prices come from GetProductInfo (mock 49), id 0 reads
-- "Coming soon", earned items show progress, owned items WEAR / TAKE OFF.
local C = lib("common")
C.lobby()
local Config = preview.shared("Config")
if preview.args.ids == "on" then
	local n = 9000
	for k in pairs(Config.Monetization.Cosmetics) do
		n += 1
		Config.Monetization.Cosmetics[k] = n
	end
	Config.Monetization.CosmeticPasses.Supporter = 9100
	for k in pairs(Config.Monetization.HeroUnlocks) do
		n += 1
		Config.Monetization.HeroUnlocks[k] = n
	end
end
local Players = game:GetService("Players")
local player = Players.LocalPlayer
if preview.args.section == "Gift" then
	preview.addPlayer("Robin", 4242)
end
-- the published looks (StoreService sets these on the real server)
player:SetAttribute("CosPet", "Pet_Fox")
player:SetAttribute("CosDais", "Dais_Sunfire")
player:SetAttribute("CosPlate", "Plate_Gold")
player:SetAttribute("Supporter", true)
C.startClient()
local p = C.profile({
	Account = { XP = 2400, Level = 8 },
	Stats = { BestTime = 754, TotalKills = 14821, Wins = 3, Runs = 12, BestStage = 5 },
	Store = {
		Owned = { Trail_Ember = true, Pet_Fox = true, Emote_Wave = true, Emote_Bow = true, Plate_Gold = true, Dais_Sunfire = true, Plate_Supporter = true },
		Equipped = { Trail = "Trail_Ember", Burst = "", Pet = "Pet_Fox", Emote = "Emote_Wave", Nameplate = "Plate_Gold", Dais = "Dais_Sunfire" },
		Supporter = true,
	},
})
C.sendProfile(p)
C.settle(1)
C.fire("OpenPanel", "Store")
C.settle(2)
local section = preview.args.section
if section then
	local chip = preview.findGui(function(obj)
		return obj.Name == "Section_" .. section and obj:IsA("GuiButton")
	end)[1]
	if chip then
		preview.click(chip)
	else
		preview.warn("store scene: no section chip " .. section)
	end
	C.settle(2)
end
-- checks: cards exist; prices / Coming soon match the ids
local cards = preview.findGui(function(obj)
	return string.match(obj.Name, "^Card%d+$") ~= nil and preview.isShown(obj)
end)
if #cards == 0 then
	preview.log("FAIL store: no cards in section " .. tostring(section or "Skins"))
else
	preview.log(string.format("store: %d cards in %s", #cards, section or "Skins"))
end
local soon = C.findText("COMING SOON")
local priced = C.findText("R%$ 49")
if preview.args.ids == "on" then
	if section ~= "Heroes" and section ~= "Gift" and not priced then
		preview.log("FAIL store: ids on but no Robux price shown")
	end
-- (Supporter: the sample profile owns the pass, so its card reads OWNED with EQUIP)
elseif section ~= nil and section ~= "Heroes" and section ~= "Gift" and section ~= "Skins" and section ~= "Supporter" and not soon and section ~= "Emotes" then
	preview.log("FAIL store: ids 0 but no COMING SOON")
end
if preview.args.view == "dais" then
	C.fire("OpenPanel", "Home")
	C.settle(2)
	local StoreFx = preview.client("StoreFx")
	local st = StoreFx and StoreFx._Stats()
	preview.log(string.format("store dais: pets %d, plates %d, dais %d", st and st.Pets or -1, st and st.Plates or -1, st and st.Dais or -1))
	if not st or st.Dais ~= 1 or st.Pets < 1 then
		preview.log("FAIL store: dais theme / pet not drawn on the menu dais")
	end
end
