-- affix-icons-regression: the elite affix badges (client AffixIcons.lua, shared AffixIconData,
-- server AffixSight; Config.Features.AffixIcons, docs/next/AFFIX_ICONS.md).
--   1) data: three affixes, three different shapes and colours, a notice line each
--   2) each elite's badge matches its Affix attribute; non-elites and junk attributes get none
--   3) size 18-22 px and narrower than an enemy health bar (64 px)
--   4) the badge is removed when the elite dies (parked / no longer an elite / destroyed)
--   5) Reduced effects keeps the badge and drops the pulse
--   6) first-sight notice (server AffixSight with a fake server context): shown once per affix,
--      once per account, not for far elites, dead players, DEV-tainted runs, or with the switch off
--   7) the switch off removes every badge
-- Prints PASS / FAIL lines. Registered as a layout check on iphone, phone-portrait and pc (the
-- final frame shows one elite of each affix with its badge for check_layout).
local A = lib("arena")
local C = lib("common")
local s = A.build({ enemies = 0, swarm = false, seconds = 300, stage = 2 })
C.settle(2)
local Config = C.shared("Config")
local EnemyData = C.shared("EnemyData")
local Data = C.shared("AffixIconData")
local Icons = preview.client("AffixIcons")
local Settings = preview.client("ClientSettings")
local Sight = C.server("AffixSight")
local fails = 0
local function check(ok: boolean, label: string)
	if not ok then
		fails += 1
	end
	preview.log((ok and "PASS " or "FAIL ") .. label)
end

-- 1. data
local ids = Config.Enemies.EliteAffixes
local shapes, colours, notices = {}, {}, {}
local dataOk = #ids == 3
for _, id in ipairs(ids) do
	local e = Data.Get(id)
	dataOk = dataOk and e ~= nil
	if e then
		shapes[e.Shape] = true
		colours[tostring(e.Color)] = true
		notices[e.Notice] = true
		dataOk = dataOk and type(e.Notice) == "string" and #e.Notice > 10 and #e.Notice < 60
	end
end
local function count(t)
	local n = 0
	for _ in pairs(t) do
		n += 1
	end
	return n
end
check(dataOk, "every affix in Config.Enemies.EliteAffixes has badge data and a short notice line")
check(count(shapes) == #ids and count(colours) == #ids and count(notices) == #ids, "each affix has its own shape, colour and notice (colour-blind safe)")
check(Data.Get("Nope") == nil and Data.Get(5) == nil and Data.Get(nil) == nil, "junk affix values have no data")

-- elites
-- the client's VFX waits for these folders (a run creates them); this scene has no drops
for _, name in ipairs({ "SwarmGems", "SwarmPickups" }) do
	if not workspace:FindFirstChild(name) then
		local f = Instance.new("Folder")
		f.Name = name
		f.Parent = workspace
	end
end
local folder = workspace:FindFirstChild("SwarmEnemies") or Instance.new("Folder")
folder.Name = "SwarmEnemies"
folder.Parent = workspace
local eliteType = EnemyData.Enemies.Beetle and "Beetle" or nil
if not eliteType then
	for id, def in pairs(EnemyData.Enemies) do
		if not def.IsBoss and not def.Static and (not eliteType or id < eliteType) then
			eliteType = id
		end
	end
end
local nextId = 700
local function spawn(elite: boolean, affix: any, dx: number, dz: number)
	nextId += 1
	local def = EnemyData.Enemies[eliteType]
	local model, body = C.try("BuildEnemyShell", s.ModelBuilder.BuildEnemyShell, nextId, folder)
	if not (model and body) then
		return nil
	end
	local sizeMult = elite and Config.Enemies.EliteSizeMult or 1
	C.try("ApplyEnemyLook", s.ModelBuilder.ApplyEnemyLook, body, def, elite, sizeMult)
	body.CFrame = CFrame.new(Vector3.new(s.centre.X + dx, Config.ArenaOrigin.Y + def.Size.Y * sizeMult / 2, s.centre.Z + dz))
	body:SetAttribute("Elite", elite)
	body:SetAttribute("Affix", affix)
	body:SetAttribute("Type", eliteType)
	return body
end
local function refresh(t: number?)
	C.settle(t or 0.4)
	Icons.Refresh()
	C.settle(0.3)
	return Icons.Debug()
end
local function find(list, body)
	for _, b in ipairs(list) do
		if b.Body == body then
			return b
		end
	end
	return nil
end

-- 2. badge per affix
local swift = spawn(true, "Swift", -9, 12)
local shield = spawn(true, "Shielded", 0, 14)
local burning = spawn(true, "Burning", 9, 12)
local plain = spawn(false, nil, 14, 6)
local junk = spawn(true, "Frozen", -14, 6)
local list = refresh()
check(#list == 3, "three affix elites get three badges and the plain enemy and the junk affix get none (got " .. #list .. ")")
local bs, bh, bb = find(list, swift), find(list, shield), find(list, burning)
check(bs ~= nil and bs.Affix == "Swift" and bs.Shape == "Lines", "Swift: speed-lines badge")
check(bh ~= nil and bh.Affix == "Shielded" and bh.Shape == "Shield", "Shielded: shield badge")
check(bb ~= nil and bb.Affix == "Burning" and bb.Shape == "Flame", "Burning: flame badge")
check(find(list, plain) == nil and find(list, junk) == nil, "no badge on a non-elite or an unknown affix")

-- 3. size
local sizeOk, narrow = true, true
for _, b in ipairs(list) do
	sizeOk = sizeOk and type(b.Size) == "number" and b.Size >= 18 and b.Size <= 22
	narrow = narrow and b.Width <= 64
end
check(sizeOk, "badges are 18-22 px (" .. tostring(Config.AffixIcons.Size) .. ")")
check(narrow, "a badge is never wider than an enemy health bar (64 px)")

-- an affix change on a reused body swaps the badge
swift:SetAttribute("Affix", "Burning")
list = refresh()
local swapped = find(list, swift)
check(swapped ~= nil and swapped.Affix == "Burning" and swapped.Shape == "Flame" and #list == 3, "a reused body that rolls another affix gets the matching badge")
swift:SetAttribute("Affix", "Swift")
list = refresh()

-- 4. removed on death
shield:SetAttribute("Elite", false)
list = refresh()
check(find(list, shield) == nil and #list == 2, "no longer an elite: badge removed")
shield:SetAttribute("Elite", true)
list = refresh()
check(find(list, shield) ~= nil, "elite again: badge back")
burning.CFrame = CFrame.new(burning.Position.X, -150, burning.Position.Z) -- parked in the pool = dead
list = refresh()
check(find(list, burning) == nil and #list == 2, "dead (parked) elite: badge removed")
local gone = spawn(true, "Swift", 16, 14)
list = refresh()
check(find(list, gone) ~= nil and #list == 3, "a new elite: badge appears")
gone.Parent:Destroy()
list = refresh()
check(find(list, gone) == nil and #list == 2, "destroyed elite: badge removed")
burning.CFrame = CFrame.new(burning.Position.X, Config.ArenaOrigin.Y + 3, burning.Position.Z)
list = refresh()
check(#list == 3, "three badges again for the layout frame")

-- 5. Reduced effects
local pulsing = true
for _, b in ipairs(list) do
	pulsing = pulsing and b.Pulse == true
end
Settings.Set("ReducedEffects", true)
list = refresh()
local still, calm = #list == 3, true
for _, b in ipairs(list) do
	calm = calm and b.Pulse == false
end
check(pulsing, "badges pulse normally")
check(still and calm, "Reduced effects keeps the badges and drops the pulse")
Settings.Set("ReducedEffects", false)
list = refresh()
local back = #list == 3
for _, b in ipairs(list) do
	back = back and b.Pulse == true
end
check(back, "pulse returns when Reduced effects is off")

-- 6. first-sight notice, server side (fake context: players, data, notices)
local function fakeCtx(players, datas, sent)
	return {
		RunManager = {
			GetRunPlayers = function()
				return players
			end,
			Notify = function(player, text, _color, meta)
				table.insert(sent, { Player = player, Text = text, Id = meta and meta.Id })
			end,
		},
		DataService = {
			GetData = function(player)
				return datas[player]
			end,
		},
	}
end
local function elite(affix, x, z)
	return { Alive = true, Elite = true, Affix = affix, Pos = Vector3.new(x, 0, z) }
end
local pA = { Name = "A", Parent = workspace }
local pB = { Name = "B", Parent = workspace }
local rpA = { Player = pA, Alive = true, Root = { Position = Vector3.new(0, 0, 0) } }
local rpB = { Player = pB, Alive = true, Root = { Position = Vector3.new(500, 0, 0) } }
local dataA, dataB = { SeenAffixes = {} }, { SeenAffixes = {} }
local sent = {}
local ctx = fakeCtx({ rpA, rpB }, { [pA] = dataA, [pB] = dataB }, sent)
local near, far = Config.AffixIcons.SightRange - 10, Config.AffixIcons.SightRange + 40
check(Sight.Check(ctx, { elite("Shielded", far, 0) }) == 0 and #sent == 0, "an elite beyond sight range shows no notice")
check(Sight.Check(ctx, { elite("Shielded", near, 0) }) == 1 and #sent == 1 and sent[1].Text == Data.Get("Shielded").Notice and sent[1].Player == pA, "the first near Shielded elite shows its line once, to the player who met it")
check(sent[1].Id == "affix.Shielded" and dataA.SeenAffixes.Shielded == true and dataB.SeenAffixes.Shielded == nil, "saved for that player's account only (SeenAffixes)")
check(Sight.Check(ctx, { elite("Shielded", near, 0), elite("Shielded", -near, 0) }) == 0 and #sent == 1, "never again for that affix (two more Shielded elites)")
check(Sight.Check(ctx, { elite("Swift", near, 0), elite("Burning", -near, 5) }) == 2 and #sent == 3, "the other affixes each show once")
check(Sight.Check(ctx, { elite("Swift", 3, 3), elite("Burning", 3, 3) }) == 0, "a repeat sight of all three shows nothing")
local junkSent = Sight.Check(ctx, { { Alive = true, Elite = true, Affix = "Frozen", Pos = Vector3.new(5, 0, 0) }, { Alive = false, Elite = true, Affix = "Swift", Pos = Vector3.new(5, 0, 0) } })
check(junkSent == 0, "an unknown affix and a dead elite show nothing")
-- a second account meets Burning: its own first time
rpB.Root.Position = Vector3.new(0, 0, 0)
sent = {}
ctx = fakeCtx({ rpA, rpB }, { [pA] = dataA, [pB] = dataB }, sent)
check(Sight.Check(ctx, { elite("Burning", 4, 4) }) == 1 and #sent == 1 and sent[1].Player == pB, "another account gets its own first notice")
-- guards
local dataC = { SeenAffixes = {} }
local pC = { Name = "C", Parent = workspace }
local rpC = { Player = pC, Alive = true, Root = { Position = Vector3.new(0, 0, 0) }, DevTainted = true }
sent = {}
ctx = fakeCtx({ rpC }, { [pC] = dataC }, sent)
check(Sight.Check(ctx, { elite("Swift", 5, 5) }) == 0 and next(dataC.SeenAffixes) == nil, "a DEV-tainted run neither shows nor records the notice")
rpC.DevTainted = false
rpC.Alive = false
check(Sight.Check(ctx, { elite("Swift", 5, 5) }) == 0 and next(dataC.SeenAffixes) == nil, "a dead player has not met it")
rpC.Alive = true
dataC.DevBoosted = true
check(Sight.Check(ctx, { elite("Swift", 5, 5) }) == 0 and next(dataC.SeenAffixes) == nil, "a DEV-boosted profile neither shows nor records the notice")
dataC.DevBoosted = false
dataC.SeenAffixes = "junk"
check(Sight.Check(ctx, { elite("Swift", 5, 5) }) == 1 and dataC.SeenAffixes.Swift == true, "a junk SeenAffixes value is repaired and the notice shows")
Config.Features.AffixIcons = false
dataC.SeenAffixes = {}
check(Sight.Check(ctx, { elite("Swift", 5, 5) }) == 0 and next(dataC.SeenAffixes) == nil, "switch off: no notice and nothing saved")

-- 7. switch off removes every badge
list = refresh()
check(#list == 0, "switch off: no badges (got " .. #list .. ")")
Config.Features.AffixIcons = true
list = refresh(0.6)
check(#list == 3, "switch on again: the three badges are back for the layout frame")

preview.log(fails == 0 and "affix-icons-regression: all PASS" or string.format("affix-icons-regression: %d FAIL", fails))
