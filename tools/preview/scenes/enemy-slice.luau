-- enemy-slice: the combat readability slice (docs/overhaul/ENEMY_ART.md) at the normal run
-- camera: the Knight in a dense mite crowd with wasps and beetles, a Swift and a Burning
-- elite (fire patches behind it), the stage boss closing in over its telegraph, a Healer's
-- green pulse, the hero's Healing Totem and Vine Snare, and a hit-flash moment on the
-- boss, an elite and several mites (the real EnemyRenderer.Flash, as VFX calls it).
--   --set arena=Forest|Snow   (Forest shows the Scorpion Queen, Snow the Moth Matriarch;
--                              --set boss=Boss|MothBoss overrides)
--   --set flash=off            no hit flashes (the calm look)
--   --set t=<s>                capture this long after the flashes (default 0.03)
local A = lib("arena")
local C = lib("common")
local E = lib("encounter")
local arenaName = preview.args.arena or "Forest"
local s = A.build({ swarm = false, inventory = "new" })
local c = s.centre
local function at(dx, dz)
	return Vector3.new(c.X + dx, c.Y, c.Z + dz)
end
local hero = at(0, 0)
local rng = Random.new(preview.seed * 7 + 11)
-- dense mite crowd (the pale mass from the review), a few wasps / beetles
local ids = {}
for i = 1, 46 do
	local a = rng:NextNumber(0, math.pi * 2)
	local r = rng:NextNumber(6, 26)
	local typeId = (i % 9 == 0 and "Bat") or (i % 7 == 0 and "Skeleton") or "Slime"
	local b = E.enemy(s, typeId, at(math.cos(a) * r, math.sin(a) * r), hero)
	if b then
		table.insert(ids, b)
	end
end
-- elites: Swift wasp and Burning beetle (fire patches trail behind it)
local swift = E.enemy(s, "Bat", at(-11, -7), hero, { Elite = true, Affix = "Swift" })
local burnAt = at(12, -9)
local burning = E.enemy(s, "Skeleton", burnAt, hero, { Elite = true, Affix = "Burning" })
E.enemy(s, "Slime", at(-15, 6), hero, { Elite = true, Affix = "Shielded" })
-- a Healer channelling (hostile heal)
local healer = at(17, 9)
E.enemy(s, "Healer", healer, hero, { Act = "Channel" })
-- the boss, coming in from the west
local bossType = preview.args.boss or (arenaName == "Snow" and "MothBoss" or "Boss")
local bossAt = at(-24, 3)
local boss = E.enemy(s, bossType, bossAt, hero, { Act = bossType == "Boss" and "Windup" or nil })
C.setState({ BossMaxHP = 2700, BossHP = 2000, BossName = bossType == "Boss" and "Scorpion Queen" or "Moth Matriarch", BossId = bossType == "Boss" and "ScorpionQueen" or "MothMatriarch", BossIntro = 0.05, BossPhaseAt = 0.5, BossPhase = 1, StagePhase = "Boss" })
preview.advance(0.6) -- models built, emerge done

-- the hero's weapons: the Healing Totem beside the hero, a Vine Snare on the crowd
local WeaponData = C.shared("WeaponData")
local items = {
	{ WeaponData.VisualByte(27, 2), c.X + 5, c.Y, c.Z + 4, 0 },
	{ WeaponData.VisualByte(51, 2), c.X - 7, c.Y + 0.2, c.Z + 7, 0 },
}
local b = buffer.create(2 + #items * 11)
buffer.writeu16(b, 0, #items)
local o = 2
for i, it in ipairs(items) do
	buffer.writeu16(b, o, 600 + i)
	buffer.writeu8(b, o + 2, it[1])
	buffer.writeu8(b, o + 3, 1)
	buffer.writei16(b, o + 4, math.floor(it[2] * 10 + 0.5))
	buffer.writei16(b, o + 6, math.floor(it[3] * 10 + 0.5))
	buffer.writei16(b, o + 8, math.floor(it[4] * 10 + 0.5))
	buffer.writeu8(b, o + 10, 0)
	o += 11
end
C.fire("ProjectileBatch", b)

local dir = (hero - bossAt).Unit
E.warn({
	{ "lane", bossAt.X + dir.X * 11, bossAt.Z + dir.Z * 11, math.atan2(-dir.X, -dir.Z), 22, 7, 0.9 },
	{ "patch", burnAt.X + 1, burnAt.Z - 4.5, 3.4, 0.5, 3.2 },
	{ "patch", burnAt.X + 2, burnAt.Z - 9, 3.4, 0, 3.2 },
	{ "pop", healer.X, healer.Z, 14, "heal" },
})
preview.advance(0.3, 20)

-- the hit-flash moment: the boss, the Burning elite and every third mite
if preview.args.flash ~= "off" then
	local ER = preview.client("EnemyRenderer")
	local function idOf(body)
		local m = body and body.Parent
		local n = m and tonumber(string.match(m.Name, "(%d+)$"))
		return n
	end
	local flashed = 0
	local list = { boss, burning, swift }
	for i, bb in ipairs(ids) do
		if i % 3 == 0 then
			table.insert(list, bb)
		end
	end
	for _, bb in ipairs(list) do
		local id = bb and idOf(bb)
		if ER and id and ER.Flash(id) then
			flashed += 1
		end
	end
	print("enemy-slice: flashed " .. flashed .. " / " .. #list)
end
preview.advance(tonumber(preview.args.t) or 0.03, 30)
