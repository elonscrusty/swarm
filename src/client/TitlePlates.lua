--[[
	TitlePlates.lua (feature 23, Config.Features.Titles; docs/features/META.md)
	A small plate over each hero that wears a title: the player's name and, under it, the
	worn title (player attribute "Title", published by MetaService). It shows in the lobby
	and in runs, for every player, within PlateRange. With the Store on, the plate wears
	the player's store / earned nameplate frame (StoreFx.DecoratePlate) and StoreFx skips
	its own plate for that player, so there is only one. Looks only: client-side GUI.
	With the switch off, Init does nothing.
]]

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")

local Shared = game:GetService("ReplicatedStorage"):WaitForChild("Shared")
local Config = require(Shared:WaitForChild("Config"))
local UIKit = require(script.Parent.UIKit)
local StoreFx = require(script.Parent.StoreFx)

local TitlePlates = {}

local new = UIKit.new
local PLATE_RANGE = 70
local folder: Folder? = nil
local plates: { [Player]: { Gui: BillboardGui, Key: string } } = {}

local function rootOf(who: Player): BasePart?
	local char = who.Character
	local root = char and char:FindFirstChild("HumanoidRootPart")
	return (root and root:IsA("BasePart")) and root or nil
end

local function drop(who: Player)
	local p = plates[who]
	if p then
		p.Gui:Destroy()
		plates[who] = nil
	end
end

local function build(who: Player, root: BasePart, title: string)
	local gui = new("BillboardGui", {
		Name = "TitlePlate_" .. who.Name,
		Adornee = root,
		Size = UDim2.fromOffset(190, 46),
		StudsOffsetWorldSpace = Vector3.new(0, 2.6, 0),
		AlwaysOnTop = false,
		MaxDistance = PLATE_RANGE,
		ResetOnSpawn = false,
		LightInfluence = 0,
	}, folder)
	local plate = new("Frame", {
		Name = "Plate",
		AnchorPoint = Vector2.new(0.5, 0),
		Position = UDim2.fromScale(0.5, 0),
		Size = UDim2.new(1, -16, 0, 40),
		BackgroundColor3 = Color3.fromRGB(28, 24, 18),
		BackgroundTransparency = 0.25,
		BorderSizePixel = 0,
	}, gui)
	UIKit.corner(plate, 12)
	-- a star before the name for members of the game's Roblox group (GroupBonus.lua sets
	-- GroupMember on the server; Config.Features.GroupBonus with a group id)
	local star = Config.FeatureOn("GroupBonus") and ((Config :: any).Group.Id or 0) ~= 0 and who:GetAttribute("GroupMember") == true
	UIKit.text(plate, "Label", (star and "\u{2605} " or "") .. who.DisplayName, {
		Name = "Name",
		Position = UDim2.fromOffset(6, 1),
		Size = UDim2.new(1, -12, 0, 20),
		TextXAlignment = Enum.TextXAlignment.Center,
		TextColor3 = Color3.fromRGB(245, 240, 228),
		TextTruncate = Enum.TextTruncate.AtEnd,
		ZIndex = 2,
	}, 14)
	UIKit.text(plate, "Small", title, {
		Name = "Title",
		Position = UDim2.fromOffset(6, 20),
		Size = UDim2.new(1, -12, 0, 18),
		TextXAlignment = Enum.TextXAlignment.Center,
		TextColor3 = Color3.fromRGB(255, 214, 120),
		TextTruncate = Enum.TextTruncate.AtEnd,
		ZIndex = 2,
	}, 12)
	pcall(StoreFx.DecoratePlate, plate, who) -- the worn frame / Supporter glow (Store on)
	return gui
end

local function update(who: Player)
	local title = who:GetAttribute("Title")
	local root = rootOf(who)
	-- never a plate over your own hero (owner: it covered the middle of the screen)
	local own = who == Players.LocalPlayer
	if not Config.FeatureOn("Titles") or type(title) ~= "string" or title == "" or not root or own then
		drop(who)
		return
	end
	local key = title .. "|" .. tostring(who:GetAttribute("CosPlate") or "") .. "|" .. tostring(who:GetAttribute("Supporter")) .. "|" .. tostring(who:GetAttribute("GroupMember")) .. "|" .. root:GetFullName()
	local p = plates[who]
	if p and p.Key == key and p.Gui.Adornee == root then
		return
	end
	drop(who)
	plates[who] = { Gui = build(who, root, title), Key = key }
end

function TitlePlates.Init()
	if not Config.FeatureOn("Titles") then
		return
	end
	local pg = Players.LocalPlayer:WaitForChild("PlayerGui")
	local f = Instance.new("Folder")
	f.Name = "TitlePlates"
	f.Parent = pg
	folder = f
	Players.PlayerRemoving:Connect(drop)
	local timer = 0
	RunService.Heartbeat:Connect(function(dt)
		timer += dt
		if timer < 0.5 then
			return
		end
		timer = 0
		for _, who in ipairs(Players:GetPlayers()) do
			update(who)
		end
	end)
end

return TitlePlates
