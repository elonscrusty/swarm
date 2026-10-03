-- characters: the lobby's character select screen (OpenPanel "Characters", as the server
-- sends it; the old lobby board prompt used the same remote).
--   --set inspect=Ranger   inspect another character (taps its row)
--   --set owned=all        every character owned (the hero unlock achievements done)
local C = lib("common")
C.lobby()
C.startClient()
local overrides = nil
if preview.args.owned == "all" then
	overrides = {
		OwnedCharacters = { Knight = true, Mage = true, Rogue = true, Priest = true, Ranger = true, Alchemist = true, Engineer = true, Necromancer = true },
		Achievements = {
			Progress = { QueenSlayer = 1, DeepDelver = 4, FieldEngineer = 3, Reaper = 500 },
			Unlocked = { QueenSlayer = 1, DeepDelver = 1, FieldEngineer = 1, Reaper = 1 },
		},
	}
else
	-- part-way to the hero unlocks (progress shows on the locked heroes)
	overrides = { Achievements = { Progress = { Survivor5 = 212, DeepDelver = 2, FieldEngineer = 1, Reaper = 318 }, Unlocked = {} } }
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
if preview.args.skin then
	local hits = preview.findGui(function(g) return g:IsA("TextButton") and g.Name == preview.args.skin and g.Parent.Name == "Swatches" end)
	if hits[1] then preview.click(hits[1]); C.settle(1) end
end
