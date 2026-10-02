# SWARM: notes for Claude

Roblox horde-survival roguelite (Rojo + Luau), heroic low-poly fantasy style, overhead camera.
The owner (kcdrewcarter, Roblox user 20194281) plays on a phone, isn't a programmer, and has no
Studio access during sessions, so nothing is verified in Studio unless they say so.

## How to work here
- Chat replies in caveman style (`/caveman full`); code, commits and docs in normal prose.
- Save straight to `main` and push (`git push origin main`). No PRs unless asked.
- Commit messages end with the attribution lines the session provides. Never put model names in code or commits.
- Save tokens: delegate routine work to cheaper subagents, keep prompts short, review only big batches.
- Rebuild and commit `build/Swarm.rbxlx` once at the end of a batch, then send it to the owner:
  `/tmp/sh-tools/rojo/rojo build default.project.json -o build/Swarm.rbxlx`.

## Commands
- `bash tools/check.sh` type check (zero diagnostics) and Rojo build; `--quick` skips the build.
- Preview renderer: `bash tools/preview/render.sh <scene> --device pc|phone|phone-portrait` (see `docs/PREVIEW.md`).
  `stage-sim` is slow: use `--max-time 240` and a long timeout.
- Models: `python3 blender/build.py --only <Name> --samples 12`, `python3 tools/gen_mesh_catalog.py`,
  upload `ROBLOX_USER_ID=20194281 python3 tools/upload_meshes.py --only <Name>`.
- Icons: `art/icons/*.png`, upload `python3 tools/upload_icons.py`, then `python3 tools/gen_icon_data.py`.

## Rules that must hold
- Never pay-to-win: Robux buys cosmetics/coins only; early unlock only for characters also earnable by play.
- Don't publish, deploy, buy assets, create products, invent or change prices, or make purchases.
- Don't enable Studio API access, HTTP or other security settings; give the owner steps.
- Don't wipe saves, reset unlocks or reset public rankings. Studio uses separate `_Studio` DataStores.
- DEV access is enforced on the server (`RunManager.isDev`, `DevAllowlist`); client hiding is not security.
  Runs that used DEV tools are tainted and never reach leaderboards or records.
- Player text (bug reports) always goes through Roblox text filtering; never show unfiltered text.
- No secrets in client code or ReplicatedStorage. No external backend, analytics, ads or subscriptions.
- Never present a mock or unconnected feature as working. Report verified vs assumed (PASS/FAIL/BLOCKED).
- Don't copy Megabonk characters, items, assets or text.

## Where things stand (last batch: 8bcec96)
Done, type-checked and built, NOT tested in Studio: playtest fixes round 1 (sword pose, priority model
loading, DEV panel tabs + unlock everything, arena picker, tutorial callouts, blue XP gems, 3D gold coins
+ purse, chest pause, UI animations), 75 icons wired in, Studio-separate stores + dev taint + idempotent
leaderboard writes, jump/bunny hop (server cap in `speedCheck`, perch push-off), Report a Bug + DEV inbox.

Open / next (release-candidate brief, phases):
- B: safe level-up input (held movement can't confirm a card), Return to Main Menu in pause with confirm.
- C: HUD declutter, typography/motion system, Reduced Motion setting.
- D: leaderboards for highest level / kills in one run / farthest stage, Standard vs Endless split; Endless mode.
- E: one synergy package, one exploration encounter, roster + 2 bosses (Briar Sentinel, Frostbound Colossus),
  snow contrast, milestone character unlocks (Robux hooks only for approved mappings), performance pass,
  final PASS/FAIL/BLOCKED handoff with release checklist and asset manifest.
- Wave F full-game polish pass; review retention batch (curses/daily/leaderboards); sim-test curses
  Frenzy/Fragile/Horde/Elite Surge; stage-sim needs a clean run after this batch.
- Owner side: Studio playtest, enable Studio API access for saves, licensed music, tune jump numbers.
