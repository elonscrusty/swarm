-- arms-sim: boots the REAL server and client, checks the Knight's arms on the lobby dais
-- (Showcase clone) and on the player's own lobby character on a fresh boot, after a
-- run left with MAIN MENU (AbandonRun) and after a death → results → MAIN MENU
-- (ReturnToLobby). Prints each arm part (exists, Transparency, LTM, Parent, size, offset
-- from the torso) and renders the dais close-up at the end. Run:
-- render.sh arms-sim --studio --devices pc [--set path=abandon|death]
local C = lib("common")
local Players = game:GetService("Players")
preview.forceMeshesUploaded()
preview.startServer()
preview.advance(1)
C.startClient()
preview.advance(2)
local me = Players.LocalPlayer
local RM = preview.server("RunManager")
local function wait(t: number)
	local left = t
	while left > 0 do
		local step = math.min(left, 0.5)
		preview.advance(step)
		left -= step
		for _ = 1, 10 do
			if not me:GetAttribute("Paused") then
				break
			end
			preview.remote("LevelUpChoose"):FireServer(1)
			preview.advance(0.2)
		end
	end
end
local function dump(label: string, m: Instance?)
	if not m then
		preview.log(label, "MISSING model")
		return
	end
	local torso = m:FindFirstChild("Torso", true)
	local n = 0
	for _, d in ipairs(m:GetDescendants()) do
		if d:IsA("BasePart") and (d.Name:find("Arm") or d.Name:find("Sword") or d.Name:find("Shield")) then
			n += 1
			local rel = torso and (torso :: BasePart).CFrame:ToObjectSpace(d.CFrame) or d.CFrame
			local p = rel.Position
			preview.log(string.format("%s %-18s T=%.2f LTM=%.2f par=%s size=(%.2f,%.2f,%.2f) rel=(%.2f,%.2f,%.2f) anch=%s",
				label, d.Name, d.Transparency, d.LocalTransparencyModifier, d.Parent and d.Parent.Name or "nil",
				d.Size.X, d.Size.Y, d.Size.Z, p.X, p.Y, p.Z, tostring(d.Anchored)))
		end
	end
	preview.log(label, "arm-ish parts", n, "total parts", #m:GetDescendants())
end
local function check(label: string)
	local f = workspace:FindFirstChild("SwarmShowcase")
	dump(label .. " dais", f and f:FindFirstChild("ShowcaseHero"))
	dump(label .. " char", me.Character)
end
check("BOOT")
local path = preview.args.path or "abandon"
preview.remote("StartRun"):FireServer("Solo")
wait(1)
preview.remote("DevCommand"):FireServer("SpawnEnemy", "Slime")
wait(6)
dump("RUN char", me.Character)
if path == "death" then
	local rp = RM.GetRunPlayer and RM.GetRunPlayer(me)
	if rp then
		RM.DamagePlayer(rp, 1e6)
	end
	for _ = 1, 40 do
		if me:GetAttribute("InRun") ~= true then
			break
		end
		wait(1)
		preview.remote("ReturnToLobby"):FireServer()
	end
	preview.log("death path InRun", tostring(me:GetAttribute("InRun")))
else
	preview.remote("SetPause"):FireServer(true)
	wait(0.5)
	preview.remote("AbandonRun"):FireServer()
	preview.remote("SetPause"):FireServer(false)
end
wait(3)
check("AFTER")

for _, g in ipairs(preview.playerGui():GetChildren()) do
	if g:IsA("ScreenGui") then
		g.Enabled = false
	end
end
local folder = workspace:FindFirstChild("SwarmShowcase")
local m = folder and folder:FindFirstChild("ShowcaseHero")
if m and m:IsA("Model") and m.PrimaryPart then
	local root = (m.PrimaryPart :: BasePart).CFrame
	local look = root.Position + Vector3.new(0, 0.6, 0)
	preview.camera = { cf = CFrame.lookAt(look + root:VectorToWorldSpace(Vector3.new(0, 0, -1)) * 11 + Vector3.new(0, 1.2, 0), look), fov = 40 }
else
	preview.note("arms-sim: no ShowcaseHero")
end
