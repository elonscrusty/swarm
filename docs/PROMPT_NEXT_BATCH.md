# SWARM next batch: 9 improvements (owner request, 2026-10-07)

Paste everything below the line into the new chat.

---

Read docs/HANDOFF.md and CLAUDE.md first. Build these 9 improvements in the existing SWARM project, on `main`. The CLAUDE.md rules still apply:
- Never pay-to-win.
- Don't create products, invent prices or publish.
- Don't wipe saves or leaderboards.
- Use Roblox text filtering for any player text.
- Never present a mock as working; report PASS/FAIL/BLOCKED.

General requirements for every item:
- Give each item its own `Config.Features` switch (on by default). With the switch off, the game behaves exactly as now.
- Save fields are additive with defaults; no schema bump unless required. Old saves must load unchanged.
- All grants, rewards and timers are server-side, exactly-once and DEV-taint aware.
- New screens are their own client modules. UIBuilder.lua is at the 200-local limit.
- Every new screen must fit the owner's phone: iphone at Roblox Text size Largest (the preview default), plus phone-portrait and pc, with check_layout at 0 problems. Use TextFit/shrink-to-fit. Respect UIState (one panel at a time; HUD pieces hide when a panel covers them).
- Add a regression scene per item and register it in tools/run_regressions.py.
- Write one short doc per item in docs/next/.
- Run only one lune process at a time; the machine has 4 cores.
- At the end: full `tools/run_regressions.py`, `bash tools/check.sh`, rebuild `build/Swarm.rbxlx`, push to main, and send the file plus side-by-side renders.

## 1. Smarter first-run tutorial (switch `SmartTutorial`)
- **Who sees it:** only players on their first 2 runs. Track this with a save field `TutorialStep` (number) plus `TutorialDone` (bool). Never show it again once done. Add a "Replay tutorial" toggle in Settings, as a function only; don't redesign Settings.
- **Show one tip at a time, only when it's needed:**
  1. "Drag the left side to move" (phone) or "WASD to move" (pc): at run start, until the hero has moved 10 studs.
  2. "Your weapon attacks by itself": after the first kill.
  3. "Pick up the blue gems for XP": when the first gem drops near the hero.
  4. "Choose an upgrade": on the first level-up. Point at the cards; don't block the choice.
  5. "Hold E / hold the button to open chests": when the hero is within 12 studs of the first chest.
  6. "Find and charge the portal": when the portal appears. Point the existing portal arrow.
  7. "Bosses guard the way out": on the first boss arrival.
- **Look:** a small speech-bubble card near the bottom centre, above the tray, with an arrow pointing at the thing. It fades after the action is done or after 8 s. At most one tip on screen.
- **Input prompts:** use InputPrompts.lua for keyboard, touch and gamepad wording.
- **Replace, don't duplicate:** remove or merge the old Tutorial.lua tips that duplicate these, so there's no double tip.
- **Regression:** steps advance on the right events, are never shown twice, are skipped when done, and are hidden behind panels.

## 2. Off-screen danger arrows (switch `DangerArrows`)
- **Arrows:** when a boss, mini-boss (champion) or elite is off-screen, or more than 60 studs away, show an arrow at the screen edge pointing at it.
  - Boss: red skull arrow.
  - Elite: crimson ring arrow.
  - Champion: gold crown arrow.
- **Distance:** a small number in metres, using the existing "m" units.
- **Limits:** at most 4 arrows, nearest first. Arrows fade in under 0.2 s and never overlap the HUD or minimap; keep them inside the safe area.
- **Shape cue:** the arrow shape differs per type as well as the colour, for colour-blind players. The reduced effects setting turns off the pulse but keeps the arrow.
- **Performance:** client-only, updated at about 10 Hz, not every frame. No new remotes; read the existing enemy replication or attributes.
- **Regression:** the arrow appears for an off-screen elite, hides on-screen, caps at 4, and stays clear of the HUD on iphone and phone-portrait.

## 6. Shorter early game (switch `FastStart`)
- **Goal:** the first 3 waves of stage 1 feel faster, without making stage 1 harder.
  - Waves 1-3 last about 30% less time: shorten their timer in `Config.Waves`.
  - Enemies spawn in slightly bigger groups, so XP per minute in the first 90 s goes up by about 25%.
  - The first level-up should come at about 20-30 s; measure the current time first.
- **Measure before and after with the econ-sim** (see docs/overhaul/BALANCE_TUNE.md for the method):
  - first level-up time
  - level at 2:00
  - damage taken on stage 1
  - stage 1 clear time
  - would-be deaths
- **Constraints:** stage 1 must not get more deadly (would-be deaths unchanged), and stages 2+ must be unchanged. Record everything in docs/next/FAST_START.md.

## 11. Daily quests (switch `DailyQuests`)
- **What:** 3 quests per UTC day, picked from a pool of at least 15 by a deterministic day seed, so every player gets the same 3. Pool examples:
  - kill 500 enemies
  - win a run with the Mage
  - open 5 chests
  - reach stage 3
  - survive 10 minutes in one run
  - defeat a boss
  - level a weapon to 8
  - play a Duo run
  - use your ultimate 5 times
  - collect 2,000 gold in runs
  - break a secret room
  - finish a Shrine of Trial
  - rescue the villager
  - play the daily challenge
  - pick up 300 XP gems
- **Progress:** counted on the server from real run events, across runs that day. DEV/DevBoosted-tainted runs don't count.
- **Rewards:** gold only, at the existing economy scale; propose amounts and the owner approves before shipping (suggest 300 / 300 / 600). A bonus for all 3 is a free cosmetic from CosmeticData (earned).
- **Claims:** claimed with a CLAIM button; exactly-once per quest per day, server-checked.
- **Where:**
  - a QUESTS row on the MORE screen with a notice dot
  - a small "Quests 1/3" chip on the home screen, placed so it doesn't collide with TOP SCORES
  - progress toasts in runs, at most 1 per 20 s, through the UIState notice lane
- **Save:** `DailyQuests = { Day = n, Progress = {...}, Claimed = {...} }`. It resets on a new UTC day.
- **Regression:** deterministic pick, counting, exactly-once claim, day rollover, taint ignored.

## 12. Comeback gift (switch `ComebackGift`)
- **Trigger:** when a player joins after 3 or more days away (save field `LastSeen`, set on leave), give a one-time "Welcome back!" card on the lobby.
  - 3-6 days away: gold.
  - 7+ days away: gold plus a free cosmetic.
  - Propose the amounts; the owner approves.
- **Rules:** server-side, at most once per 72 h, never on a brand-new account. It must not stack with the login streak in a confusing way: show them as two separate cards, comeback first.
- **Regression:** fires at 3+ days, not at 2, once only, not for new players.

## 15. Invite rewards (switch `InviteRewards`)
- **Invite:** an INVITE FRIENDS button on the Party screen and the MORE screen, using `SocialService:PromptGameInvite`. Check `CanSendGameInviteAsync` first.
- **Detecting a real referral:** use `Player:GetJoinData().ReferredByPlayerId` (set by Roblox, not client-spoofable). Don't trust TeleportData/LaunchData for rewards.
- **Rewards (cosmetic only):**
  - When a new player (first join ever) arrives referred by an existing player, the new player gets a "Friend Badge" nameplate cosmetic.
  - The inviter gets the "Recruiter" title, plus 1 point toward a "Recruiter" trail at 3 referrals.
  - Store the inviter's credit in their save. Credit is granted when the inviter is online, or on their next join through a pending record in the referred player's save, processed by the inviter's server. Keep it exactly-once and capped at 1 credit per new player.
- **Anti-abuse:** credit only for accounts that are new to SWARM (no previous save) and that finished at least 1 run.
- **BLOCKED offline:** real invites need Studio or a live server. Mock it and mark that BLOCKED.

## 17. Roblox group bonus (switch `GroupBonus`)
- The owner must give the group id; put it in `Config.Group.Id`, which is 0 (off) until then.
- **The bonus:** group members get +10% gold from runs, capped at +500 per run, plus a "Group Member" title and a nameplate star.
  - Server check: `Player:IsInGroup(id)`, cached per session.
  - The bonus is shown in the results gold ledger as its own line.
  - It must not stack with the gold passes in a way that breaks the chest-price rule: run prices use GoldMult, so apply the group bonus only to lobby payout at settlement, not to in-run chest gold.
- **Lobby:** a JOIN OUR GROUP card on MORE that explains the bonus. Roblox has no in-game group join prompt for this, so show the group name and say "find us on Roblox".
- **Regression:** member vs non-member payout, the cap, id 0 = off.

## 18. Starter bundle (switch `StarterBundle`)
- **What:** a developer product, `Config.Monetization.StarterBundle`, with Id 0 = hidden. The owner creates it and sets the price. Contents:
  - a new exclusive "Pioneer" skin for the Knight (needs a new skin entry in CharacterData and SkinPasses-style ownership, granted by the product)
  - 2,000 gold
  - the "Pioneer" title
  - Cosmetic + gold only.
- **One per account:** the server checks a save flag `StarterBundleOwned`, and the store hides it after purchase. Receipts are idempotent (the existing PurchaseId pattern).
- **Shown to new players only:** a "Starter Bundle" card on the home screen for their first 7 days (save field `FirstJoin`). It sits next to the other cards without covering PLAY, the hero or TOP SCORES. It also appears in the Store's top section. The price comes from GetProductInfo only.
- **Regression:** mock purchase grants everything once, a duplicate receipt is ignored, the card hides after purchase and after 7 days, id 0 = hidden.
- **Owner steps:** add them to docs/features/STORE.md.

## 20. Better bug reports (switch `BugReportPlus`)
- **Limitation:** a Roblox game can't receive or upload a player's screenshot, since there's no external backend. So instead of a picture, attach an automatic snapshot to the existing filtered bug report:
  - current screen / panel (UIState)
  - stage, wave and arena
  - hero and build (weapons and passives with levels)
  - device type, screen size, Roblox text size setting and input type
  - FPS average
  - the last 10 client warnings or errors (from LogService, trimmed to 200 characters each, no player text)
  - the place version (game.PlaceVersion)
- **Player text:** still goes through Roblox text filtering. The snapshot contains no free text from players.
- **Storage:** reports are stored where they already are (check the current bug report path). Rate limit: 3 per player per hour.
- **Dev viewer:** a DEV-only viewer (allowlist, server-enforced) in the DEV panel to read the latest 20 reports with their snapshots.
- **Regression:** the snapshot fields are present, no player text goes unfiltered, the rate limit holds, and non-dev players can't read reports.

## Order of work
Do 1, 2, 6, then 11, 12, then 18, 17, 15, then 20.

Before shipping, ask the owner to approve:
- the gold amounts for 11 and 12
- the group id for 17
- that the Pioneer skin for 18 is OK

Report PASS/FAIL/BLOCKED per item. BLOCKED items: real invites (15), real purchases (18), group membership (17), and anything that needs Studio or a phone.
