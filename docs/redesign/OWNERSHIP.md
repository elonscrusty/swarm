# SWARM redesign: who owns what

Two tracks build at the same time from the **shared base commit** (the commit that added this
file). The contract is in `docs/redesign/reference/Swarm-Claude-Chat-1-Lobby.md` (section
"Shared contract", identical in both prompts) plus the additions below. Code shapes are frozen in
`src/swarmv2/shared/Types.lua`.

- **Chat 1, lobby track:** basecamp scene, lobby UI, class selection/ownership, parties, queues,
  tickets, teleports, `MatchAdmission`.
- **Chat 2, gameplay track (this repo's main session):** characters, kits, camera/movement, Cliffwood
  Basin map, run bootstrap, enemies, upgrades, rewards, gameplay UI, final merge.

A track may **read** any file but only **edit** files it owns. If it needs a change in a file
the other track owns, it writes the smallest patch into its own `docs/redesign/PATCHES_<track>.md`
and Chat 2 applies it during the final merge.

## Rojo paths (added in the shared base)

| Source folder | Roblox path |
|---|---|
| `src/swarmv2/shared` | `ReplicatedStorage.SwarmV2` |
| `src/swarmv2/server` | `ServerScriptService.SwarmV2` |
| `src/swarmv2/client` | `StarterPlayer.StarterPlayerScripts.SwarmV2Client` |

Boot hooks already wired: `GameServer.server.lua` calls `SwarmV2.Lobby.LobbyBoot.Init(ctx)` then
`SwarmV2.Run.RunBoot.Init(ctx)` after all existing modules start; `ClientMain.client.lua` calls
`SwarmV2Client.Lobby.LobbyClient.Init()` and `SwarmV2Client.Run.RunClient.Init()`. `ctx` is the
existing server module table (`ctx.DataService`, `ctx.PartyService`, ...).

## Chat 1 (lobby) owns

New:
- `src/swarmv2/shared/ClassCatalog.lua` (presentation metadata only), `src/swarmv2/shared/Lobby/**`
- `src/swarmv2/server/MatchAdmission.lua`, `src/swarmv2/server/Lobby/**`
- `src/swarmv2/client/Lobby/**`
- `docs/redesign/lobby/**`, `docs/redesign/PATCHES_lobby.md`

Existing files it may edit:
- `src/server/Modules/DataService.lua`: class ownership and selection only (additive fields,
  migration-safe, no schema wipe). It is the only track that edits this file.
- `src/server/Modules/PartyService.lua`, `src/server/Modules/RunServers.lua`, `src/shared/CharacterData.lua`
  (hiding old heroes from lobby lists), `src/server/Modules/StoreService.lua` (class purchase with gold).
- Lobby client screens: `LobbyScreen`, `Menu*.lua`, `HomeBoard`, `LobbyFun`, `Showcase`, `StarterCard`,
  `NoticeDots`, `PartyLines`, `ViewportPreview`, `MetaUI`.

## Chat 2 (gameplay) owns

Everything else, including: `src/swarmv2/server/Run/**`, `src/swarmv2/client/Run/**`,
`src/swarmv2/shared/Run/**`, `default.project.json`, `src/shared/Config.lua`, `src/shared/Remotes.lua`,
`GameServer.server.lua`, `ClientMain.client.lua`, `MapBuilder.lua`, `CameraController.lua`,
`MobileControls.lua`, `JumpController.lua`, `UIBuilder.lua`, `Hud.lua`, `UIKit.lua`, `Theme.lua`,
every run module (RunManager, WeaponSystem, EnemyAI, ...), Blender models and mesh tools.

## Rules for both

- **Remotes:** don't add names to `src/shared/Remotes.lua`. Each track creates its own RemoteEvents in
  its own folder (`ReplicatedStorage.SwarmV2Net.Lobby` / `.Run`), made by its own boot code, with
  per-player rate limits and full argument checks (same pattern as `Remotes.Listen`).
- **Config:** lobby numbers go in `src/swarmv2/shared/Lobby/LobbyConfig.lua`; run numbers in
  `src/swarmv2/shared/Run/RunConfig.lua`. Chat 1 doesn't edit `Config.lua`.
- **Lobby avatars:** the place has `LoadCharacterAppearance = false`, `CharacterAutoLoads = false` and
  Scriptable movement today. Chat 2 will switch the project to standard Roblox character movement and
  a follow camera. Chat 1 doesn't edit `default.project.json`. It spawns lobby avatars itself
  (`LoadCharacter` / `ApplyDescription` with the player's own `HumanoidDescription`) and assumes
  standard controls.
- **Old lobby:** the menu-camera lobby (`MapBuilder.BuildLobby`, `Config.Lobby`) stays until the merge.
  Chat 1 builds the basecamp under `workspace.SwarmV2Lobby` at its own origin, at least 3000 studs from
  `Config.Lobby.Origin` and from any arena. Chat 2 removes the old lobby during the merge.
- Save changes are additive. Never wipe, reset or delete fields. Studio uses the `_Studio` DataStores.

## Contract additions (beyond the pack)

1. `MatchAdmission.ServerRole(): "lobby" | "match" | "local"` (Chat 1). `"local"` = Studio,
   unpublished place (`PlaceId 0`) or transfer switched off: lobby and run share one server.
2. `SwarmV2.Run.RunEntry.BeginLocalMatch(matchId, players): boolean` (Chat 2). In `"local"` role the
   lobby freezes the roster, writes an **in-memory** ticket of the same shape (no MemoryStore, no
   teleport), then calls this. The run side calls `MatchAdmission.ResolvePlayer` exactly as on a
   match server. The local ticket path is never used when the role is `"lobby"` or `"match"`.
3. In `"local"` role, `MatchAdmission.ReturnToLobby(players)` puts players back into the basecamp on
   the same server (avatar respawned at the bonfire) and reports ok per player.
4. Both place ids are `game.PlaceId` (runs use reserved servers of this same place).
5. Remote folders are `ReplicatedStorage.SwarmV2Net.Lobby` (Chat 1) and `ReplicatedStorage.SwarmV2Net.Run`
   (Chat 2). Whoever boots first creates `SwarmV2Net`, using `FindFirstChild` before `Instance.new`.
6. Player attribute `SwarmClass` (string, canonical id) is set by the **server** on the lobby avatar
   (Chat 1) and on the run character (Chat 2), for UI only.
