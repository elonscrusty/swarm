-- showcase: close-up of the lobby dais hero (Showcase.lua + HeroPoses "Showcase"), no GUI.
--   --set hero=Ranger            which hero (default Knight; every hero is owned)
--   --set view=front|side|back|three   camera angle (default front: the menu camera's side)
--   --set skin=Knight_Crimson    wear that skin (a real CharacterData skin id; owned for the preview)
--   --set bg=slate               hero alone on a flat dark-slate background (store pictures, tools/make_skin_pass_images.py);
--                                 --set bgcolor=r,g,b picks that background colour
--   --set meshes=none            the part-built fallbacks (before the meshes have loaded)
local C = lib("common")
local skinArg = preview.args.skin
local hero = preview.args.hero or (skinArg and skinArg:match("^(%a+)_")) or "Knight"
local skin = skinArg or "Default"
C.lobby({ character = hero })
C.startClient()
C.sendProfile(C.profile({
	OwnedCharacters = { Knight = true, Mage = true, Rogue = true, Priest = true, Ranger = true, Alchemist = true, Engineer = true, Necromancer = true },
	SelectedCharacter = hero,
	Skins = { [hero] = skin },
	OwnedSkins = { Default = true, [skin] = true },
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
	if preview.args.bg == "slate" then
		-- everything but the hero goes; a warm gold light behind-right acts as the rim light
		for _, d in ipairs(workspace:GetDescendants()) do
			if d:IsA("BasePart") and not d:IsDescendantOf(folder :: Instance) and not d:IsDescendantOf(preview.playerGui()) then
				d.Transparency = 1
			end
		end
		game:GetService("Lighting").ClockTime = 14
		for _, d in ipairs(folder:GetDescendants()) do
			if d:IsA("ParticleEmitter") then
				d.Enabled = false
			end
		end
		local r, g, b = string.match(preview.args.bgcolor or "", "^(%d+),(%d+),(%d+)$")
		preview.render.background = r and Color3.fromRGB(tonumber(r) :: number, tonumber(g) :: number, tonumber(b) :: number) or Color3.fromRGB(30, 34, 42)
		preview.render.hideCoreUi = true
		local rim = Instance.new("Part")
		rim.Name = "RimLight"
		rim.Anchored = true
		rim.CanCollide = false
		rim.Transparency = 1
		rim.Size = Vector3.new(1, 1, 1)
		rim.CFrame = CFrame.new(look + root:VectorToWorldSpace(Vector3.new(4, 3, 5)))
		local pl = Instance.new("PointLight")
		pl.Color = Color3.fromRGB(255, 205, 120)
		pl.Brightness = 3
		pl.Range = 24
		pl.Parent = rim
		rim.Parent = folder
	end
	preview.camera = { cf = CFrame.lookAt(look + world * (preview.args.bg == "slate" and 16 or 11) + Vector3.new(0, 1.2, 0), look), fov = 40 }
else
	preview.note("showcase scene: no ShowcaseHero")
end
