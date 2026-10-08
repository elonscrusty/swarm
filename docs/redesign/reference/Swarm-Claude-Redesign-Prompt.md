# SWARM redesign — two Claude chats

Use these two prompts instead of the earlier single implementation prompt. Start both chats from the same current SWARM source revision in separate branches or project copies. Give each chat its complete prompt and the reference images. Do not connect both chats to the same live Studio editing session.

1. **Swarm-Claude-Chat-1-Lobby.md** — shared forest lobby, class selection, parties, readiness, queues, transfer/recovery, and authoritative match admission.
2. **Swarm-Claude-Chat-2-Gameplay.md** — actual selected-class character spawning, four character kits, camera/movement, the larger single-theme map, survival gameplay, and final integration.

Both prompts include the same frozen contract for class IDs and lobby-to-run transfer. Chat 1 owns lobby/admission modules; Chat 2 consumes them. Both implementation tracks start simultaneously. Chat 2 performs final integration once both results are ready.

## Player experience

Players arrive in a shared forest basecamp using their normal Roblox avatars. They choose Ruckus, Toastmaster, Captain Croak, or Granny Boom through class displays and mobile-friendly selection, subject to existing ownership rules. They form or join a party, ready up, and enter an obvious queue gate. The group sees a countdown and loading screen. Each player enters the run as the actual character model of their selected class, with its starting weapon and abilities. After the run they return to the lobby, select again, and queue with friends.

Default party/match size is 1–4 players, adjustable to the existing supported cap. Public recruiting and party-only queues are specified. Each public lobby server is a shared social space; this does not require every player worldwide to share one unlimited server.

## References

Attach Swarm-Characters.png, Swarm-Cliffwood-Basin.png, and Swarm-Models.png to both chats. The map remains one cohesive forest-and-cliff theme with huge cliffs, grass, trees, caves, and ruins. The concept PNGs are not rigged Roblox assets. Swarm-Reference-Image-Prompts.md preserves the prompts used with the built-in image generation tool.

Both chats must inspect the actual project rather than assume source paths, place IDs, or tested performance. All gameplay numbers are starting tuning proposals. Existing saves, purchases, and unlocks remain protected. No publishing is requested.

## Final handoff

When Chat 1 finishes, supply its completed branch or changed files, lobby assets, admission module, required configuration, and test summary to Chat 2. Chat 2 incorporates that result after its independent gameplay work, checks class selection through queue/loading/spawn and return, and reports real tests. Missing destination configuration or unavailable live testing must be identified rather than presented as a working live transfer.
