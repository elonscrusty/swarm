# COPY: onboarding, prompts, objective naming, upgrade wording

Helper: COPY (overhaul phase 1). Scope: player-facing text in `src/shared/*Data.lua` (text only,
no numbers), `StatSheet` line labels and units, `Tutorial.lua`, and the new
`src/client/InputPrompts.lua`. All other files are recommendations under **For others**.
Evidence level: offline only (type check, preview regressions, preview renders). Nothing here
was checked in Studio or on a device.

Issues covered: CP-02, CP-03, CP-04, CP-05, CP-06, CP-07, CP-09, CP-10, CP-18, CP-19, CP-20,
CP-21, CP-22, plus section 8 of the master prompt (staged opening goal, input-aware prompts).

## 1. Decisions

| Topic | Decision | Why (from the code) |
|---|---|---|
| Objective name | **Portal** everywhere. "Exit" goes away. | Only `MiniMap.lua:244` says "Exit". The HUD pill, RunIntro, Tutorial, StageUI banners, server broadcasts and StageManager all say "portal". |
| Portal floor zone | **ring** (not "circle" / "rune circle") | RunIntro already says "STAND IN ITS RING"; PortalBeacon draws a pulsing floor ring; the Caravan uses "ring" too. |
| Distance unit | **m** (one game unit = 1 stud, shown as "m") | The HUD markers already print "211 m" (StageUI, TeamUI, LootUI caravan). Player-facing "studs" were only in data text and the pickup-radius card line; those now say "m". |
| Charge time | Always the live `Config.Stages.ChargeSeconds` (2 s today), never a typed number | RunIntro and Tutorial both format it from Config. |
| Upgrade values | Card lines show **build totals** (hero trait + permanent upgrades + items + passives). | `StatSheet.Lines(before, after)` compares two full sheets. A first pick from a non-zero value is correct, e.g. the Knight's Iron Skin (`damageTaken -0.10`) makes Stoneskin L1 read 10% → 16% (CP-09: **not a formula defect**, verified in passives-regression). |
| Last rank wording | "Final upgrade" on a still-pickable last rank; "Maxed" only once the cap is reached. | See the UPGRADE-UI fix below. |

## 2. Staged opening goal (no repeating on several big surfaces)

Before this pass a fresh stage-1 start showed the same instruction up to five times: the RunIntro
card, the StageManager broadcast "<Arena> · find the portal", the RunManager broadcast "Find the
portal and summon the Scorpion Queen!" (hardcoded boss, wrong for Briar Sentinel or Frostbound
Colossus stages), the reveal banner "Follow the arrow · stand in its circle", and the Tutorial
portal tip, which restated the whole plan.

Target staging, one surface per step:

1. **Stage start: RunIntro card** (exists, unchanged): the whole plan. FIND THE PORTAL ("Follow
   the gold arrow") → STAND IN ITS RING ("2 s to charge", live) → BEAT THE BOSS (live boss name).
2. **Portal reveal banner (StageUI)**: only "THE PORTAL HAS APPEARED · Follow the gold arrow".
3. **HUD stage pill**: the current step only (FIND THE PORTAL → OPENING THE PORTAL nn% →
   DEFEAT THE <BOSS> → SURVIVE THE SURGE). Unchanged.
4. **Tutorial portal tip (done)**: shows only when the portal is not being charged yet, and only
   the next step with the real time: "Follow the gold arrow, then stand in the portal's ring for
   2 s." It no longer mentions the boss or repeats the swarm warning.
5. **Tutorial boss tip (done)**: names the summoned boss (`BossName` / `StageBoss`): "Red floor
   shapes show where the Scorpion Queen strikes. Step out!"

Steps 2 and the broadcast clean-ups are in other helpers' files (see For others).

Fresh-account check: the tutorial scene simulates a brand-new profile (`TutorialDone = false`).
A real fresh account in Studio is BLOCKED (no Studio access).

## 3. Input-aware prompts: `src/client/InputPrompts.lua` (new)

One helper that follows the **last input used** (Touch / Gamepad / Mouse = keyboard and mouse),
falling back to device flags only before any input. This replaces scattered
`TouchEnabled and not KeyboardEnabled` checks that show "TAP" to touch-screen laptop users and
"CLICK" to gamepad players.

API: `Mode()`, `OnChanged(fn)`, `Verb()`, `ToSkip()`, `ToClose()`, `ToContinue()`, `HoldKey()`,
`Hold(action?)`, `Back()`, `Choose(count)`, `PickCard()`, `Move()`.
The bindings it describes are listed in its header (confirm/skip = tap, click, Space/Enter,
A; card shortcuts 1-3; interact hold = E / X; back = gamepad B or on-screen BACK; jump =
Space / A / JUMP). Plain ASCII only: no glyphs that a font can miss.

Used now in `Tutorial.lua`: the Move tip text is read when the tip shows and rewritten if the
player switches device while it is up. The first-level-up line under LEVEL UP! is now
input-neutral ("Choose one: a new weapon, an upgrade or a passive") because the card panel's
own hint line already gives the device-specific "Press 1, 2 or 3 to choose" (that was said twice).

## 4. Upgrade copy (checked against the mechanics)

StatSheet line changes (labels and units only; values unchanged):

| Line | Before | After | Mechanic checked |
|---|---|---|---|
| Move speed | 17.6 → 19.2 | +10% → +20% | `Speed = BaseSpeed × (1 + speed)`; shown against BaseSpeed, matching Speed Boots "+10% per level" |
| Pickup radius | 12 studs | 12 m | unit decision |
| Damage taken → **Damage reduction** | -10% → -16% | 10% → 16% | `DamageTaken` multiplier on incoming hits, before flat armor (RunManager.DamagePlayer). Negative only if curses raise damage taken. |
| Thorns → **Thorns (of hit taken)** | 80% of hit | 80% | ItemSystem.OnHurt: max(damage taken after armor, half the raw hit) × share × your Damage, radius 8, 0.5 s shared cooldown with Barbed Mail |
| Speed after a kill → **Speed 1.5 s after a kill** | +8% | +8% | ItemSystem.OnKill: `Tuning.WindstepSeconds`, refreshed per kill (label built from Tuning) |
| Heal per level-up | 8% HP | 8% max HP | ItemSystem.OnLevelUp heals `MaxHP × share` |
| Damage below 40% HP | | Damage below 40% max HP | `Tuning.LionheartHp` share of max HP (label built from Tuning) |
| Heal standing still | 2% HP/s | 2% max HP/s | share of max HP per second |

Data text: Windstep "Each kill gives extra speed for 1.5 s."; Second Wind "...a share of your
max HP."; Lionheart "...below 40% max HP."; Thornhide "When hit, strike back at foes close to
you."; Aegis Charm "blocks one whole hit". ItemData: Healing Herb missing full stop; Volatile
Spore / Magnet Totem "studs" → "m" (45 m verified: MagnetRadius 35 + 10 per stack); Guardian
Ward "8% max HP shield"; Barbed Mail states its real basis (150% of damage taken, +100% per
stack, at least half the raw hit, 8 m); Phoenix Feather "50% max HP" (ReviveHPFraction).
CharacterData: Knight trade-off "about 7 m".

Not changed: Stoneskin "Take 6% less damage per level." (additive into the same multiplier, so
true); passives keep the ≤48-character NEW-card limit (passives-regression asserts it).

## 5. Solo vs co-op, party, glyphs, uppercase

- Solo strings that say "every teammate", "for everyone", "Waiting for your team": all in other
  helpers' files; exact changes below (CP-02).
- Party: the hint "When the leader starts SOLO, DUO or TRIO, the party joins that run together"
  is wrong for SOLO and Daily: `RunManager.joinParty` takes members only up to the mode's size
  and tells the rest "no room for you" (CP-20). Fix below.
- Glyphs: the only risky one in UI strings is U+25BE in results "More below ▾" (CP-18). `•`,
  `·`, `→` are drawn by the game's fonts in the previews and stay.
- Account level stays cosmetic: `AccountData` grants no combat stat (CP-21, keep).
- Uppercase: Tutorial and InputPrompts return sentence case; screens decide caps. Recommend
  caps only for labels of four words or fewer (CP-22).

## 6. Owner question (CP-19, not renamed)

The Knight's starting weapon has the id and name "Whip", but its description says "Swings a wide
sword arc", the Knight holds a sword and the icon is a curved blade. One question for the owner:
**"Should the Knight's first weapon be called Sword (it is a sword swing) or stay Whip?"** No
mechanic or id change either way; only `WeaponData.Weapons.Whip.Name` and the Knight's text would
change.

## 7. For others (exact changes)

UPGRADE-UI
- `src/client/UIBuilder.lua:672-673` (`cardKind`): `elseif c.Rarity == "Epic" then return "MAX LEVEL"`
  → `return "FINAL UPGRADE"`. The server sets Rarity "Epic" when the card's level equals the cap
  (`LevelUpSystem.lua:446-447`, `476-477`), so the card is still pickable. Use "MAXED" only in the
  build/tray view for an item already at cap (CP-01).
- `UIBuilder.lua:745` `STAT_ICONS`: add `{ "reduction", "shield" }` before `{ "damage", "sparkle" }`
  so "Damage reduction" keeps a defensive icon; add `{ "thorns", "shield" }` (Thorns now falls back to chevronsUp).
- Card values are totals: label the change box "Total" (or show "+6%" added under it) for
  CP-09/CP-12. StatSheet lines already carry From/To totals.

CHOICE-SERVER (`LevelUpSystem.lua:442`, `474`, CP-08): Rank `"Lv %d → %d / %d"` mixes transition
and cap. Suggest `"Rank %d of %d"` (the new rank) and, when it equals the cap, `"Final rank"`.

RUNINTRO / UISTATE (CP-03): `src/client/RunIntro.lua:323` →
`ui.Close.Text = UIKit.track(string.upper(InputPrompts.ToClose()))` (require
`script.Parent.InputPrompts`). `UIBuilder.lua:2313` "TAP TO SKIP" →
`UIKit.track(string.upper(InputPrompts.ToSkip()))`, and refresh both via `InputPrompts.OnChanged`.
`UIBuilder.lua:889` `choiceHint` → `InputPrompts.Choose(count)` (same text, one source).
`LootUI.lua:856-861` hold label → `string.upper(InputPrompts.Hold())` (keeps "HOLD  E" spacing if
wanted: `"HOLD  " .. InputPrompts.HoldKey()`).

HUD / UISTATE (naming and staging)
- `src/client/MiniMap.lua:244` legend `Name = "Exit"` → `"Portal"` (CP-04).
- `src/client/StageUI.lua:96` reveal sub `"Follow the arrow · stand in its circle"` →
  `"Follow the gold arrow"` (the ring is the next step; the HUD pill and RunIntro carry it).
- `src/client/Hud.lua:1589` dead player in a group: keep; it only shows in group runs.

SERVER BROADCASTS (CHOICE-SERVER / FLOW owners of RunManager, StageManager)
- `RunManager.lua:1090` remove `Broadcast("Find the portal and summon the Scorpion Queen!")`:
  duplicates RunIntro and names the wrong boss on non-Queen stages.
- `StageManager.lua:768` drop the `" · find the portal"` suffix (keep arena + hazard hint).

SOLO COPY (CP-02; solo = `state:GetAttribute("Participants") <= 1` or the run's player count)
- `LootSystem.lua:528` → solo `"Free uncommon or legendary item"`, group unchanged.
- `LootSystem.lua:539` → solo `"Free: one item for you"`.
- `LootSystem.lua:959` → solo `"You opened the altar: a free item!"`.
- `CaravanEvent.lua:213` → solo `"An item and gold for you"`; `:388`/`:392` → solo "...An item
  and gold for you."
- `StageUI.lua:327` → `ui.Next.SetText("READY", (offer and offer.Group) and "Waiting for your team" or "Traveling...")`.
- `StageUI.lua:759` already falls back to "Traveling in %ds" when nobody else is listed; keep.

CARAVAN (CP-05): `CaravanEvent.lua:360` → `"Optional: defend the caravan! Hold its ring for %d seconds."`;
`LootUI.lua:365/1016` bar title `"DEFEND THE CARAVAN"` → `"OPTIONAL · DEFEND THE CARAVAN"` when
it fits, and after success/failure broadcast add "Back to the portal!" (`CaravanEvent.lua:388/401/403`).

PARTY (`src/client/MenuParty.lua:547`, CP-20) →
`"Invite players on this server or your friends. When the leader starts DUO or TRIO, party members join that run (up to its size). SOLO and Daily runs are the leader's alone."`
and `:549` → `"When everyone is READY, press START (or DUO / TRIO on the home screen): your party joins your run."`

RESULTS (`UIBuilder.lua:3184`, CP-18): replace `"  \u{25BE}"` with an `Icons.Draw(..., "chevronDown")`
image (or drop the glyph and keep "MORE BELOW").

## 8. Tests

| Test | Result | What it exercised |
|---|---|---|
| `bash tools/check.sh --quick` | PASS for my files (3 diagnostics, all in other helpers' in-progress files: MapBuilder, MenuPlay) | type check + compile |
| `data-regression` | PASS, 0 findings | data shapes incl. edited text tables |
| `passives-regression` | PASS 13/13; every NEW passive ≤48 chars; card lines print e.g. "Stoneskin L1: Damage reduction 10% -> 16%", "Windstep L1: Speed 1.5 s after a kill +0% -> +8%" | StatSheet labels and real mechanics |
| `tutorial` iphone, tips Move / Portal / Boss | see section 9 | card layout, text wrap |
| `check_layout.py` on those JSONs | see section 9 | overlap / overflow |

## 9. Render results

(filled in below after the renders)

## 10. Remaining risk

- InputPrompts is only wired into Tutorial so far; the other prompts change when their owners
  apply section 7. Gamepad text is untested (the preview mock has no gamepad).
- "m" for game units is a presentation choice; if the owner prefers "studs", change StatSheet
  pickup radius, the data text and the three HUD marker formats together.
- Nothing is Studio- or device-verified.
