local A = lib("arena")
local C = lib("common")
A.build({ enemies = 10, seconds = 120, stage = 2 })
C.settle(1)
local pg = game:GetService("Players").LocalPlayer:FindFirstChild("PlayerGui")
local total = 0
for _, g in ipairs(pg:GetChildren()) do
	local n = #g:GetDescendants()
	total += n
	if n > 50 then preview.log(string.format("%-28s %6d enabled=%s", g.Name, n, tostring(g:IsA("ScreenGui") and g.Enabled))) end
end
local bb = 0
for _, d in ipairs(workspace:GetDescendants()) do if d:IsA("BillboardGui") or d:IsA("SurfaceGui") then bb += 1 end end
preview.log("total", total, "world guis", bb)
