-- Real run-end callers must settle once and preserve unrelated savings.
preview.startServer()
preview.advance(1)
local player = game:GetService("Players").LocalPlayer
local RM = preview.server("RunManager")
local Gold = preview.server("GoldSystem")
local Data = preview.server("DataService")
local Stage = preview.server("StageManager")
local Config = preview.shared("Config")
local data = assert(Data.GetData(player))
data.Gold = 1000
local function start()
	assert(RM.StartTeamRun({ player }, "Solo", "Forest", player))
	preview.advance(2)
	local rp = assert(RM.GetRunPlayer(player))
	rp.InvulnUntil = math.huge
	Gold.AddRunGold(rp, 200)
	return rp
end
local first = start()
RM.AbandonRun(first)
assert(data.Gold == 1070 and data.RunEscrow == nil, "abandon must retain only 35% of current unspent gold")
RM.AbandonRun(first)
assert(data.Gold == 1070, "repeat abandon must not settle twice")
preview.advance(1)
local extracted = start()
local originalCleared = Stage.StagesCleared
Stage.StagesCleared = function() return 5 end
RM.ReturnThroughPortal(extracted)
Stage.StagesCleared = originalCleared
local expected = 1070 + 200 + Config.Gold.WinBonus + Config.Gold.StageClearBonus * 5
assert(extracted.GoldSettlement.Retained == expected - 1070 and data.Gold >= expected and data.RunEscrow == nil,
	"extraction must retain current gold and portal bonus once")
expected = data.Gold -- achievement rewards may pay separate persistent coins on the first win
assert(data.DifficultyClears.Standard and data.Stats.Wins == 1, "five-stage Standard extraction must unlock Veteran")
RM.ReturnThroughPortal(extracted)
assert(data.Gold == expected and data.Stats.Wins == 1, "repeat portal callback must not duplicate reward or win")
preview.advance(1)
local disconnected = start()
RM.OnPlayerRemoving(player)
assert(data.Gold == expected + 70 and data.RunEscrow == nil, "disconnect must settle current ledger as a failure")
RM.OnPlayerRemoving(player)
assert(data.Gold == expected + 70, "repeat disconnect must not settle twice")
assert(disconnected.GoldSettlement.Retained == 70, "disconnect must use the same settlement record")
preview.log("PASS abandon, safe extraction, tier clear, disconnect and duplicate end callbacks")
