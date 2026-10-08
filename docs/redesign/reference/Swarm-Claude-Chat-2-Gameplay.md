# Claude Chat 2 — SWARM gameplay and final integration

## Shared contract: identical in both chats

Work from the same starting project revision in separate branches or separate project copies. Do not edit the same live Roblox Studio session or overwrite each other's place exports. Both chats may audit the whole source but may modify only their owned scope. Reuse existing equivalent systems; map the intended module names below to actual source paths after inspection. The names describe required interfaces, not a claim that these files already exist.

Chat 1 owns the lobby scene and its scripts, lobby UI, class-selection metadata, party/queue state, transfer tickets, teleport/recovery helpers, and the server-side MatchAdmission module. Chat 2 owns the gameplay scene, character rigs and kits, movement/camera, the run bootstrap, map, enemies, upgrades, run rewards, and gameplay UI. Chat 2 owns final integration after both branches are ready. A single experience can have many public lobby servers: players sharing a lobby server socialize together. Do not promise one unlimited global lobby.

Canonical class IDs are immutable: ruckus, toastmaster, captain_croak, granny_boom. The display names are Ruckus, Toastmaster, Captain Croak, Granny Boom. Chat 1's ClassCatalog owns IDs and descriptive metadata; Chat 2's runtime registry maps those IDs to actual models, weapon kits, passives, animations, and tuning. Do not invent alternate IDs or let one module's loading order overwrite the other. Preserve any legitimate legacy class IDs already used by saves.

Pin these new runtime instance paths for both chats: ReplicatedStorage.SwarmV2.ClassCatalog and ServerScriptService.SwarmV2.MatchAdmission. Map source filenames into these paths through the existing project tooling. These are intended additions, not existing files. If equivalent existing modules must be reused, retain these stable adapter paths so the other chat's imports remain valid. Chat 1 owns both adapters; Chat 2 owns its gameplay registry under ServerScriptService.SwarmV2.Run. Admission and tickets must never be replicated into ClassCatalog.

The server-side API owned by Chat 1 is:
- MatchAdmission.ResolvePlayer(player): returns a success result containing a validated PlayerRunContext, or a failure result with an errorCode and safe display message. It may yield for bounded ticket/profile lookups; never yield indefinitely. Repeated calls for an admitted player return the same context.
- PlayerRunContext fields: schemaVersion = 1; matchId (opaque server-issued string); userId (the actual joining player's ID); classId (canonical validated ID); expectedUserIds (frozen admitted roster); lobbyPlaceId (configured return place).
- MatchAdmission.ReturnToLobby(players): accepts a list of actual server Player instances, returns them to the configured public lobby using the existing safe teleport helper, and reports failures without awarding run rewards. This is separate from Chat 2's completion/reward calculation.
- ClassCatalog: read-only class metadata by canonical ID and the available existing legacy IDs. Catalog visibility is not entitlement; server ownership checks remain authoritative.

Use one defined result convention in both implementations: success = {ok = true, context = PlayerRunContext}; failure = {ok = false, errorCode = string, message = string}. ReturnToLobby reports per-player success/failure. These are interface shapes, not client-authorized payloads.

The authoritative expiring match ticket contains schemaVersion, matchId, targetMatchPlaceId, reservedPrivateServerId, createdAt, expiresAt, expectedUserIds, classesByUserId, and lobbyPlaceId. classesByUserId uses stringified user IDs as keys. It is written to server-accessible storage before teleport, with a proposed 180-second admission TTL. MatchAdmission validates destination place and reserved-server identity as well as roster, class ID, and authoritative ownership. Reservation access codes stay server-side. TeleportData contains only schemaVersion and matchId as lookup hints; it never grants a class, item, currency, or membership. Destination reads Roblox server join data and the authoritative ticket, not a client RemoteEvent. Do not delete the whole ticket after the first member arrives; cache admissions by user/match and allow remaining expected members to arrive.

Admission updates must be atomic where needed and idempotent per match/user, with bounded retries for transient service failures. Validate the trusted origin as well as destination. Use consistent server timestamps and ensure ticket TTL covers retries plus arrival windows. The admission ticket is not a durable reward ledger; Chat 2 must preserve or implement the existing durable once-only reward guard independently.

Freeze the selected class and expected roster when departure begins. Countdown membership/class changes must cancel and rebuild that countdown rather than silently changing a ticket in transit. Chat 2 starts loading only after successful admission. It waits up to a proposed 20 seconds after the first admitted arrival for the expected group, or starts immediately when all arrive. It then starts the run with admitted players, reserving missing expected slots for a further 60-second grace period. Late admitted players initialize once with the ticket's class; after that grace they receive an explained safe return to lobby. Expired/missing/wrong-server tickets never create a default live match or silently spawn the normal avatar in combat. A development-only admission adapter is permitted for local tests and must be explicitly disabled in live servers.

Neither chat waits idle for the other. Chat 2 can build and test against a matching fake provider confined to its own tests/dev harness; live integration must call Chat 1's real module. Chat 1 tests its admission interface with mock run consumers. A shared existing startup script, persistence module, or place configuration must have one owner: Chat 1 owns lobby boot hooks; Chat 2 owns gameplay boot hooks and final shared wiring. If one common file spans both, Chat 1 delivers the smallest documented insertion patch for Chat 2 rather than independently replacing it. Keep data schema changes additive and migration-safe.

Each chat returns its branch/project artifact, actual changed paths, owned asset manifest, setup/config values, interface assumptions, and tests performed. After both finish, Chat 2 incorporates Chat 1's completed artifact, checks the real lobby-to-run flow and all four class identities, and reports any unresolved conflicts. Start both chats immediately; only final integration depends on both results.

# Chat 2: Build SWARM gameplay, characters, map, and final integration

Implement the complete gameplay redesign below while Chat 1 builds the lobby and queues independently. Use the same baseline in your own branch/project copy. Read the shared contract first and keep its identifiers and API exactly. Your work must continue without Chat 1's branch being ready; test your consumer through an isolated development provider, then integrate the real admission module before claiming end-to-end completion. You own final integration after both chats finish. Do not edit Chat 1's lobby, catalog, party, queue, ticket store, or admission implementation.

## Spawn as the selected class

The lobby is a shared forest basecamp where each player selects a class, joins a party, and enters a queue. Chat 1 preserves selected class in a validated server ticket. You consume it to spawn each player as that class's actual model, with the corresponding weapon, passive, movement variant, animations, and HUD. A player who selected Ruckus must enter as Ruckus; apply the same rule to Toastmaster, Captain Croak, and Granny Boom. Do not merely change the class label or give the normal Roblox avatar a different weapon.

Keep the destination loading overlay active until admission succeeds and the player's class rig, camera target, controls, and kit are initialized. Use the existing supported character lifecycle or destination-only automatic-spawn control to prevent a visible default-avatar combat spawn. Preserve the lobby avatar behavior owned by Chat 1. Ensure the rig contains the required Humanoid/Animator/root and camera integration for the actual project; use a shared compatible skeleton when practical. Bind the camera to the new character and clean up old listeners/models on death, respawn, departure, and return.

Resolve each player's server context through the real MatchAdmission adapter using the shared result convention. On temporary admission lookup failure, use bounded retry behind a visible loading state; on terminal rejection, show the reason and request a safe return. Never grant a chosen class from a client claim. Class changes are unavailable during a live run; returning to the lobby allows a new selection. Initialize each match/user once, including delayed arrivals.

Implement the shared arrival barrier and late-arrival grace exactly. The first eligible member starts the bounded group wait. Start immediately once all expected members arrive, otherwise start once after 20 seconds, with 60 seconds of reserved grace for missing expected members. Do not reset the match timer when someone arrives late. Reject unrelated arrivals or capacity overflow. Initialize late players with their ticket's class and a fair safe spawn; do not give them duplicate rewards or restart the run.

Keep persistent rewards once-only using the existing durable guard or the smallest safe run/user/reward record required by the persistence model. Chat 1 owns return transport, so call MatchAdmission.ReturnToLobby with actual Player instances after your outcome/reward flow. Show a result screen with a clear return-to-lobby action. Failure to return must not rerun reward payout.

## Gameplay implementation brief


# Upgrade SWARM into a fast, funny Roblox survival adventure

You are working on an existing Roblox game named SWARM. Audit the actual project first, then implement the approved changes below. The goal is the energetic movement, exploration, escalating horde combat, and satisfying build combinations associated with Megabonk and Risk of Rain 2, expressed through SWARM's own world and original characters. Do not copy those games' characters, maps, names, assets, interfaces, or distinctive kits.

Gameplay reference: https://www.youtube.com/watch?v=v0OHMlDVwQk — “This is What RANK 1 Clank Looks Like in Megabonk” by MrSwagon. Inspect it if your tools support video; disclose any access limitation. The intended qualities are responsive traversal through forest cliffs, automatic attacks while exploring, worthwhile pickups, and substantial growth in weapon spectacle and power over the run. Prioritize Megabonk's automatic-combat feel; use Risk of Rain 2 as inspiration for exploration and item interactions. Do not turn the game into a precision-aim shooter.

## Start with the existing source

Inspect the available project hierarchy and source before choosing implementation details. Identify the current camera, controls, character setup, automatic weapons, enemy spawning, XP and upgrades, run timer, bosses, rescues, lobby, multiplayer behavior, persistence, and asset-loading workflow. Reference real discovered paths in your findings; do not invent filenames or pretend unavailable source was inspected.

Preserve working systems and adapt them where practical. Protect existing DataStores, save keys, schemas, owned character unlocks, purchases, and entitlement checks. Never reset player progress or replace purchase ownership with new defaults. Chat 1 owns the redesigned social lobby; do not edit its implementation. Preserve rescues unless an incompatibility requires a targeted change, and explain the smallest adaptation. Preserve the existing knight as a legacy option if doing so fits the current roster and ownership rules.

Do not rewrite the engine, migrate the project to another framework, introduce an unrelated economy, or publish the experience. Use existing dependencies, rigs, networking, and project conventions where suitable. Make the complete approved scope below playable; a polished slice is an implementation milestone, not the final deliverable.

## Camera, movement, and combat feel

Replace the overhead-only presentation with a third-person free follow camera. Players must be able to look around independently while automatic weapons keep attacking. Start with a camera distance of 22 studs, adjustable between 16 and 28 studs, aimed near the upper torso. Use camera collision handling and keep nearby threats readable. Support mouse and controller camera input and touch drag. On mobile, gently recenter behind movement after approximately 1.25 seconds without manual camera input; suppress recentering while the player is dragging or deliberately looking around. Keep camera settings tunable and avoid sudden snaps.

Make running, jumping, air steering, and dashing responsive. These are proposed starting values, not measured properties of the current game: base movement speed 22 studs/second; ground acceleration around 110 studs/second squared if the existing controller supports it; jump apex approximately 9 studs above takeoff; airborne steering around 70% of ground steering; base dash speed 70 studs/second for 0.22 seconds, approximately 15 studs of travel, with a 2.5-second cooldown. Preserve existing gravity unless a documented reason requires changing it. Prevent dash tunneling and unintended movement exploits. Keep cooldown feedback clear and character movement bonuses visible. Do not require a custom physics controller if the existing Roblox character system can produce the intended feel.

Automatic weapons remain the core combat input. Prefer understandable nearby targets and clear projectiles over camera-dependent precision aiming. Add readable hit reactions, restrained knockback, pickup feedback, and brief, optional camera shake. Provide reduced-motion behavior where practical. Enemy telegraphs and loot must remain visible during busy combat.

## Four approved playable characters

Implement all four as original, funny, low-poly game characters with strong silhouettes and distinct starting kits. Use the existing shared character rig where possible, with simple attachments and animation variations. Their proportions must remain readable from the actual gameplay camera. Keep signature weapons compatible with the shared upgrade system; avoid four separate combat frameworks.

- **Ruckus:** A mischievous raccoon with orange goggles and a trashcan backpack. His automatic weapon launches bouncing scrap. His dash leaves rolling explosive cans. Collecting loot charges his next scrap barrage. As a starting balance proposal, allow one scrap bounce, leave two cans per dash, and trigger a bonus barrage after five eligible loot pickups. Define eligible loot explicitly, cap stored charge at one barrage, and prevent stacked pickup events from producing unbounded attacks.
- **Toastmaster:** A little toaster on tiny boots, with glowing heating coils and an excessively serious expression. His automatic weapon fires ricocheting toast; repeated hits build heat and cause a burn. His jump is spring-loaded, and landing produces a small blast. Start with one ricochet, a three-hit heat threshold, a three-second burn that refreshes rather than stacks indefinitely, and a landing-blast cooldown of two seconds. Propose a 12-stud jump apex for him. Do not let small steps or repeated ground-contact events trigger repeated blasts.
- **Captain Croak:** A round frog with aviator goggles, a yellow scarf, and an expedition backpack. His automatic weapon throws bouncing bubble bombs. He has a long leap; landing near enemies strengthens his next bubble. Start with one bubble bounce, a leap reaching roughly 28–34 horizontal studs under ordinary movement conditions, and an enemy proximity radius of 10 studs for the landing bonus. Store at most one empowered bubble, consumed by the next shot. Prevent leap bonuses from triggering on incidental ground contacts.
- **Granny Boom:** A tiny grandmother with huge welding goggles, armored slippers, and a rocket-powered walker. She automatically tosses explosive yarn. Her dash is a rocket boost, and her explosions briefly tangle enemies. Start with a boost of 80 studs/second for 0.25 seconds and a three-second cooldown; tangles last around 0.75 seconds and slow ordinary enemies by approximately 35%. Give bosses a reduced effect. Refresh tangles within a cap rather than permitting permanent immobilization.

All numbers above are editable starting proposals. Tune damage, radius, firing interval, health, and cooldowns against the existing game's scale. Give every character a readable strength and limitation without making any mandatory for progression. Preserve existing ownership rules when integrating them; do not silently grant or revoke paid entitlements.

Use the current starter weapon's damage as a baseline: begin scrap at roughly 1.0 times its per-hit damage every 0.9 seconds, toast at 0.75 times every 0.65 seconds, bubbles at 1.1 times every 1.2 seconds with a 7-stud burst radius, and yarn at 1.25 times every 1.4 seconds with an 8-stud radius. Balance total damage against ricochets and crowd size rather than multiplying every effect freely. Ruckus's eligible pickups mean chest/item rewards, not each individual XP gem; define and display the charge rule. Prevent recursive on-hit effects from triggering themselves indefinitely. Character identity includes animations and sounds: tail swing and clattering junk, springy toast ejection, frog crouch and boing, walker recoil and sputtering rockets.

## Cliffwood Basin: one cohesive forest-and-cliff map

Build one large, connected low-poly map called **Cliffwood Basin**. Use one cohesive forest-and-cliff theme and a consistent palette and material language throughout: grassy clearings, tall chunky trees, massive stone cliffs and terraces, shallow caves, and old stone ruins. The huge cliffs should make exploration feel expansive while the clearings and ruins create readable landmarks. Do not divide the map into separate regional biomes or add a scrapyard, mushroom biome, stormglass zone, or crashed-reactor science-fiction setting.

Connect broad looping paths around the cliffs with shallow cave shortcuts, walkable winding ascents, and broad bridges. An optional launch pad can offer a fun shortcut, but every essential destination also needs a reliable walking route. Keep cliff geometry chunky and camera-friendly, preserve visibility near fights, and provide routes enemies can actually traverse. Avoid inaccessible ledges that let players defeat the horde without risk.

At unupgraded base speed, traversing the map should take roughly 60–90 seconds. At the proposed 22-stud/second speed, begin with a main traversal route of approximately 1,400–1,800 studs, then measure the actual travel time. This is a traversal target, not permission to make an empty oversized rectangle. Provide visible shortcuts, broad ramps, and multiple escape routes. Main routes should generally be at least 24 studs wide, with larger spaces for major encounters. No mandatory precision platforming or jumps; every essential objective must have a walkable mobile-friendly route.

Measure the existing playable footprint first and make the new map materially larger. An initial blockout could occupy roughly 900–1,200 studs per side, with several 80–140-stud-wide combat clearings and major cliffs approximately 60–180 studs tall. Adjust these proposals to the current map's scale and measured pacing. Build a small reusable cliff/tree/ruin kit; concentrate detail at landmarks and avoid thousands of decorative parts. A loop means a route around a rock formation that returns to a familiar clearing; a shortcut means a cave, bridge, or launch pad that skips a longer section of that same forest route.

Arrange meaningful loot opportunities approximately every 10–15 seconds of normal movement along common routes. Include optional risky side pockets, useful elevated viewpoints, and recognizable landmarks. Reuse existing rescue and boss systems and place them coherently in the new map. Keep the map continuous; avoid building a procedural world generator or separate loading screens.

## Run progression and multiplayer

The run loop is: kill enemies, collect XP, choose a build, move toward worthwhile loot, complete existing rescues or objectives, and confront bosses as pressure increases. Preserve the existing run duration if it represents an explicit design. Only if no duration is established, propose a configurable 12–15-minute default. Preserve existing weapon and passive slot limits if suitable; otherwise begin with four weapon slots and four passive slots. Offer meaningful damage, utility, movement, and synergy upgrades without adding crafting, currencies, or another progression economy.

In multiplayer, one player's upgrade selection must never pause the shared world. Use a compact live choice interface and preserve movement input. As a starting proposal, offer three choices with a ten-second deadline and a predictable fallback; explain the policy and avoid leaving players indefinitely vulnerable in menus.

Keep the server authoritative for damage, deaths, XP, loot eligibility, upgrade choices, rewards, and entitlements. Clients present responsive animation, sound, and VFX. Validate remote requests, cooldowns, ranges, movement allowances, and ownership; do not trust client-provided damage or rewards. Handle simultaneous kills, pickups, disconnects, and respawns without duplicate grants.

## Performance, streaming, and touch usability

Use streaming where appropriate for the larger map. Keep critical run state independent of which scenery a client has loaded. Handle streamed-out enemies, objectives, and pickups gracefully, and avoid indefinite client waits for distant objects.

Reuse or pool projectiles, enemies, pickup visuals, and effects where the existing structure supports it. Avoid expensive pathfinding and physics work for every enemy every frame. Keep enemy updates, VFX density, and replication bounded. A starting stress-test proposal is four players and approximately 200 active enemies; choose an achievable cap after profiling rather than promising that count. Target stable 30 FPS on a representative mobile device and 60 FPS on a reasonable desktop, then report actual measurements and conditions honestly.

Provide a usable touch joystick, camera drag area, jump and dash buttons, cooldown indicators, and upgrade choices that respect screen edges and safe areas. Test that movement, camera drag, and actions work together without blocking one another. Use readable text and icons at phone size.

## Visual references and delivery

Reference images will be supplied as **Swarm-Characters.png**, **Swarm-Cliffwood-Basin.png**, and **Swarm-Models.png**. Treat them as concept references, not rigged 3D assets. Inspect supplied images and implement or import appropriate low-poly models matching their recognizable shapes, colors, and personality. Do not claim that a PNG is a Roblox model. If references are absent, state that fact and use the written designs; if model creation/import is unavailable, identify exactly which assets remain missing.

The reference sheets are more detailed than gameplay models need to be. Preserve silhouettes, main colors, equipment, and personality; simplify scratches, stitching, fur, and small mechanical details. Use neutral matte surfaces and restrained lighting, not glossy cinematic rendering. Model only the four approved new playable characters. Keep existing recognizable beetles and eyeball enemies where practical, updating their presentation to match the map.

Implement a polished playable slice first: movement, camera, one character, a representative forest-and-cliff section, and the existing survival loop. Verify it, then expand to all four characters and the complete connected Cliffwood Basin map. Continue to the full approved scope rather than stopping after the slice.

Acceptance checks must cover: existing saves and ownership remaining valid; all four characters selectable under the intended unlock rules and their kits functioning; smooth third-person control on desktop and touch; automatic weapons targeting correctly; measured traversal and loot spacing; accessible routes without mandatory jumping; rescues and bosses working; upgrades without global pauses; multiplayer reward consistency and rejected invalid requests; streaming transitions; and profiled horde performance. Run relevant existing automated checks and practical playtests. Clearly distinguish completed tests from tests you could not run.

Deliver the changed project files or available Roblox project artifact, matching character and environment assets or a precise asset manifest, editable tuning values, a concise change summary with real source paths, validation results, and any remaining limitations. If source access, asset import, or playtesting is unavailable, report the exact blocker and provide the most concrete reviewable work possible without pretending the game was implemented or verified.


## Current primary implementation references

Use current Roblox documentation for the actual APIs and limitations: [Teleport between places](https://create.roblox.com/docs/projects/teleport), [TeleportService](https://create.roblox.com/docs/reference/engine/classes/TeleportService), and [Memory stores](https://create.roblox.com/docs/cloud-services/memory-stores). Live teleport success requires Roblox client testing; Studio development adapters verify local logic only.

