-- team: a Duo / Trio run on the local client (TeamUI): the teammates list, a fallen
-- teammate with the world revive circle and the revive marker (progress ring), the
-- spectate / downed status. Teammates are extra Players (preview.addPlayer) with real
-- characters and the attributes RunManager sets.
--   --set mode=Duo|Trio      (Trio: one alive teammate + one fallen)
--   --set revive=0.55        the fallen teammate's ReviveProgress (0 = just fell)
--   --set far=on             the fallen teammate is off screen (edge arrow)
--   --set me=down            the local player is the one down (ring over yourself)
--   --set choosing=on        the alive teammate is choosing a level-up card (the freeze)
--   --set leave=on           the alive teammate disconnects mid-scene (row removed)
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
	C.setState({ Frozen = true, LevelUpPause = true, ChoosingIds = "," .. tostring(alive.UserId) .. ",", ChoosingNames = alive.DisplayName })
end
C.settle(1.5)
if preview.args.leave == "on" and alive then
	C.fire("Notify", { Text = alive.DisplayName .. " left the run.", Color = Color3.fromRGB(255, 200, 120) })
	alive.Parent = nil
	if alive.Character then
		alive.Character:Destroy()
	end
	C.settle(1)
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
