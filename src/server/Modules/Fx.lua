--[[
	Fx.lua
	Collects every visual/audio effect produced during a frame and sends them to all
	clients as ONE RemoteEvent call per flush tick (Config.Net.FxFlushHz).
	Nothing here affects gameplay; the client may drop or simplify effects freely.

	Batch shape (keys omitted when empty):
	  h = { enemyId, ... }                         hit flashes
	  d = { {x, z, Color3, size}, ... }            enemy death poofs
	  s = { {x, z, yaw, reach, sweep, tier, userId} } sword swings (x, z = player; sweep +1/-1)
	  b = { {x, z, radius, tier} }                 lightning strikes
	  c = { {x1, z1, x2, z2} }                     chain lightning arcs
	  p = { {x, z, radius, seconds, evo} }         holy water pools
	  e = { {x, z, radius} }                       explosions
	  r = { {x, z, radius, Color3} }               shockwave rings (bomb, revive, boss)
	  w = { {id, kind, ...} }                      warnings / telegraphs / hazard visuals,
	                                               drawn by src/client/Telegraphs.lua (Fx.Warn)
	  x = { id, ... }                              cancel warnings by id (0 = all of them)
	  u = { {userId, kind} }                       player events: "hurt" | "heal" | "levelup" | "die" | "revive"
	  n = { soundName, ... }                       global one-shot sounds
	  g = { {x, z, amount, userId} }               gold coins burst from a kill that paid gold
	                                               (visual only; the gold is already paid)
]]

local Config = require(game:GetService("ReplicatedStorage").Shared.Config)
local Remotes = require(game:GetService("ReplicatedStorage").Shared.Remotes)

local Fx = {}

local batch: { [string]: { any } } = {}
local hasData = false
local accumulator = 0

local function push(key: string, value: any)
	local list = batch[key]
	if not list then
		list = {}
		batch[key] = list
	end
	list[#list + 1] = value
	hasData = true
end

-- Caps per flush keep a single packet small even in huge fights.
-- Warnings (w / x) are gameplay-critical: their caps are far above what a fight produces.
local CAPS = { g = 24, h = 120, d = 60, s = 16, b = 24, c = 40, p = 16, e = 16, r = 8, u = 24, n = 16, w = 64, x = 64 }
local warnId = 0

local function pushCapped(key: string, value: any)
	local list = batch[key]
	if list and #list >= CAPS[key] then
		return
	end
	push(key, value)
end

local function r1(n: number): number
	return math.floor(n * 10 + 0.5) / 10
end

function Fx.Hit(enemyId: number)
	pushCapped("h", enemyId)
end

function Fx.Death(pos: Vector3, color: Color3, size: number)
	pushCapped("d", { r1(pos.X), r1(pos.Z), color, r1(size) })
end

-- tier = visual strength 0-3 (3 = evolved); the client draws the swing on that player.
function Fx.Slash(pos: Vector3, yaw: number, reach: number, sweep: number, tier: number, userId: number)
	pushCapped("s", { r1(pos.X), r1(pos.Z), math.floor(yaw * 100 + 0.5) / 100, r1(reach), sweep, tier, userId })
end

-- A kill paid `amount` gold to `userId`: coins pop out at pos and fly to that player.
function Fx.Gold(pos: Vector3, amount: number, userId: number)
	pushCapped("g", { r1(pos.X), r1(pos.Z), math.floor(amount + 0.5), userId })
end

function Fx.Bolt(pos: Vector3, radius: number, tier: number?)
	pushCapped("b", { r1(pos.X), r1(pos.Z), r1(radius), tier or 0 })
end

function Fx.Chain(a: Vector3, b: Vector3)
	pushCapped("c", { r1(a.X), r1(a.Z), r1(b.X), r1(b.Z) })
end

function Fx.Pool(pos: Vector3, radius: number, seconds: number, evo: boolean)
	pushCapped("p", { r1(pos.X), r1(pos.Z), r1(radius), r1(seconds), evo })
end

function Fx.Explosion(pos: Vector3, radius: number)
	pushCapped("e", { r1(pos.X), r1(pos.Z), r1(radius) })
end

function Fx.Ring(pos: Vector3, radius: number, color: Color3)
	pushCapped("r", { r1(pos.X), r1(pos.Z), r1(radius), color })
end

--[[
	Warnings: every telegraph / hazard visual is ONE entry sent once (the client animates
	it from its start time); the id lets the server cancel it early (Fx.ClearWarn).
	kind and its fields (all positions are floor x, z; seconds = how long it shows):
	  "circle"  x, z, radius, seconds, style ("venom" | "acid" | "blast" | "burrow" | "pulse"
	            | "hatch" (a Brood Egg's timer, no damage) | "nest" (mites about to climb out))
	  "lane"    x, z (lane centre), yaw, length, width, seconds
	  "spokes"  x, z, innerRadius, length, seconds, { angle, ... } (stinger lanes; gaps = safe)
	  "glob"    x1, z1, x2, z2, seconds (flight), arc height, style (nil = acid | "egg")
	  "egg"     x, z, seconds (a summon egg that cracks at the end)
	  "emerge"  x, z, seconds (soil cracks open: a summon climbs out at the end)
	  "patch"   x, z, radius, arm, life, style ("fire" | "acid")
	  "band"    x, z, inner, outer, seconds (a ground-pound ring band that fills outward)
	  "wave"    x, z, startRadius, delay, speed, maxRadius, width, gapAngle, gapHalf (a ring
	            rolling outward after delay with one safe gap; the gap lane shows meanwhile)
	  "mine"    x, z, radius, seconds, fromX, fromZ (a glimmer mote drifting down, blinking)
	  "gust"    x, z, yaw, length, halfAngle, seconds, blow (a wind cone; pushes, no damage)
	  "aura"    x, z, radius, seconds (the War Banner's rally zone while it stands)
	  "pop"     x, z, radius, style (impact burst: "acid" | "venom" | "burrow" | "dust" |
	            "shield" | "pound" | "glimmer" | "gust" | "heal" | "slam" | "hatch"), inner
	Returns the id.
]]
function Fx.Warn(kind: string, ...: any): number
	warnId = warnId % 60000 + 1
	local entry = { warnId, kind }
	for i = 1, select("#", ...) do
		entry[i + 2] = (select(i, ...))
	end
	pushCapped("w", entry)
	return warnId
end

-- Cancels a warning on every client (0 = every warning; travel / run end).
-- Clients apply a batch's cancels (x) before its new warnings (w), so a warning created
-- and cancelled within one flush is stripped from w here instead of being cancelled.
function Fx.ClearWarn(id: number)
	if id == 0 then
		-- wipes everything sent so far: pending warnings are dropped and the 0 always
		-- goes out (never lost to the cap behind per-enemy cancels)
		(batch :: any).w = nil
		batch.x = { 0 }
		hasData = true
		return
	end
	local pending = batch.w
	if pending then
		for i, entry in ipairs(pending) do
			if entry[1] == id then
				table.remove(pending, i)
				return
			end
		end
	end
	local cancels = batch.x
	if cancels and cancels[1] == 0 then
		return -- already cleared by a 0 in this flush
	end
	pushCapped("x", id)
end

-- Old boss lane telegraph entry point, now drawn by Telegraphs ("lane").
function Fx.Telegraph(pos: Vector3, yaw: number, length: number, width: number, seconds: number): number
	return Fx.Warn("lane", pos.X, pos.Z, math.floor(yaw * 100 + 0.5) / 100, length, width, seconds)
end

function Fx.PlayerEvent(player: Player, kind: string)
	pushCapped("u", { player.UserId, kind })
end

function Fx.Sound(name: string)
	pushCapped("n", name)
end

-- Called every Heartbeat by GameServer; sends at most FxFlushHz times per second.
function Fx.Step(dt: number)
	accumulator += dt
	if accumulator < 1 / Config.Net.FxFlushHz then
		return
	end
	accumulator = 0
	if not hasData then
		return
	end
	Remotes.FireAllClients("FxBatch", batch)
	batch = {}
	hasData = false
end

return Fx
