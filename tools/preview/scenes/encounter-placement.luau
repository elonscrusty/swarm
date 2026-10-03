local C = lib("common")
local s = C.bootServer()
local Loot, Caravan = C.server("LootSystem"), C.server("CaravanEvent")
local ctx = { RunManager = { GetRunPlayers = function() return {} end }, CaravanEvent = Caravan }
Loot.Init(ctx)
Caravan.Init(ctx)
s.Config.Encounters.Count = { 1, 1 }
local cases = 0
for _, biome in ipairs(s.Config.Arenas.Order) do
	for _, kind in ipairs({ "Guarded", "Caravan", "Runes", "Treasure" }) do
		for variant = 0, 2 do
			local arena = s.MapBuilder.BuildArena(biome, variant)
			s.Config.Encounters.Types = { kind }
			Loot.BuildStage(arena, variant + 1, s.Config.ArenaOrigin + Vector3.new(25, 0, 25))
			local found = kind == "Caravan" and Caravan.Get() ~= nil
			for _, obj in ipairs(Loot.Objects()) do
				if obj.Type == kind or (kind == "Runes" and obj.Type == "Rune") then found = true end
			end
			assert(found, biome .. " " .. kind .. " " .. variant .. " optional location missing")
			Loot.Clear()
			cases += 1
		end
	end
	for variant = 0, 2 do
		local arena = s.MapBuilder.BuildArena(biome, variant)
		s.Config.Encounters.Types = { "Guarded", "Caravan", "Runes", "Treasure" }
		s.Config.Encounters.Count = { 2, 2 }
		Loot.BuildStage(arena, variant + 1)
		local kinds = {}
		if Caravan.Get() then kinds.Caravan = true end
		for _, obj in ipairs(Loot.Objects()) do
			if obj.Type == "Rune" or obj.Type == "Guarded" or obj.Type == "Treasure" then kinds[obj.Type] = true end
		end
		local count = 0
		for _ in pairs(kinds) do count += 1 end
		assert(count == 2, biome .. " paired optional locations missing")
		Loot.Clear()
		s.Config.Encounters.Count = { 1, 1 }
		cases += 1
	end
end
preview.log("PASS optional encounter placement across six biomes, four types, three variants and paired locations", cases)
