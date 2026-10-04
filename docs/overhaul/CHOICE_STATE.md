# Upgrade choice state: the server contract (CHOICE-SERVER)

Issues: GI-06, GI-07, GI-09, GI-11, UI-05 (server ordering), UI-29.
Code: `src/server/Modules/LevelUpSystem.lua` (offer flow, `publishChoice`, `Step`),
`src/server/Modules/RunManager.lua` (`groupLive`, `ChoiceBudget`, `IsGroupChoice`,
`GrantChoiceGrace`, `HoldReward`, `DamagePlayer`), `Config.LevelUp`.
Regression: `tools/preview/scenes/choice-regression.luau` (in `tools/run_regressions.py`).

## What a choice is

The server opens a level-up panel (`rp.Offer` set, `rp.Paused = true`) when the player has
banked levels and nothing else owns the moment. Only the server opens, merges, resolves or
cancels it. The client can only send a card index, a reroll or a skip for the current card set.

A panel holds up to `ChoicesPerPanel` (4) rounds. Levels earned while it is open are added to it,
up to `PanelMergeMax` (6) rounds, and share the panel's single deadline. A reroll keeps the
deadline, so queued rounds and rerolls never extend it.

## Solo vs Duo/Trio

| | Solo (or the last living fighter) | Duo / Trio, world live |
|---|---|---|
| World | Frozen: enemies, damage, timer stop (`RefreshFrozen`) | Keeps running for everyone |
| Chooser | Rooted, weapons off, can't be hurt | Rooted, weapons off, no pickups/interaction, can't be hurt |
| Teammates | n/a | Fully live and vulnerable |
| Deadline | `AutoPickSeconds` (25 s) | `min(GroupAutoPickSeconds (10 s), budget left)` |
| Pause menu | Freezes the world and stops the deadline | Does nothing to the server: no pause, no protection |
| Attribute `ChoiceGroup` | false | true |

Trio uses exactly the duo rule. "Group" is decided when the panel opens (`RunManager.IsGroupChoice`:
more than one living fighter, world not frozen or travelling).

**Fixed (observed in the sim):** before this change `offerNext` called `RefreshFrozen` before it
set `rp.Offer`, so a solo panel rooted and protected the player but **never froze the world**
(enemies and the timer kept going). The freeze now happens when the panel opens.

## While protected the chooser cannot

Move (WalkSpeed 0, server speed check max 0), fire weapons (`WeaponSystem.Step` skips `Paused`),
collect XP (`XPSystem`), open chests/shrines (`LootSystem` refuses "paused"), proc items
(`ItemSystem`), be targeted by biome hazards, hold a partner revive, or count for caravan
rings that need an active player. Projectiles already in flight finish their flight (assumed
minor; not audited per weapon).

Protection is `rp.Paused and rp.Offer ~= nil` (`DamagePlayer`). `Paused` alone (no server offer)
does not protect. The client cannot set either.

## What never protects

- The run menu / pause drawer in a group run (`SetPause` is ignored outside solo).
- Rewards. Compact reward toasts (`HoldReward(rp, false)`) never hold. Chest / shrine reveals
  (`HoldReward(rp, true)`) hold only in solo, where the whole world freezes; in a live group run
  they do nothing on the server (no hold, no rooting, no protection). A hold that started solo
  ends at once if the run becomes a live group run (rejoin).
- Client state of any kind (attributes are server-written; the remotes only carry an index).

## Bounds

- **Per panel:** one deadline from opening. At the deadline every round still in the panel gets a
  random card from that round's offer (the existing rule, disclosed by the countdown), then the
  panel closes. An empty offer closes at once.
- **Per minute (group only):** `rp.ProtectBudget` starts at `ProtectBudgetSeconds` (20 s), drains
  while a panel is open in a live group run, refills at `ProtectBudgetRefillPerMinute` (20 s/min).
  The close grace (`Config.Player.ChoiceGraceSeconds`, 1.5 s) is paid from it too.
  A group panel's deadline is `min(10 s, budget)`. A new group panel opens only with at least
  `GroupMinPanelSeconds` (4 s) of budget; until then the levels stay banked and
  `ChoiceDeferred = "Budget"`.
  Measured (choice-regression, holding the panel and queuing levels for 2 minutes): 14.5 s
  protected in the second minute, cap 20 s.
- **No nesting:** one panel at a time; new levels merge into it; chests/interactions are refused
  while paused.

## Deferral (levels stay banked, never dropped)

A new panel does not open while (attribute `ChoiceDeferred`): `"Paused"` solo pause menu /
frozen, `"Travel"` stage travel, `"Portal"` the stage-clear dialog (NEXT STAGE / RETURN) is
offered to this player, `"Reward"` a solo reward reveal, `"Budget"` (above), `"Run"` no run.
A panel that is already open stays open; its clock stops during solo pause and stage travel
(`ChoiceTimerPaused = true`). So the stage-clear dialog never opens a new choice on top of
itself, and a choice open before it keeps input (client: show the choice first, UI-05).

## Cancellation

| Event | Result |
|---|---|
| Downed / dead (`rp.Alive` false) | Panel closes, levels kept (Step, `finalizeDeath`), reopen after revive |
| Disconnect with rejoin possible | `Cancel(rp, true)`: levels kept in the snapshot, reopen on rejoin |
| Leave / portal return / abandon / run end | `Cancel(rp)`: run over, levels dropped |
| Stage travel | Panel kept, clock stopped |

Closing always restores movement (`ApplyMovement`) and refreshes the freeze before vulnerability
resumes, then the short grace applies.

## Exactly once, idempotent requests

Each card set has an id (`rp.OfferSeq`), sent as `LevelUpOffer.OfferId` and attribute
`ChoiceOfferId`; a reroll makes a new id. `LevelUpChoose(index, offerId)`,
`LevelUpReroll(offerId)` and `LevelUpSkip(offerId)` with an id that is not current are ignored
(double tap, a late packet after the auto-pick). Without an id they still work (current client);
the client should send it. A pick clears `rp.Offer` before applying, so one round applies once.

## Attributes on the Player (server-written, read-only for clients)

| Attribute | Meaning |
|---|---|
| `ChoiceOpen` | bool, a panel is open for this player |
| `ChoiceId` | panel number (`PanelId`), same for all rounds of one panel |
| `ChoiceOfferId` | current card set id; send it back with pick/reroll/skip |
| `ChoiceProtectedUntil` | `workspace:GetServerTimeNow()` time the panel auto-resolves (and protection ends, before grace) |
| `ChoiceTimerPaused` | bool, clock stopped (solo menu, travel); re-sent on resume |
| `ChoiceGroup` | bool, live group choice (world not paused) |
| `ChoiceDeferred` | nil or `"Budget"`, `"Portal"`, `"Travel"`, `"Reward"`, `"Paused"`, `"Run"` while levels wait |
| `Paused`, `PendingUpgrades` | unchanged |

SwarmState `ChoosingIds/ChoosingNames/LevelUpPause/Frozen/RewardIds` are unchanged
(`RewardIds` is now only ever set in solo).

## Tests (offline Lune sim, NOT Studio, NOT live multiplayer)

- choice-regression PASS: duo chooser protected, teammate damaged, world clock runs, deadline
  ≤ 10 s, merged rounds share the deadline, stale/duplicate ids ignored, auto-pick resolves the
  whole panel and restores movement, damage resumes after grace, farming capped (14.5 s / 20 s),
  `Budget` deferral keeps levels, duo menu and duo chest reveal give no protection, `Paused`
  without an offer gives none, portal deferral, downed cancel keeps the level, solo freeze +
  25 s deadline + pause menu stops the clock.
- progression, run-manager, reward, coop (4 variants), xp-sim, fall, whip, passives, mastery,
  chest-gold: PASS.
- BLOCKED: real two/three-client Studio test with network latency (owner).

## Remaining risk

- Projectiles/pools already in flight when a panel opens keep hitting (assumed minor).
- The duo portal countdown keeps running while a teammate chooses (existing behaviour).
- The client still sends picks without `OfferId` until UPGRADE-UI updates it.
