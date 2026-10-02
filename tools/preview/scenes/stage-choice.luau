-- stage-choice: the portal of stage 2 is open (portal "Open" look) and the choice panel
-- is up: NEXT STAGE / RETURN TO LOBBY, the run so far, the countdown (PortalOffer remote
-- and the SwarmState attributes exactly as StageManager sends them).
local A = lib("arena")
local C = lib("common")
local s = A.build({ enemies = 0, swarm = false, seconds = 512, portal = true, portalState = "Open", heroNearPortal = 14, stage = 2, stagePhase = "Open", choiceLeft = 11 })
C.settle(1)
C.fire("PortalOffer", { Stage = 2, StagesCleared = 2, NextStage = 3, NextArena = "Forest", ReturnBonus = 250, Gold = 486, Kills = 1312, Level = 22, Time = 512, Seconds = 11, Group = false })
C.settle(2)
local _ = s
