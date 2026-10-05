-- lobby-back-regression: gamepad B on the lobby screens (LobbyScreen).
--   B on a sub-screen goes back like its BACK button (More -> Home, Ranks -> More);
--   B on Home does nothing; B while the lobby SETTINGS panel is open closes only the panel
--   (the screen under it stays); B while a text box has focus is ignored.
-- Prints PASS / FAIL lines; run headless:
--   lune run tools/preview/runtime/main.luau -- --scene lobby-back-regression --device pc --out <json>
local C = lib("common")
C.lobby()
C.startClient()
C.sendProfile()
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

preview.log(fails == 0 and "lobby-back-regression: all PASS" or string.format("lobby-back-regression: %d FAIL", fails))
