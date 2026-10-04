-- Exercise real client settings, sound routing, warning visibility, and touch presets.
local A, C, E = lib("arena"), lib("common"), lib("encounter")
local s = A.build({ swarm = false })
local Settings = preview.client("ClientSettings")
local Audio = preview.client("Audio")
local Access = preview.client("Accessibility")
local Telegraphs = preview.client("Telegraphs")
local Mobile = preview.client("MobileControls")
local MiniMap = preview.client("MiniMap")
local Config = C.shared("Config")
local sounds = game:GetService("SoundService")
if preview.args.headless == "on" then
	Audio.Init()
	Telegraphs.Init()
	Access.Init()
end
Settings.Apply({ Colorblind = "Deuteranopia", ReduceFlashes = true, VisualAudioCues = true,
	Music = 0.7, Sfx = 0.8, CombatVolume = 0.2, InterfaceVolume = 0.4, WarningVolume = 0.9 })
Settings.Set("Colorblind", "invalid")
Settings.Set("CombatVolume", 0 / 0)
assert(Settings.Get("Colorblind") == "Deuteranopia" and Settings.Get("CombatVolume") == 0.2, "invalid settings must be ignored")
assert(Settings.Flashes() and not Settings.Reduced(), "flash reduction must be independent of reduced effects")
if preview.args.headless ~= "on" then
	local UIAnim, Hud, CombatFx = preview.client("UIAnim"), preview.client("Hud"), preview.client("CombatFx")
	local frame = Instance.new("Frame")
	UIAnim.Flash(frame)
	assert(not frame:FindFirstChild("Flash"), "UI flash must respect separate flash reduction")
	frame:Destroy()
	Hud.Hurt()
	assert(Hud.Elements().VignetteLevel.Value == 1, "hurt edge flash must be suppressed")
	CombatFx.BossPhase()
	local edge = game:GetService("Players").LocalPlayer.PlayerGui:FindFirstChild("SwarmEdgeFlash", true)
	assert(not edge or not edge.Enabled, "boss phase edge flash must be suppressed")
	local p = game:GetService("Players").LocalPlayer
	local gradient = Hud.Elements().XP.Fill:FindFirstChildOfClass("UIGradient")
	local normal = gradient.Color.Keypoints[1].Value
	p:SetAttribute("Level", (p:GetAttribute("Level") or 1) + 1)
	Hud.Update(1 / 60, C.state(), false)
	assert(gradient.Color.Keypoints[1].Value == normal, "XP must retain its normal colour")
end
assert(Access.Color(Color3.new(1, 0, 0), "Danger") ~= Access.Color(Color3.new(0, 1, 0), "Heal"), "danger and healing must remain distinct")
local dark = Color3.fromRGB(15, 19, 24)
assert(Access.Color(dark) == dark, "dark outlines must stay dark")
assert(sounds:FindFirstChild("SwarmCombat", true).Volume == 0.2, "combat channel setting")
assert(sounds:FindFirstChild("SwarmInterface", true).Volume == 0.4, "interface channel setting")
assert(sounds:FindFirstChild("SwarmWarning", true).Volume == 0.9, "warning channel setting")
Settings.Set("MuteAll", true)
assert(sounds.SwarmMusic.Volume == 0 and sounds.SwarmSFX.Volume == 0, "mute must silence both masters")
Audio.PlayAt("FuseTick", s.centre)
local cue = game:GetService("Players").LocalPlayer.PlayerGui:FindFirstChild("SwarmSoundCues")
assert(cue and cue.Cue.Visible and string.find(cue.Cue.Text, "BOMB FUSE"), "muted warnings must retain optional visual audio cues")
Settings.Set("MuteAll", false)
assert(sounds.SwarmMusic.Volume == 0.7 and sounds.SwarmSFX.Volume == 0.8, "unmute must restore saved master volumes")
Settings.Set("TouchLayout", "RightHanded")
assert(Mobile.MovementSide(50, 1000) and not Mobile.MovementSide(950, 1000), "right handed movement stays on left")
Settings.Set("TouchLayout", "LeftHanded")
assert(Mobile.MovementSide(950, 1000) and not Mobile.MovementSide(50, 1000), "left handed movement moves right")
Settings.Set("TouchLayout", "Compact")
assert(Mobile.MovementSide(50, 1000), "compact preserves familiar movement side")
assert(Config.Settings.Defaults.AimMode == nil, "automatic targeting must remain the only aim mode")
E.warn({ { "circle", s.centre.X, s.centre.Z, 5, 3, "blast" }, { "mine", s.centre.X + 8, s.centre.Z, 4, 3 } })
preview.advance(0.6)
assert(Telegraphs.Count() == 2, "flash reduction must preserve attack warnings")
if preview.args.headless ~= "on" then
	local map = MiniMap.Elements()
	assert(map.Enemies[1].Rotation == 45, "colourblind enemy markers use a distinct diamond shape")
	assert(map.Mates[1].Rotation == 0, "ally marker stays distinct")
end
local player = game:GetService("Players").LocalPlayer
player:SetAttribute("InRun", false)
preview.advance(0.6)
local arena = workspace.SwarmMap:FindFirstChildWhichIsA("Model")
for _, model in ipairs(workspace.SwarmMap:GetChildren()) do
	if string.sub(model.Name, 1, 6) == "Arena_" then arena = model; break end
end
for i = 1, 17 do
	local hazard = Instance.new("Model")
	hazard.Name = "TestHazard"
	hazard:SetAttribute("HazardKind", "Acid")
	hazard:SetAttribute("HazardRadius", 3)
	hazard:PivotTo(CFrame.new(s.centre + Vector3.new(i * 4, 0, 30)))
	hazard.Parent = arena
end
player:SetAttribute("InRun", true)
preview.advance(0.6)
local marks = workspace:FindFirstChild("SwarmHazardOutlines")
assert(marks and #marks:GetChildren() == 16 * 12, "ground danger outlines must obey their fixed cap")
for _, part in ipairs(marks:GetChildren()) do
	assert(not part.CanCollide and not part.CanTouch and not part.CanQuery, "outlines must never change gameplay collision")
end
Settings.Set("VisualAudioCues", false)
assert(not cue.Cue.Visible, "disabling visual cues must hide the current cue")
game:GetService("Players").LocalPlayer:SetAttribute("InRun", false)
preview.advance(0.6)
local outlines = workspace:FindFirstChild("SwarmHazardOutlines")
assert(not outlines, "hazard outlines must clean up when leaving a run")
preview.log("PASS accessibility settings, channel/mute routing, visual warnings, marker shapes, touch sides and run cleanup")
game:GetService("Players").LocalPlayer:SetAttribute("InRun", true)
Settings.Set("VisualAudioCues", true)
if preview.args.headless ~= "on" then
	preview.client("UIBuilder").OpenRunSettings()
	local gui = game:GetService("Players").LocalPlayer.PlayerGui
	-- the run settings' option list (the lobby PLAY sheet has its own "Options" list)
	local options
	for _, item in ipairs(gui:GetDescendants()) do
		if item.Name == "Options" and item:IsA("ScrollingFrame") then
			local shown, node = true, item
			while node and node ~= gui do
				if node:IsA("GuiObject") and not node.Visible then shown = false end
				if node:IsA("ScreenGui") and not node.Enabled then shown = false end
				node = node.Parent
			end
			if shown then options = item; break end
		end
	end
	assert(options and options.CanvasSize.Y.Offset >= options.Size.Y.Offset, "settings must fit the viewport or remain reachable by scrolling")
	if preview.args.view == "bottom" then options.CanvasPosition = Vector2.new(0, options.CanvasSize.Y.Offset) end
end
preview.advance(0.3)
