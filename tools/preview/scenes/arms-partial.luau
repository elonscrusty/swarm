-- arms-partial: the lobby dais hero (Showcase) copying the player's own character while it
-- is still arriving (right after a run the new lobby character replicates in the same
-- moment the menu shows). The own Knight is shown with pieces held back, the menu shows,
-- then the pieces arrive; prints the dais hero's arm parts before / after and renders the
-- dais. --set drop=joints (the shoulder Motor6Ds late, default) | arms (the arm parts and
-- their gear late) | none
local C = lib("common")
local Players = game:GetService("Players")
C.lobby({ character = "Knight" })
C.startClient()
C.sendProfile(C.profile({ SelectedCharacter = "Knight" }))
C.settle(2)
local Showcase = preview.client("Showcase")
local me = Players.LocalPlayer
local char = me.Character :: Model

local function dump(label: string)
	local f = workspace:FindFirstChild("SwarmShowcase")
	local m = f and f:FindFirstChild("ShowcaseHero")
	if not m then
		preview.log(label, "no dais hero")
		return
	end
	local torso = m:FindFirstChild("Torso") :: BasePart
	local n = 0
	for _, d in ipairs(m:GetDescendants()) do
		if d:IsA("BasePart") and (d.Name == "Left Arm" or d.Name == "Right Arm" or d.Name == "SwordBlade" or d.Name == "Shield") then
			n += 1
			local p = torso.CFrame:ToObjectSpace(d.CFrame).Position
			preview.log(string.format("%s %-11s rel=(%.2f,%.2f,%.2f)", label, d.Name, p.X, p.Y, p.Z))
		end
	end
	preview.log(label, "arm/gear parts", n)
end

-- the menu goes away (a run), the character is replaced by one still arriving
Showcase.SetVisible(false)
local held: { { Instance } } = {}
local drop = preview.args.drop or "joints"
for _, d in ipairs(char:GetDescendants()) do
	local late = false
	if drop == "joints" then
		late = d:IsA("Motor6D") and (d.Name == "Left Shoulder" or d.Name == "Right Shoulder")
	elseif drop == "arms" then
		late = d:IsA("BasePart") and (d.Name:find("Arm") ~= nil or d.Name:find("Sword") ~= nil or d.Name:find("Shield") ~= nil)
	end
	if late then
		table.insert(held, { d, d.Parent :: Instance })
	end
end
for _, h in ipairs(held) do
	h[1].Parent = nil
end
preview.log("held back", #held)
Showcase.SetVisible(true)
preview.advance(1)
dump("PARTIAL")
for _, h in ipairs(held) do
	h[1].Parent = h[2]
end
preview.advance(1.5)
dump("ARRIVED")

for _, g in ipairs(preview.playerGui():GetChildren()) do
	if g:IsA("ScreenGui") then
		g.Enabled = false
	end
end
local f = workspace:FindFirstChild("SwarmShowcase")
local m = f and f:FindFirstChild("ShowcaseHero")
if m and m:IsA("Model") and m.PrimaryPart then
	local root = (m.PrimaryPart :: BasePart).CFrame
	local look = root.Position + Vector3.new(0, 0.6, 0)
	preview.camera = { cf = CFrame.lookAt(look + root:VectorToWorldSpace(Vector3.new(0, 0, -1)) * 11 + Vector3.new(0, 1.2, 0), look), fov = 40 }
end
