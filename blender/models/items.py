"""Pickups (XP gem, chest, floor pickups) and weapon projectiles.

Pickups stand on the ground (origin = ground centre); the first piece is the main body.
Projectiles are centred on their origin and fly toward -Y (Roblox -Z). Slot names are what
the game recolours:
  Crystal         Glow (gem body, recoloured per gem size from Theme.Fx.Gem) + Light (tiny Neon core)
  Shot_Orb        Core (Neon) + Shell (translucent) + Shard (Neon sparks, Spin)
  Shot_Knife      Blade (Metal) + Gold (guard, pommel) + Grip
  Shot_Bottle     Glass (translucent) + Liquid (Neon) + Cork
  Shot_Axe        Head (Metal) + Haft + Grip
  Shot_Boomerang  Wood + Inlay
  Shot_Stinger    Core (Neon) + Barbs + Carapace
"""

import math

from swarmkit import register
from style import P

from ._propkit import TAU, cap_of, loft, mesh, put, ring, sweep


def bar_solid(outline, x0, x1):
    """Extrude a (y, z) outline along X (lids, straps)."""
    k = len(outline)
    verts = [(x0, y, z) for y, z in outline] + [(x1, y, z) for y, z in outline]
    faces = [list(range(k)), list(range(2 * k - 1, k - 1, -1))] + [(i, (i + 1) % k, k + (i + 1) % k, k + i) for i in range(k)]
    return mesh(verts, faces)


# ------------------------------------------------------------------ XP gem

@register("Crystal", "Pickups", "XP gem: chunky cut gold gem, ~1.0 wide x 1.25 tall at scale 1 (Small gem), centred "
          "0.65 above the origin. Slots: Glow = body (recoloured per gem size), Light = tiny Neon table.")
def crystal(m):
    m.extra["palette"] = {"Glow": P("gold_300"), "Light": P("gold_200")}
    gem = m.piece("Gem", "Glow")
    loft(gem, [(0, 0, 0.02), ring(6, 0.5, 0.56), ring(6, 0.5, 0.72), ring(6, 0.3, 1.12)])
    core = m.piece("Core", "Light", "Neon")
    loft(core, [ring(6, 0.19, 1.1), ring(6, 0.19, 1.18)])


# ------------------------------------------------------------------ chest

@register("Chest", "Pickups", "Elite treasure chest 3 x 2 x 2.1: wooden body (Box), barrel lid (Lid, hinge at the back), "
          "iron straps, gold corners and lock. Front (lock) = -Y.")
def chest(m):
    m.extra["palette"] = {"Wood": P("wood_500"), "Lid": P("wood_400"), "Iron": P("steel_700"), "Gold": P("gold_500")}
    box = m.piece("Box", "Wood", shadow=True)
    box.box((2.8, 1.85, 1.25), loc=(0, 0, 0.66), bevel=0.08)
    box.box((2.9, 1.95, 0.16), loc=(0, 0, 0.09), bevel=0.04)  # foot rim
    lid = m.piece("Lid", "Lid", anim="Jaw", pivot=(0, 0.93, 1.28))
    arch = [(math.cos(math.radians(a)) * 0.93, 1.28 + math.sin(math.radians(a)) * 0.68) for a in range(0, 181, 30)]
    put(lid, bar_solid(arch, -1.42, 1.42), bevel=0.05)
    iron = m.piece("Straps", "Iron", "Metal")
    for x in (-0.82, 0.82):
        for y in (-0.94, 0.94):
            iron.box((0.26, 0.08, 1.15), loc=(x, y, 0.68), bevel=0.0)
        outer = [(math.cos(math.radians(a)) * 0.97, 1.28 + math.sin(math.radians(a)) * 0.72) for a in range(0, 181, 30)]
        inner = [(math.cos(math.radians(a)) * 0.9, 1.28 + math.sin(math.radians(a)) * 0.65) for a in range(0, 181, 30)]
        put(iron, bar_solid(outer + inner[::-1], x - 0.13, x + 0.13))
    gold = m.piece("Fittings", "Gold")
    for x in (-1.36, 1.36):
        for y in (-0.88, 0.88):
            gold.box((0.22, 0.22, 0.32), loc=(x, y, 0.3), bevel=0.0)
            gold.box((0.22, 0.22, 0.26), loc=(x, y, 1.14), bevel=0.0)
    gold.box((0.48, 0.12, 0.56), loc=(0, -0.96, 1.15), bevel=0.04)
    gold.box((0.22, 0.1, 0.34), loc=(0, -0.98, 1.5), bevel=0.02)


# ------------------------------------------------------------------ floor pickups

@register("Pickup_Chicken", "Pickups", "Roast drumstick (heals), ~2.4 long; centred on the origin axis so it spins in place.")
def chicken(m):
    from mathutils import Euler, Vector
    m.extra["palette"] = {"Meat": P("gold_600"), "Crisp": P("gold_700"), "Bone": P("ivory_100")}
    rot = Euler((0, math.radians(-22), math.radians(20))).to_matrix()
    off = Vector((0.15, 0, 0.9))

    def T(p):
        return tuple(rot @ Vector(p) + off)
    stations = [(-0.95, 0.24), (-0.75, 0.47), (-0.35, 0.58), (0.05, 0.5), (0.35, 0.3), (0.5, 0.14)]
    rings = [[T((x, math.cos(a) * r, math.sin(a) * r * 0.92)) for a in (i / 7 * TAU for i in range(7))] for x, r in stations]
    loft(m.piece("Meat", "Meat"), rings)
    cap_of(m.piece("Crisp", "Crisp"), [p for r_ in rings for p in r_], plane_co=T((0, 0, 0.3)),
           plane_no=tuple(rot @ Vector((0.15, 0.1, 1))), grow=1.04, lift=0.0, centre=T((-0.3, 0, 0)))
    bone = m.piece("Bone", "Bone")
    bone.limb(T((0.4, 0, 0)), T((1.15, 0, 0)), 0.11, 0.09, seg=6)
    bone.ico(0.16, loc=T((1.22, 0.11, 0.02)), subdiv=1)
    bone.ico(0.16, loc=T((1.22, -0.11, -0.02)), subdiv=1)


@register("Pickup_Magnet", "Pickups", "Crimson horseshoe magnet with steel tips, ~1.7 x 2.0 (stands upright).")
def magnet(m):
    m.extra["palette"] = {"Body": P("crimson_500"), "Metal": P("steel_300")}
    rc, cz, hw, hd = 0.58, 0.82, 0.24, 0.27
    path = [(-rc, 1.55)] + [(math.cos(math.radians(a)) * rc, cz + math.sin(math.radians(a)) * rc)
                            for a in range(180, 361, 20)] + [(rc, 1.55)]
    rings = []
    for i, (px, pz) in enumerate(path):
        ax, az = path[max(i - 1, 0)]
        bx, bz = path[min(i + 1, len(path) - 1)]
        L = math.hypot(bx - ax, bz - az)
        nx, nz = -(bz - az) / L, (bx - ax) / L
        rings.append([(px + nx * u, s, pz + nz * u) for s, u in ((-hd, -hw), (hd, -hw), (hd, hw), (-hd, hw))])
    loft(m.piece("Body", "Body"), rings)
    tips = m.piece("Tips", "Metal", "Metal")
    for x in (-rc, rc):
        tips.box((hw * 2 + 0.04, hd * 2 + 0.04, 0.42), loc=(x, 0, 1.74), bevel=0.05)


@register("Pickup_Bomb", "Pickups", "Black iron bomb with a fuse and a tiny spark, ~1.7 x 2.5.")
def bomb(m):
    m.extra["palette"] = {"Body": P("slate_900"), "Cap": P("steel_500"), "Fuse": P("dirt_300"), "Spark": P("amber_300")}
    m.piece("Body", "Body", "Metal").ico(0.82, loc=(0, 0, 0.84), subdiv=2)
    cap = m.piece("Cap", "Cap", "Metal")
    loft(cap, [ring(8, 0.3, 1.5), ring(8, 0.3, 1.72), ring(8, 0.36, 1.78), ring(8, 0.36, 1.86)])
    fuse = m.piece("Fuse", "Fuse")
    fuse.chain([(0, 0, 1.8), (0.08, 0, 2.08), (0.26, 0.04, 2.28), (0.44, 0.06, 2.34)], [0.065, 0.06, 0.055, 0.05], seg=5)
    spark = m.piece("Spark", "Spark", "Neon")
    for d in ((1, 0, 0), (0, 1, 0), (0, 0, 1)):
        spark.box((0.32 if d[0] else 0.07, 0.32 if d[1] else 0.07, 0.32 if d[2] else 0.07), loc=(0.48, 0.06, 2.38),
                  rot=(30, 20, 45), bevel=0.0)


# ------------------------------------------------------------------ projectiles

@register("Shot_Orb", "Projectiles", "Arcane orb (~1.9 with sparks): Neon core in a translucent slate shell with orbiting "
          "sparks. Recoloured for Twin Orbs (gold core).")
def shot_orb(m):
    m.extra["palette"] = {"Core": P("fx_arcane"), "Shell": P("slate_400"), "Shard": P("fx_arcane")}
    m.piece("Core", "Core", "Neon").ico(0.36, subdiv=1)
    m.piece("Shell", "Shell", transparency=0.55).ico(0.7, subdiv=2)
    sh = m.piece("Shards", "Shard", "Neon", anim="Spin", pivot=(0, 0, 0))
    for k in range(3):
        a = k / 3 * TAU
        x, y = math.cos(a) * 0.86, math.sin(a) * 0.86
        loft(sh, [(x, y, 0.13), ring(4, 0.08, 0, cx=x, cy=y), (x, y, -0.13)])


def blade_solid(piece, stations, ridge):
    """Lozenge-section blade along Y: stations = [(y, half_width)], half width 0 = point."""
    rings = []
    for y, hw in stations:
        rings.append((0.0, y, 0.0) if hw <= 0 else [(-hw, y, 0.0), (0.0, y, -ridge), (hw, y, 0.0), (0.0, y, ridge)])
    loft(piece, rings)


@register("Shot_Knife", "Projectiles", "Throwing knife ~0.75 x 2.5: steel blade, gold guard, leather grip. Tip = -Y.")
def shot_knife(m):
    m.extra["palette"] = {"Blade": P("steel_300"), "Gold": P("gold_500"), "Grip": P("leather_600")}
    c = 0.3  # centres the length on the origin
    blade_solid(m.piece("Blade", "Blade", "Metal"), [(0.05 + c, 0.17), (-0.9 + c, 0.2), (-1.35 + c, 0.12), (-1.6 + c, 0)], 0.06)
    gold = m.piece("Gold", "Gold")
    gold.box((0.72, 0.16, 0.16), loc=(0, 0.1 + c, 0), bevel=0.04)
    gold.ico(0.12, loc=(0, 0.86 + c, 0), subdiv=1)
    m.piece("Grip", "Grip").limb((0, 0.16 + c, 0), (0, 0.78 + c, 0), 0.085, 0.075, seg=6)


@register("Shot_Bottle", "Projectiles", "Holy Water flask ~1.2 x 1.65: translucent glass, Neon liquid, cork. Upright.")
def shot_bottle(m):
    m.extra["palette"] = {"Glass": P("ivory_100"), "Liquid": P("fx_holy"), "Cork": P("wood_400")}
    n = 8
    loft(m.piece("Glass", "Glass", transparency=0.5),
         [(0, 0, -0.78), ring(n, 0.36, -0.72), ring(n, 0.56, -0.45), ring(n, 0.58, -0.15), ring(n, 0.44, 0.12),
          ring(n, 0.2, 0.3), ring(n, 0.17, 0.52), ring(n, 0.21, 0.56), ring(n, 0.21, 0.62)])
    loft(m.piece("Liquid", "Liquid", "Neon"), [(0, 0, -0.7), ring(n, 0.32, -0.65), ring(n, 0.5, -0.42), ring(n, 0.5, -0.1)])
    loft(m.piece("Cork", "Cork"), [ring(6, 0.15, 0.5), ring(6, 0.18, 0.86)])


@register("Shot_Axe", "Projectiles", "Throwing axe ~1.9 x 2.3: steel bearded head at the -Y end with the bit toward +X "
          "(Roblox -X), wooden haft along Y.")
def shot_axe(m):
    m.extra["palette"] = {"Head": P("steel_300"), "Haft": P("wood_500"), "Grip": P("leather_600")}
    c = 0.1
    head = m.piece("Head", "Head", "Metal")
    outline = [(0.16, -0.62 + c), (1.38, -0.05 + c), (1.47, -0.45 + c), (1.47, -0.85 + c), (1.36, -1.3 + c), (0.16, -1.02 + c)]
    top = [(x, y, 0.13 if x < 0.3 else 0.035) for x, y in outline]
    bot = [(x, y, -z) for x, y, z in top]
    k = len(outline)
    faces = [list(range(k)), list(range(2 * k - 1, k - 1, -1))] + [(i, (i + 1) % k, k + (i + 1) % k, k + i) for i in range(k)]
    put(head, mesh(top + bot, faces))
    head.box((0.42, 0.5, 0.3), loc=(0, -0.82 + c, 0), bevel=0.05)
    head.box((0.36, 0.38, 0.26), loc=(-0.36, -0.82 + c, 0), bevel=0.05, taper=(0.8, 0.8))
    m.piece("Haft", "Haft").limb((0, -1.12 + c, 0), (0, 1.05 + c, 0), 0.11, 0.1, seg=6)
    grip = m.piece("Grip", "Grip")
    for y in (0.55, 0.78):
        grip.limb((0, y + c - 0.08, 0), (0, y + c + 0.08, 0), 0.13, 0.13, seg=6)


@register("Shot_Boomerang", "Projectiles", "Boomerang ~2.6 x 0.95 lying flat, apex toward -Y, gold inlay.")
def shot_boomerang(m):
    m.extra["palette"] = {"Wood": P("wood_400"), "Inlay": P("gold_400")}
    path = [((i / 8 * 2 - 1) * 1.3, -0.45 + abs(i / 8 * 2 - 1) ** 1.3 * 0.85, 0.0) for i in range(9)]
    secs = []
    for i in range(9):
        t = abs(i / 8 * 2 - 1)
        w, h = 0.24 - 0.07 * t, 0.1 - 0.035 * t
        secs.append([(-w, 0), (0, h), (w, 0), (0, -h * 0.6)])
    sweep(m.piece("Body", "Wood"), path, secs)
    inlay = m.piece("Inlay", "Inlay")
    for i in (1, 7):
        x, y, _ = path[i]
        ang = math.degrees(math.atan2(path[i + 1][1] - path[i - 1][1], path[i + 1][0] - path[i - 1][0]))
        inlay.box((0.36, 0.2, 0.06), loc=(x, y, 0.075), rot=(0, 0, ang), bevel=0.0)
    loft(inlay, [ring(4, 0.15, 0.06, cy=-0.45), ring(4, 0.15, 0.125, cy=-0.45)])


@register("Shot_Stinger", "Projectiles", "Boss stinger (~2.5 across, flat): amber Neon core, crimson barbed pinwheel, "
          "dark carapace ring.")
def shot_stinger(m):
    m.extra["palette"] = {"Core": P("amber_500"), "Barbs": P("crimson_500"), "Carapace": P("crimson_800")}
    m.piece("Core", "Core", "Neon").ico(0.42, subdiv=1)
    barbs = m.piece("Barbs", "Barbs")
    for k in range(4):
        a = k / 4 * TAU
        pts = [(math.cos(a + b) * r, math.sin(a + b) * r, 0.0) for r, b in ((0.45, 0.0), (0.75, 0.12), (1.0, 0.3), (1.25, 0.55))]
        barbs.chain(pts, [0.22, 0.17, 0.11, 0.0], seg=4)
    car = m.piece("Carapace", "Carapace")
    loft(car, [ring(8, 0.62, -0.18), ring(8, 0.68, 0.0), ring(8, 0.62, 0.18), ring(8, 0.44, 0.22), ring(8, 0.44, -0.22)], loop=True)
