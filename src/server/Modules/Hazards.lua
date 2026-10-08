--[[
	Hazards.lua
	Server-side enemy attacks that are not bodies or straight projectiles: delayed ground
	strikes (a Spitter's acid glob landing, the Queen's Venom Burst circles and her burrow
	eruption) and lingering patches (a Burning elite's fire). Each one is shown to every
	client once through an Fx warning (src/client/Telegraphs.lua draws the circle / glob /
	patch); the damage is decided here, at the moment the telegraph said, against the
	players' server positions. Nothing is per-frame network traffic.

	Strike: { Pos, Radius, Inner (annulus: only Inner..Radius is hit), Left (seconds until it
	          lands), Damage, Group, Style, Warn, OnStrike }
	Patch:  { Pos, Radius, Arm (harmless glow time left), Life, Tick, Damage, Hit = {rp = t} }
	Wave:   { Pos, R (current radius), Speed, MaxR, Width, Gap (angle), GapHalf (radians),
	          Delay, Damage, Passed = {rp = true} }: a ring rolling outward from Pos (the Moth
	          Matriarch's Dust Storm); it hits a player once when it passes them unless they
	          stand in the gap. The client draws it from the same numbers ("wave").
	Group "Boss" marks a boss's hazards (cleared at once when it dies or the stage ends).

	Stepped by EnemyAI (only while the run simulates: pauses freeze hazards too).
]]

local Fx = require(script.Parent.Fx)
local Config = require(game:GetService("ReplicatedStorage").Shared.Config)
local HeightGrid = require(script.Parent.HeightGrid)
local Nav = require(game:GetService("ReplicatedStorage").SwarmV2.Run.RunConfig).Nav

local Hazards = {}

local ctx
local PLAYER_RADIUS = 1.2

local strikes: { any } = {}
local patches: { any } = {}

local waves: { any } = {}

-- Cancel a pending warning before accepting a new hazard at the ceiling.
-- Eviction never leaves damage behind after the player's warning disappears.
local function makeRoom()
	while #strikes + #patches + #waves >= Config.Enemies.MaxHazards do
		local list = #strikes > 0 and strikes or (#patches > 0 and patches or waves)
		local h = table.remove(list, 1)
		if h.Warn then Fx.ClearWarn(h.Warn) end
	end
end

-- Living run players whose root is within `radius` (+ their body) of a floor point
-- (inner > 0: and at least `inner` from it, a ring band).
local function playersIn(pos: Vector3, radius: number, inner: number?): { any }
	local out = {}
	local r = radius + PLAYER_RADIUS * 0.5
	local r0 = inner or 0
	local heights = HeightGrid.IsActive()
	for _, rp in ipairs(ctx.RunManager.GetRunPlayers()) do
		local root: BasePart? = rp.Root
		if rp.Alive and root then
			local rpos = root.Position
			local dx, dz = rpos.X - pos.X, rpos.Z - pos.Z
			local d2 = dx * dx + dz * dz
			-- with a height grid: only a player on (about) the hazard's ground level
			if d2 <= r * r and d2 >= r0 * r0 and (not heights or math.abs(HeightGrid.GroundY(rpos.X, rpos.Z) - pos.Y) <= Nav.HazardBand) then
				table.insert(out, rp)
			end
		end
	end
	return out
end
Hazards.PlayersIn = playersIn

--[[
	A ground strike after `delay` seconds. opts.Warn = an Fx warning id to keep (the caller
	drew its own telegraph), otherwise a circle telegraph of opts.Style is drawn here.
	Returns the strike record.
]]
function Hazards.Strike(pos: Vector3, radius: number, delay: number, damage: number, opts: { [string]: any }?)
	makeRoom()
	pos = HeightGrid.Ground(pos) -- every hazard sits on the ground at its x, z
	local o = opts or {}
	local style = o.Style or "venom"
	local warn = o.Warn or Fx.Warn("circle", pos.X, pos.Z, radius, delay, style)
	local s = { Pos = pos, Radius = radius, Inner = o.Inner, Left = delay, Damage = damage, Group = o.Group, Style = style, Warn = warn, OnStrike = o.OnStrike, NoPop = o.NoPop, Cause = o.Cause or (style == "burrow" and "Burrow eruption" or "Ground eruption") }
	table.insert(strikes, s)
	return s
end

-- A lingering patch: harmless for `arm` seconds (it glows), then burns for `life`.
-- style "fire" (a Burning elite, the default) | "acid" (the Hive Mother's pools).
function Hazards.Patch(pos: Vector3, radius: number, arm: number, life: number, tick: number, damage: number, group: string?, style: string?)
	makeRoom()
	pos = HeightGrid.Ground(pos)
	local p = {
		Pos = pos,
		Radius = radius,
		Arm = arm,
		Life = life,
		Tick = tick,
		Damage = damage,
		Group = group,
		Cause = style == "acid" and "Acid pool" or "Burning elite fire",
		Hit = {},
		Warn = Fx.Warn("patch", pos.X, pos.Z, radius, arm, life, style or "fire"),
	}
	table.insert(patches, p)
	return p
end

--[[
	A ring wave rolling out of `pos` after `delay` seconds at `speed` up to `maxRadius`,
	`width` thick, with one gap of +/- gapHalf (radians) around the angle `gap` (math.atan2
	of z, x). The caller draws its telegraph (opts.Warn, kept with the hazard so it is
	cleared with it). Returns the wave record.
]]
function Hazards.Wave(pos: Vector3, delay: number, speed: number, maxRadius: number, width: number, gap: number, gapHalf: number, damage: number, opts: { [string]: any }?)
	makeRoom()
	pos = HeightGrid.Ground(pos)
	local o = opts or {}
	local w = { Pos = pos, R = o.Start or 0, Speed = speed, MaxR = maxRadius, Width = width, Gap = gap, GapHalf = gapHalf, Delay = delay, Damage = damage, Group = o.Group, Warn = o.Warn, Passed = {}, Cause = o.Cause or "Boss shockwave" }
	table.insert(waves, w)
	return w
end

function Hazards.IsLive(h): boolean
	return table.find(strikes, h) ~= nil or table.find(patches, h) ~= nil or table.find(waves, h) ~= nil
end

-- Removes hazards (group nil = all of them) and cancels their warnings on the clients.
function Hazards.Clear(group: string?)
	for i = #strikes, 1, -1 do
		local s = strikes[i]
		if group == nil or s.Group == group then
			Fx.ClearWarn(s.Warn)
			table.remove(strikes, i)
		end
	end
	for i = #patches, 1, -1 do
		local p = patches[i]
		if group == nil or p.Group == group then
			Fx.ClearWarn(p.Warn)
			table.remove(patches, i)
		end
	end
	for i = #waves, 1, -1 do
		local w = waves[i]
		if group == nil or w.Group == group then
			if w.Warn then
				Fx.ClearWarn(w.Warn)
			end
			table.remove(waves, i)
		end
	end
end

function Hazards.Count(): number
	return #strikes + #patches + #waves
end

-- Smallest angle between two angles (radians).
local function angleGap(a: number, b: number): number
	local d = (a - b) % (math.pi * 2)
	return math.min(d, math.pi * 2 - d)
end

function Hazards.Step(dt: number)
	if not ctx.RunManager.IsSimulating() then return end
	for i = #strikes, 1, -1 do
		local s = strikes[i]
		s.Left -= dt
		if s.Left <= 0 then
			table.remove(strikes, i)
			if s.Damage > 0 then
				for _, rp in ipairs(playersIn(s.Pos, s.Radius, s.Inner)) do
					ctx.RunManager.DamagePlayer(rp, s.Damage, s.Cause)
				end
			end
			if not s.NoPop then
				Fx.Warn("pop", s.Pos.X, s.Pos.Z, s.Radius, s.Style, s.Inner)
			end
			if s.OnStrike then
				s.OnStrike(s)
			end
		end
	end
	local now = ctx.RunManager.GetRunTime()
	for i = #patches, 1, -1 do
		local p = patches[i]
		if p.Arm > 0 then
			p.Arm -= dt
		else
			p.Life -= dt
			if p.Life <= 0 then
				table.remove(patches, i)
			else
				for _, rp in ipairs(playersIn(p.Pos, p.Radius)) do
					if now >= (p.Hit[rp] or 0) then
						p.Hit[rp] = now + p.Tick
						ctx.RunManager.DamagePlayer(rp, p.Damage, p.Cause)
					end
				end
			end
		end
	end
	for i = #waves, 1, -1 do
		local w = waves[i]
		if w.Delay > 0 then
			w.Delay -= dt
		else
			w.R += w.Speed * dt
			if w.R - w.Width > w.MaxR then
				table.remove(waves, i)
			else
				local half = w.Width / 2 + PLAYER_RADIUS * 0.5
				for _, rp in ipairs(ctx.RunManager.GetRunPlayers()) do
					local root: BasePart? = rp.Root
					if rp.Alive and root and not w.Passed[rp] then
						local rpos = root.Position
						local dx, dz = rpos.X - w.Pos.X, rpos.Z - w.Pos.Z
						local d = math.sqrt(dx * dx + dz * dz)
						if math.abs(d - w.R) <= half and not HeightGrid.InBand(HeightGrid.GroundY(rpos.X, rpos.Z), w.Pos.Y, Nav.HazardBand) then
							w.Passed[rp] = true -- another level (a terrace above / below): it rolls past
						elseif math.abs(d - w.R) <= half then
							-- the band reached them: hit unless they stand in the gap
							w.Passed[rp] = true
							if d < 0.5 or angleGap(math.atan2(dz, dx), w.Gap) > w.GapHalf then
								ctx.RunManager.DamagePlayer(rp, w.Damage, w.Cause)
							end
						elseif d < w.R - half then
							w.Passed[rp] = true -- already behind the ring (it rolled past)
						end
					end
				end
			end
		end
	end
end

function Hazards.Init(c)
	ctx = c
end

return Hazards
