--[[
	DevAccess.lua  (server only)
	The one rule for who is a developer: DEV panel commands (RunManager "DevCommand" →
	DevTools), the DEV bug inbox (BugReportService) and the client's DEV button.

	A player is a developer when Config.Dev.Enabled is on and
	  - the server runs in Studio, or
	  - their UserId is in DevAllowlist (live servers; the owner is listed), or
	  - Config.Dev.ShowInLiveGame is on and they created this user-owned game.

	Start marks each developer with the player attribute DevAccess = true so the client
	knows to build the DEV button (it also catches a late attribute after a respawn or a
	menu change). The attribute only decides what the client draws: every command is
	checked again here, on the server, so a client that sets it locally gains nothing.
]]

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")

local Config = require(game:GetService("ReplicatedStorage").Shared.Config)
local DevAllowlist = require(script.Parent.DevAllowlist)

local DevAccess = {}

function DevAccess.IsDev(player: Player): boolean
	if not Config.Dev.Enabled then
		return false
	end
	if RunService:IsStudio() then
		return true
	end
	if DevAllowlist[player.UserId] == true then
		return true
	end
	return Config.Dev.ShowInLiveGame == true and game.CreatorType == Enum.CreatorType.User and player.UserId == game.CreatorId
end

-- Studio-only commands (they change a save in a way that cannot be undone).
function DevAccess.IsStudio(): boolean
	return RunService:IsStudio()
end

local function mark(player: Player)
	if DevAccess.IsDev(player) then
		player:SetAttribute("DevAccess", true)
	end
end

function DevAccess.Start()
	Players.PlayerAdded:Connect(mark)
	for _, player in ipairs(Players:GetPlayers()) do
		mark(player)
	end
end

return DevAccess
