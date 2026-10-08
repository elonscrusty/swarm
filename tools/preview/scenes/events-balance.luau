-- events-balance: balance check for MAP EVENTS + WEATHER on the REAL server (headless).
-- Solo runs of the same length on the same arena, the hero standing still at the centre
-- (no dodging: the worst case for meteors and fire patches), auto-picking level-ups:
--   base     both switches off
--   Meteor / GoldRush / Fog   that map event forced at the start of the window
--   Snow / Lava               the window's stage started as that world (weather)
-- For each: damage taken (all causes, and the event's own), run gold, kills; Repeats runs
-- each, averaged. Prints a table and PASS when every config stays within the limits
-- (damage and gold within +max(25 %, 1.5 x the sim noise) of base, the noise being base vs
-- Fog, which changes nothing on the server; meteor / lava damage share < 15 %).
-- --set seconds=120 --set repeats=6 (needs --max-time 8000)
local C = lib("common")
local Players = game:GetService("Players")
preview.forceMeshesUploaded()
preview.startServer()
preview.advance(1)
C.startClient()
preview.advance(1)
local me = Players.LocalPlayer
local RM = preview.server("RunManager")
local ED = preview.server("EncounterDirector")
local WE = preview.server("WorldEvents")
local Config = C.shared("Config")
local advance = preview.advance
local SECONDS = tonumber(preview.args.seconds) or 120
local REPEATS = tonumber(preview.args.repeats) or 8
-- no random map event of the director's own in the windows (we force them)
Config.WorldEvents.Chance = 0

local taken: { [string]: number } = {}
local realDamage = RM.DamagePlayer
-- a huge pool so nothing is lethal or clamped; the HP lost per hit is what counts
RM.DamagePlayer = function(rp, amount, cause)
	local cap = rp.Stats.MaxHP
	rp.Stats.MaxHP = 1e6 -- (setHP clamps to it)
	rp.HP = 1e6
	realDamage(rp, amount, cause)
	if rp.HP < 1e6 then
		taken[cause or "?"] = (taken[cause or "?"] or 0) + (1e6 - rp.HP)
	end
	rp.Stats.MaxHP = cap
	rp.HP = cap
end

local function levelUps()
	for _ = 1, 30 do
		if not me:GetAttribute("Paused") then
			return
		end
		preview.remote("LevelUpChoose"):FireServer(1, game:GetService("Players").LocalPlayer:GetAttribute("ChoiceOfferId"))
		advance(0.3)
	end
end

local function window(config: string): { [string]: number }
	Config.Features.MapEvents = config ~= "base"
	Config.Features.Weather = config ~= "base"
	preview.remote("StartRun"):FireServer("Solo")
	advance(2)
	levelUps()
	local rp = RM.GetRunPlayer(me)
	if not rp then
		return { Damage = -1, Gold = -1, Kills = -1, Own = 0 }
	end
	local i = ED.Stage()
	local world = (config == "Snow" or config == "Lava") and config or "Forest"
	ED.StageStart(i.Arena, 1, i.PortalPos, world)
	if config == "Meteor" or config == "GoldRush" or config == "Fog" then
		WE.Force(config)
	end
	table.clear(taken)
	local gold0, kills0, t0 = rp.Gold, rp.Kills, RM.GetRunTime()
	local guard = 0
	while RM.GetRunTime() - t0 < SECONDS and guard < SECONDS * 4 do
		advance(1)
		levelUps()
		if rp.RewardSeq then
			preview.remote("RewardClose"):FireServer(rp.RewardSeq)
		end
		guard += 1
	end
	local total = 0
	for _, v in pairs(taken) do
		total += v
	end
	local own = (taken.Meteor or 0) + (taken["Lava eruption"] or 0)
	local out = { Damage = total, Gold = rp.Gold - gold0, Kills = rp.Kills - kills0, Own = own, Boosted = WE.Stats().Boosted }
	preview.remote("AbandonRun"):FireServer()
	advance(3)
	return out
end

local configs = { "base", "Meteor", "GoldRush", "Fog", "Snow", "Lava" }
local results = {}
for _, cfg in ipairs(configs) do
	local sum = { Damage = 0, Gold = 0, Kills = 0, Own = 0, Boosted = 0 }
	for _ = 1, REPEATS do
		local r = window(cfg)
		for k, v in pairs(r) do
			sum[k] += v
		end
	end
	for k, v in pairs(sum) do
		sum[k] = v / REPEATS
	end
	results[cfg] = sum
	preview.log(string.format("%-9s damage %7.1f (event %5.1f)  gold %6.1f  kills %6.1f  (gold-rush rolls so far %d)", cfg, sum.Damage, sum.Own, sum.Gold, sum.Kills, WE.Stats().Boosted))
end
local base = results.base
-- Fog changes nothing on the server, so base vs Fog is the run-to-run noise of this sim
local fog = results.Fog
local noise = math.max(math.abs(fog.Damage / math.max(1, base.Damage) - 1), math.abs(fog.Gold / math.max(1, base.Gold) - 1))
preview.log(string.format("sim noise (base vs Fog, same server rules): %.0f%%", noise * 100))
local limit = math.max(0.25, noise * 1.5)
local ok = true
for _, cfg in ipairs(configs) do
	local r = results[cfg]
	local dRatio = base.Damage > 0 and r.Damage / base.Damage or 1
	local gRatio = base.Gold > 0 and r.Gold / base.Gold or 1
	local share = r.Damage > 0 and r.Own / r.Damage or 0
	local fine = dRatio <= 1 + limit and gRatio <= 1 + limit and share < 0.15
	ok = ok and fine
	preview.log(string.format("%s %-9s damage x%.2f  gold x%.2f  event damage share %.0f%%  (limit +%.0f%%)", fine and "PASS" or "FAIL", cfg, dRatio, gRatio, share * 100, limit * 100))
end
-- the gold rush can only raise the kill-gold chance to MaxChance for Seconds
local G = Config.WorldEvents.GoldRush
local bound = (math.min(Config.Gold.KillGoldChance * G.ChanceMult, G.MaxChance) / Config.Gold.KillGoldChance - 1)
preview.log(string.format("gold rush bound: kill gold x%.2f for %d s (kill gold only; stage, chest and survival gold unchanged)", 1 + bound, G.Seconds))
preview.log(ok and "PASS events-balance: no big shift in damage taken or gold" or "FAIL events-balance: a config shifts the balance")
