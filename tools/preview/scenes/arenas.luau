-- arenas: the lobby's ARENAS screen (the ARENA card opens it).
--   --set best=N         the player's best stage (default 3: Forest, Ruins, Swamp unlocked)
--   --set arena=Swamp    the selected arena (SwarmState SelectedArena, default Forest)
local C = lib("common")
C.lobby()
C.startClient()
local best = tonumber(preview.args.best) or 3
local p = C.profile()
p.Stats.BestStage = best
C.sendProfile(p)
if preview.args.arena then
	C.setState({ SelectedArena = preview.args.arena })
end
C.settle(1)
local LobbyScreen = C.try("require LobbyScreen", preview.client, "LobbyScreen")
if LobbyScreen then
	C.try("LobbyScreen.Show", LobbyScreen.Show, "Arenas")
end
C.settle(2)
