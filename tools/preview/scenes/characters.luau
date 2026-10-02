-- characters: the lobby's character select screen (OpenPanel "Characters", as the server
-- sends it; the old lobby board prompt used the same remote).
--   --set inspect=Ranger   inspect another character (taps its row)
--   --set owned=all        every character owned (QueenSlayer done: the Ranger unlocked)
local C = lib("common")
C.lobby()
C.startClient()
local overrides = nil
if preview.args.owned == "all" then
	overrides = {
		OwnedCharacters = { Knight = true, Mage = true, Rogue = true, Priest = true, Ranger = true },
		Achievements = { Progress = { QueenSlayer = 1 }, Unlocked = { QueenSlayer = 1 } },
	}
else
	overrides = { Achievements = { Progress = { Survivor5 = 212 }, Unlocked = {} } }
end
C.sendProfile(C.profile(overrides))
C.settle(1)
C.fire("OpenPanel", "Characters")
C.settle(1)
if preview.args.inspect then
	local row = C.findText("^%s*" .. string.upper(preview.args.inspect) .. "%s*$", "GuiButton")
	if row then
		preview.click(row)
	else
		preview.note("characters scene: no row for " .. preview.args.inspect)
	end
end
C.settle(2)
