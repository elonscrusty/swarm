-- stage-choice: the portal of stage 2 is open (portal "Open" look) and the choice panel
-- is up: NEXT STAGE / RETURN TO LOBBY, the run so far, the countdown (PortalOffer remote
-- and the SwarmState attributes exactly as StageManager sends them).
-- --set endless=on: an Endless run on stage 9 (NEXT STAGE only; the HUD pill "ENDLESS · STAGE 9").
local A = lib("arena")
local C = lib("common")
local endless = preview.args.endless == "on"
local stage = endless and 9 or 2
local s = A.build({ enemies = 0, swarm = false, seconds = 512, portal = true, portalState = "Open", heroNearPortal = 14, stage = stage, stagePhase = "Open", choiceLeft = 11 })
C.setState({ Endless = endless })
C.settle(1)
C.fire("PortalOffer", { Endless = endless, CountsAsWin = not endless, Stage = stage, StagesCleared = stage, NextStage = stage + 1, NextArena = "Forest", ReturnBonus = endless and 0 or 250, Gold = 486, Kills = 1312, Level = 22, Time = 512, Seconds = 11, Group = false })
C.settle(2)
local _ = s
