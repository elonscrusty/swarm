-- A returning member is routed only with the server-owned saved access code.
local player = game:GetService("Players").LocalPlayer
local T = preview.teleport()
T.placeId = 4242
local Data = preview.server("DataService")
local Config = preview.shared("Config")
local store = game:GetService("DataStoreService"):GetDataStore(Config.Data.StoreName)
local data = Data.DefaultData()
data.Gold = 600
data.RunEscrow = { Id = "existing-run", Gold = 120, Stages = 1 }
data.RunReconnect = { AccessCode = "secret-reserved-code", PrivateId = "ps-existing", Id = "existing-run", Expires = os.time() + 110 }
if preview.args.fail == "expired" then data.RunReconnect.Expires = os.time() - 1 end
store:SetAsync(Config.Data.KeyPrefix .. player.UserId, { Data = data })
if preview.args.fail == "teleport" then T.teleportFails = 2 end
preview.startServer()
preview.advance(3)
local loaded = assert(Data.GetData(player))
if preview.args.fail then
	assert(not Data.IsReleased(player) and not loaded.RunReconnect and not loaded.RunEscrow)
	assert(loaded.Gold == 648, "failed or expired reconnect recovers stage-scaled retained coins")
	assert(player:GetAttribute("Travel") ~= "ToRun", "failed route returns lobby controls")
else
	assert(#T.calls == 1 and T.reserved == 0, "reconnect must not reserve a new server")
	local call = T.calls[1]
	assert(call.Code == "secret-reserved-code" and call.Data.SwarmRejoin.Id == "existing-run")
	assert(not call.Data.SwarmRun and not call.Data.AccessCode, "no run restart ticket or secret in teleport data")
	assert(Data.IsReleased(player) and loaded.Gold == 600 and loaded.RunEscrow.Gold == 120, "release leaves escrow unspent")
end
preview.log("PASS lobby reconnect " .. (preview.args.fail or "routing and durable release"))
