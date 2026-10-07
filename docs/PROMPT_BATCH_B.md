# SWARM batch B: 4 improvements (owner request, 2026-10-07)

Paste everything below the line into a chat.

---

Read docs/HANDOFF.md and CLAUDE.md first. Build these 4 improvements in SWARM on `main`. CLAUDE.md rules apply:
- Never pay-to-win.
- Don't invent prices, publish or wipe saves.
- Report PASS/FAIL/BLOCKED; never present a mock as working.

General requirements:
- Give each item its own `Config.Features` switch (on by default). Switched off, the game behaves exactly as now.
- Save fields are additive with defaults, with no schema bump unless required.
- All gameplay effects and grants are server-side, exactly-once and DEV-taint aware.
- New screens or HUD pieces are their own client modules (UIBuilder.lua is at the 200-local limit) and must fit iphone at Roblox Text size Largest (the preview default), phone-portrait and pc, with check_layout at 0. Respect UIState.
- One regression scene per item, registered in tools/run_regressions.py, plus a short doc in docs/next/.
- Run one lune process at a time.
- At the end: full regressions, `bash tools/check.sh`, rebuild `build/Swarm.rbxlx`, push to main, and send the file plus renders.

## 1. Elite affix icons (switch `AffixIcons`)
- **Show what's already there:** elites already roll affixes from `Config.Enemies.EliteAffixes` (Swift, Shielded, Burning; see EnemySpawner/EnemyAI/EnemyRenderer).
- **Badge:** each elite gets a small badge above its health bar with one icon per affix:
  - Swift: blue boots or lines
  - Shielded: silver shield
  - Burning: orange flame
- **Shape and colour:** use a different shape per affix as well as the colour, for colour-blind players.
- **Size:** 18-22 px on phones, readable at game zoom. Never wider than the elite's health bar.
- **Implementation:** client-only, read from the elite's existing affix attribute. If there isn't one, add one replicated attribute on the server; no new remote.
- **First sight:** the first time a player meets each affix, show a one-line notice through the UIState notice lane, for example "Shielded elites block the first hits". Store it in the save field `SeenAffixes`, so it's once per account.
- **Reduced effects:** keeps the icons and drops their pulse.
- **Regression:**
  - the icon matches the affix
  - it's removed when the elite dies
  - the first-sight notice shows once
  - it fits on iphone and phone-portrait

## 6. Final Stand (switch `FinalStand`)
- **Trigger:** when the hero's HP drops below 10% of max for the first time in a stage, while alive, trigger Final Stand for 5 s:
  - +30% move speed
  - +40% damage
  - a crimson-gold aura and a short headline "FINAL STAND!" through UIState
  - one sound, using the existing SFX
- **Limits:**
  - once per stage per player, re-armed at stage start
  - doesn't trigger while the hero is protected/choosing, or within 2 s of a revive
  - no healing; it doesn't block lethal damage
  - in co-op, it works per player
- **Server-side:** the buffs go through StatSheet/RunManager temporary modifiers, cleared on timeout, death, stage end and leaving the run.
- **Balance:** measure with the econ-sim (docs/overhaul/BALANCE_TUNE.md method): would-be deaths and clear times before/after, at least 3 seeds. It should help a little, not make runs easy. Record the numbers in docs/next/FINAL_STAND.md.
- **Regression:**
  - triggers at <10% once per stage, re-arms next stage
  - not while protected
  - buffs removed after 5 s and on death or leave
  - the stat math is correct

## 12. Prestige (switch `Prestige`)
- **Who:** a hero whose Hero Mastery track is fully maxed (Config.HeroMastery / MetaUpgradeData) can Prestige from the Characters screen.
- **What it does:**
  - resets that hero's mastery upgrade LEVELS to 0
  - keeps everything else: gold, unlocks, cosmetics, skins, other heroes
  - gives that hero a Prestige star, up to 5 stars
- **Reward per star:**
  - +5% gold from runs played with that hero (lobby payout at settlement only, NOT in-run chest gold, so chest prices still match the GoldMult rule), capped at +25%
  - a star badge on the hero's portrait and nameplate
  - no damage, health or other combat power
- **Confirmation:** a clear screen that lists exactly what resets and what stays: "Your Knight's upgrades go back to level 0. You keep your gold, skins and other heroes. You get ★1 and +5% gold with the Knight." The button reads "PRESTIGE KNIGHT" and needs a second tap within 3 s.
- **Server:**
  - verifies the track is maxed
  - does the reset and star atomically in one save update
  - exactly-once, with a rate limit
  - save field `Prestige = { [heroId] = stars }`
- **Never by accident:** no Robux path, and no reset happens without the confirm.
- **Regression:**
  - refused when not maxed
  - reset and star exactly once
  - the gold bonus applies at settlement only, capped
  - the cap holds at 5
  - other heroes are untouched
  - fits on iphone and phone-portrait

## 18. Quick resume (switch `QuickResume`)
- **Existing:** co-op already has a rejoin grace (`Config.RunServers.RejoinGraceSeconds` = 120; see RunManager `RunReconnect`, RunServers, and the coop-regression/reconnect-lobby scenes). Extend it to SOLO runs.
- **On disconnect from a solo run:**
  - keep the run server and its state for 60 s (`Config.RunServers.SoloResumeSeconds`)
  - pause the run clock and freeze enemies; nothing can damage the empty hero
- **On rejoin within 60 s:** if the player joins the game, or opens the lobby, show a big "RESUME RUN (0:42)" card first. Tapping it teleports them back into the same run with the same build, HP, gold, XP, stage and wave.
- **If they don't return in time:**
  - settle the run exactly as a loss/leave does today: the existing gold-kept rule, no double payout
  - free the server
- **Security:**
  - only the same UserId can resume
  - one resume per disconnect
  - a resumed run keeps its DEV taint
  - leaderboards only get the final settled score, once
- **BLOCKED offline:** real teleports and multi-server need Studio or live. Mock them as the existing reconnect scenes do, and mark that BLOCKED.
- **Regression:**
  - a disconnect freezes the run
  - a rejoin within 60 s resumes the same state
  - after 60 s it settles once
  - a wrong user can't resume
  - no double settlement
  - the resume card fits on iphone and phone-portrait

## Order
Do 1, then 6, then 12, then 18.

Before shipping, ask the owner to approve:
- the Final Stand numbers
- the Prestige reward (+5% gold per star, max 5)

Report PASS/FAIL/BLOCKED per item.

---

## Added to batch B (owner, 2026-10-07): 6 more items, same general requirements as above

## B5. Show weapon evolutions early (switch `EvolutionPreview`)
- **Check first:** the level-up card already has an "Evolves into X with Y Lv N" line (UIBuilder level-up section and HeroPresets). Build on it; don't duplicate it.
- **On a weapon card:** when the weapon has an evolution, show a small evolution icon (the evolved weapon's icon) plus its name, and the requirement with live progress, for example "Bloodblade: Sword Lv 12 + Heart Lv 3 (you: Heart 1)".
- **On a passive card that's an evolution ingredient:** show the same small line, "Needed for Bloodblade".
- **In the BUILD panel:** add an "Evolutions" section listing every evolution possible with the current build, with what's still missing.
- **Data only:** read from WeaponData/SynergyData. No new combining or fusion system.
- **Fit:** iphone at Largest text, phone-portrait and pc; check_layout at 0. Lines shrink-to-fit or wrap.
- **Regression:** the right evolution is shown, progress updates after picks, the panel lists the missing parts.

## B6. Banish (switch `Banish`)
- **On the level-up panel:** a BANISH button next to REROLL and SKIP. Tapping it, then a card, removes that card's weapon or passive from offers for the rest of the run.
- **Limits:** 3 banishes per run (`Config.LevelUp.Banishes`), shown as "BANISH · 3 left". Never banish something you already own.
- **Server-side, using the OfferId flow:**
  - the banished id is stored in the run state, and the pool skips it
  - if the pool would run empty, fall back to the existing gold/heal cards
  - the panel re-rolls that one slot after a banish
- **Input:** touch, mouse, keyboard (B then 1/2/3) and gamepad.
- **Co-op:** per player. It doesn't pause anyone.
- **Regression:**
  - the banished id never appears again that run
  - the count decrements and stops at 0
  - can't banish an owned item
  - the empty pool falls back safely
  - layout fits

## B7. Stage modifiers (switch `StageModifiers`)
- **What:** from stage 2, each stage rolls 1 modifier from a pool of at least 8, shown on the stage-start card (RunIntro) and as a HUD badge. Each one is a trade-off, for example:
  - "Swift foes: enemies +15% speed, +20% XP"
  - "Thick hides: enemies +20% HP, +25% gold"
  - "Glass arena: you deal +20% damage, take +20% damage"
  - "Gem rain: XP gems worth +30%, fewer chests"
  - "Elite night: +1 elite per wave, elites drop +1 chest roll"
  - "Calm: -15% enemies, -15% XP"
  - "Bounty: kill gold x1.5, enemy damage +10%"
  - "Haste: you +10% speed, cooldowns +10%"
- **Rolls:** deterministic from the run seed. Daily and Weekly runs use their fixed seed, so everyone gets the same ones.
- **Implementation:** server-side through existing multipliers (RunModifiers/curses pattern), cleared at stage end. No stacking with an identical curse effect beyond a cap.
- **Balance:** econ-sim, 3 seeds, average across modifiers. No single modifier may push would-be deaths up more than about 20% or gold more than about 25%. Tune the numbers until that holds. Record it in docs/next/STAGE_MODIFIERS.md.
- **Regression:** deterministic roll, effects applied and cleared, shown on the card and badge, layout fits.

## B8. Party quick lines (switch `PartyQuickLines`)
- **On the Party screen and the lobby (when in a party):** a row of quick-line buttons: "Ready?", "Go!", "GG", "One more?", "Wait for me", "Thanks!".
- **Where they show:** as a short bubble over the sender's lobby hero and in a small party feed on the Party screen.
- **Text:** fixed text only, with no free typing, so no filtering is needed.
- **Server:** rate limit of 1 per 2 s and 10 per minute; only sent to the sender's party members.
- **Regression:** party-only delivery, the rate limit, the bubble fades, layout fits.

## B9. Revive thank-you (switch `ReviveThanks`)
- **After being revived by a teammate:** a "THANKS!" button shows for 6 s near the HUD, away from JUMP and ULT. Tapping it:
  - sends the reviver a "<name> says thanks!" notice
  - gives the reviver +25 run XP (`Config.Revive.ThanksXP`)
- **Limits:** once per revive and at most 3 per run per pair, server-checked. You can't thank yourself, and it doesn't work in solo.
- **Regression:** XP granted once, the limits hold, the button hides after 6 s or after use, layout fits.

## B10. Damage number options (switch `DamageNumberOptions`)
- **Check first:** see what damage-number settings already exist (Settings / ClientSettings / CombatFx). Keep the existing Settings screen design; only add rows in its existing style.
- **Setting "Damage numbers":** Off / Small / Normal / Big. Default Normal, which is the current look.
- **Setting "Combine numbers":** on/off. When on, hits on the same enemy within 0.3 s merge into one rising number.
- **Crits:** always show in a different colour and shape (bold with a star), even when Small.
- **Persistence:** saved through the existing settings path.
- **Performance:** Off and Combine must lower the count of number labels. Check with perf-sim.
- **Regression:** each option changes the size or count, the setting persists, crits stay distinct, settings layout fits.

## Updated order for batch B
Do 1 (affix icons), B5, B6, B10, then 6 (Final Stand), B7, then B8, B9, then 12 (Prestige), then 18 (Quick resume).

Before shipping, ask the owner to approve:
- the stage modifier numbers
- the thank-you XP
- Final Stand
- Prestige
