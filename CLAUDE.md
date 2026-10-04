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

## Where things stand (last batch: fixes and polish pass, branch claude/relaxed-shannon-t6qo8p)
Done, type-checked and built, offline-preview tested, NOT tested in Studio: DEV access via server
`DevAccess` (Studio + `DevAllowlist`) with the DevAccess player attribute, Invincible toggle, pause
MAIN MENU (`AbandonRun`), High Score board (`LeaderboardService.RunScore`), HUD HP numbers, icon
checklist (`docs/ICON_CHECKLIST.md`, `tools/gen_icon_checklist.py`), icon preload (`AssetPreload`),
livelier level-up cards + safe input, chest hold 0.4 s + reward reel, XP crystals + merging +
once-per-flight replication, Fire Trail rebuild, CombatFx, lobby/HUD/results animation, perf pass
(`perf-sim` scene). Owner art (136 pictures) uploaded and wired (`ArtData`, `tools/upload_art.py`); lobby screens rebuilt
to the owner's mockups. Monetization live and owner-verified in Studio: 3 passes + 4 products in
`Config.Monetization` (owner chose to keep Revive and the VIP reroll as they are). Skin passes not
set up yet. Scenes: `menu-sim`, `perf-sim`,
`xp-sim`, `rewards-sim`, `combat-fx`, `pickups-close`, `icons`.

Content batch (offline-preview tested, NOT Studio-tested unless the owner says so): HUD rebuilt to the
owner mockup (HP/XP panel under the timer, stage pill top left), level-up cards and Characters screen to
owner mockups, brighter arenas, Endless mode + ScoreEndless/Level boards, Briar Sentinel and Frostbound
Colossus bosses with Blender meshes (+ Thorn Sprout), synergy package (SynergyData), Lost Caravan
encounter (CaravanEvent), parties (PartyService, MenuParty), co-op level-up/chest no longer freezes the
team, portal chargeable at once, drag-to-spin lobby hero, hero gold prices doubled (owner).

Post-Codex batch (offline-tested, 45/45 regressions, NOT Studio-tested): XP curve x1.5 (Base 30,
PerLevel 12, after-cap 6) + Config.XP.CoopShare (co-op per-player pace ~ solo), portal reveal
(PortalBeacon, banner, sound, always-on arrow, minimap ping), discovery-gated combo clues
(DiscoveryService, save field Discovered), one-line card summaries, last-run lobby card + validated
RETRY (MenuLastRun), journal lists discovered first. Codex handoff notes: docs/CLAUDE_HANDOFF.md.

Publish-readiness pass (61/61 regressions incl. 16 layout checks via tools/preview/check_layout.py,
NOT Studio-tested): phone shrink-before-truncate toggles/tabs, short stage objectives on phones,
minimap/tip/shrine placement, level-up touch regressions, Priest_Angel pass picture fixed.
Owner steps and per-area PASS/BLOCKED: docs/RELEASE_CHECKLIST.md.

Full-game sweep (65/65 regressions, offline only, NOT Studio-tested; details in
docs/RELEASE_CHECKLIST.md section 0): fixes across server, HUD, lobby and combat; chest
"not enough gold" fix (server prices with the published GoldMult); run-server Knight mesh swap;
fall-through rescue + travel hold (fall-regression); proximity partner revive (no button);
new minimap; centre banner queue (Hud.Announce / Hud.ReserveCentre); stage-start card
(RunIntro); readable Shrine of Chance; every chest plays the reel (mini reel when not paused);
results REPORT A BUG; enemy screen culling + low-detail models instead of plain bodies;
smoother stage scaling and gentler opening; 26 original SFX (tools/synth_sfx.py,
docs/AUDIO.md); 3D cliff edges, path detail, props, premium paid chests; brighter lighting;
Whip/Longbow auto aim; bigger Garlic Aura; stronger Healing Totem; gold kept on a loss 35%
(owner); menu animation (UIAnim); playtime leaderboard tab (home board removed by owner).
HELD for a later update (built + tested, switched off): 10 new weapons (WeaponData.HeldOrder),
11 new passives + 2 synergies (PassiveData.HeldOrder, SynergyData Held), numbered-wave rework
(patch kept outside the tree; re-do from the owner's spec: waves only, each harder).
Hero Mastery update (70/70 regressions, offline only, NOT Studio-tested): per-hero upgrades
(Config.HeroMastery, MetaUpgradeData StatOrder/AccountOrder/Signature, save schema 7 with
Heroes/HeroUpgrades; old shared stat levels copied to every hero), numbered waves (each harder,
Config.Waves; banner on wave 1, every 5th and stage starts), 10 weapons + 11 passives + 2
synergies released with art, hero prices 10k/20k/30k (owner), new boss/medal/symbol art, Whip
aim fix (whip-regression), client-drawn censer clouds and orbits, stats chip/tutorial/party
entrance fix, audit fixes (docs/AUDIT_2026-10-04.md). PUBLISH NOTE: schema bump, so after
publishing run "Migrate to Latest Update"; test with a copy of a real save first.
Pending owner OK (approved in chat but must be re-confirmed by the owner's own message):
economy changes in scratchpad ECON_PROPOSAL (20k per-level cap, more gold per run, harder
achievement heroes). Planned next: Sigils (docs/SIGILS_PLAN.md).

Open / next (release-candidate brief, phases):
- E: one synergy package, one exploration encounter, roster + 2 bosses (Briar Sentinel, Frostbound Colossus),
  snow contrast, milestone character unlocks (Robux hooks only for approved mappings), performance pass,
  final PASS/FAIL/BLOCKED handoff with release checklist and asset manifest.
- Wave F full-game polish pass; review retention batch (curses/daily/leaderboards); sim-test curses
  Frenzy/Fragile/Horde/Elite Surge; stage-sim needs a clean run after this batch.
- Owner side: Studio playtest, enable Studio API access for saves, licensed music, tune jump numbers.
