-- TEMP (world helper): parts per top-level Decor model name
local C = lib("common")
local s = C.bootServer()
local arena = s.MapBuilder.BuildArena(preview.args.arena or "Forest")
local counts = {}
for _, ch in ipairs(arena.Decor:GetChildren()) do
	local n = 0
	if ch:IsA("BasePart") then n = 1 else for _, d in ipairs(ch:GetDescendants()) do if d:IsA("BasePart") then n += 1 end end end
	counts[ch.Name] = (counts[ch.Name] or 0) + n
end
local list = {}
for k, v in pairs(counts) do table.insert(list, { k, v }) end
table.sort(list, function(a, b) return a[2] > b[2] end)
for i = 1, math.min(25, #list) do print("COUNT", list[i][1], list[i][2]) end
