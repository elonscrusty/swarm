--[[
	MenuArenas.lua
	The ARENAS screen (the lobby's ARENA card opens it): every arena in Config.Arenas.Order
	as a card with a little painted preview of the biome (sky, hills, ground, its hazard
	pool, the biome icon), the name, the hazard line and LOCKED / UNLOCKED with the exact
	rule ("Reach stage 4") and the player's progress toward it (Stats.BestStage).
	Tapping an unlocked arena picks it for stage 1: CycleArena(name), which the server
	validates (lobby phase, known arena, unlocked for this player); the SwarmState
	attribute SelectedArena is what the screen shows. A locked card says what to do.
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

-- How each biome is painted on its card, and its hazard line.
local LOOK: { [string]: { [string]: any } } = {
	Forest = { Sky = P.moss_200, Sky2 = P.moss_400, Far = P.moss_600, Ground = P.moss_700, Icon = "tree", Hazard = "No hazards: a calm, mossy clearing" },
	Ruins = { Sky = P.amber_300, Sky2 = P.stone_300, Far = P.stone_500, Ground = P.stone_600, Icon = "castle", Hazard = "No hazards: sunlit old stones, tight lanes" },
	Swamp = { Sky = P.murk_300, Sky2 = P.murk_500, Far = P.murk_700, Ground = P.bog_700, Pool = P.bog_500, Icon = "sprout", Hazard = "Mud pools slow you to " .. pct(H.Mud.PlayerSpeed) },
	Snow = { Sky = P.ice_100, Sky2 = P.snow_300, Far = P.snow_400, Ground = P.snow_200, Pool = P.ice_300, Icon = "FrostNova", Hazard = "Ice ponds: " .. pct(H.Ice.PlayerSpeed) .. " speed, but slippery" },
	Desert = { Sky = P.amber_300, Sky2 = P.sand_300, Far = P.sand_600, Ground = P.sand_400, Pool = P.sand_700, Icon = "hourglass", Hazard = "Quicksand slows you to " .. pct(H.Quicksand.PlayerSpeed) },
	Lava = { Sky = P.basalt_600, Sky2 = P.basalt_800, Far = P.basalt_700, Ground = P.basalt_900, Pool = P.lava_500, Glow = true, Icon = "FireTrail", Hazard = string.format("Lava pools burn: %d damage every %.1f s", H.Lava.Damage, H.Lava.Tick) },
}

local function place(obj: GuiObject, x: number, y: number, w: number, h: number)
	obj.Position = UDim2.fromOffset(math.floor(x + 0.5), math.floor(y + 0.5))
	obj.Size = UDim2.fromOffset(math.floor(w + 0.5), math.floor(h + 0.5))
end

-- The painted preview: sky gradient, a far hill line, the ground, a hazard pool, the icon.
local function painting(parent: Instance, look: { [string]: any }): Frame
	local f = new("Frame", { Name = "Preview", BackgroundColor3 = Color3.new(1, 1, 1), BorderSizePixel = 0, ClipsDescendants = true }, parent)
	UIKit.corner(f, Theme.Radius.S + 2)
	new("UIGradient", { Rotation = 90, Color = ColorSequence.new(look.Sky, look.Sky2) }, f)
	for i, hill in ipairs({ { 0.28, 0.52, 0.62 }, { 0.78, 0.46, 0.7 } }) do
		local h = new("Frame", {
			Name = "Hill" .. i,
			AnchorPoint = Vector2.new(0.5, 0),
			Position = UDim2.fromScale(hill[1], hill[2]),
			Size = UDim2.fromScale(hill[3], 0.6),
			BackgroundColor3 = look.Far,
			BorderSizePixel = 0,
		}, f)
		UIKit.corner(h, 999)
	end
	-- (a UIGradient multiplies the background colour: white base, the colours in the gradient)
	local ground = new("Frame", { Name = "Ground", Position = UDim2.fromScale(0, 0.66), Size = UDim2.fromScale(1, 0.34), BackgroundColor3 = Color3.new(1, 1, 1), BorderSizePixel = 0 }, f)
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
	Icons.Draw(well, look.Icon, { Size = 28, AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.5), Back = P.slate_900 })
	-- locked veil
	local veil = new("Frame", { Name = "Veil", Size = UDim2.fromScale(1, 1), BackgroundColor3 = P.slate_950, BackgroundTransparency = 0.45, BorderSizePixel = 0, Visible = false, ZIndex = 5 }, f)
	local lockWell = new("Frame", { Name = "Lock", Position = UDim2.fromOffset(6, 6), Size = UDim2.fromOffset(28, 28), BackgroundColor3 = P.slate_950, BackgroundTransparency = 0.2 }, veil)
	UIKit.corner(lockWell, 999)
	Icons.Draw(lockWell, "lock", { Size = 18, Color = P.ivory_200, AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.5), Back = P.slate_950 })
	return f
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
	local holder, face = UIKit.Surface(screen, { Name = "Panel", Radius = Theme.Radius.L, Transparency = 0.06 })
	ui.Panel = holder
	UIKit.padding(face, 16, 16, 16, 16)
	ui.Intro = text(face, "Body", "Pick where your run starts. Reach deeper stages to unlock more arenas; later stages tour every biome anyway.", {
		Name = "Intro",
		TextWrapped = true,
		TextYAlignment = Enum.TextYAlignment.Top,
	})
	local scroll = new("ScrollingFrame", {
		Name = "Cards",
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		ScrollBarThickness = 4,
		ScrollBarImageColor3 = P.gold_500,
		AutomaticCanvasSize = Enum.AutomaticSize.Y,
		CanvasSize = UDim2.new(),
		ScrollingDirection = Enum.ScrollingDirection.Y,
	}, face)
	UIKit.padding(scroll, 4, 6, 4, 4)
	ui.Scroll = scroll
	ui.Grid = new("UIGridLayout", { CellSize = UDim2.fromOffset(320, 150), CellPadding = UDim2.fromOffset(12, 12), SortOrder = Enum.SortOrder.LayoutOrder, HorizontalAlignment = Enum.HorizontalAlignment.Center }, scroll)

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

	for i, name in ipairs(Config.Arenas.Order) do
		local def = (Config.Arenas :: any)[name]
		local look = LOOK[name] or LOOK.Forest
		local b = UIKit.Button(scroll, {
			Kind = "Secondary",
			Name = name,
			LayoutOrder = i,
			Size = UDim2.fromOffset(320, 150),
			OnClick = function()
				local best = bestStage()
				if not unlocked(best, name) then
					ctx.Toast(string.format("%s: reach stage %d in a run to unlock it.", def.DisplayName, def.RequiredBestStage or 0), P.gold_300)
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
			if not ch:IsA("UIPadding") then
				ch:Destroy()
			end
		end
		local pic = painting(b.Content, look)
		local info = new("Frame", { Name = "Info", BackgroundTransparency = 1 }, b.Content)
		local title = text(info, "H3", string.upper(def.DisplayName), { Name = "ArenaName", Size = UDim2.new(1, 0, 0, TS(18) + 4), TextTruncate = Enum.TextTruncate.AtEnd })
		local hazard = text(info, "Small", look.Hazard, { Name = "Hazard", Position = UDim2.fromOffset(0, TS(18) + 6), Size = UDim2.new(1, 0, 0, TS(14) * 2 + 4), TextWrapped = true, TextYAlignment = Enum.TextYAlignment.Top, TextColor3 = C.TextMuted })
		local rule = text(info, "Small", "", { Name = "Rule", AnchorPoint = Vector2.new(0, 1), Position = UDim2.new(0, 0, 1, -16), Size = UDim2.new(1, 0, 0, TS(14) + 4), TextColor3 = P.gold_200, TextTruncate = Enum.TextTruncate.AtEnd })
		local meter = UIKit.Meter(info, { Name = "Progress", AnchorPoint = Vector2.new(0, 1), Position = UDim2.fromScale(0, 1), Size = UDim2.new(1, 0, 0, 8), Color = P.gold_400 } :: any)
		local state = UIKit.Badge(b.Content, "", "Dark", { Name = "State", AnchorPoint = Vector2.new(1, 0), Position = UDim2.fromScale(1, 0), ZIndex = 6 })
		ui.Cards[name] = { Button = b, Pic = pic, Info = info, Title = title, Hazard = hazard, Rule = rule, Meter = meter, State = state }
	end

	MenuArenas._refresh = function()
		local best = bestStage()
		local sel = selected()
		for _, name in ipairs(Config.Arenas.Order) do
			local def = (Config.Arenas :: any)[name]
			local card = ui.Cards[name]
			local need = def.RequiredBestStage or 0
			local open = unlocked(best, name)
			local isSel = name == sel
			local wasSel = card.Selected
			card.Selected = isSel
			card.Button.SetSelected(isSel)
			card.Pic.Veil.Visible = not open
			card.Title.TextColor3 = isSel and P.gold_200 or (open and C.Text or C.TextMuted)
			if isSel then
				card.State.Text = "SELECTED"
				card.State.BackgroundColor3 = P.gold_400
				card.State.TextColor3 = P.gold_900
			elseif open then
				card.State.Text = "UNLOCKED"
				card.State.BackgroundColor3 = P.moss_600
				card.State.TextColor3 = P.ivory_100
			else
				card.State.Text = "LOCKED"
				card.State.BackgroundColor3 = C.PanelInset
				card.State.TextColor3 = C.TextMuted
			end
			if need <= 0 then
				card.Rule.Text = "Open from the start"
				card.Meter.Frame.Visible = false
			elseif open then
				card.Rule.Text = string.format("Unlocked at stage %d", need)
				card.Meter.Frame.Visible = false
			else
				card.Rule.Text = string.format("Reach stage %d  ·  best %d", need, best)
				card.Meter.Frame.Visible = true
				card.Meter.Set(math.clamp(best / need, 0, 1), "")
			end
			if wasSel == false and isSel then
				UIAnim.Punch(card.Button.Instance, 0.06)
				UIAnim.Sweep(card.Button.Instance, 0, 0.6, 0.5)
				UIAnim.Burst(card.Button.Instance, UDim2.fromScale(0.5, 0.5), { P.gold_300, P.ivory_100 }, 10, 70)
			end
		end
	end

	local function layout(v: Vector2, portrait: boolean, ins: { [string]: number })
		local W, Hh = v.X, v.Y
		local compact = UIKit.IsCompact()
		local M = compact and Theme.Layout.MarginCompact or Theme.Layout.Margin
		local headY = math.max(ins.Top + 4, 12)
		place(ui.Header.Frame, M, headY, math.min(520, W - 2 * M), 56)
		local top = math.max(headY + 66 + (portrait and 58 or 0), portrait and 0 or 76)
		local w = math.min(W - 2 * M, 1080)
		local inner = w - 32 - 10
		local cols = math.clamp(math.floor((inner + 12) / 320), 1, 3)
		local cellW = math.floor((inner - (cols - 1) * 12) / cols)
		local cellH = 150
		ui.Grid.CellSize = UDim2.fromOffset(cellW, cellH)
		local rows = math.ceil(#Config.Arenas.Order / cols)
		local introH = TS(16) * (w < 640 and 3 or 2) + 10
		ui.Intro.Size = UDim2.new(1, 0, 0, introH)
		local gridTop = introH + 6
		local gridH = rows * (cellH + 12) + 8
		local h = math.min(32 + gridTop + gridH, Hh - top - M)
		place(ui.Panel, (W - w) / 2, top, w, h)
		ui.Scroll.Position = UDim2.fromOffset(0, gridTop)
		ui.Scroll.Size = UDim2.new(1, 0, 1, -gridTop)
		-- inside each card: the painting on the left, the text on the right
		local picW = math.floor(math.clamp(cellW * 0.36, 96, 150))
		local contentH = cellH - 24
		for _, card in pairs(ui.Cards) do
			place(card.Pic, 0, 0, picW, contentH)
			place(card.Info, picW + 12, 22, cellW - 24 - picW - 12 - 4, contentH - 22)
			-- two hazard lines when they fit above the rule and the bar, else one (truncated)
			local twoLines = contentH - 22 >= TS(18) + 6 + TS(14) * 2 + 4 + TS(14) + 4 + 16
			card.Hazard.Size = UDim2.new(1, 0, 0, twoLines and (TS(14) * 2 + 4) or (TS(14) + 4))
			card.Hazard.TextWrapped = twoLines
			card.Hazard.TextTruncate = twoLines and Enum.TextTruncate.None or Enum.TextTruncate.AtEnd
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
			MenuArenas._layout()
		end,
	}
end

MenuArenas._refresh = function() end
MenuArenas._layout = function() end

return MenuArenas
