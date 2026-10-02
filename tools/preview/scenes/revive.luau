-- revive: the solo revive offer (ReviveOffer) over the arena: the fallen hero's portrait
-- with the heart on its corner (`--set character=Mage` another hero).
local A = lib("arena")
local C = lib("common")
local hero = preview.args.character or "Knight"
A.build({ enemies = 60, character = hero })
C.settle(1)
game:GetService("Players").LocalPlayer:SetAttribute("CharacterId", hero)
C.fire("ReviveOffer", { Seconds = 10, ProductId = 0 })
C.settle(1.2)
