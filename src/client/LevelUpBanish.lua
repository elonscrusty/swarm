--[[
	LevelUpBanish.lua (client)
	Batch B item B6, Banish (Config.Features.Banish; docs/next/BANISH.md).

	The BANISH button next to REROLL and SKIP on the level-up panel (UIBuilder buildLevelUp
	makes the panel; this module owns the button and the banish mode). Tap BANISH (keyboard B,
	gamepad Y, or select it and press A), then a NEW card: the server (LevelUpSystem,
	remote LevelUpBanish with the set's OfferId) removes that weapon / passive from the
	offers for the rest of the run and re-rolls only that slot. Cards for things you own
	(upgrades, evolutions) and the bonus cards can't be banished: they dim while the mode is
	on, and tapping one just leaves the mode (never a pick by accident). Tap BANISH again to
	cancel. The panel's timer and pause are unchanged (co-op: per player, nobody waits).

	The offer carries Banishes (left this run) and BanishesMax; without them (switched off)
	the button stays hidden and the panel is exactly as before.

	UIBuilder hooks (one line each):
	  LevelUpBanish.Build(actions, cards, ruleR)   once, from buildLevelUp
	  LevelUpBanish.Show(offer)                    every LevelUpOffer (before the texts)
	  LevelUpBanish.Visible()                      layoutLevelUp: three buttons or two
	  LevelUpBanish.Size(bw, ah, others)           layoutLevelUp: button sizes (icons drop
	                                               on narrow buttons)
	  LevelUpBanish.Intercept(index)               chooseCard: (handled, fired)
	  LevelUpBanish.Mark()                         after the cards are (re)built
	  LevelUpBanish.Close()                        the panel closed
	  LevelUpBanish.Active()                       banish mode on (tests)
	  LevelUpBanish.Toggle()                       what B / Y / the button do (tests)
]]

local UserInputService = game:GetService("UserInputService")
local Shared = game:GetService("ReplicatedStorage"):WaitForChild("Shared")
local Config = require(Shared:WaitForChild("Config"))
local Remotes = require(Shared:WaitForChild("Remotes"))
local Theme = require(Shared:WaitForChild("Theme"))
local UIKit = require(script.Parent.UIKit)

local LevelUpBanish = {}

local C = Theme.Color
local ui: { [string]: any } = {}
local state = {
	Active = false,
	Shown = false,
	Open = false,
	Left = 0,
	Offer = nil :: { [string]: any }?,
}

local BANISHABLE = { WeaponNew = true, PassiveNew = true }

function LevelUpBanish.CanBanish(c: any): boolean
	return type(c) == "table" and BANISHABLE[c.Type] == true
end

local function owned(c: any): boolean
	return type(c) == "table" and (c.Type == "WeaponUp" or c.Type == "PassiveUp" or c.Type == "Evolve")
end

local function refreshButton()
	local b = ui.Button
	if not b then
		return
	end
	b.Instance.Visible = state.Shown
	if state.Active then
		b.SetText("CANCEL", "Tap a NEW card")
		b.SetKind("Selected")
	else
		b.SetText("BANISH", state.Left > 0 and string.format("%d left", state.Left) or "None left this run")
		b.SetKind("Outline")
	end
	b.SetEnabled(state.Left > 0)
end

-- Dims the cards that can't be banished, tints the ones that can, and turns their CHOOSE
-- plate word into BANISH / OWNED while the mode is on (restored when it ends).
function LevelUpBanish.Mark()
	local cards = ui.Cards :: Frame?
	local offer = state.Offer
	if not cards or not offer then
		return
	end
	for _, card in ipairs(cards:GetChildren()) do
		local index = tonumber(string.match(card.Name, "^Card(%d+)$"))
		local face = index and card:FindFirstChild("Face")
		if face and face:IsA("GuiObject") then
			local c = offer.Choices and offer.Choices[index :: number]
			local old = face:FindFirstChild("BanishMark")
			if old then
				old:Destroy()
			end
			local plate = face:FindFirstChild("ChoosePlate")
			local word: TextLabel? = nil
			if plate then
				for _, l in ipairs(plate:GetChildren()) do
					if l:IsA("TextLabel") and (l.Text == "CHOOSE" or l:GetAttribute("BanishOrig") ~= nil) then
						word = l
					end
				end
			end
			if state.Active then
				local can = LevelUpBanish.CanBanish(c)
				local mark = UIKit.new("Frame", {
					Name = "BanishMark",
					BackgroundColor3 = can and C.Danger or C.Backdrop,
					BackgroundTransparency = can and 0.82 or 0.45,
					BorderSizePixel = 0,
					Size = UDim2.fromScale(1, 1),
					Active = false,
					ZIndex = 50,
				}, face)
				UIKit.corner(mark, Theme.Radius.L)
				if can then
					UIKit.stroke(mark, C.Danger, 3, 0)
				end
				if word then
					if word:GetAttribute("BanishOrig") == nil then
						word:SetAttribute("BanishOrig", word.Text)
					end
					word.Text = can and "BANISH" or (owned(c) and "OWNED" or tostring(word:GetAttribute("BanishOrig")))
				end
			elseif word and word:GetAttribute("BanishOrig") ~= nil then
				word.Text = tostring(word:GetAttribute("BanishOrig"))
				word:SetAttribute("BanishOrig", nil)
			end
		end
	end
end

local function setActive(on: boolean)
	on = on and state.Shown and state.Open and state.Left > 0
	if state.Active == on then
		return
	end
	state.Active = on
	refreshButton()
	LevelUpBanish.Mark()
end

function LevelUpBanish.Toggle()
	setActive(not state.Active)
end

function LevelUpBanish.Active(): boolean
	return state.Active
end

function LevelUpBanish.Visible(): boolean
	return state.Shown
end

function LevelUpBanish.Build(actions: Frame, cards: Frame, ruleR: GuiObject?)
	if ui.Button then
		return
	end
	ui.Cards = cards
	if ruleR then
		ruleR.LayoutOrder = 4 -- REROLL 1, SKIP 2, BANISH 3, then the right rule
	end
	local b = UIKit.Button(actions, {
		Kind = "Outline",
		Title = "BANISH",
		Subtitle = "3 left",
		TitleStyle = "Label",
		TitleSize = 17,
		Icon = "close",
		IconSize = 26,
		Size = UDim2.fromOffset(230, 60),
		Align = "Left",
		LayoutOrder = 3,
		Name = "Banish",
		OnClick = function()
			task.defer(LevelUpBanish.Toggle)
		end,
	})
	b.Instance.Visible = false
	-- the words shrink inside the button (phone large text), like REROLL / SKIP
	for _, l in ipairs({ b.Title, b.Subtitle }) do
		if l then
			l.TextScaled = true
			l:SetAttribute("NoTextFit", true)
			local tf = l:FindFirstChild("TextFit")
			if tf then
				tf:Destroy()
			end
			UIKit.new("UITextSizeConstraint", { Name = "Fit", MaxTextSize = l.TextSize, MinTextSize = math.min(l.TextSize, 9) }, l)
		end
	end
	ui.Button = b
	-- keyboard B / gamepad Y toggle the mode while the panel is open (the HUD's own B / Y
	-- build toggle stays off under the level-up panel: UIState owner), then 1 / 2 / 3
	-- (UIBuilder chooseCard → Intercept) banish that card
	UserInputService.InputBegan:Connect(function(input, processed)
		local key = input.KeyCode
		if key ~= Enum.KeyCode.B and key ~= Enum.KeyCode.ButtonY then
			return
		end
		if (processed and key ~= Enum.KeyCode.ButtonY) or UserInputService:GetFocusedTextBox() then
			return
		end
		if state.Open and state.Shown then
			LevelUpBanish.Toggle()
		end
	end)
end

function LevelUpBanish.Show(offer: { [string]: any })
	state.Offer = offer
	state.Open = true
	state.Shown = Config.FeatureOn("Banish") and type(offer.Banishes) == "number"
	state.Left = state.Shown and math.max(0, math.floor(tonumber(offer.Banishes) or 0)) or 0
	state.Active = false
	refreshButton()
end

function LevelUpBanish.Size(bw: number, ah: number, others: { any }?)
	local list = table.clone(others or {})
	if ui.Button then
		ui.Button.Instance.Size = UDim2.fromOffset(bw, ah)
		table.insert(list, ui.Button)
	end
	-- narrow buttons (three in a phone row) drop their icon so the words keep their size
	for _, b in ipairs(list) do
		local holder = b and b.Instance and b.Instance:FindFirstChild("IconHolder", true)
		if holder and holder:IsA("GuiObject") then
			holder.Visible = bw >= 150
		end
	end
end

-- A card was chosen (tap, click, 1 / 2 / 3, gamepad A). In banish mode it is banished
-- instead (only a NEW card; any other card just leaves the mode). Returns (handled, fired).
function LevelUpBanish.Intercept(index: number): (boolean, boolean)
	if not state.Active then
		return false, false
	end
	local offer = state.Offer
	local c = offer and offer.Choices and offer.Choices[index]
	setActive(false)
	if not offer or not LevelUpBanish.CanBanish(c) or state.Left <= 0 then
		return true, false
	end
	Remotes.Get("LevelUpBanish"):FireServer(index, offer.OfferId)
	return true, true
end

function LevelUpBanish.Close()
	state.Open = false
	setActive(false)
end

return LevelUpBanish
