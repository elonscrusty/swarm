# SWARM handoff (2026-10-07)

Paste this into a new chat. CLAUDE.md, which loads automatically, has the full history and the rules.

## Current state
- `main` is at the "Home screen TOP SCORES panel" commit, and `build/Swarm.rbxlx` was built from it and sent to the owner.
- The work branch `claude/relaxed-shannon-t6qo8p` is the same as `main`.
- Everything is offline-tested only (Lune preview). Nothing has been verified in Studio, on a phone or in a live server.
- Last full regression run: 145/151. The 6 layout fails were fixed and rechecked one at a time. home-board-regression was added after that run.
- Toolchain: `/tmp/sh-tools` (lune, rojo, luau-lsp). If it's missing in a new container, install it per docs/PREVIEW.md.
- Run only one lune process at a time: the machine has 4 cores and has run out of memory before.

## Done recently (details in docs/)
- **Overhaul:** docs/overhaul/.
- **Full audit:** docs/audit/AUDIT_REPORT.md.
- **30 features + cosmetic Robux store:** docs/features/STATUS.md and STORE.md. Every feature has a `Config.Features` switch. All are on except `Announcer` (the combo counter), which the owner had switched off because it blocked the screen.
- **Phone layout:**
  - Cause: Roblox Text size Largest, about 1.6x, plus the iPhone top-bar inset.
  - Fixes: TextFit.lua, the computeInsets fix, and preview `--set textsize=`.
  - Screens fixed: home, play, characters, run menu, level-up. Write-up: docs/MOBILE_FIX.md.
  - The owner's phone screenshots were in the old scratchpad and are now lost. Ask for new ones if needed.
- **Home TOP SCORES panel:** src/client/HomeBoard.lua.

## Open, in priority order
1. **Phone check of the remaining menus** at Largest text: Shop, Store, Stats, Ranks, Journal, Sigils, Weekly, Season, Titles, Collection, Streak, Settings. The settings fix is functional only; the owner rejected a redesign.
2. **In-run:**
   - The WEAPONS/PASSIVES tray labels are small or cut.
   - In portrait, the minimap covers the downed hero's "REVIVING" label.
3. **Audit leftovers:**
   - MATH-15: damage dealt counts overkill.
   - MATH-17: Windstep can exceed its speed cap.
   - The dev "Next stage" command leaves a live boss.
4. A full regression run plus perf-sim with all features on.
5. **Owner decisions pending:**
   - Tune the Horde and Elite Surge curses? They get easier after stage 2 because of the extra gold.
   - Combo counter: back on as a small corner number?
   - Weekly runs give mastery XP to the lent hero.

## Owner to-do (not Claude)
- Studio playtest on the phone.
- Create the 31 store items in Creator Dashboard, set the prices and send the ids (docs/features/STORE.md).
- Icons and portraits for new content (docs/IMAGE_PROMPTS_UPDATE.md, 87 images).
- Licensed music.
