# HERO-ART: hero models, identity and preview values (overhaul 2026-10)

Owner: HERO-ART. Scope: hero meshes (Blender sources, mesh catalog), `CharacterData` colours
and materials, the part-built hero fallback in `ModelBuilder`. Not in scope: lobby lighting,
camera, Showcase framing (TITLE). Issues: ART-18, ART-19, CP-19 (`docs/overhaul/ISSUE_REGISTER.md`).
Everything below is offline evidence (Blender + preview renderer + Lune scenes). Nothing was
tested in Roblox Studio or on a device.

## 1. Canonical identity audit

### Knight weapon (CP-19): RESOLVED by the owner
What the project already said, before any change:
- `WeaponData.Weapons.Whip.Description`: "Swings a wide sword arc in the direction you face."
- `WeaponSystem.lua` (`WHIP / BLOODWHIP: sword swings, alternating front and back`), the VFX
  slash arc and `CharacterData.Knight.Strengths` ("wide sword cuts") all describe a sword.
- The Knight mesh (`blender/models/heroes.py` `knight`) holds a "steel longsword".
- The icon prompt (`docs/ICON_LIST.md`, Whip.png) asks for "a single heroic broadsword ...
  with one wide pale slash arc ... no whip rope". The uploaded `art/icons/Whip.png` is a
  straight sword with a curved ivory slash arc: the "curved blade" in the review is the slash
  arc, not the blade.
So only the display name "Whip" disagreed. The owner then decided (via the lead): the weapon is
a Sword.

Changes (display only; ids, saves, data keys and regressions unchanged):
- `WeaponData.Weapons.Whip.Name` = "Sword"; its evolution (id `Bloodwhip`) Name = "Bloodblade"
  (the old name contained "whip"; the icon `Bloodwhip.png` already shows one crimson sword).
- `CharacterData.Knight` Description / Tradeoff, `SynergyData` (Bulwark) description,
  `IconData.Glyphs` fallback letters ("Sw", "BB"), `docs/ICON_LIST.md` names,
  `docs/ICON_CHECKLIST.md` (regenerated), `tools/preview/scenes/rewards.luau` mock item.
- Icon: kept (it reads as a sword); no new image prompt needed.
- Not changed: `docs/overhaul/COPY.md` still poses the question (COPY owns it); historical
  notes in other docs keep "Whip" where they describe the id.

### Knight model vs portrait (ART-19)
- The mesh, the hero icon (`art/icons/heroes/hero_Knight.png`) and the lobby all show the
  closed great helm with a dark T visor and crimson plume. The portrait
  (`art/portraits/Knight.png`) shows an open-faced helm so the face reads at card size. This
  is a portrait convention, not a different character: no model change.
- The review frame (short/000s) shows the Knight with the **Gold Trim** skin (Starter Pack,
  owner-verified and sold): gold cape, gold plume, gold trims, plus the VIP crown. That
  explains the rest of the difference. Gold Trim was not changed (sold product).

## 2. Hot white / gold regions (ART-18)

Observed (Roblox capture long/016s): the default Priest is almost entirely clipped white on
the dais; short/000s: the Knight's armour reads near-white. Root causes found in my files
(before blaming bloom):
1. **Values**: the Priest's robe and mitre were ivory_100 (#F3EDDF, the palette's lightest
   tone) with ivory_200 bone/armour; the Necromancer's skull mask was ivory_100. Under the
   lobby's warm key, torches and gold dais ring there was no headroom left.
2. **Material**: the Knight's breastplate, pauldrons and greaves, the great helm shell, and the
   Engineer's helm, pack and pauldrons were Roblox `Metal`. Metal's specular on big curved
   plates gives a large hot patch (preview renderer: a white highlight across the breastplate).
   `ART_VOCABULARY.md` already says Metal is for small surfaces only.

Fix (vocabulary section 7 now records the hero rules):
- Big shells SmoothPlastic in the same slot colours; Metal kept on trims, gauntlets, arms,
  faulds, blades, hilts, rivets (Knight, Hat_Helmet, Engineer; part-built fallback the same).
- Priest: Cloth/Hat ivory_200, Cloth2 ivory_400 (the darker robe front gives the white robe a
  read), Gold gold_500, Metal ivory_300. Necromancer: Bone ivory_200, Metal ivory_300.
- Skins (none sold yet except Gold Trim): Paladin, Angel, Sun Priest, Frost Mage, Crimson
  Guard, Pirate lowered one step on their big ivory / pale-gold slots.
- Unchanged: skin tones (skin_400/500 already mid), every rig, pivot, joint, piece name, slot,
  scale, hat logic, unlock and price; the crimson cape on the default Knight/Rogue/Ranger/
  Engineer/Alchemist.

Meshes: rebuilt with `python3 blender/build.py --only Knight,Priest,Engineer,Necromancer,Hat_Helmet
--samples 12`; only `material` and palette values changed in `meshes/catalog.json` (diff checked),
so the uploaded geometry is reused: no upload, no new asset ids. `MeshCatalog.lua` regenerated.

### Numbers (preview renderer, `showcase` scene, pc, hero crop 400x820)
Share of hero-crop pixels with luminance >= 225 / near-white (min channel >= 230):

| Hero | before | after |
|---|---|---|
| Knight | 2.12% / 0.18% | 0.03% / 0.00% |
| Priest | 2.47% / 0.00% | 1.37% / 0.00% |
| Engineer | 1.42% / 0.00% (measured after the catalog change began; treat as approximate) | 0.93% / 0.00% |
| Necromancer | n/a (render overlapped the edit) | 0.09% / 0.00% |

The preview renderer approximates Roblox lighting (three.js, Metal = metalness 0.6); the Roblox
capture was much hotter than the preview, so these are relative numbers, not a Studio result.

## 3. Verification
- `bash tools/check.sh --quick`: TYPECHECK ok, COMPILE ok, icon/art check 0 problems.
- `data-regression` (0 findings), `whip-regression` (all cases PASS), `passives-regression`
  (13/13) after the rename: PASS.
- Renders (pc): `showcase --set hero=<Id>` and `menu --set hero=<Id>` for all eight heroes,
  `showcase --set skin=Knight_Paladin|Priest_Angel`; `arena` (Knight, Forest) and `arena
  --set character=Priest --set arena=Snow` for in-run readability; `menu-sim` short run.
  Evidence: scratchpad `wf/hero-art/{before,after}/`.
- BLOCKED: Roblox Studio lobby lighting with bloom / Future lighting, phone screens.

## 4. Open points
- **Owner question (one):** the Gold Trim skin (Starter Pack, sold) turns the cape gold, so a
  Gold Trim hero loses the red-cape locator and its cape shares the gold "local player / loot"
  colour. Keep it as sold, or keep the cape crimson with a gold hem?
- Lobby lighting (TITLE): the dais gold ring and warm torches still tint white robes peach;
  if Studio still clips the Priest after this change, lower the dais ring / spot brightness
  rather than darkening the hero further.
- Remaining risk: a Studio check of the Knight's plates without Metal sheen (they may read a
  little flat; the arms, gauntlets and trims keep the steel sheen on purpose).
