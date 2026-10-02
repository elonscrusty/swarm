"""More weapon projectiles (same rules as items.py): centred on the origin, flying toward -Y
(Roblox -Z), ~1-3 studs. Shot_Totem is the exception: it stands on the ground (origin = ground
centre). Slot names the game may recolour:
  Shot_Spear       Tip (Metal) + Shaft + Binding (gold ring, leather wrap)
  Shot_Bolt        Head (Metal) + Shaft + Fletch
  Shot_FrostShard  Ice + Ice2 + Glow (small Neon core)
  Shot_Fire        Flame (Neon) + Core (Neon) + Ember (Neon, Spin)
  Shot_Totem       Wood + Wood2 + Dark + Gold + Glow (Neon orb, light extra)
  Shot_Hook        Hook (Metal) + Chain (Metal)
"""

import math

from swarmkit import register
from style import P

from ._propkit import TAU, light_at, loft, mesh, prism_xz, put, ring, sweep
from .items import blade_solid


@register("Shot_Spear", "Projectiles", "Thrown spear ~3 long: leaf-shaped steel tip at -Y, wooden shaft, gold collar and "
          "leather grip wrap.")
def shot_spear(m):
    m.extra["palette"] = {"Tip": P("steel_300"), "Shaft": P("wood_500"), "Gold": P("gold_500"), "Wrap": P("leather_600")}
    blade_solid(m.piece("Tip", "Tip", "Metal"), [(-0.72, 0.1), (-0.95, 0.2), (-1.3, 0.16), (-1.52, 0.0)], 0.07)
    m.piece("Shaft", "Shaft").limb((0, -0.8, 0), (0, 1.5, 0), 0.075, 0.07, seg=6)
    gold = m.piece("Collar", "Gold")
    gold.limb((0, -0.86, 0), (0, -0.62, 0), 0.11, 0.1, seg=6)
    gold.limb((0, 1.38, 0), (0, 1.52, 0), 0.1, 0.09, seg=6)
    wrap = m.piece("Wrap", "Wrap")
    for y in (0.25, 0.45, 0.65):
        wrap.limb((0, y - 0.07, 0), (0, y + 0.07, 0), 0.1, 0.1, seg=6)


@register("Shot_Bolt", "Projectiles", "Crossbow bolt ~1.7 long: square steel head at -Y, dark wood shaft, three "
          "crimson fletches.")
def shot_bolt(m):
    m.extra["palette"] = {"Head": P("steel_300"), "Shaft": P("wood_600"), "Fletch": P("crimson_500")}
    head = m.piece("Head", "Head", "Metal")
    q = math.radians(45)
    # build along Y: rings in XZ planes
    rings = []
    for y, r in ((-0.45, 0.07), (-0.58, 0.16)):
        rings.append([(math.cos(q + i * TAU / 4) * r, y, math.sin(q + i * TAU / 4) * r) for i in range(4)])
    loft(head, rings + [(0, -0.88, 0)])
    m.piece("Shaft", "Shaft").limb((0, -0.5, 0), (0, 0.82, 0), 0.05, 0.05, seg=5)
    fl = m.piece("Fletch", "Fletch")
    for k in range(3):
        a = k * TAU / 3 + math.pi / 2
        c, s = math.cos(a), math.sin(a)
        prof = [(0.04, 0.82), (0.04, 0.36), (0.2, 0.5), (0.22, 0.86)]  # (radial, y)
        verts = []
        for side in (-0.015, 0.015):
            for r, y in prof:
                verts.append((c * r - s * side, y, s * r + c * side))
        n = len(prof)
        faces = [list(range(n)), list(range(2 * n - 1, n - 1, -1))] + [(i, (i + 1) % n, n + (i + 1) % n, n + i) for i in range(n)]
        put(fl, mesh(verts, faces))


@register("Shot_FrostShard", "Projectiles", "Ice shard ~1.6 long, point at -Y: pale slate faceted crystal with ivory "
          "splinters and a small Neon frost core.")
def shot_frostshard(m):
    m.extra["palette"] = {"Ice": P("slate_200"), "Ice2": P("ivory_100"), "Glow": P("fx_holy")}

    def bipyramid(piece, y0, y1, ymid, r, cx=0.0, cz=0.0, n=6, phase=0.0, twist=0.0):
        mid = [(cx + math.cos(phase + i * TAU / n) * r, ymid, cz + math.sin(phase + i * TAU / n) * r * 0.8) for i in range(n)]
        mid2 = [(cx + math.cos(phase + twist + i * TAU / n) * r * 0.85, ymid + (y1 - ymid) * 0.35,
                 cz + math.sin(phase + twist + i * TAU / n) * r * 0.7) for i in range(n)]
        loft(piece, [(cx, y0, cz), mid, mid2, (cx, y1, cz)])
    bipyramid(m.piece("Shard", "Ice"), -0.85, 0.75, -0.3, 0.3, phase=0.2, twist=0.3)
    s2 = m.piece("Splinters", "Ice2")
    bipyramid(s2, -0.35, 0.55, -0.05, 0.12, cx=0.24, cz=0.08, n=4, phase=0.5)
    bipyramid(s2, -0.2, 0.7, 0.1, 0.1, cx=-0.2, cz=-0.12, n=4, phase=0.1)
    m.piece("Core", "Glow", "Neon").ico(0.13, loc=(0, -0.3, 0), scale=(1, 1.8, 1), subdiv=0)


@register("Shot_Fire", "Projectiles", "Low-poly fire blob ~1.3 long for fire trails: a round flame head at -Y with "
          "licks streaming back toward +Y, bright core and two orbiting embers.")
def shot_fire(m):
    m.extra["palette"] = {"Flame": P("fx_fire"), "Core": P("lava_glow"), "Ember": P("gold_300")}
    fl = m.piece("Flame", "Flame", "Neon")

    def lick(piece, x, z, r, length, twist, lean):
        # built along +Z, then turned so +Z points to +Y (backwards)
        rings = [(x, z, -0.25 * r),
                 ring(5, r, r * 0.5, cx=x, cy=z),
                 ring(5, r * 0.6, length * 0.55, phase=math.radians(twist), cx=x + lean * 0.5, cy=z + lean * 0.3),
                 (x + lean, z + lean * 0.5, length)]
        loft(piece, rings, rot=(-90, 0, 0))
    fl.ico(0.42, loc=(0, -0.25, 0), subdiv=1, jitter=0.1, seed=3)
    lick(fl, 0.0, 0.0, 0.38, 1.05, 25, 0.05)
    lick(fl, 0.22, 0.12, 0.22, 0.8, 40, 0.12)
    lick(fl, -0.2, -0.1, 0.22, 0.75, -30, -0.1)
    core = m.piece("Core", "Core", "Neon")
    core.ico(0.24, loc=(0, -0.28, 0), subdiv=1)
    lick(core, 0.0, 0.0, 0.18, 0.6, 15, 0.02)
    em = m.piece("Embers", "Ember", "Neon", anim="Spin", pivot=(0, 0, 0))
    for x, y, z in ((0.5, -0.1, 0.15), (-0.45, 0.2, -0.2)):
        em.ico(0.07, loc=(x, y, z), subdiv=0)


@register("Shot_Totem", "Projectiles", "Healing totem ~3.1 tall standing on the ground (origin = ground centre): carved "
          "wooden post with a face and small wings, gold crown cradling a green-gold glowing orb. Light = orb.")
def shot_totem(m):
    m.extra["palette"] = {"Wood": P("wood_500"), "Wood2": P("wood_400"), "Dark": P("wood_900"), "Gold": P("gold_500"),
                          "Glow": P("fx_heal"), "Leaf": P("moss_400")}
    m.extra["light"] = light_at(0, 0, 2.75)
    m.extra["anchor"] = "ground centre"
    w = m.piece("Post", "Wood", shadow=True)
    loft(w, [ring(6, 0.38, -0.1), ring(6, 0.32, 0.3), ring(6, 0.28, 1.0)])
    loft(w, [(0, 0, -0.6), ring(6, 0.3, -0.05)])  # stake tip (below ground, hidden)
    w2 = m.piece("Carving", "Wood2", shadow=True)
    w2.box((0.66, 0.6, 0.85), loc=(0, 0, 1.4), bevel=0.08, taper=(1.1, 1.1))
    w.box((0.74, 0.22, 0.14), loc=(0, -0.3, 1.66), bevel=0.03)
    dark = m.piece("Face", "Dark")
    for x in (-0.15, 0.15):
        dark.box((0.13, 0.06, 0.1), loc=(x, -0.32, 1.52), bevel=0.0)
    dark.box((0.3, 0.06, 0.07), loc=(0, -0.32, 1.22), bevel=0.0)
    for sx in (-1, 1):
        prism_xz(w2, [(sx * x, z) for x, z in ((0.3, 1.4), (0.85, 1.75), (0.9, 1.95), (0.6, 1.85), (0.3, 1.75))][::sx],
                 -0.08, 0.08)
    loft(w, [ring(6, 0.3, 1.82), ring(6, 0.25, 2.25)])
    gold = m.piece("Gold", "Gold")
    loft(gold, [ring(6, 0.32, 2.2), ring(6, 0.32, 2.32), ring(6, 0.22, 2.36)])
    for k in range(4):
        a = k * TAU / 4 + TAU / 8
        gold.limb((math.cos(a) * 0.22, math.sin(a) * 0.22, 2.3), (math.cos(a) * 0.32, math.sin(a) * 0.32, 2.95), 0.05, 0.03, seg=3)
    leaf = m.piece("Leaves", "Leaf")
    for k in range(3):
        a = k * TAU / 3
        leaf.limb((math.cos(a) * 0.2, math.sin(a) * 0.2, 2.3), (math.cos(a) * 0.55, math.sin(a) * 0.55, 2.45), 0.09, 0.0, seg=3)
    m.piece("Orb", "Glow", "Neon").ico(0.3, loc=(0, 0, 2.75), subdiv=1)


@register("Shot_Hook", "Projectiles", "Chain hook head ~1.5 long: barbed steel hook at -Y curling back, eye ring and "
          "two chain links trailing toward +Y.")
def shot_hook(m):
    m.extra["palette"] = {"Hook": P("steel_400"), "Chain": P("steel_600")}
    hook = m.piece("Hook", "Hook", "Metal")
    # shank along Y, then a curve (in the XY plane) around to a point aimed back at +Y
    path = [(0, 0.25, 0), (0, -0.3, 0), (0, -0.62, 0)]
    for k in range(1, 7):
        a = math.pi * k / 6
        path.append((0.32 - math.cos(a) * 0.32, -0.62 - math.sin(a) * 0.32, 0))
    secs = []
    for i in range(len(path)):
        t = max(0.0, (i - 2) / (len(path) - 3))
        r = 0.1 * (1 - 0.65 * t)
        secs.append([(math.cos(a) * r, math.sin(a) * r) for a in (0, TAU / 4, TAU / 2, 3 * TAU / 4)][::-1])
    sweep(hook, path, secs)
    tip = path[-1]
    hook.spike(0.06, 0.28, seg=4, base=tip, direction=(-0.15, 1, 0))
    hook.spike(0.05, 0.2, seg=3, base=(0.62, -0.55, 0), direction=(-1, 0.6, 0))  # barb
    # eye ring at the back of the shank
    eye = [(math.sin(a) * 0.14, 0.38 + math.cos(a) * 0.14, 0) for a in (i * TAU / 8 for i in range(8))]
    for a, b in zip(eye, eye[1:] + eye[:1]):
        hook.limb(a, b, 0.04, 0.04, seg=4)
    ch = m.piece("Chain", "Chain", "Metal")
    for k, y in enumerate((0.68, 0.98)):
        horiz = k % 2 == 0
        pts = [((math.sin(a) * 0.09 if horiz else 0.0), y + math.cos(a) * 0.17, (0.0 if horiz else math.sin(a) * 0.09))
               for a in (i * TAU / 8 for i in range(8))]
        for a, b in zip(pts, pts[1:] + pts[:1]):
            ch.limb(a, b, 0.035, 0.035, seg=4)
