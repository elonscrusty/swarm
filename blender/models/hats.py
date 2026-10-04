"""Headgear: the twelve skin hats (category "Hats") and the shape kit the heroes share.

STANDARD BARE HEAD
  Every hero's plain `Head` piece is the same block: 1.45 wide (X) x 1.35 deep (Y) x
  1.4 tall (Z) in Blender studs = Roblox Size (1.45, 1.4, 1.35), centred 5.15 studs above the
  feet, so its top centre (HEAD_TOP) sits at 5.85. Face pieces (eyes, hair, beard) stay within
  about 0.08 above / 0.1 behind that block.

HAT MODELS ("Hat_<Shape>")
  Origin = the head-top centre, front = -Y, so the head occupies x +-0.725, y +-0.675,
  z -1.4..0 in hat space. The game welds a hat at Head.CFrame * (0, Head.Size.Y / 2, 0).
  Slots: Hat (main colour) and HatAccent (plume, band, horns, jewels), plus Gold (trim) and
  Dark (visor slits, eye patch) which follow the hero's palette.

The heroes' own headgear (Knight helm, Mage hat, Rogue hood, Priest mitre) is built by the
same functions at HEAD_TOP, so a skin hat and a default headgear always fit the same way.

Shape kit (module functions that add geometry to a swarmkit Piece; every solid is closed,
because Roblox culls back faces):
  lathe     faceted solid of revolution from an open (radius, z) profile, capped
  revolve   closed (radius, z) outline revolved: rings, bands, brims, halos
  arc_shell curved sheet with thickness around Z: capes, cloaks, neck guards, cowls
  sweep     tube along a path with varying radius: plumes, horns, staffs, scarf tails
  slab      extruded bevelled outline: shields, blades, mitre panels, feathers
  block     bevelled box with independent top/bottom size and a top shift
  mark/turn rotate the geometry added since a mark around a pivot (tilted hats)
"""

import math

import bmesh
from mathutils import Euler, Matrix, Vector

from style import P
from swarmkit import Piece, mat, register

HEAD_SIZE = (1.45, 1.35, 1.4)
HEAD_Z = 5.15
HEAD_TOP = HEAD_Z + HEAD_SIZE[2] / 2  # 5.85


# ---------------------------------------------------------------------------------- kit

def at(o, x, y, z):
    return (o[0] + x, o[1] + y, o[2] + z)


def _ring_faces(t, a, b, seg):
    """Faces between two rings (a ring of one vertex is a pole)."""
    if len(a) == 1 and len(b) == 1:
        return
    if len(a) == 1:
        for i in range(seg):
            t.faces.new((a[0], b[(i + 1) % seg], b[i]))
    elif len(b) == 1:
        for i in range(seg):
            t.faces.new((a[i], a[(i + 1) % seg], b[0]))
    else:
        for i in range(seg):
            j = (i + 1) % seg
            t.faces.new((a[i], a[j], b[j], b[i]))


def _done(p, t, loc, rot, deform=None):
    if deform:
        for v in t.verts:
            v.co = Vector(deform(Vector(v.co)))
    bmesh.ops.recalc_face_normals(t, faces=t.faces)
    return p._merge(t, mat(loc, rot))


def _xy(a, r, sx, sy):
    return math.sin(a) * r * sx, -math.cos(a) * r * sy


def lathe(p, profile, seg=8, loc=(0, 0, 0), rot=(0, 0, 0), sx=1.0, sy=1.0, phase=0.0, deform=None):
    """Solid of revolution around local Z. profile = [(radius, z), ...] bottom to top; a radius
    of 0 makes a pole. phase 0 puts a vertex at the front (-Y): a ridge, like a breastplate;
    phase 180/seg puts a flat face at the front. sx / sy squash the cross-section."""
    t = bmesh.new()
    rings = []
    for r, z in profile:
        if r < 1e-4:
            rings.append([t.verts.new((0, 0, z))])
            continue
        ring = []
        for i in range(seg):
            x, y = _xy(math.radians(phase) + i / seg * math.tau, r, sx, sy)
            ring.append(t.verts.new((x, y, z)))
        rings.append(ring)
    for a, b in zip(rings, rings[1:]):
        _ring_faces(t, a, b, seg)
    if len(rings[0]) > 2:
        t.faces.new(list(reversed(rings[0])))
    if len(rings[-1]) > 2:
        t.faces.new(rings[-1])
    return _done(p, t, loc, rot, deform)


def revolve(p, loop, seg=8, loc=(0, 0, 0), rot=(0, 0, 0), sx=1.0, sy=1.0, phase=0.0, deform=None):
    """Closed (radius, z) outline revolved around local Z (a ring / torus-like solid)."""
    t = bmesh.new()
    grid = []
    for i in range(seg):
        a = math.radians(phase) + i / seg * math.tau
        grid.append([t.verts.new((*_xy(a, r, sx, sy), z)) for r, z in loop])
    n = len(loop)
    for i in range(seg):
        A, B = grid[i], grid[(i + 1) % seg]
        for k in range(n):
            q = (k + 1) % n
            t.faces.new((A[k], A[q], B[q], B[k]))
    return _done(p, t, loc, rot, deform)


def band(p, r_in, r_out, z0, z1, seg=8, **kw):
    """Flat ring (crown band, hat band, belt) from z0 to z1."""
    return revolve(p, [(r_in, z0), (r_out, z0), (r_out, z1), (r_in, z1)], seg=seg, **kw)


def arc_shell(p, rows, a0, a1, seg=8, thick=0.1, loc=(0, 0, 0), rot=(0, 0, 0), sx=1.0, sy=1.0,
              hem=None, deform=None):
    """Curved sheet with thickness around local Z. rows = [(radius, z, dy), ...] top to bottom;
    dy moves that row's arc centre back (+Y) so capes flare. Angles in degrees: 0 = front (-Y),
    90 = left (+X), 180 = back. A full turn makes a closed collar. hem(column) adds z to the
    bottom row (tattered or pointed hems)."""
    full = (a1 - a0) >= 359.99
    cols = seg if full else seg + 1
    t = bmesh.new()
    outer, inner = [], []
    last = len(rows) - 1
    for k, (r, z, dy) in enumerate(rows):
        orow, irow = [], []
        for c in range(cols):
            a = math.radians(a0 + (a1 - a0) * c / seg)
            zz = z + (hem(c) if hem and k == last else 0.0)
            x, y = _xy(a, r, sx, sy)
            orow.append(t.verts.new((x, y + dy, zz)))
            x, y = _xy(a, max(r - thick, 0.02), sx, sy)
            irow.append(t.verts.new((x, y + dy, zz)))
        outer.append(orow)
        inner.append(irow)

    def nxt(c):
        return (c + 1) % cols if full else c + 1

    for k in range(len(rows) - 1):
        for c in range(seg):
            d = nxt(c)
            t.faces.new((outer[k][c], outer[k][d], outer[k + 1][d], outer[k + 1][c]))
            t.faces.new((inner[k][d], inner[k][c], inner[k + 1][c], inner[k + 1][d]))
    for k in (0, last):
        for c in range(seg):
            d = nxt(c)
            t.faces.new((outer[k][c], inner[k][c], inner[k][d], outer[k][d]))
    if not full:
        for c in (0, cols - 1):
            for k in range(len(rows) - 1):
                t.faces.new((outer[k][c], outer[k + 1][c], inner[k + 1][c], inner[k][c]))
    return _done(p, t, loc, rot, deform)


def sweep(p, points, radii, seg=6, sx=1.0, loc=(0, 0, 0), rot=(0, 0, 0), up=(1, 0, 0), phase=0.0,
          deform=None):
    """Tube along a path with a radius per point (0 = pointed end). The cross-section is
    stretched by sx along `up` (projected off the path): sx > 1 gives flat ribbons, feathers
    and plumes that read from above."""
    pts = [Vector(q) for q in points]
    n = len(pts)
    tan = [(pts[min(i + 1, n - 1)] - pts[max(i - 1, 0)]).normalized() for i in range(n)]
    ref = Vector(up)
    if abs(ref.dot(tan[0])) > 0.95:
        ref = Vector((0, 1, 0)) if abs(tan[0].y) < 0.9 else Vector((0, 0, 1))
    nrm = (ref - ref.project(tan[0])).normalized()
    t = bmesh.new()
    rings = []
    for i in range(n):
        nrm = (nrm - nrm.project(tan[i])).normalized()  # parallel transport
        bin_ = tan[i].cross(nrm)
        r = radii[i]
        if r < 1e-4:
            rings.append([t.verts.new(pts[i])])
            continue
        ring = []
        for k in range(seg):
            a = math.radians(phase) + k / seg * math.tau
            ring.append(t.verts.new(pts[i] + nrm * (math.cos(a) * r * sx) + bin_ * (math.sin(a) * r)))
        rings.append(ring)
    for a, b in zip(rings, rings[1:]):
        _ring_faces(t, a, b, seg)
    if len(rings[0]) > 2:
        t.faces.new(list(reversed(rings[0])))
    if len(rings[-1]) > 2:
        t.faces.new(rings[-1])
    return _done(p, t, loc, rot, deform)


def slab(p, outline, depth, loc=(0, 0, 0), rot=(0, 0, 0), bevel=0.0, deform=None):
    """Outline [(x, z), ...] (convex is safest) extruded `depth` along Y, edges bevelled."""
    t = bmesh.new()
    vs = [t.verts.new((x, -depth / 2, z)) for x, z in outline]
    face = t.faces.new(vs)
    ext = bmesh.ops.extrude_face_region(t, geom=[face])
    moved = [e for e in ext["geom"] if isinstance(e, bmesh.types.BMVert)]
    bmesh.ops.translate(t, vec=(0, depth, 0), verts=moved)
    bmesh.ops.recalc_face_normals(t, faces=t.faces)
    if bevel > 0:
        bmesh.ops.bevel(t, geom=list(t.edges), offset=min(bevel, depth * 0.45), segments=1,
                        affect="EDGES", profile=0.5, clamp_overlap=True)
    return _done(p, t, loc, rot, deform)


def block(p, size, loc=(0, 0, 0), rot=(0, 0, 0), top=(1.0, 1.0), bottom=(1.0, 1.0), shift=(0.0, 0.0),
          bevel=0.06, deform=None):
    """Bevelled box; top / bottom scale those faces, shift moves the top face (x, y)."""
    t = bmesh.new()
    bmesh.ops.create_cube(t, size=1.0)
    for v in t.verts:
        x, y, z = v.co.x * size[0], v.co.y * size[1], v.co.z * size[2]
        if v.co.z > 0:
            x, y = x * top[0] + shift[0], y * top[1] + shift[1]
        else:
            x, y = x * bottom[0], y * bottom[1]
        v.co = Vector((x, y, z))
    Piece._bevel(t, min(bevel, min(size) * 0.3))
    return _done(p, t, loc, rot, deform)


def mark(p):
    """Vertex count of a piece so far (use with turn)."""
    return len(p.bm.verts)


def turn(p, start, pivot, rot):
    """Rotate the geometry added to piece p since mark `start` around `pivot` (degrees XYZ)."""
    p.bm.verts.ensure_lookup_table()
    m = Matrix.Translation(Vector(pivot)) @ Euler([math.radians(a) for a in rot], "XYZ").to_matrix().to_4x4() \
        @ Matrix.Translation(-Vector(pivot))
    bmesh.ops.transform(p.bm, matrix=m, verts=p.bm.verts[start:])


def aim(d):
    """Euler (degrees) turning local -Y toward direction d (for guards and blades)."""
    d = Vector(d).normalized()
    q = (-d).to_track_quat("Y", "Z")
    return tuple(math.degrees(a) for a in q.to_euler("XYZ"))


# ---------------------------------------------------------------------------------- hats
# Each builder adds its pieces to model m around origin o (the head-top centre).
# bone is "Head" on heroes and None on Hat_ models.

def hat_helmet(m, o=(0, 0, 0), bone=None):
    """Great helm: faceted bucket with a flat face, dark T visor, gold brow band and a
    crimson horsehair plume arcing back (the Knight's own headgear)."""
    helm = m.piece("Helm", "Hat", bone=bone, shadow=True)  # big shell: no Metal sheen
    lathe(helm, [(0.88, -1.62), (0.97, -1.3), (0.99, -0.55), (0.98, 0.02), (0.85, 0.25), (0.5, 0.37),
                 (0.0, 0.4)], seg=8, phase=22.5, loc=o, sy=0.95)
    visor = m.piece("HelmVisor", "Dark", bone=bone)
    # flat front face (apothem 0.99 * cos 22.5 * 0.95 = 0.87): T slit, wrapping onto the side faces
    block(visor, (0.74, 0.12, 0.17), loc=at(o, 0, -0.875, -0.6), bevel=0)
    for s in (1, -1):
        block(visor, (0.3, 0.12, 0.17), loc=at(o, s * 0.52, -0.66, -0.6), rot=(0, 0, s * 47), bevel=0)
    block(visor, (0.17, 0.12, 0.62), loc=at(o, 0, -0.875, -0.98), bevel=0)
    trim = m.piece("HelmTrim", "Gold", "Metal", bone=bone)
    band(trim, 0.95, 1.02, -0.36, -0.2, loc=o, phase=22.5, sy=0.95)
    trim.cyl(0.2, 0.15, 0.16, seg=6, loc=at(o, 0, -0.1, 0.42))
    plume = m.piece("Plume", "HatAccent", bone=bone)
    sweep(plume, [(0, -0.22, 0.32), (0, -0.02, 0.74), (0, 0.36, 0.9), (0, 0.76, 0.76), (0, 1.02, 0.42),
                  (0, 1.12, 0.0), (0, 1.06, -0.44)],
          [0.2, 0.34, 0.38, 0.34, 0.27, 0.17, 0.03], seg=6, sx=1.75, loc=o)


def hat_plume(m, o=(0, 0, 0), bone=None):
    """Parade helm: open-faced rounded dome with cheek guards, a flared neck guard, nasal bar,
    gold brow band and a tall brush crest."""
    helm = m.piece("Helm", "Hat", "Metal", bone=bone, shadow=True)
    lathe(helm, [(0.96, -0.72), (0.99, -0.42), (0.93, -0.04), (0.74, 0.24), (0.4, 0.4), (0.0, 0.45)],
          seg=8, phase=22.5, loc=o, sy=0.97)
    arc_shell(helm, [(0.97, -0.6, 0.0), (1.08, -1.05, 0.06), (1.18, -1.32, 0.12)], 108, 252, seg=4, thick=0.1,
              loc=o)
    for s in (1, -1):
        slab(helm, [(-0.34, 0.12), (0.36, 0.12), (0.34, -0.42), (0.02, -0.74), (-0.32, -0.5)], 0.12,
             loc=at(o, s * 0.92, -0.16, -0.6), rot=(0, 0, 90 - s * 9), bevel=0.04)
    block(helm, (0.15, 0.12, 0.6), loc=at(o, 0, -0.9, -0.66), bevel=0.04)
    trim = m.piece("HelmTrim", "Gold", "Metal", bone=bone)
    band(trim, 0.94, 1.02, -0.76, -0.6, loc=o, phase=22.5, sy=0.97)
    sweep(trim, [(0, -0.72, 0.18), (0, -0.35, 0.4), (0, 0.1, 0.47), (0, 0.55, 0.36), (0, 0.85, 0.1)],
          [0.08, 0.09, 0.09, 0.09, 0.08], seg=4, sx=1.6, loc=o)
    crest = m.piece("Plume", "HatAccent", bone=bone)
    slab(crest, [(-0.66, 0.3), (-0.6, 0.72), (-0.3, 1.05), (0.15, 1.2), (0.62, 1.12), (0.98, 0.84),
                 (1.12, 0.4), (1.0, 0.1), (0.5, 0.42), (-0.2, 0.48)], 0.4, loc=o, rot=(0, 0, 90), bevel=0.1)


def hat_horns(m, o=(0, 0, 0), bone=None):
    """Horned helm: closed dark dome with an angry brow, slanted eye slits and two big horns
    sweeping out and up (they read as a wide V from the camera)."""
    helm = m.piece("Helm", "Hat", "Metal", bone=bone, shadow=True)
    lathe(helm, [(0.88, -1.6), (0.97, -1.22), (0.99, -0.5), (0.94, -0.04), (0.72, 0.26), (0.34, 0.4),
                 (0.0, 0.43)], seg=8, loc=o, sy=0.95)
    for s in (1, -1):
        block(helm, (0.68, 0.26, 0.2), loc=at(o, s * 0.36, -0.84, -0.4), rot=(0, s * -12, s * 21.4), bevel=0.05)
    slits = m.piece("HelmVisor", "Dark", bone=bone)
    for s in (1, -1):
        block(slits, (0.42, 0.12, 0.12), loc=at(o, s * 0.37, -0.83, -0.62), rot=(0, s * -14, s * 21.4), bevel=0.03)
    block(slits, (0.12, 0.12, 0.5), loc=at(o, 0, -0.93, -1.05), bevel=0.03)
    trim = m.piece("HelmTrim", "Gold", "Metal", bone=bone)
    revolve(trim, [(0.84, -1.64), (0.94, -1.64), (0.96, -1.48), (0.87, -1.48)], seg=8, loc=o, sy=0.95)
    for s in (1, -1):
        trim.cyl(0.3, 0.3, 0.16, seg=6, loc=at(o, s * 0.96, 0.0, -0.42), rot=(0, 90, 0))
    horns = m.piece("Horns", "HatAccent", bone=bone)
    for s in (1, -1):
        sweep(horns, [(s * 0.86, 0.0, -0.42), (s * 1.22, -0.02, -0.36), (s * 1.52, -0.02, -0.08),
                      (s * 1.64, -0.06, 0.32), (s * 1.54, -0.14, 0.72), (s * 1.32, -0.24, 0.96)],
              [0.27, 0.24, 0.2, 0.15, 0.09, 0.01], seg=6, loc=o, up=(0, 1, 0))


def hat_crown(m, o=(0, 0, 0), bone=None):
    """Gold crown sitting on the hair: a thick band with five points and jewels."""
    crown = m.piece("Crown", "Hat", "Metal", bone=bone, shadow=True)
    band(crown, 0.8, 0.92, -0.3, 0.1, seg=10, loc=o)
    for i in range(5):
        a = i * 72
        x, y = _xy(math.radians(a), 0.87, 1, 1)
        crown.cyl(0.25, 0.0, 0.5, seg=4, loc=at(o, x, y, 0.33), rot=(0, 0, a), scale=(1.0, 0.5))
        crown.ico(0.075, loc=at(o, x, y, 0.62), subdiv=0)
    gems = m.piece("CrownGems", "HatAccent", bone=bone)
    gems.ico(0.15, loc=at(o, 0, -0.93, -0.1), scale=(1.0, 0.55, 1.25), subdiv=1)
    for i in range(1, 5):
        a = math.radians(i * 72 - 36)
        x, y = _xy(a, 0.93, 1, 1)
        gems.ico(0.08, loc=at(o, x, y, -0.1), scale=(1.0, 1.0, 1.2), subdiv=0)


def hat_wizard(m, o=(0, 0, 0), bone=None):
    """Wide-brim pointed hat with a gold band; the tip bends back (the Mage's own hat)."""
    hat = m.piece("Hat", "Hat", bone=bone, shadow=True)
    revolve(hat, [(0.6, -0.4), (1.62, -0.48), (1.62, -0.4), (0.6, -0.28)], seg=10, loc=o)
    sweep(hat, [(0, 0, -0.36), (0, 0.02, 0.1), (0, 0.1, 0.52), (0, 0.28, 0.9), (0, 0.55, 1.13),
                (0, 0.88, 1.16)], [0.99, 0.88, 0.62, 0.36, 0.16, 0.02], seg=8, loc=o)
    trim = m.piece("HatBand", "HatAccent", "Metal", bone=bone)
    revolve(trim, [(0.94, -0.35), (1.03, -0.35), (0.97, -0.05), (0.88, -0.05)], seg=8, loc=o)


def hat_tophat(m, o=(0, 0, 0), bone=None):
    """Tall top hat with a band and a gold buckle, worn at a jaunty tilt."""
    hat = m.piece("Hat", "Hat", bone=bone, shadow=True)
    k = mark(hat)
    revolve(hat, [(0.6, -0.16), (1.16, -0.12), (1.18, -0.04), (0.6, -0.07)], seg=10, loc=o, sy=0.92)
    lathe(hat, [(0.8, -0.12), (0.8, 0.45), (0.88, 1.0), (0.0, 1.0)], seg=10, loc=o, sy=0.9)
    turn(hat, k, o, (-6, 7, 0))
    trim = m.piece("HatBand", "HatAccent", bone=bone)
    k = mark(trim)
    band(trim, 0.78, 0.86, -0.06, 0.22, seg=10, loc=o, sy=0.9)
    turn(trim, k, o, (-6, 7, 0))
    buckle = m.piece("HatBuckle", "Gold", "Metal", bone=bone)
    k = mark(buckle)
    block(buckle, (0.3, 0.08, 0.26), loc=at(o, 0, -0.79, 0.08), bevel=0.03)
    turn(buckle, k, o, (-6, 7, 0))


def hat_halo(m, o=(0, 0, 0), bone=None):
    """Floating ring of light, tilted back a little."""
    halo = m.piece("Halo", "HatAccent", "Neon", bone=bone)
    band(halo, 0.6, 0.8, -0.045, 0.045, seg=16, loc=at(o, 0, 0.08, 0.42), rot=(14, 0, 0))


def hat_hood(m, o=(0, 0, 0), bone=None):
    """Soft pointed hood: rounded crown drawn back into a drooping tip, sides flaring onto the
    shoulders, a brow peak over the open face (the Rogue's own)."""
    hood = m.piece("Hood", "Hat", bone=bone, shadow=True)

    def lean(co):  # draw the crown back into the tip
        h = max(co.z, 0.0)
        return Vector((co.x * (1 - h * 0.25), co.y + h * 0.62, co.z))

    lathe(hood, [(0.99, -0.14), (0.99, 0.12), (0.86, 0.4), (0.6, 0.62), (0.28, 0.76), (0.0, 0.8)], seg=8,
          phase=22.5, loc=o, deform=lean)
    arc_shell(hood, [(0.99, -0.02, 0.0), (1.0, -0.6, 0.04), (1.06, -1.12, 0.07), (1.2, -1.5, 0.12)],
              52, 308, seg=8, thick=0.13, loc=o)
    arc_shell(hood, [(0.99, -0.02, 0.0), (1.0, -0.38, -0.05)], -60, 60, seg=4, thick=0.14, loc=o)
    sweep(hood, [(0, 0.52, 0.66), (0, 0.86, 0.6), (0, 1.08, 0.36), (0, 1.16, 0.0)], [0.22, 0.16, 0.09, 0.02],
          seg=6, loc=o)
    shade = m.piece("HoodShade", "Dark", bone=bone)
    arc_shell(shade, [(0.84, -0.1, 0.0), (0.84, -1.45, 0.04)], 36, 324, seg=8, thick=0.04, loc=o)


def hat_mitre(m, o=(0, 0, 0), bone=None):
    """Bishop's mitre: two pointed panels leaning together over a deep cap, gold band, stripe,
    cross and lappets (the Priest's own)."""
    mitre = m.piece("Mitre", "Hat", bone=bone, shadow=True)
    outline = [(-0.74, -0.36), (0.74, -0.36), (0.8, 0.5), (0.0, 1.34), (-0.8, 0.5)]
    for s in (1, -1):
        slab(mitre, outline, 0.2, loc=at(o, 0, s * 0.6, 0), rot=(s * 13, 0, 0), bevel=0.05)
    block(mitre, (1.46, 1.1, 0.95), loc=at(o, 0, 0, 0.1), top=(1.04, 0.5), bevel=0.06)
    trim = m.piece("MitreTrim", "HatAccent", "Metal", bone=bone)
    revolve(trim, [(1.06, -0.42), (1.15, -0.42), (1.15, -0.16), (1.06, -0.16)], seg=4, phase=45, loc=o,
            sx=0.74, sy=0.68)
    slab(trim, [(-0.13, -0.16), (0.13, -0.16), (0.13, 1.0), (-0.13, 1.0)], 0.06, loc=at(o, 0, -0.71, 0),
         rot=(-13, 0, 0), bevel=0.02)
    slab(trim, [(-0.32, 0.4), (0.32, 0.4), (0.32, 0.58), (-0.32, 0.58)], 0.07, loc=at(o, 0, -0.72, 0),
         rot=(-13, 0, 0), bevel=0.02)
    for s in (1, -1):
        block(trim, (0.22, 0.07, 1.2), loc=at(o, s * 0.3, 0.8, -0.95), rot=(-6, 0, 0), bottom=(1.25, 1.0),
              bevel=0.02)


def hat_bandana(m, o=(0, 0, 0), bone=None):
    """Pirate bandana tied at the back with two tails, an eye patch and a gold earring."""
    cloth = m.piece("Bandana", "Hat", bone=bone, shadow=True)
    k = mark(cloth)
    lathe(cloth, [(0.86, -0.58), (0.9, -0.3), (0.82, 0.02), (0.56, 0.16), (0.0, 0.2)], seg=8, phase=22.5,
          loc=o)
    turn(cloth, k, at(o, 0, 0, -0.3), (-12, 0, 0))
    cloth.ico(0.2, loc=at(o, 0, 0.9, -0.62), scale=(1.25, 0.8, 0.95), subdiv=1)
    for s in (1, -1):
        block(cloth, (0.22, 0.08, 0.66), loc=at(o, s * 0.15, 0.98, -0.98), rot=(-14, s * 16, 0),
              bottom=(1.5, 1.0), bevel=0.03)
    edge = m.piece("BandanaEdge", "HatAccent", bone=bone)
    k = mark(edge)
    band(edge, 0.85, 0.93, -0.6, -0.48, seg=8, phase=22.5, loc=o)
    turn(edge, k, at(o, 0, 0, -0.3), (-12, 0, 0))
    patch = m.piece("EyePatch", "Dark", bone=bone)
    block(patch, (0.38, 0.08, 0.32), loc=at(o, -0.3, -0.69, -0.72), bevel=0.06)
    k = mark(patch)
    band(patch, 0.74, 0.78, -0.035, 0.035, seg=8, phase=22.5, loc=at(o, 0, 0, -0.6))
    turn(patch, k, at(o, 0, 0, -0.6), (0, -24, 0))
    ring = m.piece("Earring", "Gold", "Metal", bone=bone)
    band(ring, 0.07, 0.12, -0.03, 0.03, seg=6, loc=at(o, 0.76, 0.05, -1.12), rot=(0, 90, 0))


def hat_beanie(m, o=(0, 0, 0), bone=None):
    """Snug wrapped cowl with an eye slit, a headband and two long trailing tails (ninja)."""
    cowl = m.piece("Cowl", "Hat", bone=bone, shadow=True)
    lathe(cowl, [(0.86, -0.52), (0.88, -0.26), (0.8, 0.03), (0.55, 0.15), (0.0, 0.18)], seg=8, phase=22.5,
          loc=o)
    lathe(cowl, [(0.9, -1.66), (0.88, -1.3), (0.86, -0.84)], seg=8, phase=22.5, loc=o)
    arc_shell(cowl, [(0.87, -0.48, 0.0), (0.87, -0.88, 0.0)], 64, 296, seg=6, thick=0.1, loc=o)
    tie = m.piece("Headband", "HatAccent", bone=bone)
    band(tie, 0.86, 0.94, -0.44, -0.26, seg=8, phase=22.5, loc=o)
    tie.ico(0.16, loc=at(o, 0, 0.93, -0.36), scale=(1.2, 0.8, 0.9), subdiv=0)
    for s in (1, -1):
        sweep(tie, [(s * 0.06, 0.95, -0.36), (s * 0.22, 1.3, -0.5), (s * 0.34, 1.68, -0.52),
                    (s * 0.44, 2.0, -0.62)], [0.08, 0.075, 0.06, 0.01], seg=4, sx=2.0, loc=o,
              up=(0, 0, 1))


def hat_cap(m, o=(0, 0, 0), bone=None):
    """Ranger's peaked cap: rises to a point at the back, upturned brim, long feather."""
    cap = m.piece("Cap", "Hat", bone=bone, shadow=True)

    def lean(co):  # push the crown back as it rises: the Robin Hood peak
        h = max(co.z + 0.32, 0.0)
        return Vector((co.x, co.y + h * 0.55, co.z))

    lathe(cap, [(0.88, -0.32), (0.88, -0.1), (0.72, 0.22), (0.4, 0.42), (0.0, 0.5)], seg=8, phase=22.5,
          loc=o, sy=1.05, deform=lean)
    sweep(cap, [(0, 0.45, 0.3), (0, 0.85, 0.42), (0, 1.2, 0.36)], [0.3, 0.17, 0.02], seg=6, loc=o)

    def upturn(co):  # brim: flat peak at the front, turned up at the sides and back
        back = max(co.y + 0.35, 0.0)
        return Vector((co.x, co.y, co.z + back * 0.42))

    revolve(cap, [(0.82, -0.34), (1.12, -0.32), (1.14, -0.24), (0.84, -0.2)], seg=10, loc=o, sy=1.08,
            deform=upturn)
    feather = m.piece("Feather", "HatAccent", bone=bone)
    sweep(feather, [(0.86, 0.25, -0.12), (1.0, 0.65, 0.12), (1.04, 1.05, 0.42), (0.98, 1.4, 0.74),
                    (0.9, 1.6, 0.98)], [0.03, 0.09, 0.1, 0.07, 0.0], seg=4, sx=2.4, loc=o, up=(1, 0, 1))


HATS = {
    "Helmet": hat_helmet,
    "Plume": hat_plume,
    "Horns": hat_horns,
    "Crown": hat_crown,
    "Wizard": hat_wizard,
    "Tophat": hat_tophat,
    "Halo": hat_halo,
    "Hood": hat_hood,
    "Mitre": hat_mitre,
    "Bandana": hat_bandana,
    "Beanie": hat_beanie,
    "Cap": hat_cap,
}

# Preview / default colours of each hat (the game passes the skin's Hat / HatAccent / Gold).
FIXED = {"Gold": P("gold_500"), "Dark": P("slate_950")}
HAT_COLORS = {
    "Helmet": (P("steel_400"), P("crimson_500")),
    "Plume": (P("steel_300"), P("crimson_500")),
    "Horns": (P("steel_700"), P("ivory_300")),
    "Crown": (P("gold_400"), P("crimson_400")),
    "Wizard": (P("slate_600"), P("gold_500")),
    "Tophat": (P("slate_800"), P("crimson_600")),
    "Halo": (P("gold_300"), P("gold_200")),
    "Hood": (P("moss_600"), P("crimson_500")),
    "Mitre": (P("ivory_100"), P("gold_500")),
    "Bandana": (P("crimson_500"), P("ivory_200")),
    "Beanie": (P("chitin_900"), P("crimson_500")),
    "Cap": (P("moss_500"), P("crimson_400")),
}
NOTES = {
    "Helmet": "Great helm, T visor, gold bands, crimson plume.",
    "Plume": "Open parade helm with cheek guards and a tall brush crest.",
    "Horns": "Closed horned helm with angry slits.",
    "Crown": "Five-point gold crown with jewels.",
    "Wizard": "Wide-brim pointed hat with a band.",
    "Tophat": "Tilted top hat with a band and buckle.",
    "Halo": "Floating ring of light.",
    "Hood": "Deep hood with a pointed tail.",
    "Mitre": "Bishop's mitre with stripe, cross and lappets.",
    "Bandana": "Pirate bandana, eye patch, earring.",
    "Beanie": "Ninja cowl with an eye slit and a trailing headband.",
    "Cap": "Ranger's peaked cap with a long feather.",
}


def _register(shape):
    @register("Hat_" + shape, "Hats", NOTES[shape] + " Origin = head-top centre (standard head).")
    def build(m):
        hat, accent = HAT_COLORS[shape]
        m.extra["palette"] = dict(FIXED, Hat=hat, HatAccent=accent)
        HATS[shape](m, (0, 0, 0), None)
    return build


for _shape in HATS:
    _register(_shape)
