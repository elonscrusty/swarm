-- challenges: the client side of the CHALLENGES features (ChallengesUI, docs/features/
-- CHALLENGES.md) over the arena. The Shrine of Trial is placed by the real server modules
-- (EncounterDirector + TrialShrine on stage 2) with its ring in the "running" look; the
-- replicated state the server would set is set by hand (challenges-regression covers the
-- server):
--   champion  SwarmState MiniBossId / MiniBossName on the swarm enemy nearest the hero:
--             the violet name plate over it and the gold / violet ring under it
--   trial     TrialLeft 24 + player TrialIn: the "TRIAL 24s" FeatureHud badge;
--             --set away=on adds TrialAway (the "BACK TO THE RING!" announcer line)
--   cursed    CurseLeft 42: the "CURSED 42s" badge
-- --set show=all (default) | champion | trial | cursed. Prints PASS / FAIL lines.
-- --set extras=on also fills the other FeatureHud slots for a full-HUD layout check: the
--   ultimate button (60 % charged) and an announcer line (FEEL combo counter)
local A = lib("arena")
local C = lib("common")
local show = preview.args.show or "all"
local Config = C.shared("Config")
local ED = C.server("EncounterDirector")
local Loot = C.server("LootSystem")
local Items = C.server("ItemSystem")
local TS = C.server("TrialShrine")
local Players = game:GetService("Players")

local ctx = {
	RunManager = {
		GetRunPlayers = function() return {} end,
		Broadcast = function() end,
		Notify = function() end,
		IsRunning = function() return true end,
		IsSimulating = function() return true end,
		GetRunTime = function() return 0 end,
	},
	LootSystem = Loot,
	ItemSystem = Items,
}
Loot.Init(ctx)
Items.Init(ctx)
ED.Init(ctx)
TS.Init(ctx)
for k in pairs(Config.Features) do
	if k ~= "MiniBosses" and k ~= "TrialShrine" and k ~= "CursedChests" then
		Config.Features[k] = false
	end
end

local s = A.build({
	enemies = 40,
	stage = 2,
	portal = true,
	place = function(_s, arena, centre)
		ED.StageStart(arena, 2, nil, "Forest")
		local t = TS.Get()
		if t then
			if t.Ring then
				t.Ring.Transparency = 0.72 -- the running look (TrialShrine.start)
			end
			return t.Pos + Vector3.new(4, 0, 6)
		end
		preview.warn("challenges: no Shrine of Trial placed")
		return centre
	end,
})
local fails = 0
local function check(ok: boolean, label: string)
	if not ok then
		fails += 1
	end
	preview.log((ok and "PASS " or "FAIL ") .. label)
end
local me = Players.LocalPlayer

-- the champion: the swarm enemy nearest the hero, a little in front of the camera
if show == "all" or show == "champion" then
	local best, bestD = nil, math.huge
	local folder = workspace:FindFirstChild("SwarmEnemies")
	for _, m in ipairs(folder and folder:GetChildren() or {}) do
		local body = m:FindFirstChild("Body")
		if body and body:IsA("BasePart") then
			local d = ((body.Position - s.centre) * Vector3.new(1, 0, 1)).Magnitude
			if d > 10 and d < bestD then
				best, bestD = m, d
			end
		end
	end
	if best then
		local id = tonumber(string.sub(best.Name, 2)) or 0
		best.Body:SetAttribute("MiniBoss", "Thornback Brute")
		best.Body:SetAttribute("HPFrac", 0.7)
		C.setState({ MiniBossId = id, MiniBossName = "Thornback Brute" })
	end
end
if show == "all" or show == "trial" then
	C.setState({ TrialLeft = 24 })
	C.setPlayer({ TrialIn = true, TrialAway = preview.args.away == "on" and 1.4 or nil })
end
if show == "all" or show == "cursed" then
	C.setState({ CurseLeft = 42 })
end
C.settle(tonumber(preview.args.at) or 6) -- after the stage-start card
if preview.args.extras == "on" then
	local FH = preview.client("FeatureHud")
	FH.SetUltimate({ Charge = 0.6, Label = "ULT", OnActivate = function() end })
	FH.Announce("x24 COMBO!", { Seconds = 30 })
	C.settle(0.5)
end

local pg = me.PlayerGui
local plate = pg:FindFirstChild("ChampionPlate")
if show == "all" or show == "champion" then
	local label = plate and plate:FindFirstChild("Name")
	check(plate ~= nil and plate.Enabled and label ~= nil and label.Text == "THORNBACK BRUTE", "champion: name plate over the guard")
	local cam = workspace.CurrentCamera
	local ring = cam and cam:FindFirstChild("ChampionRingOuter")
	check(ring ~= nil and ring.Position.Y > -100, "champion: ring under the guard")
end
local function badge(id: string): string?
	local gui = pg:FindFirstChild("FeatureHud")
	local b = gui and gui:FindFirstChild("Badge_" .. id, true)
	local t = b and b.Visible and b:FindFirstChild("Text")
	return t and t.Text or nil
end
if show == "all" or show == "trial" then
	check(badge("Trial") == "TRIAL 24s", "trial: badge " .. tostring(badge("Trial")))
end
if show == "all" or show == "cursed" then
	check(badge("Curse") == "CURSED 42s", "cursed: badge " .. tostring(badge("Curse")))
end
preview.log(string.format("challenges: %d failure(s)", fails))
