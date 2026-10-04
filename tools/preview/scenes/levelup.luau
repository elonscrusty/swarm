-- levelup: the level-up offer over the arena (LevelUpOffer remote with three real cards,
-- described by the game's own data the way LevelUpSystem does it: stat lines with current
-- → next values, rank, perks and evolution hints).
--   --set cards=evolve   an evolution card + a weapon upgrade with a perk + a new passive
--   --set cards=Spear+ChainHook:4+evo:Turret   any cards (weapon id = NEW, id:N = upgrade to
--                        level N, evo:id = evolution, passive:id[:N] = passive)
--   --set rerolls=0 --set skips=0 --set rerollsMax=0 --set skipsMax=0   reroll / skip states
--   --set at=<s>         seconds after the offer arrives (default 1.5; ~0.25 = cards flying in)
--   --set pick=N         card N was just picked (its punch + flash), shown --set at later
--   --set pickAt=<s>     when that click happens (default 1.2 s); under 0.35 s it lands inside
--                        the arm delay and must be ignored (safe level-up input)
--   --set synergy=N      card N advances a synergy (bar "ELEMENTAL TRINITY • 2 / 3")
--   --set hidden=on      the discovery-gated clues of a new player: the synergy and the
--                        evolution partner / result read "???" (LevelUpSystem, DiscoveryService)
local A = lib("arena")
local C = lib("common")
A.build({ enemies = 90 })
C.settle(1.5)
local WeaponData = C.shared("WeaponData")
local PassiveData = C.shared("PassiveData")
local StatSheet = C.shared("StatSheet")
local Config = C.shared("Config")
local function rarity(name)
	local r = Config.LevelUp.Rarities[name]
	return r.Label, r.Color
end
local function joined(lines)
	local parts = {}
	for _, l in ipairs(lines) do
		table.insert(parts, WeaponData.LineText(l))
	end
	return table.concat(parts, ", ")
end
local choices = {}
local hidden = preview.args.hidden == "on"
if WeaponData and PassiveData and Config and StatSheet then
	-- the build the cards are for: Knight with Max HP 2 bought, Heart 1, Might 2
	local passives = { Heart = 1, Might = 2 }
	local sheet = StatSheet.Compute({ CharacterId = "Knight", Meta = { MaxHP = 2 }, Passives = passives })
	local function weaponUp(id, level)
		local def = WeaponData.Weapons[id]
		local r = level >= WeaponData.MaxLevel and "Epic" or "Common"
		local label, color = rarity(r)
		local lines = WeaponData.CardLines(id, level - 1, level)
		local evo = def.Evolution
		local hint, ready = nil, false
		if evo and level >= Config.LevelUp.EvolveHintLevel then
			local required = math.min(3, PassiveData.MaxLevelOf(evo.Passive))
			ready = (passives[evo.Passive] or 0) >= required
			local partner = (hidden and not passives[evo.Passive]) and "???" or PassiveData.Passives[evo.Passive].Name
			if level >= WeaponData.MaxLevel then
				hint = string.format("Evolves into %s with %s Lv %d", hidden and "???" or evo.Name, partner, required)
			else
				hint = string.format("Evolves at Lv %d with %s Lv %d%s", WeaponData.MaxLevel, partner, required, ready and " (ready)" or "")
			end
		end
		return { Type = "WeaponUp", Id = id, Level = level, Name = def.Name, Rank = string.format("Lv %d → %d / %d", level - 1, level, WeaponData.MaxLevel), Lines = lines, Description = joined(lines), Summary = WeaponData.SummaryText(lines, joined(lines)), Hint = hint, HintReady = ready, Color = def.Color, Rarity = r, RarityLabel = label, RarityColor = color }
	end
	local function passiveCard(id, level)
		local def = PassiveData.Passives[id]
		local after = table.clone(passives)
		after[id] = level
		local lines = StatSheet.Lines(sheet, StatSheet.Compute({ CharacterId = "Knight", Meta = { MaxHP = 2 }, Passives = after }))
		local new = level <= 1
		local label, color = rarity(new and "Rare" or "Common")
		return { Type = new and "PassiveNew" or "PassiveUp", Id = id, Level = level, Name = def.Name, Rank = new and "NEW" or string.format("Lv %d → %d / %d", level - 1, level, PassiveData.MaxLevelOf(id)), Lines = lines, Description = def.Description, Summary = WeaponData.SummaryText(lines, def.Description), Color = def.Color, Rarity = new and "Rare" or "Common", RarityLabel = label, RarityColor = color }
	end
	local function weaponNew(id)
		local def = WeaponData.Weapons[id]
		local label, color = rarity("Rare")
		return { Type = "WeaponNew", Id = id, Level = 1, Name = def.Name, Rank = "NEW", Lines = WeaponData.CardLines(id, 0, 1), Description = def.Description, Summary = def.Description, Color = def.Color, Rarity = "Rare", RarityLabel = label, RarityColor = color }
	end
	local function evolveCard(id)
		local label, color = rarity("Legendary")
		local edef = WeaponData.Weapons[id]
		return { Type = "Evolve", Id = id, Level = WeaponData.MaxLevel, Name = edef.Evolution.Name, Rank = "EVOLUTION", Lines = WeaponData.CardLines(id, WeaponData.MaxLevel, WeaponData.MaxLevel, true), Description = edef.Evolution.Description, Summary = edef.Evolution.Description, Color = edef.Color, Rarity = "Legendary", RarityLabel = label, RarityColor = color }
	end
	local list = preview.args.cards
	if list and (string.find(list, "+", 1, true) or string.find(list, ":", 1, true) or WeaponData.Weapons[list]) then
		-- any cards: "Spear+HealingTotem:5+evo:FireTrail+passive:Precision" (a weapon id =
		-- NEW, id:N = upgrade to level N, evo:id = its evolution, passive:id[:N])
		for item in string.gmatch(list, "[^+]+") do
			local a, b, c = string.match(item, "^([^:]+):?([^:]*):?([^:]*)$")
			if a == "evo" and WeaponData.Weapons[b] then
				table.insert(choices, evolveCard(b))
			elseif a == "passive" and PassiveData.Passives[b] then
				table.insert(choices, passiveCard(b, tonumber(c) or 1))
			elseif WeaponData.Weapons[a] then
				table.insert(choices, (tonumber(b) and weaponUp(a, tonumber(b)) or weaponNew(a)))
			end
		end
	elseif preview.args.cards == "evolve" then
		local label, color = rarity("Legendary")
		local edef = WeaponData.Weapons.Longbow
		table.insert(choices, { Type = "Evolve", Id = "Longbow", Level = WeaponData.MaxLevel, Name = edef.Evolution.Name, Rank = "EVOLUTION", Lines = WeaponData.CardLines("Longbow", WeaponData.MaxLevel, WeaponData.MaxLevel, true), Description = edef.Evolution.Description, Color = edef.Color, Rarity = "Legendary", RarityLabel = label, RarityColor = color })
		table.insert(choices, weaponUp("MagicOrb", 5))
		local fletch = passiveCard("Fletching", 1)
		fletch.Hint = "Evolves Longbow at Lv 12 with this at Lv 3" .. (hidden and "" or " into Windpiercer")
		table.insert(choices, fletch)
	else
		table.insert(choices, weaponUp("Whip", 6))
		table.insert(choices, passiveCard("Heart", 2))
		table.insert(choices, weaponNew("Longbow"))
	end
end
-- --set synergy=N   card N shows a synergy line (server text format, LevelUpSystem)
local synIndex = tonumber(preview.args.synergy)
local SynergyData = C.shared("SynergyData")
if synIndex and choices[synIndex] and SynergyData then
	local s = SynergyData.Synergies[SynergyData.Order[1]]
	choices[synIndex].Synergy = string.format("Synergy: %s %d/%d", hidden and "???" or s.Name, 2, 3)
	choices[synIndex].SynergyReady = false
end
-- --set welcome=on: a brand-new player's first level-up (Config.FirstRun): tips on, the
-- welcome hint line, level 2, no rerolls / skips bought yet. Use with
-- --set cards=Lightning+Whip:2+passive:Might (what LevelUpSystem offers a Knight then)
local welcome = preview.args.welcome == "on"
if welcome then
	game:GetService("Players").LocalPlayer:SetAttribute("FirstRunBoost", true)
	C.sendProfile(C.profile({ TutorialDone = false, SeenTips = {} }))
	C.settle(0.2)
end
-- --set group=on   a duo / trio choice (CHOICE_STATE): ChoiceGroup + ChoiceProtectedUntil on
--                  the server clock, ~10 s; the pill says the team keeps playing
-- --set paused=on  the server clock is stopped (ChoiceTimerPaused): the countdown freezes
local group, paused = preview.args.group == "on", preview.args.paused == "on"
if group or paused then
	local lp = game:GetService("Players").LocalPlayer
	lp:SetAttribute("ChoiceOpen", true)
	lp:SetAttribute("ChoiceOfferId", 1)
	lp:SetAttribute("ChoiceGroup", group)
	lp:SetAttribute("ChoiceTimerPaused", paused)
	lp:SetAttribute("ChoiceProtectedUntil", workspace:GetServerTimeNow() + (group and 9.5 or 18.5))
end
C.fire("LevelUpOffer", {
	OfferId = 1,
	Group = group,
	Choices = choices,
	Rerolls = tonumber(preview.args.rerolls) or (welcome and 0 or 2),
	Skips = tonumber(preview.args.skips) or (welcome and 0 or 1),
	RerollsMax = tonumber(preview.args.rerollsMax) or (welcome and 0 or 2),
	SkipsMax = tonumber(preview.args.skipsMax) or (welcome and 0 or 5),
	SkipGold = Config and Config.LevelUp.SkipGold or 10,
	Seconds = group and 9.5 or 25,
	Level = welcome and 2 or 14,
	Pending = 1,
	PanelId = 1,
	BatchRemaining = 4,
	BatchTotal = 4,
})
C.setState({ Frozen = true, LevelUpPause = true })
local pick = tonumber(preview.args.pick)
if pick then
	C.settle(tonumber(preview.args.pickAt) or 1.2)
	local card = C.findText and nil
	for _, d in ipairs(game:GetService("Players").LocalPlayer.PlayerGui:GetDescendants()) do
		if d.Name == "Card" .. pick and d:IsA("TextButton") then
			card = d
		end
	end
	if card then
		preview.click(card)
	end
end
-- --set touch=tap|drag|hold|zone|jump --set touchAt=<s> [--set touchCard=N]
--   one simulated finger on card N (default 2) touchAt seconds after the offer: a quick tap,
--   a 60 px drag, a 0.9 s hold, or a touch that began in the thumbstick zone / on JUMP and
--   ended on the card (worst case). The log says whether the card was taken (safe input).
local touchKind = preview.args.touch
if touchKind then
	C.settle(tonumber(preview.args.touchAt) or 0.9)
	local idx = tonumber(preview.args.touchCard) or 2
	local card
	for _, d in ipairs(game:GetService("Players").LocalPlayer.PlayerGui:GetDescendants()) do
		if d.Name == "Card" .. idx and d:IsA("TextButton") then
			card = d
		end
	end
	if card then
		local vp = workspace.CurrentCamera.ViewportSize
		local opts = {}
		if touchKind == "drag" then
			opts.drag = 60
		elseif touchKind == "hold" then
			opts.hold = 0.9
		elseif touchKind == "zone" then
			opts.at = Vector2.new(vp.X * 0.15, vp.Y * 0.8)
			opts.endOn = true
		elseif touchKind == "jump" then
			local jump = game:GetService("Players").LocalPlayer.PlayerGui:FindFirstChild("JumpButton", true)
			local l = jump and preview.layoutOf(jump)
			opts.at = l and Vector2.new(l.x + l.w / 2, l.y + l.h / 2) or Vector2.new(vp.X * 0.9, vp.Y * 0.85)
			opts.endOn = true
		end
		preview.touch(card, opts)
		C.settle(0.1)
		local taken = false
		for _, d in ipairs(game:GetService("Players").LocalPlayer.PlayerGui:GetDescendants()) do
			if d.Name == "PickFlash" or d.Name == "PickShade" then
				taken = true
			end
		end
		preview.log(string.format("[levelup] touch %s at %.2fs on card %d: %s", touchKind, tonumber(preview.args.touchAt) or 0.9, idx, taken and "TAKEN" or "ignored"))
	end
end
C.settle(tonumber(preview.args.at) or 1.5)
