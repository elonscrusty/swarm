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

## Wave 3, not done yet (resume here)
- Balance:
  - Archer and Bard take 2-3x the Knight's damage (proposal: Archer cooldown 0.15, Bard SelfShare 0.8).
  - The team combo burst and the co-op boss x1.5 are untested for balance.
  - Run the full econ-sim with every encounter on (total gold/loot added by mini-boss, Trial, merchant, secret rooms, rescue, gold rush).
- Layout:
  - The FeatureHud badge row is cut off at the right edge on phones and covers the TEAM TIP chip on iphone.
  - In portrait, the minimap covers "A teammate is reviving you".
- Merchant: no gamepad purchase.
- Presentation:
  - ChallengesUI was never rendered.
  - The explore labels were not re-rendered after the last move.
- Plates: META's title plate should go through `StoreFx.DecoratePlate` (one plate, not two).
- Emotes are icon pops only.
- Regression: the full `tools/run_regressions.py` run and perf-sim with every feature on; see the lead's latest run below.
- Owner: icons and portraits for new content (ICON_CHECKLIST), Store product creation (STORE.md), and the Studio playtest.
