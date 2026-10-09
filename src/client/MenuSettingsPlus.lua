--[[
	MenuSettingsPlus.lua  (stream L1, docs/redesign/lobby/L1_STATUS.md)
	The extra rows of the Settings screen, built in the screen's own style (UIBuilder's buildPause calls
	Build for its two columns; it extends the existing screen, it does not replace it):

	  Sound column      MASTER VOLUME (scales music and effects together)
	  Comfort column    HOW TO PLAY (lobby only: reopens the first-time guide)
	                    CAMERA & SCREEN: camera sensitivity (shown as 0.5x..2.0x), invert camera X,
	                    invert camera Y, effects intensity (cosmetic particle and trail budgets only:
	                    warnings and telegraphs are never reduced), UI size (80%..120%)
	                    a line saying reduced effects also means reduced motion
	                    RESET TO DEFAULTS (two taps: the second confirms) and a line about saving

	Every row saves through ClientSettings.Set (the existing SaveSettings path: applied at once, one
	coalesced save a moment after the last change). The save line says when saving is off, so a
	setting that lasts only for this session is never presented as saved.
]]

local Players = game:GetService("Players")
local Shared = game:GetService("ReplicatedStorage"):WaitForChild("Shared")
local Config = require(Shared:WaitForChild("Config"))
local ClientSettings = require(script.Parent.ClientSettings)
local UIKit = require(script.Parent.UIKit)
local UIAnim = require(script.Parent.UIAnim)

local MenuSettingsPlus = {}

export type Rows = {
	Sync: () -> (), -- re-read every row from the settings (and the lobby / run state)
}

local TS = UIKit.TS

-- Settings that are not "options" and are never reset (flags, not preferences).
local KEEP = { LobbyGuideSeen = true }

local function heading(parent: Instance, str: string, order: number)
	local h = TS(13) + 12
	local f = UIKit.new("Frame", { Name = "Heading", BackgroundTransparency = 1, LayoutOrder = order, Size = UDim2.new(1, 0, 0, h) }, parent)
	UIKit.text(f, "Caption", string.upper(str), { Size = UDim2.new(1, 0, 1, -4), TextYAlignment = Enum.TextYAlignment.Bottom }, 13)
	UIKit.Hairline(f, { AnchorPoint = Vector2.new(0, 1), Position = UDim2.fromScale(0, 1) })
	return f
end

-- A wrapped line of small text with a fixed height (the columns are measured from Size.Y.Offset).
local function note(parent: Instance, str: string, order: number, lines: number): TextLabel
	return UIKit.text(parent, "Small", str, {
		LayoutOrder = order,
		TextWrapped = true,
		TextYAlignment = Enum.TextYAlignment.Top,
		Size = UDim2.new(1, 0, 0, lines * (TS(14) + 4) + 4),
	}, 14)
end

-- The slider's right-hand readout (UIKit.Slider names it "Number"); `fmt` turns the 0-1 value into words.
local function readout(slider: any, fmt: (number) -> string)
	local label = slider.Frame:FindFirstChild("Number", true)
	if label and label:IsA("TextLabel") then
		label.Text = fmt(slider.Get())
	end
end

function MenuSettingsPlus.Build(colA: Instance, colB: Instance, opts: { Close: () -> (), Resync: () -> () }): Rows
	local player = Players.LocalPlayer

	-- sound -----------------------------------------------------------------------------------
	local master
	master = UIKit.Slider(colA, "Master volume", "speaker", ClientSettings.Get("MasterVolume"), function(v)
		ClientSettings.Set("MasterVolume", v)
	end, function() end, { LayoutOrder = 2 })

	-- comfort ---------------------------------------------------------------------------------
	local howTo = UIKit.Button(colB, {
		Kind = "Secondary",
		Title = "HOW TO PLAY",
		Icon = "info",
		IconSize = 18,
		Align = "Center",
		Depth = "Light",
		Size = UDim2.new(1, 0, 0, 46),
		LayoutOrder = 12,
		OnClick = function()
			-- the lobby's guide opens once the settings are closed (SwarmV2Client.Lobby.LobbyClient listens)
			opts.Close()
			local n = tonumber(player:GetAttribute("SwarmGuideRequest")) or 0
			player:SetAttribute("SwarmGuideRequest", n + 1)
		end,
	})

	heading(colB, "Camera & screen", 13)
	local sens
	sens = UIKit.Slider(colB, "Camera sensitivity", "aim", ClientSettings.Get("CameraSensitivity"), function(v)
		ClientSettings.Set("CameraSensitivity", v)
		readout(sens, ClientSettings.SensitivityText)
	end, function() end, { LayoutOrder = 14 })
	local invertX = UIKit.Toggle(colB, "Invert camera left / right", "cycle", "Drag the other way to turn the view.", ClientSettings.Get("InvertCameraX") == true, function(on)
		ClientSettings.Set("InvertCameraX", on)
	end, { LayoutOrder = 15 })
	local invertY = UIKit.Toggle(colB, "Invert camera up / down", "cycle", "Drag up to look down.", ClientSettings.Get("InvertCameraY") == true, function(on)
		ClientSettings.Set("InvertCameraY", on)
	end, { LayoutOrder = 16 })
	local effects
	effects = UIKit.Slider(colB, "Effects intensity", "sparkle", ClientSettings.Get("EffectsIntensity"), function(v)
		ClientSettings.Set("EffectsIntensity", v)
	end, function() end, { LayoutOrder = 17 })
	local size
	size = UIKit.Slider(colB, "UI size", "area", ClientSettings.Get("UIScale"), function(v)
		ClientSettings.Set("UIScale", v)
		readout(size, ClientSettings.UIScaleText)
	end, function() end, { LayoutOrder = 18 })
	note(colB, "Effects intensity only trims decoration (sparks, trails). Warnings and attack telegraphs always show in full.", 19, 3)
	note(colB, "Reduced effects (above) also means reduced motion: no camera shake or kicks, slower camera recentre.", 20, 3)

	-- reset (two taps) ----------------------------------------------------------------------------
	local armed = false
	local armToken = 0
	local resetBtn
	resetBtn = UIKit.Button(colB, {
		Kind = "Outline",
		Title = "RESET TO DEFAULTS",
		Icon = "cycle",
		IconSize = 18,
		Align = "Center",
		Shrink = true,
		Depth = "Light",
		Size = UDim2.new(1, 0, 0, 46),
		LayoutOrder = 21,
		OnClick = function()
			armToken += 1
			if not armed then
				armed = true
				local token = armToken
				resetBtn.SetText("TAP AGAIN TO RESET ALL OPTIONS")
				task.delay(4, function()
					if armed and token == armToken then
						armed = false
						resetBtn.SetText("RESET TO DEFAULTS")
					end
				end)
				return
			end
			armed = false
			resetBtn.SetText("RESET TO DEFAULTS")
			for key, default in pairs(Config.Settings.Defaults) do
				if not KEEP[key] then
					ClientSettings.Set(key, default)
				end
			end
			UIAnim.Bump(resetBtn.Face)
			opts.Resync()
		end,
	})
	local saveNote = note(colB, "", 22, 2)

	local function words(): string
		local status = player:GetAttribute("SaveStatus")
		if status == "failing" or status == "memory" then
			return "Saving is off right now, so these options last for this session only."
		end
		return "Options apply at once and are saved with your profile."
	end

	local rows: Rows
	rows = {
		Sync = function()
			master.Set(ClientSettings.Get("MasterVolume"))
			sens.Set(ClientSettings.Get("CameraSensitivity"))
			readout(sens, ClientSettings.SensitivityText)
			effects.Set(ClientSettings.Get("EffectsIntensity"))
			size.Set(ClientSettings.Get("UIScale"))
			readout(size, ClientSettings.UIScaleText)
			invertX.Set(ClientSettings.Get("InvertCameraX") == true)
			invertY.Set(ClientSettings.Get("InvertCameraY") == true)
			saveNote.Text = words()
			-- the guide belongs to the lobby: not offered from the run menu's settings
			howTo.Instance.Visible = player:GetAttribute("InRun") ~= true
		end,
	}
	rows.Sync()
	return rows
end

return MenuSettingsPlus
