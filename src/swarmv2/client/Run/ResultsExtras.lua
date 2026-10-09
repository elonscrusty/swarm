--!nonstrict
--[[
	SwarmV2/Run/ResultsExtras.lua  (StarterPlayerScripts.SwarmV2Client.Run.ResultsExtras)
	OWNER: stream F (run UI).

	The parts of the results screen the continuation brief adds, drawn from the RunResult payload only
	(the client never calculates a reward):

	  outcome line    Outcome "Victory" | "Defeat" | "Left" as the server confirmed it, with what that means
	                  ("Left early: no victory bonus")
	  duration        Duration (seconds); the existing Time tile shows it
	  RUN STATS       Stats (or RunStats): real tracked counters (Kills, Elites, Chests, Dashes, Revives,
	                  Distance, Bosses, XP ...), only the ones the server sent
	  NEW UNLOCKS     NewUnlocks: class ids (or { Id, Name }) the settlement just earned, named
	  SAVE STATUS     SaveStatus "Pending" | "Saved" | "Failed" (payload, then the player attribute
	                  RunSaveStatus as it changes): "Saving your progress..." -> "Progress saved" or the
	                  recovery message. Absent = no line at all: the screen never claims a save it was not told.

	UIBuilder builds it once (Build) and calls Fill with every RunResult and Layout from its own layout
	pass. Missing fields hide their block.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local CharacterData = require(Shared:WaitForChild("CharacterData"))
local RunConfig = require(ReplicatedStorage:WaitForChild("SwarmV2"):WaitForChild("Run"):WaitForChild("RunConfig"))
local Client = script.Parent.Parent.Parent:WaitForChild("SwarmClient")
local UIKit = require(Client:WaitForChild("UIKit"))
local Icons = require(Client:WaitForChild("Icons"))
local RunTheme = require(script.Parent.RunTheme)
local W = require(script.Parent.RunWidgets)

local ResultsExtras = {}

local CFG = RunConfig.UI.Results
local player = Players.LocalPlayer
local new = UIKit.new

local ui: { [string]: any } = {}
local data: { [string]: any }? = nil
local statusKey: string? = nil

local STAT_LABELS = {
	Kills = "Kills",
	Elites = "Elites",
	Chests = "Chests opened",
	Dashes = "Dashes",
	Revives = "Revives",
	Distance = "Distance",
	Bosses = "Bosses",
	XP = "XP earned",
	BestSurvive = "Best survive",
	CloseKills = "Close kills",
	MostWeapons = "Weapons held",
}
local STAT_ORDER = { "Kills", "Elites", "Bosses", "Chests", "Revives", "Dashes", "CloseKills", "MostWeapons", "XP", "Distance", "BestSurvive" }

local function pretty(id: string): string
	local s = string.gsub(id, "_", " ")
	return (string.gsub(s, "(%a)([%w]*)", function(a, b)
		return string.upper(a) .. b
	end))
end

-- The display name of a class id the server listed.
function ResultsExtras.UnlockName(entry: any): string
	if type(entry) == "table" then
		return tostring(entry.Name or entry.DisplayName or pretty(tostring(entry.Id or "?")))
	end
	local id = tostring(entry)
	local def = CharacterData.Characters[id]
	return def and def.Name or pretty(id)
end

local function formatStat(key: string, v: number): string
	if key == "BestSurvive" then
		return UIKit.formatTime(v)
	elseif key == "Distance" then
		return UIKit.formatNumber(math.floor(v)) .. " studs"
	end
	return UIKit.formatNumber(math.floor(v + 0.5))
end

-- The ordered { label, value } stats the server sent (numbers only).
function ResultsExtras.StatRows(stats: any): { { string } }
	local rows = {}
	if type(stats) ~= "table" then
		return rows
	end
	local seen = {}
	local function add(key: string)
		local v = stats[key]
		if type(v) == "number" and v == v and v >= 0 and v < math.huge and not seen[key] then
			seen[key] = true
			table.insert(rows, { STAT_LABELS[key] or pretty(key), formatStat(key, v) })
		end
	end
	for _, key in ipairs(STAT_ORDER) do
		add(key)
	end
	local rest = {}
	for key in pairs(stats) do
		if type(key) == "string" and not seen[key] then
			table.insert(rest, key)
		end
	end
	table.sort(rest)
	for _, key in ipairs(rest) do
		add(key)
	end
	return rows
end

-- "Victory" | "Defeat" | "Left" -> (title line, meaning) or nil
function ResultsExtras.OutcomeText(outcome: any): (string?, string?)
	if outcome == "Victory" then
		return "VICTORY", "The basin is safe. Confirmed by the server."
	elseif outcome == "Defeat" then
		return "DEFEAT", "No hero was left standing. Confirmed by the server."
	elseif outcome == "Left" then
		return "YOU LEFT THE RUN", "Left early, so no victory bonus. Confirmed by the server."
	end
	return nil, nil
end

------------------------------------------------------------------------------------------
-- Build
------------------------------------------------------------------------------------------

--[[
	body: the results ScrollingFrame (its UIListLayout sorts by LayoutOrder: the outcome line -1, new unlocks
	4, run stats 8); content: the modal's content frame (the save line sits in it, order 6, above the buttons).
]]
function ResultsExtras.Build(body: Instance, content: Instance)
	-- outcome line
	local outcome = new("Frame", { Name = "Outcome", BackgroundColor3 = RunTheme.Navy, BorderSizePixel = 0, LayoutOrder = -1, Size = UDim2.new(1, 0, 0, 44), Visible = false, Active = false }, body)
	UIKit.corner(outcome, 10)
	UIKit.stroke(outcome, RunTheme.NavyEdge, 2, 0)
	ui.Outcome = outcome
	ui.OutcomeTitle = W.Text(outcome, "", { Name = "Title", Size = 18, Font = "Heading", Position = UDim2.fromOffset(12, 3), Box = UDim2.new(1, -24, 0, 22), Fit = 12, Color = RunTheme.Gold })
	ui.OutcomeLine = W.Text(outcome, "", { Name = "Line", Size = 14, Font = "Label", Position = UDim2.fromOffset(12, 24), Box = UDim2.new(1, -24, 0, 18), Fit = 10, Color = RunTheme.CreamMuted })
	-- new unlocks
	local unlocks = new("Frame", { Name = "NewUnlocks", BackgroundColor3 = RunTheme.Navy, BorderSizePixel = 0, LayoutOrder = 4, Size = UDim2.new(1, 0, 0, 56), Visible = false, Active = false }, body)
	UIKit.corner(unlocks, 10)
	UIKit.stroke(unlocks, RunTheme.Gold, 2.5, 0)
	ui.Unlocks = unlocks
	ui.UnlockIcon = Icons.Draw(unlocks, "crown", { Size = 30, Color = RunTheme.Gold, Back = RunTheme.Navy, AnchorPoint = Vector2.new(0, 0.5), Position = UDim2.new(0, 12, 0.5, 0) })
	ui.UnlockTitle = W.Text(unlocks, "NEW UNLOCK", { Name = "Title", Size = 14, Font = "Label", Position = UDim2.fromOffset(52, 5), Box = UDim2.new(1, -62, 0, 18), Fit = 10, Color = RunTheme.Gold })
	ui.UnlockNames = W.Text(unlocks, "", { Name = "Names", Size = 18, Font = "Heading", Position = UDim2.fromOffset(52, 24), Box = UDim2.new(1, -62, 0, 26), Fit = 11, Color = RunTheme.Cream })
	-- run stats
	local stats = new("Frame", { Name = "RunStats", BackgroundColor3 = RunTheme.Navy, BorderSizePixel = 0, LayoutOrder = 8, Size = UDim2.new(1, 0, 0, 80), Visible = false, Active = false }, body)
	UIKit.corner(stats, 10)
	UIKit.stroke(stats, RunTheme.NavyEdge, 2, 0)
	ui.Stats = stats
	ui.StatsTitle = W.Text(stats, "RUN STATS", { Name = "Title", Size = 14, Font = "Label", Position = UDim2.fromOffset(12, 4), Box = UDim2.new(1, -24, 0, 18), Fit = 10, Color = RunTheme.CreamMuted })
	ui.StatsGrid = new("Frame", { Name = "Grid", BackgroundTransparency = 1, Position = UDim2.fromOffset(8, 24), Size = UDim2.new(1, -16, 1, -28), Active = false }, stats)
	ui.StatsList = UIKit.list(ui.StatsGrid, { FillDirection = Enum.FillDirection.Horizontal, HorizontalAlignment = Enum.HorizontalAlignment.Left, Wraps = true, Padding = UDim.new(0, 6) })
	-- save status (pinned above the buttons)
	local save = new("Frame", { Name = "SaveStatus", BackgroundColor3 = RunTheme.Navy, BorderSizePixel = 0, LayoutOrder = 6, Size = UDim2.new(1, 0, 0, 34), Visible = false, Active = false }, content)
	UIKit.corner(save, 10)
	UIKit.stroke(save, RunTheme.NavyEdge, 2, 0)
	ui.Save = save
	ui.SaveIcon = new("Frame", { Name = "Icon", BackgroundTransparency = 1, AnchorPoint = Vector2.new(0, 0.5), Position = UDim2.new(0, 10, 0.5, 0), Size = UDim2.fromOffset(22, 22), Active = false }, save)
	ui.SaveText = W.Text(save, "", { Name = "Text", Size = 16, Font = "Strong", Position = UDim2.fromOffset(40, 0), Box = UDim2.new(1, -50, 1, 0), Fit = 11, Color = RunTheme.Cream })
	player:GetAttributeChangedSignal("RunSaveStatus"):Connect(function()
		ResultsExtras.RefreshSave()
	end)
end

------------------------------------------------------------------------------------------
-- Fill
------------------------------------------------------------------------------------------

local SAVE_STYLE = {
	Pending = { Icon = "hourglass", Color = "CreamMuted" },
	Saved = { Icon = "check", Color = "Good" },
	Failed = { Icon = "warning", Color = "Danger" },
}

-- The save line: payload SaveStatus, then the attribute RunSaveStatus as it changes.
function ResultsExtras.RefreshSave()
	if not ui.Save then
		return
	end
	local status = player:GetAttribute("RunSaveStatus")
	if type(status) ~= "string" and data then
		status = data.SaveStatus
		if status == nil and type(data.Saved) == "boolean" then
			status = data.Saved and "Saved" or "Pending"
		end
	end
	local style = type(status) == "string" and SAVE_STYLE[status] or nil
	ui.Save.Visible = style ~= nil
	if not style then
		statusKey = nil
		return
	end
	if statusKey ~= status then
		statusKey = status
		for _, c in ipairs(ui.SaveIcon:GetChildren()) do
			c:Destroy()
		end
		Icons.Draw(ui.SaveIcon, style.Icon, { Size = 22, Color = RunTheme[style.Color], Back = RunTheme.Navy })
		ui.SaveText.Text = CFG.SaveLabels[status] or status
		ui.SaveText.TextColor3 = RunTheme[style.Color]
		ui.Save.UIStroke.Color = status == "Failed" and RunTheme.Danger or RunTheme.NavyEdge
	end
end

function ResultsExtras.Fill(payload: any)
	data = payload
	if not ui.Outcome then
		return
	end
	-- outcome
	local title, line = ResultsExtras.OutcomeText(payload.Outcome)
	ui.Outcome.Visible = title ~= nil
	if title then
		ui.OutcomeTitle.Text = title
		ui.OutcomeLine.Text = line
		ui.OutcomeTitle.TextColor3 = payload.Outcome == "Defeat" and RunTheme.Danger or RunTheme.Gold
	end
	-- stats
	local rows = ResultsExtras.StatRows(payload.Stats or payload.RunStats)
	for _, c in ipairs(ui.StatsGrid:GetChildren()) do
		if c:IsA("GuiObject") then
			c:Destroy()
		end
	end
	ui.Stats.Visible = #rows > 0
	ui.StatRows = rows
	for i, row in ipairs(rows) do
		local chip = new("Frame", { Name = "Stat", BackgroundColor3 = RunTheme.NavyRaised, BorderSizePixel = 0, Size = UDim2.fromOffset(120, 40), LayoutOrder = i, Active = false }, ui.StatsGrid)
		UIKit.corner(chip, 8)
		W.Text(chip, row[2], { Name = "Value", Size = 18, Font = "Number", Align = "Center", Position = UDim2.fromOffset(4, 0), Box = UDim2.new(1, -8, 0, 22), Fit = 11, Color = RunTheme.Cream })
		W.Text(chip, row[1], { Name = "Label", Size = 12, Font = "Label", Align = "Center", Position = UDim2.fromOffset(4, 21), Box = UDim2.new(1, -8, 0, 16), Fit = 8, Color = RunTheme.CreamMuted })
	end
	-- new unlocks
	local list = type(payload.NewUnlocks) == "table" and payload.NewUnlocks or {}
	local names = {}
	for _, entry in ipairs(list) do
		table.insert(names, ResultsExtras.UnlockName(entry))
	end
	ui.Unlocks.Visible = #names > 0
	if #names > 0 then
		ui.UnlockTitle.Text = #names == 1 and "NEW CLASS UNLOCKED" or "NEW CLASSES UNLOCKED"
		ui.UnlockNames.Text = table.concat(names, "  ·  ")
	end
	ResultsExtras.RefreshSave()
end

-- Sizes the blocks for a modal inner width; returns the height of the pinned save line (0 when hidden).
function ResultsExtras.Layout(inner: number): number
	if not ui.Outcome then
		return 0
	end
	ui.Outcome.Size = UDim2.new(1, 0, 0, 46)
	if ui.Stats.Visible then
		local rows = ui.StatRows and #ui.StatRows or 0
		local cols = math.max(1, math.floor((inner - 16 + 6) / 126))
		local chipW = math.floor((inner - 16 - (cols - 1) * 6) / cols)
		local lines = math.ceil(rows / cols)
		for _, c in ipairs(ui.StatsGrid:GetChildren()) do
			if c:IsA("Frame") then
				c.Size = UDim2.fromOffset(chipW, 40)
			end
		end
		ui.Stats.Size = UDim2.new(1, 0, 0, 30 + lines * 46)
	end
	if ui.Unlocks.Visible then
		ui.Unlocks.Size = UDim2.new(1, 0, 0, 58)
	end
	return ui.Save.Visible and 38 or 0
end

function ResultsExtras.Elements(): { [string]: any }
	return ui
end

return ResultsExtras
