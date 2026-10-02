-- party: the lobby PARTY button and screen (MenuParty) from PartyState / PartyInvite.
-- Other players on the server are preview.addPlayer players with PartyId / InRun attributes.
--   --set view=home       the home screen: the PARTY button (you lead a party of 2) (default)
--   --set view=panel      the PARTY screen, THIS SERVER tab: you lead a party of 2, an
--                         invite from Cal waiting, Dee in a run, Eve invited
--   --set view=member     the PARTY screen as a member (no KICK, the member hint)
--   --set view=solo       the PARTY screen with no party yet
--   --set view=friends    the FRIENDS tab (the mock friends list is empty: the empty note)
--   --set view=card       the invite card over the home screen (and the PARTY badge)
local C = lib("common")
C.lobby()
local Players = game:GetService("Players")
local me = Players.LocalPlayer
local view = preview.args.view or "home"
local ava = preview.addPlayer("Ava", 2)
local cal = preview.addPlayer("Cal", 4)
local dee = preview.addPlayer("Dee", 5)
local eve = preview.addPlayer("Eve", 6)
dee:SetAttribute("InRun", true)
C.startClient()
C.sendProfile()
C.settle(1)

local leader = view ~= "member"
local members = { { UserId = me.UserId, Name = me.DisplayName }, { UserId = 2, Name = "Ava" } }
if not leader then
	members = { { UserId = 2, Name = "Ava" }, { UserId = me.UserId, Name = me.DisplayName } }
end
if view == "solo" then
	members = {}
else
	me:SetAttribute("PartyId", 1)
	ava:SetAttribute("PartyId", 1)
end
C.fire("PartyState", {
	LeaderId = view == "solo" and 0 or (leader and me.UserId or 2),
	Members = members,
	Max = 3,
	Invites = (view == "panel" or view == "card") and { { FromId = 4, FromName = "Cal", Seconds = 24 } } or {},
	Sent = view == "panel" and { 6 } or {},
})
if view == "card" then
	C.fire("PartyInvite", { FromId = 4, FromName = "Cal", Seconds = 30 })
end
C.settle(1)
local LobbyScreen = preview.client("LobbyScreen")
if view == "panel" or view == "member" or view == "solo" or view == "friends" then
	LobbyScreen.Show("Party")
	C.settle(1.5)
	if view == "friends" then
		local tab = C.findText("^FRIENDS$", "TextButton")
		if tab then
			preview.click(tab)
		end
		C.settle(1.5)
	end
end
-- what the screen shows, for the log
local MenuParty = preview.client("MenuParty")
local sum = MenuParty.Summary()
preview.log(string.format("party view=%s count=%d max=%d invites=%d leader=%s", view, sum.Count, sum.Max, sum.Invites, tostring(sum.Leader)))
for _, pat in ipairs({ "^INVITE$", "^SENT$", "^ACCEPT$", "^KICK$", "^LEAVE PARTY$", "^INVITE FRIENDS$", "^PARTY$" }) do
	local g = C.findText(pat)
	preview.log(string.format("  %-16s %s", pat, g and (g:IsA("GuiObject") and tostring(g.Visible) or "found") or "-"))
end
