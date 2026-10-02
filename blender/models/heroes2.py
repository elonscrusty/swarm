"""Four more heroes: Ranger, Alchemist, Engineer, Necromancer (heroic low-poly fantasy).

Same rig contract as models/heroes.py (read its docstring): feet at z = 0, hips z = 2.0
(x +-0.5), shoulders z = 3.95 (x +-1.2), neck z = 4.45, the standard bare head 1.45 x 1.35 x
1.4 centred at z = 5.15, six bone pieces (Torso, Head, LeftArm, RightArm, LeftLeg, RightLeg)
named like their bone, every other piece names the bone it is welded to. Head-bone pieces
called "Head", "Eyes" or "Face*" are the face and stay when a skin swaps the headgear for a
hat; every other Head-bone piece is headgear.

Skin slots as in heroes.py: Hat / HatAccent, Metal / MetalDark, Cloth / Cloth2,
Accent / AccentDark, Gold. Fixed slots: Skin, Hair, Dark, Leather, Wood, Blade, Glow (Neon,
tiny cores only), plus Bone (ivory bone), Glass (translucent flask glass), Lens (goggle /
lamp glass) and Glow2 (a second potion colour).

Each hero also has an ability prop (category "Projectiles" or "Abilities"), registered at
the bottom of this file.
"""

import math

from mathutils import Vector

from models.hats import HEAD_Z, arc_shell, at, band, block, lathe, mark, revolve, slab, sweep, turn
from models.heroes import (HAT_ORIGIN, SIDES, boots, brows, gauntlet_fist, hair_cap, hair_short, head, legs,
                           palette, rig, turned)
from models.enemies import ellipsoid
from style import P, mix
from swarmkit import register


# ---------------------------------------------------------------------------------- small kit

def pal(**slots):
    """heroes.palette() that also takes ready colour tuples (palette mixes)."""
    mixed = {k: v for k, v in slots.items() if not isinstance(v, str)}
    out = palette(**{k: v for k, v in slots.items() if isinstance(v, str)})
    out.update(mixed)
    return out


def gear(p, loc, rot, r_out, r_in, teeth=6, depth=0.12, bevel=0.0):
    """Toothed gear wheel (a slab facing Y before `rot`)."""
    pts = []
    n = teeth
    for i in range(n):
        a0 = i / n * math.tau
        w = math.tau / n
        for frac, r in ((0.0, r_in), (0.12, r_out), (0.45, r_out), (0.57, r_in)):
            a = a0 + w * frac
            pts.append((math.cos(a) * r, math.sin(a) * r))
    slab(p, pts, depth, loc=loc, rot=rot, bevel=bevel)


def hand(m, bone, x, slot="Skin", z=2.2, size=(0.44, 0.48, 0.46)):
    h = m.piece(bone + "Hand", slot, bone=bone)
    block(h, size, loc=(x, -0.08, z), bevel=0.12)
    return h


def sleeve(m, bone, s, slot, x=1.38, r=(0.5, 0.44, 0.36, 0.34)):
    p = m.piece(bone, slot, bone=bone)
    k = mark(p)
    lathe(p, [(r[0], 2.42), (r[1], 2.75), (r[2], 3.4), (r[3], 3.95), (0.0, 4.12)], seg=8, phase=22.5,
          loc=(s * x, 0, 0))
    turn(p, k, (s * x, 0, 3.95), (0, -s * 6, 0))
    return p


def skull(p, c, r=0.3, yaw=0.0):
    """Small skull (a bone piece): cranium + jaw block; sockets are added by the caller."""
    p.ico(r, loc=c, scale=(1.0, 1.05, 0.95), subdiv=1)
    d = turned((0, -1, 0), (0, 0, yaw))
    block(p, (r * 1.15, r * 0.8, r * 0.7), loc=Vector(c) + d * r * 0.42 + Vector((0, 0, -r * 0.62)),
          rot=(0, 0, yaw), bevel=r * 0.15)


# ---------------------------------------------------------------------------------- Ranger

def hood_ranger(m, o, bone):
    """Deep forester's hood: rounded crown drawn forward into a peak over the brow, sides
    falling onto the shoulders (sits inside the capelet)."""
    hood = m.piece("Hood", "Hat", bone=bone, shadow=True)

    def lean(co):
        h = max(co.z, 0.0)
        return Vector((co.x, co.y + h * 0.3, co.z))

    lathe(hood, [(1.0, -0.14), (1.01, 0.1), (0.93, 0.32), (0.72, 0.5), (0.38, 0.6), (0.0, 0.63)], seg=8,
          phase=22.5, loc=o, deform=lean)
    arc_shell(hood, [(1.0, -0.02, 0.0), (1.02, -0.6, 0.04), (1.08, -1.1, 0.08), (1.16, -1.42, 0.12)],
              50, 310, seg=8, thick=0.13, loc=o)
    arc_shell(hood, [(1.0, 0.04, 0.0), (1.03, -0.32, -0.08)], -56, 56, seg=4, thick=0.14, loc=o)
    # the forester's peak: the crown drawn up and back into a short stiff point
    sweep(hood, [(0, 0.1, 0.5), (0, 0.42, 0.62), (0, 0.72, 0.78), (0, 0.92, 1.0)], [0.36, 0.26, 0.14, 0.0],
          seg=6, loc=o, sx=1.25, up=(1, 0, 0))
    shade = m.piece("HoodShade", "Dark", bone=bone)
    arc_shell(shade, [(0.84, -0.1, 0.0), (0.84, -1.42, 0.04)], 40, 320, seg=8, thick=0.04, loc=o)
    trim = m.piece("HoodTrim", "HatAccent", bone=bone)
    # a crimson feather tucked into the hood band on the left
    sweep(trim, [(0.9, 0.2, -0.3), (1.04, 0.5, -0.02), (1.08, 0.86, 0.34), (1.0, 1.1, 0.62)],
          [0.03, 0.1, 0.08, 0.0], seg=4, sx=2.2, loc=o, up=(1, 0, 1))


@register("Ranger", "Heroes", "Hooded archer: moss hood, tan dagged capelet, leather jerkin, tall longbow, quiver "
                              "with crimson fletching on the back.")
def ranger(m):
    rig(m, pal(Cloth="dirt_400", Cloth2="moss_800", Metal="leather_600", MetalDark="leather_700",
                   Accent="crimson_500", AccentDark="crimson_700", Gold="gold_500", Hat="moss_400",
                   HatAccent="crimson_500", Hair="wood_600", Skin="skin_500", Wood="wood_500"))
    head(m)
    hair_short(m)
    hood_ranger(m, HAT_ORIGIN, "Head")

    t = m.piece("Torso", "Metal", bone="Torso", shadow=True)
    lathe(t, [(0.8, 2.2), (0.84, 2.7), (0.94, 3.3), (0.98, 3.85), (0.86, 4.28), (0.5, 4.48), (0.0, 4.52)],
          seg=8, phase=22.5, sx=1.08, sy=0.68)
    tunic = m.piece("Tunic", "MetalDark", bone="Torso")
    lathe(tunic, [(1.06, 1.25), (0.98, 1.7), (0.88, 2.3)], seg=8, phase=22.5, sx=1.08, sy=0.76)
    # slit skirt: a darker panel down the front
    slab(tunic, [(-0.2, 0.55), (0.2, 0.55), (0.24, -0.5), (-0.24, -0.5)], 0.08, loc=(0, -0.8, 1.72),
         rot=(-12, 0, 0), bevel=0.02)
    belt = m.piece("Belt", "Leather", bone="Torso")
    band(belt, 0.84, 0.95, 2.2, 2.42, phase=22.5, sx=1.08, sy=0.74)
    block(belt, (0.42, 0.32, 0.4), loc=(0.66, -0.66, 2.04), bevel=0.08)  # pouch
    # quiver strap across the chest (right shoulder to left hip)
    sweep(belt, [(-0.86, -0.4, 4.2), (-0.3, -0.72, 3.55), (0.35, -0.72, 2.9), (0.86, -0.46, 2.5)],
          [0.08, 0.08, 0.08, 0.08], seg=4, sx=1.8, up=(0, -1, 0))
    buckle = m.piece("Buckle", "Gold", "Metal", bone="Torso")
    block(buckle, (0.3, 0.12, 0.26), loc=(0, -0.72, 2.31), bevel=0.03)
    block(buckle, (0.18, 0.1, 0.18), loc=(-0.05, -0.79, 3.25), rot=(0, 0, 12), bevel=0.02)
    buckle.ico(0.15, loc=(0, -0.84, 4.32), scale=(1.2, 0.6, 1.0), subdiv=1)  # capelet clasp

    # dagged capelet over the shoulders: leaf points all round
    cape = m.piece("Capelet", "Cloth", bone="Torso", shadow=True)
    dag = lambda c: -0.26 if c % 2 else 0.0  # noqa: E731
    arc_shell(cape, [(0.6, 4.58, 0.0), (1.0, 4.36, 0.02), (1.32, 3.96, 0.05), (1.44, 3.5, 0.08)], 0, 360,
              seg=14, thick=0.12, sx=1.06, sy=0.84, hem=dag)

    # quiver on the back, leaning up over the right shoulder, crimson fletching on top
    qa, qb = Vector((0.62, 0.84, 2.2)), Vector((-0.86, 1.12, 4.62))
    q = m.piece("Quiver", "Leather", bone="Torso", shadow=True)
    sweep(q, [qa, qa.lerp(qb, 0.5), qb], [0.3, 0.33, 0.35], seg=8)
    qd = (qb - qa).normalized()
    qtrim = m.piece("QuiverTrim", "Gold", "Metal", bone="Torso")
    sweep(qtrim, [qb - qd * 0.18, qb + qd * 0.02], [0.39, 0.39], seg=8)
    sweep(qtrim, [qa + qd * 0.1, qa + qd * 0.26], [0.34, 0.35], seg=8)
    shafts = m.piece("Arrows", "Wood", bone="Torso")
    fl = m.piece("Fletching", "Accent", bone="Torso")
    for i, (dx, dy, extra) in enumerate(((0.13, -0.09, 1.25), (-0.15, 0.02, 1.5), (0.03, 0.15, 1.35),
                                        (-0.05, -0.15, 1.12))):
        base = qb + Vector((dx, dy, 0))
        tip = base + qd * extra
        sweep(shafts, [base - qd * 0.1, tip], [0.035, 0.035], seg=4)
        for k in range(2):  # two crossed vanes
            sweep(fl, [tip - qd * 0.5, tip - qd * 0.26, tip], [0.0, 0.12, 0.07], seg=4, sx=2.4,
                  up=(math.cos(k * 1.57 + i), math.sin(k * 1.57 + i), 0))

    for s, side in SIDES:
        bone = side + "Arm"
        x = s * 1.38
        arm = m.piece(bone, "Cloth2", bone=bone)
        block(arm, (0.56, 0.58, 1.7), loc=(x, 0, 3.08), rot=(0, -s * 5, 0), bottom=(0.9, 0.9), bevel=0.12)
        bracer = m.piece(bone + "Bracer", "MetalDark", bone=bone)
        lathe(bracer, [(0.36, 2.42), (0.41, 2.95)], seg=8, phase=22.5, loc=(x + s * 0.07, -0.02, 0))
        glove = m.piece(bone + "Glove", "Leather", bone=bone)
        gauntlet_fist(glove, x + s * 0.08, z=2.16, size=(0.52, 0.56, 0.5))

    # longbow in the left hand: a tall D-curve bulging forward, tips flicked back, taut string
    grip = Vector((1.5, -0.12, 2.18))
    pts, rad = [], []
    for k in range(9):
        u = -1 + k / 4  # -1 bottom tip .. 1 top tip
        ln = 2.45 if u > 0 else 2.0
        z = grip.z + u * ln
        y = grip.y - 0.12 - 0.62 * (1 - u * u) + (0.16 if abs(u) > 0.9 else 0.0)
        pts.append(Vector((grip.x + u * 0.12, y + 0.12, z)))
        rad.append(0.045 if abs(u) == 1 else 0.13 - 0.05 * abs(u))
    bow = m.piece("Bow", "Wood", bone="LeftArm", shadow=True)
    sweep(bow, pts, rad, seg=5, sx=1.5, up=(1, 0, 0))
    wrap = m.piece("BowGrip", "Leather", bone="LeftArm")
    sweep(wrap, [pts[4] + Vector((0, 0, -0.3)), pts[4] + Vector((0, 0, 0.3))], [0.14, 0.14], seg=6)
    nocks = m.piece("BowTrim", "Gold", "Metal", bone="LeftArm")
    for i in (1, 7):
        sweep(nocks, [pts[i] + Vector((0, 0, -0.12)), pts[i] + Vector((0, 0, 0.12))], [0.11, 0.11], seg=5)
    string = m.piece("BowString", "Cloth2", bone="LeftArm")
    sweep(string, [pts[0] + Vector((0, 0.02, 0.05)), pts[-1] + Vector((0, 0.02, -0.05))], [0.025, 0.025], seg=4)

    legs(m, "Cloth2", width=0.68)
    boots(m, "Leather", z_top=1.08)


# ---------------------------------------------------------------------------------- Alchemist

def alchemist_cap(m, o, bone):
    """Leather aviator cap with ear flaps and brass goggles pushed up on the brow."""
    cap = m.piece("Cap", "Hat", bone=bone, shadow=True)
    lathe(cap, [(0.92, -0.42), (0.95, -0.12), (0.88, 0.14), (0.62, 0.34), (0.0, 0.42)], seg=8, phase=22.5,
          loc=o, sy=0.97)
    for s in (1, -1):  # ear flaps
        slab(cap, [(-0.32, 0.1), (0.3, 0.1), (0.24, -0.5), (0.0, -0.66), (-0.26, -0.5)], 0.12,
             loc=at(o, s * 0.86, 0.02, -0.58), rot=(0, 0, 90 + s * 4), bevel=0.04)
    goggles = m.piece("Goggles", "Gold", "Metal", bone=bone)
    strap = m.piece("GoggleStrap", "Dark", bone=bone)
    band(strap, 0.9, 0.98, -0.32, -0.16, loc=o, phase=22.5, sy=0.98)
    lens = m.piece("GoggleLens", "Lens", bone=bone)
    for s in (1, -1):
        c = Vector(at(o, s * 0.34, -0.86, -0.12))
        goggles.cyl(0.3, 0.28, 0.3, seg=8, loc=c, rot=(78, 0, 0))
        lens.cyl(0.22, 0.22, 0.08, seg=8, loc=c + Vector((0, -0.14, 0.03)), rot=(78, 0, 0))
    block(goggles, (0.2, 0.14, 0.12), loc=at(o, 0, -0.9, -0.14), bevel=0.03)
    trim = m.piece("CapRivets", "HatAccent", "Metal", bone=bone)
    band(trim, 0.9, 0.97, -0.44, -0.36, loc=o, phase=22.5, sy=0.98)


def flask(glass, liquid, cork, c, r, neck=0.12, tilt=(0, 0, 0), seg=8):
    """Round-bottomed flask: glass bulb, liquid ball inside, neck and cork."""
    c = Vector(c)
    up = turned((0, 0, 1), tilt)
    ellipsoid(glass, tuple(c), (r, r, r), seg=seg, rings=seg - 2)
    sweep(glass, [c + up * r * 0.8, c + up * (r + neck + 0.12)], [neck, neck * 0.9], seg=6)
    ellipsoid(liquid, tuple(c - up * r * 0.1), (r * 0.8, r * 0.8, r * 0.66), seg=seg, rings=4)
    sweep(cork, [c + up * (r + neck + 0.06), c + up * (r + neck + 0.2)], [neck * 1.15, neck * 1.05], seg=6)


@register("Alchemist", "Heroes", "Slate long coat over a leather apron, aviator cap with brass goggles, bandolier of "
                                 "glowing flasks, a big flask in hand.")
def alchemist(m):
    rig(m, pal(Cloth="slate_600", Cloth2="slate_800", Metal="leather_500", MetalDark="leather_700",
                   Accent="crimson_600", AccentDark="crimson_800", Gold="gold_500", Hat="leather_600",
                   HatAccent="gold_600", Hair="ivory_300", Skin="skin_400", Glow="fx_heal", Glow2="fx_arcane",
                   Glass="ivory_100", Lens="amber_300", Wood="wood_500"))
    head(m)
    hair = hair_cap(m, back_to=4.75, front=5.62)
    brows(hair, z=5.4, tilt=-14, y=-0.7)
    for s in (1, -1):  # wild grey tufts poking out from under the cap
        for k, (dy, dz, ln) in enumerate(((-0.1, 5.05, 0.5), (0.25, 4.85, 0.42), (0.45, 5.25, 0.36))):
            b = Vector((s * 0.78, dy, dz))
            sweep(hair, [b, b + Vector((s * ln, 0.06 + k * 0.08, -0.12 + k * 0.1))], [0.14, 0.0], seg=4)
    block(hair, (0.86, 0.22, 0.2), loc=(0, -0.76, HEAD_Z - 0.3), bottom=(0.7, 1.0), bevel=0)  # moustache
    for s in (1, -1):
        sweep(hair, [(s * 0.3, -0.76, HEAD_Z - 0.32), (s * 0.62, -0.74, HEAD_Z - 0.22)], [0.1, 0.0], seg=4)
    alchemist_cap(m, HAT_ORIGIN, "Head")

    t = m.piece("Torso", "Cloth", bone="Torso", shadow=True)
    lathe(t, [(0.82, 2.2), (0.86, 2.75), (0.96, 3.3), (1.0, 3.85), (0.9, 4.28), (0.56, 4.48), (0.0, 4.52)],
          seg=8, phase=22.5, sx=1.06, sy=0.7)
    # long coat skirt: open at the front, tails longer at the back
    tails = lambda c: -0.32 * max(0.0, 1 - abs(c - 4) / 2.2)  # noqa: E731
    coat = m.piece("Coat", "Cloth", bone="Torso", shadow=True)
    arc_shell(coat, [(0.92, 2.45, 0.02), (1.04, 1.8, 0.06), (1.16, 1.1, 0.12), (1.26, 0.48, 0.18)], 34, 326,
              seg=8, thick=0.1, sx=1.06, sy=0.8, hem=tails)
    lapel = m.piece("Lapels", "Cloth2", bone="Torso")
    for s in (1, -1):
        slab(lapel, [(-0.13, 0.62), (0.15, 0.62), (0.2, -0.56), (0.02, -0.7)], 0.08,
             loc=(s * 0.46, -0.66, 3.66), rot=(-6, 0, s * 18))
    apron = m.piece("Apron", "Metal", bone="Torso")
    slab(apron, [(-0.46, 0.85), (0.46, 0.85), (0.58, -0.4), (0.62, -1.7), (-0.62, -1.7), (-0.58, -0.4)], 0.1,
         loc=(0, -0.78, 2.4), rot=(-5, 0, 0), bevel=0.03)
    slab(apron, [(-0.5, 0.18), (0.5, 0.18), (0.5, -0.18), (-0.5, -0.18)], 0.08, loc=(0, -0.86, 1.62),
         rot=(-5, 0, 0), bevel=0.02)  # pocket
    cravat = m.piece("Cravat", "Accent", bone="Torso")
    cravat.ico(0.2, loc=(0, -0.6, 4.3), scale=(1.2, 0.8, 0.9), subdiv=0)
    slab(cravat, [(-0.16, 0.0), (0.16, 0.0), (0.2, -0.46), (0.0, -0.58), (-0.2, -0.46)], 0.1,
         loc=(0, -0.68, 4.2), rot=(-8, 0, 0))

    # bandolier from the left shoulder to the right hip, flasks clipped to it
    strap = m.piece("Bandolier", "Leather", bone="Torso")
    path = [Vector((0.9, -0.36, 4.22)), Vector((0.36, -0.84, 3.5)), Vector((-0.3, -0.92, 2.86)),
            Vector((-0.92, -0.56, 2.42))]
    sweep(strap, path, [0.1, 0.1, 0.1, 0.1], seg=4, sx=1.9, up=(0, -1, 0))
    belt = m.piece("Belt", "Leather", bone="Torso")
    band(belt, 0.86, 0.97, 2.32, 2.54, phase=22.5, sx=1.06, sy=0.76)
    block(belt, (0.44, 0.3, 0.42), loc=(-0.7, -0.64, 2.16), bevel=0.08)  # pouch
    glass = m.piece("Flasks", "Glass", bone="Torso", transparency=0.35)
    liq = m.piece("Potions", "Glow", "Neon", bone="Torso")
    liq2 = m.piece("Potions2", "Glow2", "Neon", bone="Torso")
    corks = m.piece("FlaskCaps", "Gold", "Metal", bone="Torso")
    for i, u in enumerate((0.18, 0.5, 0.82)):
        k = u * 3
        a, b = path[int(k)], path[min(int(k) + 1, 3)]
        c = a.lerp(b, k - int(k)) + Vector((0, -0.2, -0.05))
        flask(glass, liq if i % 2 == 0 else liq2, corks, c, 0.2, neck=0.07, tilt=(0, 22 - i * 8, 0), seg=5)
    block(corks, (0.28, 0.12, 0.24), loc=(0, -0.79, 2.43), bevel=0)  # belt buckle
    for z in (3.0, 3.45, 3.9):  # coat buttons on the left breast
        block(corks, (0.13, 0.08, 0.13), loc=(0.42, -0.7, z), rot=(0, 45, 0), bevel=0)

    for s, side in SIDES:
        bone = side + "Arm"
        x = s * 1.38
        sleeve(m, bone, s, "Cloth")
        cuff = m.piece(bone + "Cuff", "Cloth2", bone=bone)
        k = mark(cuff)
        band(cuff, 0.4, 0.54, 2.38, 2.56, phase=22.5, loc=(x, 0, 0))
        turn(cuff, k, (x, 0, 3.95), (0, -s * 6, 0))
        hand(m, bone, x + s * 0.16, slot="Leather")

    # the big round-bottomed flask held up in the right hand (the ability: throw a potion)
    fc = Vector((-1.6, -0.5, 2.62))
    bg = m.piece("HeldFlask", "Glass", bone="RightArm", transparency=0.3)
    bl = m.piece("HeldPotion", "Glow", "Neon", bone="RightArm")
    bc = m.piece("HeldFlaskCap", "Gold", "Metal", bone="RightArm")
    flask(bg, bl, bc, fc, 0.42, neck=0.14, tilt=(-10, 0, 0))

    legs(m, "Cloth2", width=0.66)
    boots(m, "Leather", z_top=0.7)


# ---------------------------------------------------------------------------------- Engineer

def miner_helmet(m, o, bone):
    """Round steel helmet with a rolled brim, a brass lamp at the brow and a gear badge."""
    helm = m.piece("Helm", "Hat", "Metal", bone=bone, shadow=True)
    lathe(helm, [(0.98, -0.5), (1.0, -0.2), (0.94, 0.08), (0.74, 0.32), (0.4, 0.46), (0.0, 0.5)], seg=8,
          phase=22.5, loc=o, sy=0.98)
    revolve(helm, [(0.92, -0.56), (1.18, -0.6), (1.2, -0.5), (0.94, -0.44)], seg=8, phase=22.5, loc=o, sy=1.0)
    rib = m.piece("HelmTrim", "HatAccent", "Metal", bone=bone)
    sweep(rib, [(0, -0.96, -0.3), (0, -0.82, 0.12), (0, -0.4, 0.45), (0, 0.1, 0.52), (0, 0.6, 0.38),
                (0, 0.92, 0.0)], [0.1, 0.11, 0.11, 0.11, 0.11, 0.1], seg=4, sx=1.5, loc=o)
    lamp = m.piece("HelmLamp", "Gold", "Metal", bone=bone)
    lamp.cyl(0.3, 0.26, 0.34, seg=8, loc=at(o, 0, -1.02, -0.18), rot=(86, 0, 0))
    block(lamp, (0.3, 0.2, 0.26), loc=at(o, 0, -0.88, -0.2), bevel=0)
    glow = m.piece("HelmLight", "Glow", "Neon", bone=bone)
    glow.cyl(0.21, 0.21, 0.06, seg=8, loc=at(o, 0, -1.2, -0.17), rot=(86, 0, 0))
    gear(lamp, at(o, 0.98, 0.1, -0.18), (0, 0, 90), 0.3, 0.22, depth=0.1)


@register("Engineer", "Heroes", "Stout dwarf engineer: steel miner's helmet with a brass lamp, huge ginger beard, "
                                "boiler backpack, gold gears, giant steel wrench.")
def engineer(m):
    rig(m, pal(Cloth="slate_500", Cloth2="stone_600", Metal="steel_400", MetalDark="steel_600",
                   Accent="crimson_500", AccentDark="crimson_700", Gold="gold_500", Hat="steel_400",
                   HatAccent="gold_500", Hair=mix("crimson_400", "gold_500", 0.45), Skin="skin_500",
                   Glow="fx_gold", Blade="steel_300"))
    head(m)
    hair = hair_cap(m, back_to=4.9, front=5.66)
    brows(hair, z=5.4, tilt=-12, y=-0.72)
    miner_helmet(m, HAT_ORIGIN, "Head")
    beard = m.piece("FaceBeard", "Hair", bone="Head", shadow=True)
    # big spade beard from the cheeks down over the chest, a braided point at the belt
    lathe(beard, [(0.42, 3.4), (0.74, 3.9), (0.86, 4.4), (0.8, 4.8), (0.6, 5.04), (0.0, 5.08)], seg=8,
          loc=(0, -0.6, 0), sx=1.05, sy=0.52)
    block(beard, (1.1, 0.3, 0.3), loc=(0, -0.83, HEAD_Z - 0.18), bottom=(0.75, 1.0), bevel=0)  # moustache
    for s in (1, -1):
        sweep(beard, [(s * 0.42, -0.86, HEAD_Z - 0.22), (s * 0.82, -0.82, HEAD_Z - 0.38),
                      (s * 0.96, -0.74, HEAD_Z - 0.6)], [0.13, 0.1, 0.0], seg=4)
        sweep(beard, [(s * 0.66, -0.36, 4.95), (s * 0.74, -0.42, 4.6)], [0.18, 0.2], seg=5)  # sideburns
    sweep(beard, [(0, -0.72, 3.55), (0, -0.8, 3.15), (0, -0.84, 2.82)], [0.22, 0.16, 0.0], seg=5)
    clasp = m.piece("FaceBeardRing", "Gold", "Metal", bone="Head")
    sweep(clasp, [(0, -0.74, 3.42), (0, -0.77, 3.28)], [0.2, 0.18], seg=6)

    # barrel chest and round belly; tunic skirt; heavy belt with a gear buckle
    t = m.piece("Torso", "Cloth", bone="Torso", shadow=True)
    lathe(t, [(0.92, 2.2), (1.06, 2.75), (1.14, 3.3), (1.12, 3.85), (0.98, 4.28), (0.6, 4.5), (0.0, 4.54)],
          seg=8, phase=22.5, sx=1.12, sy=0.8)
    skirt = m.piece("Tunic", "Cloth", bone="Torso")
    lathe(skirt, [(1.14, 1.4), (1.08, 1.9), (0.96, 2.3)], seg=8, phase=22.5, sx=1.12, sy=0.82)
    belt = m.piece("Belt", "Leather", bone="Torso")
    band(belt, 1.0, 1.12, 2.08, 2.42, phase=22.5, sx=1.12, sy=0.82)
    for x in (-0.82, 0.86):
        block(belt, (0.34, 0.34, 0.46), loc=(x, -0.68, 1.98), bevel=0)  # tool pouches
    gears = m.piece("Gears", "Gold", "Metal", bone="Torso")
    gear(gears, (0, -0.98, 2.25), (0, 0, 0), 0.32, 0.24, depth=0.12)
    # boiler backpack: a steel tank with brass bands, a gear and a stubby chimney
    pack = m.piece("Pack", "Metal", "Metal", bone="Torso", shadow=True)
    pack.cyl(0.55, 0.55, 1.5, seg=8, loc=(0, 1.08, 3.35))
    lathe(pack, [(0.55, 4.1), (0.4, 4.35), (0.0, 4.42)], seg=8, loc=(0, 1.08, 0))
    block(pack, (1.1, 0.3, 1.2), loc=(0, 0.74, 3.35), bevel=0.08)
    pipe = m.piece("PackPipe", "MetalDark", "Metal", bone="Torso")
    sweep(pipe, [(-0.32, 1.16, 4.1), (-0.36, 1.2, 4.75)], [0.13, 0.15], seg=6)
    sweep(pipe, [(-0.36, 1.2, 4.75), (-0.36, 1.2, 4.92)], [0.2, 0.2], seg=6)
    gear(gears, (0.56, 1.2, 3.35), (0, 0, 90), 0.36, 0.27, depth=0.1)
    strap = m.piece("Straps", "Leather", bone="Torso")
    for s in (1, -1):
        sweep(strap, [(s * 0.5, 0.62, 4.32), (s * 0.66, -0.2, 4.4), (s * 0.82, -0.58, 3.7)],
              [0.08, 0.08, 0.08], seg=4, sx=1.7, up=(0, 0, 1))
    scarf = m.piece("Kerchief", "Accent", bone="Torso")
    revolve(scarf, [(0.55, 4.24), (0.98, 4.18), (1.02, 4.38), (0.56, 4.5)], seg=6, phase=30, sx=1.1,
            sy=0.86)

    for s, side in SIDES:
        bone = side + "Arm"
        x = s * 1.48
        arm = m.piece(bone, "Cloth", bone=bone)
        block(arm, (0.66, 0.66, 1.6), loc=(x, 0, 3.1), rot=(0, -s * 5, 0), bottom=(0.92, 0.92), bevel=0.14)
        pad = m.piece(bone + "Pauldron", "Metal", "Metal", bone=bone)
        k = mark(pad)
        lathe(pad, [(0.66, 3.56), (0.66, 3.78), (0.56, 4.06), (0.3, 4.2), (0.0, 4.24)], seg=8, phase=22.5,
              loc=(x + s * 0.04, 0, 0), sy=0.96)
        turn(pad, k, (x, 0, 3.9), (0, s * 12, 0))
        rivet = m.piece(bone + "PadTrim", "Gold", "Metal", bone=bone)
        k = mark(rivet)
        band(rivet, 0.61, 0.71, 3.5, 3.62, phase=22.5, loc=(x + s * 0.04, 0, 0), sy=0.96)
        turn(rivet, k, (x, 0, 3.9), (0, s * 12, 0))
        glove = m.piece(bone + "Glove", "Leather", bone=bone)
        lathe(glove, [(0.38, 2.4), (0.46, 2.72)], seg=8, phase=22.5, loc=(x + s * 0.06, -0.02, 0))
        gauntlet_fist(glove, x + s * 0.07, z=2.1, size=(0.66, 0.7, 0.6))

    # the giant wrench in the right hand: steel shaft, open jaw forward and down, crimson grip
    hnd = Vector((-1.55, -0.04, 2.1))
    d = Vector((-0.12, -0.88, -0.42)).normalized()
    side = Vector((0, 0, 1)).cross(d).normalized()
    up = d.cross(side)
    w = m.piece("Wrench", "Blade", "Metal", bone="RightArm", shadow=True)
    sweep(w, [hnd + d * 0.3, hnd + d * 1.4, hnd + d * 2.3], [0.15, 0.13, 0.17], seg=6, sx=1.6, up=up)
    jaw_c = hnd + d * 2.62
    # open jaw: a thick C (two prongs) opening forward
    for k in (1, -1):
        sweep(w, [jaw_c - d * 0.25 + up * k * 0.05, jaw_c + up * k * 0.38, jaw_c + d * 0.42 + up * k * 0.44,
                  jaw_c + d * 0.62 + up * k * 0.3], [0.22, 0.23, 0.2, 0.15], seg=5, sx=1.4, up=side)
    sweep(w, [hnd - d * 0.55, hnd - d * 0.75], [0.17, 0.12], seg=6)  # pommel ring
    grip = m.piece("WrenchGrip", "Accent", bone="RightArm")
    sweep(grip, [hnd - d * 0.52, hnd + d * 0.32], [0.14, 0.14], seg=6)
    wg = m.piece("WrenchGear", "Gold", "Metal", bone="RightArm")
    rd = tuple(math.degrees(a) for a in (side).to_track_quat("Y", "Z").to_euler())
    gear(wg, hnd + d * 1.55, rd, 0.3, 0.22, depth=0.36)

    legs(m, "Cloth2", width=0.76)
    for s, side_ in SIDES:  # big hobnailed boots with steel toecaps
        bone = side_ + "Leg"
        b = m.piece(bone + "Boot", "Leather", bone=bone)
        x = s * 0.54
        block(b, (0.9, 1.3, 0.5), loc=(x, -0.16, 0.25), top=(0.9, 0.82), shift=(0, 0.08), bevel=0.14)
        block(b, (0.86, 0.9, 0.62), loc=(x, 0.0, 0.72), bevel=0.1)
        block(b, (0.96, 0.98, 0.22), loc=(x, 0.0, 1.05), bevel=0)
        cap = m.piece(bone + "ToeCap", "MetalDark", "Metal", bone=bone)
        block(cap, (0.8, 0.42, 0.34), loc=(x, -0.62, 0.22), top=(0.85, 0.7), bevel=0.1)


# ---------------------------------------------------------------------------------- Necromancer

def necro_hood(m, o, bone):
    """Tall cowl rising to a point at the back, crimson lining, sides draping onto the collar."""
    hood = m.piece("Hood", "Hat", bone=bone, shadow=True)

    def rise(co):
        h = max(co.z, 0.0)
        return Vector((co.x * (1 - h * 0.3), co.y + h * 0.45, co.z * 1.25))

    lathe(hood, [(1.02, -0.14), (1.03, 0.14), (0.9, 0.42), (0.62, 0.7), (0.3, 0.92), (0.0, 1.02)], seg=8,
          phase=22.5, loc=o, deform=rise)
    arc_shell(hood, [(1.02, -0.02, 0.0), (1.06, -0.6, 0.04), (1.14, -1.12, 0.08), (1.26, -1.5, 0.14)],
              48, 312, seg=8, thick=0.14, loc=o)
    arc_shell(hood, [(1.02, -0.02, 0.0), (1.02, -0.36, -0.06)], -56, 56, seg=4, thick=0.15, loc=o)
    lining = m.piece("HoodLining", "HatAccent", bone=bone)
    arc_shell(lining, [(1.05, 0.0, -0.08), (1.1, -0.6, -0.04), (1.18, -1.12, 0.0), (1.3, -1.48, 0.06)],
              44, 64, seg=2, thick=0.08, loc=o)
    arc_shell(lining, [(1.05, 0.0, -0.08), (1.1, -0.6, -0.04), (1.18, -1.12, 0.0), (1.3, -1.48, 0.06)],
              296, 316, seg=2, thick=0.08, loc=o)
    shade = m.piece("HoodShade", "Dark", bone=bone)
    arc_shell(shade, [(0.86, -0.1, 0.0), (0.86, -1.45, 0.04)], 40, 320, seg=8, thick=0.04, loc=o)


@register("Necromancer", "Heroes", "Ivory skull mask under a tall dark cowl, slate and crimson robes, spiked bone "
                                   "collar and pauldrons, bone staff with a small glowing soul core.")
def necromancer(m):
    rig(m, pal(Cloth="slate_800", Cloth2="slate_700", Metal="ivory_300", MetalDark="ivory_500",
                   Accent="crimson_600", AccentDark="crimson_800", Gold="gold_600", Hat="slate_900",
                   HatAccent="crimson_600", Hair="slate_950", Skin="stone_300", Bone="ivory_200",
                   Glow=mix("fx_heal", "fx_holy", 0.35)))
    head(m)
    mask = m.piece("FaceMask", "Bone", bone="Head")
    # skull mask over the face: domed brow, cheekbones, a narrow jaw
    lathe(mask, [(0.52, 4.62), (0.66, 4.86), (0.74, 5.2), (0.72, 5.5), (0.5, 5.72)], seg=8, phase=22.5,
          loc=(0, -0.42, 0), sx=1.0, sy=0.5)
    sockets = m.piece("FaceSockets", "Dark", bone="Head")
    for s in (1, -1):
        block(sockets, (0.36, 0.14, 0.3), loc=(s * 0.27, -0.76, 5.24), rot=(0, s * 10, 0), bottom=(0.8, 1.0),
              bevel=0)
    block(sockets, (0.14, 0.12, 0.18), loc=(0, -0.79, 4.98), top=(0.4, 1.0), bevel=0)  # nose
    for i in range(4):
        block(sockets, (0.05, 0.1, 0.18), loc=(-0.2 + i * 0.133, -0.74, 4.74), bevel=0)  # teeth gaps
    glint = m.piece("FaceGlow", "Glow", "Neon", bone="Head")
    for s in (1, -1):
        glint.ico(0.075, loc=(s * 0.27, -0.8, 5.22), subdiv=0)
    necro_hood(m, HAT_ORIGIN, "Head")

    t = m.piece("Torso", "Cloth", bone="Torso", shadow=True)
    lathe(t, [(0.82, 2.2), (0.86, 2.75), (0.94, 3.3), (0.98, 3.85), (0.86, 4.28), (0.52, 4.48), (0.0, 4.52)],
          seg=8, phase=22.5, sx=1.04, sy=0.7)
    rag = lambda c: (-0.3, 0.0, -0.18, 0.04)[c % 4]  # noqa: E731  (tattered hem)
    robe = m.piece("Robe", "Cloth", bone="Torso", shadow=True)
    arc_shell(robe, [(0.92, 2.5, 0.0), (1.06, 1.6, 0.04), (1.24, 0.8, 0.08), (1.4, 0.28, 0.1)], 0, 360,
              seg=12, thick=0.12, sx=1.02, sy=0.86, hem=rag)
    front = m.piece("RobeFront", "Accent", bone="Torso")
    panel = [(-0.24, 1.1), (0.24, 1.1), (0.44, -1.02), (0.0, -1.3), (-0.44, -1.02)]
    slab(front, panel, 0.1, loc=(0, -0.95, 1.3), rot=(-9, 0, 0), bevel=0.03)
    sash = m.piece("Sash", "AccentDark", bone="Torso")
    band(sash, 0.86, 0.97, 2.34, 2.56, phase=22.5, sx=1.04, sy=0.76)
    for s in (1, -1):
        slab(sash, [(-0.1, 0.0), (0.1, 0.0), (0.12, -0.9), (0.0, -1.0), (-0.12, -0.9)], 0.06,
             loc=(0.48 + s * 0.12, -0.76, 2.36), rot=(-6, 0, s * 8))
    gold = m.piece("Clasp", "Gold", "Metal", bone="Torso")
    gold.ico(0.16, loc=(0, -0.72, 4.18), scale=(1, 0.6, 1), subdiv=1)
    block(gold, (0.26, 0.1, 0.24), loc=(0, -0.8, 2.45), bevel=0.03)

    # spiked bone collar flaring up behind the head, rib pauldrons
    bone_ = m.piece("BoneCollar", "Metal", bone="Torso", shadow=True)
    arc_shell(bone_, [(0.66, 4.5, 0.06), (0.96, 4.24, 0.08)], 70, 290, seg=8, thick=0.12, sx=1.06, sy=0.9)
    for i in range(5):
        a = math.radians(115 + i * 32.5)
        b = Vector((math.sin(a) * 0.8, -math.cos(a) * 0.74 + 0.06, 4.36))
        out = Vector((math.sin(a), -math.cos(a) * 0.9, 0)).normalized()
        ln = 1.25 if i == 2 else (1.0 if i in (1, 3) else 0.72)
        sweep(bone_, [b, b + out * 0.18 + Vector((0, 0, ln * 0.55)), b + out * 0.42 + Vector((0, 0, ln))],
              [0.13, 0.09, 0.0], seg=4)
    for s, side in SIDES:
        bone = side + "Arm"
        x = s * 1.38
        sleeve(m, bone, s, "Cloth", r=(0.56, 0.46, 0.37, 0.35))
        cuff = m.piece(bone + "Cuff", "Accent", bone=bone)
        k = mark(cuff)
        band(cuff, 0.44, 0.6, 2.36, 2.5, phase=22.5, loc=(x, 0, 0))
        turn(cuff, k, (x, 0, 3.95), (0, -s * 6, 0))
        hand(m, bone, x + s * 0.16, slot="Skin")
        pad = m.piece(bone + "Ribs", "Metal", bone=bone)
        k = mark(pad)
        lathe(pad, [(0.56, 3.62), (0.54, 3.86), (0.4, 4.08), (0.0, 4.16)], seg=6, loc=(x + s * 0.06, 0, 0),
              sy=0.9)
        for j, y in enumerate((-0.32, 0.0, 0.32)):  # curved rib spikes sweeping outward and up
            b = Vector((x + s * 0.32, y, 3.95))
            sweep(pad, [b, b + Vector((s * 0.42, y * 0.2, 0.18)), b + Vector((s * 0.66, y * 0.35, 0.56 - j * 0.04))],
                  [0.11, 0.08, 0.0], seg=4)
        turn(pad, k, (x, 0, 3.9), (0, s * 10, 0))

    # bone staff in the right hand: a spine of knuckled vertebrae, a claw of finger bones
    # cradling the soul core, a small skull below it
    base, top = Vector((-1.52, -0.22, 0.12)), Vector((-1.62, -0.4, 4.7))
    staff = m.piece("Staff", "Bone", bone="RightArm", shadow=True)
    sweep(staff, [base, (base + top) / 2, top], [0.09, 0.1, 0.11], seg=6)
    for u in (0.3, 0.55, 0.8):
        c = base.lerp(top, u)
        staff.ico(0.15, loc=c, scale=(1, 1, 0.6), subdiv=0)
    for i in range(4):
        a = math.radians(45 + i * 90)
        out = Vector((math.cos(a), math.sin(a), 0))
        sweep(staff, [top, top + out * 0.3 + Vector((0, 0, 0.2)), top + out * 0.32 + Vector((0, 0, 0.62)),
                      top + out * 0.1 + Vector((0, 0, 0.84))], [0.07, 0.06, 0.05, 0.0], seg=4)
    sk = m.piece("StaffSkull", "Bone", bone="RightArm")
    skull(sk, top + Vector((0, -0.08, -0.26)), r=0.26)
    sock = m.piece("StaffSkullEyes", "Dark", bone="RightArm")
    for s in (1, -1):
        sock.ico(0.07, loc=top + Vector((s * 0.1, -0.33, -0.24)), subdiv=0)
    ring = m.piece("StaffTrim", "Gold", "Metal", bone="RightArm")
    band(ring, 0.08, 0.15, -0.07, 0.07, seg=6, loc=top + Vector((0, 0, 0.0)))
    band(ring, 0.07, 0.13, -0.06, 0.06, seg=6, loc=base + Vector((0, 0, 0.14)))
    core = m.piece("StaffCore", "Glow", "Neon", bone="RightArm")
    core.ico(0.2, loc=top + Vector((0, 0, 0.5)), subdiv=1)

    legs(m, "Cloth2", width=0.68)
    boots(m, "Dark", z_top=0.6, cuff=False)


# ---------------------------------------------------------------------------------- ability props

@register("Shot_Arrow", "Projectiles", "Ranger arrow ~0.4 x 3.2: steel head at the -Y end, wooden shaft, crimson "
                                       "fletching. Lies along Y, centred on the origin.")
def shot_arrow(m):
    m.extra["palette"] = {"Wood": P("wood_400"), "Blade": P("steel_300"), "Accent": P("crimson_500"),
                          "Gold": P("gold_500")}
    shaft = m.piece("Shaft", "Wood")
    sweep(shaft, [(0, -1.2, 0), (0, 1.5, 0)], [0.06, 0.06], seg=5)
    head_ = m.piece("Head", "Blade", "Metal")
    sweep(head_, [(0, -1.12, 0), (0, -1.3, 0), (0, -1.62, 0)], [0.1, 0.14, 0.0], seg=4, sx=2.0, up=(1, 0, 0))
    fl = m.piece("Fletching", "Accent")
    for k in range(3):
        a = k / 3 * math.tau
        sweep(fl, [(0, 1.62, 0), (0, 1.1, 0), (0, 0.78, 0)], [0.05, 0.14, 0.0], seg=4, sx=2.6,
              up=(math.cos(a), 0, math.sin(a)))
    nock = m.piece("Nock", "Gold", "Metal")
    sweep(nock, [(0, 1.42, 0), (0, 1.58, 0)], [0.08, 0.08], seg=5)


@register("Shot_Potion", "Projectiles", "Alchemist's thrown flask ~1.2 x 1.5: translucent glass bulb, glowing green "
                                        "potion, brass cap, cork. Upright, centred on the origin.")
def shot_potion(m):
    m.extra["palette"] = {"Glass": P("ivory_100"), "Glow": P("fx_heal"), "Gold": P("gold_500"),
                          "Wood": P("wood_400")}
    g = m.piece("Glass", "Glass", transparency=0.35)
    liq = m.piece("Potion", "Glow", "Neon")
    cap = m.piece("Cap", "Gold", "Metal")
    flask(g, liq, cap, (0, 0, -0.18), 0.55, neck=0.17)
    cork = m.piece("Cork", "Wood")
    sweep(cork, [(0, 0, 0.74), (0, 0, 0.92)], [0.15, 0.17], seg=6)


@register("Ability_Turret", "Abilities", "Engineer's deployable gear turret ~2.4 wide x 2.6 tall: steel tripod base, "
                                         "turning head with a brass barrel and gold gears. Origin = ground centre, "
                                         "barrel faces -Y. Head piece spins (Spin) around its own axis.")
def ability_turret(m):
    m.extra["palette"] = {"Metal": P("steel_400"), "MetalDark": P("steel_600"), "Gold": P("gold_500"),
                          "Accent": P("crimson_500"), "Glow": P("fx_gold"), "Dark": P("slate_950")}
    base = m.piece("Base", "MetalDark", "Metal", shadow=True)
    for i in range(3):
        a = math.radians(90 + i * 120)
        out = Vector((math.cos(a), math.sin(a), 0))
        sweep(base, [Vector((0, 0, 1.1)) + out * 0.2, out * 0.9 + Vector((0, 0, 0.5)), out * 1.15],
              [0.13, 0.11, 0.08], seg=5)
        base.ico(0.16, loc=out * 1.15 + Vector((0, 0, 0.08)), scale=(1, 1, 0.6), subdiv=0)
    base.cyl(0.42, 0.36, 0.5, seg=8, loc=(0, 0, 1.15))
    head_ = m.piece("Head", "Metal", "Metal", anim="Spin", pivot=(0, 0, 1.6), shadow=True)
    lathe(head_, [(0.62, 1.4), (0.7, 1.62), (0.66, 1.98), (0.4, 2.22), (0.0, 2.28)], seg=8, phase=22.5)
    barrel = m.piece("Barrel", "Gold", "Metal", anim="Spin", pivot=(0, 0, 1.6))
    sweep(barrel, [(0, -0.4, 1.78), (0, -1.25, 1.84)], [0.19, 0.17], seg=8)
    band(barrel, 0.17, 0.25, -0.08, 0.08, loc=(0, -1.18, 1.84), rot=(90, 0, 0))
    gear(barrel, (0.68, 0.0, 1.8), (0, 0, 90), 0.36, 0.27, depth=0.1)
    gear(barrel, (-0.68, 0.0, 1.8), (0, 0, 90), 0.36, 0.27, depth=0.1)
    glow = m.piece("Muzzle", "Glow", "Neon", anim="Spin", pivot=(0, 0, 1.6))
    glow.cyl(0.11, 0.11, 0.06, seg=6, loc=(0, -1.28, 1.84), rot=(90, 0, 0))
    eye = m.piece("Lamp", "Accent", anim="Spin", pivot=(0, 0, 1.6))
    eye.ico(0.14, loc=(0, -0.55, 2.15), subdiv=0)


@register("Shot_Soul", "Projectiles", "Necromancer's soul skull ~1.2 x 2.2: small ivory skull with glowing eyes "
                                      "trailing a pale spectral wisp toward +Y. Flies toward -Y.")
def shot_soul(m):
    glow = mix("fx_heal", "fx_holy", 0.35)
    m.extra["palette"] = {"Bone": P("ivory_200"), "Glow": glow, "Dark": P("slate_950"),
                          "Light": mix(glow, "ivory_100", 0.5)}
    sk = m.piece("Skull", "Bone")
    c = Vector((0, -0.45, 0.08))
    ellipsoid(sk, tuple(c), (0.46, 0.5, 0.44), seg=8, rings=6)  # cranium
    sk.box((0.5, 0.34, 0.26), loc=tuple(c + Vector((0, -0.24, -0.36))), bevel=0.06)  # jaw
    sock = m.piece("Sockets", "Dark")
    for s_ in (1, -1):
        ellipsoid(sock, tuple(c + Vector((s_ * 0.19, -0.4, 0.04))), (0.17, 0.1, 0.16), seg=6, rings=4)
    sock.box((0.08, 0.06, 0.12), loc=tuple(c + Vector((0, -0.48, -0.2))), bevel=0)
    eyes = m.piece("Eyes", "Glow", "Neon")
    for s_ in (1, -1):
        eyes.ico(0.08, loc=tuple(c + Vector((s_ * 0.19, -0.47, 0.04))), subdiv=0)
    wisp = m.piece("Wisp", "Light", transparency=0.4)
    sweep(wisp, [(0, -0.3, 0.26), (0, 0.25, 0.22), (0.14, 0.8, 0.1), (-0.08, 1.3, 0.14), (0, 1.75, 0.08)],
          [0.32, 0.28, 0.2, 0.1, 0.0], seg=6)
