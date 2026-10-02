--[[
	Theme.lua
	The SWARM look in one place: semantic colours, materials, fonts, sizes, spacing and
	motion for the UI, the world and effects. Colours come from Palette (generated from
	art/palette.json, shared with the Blender models), so models, UI and effects match.

	Art direction (docs/ART_DIRECTION.md): heroic low-poly fantasy. Moss greens, cool stone
	grays, slate blues, crimson and antique gold; ivory text on dark slate panels; gold is
	an accent, not a fill. No neon grass, no rainbow buttons, restrained glow.

	Use Theme.Color.* / Theme.Font.* / Theme.Space.* instead of hard-coded values.
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

	-- text
	Text = Palette.ivory_100,
	TextMuted = Palette.ivory_300,
	TextFaint = Palette.ivory_400,
	TextOnGold = Palette.gold_900,
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
}

-- Transparency levels used across the UI (0 = opaque).
Theme.Alpha = {
	Panel = 0.08, -- panels stay a touch see-through over the 3D scene
	PanelSoft = 0.25, -- secondary panels, HUD plates
	Backdrop = 0.35, -- modal dimmer
	Edge = 0.55, -- thin gold border on panels
	EdgeStrong = 0.1, -- focused / primary border
	Shadow = 0.55, -- soft drop shadow under panels
}

-- Rarity / card tiers (level-up cards, upgrade tiles). Muted, inside the palette.
Theme.Rarity = {
	Common = { Label = "Upgrade", Color = Palette.steel_300, Band = Palette.slate_600 },
	Rare = { Label = "New", Color = Palette.slate_300, Band = Palette.slate_500 },
	Epic = { Label = "Max", Color = Palette.crimson_300, Band = Palette.crimson_700 },
	Legendary = { Label = "Evolution", Color = Palette.gold_300, Band = Palette.gold_600 },
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
}

------------------------------------------------------------------------------------------
-- MOTION
------------------------------------------------------------------------------------------
Theme.Motion = {
	Fast = 0.12,
	Base = 0.22,
	Slow = 0.35,
	Stagger = 0.05, -- delay between items entering one after another
}

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
	Gem = { Small = Palette.gold_300, Medium = Palette.gold_400, Large = Palette.amber_500 },
	PlayerRing = Palette.gold_300, -- marker under the local player
	TeamRing = Palette.slate_300, -- marker under teammates
}

return Theme
