-- firstjoin-sim: boots the REAL server and client with a brand-new save and the automatic
-- first run switched on (Config.FirstRun; other scenes keep it off). Checks that:
--   1. the lobby asks once (StartFirstRun) and the server drops the new player straight
--      into a Solo run (player attribute FirstRun = "Start", InRun);
--   2. after leaving that run (MAIN MENU) the lobby shows and stays (no second run, even
--      when the player rejoins and asks again: Stats.Runs counts the run at its start);
--   3. a brand-new player in a party is refused (FirstRun = "Lobby"), as is a spammed ask.
-- Prints PASS / FAIL lines. Run headless (the UI-heavy render is slow):
--   lune run tools/preview/runtime/main.luau -- --scene firstjoin-sim --studio --device pc --out <json> --set headless=on
local C = lib("common")
preview.args.firstrun = "on" -- this scene tests the switch itself (other scenes keep it off)
local Players = game:GetService("Players")
local me = Players.LocalPlayer
local ava = preview.addPlayer("Ava", 2)
local ben = preview.addPlayer("Ben", 3)
preview.forceMeshesUploaded()
preview.startServer()
preview.advance(2)

local st = C.state()
local RM = preview.server("RunManager")
local Data = preview.server("DataService")
local failures = 0
local function check(name: string, good: boolean, detail: string?)
	if not good then
		failures += 1
	end
	preview.log((good and "PASS " or "FAIL ") .. name .. (detail and (" (" .. detail .. ")") or ""))
end
local asks = 0
preview.remote("StartFirstRun").OnServerEvent:Connect(function(p)
	if p == me then
		asks += 1
	end
end)

-- 1. the new player's client boots the lobby and asks
preview.startClient() -- the real client (ClientMain + lobby), also with headless=on
preview.shared("Config").FirstRun.AutoStart = true
preview.advance(3)
local data = Data.GetData(me)
check("new save starts with no runs", data ~= nil and data.Stats.Runs >= 0)
check("client asked once", asks == 1, "asks=" .. asks)
check("server started the first run", me:GetAttribute("FirstRun") == "Start" and me:GetAttribute("InRun") == true,
	tostring(me:GetAttribute("FirstRun")) .. " InRun=" .. tostring(me:GetAttribute("InRun")))
check("first run is Solo", st:GetAttribute("Mode") == "Solo", tostring(st:GetAttribute("Mode")))
check("the run counted at its start", data.Stats.Runs == 1, "Runs=" .. tostring(data.Stats.Runs))
local gui = me:FindFirstChild("PlayerGui")
local lobby = gui and gui:FindFirstChild("Lobby", true)
check("lobby hidden during the run", lobby ~= nil and lobby.Visible == false)
preview.advance(5)

-- 2. MAIN MENU: back in the lobby, which stays
preview.remote("AbandonRun"):FireServer()
preview.advance(2)
check("back in the lobby after leaving", me:GetAttribute("InRun") ~= true)
check("lobby shows after the first run", lobby ~= nil and lobby.Visible == true)
local cover = gui and gui:FindFirstChild("FirstRunCover", true)
check("no first-run cover in the lobby", cover ~= nil and cover.Visible == false)
preview.advance(3)
check("client did not ask again", asks == 1, "asks=" .. asks)
check("no second run started", me:GetAttribute("InRun") ~= true)
-- a spammed ask in the same session is ignored
preview.remote("StartFirstRun"):FireServer()
preview.advance(0.5)
check("second ask in a session ignored", me:GetAttribute("InRun") ~= true)
-- rejoin (the server forgets the session's ask): the save now has a run, so the lobby stays
preview.advance(1.2) -- past the remote's rate limit
RM.OnPlayerRemoving(me)
me:SetAttribute("FirstRun", nil)
preview.remote("StartFirstRun"):FireServer()
preview.advance(0.5)
check("rejoin after the first run keeps the lobby", me:GetAttribute("FirstRun") == "Lobby" and me:GetAttribute("InRun") ~= true,
	tostring(me:GetAttribute("FirstRun")))

-- 3. brand-new players in a party stay in the lobby (the leader starts party runs)
preview.fireServerAs(ava, "Party", "Invite", ben.UserId)
preview.advance(0.3)
preview.fireServerAs(ben, "Party", "Accept", ava.UserId)
preview.advance(0.3)
check("party formed", preview.server("PartyService").PartyOf(ben) ~= nil)
preview.fireServerAs(ben, "StartFirstRun")
preview.advance(0.5)
check("new player in a party is refused", ben:GetAttribute("FirstRun") == "Lobby" and ben:GetAttribute("InRun") ~= true,
	tostring(ben:GetAttribute("FirstRun")))
check("lobby phase unchanged", st:GetAttribute("Phase") == "Lobby", tostring(st:GetAttribute("Phase")))
preview.log(failures == 0 and "PASS firstjoin-sim: all checks" or ("FAIL firstjoin-sim: " .. failures .. " checks failed"))
