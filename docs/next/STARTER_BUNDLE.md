# Starter bundle (switch `StarterBundle`)

## What
One developer product, once per account, for new players only. Cosmetic + gold, never power.
- the **Pioneer** Knight skin (a recolour of the Knight meshes, no new mesh; PENDING owner OK),
- `Config.StarterBundle.Gold` = 2,000 gold,
- the **Pioneer** title.

Server (`src/server/Modules/StarterBundle.lua`):
- The offer is open while the switch is on, `Config.Monetization.StarterBundle` is set, the
  save flag `StarterBundleOwned` is false and the save is younger than `OfferDays` (save field
  `FirstJoin`, set when a brand-new save is made; older accounts have 0 and are never offered).
- It is published as the player attributes `StarterOffer`, `StarterEnds` and `StarterOwned`.
  They are re-checked every 30 s, so the card goes away when the offer ends.
- Remote `StarterBundle ("Buy")`: the server checks the offer and opens the Roblox prompt.
- The receipt goes through MonetizationService. Its PurchaseId is recorded, the save is written
  before the receipt is acknowledged, and a duplicate receipt grants nothing. The handler sets
  the flag, adds the gold and the title (worn at once if none is worn). The skin is owned
  through the flag (`MonetizationService.OwnsSkin`, skin `Pass = "StarterBundle"`).
- A second purchase can only come from a race between two servers. It is acknowledged and pays
  the gold again, so nobody pays for nothing.

Client:
- `StarterCard.lua` is the home card. In landscape it sits in the TOP SCORES column under the
  QUESTS chip, and the board moves down; it is left out when the board would lose its second
  row. In portrait it sits under the TOP SCORES strip, only while the hero keeps 200 px. It
  never covers PLAY, the hero or TOP SCORES.
- `MenuStarter.lua` is the STARTER BUNDLE screen (contents plus a BUY button).
- The Store's Skins section shows a Starter Bundle card on top while it is offered.
- The Pioneer skin card (Store) and the skin button (Characters) say STARTER BUNDLE or
  BUNDLE ONLY.
- The price only ever comes from `GetProductInfo`.

Save (additive, no schema bump): `FirstJoin` (os.time of the first save, 0 = an older account),
`StarterBundleOwned` (boolean).

## Config
- `Config.Features.StarterBundle = true`
- `Config.Monetization.StarterBundle = 0` (0 = hidden: no card, no prompt, no receipt handler)
- `Config.StarterBundle = { Gold = 2000, Skin = "Knight_Pioneer", Title = "Title_Pioneer", OfferDays = 7 }`
- New skin `CharacterData.Skins.Knight_Pioneer` (gold metal, moss cloth, plume). New title
  `MetaData` "Pioneer".

## Owner steps
See docs/features/STORE.md, "Starter Bundle". In short: create the developer product, set the
price yourself, paste the id into `Config.Monetization.StarterBundle`, and test in Studio.
**Before shipping, approve the Pioneer skin** (look and name) and the 2,000 gold.

## PASS / BLOCKED
- Offline: `starter-bundle-regression` (run without `--studio`).
  - id 0 hides everything.
  - The offer window and the server prompt.
  - A mock purchase grants flag, gold, title and skin once. Duplicate receipts and a failed
    save are handled.
  - The card hides after the purchase, after 7 days, and for older accounts.
  - Only the owner can wear the skin. The switch off hides everything.
- Layout: `social` scene, `screen=Home|Starter|Store`, on iphone, phone-portrait and pc.
- Run: `python3 tools/run_regressions.py --only starter-bundle-regression`.
- BLOCKED: a real Robux purchase (Studio test purchase or the live game), and the Pioneer
  skin's look on the real Knight mesh in Studio.
