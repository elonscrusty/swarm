-- analytics-client: the REAL client's ready report (ClientMain → remote ClientReady, server
-- Analytics onboarding step 2). Boots server + client with a brand-new save; checks that
-- the report comes once, only after the lobby menu shows with the profile, and that the
-- server records step 2 once. PASS / FAIL lines.
-- Run: lune run tools/preview/runtime/main.luau -- --scene analytics-client --studio --device pc --out <json>
local C = lib("common")
local Players = game:GetService("Players")
local me = Players.LocalPlayer
local fails = 0
local function check(label: string, ok: boolean, detail: string?)
	if not ok then
		fails += 1
	end
	preview.log(string.format("%s  %s%s", ok and "PASS" or "FAIL", label, detail and ("  (" .. detail .. ")") or ""))
end
preview.forceMeshesUploaded()
preview.startServer()
preview.advance(1)
local reports, lobbyAtReport = 0, nil
local LobbyScreen
preview.remote("ClientReady").OnServerEvent:Connect(function(p)
	if p == me then
		reports += 1
		if lobbyAtReport == nil then
			lobbyAtReport = LobbyScreen ~= nil and LobbyScreen.ShowsProfile()
		end
	end
end)
C.startClient()
LobbyScreen = preview.client("LobbyScreen")
preview.advance(8)
local Analytics = preview.server("Analytics")
local steps = {}
for _, e in ipairs(Analytics.Log) do
	if e.UserId == me.UserId then
		table.insert(steps, e.Kind == "Step" and (e.Step .. ":" .. e.Name) or e.Name)
	end
end
check("one ClientReady from the client", reports == 1, tostring(reports))
check("sent while the lobby menu shows the profile", lobbyAtReport == true, tostring(lobbyAtReport))
check("server: steps 1 and 2 once", table.concat(steps, ", ") == "1:Joined Game, 2:Ready to Play", table.concat(steps, ", "))
preview.log(string.format("analytics-client: %s", fails == 0 and "PASS all" or ("FAIL " .. fails)))
