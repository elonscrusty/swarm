# Hero skin game passes: creation checklist

Skins are **cosmetic only**. A skin changes the colours and hat shape of one hero and nothing
else: no stats, no gold, no drops, no advantage in runs, leaderboards or records. They are never
required for anything and cannot be bought for gold. (Rule: Robux buys cosmetics/coins only.)

The owner creates the passes and sets the prices in Creator Hub. Claude never creates products
or chooses prices. Until a pass id is filled in, the skin tile shows "SOON" in the lobby.

## Steps (repeat for each skin below)

1. Creator Hub > the SWARM experience > **Monetization** > **Passes** > **Create a Pass**.
2. Upload the picture from `art/store/skins/` (512 x 512, no text; also zipped as `SWARM_skin_pass_images.zip`).
3. Name and description: copy from the table (names have no digits on purpose, so Roblox's
   filter does not hash them).
4. Press **Create Pass**.
5. Open the new pass > **Sales** > turn on **Item for Sale** and enter the price (your choice).
6. Copy the pass **ID** (the number in the pass page address, or shown on the pass page).
7. Send all the IDs to Claude, one per line, like `Knight_Crimson = 1234567890`. Claude fills
   `Config.Monetization.SkinPasses` (`src/shared/Config.lua`) and rebuilds.

## The twelve passes

| # | Picture file | Pass name | Description | Config key to fill |
|---|---|---|---|---|
| 1 | `art/store/skins/Knight_Crimson.png` | Crimson Guard (Knight Skin) | A cosmetic skin for the Knight: crimson armour with ivory trim, gold details and a red plume. Looks only. | `SkinPasses.Knight_Crimson` |
| 2 | `art/store/skins/Knight_Shadow.png` | Shadow Knight (Knight Skin) | A cosmetic skin for the Knight: dark steel armour with crimson accents and a horned helm. Looks only. | `SkinPasses.Knight_Shadow` |
| 3 | `art/store/skins/Knight_Paladin.png` | Paladin (Knight Skin) | A cosmetic skin for the Knight: bright silver armour with gold trim and an ivory tabard. Looks only. | `SkinPasses.Knight_Paladin` |
| 4 | `art/store/skins/Mage_Frost.png` | Frost Mage (Mage Skin) | A cosmetic skin for the Mage: icy blue-grey robes with a pale wizard hat. Looks only. | `SkinPasses.Mage_Frost` |
| 5 | `art/store/skins/Mage_Ember.png` | Ember Mage (Mage Skin) | A cosmetic skin for the Mage: deep red robes with gold trim and a tall top hat. Looks only. | `SkinPasses.Mage_Ember` |
| 6 | `art/store/skins/Mage_Void.png` | Void Mage (Mage Skin) | A cosmetic skin for the Mage: near-black robes with a hood and a silver-grey glint. Looks only. | `SkinPasses.Mage_Void` |
| 7 | `art/store/skins/Rogue_Forest.png` | Woodland Rogue (Rogue Skin) | A cosmetic skin for the Rogue: mossy green cloak, leather gear and a cap with a red feather. Looks only. | `SkinPasses.Rogue_Forest` |
| 8 | `art/store/skins/Rogue_Pirate.png` | Pirate (Rogue Skin) | A cosmetic skin for the Rogue: crimson coat, wooden gear and a bandana. Looks only. | `SkinPasses.Rogue_Pirate` |
| 9 | `art/store/skins/Rogue_Ninja.png` | Ninja (Rogue Skin) | A cosmetic skin for the Rogue: black outfit with red accents and a dark beanie. Looks only. | `SkinPasses.Rogue_Ninja` |
| 10 | `art/store/skins/Priest_Sun.png` | Sun Priest (Priest Skin) | A cosmetic skin for the Priest: golden robes with a crown and red accents. Looks only. | `SkinPasses.Priest_Sun` |
| 11 | `art/store/skins/Priest_Moon.png` | Moon Priest (Priest Skin) | A cosmetic skin for the Priest: moonlit slate robes with silver trim and a mitre. Looks only. | `SkinPasses.Priest_Moon` |
| 12 | `art/store/skins/Priest_Angel.png` | Angel (Priest Skin) | A cosmetic skin for the Priest: ivory robes with gold trim and a golden halo. Looks only. | `SkinPasses.Priest_Angel` |

## After the ids are in

- Studio playtest: lobby > CHARACTERS > pick the hero > the skin card shows an R$ pill (not
  SOON); tapping GET SKIN opens the Roblox purchase prompt; after buying, the skin is OWNED and
  equips on tap.
- A pass with id 0 stays "SOON" and "COMING SOON" (no prompt can open).
- Pictures are rendered by `python3 tools/make_skin_pass_images.py` (the offline preview scene
  `showcase --set skin=<id> --set bg=slate`). They show the in-game low-poly look from the
  offline renderer, not a Studio screenshot; swap in your own art any time.
