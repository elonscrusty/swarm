-- lobby-fun: the COURTYARD behind the lobby menu camera (feature 30, docs/features/LOBBY.md):
-- the training dummy, the cosmetics mirror and the jump-pad course, with BACK and the clock.
--   --set view=dummy|mirror|course   where your hero stands (default course)
--   --set hero=<Id>                  the selected hero (dummy numbers, mirror copy)
--   --set best=on                    a finished try (the clock shows BEST)
local C = lib("common")
local hero = preview.args.hero or "Knight"
C.lobby({ character = hero })
C.startClient()
local profile = C.profile({ SelectedCharacter = hero, OwnedCharacters = { Knight = true, Mage = true, [hero] = true }, Skins = { [hero] = "Default" }, Title = "Swarm Breaker",
	Features = { Cosmetics = { Owned = {}, Equipped = { Trail = "", Burst = "", Pet = "", Emote = "", Nameplate = "", Dais = "" } }, WeaponMastery = { Whip = 1400, ["Glow:Whip"] = 2 } } })
C.sendProfile(profile)
C.settle(1)
local Config = C.shared("Config")
local Fun = preview.client("LobbyFun")
Fun.Enter()
local LF = Config.LobbyFun
local o = Config.Lobby.Origin
local view = preview.args.view or "course"
-- the play camera looks toward −Z: stand on the +Z side (in front of the thing, facing up the screen)
local spot = view == "dummy" and (LF.Dummy + Vector3.new(4, 0, 6)) or view == "mirror" and (LF.Mirror + Vector3.new(-4, 0, 7)) or (LF.Course.Start + Vector3.new(0, 0, 6))
local char = game:GetService("Players").LocalPlayer.Character
if char then
	char:PivotTo(CFrame.new(o + spot + Vector3.new(0, 3, 0)))
end
if preview.args.best == "on" then
	local c = Fun.NewCourse()
	Fun.CourseStep(c, LF.Course.Start, true, 0)
	Fun.CourseStep(c, LF.Course.Platforms[#LF.Course.Platforms].At, true, 14.3)
end
C.settle(1.2)
preview.log(string.format("courtyard parts: %d (max %d)", Fun.PartCount(), LF.MaxParts))
