--[[
	LobbyFun.lua (client; feature 30, Config.Features.LobbyFun, docs/features/LOBBY.md)
	The COURTYARD: a small play area in the lobby world, behind the menu camera (so the title
	shot never sees it), opened from MORE. Built on this client only while you are there and
	removed when you leave, so the title screen costs nothing. Cosmetic fun only: no rewards,
	nothing saved, nothing sent to the server.

	  walking   the menu hides, your lobby hero appears at Config.LobbyFun.Spawn, the stick /
	            WASD move it (local WalkSpeed; the server keeps lobby characters at 0 and does
	            not check lobby movement) and a follow camera with the run camera's angle
	            keeps it in view. BACK (or Esc / B) puts you back by the dais and the menu returns.
	  dummy     TRAINING DUMMY: the selected hero's starting weapon at level 1 (WeaponData +
	            StatSheet with the hero's bonus): "about N damage a second", and while you
	            stand near it, a hit number every DummyHitEvery seconds.
	  mirror    COSMETICS MIRROR: a copy of your hero in its worn skin on a pedestal, with a
	            board listing what you wear (title, trail, burst, pet, plate, dais, weapon glows).
	  course    JUMP PADS: a pad throws you up, steer onto the next platform; the clock starts
	            on the first pad and stops on the top platform. The best time is kept for this
	            session only (never saved). Falling to the floor ends the try.

	LobbyFun.Enter() / .Exit() / .IsOn(), LobbyFun.DummyDPS(heroId) → (weaponName, dps),
	LobbyFun.CourseStep(state, rel, grounded, now) → event (pure; the regression drives it),
	LobbyFun.Best() → seconds?, LobbyFun.PartCount() → parts in the courtyard (no hero copy).
]]

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")

local Shared = game:GetService("ReplicatedStorage"):WaitForChild("Shared")
local Config = require(Shared:WaitForChild("Config"))
local Remotes = require(Shared:WaitForChild("Remotes"))
local Theme = require(Shared:WaitForChild("Theme"))
local CharacterData = require(Shared:WaitForChild("CharacterData"))
local WeaponData = require(Shared:WaitForChild("WeaponData"))
local CosmeticData = require(Shared:WaitForChild("CosmeticData"))
local HeroPoses = require(Shared:WaitForChild("HeroPoses"))
local UIKit = require(script.Parent.UIKit)
local Showcase = require(script.Parent.Showcase)
local MobileControls = require(script.Parent.MobileControls)
local PhotoMode = require(script.Parent.PhotoMode)

local LobbyFun = {}

local player = Players.LocalPlayer
local new, text = UIKit.new, UIKit.text
local P = Theme.Palette
local LF = Config.LobbyFun
local CO = LF.Course

local profile: { [string]: any } = {}
local best: number? = nil -- this session's best course time (never saved)

type Course = { Running: boolean, Start: number, LastLaunch: number, Last: number? }

type Session = {
	Folder: Model,
	Gui: ScreenGui,
	Status: TextLabel,
	Hidden: { ScreenGui },
	Hero: Model?,
	DummyHit: TextLabel,
	DummyNext: number,
	DummyDPS: number,
	Course: Course,
	Lift: number,
	Conns: { RBXScriptConnection },
}

local session: Session? = nil

local function origin(): Vector3
	return Config.Lobby.Origin
end

local function fmtTime(t: number): string
	return string.format("%d:%04.1f", t // 60, t % 60)
end

------------------------------------------------------------------------------------------
-- Training dummy numbers
------------------------------------------------------------------------------------------

-- The selected hero's starting weapon at level 1: its name and about how much damage a
-- second it deals to one target (hero bonus included; no upgrades, items or crits).
function LobbyFun.DummyDPS(heroId: string): (string, number)
	local hero = CharacterData.Characters[heroId] or CharacterData.Characters.Knight
	local weaponId = hero.StartWeapon
	local def = WeaponData.Weapons[weaponId]
	local row = WeaponData.GetStats(weaponId, 1, false)
	if not def or not row then
		return weaponId, 0
	end
	local might, cdMult, extra = 1, 1, 0
	local ok, sheet = pcall(function()
		return require(Shared:WaitForChild("StatSheet")).Compute({ CharacterId = hero.Id, Meta = {}, Passives = {}, Items = {} })
	end)
	if ok and type(sheet) == "table" then
		might = tonumber(sheet.Might) or 1
		cdMult = tonumber(sheet.CooldownMult) or 1
		extra = tonumber(sheet.Amount) or 0
	end
	local hits = math.max(1, (row.amount or 1) + extra)
	local cooldown = math.max(0.05, (row.cooldown or 1) * cdMult)
	return def.Name or weaponId, (row.damage or 0) * might * hits / cooldown
end

------------------------------------------------------------------------------------------
-- Course logic (pure: positions are relative to Config.Lobby.Origin)
------------------------------------------------------------------------------------------

-- Pad tops: the start pad on the floor, then every platform but the last.
local function pads(): { Vector3 }
	local out = { CO.Start }
	for i = 1, #CO.Platforms - 1 do
		table.insert(out, CO.Platforms[i].At)
	end
	return out
end

function LobbyFun.NewCourse(): Course
	return { Running = false, Start = 0, LastLaunch = -math.huge, Last = nil }
end

--[[
	One course update. rel = the hero's feet relative to the origin, grounded = standing on
	something. Returns nil or one event: "launch" (+ the pad index), "finish", "fail",
	"reset" (fell out of the world), "timeout".
]]
function LobbyFun.CourseStep(c: Course, rel: Vector3, grounded: boolean, now: number): (string?, number?)
	if rel.Y < CO.FallY then
		c.Running = false
		return "reset", nil
	end
	if c.Running and now - c.Start > CO.MaxSeconds then
		c.Running = false
		return "timeout", nil
	end
	local finish = CO.Platforms[#CO.Platforms].At
	if c.Running and grounded and Vector2.new(rel.X - finish.X, rel.Z - finish.Z).Magnitude <= CO.FinishRadius and rel.Y >= finish.Y - 1 then
		c.Running = false
		local t = now - c.Start
		c.Last = t
		if not best or t < (best :: number) then
			best = t
		end
		return "finish", nil
	end
	if grounded and now - c.LastLaunch >= CO.PadCooldown then
		for i, pad in ipairs(pads()) do
			if Vector2.new(rel.X - pad.X, rel.Z - pad.Z).Magnitude <= CO.PadRadius and math.abs(rel.Y - pad.Y) < 1.5 then
				c.LastLaunch = now
				if i == 1 then
					c.Running = true
					c.Start = now
				end
				return "launch", i
			end
		end
	end
	-- back on the courtyard floor away from the start pad: the try is over
	if c.Running and grounded and rel.Y < 1 and now - c.LastLaunch > 0.3 then
		c.Running = false
		return "fail", nil
	end
	return nil, nil
end

function LobbyFun.Best(): number?
	return best
end

------------------------------------------------------------------------------------------
-- Building (client-only parts, low count)
------------------------------------------------------------------------------------------

local function part(parent: Instance, props: { [string]: any }): BasePart
	local p = Instance.new("Part")
	p.Anchored = true
	p.CastShadow = false
	p.TopSurface = Enum.SurfaceType.Smooth
	p.BottomSurface = Enum.SurfaceType.Smooth
	p.Material = Enum.Material.SmoothPlastic
	for k, v in pairs(props) do
		(p :: any)[k] = v
	end
	p.Parent = parent
	return p
end

local function billboard(adornee: BasePart, height: number, w: number, h: number): BillboardGui
	local bb = Instance.new("BillboardGui")
	bb.Name = "Label"
	bb.Size = UDim2.fromOffset(w, h)
	bb.StudsOffset = Vector3.new(0, height, 0)
	bb.AlwaysOnTop = false
	bb.MaxDistance = 80
	bb.LightInfluence = 0
	bb.Adornee = adornee
	bb.Parent = adornee
	return bb
end

local function worn(kind: string): string
	local f = profile.Features
	local eq = type(f) == "table" and type(f.Cosmetics) == "table" and f.Cosmetics.Equipped
	local id = type(eq) == "table" and eq[kind]
	if type(id) ~= "string" or id == "" then
		return "None"
	end
	local e = CosmeticData.Get(id)
	return e and e.Name or id
end

local function mirrorLines(): string
	local heroId = profile.SelectedCharacter or "Knight"
	local hero = CharacterData.Characters[heroId]
	local skinId = type(profile.Skins) == "table" and profile.Skins[heroId] or "Default"
	local skin = CharacterData.Skins[skinId]
	local lines = {
		string.format("Hero: %s%s", hero and hero.Name or heroId, skin and (" · " .. skin.Name) or ""),
		"Title: " .. (type(profile.Title) == "string" and profile.Title ~= "" and profile.Title or "None"),
	}
	for _, kind in ipairs({ "Trail", "Burst", "Pet", "Nameplate", "Dais" }) do
		table.insert(lines, kind .. ": " .. worn(kind))
	end
	-- weapon glows (feature 15): how many weapons wear one
	local f = profile.Features
	local wm = type(f) == "table" and f.WeaponMastery
	local glows = 0
	if type(wm) == "table" then
		for k in pairs(wm) do
			if type(k) == "string" and string.sub(k, 1, 5) == "Glow:" then
				glows += 1
			end
		end
	end
	table.insert(lines, "Weapon glows: " .. (glows > 0 and tostring(glows) or "None"))
	return table.concat(lines, "\n")
end

local function build(s: Session)
	local o = origin()
	local f = s.Folder
	local fl = LF.Floor
	part(f, { Name = "Floor", Size = fl.Size, CFrame = CFrame.new(o + fl.Centre - Vector3.new(0, fl.Size.Y / 2, 0)), Color = P.stone_400, Material = Enum.Material.Slate, CanCollide = true })
	-- lanterns: the courtyard is behind the castle's lit side, so it gets its own warm light
	for i, at in ipairs(LF.Lanterns) do
		part(f, { Name = "LanternPost" .. i, Size = Vector3.new(0.5, 6, 0.5), CFrame = CFrame.new(o + at + Vector3.new(0, 3, 0)), Color = P.stone_500 })
		local head = part(f, { Name = "Lantern" .. i, Shape = Enum.PartType.Ball, Size = Vector3.new(1.4, 1.4, 1.4), CFrame = CFrame.new(o + at + Vector3.new(0, 6.6, 0)), Color = Color3.fromRGB(255, 200, 110), Material = Enum.Material.Neon })
		local light = Instance.new("PointLight")
		light.Color = Color3.fromRGB(255, 196, 120)
		light.Range = 36
		light.Brightness = 2.2
		light.Shadows = false
		light.Parent = head
	end
	-- training dummy (faces the camera, +Z): base, post, body, head, a target ring
	local d = o + LF.Dummy
	part(f, { Name = "DummyBase", Shape = Enum.PartType.Cylinder, Size = Vector3.new(0.6, 4, 4), CFrame = CFrame.new(d + Vector3.new(0, 0.3, 0)) * CFrame.Angles(0, 0, math.rad(90)), Color = P.stone_500, CanCollide = true })
	part(f, { Name = "DummyPost", Size = Vector3.new(0.6, 5, 0.6), CFrame = CFrame.new(d + Vector3.new(0, 2.5, 0)), Color = P.wood_500, Material = Enum.Material.Wood })
	local body = part(f, { Name = "DummyBody", Size = Vector3.new(2.4, 2.6, 1.4), CFrame = CFrame.new(d + Vector3.new(0, 3.6, 0)), Color = P.wood_400, Material = Enum.Material.Fabric, CanCollide = true })
	part(f, { Name = "DummyHead", Shape = Enum.PartType.Ball, Size = Vector3.new(1.6, 1.6, 1.6), CFrame = CFrame.new(d + Vector3.new(0, 5.6, 0)), Color = P.wood_400:Lerp(P.ivory_200, 0.35), Material = Enum.Material.Fabric })
	part(f, { Name = "DummyTarget", Shape = Enum.PartType.Cylinder, Size = Vector3.new(0.1, 1.4, 1.4), CFrame = CFrame.new(d + Vector3.new(0, 3.7, 0.72)) * CFrame.Angles(0, math.rad(90), 0), Color = P.crimson_500 })
	local heroId = profile.SelectedCharacter or "Knight"
	local weaponName, dps = LobbyFun.DummyDPS(heroId)
	s.DummyDPS = dps
	local bb = billboard(body, 4.6, 230, 74)
	text(bb, "Label", "TRAINING DUMMY", { Name = "Title", Size = UDim2.new(1, 0, 0, 22), TextXAlignment = Enum.TextXAlignment.Center, TextColor3 = P.gold_200, TextStrokeTransparency = 0.3 }, 16)
	text(bb, "Small", string.format("%s · level 1", weaponName), { Name = "Weapon", Position = UDim2.fromOffset(0, 22), Size = UDim2.new(1, 0, 0, 18), TextXAlignment = Enum.TextXAlignment.Center, TextColor3 = P.ivory_100, TextStrokeTransparency = 0.3 }, 13)
	text(bb, "Label", string.format("about %s damage a second", UIKit.formatNumber(dps)), { Name = "DPS", Position = UDim2.fromOffset(0, 42), Size = UDim2.new(1, 0, 0, 22), TextXAlignment = Enum.TextXAlignment.Center, TextColor3 = P.ivory_100, TextStrokeTransparency = 0.3 }, 15)
	local hitBB = billboard(body, 2.2, 120, 30)
	hitBB.Name = "Hit"
	s.DummyHit = text(hitBB, "Label", "", { Name = "Number", Size = UDim2.fromScale(1, 1), TextXAlignment = Enum.TextXAlignment.Center, TextColor3 = P.gold_300, TextStrokeTransparency = 0.2 }, 20)
	-- cosmetics mirror: pedestal, frame, glass, a board
	local m = o + LF.Mirror
	part(f, { Name = "MirrorPedestal", Shape = Enum.PartType.Cylinder, Size = Vector3.new(0.8, 5, 5), CFrame = CFrame.new(m + Vector3.new(0, 0.4, 0)) * CFrame.Angles(0, 0, math.rad(90)), Color = P.stone_300, Material = Enum.Material.Marble, CanCollide = true })
	part(f, { Name = "MirrorFrame", Size = Vector3.new(6.4, 8.4, 0.5), CFrame = CFrame.new(m + Vector3.new(0, 4.2, -3.4)), Color = P.gold_500, Material = Enum.Material.Metal, CanCollide = true })
	part(f, { Name = "MirrorGlass", Size = Vector3.new(5.6, 7.6, 0.1), CFrame = CFrame.new(m + Vector3.new(0, 4.2, -3.1)), Color = P.ice_100, Material = Enum.Material.Glass, Reflectance = 0.6, Transparency = 0.15 })
	-- the board stands beside the mirror, tilted back so the camera reads it (its +Z face)
	local board = part(f, { Name = "MirrorBoard", Size = Vector3.new(5.6, 4, 0.3), CFrame = CFrame.new(m + Vector3.new(-7, 2.4, 0)) * CFrame.Angles(math.rad(-35), 0, 0), Color = P.slate_700, CanCollide = true })
	local sg = Instance.new("SurfaceGui")
	sg.Name = "Worn"
	sg.Face = Enum.NormalId.Back
	sg.SizingMode = Enum.SurfaceGuiSizingMode.PixelsPerStud
	sg.PixelsPerStud = 50
	sg.LightInfluence = 0
	sg.Parent = board
	text(sg, "Label", "COSMETICS MIRROR", { Name = "Title", Position = UDim2.fromOffset(10, 6), Size = UDim2.new(1, -20, 0, 26), TextColor3 = P.gold_200 }, 22)
	text(sg, "Small", mirrorLines(), { Name = "Lines", Position = UDim2.fromOffset(10, 36), Size = UDim2.new(1, -20, 1, -42), TextYAlignment = Enum.TextYAlignment.Top, TextColor3 = P.ivory_100, TextWrapped = true }, 17)
	local skinId = type(profile.Skins) == "table" and profile.Skins[heroId] or "Default"
	local hero = PhotoMode.CloneHero(heroId, skinId)
	if hero then
		hero.Name = "MirrorHero"
		local root = hero.PrimaryPart :: BasePart
		local bbCF, bbSize = hero:GetBoundingBox()
		local lift = math.clamp(root.Position.Y - (bbCF.Position.Y - bbSize.Y / 2), 2.4, 4.2)
		-- faces the camera (+Z) with the mirror behind it
		hero:PivotTo(CFrame.lookAt(m + Vector3.new(0, 0.8 + lift, 0), m + Vector3.new(0, 0.8 + lift, 10)))
		hero.Parent = f
		HeroPoses.Apply(hero, "Showcase", 0)
		s.Hero = hero
	end
	-- jump-pad course: pads (neon discs) and platforms (stone), a flag on the last
	for i, pad in ipairs(pads()) do
		part(f, { Name = "Pad" .. i, Shape = Enum.PartType.Cylinder, Size = Vector3.new(0.3, CO.PadRadius * 2, CO.PadRadius * 2), CFrame = CFrame.new(o + pad + Vector3.new(0, 0.12, 0)) * CFrame.Angles(0, 0, math.rad(90)), Color = P.gold_300, Material = Enum.Material.Neon })
	end
	for i, pl in ipairs(CO.Platforms) do
		part(f, { Name = "Platform" .. i, Size = pl.Size, CFrame = CFrame.new(o + pl.At - Vector3.new(0, pl.Size.Y / 2, 0)), Color = i == #CO.Platforms and P.gold_500 or P.stone_300, Material = Enum.Material.Slate, CanCollide = true })
	end
	local fin = o + CO.Platforms[#CO.Platforms].At
	part(f, { Name = "FlagPole", Size = Vector3.new(0.3, 5, 0.3), CFrame = CFrame.new(fin + Vector3.new(2.8, 2.5, 2.8)), Color = P.wood_500 })
	part(f, { Name = "Flag", Size = Vector3.new(0.1, 1.6, 2.4), CFrame = CFrame.new(fin + Vector3.new(2.8, 4.1, 1.6)), Color = P.crimson_500, Material = Enum.Material.Fabric })
	local startBB = billboard(part(f, { Name = "StartSign", Size = Vector3.new(0.2, 0.2, 0.2), CFrame = CFrame.new(o + CO.Start + Vector3.new(0, 3.5, 0)), Transparency = 1, CanCollide = false }), 0, 200, 40)
	text(startBB, "Label", "JUMP PADS · step on to start", { Size = UDim2.fromScale(1, 1), TextXAlignment = Enum.TextXAlignment.Center, TextColor3 = P.gold_200, TextStrokeTransparency = 0.3 }, 14)
end

function LobbyFun.PartCount(): number
	local s = session
	if not s then
		return 0
	end
	local n = 0
	for _, d in ipairs(s.Folder:GetDescendants()) do
		if d:IsA("BasePart") and not (s.Hero and d:IsDescendantOf(s.Hero)) then
			n += 1
		end
	end
	return n
end

------------------------------------------------------------------------------------------
-- Session
------------------------------------------------------------------------------------------

local function statusText(c: Course, now: number): string
	if c.Running then
		return "COURSE  " .. fmtTime(now - c.Start) .. (best and ("   ·   BEST  " .. fmtTime(best :: number)) or "")
	end
	if best then
		return "BEST  " .. fmtTime(best :: number) .. (c.Last and ("   ·   LAST  " .. fmtTime(c.Last :: number)) or "")
	end
	return "Walk to the gold pad to start the course"
end

local function step(dt: number)
	local s = session
	if not s then
		return
	end
	MobileControls.SetEnabled(true) -- the lobby menu blocks the stick; here you walk
	local char = player.Character
	local root = char and char:FindFirstChild("HumanoidRootPart") :: BasePart?
	local hum = char and char:FindFirstChildOfClass("Humanoid")
	local now = os.clock()
	if root and hum then
		if hum.WalkSpeed ~= LF.WalkSpeed then
			hum.WalkSpeed = LF.WalkSpeed
		end
		local feet = root.Position - Vector3.new(0, s.Lift, 0)
		local rel = feet - origin()
		local grounded = hum.FloorMaterial ~= Enum.Material.Air
		local event, pad = LobbyFun.CourseStep(s.Course, rel, grounded, now)
		if event == "launch" then
			local v = root.AssemblyLinearVelocity
			root.AssemblyLinearVelocity = Vector3.new(v.X, CO.LaunchSpeed, v.Z)
			pcall(function()
				hum:ChangeState(Enum.HumanoidStateType.Freefall)
			end)
			if pad == 1 then
				s.Status.TextColor3 = P.ivory_100
			end
		elseif event == "finish" then
			s.Status.TextColor3 = P.gold_200
		elseif event == "reset" then
			root.CFrame = CFrame.new(origin() + LF.Spawn)
			root.AssemblyLinearVelocity = Vector3.zero
		end
		-- dummy hit numbers while you stand near it
		local d = origin() + LF.Dummy
		if (Vector3.new(root.Position.X, 0, root.Position.Z) - Vector3.new(d.X, 0, d.Z)).Magnitude < 14 then
			if now >= s.DummyNext then
				s.DummyNext = now + LF.DummyHitEvery
				s.DummyHit.Text = UIKit.formatNumber(s.DummyDPS * LF.DummyHitEvery)
				s.DummyHit.TextTransparency = 0
			else
				s.DummyHit.TextTransparency = math.clamp((now - (s.DummyNext - LF.DummyHitEvery)) / LF.DummyHitEvery, 0, 1)
			end
		else
			s.DummyHit.Text = ""
		end
		-- follow camera (the run camera's angle, so the stick directions match)
		local cam = workspace.CurrentCamera
		local pitch, yaw = math.rad(Config.Camera.Pitch), math.rad(Config.Camera.Yaw)
		local dist = LF.CameraDistance * (cam.ViewportSize.Y > cam.ViewportSize.X and Config.Camera.PortraitDistanceMult or 1)
		local offset = Vector3.new(math.sin(yaw) * math.cos(pitch), math.sin(pitch), math.cos(yaw) * math.cos(pitch)) * dist
		cam.FieldOfView = Config.Camera.FieldOfView
		cam.CFrame = CFrame.lookAt(root.Position + offset, root.Position)
		cam.Focus = CFrame.new(root.Position)
	end
	s.Status.Text = statusText(s.Course, now)
end

function LobbyFun.IsOn(): boolean
	return session ~= nil
end

function LobbyFun.Enter()
	if session or not Config.FeatureOn("LobbyFun") or player:GetAttribute("InRun") == true then
		return
	end
	local folder = Instance.new("Model")
	folder.Name = "LobbyFun"
	local playerGui = player:WaitForChild("PlayerGui")
	local g = new("ScreenGui", { Name = "LobbyFunUI", ResetOnSpawn = false, IgnoreGuiInset = true, ScreenInsets = Enum.ScreenInsets.DeviceSafeInsets, DisplayOrder = 12, Enabled = true }) :: ScreenGui
	local s: Session = {
		Folder = folder,
		Gui = g,
		Status = nil :: any,
		Hidden = {},
		Hero = nil,
		DummyHit = nil :: any,
		DummyNext = 0,
		DummyDPS = 0,
		Course = LobbyFun.NewCourse(),
		Lift = 3,
		Conns = {},
	}
	session = s
	-- hide the menu (every other GUI but the thumbstick) and the dais hero
	for _, other in ipairs(playerGui:GetChildren()) do
		if other:IsA("ScreenGui") and other.Enabled and other.Name ~= "SwarmStick" then
			other.Enabled = false
			table.insert(s.Hidden, other)
		end
	end
	Showcase.SetVisible(false)
	build(s)
	folder.Parent = workspace
	-- the courtyard UI: BACK and the course clock
	UIKit.Button(g, { Kind = "Secondary", Title = "BACK", Icon = "chevronLeft", IconSize = 18, Name = "Back", Align = "Center", Size = UDim2.fromOffset(120, 48), Position = UDim2.fromOffset(16, 66), OnClick = function()
		LobbyFun.Exit()
	end })
	local pill = new("Frame", { Name = "Clock", AnchorPoint = Vector2.new(0.5, 0), Position = UDim2.new(0.5, 0, 0, 16), Size = UDim2.new(1, -300, 0, 40), BackgroundColor3 = P.slate_900, BackgroundTransparency = 0.25, BorderSizePixel = 0 }, g)
	UIKit.corner(pill, 20)
	local cons = Instance.new("UISizeConstraint")
	cons.MinSize = Vector2.new(150, 40)
	cons.MaxSize = Vector2.new(460, 40)
	cons.Parent = pill
	s.Status = text(pill, "Label", "", { Name = "Status", Position = UDim2.fromOffset(10, 0), Size = UDim2.new(1, -20, 1, 0), TextXAlignment = Enum.TextXAlignment.Center, TextColor3 = P.ivory_100, TextTruncate = Enum.TextTruncate.AtEnd }, 15)
	g.Parent = playerGui
	-- your hero walks in at the courtyard spawn
	local char = player.Character
	if char then
		-- root height above the feet (as Showcase measures it), for the pad / finish checks
		local root = char:FindFirstChild("HumanoidRootPart")
		if root and root:IsA("BasePart") then
			local bbCF, bbSize = char:GetBoundingBox()
			s.Lift = math.clamp(root.Position.Y - (bbCF.Position.Y - bbSize.Y / 2), 1.5, 5)
		end
		char:PivotTo(CFrame.new(origin() + LF.Spawn) * CFrame.Angles(0, math.rad(180), 0))
	end
	RunService:BindToRenderStep("SwarmLobbyFun", Enum.RenderPriority.Camera.Value + 4, step)
	table.insert(s.Conns, player:GetAttributeChangedSignal("InRun"):Connect(function()
		if player:GetAttribute("InRun") == true then
			LobbyFun.Exit(true)
		end
	end))
	table.insert(s.Conns, UserInputService.InputBegan:Connect(function(input)
		if input.KeyCode == Enum.KeyCode.Escape or input.KeyCode == Enum.KeyCode.ButtonB then
			LobbyFun.Exit()
		end
	end))
	step(0)
end

-- Leave the courtyard. toRun = a run started (the server moves the character itself).
function LobbyFun.Exit(toRun: boolean?)
	local s = session
	if not s then
		return
	end
	session = nil
	pcall(function()
		RunService:UnbindFromRenderStep("SwarmLobbyFun")
	end)
	for _, c in ipairs(s.Conns) do
		c:Disconnect()
	end
	s.Folder:Destroy()
	s.Gui:Destroy()
	local char = player.Character
	local hum = char and char:FindFirstChildOfClass("Humanoid")
	if not toRun then
		if hum then
			hum.WalkSpeed = 0
		end
		local spawn = Remotes.State():GetAttribute("LobbySpawn")
		if char and typeof(spawn) == "CFrame" then
			char:PivotTo(spawn)
		end
		pcall(MobileControls.SetEnabled, false) -- the lobby menu is back: no thumbstick
	end
	for _, other in ipairs(s.Hidden) do
		if other.Parent then
			other.Enabled = true
		end
	end
	if not toRun then
		Showcase.SetVisible(true)
	end
end

function LobbyFun.Init()
	Remotes.Get("ProfileSync").OnClientEvent:Connect(function(p)
		if type(p) == "table" then
			profile = p
		end
	end)
end

-- (tests) feed a profile directly
function LobbyFun._SetProfile(p: { [string]: any })
	profile = p
end

return LobbyFun
