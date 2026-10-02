"""Build every SWARM mesh model, export FBX files, write the catalog and render previews.

    python3 blender/build.py                      everything
    python3 blender/build.py --only Mite,Enemies  some models / categories
    python3 blender/build.py --no-render          skip preview pictures

Needs the `bpy` module (pip install bpy==5.0.1, Python 3.11) and Pillow for contact sheets.

Outputs (repo root):
  meshes/<Category>/<Model>.fbx     one FBX per model, one mesh object per piece
  meshes/catalog.json               piece data used by tools/gen_mesh_catalog.py
  renders/<Model>.png, renders/Sheet_<Category>.png
  renders/<Model>_All.png    also, for models with extra["render_hide"] (pieces left out of
                             <Model>.png, e.g. the Colossus's phase-2 frost armour)
"""

import argparse
import fcntl
import importlib
import json
import math
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
sys.path.insert(0, HERE)

import bpy  # noqa: E402
from mathutils import Vector  # noqa: E402

import swarmkit as K  # noqa: E402

# Every blender/models/*.py module registers its models (new files are picked up automatically).
MODULES = sorted("models." + f[:-3] for f in os.listdir(os.path.join(HERE, "models"))
                 if f.endswith(".py") and not f.startswith("_"))
OUT_MESH = os.path.join(ROOT, "meshes")
OUT_RENDER = os.path.join(ROOT, "renders")


def parse():
    argv = sys.argv[sys.argv.index("--") + 1:] if "--" in sys.argv else sys.argv[1:]
    ap = argparse.ArgumentParser()
    ap.add_argument("--only", default="")
    ap.add_argument("--no-render", action="store_true")
    ap.add_argument("--samples", type=int, default=24)
    return ap.parse_args(argv)


# ------------------------------------------------------------------ materials

_mats = {}


def preview_material(color, glow, alpha=1.0):
    key = (tuple(round(c, 3) for c in color), glow, round(alpha, 2))
    if key in _mats:
        return _mats[key]
    m = bpy.data.materials.new("M_%d" % len(_mats))
    m.use_nodes = True
    bsdf = m.node_tree.nodes["Principled BSDF"]
    bsdf.inputs["Base Color"].default_value = (*color, 1)
    bsdf.inputs["Roughness"].default_value = 0.55
    if glow:
        bsdf.inputs["Emission Color"].default_value = (*color, 1)
        bsdf.inputs["Emission Strength"].default_value = 0.8
    if alpha < 1:
        bsdf.inputs["Alpha"].default_value = alpha
    _mats[key] = m
    return m


def srgb_to_linear(c):
    return tuple(((x + 0.055) / 1.055) ** 2.4 if x > 0.04045 else x / 12.92 for x in c)


# ------------------------------------------------------------------ build

def build_model(model, collection):
    palette = dict(K.SLOT_PREVIEW)
    palette.update(model.extra.get("palette", {}))
    objs = []
    for p in model.pieces:
        p.finish()
        me = bpy.data.meshes.new(p.name)
        p.bm.to_mesh(me)
        p.bm.free()
        for poly in me.polygons:
            poly.use_smooth = False  # faceted low-poly look
        col = palette.get(p.slot, (0.6, 0.6, 0.6))
        me.materials.append(preview_material(srgb_to_linear(col), p.material == "Neon", 1 - p.transparency))
        ob = bpy.data.objects.new(p.name, me)
        ob.location = p.center
        collection.objects.link(ob)
        objs.append(ob)
    return objs


def export_fbx(objs, path):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    bpy.context.view_layer.update()
    for o in bpy.context.scene.objects:
        if o.name in bpy.context.view_layer.objects:
            o.select_set(False)
    for o in objs:
        o.select_set(True)
    bpy.context.view_layer.objects.active = objs[0]
    bpy.ops.export_scene.fbx(
        filepath=path, use_selection=True, object_types={"MESH"},
        apply_unit_scale=True, apply_scale_options="FBX_SCALE_UNITS", global_scale=1.0,
        axis_forward="Z", axis_up="Y", mesh_smooth_type="OFF", use_mesh_modifiers=True,
        use_triangles=True, add_leaf_bones=False, bake_anim=False, path_mode="AUTO")


def record(model, objs):
    pieces = []
    tris = 0
    for p in model.pieces:
        tris += p.tris
        rec = dict(name=p.name, slot=p.slot, material=p.material,
                   offset=K.to_roblox(p.center), size=K.roblox_size(p.size))
        if p.bone:
            rec["bone"] = p.bone
        if p.transparency:
            rec["transparency"] = round(p.transparency, 3)
        if p.shadow:
            rec["shadow"] = True
        if p.anim:
            rec["anim"] = p.anim
            pivot = p.pivot if p.pivot is not None else p.center
            rec["pivot"] = K.to_roblox(pivot - p.center)
        pieces.append(rec)
    palette = dict(K.SLOT_PREVIEW)
    palette.update(model.extra.get("palette", {}))
    used = {p.slot for p in model.pieces}
    extra = {k: v for k, v in model.extra.items() if k not in ("palette", "joints", "render_hide")}
    if "joints" in model.extra:
        extra["joints"] = {k: K.to_roblox(v) for k, v in model.extra["joints"].items()}
    lo = [min(p["offset"][i] - p["size"][i] / 2 for p in pieces) for i in range(3)]
    hi = [max(p["offset"][i] + p["size"][i] / 2 for p in pieces) for i in range(3)]
    return dict(name=model.name, category=model.category, note=model.note, tris=tris,
                pieces=pieces, preview_palette={k: list(v) for k, v in palette.items() if k in used},
                bounds=[[round(x, 3) for x in lo], [round(x, 3) for x in hi]], **extra)


# ------------------------------------------------------------------ render

class Renderer:
    def __init__(self, scene, samples):
        s = scene
        s.render.engine = "CYCLES"
        s.cycles.device = "CPU"
        s.cycles.samples = samples
        s.cycles.use_denoising = True
        s.render.resolution_x = s.render.resolution_y = 420
        s.render.film_transparent = True
        s.view_settings.view_transform = "Standard"
        world = bpy.data.worlds.new("W")
        world.use_nodes = True
        world.node_tree.nodes["Background"].inputs["Color"].default_value = (0.7, 0.8, 0.95, 1)
        world.node_tree.nodes["Background"].inputs["Strength"].default_value = 0.9
        s.world = world
        sun = bpy.data.objects.new("Sun", bpy.data.lights.new("Sun", "SUN"))
        sun.data.energy = 3.0
        sun.data.angle = math.radians(8)
        sun.rotation_euler = (math.radians(45), math.radians(10), math.radians(-30))
        s.collection.objects.link(sun)
        g = bpy.data.meshes.new("Ground")
        g.from_pydata([(-500, -500, -0.01), (500, -500, -0.01), (500, 500, -0.01), (-500, 500, -0.01)], [], [(0, 1, 2, 3)])
        ground = bpy.data.objects.new("Ground", g)
        ground.is_shadow_catcher = True
        s.collection.objects.link(ground)
        cam = bpy.data.objects.new("Cam", bpy.data.cameras.new("Cam"))
        s.collection.objects.link(cam)
        s.camera = cam
        self.scene, self.cam = s, cam
        self.fixed = {sun, ground, cam}

    def render(self, objs, path, direction=(0.85, -1.3, 0.85)):
        vis = set(objs)
        for o in self.scene.objects:
            if o not in self.fixed:
                o.hide_render = o not in vis
        corners = [o.matrix_world @ Vector(c) for o in objs for c in o.bound_box]
        lo = Vector([min(c[i] for c in corners) for i in range(3)])
        hi = Vector([max(c[i] for c in corners) for i in range(3)])
        center = (lo + hi) / 2
        d = Vector(direction).normalized()
        rot = (-d).to_track_quat("-Z", "Y")
        inv = rot.to_matrix().inverted()
        ext = max(max(abs((inv @ (c - center)).x), abs((inv @ (c - center)).y)) for c in corners)
        self.cam.rotation_euler = rot.to_euler()
        self.cam.data.type = "ORTHO"
        self.cam.data.ortho_scale = ext * 2 * 1.12
        self.cam.location = center + d * (ext * 4 + 50)
        self.cam.data.clip_end = 1000
        os.makedirs(os.path.dirname(path), exist_ok=True)
        self.scene.render.filepath = path
        bpy.ops.render.render(write_still=True)


def contact_sheet(entries, path, title, cols=4, cell=300):
    from PIL import Image, ImageDraw, ImageFont
    rows = math.ceil(len(entries) / cols)
    lh, head = 40, 46
    sheet = Image.new("RGB", (cols * cell, head + rows * (cell + lh)), (28, 30, 40))
    d = ImageDraw.Draw(sheet)
    try:
        font = ImageFont.truetype("DejaVuSans.ttf", 15)
        small = ImageFont.truetype("DejaVuSans.ttf", 12)
        big = ImageFont.truetype("DejaVuSans-Bold.ttf", 22)
    except OSError:
        font = small = big = ImageFont.load_default()
    d.text((12, 12), title, fill=(240, 236, 220), font=big)
    for i, (png, label, sub) in enumerate(entries):
        x, y = (i % cols) * cell, head + (i // cols) * (cell + lh)
        d.rectangle([x + 4, y + 4, x + cell - 4, y + cell - 4], fill=(196, 214, 230))
        if os.path.exists(png):
            im = Image.open(png).convert("RGBA")
            im.thumbnail((cell - 10, cell - 10), Image.LANCZOS)
            sheet.paste(im, (x + (cell - im.width) // 2, y + (cell - im.height) // 2), im)
        d.text((x + 8, y + cell + 2), label, fill=(240, 238, 226), font=font)
        d.text((x + 8, y + cell + 21), sub, fill=(160, 170, 190), font=small)
    sheet.save(path)


# ------------------------------------------------------------------ main

def main():
    args = parse()
    bpy.ops.wm.read_factory_settings(use_empty=True)
    scene = bpy.context.scene
    scene.unit_settings.system = "NONE"
    for mod in MODULES:
        importlib.import_module(mod)
    only = {x for x in args.only.split(",") if x}
    todo = [r for r in K.REGISTRY if not only or r[0] in only or r[1] in only]
    renderer = None if args.no_render else Renderer(scene, args.samples)

    cat_path = os.path.join(OUT_MESH, "catalog.json")
    built = {}

    sheets = {}
    for name, category, note, fn in todo:
        col = bpy.data.collections.new(name)
        scene.collection.children.link(col)
        model = K.Model(name, category, note)
        fn(model)
        objs = build_model(model, col)
        export_fbx(objs, os.path.join(OUT_MESH, category, name + ".fbx"))
        rec = record(model, objs)
        built[name] = rec
        print(f"{name:<22} {len(objs):>3} pieces {rec['tris']:>6} tris")
        if renderer:
            png = os.path.join(OUT_RENDER, category, name + ".png")
            hide = set(model.extra.get("render_hide", ()))  # e.g. armour shown only in some phases
            renderer.render([o for o in objs if o.name not in hide] or objs, png)
            if hide:
                renderer.render(objs, os.path.join(OUT_RENDER, category, name + "_All.png"))
            sheets.setdefault(category, []).append((png, name, f"{len(objs)} pieces, {rec['tris']} tris"))
        # remove this model's objects so the next model's piece names stay unique
        # (Blender would otherwise rename a second "Eyes" to "Eyes.001" in the FBX)
        for o in objs:
            me = o.data
            bpy.data.objects.remove(o)
            bpy.data.meshes.remove(me)
        bpy.data.collections.remove(col)

    os.makedirs(OUT_MESH, exist_ok=True)
    # Merge this run's models into the shared catalog under a lock, so builds of
    # different categories can run at the same time without losing entries.
    with open(cat_path + ".lock", "w") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        catalog = {}
        if os.path.exists(cat_path):
            with open(cat_path) as f:
                catalog = {m["name"]: m for m in json.load(f)}
        catalog.update(built)
        known = {r[0] for r in K.REGISTRY}
        catalog = {k: v for k, v in catalog.items() if k in known}  # drop removed models
        tmp = cat_path + ".tmp"
        with open(tmp, "w") as f:
            json.dump([catalog[k] for k in sorted(catalog)], f, indent=1)
        os.replace(tmp, cat_path)
        fcntl.flock(lock, fcntl.LOCK_UN)
    for category, entries in sheets.items():
        contact_sheet(entries, os.path.join(OUT_RENDER, f"Sheet_{category}.png"), f"SWARM - {category}")


if __name__ == "__main__":
    main()
