"""Shared builders for the biome kits (biome_swamp/snow/desert/lava.py, items2.py).

Not a model module (leading underscore). Same conventions as world.py: origin = ground
centre, front = -Y, colours from style.P, one colour per piece.
"""

import math
import random

from mathutils import Euler, Vector

from ._propkit import TAU, blob_points, cap_of, hull, loft, ring

# ------------------------------------------------------------------ small shapes


def rock_points(seed, n, rx, ry, rz, cx, cy, cz, floor, jitter=0.16):
    return [(cx + x, cy + y, cz + z) for x, y, z in blob_points(seed, n, rx, ry, rz, jitter=jitter, floor=floor)]


def blob(piece, centre, radii, seed, n=16, jitter=0.13, floor=None):
    cx, cy, cz = centre
    pts = blob_points(seed, n, *radii, jitter=jitter, floor=floor)
    pts = [(cx + x, cy + y, cz + z) for x, y, z in pts]
    hull(piece, pts)
    return pts


def pad(piece, x0, x1, y0, y1, z, seed, thick=0.14, inset=0.12, jit=0.12):
    """Flat irregular cap pad lying on a top surface at height z (moss, snow, sand, ash)."""
    rng = random.Random(seed)
    pts = []
    for zz in (z - 0.04, z + thick):
        for (x, y) in ((x0, y0), (x1, y0), (x1, y1), (x0, y1), ((x0 + x1) / 2, y0), ((x0 + x1) / 2, y1)):
            k = inset if zz > z else 0.0
            px = x + (k if x == x0 else -k if x == x1 else 0) + rng.uniform(-jit, jit)
            py = y + (k if y == y0 else -k) + rng.uniform(-0.05, 0.05)
            pts.append((px, py, zz))
    hull(piece, pts)


def flat_patch(piece, cx, cy, rx, ry, z0, z1, seed, n=10, wobble=0.14, top_scale=0.94, phase=0.0):
    """Low flat irregular disc (pools, puddles, pads): bottom at z0, top at z1."""
    rng = random.Random(seed)
    ks = [1 + rng.uniform(-wobble, wobble) for _ in range(n)]
    lo, hi = [], []
    for i in range(n):
        a = phase + i / n * TAU + rng.uniform(-0.12, 0.12)
        lo.append((cx + math.cos(a) * rx * ks[i], cy + math.sin(a) * ry * ks[i], z0))
        hi.append((cx + math.cos(a) * rx * ks[i] * top_scale, cy + math.sin(a) * ry * ks[i] * top_scale, z1))
    loft(piece, [lo, hi])
    return hi


def strand(piece, top, length, w, seed, sway=0.12, n=4):
    """Hanging strand (moss, willow fronds, icicles): a flattened tapered drip from `top` down."""
    rng = random.Random(seed)
    x, y, z = top
    rings = []
    ph = rng.uniform(0, TAU)
    for k in range(n):
        t = k / n
        r = w * (1 - t * 0.8)
        dx = math.sin(t * 3 + ph) * sway * t
        rings.append(ring(3, r, z - length * t, phase=ph, cx=x + dx, cy=y + dx * 0.5, sx=1.0, sy=0.55))
    rings.append((x + math.sin(3 + ph) * sway, y, z - length))
    loft(piece, rings)


def shard(piece, base, h, r, tilt=(0, 0), yaw=0.0, sides=6, shoulder=0.72, taper=0.88):
    """Faceted crystal: prism with a pointed tip, tilted (degrees) about its base."""
    rot = Euler((math.radians(tilt[0]), math.radians(tilt[1]), math.radians(yaw))).to_matrix()
    b = Vector(base)
    r0 = [tuple(rot @ Vector(p) + b) for p in ring(sides, r, -0.15)]
    r1 = [tuple(rot @ Vector(p) + b) for p in ring(sides, r * taper, h * shoulder)]
    apex = tuple(rot @ Vector((0, 0, h)) + b)
    loft(piece, [r0, r1, apex])


def snow_cap(piece, points, z_cut, tilt=(0.0, 0.0), grow=1.05, lift=0.03, centre=None):
    """Blanket of snow/sand/ash over the part of hull(points) above a gently tilted plane."""
    c = centre or (sum(p[0] for p in points) / len(points), sum(p[1] for p in points) / len(points), z_cut)
    cap_of(piece, points, plane_co=(c[0], c[1], z_cut), plane_no=(tilt[0], tilt[1], 1.0), grow=grow, lift=lift,
           centre=(c[0], c[1], c[2] if len(c) > 2 else z_cut))


# ------------------------------------------------------------------ walls

def block_wall(m, tones, cap, length, depth, courses, standing, seed, fallen=(), cap_chance=0.85,
               cap_thick=0.14, jitter_rot=1.0):
    """Broken wall of blocks split over tone pieces with a cap material on exposed tops.
    tones: list of pieces (first two most common, third darker footing); cap: piece or None."""
    rng = random.Random(seed)
    z = 0.0
    tops = []
    for c, h in enumerate(courses):
        x = -length / 2
        first = True
        while x < length / 2 - 0.3:
            span = rng.uniform(1.6, 2.5)
            if first and c % 2 == 1:
                span *= 0.55
            first = False
            x1 = x + span
            if length / 2 - x1 < 0.8:
                x1 = length / 2
            cx = (x + x1) / 2
            if standing(cx) > c:
                tone = rng.choices((0, 1, 2), weights=(0.45, 0.33, 0.22))[0]
                if c == 0:
                    tone = 2 if rng.random() < 0.5 else 0
                size = (x1 - x - 0.08, depth + rng.uniform(-0.1, 0.03), h - 0.06)
                top = c + 1 >= standing(cx)
                shift = rng.uniform(-0.05, 0.05)
                tones[tone].box(size, loc=(cx, shift, z + h / 2),
                                rot=(rng.uniform(-1.2, 1.2) * jitter_rot, rng.uniform(-1.5, 1.5) * jitter_rot,
                                     rng.uniform(-2.0, 2.0) * jitter_rot), bevel=0.09)
                if top:
                    tops.append((x, x1, size[1], shift, z + h))
                    if cap is not None and rng.random() < cap_chance:
                        pad(cap, x + 0.1, x1 - 0.1, -size[1] / 2 - 0.06 + shift, size[1] / 2 + 0.06 + shift,
                            z + h - 0.02, seed=int(cx * 100) + c, thick=cap_thick)
            x = x1
        z += h
    for loc, size, rot in fallen:
        tones[rng.choice((0, 1))].box(size, loc=loc, rot=rot, bevel=0.08)
    return tops


# ------------------------------------------------------------------ trees

def bent_trunk(piece, path, radii, sides=7, seed=1, wobble=0.05):
    """Trunk along a polyline of centre points with per-point radii (horizontal rings)."""
    rings = []
    for k, ((x, y, z), r) in enumerate(zip(path, radii)):
        rings.append(ring(sides, r, z, phase=0.3, cx=x, cy=y, wobble=wobble, seed=seed + k))
    loft(piece, rings)


def branch(piece, a, b, r0, r1, seg=5):
    piece.limb(a, b, r0, r1, seg=seg)
    piece.ico(r0 * 1.05, loc=a, subdiv=1)
