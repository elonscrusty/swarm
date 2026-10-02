-- track: the lobby TRACK screen (account level, XP bar, cosmetic rewards to wear).
--   --set xp=N   total account XP (default 9400: level 17, some rewards earned)
--   --set ring=Frost --set frame=Bronze   worn cosmetics (also shown on the dais / portrait)
local C = lib("common")
C.lobby()
C.startClient()
C.sendProfile(C.profile({
	Account = { XP = tonumber(preview.args.xp) or 9400 },
	Title = "Swarmbreaker",
	NameColor = "Azure",
	Ring = preview.args.ring or "Frost",
	Frame = preview.args.frame or "Bronze",
}))
C.settle(1)
if preview.args.home ~= "on" then
	local button = C.findText("^%s*TRACK%s*$", "GuiButton")
	if button then
		preview.click(button)
	else
		preview.warn("track scene: no TRACK button")
	end
end
C.settle(2)
