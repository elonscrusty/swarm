-- stage-arrow: stage 2 at the arena centre after the hint time: the stage pill ("STAGE 2 ·
-- Find the portal") and the edge-of-screen arrow pointing at the portal (off screen).
local A = lib("arena")
local C = lib("common")
A.build({ enemies = 80, seconds = 400, portal = true, portalState = "Idle", stage = 2, portalHint = true })
C.settle(2.5)
