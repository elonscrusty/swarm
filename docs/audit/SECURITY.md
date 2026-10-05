# SECURITY audit (2026-10-05)

Scope: every client-to-server remote, duo choice protection, DEV access and run taint, the save/load lifecycle, receipts, once-only grants.
Baseline: `audit-baseline-2026-10-05` (b07d83b). Environment: offline Lune preview with the mock live DataStore. No Studio, no real DataStores, no live multi-client. Runtime claims below come from sims, not from production.

## Changed files

| File | Purpose | Risk | Recovery |
|---|---|---|---|
| `src/server/Modules/DataService.lua` | SEC-03: a same-server rejoin waits up to 60 s for the last session's final save. If that save is still pending, the player is kicked with "still saving, rejoin", so the older save is never loaded. SEC-04: a non-table record, or a non-table `Data`, is kept under `Recovered` in the record and is not overwritten. SEC-05: `Migrate` keeps a stored version up to Schema+3 instead of downgrading it. | Low. No schema change. `Recovered` lives in the record wrapper, outside `Data`, so it is never sent to clients. | Revert the three hunks. |
| `tools/preview/scenes/security-regression.luau` | New regression scene (6 sections). | None (test only). | Delete. |

Register the scene in `tools/run_regressions.py` (lead edits):
- Add `"security-regression",` to the first `checks` name tuple.
- Add `"security-regression"` to the no-`--studio` tuple on line 60, i.e. `if scene in (..., "safety-sim", "security-regression"):`.

## Remote inventory (36 client-to-server remotes)

Every remote goes through `Remotes.Listen`, which applies a per-player token bucket and wraps the handler in pcall. There are two exceptions, both deliberate: the `LootHold` and `ReviveHold` *release* paths use a raw `OnServerEvent` so a release is never dropped. Each of those paths can only clear a hold.

The fuzz test sends 24 malformed payloads to all 36 remotes, in the lobby and in a run, and checks that the save is unchanged (safety-sim §1): **PASS**.

| Remote (rate/s) | Types / bounds | Identity / state / other checks |
|---|---|---|
| TeamPing (4) | kind in preset set; Vector3 finite and under 1e6; id must be an integer | Participant who is alive and has a Root, run running; 2 s cooldown; target resolved by the server; within 100 studs; sent to teammates only |
| LevelUpChoose (6) | index is a number, not NaN, floored, 1..Choices+1; optional offerId must match | Run player with `rp.Offer`; stale offerId dropped |
| LevelUpReroll / Skip (3) | offerId must match | Needs an Offer and Rerolls/Skips > 0; reroll keeps the deadline |
| JoinRun (2) / StartRun (2) / StartNow (2) / StartFirstRun (1) | mode checked with `isMode` | Phase Lobby/Countdown; profile loaded; RunServers.Blocks; party leader and READY; StartNow only for the starter with 2+ joined; first run once per server session plus save flags |
| CycleArena (3) | string in Arenas.Order | Lobby phase; arena unlocked for the caller (the selection is server-wide, SEC-15) |
| DevCommand (6) | command must be a string; args clamped in DevTools | `DevAccess.IsDev` on the server; lobby/run kind gates |
| ReturnToLobby (2) / AbandonRun (1) | none needed | Run player; Results phase / Running; `Returned` and `Committed` gates make it once-only |
| SetPause (4) | boolean | Running; freezes only when `#runPlayers == 1` |
| RewardClose (4) | seq must not be older than RewardSeq | Ends only a server hold. In a duo there is no hold, so it grants no grace (security-regression §6) |
| ReviveDecline (2) / ReviveHold (12) | boolean | `AwaitingRevive`; ReviveHold is legacy and ignored |
| SelectCharacter / BuyCharacter / BuyMeta / BuyHeroUpgrade / EquipSkin (2-4) | string ids from the data tables; expectedLevel must equal the owned level | In lobby; owned hero; server price; achievement heroes are never sold; mastery cap and max level; skin ownership through passes |
| SaveSettings (4) / Tutorial (6) | `Config.ValidateSetting`: type match, finite, clamped 0-1, enum values | Profile loaded |
| RequestProfile (2) | none needed | Sends a whitelisted ProfileSync only (no AccessCode, no PurchaseIds) |
| PortalChoice (3) | "Next" or "Return" | Portal open; alive, not returned; Endless and expedition rules |
| LootHold (8) | id is a number, holding is a boolean | Re-checked every frame: alive, not Paused, usable, within InteractRadius + 1.5, wallet ≥ price; state set to Opened before the grant |
| EquipCosmetic (4) | value is a string of 40 chars or fewer | Earned through an achievement or the account level |
| SetCurses / SetEndless / SetDifficulty (4-6) | `CurseData.Sanitize` (at most 16 entries, at most 32 chars each) / boolean / unlocked tier | Not a participant |
| BugReport (1) / BugInbox (2) | category, text cleaning, Roblox text filter | 60 s per user, quota, DataStore budget; inbox only for `DevAccess.IsDev` |
| LeaderboardRequest (3) | board id | Shared cache with RefreshSeconds |
| Party (ActionRate) / PartyFollow (1) | action table; userId is a positive, finite number | Leader-only invite and kick; invites expire; follow cooldown, friends-only, same place |
| TravelHome (2) | "Go", "Stay", "Hold" or "Replay" | Run-server role; not while travelling or busy |

## Matrix

| ID | subsystem | expected (source) | files/functions | repro/start state | actual | evidence type | severity | root cause | fix/proposal | status | next check |
|---|---|---|---|---|---|---|---|---|---|---|---|
| SEC-01 | remotes | Validate every client request (§10) | Remotes.Listen, all handlers above | safety-sim §1-2 | Each remote validates types, bounds, state and rate | sim + static | - | - | - | VERIFIED WORKING | live: exploit-client spot check (owner, optional) |
| SEC-02 | duo choice protection | Chooser protected, partner keeps playing, no farming, no stale flags (§8) | RunManager.DamagePlayer/RefreshFrozen/stepProtectBudget/GrantChoiceGrace, LevelUpSystem.offerNext/Step | choice-regression; security-regression §6 | Protection requires both `rp.Offer` and `Paused`, set by the server. Group deadline ≤10 s, budget 20 s/min, reroll keeps the deadline. SetPause and RewardClose in a duo give no protection; spamming them gives none either. A leaver is inert (AnyChoiceOpen false, not frozen). The resumable disconnect path cancels the offer. | sim | - | - | - | VERIFIED WORKING | Studio duo playtest |
| SEC-02b | duo choice aggro | No aggro farming while choosing (§8) | EnemyAI.nearestPlayer | static | Enemies still target a protected chooser, so the chooser acts as a decoy for up to about 20 s + grace per minute | static | P2 | targeting ignores protection | Design tradeoff for the owner: skip protected players in `nearestPlayer` (WORLD), or accept as bounded | UNVERIFIABLE (balance call) | owner decision |
| SEC-03 | save lifecycle | A same-server rejoin must never load a save older than the final write (§10) | DataService.onPlayerAdded | security-regression §3: an autosave is in flight, the player leaves and rejoins at once | **Before:** after the 30 s cap, the load proceeded under our own lock and read the older save. The late final save then cleared the lock, and the next autosave put the older data back (loss of the session's delta). Baseline run FAILS at "no load while … pending". **After:** waits up to 60 s, loads the final data; on timeout the player is kicked with a "still saving" message | sim (baseline FAIL, fixed PASS) | P1 | the wait loop fell through to load after its timeout | Wait then kick instead of a stale load | VERIFIED FIXED | Studio: rejoin during a DataStore outage |
| SEC-04 | save lifecycle | Malformed records handled without destructive repair (§10) | DataService.loadProfile | security-regression §2: string record; `Data = "half-written"` | **Before:** the record was replaced by defaults on the first save (baseline FAIL). **After:** the original value is kept under `Recovered`; the player starts from defaults | sim | P2 | `old = {}` dropped non-table values | Keep the value under `Recovered` | VERIFIED FIXED | manual repair procedure if `Recovered` is ever seen |
| SEC-05 | save lifecycle | Rolling updates must not re-run migrations | DataService.Migrate | security-regression §1 | **Before:** an older server rewrote Version to its own schema, so the next schema's migration could run twice. **After:** a version up to Schema+3 is kept; a far-off value is treated as junk | sim | P2 | unconditional `Version = SchemaVersion` | Keep the max | VERIFIED FIXED | next schema bump |
| SEC-06 | save lifecycle | A failed load never writes defaults | loadProfile/onPlayerAdded/Init | storage-sim (both), safety-sim §6, security-regression §4 | Kicked, record untouched; a live probe failure keeps the store | sim | - | - | - | VERIFIED WORKING | - |
| SEC-07 | save lifecycle | Session lock, lost lock, stale lock, handoff | SaveProfile/Reclaim/ReleaseForTeleport | safety-sim §6, runserver-sim, reconnect-lobby | Duplicate refused, stale lock taken, lost lock never overwrites, receipts wait for the handoff | sim | - | - | - | VERIFIED WORKING | Studio API access test with a copy of a real save |
| SEC-08 | fixtures | Missing fields, legacy schema, oversized values | Migrate | security-regression §1 (30 fixtures), safety-sim (v0→7), storage-sim | Never throws; progress kept; finite large values kept; junk reset per field | sim | - | - | - | VERIFIED WORKING | - |
| SEC-09 | receipts | Idempotent per PurchaseId; acknowledged only after a save | MonetizationService.processReceipt | safety-sim §4-5 | Once per id, failed save then retry, absent player, released profile, revive token flows | sim | - | - | - | VERIFIED WORKING | no real purchases (rule) |
| SEC-10 | once-only grants | Chest, finalisation, win bonus, first-run bonus, daily, reconnect | LootSystem.openChest, saveRunStats `Committed`, `WinPaid`, `FirstRunBonus`, CommitDaily (max), TryReconnect (consumed before yield) | reward-once-regression, settlement-lifecycle, coop-regression rejoin=*, reconnect-lobby | Each is gated once | sim | - | - | - | VERIFIED WORKING | - |
| SEC-11 | non-atomic writes | Recovery windows | profile UpdateAsync (atomic per key) + OrderedDataStore boards | static | A crash between the run settlement in memory and the next save loses that run (no duplication). A board write can be lost independently of the profile. | static | P2 | multi-store by design | Document only | UNVERIFIABLE | - |
| SEC-12 | DEV | Allowlist enforced server-side; DEV runs tainted | DevAccess, RunManager.devCommand, saveRunStats | safety-sim §3, security-regression §5 | An ordinary user is refused. An owner command mid-run taints the whole team: 0 board submits, no records or playtime. God in the lobby taints the next run; DevGod is cleared on return | sim | - | - | - | VERIFIED WORKING | - |
| SEC-13 | DEV leak to boards | Debug actions must not reach scores (§8) | DevTools UnlockAll/LobbyGold/AccountLevels (lobby kind) | static | In live servers the owner's lobby commands add 1M gold and levels to the real save. Later runs bought with that gold are not tainted and reach public boards | static | P2 | taint is per run, not per profile | Proposal: an additive profile flag `DevBoosted` set by lobby profile commands that taints all later runs (save field: owner decision) | MISSING | owner decision |
| SEC-14 | DEV | Irreversible save commands Studio-only (DevAccess header) | DevTools ResetProgress | static | ResetProgress (double-tap CONFIRM) wipes the owner's live save; nothing gates it to Studio | static | P2 | `DevAccess.IsStudio` exists but is unused | Proposal: gate ResetProgress with `DevAccess.IsStudio()` (owner's tool: ask first) | MISSING | owner decision |
| SEC-15 | DEV / lobby | - | RunManager.devCommand; cycleArena | static | Any DEV command while another group's run is live taints that run (over-taint, safe direction). Lobby arena choice is server-wide | static | P2 | taint keyed to phase | FOR JOURNEY: taint only when the dev is a participant | NOT APPLICABLE (safe) | - |
| SEC-16 | party | Joins only by consent | PartyService.onArrival | static | TeleportData/LaunchData `PartyInviter` (client-passable) auto-joins a *friend's* party without an open invite | static | P2 | join data trusted for friends | Proposal: show it as an invite card instead | MISSING | - |
| SEC-17 | secrets | No secrets in client code or errors | ProfileSync whitelist, Kick texts, DevAllowlist in ServerScriptService | static grep | AccessCode, PurchaseIds and Recovered are never sent; kick messages are generic | static | - | - | - | VERIFIED WORKING | - |

## Tests (exact commands)

All runs were sequential, under the lune process limit:
`lune run tools/preview/runtime/main.luau -- --scene <s> [--studio] --device pc --out <o> --max-time 400 --set headless=on [--set k=v]`

| Test | Result |
|---|---|
| security-regression (new, no `--studio`) | PASS |
| same scene against baseline DataService | FAIL at SEC-05, SEC-04 and SEC-03 (each isolated) |
| safety-sim | PASS |
| storage-sim, storage-sim outage=all | PASS |
| data-regression | PASS |
| choice-regression | PASS |
| coop-regression rejoin=success/expired/ended/forged | PASS |
| reconnect-lobby (plain, fail=teleport, fail=expired) | PASS |
| runserver-sim role=run/lobby | PASS |
| settlement-lifecycle | PASS |
| run-manager-regression | PASS |
| `bash tools/check.sh --quick` | TYPECHECK ok, COMPILE ok |
| Studio, live DataStores, real devices, real purchases | NOT RUN (BLOCKED: environment) |
