# Owner prompt: Studio recording review (2026-10-09), saved verbatim in substance

Continue the existing Roblox SWARM project and finish the integration, usability, and presentation problems below. Preserve completed work and functioning systems. Inspect the actual current source before selecting files, diagnosing causes, or changing architecture. Do not blindly replace systems because of how a video looks.
Based on a 2:29 Studio recording reviewed through sampled frames (no continuous playback, no audio). Timestamps are video timestamps. The recording begins with a run already active. Treat visible contradictions as symptoms to investigate; aesthetic notes as design direction; unseen mechanics as verification work, not confirmed defects.

## Direction and preservation
Fast, satisfying third-person automatic combat inspired by Megabonk; movement, jumping, dodging, exploration, build choices. One cohesive forest-and-cliff theme (huge cliffs, grassy clearings, chunky trees, caves, broad paths, bridges, stone ruins) — improve the existing map. Approved roster: Ruckus, Toastmaster, Captain Croak, Granny Boom, Coach Crunch, Doug the Janitor, Peter Parkour, Barry Plotter, Rambozo, Swolverine, Crash Cassidy, Knuckles McGee.
Core flow: shared social lobby → inspect/select class → party or solo → queue → readiness/countdown → loading → gameplay as the selected character → progression/boss → results → replay or lobby.
Preserve: saved progress, purchased ownership, configured products, existing benefits; class identities, equipment, progression, numeric upgrade comparisons; campfire hub, physical gates, chunky characters, forest/cliff map, working queue countdown; the working Ruckus queue-to-character spawn path; honest saving status (the Studio session had saving disabled — not evidence production saving is broken). Don't reset data, fabricate ownership, repurpose product ids, change prices, or remove benefits.

## 1. Lifecycle and HUD init — SW-01, SW-23
Evidence: 00:00–00:43 the player is in the camp (class displays, queue gates) while survival timer, damage, kills, XP, upgrades and defeat operate. 00:50–01:00 another short run in the camp. Studio Output: "attempt to index nil with 'Size'" in a client HUD layout trace (predates the recording).
Inspect fresh join, Studio/direct-start shortcuts, replay, return to lobby, leave run, queue launch, spawn completion, defeat, cleanup; the failing HUD layout op; state ownership; duplicate transitions.
Fix: lobby safe for browsing/parties/queues; run enemies/damage/XP/objectives/defeat never operate in the social lobby; gameplay starts only after map, character, equipment and camera are ready; cleanup removes obsolete UI, participation, interactions, callbacks; repair the HUD error at its cause.
Accept: repeated fresh joins, replay, leave, defeat, queue cancel, return cycles stay coherent; lobby can't act as an arena; no recurrence of the HUD error on start, resize, transitions.

## 2. Character identity — SW-02, SW-10, SW-11, SW-12
Evidence: 00:00–00:47 controlled character is a small brown animal-like avatar while results identify Ruckus with a different portrait. 01:09–01:23 queue roster names Ruckus and the run uses the right model. 00:16–00:23 pedestals show names/roles/prices but don't distinguish preview/selection/ownership/locking. 00:18–00:21 run HUD overlaps class plaques. 00:48, 01:08–01:22 lobby identity card overlaps Roblox controls.
Inspect the initial fallback/avatar behaviour first; keep the working Ruckus path. Same identity across selection panel, lobby card, party roster, queue roster, controlled character, equipment, starting build, results. States: Preview (no select/purchase), Owned (select action), Selected (persistent marker), Locked (real requirement + action), Loading (pending, no wrong fallback), Error (explain, keep valid selection). Details explain real weapon behaviour, passive, movement trait, unlock requirement (existing data). Identity info inside screen insets; no plaque/HUD overlap.
Accept: every class survives selection, queue, spawn, replay, results with matching identity/equipment; locked previews don't select/purchase; name+portrait readable with Roblox controls present.

## 3. Queue and party presentation — SW-08
Evidence: 01:08–01:10 recruit text "up to 4" while empty gates show 0/3 and a one-player queue says room for 2 more. Countdown works.
Derive all capacity wording/counters from one config. States: open, joining, joined/not ready, ready, countdown, unready/cancelled, full, leaving, loading, load failure, transfer success. Explain public recruit vs party-only. State vs action ("Ready" state, "Unready" action). Countdown shows time; committed loading shows status and only working actions. Verify invites, membership, leader changes, disconnects, readiness before changing.
Accept: occupancy displays agree with capacity; unready/leave/disconnect never leave stuck membership/countdowns; load failure returns to a recoverable state; multi-client verified.

## 4. Bridge/cliff traversal and camera — SW-03
Evidence: ~01:43 cliff rock fills the view hiding player and ground; Output: player fell out of the arena and was put back on the floor.
Inspect terrain seams, bridge ends, rail collisions, nav surfaces, movement, camera obstruction, OOB recovery. Fix the actual cause. Valid walking/jumping across connections never falls through or triggers recovery; camera follows the selected rig and stays useful near cliffs/rails without abrupt snapping; deliberate falls recover at a safe spot with feedback and no loops.
Accept: both bridge directions, jumping at approaches, moving against rails, landing near edges, camera rotation against cliffs, deliberate falls.

## 5. Chest transactions — SW-04, SW-05
Evidence: 02:07–02:09 chest reward choice open while "Open chest · not enough gold" stays visible. One frame: 21 gold, CHEST 54, "54 gold · need 45 more" (wrong arithmetic).
States: available, unaffordable, opening/pending, choosing reward, claimed, failed. Show applicable cost and accurate affordability; shortfall from the same balance and price; suppress the stale prompt while opening/choosing; charge once, one reward; failure recoverable; distinguish future price from the completed purchase.
Accept: balances below/equal/above, rapid interaction, gold gained during approach, multiple chests, cancellation, delayed updates — no contradictions, duplicate charge/reward, or wrong shortfall.

## 6. Revive purchases — SW-07
Evidence: 00:43–00:44 Roblox test purchase dialog for Revive at 35 Robux; outcome unknown.
Keep ids/benefits. Before the native dialog, explain the real benefit (restored health, return location, build kept, eligibility, limits, price). States: eligible, unavailable, pending, cancelled, failed, fulfilled. Never imply success from button animation or dialog close.
Accept: cancel leaves the run unchanged; fulfilment once; pending/retry safe; no misleading sale when unavailable; tested separately from defeat/results.

## 7. Results and cleanup — SW-06, SW-22
Evidence: 00:39–00:47 gameplay reaches LV 2 but results say LEVEL REACHED 0. Junk Collector widget stays over purchase/results and the run menu. DEV prominent in runs.
Capture final run data before cleanup; show class, map, time, kills, level, damage, boss outcome, rewards, saving status. Label "levels gained" correctly if that's the meaning. Remove "Confirmed by the server" wording. Hide run-only widgets when irrelevant. Gate DEV controls. Keep honest saving status.
Accept: final values match; replay/return/auto-return can't race; no orphaned HUD over menus/purchases; ordinary players can't access DEV.

## 8. Lobby lighting and cohesive UI — SW-09, SW-21
Evidence: 00:48–00:49, 01:03–01:22 lobby almost black while portals bright. Dark gameplay panels vs bright white menu/queue/results panels. Results show castle scenery unrelated to the forest world.
Inspect environment state restoration before picking values. Keep the campfire. Readable terrain and silhouettes, warm campfire emphasis, controlled portal brightness, visible routes/signs, one SWARM interface language (palette, type hierarchy, spacing, borders, buttons, states). Keep functional layouts. Forest/cliff scenery for results.
Accept: fresh and returned lobby lighting readable; lobby, queue, run menu, build, upgrades, purchase, results look related; selected/focus/disabled/pending/error identifiable on all inputs.

## 9. HUD, build, reward clarity — SW-13 to SW-17
Evidence: unlabeled percentage crystal/rock meter; unexplained Junk Collector progress; compact gold/chest pricing; repeated MAP wording; prominent plus-sign empty slots; 00:39–00:41 Vortex card mainly shows damage/interval, not behaviour; 00:31–00:33, 02:18–02:19 inventory covers central gameplay while saying combat continues; inventory says EVOLUTIONS 1 while the recipe is 0/3 with unmet requirements.
Implement: name and explain the meter; Junk Collector condition + benefit; separate currency balance and chest price; explicit map-button action; labelled weapon/passive groups, readable ranks, subdued empty slots; short behaviour sentences on cards keeping before/after numbers and rarity/rank rules; inventory layout and input that match its real (non-)pause behaviour; distinct recipe available / requirements met / acquired states. Menus: hover, controller focus, touch, pending/disabled, confirmation, error recovery; timed choices show their timeout; no false shared-game pause.
Accept: every meter understandable; offered benefits match applied values; starting builds don't imply an evolution; menu input doesn't move character/camera; world visibility kept if combat continues.

## 10. Movement, animation, combat readability — SW-18 (investigation)
Evidence: red ground danger markers partly behind the equipment HUD or near the player ground ring at 01:42–01:43, 02:04, 02:06, 02:28–02:29.
Measure before tuning. Movement/stop/turn/jump/air/landing/dash support fast combat; animation follows state without sliding/snapping/floating/broken attachments; auto attacks show origin, direction, target, area; effects/hits/numbers/sound match timing without hiding threats; warnings match damage areas with avoidance time; player ring can't be mistaken for danger; camera framing leaves enough ground visible below. Preserve targeting/attack systems; test ricochets, range, walls before diagnosing.

## 11. Map route and opening progression — SW-19, SW-20
Evidence: forest entry ~01:23; first sampled kill ~01:45 (~22 s later); chest choice ~02:07; ~02:29 still LV 1 at 16/20 XP despite 13 kills and a chest passive; long straight bridges and repeated cliff slabs; clearings repeat isolated trees, columns, banners, rocks, chests; yellow pads unexplained.
Inspect routes, enemy placement, spawning, XP drops/collection, chest costs, progression, yellow-pad purpose. Layout: improve the starting clearing's immediate combat/collection; bridge approaches with room and visible destinations; ruin props in intentional clusters with combat space; distinct landmarks per clearing; loop/shortcut only after connectivity check; keep big cliffs but vary silhouettes/materials; label yellow pads; scenery out of camera/threat sightlines. Progression: measure first engagement, kill, XP collected, choice, build change, escalation across routes/classes; set justified targets; fix source defects; tune encounter/reward placement before economy/XP thresholds.

## 12. Verify unseen systems, then integrate
Not shown: all-class selection/animation, parties/invites, multiplayer queues, cancel/failure paths, production saving, purchased ownership, receipt security, full progression, caves/alternates, boss intro/attacks/completion, co-op downing/revival, full results/rewards, mobile, controller, audio, performance. Test them; don't label broken without evidence; no speculative features.
Validation: existing automated tests for changed lifecycle/data/transaction/calculation; multi-client lobby/party/queue; continuous movement/camera/combat play; chest and revive state/fulfilment; safe persistence/ownership checks in an authorized environment; desktop/mobile/controller layout and input; one complete run through boss or defeat, results, return/replay; final integration of both chats' work.

## Final report
Implemented (changes, systems, issue ids) / Verified (tests and playtests with concrete results) / Remaining (unresolved, unestablished causes, untested devices/flows, blocked). Separate fixes from verified results. No claims about classes, purchases, saving, performance or balance without tests. Include shared-interface handoff and final integration status.
