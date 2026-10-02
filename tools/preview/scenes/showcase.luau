-- showcase: close-up of the lobby dais hero (Showcase.lua + HeroPoses "Showcase"), no GUI.
--   --set hero=Ranger            which hero (default Knight; every hero is owned)
--   --set view=front|side|back|three   camera angle (default front: the menu camera's side)
--   --set meshes=none            the part-built fallbacks (before the meshes have loaded)
local C = lib("common")
local hero = preview.args.hero or "Knight"
C.lobby({ character = hero })
C.startClient()
C.sendProfile(C.profile({
	OwnedCharacters = { Knight = true, Mage = true, Rogue = true, Priest = true, Ranger = true, Alchemist = true, Engineer = true, Necromancer = true },
	SelectedCharacter = hero,
	Skins = { [hero] = "Default" },
}))
C.settle(3)

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
	local dirs = {
		front = Vector3.new(0, 0, -1),
		side = Vector3.new(1, 0, 0),
		back = Vector3.new(0, 0, 1),
		three = Vector3.new(0.7, 0, -0.7),
	}
	local d = dirs[preview.args.view or "front"] or dirs.front
	-- the root faces the camera already (rotated by the showcase); -Z is the hero's front
	local world = root:VectorToWorldSpace(d)
	preview.camera = { cf = CFrame.lookAt(look + world * 11 + Vector3.new(0, 1.2, 0), look), fov = 40 }
else
	preview.note("showcase scene: no ShowcaseHero")
end
