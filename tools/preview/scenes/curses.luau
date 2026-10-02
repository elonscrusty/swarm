-- curses: the lobby CURSES screen (run modifiers). The pick comes from the player
-- attribute "Curses" (as RunModifiers sets it).
--   --set curses=Frenzy,Horde   what is picked (default Frenzy,GlassCannon; "none" = nothing)
--   --set countdown=other       someone else's Duo countdown is running (the note)
local C = lib("common")
C.lobby()
C.startClient()
C.sendProfile()
local pick = preview.args.curses or "Frenzy,GlassCannon"
if pick == "none" then
	pick = ""
end
C.setPlayer({ Curses = pick })
C.settle(1)
if preview.args.countdown == "other" then
	C.setState({ Phase = "Countdown", Mode = "Duo", Countdown = 8, Joined = 1, MaxJoin = 2, JoinedNames = "Ava", Starter = 99, Curses = "Horde" })
end
local button = C.findText("^%s*CURSES%s*$", "GuiButton")
if button then
	preview.click(button)
else
	preview.warn("curses scene: no CURSES button")
end
C.settle(2)
