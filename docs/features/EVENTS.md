# EVENTS: map events (feature 2) and weather per world (feature 9)

Flags: `Config.Features.MapEvents`, `Config.Features.Weather`. When a flag is off, that
part does nothing, so the game plays exactly as before.

## What it is

**Map events** (`src/server/Modules/WorldEvents.lua`). This is an ambient encounter that
registers with `EncounterDirector` as `MapEvents`. At most one runs per stage. From
stage 2 (`FirstStage`), each stage rolls `Chance` (0.6) using the director's own Random,
so the stage and loot rolls don't change. The event starts 40-100 s into the explore
phase. It ends after its time runs out, or as soon as the boss phase starts.

| Event | What happens | Headline (headline lane) | Badge |
|---|---|---|---|
| Meteor shower (24 s) | A volley every 3.2 s with 3 impacts, the first landing near each player but never on top of them. A "blast" warning ring shows for 1.3 s, a fireball falls onto it, then it lands. It hurts players (DamagePlayer, so armor, invulnerability and choice protection apply) and normal enemies (45 % of max HP; elites 12 %). Enemies killed this way give no kill gold. It never hits bosses, altar guards, nests or boss objects. | METEOR SHOWER / Step out of the red rings (Critical) | METEORS 24s |
| Gold rush (60 s) | The kill-gold chance doubles, capped at 0.6 and never lowered. The amount, GoldMult and the gold passes stay the same. | GOLD RUSH / More gold from kills for a minute | GOLD RUSH 60s |
| Fog (45 s) | Visual only. The client draws normal enemies only within 42 studs of a living run player, with 4 studs of hysteresis. Bosses, elites, always-detailed creatures, telegraphs, projectiles, pickups and the minimap always show. A soft mist dims the screen outside that circle but never hides anything. | FOG ROLLS IN / Enemies hide in the mist | FOG 45s |

A meteor volley is skipped while other hazards already fill half of
`Config.Enemies.MaxHazards`, so meteors never push a boss's warnings out.

**Weather** (`src/server/Modules/Weather.lua`). Weather belongs to the world, not to an
encounter. It uses the director's ticks and cleanup, but its `Allow` always returns
false, so it never takes the single ambient slot and a map event can still run in a
snow or lava world.

- **Snow storm:** every run player's WalkSpeed is x0.9 (`rp.WeatherSpeedMult`, in
  `RunManager.ApplyMovement`), and so is every walking enemy (`EnemyAI.WorldSpeedMult`;
  scripted `SpeedOverride` moves keep their speed). Light snowfall, a SNOW STORM badge
  and a notice.
- **Lava eruptions:** in the explore phase, from 20 s and then every 14-20 s, 2 fire
  patches appear (`Hazards.Patch` "fire"). They glow harmlessly for 1.6 s (the
  telegraph), then burn for 4 s. They burn players (5 per tick x stage DamageMult) and
  normal enemies (8 % of max HP per tick, with no killer). There are embers and a notice.
- **Other worlds:** one light particle effect each, on the client only. Forest has
  leaves, Ruins and Swamp have motes, Desert has dust.
- **Reduced effects:** no decorative particles, snowfall at 40 %, no meteor light, and a
  lighter mist.

**Client** (`src/client/WorldFx.lua`). It reads the attributes on `workspace.WorldFx`:
`MapEvent`, `MapEventLeft`, `FogRadius`, `World` and `Storm`, plus the `Meteor` marker
parts. It draws the headlines through `UIState.Headline`, the notices through
`UIState.Notice`, the badges through `FeatureHud.Badge` (Order 20 and 21), the particles,
the fireballs and the fog. Nothing shows outside a run.

**Small hooks in shared files** (each one is inert when its flag is off):
- `GameServer` ORDER: `WorldEvents` and `Weather`, after `CaravanEvent`.
- `GoldSystem.OnKill`: `ctx.WorldEvents.GoldChance(chance)`.
- `RunManager.ApplyMovement`: `* (rp.WeatherSpeedMult or 1)`.
- `EnemyAI`: `EnemyAI.WorldSpeedMult`, applied when there is no `SpeedOverride`.
- `EnemyRenderer.HideFilter`: the fog test, never called for bosses or elites.
- `ClientMain`: `WorldFx.Init()`, after FeatureHud.

## How to tune

Everything is in `Config.WorldEvents` (FirstStage, Chance, StartAfter, Weights, and the
Meteor / GoldRush / Fog blocks) and `Config.Weather` (FirstStage, Snow, Lava, Ambient).
`Meteor.Warn` and `Lava.Arm` must stay at 1.2 s or more. `WorldEvents.Force(kind)`
starts an event on the live stage, which is useful for tests and DEV.

## Balance (events-balance, offline)

`events-balance` ran on 2026-10-05: solo runs on stage 1, 120 s windows, 8 runs per
config, the hero standing still (no dodging), level-ups picked automatically. Fog changes
nothing on the server, so the base vs Fog difference shows this sim's run-to-run noise:
about 19 %.

| Config | Damage taken | Event's own damage | Run gold | Kills | vs base |
|---|---|---|---|---|---|
| base (both off) | 334 | 0 | 267 | 215 | 1.00 / 1.00 |
| Meteor | 318 | 25 (8 %) | 273 | 204 | dmg x0.95, gold x1.02 |
| Gold rush | 330 | 0 | 305 | 207 | dmg x0.99, gold x1.14 |
| Fog | 275 | 0 | 319 | 214 | x0.82 / x1.19 (noise) |
| Snow | 223 | 0 | 265 | 201 | dmg x0.67, gold x0.99 |
| Lava | 307 | 17 (6 %) | 252 | 211 | dmg x0.92, gold x0.94 |

Verdict: PASS. No config moves damage or gold by more than the noise. The meteor and
lava hazards make up 8 % and 6 % of the damage taken while standing still. The gold rush
can only double kill gold for 60 s (the chance is capped at 0.6). Stage, chest and
survival gold don't change. Snow lowered damage in this sim, because enemies reach a
hero who stands still more slowly, while a moving player is just as slow. Expect the
storm to be roughly neutral in play; this is ASSUMED, not tested.

## Verified vs BLOCKED

- PASS (offline Lune): `events-regression` (server: flags off, snow mults and cleanup,
  lava eruptions, meteor impacts and no kill gold, gold rush cap and expiry, fog
  attributes, boss phase ends the event, travel and run-end cleanup), `events-fx` (client:
  particles, Reduced effects, badges, headlines, fireballs, the fog filter and mist, leaving
  the run), `events-balance` (see above), and `check.sh --quick` with zero diagnostics in
  these files.
- BLOCKED (not tested yet): Studio, phones and live servers. That covers particle looks,
  how the mist reads on a real phone, the UIStroke ring at large sizes, and how the
  fireball feels.
