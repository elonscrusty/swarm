# Banish (switch `Banish`)

## What
A BANISH button on the level-up panel, next to REROLL and SKIP. Tap BANISH, then a card: that
card's weapon or passive is removed from the offers for the rest of the run and only that one
card slot is re-rolled. The button reads `BANISH` over `3 left` (the same two-line style as
REROLL / SKIP); while banish mode is on it reads `CANCEL` / `Tap a NEW card` and turns gold.

- **Limits:** 3 per run (`Config.LevelUp.Banishes`). At 0 the button is greyed out ("None left
  this run"). Only NEW cards (a weapon or passive you don't own) can be banished. Upgrades,
  evolutions and the bonus cards dim in banish mode (the CHOOSE plate of an upgrade or
  evolution says OWNED); tapping
  one just leaves banish mode, it is never picked by accident.
- **Server-side** (`LevelUpSystem`, remote `LevelUpBanish (index, offerId)`): uses the OfferId
  flow (a stale id is ignored), stores the banished id in the run state (`rp.Banished`,
  `rp.BanishesLeft`, both new every run), the pool skips banished ids (new-weapon / new-passive
  cards, and the "how many unowned" share), and the slot re-rolls with a weighted draw that
  skips the other cards on show. If nothing is left in the pool, the slot becomes the existing
  bonus card: Roast Chicken while hurt, else the Gold Pouch ("Nothing else to offer").
  A banish keeps the panel's deadline and uses no level. Rate limited (3 / s), validated.
- **Input:** touch and mouse (tap BANISH, tap a card), keyboard (B, then 1 / 2 / 3), gamepad
  (Y, or select BANISH and press A, then select a card and press A). While the level-up panel is
  open the HUD's own B / Y (BUILD) is off, so there is no clash.
- **Co-op:** per player (all state lives on that player's run state). It doesn't pause anyone
  and doesn't extend anyone's protection.
- **Layout:** with three buttons the row splits the width; on narrow screens the buttons drop
  their icons and REROLL / SKIP use their short lines (`2 left`, `1 left · +10`).

Code: `src/server/Modules/LevelUpSystem.lua` (pool, `rerollSlot`, the remote),
`src/client/LevelUpBanish.lua` (button, mode, marks, keys), small hooks in
`src/client/UIBuilder.lua` (build, layout, show/close, card pick), remote in
`src/shared/Remotes.lua`.

## Config
- `Config.Features.Banish = true` (false: no button, the offer has no `Banishes`, the remote
  is ignored, nothing is skipped; the panel is exactly as before)
- `Config.LevelUp.Banishes = 3` (the number from the owner's brief)

## Owner steps
1. Studio playtest: on a level-up tap BANISH, then a NEW card; check that card's item never
   comes back that run and the count goes 3 → 2 → 1 → 0. Try B + 1/2/3 on a keyboard and Y on a
   gamepad.

## Regression
Registered in `tools/run_regressions.py` under `# batch B group B`:

- `banish-regression` (real server, Solo run): the banished id is stored, the count goes
  3 → 2, a fresh OfferId, only that slot changed, deadline / pause / pending levels unchanged,
  no duplicate card; a stale id, an owned weapon's upgrade, a forged NEW card of an owned id,
  a bonus card and bad indexes are refused; the pool skips the id and 30 real rerolls never
  offer it; three banishes reach 0 and a fourth is refused; an empty pool turns the slot into
  the Gold Pouch, the XP reward reads Coins and picking it pays and closes the panel safely;
  switched off nothing happens.
- `layout-levelup-{iphone,phone-portrait,pc}-banish-3`: the three-button row;
  `layout-levelup-{iphone,phone-portrait,pc}-banish-2-banishmode-on-evo-on`: banish mode on
  (marked cards, CANCEL button) with the evolution lines.

    python3 tools/run_regressions.py --only banish-regression,layout-levelup-iphone-banish-3

Status: code type-checked (`bash tools/check.sh --quick`: TYPECHECK ok, COMPILE ok). The
regression results are pending the final check (the full round runs at the end of the batch).
Offline only, NOT tested in Studio.
