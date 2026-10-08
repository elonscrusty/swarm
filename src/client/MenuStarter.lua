--[[
	MenuStarter.lua (Config.Features.StarterBundle; docs/next/STARTER_BUNDLE.md)
	The STARTER BUNDLE screen, opened from the home card (StarterCard) and the Store's top
	card. What is inside (rows), how long the offer lasts and one BUY button with the Robux
	price from GetProductInfo (never a number from the game). The server checks the offer
	and opens the Roblox prompt (remote "StarterBundle"); the receipt grants everything once
	(StarterBundle.lua). Cosmetic + gold only: nothing here changes a run's power.
]]

local Players = game:GetService("Players")

local Shared = game:GetService("ReplicatedStorage"):WaitForChild("Shared")
local Theme = require(Shared:WaitForChild("Theme"))
local Config = require(Shared:WaitForChild("Config"))
local UIKit = require(script.Parent.UIKit)
local UIAnim = require(script.Parent.UIAnim)
local MetaUI = require(script.Parent.MetaUI)
local StarterCard = require(script.Parent.StarterCard)

local MenuStarter = {}

local TS = UIKit.TS
local C = Theme.Color
local player = Players.LocalPlayer

function MenuStarter.Build(screen: Frame, ctx: { [string]: any })
	local host = ctx.Host
	local ui = MetaUI.Screen(screen, ctx, "STARTER BUNDLE", 720)
	local title = MetaUI.Line(ui.Head, "H3", "FOR NEW HEROES", 20, { Name = "StarterHead", TextColor3 = C.BlueDeep })
	local sub = MetaUI.Line(ui.Head, "Small", "", 14, { Name = "StarterRule" })
	UIKit.list(ui.Body, { Padding = UDim.new(0, 6) })
	local buy
	buy = UIKit.Button(ui.Foot, {
		Kind = "Primary",
		Glow = true,
		Title = "BUY",
		Icon = "robux",
		IconSize = 22,
		TitleStyle = "H2",
		Align = "Center",
		Shrink = true,
		Name = "BuyStarter",
		Size = UDim2.fromScale(1, 1),
		OnClick = function()
			if StarterCard.Offered() then
				StarterCard.Buy()
			end
		end,
	})

	local function fill()
		local c = (Config :: any).StarterBundle or {}
		local offered, owned = StarterCard.Offered(), StarterCard.Owned()
		local left = StarterCard.TimeLeft()
		if owned then
			sub.Text = "You own the Starter Bundle. Thank you!"
		elseif offered then
			sub.Text = "Once per account" .. (left ~= "" and (" · offer ends in " .. (string.gsub(left, " left$", ""))) or "") .. ". Looks and gold only."
		else
			sub.Text = "This offer is for new players in their first " .. tostring(c.OfferDays or 7) .. " days."
		end
		MetaUI.Clear(ui.Body)
		local rows = {
			{ Name = "Skin", Icon = "helmet", Title = "PIONEER KNIGHT SKIN", Sub = "A gold and green look for the Knight. Only in this bundle." },
			{ Name = "Gold", Icon = "lobby_Gold", Title = UIKit.formatNumber(tonumber(c.Gold) or 0) .. " GOLD", Sub = "Added to your gold at once." },
			{ Name = "Title", Icon = "medal", Title = "PIONEER TITLE", Sub = "Shown under your name." },
		}
		for i, r in ipairs(rows) do
			local row = MetaUI.Row(ui.Body, { Name = r.Name, Order = i, Icon = r.Icon, Title = r.Title, Sub = r.Sub, Height = 60 })
			row.SetDone(owned)
		end
		if owned then
			buy.SetText("OWNED")
			buy.SetEnabled(false)
		elseif not offered then
			buy.SetText("NOT AVAILABLE")
			buy.SetEnabled(false)
		else
			local price = StarterCard.Price(function()
				if screen.Visible then
					fill()
				end
			end)
			buy.SetText(price and ("BUY · " .. price) or "BUY")
			buy.SetEnabled(true)
		end
	end

	local function layout(v: Vector2, portrait: boolean, ins: { [string]: number })
		local h1, h2 = TS(20) + 6, TS(14) + 6
		ui.Layout(v, portrait, ins, h1 + h2, 60)
		local w = ui.Head.Size.X.Offset
		MetaUI.place(title, 0, 0, w, h1)
		MetaUI.place(sub, 0, h1, w, h2)
	end

	for _, name in ipairs({ "StarterOffer", "StarterOwned" }) do
		player:GetAttributeChangedSignal(name):Connect(function()
			if screen.Visible then
				fill()
			end
		end)
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

return MenuStarter
