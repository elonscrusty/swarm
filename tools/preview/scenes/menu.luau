-- menu: the lobby world at dusk, the lobby home screen, camera at the MenuCamera part.
--   --set save=failing|memory   the server says progress isn't being saved (SaveStatus):
--                               the lobby's save notice
local C = lib("common")
C.lobby()
C.startClient()
C.sendProfile()
if preview.args.save then
	C.setPlayer({ SaveStatus = preview.args.save })
end
C.settle(3)
