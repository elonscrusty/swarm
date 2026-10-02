"""The swarm: six creature types and the Scorpion Queen boss (heroic low-poly fantasy).

Enemy ids stay as in EnemyData (Slime, Bat, Skeleton, Ghost, Brute, Bomber, Boss); the model
names below are what ModelLibrary maps them to. Every model's origin is the ground centre
(z = 0), it faces -Y, and its footprint follows EnemyData: width ~ 2 * Radius * 1.1, height ~
Size.Y (the client lifts it by -Size.Y / 2 onto the hit body; fliers hover by FlyHeight).

Design rules (docs/ART_DIRECTION.md): each type owns a hue and a silhouette that reads from
the 55-60 degree gameplay camera; legs and undersides are dark chitin so the shells pop off
moss-green grass; eyes are small amber Neon; Neon only on tiny glowing bits.

Animated pieces (runtime keys in src/client/ModelLibrary.lua, pivot = the joint):
  SwingA / SwingB   legs and arms (pitch around the hip / shoulder)
  FlapL / FlapR     fast wasp wings (roll around the wing root)
  FlutterL / R      slow, wide moth wings (roll around the wing root, rest raised)
  Jaw               mandibles, horn toss, the queen's claws (lift)
  Tail              the queen's tail (sway around its base)
  Wiggle            antennae
  Pulse, Throb      glow (a small bob; Throb sinks glowing spots into the shell and back)
"""

import math

import bmesh
from mathutils import Matrix, Vector

from swarmkit import mat, register
from style import P, mix

# ------------------------------------------------------------------ geometry helpers
# All helpers build world-space geometry in a temporary bmesh and merge it into a piece.


def _cap_cut(t, co, no):
    """Cut bmesh t with a plane, keep the side the normal points to and close the hole."""
    geom = list(t.verts) + list(t.edges) + list(t.faces)
    bmesh.ops.bisect_plane(t, geom=geom, dist=1e-5, plane_co=Vector(co), plane_no=Vector(no),
                           clear_inner=True)
    boundary = [e for e in t.edges if e.is_boundary]
    if boundary:
        bmesh.ops.holes_fill(t, edges=boundary, sides=0)


def ellipsoid(p, c, r, seg=10, rings=6, rot=(0, 0, 0), axis="Z", keep=(), lumps=0.0, seed=3, shift=(0, 0, 0),
              taper=0.0):
    """Faceted ellipsoid (a low UV sphere) centred at c with radii r.

    axis  the pole direction before `rot` ("Y" runs the facets front to back, like elytra;
          vertex columns sit every 360/seg degrees from +X, so with seg % 4 == 0 cuts through
          the centre's x = 0 / z = 0 planes follow existing edges and add no triangles)
    keep  planes (point, normal): only the side the normal points to is kept, cut faces capped
    lumps random radial roughness (fur, warts)
    shift moves the result after cutting (e.g. to open a seam between two elytra)
    taper narrows the front (-y) and widens the back (teardrop bodies)
    """
    t = bmesh.new()
    bmesh.ops.create_uvsphere(t, u_segments=seg, v_segments=rings, radius=1.0)
    if axis == "Y":
        t.transform(Matrix.Rotation(math.radians(90), 4, "X"))
    elif axis == "X":
        t.transform(Matrix.Rotation(math.radians(90), 4, "Y"))
    if lumps:
        import random
        rng = random.Random(seed)
        for v in t.verts:
            v.co *= 1 + rng.uniform(-lumps, lumps)
    if taper:
        for v in t.verts:
            v.co.x *= 1 + taper * v.co.y
    t.transform(Matrix.Diagonal(Vector((r[0], r[1], r[2], 1.0))))
    t.transform(mat(c, rot))
    for co, no in keep:
        _cap_cut(t, co, no)
    return p._merge(t, Matrix.Translation(shift))


def tube(p, pts, radii, seg=5, flat=1.0, roll=0.0, up=(0, 0, 1), caps=(True, True)):
    """Continuous faceted tube through pts (legs, horns, tails, antennae).

    A radius of 0 makes a point (a claw tip). flat < 1 squashes the cross-section along the
    side direction (flat bands for tails / blades). No joint balls, so it stays cheap.
    caps=(False, False) leaves hidden ends open (bands buried in a neighbour).
    """
    pts = [Vector(q) for q in pts]
    n = len(pts)
    tan = []
    for i in range(n):
        if i == 0:
            d = pts[1] - pts[0]
        elif i == n - 1:
            d = pts[-1] - pts[-2]
        else:
            d = (pts[i + 1] - pts[i]).normalized() + (pts[i] - pts[i - 1]).normalized()
        tan.append(d.normalized())
    ref = Vector(up)
    if abs(ref.normalized().dot(tan[0])) > 0.95:
        ref = Vector((0, 1, 0)) if abs(tan[0].y) < 0.9 else Vector((1, 0, 0))
    nrm = (ref - tan[0] * ref.dot(tan[0])).normalized()
    t = bmesh.new()
    rings = []
    for i in range(n):
        if i:
            nrm = (nrm - tan[i] * nrm.dot(tan[i])).normalized()
        side = tan[i].cross(nrm)
        r = radii[i]
        if 0 < i < n - 1:  # widen joints a little so bends keep their thickness
            r /= max(0.75, (pts[i + 1] - pts[i]).normalized().dot(tan[i]))
        if r < 1e-4:
            rings.append([t.verts.new(pts[i])])
            continue
        ring = []
        for k in range(seg):
            a = roll + 2 * math.pi * k / seg
            ring.append(t.verts.new(pts[i] + (nrm * math.cos(a) + side * math.sin(a) * flat) * r))
        rings.append(ring)
    for i in range(n - 1):
        a, b = rings[i], rings[i + 1]
        if len(a) == 1 and len(b) == 1:
            continue
        for k in range(seg):
            k2 = (k + 1) % seg
            if len(b) == 1:
                t.faces.new((a[k], a[k2], b[0]))
            elif len(a) == 1:
                t.faces.new((a[0], b[k2], b[k]))
            else:
                t.faces.new((a[k], a[k2], b[k2], b[k]))
    if len(rings[0]) > 1 and caps[0]:
        t.faces.new(list(reversed(rings[0])))
    if len(rings[-1]) > 1 and caps[1]:
        t.faces.new(rings[-1])
    bmesh.ops.recalc_face_normals(t, faces=t.faces)
    return p._merge(t, Matrix.Identity(4))


def plate(p, pts, depth, loc=(0, 0, 0), rot=(0, 0, 0)):
    """Flat polygon (x, y outline) extruded `depth` along z, then placed (wings, blades)."""
    t = bmesh.new()
    vs = [t.verts.new((x, y, -depth / 2)) for x, y in pts]
    f = t.faces.new(vs)
    ext = bmesh.ops.extrude_face_region(t, geom=[f])
    moved = [e for e in ext["geom"] if isinstance(e, bmesh.types.BMVert)]
    bmesh.ops.translate(t, vec=(0, 0, depth), verts=moved)
    bmesh.ops.recalc_face_normals(t, faces=t.faces)
    return p._merge(t, mat(loc, rot))


def annulus(p, c2, r_out, r_in, depth, seg=8, loc=(0, 0, 0), rot=(0, 0, 0)):
    """Flat ring (x, y centre c2) extruded `depth` along z, then placed (eye-spots, rims)."""
    t = bmesh.new()
    out, inn = [], []
    for k in range(seg):
        a = 2 * math.pi * k / seg
        for lst, r in ((out, r_out), (inn, r_in)):
            lst.append([t.verts.new((c2[0] + math.cos(a) * r, c2[1] + math.sin(a) * r, z)) for z in (-depth / 2, depth / 2)])
    for k in range(seg):
        k2 = (k + 1) % seg
        for lo, hi in ((0, 1),):
            t.faces.new((out[k][hi], out[k2][hi], inn[k2][hi], inn[k][hi]))  # top
            t.faces.new((out[k][lo], inn[k][lo], inn[k2][lo], out[k2][lo]))  # bottom
            t.faces.new((out[k][lo], out[k2][lo], out[k2][hi], out[k][hi]))  # outer wall
            t.faces.new((inn[k][lo], inn[k][hi], inn[k2][hi], inn[k2][lo]))  # inner wall
    bmesh.ops.recalc_face_normals(t, faces=t.faces)
    return p._merge(t, mat(loc, rot))


def gem(p, c, r, scale=(1, 1, 1), rot=(0, 0, 0)):
    """Octahedron bead (8 tris): eyes, glowing spots, studs."""
    t = bmesh.new()
    v = [t.verts.new(q) for q in ((1, 0, 0), (-1, 0, 0), (0, 1, 0), (0, -1, 0), (0, 0, 1), (0, 0, -1))]
    for f in ((0, 2, 4), (2, 1, 4), (1, 3, 4), (3, 0, 4), (2, 0, 5), (1, 2, 5), (3, 1, 5), (0, 3, 5)):
        t.faces.new([v[i] for i in f])
    t.transform(Matrix.Diagonal(Vector((r * scale[0], r * scale[1], r * scale[2], 1.0))))
    return p._merge(t, mat(c, rot))


def on_ellipsoid(c, r, d, inset=0.0, taper=0.0):
    """Point on an ellipsoid surface in direction d from its centre, and the surface normal
    (taper: the same front narrowing as ellipsoid(taper=...), approximately)."""
    d = Vector(d).normalized()
    k = 1 / math.sqrt(sum((d[i] / r[i]) ** 2 for i in range(3)))
    q = Vector(c) + d * k
    n = Vector([(q[i] - c[i]) / r[i] ** 2 for i in range(3)])
    if taper:
        f = 1 + taper * (q.y - c[1]) / r[1]
        q.x = c[0] + (q.x - c[0]) * f
        n.x /= f
    n.normalize()
    return q - n * inset, n


def stud(p, c, r, d, size, embed=0.3, protrude=0.24, taper=0.0, seg=6):
    """Rounded blister sitting on an ellipsoid surface (glow spots, rivets): its base is sunk
    `embed` * size below the surface and its top stands `protrude` * size above it."""
    q, n = on_ellipsoid(c, r, d, taper=taper)
    rot = n.to_track_quat("Z", "Y").to_matrix().to_4x4()
    t = bmesh.new()
    rings = [(1.0, 0.0), (0.92, 0.55), (0.55, 1.0)]  # (radius, height) profile of a low dome
    verts = []
    for rr, hh in rings:
        verts.append([t.verts.new((math.cos(2 * math.pi * k / seg) * rr, math.sin(2 * math.pi * k / seg) * rr, hh))
                      for k in range(seg)])
    for i in range(len(rings) - 1):
        for k in range(seg):
            k2 = (k + 1) % seg
            t.faces.new((verts[i][k], verts[i][k2], verts[i + 1][k2], verts[i + 1][k]))
    t.faces.new(verts[-1])
    t.faces.new(list(reversed(verts[0])))
    t.transform(Matrix.Diagonal(Vector((size, size, size * (embed + protrude), 1.0))))
    t.transform(Matrix.Translation(q - n * size * embed) @ rot)
    bmesh.ops.recalc_face_normals(t, faces=t.faces)
    return p._merge(t, Matrix.Identity(4))


def mirror(points):
    """The same points on the other side (x -> -x)."""
    return [(-x, y, z) for x, y, z in points]


def X(s, pts):
    """Points authored for the +x side, flipped to side s (+1 / -1)."""
    return [(s * x, y, z) for x, y, z in pts]


# ------------------------------------------------------------------ MITE (Slime id)

@register("Mite", "Enemies", "Slime id. The grunt: round yellow-green beetle, dark head, amber eyes.")
def mite(m):
    """Cheapest model (100+ on screen): 5 pieces, <= 350 tris."""
    m.extra["palette"] = {"Base": P("beetle_300"), "Dark": P("chitin_900"), "Eye": P("amber_500")}
    shell = m.piece("Shell", "Base", shadow=True)
    c = (0, 0.36, 0.6)
    for s in (-1, 1):  # two elytra; the dark underside shows through the seam
        ellipsoid(shell, c, (1.2, 1.12, 1.14), seg=12, rings=6, axis="Y",
                  keep=[(c, (0, 0, 1)), (c, (s, 0, 0))], shift=(s * 0.045, 0, 0))
    pc = (0, -0.64, 0.6)
    ellipsoid(shell, pc, (0.84, 0.5, 0.8), seg=8, rings=4, axis="Y", keep=[(pc, (0, 0, 1))])  # pronotum
    head = m.piece("Head", "Dark")
    ellipsoid(head, (0, -1.1, 0.58), (0.5, 0.42, 0.36), seg=8, rings=4)
    ellipsoid(head, (0, 0.22, 0.6), (1.06, 1.3, 0.42), seg=8, rings=4, keep=[((0, 0, 0.6), (0, 0, -1))])
    for s in (-1, 1):  # mandibles
        tube(head, X(s, [(0.18, -1.38, 0.48), (0.21, -1.62, 0.47), (0.06, -1.78, 0.45)]), [0.08, 0.06, 0.0], seg=3)
    eyes = m.piece("Eyes", "Eye", "Neon")
    for s in (-1, 1):
        gem(eyes, (s * 0.29, -1.38, 0.7), 0.105)
    for s, name, anim in ((1, "LegsL", "SwingA"), (-1, "LegsR", "SwingB")):
        legs = m.piece(name, "Dark", anim=anim, pivot=(s * 0.72, 0.2, 0.5))
        for hip, knee, foot in (((0.72, -0.42, 0.5), (1.36, -0.8, 0.8), (1.5, -1.16, 0.0)),
                                ((0.74, 0.2, 0.48), (1.44, 0.22, 0.82), (1.6, 0.3, 0.0)),
                                ((0.72, 0.82, 0.48), (1.36, 1.16, 0.8), (1.48, 1.52, 0.0))):
            tube(legs, X(s, [hip, knee, foot]), [0.15, 0.125, 0.0], seg=4)


# ------------------------------------------------------------------ WASP (Bat id)

def banded(gold, black, pts, radii, black_bands, seg=8):
    """Abdomen made of rings along pts: band i (pts[i] -> pts[i+1]) goes to black if i is in
    black_bands, else to gold. Neighbouring bands share their edge rings, so the stripes are
    crisp; the hidden band ends stay open."""
    for i in range(len(pts) - 1):
        tube(black if i in black_bands else gold, [pts[i], pts[i + 1]], [radii[i], radii[i + 1]], seg=seg,
             caps=(False, False))


@register("Wasp", "Enemies", "Bat id. Gold and black wasp with translucent ivory wings and a stinger (flies).")
def wasp(m):
    m.extra["palette"] = {"Base": P("wasp_500"), "Dark": P("wasp_900"), "Eye": P("amber_500"),
                          "Light": P("ivory_100")}
    body = m.piece("Body", "Dark", shadow=True)
    gold = m.piece("Abdomen", "Base")
    ellipsoid(body, (0, -0.4, 0.64), (0.3, 0.38, 0.3), seg=8, rings=4, axis="Y")  # thorax
    ellipsoid(body, (0, -0.9, 0.66), (0.28, 0.2, 0.26), seg=6, rings=4)  # head
    tube(body, [(0, -0.06, 0.6), (0, 0.2, 0.56)], [0.075, 0.075], seg=4)  # wasp waist
    # abdomen: gold / black rings, hanging slightly, ending in a point
    ys = [0.16, 0.3, 0.5, 0.64, 0.86, 1.0, 1.22, 1.38, 1.62]
    rs = [0.1, 0.3, 0.4, 0.4, 0.37, 0.33, 0.24, 0.16, 0.0]
    pts = [(0, y, 0.58 - 0.16 * ((y - 0.16) / 1.46) ** 1.5) for y in ys]
    banded(gold, body, pts, rs, black_bands={2, 4, 6, 7}, seg=8)
    tube(body, [pts[-2], (0, 1.92, 0.34)], [0.07, 0.0], seg=4)  # stinger
    ellipsoid(gold, (0, -1.0, 0.6), (0.19, 0.1, 0.15), seg=6, rings=4)  # face
    for s in (-1, 1):
        gem(gold, (s * 0.2, -0.54, 0.9), 0.1, scale=(1, 1.3, 0.6))  # shoulder marks
        tube(body, X(s, [(0.08, -1.02, 0.82), (0.2, -1.22, 1.02), (0.3, -1.42, 1.0)]), [0.035, 0.03, 0.0], seg=3)
        for y in (-0.5, -0.26):  # legs tucked under the thorax
            tube(body, X(s, [(0.15, y, 0.42), (0.34, y + 0.08, 0.24), (0.28, y + 0.34, 0.06)]), [0.05, 0.04, 0.0], seg=3)
    eyes = m.piece("Eyes", "Eye", "Neon")
    for s in (-1, 1):
        gem(eyes, (s * 0.19, -0.98, 0.72), 0.085, scale=(0.8, 1, 1.2))
    fore = [(0.1, -0.54), (0.5, -0.6), (1.0, -0.48), (1.32, -0.26), (1.27, -0.12), (0.86, -0.02), (0.4, -0.16), (0.1, -0.34)]
    hind = [(0.1, -0.28), (0.46, -0.1), (0.82, 0.04), (0.88, 0.2), (0.6, 0.26), (0.24, 0.1)]
    for s, name, anim in ((1, "WingL", "FlapL"), (-1, "WingR", "FlapR")):
        w = m.piece(name, "Light", anim=anim, pivot=(s * 0.12, -0.44, 0.88), transparency=0.35)
        for outline in (fore, hind):
            pts2 = [(s * x, y) for x, y in outline]
            if s < 0:
                pts2.reverse()
            plate(w, pts2, 0.03, loc=(0, 0, 0.88), rot=(0, -s * 7, 0))


# ------------------------------------------------------------------ BEETLE WARRIOR (Skeleton id)

def disc(p, c, normal, radius, depth, seg=10):
    """Flat round disc facing `normal` (shield rims, plates)."""
    n = Vector(normal).normalized()
    rot = n.to_track_quat("Z", "Y").to_euler()
    pts = [(math.cos(2 * math.pi * k / seg) * radius, math.sin(2 * math.pi * k / seg) * radius) for k in range(seg)]
    return plate(p, pts, depth, loc=c, rot=tuple(math.degrees(a) for a in rot))


@register("BeetleWarrior", "Enemies", "Skeleton id. Upright armoured beetle soldier: horned steel helm, spear and shield.")
def beetle_warrior(m):
    m.extra["palette"] = {"Base": P("beetle_700"), "Light": P("beetle_500"), "Dark": P("chitin_900"),
                          "Eye": P("amber_500"), "Metal": P("steel_500"), "Wood": P("wood_700"), "White": P("steel_300")}
    shell = m.piece("Carapace", "Base", shadow=True)
    ellipsoid(shell, (0, -0.02, 2.6), (0.76, 0.58, 0.72), seg=8, rings=6)  # chest
    ec, er = (0, 0.28, 2.42), (0.86, 0.62, 1.02)
    gloss = m.piece("Gloss", "Light")
    for s in (-1, 1):  # elytra on the back
        ellipsoid(shell, ec, er, seg=12, rings=6,
                  keep=[((0, 0.28, 0), (0, 1, 0)), (ec, (s, 0, 0))], shift=(s * 0.03, 0, 0))
        ellipsoid(gloss, ec, (er[0] + 0.03, er[1] + 0.03, er[2] + 0.03), seg=12, rings=6,  # painted highlight
                  keep=[((0, 0.5, 0), (0, 1, 0)), ((s * 0.2, 0, 0), (s, 0, 0)), ((s * 0.52, 0, 0), (-s, 0, 0)),
                        ((0, 0, 2.55), (0, 0, 1))], shift=(s * 0.03, 0, 0))
        for k, (z, r) in enumerate(((3.12, 0.52), (2.86, 0.46))):  # layered shoulder plates
            pc = (s * (0.8 + k * 0.1), 0.0, z)
            ellipsoid(shell, pc, (r, r * 1.02, r * 0.66), seg=8, rings=4, keep=[(pc, (0, 0, 1))])
        pc = (s * 0.8, 0.0, 3.12)
        ellipsoid(gloss, pc, (0.55, 0.55, 0.37), seg=8, rings=4, keep=[((0, 0, 3.4), (0, 0, 1))])
    body = m.piece("Body", "Dark")
    ellipsoid(body, (0, 0.08, 1.7), (0.6, 0.5, 0.42), seg=8, rings=4)  # belly
    ellipsoid(body, (0, -0.16, 3.5), (0.38, 0.4, 0.36), seg=8, rings=4)  # face under the helm
    for s in (-1, 1):
        tube(body, X(s, [(0.14, -0.5, 3.28), (0.17, -0.7, 3.18), (0.05, -0.8, 3.1)]), [0.07, 0.05, 0.0], seg=3)
        tube(body, X(s, [(0.34, -0.1, 3.84), (0.64, -0.2, 4.02), (0.66, -0.36, 4.26), (0.42, -0.5, 4.36)]),
             [0.14, 0.12, 0.08, 0.0], seg=5)  # helm horns
    # right arm holding the spear (held still while the left arm swings)
    tube(body, [(-0.82, 0.0, 3.0), (-1.08, -0.12, 2.42), (-1.0, -0.5, 2.12)], [0.2, 0.17, 0.15], seg=5)
    gem(body, (-1.0, -0.56, 2.08), 0.2)
    helm = m.piece("Helm", "Metal", "Metal")
    hc = (0, -0.12, 3.56)
    ellipsoid(helm, hc, (0.5, 0.52, 0.52), seg=8, rings=6, keep=[(hc, (0, 0, 1))])
    helm.box((0.14, 0.12, 0.42), loc=(0, -0.62, 3.48), bevel=0)  # nasal guard
    helm.box((0.12, 0.86, 0.16), loc=(0, -0.1, 4.06), bevel=0)  # crest
    eyes = m.piece("Eyes", "Eye", "Neon")
    for s in (-1, 1):
        gem(eyes, (s * 0.18, -0.52, 3.42), 0.075)
    # left arm with a beetle-shell shield (swings)
    pivot = (0.82, 0.0, 3.0)
    arm = m.piece("ArmL", "Dark", anim="SwingA", pivot=pivot)
    tube(arm, [(0.82, 0.0, 3.0), (1.06, -0.04, 2.4), (1.04, -0.3, 1.98)], [0.2, 0.17, 0.15], seg=5)
    gem(arm, (1.04, -0.36, 1.92), 0.2)
    sc = Vector((1.3, -0.36, 2.2))
    nrm = Vector((0.85, -0.25, 0.45)).normalized()
    deg = tuple(math.degrees(a) for a in nrm.to_track_quat("Z", "Y").to_euler())
    shield = m.piece("Shield", "Base", anim="SwingA", pivot=pivot)
    ellipsoid(shield, sc, (0.58, 0.58, 0.24), seg=10, rings=4, rot=deg, keep=[(sc, nrm)])
    rim = m.piece("ShieldRim", "Metal", "Metal", anim="SwingA", pivot=pivot)
    disc(rim, sc - nrm * 0.04, nrm, 0.68, 0.1, seg=10)
    gem(rim, sc + nrm * 0.25, 0.13, scale=(1, 1, 0.7), rot=deg)  # boss
    spear = m.piece("Spear", "Wood")
    d = Vector((0, -0.38, 0.92)).normalized()
    f = Vector((-1.0, -0.58, 2.08))
    tube(spear, [f - d * 1.95, f + d * 1.75], [0.07, 0.07], seg=5)
    tip = m.piece("SpearTip", "White", "Metal")
    top = f + d * 1.75
    tube(tip, [top - d * 0.1, top + d * 0.1, top + d * 0.32, top + d * 0.75], [0.09, 0.16, 0.13, 0.0], seg=4, flat=0.35)
    for s, name, anim in ((1, "LegL", "SwingB"), (-1, "LegR", "SwingA")):
        leg = m.piece(name, "Dark", anim=anim, pivot=(s * 0.42, 0.05, 1.62))
        tube(leg, X(s, [(0.42, 0.05, 1.66), (0.56, -0.32, 0.98), (0.5, 0.1, 0.4), (0.52, -0.42, 0.06)]),
             [0.27, 0.23, 0.17, 0.06], seg=5)
        tube(leg, X(s, [(0.5, 0.1, 0.4), (0.5, 0.42, 0.08)]), [0.12, 0.0], seg=4)  # heel spur


# ------------------------------------------------------------------ PHASE MOTH (Ghost id)

@register("PhaseMoth", "Enemies", "Ghost id. Pale grey-lavender moth: translucent wings with slate eye-spots, glowing core (floats).")
def phase_moth(m):
    lavender = mix(mix("moth_300", "crimson_300", 0.14), "slate_300", 0.12)
    m.extra["palette"] = {"Base": mix(mix("moth_500", "crimson_300", 0.16), "stone_500", 0.25), "Light": lavender,
                          "Accent": P("slate_600"), "Glow": P("moth_glow"), "Eye": P("amber_500"),
                          "Dark": P("chitin_800"), "White": P("ivory_200")}
    body = m.piece("Body", "Base", shadow=True)
    ellipsoid(body, (0, -0.22, 1.55), (0.4, 0.42, 0.4), seg=8, rings=6, lumps=0.09, seed=5)  # fuzzy thorax
    ellipsoid(body, (0, -0.56, 1.6), (0.36, 0.2, 0.32), seg=8, rings=4, lumps=0.16, seed=9)  # ruff
    ellipsoid(body, (0, 0.4, 1.45), (0.23, 0.5, 0.23), seg=8, rings=6, axis="Y", taper=-0.25)  # abdomen
    ellipsoid(body, (0, -0.74, 1.6), (0.24, 0.2, 0.22), seg=6, rings=4)  # head
    legs = m.piece("Legs", "Dark")
    for s in (-1, 1):
        for y in (-0.4, -0.18, 0.04):
            tube(legs, X(s, [(0.18, y, 1.25), (0.42, y + 0.06, 1.05), (0.36, y + 0.28, 0.86)]), [0.05, 0.04, 0.0], seg=3)
    eyes = m.piece("Eyes", "Eye", "Neon")
    for s in (-1, 1):
        gem(eyes, (s * 0.16, -0.86, 1.66), 0.08)
    ant = m.piece("Antennae", "White", anim="Wiggle", pivot=(0, -0.8, 1.78))
    for s in (-1, 1):  # feathery antennae
        tube(ant, X(s, [(0.07, -0.84, 1.76), (0.26, -1.04, 2.08), (0.44, -1.12, 2.36), (0.58, -1.08, 2.52)]),
             [0.025, 0.09, 0.07, 0.0], seg=4, flat=0.3)
    core = m.piece("Core", "Glow", "Neon", anim="Pulse")
    gem(core, (0, -0.16, 1.98), 0.15, scale=(1, 1.35, 0.8))
    fore = [(0.12, -0.44), (0.55, -0.7), (1.1, -0.8), (1.5, -0.64), (1.6, -0.3), (1.36, 0.0), (0.82, 0.1),
            (0.32, 0.0), (0.12, -0.14)]
    hind = [(0.12, -0.06), (0.55, 0.06), (1.0, 0.24), (1.12, 0.58), (0.86, 0.9), (0.46, 0.84), (0.2, 0.44)]
    dihedral, zr = 16, 1.74
    for s, name, anim in ((1, "L", "FlutterL"), (-1, "R", "FlutterR")):
        piv = (s * 0.12, -0.2, zr)
        wing = m.piece("Wing" + name, "Light", anim=anim, pivot=piv, transparency=0.3)
        spots = m.piece("Spots" + name, "Accent", anim=anim, pivot=piv)
        for outline in (fore, hind):
            pts2 = [(s * x, y) for x, y in outline]
            if s < 0:
                pts2.reverse()
            plate(wing, pts2, 0.04, loc=(0, 0, zr), rot=(0, -s * dihedral, 0))
        annulus(spots, (s * 1.06, -0.4), 0.24, 0.1, 0.07, seg=8, loc=(0, 0, zr), rot=(0, -s * dihedral, 0))  # eye-spot
        ring = [(s * 0.74 + math.cos(2 * math.pi * k / 6) * 0.12, 0.52 + math.sin(2 * math.pi * k / 6) * 0.12) for k in range(6)]
        plate(spots, ring, 0.07, loc=(0, 0, zr), rot=(0, -s * dihedral, 0))
        rim = [(s * x, y) for x, y in ((1.36, -0.72), (1.56, -0.6), (1.64, -0.3), (1.5, -0.42))]  # dark wing tip
        if s < 0:
            rim.reverse()
        plate(spots, rim, 0.07, loc=(0, 0, zr), rot=(0, -s * dihedral, 0))


# ------------------------------------------------------------------ RHINO BEETLE (Brute id)

@register("RhinoBeetle", "Enemies", "Brute id. Heavy slate-blue armoured beetle with a big ivory horn.")
def rhino_beetle(m):
    m.extra["palette"] = {"Base": P("slate_400"), "Accent": P("slate_500"), "Light": P("slate_200"),
                          "Dark": P("chitin_900"), "White": P("ivory_200"), "Eye": P("amber_500")}
    shell = m.piece("Shell", "Base", shadow=True)
    ec, er = (0, 0.72, 1.5), (2.0, 2.05, 1.78)
    for s in (-1, 1):
        ellipsoid(shell, ec, er, seg=12, rings=8, axis="Y",
                  keep=[(ec, (0, 0, 1)), (ec, (s, 0, 0))], shift=(s * 0.06, 0, 0))
    gloss = m.piece("Gloss", "Light")
    for s in (-1, 1):  # painted highlight along each wing case
        ellipsoid(gloss, ec, (er[0] + 0.035, er[1] + 0.035, er[2] + 0.035), seg=12, rings=8, axis="Y",
                  keep=[((s * 0.42, 0, 0), (s, 0, 0)), ((s * 0.92, 0, 0), (-s, 0, 0)), ((0, 0, 2.95), (0, 0, 1)),
                        ((0, 1.9, 0), (0, -1, 0))], shift=(s * 0.06, 0, 0))
    pron = m.piece("Pronotum", "Accent")
    pc = (0, -1.08, 1.62)
    ellipsoid(pron, pc, (1.72, 1.02, 1.38), seg=12, rings=6, axis="Y", keep=[(pc, (0, 0, 1))])
    body = m.piece("Body", "Dark")
    ellipsoid(body, (0, -2.12, 1.3), (0.86, 0.76, 0.64), seg=8, rings=6)  # head
    ellipsoid(body, (0, 0.2, 1.5), (1.78, 2.4, 0.82), seg=10, rings=4, keep=[((0, 0, 1.5), (0, 0, -1))])  # underside
    horns = m.piece("Horns", "White")
    tube(horns, [(0, -1.5, 2.75), (0, -1.86, 3.26), (0, -1.98, 3.7)], [0.3, 0.17, 0.0], seg=5)  # pronotum horn
    horn = m.piece("Horn", "White", anim="Jaw", pivot=(0, -2.25, 1.5))
    tube(horn, [(0, -2.5, 1.42), (0, -3.18, 1.72), (0, -3.56, 2.45), (0, -3.5, 3.5), (0, -3.18, 4.3), (0, -2.9, 4.72)],
         [0.52, 0.44, 0.36, 0.27, 0.15, 0.0], seg=6)
    for s in (-1, 1):  # forked tip
        tube(horn, [(0, -3.3, 4.05), (s * 0.3, -3.52, 4.38), (s * 0.38, -3.56, 4.6)], [0.12, 0.08, 0.0], seg=4)
    eyes = m.piece("Eyes", "Eye", "Neon")
    for s in (-1, 1):
        gem(eyes, (s * 0.62, -2.56, 1.48), 0.12)
    # six legs, each on its own hip joint, stepping in two alternating tripods
    for i, (y, dk, df) in enumerate(((-1.22, -0.36, -0.82), (0.25, 0.0, 0.1), (1.66, 0.36, 0.84))):
        for s, side in ((1, "L"), (-1, "R")):
            anim = "SwingA" if (i % 2 == 0) == (s > 0) else "SwingB"
            hip = (s * 1.25, y, 1.15)
            leg = m.piece(f"Leg{side}{i + 1}", "Dark", anim=anim, pivot=hip)
            knee = (s * 2.15, y + dk, 1.78)
            ankle = (s * 2.36, y + df, 0.4)
            tube(leg, [hip, knee, ankle, (s * 2.42, y + df * 1.12, 0.0)], [0.33, 0.28, 0.17, 0.0], seg=5)
            for t in (0.35, 0.7):  # tibia spurs
                q = Vector(knee).lerp(Vector(ankle), t)
                tube(leg, [q, q + Vector((s * 0.3, 0.0, 0.16))], [0.08, 0.0], seg=3)


# ------------------------------------------------------------------ BOMB TICK (Bomber id)

@register("BombTick", "Enemies", "Bomber id. Bloated crimson tick with glowing amber spots that pulse: explosive.")
def bomb_tick(m):
    m.extra["palette"] = {"Base": P("tick_500"), "Dark": P("chitin_900"), "Glow": P("tick_glow"),
                          "Eye": P("amber_500")}
    ac, ar = (0, 0.32, 1.12), (1.2, 1.36, 1.0)
    sac = m.piece("Abdomen", "Base", shadow=True)
    ellipsoid(sac, ac, ar, seg=12, rings=8, axis="Y", taper=0.16, keep=[((0, 0, 0.2), (0, 0, 1))])  # engorged sac
    body = m.piece("Body", "Dark")
    ellipsoid(body, (0, -0.86, 1.02), (0.6, 0.42, 0.42), seg=8, rings=6, axis="Y", keep=[((0, 0, 0.62), (0, 0, 1))])  # shield
    ellipsoid(body, (0, -1.24, 0.72), (0.36, 0.34, 0.28), seg=8, rings=4)  # capitulum
    tube(body, [(0, -1.5, 0.68), (0, -1.86, 0.6)], [0.1, 0.0], seg=4)  # barbed beak
    for s in (-1, 1):
        tube(body, X(s, [(0.2, -1.46, 0.72), (0.27, -1.72, 0.64), (0.22, -1.86, 0.56)]), [0.09, 0.07, 0.0], seg=4)  # palps
    spots = m.piece("Spots", "Glow", "Neon", anim="Throb")
    stud(spots, ac, ar, (0, 0.42, 1), 0.38, taper=0.16)  # the big one on top
    for sx in (-1, 1):
        for d, size in (((0.66, -0.05, 1), 0.27), ((0.62, 0.95, 0.9), 0.27), ((0.36, 1.45, 0.42), 0.2)):
            stud(spots, ac, ar, (sx * d[0], d[1], d[2]), size, taper=0.16)
    eyes = m.piece("Eyes", "Eye", "Neon")
    for s in (-1, 1):
        gem(eyes, (s * 0.36, -1.08, 1.0), 0.08)
    for s, name, anim in ((1, "LegsL", "SwingA"), (-1, "LegsR", "SwingB")):
        legs = m.piece(name, "Dark", anim=anim, pivot=(s * 0.55, -0.55, 0.6))
        for y, dk, df in ((-1.0, -0.36, -0.66), (-0.72, -0.1, -0.22), (-0.44, 0.16, 0.3), (-0.16, 0.42, 0.76)):
            tube(legs, X(s, [(0.52, y, 0.6), (1.2, y + dk, 0.98), (1.42, y + df, 0.0)]), [0.11, 0.09, 0.0], seg=4)


# ------------------------------------------------------------------ SCORPION QUEEN (Boss id)

@register("ScorpionQueen", "Enemies", "Boss. Crimson scorpion queen: antique-gold plates and crown, huge claws, amber stinger.")
def scorpion_queen(m):
    m.extra["palette"] = {"Base": P("crimson_500"), "Accent": P("crimson_800"), "Gold": P("gold_500"),
                          "Dark": P("chitin_900"), "Eye": P("amber_500"), "Light": P("amber_500"), "Glow": P("amber_300")}
    shell = m.piece("Carapace", "Base", shadow=True)
    gold = m.piece("Plates", "Gold", "Metal")
    hc, hr = (0, -2.55, 2.3), (2.5, 1.75, 1.35)
    ellipsoid(shell, hc, hr, seg=12, rings=8, axis="Y", keep=[(hc, (0, 0, 1))])  # head shield
    for i in range(6):  # overlapping back plates: crimson with a broad gold rear rim and a keel spike
        y = -1.15 + i * 0.82
        w = 2.55 - abs(i - 1.5) * 0.12 - max(0, i - 3) * 0.2
        c, r = (0, y, 2.25), (w, 0.66, 1.18 - max(0, i - 3) * 0.08)
        ellipsoid(shell, c, r, seg=12, rings=4, axis="Y", keep=[(c, (0, 0, 1))])
        ellipsoid(gold, c, (r[0] + 0.05, r[1] + 0.05, r[2] + 0.05), seg=12, rings=4, axis="Y",
                  keep=[(c, (0, 0, 1)), ((0, y + 0.3, 0), (0, 1, 0))])
        top = Vector((0, y + 0.1, c[2] + r[2] - 0.08))
        tube(gold, [top, top + Vector((0, 0.32, 0.42))], [0.2, 0.0], seg=4)
    # crown: a gold band across the head shield behind the eyes, five spikes
    ellipsoid(gold, hc, (hr[0] + 0.05, hr[1] + 0.05, hr[2] + 0.05), seg=12, rings=8, axis="Y",
              keep=[(hc, (0, 0, 1)), ((0, -3.15, 0), (0, 1, 0)), ((0, -2.65, 0), (0, -1, 0))])
    for x, h, lean in ((0, 1.75, 0.0), (0.42, 1.35, 0.3), (0.78, 1.0, 0.6)):
        for s in ((1,) if x == 0 else (-1, 1)):
            base = on_ellipsoid(hc, hr, (s * x, -0.32, 1))[0] - Vector((0, 0, 0.15))
            tube(gold, [base, base + Vector((s * lean * 0.45, 0.12, h * 0.55)), base + Vector((s * lean, 0.22, h))],
                 [0.3, 0.19, 0.0], seg=4)
    body = m.piece("Body", "Dark")
    ellipsoid(body, (0, 0.1, 1.95), (2.3, 4.3, 0.95), seg=10, rings=4, keep=[((0, 0, 2.3), (0, 0, -1))])
    jaws = m.piece("Mandibles", "Dark", anim="Jaw", pivot=(0, -4.1, 2.3))
    for s in (-1, 1):  # chelicerae
        tube(jaws, X(s, [(0.42, -4.05, 2.25), (0.4, -4.75, 2.05), (0.12, -5.05, 1.92)]), [0.24, 0.18, 0.0], seg=5)
    eyes = m.piece("Eyes", "Eye", "Neon")
    for s in (-1, 1):
        gem(eyes, (s * 0.36, -3.62, 3.48), 0.2, scale=(1, 1, 0.8))
        for x, y, z in ((1.55, -3.85, 3.0), (1.8, -3.55, 2.95), (1.3, -4.05, 2.9)):
            gem(eyes, (s * x, y, z), 0.11)
    for s, side in ((1, "L"), (-1, "R")):
        shoulder = (s * 1.9, -3.3, 2.35)
        claw = m.piece("Claw" + side, "Base", anim="Jaw", pivot=shoulder)
        tube(claw, [shoulder, (s * 3.55, -4.0, 2.95), (s * 4.05, -5.5, 2.85)], [0.62, 0.55, 0.5], seg=6)
        hand_c, hand_r = (s * 3.85, -6.55, 2.75), (1.08, 1.48, 0.9)
        ellipsoid(claw, hand_c, hand_r, seg=10, rings=6, axis="Y")
        plate_ = m.piece("ClawPlate" + side, "Gold", "Metal", anim="Jaw", pivot=shoulder)
        ellipsoid(plate_, hand_c, (hand_r[0] + 0.05, hand_r[1] + 0.05, hand_r[2] + 0.05), seg=10, rings=6, axis="Y",
                  keep=[((0, 0, hand_c[2] + 0.42), (0, 0, 1)), ((hand_c[0] - 0.42, 0, 0), (1, 0, 0)),
                        ((hand_c[0] + 0.42, 0, 0), (-1, 0, 0))])
        tips = m.piece("ClawTips" + side, "Dark", anim="Jaw", pivot=shoulder)
        tube(tips, [(s * 4.3, -7.6, 2.75), (s * 4.3, -8.5, 2.72), (s * 3.8, -9.2, 2.68)], [0.5, 0.36, 0.0], seg=5)
        tube(tips, [(s * 3.35, -7.65, 2.75), (s * 3.0, -8.45, 2.72), (s * 3.32, -9.02, 2.68)], [0.42, 0.3, 0.0], seg=5)
    # eight legs, alternating steps, each on its own hip
    for i, (y, dk, df) in enumerate(((-1.75, -0.9, -1.75), (-0.45, -0.3, -0.5), (0.85, 0.3, 0.6), (2.15, 0.9, 1.75))):
        for s, side in ((1, "L"), (-1, "R")):
            anim = "SwingA" if (i % 2 == 0) == (s > 0) else "SwingB"
            hip = (s * 2.0, y, 2.05)
            leg = m.piece(f"Leg{side}{i + 1}", "Accent", anim=anim, pivot=hip)
            tube(leg, [hip, (s * 4.0, y + dk * 0.55, 3.75), (s * 5.85, y + dk, 1.2), (s * 6.55, y + df, 0.0)],
                 [0.44, 0.38, 0.24, 0.0], seg=5)
    tail_pts = [(0, 3.15, 2.6), (0, 4.5, 3.4), (0, 5.4, 5.05), (0, 5.6, 7.0), (0, 5.1, 8.85), (0, 3.95, 10.25), (0, 2.45, 10.95)]
    tail_r = [1.0, 0.92, 0.84, 0.76, 0.7, 0.64, 0.6]
    pivot = tail_pts[0]
    tail = m.piece("Tail", "Base", anim="Tail", pivot=pivot, shadow=True)
    rings = m.piece("TailPlates", "Gold", "Metal", anim="Tail", pivot=pivot)
    for i in range(len(tail_pts) - 1):  # bulging segments with gold joint rings
        a, b = Vector(tail_pts[i]), Vector(tail_pts[i + 1])
        r0, r1 = tail_r[i], tail_r[i + 1]
        tube(tail, [a, a.lerp(b, 0.5), b], [r0 * 0.8, (r0 + r1) * 0.62, r1 * 0.8], seg=7)
        if i:
            d = (b - a).normalized()
            tube(rings, [a - d * 0.12, a + d * 0.12], [r0 * 0.88, r0 * 0.88], seg=7)
    sting = m.piece("Stinger", "Light", anim="Tail", pivot=pivot)
    bulb = Vector((0, 1.95, 10.9))
    ellipsoid(sting, bulb, (0.74, 0.98, 0.74), seg=8, rings=6, axis="Y")
    barb = m.piece("Barb", "Dark", anim="Tail", pivot=pivot)
    tip = bulb + Vector((0, -1.45, -1.25))
    tube(barb, [bulb + Vector((0, -0.6, -0.1)), bulb + Vector((0, -1.25, -0.55)), tip], [0.38, 0.22, 0.0], seg=5)
    venom = m.piece("Venom", "Glow", "Neon", anim="Tail", pivot=pivot)
    gem(venom, tip + Vector((0, 0.02, -0.12)), 0.16, scale=(1, 1, 1.4))
