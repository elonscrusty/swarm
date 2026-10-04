# Corner farming (master prompt section 3): CORNER report

Status: root cause found and fixed in `src/server/Modules/EnemyAI.lua`. Before and after runs of
the same controlled reproduction are below. Checked offline only (real server modules on the
Lune mock, headless). Not tested in Studio, on a device or in multiplayer.

## Evidence looked at
- `long/274s`, `long/304s`: the hero stands still at the south-east arena corner (the minimap dot is
  in the corner of the play square). The low rim and the fence run along the south side and the tall
  cliff runs along the east side. HP is 154/154 at both frames while kills go from 243 to 367.
- `long/295s`, `long/300s`: the bugs line up in single file along the fence (west) and in a column
  down the cliff side (north). They bunch up a few studs from the hero and few of them touch.
  HP drops to 145 and comes back to 154 (Healing Totem and regen are in the build).
- `long/340s`: 127/154 HP after going back to the edge. The hero still takes some damage there.

Damage still happened (145 and 127 HP), so the hero was not immune. What the frames suggest is
that enemies near a wall moved very slowly and few of them could reach the hero. The tests below
confirm that.

## Root cause (observed in the reproduction)
1. **The look-ahead ray went past the player (main cause).** `think()` cast a ray of
   `AvoidRayLength + radius` (about 10.4 studs for a Mite) toward the player. The ray did not stop at
   the player. When the player stood close to a wall, the ray hit the invisible Boundary wall
   *behind* the player. The enemy then steered along the wall:
   `tangent*1.4 + desired*0.4 + normal*0.3`, which comes out as about 0.1 of its forward speed.
   Every enemy within about 10 studs of a player at a wall slowed to a crawl just outside contact
   reach. In a corner both walls caught the ray. This is the single-file line in the video. A tree
   or rock behind the player caused the same thing.
2. **Low colliders were invisible to the ray.** The ray started 2.5 studs up. 70+ colliders (rubble,
   low walls, plinths) are only 1.3 to 2.8 studs tall, so the ray passed over them. An enemy that
   met one head-on was pushed straight back and stalled, for example a hero in the slot between a
   Ruins corner stone and the wall.
3. **A thin ray for a wide enemy.** An elite (radius 2.8) whose edge rested on a box the ray
   missed, or that met a face head-on, swapped sides on every think and stayed put behind a box in
   line with the hero.

These were reach problems. Sustain did not cause the corner pocket. Contact reach, the clamp and
the collider sizes were all fine: in the reproduction, after the fix, a stationary enemy at the
clamp limit always reaches the hero, at every legal spot.

## Fix (smallest coherent change, `EnemyAI.think` / `EnemyAI.Step`)
- The look-ahead ray length is `min(AvoidRayLength + radius, distance to target)`. Only obstacles
  between the enemy and the player count.
- The ray starts 1 stud above the floor instead of 2.5, so it sees the lowest colliders.
- Contact fallback: `Step` records the direction `pushOut` pushed the enemy back
  (`e.BlockNormal`). If the ray missed but the enemy is pressed against an obstacle and still
  heading into it, it steers around it the same way.
- Head-on tie-break: when the target lies almost straight through the face (|cos| ≤ 0.3), each
  enemy always goes round the same side, chosen by `e.Id` parity. It no longer flips sides.

These rules were not added: no damage to stationary players, no teleports, no enemy buffs, no
sustain changes, no geometry changes. The clamp, contact rules, telegraphs and knockback are
unchanged. Cost is zero or one ray per think as before (shorter rays) plus one sqrt per enemy per
frame.

## Reproduction: `tools/preview/scenes/corner-regression.luau`
Configuration: Solo run, default hero, stage 1 difficulty. Each case uses a fresh controlled
enemy set; the real spawner's waves and top-ups are removed every frame. There are no weapons and
no healing. Contact damage is counted but not applied, so the result measures reach, not
survival. The hero stands still at legal spots: 1.0 stud (half the root width) inside the Boundary
wall face, pushed out of colliders. Spots in each of the six arenas: open field, the middle of each
of the 4 walls, all 4 corners, and the 3 tightest obstacle/wall pockets. Cases per spot: one Mite,
a crowd of 24 Mites (ring 22 to 40 studs, clamped like real spawns), and one elite Beetle Warrior.
At the open field, the south wall and the south-east corner (the evidence spot) it also runs a
Spitter and a Rhino. The Scorpion Queen runs in the first arena. Extra checks: knockback into a
corner, and kiting along a wall. The mock's raycast hits nothing by default, so the scene installs
a ray caster over the real collider parts (`preview.setRaycast`, new opt-in hook in
`tools/preview/runtime/mock`). Instrumentation (offline, per enemy): target distance, collider
radius, steering alignment (cos of the move direction against the line to the hero), forward speed
against max speed, separation, stuck time, contact attempts (cooldown resets), knockback, glob and
lunge counts. There is no in-game overlay.

Permanent regression: `corner-regression` in `tools/run_regressions.py`. Runtime is about 50 s of
CPU time and 80 to 190 s of wall time depending on load.

## Before and after (same harness, all 6 arenas, 1 seed)
| spot group | case | reached (before → after) | mean first hit | steering cos | fwd speed | crowd hits/s, attackers |
|---|---|---|---|---|---|---|
| open field (6) | lone Mite | 6/6 → 6/6 | 2.2 s → 2.2 s | 1.00 → 1.00 | 1.00 → 1.00 | |
| open field (6) | crowd 24 | | | 1.00 → 1.00 | | 11.7/s ×12.8 → same |
| wall middles (24) | lone Mite | **0/24 → 24/24** | never → 2.16 s | 0.14 → 1.00 | 0.14 → 1.00 | |
| wall middles (24) | elite | **8/24 → 24/24** | 7.4 s → 1.6 s | 0.10 → 1.00 | 0.10 → 1.00 | |
| wall middles (24) | crowd 24 | | | 0.54 → 1.00 | | 7.9/s ×10.5 → 11.7/s ×12.7 |
| corners (24) | lone Mite | **0/24 → 24/24** | never → 2.16 s | 0.26 → 1.00 | 0.19 → 0.97 | |
| corners (24) | elite | **5/24 → 24/24** | 6.6 s → 1.6 s | 0.38 → 0.99 | 0.13 → 0.95 | |
| corners (24) | crowd 24 | | | 0.40 → 1.00 | | **5.6/s ×4.4 → 12.5/s ×12.5** |
| pockets (18) | lone Mite | **0/18 → 18/18** | never → 2.19 s | 0.14 → 0.99 | 0.13 → 0.99 | |
| pockets (18) | elite | **4/18 → 18/18** | 7.3 s → 1.9 s | 0.15 → 0.99 | 0.14 → 0.97 | |
| pockets (18) | crowd 24 | | | 0.52 → 1.00 | | 8.8/s ×9.9 → 13.0/s ×12.3 |

Other results:
- Rhino lunger: reached at every spot before and after.
- Scorpion Queen: hits at the open field, the wall and the corner before and after.
- Spitter: fires at every tested spot before and after. It never makes contact, as designed.
- Knockback into a corner: next hit after 3.4 s before, 0.53 s after.
- Kiting at 16 studs/s along the south wall: 0 hits before and after; the Mite ends 55 studs
  behind.
- No enemy left the play square in any case.
- Failures: 177 before, 0 after.

The "before" crowd still lands hits in corners because some Mites spawn already touching the hero.
The ones that walk in mostly never arrive: 4.4 attackers against 12.8 in the open field.

## Tests run
- PASS: `corner-regression` (all arenas, 0 FAIL; it showed 177 FAIL before the fix).
- PASS: `combat-regression`.
- PASS: `tools/check.sh --quick` (typecheck, compile, icons).
- PASS (finished, 0 errors): `stage-sim --max-time 240`.

## Not covered / remaining risk
- Offline mock only. Roblox physics for the hero (how close a real character gets to the Boundary
  face, standing on low colliders) is assumed: the hero centre is 1.0 stud from the wall. Needs a
  Studio playtest at the SE Forest corner.
- Solo only. Co-op target switching was not exercised. Each enemy chases the nearest player, and
  the change is per enemy.
- One seed. Pocket spots depend on each arena's random layout.
- Sustain was not measured here: Healing Totem, regen and Garlic hitting the crowd that does arrive.
  The video's 145 → 154 HP recovery inside 5 s with a real attacker stream is for ECON to check
  once enemies can reach again.
- No in-game diagnostic overlay was built. The instrumentation lives in the offline scene.
