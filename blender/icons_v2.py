"""Picture icons for the run things that had no picture: the 12 class signature weapons, the 4 new
evolutions, the 8 loot passives and the 12 class heads (docs/redesign/gameplay/BUILDS.md and CLASSES.md).

    /tmp/bpyenv/bin/python blender/icons_v2.py                    every icon -> art/icons/
    /tmp/bpyenv/bin/python blender/icons_v2.py --only ScrapToss,hero_ruckus --samples 24
    /tmp/bpyenv/bin/python blender/icons_v2.py --sheet            only rebuild the contact sheet

Each icon is a small chunky low-poly scene built with the swarmkit pieces (the DEFS section below), lit with
soft light and drawn with a dark inverted-hull outline on a transparent film, 1024 x 1024, the object
filling about 80 % of the square (same look as the other art/icons pictures).  Weapon / passive /
evolution icons are named after their id (art/icons/<Id>.png, uploaded by tools/upload_icons.py).  Class
heads are the class meshes (blender/models/classes.py, classes2.py) cut at the chest and framed
head-and-shoulders: art/icons/heroes/hero_<classId>.png (uploaded by tools/upload_art.py, like hero_Knight).

The outline is a copy of every piece pushed out along its vertex normals with its faces flipped; a material
makes the shell's near side see-through, so only the rim around the object shows.  (A Solidify modifier
leaves a transparent copy of the original surface in the same place and Cycles then skips the real surface.)

After a render:  python3 tools/upload_icons.py, python3 tools/gen_icon_data.py (items), and for the heads
python3 tools/upload_art.py --only icons/heroes/hero_<classId>,...; then python3 tools/gen_icon_checklist.py.

Needs the bpy module (pip install bpy==5.0.1, Python 3.11) and Pillow.
"""

import argparse
import math
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
sys.path.insert(0, HERE)

import bpy  # noqa: E402  (must come first: it makes bmesh importable)
import bmesh  # noqa: E402
from mathutils import Euler, Quaternion, Vector  # noqa: E402

import swarmkit as K  # noqa: E402
from models.hats import band, lathe, revolve, slab, sweep  # noqa: E402

OUT = os.path.join(ROOT, "art", "icons")
OUT_HEROES = os.path.join(OUT, "heroes")
SHEET = os.path.join(ROOT, "renders", "Sheet_IconsV2.png")
SIZE = 1024
OUTLINE_PX = 8  # outline width in pixels at 1024
OUTLINE_COLOR = "#141c2b"

# ------------------------------------------------------------------------------ palette
STEEL = "#aab3bf"
STEEL_L = "#d9dfe6"
STEEL_D = "#6b7584"
IRON = "#4a515e"
RUST = "#b0652f"
RUST_D = "#7d4220"
GOLD = "#e8b43c"
GOLD_L = "#f6d472"
GOLD_D = "#b07d1f"
WOOD = "#9a6234"
WOOD_L = "#c58f55"
WOOD_D = "#6c3f20"
RED = "#dc3d35"
RED_D = "#a02a2a"
RED_L = "#f06a5a"
ORANGE = "#f2872c"
ORANGE_L = "#ffb35a"
CREAM = "#f6ecd2"
WHITE = "#f4f6fa"
TOAST = "#e6a043"
TOAST_D = "#a35d22"
TOAST_L = "#f6cf86"
AQUA = "#48c6ea"
AQUA_L = "#a9ecfa"
AQUA_D = "#2b8fc4"
PINK = "#ee5a98"
PINK_L = "#ff9cc6"
PINK_D = "#b8316f"
PURPLE = "#7a45c8"
PURPLE_D = "#4b2a8c"
PURPLE_L = "#a77ce6"
GREEN = "#58b840"
GREEN_L = "#8ee26a"
GREEN_D = "#2f7d2c"
YELLOW = "#ffd23a"
TEAL = "#27b3a6"
TEAL_D = "#17786f"
BLUE = "#3a78e0"
BLUE_D = "#244a9a"
SOIL = "#6b4429"
BLACK = "#252833"
COPPER = "#c8743a"

ICONS = []  # (id, kind, builder, options)


def icon(name, view=(14, 26), roll=0.0, rot=(0, 0, 0), kind="item"):
    def deco(fn):
        ICONS.append((name, kind, fn, dict(view=view, roll=roll, rot=rot)))
        return fn
    return deco


def hexc(h):
    h = h.lstrip("#")
    return tuple(int(h[i:i + 2], 16) / 255 for i in (0, 2, 4))


def lin(c):
    return tuple(((x + 0.055) / 1.055) ** 2.4 if x > 0.04045 else x / 12.92 for x in c)


class Ic:
    """The parts of one icon; every part is a swarmkit Piece with its own flat colour."""

    def __init__(self, name):
        self.name = name
        self.parts = []

    def part(self, color, glow=0.0, name=None):
        p = K.Piece(name or "%s_%d" % (self.name, len(self.parts)))
        p.color = hexc(color) if isinstance(color, str) else color
        p.glow = glow
        self.parts.append(p)
        return p


# ------------------------------------------------------------------------------ shapes
def torus(p, R, r, seg=18, tseg=6, loc=(0, 0, 0), rot=(0, 0, 0), phase=0.0):
    """Ring of radius R and tube radius r around local Z."""
    loop = [(R + r * math.cos(phase + i / tseg * math.tau), r * math.sin(phase + i / tseg * math.tau))
            for i in range(tseg)]
    return revolve(p, loop, seg=seg, loc=loc, rot=rot)


def star_pts(n, r_out, r_in, rot=0.0):
    pts = []
    for i in range(2 * n):
        a = rot + math.pi * i / n
        r = r_out if i % 2 == 0 else r_in
        pts.append((math.sin(a) * r, math.cos(a) * r))
    return pts


def gear(p, teeth, r_body, r_tooth, thick, loc=(0, 0, 0), rot=(0, 0, 0), hole=0.0, seg_extra=0):
    """Flat gear in the XZ plane (axis along Y)."""
    k = max(teeth, 6)
    pts = []
    for i in range(k):
        a0 = i / k * math.tau
        w = math.tau / k
        pts += [(math.sin(a0) * r_body, math.cos(a0) * r_body),
                (math.sin(a0 + w * 0.12) * r_tooth, math.cos(a0 + w * 0.12) * r_tooth),
                (math.sin(a0 + w * 0.42) * r_tooth, math.cos(a0 + w * 0.42) * r_tooth),
                (math.sin(a0 + w * 0.56) * r_body, math.cos(a0 + w * 0.56) * r_body)]
    return slab(p, pts, thick, loc=loc, rot=rot, bevel=thick * 0.14)


def disc(p, r, thick, seg=14, loc=(0, 0, 0), rot=(0, 0, 0), bevel=0.0):
    """Flat round disc facing -Y (axis along Y)."""
    return p.cyl(r, r, thick, seg=seg, loc=loc, rot=(90 + rot[0], rot[1], rot[2]), bevel=bevel)


def streaks(ic, color, origin, direction, n=3, length=2.2, spread=0.55, width=0.16, seed=0, depth=(0, -1, 0)):
    """Speed lines: tapered wedges trailing behind `origin` (thick near the object, a point at the far end)."""
    d = Vector(direction).normalized()
    side = d.cross(Vector(depth)).normalized()
    for i in range(n):
        off = (i - (n - 1) / 2) * spread
        ln = length * (1.0 - 0.3 * abs(i - (n - 1) / 2) + 0.12 * ((i * 7 + seed) % 3))
        a = Vector(origin) + side * off
        b = a - d * ln
        p = ic.part(color)
        p.limb(a, b, width, 0.0, seg=4)


def sparkle(ic, color, loc, r=0.3, depth=0.16, pts=4, inner=0.3):
    """A flat star facing the camera (-Y)."""
    p = ic.part(color)
    slab(p, star_pts(pts, r, r * inner), depth, loc=loc, bevel=0.0)
    return p


def spark_burst(ic, loc, r=0.55):
    """Fuse spark: orange star with a yellow star in front."""
    sparkle(ic, ORANGE, loc, r, 0.16, pts=6, inner=0.45)
    sparkle(ic, YELLOW, (loc[0], loc[1] - 0.1, loc[2]), r * 0.62, 0.16, pts=6, inner=0.45)


def leaf_pts(length, width, n=6):
    """Pointed leaf outline in (x, z) from the stem (0, 0) to the tip (length, 0)."""
    up = [(length * u, width * math.sin(math.pi * u) ** 0.8 * (1.0 - 0.25 * u)) for u in [i / n for i in range(1, n)]]
    dn = [(x, -z * 0.7) for x, z in reversed(up)]
    return [(0.0, 0.0)] + up + [(length, 0.0)] + dn


def clip_poly(pts, nx, nz, d):
    """Sutherland-Hodgman: keep the part of polygon `pts` where nx*x + nz*z >= d."""
    out = []
    for i, a in enumerate(pts):
        b = pts[(i + 1) % len(pts)]
        fa, fb = nx * a[0] + nz * a[1] - d, nx * b[0] + nz * b[1] - d
        if fa >= 0:
            out.append(a)
        if (fa >= 0) != (fb >= 0):
            t = fa / (fa - fb)
            out.append((a[0] + (b[0] - a[0]) * t, a[1] + (b[1] - a[1]) * t))
    return out


def heart_pts(scale=1.0, n=40):
    pts = []
    for i in range(n):
        t = i / n * math.tau
        x = 16 * math.sin(t) ** 3
        z = 13 * math.cos(t) - 5 * math.cos(2 * t) - 2 * math.cos(3 * t) - math.cos(4 * t)
        pts.append((x * scale / 16.0, z * scale / 16.0))
    pts.reverse()  # counter-clockwise seen from -Y so the normals face the camera
    return pts


def arc_path(cx, cz, R, a0, a1, n=14, y=0.0):
    """Points along a circle in the XZ plane, angles in degrees (0 = right, 90 = up)."""
    return [(cx + math.cos(math.radians(a0 + (a1 - a0) * i / n)) * R, y,
             cz + math.sin(math.radians(a0 + (a1 - a0) * i / n)) * R) for i in range(n + 1)]


def tube(ic, color, pts, r0, r1=None, seg=5, mid=None):
    """A tapered tube along `pts` (radius r0 -> r1; `mid` gives a bulge radius multiplier at the middle)."""
    p = ic.part(color)
    n = len(pts)
    r1 = r0 if r1 is None else r1
    radii = []
    for i in range(n):
        u = i / (n - 1)
        r = r0 + (r1 - r0) * u
        if mid:
            r *= 1 + (mid - 1) * math.sin(math.pi * u)
        radii.append(r)
    sweep(p, pts, radii, seg=seg)
    return p


def sphere_arc(ic, color, center, R, normal, toward_cam, r=0.1, steps=40, lift=0.04):
    """A seam on a sphere: the part of the great circle (plane through the centre with `normal`) that faces the
    camera (direction `toward_cam`), as a thin tube lying on the surface."""
    n = Vector(normal).normalized()
    c = Vector(toward_cam).normalized()
    ref = Vector((0, 0, 1)) if abs(n.z) < 0.9 else Vector((1, 0, 0))
    u = n.cross(ref).normalized()
    v = n.cross(u).normalized()
    n_pts = steps * 2
    ring = [u * math.cos(i / n_pts * math.tau) + v * math.sin(i / n_pts * math.tau) for i in range(n_pts)]
    facing = [p.dot(c) > 0.12 for p in ring]
    if all(facing) or not any(facing):
        return None
    start = facing.index(False)  # begin at a point on the far side so no run wraps past index 0
    runs, run = [], []
    for k in range(n_pts):
        i = (start + k) % n_pts
        if facing[i]:
            run.append(Vector(center) + ring[i] * (R + lift))
        elif run:
            runs.append(run)
            run = []
    if run:
        runs.append(run)
    best = max(runs, key=len)
    p = ic.part(color)
    radii = [r * (0.55 + 0.45 * math.sin(math.pi * (i + 0.5) / len(best))) for i in range(len(best))]
    sweep(p, best, radii, seg=5)
    return p


def arrow_head(ic, color, tip, direction, length=0.9, r=0.42, seg=5):
    d = Vector(direction).normalized()
    base = Vector(tip) - d * length
    p = ic.part(color)
    p.limb(base, tip, r, 0.0, seg=seg)
    return p


def blob(p, r, loc, rot=(0, 0, 0), scale=(1, 1, 1), subdiv=1, jitter=0.0, seed=1):
    return p.ico(r, loc=loc, rot=rot, scale=scale, subdiv=subdiv, jitter=jitter, seed=seed)


def helix(p, R, pitch_total, turns, r_wire, loc=(0, 0, 0), seg_per_turn=10, tube_seg=5, taper=1.0):
    """A coil spring around local Z, bottom at loc.z - pitch_total/2."""
    n = int(turns * seg_per_turn)
    pts, radii = [], []
    for i in range(n + 1):
        u = i / n
        a = u * turns * math.tau
        pts.append((loc[0] + math.cos(a) * R, loc[1] + math.sin(a) * R, loc[2] - pitch_total / 2 + u * pitch_total))
        radii.append(r_wire)
    sweep(p, pts, radii, seg=tube_seg)
    return p


# ------------------------------------------------------------------------------ build + render
def clear_scene():
    _mat_cache.clear()
    for ob in list(bpy.data.objects):
        bpy.data.objects.remove(ob)
    for coll in (bpy.data.meshes, bpy.data.materials, bpy.data.lights, bpy.data.cameras):
        for item in list(coll):
            coll.remove(item)


_mat_cache = {}


def material(color, glow=0.0):
    key = (tuple(round(c, 4) for c in color), round(glow, 2))
    if key in _mat_cache:
        return _mat_cache[key]
    m = bpy.data.materials.new("M%d" % len(_mat_cache))
    m.use_nodes = True
    nt = m.node_tree
    bsdf = nt.nodes["Principled BSDF"]
    bsdf.inputs["Base Color"].default_value = (*lin(color), 1)
    bsdf.inputs["Roughness"].default_value = 0.72
    for name in ("Specular IOR Level", "Specular"):
        if name in bsdf.inputs:
            bsdf.inputs[name].default_value = 0.22
            break
    if glow > 0:
        bsdf.inputs["Emission Color"].default_value = (*lin(color), 1)
        bsdf.inputs["Emission Strength"].default_value = glow
    _mat_cache[key] = m
    return m


def hull_material():
    """Outline material of the shells: dark emission, see-through where the shell's face looks away from the
    camera (its near side), so only the rim around the real object shows."""
    if "hull" in _mat_cache:
        return _mat_cache["hull"]
    line = bpy.data.materials.new("HullLine")
    line.use_nodes = True
    nt = line.node_tree
    for n in list(nt.nodes):
        nt.nodes.remove(n)
    out = nt.nodes.new("ShaderNodeOutputMaterial")
    bsdf = nt.nodes.new("ShaderNodeBsdfPrincipled")
    bsdf.inputs["Base Color"].default_value = (0, 0, 0, 1)
    bsdf.inputs["Roughness"].default_value = 1.0
    for nm in ("Specular IOR Level", "Specular"):
        if nm in bsdf.inputs:
            bsdf.inputs[nm].default_value = 0.0
    bsdf.inputs["Emission Color"].default_value = (*lin(hexc(OUTLINE_COLOR)), 1)
    bsdf.inputs["Emission Strength"].default_value = 1.0
    geo = nt.nodes.new("ShaderNodeNewGeometry")
    inv = nt.nodes.new("ShaderNodeMath")
    inv.operation = "SUBTRACT"
    inv.inputs[0].default_value = 1.0
    nt.links.new(geo.outputs["Backfacing"], inv.inputs[1])
    nt.links.new(inv.outputs[0], bsdf.inputs["Alpha"])  # the near side of the shell (backfacing after the flip) is see-through
    nt.links.new(bsdf.outputs[0], out.inputs[0])
    _mat_cache["hull"] = line
    return line


def setup_scene(samples):
    s = bpy.context.scene
    s.render.engine = "CYCLES"
    s.cycles.device = "CPU"
    s.cycles.samples = samples
    s.cycles.use_denoising = True
    s.cycles.denoiser = "OPENIMAGEDENOISE"
    s.cycles.max_bounces = 4
    s.cycles.transparent_max_bounces = 96
    s.cycles.filter_width = 1.4
    s.render.resolution_x = s.render.resolution_y = SIZE
    s.render.resolution_percentage = 100
    s.render.film_transparent = True
    s.render.image_settings.file_format = "PNG"
    s.render.image_settings.color_mode = "RGBA"
    s.render.image_settings.color_depth = "8"
    s.view_settings.view_transform = "Standard"
    s.view_settings.look = "None"
    s.view_settings.exposure = 0.0
    world = bpy.data.worlds.new("W")
    world.use_nodes = True
    bg = world.node_tree.nodes["Background"]
    bg.inputs["Color"].default_value = (0.86, 0.9, 1.0, 1)
    bg.inputs["Strength"].default_value = 0.62
    s.world = world
    return s


def view_dir(yaw, elev):
    y, e = math.radians(yaw), math.radians(elev)
    return Vector((math.sin(y) * math.cos(e), -math.cos(y) * math.cos(e), math.sin(e))).normalized()


def build_objects(parts, root):
    objs = []
    for p in parts:
        if not p.bm.verts:
            continue
        p.finish()
        me = bpy.data.meshes.new(p.name)
        p.bm.to_mesh(me)
        p.bm.free()
        for poly in me.polygons:
            poly.use_smooth = False
        me.materials.append(material(p.color, getattr(p, "glow", 0.0)))
        ob = bpy.data.objects.new(p.name, me)
        ob.location = p.center
        bpy.context.scene.collection.objects.link(ob)
        ob.parent = root
        objs.append(ob)
    return objs


def shell_mesh(src, thickness):
    """The outline shell of mesh `src`: a copy pushed out along the (mitred) vertex normals with flipped
    faces, so only its far side faces the camera."""
    bm = bmesh.new()
    bm.from_mesh(src)
    bm.normal_update()
    for v in bm.verts:
        n = v.normal.copy()
        if n.length < 1e-6:
            continue
        n.normalize()
        k = min([n.dot(f.normal) for f in v.link_faces] or [1.0])
        v.co += n * (thickness / max(k, 0.4))
    bmesh.ops.reverse_faces(bm, faces=bm.faces)
    me = bpy.data.meshes.new(src.name + "_shell")
    bm.to_mesh(me)
    bm.free()
    return me


def add_hulls(objs, root, thickness):
    line = hull_material()
    for ob in objs:
        me = shell_mesh(ob.data, thickness)
        me.materials.append(line)
        for poly in me.polygons:
            poly.use_smooth = False
        h = bpy.data.objects.new(ob.name + "_hull", me)
        h.location = ob.location
        bpy.context.scene.collection.objects.link(h)
        h.parent = root
        h.visible_shadow = False
        h.visible_diffuse = False
        h.visible_glossy = False
        h.visible_transmission = False
        h.visible_volume_scatter = False


def frame_camera(objs, direction, roll, fill):
    scn = bpy.context.scene
    bpy.context.view_layer.update()
    rot = (-direction).to_track_quat("-Z", "Y")
    rot = rot @ Quaternion((0, 0, 1), math.radians(roll))
    inv = rot.to_matrix().inverted()
    pts = [inv @ (o.matrix_world @ Vector(c)) for o in objs for c in o.bound_box]
    lo = Vector([min(p[i] for p in pts) for i in range(3)])
    hi = Vector([max(p[i] for p in pts) for i in range(3)])
    center_cam = (lo + hi) / 2
    center = rot.to_matrix() @ Vector((center_cam.x, center_cam.y, 0.0))
    ext = max(hi.x - lo.x, hi.y - lo.y)
    cam = bpy.data.objects.new("Cam", bpy.data.cameras.new("Cam"))
    scn.collection.objects.link(cam)
    scn.camera = cam
    cam.data.type = "ORTHO"
    cam.data.ortho_scale = ext / fill
    cam.data.clip_end = 1000
    cam.rotation_euler = rot.to_euler()
    cam.location = center + direction * 60
    return cam, rot, cam.data.ortho_scale


def add_lights(rot):
    scn = bpy.context.scene

    def sun(vec, energy, angle, color=(1, 1, 1)):
        d = rot.to_matrix() @ Vector(vec).normalized()  # direction towards the light
        light = bpy.data.lights.new("L", "SUN")
        light.energy = energy
        light.angle = math.radians(angle)
        light.color = color
        ob = bpy.data.objects.new("L", light)
        ob.rotation_euler = (-d).to_track_quat("-Z", "Y").to_euler()
        scn.collection.objects.link(ob)

    sun((-0.55, 0.75, 0.6), 2.7, 18, (1.0, 0.97, 0.92))   # key: upper left, in front
    sun((0.8, -0.35, 0.5), 0.55, 40, (0.8, 0.88, 1.0))     # cool fill from the lower right


def render_icon(ic, path, view, roll, rot_deg, samples, fill=0.80):
    clear_scene()
    scn = setup_scene(samples)
    root = bpy.data.objects.new("Root", None)
    scn.collection.objects.link(root)
    root.rotation_euler = Euler([math.radians(a) for a in rot_deg], "XYZ")
    objs = build_objects(ic.parts, root)
    bpy.context.view_layer.update()
    direction = view_dir(*view)
    cam, rot, ortho = frame_camera(objs, direction, roll, fill)
    add_hulls(objs, root, OUTLINE_PX / SIZE * ortho)
    add_lights(rot)
    os.makedirs(os.path.dirname(path), exist_ok=True)
    scn.render.filepath = path
    bpy.ops.render.render(write_still=True)
    fit(path)


def fit(path, target=0.80):
    """Centre the picture and make the object fill `target` of the square (post-fix for odd framings)."""
    from PIL import Image
    im = Image.open(path).convert("RGBA")
    bbox = im.getchannel("A").point(lambda v: 255 if v > 10 else 0).getbbox()
    if not bbox:
        return
    w, h = bbox[2] - bbox[0], bbox[3] - bbox[1]
    side = max(w, h) / target
    cx, cy = (bbox[0] + bbox[2]) / 2, (bbox[1] + bbox[3]) / 2
    if abs(side - SIZE) < 0.06 * SIZE and abs(cx - SIZE / 2) < 0.05 * SIZE and abs(cy - SIZE / 2) < 0.05 * SIZE:
        return
    box = (cx - side / 2, cy - side / 2, cx + side / 2, cy + side / 2)
    im = im.transform((SIZE, SIZE), Image.AFFINE, (side / SIZE, 0, box[0], 0, side / SIZE, box[1]), resample=Image.BICUBIC)
    im.save(path, optimize=True)


# ------------------------------------------------------------------------------ class heads
CLASS_MODELS = {  # class id -> (mesh model name, cut height in studs, pieces left out, view)
    "ruckus": ("Ruckus", 3.4, ("TrashCan", "CanRibs", "CanLid", "Tail"), (16, 12)),
    "toastmaster": ("Toastmaster", 2.7, (), (16, 12)),
    "captain_croak": ("CaptainCroak", 3.15, ("Backpack", "BackpackFlap", "Bedroll", "BedrollBands"), (16, 12)),
    "granny_boom": ("GrannyBoom", 3.2, ("WalkerFrame", "WalkerGrips", "WalkerFeet", "HazardPlate", "HazardStripes", "HazardFrame", "RocketNozzles", "RocketGlow", "Canisters", "CanisterCaps"), (16, 12)),
    "coach_crunch": ("CoachCrunch", 3.3, ("NetSack", "NetBands", "SackBalls", "SackStraps", "Dodgeball", "DodgeballSeam"), (16, 12)),
    "doug_janitor": ("DougJanitor", 3.3, ("Tank", "TankCap", "Hose", "SprayBottle", "SprayNozzle", "MopShaft", "MopHead", "MopTie", "Soap", "Bubbles", "Plunger"), (16, 12)),
    "peter_parkour": ("PeterParkour", 3.7, ("Crate", "CrateStraps", "CrateSoles", "CrateUppers", "MessengerBag", "MessengerFlap"), (16, 12)),
    "barry_plotter": ("BarryPlotter", 3.3, ("WateringCan", "CanRose", "Hose", "SpadeBlade", "SpadeHandle", "Staff", "StaffRope", "Bristles", "BroomBinding", "Pots", "Plants", "Flowers"), (16, 12)),
    "rambozo": ("Rambozo", 3.5, ("Barrel", "Minigun"), (16, 12)),
    "swolverine": ("Swolverine", 3.35, ("Shaker",), (16, 12)),
    "crash_cassidy": ("CrashCassidy", 3.1, ("Stick",), (16, 12)),
    "knuckles_mcgee": ("KnucklesMcGee", 2.65, ("Towel", "Waistband", "Shorts", "ChampBelt", "BeltPlate", "BeltStar", "LeftArmGlove", "RightArmGlove", "LeftArmCuff", "RightArmCuff"), (16, 12)),
}


def cut_below(p, zcut):
    """Remove everything of piece p under z = zcut and close the cut (a bust)."""
    bm = p.bm
    geom = list(bm.verts) + list(bm.edges) + list(bm.faces)
    res = bmesh.ops.bisect_plane(bm, geom=geom, plane_co=(0, 0, zcut), plane_no=(0, 0, 1),
                                 clear_inner=True, clear_outer=False, dist=1e-5)
    edges = [e for e in res["geom_cut"] if isinstance(e, bmesh.types.BMEdge)]
    if edges:
        try:
            bmesh.ops.edgenet_fill(bm, edges=edges, mat_nr=0, use_smooth=False, sides=0)
        except Exception:
            try:
                bmesh.ops.contextual_create(bm, geom=edges)
            except Exception:
                pass
    # drop loose bits that the cut leaves with no faces
    bmesh.ops.delete(bm, geom=[v for v in bm.verts if not v.link_faces], context="VERTS")


def class_ic(class_id):
    model_name, zcut, drop, _view = CLASS_MODELS[class_id]
    import models.classes  # noqa: F401  (registers the models)
    import models.classes2  # noqa: F401
    fn = next(r[3] for r in K.REGISTRY if r[0] == model_name)
    m = K.Model(model_name, "Classes")
    fn(m)
    palette = dict(K.SLOT_PREVIEW)
    palette.update(m.extra.get("palette", {}))
    ic = Ic(class_id)
    for p in m.pieces:
        if any(p.name.startswith(d) for d in drop):
            continue
        cut_below(p, zcut)
        if not p.bm.verts:
            continue
        p.color = palette.get(p.slot, (0.6, 0.6, 0.6))
        p.glow = 0.9 if p.material == "Neon" else 0.0
        ic.parts.append(p)
    return ic


# ------------------------------------------------------------------------------ icon definitions
# (item icons are defined below the class heads; DEFS_END marks the end of the definitions)
for _cid, _spec in CLASS_MODELS.items():
    ICONS.append((_cid, "hero", None, dict(view=_spec[3], roll=0.0, rot=(0, 0, 0))))

# DEFS_BEGIN
# ---------------------------------------------------------------- signature weapons
@icon("ScrapToss", view=(16, 24), roll=-6)
def _scrap(ic):
    body = ic.part(RUST)
    body.ico(1.75, subdiv=1, jitter=0.16, scale=(1.1, 0.95, 1.0), seed=4)
    lump = ic.part(RUST_D)
    lump.ico(0.8, loc=(1.15, -0.7, -0.9), subdiv=1, jitter=0.2, seed=9)
    lump.ico(0.62, loc=(-1.3, -0.6, 1.0), subdiv=1, jitter=0.2, seed=2)
    plate = ic.part(STEEL)
    slab(plate, [(-1.15, -0.65), (1.0, -1.1), (1.35, 0.3), (0.3, 1.2), (-1.1, 0.6)], 0.4,
         loc=(-0.2, -1.55, -0.1), rot=(0, -20, 0), bevel=0.09)
    rivet = ic.part(STEEL_D)
    for (rx, rz) in ((-0.65, 0.25), (0.55, -0.45), (0.55, 0.55)):
        rivet.ico(0.17, loc=(rx - 0.2, -1.95, rz - 0.1), subdiv=1)
    nut = ic.part(GOLD)
    band(nut, 0.24, 0.62, -0.22, 0.22, seg=6, loc=(1.35, -1.45, -1.2), rot=(90, 0, 0))
    bolt = ic.part(STEEL_L)
    bolt.cyl(0.2, 0.2, 1.5, seg=6, loc=(-0.1, -0.6, 2.05), rot=(0, 35, 0))
    bolt.cyl(0.46, 0.46, 0.32, seg=6, loc=(-0.55, -0.6, 2.6), rot=(0, 35, 0))
    streaks(ic, STEEL_L, (-2.05, -0.2, 0.2), (1, 0, 0.12), n=2, length=1.9, spread=0.95, width=0.16)


def toast_slice(ic, x=0.0, y=0.0, z=0.0, tilt=0.0, s=1.0, crust=TOAST_D, face=TOAST, butter=True):
    """A slice of bread seen from the front: crust slab, a raised lighter face, optional butter pat."""
    prof = [(-1.0, -1.15), (1.0, -1.15), (1.05, 0.2), (1.38, 0.55), (1.4, 1.15), (0.9, 1.5), (-0.9, 1.5),
            (-1.4, 1.15), (-1.38, 0.55), (-1.05, 0.2)]
    c = ic.part(crust)
    slab(c, [(a * s, b * s) for a, b in prof], 0.6 * s, loc=(x, y, z), rot=(0, tilt, 0), bevel=0.12 * s)
    f = ic.part(face)
    slab(f, [(a * 0.78 * s, b * 0.78 * s + 0.12 * s) for a, b in prof], 0.5 * s, loc=(x, y - 0.28 * s, z), rot=(0, tilt, 0), bevel=0.1 * s)
    if butter:
        b = ic.part(YELLOW)
        b.box((0.95 * s, 0.5 * s, 0.7 * s), loc=(x + 0.05 * s, y - 0.75 * s, z + 0.3 * s), rot=(0, tilt + 10, 0), bevel=0.12 * s)


@icon("ToastVolley", view=(14, 22), roll=-10)
def _toast(ic):
    toast_slice(ic, 1.0, 0.9, 0.9, -18, 0.8, crust="#8c4b1c", face="#d58a35", butter=False)
    toast_slice(ic, 0.0, 0.0, 0.0, 6, 1.0)
    streaks(ic, CREAM, (-1.9, 0.0, 0.1), (1, 0, 0.1), n=3, length=1.7, spread=0.8, width=0.15)
    for (cx, cz) in ((-2.0, 1.6), (-2.7, -1.1)):
        cr = ic.part(TOAST_L)
        cr.box((0.3, 0.3, 0.3), loc=(cx, -0.3, cz), rot=(20, 30, 40), bevel=0.05)


@icon("BubbleBomb", view=(12, 20), roll=0)
def _bubble(ic):
    ball = ic.part(AQUA)
    ball.ico(1.85, subdiv=2, scale=(1, 0.95, 1))
    shine = ic.part(WHITE)
    shine.ico(0.3, loc=(-0.85, -1.62, 0.95), subdiv=1, scale=(1.5, 0.5, 1.0), rot=(0, -40, 0))
    shine.ico(0.17, loc=(-0.3, -1.76, 1.3), subdiv=1, scale=(1, 0.5, 1))
    cap = ic.part(IRON)
    cap.cyl(0.62, 0.78, 0.6, seg=8, loc=(0.1, 0.0, 1.9))
    collar = ic.part(GOLD)
    collar.cyl(0.8, 0.8, 0.18, seg=8, loc=(0.1, 0.0, 1.66))
    fuse = ic.part("#6b4a2e")
    fuse.limb((0.1, 0, 2.15), (0.2, 0, 2.55), 0.14, 0.12, seg=5)
    fuse.limb((0.2, 0, 2.55), (0.7, 0, 3.0), 0.12, 0.1, seg=5)
    spark_burst(ic, (0.95, -0.25, 3.2), 0.55)
    for (bx, bz, r, c) in ((2.55, -0.9, 0.62, AQUA_L), (2.3, 0.6, 0.36, AQUA_L), (-2.45, 1.0, 0.45, AQUA_L)):
        b = ic.part(c)
        b.ico(r, loc=(bx, -0.4, bz), subdiv=1)


@icon("YarnBomb", view=(14, 22), roll=0)
def _yarn(ic):
    ball = ic.part(PINK)
    ball.ico(1.65, subdiv=2)
    for i, (rot, c) in enumerate((((62, 0, 25), PINK_L), ((-35, 0, -40), PINK_D), ((8, 0, 75), PINK_L), ((70, 0, -60), PINK_D))):
        w = ic.part(c)
        torus(w, 1.62, 0.14, seg=22, tseg=5, rot=rot)
    tail = ic.part(PINK_L)
    sweep(tail, [(1.2, -1.0, -1.2), (2.0, -1.2, -1.8), (2.7, -1.0, -1.6), (3.2, -1.1, -1.0), (3.4, -1.2, -0.3)],
          [0.15, 0.15, 0.15, 0.14, 0.12], seg=5)
    cap = ic.part(IRON)
    cap.cyl(0.5, 0.62, 0.5, seg=8, loc=(-0.2, 0.0, 1.78), rot=(0, -12, 0))
    fuse = ic.part("#6b4a2e")
    fuse.limb((-0.25, 0, 2.0), (-0.45, 0, 2.55), 0.14, 0.12, seg=5)
    fuse.limb((-0.45, 0, 2.55), (0.1, 0, 3.1), 0.12, 0.1, seg=5)
    spark_burst(ic, (0.4, -0.3, 3.3), 0.55)


@icon("Dodgeball", view=(14, 22), roll=0)
def _dodge(ic):
    ball = ic.part(RED)
    ball.ico(1.95, subdiv=3)
    cam = view_dir(14, 22)
    star = ic.part(WHITE)
    slab(star, star_pts(5, 0.95, 0.42), 0.5, loc=tuple(cam * 1.9), rot=(-22, 0, 14), bevel=0.06)
    streaks(ic, RED_L, (-2.15, 0.0, 0.1), (1, 0, 0.18), n=3, length=1.5, spread=0.8, width=0.1)
    for (sx, sz) in ((2.6, 1.9), (2.9, -1.6)):
        sparkle(ic, YELLOW, (sx, -0.6, sz), 0.34)


@icon("MopSweep", view=(14, 22), roll=0)
def _mop(ic):
    h = ic.part(WOOD_L)
    h.limb((-0.3, 0, -0.2), (1.9, 0, 3.0), 0.16, 0.16, seg=6)
    knob = ic.part(WOOD)
    knob.ico(0.26, loc=(1.95, 0, 3.08), subdiv=1)
    clamp = ic.part(STEEL_D)
    clamp.box((1.5, 0.7, 0.55), loc=(-0.55, 0, -0.45), rot=(0, 14, 0), bevel=0.12)
    clamp2 = ic.part(STEEL)
    clamp2.box((0.35, 0.78, 0.7), loc=(-0.25, 0, -0.25), rot=(0, 14, 0), bevel=0.06)
    cols = (CREAM, STEEL_L, CREAM, "#dfe7ee", CREAM, STEEL_L, CREAM)
    for i, c in enumerate(cols):
        u = i / (len(cols) - 1)
        x0 = -1.15 + u * 1.15
        s = ic.part(c)
        s.limb((x0, (i % 2) * 0.12 - 0.06, -0.72), (x0 - 0.55 + u * 0.4, (i % 3 - 1) * 0.3, -2.55 - (i % 2) * 0.15), 0.2, 0.08, seg=5)
    wet = ic.part(AQUA)
    sweep(wet, arc_path(0.5, -0.8, 2.9, 205, 340, n=10, y=0.5), [0.04, 0.12, 0.2, 0.24, 0.22, 0.2, 0.16, 0.12, 0.08, 0.05, 0.02], seg=5)
    for (dx, dz, r) in ((2.7, -0.6, 0.3), (2.0, -1.8, 0.22), (3.2, 0.4, 0.2)):
        d = ic.part(AQUA)
        d.ico(r, loc=(dx, -0.2, dz), subdiv=1, scale=(1, 1, 1.15))
        d.spike(r * 0.85, r * 1.4, seg=5, base=(dx, -0.2, dz + r * 0.7), direction=(0, 0, 1))


def sneaker(ic, upper, trim, sole, accent, lace, x=0.0, y=0.0, z=0.0, s=1.0):
    """A chunky side-on sneaker pointing to the right (+X)."""
    prof = [(-1.75, -0.35), (1.7, -0.35), (2.0, 0.1), (1.75, 0.45), (0.75, 0.62), (0.3, 1.1), (-0.15, 1.65),
            (-1.15, 1.75), (-1.75, 1.2)]
    u = ic.part(upper)
    slab(u, [(a * s, b * s) for a, b in prof], 1.25 * s, loc=(x, y, z), bevel=0.14 * s)
    t = ic.part(trim)
    slab(t, [(a * s, b * s) for a, b in ((0.95, 0.5), (1.9, 0.0), (2.05, 0.32), (1.7, 0.5), (1.2, 0.58))], 1.3 * s, loc=(x, y, z), bevel=0.06 * s)
    so = ic.part(sole)
    so.box((4.0 * s, 1.5 * s, 0.55 * s), loc=(x + 0.12 * s, y, z - 0.62 * s), bevel=0.2 * s)
    st = ic.part(accent)
    st.box((3.5 * s, 1.56 * s, 0.14 * s), loc=(x + 0.1 * s, y, z - 0.52 * s), bevel=0.04 * s)
    sw = ic.part(accent)
    slab(sw, [(a * s, b * s) for a, b in ((-1.3, 0.3), (0.2, 0.2), (0.7, 0.55), (0.1, 0.5), (-1.1, 0.75))], 1.32 * s, loc=(x, y, z), bevel=0.04 * s)
    tg = ic.part(lace)
    tg.box((0.5 * s, 0.9 * s, 0.9 * s), loc=(x - 0.05 * s, y, z + 1.55 * s), rot=(0, 28, 0), bevel=0.1 * s)
    for i in range(3):
        lc = ic.part(lace)
        lc.box((0.7 * s, 1.35 * s, 0.14 * s), loc=(x + (0.95 - 0.36 * i) * s, y, z + (0.86 + 0.34 * i) * s), rot=(0, -50, 0), bevel=0.04 * s)
    col = ic.part(BLACK)
    col.box((0.8 * s, 0.95 * s, 0.2 * s), loc=(x - 0.7 * s, y, z + 1.78 * s), rot=(0, -8, 0), bevel=0.04 * s)


@icon("ReturningSneakers", view=(12, 20), roll=0)
def _sneakers(ic):
    sneaker(ic, ORANGE, WHITE, WHITE, "#e9622a", WHITE, 0.0, 0.0, -0.5, 0.95)
    pts = arc_path(0.0, 0.2, 3.2, 20, 160, n=14, y=1.3)
    tube(ic, GOLD, pts, 0.2, 0.15, seg=5)
    arrow_head(ic, GOLD, (-3.2 * 0.94 - 0.35, 1.3, 0.2 + 3.2 * 0.342 - 0.9), (-0.34, 0, -0.94), length=1.1, r=0.55)
    sparkle(ic, YELLOW, (3.1, -0.4, 2.1), 0.34)


@icon("SeedSlinger", view=(14, 24), roll=0)
def _seed(ic):
    soil = ic.part(SOIL)
    soil.ico(1.7, loc=(0.7, 0, -1.9), subdiv=2, scale=(1.1, 0.9, 0.5))
    clod = ic.part("#7f5434")
    clod.ico(0.45, loc=(-0.6, -0.8, -1.8), subdiv=1, scale=(1, 0.8, 0.7))
    stem = ic.part(GREEN_D)
    sweep(stem, [(0.7, 0, -1.7), (0.55, 0, -0.5), (0.8, 0, 0.5), (0.9, 0, 1.3)], [0.3, 0.26, 0.22, 0.2], seg=5)
    l1 = ic.part(GREEN)
    slab(l1, leaf_pts(2.3, 0.95), 0.24, loc=(0.85, 0, 0.7), rot=(0, -28, 0), bevel=0.06)
    l2 = ic.part(GREEN_L)
    slab(l2, [(-x, z) for x, z in reversed(leaf_pts(2.0, 0.85))], 0.24, loc=(0.6, -0.1, 0.2), rot=(0, 24, 0), bevel=0.06)
    bud = ic.part(GREEN_L)
    bud.ico(0.5, loc=(0.95, 0, 1.55), subdiv=1, scale=(0.9, 0.9, 1.2))
    seed = ic.part(BLACK)
    seed.ico(0.85, loc=(-2.1, -0.3, 2.3), subdiv=1, scale=(0.6, 0.5, 1.0), rot=(0, 35, 0))
    sstripe = ic.part(WHITE)
    sstripe.ico(0.75, loc=(-2.1, -0.7, 2.3), subdiv=1, scale=(0.2, 0.3, 0.95), rot=(0, 35, 0))
    streaks(ic, YELLOW, (-1.55, -0.1, 1.55), (-1.0, 0, -1.0), n=2, length=1.3, spread=0.5, width=0.12)
    seed2 = ic.part(BLACK)
    seed2.ico(0.5, loc=(-3.1, -0.2, 0.7), subdiv=1, scale=(0.6, 0.5, 1.0), rot=(0, 55, 0))


@icon("ConfettiMinigun", view=(14, 24), roll=24)
def _confetti(ic):
    body = ic.part(RED)
    body.box((2.0, 1.5, 1.5), loc=(-1.0, 0, 0), bevel=0.25)
    body.cyl(0.95, 0.95, 1.5, seg=10, loc=(0.5, 0, 0), rot=(0, 90, 0), bevel=0.06)
    stripe = ic.part(GOLD)
    stripe.box((2.05, 1.56, 0.28), loc=(-1.0, 0, 0.0), bevel=0.05)
    hand = ic.part(IRON)
    hand.box((0.5, 0.55, 1.4), loc=(-1.2, 0, -1.35), rot=(0, 18, 0), bevel=0.1)
    ammo = ic.part(PINK)
    ammo.box((1.3, 1.2, 0.8), loc=(-1.1, 0, 1.15), bevel=0.2)
    bar = ic.part(STEEL_D)
    bar.limb((0.0, 0, 1.0), (1.4, 0, 1.0), 0.14, 0.14, seg=5)
    plate = ic.part(GOLD)
    plate.cyl(1.1, 1.1, 0.28, seg=12, loc=(1.35, 0, 0), rot=(0, 90, 0), bevel=0.05)
    for k in range(6):
        a = k / 6 * math.tau
        by, bz = math.cos(a) * 0.62, math.sin(a) * 0.62
        b = ic.part(STEEL_D if k % 2 else STEEL)
        b.cyl(0.26, 0.26, 2.4, seg=6, loc=(2.55, by, bz), rot=(0, 90, 0))
        tip = ic.part(BLACK)
        tip.cyl(0.17, 0.17, 0.1, seg=6, loc=(3.78, by, bz), rot=(0, 90, 0))
    ring = ic.part(GOLD_L)
    band(ring, 0.78, 0.98, 3.2, 3.5, seg=12, loc=(0, 0, 0), rot=(0, 90, 0))
    cols = (PINK, YELLOW, AQUA, GREEN_L, ORANGE, PURPLE_L, RED_L)
    spots = ((4.5, 0.2, 0.9), (4.9, -0.5, -0.5), (5.3, 0.4, 0.2), (5.6, -0.2, 1.1), (4.3, 0.1, -1.0), (5.9, 0.5, -0.4), (6.1, -0.4, 0.6),
             (4.8, 0.7, 1.4), (5.2, -0.7, -1.3), (6.4, 0.1, -0.2))
    for i, (cx, cy, cz) in enumerate(spots):
        c = ic.part(cols[i % len(cols)])
        c.box((0.34, 0.1, 0.22), loc=(cx, -0.5 + cy * 0.3, cz), rot=(i * 37 % 90, i * 53 % 90, i * 71 % 90), bevel=0.02)
    st = ic.part(PINK_L)
    sweep(st, [(3.9, -0.9, 0.2), (4.8, -0.9, 1.0), (5.5, -0.9, 0.5), (6.2, -0.9, 1.2)], [0.0, 0.08, 0.08, 0.0], seg=4)


@icon("ProteinClaws", view=(12, 18), roll=-8)
def _claws(ic):
    grip = ic.part(YELLOW)
    grip.box((3.2, 1.0, 1.0), loc=(0, 0, -1.4), bevel=0.3)
    wrap = ic.part(BLACK)
    for i in range(4):
        wrap.box((0.28, 1.06, 1.06), loc=(-1.1 + i * 0.75, 0, -1.4), bevel=0.06)
    guard = ic.part(STEEL_D)
    guard.box((3.5, 0.85, 0.4), loc=(0, 0, -0.75), bevel=0.14)
    for i, (x0, lean, ln) in enumerate(((-1.1, -9, 4.2), (0.0, 0, 4.7), (1.1, 9, 4.2))):
        n = 9
        left, right = [], []
        for k in range(n + 1):
            u = k / n
            cx = x0 + math.tan(math.radians(lean)) * ln * u + (0.35 * (i - 1)) * u * u
            w = 0.36 * (1 - u ** 1.6) + 0.02
            zz = -0.55 + ln * u
            left.append((cx - w, zz))
            right.append((cx + w, zz))
        cl = ic.part(STEEL_L)
        slab(cl, left + list(reversed(right[:-1])), 0.3, loc=(0, 0.0, 0), bevel=0.07)
        ridge = ic.part(STEEL)
        slab(ridge, [(x0 + math.tan(math.radians(lean)) * ln * k / n + 0.35 * (i - 1) * (k / n) ** 2 + 0.04, -0.55 + ln * k / n) for k in range(0, n)] +
             [(x0 + math.tan(math.radians(lean)) * ln * k / n + 0.35 * (i - 1) * (k / n) ** 2 + 0.34 * (1 - (k / n) ** 1.6), -0.55 + ln * k / n) for k in range(n - 1, -1, -1)],
             0.34, loc=(0, -0.02, 0), bevel=0.0)
    for j, (sx, sz) in enumerate(((-2.9, 2.0), (2.9, 2.7), (3.5, 1.6))):
        sl = ic.part(RED_L)
        sweep(sl, [(sx - 0.5, 0.9, sz - 1.4), (sx, 0.9, sz), (sx + 0.15, 0.9, sz + 0.8)], [0.0, 0.1, 0.0], seg=4)


@icon("RicochetPuck", view=(12, 30), roll=0)
def _puck(ic):
    puck = ic.part("#33384a")
    puck.cyl(1.9, 1.9, 1.05, seg=14, loc=(1.0, 0, -0.5), bevel=0.16)
    top = ic.part("#4d5470")
    top.cyl(1.55, 1.55, 0.14, seg=14, loc=(1.0, 0, 0.0), bevel=0.02)
    stripe = ic.part(TEAL)
    band(stripe, 1.9, 1.98, -0.85, -0.38, seg=14, loc=(1.0, 0, 0))
    star = ic.part(YELLOW)
    slab(star, star_pts(5, 0.95, 0.42), 0.14, loc=(1.0, 0, 0.12), rot=(90, 0, 0), bevel=0.0)
    pts = [(-3.6, 0.0, 3.2), (-2.4, 0.0, -0.6), (-0.7, 0.0, 1.3)]
    for a, b in zip(pts, pts[1:]):
        t = ic.part(YELLOW)
        t.limb(a, b, 0.17, 0.17, seg=5)
    j = ic.part(ORANGE)
    j.ico(0.3, loc=pts[1], subdiv=1)
    arrow_head(ic, YELLOW, (-0.25, 0, 1.55), (0.6, 0, 0.45), length=0.95, r=0.45)
    sparkle(ic, ORANGE_L, (-2.9, -0.5, -1.15), 0.62, pts=6, inner=0.42)


@icon("GloveCombo", view=(12, 18), roll=-6)
def _glove(ic):
    burst = ic.part(YELLOW)
    slab(burst, star_pts(9, 3.2, 2.15), 0.3, loc=(1.7, 1.3, 0.2), bevel=0.0)
    burst2 = ic.part(ORANGE)
    slab(burst2, star_pts(9, 2.6, 1.75, rot=0.18), 0.3, loc=(1.7, 1.0, 0.2), bevel=0.0)
    # a glove punching to the right: round fist, thumb tucked along the front, white cuff on the left
    g = ic.part(RED)
    g.ico(1.5, loc=(0.7, 0, 0.1), subdiv=2, scale=(1.2, 1.05, 1.1), jitter=0.04, seed=3)
    th = ic.part(RED_L)
    th.ico(0.9, loc=(0.1, -1.05, -0.6), subdiv=2, scale=(1.7, 0.95, 0.85), rot=(0, 20, 0))
    crease = ic.part(RED_D)
    crease.limb((-0.75, -1.5, -0.1), (1.6, -1.45, -0.05), 0.07, 0.07, seg=4)
    knuckle = ic.part(RED_D)
    for i in (0, 1, 2):
        knuckle.box((0.06, 0.1, 0.62), loc=(1.82, -1.0, 0.85 - i * 0.55), rot=(0, 0, 0), bevel=0.02)
    cuff = ic.part(WHITE)
    cuff.cyl(1.0, 1.1, 1.3, seg=10, loc=(-1.55, 0.0, 0.0), rot=(0, 90, 0))
    cb = ic.part(RED_D)
    cb.cyl(1.18, 1.18, 0.2, seg=10, loc=(-0.85, 0.0, 0.0), rot=(0, 90, 0))
    star = ic.part(GOLD)
    slab(star, star_pts(5, 0.42, 0.19), 0.12, loc=(0.4, -1.55, 0.7), bevel=0.0)


# ---------------------------------------------------------------- evolutions
BOLT = [(0.1, 1.6), (-0.9, -0.2), (-0.15, -0.2), (-0.55, -1.7), (0.85, 0.35), (0.1, 0.35), (0.8, 1.6)]


@icon("JunkyardCyclone", view=(10, 13), roll=0)
def _cyclone(ic):
    cone = ic.part("#46506a")
    cone.cyl(0.3, 2.0, 4.6, seg=14, loc=(0, 0, 0.1))
    cols = [STEEL, RUST, STEEL_D, RUST_D, STEEL, RUST]
    for i in range(6):
        u = i / 5
        R = 2.3 - 1.75 * u
        r = ic.part(cols[i])
        torus(r, R, 0.3 - 0.07 * u, seg=22, tseg=5, loc=(math.sin(u * 5.0) * 0.3, 0.0, 2.1 - 4.1 * u))
    gear_p = ic.part(STEEL_L)
    gear(gear_p, 8, 0.55, 0.78, 0.3, loc=(-2.65, -0.9, 2.1))
    hub = ic.part(IRON)
    hub.cyl(0.2, 0.2, 0.4, seg=6, loc=(-2.65, -1.0, 2.1), rot=(90, 0, 0))
    nut = ic.part(GOLD)
    band(nut, 0.22, 0.58, -0.22, 0.22, seg=6, loc=(2.75, -0.9, 0.9), rot=(90, 0, 0))
    plate = ic.part(RUST)
    slab(plate, [(-0.7, -0.45), (0.65, -0.5), (0.8, 0.35), (-0.4, 0.55)], 0.3, loc=(-2.5, -0.8, -0.9), rot=(0, 24, 0), bevel=0.07)
    bolt = ic.part(STEEL_L)
    bolt.cyl(0.17, 0.17, 1.2, seg=6, loc=(2.3, -0.8, -1.8), rot=(0, 70, 0))
    bolt.cyl(0.38, 0.38, 0.26, seg=6, loc=(2.85, -0.8, -1.65), rot=(0, 70, 0))
    sparkle(ic, YELLOW, (0.2, -1.5, 3.1), 0.45)


@icon("Toaststorm", view=(10, 20), roll=0)
def _toaststorm(ic):
    for (cx, cz, r, c) in ((-1.5, 2.45, 1.05, "#8d9bb8"), (-0.1, 2.9, 1.4, "#9eabc6"), (1.5, 2.45, 1.05, "#8d9bb8"), (0.1, 2.15, 1.25, "#b6c2da")):
        cl = ic.part(c)
        cl.ico(r, loc=(cx, 0, cz), subdiv=2, scale=(1.05, 0.9, 0.85))
    bolt = ic.part(YELLOW)
    slab(bolt, [(x * 0.75, z * 0.75) for x, z in BOLT], 0.4, loc=(0.1, -0.9, 0.7), bevel=0.06)
    glow = ic.part(ORANGE_L)
    slab(glow, [(x * 0.95, z * 0.95) for x, z in BOLT], 0.3, loc=(0.1, -0.7, 0.7), bevel=0.0)
    toast_slice(ic, -2.6, -0.4, -1.5, 18, 0.55)
    toast_slice(ic, 2.7, -0.4, -1.0, -22, 0.55)
    toast_slice(ic, 0.7, -0.9, -2.2, 6, 0.45, butter=False)
    for (dx, dz) in ((-2.4, 0.9), (2.6, 0.9), (-1.3, -0.3)):
        d = ic.part(AQUA_L)
        d.spike(0.1, 0.55, seg=4, base=(dx, -0.5, dz), direction=(-0.15, 0, -1))


@icon("BubbleTorrent", view=(8, 16), roll=0)
def _torrent(ic):
    # a breaking wave: back swell, a lighter front face and white foam, with bubbles tumbling off the crest
    outline = [(-3.5, -2.0), (-3.5, -1.2), (-3.1, -0.3), (-2.4, 0.7), (-1.5, 1.6), (-0.4, 2.3), (0.8, 2.7), (1.9, 2.6), (2.7, 2.1),
               (3.0, 1.5), (2.45, 1.75), (1.8, 1.95), (1.0, 1.85), (0.3, 1.4), (-0.1, 0.7), (0.0, -0.1), (0.6, -0.8), (1.5, -1.3),
               (2.5, -1.45), (3.5, -1.2), (3.5, -2.0)]
    back = ic.part(AQUA_D)
    slab(back, outline, 1.1, bevel=0.14)
    face = ic.part(AQUA)
    slab(face, [(0.05, -0.15), (0.0, 0.7), (0.4, 1.35), (1.0, 1.7), (1.8, 1.75), (2.35, 1.6), (1.9, 0.5), (1.5, -0.6), (0.9, -0.9), (0.4, -0.6)],
         0.5, loc=(0, -0.55, 0), bevel=0.1)
    lower = ic.part(AQUA)
    slab(lower, [(-3.2, -1.85), (-3.2, -1.1), (-2.7, -0.2), (-2.0, 0.5), (-1.6, -0.5), (-0.9, -1.1), (0.0, -1.5), (1.2, -1.85)], 0.5, loc=(0, -0.55, 0), bevel=0.1)
    foam = ic.part(WHITE)
    for (fx, fz, r) in ((-1.6, 1.55, 0.36), (-0.6, 2.25, 0.4), (0.6, 2.65, 0.44), (1.7, 2.55, 0.38), (2.55, 2.05, 0.3), (2.85, 1.45, 0.24)):
        foam.ico(r, loc=(fx, -0.75, fz), subdiv=2)
    for (bx, bz, r) in ((3.0, 3.0, 0.62), (4.0, 1.4, 0.42), (-2.9, 2.1, 0.5), (3.9, -0.4, 0.5), (-0.2, -1.55, 0.3), (4.1, 2.6, 0.3)):
        b = ic.part(AQUA_L)
        b.ico(r, loc=(bx, -0.4, bz), subdiv=2)
        s = ic.part(WHITE)
        s.ico(r * 0.26, loc=(bx - r * 0.38, -0.4 - r * 0.85, bz + r * 0.42), subdiv=1, scale=(1.4, 0.5, 1))


@icon("KnittingNightmare", view=(12, 22), roll=0)
def _nightmare(ic):
    for sgn in (1, -1):
        n = ic.part(STEEL_L)
        n.limb((-3.2 * sgn, 0.9, -2.4), (3.2 * sgn, 0.9, 2.4), 0.14, 0.1, seg=6)
        for e in (-1, 1):
            k = ic.part(RED)
            k.ico(0.34, loc=(3.3 * sgn * e, 0.9, 2.5 * e), subdiv=1)
    ball = ic.part(PURPLE)
    ball.ico(1.75, subdiv=2)
    for rot, c in (((62, 0, 25), PURPLE_L), ((-35, 0, -40), PURPLE_D), ((8, 0, 75), PURPLE_L), ((70, 0, -60), PURPLE_D)):
        w = ic.part(c)
        torus(w, 1.72, 0.15, seg=22, tseg=5, rot=rot)
    for sgn, tilt in ((1, -22), (-1, 22)):
        e = ic.part("#ffe14a", glow=2.0)
        e.box((0.85, 0.22, 0.3), loc=(0.62 * sgn, -1.72, 0.35), rot=(0, tilt, 0), bevel=0.05)
        pu = ic.part(BLACK)
        pu.box((0.2, 0.26, 0.2), loc=(0.55 * sgn, -1.78, 0.33), bevel=0.02)
    for (a, b, c) in (((1.4, -0.4, -1.2), (2.6, -0.6, -2.2), (3.6, -0.5, -1.7)), ((-1.5, -0.4, -1.1), (-2.5, -0.6, -1.9), (-3.5, -0.4, -1.6))):
        t = ic.part(PURPLE_L)
        sweep(t, [a, ((a[0] + b[0]) / 2, -0.7, (a[2] + b[2]) / 2 - 0.3), b, c], [0.15, 0.15, 0.13, 0.1], seg=5)


# ---------------------------------------------------------------- loot passives
@icon("PocketDynamo", view=(14, 22), roll=0)
def _dynamo(ic):
    body = ic.part(BLUE)
    body.cyl(1.4, 1.4, 3.0, seg=12, rot=(0, 90, 0), bevel=0.05)
    for k in (-0.95, -0.35, 0.25, 0.85):
        w = ic.part(COPPER)
        band(w, 1.38, 1.56, k - 0.16, k + 0.16, seg=12, rot=(0, 90, 0))
    for sx in (-1, 1):
        cap = ic.part(STEEL)
        cap.cyl(1.55, 1.55, 0.4, seg=12, loc=(1.72 * sx, 0, 0), rot=(0, 90, 0), bevel=0.06)
    axle = ic.part(STEEL_D)
    axle.cyl(0.25, 0.25, 0.9, seg=8, loc=(2.3, 0, 0), rot=(0, 90, 0))
    arm = ic.part(STEEL_D)
    arm.limb((2.6, 0, 0), (2.6, 0, 1.7), 0.16, 0.16, seg=6)
    knob = ic.part(RED)
    knob.cyl(0.3, 0.3, 0.9, seg=8, loc=(2.6, 0, 1.75), rot=(90, 0, 0), bevel=0.05)
    bolt = ic.part(YELLOW)
    slab(bolt, [(x * 0.62, z * 0.62) for x, z in BOLT], 0.3, loc=(0.0, -1.55, 0.0), bevel=0.05)
    feet = ic.part(IRON)
    feet.box((3.0, 1.9, 0.35), loc=(0.0, 0, -1.65), bevel=0.1)
    sparkle(ic, YELLOW, (-2.6, -0.9, 1.9), 0.45)
    sparkle(ic, YELLOW, (-3.1, -0.9, 0.7), 0.28)


def ratchet_pts(n, r_in, r_out):
    pts = []
    w = math.tau / n
    for i in range(n):
        a0 = i * w
        pts += [(math.sin(a0) * r_in, math.cos(a0) * r_in),
                (math.sin(a0 + 0.02 * w) * r_out, math.cos(a0 + 0.02 * w) * r_out),
                (math.sin(a0 + 0.22 * w) * r_out, math.cos(a0 + 0.22 * w) * r_out)]
    return pts


@icon("RatchetTimer", view=(10, 20), roll=0)
def _ratchet(ic):
    g = ic.part(TEAL)
    slab(g, ratchet_pts(14, 1.75, 2.4), 0.7, loc=(0, 0, 0), bevel=0.1)
    face = ic.part(TEAL_D)
    face.cyl(1.55, 1.55, 0.2, seg=20, loc=(0, -0.38, 0), rot=(90, 0, 0))
    ticks = ic.part(CREAM)
    for k in range(12):
        a = k / 12 * math.tau
        tr = 1.38
        ticks.box((0.12, 0.1, 0.3 if k % 3 == 0 else 0.17), loc=(math.sin(a) * tr, -0.5, math.cos(a) * tr), rot=(0, -math.degrees(a), 0), bevel=0.0)
    hub = ic.part(GOLD)
    hub.cyl(0.62, 0.62, 0.34, seg=10, loc=(0, -0.5, 0), rot=(90, 0, 0), bevel=0.04)
    hand = ic.part(RED)
    hand.limb((0, -0.72, 0), (0.55, -0.72, 0.5), 0.1, 0.07, seg=4)
    hand.box((0.18, 0.2, 0.75), loc=(0, -0.72, 0.35), bevel=0.04)
    pawl = ic.part(STEEL_L)
    slab(pawl, [(-1.9, 3.15), (-1.3, 3.4), (-0.2, 2.95), (0.6, 2.35), (0.05, 2.25), (-0.4, 2.6), (-1.5, 2.85)], 0.55, loc=(0, -0.05, 0), bevel=0.08)
    pivot = ic.part(GOLD)
    pivot.cyl(0.4, 0.4, 0.7, seg=10, loc=(-1.6, -0.1, 3.05), rot=(90, 0, 0), bevel=0.04)
    sparkle(ic, YELLOW, (2.9, -0.9, 2.7), 0.4)


@icon("TrailSneakers", view=(12, 20), roll=0)
def _trail(ic):
    sneaker(ic, "#2f8fe0", WHITE, "#f6f1e0", GREEN_L, WHITE, 0.8, 0.0, -0.3, 1.05)
    for (px, pz, r) in ((-2.6, -1.95, 0.62), (-3.5, -1.6, 0.46)):
        d = ic.part("#e9dfc7")
        d.ico(r, loc=(px, -0.2, pz), subdiv=2, scale=(1.2, 1, 0.9))
    streaks(ic, GREEN_L, (-1.5, -0.2, 0.7), (1, 0, 0.0), n=3, length=1.7, spread=0.8, width=0.13)


@icon("PatchworkPadding", view=(10, 18), roll=0)
def _patchwork(ic):
    base = ic.part(CREAM)
    slab(base, [(x * 1.06, z * 1.06 + 0.04) for x, z in [(x * 2.7, z * 2.7) for x, z in heart_pts(1.0)]], 0.55, bevel=0.12)
    heart = [(x * 2.7, z * 2.7) for x, z in heart_pts(1.0)]
    cx, cz = 0.0, -0.1
    cols = (RED, TEAL, YELLOW, PURPLE_L)
    quads = (((-1, 0), 0.0), ((1, 0), 0.0))
    regions = []
    left = clip_poly(heart, -1, 0, 0.0)
    right = clip_poly(heart, 1, 0, 0.0)
    for side, poly in ((0, left), (1, right)):
        top = clip_poly(poly, 0, 1, 0.15)
        bot = clip_poly(poly, 0, -1, -0.15)
        regions += [top, bot]
    colors = (RED, TEAL, YELLOW, PURPLE_L)
    for poly, c in zip(regions, colors):
        if len(poly) < 3:
            continue
        mx = sum(p[0] for p in poly) / len(poly)
        mz = sum(p[1] for p in poly) / len(poly)
        poly = [(mx + (x - mx) * 0.93, mz + (z - mz) * 0.93) for x, z in poly]
        pc = ic.part(c)
        slab(pc, poly, 0.5, loc=(0, -0.2, 0), bevel=0.08)
    st = ic.part("#3a2f2f")
    for i in range(-5, 3):
        st.box((0.1, 0.1, 0.34), loc=(0.0, -0.5, 0.15 + i * 0.4), bevel=0.0)
    for i in range(-5, 6):
        if abs(i * 0.5) < 2.4:
            st.box((0.34, 0.1, 0.1), loc=(i * 0.5, -0.5, 0.15), bevel=0.0)
    btn = ic.part(GOLD)
    btn.cyl(0.42, 0.42, 0.22, seg=10, loc=(0.0, -0.58, 0.15), rot=(90, 0, 0), bevel=0.04)
    for (hx, hz) in ((-0.1, 0.15), (0.1, 0.15)):
        hole = ic.part(BLACK)
        hole.cyl(0.06, 0.06, 0.1, seg=5, loc=(hx, -0.72, hz), rot=(90, 0, 0))
    sparkle(ic, YELLOW, (2.9, -0.7, 2.4), 0.4)


@icon("CollectorsBell", view=(10, 18), roll=0)
def _bell(ic):
    bell = ic.part(GOLD)
    lathe(bell, [(1.7, -1.3), (1.55, -1.05), (1.35, -0.3), (1.05, 0.7), (0.62, 1.55), (0.0, 1.85)], seg=12)
    rim = ic.part(GOLD_D)
    torus(rim, 1.62, 0.17, seg=12, tseg=5, loc=(0, 0, -1.25))
    shine = ic.part(GOLD_L)
    shine.box((0.28, 0.2, 1.7), loc=(-0.7, -1.0, 0.2), rot=(0, 18, 0), bevel=0.06)
    clap = ic.part(COPPER)
    clap.ico(0.42, loc=(0, 0, -1.65), subdiv=1)
    loop = ic.part(GOLD_D)
    torus(loop, 0.32, 0.1, seg=10, tseg=4, loc=(0, 0, 2.05), rot=(90, 0, 0))
    bow = ic.part(RED)
    bow.ico(0.42, loc=(-0.45, -0.3, 1.75), subdiv=1, scale=(1.3, 0.8, 0.8), rot=(0, 25, 0))
    bow.ico(0.42, loc=(0.45, -0.3, 1.75), subdiv=1, scale=(1.3, 0.8, 0.8), rot=(0, -25, 0))
    kn = ic.part(RED_D)
    kn.ico(0.22, loc=(0, -0.4, 1.75), subdiv=1)
    for sgn in (-1, 1):
        snd = ic.part(WHITE)
        sweep(snd, arc_path(0.0, 0.3, 2.55 + 0.0, 90 + 28 * sgn + 8, 90 + 28 * sgn + 52, n=5, y=0.0) if sgn > 0 else
              arc_path(0.0, 0.3, 2.55, 90 - 28 - 8 - 44, 90 - 28 - 8, n=5, y=0.0),
              [0.03, 0.1, 0.13, 0.1, 0.05, 0.02][:6], seg=4)
    for (cx, cz, tilt) in ((2.2, -1.5, 12), (3.0, -0.9, -16)):
        c = ic.part(GOLD)
        c.cyl(0.65, 0.65, 0.2, seg=12, loc=(cx, -0.6, cz), rot=(90 + 0, tilt, 0), bevel=0.04)
        ci = ic.part(GOLD_L)
        ci.cyl(0.42, 0.42, 0.22, seg=12, loc=(cx, -0.64, cz), rot=(90 + 0, tilt, 0))


@icon("LuckyButton", view=(10, 18), roll=0)
def _button(ic):
    b = ic.part(RED)
    b.cyl(2.1, 2.1, 0.6, seg=18, rot=(90, 0, 0), bevel=0.12)
    rim = ic.part(GOLD)
    torus(rim, 2.05, 0.2, seg=18, tseg=5, loc=(0, -0.3, 0), rot=(90, 0, 0))
    dish = ic.part(RED_D)
    dish.cyl(1.4, 1.4, 0.16, seg=16, loc=(0, -0.33, 0), rot=(90, 0, 0))
    for (hx, hz) in ((-0.55, 0.55), (0.55, 0.55), (-0.55, -0.55), (0.55, -0.55)):
        h = ic.part(BLACK)
        h.cyl(0.24, 0.24, 0.12, seg=8, loc=(hx, -0.42, hz), rot=(90, 0, 0))
    for sgn in (1, -1):
        th = ic.part(WHITE)
        th.limb((-0.58 * sgn, -0.5, 0.58), (0.58 * sgn, -0.5, -0.58), 0.1, 0.1, seg=5)
    sparkle(ic, YELLOW, (2.4, -0.9, 2.2), 0.62)
    sparkle(ic, YELLOW, (-2.5, -0.9, -1.9), 0.4)


@icon("SpringStitch", view=(14, 22), roll=0)
def _spring(ic):
    for z, c in ((-2.5, IRON), (2.5, IRON)):
        cap = ic.part(c)
        cap.cyl(1.7, 1.7, 0.36, seg=12, loc=(0, 0, z), bevel=0.06)
    sp = ic.part(STEEL)
    helix(sp, 1.25, 4.6, 3.6, 0.27, loc=(0, 0, 0), seg_per_turn=12, tube_seg=6)
    core = ic.part(STEEL_D)
    core.cyl(0.45, 0.45, 4.6, seg=8)
    pts = []
    for i in range(7):
        zz = -1.95 + i * 0.65
        pts.append((((-1) ** i) * 0.55, -1.75, zz))
    th = ic.part(RED)
    sweep(th, pts, [0.11] * 7, seg=4)
    for i in range(0, 7, 2):
        x = pts[i]
        for sgn in (1, -1):
            st = ic.part(RED_L)
            st.limb((x[0] - 0.4, -1.85, x[2] + 0.28 * sgn), (x[0] + 0.4, -1.85, x[2] - 0.28 * sgn), 0.09, 0.09, seg=4)
    ndl = ic.part(STEEL_L)
    ndl.limb((1.9, -1.9, 3.0), (3.6, -1.9, 0.4), 0.11, 0.05, seg=5)
    ey = ic.part(STEEL_L)
    torus(ey, 0.22, 0.07, seg=8, tseg=4, loc=(1.75, -1.9, 3.15), rot=(90, 0, 30))


@icon("SplinterBadge", view=(10, 18), roll=0)
def _badge(ic):
    star = ic.part(WOOD)
    slab(star, star_pts(5, 2.8, 1.3), 0.6, bevel=0.14)
    for k in range(5):
        a = k / 5 * math.tau
        tip = ic.part(GOLD)
        tip.ico(0.36, loc=(math.sin(a) * 2.78, -0.05, math.cos(a) * 2.78), subdiv=1)
    ring = ic.part(GOLD)
    torus(ring, 0.95, 0.14, seg=14, tseg=5, loc=(0, -0.34, 0), rot=(90, 0, 0))
    plate = ic.part(WOOD_L)
    plate.cyl(0.9, 0.9, 0.22, seg=12, loc=(0, -0.3, 0), rot=(90, 0, 0))
    cr = ic.part(WOOD_D)
    cr.limb((-0.55, -0.45, 0.6), (-0.1, -0.45, 0.0), 0.07, 0.05, seg=4)
    cr.limb((-0.1, -0.45, 0.0), (0.3, -0.45, 0.1), 0.05, 0.05, seg=4)
    cr.limb((0.3, -0.45, 0.1), (0.5, -0.45, -0.6), 0.05, 0.03, seg=4)
    cr2 = ic.part(WOOD_D)
    cr2.limb((1.2, -0.35, 1.2), (0.9, -0.35, 0.5), 0.07, 0.04, seg=4)
    cr2.limb((-1.5, -0.35, -1.1), (-0.9, -0.35, -0.7), 0.07, 0.04, seg=4)
    for (a0, b0, r) in (((2.3, -0.2, -1.9), (3.6, -0.3, -3.1), 0.2), ((1.0, -0.2, -2.8), (1.4, -0.3, -4.0), 0.15), ((3.2, -0.2, 0.2), (4.5, -0.3, -0.4), 0.15)):
        sp = ic.part(WOOD_L)
        sp.limb(a0, b0, r, 0.0, seg=4)
        sp2 = ic.part(CREAM)
        sp2.limb((a0[0] - 0.02, a0[1] - 0.12, a0[2]), ((a0[0] + b0[0]) / 2, (a0[1] + b0[1]) / 2 - 0.12, (a0[2] + b0[2]) / 2), r * 0.35, 0.0, seg=4)


# DEFS_END


def contact_sheet(ids, path):
    """Big sheet (items first, then class heads) with 64 px previews on light and dark and a few of the
    existing pictures (reference row) to compare the style."""
    from PIL import Image, ImageDraw, ImageFont
    ids = [i for i in ids if i[1] != "hero"] + [i for i in ids if i[1] == "hero"]
    cell, cols, lab = 220, 7, 24
    rows = math.ceil(len(ids) / cols)
    width = cols * cell
    per_row = (width - 8) // 66
    strip_rows = math.ceil((len(ids) + 6) / per_row)
    strip_h = strip_rows * 68 + 6
    sheet = Image.new("RGB", (width, rows * (cell + lab) + 2 * strip_h + 8), (196, 214, 230))
    d = ImageDraw.Draw(sheet)
    try:
        font = ImageFont.truetype("DejaVuSans.ttf", 13)
    except OSError:
        font = ImageFont.load_default()

    def src_of(name, kind):
        return os.path.join(OUT_HEROES if kind == "hero" else OUT, ("hero_" + name if kind == "hero" else name) + ".png")

    for i, (name, kind, _fn, _o) in enumerate(ids):
        x, y = (i % cols) * cell, (i // cols) * (cell + lab)
        if os.path.exists(src_of(name, kind)):
            im = Image.open(src_of(name, kind)).convert("RGBA").resize((cell - 10, cell - 10), Image.LANCZOS)
            sheet.paste(im, (x + 5, y + 5), im)
        d.text((x + 6, y + cell), name, fill=(20, 28, 43), font=font)
    refs = [os.path.join(OUT, n + ".png") for n in ("Axe", "Sling", "Garlic", "Might", "Whetstone")] + [os.path.join(OUT_HEROES, "hero_Knight.png")]
    files = [src_of(n, k) for n, k, _f, _o in ids] + refs
    y0 = rows * (cell + lab) + 4
    for bgi, bg in enumerate(((255, 255, 255), (36, 44, 66))):
        top = y0 + bgi * strip_h
        d.rectangle([0, top, width, top + strip_h - 2], fill=bg)
        for i, f in enumerate(files):
            if not os.path.exists(f):
                continue
            im = Image.open(f).convert("RGBA").resize((64, 64), Image.LANCZOS)
            sheet.paste(im, (4 + (i % per_row) * 66, top + 3 + (i // per_row) * 68), im)
    os.makedirs(os.path.dirname(path), exist_ok=True)
    sheet.save(path)


def main():
    argv = sys.argv[sys.argv.index("--") + 1:] if "--" in sys.argv else sys.argv[1:]
    ap = argparse.ArgumentParser()
    ap.add_argument("--only", default="")
    ap.add_argument("--samples", type=int, default=48)
    ap.add_argument("--sheet", action="store_true")
    ap.add_argument("--out", default="", help="write PNGs here instead of art/icons (test renders)")
    args = ap.parse_args(argv)
    only = {x for x in args.only.split(",") if x}
    todo = [i for i in ICONS if not only or i[0] in only or ("hero_" + i[0]) in only]
    if not args.sheet:
        for name, kind, fn, opt in todo:
            ic = class_ic(name) if kind == "hero" else Ic(name)
            if kind != "hero":
                clear_scene()
                fn(ic)
            base = args.out or (OUT_HEROES if kind == "hero" else OUT)
            path = os.path.join(base, ("hero_" + name if kind == "hero" else name) + ".png")
            view = CLASS_MODELS[name][3] if kind == "hero" else opt["view"]
            render_icon(ic, path, view, opt["roll"], opt["rot"], args.samples)
            print("rendered", path, flush=True)
    if not only or args.sheet:
        contact_sheet(ICONS, SHEET)
        print("sheet", SHEET)


if __name__ == "__main__":
    main()
