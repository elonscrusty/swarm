-- run-intro: the stage objective card (client RunIntro) right after a stage begins:
-- STAGE N · arena, OPEN THE PORTAL / BEFORE THE SWARM GROWS TOO STRONG, and on stage 1
-- the three icon hints (find the portal, stand in its ring, beat the boss).
--   --set stage=N       the stage that begins (default 1; 2+ shows the short card)
--   --set first=on      a player's first run (profile TutorialDone = false): the long card
--   --set at=SECONDS    how long after the stage begins to capture (default 0.8)
--   --set endless=on    an Endless run (ENDLESS · STAGE N)
local A = lib("arena")
local C = lib("common")
local stage = tonumber(preview.args.stage) or 1
local at = tonumber(preview.args.at) or 0.8
local s = A.build({ enemies = 40, seconds = stage == 1 and 3 or 300, portal = true })
if preview.args.first == "on" then
	C.sendProfile(C.profile({ TutorialDone = false, SeenTips = {} }))
end
C.settle(0.3)
-- the stage begins while the client watches (like StageManager.buildStage)
C.setState({
	Stage = stage,
	StagePhase = "Explore",
	StageArena = s.Config and s.Config.Arenas.Forest and s.Config.Arenas.Forest.DisplayName or "Forest",
	StageBoss = stage == 1 and "Scorpion Queen" or "Briar Sentinel",
	Endless = preview.args.endless == "on",
	PortalPos = s.portal and s.portal.Pos or nil,
	PortalHint = false,
	PortalReveal = 0,
	PortalCharge = 0,
	PortalLockLeft = 0,
})
C.settle(at)
