--[[
	Announcer.lua (feature 26, Config.Features.Announcer; docs/features/FEEL.md)
	A combo counter and kill-streak callouts in FeatureHud's announcer line.
	  * Combo: the local player's kills (player attribute Kills, 10 Hz from the server) in a
	    row; it ends after Config.Feel.Announcer.ResetSeconds with no kill, on death and when
	    the run ends. The line shows from ShowFrom kills ("37 COMBO").
	  * Milestones (Milestones: 50 / 100 / 250 / 500 / 1000): one callout each per combo
	    ("RAMPAGE! 100") with the ComboMilestone chime, a little higher for every milestone.
	  * No spam, one voice with UIState: while a headline banner shows, the counter line is
	    cleared and a milestone goes to the notice lane instead (same id "combo.streak", so
	    two quick ones coalesce); nothing shows while a panel covers the HUD (FeatureHud).
	Purely visual: kills, score and rewards are the server's, untouched.
]]

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")

local Shared = game:GetService("ReplicatedStorage"):WaitForChild("Shared")
local Config = require(Shared:WaitForChild("Config"))
local Theme = require(Shared:WaitForChild("Theme"))
local FeatureHud = require(script.Parent.FeatureHud)
local UIState = require(script.Parent.UIState)
local Audio = require(script.Parent.Audio)

local Announcer = {}

local player = Players.LocalPlayer
local A = Config.Feel.Announcer
local P = Theme.Palette

local combo = 0
local lastKills = 0
local lastKillAt = -math.huge
local calloutUntil = 0
local shownText = ""
local nextMilestone = 1
local stats = { Callouts = 0, Notices = 0, Resets = 0, Best = 0 }

local function on(): boolean
	return Config.FeatureOn("Announcer")
end

local function clearLine()
	if shownText ~= "" then
		shownText = ""
		FeatureHud.Announce("")
	end
end

-- Ends the combo (no kill for ResetSeconds, death, run end).
function Announcer.Reset()
	if combo > 0 then
		stats.Resets += 1
	end
	combo = 0
	nextMilestone = 1
	calloutUntil = 0
	clearLine()
end

local function milestone(m: number, index: number)
	local word = A.Words[m] or "STREAK"
	local text = string.format("%s! %d", word, m)
	local pitch = 2 ^ (((index - 1) * (A.PitchStep or 2)) / 12)
	Audio.Play("ComboMilestone", pitch)
	if UIState.HeadlineShowing() ~= nil then
		UIState.Notice({ Id = "combo.streak", Text = text, Color = P.gold_300, Class = "Info", Seconds = 2 })
		stats.Notices += 1
		return
	end
	FeatureHud.Announce(text, { Color = P.gold_300, Seconds = A.CalloutSeconds })
	shownText = text
	calloutUntil = os.clock() + A.CalloutSeconds
	stats.Callouts += 1
end

-- New kills arrived (delta > 0).
local function onKills(delta: number)
	local now = os.clock()
	combo += delta
	lastKillAt = now
	stats.Best = math.max(stats.Best, combo)
	local list = A.Milestones
	-- several thresholds crossed in one update: only the highest one is called out
	local hit, hitIndex = nil, 0
	while nextMilestone <= #list and combo >= list[nextMilestone] do
		hit, hitIndex = list[nextMilestone], nextMilestone
		nextMilestone += 1
	end
	if hit then
		milestone(hit, hitIndex)
	end
end

local function refresh(now: number)
	if combo > 0 and now - lastKillAt > A.ResetSeconds then
		Announcer.Reset()
		return
	end
	-- the line steps aside for a headline banner (UIState's centre lane wins)
	if UIState.HeadlineShowing() ~= nil then
		calloutUntil = 0
		clearLine()
		return
	end
	if now < calloutUntil then
		return
	end
	if combo < A.ShowFrom then
		clearLine()
		return
	end
	local text = string.format("%d COMBO", combo)
	if text ~= shownText then
		shownText = text
		FeatureHud.Announce(text, { Color = P.ivory_100, Seconds = math.max(0.2, A.ResetSeconds - (now - lastKillAt)) })
	end
end

function Announcer.Combo(): number
	return combo
end

function Announcer.Stats(): { [string]: number }
	return table.clone(stats)
end

function Announcer.Init()
	lastKills = tonumber(player:GetAttribute("Kills")) or 0
	player:GetAttributeChangedSignal("Kills"):Connect(function()
		local kills = tonumber(player:GetAttribute("Kills")) or 0
		local delta = kills - lastKills
		lastKills = kills
		if not on() or player:GetAttribute("InRun") ~= true or player:GetAttribute("Alive") == false then
			return
		end
		if delta > 0 and delta < 10000 then
			onKills(delta)
		elseif delta < 0 then
			Announcer.Reset() -- a new run started from 0
		end
	end)
	player:GetAttributeChangedSignal("InRun"):Connect(function()
		lastKills = tonumber(player:GetAttribute("Kills")) or 0
		Announcer.Reset()
	end)
	player:GetAttributeChangedSignal("Alive"):Connect(function()
		if player:GetAttribute("Alive") == false then
			Announcer.Reset()
		end
	end)
	local acc = 0
	RunService.Heartbeat:Connect(function(dt)
		if combo == 0 and shownText == "" then
			return
		end
		acc += dt
		if acc < 0.1 then
			return
		end
		acc = 0
		if not on() then
			Announcer.Reset()
			return
		end
		refresh(os.clock())
	end)
end

return Announcer
