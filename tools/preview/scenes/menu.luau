-- menu: the lobby world at dusk, the lobby home screen, camera at the MenuCamera part.
--   --set save=failing|memory   the server says progress isn't being saved (SaveStatus):
--                               the lobby's save notice
--   --set drag=90               the hero turned by this many degrees (Showcase.Spin, as a drag would)
--   --set drag=input            a real drag over the hero through UserInputService events
--                               (right across the hero; prints whether the press was taken)
--   --set endless=on             the ENDLESS switch is on (player attribute Endless)
local C = lib("common")
C.lobby()
C.startClient()
C.sendProfile()
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
