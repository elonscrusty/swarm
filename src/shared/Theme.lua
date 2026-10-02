--[[
	Theme.lua
	The SWARM look in one place: semantic colours, materials, fonts, sizes, spacing and
	motion for the UI, the world and effects. Colours come from Palette (generated from
	art/palette.json, shared with the Blender models), so models, UI and effects match.

	Art direction (docs/ART_DIRECTION.md): heroic low-poly fantasy. Moss greens, cool stone
	grays, slate blues, crimson and antique gold; ivory text on dark slate panels; gold is
	an accent, not a fill. No neon grass, no rainbow buttons, restrained glow.

	Use Theme.Color.* / Theme.Font.* / Theme.Space.* instead of hard-coded values.
	The client UI kit (src/client/UIKit.lua) turns these tokens into components.
]]

local Palette = require(script.Parent.Palette)

local Theme = {}

Theme.Palette = Palette

------------------------------------------------------------------------------------------
-- UI COLOURS
------------------------------------------------------------------------------------------
Theme.Color = {
	-- surfaces
	Backdrop = Palette.slate_950, -- full-screen dimmer behind modals (with transparency)
	Panel = Palette.slate_900, -- standard panel / card
	PanelRaised = Palette.slate_800, -- hovered card, inner wells
	PanelInset = Palette.slate_950, -- bar tracks, input wells
	PanelEdge = Palette.gold_500, -- thin panel border (used with BorderTransparency)
	Divider = Palette.slate_600,
	Shadow = Palette.slate_950, -- soft drop shadows under panels
	Track = Palette.slate_950, -- meter / slider tracks

	-- text
	Text = Palette.ivory_100,
	TextMuted = Palette.ivory_300,
	TextFaint = Palette.ivory_400,
	TextOnGold = Palette.gold_900,
	TextOnGoldMuted = Palette.gold_800,
	TextDanger = Palette.crimson_300,

	-- accents
	Gold = Palette.gold_500,
	GoldLight = Palette.gold_300,
	GoldDark = Palette.gold_700,
	Crimson = Palette.crimson_500,
	CrimsonDark = Palette.crimson_700,
	Slate = Palette.slate_500,
	SlateLight = Palette.slate_300,
	Moss = Palette.moss_400,
	Steel = Palette.steel_300,
	Coin = Palette.gold_400,

	-- primary button (gold gradient, dark text)
	PrimaryTop = Palette.gold_300,
	Primary = Palette.gold_400,
	PrimaryBottom = Palette.gold_600,
	PrimaryEdge = Palette.gold_200,

	-- meters
	Health = Palette.crimson_500,
	HealthLight = Palette.crimson_400,
	HealthTrail = Palette.ivory_200,
	XP = Palette.gold_400,
	XPLight = Palette.gold_300,
	Boss = Palette.crimson_600,
	Heal = Palette.fx_heal,

	-- states
	Locked = Palette.stone_500,
	Success = Palette.moss_300,
	Warning = Palette.gold_400,
	Danger = Palette.crimson_400,
	Disabled = Palette.stone_700, -- face of a disabled button
	DisabledText = Palette.stone_300,
	Selected = Palette.gold_400, -- strong border of the selected card / swatch
	Focus = Palette.gold_300, -- gamepad selection outline
	Hover = Palette.ivory_100, -- light sheen laid over a hovered button
}

-- Transparency levels used across the UI (0 = opaque).
Theme.Alpha = {
	Panel = 0.08, -- panels stay a touch see-through over the 3D scene
	PanelSoft = 0.25, -- secondary panels, HUD plates
	Backdrop = 0.35, -- modal dimmer
	Edge = 0.55, -- thin gold border on panels
	EdgeStrong = 0.1, -- focused / primary border
	Shadow = 0.55, -- soft drop shadow under panels
	Hover = 0.9, -- the light sheen on a hovered button
	Glow = 0.72, -- primary button glow
	Disabled = 0.35, -- icons / text on a disabled control
	Vignette = 0.35, -- strongest point of the menu edge vignette
}

-- Rarity / card tiers (level-up cards, upgrade tiles). Muted, inside the palette.
Theme.Rarity = {
	Common = { Label = "Upgrade", Color = Palette.steel_300, Band = Palette.slate_600 },
	Rare = { Label = "New", Color = Palette.slate_300, Band = Palette.slate_500 },
	Epic = { Label = "Max", Color = Palette.crimson_300, Band = Palette.crimson_700 },
	Legendary = { Label = "Evolution", Color = Palette.gold_300, Band = Palette.gold_600 },
}

-- Run item rarities (ItemData): ivory commons, slate-blue uncommons, gold legendaries.
-- Color = text / border, Band = the darker fill behind badges and tile rims.
Theme.ItemRarity = {
	Common = { Label = "Common", Color = Palette.ivory_200, Band = Palette.stone_600 },
	Uncommon = { Label = "Uncommon", Color = Palette.slate_300, Band = Palette.slate_600 },
	Legendary = { Label = "Legendary", Color = Palette.gold_300, Band = Palette.gold_700 },
}

------------------------------------------------------------------------------------------
-- GRADIENTS (UIGradient colour sequences)
------------------------------------------------------------------------------------------
Theme.Gradient = {
	-- antique gold fill of the one primary button per screen
	Primary = ColorSequence.new({
		ColorSequenceKeypoint.new(0, Palette.gold_200),
		ColorSequenceKeypoint.new(0.45, Palette.gold_400),
		ColorSequenceKeypoint.new(1, Palette.gold_600),
	}),
	-- polished steel: the SWARM logo letters, steel trims
	Steel = ColorSequence.new({
		ColorSequenceKeypoint.new(0, Palette.ivory_100),
		ColorSequenceKeypoint.new(0.55, Palette.steel_200),
		ColorSequenceKeypoint.new(1, Palette.steel_400),
	}),
	-- panels: a faint top-down light so flat slate reads as a surface
	Panel = ColorSequence.new(Palette.slate_800, Palette.slate_900),
	Health = ColorSequence.new(Palette.crimson_400, Palette.crimson_600),
	XP = ColorSequence.new(Palette.gold_300, Palette.gold_500),
	Boss = ColorSequence.new(Palette.crimson_500, Palette.crimson_700),
}

------------------------------------------------------------------------------------------
-- TYPOGRAPHY
-- Display / headings: Merriweather (classic serif, reads as "fantasy" without being
-- hard to read). Body and numbers: Source Sans (clean, compact, legible on phones).
------------------------------------------------------------------------------------------
-- Families come from the built-in enum fonts, so the asset paths are always right.
local MERRI = Font.fromEnum(Enum.Font.Merriweather).Family
local SOURCE = Font.fromEnum(Enum.Font.SourceSans).Family

Theme.Font = {
	Display = Font.new(MERRI, Enum.FontWeight.Heavy),
	Heading = Font.new(MERRI, Enum.FontWeight.Bold),
	Title = Font.new(MERRI, Enum.FontWeight.Bold),
	Body = Font.new(SOURCE, Enum.FontWeight.Regular),
	BodyStrong = Font.new(SOURCE, Enum.FontWeight.SemiBold),
	Label = Font.new(SOURCE, Enum.FontWeight.Bold), -- small caps-style labels (upper case)
	Number = Font.new(SOURCE, Enum.FontWeight.Bold),
}

-- Text sizes in reference pixels (the UI is designed at Config.UI.ReferenceSize and
-- scaled with one UIScale, so these stay proportional on every screen).
Theme.TextSize = {
	Hero = 64, -- logo
	Display = 40, -- run timer, result title
	H1 = 30, -- screen titles, character name
	H2 = 22, -- card titles, button titles
	H3 = 18, -- section headers
	Body = 16,
	Small = 14,
	Caption = 12, -- labels like "BEST TIME"
}

--[[
	Named text roles: one font + size + stroke rule per job, so the same kind of text has the
	same look on every screen (UIKit.Role builds a label from one). Sizes are reference px
	(UIKit.TS adds the phone boost). Stroke = text stroke transparency (nil = no stroke:
	text on a panel); text drawn straight over the 3D world gets a stroke.
	  Display  the run timer, stage banners, big results words      Merriweather Heavy 40
	  Title    panel / tip / boss titles                            Merriweather Bold 22
	  Heading  section and status lines                             Merriweather Bold 18
	  Body     sentences, objectives, toasts                        Source Sans SemiBold 16
	  Label    caps labels, chips, pills, names                     Source Sans Bold 14
	  Number   HUD figures: HP, kills, gold, XP                     Source Sans Bold 18
	  Stat     the big figure of a counter (the gold purse)         Source Sans Bold 30
	  Caption  small print under a figure, badges                   Source Sans Bold 12
]]
Theme.Type = {
	Display = { Font = Theme.Font.Display, Size = Theme.TextSize.Display, Stroke = 0.55 },
	Title = { Font = Theme.Font.Title, Size = Theme.TextSize.H2, Stroke = nil },
	Heading = { Font = Theme.Font.Heading, Size = Theme.TextSize.H3, Stroke = 0.5 },
	Body = { Font = Theme.Font.BodyStrong, Size = Theme.TextSize.Body, Stroke = nil },
	Label = { Font = Theme.Font.Label, Size = Theme.TextSize.Small, Stroke = nil },
	Number = { Font = Theme.Font.Number, Size = Theme.TextSize.H3, Stroke = 0.55 },
	Stat = { Font = Theme.Font.Number, Size = 30, Stroke = 0.45 },
	Caption = { Font = Theme.Font.Label, Size = Theme.TextSize.Caption, Stroke = nil },
}

-- Phones render the reference pixels small (UIScale ~0.77 in landscape, see
-- Config.UI.PhoneReferenceSize), so text there is set this much bigger to stay readable
-- (UIKit applies it; layouts leave room for it).
Theme.TextScaleCompact = 1.2

------------------------------------------------------------------------------------------
-- SPACING, SHAPE, STROKES, SIZES
------------------------------------------------------------------------------------------
Theme.Space = { XS = 4, S = 8, M = 12, L = 16, XL = 24, XXL = 32 }

Theme.Radius = { S = 6, M = 10, L = 14, Pill = 999 }

Theme.Stroke = { Hairline = 1, Thin = 1.5, Medium = 2, Thick = 3 }

Theme.Size = {
	TapMin = 48, -- smallest touch target (reference px)
	Button = 56, -- standard button height
	BigButton = 76, -- SOLO / DUO / TRIO, feature cards
	IconButton = 64, -- square icon buttons (Settings, Stats, Pause)
	Icon = 24,
	IconLarge = 34,
	Tile = 52, -- upgrade bar weapon tile
	TileSmall = 42, -- upgrade bar passive tile
	Chip = 44, -- stat chips, counters
	Badge = 20, -- level badges, small pills
	Slider = 28, -- slider knob
}

-- Screen layout (reference px).
Theme.Layout = {
	Margin = 24, -- screen edge margin
	MarginCompact = 16, -- phones / short screens
	Gutter = 12, -- gap between neighbouring cards / buttons
	MenuColumn = 340, -- width of the menu's left (cards) and right (modes) columns
	Nameplate = Vector2.new(460, 92),
	HudPlate = Vector2.new(420, 66),
}

-- Draw order of the top-level UI layers (ZIndex of root children, Sibling behaviour).
Theme.Z = {
	Hud = 1,
	Lobby = 2,
	Toast = 20,
	Loot = 22, -- item popups, chest / shrine prompts
	Chest = 25,
	LevelUp = 30,
	Pause = 40,
	Revive = 45,
	Results = 50,
	Dev = 60,
}

------------------------------------------------------------------------------------------
-- MOTION
------------------------------------------------------------------------------------------
Theme.Motion = {
	Fast = 0.12,
	Base = 0.22,
	Slow = 0.35,
	Stagger = 0.05, -- delay between items entering one after another
	PressScale = 0.96, -- buttons shrink to this while pressed
	HoverLift = 2, -- px a hovered button rises
}

------------------------------------------------------------------------------------------
-- ICONS (src/client/Icons.lua draws them on this grid)
------------------------------------------------------------------------------------------
Theme.Icon = {
	Grid = 24, -- icons are designed on a 24 x 24 grid and scale to any size
	Stroke = 2.6, -- line weight in grid units (same for every icon)
	Main = Palette.ivory_100, -- default glyph colour
	Accent = Palette.gold_400, -- default second colour
	Back = Palette.slate_900, -- colour of cut-outs (eyes, visors, holes)
}

--[[
	Brings any colour into the palette's mood: keeps its hue (so items stay recognisable)
	but caps the saturation and settles the brightness. Used for item colours that come
	from the data modules (weapons, passives, server messages), which are much brighter.
]]
function Theme.Tint(color: Color3, maxSaturation: number?, value: number?): Color3
	local h, s, v = color:ToHSV()
	if s < 0.08 then
		-- greys and whites become warm ivory / steel
		return Palette.ivory_200:Lerp(Palette.steel_400, math.clamp(1 - v, 0, 1))
	end
	return Color3.fromHSV(h, math.min(s, maxSaturation or 0.55), value or math.clamp(v, 0.62, 0.86))
end

------------------------------------------------------------------------------------------
-- WORLD MATERIAL RULES (used by MapBuilder / effects)
------------------------------------------------------------------------------------------
-- Clean faceted look: SmoothPlastic almost everywhere, Metal for armour and blades,
-- Neon only for small glowing bits (eyes, gems, flames). Never Neon for big surfaces.
Theme.Material = {
	Default = Enum.Material.SmoothPlastic,
	Metal = Enum.Material.Metal,
	Glow = Enum.Material.Neon,
	Glass = Enum.Material.Glass,
	Wood = Enum.Material.SmoothPlastic, -- wood reads through colour, not texture
	Stone = Enum.Material.SmoothPlastic,
}

------------------------------------------------------------------------------------------
-- EFFECT COLOURS (attack trails, impacts, pickups)
------------------------------------------------------------------------------------------
Theme.Fx = {
	Slash = Palette.fx_ivory,
	SlashEdge = Palette.fx_gold,
	Spark = Palette.fx_gold,
	Hit = Palette.fx_ivory,
	Heal = Palette.fx_heal,
	Arcane = Palette.fx_arcane,
	Holy = Palette.fx_holy,
	Fire = Palette.fx_fire,
	Bolt = Palette.fx_bolt,
	Gold = Palette.gold_300,
	Danger = Palette.crimson_400,
	-- XP gems are bright, saturated azure / royal blue / violet crystals that pop on the
	-- grass, sand and snow (never gold: gold means coins, and never the red / orange / green
	-- of enemy attacks); Glow = the faint floor disc
	Gem = {
		Small = Color3.fromRGB(28, 156, 255),
		Medium = Color3.fromRGB(40, 92, 255),
		Large = Color3.fromRGB(160, 72, 255),
		Glow = Color3.fromRGB(40, 170, 255),
		Core = Palette.ivory_100,
	},
	Coin = Palette.gold_500, -- gold coins (GoldCoin / GoldPile meshes, part fallback)
	PlayerRing = Palette.gold_300, -- marker under the local player
	TeamRing = Palette.slate_300, -- marker under teammates
}

return Theme
