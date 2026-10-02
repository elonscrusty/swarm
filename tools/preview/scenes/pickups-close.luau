-- pickups-close: close-up of XP gems (small / medium / large) next to gold coins and a trail
-- of Fire Trail patches, with the run camera pulled in (--set dist=16). No enemies.
--   --set evolved=on   Phoenix Stride flames     --set trail=off   gems only
--   --set reduced=on   Reduced effects look      --set t=1.2       seconds to let the flames burn
local A = lib("arena")
local C = lib("common")
local s = A.build({ swarm = false })
local Config = s.Config
Config.Camera.RunDistance = tonumber(preview.args.dist) or 16
if preview.args.reduced == "on" then
	local Settings = C.try("require ClientSettings", preview.client, "ClientSettings")
	if Settings then
		Settings.Set("ReducedEffects", true)
	end
end
local centre = s.centre
local y0 = Config.ArenaOrigin.Y
local gems = workspace:FindFirstChild("SwarmGems") or Instance.new("Folder")
gems.Name = "SwarmGems"
gems.Parent = workspace
local kinds = { "Small", "Medium", "Large", "Small", "Small", "Medium", "Small", "Large" }
for i, kind in ipairs(kinds) do
	local gem = s.ModelBuilder.BuildGem(i, gems)
	s.ModelBuilder.StyleGem(gem, kind)
	local x, z = centre.X - 7 + (i - 1) % 4 * 4.5, centre.Z - 6 - math.floor((i - 1) / 4) * 4
	local pos = Vector3.new(x, y0 + Config.XP.GemHeight, z)
	gem.CFrame = CFrame.new(pos)
	gem:SetAttribute("Base", pos)
	gem:SetAttribute("Active", true)
end
C.settle(1)
if preview.args.trail ~= "off" then
	local evo = preview.args.evolved == "on"
	local patches = {}
	for i = 1, 8 do
		table.insert(patches, { centre.X - 8 + i * 2.3, centre.Z + 2 + math.sin(i * 0.7) * 1.5, 3.2, 3.5, evo and 1 or 0 })
	end
	for i, p in ipairs(patches) do
		C.fire("WeaponFx", { fp = { p } })
		C.settle(0.12)
	end
end
C.settle(tonumber(preview.args.t) or 0.8)
