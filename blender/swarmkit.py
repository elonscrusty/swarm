"""SWARM modeling kit: chunky faceted low-poly pieces for Roblox MeshParts.

Conventions
  * 1 Blender unit = 1 stud. Front faces Blender -Y (Roblox -Z), up is +Z (Roblox +Y).
  * Models are authored standing on the ground (z = 0) unless noted.
  * A model is a set of PIECES. Each piece becomes one MeshPart. Pieces are untextured:
    the game colours each one from its colour SLOT (so skins and elites can recolour)
    and gives it a Roblox material (Neon pieces glow).
  * Pieces that animate (legs, wings, jaws, tails) carry an Anim key and a joint PIVOT.
"""

import math
import random

import bmesh
import bpy
from mathutils import Euler, Matrix, Vector

# Preview colours for each slot (the game overrides these at runtime).
SLOT_PREVIEW = {
    "Base": (0.55, 0.55, 0.6),
    "Dark": (0.2, 0.2, 0.24),
    "Light": (0.85, 0.85, 0.88),
    "Accent": (0.9, 0.35, 0.15),
    "Glow": (1.0, 0.45, 0.1),
    "Eye": (1.0, 0.15, 0.1),
    "Metal": (0.62, 0.64, 0.7),
    "Gold": (1.0, 0.75, 0.2),
    "Wood": (0.45, 0.3, 0.18),
    "Skin": (1.0, 0.8, 0.62),
    "Cloth": (0.25, 0.35, 0.8),
    "Cloth2": (0.85, 0.75, 0.3),
    "Leaf": (0.25, 0.65, 0.3),
    "Stone": (0.5, 0.5, 0.52),
    "White": (0.95, 0.95, 0.95),
    "Black": (0.06, 0.06, 0.08),
}


def mat(loc=(0, 0, 0), rot=(0, 0, 0), scale=(1, 1, 1)):
    r = Euler([math.radians(a) for a in rot], "XYZ").to_matrix().to_4x4()
    if not hasattr(scale, "__len__"):
        scale = (scale, scale, scale)
    return Matrix.Translation(Vector(loc)) @ r @ Matrix.Diagonal(Vector((*scale, 1.0)))


class Piece:
    def __init__(self, name, slot="Base", material="SmoothPlastic", anim=None, pivot=None, bone=None):
        self.name = name
        self.bone = bone  # hero pieces: which body part they are welded to
        self.slot = slot
        self.material = material
        self.anim = anim
        self.pivot = Vector(pivot) if pivot is not None else None  # model space joint
        self.bm = bmesh.new()

    # ---------------------------------------------------------------- helpers
    # Every primitive is built in its own temporary bmesh, transformed, then appended,
    # so operations like bevel never touch geometry that is already placed.
    def _merge(self, tmp, m):
        tmp.transform(m)
        me = bpy.data.meshes.new("_tmp")
        tmp.to_mesh(me)
        tmp.free()
        self.bm.from_mesh(me)
        bpy.data.meshes.remove(me)
        return self

    @staticmethod
    def _bevel(bm, amount):
        if amount > 0:
            bmesh.ops.bevel(bm, geom=list(bm.edges) + list(bm.verts), offset=amount, segments=1,
                            affect="EDGES", profile=0.5, clamp_overlap=True)

    # ---------------------------------------------------------------- shapes
    def box(self, size, loc=(0, 0, 0), rot=(0, 0, 0), bevel=0.08, taper=None):
        """Chamfered box. taper=(sx, sy) shrinks the top face (wedge-ish blocks)."""
        t = bmesh.new()
        bmesh.ops.create_cube(t, size=1.0)
        if taper:
            for v in t.verts:
                if v.co.z > 0:
                    v.co.x *= taper[0]
                    v.co.y *= taper[1]
        t.transform(Matrix.Diagonal(Vector((*size, 1.0))))
        self._bevel(t, min(bevel, min(size) * 0.3))
        return self._merge(t, mat(loc, rot))

    def ico(self, radius, loc=(0, 0, 0), rot=(0, 0, 0), scale=(1, 1, 1), subdiv=1, jitter=0.0, seed=1):
        """Faceted sphere (icosphere). jitter roughens it (rocks, organic lumps)."""
        t = bmesh.new()
        bmesh.ops.create_icosphere(t, subdivisions=subdiv, radius=radius)
        if jitter:
            rng = random.Random(seed)
            for v in t.verts:
                v.co *= 1 + rng.uniform(-jitter, jitter)
        if not hasattr(scale, "__len__"):
            scale = (scale, scale, scale)
        t.transform(Matrix.Diagonal(Vector((*scale, 1.0))))
        return self._merge(t, mat(loc, rot))

    def cyl(self, r1, r2, h, seg=6, loc=(0, 0, 0), rot=(0, 0, 0), bevel=0.0, scale=(1, 1)):
        """Faceted cylinder / cone along +Z, centred at loc. r2=0 gives a point."""
        t = bmesh.new()
        bmesh.ops.create_cone(t, cap_ends=True, cap_tris=False, segments=seg,
                              radius1=r1, radius2=max(r2, 0.0001), depth=h)
        t.transform(Matrix.Diagonal(Vector((scale[0], scale[1], 1, 1))))
        self._bevel(t, bevel)
        return self._merge(t, mat(loc, rot))

    def limb(self, a, b, r1, r2=None, seg=5):
        """Tapered faceted segment from point a to point b (legs, horns, tails)."""
        a, b = Vector(a), Vector(b)
        d = b - a
        r2 = r1 if r2 is None else r2
        t = bmesh.new()
        bmesh.ops.create_cone(t, cap_ends=True, segments=seg, radius1=r1,
                              radius2=max(r2, 0.0001), depth=d.length)
        t.transform(Matrix.Translation((0, 0, d.length / 2)))
        q = d.normalized().to_track_quat("Z", "Y")
        return self._merge(t, Matrix.Translation(a) @ q.to_matrix().to_4x4())

    def spike(self, r, h, seg=4, base=(0, 0, 0), direction=(0, 0, 1)):
        """Cone from `base` pointing along `direction`."""
        d = Vector(direction).normalized() * h
        return self.limb(base, Vector(base) + d, r, 0.0, seg)

    def chain(self, points, radii, seg=5):
        """Joined tapered segments through points (tails, antennae, tentacles)."""
        for i in range(len(points) - 1):
            self.limb(points[i], points[i + 1], radii[i], radii[i + 1], seg)
            if 0 < i:
                self.ico(radii[i] * 1.08, loc=points[i], subdiv=1)
        return self

    def prism(self, profile, depth, loc=(0, 0, 0), rot=(0, 0, 0)):
        """Extruded 2D outline (x, z) with thickness `depth` along Y (blades, wings, fins)."""
        t = bmesh.new()
        verts = [t.verts.new((x, -depth / 2, z)) for x, z in profile]
        face = t.faces.new(verts)
        ext = bmesh.ops.extrude_face_region(t, geom=[face])
        moved = [e for e in ext["geom"] if isinstance(e, bmesh.types.BMVert)]
        bmesh.ops.translate(t, vec=(0, depth, 0), verts=moved)
        bmesh.ops.recalc_face_normals(t, faces=t.faces)
        return self._merge(t, mat(loc, rot))

    # ---------------------------------------------------------------- output
    def finish(self):
        bm = self.bm
        bmesh.ops.remove_doubles(bm, verts=bm.verts, dist=0.0005)
        bmesh.ops.recalc_face_normals(bm, faces=bm.faces)
        bmesh.ops.triangulate(bm, faces=[f for f in bm.faces if len(f.verts) > 4])
        mins = Vector([min(v.co[i] for v in bm.verts) for i in range(3)])
        maxs = Vector([max(v.co[i] for v in bm.verts) for i in range(3)])
        center = (mins + maxs) / 2
        bmesh.ops.translate(bm, vec=-center, verts=bm.verts)
        self.center, self.size = center, maxs - mins
        self.tris = sum(len(f.verts) - 2 for f in bm.faces)
        return self


class Model:
    def __init__(self, name, category, note=""):
        self.name, self.category, self.note = name, category, note
        self.pieces = []
        self.extra = {}

    def piece(self, name, slot="Base", material="SmoothPlastic", anim=None, pivot=None, bone=None):
        p = Piece(name, slot, material, anim, pivot, bone)
        self.pieces.append(p)
        return p


# ------------------------------------------------------------------ coordinates

def to_roblox(v):
    """Blender (x, y, z) -> Roblox (x, y, z) for FBX Forward=Z, Up=Y."""
    return [round(-v[0], 4) + 0.0, round(v[2], 4) + 0.0, round(v[1], 4) + 0.0]


def roblox_size(s):
    return [round(s[0], 4), round(s[2], 4), round(s[1], 4)]


REGISTRY = []


def register(name, category, note=""):
    def deco(fn):
        REGISTRY.append((name, category, note, fn))
        return fn
    return deco
