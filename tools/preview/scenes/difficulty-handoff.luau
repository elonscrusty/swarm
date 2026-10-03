-- Missing host: retain the ticket's tier only when the replacement host owns access.
local C = lib("common")
local T = preview.teleport()
T.placeId, T.privateServerId, T.privateServerOwnerId = 4242, "tier-test", 0
local s = C.bootServer()
local player = game:GetService("Players").LocalPlayer
local unlocked = preview.args.unlocked ~= "off"
local data = { Difficulty = "Standard", DifficultyClears = { Standard = unlocked }, Stats = { BestStage = 0 }, Curses = {} }
local RS = C.server("RunServers")
local startedTier
RS.Init({
 DataService = { GetData = function() return data end, OnProfileLoaded = function() end },
 RunModifiers = { Today = function() return 20000 end },
 RunManager = {
  IsParticipant = function() return false end,
  StartTeamRun = function(_, _, _, starter) assert(starter == player) startedTier = data.Difficulty return true end,
 },
})
data.Difficulty = "Veteran"
local built = RS.BuildTicket({ player }, "Solo", player, "Forest")
assert(built.Difficulty == (unlocked and "Veteran" or "Standard"), "lobby must validate requested tier")
data.Difficulty = "Standard"
local ticket = RS.SanitizeTicket({ V = 1, Mode = "Duo", Members = { 1, 2 }, Starter = 2, Difficulty = "Veteran" })
assert(ticket and ticket.Difficulty == "Veteran")
assert(RS.SanitizeTicket({ V = 1, Mode = "Solo", Members = { 1 }, Difficulty = {} }).Difficulty == "Standard")
T.joinData[1] = { SwarmRun = ticket }
s.Config.RunServers.WaitForTeamSeconds = 0.25
RS.Start()
preview.advance(1)
assert(startedTier == (unlocked and "Veteran" or "Standard"), "missing-host fallback must preserve unlocked ticket tier and reject locked tier")
preview.log("PASS sanitized difficulty handoff and missing-host eligibility", startedTier)
