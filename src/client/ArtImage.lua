--[[
	ArtImage.lua
	Places the owner's big pictures (src/shared/ArtData: portraits/, arenas/, bosses/,
	screens/, ui/frames/, icons/ui/ui_*) over the drawn look they replace. Every call works
	when a picture is not uploaded: it returns nil and the drawn look stays as it was.

	ArtImage.Image(key)                      "rbxassetid://<id>" or nil
	ArtImage.Portrait(characterId)           key "portraits/<Id>"; Boss(id) "bosses/<Id>";
	                                         Arena(id) "arenas/<Id>"; Screen(name) "screens/<name>"
	ArtImage.Place(parent, key, props, fallbacks?)
	                                         an ImageLabel (props: any ImageLabel properties, Fit by
	                                         default) or nil. fallbacks (GuiObjects, or a function
	                                         (show: boolean)) are what the picture covers: hidden
	                                         while it may still be loading, shown when it has not
	                                         loaded after 0.6 s, hidden for good once it is in (the
	                                         same rule as Icons' pictures; IsLoaded is polled too).
	                                         props.FadeIn = seconds fades the picture in once loaded
	                                         (instant with Reduced effects). props.Idle =
	                                         { Kind, Opts? } gives it an IdleFx idle motion.
	ArtImage.Set(label, key, fallbacks?)     re-points a Place()d label at another key (nil key:
	                                         label hidden, fallbacks shown)
	ArtImage.ButtonIcon(holder, key, layout?, glyphName?)
	                                         a picture over a UIKit button's icon holder whose
	                                         drawn icon is redrawn on state changes (enable /
	                                         kind): the picture survives the redraws and keeps
	                                         the drawn glyph hidden under it. layout (Size,
	                                         Position ...) lets it stand a little proud;
	                                         layout.Idle = { Kind, Opts? } survives redraws too.
	ArtImage.RoundPortrait(medal, key, fallbacks, props?)
	                                         a bust clipped to a circle (CanvasGroup) filling a
	                                         round medal; call again to change it
	ArtImage.Frame(parent, band, border, props?)
	                                         9-slice rarity frame (ui/frames/frame_<band>) around
	                                         its parent: border = visible rim width in pixels.
	ArtImage.ItemBand(id) / CardBand(card)   frame band of a run item / a level-up card
	ArtImage.PreloadList()                   home-screen and loading pictures, most needed first
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local ArtData = require(Shared:WaitForChild("ArtData"))
local ItemData = require(Shared:WaitForChild("ItemData"))
local CharacterData = require(Shared:WaitForChild("CharacterData"))
local BossData = require(Shared:WaitForChild("BossData"))
local ClientSettings = require(script.Parent.ClientSettings)
local IdleFx = require(script.Parent.IdleFx)

local ArtImage = {}

local FALLBACK_DELAY = 0.6
local POLL = 0.25
local GIVE_UP = 20

function ArtImage.Image(key: string?): string?
	return ArtData.Image(key)
end

function ArtImage.Portrait(id: string?): string
	return "portraits/" .. tostring(id)
end

function ArtImage.Boss(id: string?): string
	return "bosses/" .. tostring(id)
end

function ArtImage.Arena(id: string?): string
	return "arenas/" .. tostring(id)
end

function ArtImage.Screen(name: string): string
	return "screens/" .. name
end

type Fallbacks = { GuiObject } | ((boolean) -> ()) | nil

local function showFallbacks(fallbacks: Fallbacks, on: boolean)
	if type(fallbacks) == "function" then
		fallbacks(on)
	elseif type(fallbacks) == "table" then
		for _, g in ipairs(fallbacks) do
			if g.Parent then
				g.Visible = on
			end
		end
	end
end

-- Watches one picture load: fallbacks hidden at first, shown after FALLBACK_DELAY if it is
-- not in yet, hidden again once it is. A newer watch on the same label wins (token).
local function watch(img: ImageLabel, fallbacks: Fallbacks, fadeIn: number?, target: number)
	local token = (tonumber(img:GetAttribute("ArtToken")) or 0) + 1
	img:SetAttribute("ArtToken", token)
	showFallbacks(fallbacks, false)
	local fade = fadeIn and fadeIn > 0 and not ClientSettings.Reduced()
	if fade then
		img.ImageTransparency = 1
	end
	task.spawn(function()
		local waited = 0
		local shown = false
		while img.Parent and img:GetAttribute("ArtToken") == token and waited < GIVE_UP do
			if img.IsLoaded then
				if shown then
					showFallbacks(fallbacks, false)
				end
				if fade then
					TweenService:Create(img, TweenInfo.new(fadeIn :: number), { ImageTransparency = target }):Play()
				end
				return
			end
			if waited >= FALLBACK_DELAY and not shown then
				shown = true
				showFallbacks(fallbacks, true)
			end
			task.wait(POLL)
			waited += POLL
		end
		-- never loaded: the fallbacks stay (shown by now); a faded picture shows as it is
		if fade and img.Parent and img:GetAttribute("ArtToken") == token then
			img.ImageTransparency = target
		end
	end)
end

function ArtImage.Place(parent: Instance?, key: string?, props: { [string]: any }?, fallbacks: Fallbacks): ImageLabel?
	local image = ArtData.Image(key)
	if not image then
		return nil
	end
	local img = Instance.new("ImageLabel")
	img.Name = "Art"
	img.BackgroundTransparency = 1
	img.BorderSizePixel = 0
	img.ScaleType = Enum.ScaleType.Fit
	img.Size = UDim2.fromScale(1, 1)
	img.Active = false
	local fadeIn: number? = nil
	local idle: { [any]: any }? = nil
	for k, v in pairs(props or {}) do
		if k == "FadeIn" then
			fadeIn = v
		elseif k == "Idle" then
			idle = v
		else
			(img :: any)[k] = v
		end
	end
	img.Image = image
	img.Parent = parent
	watch(img, fallbacks, fadeIn, img.ImageTransparency)
	if idle then
		IdleFx.Attach(img, idle[1] or idle.Kind, idle[2] or idle.Opts)
	end
	return img
end

function ArtImage.Set(img: ImageLabel?, key: string?, fallbacks: Fallbacks)
	if not img then
		return
	end
	local image = ArtData.Image(key)
	if not image then
		img:SetAttribute("ArtToken", (tonumber(img:GetAttribute("ArtToken")) or 0) + 1)
		img.Visible = false
		showFallbacks(fallbacks, true)
		return
	end
	img.Visible = true
	if img.Image ~= image then
		img.Image = image
	end
	watch(img, fallbacks, nil, img.ImageTransparency)
end

-- Picture over a UIKit button's IconHolder (or an IconButton's Content, glyphName "Glyph").
-- The button rebuilds its drawn icon on enable / kind changes (a Button even clears the
-- whole holder): a new glyph follows the picture's state, and a cleared picture is put back.
function ArtImage.ButtonIcon(holder: Instance?, key: string, layout: { [string]: any }?, glyphName: string?): ImageLabel?
	if not holder or not ArtData.Image(key) then
		return nil
	end
	local showing = false -- the drawn glyph shows (the picture has not loaded yet)
	local function mine(ch: Instance): boolean
		return ch:IsA("GuiObject") and ch.Name ~= "Art" and (glyphName == nil or ch.Name == glyphName)
	end
	local props = {
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.5),
		Size = UDim2.fromScale(1, 1),
		ZIndex = 4,
	}
	for k, v in pairs(layout or {}) do
		props[k] = v
	end
	local img = ArtImage.Place(holder, key, props, function(on: boolean)
		showing = on
		for _, ch in ipairs(holder:GetChildren()) do
			if mine(ch) then
				(ch :: GuiObject).Visible = on
			end
		end
	end)
	if not img then
		return nil
	end
	local added, removed
	added = holder.ChildAdded:Connect(function(ch)
		if mine(ch) then
			(ch :: GuiObject).Visible = showing
		end
	end)
	removed = holder.ChildRemoved:Connect(function(ch)
		if ch == img then
			added:Disconnect()
			removed:Disconnect()
			task.defer(function()
				if holder.Parent and not holder:FindFirstChild("Art") then
					ArtImage.ButtonIcon(holder, key, layout, glyphName)
				end
			end)
		end
	end)
	return img
end

--[[
	Round portrait: a CanvasGroup with a full UICorner (it clips to the circle) holding the
	bust, filling a medal frame. fallback = the drawn icon(s) shown while it loads. Call
	again on the same medal to change hero; nil when the hero has no portrait (the clip is
	hidden and the fallback shown).
]]
function ArtImage.RoundPortrait(medal: GuiObject, key: string, fallbacks: Fallbacks, props: { [string]: any }?): ImageLabel?
	local clip = medal:FindFirstChild("PortraitClip") :: CanvasGroup?
	local img = clip and clip:FindFirstChild("Art") :: ImageLabel?
	if not ArtData.Image(key) then
		if clip then
			clip.Visible = false
		end
		showFallbacks(fallbacks, true)
		return nil
	end
	if not clip then
		local c = Instance.new("CanvasGroup")
		c.Name = "PortraitClip"
		c.BackgroundTransparency = 1
		c.BorderSizePixel = 0
		c.Size = UDim2.fromScale(1, 1)
		c.ZIndex = 2
		c.Active = false
		local corner = Instance.new("UICorner")
		corner.CornerRadius = UDim.new(1, 0)
		corner.Parent = c
		c.Parent = medal
		clip = c
	end
	(clip :: CanvasGroup).Visible = true
	if img then
		ArtImage.Set(img, key, fallbacks)
	else
		local p = {
			AnchorPoint = Vector2.new(0.5, 1),
			Position = UDim2.fromScale(0.5, 1.04),
			Size = UDim2.fromScale(1.12, 1.12),
		}
		for k, v in pairs(props or {}) do
			p[k] = v
		end
		img = ArtImage.Place(clip, key, p, fallbacks)
	end
	return img
end

-- 9-slice slice centre of the frame pictures (512 px): the rim runs from 42 px (transparent
-- margin) to about 112 px; the ornamented corners reach a little further.
local FRAME_MARGIN, FRAME_INNER = 42, 120

function ArtImage.Frame(parent: Instance?, band: string, border: number, props: { [string]: any }?): ImageLabel?
	local image = ArtData.Image("ui/frames/frame_" .. band) or ArtData.Image("ui/frames/frame_Common")
	if not image then
		return nil
	end
	local scale = border / (FRAME_INNER - FRAME_MARGIN)
	local m = math.floor(FRAME_MARGIN * scale + 0.5)
	local img = Instance.new("ImageLabel")
	img.Name = "ArtFrame"
	img.BackgroundTransparency = 1
	img.BorderSizePixel = 0
	img.Active = false
	img.Image = image
	img.ScaleType = Enum.ScaleType.Slice
	img.SliceCenter = Rect.new(FRAME_INNER, FRAME_INNER, 512 - FRAME_INNER, 512 - FRAME_INNER)
	img.SliceScale = scale
	img.Position = UDim2.fromOffset(-m, -m)
	img.Size = UDim2.new(1, 2 * m, 1, 2 * m)
	img.ZIndex = 5
	for k, v in pairs(props or {}) do
		(img :: any)[k] = v
	end
	img.Parent = parent
	return img
end

-- Re-points a frame made by ArtImage.Frame at another band.
function ArtImage.SetFrame(img: ImageLabel?, band: string)
	if img then
		local image = ArtData.Image("ui/frames/frame_" .. band) or ArtData.Image("ui/frames/frame_Common")
		if image and img.Image ~= image then
			img.Image = image
		end
	end
end

-- Run item rarity → frame band (weapons / passives / evolutions in an elite chest: Rare /
-- Legendary).
function ArtImage.ItemBand(id: string?, evolved: boolean?): string
	local def = id and ItemData.Items[id]
	if def then
		return def.Rarity
	end
	return evolved and "Legendary" or "Rare"
end

-- Level-up card → frame band: Upgrade = Common, New = Rare, Max = Epic, Evolution =
-- Legendary, the Gold / Heal bonus cards Uncommon (green, like their band).
function ArtImage.CardBand(c: any): string
	if c.Type == "Gold" or c.Type == "Heal" then
		return "Uncommon"
	elseif c.Type == "Evolve" then
		return "Legendary"
	end
	local r = c.Rarity
	if r == "Rare" or r == "Epic" or r == "Legendary" or r == "Uncommon" then
		return r
	end
	return "Common"
end

-- Pictures worth having before the menu shows: the loading screen, logo, home buttons,
-- hero portraits, then the frames, arena cards, results backdrops and boss portraits.
function ArtImage.PreloadList(): { string }
	local list = {}
	local function add(key: string)
		local image = ArtData.Image(key)
		if image and not table.find(list, image) then
			table.insert(list, image)
		end
	end
	add("screens/loading")
	add("screens/logo_SWARM")
	for _, name in ipairs({ "Solo", "Duo", "Trio", "Curses", "Characters", "Upgrades", "Arenas", "Daily", "Settings", "Leaderboards", "Track", "Play" }) do
		add("icons/ui/ui_" .. name)
	end
	for _, id in ipairs(CharacterData.Order) do
		add(ArtImage.Portrait(id))
	end
	for _, band in ipairs({ "Common", "Uncommon", "Rare", "Epic", "Legendary" }) do
		add("ui/frames/frame_" .. band)
	end
	for _, id in ipairs({ "Forest", "Ruins", "Swamp", "Snow", "Desert", "Lava" }) do
		add(ArtImage.Arena(id))
	end
	for _, id in ipairs(BossData.Rotation) do
		add(ArtImage.Boss(id))
	end
	for _, name in ipairs({ "victory", "defeat", "results_bg" }) do
		add(ArtImage.Screen(name))
	end
	return list
end

return ArtImage
