-- lobby-screens-regression: gamepad B on the lobby screens (LobbyScreen), the account
-- pill's ACCOUNT caption and the STATS screen's personal best score / level tiles.
--   B on a sub-screen goes back like its BACK button (More -> Home, Ranks -> More);
--   B on Home does nothing; B while the lobby SETTINGS panel is open closes only the panel
--   (the screen under it stays); B while a text box has focus is ignored.
-- Prints PASS / FAIL lines; run headless:
--   lune run tools/preview/runtime/main.luau -- --scene lobby-screens-regression --device pc --out <json>
local C = lib("common")
C.lobby()
C.startClient()
local profile = C.profile()
profile.Stats.BestScore = 48210
profile.Stats.BestLevel = 27
C.sendProfile(profile)
C.settle(1)
local UIS = game:GetService("UserInputService")
local Lobby = preview.client("LobbyScreen")
local UIBuilder = preview.client("UIBuilder")
local UIState = preview.client("UIState")
local fails = 0
local function check(ok: boolean, label: string, detail: string?)
	if not ok then
		fails += 1
	end
	preview.log(string.format("%s %s%s", ok and "PASS" or "FAIL", label, detail and (" (" .. detail .. ")") or ""))
end
local function pressB()
	local input = { UserInputType = Enum.UserInputType.Gamepad1, UserInputState = Enum.UserInputState.Begin, KeyCode = Enum.KeyCode.ButtonB, Position = Vector3.zero, Delta = Vector3.zero }
	UIS.InputBegan:_fire(input, false)
	C.settle(0.4)
	input.UserInputState = Enum.UserInputState.End
	UIS.InputEnded:_fire(input, false)
	C.settle(0.2)
end

pressB()
check(Lobby.Current() == "Home", "B on Home stays on Home", Lobby.Current())

Lobby.Show("More")
C.settle(0.5)
Lobby.Show("Ranks")
C.settle(0.5)
pressB()
check(Lobby.Current() == "More", "B on Ranks goes back to More", Lobby.Current())
pressB()
check(Lobby.Current() == "Home", "B on More goes back to Home", Lobby.Current())

Lobby.Show("Upgrades")
C.settle(0.5)
UIBuilder.OpenSettings()
C.settle(0.5)
check(UIState.IsOpen("Pause"), "lobby SETTINGS opened over Upgrades")
pressB()
check(not UIState.IsOpen("Pause"), "B closes the SETTINGS panel")
check(Lobby.Current() == "Upgrades", "the same B press does not also leave Upgrades", Lobby.Current())
pressB()
check(Lobby.Current() == "Home", "the next B leaves Upgrades", Lobby.Current())

-- the account level is labelled as the ACCOUNT level (not the hero badge's)
local caption = preview.findGui(function(g) return g.Name == "AccountCaption" end)[1]
check(caption ~= nil and caption.Text == "ACCOUNT" and preview.isShown(caption), "account pill says ACCOUNT over its LV")
-- STATS: personal best score and highest run level from the save
Lobby.Show("Stats")
C.settle(0.6)
local function valueOf(key: string): string?
	local tile = preview.findGui(function(g) return g.Name == key and g.Parent and g.Parent.Name == "StatsScroll" end)[1]
	local v = tile and tile:FindFirstChild("Value")
	return v and v.Text
end
check(valueOf("Score") == "48,210", "STATS shows the best score", tostring(valueOf("Score")))
check(valueOf("Level") == "LV 27", "STATS shows the highest run level", tostring(valueOf("Level")))

preview.log(fails == 0 and "lobby-screens-regression: all PASS" or string.format("lobby-screens-regression: %d FAIL", fails))
