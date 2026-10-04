-- friendly-fx: the hero's own area / pickup effects together at normal run zoom, drawn by the
-- real VFX from ProjectileBatch / WeaponFx / FxBatch like the server sends them: a Healing
-- Totem with its pulse (right), two Vine Snares gripping the swarm's edge (left, front),
-- Soul Bolt skulls flying out among the enemies, gold coins flying into the hero and XP gems
-- collected at the hero (the pickup bursts must not cover the hero).
--   --set arena=Snow        any arena (default Forest)
--   --set evolved=on        Lifebloom / Strangleroot / Soul Storm looks
--   --set release=on        the snares end just before the capture (the roots sink back)
--   --set t=<s>             seconds after the batch (default 0.45: coins on their way in)
--   --set dist=<studs>      run camera distance (default: the game's)
--   --set reduced=on        Reduced effects
local A = lib("arena")
local C = lib("common")
local Players = game:GetService("Players")
local s = A.build({ inventory = "new" })
local Config = s.Config
if preview.args.dist then
	Config.Camera.RunDistance = tonumber(preview.args.dist)
end
if preview.args.reduced == "on" then
	local Settings = C.try("require ClientSettings", preview.client, "ClientSettings")
	if Settings then
		Settings.Set("ReducedEffects", true)
	end
end
C.settle(2)
local WeaponData = C.shared("WeaponData")
local me = Players.LocalPlayer
local centre = s.centre
local x, z = centre.X, centre.Z
local y0 = Config.ArenaOrigin.Y
local evo = preview.args.evolved == "on"
local e = evo and 1 or 0
local tier = evo and 3 or 2
local function vb(normal, evolved)
	return WeaponData.VisualByte(evo and evolved or normal, tier)
end

local function batch(items)
	local b = buffer.create(2 + #items * 11)
	buffer.writeu16(b, 0, #items)
	local o = 2
	for i, it in ipairs(items) do
		buffer.writeu16(b, o, it[6] or (500 + i))
		buffer.writeu8(b, o + 2, it[1])
		buffer.writeu8(b, o + 3, 1)
		buffer.writei16(b, o + 4, math.floor(it[2] * 10 + 0.5))
		buffer.writei16(b, o + 6, math.floor(it[3] * 10 + 0.5))
		buffer.writei16(b, o + 8, math.floor(it[4] * 10 + 0.5))
		buffer.writeu8(b, o + 10, math.floor(((it[5] % (math.pi * 2)) / (math.pi * 2)) * 255 + 0.5) % 256)
		o += 11
	end
	return b
end

local planted = {
	{ vb(27, 28), x + 7, y0, z + 3, 0.3, 501 }, -- totem
	{ vb(51, 52), x - 9, y0, z - 3, 1.1, 502 }, -- snares
	{ vb(51, 52), x - 2, y0, z - 10, 2.0, 503 },
}
local souls = {
	{ vb(31, 32), x + 4, y0 + 3.1, z - 5, -0.7, 511 },
	{ vb(31, 32), x - 5, y0 + 3.1, z + 7, 2.2, 512 },
	{ vb(31, 32), x + 12, y0 + 3.1, z + 9, -2.4, 513 },
}
local all = table.clone(planted)
for _, it in ipairs(souls) do
	table.insert(all, it)
end
local snareR = evo and 4.3 or 3.2
C.fire("ProjectileBatch", batch(all))
C.fire("WeaponFx", { vn = { { x - 9, z - 3, snareR, e }, { x - 2, z - 10, snareR, e } } })
preview.advance(0.3, 60)
C.fire("ProjectileBatch", batch(all))
preview.advance(0.3, 60)
C.fire("ProjectileBatch", batch(all))

-- gems collected at the hero and kills that paid gold around it
local gems = workspace:FindFirstChild("SwarmGems") or Instance.new("Folder")
gems.Name = "SwarmGems"
gems.Parent = workspace
local root = me.Character and me.Character.PrimaryPart
local hero = root and root.Position or centre
for i = 1, 6 do
	local gem = s.ModelBuilder.BuildGem(900 + i, gems)
	s.ModelBuilder.StyleGem(gem, i % 3 == 0 and "Medium" or "Small")
	local a = i * 1.05
	local pos = Vector3.new(hero.X + math.cos(a) * 0.8, y0 + Config.XP.GemHeight, hero.Z + math.sin(a) * 0.8)
	gem.CFrame = CFrame.new(pos)
	gem:SetAttribute("Base", pos)
	gem:SetAttribute("Active", true)
	gem:SetAttribute("Fly", me.UserId)
end
preview.advance(0.05, 60)
local coins = {}
for i = 1, 7 do
	local a = i * 0.9
	table.insert(coins, { x + math.cos(a) * 9, z + math.sin(a) * 9, i % 3 == 0 and 9 or 2, me.UserId })
end
C.fire("FxBatch", { g = coins })
-- the totem's pulse healed the hero
C.fire("WeaponFx", { tp = { { x + 7, z + 3, evo and 11 or 9, e, 1 } } })
local t = tonumber(preview.args.t) or 0.45
local steps = math.max(1, math.floor(t / 0.15))
for k = 1, steps do
	if k == 2 then
		for _, gem in ipairs(gems:GetChildren()) do
			if gem:GetAttribute("Fly") == me.UserId then
				gem:SetAttribute("Active", false) -- collected
			end
		end
	end
	if preview.args.release == "on" and k == steps then
		C.fire("ProjectileBatch", batch(souls)) -- the snares and the totem end
	else
		C.fire("ProjectileBatch", batch(all))
	end
	preview.advance(t / steps, 60)
end
preview.metrics.swarm = preview.worldCounts()
