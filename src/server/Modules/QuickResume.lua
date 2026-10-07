--[[
	QuickResume.lua (Config.Features.QuickResume; docs/next/QUICK_RESUME.md)
	Solo runs get the co-op rejoin grace (RunManager.TryReconnect, RunServers "Rejoin"):

	Disconnect (RunManager.OnPlayerRemoving asks CanHold): a living, uncommitted player of a
	one-player run (Solo / Daily / Weekly) who leaves keeps the run. RunManager snapshots
	the run record exactly as for co-op (lifetime stats checkpointed, escrow kept), keeps the
	run world (no returnAll), and RunManager.SoloAway freezes the run (RefreshFrozen: the run
	clock stops, enemies, projectiles and timers stop; the hero is out of the run, so
	nothing can damage it). Mark writes data.SoloResume = { Id, Expires, Stage, Level, Hero,
	Wave } into the save before the profile is released (Expires = now + Config.RunServers.
	SoloResumeSeconds). The secret reserved-server route stays in data.RunReconnect (its
	Expires stays 0, so the lobby never teleports by itself).

	Back within the window (OnLobbyLoad, from RunServers' profile-loaded handler, and on
	the same server): GoldSystem leaves the escrow alone (Pending), and the player gets the
	attributes ResumeEndsAt (workspace:GetServerTimeNow() based) and ResumeInfo; the client
	(ResumeCard.lua) shows the big RESUME RUN (0:42) card first. Remote "QuickResume":
	  ("Resume")  the run is held on this server: RunManager.TryReconnect (same UserId,
	              same run id, same escrow, snapshot consumed once). Else the live game:
	              RunServers.ResumeSolo teleports to the run's reserved server with the saved
	              access code; the run server restores it through the same TryReconnect.
	              Else (the run is gone): settled now.
	  ("End")     settle now (the usual loss / leave gold-kept rule).
	Too late (Pending false: the window passed, a new run replaced the escrow): settled once
	(GoldSystem.RecoverEscrow: Config.Gold failure retention by stages cleared, exactly the
	kept rule of a loss / leave), SoloResume cleared in the same update, so nothing pays
	twice. The server that holds the run settles it at expiry (RunManager.ExpireSoloHold):
	with the player back on that server, the full leave commit (saveRunStats); with the
	player away, the boards get the final score once and the gold settles on their next load.

	Security: only the save's owner can resume (the snapshot is keyed by UserId and the run
	server only takes its ticket's members); one resume per disconnect (snapshot and
	SoloResume consumed); a resumed run keeps its DEV taint (the snapshot keeps DevTainted).
	Offline / Studio: runs play on the lobby server and the hold stays in memory there; real
	teleports and Roblox closing empty reserved servers are BLOCKED until a live test.
]]

local Players = game:GetService("Players")

local Shared = game:GetService("ReplicatedStorage").Shared
local Config = require(Shared.Config)
local Remotes = require(Shared.Remotes)
local CharacterData = require(Shared.CharacterData)

local QuickResume = {}

local ctx
local INFO = Color3.fromRGB(200, 220, 255)
local WARN = Color3.fromRGB(255, 200, 120)

function QuickResume.On(): boolean
	return Config.FeatureOn("QuickResume")
end

-- Seconds a disconnected solo run waits.
function QuickResume.Window(): number
	local s = tonumber((Config.RunServers :: any).SoloResumeSeconds) or 60
	return math.clamp(math.floor(s), 5, 600)
end

local function finite(v: any): number?
	local n = tonumber(v)
	if not n or n ~= n or n == math.huge or n == -math.huge then
		return nil
	end
	return n
end

-- A valid, unexpired SoloResume whose escrow is still in the save.
function QuickResume.Pending(data: any): boolean
	if not QuickResume.On() or type(data) ~= "table" then
		return false
	end
	local s = data.SoloResume
	if type(s) ~= "table" or type(s.Id) ~= "string" or s.Id == "" or #s.Id > 160 then
		return false
	end
	local expires = finite(s.Expires)
	local now = os.time()
	return expires ~= nil and expires > now and expires <= now + QuickResume.Window() + 5
		and type(data.RunEscrow) == "table" and data.RunEscrow.Id == s.Id
end

-- RunManager.OnPlayerRemoving: may this leaving player's run be held?
function QuickResume.CanHold(rp, runPlayerCount: number, maxPlayers: number): boolean
	if not QuickResume.On() or not rp or not rp.Player then
		return false
	end
	if not rp.Alive or rp.AwaitingRevive or rp.Committed or rp.Abandoned or rp.Returned then
		return false
	end
	if runPlayerCount ~= 1 or maxPlayers ~= 1 then
		return false -- solo runs only: co-op has its own rejoin (RunServers.CanReconnect)
	end
	return ctx.DataService.GetData(rp.Player) ~= nil
end

-- Writes the save's SoloResume for a held run. Returns its expiry (os.time()).
function QuickResume.Mark(rp, data: { [string]: any }): number
	if not (type(data.RunEscrow) == "table" and data.RunEscrow.Id == tostring(rp.RunId)) then
		ctx.GoldSystem.BeginRun(rp) -- an escrow with nothing earned yet
	end
	local expires = os.time() + QuickResume.Window()
	local wave = Remotes.State():GetAttribute("Wave")
	data.SoloResume = {
		Id = tostring(rp.RunId),
		Expires = expires,
		Stage = ctx.StageManager.GetStage(),
		Level = math.floor(tonumber(rp.Level) or 1),
		Hero = type(rp.CharacterId) == "string" and rp.CharacterId or CharacterData.Default,
		Wave = type(wave) == "number" and math.floor(wave) or 0,
	}
	return expires
end

-- The card's one line: "Stage 2 · Wave 7 · Level 14 · Knight".
function QuickResume.InfoText(data: any): string
	local s = type(data) == "table" and data.SoloResume or nil
	if type(s) ~= "table" then
		return ""
	end
	local parts = {}
	local stage = finite(s.Stage)
	if stage and stage >= 1 then
		table.insert(parts, "Stage " .. math.floor(stage))
	end
	local wave = finite(s.Wave)
	if wave and wave >= 1 then
		table.insert(parts, "Wave " .. math.floor(wave))
	end
	local level = finite(s.Level)
	if level and level >= 1 then
		table.insert(parts, "Level " .. math.floor(level))
	end
	local hero = type(s.Hero) == "string" and CharacterData.Characters[s.Hero]
	if hero then
		table.insert(parts, hero.Name)
	end
	return table.concat(parts, "  ·  ")
end

local function setOffer(player: Player, data: any)
	if not player.Parent then
		return
	end
	if data and QuickResume.Pending(data) then
		local left = math.max(0, (finite(data.SoloResume.Expires) or 0) - os.time())
		player:SetAttribute("ResumeEndsAt", workspace:GetServerTimeNow() + left)
		player:SetAttribute("ResumeInfo", QuickResume.InfoText(data))
	else
		player:SetAttribute("ResumeEndsAt", nil)
		player:SetAttribute("ResumeInfo", nil)
	end
end

-- Clears the save's SoloResume and the card (after a resume or a settlement).
function QuickResume.Clear(player: Player?, data: any)
	if type(data) == "table" then
		data.SoloResume = nil
	end
	if player and player.Parent then
		player:SetAttribute("ResumeEndsAt", nil)
		player:SetAttribute("ResumeInfo", nil)
	end
end

--[[
	Settles a held run that can no longer be resumed, once: the escrow of THAT run (if it
	is still in the save) with the loss / leave kept rule, the stale route cleared. Returns
	the gold kept. Safe to call twice (the second call finds nothing).
]]
function QuickResume.Settle(player: Player, data: any, why: string?): number
	if type(data) ~= "table" or type(data.SoloResume) ~= "table" then
		QuickResume.Clear(player, data)
		return 0
	end
	local id = data.SoloResume.Id
	data.SoloResume = nil
	local kept = 0
	local had = type(data.RunEscrow) == "table" and data.RunEscrow.Id == id
	if had then
		kept = ctx.GoldSystem.RecoverEscrow(data)
	end
	if type(data.RunReconnect) == "table" and data.RunReconnect.Id == id then
		data.RunReconnect = nil
	end
	QuickResume.Clear(player, data)
	if player.Parent then
		ctx.GoldSystem.SyncProfile(player)
		-- quiet when another path already settled it (a failed teleport says so itself)
		if why or had then
			ctx.RunManager.Notify(player, why or string.format("Your run ended. %d gold kept.", kept), WARN, { Id = "resume.settled" })
		end
	end
	return kept
end

--[[
	RunServers' profile-loaded handler (lobby side, before its co-op reconnect routing) and
	the same-server join: true when this player has a solo run waiting (the card is offered
	and the co-op path must not settle or route it).
]]
function QuickResume.OnLobbyLoad(player: Player, data: any): boolean
	if not QuickResume.On() or type(data) ~= "table" or type(data.SoloResume) ~= "table" then
		return false
	end
	if not QuickResume.Pending(data) then
		local hold = ctx.RunManager.SoloHoldFor and ctx.RunManager.SoloHoldFor(player.UserId)
		if hold then
			return true -- held on this server: RunManager settles it at its expiry
		end
		QuickResume.Settle(player, data)
		return true
	end
	setOffer(player, data)
	return true
end

local function onRequest(player: Player, action: any)
	if not QuickResume.On() or (action ~= "Resume" and action ~= "End") then
		return
	end
	local data = ctx.DataService.GetData(player)
	if not data or type(data.SoloResume) ~= "table" then
		setOffer(player, nil)
		return
	end
	if ctx.RunManager.IsParticipant(player) or (ctx.RunServers and ctx.RunServers.IsTravelling(player)) then
		return
	end
	local hold = ctx.RunManager.SoloHoldFor and ctx.RunManager.SoloHoldFor(player.UserId)
	if action == "End" then
		if hold then
			ctx.RunManager.ExpireSoloHold(false)
		else
			QuickResume.Settle(player, data)
		end
		return
	end
	if not QuickResume.Pending(data) then
		if hold then
			ctx.RunManager.ExpireSoloHold(false)
		else
			QuickResume.Settle(player, data, "Too late: your run has ended. Your kept gold is in your purse.")
		end
		return
	end
	if hold then
		if ctx.RunManager.TryReconnect(player, data.SoloResume.Id) then
			QuickResume.Clear(player, data)
			ctx.GoldSystem.SyncProfile(player)
			ctx.RunManager.Notify(player, "Run resumed.", INFO, { Id = "resume.done" })
		elseif not ctx.RunManager.ExpireSoloHold(false) then
			QuickResume.Settle(player, data, "Couldn't bring the run back, so it has ended. Your kept gold is in your purse.")
		end
		return
	end
	if ctx.RunServers and ctx.RunServers.ResumeSolo and ctx.RunServers.ResumeSolo(player) then
		-- on the way back (the travel cover shows); the card closes
		player:SetAttribute("ResumeEndsAt", nil)
		player:SetAttribute("ResumeInfo", nil)
		return
	end
	QuickResume.Settle(player, data, "Your run's server has closed, so the run has ended. Your kept gold is in your purse.")
end
QuickResume._Request = onRequest -- (tests)

-- Twice a second: offers that ran out are settled once (the holding server settles its own).
function QuickResume.Step()
	if not QuickResume.On() then
		return
	end
	for _, player in ipairs(Players:GetPlayers()) do
		local data = ctx.DataService.GetData(player)
		if data and type(data.SoloResume) == "table" and not ctx.RunManager.IsParticipant(player)
			and not (ctx.RunServers and ctx.RunServers.IsTravelling(player)) then
			local hold = ctx.RunManager.SoloHoldFor and ctx.RunManager.SoloHoldFor(player.UserId)
			if not hold and not QuickResume.Pending(data) then
				QuickResume.Settle(player, data)
			elseif player:GetAttribute("ResumeEndsAt") == nil and QuickResume.Pending(data) then
				setOffer(player, data)
			end
		elseif player:GetAttribute("ResumeEndsAt") ~= nil and not (data and QuickResume.Pending(data)) then
			setOffer(player, nil)
		end
	end
end

function QuickResume.Init(c)
	ctx = c
end

function QuickResume.Start()
	Remotes.Listen("QuickResume", onRequest, tonumber(((Config :: any).QuickResume or {}).Rate) or 2)
	task.spawn(function()
		while true do
			task.wait(0.5)
			local ok, err = pcall(QuickResume.Step)
			if not ok then
				warn("[QuickResume] " .. tostring(err))
			end
		end
	end)
end

return QuickResume
