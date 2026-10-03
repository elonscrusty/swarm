--[[
	MenuArenas.lua
	The ARENAS screen (the lobby's ARENA card opens it). Title with a BEST STAGE badge, the
	line "Choose where your run starts. Later stages visit every biome.", one panel with a
	card per arena in Config.Arenas.Order (3 x 2 on wide screens, 2 columns with the
	picture on top in portrait, scrolling when needed), and a gold CONFIRM <ARENA> button.
	Each card: the arena picture (art/arenas/<Arena>, cropped; a painted biome preview as
	stand-in) with a lock badge (locked, muted) or a gold check (selected), the name, a
	status pill (SELECTED / UNLOCKED / LOCKED), the biome icon and its hazard with the real
	numbers (Config.Arenas.Hazards), then the unlock rule ("Open from the start" /
	"Unlocked at stage 2" / "Reach stage 4 • Best 2") and, while locked, a gold progress
	bar with "2/4" (Stats.BestStage).
	Tapping an unlocked arena picks it for stage 1 at once: CycleArena(name), which the
	server validates (lobby phase, known arena, unlocked for this player); the SwarmState
	attribute SelectedArena is what the screen shows. A locked card says what to do.
	CONFIRM goes back to the home screen with that arena picked.
]]

local Shared = game:GetService("ReplicatedStorage"):WaitForChild("Shared")
local Config = require(Shared:WaitForChild("Config"))
local Theme = require(Shared:WaitForChild("Theme"))
local Remotes = require(Shared:WaitForChild("Remotes"))
local UIKit = require(script.Parent.UIKit)
local UIAnim = require(script.Parent.UIAnim)
local Icons = require(script.Parent.Icons)

local MenuArenas = {}

local new, text, TS = UIKit.new, UIKit.text, UIKit.TS
local C, P = Theme.Color, Theme.Palette

local H = Config.Arenas.Hazards
local function pct(x: number): string
	return tostring(math.floor(x * 100 + 0.5)) .. "%"
end

local GAP = 12 -- between cards
local PIC_R = Theme.Radius.S + 2 -- picture corners

-- How each biome is painted when its picture is missing, its icon and its hazard line.
local LOOK: { [string]: { [string]: any } } = {
	Forest = { Sky = P.moss_200, Sky2 = P.moss_400, Far = P.moss_600, Ground = P.moss_700, Icon = "arena_Forest", Hazard = "No hazards" },
	Ruins = { Sky = P.amber_300, Sky2 = P.stone_300, Far = P.stone_500, Ground = P.stone_600, Icon = "arena_Ruins", Hazard = "No hazards  ·  Tight lanes" },
	Swamp = { Sky = P.murk_300, Sky2 = P.murk_500, Far = P.murk_700, Ground = P.bog_700, Pool = P.bog_500, Icon = "arena_Swamp", Hazard = "Mud slows you to " .. pct(H.Mud.PlayerSpeed) .. " speed" },
	Snow = { Sky = P.ice_100, Sky2 = P.snow_300, Far = P.snow_400, Ground = P.snow_200, Pool = P.ice_300, Icon = "arena_Snow", Hazard = "Ice: " .. pct(H.Ice.PlayerSpeed) .. " speed, slippery" },
	Desert = { Sky = P.amber_300, Sky2 = P.sand_300, Far = P.sand_600, Ground = P.sand_400, Pool = P.sand_700, Icon = "arena_Desert", Hazard = "Quicksand slows you to " .. pct(H.Quicksand.PlayerSpeed) .. " speed" },
	Lava = { Sky = P.basalt_600, Sky2 = P.basalt_800, Far = P.basalt_700, Ground = P.basalt_900, Pool = P.lava_500, Glow = true, Icon = "arena_Lava", Hazard = string.format("Lava: %d damage every %ss", H.Lava.Damage, tostring(H.Lava.Tick)) },
}

local function place(obj: GuiObject, x: number, y: number, w: number, h: number)
	obj.Position = UDim2.fromOffset(math.floor(x + 0.5), math.floor(y + 0.5))
	obj.Size = UDim2.fromOffset(math.floor(w + 0.5), math.floor(h + 0.5))
end

-- The painted stand-in: sky gradient, a far hill line, the ground, a hazard pool, the icon.
local function painting(f: Frame, look: { [string]: any })
	f.BackgroundColor3 = Color3.new(1, 1, 1)
	f.BackgroundTransparency = 0
	UIKit.corner(f, PIC_R)
	new("UIGradient", { Rotation = 90, Color = ColorSequence.new(look.Sky, look.Sky2) }, f)
	for i, hill in ipairs({ { 0.28, 0.52, 0.62 }, { 0.78, 0.46, 0.7 } }) do
		local h = new("Frame", {
			Name = "Hill" .. i,
			AnchorPoint = Vector2.new(0.5, 0),
			Position = UDim2.fromScale(hill[1], hill[2]),
			Size = UDim2.fromScale(hill[3], 0.48),
			BackgroundColor3 = look.Far,
			BorderSizePixel = 0,
		}, f)
		UIKit.corner(h, 999)
	end
	-- (a UIGradient multiplies the background colour: white base, the colours in the gradient)
	local ground = new("Frame", { Name = "Ground", Position = UDim2.fromScale(0, 0.66), Size = UDim2.fromScale(1, 0.34), BackgroundColor3 = Color3.new(1, 1, 1), BorderSizePixel = 0 }, f)
	UIKit.corner(ground, PIC_R)
	new("UIGradient", { Rotation = 90, Color = ColorSequence.new(look.Ground:Lerp(Color3.new(1, 1, 1), 0.08), look.Ground:Lerp(Color3.new(0, 0, 0), 0.25)) }, ground)
	if look.Pool then
		local pool = new("Frame", {
			Name = "Pool",
			AnchorPoint = Vector2.new(0.5, 0.5),
			Position = UDim2.fromScale(0.7, 0.83),
			Size = UDim2.fromScale(0.44, 0.13),
			BackgroundColor3 = look.Pool,
			BorderSizePixel = 0,
		}, f)
		UIKit.corner(pool, 999)
		UIKit.stroke(pool, look.Glow and P.amber_300 or look.Pool:Lerp(Color3.new(1, 1, 1), 0.3), look.Glow and 2 or 1, look.Glow and 0.1 or 0.4)
	end
	local well = new("Frame", {
		Name = "IconWell",
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.42),
		Size = UDim2.fromOffset(44, 44),
		BackgroundColor3 = P.slate_900,
		BackgroundTransparency = 0.35,
	}, f)
	UIKit.corner(well, 999)
	UIKit.stroke(well, P.ivory_100, 1, 0.6)
	Icons.Draw(well, look.Icon, { Size = 30, AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.5), Back = P.slate_900 })
end

-- Round badge on the picture's corner: a lock (locked) or a gold check (selected).
local function cornerBadge(parent: Instance, icon: string, back: Color3, fg: Color3, edge: Color3): Frame
	local b = new("Frame", { Name = icon == "lock" and "LockBadge" or "CheckBadge", Position = UDim2.fromOffset(7, 7), Size = UDim2.fromOffset(30, 30), BackgroundColor3 = back, BackgroundTransparency = 0.05, Visible = false, ZIndex = 6 }, parent)
	UIKit.corner(b, 999)
	UIKit.stroke(b, edge, 1.5, 0.1)
	local glyph = Icons.Draw(b, icon, { Size = 18, Color = fg, AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.5), Back = back })
	glyph.ZIndex = 7
	return b
end

local function unlocked(best: number, name: string): boolean
	local def = (Config.Arenas :: any)[name]
	return def ~= nil and best >= (def.RequiredBestStage or 0)
end

function MenuArenas.Build(screen: Frame, ctx: { [string]: any })
	local host = ctx.Host
	local ui: { [string]: any } = { Cards = {} }
	local optimistic: string? = nil
	local optimisticUntil = 0
	ui.Header = UIKit.ScreenHeader(screen, "ARENAS", ctx.Back)
	ui.Best = UIKit.IconPill(ui.Header.Frame, "crown", "BEST STAGE 0", { Name = "BestStage", AnchorPoint = Vector2.new(0, 0.5) })
	ui.Intro = text(screen, "Body", "Choose where your run starts. Later stages visit every arena.", {
		Name = "Intro",
		TextWrapped = true,
		TextColor3 = P.ivory_200,
	})
	local holder, face = UIKit.Surface(screen, { Name = "Panel", Radius = Theme.Radius.L, Transparency = 0.06 })
	ui.Panel = holder
	local scroll = new("ScrollingFrame", {
		Name = "Cards",
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		Size = UDim2.fromScale(1, 1),
		ScrollBarThickness = 4,
		ScrollBarImageColor3 = P.gold_500,
		AutomaticCanvasSize = Enum.AutomaticSize.Y,
		CanvasSize = UDim2.new(),
		ScrollingDirection = Enum.ScrollingDirection.Y,
	}, face)
	UIKit.padding(scroll, 16, 16, 16, 16)
	ui.Scroll = scroll
	ui.Grid = new("UIGridLayout", { CellSize = UDim2.fromOffset(320, 180), CellPadding = UDim2.fromOffset(GAP, GAP), SortOrder = Enum.SortOrder.LayoutOrder, HorizontalAlignment = Enum.HorizontalAlignment.Center }, scroll)

	local function selected(): string
		if optimistic and os.clock() < optimisticUntil then
			return optimistic
		end
		local s = Remotes.State():GetAttribute("SelectedArena")
		return type(s) == "string" and s or "Forest"
	end

	local function bestStage(): number
		local p = ctx.Profile()
		return p and p.Stats and tonumber(p.Stats.BestStage) or 0
	end

	ui.Confirm = UIKit.Button(screen, {
		Kind = "Primary",
		Title = "CONFIRM FOREST",
		TitleStyle = "H3",
		Icon = "arena_Forest",
		IconSize = 26,
		Align = "Center",
		Glow = true,
		Name = "Confirm",
		Size = UDim2.fromOffset(360, Theme.Size.Button),
		OnClick = function()
			ctx.Back()
		end,
	})

	for i, name in ipairs(Config.Arenas.Order) do
		local def = (Config.Arenas :: any)[name]
		local look = LOOK[name] or LOOK.Forest
		local b = UIKit.Button(scroll, {
			Kind = "Secondary",
			Name = name,
			LayoutOrder = i,
			Size = UDim2.fromOffset(320, 180),
			Shadow = false,
			OnClick = function()
				local best = bestStage()
				if not unlocked(best, name) then
					ctx.Toast(string.format("Reach stage %d in a run to unlock %s", def.RequiredBestStage or 0, def.DisplayName), P.gold_300)
					return
				end
				if selected() ~= name then
					optimistic = name
					optimisticUntil = os.clock() + 2
					Remotes.Get("CycleArena"):FireServer(name)
					MenuArenas._refresh()
				end
			end,
		})
		b.Instance.Text = def.DisplayName
		for _, ch in ipairs(b.Content:GetChildren()) do
			ch:Destroy()
		end
		-- the picture with its veil and corner badges
		local pic = new("Frame", { Name = "Picture", BackgroundTransparency = 1 }, b.Content)
		local art = UIKit.ArtPicture(pic, "arenas/" .. name, { Name = "Art", CornerRadius = PIC_R }, function(fb: Frame)
			painting(fb, look)
		end)
		local veil = new("Frame", { Name = "Veil", Size = UDim2.fromScale(1, 1), BackgroundColor3 = P.slate_950, BackgroundTransparency = 0.5, BorderSizePixel = 0, Visible = false, ZIndex = 5 }, pic)
		UIKit.corner(veil, PIC_R)
		local picEdge = UIKit.stroke(art, P.slate_950, 1, 0.4)
		local lockBadge = cornerBadge(pic, "lock", P.slate_950, P.ivory_200, P.stone_500)
		local checkBadge = cornerBadge(pic, "check", P.gold_400, P.gold_900, P.gold_200)
		-- the text side
		local info = new("Frame", { Name = "Info", BackgroundTransparency = 1 }, b.Content)
		local title = text(info, "H2", string.upper(def.DisplayName), { Name = "ArenaName", Size = UDim2.new(1, -110, 0, TS(22) + 4), TextTruncate = Enum.TextTruncate.AtEnd })
		local state = UIKit.StatusPill(info, "LOCKED", { AnchorPoint = Vector2.new(1, 0), Position = UDim2.fromScale(1, 0) })
		local hazardIcon = Icons.Draw(info, look.Icon, { Size = 22, Position = UDim2.fromOffset(0, TS(22) + 12) })
		local hazard = text(info, "Small", look.Hazard, {
			Name = "Hazard",
			Position = UDim2.fromOffset(28, TS(22) + 10),
			Size = UDim2.new(1, -28, 0, TS(14) * 2 + 6),
			TextWrapped = true,
			TextYAlignment = Enum.TextYAlignment.Top,
			TextColor3 = P.ivory_200,
		})
		local rule = new("Frame", { Name = "Divider", BackgroundColor3 = C.PanelEdge, BackgroundTransparency = 0.55, BorderSizePixel = 0, Size = UDim2.new(1, 0, 0, 1) }, info)
		local ruleText = text(info, "Small", "", { Name = "Rule", Size = UDim2.new(1, 0, 0, TS(14) + 4), TextColor3 = P.gold_200, TextTruncate = Enum.TextTruncate.AtEnd })
		local meter = UIKit.Meter(info, { Name = "Progress", Size = UDim2.new(1, -52, 0, 8), Color = P.gold_400 } :: any)
		local count = text(info, "Label", "", { Name = "Count", AnchorPoint = Vector2.new(1, 0.5), Size = UDim2.fromOffset(48, TS(14) + 4), TextXAlignment = Enum.TextXAlignment.Right, TextColor3 = P.gold_200 })
		ui.Cards[name] = {
			Button = b,
			Pic = pic,
			Art = art,
			PicEdge = picEdge,
			Veil = veil,
			Lock = lockBadge,
			Check = checkBadge,
			Info = info,
			Title = title,
			HazardIcon = hazardIcon,
			Hazard = hazard,
			Divider = rule,
			Rule = ruleText,
			Meter = meter,
			Count = count,
			State = state,
		}
	end

	MenuArenas._refresh = function()
		local best = bestStage()
		local sel = selected()
		ui.Best.SetText("BEST STAGE " .. tostring(best))
		local selDef = (Config.Arenas :: any)[sel]
		ui.Confirm.SetText("CONFIRM " .. string.upper(selDef and selDef.DisplayName or sel))
		if ui.ConfirmIcon ~= sel then
			ui.ConfirmIcon = sel
			ui.Confirm.SetIcon((LOOK[sel] or LOOK.Forest).Icon)
		end
		for _, name in ipairs(Config.Arenas.Order) do
			local def = (Config.Arenas :: any)[name]
			local card = ui.Cards[name]
			local need = def.RequiredBestStage or 0
			local open = unlocked(best, name)
			local isSel = name == sel
			local wasSel = card.Selected
			card.Selected = isSel
			card.Button.SetSelected(isSel)
			card.Veil.Visible = not open
			card.Lock.Visible = not open
			card.Check.Visible = isSel
			card.PicEdge.Color = isSel and P.gold_400 or P.slate_950
			card.PicEdge.Transparency = isSel and 0.2 or 0.4
			card.Title.TextColor3 = isSel and P.gold_200 or (open and C.Text or P.ivory_300)
			card.Hazard.TextColor3 = open and P.ivory_200 or P.ivory_300
			UIKit.SetStatus(card.State, isSel and "SELECTED" or (open and "UNLOCKED" or "LOCKED"))
			if not open and not isSel then
				-- locked: a dark outline pill (not red: nothing is wrong, it's just ahead)
				card.State.TextColor3 = P.ivory_300
				local edge = card.State:FindFirstChild("StatusEdge") :: UIStroke?
				if edge then
					edge.Color = P.stone_400
				end
			end
			if need <= 0 then
				card.Rule.Text = "Open from the start"
			elseif open then
				card.Rule.Text = string.format("Unlocked at stage %d", need)
			else
				card.Rule.Text = string.format("Reach stage %d  ·  Best %d", need, best)
				card.Meter.Set(math.clamp(best / need, 0, 1), "")
				card.Count.Text = string.format("%d/%d", math.min(best, need), need)
			end
			card.Rule.TextColor3 = open and P.moss_200 or P.gold_200
			card.Meter.Frame.Visible = not open
			card.Count.Visible = not open
			if wasSel == false and isSel and screen.Visible then
				UIAnim.Punch(card.Button.Instance, 0.06)
				UIAnim.Sweep(card.Button.Instance, 0, 0.6, 0.5)
				UIAnim.Burst(card.Button.Instance, UDim2.fromScale(0.5, 0.5), { P.gold_300, P.ivory_100 }, 10, 70)
			end
		end
	end

	-- inside a card: the picture on the left (wide cards) or on top (narrow ones), the text
	local function cardLayout(card: { [string]: any }, cellW: number, cellH: number, stacked: boolean)
		local pad = 10
		local iw, ih = cellW - 2 * pad, cellH - 2 * pad
		local ix, iy, infoW, infoH
		if stacked then
			local picH = math.floor(ih * 0.42)
			place(card.Pic, pad, pad, iw, picH)
			ix, iy, infoW, infoH = pad, pad + picH + 8, iw, ih - picH - 8
		else
			local picW = math.floor(iw * 0.4)
			place(card.Pic, pad, pad, picW, ih)
			ix, iy, infoW, infoH = pad + picW + 12, pad + 2, iw - picW - 12, ih - 2
		end
		place(card.Info, ix, iy, infoW, infoH)
		-- top: name + pill, hazard; bottom up: bar, rule, divider
		local titleH = TS(22) + 4
		card.Title.Size = UDim2.new(1, -(card.State.AbsoluteSize.X / math.max(0.01, host.Scale()) + 8), 0, titleH)
		local lineH = TS(14) + 4
		local barY = infoH - 8
		card.Meter.Frame.Position = UDim2.fromOffset(0, barY)
		card.Count.Position = UDim2.new(1, 0, 0, barY + 4)
		local ruleY = barY - 6 - lineH
		card.Rule.Position = UDim2.fromOffset(0, ruleY)
		card.Divider.Position = UDim2.fromOffset(0, ruleY - 6)
		local hazY = titleH + 8
		card.HazardIcon.Position = UDim2.fromOffset(0, hazY + 1)
		card.Hazard.Position = UDim2.fromOffset(28, hazY)
		-- two hazard lines when they fit above the divider, else one (truncated)
		local room = ruleY - 8 - hazY
		local twoLines = room >= TS(14) * 2 + 4
		card.Hazard.Size = UDim2.new(1, -28, 0, twoLines and (TS(14) * 2 + 6) or lineH)
		card.Hazard.TextWrapped = twoLines
		card.Hazard.TextTruncate = twoLines and Enum.TextTruncate.None or Enum.TextTruncate.AtEnd
	end

	local function layout(v: Vector2, portrait: boolean, ins: { [string]: number })
		local W, Hh = v.X, v.Y
		local compact = UIKit.IsCompact()
		local M = compact and Theme.Layout.MarginCompact or Theme.Layout.Margin
		local headY = math.max(ins.Top + 4, 12)
		place(ui.Header.Frame, M, headY, math.min(620, W - 2 * M), 56)
		-- the BEST STAGE badge right after the title
		local tb = ui.Header.Title.TextBounds.X
		if tb < 10 then
			tb = TS(Theme.TextSize.H1) * 0.75 * #ui.Header.Title.Text
		end
		ui.Best.Frame.Position = UDim2.new(0, 148 + tb + 16, 0.5, 0)
		local top = headY + 62 + (portrait and 58 or 0)
		local w = math.min(W - 2 * M, 1180)
		local x0 = (W - w) / 2
		local introH = TS(16) * (w < 560 and 2 or 1) + 8
		place(ui.Intro, x0 + 4, top, w - 8, introH)
		local confirmH = Theme.Size.Button
		local confirmW = math.min(380, w)
		local confirmY = Hh - M - confirmH
		local panelTop = top + introH + 8
		local panelMax = confirmY - 14 - panelTop
		-- columns: three on wide screens; narrow cards put the picture on top
		local inner = w - 32 - 6
		local cols = math.clamp(math.floor((inner + GAP) / 330), 1, 3)
		if portrait then
			cols = math.min(cols, 2)
		end
		local cellW = math.floor((inner - (cols - 1) * GAP) / cols)
		local stacked = cellW < 360
		local rows = math.ceil(#Config.Arenas.Order / cols)
		local minH = stacked and math.max(250, TS(22) + TS(14) * 3 + 150) or math.max(130, TS(22) + TS(14) * 2 + 70)
		local fitH = math.floor((panelMax - 32 - (rows - 1) * GAP) / rows)
		local cellH = math.clamp(fitH, minH, stacked and 320 or 200)
		ui.Grid.CellSize = UDim2.fromOffset(cellW, cellH)
		local gridH = rows * cellH + (rows - 1) * GAP + 32
		local panelH = math.min(gridH, panelMax)
		place(ui.Panel, x0, panelTop, w, panelH)
		-- the button right under the panel (at the bottom when the panel fills the screen)
		place(ui.Confirm.Instance, (W - confirmW) / 2, math.min(confirmY, panelTop + panelH + 16), confirmW, confirmH)
		for _, card in pairs(ui.Cards) do
			cardLayout(card, cellW, cellH, stacked)
		end
	end
	MenuArenas._layout = function()
		layout(host.VirtualSize(), host.IsPortrait(), host.Insets())
	end

	Remotes.State():GetAttributeChangedSignal("SelectedArena"):Connect(function()
		optimistic = nil
		MenuArenas._refresh()
	end)
	MenuArenas._refresh()

	return {
		Layout = layout,
		Refresh = function(_p)
			MenuArenas._refresh()
		end,
		OnShow = function(_p)
			MenuArenas._refresh()
			for i, name in ipairs(Config.Arenas.Order) do
				UIAnim.Pop(ui.Cards[name].Button.Instance, 0.03 * i, 0.8)
			end
			UIAnim.Pop(ui.Confirm.Instance, 0.25, 0.85)
			MenuArenas._layout()
		end,
	}
end

MenuArenas._refresh = function() end
MenuArenas._layout = function() end

return MenuArenas
