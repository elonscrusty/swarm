--[[
	MenuTrack.lua
	The TRACK screen: your account level (AccountData.lua), the XP bar to the next level,
	how XP is earned, and every cosmetic reward of levels 1-50 (titles, nameplate colours,
	lobby dais rings, portrait frames). Earned ones can be worn (EquipCosmetic; tap a worn
	one to take it off); locked ones say the level they need. Cosmetic only: nothing here
	changes a run.
]]

local Shared = game:GetService("ReplicatedStorage"):WaitForChild("Shared")
local Theme = require(Shared:WaitForChild("Theme"))
local Remotes = require(Shared:WaitForChild("Remotes"))
local AccountData = require(Shared:WaitForChild("AccountData"))
local CharacterData = require(Shared:WaitForChild("CharacterData"))
local UIKit = require(script.Parent.UIKit)
local UIAnim = require(script.Parent.UIAnim)
local Icons = require(script.Parent.Icons)
local Cosmetics = require(script.Parent.Cosmetics)

local MenuTrack = {}

local new, text, TS = UIKit.new, UIKit.text, UIKit.TS
local C, P = Theme.Color, Theme.Palette

local KIND_ICON = { Title = "track_Title", Color = "track_Color", Ring = "track_Ring", Frame = "track_Frame" }
local KIND_LABEL = { Title = "Title", Color = "Name color", Ring = "Dais ring", Frame = "Portrait frame" }
local WORN_KEY = { Title = "Title", Color = "NameColor", Ring = "Ring", Frame = "Frame" }

local function place(obj: GuiObject, x: number, y: number, w: number, h: number)
	obj.Position = UDim2.fromOffset(math.floor(x + 0.5), math.floor(y + 0.5))
	obj.Size = UDim2.fromOffset(math.floor(w + 0.5), math.floor(h + 0.5))
end

-- The profile's account view (level 1 with no XP until the first sync).
function MenuTrack.Account(profile: { [string]: any }?): (number, number, number, number)
	local a = profile and profile.Account
	if type(a) ~= "table" then
		return 1, 0, AccountData.XPToNext(1), 0
	end
	local level, into, need = AccountData.LevelFor(tonumber(a.XP) or 0)
	return level, into, need, tonumber(a.XP) or 0
end

function MenuTrack.Build(screen: Frame, ctx: { [string]: any })
	local host = ctx.Host
	local ui: { [string]: any } = {}
	ui.Header = UIKit.ScreenHeader(screen, "ACCOUNT LEVEL", ctx.Back)
	local holder, face = UIKit.Surface(screen, { Name = "Panel", Radius = Theme.Radius.L, Transparency = 0.06 })
	ui.Panel = holder
	UIKit.padding(face, 16, 16, 16, 16)

	-- head: framed hero medallion, level, XP bar, how XP is earned
	local head = new("Frame", { Name = "Head", BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 104) }, face)
	ui.Head = head
	local medal = new("Frame", { Name = "Portrait", BackgroundColor3 = C.PanelInset, BackgroundTransparency = 0.05, Position = UDim2.fromOffset(10, 10), Size = UDim2.fromOffset(80, 80) }, head)
	UIKit.corner(medal, 999)
	ui.MedalStroke = UIKit.stroke(medal, P.gold_400, 2.5, 0.05)
	ui.Medal = medal
	ui.Level = text(head, "H1", "Level 1", { Name = "Level", Position = UDim2.fromOffset(110, 4), Size = UDim2.new(1, -110, 0, TS(30) + 6) })
	ui.Meter = UIKit.Meter(head, {
		Gradient = ColorSequence.new(P.gold_500, P.gold_300),
		TextStyle = "Number",
		TextSize = Theme.TextSize.Small,
		Position = UDim2.fromOffset(110, TS(30) + 14),
		Size = UDim2.new(1, -110, 0, 22),
	})
	ui.How = text(head, "Small", string.format("XP from every run: %d per minute survived, %d per stage cleared, 1 per %d kills, %d per boss, %d for a win; curses add their gold bonus, the daily's scored attempt +%d. Rewards are cosmetic only.", math.floor(60 * AccountData.XP.PerSecond + 0.5), AccountData.XP.PerStage, AccountData.XP.PerKills, AccountData.XP.PerBoss, AccountData.XP.Win, AccountData.XP.Daily), {
		Name = "How",
		Position = UDim2.fromOffset(110, TS(30) + 44),
		Size = UDim2.new(1, -110, 0, TS(14) * 2 + 6),
		TextWrapped = true,
		TextYAlignment = Enum.TextYAlignment.Top,
	})

	local list = new("ScrollingFrame", {
		Name = "Rewards",
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		ScrollBarThickness = 4,
		ScrollBarImageColor3 = P.gold_500,
		AutomaticCanvasSize = Enum.AutomaticSize.Y,
		CanvasSize = UDim2.new(),
		ScrollingDirection = Enum.ScrollingDirection.Y,
	}, face)
	UIKit.padding(list, 2, 8, 6, 2)
	UIKit.list(list, { Padding = UDim.new(0, 6) })
	ui.List = list

	local function preview(f: Frame, r: AccountData.Reward, unlocked: boolean)
		local box = new("Frame", { Name = "Preview", BackgroundTransparency = 1, AnchorPoint = Vector2.new(0, 0.5), Position = UDim2.new(0, 84, 0.5, 0), Size = UDim2.fromOffset(40, 40) }, f)
		if r.Kind == "Frame" then
			local m = new("Frame", { BackgroundColor3 = C.PanelInset, AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.5), Size = UDim2.fromOffset(30, 30) }, box)
			UIKit.corner(m, 999)
			Icons.Character(m, (ctx.Profile() or {}).SelectedCharacter or CharacterData.Default, { Size = 18, AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.5), Back = P.slate_950 })
			Cosmetics.Frame(m, r.Id)
		elseif r.Kind == "Ring" then
			local def = AccountData.Rings[r.Id]
			local ring = new("Frame", { BackgroundTransparency = 1, AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.5), Size = UDim2.fromOffset(34, 14) }, box)
			UIKit.corner(ring, 999)
			UIKit.stroke(ring, def and def.Color or P.gold_300, 3, unlocked and 0 or 0.5)
		elseif r.Kind == "Color" then
			local c = AccountData.Colors[r.Id]
			local dot = new("Frame", { BackgroundColor3 = c and c.Color or P.ivory_200, AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.5), Size = UDim2.fromOffset(24, 24), BackgroundTransparency = unlocked and 0 or 0.4 }, box)
			UIKit.corner(dot, 999)
			UIKit.stroke(dot, P.slate_950, 1.5, 0.2)
		else
			Icons.Draw(box, KIND_ICON[r.Kind] or "gift", { Size = 26, AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.5), Color = (not unlocked) and P.stone_400 or nil, Dim = not unlocked, Back = C.PanelInset })
		end
	end

	local function rewardRow(level: number, r: AccountData.Reward, have: number, order: number)
		local p = ctx.Profile() or {}
		local unlocked = have >= level
		local worn = p[WORN_KEY[r.Kind]] == r.Id
		local f = UIKit.Panel(list, { Name = "Lv" .. level .. r.Kind, LayoutOrder = order, Size = UDim2.new(1, 0, 0, 64) }, true)
		if worn then
			UIKit.stroke(f, P.gold_400, 1.5, 0.1)
		elseif not unlocked then
			f.BackgroundTransparency = 0.45
		end
		local badge = UIKit.Badge(f, "LV " .. level, unlocked and "Gold" or "Dark", { AnchorPoint = Vector2.new(0, 0.5), Position = UDim2.new(0, 12, 0.5, 0), Size = UDim2.fromOffset(0, 26) })
		badge.TextSize = TS(13)
		preview(f, r, unlocked)
		local nameColor = (r.Kind == "Color" and unlocked) and (Cosmetics.NameColor(r.Id) or C.Text) or (unlocked and C.Text or C.TextMuted)
		text(f, "H3", r.Kind == "Title" and r.Id or AccountData.RewardName(r), { Name = "RewardName", Position = UDim2.fromOffset(136, 8), Size = UDim2.new(1, -136 - 150, 0, TS(18) + 4), TextColor3 = nameColor, TextTruncate = Enum.TextTruncate.AtEnd })
		text(f, "Caption", UIKit.track(KIND_LABEL[r.Kind] or r.Kind), { Position = UDim2.fromOffset(136, 12 + TS(18)), Size = UDim2.new(1, -136 - 150, 0, TS(12) + 4) })
		if unlocked then
			UIKit.Button(f, {
				Kind = worn and "Primary" or "Secondary",
				Title = worn and "WORN" or "WEAR",
				Icon = worn and "check" or nil,
				IconSize = 16,
				Align = "Center",
				AnchorPoint = Vector2.new(1, 0.5),
				Position = UDim2.new(1, -10, 0.5, 0),
				Size = UDim2.fromOffset(128, 46),
				Shadow = false,
				Name = "Wear",
				OnClick = function()
					local kind = r.Kind == "Color" and "Color" or r.Kind
					Remotes.Get("EquipCosmetic"):FireServer(kind, worn and "" or r.Id)
				end,
			})
		else
			text(f, "Label", "LOCKED", { AnchorPoint = Vector2.new(1, 0.5), Position = UDim2.new(1, -16, 0.5, 0), Size = UDim2.fromOffset(120, 30), TextXAlignment = Enum.TextXAlignment.Right, TextColor3 = C.TextFaint })
		end
		return f
	end

	local function fill(animate: boolean)
		local p = ctx.Profile()
		local level, into, need = MenuTrack.Account(p)
		ui.Level.Text = level >= AccountData.MaxLevel and ("Level " .. level .. " · MAX") or ("Level " .. level)
		if need > 0 then
			ui.Meter.Set(into / need, string.format("%s / %s XP to level %d", UIKit.formatNumber(into), UIKit.formatNumber(need), level + 1))
		else
			ui.Meter.Set(1, "Max level reached")
		end
		if animate then
			if level < AccountData.MaxLevel then
				UIAnim.CountTo(ui.Level, 0, level, "Level %d", 0.7)
			end
			ui.Meter.Frame.ClipsDescendants = true
			UIAnim.Sweep(ui.Meter.Frame, 0.35, 0.5, 0.7)
		end
		for _, ch in ipairs(ui.Medal:GetChildren()) do
			if ch:IsA("Frame") then
				ch:Destroy()
			end
		end
		Icons.Character(ui.Medal, p and p.SelectedCharacter or CharacterData.Default, { Size = 48, AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.5), Back = P.slate_950 })
		local framed = Cosmetics.Frame(ui.Medal, p and p.Frame or "")
		ui.MedalStroke.Transparency = framed and 1 or 0.05
		for _, ch in ipairs(list:GetChildren()) do
			if ch:IsA("GuiObject") then
				ch:Destroy()
			end
		end
		local order = 0
		for _, lv in ipairs(AccountData.RewardLevels) do
			for _, r in ipairs(AccountData.Rewards[lv]) do
				order += 1
				local f = rewardRow(lv, r, level, order)
				if animate and order <= 10 then
					UIAnim.Pop(f, 0.02 * order, 0.9)
				end
			end
		end
	end

	local function layout(v: Vector2, portrait: boolean, ins: { [string]: number })
		local W, H = v.X, v.Y
		local M = UIKit.IsCompact() and Theme.Layout.MarginCompact or Theme.Layout.Margin
		local headY = math.max(ins.Top + 4, 12)
		place(ui.Header.Frame, M, headY, math.min(580, W - 2 * M), 56)
		local top = math.max(headY + 66 + (portrait and 58 or 0), portrait and 0 or 76)
		local w = math.min(W - 2 * M, 860)
		place(ui.Panel, (W - w) / 2, top, w, H - top - M)
		local lines = w < 640 and 4 or 2
		ui.How.Size = UDim2.new(1, -110, 0, TS(14) * lines + 6)
		local headH = math.max(100, TS(30) + 44 + TS(14) * lines + 10)
		ui.Head.Size = UDim2.new(1, 0, 0, headH)
		ui.List.Position = UDim2.fromOffset(0, headH + 8)
		ui.List.Size = UDim2.new(1, 0, 1, -(headH + 8))
	end
	MenuTrack._layout = function()
		layout(host.VirtualSize(), host.IsPortrait(), host.Insets())
	end

	return {
		Layout = layout,
		Refresh = function(_p)
			if screen.Visible then
				fill(false)
			end
		end,
		OnShow = function(_p)
			fill(true)
			MenuTrack._layout()
		end,
	}
end

MenuTrack._layout = function() end

return MenuTrack
