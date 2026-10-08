# Batch B summary (2026-10-07)

Spec: docs/PROMPT_BATCH_B.md. Branch `claude/batch-b-0rk7j6` (not main, owner's request).
Offline only: type check + Rojo build + the preview regressions. NOT tested in Studio or on a phone.

## Released (switch on)
| Item | Switch | Status | Doc |
|---|---|---|---|
| Elite affix icons + first-sight notice (save `SeenAffixes`) | AffixIcons | PASS offline (affix-sight-regression, layout x3) | AFFIX_ICONS.md |
| Damage number options (Off/Small/Normal/Big, Combine, star crits) | DamageNumberOptions | PASS offline (damage-settings-regression, layout x3, settings-sim) | DAMAGE_NUMBERS.md |
| Evolution preview on cards + BUILD panel Evolutions | EvolutionPreview | PASS offline (evolution regressions, levelup/hud layouts, ui-phone) | EVOLUTION_PREVIEW.md |
| Banish (3 per run) | Banish | PASS offline (banish-regression, levelup layouts) | BANISH.md |
| Revive thank-you (+25 run XP to the reviver) | ReviveThanks | PASS offline (revive-thanks-regression, layout x3) | REVIVE_THANKS.md |

Owner decisions: evolution names show before discovery (OK); damage numbers stay OFF by default
for new players (OK). Thanks XP 25: proposed, not yet confirmed.

## Held by the owner (built, switched off, checks removed from the list)
FinalStand, StageModifiers, PartyQuickLines, Prestige, QuickResume. With the switches off the
game behaves as before. QuickResume: live servers close about 30 s after the last player leaves,
so a 60 s solo hold would mostly be lost; a real resume needs the run rebuilt on a new server.

## Fixes found by the test round
- RunModifiers rolled an unseeded Random at load even with StageModifiers off; it shifted the
  offline preview's random sequence (team-regression boss fight). Now rolled only when on.
- settings-sim and ui_regression know the new settings and the BUILD panel's evolution rows.
- Scene fixes for the affix and revive-thanks checks; the THANKS! button clears the weapon tray.

## Test results
- Full round: 213/253 first pass. Every batch B failure was fixed and re-run to PASS.
- Older failures came from the last batch, were fixed on main and are merged here (re-run PASS:
  settings-sim, team-regression, ui/menu phone + portrait, comeback, team Duo wheel, danger
  arrows portrait, walkthrough).
- Still red, not batch B:
  - starter-bundle / group-bonus / invite regressions and the social Home layouts: main switched
    those features off (owner hold) and the scenes still expect them on.
  - textfit-regression (both) and smart-tutorial layouts: they run past the runner's 360 s limit.
    Run alone, smart-tutorial took 358 s on main and 377 s here, with all 37 checks PASS both times
    and check_layout 0 problems.
- Type check and Rojo build: OK.
