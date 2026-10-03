-- Trusted pings, discoveries, damage history and reserved-run reconnects.
local Players = game:GetService("Players")
local me = Players.LocalPlayer
local friend = preview.addPlayer("Partner", 2)
local outsider = preview.addPlayer("Spectator", 3)
local T = preview.teleport()
T.placeId, T.privateServerId, T.privateServerOwnerId = 4242, "ps-coop", 0
local ticket = { SwarmRun = { V = 1, Mode = "Duo", Members = { 1, 2 }, Starter = 1, Arena = "Forest" } }
T.joinData[1], T.joinData[2] = ticket, ticket
local Data = preview.server("DataService")
local Config = preview.shared("Config")
local store = game:GetService("DataStoreService"):GetDataStore(Config.Data.StoreName)
for _, p in ipairs({ me, friend }) do
	local data = Data.DefaultData()
	data.Gold = 500
	data.RunReconnect = { AccessCode = "secret-code", PrivateId = "ps-coop", Id = "", Expires = 0 }
	store:SetAsync(Config.Data.KeyPrefix .. p.UserId, { Data = data })
end
preview.startServer()
preview.advance(2)
local RM, RS = preview.server("RunManager"), preview.server("RunServers")
local Gold, Ping = preview.server("GoldSystem"), preview.server("TeamPingService")
local Journal, Enemies = preview.server("JournalService"), preview.server("EnemySpawner")
local Remotes = preview.shared("Remotes")
local rp = assert(RM.GetRunPlayer(me), "ticket must start co-op run")
local teammate = assert(RM.GetRunPlayer(friend))
rp.InvulnUntil, teammate.InvulnUntil = math.huge, math.huge
local shown, results, profiles = {}, {}, {}
local fire = Remotes.FireClient
Remotes.FireClient = function(name, player, payload)
	if name == "TeamPingShown" then table.insert(shown, { Player = player, Data = payload }) end
	if name == "RunResult" then results[player] = payload end
	if name == "ProfileSync" then profiles[player] = payload end
	return fire(name, player, payload)
end
assert(not Ping.Send(outsider, "Help"), "nonparticipants cannot ping")
assert(not Ping.Send(me, "arbitrary chat"), "only presets allowed")
assert(not Ping.Send(me, "Location", Vector3.new(0/0, 0, 0)), "NaN rejected")
assert(not Ping.Send(me, "Location", rp.Root.Position + Vector3.new(10000, 0, 0)), "distant position rejected")
assert(not Ping.Send(me, "Enemy", 999999), "unknown target rejected")
assert(Ping.Send(me, "Help"), "preset accepted")
assert(#shown == 2 and shown[1].Player ~= outsider and shown[2].Player ~= outsider, "only teammates receive ping")
assert(not Ping.Send(me, "Help"), "cooldown rejects spam")
assert(shown[1].Data.Kind == "Help" and shown[1].Data.Duration == 6 and shown[1].Data.UserId == me.UserId)
assert(me:GetAttribute("TeamPingColor") ~= friend:GetAttribute("TeamPingColor"), "teammates have distinct persistent colors")
preview.advance(2.1)
local enemy = Enemies.Spawn("Slime", rp.Root.Position + Vector3.new(30, 0, 0), {})
assert(enemy and Data.GetData(me).Journal.Enemies.Slime, "nearby server spawn discovers enemy")
assert(Ping.Send(me, "Enemy", enemy.Id), "server resolves enemy target")
Config.Drops.FloorPickupChance, Config.Drops.Weights, Config.Gold.KillGoldChance = 1, { Chicken = 1 }, 1
Enemies.Kill(enemy, rp)
assert(Data.GetData(me).Journal.Drops.Slime.XP and Data.GetData(me).Journal.Drops.Slime.Gold
	and Data.GetData(me).Journal.Drops.Slime.Chicken, "actual kill records emitted drops")
Journal.Record(me, "Slime", { "XP", "forged drop", "Chest" })
Journal.Record(me, "forged enemy", { "Gold" })
local journal = Data.GetData(me).Journal
assert(journal.Drops.Slime.XP and journal.Drops.Slime.Chest and not journal.Drops.Slime["forged drop"] and not journal.Enemies["forged enemy"])
local migrated = Data.Migrate({ Journal = { Enemies = { Slime = true, fake = true }, Drops = { Bat = { Bomb = true, fake = true } } } })
assert(migrated.Journal.Enemies.Slime and migrated.Journal.Enemies.Bat and migrated.Journal.Drops.Bat.Bomb and not migrated.Journal.Enemies.fake and not migrated.Journal.Drops.Bat.fake)
rp.InvulnUntil = 0
for i = 1, 9 do RM.DamagePlayer(rp, 1, "Hit " .. i) end
assert(#rp.DamageHistory == 6 and rp.DamageHistory[1].Cause == "Hit 4", "history bounded to six recent hits")
local hp = rp.HP
RM.DamagePlayer(rp, math.huge, "bad")
assert(rp.HP == hp, "nonfinite damage rejected")
rp.InvulnUntil = math.huge
Gold.AddRunGold(rp, 100)
rp.PendingLevels = 3
local oldLevel, oldGold, oldId = rp.Level, rp.Gold, rp.RunId
local oldKills = rp.Kills
assert(RS.CanReconnect(rp))
preview.removePlayer(me)
preview.advance(0.1)
local saved = store:GetAsync(Config.Data.KeyPrefix .. me.UserId).Data
assert(saved.Gold == 500 and saved.RunEscrow.Gold == oldGold and RS.HasPendingReconnect(saved), "disconnect preserves escrow and bank")
assert(saved.Stats.TotalKills == oldKills, "disconnect checkpoints lifetime kills without completing the run")
local variant = preview.args.rejoin or "success"
if variant == "expired" then
	saved.RunReconnect.Expires = os.time() - 1
	store:SetAsync(Config.Data.KeyPrefix .. me.UserId, { Data = saved })
elseif variant == "ended" then
	RM.AbandonRun(teammate)
end
T.joinData[1] = { SwarmRejoin = { Id = variant == "forged" and "fake-run" or oldId } }
local returned = preview.addPlayer("Returned", 1)
preview.playerJoined(returned)
preview.advance(1)
if variant ~= "success" then
	assert(not RM.GetRunPlayer(returned), "expired, ended and forged reconnects must not restore a run")
	local data = Data.GetData(returned)
	assert(data.Gold == 500 + math.floor(oldGold * Config.Gold.FailureRetainBase), "failed reconnect settles retained escrow once")
	assert(not data.RunReconnect and not data.RunEscrow, "stale reconnect route cleared")
	assert(T.calls[#T.calls].Data.SwarmReturn, "failed resume returns to public lobby")
	Gold.RecoverEscrow(data)
	assert(data.Gold == 500 + math.floor(oldGold * Config.Gold.FailureRetainBase), "fallback settlement cannot replay")
	preview.log("PASS " .. variant .. " reconnect fallback and one-time settlement")
	return
end
local resumed = assert(RM.GetRunPlayer(returned), "authorized member must resume same live run")
assert(resumed.RunId == oldId and resumed.Level == oldLevel and resumed.Gold == oldGold, "build and escrow restored")
assert(resumed.PendingLevels == 3 and resumed.HP <= hp and not resumed.Committed, "pending XP preserved without healing or settlement")
assert(not RM.TryReconnect(returned, oldId), "snapshot cannot be consumed twice")
assert(Data.GetData(returned).Gold == 500 and Data.GetData(returned).Stats.Runs == 1, "no duplicate run start or currency grant")
resumed.Kills += 5
Gold.SyncProfile(returned)
assert(profiles[returned].Journal and not profiles[returned].RunReconnect, "journal replicates but access code stays secret")
RM.AbandonRun(resumed)
local bank = Data.GetData(returned).Gold
assert(bank == 500 + math.floor(oldGold * Config.Gold.FailureRetainBase), "one failure settlement")
assert(Data.GetData(returned).Stats.TotalKills == oldKills + 5, "checkpointed kills are not counted twice")
assert(not Data.GetData(returned).RunReconnect and not Data.GetData(returned).RunEscrow)
RM.AbandonRun(resumed)
assert(Data.GetData(returned).Gold == bank and results[returned].DamageHistory, "repeat end cannot duplicate coins")
assert(Data.GetData(returned).LastRun.Mode == "Duo", "bounded last run saved")
preview.log("PASS trusted pings, journal migration, bounded damage history, reconnect restore and single settlement")
