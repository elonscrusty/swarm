--[[
	MenuCharacters.lua
	The CHARACTERS screen of the menu. The inspected hero stands on the dais in the middle
	of the 3D scene (Showcase), so the screen is two panels around it:
	  left   every character: class icon, name, state (selected / owned / price)
	  right  the inspected character: role, description, starting weapon, trait, then
	         TRAIT / STRENGTH / TRADEOFF lines, how to unlock it (gold, or an achievement
	         with its progress: the Ranger), the UNLOCK / SELECT button, and its skins (equip, preview, Robux skin passes,
	         the Starter Pack gold trim, "coming soon" for passes not set up)
	Portrait: character tabs on top, the hero in between, the details panel below.

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

	-- left: the list (landscape) / tabs (portrait)
	local listHolder, listFace = UIKit.Surface(screen, { Name = "List", Radius = Theme.Radius.L })
	ui.List = listHolder
	UIKit.pad(listFace, 12)
	ui.ListLayout = UIKit.list(listFace, { Padding = UDim.new(0, 8) })
	ui.Rows = {}
	for i, id in ipairs(CharacterData.Order) do
		local def = CharacterData.Characters[id]
		ui.Rows[id] = UIKit.Button(listFace, {
			Title = def.Name,
			Subtitle = def.Role,
			Icon = Icons.CharacterIcon(id),
			IconSize = 30,
			TitleStyle = "H2",
			Align = "Left",
			Size = UDim2.new(1, 0, 0, 72),
			LayoutOrder = i,
			Shadow = false,
			Name = id,
			OnClick = function()
				MenuCharacters._inspect(id)
			end,
		})
	end

	-- right: details
	local detailHolder, detailFace = UIKit.Surface(screen, { Name = "Details", Radius = Theme.Radius.L })
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
	UIKit.padding(scroll, 16, 18, 16, 18)
	ui.DetailList = UIKit.list(scroll, { Padding = UDim.new(0, 8), HorizontalAlignment = Enum.HorizontalAlignment.Left })
	local head = new("Frame", { BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, TS(30) + 6), LayoutOrder = 1 }, scroll)
	ui.Name = text(head, "H1", "", { Size = UDim2.new(1, -110, 1, 0) })
	ui.State = UIKit.Badge(head, "OWNED", "Slate", { AnchorPoint = Vector2.new(1, 0.5), Position = UDim2.new(1, 0, 0.5, 0) })
	ui.Role = text(scroll, "Label", "", { LayoutOrder = 2, TextColor3 = P.gold_300 })
	ui.Desc = text(scroll, "Body", "", { LayoutOrder = 3, TextWrapped = true, Size = UDim2.new(1, 0, 0, TS(16) * 2 + 8), TextYAlignment = Enum.TextYAlignment.Top })
	-- starting weapon + bonus
	local facts = new("Frame", { BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 56), LayoutOrder = 4 }, scroll)
	ui.WeaponHolder = new("Frame", { BackgroundTransparency = 1, Size = UDim2.fromOffset(48, 48), Position = UDim2.fromOffset(0, 4) }, facts)
	text(facts, "Caption", UIKit.track("Starts with"), { Position = UDim2.fromOffset(58, 6), Size = UDim2.new(0.5, -58, 0, TS(12) + 2) })
	ui.Weapon = text(facts, "BodyStrong", "", { Position = UDim2.fromOffset(58, 10 + TS(12)), Size = UDim2.new(0.5, -58, 0, TS(16) + 4), TextTruncate = Enum.TextTruncate.AtEnd })
	text(facts, "Caption", UIKit.track("Trait"), { Position = UDim2.new(0.5, 8, 0, 6), Size = UDim2.new(0.5, -8, 0, TS(12) + 2) })
	ui.Bonus = text(facts, "BodyStrong", "", { Position = UDim2.new(0.5, 8, 0, 10 + TS(12)), Size = UDim2.new(0.5, -8, 0, TS(16) + 4), TextColor3 = P.moss_200, TextTruncate = Enum.TextTruncate.AtEnd })
	-- TRAIT / STRENGTH / TRADEOFF: a caption column and a wrapped line each
	local function infoRow(order: number, caption: string, color: Color3): TextLabel
		local row = new("Frame", { Name = caption, BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 0), AutomaticSize = Enum.AutomaticSize.Y, LayoutOrder = order }, scroll)
		text(row, "Caption", UIKit.track(caption), { Size = UDim2.fromOffset(92, TS(16) + 2), TextColor3 = color })
		return text(row, "Small", "", {
			Position = UDim2.fromOffset(96, 0),
			Size = UDim2.new(1, -96, 0, 0),
			AutomaticSize = Enum.AutomaticSize.Y,
			TextWrapped = true,
			TextColor3 = C.Text,
			TextYAlignment = Enum.TextYAlignment.Top,
		})
	end
	ui.Trait = infoRow(5, "Effect", P.moss_200)
	ui.Strength = infoRow(6, "Strength", P.gold_300)
	ui.Tradeoff = infoRow(7, "Tradeoff", P.crimson_300)
	ui.Unlock = text(scroll, "BodyStrong", "", {
		Name = "Unlock",
		LayoutOrder = 8,
		Size = UDim2.new(1, 0, 0, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		TextWrapped = true,
		RichText = true,
		TextColor3 = P.gold_200,
	})
	ui.Action = UIKit.Button(scroll, {
		Kind = "Primary",
		Title = "SELECT",
		Icon = "check",
		IconSize = 20,
		Align = "Center",
		Size = UDim2.new(1, 0, 0, Theme.Size.Button),
		LayoutOrder = 9,
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
	UIKit.Divider(scroll, 200, { LayoutOrder = 10, Size = UDim2.new(1, 0, 0, 10) })
	text(scroll, "Caption", UIKit.track("Skins"), { LayoutOrder = 11 })
	ui.Swatches = new("Frame", { BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 56), LayoutOrder = 12, AutomaticSize = Enum.AutomaticSize.Y }, scroll)
	UIKit.list(ui.Swatches, { FillDirection = Enum.FillDirection.Horizontal, Padding = UDim.new(0, 8), Wraps = true })
	local skinRow = new("Frame", { BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, TS(16) + 8), LayoutOrder = 13 }, scroll)
	ui.SkinName = text(skinRow, "BodyStrong", "", { Size = UDim2.new(1, -120, 1, 0) })
	ui.SkinState = text(skinRow, "Caption", "", { AnchorPoint = Vector2.new(1, 0), Position = UDim2.fromScale(1, 0), Size = UDim2.new(0, 120, 1, 0), TextXAlignment = Enum.TextXAlignment.Right })
	ui.SkinAction = UIKit.Button(scroll, {
		Kind = "Outline",
		Title = "GET SKIN",
		Icon = "robux",
		IconSize = 20,
		Align = "Center",
		Size = UDim2.new(1, 0, 0, 50),
		LayoutOrder = 14,
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
			local hit = new("TextButton", { Name = skinId, Text = "", AutoButtonColor = false, BackgroundColor3 = look.Colors.Torso, Size = UDim2.fromOffset(56, 56), LayoutOrder = order, ClipsDescendants = true }, ui.Swatches)
			UIKit.corner(hit, Theme.Radius.M)
			UIKit.Focusable(hit)
			new("UIGradient", { Rotation = 90, Color = ColorSequence.new(Color3.new(1, 1, 1), Color3.fromRGB(170, 170, 170)) }, hit)
			new("Frame", { BackgroundColor3 = look.Colors.Hat, BorderSizePixel = 0, Size = UDim2.new(1, 0, 0.36, 0) }, hit)
			new("Frame", { BackgroundColor3 = look.GoldTrim and P.gold_400 or look.Colors.Accent, BorderSizePixel = 0, AnchorPoint = Vector2.new(0, 0.5), Position = UDim2.fromScale(0, 0.62), Size = UDim2.new(1, 0, 0, 6) }, hit)
			local lock = new("Frame", { Name = "Lock", BackgroundColor3 = C.Backdrop, BackgroundTransparency = 0.45, Size = UDim2.fromScale(1, 1), ZIndex = 3 }, hit)
			Icons.Draw(lock, "lock", { Size = 20, Color = P.ivory_100, Back = P.slate_900, AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.42) })
			local badge = text(hit, "Caption", "", { AnchorPoint = Vector2.new(0.5, 1), Position = UDim2.new(0.5, 0, 1, -2), Size = UDim2.new(1, 0, 0, TS(12)), TextXAlignment = Enum.TextXAlignment.Center, TextColor3 = P.gold_200, ZIndex = 4 }, 11)
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
			for _, c in ipairs(ui.WeaponHolder:GetChildren()) do
				c:Destroy()
			end
			UIKit.Tile(ui.WeaponHolder, { Id = def.StartWeapon, Size = 48 })
		end
		for id, row in pairs(ui.Rows) do
			local d = CharacterData.Characters[id]
			local own = p.OwnedCharacters[id] == true
			local lockText = d.Unlock and ("Locked · " .. ((AchievementData.Achievements[d.Unlock.Achievement] or {}).Name or "achievement")) or ("Locked · " .. UIKit.formatNumber(d.Cost) .. " gold")
			local sub = (p.SelectedCharacter == id) and "Selected" or (own and d.Role or lockText)
			row.SetText(d.Name, sub)
			row.SetSelected(id == inspChar)
			if row.Subtitle then
				row.Subtitle.TextColor3 = (p.SelectedCharacter == id) and P.moss_200 or (own and C.TextMuted or P.gold_300)
			end
		end
		local own = p.OwnedCharacters[inspChar] == true
		local selected = p.SelectedCharacter == inspChar
		ui.Name.Text = def.Name
		ui.Role.Text = UIKit.track(def.Role or "")
		ui.Desc.Text = def.Description
		local weapon = WeaponData.Weapons[def.StartWeapon]
		ui.Weapon.Text = weapon and weapon.Name or def.StartWeapon
		ui.Bonus.Text = def.Trait and def.Trait.Name or (def.BonusText or "")
		ui.Trait.Text = def.Trait and def.Trait.Text or (def.BonusText or "")
		ui.Strength.Text = def.Strengths or ""
		ui.Tradeoff.Text = def.Tradeoff or ""
		-- how to unlock it (gold price, or the achievement and its progress)
		local unlockText = ""
		if not p.OwnedCharacters[inspChar] then
			if def.Unlock then
				local aid = def.Unlock.Achievement
				local a = AchievementData.Achievements[aid]
				local progress = p.Achievements and p.Achievements.Progress and tonumber(p.Achievements.Progress[aid]) or 0
				unlockText = string.format('<font color="%s">UNLOCK</font>  <b>%s</b>: %s <font color="%s">%s</font>', UIKit.hex(C.TextMuted), a and a.Name or aid, a and a.Description or "", UIKit.hex(C.TextMuted), (string.gsub(AchievementData.ProgressText(aid, progress), " ", "")))
			else
				unlockText = string.format('<font color="%s">UNLOCK</font>  %s gold', UIKit.hex(C.TextMuted), UIKit.formatNumber(def.Cost))
			end
		end
		ui.Unlock.Text = unlockText
		ui.Unlock.Visible = unlockText ~= ""
		ui.State.Text = selected and "SELECTED" or (own and "OWNED" or "LOCKED")
		ui.State.BackgroundColor3 = selected and P.moss_600 or (own and P.slate_600 or P.crimson_700)
		if not own and def.Unlock then
			local a = AchievementData.Achievements[def.Unlock.Achievement]
			ui.Action.SetKind("Outline")
			ui.Action.SetText("LOCKED · " .. string.upper(a and a.Name or "Achievement"))
			ui.Action.SetIcon("lock")
			ui.Action.SetEnabled(false)
		elseif not own then
			ui.Action.SetKind("Outline")
			ui.Action.SetText("UNLOCK  " .. UIKit.formatNumber(def.Cost) .. " GOLD")
			ui.Action.SetIcon("coin")
			ui.Action.SetEnabled(p.Gold >= def.Cost)
		elseif selected then
			ui.Action.SetKind("Secondary")
			ui.Action.SetText("SELECTED")
			ui.Action.SetIcon("check")
			ui.Action.SetEnabled(false)
		else
			ui.Action.SetEnabled(true)
			ui.Action.SetKind("Primary")
			ui.Action.SetText("SELECT")
			ui.Action.SetIcon("check")
		end
		local equipped = p.Skins[inspChar] or "Default"
		for skinId, s in pairs(swatches) do
			local mine = skinOwned(p, skinId)
			s.Lock.Visible = not mine
			s.Badge.Text = mine and "" or (skinPassId(skinId) and "R$" or "SOON")
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
				ui.SkinState.Text = UIKit.track("Starter Pack")
				action.SetText(passId and "GET STARTER PACK" or "COMING SOON")
			else
				ui.SkinState.Text = UIKit.track("Skin pass")
				action.SetText(passId and "GET SKIN" or "COMING SOON")
			end
			action.SetEnabled(passId ~= nil)
		end
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
		local contentH = measured > 10 and (measured + 36) or (UIKit.IsCompact() and 640 or 590)
		if portrait then
			-- tabs row: one compact button per character
			ui.ListLayout.FillDirection = Enum.FillDirection.Horizontal
			local w = W - 2 * M
			place(ui.List, M, top, w, 76)
			for _, row in pairs(ui.Rows) do
				row.Instance.Size = UDim2.new(1 / #CharacterData.Order, -6, 1, 0)
				if row.Subtitle then
					row.Subtitle.Visible = false
				end
				row.SetIcon(nil)
				local column = row.Content:FindFirstChild("Text") :: Frame?
				if column then
					column.Size = UDim2.fromScale(1, 1)
				end
				if row.Title then
					row.Title.TextXAlignment = Enum.TextXAlignment.Center
					-- five names in one row: a smaller title so none is cut off
					row.Title.TextSize = TS(Theme.TextSize.Body + 1)
				end
			end
			local detailH = math.min(contentH, math.floor(H * 0.52))
			place(ui.Detail, M, H - M - detailH, w, detailH)
			if ctx.Current() == "Characters" then
				workspace.CurrentCamera:SetAttribute("MenuHeroY", ((top + 76) + (H - M - detailH)) / 2 / H)
			end
		else
			ui.ListLayout.FillDirection = Enum.FillDirection.Vertical
			local lw = math.clamp(W * 0.24, 270, 330)
			local n = #CharacterData.Order
			place(ui.List, M, top, lw, n * 72 + (n - 1) * 8 + 24)
			for id, row in pairs(ui.Rows) do
				row.Instance.Size = UDim2.new(1, 0, 0, 72)
				if row.Subtitle then
					row.Subtitle.Visible = true
				end
				row.SetIcon(Icons.CharacterIcon(id))
				if row.Title then
					row.Title.TextXAlignment = Enum.TextXAlignment.Left
					row.Title.TextSize = TS(Theme.TextSize.H2)
				end
			end
			local rw = math.clamp(W * 0.32, 360, 440)
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
