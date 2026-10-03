--[[
	scenes/lib/common.luau - helpers shared by the preview scenes.

	Scenes drive the game only through public entry points (MapBuilder.BuildLobby /
	BuildArena / ApplyLighting, MeshService.Init / Start, ModelBuilder.BuildCharacter,
	the client's ClientMain → UIBuilder.Init) and remote events / attributes, so they keep
	working while the UI and map code is rewritten. Every step is protected: a failing game
	module is reported (with its stack) and the scene renders whatever exists.
]]

local C = {}

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

-- Runs fn; on error reports it and returns nil (the scene keeps going).
function C.try(label: string, fn, ...)
	local results = table.pack(xpcall(fn, function(e)
		return debug.traceback(tostring(e), 2)
	end, ...))
	if not results[1] then
		preview.warn(label .. " failed:\n" .. tostring(results[2]))
		return nil
	end
	return table.unpack(results, 2, results.n)
end

function C.shared(name: string)
	return C.try("require Shared." .. name, preview.shared, name)
end

function C.server(name: string)
	return C.try("require server " .. name, preview.server, name)
end

-- Remotes + SwarmState + meshes (every catalog model counts as uploaded unless
-- --set meshes=uploaded keeps only the really uploaded ones).
function C.bootServer()
	local Remotes = C.shared("Remotes")
	if Remotes then
		C.try("Remotes.Setup", Remotes.Setup)
	end
	if preview.args.meshes ~= "uploaded" and preview.args.meshes ~= "none" then
		local forced = preview.forceMeshesUploaded()
		if #forced > 0 then
			preview.note("not yet uploaded models shown from meshes/: " .. table.concat(forced, ", "))
		end
	end
	local MeshService = C.server("MeshService")
	if MeshService then
		C.try("MeshService.Init", MeshService.Init, {})
		if preview.args.meshes == "none" then
			preview.note("--set meshes=none: no mesh loads, every model is its part-built fallback")
		else
			C.try("MeshService.Start", MeshService.Start, {})
		end
	end
	preview.advance(0.05)
	return {
		Remotes = Remotes,
		MeshService = MeshService,
		MapBuilder = C.server("MapBuilder"),
		ModelBuilder = C.server("ModelBuilder"),
		Config = C.shared("Config"),
	}
end

function C.state()
	return ReplicatedStorage:FindFirstChild("SwarmState")
end

function C.setState(attrs)
	local st = C.state()
	if not st then
		return
	end
	for k, v in pairs(attrs) do
		st:SetAttribute(k, v)
	end
end

function C.setPlayer(attrs)
	local p = Players.LocalPlayer
	for k, v in pairs(attrs) do
		p:SetAttribute(k, v)
	end
end

-- ReplicatedStorage.CharacterPreviews, built like RunManager does (anchored, no Humanoid).
function C.buildPreviews(ModelBuilder)
	local CharacterData = C.shared("CharacterData")
	if not ModelBuilder or not CharacterData then
		return
	end
	local folder = ReplicatedStorage:FindFirstChild("CharacterPreviews") or Instance.new("Folder")
	folder.Name = "CharacterPreviews"
	folder.Parent = ReplicatedStorage
	for _, id in ipairs(CharacterData.Order) do
		for _, skinId in ipairs(CharacterData.SkinsFor(id)) do
			local model = C.try("BuildCharacter " .. id .. "|" .. skinId, ModelBuilder.BuildCharacter, id, skinId)
			if model then
				local hum = model:FindFirstChildOfClass("Humanoid")
				if hum then
					hum:Destroy()
				end
				for _, d in ipairs(model:GetDescendants()) do
					if d:IsA("BasePart") then
						d.Anchored = true
					end
				end
				model.Name = id .. "|" .. skinId
				model.Parent = folder
			end
		end
	end
end

-- The local player's character at `cf` (like RunManager.spawnCharacter).
function C.spawnCharacter(ModelBuilder, cf: CFrame, characterId: string?, skinId: string?)
	if not ModelBuilder then
		return nil
	end
	local model = C.try("BuildCharacter", ModelBuilder.BuildCharacter, characterId or "Knight", skinId or "Default")
	if not model then
		return nil
	end
	local player = Players.LocalPlayer
	model.Name = player.Name
	model:PivotTo(cf)
	player.Character = model
	model.Parent = workspace
	return model
end

function C.profile(overrides)
	local CharacterData = C.shared("CharacterData")
	local p = {
		Gold = 1840,
		Meta = { MaxHP = 2, Might = 1, Armor = 1, Speed = 0, Luck = 0, Growth = 1, Revive = 0, Reroll = 1, Skip = 0 },
		-- Hero Mastery: Knight mastery 3 (some XP into 4), part of its track bought
		Heroes = { Knight = { XP = 620, Runs = 9 }, Mage = { XP = 40, Runs = 1 } },
		HeroUpgrades = {
			Knight = { MaxHP = 6, Might = 3, Armor = 1, Growth = 1, Signature = 1 },
			Mage = { MaxHP = 2, Might = 1, Armor = 1, Growth = 1 },
		},
		OwnedCharacters = { Knight = true, Mage = true },
		SelectedCharacter = "Knight",
		Skins = { Knight = "Default" },
		Stats = { BestTime = 754, TotalKills = 4821, Wins = 1, Runs = 12 },
		Settings = { Music = 0.6, Sfx = 0.8 },
		ReviveTokens = 0,
		OwnedSkins = { Default = true },
		Passes = { StarterPack = false, VIP = false, DoubleGold = false },
		MemoryOnly = false,
	}
	if CharacterData and CharacterData.Skins then
		-- one bought skin so the skin rows show both states
		for skinId in pairs(CharacterData.Skins) do
			if string.find(skinId, "^Knight_") then
				p.OwnedSkins[skinId] = true
				break
			end
		end
	end
	for k, v in pairs(overrides or {}) do
		p[k] = v
	end
	return p
end

-- Starts the client exactly like Roblox (copies StarterPlayerScripts, runs ClientMain).
function C.startClient()
	-- Server logic scenes can omit UI layout; visual scenes keep the normal client.
	if preview.args.headless == "on" then
		preview.startClient(false)
		return
	end
	C.try("start client", preview.startClient)
	preview.advance(0.1)
end

function C.fire(name: string, ...)
	C.try("fire " .. name, preview.fireClient, name, ...)
end

-- Lobby world + previews + character + lobby attributes (the menu backdrop).
function C.lobby(opts)
	opts = opts or {}
	local s = C.bootServer()
	local lobby
	if s.MapBuilder then
		lobby = C.try("MapBuilder.BuildLobby", s.MapBuilder.BuildLobby)
	end
	C.buildPreviews(s.ModelBuilder)
	local spawnCF = lobby and lobby.SpawnCFrame or CFrame.new(1200, 3.5, -6)
	C.setState({ Phase = "Lobby", SelectedArena = "Forest", Mode = "Solo", BossHP = 0, BossMaxHP = 0, LobbySpawn = spawnCF, Participants = 0, RunTime = 0 })
	C.setPlayer({ InRun = false, Gold = 1840 })
	C.spawnCharacter(s.ModelBuilder, spawnCF, opts.character, opts.skin)
	s.lobby = lobby
	return s
end

-- Shows the lobby profile (the server answers RequestProfile with ProfileSync).
function C.sendProfile(p)
	C.fire("ProfileSync", p or C.profile())
end

-- Lets pop-in / slide animations finish (looping idle tweens keep their phase).
function C.settle(seconds: number?)
	preview.advance(seconds or 2.5, 30)
end

-- First GuiButton / label whose text matches (Lua pattern), or nil.
function C.findText(pattern: string, class: string?)
	for _, g in ipairs(preview.findGui(function(obj, st)
		local ok, text = pcall(function()
			return obj.Text
		end)
		return ok and type(text) == "string" and string.find(string.upper(text), pattern) ~= nil and (not class or obj:IsA(class))
	end)) do
		return g
	end
	return nil
end

return C
