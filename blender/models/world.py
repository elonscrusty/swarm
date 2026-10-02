"""World kit for the forest arena: trees, shrubs, rocks, ruins, props and small clutter.

Conventions (see docs/ART_DIRECTION.md): origin = ground centre, front = -Y (Roblox -Z),
1 unit = 1 stud, colours from the shared palette (style.P). Each piece is one MeshPart in
one colour, so tones are split by piece; big pieces of obstacles cast shadows, clutter
does not. Extras written to meshes/catalog.json (Roblox studs, from the origin):
  collider  {"kind": "circle", "radius", "height"} | {"kind": "box", "size": [x, z], "height"}
            | {"kind": "multi", "shapes": [... each with "offset": [x, z]]}
  light     [x, y, z] where a PointLight / Fire belongs (flames, lantern cores, glows)
"""

import math
import random

from swarmkit import register
from style import P, mix

from ._propkit import (TAU, annular_block, blade, blob_points, box, cap_of, flame, hull, leaf,
                       light_at, loft, mesh, prism_xz, put, ring, roblox_xz, sheet, voussoir)


# ------------------------------------------------------------------ shared builders

def trunk(piece, height, r0, r1, seed, sides=7, lean=(0.0, 0.0), flare=0.3, roots=4, root_len=1.0):
    """Tapered faceted trunk with a flared base and a few root knuckles."""
    rng = random.Random(seed)
    lx, ly = lean
    rings = []
    for t in (0.0, 0.08, 0.35, 0.7, 1.0):
        z = -0.15 + (height + 0.15) * t
        r = r0 + (r1 - r0) * t
        if t == 0.0:
            r *= 1 + flare
        elif t == 0.08:
            r *= 1 + flare * 0.25
        rings.append(ring(sides, r, z, phase=0.3, cx=lx * t * t, cy=ly * t * t, wobble=0.05,
                          seed=seed + int(t * 10)))
    loft(piece, rings)
    for i in range(roots):
        a = rng.uniform(0, TAU) if roots == 1 else (i / roots * TAU + rng.uniform(-0.4, 0.4))
        d = r0 * (1.9 + rng.uniform(0, 0.5)) * root_len
        piece.limb((math.cos(a) * r0 * 0.3, math.sin(a) * r0 * 0.3, r0 * 0.9),
                   (math.cos(a) * d, math.sin(a) * d, -0.12), r0 * 0.42, r0 * 0.1, seg=4)


def pine_tier(piece, z, r, h, seed, n=10, droop=0.38, star=0.17):
    """One skirt of a pine: drooping star-shaped rim, puffy cone, tucked underside."""
    rng = random.Random(seed)
    phase = rng.uniform(0, TAU)
    rim = ring(n, r, z, phase=phase, star=star, wobble=0.06, seed=seed,
               zfn=lambda a, i: -droop if i % 2 == 0 else droop * 0.25)
    mid = ring(n, r * 0.6, z + h * 0.38, phase=phase + 0.12, star=star * 0.45, wobble=0.05, seed=seed + 1)
    apex = (rng.uniform(-0.06, 0.06) * r, rng.uniform(-0.06, 0.06) * r, z + h)
    under = (0.0, 0.0, z + h * 0.16)
    loft(piece, [apex, mid, rim, under])


def build_pine(m, rims, radii, heights, seed, trunk_r=0.62):
    m.extra["palette"] = {"Bark": P("wood_700"), "Needles": P("moss_800"), "Needles2": P("moss_700")}
    t = m.piece("Trunk", "Bark", shadow=True)
    trunk(t, rims[-1], trunk_r, trunk_r * 0.35, seed, sides=7, lean=(0.15, -0.1), flare=0.35, roots=4, root_len=0.9)
    dark = m.piece("Needles", "Needles", shadow=True)
    light = m.piece("Needles2", "Needles2", shadow=True)
    for k, (z, r, h) in enumerate(zip(rims, radii, heights)):
        pine_tier(dark if k % 2 == 0 else light, z, r, h, seed * 10 + k)


def clump(piece, centre, radii, seed, n=20, jitter=0.13, flat=None):
    cx, cy, cz = centre
    pts = blob_points(seed, n, *radii, jitter=jitter, floor=flat)
    hull(piece, [(cx + x, cy + y, cz + z) for x, y, z in pts])


def moss_pad(piece, x0, x1, y0, y1, z, seed, thick=0.14, inset=0.12):
    """Flat irregular moss pad lying on a top surface at height z."""
    rng = random.Random(seed)
    pts = []
    for zz in (z - 0.04, z + thick):
        for (x, y) in ((x0, y0), (x1, y0), (x1, y1), (x0, y1), ((x0 + x1) / 2, y0), ((x0 + x1) / 2, y1)):
            k = inset if zz > z else 0.0
            px = x + (k if x == x0 else -k if x == x1 else 0) + rng.uniform(-0.12, 0.12)
            py = y + (k if y == y0 else -k) + rng.uniform(-0.05, 0.05)
            pts.append((px, py, zz))
    hull(piece, pts)


# ------------------------------------------------------------------ trees and plants

@register("Tree_Pine", "World", "Tiered chunky pine, ~16 tall, canopy radius ~4.5. Collider = trunk.")
def tree_pine(m):
    m.extra["collider"] = {"kind": "circle", "radius": 0.9, "height": 8}
    build_pine(m, rims=[3.4, 6.0, 8.4, 10.6, 12.6], radii=[4.5, 3.8, 3.1, 2.3, 1.5],
               heights=[4.2, 3.8, 3.4, 3.0, 3.4], seed=11)


@register("Tree_PineTall", "World", "Tall pine for the tree line, ~22 tall. Collider = trunk.")
def tree_pine_tall(m):
    m.extra["collider"] = {"kind": "circle", "radius": 1.0, "height": 8}
    build_pine(m, rims=[4.4, 7.4, 10.2, 12.8, 15.2, 17.4], radii=[4.6, 4.0, 3.4, 2.75, 2.05, 1.35],
               heights=[4.6, 4.2, 3.9, 3.6, 3.3, 4.6], seed=23, trunk_r=0.7)


@register("Tree_Round", "World", "Chunky broadleaf, ~13 tall, canopy radius ~5.5. Collider = trunk.")
def tree_round(m):
    m.extra["palette"] = {"Bark": P("wood_600"), "Leaves": P("moss_700"), "Leaves2": P("moss_600")}
    m.extra["collider"] = {"kind": "circle", "radius": 1.1, "height": 8}
    t = m.piece("Trunk", "Bark", shadow=True)
    trunk(t, 8.2, 0.82, 0.38, seed=5, sides=7, lean=(0.25, 0.1), flare=0.32, roots=5, root_len=1.0)
    for a, b, r0, r1 in (((0.1, 0.0, 5.0), (2.3, 0.9, 7.7), 0.36, 0.17),
                         ((0.1, 0.0, 5.6), (-2.0, -0.9, 8.1), 0.34, 0.16),
                         ((0.15, 0.05, 6.2), (-0.2, 2.0, 8.7), 0.3, 0.14),
                         ((0.15, 0.0, 6.0), (0.6, -2.1, 8.4), 0.28, 0.13)):
        t.limb(a, b, r0, r1, seg=5)
    lo = m.piece("Leaves", "Leaves", shadow=True)
    hi = m.piece("Leaves2", "Leaves2", shadow=True)
    clump(lo, (0.1, 0.0, 8.9), (3.9, 3.7, 2.5), seed=40, n=26)
    for k in range(5):
        a = math.radians(k * 72 + 18)
        clump(lo, (math.cos(a) * 3.25, math.sin(a) * 3.0, 7.75 + (k % 2) * 0.45), (2.3, 2.15, 1.75), seed=41 + k, n=18)
    clump(hi, (0.9, 0.7, 10.75), (2.6, 2.4, 1.75), seed=50, n=22)
    clump(hi, (-1.5, -0.5, 10.45), (2.25, 2.1, 1.6), seed=51, n=20)
    clump(hi, (0.2, -1.9, 10.2), (2.0, 1.9, 1.45), seed=52, n=18)


@register("Bush", "World", "Low shrub, 3 x 2. Decoration (no collider).")
def bush(m):
    m.extra["palette"] = {"Leaves": P("moss_600"), "Leaves2": P("moss_400")}
    lo = m.piece("Leaves", "Leaves")
    hi = m.piece("Leaves2", "Leaves2")
    clump(lo, (0.0, 0.0, 0.8), (1.2, 1.0, 0.9), seed=61, n=20, flat=-0.85)
    clump(lo, (0.95, 0.3, 0.6), (0.8, 0.72, 0.68), seed=62, n=14, flat=-0.65)
    clump(lo, (-0.95, -0.2, 0.55), (0.75, 0.7, 0.62), seed=63, n=14, flat=-0.6)
    clump(hi, (0.25, -0.15, 1.35), (0.72, 0.62, 0.5), seed=64, n=14)
    clump(hi, (-0.5, 0.25, 1.15), (0.55, 0.5, 0.42), seed=65, n=12)


@register("Fern", "World", "Fern rosette, 2.5 x 1.2. Small decoration (no collider, no shadow).")
def fern(m):
    m.extra["palette"] = {"Fern": P("moss_400")}
    f = m.piece("Fronds", "Fern")
    rng = random.Random(71)
    for k in range(9):
        inner = k % 3 == 2
        a = k / 9 * TAU + rng.uniform(-0.15, 0.15)
        if inner:  # short upright fronds fill the centre
            leaf(f, (0.0, 0.0, 0.1), (math.cos(a), math.sin(a)), rng.uniform(0.7, 0.85), 0.42,
                 rise=rng.uniform(0.95, 1.1), tip_drop=0.3, thick=0.05, mid=0.5)
        else:
            leaf(f, (math.cos(a) * 0.08, math.sin(a) * 0.08, 0.05), (math.cos(a), math.sin(a)), rng.uniform(1.15, 1.3),
                 rng.uniform(0.55, 0.62), rise=rng.uniform(0.6, 0.75), tip_drop=rng.uniform(0.38, 0.5), thick=0.05, mid=0.42)


@register("GrassTuft", "World", "Grass tuft, 1.2 x 0.8. Scatter decoration (<= 40 tris).")
def grass_tuft(m):
    m.extra["palette"] = {"Grass": P("moss_300")}
    g = m.piece("Blades", "Grass")
    rng = random.Random(81)
    for k in range(9):
        a = k / 9 * TAU + rng.uniform(-0.3, 0.3)
        r = rng.uniform(0.04, 0.18)
        base = (math.cos(a) * r, math.sin(a) * r, -0.05)
        out = rng.uniform(0.25, 0.42)
        h = rng.uniform(0.38, 0.78)
        tip = (base[0] + math.cos(a) * out, base[1] + math.sin(a) * out, h)
        blade(g, base, tip, w=rng.uniform(0.15, 0.19))


@register("Flowers", "World", "Patch of small ivory flowers with leaves, 1.5 wide (<= 80 tris). "
          "Recolour slot Bloom (e.g. gold_300) for pale-gold patches.")
def flowers(m):
    m.extra["palette"] = {"Leaves": P("moss_400"), "Bloom": P("ivory_100")}
    lv = m.piece("Leaves", "Leaves")
    bl = m.piece("Blooms", "Bloom")
    rng = random.Random(91)
    for k in range(3):
        a = k / 3 * TAU + 0.4
        leaf(lv, (math.cos(a) * 0.08, math.sin(a) * 0.08, 0.0), (math.cos(a), math.sin(a)), 0.62, 0.28,
             rise=0.14, tip_drop=0.1, thick=0.03, mid=0.5)
    spots = [(0.38, 0.12, 0.5), (-0.3, 0.32, 0.4), (-0.12, -0.38, 0.46), (0.5, -0.32, 0.34)]
    for x, y, h in spots:
        blade(lv, (x * 0.4, y * 0.4, -0.02), (x, y, h - 0.02), w=0.06)
        disc = ring(5, rng.uniform(0.12, 0.14), h, phase=rng.uniform(0, TAU), cx=x, cy=y)
        loft(bl, [(x, y, h - 0.025), disc, (x, y, h - 0.09)])  # shallow open cup


@register("Mushroom", "World", "Cluster of three small forest mushrooms with muted crimson caps (~1.5 x 1). "
          "Decoration for tree shade.")
def mushroom(m):
    m.extra["palette"] = {"Stem": P("ivory_200"), "Cap": P("crimson_600")}
    st = m.piece("Stems", "Stem")
    cp = m.piece("Caps", "Cap")
    for x, y, h, r, seg, dome in ((0.18, 0.08, 0.95, 0.4, 6, True), (-0.38, -0.12, 0.66, 0.29, 5, True),
                                  (0.3, -0.38, 0.4, 0.19, 5, False)):
        lean = 0.06 if x > 0 else -0.06
        loft(st, [ring(4, r * 0.24, -0.02, cx=x, cy=y), ring(4, r * 0.18, h, cx=x + lean, cy=y)],
             cap_first=False, cap_last=False)
        cx, cy = x + lean, y
        if dome:
            loft(cp, [(cx, cy, h + r * 0.75), ring(seg, r * 0.72, h + r * 0.5, phase=0.3, cx=cx, cy=cy),
                      ring(seg, r, h + 0.02, cx=cx, cy=cy), (cx, cy, h + 0.1)])
        else:
            loft(cp, [(cx, cy, h + r * 0.85), ring(seg, r, h, cx=cx, cy=cy), (cx, cy, h + 0.06)])


# ------------------------------------------------------------------ rocks

def _rock_points(seed, n, rx, ry, rz, cx, cy, cz, floor, jitter=0.16):
    return [(cx + x, cy + y, cz + z) for x, y, z in blob_points(seed, n, rx, ry, rz, jitter=jitter, floor=floor)]


@register("Rock", "World", "Mossy grey boulder, 4.5 x 3. Collider circle.")
def rock(m):
    m.extra["palette"] = {"Stone": P("stone_500"), "Stone2": P("stone_600"), "Moss": P("moss_400")}
    m.extra["collider"] = {"kind": "circle", "radius": 2.0, "height": 3}
    main = _rock_points(21, 18, 2.15, 1.7, 1.55, -0.25, 0.1, 1.25, floor=-1.38)
    hull(m.piece("Rock", "Stone", shadow=True), main)
    side = _rock_points(22, 12, 1.05, 0.95, 0.8, 1.45, -0.55, 0.58, floor=-0.72)
    hull(m.piece("Rock2", "Stone2", shadow=True), side)
    cap_of(m.piece("Moss", "Moss"), main, plane_co=(-0.25, 0.1, 2.05), plane_no=(0.22, -0.18, 1.0),
           grow=1.045, lift=0.02, centre=(-0.25, 0.1, 1.25))


@register("Rock_Small", "World", "Small stone, ~1.5. Clutter (no collider, no shadow).")
def rock_small(m):
    m.extra["palette"] = {"Stone": P("stone_400")}
    hull(m.piece("Rock", "Stone"), _rock_points(31, 12, 0.75, 0.62, 0.5, 0, 0, 0.38, floor=-0.46))


@register("Rock_Slab", "World", "Flat stone slab, 4 x 0.8 x 3 (paths, stepping stones). Walkable, no collider.")
def rock_slab(m):
    m.extra["palette"] = {"Slab": P("stone_400"), "Moss": P("moss_500")}
    rng = random.Random(41)
    n = 8
    out = []
    for i in range(n):
        a = i / n * TAU + rng.uniform(-0.18, 0.18)
        k = 1 + rng.uniform(-0.1, 0.06)
        out.append((math.cos(a) * 1.95 * k, math.sin(a) * 1.45 * k))
    pts = [(x, y, -0.12) for x, y in out]
    pts += [(x * 0.9, y * 0.9, 0.6 + x * 0.025 + y * 0.02) for x, y in out]
    hull(m.piece("Slab", "Slab"), pts)
    moss = m.piece("Moss", "Moss")
    for (x, y, rx, ry, s) in ((1.35, 0.55, 0.65, 0.5, 42), (-1.4, -0.6, 0.55, 0.42, 43)):
        p = blob_points(s, 10, rx, ry, 0.12, jitter=0.1)
        hull(moss, [(x + px, y + py, 0.6 + x * 0.025 + y * 0.02 + 0.02 + pz) for px, py, pz in p])


# ------------------------------------------------------------------ ruins

STONE_TONES = {"Stone": P("stone_500"), "Stone2": P("stone_400"), "Stone3": P("stone_600")}


def _tone_pieces(m):
    return [m.piece("Stone", "Stone", shadow=True), m.piece("Stone2", "Stone2", shadow=True),
            m.piece("Stone3", "Stone3", shadow=True)]


def ruin_wall(m, length, depth, courses, standing, seed, fallen=()):
    """Broken wall of stone blocks in three tones with moss on the exposed tops.
    courses: course heights; standing(x) -> how many courses stand at x."""
    rng = random.Random(seed)
    m.extra["palette"] = dict(STONE_TONES, Moss=P("moss_400"))
    tones = _tone_pieces(m)
    moss = m.piece("Moss", "Moss")
    z = 0.0
    for c, h in enumerate(courses):
        x = -length / 2
        first = True
        while x < length / 2 - 0.3:
            span = rng.uniform(1.6, 2.5)
            if first and c % 2 == 1:
                span *= 0.55  # stagger the joints
            first = False
            x1 = x + span
            if length / 2 - x1 < 0.8:
                x1 = length / 2
            cx = (x + x1) / 2
            if standing(cx) > c:
                tone = rng.choices((0, 1, 2), weights=(0.45, 0.33, 0.22))[0]
                if c == 0:
                    tone = 2 if rng.random() < 0.5 else 0  # darker footing
                size = (x1 - x - 0.08, depth + rng.uniform(-0.1, 0.03), h - 0.06)
                top = c + 1 >= standing(cx)
                shift = rng.uniform(-0.05, 0.05)
                tones[tone].box(size, loc=(cx, shift, z + h / 2), rot=(rng.uniform(-1.2, 1.2), rng.uniform(-1.5, 1.5), rng.uniform(-2.0, 2.0)),
                                bevel=0.09)
                if top and rng.random() < 0.85:
                    moss_pad(moss, x + 0.12, x1 - 0.12, -size[1] / 2 - 0.05 + shift, size[1] / 2 + 0.05 + shift,
                             z + h - 0.02, seed=int(cx * 100) + c, thick=0.13)
            x = x1
        z += h
    for loc, size, rot in fallen:
        tones[rng.choice((0, 1))].box(size, loc=loc, rot=rot, bevel=0.08)


@register("Ruin_Wall", "World", "Broken stone wall, 8 x 3.5 x 1.4 (length along X). Collider box.")
def ruin_wall_big(m):
    m.extra["collider"] = {"kind": "box", "size": [8.0, 1.4], "height": 3.5}

    def standing(x):
        if x < -2.1:
            return 4
        if x < 0.9:
            return 3
        if x < 2.6:
            return 2
        return 1
    ruin_wall(m, 8.0, 1.4, [0.95, 0.9, 0.85, 0.8], standing, seed=101,
              fallen=[((3.15, -1.15, 0.3), (1.1, 0.8, 0.62), (6, -8, 28)),
                      ((1.9, 1.15, 0.24), (0.85, 0.7, 0.5), (0, 10, -16))])


@register("Ruin_WallLow", "World", "Low broken wall, 6 x 1.6 x 1.2 (length along X). Collider box.")
def ruin_wall_low(m):
    m.extra["collider"] = {"kind": "box", "size": [6.0, 1.2], "height": 1.6}

    def standing(x):
        return 2 if x < 1.2 else 1
    ruin_wall(m, 6.0, 1.2, [0.85, 0.75], standing, seed=111,
              fallen=[((2.3, -1.05, 0.22), (0.8, 0.65, 0.46), (4, 6, 22))])


@register("Pillar", "World", "Broken column on a plinth, ~1.6 wide, 5 tall. Collider circle.")
def pillar(m):
    m.extra["palette"] = {"Base": P("stone_600"), "Shaft": P("stone_400"), "Shaft2": P("stone_500"), "Moss": P("moss_400")}
    m.extra["collider"] = {"kind": "circle", "radius": 1.15, "height": 5}
    base = m.piece("Plinth", "Base", shadow=True)
    base.box((2.3, 2.3, 0.6), loc=(0, 0, 0.25), bevel=0.1)
    loft(base, [ring(10, 0.98, 0.52, phase=0.31), ring(10, 0.84, 0.86, phase=0.31)])
    shaft = m.piece("Shaft", "Shaft", shadow=True)
    shaft2 = m.piece("Shaft2", "Shaft2", shadow=True)
    loft(shaft, [ring(10, 0.78, 0.85, phase=0.31), ring(10, 0.75, 2.3, phase=0.31)])
    loft(shaft2, [ring(10, 0.76, 2.34, phase=0.31, cx=0.03), ring(10, 0.73, 3.68, phase=0.31, cx=0.03)])
    rng = random.Random(121)
    top = ring(10, 0.72, 4.45, phase=0.31, cx=0.05, cy=-0.02,
               zfn=lambda a, i: 0.42 * math.cos(a - 0.8) + rng.uniform(-0.12, 0.12))
    loft(shaft, [ring(10, 0.74, 3.72, phase=0.31, cx=0.05, cy=-0.02), top])
    moss = m.piece("Moss", "Moss")
    pts = [p for p in top] + [(x, y, 3.9) for x, y, _ in ring(10, 0.72, 0, phase=0.31, cx=0.05, cy=-0.02)]
    cap_of(moss, pts, plane_co=(0.05, -0.02, 4.55), plane_no=(0.35, 0.25, 1.0), grow=1.06, lift=0.02, centre=(0.05, -0.02, 4.2))
    for a in (0.6, 2.4, 4.1):
        moss_pad(moss, math.cos(a) * 0.9 - 0.35, math.cos(a) * 0.9 + 0.35, math.sin(a) * 0.9 - 0.3, math.sin(a) * 0.9 + 0.3,
                 0.53, seed=int(a * 10), thick=0.12, inset=0.08)
    hull(base, [(1.45 + x, -0.9 + y, 0.25 + z) for x, y, z in blob_points(122, 10, 0.4, 0.32, 0.3, floor=-0.28)])


@register("Ruin_Arch", "World", "Landmark broken arch, ~10 x 9 x 2 (span along X). Passage 5.4 wide x 4.5 tall "
          "stays open between the piers. Collider = the two piers.")
def ruin_arch(m):
    m.extra["palette"] = dict(STONE_TONES, Moss=P("moss_400"))
    m.extra["collider"] = {"kind": "multi", "shapes": [
        {"kind": "box", "size": [2.7, 2.4], "height": 7, "offset": roblox_xz(-3.95, 0)},
        {"kind": "box", "size": [2.7, 2.4], "height": 4, "offset": roblox_xz(3.95, 0)},
    ]}
    m.extra["passage"] = {"width": 5.4, "height": 4.5}
    rng = random.Random(131)
    stone, stone2, stone3 = _tone_pieces(m)
    moss = m.piece("Moss", "Moss")
    R_IN, R_OUT, S = 2.7, 3.95, 4.55  # arch radii, springline

    def blk(piece, x0, x1, z0, z1, d=1.9):
        piece.box((x1 - x0 - 0.07, d + rng.uniform(-0.08, 0.03), z1 - z0 - 0.06),
                  loc=((x0 + x1) / 2, rng.uniform(-0.04, 0.04), (z0 + z1) / 2),
                  rot=(rng.uniform(-1, 1), rng.uniform(-1, 1), rng.uniform(-1.5, 1.5)), bevel=0.09)

    for sx in (-1, 1):
        o, i = sx * 5.05, sx * 2.7  # outer and inner face of the pier
        lo, hi = min(o, i), max(o, i)
        stone3.box((hi - lo + 0.45, 2.4, 0.55), loc=((lo + hi) / 2, 0, 0.22), bevel=0.1)
        rows = ((0.5, 1.7, 0.55), (1.7, 2.85, 0.4), (2.85, 4.0, 0.62))
        if sx < 0:
            rows += ((4.0, 4.55, None),)
        for z0, z1, split in rows:
            if split is None:  # impost course, one long block
                blk(stone3, lo - 0.12, hi + 0.12, z0, z1, d=2.15)
                continue
            mid_x = lo + (hi - lo) * split
            pa, pb = (stone, stone2) if rng.random() < 0.5 else (stone2, stone)
            blk(pa, lo, mid_x, z0, z1)
            if sx > 0 and z0 > 2.5:
                continue  # the right pier's top course has fallen
            blk(pb, mid_x, hi, z0, z1)
    # wall stub above the left pier (spandrel), broken off in steps
    blk(stone, -5.05, -3.95, 4.55, 5.75)
    blk(stone2, -5.05, -4.15, 5.75, 6.85)
    blk(stone3, -5.05, -4.45, 6.85, 7.55)
    # voussoirs: the left half and the keystone still stand, the right side has fallen
    n = 9
    for k in (0, 1, 2, 3, 4):
        a0, a1 = 180 - k * 20, 180 - (k + 1) * 20
        key = k == 4
        voussoir(stone2 if k % 2 == 0 else stone, 0, S, R_IN - (0.1 if key else 0), R_OUT + (0.3 if key else 0),
                 a0 - 0.8, a1 + 0.8, -0.95 - (0.06 if key else 0), 0.95 + (0.06 if key else 0), bevel=0.08)
    for k in (1, 2, 3, 4):  # moss on the extrados
        a = math.radians(180 - (k + 0.5) * 20)
        pts = []
        for y in (-0.82, 0.82):
            for da in (-8, 8):
                aa = a + math.radians(da)
                for dr in (-0.06, 0.12):
                    pts.append((math.cos(aa) * (R_OUT + dr), y + rng.uniform(-0.08, 0.08), S + math.sin(aa) * (R_OUT + dr)))
        hull(moss, pts)
    moss_pad(moss, -5.0, -4.5, -0.95, 0.95, 7.49, seed=133, thick=0.13, inset=0.08)
    moss_pad(moss, 3.0, 4.6, -0.95, 0.95, 2.79, seed=134, thick=0.13)
    # fallen stones at the right foot
    stone2.box((1.25, 1.9, 0.8), loc=(1.4, -1.7, 0.32), rot=(4, -6, 32), bevel=0.09)
    stone.box((1.0, 1.4, 0.65), loc=(6.2, 0.9, 0.26), rot=(-3, 8, -18), bevel=0.09)


@register("Ruin_Block", "World", "Fallen carved block, ~2.4, tilted and half sunk, with moss. Collider circle.")
def ruin_block(m):
    from mathutils import Euler, Matrix, Vector
    m.extra["palette"] = {"Stone": P("stone_500"), "Trim": P("stone_400"), "Moss": P("moss_400"), "Stone2": P("stone_600")}
    m.extra["collider"] = {"kind": "circle", "radius": 1.3, "height": 1.6}
    rot = (4, -10, 22)
    M = Matrix.Translation((0, 0, 0.5)) @ Euler([math.radians(a) for a in rot]).to_matrix().to_4x4()
    blk = m.piece("Block", "Stone", shadow=True)
    blk.box((2.4, 1.5, 1.25), loc=(0, 0, 0.5), rot=rot, bevel=0.1)
    band = m.piece("Band", "Trim")
    band.box((2.46, 1.56, 0.26), loc=tuple(M @ Vector((0, 0, 0.18))), rot=rot, bevel=0.05)  # carved moulding band
    moss = m.piece("Moss", "Moss")
    pts = [tuple(M @ Vector(p)) for p in ((-1.15, -0.7, 0.6), (0.2, -0.72, 0.6), (0.5, 0.0, 0.6), (0.1, 0.72, 0.6),
                                            (-1.15, 0.72, 0.6), (-1.15, -0.7, 0.75), (0.05, -0.55, 0.75), (0.25, 0.1, 0.75),
                                            (-0.1, 0.6, 0.75), (-1.0, 0.55, 0.75))]
    hull(moss, pts)
    hull(m.piece("Chunk", "Stone2"), [(1.45 + x, 0.85 + y, 0.18 + z) for x, y, z in blob_points(141, 10, 0.45, 0.36, 0.32, floor=-0.28)])


# ------------------------------------------------------------------ fences, banners, lights

@register("Fence_Section", "World", "Weathered post-and-rail fence, 8 long (X) x 2.6 tall. Collider box.")
def fence_section(m):
    m.extra["palette"] = {"Post": P("wood_600"), "Rail": mix("wood_500", "stone_400", 0.22)}
    m.extra["collider"] = {"kind": "box", "size": [8.0, 0.5], "height": 2.6}
    posts = m.piece("Posts", "Post")
    rails = m.piece("Rails", "Rail")
    for x, h, tilt in ((-3.75, 2.6, (2, -1.5, 3)), (0.0, 2.45, (-1.5, 2, -4)), (3.75, 2.55, (1, 2.5, 2))):
        posts.box((0.42, 0.42, h + 0.2), loc=(x, 0, (h + 0.2) / 2 - 0.2), rot=tilt, bevel=0.06, taper=(0.86, 0.86))
    for (x0, x1, z0, z1) in ((-3.95, 0.2, 1.88, 1.8), (-3.95, 0.2, 0.98, 1.02), (-0.2, 3.95, 1.82, 1.9), (-0.2, 2.6, 0.98, 0.62)):
        length = x1 - x0
        ang = math.degrees(math.atan2(z1 - z0, length))
        rails.box((math.hypot(length, z1 - z0), 0.17, 0.27), loc=((x0 + x1) / 2, -0.29, (z0 + z1) / 2),
                  rot=(0, -ang, 0), bevel=0.05)


def crown_profile(w=1.0, h=0.8):
    """Outline (x, z) of a three-pointed crown, base at z = 0, centred on x = 0."""
    s = w / 1.0
    return [(-0.5 * s, 0.0), (0.5 * s, 0.0), (0.5 * s, 0.24 * h / 0.8), (0.58 * s, 0.74 * h / 0.8),
            (0.27 * s, 0.4 * h / 0.8), (0.0, 0.82 * h / 0.8), (-0.27 * s, 0.4 * h / 0.8),
            (-0.58 * s, 0.74 * h / 0.8), (-0.5 * s, 0.24 * h / 0.8)]


def crown_plate(piece, cx, cz, y_face, w, h, depth=0.06, outward=-1):
    """Crown emblem lying on a vertical face at y = y_face, standing out toward `outward` (-1 = -Y)."""
    prof = [(cx + x, cz + z) for x, z in crown_profile(w, h)]
    y0, y1 = y_face, y_face + outward * depth
    prism_xz(piece, prof, min(y0, y1), max(y0, y1))


@register("Banner", "World", "Pole banner ~9 tall: slate-blue cloth with a gold crown (both faces). Front = -Y.")
def banner(m):
    m.extra["palette"] = {"Wood": P("wood_600"), "Cloth": P("slate_600"), "Gold": P("gold_500")}
    m.extra["collider"] = {"kind": "circle", "radius": 0.35, "height": 9}
    pole = m.piece("Pole", "Wood")
    loft(pole, [ring(6, 0.2, -0.1), ring(6, 0.17, 8.75)])
    pole.box((2.9, 0.2, 0.2), loc=(0, 0, 8.3), bevel=0.05)
    pole.box((0.5, 0.5, 0.35), loc=(0, 0, 0.12), bevel=0.06, taper=(0.75, 0.75))
    gold = m.piece("Gold", "Gold")
    loft(gold, [(0, 0, 9.45), ring(4, 0.16, 9.05, phase=math.radians(45)), ring(4, 0.12, 8.72, phase=math.radians(45))])
    for x in (-1.5, 1.5):
        gold.ico(0.13, loc=(x, 0, 8.3), subdiv=1)
    cloth = m.piece("Cloth", "Cloth")
    w, top, length, y0 = 2.35, 8.12, 4.7, -0.12
    xs = [-w / 2 + w * i / 6 for i in range(7)]

    def tail(x):  # swallowtail: the bottom edge rises toward the middle
        return top - length + 0.6 * (1 - min(1.0, abs(x) / (w / 2)))

    def wave(x):
        return 0.05 * math.sin(x * 2.6)
    sheet(cloth, xs, lambda x: top, tail, wave, 0.1, y0=y0)
    sheet(gold, xs, lambda x: top - 0.22, lambda x: top - 0.46, wave, 0.14, y0=y0)
    for side in (-1, 1):  # crown on both faces, sunk into the cloth so the wave never covers it
        crown_plate(gold, 0, 5.85, y0 - side * 0.02, 0.95, 0.78, depth=0.14, outward=side)


@register("Torch", "World", "Standing torch post ~5 tall with an iron fire bowl and a small flame.")
def torch(m):
    m.extra["palette"] = {"Wood": P("wood_600"), "Iron": P("steel_700"), "Flame": P("fx_fire"), "Core": P("gold_300")}
    m.extra["light"] = light_at(0, 0, 4.95)
    m.extra["collider"] = {"kind": "circle", "radius": 0.35, "height": 4.5}
    post = m.piece("Post", "Wood")
    loft(post, [ring(6, 0.24, -0.1), ring(6, 0.19, 1.2), ring(6, 0.17, 4.0)])
    post.box((0.62, 0.62, 0.3), loc=(0, 0, 0.1), bevel=0.06, taper=(0.7, 0.7))
    iron = m.piece("Bowl", "Iron", "Metal")
    loft(iron, [ring(6, 0.2, 2.6), ring(6, 0.23, 2.75)])  # iron collar half way up
    loft(iron, [ring(8, 0.16, 3.9), ring(8, 0.42, 4.08), ring(8, 0.6, 4.38), ring(8, 0.63, 4.5),
                ring(8, 0.5, 4.5), ring(8, 0.3, 4.3)])
    for k in range(4):
        a = k * TAU / 4 + TAU / 8
        iron.spike(0.07, 0.32, seg=3, base=(math.cos(a) * 0.58, math.sin(a) * 0.58, 4.45), direction=(math.cos(a) * 0.3, math.sin(a) * 0.3, 1))
    fl = m.piece("Flame", "Flame", "Neon")
    flame(fl, (0, 0, 4.25), 0.36, 1.05, seg=5, lean=(0.05, -0.03))
    flame(fl, (0.18, 0.1, 4.3), 0.2, 0.65, seg=4, twist=40, lean=(0.12, 0.06))
    flame(fl, (-0.16, -0.1, 4.3), 0.2, 0.7, seg=4, twist=-30, lean=(-0.1, -0.05))
    core = m.piece("FlameCore", "Core", "Neon")
    flame(core, (0, 0, 4.35), 0.17, 1.15, seg=4, twist=20, lean=(0.04, 0.0))


@register("Lantern_Post", "World", "Wooden lantern post ~7 tall; the lantern hangs from an arm toward +X "
          "(Roblox -X). Warm Neon core.")
def lantern_post(m):
    m.extra["palette"] = {"Wood": P("wood_600"), "Iron": P("steel_800"), "Glass": P("gold_300"), "Core": P("amber_300")}
    m.extra["collider"] = {"kind": "circle", "radius": 0.4, "height": 7}
    lx = 1.55  # lantern centre line
    m.extra["light"] = light_at(lx, 0, 4.95)
    post = m.piece("Post", "Wood")
    post.box((0.62, 0.62, 0.55), loc=(0, 0, 0.2), bevel=0.07, taper=(0.82, 0.82))
    post.box((0.42, 0.42, 6.55), loc=(0, 0, 3.4), bevel=0.06)
    post.box((0.5, 0.5, 0.3), loc=(0, 0, 6.75), bevel=0.06, taper=(0.4, 0.4))
    post.box((2.1, 0.3, 0.3), loc=(0.85, 0, 6.15), bevel=0.05)
    post.limb((0.15, 0, 5.2), (1.05, 0, 6.05), 0.1, 0.1, seg=4)
    iron = m.piece("Iron", "Iron", "Metal")
    iron.box((0.08, 0.08, 0.34), loc=(lx, 0, 5.85), bevel=0.0)
    q = math.radians(45)
    loft(iron, [(lx, 0, 5.74), ring(4, 0.36, 5.45, phase=q, cx=lx), ring(4, 0.36, 5.38, phase=q, cx=lx)])
    iron.box((0.46, 0.46, 0.1), loc=(lx, 0, 4.55), bevel=0.02)
    for k in range(4):
        a = math.radians(45 + 90 * k)
        iron.box((0.06, 0.06, 0.82), loc=(lx + math.cos(a) * 0.28, math.sin(a) * 0.28, 4.99), bevel=0.0)
    glass = m.piece("Glass", "Glass", transparency=0.45)
    glass.box((0.42, 0.42, 0.78), loc=(lx, 0, 4.99), bevel=0.0)
    core = m.piece("Core", "Core", "Neon")
    loft(core, [(lx, 0, 4.64), ring(4, 0.11, 4.82, cx=lx), ring(4, 0.06, 5.02, phase=0.5, cx=lx), (lx, 0, 5.2)])


# ------------------------------------------------------------------ props

@register("Barrel", "World", "Wooden barrel, 1.6 x 2. Collider circle.")
def barrel(m):
    m.extra["palette"] = {"Wood": P("wood_500"), "Iron": P("steel_700"), "Lid": P("wood_600")}
    m.extra["collider"] = {"kind": "circle", "radius": 0.8, "height": 2}
    staves = m.piece("Staves", "Wood", shadow=True)
    n = 12
    loft(staves, [ring(n, 0.64, 0.0), ring(n, 0.74, 0.32), ring(n, 0.8, 1.0), ring(n, 0.74, 1.68), ring(n, 0.66, 2.0),
                  ring(n, 0.58, 2.0), ring(n, 0.58, 1.9)])
    hoops = m.piece("Hoops", "Iron", "Metal")
    for z, r in ((0.32, 0.755), (1.68, 0.755), (0.82, 0.81), (1.18, 0.81)):
        loft(hoops, [ring(n, r, z - 0.07), ring(n, r, z + 0.07)])
    lid = m.piece("Lid", "Lid")
    loft(lid, [ring(n, 0.585, 1.88), ring(n, 0.585, 1.93)])
    lid.box((0.95, 0.12, 0.06), loc=(0, 0.1, 1.95), bevel=0.0)


@register("Crate", "World", "Wooden supply crate, 2 x 2 x 2. Collider box.")
def crate(m):
    m.extra["palette"] = {"Wood": P("wood_500"), "Frame": P("wood_700")}
    m.extra["collider"] = {"kind": "box", "size": [2.0, 2.0], "height": 2}
    body = m.piece("Body", "Wood", shadow=True)
    body.box((1.84, 1.84, 1.84), loc=(0, 0, 0.94), bevel=0.05)
    fr = m.piece("Frame", "Frame")
    e, t = 1.0, 0.22
    for z in (0.11, 1.89):
        for (sx, sy, x, y) in ((2.0, t, 0, -e + t / 2), (2.0, t, 0, e - t / 2), (t, 2.0 - 2 * t, -e + t / 2, 0), (t, 2.0 - 2 * t, e - t / 2, 0)):
            fr.box((sx, sy, t), loc=(x, y, z), bevel=0.0)
    for x in (-e + t / 2, e - t / 2):
        for y in (-e + t / 2, e - t / 2):
            fr.box((t, t, 1.56), loc=(x, y, 1.0), bevel=0.0)
    for (rot, loc) in (((0, 45, 0), (0, -0.93, 1.0)), ((0, -45, 0), (0, 0.93, 1.0)),
                       ((0, 45, 90), (-0.93, 0, 1.0)), ((0, -45, 90), (0.93, 0, 1.0))):
        fr.box((2.05, 0.12, 0.2), loc=loc, rot=rot, bevel=0.0)


@register("Log", "World", "Fallen log, 7 long (X) x 1.4. Collider box.")
def log(m):
    m.extra["palette"] = {"Bark": P("wood_600"), "Heart": P("dirt_300"), "Moss": P("moss_400")}
    m.extra["collider"] = {"kind": "box", "size": [7.0, 1.4], "height": 1.4}
    bark = m.piece("Bark", "Bark", shadow=True)
    n = 8
    stations = [(-3.45, 0.58, 0.0, 0.6), (-1.6, 0.68, 0.06, 0.68), (0.6, 0.7, -0.05, 0.69), (2.4, 0.64, 0.04, 0.63), (3.45, 0.6, 0.0, 0.6)]
    rings = []
    for x, r, y, z in stations:
        pts = []
        for i in range(n):
            a = i / n * TAU + 0.2
            pts.append((x, y + math.cos(a) * r, z + math.sin(a) * r))
        rings.append(pts)
    loft(bark, rings)
    bark.limb((0.9, 0.1, 1.1), (1.6, 0.55, 2.0), 0.26, 0.14, seg=5)
    heart = m.piece("Ends", "Heart")
    for x, r, y, z, sgn in ((-3.45, 0.5, 0.0, 0.6, -1), (3.45, 0.52, 0.0, 0.6, 1)):
        pts = []
        for xx in (x - sgn * 0.02, x + sgn * 0.05):
            for i in range(n):
                a = i / n * TAU + 0.2
                pts.append((xx, y + math.cos(a) * r, z + math.sin(a) * r))
        hull(heart, pts)
    moss = m.piece("Moss", "Moss")
    for x0, x1, s in ((-2.9, -1.0, 151), (0.1, 1.9, 152)):
        pts = []
        for x in (x0, (x0 + x1) / 2, x1):
            for a in (60, 90, 120):
                aa = math.radians(a)
                for dr in (-0.06, 0.1):
                    r = 0.69 + dr
                    pts.append((x + random.Random(s + a).uniform(-0.15, 0.15), math.cos(aa) * r, 0.64 + math.sin(aa) * r))
        hull(moss, pts)


@register("Stump", "World", "Tree stump, 1.8 x 1.2. Collider circle.")
def stump(m):
    m.extra["palette"] = {"Bark": P("wood_600"), "Heart": P("dirt_300"), "Moss": P("moss_400")}
    m.extra["collider"] = {"kind": "circle", "radius": 0.85, "height": 1.2}
    bark = m.piece("Bark", "Bark", shadow=True)
    rng = random.Random(161)
    n = 8
    loft(bark, [ring(n, 0.95, -0.08, star=0.2, phase=0.2), ring(n, 0.74, 0.3, phase=0.2, star=0.06),
                ring(n, 0.66, 1.0, phase=0.2, zfn=lambda a, i: rng.uniform(-0.05, 0.12)),
                ring(n, 0.56, 1.02, phase=0.2)])
    for k in range(4):
        a = k * TAU / 4 + 0.5
        bark.limb((math.cos(a) * 0.4, math.sin(a) * 0.4, 0.45), (math.cos(a) * 1.05, math.sin(a) * 1.05, -0.1), 0.24, 0.06, seg=4)
    top = m.piece("Top", "Heart")
    loft(top, [ring(n, 0.57, 0.98, phase=0.2), ring(n, 0.57, 1.06, phase=0.2)])
    moss = m.piece("Moss", "Moss")
    hull(moss, [(0.42 + x, -0.38 + y, 1.04 + z) for x, y, z in blob_points(162, 10, 0.32, 0.26, 0.08, jitter=0.1)])
    hull(moss, [(-0.7 + x, 0.35 + y, 0.18 + z) for x, y, z in blob_points(163, 10, 0.42, 0.34, 0.22, floor=-0.2)])


@register("CrystalCluster", "World", "Restrained arcane crystal cluster, ~3 x 3, slate-blue and ivory with a tiny glow.")
def crystal_cluster(m):
    m.extra["palette"] = {"Stone": P("stone_600"), "Crystal": P("slate_400"), "Crystal2": P("slate_200"), "Glow": P("fx_arcane")}
    m.extra["collider"] = {"kind": "circle", "radius": 1.2, "height": 2.5}
    m.extra["light"] = light_at(0.15, -0.35, 0.6)
    base = m.piece("Base", "Stone")
    hull(base, [(x, y, 0.2 + z) for x, y, z in blob_points(171, 16, 1.45, 1.25, 0.45, floor=-0.32)])
    c1 = m.piece("Crystals", "Crystal")
    c2 = m.piece("Crystals2", "Crystal2")
    from mathutils import Euler, Vector

    def crystal(piece, x, y, h, r, tilt, yaw):
        rot = Euler((math.radians(tilt[0]), math.radians(tilt[1]), math.radians(yaw))).to_matrix()
        base_ring = [tuple(rot @ Vector(p) + Vector((x, y, 0.1))) for p in ring(6, r, 0.0)]
        top_ring = [tuple(rot @ Vector(p) + Vector((x, y, 0.1))) for p in ring(6, r * 0.88, h * 0.72)]
        apex = tuple(rot @ Vector((0, 0, h)) + Vector((x, y, 0.1)))
        loft(piece, [base_ring, top_ring, apex])

    crystal(c1, 0.0, 0.1, 2.5, 0.36, (-6, 4), 10)
    crystal(c2, 0.55, 0.3, 1.7, 0.27, (-14, 22), 40)
    crystal(c1, -0.6, 0.25, 1.55, 0.26, (-10, -24), 5)
    crystal(c2, -0.2, -0.55, 1.2, 0.22, (24, -8), 25)
    crystal(c1, 0.75, -0.45, 0.95, 0.2, (20, 26), 15)
    glow = m.piece("Glow", "Glow", "Neon")
    crystal(glow, 0.2, -0.3, 0.65, 0.09, (16, 10), 0)


@register("Shrine", "World", "Small mossy standing stone with a carved gold sigil, ~3 x 5 x 2. Front = -Y. Collider box.")
def shrine(m):
    m.extra["palette"] = {"Stone": P("stone_500"), "Base": P("stone_600"), "Gold": P("gold_500"), "Moss": P("moss_400")}
    m.extra["collider"] = {"kind": "box", "size": [3.0, 2.0], "height": 5}
    base = m.piece("Plinth", "Base", shadow=True)
    base.box((3.0, 2.0, 0.45), loc=(0, 0, 0.18), bevel=0.08)
    base.box((2.25, 1.5, 0.36), loc=(0, 0.05, 0.56), bevel=0.07)
    stone = m.piece("Stone", "Stone", shadow=True)

    def oct_ring(w, d, z, c=0.18):
        hw, hd = w / 2, d / 2
        return [(-hw + c, -hd, z), (hw - c, -hd, z), (hw, -hd + c, z), (hw, hd - c, z),
                (hw - c, hd, z), (-hw + c, hd, z), (-hw, hd - c, z), (-hw, -hd + c, z)]
    lean = 0.08
    rings = [oct_ring(1.62, 0.92, 0.7), oct_ring(1.55, 0.86, 2.2), oct_ring(1.38, 0.78, 3.7),
             [(x + lean, y, z) for x, y, z in oct_ring(1.08, 0.66, 4.45, c=0.3)]]
    rings.append((lean + 0.06, 0.02, 4.95))
    loft(stone, rings)
    gold = m.piece("Sigil", "Gold")
    # sigil: a ring with a four-point star, on the front face (y = -0.46 at z ~ 2.9; the face leans back)
    zc = 2.85
    face = -0.43 + (zc - 2.2) * (0.04 / 1.5)  # the front face leans back slightly
    yb, yf = face + 0.015, face - 0.05  # sunk into the face so it never floats
    for i in range(12):
        a0, a1 = i / 12 * TAU, (i + 1) / 12 * TAU
        pts = []
        for a in (a0, a1):
            for r in (0.3, 0.42):
                for yy in (yb, yf):
                    pts.append((math.cos(a) * r, yy, zc + math.sin(a) * r))
        hull(gold, pts)
    star = []
    for i in range(8):
        a = i / 8 * TAU + TAU / 4
        r = 0.27 if i % 2 == 0 else 0.08
        star.append((math.cos(a) * r, zc + math.sin(a) * r))
    prism_xz(gold, star, yf, yb)
    moss = m.piece("Moss", "Moss")
    top_pts = [p for p in rings[3]] + [rings[4]] + [(x, y, 4.1) for x, y, _ in oct_ring(1.2, 0.7, 0)]
    cap_of(moss, top_pts, plane_co=(0.05, 0, 4.48), plane_no=(-0.3, 0.2, 1.0), grow=1.07, lift=0.02, centre=(0.05, 0, 4.3))
    moss_pad(moss, 0.75, 1.42, -0.95, -0.35, 0.39, seed=181, thick=0.12, inset=0.06)
    moss_pad(moss, -1.42, -0.85, 0.3, 0.95, 0.39, seed=182, thick=0.12, inset=0.06)
