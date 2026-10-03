-- temp: in-run hero built before its meshes loaded must swap to the mesh hero; a failed
-- LoadAsset of the hero is retried.
local Players = game:GetService("Players")
local player = Players.LocalPlayer
preview.setLoadLatency(tonumber(preview.args.base) or 1.5, 6)
local IS = game:GetService("InsertService")
local failsLeft = tonumber(preview.args.fails) or 0
local okPatch = pcall(function()
	local orig = IS.LoadAsset
	IS.LoadAsset = function(self, id)
		if id == 138632496523676 and failsLeft > 0 then
			failsLeft -= 1
			error("HTTP 429 (simulated)")
		end
		return orig(self, id)
	end
end)
preview.log("[knight] patch LoadAsset: " .. tostring(okPatch))
preview.startServer()
preview.advance(1)
local RM = preview.server("RunManager")
local MS = preview.server("MeshService")
local function meshCount(m)
	local n = 0
	if m then for _, d in ipairs(m:GetDescendants()) do if d:IsA("MeshPart") then n += 1 end end end
	return n
end
preview.log(string.format("[knight] Knight loaded at start: %s", tostring(MS.Get("Knight") ~= nil)))
assert(RM.StartTeamRun({ player }, "Solo", "Forest", player))
preview.advance(0.5)
local rp = assert(RM.GetRunPlayer(player))
rp.InvulnUntil = math.huge
local first = rp.Character
preview.log(string.format("[knight] run char at start: meshparts=%d loaded=%s", meshCount(first), tostring(MS.Get("Knight") ~= nil)))
for i = 1, 120 do
	preview.advance(0.5)
	rp.InvulnUntil = math.huge
	if MS.Get("Knight") and rp.Character ~= first then break end
end
preview.log(string.format("[knight] after load: Knight loaded=%s swapped=%s meshparts=%d parent=%s attached=%s humanoid=%s", tostring(MS.Get("Knight") ~= nil), tostring(rp.Character ~= first), meshCount(rp.Character), tostring(rp.Character and rp.Character.Parent), tostring(player.Character == rp.Character), tostring(rp.Humanoid and rp.Humanoid.Parent == rp.Character)))
local p = MS.Progress()
preview.log(string.format("[knight] progress loaded=%d failed=%d total=%d", p.Loaded, p.Failed, p.Total))
