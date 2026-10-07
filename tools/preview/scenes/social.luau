-- social: the next-batch lobby pieces (docs/next/STARTER_BUNDLE.md, GROUP_BONUS.md,
-- INVITE_REWARDS.md) with mock ids / attributes, for screenshots and the phone layout checks
-- (check_layout.py):
--   --set screen=Home|Starter|Group|Invite|Store|More   (default Home: the Starter Bundle card)
--   --set owned=on      the bundle is owned (card gone, Starter screen says OWNED)
--   --set member=on     a group member (JOIN OUR GROUP status line, plate star)
-- The product / group ids ship as 0; this scene sets fake ones on the client only.
local C = lib("common")
C.lobby()
C.startClient()
local Config = C.shared("Config")
Config.Monetization.StarterBundle = 9301
Config.Group.Id = 4242
local owned = preview.args.owned == "on"
C.setPlayer({
	StarterOffer = not owned,
	StarterOwned = owned,
	StarterEnds = os.time() + 6 * 86400 + 3600,
	GroupMember = preview.args.member == "on",
	Recruits = 2,
})
local p = C.profile()
C.sendProfile(p)
C.settle(1)
local Lobby = preview.client("LobbyScreen")
local screen = preview.args.screen or "Home"
Lobby.Show(screen, screen == "Store" and "Skins" or nil)
C.settle(1)
assert(Lobby.Current() == screen, "the screen must open: " .. screen)
if screen == "Home" then
	local card = C.findText("^STARTER BUNDLE$", "TextButton")
	if owned then
		assert(not card or not preview.isShown(card), "an owned bundle shows no home card")
	else
		assert(card and preview.isShown(card), "the Starter Bundle card shows on the home screen")
	end
end
preview.log("PASS social screen " .. screen .. " opened")
