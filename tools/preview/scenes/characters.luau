-- characters: the lobby's character select screen (OpenPanel "Characters", as the server
-- sends it; the old lobby board prompt used the same remote).
local C = lib("common")
C.lobby()
C.startClient()
C.sendProfile()
C.settle(1)
C.fire("OpenPanel", "Characters")
C.settle(2.5)
