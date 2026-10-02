"""Swamp biome kit: mangroves and willows with hanging moss, reeds, lilypads, a mud pool,
a stilt hut landmark and wisp lanterns.

Same conventions as world.py: origin = ground centre, front = -Y (Roblox -Z), 1 unit = 1 stud,
colours from the shared palette (murk_* greens, bog_* muds). Extras (meshes/catalog.json):
collider (circle / box / multi, Roblox studs) on deliberate obstacles only, light at glow cores.
Flat hazard visuals (Mud_Pool) are walkable decoration: the game owns the hazard radius.
"""

import math
import random

from swarmkit import register
from style import P, mix

from ._biomekit import bent_trunk, blob, block_wall, flat_patch, pad, rock_points, strand  # noqa: F401
from ._propkit import TAU, blade, blob_points, box, flame, hull, light_at, loft, mesh, put, ring, roblox_xz

BARK = mix("wood_700", "murk_700", 0.35)
BARK2 = mix("wood_600", "murk_600", 0.3)


def _clump(piece, centre, radii, seed, n=18, jitter=0.13, flat=None):
    blob(piece, centre, radii, seed, n=n, jitter=jitter, floor=flat)


def _hanging_moss(piece, centre, r0, r1, z, count, seed, length=(1.4, 2.6), w=0.16):
    rng = random.Random(seed)
    cx, cy = centre
    for k in range(count):
        a = k / count * TAU + rng.uniform(-0.2, 0.2)
        r = rng.uniform(r0, r1)
        strand(piece, (cx + math.cos(a) * r, cy + math.sin(a) * r, z + rng.uniform(-0.3, 0.2)),
               rng.uniform(*length), w * rng.uniform(0.8, 1.2), seed + k, sway=0.1)


# ------------------------------------------------------------------ trees

@register("Swamp_Tree", "Swamp", "Gnarled mangrove on arching prop roots with a broad flat canopy and pale hanging "
          "moss, ~12 tall, canopy radius ~5. Collider = the root knot.")
def swamp_tree(m):
    m.extra["palette"] = {"Bark": BARK, "Leaves": P("murk_700"), "Leaves2": P("murk_600"), "Moss": P("murk_300")}
    m.extra["collider"] = {"kind": "circle", "radius": 1.5, "height": 8}
    rng = random.Random(301)
    bark = m.piece("Trunk", "Bark", shadow=True)
    bent_trunk(bark, [(0, 0, 1.4), (0.15, 0.05, 3.2), (0.45, 0.1, 5.4), (0.6, 0.2, 7.4), (0.7, 0.25, 8.6)],
               [0.78, 0.6, 0.5, 0.4, 0.3], sides=7, seed=302)
    # prop roots: arch out from the lower trunk and plunge into the ground
    for k in range(7):
        a = k / 7 * TAU + rng.uniform(-0.25, 0.25)
        z0 = rng.uniform(1.6, 3.2)
        rr = rng.uniform(2.3, 3.1)
        c, s = math.cos(a), math.sin(a)
        pts = [(c * 0.3, s * 0.3, z0), (c * rr * 0.55, s * rr * 0.55, z0 + 0.35), (c * rr * 0.9, s * rr * 0.9, 1.0),
               (c * rr, s * rr, -0.15)]
        for (p0, p1), (r0, r1) in zip(zip(pts, pts[1:]), ((0.34, 0.24), (0.25, 0.18), (0.19, 0.22))):
            bark.limb(p0, p1, r0, r1, seg=5)
    # crooked boughs carrying the canopy
    for a, b in (((0.5, 0.1, 6.2), (2.6, 1.0, 8.3)), ((0.4, 0.1, 6.6), (-2.3, 0.9, 8.6)),
                 ((0.6, 0.2, 7.0), (0.6, -2.5, 8.4)), ((0.65, 0.2, 7.6), (1.3, 2.4, 9.0))):
        bark.limb(a, b, 0.26, 0.13, seg=5)
    lo = m.piece("Leaves", "Leaves", shadow=True)
    hi = m.piece("Leaves2", "Leaves2", shadow=True)
    _clump(lo, (0.6, 0.2, 9.3), (3.9, 3.6, 1.35), 310, n=18)
    for k in range(5):
        a = math.radians(k * 72 + 30)
        _clump(lo, (0.6 + math.cos(a) * 3.2, 0.2 + math.sin(a) * 2.9, 8.8 + (k % 2) * 0.3), (2.2, 2.0, 1.0), 311 + k, n=12)
    _clump(hi, (1.4, 0.9, 10.3), (2.4, 2.2, 1.0), 320, n=18)
    _clump(hi, (-0.9, -0.4, 10.0), (2.1, 1.9, 0.95), 321, n=16)
    _clump(hi, (0.9, -1.6, 9.9), (1.8, 1.6, 0.85), 322, n=14)
    moss = m.piece("Moss", "Moss")
    _hanging_moss(moss, (0.6, 0.2), 2.4, 4.6, 8.4, 12, 330, length=(1.8, 3.2), w=0.24)
    for a, b in (((0.5, 0.1, 6.2), (2.6, 1.0, 8.3)), ((0.4, 0.1, 6.6), (-2.3, 0.9, 8.6))):
        for t in (0.45, 0.8):
            p = [a[i] + (b[i] - a[i]) * t for i in range(3)]
            strand(moss, (p[0], p[1], p[2] - 0.15), 1.5 + t, 0.13, int(t * 100) + int(p[0] * 10), sway=0.08)


@register("Swamp_Willow", "Swamp", "Weeping willow: thick short trunk, domed crown and a curtain of drooping fronds, "
          "~11 tall, canopy radius ~5. Collider = trunk.")
def swamp_willow(m):
    m.extra["palette"] = {"Bark": BARK2, "Leaves": P("murk_600"), "Leaves2": P("murk_500"), "Fronds": mix("murk_500", "murk_400", 0.4)}
    m.extra["collider"] = {"kind": "circle", "radius": 1.2, "height": 8}
    bark = m.piece("Trunk", "Bark", shadow=True)
    bent_trunk(bark, [(0, 0, -0.15), (0, 0, 0.5), (0.2, 0.0, 2.6), (0.4, 0.1, 4.6), (0.5, 0.1, 6.2)],
               [1.25, 0.95, 0.8, 0.62, 0.45], sides=8, seed=341)
    rng = random.Random(342)
    for k in range(5):
        a = k / 5 * TAU + rng.uniform(-0.3, 0.3)
        bark.limb((math.cos(a) * 0.3, math.sin(a) * 0.3, 0.8), (math.cos(a) * 1.9, math.sin(a) * 1.9, -0.12), 0.38, 0.1, seg=4)
    for a, b in (((0.4, 0.1, 5.0), (2.4, 0.6, 7.2)), ((0.4, 0.1, 5.3), (-1.9, -0.6, 7.4)), ((0.5, 0.1, 5.6), (0.2, 2.2, 7.6))):
        bark.limb(a, b, 0.32, 0.15, seg=5)
    cx, cy = 0.4, 0.1
    lo = m.piece("Crown", "Leaves", shadow=True)
    hi = m.piece("Crown2", "Leaves2", shadow=True)
    _clump(lo, (cx, cy, 8.2), (3.6, 3.4, 2.0), 350, n=22)
    _clump(hi, (cx + 0.7, cy + 0.5, 9.6), (2.2, 2.0, 1.3), 351, n=16)
    _clump(hi, (cx - 1.1, cy - 0.6, 9.3), (1.9, 1.8, 1.15), 352, n=14)
    fr = m.piece("Fronds", "Fronds", shadow=True)
    n = 24
    ph = 0.1

    def fringe(a, i):
        return (-0.9, 0.7, -0.4, 0.9)[i % 4]
    outer_top = ring(n, 3.4, 8.3, phase=ph, cx=cx, cy=cy)
    outer_mid = ring(n, 4.3, 6.4, phase=ph, cx=cx, cy=cy, star=0.2, wobble=0.04, seed=353)
    outer_bot = ring(n, 4.6, 3.2, phase=ph, cx=cx, cy=cy, star=0.3, wobble=0.06, seed=354, zfn=fringe)
    inner_bot = ring(n, 4.05, 3.45, phase=ph, cx=cx, cy=cy, star=0.3, zfn=fringe)
    inner_top = ring(n, 2.9, 7.6, phase=ph, cx=cx, cy=cy)
    loft(fr, [outer_top, outer_mid, outer_bot, inner_bot, inner_top])


# ------------------------------------------------------------------ plants and decor

@register("Reeds", "Swamp", "Clump of reeds with three cattails, ~1.6 wide x 2.4 tall. Decoration (no collider).")
def reeds(m):
    m.extra["palette"] = {"Reed": P("murk_400"), "Reed2": P("murk_300"), "Cattail": P("leather_600")}
    r1 = m.piece("Reeds", "Reed")
    r2 = m.piece("Reeds2", "Reed2")
    rng = random.Random(361)
    for k in range(11):
        a = k / 11 * TAU + rng.uniform(-0.3, 0.3)
        r = rng.uniform(0.05, 0.35)
        base = (math.cos(a) * r, math.sin(a) * r, -0.05)
        out = rng.uniform(0.15, 0.55)
        h = rng.uniform(1.2, 2.3)
        tip = (base[0] + math.cos(a) * out, base[1] + math.sin(a) * out, h)
        blade(r1 if k % 3 else r2, base, tip, w=rng.uniform(0.17, 0.22))
    cat = m.piece("Cattails", "Cattail")
    for x, y, h, lean in ((0.12, 0.05, 2.35, (0.12, 0.05)), (-0.25, 0.18, 2.0, (-0.15, 0.1)), (0.1, -0.28, 1.75, (0.08, -0.14))):
        top = (x + lean[0], y + lean[1], h)
        r2.limb((x, y, -0.05), top, 0.04, 0.03, seg=3)
        mid = (x + lean[0] * 0.92, y + lean[1] * 0.92, h - 0.35)
        cat.limb((mid[0], mid[1], mid[2] - 0.25), (top[0], top[1], top[2] - 0.08), 0.1, 0.09, seg=5)
        r2.limb(top, (top[0] + lean[0] * 0.1, top[1] + lean[1] * 0.1, top[2] + 0.22), 0.025, 0.0, seg=3)


def _pad(piece, cx, cy, r, z, notch, seed, n=9, t=0.07):
    """Lily pad: flat disc with a wedge notch (angle `notch`, radians), built as a closed fan."""
    rng = random.Random(seed)
    span = TAU - 0.55
    rim = []
    for i in range(n + 1):
        a = notch + 0.275 + span * i / n
        rr = r * (1 + rng.uniform(-0.05, 0.04))
        rim.append((cx + math.cos(a) * rr, cy + math.sin(a) * rr))
    k = len(rim)
    verts = [(cx, cy, z), (cx, cy, z + t)] + [(x, y, z) for x, y in rim] + [(x, y, z + t) for x, y in rim]
    faces = []
    for i in range(k - 1):
        b0, b1, t0, t1 = 2 + i, 2 + i + 1, 2 + k + i, 2 + k + i + 1
        faces += [(0, b1, b0), (1, t0, t1), (b0, b1, t1, t0)]
    faces += [(0, 2, 2 + k, 1), (0, 1, 2 + 2 * k - 1, 2 + k - 1)]
    put(piece, mesh(verts, faces))


@register("Lilypads", "Swamp", "Lilypad cluster with one pale bloom, ~3 x 2.6, 0.3 tall. Flat decoration for mud and "
          "water (no collider, no shadow).")
def lilypads(m):
    m.extra["palette"] = {"Pad": P("moss_500"), "Pad2": P("moss_400"), "Petal": P("ivory_100"), "Heart": P("gold_300")}
    p1 = m.piece("Pads", "Pad")
    p2 = m.piece("Pads2", "Pad2")
    for (x, y, r, notch, s, pc) in ((0.0, 0.0, 0.85, 0.6, 1, p1), (1.05, 0.55, 0.6, 2.4, 2, p2), (-0.95, 0.6, 0.55, 4.0, 3, p2),
                                     (0.65, -0.85, 0.45, 1.5, 4, p1), (-0.8, -0.7, 0.38, 5.2, 5, p1)):
        _pad(pc, x, y, r, s * 0.018, notch, 370 + s)
    pet = m.piece("Bloom", "Petal")
    cx, cy, z = 0.15, 0.1, 0.07
    for k in range(6):
        a = k / 6 * TAU
        tip = (cx + math.cos(a) * 0.36, cy + math.sin(a) * 0.36, z + 0.26)
        loft(pet, [(cx, cy, z), ring(3, 0.09, z + 0.12, phase=a, cx=cx + math.cos(a) * 0.17, cy=cy + math.sin(a) * 0.17), tip])
    loft(m.piece("Heart", "Heart"), [ring(5, 0.1, z + 0.02, cx=cx, cy=cy), ring(5, 0.08, z + 0.2, cx=cx, cy=cy)])


@register("Swamp_Log", "Swamp", "Rotting log half sunk in the bog, 7 long (X) x 1.5, moss and pale shelf fungus. "
          "Collider box.")
def swamp_log(m):
    m.extra["palette"] = {"Bark": BARK, "Heart": P("bog_500"), "Moss": P("murk_400"), "Fungus": P("ivory_300")}
    m.extra["collider"] = {"kind": "box", "size": [7.0, 1.5], "height": 1.3}
    bark = m.piece("Bark", "Bark", shadow=True)
    n = 8
    stations = [(-3.45, 0.62, 0.0, 0.4), (-1.7, 0.72, 0.05, 0.5), (0.4, 0.74, -0.06, 0.52), (2.3, 0.68, 0.03, 0.45),
                (3.45, 0.6, 0.0, 0.38)]
    rings = []
    for x, r, y, z in stations:
        rings.append([(x, y + math.cos(i / n * TAU + 0.2) * r, z + math.sin(i / n * TAU + 0.2) * r) for i in range(n)])
    loft(bark, rings)
    bark.limb((-0.6, 0.2, 1.0), (-1.3, 0.7, 1.75), 0.24, 0.12, seg=5)
    bark.limb((1.9, -0.3, 0.9), (2.4, -1.2, 1.1), 0.18, 0.08, seg=4)
    heart = m.piece("Ends", "Heart")
    for x, r, z, sgn in ((-3.45, 0.52, 0.4, -1), (3.45, 0.5, 0.38, 1)):
        pts = []
        for xx in (x - sgn * 0.02, x + sgn * 0.05):
            pts += [(xx, math.cos(i / n * TAU + 0.2) * r, z + math.sin(i / n * TAU + 0.2) * r) for i in range(n)]
        hull(heart, pts)
    moss = m.piece("Moss", "Moss")
    for x0, x1, s in ((-3.0, -0.6, 381), (0.9, 3.1, 382)):
        rng = random.Random(s)
        pts = []
        for x in (x0, (x0 + x1) / 2, x1):
            for a in (50, 90, 130):
                aa = math.radians(a + rng.uniform(-10, 10))
                for dr in (-0.06, 0.1):
                    pts.append((x + rng.uniform(-0.15, 0.15), math.cos(aa) * (0.73 + dr), 0.48 + math.sin(aa) * (0.73 + dr)))
        hull(moss, pts)
    fun = m.piece("Fungus", "Fungus")
    for x, side, s in ((-1.0, -1, 0.42), (-0.4, -1, 0.32), (1.6, 1, 0.38)):
        y = side * 0.7
        loft(fun, [ring(6, s * 0.2, 0.55, cx=x, cy=y + side * 0.05),
                   ring(6, s, 0.62, cx=x, cy=y + side * s * 0.65, sx=1.0, sy=0.7),
                   ring(6, s * 0.8, 0.72, cx=x, cy=y + side * s * 0.55, sx=1.0, sy=0.7)])


@register("Mud_Pool", "Swamp", "Flat bog pool ~8.4 x 7.6, 0.2 tall: dark mud, wet sheen, bubbles, rim stones. Slow-zone "
          "hazard visual (hazard radius ~3.6 from the origin). Walkable decoration (no collider).")
def mud_pool(m):
    m.extra["palette"] = {"Rim": P("bog_500"), "Mud": P("bog_700"), "Wet": P("murk_800"), "Bubble": P("bog_600"),
                          "Stone": mix("stone_600", "murk_600", 0.3)}
    rim = m.piece("Rim", "Rim")
    flat_patch(rim, 0, 0, 4.2, 3.8, -0.03, 0.06, 391, n=14, wobble=0.1, top_scale=0.97)
    mud = m.piece("Mud", "Mud")
    flat_patch(mud, 0.1, -0.05, 3.6, 3.2, 0.0, 0.1, 392, n=13, wobble=0.12, top_scale=0.98)
    wet = m.piece("Wet", "Wet")
    flat_patch(wet, -0.7, 0.4, 1.7, 1.3, 0.05, 0.13, 393, n=9, wobble=0.18)
    flat_patch(wet, 1.4, -0.9, 1.0, 0.75, 0.05, 0.13, 394, n=8, wobble=0.18)
    flat_patch(wet, 1.6, 1.3, 0.55, 0.42, 0.05, 0.13, 395, n=7, wobble=0.15)
    bub = m.piece("Bubbles", "Bubble")
    for x, y, r in ((0.6, 0.5, 0.26), (0.9, 0.25, 0.16), (-1.8, -1.0, 0.22), (-0.3, -1.6, 0.14), (2.3, 0.2, 0.18)):
        loft(bub, [ring(6, r, 0.08, cx=x, cy=y), ring(6, r * 0.75, 0.08 + r * 0.55, cx=x, cy=y), (x, y, 0.08 + r * 0.75)])
    st = m.piece("Stones", "Stone")
    for x, y, s, seed in ((-3.7, -1.2, 0.5, 396), (-3.2, -1.9, 0.32, 397), (3.4, 1.9, 0.42, 398), (2.6, -3.1, 0.36, 399)):
        hull(st, rock_points(seed, 10, s * 1.2, s, s * 0.7, x, y, s * 0.3, floor=-s * 0.35))


@register("Swamp_Stump", "Swamp", "Hollow broken stump with a jagged rim, moss and shelf fungus, ~2.2 x 2.3. Collider circle.")
def swamp_stump(m):
    m.extra["palette"] = {"Bark": BARK, "Heart": P("wood_900"), "Moss": P("murk_400"), "Fungus": P("ivory_300")}
    m.extra["collider"] = {"kind": "circle", "radius": 1.0, "height": 2.2}
    bark = m.piece("Bark", "Bark", shadow=True)
    rng = random.Random(401)
    n = 9
    jag = [rng.uniform(-0.55, 0.35) + (0.35 if i in (2, 3) else 0) for i in range(n)]
    loft(bark, [ring(n, 1.1, -0.1, star=0.18, phase=0.2), ring(n, 0.86, 0.45, phase=0.2, star=0.05),
                ring(n, 0.78, 1.6, phase=0.2, zfn=lambda a, i: jag[i]), ring(n, 0.56, 1.6, phase=0.2, zfn=lambda a, i: jag[i] - 0.08),
                ring(n, 0.5, 0.9, phase=0.2)])
    for k in range(4):
        a = k * TAU / 4 + 0.7
        bark.limb((math.cos(a) * 0.45, math.sin(a) * 0.45, 0.5), (math.cos(a) * 1.3, math.sin(a) * 1.3, -0.1), 0.26, 0.07, seg=4)
    heart = m.piece("Hollow", "Heart")
    loft(heart, [ring(n, 0.52, 0.85, phase=0.2), ring(n, 0.52, 0.95, phase=0.2)])
    moss = m.piece("Moss", "Moss")
    hull(moss, [(-0.75 + x, 0.45 + y, 0.25 + z) for x, y, z in blob_points(402, 10, 0.5, 0.4, 0.28, floor=-0.25)])
    strand(moss, (0.55, -0.55, 1.55), 0.9, 0.14, 403)
    strand(moss, (0.2, -0.75, 1.75), 1.1, 0.13, 404)
    fun = m.piece("Fungus", "Fungus")
    for a, z, s in ((2.6, 0.9, 0.36), (3.2, 0.62, 0.28), (5.6, 1.1, 0.3)):
        x, y = math.cos(a) * 0.84, math.sin(a) * 0.84
        dx, dy = math.cos(a), math.sin(a)
        loft(fun, [ring(6, s * 0.25, z - 0.06, cx=x, cy=y),
                   ring(6, s, z, cx=x + dx * s * 0.6, cy=y + dy * s * 0.6),
                   ring(6, s * 0.8, z + 0.1, cx=x + dx * s * 0.5, cy=y + dy * s * 0.5)])


@register("Swamp_Rock", "Swamp", "Dark wet boulder with a moss blanket and a draping fringe, ~4.4 x 2.6. Collider circle.")
def swamp_rock(m):
    m.extra["palette"] = {"Stone": mix("stone_600", "murk_600", 0.35), "Stone2": mix("stone_700", "murk_700", 0.35),
                          "Moss": P("murk_400")}
    m.extra["collider"] = {"kind": "circle", "radius": 1.9, "height": 2.6}
    main = rock_points(411, 18, 2.1, 1.6, 1.3, -0.2, 0.1, 1.05, floor=-1.15)
    hull(m.piece("Rock", "Stone", shadow=True), main)
    side = rock_points(412, 12, 1.0, 0.85, 0.65, 1.5, -0.6, 0.45, floor=-0.55)
    hull(m.piece("Rock2", "Stone2", shadow=True), side)
    moss = m.piece("Moss", "Moss")
    from ._propkit import cap_of
    cap_of(moss, main, plane_co=(-0.2, 0.1, 1.7), plane_no=(-0.3, 0.35, 1.0), grow=1.04, lift=0.02, centre=(-0.2, 0.1, 1.05))
    for x, y, z, L in ((-1.6, -0.9, 1.5, 0.9), (-0.6, -1.35, 1.6, 1.0), (0.6, -1.2, 1.55, 0.8)):
        strand(moss, (x, y, z), L, 0.16, int(x * 10) + 420, sway=0.05)


# ------------------------------------------------------------------ landmark and lights

@register("Swamp_Hut", "Swamp", "Landmark stilt hut: plank cabin on six stilts, shaggy thatch roof, front porch with a "
          "ladder (-Y) and a hanging wisp lantern, ~7.2 x 8.4 x 8.6. Collider = the stilt footprint.")
def swamp_hut(m):
    m.extra["palette"] = {"Wood": P("wood_600"), "Wood2": P("wood_500"), "Dark": P("wood_900"),
                          "Thatch": mix("dirt_400", "murk_400", 0.4), "Thatch2": mix("dirt_500", "murk_500", 0.45),
                          "Iron": P("steel_800"), "Glow": P("wisp_glow"), "Moss": P("murk_400")}
    m.extra["collider"] = {"kind": "box", "size": [6.6, 6.4], "height": 8}
    rng = random.Random(431)
    wood = m.piece("Wood", "Wood", shadow=True)
    wood2 = m.piece("Wood2", "Wood2", shadow=True)
    dark = m.piece("Dark", "Dark")
    D = 3.0  # deck height
    # stilts with braces
    for x in (-2.9, 0.0, 2.9):
        for y in (-2.9, 2.3):
            loft(wood, [ring(6, 0.26, -0.15, cx=x, cy=y), ring(6, 0.22, D + 0.1, cx=x + rng.uniform(-0.08, 0.08), cy=y)])
    for y in (-2.9, 2.3):
        wood.limb((-2.9, y, 0.5), (0.0, y, 2.6), 0.1, 0.1, seg=4)
        wood.limb((2.9, y, 0.5), (0.0, y, 2.6), 0.1, 0.1, seg=4)
    # deck planks (along Y), alternating tones, porch at the front
    x = -3.3
    i = 0
    while x < 3.3:
        w = 0.6
        (wood2 if i % 2 else wood).box((w - 0.05, 6.2 + rng.uniform(-0.15, 0.15), 0.22),
                                       loc=(x + w / 2, -0.35 + rng.uniform(-0.06, 0.06), D),
                                       rot=(rng.uniform(-1, 1), 0, rng.uniform(-1, 1)), bevel=0.0)
        x += w
        i += 1
    dark.box((6.8, 0.3, 0.3), loc=(0, -3.35, D - 0.18), bevel=0.0)
    dark.box((6.8, 0.3, 0.3), loc=(0, 2.65, D - 0.18), bevel=0.0)
    # cabin: vertical plank walls, dark door and a small glowing window
    cy, W, Dp, H = 0.6, 4.8, 3.8, 2.5
    z0 = D + 0.1
    for side in (-1, 1):
        n = 8
        for k in range(n):
            px = -W / 2 + W * (k + 0.5) / n
            if side < 0 and abs(px + 0.4) < 0.55:
                continue  # doorway
            (wood if (k + (side > 0)) % 2 else wood2).box((W / n - 0.04, 0.22, H + rng.uniform(-0.1, 0.12)),
                                                         loc=(px, cy + side * Dp / 2, z0 + H / 2), bevel=0.0)
        for k in range(6):
            py = cy - Dp / 2 + Dp * (k + 0.5) / 6
            (wood2 if k % 2 else wood).box((0.22, Dp / 6 - 0.04, H + rng.uniform(-0.1, 0.1)),
                                           loc=(side * W / 2, py, z0 + H / 2), bevel=0.0)
    dark.box((W - 0.2, Dp - 0.2, H - 0.1), loc=(0, cy, z0 + H / 2 - 0.05), bevel=0.0)  # interior shadow block
    dark.box((0.95, 0.12, 1.9), loc=(-0.4, cy - Dp / 2 + 0.02, z0 + 0.95), bevel=0.0)
    for x in (-0.95, 0.15):
        wood.box((0.18, 0.3, 2.1), loc=(x, cy - Dp / 2 - 0.05, z0 + 1.05), bevel=0.0)
    wood.box((1.35, 0.3, 0.2), loc=(-0.4, cy - Dp / 2 - 0.05, z0 + 2.05), bevel=0.0)
    glow = m.piece("Glow", "Glow", "Neon")
    glow.box((0.7, 0.1, 0.55), loc=(1.4, cy - Dp / 2 - 0.08, z0 + 1.4), bevel=0.0)
    wood.box((0.95, 0.24, 0.14), loc=(1.4, cy - Dp / 2 - 0.12, z0 + 1.05), bevel=0.03)
    for dx in (-0.4, 0.4):
        wood.box((0.12, 0.2, 0.75), loc=(1.4 + dx, cy - Dp / 2 - 0.12, z0 + 1.4), bevel=0.0)
    # thatch: two shaggy hipped layers
    th = m.piece("Thatch", "Thatch", shadow=True)
    th2 = m.piece("Thatch2", "Thatch2", shadow=True)
    zr = z0 + H - 0.1

    def rect_ring(hx, hy, z, n_side=4, shag=0.0, seed=0):
        r = random.Random(seed)
        pts = []
        corners = [(-hx, -hy), (hx, -hy), (hx, hy), (-hx, hy)]
        for c in range(4):
            ax, ay = corners[c]
            bx, by = corners[(c + 1) % 4]
            for k in range(n_side):
                t = k / n_side
                dz = -shag if (k + c) % 2 == 0 else shag * 0.3
                pts.append((ax + (bx - ax) * t, cy + ay + (by - ay) * t, z + dz + r.uniform(-0.05, 0.05)))
        return pts
    loft(th2, [rect_ring(3.65, 2.95, zr - 0.55, shag=0.28, seed=432), rect_ring(3.1, 2.45, zr + 0.35),
               rect_ring(0.9, 0.35, zr + 2.9)])
    loft(th, [rect_ring(3.2, 2.5, zr + 0.5, shag=0.22, seed=433), rect_ring(2.0, 1.4, zr + 1.95),
              rect_ring(0.75, 0.25, zr + 3.25)])
    dark.box((1.9, 0.55, 0.4), loc=(0, cy, zr + 3.3), bevel=0.06)  # ridge bundle
    moss = m.piece("Moss", "Moss")
    pad(moss, 0.8, 2.2, cy + 0.2, cy + 1.6, zr + 1.55, 434, thick=0.16, inset=0.15)
    # porch rail and ladder
    for x in (-3.1, 2.9):
        wood.box((0.2, 0.2, 1.2), loc=(x, -3.15, D + 0.65), bevel=0.03)
    wood2.box((2.2, 0.16, 0.16), loc=(-2.0, -3.15, D + 1.1), rot=(0, -4, 0), bevel=0.02)
    wood2.box((2.2, 0.16, 0.16), loc=(1.8, -3.15, D + 1.05), rot=(0, 3, 0), bevel=0.02)
    for x in (-0.55, 0.55):
        wood.limb((x * 1.1, -4.55, -0.1), (x, -3.3, D + 0.9), 0.1, 0.09, seg=4)
    for k in range(6):
        t = (k + 0.6) / 6.6
        y = -4.55 + 1.25 * t
        z = -0.1 + (D + 1.0) * t
        wood2.box((1.25 - 0.1 * t, 0.14, 0.12), loc=(0, y, z), bevel=0.0)
    # lantern on a bracket at the porch corner
    wood.box((0.16, 0.16, 1.4), loc=(2.9, -3.15, D + 0.75), bevel=0.02)
    wood.box((0.9, 0.14, 0.14), loc=(3.3, -3.15, D + 1.4), bevel=0.02)
    iron = m.piece("Iron", "Iron", "Metal")
    lx, ly, lz = 3.65, -3.15, D + 0.85
    iron.box((0.05, 0.05, 0.3), loc=(lx, ly, lz + 0.42), bevel=0.0)
    loft(iron, [(lx, ly, lz + 0.42), ring(4, 0.24, lz + 0.22, phase=math.radians(45), cx=lx, cy=ly),
                ring(4, 0.24, lz + 0.17, phase=math.radians(45), cx=lx, cy=ly)])
    iron.box((0.32, 0.32, 0.06), loc=(lx, ly, lz - 0.28), bevel=0.0)
    loft(glow, [(lx, ly, lz - 0.25), ring(5, 0.13, lz - 0.05, cx=lx, cy=ly), ring(5, 0.1, lz + 0.12, cx=lx, cy=ly),
                (lx, ly, lz + 0.18)])
    m.extra["light"] = light_at(lx, ly, lz)


@register("Swamp_Lantern", "Swamp", "Crooked wooden post ~5.6 tall with a hanging cage lantern and a pale-green wisp "
          "glow (toward +X, Roblox -X); moss strands. Collider circle.")
def swamp_lantern(m):
    m.extra["palette"] = {"Wood": BARK2, "Iron": P("steel_800"), "Glow": P("wisp_glow"), "Moss": P("murk_300")}
    m.extra["collider"] = {"kind": "circle", "radius": 0.4, "height": 5.5}
    post = m.piece("Post", "Wood")
    bent_trunk(post, [(0, 0, -0.15), (0.05, 0, 1.5), (-0.1, 0.05, 3.2), (0.05, 0.0, 4.8), (0.25, 0, 5.4)],
               [0.3, 0.24, 0.21, 0.18, 0.14], sides=6, seed=441)
    for k in range(3):
        a = k / 3 * TAU + 0.4
        post.limb((0, 0, 0.4), (math.cos(a) * 0.65, math.sin(a) * 0.65, -0.1), 0.15, 0.05, seg=4)
    post.chain([(0.2, 0, 5.1), (0.8, 0, 5.45), (1.35, 0.0, 5.3)], [0.12, 0.1, 0.08], seg=5)
    lx, lz = 1.35, 4.35
    m.extra["light"] = light_at(lx, 0, lz)
    iron = m.piece("Iron", "Iron", "Metal")
    iron.box((0.05, 0.05, 0.45), loc=(lx, 0, lz + 0.78), bevel=0.0)
    loft(iron, [(lx, 0, lz + 0.62), ring(5, 0.32, lz + 0.36, cx=lx), ring(5, 0.32, lz + 0.3, cx=lx)])
    loft(iron, [ring(5, 0.3, lz - 0.38, cx=lx), ring(5, 0.3, lz - 0.32, cx=lx), (lx, 0, lz - 0.5)])
    for k in range(5):
        a = k / 5 * TAU
        iron.limb((lx + math.cos(a) * 0.29, math.sin(a) * 0.29, lz - 0.34), (lx + math.cos(a) * 0.29, math.sin(a) * 0.29, lz + 0.32),
                  0.035, 0.035, seg=3)
    glow = m.piece("Glow", "Glow", "Neon")
    glow.ico(0.2, loc=(lx, 0, lz), subdiv=1)
    moss = m.piece("Moss", "Moss")
    strand(moss, (0.75, 0.05, 5.4), 0.8, 0.12, 442)
    strand(moss, (0.12, -0.15, 3.3), 0.9, 0.13, 443)
    strand(moss, (-0.1, 0.18, 4.6), 0.7, 0.12, 444)
