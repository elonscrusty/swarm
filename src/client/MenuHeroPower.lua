--[[
	MenuHeroPower.lua (client)
	The HEROPOWER block of the Characters screen (docs/features/HEROPOWER.md), built into
	MenuCharacters' details panel under the mastery rows. Each part shows only while its
	switch is on:
	  ULTIMATE      (Ultimate)      the hero's ultimate: name and one line
	  SECOND SKILL  (SecondSkill)   name, what it does and "Unlocks at mastery rank N" /
	                                "Unlocked" (free; never sold)
	  FAVOURITES    (BuildPresets)  owned heroes: FAVOURITES opens a grid of every weapon and
	                                passive; tapping one marks / unmarks it (server SetPreset).
	                                Marked cards get a small tag at level-up.

	  MenuHeroPower.Build(parent, order) -> { Frame, Refresh(heroId, profile, owned) }
]]

local Shared = game:GetService("ReplicatedStorage"):WaitForChild("Shared")
local Config = require(Shared:WaitForChild("Config"))
local Theme = require(Shared:WaitForChild("Theme"))
local CharacterData = require(Shared:WaitForChild("CharacterData"))
local WeaponData = require(Shared:WaitForChild("WeaponData"))
local PassiveData = require(Shared:WaitForChild("PassiveData"))
local MetaUpgradeData = require(Shared:WaitForChild("MetaUpgradeData"))
local UIKit = require(script.Parent.UIKit)
local HeroPresets = require(script.Parent.HeroPresets)

local MenuHeroPower = {}

local new, text, TS = UIKit.new, UIKit.text, UIKit.TS
local P = Theme.Palette
local HEADING = Font.fromEnum(Enum.Font.GothamBold)
local TILE = 44

local function wrapped(parent: Instance, style: string, color: Color3, size: number, order: number, name: string): TextLabel
	return text(parent, style, "", {
		Name = name,
		LayoutOrder = order,
		Size = UDim2.new(1, 0, 0, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		TextWrapped = true,
		FontFace = Theme.Font.Body,
		LineHeight = 1.15,
		TextColor3 = color,
		TextYAlignment = Enum.TextYAlignment.Top,
	}, size)
end

local function caption(parent: Instance, label: string, order: number): TextLabel
	return text(parent, "Label", label, { FontFace = HEADING, TextColor3 = P.gold_300, LayoutOrder = order, Size = UDim2.new(1, 0, 0, TS(13) + 4) }, 13)
end

function MenuHeroPower.Build(parent: Instance, order: number)
	local root = new("Frame", { Name = "HeroPower", BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 0), AutomaticSize = Enum.AutomaticSize.Y, LayoutOrder = order, Visible = false }, parent)
	UIKit.list(root, { Padding = UDim.new(0, 6) })
	UIKit.Hairline(root, { LayoutOrder = 0 })

	-- ULTIMATE
	local ultCap = caption(root, "ULTIMATE", 1)
	local ultName = wrapped(root, "BodyStrong", P.ivory_100, 16, 2, "UltName")
	ultName.FontFace = HEADING
	local ultText = wrapped(root, "Body", P.ivory_200, 15, 3, "UltText")

	-- SECOND SKILL
	local skillCap = caption(root, "SECOND SKILL", 4)
	local skillName = wrapped(root, "BodyStrong", P.ivory_100, 16, 5, "SkillName")
	skillName.FontFace = HEADING
	local skillText = wrapped(root, "Body", P.ivory_200, 15, 6, "SkillText")
	local skillState = wrapped(root, "Small", P.gold_200, 14, 7, "SkillState")

	-- FAVOURITES
	local favCap = caption(root, "FAVOURITES", 8)
	local favText = wrapped(root, "Small", P.ivory_300, 14, 9, "FavText")
	local open = false
	local heroNow = CharacterData.Default
	local refreshSelf: () -> () = function() end
	local favButton = UIKit.Button(root, {
		Name = "Favourites",
		Kind = "Outline",
		Title = "FAVOURITES",
		Icon = "check",
		IconSize = 16,
		Align = "Center",
		Size = UDim2.new(1, 0, 0, 40),
		LayoutOrder = 10,
		Shadow = false,
		OnClick = function()
			open = not open
			refreshSelf()
		end,
	})
	local grid = new("Frame", { Name = "FavouriteGrid", BackgroundTransparency = 1, Visible = false, LayoutOrder = 11, Size = UDim2.new(1, 0, 0, 0), AutomaticSize = Enum.AutomaticSize.Y }, root)
	UIKit.list(grid, { Padding = UDim.new(0, 6) })
	local tiles: { [string]: { Stroke: UIStroke, Mark: GuiObject, Kind: string } } = {}
	local function section(kind: string, label: string, ids: { string }, sOrder: number)
		text(grid, "Label", label, { FontFace = HEADING, TextColor3 = P.ivory_300, LayoutOrder = sOrder, Size = UDim2.new(1, 0, 0, TS(12) + 4) }, 12)
		local box = new("Frame", { Name = kind, BackgroundTransparency = 1, LayoutOrder = sOrder + 1, Size = UDim2.new(1, 0, 0, 0), AutomaticSize = Enum.AutomaticSize.Y }, grid)
		new("UIGridLayout", { CellSize = UDim2.fromOffset(TILE, TILE), CellPadding = UDim2.fromOffset(6, 6), SortOrder = Enum.SortOrder.LayoutOrder }, box)
		for i, id in ipairs(ids) do
			local hit = new("TextButton", { Name = id, Text = "", AutoButtonColor = true, BackgroundTransparency = 1, LayoutOrder = i }, box)
			UIKit.Tile(hit, { Id = id, Size = TILE })
			local stroke = UIKit.stroke(hit, P.gold_300, 2.5, 1)
			UIKit.corner(hit, math.floor(TILE * 0.2))
			local mark = text(hit, "Label", "★", { Name = "Mark", AnchorPoint = Vector2.new(1, 0), Position = UDim2.new(1, 2, 0, -2), Size = UDim2.fromOffset(16, 16), TextColor3 = P.gold_200, TextStrokeTransparency = 0.3, Visible = false, ZIndex = 5 }, 14)
			tiles[id] = { Stroke = stroke, Mark = mark, Kind = kind }
			hit.Activated:Connect(function()
				UIKit.Click()
				HeroPresets.Toggle(heroNow, kind, id)
			end)
		end
	end
	section("Weapons", "WEAPONS", WeaponData.Order, 1)
	section("Passives", "PASSIVES", PassiveData.Order, 3)

	local lastProfile: { [string]: any }? = nil
	local lastOwned = false
	local function refresh(heroId: string, p: { [string]: any }?, owned: boolean)
		heroNow, lastProfile, lastOwned = heroId, p, owned
		local ultOn, skillOn, favOn = Config.FeatureOn("Ultimate"), Config.FeatureOn("SecondSkill"), Config.FeatureOn("BuildPresets")
		root.Visible = ultOn or skillOn or favOn
		-- ultimate
		local ult = CharacterData.UltimateFor(heroId)
		for _, o in ipairs({ ultCap, ultName, ultText }) do
			o.Visible = ultOn
		end
		ultName.Text = ult.Name
		ultText.Text = ult.Text .. " Charge it with kills, then press ULT (Q)."
		-- second skill
		local skill = CharacterData.SecondSkills[heroId]
		local skillShown = skillOn and skill ~= nil
		for _, o in ipairs({ skillCap, skillName, skillText, skillState }) do
			o.Visible = skillShown
		end
		if skill then
			local heroes = p and type(p.Heroes) == "table" and p.Heroes or {}
			local xp = type(heroes[heroId]) == "table" and heroes[heroId].XP or 0
			local mastery = MetaUpgradeData.MasteryFor(xp)
			local unlocked = owned and mastery >= Config.SecondSkill.Rank
			skillName.Text = skill.Name
			skillText.Text = skill.Text
			skillState.Text = unlocked and "Unlocked: on in every run with this hero." or string.format("Unlocks at mastery rank %d.", Config.SecondSkill.Rank)
			skillState.TextColor3 = unlocked and P.moss_300 or P.gold_200
		end
		-- favourites (owned heroes)
		local favShown = favOn and owned
		favCap.Visible = favShown
		favText.Visible = favShown
		favButton.Instance.Visible = favShown
		grid.Visible = favShown and open
		local fav = HeroPresets.Favourites(heroId)
		local n = #fav.Weapons + #fav.Passives
		favText.Text = n > 0 and string.format("%d marked. Their level-up cards show a %s tag.", n, Config.BuildPresets.Tag)
			or string.format("Mark the weapons and passives you like. Their level-up cards show a %s tag.", Config.BuildPresets.Tag)
		favButton.SetText(open and "DONE" or "FAVOURITES")
		if grid.Visible then
			for id, t in pairs(tiles) do
				local marked = table.find(t.Kind == "Weapons" and fav.Weapons or fav.Passives, id) ~= nil
				t.Stroke.Transparency = marked and 0 or 1
				t.Mark.Visible = marked
			end
		end
	end
	refreshSelf = function()
		refresh(heroNow, lastProfile, lastOwned)
	end

	return {
		Frame = root,
		Refresh = function(heroId: string, p: { [string]: any }?, owned: boolean)
			HeroPresets._Set(p)
			refresh(heroId, p, owned)
		end,
	}
end

return MenuHeroPower
