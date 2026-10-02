# Polish report (Wave F)

Sweep of the whole game in the offline preview renderer plus a code grep, after the content
batch (new HUD, level-up cards, Characters, lobby screens, Endless, bosses, party, synergy,
caravan). Nothing here was tested in Studio.

## What was checked

**Renders** (`--set images=loaded`, `pc`, `phone`, `phone-portrait`; 0 game errors and only the
known `Lighting.Technology` mock warning in every scene):

- Lobby: `menu`, `characters`, `upgrades`, `settings`, `stats`, `countdown`, `curses`, `daily`,
  `leaderboards`, `track`, `arenas`, `party`, `items`, `bugreport`.
- In run: `arena`, `rewards`, `levelup`, `results`, `pause`, `revive`, `team`, `tutorial`,
  `stage-portal`, `stage-arrow`, `stage-choice`, `loot`, `combat-fx`, `enemy-telegraphs`, `boss`.
- DEV (`--studio`, pc + phone): `dev`, `dev-inbox`. Also `loading`, `icons`, `pickups-close`,
  `models`, `arena-map` (pc).
- Skipped: the slow `*-sim` scenes. `stage-sim` was not run either: the machine was shared
  with other agents' renders (load ~12 on 4 cores) and the plain scenes alone took ~40 min.

Hatched squares in the renders are icons uploaded through `tools/upload_icons.py` (weapon and
passive tiles, `portal`, `revive`, item icons): the preview draws only owner art from
`art/uploaded_art.json` for real, so these are expected, not missing art.

**Code grep** over `src/`:

- Leftover `print`: only three one-off boot lines (server ready, MeshService timings). Kept.
- `TODO` / `FIXME` / `HACK`: none.
- Unused locals / shadowing / unreachable code (`luau-analyze` lints with type checking off):
  none.
- `warn` in normal play: all are on failure paths (DataStores, filter, handler errors). The
  per-frame server step errors are already throttled to one per 5 s per system. The
  `MapBuilder` "collider / pool skipped" warnings only fire when a layout entry lands in the
  spawn clearing (none appeared in the renders).
- Remotes: every client→server remote goes through `Remotes.Listen` (token bucket per player
  and remote, pcall). The one direct `OnServerEvent` (`LootHold` release) is intentional and
  documented: a release must never be dropped, and it only clears a hold.

## Fixed

1. **Boss objective ran under the health panel on phones** (`Hud.lua`): "STAGE 1 · DEFEAT THE
   SCORPION QUEEN" overlapped the HP/XP panel in landscape phone (worse with Endless and
   Frostbound Colossus). The layout now stores the room left of the health panel; a boss goal
   measured wider than that switches to "DEFEAT THE BOSS" (the boss bar right below names the
   boss). Once shortened it stays short for that boss, so it never flickers. PASS in
   `boss --device phone`; pc keeps the full name.
2. **Item popups covered the ability panel on phones** (`LootUI.lua`): two popups in the left
   column ran over the WEAPONS / PASSIVES panel. In landscape the column now only keeps as
   many popups as fit above the panel when the two share columns (newest stay, 1 to 3).
   PASS in `loot --device phone`.
3. **Countdown and lobby CURSES lines hid the gold bonus** (`LobbyScreen.lua`): "Frenzy,
   Horde · +45% ..." truncated the reward. The line is now "+45% gold · Frenzy, Horde", so
   truncation eats curse names, not the bonus. PASS in `countdown --device phone`.
4. **Leaderboard list showed 1.5 rows on phones** (`MenuLeaderboards.lua`): on short screens
   the HIGH SCORE tab drops its subtitle (the heading and the STANDARD / ENDLESS switch already
   name the board), which gives the list one more row. Other tabs keep their subtitle.
5. **Toasts looked like the old style** (`UIBuilder.lua`): toast pills now have the thin gold
   rim of the HUD pills instead of the grey panel edge. PASS in `enemy-telegraphs`.
6. **Items list BACK button showed a check mark** (`LootUI.lua`): now the chevron the other
   BACK buttons use.

`bash tools/check.sh --quick`: TYPECHECK ok, COMPILE ok, icon art 0 problems.

## Remaining suggestions (ranked)

1. **Phone scale work in progress affects layouts.** Renders taken while the phone UI scaling
   change was mid-edit show the lobby left cards overlapping ("CHARACT...", subtitles under the
   next card) in `party` / `countdown` phone, and the leaderboards YOUR BEST card hanging below
   the panel. Re-render `menu`, `countdown`, `party`, `leaderboards` on phone once that change
   lands. (Owned by the scaling agent; not touched here.)
2. **Overlays don't hide the HUD behind them** (dimmers / z-order, owned by the scaling agent):
   the LEVEL UP! title sits over the HP panel and the weapons panel shows through "Choose one
   upgrade" in phone portrait; the revive and stage-choice panels overlap the HP panel edge.
3. **Results on landscape phones**: the scroll area ends mid-way through the account XP block
   (the UNLOCKED line is cut until scrolled). Consider shrinking the stat tiles on short
   screens or pinning the XP block above the buttons.
4. **Naming**: the lobby button says TRACK but its screen title is ACCOUNT LEVEL; the
   Characters screen title is spaced sans caps while every other screen uses the serif title.
   Pick one each (owner design call).
5. **Enemy intro toast** uses a hyphen ("New: Spitter - dodge the acid", `EnemySpawner.lua`,
   owned by the perf agent now): "New: Spitter · dodge the acid" would match the rest of the UI.
6. **Characters skin cards on phones** truncate names ("Crimson G...", "Shadow K...") and the
   card bottoms touch the EQUIPPED button; a two-line name or a smaller caption would fit.
7. **DEV panel on phones** truncates "+10 account le..." and covers the PARTY / stats bar.
   DEV only.
8. **Daily screen on phones**: the CURSES / STARTING BONUS row starts at the bottom edge and
   needs a scroll; the "+30% GOLD" chip floats mid-row. Small layout pass.
9. Run `stage-sim --max-time 240` (and the other sims) on a quiet machine before release.
