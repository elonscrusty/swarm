-- enemy-telegraphs: the arena around the hero with every enemy warning at once, ~0.45 s
-- into it: a Spitter swelling over its acid landing marker (dashed ring + crosshair), a
-- second Spitter's glob in flight, a Bomb Tick swelling and blinking inside its blast
-- ring, a Rhino Beetle rearing up over its lunge lane, and the three elite affixes
-- (Burning with a fire patch behind it, Shielded, Swift) with their tags. The "New:
-- Spitter" callout toast is on the HUD. --set t=<seconds> changes the moment.
local A = lib("arena")
local C = lib("common")
local E = lib("encounter")
local s = A.build({ swarm = false })
local c = s.centre
local function at(dx, dz)
	return Vector3.new(c.X + dx, c.Y, c.Z + dz)
end
local hero = at(0, 0)
-- a few grunts for context
for i, off in ipairs({ { -30, 6 }, { 28, 10 }, { -18, 20 }, { 33, -12 }, { -36, -14 } }) do
	E.enemy(s, i % 2 == 0 and "Slime" or "Bat", at(off[1], off[2]), hero)
end
-- Spitter #1 winding up; its acid circle sits where the hero stands (offset a little)
local spit = at(-24, -12)
E.enemy(s, "Spitter", spit, hero, { Act = "Windup" })
-- Spitter #2 already threw: glob in flight toward a spot right of the hero
local spit2 = at(25, -16)
E.enemy(s, "Spitter", spit2, hero)
-- Bomb Tick fusing next to the hero
local tick = at(6, 4)
E.enemy(s, "Bomber", tick, hero, { Act = "Fuse" })
-- Rhino Beetle rearing up, lunge lane toward the hero
local rhino = at(-14, 13)
E.enemy(s, "Brute", rhino, hero, { Act = "Windup" })
-- elites with affixes
local burn = at(16, 16)
E.enemy(s, "Skeleton", burn, hero, { Elite = true, Affix = "Burning" })
E.enemy(s, "Slime", at(-30, -2), hero, { Elite = true, Affix = "Shielded" })
E.enemy(s, "Bat", at(30, 2), hero, { Elite = true, Affix = "Swift" })
preview.advance(0.6) -- models built, emerge done
local dir = (hero - rhino).Unit
E.warn({
	{ "circle", hero.X - 1, hero.Z - 1.5, 4.5, 1.75, "acid" },
	{ "glob", spit2.X, spit2.Z, hero.X + 9, hero.Z - 4, 1.05, 7 },
	{ "circle", hero.X + 9, hero.Z - 4, 4.5, 1.05, "acid" },
	{ "circle", tick.X, tick.Z, 8, 0.7, "blast" },
	{ "lane", rhino.X + dir.X * 6.75, rhino.Z + dir.Z * 6.75, math.atan2(-dir.X, -dir.Z), 13.5, 4.8, 0.65 },
	{ "patch", burn.X + 1, burn.Z + 4.5, 3.4, 0.5, 3.2 },
	{ "patch", burn.X + 2, burn.Z + 9, 3.4, 0, 3.2 },
})
C.fire("Notify", { Text = "New: Spitter - dodge the acid", Color = Color3.fromRGB(255, 205, 120) })
preview.advance(tonumber(preview.args.t) or 0.45, 30)
