--[[
	MenuSigils.lua
	The SIGILS screen (feature 1, Config.Features.Sigils; opened from PLAY's run setup).
	  head  the slots (1, and 2 once any hero reaches Mastery 3); tap a worn Sigil to take it off
	  body  every Sigil: found ones with EQUIP / WORN, the rest as dark silhouettes
	  foot  how Sigils are found and kept
	The server checks everything again (MetaService: owned, slot unlocked, lobby only) and
	applies worn Sigils in the run's stat sheet. No Robux: Sigils are only found in runs.
]]

local Shared = game:GetService("ReplicatedStorage"):WaitForChild("Shared")
local Theme = require(Shared:WaitForChild("Theme"))
local SigilData = require(Shared:WaitForChild("SigilData"))
local MetaUpgradeData = require(Shared:WaitForChild("MetaUpgradeData"))
local UIKit = require(script.Parent.UIKit)
local UIAnim = require(script.Parent.UIAnim)
local Icons = require(script.Parent.Icons)
local MetaUI = require(script.Parent.MetaUI)

local MenuSigils = {}

local new, TS = UIKit.new, UIKit.TS
local C = Theme.Color

-- Slots this profile has (the server decides the same way).
function MenuSigils.Slots(p: { [string]: any }?): number
	return SigilData.SlotsFor(p, function(xp: number): number
		return (MetaUpgradeData.MasteryFor(xp))
	end)
end

-- The worn Sigil ids (slot order) and the owned set.
function MenuSigils.State(p: { [string]: any }?): ({ string }, { [string]: any })
	local s = MetaUI.Features(p).Sigils
	local owned = type(s) == "table" and type(s.Owned) == "table" and s.Owned or {}
	local worn = {}
	if type(s) == "table" and type(s.Equipped) == "table" then
		for _, id in ipairs(s.Equipped) do
			if SigilData.Sigils[id] and owned[id] ~= nil then
				table.insert(worn, id)
			end
		end
	end
	return worn, owned
end

-- "Hare's Foot, Lodestar" / "None worn" for the PLAY row.
function MenuSigils.Summary(p: { [string]: any }?): string
	local worn = MenuSigils.State(p)
	local names = {}
	for _, id in ipairs(worn) do
		table.insert(names, SigilData.Sigils[id].Name)
	end
	return #names > 0 and table.concat(names, ", ") or "None worn · found on bosses and elites"
end

function MenuSigils.Build(screen: Frame, ctx: { [string]: any })
	local host = ctx.Host
	local ui = MetaUI.Screen(screen, ctx, "SIGILS")
	local slotFrames = {}
	for i = 1, 2 do
		local f = new("TextButton", { Name = "Slot" .. i, Text = "", AutoButtonColor = false, BackgroundColor3 = C.PanelRaised, BackgroundTransparency = 0, BorderSizePixel = 0 }, ui.Head)
		UIKit.corner(f, Theme.Radius.M)
		local stroke = UIKit.stroke(f, C.PanelEdge, 2, 0)
		local well = new("Frame", { Name = "Well", BackgroundTransparency = 1, Position = UDim2.fromOffset(10, 10), Size = UDim2.fromOffset(44, 44) }, f)
		local title = MetaUI.Line(f, "Label", "", 15, { Name = "SlotTitle", Position = UDim2.fromOffset(62, 8), Size = UDim2.new(1, -70, 0, TS(15) + 4) })
		local sub = new("TextLabel", { Name = "SlotSub", BackgroundTransparency = 1, Position = UDim2.fromOffset(62, 12 + TS(15)), Size = UDim2.new(1, -70, 1, -(16 + TS(15))), Text = "", FontFace = Theme.Font.Body, TextSize = TS(12), TextColor3 = C.TextMuted, TextWrapped = true, TextXAlignment = Enum.TextXAlignment.Left, TextYAlignment = Enum.TextYAlignment.Top, TextTruncate = Enum.TextTruncate.AtEnd }, f)
		slotFrames[i] = { Frame = f, Stroke = stroke, Well = well, Title = title, Sub = sub, Id = "" }
		f.Activated:Connect(function()
			local s = slotFrames[i]
			if s.Id ~= "" then
				MetaUI.Send("EquipSigil", i, "")
			elseif i > MenuSigils.Slots(ctx.Profile()) and ctx.Toast then
				ctx.Toast("Slot 2 opens when any hero reaches Mastery " .. SigilData.SlotUnlockMastery .. ".", C.BlueDeep)
			end
		end)
	end
	UIKit.list(ui.Body, { Padding = UDim.new(0, 8) })
	local rows = {}
	local foot = new("TextLabel", { Name = "Rules", BackgroundTransparency = 1, Size = UDim2.fromScale(1, 1), Text = "", FontFace = Theme.Font.Body, TextSize = TS(13), TextColor3 = C.TextMuted, TextWrapped = true, TextXAlignment = Enum.TextXAlignment.Left }, ui.Foot)
	foot.Text = string.format("Bosses drop one %d%% of the time, elites %d%%. Finish the run (win or portal) to keep it. Daily and Weekly runs ignore Sigils. A copy you own turns into gold.",
		math.floor(SigilData.BossChance * 100 + 0.5), math.floor(SigilData.EliteChance * 100 + 0.5))

	local function fill()
		local p = ctx.Profile()
		local worn, owned = MenuSigils.State(p)
		local slots = MenuSigils.Slots(p)
		for i, s in ipairs(slotFrames) do
			MetaUI.Clear(s.Well)
			local id = worn[i] or ""
			s.Id = id
			local def = SigilData.Sigils[id]
			if def then
				Icons.Draw(s.Well, def.Icon, { Size = 40, AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.5), Back = C.PanelRaised })
				s.Title.Text = def.Name
				s.Sub.Text = def.Text .. " · tap to remove"
				s.Stroke.Color = C.SelectedEdge
				s.Frame.BackgroundColor3 = C.SelectedPale
			else
				Icons.Draw(s.Well, i <= slots and "plus" or "lock", { Size = 30, AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.5), Color = C.TextMuted, Back = C.PanelRaised })
				s.Title.Text = "SLOT " .. i
				s.Sub.Text = i <= slots and "Empty: equip a Sigil below" or ("Locked: any hero at Mastery " .. SigilData.SlotUnlockMastery)
				s.Stroke.Color = i <= slots and C.PanelEdge or C.Divider
				s.Frame.BackgroundColor3 = i <= slots and C.PanelRaised or C.Disabled
			end
		end
		MetaUI.Clear(ui.Body)
		table.clear(rows)
		local found = 0
		for order, id in ipairs(SigilData.Order) do
			local def = SigilData.Sigils[id]
			local have = owned[id] ~= nil
			local isWorn = table.find(worn, id)
			if have then
				found += 1
			end
			local row = MetaUI.Row(ui.Body, {
				Name = id,
				Order = order + (have and 0 or 100),
				Icon = def.Icon,
				Title = have and string.upper(def.Name) .. " · " .. string.upper(def.Rarity) or "???",
				Sub = have and def.Text or "Not found yet: bosses and elites drop Sigils",
				Action = have and {
					Title = isWorn and "WORN" or "EQUIP",
					Kind = isWorn and "Selected" or "Secondary",
					OnClick = function()
						if isWorn then
							MetaUI.Send("EquipSigil", isWorn, "")
							return
						end
						local slot = math.min(#worn + 1, slots)
						MetaUI.Send("EquipSigil", slot, id)
					end,
				} or nil,
			})
			if isWorn then
				row.SetDone(true)
			end
			if not have then
				MetaUI.Silhouette(row.Icon)
				row.SetDim(true)
			end
			rows[id] = row
		end
		ui.Header.Title.Text = string.format("SIGILS · %d/%d", found, #SigilData.Order)
	end

	local function layout(v: Vector2, portrait: boolean, ins: { [string]: number })
		local headH = 64
		local footH = TS(13) * (v.X < 600 and 4 or 2) + 10
		ui.Layout(v, portrait, ins, headH, footH)
		local w = ui.Head.Size.X.Offset
		local G = Theme.Layout.Gutter
		local sw = math.floor((w - G) / 2)
		for i, s in ipairs(slotFrames) do
			MetaUI.place(s.Frame, (i - 1) * (sw + G), 0, sw, headH)
		end
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

return MenuSigils
