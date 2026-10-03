--[[
	MenuCharacters.lua
	The CHARACTERS screen of the menu. The inspected hero stands on the dais in the middle
	of the 3D scene (Showcase), so the screen is two panels around it and nothing covers it:
	  top     a compact BACK and the spaced serif title "C H A R A C T E R S" over a gold
	          rule (UIKit.TitleBar) in the Roblox top-bar row; LobbyScreen shows the BEST /
	          WINS / GOLD stats inline on the right
	  left    the roster: one row per character (hero badge art, serif name), rows split by
	          thin lines; the selected hero shows a gold check and EQUIPPED, locked heroes a
	          lock, the inspected one a gold border, a gold accent bar and a PREVIEW pill
	  centre  under the hero: its name in spaced caps between gold rules and
	          "Preview • <skin>"
	  right   framed portrait (art/portraits, drawn class icon as stand-in), the name, a
	          status pill (SELECTED / OWNED / LOCKED with a lock), role in gold caps, the
	          intro line; a rule; STARTING WEAPON (tile) | TRAIT (green badge); EFFECT (a big
	          gold "+20%" when the trait text starts with one, the rest, the weapon list),
	          STRENGTH, TRADEOFF (red); for a locked hero the UNLOCK block (achievement and
	          big "2 / 4" with a gold bar, or the gold price); the action button (gold
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
local UIKit = require(script.Parent.UIKit)
local UIAnim = require(script.Parent.UIAnim)
local Icons = require(script.Parent.Icons)
local Showcase = require(script.Parent.Showcase)

local MenuCharacters = {}

local player = Players.LocalPlayer
local new, text, TS = UIKit.new, UIKit.text, UIKit.TS
local C, P = Theme.Color, Theme.Palette
local DETAIL_HEADING = Font.fromEnum(Enum.Font.GothamBold)

local ACTION_H = 46 -- the SELECT / UNLOCK button
local PORTRAIT = 84 -- framed portrait in the details head
local SKIN_GAP = 8

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

-- Trait text split for the EFFECT row: a leading "+N%" (big number, or nil), the rest as
-- a sentence, and the weapon list after a colon (" • " separated, or nil).
local function splitEffect(s: string): (string?, string, string?)
	local big, rest = string.match(s, "^(%+%d+%%)%s+(.+)$")
	local body = rest or s
	local main, list = string.match(body, "^(.-):%s+(.+)$")
	if main and list then
		list = string.gsub(list, "%.$", "")
		list = string.gsub(list, ",%s*", "  •  ")
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

	ui.Header = UIKit.TitleBar(screen, "Characters", ctx.Back)

	------------------------------------------------------------------------------------
	-- left: the roster (landscape) / tabs (portrait)
	------------------------------------------------------------------------------------
	local listHolder, listFace = UIKit.Surface(screen, { Name = "List", Radius = Theme.Radius.L, Transparency = 0.06 })
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
			BackgroundColor3 = P.slate_700,
			BackgroundTransparency = 1,
			BorderSizePixel = 0,
			Size = UDim2.new(1, 0, 0, 64),
			LayoutOrder = i,
		}, listFace)
		UIKit.corner(hit, Theme.Radius.M)
		UIKit.Focusable(hit)
		local edge = UIKit.stroke(hit, P.gold_400, 1.5, 1)
		local accent = new("Frame", { Name = "Accent", BackgroundColor3 = P.gold_400, BorderSizePixel = 0, Position = UDim2.fromOffset(0, 6), Size = UDim2.new(0, 4, 1, -12), Visible = false, ZIndex = 3 }, hit)
		UIKit.corner(accent, 2)
		local sep = UIKit.Hairline(hit, { Name = "Sep", AnchorPoint = Vector2.new(0, 1), Position = UDim2.new(0, 8, 1, 0), Size = UDim2.new(1, -16, 0, 1), BackgroundTransparency = 0.82 })
		local icon = Icons.Character(hit, id, { Size = 46, AnchorPoint = Vector2.new(0, 0.5), Position = UDim2.new(0, 12, 0.5, 0) })
		local name = text(hit, "H2", def.Name, { Name = "CharName", TextTruncate = Enum.TextTruncate.AtEnd, TextColor3 = P.ivory_100 }, Theme.TextSize.H2)
		-- right side marks: check + EQUIPPED, lock, PREVIEW
		local marks = new("Frame", { Name = "Marks", BackgroundTransparency = 1, AnchorPoint = Vector2.new(1, 0.5), Position = UDim2.new(1, -10, 0.5, 0), Size = UDim2.new(0, 170, 1, 0) }, hit)
		UIKit.list(marks, { FillDirection = Enum.FillDirection.Horizontal, HorizontalAlignment = Enum.HorizontalAlignment.Right, VerticalAlignment = Enum.VerticalAlignment.Center, Padding = UDim.new(0, 8) })
		local check = Icons.Draw(marks, "check", { Size = 20, Color = P.gold_300, Back = P.slate_900 })
		check.LayoutOrder = 1
		local equipped = text(marks, "Label", "EQUIPPED", { Name = "Equipped", LayoutOrder = 2, Size = UDim2.fromOffset(0, TS(13) + 4), AutomaticSize = Enum.AutomaticSize.X, TextColor3 = P.gold_200 }, 13)
		local lock = Icons.Draw(marks, "lock", { Size = 18, Color = P.stone_300, Back = P.slate_900 })
		lock.LayoutOrder = 3
		local preview = UIKit.StatusPill(marks, "PREVIEW", { LayoutOrder = 4, Size = UDim2.fromOffset(0, TS(11) + 12) })
		preview.TextSize = TS(11)
		UIKit.SetStatus(preview, "PREVIEW")
		preview.TextColor3 = P.gold_200
		preview.BackgroundColor3 = P.slate_950
		local pe = preview:FindFirstChild("StatusEdge") :: UIStroke?
		if pe then
			pe.Color = P.gold_400
			pe.Transparency = 0.15
		end
		UIAnim.Button(hit)
		hit.MouseEnter:Connect(function()
			if inspChar ~= id then
				hit.BackgroundTransparency = 0.82
			end
		end)
		hit.MouseLeave:Connect(function()
			if inspChar ~= id then
				hit.BackgroundTransparency = 1
			end
		end)
		hit.Activated:Connect(function()
			UIKit.Click()
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
	ui.CentreTitle.Title.TextColor3 = P.ivory_100
	ui.CentreSub = text(ui.Centre, "Body", "", { Name = "Preview", AnchorPoint = Vector2.new(0, 1), Position = UDim2.fromScale(0, 1), Size = UDim2.new(1, 0, 0, TS(15) + 4), TextXAlignment = Enum.TextXAlignment.Center, TextColor3 = P.ivory_300 }, 15)

	------------------------------------------------------------------------------------
	-- right: details
	------------------------------------------------------------------------------------
	local detailHolder, detailFace = UIKit.Surface(screen, { Name = "Details", Radius = Theme.Radius.L, Transparency = 0.04 })
	ui.Detail = detailHolder
	local scroll = new("ScrollingFrame", {
		Name = "Scroll",
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		Size = UDim2.fromScale(1, 1),
		ScrollBarThickness = 4,
		ScrollBarImageColor3 = P.gold_500,
		AutomaticCanvasSize = Enum.AutomaticSize.Y,
		CanvasSize = UDim2.new(),
		ScrollingDirection = Enum.ScrollingDirection.Y,
	}, detailFace)
	UIKit.padding(scroll, 20, 20, 20, 20)
	ui.DetailList = UIKit.list(scroll, { Padding = UDim.new(0, 12), HorizontalAlignment = Enum.HorizontalAlignment.Left })
	ui.Scroll = scroll
	-- footer for the action button when the details don't fit (phones): always in view
	ui.Footer = new("Frame", { Name = "Footer", BackgroundTransparency = 1, Visible = false, AnchorPoint = Vector2.new(0, 1), Position = UDim2.fromScale(0, 1) }, detailFace)
	UIKit.padding(ui.Footer, 6, 18, 12, 18)
	UIKit.Hairline(ui.Footer, { Position = UDim2.fromOffset(0, -6) })

	-- head: framed portrait | NAME + pill / ROLE / intro
	local head = new("Frame", { Name = "Head", BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, PORTRAIT), AutomaticSize = Enum.AutomaticSize.Y, LayoutOrder = 1 }, scroll)
	ui.PortraitWell = new("Frame", { Name = "Portrait", BackgroundColor3 = P.slate_950, BackgroundTransparency = 0.1, Size = UDim2.fromOffset(PORTRAIT, PORTRAIT), ClipsDescendants = true }, head)
	UIKit.corner(ui.PortraitWell, Theme.Radius.M)
	UIKit.stroke(ui.PortraitWell, P.gold_400, 2, 0.1)
	local col = new("Frame", { Name = "Column", BackgroundTransparency = 1, Position = UDim2.fromOffset(PORTRAIT + 14, 0), Size = UDim2.new(1, -(PORTRAIT + 14), 0, 0), AutomaticSize = Enum.AutomaticSize.Y }, head)
	UIKit.list(col, { Padding = UDim.new(0, 6) })
	local nameRow = new("Frame", { Name = "NameRow", BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, TS(30) + 6), LayoutOrder = 1 }, col)
	ui.Name = text(nameRow, "H1", "", { Name = "CharName", FontFace = DETAIL_HEADING, Size = UDim2.fromScale(1, 1), TextTruncate = Enum.TextTruncate.AtEnd, TextColor3 = P.ivory_100 }, 28)
	ui.State = UIKit.StatusPill(col, "OWNED", { LayoutOrder = 2, Size = UDim2.fromOffset(0, Theme.Size.Badge + 10) })
	ui.StatePad = ui.State:FindFirstChildOfClass("UIPadding")
	ui.StateLock = Icons.Draw(ui.State, "lock", { Size = 14, Color = P.crimson_300, Back = P.slate_950, AnchorPoint = Vector2.new(1, 0.5), Position = UDim2.new(0, -4, 0.5, 0) })
	ui.Role = text(col, "Label", "", { Name = "Role", FontFace = DETAIL_HEADING, LayoutOrder = 3, Size = UDim2.new(1, 0, 0, TS(13) + 4), TextColor3 = P.gold_300 }, 13)
	ui.Desc = text(col, "Body", "", {
		Name = "Intro",
		LayoutOrder = 4,
		LineHeight = 1.15,
		TextWrapped = true,
		Size = UDim2.new(1, 0, 0, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		TextYAlignment = Enum.TextYAlignment.Top,
		TextColor3 = P.ivory_200,
	}, 15)
	UIKit.Divider(scroll, 10, { LayoutOrder = 2, Size = UDim2.new(1, 0, 0, 12) })

	-- Starting weapon and trait each keep the full panel width.
	local factH = math.max(52, TS(12) + TS(18) + 16)
	local facts = new("Frame", { Name = "Facts", BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 2 * factH + 8), LayoutOrder = 3 }, scroll)
	local function fact(x: number, caption: string): (TextLabel, Frame)
		local half = new("Frame", { Name = caption, BackgroundTransparency = 1, Position = UDim2.fromOffset(0, x > 0 and factH + 8 or 0), Size = UDim2.new(1, 0, 0, factH) }, facts)
		local well = new("Frame", { Name = "Well", BackgroundTransparency = 1, AnchorPoint = Vector2.new(0, 0.5), Position = UDim2.new(0, 0, 0.5, 0), Size = UDim2.fromOffset(48, 48) }, half)
		text(half, "Label", string.upper(caption), { FontFace = DETAIL_HEADING, Position = UDim2.fromOffset(60, 4), Size = UDim2.new(1, -60, 0, TS(12) + 4), TextColor3 = P.gold_300 }, 12)
		local value = text(half, "BodyStrong", "", { Position = UDim2.fromOffset(60, 8 + TS(12)), Size = UDim2.new(1, -60, 0, TS(18) + 4), TextTruncate = Enum.TextTruncate.AtEnd, TextColor3 = P.ivory_100 }, 18)
		return value, well
	end
	ui.Weapon, ui.WeaponHolder = fact(0, "Starting weapon")
	local bonus, traitWell = fact(0.5, "Trait")
	ui.Bonus = bonus
	local traitDisc = new("Frame", { BackgroundColor3 = P.moss_700, Size = UDim2.fromScale(1, 1) }, traitWell)
	UIKit.corner(traitDisc, 999)
	UIKit.stroke(traitDisc, P.moss_300, 1.5, 0.3)
	Icons.Draw(traitDisc, "sparkle", { Size = 26, Color = P.ivory_100, AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.5), Back = P.moss_700 })
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
	local _, effBody = infoRow(5, "Effect", P.gold_300)
	UIKit.list(effBody, { Padding = UDim.new(0, 6) })
	local effTop = new("Frame", { Name = "Top", BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 0), AutomaticSize = Enum.AutomaticSize.Y, LayoutOrder = 1 }, effBody)
	ui.EffectBig = text(effTop, "Display", "", { Name = "Big", FontFace = DETAIL_HEADING, Size = UDim2.fromOffset(0, TS(24) + 4), AutomaticSize = Enum.AutomaticSize.X, TextColor3 = P.gold_300 }, 24)
	ui.Trait = wrapped(effTop, "Body", P.ivory_100, 15)
	ui.EffectList = wrapped(effBody, "Small", P.ivory_300, 14, { LayoutOrder = 2, Name = "Weapons" })
	local _, strBody = infoRow(6, "Strength", P.gold_300)
	ui.Strength = wrapped(strBody, "Body", P.ivory_100, 15)
	local _, tradeBody = infoRow(7, "Tradeoff", P.crimson_300)
	ui.Tradeoff = wrapped(tradeBody, "Body", P.crimson_300, 15)

	-- UNLOCK block (locked heroes): goal + big progress, the rule, a gold bar
	local unlock = new("Frame", { Name = "Unlock", BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 0), AutomaticSize = Enum.AutomaticSize.Y, LayoutOrder = 8 }, scroll)
	ui.UnlockCard = unlock
	UIKit.list(unlock, { Padding = UDim.new(0, 4) })
	UIKit.Hairline(unlock, { LayoutOrder = 0 })
	local uTop = new("Frame", { Name = "Top", BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 0), AutomaticSize = Enum.AutomaticSize.Y, LayoutOrder = 1 }, unlock)
	text(uTop, "Label", "UNLOCK", { FontFace = DETAIL_HEADING, TextColor3 = P.gold_300, Size = UDim2.new(1, 0, 0, TS(13) + 4) }, 13)
	ui.UnlockName = text(uTop, "BodyStrong", "", { FontFace = DETAIL_HEADING, Position = UDim2.fromOffset(0, TS(13) + 10), Size = UDim2.new(1, 0, 0, 0), AutomaticSize = Enum.AutomaticSize.Y, TextWrapped = true, TextColor3 = P.ivory_100 }, 16)
	ui.UnlockCount = text(unlock, "Display", "", { FontFace = DETAIL_HEADING, LayoutOrder = 2, Size = UDim2.new(1, 0, 0, TS(22) + 6), TextColor3 = P.gold_200 }, 22)
	ui.UnlockRule = wrapped(unlock, "Body", P.ivory_200, 15, { Name = "Rule", LayoutOrder = 3 })
	ui.UnlockMeter = UIKit.Meter(unlock, { Size = UDim2.new(1, 0, 0, 10), Color = P.gold_400, LayoutOrder = 4 } :: any)
	ui.UnlockMeter.Frame.Name = "Progress"

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
					ctx.Toast(string.format("Unlock the %s: %s", def.Name, a and a.Description or "earn its achievement"), P.gold_300)
					return
				end
				if p.Gold < def.Cost then
					ctx.Toast("Not enough gold yet: " .. UIKit.formatNumber(def.Cost) .. " needed.", P.crimson_300)
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
	text(skinHead, "Label", "SKINS", { FontFace = DETAIL_HEADING, TextColor3 = P.gold_300, Size = UDim2.fromOffset(64, skinHeadH) }, 13)
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
			if passId then
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
		for order, skinId in ipairs(CharacterData.SkinsFor(inspChar)) do
			local look = CharacterData.ResolveLook(inspChar, skinId)
			local hit = new("TextButton", {
				Name = skinId,
				Text = "",
				AutoButtonColor = false,
				BackgroundColor3 = P.slate_900,
				BackgroundTransparency = 0.15,
				Size = UDim2.fromOffset(ui.SkinW, cardH),
				LayoutOrder = order,
			}, ui.Swatches)
			UIKit.corner(hit, Theme.Radius.M)
			UIKit.Focusable(hit)
			local st = UIKit.stroke(hit, P.slate_600, 1.5, 0.3)
			-- the swatch: torso colour, hat band, trim
			local sw = new("Frame", { Name = "Swatch", BackgroundColor3 = look.Colors.Torso, Position = UDim2.fromOffset(10, 8), Size = UDim2.new(1, -20, 0, 34), ClipsDescendants = true }, hit)
			UIKit.corner(sw, 4)
			new("UIGradient", { Rotation = 90, Color = ColorSequence.new(Color3.new(1, 1, 1), Color3.fromRGB(170, 170, 170)) }, sw)
			new("Frame", { BackgroundColor3 = look.Colors.Hat, BorderSizePixel = 0, Size = UDim2.new(1, 0, 0.36, 0) }, sw)
			new("Frame", { BackgroundColor3 = look.GoldTrim and P.gold_400 or look.Colors.Accent, BorderSizePixel = 0, AnchorPoint = Vector2.new(0, 0.5), Position = UDim2.fromScale(0, 0.66), Size = UDim2.new(1, 0, 0, 5) }, sw)
			local lock = new("Frame", { Name = "Lock", BackgroundColor3 = P.slate_950, BackgroundTransparency = 0.35, Size = UDim2.fromScale(1, 1), ZIndex = 3 }, sw)
			Icons.Draw(lock, "lock", { Size = 18, Color = P.ivory_200, Back = P.slate_950, AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.5) })
			text(hit, "Small", skinName(skinId), { Name = "SkinName", Position = UDim2.fromOffset(4, 45), Size = UDim2.new(1, -8, 0, TS(14) + 4), TextXAlignment = Enum.TextXAlignment.Center, TextColor3 = P.ivory_100, TextTruncate = Enum.TextTruncate.AtEnd })
			local pill = UIKit.StatusPill(hit, "OWNED", { Name = "State", AnchorPoint = Vector2.new(0.5, 1), Position = UDim2.new(0.5, 0, 1, -7), Size = UDim2.fromOffset(0, TS(10) + 10) })
			pill.TextSize = TS(10)
			local pad = pill:FindFirstChildOfClass("UIPadding")
			if pad then
				pad.PaddingLeft = UDim.new(0, 8)
				pad.PaddingRight = UDim.new(0, 8)
			end
			local badge = new("Frame", { Name = "Check", BackgroundColor3 = P.gold_400, AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.new(1, -6, 0, 6), Size = UDim2.fromOffset(22, 22), Visible = false, ZIndex = 5 }, hit)
			UIKit.corner(badge, 999)
			UIKit.stroke(badge, P.gold_200, 1, 0.2)
			Icons.Draw(badge, "check", { Size = 14, Color = P.gold_900, Back = P.gold_400, AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.5) })
			UIAnim.Button(hit)
			hit.Activated:Connect(function()
				UIKit.Click()
				inspSkin = skinId
				Showcase.Show(inspChar, inspSkin)
				MenuCharacters._refresh()
			end)
			swatches[skinId] = { Hit = hit, Stroke = st, Lock = lock, Pill = pill, Check = badge }
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
		row.Instance.BackgroundTransparency = insp and 0.55 or (full and 1 or 0.4)
		row.Instance.BackgroundColor3 = insp and P.slate_700 or P.slate_900
		row.Edge.Transparency = insp and 0.05 or (full and 1 or 0.6)
		row.Edge.Color = insp and P.gold_400 or P.slate_600
		row.Edge.Thickness = insp and 2 or 1
		row.Accent.Visible = insp and full
		row.Name.TextColor3 = insp and P.gold_200 or P.ivory_100
		row.Check.Visible = sel
		row.Equipped.Visible = sel and full
		row.Lock.Visible = not own
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
	local function refresh()
		local p = profile()
		if not p then
			return
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
		ui.Name.Text = string.upper(def.Name)
		-- long names a step smaller so they fit beside the pill
		local nameSize = 28
		while nameSize > 20 and #def.Name * TS(nameSize) * 0.74 > (ui.NameRoom or 300) do
			nameSize -= 2
		end
		ui.Name.TextSize = TS(nameSize)
		ui.Role.Text = string.upper(def.Role or "")
		ui.Desc.Text = def.Description
		local weapon = WeaponData.Weapons[def.StartWeapon]
		ui.Weapon.Text = weapon and weapon.Name or def.StartWeapon
		ui.Bonus.Text = def.Trait and def.Trait.Name or (def.BonusText or "")
		local big, body, list = splitEffect(def.Trait and def.Trait.Text or (def.BonusText or ""))
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
		ui.CentreTitle.Set(UIKit.spaced(def.Name))
		local previewSkin = inspSkin
		ui.CentreSub.Text = "Preview  •  " .. skinName(previewSkin)
		-- how to unlock it: the achievement and its progress, or the gold price
		ui.UnlockCard.Visible = not own
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
			ui.Action.SetEnabled(p.Gold >= def.Cost)
			ui.Action.SetKind("Primary")
			ui.Action.SetText("UNLOCK  •  " .. UIKit.formatNumber(def.Cost) .. " GOLD")
			ui.Action.SetIcon("coin")
		elseif selected then
			ui.Action.SetKind("Secondary")
			ui.Action.SetText(string.upper(def.Name) .. " EQUIPPED")
			ui.Action.SetIcon("check")
			ui.Action.SetEnabled(false)
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
				UIKit.SetStatus(s.Pill, "OWNED-DARK", "OWNED")
			else
				UIKit.SetStatus(s.Pill, "SOON-DARK", skinPassId(skinId) and "R$" or "SOON")
			end
			s.Stroke.Color = isEq and P.gold_400 or (skinId == inspSkin and P.ivory_200 or P.slate_600)
			s.Stroke.Thickness = (isEq or skinId == inspSkin) and 2 or 1.5
			s.Stroke.Transparency = (isEq or skinId == inspSkin) and 0 or 0.3
		end
		-- Preview never changes the equipped skin; only this explicit action does.
		local skin = CharacterData.Skins[inspSkin]
		local action = ui.SkinAction
		action.Instance.Visible = true
		if skinOwned(p, inspSkin) then
			local isEquipped = equipped == inspSkin
			action.SetKind(isEquipped and "Secondary" or "Outline")
			action.SetIcon("check")
			action.SetText(isEquipped and "EQUIPPED" or "EQUIP SKIN")
			action.SetEnabled(own and not isEquipped)
		else
			local passId = skinPassId(inspSkin)
			action.Instance.Visible = true
			action.SetKind("Outline")
			action.SetIcon("robux")
			if skin and skin.Pass == "StarterPack" then
				action.SetText(passId and "BUY PACK" or "COMING SOON")
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
		MenuCharacters._relayout()
		UIAnim.Punch(ui.Detail, 0.03)
		if screen.Visible then
			UIAnim.Burst(ui.Detail, UDim2.fromScale(0.5, 0.1), { P.gold_300, P.ivory_100, P.steel_200 }, 12, 70)
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
		row.Name.TextSize = TS(size)
		row.Marks.Visible = mode == "row"
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
		ui.Scroll.Size = on and UDim2.new(1, 0, 1, -(ACTION_H + 18)) or UDim2.fromScale(1, 1)
		b.Parent = on and ui.Footer or ui.Scroll
	end

	-- skin cards share the row: up to five, at least 82 px wide
	local function fitSkins(innerW: number)
		local n = math.max(1, #CharacterData.SkinsFor(inspChar))
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
		local contentH = measured > 10 and (measured + 32) or (UIKit.IsCompact() and 640 or 590)
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
			local detailH = math.min(contentH, math.floor(H * 0.56) - (listH - 76))
			local detailY = H - M - detailH
			ui.NameRoom = w - 40 - PORTRAIT - 14
			place(ui.Detail, M, detailY, w, detailH)
			pinAction(contentH > detailH + 1)
			fitSkins(w - 40)
			place(ui.Centre, (W - centreW) / 2, detailY - 64, centreW, 58)
			ui.Centre.Visible = true
			if ctx.Current() == "Characters" then
				workspace.CurrentCamera:SetAttribute("MenuHeroY", ((top + listH) + (detailY - 50)) / 2 / H)
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
			local rw = math.clamp(W * 0.37, 430, 530)
			ui.NameRoom = rw - 40 - PORTRAIT - 14
			place(ui.Detail, W - M - rw, top, rw, math.min(contentH, H - M - top))
			pinAction(contentH > H - M - top + 1)
			fitSkins(rw - 40)
			-- the hero's name between the panels, under the dais
			local gapL, gapR = M + lw, W - M - rw
			centreW = math.min(420, gapR - gapL - 16)
			place(ui.Centre, (gapL + gapR - centreW) / 2, H - M - 58, centreW, 58)
			-- phones in landscape leave no room between the panels: the details panel
			-- already names the hero, so the caption hides instead of reading "KNI..."
			ui.Centre.Visible = centreW >= 180
			if ctx.Current() == "Characters" then
				workspace.CurrentCamera:SetAttribute("MenuHeroY", 0.5)
			end
		end
		if p then
			for id in pairs(ui.Rows) do
				paintRow(id, p)
			end
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
			refresh()
			local i = 0
			for _, id in ipairs(CharacterData.Order) do
				i += 1
				UIAnim.Pop(ui.Rows[id].Instance, 0.04 * i, 0.8)
			end
			UIAnim.Pop(ui.Detail, 0.1, 0.9)
			UIKit.FocusIfGamepad(ui.Rows[inspChar] and ui.Rows[inspChar].Instance)
			layout(host.VirtualSize(), host.IsPortrait(), host.Insets())
		end,
		Inspect = function(id: string)
			MenuCharacters._inspect(id)
		end,
	}
end

MenuCharacters._refresh = function() end
MenuCharacters._inspect = function(_id: string) end
MenuCharacters._relayout = function() end

return MenuCharacters
