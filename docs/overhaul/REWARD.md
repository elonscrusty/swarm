# REWARD: compact rewards, contained reveal, exact-once grant

Approved screen: 05_Compact_Reward.png. Issue: TS-02 (docs/overhaul/ISSUE_REGISTER.md).
Lead decision: the compact card replaces the older "every chest plays the reel" behaviour.

Side by side (approved 05 on the left, our pc render on the right):
`scratchpad/wf/reward/side-by-side-05.png`
(scratchpad = /tmp/claude-0/-home-user-swarm/587c5e35-da3e-5580-abb3-5cc8b9f0c56b/scratchpad).
Renders: `scratchpad/wf/reward/r/reward-card-{pc,iphone,phone-portrait}.png`, rare reveal
`scratchpad/wf/reward/r/rare/reward-card-iphone.png`.

## Behaviour
- Common rewards (a Small or Large chest's common/uncommon item, a shrine item, a one-level
  elite chest): a compact side card "SMALL CHEST · REWARD", medallion, name, rarity, effect
  and a draining "AUTO-ADDED · 3s" bar. No reel, no dimmer, no confirmation, not a UIState
  primary, world input stays on, so the next chest can be opened. Repeats of the same item
  from the same source merge ("x2"); others queue and show faster. The x closes it early.
- Rare rewards (Legendary item, Golden Chest, guarded altar / rune stones, multi-level elite
  chest or evolution) in a solo run: the short contained reveal (reel panel, capped by
  `Config.Chests.RewardPauseMax`, tap to skip). In a live duo/trio run they are a rare card;
  the server never holds a group run for a reward (`RunManager.HoldReward`).
- Recent-rewards history: the last 8 rewards (`LootUI.RecordReward` / `RecentRewards`),
  shown at the top of the ITEMS list; cleared when the run ends.
- Paid-chest disclosure before the hold (unchanged prices and odds): real chest name,
  "Costs N run gold · hold to open", and the odds line from `Config.Chests.Weights`
  ("1 item (80% common, 19% uncommon, 1% legendary before luck)").
- Prompt icon by tier: Small/Treasure `chest`, Large `reward_ChestLarge`, Golden
  `reward_ChestGolden` (LootUI `CHEST_ICON`).
- Bargain HUD chip: "BARGAIN  +25% DMG BONUS  +30% GOLD" (numbers from `Config.Shrines`).
  The enemy HP tradeoff stays on the shrine prompt before sealing.

## Exact-once grant (TS-02)
The server grants in `LootSystem` at hold completion, before any presentation; the client
card/reveal is display only and `RewardClose` only ends a pause (sequence-checked).
`tools/preview/scenes/reward-once-regression.luau` (real server + client) counts every
`ItemSystem.Grant`: common chest, spammed holds on an opened chest, rare reveal skipped at
once, junk/stale/huge `RewardClose` values, hero going down after a reveal, leaving the run
with a card up. Result: 29/29 PASS, 3 grants for 3 chests, 3 deliveries. The scene runs at
10 simulated fps (about 235 s real on a loaded machine; the runner allows 360 s).

## Tests (offline only, NOT Studio, NOT live multiplayer)
- check.sh --quick: PASS.
- reward-regression: PASS (fixed: it now skips the Golden Chest, which is always rare).
- reward-once-regression: PASS 29/29.
- chest-gold-sim: PASS.
- ui_regression phone and phone-portrait: PASS ("ordinary chest shows the non-blocking
  compact card, never the reel or its dimmer"; "rare chest opens established dramatic reel").
- uistate_regression: PASS.
- reward-card renders pc / iphone / phone-portrait + rare iphone: check_layout 0 problems.

## Remaining risk
- Studio, real touch input and duo/trio live behaviour are not verified.
- reward-once-regression is slow in the mock; on a busy machine it could hit the 360 s
  runner timeout.
