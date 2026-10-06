# Features batch review (2026-10-06)

A correctness and security review of the 30-features and store batch (`git diff 08dea66..HEAD -- src`).
It is offline only: the code was read and the Lune regressions were run. Nothing here was tested in Studio, on a device or live (BLOCKED).

## What was checked
- **Client-to-server remotes.** UseUltimate, TeamComboFire, SetPreset, MerchantBuy, Meta, SetMasteryGlow, StoreBuy, StoreEquip, StoreEmote, and TeamPing with its new presets and ReviveMe. Every one goes through `Remotes.Listen`, which has a per-player token bucket and pcall. Each handler checks the argument types, finite whole numbers, its feature switch, the run phase, life and portal state, and ownership. Meta equips and claims are refused during a run. None of them trusts an id or amount sent by the client.
- **Exactly-once grants.**
  - Sigils, the weekly and team boards, season XP and the collection are written only from `CommitRun`. It runs behind `rp.Committed` and after the DEV-taint return. DevBoosted taints the whole run in `beginRun`, and also on `TryReconnect`.
  - Streak and season claims mark the save before they pay.
  - Merchant slots are marked sold before the item is granted. Rescue, the Trial, the mini-boss chest and the secret cache each change state before they pay.
  - Store receipts keep the buyer's PurchaseIds. A gift keeps its route per PurchaseId.
- **Save fields.** `CleanFeatureFields` fills in defaults and caps every set and list. Old saves get the new fields, and nothing is removed apart from entries above a cap. There is no schema bump.
- **Cleanup.** The EncounterDirector calls `OnCleanup` on every registered module when a stage ends. It calls `PlayerOut` on a death, a portal return, an abandon and a leave. The store, gift, emote and remote buckets are cleared on PlayerRemoving.
- **Pay-to-win.** Store items only set ownership and the player attributes that StoreFx draws. No server code reads them for power. The Archer, Bard and Golem early unlocks are sold only while `HeroEarnable` is true, and all three also have gold prices of 10k, 20k and 30k. Sigils, mastery glows and titles are earned by play only.

## Findings

| ID | Where | Sev | Finding | Status |
|----|-------|-----|---------|--------|
| R-01 | src/server/Modules/Merchant.lua:178 | P2 | The merchant stock was keyed by the run-player record. A reconnect makes a new record from a copy, so a rejoin rerolled the cart and reopened sold slots: more items for run gold. | FIXED: the stock is now keyed by UserId. explore-regression has 2 new checks. |
| R-02 | src/server/Modules/Weather.lua:50 | P1 | A record that reconnected during a snow storm already carried the storm multiplier, so `setPlayerMult` returned early and never tracked it. At the stage end it was not reset, and the player stayed slowed for the rest of the run. | FIXED: a record with the multiplier that is not tracked is now tracked. events-regression has a new check. |
| R-03 | src/server/Modules/Ultimate.lua:160 | P2 | The ultimate did not check for an open card choice, although its doc says it does. A co-op player who was protected while choosing a card could fire it. | FIXED: `rp.Offer` now refuses it. heropower-regression has a new assert. |
| R-04 | src/server/Modules/StoreService.lua:307 | P2 | A gift to a player who got the look while the prompt was open charged the buyer for nothing. | FIXED: the buyer keeps the look. A retried receipt of a gift that was already delivered keeps its route (`g.Delivered`), so it is never granted twice. store-regression has 2 new asserts. |
| R-05 | src/server/Modules/MetaService.lua:310 | P3 | A streak milestone look that can't be stored (Cosmetics.Owned at the 400 cap) pays DupeGold again on every later claim. That is a small amount of gold and only at the cap. | Open (note) |
| R-06 | src/server/Modules/WeaponSystem.lua:470 | P3 | The delayed Sword and Horn hits set `killSource` outside Step. A kill made outside Step before the next frame could credit the wrong weapon's mastery count. This is cosmetic only. | Open (note) |
| R-07 | src/server/Modules/RunManager.lua:903 | P3 | A Weekly Challenge run gives Hero Mastery XP, and uses the HeroUpgrades, of the lent hero even when the player doesn't own it. Mastery XP is not power until the hero is owned. | Open (owner design call) |
| R-08 | src/server/Modules/StoreService.lua:287 | P3 | `routes` (PurchaseId to gift) is never pruned. It grows by one small entry for each gift on a server. | Open (note) |
| R-09 | src/server/Modules/BuildPresets.lua:32 | P3 | A favourite may name a weapon that is held back (HeldOrder) and not released. It is only a tag on a card that never shows. | Open (note) |
| R-10 | src/server/Modules/Merchant.lua:241 | P3 | In co-op, a buy is allowed while the player is choosing a card. The reward shows without a hold (group rule), so nothing breaks. | Open (note) |

No P0 was found. Pay-to-win: PASS (code read). Remotes and exactly-once grants: PASS (code read plus regressions). Studio and live: BLOCKED.

## Verification
- `bash tools/check.sh --quick`: TYPECHECK ok, COMPILE ok.
- explore-regression: 63 PASS, 0 FAIL.
- events-regression: 36 PASS, 0 FAIL.
- heropower-regression: PASS (asserts).
- store-regression: PASS (asserts).
