--[[
	HeroPresets.lua (client)
	Feature 14, build presets (Config.Features.BuildPresets; docs/features/HEROPOWER.md).

	Keeps the last ProfileSync's favourites (Features.Presets) and the selected hero, so the
	Characters screen (MenuHeroPower) can show the marks and the level-up cards (UIBuilder
	makeCard, one call to HeroPresets.Tag) can add a small "★ Favourite" tag. The tag is
	the only thing that changes: which cards are offered, and their weights, never do.

	  HeroPresets.Init()                     listen to ProfileSync (ClientMain, once)
	  HeroPresets.Favourites(heroId)         { Weapons = {id}, Passives = {id} }
	  HeroPresets.IsFavourite(heroId, id)    weapon or passive id
	  HeroPresets.Toggle(heroId, kind, id)   ask the server (SetPreset); the next ProfileSync
	                                         brings the saved state
	  HeroPresets.Tag(face, card)            adds the tag to a level-up card face when the
	                                         card's Id is a favourite of the selected hero
]]

local Shared = game:GetService("ReplicatedStorage"):WaitForChild("Shared")
local Config = require(Shared:WaitForChild("Config"))
local Remotes = require(Shared:WaitForChild("Remotes"))
local Theme = require(Shared:WaitForChild("Theme"))
local UIKit = require(script.Parent.UIKit)

local HeroPresets = {}

local P = Theme.Palette
local presets: { [string]: any }? = nil
local selected: string? = nil
local started = false

local function on(): boolean
	return Config.FeatureOn("BuildPresets")
end

-- (tests / scenes) set the cached profile directly
function HeroPresets._Set(p: { [string]: any }?)
	if type(p) ~= "table" then
		return
	end
	if type(p.SelectedCharacter) == "string" then
		selected = p.SelectedCharacter
	end
	local f = p.Features
	if type(f) == "table" and type(f.Presets) == "table" then
		presets = f.Presets
	end
end

function HeroPresets.Init()
	if started then
		return
	end
	started = true
	Remotes.Get("ProfileSync").OnClientEvent:Connect(HeroPresets._Set)
	if on() then
		-- the first sync may have gone to the menus before this listener existed
		Remotes.Get("RequestProfile"):FireServer()
	end
end

function HeroPresets.Favourites(heroId: string?): { Weapons: { string }, Passives: { string } }
	local out = { Weapons = {}, Passives = {} }
	local p = presets
	if not p or not heroId or type(p.List) ~= "table" then
		return out
	end
	for _, entry in ipairs(p.List) do
		if type(entry) == "table" and entry.Hero == heroId then
			out.Weapons = type(entry.Weapons) == "table" and entry.Weapons or {}
			out.Passives = type(entry.Passives) == "table" and entry.Passives or {}
			break
		end
	end
	return out
end

function HeroPresets.IsFavourite(heroId: string?, id: any): boolean
	if not on() or type(id) ~= "string" then
		return false
	end
	local f = HeroPresets.Favourites(heroId)
	return table.find(f.Weapons, id) ~= nil or table.find(f.Passives, id) ~= nil
end

function HeroPresets.Toggle(heroId: string, kind: string, id: string)
	if not on() then
		return
	end
	local f = HeroPresets.Favourites(heroId)
	local list = kind == "Weapons" and f.Weapons or f.Passives
	Remotes.Get("SetPreset"):FireServer(heroId, kind, id, table.find(list, id) == nil)
end

-- Adds the favourite tag to a level-up card face (`c` = the offer card { Type, Id, ... }).
function HeroPresets.Tag(face: GuiObject, c: { [string]: any })
	if not HeroPresets.IsFavourite(selected, c and c.Id) then
		return
	end
	-- tall cards (landscape): bottom-left, clear of the kind tab on top; short wide cards
	-- (portrait stack): on the top edge left of the key number, in the gap between cards
	local hit = face.Parent
	local wide = hit and hit:IsA("GuiObject") and hit.Size.X.Offset > 2 * hit.Size.Y.Offset
	local plate = face:FindFirstChild("ChoosePlate") :: GuiObject?
	local tag = UIKit.text(face, "Label", Config.BuildPresets.Tag, {
		Name = "FavouriteTag",
		AnchorPoint = if wide then Vector2.new(1, 0.5) else Vector2.new(0, 1),
		-- tall cards sit just above the CHOOSE plate so a wide tag (large text) never meets the key
		Position = if wide then UDim2.new(1, -44, 0, 0) else (plate and UDim2.new(0, 8, 0, plate.Position.Y.Offset - 4) or UDim2.new(0, 8, 1, -8)),
		Size = UDim2.fromOffset(0, UIKit.TS(12) + 6),
		AutomaticSize = Enum.AutomaticSize.X,
		TextXAlignment = Enum.TextXAlignment.Center,
		BackgroundColor3 = P.slate_950,
		BackgroundTransparency = 0.1,
		TextColor3 = P.gold_200,
		ZIndex = 8,
	}, 12)
	UIKit.new("UIPadding", { PaddingLeft = UDim.new(0, 6), PaddingRight = UDim.new(0, 6) }, tag)
	UIKit.corner(tag, 6)
	UIKit.stroke(tag, P.gold_400, 1, 0.3)
end

return HeroPresets
