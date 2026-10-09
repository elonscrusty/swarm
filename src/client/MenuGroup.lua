--[[
	MenuGroup.lua (Config.Features.GroupBonus; docs/next/GROUP_BONUS.md)
	The JOIN OUR GROUP screen (MORE screen row; listed only while the switch is on and
	Config.Group.Id is set). It explains the member bonus and names the group: Roblox has no
	in-game group join prompt, so it says "find us on Roblox". Membership is checked on the
	server (GroupBonus.lua, player attribute GroupMember); this screen only shows it.
]]

local Players = game:GetService("Players")
local GroupService = game:GetService("GroupService")

local Shared = game:GetService("ReplicatedStorage"):WaitForChild("Shared")
local Theme = require(Shared:WaitForChild("Theme"))
local Config = require(Shared:WaitForChild("Config"))
local UIKit = require(script.Parent.UIKit)
local UIAnim = require(script.Parent.UIAnim)
local MetaUI = require(script.Parent.MetaUI)

local MenuGroup = {}

local TS = UIKit.TS
local C = Theme.Color
local player = Players.LocalPlayer

local groupName: string? = nil
local asking = false

local function cfg(): { [string]: any }
	return (Config :: any).Group or {}
end

function MenuGroup.GroupId(): number
	local id = cfg().Id
	return (type(id) == "number" and id > 0) and id or 0
end

-- The MORE row shows only while the bonus is live.
function MenuGroup.Shown(): boolean
	return Config.FeatureOn("GroupBonus") and MenuGroup.GroupId() ~= 0
end

function MenuGroup.IsMember(): boolean
	return player:GetAttribute("GroupMember") == true
end

-- The MORE row's line.
function MenuGroup.Summary(): string
	if MenuGroup.IsMember() then
		return "Member: +" .. math.floor((tonumber(cfg().GoldBonus) or 0) * 100 + 0.5) .. "% run gold"
	end
	return "+" .. math.floor((tonumber(cfg().GoldBonus) or 0) * 100 + 0.5) .. "% gold for members"
end

-- The group's name from Roblox (asks once; onName runs when it arrives).
local function nameOf(onName: () -> ()): string?
	if groupName then
		return groupName
	end
	local id = MenuGroup.GroupId()
	if id ~= 0 and not asking then
		asking = true
		task.spawn(function()
			local ok, info = pcall(function()
				return GroupService:GetGroupInfoAsync(id)
			end)
			if ok and type(info) == "table" and type(info.Name) == "string" and info.Name ~= "" then
				groupName = info.Name
				onName()
			else
				asking = false
			end
		end)
	end
	return nil
end

function MenuGroup.Build(screen: Frame, ctx: { [string]: any })
	local host = ctx.Host
	local ui = MetaUI.Screen(screen, ctx, "JOIN OUR GROUP", 720)
	local title = MetaUI.Line(ui.Head, "H3", "", 20, { Name = "GroupName", TextColor3 = C.BlueDeep })
	local sub = MetaUI.Line(ui.Head, "Small", "", 14, { Name = "GroupStatus" })
	UIKit.list(ui.Body, { Padding = UDim.new(0, 6) })

	local function fill()
		local c = cfg()
		local name = nameOf(function()
			if screen.Visible then
				fill()
			end
		end)
		title.Text = name and string.upper(name) or "OUR ROBLOX GROUP"
		if MenuGroup.IsMember() then
			sub.Text = "You're a member. Your bonus is on. Thank you!"
			sub.TextColor3 = C.Success
		else
			sub.Text = "Find us on Roblox: search for " .. (name and ('"' .. name .. '"') or "our group") .. " and join."
			sub.TextColor3 = Theme.Color.TextMuted
		end
		MetaUI.Clear(ui.Body)
		local pct = math.floor((tonumber(c.GoldBonus) or 0) * 100 + 0.5)
		local rows = {
			{ Name = "Gold", Icon = "lobby_Gold", Title = string.format("+%d%% GOLD FROM RUNS", pct), Sub = string.format("Up to +%s per run, added when the run ends.", UIKit.formatNumber(tonumber(c.GoldCap) or 0)) },
			{ Name = "Title", Icon = "medal", Title = "GROUP MEMBER TITLE", Sub = "Wear it under your name (TITLES)." },
			{ Name = "Star", Icon = "crown", Title = "NAMEPLATE STAR", Sub = "A star next to your name over your hero." },
			{ Name = "How", Icon = "info", Title = "HOW TO JOIN", Sub = "Tap the group on the game's page, then Join." } -- one line on portrait phones,
		}
		for i, r in ipairs(rows) do
			local row = MetaUI.Row(ui.Body, { Name = r.Name, Order = i, Icon = r.Icon, Title = r.Title, Sub = r.Sub, Height = 60 })
			row.SetDim(false)
		end
	end

	local function layout(v: Vector2, portrait: boolean, ins: { [string]: number })
		local h1, h2 = TS(20) + 6, TS(14) + 6
		ui.Layout(v, portrait, ins, h1 + h2, 0)
		local w = ui.Head.Size.X.Offset
		MetaUI.place(title, 0, 0, w, h1)
		MetaUI.place(sub, 0, h1, w, h2)
	end

	player:GetAttributeChangedSignal("GroupMember"):Connect(function()
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

return MenuGroup
