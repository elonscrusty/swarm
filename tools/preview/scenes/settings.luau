-- settings: taps the lobby's SETTINGS button (found by its text, so a redesigned lobby
-- keeps working as long as the button still says "Settings").
local C = lib("common")
C.lobby()
C.startClient()
C.sendProfile()
C.settle(1)
local button = C.findText("SETTINGS", "GuiButton")
if button then
	preview.click(button)
else
	preview.warn("settings scene: no button with the text SETTINGS")
end
C.settle(2)
