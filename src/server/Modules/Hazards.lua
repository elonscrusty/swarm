--[[
	Hazards.lua
	Server-side enemy attacks that are not bodies or straight projectiles: delayed ground
	strikes (a Spitter's acid glob landing, the Queen's Venom Burst circles and her burrow
	eruption) and lingering patches (a Burning elite's fire). Each one is shown to every
	client once through an Fx warning (src/client/Telegraphs.lua draws the circle / glob /
	patch); the damage is decided here, at the moment the telegraph said, against the
	players' server positions. Nothing is per-frame network traffic.

	Strike: { Pos, Radius, Left (seconds until it lands), Damage, Group, Style, Warn }
	Patch:  { Pos, Radius, Arm (harmless glow time left), Life, Tick, Damage, Hit = {rp = t} }
	Group "Boss" marks the Queen's hazards (cleared at once when she dies or the stage ends).

	Stepped by EnemyAI (only while the run simulates: pauses freeze hazards too).
]]

local Fx = require(script.Parent.Fx)

local Hazards = {}

local ctx
local PLAYER_RADIUS = 1.2

local strikes: { any } = {}
local patches: { any } = {}

-- Living run players whose root is within `radius` (+ their body) of a floor point.
local function playersIn(pos: Vector3, radius: number): { any }
	local out = {}
	for _, rp in ipairs(ctx.RunManager.GetRunPlayers()) do
		local root: BasePart? = rp.Root
		if rp.Alive and root then
			local dx, dz = root.Position.X - pos.X, root.Position.Z - pos.Z
			local r = radius + PLAYER_RADIUS * 0.5
			if dx * dx + dz * dz <= r * r then
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
	local o = opts or {}
	local style = o.Style or "venom"
	local warn = o.Warn or Fx.Warn("circle", pos.X, pos.Z, radius, delay, style)
	local s = { Pos = pos, Radius = radius, Left = delay, Damage = damage, Group = o.Group, Style = style, Warn = warn, OnStrike = o.OnStrike }
	table.insert(strikes, s)
	return s
end

-- A lingering patch: harmless for `arm` seconds (it glows), then burns for `life`.
function Hazards.Patch(pos: Vector3, radius: number, arm: number, life: number, tick: number, damage: number, group: string?)
	local p = {
		Pos = pos,
		Radius = radius,
		Arm = arm,
		Life = life,
		Tick = tick,
		Damage = damage,
		Group = group,
		Hit = {},
		Warn = Fx.Warn("patch", pos.X, pos.Z, radius, arm, life),
	}
	table.insert(patches, p)
	return p
end

function Hazards.IsLive(h): boolean
	return table.find(strikes, h) ~= nil or table.find(patches, h) ~= nil
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
end

function Hazards.Count(): number
	return #strikes + #patches
end

function Hazards.Step(dt: number)
	for i = #strikes, 1, -1 do
		local s = strikes[i]
		s.Left -= dt
		if s.Left <= 0 then
			table.remove(strikes, i)
			for _, rp in ipairs(playersIn(s.Pos, s.Radius)) do
				ctx.RunManager.DamagePlayer(rp, s.Damage)
			end
			Fx.Warn("pop", s.Pos.X, s.Pos.Z, s.Radius, s.Style)
			if s.OnStrike then
				s.OnStrike(s)
			end
		end
	end
	local now = os.clock()
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
						ctx.RunManager.DamagePlayer(rp, p.Damage)
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
