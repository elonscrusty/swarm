--[[
	MenuPrestige.lua (client; Config.Features.Prestige, docs/next/PRESTIGE.md)
	The PRESTIGE block of the Characters screen, built into MenuCharacters' MASTERY card
	under the hero's upgrade rows, plus the small star badge used on hero portraits.

	Shown for an owned hero while the switch is on, once it has a star, its mastery is at
	max or every upgrade is maxed:
	  PRESTIGE  ★2 / 5 · +10% gold from Knight runs
	  a line: what is left to max ("4 / 7 upgrades maxed"), or what a prestige does
	  PRESTIGE KNIGHT (outline) when the whole track is maxed and stars < 5: it opens the
	  confirmation screen (PrestigeConfirm), which sends the request after a second tap.
	The server (Prestige.lua) checks everything again.

	  MenuPrestige.Build(parent, order) -> { Frame, Refresh(heroId, profile, owned) }
	  MenuPrestige.StarsOf(profile, heroId) -> number
	  MenuPrestige.Badge(guiObject, stars)   a "★n" corner badge (hidden at 0)
]]

local Shared = game:GetService("ReplicatedStorage"):WaitForChild("Shared")
local Config = require(Shared:WaitForChild("Config"))
local Theme = require(Shared:WaitForChild("Theme"))
local CharacterData = require(Shared:WaitForChild("CharacterData"))
local MetaUpgradeData = require(Shared:WaitForChild("MetaUpgradeData"))
local PrestigeData = require(Shared:WaitForChild("PrestigeData"))
local UIKit = require(script.Parent.UIKit)
local PrestigeConfirm = require(script.Parent.PrestigeConfirm)

local MenuPrestige = {}

local new, text, TS = UIKit.new, UIKit.text, UIKit.TS
local C = Theme.Color
local HEADING = Theme.Font.Heading

local function on(): boolean
	return Config.FeatureOn("Prestige")
end

-- The hero's stars from a ProfileSync (Features.Prestige).
function MenuPrestige.StarsOf(p: { [string]: any }?, heroId: string): number
	if not on() or type(p) ~= "table" then
		return 0
	end
	local f = type(p.Features) == "table" and p.Features or {}
	return PrestigeData.Stars(f.Prestige, heroId)
end

-- A small gold "★n" badge in the bottom-right corner of `holder` (hidden for 0 stars).
function MenuPrestige.Badge(holder: GuiObject?, stars: number)
	if not holder then
		return
	end
	local badge = holder:FindFirstChild("PrestigeBadge") :: TextLabel?
	if stars <= 0 then
		if badge then
			badge.Visible = false
		end
		return
	end
	if not badge then
		local b = text(holder, "Label", "", {
			Name = "PrestigeBadge",
			AnchorPoint = Vector2.new(1, 1),
			Position = UDim2.new(1, -2, 1, -2),
			Size = UDim2.fromOffset(0, TS(12) + 6),
			AutomaticSize = Enum.AutomaticSize.X,
			BackgroundColor3 = C.Panel,
			BackgroundTransparency = 0,
			TextColor3 = C.BlueDeep,
			FontFace = HEADING,
			ZIndex = 8,
		}, 12)
		b:SetAttribute("NoTextFit", true)
		UIKit.corner(b, 6)
		UIKit.stroke(b, C.PanelEdge, 1.5, 0)
		UIKit.padding(b, 0, 4, 0, 4)
		badge = b
	end
	if badge then
		badge.Text = PrestigeData.StarText(stars)
		badge.Visible = true
	end
end

local function wrapped(parent: Instance, style: string, color: Color3, size: number, order: number, name: string): TextLabel
	return text(parent, style, "", {
		Name = name,
		LayoutOrder = order,
		Size = UDim2.new(1, 0, 0, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		TextWrapped = true,
		FontFace = Theme.Font.Body,
		LineHeight = 1.15,
		TextColor3 = color,
		TextYAlignment = Enum.TextYAlignment.Top,
	}, size)
end

function MenuPrestige.Build(parent: Instance, order: number)
	local root = new("Frame", { Name = "Prestige", BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 0), AutomaticSize = Enum.AutomaticSize.Y, LayoutOrder = order, Visible = false }, parent)
	UIKit.list(root, { Padding = UDim.new(0, 6) })
	UIKit.Hairline(root, { LayoutOrder = 0 })
	text(root, "Label", "PRESTIGE", { Name = "Caption", FontFace = HEADING, TextColor3 = C.BlueDeep, LayoutOrder = 1, Size = UDim2.new(1, 0, 0, TS(13) + 4) }, 13)
	local stateLine = wrapped(root, "BodyStrong", C.BlueDeep, 15, 2, "Stars")
	stateLine.FontFace = HEADING
	local rule = wrapped(root, "Small", C.TextMuted, 14, 3, "Rule")
	local heroNow = CharacterData.Default
	local starsNow = 0
	local button = UIKit.Button(root, {
		Name = "PrestigeButton",
		Kind = "Outline",
		Title = "PRESTIGE",
		Align = "Center",
		Shrink = true,
		Size = UDim2.new(1, 0, 0, 42),
		LayoutOrder = 4,
		Shadow = false,
		OnClick = function()
			PrestigeConfirm.Open(heroNow, starsNow)
		end,
	})

	local function refresh(heroId: string, p: { [string]: any }?, owned: boolean)
		heroNow = heroId
		local def = CharacterData.Characters[heroId]
		local name = def and def.Name or heroId
		local stars = MenuPrestige.StarsOf(p, heroId)
		starsNow = stars
		local track = p and type(p.HeroUpgrades) == "table" and p.HeroUpgrades[heroId] or nil
		local maxed = PrestigeData.IsMaxed(heroId, track)
		local heroes = p and type(p.Heroes) == "table" and p.Heroes or {}
		local h = type(heroes[heroId]) == "table" and heroes[heroId] or {}
		local mastery = MetaUpgradeData.MasteryFor(h.XP or 0)
		local atMax = mastery >= Config.HeroMastery.MaxLevel
		local maxStars = PrestigeData.MaxStars()
		root.Visible = on() and owned and (stars > 0 or atMax or maxed)
		if not root.Visible then
			return
		end
		if stars > 0 then
			stateLine.Text = string.format("%s / %d  ·  %s gold from %s runs", PrestigeData.StarText(stars), maxStars, PrestigeData.PercentText(stars), name)
		else
			stateLine.Text = string.format("No stars yet  ·  up to %s gold", PrestigeData.PercentText(maxStars))
		end
		local done, total = PrestigeData.Progress(heroId, track)
		if stars >= maxStars then
			rule.Text = string.format("The %s has every prestige star.", name)
		elseif maxed then
			rule.Text = string.format("Every %s upgrade is maxed. Prestige puts them back to level 0 for a star: %s gold from %s runs (paid when a run ends). No combat power.",
				name, PrestigeData.PercentText(stars + 1), name)
		else
			rule.Text = string.format("Max every %s upgrade to prestige (%d / %d maxed). Each star adds %s gold from %s runs, up to %s.",
				name, done, total, PrestigeData.PercentText(1), name, PrestigeData.PercentText(maxStars))
		end
		local canPrestige = maxed and stars < maxStars
		button.Instance.Visible = canPrestige
		button.SetText(PrestigeData.ButtonText(name))
	end

	return {
		Frame = root,
		Refresh = refresh,
	}
end

return MenuPrestige
