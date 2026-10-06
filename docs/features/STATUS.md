# 30-features batch: status at pause (2026-10-05)

The owner asked to wrap up and pause. Everything below is offline-tested only (Lune preview);
nothing has been played in Studio, on a device or in a live server. Each feature has a switch in
`Config.Features`; switching one off restores the previous behaviour.

## Done (switch on)
| # | Feature | Doc |
|---|---|---|
| 2, 9 | Map events (meteor, gold rush, fog), weather (snow storm, lava) | EVENTS.md |
| 3, 5, 7 | Champion mini-bosses, Shrine of Trial, cursed chests | CHALLENGES.md |
| 4, 6, 8 | Secret rooms, merchant cart, lost villager rescue | EXPLORE.md |
| 10, 26, 27, 28 | Boss intro, combo announcer, hit feel, music slots | FEEL.md |
| 12, 13, 14 | Second skill, ultimate, build presets | HEROPOWER.md |
| 11 | Archer, Bard, Golem | HEROES.md |
| 16, 17, 18, 20 | Team combo, ping wheel, co-op boss, spectate | TEAM.md |
| 1, 19, 21-25 | Sigils, team board, weekly challenge, season track, titles, collection book, login streak | META.md |
| 15, 29, 30 | Weapon mastery glows, photo mode, lobby courtyard | LOBBY.md |
| Store | Cosmetic Robux store, all ids 0 ("Coming soon") | STORE.md |
| Groundwork | Switches, save fields, EncounterDirector, FeatureHud, CosmeticData | FOUNDATION.md |

## Wave 3 (2026-10-06)
- Done: UI pass (UI_PASS.md, one portrait FAIL left: minimap over the downed hero's "REVIVING" world
  label), lobby features verified (LOBBY.md), merchant gamepad, single title/name plate, regression fixes
  (sealed secret rooms block spawns inside; WorldFx no longer waits on its folder; favourites grid built on
  open; FeatureHud re-placed only on change). Full run: `bash tools/check.sh` clean,
  `tools/run_regressions.py` 149/149 PASS.
- Balance: Archer and Bard measured inside the existing heroes' range (Archer about Mage, Bard about
  Priest, econ-sim 5 seeds), so left unchanged. NOT RUN: encounter totals with every feature on, team combo
  share and co-op boss weak spot (sims stopped; owner to choose whether to run them).
- Owner: icons/portraits for new content (ICON_CHECKLIST), Store product creation (STORE.md), Studio playtest.
