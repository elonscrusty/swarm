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
-- --set panel=on (audit J-05 regression): a level-up panel opens at once over the stage
-- card (banked levels open the moment a travel ends). The card's clock must wait behind
-- the covering panel and the card must still be shown after the panel closes.
if preview.args.panel == "on" then
	local RunIntro = preview.client("RunIntro")
	local fails = 0
	local function check(cond, label)
		preview.log((cond and "PASS " or "FAIL ") .. label)
		if not cond then fails += 1 end
	end
	check(RunIntro.Active(), "the stage card shows when the stage begins")
	C.fire("LevelUpOffer", {
		OfferId = 1, Group = false, Choices = { { Kind = "Weapon", Id = "Whip", Level = 2, Text = "+damage" } },
		Rerolls = 0, Skips = 0, RerollsMax = 0, SkipsMax = 0, SkipGold = 10, Seconds = 25, Level = 5,
		Pending = 1, PanelId = 1, BatchRemaining = 1, BatchTotal = 1,
	})
	C.setState({ Frozen = true, LevelUpPause = true })
	C.settle(4) -- longer than the later-stage card (2.4 s) and the stage-1 card (3.6 s)
	check(RunIntro.Active(), "the card waits behind the covering level-up panel")
	C.fire("LevelUpClose")
	C.setState({ Frozen = false, LevelUpPause = false })
	C.settle(0.6)
	check(RunIntro.Active(), "the card is still shown after the panel closes")
	C.settle(5)
	check(not RunIntro.Active(), "the card then closes on its own timer")
	preview.log(fails == 0 and "run-intro panel: ALL PASS" or ("run-intro panel: " .. fails .. " FAIL"))
end
