--[[
	AffixSight.lua (Config.Features.AffixIcons, Config.AffixIcons; docs/next/AFFIX_ICONS.md)
	The first-sight notice for elite affixes. The first time a player meets an elite with a
	given affix (a living elite within Config.AffixIcons.SightRange studs of the player's
	hero), they get one line through the notice lane ("Shielded elites block the first
	hits") and the save field SeenAffixes remembers it, so it is once per account and
	affix, never again on later runs.

	The server decides, not the client: the affix is the elite's own field (e.Affix), the
	player's position is the hero's, and the save is marked BEFORE the notice is sent, so a
	second check (or a second elite of the same affix in the same moment) finds it already
	seen. No remote is involved. A DEV-tainted run neither shows nor records the notice
	(DEV spawns would use up the lesson); a spectating / dead player is not "meeting" it.

	EnemySpawner.Step calls AffixSight.Step; the badge itself is client only (AffixIcons.lua).
]]

local Config = require(game:GetService("ReplicatedStorage").Shared.Config)
local AffixIconData = require(game:GetService("ReplicatedStorage").Shared.AffixIconData)

local AffixSight = {}

local INFO = Color3.fromRGB(255, 205, 120)
local timer = 0

local function on(): boolean
	return Config.FeatureOn("AffixIcons")
end

-- The save's SeenAffixes table, repaired in place if it is missing or junk.
function AffixSight.Seen(data: { [string]: any }): { [string]: boolean }
	local t = data.SeenAffixes
	if type(t) ~= "table" then
		t = {}
		data.SeenAffixes = t
	end
	return t
end

-- Marks `affix` as seen in the save. True only the first time (the caller then shows the
-- notice), false for an unknown id or one already seen.
function AffixSight.Mark(data: { [string]: any }, affix: any): boolean
	if not AffixIconData.Get(affix) then
		return false
	end
	local seen = AffixSight.Seen(data)
	if seen[affix] == true then
		return false
	end
	seen[affix] = true
	return true
end

-- One check: every living player against every living elite. `ctx` is the server context,
-- `enemies` the active enemy list (EnemySpawner.Active). Returns how many notices were sent.
function AffixSight.Check(ctx: any, enemies: { any }): number
	if not on() then
		return 0
	end
	local range = tonumber(Config.AffixIcons.SightRange) or 60
	local sent = 0
	for _, rp in ipairs(ctx.RunManager.GetRunPlayers()) do
		local player = rp.Player
		local root = rp.Alive and rp.Root
		if player and player.Parent and root and not rp.DevTainted then
			local data = ctx.DataService.GetData(player)
			if data and data.DevBoosted ~= true then
				local seen = AffixSight.Seen(data)
				for _, e in ipairs(enemies) do
					local affix = e.Alive and e.Elite and e.Affix
					if affix and seen[affix] ~= true and e.Pos then
						local dx, dz = e.Pos.X - root.Position.X, e.Pos.Z - root.Position.Z
						if dx * dx + dz * dz <= range * range and AffixSight.Mark(data, affix) then
							local entry = AffixIconData.Get(affix)
							if entry then
								ctx.RunManager.Notify(player, entry.Notice, INFO, { Id = "affix." .. entry.Id, Lane = "Notice", Class = "Info" })
								sent += 1
							end
						end
					end
				end
			end
		end
	end
	return sent
end

function AffixSight.Step(dt: number, ctx: any, enemies: { any })
	if not on() then
		return
	end
	timer += dt
	if timer < (tonumber(Config.AffixIcons.SightEvery) or 0.5) then
		return
	end
	timer = 0
	AffixSight.Check(ctx, enemies)
end

return AffixSight
