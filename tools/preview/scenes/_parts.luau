-- temp: part breakdown by name per arena (scratch, removed after)
local C = lib("common")
local s = C.bootServer()
local out = {}
for _, a in ipairs({ "Forest", "Ruins", "Swamp", "Snow", "Desert", "Lava" }) do
	local arena = s.MapBuilder.BuildArena(a)
	local by = {}
	local tot = 0
	for _, d in ipairs(arena.Model:GetDescendants()) do
		if d:IsA("BasePart") then
			tot += 1
			local key = d.Name
			local p = d.Parent
			if p and p:IsA("Model") and p ~= arena.Model and p.Name ~= "Decor" then key = p.Name .. "/" .. d.ClassName end
			by[key] = (by[key] or 0) + 1
		end
	end
	local list = {}
	for k, v in pairs(by) do table.insert(list, { k, v }) end
	table.sort(list, function(x, y) return x[2] > y[2] end)
	local s2 = a .. " total " .. tot .. ":"
	for i = 1, math.min(40, #list) do s2 ..= " " .. list[i][1] .. "=" .. list[i][2] end
	print(s2)
	s.MapBuilder.DestroyArena()
end
preview.advance(0.1)
