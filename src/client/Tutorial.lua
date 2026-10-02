--[[
	Tutorial.lua
	First-run tips that teach through play (Config.Tutorial). A small card shows one hint
	at a time, dismisses itself after a few seconds and never pauses or blocks the run:
	the card is not Active (a thumb landing on it still moves the hero); only its small
	"Skip tips" button takes a tap.

	Tutorial tips (a player's first run; anyone with a run played before skips them):
	  Move      at the start: drag anywhere / WASD / left stick (by input device); done
	            early once the hero has walked a few steps
	  Attack    "your weapon attacks on its own"
	  Gems      after the first kill: gems are XP
	  LevelUp   the first level-up offer: one line under LEVEL UP! explains the cards
	            (UIBuilder asks LevelUpHint)
	  Portal    after Config.Tutorial.PortalTipAt run seconds: the stage objective
	  Boss      when the Queen appears: red floor shapes show where she strikes
	Co-op tips (once ever, also for experienced players):
	  TeamRules the first group run: what is shared and what is your own
	  Revive    the first time a teammate falls: stand in the gold circle

	Each hint shown is reported (Tutorial remote "Seen") so it never repeats; "Skip tips"
	ends the tutorial ("Skip"); Settings > Show tips switches every hint off and Settings >
	Replay tips ("Replay") shows them again from the next run. The server marks the
	tutorial done when the first run ends.
]]

local Players = game:GetService("Players")
local UserInputService = game:GetService("UserInputService")
local TextService = game:GetService("TextService")

local Shared = game:GetService("ReplicatedStorage"):WaitForChild("Shared")
local Config = require(Shared:WaitForChild("Config"))
local Remotes = require(Shared:WaitForChild("Remotes"))
local Theme = require(Shared:WaitForChild("Theme"))
local UIKit = require(script.Parent.UIKit)
local UIAnim = require(script.Parent.UIAnim)
local Icons = require(script.Parent.Icons)
local Hud = require(script.Parent.Hud)
local ClientSettings = require(script.Parent.ClientSettings)

local Tutorial = {}

local player = Players.LocalPlayer
local new, text, TS = UIKit.new, UIKit.text, UIKit.TS
local C, P = Theme.Color, Theme.Palette
local T = Config.Tutorial

local COOP = { TeamRules = true, Revive = true }

local kit: { [string]: any } = {}
local ui: { [string]: any } = {}
local tutorialDone = true -- until the profile says otherwise
local seen: { [string]: boolean } = {}
local queue: { { Id: string, Text: string, Title: string, Icon: string, Seconds: number } } = {}
local current: { [string]: any }? = nil
local nextAt = 0
local run: { [string]: any } = {} -- per-run trigger state

------------------------------------------------------------------------------------------
-- Eligibility
------------------------------------------------------------------------------------------

local function tipsOn(): boolean
	return ClientSettings.Get("Tips") ~= false
end

local function wants(id: string): boolean
	if not tipsOn() or seen[id] then
		return false
	end
	if COOP[id] then
		return true
	end
	return not tutorialDone
end

local function markSeen(id: string)
	if not seen[id] then
		seen[id] = true
		Remotes.Get("Tutorial"):FireServer("Seen", id)
	end
end

local function queued(id: string): boolean
	if current and current.Id == id then
		return true
	end
	for _, q in ipairs(queue) do
		if q.Id == id then
			return true
		end
	end
	return false
end

local function push(id: string, title: string, body: string, icon: string, seconds: number?, first: boolean?)
	if not wants(id) or queued(id) then
		return
	end
	table.insert(queue, first and 1 or (#queue + 1), { Id = id, Title = title, Text = body, Icon = icon, Seconds = seconds or T.HintSeconds })
end

------------------------------------------------------------------------------------------
-- The card
------------------------------------------------------------------------------------------

local function build(root: Frame)
	local holder, face = UIKit.Surface(root, { Name = "TipCard", Radius = Theme.Radius.L, Transparency = 0.06, Edge = P.gold_400, EdgeTransparency = 0.25, Visible = false, ZIndex = Theme.Z.Toast, AnchorPoint = Vector2.new(0.5, 1), Size = UDim2.fromOffset(520, 92) })
	holder.Active = false
	ui.Card = holder
	ui.Face = face
	UIKit.padding(face, 10, 12, 12, 12)
	local iconWell = new("Frame", { Name = "IconWell", BackgroundColor3 = C.PanelInset, BackgroundTransparency = 0.1, Size = UDim2.fromOffset(40, 40), Position = UDim2.fromOffset(0, 2) }, face)
	UIKit.corner(iconWell, 999)
	UIKit.stroke(iconWell, P.gold_500, 1.5, 0.3)
	ui.IconWell = iconWell
	ui.Title = text(face, "Label", "", { Name = "Title", Position = UDim2.fromOffset(52, 0), Size = UDim2.new(1, -52 - 140, 0, TS(12) + 4), TextColor3 = P.gold_300 }, 12)
	ui.Body = text(face, "BodyStrong", "", {
		Name = "Body",
		Position = UDim2.fromOffset(52, TS(12) + 4),
		Size = UDim2.new(1, -52, 1, -(TS(12) + 4)),
		TextWrapped = true,
		TextYAlignment = Enum.TextYAlignment.Top,
		TextColor3 = C.Text,
	}, 15)
	ui.Skip = UIKit.Button(face, {
		Kind = "Ghost",
		Title = "SKIP TIPS",
		TitleStyle = "Label",
		Align = "Center",
		AnchorPoint = Vector2.new(1, 0),
		Position = UDim2.new(1, 4, 0, -6),
		Size = UDim2.fromOffset(UIKit.IsCompact() and 136 or 112, 30),
		Shadow = false,
		Name = "SkipTips",
		OnClick = function()
			Tutorial.Skip()
		end,
	})
	-- time left: a thin gold line along the bottom edge
	ui.Timer = new("Frame", { Name = "Timer", BackgroundColor3 = P.gold_400, BorderSizePixel = 0, AnchorPoint = Vector2.new(0, 1), Position = UDim2.new(0, 0, 1, 10), Size = UDim2.new(1, 0, 0, 2) }, face)
end

local function cardHeight(body: string, w: number): number
	-- the body's wrapped height (1-3 lines), measured like Roblox lays it out
	local lineH = TS(15) + 3
	local lines = 2
	local ok, size = pcall(function()
		return TextService:GetTextSize(body, TS(15), Enum.Font.SourceSansSemibold, Vector2.new(w - 76, 1000))
	end)
	if ok and typeof(size) == "Vector2" then
		lines = math.clamp(math.ceil(size.Y / TS(15) - 0.2), 1, 3)
	end
	return 22 + TS(12) + 4 + lines * lineH
end

local function layout()
	if not ui.Card then
		return
	end
	local v: Vector2 = kit.VirtualSize()
	local W, H = v.X, v.Y
	local portrait: boolean = kit.IsPortrait()
	local w = math.min(UIKit.IsCompact() and 600 or 540, W - 32)
	local body = ui.Body.Text
	local h = cardHeight(body, w)
	ui.Card.Size = UDim2.fromOffset(w, h)
	local bottom
	if portrait then
		-- under the hero, above the thumbs' usual spot
		bottom = H * 0.72
	else
		-- over the ability bar (and over the status line when it shows)
		bottom = Hud.BarTop() - 10
		local els = Hud.Elements()
		if els.Buff and els.Buff.Visible then
			bottom -= 38
		end
		if els.Status and els.Status.Visible then
			bottom = math.min(bottom, els.Status.Position.Y.Offset - els.Status.Size.Y.Offset / 2 - 8)
		end
	end
	ui.Card.Position = UDim2.fromOffset(math.floor(W / 2), math.floor(bottom))
end

local function setIcon(name: string)
	for _, c in ipairs(ui.IconWell:GetChildren()) do
		if c:IsA("Frame") then
			c:Destroy()
		end
	end
	Icons.Draw(ui.IconWell, name, { Size = 24, AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.5), Back = P.slate_900 })
end

local function hideCard()
	if current then
		current = nil
		local card = ui.Card :: Frame
		UIAnim.PopOut(card, function()
			if not current then
				card.Visible = false
			end
		end)
	end
end

local function showNext(now: number)
	local tip = table.remove(queue, 1)
	if not tip then
		return
	end
	if not wants(tip.Id) then
		return
	end
	current = { Id = tip.Id, Until = now + tip.Seconds, Seconds = tip.Seconds, Since = now }
	ui.Title.Text = UIKit.track(tip.Title)
	ui.Body.Text = tip.Text
	setIcon(tip.Icon)
	layout()
	ui.Card.Visible = true
	UIAnim.Pop(ui.Card, 0, 0.85)
	markSeen(tip.Id)
	if kit.Audio then
		pcall(kit.Audio.Play, "Tip")
	end
end

------------------------------------------------------------------------------------------
-- Triggers
------------------------------------------------------------------------------------------

local function moveText(): string
	local last = UserInputService:GetLastInputType()
	local gamepad = string.find(tostring(last), "Gamepad") ~= nil
	if gamepad then
		return "Move with the left stick. That's all you control!"
	elseif UserInputService.TouchEnabled and not UserInputService.KeyboardEnabled then
		return "Drag anywhere on the screen to move. That's all you control!"
	end
	return "Move with WASD or the arrow keys. That's all you control!"
end

local function heroPos(): Vector3?
	local char = player.Character
	local root = char and char.PrimaryPart
	return root and root.Position or nil
end

local function startRun(state: Configuration)
	table.clear(run)
	run.Start = os.clock()
	run.StartPos = heroPos()
	run.Kills0 = player:GetAttribute("Kills") or 0
	push("Move", "How to play", moveText(), "boot")
	push("Attack", "Auto attack", "Your weapon attacks on its own. Keep moving and stay out of reach!", "sword")
end

local function triggers(state: Configuration)
	-- a group run: the team rules first (checked for a few seconds: the player count may
	-- arrive just after InRun)
	if not run.Team and os.clock() - (run.Start or 0) < 8 and (state:GetAttribute("Participants") or 1) > 1 then
		run.Team = true
		push(
			"TeamRules",
			"Team run",
			"XP from gems is shared by everyone still standing. Gold is your own: your kills and the Queen's reward. Items are your own too (the Guarded Altar gives one to each of you).",
			"people2",
			T.HintSeconds + 3,
			true
		)
	end
	-- gems after the first kill
	if not run.Gems and (player:GetAttribute("Kills") or 0) > (run.Kills0 or 0) then
		run.Gems = true
		push("Gems", "Experience", "Defeated enemies drop gold gems. Walk over them to collect XP and level up.", "gem")
	end
	-- the objective, a while into the run
	local runTime = state:GetAttribute("RunTime") or 0
	local stagePhase = state:GetAttribute("StagePhase") or "None"
	if not run.Portal and stagePhase == "Explore" and runTime >= T.PortalTipAt then
		run.Portal = true
		local lockLeft = state:GetAttribute("PortalLockLeft") or 0
		local wake = lockLeft > 0 and string.format(" It wakes in %s.", UIKit.formatTime(lockLeft)) or ""
		push("Portal", "Your goal", "Find the stone portal on this map." .. wake .. " Stand in its circle to summon the Scorpion Queen, then beat her to go deeper.", "portal", T.HintSeconds + 2)
	end
	if not run.Boss and stagePhase == "Boss" then
		run.Boss = true
		push("Boss", "The Queen", "Red shapes on the floor show where she strikes next. Step out of them before they fill!", "skull")
	end
	-- the first fallen teammate
	if not run.Revive then
		for _, p in ipairs(Players:GetPlayers()) do
			if p ~= player and p:GetAttribute("InRun") == true and p:GetAttribute("Alive") == false and (tonumber(p:GetAttribute("PartnerRevivesLeft")) or 0) > 0 and p:GetAttribute("AwaitingRevive") ~= true then
				run.Revive = true
				push("Revive", "Revive", string.format("%s is down! Stand inside the gold circle around them for a few seconds to bring them back.", p.DisplayName), "revive")
				break
			end
		end
	end
	-- Move ends early once the hero has walked a few steps
	if current and current.Id == "Move" and run.StartPos then
		local pos = heroPos()
		if pos and (pos - run.StartPos).Magnitude > 14 and os.clock() - current.Since > 2.5 then
			current.Until = math.min(current.Until, os.clock() + 0.6)
		end
	end
end

------------------------------------------------------------------------------------------
-- Public
------------------------------------------------------------------------------------------

-- Profile from ProfileSync: TutorialDone, SeenTips.
function Tutorial.SetProfile(p: { [string]: any })
	tutorialDone = p.TutorialDone ~= false
	if type(p.SeenTips) == "table" then
		-- the server's list plus whatever this session showed (its "Seen" may be in flight;
		-- Replay clears both)
		for id, on in pairs(p.SeenTips) do
			if on == true then
				seen[id] = true
			end
		end
	end
end

-- The first level-up offer's explanation (nil once seen or when tips are off).
function Tutorial.LevelUpHint(): string?
	if not wants("LevelUp") then
		return nil
	end
	markSeen("LevelUp")
	return "Tap a card: a new weapon, an upgrade or a passive"
end

-- "Skip tips": no more tutorial hints (co-op tips stay until seen or Show tips is off).
function Tutorial.Skip()
	tutorialDone = true
	for i = #queue, 1, -1 do
		if not COOP[queue[i].Id] then
			table.remove(queue, i)
		end
	end
	hideCard()
	Remotes.Get("Tutorial"):FireServer("Skip")
end

-- Settings > Replay tips: every hint again from the next run.
function Tutorial.Replay()
	tutorialDone = false
	table.clear(seen)
	Remotes.Get("Tutorial"):FireServer("Replay")
end

-- Hides everything (run end, tips switched off).
function Tutorial.Clear()
	table.clear(queue)
	hideCard()
end

--[[
	Per frame. blocked = a modal is open (level-up cards, pause, results): the current hint
	waits (its clock stops) and no new one starts.
]]
function Tutorial.Update(_dt: number, state: Configuration, inRun: boolean, blocked: boolean)
	if not ui.Card then
		return
	end
	local now = os.clock()
	if not inRun or not tipsOn() then
		if run.Start then
			table.clear(run)
		end
		Tutorial.Clear()
		return
	end
	if not run.Start then
		startRun(state)
		nextAt = now + T.FirstDelay
	end
	if (state:GetAttribute("Phase") or "") ~= "Running" then
		Tutorial.Clear()
		return
	end
	triggers(state)
	if current then
		if blocked then
			current.Until += _dt
			ui.Card.Visible = false
			return
		end
		ui.Card.Visible = true
		local left = math.max(0, current.Until - now)
		ui.Timer.Size = UDim2.new(math.clamp(left / current.Seconds, 0, 1), 0, 0, 2)
		if left <= 0 then
			hideCard()
			nextAt = now + T.GapSeconds
		end
	elseif not blocked and now >= nextAt and #queue > 0 then
		showNext(now)
	end
end

function Tutorial.Build(root: Frame, k: { [string]: any })
	kit = k
	build(root)
	kit.OnRelayout(layout)
	ClientSettings.OnChanged(function(key, value)
		if key == "Tips" and value == false then
			Tutorial.Clear()
		end
	end)
end

-- For the preview tool / tests.
function Tutorial.Elements(): { [string]: any }
	return ui
end

return Tutorial
