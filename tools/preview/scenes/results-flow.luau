-- results-flow: the client side of the return flow after a run (UIBuilder results +
-- TravelOverlay), against attributes set the way RunManager / RunServers set them. Prints
-- PASS / FAIL (docs/overhaul/FLOW.md; review Short 2:04: a lobby with a stale "Back to the
-- lobby in 2s", then another loading screen).
--   --set case=auto (default)  run server: the defeat results run out; the server ends the
--                              run and raises the travel cover in the same step. The
--                              results stay under the cover: no lobby, no second countdown.
--   --set case=stay            run server: STAY sends TravelHome "Hold"; back in the lobby
--                              the results stay open with no timer; MAIN MENU sends "Go"
--                              and the results wait for the cover.
--   --set case=replay          run server: REPLAY sends ReturnToLobby "Replay" once.
--   --set case=portal          run server, results over the lobby menu with TravelHomeIn:
--                              the footer shows that countdown, the banner stays hidden.
--   --set case=plain           not a run server (Studio, fallback): "Back to the lobby in
--                              Ns", the results close when the server returns the player.
-- Run: render.sh results-flow --devices pc --set case=stay
local C = lib("common")
C.lobby()
local case = preview.args.case or "auto"
local runServer = case ~= "plain"
local Players = game:GetService("Players")
local me = Players.LocalPlayer
C.setState({ Phase = "Results", RunServer = runServer })
C.setPlayer({ InRun = case ~= "portal" })
C.startClient()
C.sendProfile()
C.settle(1)

local fails = 0
local function check(label: string, ok: boolean, detail: string?)
	if not ok then
		fails += 1
	end
	preview.log(string.format("%s  %s%s", ok and "PASS" or "FAIL", label, detail and ("  (" .. detail .. ")") or ""))
end

local sent: { string } = {}
for _, name in ipairs({ "TravelHome", "ReturnToLobby" }) do
	preview.remote(name).OnServerEvent:Connect(function(_p, arg)
		table.insert(sent, name .. ":" .. tostring(arg))
	end)
end
local function sentText(): string
	return table.concat(sent, ",")
end

local TO = preview.client("TravelOverlay")
local function overlay(): GuiObject?
	return preview.findGui(function(obj)
		return obj.Name == "Results" and obj:IsA("Frame") and obj:FindFirstChild("Panel") ~= nil
	end)[1]
end
local function visible(): boolean
	local o = overlay()
	return o ~= nil and o.Visible and not o:GetAttribute("Hiding")
end
local function timerText(): string
	local o = overlay()
	local footer = o and o:FindFirstChild("Footer", true)
	if not footer then
		return "-"
	end
	for _, ch in ipairs(footer:GetChildren()) do
		if ch:IsA("TextLabel") then
			return ch.Text
		end
	end
	return "-"
end
local function button(pattern: string): GuiButton?
	local o = overlay()
	for _, g in ipairs(preview.findGui(function(obj)
		local ok, t = pcall(function()
			return obj.Text
		end)
		return ok and type(t) == "string" and string.find(string.upper(t), pattern) ~= nil and o ~= nil and obj:IsDescendantOf(o)
	end)) do
		local b = g:IsA("GuiButton") and g or g:FindFirstAncestorWhichIsA("GuiButton")
		if b then
			return b
		end
	end
	return nil
end

C.fire("RunResult", {
	Won = false, Portal = case == "portal", InLobby = case == "portal", Time = 109, Kills = 165, Gold = 176, GoldEarned = 505, GoldLost = 329,
	GoldRetention = 0.35, Difficulty = "Standard", Level = 12, Damage = 18200, Arena = "Forest", Mode = "Solo",
	CharacterId = "Knight", Build = { Weapons = { { Id = "Whip", Level = 4, Evolved = false } }, Passives = {} },
	BossKills = 0, BossFight = false, Seconds = 12, StagesCleared = 0, Stage = 1, Items = {}, Curses = {}, CurseGold = 1,
})
if case == "portal" then
	C.setState({ Phase = "Lobby" })
	C.setPlayer({ TravelHomeIn = 18 })
end
C.settle(1)
check("results up", visible())

if case == "auto" then
	check("footer: the real destination", string.find(timerText(), "MAIN LOBBY IN") ~= nil, timerText())
	check("STAY offered", button("^STAY$") ~= nil)
	-- the server ends the run: InRun = false and Travel = "ToLobby" in the same step
	C.setPlayer({ InRun = false, Travel = "ToLobby" })
	C.setState({ Phase = "Lobby" })
	preview.advance(0.6, 30)
	local d = TO.Debug()
	check("results stay under the cover (no bare lobby)", visible() and d.Cover, tostring(visible()) .. " / " .. tostring(d.Cover))
	check("no go-home banner", not d.Banner)
	check("footer says where it is going", string.find(timerText(), "GOING TO THE MAIN LOBBY") ~= nil, timerText())
	check("no remote sent by the client", #sent == 0, sentText())
elseif case == "stay" then
	local stay = button("^STAY$")
	check("STAY offered", stay ~= nil)
	if stay then
		preview.click(stay)
	end
	preview.advance(0.3, 30)
	check("STAY → TravelHome Hold", sentText() == "TravelHome:Hold", sentText())
	check("STAY hides itself", button("^STAY$") == nil or not (button("^STAY$") :: GuiButton).Visible)
	-- the results phase ends without a trip (held): back in this server's lobby
	C.setPlayer({ InRun = false })
	C.setState({ Phase = "Lobby" })
	preview.advance(15, 30)
	check("results still open long after the old timer", visible(), timerText())
	check("footer: no countdown", string.find(timerText(), "STAYS OPEN") ~= nil, timerText())
	local menu = button("MAIN MENU")
	if menu then
		preview.click(menu)
	end
	preview.advance(0.3, 30)
	check("MAIN MENU → TravelHome Go (once)", sentText() == "TravelHome:Hold,TravelHome:Go", sentText())
	check("results wait for the cover", visible() and string.find(timerText(), "GOING TO THE MAIN LOBBY") ~= nil, timerText())
	C.setPlayer({ Travel = "ToLobby" })
	preview.advance(0.5, 30)
	check("cover up over the results", TO.Debug().Cover and visible())
elseif case == "replay" then
	local replay = button("REPLAY")
	if replay then
		preview.click(replay)
	end
	preview.advance(0.5, 30)
	check("REPLAY → ReturnToLobby Replay, once", sentText() == "ReturnToLobby:Replay", sentText())
	check("results closed for the new run", not visible())
elseif case == "portal" then
	check("footer: the trip countdown", string.find(timerText(), "MAIN LOBBY IN 18S") ~= nil, timerText())
	check("banner hidden while the results show it", not TO.Debug().Banner)
	preview.advance(14, 30)
	check("results do not close on their own 12 s timer", visible(), timerText())
else
	check("footer: back to the lobby", string.find(timerText(), "BACK TO THE LOBBY IN") ~= nil, timerText())
	C.setPlayer({ InRun = false })
	C.setState({ Phase = "Lobby" })
	preview.advance(0.6, 30)
	check("results close when returned", not visible())
	check("no cover off a run server", not TO.Debug().Cover)
end

preview.log(fails == 0 and "ALL PASS" or (fails .. " FAIL"))
assert(fails == 0, tostring(fails) .. " results-flow checks failed")
