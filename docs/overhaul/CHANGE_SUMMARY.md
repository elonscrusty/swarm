# SWARM overhaul: change summary

Range: `83be6c9` (Home and retention update, the last release on `main`, 2026-10-04 18:24 UTC)
to `59f533b` (2026-10-04 23:33 UTC), 44 commits, 144 files.
File-by-file map: `FILE_MAP.md`. Issue status: `ISSUE_REGISTER.md`. Tests: `TEST_REPORT.md`,
`ACCEPTANCE.md`. Saves and rollback: `MIGRATION_ROLLBACK.md`.

**Evidence level for everything below:** type check, Rojo build, offline Lune simulations of the
real server and client modules on a mock Roblox API, and preview renders. **Nothing was tested in
Roblox Studio, on a phone or tablet, with a gamepad, or with two real clients.** Nothing was
published, no Robux prices or products changed, no live data or leaderboard was touched.

## Owner decisions (2026-10-04)

| Decision | What it means in the build | Doc |
| --- | --- | --- |
| The approved title screen (01) replaces the home screen built earlier the same day | `LobbyScreen` rebuilt: logo, hero caption, gold PLAY, compact routes; PLAY opens a run-setup step | TITLE.md |
| Compact reward cards replace "every chest rolls" | Common rewards are a short side card with no reel and no click; rare rewards keep a short contained reveal | REWARD.md |
| The Knight's "Whip" is shown as **Sword** | Display name only: "Sword", evolution "Bloodblade". Ids (`Whip`, `Bloodwhip`), saves and icons unchanged | HERO_ART.md |
| Gold Trim stays gold | The sold Starter Pack skin keeps its gold cape and plume; no change to its data | HERO_ART.md, TITLE.md |
| Balance: MaxTier 16 and the boss HP steps kept | `Difficulty.MaxTier` 12 -> 16, `Stages.BossHPByStage` stages 3-5 0.85 / 1.35 / 2.0 | BALANCE_TUNE.md 1 |
| Balance: armor cap, elite gold and chest exponent "as written" rejected by the data | Measured, not applied: each made stage 2 harder or did nothing late | BALANCE_TUNE.md 2b |
| Balance: owner chose "stage 3+ only" | New `Chests.LateCostExponent` 0.75 (pricier chests and Shrine of Chance from stage 3, capped at the stage 5 ratio) and `Gold.EliteLateStageScale` 0.05 (less elite-chest gold from stage 3). Stages 1-2 identical. No armor, Robux or pass change | BALANCE_TUNE.md 5 |
| Settings screen design is excluded | Only functional fixes; the existing screen opens unchanged from the new run menu | SETTINGS_TEST.md, DUO_MENU.md |
| No weapon combining, fusion or new evolution system | None added; existing evolutions untouched | UPGRADE_UI.md |

## 1. Gameplay integrity

- **Corner farming fixed (root cause).** Enemies near a player standing at a wall steered along
  the wall *behind* the player and crawled at about a tenth of their speed. The look-ahead ray now
  stops at the target, starts 1 stud above the floor (it missed low colliders) and has a contact
  fallback and a fixed side for head-on blocks. No damage to stationary players, no teleports, no
  buffs. Offline: 177 failures before, 0 after, in all six arenas (CORNER_REPORT.md).
- **Sustain checked separately:** after the fix a fresh build in the corner takes three times the
  damage it heals, so no sustain nerf was needed (BALANCE_AUDIT.md 5.3).
- **Upgrade choice state on the server.** Solo: the panel now really freezes the world (it did
  not before). Duo/Trio: only the chooser is rooted and protected, for at most 10 s per panel and
  about 20 s per minute; the team plays on. Stale or duplicate picks are ignored (`OfferId`).
  The run menu and reward reveals never protect in a group run (CHOICE_STATE.md).
- **Group stage-clear countdown** waits up to 12 s for a teammate who is choosing an upgrade
  (NOTIFY_SERVER.md 3).

## 2. UI and state flow

- **One coordinator, `UIState`:** one shown panel owns input, by priority (Travel > Results >
  Revive > LevelUp > Portal > Reward > Run menu); one objective slot, one headline lane, one short
  notice lane with semantic ids, coalescing and expiry; one `Reset` for death, travel and leaving.
  Fixes the duplicate portal heading, caravan toast over its bar, elite toast over the wave
  heading, four stacked notices, upgrade over the stage-clear dialog, and reel + headings + chest
  prompt together (UI_STATE_CONTRACT.md, UISTATE.md). The server now tags every notice with an
  id, lane and class (NOTIFY_SERVER.md).
- **Seven approved screens built as real UI:** title and run setup (TITLE.md); desktop and mobile
  HUD with BUILD details (HUD.md); upgrade choice cards with "FINAL UPGRADE" and a server-driven
  countdown (UPGRADE_UI.md); compact reward card and recent-rewards list (REWARD.md); results with
  a gold ledger and three separate progress cards (RESULTS.md); run menu drawer with a truthful
  "game not paused" label and a LEAVE RUN confirmation (DUO_MENU.md).
- **Return flow:** after a defeat the player goes to the main lobby in one step, with no second
  countdown; STAY holds the results (FLOW.md 1).
- **Leaderboards:** the "Your best" card shows the row's own value and names the save's best
  separately; no score written or deleted (FLOW.md 2).
- **Copy:** device-aware prompts (`InputPrompts`), "Portal" everywhere, "m" as the unit, damage
  reduction and max-HP qualifiers, staged opening tips, real boss name in the run-start line
  (COPY.md, NOTIFY_SERVER.md). Not done: solo wording for "every teammate" strings and the
  "Optional" caravan label (ISSUE_REGISTER CP-02, CP-05).

## 3. Balance

- Audit of every gold source, chest price, rarity table and the recorded examples; all recorded
  prices and the 505 / 176 / 329 settlement reproduced exactly (BALANCE_AUDIT.md).
- Applied (see owner decisions): MaxTier 16, boss HP steps on stages 3-5, stage 3+ chest prices
  and elite-chest gold. In the bot cohorts stages 1-2 are identical; a greedy buyer affords 68-75 %
  of stage 4-5 chests instead of 96-100 %; stage 3 bosses last about 30 s instead of 25 s.
  An established armoured build still does not drop below 60 % HP (goal not met; armor was out of
  scope) (BALANCE_TUNE.md).
- Chest odds text says "before luck"; Bargain text says "added to damage bonus".

## 4. Art and feel

- Enemies: partial, contour-keeping hit flash; darker mite sides; crimson elite rings; Swift aura
  blue; recoloured Scorpion Queen and Moth Matriarch meshes (ENEMY_ART.md).
- Hero effects: Healing Totem idol mesh, Vine Snare roots with a grip animation, soul bolts with a
  green tail, dashed friendly rings, coins and gems kept off the hero (VFX_ART.md).
- Props: one chest construction per tier matching the icons, rune monuments with glyphs and
  states, shrine crowns, quieter portal beams, caravan cart (PROPS_ART.md).
- World: stepped arena corners, capped rims, the false fence removed, pond banks, hazard circles
  matched to their meshes; collision unchanged (WORLD_ART.md).
- Heroes: less Metal sheen and one-step-darker ivory on Knight, Priest, Engineer, Necromancer and
  pale skins (HERO_ART.md). Shared vocabulary: ART_VOCABULARY.md. Asset list: ASSET_REGISTER.md.
- Audio: voice reserve and ducking for warnings, new elite and UI cues from existing sound ids
  (AUDIO_MIX.md). Nobody has listened to it.

## 5. Technical safety

- All 36 client remotes reviewed and fuzzed offline; purchase receipts idempotent, failed saves
  retried, malformed receipts refused (SAFETY.md 1-2).
- **Save race fixed:** a fast rejoin to the same server could load the save from before the
  leave save and roll it back; the load now waits for that save (SAFETY.md 3).
- Settings echo fixed: a profile sync no longer flips a just-changed setting back
  (SETTINGS_TEST.md).
- DEV commands checked inert for ordinary users on a live-mode server (SAFETY.md 4).
- **No save schema change** (still 7); see MIGRATION_ROLLBACK.md.

## Known gaps (short)

Open in the register: UI-11, UI-30, CP-02, CP-05, CP-11, CP-16, ART-22, ART-24. Blocked: UI-61
(gamepad), TS-08 (two-client duo). No after-overhaul performance run. Every Studio, device and
multiplayer check is still owed by the owner (MIGRATION_ROLLBACK.md, owner steps). This build is
**not** release-verified.
