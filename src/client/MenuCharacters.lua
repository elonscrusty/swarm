--[[
	MenuCharacters.lua
	The CHARACTERS screen of the menu. The inspected hero stands on the dais in the middle
	of the 3D scene (Showcase), so the screen is two panels around it and nothing covers it:
	  top     a compact BACK and the spaced serif title "C H A R A C T E R S" over a gold
	          rule (UIKit.TitleBar) in the Roblox top-bar row; LobbyScreen shows the BEST /
	          WINS / GOLD stats inline on the right
	  left    the roster: one row per character (hero badge art, serif name), rows split by
	          thin lines; the selected hero shows a gold check and SELECTED, locked heroes a
	          lock, the inspected one a gold border, a gold accent bar and a PREVIEW pill
	  centre  under the hero: its name in spaced caps between gold rules and
	          "Preview • <skin>"
	  right   framed portrait (art/portraits, drawn class icon as stand-in), the name, a
	          status pill (SELECTED / OWNED / LOCKED with a lock), role in gold caps, the
	          intro line; a rule; STARTING WEAPON (tile) | TRAIT (green badge); EFFECT (a big
	          gold "+20%" when the trait text starts with one, the rest, the weapon list),
	          STRENGTH, TRADEOFF (red); for a locked hero the UNLOCK block (achievement and
	          big "2 / 4" with a gold bar, or the gold price); for an OWNED hero the same
	          spot is the MASTERY block (Hero Mastery: level, XP "120 / 350" with a gold bar,
	          the cap it allows, and UPGRADE <HERO>, which opens the hero's upgrade list
	          right there: seven rows (icon, LV n / max, "current → next", BUY · N /
	          LOCKED: MASTERY N / MAXED / BUYING... until the next ProfileSync), so phones
	          scroll it and portrait shows it under the hero); the action button (gold
	          SELECT <NAME> / UNLOCK • N GOLD, grey "REACH STAGE 4 TO UNLOCK"); SKINS: skin
	          cards (swatch, name, OWNED / SKIN EQUIPPED / SOON / R$ pill, a check on the
	          equipped one) and, for a skin not owned, its GET SKIN / COMING SOON button
	Phones in landscape: the roster turns into two columns of tiles when rows get too short;
	when the details don't fit, the action button is pinned at the bottom of the panel.
	Portrait: character tabs on top (two rows of four), the hero in between, the details
	panel below.

	Tapping a skin only previews it on the dais; the separate action equips or buys it.
	Server: BuyCharacter / SelectCharacter / EquipSkin (GoldSystem validates everything),
	skin passes through MarketplaceService.
]]

local Players = game:GetService("Players")
local MarketplaceService = game:GetService("MarketplaceService")

local Shared = game:GetService("ReplicatedStorage"):WaitForChild("Shared")
local Config = require(Shared:WaitForChild("Config"))
local Remotes = require(Shared:WaitForChild("Remotes"))
local Theme = require(Shared:WaitForChild("Theme"))
local CharacterData = require(Shared:WaitForChild("CharacterData"))
local WeaponData = require(Shared:WaitForChild("WeaponData"))
local AchievementData = require(Shared:WaitForChild("AchievementData"))
local MetaUpgradeData = require(Shared:WaitForChild("MetaUpgradeData"))
local UIKit = require(script.Parent.UIKit)
local UIAnim = require(script.Parent.UIAnim)
local Icons = require(script.Parent.Icons)
local StarterCard = require(script.Parent.StarterCard)
local Showcase = require(script.Parent.Showcase)
local MenuHeroPower = require(script.Parent.MenuHeroPower)
local MenuPrestige = require(script.Parent.MenuPrestige) -- Prestige stars (docs/next/PRESTIGE.md)

local MenuCharacters = {}

local player = Players.LocalPlayer
local new, text, TS = UIKit.new, UIKit.text, UIKit.TS
local C, P = Theme.Color, Theme.Palette
local DETAIL_HEADING = Theme.Font.Heading

-- A hero name shrinks to fit its row / tile ("Necromancer" in a narrow portrait tab, or a large
-- Roblox Text size setting) instead of being cut to "Necroma..." (docs/MOBILE_FIX.md).
local function fitName(label: TextLabel, size: number)
	label.TextSize = size
	label.TextScaled = true
	label:SetAttribute("NoTextFit", true)
	local tf = label:FindFirstChild("TextFit")
	if tf then
		tf:Destroy()
	end
	local fit = label:FindFirstChild("Fit") :: UITextSizeConstraint?
	if not fit then
		local c = Instance.new("UITextSizeConstraint")
		c.Name = "Fit"
		c.Parent = label
		fit = c
	end
	if fit then
		fit.MaxTextSize = size
		fit.MinTextSize = math.min(size, 9)
	end
end

local function unfitName(label: TextLabel, size: number)
	label.TextScaled = false
	label.TextSize = size
	label:SetAttribute("NoTextFit", nil)
	local fit = label:FindFirstChild("Fit")
	if fit then
		fit:Destroy()
	end
end

local ACTION_H = 46 -- the SELECT / UNLOCK button
local PORTRAIT = 84 -- framed portrait in the details head
local SKIN_GAP = 8
local STICKY_H = 30 -- the PREVIEW / EQUIPPED strip on top of the details panel

local function place(obj: GuiObject, x: number, y: number, w: number, h: number)
	obj.Position = UDim2.fromOffset(math.floor(x + 0.5), math.floor(y + 0.5))
	obj.Size = UDim2.fromOffset(math.floor(w + 0.5), math.floor(h + 0.5))
end

local function skinPassId(skinId: string): number?
	local skin = CharacterData.Skins[skinId]
	if not skin then
		return nil
	end
	local id = skin.Pass == "StarterPack" and Config.Monetization.GamePasses.StarterPack or Config.Monetization.SkinPasses[skinId]
	if id and id ~= 0 then
		return id
	end
	return nil
end

local function skinName(skinId: string): string
	local skin = CharacterData.Skins[skinId]
	return skin and skin.Name or "Default"
end

-- Short goal for the locked button: the achievement's first clause when it is short
-- ("Reach stage 4"), else nil (the button names the achievement instead).
local function shortGoal(a: { [string]: any }?): string?
	if not a then
		return nil
	end
	local desc = tostring(a.Description or "")
	local first = string.match(desc, "^([^:%.]+)") or desc
	first = string.gsub(first, " in one run$", "")
	if #first > 0 and #first <= 22 then
		return first
	end
	return nil
end

-- "+30 → +40 max HP": a hero upgrade's total effect now and after one more level, the
-- shared words written once (Effect.Format is "<number part> <words>").
local function effectStep(heroId: string, upgradeId: string, level: number, maxed: boolean): string
	local def = MetaUpgradeData.HeroDef(heroId, upgradeId)
	if not def or not def.Effect then
		return ""
	end
	local function value(l: number): number
		if upgradeId == "Signature" then
			return def.Trait.Base + def.Trait.Per * l
		end
		return def.Effect.Per * l
	end
	local numberPart, words = string.match(def.Effect.Format, "^(%S+)%s+(.+)$")
	if not numberPart then
		return MetaUpgradeData.HeroEffectText(heroId, upgradeId, level)
	end
	-- nothing bought yet reads like the account upgrades ("None yet"), not "+0% → +5%"
	if level <= 0 and upgradeId ~= "Signature" and not maxed then
		return "Next: " .. string.format(numberPart, value(1)) .. " " .. words
	end
	local now = string.format(numberPart, value(level))
	if maxed then
		return now .. " " .. words .. " (max)"
	end
	return now .. " → " .. string.format(numberPart, value(level + 1)) .. " " .. words
end

-- The trait sentence with the hero's current value (Hero Mastery: base + Signature level),
-- e.g. "Takes 14% less damage" at Iron Skin level 2. The Ranger's "+10% other weapons"
-- scales with the Longbow number the way WeaponSystem does.
local function currentTraitText(heroId: string, textIn: string, level: number): string
	local sig = MetaUpgradeData.Signature[heroId]
	if not sig or level <= 0 then
		return textIn
	end
	local base = sig.Trait.Base
	local now = base + sig.Trait.Per * level
	local out, n = string.gsub(textIn, "%f[%d]" .. base .. "%%", now .. "%%", 1)
	if n > 0 then
		local steady = CharacterData.Characters[heroId] and CharacterData.Characters[heroId].SteadyAim
		if steady and steady.OtherDamage then
			local other = math.floor(steady.OtherDamage * 100 + 0.5)
			local otherNow = math.floor(steady.OtherDamage * now / base * 100 + 0.5)
			out = string.gsub(out, "%(%+" .. other .. "%%", "(+" .. otherNow .. "%%", 1)
		end
	end
	return out
end

-- the same sentence for a profile (the home hero card uses it so both screens agree)
function MenuCharacters.TraitText(heroId: string, textIn: string, p: { [string]: any }?): string
	local level = 0
	if p and type(p.OwnedCharacters) == "table" and p.OwnedCharacters[heroId] == true and type(p.HeroUpgrades) == "table" and type(p.HeroUpgrades[heroId]) == "table" then
		level = math.floor(tonumber(p.HeroUpgrades[heroId].Signature) or 0)
	end
	return currentTraitText(heroId, textIn, level)
end

-- Trait text split for the EFFECT row: a leading "+N%" (big number, or nil), the rest as
-- a sentence, and the weapon list after a colon (" • " separated, or nil).
local function splitEffect(s: string): (string?, string, string?)
	local big, rest = string.match(s, "^(%+%d+%%)%s+(.+)$")
	local body = rest or s
	local main, list = string.match(body, "^(.-):%s+(.+)$")
	if main and list then
		list = string.gsub(list, "%.$", "")
		list = string.gsub(list, ",%s*", "  ·  ")
		body = main .. "."
	else
		list = nil
	end
	if big then
		body = string.upper(string.sub(body, 1, 1)) .. string.sub(body, 2)
	end
	return big, body, list
end

function MenuCharacters.Build(screen: Frame, ctx: { [string]: any })
	local host = ctx.Host
	local ui: { [string]: any } = {}
	local inspChar = CharacterData.Default
	local inspSkin = "Default"

	local function profile(): { [string]: any }?
		return ctx.Profile()
	end
	local function skinOwned(p, skinId: string): boolean
		return skinId == "Default" or p.OwnedSkins[skinId] == true
	end
	-- the hero's skins; one of a held feature (Starter Bundle skin) is left out while its
	-- switch is off, unless the player already owns it
	local function visibleSkins(): { string }
		local p = profile()
		local out = {}
		for _, skinId in ipairs(CharacterData.SkinsFor(inspChar)) do
			local feature = skinId ~= "Default" and CharacterData.Skins[skinId] and (CharacterData.Skins[skinId] :: any).Feature
			if not feature or Config.FeatureOn(feature) or (p ~= nil and skinOwned(p, skinId)) then
				table.insert(out, skinId)
			end
		end
		return out
	end

	ui.Header = UIKit.TitleBar(screen, "Characters", ctx.Back)

	------------------------------------------------------------------------------------
	-- left: the roster (landscape) / tabs (portrait)
	------------------------------------------------------------------------------------
	local listHolder, listFace = UIKit.Surface(screen, { Name = "List", Radius = Theme.Radius.L })
	ui.List = listHolder
	UIKit.padding(listFace, 10, 10, 10, 10)
	ui.ListLayout = UIKit.list(listFace, { Padding = UDim.new(0, 0) })
	ui.Rows = {}
	for i, id in ipairs(CharacterData.Order) do
		local def = CharacterData.Characters[id]
		local hit = new("TextButton", {
			Name = id,
			Text = def.Name, -- invisible: tools / a11y find the row by it
			TextTransparency = 1,
			AutoButtonColor = false,
			BackgroundColor3 = C.PanelRaised,
			BackgroundTransparency = 1,
			BorderSizePixel = 0,
			Size = UDim2.new(1, 0, 0, 64),
			LayoutOrder = i,
		}, listFace)
		UIKit.corner(hit, Theme.Radius.M)
		UIKit.Focusable(hit)
		local edge = UIKit.stroke(hit, C.PanelEdge, 2, 1)
		local accent = new("Frame", { Name = "Accent", BackgroundColor3 = C.BlueDeep, BorderSizePixel = 0, Position = UDim2.fromOffset(0, 6), Size = UDim2.new(0, 4, 1, -12), Visible = false, ZIndex = 3 }, hit)
		UIKit.corner(accent, 2)
		local sep = UIKit.Hairline(hit, { Name = "Sep", AnchorPoint = Vector2.new(0, 1), Position = UDim2.new(0, 8, 1, 0), Size = UDim2.new(1, -16, 0, 1), BackgroundTransparency = 0 })
		local icon = Icons.Character(hit, id, { Size = 46, AnchorPoint = Vector2.new(0, 0.5), Position = UDim2.new(0, 12, 0.5, 0) })
		local name = text(hit, "H2", def.Name, { Name = "CharName", TextTruncate = Enum.TextTruncate.AtEnd, TextColor3 = C.Text }, Theme.TextSize.H2)
		-- right side marks: check + EQUIPPED, lock, PREVIEW
		local marks = new("Frame", { Name = "Marks", BackgroundTransparency = 1, AnchorPoint = Vector2.new(1, 0.5), Position = UDim2.new(1, -10, 0.5, 0), Size = UDim2.new(0, 170, 1, 0) }, hit)
		UIKit.list(marks, { FillDirection = Enum.FillDirection.Horizontal, HorizontalAlignment = Enum.HorizontalAlignment.Right, VerticalAlignment = Enum.VerticalAlignment.Center, Padding = UDim.new(0, 8) })
		local check = Icons.Draw(marks, "check", { Size = 20, Color = C.SelectedEdge, Back = C.Panel })
		check.LayoutOrder = 1
		local equipped = text(marks, "Label", "SELECTED", { Name = "Equipped", LayoutOrder = 2, Size = UDim2.fromOffset(0, TS(13) + 4), AutomaticSize = Enum.AutomaticSize.X, TextColor3 = C.SelectedEdge }, 13)
		local lock = Icons.Draw(marks, "lock", { Size = 18, Color = C.DisabledText, Back = C.Panel })
		lock.LayoutOrder = 3
		local preview = UIKit.StatusPill(marks, "PREVIEW", { LayoutOrder = 4, Size = UDim2.fromOffset(0, TS(11) + 12) })
		preview.TextSize = TS(11)
		UIKit.SetStatus(preview, "PREVIEW")
		preview.TextColor3 = C.BlueDeep
		preview.BackgroundColor3 = C.BluePale
		local pe = preview:FindFirstChild("StatusEdge") :: UIStroke?
		if pe then
			pe.Color = C.PanelEdge
			pe.Transparency = 0
		end
		UIAnim.Button(hit)
		hit.MouseEnter:Connect(function()
			if inspChar ~= id then
				hit.BackgroundTransparency = 0.5
			end
		end)
		hit.MouseLeave:Connect(function()
			if inspChar ~= id then
				hit.BackgroundTransparency = 1
			end
		end)
		hit.Activated:Connect(function()
			UIKit.Click()
			UIAnim.Bump(icon, 0.15)
			MenuCharacters._inspect(id)
		end)
		ui.Rows[id] = { Instance = hit, Edge = edge, Accent = accent, Sep = sep, Icon = icon, Name = name, Marks = marks, Check = check, Equipped = equipped, Lock = lock, Preview = preview, Mode = "" }
	end

	------------------------------------------------------------------------------------
	-- centre: the hero's name under the dais
	------------------------------------------------------------------------------------
	ui.Centre = new("Frame", { Name = "HeroName", BackgroundTransparency = 1, Size = UDim2.fromOffset(420, 60) }, screen)
	ui.CentreTitle = UIKit.TitleRule(ui.Centre, "", { Position = UDim2.fromOffset(0, 0) }, Theme.TextSize.H3 + 2)
	ui.CentreTitle.Title.FontFace = Theme.Font.Display
	UIKit.PageTitleStyle(ui.CentreTitle.Title, 2)
	ui.CentreSub = text(ui.Centre, "Body", "", { Name = "Preview", AnchorPoint = Vector2.new(0.5, 1), Position = UDim2.fromScale(0.5, 1), Size = UDim2.fromOffset(0, TS(15) + 8), AutomaticSize = Enum.AutomaticSize.X, TextXAlignment = Enum.TextXAlignment.Center, TextColor3 = C.Text, BackgroundColor3 = C.Panel, BackgroundTransparency = 0 }, 15)
	UIKit.corner(ui.CentreSub, 999)
	UIKit.padding(ui.CentreSub, 0, 14, 0, 14)
	UIKit.stroke(ui.CentreSub, C.PanelEdge, 2, 0)

	------------------------------------------------------------------------------------
	-- right: details
	------------------------------------------------------------------------------------
	local detailHolder, detailFace = UIKit.Surface(screen, { Name = "Details", Radius = Theme.Radius.L })
	ui.Detail = detailHolder
	local scroll = new("ScrollingFrame", {
		Name = "Scroll",
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		Position = UDim2.fromOffset(0, STICKY_H),
		Size = UDim2.new(1, 0, 1, -STICKY_H),
		ScrollBarThickness = 5,
		ScrollBarImageColor3 = C.PanelEdge,
		AutomaticCanvasSize = Enum.AutomaticSize.Y,
		CanvasSize = UDim2.new(),
		ScrollingDirection = Enum.ScrollingDirection.Y,
	}, detailFace)
	UIKit.padding(scroll, 20, 20, 20, 20)
	ui.DetailList = UIKit.list(scroll, { Padding = UDim.new(0, 12), HorizontalAlignment = Enum.HorizontalAlignment.Left })
	ui.Scroll = scroll
	-- sticky strip over the scrolling details: which hero this panel is about (PREVIEW vs
	-- EQUIPPED) and whose upgrades the rows below buy, so it stays clear while scrolling
	ui.Sticky = new("Frame", { Name = "Sticky", BackgroundColor3 = C.BluePale, BackgroundTransparency = 0, BorderSizePixel = 0, Size = UDim2.new(1, 0, 0, STICKY_H), ZIndex = 4 }, detailFace)
	UIKit.corner(ui.Sticky, Theme.Radius.L)
	UIKit.Hairline(ui.Sticky, { AnchorPoint = Vector2.new(0, 1), Position = UDim2.new(0, 12, 1, 0), Size = UDim2.new(1, -24, 0, 1), ZIndex = 5 })
	ui.StickyText = text(ui.Sticky, "Label", "", { Name = "Text", Position = UDim2.fromOffset(16, 0), Size = UDim2.new(1, -32, 1, 0), RichText = true, TextTruncate = Enum.TextTruncate.AtEnd, TextColor3 = C.Text, TextScaled = true, ZIndex = 5 }, 13)
	new("UITextSizeConstraint", { MaxTextSize = TS(13), MinTextSize = 9 }, ui.StickyText)
	-- footer for the action button when the details don't fit (phones): always in view
	ui.Footer = new("Frame", { Name = "Footer", BackgroundTransparency = 1, Visible = false, AnchorPoint = Vector2.new(0, 1), Position = UDim2.fromScale(0, 1) }, detailFace)
	UIKit.padding(ui.Footer, 6, 18, 12, 18)
	UIKit.Hairline(ui.Footer, { Position = UDim2.fromOffset(0, -6) })

	-- head: framed portrait | NAME + pill / ROLE / intro
	local head = new("Frame", { Name = "Head", BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, PORTRAIT), AutomaticSize = Enum.AutomaticSize.Y, LayoutOrder = 1 }, scroll)
	ui.PortraitWell = new("Frame", { Name = "Portrait", BackgroundColor3 = C.Panel, BackgroundTransparency = 0, Size = UDim2.fromOffset(PORTRAIT, PORTRAIT), ClipsDescendants = true }, head)
	UIKit.corner(ui.PortraitWell, Theme.Radius.M)
	UIKit.stroke(ui.PortraitWell, C.PanelEdge, 3, 0)
	local col = new("Frame", { Name = "Column", BackgroundTransparency = 1, Position = UDim2.fromOffset(PORTRAIT + 14, 0), Size = UDim2.new(1, -(PORTRAIT + 14), 0, 0), AutomaticSize = Enum.AutomaticSize.Y }, head)
	UIKit.list(col, { Padding = UDim.new(0, 6) })
	local nameRow = new("Frame", { Name = "NameRow", BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, TS(30) + 6), LayoutOrder = 1 }, col)
	ui.Name = text(nameRow, "H1", "", { Name = "CharName", FontFace = DETAIL_HEADING, Size = UDim2.fromScale(1, 1), TextTruncate = Enum.TextTruncate.AtEnd, TextColor3 = C.Text }, 28)
	ui.State = UIKit.StatusPill(col, "OWNED", { LayoutOrder = 2, Size = UDim2.fromOffset(0, Theme.Size.Badge + 10) })
	ui.StatePad = ui.State:FindFirstChildOfClass("UIPadding")
	ui.StateLock = Icons.Draw(ui.State, "lock", { Size = 14, Color = C.DisabledText, Back = C.Disabled, AnchorPoint = Vector2.new(1, 0.5), Position = UDim2.new(0, -4, 0.5, 0) })
	ui.Role = text(col, "Label", "", { Name = "Role", FontFace = DETAIL_HEADING, LayoutOrder = 3, Size = UDim2.new(1, 0, 0, TS(13) + 4), TextColor3 = C.BlueDeep }, 13)
	ui.Desc = text(col, "Body", "", {
		Name = "Intro",
		LayoutOrder = 4,
		LineHeight = 1.15,
		TextWrapped = true,
		Size = UDim2.new(1, 0, 0, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		TextYAlignment = Enum.TextYAlignment.Top,
		TextColor3 = C.Text,
	}, 15)
	UIKit.Divider(scroll, 10, { LayoutOrder = 2, Size = UDim2.new(1, 0, 0, 12) })

	-- Starting weapon and trait each keep the full panel width.
	local factH = math.max(52, TS(12) + TS(18) + 16)
	local facts = new("Frame", { Name = "Facts", BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 2 * factH + 8), LayoutOrder = 3 }, scroll)
	local function fact(x: number, caption: string): (TextLabel, Frame)
		local half = new("Frame", { Name = caption, BackgroundTransparency = 1, Position = UDim2.fromOffset(0, x > 0 and factH + 8 or 0), Size = UDim2.new(1, 0, 0, factH) }, facts)
		local well = new("Frame", { Name = "Well", BackgroundTransparency = 1, AnchorPoint = Vector2.new(0, 0.5), Position = UDim2.new(0, 0, 0.5, 0), Size = UDim2.fromOffset(48, 48) }, half)
		text(half, "Label", string.upper(caption), { FontFace = DETAIL_HEADING, Position = UDim2.fromOffset(60, 4), Size = UDim2.new(1, -60, 0, TS(12) + 4), TextColor3 = C.BlueDeep }, 12)
		local value = text(half, "BodyStrong", "", { Position = UDim2.fromOffset(60, 8 + TS(12)), Size = UDim2.new(1, -60, 0, TS(18) + 4), TextTruncate = Enum.TextTruncate.AtEnd, TextColor3 = C.Text }, 18)
		return value, well
	end
	ui.Weapon, ui.WeaponHolder = fact(0, "Starting weapon")
	local bonus, traitWell = fact(0.5, "Trait")
	ui.Bonus = bonus
	local traitDisc = new("Frame", { BackgroundColor3 = C.Blue, Size = UDim2.fromScale(1, 1) }, traitWell)
	UIKit.corner(traitDisc, 999)
	UIKit.stroke(traitDisc, C.BlueDeep, 2, 0)
	Icons.Draw(traitDisc, "sparkle", { Size = 26, Color = C.TextOnBlue, AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.5), Back = C.Blue })
	UIKit.Hairline(scroll, { LayoutOrder = 4 })

	-- EFFECT (big "+N%" + text + weapon list), STRENGTH, TRADEOFF
	local function infoRow(order: number, caption: string, color: Color3): (Frame, Frame)
		local row = new("Frame", { Name = caption, BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 0), AutomaticSize = Enum.AutomaticSize.Y, LayoutOrder = order }, scroll)
		text(row, "Label", string.upper(caption), { FontFace = DETAIL_HEADING, TextColor3 = color, Size = UDim2.new(1, 0, 0, TS(13) + 4) }, 13)
		local body = new("Frame", { Name = "Body", BackgroundTransparency = 1, Position = UDim2.fromOffset(0, TS(13) + 10), Size = UDim2.new(1, 0, 0, 0), AutomaticSize = Enum.AutomaticSize.Y }, row)
		return row, body
	end
	local function wrapped(parent: Instance, style: string, color: Color3, size: number?, props: { [string]: any }?): TextLabel
		local l = text(parent, style, "", {
			Size = UDim2.new(1, 0, 0, 0),
			AutomaticSize = Enum.AutomaticSize.Y,
			TextWrapped = true,
			FontFace = Theme.Font.Body,
			LineHeight = 1.15,
			TextColor3 = color,
			TextYAlignment = Enum.TextYAlignment.Top,
		}, size)
		if props then
			for k, v in pairs(props) do
				(l :: any)[k] = v
			end
		end
		return l
	end
	local _, effBody = infoRow(5, "Effect", C.BlueDeep)
	UIKit.list(effBody, { Padding = UDim.new(0, 6) })
	local effTop = new("Frame", { Name = "Top", BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 0), AutomaticSize = Enum.AutomaticSize.Y, LayoutOrder = 1 }, effBody)
	ui.EffectBig = text(effTop, "Display", "", { Name = "Big", FontFace = DETAIL_HEADING, Size = UDim2.fromOffset(0, TS(24) + 4), AutomaticSize = Enum.AutomaticSize.X, TextColor3 = C.BlueDeep }, 24)
	ui.Trait = wrapped(effTop, "Body", C.Text, 15)
	ui.EffectList = wrapped(effBody, "Small", C.TextMuted, 14, { LayoutOrder = 2, Name = "Weapons" })
	local _, strBody = infoRow(6, "Strength", C.BlueDeep)
	ui.Strength = wrapped(strBody, "Body", C.Text, 15)
	local _, tradeBody = infoRow(7, "Tradeoff", C.TextDanger)
	ui.Tradeoff = wrapped(tradeBody, "Body", C.TextDanger, 15)

	-- UNLOCK block (locked heroes): goal + big progress, the rule, a gold bar
	local unlock = new("Frame", { Name = "Unlock", BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 0), AutomaticSize = Enum.AutomaticSize.Y, LayoutOrder = 8 }, scroll)
	ui.UnlockCard = unlock
	UIKit.list(unlock, { Padding = UDim.new(0, 4) })
	UIKit.Hairline(unlock, { LayoutOrder = 0 })
	local uTop = new("Frame", { Name = "Top", BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 0), AutomaticSize = Enum.AutomaticSize.Y, LayoutOrder = 1 }, unlock)
	ui.UnlockLabel = text(uTop, "Label", "UNLOCK", { FontFace = DETAIL_HEADING, TextColor3 = C.BlueDeep, Size = UDim2.new(1, 0, 0, TS(13) + 4) }, 13)
	ui.UnlockName = text(uTop, "BodyStrong", "", { FontFace = DETAIL_HEADING, Position = UDim2.fromOffset(0, TS(13) + 10), Size = UDim2.new(1, 0, 0, 0), AutomaticSize = Enum.AutomaticSize.Y, TextWrapped = true, TextColor3 = C.Text }, 16)
	ui.UnlockCount = text(unlock, "Display", "", { FontFace = DETAIL_HEADING, LayoutOrder = 2, Size = UDim2.new(1, 0, 0, TS(22) + 6), TextColor3 = C.BlueDeep }, 22)
	ui.UnlockRule = wrapped(unlock, "Body", C.TextMuted, 15, { Name = "Rule", LayoutOrder = 3 })
	ui.UnlockMeter = UIKit.Meter(unlock, { Size = UDim2.new(1, 0, 0, 10), Color = C.Blue, LayoutOrder = 4 } :: any)
	ui.UnlockMeter.Frame.Name = "Progress"

	-- Hero Mastery (owned heroes): UPGRADE <HERO> opens the hero's upgrade rows below it
	ui.MasteryOpen = false
	ui.MasteryButton = UIKit.Button(unlock, {
		Name = "MasteryUpgrade",
		Kind = "Outline",
		Title = "UPGRADE",
		Icon = "chevronsUp",
		IconSize = 18,
		Align = "Center",
		Size = UDim2.new(1, 0, 0, 42),
		LayoutOrder = 5,
		Shadow = false,
		OnClick = function()
			ui.MasteryOpen = not ui.MasteryOpen
			MenuCharacters._refresh()
			if ui.MasteryOpen then
				-- bring the rows into view (phones scroll the details panel)
				task.defer(function()
					local panel = ui.MasteryPanel
					if panel.Visible then
						local y = panel.AbsolutePosition.Y - ui.Scroll.AbsolutePosition.Y + ui.Scroll.CanvasPosition.Y
						ui.Scroll.CanvasPosition = Vector2.new(0, math.max(0, y - 60))
					end
				end)
			end
		end,
	})
	ui.MasteryPanel = new("Frame", { Name = "HeroUpgrades", BackgroundTransparency = 1, Visible = false, Size = UDim2.new(1, 0, 0, 0), AutomaticSize = Enum.AutomaticSize.Y, LayoutOrder = 6 }, unlock)
	UIKit.list(ui.MasteryPanel, { Padding = UDim.new(0, 6) })
	-- HEROPOWER (ultimate, second skill, favourites): its own module, under the mastery rows
	ui.Prestige = MenuPrestige.Build(unlock, 7) -- Prestige: stars + PRESTIGE <HERO> (its own module)
	ui.HeroPower = MenuHeroPower.Build(unlock, 8)

	ui.Action = UIKit.Button(scroll, {
		Kind = "Primary",
		Title = "SELECT",
		TitleStyle = "H3",
		Icon = "play",
		IconSize = 20,
		Align = "Center",
		Size = UDim2.new(1, 0, 0, ACTION_H),
		LayoutOrder = 9,
		Name = "Action",
		OnClick = function()
			local p = profile()
			if not p then
				return
			end
			local def = CharacterData.Characters[inspChar]
			if p.OwnedCharacters[inspChar] ~= true then
				if def.Unlock then
					local a = AchievementData.Achievements[def.Unlock.Achievement]
					ctx.Toast(string.format("Unlock the %s: %s", def.Name, a and a.Description or "earn its achievement"), C.BlueDeep)
					return
				end
				if p.Gold < def.Cost then
					ctx.Toast("Not enough gold yet: " .. UIKit.formatNumber(def.Cost) .. " needed.", C.Danger)
					return
				end
				Remotes.Get("BuyCharacter"):FireServer(inspChar)
			elseif p.SelectedCharacter ~= inspChar then
				Remotes.Get("SelectCharacter"):FireServer(inspChar)
			end
		end,
	})

	-- SKINS header (label, rule, the button for a skin not owned) and the skin cards
	local skinHeadH = math.max(Theme.Size.TapMin, TS(14) + 14)
	local skinHead = new("Frame", { Name = "SkinHead", BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, skinHeadH), LayoutOrder = 10 }, scroll)
	text(skinHead, "Label", "SKINS", { FontFace = DETAIL_HEADING, TextColor3 = C.BlueDeep, Size = UDim2.fromOffset(64, skinHeadH) }, 13)
	ui.SkinRule = UIKit.Hairline(skinHead, { AnchorPoint = Vector2.new(0, 0.5), Position = UDim2.new(0, 70, 0.5, 0), Size = UDim2.new(1, -70, 0, 1) })
	ui.SkinAction = UIKit.Button(skinHead, {
		Name = "SkinAction",
		Kind = "Outline",
		Title = "GET SKIN",
		Icon = "robux",
		IconSize = 16,
		Align = "Center",
		AnchorPoint = Vector2.new(1, 0.5),
		Position = UDim2.new(1, 0, 0.5, 0),
		Size = UDim2.new(0, 170, 1, 0),
		Shadow = false,
		OnClick = function()
			local p = profile()
			if not p then
				return
			end
			if skinOwned(p, inspSkin) then
				if p.OwnedCharacters[inspChar] == true and (p.Skins[inspChar] or "Default") ~= inspSkin then
					Remotes.Get("EquipSkin"):FireServer(inspChar, inspSkin)
				end
				return
			end
			local passId = skinPassId(inspSkin)
			local bundleSkin = CharacterData.Skins[inspSkin] and (CharacterData.Skins[inspSkin] :: any).Pass == "StarterBundle"
			if bundleSkin then
				-- the Starter Bundle's skin (StarterBundle.lua): only inside the bundle
				if StarterCard.Offered() then
					ctx.ShowScreen("Starter")
				else
					ctx.Toast("This skin comes with the Starter Bundle.", C.TextMuted)
				end
			elseif passId then
				MarketplaceService:PromptGamePassPurchase(player, passId)
			else
				ctx.Toast("That skin is coming soon!", C.TextMuted)
			end
		end,
	})
	ui.Swatches = new("Frame", { Name = "Swatches", BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 0), LayoutOrder = 11, AutomaticSize = Enum.AutomaticSize.Y }, scroll)
	ui.SwatchLayout = UIKit.list(ui.Swatches, { FillDirection = Enum.FillDirection.Horizontal, Padding = UDim.new(0, SKIN_GAP), Wraps = true })
	ui.SkinW = 104

	local swatches: { [string]: { [string]: any } } = {}

	local function buildSwatches()
		for _, c in ipairs(ui.Swatches:GetChildren()) do
			if c:IsA("GuiObject") then
				c:Destroy()
			end
		end
		table.clear(swatches)
		local cardH = 34 + TS(14) + TS(10) + 32
		for order, skinId in ipairs(visibleSkins()) do
			local look = CharacterData.ResolveLook(inspChar, skinId)
			local hit = new("TextButton", {
				Name = skinId,
				Text = "",
				AutoButtonColor = false,
				BackgroundColor3 = C.PanelRaised,
				BackgroundTransparency = 0,
				Size = UDim2.fromOffset(ui.SkinW, cardH),
				LayoutOrder = order,
			}, ui.Swatches)
			UIKit.corner(hit, Theme.Radius.M)
			UIKit.Focusable(hit)
			local st = UIKit.stroke(hit, C.Divider, 2, 0)
			-- the swatch: torso colour, hat band, trim
			local sw = new("Frame", { Name = "Swatch", BackgroundColor3 = look.Colors.Torso, Position = UDim2.fromOffset(10, 8), Size = UDim2.new(1, -20, 0, 34), ClipsDescendants = true }, hit)
			UIKit.corner(sw, 4)
			new("UIGradient", { Rotation = 90, Color = ColorSequence.new(Color3.new(1, 1, 1), Color3.fromRGB(170, 170, 170)) }, sw)
			new("Frame", { BackgroundColor3 = look.Colors.Hat, BorderSizePixel = 0, Size = UDim2.new(1, 0, 0.36, 0) }, sw)
			new("Frame", { BackgroundColor3 = look.GoldTrim and P.gold_400 or look.Colors.Accent, BorderSizePixel = 0, AnchorPoint = Vector2.new(0, 0.5), Position = UDim2.fromScale(0, 0.66), Size = UDim2.new(1, 0, 0, 5) }, sw)
			local lock = new("Frame", { Name = "Lock", BackgroundColor3 = C.Disabled, BackgroundTransparency = 0.25, Size = UDim2.fromScale(1, 1), ZIndex = 3 }, sw)
			Icons.Draw(lock, "lock", { Size = 18, Color = C.DisabledText, Back = C.Disabled, AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.5) })
			text(hit, "Small", skinName(skinId), { Name = "SkinName", Position = UDim2.fromOffset(4, 45), Size = UDim2.new(1, -8, 0, TS(14) + 4), TextXAlignment = Enum.TextXAlignment.Center, TextColor3 = C.Text, TextTruncate = Enum.TextTruncate.AtEnd })
			local pill = UIKit.StatusPill(hit, "OWNED", { Name = "State", AnchorPoint = Vector2.new(0.5, 1), Position = UDim2.new(0.5, 0, 1, -7), Size = UDim2.fromOffset(0, TS(10) + 10) })
			pill.TextSize = TS(10)
			local pad = pill:FindFirstChildOfClass("UIPadding")
			if pad then
				pad.PaddingLeft = UDim.new(0, 8)
				pad.PaddingRight = UDim.new(0, 8)
			end
			local badge = new("Frame", { Name = "Check", BackgroundColor3 = C.Selected, AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.new(1, -6, 0, 6), Size = UDim2.fromOffset(22, 22), Visible = false, ZIndex = 5 }, hit)
			UIKit.corner(badge, 999)
			UIKit.stroke(badge, C.SelectedEdge, 2, 0)
			Icons.Draw(badge, "check", { Size = 14, Color = C.Text, Back = C.Selected, AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.5) })
			UIAnim.Button(hit)
			hit.Activated:Connect(function()
				UIKit.Click()
				inspSkin = skinId
				UIAnim.Bump(sw, 0.1)
				Showcase.Show(inspChar, inspSkin)
				MenuCharacters._refresh()
			end)
			swatches[skinId] = { Hit = hit, Stroke = st, Lock = lock, Pill = pill, Check = badge }
		end
	end

	-- Hero Mastery upgrade rows (rebuilt from the profile; a tap marks its row BUYING...
	-- until the next ProfileSync, which always carries the real gold and levels)
	local pending: { [string]: number } = {}
	local lastHeroLevel: { [string]: number } = {} -- mastery levels seen (a rise plays a sound)
local bought: { [string]: { [string]: number } } = {} -- upgrades bought on this visit
	local lastProfile: any = nil
	local function buildMasteryRows(p: { [string]: any }, heroId: string)
		for _, c in ipairs(ui.MasteryPanel:GetChildren()) do
			if c:IsA("GuiObject") then
				c:Destroy()
			end
		end
		local heroes = type(p.Heroes) == "table" and p.Heroes or {}
		local mastery = MetaUpgradeData.MasteryFor(type(heroes[heroId]) == "table" and heroes[heroId].XP or 0)
		local track = type(p.HeroUpgrades) == "table" and type(p.HeroUpgrades[heroId]) == "table" and p.HeroUpgrades[heroId] or {}
		local innerW = ui.DetailInnerW or 390
		ui.BuiltInnerW = innerW
		local heroName = CharacterData.Characters[heroId] and CharacterData.Characters[heroId].Name or heroId
		-- whose upgrades these are, and one running note of what was bought on this visit
		-- (rows update from the server's profile; no stream of confirmations here)
		local headTxt = string.format("%s'S UPGRADES · only for the %s · paid with gold", string.upper(heroName), heroName)
		text(ui.MasteryPanel, "Small", headTxt, { Name = "Owner", LayoutOrder = 0, Size = UDim2.new(1, 0, 0, TS(13) + 6), AutomaticSize = Enum.AutomaticSize.Y, TextWrapped = true, TextColor3 = C.BlueDeep, FontFace = DETAIL_HEADING }, 13) -- wraps to a second line at large text sizes
		local bw = math.clamp(math.floor(innerW * 0.37), 128, 190)
		local withIcon = bw >= 175 -- narrow buttons (phones) keep the whole label instead
		local lineH = TS(13) + 4
		local rowH = math.max(58, lineH + 2 * (TS(13) + 2) + 10)
		for order, id in ipairs(MetaUpgradeData.HeroOrder()) do
			local def = MetaUpgradeData.HeroDef(heroId, id)
			if not def then
				continue
			end
			local level = math.floor(tonumber(track[id]) or 0)
			local cost = MetaUpgradeData.HeroCostOf(heroId, id, level)
			local maxed = cost == nil
			local cap = MetaUpgradeData.HeroCap(mastery, id, heroId)
			local locked = not maxed and level + 1 > cap
			local key = heroId .. "/" .. id
			if lastHeroLevel[key] ~= nil and level > lastHeroLevel[key] and screen.Visible then
				UIKit.Sound("Item") -- a mastery level bought
				bought[heroId] = bought[heroId] or {}
				bought[heroId][def.Name] = level
			end
			lastHeroLevel[key] = level
			local busy = pending[key] ~= nil
			local row = new("Frame", { Name = id, BackgroundColor3 = C.PanelRaised, BackgroundTransparency = 0, Size = UDim2.new(1, 0, 0, rowH), LayoutOrder = order }, ui.MasteryPanel)
			UIKit.corner(row, Theme.Radius.M)
			UIKit.stroke(row, C.Divider, 2, 0)
			if id == "Signature" then
				local disc = new("Frame", { Name = "Icon", BackgroundColor3 = C.Blue, AnchorPoint = Vector2.new(0, 0.5), Position = UDim2.new(0, 8, 0.5, 0), Size = UDim2.fromOffset(36, 36) }, row)
				UIKit.corner(disc, 999)
				UIKit.stroke(disc, C.BlueDeep, 2, 0)
				Icons.Draw(disc, Icons.MetaIcon("Signature"), { Size = 20, Color = C.TextOnBlue, AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.5), Back = C.Blue })
			else
				local tile = UIKit.Tile(row, { Id = Icons.MetaIcon(id), Size = 36 })
				tile.AnchorPoint = Vector2.new(0, 0.5)
				tile.Position = UDim2.new(0, 8, 0.5, 0)
			end
			local textW = innerW - 52 - bw - 16
			text(row, "Label", string.upper(def.Name) .. " · LV " .. level .. "/" .. def.MaxLevel, {
				Name = "Level", FontFace = DETAIL_HEADING, Position = UDim2.fromOffset(52, 5), Size = UDim2.fromOffset(textW, lineH),
				TextTruncate = Enum.TextTruncate.AtEnd, TextColor3 = maxed and C.BlueDeep or C.Text,
			}, 13)
			local effectLine = effectStep(heroId, id, level, maxed)
if locked then
	-- why the next level is locked (MetaUpgradeData.RequiredMastery / HeroCap)
	effectLine = string.format("LV %d needs mastery %d (now %d)", level + 1, MetaUpgradeData.RequiredMastery(id, level + 1), mastery)
end
text(row, "Small", effectLine, {
				Name = "Effect", Position = UDim2.fromOffset(52, 5 + lineH + 2), Size = UDim2.fromOffset(textW, rowH - lineH - 12),
				TextWrapped = true, TextYAlignment = Enum.TextYAlignment.Top, TextTruncate = Enum.TextTruncate.AtEnd,
				TextColor3 = maxed and C.BlueDeep or (locked and C.TextMuted or C.Success),
			}, 13)
			local title, kind = "", "Primary"
			local icon = "coin"
			if maxed then
				title, kind = "MAXED", "Secondary"
				icon = "check"
			elseif locked then
				title, kind = "MASTERY " .. MetaUpgradeData.RequiredMastery(id, level + 1), "Secondary"
				icon = "lock"
			elseif busy then
				title = "BUYING..."
			else
				-- the unit always shows (Upgrades reads "BUY · N GOLD"); narrow phone
				-- buttons drop the BUY instead
				title = (withIcon and "BUY · " or "") .. UIKit.formatNumber(cost :: number) .. " GOLD"
				kind = p.Gold >= (cost :: number) and "Primary" or "Outline"
			end
			local b
			b = UIKit.Button(row, {
				Name = "Buy",
				Kind = kind,
				Title = title,
				Icon = withIcon and icon or nil,
				IconSize = 16,
				Shrink = true, -- large text sizes: the label shrinks a little before it cuts
				Align = "Center",
				AnchorPoint = Vector2.new(1, 0.5),
				Position = UDim2.new(1, -8, 0.5, 0),
				Size = UDim2.fromOffset(bw, 40),
				Shadow = false,
				OnClick = function()
					if maxed or locked or pending[key] then
						return
					end
					local pr = profile()
					if pr and pr.Gold < (cost :: number) then
						ctx.Toast("Not enough gold yet: " .. UIKit.formatNumber(cost :: number) .. " needed.", C.Danger)
						return
					end
					pending[key] = os.clock()
					b.SetText("BUYING...")
					b.SetEnabled(false)
					Remotes.Get("BuyHeroUpgrade"):FireServer(heroId, id, level)
					-- no answer (dropped / rejected): ask for the real profile and free the row
					task.delay(3, function()
						if pending[key] and os.clock() - pending[key] >= 2.9 then
							pending[key] = nil
							Remotes.Get("RequestProfile"):FireServer()
						end
					end)
				end,
			})
			b.SetEnabled(not maxed and not locked and not busy)
		end
		local got = bought[heroId]
		if got and next(got) then
			local parts = {}
			for name, lv in pairs(got) do
				table.insert(parts, name .. " LV " .. lv)
			end
			table.sort(parts)
			text(ui.MasteryPanel, "Small", "Bought this visit: " .. table.concat(parts, " · "), { Name = "Bought", LayoutOrder = 100, Size = UDim2.new(1, 0, 0, 0), AutomaticSize = Enum.AutomaticSize.Y, TextWrapped = true, TextColor3 = C.Success }, 13)
		end
	end

	-- the portrait (art/portraits/<Id>; the drawn class icon while it loads / if missing)
	local function buildPortrait(id: string)
		for _, c in ipairs(ui.PortraitWell:GetChildren()) do
			if c:IsA("GuiObject") then
				c:Destroy()
			end
		end
		UIKit.ArtPicture(ui.PortraitWell, "portraits/" .. id, { CornerRadius = Theme.Radius.M }, function(fb: Frame)
			Icons.Character(fb, id, { Size = math.floor(PORTRAIT * 0.7), AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.5) })
		end)
	end

	-- a roster row's look: previewed (gold border, accent bar, PREVIEW) or plain
	local function paintRow(id: string, p: { [string]: any })
		local row = ui.Rows[id]
		local insp = id == inspChar
		local own = p.OwnedCharacters[id] == true
		local sel = p.SelectedCharacter == id
		local full = row.Mode == "row"
		row.Instance.BackgroundTransparency = (insp or not full) and 0 or 1
		row.Instance.BackgroundColor3 = insp and C.BluePale or C.PanelRaised
		row.Edge.Transparency = (insp or not full) and 0 or 1
		row.Edge.Color = insp and C.PanelEdge or C.Divider
		row.Edge.Thickness = insp and 3 or 2
		row.Accent.Visible = insp and full
		row.Name.TextColor3 = insp and C.BlueDeep or ((own or full) and C.Text or C.TextMuted)
		row.Check.Visible = sel
		row.Equipped.Visible = sel and full
		row.Lock.Visible = not own
		MenuPrestige.Badge(row.Icon, own and MenuPrestige.StarsOf(p, id) or 0)
		row.Preview.Visible = insp and not sel and full
		-- the name takes the room the marks leave
		if full then
			local nx = row.Name.Position.X.Offset
			local reserve = sel and 124 or ((insp and 96 or 0) + (own and 0 or 26))
			row.Name.Size = UDim2.new(1, -(nx + reserve + 8), 1, 0)
			-- a long name beside the marks a little smaller instead of cut off
			local room = (ui.RowW or 300) - nx - reserve - 8
			local size = Theme.TextSize.H2
			while size > 13 and #CharacterData.Characters[id].Name * TS(size) * 0.58 > room do
				size -= 1
			end
			row.Name.TextSize = TS(size)
		end
	end

	local builtFor = ""
	-- idle life while the screen shows: the inspected row's accent bar breathes
	local idle = UIAnim.Track()
	local pulsing = ""
	local function startIdle()
		if pulsing == inspChar or not screen.Visible then
			return
		end
		idle.Clear()
		pulsing = inspChar
		local row = ui.Rows[inspChar]
		if row then
			row.Accent.BackgroundTransparency = 0
			idle.Add(UIAnim.IdlePulse(row.Accent, "BackgroundTransparency", 0, 0.45, 1.2))
		end
	end
	local function stopIdle()
		idle.Clear()
		pulsing = ""
		for _, row in pairs(ui.Rows) do
			row.Accent.BackgroundTransparency = 0
		end
	end
	-- what was selected / equipped last time (a change pops the button and the check)
	local lastSel: string? = nil
	local lastSkin: string? = nil
	local lastOwned: { [string]: boolean } = {}
	local function refresh()
		local p = profile()
		if not p then
			return
		end
		local skinNow = (p.Skins[inspChar] or "Default") .. "@" .. inspChar
		local bought = lastOwned[inspChar] == false and p.OwnedCharacters[inspChar] == true
		if screen.Visible and ((lastSel and lastSel ~= p.SelectedCharacter) or bought) then
			local row = ui.Rows[p.SelectedCharacter]
			UIAnim.Selected(ui.Action.Face)
			if row then
				UIAnim.Selected(row.Check)
			end
			if bought then
				UIKit.Sound("Chest") -- a hero unlocked with gold
			end
		end
		if screen.Visible and lastSkin and lastSkin ~= skinNow and string.find(lastSkin, "@" .. inspChar, 1, true) then
			local sw = swatches[p.Skins[inspChar] or "Default"]
			if sw then
				UIAnim.Selected(sw.Check)
			end
		end
		lastSel, lastSkin = p.SelectedCharacter, skinNow
		for id in pairs(ui.Rows) do
			lastOwned[id] = p.OwnedCharacters[id] == true
		end
		local def = CharacterData.Characters[inspChar]
		if builtFor ~= inspChar then
			builtFor = inspChar
			buildSwatches()
			buildPortrait(inspChar)
			for _, c in ipairs(ui.WeaponHolder:GetChildren()) do
				c:Destroy()
			end
			UIKit.Tile(ui.WeaponHolder, { Id = def.StartWeapon, Size = 48 })
		end
		for id in pairs(ui.Rows) do
			paintRow(id, p)
		end
		local own = p.OwnedCharacters[inspChar] == true
		local selected = p.SelectedCharacter == inspChar
		ui.HeroPower.Refresh(inspChar, p, own)
		ui.Prestige.Refresh(inspChar, p, own)
		MenuPrestige.Badge(ui.PortraitWell, MenuPrestige.StarsOf(p, inspChar))
		ui.Name.Text = string.upper(def.Name)
		-- long names a step smaller so they fit beside the pill
		local nameSize = 28
		while nameSize > 20 and #def.Name * TS(nameSize) * 0.74 > (ui.NameRoom or 300) do
			nameSize -= 2
		end
		ui.Name.TextSize = TS(nameSize)
		ui.Role.Text = string.upper(def.Role or "")
		ui.Desc.Text = def.Description -- (the trait's current value is set below)
		local weapon = WeaponData.Weapons[def.StartWeapon]
		ui.Weapon.Text = weapon and weapon.Name or def.StartWeapon
		ui.Bonus.Text = def.Trait and def.Trait.Name or (def.BonusText or "")
		local sigLevel = 0
		if own and type(p.HeroUpgrades) == "table" and type(p.HeroUpgrades[inspChar]) == "table" then
			sigLevel = math.floor(tonumber(p.HeroUpgrades[inspChar].Signature) or 0)
		end
		ui.Desc.Text = currentTraitText(inspChar, def.Description, sigLevel)
		local big, body, list = splitEffect(currentTraitText(inspChar, def.Trait and def.Trait.Text or (def.BonusText or ""), sigLevel))
		ui.EffectBig.Text = big or ""
		ui.EffectBig.Visible = big ~= nil
		-- The trait sentence stays full width beneath its highlighted number.
		ui.Trait.Position = UDim2.fromOffset(0, big and TS(24) + 8 or 0)
		ui.Trait.Size = UDim2.new(1, 0, 0, 0)
		ui.Trait.Text = body
		ui.EffectList.Text = list or ""
		ui.EffectList.Visible = list ~= nil
		ui.Strength.Text = def.Strengths or ""
		ui.Tradeoff.Text = def.Tradeoff or ""
		-- status pill (a lock in front of LOCKED)
		local status = selected and "SELECTED" or (own and "OWNED" or "LOCKED")
		UIKit.SetStatus(ui.State, status)
		ui.StateLock.Visible = status == "LOCKED"
		if ui.StatePad then
			ui.StatePad.PaddingLeft = UDim.new(0, status == "LOCKED" and 28 or 10)
		end
		ui.StateLock.Position = UDim2.new(0, -6, 0.5, 0)
		-- centre caption
		local starMark = MenuPrestige.StarsOf(p, inspChar) -- the nameplate under the hero shows the prestige star
		ui.CentreTitle.Set(UIKit.spaced(def.Name) .. (starMark > 0 and ("  \u{2605}" .. starMark) or ""))
		local previewSkin = inspSkin
		-- the equipped hero in its equipped skin is not a preview
		local wearing = selected and type(p.Skins) == "table" and (p.Skins[inspChar] or "Default") == previewSkin
		ui.CentreSub.Text = (wearing and "Equipped  ·  " or "Preview  ·  ") .. skinName(previewSkin)
local eqDef = CharacterData.Characters[p.SelectedCharacter or CharacterData.Default]
local gold, muted = UIKit.hex(C.BlueDeep), UIKit.hex(C.TextMuted)
local sticky
if selected then
	sticky = string.format('<font color="%s">EQUIPPED</font>  %s', gold, string.upper(def.Name))
	if not wearing then
		sticky ..= string.format('  <font color="%s">· previewing skin %s</font>', muted, skinName(previewSkin))
	end
else
	sticky = string.format('<font color="%s">PREVIEW</font>  %s  <font color="%s">· you play the %s until you select another</font>', gold, string.upper(def.Name), muted, eqDef and eqDef.Name or "Knight")
end
ui.StickyText.Text = sticky
		-- how to unlock it: the achievement and its progress, or the gold price; an owned
		-- hero shows its MASTERY instead (and UPGRADE <HERO>)
		if p ~= lastProfile then
			lastProfile = p
			table.clear(pending) -- a fresh profile answers every purchase in flight
		end
		ui.UnlockCard.Visible = true
		ui.UnlockLabel.Text = own and "MASTERY" or "UNLOCK"
		ui.MasteryButton.Instance.Visible = own
		ui.MasteryPanel.Visible = own and ui.MasteryOpen
		if own then
			local heroes = type(p.Heroes) == "table" and p.Heroes or {}
			local h = type(heroes[inspChar]) == "table" and heroes[inspChar] or {}
			local level, into, need = MetaUpgradeData.MasteryFor(h.XP or 0)
			local cap = MetaUpgradeData.HeroCap(level, "MaxHP", inspChar)
			ui.UnlockName.Text = "LEVEL " .. level .. (level >= Config.HeroMastery.MaxLevel and "  ·  MAX" or "")
			ui.UnlockCount.Text = need > 0 and (UIKit.formatNumber(into) .. " / " .. UIKit.formatNumber(need) .. " XP") or "MAX"
			local sigCap = MetaUpgradeData.HeroCap(level, "Signature", inspChar)
local every = Config.HeroMastery.SignatureEvery
ui.UnlockRule.Text = string.format("Runs with the %s raise its mastery (max %d). Each mastery level lets every stat upgrade go %d levels higher, up to that upgrade's own max; the trait needs mastery %d, %d, %d... Now: stats up to LV %d, trait up to LV %d.",
	def.Name, Config.HeroMastery.MaxLevel, Config.HeroMastery.StatPerLevel, every, 2 * every, 3 * every, cap, sigCap)
			ui.UnlockMeter.Set(need > 0 and math.clamp(into / need, 0, 1) or 1, "")
			ui.MasteryButton.SetText(ui.MasteryOpen and "HIDE UPGRADES" or ("UPGRADE " .. string.upper(def.Name)))
			if ui.MasteryOpen then
				buildMasteryRows(p, inspChar)
			end
		end
		if not own then
			if def.Unlock then
				local aid = def.Unlock.Achievement
				local a = AchievementData.Achievements[aid]
				local progress = p.Achievements and p.Achievements.Progress and tonumber(p.Achievements.Progress[aid]) or 0
				local goal = a and a.Goal or 1
				ui.UnlockName.Text = string.upper(a and a.Name or aid)
				ui.UnlockCount.Text = AchievementData.ProgressText(aid, progress)
				ui.UnlockRule.Text = a and a.Description or ""
				ui.UnlockMeter.Set(math.clamp(progress / math.max(1, goal), 0, 1), "")
			else
				ui.UnlockName.Text = UIKit.formatNumber(def.Cost) .. " GOLD"
				ui.UnlockCount.Text = p.Gold >= def.Cost and "READY" or (UIKit.formatNumber(p.Gold) .. " / " .. UIKit.formatNumber(def.Cost))
				ui.UnlockRule.Text = "Buy with gold earned in runs. You have " .. UIKit.formatNumber(p.Gold) .. " gold."
				ui.UnlockMeter.Set(math.clamp(p.Gold / math.max(1, def.Cost), 0, 1), "")
			end
		end
		if not own and def.Unlock then
			local a = AchievementData.Achievements[def.Unlock.Achievement]
			local goal = shortGoal(a)
			ui.Action.SetKind("Secondary")
			-- (phones: just the goal when "TO UNLOCK" would not fit)
			local tail = (UIKit.IsCompact() and goal and #goal > 14) and "" or " TO UNLOCK"
			ui.Action.SetText(goal and (string.upper(goal) .. tail) or ("EARN " .. string.upper(a and a.Name or "its achievement") .. " TO UNLOCK"))
			ui.Action.SetIcon("lock")
			ui.Action.SetEnabled(false)
		elseif not own then
			ui.Action.SetKind("Primary")
			ui.Action.SetEnabled(p.Gold >= def.Cost)
			ui.Action.SetText("UNLOCK  ·  " .. UIKit.formatNumber(def.Cost) .. " GOLD")
			ui.Action.SetIcon("coin")
		elseif selected then
			-- (lime with a check: nothing to do, a tap changes nothing)
			ui.Action.SetEnabled(true)
			ui.Action.SetKind("Selected")
			ui.Action.SetText(string.upper(def.Name) .. " SELECTED")
			ui.Action.SetIcon("check")
		else
			ui.Action.SetEnabled(true)
			ui.Action.SetKind("Primary")
			ui.Action.SetText("SELECT " .. string.upper(def.Name))
			ui.Action.SetIcon("play")
		end
		-- skin cards
		local equipped = p.Skins[inspChar] or "Default"
		local narrow = ui.SkinW < 100
		for skinId, s in pairs(swatches) do
			local mine = skinOwned(p, skinId)
			local isEq = skinId == equipped
			s.Lock.Visible = not mine
			s.Check.Visible = isEq
			if isEq then
				UIKit.SetStatus(s.Pill, "EQUIPPED", narrow and "EQUIPPED" or "SKIN EQUIPPED")
			elseif mine then
				UIKit.SetStatus(s.Pill, "OWNED", "OWNED")
			else
				UIKit.SetStatus(s.Pill, "LOCKED", skinPassId(skinId) and "R$" or "SOON")
			end
			s.Stroke.Color = isEq and C.SelectedEdge or (skinId == inspSkin and C.PanelEdge or C.Divider)
			s.Stroke.Thickness = (isEq or skinId == inspSkin) and 3 or 2
			s.Stroke.Transparency = 0
		end
		-- Preview never changes the equipped skin; only this explicit action does.
		local skin = CharacterData.Skins[inspSkin]
		local action = ui.SkinAction
		action.Instance.Visible = true
		if skinOwned(p, inspSkin) then
			local isEquipped = equipped == inspSkin
			action.SetKind(isEquipped and "Selected" or "Secondary")
			action.SetIcon("check")
			action.SetText(isEquipped and "EQUIPPED" or "EQUIP SKIN")
			action.SetEnabled(own)
		else
			local passId = skinPassId(inspSkin)
			action.Instance.Visible = true
			action.SetKind("Outline")
			action.SetIcon("robux")
			if skin and skin.Pass == "StarterPack" then
				action.SetText(passId and "BUY PACK" or "COMING SOON")
			elseif skin and (skin :: any).Pass == "StarterBundle" then
				action.SetText(StarterCard.Offered() and "STARTER BUNDLE" or "BUNDLE ONLY")
				passId = StarterCard.Offered() and 1 or nil
			else
				action.SetText(passId and "BUY SKIN" or "COMING SOON")
			end
			action.SetEnabled(passId ~= nil)
		end
		ui.SkinRule.Size = UDim2.new(1, -(70 + (action.Instance.Visible and 182 or 0)), 0, 1)
	end
	MenuCharacters._refresh = refresh

	MenuCharacters._inspect = function(id: string)
		inspChar = id
		local p = profile()
		inspSkin = p and p.Skins[id] or "Default"
		if p and not skinOwned(p, inspSkin) then
			inspSkin = "Default"
		end
		Showcase.Show(inspChar, inspSkin)
		refresh()
		startIdle()
		MenuCharacters._relayout()
		UIAnim.Punch(ui.Detail, 0.03)
		if screen.Visible then
			UIAnim.Burst(ui.Detail, UDim2.fromScale(0.5, 0.1), { C.BlueLight, C.Panel, C.Blue }, 12, 70)
		end
	end

	-- roster rows: "row" (art, name, marks, lines between), "tile" (small art + name in a
	-- box, phones in landscape) or "tab" (centred name, portrait)
	local function rowStyle(id: string, mode: string, rowH: number)
		local row = ui.Rows[id]
		row.Mode = mode
		local def = CharacterData.Characters[id]
		local long = #def.Name > 9
		local iconS = mode == "row" and math.clamp(rowH - 16, 32, 52) or 30
		row.Icon.Visible = mode ~= "tab"
		row.Icon.Size = UDim2.fromOffset(iconS, iconS)
		row.Icon.Position = UDim2.new(0, mode == "row" and 14 or 8, 0.5, 0)
		local nx = mode == "tab" and 4 or (row.Icon.Position.X.Offset + iconS + (mode == "row" and 16 or 8))
		row.Name.Position = UDim2.fromOffset(nx, 0)
		row.Name.Size = UDim2.new(1, -(nx + (mode == "row" and 150 or 4)), 1, 0)
		row.Name.TextXAlignment = mode == "tab" and Enum.TextXAlignment.Center or Enum.TextXAlignment.Left
		local size = mode == "row" and Theme.TextSize.H2 or (long and Theme.TextSize.Small - 1 or Theme.TextSize.Body)
		-- portrait tabs are narrow: the name shrinks to fit there; rows and tiles keep
		-- their size (TextFit lets them grow with a large Text size setting where they fit)
		if mode == "tab" then
			fitName(row.Name, TS(size))
		else
			unfitName(row.Name, TS(size))
		end
		-- tiles / tabs (phones) keep the lock and the equipped check as a small corner badge
		row.Marks.Visible = true
		if mode == "row" then
			row.Marks.AnchorPoint = Vector2.new(1, 0.5)
			row.Marks.Position = UDim2.new(1, -10, 0.5, 0)
			row.Marks.Size = UDim2.new(0, 170, 1, 0)
		else
			row.Marks.AnchorPoint = Vector2.new(1, 0)
			row.Marks.Position = UDim2.new(1, -3, 0, 3)
			row.Marks.Size = UDim2.fromOffset(40, 16)
		end
		local markS = mode == "row" and 20 or 15
		row.Check.Size = UDim2.fromOffset(markS, markS)
		row.Lock.Size = UDim2.fromOffset(markS - 2, markS - 2)
		row.Sep.Visible = mode == "row"
	end

	-- the action button sits in the list under the details; when they don't fit (phones) it
	-- is pinned in a footer at the bottom of the panel instead, so it is always in view
	local function pinAction(on: boolean)
		local b = ui.Action.Instance
		if (b.Parent == ui.Footer) == on then
			return
		end
		ui.Footer.Visible = on
		ui.Footer.Size = UDim2.new(1, 0, 0, ACTION_H + 18)
		ui.Scroll.Size = on and UDim2.new(1, 0, 1, -(ACTION_H + 18) - STICKY_H) or UDim2.new(1, 0, 1, -STICKY_H)
		b.Parent = on and ui.Footer or ui.Scroll
	end

	-- skin cards share the row: up to five, at least 82 px wide
	local function fitSkins(innerW: number)
		local n = math.max(1, #visibleSkins())
		local per = math.clamp(math.floor((innerW + SKIN_GAP) / (82 + SKIN_GAP)), 1, 5)
		local w = math.floor((innerW - (math.min(n, per) - 1) * SKIN_GAP) / math.min(n, per))
		w = math.clamp(w, 82, 124)
		if w ~= ui.SkinW then
			ui.SkinW = w
			for _, s in pairs(swatches) do
				s.Hit.Size = UDim2.fromOffset(w, s.Hit.Size.Y.Offset)
			end
			refresh()
		end
	end

	local function layout(v: Vector2, portrait: boolean, ins: { [string]: number })
		local W, H = v.X, v.Y
		local p = profile()
		local M = UIKit.IsCompact() and Theme.Layout.MarginCompact or Theme.Layout.Margin
		-- the title bar sits in the Roblox top-bar row, right of the Roblox buttons
		local barX = ins.Left > 0 and (ins.Left + 8) or M
		local barY = math.max(2, math.floor((ins.Top - 52) / 2))
		place(ui.Header.Frame, barX, barY, math.min(560, W - barX - M), 52)
		local barBottom = math.max(barY + 52, ins.Top)
		-- portrait: the stats chip sits under the bar (LobbyScreen), the tabs under it
		local top = portrait and (math.max(ins.Top + 4, 12) + 64 + 58) or (barBottom + 8)
		-- the details panel fits its content (measured with the action button in the list,
		-- also while it is pinned below), up to the room there is
		local measured = ui.DetailList.AbsoluteContentSize.Y / math.max(0.01, host.Scale())
		if ui.Action.Instance.Parent == ui.Footer then
			measured += ACTION_H + 8
		end
		local contentH = measured > 10 and (measured + 32 + STICKY_H) or (UIKit.IsCompact() and 640 or 590)
		local n = #CharacterData.Order
		local centreW = 420
		if portrait then
			-- tabs: one compact button per character, in two rows of four
			local perRow = n > 5 and math.ceil(n / 2) or n
			local tabRows = math.ceil(n / perRow)
			local listH = 20 + tabRows * 52 + (tabRows - 1) * 6
			ui.ListLayout.FillDirection = Enum.FillDirection.Horizontal
			ui.ListLayout.Wraps = true
			ui.ListLayout.Padding = UDim.new(0, 6)
			local w = W - 2 * M
			place(ui.List, M, top, w, listH)
			for id, row in pairs(ui.Rows) do
				row.Instance.Size = UDim2.new(1 / perRow, -6, 0, 52)
				rowStyle(id, "tab", 52)
			end
			-- the details panel leaves the hero a clear gap between the tabs and the panel
			-- (the panel scrolls; the action button stays pinned in view)
			local detailH = math.min(contentH, math.floor(H * 0.5) - (listH - 76))
			local detailY = H - M - detailH
			ui.NameRoom = w - 40 - PORTRAIT - 14
			place(ui.Detail, M, detailY, w, detailH)
			pinAction(contentH > detailH + 1)
			fitSkins(w - 40)
			ui.DetailInnerW = w - 44
			-- the details panel already names the hero: no caption over the hero's feet
			place(ui.Centre, (W - centreW) / 2, detailY - 64, centreW, 58)
			ui.Centre.Visible = false
			if ctx.Current() == "Characters" then
				local gapTop, gapBottom = top + listH + 6, detailY - 6
				local cam = workspace.CurrentCamera
				cam:SetAttribute("MenuHeroY", (gapTop + gapBottom) / 2 / H)
				cam:SetAttribute("MenuHeroX", 0.5)
				-- a short gap widens the shot so the whole hero fits (CameraController)
				cam:SetAttribute("MenuHeroZoom", math.clamp(H * 0.3 / math.max(1, gapBottom - gapTop), 1, 1.6))
			end
		else
			-- one column of rows split by lines; when rows get too short (phones in
			-- landscape) two columns of tiles
			local lw = math.clamp(W * 0.27, 300, 350)
			local inner = H - M - top - 20
			local rowH = math.floor(inner / n)
			local cols = 1
			if rowH < 50 then
				cols = 2
				local rows = math.ceil(n / 2)
				rowH = math.clamp(math.floor((inner - (rows - 1) * 6) / rows), 40, 72)
				lw += 40 -- room for "Necromancer" in a half-width tile
			end
			rowH = math.min(80, rowH)
			local gap = cols == 2 and 6 or 0
			local rows = math.ceil(n / cols)
			ui.ListLayout.FillDirection = cols == 2 and Enum.FillDirection.Horizontal or Enum.FillDirection.Vertical
			ui.ListLayout.Wraps = cols == 2
			ui.ListLayout.Padding = UDim.new(0, gap)
			place(ui.List, M, top, lw, rows * rowH + (rows - 1) * gap + 20)
			ui.RowW = cols == 2 and (lw - 20 - gap) / 2 or (lw - 20)
			for id, row in pairs(ui.Rows) do
				row.Instance.Size = cols == 2 and UDim2.new(0.5, -gap / 2, 0, rowH) or UDim2.new(1, 0, 0, rowH)
				rowStyle(id, cols == 2 and "tile" or "row", rowH)
			end
			-- phones in landscape (tiles): a slimmer details panel leaves the dais hero clear
			local rw = math.clamp(W * 0.37, cols == 2 and 400 or 430, 530)
			ui.NameRoom = rw - 40 - PORTRAIT - 14
			place(ui.Detail, W - M - rw, top, rw, math.min(contentH, H - M - top))
			pinAction(contentH > H - M - top + 1)
			fitSkins(rw - 40)
			ui.DetailInnerW = rw - 44
			-- the hero's name between the panels, under the dais
			local gapL, gapR = M + lw, W - M - rw
			centreW = math.min(420, gapR - gapL - 16)
			place(ui.Centre, (gapL + gapR - centreW) / 2, H - M - 58, centreW, 58)
			-- phones in landscape leave no room between the panels: the details panel
			-- already names the hero, so the caption hides instead of reading "KNI..."
			ui.Centre.Visible = centreW >= 180
			if ctx.Current() == "Characters" then
				local cam = workspace.CurrentCamera
				cam:SetAttribute("MenuHeroY", 0.5)
				-- the hero stands in the middle of the gap between the panels
				cam:SetAttribute("MenuHeroX", math.clamp((gapL + gapR) / 2 / W, 0.35, 0.65))
				-- a narrow gap between the panels (phones) widens the shot so the turning
				-- hero stays clear of both panels
				cam:SetAttribute("MenuHeroZoom", math.clamp(W * 0.23 / math.max(1, gapR - gapL), 1, 1.6))
			end
		end
		if p then
			for id in pairs(ui.Rows) do
				paintRow(id, p)
			end
		end
		-- the upgrade rows follow the panel's width (rotation, window size)
		if ui.MasteryOpen and ui.MasteryPanel.Visible and ui.BuiltInnerW ~= ui.DetailInnerW then
			refresh()
		end
	end

	-- the details panel follows its content (another hero, a skin button shown / hidden)
	MenuCharacters._relayout = function()
		if ctx.Current() == "Characters" then
			layout(host.VirtualSize(), host.IsPortrait(), host.Insets())
		end
	end
	ui.DetailList:GetPropertyChangedSignal("AbsoluteContentSize"):Connect(MenuCharacters._relayout)

	return {
		Layout = layout,
		Refresh = function(_p)
			if screen.Visible then
				refresh()
			end
		end,
		OnShow = function(_p)
			table.clear(bought)
			refresh()
			local i = 0
			for _, id in ipairs(CharacterData.Order) do
				i += 1
				UIAnim.Pop(ui.Rows[id].Instance, 0.03 * i, 0.8)
			end
			UIAnim.Pop(ui.Detail, 0.1, 0.9)
			UIKit.FocusIfGamepad(ui.Rows[inspChar] and ui.Rows[inspChar].Instance)
			pulsing = ""
			task.defer(startIdle) -- (the screen is visible once the swap has started)
			layout(host.VirtualSize(), host.IsPortrait(), host.Insets())
		end,
		Inspect = function(id: string)
			MenuCharacters._inspect(id)
		end,
		OnHide = stopIdle,
	}
end

MenuCharacters._refresh = function() end
MenuCharacters._inspect = function(_id: string) end
MenuCharacters._relayout = function() end

return MenuCharacters
