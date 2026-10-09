# Final fix-up list (collected from stream reports; the last integration pass works through it)

- **MenuUpgrades.shopCard:** copy `MenuStore.priceState` (disabled while the price loads; PRICE UNAVAILABLE).
  It is the screen that sells the live gold packs and Revive.
- **UIBuilder revive overlay (~4620):** add a fallback when the price lookup fails.
- **Characters screen:** "GET SKIN" has no Robux price shown, or should be hidden for id-0 passes.
- **ClassService.Buy / SaveSettings:** use `DataService.IsReady`, not `GetData`. Changes during a teleport
  handoff stay in memory and are never saved.
- **Failing regressions** (found by L2 and B):
  - data-regression
  - heroes-regression: "in Order: Archer". Old heroes are now hidden by design, so update the test.
  - coop-regression: "kill records emitted drops". XP drops are personal shards now (E2).
  - layout store gift ids
- **Owner decision:** the Revive prompt opens automatically on elimination with a 12 s countdown (existing
  behaviour, C8). The brief wants a deliberate button. Proposal: open it only when the player taps REVIVE.
- **Owner decision:** the class bonus changes. Stream C removed the first four classes' old innate
  bonuses, and Granny's boost fire trail.
- **layout-results-iphone / -phone-portrait:** REPORT A BUG is cut off, PHOTO is off screen, and the
  "7,700 / 10,000 gold" line overflows. This also happens on the base branch (found by F).
- **Portrait:** stacked level-up cards can overlap the top of JUMP slightly (F).
- **Results:** the server sends no Outcome / Duration / Stats fields. The UI derives them from Won /
  Abandoned and ClassGoals; the brief wants server-confirmed outcome, duration and stats (F).
- **Walkthrough / tutorial texts:** still mention the portal (H1 is on it).
