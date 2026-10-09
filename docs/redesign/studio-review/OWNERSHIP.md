# Studio recording review (2026-10-09): ownership for this batch

The owner's prompt from a 2:29 Studio recording (issues SW-01 to SW-23) is saved as `PROMPT.md` here.
The lobby chat never started its continuation, so the gameplay chat (`claude/dazzling-fermi-ycslnt`) owns
both tracks and is the **integration owner** for the combined build.

| Stream | Issues | Owns (edit) |
|---|---|---|
| R1 lifecycle | SW-01, SW-23, SW-06 (data), SW-22 (DEV gating) | RunManager lifecycle and results payload, LobbyBoot / RunEntry boot order, Hud.lua layout fix, DevPanel / DevAccess client gating |
| R2 identity | SW-02, SW-10, SW-11, SW-12 | ModelBuilder spawn and fallback, Lobby ClassBrowser / ClassPanel / Basecamp plaques, identity card |
| R3 queue | SW-08 | QueueService, QueuePanel, PartyStrip, LobbyConfig capacity, gate signs in Basecamp (signs only) |
| R4 map + camera | SW-03, SW-19, SW-20 (layout part) | CliffwoodLayout / Builder, CameraController, fallRescue in RunManager (that function only), LaunchPads labels |
| R5 transactions | SW-04, SW-05, SW-07 | LootUI, LootSystem / GoldSystem chest purchase, revive offer server and client (UIBuilder revive section only), MonetizationService |
| R6 presentation | SW-09, SW-21, SW-13 to SW-17, SW-18, SW-06 (visual) | lighting (MapBuilder.ApplyLighting / Basecamp), RunTheme and run HUD widgets, RunCards, RunScreens (inventory), ResultsExtras and the UIBuilder results section, Telegraphs and player ring |

Shared contract: the existing attributes and remotes in `docs/redesign/continuation/GAMEPLAY_PLAN.md`. A
change to a file you don't own: keep it to a few lines, mark it `[Rn]`, and list it in your report.
