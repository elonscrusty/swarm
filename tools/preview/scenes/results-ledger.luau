-- results-ledger: the results screen (approved screen 06) with a full gold ledger and the
-- three separate progress bars, plus PASS / FAIL checks of the ledger numbers.
--   --set outcome=loss (default)  defeat on stage 1 (sample values of screen 06), spent gold,
--                                 survival bonus, run level / mastery / account bars
--   --set outcome=win             a portal win: everything unspent kept, first-run bonus
--   --set details=open            RUN DETAILS opened (build, items, recent damage)
-- Run: render.sh results-ledger --devices pc,iphone,phone-portrait --set outcome=win
local A = lib("arena")
local C = lib("common")
A.build({ enemies = 40, seconds = 120 })
C.settle(1)
C.setState({ Phase = "Results" })
C.sendProfile(C.profile({ Heroes = { Knight = { XP = 600, Runs = 6 } } }))
local win = preview.args.outcome == "win"
local Players = game:GetService("Players")
local me = Players.LocalPlayer
C.setPlayer({ Level = win and 31 or 8, XP = win and 140 or 52, XPNeeded = win and 420 or 126 })
local build = {
	Weapons = { { Id = "Whip", Level = 6, Evolved = false }, { Id = "MagicOrb", Level = 3, Evolved = false } },
	Passives = { { Id = "Might", Level = 2 }, { Id = "Armor", Level = 1 } },
}
local data
if win then
	data = { Won = true, Portal = true, WinMinStages = 5, Time = 1500, Kills = 3874, Gold = 1412, GoldEarned = 1412, GoldSpent = 2310, GoldLost = 0,
		GoldRetention = 1, GoldSurvival = 1000, FirstRun = { Bonus = 200 }, Difficulty = "Standard", Level = 31, Damage = 286400, Score = 9120,
		Arena = "Forest", Mode = "Solo", CharacterId = "Knight", Build = build, BossKills = 5, BossFight = false, Stage = 5, StagesCleared = 5,
		Items = { { Id = "Whetstone", Count = 3 } }, Curses = {}, CurseGold = 1, NewBest = true,
		Account = { Gained = 342, From = 7, To = 8, Into = 92, Need = 500, Rewards = { "Bronze Frame" } },
		Mastery = { Hero = "Knight", Gained = 342, From = 3, To = 3 },
		NextGoal = { Kind = "BuyHero", Icon = "hero:Mage", Text = "Unlock Mage at 10,000 gold", Sub = "about 2 more runs", Progress = 0.77, ProgressText = "7,700 / 10,000 gold" },
		Seconds = 25 }
else
	data = { Won = false, Portal = false, Time = 109, Kills = 165, Gold = 176, GoldEarned = 505, GoldSpent = 240, GoldLost = 329, GoldRetention = 0.35,
		GoldSurvival = 40, Difficulty = "Standard", Level = 8, Damage = 2329, Score = 359, Arena = "Forest", Mode = "Solo", CharacterId = "Knight",
		Build = build, BossKills = 0, BossFight = false, Stage = 1, StagesCleared = 0, Items = {}, Curses = {}, CurseGold = 1,
		DamageHistory = { { Cause = "Forest Beetle bite", Damage = 12, Time = 104 }, { Cause = "Thorn Sprout spit", Damage = 18, Time = 108 } },
		Account = { Gained = 37, From = 5, To = 5, Into = 210, Need = 450, Rewards = {} },
		Mastery = { Hero = "Knight", Gained = 37, From = 3, To = 3 },
		NextGoal = { Kind = "BuyHero", Icon = "hero:Mage", Text = "Unlock Mage at 10,000 gold", Sub = "or play again", Progress = 0.05, ProgressText = "500 / 10,000 gold" },
		Seconds = 25 }
end
C.fire("RunResult", data)
C.settle(3)

local fails = 0
local function check(label: string, ok: boolean, detail: string?)
	if not ok then
		fails += 1
	end
	preview.log(string.format("%s  %s%s", ok and "PASS" or "FAIL", label, detail and ("  (" .. detail .. ")") or ""))
end
local function find(name: string): Instance?
	return preview.findGui(function(obj)
		return obj.Name == name and obj:FindFirstAncestor("Results") ~= nil
	end)[1]
end
local function cell(name: string): string
	local c = find("GoldLedger")
	local f = c and c:FindFirstChild(name, true)
	local v = f and f:FindFirstChild("Value")
	return v and (v :: TextLabel).Text or "-"
end
local function caption(name: string): string
	local c = find("GoldLedger")
	local f = c and c:FindFirstChild(name, true)
	local v = f and f:FindFirstChild("Caption")
	return v and (v :: TextLabel).Text or "-"
end
if win then
	check("earned = unspent + spent", cell("Earned") == "3,722", cell("Earned"))
	check("unspent", cell("Unspent") == "1,412" and caption("Unspent") == "UNSPENT", cell("Unspent") .. " / " .. caption("Unspent"))
	check("kept all", caption("Kept") == "KEPT · ALL", caption("Kept"))
	check("bonuses = survival + first run", cell("Bonuses") == "+1,200", cell("Bonuses"))
else
	check("earned = unspent + spent", cell("Earned") == "745", cell("Earned"))
	check("spent", cell("Spent") == "240", cell("Spent"))
	check("gold at defeat", cell("Unspent") == "505", cell("Unspent"))
	check("kept 35%", caption("Kept") == "KEPT · 35%", caption("Kept"))
	check("bonuses", cell("Bonuses") == "+40", cell("Bonuses"))
end
for _, card in ipairs({ "RunLevel", "HeroMastery", "AccountLevel" }) do
	local f = find(card)
	local meter = f and f:FindFirstChild("Meter")
	check(card .. " card with its own bar", meter ~= nil and (meter :: GuiObject).Visible)
end
if preview.args.details == "open" then
	local t = find("RunDetails")
	if t then
		preview.click(t :: GuiButton)
	end
	C.settle(1)
	local d = find("DetailsText")
	check("details open", d ~= nil and (d :: GuiObject).Visible)
end
preview.log(fails == 0 and "ALL PASS" or (fails .. " FAIL"))
