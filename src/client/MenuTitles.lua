--[[
	MenuTitles.lua
	The TITLES screen (feature 23, Config.Features.Titles): every title in the game
	(achievement, account level and the META milestones, CosmeticData kind "Title") and the
	META nameplate frames (worn through the STORE's StoreEquip, so only while the Store
	switch is on). Earned ones can be worn; the rest say how to earn them.
	  head  your name plate as others see it (name, worn title, frame colour)
	  body  NAMEPLATE FRAMES, then TITLES (earned first)
	Titles are worn through EquipCosmetic("Title", text) (AchievementService checks the
	source, MetaService the META ones). The plate shows over your hero in the lobby and in
	runs (TitlePlates).
]]

local Players = game:GetService("Players")
local Shared = game:GetService("ReplicatedStorage"):WaitForChild("Shared")
local Theme = require(Shared:WaitForChild("Theme"))
local Remotes = require(Shared:WaitForChild("Remotes"))
local CosmeticData = require(Shared:WaitForChild("CosmeticData"))
local AchievementData = require(Shared:WaitForChild("AchievementData"))
local AccountData = require(Shared:WaitForChild("AccountData"))
local MetaData = require(Shared:WaitForChild("MetaData"))
local Config = require(Shared:WaitForChild("Config"))
local UIKit = require(script.Parent.UIKit)
local UIAnim = require(script.Parent.UIAnim)
local MetaUI = require(script.Parent.MetaUI)

local MenuTitles = {}

local new, TS = UIKit.new, UIKit.TS
local C = Theme.Color

-- True when this profile has earned the title text `name`.
function MenuTitles.Owns(p: { [string]: any }?, name: string): boolean
	if not p then
		return false
	end
	local source = AchievementData.Source("Title", name)
	local ach = type(p.Achievements) == "table" and p.Achievements.Unlocked
	if source and type(ach) == "table" and ach[source] ~= nil then
		return true
	end
	local a = type(p.Account) == "table" and p.Account
	local level = a and AccountData.LevelFor(tonumber(a.XP) or 0) or 1
	if AccountData.Has(level, "Title", name) then
		return true
	end
	local t = MetaUI.Features(p).Titles
	return type(t) == "table" and type(t.Owned) == "table" and t.Owned[MetaData.TitleId(name)] == true
end

local function ownsPlate(p: { [string]: any }?, id: string): boolean
	local c = MetaUI.Features(p).Cosmetics
	return type(c) == "table" and type(c.Owned) == "table" and c.Owned[id] == true
end

local function wornPlate(p: { [string]: any }?): string
	local c = MetaUI.Features(p).Cosmetics
	local id = type(c) == "table" and type(c.Equipped) == "table" and c.Equipped.Nameplate or ""
	return type(id) == "string" and id or ""
end

-- "12 titles earned" for the MORE row.
function MenuTitles.Summary(p: { [string]: any }?): string
	local n = 0
	for _, e in ipairs(CosmeticData.OfKind("Title")) do
		if MenuTitles.Owns(p, e.Name) then
			n += 1
		end
	end
	local worn = p and p.Title or ""
	return (worn ~= "" and ("Wearing " .. worn) or "No title worn") .. string.format(" · %d earned", n)
end

function MenuTitles.Build(screen: Frame, ctx: { [string]: any })
	local host = ctx.Host
	local ui = MetaUI.Screen(screen, ctx, "TITLES")
	local plate = new("Frame", { Name = "Plate", BackgroundColor3 = C.Panel, BackgroundTransparency = 0, AnchorPoint = Vector2.new(0.5, 0) }, ui.Head)
	UIKit.corner(plate, Theme.Radius.M)
	local plateStroke = UIKit.stroke(plate, C.PanelEdge, 3, 0)
	local plateName = MetaUI.Line(plate, "Label", Players.LocalPlayer.DisplayName, 18, { Name = "PlateName", TextXAlignment = Enum.TextXAlignment.Center, Position = UDim2.fromOffset(8, 4), Size = UDim2.new(1, -16, 0, TS(18) + 4) })
	local plateTitle = MetaUI.Line(plate, "Small", "", 14, { Name = "PlateTitle", TextXAlignment = Enum.TextXAlignment.Center, TextColor3 = C.BlueDeep, Position = UDim2.fromOffset(8, 6 + TS(18)), Size = UDim2.new(1, -16, 0, TS(14) + 4) })
	UIKit.list(ui.Body, { Padding = UDim.new(0, 6) })

	local function fill()
		local p = ctx.Profile()
		local worn = p and p.Title or ""
		local wornId = wornPlate(p)
		plateName.Text = Players.LocalPlayer.DisplayName
		plateTitle.Text = worn ~= "" and worn or "No title worn"
		local def = MetaData.NameplateById[wornId]
		plateStroke.Color = def and def.Color or C.PanelEdge
		MetaUI.Clear(ui.Body)
		local order = 0
		local function section(str: string)
			order += 1
			local l = UIKit.SectionLabel(ui.Body, str)
			l.LayoutOrder = order
		end
		local plates = Config.FeatureOn("Store") and MetaData.Nameplates or {}
		if #plates > 0 then
			section("NAMEPLATE FRAMES")
		end
		for _, n in ipairs(plates) do
			order += 1
			local have = ownsPlate(p, n.Id)
			local isWorn = wornId == n.Id
			local row = MetaUI.Row(ui.Body, {
				Name = n.Id,
				Order = order,
				Icon = "crown",
				Title = string.upper(n.Name) .. " FRAME",
				Sub = have and (isWorn and "Worn" or "Earned") or n.How,
				Height = 58,
				Action = have and {
					Title = isWorn and "WORN" or "WEAR",
					Kind = isWorn and "Selected" or "Secondary",
					OnClick = function()
						Remotes.Get("StoreEquip"):FireServer("Nameplate", isWorn and "" or n.Id)
					end,
				} or nil,
			})
			row.SetDim(not have)
			row.SetDone(have and isWorn)
			local holder = row.Icon
			for _, d in ipairs(holder:GetDescendants()) do
				if d:IsA("GuiObject") and d.BackgroundTransparency < 1 then
					d.BackgroundColor3 = n.Color
				end
			end
		end
		section("TITLES")
		local list = CosmeticData.OfKind("Title")
		local earned, locked = {}, {}
		for _, e in ipairs(list) do
			local owned = MenuTitles.Owns(p, e.Name)
			-- a title of a held feature (Starter Bundle, invites, group) can't be earned while its
			-- switch is off: hidden, unless the player already owns it
			local feature = (e :: any).Feature
			if owned or feature == nil or Config.FeatureOn(feature) then
				table.insert(owned and earned or locked, e)
			end
		end
		for _, group in ipairs({ earned, locked }) do
			for _, e in ipairs(group) do
				order += 1
				local have = group == earned
				local isWorn = worn == e.Name
				local row = MetaUI.Row(ui.Body, {
					Name = e.Id,
					Order = order,
					Icon = "medal",
					Title = string.upper(e.Name),
					Sub = have and (isWorn and "Worn" or "Earned") or (e.Condition or "Earned by play"),
					Height = 58,
					Action = have and {
						Title = isWorn and "WORN" or "WEAR",
						Kind = isWorn and "Selected" or "Secondary",
						OnClick = function()
							Remotes.Get("EquipCosmetic"):FireServer("Title", isWorn and "" or e.Name)
						end,
					} or nil,
				})
				row.SetDim(not have)
			row.SetDone(have and isWorn)
			end
		end
	end

	local function layout(v: Vector2, portrait: boolean, ins: { [string]: number })
		local plateH = TS(18) + TS(14) + 16
		ui.Layout(v, portrait, ins, plateH, 0)
		local w = ui.Head.Size.X.Offset
		local pw = math.min(w, 360)
		plate.Position = UDim2.new(0.5, 0, 0, 0)
		plate.Size = UDim2.fromOffset(pw, plateH)
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

return MenuTitles
