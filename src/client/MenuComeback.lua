--[[
	MenuComeback.lua
	The WELCOME BACK card (Config.Features.ComebackGift; docs/next/COMEBACK_GIFT.md). The
	server decides the gift when the profile loads (ComebackGift: 3+ days away, never a
	brand-new account, at most once per 72 h) and keeps it in the save until it is claimed
	(ProfileSync Features.Comeback.Pending). This screen shows it with one CLAIM button; the
	server pays it once. It opens by itself once per session on the home screen while a gift
	waits (LobbyScreen), and from its MORE row (listed just before DAILY REWARD). The login
	streak stays its own card: after the claim, the button leads on to DAILY REWARD when
	today's streak claim is open.
]]

local Shared = game:GetService("ReplicatedStorage"):WaitForChild("Shared")
local Theme = require(Shared:WaitForChild("Theme"))
local Config = require(Shared:WaitForChild("Config"))
local Remotes = require(Shared:WaitForChild("Remotes"))
local CosmeticData = require(Shared:WaitForChild("CosmeticData"))
local UIKit = require(script.Parent.UIKit)
local UIAnim = require(script.Parent.UIAnim)
local UIState = require(script.Parent.UIState)
local MetaUI = require(script.Parent.MetaUI)
local MenuStreak = require(script.Parent.MenuStreak)

local MenuComeback = {}

local TS = UIKit.TS
local P = Theme.Palette

local autoShown = false

-- The gift waiting in the profile ({ Days, Gold, Look? }) or nil.
function MenuComeback.Pending(p: { [string]: any }?): { [string]: any }?
	if not Config.FeatureOn("ComebackGift") then
		return nil
	end
	local c = MetaUI.Features(p).Comeback
	local g = type(c) == "table" and c.Pending or nil
	if type(g) ~= "table" or (tonumber(g.Gold) or 0) <= 0 then
		return nil
	end
	return g
end

-- The MORE row's line.
function MenuComeback.Summary(p: { [string]: any }?): string
	local g = MenuComeback.Pending(p)
	if not g then
		return "Nothing waiting"
	end
	return string.format("A gift is waiting: +%d gold%s", tonumber(g.Gold) or 0, g.Look and " and a look" or "")
end

--[[
	The home screen calls this on every profile: opens the card once per session while a
	gift waits, only on the home screen with nothing else open. `show` = LobbyScreen.Show.
]]
function MenuComeback.MaybeOpen(p: { [string]: any }?, current: string, visible: boolean, show: (string) -> ())
	if autoShown or not visible or current ~= "Home" or UIState.Owner() ~= nil then
		return
	end
	if MenuComeback.Pending(p) then
		autoShown = true
		show("Comeback")
	end
end

-- Tests: the card may open by itself again.
function MenuComeback._ResetSession()
	autoShown = false
end

function MenuComeback.Build(screen: Frame, ctx: { [string]: any })
	local host = ctx.Host
	local ui = MetaUI.Screen(screen, ctx, "WELCOME BACK!", 640)
	local title = MetaUI.Line(ui.Head, "H3", "", 20, { Name = "AwayDays", TextColor3 = P.gold_200 })
	local sub = MetaUI.Line(ui.Head, "Small", "", 14, { Name = "GiftRule" })
	UIKit.list(ui.Body, { Padding = UDim.new(0, 6) })
	local last: { [string]: any }? = nil -- the gift shown (kept after the claim to show it as claimed)
	local nextStreak = false
	local claim = UIKit.Button(ui.Foot, {
		Kind = "Primary",
		Glow = true,
		Title = "CLAIM",
		Icon = "gift",
		IconSize = 22,
		TitleStyle = "H2",
		Align = "Center",
		Shrink = true,
		Name = "ClaimComeback",
		Size = UDim2.fromScale(1, 1),
		OnClick = function()
			local p = ctx.Profile()
			if MenuComeback.Pending(p) then
				Remotes.Get("Comeback"):FireServer("Claim")
			elseif nextStreak then
				ctx.ShowScreen("Streak")
			else
				ctx.Back()
			end
		end,
	})

	local function fill()
		local p = ctx.Profile()
		local g = MenuComeback.Pending(p)
		if g then
			last = g
		end
		local shown = g or last
		local days = shown and math.floor(tonumber(shown.Days) or 0) or 0
		title.Text = shown and string.format("YOU WERE AWAY %d DAYS", days) or "WELCOME BACK"
		MetaUI.Clear(ui.Body)
		if shown then
			local row = MetaUI.Row(ui.Body, {
				Name = "GiftGold",
				Order = 1,
				Icon = "lobby_Gold",
				Title = string.format("+%d GOLD", math.floor(tonumber(shown.Gold) or 0)),
				Sub = g and "A gift for coming back" or "Claimed",
				Height = 60,
			})
			row.SetDim(g == nil)
			if type(shown.Look) == "string" then
				local e = CosmeticData.Get(shown.Look)
				local look = MetaUI.Row(ui.Body, {
					Name = "GiftLook",
					Order = 2,
					Icon = "sparkle",
					Title = "NEW LOOK · " .. string.upper(e and e.Name or shown.Look),
					Sub = g and "Wear it from the STORE (already owned: gold instead)" or "Claimed",
					Height = 60,
				})
				look.SetDim(g == nil)
			end
		end
		local streakOpen = Config.FeatureOn("LoginStreak") and (MenuStreak.State(p))
		nextStreak = g == nil and streakOpen == true
		if g then
			sub.Text = "Claim it once. Your daily reward is a separate card."
			claim.SetText("CLAIM GIFT")
		elseif nextStreak then
			sub.Text = "Claimed! Your daily reward is waiting too."
			claim.SetText("NEXT: DAILY REWARD")
		else
			sub.Text = shown and "Claimed! Have a good run." or "No gift is waiting."
			claim.SetText("BACK")
		end
		claim.SetEnabled(true)
	end

	local function layout(v: Vector2, portrait: boolean, ins: { [string]: number })
		local h1, h2 = TS(20) + 6, TS(14) + 6
		ui.Layout(v, portrait, ins, h1 + h2, 60)
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

return MenuComeback
