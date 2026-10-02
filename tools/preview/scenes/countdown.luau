-- countdown: a Duo countdown started by this player, a teammate joined (START NOW shows).
local C = lib("common")
C.lobby()
C.startClient()
C.sendProfile()
C.settle(1)
local player = game:GetService("Players").LocalPlayer
C.setState({ Phase = "Countdown", Mode = "Duo", Countdown = 7, Joined = 2, MaxJoin = 2, JoinedNames = player.Name .. ", Ava", Starter = player.UserId })
C.fire("OpenPanel", "Joined")
C.settle(2)
