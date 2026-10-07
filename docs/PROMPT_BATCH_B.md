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
