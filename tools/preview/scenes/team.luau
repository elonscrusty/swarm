-- team: a Duo / Trio run on the local client (TeamUI): the teammates list, a fallen
-- teammate with the world revive circle and the revive marker (progress ring), the
-- spectate / downed status. Teammates are extra Players (preview.addPlayer) with real
-- characters and the attributes RunManager sets.
--   --set mode=Duo|Trio      (Trio: one alive teammate + one fallen)
--   --set revive=0.55        the fallen teammate's ReviveProgress (0 = just fell)
--   --set far=on             the fallen teammate is off screen (edge arrow)
--   --set me=down            the local player is the one down (ring over yourself)
--   --set choosing=on        the alive teammate is choosing a level-up card: a live group choice
--                            (docs/overhaul/CHOICE_STATE.md), the world keeps running, no "Paused"
--   --set leave=on           the alive teammate disconnects mid-scene (row removed)
--   TEAM features (docs/features/TEAM.md):
--   --set wheel=on           the quick-ping wheel open (FeatureHud PingWheel slot)
--   --set combo=full|half    the team combo meter (badge; full = the COMBO button)
--   --set weakspot=on        the co-op boss weak spot marker + badge in front of the hero
--   (with me=down the spectate bar shows: < WATCHING NAME > and REVIVE ME)
local A = lib("arena")
local C = lib("common")
local mode = preview.args.mode or "Trio"
local s = A.build({ enemies = tonumber(preview.args.enemies) or 60 })
C.settle(0.5)
local centre = s.centre
local Config = s.Config
local function mate(name, userId, heroId, offset, attrs)
	local p = preview.addPlayer(name, userId)
	local model = C.try("BuildCharacter " .. heroId, s.ModelBuilder.BuildCharacter, heroId, "Default")
	if model then
		model.Name = name
		model:PivotTo(CFrame.new(centre + offset + Vector3.new(0, 3.5, 0)))
		model.Parent = workspace
		p.Character = model
	end
	p:SetAttribute("InRun", true)
	p:SetAttribute("CharacterId", heroId)
	for k, v in pairs(attrs) do
		p:SetAttribute(k, v)
	end
	return p, model
end
local revive = tonumber(preview.args.revive) or 0.55
local downOffset = preview.args.far == "on" and Vector3.new(95, 0, -70) or Vector3.new(-15, 0, 9)
local meDown = preview.args.me == "down"
local mates = {}
local alive
if mode == "Trio" then
	alive = mate("Ava", 2, "Mage", Vector3.new(13, 0, 5), { Alive = true, HP = 64, MaxHP = 110, PartnerRevivesLeft = 3 })
	table.insert(mates, alive)
end
local downName = meDown and "Ben" or "Ben"
local down, downModel = mate(downName, 3, "Rogue", meDown and Vector3.new(10, 0, 4) or downOffset, {
	Alive = meDown,
	HP = meDown and 40 or 0,
	MaxHP = 100,
	PartnerRevivesLeft = 2,
	ReviveProgress = meDown and 0 or revive,
})
table.insert(mates, down)
if downModel and not meDown then
	for _, d in ipairs(downModel:GetDescendants()) do
		if d:IsA("BasePart") and d.Name ~= "HumanoidRootPart" then
			d.Transparency = 0.75
		end
	end
end
C.setState({ Mode = mode, Participants = #mates + 1 })
C.setPlayer({ CharacterId = "Knight", PartnerRevivesLeft = 3 })
if meDown then
	C.setPlayer({ Alive = false, HP = 0, ReviveProgress = revive, PartnerRevivesLeft = 2 })
end
if preview.args.choosing == "on" and alive then
	-- what RunManager writes for a Duo/Trio panel: the world is not frozen, LevelUpPause stays
	-- false, the chooser's own Player carries ChoiceOpen / ChoiceGroup / ChoiceProtectedUntil
	C.setState({ Frozen = false, LevelUpPause = false, ChoosingIds = "," .. tostring(alive.UserId) .. ",", ChoosingNames = alive.DisplayName })
	alive:SetAttribute("ChoiceOpen", true)
	alive:SetAttribute("ChoiceGroup", true)
	alive:SetAttribute("ChoiceId", 1)
	alive:SetAttribute("ChoiceOfferId", 1)
	alive:SetAttribute("ChoiceProtectedUntil", workspace:GetServerTimeNow() + (Config.LevelUp and Config.LevelUp.GroupAutoPickSeconds or 10))
	alive:SetAttribute("Paused", true)
end
C.settle(1.5)
if preview.args.choosing == "on" and alive then
	local text = ""
	for _, d in ipairs(game:GetService("Players").LocalPlayer.PlayerGui:GetDescendants()) do
		if d:IsA("TextLabel") and d.Visible and string.find(d.Text, "choosing an upgrade", 1, true) then
			text = d.Text
		end
	end
	local ok = text ~= "" and not string.find(text, "Paused", 1, true)
	preview.log(string.format("%s team group choice status: %q (live world, no Paused)", ok and "PASS" or "FAIL", text))
end
if preview.args.leave == "on" and alive then
	C.fire("Notify", { Text = alive.DisplayName .. " left the run.", Color = Color3.fromRGB(255, 200, 120) })
	alive.Parent = nil
	if alive.Character then
		alive.Character:Destroy()
	end
	C.settle(1)
end
-- TEAM features (16, 17, 18, 20)
if preview.args.combo == "full" or preview.args.combo == "half" then
	local pair = alive and string.format(",%d,%d,", game:GetService("Players").LocalPlayer.UserId, alive.UserId) or nil
	C.setState({ TeamCombo = preview.args.combo == "full" and 1 or 0.46, TeamComboPair = pair, TeamComboUsed = 0 })
end
if preview.args.weakspot == "on" then
	C.setState({ BossWeakSpot = centre + Vector3.new(6, 0, -10), BossAggroId = 2 })
end
if preview.args.wheel == "on" then
	local wheel = C.try("require PingWheel", preview.client, "PingWheel")
	if wheel then
		wheel.SetOpen(true)
	end
end
if preview.args.combo or preview.args.weakspot or preview.args.wheel or meDown then
	C.settle(0.6)
	local spectate = game:GetService("Players").LocalPlayer.PlayerGui:FindFirstChild("Spectate")
	local fh = game:GetService("Players").LocalPlayer.PlayerGui:FindFirstChild("FeatureHud")
	preview.log(string.format("team features: spectate bar=%s wheel=%s combo button=%s", tostring(spectate and spectate.Enabled),
		tostring(fh and fh.Root.PingWheel.Visible), tostring(fh and fh.Root:FindFirstChild("TeamCombo") and fh.Root.TeamCombo.Visible)))
end
local TeamUI = C.try("require TeamUI", preview.client, "TeamUI")
if TeamUI then
	local els = TeamUI.Elements()
	local n, words = 0, {}
	for p, r in pairs(els.Rows) do
		n += 1
		table.insert(words, p.Name .. "=" .. r.State.Text)
	end
	local rings = 0
	for _ in pairs(els.Rings) do
		rings += 1
	end
	preview.log(string.format("team rows=%d [%s] revive rings=%d", n, table.concat(words, ", "), rings))
end
local _ = Config
if preview.args.debug == "on" then
	local f = workspace:FindFirstChild("SwarmTeamFx")
	if f then
		for i, p in ipairs(f:GetChildren()) do
			if i <= 6 then
				preview.log(string.format("%s pos=%s size=%s t=%.2f", p.Name, tostring(p.Position), tostring(p.Size), p.Transparency))
			end
		end
	end
	preview.log("ben root " .. tostring(down.Character and down.Character.PrimaryPart and down.Character.PrimaryPart.Position))
end

-- --set plate=on: one plate per hero. A teammate wearing a store nameplate + Supporter gets
-- StoreFx's plate; once they wear a META title, TitlePlates draws the plate (name + title)
-- styled by StoreFx.DecoratePlate and StoreFx drops its own (PASS / FAIL lines)
if preview.args.plate == "on" then
	local mate = alive or down
	local pg = game:GetService("Players").LocalPlayer.PlayerGui
	local function count(prefix: string): (number, Instance?)
		local n, last = 0, nil
		for _, d in ipairs(pg:GetDescendants()) do
			if d:IsA("BillboardGui") and d.Name == prefix .. mate.Name then
				n += 1
				last = d
			end
		end
		return n, last
	end
	mate:SetAttribute("CosPlate", "Plate_Gold")
	mate:SetAttribute("Supporter", true)
	C.settle(1.2)
	local store0, title0 = count("StorePlate_"), count("TitlePlate_")
	preview.log(((store0 == 1 and title0 == 0) and "PASS" or "FAIL") .. string.format(" plate: no title = the store plate only (store %d, title %d)", store0, title0))
	mate:SetAttribute("Title", "Swarm Breaker")
	C.settle(1.2)
	local store1 = count("StorePlate_")
	local title1, gui = count("TitlePlate_")
	local styled = gui and gui:FindFirstChild("StorePlateStroke", true) ~= nil
	preview.log(((store1 == 0 and title1 == 1 and styled) and "PASS" or "FAIL") .. string.format(" plate: titled = one plate (store %d, title %d, frame styled %s)", store1, title1, tostring(styled)))
end
