-- Native offline regression checks for button input and icon lifecycle.
local process = require("@lune/process")
local Mock = require("./preview/runtime/mock")
local R, S = Mock.R, Mock.S
local preview = Mock.boot({ device = process.args[1] or "phone", seed = 7, repo = process.cwd, root = process.cwd .. "/tools/preview", fontMetrics = nil })
local failures = 0
local function check(name, on)
	print((on and "PASS " or "FAIL ") .. name)
	if not on then failures += 1 end
end
local ok, err = S.runMain(function()
	preview.startClient(false)
	preview.shared("Remotes").Setup()
	local env = R.envFor(nil)
	local Instance, UDim2 = env.Instance, env.UDim2
	local gui = Instance.new("ScreenGui")
	gui.Parent = preview.playerGui()
	local root = Instance.new("Frame")
	root.Size = UDim2.fromOffset(600, 400)
	root.Parent = gui
	local scale = Instance.new("UIScale")
	scale.Scale = 0.5
	scale.Parent = root
	local UIKit = preview.client("UIKit")
	local got
	local button = UIKit.Button(root, { Title = "Touch", OnClick = function(input) got = input end })
	local input = { UserInputType = env.Enum.UserInputType.Touch }
	button.Instance.Activated:_fire(input)
	preview.advance(0.05)
	check("button forwards exact activating touch", got == input)
	local IdleFx = preview.client("IdleFx")
	local settings = preview.client("ClientSettings")
	local icon = Instance.new("ImageLabel")
	icon.Size = UDim2.fromOffset(80, 80)
	icon.Position = UDim2.fromOffset(100, 40)
	icon.AnchorPoint = env.Vector2.new(0.5, 0.5)
	icon.Parent = root
	IdleFx.Attach(icon, "Sun")
	preview.advance(0.3)
	local glow = root:FindFirstChild("IdleGlow")
	check("scaled glow stays centered in parent units", glow ~= nil and math.abs(glow.Position.X.Offset - 100) < 2 and glow.Size.X.Offset > 60)
	IdleFx.Stop(icon)
	IdleFx.Attach(icon, "Hammer", { Period = 0.4 })
	local deformed = false
	for _ = 1, 30 do
		preview.advance(1 / 60)
		if icon.Size ~= UDim2.fromOffset(80, 80) then deformed = true; break end
	end
	check("hammer runs before reduced-effects transition", deformed)
	settings.Set("ReducedEffects", true)
	preview.advance(0.3)
	check("reduced effects restores rest size", icon.Size == UDim2.fromOffset(80, 80))
	root.Visible = false
	preview.advance(0.3)
	check("hidden icons stop animating", IdleFx.Stats().Shown == 0)
	icon:Destroy()
	preview.advance(0.3)
	check("destroyed icon releases entry and heartbeat", IdleFx.Count() == 0 and IdleFx.Stats().Loop == 0)
	root.Visible = true
	settings.Set("ReducedEffects", false)
	local UIAnim = preview.client("UIAnim")
	local stopMotes = UIAnim.Motes(root, 3)
	local performance = preview.client("ClientPerformance")
	for _ = 1, 60 do performance.Step(0.1) end
	preview.advance(0.6)
	check("adaptive budget suppresses existing decorative motes", root.Motes.Visible == false and settings.Reduced() == false)
	for _ = 1, 1000 do performance.Step(1 / 60) end
	preview.advance(0.6)
	check("decoration recovers without changing saved setting", root.Motes.Visible == true and settings.Reduced() == false)
	stopMotes()
	local TeamUI = preview.client("TeamUI")
	TeamUI.Build(root, { OnRelayout = function() end, VirtualSize = function() return env.Vector2.new(600, 400) end, IsPortrait = function() return false end, Scale = function() return 1 end, GuiOffset = function() return env.Vector2.zero end })
	local me = R.localPlayer
	local mate = preview.addPlayer(77, "Fallen")
	for i, p in ipairs({ me, mate }) do
		local char = Instance.new("Model")
		char.Parent = R.services.Workspace
		local part = Instance.new("Part")
		part.Position = env.Vector3.new(i, 0, 0)
		part.Parent = char
		char.PrimaryPart = part
		p.Character = char
		p:SetAttribute("InRun", true)
		p:SetAttribute("Alive", p == me)
		p:SetAttribute("PartnerRevivesLeft", 1)
	end
	local state = preview.shared("Remotes").State()
	state:SetAttribute("Mode", "Duo")
	state:SetAttribute("Phase", "Running")
	state:SetAttribute("Participants", 2)
	TeamUI.Update(0.1, state, true)
	local revive = root:FindFirstChild("HoldRevive")
	check("nearby fallen teammate exposes held revive control", revive ~= nil and revive.Visible)
	if revive then
		local active
		preview.remote("ReviveHold").OnServerEvent:Connect(function(_player, on) active = on end)
		local finger = { UserInputType = env.Enum.UserInputType.Touch }
		revive.InputBegan:_fire(finger)
		preview.advance(0.05)
		check("revive starts only on a held press", active == true)
		R.services.UserInputService.WindowFocusReleased:_fire()
		preview.advance(0.05)
		check("focus loss cancels held revive", active == false)
		revive.InputBegan:_fire(finger)
		preview.advance(0.05)
		mate.Character.PrimaryPart.Position = env.Vector3.new(100, 0, 0)
		TeamUI.Update(0.1, state, true)
		preview.advance(0.05)
		check("leaving revive range cancels held press", active == false and not revive.Visible)
	end
	local UI = preview.client("UIBuilder")
	UI.Init({})
	preview.advance(0.2)
	local guiRoot = preview.playerGui():FindFirstChild("SwarmUI").Root
	local offer = { PanelId = 1, BatchTotal = 4, BatchRemaining = 4, Pending = 7, Seconds = 25, Choices = { { Type = "Gold", Name = "Gold", Text = "+20 gold", Amount = 20 } } }
	preview.fireClient("LevelUpOffer", offer)
	preview.advance(1)
	local cards = guiRoot.LevelUp.Panel.Cards
	check("first grouped choice finishes entrance", cards.Card1:FindFirstChild("AnimScale").Scale == 1)
	offer.BatchRemaining = 3
	offer.Seconds = 24
	preview.fireClient("LevelUpOffer", offer)
	preview.advance(0.01)
	check("same panel next choice never replays entrance", cards.Card1:FindFirstChild("AnimScale") == nil or cards.Card1:FindFirstChild("AnimScale").Scale == 1)
	local uis = R.services.UserInputService
	local unsafe = { UserInputType = env.Enum.UserInputType.Touch, KeyCode = env.Enum.KeyCode.Unknown, Position = env.Vector3.new(500, 100, 0) }
	uis.InputBegan:_fire(unsafe, false)
	preview.advance(0.05)
	offer.PanelId = 2
	offer.Rerolls = 1
	preview.fireClient("LevelUpOffer", offer)
	preview.advance(1)
	local fresh = { UserInputType = env.Enum.UserInputType.Touch, KeyCode = env.Enum.KeyCode.Unknown, Position = env.Vector3.new(500, 100, 0) }
	uis.InputBegan:_fire(fresh, false)
	preview.advance(0.05)
	uis.InputEnded:_fire(fresh)
	preview.advance(0.01)
	local reroll
	for _, d in ipairs(guiRoot.LevelUp:GetDescendants()) do
		if d:IsA("TextLabel") and d.Text == "REROLL" then
			reroll = d.Parent
			while reroll and not reroll:IsA("GuiButton") do reroll = reroll.Parent end
			break
		end
	end
	local rerolls = 0
	preview.remote("LevelUpReroll").OnServerEvent:Connect(function() rerolls += 1 end)
	assert(reroll, "reroll button exists")
	reroll.Activated:_fire(unsafe)
	preview.advance(0.1)
	check("ongoing movement touch cannot borrow another touch to reroll", rerolls == 0)
	preview.fireClient("LevelUpClose")
	preview.advance(0.5)
	UI.ShowChest({ Dramatic = false, Gold = 20, Rewards = {} })
	preview.advance(0.05)
	check("ordinary chest never opens reward overlay", guiRoot.Reward.Visible == false)
	UI.ShowChest({ Dramatic = true, Gold = 50, Rewards = {} })
	preview.advance(0.05)
	check("rare chest opens established dramatic reel", guiRoot.Reward.Visible == true)
	state:SetAttribute("StagePhase", "Open")
	preview.fireClient("PortalOffer", { Complete = true, Stage = 5, StagesCleared = 5, CountsAsWin = true })
	preview.advance(0.1)
	local stage = preview.client("StageUI").Elements()
	check("Standard completion removes deeper-stage action", stage.Next.Instance.Visible == false and stage.Return.Instance.Visible == true)
	local loot = Instance.new("Folder")
	loot.Name = "SwarmLoot"
	loot.Parent = R.services.Workspace
	local altar = Instance.new("Model")
	altar.Parent = loot
	for key, value in pairs({ LootKind = "Altar", State = "Dormant", Pos = me.Character.PrimaryPart.Position, LootId = 1, Hold = 0.4, Price = 0, Title = "Guarded altar" }) do altar:SetAttribute(key, value) end
	local LootUI = preview.client("LootUI")
	LootUI.Update(0.1, true)
	check("optional elite altar requires explicit usable hold", LootUI.Elements().HoldButton.Visible == true)
	local config = preview.shared("Config")
	local markerCount = config.Chests.SmallCount[2] + config.Chests.LargeCount[2] + config.Chests.GoldenCount + config.Shrines.ChanceCount[2] + config.Shrines.BargainCount + 4
	for i = 1, markerCount do
		local marker = Instance.new("Model")
		marker.Parent = loot
		marker:SetAttribute("Pos", env.Vector3.new(i, 0, 1))
		marker:SetAttribute("State", "Ready")
		marker:SetAttribute("LootKind", "Shrine")
	end
	local map = preview.client("MiniMap")
	map.SetCovered(false)
	preview.advance(0.2)
	map.Update(0.1, state, true)
	local marked = 0
	for _, dot in ipairs(map.Elements().Loot) do if dot.Visible then marked += 1 end end
	check("minimap retains every natural stage loot location", marked == markerCount)
end, 10)
assert(ok, err)
assert(#R.log.errors == 0, "mock runtime errors")
assert(failures == 0, tostring(failures) .. " UI regressions")


