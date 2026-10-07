--[[
	DamageNumberView.lua
	Pure helpers for the damage number options (Config.Features.DamageNumberOptions,
	Config.DamageNumberOptions; docs/next/DAMAGE_NUMBERS.md). Shared by the floating numbers
	(client DamageText.lua), the Settings rows (client DamageOptionsUI.lua) and the
	regression scene, so all three agree on what each choice means.

	One choice, four words: Off / Small / Normal / Big.
	  Off      the old DamageNumbers setting is false: the server sends nothing.
	  Small, Normal, Big   DamageNumbers is true and DamageNumberSize says which.
	Normal is the look the numbers always had (18 px, crits 22 px).

	With the switch off every function answers the old behaviour: Normal size, merge window
	Config.DamageNumbers.MergeSeconds, crits gold with a trailing "!".
]]

local Config = require(script.Parent.Config)

local View = {}

export type Settings = { [string]: any }

local function on(): boolean
	return Config.FeatureOn("DamageNumberOptions")
end

local function opts(): { [string]: any }
	return (Config :: any).DamageNumberOptions
end

-- The choice shown in the Settings row: "Off" | "Small" | "Normal" | "Big".
function View.Mode(settings: Settings?): string
	local s = settings or {}
	if s.DamageNumbers ~= true then
		return "Off"
	end
	if not on() then
		return "Normal"
	end
	local size = s.DamageNumberSize
	if type(size) == "string" and opts().Sizes[size] then
		return size
	end
	return "Normal"
end

-- The settings a choice stands for (what the row saves): { DamageNumbers, DamageNumberSize? }.
-- Choosing Off keeps the remembered size, so Off then Big again lands on Big.
function View.Apply(mode: string): { [string]: any }?
	if mode == "Off" then
		return { DamageNumbers = false }
	end
	if opts().Sizes[mode] then
		return { DamageNumbers = true, DamageNumberSize = mode }
	end
	return nil
end

-- The next choice when the row is tapped (Off > Small > Normal > Big > Off).
function View.Next(mode: string): string
	local order = opts().Order
	local at = table.find(order, mode) or 1
	return order[at % #order + 1]
end

-- Text size in pixels for a plain or critical number at a mode (Off has none).
function View.TextSize(mode: string, crit: boolean): number
	local row = opts().Sizes[on() and mode or "Normal"] or opts().Sizes.Normal
	return crit and row.Crit or row.Hit
end

-- The string shown: crits carry the star (and "!" without the switch), plain hits the number.
function View.Text(amount: number, crit: boolean): string
	local n = math.floor(amount + 0.5)
	local body = if amount >= 10000 then string.format("%.1fk", amount / 1000) else tostring(n)
	if not crit then
		return body
	end
	if on() then
		return opts().CritMark .. body
	end
	return body .. "!"
end

-- Seconds within which hits on one enemy merge into one number; 0 = never merge.
function View.MergeWindow(settings: Settings?): number
	if not on() then
		return Config.DamageNumbers.MergeSeconds
	end
	local s = settings or {}
	if s.CombineNumbers == false then
		return 0
	end
	return opts().CombineSeconds
end

-- True when crits use the bold face (always with the switch on).
function View.CritBold(): boolean
	return on()
end

return View
