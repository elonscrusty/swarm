-- enemy-telegraphs: the arena around the hero with every enemy warning at once, ~0.45 s
-- into it: a Spitter swelling over its acid landing marker (dashed ring + crosshair), a
-- second Spitter's glob in flight, a Bomb Tick swelling and blinking inside its blast
-- ring, a Rhino Beetle rearing up over its lunge lane, and the three elite affixes
-- (Burning with a fire patch behind it, Shielded, Swift) with their tags. The "New:
-- Spitter" callout toast is on the HUD. --set t=<seconds> changes the moment.
-- --set view=creatures: the later creatures instead: a Burrower tunnelling (only its soil
-- ring and a dust trail), another one about to burst out of its warning circle next to
-- the hero, a Healer glowing with its green pulse, a Nest (HP bar) with mites about to
-- climb out of its openings, and the "New: Healer" toast.
local A = lib("arena")
local C = lib("common")
local E = lib("encounter")
local s = A.build({ swarm = false })
local c = s.centre
local function at(dx, dz)
	return Vector3.new(c.X + dx, c.Y, c.Z + dz)
end
local hero = at(0, 0)
if preview.args.view == "creatures" then
	for i, off in ipairs({ { -30, 6 }, { 28, 10 }, { 33, -12 }, { -36, -14 } }) do
		E.enemy(s, i % 2 == 0 and "Slime" or "Skeleton", at(off[1], off[2]), hero)
	end
	local tunnel = at(-18, 10)
	E.enemy(s, "Burrower", tunnel, hero, { Act = "Tunnel" })
	local pop = at(4, -5)
	E.enemy(s, "Burrower", pop, hero, { Act = "Surface" })
	E.enemy(s, "Burrower", at(12, 9), hero)
	local healer = at(-20, -12)
	E.enemy(s, "Healer", healer, hero, { Act = "Channel" })
	E.enemy(s, "Skeleton", at(-16, -16), hero)
	E.enemy(s, "Brute", at(-26, -8), hero)
	local nestAt = at(22, -14)
	local nest = E.enemy(s, "Nest", nestAt, at(22, -30), { Act = "Pulse" })
	if nest then
		nest:SetAttribute("HPFrac", 0.6)
	end
	preview.advance(0.6)
	E.warn({
		{ "circle", pop.X, pop.Z, 3.2, 0.9, "burrow" },
		{ "pop", healer.X, healer.Z, 14, "heal" },
		{ "circle", nestAt.X, nestAt.Z - 4.4, 1.7, 0.7, "nest" },
		{ "circle", nestAt.X - 4.4, nestAt.Z, 1.7, 0.7, "nest" },
	})
	-- the tunneller moves so its dust trail shows
	local body = nil
	for _, m in ipairs(workspace.SwarmEnemies:GetChildren()) do
		local b = m:FindFirstChild("Body")
		if b and b:GetAttribute("Act") == "Tunnel" then
			body = b
		end
	end
	for _ = 1, 6 do
		if body then
			body.CFrame += Vector3.new(1.2, 0, -0.8)
		end
		preview.advance(0.05)
	end
	C.fire("Notify", { Text = "New: Healer - it heals the swarm, kill it first", Color = Color3.fromRGB(255, 205, 120) })
	preview.advance(tonumber(preview.args.t) or 0.3, 30)
	return
end
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
