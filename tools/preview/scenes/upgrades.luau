-- upgrades: permanent gold upgrades + the Robux shop (OpenPanel "Upgrades").
local C = lib("common")
C.lobby()
C.startClient()
C.sendProfile()
C.settle(1)
C.fire("OpenPanel", "Upgrades")
C.settle(2.5)
