--[[
	DevPanel.lua
	The "DEV" button and its tools panel for testing. Shown in Studio, and in live servers to
	developers: the server (DevAccess.lua: DevAllowlist UserIds, or the creator when
	Config.Dev.ShowInLiveGame is on) marks them with the player attribute DevAccess, which
	may arrive after this module starts, so the button is built when it shows up. The GUI
	does not reset on respawn, so the button stays through runs, deaths and menus. Normal
	players never see it. Config.Dev.Enabled = false removes it everywhere.

	The DEV button opens / closes a tabbed panel (the x in its header folds it back to the
	button):
	  SAVE     Start solo now, UNLOCK EVERYTHING, gold, account levels, damage numbers,
	           RESET PROGRESS (tap twice to confirm), Bug inbox (DevInbox; the server re-checks access)
	  RUN      INVINCIBLE ON/OFF (no damage from any source; the run becomes a test run and
	           the DEV button shows a red INVINCIBLE badge), levels, run gold, damage
	           numbers, teleport to portal, portal boss, next stage
	  MOBS     any stage boss (the portal summons it), 5 of an enemy type / 1 elite
	  ITEMS    any item, 3 random items, any weapon at max level, all weapons, evolve all

	The buttons are only shortcuts: the server (RunManager "DevCommand" → DevTools.lua)
	checks isDev again and re-validates every argument.
]]

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")

local Shared = game:GetService("ReplicatedStorage"):WaitForChild("Shared")
local Config = require(Shared:WaitForChild("Config"))
local Remotes = require(Shared:WaitForChild("Remotes"))
local Theme = require(Shared:WaitForChild("Theme"))
local BossData = require(Shared:WaitForChild("BossData"))
local EnemyData = require(Shared:WaitForChild("EnemyData"))
local ItemData = require(Shared:WaitForChild("ItemData"))
local WeaponData = require(Shared:WaitForChild("WeaponData"))
local UIKit = require(script.Parent.UIKit)
local UIAnim = require(script.Parent.UIAnim)
local DevInbox = require(script.Parent.DevInbox)

local DevPanel = {}

local player = Players.LocalPlayer
local P, C = Theme.Palette, Theme.Color
local new, text = UIKit.new, UIKit.text

-- the enemy types the server lets the panel spawn (DevTools.Enemies)
local ENEMIES = { "Slime", "Bat", "Skeleton", "Ghost", "Brute", "Bomber", "Spitter", "Burrower", "Healer", "Nest" }
local TABS = {
	{ Id = "Profile", Title = "Save" },
	{ Id = "Run", Title = "Run" },
	{ Id = "Spawn", Title = "Mobs" },
	{ Id = "Items", Title = "Items" },
}
local BUTTON_H = 40

local panel: Frame? = nil
local toggle: GuiObject? = nil
local pages: { [string]: ScrollingFrame } = {}
local note: TextLabel? = nil
local refreshers: { () -> () } = {}

-- Whether to draw the DEV button: Studio, or the server's DevAccess mark. Only a hint:
-- the server checks every command again (DevAccess.IsDev).
function DevPanel.IsDev(): boolean
	if not Config.Dev.Enabled then
		return false
	end
	return RunService:IsStudio() or player:GetAttribute("DevAccess") == true
end

local function send(command: string, arg: any?)
	Remotes.Get("DevCommand"):FireServer(command, arg)
end

local function refresh()
	local inRun = player:GetAttribute("InRun") == true
	if note then
		note.Text = inRun and "In a run: RUN, MOBS and ITEMS work now." or "Lobby: the SAVE tab works now; the rest in a run."
	end
	for _, fn in ipairs(refreshers) do
		fn()
	end
end

-- A titled block of buttons in a page (two columns, or `cols`).
local function section(page: Instance, title: string, order: number, cols: number?): Frame
	local f = new("Frame", { Name = title, BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 0), AutomaticSize = Enum.AutomaticSize.Y, LayoutOrder = order }, page)
	text(f, "Caption", UIKit.track(title), { Name = "Title", Size = UDim2.new(1, 0, 0, 18), TextColor3 = P.crimson_300 })
	local grid = new("Frame", { Name = "Grid", BackgroundTransparency = 1, Position = UDim2.fromOffset(0, 22), Size = UDim2.new(1, 0, 0, 0), AutomaticSize = Enum.AutomaticSize.Y }, f)
	local n = cols or 2
	new("UIGridLayout", {
		CellSize = UDim2.new(1 / n, -math.ceil(6 * (n - 1) / n), 0, BUTTON_H),
		CellPadding = UDim2.fromOffset(6, 6),
		SortOrder = Enum.SortOrder.LayoutOrder,
	}, grid)
	new("UIPadding", { PaddingBottom = UDim.new(0, 2) }, f)
	return grid
end

local function button(grid: Instance, title: string, order: number, onClick: () -> (), kind: string?): UIKit.Button
	return UIKit.Button(grid, {
		Kind = kind or "Secondary",
		Title = title,
		TitleStyle = "Label",
		LayoutOrder = order,
		Shadow = false,
		Radius = Theme.Radius.S,
		Align = "Center",
		OnClick = onClick,
	})
end

local function page(parent: Instance, id: string): ScrollingFrame
	local s = new("ScrollingFrame", {
		Name = id,
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		ScrollBarThickness = 4,
		ScrollBarImageColor3 = P.crimson_400,
		AutomaticCanvasSize = Enum.AutomaticSize.Y,
		CanvasSize = UDim2.new(),
		ScrollingDirection = Enum.ScrollingDirection.Y,
		Size = UDim2.fromScale(1, 1),
		Visible = false,
	}, parent)
	UIKit.padding(s, 2, 8, 2, 0)
	UIKit.list(s, { Padding = UDim.new(0, 6) })
	pages[id] = s
	return s
end

local function buildProfile(p: Instance)
	local g = section(p, "Quick", 1, 1)
	button(g, "Start solo now", 1, function()
		send("StartSolo")
	end)
	button(g, "UNLOCK EVERYTHING", 2, function()
		send("UnlockAll")
	end, "Primary")
	button(g, "Bug inbox", 3, function()
		if panel then
			panel.Visible = false
		end
		DevInbox.Open()
	end)
	g = section(p, "Gold & levels", 2)
	button(g, "+1,000 gold", 1, function()
		send("LobbyGold", 1000)
	end)
	button(g, "+100,000 gold", 2, function()
		send("LobbyGold", 100000)
	end)
	button(g, "+1 account level", 3, function()
		send("AccountLevels", 1)
	end)
	button(g, "+10 account levels", 4, function()
		send("AccountLevels", 10)
	end)
	g = section(p, "Settings", 3, 1)
	local dmg = button(g, "", 1, function()
		send("DamageNumbers")
	end)
	table.insert(refreshers, function()
		dmg.SetText("Damage numbers: " .. (player:GetAttribute("DamageNumbers") == true and "ON" or "OFF"))
	end)
	player:GetAttributeChangedSignal("DamageNumbers"):Connect(refresh)
	g = section(p, "Danger zone", 4, 1)
	local armed = 0
	local reset: UIKit.Button
	reset = button(g, "Reset progress", 1, function()
		if os.clock() < armed then
			armed = 0
			reset.SetText("Reset progress")
			send("ResetProgress", "CONFIRM")
		else
			armed = os.clock() + 4
			reset.SetText("Tap again to RESET everything")
			task.delay(4.1, function()
				if os.clock() >= armed then
					reset.SetText("Reset progress")
				end
			end)
		end
	end)
end

local function buildRun(p: Instance)
	local g = section(p, "Player", 1)
	button(g, "+1 level", 1, function()
		send("AddLevels", 1)
	end)
	button(g, "+" .. Config.Dev.AddLevels .. " levels", 2, function()
		send("AddLevels", Config.Dev.AddLevels)
	end)
	button(g, "+300 gold", 3, function()
		send("AddGold", 300)
	end)
	button(g, "+5,000 gold", 4, function()
		send("AddGold", 5000)
	end)
	local god = button(g, "", 5, function()
		send("God")
	end)
	local dmg = button(g, "", 6, function()
		send("DamageNumbers")
	end)
	table.insert(refreshers, function()
		local on = player:GetAttribute("DevGod") == true
		god.SetText("Invincible: " .. (on and "ON" or "OFF"))
		god.SetSelected(on)
		dmg.SetText("Dmg numbers: " .. (player:GetAttribute("DamageNumbers") == true and "ON" or "OFF"))
	end)
	player:GetAttributeChangedSignal("DevGod"):Connect(refresh)
	g = section(p, "Stage", 2)
	button(g, "Teleport to portal", 1, function()
		send("TeleportToPortal")
	end)
	button(g, "Portal boss now", 2, function()
		send("SpawnPortalBoss")
	end)
	button(g, "Next stage", 3, function()
		send("NextStage")
	end, "Primary")
end

local function buildSpawn(p: Instance)
	local g = section(p, "Boss (the portal summons it)", 1)
	for i, id in ipairs(BossData.Rotation) do
		local def = BossData.Bosses[id]
		button(g, def and def.DisplayName or id, i, function()
			send("SpawnBoss", id)
		end)
	end
	button(g, "Normal rotation", #BossData.Rotation + 1, function()
		send("BossRotation")
	end, "Ghost")
	g = section(p, "Enemies (5 each)", 2)
	for i, id in ipairs(ENEMIES) do
		local def = EnemyData.Enemies[id]
		button(g, def and def.DisplayName or id, i, function()
			send("SpawnEnemy", id)
		end)
	end
	g = section(p, "Elites (1 each)", 3)
	for i, id in ipairs(ENEMIES) do
		local def = EnemyData.Enemies[id]
		button(g, "Elite " .. (def and def.DisplayName or id), i, function()
			send("SpawnElite", id)
		end)
	end
end

local function buildItems(p: Instance)
	local g = section(p, "Weapons", 1)
	button(g, "All weapons max rank", 1, function()
		send("MaxWeapons")
	end, "Primary")
	button(g, "Evolve all", 2, function()
		send("EvolveWeapons")
	end)
	g = section(p, "One weapon (max rank)", 2)
	for i, id in ipairs(WeaponData.Order) do
		local def = WeaponData.Weapons[id]
		button(g, def and def.Name or id, i, function()
			send("GiveWeapon", id)
		end)
	end
	g = section(p, "Items", 3)
	button(g, "+3 random items", 0, function()
		send("GiveItems")
	end, "Primary")
	for i, id in ipairs(ItemData.Order) do
		local def = ItemData.Items[id]
		button(g, def and def.Name or id, i, function()
			send("GiveItem", id)
		end)
	end
end

local tabs: UIKit.Tabs? = nil

local function showTab(id: string)
	for name, pg in pairs(pages) do
		pg.Visible = name == id
	end
	if tabs and tabs.Selected() ~= id then
		tabs.Select(id)
	end
end

local built = false

local function build(root: Instance, host: { [string]: any }?)
	if built then
		return
	end
	built = true
	local t = UIKit.Button(root, {
		Kind = "Secondary",
		Title = "DEV",
		Name = "DevButton",
		Size = UDim2.fromOffset(88, 48),
		ZIndex = Theme.Z.Dev,
		Align = "Center",
		OnClick = function()
			if panel then
				panel.Visible = not panel.Visible
				if panel.Visible then
					refresh()
					UIAnim.Pop(panel, 0, 0.9)
				end
			end
		end,
	})
	local st = t.Face:FindFirstChildOfClass("UIStroke")
	if st then
		st.Color = P.crimson_400
		st.Transparency = 0.1
	end
	toggle = t.Instance

	local holder, face = UIKit.Surface(root, { Name = "DevPanel", Size = UDim2.fromOffset(360, 520), Visible = false, ZIndex = Theme.Z.Dev, Edge = P.crimson_400, EdgeTransparency = 0.2, Transparency = 0.04 })
	UIKit.pad(face, 10)
	-- header: title + fold
	local head = new("Frame", { Name = "Header", BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 30) }, face)
	text(head, "Label", UIKit.track("Dev tools"), { Size = UDim2.new(1, -44, 1, 0), TextColor3 = P.crimson_300 })
	UIKit.Button(head, {
		Kind = "Ghost",
		Icon = "close",
		IconSize = 18,
		Name = "Fold",
		AnchorPoint = Vector2.new(1, 0),
		Position = UDim2.fromScale(1, 0),
		Size = UDim2.fromOffset(40, 30),
		Shadow = false,
		Align = "Center",
		OnClick = function()
			holder.Visible = false
		end,
	})
	note = text(face, "Small", "", { Name = "Note", Position = UDim2.fromOffset(0, 32), Size = UDim2.new(1, 0, 0, 18), TextColor3 = C.TextMuted, TextTruncate = Enum.TextTruncate.AtEnd })
	tabs = UIKit.Tabs(face, TABS, showTab, { Position = UDim2.fromOffset(0, 54) })
	local top = 54 + Theme.Size.TapMin + 8
	local body = new("Frame", { Name = "Body", BackgroundTransparency = 1, Position = UDim2.fromOffset(0, top), Size = UDim2.new(1, 0, 1, -top) }, face)
	DevInbox.ClaimButton()
	buildProfile(page(body, "Profile"))
	buildRun(page(body, "Run"))
	buildSpawn(page(body, "Spawn"))
	buildItems(page(body, "Items"))
	panel = holder

	-- bottom right in landscape (clear of the menu columns and the ability bar), from the
	-- top in portrait; never taller than the screen allows
	local function layout()
		if not host or not toggle or not panel then
			return
		end
		local v: Vector2 = host.VirtualSize()
		local portrait: boolean = host.IsPortrait()
		local ins = host.Insets and host.Insets() or { Top = 0 }
		local M = UIKit.IsCompact() and Theme.Layout.MarginCompact or Theme.Layout.Margin
		local w = math.min(380, v.X - 2 * M)
		local topY = math.max((ins.Top or 0) + 8, 12)
		if portrait then
			local ty = math.floor(v.Y * 0.4)
			toggle.AnchorPoint = Vector2.new(0, 0)
			toggle.Position = UDim2.fromOffset(M, ty)
			panel.AnchorPoint = Vector2.new(0, 0)
			panel.Position = UDim2.fromOffset(M, ty + 56)
			panel.Size = UDim2.fromOffset(w, math.min(600, v.Y - ty - 56 - M))
		else
			toggle.AnchorPoint = Vector2.new(1, 1)
			toggle.Position = UDim2.fromOffset(v.X - M, v.Y - M)
			panel.AnchorPoint = Vector2.new(1, 1)
			panel.Position = UDim2.fromOffset(v.X - M, v.Y - M - 56)
			panel.Size = UDim2.fromOffset(w, math.min(600, v.Y - M - 56 - topY))
		end
	end
	if host then
		host.OnRelayout(layout)
		layout()
	end
	player:GetAttributeChangedSignal("InRun"):Connect(function()
		showTab(player:GetAttribute("InRun") == true and "Run" or "Profile")
		refresh()
	end)
	showTab(player:GetAttribute("InRun") == true and "Run" or "Profile")
	refresh()

	-- INVINCIBLE badge on the DEV button while god mode is on (visible with the panel shut)
	local badge = new("TextLabel", {
		Name = "GodBadge",
		AnchorPoint = Vector2.new(0.5, 1),
		Position = UDim2.new(0.5, 0, 0, -4),
		Size = UDim2.fromOffset(104, 20),
		BackgroundColor3 = P.crimson_500,
		Text = "INVINCIBLE",
		TextColor3 = Color3.new(1, 1, 1),
		FontFace = Theme.Font.Label,
		TextSize = 13,
		ZIndex = Theme.Z.Dev + 2,
		Visible = false,
	}, t.Instance)
	new("UICorner", { CornerRadius = UDim.new(0, 6) }, badge)
	local function syncBadge()
		badge.Visible = player:GetAttribute("DevGod") == true
	end
	player:GetAttributeChangedSignal("DevGod"):Connect(syncBadge)
	syncBadge()
end

function DevPanel.Init(root: Instance, host: { [string]: any }?)
	if not Config.Dev.Enabled then
		return
	end
	if DevPanel.IsDev() then
		build(root, host)
		return
	end
	-- live servers: the server's DevAccess mark can land after the GUI is built
	local conn: RBXScriptConnection? = nil
	conn = player:GetAttributeChangedSignal("DevAccess"):Connect(function()
		if DevPanel.IsDev() then
			if conn then
				conn:Disconnect()
			end
			build(root, host)
		end
	end)
end

-- Opens the panel on a tab (preview scenes).
function DevPanel.Open(tab: string?)
	if panel then
		panel.Visible = true
		if tab and pages[tab] then
			showTab(tab)
		end
		refresh()
	end
end

return DevPanel
