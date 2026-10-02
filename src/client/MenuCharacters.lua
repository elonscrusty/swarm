--[[
	MenuCharacters.lua
	The CHARACTERS screen of the menu. The inspected hero stands on the dais in the middle
	of the 3D scene (Showcase), so the screen is two panels around it and nothing covers it:
	  left   the roster: one row per character with its class picture (hero_<Id>, drawn
	         class icon as stand-in) and its name in serif; the inspected row has a bright
	         gold border and gold name, a gold check marks the selected hero, a lock the
	         locked ones
	  right  the inspected character: portrait (art/portraits, drawn class icon as
	         stand-in), NAME and status pill (SELECTED / OWNED / LOCKED), role in gold caps,
	         the intro line, two mini cards (STARTING WEAPON with its tile, TRAIT), the
	         EFFECT / STRENGTH / TRADEOFF rows, for a locked hero an UNLOCK card (the
	         achievement and its progress bar, or the gold price), the big action button
	         (gold SELECT <NAME> / UNLOCK • N GOLD, grey LOCKED • <goal>), then SKINS: square
	         tiles (EQUIPPED / OWNED / R$ / SOON under each), the skin name and its button
	         (equip, Robux skin passes, the Starter Pack gold trim, "coming soon")
	Phones in landscape: the roster becomes two columns of name tiles when rows get too
	short. Portrait: character tabs on top (two rows of four), the hero in between, the
	details panel below.

	Tapping a skin previews it on the dais; an owned skin is equipped at once (as before).
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

local SWATCH = 52 -- skin tile size (reference px)
local LABEL_W = 86 -- width of the EFFECT / STRENGTH / TRADEOFF column

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

-- Short goal for the locked button: the achievement's first clause when it is short
-- ("Reach stage 4"), else its name ("Field Engineer").
local function shortGoal(a: { [string]: any }?): string
	if not a then
		return "Achievement"
	end
	local desc = tostring(a.Description or "")
	local first = string.match(desc, "^([^:%.]+)") or desc
	first = string.gsub(first, " in one run$", "")
	if #first > 0 and #first <= 22 then
		return first
	end
	return a.Name or "Achievement"
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

	ui.Header = UIKit.ScreenHeader(screen, "CHARACTERS", ctx.Back)

	-- left: the roster (landscape) / tabs (portrait)
	local listHolder, listFace = UIKit.Surface(screen, { Name = "List", Radius = Theme.Radius.L })
	ui.List = listHolder
	UIKit.pad(listFace, 12)
	ui.ListLayout = UIKit.list(listFace, { Padding = UDim.new(0, 8) })
	ui.Rows = {}
	ui.Marks = {}
	for i, id in ipairs(CharacterData.Order) do
		local def = CharacterData.Characters[id]
		local row = UIKit.Button(listFace, {
			Title = def.Name,
			Icon = Icons.CharacterIcon(id),
			IconSize = 38,
			TitleStyle = "H2",
			TitleSize = Theme.TextSize.H2 + 2,
			Align = "Left",
			Size = UDim2.new(1, 0, 0, 64),
			LayoutOrder = i,
			Shadow = false,
			Name = id,
			OnClick = function()
				MenuCharacters._inspect(id)
			end,
		})
		ui.Rows[id] = row
		-- state mark on the right edge (gold check = selected, lock = locked)
		ui.Marks[id] = { Frame = new("Frame", {
			Name = "Mark",
			BackgroundTransparency = 1,
			AnchorPoint = Vector2.new(1, 0.5),
			Position = UDim2.new(1, -14, 0.5, 0),
			Size = UDim2.fromOffset(20, 20),
			ZIndex = 4,
		}, row.Face), State = "" }
	end

	-- right: details
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
	UIKit.padding(scroll, 14, 18, 14, 18)
	ui.DetailList = UIKit.list(scroll, { Padding = UDim.new(0, 7), HorizontalAlignment = Enum.HorizontalAlignment.Left })

	-- head: portrait | NAME / ROLE | status pill
	local headH = math.max(56, TS(28) + TS(12) + 12)
	local head = new("Frame", { Name = "Head", BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, headH), LayoutOrder = 1 }, scroll)
	ui.PortraitWell = new("Frame", {
		Name = "Portrait",
		BackgroundColor3 = P.slate_950,
		BackgroundTransparency = 0.1,
		Size = UDim2.fromOffset(headH, headH),
		ClipsDescendants = true,
	}, head)
	UIKit.corner(ui.PortraitWell, Theme.Radius.M)
	UIKit.stroke(ui.PortraitWell, P.gold_400, 1.5, 0.25)
	local nameX = headH + 12
	ui.Name = text(head, "H1", "", {
		Name = "CharName",
		FontFace = Theme.Font.Display,
		Position = UDim2.fromOffset(nameX, 0),
		Size = UDim2.new(1, -(nameX + 110), 0, TS(28) + 6),
		TextTruncate = Enum.TextTruncate.AtEnd,
	}, 28)
	ui.Role = text(head, "Label", "", { Name = "Role", Position = UDim2.fromOffset(nameX, TS(28) + 8), Size = UDim2.new(1, -nameX, 0, TS(13) + 4), TextColor3 = P.gold_300 }, 13)
	ui.State = UIKit.StatusPill(head, "OWNED", { AnchorPoint = Vector2.new(1, 0), Position = UDim2.new(1, 0, 0, 4) })
	ui.Desc = text(scroll, "Body", "", {
		Name = "Intro",
		LayoutOrder = 2,
		TextWrapped = true,
		Size = UDim2.new(1, 0, 0, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		TextYAlignment = Enum.TextYAlignment.Top,
		TextColor3 = P.ivory_200,
	})

	-- two mini cards: STARTING WEAPON (tile) and TRAIT
	local factH = math.max(56, TS(11) + TS(16) + 22)
	local facts = new("Frame", { Name = "Facts", BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, factH), LayoutOrder = 3 }, scroll)
	local function miniCard(x: number, caption: string): (Frame, TextLabel, Frame)
		local card = UIKit.Panel(facts, { Name = caption, Position = UDim2.new(x, x > 0 and 5 or 0, 0, 0), Size = UDim2.new(0.5, -5, 1, 0) }, true)
		local well = new("Frame", { Name = "Well", BackgroundTransparency = 1, AnchorPoint = Vector2.new(0, 0.5), Position = UDim2.new(0, 8, 0.5, 0), Size = UDim2.fromOffset(40, 40) }, card)
		text(card, "Caption", UIKit.track(caption), { Position = UDim2.fromOffset(56, 8), Size = UDim2.new(1, -60, 0, TS(11) + 2), TextTruncate = Enum.TextTruncate.AtEnd }, 11)
		local value = text(card, "BodyStrong", "", { Position = UDim2.fromOffset(56, 10 + TS(11)), Size = UDim2.new(1, -60, 0, TS(16) + 4), TextTruncate = Enum.TextTruncate.AtEnd })
		return card, value, well
	end
	local _, weaponName, weaponWell = miniCard(0, "Starting weapon")
	ui.Weapon, ui.WeaponHolder = weaponName, weaponWell
	local _, bonus, traitWell = miniCard(0.5, "Trait")
	ui.Bonus = bonus
	ui.Bonus.TextColor3 = P.moss_200
	local traitDisc = new("Frame", { BackgroundColor3 = P.moss_800, Size = UDim2.fromScale(1, 1) }, traitWell)
	UIKit.corner(traitDisc, 999)
	UIKit.stroke(traitDisc, P.moss_300, 1.5, 0.3)
	Icons.Draw(traitDisc, "sparkle", { Size = 24, Color = P.moss_100, AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.5), Back = P.moss_800 })

	-- EFFECT / STRENGTH / TRADEOFF: a caption column and a wrapped line each
	local function infoRow(order: number, caption: string, color: Color3): TextLabel
		local row = new("Frame", { Name = caption, BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 0), AutomaticSize = Enum.AutomaticSize.Y, LayoutOrder = order }, scroll)
		UIKit.SectionLabel(row, caption, color, { Size = UDim2.fromOffset(LABEL_W, TS(14) + 4) })
		return text(row, "Small", "", {
			Position = UDim2.fromOffset(LABEL_W + 4, 0),
			Size = UDim2.new(1, -(LABEL_W + 4), 0, 0),
			AutomaticSize = Enum.AutomaticSize.Y,
			TextWrapped = true,
			TextColor3 = C.Text,
			TextYAlignment = Enum.TextYAlignment.Top,
		})
	end
	ui.Trait = infoRow(4, "Effect", P.gold_300)
	ui.Strength = infoRow(5, "Strength", P.gold_300)
	ui.Tradeoff = infoRow(6, "Tradeoff", P.crimson_300)

	-- UNLOCK card (locked heroes): goal name + progress, the rule, a gold bar
	local unlockCard = UIKit.Panel(scroll, { Name = "Unlock", LayoutOrder = 7, Size = UDim2.new(1, 0, 0, 0), AutomaticSize = Enum.AutomaticSize.Y }, true)
	ui.UnlockCard = unlockCard
	UIKit.padding(unlockCard, 8, 12, 10, 12)
	UIKit.list(unlockCard, { Padding = UDim.new(0, 4) })
	local uTop = new("Frame", { Name = "Top", BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, TS(16) + 4), LayoutOrder = 1 }, unlockCard)
	UIKit.SectionLabel(uTop, "Unlock", P.gold_300, { Size = UDim2.fromOffset(LABEL_W, TS(16) + 4) })
	ui.UnlockName = text(uTop, "Label", "", { Position = UDim2.fromOffset(LABEL_W + 4, 0), Size = UDim2.new(1, -(LABEL_W + 84), 1, 0), TextColor3 = P.ivory_100, TextTruncate = Enum.TextTruncate.AtEnd }, Theme.TextSize.Body)
	ui.UnlockCount = text(uTop, "Number", "", { AnchorPoint = Vector2.new(1, 0), Position = UDim2.fromScale(1, 0), Size = UDim2.new(0, 80, 1, 0), TextXAlignment = Enum.TextXAlignment.Right, TextColor3 = P.gold_200 }, Theme.TextSize.Body)
	ui.UnlockRule = text(unlockCard, "Small", "", { Name = "Rule", LayoutOrder = 2, Size = UDim2.new(1, 0, 0, 0), AutomaticSize = Enum.AutomaticSize.Y, TextWrapped = true, TextColor3 = P.ivory_200 })
	ui.UnlockMeter = UIKit.Meter(unlockCard, { Size = UDim2.new(1, 0, 0, 8), Color = P.gold_400, LayoutOrder = 3 } :: any)
	ui.UnlockMeter.Frame.Name = "Progress"

	ui.Action = UIKit.Button(scroll, {
		Kind = "Primary",
		Title = "SELECT",
		TitleStyle = "H3",
		Icon = "play",
		IconSize = 20,
		Align = "Center",
		Size = UDim2.new(1, 0, 0, Theme.Size.Button - 4),
		LayoutOrder = 8,
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
	local div = new("Frame", { Name = "Rule", BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 7), LayoutOrder = 9 }, scroll)
	new("Frame", { BackgroundColor3 = C.PanelEdge, BackgroundTransparency = 0.55, BorderSizePixel = 0, AnchorPoint = Vector2.new(0, 0.5), Position = UDim2.fromScale(0, 0.5), Size = UDim2.new(1, 0, 0, 1) }, div)
	UIKit.SectionLabel(scroll, "Skins", P.gold_300, { LayoutOrder = 10, Size = UDim2.new(1, 0, 0, TS(12) + 2) })
	ui.Swatches = new("Frame", { Name = "Swatches", BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 0), LayoutOrder = 11, AutomaticSize = Enum.AutomaticSize.Y }, scroll)
	UIKit.list(ui.Swatches, { FillDirection = Enum.FillDirection.Horizontal, Padding = UDim.new(0, 10), Wraps = true })
	-- skin name, its state, and its button (EQUIP / GET SKIN / COMING SOON) on one line
	local skinRowH = math.max(40, TS(16) + 12)
	local skinRow = new("Frame", { Name = "SkinRow", BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, skinRowH), LayoutOrder = 12 }, scroll)
	ui.SkinName = text(skinRow, "BodyStrong", "", { Size = UDim2.new(1, -190, 1, 0), TextTruncate = Enum.TextTruncate.AtEnd })
	ui.SkinState = text(skinRow, "Caption", "", { AnchorPoint = Vector2.new(1, 0), Position = UDim2.fromScale(1, 0), Size = UDim2.new(0, 180, 1, 0), TextXAlignment = Enum.TextXAlignment.Right, TextColor3 = P.gold_200 })
	ui.SkinAction = UIKit.Button(skinRow, {
		Kind = "Outline",
		Title = "GET SKIN",
		Icon = "robux",
		IconSize = 18,
		Align = "Center",
		AnchorPoint = Vector2.new(1, 0),
		Position = UDim2.fromScale(1, 0),
		Size = UDim2.new(0, 180, 1, 0),
		Shadow = false,
		OnClick = function()
			local p = profile()
			if not p then
				return
			end
			if skinOwned(p, inspSkin) then
				Remotes.Get("EquipSkin"):FireServer(inspChar, inspSkin)
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

	local swatches: { [string]: { Hit: TextButton, Stroke: UIStroke, Lock: Frame, Badge: TextLabel } } = {}

	local function buildSwatches()
		for _, c in ipairs(ui.Swatches:GetChildren()) do
			if c:IsA("GuiObject") then
				c:Destroy()
			end
		end
		table.clear(swatches)
		for order, skinId in ipairs(CharacterData.SkinsFor(inspChar)) do
			local look = CharacterData.ResolveLook(inspChar, skinId)
			local cell = new("Frame", { Name = skinId, BackgroundTransparency = 1, Size = UDim2.fromOffset(SWATCH + 8, SWATCH + TS(10) + 6), LayoutOrder = order }, ui.Swatches)
			local hit = new("TextButton", {
				Name = "Tile",
				Text = "",
				AutoButtonColor = false,
				BackgroundColor3 = look.Colors.Torso,
				AnchorPoint = Vector2.new(0.5, 0),
				Position = UDim2.fromScale(0.5, 0),
				Size = UDim2.fromOffset(SWATCH, SWATCH),
				ClipsDescendants = true,
			}, cell)
			UIKit.corner(hit, Theme.Radius.M)
			UIKit.Focusable(hit)
			new("UIGradient", { Rotation = 90, Color = ColorSequence.new(Color3.new(1, 1, 1), Color3.fromRGB(170, 170, 170)) }, hit)
			new("Frame", { BackgroundColor3 = look.Colors.Hat, BorderSizePixel = 0, Size = UDim2.new(1, 0, 0.36, 0) }, hit)
			new("Frame", { BackgroundColor3 = look.GoldTrim and P.gold_400 or look.Colors.Accent, BorderSizePixel = 0, AnchorPoint = Vector2.new(0, 0.5), Position = UDim2.fromScale(0, 0.62), Size = UDim2.new(1, 0, 0, 6) }, hit)
			local lock = new("Frame", { Name = "Lock", BackgroundColor3 = P.slate_950, BackgroundTransparency = 0.3, Size = UDim2.fromScale(1, 1), ZIndex = 3 }, hit)
			Icons.Draw(lock, "lock", { Size = 20, Color = P.ivory_200, Back = P.slate_950, AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.5) })
			local badge = text(cell, "Caption", "", {
				Name = "State",
				AnchorPoint = Vector2.new(0.5, 1),
				Position = UDim2.fromScale(0.5, 1),
				Size = UDim2.new(1, 12, 0, TS(10) + 2),
				TextXAlignment = Enum.TextXAlignment.Center,
				TextColor3 = C.TextMuted,
			}, 10)
			local st = UIKit.stroke(hit, P.slate_950, 2, 0)
			UIAnim.Button(hit)
			hit.Activated:Connect(function()
				UIKit.Click()
				inspSkin = skinId
				Showcase.Show(inspChar, inspSkin)
				local p = profile()
				if p and skinOwned(p, skinId) and (p.Skins[inspChar] or "Default") ~= skinId then
					Remotes.Get("EquipSkin"):FireServer(inspChar, skinId)
				end
				MenuCharacters._refresh()
			end)
			swatches[skinId] = { Hit = hit, Stroke = st, Lock = lock, Badge = badge }
		end
	end

	-- the portrait (art/portraits/<Id>; the drawn class icon while it loads / if missing)
	local function buildPortrait(id: string)
		for _, c in ipairs(ui.PortraitWell:GetChildren()) do
			if c:IsA("GuiObject") then
				c:Destroy()
			end
		end
		UIKit.ArtPicture(ui.PortraitWell, "portraits/" .. id, nil, function(fb: Frame)
			Icons.Character(fb, id, { Size = math.floor(headH * 0.7), AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.5) })
		end)
	end

	local function setMark(id: string, state: string)
		local m = ui.Marks[id]
		if m.State == state then
			return
		end
		m.State = state
		for _, c in ipairs(m.Frame:GetChildren()) do
			c:Destroy()
		end
		if state == "Selected" then
			Icons.Draw(m.Frame, "check", { Size = 20, Color = P.gold_300, Back = P.slate_900 })
		elseif state == "Locked" then
			Icons.Draw(m.Frame, "lock", { Size = 18, Color = P.stone_300, Back = P.slate_900, AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.5) })
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
			UIKit.Tile(ui.WeaponHolder, { Id = def.StartWeapon, Size = 40 })
		end
		for id, row in pairs(ui.Rows) do
			local own = p.OwnedCharacters[id] == true
			row.SetSelected(id == inspChar)
			setMark(id, (p.SelectedCharacter == id) and "Selected" or (own and "" or "Locked"))
		end
		local own = p.OwnedCharacters[inspChar] == true
		local selected = p.SelectedCharacter == inspChar
		ui.Name.Text = string.upper(def.Name)
		ui.Role.Text = UIKit.track(def.Role or "")
		ui.Desc.Text = def.Description
		local weapon = WeaponData.Weapons[def.StartWeapon]
		ui.Weapon.Text = weapon and weapon.Name or def.StartWeapon
		ui.Bonus.Text = def.Trait and def.Trait.Name or (def.BonusText or "")
		ui.Trait.Text = def.Trait and def.Trait.Text or (def.BonusText or "")
		ui.Strength.Text = def.Strengths or ""
		ui.Tradeoff.Text = def.Tradeoff or ""
		UIKit.SetStatus(ui.State, selected and "SELECTED" or (own and "OWNED" or "LOCKED"))
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
				ui.UnlockCount.Text = UIKit.formatNumber(math.min(p.Gold, def.Cost)) .. " / " .. UIKit.formatNumber(def.Cost)
				ui.UnlockRule.Text = "Buy with gold earned in runs. You have " .. UIKit.formatNumber(p.Gold) .. " gold."
				ui.UnlockMeter.Set(math.clamp(p.Gold / math.max(1, def.Cost), 0, 1), "")
			end
		end
		if not own and def.Unlock then
			local a = AchievementData.Achievements[def.Unlock.Achievement]
			ui.Action.SetKind("Secondary")
			ui.Action.SetText("LOCKED  •  " .. string.upper(shortGoal(a)))
			ui.Action.SetIcon("lock")
			ui.Action.SetEnabled(false)
		elseif not own then
			ui.Action.SetEnabled(p.Gold >= def.Cost)
			ui.Action.SetKind("Primary")
			ui.Action.SetText("UNLOCK  •  " .. UIKit.formatNumber(def.Cost) .. " GOLD")
			ui.Action.SetIcon("coin")
		elseif selected then
			ui.Action.SetKind("Secondary")
			ui.Action.SetText(string.upper(def.Name) .. " SELECTED")
			ui.Action.SetIcon("check")
			ui.Action.SetEnabled(false)
		else
			ui.Action.SetEnabled(true)
			ui.Action.SetKind("Primary")
			ui.Action.SetText("SELECT " .. string.upper(def.Name))
			ui.Action.SetIcon("play")
		end
		local equipped = p.Skins[inspChar] or "Default"
		for skinId, s in pairs(swatches) do
			local mine = skinOwned(p, skinId)
			s.Lock.Visible = not mine
			if skinId == equipped then
				s.Badge.Text = "EQUIPPED"
				s.Badge.TextColor3 = P.gold_200
			else
				s.Badge.Text = mine and "OWNED" or (skinPassId(skinId) and "R$" or "SOON")
				s.Badge.TextColor3 = C.TextMuted
			end
			s.Stroke.Color = skinId == equipped and C.Selected or (skinId == inspSkin and P.ivory_100 or P.slate_950)
			s.Stroke.Thickness = (skinId == equipped or skinId == inspSkin) and 3 or 2
		end
		local skin = CharacterData.Skins[inspSkin]
		ui.SkinName.Text = skin and skin.Name or (def.Name .. " (default)")
		local mine = skinOwned(p, inspSkin)
		local action = ui.SkinAction
		if mine then
			ui.SkinState.Text = UIKit.track(inspSkin == equipped and "Equipped" or "Owned")
			action.Instance.Visible = inspSkin ~= equipped
			action.SetEnabled(true)
			action.SetKind("Secondary")
			action.SetText("EQUIP")
			action.SetIcon("check")
		else
			local passId = skinPassId(inspSkin)
			action.Instance.Visible = true
			action.SetKind("Outline")
			action.SetIcon("robux")
			if skin and skin.Pass == "StarterPack" then
				action.SetText(passId and "STARTER PACK" or "COMING SOON")
			else
				action.SetText(passId and "GET SKIN" or "COMING SOON")
			end
			action.SetEnabled(passId ~= nil)
		end
		ui.SkinState.Visible = not action.Instance.Visible
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
		UIAnim.Punch(ui.Detail, 0.03)
		if screen.Visible then
			UIAnim.Burst(ui.Detail, UDim2.fromScale(0.5, 0.12), { P.gold_300, P.ivory_100, P.steel_200 }, 12, 70)
		end
	end

	-- title size on a compact tile: long names ("Necromancer") a step smaller so they fit
	local function tileSize(id: string): number
		local def = CharacterData.Characters[id]
		return (def and #def.Name > 9) and Theme.TextSize.Small - 1 or Theme.TextSize.Body
	end

	-- roster rows as tiles (no picture, centred name) or as full rows
	local function rowStyle(id: string, tile: boolean, titleSize: number)
		local row = ui.Rows[id]
		row.SetIcon(not tile and Icons.CharacterIcon(id) or nil)
		local column = row.Content:FindFirstChild("Text") :: Frame?
		if column and tile then
			column.Size = UDim2.fromScale(1, 1)
		elseif column then
			column.Size = UDim2.new(1, -(38 + Theme.Space.M + 22), 1, 0)
		end
		if row.Title then
			row.Title.TextXAlignment = tile and Enum.TextXAlignment.Center or Enum.TextXAlignment.Left
			row.Title.TextSize = TS(titleSize)
		end
		ui.Marks[id].Frame.Visible = not tile
	end

	local function layout(v: Vector2, portrait: boolean, ins: { [string]: number })
		local W, H = v.X, v.Y
		local M = UIKit.IsCompact() and Theme.Layout.MarginCompact or Theme.Layout.Margin
		local headY = math.max(ins.Top + 4, 12)
		place(ui.Header.Frame, M, headY, math.min(520, W - 2 * M), 56)
		-- portrait: the stats chip sits under the header (LobbyScreen), the tabs under it
		local top = headY + 66 + (portrait and 58 or 0)
		-- the details panel fits its content (measured), up to the room there is
		local measured = ui.DetailList.AbsoluteContentSize.Y / math.max(0.01, host.Scale())
		local contentH = measured > 10 and (measured + 30) or (UIKit.IsCompact() and 640 or 590)
		local n = #CharacterData.Order
		if portrait then
			-- tabs: one compact button per character, in two rows of four when there are
			-- more than five heroes (names stay readable)
			local perRow = n > 5 and math.ceil(n / 2) or n
			local tabRows = math.ceil(n / perRow)
			local listH = 24 + tabRows * 52 + (tabRows - 1) * 6
			ui.ListLayout.FillDirection = Enum.FillDirection.Horizontal
			ui.ListLayout.Wraps = true
			ui.ListLayout.Padding = UDim.new(0, 6)
			local w = W - 2 * M
			place(ui.List, M, top, w, listH)
			for id, row in pairs(ui.Rows) do
				row.Instance.Size = UDim2.new(1 / perRow, -6, 0, 52)
				rowStyle(id, true, perRow >= 4 and tileSize(id) or Theme.TextSize.Body + 1)
			end
			local detailH = math.min(contentH, math.floor(H * 0.54) - (listH - 76))
			place(ui.Detail, M, H - M - detailH, w, detailH)
			if ctx.Current() == "Characters" then
				workspace.CurrentCamera:SetAttribute("MenuHeroY", ((top + listH) + (H - M - detailH)) / 2 / H)
			end
		else
			-- one column of rows (shorter rows when needed); when even short rows don't fit
			-- (phones in landscape) two columns of name tiles
			local lw = math.clamp(W * 0.22, 260, 320)
			local inner = H - M - top - 24
			local rowH = math.floor((inner - (n - 1) * 8) / n)
			local cols = 1
			if rowH < 50 then
				cols = 2
				local rows = math.ceil(n / 2)
				rowH = math.clamp(math.floor((inner - (rows - 1) * 6) / rows), 40, 72)
			end
			rowH = math.min(68, rowH)
			if cols == 2 then
				lw += 36 -- room for "Necromancer" in a half-width tile
			end
			local gap = cols == 2 and 6 or 8
			local rows = math.ceil(n / cols)
			ui.ListLayout.FillDirection = cols == 2 and Enum.FillDirection.Horizontal or Enum.FillDirection.Vertical
			ui.ListLayout.Wraps = cols == 2
			ui.ListLayout.Padding = UDim.new(0, gap)
			place(ui.List, M, top, lw, rows * rowH + (rows - 1) * gap + 24)
			for id, row in pairs(ui.Rows) do
				row.Instance.Size = cols == 2 and UDim2.new(0.5, -gap / 2, 0, rowH) or UDim2.new(1, 0, 0, rowH)
				rowStyle(id, cols == 2, cols == 2 and tileSize(id) or (rowH >= 56 and Theme.TextSize.H2 + 2 or Theme.TextSize.H2))
			end
			local rw = math.clamp(W * 0.36, 400, 500)
			local dTop = math.max(top, 74)
			place(ui.Detail, W - M - rw, dTop, rw, math.min(contentH, H - M - dTop))
			if ctx.Current() == "Characters" then
				workspace.CurrentCamera:SetAttribute("MenuHeroY", 0.5)
			end
		end
	end

	ui.DetailList:GetPropertyChangedSignal("AbsoluteContentSize"):Connect(function()
		if ctx.Current() == "Characters" then
			layout(host.VirtualSize(), host.IsPortrait(), host.Insets())
		end
	end)

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

return MenuCharacters
