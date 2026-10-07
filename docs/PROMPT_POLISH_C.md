# SWARM batch C: 30 polish items (owner request, 2026-10-07)

Paste everything below the line into a chat, after batch B is done.

---

Read docs/HANDOFF.md and CLAUDE.md first. This is a POLISH batch for SWARM on `main`: no new systems, and no balance or price changes. CLAUDE.md rules apply; report PASS/FAIL/BLOCKED.

General requirements:
- **Check before building.** Many of these partly exist already: CombatFx, HitFeel, UIAnim, Hud low-HP vignette, the heartbeat SFX, Audio pitch variation, results gold ledger, reward cards, NoticeDots, TextFit, the existing hit flash in EnemyRenderer, the existing minimap/portal arrow. For each item, first write down what exists, then improve it. Never duplicate a system.
- Add a switch in `Config.Polish` for any item with an on/off look, so it can be undone. The Settings screen design stays the same; new options only as rows in its existing style.
- Respect accessibility settings everywhere: reduced effects, reduced flashes, screen shake %, visual sound cues. Every new shake, flash or pulse must scale down or off with them.
- Phones first: iphone at Roblox Text size Largest (the preview default), phone-portrait and pc, with check_layout at 0. UIBuilder.lua is at the 200-local limit, so put new code in its own modules.
- Performance: no new per-frame work per enemy. Pool effect parts. Measure with perf-sim at 300 enemies before and after; the client ms must not rise by more than 5%.
- Add or extend a regression per area, register it in tools/run_regressions.py, and write one doc, docs/next/POLISH_C.md, with before/after renders per item.
- Run one lune process at a time.
- At the end: full regressions, `bash tools/check.sh`, rebuild `build/Swarm.rbxlx`, push to main, and send the file plus a few side-by-side renders.

## Combat feel
1. **Hit feedback on every hit.** Every enemy hit gets:
   - a quick white flash: 0.06 s, at the existing partial-brighten strength
   - a tiny knockback nudge: at most 0.3 studs, server-authoritative or a visual-only offset, but never desyncing position
   Big hits keep their stronger reaction. Cap the visible flashes to 40 per frame, nearest first.
2. **Hit sound variety:** random pitch ±8% and 3 alternating variants of the hit SFX. Respect the existing MinGap and voice caps in Audio.lua, so it's never louder overall.
3. **XP gem pickup sparkle:** a tiny pooled spark (3-4 parts, 0.2 s) when a gem reaches the hero. At most 6 sparkles per 0.1 s.
4. **Level-up flash:** a 0.4 s gold ring that expands from the hero, plus a soft chime, on the level-up event before the cards open. Reduced flashes keeps the ring but no bright flash.
5. **Boss health bar phases:** the boss bar shows its phase thresholds as small notches. When a phase breaks, the segment cracks: a 0.3 s crack graphic plus a shake of the bar only, not the camera.
6. **Tune hit-stop and shake:**
   - hit-stop at most 40 ms, at most 2 per second (HitFeel)
   - camera shake: small hit 0.15, big hit 0.35, boss slam 0.6 (relative units), all times the screen shake % setting
   - no shake at all during menus or panels
   Write the final numbers in Config.Polish.

## Clarity
7. **One danger language:** every enemy attack telegraph uses the same style:
   - a red outline ring or line with a filled area that grows until impact
   - the same red (one Theme colour), the same 0.6-1.2 s fill rule
   Audit all telegraphs (BossAI, hazards, meteors, lava, champion slams) and convert the odd ones out. Colour-blind safe: outline plus fill, not colour alone.
8. **Hero outline:**
   - your own hero gets a thin bright outline (a Highlight with OutlineTransparency about 0.2 and no fill), visible through crowds
   - teammates get a softer blue outline
   - Roblox allows few Highlights, so share one Highlight for the local hero and up to 3 for teammates; never one per enemy
9. **Pickup expiry warning:** pickups that despawn (gold, gems, items, if they do) blink for their last 3 s. If off-screen, they show a small edge glow toward them. Check the actual despawn rules first; skip types that never despawn.
10. **Low health:** below 25% HP, the screen edges pulse red at a 1 s rhythm and the heartbeat SFX plays. Below 10%, faster. Make sure this already-existing piece works on phones and respects reduced flashes (a steady tint instead of a pulse). Visual sound cues show a heart icon.
11. **Buff badges:** every active timed buff (Final Stand, gold rush, Rally Song, weather slow, cursed chest, shrines) shows in the FeatureHud badge row as an icon plus a short label plus a shrinking ring timer, for example "x2 GOLD 0:12". Never more than 3 visible on phones; the newest replaces the oldest. Buffs share one badge style.

## Menus
12. **One button style everywhere:** every button gets:
    - the same press feedback: scale 0.96 for 0.08 s and back
    - the same click sound
    - a hover brighten on pc
    - a disabled look at 50% alpha with no sound
    Apply it through one shared helper in UIKit, and convert all lobby and in-run buttons. A list of converted screens goes in the doc.
13. **Menu screen transition:** switching lobby screens slides the new screen in from the right (0.18 s, ease-out) and the old one out. BACK reverses the direction. Reduced effects gives a 0.1 s fade instead. Input is blocked during the transition, at most 0.2 s.
14. **Loading states:** every list that waits for data (leaderboards, home TOP SCORES, store prices, season, weekly, collection) shows a small spinner plus "Loading…" instead of empty boxes. After 8 s, it shows "Couldn't load. Tap to retry".
15. **Honest notice dots:** audit NoticeDots. A dot shows only when there's something new to claim or see, and clears when the screen is opened or the item is claimed. List every dot source in the doc. Add a regression: open, then the dot clears; nothing claimable means no dot.
16. **One type scale:** define Theme sizes (Title, Heading, Body, Label, Small; for example 34/24/18/15/13 at the pc base) and convert every screen to them, with no stray TextSize numbers. Check everything at Largest text on iphone with check_layout.
17. **BACK always in the same spot:** every lobby screen's BACK button sits at the same position (top-left under the Roblox top bar, using computeInsets), with the same size and look. Gamepad B and Escape do the same.

## Results and rewards
18. **Gold count-up:** results gold numbers count up from 0 over 0.8 s with a soft tick sound, at most 12 ticks per second. Tapping skips to the final value. Reduced effects shows the final value instantly.
19. **New record flash:** when a run beats the personal best time, kills, score or stage, show "NEW BEST TIME" (etc.) badges that pop in on the results screen once each. These are based on saved bests; add the save fields if missing.
20. **Show what changed on reward cards:** every reward card and the level-up card show the change, for example "Sword Lv 3 → 4", "Max HP 120 → 140", "Gold +250". If a card already does this, make all cards match.

## World
21. **More ground detail:** add small pooled decorations per world (flowers, pebbles, puddles, mushrooms, snow tufts, embers) using GroundDetail.lua. Keep under 120 extra parts per arena, never on paths, hazards or encounter spots. Measure part counts before/after (docs/PERFORMANCE.md table).
22. **Soft arena edges:** a fog band or atmosphere gradient at the arena border instead of a hard visual edge, plus a darker ground falloff. Collision is unchanged.
23. **Ambient sound per world:** one quiet looping ambience per world (forest birds, ruins wind, swamp frogs, snow wind, desert breeze, lava bubbling). Use existing sound ids only, or synth new ones with tools/synth_sfx.py. Owner music is unaffected. An "Ambience" volume row in Settings, using the existing style.
24. **Portal proximity glow:** the portal glow and beam get stronger as the hero gets closer (within 40 studs), and the existing arrow pulses when within 20 studs.

## Phone
25. **Bigger tap areas:** every button smaller than 44×44 pt gets an invisible hit area of at least 44×44 pt without changing its look. Overlapping hit areas are not allowed; check with a layout rule.
26. **Floating joystick:** the joystick appears where the thumb first touches in the left 40% of the screen, and follows if the thumb drags past its edge. It respects the existing touch layout options (left-handed etc.). Add a setting "Joystick: Fixed / Floating", default Floating.
27. **Minimum text size:** no text renders below 12 pt on phones, including at Small. Add a check_layout rule that flags any text under 12 pt on phone devices, then fix every hit.

## Performance and quality
28. **Effect budget under load:** when more than 200 enemies are on screen, scale down extra effects: fewer death-burst pieces, no gem sparkles, fewer hit flashes. Use one shared budget object read by CombatFx/HitFeel/VFX. Measure with perf-sim at 300 and 400 enemies.
29. **Faster first screen:** on join, show the lobby home as soon as the core UI is ready. Load pictures (ArtData/IconData) after, with their drawn fallbacks showing meanwhile; AssetPreload must not block the first screen. Measure time-to-home in the preview before/after.
30. **Friendly errors:** wrap screen builds and remote handlers on the client so an error shows "Something went wrong. Tap to retry" on that screen instead of a broken or blank screen, and the error goes into the bug-report snapshot. The server must also never send raw error text to players.

## Order
Do 12, 16, 17, 27, 25 (shared UI basics first), then 13, 14, 15, 18, 19, 20, then 8, 7, 10, 11, 9, then 1-6, then 21-24, then 26, then 28, 29, 30.

Report PASS/FAIL/BLOCKED per item. Studio-only checks (real touch feel, sound loudness, Highlight limits on device) are BLOCKED; give the owner a short checklist.
