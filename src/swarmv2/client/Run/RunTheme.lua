--!strict
--[[
	SwarmV2/Run/RunTheme.lua  (StarterPlayerScripts.SwarmV2Client.Run.RunTheme)
	OWNER: stream F (run UI).

	The brief's colour tokens for the run HUD and the run screens (docs/redesign/continuation,
	"Visual system and screen behavior"): navy #162438 opaque panels, cream #FFF3DC primary
	text, gold #EFC46E main actions, cyan #65DDE0 selection / focus. No Roblox services, so a
	test can read it; the existing Theme / UIKit / TextFit helpers stay in use for everything
	else (fonts, type roles, scale, the phone text boost).

	Rules the HUD follows with these:
	  * a panel is opaque (Alpha <= 0.08) so text stays readable over any scenery
	  * errors and states carry an icon or a word as well as a colour (rarity, danger, ready)
	  * body text 18 px desktop / 16 px phone minimum, touch targets 48 px minimum
]]

local hex = Color3.fromHex

local RunTheme = {}

-- surfaces
RunTheme.Navy = hex("#162438") -- opaque panel background
RunTheme.NavyDeep = hex("#0E1A2B") -- wells, bar tracks
RunTheme.NavyRaised = hex("#1F3350") -- inner cards, hover
RunTheme.NavyEdge = hex("#35527A") -- quiet panel edge
RunTheme.Scrim = hex("#08111D") -- dark plate behind text drawn over the world

-- text
RunTheme.Cream = hex("#FFF3DC") -- primary text
RunTheme.CreamMuted = hex("#C7BBA3") -- secondary text (still > 7:1 on Navy)
RunTheme.CreamFaint = hex("#8E8573") -- disabled / quiet (never the only carrier of a state)

-- actions + focus
RunTheme.Gold = hex("#EFC46E") -- the main action, evolution mark, coins
RunTheme.GoldDeep = hex("#B88A2C")
RunTheme.OnGold = hex("#162438") -- text on gold
RunTheme.Cyan = hex("#65DDE0") -- selection and focus
RunTheme.CyanDeep = hex("#2C9DA3")

-- state colours (always paired with a word or a symbol)
RunTheme.Danger = hex("#F1735E")
RunTheme.DangerDeep = hex("#B8392B")
RunTheme.Health = hex("#E5584B")
RunTheme.HealthTrail = hex("#F6C4A8")
RunTheme.Good = hex("#8EDB7B")
RunTheme.Warn = hex("#F2B544")

-- rarity (symbol + word are the real carrier; this is garnish)
RunTheme.Rarity = {
	Common = hex("#C7BBA3"),
	Uncommon = hex("#8EDB7B"),
	Rare = hex("#65DDE0"),
	Epic = hex("#C99BFF"),
	Evolution = hex("#EFC46E"),
} :: { [string]: Color3 }

-- sizes (design px; UIKit.TS adds the phone boost, so these are the desktop values)
RunTheme.Size = {
	ScreenTitle = 38,
	Section = 24,
	Body = 18,
	BodyPhone = 16, -- floor for phone body text, as physical points
	Caption = 14,
	TouchMin = 48,
	MainAction = 56,
	MarginDesktop = 24,
	MarginPhone = 12,
}

-- panels: how opaque is opaque enough
RunTheme.PanelAlpha = 0 -- opaque: the HUD pieces underneath never show through a panel
RunTheme.Radius = { Small = 8, Panel = 12, Pill = 999 }

-- Perceived brightness of a colour (0..1), for contrast checks in tests.
function RunTheme.Luma(c: Color3): number
	local function lin(v: number): number
		return if v <= 0.03928 then v / 12.92 else ((v + 0.055) / 1.055) ^ 2.4
	end
	return 0.2126 * lin(c.R) + 0.7152 * lin(c.G) + 0.0722 * lin(c.B)
end

-- WCAG contrast ratio of two colours.
function RunTheme.Contrast(a: Color3, b: Color3): number
	local la, lb = RunTheme.Luma(a), RunTheme.Luma(b)
	local hi, lo = math.max(la, lb), math.min(la, lb)
	return (hi + 0.05) / (lo + 0.05)
end

return RunTheme
