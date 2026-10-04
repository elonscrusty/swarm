-- props: the interactable family side by side at gameplay zoom (no swarm), built by the
-- real LootSystem / CaravanEvent and driven through real LootHold holds:
--   back row    Shrine of Chance, Bargain Shrine, Guarded Altar
--   middle row  Small, Large and Golden chests, an opened Small chest, a Buried Cache
--   right       the Star/Sun/Moon rune stones (centre tablet shows the order)
--   front left  the Lost Caravan
--   --set rune=0|1|2|solved|reset   rune sequence progress (default 1 correct stone)
--   --set altar=Dormant|Guarded|Claimed   altar state, through real holds (default Dormant)
--   --set bargain=active             seal the bargain
--   --set caravan=Waiting|Defending|Saved|Lost
local A = lib("arena")
local C = lib("common")

local Players = game:GetService("Players")
local placed = {}

local s = A.build({
	swarm = false,
	seconds = 200,
	stage = 2,
	place = function(s, arena, centre)
		local Loot = C.server("LootSystem")
		local Caravan = C.server("CaravanEvent")
		local Config = s.Config
		local player = Players.LocalPlayer
		local root = Instance.new("Part")
		root.Anchored = true
		root.Transparency = 1
		root.Parent = workspace
		local rp = { Player = player, Root = root, Alive = true, Stats = { Luck = 1, GoldMult = 1 } }
		local uid = 0
		local stub = {
			RunManager = {
				GetRunPlayers = function() return { rp } end, GetRunPlayer = function() return rp end,
				IsRunning = function() return true end, IsSimulating = function() return true end,
				GetRunTime = function() return 200 end, Notify = function() end, Broadcast = function() end, HoldReward = function() end,
			},
			StageManager = { GetPhase = function() return "Explore" end },
			MonetizationService = { GoldMultiplier = function() return 1 end },
			GoldSystem = { RunWallet = function() return 99999 end, PriceMult = function() return 1 end, SpendRunGold = function() return true end, AddRunGold = function() end },
			ItemSystem = { Roll = function() return "HealingHerb" end, Grant = function() return true, false end, Refresh = function() end },
			EnemyAI = { IsBlocked = function() return false end },
			EnemySpawner = { ProgressionTime = function() return 200 end, ClampToArena = function(x, z) return x, z end, Spawn = function() uid += 1 return { Uid = uid } end },
		}
		C.try("CaravanEvent.Init", Caravan.Init, stub)
		stub.CaravanEvent = Caravan
		C.try("LootSystem.Init", Loot.Init, stub)
		C.try("LootSystem.Start", Loot.Start)
		Config.Encounters.Types = { "Guarded", "Runes", "Treasure", "Caravan" }
		Config.Encounters.Count = { 4, 4 }
		C.try("LootSystem.BuildStage", Loot.BuildStage, arena, 2, nil)
		local y = centre.Y
		local function at(dx, dz)
			return Vector3.new(centre.X + dx, y, centre.Z + dz)
		end
		local function move(obj, to: Vector3)
			local delta = (to - obj.Pos) * Vector3.new(1, 0, 1)
			obj.Model:PivotTo(obj.Model:GetPivot() + delta)
			obj.Pos += delta
			obj.Model:SetAttribute("Pos", obj.Pos)
			return delta
		end
		local slots = {
			Chance = at(-24, -17), Bargain = at(-13, -18), Guarded = at(22, -17),
			Small = at(-27, -3), Large = at(-20, -3), Golden = at(-12.5, -3), Treasure = at(-5, -3),
		}
		local used, runes, opened = {}, {}, nil
		for _, obj in ipairs(Loot.Objects()) do
			local t = obj.Type
			if t == "Rune" then
				table.insert(runes, obj)
			elseif slots[t] and not used[t] then
				used[t] = true
				move(obj, slots[t])
			elseif t == "Small" and not opened then
				opened = obj
				move(obj, at(-27, 6))
			else
				obj.Model.Parent = nil -- the rest of the stage's chests and shrines
			end
		end
		-- the rune triangle keeps its layout: shift every stone by the same amount
		if #runes > 0 then
			local mid = Vector3.zero
			for _, r in ipairs(runes) do mid += r.Pos end
			mid /= #runes
			local delta = (at(17, -3) - mid) * Vector3.new(1, 0, 1)
			for _, r in ipairs(runes) do move(r, r.Pos + delta) end
			-- (the order tablet is inside the first stone's model: it moved with it)
		end
		local cv = Caravan.Get()
		if cv then
			local delta = (at(-6, 13) - cv.Pos) * Vector3.new(1, 0, 1)
			cv.Model:PivotTo(cv.Model:GetPivot() + delta)
			cv.Pos += delta
		end
		local function hold(obj)
			root.Position = obj.Pos
			s.Remotes.Get("LootHold"):FireServer(obj.Id, true)
			preview.advance(0.05)
			Loot.Step(3)
		end
		if opened then hold(opened) end
		local byRune = {}
		for _, r in ipairs(runes) do byRune[r.Rune] = r end
		local puzzle = runes[1] and runes[1].Puzzle
		local want = preview.args.rune or "1"
		if puzzle then
			if want == "solved" then
				for _, id in ipairs(puzzle.Order) do hold(byRune[id]) end
			elseif want == "reset" then
				hold(byRune[puzzle.Order[1]])
				hold(byRune[puzzle.Order[3]])
			else
				for i = 1, math.min(2, tonumber(want) or 1) do hold(byRune[puzzle.Order[i]]) end
			end
		end
		for _, obj in ipairs(Loot.Objects()) do
			if obj.Kind == "Altar" and used.Guarded then
				local a = preview.args.altar
				if a == "Guarded" or a == "Claimed" then
					hold(obj)
				end
				if a == "Claimed" then
					local guards = {}
					for e in pairs(obj.Guards) do table.insert(guards, e) end
					for _, e in ipairs(guards) do Loot.OnGuardDown(e, true) end
					hold(obj)
				end
			elseif obj.Type == "Bargain" and preview.args.bargain == "active" then
				hold(obj)
			end
		end
		if cv and preview.args.caravan then
			cv.Model:SetAttribute("State", preview.args.caravan)
		end
		preview.metrics.props = #Loot.Objects()
		placed.rp = rp
		return at(3, 9)
	end,
})
C.settle(1)
local _ = s
