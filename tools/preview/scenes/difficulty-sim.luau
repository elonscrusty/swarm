-- Exercise actual RunModifiers without starting a combat simulation.
local C = lib("common")
local s = C.bootServer()
local player = game:GetService("Players").LocalPlayer
local profile = { Stats = { Wins = 0 }, Difficulty = "Nightmare", DifficultyClears = {}, OwnedCharacters = {}, Curses = {} }
local rp = { Player = player, DevTainted = false }
local participating = false
local Modifiers = C.server("RunModifiers")
Modifiers.Init({
	DataService = { GetData = function() return profile end, OnProfileLoaded = function() end },
	RunManager = { GetRunPlayer = function() return rp end, IsDevTainted = function() return rp.DevTainted end, IsParticipant = function() return participating end, Notify = function() end },
	GoldSystem = { SyncProfile = function() end },
})
Modifiers.Start()
local function select(id)
	s.Remotes.Get("SetDifficulty"):FireServer(id)
	preview.advance(0.3)
end
profile.Difficulty = "Standard"
select("Nightmare")
assert(profile.Difficulty == "Standard", "locked difficulty request must be rejected")
select({ "Veteran" })
assert(profile.Difficulty == "Standard", "malformed difficulty request must be rejected")
Modifiers.BeginRun("Solo", player)
Modifiers.SetupRunPlayer(rp)
assert(Modifiers.DifficultyId() == "Standard", "locked requested tier must fall back")
Modifiers.CompleteDifficulty(player, 4, true)
assert(not profile.DifficultyClears.Standard, "four stages cannot unlock next tier")
rp.DevTainted = true
Modifiers.CompleteDifficulty(player, 5, true)
assert(not profile.DifficultyClears.Standard, "DEV runs cannot unlock difficulty")
rp.DevTainted = false
Modifiers.CompleteDifficulty(player, 5, true)
assert(profile.DifficultyClears.Standard, "five normal stages unlock Veteran")
select("Veteran")
assert(profile.Difficulty == "Veteran", "unlocked tier must be selectable")
participating = true
select("Standard")
assert(profile.Difficulty == "Veteran", "tier cannot change during a run")
participating = false
Modifiers.BeginRun("Solo", player)
Modifiers.SetupRunPlayer(rp)
assert(Modifiers.DifficultyMultiplier("HP") == 1.35)
assert(Modifiers.GoldMult() == 1.35, "tier reward should apply once")
Modifiers.CompleteDifficulty(player, 5, true)
assert(profile.DifficultyClears.Veteran and profile.OwnedCharacters.Engineer, "Veteran grants alternate hero path")
Modifiers.BeginRun("Daily", player)
assert(Modifiers.DifficultyId() == "Standard", "daily challenge keeps a shared difficulty")
preview.log("PASS difficulty selection, clear boundaries, DEV rejection, tier rewards and daily isolation")
