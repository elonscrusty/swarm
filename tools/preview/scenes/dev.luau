-- dev: the lobby with the DEV tools panel open (render with --studio so it exists).
--   --set tab=Profile|Run|Spawn|Items   the tab shown (default Profile)
local C = lib("common")
C.lobby()
C.startClient()
C.sendProfile()
C.settle(1.5)
local dev = C.findText("^%s*DEV%s*$", "GuiButton")
if dev then
	preview.click(dev)
else
	preview.note("dev scene: no DEV button (render with --studio)")
end
C.settle(0.5)
local tab = preview.args.tab
if tab and tab ~= "Profile" then
	local DevPanel = C.try("require DevPanel", preview.client, "DevPanel")
	if DevPanel and DevPanel.Open then
		DevPanel.Open(tab)
	end
end
C.settle(1)
