-- bugreport-sim: boots the REAL server and drives BugReportService through its remotes:
-- bad payloads, a report through the mock text filter ("badword" → hashes), the
-- cooldown, then the DEV inbox page, a bad cursor and status changes. Prints every answer. Run with --studio (Studio = dev rule passes):
--   render.sh bugreport-sim --studio --devices pc
local C = lib("common")
local Players = game:GetService("Players")
preview.startServer()
preview.advance(1)
C.startClient()
preview.advance(1)
local me = Players.LocalPlayer
preview.log("BugInbox attribute: " .. tostring(me:GetAttribute("BugInbox")))
preview.remote("BugReportResult").OnClientEvent:Connect(function(d)
	preview.log(string.format("BugReportResult Ok=%s Message=%s", tostring(d.Ok), tostring(d.Message)))
end)
preview.remote("BugInboxData").OnClientEvent:Connect(function(d)
	if d.Kind == "Page" then
		preview.log(string.format("BugInboxData Page status=%s rows=%d next=%s", tostring(d.Status), #(d.Rows or {}), tostring(d.Next ~= nil)))
		for _, r in ipairs(d.Rows or {}) do
			preview.log(string.format("  %s [%s] %s: %s | %s | client: %s", tostring(r.Id), tostring(r.Status), tostring(r.Category), tostring(r.Text), tostring(r.Context), tostring(r.ClientLine)))
		end
	else
		preview.log(string.format("BugInboxData Status id=%s status=%s ok=%s", tostring(d.Id), tostring(d.Status), tostring(d.Ok)))
	end
end)
local function send(...)
	preview.remote("BugReport"):FireServer(...)
	preview.advance(1.2)
end
send("nope")
send({ Category = "Hacks", Text = "a valid length text here" })
send({ Category = "Gameplay", Text = "short" })
send({ Category = "Gameplay", Text = string.rep("x", 600) })
send({ Category = "Visual", Text = "Lava pools flicker, badword here.", Client = { Device = "Phone<b>", Stage = 1e9, Level = 3, Version = "1.0.0" } })
send({ Category = "Visual", Text = "A second report straight away should wait.", Client = {} })
preview.remote("BugInbox"):FireServer("Page", nil)
preview.advance(1)
preview.remote("BugInbox"):FireServer("Page", { V = "bad" })
preview.advance(1)
local Ids = {}
preview.remote("BugInboxData").OnClientEvent:Connect(function(d)
	for _, r in ipairs(d.Rows or {}) do
		table.insert(Ids, r.Id)
	end
end)
preview.remote("BugInbox"):FireServer("Page", nil)
preview.advance(1)
if Ids[1] then
	preview.remote("BugInbox"):FireServer("SetStatus", Ids[1], "Fixed")
	preview.advance(1)
	preview.remote("BugInbox"):FireServer("Page", nil)
	preview.advance(1)
end
preview.remote("BugInbox"):FireServer("SetStatus", "123_456", "Fixed")
preview.advance(1)
preview.remote("BugInbox"):FireServer("SetStatus", "123_456", "Deleted")
preview.advance(1)
C.settle(0.5)
