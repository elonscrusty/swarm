-- bugreport: the REPORT A BUG form over the pause menu (BugReportUI), with some text typed.
--   --set result=fail   the server's "could not be saved" answer under the text
local A = lib("arena")
local C = lib("common")
A.build({ enemies = 60 })
C.settle(1)
local UIBuilder = C.try("require UIBuilder", preview.client, "UIBuilder")
if UIBuilder then
	C.try("UIBuilder.OpenPause", UIBuilder.OpenPause)
end
C.settle(0.4)
local button = C.findText("REPORT A BUG", "GuiButton")
if button then
	preview.click(button)
else
	preview.warn("bugreport scene: no REPORT A BUG button")
end
C.settle(0.3)
local box = preview.findGui(function(obj)
	return obj.Name == "ReportText"
end)[1]
if box then
	box.Text = "The portal didn't open after I killed the boss on stage 2. I stood in the circle for a while and nothing happened."
end
if preview.args.result == "fail" then
	local send = C.findText("^SEND$", "GuiButton")
	if send then
		preview.click(send)
	end
	C.settle(0.2)
	C.fire("BugReportResult", { Ok = false, Message = "Report could not be saved: saving is offline on this server." })
end
C.settle(1)
