# Funnel analytics (where new players quit)

SWARM sends a small set of Roblox analytics events so the Creator Dashboard can show where
brand-new players stop. Everything is sent by the server (`src/server/Modules/Analytics.lua`)
through Roblox's own `AnalyticsService`. There is no third-party service, no new saved data
and no change to gameplay, rewards or prices. Switch: `Config.Features.Analytics`.

## The onboarding funnel (Creator Dashboard: Analytics → Funnels)

| Step | Name | Sent when |
|---|---|---|
| 1 | Joined Game | the player's save finished loading on a lobby server |
| 2 | Ready to Play | the player's game reports that the loading picture is gone and the lobby menu is showing with their profile (or they are already in a run); the server checks the report before counting it |
| 3 | Started First Run | a run really started for the player (heroes placed, weapons given) and their save says they have never started a run before |

- Only accounts that have never started a run enter the funnel (save `Stats.Runs` is 0 when
  the save loads). Long-time players are left out, so they don't inflate step 1.
- Roblox keeps only the first time each step happens for a player, across every server and
  every visit. If step 1 or 2 is missed (for example, a failed call or a very fast trip to a
  run server), Roblox counts it as done once step 3 arrives.
- There are only three steps on purpose. After the first run starts, nothing else always
  happens in the same order, and an out-of-order step would mark earlier steps done.
- Step numbers and names must never change. The dashboard groups by them.

## Separate events (Creator Dashboard: Analytics, custom events)

| Event | Sent when | "First" means |
|---|---|---|
| First Evolution | a weapon evolves (a level-up card or a chest) and the save shows no evolution ever before | per account, across visits (save `Discovered.Evolutions`) |
| First Wave Completed | wave 1 of the account's first run is cleared (the game's own wave-clear rule) while the player is in the run and alive | per account: only the first run counts, read from `Stats.Runs` |
| Started Second Run | a run really starts and the save says it is the account's second | per account, across visits (`Stats.Runs` was 1) |

These are separate events, not funnel steps, because they are optional or can happen in a
different order. A wave that ends because its 30-second timer runs out is **not** counted as
completed. Runs that used DEV tools send no separate events.

If a player leaves their first run before clearing wave 1, "First Wave Completed" is never
sent for them, even if they clear a wave in a later run. That is on purpose: the event
measures whether new players get through the first wave of their first run.

## Safety rules the code keeps

- Server only. Roblox ignores analytics sent from a player's device or from Studio. In Studio
  nothing is sent at all; the module only keeps a short local list for the offline checks.
- Every `AnalyticsService` call is wrapped so an analytics error can never stop a save, a run
  or a reward. A failed call is logged as a warning and not retried.
- Each player sends each step or event at most once per server visit. The save rules above
  keep the separate events to about once per account. No new save fields were added.
- The ready report (remote `ClientReady`) takes no data. The server ignores anything sent with
  it and drops it unless the sender is a new player on this lobby server whose save has
  loaded and whose step 1 went out. Only the first accepted report counts, and the remote is
  rate limited to once per second.
- Run servers (the private servers runs play on) never send steps 1 or 2. Players there
  always came from a lobby first.

## Checking it works

### Already checked offline (no Studio, no live game)
- `tools/preview/scenes/analytics-regression.luau` runs the real server against a fake
  `AnalyticsService` as a published lobby (`--set mode=published`, no `--studio`) and checks
  all of the above: who gets step 1, ready-report validation (veteran, before the save loads,
  repeats, junk data), an analytics failure not blocking the save, step 3 and Started Second
  Run, wave-1 clear vs. timeout, chest and card evolutions once. With `--studio`, it checks that
  nothing reaches `AnalyticsService`.
- `tools/preview/scenes/analytics-client.luau` runs the real client: one ready report, sent only
  after the lobby menu shows the profile.
- Both are in `tools/run_regressions.py`.

### Only possible in the published game (owner steps)
Roblox does not take analytics from Studio, so the dashboard numbers can only be checked
after publishing.
1. Publish as usual. Nothing here publishes on its own.
2. Play with an account that has never played SWARM (a fresh alt account). Your main account
   has played runs, so it is not in the funnel.
3. On that account: join, wait for the menu, play the first run, clear wave 1, evolve a weapon
   if you can, then start a second run.
4. Wait up to a day. Roblox gathers analytics daily, so charts can take up to 24 hours.
5. Creator Dashboard → your experience → **Analytics → Funnels**: the onboarding funnel shows
   Joined Game → Ready to Play → Started First Run with the share of players who reach each step.
6. Creator Dashboard → your experience → **Analytics**, the custom events view (Roblox's docs
   call it the Explore page): look for First Evolution, First Wave Completed and Started
   Second Run. Event counts are numbers of players, since each account sends each event about
   once.

The dashboard menu names come from Roblox's documentation and may be labelled slightly
differently. They have not been checked against the live dashboard.
