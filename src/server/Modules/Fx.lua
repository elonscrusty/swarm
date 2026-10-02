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
	  t = { {x, z, yaw, length, width, seconds} }  boss charge telegraph
	  u = { {userId, kind} }                       player events: "hurt" | "heal" | "levelup" | "die" | "revive"
	  n = { soundName, ... }                       global one-shot sounds
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
local CAPS = { h = 120, d = 60, s = 16, b = 24, c = 40, p = 16, e = 16, r = 8, t = 4, u = 24, n = 16 }

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

function Fx.Telegraph(pos: Vector3, yaw: number, length: number, width: number, seconds: number)
	-- yaw to 0.01 rad (as Slash): 0.1 rad put the far end of a long charge lane ~2 studs off
	pushCapped("t", { r1(pos.X), r1(pos.Z), math.floor(yaw * 100 + 0.5) / 100, r1(length), r1(width), seconds })
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
