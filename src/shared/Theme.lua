--[[
	Theme.lua
	The SWARM look in one place: semantic colours, materials, fonts, sizes, spacing and
	motion for the UI, the world and effects. Colours come from Palette (generated from
	art/palette.json, shared with the Blender models), so models, UI and effects match.

	World art direction (docs/ART_DIRECTION.md): heroic low-poly fantasy. The UI follows
	the owner's "Bright Arcade" reference pack (2026-10-08, docs/UI_BRIGHT_ARCADE.md): icy-white
	panels with royal blue borders and a blue drop shadow, navy text, chunky rounded type,
	yellow for the one main action, lime for selected states, red for leave / destructive.

	Use Theme.Color.* / Theme.Font.* / Theme.Space.* instead of hard-coded values.
	The client UI kit (src/client/UIKit.lua) turns these tokens into components.
]]

local Palette = require(script.Parent.Palette)

local Theme = {}

Theme.Palette = Palette

------------------------------------------------------------------------------------------
-- BRIGHT ARCADE TOKENS (owner's 2026-10-08 UI reference pack)
-- Icy-white panels, royal blue borders, navy text, sunny yellow main actions, lime
-- selected states. Gold coins and character art keep their own colours.
------------------------------------------------------------------------------------------
local hex = Color3.fromHex
local A = {
	PanelTop = hex("#FFFFFF"),
	PanelBottom = hex("#E8F6FF"),
	CardFill = hex("#F5FBFF"),
	Blue = hex("#087FFF"),
	BlueLight = hex("#39C8FF"),
	BlueDeep = hex("#1744CD"),
	BluePale = hex("#CDE9FF"),
	Shadow = hex("#082D9C"),
	Text = hex("#08164E"),
	TextSecondary = hex("#455F9D"),
	PrimaryTop = hex("#FFF35A"),
	PrimaryBottom = hex("#FFD21C"),
	PrimaryEdge = hex("#E8A90B"),
	Selected = hex("#BBF52B"),
	SelectedDeep = hex("#5E9E00"),
	SelectedPale = hex("#EAFACB"),
	Danger = hex("#E65050"),
	DangerDeep = hex("#B42A2A"),
	DisabledFill = hex("#D8E3EE"),
	DisabledText = hex("#778AA5"),
	Track = hex("#C9DDF2"),
	Divider = hex("#B9D7F2"),
	Coin = hex("#FFC21C"),
	CoinDeep = hex("#C98A00"),
}
Theme.Arcade = A

-- Icon badge fills (UIKit.IconBadge): simple white glyphs on a few bright, friendly
-- colours so each option reads at a glance (one colour per kind of thing, not per screen).
Theme.IconTint = {
	Blue = hex("#2E8BFF"),
	Green = hex("#3CC25A"),
	Red = hex("#F2575A"),
	Purple = hex("#9A5BF0"),
	Orange = hex("#FF9F1C"),
	Teal = hex("#1FC4C4"),
	Gold = hex("#F2B705"),
	Navy = hex("#2A3F8F"),
}

------------------------------------------------------------------------------------------
-- UI COLOURS (semantic: screens use these, never raw values)
------------------------------------------------------------------------------------------
Theme.Color = {
	-- surfaces
	Backdrop = A.Text, -- full-screen dimmer behind modals (with transparency)
	Panel = A.PanelTop, -- standard panel / card
	PanelRaised = A.CardFill, -- hovered card, inner wells
	PanelInset = A.PanelBottom, -- bar tracks, input wells
	PanelEdge = A.Blue, -- panel / card border
	Divider = A.Divider,
	Shadow = A.Shadow, -- the blue drop shadow under panels
	Track = A.Track, -- meter / slider tracks

	-- text
	Text = A.Text,
	TextMuted = A.TextSecondary,
	TextFaint = A.DisabledText,
	TextOnGold = A.Text, -- navy on the yellow main action
	TextOnGoldMuted = hex("#6B5310"),
	TextDanger = A.DangerDeep,
	TextOnBlue = A.PanelTop, -- white on blue plates (title tabs, badges)

	-- accents (the old gold accent names now point at the arcade blues)
	Gold = A.Blue,
	GoldLight = A.BlueDeep,
	GoldDark = A.Shadow,
	Blue = A.Blue,
	BlueLight = A.BlueLight,
	BlueDeep = A.BlueDeep,
	BluePale = A.BluePale,
	Crimson = A.Danger,
	CrimsonDark = A.DangerDeep,
	Slate = A.TextSecondary,
	SlateLight = A.BlueLight,
	Moss = A.SelectedDeep,
	Steel = A.TextSecondary,
	Coin = A.Coin,
	CoinDeep = A.CoinDeep,

	-- primary button (sunny yellow gradient, navy text)
	PrimaryTop = A.PrimaryTop,
	Primary = A.PrimaryBottom,
	PrimaryBottom = A.PrimaryBottom,
	PrimaryEdge = A.PrimaryEdge,

	-- meters
	Health = Palette.crimson_500,
	HealthLight = Palette.crimson_400,
	HealthTrail = Palette.ivory_200,
	XP = A.Blue,
	XPLight = A.BlueLight,
	Boss = Palette.crimson_600,
	Heal = Palette.fx_heal,

	-- states
	Locked = A.DisabledText,
	Success = A.SelectedDeep,
	Warning = A.PrimaryEdge,
	Danger = A.Danger,
	Disabled = A.DisabledFill, -- face of a disabled button
	DisabledText = A.DisabledText,
	Selected = A.Selected, -- lime: selected tab / card (always with a check or label)
	SelectedPale = A.SelectedPale,
	SelectedEdge = A.SelectedDeep,
	Focus = A.BlueLight, -- gamepad selection outline
	Hover = A.PanelTop, -- light sheen laid over a hovered button
}

-- Transparency levels used across the UI (0 = opaque).
Theme.Alpha = {
	Panel = 0, -- panels are solid icy white
	PanelSoft = 0.08, -- secondary panels, HUD plates
	Backdrop = 0.55, -- modal dimmer (navy, light enough to keep the world recognisable)
	Edge = 0, -- blue panel borders are solid
	EdgeStrong = 0,
	Shadow = 0.25, -- the blue drop shadow under panels
	Hover = 0.85, -- the light sheen on a hovered button
	Glow = 0.72, -- primary button glow
	Disabled = 0.35, -- icons / text on a disabled control
	Vignette = 0.6, -- strongest point of the menu edge vignette
}

-- Rarity / card tiers (level-up cards, upgrade tiles), readable on white.
Theme.Rarity = {
	Common = { Label = "Upgrade", Color = A.TextSecondary, Band = A.BluePale },
	Rare = { Label = "New", Color = A.Blue, Band = A.BluePale },
	Epic = { Label = "Max", Color = A.DangerDeep, Band = hex("#FFD9D9") },
	Legendary = { Label = "Evolution", Color = A.CoinDeep, Band = A.PrimaryBottom },
}

-- Run item rarities (ItemData): grey-blue commons, blue uncommons, gold legendaries.
-- Color = text / border, Band = the lighter fill behind badges and tile rims.
Theme.ItemRarity = {
	Common = { Label = "Common", Color = A.TextSecondary, Band = A.DisabledFill },
	Uncommon = { Label = "Uncommon", Color = A.Blue, Band = A.BluePale },
	Legendary = { Label = "Legendary", Color = A.CoinDeep, Band = hex("#FFE680") },
}

------------------------------------------------------------------------------------------
-- GRADIENTS (UIGradient colour sequences)
------------------------------------------------------------------------------------------
Theme.Gradient = {
	-- sunny yellow fill of the one primary button per screen
	Primary = ColorSequence.new({
		ColorSequenceKeypoint.new(0, A.PrimaryTop),
		ColorSequenceKeypoint.new(1, A.PrimaryBottom),
	}),
	-- polished steel: the SWARM logo letters, steel trims
	Steel = ColorSequence.new({
		ColorSequenceKeypoint.new(0, Palette.ivory_100),
		ColorSequenceKeypoint.new(0.55, Palette.steel_200),
		ColorSequenceKeypoint.new(1, Palette.steel_400),
	}),
	-- panels: white at the top, icy blue at the bottom
	Panel = ColorSequence.new(A.PanelTop, A.PanelBottom),
	-- lime selected state
	Selected = ColorSequence.new(hex("#D6FF6A"), A.Selected),
	-- blue title tab / secondary plates
	Blue = ColorSequence.new(A.BlueLight, A.Blue),
	Health = ColorSequence.new(Palette.crimson_400, Palette.crimson_600),
	XP = ColorSequence.new(A.BlueLight, A.Blue),
	Boss = ColorSequence.new(Palette.crimson_500, Palette.crimson_700),
}

------------------------------------------------------------------------------------------
-- TYPOGRAPHY
-- Display / titles / buttons: Fredoka One (chunky, rounded, upright). Body and small
-- labels: Nunito (rounded sans, readable on phones). Two families only.
------------------------------------------------------------------------------------------
-- Families come from the built-in enum fonts, so the asset paths are always right.
local FREDOKA = Font.fromEnum(Enum.Font.FredokaOne).Family
local NUNITO = Font.fromEnum(Enum.Font.Nunito).Family

Theme.Font = {
	Display = Font.new(FREDOKA, Enum.FontWeight.Regular),
	Heading = Font.new(FREDOKA, Enum.FontWeight.Regular),
	Title = Font.new(FREDOKA, Enum.FontWeight.Regular),
	Body = Font.new(NUNITO, Enum.FontWeight.SemiBold),
	BodyStrong = Font.new(NUNITO, Enum.FontWeight.Bold),
	Label = Font.new(NUNITO, Enum.FontWeight.ExtraBold), -- small caps labels, chips, badges
	Number = Font.new(FREDOKA, Enum.FontWeight.Regular),
}

-- Text sizes in reference pixels (the UI is designed at Config.UI.ReferenceSize and
-- scaled with one UIScale, so these stay proportional on every screen).
Theme.TextSize = {
	Hero = 64, -- logo
	Display = 40, -- run timer, page titles, result title
	H1 = 32, -- screen titles, character name
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
	  Display  the run timer, stage banners, big results words      Fredoka One 40
	  Title    panel / tip / boss titles                            Fredoka One 22
	  Heading  section and status lines                             Fredoka One 18
	  Body     sentences, objectives, toasts                        Nunito Bold 16
	  Label    caps labels, chips, pills, names                     Nunito ExtraBold 14
	  Number   HUD figures: HP, kills, gold, XP                     Fredoka One 18
	  Stat     the big figure of a counter (the gold purse)         Fredoka One 30
	  Caption  small print under a figure, badges                   Nunito ExtraBold 12
]]
Theme.Type = {
	Display = { Font = Theme.Font.Display, Size = Theme.TextSize.Display, Stroke = nil },
	Title = { Font = Theme.Font.Title, Size = Theme.TextSize.H2, Stroke = nil },
	Heading = { Font = Theme.Font.Heading, Size = Theme.TextSize.H3, Stroke = nil },
	Body = { Font = Theme.Font.BodyStrong, Size = Theme.TextSize.Body, Stroke = nil },
	Label = { Font = Theme.Font.Label, Size = Theme.TextSize.Small, Stroke = nil },
	Number = { Font = Theme.Font.Number, Size = Theme.TextSize.H3, Stroke = nil },
	Stat = { Font = Theme.Font.Number, Size = 30, Stroke = nil },
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

Theme.Radius = { S = 8, M = 14, L = 20, Pill = 999 }

Theme.Stroke = { Hairline = 1, Thin = 2, Medium = 3, Thick = 4 }

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
	Main = A.Text, -- default glyph colour (navy on white panels)
	Accent = A.Blue, -- default second colour
	Back = A.PanelTop, -- colour of cut-outs (eyes, visors, holes)
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
