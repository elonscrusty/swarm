-- dev-inbox: the DEV bug inbox (DevInbox) with a page of reports as BugReportService sends
-- them. Run with --studio (the DEV panel's "Bug inbox" button opens it).
--   --set status=ok|offline|empty
local C = lib("common")
C.lobby()
C.startClient()
C.sendProfile()
C.settle(1)
local DevInbox = C.try("require DevInbox", preview.client, "DevInbox")
if DevInbox then
	C.try("DevInbox.Open", DevInbox.Open)
end
C.settle(0.3)
local status = preview.args.status or "ok"
local now = 1759400000
local samples = {
	{ "Gameplay", "Portal didn't open after the boss died on stage 2.", "New", "Stage 2 · Swamp · Ranger · Lv 14", "Phone · v1.0.0" },
	{ "Visual", "The lava pools flicker white when I use reduced effects.", "Seen", "Stage 5 · Lava · Alchemist · Lv 31", "Desktop · v1.0.0" },
	{ "Performance", "Big lag spike at 12 minutes with lots of bugs on screen. ####", "Fixed", "Stage 4 · Snow · Engineer · Lv 27", "Tablet · v1.0.0" },
	{ "Controls", "Thumbstick sticks after the level up cards close.", "WontFix", "Lobby · Forest · Knight", "Phone · v1.0.0" },
}
local rows = {}
if status == "ok" then
	for i, s in ipairs(samples) do
		table.insert(rows, {
			Id = string.format("%d_%d", (now - i * 3600) * 1000, 1000 + i),
			Time = now - i * 3600,
			UserId = 1000 + i,
			Name = "Player" .. i,
			Category = s[1],
			Text = s[2],
			Status = s[3],
			Context = s[4],
			ClientLine = s[5],
			Mode = "Solo",
			RunTime = 300 + i * 90,
			PlaceVersion = 42,
		})
	end
end
C.fire("BugInboxData", {
	Kind = "Page",
	Status = status == "offline" and "offline" or "ok",
	Rows = rows,
	Next = status == "ok" and { V = (now - 4 * 3600) * 1000, K = { rows[4] and rows[4].Id } } or nil,
	Message = status == "offline" and "DataStores are unavailable on this server." or nil,
})
C.settle(1)
