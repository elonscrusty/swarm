# Roblox group bonus (switch `GroupBonus`)

## What
Members of the game's Roblox group get:
- +10 % gold from runs, at most +500 per run,
- the "Group Member" title,
- a star before their name on the name plate.

Server (`src/server/Modules/GroupBonus.lua`):
- Membership is checked with `Player:IsInGroupAsync(Config.Group.Id)`, once per session in the
  background. A failing lookup is retried twice, then counts as "not a member" for that
  session.
- The bonus is paid only at settlement (`GoldSystem.SettleRun`). It is 10 % of what the run
  paid into the lobby (kept purse + survival gold) and goes straight into the save.
- In-run gold, chest and shrine prices never change, because they follow GoldMult (passes
  only). So the chest-price rule holds.
- Never for a DEV-tainted run or a DEV-boosted profile. Paid once per run.
- `RunResult.GoldGroup` carries it. The results ledger's note shows "+ N group bonus", and
  RUN DETAILS has its own "Group bonus" line.
- Title: granted into `Titles.Owned` while a member. A later session that finds the player
  left the group takes it away (and clears it if worn). The gold already paid stays.
- The plate star: player attribute `GroupMember`, drawn by client TitlePlates.

Client: MORE > JOIN OUR GROUP (`MenuGroup.lua`). The row shows only with the switch on and a
group id. The screen names the group (GroupService), explains the bonus, and says "find us on
Roblox". There is no in-game join prompt.

No save fields (the title lives in the existing `Titles.Owned`).

## Config
- `Config.Features.GroupBonus = true`
- `Config.Group = { Id = 0, GoldBonus = 0.10, GoldCap = 500, Title = "Title_Group Member" }`.
  Id 0 = off.

## Owner steps
1. Send the group id (the number in the group's web address) and approve the bonus numbers.
2. Paste it into `Config.Group.Id`, rebuild and publish.
3. Test in Studio: join with an account in the group. The plate shows the star and TITLES
   lists "Group Member". Finish a run: the results note shows "+ N group bonus".

## PASS / BLOCKED
- Offline: `group-bonus-regression`.
  - id 0 = off.
  - Member +10 % vs non-member 0, with one cached lookup per session.
  - The +500 cap, paid once per run, never for a DEV-tainted run.
  - In-run prices unchanged.
  - Title and star follow membership, and leaving takes the title away.
  - A failing lookup counts as not a member, and the switch off pays nothing.
- Layout: `social` scene, `screen=Group|More`.
- BLOCKED: real group membership (needs the owner's group id and a Studio / live server).
