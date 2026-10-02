"""Shape helpers for the world, castle and item kits (world.py, castle.py, items.py).

Not a model module: the leading underscore keeps build.py from importing it as one.
Every helper builds a closed solid in its own temporary bmesh and appends it to a piece
(swarmkit Piece), so Piece.finish() can recalculate outward normals safely.
"""

import math
import random

import bmesh
from mathutils import Matrix, Vector

import swarmkit as K

TAU = math.tau


# ------------------------------------------------------------------ plumbing

def put(piece, t, loc=(0, 0, 0), rot=(0, 0, 0), scale=None, bevel=0.0):
    """Scale, bevel (optional), rotate and move bmesh `t`, then append it to `piece`."""
    if scale is not None:
        if not hasattr(scale, "__len__"):
            scale = (scale, scale, scale)
        t.transform(Matrix.Diagonal(Vector((*scale, 1.0))))
    if bevel > 0:
        K.Piece._bevel(t, bevel)
    bmesh.ops.recalc_face_normals(t, faces=t.faces)
    piece._merge(t, K.mat(loc, rot))
    return piece


def mesh(verts, faces):
    """bmesh from vertex positions and faces (index lists)."""
    t = bmesh.new()
    vs = [t.verts.new(v) for v in verts]
    for f in faces:
        try:
            t.faces.new([vs[i] for i in f])
        except ValueError:  # duplicate face
            pass
    return t


def hull_bm(points):
    """Convex hull of points: big irregular facets (rocks, canopy clumps, chunks)."""
    t = bmesh.new()
    vs = [t.verts.new(p) for p in points]
    res = bmesh.ops.convex_hull(t, input=vs, use_existing_faces=False)
    junk = list({g for g in res["geom_interior"] + res["geom_unused"] if isinstance(g, bmesh.types.BMVert)})
    if junk:
        bmesh.ops.delete(t, geom=junk, context="VERTS")
    # the hull is all triangles: merge coplanar ones so bevels only chamfer real edges
    bmesh.ops.dissolve_limit(t, angle_limit=math.radians(0.5), verts=list(t.verts), edges=list(t.edges))
    return t


def hull(piece, points, loc=(0, 0, 0), rot=(0, 0, 0), bevel=0.0):
    return put(piece, hull_bm(points), loc, rot, bevel=bevel)


def blob_points(seed, n, rx, ry, rz, jitter=0.12, floor=None, squash_top=1.0):
    """n points spread evenly over an ellipsoid (golden spiral) with radial jitter.
    floor clamps z (relative to the centre) so the blob gets a flat base."""
    rng = random.Random(seed)
    pts = []
    for i in range(n):
        z = 1 - 2 * (i + 0.5) / n
        r = math.sqrt(max(0.0, 1 - z * z))
        a = i * 2.399963 + rng.uniform(-0.25, 0.25)
        s = 1 + rng.uniform(-jitter, jitter)
        p = [math.cos(a) * r * rx * s, math.sin(a) * r * ry * s, z * rz * s]
        if p[2] > 0:
            p[2] *= squash_top
        if floor is not None and p[2] < floor:
            p[2] = floor
        pts.append(tuple(p))
    return pts


def ring(n, r, z=0.0, phase=0.0, sx=1.0, sy=1.0, cx=0.0, cy=0.0, star=0.0, wobble=0.0,
         zwob=0.0, seed=None, zfn=None):
    """n points on a (possibly star-shaped / wobbly) horizontal ring."""
    rng = random.Random(seed) if seed is not None else None
    pts = []
    for i in range(n):
        a = phase + i / n * TAU
        rr = r * (1 - star * (i % 2))
        zz = z
        if rng:
            rr *= 1 + rng.uniform(-wobble, wobble)
            zz += rng.uniform(-zwob, zwob)
        if zfn:
            zz += zfn(a, i)
        pts.append((cx + math.cos(a) * rr * sx, cy + math.sin(a) * rr * sy, zz))
    return pts


def loft_bm(rings, cap_first=True, cap_last=True, loop=False):
    """Closed solid through rings (equal-length point lists) or single apex points.
    loop=True also joins the last ring back to the first (a ring-shaped solid, no caps)."""
    t = bmesh.new()
    vr = []
    for r in rings:
        if isinstance(r[0], (int, float)):
            vr.append([t.verts.new(r)])
        else:
            vr.append([t.verts.new(p) for p in r])
    pairs = list(zip(vr, vr[1:]))
    if loop:
        pairs.append((vr[-1], vr[0]))
        cap_first = cap_last = False
    for a, b in pairs:
        if len(a) == 1 and len(b) == 1:
            continue
        if len(a) == 1:
            n = len(b)
            for i in range(n):
                t.faces.new((a[0], b[i], b[(i + 1) % n]))
        elif len(b) == 1:
            n = len(a)
            for i in range(n):
                t.faces.new((a[i], a[(i + 1) % n], b[0]))
        else:
            n = len(a)
            for i in range(n):
                t.faces.new((a[i], a[(i + 1) % n], b[(i + 1) % n], b[i]))
    if cap_first and len(vr[0]) > 2:
        t.faces.new(vr[0])
    if cap_last and len(vr[-1]) > 2:
        t.faces.new(vr[-1])
    bmesh.ops.recalc_face_normals(t, faces=t.faces)
    return t


def loft(piece, rings, loc=(0, 0, 0), rot=(0, 0, 0), bevel=0.0, cap_first=True, cap_last=True, loop=False):
    return put(piece, loft_bm(rings, cap_first, cap_last, loop), loc, rot, bevel=bevel)


def frame_along(a, b, up=(0, 0, 1)):
    """Unit (forward, side, up) axes for a segment a -> b."""
    f = (Vector(b) - Vector(a)).normalized()
    u = Vector(up)
    if abs(f.dot(u)) > 0.97:
        u = Vector((0, 1, 0)) if abs(f.y) < 0.9 else Vector((1, 0, 0))
    s = f.cross(u).normalized()
    u = s.cross(f).normalized()
    return f, s, u


def sweep(piece, path, sections, closed=False, cap=True):
    """Loft a cross-section along a path.
    path: points; sections: per point a list of (side, up) offsets (same count for all)
    measured in the local frame of the path at that point."""
    rings = []
    n = len(path)
    for i, p in enumerate(path):
        a = Vector(path[max(i - 1, 0)])
        b = Vector(path[min(i + 1, n - 1)])
        _, s, u = frame_along(a, b)
        rings.append([tuple(Vector(p) + s * so + u * uo) for so, uo in sections[i]])
    return loft(piece, rings, cap_first=cap, cap_last=cap)


def leaf(piece, base, out, length, width, rise, tip_drop, thick=0.05, mid=0.45):
    """Closed thin leaf / frond with a raised mid rib (8 tris).
    base: start point; out: horizontal direction; rise: height of the rib at `mid`;
    tip_drop: how far the tip falls below the rib."""
    b = Vector(base)
    f = Vector((out[0], out[1], 0)).normalized()
    s = Vector((-f.y, f.x, 0))
    up = Vector((0, 0, 1))
    m = b + f * length * mid + up * rise
    tip = b + f * length + up * (rise - tip_drop)
    L, R = m - s * width / 2, m + s * width / 2
    C, D = m + up * thick, m - up * thick * 0.6
    verts = [tuple(b), tuple(L), tuple(C), tuple(R), tuple(D), tuple(tip)]
    faces = [(0, 1, 2), (0, 2, 3), (1, 5, 2), (2, 5, 3), (0, 4, 1), (0, 3, 4), (1, 4, 5), (4, 3, 5)]
    return put(piece, mesh(verts, faces))


def blade(piece, base, tip, w=0.12):
    """Grass blade: thin triangular pyramid (4 tris)."""
    b, t = Vector(base), Vector(tip)
    f, s, u = frame_along(b, t)
    p0 = b + s * w * 0.5
    p1 = b - s * w * 0.5
    p2 = b + (u if abs(f.z) < 0.9 else Vector((0, 1, 0))) * w * 0.35
    verts = [tuple(p0), tuple(p1), tuple(p2), tuple(t)]
    return put(piece, mesh(verts, [(0, 1, 2), (0, 1, 3), (1, 2, 3), (2, 0, 3)]))


def flame(piece, base, r, h, seg=5, twist=25.0, lean=(0.0, 0.0)):
    """Teardrop flame lick: point at the base, belly, twisted neck, tip."""
    x, y, z = base
    rings = [
        (x, y, z),
        ring(seg, r, z + h * 0.3, cx=x + lean[0] * 0.2, cy=y + lean[1] * 0.2),
        ring(seg, r * 0.6, z + h * 0.6, phase=math.radians(twist), cx=x + lean[0] * 0.55, cy=y + lean[1] * 0.55),
        (x + lean[0], y + lean[1], z + h),
    ]
    return loft(piece, rings)


def annular_block(piece, r_in, r_out, a0, a1, z0, z1, bevel=0.06, mid=False, cx=0.0, cy=0.0):
    """Curved block of a ring (dais rims, tower blocks, merlons). Angles in degrees."""
    pts = []
    angs = [a0, a1] if not mid else [a0, (a0 + a1) / 2, a1]
    for z in (z0, z1):
        for a in (a0, a1):
            r = math.radians(a)
            pts.append((cx + math.cos(r) * r_in, cy + math.sin(r) * r_in, z))
        for a in angs:
            r = math.radians(a)
            pts.append((cx + math.cos(r) * r_out, cy + math.sin(r) * r_out, z))
    return hull(piece, pts, bevel=bevel)


def voussoir(piece, cx, cz, r_in, r_out, a0, a1, y0, y1, bevel=0.05):
    """Arch stone in the XZ plane (centre cx, cz), depth from y0 to y1. Angles in degrees."""
    pts = []
    for y in (y0, y1):
        for a in (a0, a1):
            r = math.radians(a)
            pts.append((cx + math.cos(r) * r_in, y, cz + math.sin(r) * r_in))
            pts.append((cx + math.cos(r) * r_out, y, cz + math.sin(r) * r_out))
    return hull(piece, pts, bevel=bevel)


def cap_of(piece, points, plane_co, plane_no, grow=1.04, lift=0.03, centre=None):
    """Moss / snow cap: the part of hull(points) above a plane, grown slightly outward
    so it sits on the original surface like a blanket."""
    t = hull_bm(points)
    no = Vector(plane_no).normalized()
    geom = list(t.verts) + list(t.edges) + list(t.faces)
    bmesh.ops.bisect_plane(t, geom=geom, dist=0.0001, plane_co=plane_co, plane_no=no,
                           clear_inner=True)
    edges = [e for e in t.edges if e.is_boundary]
    if edges:
        bmesh.ops.holes_fill(t, edges=edges, sides=0)
    c = Vector(centre) if centre is not None else Vector((0, 0, 0))
    for v in t.verts:
        v.co = c + (v.co - c) * grow + Vector((0, 0, lift))
    return put(piece, t)


def box(piece, size, loc=(0, 0, 0), rot=(0, 0, 0), bevel=0.06, taper=None):
    """swarmkit box; bevel 0 gives a plain 12-tri box."""
    return piece.box(size, loc=loc, rot=rot, bevel=bevel, taper=taper)


def arc(cx, cz, r, a0, a1, n):
    """Points on an arc in the XZ plane (degrees)."""
    return [(cx + math.cos(math.radians(a0 + (a1 - a0) * i / n)) * r,
             cz + math.sin(math.radians(a0 + (a1 - a0) * i / n)) * r) for i in range(n + 1)]


def prism_xz(piece, profile, y0, y1):
    """Extrude an (x, z) outline (may be concave) from y = y0 to y = y1."""
    n = len(profile)
    verts = [(x, y0, z) for x, z in profile] + [(x, y1, z) for x, z in profile]
    faces = [list(range(n)), list(range(2 * n - 1, n - 1, -1))]
    for i in range(n):
        j = (i + 1) % n
        faces.append((i, j, n + j, n + i))
    return put(piece, mesh(verts, faces))


def prism_yz(piece, profile, x0, x1):
    """Extrude a (y, z) outline from x = x0 to x = x1 (mouldings that tile along X)."""
    n = len(profile)
    verts = [(x0, y, z) for y, z in profile] + [(x1, y, z) for y, z in profile]
    faces = [list(range(n)), list(range(2 * n - 1, n - 1, -1))]
    for i in range(n):
        j = (i + 1) % n
        faces.append((i, j, n + j, n + i))
    return put(piece, mesh(verts, faces))


def u_shell(piece, inner, outer, y0, y1):
    """Thin closed shell between two matching open (x, z) polylines, from y0 to y1
    (tunnel linings, arch soffits)."""
    n = len(inner)
    verts = []
    for y in (y0, y1):
        verts += [(x, y, z) for x, z in inner]
        verts += [(x, y, z) for x, z in outer]

    def v(side, ring_, i):  # side 0 = y0, 1 = y1; ring_ 0 inner / 1 outer
        return side * 2 * n + ring_ * n + i

    faces = []
    for i in range(n - 1):
        faces.append((v(0, 0, i), v(0, 0, i + 1), v(1, 0, i + 1), v(1, 0, i)))
        faces.append((v(0, 1, i), v(1, 1, i), v(1, 1, i + 1), v(0, 1, i + 1)))
        faces.append((v(0, 0, i), v(0, 1, i), v(0, 1, i + 1), v(0, 0, i + 1)))
        faces.append((v(1, 0, i), v(1, 0, i + 1), v(1, 1, i + 1), v(1, 1, i)))
    for i in (0, n - 1):
        faces.append((v(0, 0, i), v(1, 0, i), v(1, 1, i), v(0, 1, i)))
    return put(piece, mesh(verts, faces))


def sheet(piece, xs, top, bottom, wave, thick, y0=0.0):
    """Hanging cloth: columns at xs, top(x)/bottom(x) edge heights, wave(x) y offset.
    A closed thin solid (front at y0 - thick/2 + wave, back at y0 + thick/2 + wave)."""
    n = len(xs)
    verts = []
    for side in (-1, 1):
        for x in xs:
            y = y0 + wave(x) + side * thick / 2
            verts.append((x, y, top(x)))
            verts.append((x, y, bottom(x)))
    faces = []

    def vi(side, i, b):  # side 0 front / 1 back, column i, b 0 top / 1 bottom
        return side * 2 * n + i * 2 + b

    for i in range(n - 1):
        faces.append((vi(0, i, 0), vi(0, i + 1, 0), vi(0, i + 1, 1), vi(0, i, 1)))
        faces.append((vi(1, i, 0), vi(1, i, 1), vi(1, i + 1, 1), vi(1, i + 1, 0)))
        faces.append((vi(0, i, 0), vi(1, i, 0), vi(1, i + 1, 0), vi(0, i + 1, 0)))
        faces.append((vi(0, i, 1), vi(0, i + 1, 1), vi(1, i + 1, 1), vi(1, i, 1)))
    faces.append((vi(0, 0, 0), vi(0, 0, 1), vi(1, 0, 1), vi(1, 0, 0)))
    faces.append((vi(0, n - 1, 0), vi(1, n - 1, 0), vi(1, n - 1, 1), vi(0, n - 1, 1)))
    return put(piece, mesh(verts, faces))


def roblox_xz(x, y):
    """Blender ground (x, y) -> Roblox (X, Z) for collider extras."""
    r = K.to_roblox((x, y, 0))
    return [r[0], r[2]]


def light_at(x, y, z):
    """Blender point -> Roblox [X, Y, Z] (catalog extras such as light positions)."""
    return K.to_roblox((x, y, z))
