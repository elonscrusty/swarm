# SWARM overhaul: migration, rollback and owner steps

Baseline (last release on `main`): `83be6c9`, "Home and retention update", 2026-10-04 18:24 UTC.
Overhaul head when this was written: `59f533b`.

## 1. Saves: no schema change

Checked by grep, `83be6c9` against the working tree:

- `Config.Data.SchemaVersion = 7` in both (`src/shared/Config.lua`; `git show 83be6c9:src/shared/Config.lua`).
- `DataService.lua` migration steps (`while version < Config.Data.SchemaVersion`) unchanged. The only
  DataService change is the `releasing` guard: a player rejoining the same server waits (up to 30 s)
  for that server's leave save before loading, and the leave save is pcall-guarded (SAFETY.md 3).
  It changes timing, not the save shape.
- No new saved field. New state is per run or per session only: player attributes `ChoiceOpen`,
  `ChoiceId`, `ChoiceOfferId`, `ChoiceProtectedUntil`, `ChoiceTimerPaused`, `ChoiceGroup`,
  `ChoiceDeferred`; SwarmState `ChoiceLeftHeld`; the client's recent-rewards list (cleared when the
  run ends); leaderboard replies `MyBoard` / `MyQueued` (read only).
- Leaderboards: no write path changed; no score was lowered, deleted or copied (FLOW.md 2).
- Remotes: no new remote. `LevelUpChoose` / `LevelUpReroll` / `LevelUpSkip` accept an optional
  `OfferId`; calls without it still work. `TravelHome` accepts two new choices, `Hold` and `Replay`.

So: **nothing to migrate.** "Migrate to Latest Update" is not needed for this overhaul on its own.
(If the schema 7 Hero Mastery update has not been published yet, its own note still applies: test
with a copy of a real save, then run "Migrate to Latest Update" after publishing.)

## 2. Config keys

New:

| Key | Value | Purpose | Doc |
| --- | --- | --- | --- |
| `Config.Stages.ChoiceHoldMaxSeconds` | 12 | Group stage-clear countdown waits this long at most for an open upgrade choice | NOTIFY_SERVER 3 |
| `Config.LevelUp.ProtectBudgetSeconds` | 20 | Duo/Trio: protected seconds available | CHOICE_STATE |
| `Config.LevelUp.ProtectBudgetRefillPerMinute` | 20 | Budget refill rate | CHOICE_STATE |
| `Config.LevelUp.GroupMinPanelSeconds` | 4 | A new group panel needs this much budget | CHOICE_STATE |
| `Config.Gold.EliteLateStageScale` | 0.05 | Elite-chest gold growth per stage from stage 3 (owner: stage 3+ only) | BALANCE_TUNE 5 |
| `Config.Chests.LateCostExponent` | 0.75 | Extra chest / Shrine of Chance price factor `(stage/2)^0.75` from stage 3, capped at stage 5 | BALANCE_TUNE 5 |
| `Config.Audio.CriticalPriority` | 5 | Only priority-5 sounds may use the reserved voices | AUDIO_MIX |
| `Config.RunServers.ReplayGraceSeconds` | 10 | REPLAY on a run server: the new run must start within this | FLOW 1 |
| `Config.Sounds.EliteSpawn`, `CardAppear`, `ChoiceOpen`, `ChoicePick`, `ResultsLose`, `PartyJoin`, `TitleStart` | existing sound ids, re-pitched | New cues | AUDIO_MIX |

Changed:

| Key | Before -> after | Doc |
| --- | --- | --- |
| `Config.Difficulty.MaxTier` | 12 -> 16 | BALANCE_TUNE 1a |
| `Config.Stages.BossHPByStage` | {0.22, 0.4, 0.7, 1.05, 1.5} -> {0.22, 0.4, 0.85, 1.35, 2.0} | BALANCE_TUNE 1b |
| `Config.Sounds.Heartbeat`, `WaveHorn` | + `Priority = 5` | AUDIO_MIX |

Removed: `Config.RunServers.HomeDelayAfterResultsSeconds` (2; no longer used, defeat results go home
at once).

Unchanged on purpose: `Gold.EliteStageScale` 0.25, `Chests.CostExponent` 1.2, armor rules, every
Robux price, product and pass, `Config.Monetization`.

## 3. How to roll back

Pick the smallest step that fixes the problem.

1. **Roblox (fastest, no code):** in Studio, File > Version History (or the Creator Dashboard's
   place version history), restore the version published before the overhaul and publish it. Saves
   are compatible both ways because the schema did not change.
2. **Only the balance:** set the Config keys back (MaxTier 12, BossHPByStage stages 3-5
   0.7 / 1.05 / 1.5, LateCostExponent 0, EliteLateStageScale 0.25), rebuild, publish. Each is one
   line in `src/shared/Config.lua`.
3. **Only the art meshes:** `meshes/uploaded_ids.json` / `src/shared/MeshCatalog.lua` from
   `83be6c9` point back to the old asset ids (they still exist on Roblox); the hero material change
   is catalog data only.
4. **The whole overhaul in git:** `git revert --no-edit 83be6c9..HEAD` (one revert commit per
   overhaul commit, history kept), or check out the old tree on a branch:
   `git switch -c rollback-83be6c9 83be6c9`. Then
   `/tmp/sh-tools/rojo/rojo build default.project.json -o build/Swarm.rbxlx`, open it in Studio and
   publish. Do not `git reset --hard` on `main`.

Nothing in the overhaul writes data that the old build cannot read, so a rollback needs no data step.

## 4. Owner steps in Studio (nothing below has been done)

Use the `_Studio` DataStores and test purchases only. Never real Robux, never live saves.

1. Build the place (`rojo build ... -o build/Swarm.rbxlx`) and open it in Studio.
2. **Corner fix (GI-01):** Forest, stand still in the south-east corner (cliff / low wall) for a
   minute; enemies should reach you and hit you. Compare an open field. Try another arena's corner.
3. **Duo choice (TS-08):** Test > Start with 2 players. Level up player 1: player 2 keeps moving and
   taking hits, player 1 cannot be hurt, the panel auto-picks within 10 s. Open the run menu on one
   client: the other keeps playing and the menu says "Game not paused".
4. **Solo choice:** open a level-up: enemies and the timer stop.
5. **Rewards:** open a Small Chest (compact card, no reel, you can keep moving) and a Golden Chest
   (short reveal, tap to skip). Check the item appears once in ITEMS.
6. **Screens on a phone (Studio device emulator first, then a real phone):** title, run setup,
   HUD, upgrade cards, results, run menu. Check notch/safe areas, thumbstick and JUMP, hold buttons.
7. **Gamepad (UI-61):** card focus, 1/2/3, B to close the run menu.
8. **Return flow:** lose a run on a run server: one transition to the main lobby, no second
   countdown; STAY keeps the results.
9. **Revive purchase:** test purchase while downed: cancel once, buy once; one token, one revive.
10. **Saves:** leave and rejoin quickly; gold and settings stay. Load a copy of a real save.
11. **Meshes:** check the new Mite, Scorpion Queen, Moth Matriarch and Healing Totem load (asset
    ids in ASSET_REGISTER.md), and the Knight/Priest look in the lobby lighting.
12. **Audio:** listen on a phone and on headphones (AUDIO_MIX.md "Needs ears").
13. **Performance:** MicroProfiler / Developer Console on the phone with 200 enemies; compare with
    PERFORMANCE_BASELINE.md budgets; 5 lobby -> run -> lobby cycles for memory.
14. Only after these pass: publish, then watch the live boards and economy for a few days.
