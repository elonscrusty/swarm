--[[
	StoreFx.lua (Config.Features.Store; docs/features/STORE.md)
	Draws the cosmetic store's looks on this client, for every player, from the attributes
	StoreService publishes (StoreCatalog.Attr: CosTrail / CosBurst / CosPet / CosEmote /
	CosPlate / CosDais, Supporter, CosEmoteAt). Looks only: every part here is anchored,
	client-side, CanCollide / CanQuery / CanTouch off, so nothing can touch the game.

	  Pets       a small part-built follower (2-6 parts) beside each hero, in the lobby
	             and in runs; the local hero's pet stands beside the menu dais while the
	             menu shows. At most Config.Store.MaxPets, nearest first, within PetRange.
	             No stats and no pickup help: it never moves anything but itself.
	  Trails     a Roblox Trail on the hero's root (two client attachments).
	  Nameplate  a small framed name over the hero (worn frame, Supporter glow + badge).
	             StoreFx.DecoratePlate(frame, player) styles another module's plate (META
	             titles can call it instead of drawing a second plate).
	  Emote      the worn emote's icon pops over the hero for EmoteSeconds (StoreEmote).
	  Dais       the worn dais theme under the menu hero (Showcase.Stand), plus the
	             Supporter banner beside it.
	  Burst      the worn death burst styles HitFeel's bursts on THIS screen (HitFeel.SetStyle).
	With the switch off, Init does nothing.
]]

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")

local Shared = game:GetService("ReplicatedStorage"):WaitForChild("Shared")
local Config = require(Shared:WaitForChild("Config"))
local Remotes = require(Shared:WaitForChild("Remotes"))
local StoreCatalog = require(Shared:WaitForChild("StoreCatalog"))
local UIKit = require(script.Parent.UIKit)
local UIAnim = require(script.Parent.UIAnim)
local Icons = require(script.Parent.Icons)
local Showcase = require(script.Parent.Showcase)
local HitFeel = require(script.Parent.HitFeel)

local StoreFx = {}

local player = Players.LocalPlayer
local S = (Config :: any).Store or {}
local new = UIKit.new

local folder: Folder? = nil
local plateGui: Folder? = nil

type Rig = {
	Char: Model?,
	Root: BasePart?,
	Drop: number, -- root height above the feet
	HideProbe: BasePart?,
	PetId: string,
	Pet: Model?,
	PetPos: Vector3?,
	TrailId: string,
	Trail: Trail?,
	Att: { Attachment },
	PlateKey: string,
	Plate: BillboardGui?,
	PlateAnchor: BasePart?,
	EmoteAt: number,
	Emote: BillboardGui?,
}
local rigs: { [Player]: Rig } = {}

local function on(): boolean
	return Config.FeatureOn("Store")
end

local function look(id: any): any
	local e = type(id) == "string" and id ~= "" and StoreCatalog.Get(id) or nil
	return e and e.Look or nil
end

local function part(parent: Instance, shape: Enum.PartType?, size: Vector3, color: Color3, material: Enum.Material?): Part
	local p = Instance.new("Part")
	p.Shape = shape or Enum.PartType.Block
	p.Size = size
	p.Color = color
	p.Material = material or Enum.Material.SmoothPlastic
	p.Anchored = true
	p.CanCollide = false
	p.CanQuery = false
	p.CanTouch = false
	p.CastShadow = false
	p.TopSurface = Enum.SurfaceType.Smooth
	p.BottomSurface = Enum.SurfaceType.Smooth
	p.Parent = parent
	return p
end

------------------------------------------------------------------------------------------
-- Pets (built around the origin facing -Z, then pivoted)
------------------------------------------------------------------------------------------

local FLYERS = { Owl = true, Drake = true, Wisp = true }

local BUILD: { [string]: (Model, any) -> BasePart } = {
	Fox = function(m, l)
		local body = part(m, nil, Vector3.new(0.7, 0.6, 1.1), l.Color)
		body.CFrame = CFrame.new(0, 0.55, 0)
		local head = part(m, nil, Vector3.new(0.6, 0.55, 0.55), l.Color)
		head.CFrame = CFrame.new(0, 0.95, -0.65)
		local snout = part(m, nil, Vector3.new(0.3, 0.25, 0.3), l.Color2)
		snout.CFrame = CFrame.new(0, 0.85, -1.0)
		for _, x in ipairs({ -0.18, 0.18 }) do
			local ear = part(m, Enum.PartType.Wedge, Vector3.new(0.12, 0.3, 0.2), l.Color)
			ear.CFrame = CFrame.new(x, 1.35, -0.6)
		end
		local tail = part(m, Enum.PartType.Ball, Vector3.new(0.45, 0.45, 0.8), l.Color2)
		tail.CFrame = CFrame.new(0, 0.85, 0.75) * CFrame.Angles(math.rad(-35), 0, 0)
		return body
	end,
	Owl = function(m, l)
		local body = part(m, Enum.PartType.Ball, Vector3.new(0.95, 0.95, 0.95), l.Color)
		body.CFrame = CFrame.new(0, 0.5, 0)
		for _, x in ipairs({ -0.18, 0.18 }) do
			local eye = part(m, Enum.PartType.Ball, Vector3.new(0.22, 0.22, 0.22), l.Color2, Enum.Material.Neon)
			eye.CFrame = CFrame.new(x, 0.62, -0.4)
		end
		local beak = part(m, Enum.PartType.Wedge, Vector3.new(0.12, 0.16, 0.14), l.Color2)
		beak.CFrame = CFrame.new(0, 0.45, -0.48) * CFrame.Angles(math.rad(180), 0, 0)
		return body
	end,
	Drake = function(m, l)
		local body = part(m, nil, Vector3.new(0.6, 0.55, 1.0), l.Color)
		body.CFrame = CFrame.new(0, 0.5, 0)
		local head = part(m, nil, Vector3.new(0.5, 0.45, 0.55), l.Color)
		head.CFrame = CFrame.new(0, 0.8, -0.6)
		for _, x in ipairs({ -1, 1 }) do
			local wing = part(m, nil, Vector3.new(0.9, 0.06, 0.5), l.Color2)
			wing.CFrame = CFrame.new(x * 0.65, 0.7, 0) * CFrame.Angles(0, 0, math.rad(x * 20))
		end
		local tail = part(m, Enum.PartType.Wedge, Vector3.new(0.2, 0.25, 0.6), l.Color)
		tail.CFrame = CFrame.new(0, 0.45, 0.75) * CFrame.Angles(0, math.rad(180), 0)
		return body
	end,
	Slime = function(m, l)
		local body = part(m, Enum.PartType.Ball, Vector3.new(1.1, 0.85, 1.1), l.Color)
		body.Transparency = 0.12
		body.CFrame = CFrame.new(0, 0.42, 0)
		for _, x in ipairs({ -0.2, 0.2 }) do
			local eye = part(m, Enum.PartType.Ball, Vector3.new(0.16, 0.2, 0.16), l.Color2)
			eye.CFrame = CFrame.new(x, 0.55, -0.45)
		end
		return body
	end,
	Wisp = function(m, l)
		local glow = part(m, Enum.PartType.Ball, Vector3.new(0.6, 0.6, 0.6), l.Color, Enum.Material.Neon)
		glow.CFrame = CFrame.new(0, 0.6, 0)
		local cage = part(m, nil, Vector3.new(0.5, 0.12, 0.5), l.Color2)
		cage.CFrame = CFrame.new(0, 0.95, 0)
		local light = Instance.new("PointLight")
		light.Color = l.Color
		light.Range = 8
		light.Brightness = 0.8
		light.Shadows = false
		light.Parent = glow
		return glow
	end,
}

local function buildPet(id: string): Model?
	local l = look(id)
	local build = l and BUILD[l.Shape]
	if not build or not folder then
		return nil
	end
	local m = Instance.new("Model")
	m.Name = "Pet_" .. id
	local primary = build(m, l)
	m.PrimaryPart = primary
	m:SetAttribute("Flyer", FLYERS[l.Shape] == true)
	m.Parent = folder
	return m
end

------------------------------------------------------------------------------------------
-- Trails
------------------------------------------------------------------------------------------

local function dropTrail(r: Rig)
	if r.Trail then
		r.Trail:Destroy()
		r.Trail = nil
	end
	for _, a in ipairs(r.Att) do
		a:Destroy()
	end
	table.clear(r.Att)
end

local function buildTrail(r: Rig, id: string)
	local l = look(id)
	local root = r.Root
	if not l or not root then
		return
	end
	local a0 = Instance.new("Attachment")
	a0.Name = "StoreTrail0"
	a0.Position = Vector3.new(0, -r.Drop + 0.3, 0)
	a0.Parent = root
	local a1 = Instance.new("Attachment")
	a1.Name = "StoreTrail1"
	a1.Position = Vector3.new(0, -r.Drop + 0.3 + (l.Width or 1), 0)
	a1.Parent = root
	local t = Instance.new("Trail")
	t.Name = "StoreTrail"
	t.Attachment0 = a0
	t.Attachment1 = a1
	t.Color = ColorSequence.new(l.Color, l.Color2 or l.Color)
	t.Transparency = NumberSequence.new({ NumberSequenceKeypoint.new(0, 0.25), NumberSequenceKeypoint.new(1, 1) })
	t.Lifetime = 0.45
	t.MinLength = 0.2
	t.LightEmission = 0.5
	t.FaceCamera = true
	t.Parent = root
	r.Trail = t
	r.Att = { a0, a1 }
end

------------------------------------------------------------------------------------------
-- Nameplates
------------------------------------------------------------------------------------------

-- Styles a plate frame (any module's) for this player's worn frame and Supporter glow.
-- Returns true when it added anything.
function StoreFx.DecoratePlate(frame: GuiObject, who: Player): boolean
	if not on() then
		return false
	end
	for _, ch in ipairs(frame:GetChildren()) do
		if ch.Name == "StorePlateStroke" or ch.Name == "StoreSupporter" or ch.Name == "StoreGlow" then
			ch:Destroy()
		end
	end
	local l = look(who:GetAttribute("CosPlate"))
	local supporter = who:GetAttribute("Supporter") == true
	if not l and not supporter then
		return false
	end
	local color = l and l.Color or Color3.fromRGB(255, 222, 120)
	local s = UIKit.stroke(frame, color, 2, 0)
	s.Name = "StorePlateStroke"
	if supporter or (l and l.Glow) then
		local glow = new("Frame", { Name = "StoreGlow", BackgroundColor3 = color, BackgroundTransparency = 0.75, BorderSizePixel = 0, AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.5), Size = UDim2.new(1, 8, 1, 8), ZIndex = 0 }, frame)
		UIKit.corner(glow, 999)
		UIAnim.Breathe(glow, 0.06, 1.4)
	end
	if supporter then
		local badge = UIKit.Badge(frame, "SUPPORTER", "Gold", { Name = "StoreSupporter", AnchorPoint = Vector2.new(0.5, 0), Position = UDim2.new(0.5, 0, 1, 2) })
		badge.ZIndex = 3
	end
	return true
end

local function dropPlate(r: Rig)
	if r.Plate then
		r.Plate:Destroy()
		r.Plate = nil
	end
	r.PlateKey = ""
end

local function buildPlate(r: Rig, who: Player, adornee: BasePart)
	local gui = new("BillboardGui", {
		Name = "StorePlate_" .. who.Name,
		Adornee = adornee,
		Size = UDim2.fromOffset(170, 46),
		StudsOffsetWorldSpace = Vector3.new(0, 2.6, 0),
		AlwaysOnTop = false,
		MaxDistance = S.PlateRange or 70,
		ResetOnSpawn = false,
		LightInfluence = 0,
	}, plateGui)
	local l = look(who:GetAttribute("CosPlate"))
	local plate = new("Frame", {
		Name = "Plate",
		AnchorPoint = Vector2.new(0.5, 0),
		Position = UDim2.fromScale(0.5, 0),
		Size = UDim2.new(1, -20, 0, 24),
		BackgroundColor3 = l and l.Color2 or Color3.fromRGB(40, 32, 20),
		BackgroundTransparency = 0.2,
		BorderSizePixel = 0,
	}, gui)
	UIKit.corner(plate, 999)
	UIKit.text(plate, "Label", who.DisplayName, {
		Name = "Name",
		Size = UDim2.fromScale(1, 1),
		TextXAlignment = Enum.TextXAlignment.Center,
		TextColor3 = l and l.Color or Color3.fromRGB(255, 232, 160),
		TextTruncate = Enum.TextTruncate.AtEnd,
		ZIndex = 2,
	}, 14)
	StoreFx.DecoratePlate(plate, who)
	r.Plate = gui
end

------------------------------------------------------------------------------------------
-- Emotes
------------------------------------------------------------------------------------------

local function showEmote(r: Rig, who: Player, adornee: BasePart)
	local l = look(who:GetAttribute("CosEmote"))
	if not l or not plateGui then
		return
	end
	if r.Emote then
		r.Emote:Destroy()
	end
	local gui = new("BillboardGui", {
		Name = "StoreEmote_" .. who.Name,
		Adornee = adornee,
		Size = UDim2.fromOffset(72, 72),
		StudsOffsetWorldSpace = Vector3.new(0, 5, 0),
		AlwaysOnTop = true,
		MaxDistance = S.PlateRange or 70,
		ResetOnSpawn = false,
	}, plateGui)
	local disc = new("Frame", { Name = "Disc", AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.5), Size = UDim2.fromOffset(60, 60), BackgroundColor3 = Color3.fromRGB(28, 24, 36), BackgroundTransparency = 0.15, BorderSizePixel = 0 }, gui)
	UIKit.corner(disc, 999)
	UIKit.stroke(disc, l.Color, 2, 0)
	Icons.Draw(disc, l.Icon or "sparkle", { Size = 40, Color = l.Color, Position = UDim2.fromScale(0.5, 0.5), AnchorPoint = Vector2.new(0.5, 0.5) } :: any)
	UIAnim.Pop(disc, 0, 0.4)
	r.Emote = gui
	task.delay(S.EmoteSeconds or 2.2, function()
		if r.Emote == gui then
			gui:Destroy()
			r.Emote = nil
		end
	end)
end

-- Asks the server to play the worn emote (cooldown on the server). For the Store screen and
-- other features (pings / photo mode) that want an emote button.
function StoreFx.Emote()
	if on() then
		Remotes.Get("StoreEmote"):FireServer()
	end
end

------------------------------------------------------------------------------------------
-- Dais theme + Supporter banner (local menu only)
------------------------------------------------------------------------------------------

local dais: Model? = nil
local daisKey = ""

local function refreshDais()
	local stand = Showcase.Stand()
	local id = player:GetAttribute("CosDais")
	local supporter = player:GetAttribute("Supporter") == true
	local l = look(id)
	local key = stand and ((id or "") .. "|" .. tostring(supporter) .. "|" .. tostring(stand.Position)) or ""
	if key == daisKey and (key == "" or (dais and dais.Parent)) then
		return
	end
	daisKey = key
	if dais then
		dais:Destroy()
		dais = nil
	end
	if not stand or not folder or (not l and not supporter) then
		return
	end
	local m = Instance.new("Model")
	m.Name = "StoreDais"
	if l then
		local material = (Enum.Material :: any)[l.Material or "Slate"] or Enum.Material.Slate
		local disc = part(m, Enum.PartType.Cylinder, Vector3.new(0.12, 5.6, 5.6), l.Color, material)
		disc.CFrame = stand * CFrame.new(0, 0.02, 0) * CFrame.Angles(0, 0, math.rad(90))
		local trim = part(m, Enum.PartType.Cylinder, Vector3.new(0.08, 6.0, 6.0), l.Color2, l.Glow and Enum.Material.Neon or Enum.Material.Metal)
		trim.CFrame = stand * CFrame.new(0, -0.01, 0) * CFrame.Angles(0, 0, math.rad(90))
		for i = 1, 4 do
			local a = (i - 0.5) / 4 * math.pi * 2
			local gem = part(m, nil, Vector3.new(0.35, 0.7, 0.35), l.Color2, l.Glow and Enum.Material.Neon or Enum.Material.SmoothPlastic)
			gem.CFrame = stand * CFrame.new(math.cos(a) * 3.2, 0.35, math.sin(a) * 3.2) * CFrame.Angles(0, a, math.rad(45))
		end
	end
	if supporter then
		local base = stand * CFrame.new(-4.2, 0, 1.2)
		local pole = part(m, Enum.PartType.Cylinder, Vector3.new(6, 0.18, 0.18), Color3.fromRGB(120, 90, 50), Enum.Material.Wood)
		pole.CFrame = base * CFrame.new(0, 3, 0) * CFrame.Angles(0, 0, math.rad(90))
		local cloth = part(m, nil, Vector3.new(1.6, 2.2, 0.06), Color3.fromRGB(170, 40, 50), Enum.Material.Fabric)
		cloth.CFrame = base * CFrame.new(0.9, 4.6, 0)
		local star = part(m, nil, Vector3.new(0.6, 0.6, 0.08), Color3.fromRGB(255, 214, 90), Enum.Material.Neon)
		star.CFrame = base * CFrame.new(0.9, 4.8, -0.04) * CFrame.Angles(0, 0, math.rad(45))
		local top = part(m, Enum.PartType.Ball, Vector3.new(0.4, 0.4, 0.4), Color3.fromRGB(255, 214, 90), Enum.Material.Metal)
		top.CFrame = base * CFrame.new(0, 6.1, 0)
	end
	m.Parent = folder
	dais = m
end

------------------------------------------------------------------------------------------
-- Per-player rigs
------------------------------------------------------------------------------------------

local function rigOf(who: Player): Rig
	local r = rigs[who]
	if not r then
		r = { Drop = 3, PetId = "", TrailId = "", Att = {}, PlateKey = "", EmoteAt = 0 } :: any
		rigs[who] = r
	end
	return r :: Rig
end

local function dropRig(r: Rig)
	if r.Pet then
		r.Pet:Destroy()
		r.Pet = nil
	end
	r.PetId = ""
	r.PetPos = nil
	dropTrail(r)
	r.TrailId = ""
	dropPlate(r)
	if r.Emote then
		r.Emote:Destroy()
		r.Emote = nil
	end
end

local function hidden(r: Rig): boolean
	local probe = r.HideProbe
	return probe ~= nil and probe.LocalTransparencyModifier >= 1
end

-- Picks up a new character: root, the feet drop and a part to tell if it is hidden.
local function bindChar(r: Rig, char: Model?)
	if r.Char == char then
		return
	end
	dropTrail(r)
	r.TrailId = ""
	dropPlate(r)
	r.Char = char
	r.Root = char and char.PrimaryPart or nil
	r.HideProbe = nil
	r.Drop = 3
	if char and r.Root then
		local ok, cf, size = pcall(function()
			return char:GetBoundingBox()
		end)
		if ok and cf and size then
			r.Drop = math.clamp((r.Root :: BasePart).Position.Y - (cf.Position.Y - size.Y / 2), 0.5, 6)
		end
		for _, d in ipairs(char:GetDescendants()) do
			if d:IsA("BasePart") and d ~= r.Root and d.Transparency < 1 then
				r.HideProbe = d
				break
			end
		end
	end
end

local menuAnchor: BasePart? = nil

-- Updates one player's looks (structure only; pets move in step()).
local function refreshPlayer(who: Player, camPos: Vector3?)
	local r = rigOf(who)
	local char = who.Character
	bindChar(r, char)
	local menu = who == player and Showcase.Stand() ~= nil
	local root = r.Root
	local far = root and camPos and (root.Position - camPos).Magnitude > (S.PetRange or 150)
	-- trail
	local trailId = (not menu and not far and root) and (who:GetAttribute("CosTrail") or "") or ""
	if trailId ~= r.TrailId then
		dropTrail(r)
		r.TrailId = trailId
		if trailId ~= "" then
			buildTrail(r, trailId)
		end
	end
	-- nameplate (none on the menu hero: the lobby screens sit over it)
	local adornee: BasePart? = nil
	if not menu and root and not hidden(r) then
		adornee = root
	end
	local plateKey = adornee and (tostring(who:GetAttribute("CosPlate") or "") .. "|" .. tostring(who:GetAttribute("Supporter")) .. "|" .. adornee:GetFullName()) or ""
	local wantsPlate = adornee ~= nil and ((who:GetAttribute("CosPlate") or "") ~= "" or who:GetAttribute("Supporter") == true)
	-- a worn META title: TitlePlates draws the plate (name + title) and styles it with
	-- DecoratePlate, so there is one plate, not two
	if Config.FeatureOn("Titles") and (who:GetAttribute("Title") or "") ~= "" then
		wantsPlate = false
	end
	if not wantsPlate then
		plateKey = ""
	end
	if plateKey ~= r.PlateKey then
		dropPlate(r)
		r.PlateKey = plateKey
		if plateKey ~= "" and adornee then
			buildPlate(r, who, adornee)
		end
	end
	-- emote (CosEmoteAt = server time it was played)
	local at = tonumber(who:GetAttribute("CosEmoteAt")) or 0
	if at ~= r.EmoteAt then
		r.EmoteAt = at
		local age = workspace:GetServerTimeNow() - at
		local target = menu and menuAnchor or root
		if at > 0 and age < (S.EmoteSeconds or 2.2) and target then
			showEmote(r, who, target)
		end
	end
end

------------------------------------------------------------------------------------------
-- Frame step: pets follow
------------------------------------------------------------------------------------------

local clock = 0
local nextRefresh = 0

local function petTarget(who: Player, r: Rig): (CFrame?, number)
	if who == player then
		local stand = Showcase.Stand()
		if stand then
			return stand * CFrame.new(2.6, 0, -0.6), 0
		end
	end
	local root = r.Root
	if not root or not root.Parent or hidden(r) then
		return nil, 0
	end
	local flat = root.CFrame - root.CFrame.Position
	local feet = root.Position - Vector3.new(0, r.Drop, 0)
	return CFrame.new(feet) * flat * CFrame.new(2.2, 0, 1.6), 1
end

local function step(dt: number)
	clock += dt
	local cam = workspace.CurrentCamera
	local camPos = cam and cam.CFrame.Position
	local now = os.clock()
	if now >= nextRefresh then
		nextRefresh = now + 0.25
		local stand = Showcase.Stand()
		if stand and folder then
			if not menuAnchor then
				local a = part(folder, nil, Vector3.new(0.2, 0.2, 0.2), Color3.new(1, 1, 1))
				a.Name = "StoreMenuAnchor"
				a.Transparency = 1
				menuAnchor = a
			end
			(menuAnchor :: BasePart).CFrame = stand * CFrame.new(0, 6.4, 0)
		end
		for _, who in ipairs(Players:GetPlayers()) do
			refreshPlayer(who, camPos)
		end
		refreshDais()
		local burst = look(player:GetAttribute("CosBurst"))
		HitFeel.SetStyle(burst)
	end
	-- pets: nearest MaxPets within range
	local wanted: { { Who: Player, R: Rig, CF: CFrame, D: number, Follow: number } } = {}
	for who, r in pairs(rigs) do
		local id = who:GetAttribute("CosPet")
		local cf, follow = nil, 0
		if type(id) == "string" and id ~= "" then
			cf, follow = petTarget(who, r)
		end
		if cf then
			local d = camPos and (cf.Position - camPos).Magnitude or 0
			if d <= (S.PetRange or 150) then
				table.insert(wanted, { Who = who, R = r, CF = cf, D = d, Follow = follow })
			end
		end
	end
	table.sort(wanted, function(a, b)
		return a.D < b.D
	end)
	local keep: { [Rig]: boolean } = {}
	for i, w in ipairs(wanted) do
		if i > (S.MaxPets or 8) then
			break
		end
		local r = w.R
		local id = w.Who:GetAttribute("CosPet") :: string
		if r.PetId ~= id or not r.Pet or not r.Pet.Parent then
			if r.Pet then
				r.Pet:Destroy()
			end
			r.Pet = buildPet(id)
			r.PetId = id
			r.PetPos = nil
		end
		local pet = r.Pet
		if pet then
			keep[r] = true
			local goal = w.CF.Position
			local pos = r.PetPos or goal
			-- eases after the hero (snaps when it fell far behind: a teleport, a new stage)
			if (goal - pos).Magnitude > 30 then
				pos = goal
			else
				pos = pos:Lerp(goal, math.clamp(dt * 6, 0, 1))
			end
			r.PetPos = pos
			local flyer = pet:GetAttribute("Flyer") == true
			local bob = flyer and (1.6 + math.sin(clock * 3 + i) * 0.25) or math.abs(math.sin(clock * 6 + i)) * 0.12 * w.Follow
			local look3 = w.CF.LookVector
			pet:PivotTo(CFrame.lookAt(pos + Vector3.new(0, bob, 0), pos + Vector3.new(0, bob, 0) + Vector3.new(look3.X, 0, look3.Z)))
		end
	end
	for _, r in pairs(rigs) do
		if r.Pet and not keep[r] then
			r.Pet:Destroy()
			r.Pet = nil
			r.PetId = ""
			r.PetPos = nil
		end
	end
end

function StoreFx.Init()
	if not on() then
		return
	end
	local f = Instance.new("Folder")
	f.Name = "SwarmStoreFx"
	f.Parent = workspace
	folder = f
	local g = Instance.new("Folder")
	g.Name = "SwarmStorePlates"
	g.Parent = player:WaitForChild("PlayerGui")
	plateGui = g
	Players.PlayerRemoving:Connect(function(who)
		local r = rigs[who]
		if r then
			dropRig(r)
			rigs[who] = nil
		end
	end)
	RunService.RenderStepped:Connect(step)
end

-- (preview scenes / tests)
function StoreFx._Stats(): { [string]: number }
	local pets, trails, plates = 0, 0, 0
	for _, r in pairs(rigs) do
		pets += r.Pet and 1 or 0
		trails += r.Trail and 1 or 0
		plates += r.Plate and 1 or 0
	end
	return { Pets = pets, Trails = trails, Plates = plates, Dais = dais and 1 or 0 }
end

return StoreFx
