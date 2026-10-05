-- pass-warm-regression: audit EC-A21 (docs/audit/ECONOMY.md). A pass owner whose first pass
-- lookup answers slowly (mock MarketplaceService: 5 s, owns DoubleGold + VIP) starts a run at
-- once: the run is never held up, gold earned before the answer is paid at x1 and the
-- difference is paid back once when the lookup answers; the VIP reroll arrives too.
-- Prints PASS / FAIL per check.
local Players = game:GetService("Players")
local player = Players.LocalPlayer
local Config = preview.shared("Config")
local passes = Config.Monetization.GamePasses

local DELAY = 5
preview.setPassLookup(function(_userId, passId)
	task.wait(DELAY)
	return passId == passes.DoubleGold or passId == passes.VIP
end)

local fails = 0
local function check(label: string, ok: boolean, detail: any?)
	if not ok then
		fails += 1
	end
	preview.log(string.format("%s  %s%s", ok and "PASS" or "FAIL", label, detail ~= nil and ("  (" .. tostring(detail) .. ")") or ""))
end

preview.startServer()
preview.advance(0.5)
local RM = preview.server("RunManager")
local Gold = preview.server("GoldSystem")
local MS = preview.server("MonetizationService")

check("lookup still pending at run start", not MS.PassesKnown(player))
preview.remote("StartRun"):FireServer("Solo")
preview.advance(1)
local rp = RM.GetRunPlayer(player)
check("run started without waiting for the lookup", rp ~= nil)
if rp then
	local rerolls0 = rp.Rerolls
	local paid = Gold.AddRunGold(rp, 100)
	check("early gold paid at x1 while unknown", paid == 100, paid)
	preview.advance(DELAY + 2)
	check("lookup answered", MS.PassesKnown(player))
	check("GoldMult published x2", player:GetAttribute("GoldMult") == 2, player:GetAttribute("GoldMult"))
	check("early gold topped up to x2 (200 total)", rp.Gold >= 200 and rp.Gold < 300, rp.Gold)
	local before = rp.Gold
	local later = Gold.AddRunGold(rp, 100)
	check("later gold paid at x2", later == 200, later)
	MS.RefreshAttributes(player)
	check("top-up paid once", rp.Gold == before + 200, rp.Gold - before)
	check("VIP reroll handed over late", rp.Rerolls == rerolls0 + Config.Monetization.VIPExtraRerolls, tostring(rerolls0) .. " -> " .. tostring(rp.Rerolls))
end
if fails == 0 then
	preview.log("PASS pass-warm-regression")
else
	preview.log(string.format("FAIL pass-warm-regression: %d check(s) failed", fails))
end
