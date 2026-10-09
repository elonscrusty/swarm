# Hand-off between the two chats (continuation pack)

- Lobby chat (Chat 1): branch `claude/brave-goodall-mzpahn`. When a milestone is validated, it writes
  `docs/redesign/handoff/LOBBY_READY.md`. That file holds the commit, changed paths, interfaces, config
  and tests (PASS / FAIL / BLOCKED, and whether offline or Studio).
- Gameplay chat (Chat 2): branch `claude/dazzling-fermi-ycslnt`. It writes `GAMEPLAY_STATUS.md` here,
  merges the lobby branch, and does the final merge to `main`.
- Interfaces between the two are listed in `docs/redesign/DECISIONS.md` (C2-C4, C10) and
  `docs/redesign/OWNERSHIP.md`.
