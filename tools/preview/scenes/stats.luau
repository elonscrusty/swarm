-- stats: opens the lobby Stats screen if the UI has one (a button saying "STATS");
-- otherwise renders the home screen and says so.
local C = lib("common")
C.lobby()
C.startClient()
C.sendProfile()
C.settle(1)
local button = C.findText("^%s*STATS%s*$", "GuiButton") or C.findText("STATS", "GuiButton")
if button then
	preview.click(button)
	C.settle(2)
else
	preview.note("stats scene: this UI has no Stats button yet (showing the home screen)")
	preview.metrics.skipped = "no Stats screen"
	C.settle(1)
end
