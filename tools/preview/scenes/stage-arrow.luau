-- stage-arrow: stage 2 at the arena centre right after the portal reveal: the stage pill
-- ("STAGE 2 · Find the portal"), the edge-of-screen arrow with the distance pointing at the
-- portal (off screen), the minimap marker pinned to the map's edge and the beacon pillar
-- rising over the portal in the distance. --set reveal=0 shows the pre-reveal HUD.
local A = lib("arena")
local C = lib("common")
local reveal = tonumber(preview.args.reveal) or 1
A.build({ enemies = 80, seconds = 400, portal = true, portalState = "Idle", stage = 2, portalHint = true, portalReveal = reveal })
C.settle(2.5)
