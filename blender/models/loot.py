"""Map loot (LootSystem): the stage chests players pay gold for.

Chunky low-poly chests (wood / iron / gold), origin = ground centre, front (lock) = -Y.
Every chest has a "Lid" piece (arched, hinge at the back top edge: anim "Jaw", pivot on the
hinge) that the game swings open, plus Box / Straps / Fittings. Sizes match the part-built
fallbacks in src/server/Modules/LootSystem.lua (CHEST_LOOK), so the bounds stay put:
  Chest_Small   2.6 x 1.8 base, ~2.1 tall   wood, iron straps, gold lock
  Chest_Large   3.6 x 2.4 base, ~2.8 tall   darker wood, heavy iron bands, gold corners
  Chest_Golden  3.0 x 2.1 base, ~2.5 tall   gilded body, ivory trims, a crimson gem
"""

import math

from swarmkit import register
from style import P

from ._propkit import prism_yz


def _arch(depth, base_z, rise, n=6):
    """(y, z) outline of an arched lid: flat bottom, half-ellipse top across the depth."""
    half = depth / 2
    pts = [(math.cos(math.radians(180 * i / n)) * half, base_z + math.sin(math.radians(180 * i / n)) * rise) for i in range(n + 1)]
    return pts


def chest(m, w, d, h, lid_rise, palette, gem=False, corners=False):
    m.extra["palette"] = palette
    # body
    box = m.piece("Box", "Wood", shadow=True)
    box.box((w, d, h), loc=(0, 0, h / 2), bevel=0.07)
    box.box((w + 0.1, d + 0.1, 0.16), loc=(0, 0, 0.08), bevel=0.04)  # foot rim
    # lid: arched, hinged on the back top edge (+Y)
    lid = m.piece("Lid", "Lid", anim="Jaw", pivot=(0, d / 2, h))
    prism_yz(lid, _arch(d + 0.06, h, lid_rise), -(w + 0.06) / 2, (w + 0.06) / 2)
    lid.box((w * 0.92, 0.12, 0.2), loc=(0, -(d + 0.06) / 2, h + 0.1), bevel=0.03)  # front lip
    # iron straps over body and lid
    iron = m.piece("Straps", "Iron", "Metal")
    for x in (-w * 0.3, w * 0.3):
        iron.box((0.22, d + 0.06, 0.1), loc=(x, 0, 0.06 + 0.02), bevel=0.0)
        iron.box((0.22, 0.08, h - 0.1), loc=(x, -(d / 2 + 0.03), h / 2), bevel=0.0)
        iron.box((0.22, 0.08, h - 0.1), loc=(x, d / 2 + 0.03, h / 2), bevel=0.0)
        outer = _arch(d + 0.14, h, lid_rise + 0.06)
        inner = _arch(d + 0.02, h, lid_rise - 0.02)
        prism_yz(iron, outer + inner[::-1], x - 0.11, x + 0.11)
    # gold fittings: lock plate + hasp (+ corner caps)
    gold = m.piece("Fittings", "Gold", "Metal")
    gold.box((0.46, 0.12, 0.54), loc=(0, -(d / 2 + 0.06), h - 0.18), bevel=0.03)
    gold.box((0.2, 0.1, 0.3), loc=(0, -(d / 2 + 0.1), h + 0.08), bevel=0.02)
    if corners:
        for x in (-w / 2, w / 2):
            for y in (-d / 2, d / 2):
                gold.box((0.26, 0.26, 0.34), loc=(x, y, 0.22), bevel=0.03)
                gold.box((0.26, 0.26, 0.26), loc=(x, y, h - 0.14), bevel=0.03)
    if gem:
        g = m.piece("Gem", "Gem", "Neon")
        g.ico(0.2, loc=(0, -(d / 2 + 0.16), h - 0.2), scale=(1, 0.6, 1.2), subdiv=1)


@register("Chest_Small", "Loot", "Stage chest, small (pay gold, 1 item): 2.6 x 1.8, wood + iron + gold lock. "
          "Lid hinge at the back top edge.")
def chest_small(m):
    chest(m, 2.6, 1.8, 1.2, 0.62, {"Wood": P("wood_500"), "Lid": P("wood_400"), "Iron": P("steel_700"), "Gold": P("gold_500")})


@register("Chest_Large", "Loot", "Stage chest, large (uncommon+ item): 3.6 x 2.4, dark wood, heavy iron, gold corners.")
def chest_large(m):
    chest(m, 3.6, 2.4, 1.6, 0.85, {"Wood": P("wood_600"), "Lid": P("wood_500"), "Iron": P("steel_600"), "Gold": P("gold_400")},
          corners=True)


@register("Chest_Golden", "Loot", "Stage chest, golden (legendary item): 3.0 x 2.1, gilded body, ivory trims, crimson gem.")
def chest_golden(m):
    chest(m, 3.0, 2.1, 1.4, 0.75, {"Wood": P("gold_600"), "Lid": P("gold_500"), "Iron": P("ivory_200"), "Gold": P("gold_300"),
                                   "Gem": P("crimson_400")}, gem=True, corners=True)
