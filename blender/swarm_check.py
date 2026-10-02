"""Readability and animation checks for the creature models (blender/models/enemies.py).

    python3 blender/swarm_check.py                  swarm on moss grass from the gameplay camera
    python3 blender/swarm_check.py --poses          each creature at its animation extremes
    python3 blender/swarm_check.py --preview Mite   quick previews (no FBX / catalog writes)

Builds the Enemies models in memory only, so it never touches meshes/ or meshes/catalog.json.

Swarm check: a moss_500 ground with darker / lighter moss patches and a dirt path, the seven
creatures at gameplay scale (fliers at their FlyHeight), a stand-in hero, an elite, and the
plain server bodies (EnemyData Color / Material / Mesh, what players see past
Config.Graphics.MaxDetailedEnemies), seen from the gameplay camera (Config.Camera: pitch 58,
distance 64, FOV 50) at phone-like resolution. Output: renders/Enemies/SwarmCheck*.png.

Poses: for every animated piece the runtime transform of ModelLibrary.Animate at both ends
of its cycle (mirrored here in Python), rotated around the piece pivot, so wrong pivots or
wings that flap the wrong way show up. Output: renders/Enemies/Poses.png.
"""

import argparse
import math
import os
import random
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
sys.path.insert(0, HERE)

import bpy  # noqa: E402
from mathutils import Matrix, Vector  # noqa: E402

import build as B  # noqa: E402
import swarmkit as K  # noqa: E402
from style import P  # noqa: E402

OUT = os.path.join(ROOT, "renders", "Enemies")

# EnemyData id -> (model, FlyHeight, Size, Radius) for placement; mirrors src/shared/EnemyData.lua
TYPES = {
    "Slime": ("Mite", 0.0, (2.8, 2.2, 2.8)),
    "Bat": ("Wasp", 2.5, (2.6, 1.0, 1.4)),
    "Skeleton": ("BeetleWarrior", 0.0, (2.0, 4.2, 1.4)),
    "Ghost": ("PhaseMoth", 1.0, (2.6, 3.2, 2.6)),
    "Brute": ("RhinoBeetle", 0.0, (4.6, 5.0, 4.6)),
    "Bomber": ("BombTick", 0.0, (2.4, 2.4, 2.4)),
    "Boss": ("ScorpionQueen", 0.0, (12.0, 12.0, 12.0)),
}


def parse():
    argv = sys.argv[sys.argv.index("--") + 1:] if "--" in sys.argv else sys.argv[1:]
    ap = argparse.ArgumentParser()
    ap.add_argument("--poses", action="store_true")
    ap.add_argument("--preview", default="")
    ap.add_argument("--samples", type=int, default=16)
    ap.add_argument("--out", default=OUT)
    ap.add_argument("--scale", type=float, default=1.0, help="output size multiplier (1 = 640x360)")
    return ap.parse_args(argv)


# ------------------------------------------------------------------ models

def build_all(names=None):
    """Builds the enemy models into hidden template collections. Returns {name: (objs, model)}."""
    import importlib
    importlib.import_module("models.enemies")
    out = {}
    for name, category, note, fn in K.REGISTRY:
        if category != "Enemies" or (names and name not in names):
            continue
        col = bpy.data.collections.new("T_" + name)
        bpy.context.scene.collection.children.link(col)
        model = K.Model(name, category, note)
        fn(model)
        objs = B.build_model(model, col)
        out[name] = (objs, model)
    return out


def stats(model, objs):
    bpy.context.view_layer.update()
    tris = sum(p.tris for p in model.pieces)
    lo = Vector([min((o.matrix_world @ Vector(c))[i] for o in objs for c in o.bound_box) for i in range(3)])
    hi = Vector([max((o.matrix_world @ Vector(c))[i] for o in objs for c in o.bound_box) for i in range(3)])
    return tris, lo, hi


def instance(objs, matrix, col, tint=None):
    """Linked copies of a model's pieces under `matrix` (model origin = ground centre)."""
    made = []
    for o in objs:
        n = o.copy()
        n.hide_render = False
        n.matrix_world = matrix @ o.matrix_world
        if tint is not None:
            me = o.data.copy()
            for i, m in enumerate(me.materials):
                c = m.node_tree.nodes["Principled BSDF"].inputs["Base Color"].default_value
                lin = tuple(c[k] + (tint[k] - c[k]) * 0.22 for k in range(3))
                me.materials[i] = B.preview_material(lin, m.node_tree.nodes["Principled BSDF"].inputs["Emission Strength"].default_value > 0,
                                                     m.node_tree.nodes["Principled BSDF"].inputs["Alpha"].default_value)
            n.data = me
        col.objects.link(n)
        made.append(n)
    return made


# ------------------------------------------------------------------ animation mirror (ModelLibrary.Animate)

def animate(key, u, move=1.0):
    """Roblox (rx, ry, rz, ty) for anim `key` where u = the cycle's sine value (-1..1)."""
    if key in ("SwingA", "SwingB"):
        d = 1 if key == "SwingA" else -1
        return (u * (0.15 + move * 0.55) * d, 0, 0, 0)
    if key in ("FlapL", "FlapR"):
        d = 1 if key == "FlapL" else -1
        return (0, 0, u * 0.6 * d, 0)
    if key in ("FlutterL", "FlutterR"):
        d = -1 if key == "FlutterL" else 1
        return (0, 0, (0.2 + u * 0.55) * d, 0)
    if key == "Jaw":
        return (max(0, u) * 0.45, 0, 0, 0)
    if key in ("PinchL", "PinchR"):
        d = 1 if key == "PinchL" else -1
        return (0, max(0, u) * 0.45 * d, 0, 0)
    if key == "Tail":
        return (u * 0.12, 0, u * 0.08, 0)
    if key == "Wiggle":
        return (0, 0, u * 0.35, 0)
    if key == "Pulse":
        return (0, 0, 0, u * 0.05)
    if key == "Throb":
        return (0, 0, 0, -0.06 if u < 0 else 0.07)
    return (0, 0, 0, 0)


def roblox_to_blender(rx, ry, rz, ty):
    """CFrame.Angles(rx, ry, rz) + (0, ty, 0) in Roblox axes -> Blender 4x4 (same rotation)."""
    rr = (Matrix.Rotation(rx, 3, "X") @ Matrix.Rotation(ry, 3, "Y") @ Matrix.Rotation(rz, 3, "Z"))
    m = Matrix(((-1, 0, 0), (0, 0, 1), (0, 1, 0)))  # Blender -> Roblox (its own inverse)
    rb = m @ rr @ m
    out = rb.to_4x4()
    out.translation = m @ Vector((0, ty, 0))
    return out


def posed(objs, model, u):
    """Matrices for each piece object at cycle value u."""
    mats = []
    for o, p in zip(objs, model.pieces):
        base = Matrix.Translation(p.center)
        if p.anim:
            piv = p.pivot if p.pivot is not None else p.center
            a = roblox_to_blender(*animate(p.anim, u))
            rot = a.copy()
            rot.translation = Vector()
            mats.append(Matrix.Translation(a.translation) @ Matrix.Translation(piv) @ rot @ Matrix.Translation(-piv) @ base)
        else:
            mats.append(base)
    return mats


# ------------------------------------------------------------------ plain server bodies (EnemyData)

def enemy_data():
    """Visual fields of each enemy id from src/shared/EnemyData.lua."""
    with open(os.path.join(ROOT, "src", "shared", "EnemyData.lua")) as f:
        src = f.read()
    out = {}
    for m in re.finditer(r'\n\t(\w+) = \{\n\t\tId = "(\w+)"(.*?)\n\t\},', src, re.S):
        body = m.group(3)
        d = {}
        c = re.search(r"Color = Palette\.(\w+)", body)
        if c:
            d["Color"] = P(c.group(1))
        else:
            c = re.search(r"Color = Color3\.fromRGB\((\d+), (\d+), (\d+)\)", body)
            d["Color"] = tuple(int(c.group(i)) / 255 for i in (1, 2, 3))
        d["Material"] = re.search(r'Material = "(\w+)"', body).group(1)
        t = re.search(r"Transparency = ([\d.]+)", body)
        d["Transparency"] = float(t.group(1)) if t else 0.0
        mesh = re.search(r'Mesh = \{ Type = "(\w+)", Scale = Vector3\.new\(([\d., ]+)\) \}', body)
        d["Mesh"] = (mesh.group(1), tuple(float(x) for x in mesh.group(2).split(","))) if mesh else None
        d["Shape"] = re.search(r'Shape = "(\w+)"', body).group(1)
        out[m.group(2)] = d
    return out


def plain_body(type_id, d, matrix, col):
    """One plain enemy body (a Part with a SpecialMesh) as Blender geometry."""
    _, fly, size = TYPES[type_id]
    kind, scale = d["Mesh"] if d["Mesh"] else (("Sphere" if d["Shape"] == "Ball" else "Brick"), (1, 1, 1))
    sx, sy, sz = size[0] * scale[0], size[2] * scale[2], size[1] * scale[1]  # Blender x, y, z
    if kind in ("Sphere", "Head"):
        bpy.ops.mesh.primitive_uv_sphere_add(segments=24, ring_count=12, radius=0.5)
    else:
        bpy.ops.mesh.primitive_cube_add(size=1.0)
    o = bpy.context.active_object
    for c in o.users_collection:
        c.objects.unlink(o)
    col.objects.link(o)
    o.matrix_world = matrix @ Matrix.Translation((0, 0, fly + size[1] / 2)) @ Matrix.Diagonal((sx, sy, sz, 1.0))
    glow = d["Material"] == "Neon"
    o.data.materials.append(B.preview_material(B.srgb_to_linear(d["Color"]), glow, 1 - d["Transparency"]))
    for poly in o.data.polygons:
        poly.use_smooth = True
    return o


# ------------------------------------------------------------------ scene

def setup_scene(samples, w, h):
    s = bpy.context.scene
    s.render.engine = "CYCLES"
    s.cycles.device = "CPU"
    s.cycles.samples = samples
    s.cycles.use_denoising = True
    s.render.resolution_x, s.render.resolution_y = w, h
    s.render.film_transparent = False
    s.view_settings.view_transform = "Standard"
    world = bpy.data.worlds.new("Sky")
    world.use_nodes = True
    world.node_tree.nodes["Background"].inputs["Color"].default_value = (0.62, 0.74, 0.92, 1)
    world.node_tree.nodes["Background"].inputs["Strength"].default_value = 0.42
    s.world = world
    sun = bpy.data.objects.new("Sun", bpy.data.lights.new("Sun", "SUN"))
    sun.data.energy = 2.6
    sun.data.angle = math.radians(14)  # soft shadows
    sun.data.color = (1.0, 0.97, 0.9)
    sun.rotation_euler = (math.radians(38), math.radians(12), math.radians(-35))
    s.collection.objects.link(sun)
    return s


def matte(color):
    """Rough, non-glossy material for the ground (no sky sheen)."""
    m = bpy.data.materials.new("Ground_" + color)
    m.use_nodes = True
    bsdf = m.node_tree.nodes["Principled BSDF"]
    bsdf.inputs["Base Color"].default_value = (*B.srgb_to_linear(P(color)), 1)
    bsdf.inputs["Roughness"].default_value = 0.95
    bsdf.inputs["Specular IOR Level"].default_value = 0.15
    return m


def ground(col):
    def disc(name, color, verts, z):
        me = bpy.data.meshes.new(name)
        me.from_pydata([(x, y, z) for x, y in verts], [], [list(range(len(verts)))])
        me.materials.append(matte(color))
        o = bpy.data.objects.new(name, me)
        col.objects.link(o)

    disc("Grass", "moss_500", [(-200, -200), (200, -200), (200, 200), (-200, 200)], -0.02)
    rng = random.Random(7)

    def blob(cx, cy, r, n=14):
        return [(cx + math.cos(a) * r * rng.uniform(0.8, 1.15), cy + math.sin(a) * r * rng.uniform(0.8, 1.15))
                for a in (2 * math.pi * i / n for i in range(n))]

    disc("PatchDark", "moss_600", blob(-24, 6, 11), -0.015)
    disc("PatchLight", "moss_400", blob(20, -6, 9), -0.015)
    path = [(-60, -14), (-20, -9), (8, -11), (60, -5), (60, -1), (8, -7), (-20, -5), (-60, -10)]
    disc("Path", "dirt_500", path, -0.012)


def hero(col, at):
    """Stand-in knight (just for scale): steel body, crimson cape, ~7 studs tall."""
    for name, color, size, loc in (("HeroLegs", "steel_600", (1.6, 1.0, 2.0), (0, 0, 1.0)),
                                   ("HeroBody", "steel_400", (2.2, 1.2, 2.0), (0, 0, 3.0)),
                                   ("HeroCape", "crimson_500", (2.0, 0.25, 3.0), (0, 0.7, 2.6)),
                                   ("HeroHead", "steel_300", (1.5, 1.4, 1.4), (0, 0, 4.7)),
                                   ("HeroPlume", "crimson_500", (0.3, 1.2, 0.7), (0, 0.1, 5.7))):
        bpy.ops.mesh.primitive_cube_add(size=1.0)
        o = bpy.context.active_object
        for c in o.users_collection:
            c.objects.unlink(o)
        col.objects.link(o)
        o.scale = size
        o.location = (at[0] + loc[0], at[1] + loc[1], loc[2])
        o.data.materials.append(B.preview_material(B.srgb_to_linear(P(color)), False))


def gameplay_camera(scene, target, pitch=58, distance=64, fov=50):
    cam = bpy.data.objects.new("Cam", bpy.data.cameras.new("Cam"))
    scene.collection.objects.link(cam)
    scene.camera = cam
    p = math.radians(pitch)
    cam.location = Vector(target) + Vector((0, math.cos(p), math.sin(p))) * distance
    d = (Vector(target) - cam.location).normalized()
    cam.rotation_euler = d.to_track_quat("-Z", "Y").to_euler()
    cam.data.sensor_fit = "VERTICAL"
    cam.data.angle = math.radians(fov)
    cam.data.clip_end = 1000
    return cam


def place(x, y, face_to=(0, 0), z=0.0, scale=1.0):
    """Model matrix at (x, y) facing the point face_to (models face -Y)."""
    yaw = math.atan2(face_to[0] - x, -(face_to[1] - y))
    return Matrix.Translation((x, y, z)) @ Matrix.Rotation(yaw, 4, "Z") @ Matrix.Scale(scale, 4)


def swarm(args):
    w, h = int(640 * args.scale), int(360 * args.scale)
    scene = setup_scene(args.samples, w, h)
    models = build_all()
    for name, (objs, _) in models.items():
        for o in objs:
            o.hide_render = True
    col = bpy.data.collections.new("Swarm")
    scene.collection.children.link(col)
    ground(col)
    hero(col, (0, 0))
    rng = random.Random(11)
    # the swarm closing in on the hero; fliers at their FlyHeight
    layout = [("Mite", 0.0, 22, 7, 13), ("Wasp", 2.5, 8, 9, 15), ("BeetleWarrior", 0.0, 6, 10, 16),
              ("PhaseMoth", 1.0, 5, 11, 17), ("RhinoBeetle", 0.0, 2, 13, 17), ("BombTick", 0.0, 4, 8, 14)]
    placed = []
    for name, z, count, r0, r1 in layout:
        objs = models[name][0]
        for _ in range(count):
            for _ in range(60):
                a = rng.uniform(0, 2 * math.pi)
                rr = rng.uniform(r0, r1)
                x, y = math.cos(a) * rr * 1.35, math.sin(a) * rr * 0.9 - 2
                if all((x - px) ** 2 + (y - py) ** 2 > (pr + 1.6) ** 2 for px, py, pr in placed):
                    break
            rad = {"RhinoBeetle": 2.6, "BeetleWarrior": 1.3}.get(name, 1.4)
            placed.append((x, y, rad))
            instance(objs, place(x, y, z=z), col)
    # an elite (x2, gold tint) and the queen at the top of the frame
    instance(models["BeetleWarrior"][0], place(-14, 8, z=0, scale=2.0), col, tint=B.srgb_to_linear(P("gold_400")))
    instance(models["Mite"][0], place(15, -9, z=0, scale=2.0), col, tint=B.srgb_to_linear(P("gold_400")))
    instance(models["ScorpionQueen"][0], place(4, 26), col)
    gameplay_camera(scene, (0, 4, 0))
    os.makedirs(args.out, exist_ok=True)
    scene.render.filepath = os.path.join(args.out, "SwarmCheck.png")
    bpy.ops.render.render(write_still=True)

    # lineup: each type (detailed) above its plain server body, same camera distance
    for o in col.objects:
        o.hide_render = True
    line = bpy.data.collections.new("Lineup")
    scene.collection.children.link(line)
    ground(line)
    data = enemy_data()
    xs = {"Slime": 17, "Bat": 11, "Skeleton": 5, "Ghost": -1, "Brute": -8, "Bomber": -15, "Boss": 0}
    for type_id, (name, fly, size) in TYPES.items():
        if type_id == "Boss":
            continue
        x = xs[type_id]
        instance(models[name][0], place(x, -4, face_to=(x, 40), z=fly), line)
        plain_body(type_id, data[type_id], place(x, 7, face_to=(x, 40)), line)
    scene.camera.location.y -= 6
    scene.render.filepath = os.path.join(args.out, "SwarmCheck_Lineup.png")
    bpy.ops.render.render(write_still=True)
    print("wrote", os.path.join(args.out, "SwarmCheck.png"), "and SwarmCheck_Lineup.png")


def poses(args):
    scene = bpy.context.scene
    renderer = B.Renderer(scene, args.samples)
    scene.render.resolution_x = scene.render.resolution_y = 300
    models = build_all()
    entries = []
    for name, (objs, model) in models.items():
        for o in objs:
            o.hide_render = True
        for label, u in (("rest", 0.0), ("+1", 1.0), ("-1", -1.0)):
            for o, mtx in zip(objs, posed(objs, model, u)):
                o.matrix_world = mtx
            png = os.path.join(args.out, "_poses", f"{name}_{label}.png")
            renderer.render(objs, png, direction=(1.0, -1.1, 0.75))
            keys = sorted({p.anim for p in model.pieces if p.anim})
            entries.append((png, f"{name} {label}", ", ".join(keys)))
        for o, mtx in zip(objs, posed(objs, model, 0.0)):
            o.matrix_world = mtx
    B.contact_sheet(entries, os.path.join(args.out, "Poses.png"), "SWARM - creature animation extremes", cols=6, cell=260)
    print("wrote", os.path.join(args.out, "Poses.png"))


def preview(args):
    scene = bpy.context.scene
    renderer = B.Renderer(scene, args.samples)
    names = [n for n in args.preview.split(",") if n]
    models = build_all(names if names != ["all"] else None)
    entries = []
    for name, (objs, model) in models.items():
        tris, lo, hi = stats(model, objs)
        size = hi - lo
        print(f"{name:<14} {len(objs):>2} pieces {tris:>5} tris  width {size.x:.2f}  length {size.y:.2f}  "
              f"height {size.z:.2f}  z {lo.z:.2f}..{hi.z:.2f}  y {lo.y:.2f}..{hi.y:.2f}")
        print("    " + ", ".join(f"{p.name}:{p.tris}" for p in model.pieces))
        for o in models[name][0]:
            o.hide_render = False
        for other, (oo, _) in models.items():
            if other != name:
                for o in oo:
                    o.hide_render = True
        for view, d in (("a", (0.85, -1.3, 0.85)), ("top", (0.2, -0.62, 1.0)), ("side", (1.0, 0.0, 0.25))):
            png = os.path.join(args.out, f"{name}_{view}.png")
            renderer.render(objs, png, direction=d)
            entries.append((png, f"{name} {view}", f"{len(objs)} pieces, {tris} tris"))
    B.contact_sheet(entries, os.path.join(args.out, "Preview.png"), "SWARM - creature preview", cols=3, cell=360)
    print("wrote", os.path.join(args.out, "Preview.png"))


def main():
    args = parse()
    bpy.ops.wm.read_factory_settings(use_empty=True)
    bpy.context.scene.unit_settings.system = "NONE"
    if args.preview:
        preview(args)
    elif args.poses:
        poses(args)
    else:
        swarm(args)


if __name__ == "__main__":
    main()
