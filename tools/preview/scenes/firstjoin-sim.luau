-- firstjoin-sim: boots the REAL server and client with a brand-new save and the automatic
-- first run switched on (Config.FirstRun; other scenes keep it off). Checks that:
--   1. the lobby asks once (StartFirstRun) and the server drops the new player straight
--      into a Solo run (player attribute FirstRun = "Start", InRun);
--   2. after leaving that run (MAIN MENU) the lobby shows and stays (no second run, even
--      when the player rejoins and asks again: Stats.Runs counts the run at its start);
--   3. a brand-new player in a party is refused (FirstRun = "Lobby"), as is a spammed ask;
--   4. the first run's welcome (Config.FirstRun: cheap first level within ~20 s, showcase
--      weapon + start-weapon upgrade on the first offer, gentle waves 1-2, one-time gold
--      bonus and a NEXT GOAL hero on the results) happens once per account, not for a
--      DEV-tainted run.
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
preview.shared("Config").Features.Walkthrough = false -- this scene checks the flow without the interactive walkthrough (walkthrough-regression covers it)

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

-- 1b. the first run's welcome (Config.FirstRun): cheap first level, showcase offer,
-- gentle first waves, a one-time gold bonus on the results
local FR = preview.shared("Config").FirstRun
local Config = preview.shared("Config")
local rp = RM.GetRunPlayer(me)
check("first run gets the welcome", rp ~= nil and rp.FirstRun == true and me:GetAttribute("FirstRunBoost") == true)
check("first level is cheap (this run only)", rp ~= nil and rp.XPNeeded == FR.FirstLevelXP and preview.server("XPSystem").XPNeeded(1) == Config.XP.Base + Config.XP.PerLevel,
	"XPNeeded=" .. tostring(rp and rp.XPNeeded))
local Spawner = preview.server("EnemySpawner")
local normal1 = Config.Waves.Base * Config.Difficulty.PlayerCountMult[1]
check("wave 1 is gentle", Spawner.WaveSize(1) == math.floor(normal1 * FR.GentleSizeMult + 0.5), "size=" .. Spawner.WaveSize(1))
check("wave 3 is normal size", Spawner.WaveSize(3) == math.floor((Config.Waves.Base + 2 * Config.Waves.PerWave) * Config.Difficulty.PlayerCountMult[1] + 0.5), "size=" .. Spawner.WaveSize(3))
-- the hero walks a slow circle in the swarm (as levelrate-sim) until the first offer
local c = Config.ArenaOrigin
local angle, firstAt = 0, nil
if rp then
	rp.InvulnUntil = math.huge
end
for _ = 1, 400 do -- 40 s at most
	if rp and rp.Root then
		angle += 0.1 * 5 / 24
		local pos = Vector3.new(c.X + math.cos(angle) * 24, rp.Root.Position.Y, c.Z + math.sin(angle) * 24)
		local dir = Vector3.new(-math.sin(angle), 0, math.cos(angle))
		rp.MoveDir, rp.Facing = dir, dir
		rp.Root.CFrame = CFrame.lookAt(pos, pos + dir)
		rp.LastValidPos = rp.Root.Position
		rp.SpeedCheckTimer = 0
	end
	preview.advance(0.1)
	if rp and rp.Offer then
		firstAt = RM.GetRunTime()
		break
	end
end
preview.log(string.format("first level-up offer at run time %s s", firstAt and string.format("%.1f", firstAt) or "never"))
check("first level-up within 22 s", firstAt ~= nil and firstAt <= 22, tostring(firstAt))
local offer = rp and rp.Offer or {}
local showcase, startUp = nil, false
for i, card in ipairs(offer) do
	if card.Type == "WeaponNew" and table.find(FR.ShowcaseWeapons, card.Id) then
		showcase = showcase or i
	elseif card.Type == "WeaponUp" and rp and card.Id == rp.WeaponOrder[1] then
		startUp = true
	end
end
local names = {}
for _, card in ipairs(offer) do
	table.insert(names, tostring(card.Type) .. ":" .. tostring(card.Id))
end
check("first offer has a showcase weapon", showcase == 1, table.concat(names, ", "))
check("first offer upgrades the start weapon", startUp)
check("first offer has 3 cards", #offer == Config.LevelUp.Choices, tostring(#offer))
preview.remote("LevelUpChoose"):FireServer(showcase or 1, game:GetService("Players").LocalPlayer:GetAttribute("ChoiceOfferId"))
preview.advance(1)
check("showcase weapon taken", rp ~= nil and #rp.WeaponOrder == 2, rp and table.concat(rp.WeaponOrder, ",") or "")
check("level 2 costs the normal curve", rp ~= nil and rp.XPNeeded == preview.server("XPSystem").XPNeeded(2), tostring(rp and rp.XPNeeded))

-- 2. MAIN MENU: back in the lobby, which stays; the results carry the one-time bonus
local result = nil
preview.remote("RunResult").OnClientEvent:Connect(function(d)
	result = d
end)
local goldBefore = data.Gold
preview.remote("AbandonRun"):FireServer()
preview.advance(2)
check("first-run bonus paid once", data.FirstRunBonus == true and data.Gold >= goldBefore + FR.BonusGold, "gold " .. goldBefore .. " -> " .. data.Gold)
check("results show the bonus", type(result) == "table" and type(result.FirstRun) == "table" and result.FirstRun.Bonus == FR.BonusGold)
local goal = type(result) == "table" and result.NextGoal or nil
check("results point at the first gold hero", type(goal) == "table" and goal.Kind == "BuyHero" and goal.Icon == "hero:Mage", goal and tostring(goal.Text) or "none")
check("boost attribute cleared", me:GetAttribute("FirstRunBoost") == nil)
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

-- 4. the welcome is once per account and never for a DEV-tainted run
preview.advance(1.2)
preview.remote("StartRun"):FireServer("Solo")
preview.advance(1.5)
local again = RM.GetRunPlayer(me)
check("second run gets no welcome", again ~= nil and again.FirstRun ~= true and me:GetAttribute("FirstRunBoost") ~= true
	and again.XPNeeded == preview.server("XPSystem").XPNeeded(1), tostring(again and again.XPNeeded))
check("second run waves are normal", Spawner.WaveSize(1) == math.floor(normal1 + 0.5), "size=" .. Spawner.WaveSize(1))
local gold2 = data.Gold
result = nil
preview.remote("AbandonRun"):FireServer()
preview.advance(2)
check("no second bonus", data.Gold - gold2 < FR.BonusGold and (type(result) ~= "table" or result.FirstRun == nil), "gold " .. gold2 .. " -> " .. data.Gold)
-- Ben (brand new, refused above while in a party) leaves the party and starts Solo
preview.fireServerAs(ben, "Party", "Leave")
preview.advance(1.5)
preview.fireServerAs(ben, "StartRun", "Solo")
preview.advance(1.5)
local cyRp = RM.GetRunPlayer(ben)
local cyData = Data.GetData(ben)
check("a new player's first Solo run gets the welcome", cyRp ~= nil and cyRp.FirstRun == true, cyRp and "in run" or "no run")
if cyRp then
	cyRp.DevTainted = true -- as if a DEV command was used
end
local cyGold = cyData and cyData.Gold or 0
preview.fireServerAs(ben, "AbandonRun")
preview.advance(2)
check("a DEV-tainted first run pays no bonus", cyData ~= nil and cyData.FirstRunBonus ~= true and cyData.Gold - cyGold < FR.BonusGold,
	cyData and ("gold " .. cyGold .. " -> " .. cyData.Gold) or "no data")
preview.log(failures == 0 and "PASS firstjoin-sim: all checks" or ("FAIL firstjoin-sim: " .. failures .. " checks failed"))
