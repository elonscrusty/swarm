-- countdown: a Duo countdown started by this player, a teammate joined (START NOW shows),
-- with the starter's curses on show (--set curses=Frenzy,Horde; --set curses=none: none).
-- --set endless=on: the starter switched ENDLESS on (the panel's ENDLESS line).
local C = lib("common")
C.lobby()
C.startClient()
C.sendProfile()
C.settle(1)
local player = game:GetService("Players").LocalPlayer
local curses = preview.args.curses or "Frenzy,Horde"
if curses == "none" then
	curses = ""
end
local endless = preview.args.endless == "on"
C.setPlayer({ Curses = curses, Endless = endless })
C.setState({ Phase = "Countdown", Mode = "Duo", Countdown = 7, Joined = 2, MaxJoin = 2, JoinedNames = player.Name .. ", Ava", Starter = player.UserId, Curses = curses, Endless = endless })
C.fire("OpenPanel", "Joined")
C.settle(2)
