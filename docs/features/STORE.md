# STORE: the cosmetic Robux store

Switch: `Config.Features.Store`. When it is `false`, the STORE card and screen are hidden,
the server offers and sets nothing, and the game behaves exactly as it did before.

Robux buys **looks only**: skins, trails, death bursts, pets, emotes, nameplate frames,
lobby dais themes, the Supporter pass, and early unlocks of heroes that can also be earned
by playing. Nothing here changes stats, gold, items, XP, revives or a run's power. Pets
give no stats and never pull pickups.

## What it is

- **STORE screen** (`src/client/MenuStore.lua`). Open it from UPGRADES > SHOP > OPEN STORE.
  It has sections for Skins, Trails, Death bursts, Pets, Emotes and poses, Nameplates,
  Lobby dais, Supporter, Hero early unlocks and Gift. The existing gold packs, passes and
  Revive stay on the SHOP tab, which works the same as before.
- **Items.** Every item comes from `CosmeticData`. The store items themselves are listed
  in `src/shared/StoreCatalog.lua`.
  - Earned items show their goal and progress, for example "Win 10 runs · 3 / 10".
  - Store items show the Robux price from `MarketplaceService:GetProductInfo`. While an
    item's id in Config is 0, it shows "Coming soon". No price is written anywhere in
    the game's code.
- **Server** (`src/server/Modules/StoreService.lua`, with hooks in `MonetizationService`).
  - `StoreBuy` checks the item and opens the Roblox prompt from the server.
  - Passes are checked with `UserOwnsGamePassAsync`. The answer is cached and refreshed
    on `PromptGamePassPurchaseFinished`.
  - Products are granted in `ProcessReceipt` using the existing `PurchaseId` pattern, into
    `data.Cosmetics.Owned`. A hero unlock sets `OwnedCharacters[id]` instead.
  - If the player cancels or the payment fails, they see a calm line: "No purchase made.
    Nothing was charged."
- **Gift.** In the Gift section, the player picks someone else in the same server and
  buys a store look for them. The server records the target when the purchase starts.
  When the receipt arrives, the server checks again that the recipient is still in this
  server, grants the look into the recipient's save, and saves that before it confirms
  the receipt. If the recipient has left, the buyer gets the look instead.
  - You can't gift to yourself, to someone who already owns the look, or to someone who
    isn't in the server.
  - Passes and heroes can't be gifted.
  - A pending gift expires after `Config.Store.GiftSeconds`.
  - A retried receipt goes to the same person as the first try.
- **Equip.** `StoreEquip(kind, id)` only accepts looks the server says you own. The worn
  ids reach every player as attributes (`CosTrail`, `CosBurst`, `CosPet`, `CosEmote`,
  `CosPlate`, `CosDais`, `Supporter`).
- **Visuals** (`src/client/StoreFx.lua`). Everything is built from parts, runs only on
  each player's own device, and never collides with anything.
  - Pets follow the hero in the lobby and in runs. Each pet is 2 to 6 parts. At most
    `MaxPets` are drawn, the nearest ones first.
  - Trails are drawn behind the hero.
  - Nameplates show the frame you wear, plus the Supporter glow and badge.
  - Emotes pop an icon over the hero.
  - The dais theme and the Supporter banner show on the lobby dais.
  - Death bursts restyle `HitFeel`'s bursts through `HitFeel.SetStyle`, on your own
    screen only.
  - Other features can hook in:
    - `StoreFx.DecoratePlate(frame, player)` lets the titles plate (META) use the worn
      frame instead of drawing a second plate.
    - `StoreFx.Emote()` plays the emote you are wearing.
    - The emote `Pose` names are there for photo mode to use.
- **Supporter pass.** It gives a `[SUPPORTER]` chat tag, a SUPPORTER badge on the
  nameplate, a glowing plate and a banner next to the lobby dais. Once the pass has been
  seen, `data.Supporter` stays true.

## How to tune it

- `Config.Store`:
  - `GiftSeconds`: how long a gift target is kept while the Roblox prompt is open.
  - `EmoteCooldown`, `EmoteSeconds`: the gap between emotes, and how long one shows.
  - `MaxPets`, `PetRange`, `PlateRange`: how many pets are drawn, and how far away pets
    and nameplates are drawn.
- Items, looks and earned goals live in `StoreCatalog.Entries`. An earned goal looks like
  `Earn = { Stat = "Wins", At = 10 }` or `{ Level = 15 }`.
- Ids go in `Config.Monetization`:
  - `Cosmetics` holds the products.
  - `CosmeticPasses.Supporter` holds the Supporter pass.
  - `HeroUnlocks` holds the hero products.
  - `SkinPasses` holds the skin passes (existing, see `docs/SKIN_PASSES.md`).

## Owner steps (Creator Dashboard)

Claude never creates products, never sets prices and never makes purchases. Repeat these
steps for each row in the table below.

1. Open Creator Dashboard > SWARM > **Monetization**.
   - For a pass, go to **Passes** > **Create a Pass**.
   - For a product, go to **Developer Products** > **Create a Developer Product**.
2. Enter a name and a short description, for example "Ember Trail: a warm ember streak
   behind your hero. Looks only." If you like, add a picture.
3. **Choose the price yourself.** For a pass, also turn on **Item for Sale**.
4. Copy the **ID** and paste it into the Config key from the table, in
   `src/shared/Config.lua`. You can also send the ids to Claude, one per line, like
   `Trail_Ember = 1234567890`.
5. Test in Studio: Play > lobby > UPGRADES > SHOP > OPEN STORE > the item's section.
   - The card shows `R$ <your price>`.
   - Tap it: Roblox opens a **test purchase**, and Studio doesn't charge Robux.
   - After buying, the card reads OWNED and WEAR works. A product survives a rejoin.
   - Press Cancel: you see "No purchase made. Nothing was charged."
   - Gift: start a 2-player local server test (Test > Clients and Servers > 2 players).
     Gift a look to Player2. Player2 gets it and sees "<name> sent you a gift".
6. Rebuild and publish. A Config id that is still 0 keeps showing "Coming soon".

| Item | Type | Config key | What it gives | Earned alternative |
|---|---|---|---|---|
| 12 hero skins | pass | `SkinPasses.<SkinId>` (see SKIN_PASSES.md) | a hero's colours and hat | none (Gold Trim comes with the Starter Pack) |
| Ember Trail | product | `Cosmetics.Trail_Ember` | ember trail behind the hero | Leaf Trail (play 25 runs), Starlight Trail (account level 15) |
| Frost Trail | product | `Cosmetics.Trail_Frost` | blue mist trail | same as above |
| Royal Trail | product | `Cosmetics.Trail_Royal` | violet and gold trail | same as above |
| Confetti Burst | product | `Cosmetics.Burst_Confetti` | foes pop into confetti on your screen | Gold Burst (defeat 25,000 foes) |
| Void Burst | product | `Cosmetics.Burst_Void` | glowing violet death shards | Gold Burst |
| Frost Burst | product | `Cosmetics.Burst_Frost` | ice death shards | Gold Burst |
| Ember Fox | product | `Cosmetics.Pet_Fox` | fox pet that follows you (no stats) | Moss Slime (win 10 runs), Lantern Wisp (reach stage 6) |
| Snow Owl | product | `Cosmetics.Pet_Owl` | owl pet (no stats) | same as above |
| Little Drake | product | `Cosmetics.Pet_Drake` | small dragon pet (no stats) | same as above |
| Cheer | product | `Cosmetics.Emote_Cheer` | star emote over the hero | Wave (play 1 run), Bow (win 3 runs) |
| Victory Flex | product | `Cosmetics.Emote_Flex` | trophy emote | same as above |
| Gilded Plate | product | `Cosmetics.Plate_Gold` | gold nameplate frame | Ivy Plate (account level 10); titles and colours from the level track |
| Ember Plate | product | `Cosmetics.Plate_Ember` | red-hot nameplate frame | Ivy Plate |
| Obsidian Dais | product | `Cosmetics.Dais_Obsidian` | black glass lobby dais, violet light | Marble Dais (win 5 runs), Grove Dais (reach stage 8); track rings |
| Sunfire Dais | product | `Cosmetics.Dais_Sunfire` | warm stone dais with fire light | same as above |
| Supporter | pass | `CosmeticPasses.Supporter` | SUPPORTER badge and chat tag, glowing Supporter plate, lobby banner | none (a thank-you pass) |
| Archer early unlock | product | `HeroUnlocks.Archer` | the Archer now | buy with 10,000 gold from runs |
| Bard early unlock | product | `HeroUnlocks.Bard` | the Bard now | buy with 20,000 gold |
| Golem early unlock | product | `HeroUnlocks.Golem` | the Golem now | buy with 30,000 gold |

Any store product above can be gifted. Passes and hero unlocks can't.

## Verified vs BLOCKED

- **PASS (offline Lune):**
  - `store-regression` runs without `--studio`. It covers purchase success, cancel, a
    failed save followed by a retry, duplicate receipts, an unknown product, Coming soon,
    already owned, malformed payloads, and the switch turned off.
  - Equip checks: you must own the look, it must be the right kind, and weapon glows
    can't be equipped here. Forged worn ids are hidden.
  - Gift checks: the target is checked on the server, the recipient's save is written,
    and no spoofing is possible. Gifts to yourself, to an unknown player, of a pass, to
    someone who already owns the look, and of a hero are all refused. A stale target
    expires, a retry goes to the same recipient, and a gift to someone who left goes to
    the buyer.
  - The Supporter pass signal, earned looks (none for a DEV-boosted profile) and the
    Archer unlock.
  - Layout: the `store` scene passes on iphone and phone-portrait with `check_layout` at 0.
- **BLOCKED:** real Roblox purchase prompts, real prices, `GetProductInfo`, gifting
  between two real clients, pets, trails and plates on devices, and Studio performance.
  None of this is tested in Studio. All products are at id 0 until the owner creates them.
- **Known limits:**
  - If the server shuts down between the gift prompt and the receipt, the retried
    receipt goes to the buyer.
  - A gift to someone who left, when the buyer already owns the look, is still confirmed
    (Roblox has charged), but nothing new is granted.
  - Emote poses are icon pops only. The heroes don't animate yet.
