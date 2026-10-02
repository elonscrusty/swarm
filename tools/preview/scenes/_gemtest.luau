local C = lib("common")
local Players = game:GetService("Players")
preview.forceMeshesUploaded()
preview.startServer()
preview.advance(1)
C.startClient()
preview.advance(1)
local me = Players.LocalPlayer
local RM = preview.server("RunManager")
local XP = preview.server("XPSystem")
preview.remote("StartRun"):FireServer("Solo")
preview.advance(1.5)
local rp = RM.GetRunPlayer(me)
rp.InvulnUntil = math.huge
local p = rp.Root.Position
XP.SpawnGem(p + Vector3.new(30, 0, 0), 5)
preview.advance(0.2)
local gem
for _, g in ipairs(workspace.SwarmGems:GetChildren()) do if g:GetAttribute("Active") then gem = g end end
local writes = 0
gem:GetAttributeChangedSignal("Base"):Connect(function() writes += 1 end)
XP.MagnetAll(rp)
preview.advance(0.1)
print("fly attr", gem:GetAttribute("Fly"), "uid", me.UserId)
local vfx = preview.client("VFX")
preview.advance(0.2)
-- kill the target mid-flight
rp.Alive = false
preview.advance(0.1)
print("after target lost: fly", gem:GetAttribute("Fly"), "base", gem:GetAttribute("Base"), "active", gem:GetAttribute("Active"), "base writes", writes)
rp.Alive = true
local xp0 = rp.XP
XP.MagnetAll(rp)
preview.advance(2)
print("collected: active", gem:GetAttribute("Active"), "fly", gem:GetAttribute("Fly"), "xp gained", rp.XP - xp0, "level", rp.Level, "base writes", writes)
