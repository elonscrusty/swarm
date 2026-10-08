--[[
	AffixIconData.lua
	What each elite affix looks like as a badge, and the one-line notice a player gets the
	first time they meet it (Config.Features.AffixIcons, Config.AffixIcons;
	docs/next/AFFIX_ICONS.md). Pure data and helpers shared by the client badge
	(AffixIcons.lua), the server first-sight check (AffixSight.lua) and the regression scene.

	The affixes themselves are Config.Enemies.EliteAffixes (rolled by EnemySpawner, replicated
	as the enemy body attribute "Affix"). Every affix has its own SHAPE as well as its colour,
	so colour-blind players can tell them apart:
	  Swift     blue circle with three speed lines
	  Shielded  silver shield
	  Burning   orange flame (a drop with a point)
]]

local AffixIconData = {}

export type Entry = {
	Id: string,
	Shape: string, -- "Lines" | "Shield" | "Flame"
	Name: string, -- what the badge is called (accessibility text)
	Color: Color3, -- the badge's main colour (goes through Accessibility.Color on the client)
	Role: string, -- Accessibility role for that colour
	Notice: string, -- the first-sight line
}

AffixIconData.ById = {
	Swift = {
		Id = "Swift",
		Shape = "Lines",
		Name = "Swift",
		Color = Color3.fromRGB(80, 170, 255),
		Role = "Ally",
		Notice = "Swift elites run much faster than normal enemies",
	},
	Shielded = {
		Id = "Shielded",
		Shape = "Shield",
		Name = "Shielded",
		Color = Color3.fromRGB(205, 214, 224),
		Role = "Neutral",
		Notice = "Shielded elites block the first hits",
	},
	Burning = {
		Id = "Burning",
		Shape = "Flame",
		Name = "Burning",
		Color = Color3.fromRGB(255, 140, 40),
		Role = "Danger",
		Notice = "Burning elites leave fire behind them",
	},
} :: { [string]: Entry }

-- The entry for an affix id, or nil for anything that is not an affix (junk attribute).
function AffixIconData.Get(affix: any): Entry?
	if type(affix) ~= "string" then
		return nil
	end
	return AffixIconData.ById[affix]
end

-- The shapes of all affixes are different from each other (the regression checks it).
function AffixIconData.Shapes(): { [string]: string }
	local out = {}
	for id, e in pairs(AffixIconData.ById) do
		out[id] = e.Shape
	end
	return out
end

return AffixIconData
