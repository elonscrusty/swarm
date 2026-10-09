# SWARM redesign: lobby track handoff (Chat 1)

Branch: `claude/brave-goodall-mzpahn` (from `main` at the shared base). For the gameplay track
(Chat 2), which merges both tracks. Everything here is **offline-tested only**: nothing ran in
Studio, and live reserved-server transfer can only be tested in a published game (section 6).

## 1. What the lobby track built

- **Basecamp** (`workspace.SwarmV2Lobby`, built by `SwarmV2.Lobby.Basecamp` at
  `LobbyConfig.Origin` = (0, 0, 4000), ~220 studs): forest floor under big stone cliffs, chunky
  trees, old ruins, bonfire spawn, four class pedestals with clearly labelled temporary part-built
  previews ("PREVIEW") and a Choose prompt, three gates (Recruit A, Party, Recruit B) with glowing
  pads and live signs, invisible boundary walls. Parts only, no uploaded assets.
- **Own avatars** in the camp (`Avatars`: `LoadCharacterWithHumanoidDescription` with the player's own
  description, respawn at the bonfire, fall rescue). Attribute `SwarmClass` on the Player and the avatar.
- **Classes** (`ClassService`, `ClassOwnership`): select / buy through the class sheet and the pedestal
  prompts (prompts only select, never spend). Saves: the existing `OwnedCharacters`,
  `SelectedCharacter`, `Gold`.
- **Parties**: the existing `PartyService` (invite / accept / decline / kick / leave) plus `Promote`
  and `OnChanged`. Leader policy: when the leader leaves, the longest-standing member (join order)
  leads; otherwise the lead only moves when the leader picks someone (LEAD button on the Party screen).
- **Queues** (`QueueService`): public recruiting gates and a party-only gate, READY, 10 s countdown,
  frozen roster + classes, cancel on any change, re-check at zero, then `Transfer`.
- **Transfer** (`Transfer`): reserve → server-only MemoryStore ticket → save release → one teleport with
  a hint only, per-player retries to the same reservation, partial / failed handling.
- **MatchAdmission** (`ServerScriptService.SwarmV2.MatchAdmission`): `ServerRole`, `ResolvePlayer`,
  `ReturnToLobby`, plus lobby-side helpers.
- **Lobby UI** (`SwarmV2Client.Lobby.*`): class chip + class sheet, PLAY → gate sheet, queue panel
  (members, READY, LEAVE, countdown, travel state), party strip, menu bar to the existing screens
  (Store, Leaderboards, Quests, Settings, More, Party), toasts. Old Home screen hidden in basecamp mode
  (`LobbyScreen.SetBasecamp`).

## 2. Changed paths

New (lobby-owned):
- `src/swarmv2/shared/ClassCatalog.lua` (extended: Role, Look, Primary, Accent, `IsLegacyId`)
- `src/swarmv2/shared/Lobby/LobbyConfig.lua`, `src/swarmv2/shared/Lobby/LobbyNet.lua`
- `src/swarmv2/server/MatchAdmission.lua` (replaces the placeholder; same functions and shapes)
- `src/swarmv2/server/Lobby/{LobbyBoot,Basecamp,Avatars,ClassOwnership,ClassService,QueueService,Transfer,TicketStore,Clock}.lua`
- `src/swarmv2/client/Lobby/*.lua`
- `tools/preview/scenes/{basecamp,basecamp-ui,admission-regression,lobby-queue-regression,party-v2-regression}.luau`
- `docs/redesign/lobby/HANDOFF.md`, `docs/redesign/PATCHES_lobby.md`

Existing files edited (all allowed to the lobby track by OWNERSHIP.md, except the one tools line):
- `src/server/Modules/DataService.lua`, `PartyService.lua`, `RunServers.lua` (see PATCHES_lobby.md, last section)
- `src/client/LobbyScreen.lua` (`SetBasecamp`), `src/client/MenuParty.lua` (LEAD button)
- `tools/run_regressions.py` (registration of the new checks)

Not touched: `Types.lua`, `default.project.json`, `Config.lua`, `Remotes.lua`, GameServer / ClientMain,
any run module.

## 3. Owned asset manifest

No uploaded assets (no meshes, images, sounds, products). The basecamp, pedestal previews, gates and signs
are Roblox Parts built at runtime by `Basecamp.lua`. The pedestal figures are **temporary part-built
previews**, not rigs; when the gameplay track's class models exist, swap the preview builder for clones
of those models (one function in `Basecamp.lua`).

## 4. Config values (`src/swarmv2/shared/Lobby/LobbyConfig.lua`)

| Key | Value | Meaning |
|---|---|---|
| Enabled | true | basecamp replaces the old menu lobby on lobby servers |
| TransferEnabled | true | live reserved-server transfer (false = "local" role) |
| Origin / Size | (0,0,4000) / 220 | basecamp position and floor size |
| MaxPlayers / MinPlayers | 4 / 1 | match and party size (also capped by PartyService.MaxSize) |
| Gates | PublicA (Public), Party (Party), PublicB (Public) | |
| CountdownSeconds | 10 | after everyone is READY |
| PadCooldownSeconds / PadPollSeconds | 1.5 / 0.25 | pad spam guard / pad polling |
| TicketTTLSeconds | 180 | MemoryStore ticket lifetime |
| ReserveAttempts / StoreAttempts | 2 / 3 | ReserveServer / MemoryStore tries |
| TeleportRetries / TeleportRetryDelays | 2 / {1, 3} s | per-player retries to the same reservation |
| TeleportTimeoutSeconds | 25 | a silent teleport failure counts as failed |
| ReturnRetries | 2 | return-to-lobby teleport retries |
| ProfileWaitSeconds / ResolveWaitSeconds | 20 / 30 | bounded waits in ResolvePlayer |

Place ids: none to configure. Runs use reserved servers of **this same place**, so
`targetMatchPlaceId = lobbyPlaceId = game.PlaceId` (DECISIONS.md). MemoryStore map: `SwarmV2Tickets`.

## 5. Interface notes for the gameplay track

```lua
local MatchAdmission = require(game:GetService("ServerScriptService").SwarmV2.MatchAdmission)
MatchAdmission.ServerRole()        --> "lobby" | "match" | "local"
MatchAdmission.ResolvePlayer(p)    --> { ok = true, context = PlayerRunContext } | { ok = false, errorCode, message }
MatchAdmission.ReturnToLobby(list) --> { { userId, ok, errorCode?, message? } }
```

- `ResolvePlayer` may yield (MemoryStore read with retries, waits for the player's save up to 20 s);
  it never yields forever. Call it from a spawned thread per arriving player. Same player again → the
  same frozen context table. Recoverable errors: `STORE_UNAVAILABLE`, `PROFILE_UNAVAILABLE`, `TIMEOUT`
  (call once more, then return the player). Every other error: show `message`, then
  `ReturnToLobby({ player })`. Never start a default match or put the normal avatar in combat.
- The ticket is not consumed on arrival: every expected member can be admitted until it expires (180 s
  after the lobby wrote it). Your arrival barrier (20 s wait, 60 s late grace) fits inside that.
- The match server binds to the first match it admits; another matchId gets `WRONG_MATCH`.
- `context.classId` is validated against the save at arrival. Ownership is not re-checked later.
- `ReturnToLobby` releases each save before the teleport (it is the last save of the run server for
  that player: settle run rewards **before** calling it). It awards nothing.
- Local role (Studio / unpublished / TransferEnabled off): the lobby calls
  `SwarmV2.Run.RunEntry.BeginLocalMatch(matchId, players)` after registering an in-memory ticket; your
  side calls `ResolvePlayer` exactly as on a match server. Return false if the run can't start: the
  lobby drops the local ticket and puts everyone back at the bonfire. `ReturnToLobby` in local role
  respawns the avatar at the bonfire (you should remove your run character first or let the avatar
  spawn replace it).
- On a match server the lobby builds nothing (no basecamp, no lobby remotes); `LobbyBoot` only starts
  `MatchAdmission`'s return-trip watcher.
- `RunServers` (old) ignores arrivals with `TeleportData.SwarmV2`.
- Player attribute `Travel = "ToRun"` is set during a transfer (the old TravelOverlay cover shows it).

## 6. Tests (offline only, 2026-10-09; nothing in Studio, nothing live)

| Check | Result |
|---|---|
| `bash tools/check.sh --quick` (type check, compile) | PASS, zero diagnostics |
| `admission-regression` (MatchAdmission + TicketStore: roles, valid ticket, frozen + repeated context, every reject code, store outage, expiry, replay, wrong match / server / place, ReturnToLobby in match and local role, retries) | PASS 168/168 |
| `lobby-queue-regression` (queues, whole-party admission, capacity, party-only gate, READY, countdown cancel on leave / unready / disconnect / class / party change, commit revalidation, Transfer live + local paths, partial teleport retries to the same reservation, exhausted failures, pads vs UI same transitions, pad spam, ClassOwnership buy / select / legacy id) | PASS 194/194 |
| `party-v2-regression` (real server: invite / accept / expiry / full party races / kick / leave / leader policy / Promote / disconnect / OnChanged; save normalisation) | PASS 82/82 after fixing two bugs it found |
| `basecamp` scene (world render, 1139 parts) | renders, 0 errors; looked at by eye |
| `basecamp-ui` scene on iphone / phone-portrait / pc (12 views) | renders; `check_layout.py` clean except a deliberately long test name (ellipsis) |
| Full `tools/run_regressions.py` (6 workers) | 254/275 PASS. All 8 new basecamp-ui phone layout checks PASS. The 21 FAIL are all layout checks of the OLD lobby screens (menu, daily, party, results, explore, store, levelup): not yet compared with `main`, so unknown whether they are pre-existing or caused by the basecamp hiding the old Home screen in the preview. Compare with `--only <name>` on `main` before merging. |

BLOCKED (need a published game / Studio): live reserved-server teleport, MemoryStore, real avatars
(`LoadCharacterWithHumanoidDescription`), walking, ProximityPrompts, SurfaceGui gate signs (the preview
does not draw them), phone feel. `build/Swarm.rbxlx` was NOT rebuilt on this branch (binary file, would
conflict with the gameplay track's merge): rebuild once after the merge.

## 7. Open items

- PATCHES_lobby.md L1-L4 are required for the basecamp to be playable (old lobby hero, movement block,
  menu camera, first-run auto start).
- Pedestal figures are temporary part previews; swap in the real class models when they exist.
- Old hero skins in the Store are still listed (the Store was not changed); decide whether to hide them.
- Parties don't re-form after a return (PATCHES L6, needs a shared ticket field).
