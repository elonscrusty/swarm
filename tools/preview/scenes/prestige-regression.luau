-- prestige-regression: Prestige (Config.Features.Prestige; docs/next/PRESTIGE.md).
--   default (server, real GameServer):
--     1) refused: switch off, not owned, in a run, not maxed, stale stars; nothing changes
--     2) a maxed hero: its upgrade levels reset to 0 and it gets one star, exactly once
--        (a repeat with the old star count is ignored); gold, mastery XP, skins and the
--        other heroes are untouched; the remote path does the same; a cooldown holds
--     3) the cap: never more than 5 stars; junk saves are cleaned (whole stars 1..5)
--     4) gold: the bonus is paid only at settlement (GoldSystem.SettleRun: +5% per star of
--        kept + survival, +25% at most), once per run, none for a DEV-tainted run; in-run
--        gold (AddRunGold, chest money) is the same with or without stars
--   --set case=confirm (client, registered as a layout check on iphone / phone-portrait /
--     pc): the Characters screen with a maxed Knight (1 star): the PRESTIGE block and
--     PRESTIGE KNIGHT, the confirmation screen with the owner's exact text, the first tap
--     only arms, a second within 3 s sends once, an armed tap expires after 3 s. The last
--     frame shows the confirmation screen for check_layout.
-- PASS / FAIL lines; any FAIL fails the regression.
local C = lib("common")
local Players = game:GetService("Players")
local me = Players.LocalPlayer

local fails = 0
local function check(label: string, ok: any, detail: string?)
	if not ok then
		fails += 1
	end
	preview.log(string.format("%s  %s%s", ok and "PASS" or "FAIL", label, detail and ("  (" .. detail .. ")") or ""))
end

local function maxTrack(MetaUpgradeData, heroId: string): { [string]: number }
	local t = {}
	for _, id in ipairs(MetaUpgradeData.HeroOrder()) do
		local def = MetaUpgradeData.HeroDef(heroId, id)
		if def then
			t[id] = def.MaxLevel
		end
	end
	return t
end

------------------------------------------------------------------------------------------
-- case=confirm: the client screens (layout)
------------------------------------------------------------------------------------------
if preview.args.case == "confirm" then
	C.lobby()
	C.startClient()
	local Config = C.shared("Config")
	local MetaUpgradeData = C.shared("MetaUpgradeData")
	local PrestigeData = C.shared("PrestigeData")
	check("exact owner text for the first star",
		PrestigeData.ConfirmText("Knight", 1) == "Your Knight's upgrades go back to level 0. You keep your gold, skins and other heroes. You get \u{2605}1 and +5% gold with the Knight.",
		PrestigeData.ConfirmText("Knight", 1))
	check("button text", PrestigeData.ButtonText("Knight") == "PRESTIGE KNIGHT")
	local sentLog = {}
	preview.remote("Prestige").OnServerEvent:Connect(function(_p, hero, stars)
		table.insert(sentLog, { Hero = hero, Stars = stars })
	end)
	local p = C.profile({
		Heroes = { Knight = { XP = 999999, Runs = 40 }, Mage = { XP = 40, Runs = 1 } },
		HeroUpgrades = { Knight = maxTrack(MetaUpgradeData, "Knight"), Mage = { MaxHP = 2 } },
		Features = { Prestige = { Knight = 1 } },
	})
	C.sendProfile(p)
	C.settle(1)
	C.fire("OpenPanel", "Characters")
	C.settle(1.5)
	local block = preview.findGui(function(g) return g.Name == "Prestige" and g:IsA("Frame") and g.Parent and g.Parent.Name == "Unlock" end)[1]
	check("PRESTIGE block shows for the maxed Knight", block ~= nil and block.Visible)
	local badge = preview.findGui(function(g) return g.Name == "PrestigeBadge" and g:IsA("TextLabel") and g.Visible end)
	check("star badge on the portrait / roster", #badge >= 1 and badge[1].Text == "\u{2605}1", tostring(#badge))
	local button = preview.findGui(function(g) return g:IsA("GuiButton") and g.Name == "PrestigeButton" end)[1]
	check("PRESTIGE KNIGHT button visible", button ~= nil and button.Visible and button.Text == "PRESTIGE KNIGHT", button and button.Text or "none")
	local Confirm = preview.client("PrestigeConfirm")
	local UIState = preview.client("UIState")
	if button then
		-- the details panel scrolls: bring the block into view first
		local scroll = preview.findGui(function(g) return g:IsA("ScrollingFrame") and g.Name == "Scroll" and g.Parent and g.Parent.Parent and g.Parent.Parent.Name == "Details" end)[1]
		if scroll and block then
			local y = block.AbsolutePosition.Y - scroll.AbsolutePosition.Y + scroll.CanvasPosition.Y
			scroll.CanvasPosition = Vector2.new(0, math.max(0, y - 80))
			C.settle(0.3)
		end
		preview.click(button)
		C.settle(0.6)
	end
	local d = Confirm.Debug()
	check("confirmation screen open (UIState primary)", d.Open and UIState.IsShown("PrestigeConfirm"))
	check("confirmation text is the owner's sentence for the next star", d.Text == PrestigeData.ConfirmText("Knight", 2), d.Text)
	local confirmBtn = preview.findGui(function(g) return g:IsA("GuiButton") and g.Name == "PrestigeConfirmButton" end)[1]
	check("confirm button reads PRESTIGE KNIGHT", confirmBtn ~= nil and confirmBtn.Text == "PRESTIGE KNIGHT", confirmBtn and confirmBtn.Text or "none")
	if confirmBtn then
		preview.click(confirmBtn)
		C.settle(0.2)
		check("first tap only arms (nothing sent)", #sentLog == 0 and Confirm.Debug().Armed)
		preview.advance(Config.Prestige.ConfirmSeconds + 0.5, 20)
		check("an armed tap expires after 3 s", not Confirm.Debug().Armed and #sentLog == 0)
		preview.click(confirmBtn)
		C.settle(0.3)
		preview.click(confirmBtn)
		C.settle(0.3)
		check("second tap within 3 s sends once", #sentLog == 1 and sentLog[1].Hero == "Knight" and sentLog[1].Stars == 1, tostring(#sentLog))
		check("screen closes after sending", not Confirm.Debug().Open and not UIState.IsOpen("PrestigeConfirm"))
		preview.click(confirmBtn)
		C.settle(0.3)
		check("a tap after closing sends nothing", #sentLog == 1)
	end
	-- the last frame: the confirmation screen open for check_layout
	Confirm.Open("Knight", 1)
	C.settle(1)
	check("confirmation screen reopens for the layout frame", Confirm.Debug().Open)
	preview.log(fails == 0 and "PASS prestige confirm screen" or ("FAIL prestige confirm screen: " .. fails .. " failed"))
	return
end

------------------------------------------------------------------------------------------
-- default: the server rules
------------------------------------------------------------------------------------------
preview.forceMeshesUploaded()
preview.startServer()
preview.advance(2)

local Config = C.shared("Config")
local MetaUpgradeData = C.shared("MetaUpgradeData")
local PrestigeData = C.shared("PrestigeData")
local RM = preview.server("RunManager")
local DS = preview.server("DataService")
local GS = preview.server("GoldSystem")
local PR = preview.server("Prestige")

check("Prestige switch on by default", Config.Features.Prestige == true)
check("PROPOSED numbers: +5% per star, max 5, cap 25%", Config.Prestige.GoldPerStar == 0.05 and Config.Prestige.MaxStars == 5 and Config.Prestige.GoldCap == 0.25)

local data = assert(DS.GetData(me), "profile missing")
data.OwnedCharacters = { Knight = true, Mage = true }
data.SelectedCharacter = "Knight"
data.TutorialDone = true
data.FirstRunBonus = true
data.Gold = 5000
data.Heroes = { Knight = { XP = 999999, Runs = 50 }, Mage = { XP = 620, Runs = 3 } }
data.HeroUpgrades = { Knight = { MaxHP = 20, Might = 20, Armor = 8 }, Mage = { MaxHP = 6, Might = 3, Signature = 1 } }
data.Skins = { Knight = "Default" }
data.Prestige = nil

local now = 1000
PR._SetClock(function()
	return now
end)

local function snapshotOther()
	local m = data.HeroUpgrades.Mage
	return string.format("%d/%d/%d/%d", m.MaxHP or 0, m.Might or 0, m.Signature or 0, data.Heroes.Mage.XP)
end
local otherBefore = snapshotOther()

-- 1) refusals
local ok, why = PR.Request(me, "Knight", 0)
check("refused when the track is not maxed", not ok and why == "notmaxed" and data.HeroUpgrades.Knight.MaxHP == 20 and (data.Prestige == nil or next(data.Prestige) == nil), why)
data.HeroUpgrades.Knight = maxTrack(MetaUpgradeData, "Knight")
check("a fully bought track counts as maxed", PrestigeData.IsMaxed("Knight", data.HeroUpgrades.Knight))
ok, why = PR.Request(me, "Rogue", 0)
check("refused for a hero not owned", not ok and why == "notowned", why)
ok, why = PR.Request(me, "Nobody", 0)
check("refused for an unknown hero", not ok and why == "hero", why)
ok, why = PR.Request(me, "Knight", 2)
check("refused with stale stars", not ok and why == "stale" and PrestigeData.Stars(data.Prestige, "Knight") == 0, why)
ok, why = PR.Request(me, "Knight", "0")
check("refused with junk stars", not ok and why == "stale", why)
Config.Features.Prestige = false
ok, why = PR.Request(me, "Knight", 0)
check("switch off: refused, nothing changes", not ok and why == "off" and data.HeroUpgrades.Knight.MaxHP == 20, why)
Config.Features.Prestige = true
local realParticipant = RM.IsParticipant
RM.IsParticipant = function()
	return true
end
ok, why = PR.Request(me, "Knight", 0)
RM.IsParticipant = realParticipant
check("refused during a run", not ok and why == "inrun" and data.HeroUpgrades.Knight.MaxHP == 20, why)

-- 2) the prestige: reset + star, exactly once
local goldBefore, xpBefore = data.Gold, data.Heroes.Knight.XP
ok, why = PR.Request(me, "Knight", 0)
local cleared = true
for _, id in ipairs(MetaUpgradeData.HeroOrder()) do
	if (data.HeroUpgrades.Knight[id] or 0) ~= 0 then
		cleared = false
	end
end
check("maxed hero: prestige applied", ok and why == "ok", why)
check("every Knight upgrade back to level 0", cleared)
check("Knight gets star 1", PrestigeData.Stars(data.Prestige, "Knight") == 1)
check("gold, mastery XP and skins untouched", data.Gold == goldBefore and data.Heroes.Knight.XP == xpBefore and data.Skins.Knight == "Default")
check("other heroes untouched", snapshotOther() == otherBefore and PrestigeData.Stars(data.Prestige, "Mage") == 0)
ok, why = PR.Request(me, "Knight", 0)
check("a repeated request (old star count) is ignored", not ok and PrestigeData.Stars(data.Prestige, "Knight") == 1, why)
data.HeroUpgrades.Knight = maxTrack(MetaUpgradeData, "Knight")
ok, why = PR.Request(me, "Knight", 1)
check("cooldown holds a second prestige right away", not ok and why == "cooldown" and data.HeroUpgrades.Knight.MaxHP == 20, why)
now += Config.Prestige.CooldownSeconds + 1
preview.fireServerAs(me, "Prestige", "Knight", 1)
preview.advance(0.3)
check("remote path: star 2 and a reset", PrestigeData.Stars(data.Prestige, "Knight") == 2 and (data.HeroUpgrades.Knight.MaxHP or 0) == 0)
now += Config.Prestige.CooldownSeconds + 1
preview.fireServerAs(me, "Prestige", "Knight", 2)
preview.advance(0.3)
check("remote path: refused when not maxed again", PrestigeData.Stars(data.Prestige, "Knight") == 2)

-- 3) the cap
data.Prestige.Knight = 5
data.HeroUpgrades.Knight = maxTrack(MetaUpgradeData, "Knight")
now += 100
ok, why = PR.Request(me, "Knight", 5)
check("cap: no sixth star", not ok and why == "max" and data.Prestige.Knight == 5 and data.HeroUpgrades.Knight.MaxHP == 20, why)
local cleaned = PrestigeData.Clean({ Knight = 9, Mage = 2.7, Rogue = -1, [5] = 3, Priest = 0 / 0 })
check("junk saves cleaned: whole stars 1..5", cleaned.Knight == 5 and cleaned.Mage == 2 and cleaned.Rogue == nil and cleaned.Priest == nil and cleaned[5] == nil)
check("bonus rate capped at +25%", PrestigeData.BonusRate(5) == 0.25 and PrestigeData.BonusRate(9) == 0.25 and math.abs(PrestigeData.BonusRate(2) - 0.10) < 1e-9 and PrestigeData.BonusRate(0) == 0)

-- 4) gold: settlement only, capped, once, never DEV-tainted
data.Prestige = { Knight = 2 }
local function fakeRun(id: string, hero: string)
	return { Player = me, RunId = id, CharacterId = hero, Gold = 0, Kills = 0, Level = 1, Stats = { GoldMult = 1 } }
end
local plain = fakeRun("prestige-plain", "Mage")
GS.BeginRun(plain)
local plainPaid = GS.AddRunGold(plain, 100)
local plainSettle = GS.SettleRun(plain, true, 1, 0)
local starred = fakeRun("prestige-starred", "Knight")
GS.BeginRun(starred)
local starredPaid = GS.AddRunGold(starred, 100)
check("in-run gold is the same with stars (chest money unchanged)", starredPaid == plainPaid and starred.Gold == plain.Gold, string.format("%d vs %d", starredPaid, plainPaid))
check("no star bonus before settlement", data.RunEscrow and data.RunEscrow.Gold == starredPaid)
local before = data.Gold
local settle = GS.SettleRun(starred, true, 1, 0)
local expect = math.floor((settle.Retained + settle.Survival) * 0.10)
check("settlement pays +10% for 2 stars", settle.Prestige == expect and data.Gold == before + settle.Retained + settle.Survival + settle.Group + expect, string.format("%s / %s", tostring(settle.Prestige), tostring(expect)))
check("a hero without stars gets no bonus", plainSettle.Prestige == 0)
local again = GS.SettleRun(starred, true, 1, 0)
check("settling again pays nothing more", again == settle and data.Gold == before + settle.Retained + settle.Survival + settle.Group + expect)
data.Prestige = { Knight = 5 }
local capped = fakeRun("prestige-cap", "Knight")
local paidCap = PR.Settle(capped, 1000, data)
check("5 stars: +25% (the cap)", paidCap == 250, tostring(paidCap))
check("Settle is once per run", PR.Settle(capped, 1000, data) == 250 and capped.PrestigeBonusPaid == 250)
local dev = fakeRun("prestige-dev", "Knight")
dev.DevTainted = true
local goldDev = data.Gold
check("DEV-tainted run: no bonus", PR.Settle(dev, 1000, data) == 0 and data.Gold == goldDev)
data.DevBoosted = true
check("DevBoosted profile: no bonus", PR.Settle(fakeRun("prestige-boost", "Knight"), 1000, data) == 0)
data.DevBoosted = false
Config.Features.Prestige = false
check("switch off: no bonus", PR.Settle(fakeRun("prestige-off", "Knight"), 1000, data) == 0)
Config.Features.Prestige = true
check("profile view carries Prestige", type(DS.FeatureView(data).Prestige) == "table" and DS.FeatureView(data).Prestige.Knight == 5)

PR._SetClock(nil)
preview.log(fails == 0 and "PASS prestige rules" or ("FAIL prestige rules: " .. fails .. " failed"))
