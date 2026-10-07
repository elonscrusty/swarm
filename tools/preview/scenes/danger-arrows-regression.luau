-- danger-arrows-regression: the off-screen danger arrows (client DangerArrows.lua,
-- Config.Features.DangerArrows, docs/next/DANGER_ARROWS.md). An elite far off screen gets an
-- edge arrow with its ring badge and "N m"; on screen and near it has none; six threats cap
-- at four arrows (the boss always among them, then nearest first) with the skull / crown /
-- ring shapes; every arrow stays inside the safe area and off the HUD rects; Reduced effects
-- drops the pulse but keeps the arrow; a panel and the switch hide them. Prints PASS / FAIL
-- lines. Registered as a layout check on iphone, phone-portrait and pc (the final frame
-- shows four arrows for check_layout).
local A = lib("arena")
local C = lib("common")
local s = A.build({ enemies = 0, swarm = false, seconds = 300, stage = 2 })
C.settle(2)
local Config = C.shared("Config")
local EnemyData = C.shared("EnemyData")
local DA = preview.client("DangerArrows")
local UIState = preview.client("UIState")
local Settings = preview.client("ClientSettings")
local fails = 0
local function check(ok: boolean, label: string)
	if not ok then
		fails += 1
	end
	preview.log((ok and "PASS " or "FAIL ") .. label)
end

local folder = workspace:FindFirstChild("SwarmEnemies") or Instance.new("Folder")
folder.Name = "SwarmEnemies"
folder.Parent = workspace
local bossType, eliteType
for id, def in pairs(EnemyData.Enemies) do
	if def.IsBoss and (not bossType or id < bossType) then
		bossType = id
	end
end
eliteType = EnemyData.Enemies.Beetle and "Beetle" or nil
if not eliteType then
	for id, def in pairs(EnemyData.Enemies) do
		if not def.IsBoss and not def.Static and (not eliteType or id < eliteType) then
			eliteType = id
		end
	end
end
local nextId = 900
local bodies = {}
local function spawn(kind: string, dx: number, dz: number)
	nextId += 1
	local typeId = kind == "Boss" and bossType or eliteType
	local def = EnemyData.Enemies[typeId]
	local elite = kind ~= "Boss"
	local model, body = C.try("BuildEnemyShell", s.ModelBuilder.BuildEnemyShell, nextId, folder)
	if not (model and body) then
		return nil
	end
	local sizeMult = elite and Config.Enemies.EliteSizeMult or 1
	C.try("ApplyEnemyLook", s.ModelBuilder.ApplyEnemyLook, body, def, elite, sizeMult)
	local pos = Vector3.new(s.centre.X + dx, Config.ArenaOrigin.Y + def.Size.Y * sizeMult / 2, s.centre.Z + dz)
	body.CFrame = CFrame.new(pos)
	body:SetAttribute("Elite", elite)
	if kind == "Champion" then
		body:SetAttribute("MiniBoss", "Champion Test")
	end
	body:SetAttribute("Type", typeId)
	table.insert(bodies, body)
	return body
end
local function refresh(t: number?)
	C.settle(t or 0.4)
	DA.Refresh()
	C.settle(0.3)
	return (DA.Debug())
end

-- 1. one elite far off screen
local e1 = spawn("Elite", 150, 0)
local list = refresh(0.6)
check(#list == 1 and list[1].Kind == "Elite", "an off-screen elite gets one arrow (got " .. #list .. ")")
check(list[1] ~= nil and list[1].Glyph == "Elite", "the elite arrow shows the ring badge")
check(list[1] ~= nil and string.match(list[1].Text or "", "^%d+ m$") ~= nil and math.abs(list[1].Dist - 150) < 3, "the elite arrow reads its distance in m (" .. tostring(list[1] and list[1].Text) .. ")")

-- 2. the same elite near and on screen: no arrow
if e1 then
	e1.CFrame = CFrame.new(s.centre.X + 10, e1.Position.Y, s.centre.Z)
end
list = refresh()
check(#list == 0, "an on-screen elite within " .. Config.DangerArrows.FarStuds .. " studs has no arrow (got " .. #list .. ")")

-- 3. six threats: four arrows, boss first, then nearest
if e1 then
	e1.CFrame = CFrame.new(s.centre.X + 150, e1.Position.Y, s.centre.Z)
end
spawn("Champion", 0, -160)
spawn("Elite", -170, 0)
spawn("Boss", 0, 200)
spawn("Elite", 180, -180)
spawn("Elite", -190, 190)
list = refresh(0.6)
check(#list == Config.DangerArrows.MaxArrows, "six threats cap at " .. Config.DangerArrows.MaxArrows .. " arrows (got " .. #list .. ")")
local kinds = {}
for _, a in ipairs(list) do
	kinds[a.Kind] = (kinds[a.Kind] or 0) + 1
end
check(kinds.Boss == 1 and kinds.Champion == 1 and kinds.Elite == 2, "the boss, the champion and the two nearest elites are shown")
local glyphOk = true
for _, a in ipairs(list) do
	glyphOk = glyphOk and a.Glyph == a.Kind
end
check(glyphOk, "each arrow's badge shape matches its kind (skull / crown / ring)")
local nearestOk = true
for i = 3, #list do
	nearestOk = nearestOk and list[i].Dist >= list[i - 1].Dist - 0.01
end
check(list[1] and list[1].Kind == "Boss" and nearestOk, "the boss leads, the rest are nearest first")

-- 4. inside the safe area and clear of the HUD rects and of each other
local _, rects = DA.Debug()
local gui = game:GetService("Players").LocalPlayer.PlayerGui:FindFirstChild("DangerArrows")
local rootFrame = gui and gui:FindFirstChild("Root")
local inside, clear = true, true
if rootFrame then
	local ap, as = rootFrame.AbsolutePosition, rootFrame.AbsoluteSize
	for i, a in ipairs(list) do
		local b = a.Box
		if b[1] < ap.X - 0.5 or b[2] < ap.Y - 0.5 or b[3] > ap.X + as.X + 0.5 or b[4] > ap.Y + as.Y + 0.5 then
			inside = false
			preview.log(string.format("  arrow %d box %d,%d,%d,%d outside safe %d,%d,%d,%d", i, b[1], b[2], b[3], b[4], ap.X, ap.Y, ap.X + as.X, ap.Y + as.Y))
		end
		for _, r in ipairs(rects) do
			if r[3] > b[1] and r[1] < b[3] and r[4] > b[2] and r[2] < b[4] then
				clear = false
				preview.log(string.format("  arrow %d box %d,%d,%d,%d hits rect %d,%d,%d,%d", i, b[1], b[2], b[3], b[4], r[1], r[2], r[3], r[4]))
			end
		end
		for j, o in ipairs(list) do
			local c = o.Box
			if j ~= i and c[3] > b[1] and c[1] < b[3] and c[4] > b[2] and c[2] < b[4] then
				clear = false
				preview.log(string.format("  arrow %d overlaps arrow %d", i, j))
			end
		end
	end
else
	inside = false
end
check(inside, "every arrow sits inside the safe area")
check(clear and #rects > 0, "no arrow covers the HUD, minimap, touch buttons or another arrow (" .. #rects .. " rects)")

-- 5. Reduced effects: arrows stay, no pulse
local pulsing = list[1] ~= nil and list[1].Pulse == true
Settings.Set("ReducedEffects", true)
list = refresh()
local still = #list == Config.DangerArrows.MaxArrows
local noPulse = true
for _, a in ipairs(list) do
	noPulse = noPulse and a.Pulse == false
end
check(pulsing and still and noPulse, "Reduced effects keeps the arrows and stops the pulse")
Settings.Set("ReducedEffects", false)

-- 6. a panel hides them; so does the switch
UIState.Open("LevelUp", {})
list = refresh()
check(#list == 0 and not (gui and gui.Enabled), "arrows hide while a panel is open")
UIState.Close("LevelUp")
list = refresh()
check(#list == Config.DangerArrows.MaxArrows, "arrows return once the panel closed")
Config.Features.DangerArrows = false
list = refresh()
check(#list == 0 and not (gui and gui.Enabled), "switch off: no arrows")
Config.Features.DangerArrows = true
list = refresh(0.6)
check(#list == Config.DangerArrows.MaxArrows, "switch on again: the four arrows are back for the layout frame")

preview.log(fails == 0 and "danger-arrows-regression: all PASS" or string.format("danger-arrows-regression: %d FAIL", fails))
