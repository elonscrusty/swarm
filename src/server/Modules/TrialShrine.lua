--[[
	TrialShrine.lua (feature 5, Config.Features.TrialShrine; docs/features/CHALLENGES.md)
	A placed encounter: a violet shrine with a big ring around it. Holding its prompt (the
	normal LootSystem hold) starts the trial for every living player inside the ring:

	  Running   Config.TrialShrine.Seconds of a harder fight: trial enemies (HP / damage x
	            HPMult / DamageMult) are kept alive around the shrine, an elite joins every
	            EliteEvery seconds.
	  Out       a participant who dies, leaves the run or stays outside the ring longer than
	            LeaveGrace is out: no reward for them. Everyone out = the trial fails.
	  Won       every participant still in gets ONE bonus upgrade pick whose card set holds a
	            card above Common (LevelUpSystem.QueueBonusPick: the normal offer / OfferId
	            flow). The state changes before the grant, so it pays exactly once. The trial
	            enemies left are removed (no drops).
	The shrine works once per stage. The portal opening / the boss phase ends a running trial
	with no reward ("the trial fades").

	Replicated: SwarmState TrialLeft (whole seconds, -1 = no trial running), TrialPos,
	TrialRadius; player attributes TrialIn (a participant) and TrialAway (grace seconds left
	while outside the ring, nil inside).
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Config = require(ReplicatedStorage.Shared.Config)
local Remotes = require(ReplicatedStorage.Shared.Remotes)
local EnemyData = require(ReplicatedStorage.Shared.EnemyData)
local Palette = require(ReplicatedStorage.Shared.Palette)
local ModelBuilder = require(script.Parent.ModelBuilder)
local EncounterDirector = require(script.Parent.EncounterDirector)
local Fx = require(script.Parent.Fx)

local TrialShrine = {}

local P = Palette :: { [string]: Color3 }
local NAME = "TrialShrine"
local SIGIL = Color3.fromRGB(150, 110, 255)
local FLAT = Vector3.new(1, 0, 1)
local UPRIGHT = CFrame.Angles(0, 0, math.rad(90))

local ctx
local rng = Random.new()
-- { Obj, Pos, Phase ("Ready" | "Running" | "Won" | "Failed"), Left, Who {rp → {Out, Away}},
--   Foes {{e, uid}}, EliteTimer, SpawnTimer, Ring }
local cur: any = nil

local function T()
	return Config.TrialShrine
end

local function setState(left: number)
	local state = Remotes.State()
	state:SetAttribute("TrialLeft", left)
	if cur and left >= 0 then
		state:SetAttribute("TrialPos", cur.Pos)
		state:SetAttribute("TrialRadius", T().Radius)
	end
end

local function clearPlayer(rp)
	local player: Player? = rp and rp.Player
	if player and player.Parent then
		player:SetAttribute("TrialIn", nil)
		player:SetAttribute("TrialAway", nil)
	end
end

local function foesAlive(): number
	local n = 0
	for i = #cur.Foes, 1, -1 do
		local f = cur.Foes[i]
		if f.e.Alive and f.e.Uid == f.uid then
			n += 1
		else
			table.remove(cur.Foes, i)
		end
	end
	return n
end

local function spawnFoe(elite: boolean): boolean
	local es = ctx.EnemySpawner
	local row = EnemyData.GetSpawnRow(es.ProgressionTime())
	local total = 0
	for id, w in pairs(row.Weights) do
		local def = EnemyData.Enemies[id]
		if def and not def.Static and not def.Object and not def.Burrow then
			total += w
		end
	end
	if total <= 0 then
		return false
	end
	local roll = rng:NextNumber() * total
	local typeId = "Slime"
	for id, w in pairs(row.Weights) do
		local def = EnemyData.Enemies[id]
		if def and not def.Static and not def.Object and not def.Burrow then
			typeId = id
			roll -= w
			if roll <= 0 then
				break
			end
		end
	end
	local def = EnemyData.Enemies[typeId]
	if not def then
		return false
	end
	local S = T()
	for _ = 1, 4 do
		local a = rng:NextNumber(0, math.pi * 2)
		local r = rng:NextNumber(S.SpawnRadius[1], S.SpawnRadius[2])
		local x, z = es.ClampToArena(cur.Pos.X + math.cos(a) * r, cur.Pos.Z + math.sin(a) * r, 4)
		if def.Ghost or not ctx.EnemyAI.IsBlocked(x, z, def.Radius * (elite and Config.Enemies.EliteSizeMult or 1)) then
			local e = es.Spawn(typeId, Vector3.new(x, Config.ArenaOrigin.Y, z), { Elite = elite, Force = true })
			if not e then
				return false
			end
			e.MaxHP *= S.HPMult
			e.HP = e.MaxHP
			e.Damage *= S.DamageMult
			e.DmgScale = (e.DmgScale or 1) * S.DamageMult
			if e.Shield and e.Shield > 0 then
				e.Shield *= S.HPMult
			end
			table.insert(cur.Foes, { e = e, uid = e.Uid })
			return true
		end
	end
	return false
end

local function participants(): number
	local n = 0
	for _, w in pairs(cur.Who) do
		if not w.Out then
			n += 1
		end
	end
	return n
end

local function shrineText(detail: string, ready: boolean?)
	local S = T()
	ctx.LootSystem.SetObjState(cur.Obj, ready and "Ready" or (cur.Phase == "Running" and "Active" or "Spent"), {
		Benefit = string.format("Survive %d s in the ring: 1 bonus upgrade with a rare card", S.Seconds),
		Tradeoff = "Harder enemies attack · leave the ring or fall: no reward",
		Detail = detail,
	})
end

local function ringLook(color: Color3, transparency: number)
	local ring = cur and cur.Ring
	if ring and ring.Parent then
		ring.Color = color
		ring.Transparency = transparency
	end
end

local function finish(won: boolean, why: string?)
	if not cur or cur.Phase ~= "Running" then
		return
	end
	cur.Phase = won and "Won" or "Failed" -- first: nothing below can pay twice
	setState(-1)
	local winners = {}
	for rp, w in pairs(cur.Who) do
		clearPlayer(rp)
		if won and not w.Out and rp.Alive and not rp.Returned and rp.Stats then
			table.insert(winners, rp)
		end
	end
	if won then
		for _, rp in ipairs(winners) do
			ctx.LevelUpSystem.QueueBonusPick(rp)
			ctx.RunManager.Notify(rp.Player, "Trial won! A bonus upgrade with a rare card.", Color3.fromRGB(205, 170, 255), { Id = "trial.won" })
		end
		for _, f in ipairs(cur.Foes) do
			if f.e.Alive and f.e.Uid == f.uid then
				ctx.EnemySpawner.Despawn(f.e) -- the trial's leftovers go (no drops)
			end
		end
		Fx.Ring(cur.Pos, T().Radius, P.gold_300)
		Fx.Sound("Shrine")
		shrineText("Trial complete")
		ctx.LootSystem.SetGlow(cur.Obj, P.gold_400, 0)
		ringLook(P.gold_300, 1)
	else
		ctx.RunManager.Broadcast(why or "The trial failed: no reward.", Color3.fromRGB(200, 200, 210), nil, { Id = "trial.failed" })
		shrineText("Trial failed")
		ctx.LootSystem.SetGlow(cur.Obj, P.stone_500, 1)
		ringLook(P.stone_400, 1)
	end
	table.clear(cur.Foes)
	EncounterDirector.Finish(NAME)
end

local function inRing(rp): boolean
	local root = rp.Root
	return root ~= nil and ((((root :: BasePart).Position - cur.Pos) * FLAT).Magnitude <= T().Radius)
end

local function start(rp, _obj)
	if not cur or cur.Phase ~= "Ready" then
		return
	end
	if ctx.StageManager.GetPhase() ~= "Explore" then
		ctx.RunManager.Notify(rp.Player, "The trial can't start now.", Color3.fromRGB(200, 200, 210))
		return
	end
	cur.Phase = "Running"
	cur.Left = T().Seconds
	cur.EliteTimer = 0
	cur.SpawnTimer = 0
	table.clear(cur.Who)
	for _, other in ipairs(ctx.RunManager.GetRunPlayers()) do
		if other.Alive and not other.Returned and (other == rp or inRing(other)) then
			cur.Who[other] = { Out = false, Away = 0 }
			if other.Player.Parent then
				other.Player:SetAttribute("TrialIn", true)
			end
		end
	end
	setState(math.ceil(cur.Left))
	shrineText("Trial running")
	ringLook(SIGIL, 0.55)
	spawnFoe(true)
	Fx.Ring(cur.Pos, T().Radius, SIGIL)
	Fx.Sound("BossRoar")
	ctx.RunManager.Broadcast(string.format("Trial started! Survive %d s inside the ring.", T().Seconds), Color3.fromRGB(205, 170, 255), nil, { Id = "trial.start" })
end

local function out(rp, why: string)
	local w = cur and cur.Who[rp]
	if not w or w.Out or cur.Phase ~= "Running" then
		return
	end
	w.Out = true
	clearPlayer(rp)
	if rp.Player and rp.Player.Parent then
		ctx.RunManager.Notify(rp.Player, why, Color3.fromRGB(255, 150, 150), { Id = "trial.out" })
	end
	if participants() == 0 then
		finish(false, "The trial failed: no reward.")
	end
end

------------------------------------------------------------------------------------------
-- EncounterDirector callbacks
------------------------------------------------------------------------------------------

local function cleanup(_reason: string?)
	if not cur then
		return
	end
	for rp in pairs(cur.Who) do
		clearPlayer(rp)
	end
	cur = nil
	setState(-1)
end

local function onStageStart(info): boolean
	cleanup()
	local pos = EncounterDirector.FindSpot(NAME)
	if not pos then
		return false
	end
	local obj = ctx.LootSystem.AddFeatureShrine(info.Arena, "Trial", pos, SIGIL, P.slate_600)
	obj.Model:SetAttribute("Title", "Shrine of Trial")
	obj.Model:SetAttribute("Hold", T().Hold)
	obj.OnComplete = start
	-- the trial ring (faint until it runs)
	local r = T().Radius
	local ring = ModelBuilder.Part({ Name = "TrialRing", Shape = Enum.PartType.Cylinder, Size = Vector3.new(0.06, r * 2, r * 2), CFrame = CFrame.new(pos + Vector3.new(0, 0.06, 0)) * UPRIGHT, Color = SIGIL, Transparency = 0.9 })
	ring.Parent = obj.Model
	cur = { Obj = obj, Pos = pos, Phase = "Ready", Left = 0, Who = {}, Foes = {}, EliteTimer = 0, SpawnTimer = 0, Ring = ring }
	shrineText("Free · once per stage", true)
	return true
end

local function onTick(dt: number, info)
	if not cur or cur.Phase ~= "Running" then
		return
	end
	if info.Phase ~= "Explore" then
		finish(false, "The trial fades: no reward.")
		return
	end
	local S = T()
	local players = ctx.RunManager.GetRunPlayers()
	for rp, w in pairs(cur.Who) do
		if not w.Out then
			if not table.find(players, rp) or rp.Returned then
				out(rp, "You left the trial: no reward.")
			elseif not rp.Alive then
				out(rp, "You fell in the trial: no reward.")
			elseif inRing(rp) then
				if w.Away > 0 then
					w.Away = 0
					rp.Player:SetAttribute("TrialAway", nil)
				end
			else
				w.Away += dt
				if w.Away > S.LeaveGrace then
					out(rp, "You left the ring: no reward.")
				else
					rp.Player:SetAttribute("TrialAway", math.ceil((S.LeaveGrace - w.Away) * 10) / 10)
				end
			end
		end
		if not cur or cur.Phase ~= "Running" then
			return
		end
	end
	cur.Left -= dt
	if cur.Left <= 0 then
		finish(true)
		return
	end
	setState(math.ceil(cur.Left))
	-- keep the trial crowd up (a few per beat, never a burst)
	cur.SpawnTimer -= dt
	cur.EliteTimer += dt
	if cur.SpawnTimer <= 0 then
		cur.SpawnTimer = 0.25
		local want = S.Alive + S.AlivePerExtraPlayer * math.max(0, participants() - 1)
		local alive = foesAlive()
		for _ = 1, math.min(3, want - alive) do
			spawnFoe(false)
		end
	end
	if cur.EliteTimer >= S.EliteEvery then
		cur.EliteTimer = 0
		spawnFoe(true)
	end
end

local function onPlayerOut(rp, reason: string)
	if cur and cur.Phase == "Running" then
		out(rp, reason == "Death" and "You fell in the trial: no reward." or "You left the trial: no reward.")
	end
end

-- Tests / tools: the live shrine (nil when none).
function TrialShrine.Get()
	return cur
end

function TrialShrine.Init(c)
	ctx = c
	EncounterDirector.Register(NAME, {
		Feature = "TrialShrine",
		Weight = Config.TrialShrine.Weight,
		OnStageStart = onStageStart,
		OnTick = onTick,
		OnCleanup = cleanup,
		OnPlayerOut = onPlayerOut,
	})
end

return TrialShrine
