-- Server-observed enemy and drop discoveries. The journal is opened manually.
local EnemyData = require(game:GetService("ReplicatedStorage").Shared.EnemyData)
local JournalService = {}
local ctx
local pending = {}
local DROPS = { XP = true, Gold = true, Chest = true, Chicken = true, Magnet = true, Bomb = true }

function JournalService.Record(player: Player, enemy: string, drops: { string }?)
	if not EnemyData.Enemies[enemy] then return end
	local data = ctx.DataService.GetData(player)
	if not data then return end
	local journal = data.Journal
	local changed = journal.Enemies[enemy] ~= true
	journal.Enemies[enemy] = true
	for _, id in ipairs(drops or {}) do
		if DROPS[id] then
			journal.Drops[enemy] = journal.Drops[enemy] or {}
			changed = changed or journal.Drops[enemy][id] ~= true
			journal.Drops[enemy][id] = true
		end
	end
	if changed and not pending[player] then
		pending[player] = true
		task.delay(1, function()
			pending[player] = nil
			if player.Parent then ctx.GoldSystem.SyncProfile(player) end
		end)
	end
end

function JournalService.Observe(enemy: string, position: Vector3, drops: { string }?)
	for _, rp in ipairs(ctx.RunManager.GetRunPlayers()) do
		if not rp.Returned and rp.Root and (rp.Root.Position - position).Magnitude <= 120 then
			JournalService.Record(rp.Player, enemy, drops)
		end
	end
end

function JournalService.Init(c) ctx = c end
return JournalService
