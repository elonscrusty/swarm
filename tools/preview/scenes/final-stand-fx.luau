-- final-stand-fx: Final Stand's client side (FinalStandFx.lua, batch B FinalStand,
-- docs/next/FINAL_STAND.md). The server's player attribute "FinalStand" gives the hero a
-- crimson-gold aura and one "FINAL STAND!" headline through UIState; the aura goes when the
-- attribute clears; Reduced effects keeps a smaller aura without the light; the switch off
-- shows nothing. Prints PASS / FAIL lines. Registered as a layout check on iphone and
-- phone-portrait: the final frame holds the headline banner over the arena.
local A = lib("arena")
local C = lib("common")
A.build({ enemies = 30, seconds = 200, stage = 2 })
C.settle(1)
local Config = C.shared("Config")
local FX = preview.client("FinalStandFx")
local UIState = preview.client("UIState")
local Settings = preview.client("ClientSettings")
local me = game:GetService("Players").LocalPlayer
local fails = 0
local function check(ok: boolean, label: string)
	if not ok then
		fails += 1
	end
	preview.log((ok and "PASS " or "FAIL ") .. label)
end

-- 1. the buff starts: aura + one headline
local before = FX.Debug().Headlines
C.setPlayer({ FinalStand = Config.FinalStand.Seconds })
C.settle(0.3)
local d = FX.Debug()
check(d.Aura and d.Light and d.Embers > 0, "the aura shows (embers " .. tostring(d.Embers) .. ", light " .. tostring(d.Light) .. ")")
check(d.Headlines == before + 1, "one FINAL STAND! headline raised")
check(UIState.HeadlineSeen("player.finalstand"), "the headline went through UIState")

-- 2. the buff ends: aura gone
me:SetAttribute("FinalStand", nil)
C.settle(0.2)
check(not FX.Debug().Aura, "the aura is removed when the buff ends")

-- 3. Reduced effects: fewer embers, no light
Settings.Set("ReducedEffects", true)
C.setPlayer({ FinalStand = Config.FinalStand.Seconds })
C.settle(0.2)
local r = FX.Debug()
check(r.Aura and not r.Light and r.Embers < d.Embers, "Reduced effects: smaller aura, no light (embers " .. tostring(r.Embers) .. ")")
me:SetAttribute("FinalStand", nil)
Settings.Set("ReducedEffects", false)
C.settle(0.2)

-- 4. switch off: nothing
;(Config.Features :: any).FinalStand = false
local n = FX.Debug().Headlines
C.setPlayer({ FinalStand = Config.FinalStand.Seconds })
C.settle(0.2)
check(not FX.Debug().Aura and FX.Debug().Headlines == n, "switch off: no aura, no headline")
me:SetAttribute("FinalStand", nil)
;(Config.Features :: any).FinalStand = true

-- 5. final frame: the headline banner (after the dedupe window) for the layout check
C.settle(7)
C.setPlayer({ FinalStand = Config.FinalStand.Seconds })
C.settle(0.6)
local showing = UIState.HeadlineShowing()
check(showing ~= nil and showing.Id == "player.finalstand", "final frame: the FINAL STAND! banner is up (" .. tostring(showing and showing.Title) .. ")")
preview.log(fails == 0 and "final-stand-fx: ALL PASS" or ("final-stand-fx: " .. fails .. " FAIL"))
