-- damage-settings-regression: the damage number options travel through the existing settings
-- path against the real server (Config.Features.DamageNumberOptions, docs/next/DAMAGE_NUMBERS.md).
--   1) a new profile has DamageNumbers off, DamageNumberSize Normal, CombineNumbers on
--   2) SaveSettings with Big + Combine off is stored and the server's DamageNumbers attribute follows
--   3) junk values (unknown size, wrong types) are refused and change nothing
--   4) an older save without the new keys gets the defaults when it loads (Migrate)
--   5) the server sends numbers only while the setting is on
-- PASS / FAIL lines; any FAIL fails the regression.
local C = lib("common")
local Players = game:GetService("Players")
local me = Players.LocalPlayer
preview.forceMeshesUploaded()
preview.startServer()
preview.advance(2)

local Config = C.shared("Config")
local DS = preview.server("DataService")
local DN = preview.server("DamageNumbers")
local data = assert(DS.GetData(me), "profile missing")
C.startClient()
preview.advance(1)

local fails = 0
local function check(label: string, ok: boolean)
	if not ok then
		fails += 1
	end
	preview.log((ok and "PASS" or "FAIL") .. "  " .. label)
end
local function save(settings)
	preview.remote("SaveSettings"):FireServer(settings)
	preview.advance(0.5)
end

local fresh = DS.DefaultData()
check("a new profile: numbers off, size Normal, Combine on", fresh.Settings.DamageNumbers == false and fresh.Settings.DamageNumberSize == "Normal" and fresh.Settings.CombineNumbers == true)

save({ DamageNumbers = true, DamageNumberSize = "Big", CombineNumbers = false })
check("Big + Combine off are stored in the profile", data.Settings.DamageNumbers == true and data.Settings.DamageNumberSize == "Big" and data.Settings.CombineNumbers == false)
check("the server's DamageNumbers attribute follows (on)", me:GetAttribute("DamageNumbers") == true)

save({ DamageNumberSize = "Huge", CombineNumbers = "yes" })
check("an unknown size and a wrong type change nothing", data.Settings.DamageNumberSize == "Big" and data.Settings.CombineNumbers == false)
save({ DamageNumberSize = 7, DamageNumbers = "on" })
check("numbers for strings and strings for booleans are refused", data.Settings.DamageNumberSize == "Big" and data.Settings.DamageNumbers == true)

local old = DS.Migrate({ Version = Config.Data.SchemaVersion, Settings = { Music = 0.3, Sfx = 0.4, DamageNumbers = true } })
check("an older save gets the defaults for the new keys and keeps its own", old.Settings.DamageNumberSize == "Normal" and old.Settings.CombineNumbers == true and old.Settings.DamageNumbers == true and old.Settings.Music == 0.3)

local got = {}
preview.remote("DamageNumbers").OnClientEvent:Connect(function(d)
	table.insert(got, d)
end)
local function hit()
	DN.Add(me, 5, 40, false)
	preview.advance(0.4)
end
hit()
check("numbers on: the server sends the batch", #got == 1)
save({ DamageNumbers = false })
check("the server's DamageNumbers attribute follows (off)", me:GetAttribute("DamageNumbers") == false)
hit()
check("numbers off: nothing is sent", #got == 1)

preview.log(fails == 0 and "damage-settings-regression: all PASS" or string.format("damage-settings-regression: %d FAIL", fails))
