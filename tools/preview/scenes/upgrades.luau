-- upgrades: permanent gold upgrades + the Robux shop (OpenPanel "Upgrades"); --set tab=shop.
local C = lib("common")
C.lobby()
C.startClient()
C.sendProfile()
C.settle(1)
C.fire("OpenPanel", "Upgrades")
C.settle(2.5)
-- --set tab=shop: the Robux SHOP tab
if preview.args.tab == "shop" then
	local b = C.findText("^%s*SHOP%s*$", "GuiButton")
	if b then
		preview.click(b)
	else
		preview.warn("upgrades scene: no SHOP tab")
	end
	C.settle(1.5)
end
