-- stage-modifiers-ui: the stage modifier on screen (batch B StageModifiers,
-- docs/next/STAGE_MODIFIERS.md): the stage-start card (RunIntro) names the modifier and its
-- effects, the HUD badge (StageModifierUI via FeatureHud) shows its name, the badge hides
-- when the modifier clears and while a panel covers the HUD, and nothing shows with the
-- switch off. Prints PASS / FAIL lines. Registered as a layout check on iphone,
-- phone-portrait and pc: the final frame holds the card with the longest modifier text
-- (--set mod=<Id>, default EliteNight) and the badge.
local A = lib("arena")
local C = lib("common")
local modId = tostring(preview.args.mod or "EliteNight")
local s = A.build({ enemies = 30, seconds = 300, portal = true, stage = 2 })
C.settle(0.5)
local Config = C.shared("Config")
local SMD = C.shared("StageModifierData")
local RunIntro = preview.client("RunIntro")
local UI = preview.client("StageModifierUI")
local UIState = preview.client("UIState")
local fails = 0
local function check(ok: boolean, label: string)
	if not ok then
		fails += 1
	end
	preview.log((ok and "PASS " or "FAIL ") .. label)
end
local function badgeText(): string?
	local found = nil
	for _, gui in ipairs(game:GetService("Players").LocalPlayer.PlayerGui:GetChildren()) do
		local b = gui:FindFirstChild("Badge_stagemod", true)
		if b then
			local label = b:FindFirstChild("Text") :: TextLabel?
			found = label and label.Text or ""
			if not (b :: GuiObject).Visible then
				found = "(hidden)" .. tostring(found)
			end
		end
	end
	return found
end
local function beginStage(stage: number, id: string)
	C.setState({ StageModifier = id })
	C.setState({
		Stage = stage,
		StagePhase = "Explore",
		StageArena = s.Config and s.Config.Arenas.Forest and s.Config.Arenas.Forest.DisplayName or "Forest",
		StageBoss = "Briar Sentinel",
		PortalPos = s.portal and s.portal.Pos or nil,
		PortalHint = false,
		PortalReveal = 0,
		PortalCharge = 0,
		PortalLockLeft = 0,
	})
end

-- 1. a stage with Glass Arena: card line + badge
beginStage(3, "GlassArena")
C.settle(0.8)
local els = RunIntro.Elements()
local text = els.Mod and els.Mod.Text or ""
check(RunIntro.Active(), "the stage card shows when stage 3 begins")
check(els.Mod ~= nil and els.Mod.Visible and string.find(text, "GLASS ARENA", 1, true) ~= nil, "the card names the modifier (" .. text .. ")")
check(string.find(text, SMD.Short("GlassArena"), 1, true) ~= nil, "the card lists its effects")
check(UI.Shown() == "GlassArena" and badgeText() == "GLASS ARENA", "the HUD badge shows GLASS ARENA (" .. tostring(badgeText()) .. ")")

-- 2. the modifier clears (travel / run end): the badge goes
C.setState({ StageModifier = "" })
C.settle(0.3)
check(UI.Shown() == "" and badgeText() == nil, "the badge is removed when the modifier clears")

-- 3. a covering panel hides the badge row (FeatureHud follows UIState)
C.setState({ StageModifier = "Haste" })
C.settle(0.3)
UIState.Open("LevelUp", { Covers = true, Blocks = true })
C.settle(0.4)
local covered = badgeText()
local slot = preview.client("FeatureHud").Visible()
check(slot == false, "a covering panel hides the feature badges (FeatureHud.Visible = " .. tostring(slot) .. ", badge " .. tostring(covered) .. ")")
UIState.Close("LevelUp")
C.settle(0.4)

-- 4. switch off: no badge, no card line
;(Config.Features :: any).StageModifiers = false
UI.Refresh()
check(UI.Shown() == "" and badgeText() == nil, "switch off: no badge")
check(RunIntro.ModifierText(game:GetService("ReplicatedStorage"):FindFirstChild("SwarmState") :: any) == "", "switch off: no card line")
;(Config.Features :: any).StageModifiers = true

-- 5. final frame: the longest modifier on the card + the badge (layout check)
C.setState({ StageModifier = "" })
C.settle(6) -- the earlier card has gone
beginStage(4, modId)
C.settle(0.9)
els = RunIntro.Elements()
check(RunIntro.Active() and els.Mod and els.Mod.Visible, "final frame: the card shows " .. modId .. " (" .. tostring(els.Mod and els.Mod.Text) .. ")")
check(badgeText() == string.upper(SMD.Name(modId)), "final frame: the badge shows " .. tostring(badgeText()))
preview.log(fails == 0 and "stage-modifiers-ui: ALL PASS" or ("stage-modifiers-ui: " .. fails .. " FAIL"))
