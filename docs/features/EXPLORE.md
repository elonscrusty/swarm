# EXPLORE: secret rooms, merchant cart, lost villager

Wave 1 of the 30-features batch (features 4, 6 and 8). All three are placed
encounters of the `EncounterDirector` (docs/features/FOUNDATION.md). That means at most
`Config.Encounters.Director.MaxActive` (2) placed encounters run on one stage, so not every
stage gets every encounter. Each one has its own switch. When a switch is `false`, its
encounter is never placed and the game plays exactly as before.

| # | Feature | Switch | Server | Tuning |
|---|---|---|---|---|
| 4 | Secret rooms | `Config.Features.SecretRooms` | `src/server/Modules/SecretRoom.lua` | `Config.Explore.SecretRoom` |
| 6 | Merchant cart | `Config.Features.Merchant` | `src/server/Modules/Merchant.lua` | `Config.Explore.Merchant` |
| 8 | Rescue a lost villager | `Config.Features.Rescue` | `src/server/Modules/Rescue.lua` | `Config.Explore.Rescue` |

The client side lives in `src/client/ExploreUI.lua`, which has its own ScreenGui plus world pills.
It draws a pill over each model, the crack shimmer, the "OPTIONAL" tag and HP bar, and the merchant
panel. Everything hides outside a run and whenever a panel covers the HUD.
The models are part-built, with no new meshes or icons. Their item tiles reuse the existing item icons.

## 4. Secret rooms

- The room is a small walled alcove at an arena edge. Its centre sits 20 to 46 studs inside
  the fence (`EdgeMargin`, `EdgeBand`), on a spot the director has reserved. That spot is
  clear of the portal, the loot, the caravan, other encounters, colliders and hazard pools.
  The back wall and the side walls are box colliders standing on the arena's own floor, so
  there is nothing to fall through. The alcove has no roof, so the overhead camera can see
  inside.
- The front is a cracked wall with a glowing gold crack. The crack pulses on the client,
  and that pulse is the hint shimmer. A pill reads "CRACKED WALL / Attack it to break it".
- Every weapon attack a player makes within `BreakRange` (16) studs of the wall chips it.
  Each attack does its damage x its projectile count, capped at `MaxShots`. Wall HP is
  `HP` 70 x (1 + 0.6 x (stage - 1)).
- The wall breaks exactly once. Its collider is removed (the enemy obstacle grid is rebuilt)
  and the alcove holds one of two rewards:
  - **Treasure** (60%): a free "Secret Cache" chest. It follows the same rules as the Buried
    Cache: one item, hold to claim, and LootSystem makes sure it opens only once.
  - **Challenge** (`ChallengeChance` 40%): an elite pack climbs out. The pack is
    `PackBase` 2 elites, +1 every 2 stages, up to `PackMax` 4. Their normal elite drops are
    the reward, and nothing extra is granted.

## 6. Merchant cart

- At most one cart appears per stage, and it leaves when the stage ends.
- Stock is **per player**. Each player gets 3 different items, rolled the first time
  they walk up (`Weights` plus their luck). Each item can be bought once, and only with
  **run gold**.
- **Price (owner note):** this is not a new formula. An item costs exactly what a chest of
  its rarity costs on that stage: Common is the Small chest (25), Uncommon the Large chest
  (60) and Legendary the Golden chest (150), all at stage 1. The server takes
  `ItemData.StagePrice(Config.Chests.Cost[...], stage, CostExponent)` and multiplies it by
  `ItemData.PlayerPrice` with the player's published `GoldMult`. The client shows the price with
  those same helpers and the same attribute, so the shown price is always the charged price.
  To change prices, change `PriceChest` (which chest each rarity copies) or
  `Config.Chests.Cost`, which also changes chests.
- The panel follows the LootUI purchase pattern. It appears while you stand in the cart's ring
  (`InteractRadius` 10) and shows each item's tile, name, rarity and price, with a BUY or SOLD
  button. A price you can't afford turns red, and pressing BUY then shows "NEED N" on the purse.
  Keys 1, 2 and 3 also buy.
- The server decides every purchase (`MerchantBuy`). It checks that the run is simulating,
  that you are alive and not picking a card, that you are in range, that the slot is unsold,
  and that you have the gold. Then it takes the gold, marks the slot sold (so it can only be
  bought once) and grants the item through `ItemSystem.Grant` and the reward reel. Every
  answer sends the stock again.

## 8. Rescue a lost villager

- The villager is optional, and the pill says "OPTIONAL". It waits at least 90 studs from
  the spawn. When a living player comes within 9 studs, the message "Optional: lead the
  villager to the portal!" plays.
- It walks at `WalkSpeed` 15 after the **nearest** living player and stops 5 studs from them.
  It is pushed out of obstacles the same way enemies are, and it stays inside the fence.
  If it gets stuck 45 studs behind for 3 seconds, it hops to its hero.
- Enemies that touch it deal their contact damage, once per `ContactCooldown` per enemy.
  Its HP is 80 x (1 + 0.4 x (stage - 1)). Enemies within 14 studs that are closer to it
  than to any hero turn toward it. If its HP reaches 0, a message says "The villager was
  lost..." and nothing is granted.
- When it reaches the portal ring (`Config.Stages.PortalRadius`), every living teammate
  gets an item (`Weights`, via `ItemSystem.Grant` and the reel). If no item can be granted,
  that teammate gets run gold instead. The reward is granted exactly once.

## Hooks into existing modules (kept small)

- `LootSystem.AddTreasure(arena, pos, title?)`: places a Buried-Cache-style free chest
  mid-stage. `buildTreasure` now returns its object.
- `WeaponSystem.OnFired(fn)`: a listener list that runs after each weapon attack. With no
  listeners, nothing changes.
- `Remotes`: `MerchantStock` (server to client) and `MerchantBuy` (client to server).
- `GameServer` ORDER: `SecretRoom`, `Merchant` and `Rescue` (after `CaravanEvent`).
  `ClientMain`: `ExploreUI.Init()`.
- `Config.Explore`, after `Config.Caravan`.
- Rescue sets `e.Dir` on nearby enemies. EnemyAI keeps that heading until the enemy's next
  think, so this is a nudge and not a full target change.

## Tests

- `explore-regression` (60 checks, real server, about 3 s real time) passed. It covers
  edge placement inside the fence, collider walls, the free inside, weapons chipping
  the wall, opening only once, the removed front collider, both rewards, the cache's single
  item, and the hero standing in the alcove. For the merchant it covers 3 unique offers,
  chest-equal prices, per-player stock, buying for exactly the shown price, and refusals
  for sold, bad slot, stale id, too far, no gold and junk remote arguments. For the villager
  it covers following, being saved in the portal ring with one item granted once, being hurt
  and lost, cleanup on travel and at run end, and switches off.
  run_regressions entry: `"explore-regression"` (in the main list).
- `explore` (visual): the merchant panel and the pills, with `--set focus=merchant|wall|villager`
  and `--set wall=open`. Layout entries: `("layout", ["explore", device])` for iphone and
  phone-portrait.
- `fall-regression`, `foundation-regression` and `check.sh --quick` still pass.

## Verified vs BLOCKED

- PASS (offline Lune): everything listed under Tests.
- BLOCKED: Studio, real phones and live servers. Real Roblox physics against the alcove
  colliders, how the BillboardGui pills look, how touch feels on the BUY buttons, and
  gamepad selection of the BUY buttons (keyboard 1/2/3 and touch/mouse are wired; gamepad
  is not) have not been tested.
- Not done: meshes. The cart, villager and wall are part-built. A Blender mesh can replace
  them later.
