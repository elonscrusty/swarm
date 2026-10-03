-- Standalone pure-data checks; native Lune can run this without a Roblox client.
local Difficulty = require("../src/shared/DifficultyData")
local fresh = { Stats = { Wins = 0 }, DifficultyClears = {} }
assert(Difficulty.IsUnlocked(fresh, "Standard"))
assert(not Difficulty.IsUnlocked(fresh, "Veteran"))
assert(not Difficulty.IsUnlocked(fresh, "not-a-tier"))
assert(Difficulty.Selected({ Difficulty = "Nightmare", DifficultyClears = {} }) == "Standard")
assert(not Difficulty.IsUnlocked({ Stats = { Wins = 1 }, DifficultyClears = {} }, "Veteran"), "Daily wins must not bypass Standard completion")
assert(Difficulty.IsUnlocked({ Stats = { Wins = 1 }, DifficultyClears = { Standard = true } }, "Veteran"), "migrated historical winners retain next-tier access")
assert(not Difficulty.IsUnlocked({ Stats = { Wins = 1 } }, "Nightmare"))
assert(Difficulty.IsUnlocked({ DifficultyClears = { Veteran = true } }, "Nightmare"))
assert(Difficulty.Tiers.Standard.Gold == 1 and Difficulty.Tiers.Nightmare.Gold > Difficulty.Tiers.Veteran.Gold)
print("PASS difficulty unlock boundaries, historical wins, invalid tiers and reward scaling")
