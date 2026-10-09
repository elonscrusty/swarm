--!nonstrict
--[[
	SwarmV2/Run/RunInteract.lua  (StarterPlayerScripts.SwarmV2Client.Run.RunInteract)
	OWNER: stream F (run UI).

	The one interact prompt of the run: E on a keyboard, the gamepad X button, or pressing and holding
	the prompt itself on touch. It names the thing the hold would do, chosen by the current state,
	in this priority: REVIVE a downed teammate within reach, then the BEACON, then a CHEST. A held
	revive wins over an incidental chest (the chest prompt and its hold are suppressed while a
	revive is possible); passive proximity never buys anything: only a deliberate hold does.

	  revive  "Hold to revive Ben" - a downed teammate (player attribute Downed) within
	          RunConfig.UI.Interact.ReviveRange; the ring follows their ReviveProgress; "Interrupted"
	          shows when the progress was lost while holding. Server: ReplicatedStorage.SwarmV2Net.Run.
	          Interact:FireServer("Revive", userId, holding) when stream E1 provides it, else the older
	          ReviveHold remote; with neither the prompt shows nothing (no pretend button).
	  beacon  "Hold to start the beacon" - RunStage BeaconAvailable, BeaconPos within BeaconRange.
	          Server: SwarmV2Net.Run.Interact:FireServer("Beacon", "Beacon", holding) (stream D); absent
	          = nothing shown.
	  chest   "Open chest  ·  140 gold" with the cost and the team balance ("you have 215", or
	          "need 55 more" in red): from the loot model (LootUI) and SwarmState TeamRunGold /
	          ChestCost. The hold itself is LootUI's existing LootHold flow (the server decides and
	          debits once); this prompt only presents it and forwards the press / release.

	Missing attributes are fine: no target, no prompt. Reduced motion: no pop.
]]

local Players = game:GetService("Players")
local UserInputService = game:GetService("UserInputService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Theme = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Theme"))
local RunConfig = require(ReplicatedStorage:WaitForChild("SwarmV2"):WaitForChild("Run"):WaitForChild("RunConfig"))
local Client = script.Parent.Parent.Parent:WaitForChild("SwarmClient")
local UIKit = require(Client:WaitForChild("UIKit"))
local UIAnim = require(Client:WaitForChild("UIAnim"))
local UIState = require(Client:WaitForChild("UIState"))
local ClientSettings = require(Client:WaitForChild("ClientSettings"))
local InputPrompts = require(Client:WaitForChild("InputPrompts"))
local RunTheme = require(script.Parent.RunTheme)
local W = require(script.Parent.RunWidgets)

local RunInteract = {}

local CFG = RunConfig.UI.Interact
local player = Players.LocalPlayer
local new = UIKit.new
local FLAT = Vector3.new(1, 0, 1)

local ui: { [string]: any } = {}
local kit: { [string]: any } = {}
local SD = RunConfig.Survival and RunConfig.Survival.Downed
local reviveHoldMod: any = nil -- stream E1's ReviveHoldClient (E / X / the touch REVIVE button), false = absent
local cur: { [string]: any }? = nil -- the target now: { Kind, Id, Name, ... }
local holding = false
local holdStart = 0
local lastPoll = 0
local remote: Instance? = nil
local remoteAt = 0
local interruptedUntil = 0
local lastProgress = 0
local LootUI: any = nil -- set by UIBuilder (the chest hold and the loot models)

function RunInteract.SetLoot(loot: any)
	LootUI = loot
end

------------------------------------------------------------------------------------------
-- Server hooks (present only when the owning stream added them)
------------------------------------------------------------------------------------------

local function findRemote(): Instance?
	local now = os.clock()
	if remote and remote.Parent then
		return remote
	end
	if now - remoteAt < 1 then
		return nil
	end
	remoteAt = now
	local net = ReplicatedStorage:FindFirstChild("SwarmV2Net")
	local run = net and net:FindFirstChild(CFG.RemoteFolder)
	remote = run and run:FindFirstChild(CFG.RemoteName) or nil
	return remote
end

local function reviveHold(): any
	if reviveHoldMod == nil then
		local mod = script.Parent:FindFirstChild("ReviveHoldClient")
		if mod and mod:IsA("ModuleScript") then
			local ok, m = pcall(require, mod)
			reviveHoldMod = ok and m or false
		else
			reviveHoldMod = false
		end
	end
	return reviveHoldMod or nil
end

local function legacyReviveRemote(): Instance?
	local folder = ReplicatedStorage:FindFirstChild("Remotes")
	return folder and folder:FindFirstChild("ReviveHold") or nil
end

-- The beacon's own ProximityPrompt (stream D: "BeaconPrompt", E, a 0.5 s hold; the server's
-- Beacon.TryActivate decides). This prompt draws it (the default Roblox one is switched to Custom on this
-- client) and forwards the hold with InputHoldBegin / InputHoldEnd.
local beaconPrompt: ProximityPrompt? = nil
local beaconPromptAt = 0
local function findBeaconPrompt(): ProximityPrompt?
	if beaconPrompt and beaconPrompt.Parent then
		return beaconPrompt
	end
	local now = os.clock()
	if now - beaconPromptAt < 1 then
		return nil
	end
	beaconPromptAt = now
	local found = workspace:FindFirstChild("BeaconPrompt", true)
	beaconPrompt = found and found:IsA("ProximityPrompt") and found or nil
	if beaconPrompt then
		pcall(function()
			(beaconPrompt :: ProximityPrompt).Style = Enum.ProximityPromptStyle.Custom
		end)
	end
	return beaconPrompt
end

local function send(kind: string, id: any, on: boolean)
	if kind == "Beacon" then
		local pp = findBeaconPrompt()
		if pp then
			local ok = pcall(function()
				if on then
					pp:InputHoldBegin()
				else
					pp:InputHoldEnd()
				end
			end)
			return ok
		end
	end
	local r = findRemote()
	if r and r:IsA("RemoteEvent") then
		r:FireServer(kind, id, on)
		return true
	end
	if kind == "Revive" then
		local legacy = legacyReviveRemote()
		if legacy and legacy:IsA("RemoteEvent") then
			legacy:FireServer(on)
			return true
		end
	end
	return false
end

local function canAct(kind: string): boolean
	if kind == "Chest" then
		return LootUI ~= nil
	end
	if kind == "Revive" then
		-- E1's ReviveHoldClient sends the hold; without it the older ReviveHold remote still does
		return reviveHold() ~= nil or legacyReviveRemote() ~= nil
	end
	if kind == "Beacon" and findBeaconPrompt() then
		return true
	end
	return findRemote() ~= nil
end

------------------------------------------------------------------------------------------
-- Target
------------------------------------------------------------------------------------------

local function myRoot(): BasePart?
	local c = player.Character
	return c and c.PrimaryPart or nil
end

local function iAmOut(): boolean
	return player:GetAttribute("Downed") == true or player:GetAttribute("Eliminated") == true or player:GetAttribute("Spectating") == true
end

-- The target for this moment (priority Revive > Beacon > Chest), or nil.
local function findTarget(state: Instance): { [string]: any }?
	local root = myRoot()
	if not root or iAmOut() then
		return nil
	end
	-- revive
	local best, bestD = nil, math.huge
	for _, p in ipairs(Players:GetPlayers()) do
		if p ~= player and p:GetAttribute("Downed") == true and p:GetAttribute("Eliminated") ~= true then
			local r = p.Character and p.Character.PrimaryPart
			if r then
				local d = ((r.Position - root.Position) * FLAT).Magnitude
				if d <= (SD and SD.ReviveRange + 1 or CFG.ReviveRange) and d < bestD then
					best, bestD = p, d
				end
			end
		end
	end
	if best and canAct("Revive") then
		return { Kind = "Revive", Id = best.UserId, Name = best.DisplayName, Player = best, Hold = CFG.ReviveHold }
	end
	-- beacon
	local beacon = state:GetAttribute("BeaconPos")
	if state:GetAttribute("RunStage") == "BeaconAvailable" and typeof(beacon) == "Vector3" then
		local d = ((beacon - root.Position) * FLAT).Magnitude
		if d <= CFG.BeaconRange and canAct("Beacon") then
			local pp = findBeaconPrompt()
		return { Kind = "Beacon", Id = "Beacon", Name = "the beacon", Hold = pp and pp.HoldDuration or CFG.BeaconHold, Action = pp and pp.ActionText or nil }
		end
	end
	-- chest
	local model = LootUI and LootUI.Target and LootUI.Target() or nil
	if model and model.Parent and model:GetAttribute("LootKind") == "Chest" and model:GetAttribute("State") == "Ready" then
		return { Kind = "Chest", Id = model:GetAttribute("LootId"), Model = model, Hold = tonumber(model:GetAttribute("Hold")) or CFG.ChestHold }
	end
	return nil
end

-- Which kind (if any) owns the interact key right now: LootUI asks, to drop a chest hold while a
-- revive is possible.
function RunInteract.Priority(): string?
	return cur and cur.Kind or nil
end

------------------------------------------------------------------------------------------
-- Build
------------------------------------------------------------------------------------------

-- The touch REVIVE button is E1's (ReviveHoldClient): the run HUD adopts it, places it above JUMP
-- (RunLayout "Revive") and gives it the run tokens; its input and visibility stay with that module.
local function adoptReviveButton()
	local rh = reviveHold()
	local b = rh and rh.Button and rh.Button() or nil
	if not b or not ui.Root then
		return
	end
	if ui.ReviveBtn ~= b then
		ui.ReviveBtn = b
		b.Parent = ui.Root
		b.AnchorPoint = Vector2.zero
		b.ZIndex = Theme.Z.LevelUp + 3 -- above the upgrade cards: a revive is never blocked by a panel
		b.BackgroundColor3 = RunTheme.Gold
		local st = b:FindFirstChildOfClass("UIStroke")
		if st then
			st.Color = RunTheme.Navy
		end
		local fill = b:FindFirstChild("Fill")
		if fill then
			fill.BackgroundColor3 = RunTheme.Cyan
			fill.BackgroundTransparency = 0.25
		end
		local label = b:FindFirstChild("Label")
		if label then
			label.Text = "HOLD\nREVIVE"
			label.FontFace = Theme.Font.Heading
			label.TextColor3 = RunTheme.OnGold
			label.ZIndex = 2
		end
	end
	local Hud = kit.Hud
	local r = Hud and Hud.RunRect("Revive")
	if r then
		local pos, size = UDim2.fromOffset(math.floor(r.X + 0.5), math.floor(r.Y + 0.5)), UDim2.fromOffset(math.floor(r.W + 0.5), math.floor(r.H + 0.5))
		if b.Position ~= pos then
			b.Position = pos
		end
		if b.Size ~= size then
			b.Size = size
		end
		local label = b:FindFirstChild("Label")
		local scale = math.max(0.3, kit.Scale and kit.Scale() or 1)
		local px = math.ceil(18 / scale)
		if label and label.TextSize ~= px then
			label.TextSize = px
		end
	end
end

function RunInteract.Build(root: Instance, k: any)
	kit = k
	ui.Root = root
	local holder, face = W.Panel(root, { Name = "RunInteract", Visible = false, ZIndex = Theme.Z.Loot })
	holder.AnchorPoint = Vector2.new(0.5, 1)
	ui.Panel, ui.Face = holder, face
	-- the whole prompt is the touch button (hold it); it sits where a thumb can reach
	local hit = new("TextButton", { Name = "Hold", Text = "", AutoButtonColor = false, BackgroundTransparency = 1, Size = UDim2.fromScale(1, 1), ZIndex = 6, Selectable = true, Active = true }, face)
	ui.Hit = hit
	ui.Ring = W.Ring(face, { Name = "HoldRing", Size = 52, Segments = 24, Color = RunTheme.Gold, Position = UDim2.fromOffset(8, 6), ZIndex = 3 })
	ui.KeyHolder = new("Frame", { Name = "KeyHolder", BackgroundTransparency = 1, AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromOffset(8 + 26, 6 + 26), Size = UDim2.fromOffset(40, 36), ZIndex = 4, Active = false }, face)
	ui.Key = W.KeyCap(ui.KeyHolder, "E", { Height = 32, Width = 36, AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.5), ZIndex = 5 })
	ui.Label = W.Text(face, "", { Name = "Label", Size = 20, Font = "Heading", Position = UDim2.fromOffset(70, 4), Box = UDim2.new(1, -78, 0, 28), Fit = 13, Color = RunTheme.Cream, ZIndex = 4 })
	ui.Sub = W.Text(face, "", { Name = "Sub", Size = 16, Font = "Body", Position = UDim2.fromOffset(70, 32), Box = UDim2.new(1, -78, 0, 22), Fit = 11, Color = RunTheme.CreamMuted, ZIndex = 4 })
	hit.InputBegan:Connect(function(input)
		if input.UserInputType == Enum.UserInputType.Touch or input.UserInputType == Enum.UserInputType.MouseButton1 then
			RunInteract.Press()
		end
	end)
	hit.InputEnded:Connect(function(input)
		if input.UserInputType == Enum.UserInputType.Touch or input.UserInputType == Enum.UserInputType.MouseButton1 then
			RunInteract.Release()
		end
	end)
	-- E / gamepad X: hold
	UserInputService.InputBegan:Connect(function(input, processed)
		if processed or UserInputService:GetFocusedTextBox() then
			return
		end
		if input.KeyCode == CFG.Key or input.KeyCode == CFG.PadButton then
			RunInteract.Press()
		end
	end)
	UserInputService.InputEnded:Connect(function(input)
		if input.KeyCode == CFG.Key or input.KeyCode == CFG.PadButton then
			RunInteract.Release()
		end
	end)
	UserInputService.WindowFocusReleased:Connect(function()
		RunInteract.Release()
	end)
end

------------------------------------------------------------------------------------------
-- Hold
------------------------------------------------------------------------------------------

function RunInteract.Press()
	local t = cur
	if not t or holding or not UIState.WorldInputAllowed() then
		return
	end
	if t.Kind == "Revive" then
		return -- ReviveHoldClient binds E / X and the touch REVIVE button; this prompt only shows it
	end
	if t.Kind == "Chest" then
		if LootUI and LootUI.Press then
			LootUI.Press() -- LootUI keeps the hold, the gold check and the server flow
			holding = true
			holdStart = os.clock()
		end
		return
	end
	if send(t.Kind, t.Id, true) then
		holding = true
		holdStart = os.clock()
		lastProgress = 0
	end
end

function RunInteract.Release()
	if not holding then
		return
	end
	holding = false
	local t = cur
	if t then
		if t.Kind == "Chest" then
			if LootUI and LootUI.Release then
				LootUI.Release()
			end
		else
			send(t.Kind, t.Id, false)
		end
	end
end

------------------------------------------------------------------------------------------
-- Per frame
------------------------------------------------------------------------------------------

local function chestLines(t: { [string]: any }, state: Instance): (string, string, boolean)
	local price = LootUI and LootUI.PriceOf and LootUI.PriceOf(t.Model) or 0
	local cost = tonumber(state:GetAttribute("ChestCost"))
	if price <= 0 and cost then
		price = cost
	end
	local gold = LootUI and LootUI.WalletOf and t.Model and LootUI.WalletOf(t.Model) or tonumber(state:GetAttribute("TeamRunGold")) or tonumber(player:GetAttribute("RunGold")) or 0
	if price <= 0 then
		return "Open chest", "Free", true
	end
	local afford = gold >= price
	local sub = afford and string.format("%s gold  ·  you have %s", UIKit.formatNumber(price), UIKit.formatNumber(gold))
		or string.format("%s gold  ·  need %s more", UIKit.formatNumber(price), UIKit.formatNumber(price - gold))
	return "Open chest", sub, afford
end

function RunInteract.Update(_dt: number, state: Instance, inRun: boolean)
	if not ui.Panel then
		return
	end
	adoptReviveButton()
	local now = os.clock()
	if now - lastPoll >= CFG.Poll then
		lastPoll = now
		local nextTarget = inRun and findTarget(state) or nil
		local changed = (nextTarget and nextTarget.Kind or nil) ~= (cur and cur.Kind or nil) or (nextTarget and cur and nextTarget.Id ~= cur.Id)
		if changed and holding then
			-- the target went away (walked off, got revived, the chest opened): let go
			RunInteract.Release()
		end
		if changed and nextTarget and not ClientSettings.Reduced() then
			UIAnim.Pop(ui.Panel, 0, 0.85)
		end
		cur = nextTarget
	end
	local t = cur
	local allowed = UIState.WorldInputAllowed()
	if not t or not allowed then
		if ui.Panel.Visible then
			ui.Panel.Visible = false
		end
		if holding then
			RunInteract.Release()
		end
		return
	end
	-- the words
	local label, sub, ok = "", "", true
	local progress = 0
	local touchMode = InputPrompts.Mode() == "Touch"
	ui.Hit.Visible = t.Kind ~= "Revive" -- a revive is held on the REVIVE button / E / X, not on the prompt
	if t.Kind == "Revive" then
		label = (touchMode and "Hold REVIVE to revive " or "Hold to revive ") .. tostring(t.Name)
		local serverProgress = tonumber(t.Player:GetAttribute("ReviveProgress")) or 0
		if holding and serverProgress <= 0 and lastProgress > 0.05 then
			interruptedUntil = now + RunConfig.UI.Downed.InterruptedShow
		end
		lastProgress = serverProgress
		progress = serverProgress
		local bleed = tonumber(t.Player:GetAttribute("BleedLeft"))
		sub = now < interruptedUntil and "Interrupted. Hold again" or string.format("%d second hold%s", t.Hold, bleed and string.format("  ·  %d s left", math.ceil(bleed)) or "")
	elseif t.Kind == "Beacon" then
		label = "Hold to " .. string.lower(t.Action or "light the beacon")
		sub = string.format("%s s hold  ·  stay within %d studs", tostring(math.floor((t.Hold or CFG.BeaconHold) * 10 + 0.5) / 10), CFG.BeaconRange)
		progress = holding and math.clamp((now - holdStart) / t.Hold, 0, 1) or 0
	else
		label, sub, ok = chestLines(t, state)
		progress = LootUI and LootUI.HoldProgress and LootUI.HoldProgress() or 0
		if not ok then
			label = "Open chest  ·  not enough gold"
		end
	end
	W.Set(ui.Label, label)
	W.Set(ui.Sub, sub)
	ui.Sub.TextColor3 = (not ok or now < interruptedUntil) and RunTheme.Danger or RunTheme.CreamMuted
	ui.Ring.Set(progress)
	-- the key hint follows the device
	local mode = InputPrompts.Mode()
	local keyText = mode == "Gamepad" and "X" or (mode == "Touch" and "HOLD" or "E")
	local keyLabel = ui.Key:FindFirstChild("Key")
	if keyLabel and keyLabel.Text ~= keyText then
		keyLabel.Text = keyText
	end
	ui.Key.Size = UDim2.fromOffset(mode == "Touch" and 46 or 36, 32)
	ui.KeyHolder.Visible = not (mode == "Touch" and t.Kind == "Revive")
	-- place above the equipment row, centred
	local v = kit.VirtualSize()
	local w = math.min(v.X - 24, UIKit.IsCompact() and 360 or 400)
	local bottom = (kit.EquipmentTop and kit.EquipmentTop() or (v.Y - 120)) - 12
	if kit.IsPortrait and kit.IsPortrait() and kit.Hud then
		-- portrait: the equipment row is under the top cluster; the prompt rides above the touch buttons instead
		local top = v.Y
		for _, name in ipairs({ "Revive", "Jump", "Stick" }) do
			local r = kit.Hud.RunRect(name)
			if r and r.W > 0 then
				top = math.min(top, r.Y)
			end
		end
		bottom = top - 10
	end
	ui.Panel.Size = UDim2.fromOffset(w, math.max(64, W.TouchPx(kit.Scale and kit.Scale() or 1)))
	ui.Panel.Position = UDim2.fromOffset(math.floor(v.X / 2 + 0.5), math.floor(bottom + 0.5))
	if not ui.Panel.Visible then
		ui.Panel.Visible = true
	end
end

function RunInteract.Elements(): { [string]: any }
	return { Panel = ui.Panel, Label = ui.Label, Sub = ui.Sub, Ring = ui.Ring, Key = ui.Key, Target = cur }
end

return RunInteract
