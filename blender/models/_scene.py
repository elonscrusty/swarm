"""Composed vignettes from the gameplay camera (55 degrees down), to check a kit's cohesion.

    python3 blender/models/_scene.py <scene> [--samples 32] [--out renders/Scenes/<scene>.png]

Scenes live in _scenes.py (SCENES dict): ground colours, ground patches, paths and a list of
placements (model name, x, y, yaw degrees, scale). Models are built straight from the
registry (no FBX round trip), each once, then instanced. Not a model module (underscore).
"""

import argparse
import importlib
import math
import os
import random
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
BLENDER = os.path.dirname(HERE)
ROOT = os.path.dirname(BLENDER)
sys.path.insert(0, BLENDER)

import bpy  # noqa: E402
from mathutils import Vector  # noqa: E402

import build as B  # noqa: E402
import swarmkit as K  # noqa: E402
from style import P  # noqa: E402


def lin(c):
    return B.srgb_to_linear(c)


def ground_mat(color, name):
    m = bpy.data.materials.new(name)
    m.use_nodes = True
    bsdf = m.node_tree.nodes["Principled BSDF"]
    bsdf.inputs["Base Color"].default_value = (*lin(color), 1)
    bsdf.inputs["Roughness"].default_value = 0.9
    return m


def blob_poly(cx, cy, rx, ry, n, seed, wob=0.18):
    rng = random.Random(seed)
    pts = []
    for i in range(n):
        a = i / n * math.tau + rng.uniform(-0.1, 0.1)
        k = 1 + rng.uniform(-wob, wob)
        pts.append((cx + math.cos(a) * rx * k, cy + math.sin(a) * ry * k))
    return pts


def add_flat(name, pts, z, color):
    me = bpy.data.meshes.new(name)
    me.from_pydata([(x, y, z) for x, y in pts], [], [list(range(len(pts)))])
    me.materials.append(ground_mat(color, name))
    ob = bpy.data.objects.new(name, me)
    bpy.context.scene.collection.objects.link(ob)
    return ob


def add_path(name, points, width, z, color, seed=1):
    rng = random.Random(seed)
    left, right = [], []
    for i, (x, y) in enumerate(points):
        a = points[max(i - 1, 0)]
        b = points[min(i + 1, len(points) - 1)]
        dx, dy = b[0] - a[0], b[1] - a[1]
        L = math.hypot(dx, dy) or 1
        nx, ny = -dy / L, dx / L
        w = width / 2 * (1 + rng.uniform(-0.18, 0.18))
        left.append((x + nx * w, y + ny * w))
        right.append((x - nx * w * (1 + rng.uniform(-0.15, 0.15)), y - ny * w))
    return add_flat(name, left + right[::-1], z, color)


def main():
    argv = sys.argv[sys.argv.index("--") + 1:] if "--" in sys.argv else sys.argv[1:]
    ap = argparse.ArgumentParser()
    ap.add_argument("scene")
    ap.add_argument("--samples", type=int, default=32)
    ap.add_argument("--out", default="")
    ap.add_argument("--res", default="1600x900")
    args = ap.parse_args(argv)
    from models._scenes import SCENES
    sc = SCENES[args.scene]

    bpy.ops.wm.read_factory_settings(use_empty=True)
    scene = bpy.context.scene
    scene.unit_settings.system = "NONE"
    for mod in B.MODULES:
        importlib.import_module(mod)
    reg = {r[0]: r for r in K.REGISTRY}

    s = scene
    s.render.engine = "CYCLES"
    s.cycles.device = "CPU"
    s.cycles.samples = args.samples
    s.cycles.use_denoising = True
    w, h = (int(v) for v in args.res.split("x"))
    s.render.resolution_x, s.render.resolution_y = w, h
    s.view_settings.view_transform = "Standard"
    world = bpy.data.worlds.new("W")
    world.use_nodes = True
    bg = world.node_tree.nodes["Background"]
    bg.inputs["Color"].default_value = (*lin(sc.get("sky", (0.72, 0.8, 0.92))), 1)
    bg.inputs["Strength"].default_value = sc.get("sky_strength", 0.9)
    s.world = world
    sun = bpy.data.objects.new("Sun", bpy.data.lights.new("Sun", "SUN"))
    sun.data.energy = sc.get("sun", 3.2)
    sun.data.color = sc.get("sun_color", (1.0, 0.97, 0.9))
    sun.data.angle = math.radians(10)
    sun.rotation_euler = (math.radians(42), math.radians(8), math.radians(-35))
    s.collection.objects.link(sun)

    # ground: base plane, tone patches, paths
    add_flat("Ground", [(-400, -400), (400, -400), (400, 400), (-400, 400)], 0.0, sc["ground"])
    for i, (cx, cy, rx, ry, color) in enumerate(sc.get("patches", [])):
        add_flat(f"Patch{i}", blob_poly(cx, cy, rx, ry, 14, 900 + i), 0.01 + i * 0.0005, color)
    for i, (pts, width, color) in enumerate(sc.get("paths", [])):
        add_path(f"Path{i}", pts, width, 0.03 + i * 0.001, color, seed=50 + i)

    # build each model once, instance it per placement
    built = {}
    for name, *_ in sc["place"]:
        if name in built:
            continue
        _, category, note, fn = reg[name]
        col = bpy.data.collections.new("src_" + name)
        model = K.Model(name, category, note)
        fn(model)
        built[name] = B.build_model(model, col)
    for i, (name, x, y, yaw, scale, *rest) in enumerate(sc["place"]):
        z0 = rest[0] if rest else 0.0
        for o in built[name]:
            inst = bpy.data.objects.new(f"{name}_{i}_{o.name}", o.data)
            inst.location = Vector(o.location) * scale
            inst.scale = (scale, scale, scale)
            # rotate the piece offset about the model origin, then move to the spot
            ang = math.radians(yaw)
            px, py, pz = inst.location
            inst.location = (x + px * math.cos(ang) - py * math.sin(ang), y + px * math.sin(ang) + py * math.cos(ang), pz + z0)
            inst.rotation_euler = (0, 0, ang)
            s.collection.objects.link(inst)

    # gameplay camera: 55 degrees down, looking north (+Y), from the south
    cam = bpy.data.objects.new("Cam", bpy.data.cameras.new("Cam"))
    s.collection.objects.link(cam)
    s.camera = cam
    tx, ty = sc.get("focus", (0, 0))
    dist = sc.get("distance", 75)
    pitch = math.radians(55)
    cam.location = (tx, ty - math.cos(pitch) * dist, math.sin(pitch) * dist)
    cam.rotation_euler = (math.radians(90 - 55), 0, 0)
    cam.data.lens = sc.get("lens", 35)
    cam.data.clip_end = 2000
    out = args.out or os.path.join(ROOT, "renders", "Scenes", args.scene + ".png")
    os.makedirs(os.path.dirname(out), exist_ok=True)
    s.render.filepath = out
    bpy.ops.render.render(write_still=True)
    print("wrote", out)


if __name__ == "__main__":
    main()
