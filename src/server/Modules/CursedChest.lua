--[[
	CursedChest.lua (feature 7, Config.Features.CursedChests; docs/features/CHALLENGES.md)
	After LootSystem places a stage's chests (LootSystem.OnBuilt), one paid Small or Large
	chest may turn cursed (Config.CursedChest.Chance, own Random: the stage's loot rolls are
	unchanged). A cursed chest keeps its price and its hold; it rolls its item with the
	better CursedChest.Weights and wears a violet curse look (tinted chest, violet beam and
	trim, a dark orb, a violet ring). Its prompt states the curse BEFORE the hold
	("- Curse: enemies +25% damage, +15% speed for 60 s").

	Opening it (LootSystem.openChest: the item is granted first, exactly once) starts the
	curse for the whole team: for Seconds of run time (frozen runs pause it) every enemy
	except bosses deals x EnemyDamageMult damage and moves x EnemySpeedMult. Another cursed
	chest opened meanwhile restarts the timer (no stacking). The curse ends early when the
	stage ends (travel / run end); the multipliers are taken back off the living enemies.

	Replicated: SwarmState CurseLeft (whole seconds, 0 = no curse) for the HUD badge.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Config = require(ReplicatedStorage.Shared.Config)
local Remotes = require(ReplicatedStorage.Shared.Remotes)
local ModelBuilder = require(script.Parent.ModelBuilder)
local EncounterDirector = require(script.Parent.EncounterDirector)
local Fx = require(script.Parent.Fx)

local CursedChest = {}

local NAME = "CursedChests"
local CURSE = Color3.fromRGB(150, 70, 210)
local CURSE_GLOW = Color3.fromRGB(190, 120, 255)
local UPRIGHT = CFrame.Angles(0, 0, math.rad(90))

local ctx
local rng = Random.new()
local curseLeft = 0
local shownLeft = -1
local buffed: { { e: any, uid: number } } = {}
local buffedUid: { [number]: boolean } = {} -- enemy Uid → buffed now

local function K()
	return Config.CursedChest
end

local function pct(x: number): number
	return math.floor((x - 1) * 100 + 0.5)
end

local function benefitText(weights: { [string]: number }): string
	local total = 0
	for _, w in pairs(weights) do
		total += w
	end
	local parts = {}
	for _, rarity in ipairs({ "Common", "Uncommon", "Legendary" }) do
		local w = weights[rarity] or 0
		if w > 0 and total > 0 then
			table.insert(parts, string.format("%d%% %s", math.floor(w / total * 100 + 0.5), string.lower(rarity)))
		end
	end
	return "Better loot: 1 item (" .. table.concat(parts, ", ") .. " before luck)"
end

function CursedChest.TradeoffText(): string
	return string.format("Curse: enemies +%d%% damage, +%d%% speed for %d s", pct(K().EnemyDamageMult), pct(K().EnemySpeedMult), K().Seconds)
end

local function publish(left: number)
	local whole = left > 0 and math.ceil(left) or 0
	if whole ~= shownLeft then
		shownLeft = whole
		Remotes.State():SetAttribute("CurseLeft", whole)
	end
end

------------------------------------------------------------------------------------------
-- Enemy buff (applied to every living non-boss enemy while the curse runs)
------------------------------------------------------------------------------------------

local function buff(e)
	local k = K()
	e.Speed *= k.EnemySpeedMult
	e.Damage *= k.EnemyDamageMult
	e.DmgScale = (e.DmgScale or 1) * k.EnemyDamageMult
	buffedUid[e.Uid] = true
	table.insert(buffed, { e = e, uid = e.Uid })
end

local function unbuffAll()
	local k = K()
	for _, b in ipairs(buffed) do
		local e = b.e
		if e.Alive and e.Uid == b.uid then
			e.Speed /= k.EnemySpeedMult
			e.Damage /= k.EnemyDamageMult
			e.DmgScale = (e.DmgScale or 1) / k.EnemyDamageMult
		end
	end
	table.clear(buffed)
	table.clear(buffedUid)
end

local function endCurse()
	if curseLeft > 0 or #buffed > 0 then
		unbuffAll()
	end
	curseLeft = 0
	publish(0)
end

-- True while the curse is on (tests / other features).
function CursedChest.Active(): boolean
	return curseLeft > 0
end

function CursedChest.Left(): number
	return curseLeft
end

------------------------------------------------------------------------------------------
-- The chest
------------------------------------------------------------------------------------------

local function onOpened(rp, _obj)
	local fresh = curseLeft <= 0
	curseLeft = K().Seconds
	publish(curseLeft)
	Fx.Ring((rp.Root and (rp.Root :: BasePart).Position) or Config.ArenaOrigin, 40, CURSE_GLOW)
	Fx.Sound("BossRoar")
	ctx.RunManager.Broadcast(
		string.format("%s opened a cursed chest! Enemies are stronger for %d s.", rp.Player.DisplayName, K().Seconds),
		CURSE_GLOW,
		nil,
		{ Id = fresh and "curse.start" or "curse.refresh" }
	)
end

local function curse(obj)
	obj.Weights = K().Weights[obj.Type]
	obj.Title = "Cursed chest"
	obj.OnOpened = onOpened
	local m: Model = obj.Model
	m:SetAttribute("Title", "Cursed " .. (obj.Type == "Large" and "Large Chest" or "Small Chest"))
	m:SetAttribute("Benefit", benefitText(obj.Weights))
	m:SetAttribute("Tradeoff", CursedChest.TradeoffText())
	m:SetAttribute("Cursed", true)
	-- look: the chest tinted violet, the beam and trim violet, a dark orb and a ring
	for _, d in ipairs(m:GetDescendants()) do
		if d:IsA("BasePart") then
			if d.Name == "Beam" then
				d.Color = CURSE_GLOW
				d.Transparency = math.min(d.Transparency, 0.7)
			elseif d.Name == "PlinthTrim" or d.Name == "Coin" then
				d.Color = CURSE
			elseif obj.Chest and d:IsDescendantOf(obj.Chest) then
				d.Color = d.Color:Lerp(CURSE, 0.45)
			end
		end
	end
	local orb = ModelBuilder.Part({ Name = "CurseOrb", Shape = Enum.PartType.Ball, Size = Vector3.new(1.1, 1.1, 1.1), CFrame = CFrame.new(obj.Pos + Vector3.new(0, 5.6, 0)), Color = CURSE_GLOW, Material = Enum.Material.Neon })
	orb.Parent = m
	table.insert(obj.Glow, orb) -- hidden when it is opened (LootSystem)
	local light = Instance.new("PointLight")
	light.Color = CURSE_GLOW
	light.Range = 16
	light.Brightness = 1.4
	light.Shadows = false
	light.Parent = orb
	local r = Config.Chests.InteractRadius
	local ring = ModelBuilder.Part({ Name = "CurseRing", Shape = Enum.PartType.Cylinder, Size = Vector3.new(0.07, r * 2, r * 2), CFrame = CFrame.new(obj.Pos + Vector3.new(0, 0.06, 0)) * UPRIGHT, Color = CURSE, Material = Enum.Material.Neon, Transparency = 0.55 })
	ring.Parent = m
	obj.Ring = ring
end

local function onBuilt(_arena, stage: number)
	if not Config.FeatureOn("CursedChests") or stage < K().MinStage then
		return
	end
	if rng:NextNumber() >= K().Chance then
		return
	end
	local options = {}
	for _, obj in ipairs(ctx.LootSystem.Objects()) do
		if obj.Kind == "Chest" and table.find(K().Types, obj.Type) and obj.State == "Ready" and obj.Price > 0 and not obj.OnOpened and not obj.Weights then
			table.insert(options, obj)
		end
	end
	if #options > 0 then
		curse(options[rng:NextInteger(1, #options)])
	end
end

------------------------------------------------------------------------------------------
-- EncounterDirector: ticks + cleanup only (never takes a placed slot)
------------------------------------------------------------------------------------------

local function onTick(dt: number, _info)
	if curseLeft <= 0 then
		return
	end
	curseLeft -= dt
	if curseLeft <= 0 then
		endCurse()
		ctx.RunManager.Broadcast("The curse has lifted.", CURSE_GLOW, nil, { Id = "curse.end" })
		return
	end
	publish(curseLeft)
	for _, e in ipairs(ctx.EnemySpawner.Active) do
		if not buffedUid[e.Uid] and not e.Boss and not e.Def.Object then
			buff(e)
		end
	end
	-- forget the dead now and then (the list only grows during one curse)
	if #buffed > 600 then
		for i = #buffed, 1, -1 do
			local b = buffed[i]
			if not (b.e.Alive and b.e.Uid == b.uid) then
				buffedUid[b.uid] = nil
				table.remove(buffed, i)
			end
		end
	end
end

function CursedChest.Init(c)
	ctx = c
	ctx.LootSystem.OnBuilt(onBuilt)
	EncounterDirector.Register(NAME, {
		Feature = "CursedChests",
		Allow = function()
			return false -- no spot / slot of its own: it only needs ticks and cleanup
		end,
		OnTick = onTick,
		OnCleanup = function(_reason)
			endCurse()
		end,
	})
end

return CursedChest
