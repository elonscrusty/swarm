"""Vignette layouts for _scene.py (data only). Coordinates are Blender studs: +Y = north (away
from the camera), the camera sits south looking north at `focus`, 55 degrees down.
place: (model, x, y, yaw degrees, scale)."""

import random

from style import P, mix


def scatter(names, n, box, seed, avoid=(), yaw=True, scale=(0.85, 1.15), min_gap=0.0):
    """Deterministic scatter of small decor inside box (x0, y0, x1, y1), skipping avoid circles."""
    rng = random.Random(seed)
    out = []
    tries = 0
    while len(out) < n and tries < n * 40:
        tries += 1
        x, y = rng.uniform(box[0], box[2]), rng.uniform(box[1], box[3])
        if any((x - ax) ** 2 + (y - ay) ** 2 < ar * ar for ax, ay, ar in avoid):
            continue
        if min_gap and any((x - o[1]) ** 2 + (y - o[2]) ** 2 < min_gap ** 2 for o in out):
            continue
        out.append((rng.choice(names), round(x, 2), round(y, 2), rng.uniform(0, 360) if yaw else 0,
                    rng.uniform(*scale)))
    return out


def ring_of(names, n, cx, cy, r0, r1, seed, scale=(0.9, 1.15), arc=(0, 360)):
    import math
    rng = random.Random(seed)
    out = []
    for i in range(n):
        a = math.radians(arc[0] + (arc[1] - arc[0]) * (i + rng.uniform(0.1, 0.9)) / n)
        r = rng.uniform(r0, r1)
        out.append((rng.choice(names), cx + math.cos(a) * r, cy + math.sin(a) * r, rng.uniform(0, 360), rng.uniform(*scale)))
    return out


# ------------------------------------------------------------------ events (forest)

_EV_AVOID = [(4, 8, 14), (-22, 4, 6), (24, 2, 4.5)]
EVENTS = dict(
    ground=P("moss_500"),
    patches=[(-30, 20, 16, 10, P("moss_600")), (26, -18, 14, 9, P("moss_400")), (30, 26, 12, 8, P("moss_600")),
             (-26, -20, 12, 8, P("moss_400")), (6, 8, 13.5, 13.5, mix("moss_500", "moss_400", 0.5))],
    paths=[([(-60, -30), (-30, -18), (-12, -12), (0, -14), (14, -10), (30, -14), (60, -8)], 7, P("dirt_500"))],
    focus=(0, 6),
    distance=92,
    place=[
        ("Challenge_Ring", 4, 8, 0, 1), ("Challenge_Brazier", 4, 8, 15, 1),
        ("Guard_Altar", -22, 4, 10, 1), ("Chest", -22, 4, 10, 1, 0.9),
        ("BeetleWarrior", -18, 0, 200, 1), ("BeetleWarrior", -26, -1, 160, 1),
        ("Shrine_Bargain", 24, 2, -12, 1),
        ("Knight", -3, -1, 20, 1),
        ("Mite", 8, 3, 30, 1), ("Mite", 1, 13, 200, 1), ("Mite", 10, 12, 120, 1),
        ("Tree_Pine", -34, 30, 0, 1.05), ("Tree_Round", -18, 34, 40, 1), ("Tree_PineTall", 32, 36, 0, 1),
        ("Tree_Pine", 40, 16, 70, 0.95), ("Tree_Round", -42, 12, 0, 1.05), ("Tree_Pine", 20, 40, 30, 1),
        ("Rock", 34, -2, 30, 1), ("Ruin_WallLow", -30, 14, 20, 1), ("Pillar", 30, 8, 0, 1),
        ("Rock", -8, 26, 120, 0.9), ("Lantern_Post", 12, -18, 0, 1), ("Torch", -14, -6, 0, 1),
    ] + scatter(["Bush", "Fern", "GrassTuft", "GrassTuft", "Flowers", "Rock_Small"], 46, (-46, -26, 46, 40), 7,
                avoid=_EV_AVOID + [(0, -14, 6)], min_gap=3.5),
)

SCENES = {"events": EVENTS}


# ------------------------------------------------------------------ biomes

def _biome(ground, patches, paths, place, decor, decor_n, avoid, seed, **kw):
    d = dict(ground=ground, patches=patches, paths=paths, focus=(0, 6), distance=92,
             place=place + scatter(decor, decor_n, (-48, -26, 48, 44), seed, avoid=avoid, min_gap=3.2))
    d.update(kw)
    return d


_PATH = [(-60, -26), (-30, -16), (-12, -12), (0, -14), (14, -9), (30, -13), (60, -6)]
_HEROES = [("Knight", -2, -4, 20, 1), ("Mite", 6, -1, 210, 1), ("Mite", 9, 3, 180, 1), ("Mite", 3, 4, 150, 1),
           ("Wasp", -9, 2, 120, 1)]

SWAMP = _biome(
    P("murk_500"),
    [(-30, 22, 16, 10, P("murk_600")), (26, -18, 14, 9, P("murk_400")), (30, 26, 12, 8, P("murk_600")),
     (-6, 24, 9, 6, P("bog_500")), (-26, -20, 12, 8, P("murk_400"))],
    [(_PATH, 7, P("bog_500"))],
    _HEROES + [
        ("Swamp_Hut", -20, 18, 15, 1), ("Mud_Pool", 14, 10, 0, 1), ("Mud_Pool", -6, 24, 70, 0.8),
        ("Lilypads", 15, 11, 30, 1), ("Lilypads", -5, 25, 200, 0.9),
        ("Swamp_Tree", -40, 34, 0, 1), ("Swamp_Tree", 34, 34, 80, 1.05), ("Swamp_Tree", 44, 6, 200, 0.95),
        ("Swamp_Willow", -44, 8, 0, 1), ("Swamp_Willow", 14, 40, 60, 1), ("Swamp_Tree", -10, 44, 140, 1),
        ("Swamp_Log", 28, -2, 25, 1), ("Swamp_Stump", -30, 4, 0, 1), ("Swamp_Rock", 34, 14, 40, 1),
        ("Swamp_Rock", -36, -10, 200, 0.9), ("Swamp_Lantern", -14, -6, 0, 1), ("Swamp_Lantern", 20, -4, 180, 1),
        ("Reeds", 18, 6, 0, 1), ("Reeds", 9, 13, 50, 0.9), ("Reeds", -9, 21, 0, 1), ("Reeds", -2, 27, 0, 1.1),
        ("Swamp_Tree", 30, 22, 300, 0.95), ("Swamp_Willow", -34, 24, 120, 0.9), ("Swamp_Tree", 6, 30, 20, 0.9),
        ("Swamp_Stump", 24, 18, 60, 0.9), ("Swamp_Log", -30, 32, 160, 1),
    ],
    ["Reeds", "Reeds", "Fern", "GrassTuft", "Lilypads", "Rock_Small", "Mushroom"], 34,
    [(14, 10, 6), (-20, 18, 7), (-6, 24, 5), (0, 0, 8), (30, 22, 4), (-34, 24, 5), (6, 30, 4)], 11,
    sky=(0.66, 0.74, 0.72), sun=2.8, sun_color=(0.95, 0.97, 0.88))

SNOW = _biome(
    P("snow_200"),
    [(-30, 22, 16, 10, P("snow_100")), (26, -18, 14, 9, P("snow_300")), (30, 26, 12, 8, P("snow_100")),
     (-26, -20, 12, 8, P("snow_100"))],
    [(_PATH, 6, P("snow_300"))],
    _HEROES + [
        ("Snow_Shrine_Totem", -18, 16, 10, 1), ("Frozen_Pond", 14, 10, 0, 1),
        ("Snow_Pine", -40, 32, 0, 1), ("Snow_PineTall", -28, 40, 30, 1), ("Snow_Pine", 34, 34, 80, 1.05),
        ("Snow_PineTall", 44, 14, 20, 1), ("Snow_Pine", -46, 6, 0, 0.95), ("Snow_Pine", 10, 42, 60, 1),
        ("Snow_Rock", 30, 0, 30, 1), ("Snow_Rock", -32, -6, 200, 0.9), ("Ice_Crystal", 26, 18, 0, 1),
        ("Ice_Crystal", -26, 10, 40, 0.9), ("Snow_Ruin_Wall", -4, 28, 10, 1), ("Snow_Lamp", -14, -6, 0, 1),
        ("Snow_Lamp", 20, -4, 0, 1),
    ],
    ["Snow_Drift", "Snow_Bush", "Snow_Bush", "Rock_Small", "Snow_Drift"], 26,
    [(14, 10, 7), (-18, 16, 5), (-4, 28, 5), (0, 0, 8)], 12,
    sky=(0.7, 0.77, 0.88), sky_strength=0.62, sun=2.2, sun_color=(1.0, 0.97, 0.92))

DESERT = _biome(
    P("sand_400"),
    [(-30, 22, 16, 10, P("sand_300")), (26, -18, 14, 9, P("sand_500")), (30, 26, 12, 8, P("sand_300")),
     (-26, -20, 12, 8, P("sand_500"))],
    [(_PATH, 7, P("sand_500"))],
    _HEROES + [
        ("Desert_Mesa", -34, 34, 0, 1), ("Desert_Obelisk", 16, 20, 0, 1), ("Quicksand", -8, 14, 0, 1),
        ("Desert_Tent", 30, -2, -25, 1), ("Cactus", -24, 4, 0, 1), ("Cactus_Tall", 38, 30, 40, 1),
        ("Cactus", 22, 2, 120, 0.9), ("Cactus_Tall", -40, 10, 0, 1), ("Cactus", 6, 36, 200, 1),
        ("Desert_Rock", 34, 12, 30, 1), ("Desert_Rock", -18, -8, 120, 0.9), ("Desert_Ruin_Pillar", 8, 22, 0, 1),
        ("Desert_Ruin_Pillar", 24, 24, 0, 0.9), ("Desert_Ruin_Wall", -16, 28, 10, 1), ("Bones", 2, 10, 30, 1),
        ("Dune", -38, -14, 0, 1.2), ("Dune", 40, -18, 160, 1),
    ],
    ["Dune", "Rock_Small", "Rock_Small", "Cactus"], 14,
    [(-8, 14, 6), (16, 20, 5), (30, -2, 6), (-34, 34, 9), (0, 0, 8)], 13,
    sky=(0.78, 0.82, 0.88), sun=3.4, sun_color=(1.0, 0.95, 0.85))

LAVA = _biome(
    mix("basalt_600", "ash_400", 0.35),
    [(-30, 22, 16, 10, P("basalt_600")), (26, -18, 14, 9, P("ash_400")), (30, 26, 12, 8, P("basalt_600")),
     (-26, -20, 12, 8, P("ash_400"))],
    [(_PATH, 7, P("ash_300"))],
    _HEROES + [
        ("Brimstone_Altar", -2, 22, 0, 1), ("Lava_Pool", 18, 6, 0, 1), ("Lava_Pool", -22, 10, 50, 0.85),
        ("Basalt_Column", -36, 32, 0, 1), ("Basalt_Column", 36, 34, 60, 0.8), ("Charred_Tree", -42, 8, 0, 1),
        ("Charred_Tree", 40, 12, 90, 1), ("Charred_Tree", 18, 38, 30, 0.9), ("Obsidian_Crystal", 28, 20, 0, 1),
        ("Obsidian_Crystal", -14, 32, 40, 0.9), ("Ember_Vent", 8, 14, 0, 1), ("Ember_Vent", -30, -6, 0, 0.9),
        ("Lava_Ruin_Wall", 30, -4, 20, 1), ("Basalt_Rock", -12, -6, 30, 1), ("Basalt_Rock", 22, -14, 200, 0.9),
    ],
    ["Ash_Pile", "Ash_Pile", "Rock_Small"], 18,
    [(18, 6, 6), (-22, 10, 5), (-2, 22, 7), (0, 0, 8)], 14,
    sky=(0.55, 0.5, 0.5), sky_strength=0.75, sun=2.6, sun_color=(1.0, 0.88, 0.75))

SCENES.update(swamp=SWAMP, snow=SNOW, desert=DESERT, lava=LAVA)
