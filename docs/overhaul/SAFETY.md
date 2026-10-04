# SAFETY: security, purchases, persistence, DEV tools (overhaul phase 1)

Owner: SAFETY helper. Issues: TS-01, TS-03, TS-04, TS-07, UI-43, UI-58 (docs/overhaul/ISSUE_REGISTER.md).
Settings test: see SETTINGS_TEST.md (UI-59, UI-60, TS-09, TS-10).

**What was exercised:** a code review of every client-to-server remote and the purchase and save
paths, plus offline Lune simulations of the real server modules against the preview mock
(`tools/preview`). None of this was run in Studio, on a device, with two real clients, or against
live DataStores or real purchases. Receipts were driven by calling the real `ProcessReceipt` function
with made-up receipt tables. No Robux was spent and no live data was touched.

## 1. Remote review (all 36 client-to-server remotes in `Remotes.ClientToServer`)

Every remote except two goes through `Remotes.Listen`, which applies a per-player token bucket and wraps
the handler in a pcall. The two exceptions are the release halves of `LootHold` and `ReviveHold`. They
are deliberately not rate-limited, so a dropped release can never complete a hold.

| Remote(s) | Server checks found | Verdict |
|---|---|---|
| BuyCharacter, BuyMeta, BuyHeroUpgrade | Lobby only. Ids come from server data and prices come from the server. Achievement heroes are never sold. BuyMeta and BuyHeroUpgrade take the level the client saw, so a stale double tap buys one level. BuyHeroUpgrade also checks ownership and the mastery cap. Rates are 2, 4 and 4 per second | OK |
| SelectCharacter, EquipSkin, EquipCosmetic | Owned hero only. Skin ownership is checked through `MonetizationService.OwnsSkin`. A cosmetic needs its achievement or account level, and strings are capped at 40 characters | OK |
| SaveSettings | Only keys in `Config.Settings.Defaults` are read. Types must match. Numbers are clamped to 0-1 with NaN and infinity rejected. Enums are checked against `Config.Settings.Enums` | OK |
| Tutorial | Only known tip ids and actions are accepted. The flags only affect which hints show | OK |
| StartRun, StartFirstRun, JoinRun, StartNow, CycleArena | `isMode`, the phase, party and run-server blocks, `firstRunAllowed` (asked once per player), only the starter can StartNow, and the arena must be unlocked | OK |
| LevelUpChoose, LevelUpReroll, LevelUpSkip | Requires a live run player and an open offer. The index is an integer in range. Reroll and skip counts come from the server. A reroll keeps the original deadline | OK. New choice-state remotes from CHOICE-SERVER are fuzzed automatically by `safety-sim` |
| LootHold (chest hold) | `check()` re-runs every tick: object exists, player alive and not paused, in range, usable, and can afford it. `SpendRunGold` is checked again at completion, and opening marks the chest Opened, so it is granted once | OK |
| RewardClose | Only the player's own run player. An older sequence number cannot end a newer reward | OK. It can only end your own protection early |
| SetPause | Requires a boolean. It only freezes the world in a solo run | OK |
| ReviveDecline, ReviveHold | Decline only acts while the offer is open. Hold is legacy and only clears a flag | OK |
| AbandonRun, ReturnToLobby | Your own run player only; ReturnToLobby only in Results | OK |
| PortalChoice | Only "Next" or "Return", only while the portal is Open, alive, not already chosen, with Endless and completion rules | OK |
| SetCurses, SetEndless, SetDifficulty | Lobby only. Inputs pass through `CurseData.Sanitize` (at most 16 entries, strings of 32 characters or fewer), booleans are checked, and difficulty must be unlocked | OK |
| TeamPing | Kind is whitelisted. Live run, 2 s cooldown, targets resolved by the server, finite positions | OK |
| Party, PartyFollow, TravelHome, LeaderboardRequest | The action table is looked up by a string key, the follow requires friendship (PartyService), the role is checked, and the board id is whitelisted | OK |
| BugReport, BugInbox | Text is filtered and rate-limited. The inbox requires `DevAccess.IsDev` | OK |
| DevCommand | `DevAccess.IsDev`, decided on the server: Studio, `DevAllowlist`, or the creator with `ShowInLiveGame` (off). Every argument is clamped again in `DevTools`. Any command used in a run marks the run as dev-tainted | OK |

Fuzzing in `safety-sim`: 36 remotes × 24 malformed payloads (nil, NaN, ±inf, 1e308, 2^53, a
5000-character string, nested tables, Vector3, Instance, `"__index"`, wrong arity), once in the lobby
and once inside a live run. After each pass the gold, unlocks, Meta, hero tracks, settings, skins,
tokens, purchase ids, stats and cosmetics must be unchanged, and run membership must be unchanged.
`run_regressions.py` fails the scene on any `handler error`. **PASS** (offline).

## 2. Purchases and revive

**Design (code review).** `ProcessReceipt` grants a product only after the profile is loaded, not
released and not lock-lost. It records the `PurchaseId`, and returns `PurchaseGranted` only after
`ForceSave` succeeds. A repeated callback for a recorded id never calls the handler again; it saves
again and acknowledges. Gold products only add gold. Revive adds a saved token.
`RunManager.OnReviveTokenGranted` spends that token at once if the buyer is down in a running run,
otherwise it is kept for their next fall. The client only opens Roblox's native prompt (UIBuilder
revive offer, MenuUpgrades, MenuCharacters) and never shows success on its own. The thank-you notices
come from the server after the grant.

**Changes made:**
- `MonetizationService.lua`: `ProcessReceipt` now rejects malformed receipt info (NotProcessedYet).
  `PromptGamePassPurchaseFinished` now ignores pass ids that are not configured
  (`MonetizationService.IsConfiguredPass`). Passes are never saved; every join asks Roblox again.
  `MonetizationService._ProcessReceipt` is exposed for tests.

**safety-sim results (offline, PASS):**
- Gold500 is granted once. Three more callbacks with the same PurchaseId are acknowledged and grant nothing more.
- Failed save: the grant is held in memory and NotProcessedYet is returned (SaveStatus "failing"). The
  retry while still failing returns NotProcessedYet. After recovery the retry returns Granted with no second grant.
- Unknown product id, malformed info, a player not in the server, and a profile released for a
  teleport all return NotProcessedYet with nothing granted. After a failed teleport, `Reclaim` lets the
  same receipt be granted once.
- Revive: decline ends the solo run. A purchase that completes after that is kept as one token, and a
  repeated callback still leaves one. The token revives automatically on the next fall, and a second
  fall in that run gets no offer (one product revive per run). Buying while the offer is open revives
  once, and a repeated callback changes nothing. If the offer expires, nothing is granted.

**Not exercised (BLOCKED):** Roblox's real prompt UI (cancel, insufficient funds), the real
receipt retry timing, and purchases in Studio test mode or live. Owner steps: in Studio, use a test
purchase of Revive while downed, cancel once, and buy once; check one token and one revive. Never test
with real Robux.

**Note:** the co-op path "purchase completes after the offer timed out while a teammate is still
alive" (revive late) is reviewed in code (`OnReviveTokenGranted`: a fallen player without a product
revive yet is revived) but was not simulated.

## 3. Persistence (DataService, schema 7)

Session-locked UpdateAsync saves, with retries and backoff, a teleport handoff (release and reclaim),
and Studio uses `_Studio` stores.

**Change made (state-loss fix, found by review):** `DataService.lua` adds a `releasing[userId]` guard.
Before, a player rejoining the **same** server while that server was still writing their leave save
could load the record from before that save, because our own lock does not block our own load. The
next autosave would then write the older data back (a rollback of the last session's gold and
progress). Reconnects and Rejoin make that possible. Now the load waits up to 30 s for the leave save
to finish. The leave save is also pcall-guarded. The mock store is synchronous, so the race itself
cannot be reproduced offline. This fix is checked by review only, and the existing regressions still
pass.

**safety-sim results (offline, PASS):** first load gives the current-schema defaults. Leave saves and
releases the lock. A returning load keeps gold and every setting. A schema-0 save migrates to 7 through
the real load path (hero array becomes a set, shared stats are copied to every hero, Meta is kept, every
settings key gets the right type). A fresh lock held by another server is refused (kick) and that
server's data and lock are untouched. A stale lock (crashed server) is taken over with the data kept.
After a lost lock, ForceSave fails and marks the profile LockLost, and neither the save nor the leave
overwrites the other server's newer data. `storage-sim` (both modes) also passes: probe failure keeps
the save, and a live outage refuses fresh profiles.

**Not exercised (BLOCKED):** real DataStore latency, throttling and two live servers. Owner steps:
before publishing the schema 7 update, load a **copy** of a real save in Studio (`_Studio` store), and
after publishing run "Migrate to Latest Update".

**Residual risk:** if every retry of the leave save fails during an outage, changes since the last
autosave (at most 60 s) are lost. The lock then stays until it goes stale (200 s), and a rejoin
elsewhere waits for that. This is a known limit of the design.

## 4. DEV tools

The rule lives on the server only: `DevAccess.IsDev` is Studio, `DevAllowlist` (owner 20194281), or
the creator with `ShowInLiveGame` (off). The `DevAccess` attribute only decides whether the client draws
the button. `DevGod` is a server attribute (a client's own attribute writes never replicate).

**safety-sim (run without `--studio`, so it behaves like a live server):** an ordinary user (UserId 1)
has no DevAccess attribute. UnlockAll, LobbyGold, AccountLevels, ResetProgress CONFIRM,
DamageNumbers, God and StartSolo change nothing and start no run. The bug inbox does not answer. Junk
DevCommands inside a run do not taint it. Positive control: the allowlisted UserId's LobbyGold runs.
**PASS** (offline). UI-58: the recording account is the owner, who is allowlisted, so seeing the
button there is expected.

## 5. Regressions added

- `tools/preview/scenes/safety-sim.luau` (sections 1-4). It **must run without `--studio`**.
- `tools/preview/scenes/settings-sim.luau` (see SETTINGS_TEST.md).
- For the lead: add both to `tools/run_regressions.py`, and add `"safety-sim"` to the live-store
  tuple that drops `--studio`.

Commands:

```
lune run tools/preview/runtime/main.luau -- --scene safety-sim --device pc --out <dir>/s.json --max-time 400 --set headless=on
lune run tools/preview/runtime/main.luau -- --scene settings-sim --studio --device pc --out <dir>/t.json --max-time 200 --set headless=on
```

Re-run after these changes: storage-sim and storage-sim with outage=all, reconnect-lobby (default,
fail=teleport, fail=expired), runserver-sim with role=lobby and role=run, coop-regression with
rejoin=success, mastery-regression, difficulty-handoff, and accessibility-sim all **PASS**.
`settlement-lifecycle` **FAILS** ("two minutes survived pay survival gold: 0"). It fails the same way
with my DataService and MonetizationService changes reverted, so it comes from another helper's
in-progress edits.
