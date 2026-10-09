-- run-hud-regression: the continuation brief's run UI (stream F), fed by the shared-contract
-- attributes and remotes only. Prints PASS / FAIL lines; registered as a layout check on iphone,
-- phone-portrait and pc (the final frame is the results modal over the HUD for check_layout).
--
--   tokens      RunTheme colours are the brief's, text on navy is readable
--   layout      every HUD piece (health, timer, objective, boss, counters, map, party, equipment, XP strip,
--               joystick, JUMP, DASH) inside the screen and clear of the others; touch targets >= 48 pt
--   objective   one strip per RunStage (Survive, BeaconAvailable, Rally, Charge, Boss, Victory, Defeat),
--               OVERTIME after 15:00, the boss bar, the beacon edge arrow, nothing without the attributes
--   inventory   4 + 4 tiles, rank badge and pips, evolution mark, the evolution requirement line
--   map         ~80-stud reveal shared by the team, chests only once discovered
--   interact    Revive > Beacon > Chest, chest cost and balance, nothing without the server remote
--   downed      bleed-out ring, revive progress, Interrupted, Revived, Out (spectate) and teammates left
--   cards       rarity word + symbol, current -> next lines, deadline ring, safe input, reroll, keys, touch,
--               live (no pause), no "Recommended", older payloads normalise
--   menu        Escape menu in a live team run says "The run continues"
--   results     server-confirmed outcome, stats, new unlocks, save status, RETURN TO LOBBY
local A = lib("arena")
local C = lib("common")
local s = A.build({ arena = preview.args.arena or "Cliffwood", enemies = 0, swarm = false, seconds = 300 })
local centre = s.centre
-- the client's renderers wait for these folders (a swarm scene would create them)
for _, name in ipairs({ "SwarmEnemies", "SwarmGems", "SwarmPickups" }) do
	if not workspace:FindFirstChild(name) then
		local f = Instance.new("Folder")
		f.Name = name
		f.Parent = workspace
	end
end
C.settle(1.5)

local Players = game:GetService("Players")
local RS = game:GetService("ReplicatedStorage")
local UIS = game:GetService("UserInputService")
local lp = Players.LocalPlayer
local state = C.state()
local fails = 0
local function check(ok: boolean, label: string)
	if not ok then
		fails += 1
	end
	preview.log((ok and "PASS " or "FAIL ") .. label)
end
local function section(name: string, fn)
	local ok, err = xpcall(fn, function(e)
		return debug.traceback(tostring(e), 2)
	end)
	if not ok then
		fails += 1
		preview.log("FAIL " .. name .. " raised: " .. tostring(err))
	end
end
local function setS(k: string, v: any)
	state:SetAttribute(k, v)
end
local function setP(k: string, v: any)
	lp:SetAttribute(k, v)
end
local function settle(t: number?)
	preview.advance(t or 0.5, 12) -- 12 fps: enough for the UI timers, three times cheaper than the default 30
end

-- modules ---------------------------------------------------------------------------------------
local scripts = lp:FindFirstChild("PlayerScripts")
local v2 = scripts and scripts:FindFirstChild("SwarmV2Client")
local runFolder = v2 and v2:FindFirstChild("Run")
local sharedRun = RS:FindFirstChild("SwarmV2") and RS.SwarmV2:FindFirstChild("Run")
local function mod(name: string)
	return preview.require(runFolder:FindFirstChild(name))
end
local RunConfig = preview.require(sharedRun:FindFirstChild("RunConfig"))
local RunLayout = preview.require(sharedRun:FindFirstChild("RunLayout"))
local RunTheme = mod("RunTheme")
local RunCards = mod("RunCards")
local RunObjective = mod("RunObjective")
local RunInteract = mod("RunInteract")
local RunDowned = mod("RunDowned")
local MapReveal = mod("MapReveal")
local ResultsExtras = mod("ResultsExtras")
local Hud = preview.client("Hud")
local MiniMap = preview.client("MiniMap")
local UIState = preview.client("UIState")
local UIBuilder = preview.client("UIBuilder")
local UI = RunConfig.UI

-- helpers ---------------------------------------------------------------------------------------
local function vis(d: Instance): boolean
	local p: Instance? = d
	while p do
		if p:IsA("GuiObject") and not p.Visible then
			return false
		end
		if p:IsA("ScreenGui") and not p.Enabled then
			return false
		end
		p = p.Parent
	end
	return true
end
-- visible text of a subtree: { { Text, Inst } }
local function visibleTexts(root: Instance): { any }
	local out = {}
	if not root then
		return out
	end
	for _, d in ipairs(root:GetDescendants()) do
		if (d:IsA("TextLabel") or d:IsA("TextButton")) and d.Text ~= "" and vis(d) then
			table.insert(out, { Text = d.Text, Inst = d })
		end
	end
	return out
end
local function textHas(root: Instance, pattern: string): boolean
	for _, t in ipairs(visibleTexts(root)) do
		if string.find(string.upper(t.Text), pattern) then
			return true
		end
	end
	return false
end
local function anyText(pattern: string): any
	local pg = preview.playerGui()
	for _, t in ipairs(visibleTexts(pg)) do
		if string.find(string.upper(t.Text), pattern) then
			return t.Inst
		end
	end
	return nil
end
-- the UI root's design size (what Hud / RunLayout use): the safe-area gui over the root's UIScale
local function virtualSize()
	local pg = preview.playerGui()
	for _, d in ipairs(pg:GetDescendants()) do
		if d:IsA("UIScale") and d.Parent and d.Parent.Name == "Root" and d.Parent.Parent then
			local size = d.Parent.Parent.AbsoluteSize
			local sc = math.max(0.01, d.Scale)
			return size.X / sc, size.Y / sc, sc
		end
	end
	local vp = workspace.CurrentCamera.ViewportSize
	return vp.X, vp.Y, 1
end
local function key(code, state_)
	return { UserInputType = Enum.UserInputType.Keyboard, UserInputState = state_ or Enum.UserInputState.Begin, KeyCode = code, Position = Vector3.zero, Delta = Vector3.zero }
end
local function press(code)
	UIS.InputBegan:_fire(key(code), false)
	settle(0.3)
end
local function serverNow(): number
	local ok, now = pcall(function()
		return workspace:GetServerTimeNow()
	end)
	return ok and now or os.clock()
end
local function hex(c: Color3): string
	return string.format("%02X%02X%02X", math.floor(c.R * 255 + 0.5), math.floor(c.G * 255 + 0.5), math.floor(c.B * 255 + 0.5))
end
local function lum(c: Color3): number
	local function f(v: number)
		return v <= 0.03928 and v / 12.92 or ((v + 0.055) / 1.055) ^ 2.4
	end
	return 0.2126 * f(c.R) + 0.7152 * f(c.G) + 0.0722 * f(c.B)
end
local function contrast(a: Color3, b: Color3): number
	local la, lb = lum(a), lum(b)
	if la < lb then
		la, lb = lb, la
	end
	return (la + 0.05) / (lb + 0.05)
end
local device = tostring(preview.device.name or "pc")
local touchDevice = preview.device.touch == true

-- teammates (extra Players with real characters), like the run-hud scene
local function mate(name: string, userId: number, heroId: string, offset: Vector3, attrs: { [string]: any })
	local p = preview.addPlayer(name, userId)
	local model = C.try("BuildCharacter " .. heroId, s.ModelBuilder.BuildCharacter, heroId, "Default")
	if model then
		model.Name = name
		model:PivotTo(CFrame.new(centre + offset + Vector3.new(0, 3.5, 0)))
		model.Parent = workspace
		p.Character = model
	end
	p:SetAttribute("InRun", true)
	p:SetAttribute("CharacterId", heroId)
	for k, v in pairs(attrs) do
		p:SetAttribute(k, v)
	end
	return p
end
local ava = mate("Ava", 2, "Mage", Vector3.new(14, 0, 6), { Alive = true, HP = 70, MaxHP = 110, Downed = false })
local ben = mate("Ben", 3, "Rogue", Vector3.new(-18, 0, 10), { Alive = false, HP = 0, MaxHP = 100, Downed = true, BleedLeft = 13, ReviveProgress = 0.4 })
local cleo = mate("Cleo", 4, "Ranger", Vector3.new(30, 0, -22), { Alive = false, HP = 0, MaxHP = 100, Downed = false, Eliminated = true })
setP("InRun", true)
setP("HP", 90)
setP("MaxHP", 120)
setP("Level", 14)
setP("XP", 38)
setP("XPNeeded", 80)
setS("Participants", 3)
setS("TeamRunGold", 215)
setS("ChestCost", 140)
setS("RunStage", "Survive")
setS("RunClock", 300)

local WeaponData = C.shared("WeaponData")
local PassiveData = C.shared("PassiveData")
local function sendInventory(weapons, passives)
	C.fire("Inventory", { Weapons = weapons, Passives = passives, WeaponSlots = 4, PassiveSlots = 4, Rerolls = 1, Skips = 0 })
end
local function weapon(id: string, rank: number, evolved: boolean?)
	local def = WeaponData.Weapons[id]
	return { Id = id, Name = def and def.Name or id, Rank = rank, Evolved = evolved == true, Damage = 12 + rank * 3, Interval = 1.4 - rank * 0.05 }
end
local function passive(id: string, rank: number)
	local def = PassiveData.Passives[id]
	return { Id = id, Name = def and def.Name or id, Rank = rank }
end
sendInventory({ weapon("Whip", 5, true), weapon("Garlic", 3), weapon("Knives", 2), weapon("MagicOrb", 1) }, { passive("Might", 3), passive("Armor", 1), passive("Heart", 4) })
settle(2)

------------------------------------------------------------------------------------------
section("tokens", function()
	check(hex(RunTheme.Navy) == "162438", "navy panel token is #162438")
	check(hex(RunTheme.Cream) == "FFF3DC", "cream text token is #FFF3DC")
	check(hex(RunTheme.Gold) == "EFC46E", "gold action token is #EFC46E")
	check(hex(RunTheme.Cyan) == "65DDE0", "cyan focus token is #65DDE0")
	check(contrast(RunTheme.Cream, RunTheme.Navy) >= 7, string.format("cream on navy contrast %.1f >= 7", contrast(RunTheme.Cream, RunTheme.Navy)))
	check(contrast(RunTheme.CreamMuted, RunTheme.Navy) >= 4.5, "secondary cream on navy >= 4.5")
	check(contrast(RunTheme.Gold, RunTheme.Navy) >= 4.5, "gold on navy >= 4.5")
	check(contrast(RunTheme.Cyan, RunTheme.Navy) >= 4.5, "cyan on navy >= 4.5")
	check(contrast(RunTheme.OnGold, RunTheme.Gold) >= 4.5, "navy on gold buttons >= 4.5")
	local rarityOk = true
	for name, color in pairs(RunTheme.Rarity) do
		if contrast(color, RunTheme.Navy) < 4.5 then
			rarityOk = false
			preview.log("  rarity " .. name .. " contrast " .. contrast(color, RunTheme.Navy))
		end
	end
	check(rarityOk, "every rarity colour reads on navy (4.5)")
	local U = UI.Layout
	check(U.TouchMin >= 48, "RunConfig touch minimum is 48")
	check(U.JumpPx >= 48 and U.DashPx >= 48 and U.StickPx >= 96, "thumb controls: stick >= 96, JUMP / DASH >= 48")
	check(UI.Slots.Weapons == 4 and UI.Slots.Passives == 4 and UI.MaxRank == 5, "equipment rows are 4 + 4 with rank pips 1-5")
	check(UI.OvertimeAt == 900, "OVERTIME after 15:00 (900 s)")
end)

------------------------------------------------------------------------------------------
section("layout", function()
	setS("RunStage", "Boss")
	setS("RunClock", 900)
	setS("BossName", "Basin Breaker")
	setS("BossMaxHP", 24000)
	setS("BossHP", 18000)
	settle(2)
	local W, H, scale = virtualSize()
	local env = { W = W, H = H, Insets = { Top = 0, Left = 0, Right = 0 }, Phone = false, Portrait = H > W, Touch = false, Scale = scale }
	local layout = {}
	local names = { "Health", "Timer", "Objective", "Boss", "Counters", "Map", "Party", "Equipment", "XpStrip", "Stick", "Jump", "Dash" }
	local have = {}
	for _, n in ipairs(names) do
		local r = Hud.RunRect(n)
		if r and r.W > 0 and r.H > 0 then
			layout[n] = r
			table.insert(have, n)
		end
	end
	preview.log(string.format("  layout on %s: virtual %dx%d scale %.2f, pieces %s", device, W, H, scale, table.concat(have, ",")))
	for _, n in ipairs({ "Health", "Timer", "Objective", "Boss", "Counters", "Map", "Party", "Equipment" }) do
		check(layout[n] ~= nil, n .. " has a rectangle with the full contract state")
	end
	local conflicts = RunLayout.Conflicts(layout, names, 0, nil)
	check(#conflicts == 0, "no HUD piece overlaps another" .. (#conflicts > 0 and (": " .. table.concat(conflicts, "; ")) or ""))
	for _, n in ipairs(have) do
		local r = layout[n]
		check(RunLayout.Inside(r, env, 0), string.format("%s inside the screen (%.0f,%.0f %.0fx%.0f)", n, r.X, r.Y, r.W, r.H))
	end
	if touchDevice then
		for _, n in ipairs({ "Stick", "Jump", "Dash" }) do
			check(layout[n] ~= nil, n .. " touch control placed")
		end
		for _, n in ipairs({ "Jump", "Dash" }) do
			local r = layout[n]
			check(r ~= nil and r.W * scale >= 48 - 0.5, n .. " is at least 48 pt")
		end
		local stick = layout.Stick
		check(stick ~= nil and stick.W * scale >= 96, "joystick is at least 96 pt")
		-- the right side stays free for the camera drag: the map and the party are small, nothing spans the screen
		local cover = 0
		for _, n in ipairs({ "Health", "Timer", "Objective", "Boss", "Counters", "Map", "Party", "Equipment" }) do
			if layout[n] then
				cover += layout[n].W * layout[n].H
			end
		end
		check(cover / (W * H) < 0.45, string.format("HUD pieces cover %.0f%% of the screen (< 45%%) so the camera drag has room", cover / (W * H) * 100))
	end
	check(Hud.Elements().Overtime == true or textHas(Hud.Elements().Frame, "OVERTIME"), "timer shows OVERTIME at 15:00")
	setS("RunClock", 300)
	settle(1)
end)

------------------------------------------------------------------------------------------
section("objective", function()
	local E = RunObjective.Elements()
	local function stage(name: string, attrs: { [string]: any }, t: number?)
		for _, k in ipairs({ "BeaconPos", "BeaconCharge", "RallyLeft", "BossHP", "BossMaxHP", "BossName" }) do
			setS(k, nil)
		end
		for k, v in pairs(attrs) do
			setS(k, v)
		end
		setS("RunStage", name)
		settle(t or 0.6)
	end
	stage("Survive", { RunClock = 300 })
	check(E.Strip.Visible, "Survive: strip shown")
	check(E.Word.Text == "SURVIVE" and string.match(E.Value.Text, "^%d+:%d%d$") ~= nil, "Survive: word + countdown to the beacon (" .. E.Value.Text .. ")")
	check(not E.Boss.Visible and not E.Cue.Visible, "Survive: no boss bar, no beacon arrow")
	stage("Survive", { RunClock = 930 })
	check(E.Value.Text == "OVERTIME", "Survive after 15:00: OVERTIME on the strip")
	setS("RunClock", 300)
	local far = centre + Vector3.new(160, 0, -90)
	stage("BeaconAvailable", { BeaconPos = far, RunClock = 760 })
	check(E.Word.Text == "BEACON AVAILABLE" and string.find(string.upper(E.Detail.Text), "BEACON") ~= nil, "BeaconAvailable: word + direction detail")
	check(E.Cue.Visible and string.find(E.CueLabel.Text, "Beacon") ~= nil and string.find(E.CueLabel.Text, " m") ~= nil, "BeaconAvailable: edge arrow with the distance (" .. E.CueLabel.Text .. ")")
	stage("BeaconAvailable", { BeaconPos = centre + Vector3.new(8, 0, 4), RunClock = 760 })
	check(not E.Cue.Visible, "BeaconAvailable: no arrow when standing at the beacon")
	stage("Rally", { BeaconPos = far, RallyLeft = 21, RunClock = 790 })
	check(E.Word.Text == "RALLY" and string.match(E.Value.Text, "^0:[12]%d$") ~= nil, "Rally: word + RallyLeft countdown (" .. E.Value.Text .. ")")
	check(E.Progress.Frame.Visible, "Rally: progress bar")
	stage("Charge", { BeaconPos = centre + Vector3.new(60, 0, -16), BeaconCharge = 0.42, RunClock = 845 })
	check(E.Word.Text == "CHARGE" and E.Value.Text == "42%", "Charge: word + BeaconCharge percent (" .. E.Value.Text .. ")")
	check(E.Progress.Frame.Visible, "Charge: progress bar")
	stage("Boss", { BossName = "Basin Breaker", BossMaxHP = 24000, BossHP = 20000, RunClock = 900 })
	check(E.Word.Text == "BOSS" and E.Boss.Visible, "Boss: strip + boss bar")
	check(E.BossName.Text == "BASIN BREAKER" and string.find(E.BossBar.Label.Text, "/") ~= nil, "Boss: name + HP numbers (" .. E.BossBar.Label.Text .. ")")
	check(not E.BossPhase.Visible, "Boss: phase 2 tag hidden above 50%")
	setS("BossHP", 9000)
	settle(0.6)
	check(E.BossPhase.Visible, "Boss: PHASE 2 tag once below the notch")
	stage("Victory", { RunClock = 960 })
	check(E.Word.Text == "VICTORY" and not E.Boss.Visible, "Victory: word, boss bar gone")
	stage("Defeat", { RunClock = 610 })
	check(E.Word.Text == "DEFEAT", "Defeat: word")
	-- no RunStage: the previous objective keeps working, the new strip is hidden
	for _, k in ipairs({ "RunStage", "RunClock", "BeaconPos", "BeaconCharge", "RallyLeft", "BossHP", "BossMaxHP", "BossName" }) do
		setS(k, nil)
	end
	settle(0.8)
	check(not E.Strip.Visible and not E.Boss.Visible and not E.Cue.Visible, "no contract attributes: strip, boss bar and arrow hidden")
	check(not RunObjective.Active(state), "RunObjective.Active false without RunStage")
	setS("RunStage", "Survive")
	setS("RunClock", 300)
	settle(0.6)
end)

------------------------------------------------------------------------------------------
section("inventory", function()
	local ui = Hud.Elements()
	local function tiles(row: Instance)
		local t, e = 0, 0
		for _, c in ipairs(row:GetChildren()) do
			if c.Name == "Tile" then
				t += 1
			elseif c.Name == "Empty" then
				e += 1
			end
		end
		return t, e
	end
	local wt, we = tiles(ui.WeaponRow)
	local pt, pe = tiles(ui.PassiveRow)
	check(wt == 4 and we == 0, "weapon row: 4 tiles")
	check(pt == 3 and pe == 1, "passive row: 3 passives + 1 empty slot of 4")
	local first
	for _, c in ipairs(ui.WeaponRow:GetChildren()) do
		if c.Name == "Tile" and (not first or c.LayoutOrder < first.LayoutOrder) then
			first = c
		end
	end
	check(first ~= nil and first:FindFirstChild("EvolutionMark", true) ~= nil, "evolved weapon carries the evolution mark")
	local badge = first and first:FindFirstChild("Badge", true)
	check(badge ~= nil and badge.Text == "5", "rank badge shows the rank (5)")
	local pips = first and first:FindFirstChild("Pips", true)
	local shown = 0
	if pips then
		for _, c in ipairs(pips:GetChildren()) do
			if c:IsA("Frame") and c.Visible then
				shown += 1
			end
		end
	end
	check(shown == UI.MaxRank, "five rank pips under a tile (" .. shown .. ")")
	-- details: ranks, stats and the evolution requirement of a weapon that has not evolved
	sendInventory({ weapon("Whip", 5, false), weapon("Garlic", 3) }, { passive("Heart", 1) })
	settle(0.5)
	Hud.SetBuildOpen(true)
	settle(0.8)
	local list = ui.BuildList
	check(list ~= nil and textHas(list, "RANK 5"), "inventory panel lists ranks")
	check(list ~= nil and textHas(list, "EVOLVES INTO"), "inventory panel shows the evolution requirement")
	check(list ~= nil and textHas(list, "HEART"), "evolution requirement names the passive and what you have")
	press(Enum.KeyCode.Tab)
	check(not Hud.BuildOpen(), "Tab closes the inventory")
	press(Enum.KeyCode.Tab)
	check(Hud.BuildOpen(), "Tab opens the inventory")
	Hud.SetBuildOpen(false)
	sendInventory({ weapon("Whip", 5, true), weapon("Garlic", 3), weapon("Knives", 2), weapon("MagicOrb", 1) }, { passive("Might", 3), passive("Armor", 1), passive("Heart", 4) })
	settle(0.5)
end)

------------------------------------------------------------------------------------------
section("map", function()
	local ok = MapReveal.Loaded()
	check(ok, "the arena's NavGround parts are loaded for the map")
	if not ok then
		return
	end
	local root = lp.Character and lp.Character.PrimaryPart
	check(root ~= nil, "local hero exists")
	if not root then
		return
	end
	local cx, cz, size = MapReveal.Bounds()
	local px, pz = root.Position.X, root.Position.Z
	-- a far point inside the map bounds
	local fx = (px + 170 < cx + size / 2 - 5) and px + 170 or px - 170
	local nearP = Vector3.new(px + 20, root.Position.Y, pz + 10)
	local farP = Vector3.new(fx, root.Position.Y, pz)
	local folder = workspace:FindFirstChild("SwarmLoot") or Instance.new("Folder")
	folder.Name = "SwarmLoot"
	folder.Parent = workspace
	local function chest(name: string, pos: Vector3)
		local m = Instance.new("Model")
		m.Name = name
		for k, v in pairs({ Pos = pos, LootKind = "Chest", State = "Ready", Price = 140, LootId = 40 + #folder:GetChildren(), Hold = 0.4 }) do
			m:SetAttribute(k, v)
		end
		m.Parent = folder
		return m
	end
	-- forget what the run knew, then let the reveal run (hero + the living teammate at 4 Hz)
	MapReveal.ResetKnown()
	local nearChest = chest("MapNear", nearP)
	local farChest = chest("MapFar", farP)
	settle(1.5)
	check(MapReveal.Discovered(nearP.X, nearP.Z), "ground within ~80 studs of the hero is revealed")
	check(not MapReveal.Discovered(farP.X, farP.Z), "ground ~170 studs away is not revealed")
	local function visibleLoot(): number
		local n = 0
		for _, f in ipairs(MiniMap.Elements().Loot or {}) do
			if f.Visible then
				n += 1
			end
		end
		return n
	end
	local before = visibleLoot()
	check(before >= 1, "a chest in the revealed area is on the minimap (" .. before .. " marker)")
	-- a teammate far away reveals around themselves for everyone
	local mateRoot = ava.Character and ava.Character.PrimaryPart
	if mateRoot then
		mateRoot.CFrame = CFrame.new(farP + Vector3.new(0, 3.5, 0))
		settle(1.5)
		check(MapReveal.Discovered(farP.X, farP.Z), "a teammate's position is revealed for the whole team")
		check(visibleLoot() > before, "the far chest shows once the team has been near it (" .. visibleLoot() .. " markers)")
		mateRoot.CFrame = CFrame.new(centre + Vector3.new(14, 3.5, 6))
	end
	-- big map: M opens it, the run stays live, M closes it
	press(Enum.KeyCode.M)
	local BigMap = mod("BigMap")
	check(BigMap.IsOpen(), "M opens the larger map")
	check(UIState.Owner() ~= "BigMap", "the larger map never freezes the run (not a UIState owner)")
	press(Enum.KeyCode.M)
	check(not BigMap.IsOpen(), "M closes the larger map")
	nearChest:Destroy()
	farChest:Destroy()
	settle(0.4)
end)

------------------------------------------------------------------------------------------
section("interact", function()
	local root = lp.Character and lp.Character.PrimaryPart
	if not root then
		check(false, "interact: local hero exists")
		return
	end
	local fired = {}
	local net = RS:FindFirstChild("SwarmV2Net")
	local runNet = net and net:FindFirstChild("Run")
	local function priority(): string?
		settle(0.5)
		return RunInteract.Priority()
	end
	local folder = workspace:FindFirstChild("SwarmLoot") or Instance.new("Folder")
	folder.Name = "SwarmLoot"
	folder.Parent = workspace
	local chest = Instance.new("Model")
	chest.Name = "InteractChest"
	for k, v in pairs({ Pos = root.Position + Vector3.new(4, 0, 2), LootKind = "Chest", State = "Ready", Price = 140, LootId = 91, Hold = 0.4 }) do
		chest:SetAttribute(k, v)
	end
	chest.Parent = folder
	-- put every teammate out of range first
	local function away(p: Player)
		local r = p.Character and p.Character.PrimaryPart
		if r then
			r.CFrame = CFrame.new(root.Position + Vector3.new(80, 0, 80))
		end
	end
	away(ava)
	away(ben)
	setS("RunStage", "Survive")
	setS("BeaconPos", nil)
	-- chest alone
	local p1 = priority()
	local sub1 = RunInteract.Elements().Sub and RunInteract.Elements().Sub.Text or ""
	check(p1 == "Chest", "chest alone: the chest owns the interact key (" .. tostring(p1) .. ")")
	check(string.find(sub1, "140") ~= nil and string.find(sub1, "215") ~= nil, "chest prompt shows the cost and the balance (" .. sub1 .. ")")
	setS("TeamRunGold", 100)
	priority()
	local label2 = RunInteract.Elements().Label.Text
	local sub2 = RunInteract.Elements().Sub.Text
	check(string.find(string.upper(label2), "NOT ENOUGH GOLD") ~= nil and string.find(sub2, "40") ~= nil, "short on gold: says so and how much is missing (" .. sub2 .. ")")
	setS("TeamRunGold", 215)
	-- beacon beats the chest, but only with the server remote
	setS("RunStage", "BeaconAvailable")
	setS("BeaconPos", root.Position + Vector3.new(6, 0, 3))
	local noRemote = priority()
	local hadRemote = runNet and runNet:FindFirstChild("Interact")
	if not hadRemote then
		check(noRemote == "Chest", "no server Interact remote: the beacon shows no prompt, the chest still works (" .. tostring(noRemote) .. ")")
		local ev = Instance.new("RemoteEvent")
		ev.Name = "Interact"
		ev.Parent = runNet
		hadRemote = ev
	end
	hadRemote.OnServerEvent:Connect(function(_, kind, id, on)
		table.insert(fired, { kind, id, on })
	end)
	settle(1.2) -- the remote lookup retries each second
	local p2 = priority()
	check(p2 == "Beacon", "beacon beats the chest (" .. tostring(p2) .. ")")
	check(string.find(string.upper(RunInteract.Elements().Label.Text), "BEACON") ~= nil, "beacon prompt words: " .. RunInteract.Elements().Label.Text)
	-- revive beats the beacon
	ben:SetAttribute("Downed", true)
	local br = ben.Character and ben.Character.PrimaryPart
	if br then
		br.CFrame = CFrame.new(root.Position + Vector3.new(3, 0, 5))
	end
	local p3 = priority()
	check(p3 == "Revive", "revive beats beacon and chest (" .. tostring(p3) .. ")")
	check(string.find(RunInteract.Elements().Label.Text, "Ben") ~= nil, "revive prompt names the teammate (" .. RunInteract.Elements().Label.Text .. ")")
	-- holding the key sends the hold; letting go sends the release
	local before = #fired
	RunInteract.Press()
	settle(0.2)
	RunInteract.Release()
	settle(0.2)
	local sent = {}
	for i = before + 1, #fired do
		table.insert(sent, tostring(fired[i][1]) .. ":" .. tostring(fired[i][3]))
	end
	check(#fired >= before + 2 and fired[before + 1][1] == "Revive" and fired[before + 1][3] == true and fired[#fired][3] == false, "Press / Release send Revive hold on / off (" .. table.concat(sent, ",") .. ")")
	-- out of range / revived: nothing
	ben:SetAttribute("Downed", false)
	away(ben)
	setS("RunStage", "Survive")
	setS("BeaconPos", nil)
	chest:Destroy()
	check(priority() == nil and not RunInteract.Elements().Panel.Visible, "nothing in reach: no prompt")
end)

------------------------------------------------------------------------------------------
section("downed", function()
	local D = RunDowned.Elements
	ben:SetAttribute("Downed", true)
	check(RunDowned.StateOf(ava) == "Alive" and RunDowned.StateOf(ben) == "Downed", "StateOf reads Downed and Alive")
	check(RunDowned.StateOf(cleo) == "Out", "StateOf reads Eliminated as Out")
	setP("HP", 0)
	setP("Downed", true)
	setP("BleedLeft", 12)
	setP("ReviveProgress", 0)
	settle(0.8)
	check(D().Panel.Visible and RunDowned.Mode() == "Downed", "downed: panel shown")
	check(D().Title.Text == "YOU ARE DOWN", "downed: title")
	local secs = tonumber(D().Seconds.Text)
	check(secs ~= nil and secs <= 12 and secs >= 10, "downed: bleed-out seconds from BleedLeft (" .. D().Seconds.Text .. ")")
	check(D().Mate.Visible and string.find(D().MateText.Text, " m") ~= nil, "downed: nearest teammate with a distance (" .. D().MateText.Text .. ")")
	check(not D().Revive.Frame.Visible, "downed: no revive bar without progress")
	setP("ReviveProgress", 0.4)
	settle(0.5)
	check(D().Revive.Frame.Visible and string.find(D().Line.Text, "40%%") ~= nil, "downed: revive progress shows 40% (" .. D().Line.Text .. ")")
	setP("ReviveProgress", 0)
	settle(0.5)
	check(string.find(string.upper(D().Line.Text), "INTERRUPTED") ~= nil, "downed: Interrupted when the progress is lost (" .. D().Line.Text .. ")")
	settle(2.2)
	check(string.find(string.upper(D().Line.Text), "INTERRUPTED") == nil, "downed: the Interrupted line goes away")
	-- revived
	setP("Downed", false)
	setP("HP", 30)
	settle(0.6)
	check(RunDowned.Mode() == "Revived" and D().Title.Text == "REVIVED" and D().Panel.Visible, "revived: REVIVED shown")
	settle(2.6)
	check(RunDowned.Mode() == "Alive" and not D().Panel.Visible, "revived: panel leaves after a moment")
	-- out: spectate
	setP("Downed", false)
	setP("Eliminated", true)
	setP("Spectating", true)
	setP("HP", 0)
	settle(0.8)
	check(RunDowned.Mode() == "Out" and D().Title.Text == "YOU ARE OUT", "out: YOU ARE OUT")
	check(textHas(D().Panel, "STILL FIGHTING") and textHas(D().Panel, "AVA"), "out: says who is still fighting")
	check(textHas(D().Panel, "NOTHING IS AWARDED EARLY") and textHas(D().Panel, "WATCHING"), "out: results come at the end, who you watch")
	check(D().Prev.Instance.Visible and D().Next.Instance.Visible and D().Menu.Instance.Visible, "out: previous / next / run menu buttons")
	setP("Eliminated", nil)
	setP("Spectating", nil)
	setP("HP", 90)
	settle(0.8)
	check(RunDowned.Mode() == "Alive", "back to alive when the attributes clear")
end)

------------------------------------------------------------------------------------------
section("cards", function()
	local chosen, rerolled = {}, {}
	preview.remote("LevelUpChoose").OnServerEvent:Connect(function(_, index, offerId)
		table.insert(chosen, { index, offerId })
	end)
	preview.remote("LevelUpReroll").OnServerEvent:Connect(function(_, offerId)
		table.insert(rerolled, offerId)
	end)
	local function payload(over)
		local now = serverNow()
		local p = {
			OfferId = 7,
			Source = "Level",
			Level = 8,
			Deadline = now + 8.2,
			Seconds = 8.2,
			RerollsLeft = 2,
			Group = true,
			Choices = {
				{ Type = "WeaponUp", Id = "Whip", Name = "Rusty Sword", Category = "WeaponUpgrade", Rarity = "Rare", RankFrom = 2, RankTo = 3, Slot = 1,
					Lines = { { Label = "Damage", From = "14", To = "17" }, { Label = "Swings", From = "1", To = "2" } }, Synergy = "Blood Pact with Heart" },
				{ Type = "PassiveNew", Id = "Armor", Name = "Iron Plating", Category = "NewPassive", Rarity = "Uncommon", RankFrom = 0, RankTo = 2,
					Lines = { { Label = "Armor", From = "0", To = "6" } } },
				{ Type = "Evolve", Id = "Whip", Name = "Bloodblade", Category = "Evolution", Rarity = "Evolution", Slot = 1,
					Lines = { { Text = "Sword becomes Bloodblade" }, { Label = "Damage", From = "30", To = "52" } } },
			},
		}
		for k, v in pairs(over or {}) do
			p[k] = v
		end
		return p
	end
	-- older payloads normalise, and only new ones use the compact live cards
	local old = RunCards.Normalize({ Type = "WeaponUp", Id = "Whip", Name = "Sword", Level = 3, Rarity = "Legendary" }, 1)
	check(old.Rarity == "Evolution" and old.RarityLabel == "Evolution" and old.CategoryLabel == "Weapon upgrade" and old.RankTo == 3 and old.RankFrom == 2, "older card: rarity, category and ranks are mapped")
	local bare = RunCards.Normalize({}, 2)
	check(bare.Name == "Upgrade" and bare.Rarity == "Common" and #bare.Lines == 0 and bare.Slot == nil, "a card with no fields still normalises (Common, no lines)")
	check(not RunCards.Wants({ Choices = { { Type = "WeaponUp", Id = "Whip", Name = "Sword", Level = 2 } } }), "an older payload keeps the previous panel")
	check(RunCards.Wants(payload()), "a new-contract payload uses the live cards")

	C.fire("LevelUpOffer", payload())
	settle(0.15)
	local E = RunCards.Elements()
	check(RunCards.IsOpen() and E.Panel.Visible, "cards open")
	check(UIState.Owner() ~= "LevelUp" and UIState.Owner() ~= "Cards", "live: the cards are not a pause (UIState owner " .. tostring(UIState.Owner()) .. ")")
	local count = 0
	for _ in pairs(E.Cards) do
		count += 1
	end
	check(count == 3, "three cards")
	local allOk = true
	for i = 1, 3 do
		local it = E.Cards[i]
		local card = it and it.Card
		local word = card and string.upper(card.RarityLabel) or "?"
		local hasWord = it and textHas(it.Holder, "^" .. word .. "$")
		local hasSymbol = it and it.Holder:FindFirstChild("Symbol_" .. (card and card.Rarity or "?"), true) ~= nil
		local hasName = it and textHas(it.Holder, string.upper(card.Name))
		local hasCat = it and card.CategoryLabel and textHas(it.Holder, string.upper(card.CategoryLabel))
		if not (hasWord and hasSymbol and hasName and hasCat) then
			allOk = false
			preview.log(string.format("  card %d: word=%s symbol=%s name=%s category=%s", i, tostring(hasWord), tostring(hasSymbol), tostring(hasName), tostring(hasCat)))
		end
	end
	check(allOk, "every card: rarity word + rarity symbol + name + category (never colour alone)")
	check(textHas(E.Cards[1].Holder, "14") and textHas(E.Cards[1].Holder, "17") and textHas(E.Cards[1].Holder, "DAMAGE"), "card 1 shows current -> next (Damage 14 -> 17)")
	check(textHas(E.Cards[1].Holder, "RANK 2") and textHas(E.Cards[1].Holder, "3"), "card 1 shows the rank change")
	check(textHas(E.Cards[1].Holder, "WEAPON SLOT 1"), "card 1 names the slot")
	check(textHas(E.Cards[1].Holder, "SYNERGY"), "card 1 shows the synergy line")
	check(textHas(E.Panel or E.Cards[1].Holder.Parent.Parent, "REROLL"), "reroll button shown")
	check(not textHas(E.Panel, "RECOMMEND") and not textHas(E.Panel, "BEST PICK"), "no Recommended / best-pick label")
	local minPx = math.huge
	local _, _, sc = virtualSize()
	for _, t in ipairs(visibleTexts(E.Panel)) do
		minPx = math.min(minPx, t.Inst.TextSize * sc)
	end
	preview.log(string.format("  smallest card text %.1f pt on %s", minPx, device))
	check(minPx >= 12 - 0.01, "card text is at least 12 pt (smallest " .. string.format("%.1f", minPx) .. ")")
	-- the body lines (current -> next) are the text people read: 16 pt on a phone
	local bodyMin, bodyRows = math.huge, 0
	for _, it in pairs(E.Cards) do
		for _, d in ipairs(it.Holder:GetDescendants()) do
			if d.Name == "Line" and d:IsA("Frame") then
				bodyRows += 1
				for _, t in ipairs(visibleTexts(d)) do
					bodyMin = math.min(bodyMin, t.Inst.TextSize * sc)
				end
			end
		end
	end
	check(bodyRows > 0 and bodyMin >= (touchDevice and 16 or 14) - 0.01, string.format("card body lines are at least %d pt (smallest %.1f over %d rows)", touchDevice and 16 or 14, bodyMin, bodyRows))
	local rr = E.Reroll
	check(rr.Instance.AbsoluteSize.Y >= 48 - 0.5 and E.Cards[1].Hit.AbsoluteSize.Y >= 48 - 0.5, string.format("reroll and cards are at least 48 pt tall (%.0f / %.0f)", rr.Instance.AbsoluteSize.Y, E.Cards[1].Hit.AbsoluteSize.Y))
	-- the deadline ring follows the payload deadline
	local left = tonumber(E.Seconds.Text)
	check(left ~= nil and left >= 7 and left <= 9, "deadline ring counts from the payload deadline (" .. E.Seconds.Text .. ")")
	settle(2)
	local left2 = tonumber(E.Seconds.Text)
	check(left2 ~= nil and left ~= nil and left2 <= left - 1, "deadline ring counts down (" .. E.Seconds.Text .. ")")
	-- safe input: nothing confirms before the arm time; a held key never confirms
	C.fire("LevelUpOffer", payload({ OfferId = 8 }))
	settle(0.05)
	local n0 = #chosen
	UIS.InputBegan:_fire(key(Enum.KeyCode.Two), false)
	settle(0.05)
	check(#chosen == n0, "a key press right as the cards appear does nothing (safe input)")
	settle(0.6)
	UIS.InputBegan:_fire(key(Enum.KeyCode.Two), false)
	settle(0.1)
	check(#chosen == n0 + 1 and chosen[#chosen][1] == 2 and chosen[#chosen][2] == 8, "key 2 picks card 2 with the offer id (" .. tostring(chosen[#chosen] and (chosen[#chosen][1] .. "/" .. tostring(chosen[#chosen][2]))) .. ")")
	UIS.InputBegan:_fire(key(Enum.KeyCode.Three), false)
	settle(0.1)
	check(#chosen == n0 + 1, "a second pick is ignored")
	RunCards.Close()
	-- keys 1 and 3
	for _, pair in ipairs({ { Enum.KeyCode.One, 1 }, { Enum.KeyCode.Three, 3 } }) do
		C.fire("LevelUpOffer", payload({ OfferId = 20 + pair[2] }))
		settle(0.7)
		local n = #chosen
		UIS.InputBegan:_fire(key(pair[1]), false)
		settle(0.1)
		check(#chosen == n + 1 and chosen[#chosen][1] == pair[2], "key " .. pair[2] .. " picks card " .. pair[2])
		RunCards.Close()
	end
	-- touch: an early tap is ignored, a later whole tap picks
	C.fire("LevelUpOffer", payload({ OfferId = 30 }))
	settle(0.1)
	local n1 = #chosen
	preview.touch(RunCards.Elements().Cards[1].Hit, { hold = 0.05 })
	settle(0.1)
	check(#chosen == n1, "a touch right as the cards appear does nothing")
	settle(1)
	preview.touch(RunCards.Elements().Cards[3].Hit, { hold = 0.05 })
	settle(0.1)
	check(#chosen == n1 + 1 and chosen[#chosen][1] == 3, "a later tap picks the card")
	RunCards.Close()
	-- reroll
	C.fire("LevelUpOffer", payload({ OfferId = 40, RerollsLeft = 2 }))
	settle(0.7)
	local r0 = #rerolled
	RunCards.Reroll(key(Enum.KeyCode.R))
	settle(0.1)
	check(#rerolled == r0 + 1 and rerolled[#rerolled] == 40, "reroll sends the offer id")
	RunCards.Reroll(key(Enum.KeyCode.R))
	settle(0.1)
	check(#rerolled == r0 + 1, "a second reroll waits for the new set")
	RunCards.Close()
	C.fire("LevelUpOffer", payload({ OfferId = 41, RerollsLeft = 0 }))
	settle(0.7)
	local r1 = #rerolled
	RunCards.Reroll(key(Enum.KeyCode.R))
	settle(0.1)
	check(#rerolled == r1 and not RunCards.Elements().Reroll.IsEnabled(), "no rerolls left: the button is off and nothing is sent")
	RunCards.Close()
	-- a downed hero's offer waits (the ring holds), the status says so
	C.fire("LevelUpOffer", payload({ OfferId = 50 }))
	settle(0.5)
	setP("Downed", true)
	settle(0.3)
	local frozenA = RunCards.Elements().Seconds.Text
	settle(1.5)
	check(RunCards.Elements().Seconds.Text == frozenA and textHas(RunCards.Elements().Panel, "PAUSED WHILE YOU ARE DOWN"), "downed: the deadline ring holds and the cards say why")
	setP("Downed", nil)
	RunCards.Close()
	-- movement is never swallowed: the panel is not Active outside its own rectangle, no ContextAction sink
	C.fire("LevelUpOffer", payload({ OfferId = 60 }))
	settle(0.5)
	local panel = RunCards.Elements().Panel
	-- the panel's rectangle in the UI root's design px (RunCards places it with offsets)
	local pr = { X = panel.Position.X.Offset, Y = panel.Position.Y.Offset, W = panel.Size.X.Offset, H = panel.Size.Y.Offset }
	local eq = Hud.RunRect("Equipment")
	check(eq == nil or pr.Y + pr.H < eq.Y or not RunLayout.Overlaps(pr, eq, 0), "the cards stay clear of the equipment row")
	local vw, vh = virtualSize()
	check(pr.X >= 0 and pr.Y >= 0 and pr.X + pr.W <= vw + 0.5 and pr.Y + pr.H <= vh + 0.5, string.format("the cards stay on screen (%.0f,%.0f %.0fx%.0f of %.0fx%.0f)", pr.X, pr.Y, pr.W, pr.H, vw, vh))
	if touchDevice then
		local stick = Hud.RunRect("Stick")
		local jump = Hud.RunRect("Jump")
		local dash = Hud.RunRect("Dash")
		local hit = false
		for _, t in ipairs({ stick, jump, dash }) do
			if t and RunLayout.Overlaps(pr, t, 0) then
				hit = true
			end
		end
		check(not hit, "the cards never cover the joystick, JUMP or DASH")
	end
	RunCards.Close()
	settle(0.3)
	-- reduced motion: the panel does not grow in
	local Settings = preview.client("ClientSettings")
	local function popScale(id: number): number
		RunCards.Close()
		C.fire("LevelUpOffer", payload({ OfferId = id }))
		preview.advance(0.04, 30)
		local sc2 = RunCards.Elements().Panel:FindFirstChildWhichIsA("UIScale")
		return sc2 and sc2.Scale or 1
	end
	Settings.Set("ReducedEffects", false)
	local withMotion = popScale(70)
	Settings.Set("ReducedEffects", true)
	local withoutMotion = popScale(71)
	Settings.Set("ReducedEffects", false)
	check(withMotion < 0.999 and withoutMotion >= 0.999, string.format("reduced motion: the cards do not pop in (%.2f with motion, %.2f reduced)", withMotion, withoutMotion))
	RunCards.Close()
	settle(0.3)
end)

------------------------------------------------------------------------------------------
section("menu", function()
	setS("Participants", 3)
	UIBuilder.OpenPause()
	settle(0.8)
	check(UIState.IsShown("Pause"), "run menu opens in a live team run")
	check(anyText("THE RUN CONTINUES") ~= nil, "run menu says: The run continues")
	check(anyText("GAME NOT PAUSED") ~= nil or anyText("ENEM") ~= nil or anyText("NO ENEMIES") ~= nil, "run menu shows the danger line")
	UIBuilder.ClosePause()
	settle(0.5)
	press(Enum.KeyCode.Escape)
	check(UIState.IsShown("Pause"), "Escape opens the compact run menu during a run")
	press(Enum.KeyCode.Escape)
	check(not UIState.IsShown("Pause"), "Escape closes it again")
end)

------------------------------------------------------------------------------------------
section("results", function()
	-- pure helpers
	local rows = ResultsExtras.StatRows({ Kills = 1840, Elites = 12, Bad = -1, Nan = 0 / 0, Inf = math.huge, Word = "x", Revives = 2, Distance = 9120 })
	local labels = {}
	for _, r in ipairs(rows) do
		table.insert(labels, r[1])
	end
	check(#rows == 4 and rows[1][1] == "Kills" and rows[1][2] == "1,840", "stat rows: only real numbers, ordered (" .. table.concat(labels, ",") .. ")")
	local t1, t2, t3 = ResultsExtras.OutcomeText("Victory"), ResultsExtras.OutcomeText("Defeat"), ResultsExtras.OutcomeText("Left")
	check(t1 == "VICTORY" and t2 == "DEFEAT" and t3 == "YOU LEFT THE RUN" and ResultsExtras.OutcomeText("???") == nil, "outcome words for Victory / Defeat / Left")
	check(ResultsExtras.UnlockName("granny_boom") ~= "" and ResultsExtras.UnlockName({ Id = "x", Name = "Coach Crunch" }) == "Coach Crunch", "new unlock names")
	-- the screen
	C.setState({ Phase = "Results" })
	C.sendProfile(C.profile({ Frame = "Gold", Account = { XP = 2240 } }))
	setP("RunSaveStatus", nil)
	local returned = 0
	preview.remote("ReturnToLobby").OnServerEvent:Connect(function()
		returned += 1
	end)
	C.fire("RunResult", {
		Outcome = "Victory",
		Duration = 927,
		NewUnlocks = { "granny_boom", { Id = "coach_crunch", Name = "Coach Crunch" } },
		SaveStatus = "Pending",
		Stats = { Kills = 1840, Elites = 12, Chests = 7, Dashes = 96, Revives = 2, Distance = 9120, Bosses = 1 },
		Mode = "Trio",
		CharacterId = "Knight",
		Build = { Weapons = { { Id = "Whip", Level = 5, Evolved = true }, { Id = "MagicOrb", Level = 3 } }, Passives = { { Id = "Might", Level = 3 } } },
		Account = { Gained = 342, From = 7, To = 8, Into = 92, Need = 500, Rewards = {} },
		Time = 927, Kills = 1840, Gold = 640, GoldEarned = 640, GoldLost = 0, GoldRetention = 1, Level = 21, Damage = 186400,
		Arena = "Cliffwood", Seconds = 25, StagesCleared = 1, Stage = 1, BossKills = 1, BossFight = true, Items = {},
	})
	settle(2.5)
	local X = ResultsExtras.Elements()
	check(X.Outcome.Visible and X.OutcomeTitle.Text == "VICTORY", "results: the server-confirmed outcome")
	check(string.find(string.upper(X.OutcomeLine.Text), "CONFIRMED BY THE SERVER") ~= nil, "results: says the server confirmed it")
	check(X.Stats.Visible and #X.StatRows >= 5, "results: real run stats (" .. #X.StatRows .. " rows)")
	check(X.Unlocks.Visible and string.find(X.UnlockNames.Text, "Coach Crunch") ~= nil, "results: new unlocks listed (" .. X.UnlockNames.Text .. ")")
	check(anyText("15:27") ~= nil, "results: the run duration 15:27")
	check(X.Save.Visible and X.SaveText.Text == UI.Results.SaveLabels.Pending, "results: save status Pending (" .. X.SaveText.Text .. ")")
	setP("RunSaveStatus", "Saved")
	settle(0.4)
	check(X.SaveText.Text == UI.Results.SaveLabels.Saved, "results: Pending -> Saved (" .. X.SaveText.Text .. ")")
	setP("RunSaveStatus", "Failed")
	settle(0.4)
	check(X.SaveText.Text == UI.Results.SaveLabels.Failed and X.SaveText.TextColor3 == RunTheme.Danger, "results: save failure message in the danger colour (" .. X.SaveText.Text .. ")")
	setP("RunSaveStatus", "Pending")
	settle(0.4)
	local button = anyText("^RETURN TO LOBBY$")
	check(button ~= nil, "results: RETURN TO LOBBY button")
	if button then
		local face = button
		while face and not face:IsA("GuiButton") do
			face = face.Parent
		end
		check(face ~= nil and face.AbsoluteSize.Y >= 48 - 0.5, "results: the button is at least 48 pt tall")
		local target = button
		while target and not target:IsA("GuiButton") do
			target = target.Parent
		end
		if target then
			preview.click(target)
			settle(0.3)
			check(returned >= 1, "results: RETURN TO LOBBY fires the existing ReturnToLobby remote")
		else
			check(false, "results: RETURN TO LOBBY is a button")
		end
	end
	settle(0.5)
end)

preview.log(fails == 0 and "run-hud-regression: all PASS" or string.format("run-hud-regression: %d FAIL", fails))
