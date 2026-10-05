-- hud-key-regression: the HUD's B / gamepad Y build-details key (Hud) only works with no
-- panel owning input: it toggles the BUILD details on the plain HUD, and does nothing while
-- the run menu drawer is open (that drawer leaves the HUD visible). Prints PASS / FAIL lines.
local A = lib("arena")
local C = lib("common")
A.build({ enemies = 10, seconds = 120 })
C.settle(2)
local UIS = game:GetService("UserInputService")
local Hud = preview.client("Hud")
local UIBuilder = preview.client("UIBuilder")
local UIState = preview.client("UIState")
local fails = 0
local function check(ok: boolean, label: string)
	if not ok then
		fails += 1
	end
	preview.log((ok and "PASS " or "FAIL ") .. label)
end
local function press(key)
	local input = { UserInputType = Enum.UserInputType.Keyboard, UserInputState = Enum.UserInputState.Begin, KeyCode = key, Position = Vector3.zero, Delta = Vector3.zero }
	UIS.InputBegan:_fire(input, false)
	C.settle(0.3)
end
local function buildOpen(): boolean
	return Hud.Elements().BuildOpen == true
end

press(Enum.KeyCode.B)
check(buildOpen(), "B opens the BUILD details on the plain HUD")
press(Enum.KeyCode.B)
check(not buildOpen(), "B closes them again")

UIBuilder.OpenPause()
C.settle(0.5)
check(UIState.IsShown("Pause"), "the run menu drawer is open")
press(Enum.KeyCode.B)
check(not buildOpen(), "B does nothing behind the run menu drawer")
UIBuilder.ClosePause()
C.settle(0.5)
press(Enum.KeyCode.B)
check(buildOpen(), "B works again once the drawer closed")

preview.log(fails == 0 and "hud-key-regression: all PASS" or string.format("hud-key-regression: %d FAIL", fails))
