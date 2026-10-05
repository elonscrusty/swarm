-- characters: the lobby's character select screen (OpenPanel "Characters", as the server
-- sends it; the old lobby board prompt used the same remote).
--   --set inspect=Ranger   inspect another character (taps its row)
--   --set owned=all        every character owned (the hero unlock achievements done)
--   --set mastery=open     tap UPGRADE <HERO> (Hero Mastery rows under the mastery block)
--   --set favourites=open  HEROPOWER: tap FAVOURITES (the weapon / passive grid), Knight at
--                          mastery 6 (second skill unlocked) with two favourites marked
local C = lib("common")
C.lobby()
C.startClient()
local overrides = nil
if preview.args.owned == "all" then
	overrides = {
		OwnedCharacters = { Knight = true, Mage = true, Rogue = true, Priest = true, Ranger = true, Alchemist = true, Engineer = true, Necromancer = true, Archer = true, Bard = true, Golem = true },
		Achievements = {
			Progress = { QueenSlayer = 1, DeepDelver = 4, FieldEngineer = 3, Reaper = 500 },
			Unlocked = { QueenSlayer = 1, DeepDelver = 1, FieldEngineer = 1, Reaper = 1 },
		},
	}
else
	-- part-way to the hero unlocks (progress shows on the locked heroes)
	overrides = { Achievements = { Progress = { Survivor5 = 212, DeepDelver = 2, FieldEngineer = 1, Reaper = 318 }, Unlocked = {} } }
end
if preview.args.favourites == "open" then
	overrides.Heroes = { Knight = { XP = 3000, Runs = 4 } }
	overrides.Features = { Presets = { List = { { Hero = "Knight", Weapons = { "Whip", "MagicOrb" }, Passives = {} } }, Active = { Knight = 1 } } }
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
if preview.args.mastery == "open" then
	local hits = preview.findGui(function(g) return g:IsA("GuiButton") and g.Name == "MasteryUpgrade" end)
	if hits[1] then
		preview.click(hits[1])
		C.settle(1)
	else
		preview.note("characters scene: no MasteryUpgrade button")
	end
end
if preview.args.favourites == "open" then
	local hits = preview.findGui(function(g) return g:IsA("GuiButton") and g.Name == "Favourites" end)
	if hits[1] then
		preview.click(hits[1])
		C.settle(1)
		-- scroll the details panel down to the grid
		local scroll = preview.findGui(function(g) return g:IsA("ScrollingFrame") and g.Name == "Scroll" and g.Parent and g.Parent.Parent and g.Parent.Parent.Name == "Details" end)[1]
		local grid = preview.findGui(function(g) return g.Name == "FavouriteGrid" end)[1]
		if scroll and grid then
			local y = grid.AbsolutePosition.Y - scroll.AbsolutePosition.Y + scroll.CanvasPosition.Y
			scroll.CanvasPosition = Vector2.new(0, math.max(0, y - 120))
			C.settle(0.5)
		end
	else
		preview.note("characters scene: no Favourites button")
	end
end
