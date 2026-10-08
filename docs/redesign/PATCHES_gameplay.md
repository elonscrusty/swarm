# Patches the gameplay track needs in lobby-owned files

For the final merge. The class kits (docs/redesign/gameplay/CLASSES.md) did not edit
`DataService.lua` or any lobby file.

## DataService.lua (lobby track)

1. **Ownership of Ruckus.** `ClassRoster.Register` (run at RunBoot, before any player joins) sets
   `CharacterData.Default = "ruckus"`. `DataService` already reads `CharacterData.Default` when it
   creates a profile (`OwnedCharacters = { [CharacterData.Default] = true }`) and in the load clean-up
   (`data.OwnedCharacters[CharacterData.Default] = true`), so Ruckus is owned by every account with no
   change. If the lobby track wants an explicit rule instead, grant `ruckus` there and keep the line.
2. **Old selection.** A profile whose `SelectedCharacter` is one of the 11 old heroes stays valid
   (their `CharacterData.Characters` entries are kept) and the run plays Ruckus instead
   (`ClassRegistry.RunHero`). The lobby should show the selection as Ruckus too. Suggested patch in the
   load clean-up, after the `SelectedCharacter` check:

   ```lua
   if table.find(ClassCatalog.LegacyIds, data.SelectedCharacter) then
       data.SelectedCharacter = ClassCatalog.Default
   end
   ```

   (Only the selection is rewritten; `OwnedCharacters`, `Heroes`, `HeroUpgrades` and skins are never
   touched.)
3. **Per-class sanitising.** The load clean-up loops `CharacterData.Order` for `Heroes` /
   `HeroUpgrades`. At RunBoot `Order` becomes the four class ids (old heroes removed), so the new ids
   are covered and the old ones are left untouched ("unknown ids are left untouched"). Nothing to patch,
   but if the lobby track keeps its own copy of the list it must contain the four class ids.

## Client

- The client has its own copy of `CharacterData`. Call
  `require(ReplicatedStorage.SwarmV2.Run.ClassRoster).Register(CharacterData, MetaUpgradeData)` once at
  client start (before any screen builds a hero list) so screens and the HUD know the four ids, their
  colours and prices. It is idempotent and never overwrites. The lobby track's `ClassCatalog` stays the
  presentation source for lobby cards.
- Class pictures: `Icons` / `IconData` have no `hero:ruckus` ... entries yet, and the four weapons
  (`ScrapToss`, `ToastVolley`, `BubbleBomb`, `YarnBomb`) and their evolutions have no uploaded card
  icons; the cards use the drawn fallbacks until art is uploaded.

## Mesh pipeline (art, not code)

Models `Ruckus`, `Toastmaster`, `CaptainCroak`, `GrannyBoom` (category `Classes`) need `MeshCatalog`
entries. `CharacterData.Characters[id].MeshName` already points at them; until then the part-built
fallback is used.
