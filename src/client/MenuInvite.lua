--[[
	MenuInvite.lua (Config.Features.InviteRewards; docs/next/INVITE_REWARDS.md)
	The INVITE FRIENDS screen (MORE screen row): the cosmetic rewards for inviting and one
	INVITE FRIENDS button. The button is the PARTY screen's own invite (MenuParty
	.InviteFriends: CanSendGameInviteAsync first, then SocialService:PromptGameInvite).
	Credits are decided on the server only (InviteRewards.lua; player attribute Recruits):
	a friend counts once, when they are new to SWARM and have finished a run.
]]

local Players = game:GetService("Players")

local Shared = game:GetService("ReplicatedStorage"):WaitForChild("Shared")
local Theme = require(Shared:WaitForChild("Theme"))
local Config = require(Shared:WaitForChild("Config"))
local UIKit = require(script.Parent.UIKit)
local UIAnim = require(script.Parent.UIAnim)
local MetaUI = require(script.Parent.MetaUI)
local MenuParty = require(script.Parent.MenuParty)

local MenuInvite = {}

local TS = UIKit.TS
local P = Theme.Palette
local player = Players.LocalPlayer

local function cfg(): { [string]: any }
	return (Config :: any).Invite or {}
end

function MenuInvite.Recruits(): number
	return math.max(0, math.floor(tonumber(player:GetAttribute("Recruits")) or 0))
end

-- The MORE row's line.
function MenuInvite.Summary(): string
	local n, at = MenuInvite.Recruits(), tonumber(cfg().TrailAt) or 3
	if n <= 0 then
		return "Rewards for bringing friends"
	end
	return string.format("%d friend%s joined · trail at %d", n, n == 1 and "" or "s", at)
end

function MenuInvite.Build(screen: Frame, ctx: { [string]: any })
	local host = ctx.Host
	local ui = MetaUI.Screen(screen, ctx, "INVITE FRIENDS", 720)
	local title = MetaUI.Line(ui.Head, "H3", "", 20, { Name = "InviteCount", TextColor3 = P.gold_200 })
	local sub = MetaUI.Line(ui.Head, "Small", "A friend counts once: new to SWARM and finished a run.", 14, { Name = "InviteRule" })
	UIKit.list(ui.Body, { Padding = UDim.new(0, 6) })
	UIKit.Button(ui.Foot, {
		Kind = "Primary",
		Glow = true,
		Title = "INVITE FRIENDS",
		Icon = "userPlus",
		IconSize = 22,
		TitleStyle = "H2",
		Align = "Center",
		Shrink = true,
		Name = "InviteFriends",
		Size = UDim2.fromScale(1, 1),
		OnClick = function()
			MenuParty.InviteFriends(ctx.Toast)
		end,
	})

	local function fill()
		local n, at = MenuInvite.Recruits(), math.max(1, math.floor(tonumber(cfg().TrailAt) or 3))
		title.Text = string.format("FRIENDS JOINED: %d", n)
		MetaUI.Clear(ui.Body)
		local rows = {
			{ Name = "Badge", Icon = "flag", Title = "FRIEND BADGE · FOR THEM", Sub = "A new player who joins from your invite gets this nameplate.", Done = false },
			{ Name = "Title", Icon = "medal", Title = "RECRUITER TITLE", Sub = n >= 1 and "Earned" or "Your first friend who finishes a run", Done = n >= 1 },
			{ Name = "Trail", Icon = "arrowFast", Title = "RECRUITER TRAIL", Sub = n >= at and "Earned" or string.format("%d / %d friends", math.min(n, at), at), Done = n >= at },
		}
		for i, r in ipairs(rows) do
			local row = MetaUI.Row(ui.Body, { Name = r.Name, Order = i, Icon = r.Icon, Title = r.Title, Sub = r.Sub, Height = 60 })
			row.SetDim(r.Done)
		end
	end

	local function layout(v: Vector2, portrait: boolean, ins: { [string]: number })
		local h1, h2 = TS(20) + 6, TS(14) + 6
		ui.Layout(v, portrait, ins, h1 + h2, 60)
		local w = ui.Head.Size.X.Offset
		MetaUI.place(title, 0, 0, w, h1)
		MetaUI.place(sub, 0, h1, w, h2)
	end

	player:GetAttributeChangedSignal("Recruits"):Connect(function()
		if screen.Visible then
			fill()
		end
	end)

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

return MenuInvite
