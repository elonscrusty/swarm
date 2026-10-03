# SWARM accessibility and co-op follow-up

The user approved the visual revision and selected all twenty follow-up choices through the interactive questionnaire. Preserve the progression changes and the approved menu, grass, minimap, font, and skin-hover fixes. Back up source before each new edit. Finish with verification, one rebuilt place, and a normal fast-forward push to main.

## Accepted choices

1. Co-op pings cover locations, enemies, loot, and preset quick messages.
2. Pings are brief markers in teammate colors.
3. Match players automatically without preference queues.
4. Rejoin the same run after disconnect when it is still available.
5. Learn enemies through play; do not add automatic enemy introductions.
6. An optional enemy journal shows attack clues and discovered drops.
7. Weapon-combination clues appear after finding their ingredients.
8. Do not add saved build plans.
9. Upgrade cards use short benefit summaries.
10. Ground danger uses consistent colors and clear outlines.
11. Colorblind support covers combat colors and marker shapes.
12. Reduce flashes is a separate setting.
13. Audio offers detailed channel controls and mute all.
14. Visual indicators for sound cues are optional.
15. Touch controls offer a few presets.
16. Automatic aiming only. The user explicitly removed manual aiming and its setting.
17. The lobby shows a small last-run summary and a retry action.
18. Defeat review shows the recent damage sources.
19. Skins preview freely; a clear Equip button commits the selection.
20. Completed daily results show score, personal best, and leaderboard position when available.

## Ownership and implementation

- Astra: server pings, authorized rejoining, bounded damage history, journal persistence and discovery; final clarity work in Daily/Stats before server work.
- Interface helper: explicit skin equip, honest daily rank, optional journal interface.
- Accessibility helper: audio channels, flash/color settings, danger readability, touch presets and aiming controls.
- Root: shared configuration/remotes and settings validation, module integration, last-run summary and retry, recent damage presentation, discovered combination clues, short upgrade summaries, verification and delivery.

Upgrades must appear immediately when XP fills the bar. There is no pacing timer. Higher XP costs slow leveling naturally; later levels grant coins only once all legal weapon, passive, and evolution upgrades are exhausted.

Use existing modules and native Roblox functionality. Validate all client/server inputs, retain the save and purchase safeguards, and keep unreached or unavailable leaderboard/rejoin states honest. New runtime features must have meaningful focused checks for boundary cases and lifecycle behavior.

## Verification

The preceding visual revision passes 33/33 portable regression processes, including both phone orientations and the new guided Daily/closest-first Achievement checks. Full Studio physics, live teleports, live DataStores, audio permissions, and real phone performance remain unverified.

- [ ] Integrate the selected follow-up behavior.
- [ ] Check meaningful feature regressions and the existing suite.
- [ ] Inspect affected previews in both phone orientations.
- [ ] Rebuild and verify the final place.
- [ ] Commit and push to main; report remaining live testing needs.
