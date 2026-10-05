-- events-balance: balance check for MAP EVENTS + WEATHER on the REAL server (headless).
-- Solo runs of the same length on the same arena, the hero standing still at the centre
-- (no dodging: the worst case for meteors and fire patches), auto-picking level-ups:
--   base     both switches off
--   Meteor / GoldRush / Fog   that map event forced at the start of the window
--   Snow / Lava               the window's stage started as that world (weather)
-- For each: damage taken (all causes, and the event's own), run gold, kills; Repeats runs
-- each, averaged. Prints a table and PASS when every config stays within the limits
-- (damage within +25 %, gold within +25 % of base; meteor / lava damage share < 15 %).
-- --set seconds=120 --set repeats=4
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
local REPEATS = tonumber(preview.args.repeats) or 4
-- no random map event of the director's own in the windows (we force them)
Config.WorldEvents.Chance = 0

local taken: { [string]: number } = {}
local realDamage = RM.DamagePlayer
RM.DamagePlayer = function(rp, amount, cause)
	rp.HP = 1e6
	local before = rp.HP
	realDamage(rp, amount, cause)
	if rp.HP < before then
		taken[cause or "?"] = (taken[cause or "?"] or 0) + (before - rp.HP)
	end
	rp.HP = 1e6
end

local function levelUps()
	for _ = 1, 30 do
		if not me:GetAttribute("Paused") then
			return
		end
		preview.remote("LevelUpChoose"):FireServer(1)
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
	rp.HP = 1e6
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
	local out = { Damage = total, Gold = rp.Gold - gold0, Kills = rp.Kills - kills0, Own = own }
	preview.remote("AbandonRun"):FireServer()
	advance(3)
	return out
end

local configs = { "base", "Meteor", "GoldRush", "Fog", "Snow", "Lava" }
local results = {}
for _, cfg in ipairs(configs) do
	local sum = { Damage = 0, Gold = 0, Kills = 0, Own = 0 }
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
	preview.log(string.format("%-9s damage %7.1f (event %5.1f)  gold %6.1f  kills %6.1f", cfg, sum.Damage, sum.Own, sum.Gold, sum.Kills))
end
local base = results.base
local ok = true
for _, cfg in ipairs(configs) do
	local r = results[cfg]
	local dRatio = base.Damage > 0 and r.Damage / base.Damage or 1
	local gRatio = base.Gold > 0 and r.Gold / base.Gold or 1
	local share = r.Damage > 0 and r.Own / r.Damage or 0
	local fine = dRatio <= 1.25 and gRatio <= 1.25 and share < 0.15
	ok = ok and fine
	preview.log(string.format("%s %-9s damage x%.2f  gold x%.2f  event damage share %.0f%%", fine and "PASS" or "FAIL", cfg, dRatio, gRatio, share * 100))
end
preview.log(ok and "PASS events-balance: no big shift in damage taken or gold" or "FAIL events-balance: a config shifts the balance")
