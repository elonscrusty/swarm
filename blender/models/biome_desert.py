"""Desert biome kit: layered sandstone rocks and a mesa landmark, saguaro cacti, dunes,
sandstone ruins, a gold-glyph obelisk landmark, bones, a quicksand pool and a nomad tent.

Same conventions as world.py: origin = ground centre, front = -Y (Roblox -Z), colours from the
shared palette (sand_* tans, clay_* terracotta; muted greens for cacti, crimson/gold accents).
Extras: collider on deliberate obstacles only. Quicksand is a walkable flat hazard visual: the
game owns the hazard radius.
"""

import math
import random

from swarmkit import register
from style import P, mix

from ._biomekit import block_wall, flat_patch, pad, rock_points
from ._propkit import TAU, blob_points, cap_of, hull, loft, prism_xz, ring, roblox_xz


def strata(piece, cx, cy, r, z0, z1, seed, n=10, wobble=0.1, inset=0.94, phase=0.0):
    """One wobbly vertical rock band (sandstone layer), slightly narrower at the top."""
    rng = random.Random(seed)
    ks = [1 + rng.uniform(-wobble, wobble) for _ in range(n)]
    lo = [(cx + math.cos(phase + i / n * TAU) * r * ks[i], cy + math.sin(phase + i / n * TAU) * r * ks[i], z0) for i in range(n)]
    hi = [(cx + math.cos(phase + i / n * TAU) * r * ks[i] * inset, cy + math.sin(phase + i / n * TAU) * r * ks[i] * inset, z1)
          for i in range(n)]
    loft(piece, [lo, hi])
    return hi


def sand_heap(piece, x, y, rx, ry, h, seed):
    hull(piece, [(x + px, y + py, pz - 0.03) for px, py, pz in blob_points(seed, 12, rx, ry, h, jitter=0.1, floor=0.0)])


# ------------------------------------------------------------------ rocks

@register("Desert_Rock", "Desert", "Layered sandstone rock, ~4.4 x 2.8, terracotta and tan bands. Collider circle.")
def desert_rock(m):
    m.extra["palette"] = {"Rock": P("sand_500"), "Band": P("clay_500"), "Top": P("sand_400")}
    m.extra["collider"] = {"kind": "circle", "radius": 2.0, "height": 2.8}
    a = m.piece("Rock", "Rock", shadow=True)
    b = m.piece("Band", "Band", shadow=True)
    t = m.piece("Top", "Top", shadow=True)
    strata(a, 0, 0, 2.15, -0.1, 0.95, 701, n=9, wobble=0.12, inset=0.95)
    strata(b, 0.1, 0.05, 1.9, 0.95, 1.6, 702, n=9, wobble=0.12, inset=0.93, phase=0.2)
    strata(t, 0.25, 0.1, 1.55, 1.6, 2.45, 703, n=8, wobble=0.14, inset=0.8, phase=0.4)
    hull(a, rock_points(704, 10, 0.8, 0.65, 0.5, 2.0, -1.1, 0.35, floor=-0.4))


@register("Desert_Mesa", "Desert", "Landmark mesa: a stepped butte of striped sandstone layers with a flat sand-capped "
          "top and fallen boulders, ~13 x 8.5 tall. Collider circle.")
def desert_mesa(m):
    m.extra["palette"] = {"Talus": P("sand_600"), "Clay": P("clay_600"), "Clay2": P("clay_500"), "Sand": P("sand_500"),
                          "Cap": P("sand_300")}
    m.extra["collider"] = {"kind": "circle", "radius": 5.6, "height": 8.5}
    talus = m.piece("Talus", "Talus", shadow=True)
    clay = m.piece("Clay", "Clay", shadow=True)
    clay2 = m.piece("Clay2", "Clay2", shadow=True)
    sand = m.piece("Sand", "Sand", shadow=True)
    cap = m.piece("Cap", "Cap", shadow=True)
    hull(talus, [(x * 1.1, y, z) for x, y, z in blob_points(711, 26, 6.4, 5.4, 1.7, jitter=0.12, floor=0.0)])
    # main butte: bands that step in and overhang, leaning back (+Y) as they rise
    bands = [(clay, 5.2, 0.8, 2.0, 1.0), (sand, 4.9, 2.0, 3.6, 0.93), (clay2, 4.55, 3.6, 4.4, 1.04),
             (sand, 4.3, 4.4, 6.4, 0.9), (clay, 3.7, 6.4, 7.3, 1.03)]
    top = None
    for k, (pc, r, z0, z1, inset) in enumerate(bands):
        top = strata(pc, -0.6 + 0.12 * k, 0.35 * k, r, z0, z1, 712 + k, n=11, wobble=0.15, inset=inset, phase=0.25 * k)
    loft(cap, [top, [(x, y, 7.65) for x, y, _ in top]])
    # lower shoulder at the front-right gives an asymmetric, stepped silhouette
    t2 = None
    for k, (pc, r, z0, z1) in enumerate(((sand, 2.9, 0.8, 2.4), (clay2, 2.6, 2.4, 3.3), (sand, 2.3, 3.3, 4.1))):
        t2 = strata(pc, 3.6, -2.0, r, z0, z1, 730 + k, n=9, wobble=0.16, inset=0.95, phase=0.3 * k)
    loft(cap, [t2, [(x, y, 4.35) for x, y, _ in t2]])
    # fallen boulders and a notch of talus at the front
    for x, y, s, seed, pc in ((-5.6, -3.6, 1.0, 721, sand), (-4.2, -4.8, 0.65, 722, clay2), (5.4, -3.2, 0.8, 723, clay),
                              (6.4, 1.8, 0.7, 724, sand)):
        hull(pc, rock_points(seed, 10, s * 1.2, s, s * 0.8, x, y, s * 0.55, floor=-s * 0.6))


# ------------------------------------------------------------------ cacti

CACTUS = {"Cactus": mix("moss_600", "murk_500", 0.3), "Rib": mix("moss_500", "murk_400", 0.3), "Bloom": P("crimson_300")}


def cactus_column(piece, x, y, z0, z1, r, n=8):
    loft(piece, [ring(n, r * 1.02, z0, cx=x, cy=y, star=0.12), ring(n, r, z1 - r * 0.6, cx=x, cy=y, star=0.12),
                 ring(n, r * 0.7, z1 - r * 0.15, cx=x, cy=y, star=0.1), (x, y, z1)])


def cactus_arm(piece, side, z, out, up, r, yaw=0.0):
    """Elbow arm: out from the trunk at height z, then up."""
    c, s = math.cos(yaw) * side, math.sin(yaw) * side
    a = (c * 0.2, s * 0.2, z)
    b = (c * out, s * out, z + r * 0.4)
    piece.limb(a, b, r * 0.9, r, seg=7)
    cactus_column(piece, b[0], b[1], z - r * 0.2, z + up, r, n=7)


@register("Cactus", "Desert", "Saguaro cactus ~4.2 tall with two arms and a crimson bloom. Collider circle.")
def cactus(m):
    m.extra["palette"] = dict(CACTUS)
    m.extra["collider"] = {"kind": "circle", "radius": 0.6, "height": 4}
    body = m.piece("Body", "Cactus", shadow=True)
    cactus_column(body, 0, 0, -0.1, 4.2, 0.55)
    cactus_arm(body, 1, 1.6, 1.15, 1.5, 0.36, yaw=0.3)
    cactus_arm(body, -1, 2.2, 0.95, 1.15, 0.3, yaw=-0.2)
    bl = m.piece("Bloom", "Bloom")
    for x, y, z in ((0.0, 0.0, 4.15), (1.1, 0.35, 3.25)):
        loft(bl, [ring(5, 0.1, z - 0.05, cx=x, cy=y), ring(5, 0.2, z + 0.12, cx=x, cy=y, star=0.4), (x, y, z + 0.08)])


@register("Cactus_Tall", "Desert", "Tall saguaro ~7 tall with three arms. Collider circle.")
def cactus_tall(m):
    m.extra["palette"] = dict(CACTUS)
    m.extra["collider"] = {"kind": "circle", "radius": 0.75, "height": 7}
    body = m.piece("Body", "Cactus", shadow=True)
    cactus_column(body, 0, 0, -0.1, 7.0, 0.7)
    cactus_arm(body, 1, 2.6, 1.4, 2.3, 0.45, yaw=0.2)
    cactus_arm(body, -1, 3.6, 1.25, 1.9, 0.42, yaw=-0.35)
    cactus_arm(body, 1, 4.4, 1.0, 1.3, 0.34, yaw=-1.3)
    bl = m.piece("Bloom", "Bloom")
    for x, y, z in ((0.0, 0.0, 6.95), (0.1, 0.25, 6.85)):
        loft(bl, [ring(5, 0.12, z - 0.05, cx=x, cy=y), ring(5, 0.22, z + 0.12, cx=x, cy=y, star=0.4), (x, y, z + 0.08)])


# ------------------------------------------------------------------ dunes, ruins, landmark

@register("Dune", "Desert", "Wind-shaped sand dune mound ~9 x 5.5 x 1.5 with a lit crest. Decoration (no collider).")
def dune(m):
    m.extra["palette"] = {"Sand": P("sand_400"), "Crest": P("sand_300")}
    pts = []
    for x, y, z in blob_points(731, 26, 4.5, 2.7, 1.5, jitter=0.08, floor=0.0):
        z = max(0.0, z)
        if y < 0:
            z *= 0.6  # long windward slope toward -Y, steep lee side
        pts.append((x, y + (0.4 if z > 0.8 else 0.0), z - 0.04))
    hull(m.piece("Dune", "Sand"), pts)
    cap_of(m.piece("Crest", "Crest"), pts, plane_co=(0, 0.3, 0.8), plane_no=(0.0, -0.6, 1.0), grow=1.02, lift=0.02,
           centre=(0, 0.2, 0.3))


SANDSTONE = {"Stone": P("sand_400"), "Stone2": P("sand_300"), "Stone3": P("sand_500"), "Sand": P("sand_400"),
             "Band": P("clay_500")}


@register("Desert_Ruin_Pillar", "Desert", "Broken sandstone column on a plinth with a terracotta band and a sand drift, "
          "~2.6 wide, 5.2 tall. Collider circle.")
def desert_ruin_pillar(m):
    m.extra["palette"] = {"Base": P("sand_500"), "Shaft": P("sand_300"), "Shaft2": P("sand_400"), "Band": P("clay_500"),
                          "Sand": P("sand_400")}
    m.extra["collider"] = {"kind": "circle", "radius": 1.15, "height": 5}
    base = m.piece("Plinth", "Base", shadow=True)
    base.box((2.3, 2.3, 0.6), loc=(0, 0, 0.25), bevel=0.1)
    shaft = m.piece("Shaft", "Shaft", shadow=True)
    shaft2 = m.piece("Shaft2", "Shaft2", shadow=True)
    loft(shaft, [ring(10, 0.8, 0.5, phase=0.31, star=0.06), ring(10, 0.77, 2.2, phase=0.31, star=0.06)])
    loft(shaft2, [ring(10, 0.77, 2.5, phase=0.31, star=0.06), ring(10, 0.74, 3.75, phase=0.31, star=0.06)])
    band = m.piece("Band", "Band")
    loft(band, [ring(10, 0.82, 2.18, phase=0.31), ring(10, 0.82, 2.52, phase=0.31)])
    rng = random.Random(741)
    top = ring(10, 0.72, 4.6, phase=0.31, star=0.06, zfn=lambda a, i: 0.45 * math.cos(a + 2.2) + rng.uniform(-0.12, 0.12))
    loft(shaft, [ring(10, 0.74, 3.75, phase=0.31, star=0.06), top])
    sand = m.piece("Sand", "Sand")
    sand_heap(sand, -0.9, -0.9, 1.4, 0.9, 0.6, 742)
    sand_heap(sand, 1.0, 0.9, 1.0, 0.8, 0.45, 743)
    hull(base, rock_points(744, 10, 0.45, 0.38, 0.32, 1.6, -1.1, 0.25, floor=-0.28))


@register("Desert_Ruin_Wall", "Desert", "Broken sandstone block wall half buried in sand, 8 x 3.4 x 1.4 (length along X), "
          "terracotta course. Collider box.")
def desert_ruin_wall(m):
    m.extra["palette"] = dict(SANDSTONE)
    m.extra["collider"] = {"kind": "box", "size": [8.0, 1.4], "height": 3.4}
    tones = [m.piece("Stone", "Stone", shadow=True), m.piece("Stone2", "Stone2", shadow=True),
             m.piece("Stone3", "Stone3", shadow=True)]

    def standing(x):
        return 4 if x < -1.8 else 3 if x < 1.2 else 2 if x < 2.8 else 1
    block_wall(m, tones, None, 8.0, 1.4, [0.95, 0.85, 0.85, 0.8], standing, seed=751,
               fallen=[((3.3, -1.2, 0.3), (1.1, 0.8, 0.62), (6, -8, 28)), ((-3.9, 1.3, 0.25), (0.9, 0.7, 0.5), (0, 10, -16))])
    band = m.piece("Band", "Band")
    band.box((5.9, 1.48, 0.2), loc=(-1.0, 0, 1.9), bevel=0.04)
    sand = m.piece("Sand", "Sand")
    sand_heap(sand, -2.0, -1.0, 2.6, 0.9, 0.9, 752)
    sand_heap(sand, 1.6, 1.1, 2.2, 0.8, 0.7, 753)
    sand_heap(sand, 3.2, -0.8, 1.2, 0.8, 0.45, 754)


@register("Desert_Obelisk", "Desert", "Landmark sandstone obelisk ~11 tall on a three-step plinth, gold pyramidion and gold "
          "glyph columns on every face. Front = -Y. Collider box.")
def desert_obelisk(m):
    m.extra["palette"] = {"Base": P("sand_500"), "Base2": P("sand_400"), "Shaft": P("sand_300"), "Gold": P("gold_500"),
                          "Sand": P("sand_400"), "Band": P("clay_500")}
    m.extra["collider"] = {"kind": "box", "size": [3.2, 3.2], "height": 10}
    b = m.piece("Base", "Base", shadow=True)
    b2 = m.piece("Base2", "Base2", shadow=True)
    b.box((4.4, 4.4, 0.5), loc=(0, 0, 0.2), bevel=0.1)
    b2.box((3.5, 3.5, 0.5), loc=(0, 0, 0.68), bevel=0.09)
    b.box((2.7, 2.7, 0.45), loc=(0, 0, 1.12), bevel=0.08)
    shaft = m.piece("Shaft", "Shaft", shadow=True)
    q = TAU / 8
    loft(shaft, [ring(4, 1.25, 1.3, phase=q), ring(4, 0.82, 9.6, phase=q)])
    gold = m.piece("Gold", "Gold")
    loft(gold, [ring(4, 0.86, 9.55, phase=q), ring(4, 0.86, 9.68, phase=q), (0, 0, 10.9)])
    band = m.piece("Band", "Band")
    loft(band, [ring(4, 1.235, 1.5, phase=q), ring(4, 1.215, 1.8, phase=q)])
    # glyph columns: small gold marks sunk into each tapered face
    rng = random.Random(761)
    for k in range(4):
        ang = k * math.pi / 2
        nx, ny = math.sin(ang), -math.cos(ang)  # face normal (k = 0 -> front, -Y)
        tx, ty = math.cos(ang), math.sin(ang)
        z = 2.4
        while z < 8.8:
            t = (z - 1.3) / (9.6 - 1.3)
            half = (1.25 + (0.82 - 1.25) * t) * math.cos(q)
            off = half + 0.01
            kind = rng.randint(0, 3)
            cx, cy = nx * off, ny * off
            if kind == 0:  # bar
                gold.box((0.42 * abs(tx) + 0.1 * abs(nx), 0.42 * abs(ty) + 0.1 * abs(ny), 0.1), loc=(cx, cy, z), bevel=0.0)
            elif kind == 1:  # eye-ish diamond
                gold.box((0.28 * abs(tx) + 0.1 * abs(nx), 0.28 * abs(ty) + 0.1 * abs(ny), 0.28), loc=(cx, cy, z),
                         rot=(45 * abs(ny), 45 * abs(nx), 0), bevel=0.0)
            elif kind == 2:  # two dots
                for d in (-0.14, 0.14):
                    gold.box((0.12 * abs(tx) + 0.1 * abs(nx), 0.12 * abs(ty) + 0.1 * abs(ny), 0.12),
                             loc=(cx + tx * d, cy + ty * d, z), bevel=0.0)
            else:  # upright stroke
                gold.box((0.1, 0.1, 0.38), loc=(cx, cy, z), bevel=0.0)
            z += 0.62
    sand = m.piece("Sand", "Sand")
    sand_heap(sand, -1.8, -2.0, 1.6, 0.9, 0.55, 762)
    sand_heap(sand, 2.1, 1.4, 1.2, 1.4, 0.7, 763)


# ------------------------------------------------------------------ decor, hazard, camp

@register("Bones", "Desert", "Sun-bleached bones of a big beast: horned skull, spine and ribs, ~5 x 2.6. Decoration "
          "(no collider).")
def bones(m):
    m.extra["palette"] = {"Bone": P("ivory_200"), "Bone2": P("ivory_300"), "Dark": P("wood_900")}
    bone = m.piece("Bones", "Bone")
    b2 = m.piece("Bones2", "Bone2")
    spine = [(-2.2, 0.0, 0.18), (-1.2, 0.05, 0.3), (0.0, 0.0, 0.34), (1.2, -0.05, 0.3), (2.0, 0.0, 0.2)]
    for a, b in zip(spine, spine[1:]):
        b2.limb(a, b, 0.17, 0.15, seg=5)
    for k, x in enumerate((-1.0, -0.45, 0.1, 0.65, 1.15)):
        for side in (-1, 1):
            h = 1.15 - abs(x) * 0.25
            pts = [(x, side * 0.15, 0.32), (x + 0.05, side * 0.75, 0.25 + h * 0.65), (x + 0.15, side * 1.15, h * 0.35),
                   (x + 0.2, side * 1.2, -0.02)]
            for (p, q), (r0, r1) in zip(zip(pts, pts[1:]), ((0.13, 0.11), (0.11, 0.09), (0.09, 0.06))):
                bone.limb(p, q, r0, r1, seg=4)
    # skull with curved horns at the -X end
    sx = -2.65
    hull(bone, [(sx + x * 1.25, y, 0.32 + z * 0.8) for x, y, z in blob_points(771, 14, 0.42, 0.36, 0.34, floor=-0.36)])
    hull(bone, [(sx - 0.5 + x, y, 0.16 + z) for x, y, z in blob_points(772, 10, 0.32, 0.24, 0.16, floor=-0.14)])
    dark = m.piece("Sockets", "Dark")
    for y in (-0.2, 0.2):
        dark.box((0.16, 0.12, 0.12), loc=(sx - 0.2, y * 1.25, 0.5), bevel=0.0)
    for side in (-1, 1):
        pts = [(sx + 0.1, side * 0.3, 0.55), (sx + 0.15, side * 0.8, 0.85), (sx - 0.25, side * 1.15, 1.05), (sx - 0.65, side * 1.1, 0.95)]
        for (p, q), (r0, r1) in zip(zip(pts, pts[1:]), ((0.12, 0.09), (0.09, 0.06), (0.06, 0.01))):
            b2.limb(p, q, r0, r1, seg=5)
    b2.limb((2.6, 0.9, 0.05), (3.2, 1.5, 0.08), 0.08, 0.06, seg=4)  # a stray leg bone
    b2.ico(0.11, loc=(3.22, 1.52, 0.09), subdiv=1)


@register("Quicksand", "Desert", "Flat quicksand pool ~8.4 x 7.6, 0.2 tall: darker sinking centre and spiral ripples. "
          "Hazard visual (hazard radius ~3.6). Walkable decoration (no collider).")
def quicksand(m):
    m.extra["palette"] = {"Rim": P("sand_400"), "Sand": P("sand_500"), "Inner": P("sand_600"), "Core": P("sand_700"),
                          "Ripple": P("sand_300")}
    flat_patch(m.piece("Rim", "Rim"), 0, 0, 4.2, 3.8, -0.03, 0.05, 781, n=14, wobble=0.08)
    flat_patch(m.piece("Sand", "Sand"), 0, 0, 3.6, 3.25, 0.0, 0.09, 782, n=14, wobble=0.07)
    flat_patch(m.piece("Inner", "Inner"), 0.1, 0.05, 2.2, 2.0, 0.04, 0.12, 783, n=12, wobble=0.07)
    flat_patch(m.piece("Core", "Core"), 0.15, 0.08, 0.85, 0.78, 0.08, 0.14, 784, n=9, wobble=0.1)
    rip = m.piece("Ripples", "Ripple")
    a = 0.0
    while a < 5.2 * math.pi:
        r = 0.95 + a * 0.17
        if r > 3.4:
            break
        da = 0.62 / r
        x, y = math.cos(a) * r * 1.05, math.sin(a) * r * 0.95
        z = 0.13 if r < 2.2 else 0.1
        rip.box((0.5, 0.11, 0.03), loc=(x + 0.1, y + 0.05, z), rot=(0, 0, math.degrees(a) + 90), bevel=0.0)
        a += da * 1.4


@register("Desert_Tent", "Desert", "Nomad tent ~6 x 5 x 3.9: striped crimson and ivory cloth on poles, open front (-Y) "
          "over a rug, a clay pot and guy ropes. Collider box.")
def desert_tent(m):
    m.extra["palette"] = {"Cloth": P("crimson_600"), "Cloth2": P("ivory_300"), "Wood": P("wood_600"), "Rug": P("crimson_800"),
                          "Gold": P("gold_500"), "Clay": P("clay_500"), "Rope": P("dirt_300"), "Dark": P("wood_900")}
    m.extra["collider"] = {"kind": "box", "size": [5.0, 4.4], "height": 3.9}
    wood = m.piece("Poles", "Wood", shadow=True)
    c1 = m.piece("Cloth", "Cloth", shadow=True)
    c2 = m.piece("Cloth2", "Cloth2", shadow=True)
    L, H, half = 4.6, 3.6, 2.5  # depth (Y), ridge height, half width
    for y in (-L / 2, L / 2):
        loft(wood, [ring(5, 0.13, -0.1, cy=y), ring(5, 0.11, H + 0.35, cy=y)])
    wood.limb((0, -L / 2 - 0.2, H), (0, L / 2 + 0.2, H), 0.1, 0.1, seg=5)
    # roof: two sloped panels of alternating stripes, eaves at 0.9
    n = 6
    eave = 0.9
    for side in (-1, 1):
        for k in range(n):
            y0 = -L / 2 + L * k / n
            y1 = y0 + L / n
            piece = c1 if k % 2 == 0 else c2
            pts = []
            for y in (y0, y1):
                for (x, z) in ((0, H + 0.08), (side * half, eave), (side * (half - 0.02), eave - 0.12), (0, H - 0.06)):
                    pts.append((x, y, z))
            hull(piece, pts)
    # back wall and a dark interior
    dark = m.piece("Dark", "Dark")
    prism_xz(dark, [(-half + 0.15, 0.0), (half - 0.15, 0.0), (0, H - 0.15)], L / 2 - 0.2, L / 2 - 0.1)
    prism_xz(c2, [(-half, 0.0), (half, 0.0), (half, eave), (0, H), (-half, eave)], L / 2 - 0.08, L / 2)
    # front flaps tied back
    for side in (-1, 1):
        prism_xz(c1, [(side * 0.15, H - 0.2), (side * half * 0.95, eave), (side * half * 0.95, 0.15), (side * 1.4, 0.4)],
                 -L / 2 - 0.08, -L / 2)
    # side walls under the eaves
    for side in (-1, 1):
        c1.box((0.1, L, eave), loc=(side * (half - 0.05), 0, eave / 2), bevel=0.0)
    rug = m.piece("Rug", "Rug")
    rug.box((2.6, 3.2, 0.06), loc=(0, -1.6, 0.03), bevel=0.0)
    gold = m.piece("Gold", "Gold")
    for x in (-1.15, 1.15):
        gold.box((0.12, 3.0, 0.07), loc=(x, -1.6, 0.04), bevel=0.0)
    gold.box((0.5, 0.5, 0.07), loc=(0, -1.8, 0.04), rot=(0, 0, 45), bevel=0.0)
    clay = m.piece("Pot", "Clay")
    loft(clay, [ring(7, 0.22, 0.0, cx=1.9, cy=-2.9), ring(7, 0.42, 0.35, cx=1.9, cy=-2.9), ring(7, 0.3, 0.75, cx=1.9, cy=-2.9),
                ring(7, 0.2, 0.85, cx=1.9, cy=-2.9), ring(7, 0.24, 0.95, cx=1.9, cy=-2.9)])
    rope = m.piece("Ropes", "Rope")
    for y in (-L / 2, L / 2):
        for side in (-1, 1):
            sy = y + (-0.9 if y < 0 else 0.9)
            rope.limb((0, y, H + 0.25), (side * 1.2, sy, -0.05), 0.035, 0.035, seg=3)
            wood.box((0.12, 0.12, 0.4), loc=(side * 1.2, sy, 0.1), bevel=0.0)
