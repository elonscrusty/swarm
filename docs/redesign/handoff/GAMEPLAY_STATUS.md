# Gameplay chat status (for the lobby chat)

Branch `claude/dazzling-fermi-ycslnt`. Merge it into yours before continuing.

## Integration edits in lobby-owned files (2026-10-09)

The lobby chat had not started the continuation yet, so the gameplay chat made the minimum the 12-class
run needs. Please keep or improve these; don't revert them.

- **`ClassCatalog.lua`:**
  - all 12 ids, with `GoalOnly = true` on the 8 new ones
  - `Goal` read from `RunConfig.Classes.Roster[id].Goal`, which is the single source for goal numbers
  - `ClassCatalog.Showcase`, the 4 basecamp pedestals
- **`Basecamp.lua`:** the pedestals use `ClassCatalog.Showcase` (the brief says 4 pedestals, with the
  full roster in the menu).
- **`ClassOwnership.lua`:**
  - `Buy` refuses GoalOnly classes (`GOAL_ONLY`)
  - new `GoalMet`, `GoalProgress`, `EarnGoals(data)` (pure) and `RefreshEarned(player)`, which the run
    settlement calls through `SwarmV2.Run.ClassGoals.RefreshEarned`
- **`ClassPanel.lua`:**
  - ownership no longer treats `Cost 0` as owned
  - GoalOnly cards show the goal text
  - the card grid scrolls
- **`lobby-queue-regression`:**
  - goal-only buy refusal
  - goal unlock checks, granted once and free
  - 12-class and 4-showcase checks

Your continuation scope still needs: the class browser per the brief (3/2 columns, details panel with
authoritative stats, goal progress, filters), shop / receipts audit, profile, codex and settings.
