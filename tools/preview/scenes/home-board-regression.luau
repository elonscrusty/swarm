-- home-board-regression: the home screen's TOP SCORES panel (HomeBoard).
--   the home screen asks for the High Score board; the rows show (ties share a rank), your
--   line reads "You #12 · 2,210" / "Beat #11 by 36"; empty and error states; a tap opens
--   RANKS on HIGH SCORE; a UIState panel (SETTINGS) hides it. Prints PASS / FAIL lines:
--   lune run tools/preview/runtime/main.luau -- --scene home-board-regression --device iphone --out <json>
local C = lib("common")
C.lobby()
local asks = 0
preview.remote("LeaderboardRequest").OnServerEvent:Connect(function(_p, board)
	if board == "Score" then
		asks += 1
	end
end)
C.startClient()
C.sendProfile()
C.settle(1)
local Lobby = preview.client("LobbyScreen")
local HB = preview.client("HomeBoard")
local UIBuilder = preview.client("UIBuilder")
local fails = 0
local function check(ok: boolean, label: string, detail: string?)
	if not ok then
		fails += 1
	end
	preview.log(string.format("%s %s%s", ok and "PASS" or "FAIL", label, detail and (" (" .. detail .. ")") or ""))
end
local function find(name: string, parent: Instance?): GuiObject?
	local list = preview.findGui(function(g)
		return g.Name == name and (parent == nil or g:IsDescendantOf(parent))
	end)
	return list[1]
end

check(asks >= 1, "the home screen asks for the High Score board", tostring(asks) .. " asks")
local rows = {}
local names = { "Ava", "Bramblewick", "Kestrel", "Moonpetal", "Ironjaw", "Thistle" }
for i, n in ipairs(names) do
	table.insert(rows, { Rank = i == 5 and 4 or i, UserId = 2000 + i, Name = n, Value = i == 5 and 60000 or (100000 - i * 10000), Me = false })
end
rows[6].Value = 2245
table.insert(rows, { Rank = 7, UserId = 1, Name = "PreviewPlayer", Value = 2210, Me = true })
C.fire("LeaderboardData", { Board = "Score", Rows = rows, Status = "ok", Top = 50, MyRank = 7, MyBoard = 2210, MyBest = 2210 })
C.settle(1)
local board = find("HomeBoard")
check(board ~= nil and preview.isShown(board), "TOP SCORES shows on the home screen")
local row1 = board and find("Row1", board)
local n1 = row1 and find("Name", row1)
check(n1 ~= nil and (n1 :: any).Text == "Ava" and preview.isShown(row1 :: GuiObject), "row 1 shows the leader", n1 and (n1 :: any).Text)
local row5 = board and find("Row5", board)
local r5 = row5 and find("Rank", row5)
check(r5 ~= nil and (r5 :: any).Text == "#4", "a tie shares the rank", r5 and (r5 :: any).Text)
local you = board and find("You", board)
local hook = board and find("Hook", board)
check(you ~= nil and (you :: any).Text == "You #7 · 2,210", "own rank line", you and (you :: any).Text)
check(hook ~= nil and (hook :: any).Text == "Beat #6 by 36", "points to pass the next player", hook and (hook :: any).Text)

-- pure lines
local a, b = HB.OwnLine({ Rows = { { Rank = 1, Value = 900, Me = true } }, MyRank = 1, MyBoard = 900, MyBest = 900 })
check(a == "You #1 · 900" and b == "You hold the top spot!", "#1 line", a .. " / " .. b)
local full = {}
for i = 1, 50 do
	table.insert(full, { Rank = i, Value = 10000 - i })
end
a, b = HB.OwnLine({ Rows = full, MyBest = 120, Top = 50 })
check(a == "You · 120" and b == "#50 needs 9,951", "not in the top 50", a .. " / " .. b)
check(HB.StateText({ Rows = {}, Status = "ok" }) == "Be the first on the board!", "empty board line")
check(HB.StateText({ Rows = {}, Status = "error" }) ~= nil and not string.find(HB.StateText({ Rows = {}, Status = "error" }) :: string, "first"), "error line never says be the first")

-- a failed re-read keeps the rows we had
C.fire("LeaderboardData", { Board = "Score", Rows = {}, Status = "error", Top = 50 })
C.settle(0.5)
check(n1 ~= nil and (n1 :: any).Text == "Ava" and preview.isShown(row1 :: GuiObject), "an error keeps the last rows")

-- UIState: SETTINGS over home hides the panel
UIBuilder.OpenSettings()
C.settle(0.5)
check(board ~= nil and not preview.isShown(board), "hidden while SETTINGS is open")
do -- gamepad B closes the panel (as in lobby-screens-regression)
	local UIS = game:GetService("UserInputService")
	local input = { UserInputType = Enum.UserInputType.Gamepad1, UserInputState = Enum.UserInputState.Begin, KeyCode = Enum.KeyCode.ButtonB, Position = Vector3.zero, Delta = Vector3.zero }
	UIS.InputBegan:_fire(input, false)
	C.settle(0.4)
	input.UserInputState = Enum.UserInputState.End
	UIS.InputEnded:_fire(input, false)
	C.settle(0.6)
end
check(board ~= nil and preview.isShown(board), "back after SETTINGS closes")

-- tap opens RANKS on HIGH SCORE
if board then
	preview.click(board)
end
C.settle(0.6)
check(Lobby.Current() == "Ranks", "a tap opens RANKS", Lobby.Current())
check(board ~= nil and not preview.isShown(board), "hidden on another screen")
Lobby.Show("Home")
C.settle(0.6)

-- an empty board: the friendly line, no rows
C.fire("LeaderboardData", { Board = "Score", Rows = {}, Status = "ok", Top = 50, MyBest = 0 })
C.settle(0.5)
local state = board and find("State", board)
check(state ~= nil and (state :: any).Text == "Be the first on the board!" and preview.isShown(state :: GuiObject), "empty board shows the friendly line")
check(row1 ~= nil and not preview.isShown(row1 :: GuiObject), "empty board shows no rows")
preview.log(fails == 0 and "PASS home board: all checks" or ("FAIL home board: " .. fails .. " failed"))
