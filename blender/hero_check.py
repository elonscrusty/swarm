"""Preview and readability checks for the heroes and hats (blender/models/heroes.py, hats.py).

    python3 blender/hero_check.py                     everything below
    python3 blender/hero_check.py --views             turnaround of each hero (front, back, side, top)
    python3 blender/hero_check.py --topdown           each hero from the gameplay angle at 120 px
    python3 blender/hero_check.py --gameplay          heroes among the swarm from the gameplay camera
    python3 blender/hero_check.py --skins             every skin (+ Gold Trim) of every hero
    python3 blender/hero_check.py --hats              every hat on a bare-headed hero
    python3 blender/hero_check.py --only Knight,Mage  limit the heroes

Builds models in memory only: never touches meshes/ or meshes/catalog.json. Skins are read
from src/shared/CharacterData.lua (Palette.<name> or Color3.fromRGB values) and resolved like
CharacterData.MeshPalette / ResolveLook do in game, so the sheet shows what players will see.

Outputs: renders/Heroes/Views_<Hero>.png, renders/Heroes/TopDown.png, renders/Heroes/Gameplay.png
(+ Gameplay_small.png), renders/Sheet_HeroSkins.png, renders/Hats/OnHeads.png.
"""

import argparse
import math
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
sys.path.insert(0, HERE)

import bpy  # noqa: E402
from mathutils import Vector  # noqa: E402

import build as B  # noqa: E402
import swarmkit as K  # noqa: E402
from style import P  # noqa: E402

OUT = os.path.join(ROOT, "renders")
HEROES = ["Knight", "Mage", "Rogue", "Priest"]
FACE = ("Head", "Eyes")


def parse():
    argv = sys.argv[sys.argv.index("--") + 1:] if "--" in sys.argv else sys.argv[1:]
    ap = argparse.ArgumentParser()
    for flag in ("views", "topdown", "gameplay", "skins", "hats"):
        ap.add_argument("--" + flag, action="store_true")
    ap.add_argument("--only", default="")
    ap.add_argument("--samples", type=int, default=16)
    a = ap.parse_args(argv)
    if not any(getattr(a, f) for f in ("views", "topdown", "gameplay", "skins", "hats")):
        a.views = a.topdown = a.gameplay = a.skins = a.hats = True
    return a


# ------------------------------------------------------------------ CharacterData (Lua) → slots

def lua_colors(text):
    out = {}
    for key, val in re.findall(r"(\w+)\s*=\s*(Palette\.\w+|Color3\.fromRGB\([^)]*\))", text):
        if val.startswith("Palette."):
            out[key] = P(val[8:])
        else:
            out[key] = tuple(int(x) / 255 for x in re.findall(r"\d+", val)[:3])
    return out


def block_after(text, start):
    """Text of the {...} block that opens at or after `start`."""
    i = text.index("{", start)
    depth = 0
    for j in range(i, len(text)):
        depth += {"{": 1, "}": -1}.get(text[j], 0)
        if depth == 0:
            return text[i:j + 1]
    return text[i:]


def read_character_data():
    with open(os.path.join(ROOT, "src", "shared", "CharacterData.lua")) as f:
        src = f.read()
    chars, skins = {}, {}
    for cid in HEROES:
        m = re.search(r"\n\t%s = \{" % cid, src)
        body = block_after(src, m.start())
        cols = block_after(body, body.index("Colors"))
        hat = re.search(r'\n\t\tHat = "(\w+)"', body)
        chars[cid] = {"Colors": lua_colors(cols), "Hat": hat.group(1) if hat else None}
    sk = src.index("CharacterData.Skins = {")
    skin_src = block_after(src, sk)
    for m in re.finditer(r"\n\t(\w+) = \{", skin_src):
        body = block_after(skin_src, m.start())
        cid = re.search(r'Character = "([^"]+)"', body).group(1)
        cols = block_after(body, body.index("Colors"))
        hat = re.search(r'\n\t\tHat = "(\w+)"', body)
        name = re.search(r'Name = "([^"]+)"', body).group(1)
        skins[m.group(1)] = {"Character": cid, "Name": name, "Colors": lua_colors(cols),
                             "Hat": hat.group(1) if hat else None, "GoldTrim": "GoldTrim = true" in body}
    return chars, skins


def shade(c):
    return (c[0] * 0.7, c[1] * 0.7, min(1.0, c[2] * 0.74))


def skin_palette(skin):
    """Mirror of CharacterData.MeshPalette: the skin's slots plus derived shades."""
    pal = dict(skin["Colors"])
    if "Metal" in pal and "MetalDark" not in pal:
        pal["MetalDark"] = shade(pal["Metal"])
    if "Accent" in pal and "AccentDark" not in pal:
        pal["AccentDark"] = shade(pal["Accent"])
    return pal


# ------------------------------------------------------------------ building

def registry():
    import models.hats  # noqa: F401
    import models.heroes  # noqa: F401
    return {r[0]: r for r in K.REGISTRY}


def make(reg, name, palette=None, hat=None):
    """Build a model in memory. hat = a Hat_ shape replacing the hero's headgear."""
    entry = reg[name]
    model = K.Model(name, entry[1], entry[2])
    entry[3](model)
    if hat:
        from models.hats import HATS
        from models.heroes import HAT_ORIGIN
        model.pieces = [p for p in model.pieces
                        if not (p.bone == "Head" and p.name not in FACE and not p.name.startswith("Face"))]
        HATS[hat](model, HAT_ORIGIN, "Head")
    if palette:
        model.extra.setdefault("palette", {}).update(palette)
    col = bpy.data.collections.new(name)
    bpy.context.scene.collection.children.link(col)
    objs = B.build_model(model, col)
    bpy.context.view_layer.update()  # world matrices / bounds before the first render
    return model, objs, col


def drop(objs, col):
    for o in objs:
        me = o.data
        bpy.data.objects.remove(o)
        bpy.data.meshes.remove(me)
    bpy.data.collections.remove(col)


def move(objs, offset, yaw=0.0):
    from mathutils import Matrix
    m = Matrix.Translation(Vector(offset)) @ Matrix.Rotation(math.radians(yaw), 4, "Z")
    for o in objs:
        o.matrix_world = m @ o.matrix_world


def tris(model):
    return sum(p.tris for p in model.pieces)


# ------------------------------------------------------------------ renders

def render_set(renderer, objs, path, direction, size=420, margin=1.12):
    s = renderer.scene
    s.render.resolution_x = s.render.resolution_y = size
    renderer.render(objs, path, direction=direction)


def views(reg, renderer, names):
    from PIL import Image, ImageDraw
    dirs = {"front": (0.85, -1.3, 0.85), "back": (-0.7, 1.3, 0.7), "side": (1.4, -0.15, 0.55),
            "top": (0.0, 0.62, 0.99)}
    tmp = os.path.join(OUT, "Heroes", "_tmp")
    for name in names:
        model, objs, col = make(reg, name)
        cells = []
        for key, d in dirs.items():
            path = os.path.join(tmp, f"{name}_{key}.png")
            render_set(renderer, objs, path, d)
            cells.append(path)
        sheet = Image.new("RGB", (4 * 420, 460), (196, 214, 230))
        for i, c in enumerate(cells):
            im = Image.open(c).convert("RGBA")
            sheet.paste(im, (i * 420, 0), im)
        ImageDraw.Draw(sheet).text((10, 432), f"{name}: {len(model.pieces)} pieces, {tris(model)} tris  "
                                               f"(front / back / side / top)", fill=(30, 30, 40))
        sheet.save(os.path.join(OUT, "Heroes", f"Views_{name}.png"))
        print(name, len(model.pieces), "pieces", tris(model), "tris")
        for p in sorted(model.pieces, key=lambda q: -q.tris):
            print(f"   {p.name:<22} {p.slot:<10} {p.tris:>5}")
        drop(objs, col)


def topdown(reg, renderer, names):
    """Each hero at 120 px from the gameplay pitch (58 deg), facing away / toward / sideways."""
    from PIL import Image, ImageDraw
    tmp = os.path.join(OUT, "Heroes", "_tmp")
    pitch = math.radians(58)
    facings = [("away", 0), ("toward", 180), ("left", 90), ("right", -90)]
    sheet = Image.new("RGB", (len(facings) * 130 + 10, len(names) * 130 + 30), (82, 118, 61))
    d = ImageDraw.Draw(sheet)
    for r, name in enumerate(names):
        model, objs, col = make(reg, name)
        for c, (label, yaw) in enumerate(facings):
            a = math.radians(yaw)
            # camera sits at +Y (Roblox +Z) above the hero; turning the hero = turning the camera back
            direction = (math.sin(a) * math.cos(pitch), math.cos(a) * math.cos(pitch), math.sin(pitch))
            path = os.path.join(tmp, f"{name}_td_{label}.png")
            render_set(renderer, objs, path, direction, size=120)
            im = Image.open(path).convert("RGBA")
            sheet.paste(im, (10 + c * 130, 25 + r * 130), im)
            if r == 0:
                d.text((12 + c * 130, 6), label, fill=(240, 236, 220))
        drop(objs, col)
    sheet.save(os.path.join(OUT, "Heroes", "TopDown.png"))


def ground_scene(scene):
    """Moss ground (no shadow catcher) for the gameplay view; returns the objects to clean up."""
    made = []

    def disc(name, r, color, z, at=(0, 0)):
        me = bpy.data.meshes.new(name)
        n = 24
        verts = [(at[0] + math.cos(i / n * math.tau) * r, at[1] + math.sin(i / n * math.tau) * r, z) for i in range(n)]
        me.from_pydata(verts, [], [list(range(n))])
        me.materials.append(B.preview_material(B.srgb_to_linear(color), False))
        ob = bpy.data.objects.new(name, me)
        scene.collection.objects.link(ob)
        made.append(ob)

    disc("G0", 400, P("moss_500"), 0.0)
    disc("G1", 9, P("moss_600"), 0.004, (-14, 10))
    disc("G2", 7, P("moss_400"), 0.004, (16, -8))
    disc("G3", 6, P("dirt_500"), 0.005, (2, 14))
    return made


def gameplay(reg, renderer, names):
    """Heroes among the swarm from the in-game camera: pitch 58, distance 64, FOV 50, 16:9."""
    scene = renderer.scene
    made = ground_scene(scene)
    for o in scene.objects:
        if o.name == "Ground":
            o.hide_render = True
    placed = []
    layout = [(-11, 2, 0), (-3.5, -1, 180), (4, 2, 90), (11.5, -1, -40)]
    for (x, y, yaw), name in zip(layout, names):
        model, objs, col = make(reg, name)
        move(objs, (x, y, 0), yaw)
        placed.append((objs, col))
    # the swarm: real enemy models when models/enemies.py builds, stand-ins otherwise
    try:
        import models.enemies  # noqa: F401
        reg.update({r[0]: r for r in K.REGISTRY})
        crowd = [("Mite", (-7, 7), 20), ("Mite", (-14, -5), -30), ("Mite", (0, 8), 160), ("Mite", (7, -6), 200),
                 ("Mite", (15, 6), 90), ("Mite", (-2, -8), 10), ("Wasp", (9, 9), 45), ("BeetleWarrior", (-17, 4), 60),
                 ("PhaseMoth", (19, -3), 0), ("RhinoBeetle", (2, 15), 200), ("BombTick", (-9, -8), 120)]
        for name, (x, y), yaw in crowd:
            if name in reg:
                model, objs, col = make(reg, name)
                lift = 2.5 if name == "Wasp" else (1.0 if name == "PhaseMoth" else 0.0)
                move(objs, (x, y, lift), yaw)
                placed.append((objs, col))
    except Exception as e:  # noqa: BLE001
        print("enemies not available:", e)
    for o in scene.objects:
        if o.type == "MESH" and o.name not in ("Ground",):
            o.hide_render = False
    cam = renderer.cam
    pitch, dist = math.radians(58), 64
    focus = Vector((0, 2, 2.5))
    cam.data.type = "PERSP"
    cam.data.sensor_fit = "VERTICAL"
    cam.data.angle = math.radians(50)
    cam.location = focus + Vector((0, math.cos(pitch), math.sin(pitch))) * dist
    cam.rotation_euler = (focus - cam.location).to_track_quat("-Z", "Y").to_euler()
    cam.data.clip_end = 2000
    scene.render.resolution_x, scene.render.resolution_y = 1280, 720
    scene.render.film_transparent = False
    path = os.path.join(OUT, "Heroes", "Gameplay.png")
    scene.render.filepath = path
    bpy.ops.render.render(write_still=True)
    from PIL import Image
    Image.open(path).resize((640, 360), Image.LANCZOS).save(os.path.join(OUT, "Heroes", "Gameplay_small.png"))
    scene.render.film_transparent = True
    for objs, col in placed:
        drop(objs, col)
    for o in made:
        me = o.data
        bpy.data.objects.remove(o)
        bpy.data.meshes.remove(me)
    for o in scene.objects:
        if o.name == "Ground":
            o.hide_render = False


def skins(reg, renderer, names):
    chars, skin_defs = read_character_data()
    entries = []
    tmp = os.path.join(OUT, "Heroes", "_tmp")
    for cid in names:
        order = [("Default", None)] + [(k, v) for k, v in skin_defs.items() if v["Character"] == cid] + \
                [(k, v) for k, v in skin_defs.items() if v["Character"] == "*"]
        for sid, skin in order:
            pal, hat = None, None
            if skin:
                pal = skin_palette(skin)
                if skin.get("Hat") and skin["Hat"] != chars[cid]["Hat"]:
                    hat = skin["Hat"]
            model, objs, col = make(reg, cid, pal, hat)
            path = os.path.join(tmp, f"skin_{cid}_{sid}.png")
            render_set(renderer, objs, path, (0.85, -1.3, 0.85), size=300)
            entries.append((path, f"{cid}: {skin['Name'] if skin else 'Default'}",
                            f"{'hat ' + hat if hat else 'own headgear'}, {tris(model)} tris"))
            drop(objs, col)
    B.contact_sheet(entries, os.path.join(OUT, "Sheet_HeroSkins.png"), "SWARM - hero skins", cols=5, cell=240)


def hats(reg, renderer):
    """Every hat on a bare-headed hero (cycling through the four bodies)."""
    from models.hats import HATS
    entries = []
    tmp = os.path.join(OUT, "Hats", "_tmp")
    for i, shape in enumerate(HATS):
        cid = HEROES[i % 4]
        model, objs, col = make(reg, cid, None, shape)
        path = os.path.join(tmp, f"on_{shape}.png")
        render_set(renderer, objs, path, (0.85, -1.3, 0.85), size=300)
        hat_tris = sum(p.tris for p in model.pieces if p.bone == "Head" and p.name not in FACE
                       and not p.name.startswith("Face"))
        entries.append((path, f"Hat_{shape}", f"on {cid}, hat {hat_tris} tris"))
        drop(objs, col)
    B.contact_sheet(entries, os.path.join(OUT, "Hats", "OnHeads.png"), "SWARM - hats on the standard head",
                    cols=4, cell=260)


def main():
    a = parse()
    bpy.ops.wm.read_factory_settings(use_empty=True)
    scene = bpy.context.scene
    scene.unit_settings.system = "NONE"
    reg = registry()
    names = [n for n in HEROES if not a.only or n in a.only.split(",")]
    renderer = B.Renderer(scene, a.samples)
    os.makedirs(os.path.join(OUT, "Heroes", "_tmp"), exist_ok=True)
    os.makedirs(os.path.join(OUT, "Hats", "_tmp"), exist_ok=True)
    if a.views:
        views(reg, renderer, names)
    if a.topdown:
        topdown(reg, renderer, names)
    if a.skins:
        skins(reg, renderer, names)
    if a.hats:
        hats(reg, renderer)
    if a.gameplay:
        gameplay(reg, renderer, names)


if __name__ == "__main__":
    main()
