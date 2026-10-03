-- weapons-sim: boots the REAL server (like stage-sim) and runs a solo run with the dev
-- loadout of every weapon added with the Alchemist / Engineer / Necromancer (DevCommand
-- "NewWeapons": all eight at level 12; --set weapons=armoury: the ten held ones), then evolves them all (DevCommand "EvolveWeapons"),
-- printing what is alive (projectiles by kind, kills, damage, HP) every few seconds. A logic
-- smoke test for the new weapon behaviours, the hero traits and their effects; the final
-- frame is the arena with the effects. Run it with --studio (dev commands are Studio only):
--   render.sh weapons-sim --studio --devices pc
--   --set character=Necromancer|Engineer|Alchemist   the hero (owned for the test)
--   --set seconds=12                                  seconds per phase
--   --set weapons=armoury                             the ten armoury-batch weapons instead
local C = lib("common")
local Players = game:GetService("Players")
preview.forceMeshesUploaded()
preview.startServer()
preview.advance(1)
C.startClient()
preview.advance(1)
local me = Players.LocalPlayer
local advance = preview.advance
local function pickLevels()
	for _ = 1, 20 do
		if not me:GetAttribute("Paused") then
			return
		end
		preview.remote("LevelUpChoose"):FireServer(1)
		advance(0.3)
	end
end
local function step(t)
	local left = t
	while left > 0 do
		local dt = math.min(left, 0.5)
		advance(dt)
		left -= dt
		pickLevels()
	end
end
local function send(name, ...)
	preview.remote(name):FireServer(...)
	advance(0.2)
	pickLevels()
end

local RM = preview.server("RunManager")
local WS = preview.server("WeaponSystem")
local DS = preview.server("DataService")
local Spawner = preview.server("EnemySpawner")
local hero = preview.args.character or "Necromancer"
local data = DS.GetData(me)
if data then
	data.OwnedCharacters[hero] = true
	data.SelectedCharacter = hero
end
send("StartRun", "Solo")
step(1)
local rp = RM.GetRunPlayer(me)
if rp then
	rp.InvulnUntil = math.huge -- the test is about the weapons, not survival
end

local function report(label)
	rp = RM.GetRunPlayer(me)
	local kinds = {}
	local counts = WS.DebugCounts and WS.DebugCounts() or {}
	for k, v in pairs(counts) do
		table.insert(kinds, k .. "=" .. v)
	end
	table.sort(kinds)
	local weapons = {}
	if rp then
		for _, id in ipairs(rp.WeaponOrder) do
			local w = rp.Weapons[id]
			table.insert(weapons, id .. (w.Evolved and "*" or tostring(w.Level)))
		end
	end
	preview.log(string.format("%-14s hero=%s kills=%s dmg=%d HP=%s/%s enemies=%d | %s | %s", label, tostring(rp and rp.CharacterId), tostring(me:GetAttribute("Kills")),
		rp and math.floor(rp.DamageDealt) or -1, tostring(me:GetAttribute("HP")), tostring(me:GetAttribute("MaxHP")), #Spawner.Active, table.concat(kinds, " "), table.concat(weapons, " ")))
end

local seconds = tonumber(preview.args.seconds) or 12
report("start")
if preview.args.weapons == "armoury" then
	-- the armoury batch instead (GiveWeapon: each at level 12)
	for _, id in ipairs({ "WardShields", "Earthsplitter", "Starfall", "Sling", "PlagueCenser", "Sawblade", "VineSnare", "WarHorn", "SpiritWisps", "Vortex" }) do
		send("DevCommand", "GiveWeapon", id)
	end
else
	send("DevCommand", "NewWeapons")
end
report("loadout")
-- walk in a circle so the Fire Trail and the facing-based weapons work
local function walk(t)
	local left = t
	local a = 0
	while left > 0 do
		rp = RM.GetRunPlayer(me)
		if rp and rp.Root then
			a += 0.35
			local dir = Vector3.new(math.cos(a), 0, math.sin(a))
			rp.MoveDir = dir
			rp.Facing = dir
			rp.Root.CFrame = rp.Root.CFrame + dir * 3
		end
		step(0.5)
		left -= 0.5
	end
end
for i = 1, 3 do
	walk(seconds / 3)
	report("lv8 +" .. i * math.floor(seconds / 3) .. "s")
end
send("DevCommand", "EvolveWeapons")
report("evolved")
for i = 1, 3 do
	walk(seconds / 3)
	report("evo +" .. i * math.floor(seconds / 3) .. "s")
end
-- a stage change clears every weapon thing (patches, turrets, totems, hooks)
WS.Clear()
step(0.5)
report("after Clear")
walk(2)
report("refire")
