-- pause: the in-run menu (the HUD's pause button; UIBuilder.OpenPause when present).
--   --set coop=on       a two-player run (Participants 2): the live drawer, "Game not paused"
--   --set confirm=on    after opening, press LEAVE RUN once: the leave question
--   --set view=settings open SETTINGS from the drawer (the existing settings screen)
local A = lib("arena")
local C = lib("common")
A.build({ enemies = 90 })
if preview.args.coop == "on" then
	C.setState({ Participants = 2 })
end
C.settle(1.5)
local UIBuilder = C.try("require UIBuilder", preview.client, "UIBuilder")
if UIBuilder and type(UIBuilder.OpenPause) == "function" then
	C.try("UIBuilder.OpenPause", UIBuilder.OpenPause)
else
	local b = C.findText("^II$", "GuiButton") or C.findText("PAUSE", "GuiButton")
	if b then
		preview.click(b)
	else
		preview.warn("pause scene: no pause entry point found")
	end
end
C.settle(1.5)
if preview.args.confirm == "on" then
	local leave = C.findText("^LEAVE RUN$", "GuiButton")
	if leave then
		preview.click(leave)
	else
		preview.warn("pause scene: no LEAVE RUN button")
	end
	C.settle(0.6)
elseif preview.args.view == "settings" then
	local s = C.findText("^SETTINGS$", "GuiButton")
	if s then
		preview.click(s)
	else
		preview.warn("pause scene: no SETTINGS button")
	end
	C.settle(0.8)
end
