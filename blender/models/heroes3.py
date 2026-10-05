"""Three heroes earned by play (feature 11, docs/features/HEROES.md): Archer, Bard, Golem.

Same rig contract as models/heroes.py (read its docstring): feet at z = 0, hips z = 2.0
(x +-0.5), shoulders z = 3.95 (x +-1.2), neck z = 4.45, the standard bare head 1.45 x 1.35 x
1.4 centred at z = 5.15, six bone pieces (Torso, Head, LeftArm, RightArm, LeftLeg, RightLeg)
named like their bone, every other piece names the bone it is welded to. Head-bone pieces
called "Head", "Eyes" or "Face*" are the face and stay when a skin swaps the headgear.
The character's LEFT is +X (Roblox -X); the right hand is at -X.

Skin slots as in heroes.py (Hat / HatAccent, Metal / MetalDark, Cloth / Cloth2, Accent /
AccentDark, Gold) with the same values as CharacterData.NewHeroes[id].Colors. Fixed slots:
Skin, Hair, Dark, Leather, Wood, Blade, Glow (Neon, small cores only), plus Lace (Bard ruff)
and Rock (Golem's loose stones).
"""

import math

from mathutils import Vector

from models.hats import (HEAD_Z, arc_shell, band, block, hat_cap, hat_plume, lathe, mark, slab, sweep,
                         turn)
from models.heroes import HAT_ORIGIN, SIDES, boots, gauntlet_fist, hair_short, head, legs, rig
from models.heroes2 import pal, sleeve
from swarmkit import register


# ---------------------------------------------------------------------------------- Archer

@register("Archer", "Heroes", "Royal crossbowman: steel parade helm with a crimson crest, slate gambeson under "
                              "an ivory tabard with gold trim, leather bracers, bolt case on the hip, a heavy "
                              "crossbow held forward at the waist.")
def archer(m):
    rig(m, pal(Cloth="slate_500", Cloth2="stone_700", Metal="leather_500", MetalDark="leather_700",
               Accent="ivory_300", AccentDark="ivory_500", Gold="gold_500", Hat="steel_400",
               HatAccent="crimson_400", Hair="wood_600", Skin="skin_400", Wood="wood_500", Blade="steel_300",
               Lace="ivory_100"))
    head(m)
    hair_short(m)
    hat_plume(m, HAT_ORIGIN, "Head")

    # padded gambeson (quilted ridges), skirt, ivory tabard front and back with a gold hem
    t = m.piece("Torso", "Cloth", bone="Torso", shadow=True)
    lathe(t, [(0.82, 2.2), (0.88, 2.7), (0.98, 3.3), (1.02, 3.85), (0.88, 4.28), (0.52, 4.48), (0.0, 4.52)],
          seg=8, phase=22.5, sx=1.08, sy=0.72)
    quilt = m.piece("Quilting", "Cloth2", bone="Torso")
    for z in (2.85, 3.35, 3.85):
        band(quilt, 0.9, 1.0, z - 0.04, z + 0.04, phase=22.5, sx=1.08, sy=0.74)
    skirt = m.piece("Tunic", "Cloth", bone="Torso")
    lathe(skirt, [(1.06, 1.3), (0.98, 1.75), (0.88, 2.3)], seg=8, phase=22.5, sx=1.08, sy=0.78)
    tabard = m.piece("Tabard", "Accent", bone="Torso", shadow=True)
    panel = [(-0.46, 1.25), (0.46, 1.25), (0.52, -1.35), (0.0, -1.62), (-0.52, -1.35)]
    slab(tabard, panel, 0.08, loc=(0, -0.86, 2.95), rot=(-5, 0, 0), bevel=0.02)
    slab(tabard, panel, 0.08, loc=(0, 0.86, 2.95), rot=(5, 0, 0), bevel=0.02)
    trim = m.piece("TabardTrim", "Gold", "Metal", bone="Torso")
    for y, rx in ((-0.92, -5), (0.92, 5)):
        slab(trim, [(-0.54, 0.0), (0.54, 0.0), (0.0, -0.32)], 0.05, loc=(0, y, 1.48), rot=(rx, 0, 0))
    # a gold crossbow badge on the chest: two bars crossed
    block(trim, (0.5, 0.06, 0.1), loc=(0, -0.95, 3.5), rot=(0, 30, 0), bevel=0.02)
    block(trim, (0.5, 0.06, 0.1), loc=(0, -0.95, 3.5), rot=(0, -30, 0), bevel=0.02)
    belt = m.piece("Belt", "Leather", bone="Torso")
    band(belt, 0.88, 0.98, 2.2, 2.42, phase=22.5, sx=1.08, sy=0.8)
    buckle = m.piece("Buckle", "Gold", "Metal", bone="Torso")
    block(buckle, (0.3, 0.12, 0.26), loc=(0, -0.82, 2.31), bevel=0.03)
    # bolt case on the right hip, bolts with crimson fletching
    case = m.piece("BoltCase", "Metal", bone="Torso", shadow=True)
    ca, cb = Vector((-1.02, 0.18, 1.35)), Vector((-1.08, 0.3, 2.55))
    sweep(case, [ca, cb], [0.26, 0.3], seg=6, sx=1.3, up=(0, 1, 0))
    bolts = m.piece("Bolts", "Wood", bone="Torso")
    fl = m.piece("Fletching", "HatAccent", bone="Torso")
    for i, (dx, dy) in enumerate(((0.08, -0.08), (-0.1, 0.02), (0.02, 0.12))):
        b0 = cb + Vector((dx, dy, -0.1))
        tip = b0 + Vector((0, 0.04, 0.55))
        sweep(bolts, [b0, tip], [0.03, 0.03], seg=4)
        sweep(fl, [tip - Vector((0, 0, 0.3)), tip], [0.0, 0.09], seg=4, sx=2.2, up=(math.cos(i), math.sin(i), 0))

    for s, side in SIDES:
        bone = side + "Arm"
        x = s * 1.38
        arm = m.piece(bone, "Cloth", bone=bone)
        block(arm, (0.6, 0.6, 1.7), loc=(x, 0, 3.08), rot=(0, -s * 5, 0), bottom=(0.9, 0.9), bevel=0.12)
        pad = m.piece(bone + "Pad", "Accent", bone=bone)
        k = mark(pad)
        lathe(pad, [(0.48, 3.56), (0.48, 3.76), (0.4, 4.0), (0.0, 4.12)], seg=8, phase=22.5, loc=(x + s * 0.04, 0, 0))
        turn(pad, k, (x, 0, 3.9), (0, s * 10, 0))
        bracer = m.piece(bone + "Bracer", "MetalDark", bone=bone)
        lathe(bracer, [(0.38, 2.42), (0.43, 2.95)], seg=8, phase=22.5, loc=(x + s * 0.07, -0.02, 0))
        glove = m.piece(bone + "Glove", "Leather", bone=bone)
        gauntlet_fist(glove, x + s * 0.08, z=2.16, size=(0.52, 0.56, 0.5))

    # the crossbow, in the right hand at the waist, aimed forward: wooden stock, steel
    # prod across the front, string drawn back to the nut, a loaded bolt, gold fittings
    hand = Vector((-1.46, -0.1, 2.16))
    front = Vector((-0.95, -2.5, 2.42))
    d = (front - hand).normalized()
    side = Vector((0, 0, 1)).cross(d).normalized()
    stock = m.piece("Crossbow", "Wood", bone="RightArm", shadow=True)
    sweep(stock, [hand - d * 0.6, hand + d * 0.3, front], [0.22, 0.19, 0.16], seg=6, sx=1.4, up=(0, 0, 1))
    prod = m.piece("CrossbowProd", "Blade", "Metal", bone="RightArm", shadow=True)
    tip = front - d * 0.12
    for k in (1, -1):
        sweep(prod, [tip, tip + side * k * 0.7 + d * 0.1, tip + side * k * 1.4 - d * 0.22],
              [0.14, 0.11, 0.07], seg=5, sx=1.5, up=(0, 0, 1))
    string = m.piece("CrossbowString", "Lace", bone="RightArm")
    nut = hand + d * 0.65
    for k in (1, -1):
        sweep(string, [tip + side * k * 1.4 - d * 0.22, nut + side * k * 0.05], [0.025, 0.025], seg=4)
    bolt = m.piece("CrossbowBolt", "Wood", bone="RightArm")
    sweep(bolt, [nut + Vector((0, 0, 0.14)), front + d * 0.3 + Vector((0, 0, 0.14))], [0.035, 0.035], seg=4)
    fit = m.piece("CrossbowTrim", "Gold", "Metal", bone="RightArm")
    band(fit, 0.12, 0.2, -0.08, 0.08, seg=6, loc=tip, rot=(90, 0, 0))
    fit.ico(0.11, loc=nut + Vector((0, 0, 0.12)), subdiv=0)
    sweep(fit, [tip + d * 0.08, tip + d * 0.42], [0.12, 0.0], seg=4)  # bolt head

    legs(m, "Cloth2", width=0.7)
    boots(m, "Leather", z_top=1.0)


# ---------------------------------------------------------------------------------- Bard

@register("Bard", "Heroes", "Travelling bard: crimson feathered cap with a long white plume, crimson doublet with "
                            "gold slashes and a lace ruff, short gold half-cape, a lute on the back and a curved "
                            "brass war horn in the left hand.")
def bard(m):
    rig(m, pal(Cloth="crimson_500", Cloth2="slate_800", Metal="leather_500", MetalDark="leather_700",
               Accent="gold_400", AccentDark="gold_600", Gold="gold_500", Hat="crimson_600",
               HatAccent="ivory_200", Hair="wood_700", Skin="skin_500", Wood="wood_500", Lace="ivory_200"))
    head(m)
    hair_short(m)
    hat_cap(m, HAT_ORIGIN, "Head")
    face = m.piece("FaceMoustache", "Hair", bone="Head")
    for s in (1, -1):
        sweep(face, [(s * 0.04, -0.72, HEAD_Z - 0.3), (s * 0.3, -0.72, HEAD_Z - 0.34), (s * 0.48, -0.66, HEAD_Z - 0.22)],
              [0.08, 0.06, 0.0], seg=4)

    # doublet: a fitted body with gold slashes, a peplum skirt and a lace ruff
    t = m.piece("Torso", "Cloth", bone="Torso", shadow=True)
    lathe(t, [(0.8, 2.2), (0.86, 2.7), (0.98, 3.3), (1.02, 3.85), (0.88, 4.28), (0.52, 4.48), (0.0, 4.52)],
          seg=8, phase=22.5, sx=1.06, sy=0.72)
    slash = m.piece("Slashes", "Accent", bone="Torso")
    for i in range(5):
        x = -0.56 + i * 0.28
        block(slash, (0.08, 0.06, 0.9), loc=(x, -0.74 - (0.04 if abs(x) < 0.2 else 0.0), 3.3), bevel=0)
    pep = m.piece("Peplum", "Cloth", bone="Torso")
    dag = lambda c: -0.18 if c % 2 else 0.0  # noqa: E731
    arc_shell(pep, [(0.92, 2.38, 0.0), (1.1, 1.85, 0.02), (1.2, 1.45, 0.04)], 0, 360, seg=12, thick=0.1,
              sx=1.06, sy=0.82, hem=dag)
    ruff = m.piece("Ruff", "Lace", bone="Torso")
    for k in range(10):
        a = k / 10 * math.tau
        ruff.ico(0.2, loc=(math.sin(a) * 0.62, -math.cos(a) * 0.48, 4.42), scale=(1.0, 1.0, 0.6), subdiv=0)
    belt = m.piece("Belt", "Leather", bone="Torso")
    band(belt, 0.86, 0.96, 2.24, 2.44, phase=22.5, sx=1.06, sy=0.8)
    pouch = m.piece("Pouch", "Metal", bone="Torso")
    block(pouch, (0.4, 0.3, 0.42), loc=(0.66, -0.66, 2.08), bevel=0.08)
    buckle = m.piece("Buckle", "Gold", "Metal", bone="Torso")
    block(buckle, (0.3, 0.12, 0.26), loc=(0, -0.82, 2.34), bevel=0.03)
    # half-cape over the left shoulder, gold
    cape = m.piece("Cape", "Accent", bone="Torso", shadow=True)
    arc_shell(cape, [(0.62, 4.56, 0.04), (1.02, 4.3, 0.08), (1.24, 3.4, 0.16), (1.3, 2.6, 0.22)], 60, 200,
              seg=6, thick=0.1, sx=1.06, sy=0.86)
    clasp = m.piece("CapeClasp", "Gold", "Metal", bone="Torso")
    clasp.ico(0.14, loc=(0.62, -0.58, 4.2), scale=(1, 0.6, 1), subdiv=1)

    # lute on the back, slung diagonally: pear body, sound hole, neck, bent peg head, strap
    body_c = Vector((0.3, 0.86, 2.9))
    up = Vector((-0.5, 0.06, 1.0)).normalized()
    lute = m.piece("Lute", "Wood", bone="Torso", shadow=True)
    lute.ico(0.62, loc=body_c, scale=(1.0, 0.42, 1.2), rot=(0, -27, 0), subdiv=1)
    hole = m.piece("LuteHole", "Dark", bone="Torso")
    hole.cyl(0.16, 0.16, 0.04, seg=8, loc=body_c + up * 0.25 + Vector((0, 0.27, 0)), rot=(90, 0, -27))
    neck = m.piece("LuteNeck", "Leather", bone="Torso")
    n0, n1 = body_c + up * 0.6, body_c + up * 2.0
    sweep(neck, [n0, n1], [0.1, 0.08], seg=4, sx=1.6, up=(1, 0, 0))
    peg = m.piece("LutePegs", "Gold", "Metal", bone="Torso")
    sweep(peg, [n1, n1 + up * 0.3 + Vector((0, 0.18, 0))], [0.11, 0.08], seg=4, sx=1.5, up=(1, 0, 0))
    strap = m.piece("LuteStrap", "Metal", bone="Torso")
    sweep(strap, [(0.86, -0.4, 4.2), (0.3, -0.76, 3.5), (-0.4, -0.74, 2.8), (-0.86, -0.4, 2.5)],
          [0.07, 0.07, 0.07, 0.07], seg=4, sx=1.8, up=(0, -1, 0))

    # puffed sleeves with gold slashes, leather gloves
    for s, side in SIDES:
        bone = side + "Arm"
        x = s * 1.38
        sleeve(m, bone, s, "Cloth", r=(0.46, 0.5, 0.52, 0.42))
        puff = m.piece(bone + "Slash", "Accent", bone=bone)
        k = mark(puff)
        for j in range(4):
            a = j / 4 * math.tau + 0.4
            block(puff, (0.08, 0.06, 0.6), loc=(x + math.sin(a) * 0.5, -math.cos(a) * 0.5, 3.2),
                  rot=(0, 0, math.degrees(a)), bevel=0)
        turn(puff, k, (x, 0, 3.95), (0, -s * 6, 0))
        glove = m.piece(bone + "Glove", "Leather", bone=bone)
        lathe(glove, [(0.36, 2.4), (0.42, 2.66)], seg=8, phase=22.5, loc=(x + s * 0.06, -0.02, 0))
        gauntlet_fist(glove, x + s * 0.08, z=2.16, size=(0.5, 0.54, 0.5))

    # the war horn in the left hand: a brass horn curving up and forward to a wide bell
    hnd = Vector((1.48, -0.12, 2.16))
    pts = [hnd + Vector((0.0, 0.3, -0.25)), hnd + Vector((0.05, 0.0, 0.0)), hnd + Vector((0.12, -0.45, 0.25)),
           hnd + Vector((0.18, -0.85, 0.65)), hnd + Vector((0.2, -1.05, 1.1))]
    horn = m.piece("WarHorn", "Gold", "Metal", bone="LeftArm", shadow=True)
    sweep(horn, pts, [0.06, 0.1, 0.14, 0.22, 0.38], seg=8)
    rim = m.piece("WarHornBand", "Cloth", bone="LeftArm")
    sweep(rim, [pts[1] + Vector((0.01, -0.15, 0.08)), pts[2]], [0.13, 0.15], seg=8)
    bell = m.piece("WarHornBell", "Dark", bone="LeftArm")
    d = (pts[4] - pts[3]).normalized()
    sweep(bell, [pts[4] - d * 0.02, pts[4] + d * 0.03], [0.3, 0.3], seg=8)

    legs(m, "Cloth2", width=0.64)
    boots(m, "Leather", z_top=1.15)


# ---------------------------------------------------------------------------------- Golem

def golem_crag(m, o, bone):
    """Stone brow cap with two rock horns and a moss tuft (the Golem's own headgear)."""
    crag = m.piece("Crag", "Hat", bone=bone, shadow=True)
    lathe(crag, [(0.98, -0.5), (1.02, -0.22), (0.9, 0.06), (0.6, 0.24), (0.0, 0.3)], seg=7, loc=o, sy=0.98)
    block(crag, (1.5, 0.3, 0.26), loc=(o[0], o[1] - 0.8, o[2] - 0.36), rot=(-8, 0, 0), bevel=0.08)  # brow
    horns = m.piece("CragHorns", "HatAccent", bone=bone)
    for s in (1, -1):
        sweep(horns, [(s * 0.72, 0.0, o[2] - 0.2), (s * 1.12, -0.1, o[2] + 0.1), (s * 1.28, -0.2, o[2] + 0.55),
                      (s * 1.2, -0.3, o[2] + 0.9)], [0.26, 0.2, 0.12, 0.0], seg=5, up=(0, 1, 0))
    moss = m.piece("CragMoss", "Accent", bone=bone)
    moss.ico(0.36, loc=(o[0] + 0.25, o[1] + 0.1, o[2] + 0.22), scale=(1.3, 1.1, 0.45), subdiv=1, jitter=0.15, seed=3)


@register("Golem", "Heroes", "Living stone guardian: a boulder chest with glowing amber cracks and a rune, a "
                             "craggy stone brow with rock horns and amber eyes, moss on the shoulders, huge "
                             "stone arms and fists, thick stone legs.")
def golem(m):
    rig(m, pal(Metal="stone_400", MetalDark="stone_600", Cloth="moss_600", Cloth2="stone_700",
               Accent="moss_400", AccentDark="moss_700", Gold="gold_500", Hat="stone_500",
               HatAccent="stone_200", Skin="stone_300", Hair="stone_500", Glow="amber_300", Rock="stone_500"))
    head(m)
    eyes = m.piece("FaceGlow", "Glow", "Neon", bone="Head")
    for s in (1, -1):
        block(eyes, (0.26, 0.06, 0.16), loc=(s * 0.27, -0.7, HEAD_Z + 0.02), bevel=0)
    jaw = m.piece("FaceJaw", "Skin", bone="Head")
    block(jaw, (1.2, 0.5, 0.36), loc=(0, -0.42, HEAD_Z - 0.62), bottom=(0.85, 0.9), bevel=0.08)
    golem_crag(m, HAT_ORIGIN, "Head")

    # boulder chest: wide and deep, a shelf of stone plates, cracks and a rune
    t = m.piece("Torso", "Metal", bone="Torso", shadow=True)
    lathe(t, [(0.84, 2.1), (0.98, 2.6), (1.16, 3.2), (1.24, 3.8), (1.1, 4.25), (0.66, 4.5), (0.0, 4.55)],
          seg=7, phase=0, sx=1.16, sy=0.84)
    plate = m.piece("ChestPlates", "MetalDark", bone="Torso", shadow=True)
    for s in (1, -1):
        block(plate, (0.9, 0.4, 0.8), loc=(s * 0.5, -0.86, 3.75), rot=(-8, 0, s * 8), top=(0.85, 0.8), bevel=0.1)
    block(plate, (1.5, 0.5, 0.5), loc=(0, -0.8, 2.6), rot=(6, 0, 0), bevel=0.1)
    crack = m.piece("Cracks", "Glow", "Neon", bone="Torso")
    rune_c = Vector((0, -1.06, 3.2))
    slab(crack, [(0, 0.22), (0.18, 0), (0, -0.22), (-0.18, 0)], 0.06, loc=rune_c)
    for k, (dx, dz) in enumerate(((0.5, 0.35), (-0.45, 0.4), (0.35, -0.42), (-0.4, -0.38))):
        sweep(crack, [rune_c + Vector((dx * 0.35, 0.02, dz * 0.35)), rune_c + Vector((dx, 0.06, dz)),
                      rune_c + Vector((dx * 1.4, 0.12, dz * 1.2 + (0.08 if k % 2 else -0.08)))],
              [0.04, 0.035, 0.0], seg=4)
    moss = m.piece("Moss", "Accent", bone="Torso")
    moss.ico(0.5, loc=(0.55, 0.3, 4.35), scale=(1.2, 1.3, 0.4), subdiv=1, jitter=0.18, seed=5)
    moss.ico(0.4, loc=(-0.6, 0.55, 3.9), scale=(1.0, 1.0, 0.45), subdiv=1, jitter=0.18, seed=6)
    vine = m.piece("VineBelt", "Cloth", bone="Torso")
    band(vine, 0.92, 1.05, 2.15, 2.4, seg=7, sx=1.16, sy=0.88)
    rocks = m.piece("Rocks", "Rock", bone="Torso", shadow=True)
    for i, (x, y, z, r) in enumerate(((0.0, 0.95, 3.6, 0.42), (0.5, 0.9, 2.9, 0.32), (-0.55, 0.88, 3.1, 0.3))):
        rocks.ico(r, loc=(x, y, z), subdiv=1, jitter=0.2, seed=10 + i)

    # huge arms: stone upper arm, boulder pauldron with moss, a big blocky fist
    for s, side in SIDES:
        bone = side + "Arm"
        x = s * 1.6
        arm = m.piece(bone, "Metal", bone=bone)
        block(arm, (0.86, 0.86, 1.7), loc=(x, 0, 3.0), rot=(0, -s * 6, 0), bottom=(0.9, 0.9), bevel=0.14)
        pad = m.piece(bone + "Boulder", "MetalDark", bone=bone, shadow=True)
        pad.ico(0.82, loc=(x + s * 0.08, 0, 3.95), scale=(1.05, 1.0, 0.72), subdiv=1, jitter=0.12, seed=20 + s)
        tuft = m.piece(bone + "Moss", "Accent", bone=bone)
        tuft.ico(0.5, loc=(x + s * 0.06, 0.05, 4.45), scale=(1.0, 1.0, 0.35), subdiv=1, jitter=0.2, seed=30 + s)
        fist = m.piece(bone + "Fist", "Metal", bone=bone, shadow=True)
        block(fist, (1.0, 1.0, 0.86), loc=(x + s * 0.06, -0.06, 1.95), bottom=(0.88, 0.88), bevel=0.16)
        knuckle = m.piece(bone + "Knuckles", "MetalDark", bone=bone)
        for j in range(3):
            block(knuckle, (0.26, 0.2, 0.22), loc=(x + s * 0.06 + (j - 1) * 0.3, -0.58, 2.1), bevel=0.05)

    # thick stone legs and wide feet
    for s, side in SIDES:
        bone = side + "Leg"
        leg = m.piece(bone, "Cloth2", bone=bone)
        block(leg, (0.88, 0.9, 1.6), loc=(s * 0.56, 0, 1.25), bottom=(0.92, 0.92), bevel=0.14)
        foot = m.piece(bone + "Foot", "MetalDark", bone=bone, shadow=True)
        block(foot, (1.0, 1.3, 0.56), loc=(s * 0.58, -0.14, 0.28), top=(0.9, 0.8), shift=(0, 0.08), bevel=0.14)
