# Mobile clarity + boss/combat fairness pass (2026-10-07)

Two owner briefs based on landscape phone recordings at 1108x512: (1) mobile HUD, onboarding,
portal, cards, merchant, ULT/JUMP, start flow, daily, DEV access; (2) first boss, telegraphs,
damage, caravan, villager, Healing Totem, build choices, items, pause, results.

Everything here is **offline-tested only** (Lune preview with the real game modules). Nothing is
verified in Studio, on a real phone or on a live server.

## 1. Confirmed issues fixed

| Issue | Fix |
|---|---|
| Portal banner was pale text straight on bright terrain | Banner sits on a dark plate with a gold rim, in its own lane under the timer/objective stack |
| An urgent banner (wave) waited behind an info banner; stale notices could still play | Critical headlines cut a showing info headline short; validators drop stale portal/wave/stage headlines |
| Portal marker drew over the merchant panel and other panels | Marker hides while any panel is open (run menu, level-up, reward, portal choice, BUILD, merchant) and keeps clear of JUMP/ULT/notices |
| Merchant panel drew under the HUD (DisplayOrder 9 < 10); no close; unaffordable BUY stayed bright | Panel draws above the HUD, has a close X, "RUN GOLD 27", dimmed "NEED 36 MORE" buttons that update live, double-tap guard |
| "Find the portal and summon the Scorpion Queen!" fired before the portal was revealed | Run-start broadcast removed; objective text follows portal state |
| Portal beacon showed before each later stage's reveal (stage 2+) | Beacon also needs this stage's PortalHint |
| Level-up keyboard badges showed on touch phones | Hidden on touch, kept for keyboard/gamepad |
| Queen's charge hurt ~6 studs past the drawn lane | Lane covers the real reach (width 12 -> 14.4, length +7.2) and stops at the fence |
| Stinger spokes drawn 0.45 wide / 18 long vs a 5.2-wide hit lane flying 130 studs | Spokes drawn at the real width, 36 long, fading |
| Telegraph fills finished after the server hit (client started timers on arrival) | Timers count from the server start time |
| Phase 2: Venom Burst (Queen) / Glimmer Mines (Moth) cast twice in a row | A follow-up takes the next cycle slot |
| Contact cooldown was per enemy, not per player (co-op) | Per enemy per player |
| Homing shots circled a burrowed boss | They retarget or fly straight |
| Caravan / villager result toasts were cut on phones ("Back to...") | Toasts wrap to two lines; new short texts |
| Item timers (burns, Windstep, thorns, ward/shield) kept running in a solo pause | Run clock (stops while paused) |
| Barbed Mail text "hit back x1.5" was vague | Full rule: 150% of damage taken (at least half the hit) to every enemy within 8 m, once per 0.5 s, +100% per copy, scales with Might |
| Items strip under the HP panel could not be tapped | Tap opens VIEW BUILD |
| Caravan reward skipped downed teammates though it says "every teammate" | Downed teammates still in the run get it (villager too) |
| Lost Villager could be stranded behind a rock up to 45 studs back; catch-up hop could land in a collider | Hops when stuck more than 12 studs back; hop spot is pushed out of obstacles and kept inside the fence |
| Level-up auto-pick clock ran while the client was still revealing cards | +1.5 s reveal grace (Config.LevelUp.RevealGraceSeconds) |
| Results screen did not say what killed you | "Defeated by: <cause>" line with one matching tip |

## 2. Design improvements

- First solo run: the portal is revealed after the first upgrade pick (cap 45 s); tips go Move -> Auto attack ("Your weapon attacks automatically. Keep moving to dodge enemies!") -> blue gems -> level-up -> portal -> boss. Returning players keep the 4 s reveal; REPLAY TIPS replays the basics.
- Objective pill: "Survive until the portal opens" -> "Reach the portal" -> "Stay in the ring · summoning N%"; ring label "Stand here 2 s to summon".
- Cards lead with one sentence for this pick ("Adds one extra sword swing per attack.", "Earn 15% more gold from kills, chests and bosses."); details line for later levels; "Extra shots" label with weapon compatibility; role chips (Damage/Recovery/Defense/Growth/Utility); first 3 level-ups swap in an immediate option when the pool has one.
- Healing Totem card: "Plants a totem behind you every 9 s (lasts 7 s). Stand in its green ring to heal 2 HP each second; it also hurts enemies." Green-teal pulse with a plus and "+N" only when healing lands.
- Luck/Growth: honest text ("Not a % chance: luck boosts rarity and drop weights").
- BUILD overlay: weapons with base stats, passives with totals, items with full text.
- Phone camera 15% closer on landscape phones (77.5 -> 65.9 studs); dark rim under the player ring.
- ULT: hero icon, charge %, READY glow, one-time callout ("VALOR QUAKE: Slams the ground. Tap ULT!"). JUMP: up-arrow icon.
- New accounts (fewer than 3 runs, not in a party): START SOLO, hero/world summary, ADVANCED OPTIONS folded. Bigger home nav captions (min 12). Daily: "NEW TRY IN 5H 12M · 00:00 UTC", "Scored · 1 try today".
- Scorpion Queen stage-1 intro (Config.Boss.Intro): opens with 2 charges, harmless 0.8 s recoveries after Venom Burst and Stinger Ring, wider phase-1 stinger gaps (72° -> 90°), venom spots marked from the claw pose.
- 0.4 s contact grace after a contact hit (Config.Player.ContactGraceSeconds); boss preference within 20 studs for single-target weapons; IMMUNE cue only when the boss really is immune; DEV-only CombatTrace.
- Stage-1 encounters (Config.Encounters.Intro): no new caravan/escort during the boss fight, 20 s quiet after the boss or a mission reward; caravan needs 1 s in the ring and shows its rules first; stage-1 grace 10 s (8 elsewhere).

## 3. Investigated, not reproduced / already correct

- DEV access: server-checked on every dev remote (DevAccess.IsDev: Studio or the server-only DevAllowlist, which holds only the owner). Ordinary players never get it.
- Daily attempt: used only when the run actually begins on the hosting server; failed teleports and run servers that never start do not use it.
- Attacks are automatic (WeaponSystem). Charge direction is locked once drawn; venom circles are fixed; damage is server-only; one projectile hits once; solo pause freezes boss timers, caravan, villager and weapons.
- Merchant prices: 63 = 25 x 2.5 (the owner's two gold passes raise prices with the gold multiplier). Prices unchanged.
- The "one card then three" level-up moment: no code path found; the reveal is now one 0.3 s animation anyway.
- Revive: NO THANKS exists and the server timer ends the death even if the purchase prompt is closed.

## 4. Tests performed

- Type check + compile: zero diagnostics.
- Full regression run (tools/run_regressions.py, 165 checks): 157 passed first time. The 8 failures were fixed (test timing for the new 1 s caravan start and reveal grace, a test reading the old contact field, merchant card text on narrow cards, the villager unstick bug) or were timeouts from an overloaded machine; all 8 then passed on rerun.
- New scenes: hud-merchant (5 devices, close and double-tap variants, all PASS, layout clean), portal-reveal-sim (PASS).
- Renders + layout checks at phone-1108, phone-small, iphone (Largest text), phone-portrait, tablet, pc: HUD, ULT charging/ready, stage arrow, level-up cards, totem cards, start screen (new and returning), home, daily, results, telegraphs, portal, caravan.
- perf-sim on the iphone profile (see the batch notes for the numbers).

**Not tested:** Studio, a real phone, live servers, real multiplayer, real touch multi-touch, actual
device frame rate, boss fight duration with a starter build (no sim measures it), DataStore saves.

**Known leftovers:** the shared "More" scroll hint can cover two words of a scrolling list
(Daily, Play advanced options); on the shortest phones the merchant panel may still touch the top of
the ability bar; ULT first-ready callout is remembered per session only.
