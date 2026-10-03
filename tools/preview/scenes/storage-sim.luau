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
