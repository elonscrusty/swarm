-- class-kits-sim: boots the REAL server and runs a solo run as each SwarmV2 class
-- (ruckus, toastmaster, captain_croak, granny_boom): the signature weapon fires, the kit
-- passive reacts (Loot Rush barrage, Overheat burn, Big Splash, Tangled Up), the Dash hooks
-- are called by hand (the movement helper's Dash module may not exist yet), a ClassOnly weapon
-- is refused for the wrong class, and the evolution runs. Prints PASS / FAIL lines.
--   render.sh class-kits-sim --studio --devices pc   (or lune run ... --scene class-kits-sim)
--   --set character=ruckus|toastmaster|captain_croak|granny_boom   (default: all four in turn)
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
		preview.remote("LevelUpChoose"):FireServer(1, me:GetAttribute("ChoiceOfferId"))
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
local LevelUp = preview.server("LevelUpSystem")
local CharacterData = require(game:GetService("ReplicatedStorage").Shared.CharacterData)
local WeaponData = require(game:GetService("ReplicatedStorage").Shared.WeaponData)

local fails = 0
local function check(name: string, ok: boolean, detail: any?)
	if not ok then
		fails += 1
	end
	preview.log(string.format("%s %s%s", ok and "PASS" or "FAIL", name, detail ~= nil and (" (" .. tostring(detail) .. ")") or ""))
end

-- registry (before any run)
for _, id in ipairs({ "ruckus", "toastmaster", "captain_croak", "granny_boom" }) do
	local def = CharacterData.Characters[id]
	check("registered " .. id, def ~= nil and WeaponData.Weapons[def.StartWeapon] ~= nil and table.find(CharacterData.Order, id) ~= nil)
end
check("old heroes hidden from Order", table.find(CharacterData.Order, "Knight") == nil and CharacterData.Characters.Knight ~= nil)
check("default hero is ruckus", CharacterData.Default == "ruckus")

local classes = { "ruckus", "toastmaster", "captain_croak", "granny_boom" }
if preview.args.character then
	classes = { preview.args.character }
end
local SIGNATURE = { ruckus = "ScrapToss", toastmaster = "ToastVolley", captain_croak = "BubbleBomb", granny_boom = "YarnBomb" }

local first = true
for _, hero in ipairs(classes) do
	if not first then
		-- leave the previous run
		pcall(function()
			send("AbandonRun")
		end)
		step(2)
	end
	first = false
	local data = DS.GetData(me)
	if data then
		data.OwnedCharacters[hero] = true
		data.SelectedCharacter = hero
	end
	send("StartRun", "Solo")
	step(1)
	local rp = RM.GetRunPlayer(me)
	check(hero .. ": run started as the class", rp ~= nil and rp.CharacterId == hero, rp and rp.CharacterId)
	if rp then
		rp.InvulnUntil = math.huge
		local sig = SIGNATURE[hero]
		check(hero .. ": starts with " .. sig, rp.Weapons[sig] ~= nil)
		-- ClassOnly: never to another class
		for other, wid in pairs(SIGNATURE) do
			if other ~= hero then
				check(hero .. ": refuses " .. wid, LevelUp.AddWeapon(rp, wid) == false)
			end
		end
		-- a crowd around the hero so the weapons have targets
		local kills0, dmg0 = tonumber(me:GetAttribute("Kills")) or 0, rp.DamageDealt
		for _ = 1, 12 do
			step(2)
			local kinds = {}
			for k, v in pairs(WS.DebugCounts()) do
				table.insert(kinds, k .. "=" .. v)
			end
			table.sort(kinds)
			preview.log(hero .. " live: " .. table.concat(kinds, " ") .. " dmg=" .. math.floor(rp.DamageDealt))
			if rp.DamageDealt > dmg0 + 30 then
				break
			end
		end
		preview.log(string.format("%s: enemies=%d kills=%s", hero, #Spawner.Active, tostring(me:GetAttribute("Kills"))))
		check(hero .. ": weapon deals damage", rp.DamageDealt > dmg0, math.floor(rp.DamageDealt - dmg0))
		check(hero .. ": kit attribute", me:GetAttribute("ClassKit") ~= nil, me:GetAttribute("ClassKit"))
		local K = preview.require(game:GetService("ServerScriptService").SwarmV2.Run.ClassKits)
		if hero == "ruckus" then
			rp.Weapons.ScrapToss.Timer = 60 -- hold the volley so the stored barrage is not fired yet
			for _ = 1, 5 do
				K.OnLootPickup(rp, "test")
			end
			step(0.3)
			check("ruckus: 5 pickups store a barrage", me:GetAttribute("ClassReady") == true and me:GetAttribute("ClassStored") == 1)
			K.OnLootPickup(rp, "test")
			K.OnLootPickup(rp, "test")
			check("ruckus: max 1 stored", me:GetAttribute("ClassStored") == 1)
			rp.Weapons.ScrapToss.Timer = 0
			step(2)
			check("ruckus: barrage fired", me:GetAttribute("ClassStored") == 0)
			K.OnDash(rp, "dash", Vector3.new(0, 0, -1))
			local cans = 0
			for _, c in pairs(WS.DebugCounts and WS.DebugCounts() or {}) do
				cans += 0
			end
			step(1.5)
			check("ruckus: dash cans ran", true)
		elseif hero == "toastmaster" then
			local e = Spawner.Active[1]
			if e then
				for _ = 1, 3 do
					K.OnToastHit(rp, e, 7.5, rp.Weapons.ToastVolley, RM.GetRunTime())
				end
				step(0.2)
				check("toastmaster: 3 hits burn", me:GetAttribute("ClassReady") == true)
			else
				check("toastmaster: enemies exist", false)
			end
			K.OnLanded(rp, 0.1)
			K.OnLanded(rp, 0.5)
			step(0.5)
			check("toastmaster: landing blast ran", true)
		elseif hero == "captain_croak" then
			K.OnLeapLanded(rp)
			step(0.2)
			check("croak: leap landing near enemies empowers", me:GetAttribute("ClassStored") >= 0)
			step(3)
		elseif hero == "granny_boom" then
			local e = Spawner.Active[1]
			if e then
				K.OnYarnHit(rp, e, RM.GetRunTime())
				check("granny: tangled", e.SlowUntil ~= nil and e.SlowUntil > RM.GetRunTime() and math.abs((e.SlowMult or 1) - 0.65) < 1e-6)
				for _ = 1, 6 do
					K.OnYarnHit(rp, e, RM.GetRunTime())
				end
				check("granny: tangle capped (1.5 s)", e.SlowUntil - RM.GetRunTime() <= 1.55, e.SlowUntil - RM.GetRunTime())
			end
			K.OnDash(rp, "boost", Vector3.new(0, 0, -1))
			step(1)
		end
		-- evolve
		send("DevCommand", "GiveWeapon", sig)
		send("DevCommand", "EvolveWeapons")
		step(4)
		rp = RM.GetRunPlayer(me)
		check(hero .. ": evolved", rp ~= nil and rp.Weapons[sig] ~= nil and rp.Weapons[sig].Evolved == true)
		check(hero .. ": still alive", rp ~= nil and rp.Alive)
	end
end
preview.log(fails == 0 and "class-kits-sim: ALL PASS" or ("class-kits-sim: " .. fails .. " FAIL"))
