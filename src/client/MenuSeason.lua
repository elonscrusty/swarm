--[[
	MenuSeason.lua
	The SEASON screen (feature 22, Config.Features.SeasonTrack): the free season track.
	  head  the season's name and end, your tier and the XP bar to the next one
	  body  every tier's reward (gold, a title or a nameplate frame): CLAIM once reached
	  foot  CLAIM ALL
	Season XP is the account XP of each clean run. Free only: there is no paid lane. The
	server pays every claim once (MetaService, Season.Claimed).
]]

local Shared = game:GetService("ReplicatedStorage"):WaitForChild("Shared")
local Theme = require(Shared:WaitForChild("Theme"))
local MetaData = require(Shared:WaitForChild("MetaData"))
local CurseData = require(Shared:WaitForChild("CurseData"))
local UIKit = require(script.Parent.UIKit)
local UIAnim = require(script.Parent.UIAnim)
local MetaUI = require(script.Parent.MetaUI)

local MenuSeason = {}

local TS = UIKit.TS
local P = Theme.Palette

-- (season or nil, xp, claimed set) for this profile (a save still on an old season reads 0).
function MenuSeason.State(p: { [string]: any }?): (MetaData.Season?, number, { [string]: boolean })
	local season = MetaData.Season(MetaUI.Now())
	local s = MetaUI.Features(p).Season
	if not season or type(s) ~= "table" or s.Id ~= season.Id then
		return season, 0, {}
	end
	return season, tonumber(s.XP) or 0, type(s.Claimed) == "table" and s.Claimed or {}
end

-- Tiers reached but not claimed (the MORE row's dot / sub line).
function MenuSeason.Unclaimed(p: { [string]: any }?): number
	local season, xp, claimed = MenuSeason.State(p)
	if not season then
		return 0
	end
	local n = 0
	for tier = 1, MetaData.TierFor(xp) do
		if not claimed[tostring(tier)] then
			n += 1
		end
	end
	return n
end

function MenuSeason.Summary(p: { [string]: any }?): string
	local season, xp = MenuSeason.State(p)
	if not season then
		return "No season running"
	end
	local open = MenuSeason.Unclaimed(p)
	return string.format("Tier %d/%d%s", MetaData.TierFor(xp), MetaData.SeasonTiers(), open > 0 and (" · " .. open .. " to claim") or " · free rewards")
end

local function rewardText(r: MetaData.Reward): (string, string)
	if r.Kind == "Gold" then
		return "+" .. tostring(r.Gold) .. " GOLD", "lobby_Gold"
	elseif r.Kind == "Title" then
		local def = MetaData.TitleById[r.Id or ""]
		return "TITLE · " .. string.upper(def and def.Name or tostring(r.Id)), "medal"
	end
	local plate = MetaData.NameplateById[r.Id or ""]
	return "NAMEPLATE · " .. string.upper(plate and plate.Name or tostring(r.Id)), "crown"
end

function MenuSeason.Build(screen: Frame, ctx: { [string]: any })
	local host = ctx.Host
	local ui = MetaUI.Screen(screen, ctx, "SEASON")
	local title = MetaUI.Line(ui.Head, "H3", "", 20, { Name = "SeasonName", TextColor3 = P.gold_200 })
	local sub = MetaUI.Line(ui.Head, "Small", "", 14, { Name = "SeasonEnds" })
	local meter = UIKit.Meter(ui.Head, { Size = UDim2.new(1, 0, 0, 26) })
	meter.Frame.Name = "SeasonBar"
	UIKit.list(ui.Body, { Padding = UDim.new(0, 6) })
	local claimAll = UIKit.Button(ui.Foot, {
		Kind = "Primary",
		Title = "CLAIM ALL",
		Icon = "gift",
		IconSize = 22,
		TitleStyle = "H2",
		Align = "Center",
		Name = "ClaimAll",
		Size = UDim2.fromScale(1, 1),
		OnClick = function()
			MetaUI.Send("ClaimSeason", "All")
		end,
	})

	local function fill()
		local p = ctx.Profile()
		local season, xp, claimed = MenuSeason.State(p)
		local per = MetaData.SeasonXPPerTier()
		local tiers = MetaData.SeasonTiers()
		local tier = MetaData.TierFor(xp)
		if season then
			title.Text = string.upper(season.Name) .. " · TIER " .. tier .. "/" .. tiers
			local left = (season.End + 1) * 86400 - MetaUI.Now()
			sub.Text = "Ends " .. CurseData.DateText(season.End) .. " (" .. MetaData.TimeText(left) .. " left) · season XP = account XP from runs"
		else
			title.Text = "NO SEASON RUNNING"
			sub.Text = "The next season starts soon."
		end
		if tier >= tiers then
			meter.Set(1, "Track complete!")
		else
			local into = xp - tier * per
			meter.Set(math.clamp(into / per, 0, 1), string.format("%s / %s XP to tier %d", UIKit.formatNumber(into), UIKit.formatNumber(per), tier + 1))
		end
		local open = MenuSeason.Unclaimed(p)
		claimAll.SetEnabled(open > 0)
		claimAll.SetText(open > 0 and ("CLAIM ALL · " .. open) or "CLAIM ALL")
		MetaUI.Clear(ui.Body)
		for t = 1, tiers do
			local r = MetaData.SeasonReward(t)
			local name, icon = rewardText(r)
			local reached = season ~= nil and t <= tier
			local got = claimed[tostring(t)] == true
			local row = MetaUI.Row(ui.Body, {
				Name = "Tier" .. t,
				Order = t,
				Icon = icon,
				Title = string.format("TIER %d · %s", t, name),
				Sub = got and "Claimed" or (reached and "Ready to claim" or string.format("Needs %s XP", UIKit.formatNumber(t * per - xp))),
				Height = 58,
				Action = (reached and not got) and {
					Title = "CLAIM",
					Kind = "Primary",
					OnClick = function()
						MetaUI.Send("ClaimSeason", t)
					end,
				} or nil,
			})
			row.SetDim(not reached or got)
		end
	end

	local function layout(v: Vector2, portrait: boolean, ins: { [string]: number })
		local h1, h2 = TS(20) + 6, TS(14) + 6
		local headH = h1 + h2 + 8 + 26
		ui.Layout(v, portrait, ins, headH, 56)
		local w = ui.Head.Size.X.Offset
		MetaUI.place(title, 0, 0, w, h1)
		MetaUI.place(sub, 0, h1, w, h2)
		MetaUI.place(meter.Frame, 0, h1 + h2 + 8, w, 26)
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

return MenuSeason
