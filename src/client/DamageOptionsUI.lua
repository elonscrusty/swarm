--[[
	DamageOptionsUI.lua (Config.Features.DamageNumberOptions; docs/next/DAMAGE_NUMBERS.md)
	The two Settings rows for the floating damage numbers, built in the Settings screen's own
	style (UIBuilder's buildPause calls Build for its Comfort column; UIBuilder has no top
	level locals left, so the row code lives here):

	  DAMAGE NUMBERS: NORMAL   a cycle button like COLORS / TOUCH LAYOUT: Off > Small >
	                           Normal > Big. Off is the old DamageNumbers setting being false,
	                           the other three also set DamageNumberSize.
	  Combine numbers          a toggle: hits on one enemy within 0.3 s become one number.

	Both save through ClientSettings.Set (the existing SaveSettings path); the pure rules
	(which words, which settings) are DamageNumberView.
]]

local Shared = game:GetService("ReplicatedStorage"):WaitForChild("Shared")
local View = require(Shared:WaitForChild("DamageNumberView"))
local Config = require(Shared:WaitForChild("Config"))
local ClientSettings = require(script.Parent.ClientSettings)
local UIKit = require(script.Parent.UIKit)
local UIAnim = require(script.Parent.UIAnim)

local DamageOptionsUI = {}

export type Rows = {
	Size: any, -- the cycle button
	Combine: any, -- the toggle
	Sync: () -> (), -- re-read both from the settings
}

local function current(): string
	return View.Mode({
		DamageNumbers = ClientSettings.Get("DamageNumbers"),
		DamageNumberSize = ClientSettings.Get("DamageNumberSize"),
	})
end

local function title(mode: string): string
	return "DAMAGE NUMBERS: " .. string.upper(mode)
end

-- Adds the rows to `parent` (a settings column) at the given LayoutOrders.
function DamageOptionsUI.Build(parent: Instance, sizeOrder: number, combineOrder: number): Rows
	local button
	button = UIKit.Button(parent, {
		Title = title(current()),
		Kind = "Outline",
		Icon = "cycle",
		IconSize = 18,
		Shrink = true,
		Size = UDim2.new(1, 0, 0, 46),
		LayoutOrder = sizeOrder,
		OnClick = function()
			local settings = View.Apply(View.Next(current()))
			if settings then
				for key, value in pairs(settings) do
					ClientSettings.Set(key, value)
				end
			end
			button.SetText(title(current()))
			UIAnim.Bump(button.Face)
		end,
	})
	local blurb = "Hits on one enemy within " .. string.format("%.1f", Config.DamageNumberOptions.CombineSeconds) .. " s show as one number."
	local combine = UIKit.Toggle(parent, "Combine numbers", "sword", blurb, ClientSettings.Get("CombineNumbers") ~= false, function(on)
		ClientSettings.Set("CombineNumbers", on)
	end, { LayoutOrder = combineOrder })
	local rows: Rows = {
		Size = button,
		Combine = combine,
		Sync = function()
			button.SetText(title(current()))
			combine.Set(ClientSettings.Get("CombineNumbers") ~= false)
		end,
	}
	return rows
end

return DamageOptionsUI
