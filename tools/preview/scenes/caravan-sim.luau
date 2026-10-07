-- caravan-sim: boots the REAL server (GameServer, all modules) and plays the Lost Caravan
-- (CaravanEvent) through a solo run, printing every state change:
--   1) stage 1: placed away from the centre; step into the ring → Defending, waves come,
--      hold until Saved (items + gold before / after)
--   2) DEV next stage: the old cart is gone, a new one stands; start it, walk away →
--      the grace countdown → Lost (no reward)
--   3) stage 3: start it, then MAIN MENU (AbandonRun) mid-defence → the cart is removed,
--      CaravanEvent.Get() is nil, nothing errors
-- --set part=1|2|3|4 runs one part on stage 1 (4 = DEV next stage while defending: the cart
--                    is removed on travel, the next stage has a new one); default: 1, 2, 3
--                    in a row as above (slow: about 15 minutes on a busy machine)
-- --set show=defend  stops in stage 1 while defending, the hero in the ring (marker + bar)
-- --set show=away    stops in stage 1 while defending, the hero 40 studs out (arrow +
--                    "RETURN TO THE CARAVAN" bar)
-- run: render.sh caravan-sim --studio --devices pc --max-time 400
local C = lib("common")
local Players = game:GetService("Players")
preview.forceMeshesUploaded()
preview.startServer()
preview.advance(1)
C.startClient()
preview.advance(1)
local me = Players.LocalPlayer
local RM = preview.server("RunManager")
local SM = preview.server("StageManager")
local CE = preview.server("CaravanEvent")
local ES = preview.server("EnemySpawner")
local Config = C.shared("Config")
-- LootSystem draws the caravan as one of Config.Encounters.Types (Count per stage), so it
-- is not on every stage; this test needs one on each stage it visits.
Config.Encounters.Types = { "Caravan" }
Config.Encounters.Count = { 1, 1 }
local advance = preview.advance
local show = preview.args.show
local part = tonumber(preview.args.part)

local function levelUps()
	for _ = 1, 30 do
		if not me:GetAttribute("Paused") then
			return
		end
		preview.remote("LevelUpChoose"):FireServer(1)
		advance(0.3)
	end
end

-- the reward reel pauses the run: close it like the client does
local function closeRewards(rp)
	if rp.RewardSeq then
		preview.remote("RewardClose"):FireServer(rp.RewardSeq)
	end
end

local function itemCount(rp): number
	local n = 0
	for _, c in pairs(rp.Items or {}) do
		n += c
	end
	return n
end

preview.remote("StartRun"):FireServer("Solo")
advance(2)
levelUps()
local rp = RM.GetRunPlayer(me)
if not rp then
	preview.log("FAIL: no run player")
	return
end
rp.InvulnUntil = math.huge

local function standAt(pos: Vector3)
	local root = rp.Root
	if root then
		root.CFrame = CFrame.new(pos + Vector3.new(0, 3, 0))
		rp.LastValidPos = root.Position
		rp.SpeedCheckTimer = 0
	end
end

local function line(label: string)
	local c = CE.Get()
	if not c then
		preview.log(string.format("%-28s caravan=nil", label))
		return
	end
	local m = c.Model
	preview.log(string.format("%-28s state=%s progress=%.2f left=%s grace=%s waves=%d enemies=%d frozen=%s",
		label, tostring(m:GetAttribute("State")), tonumber(m:GetAttribute("Progress")) or -1,
		tostring(m:GetAttribute("Left")), tostring(m:GetAttribute("Grace")), c.Waves, #ES.Active,
		tostring(C.state():GetAttribute("Frozen"))))
end

local function caravanOrFail(label: string)
	local c = CE.Get()
	if not c then
		preview.log("FAIL: no caravan on " .. label)
		return nil
	end
	local d = ((c.Pos - Config.ArenaOrigin) * Vector3.new(1, 0, 1)).Magnitude
	preview.log(string.format("%s: caravan at %.0f studs from the centre (MinDistance %d) state=%s in SwarmEvents=%s",
		label, d, Config.Caravan.MinDistance, c.State, tostring(c.Model.Parent ~= nil and c.Model.Parent.Name == "SwarmEvents")))
	return c
end

local function nextStage(label: string)
	local old = CE.Get()
	local oldModel = old and old.Model
	SM.DevNextStage()
	for _ = 1, 60 do
		advance(0.5)
		levelUps()
		if SM.GetPhase() == "Explore" then
			break
		end
	end
	preview.log(string.format("%s: stage=%d phase=%s old cart removed=%s", label, SM.GetStage(), SM.GetPhase(), tostring(oldModel == nil or oldModel.Parent == nil)))
end

local c = caravanOrFail("stage 1")
if not c then
	return
end
if part == 2 or part == 3 or part == 4 then
	standAt(c.Pos + Vector3.new(3, 0, 0))
	advance(1.5)
	levelUps()
	line("started")
	if part == 2 then
		local items1 = itemCount(rp)
		for s = 1, 12 do
			standAt(c.Pos + Vector3.new(45, 0, 0))
			advance(1)
			levelUps()
			line(string.format("away %ds", s))
			if c.State ~= "Defending" then
				break
			end
		end
		preview.log(string.format("RESULT 2: state=%s (want Lost) items +%d (want 0)", c.State, itemCount(rp) - items1))
	elseif part == 3 then
		local model = c.Model
		preview.remote("AbandonRun"):FireServer()
		advance(2)
		local ev = workspace:FindFirstChild("SwarmEvents")
		preview.log(string.format("RESULT 3: after MAIN MENU: Get()=%s model removed=%s SwarmEvents children=%d running=%s",
			tostring(CE.Get()), tostring(model.Parent == nil), ev and #ev:GetChildren() or -1, tostring(RM.IsRunning())))
		advance(2)
	else
		nextStage("travel mid-defence")
		local c2 = caravanOrFail("stage 2")
		preview.log(string.format("RESULT 4: new caravan=%s state=%s", tostring(c2 ~= nil and c2 ~= c), c2 and c2.State or "-"))
	end
	preview.log("done")
	return
end

-- 1) success --------------------------------------------------------------------------
line("before")
standAt(c.Pos + Vector3.new(4, 0, 0))
advance(1.2) -- the caravan starts after 1 s in the ring (Config.Caravan.StartSeconds)
line("stepped into the ring")
local items0, gold0 = itemCount(rp), rp.Gold
local t = 0
while c.State == "Defending" and t < 40 do
	advance(1)
	t += 1
	levelUps()
	closeRewards(rp)
	standAt(c.Pos + Vector3.new(4, 0, 0))
	if t % 4 == 0 then
		line(string.format("defending t=%ds", t))
	end
	if show and t >= 6 then
		if show == "away" then
			standAt(c.Pos + Vector3.new(40, 0, 0))
			advance(2.2)
		else
			advance(0.4)
		end
		line("render (" .. show .. ")")
		return
	end
end
line("end of defence")
preview.log(string.format("RESULT 1: state=%s (want Saved) items +%d gold +%d (want +1 item, +%d x gold mult)",
	c.State, itemCount(rp) - items0, rp.Gold - gold0, Config.Caravan.Gold))
advance(1)
closeRewards(rp)
advance(4)
if part == 1 then
	preview.log("done")
	return
end

-- 2) fail ------------------------------------------------------------------------------
nextStage("travel")
local c2 = caravanOrFail("stage 2")
if c2 then
	preview.log("new caravan object:", tostring(c2 ~= c))
	standAt(c2.Pos + Vector3.new(3, 0, 0))
	advance(1.5)
	levelUps()
	line("started")
	standAt(c2.Pos + Vector3.new(45, 0, 0))
	local items1 = itemCount(rp)
	for s = 1, 12 do
		advance(1)
		levelUps()
		closeRewards(rp)
		standAt(c2.Pos + Vector3.new(45, 0, 0))
		line(string.format("away %ds", s))
		if c2.State ~= "Defending" then
			break
		end
	end
	preview.log(string.format("RESULT 2: state=%s (want Lost) items +%d (want 0)", c2.State, itemCount(rp) - items1))
end

-- 3) run end mid-encounter -------------------------------------------------------------
nextStage("travel")
local c3 = caravanOrFail("stage 3")
if c3 then
	standAt(c3.Pos + Vector3.new(3, 0, 0))
	advance(1.5)
	levelUps()
	line("started")
	local model = c3.Model
	preview.remote("AbandonRun"):FireServer()
	advance(2)
	local ev = workspace:FindFirstChild("SwarmEvents")
	preview.log(string.format("RESULT 3: after MAIN MENU: Get()=%s model removed=%s SwarmEvents children=%d running=%s",
		tostring(CE.Get()), tostring(model.Parent == nil), ev and #ev:GetChildren() or -1, tostring(RM.IsRunning())))
	advance(2)
end
preview.log("done")
