# Lobby track: patches for files the gameplay track owns

The lobby track (Chat 1) may not edit these files (docs/redesign/OWNERSHIP.md). The gameplay track
(Chat 2) applies them during the final merge. Each patch is the smallest change; line numbers are from
the shared base commit and may have moved.

How the old code can tell the basecamp is running:
- server: `require(ServerScriptService.SwarmV2.Lobby.LobbyBoot).Active()` (true on lobby / local
  servers once the basecamp booted; false on match servers or with `LobbyConfig.Enabled = false`);
- client: `ReplicatedStorage.SwarmV2Net.Lobby:GetAttribute("Basecamp") == true`.

## L1. RunManager: stop building the old blocky lobby hero (REQUIRED)

`src/server/Modules/RunManager.lua`. The basecamp spawns the player's own Roblox avatar
(`SwarmV2.Lobby.Avatars`). The old code replaces it with the menu-lobby hero in four places:
`spawnCharacter(..., inLobby = true)` from `DataService.OnProfileLoaded`, `RefreshLobbyCharacter`
(character select, skins, the VIP crown mesh), `returnPlayerToLobby` and the fall-out respawn. One guard
at the top of `spawnCharacter` covers all of them:

```lua
spawnCharacter = function(player: Player, cframe: CFrame, inLobby: boolean, runCharacterId: string?): Model?
	if inLobby then
		local ok, boot = pcall(function()
			return require(game:GetService("ServerScriptService").SwarmV2.Lobby.LobbyBoot)
		end)
		if ok and boot.Active() then
			return player.Character -- the basecamp owns lobby characters (Avatars)
		end
	end
	...
```

Until this is applied, `Avatars` has a guard that re-spawns the avatar when the old code replaces it
(at most once per 2 s). Remove nothing else; the guard is harmless after the patch.

## L2. UIBuilder: let players walk in the basecamp (REQUIRED)

`src/client/UIBuilder.lua` around line 6002 (`setBlocking("Lobby", not inRun)`): the old lobby is a
menu, so movement is blocked outside runs. With the basecamp:

```lua
local basecamp = game:GetService("ReplicatedStorage"):FindFirstChild("SwarmV2Net")
basecamp = basecamp and basecamp:FindFirstChild("Lobby")
local inCamp = basecamp ~= nil and basecamp:GetAttribute("Basecamp") == true
setBlocking("Lobby", not inRun and not inCamp)
Showcase.SetVisible(not inRun and not inCamp) -- the old dais hero is not in the basecamp
```

`LobbyScreen.SetVisible(not inRun)` stays: in basecamp mode (`LobbyScreen.SetBasecamp(true)`, called by
`SwarmV2Client.Lobby.LobbyClient`) the old Home screen draws nothing and blocks no input; only the
screens the basecamp menu opens (Store, Party, Leaderboards, Quests, Settings, More) show.

## L3. CameraController / movement: standard follow camera in the basecamp (REQUIRED)

`src/client/CameraController.lua`: outside a run it points the camera at the old lobby's `MenuCamera`
part. In the basecamp the camera must be Roblox's normal follow camera on the player's own avatar
(`Camera.CameraType = Custom`, `CameraSubject = Humanoid`). The gameplay track already switches the
project to standard movement and a follow camera (OWNERSHIP.md "Lobby avatars"); apply it to lobby
servers too, keyed on the same `Basecamp` attribute. `MobileControls` must show the normal thumbstick and
jump in the basecamp.

## L4. First-run auto start (REQUIRED)

`src/shared/Config.lua` `Config.FirstRun.AutoStart = true` starts an old solo run on a new account's first
join (RunManager). With the basecamp that would drop new players into the old run flow. Either set it to
false, or replace it with the new flow (e.g. the gameplay track's own first-run). Owner decision needed
if the new game should auto-start a first run.

## L5. Old lobby removal (at merge)

`MapBuilder.BuildLobby`, `Config.Lobby`, `CameraController` menu camera, the old PLAY / mode / Daily
start buttons and the old `RunServers` lobby → run trip (`RunServers.SendToRun`) are replaced by the
basecamp's gates + `Transfer`. Keep `RunServers` for its return / reconnect helpers only as long as the
gameplay track still needs them. The basecamp sits at `LobbyConfig.Origin` (0, 0, 4000), more than 3000
studs from `Config.Lobby.Origin` and from the arenas.

## L6. Party re-forming after a return (optional)

`MatchAdmission.ReturnToLobby` sends `TeleportData { SwarmV2Return = { schemaVersion = 1 } }`. Parties don't
re-form automatically on the lobby server (the frozen `MatchTicket` shape has no party field). If wanted:
add an optional `party = { leader, members }` to the ticket (both tracks + owner OK, `Types.lua` is frozen)
and pass it as `SwarmReturn = { Party = ... }`, which `PartyService.reformAfterRun` already understands.

## L7. Regressions registration (done in this branch)

`tools/run_regressions.py` got the new lobby checks (one line, comment "SwarmV2 lobby"). Tools are the
gameplay track's; keep the line when merging.

## Lobby-owned edits to existing files (already in this branch, for review)

- `src/server/Modules/DataService.lua`: every save owns `ruckus`; `SelectedCharacter` may hold a class
  id (old hero ids are kept and read as `ruckus` by the lobby). Additive, no schema bump.
- `src/server/Modules/PartyService.lua`: `Promote` action, `OnChanged(fn)` signal, comment on the
  leader policy.
- `src/server/Modules/RunServers.lua`: arrivals carrying `TeleportData.SwarmV2` are left to
  `MatchAdmission` (the old run-server code no longer refuses them); `OwnsTeleport` also covers a
  basecamp transfer (`Travel = "ToRun"`), so PartyService stays quiet about its teleport failures.
