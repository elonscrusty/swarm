--[[
	DamageNumbers.lua
	Optional floating damage numbers (Settings > Damage numbers, off by default).

	EnemySpawner.Damage reports every player hit here. Hits are summed per player per
	enemy and sent FlushHz times a second (Config.DamageNumbers), only to players whose
	setting is on (player attribute "DamageNumbers", set by GoldSystem from the save). At
	most MaxPerFlush enemies per message, the biggest totals first, so a swarm never sends
	a flood. Payload: a flat array { enemyId, amount, crit (0 / 1), enemyId, ... }.
	Purely visual: nothing here changes damage.
]]

local Players = game:GetService("Players")

local Config = require(game:GetService("ReplicatedStorage").Shared.Config)
local Remotes = require(game:GetService("ReplicatedStorage").Shared.Remotes)

local DamageNumbers = {}

type Pending = { [number]: { Amount: number, Crit: boolean } }

local pending: { [Player]: Pending } = {}
local accumulator = 0

-- A player's hit on enemy `enemyId` (after crits, after shields).
function DamageNumbers.Add(player: Player, enemyId: number, amount: number, crit: boolean?)
	if amount <= 0 or player:GetAttribute("DamageNumbers") ~= true then
		return
	end
	local list = pending[player]
	if not list then
		list = {}
		pending[player] = list
	end
	local entry = list[enemyId]
	if entry then
		entry.Amount += amount
		entry.Crit = entry.Crit or crit == true
	else
		list[enemyId] = { Amount = amount, Crit = crit == true }
	end
end

local function flush()
	local D = Config.DamageNumbers
	for player, list in pairs(pending) do
		if player.Parent then
			local entries = {}
			for id, e in pairs(list) do
				table.insert(entries, { id, e.Amount, e.Crit })
			end
			table.sort(entries, function(a, b)
				return a[2] > b[2]
			end)
			local out = {}
			for i = 1, math.min(#entries, D.MaxPerFlush) do
				local e = entries[i]
				table.insert(out, e[1])
				table.insert(out, math.max(1, math.floor(e[2] + 0.5)))
				table.insert(out, e[3] and 1 or 0)
			end
			if #out > 0 then
				Remotes.FireClient("DamageNumbers", player, out)
			end
		end
	end
	table.clear(pending)
end

function DamageNumbers.Step(dt: number)
	accumulator += dt
	if accumulator < 1 / Config.DamageNumbers.FlushHz then
		return
	end
	accumulator = 0
	if next(pending) then
		flush()
	end
end

function DamageNumbers.Init(_ctx)
	Players.PlayerRemoving:Connect(function(player)
		pending[player] = nil
	end)
end

return DamageNumbers
