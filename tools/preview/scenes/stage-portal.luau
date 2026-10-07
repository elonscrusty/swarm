-- stage-portal: stage 2 in the Forest, the hero just south of the portal while it charges
-- (portal "Charging" look, the HUD charge ring over it, stage pill "Summoning the boss
-- 60%"; the hero stands outside the ring). --set hint=off: the portal not revealed yet. The portal spot comes from MapBuilder.FindPortalSpot like a real run.
-- --set charge=0 shows the idle portal (no ring), --set look=Boss|Surge|Open other states,
-- --set charge=0 --set lock=95 the dormant portal ("The portal is dormant: 1:35").
-- The revealed portal (lock over) also shows the client beacon: the pillar, cap and
-- pulsing floor rings (PortalBeacon) in the state's colour.
local A = lib("arena")
local C = lib("common")
local charge = tonumber(preview.args.charge) or 0.6
local look = preview.args.look or (charge > 0 and "Charging" or "Idle")
A.build({ enemies = 50, seconds = 340, portal = true, portalState = look, portalCharge = charge, heroNearPortal = tonumber(preview.args.lock) and 6 or 13, stage = 2, lockLeft = tonumber(preview.args.lock), portalReveal = (tonumber(preview.args.lock) or 0) > 0 and 0 or 1, portalHint = (tonumber(preview.args.lock) or 0) <= 0 and preview.args.hint ~= "off" })
C.settle(2.5)
local Hud = C.try("require Hud", preview.client, "Hud")
local StageUI = C.try("require StageUI", preview.client, "StageUI")
local goal = Hud and Hud.Elements().StageGoal
preview.log("stage pill: " .. tostring(goal and goal.Text))
if StageUI and StageUI.Elements then
	local els = StageUI.Elements()
	preview.log(string.format("ring visible=%s label=%s", tostring(els.Ring and els.Ring.Visible), tostring(els.RingLabel and els.RingLabel.Text)))
end
