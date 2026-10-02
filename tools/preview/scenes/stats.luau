-- stats: opens the lobby Stats screen if the UI has one (a button saying "STATS");
-- otherwise renders the home screen and says so.
--   --set tab=achievements   the ACHIEVEMENTS tab (a profile with some done, some partway)
local C = lib("common")
C.lobby()
C.startClient()
C.sendProfile(C.profile({
	Achievements = {
		Progress = { Survivor5 = 300, Survivor10 = 482, QueenSlayer = 1, Lifesaver = 1, Veteran = 22, MageClear = 1 },
		Unlocked = { Survivor5 = 1, QueenSlayer = 1, MageClear = 1 },
	},
	Title = "",
	NameColor = "Arcane",
	OwnedCharacters = { Knight = true, Mage = true, Ranger = true },
}))
C.settle(1)
local button = C.findText("^%s*STATS%s*$", "GuiButton") or C.findText("STATS", "GuiButton")
if button then
	preview.click(button)
	C.settle(1)
	if preview.args.tab == "achievements" then
		local tab = C.findText("^%s*ACHIEVEMENTS%s*$", "GuiButton")
		if tab then
			preview.click(tab)
		else
			preview.note("stats scene: no ACHIEVEMENTS tab")
		end
	end
	C.settle(2)
else
	preview.note("stats scene: this UI has no Stats button yet (showing the home screen)")
	preview.metrics.skipped = "no Stats screen"
	C.settle(1)
end
