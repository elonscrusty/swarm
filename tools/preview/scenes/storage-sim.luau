-- Probe failures must never substitute a fresh live profile for an existing save.
local Config = preview.shared("Config")
local Data = preview.server("DataService")
local player = game:GetService("Players").LocalPlayer
Config.Data.LoadAttempts = 1
Config.Data.SaveAttempts = 1
local store = game:GetService("DataStoreService"):GetDataStore(Config.Data.StoreName)
local saved = Data.DefaultData()
saved.Gold = 777
saved.Stats.Wins = 1
saved.DifficultyClears = nil -- historical save from before tier progression
local dailyWinner = Data.DefaultData()
dailyWinner.Stats.Wins = 1
assert(not Data.Migrate(dailyWinner).DifficultyClears.Standard, "new Daily wins must not grandfather a Standard clear")
local malformed = Data.DefaultData()
malformed.Gold = math.huge
malformed.RunEscrow = { Id = "bad", Gold = "100", Stages = "2" }
malformed = Data.Migrate(malformed)
assert(malformed.Gold == 0 and malformed.RunEscrow.Gold == 100 and malformed.RunEscrow.Stages == 2, "ledger migration must normalize finite numeric values")
-- Hero Mastery (schema 6 -> 7): the shared stat levels are copied to every hero; gold,
-- Meta and the account upgrades are untouched; running Migrate again changes nothing
local CharacterData = preview.shared("CharacterData")
local v6 = Data.DefaultData()
v6.Version = 6
v6.Heroes, v6.HeroUpgrades = nil, nil
v6.Gold = 4321
v6.Meta = { MaxHP = 5, Might = 3, Revive = 1 }
local v7 = Data.Migrate(v6)
assert(v7.Version == 7 and v7.Gold == 4321, "migration must keep gold and reach schema 7")
assert(v7.Meta.MaxHP == 5 and v7.Meta.Might == 3 and v7.Meta.Revive == 1, "Meta must be kept for rollback")
for _, id in ipairs(CharacterData.Order) do
	local t = v7.HeroUpgrades[id]
	assert(t and t.MaxHP == 5 and t.Might == 3 and t.Revive == nil and t.Armor == nil, "every hero must get the shared stat levels: " .. id)
end
assert(type(v7.Heroes) == "table", "Heroes must exist")
local again = Data.Migrate(v7)
for _, id in ipairs(CharacterData.Order) do
	assert(again.HeroUpgrades[id].MaxHP == 5 and again.HeroUpgrades[id].Might == 3, "migration must be idempotent")
end
assert(again.Gold == 4321, "a second migrate must not touch gold")
local junk = Data.DefaultData()
junk.Heroes = { Knight = { XP = "12.7", Runs = -3 }, Mage = "bad", Nobody = { XP = 5 } }
junk.HeroUpgrades = { Knight = { MaxHP = 99, Might = -2, Signature = 7.9, Bogus = 3 }, Rogue = "bad" }
junk = Data.Migrate(junk)
assert(junk.Heroes.Knight.XP == 12 and junk.Heroes.Knight.Runs == 0 and junk.Heroes.Mage.XP == 0, "malformed mastery must be clamped")
assert(junk.HeroUpgrades.Knight.MaxHP == 20 and junk.HeroUpgrades.Knight.Might == nil and junk.HeroUpgrades.Knight.Signature == 5, "malformed hero levels must be clamped")
assert(junk.HeroUpgrades.Knight.Bogus == 3 and type(junk.HeroUpgrades.Rogue) == "table", "unknown ids kept, bad tracks reset")
local bad = Data.Migrate({ Version = 6, Meta = "junk", Gold = 10 })
assert(bad.Gold == 10 and type(bad.HeroUpgrades.Knight) == "table", "a v6 save with junk Meta still migrates")
preview.log("PASS schema 7 hero mastery migration (seeded, idempotent, clamped)")
store:SetAsync(Config.Data.KeyPrefix .. player.UserId, { Data = saved })
local unavailable = preview.args.outage == "all"
preview.failDataStores(true, unavailable, unavailable)
Data.Init({})
Data.Start()
preview.advance(1)
if unavailable then
	assert(Data.GetProfile(player) == nil, "unavailable live store must refuse a fresh profile")
	assert(not Data.ForceSave(player), "unavailable live storage must not report durable success")
	preview.log("PASS live outage refuses fresh profiles and receipt save")
else
	local loaded = Data.GetData(player)
	assert(loaded and loaded.Gold == 777, "read probe failure must keep and load existing save")
	assert(loaded.DifficultyClears.Standard, "existing winners retain Veteran access")
	assert(Data.ForceSave(player), "working live writes remain usable after failed probe")
	preview.log("PASS live failed probe preserves saved balance and unlocks")
end
