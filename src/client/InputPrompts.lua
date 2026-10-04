--[[
	InputPrompts.lua
	One place for input-aware prompt text, so every screen says "Tap", "Click" or
	"Press A" the same way and follows the device the player is actually using right now
	(the LAST input, not what the device could do: many PCs report TouchEnabled or
	GamepadEnabled, and a phone with a controller should read gamepad prompts).

	Mode()             "Touch" | "Gamepad" | "Mouse" (keyboard and mouse)
	OnChanged(fn)      fn(mode) whenever the mode changes; returns the connection
	Verb()             "Tap" | "Click" | "Press A"            (a plain press)
	ToSkip()           "Tap to skip" | "Click or press Space to skip" | "Press A to skip"
	ToClose()          "Tap to close" | "Click to close" | "Press A to close"
	ToContinue()       "Tap to continue" | "Click to continue" | "Press A to continue"
	HoldKey()          "" | "E" | "X"                          (the interact key, if any)
	Hold(action?)      "Hold" | "Hold E" | "Hold X", plus " to <action>" when given
	Back()             "Tap BACK" | "Click BACK" | "Press B"    (leave a screen / cancel)
	Choose(count)      "Tap a card to choose" | "Press 1, 2 or 3 to choose" | "Press A to choose"
	PickCard()         "Tap a card" | "Click a card or press 1-3" | "Pick a card with A"
	Move()             how to move and jump with the current device (one short sentence)

	Bindings these texts describe (keep them in step when a binding changes):
	  confirm / skip   Touch tap, mouse click, Space / Enter, gamepad A (UIBuilder level-up
	                   and reward reel)
	  card shortcuts   keys 1 / 2 / 3 (/ 4) on the level-up cards (UIBuilder)
	  interact (hold)  E or gamepad X (LootUI)
	  back             gamepad B (pause menu); on-screen BACK buttons for touch and mouse
	  jump             Space, gamepad A, the on-screen JUMP button (JumpController)
	Text comes back in sentence case; callers upper-case or UIKit.track it as their style
	needs. No special glyphs: only plain letters and digits, which every font draws.
]]

local UserInputService = game:GetService("UserInputService")

local InputPrompts = {}

export type Mode = "Touch" | "Gamepad" | "Mouse"

local function fromInput(t: Enum.UserInputType): Mode?
	if t == Enum.UserInputType.Touch then
		return "Touch"
	elseif string.sub(t.Name, 1, 7) == "Gamepad" then
		return "Gamepad"
	elseif t == Enum.UserInputType.Keyboard or string.sub(t.Name, 1, 5) == "Mouse" then
		return "Mouse"
	end
	return nil -- Focus, Accelerometer, None ...: says nothing about the device in hand
end

local lastMode: Mode? = nil

-- The device the player is using right now.
function InputPrompts.Mode(): Mode
	local m = fromInput(UserInputService:GetLastInputType())
	if m then
		lastMode = m
		return m
	end
	if lastMode then
		return lastMode
	end
	if UserInputService.TouchEnabled and not UserInputService.KeyboardEnabled then
		return "Touch"
	elseif UserInputService.GamepadEnabled and not UserInputService.KeyboardEnabled and not UserInputService.MouseEnabled then
		return "Gamepad"
	end
	return "Mouse"
end

-- Calls fn(mode) when the device in hand changes (not on every input).
function InputPrompts.OnChanged(fn: (Mode) -> ()): RBXScriptConnection
	local current = InputPrompts.Mode()
	return UserInputService.LastInputTypeChanged:Connect(function()
		local m = InputPrompts.Mode()
		if m ~= current then
			current = m
			fn(m)
		end
	end)
end

local function pick(touch: string, mouse: string, pad: string): string
	local m = InputPrompts.Mode()
	if m == "Touch" then
		return touch
	elseif m == "Gamepad" then
		return pad
	end
	return mouse
end

function InputPrompts.Verb(): string
	return pick("Tap", "Click", "Press A")
end

function InputPrompts.ToSkip(): string
	return pick("Tap to skip", "Click or press Space to skip", "Press A to skip")
end

function InputPrompts.ToClose(): string
	return pick("Tap to close", "Click to close", "Press A to close")
end

function InputPrompts.ToContinue(): string
	return pick("Tap to continue", "Click to continue", "Press A to continue")
end

function InputPrompts.HoldKey(): string
	return pick("", "E", "X")
end

function InputPrompts.Hold(action: string?): string
	local key = InputPrompts.HoldKey()
	local s = key ~= "" and ("Hold " .. key) or "Hold"
	if action and action ~= "" then
		s ..= " to " .. action
	end
	return s
end

function InputPrompts.Back(): string
	return pick("Tap BACK", "Click BACK", "Press B")
end

-- How to pick one of `count` level-up cards.
function InputPrompts.Choose(count: number): string
	local m = InputPrompts.Mode()
	if m == "Touch" then
		return "Tap a card to choose"
	elseif m == "Gamepad" then
		return "Press A to choose"
	end
	local keys = {}
	for i = 1, math.max(1, count) do
		table.insert(keys, tostring(i))
	end
	local last = table.remove(keys) :: string
	return #keys > 0 and string.format("Press %s or %s to choose", table.concat(keys, ", "), last) or string.format("Press %s to choose", last)
end

-- The start of a short "pick a card" instruction (tutorial line under LEVEL UP!).
function InputPrompts.PickCard(): string
	return pick("Tap a card", "Click a card or press 1-3", "Pick a card with A")
end

function InputPrompts.Move(): string
	return pick(
		"Drag anywhere to move. Tap JUMP to hop over trouble.",
		"Move with WASD or the arrow keys. Space jumps; chain hops for speed!",
		"Move with the left stick. A jumps; chain hops for speed!"
	)
end

return InputPrompts
