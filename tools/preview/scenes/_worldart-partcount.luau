-- scratch: part counts by name for one arena (WORLD-ART budget)
local C = lib("common")
local s = C.bootServer()
local name = preview.args.arena or "Forest"
local arena = C.try("BuildArena", s.MapBuilder.BuildArena, name)
local counts = {}
local total = 0
for _, d in ipairs(arena.Model:GetDescendants()) do
	if d:IsA("BasePart") then
		local key = d.Name
		local p = d.Parent
		if p and p:IsA("Model") and p.Parent and p.Parent.Name == "Decor" then key = p.Name .. "/" .. d.Name end
		if p and p:IsA("Model") then key = p.Name end
		counts[key] = (counts[key] or 0) + 1
		total += 1
	end
end
local list = {}
for k, v in pairs(counts) do table.insert(list, { k, v }) end
table.sort(list, function(a, b) return a[2] > b[2] end)
local out = { name .. " total " .. total }
for i = 1, math.min(40, #list) do table.insert(out, list[i][1] .. "=" .. list[i][2]) end
print(table.concat(out, "  "))
