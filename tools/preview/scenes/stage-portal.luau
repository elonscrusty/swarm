-- stage-portal: stage 2 in the Forest, the hero just south of the portal while it charges
-- (portal "Charging" look, the HUD charge ring over it, stage pill "Opening the portal
-- 60%"). The portal spot comes from MapBuilder.FindPortalSpot like a real run.
-- --set charge=0 shows the idle portal (no ring), --set look=Boss|Surge|Open other states,
-- --set charge=0 --set lock=95 the dormant portal ("The portal is dormant: 1:35").
local A = lib("arena")
local C = lib("common")
local charge = tonumber(preview.args.charge) or 0.6
local look = preview.args.look or (charge > 0 and "Charging" or "Idle")
A.build({ enemies = 50, seconds = 340, portal = true, portalState = look, portalCharge = charge, heroNearPortal = tonumber(preview.args.lock) and 6 or 13, stage = 2, lockLeft = tonumber(preview.args.lock) })
C.settle(2.5)
