-- tutorial: a brand new player's first run (profile TutorialDone = false) and its
-- contextual tips (client Tutorial.lua). The run is restarted once on the client
-- (InRun off / on) after the profile arrives, like a real first run.
--   --set tip=Move|Attack|Gems|Portal|Boss|TeamRules|Revive|LevelUp   which hint to show
--     (the hints before it count as seen; LevelUp opens a level-up offer and shows the
--     explanation line under LEVEL UP!)
--   --set tips=off   Settings > Show tips off: nothing shows
local A = lib("arena")
local C = lib("common")
local tip = preview.args.tip or "Move"
local order = { "Move", "Attack", "Gems", "Portal", "Boss" }
local seen = {}
for _, id in ipairs(order) do
	if id == tip then
		break
	end
	seen[id] = true
end
if tip == "LevelUp" or tip == "TeamRules" or tip == "Revive" then
	seen = { Move = true, Attack = true }
end
local s = A.build({ enemies = 50, stage = 1, stagePhase = "Explore", lockLeft = 95 })
C.setPlayer({ Kills = 0 })
local settings = { Music = 0.6, Sfx = 0.8, Shake = 1, ReducedEffects = false, DamageNumbers = false, Tips = preview.args.tips ~= "off" }
C.sendProfile(C.profile({ TutorialDone = false, SeenTips = seen, Settings = settings, Stats = { BestTime = 0, TotalKills = 0, Wins = 0, Runs = 1, BestStage = 0 } }))
C.settle(0.2)
if tip == "TeamRules" or tip == "Revive" then
	local p = preview.addPlayer("Ava", 2)
	local model = C.try("BuildCharacter", s.ModelBuilder.BuildCharacter, "Mage", "Default")
	if model then
		model:PivotTo(CFrame.new(s.centre + Vector3.new(-12, 3.5, 8)))
		model.Parent = workspace
		p.Character = model
	end
	p:SetAttribute("InRun", true)
	p:SetAttribute("CharacterId", "Mage")
	p:SetAttribute("Alive", tip ~= "Revive")
	p:SetAttribute("HP", tip == "Revive" and 0 or 90)
	p:SetAttribute("MaxHP", 110)
	p:SetAttribute("PartnerRevivesLeft", 3)
	C.setState({ Mode = "Duo", Participants = 2 })
	if tip == "Revive" then
		seen.TeamRules = true
		C.sendProfile(C.profile({ TutorialDone = false, SeenTips = seen, Settings = settings }))
	end
end
-- the first run starts now (the client saw the profile)
C.setPlayer({ InRun = false })
preview.advance(0.1)
C.setPlayer({ InRun = true })
C.fire("Inventory", A.inventory())
preview.advance(0.2)
if tip == "Gems" then
	C.settle(0.3)
	C.setPlayer({ Kills = 3 })
elseif tip == "Portal" then
	C.setState({ RunTime = 62 })
elseif tip == "Boss" then
	C.setState({ StagePhase = "Boss", BossMaxHP = 9000, BossHP = 9000, BossName = "Scorpion Queen" })
end
C.settle(2.4)
if tip == "LevelUp" then
	local WeaponData = C.shared("WeaponData")
	local function card(id, level)
		local def = WeaponData.Weapons[id]
		return { Type = "WeaponUp", Id = id, Level = level, Name = def.Name, Rank = string.format("Lv %d → %d / %d", level - 1, level, WeaponData.MaxLevel), Lines = WeaponData.CardLines(id, level - 1, level), Rarity = "Common" }
	end
	C.fire("LevelUpOffer", { Choices = { card("Whip", 2), card("MagicOrb", 1), card("Knives", 3) }, Seconds = 12, Pending = 1, Rerolls = 1, Skips = 0, RerollsMax = 1, SkipsMax = 0, SkipGold = 10 })
	C.settle(1)
end
local Tutorial = C.try("require Tutorial", preview.client, "Tutorial")
if Tutorial then
	local els = Tutorial.Elements()
	preview.log(string.format("tip card visible=%s title=%s body=%s", tostring(els.Card and els.Card.Visible), tostring(els.Title and els.Title.Text), tostring(els.Body and els.Body.Text)))
end
