-- pause: the in-run pause menu (the HUD's pause button; UIBuilder.OpenPause when present).
local A = lib("arena")
local C = lib("common")
A.build({ enemies = 90 })
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
