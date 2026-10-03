-- menu: the lobby world at dusk, the lobby home screen, camera at the MenuCamera part.
--   --set save=failing|memory   the server says progress isn't being saved (SaveStatus):
--                               the lobby's save notice
--   --set drag=90               the hero turned by this many degrees (Showcase.Spin, as a drag would)
--   --set drag=input            a real drag over the hero through UserInputService events
--                               (right across the hero; prints whether the press was taken)
--   --set endless=on             the ENDLESS switch is on (player attribute Endless)
--   --set lastrun=won|fell|left  the profile carries a LastRun (the LAST RUN card + RETRY);
--                               --set lastmode=Duo its mode; --set retry=on taps RETRY and
--                               prints the StartRun the server received
local C = lib("common")
C.lobby()
C.startClient()
local profile = C.profile()
if preview.args.lastrun then
	local kind = preview.args.lastrun
	profile.LastRun = {
		Won = kind == "won", Portal = kind == "won", Mode = preview.args.lastmode or "Solo", CharacterId = "Knight",
		Time = 754, Stage = kind == "won" and 5 or 3, StagesCleared = kind == "won" and 5 or 2, Kills = 1284, Level = 19,
		Gold = 215, Difficulty = "Standard", DeathCause = kind == "fell" and "Briar Sentinel" or nil,
	}
end
C.sendProfile(profile)
if preview.args.retry == "on" then
	local got = nil
	preview.remote("StartRun").OnServerEvent:Connect(function(_player, mode)
		got = mode
	end)
	C.settle(1)
	local retry = preview.findGui(function(g) return g:IsA("GuiButton") and g.Name == "Retry" and preview.isShown(g) end)
	local vp = workspace.CurrentCamera.ViewportSize
	if not retry[1] and vp.X > vp.Y and vp.Y < 600 then
		-- phones in landscape have no room for the card (LobbyScreen hides it there)
		preview.log("SKIP LAST RUN card hidden on a short landscape screen (no room)")
	else
		assert(retry[1], "the LAST RUN card must show a RETRY button")
		preview.click(retry[1])
		C.settle(0.5)
		assert(got == (preview.args.lastmode or "Solo"), "RETRY must fire StartRun with the last mode, got " .. tostring(got))
		preview.log("PASS RETRY fired StartRun(" .. tostring(got) .. ")")
	end
end
if preview.args.save then
	C.setPlayer({ SaveStatus = preview.args.save })
end
if preview.args.endless == "on" then
	C.setPlayer({ Endless = true })
end
C.settle(3)
if preview.args.drag then
	local Showcase = preview.client("Showcase")
	local UIS = game:GetService("UserInputService")
	local cam = workspace.CurrentCamera
	if preview.args.drag == "input" then
		-- press on the hero's middle, drag 150 px right, hold still
		local folder = workspace:FindFirstChild("SwarmShowcase")
		local m = folder and folder:FindFirstChild("ShowcaseHero")
		local p = cam:WorldToViewportPoint((m :: Model):GetPivot().Position)
		local touch = { UserInputType = Enum.UserInputType.Touch, KeyCode = Enum.KeyCode.Unknown, Position = Vector3.new(p.X, p.Y, 0) }
		UIS.InputBegan:_fire(touch, false)
		for i = 1, 10 do
			preview.advance(0.02, 60)
			touch.Position = Vector3.new(p.X + i * 15, p.Y, 0)
			UIS.InputChanged:_fire(touch, false)
		end
		UIS.InputEnded:_fire(touch, false)
		preview.advance(0.05, 60)
		preview.note("simulated drag fired at " .. tostring(p.X) .. "," .. tostring(p.Y))
	else
		Showcase.Spin(tonumber(preview.args.drag) or 0)
		preview.advance(0.1, 60)
	end
end
