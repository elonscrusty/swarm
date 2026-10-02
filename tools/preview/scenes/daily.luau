-- daily: the lobby DAILY CHALLENGE screen (today's route, curses, bonus, your attempt).
--   --set used=on   today's scored attempt is used (score shown, PRACTICE button)
local C = lib("common")
C.lobby()
C.startClient()
local CurseData = C.shared("CurseData")
local day = CurseData and CurseData.DayOf(os.time()) or 0
local used = preview.args.used == "on"
C.setState({ DailyDay = day })
C.sendProfile(C.profile({
	Daily = {
		Day = day,
		Used = used,
		Score = used and CurseData.DailyScore(3, 552, 700) or 0,
		Plays = used and 1 or 0,
		BestScore = CurseData.DailyScore(4, 801, 900),
		BestDay = day - 3,
	},
	Account = { XP = 2350 },
}))
C.settle(1)
local button = C.findText("^%s*DAILY", "GuiButton")
if button then
	preview.click(button)
else
	preview.warn("daily scene: no DAILY button")
end
C.settle(2)
