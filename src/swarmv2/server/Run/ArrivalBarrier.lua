--!strict
--[[
	SwarmV2/Run/ArrivalBarrier.lua  (ServerScriptService.SwarmV2.Run.ArrivalBarrier)
	Pure logic for the match server's arrival barrier (no Roblox services, so Lune tests can
	drive it with a fake clock). Contract: docs/redesign/OWNERSHIP.md, DESIGN.md section 7.

	- The first admitted arrival opens the barrier and fixes the match id and roster.
	- The run starts once every expected player is admitted, or GroupWait seconds after the
	  first arrival, whichever comes first (exactly once).
	- After the start, a missing expected player may still arrive for LateGrace seconds and
	  joins once; after that, or for anyone not on the roster / of another match, "reject".
]]

local ArrivalBarrier = {}
ArrivalBarrier.__index = ArrivalBarrier

export type Decision = "wait" | "start" | "late" | "reject" | "duplicate"

export type Barrier = typeof(setmetatable(
	{} :: {
		MatchId: string?,
		Expected: { [number]: boolean },
		ExpectedCount: number,
		Admitted: { [number]: boolean },
		AdmittedCount: number,
		FirstAt: number?,
		StartedAt: number?,
		GroupWait: number,
		LateGrace: number,
	},
	ArrivalBarrier
))

function ArrivalBarrier.new(groupWait: number, lateGrace: number): Barrier
	return setmetatable({
		MatchId = nil,
		Expected = {},
		ExpectedCount = 0,
		Admitted = {},
		AdmittedCount = 0,
		FirstAt = nil,
		StartedAt = nil,
		GroupWait = groupWait,
		LateGrace = lateGrace,
	}, ArrivalBarrier)
end

-- An admitted context arrived at time `now`. Returns what to do with this player.
function ArrivalBarrier.Arrive(self: Barrier, matchId: string, userId: number, expected: { number }, now: number): Decision
	if self.MatchId == nil then
		self.MatchId = matchId
		for _, id in ipairs(expected) do
			if not self.Expected[id] then
				self.Expected[id] = true
				self.ExpectedCount += 1
			end
		end
		self.FirstAt = now
	end
	if matchId ~= self.MatchId or not self.Expected[userId] then
		return "reject"
	end
	if self.Admitted[userId] then
		return "duplicate"
	end
	if self.StartedAt then
		if now - self.StartedAt > self.LateGrace then
			return "reject"
		end
		self.Admitted[userId] = true
		self.AdmittedCount += 1
		return "late"
	end
	self.Admitted[userId] = true
	self.AdmittedCount += 1
	return "wait"
end

-- Polled every frame or so: true exactly once, when the run should start.
function ArrivalBarrier.ShouldStart(self: Barrier, now: number): boolean
	if self.StartedAt or not self.FirstAt or self.AdmittedCount == 0 then
		return false
	end
	if self.AdmittedCount >= self.ExpectedCount or now - self.FirstAt >= self.GroupWait then
		self.StartedAt = now
		return true
	end
	return false
end

-- Seconds left before the group wait ends (for the loading overlay), or 0.
function ArrivalBarrier.WaitLeft(self: Barrier, now: number): number
	if not self.FirstAt or self.StartedAt then
		return 0
	end
	return math.max(0, self.GroupWait - (now - self.FirstAt))
end

-- The late window is over: the run no longer waits for anyone.
function ArrivalBarrier.GraceOver(self: Barrier, now: number): boolean
	return self.StartedAt ~= nil and now - self.StartedAt > self.LateGrace
end

-- A player left before the start: their slot stays expected (they may come back).
function ArrivalBarrier.Missing(self: Barrier): { number }
	local out = {}
	for id in pairs(self.Expected) do
		if not self.Admitted[id] then
			table.insert(out, id)
		end
	end
	table.sort(out)
	return out
end

return ArrivalBarrier
