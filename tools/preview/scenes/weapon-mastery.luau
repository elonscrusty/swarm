-- weapon-mastery: the WEAPON MASTERY menu (feature 15, docs/features/LOBBY.md), opened from
-- the MORE screen's row: one row per weapon with its kills, the next milestone and the glow
-- swatches (own colour + each milestone; locked ones with a lock, the worn one ringed).
--   --set view=more    stop on the MORE screen (the new COURTYARD / WEAPON MASTERY rows)
local C = lib("common")
C.lobby()
C.startClient()
C.sendProfile(C.profile({ Features = { WeaponMastery = { Whip = 1400, ["Glow:Whip"] = 2, MagicOrb = 260, ["Glow:MagicOrb"] = 1, Knives = 40, Garlic = 3100, Lightning = 9000, ["Glow:Lightning"] = 4 } } }))
C.settle(1)
preview.client("LobbyScreen").Show("More")
C.settle(1)
local gui = game:GetService("Players").LocalPlayer.PlayerGui
local row = gui:FindFirstChild("WeaponMastery", true)
preview.log((row and "PASS" or "FAIL") .. " WEAPON MASTERY row on MORE")
preview.log((gui:FindFirstChild("Courtyard", true) and "PASS" or "FAIL") .. " COURTYARD row on MORE")
if preview.args.view == "more" or not row then
	return
end
preview.click(row)
C.settle(0.8)
local ui = gui:FindFirstChild("WeaponMasteryUI")
preview.log(((ui and ui.Enabled) and "PASS" or "FAIL") .. " the menu opens")
