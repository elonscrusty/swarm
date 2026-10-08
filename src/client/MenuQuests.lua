--[[
	MenuQuests.lua
	The DAILY QUESTS screen (Config.Features.DailyQuests; docs/next/DAILY_QUESTS.md) and the
	home screen's small "QUESTS 1/3" chip.

	Screen: today's three quests (QuestData.Pick of the UTC day, the same for everyone) with
	their saved progress and a CLAIM button each, then the all-three bonus (an earned look,
	or gold once the looks are owned). Progress comes from finished runs (the server counts
	it; DEV-tainted runs never count). Claims go to the server ("Quests" remote), which
	checks and pays once. Opened from the MORE row and the home chip.

	Chip: a slim button the lobby places so it never covers TOP SCORES or PLAY (LobbyScreen
	relayout); a notice dot ("Quests") while something can be claimed. Hidden while a
	UIState panel owns the screen, and while the switch is off.
]]

local Shared = game:GetService("ReplicatedStorage"):WaitForChild("Shared")
local Theme = require(Shared:WaitForChild("Theme"))
local Config = require(Shared:WaitForChild("Config"))
local Remotes = require(Shared:WaitForChild("Remotes"))
local QuestData = require(Shared:WaitForChild("QuestData"))
local CurseData = require(Shared:WaitForChild("CurseData"))
local CosmeticData = require(Shared:WaitForChild("CosmeticData"))
local MetaData = require(Shared:WaitForChild("MetaData"))
local UIKit = require(script.Parent.UIKit)
local UIAnim = require(script.Parent.UIAnim)
local UIState = require(script.Parent.UIState)
local Icons = require(script.Parent.Icons)
local MetaUI = require(script.Parent.MetaUI)
local NoticeDots = require(script.Parent.NoticeDots)

local MenuQuests = {}

local new, TS = UIKit.new, UIKit.TS
local C = Theme.Color
local function today(): number
	return CurseData.DayOf(MetaUI.Now())
end

local function save(p: { [string]: any }?): any
	return MetaUI.Features(p).DailyQuests
end

local function send(...: any)
	Remotes.Get("Quests"):FireServer(...)
end

-- The MORE row's line.
function MenuQuests.Summary(p: { [string]: any }?): string
	local day = today()
	local done, got, ready = QuestData.Counts(save(p), day)
	local n = #QuestData.Pick(day)
	if ready > 0 then
		return string.format("%d/%d done · %d to claim", done, n, ready)
	elseif QuestData.BonusReady(save(p), day) then
		return "All done · claim the bonus"
	elseif got >= n then
		return "All done · new ones in " .. MetaData.TimeText(CurseData.SecondsLeft(MetaUI.Now()))
	end
	return string.format("%d/%d done today", done, n)
end

-- The bonus line: the look it gives next, or the gold.
local function bonusText(p: { [string]: any }?): string
	local owned = MetaUI.Features(p).Cosmetics
	owned = type(owned) == "table" and type(owned.Owned) == "table" and owned.Owned or {}
	for _, id in ipairs(Config.DailyQuests.BonusCosmetics or {}) do
		if owned[id] ~= true then
			local e = CosmeticData.Get(id)
			return "New look: " .. (e and e.Name or id)
		end
	end
	return string.format("+%d gold", math.floor(tonumber(Config.DailyQuests.BonusGoldAfter) or 0))
end

function MenuQuests.Build(screen: Frame, ctx: { [string]: any })
	local host = ctx.Host
	local ui = MetaUI.Screen(screen, ctx, "DAILY QUESTS", 760)
	local title = MetaUI.Line(ui.Head, "H3", "", 20, { Name = "QuestsDone", TextColor3 = C.BlueDeep })
	local sub = MetaUI.Line(ui.Head, "Small", "", 14, { Name = "QuestsRule" })
	UIKit.list(ui.Body, { Padding = UDim.new(0, 6) })

	local function fill()
		local p = ctx.Profile()
		local day = today()
		local s = save(p)
		local progress, claimed, bonusClaimed = QuestData.View(s, day)
		local picks = QuestData.Pick(day)
		local done = QuestData.Counts(s, day)
		title.Text = string.format("TODAY · %d/%d DONE", done, #picks)
		sub.Text = "New quests in " .. MetaData.TimeText(CurseData.SecondsLeft(MetaUI.Now())) .. " (UTC). Progress comes from your runs."
		MetaUI.Clear(ui.Body)
		local order = 0
		for i, id in ipairs(picks) do
			local q = QuestData.ById[id]
			local value = progress[id] or 0
			local isDone = value >= q.Goal
			local got = claimed[id] == true
			order += 1
			local gold = QuestData.RewardGold(i)
			local row = MetaUI.Row(ui.Body, {
				Name = "Quest" .. i,
				Order = order,
				Icon = q.Icon,
				Title = string.upper(q.Text),
				Sub = (got and "Claimed" or QuestData.ProgressText(q, value)) .. string.format(" · +%d gold", gold),
				Height = 64,
				Action = {
					Title = got and "CLAIMED" or "CLAIM",
					Kind = (isDone and not got) and "Primary" or "Secondary",
					OnClick = function()
						send("Claim", id)
					end,
				},
			})
			if row.Action then
				row.Action.SetEnabled(isDone and not got)
			end
			row.SetDim(false)
			row.SetDone(got)
		end
		order += 1
		local l = UIKit.SectionLabel(ui.Body, "ALL THREE")
		l.LayoutOrder = order
		order += 1
		local ready = QuestData.BonusReady(s, day)
		local bonus = MetaUI.Row(ui.Body, {
			Name = "QuestBonus",
			Order = order,
			Icon = "gift",
			Title = "DAILY BONUS",
			Sub = bonusClaimed and "Claimed today" or bonusText(p),
			Height = 64,
			Action = {
				Title = bonusClaimed and "CLAIMED" or "CLAIM",
				Kind = ready and "Primary" or "Secondary",
				OnClick = function()
					send("ClaimBonus")
				end,
			},
		})
		if bonus.Action then
			bonus.Action.SetEnabled(ready)
		end
		bonus.SetDone(bonusClaimed)
	end

	local function layout(v: Vector2, portrait: boolean, ins: { [string]: number })
		local h1, h2 = TS(20) + 6, TS(14) + 6
		ui.Layout(v, portrait, ins, h1 + h2, 0)
		local w = ui.Head.Size.X.Offset
		MetaUI.place(title, 0, 0, w, h1)
		MetaUI.place(sub, 0, h1, w, h2)
	end

	return {
		Layout = layout,
		Refresh = function(_p)
			if screen.Visible then
				fill()
			end
		end,
		OnShow = function(_p)
			fill()
			layout(host.VirtualSize(), host.IsPortrait(), host.Insets())
			UIAnim.Pop(ui.Panel, 0, 0.96)
		end,
	}
end

------------------------------------------------------------------------------------------
-- Home chip
------------------------------------------------------------------------------------------

export type Chip = {
	Button: TextButton,
	Layout: (x: number, y: number, w: number, h: number) -> (),
	Hide: () -> (),
	Refresh: (p: { [string]: any }?) -> (),
}

-- The chip's width for a height (icon + "QUESTS 3/3"), so the lobby can reserve its room.
function MenuQuests.ChipWidth(h: number): number
	return math.floor(h * 3.6 + 0.5)
end

function MenuQuests.BuildChip(parent: Frame, onOpen: () -> ()): Chip
	local b = new("TextButton", {
		Name = "QuestChip",
		Text = "",
		AutoButtonColor = false,
		BackgroundColor3 = C.Panel,
		BackgroundTransparency = 0,
		BorderSizePixel = 0,
		Visible = false,
	}, parent)
	UIKit.corner(b, 10)
	UIKit.stroke(b, C.PanelEdge, 2, 0)
	UIKit.Focusable(b)
	UIAnim.Button(b)
	b.Activated:Connect(function()
		UIKit.Click()
		onOpen()
	end)
	local iconHolder = new("Frame", { Name = "IconHolder", BackgroundTransparency = 1 }, b)
	Icons.Draw(iconHolder, "flag", { Size = 18, AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.5), Back = C.Panel })
	local label = new("TextLabel", {
		Name = "ChipText",
		BackgroundTransparency = 1,
		Text = "QUESTS 0/3",
		FontFace = Theme.Font.Title,
		TextSize = 15,
		TextScaled = true,
		TextColor3 = C.Text,
		TextXAlignment = Enum.TextXAlignment.Left,
		TextTruncate = Enum.TextTruncate.AtEnd,
		TextStrokeTransparency = 1,
	}, b)
	new("UITextSizeConstraint", { Name = "Fit", MaxTextSize = 16, MinTextSize = 8 }, label)
	NoticeDots.Attach("Quests", b, { Position = UDim2.new(1, -4, 0, 4) })

	local wanted, covered = false, false
	local function sync()
		b.Visible = wanted and not covered and Config.FeatureOn("DailyQuests")
	end
	UIState.OnOwnerChanged(function(owner: string?)
		covered = owner ~= nil
		sync()
	end)

	local chip: Chip
	chip = {
		Button = b,
		Layout = function(x: number, y: number, w: number, h: number)
			wanted = w > 0 and h > 0
			b.Position = UDim2.fromOffset(math.floor(x + 0.5), math.floor(y + 0.5))
			b.Size = UDim2.fromOffset(math.floor(w + 0.5), math.floor(h + 0.5))
			local s = math.max(14, h - 12)
			iconHolder.Position = UDim2.fromOffset(8, (h - s) / 2)
			iconHolder.Size = UDim2.fromOffset(s, s)
			label.Position = UDim2.fromOffset(8 + s + 6, 4)
			label.Size = UDim2.new(1, -(8 + s + 6 + 12), 1, -8)
			sync()
		end,
		Hide = function()
			wanted = false
			sync()
		end,
		Refresh = function(p: { [string]: any }?)
			local day = today()
			local s = save(p)
			local done, got = QuestData.Counts(s, day)
			local n = #QuestData.Pick(day)
			local _, _, bonus = QuestData.View(s, day)
			label.Text = (got >= n and bonus) and "QUESTS DONE" or string.format("QUESTS %d/%d", done, n)
		end,
	}
	return chip
end

return MenuQuests
