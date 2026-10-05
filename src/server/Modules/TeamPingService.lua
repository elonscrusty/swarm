-- Preset team communication. Clients provide targets, never text or recipients.
local Config = require(game:GetService("ReplicatedStorage").Shared.Config)
local Remotes = require(game:GetService("ReplicatedStorage").Shared.Remotes)
local TeamPingService = {}
local ctx
local last = {}
local COLORS = { Color3.fromRGB(98, 225, 209), Color3.fromRGB(255, 214, 115), Color3.fromRGB(192, 163, 255), Color3.fromRGB(125, 190, 255) }
local KINDS = { Location = true, Enemy = true, Loot = true, Help = true, Regroup = true }
-- Quick pings and emotes (feature 17, Config.Features.QuickPings, docs/features/TEAM.md):
-- presets at the sender (On my way, the two emotes) or at the open portal (Go portal).
local QUICK = { Portal = true, OnMyWay = true, Wave = true, Cheer = true }
-- Spectate (feature 20): a fallen player who can still be revived asks for help at their body.
local DOWN = { ReviveMe = true }

-- True when `kind` is a ping preset a client may send right now (switches included).
function TeamPingService.Allowed(kind: any): boolean
	if type(kind) ~= "string" then return false end
	if KINDS[kind] then return true end
	if QUICK[kind] then return Config.FeatureOn("QuickPings") end
	if DOWN[kind] then return Config.FeatureOn("Spectate") end
	return false
end

-- A fallen player in a group run who can still be partner-revived.
local function revivable(rp): boolean
	local rules = (Config.Modes :: any)[Remotes.State():GetAttribute("Mode") or ""]
	local perRun = rules and rules.PartnerRevive and rules.PartnerRevive.PerRun
	return not rp.Alive and not rp.AwaitingRevive and (perRun == nil or (rp.PartnerRevives or 0) < perRun)
end

function TeamPingService.Assign(rp, slot: number)
	rp.TeamPingColor = rp.TeamPingColor or COLORS[(slot - 1) % #COLORS + 1]
	rp.Player:SetAttribute("TeamPingColor", rp.TeamPingColor)
end

local function finite(v: Vector3): boolean
	return v.X == v.X and v.Y == v.Y and v.Z == v.Z
		and math.abs(v.X) < 1e6 and math.abs(v.Y) < 1e6 and math.abs(v.Z) < 1e6
end

function TeamPingService.Send(player: Player, kind: any, target: any): boolean
	local rp = ctx.RunManager.GetRunPlayer(player)
	if not TeamPingService.Allowed(kind) or not rp or rp.Returned or not rp.Root
		or not ctx.RunManager.IsRunning() then return false end
	if not KINDS[kind] and #ctx.RunManager.GetRunPlayers() < 2 then return false end -- new presets: group runs only
	if DOWN[kind] then
		if not revivable(rp) then return false end
	elseif not rp.Alive then
		return false
	end
	local now, rules = os.clock(), Config.TeamPings
	if last[player] and now - last[player] < rules.Cooldown then return false end
	local position: Vector3? = nil
	if kind == "Help" or kind == "Regroup" or kind == "OnMyWay" or kind == "Wave" or kind == "Cheer" or kind == "ReviveMe" then
		position = rp.Root.Position
	elseif kind == "Portal" then
		-- the open (or charging) portal wherever it is: no distance limit for this one
		local portal = ctx.StageManager and ctx.StageManager.PortalPosition()
		if not portal or not finite(portal) then return false end
		position = portal
	elseif kind == "Location" and typeof(target) == "Vector3" and finite(target) then
		position = Vector3.new(target.X, rp.Root.Position.Y, target.Z)
	elseif type(target) == "number" and target == target and target % 1 == 0 then
		if kind == "Enemy" then
			for _, enemy in ipairs(ctx.EnemySpawner.Active) do
				if enemy.Id == target and enemy.Alive then position = enemy.Pos; break end
			end
		elseif kind == "Loot" then
			for _, object in ipairs(ctx.LootSystem.Objects()) do
				if object.Id == target and object.Model.Parent and object.State ~= "Opened" and object.State ~= "Claimed"
					and object.State ~= "Spent" and object.State ~= "Active" then
					position = object.Pos; break
				end
			end
		end
	end
	if not position or not finite(position) or (kind ~= "Portal" and (position - rp.Root.Position).Magnitude > rules.MaxDistance) then return false end
	last[player] = now
	local color = rp.TeamPingColor or COLORS[1]
	player:SetAttribute("TeamPingColor", color)
	for _, teammate in ipairs(ctx.RunManager.GetRunPlayers()) do
		if not teammate.Returned and teammate.Player.Parent then
			Remotes.FireClient("TeamPingShown", teammate.Player, {
				Kind = kind, Position = position, UserId = player.UserId, Color = color, Duration = rules.Duration,
			})
		end
	end
	return true
end

function TeamPingService.Init(c) ctx = c end
function TeamPingService.Start()
	Remotes.Listen("TeamPing", TeamPingService.Send, 4)
	game:GetService("Players").PlayerRemoving:Connect(function(player) last[player] = nil end)
end
return TeamPingService
