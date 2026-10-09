# Commerce and persistence audit (stream L2, 2026-10-09)

Scope: every Robux product and pass in the game, how each is shown, priced, fulfilled and saved;
the receipt contract; game-pass entitlement; the profile lifecycle; the shop's honest states.
Source of truth: `src/shared/Config.lua` (`Config.Monetization`, `Config.Data`),
`src/server/Modules/MonetizationService.lua`, `StoreService.lua`, `StarterBundle.lua`,
`DataService.lua`, `src/client/MenuStore.lua`, `MenuUpgrades.lua`, `UIBuilder.lua` (revive overlay),
`MenuCharacters.lua`. Decisions C4 (one profile writer, one `ProcessReceipt`) and C8 (paid benefits kept
as they are) apply. No product id, price or benefit was added or changed by this pass.

Evidence levels: **offline** = Lune preview regressions against the real server modules and a mock
DataStore / MarketplaceService (`tools/preview/scenes/receipt-regression.luau` and the existing
`safety-sim`, `store-regression`, `economy-sim`, `pass-warm-regression`); **live only** = cannot be
checked without a published place (see section 8). Nothing here was tested in Studio or live.

## 1. Inventory

Robux prices never live in the game: every card asks Roblox (`MarketplaceService:GetProductInfo`) on the
client. Currency for all of them is Robux; what they grant is account gold, a revive token, looks or a
pass benefit. Run gold (team chest gold) is never sold.

### 1.1 Game passes (configured, live ids)

| Key | Pass id | Shown where / as | Actual benefit (server) | Entitlement (where it lives) | Handler path |
|---|---|---|---|---|---|
| StarterPack | 2008346507 | UPGRADES > SHOP card "Starter Pack: +25% gold forever + Gold Trim skins"; Characters screen (Gold Trim skin) | `GoldMultiplier` x`StarterPackGoldMult` (1.25) on account gold earnings; every "Gold Trim" skin (`CharacterData.Skins[*].Pass = "StarterPack"`) owned | session cache `passCache` (Roblox answer) + save `PassesOwned["2008346507"]` (new, outage fallback); player attribute `StarterPack`; `ProfileSync.Passes.StarterPack` | `MonetizationService.OwnsPass` -> `GoldMultiplier` -> `GoldSystem.PublishGoldMult`; `OwnsSkin` |
| VIP | 2006432550 | SHOP card "+1 reroll per run, chat tag, lobby crown" | `ExtraRerolls` = `VIPExtraRerolls` (1) per run; `[VIP]` chat tag; lobby crown | as above, attribute `VIP` | `ExtraRerolls` (RunManager reroll budget), `RefreshAttributes`, `RunManager.RefreshLobbyCharacter` |
| DoubleGold | 2005460551 | SHOP card "2x Gold: Double gold from runs" | `GoldMultiplier` x`DoubleGoldMult` (2) | as above, attribute `DoubleGold` | `GoldMultiplier` |

Purchase: the SHOP card opens `PromptGamePassPurchase` on the client (Roblox's own dialog). The grant
comes only from the server: `PromptGamePassPurchaseFinished` on the server (purchased = true, a configured
pass id) or `UserOwnsGamePassAsync` on the server. No client message grants a pass.

### 1.2 Developer products (configured, live ids)

| Key | Product id | Shown where / as | Actual benefit | Save key | Repeatable | Handler |
|---|---|---|---|---|---|---|
| Gold500 | 3716061041 | SHOP "500 Gold: A pouch of gold." | +500 account gold | `data.Gold` | yes, every PurchaseId is one grant | `buildProductHandlers` gold handler |
| Gold1500 | 3716061205 | SHOP "1,500 Gold" | +1500 | `data.Gold` | yes | same |
| Gold5000 | 3716061092 | SHOP "5,000 Gold" | +5000 | `data.Gold` | yes | same |
| Revive | 3716061270 | run overlay "YOU FELL! / REVIVE R$n" for `RevivePromptSeconds` (12) on elimination, once per run; the overlay states the real benefit (50% HP where you fell, 3 s protection, nearby enemies cleared, build kept, one per run). Since R5 (2026-10-09) Roblox's dialog opens only when the player taps REVIVE (remote `ReviveBuy`), with server states Prompting / Cancelled / Failed / Pending / Fulfilled | +1 `ReviveTokens`; spent at once if the buyer is waiting for / just lost the offer (`RunManager.OnReviveTokenGranted`), else kept and spent automatically at the next elimination | `data.ReviveTokens` | yes (one product revive per run) | revive handler; consumption `RunManager.OnReviveTokenGranted` / `eliminate` |

Every receipt is recorded in `data.PurchaseIds` (+ `data.PurchaseTimes`, new) by `DataService.RecordPurchase`.

### 1.3 Configured as 0: setup required, never sold

All of these show **Coming soon** in the store (`MenuStore.buyButton`, `MenuUpgrades.shopCard`), the server
refuses `StoreBuy` with "Coming soon." and no receipt handler exists for them (`StoreService.ProductMap`
skips 0), so a stray receipt is left `NotProcessedYet`, never acknowledged.

| Group (`Config.Monetization.*`) | Entries | Would grant | Save key |
|---|---|---|---|
| `Cosmetics` (developer products) | Trail_Ember, Trail_Frost, Trail_Royal, Burst_Confetti, Burst_Void, Burst_Frost, Pet_Fox, Pet_Owl, Pet_Drake, Emote_Cheer, Emote_Flex, Plate_Gold, Plate_Ember, Dais_Obsidian, Dais_Sunfire | one look, giftable | `data.Cosmetics.Owned[id]` |
| `CosmeticPasses.Supporter` (pass) | Supporter | badge, glowing plate, lobby banner | `data.Supporter` (seen-owned flag) + `PassesOwned` |
| `SkinPasses` (passes) | 12 old-hero skins (Knight_*, Mage_*, Rogue_*, Priest_*) | one skin each | pass lookup + `PassesOwned` |
| `HeroUnlocks` (developer products) | Archer, Bard, Golem | early unlock of an old hero | `data.OwnedCharacters[id]` |
| `StarterBundle` (developer product, feature held off) | Starter Bundle | Pioneer skin + `Config.StarterBundle.Gold` + Pioneer title, once per account | `data.StarterBundleOwned`, `Titles.Owned` |

Notes for the owner: the 12 skin passes and the 3 hero unlocks belong to the hidden old heroes; under C2
there is no Robux route to any class, so `HeroUnlocks` should stay 0. Creating any product above is an
owner step (paste the id, set the price on Roblox); the code is ready and tested with fake ids at run
time only (`store-regression`, `receipt-regression`).

### 1.4 Not Robux (account gold or free), listed for completeness

Class purchases (`ClassService.Buy`, gold prices in `ClassCatalog`: 10k / 20k / 30k), permanent upgrades
(`BuyMeta`, `BuyHeroUpgrade`), merchant / chests (run gold). Held features with no Robux: GroupBonus,
InviteRewards (own `SwarmInvites` store for pending credits, never the profile key), DailyQuests,
ComebackGift. No subscriptions, no premium payouts, no loot boxes.

### 1.5 The single receipt callback

`MarketplaceService.ProcessReceipt` is assigned exactly once in the source tree:
`src/server/Modules/MonetizationService.lua` `MonetizationService.Init` (run once by `GameServer` in the
module ORDER). StoreService and StarterBundle register *handlers* with it; they do not assign a callback.
`grep -rn "ProcessReceipt\s*=" src` returns that one line; `receipt-regression` asserts the live callback
is MonetizationService's.

## 2. Receipt contract (developer products)

The save mechanism is the project's own session lock in `DataService` (no ProfileService / ProfileStore
library is installed): each key holds `{ Data, Lock = { JobId, Time }, LastJob }`; load and every save are
one `UpdateAsync` whose transform only checks the lock and returns the record (no yields, no side
effects); `SaveProfile` serializes saves per profile (`Saving` flag) and returns true only when that
`UpdateAsync` succeeded with the lock still ours; `ForceSave` is `SaveProfile(profile, false)`.

| Invariant | How it holds | Evidence |
|---|---|---|
| Dedupe by PurchaseId, never ProductId | `HasPurchase(purchaseId)` before any handler; the same product with two PurchaseIds is two grants | receipt-regression 2 (two ids -> +1000; three replays -> no change) |
| Grant and processed-receipt record commit together | the handler changes the profile table, `RecordPurchase` adds the id to the same table, one `DataService.SaveProfile` (`UpdateAsync` under the session lock) writes both | receipt-regression 2/3 (stored ledger checked after each case) |
| PurchaseGranted only after a confirmed durable save | `ForceSave` must return true (UpdateAsync succeeded, lock still ours); for an id already present, a successful `ForceSave` is the durable proof | receipt-regression 3 (failing store -> NotProcessedYet, stored record unchanged) |
| NotProcessedYet cases | player not in this server; profile loading > 10 s, released (teleport handoff), lock lost; unknown product (warned, never acknowledged); handler error (grant rolled back from a deep copy); failed save | receipt-regression 3, 6, 7, 10; safety-sim 4; economy-sim |
| No double credit on retries | after a failed save the grant stays in memory **with** its id, so a retry only re-saves; the next autosave / leave save writes both or neither | receipt-regression 3, 6 (quitter) |
| Concurrent callbacks for one player serialized | `receiptBusy[userId]`: one receipt at a time per player (bounded 30 s queue, then NotProcessedYet for a later callback) | receipt-regression 5 (4 concurrent callbacks with a slow store: one grant per id) |
| A second server cannot double grant | a server can only process with a loaded profile, which needs the session lock (`DataService.loadProfile`); a save is refused inside the `UpdateAsync` transform when another JobId holds the lock or another server wrote after our release (`LastJob` check), so a stale holder's grant is never committed | receipt-regression 7 (another server took the lock and granted t-1: this server answers NotProcessedYet, marks the profile lost, the save keeps exactly one grant, leaving never overwrites it) |
| Departure during fulfilment keeps it fulfillable, once | no player -> NotProcessedYet (Roblox calls again on the next join); a player leaving mid-save: the leave save waits for the receipt save (`Saving` flag) and writes the same table | receipt-regression 6 (left before / left mid-save / left while saves fail: each granted exactly once after rejoining) |
| Receipt history never forgets a recent id by count | was: `MaxStoredPurchaseIds = 150`, oldest dropped -> a replay after 150 newer purchases would grant again. Now: above `MaxStoredPurchaseIds` (1000) only ids older than `PurchaseIdKeepDays` (365) are dropped; `PurchaseIdHardCap` (5000, ~450 KB) is the save-size guard; old saves' ids are stamped with the load time (counted as recent) | receipt-regression 8 (replay after 200 newer purchases recognised; mutation back to 150 fails the test with a double grant) |
| Live effects only after the commit | handlers return `after` (thank-you line, profile sync, revive now); run by `runAfter` only after the save; owed again on the retry that saves it; dropped on leave (the saved token / item stays) | receipt-regression 3, 4 |
| Revive: granting apart from consuming | the receipt adds a durable token; `OnReviveTokenGranted` (spend now) runs only after the receipt is saved, else the token waits for the next elimination (the C8 semantics). A crash before the save leaves neither the revive nor the token; the receipt grants it once later | receipt-regression 4; safety-sim 5 (decline, late purchase kept, auto-spend, one per run, buy while waiting, expiry) |
| Paid prompt close is not a grant | `PromptProductPurchaseFinished` only shows "Payment received. Adding it to your save..." (skipped when the receipt already granted); store products get `StoreResult` Pending, then Granted after the save | receipt-regression 1, 10 |

Roblox has no timed retry for `NotProcessedYet`: an unacknowledged receipt is offered again on a later
callback (typically the player's next join). The save bounds retries inside a callback
(`Config.Data.SaveAttempts` with backoff, outside the `UpdateAsync` transform). The transform itself has
no side effects (it only compares the lock and returns the record).

## 3. Game passes

| Rule | Implementation (`MonetizationService.OwnsPassId`, `queryPass`) |
|---|---|
| Server-side check with the existing mapping | `UserOwnsGamePassAsync` on the server for every id in `GamePasses`, `SkinPasses`, `CosmeticPasses` (`IsConfiguredPass`) |
| On join | `warm` asks every configured pass in the background; answered passes are not asked again; still-unknown ones retried 3 times (10 s apart) |
| Refresh after purchase | server `PromptGamePassPurchaseFinished` with purchased = true and a configured id: owned for the session, recorded in `PassesOwned`, attributes / profile / lobby crown refreshed. A later stale "no" never revokes it this session |
| Coalesced | one lookup per player and pass at a time (`inFlight`); a failed one is not repeated for 15 s |
| Failure is not "not owned" | a failed lookup leaves the answer unknown (`PassesKnown` false, so `GoldSystem.CorrectEarlyGold` still pays back early gold when it answers) |
| No long negative cache | a confirmed "no" is asked again after 120 s on the next use (bought on the website / another server) |
| Recorded entitlements survive outages | new save field `PassesOwned {tostring(passId) -> os.time()}`, written when Roblox confirms ownership or the purchase event fires, cleared when Roblox confirms "not owned". During a lookup failure a recorded pass counts as owned (`effective`). Existing `data.Supporter` keeps working as before |

Evidence: receipt-regression 9 (outage keeps a recorded DoubleGold at x2 gold; an unrecorded pass is not
granted; outage is not a confirmed answer; a confirmed "no" clears the record; purchase event grants and
records, cancel / unknown pass ids grant nothing; a negative answer is asked again after the window);
pass-warm-regression (slow lookup: run starts at once, early gold topped up, VIP reroll handed over).

## 4. Profile lifecycle

`DataService.State(player)` = `loading` | `ready` | `released` | `lost` | `failed` | `none`, published as the
player attribute `ProfileState` (new). `DataService.IsReady(player)` is true only for `ready`.

| State | Entered by | What is allowed |
|---|---|---|
| loading | `PlayerAdded` until the locked `UpdateAsync` load answers (6 tries, 12 after a SWARM teleport) | nothing: `GetData` is nil, so queue (QueueService "Your save is still loading."), store, upgrades, class buy and run entry refuse; receipts wait up to 10 s, then NotProcessedYet |
| failed | every load try failed, another live server holds the lock, or migration failed | player kicked with a retry message; **no default / empty profile is created**, the stored record is untouched, a failed migration gives the lock back without writing Data |
| ready | load succeeded / `Reclaim` after a failed teleport | the only state that is saved; receipts, purchases, settlement |
| released | `ReleaseForTeleport` saved and cleared the lock (handoff) | `SaveProfile` refuses; receipts NotProcessedYet; `StoreBuy` refuses ("Your save is busy"). Other in-memory changes are never written unless `Reclaim` takes the lock back with no newer save elsewhere |
| lost | a save found another server's lock or a newer foreign write | kicked; no later save (also re-checked after waiting for a running save) |

Memory-only fallback: only in Studio without API access (`store == nil`, `SaveStatus = "memory"`, red
note in the lobby). A live server never runs memory-only: if `GetDataStore` fails, every load fails and
the player is kicked; a failed live probe keeps the live store. A record that is not a table is kept
under `Recovered` and the player starts from defaults (pre-existing behaviour for hand-edited or corrupt
records; the old value is never overwritten).

Leave / teleport / shutdown: `GameServer` runs `RunManager.OnPlayerRemoving` (run commit) first, then
`DataService.ReleasePlayer` (release save, 6 tries over ~25 s; a same-server rejoin waits up to 60 s for
it). `BindToClose` runs `RunManager.CommitAll`, then releases every profile in parallel (25 s budget).
Overlapping leave / autosave / receipt / shutdown saves are serialized per profile by the `Saving` flag;
the second release finds `Released` and writes nothing. Autosave every 60 s also refreshes the lock
(stale after 200 s). Settings: the client batches changes (`ClientSettings` save delay) and sends only the
changed keys; the server clamps them (`Config.ValidateSetting`) into the profile in memory; they are
written by the next autosave / leave save, never per click.

Evidence: receipt-regression 10 (loading state, waiting receipt granted after the load, released ->
NotProcessedYet, reclaim -> granted once, failed load -> no profile, stored save untouched, leaving writes
nothing); safety-sim 6 (fresh / returning load, v0 -> v7 migration, duplicate session refused, stale lock
taken, lost lock never overwrites, settings persisted); storage-sim, settlement-lifecycle.

## 5. Shop honest states

| State | Store screen (`MenuStore`, fixed here) | UPGRADES > SHOP (`MenuUpgrades`) / revive overlay / Characters |
|---|---|---|
| Unavailable (id 0) | Coming soon, no button | Coming soon (SHOP); skins "COMING SOON" |
| Price loading | `R$ ...`, button disabled | **gap**: shows `BUY`, enabled |
| Price Unavailable (API failure) | `PRICE UNAVAILABLE`, disabled, asked again after 30 s; `UNAVAILABLE` when off sale | **gap**: stays `BUY` / `REVIVE`, enabled (Roblox's dialog still shows the real price) |
| Confirming | Roblox's native dialog (opened by the server after its checks) | native dialog (opened by the client) |
| Pending grant | `Pending · saving` on the card + the note "Payment received. Adding it to your save...", until the server's Granted line or the profile shows it owned | server notice "Payment received. Adding it to your save..." (any surface) |
| Granted | `StoreResult` Granted + the card shows OWNED / WEAR | "+N gold. Thank you!" / revive, both after the save |
| Owned (passes) | OWNED / WORN | OWNED badge (SHOP), skins owned |
| Cancelled | neutral grey line "No purchase made. Nothing was charged." | nothing shown |
| Insufficient funds / Failed | Roblox's own dialog handles balance and payment errors | same |

No fake prompts, no preselected upsell, no countdown on store items. Remaining gaps outside this
stream's files (lobby / run UI owners): `MenuUpgrades.shopCard` price states (copy `MenuStore.priceState`:
disabled while loading, PRICE UNAVAILABLE on failure), the revive overlay's price fallback
(`UIBuilder` ~4620), and the Characters screen's GET SKIN button (no Robux price shown).

## 6. Owner decisions to confirm

1. **Revive offer pressure (C8 vs the brief).** On elimination the server opens the Roblox revive prompt
   by itself (`RunManager.eliminate` -> `MonetizationService.PromptRevive`) and the overlay shows a 12 s
   countdown bar. The brief asks for a deliberate purchase button and no countdown pressure. C8 keeps the
   revive "as is", so nothing was changed. Proposal: keep the 12 s offer window but open the dialog only
   when the player taps REVIVE (drop the automatic `PromptRevive` call; one line in RunManager).
2. **Starter Bundle (held).** Its card shows the offer's end time (`StarterEnds`); before releasing it,
   show "new players, first 7 days" without a ticking timer.
3. **HeroUnlocks / old-hero skin passes** stay 0 (no Robux route to any class, C2).

## 7. Changes in this pass

- `MonetizationService`: per-player receipt serialization; live effects (`after`) only after the save,
  owed again on the saving retry; revive token consumption after the commit; a pending notice on a paid
  prompt close (not a grant); handler failures roll back; a handoff / lock loss during a gift save rolls
  back. Passes: outage fallback to the saved record, failure kept apart from "not owned", 120 s negative
  re-check, purchase event records the pass and is never revoked by a stale answer, warm skips answered
  passes, failure warnings once per outage.
- `DataService`: time-bounded receipt history (`TrimPurchases`, `PurchaseTimes`, dedupe on load);
  `PassesOwned` save field (additive, cleaned on load, no schema bump); lifecycle `State` / `IsReady` /
  `ProfileState` attribute; failed loads marked (pcall around the load); no save after a lock loss even
  when it was waiting for a running save.
- `StoreService`: handlers return their live part; gifts return the buyer's line as `after`; prompt close
  sends Pending (paid) or a neutral Cancelled; `StoreBuy` refused unless the profile is ready.
- `MenuStore`: price loading / unavailable / off-sale states disable buying; pending state per item;
  neutral cancel colour.
- `Config.Data`: `MaxStoredPurchaseIds` 150 -> 1000 (soft), `PurchaseIdKeepDays` 365, `PurchaseIdHardCap` 5000.
- Tests: new `receipt-regression` (in `tools/run_regressions.py`), mock `preview.setDataStoreLatency`.

## 8. Residual risks and what only a live server can show

- **Acknowledgement lost and replayed after more than 365 days and 1000 newer purchases, or past 5000
  ids**: would grant again. Practically unreachable; documented, not eliminated.
- **Gift path** (all gift products are id 0 today): the recipient's save is written before the buyer's
  receipt is acknowledged. If the buyer's server dies in between, the gift route (memory only) is lost and
  the replayed receipt gives the look to the buyer as well (one extra copy of a cosmetic). Recipient
  first is deliberate (the buyer never pays for nothing).
- **Revive consumption after a crash**: the spent token is saved by the next autosave / settlement; a
  crash before that returns one token (player-favourable). A failed receipt save delays the revive: if
  the 12 s offer ends first, the token is kept for the next elimination (the documented C8 behaviour).
- **A refunded pass** keeps its benefit during a lookup outage until Roblox answers "not owned" (gold
  multiplier / reroll only).
- **Studio memory mode** acknowledges after a memory "save" (Studio only, no real Robux, shown as
  "memory"); live servers never run memory-only.
- **Released profile, other writers**: settings / gold-shop changes made during a teleport handoff stay in
  memory and are lost if the teleport succeeds (nothing is double-counted). `ClassService.Buy` and
  `SaveSettings` check `GetData`, not `IsReady` (lobby / gameplay owners can switch to `IsReady`).
- **Live only** (not verifiable offline): Roblox calling the same receipt on two servers at once (the
  lock logic is tested through the stored lock record, not two real servers); real receipt replay timing
  after `NotProcessedYet`; `PromptGamePassPurchaseFinished` delivery and `UserOwnsGamePassAsync` caching
  right after a website purchase; `GetProductInfo` failure rates; DataStore throttling and `UpdateAsync`
  ambiguous outcomes (a thrown call that still committed is handled by the in-memory id, a crash after it
  by the stored id). The release checklist's owner steps (create products, test a real purchase with a
  copy of a save, then "Migrate to Latest Update") still apply.

## 9. Test results (offline, 2026-10-09, `tools/run_regressions.py --only ...`)

- PASS: `receipt-regression` (94 checks), `store-regression`, `safety-sim`, `economy-sim`,
  `pass-warm-regression`, `security-regression`, `settlement-lifecycle`, `storage-sim`,
  `storage-sim-outage-all`, `settings-sim`, `economy-regression`, `reward-regression`,
  `difficulty-handoff`, `run-manager-regression`, `reconnect-lobby` (3 cases), `admission-regression`,
  `lobby-queue-regression`, `party-v2-regression`, `runserver-sim` (lobby, run), `revive-thanks-regression`,
  `analytics-regression` (published, studio), `survival-sim`.
- PASS, run directly (the runner's time limits ran out under machine load): store layouts
  `section=Pets ids=on price=fail` and `pending=on` on iphone and phone-portrait (scene assertion plus
  `check_layout.py`: 0 problems), `run-entry-regression` (21/21), `swarm-v2-flow` (49/49; note: its
  own line "PASS Z1 no step / handler errors logged" matches the runner's `handler error` failure
  pattern, so the runner reports this scene as FAIL even when it passes).
- Mutation check: putting back the 150 cap, spending the revive before the commit, or ignoring the pass
  record makes `receipt-regression` fail (6 checks, including a double grant on a replay).
- Failing before and after this pass (not caused by it): `data-regression` (identical findings: class rank
  specs, Basin Breaker BossAI starts, feature flag count), `layout-store-iphone-section-Gift-ids-on`
  (gift picker caption cut, identical on the unchanged MenuStore), `heroes-regression` ("in Order: Archer",
  old heroes hidden by the SwarmV2 roster) and `coop-regression` ("actual kill records emitted drops"):
  assertions in systems this pass did not touch.
