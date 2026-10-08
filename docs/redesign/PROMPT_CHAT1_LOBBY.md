# Prompt for the second chat (Chat 1: lobby track)

Paste the short message at the bottom into a new Claude Code chat on the `elonscrusty/swarm` repo.
Everything else that chat needs is in the repo.

---

## What the chat must read first (in order)

1. `CLAUDE.md`: project rules. They all apply, with **one exception**: do NOT push to `main`. Push only
   to this chat's own session branch.
2. `docs/redesign/reference/Swarm-Claude-Chat-1-Lobby.md`: **your full brief**. Follow it.
3. `docs/redesign/OWNERSHIP.md`: the files you may edit, and the contract additions (local
   role, `RunEntry.BeginLocalMatch`, remote folders, avatar spawning). It overrides the brief where they differ.
4. `docs/redesign/DECISIONS.md`: owner decisions (old heroes hidden; prices 0 / 10k / 20k / 30k;
   no compensation for old hero buyers).
5. `src/swarmv2/shared/Types.lua`, `src/swarmv2/shared/ClassCatalog.lua`,
   `src/swarmv2/server/MatchAdmission.lua`: the frozen shapes and your placeholders.
6. Reference images: `docs/redesign/reference/*.png`.

## Facts already established (don't redo)

- Runs already teleport to **reserved servers of this same place**: `src/server/Modules/RunServers.lua`
  (ReserveServer + TeleportAsync with game.PlaceId, TeleportInitFailed retries, save release before
  teleport via `DataService.ReleaseForTeleport`). Reuse it for tickets and transfer. Both place ids =
  `game.PlaceId`.
- Existing parties: `src/server/Modules/PartyService.lua` + `src/client/MenuParty.lua`. Reuse them.
- Save: `src/server/Modules/DataService.lua` (fields `OwnedCharacters` {id->true}, `SelectedCharacter`).
  Add the new class ids to these same fields (additive). `ruckus` is owned by every account
  (also fill it in for old saves on load). If `SelectedCharacter` holds an old hero id, treat the
  selection as `ruckus` but don't delete anything.
- Gold purchase of heroes exists (CharacterData `Cost`, StoreService / lobby buy flow). Reuse it for
  the 10k / 20k / 30k classes.
- Old lobby = a menu-camera screen (`LobbyScreen`, `MenuPlay`, `MapBuilder.BuildLobby`). The new lobby is a
  walk-around basecamp with normal avatars. Keep the useful existing menus (store, leaderboards,
  settings, quests, etc.) reachable from the basecamp UI.

## Working rules for this chat

- Owner plays on a phone, isn't a programmer and has no Studio during sessions. Chat replies in short
  plain words.
- **Branch:** start from the latest `main` (it contains the shared base commit "Add SwarmV2 shared
  base"). Push only to your own session branch. Never push to `main`; the gameplay chat merges.
- **Save time:** use cheaper subagents (Haiku/Sonnet) for routine work: UI layout, data tables, docs,
  tests. Run them in parallel on separate files. Keep design, security, saves and
  teleports for yourself, and review helpers' work in batches.
- **Don't check after every small change.** Helpers run `bash tools/check.sh --quick` (type check)
  only. Run the full check (`bash tools/check.sh`, `python3 tools/run_regressions.py`, preview
  scenes) **once at the end**. Install tools first with `bash tools/setup_tools.sh`.
- Don't edit files owned by the gameplay track (see OWNERSHIP.md). If you need a change there, write it as a patch in
  `docs/redesign/PATCHES_lobby.md`.
- Tests: write Lune regressions like the existing ones in `tools/*.luau` and `tools/preview/scenes`, and
  register them in `tools/run_regressions.py`. Use mock run consumers for admission. Mark Studio/dev
  mocks clearly. Never claim live teleport works: it can only be tested in a published game.

## Deliver (at the end)

`docs/redesign/lobby/HANDOFF.md` with: changed paths, owned asset manifest, config values, interface
notes for the gameplay chat, PATCHES list, and tests (PASS/FAIL/BLOCKED, offline vs Studio). Push the
branch and tell the owner the branch name so they can pass it to the gameplay chat.

---

## Message to paste into the new chat

```
You are the LOBBY track of the SWARM redesign. Another chat is building the gameplay at the same time.
Read docs/redesign/PROMPT_CHAT1_LOBBY.md on main and do everything it says, start to finish.
Push only to your own session branch, never to main. When done, tell me the branch name.
```
