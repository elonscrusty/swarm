-- results: the victory screen over the arena (RunResult remote, as RunManager sends it).
local A = lib("arena")
local C = lib("common")
A.build({ enemies = 60, seconds = 900 })
C.settle(1)
C.setState({ Phase = "Results" })
C.fire("RunResult", { Won = true, Time = 900, Kills = 1874, Gold = 412, Level = 31, Damage = 286400, Arena = "Forest", NewBest = true, Unlocked = "Ruins", Seconds = 25 })
C.settle(3)
