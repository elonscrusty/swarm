# Run menu drawer (DUO-MENU)

Issues: UI-45 (duo run menu per approved screen 07), GI-10 (the duo menu must not grant
protection or suggest a pause). Owner: DUO-MENU helper (phase 2).
Code: `src/client/UIBuilder.lua` run menu section (`runMenu`, `UIBuilder.OpenPause`,
`OpenRunSettings`, `OpenSettings`, `ClosePause`), `src/client/MenuParty.lua` (copy, PartyJoin).
Scene: `tools/preview/scenes/pause.luau` (`--set coop=on`, `--set confirm=on`, `--set view=settings`).

Status: type-checked, offline previews and regressions only. NOT tested in Studio, on a
device or in a live multiplayer server.

## What changed

- **One drawer for solo and group runs** (approved 07). It sits on the right edge in
  landscape. In portrait it becomes a bottom sheet, so the HP bar and the timer at the top
  stay visible. It shows run gold and kills, the helmet crest, RUN MENU, a status pill,
  one line about what the run is doing, then RETURN TO RUN, SETTINGS, VIEW BUILD and
  LEAVE RUN (crimson), plus a device-aware hint ("Tap / Click the arena to return",
  "Press B to return").
- **The label matches the server rule.** The server freezes the run for the menu only when
  the run has one player and `Config.Run.SoloPauseFreezesRun` is set (`RunManager`
  `SetPause`). The client uses the same test (`Participants`):
  - Group run: pill "DUO / TRIO · RUN CONTINUES" and "Game not paused, you can be hit." The
    tint is light and the HUD stays visible (the drawer opens as a `Pause` primary with
    `covers = false`).
  - Solo: pill "SOLO · GAME PAUSED" and "The run is paused while this menu is open." The
    tint is darker.
  - If `Participants` changes while the menu is open, the client sends `SetPause(true)` again
    so the server re-decides, and the label updates.
  - **No protection was added.** The client only sends `SetPause` as before.
    `choice-regression` section 5 already proves on the server that an open duo menu neither
    pauses nor protects.
- **LEAVE RUN asks first.** The first press turns the drawer into "LEAVE RUN?". That screen
  shows the real cost from Config: a loss, 35% of run gold kept plus 15% per stage cleared,
  kills and account XP still count, and "Your team keeps playing" in a group run. Its
  buttons are KEEP PLAYING (focused on gamepad) and YES, LEAVE RUN. Only that confirm press
  sends `AbandonRun`. Every state arms its buttons 0.35 s after it shows, so a held or double
  tap does nothing. Pressing B or tapping the arena cancels the question first.
  - The old text said all gold is kept, which was wrong.
- **SETTINGS opens the existing settings screen, unchanged.** It is mode `RunSettings`: the
  button reads BACK and the close / B buttons return to the drawer. In a group run the note
  adds "Game not paused, you can be hit." Solo stays paused the whole time (no
  `SetPause(false)` in between). The modal lost its in-run ITEMS / MAIN MENU buttons and its
  old leave confirmation; the drawer now does those jobs.
  - `UIBuilder.OpenSettings()` during a run now routes to `RunSettings`.
- **VIEW BUILD** opens the existing items / combos list (`LootUI.OpenItems`, the `Items`
  primary stacked on the menu). Weapons and passives are in the HUD build strip, which stays
  visible in a group run.
- **Ownership is unchanged.** `OpenPause` returns when `UIState.CanOpen("Pause")` is false or
  the player is not in a run. A higher panel suspends the drawer. Leaving the run, results
  or InRun false close it without telling the server; a watchdog in the update loop hides a
  drawer whose `Pause` entry was closed elsewhere.
- **Plumbing:** `show(overlay, name, blocks, covers?)` gained an optional `covers` override.
  It is backward compatible.
- **Party:** the CP-20 copy (SOLO / Daily runs are the leader's alone; START or DUO / TRIO).
  `PartyJoin` now plays when a new member appears in my party (or I join theirs); it stays
  silent on the first state after load.
- UIBuilder is close to Luau's 200-locals limit for the main chunk. This section adds a
  single top-level local (`runMenu`) and keeps its helpers inside it.

## Tests

| Test | Result | What it exercised |
|---|---|---|
| `check.sh --quick` | PASS (clean on the last run) | types, compile, icons |
| pause renders: solo pc / iphone / phone-portrait; co-op pc / iphone / phone-portrait; co-op confirm iphone / phone-portrait; co-op settings iphone | PASS (visual) | drawer, sheet, labels, confirm, existing settings opened from the drawer |
| `check_layout` on the final co-op iphone, phone-portrait and settings renders | 0 problems | overlap, off-screen, top bar, covering |
| `ui_regression` phone + phone-portrait | PASS | |
| `uistate_regression` | PASS | |
| `coop-regression` x4 (success, expired, ended, forged) | PASS | |
| `choice-regression` | PASS | server: the duo menu gives no pause and no protection |

## Remaining risk

- Studio / device: the slide animation, the gamepad B and focus behaviour, and the PartyJoin
  timing with real PartyState traffic are not verified.
- In landscape the drawer covers the minimap and the right end of the build strip (as in 07).
  In portrait the sheet covers the build strip and the minimap.
- Escape (07 shows "Esc · Return") belongs to Roblox's own menu. The hint uses a click / tap
  on the arena or B instead.
- Other scenes call `UIBuilder.OpenPause()` and expect the settings rows
  (`settings-sim`, `accessibility-sim` outside headless mode). They should call
  `UIBuilder.OpenRunSettings()` instead. Their headless regression runs skip that branch.
