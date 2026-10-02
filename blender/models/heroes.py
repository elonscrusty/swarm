"""The four heroes: Knight, Mage, Rogue, Priest (heroic low-poly fantasy, docs/ART_DIRECTION.md).

Shared rig (Blender: z up, front -Y, the character's LEFT is +X = Roblox -X). Every hero uses
the same skeleton so poses, hats and the part-built fallback line up:
  feet at z = 0, hips z = 2.0 (x +-0.5), shoulders z = 3.95 (x +-1.2), neck z = 4.45,
  HumanoidRootPart 2x2x1 centred at z = 3 (unchanged), standard bare head 1.45 x 1.35 x 1.4
  centred at z = 5.15 (top 5.85, see models/hats.py), 6.9-7.2 studs tall with headgear.
Six bone pieces (Torso, Head, LeftArm, RightArm, LeftLeg, RightLeg, each named like its
bone); every other piece names the bone it is welded to. Head-bone pieces called "Head",
"Eyes" or "Face*" are the face and stay when a skin swaps the headgear for a hat; every other
Head-bone piece is headgear and is removed then.

Colour slots (skins recolour these; see CharacterData.MeshPalette):
  Hat / HatAccent       headgear and its plume / band (defaults follow Metal / Accent)
  Metal / MetalDark     main armour (Rogue: leather armour) and its shade
  Cloth / Cloth2        main fabric, secondary fabric and legs
  Accent / AccentDark   cape, scarf, stole, mantle
  Gold                  trims, guards, buckles
Fixed: Skin, Hair, Dark, Leather, Wood, Blade, Glow (Neon, tiny magic cores only), Book.
"""

import math

from mathutils import Euler, Vector

from models.hats import (HEAD_SIZE, HEAD_TOP, HEAD_Z, aim, arc_shell, band, block, hat_helmet, hat_hood,
                         hat_mitre, hat_wizard, lathe, mark, revolve, slab, sweep, turn)
from style import P
from swarmkit import register

JOINTS = {
    "Neck": (0.0, 0.0, 4.45),
    "LeftShoulder": (1.2, 0.0, 3.95),
    "RightShoulder": (-1.2, 0.0, 3.95),
    "LeftHip": (0.5, 0.0, 2.0),
    "RightHip": (-0.5, 0.0, 2.0),
}
HAT_ORIGIN = (0.0, 0.0, HEAD_TOP)
SIDES = ((1, "Left"), (-1, "Right"))


def palette(**slots):
    base = {"Skin": "skin_400", "Hair": "wood_700", "Dark": "slate_950", "Leather": "leather_600",
            "Wood": "wood_500", "Blade": "steel_300", "Glow": "fx_arcane"}
    base.update(slots)
    return {k: P(v) for k, v in base.items()}


def rig(m, pal):
    m.extra["joints"] = dict(JOINTS)
    m.extra["palette"] = pal


def turned(v, rot):
    return Euler([math.radians(a) for a in rot], "XYZ").to_matrix() @ Vector(v)


# ---------------------------------------------------------------------------------- shared body

def head(m):
    """The plain standard head (a heavily chamfered block, so round hats enclose it) and eyes."""
    h = m.piece("Head", "Skin", bone="Head", shadow=True)
    block(h, HEAD_SIZE, loc=(0, 0, HEAD_Z), bottom=(0.94, 0.96), bevel=0.34)
    eyes = m.piece("Eyes", "Dark", bone="Head")
    for x in (-0.27, 0.27):
        block(eyes, (0.16, 0.08, 0.28), loc=(x, -0.665, HEAD_Z - 0.03), bevel=0)


def brows(p, z=5.38, tilt=10, y=-0.69):
    for s in (1, -1):
        block(p, (0.34, 0.1, 0.11), loc=(s * 0.27, y, z), rot=(0, s * -tilt, 0), bevel=0)


def hair_cap(m, back_to=4.9, front=5.6):
    """Hair inside the standard envelope: an octagonal cap over the top (down to `front` at the
    forehead) and a shell round the sides and back (down to `back_to`)."""
    h = m.piece("FaceHair", "Hair", bone="Head")
    lathe(h, [(0.86, front), (0.88, 5.76), (0.74, 5.9), (0.0, 5.93)], seg=8, phase=22.5, loc=(0, 0.03, 0),
          sy=0.96)
    arc_shell(h, [(0.88, front + 0.02, 0.03), (0.86, back_to, 0.05)], 62, 298, seg=6, thick=0.12, sy=0.96)
    return h


def hair_short(m, fringe=True):
    h = hair_cap(m)
    if fringe:
        for i, x in enumerate((-0.42, -0.08, 0.26)):
            block(h, (0.4, 0.16, 0.3), loc=(x, -0.68, 5.6), rot=(0, 18 - i * 10, 0), bevel=0)
    brows(h)
    return h


def gauntlet_fist(p, x, z=2.12, size=(0.62, 0.66, 0.58)):
    block(p, size, loc=(x, -0.04, z), bottom=(0.92, 0.9), bevel=0.14)


def boots(m, slot="Leather", z_top=0.78, cuff=True):
    for s, side in SIDES:
        bone = side + "Leg"
        b = m.piece(bone + "Boot", slot, bone=bone)
        x = s * 0.52
        block(b, (0.8, 1.16, 0.46), loc=(x, -0.14, 0.23), top=(0.9, 0.82), shift=(0, 0.08), bevel=0.12)
        block(b, (0.76, 0.82, z_top - 0.3), loc=(x, 0.0, 0.3 + (z_top - 0.3) / 2), bevel=0.08)
        if cuff:
            block(b, (0.86, 0.9, 0.2), loc=(x, 0.0, z_top), bevel=0.06)


def legs(m, slot="Cloth2", width=0.74):
    for s, side in SIDES:
        bone = side + "Leg"
        leg = m.piece(bone, slot, bone=bone)
        block(leg, (width, 0.8, 1.6), loc=(s * 0.52, 0, 1.25), bottom=(0.9, 0.92), bevel=0.12)


def kite(w, h):
    """Kite-shield outline (x, z), centred on the origin."""
    return [(-0.5 * w, 0.26 * h), (-0.48 * w, 0.4 * h), (-0.36 * w, 0.48 * h), (0, 0.51 * h), (0.36 * w, 0.48 * h),
            (0.48 * w, 0.4 * h), (0.5 * w, 0.26 * h), (0.42 * w, -0.05 * h), (0.25 * w, -0.29 * h), (0, -0.5 * h),
            (-0.25 * w, -0.29 * h), (-0.42 * w, -0.05 * h)]


def scaled(outline, k):
    return [(x * k, z * k) for x, z in outline]


# ---------------------------------------------------------------------------------- Knight

@register("Knight", "Heroes", "The reference hero: silver plate, great helm with a dark T visor and crimson "
                              "plume, crimson cape with gold trim, crimson kite shield, steel longsword.")
def knight(m):
    rig(m, palette(Metal="steel_400", MetalDark="steel_600", Cloth="slate_600", Cloth2="slate_700",
                   Accent="crimson_500", AccentDark="crimson_700", Gold="gold_500",
                   Hat="steel_400", HatAccent="crimson_500", Hair="wood_700"))
    head(m)
    hair_short(m)
    hat_helmet(m, HAT_ORIGIN, "Head")

    # torso: faceted breastplate with a front ridge, stepped plate skirt, belt, cape
    t = m.piece("Torso", "Metal", "Metal", bone="Torso", shadow=True)
    lathe(t, [(0.78, 2.3), (0.86, 2.75), (1.0, 3.3), (1.06, 3.85), (0.96, 4.28), (0.6, 4.5), (0.0, 4.54)],
          seg=8, sx=1.12, sy=0.66)
    f = m.piece("Faulds", "MetalDark", "Metal", bone="Torso")
    lathe(f, [(0.95, 1.86), (0.84, 2.34)], seg=8, sx=1.12, sy=0.74)
    lathe(f, [(1.08, 1.46), (0.97, 1.94)], seg=8, sx=1.12, sy=0.74)
    tunic = m.piece("Tunic", "Cloth", bone="Torso")
    lathe(tunic, [(1.04, 1.18), (0.98, 1.56)], seg=8, phase=22.5, sx=1.1, sy=0.74)
    belt = m.piece("Belt", "Leather", bone="Torso")
    band(belt, 0.76, 0.86, 2.24, 2.46, sx=1.12, sy=0.72)
    trim = m.piece("Trim", "Gold", "Metal", bone="Torso")
    block(trim, (0.4, 0.14, 0.32), loc=(0, -0.64, 2.35), bevel=0)
    hem = lambda c: -0.14 * (1 - abs(c - 4) / 4)  # noqa: E731  (cape longer in the middle)
    arc_shell(trim, [(1.01, 4.48, 0.07), (1.03, 4.3, 0.09)], 96, 264, seg=8, thick=0.15, sx=1.12, sy=0.74)
    arc_shell(trim, [(1.365, 1.2, 0.565), (1.375, 1.03, 0.585)], 98, 262, seg=8, thick=0.15, sx=1.12, sy=0.74,
              hem=hem)
    cape = m.piece("Cape", "Accent", bone="Torso", shadow=True)
    arc_shell(cape, [(0.98, 4.4, 0.08), (1.12, 3.9, 0.14), (1.22, 2.9, 0.28), (1.3, 1.9, 0.44),
                     (1.35, 1.05, 0.58)], 98, 262, seg=8, thick=0.12, sx=1.12, sy=0.74, hem=hem)

    # arms: plate sleeves, big domed pauldrons with gold rims, oversized gauntlets
    for s, side in SIDES:
        bone = side + "Arm"
        x = s * 1.43
        arm = m.piece(bone, "MetalDark", "Metal", bone=bone)
        block(arm, (0.6, 0.62, 1.7), loc=(x, 0, 3.05), rot=(0, -s * 5, 0), bottom=(0.9, 0.9), bevel=0.12)
        pad = m.piece(bone + "Pauldron", "Metal", "Metal", bone=bone)
        k = mark(pad)
        lathe(pad, [(0.76, 3.5), (0.74, 3.64), (0.74, 3.86), (0.62, 4.14), (0.34, 4.3), (0.0, 4.34)], seg=8,
              phase=22.5, loc=(x + s * 0.06, 0, 0), sy=0.94)
        turn(pad, k, (x, 0, 3.9), (0, s * 14, 0))
        rim = m.piece(bone + "Trim", "Gold", "Metal", bone=bone)
        k = mark(rim)
        band(rim, 0.7, 0.81, 3.44, 3.56, phase=22.5, loc=(x + s * 0.06, 0, 0), sy=0.94)
        turn(rim, k, (x, 0, 3.9), (0, s * 14, 0))
        glove = m.piece(bone + "Gauntlet", "Metal", "Metal", bone=bone)
        lathe(glove, [(0.35, 2.4), (0.42, 2.7)], seg=8, phase=22.5, loc=(x + s * 0.07, -0.02, 0))
        gauntlet_fist(glove, x + s * 0.08)

    # left arm: big crimson kite shield with a gold rim and cross, turned toward the front
    sh, rot = Vector((2.04, -0.3, 2.62)), (-14, 0, 54)
    n = turned((0, -1, 0), rot)
    outline = kite(1.52, 2.2)
    rim = m.piece("ShieldRim", "Gold", "Metal", bone="LeftArm")
    slab(rim, outline, 0.16, loc=sh, rot=rot)
    slab(rim, [(-0.11, -0.74), (0.11, -0.74), (0.11, 0.86), (-0.11, 0.86)], 0.08, loc=sh + n * 0.15, rot=rot)
    slab(rim, [(-0.52, 0.25), (0.52, 0.25), (0.52, 0.47), (-0.52, 0.47)], 0.08, loc=sh + n * 0.15, rot=rot)
    face = m.piece("Shield", "Accent", bone="LeftArm", shadow=True)
    slab(face, scaled(outline, 0.86), 0.12, loc=sh + n * 0.07, rot=rot, bevel=0.05)

    # right arm: steel longsword with a gold crossguard, blade forward and down
    hand = Vector((-1.51, -0.04, 2.12))
    d = Vector((-0.1, -0.86, -0.46)).normalized()
    g = hand + d * 0.44
    blade = m.piece("SwordBlade", "Blade", "Metal", bone="RightArm")
    sweep(blade, [g, g + d * 0.3, g + d * 2.1, g + d * 2.62], [0.08, 0.08, 0.075, 0.0], seg=4, sx=3.2,
          up=(1, 0, 0.6))
    hilt = m.piece("SwordHilt", "Gold", "Metal", bone="RightArm")
    block(hilt, (1.02, 0.2, 0.22), loc=g, rot=aim(d), bevel=0.06)
    sweep(hilt, [hand - d * 0.36, g], [0.08, 0.08], seg=6)
    hilt.ico(0.15, loc=hand - d * 0.44, subdiv=1)

    # legs: dark chausses, greaves with knee cops, sabatons
    legs(m, "Cloth2")
    for s, side in SIDES:
        bone = side + "Leg"
        x = s * 0.52
        a = m.piece(bone + "Armor", "Metal", "Metal", bone=bone)
        block(a, (0.84, 0.92, 0.66), loc=(x, -0.02, 0.8), bottom=(0.92, 0.94), bevel=0.1)
        block(a, (0.5, 0.26, 0.42), loc=(x, -0.44, 1.18), rot=(-12, 0, 0), top=(0.8, 1.0), bevel=0)
        block(a, (0.9, 1.26, 0.48), loc=(x, -0.17, 0.24), top=(0.86, 0.78), shift=(0, 0.1), bevel=0.1)


# ---------------------------------------------------------------------------------- Mage

@register("Mage", "Heroes", "Slate-blue robes and mantle, wide-brim pointed hat with a gold band, ivory beard, "
                            "wooden staff with a small arcane crystal, leather belt and satchel.")
def mage(m):
    rig(m, palette(Cloth="slate_400", Cloth2="slate_600", Accent="slate_700", AccentDark="slate_800",
                   Gold="gold_500", Hat="slate_500", HatAccent="gold_500", Metal="slate_500", MetalDark="slate_600",
                   Hair="ivory_200", Skin="skin_400"))
    head(m)
    hair = hair_cap(m, back_to=4.35)
    brows(hair, z=5.4, tilt=-8, y=-0.7)
    block(hair, (1.0, 0.26, 0.24), loc=(0, -0.76, HEAD_Z - 0.3), bottom=(0.7, 1.0), bevel=0)  # moustache
    sweep(hair, [(0, -0.5, 5.0), (0, -0.66, 4.55), (0, -0.78, 4.05), (0, -0.84, 3.62)], [0.42, 0.4, 0.24, 0.0],
          seg=6, sx=1.55, up=(1, 0, 0))  # beard, a fat point on the chest
    hat_wizard(m, HAT_ORIGIN, "Head")

    t = m.piece("Torso", "Cloth", bone="Torso", shadow=True)
    lathe(t, [(0.84, 2.2), (0.9, 2.75), (0.98, 3.3), (1.0, 3.85), (0.9, 4.28), (0.56, 4.48), (0.0, 4.52)],
          seg=8, phase=22.5, sx=1.06, sy=0.72)
    robe = m.piece("Robe", "Cloth", bone="Torso", shadow=True)
    lathe(robe, [(1.34, 0.08), (1.24, 0.6), (1.08, 1.4), (0.94, 2.2), (0.9, 2.5)], seg=8, phase=22.5,
          sx=1.04, sy=0.86)
    front = m.piece("RobeFront", "Cloth2", bone="Torso")
    panel = [(-0.26, 1.08), (0.26, 1.08), (0.46, -1.04), (-0.46, -1.04)]
    slab(front, panel, 0.1, loc=(0, -0.94, 1.14), rot=(-8.5, 0, 0), bevel=0.03)
    mantle = m.piece("Mantle", "Accent", bone="Torso", shadow=True)
    arc_shell(mantle, [(0.62, 4.52, 0.0), (1.02, 4.24, 0.0), (1.28, 3.8, 0.03), (1.34, 3.52, 0.05)], 0, 360,
              seg=10, thick=0.13, sx=1.06, sy=0.8)
    trim = m.piece("RobeTrim", "Gold", "Metal", bone="Torso")
    revolve(trim, [(1.31, 0.05), (1.39, 0.05), (1.37, 0.22), (1.29, 0.22)], seg=8, phase=22.5, sx=1.04, sy=0.86)
    slab(trim, [(x * 1.25, z * 1.02) for x, z in panel], 0.08, loc=(0, -0.92, 1.14), rot=(-8.5, 0, 0), bevel=0.02)
    arc_shell(trim, [(1.35, 3.6, 0.05), (1.36, 3.48, 0.055)], 0, 360, seg=10, thick=0.12, sx=1.06, sy=0.8)
    belt = m.piece("Belt", "Leather", bone="Torso")
    band(belt, 0.88, 0.98, 2.38, 2.58, phase=22.5, sx=1.06, sy=0.78)
    sweep(belt, [(-0.78, -0.58, 4.05), (-0.2, -0.78, 3.35), (0.45, -0.74, 2.75), (0.82, -0.6, 2.4)],
          [0.07, 0.07, 0.07, 0.07], seg=4, sx=1.8, up=(0, -1, 0))
    block(belt, (0.56, 0.32, 0.58), loc=(1.02, -0.3, 2.12), rot=(0, 0, -18), bevel=0.08)  # satchel
    block(belt, (0.6, 0.36, 0.2), loc=(1.02, -0.32, 2.4), rot=(0, 0, -18), bevel=0.06)
    buckle = m.piece("Buckle", "Gold", "Metal", bone="Torso")
    block(buckle, (0.3, 0.12, 0.26), loc=(0, -0.77, 2.48), bevel=0.03)
    block(buckle, (0.14, 0.1, 0.14), loc=(0.98, -0.5, 2.26), rot=(0, 0, -18), bevel=0.02)

    for s, side in SIDES:
        bone = side + "Arm"
        x = s * 1.38
        sleeve = m.piece(bone, "Cloth", bone=bone)
        k = mark(sleeve)
        lathe(sleeve, [(0.5, 2.42), (0.44, 2.75), (0.36, 3.4), (0.34, 3.95), (0.0, 4.12)], seg=8, phase=22.5,
              loc=(x, 0, 0))
        turn(sleeve, k, (x, 0, 3.95), (0, -s * 6, 0))
        cuff = m.piece(bone + "Cuff", "Cloth2", bone=bone)
        k = mark(cuff)
        band(cuff, 0.4, 0.53, 2.38, 2.52, phase=22.5, loc=(x, 0, 0))
        turn(cuff, k, (x, 0, 3.95), (0, -s * 6, 0))
        hand = m.piece(bone + "Hand", "Skin", bone=bone)
        block(hand, (0.44, 0.48, 0.46), loc=(x + s * 0.16, -0.08, 2.2), bevel=0.12)

    # staff in the right hand, leaning a little forward and out, crystal held in a wooden crook
    base, top = Vector((-1.5, -0.2, 0.15)), Vector((-1.66, -0.4, 4.95))
    staff = m.piece("Staff", "Wood", bone="RightArm")
    sweep(staff, [base, (base + top) / 2, top], [0.11, 0.12, 0.13], seg=6)
    for i in range(3):
        a = math.radians(90 + i * 120)
        out = Vector((math.cos(a), math.sin(a), 0))
        sweep(staff, [top + Vector((0, 0, -0.05)), top + out * 0.22 + Vector((0, 0, 0.22)),
                      top + out * 0.2 + Vector((0, 0, 0.5)), top + out * 0.06 + Vector((0, 0, 0.66))],
              [0.07, 0.06, 0.045, 0.0], seg=4)
    ring = m.piece("StaffTrim", "Gold", "Metal", bone="RightArm")
    band(ring, 0.08, 0.15, -0.08, 0.08, loc=top + Vector((0, 0, -0.12)))
    band(ring, 0.07, 0.12, -0.06, 0.06, loc=base + Vector((0, 0, 0.12)))
    crystal = m.piece("StaffCrystal", "Glow", "Neon", bone="RightArm")
    lathe(crystal, [(0.0, -0.24), (0.19, 0.0), (0.0, 0.3)], seg=4, loc=top + Vector((0, 0, 0.38)), phase=45)

    legs(m, "Cloth2", width=0.7)
    boots(m, "Leather", z_top=0.62, cuff=False)


# ---------------------------------------------------------------------------------- Rogue

@register("Rogue", "Heroes", "Moss-green hooded cloak, leather armour, crimson scarf and mask, twin steel daggers.")
def rogue(m):
    rig(m, palette(Cloth="moss_800", Cloth2="stone_700", Accent="crimson_500", AccentDark="crimson_700",
                   Metal="leather_500", MetalDark="leather_700", Gold="gold_600", Hat="moss_700",
                   HatAccent="crimson_500", Hair="wood_800", Skin="skin_500", Blade="steel_300"))
    head(m)
    hair_short(m)
    hat_hood(m, HAT_ORIGIN, "Head")
    mask = m.piece("Mask", "Accent", bone="Head")
    block(mask, (1.54, 1.0, 0.64), loc=(0, -0.2, 4.78), top=(1.0, 1.0), bevel=0.16)
    block(mask, (0.5, 0.2, 0.42), loc=(0, -0.72, 4.84), top=(0.5, 1.0), bevel=0.05)

    t = m.piece("Torso", "Metal", bone="Torso", shadow=True)
    lathe(t, [(0.8, 2.2), (0.84, 2.7), (0.94, 3.3), (0.98, 3.85), (0.86, 4.28), (0.5, 4.48), (0.0, 4.52)],
          seg=8, phase=22.5, sx=1.08, sy=0.68)
    skirt = m.piece("Tassets", "MetalDark", bone="Torso")
    lathe(skirt, [(1.0, 1.5), (0.94, 1.9), (0.86, 2.3)], seg=8, phase=22.5, sx=1.08, sy=0.74)
    belt = m.piece("Belt", "Leather", bone="Torso")
    band(belt, 0.84, 0.94, 2.22, 2.42, phase=22.5, sx=1.08, sy=0.74)
    sweep(belt, [(0.8, -0.5, 4.15), (0.25, -0.72, 3.45), (-0.4, -0.7, 2.85), (-0.85, -0.52, 2.45)],
          [0.08, 0.08, 0.08, 0.08], seg=4, sx=1.8, up=(0, -1, 0))
    for x in (-0.62, 0.6):
        block(belt, (0.4, 0.3, 0.38), loc=(x, -0.7, 2.06), bevel=0.08)
    buckle = m.piece("Buckle", "Gold", "Metal", bone="Torso")
    block(buckle, (0.3, 0.12, 0.26), loc=(0, -0.72, 2.32), bevel=0.03)
    block(buckle, (0.18, 0.1, 0.18), loc=(0.06, -0.8, 3.24), rot=(0, 0, 12), bevel=0.02)

    cloak = m.piece("Cloak", "Cloth", bone="Torso", shadow=True)
    tatter = lambda c: -0.2 if c % 2 else 0.0  # noqa: E731
    arc_shell(cloak, [(0.96, 4.4, 0.07), (1.06, 3.9, 0.12), (1.14, 2.8, 0.24), (1.2, 1.7, 0.36),
                      (1.23, 1.22, 0.42)], 98, 262, seg=8, thick=0.1, sx=1.08, sy=0.72, hem=tatter)
    scarf = m.piece("Scarf", "Accent", bone="Torso", shadow=True)
    revolve(scarf, [(0.55, 4.0), (1.16, 3.92), (1.22, 4.14), (1.0, 4.38), (0.52, 4.46)], seg=8, phase=22.5,
            sx=1.08, sy=0.9)
    sweep(scarf, [(0.36, 0.7, 4.3), (0.5, 1.0, 3.95), (0.56, 1.1, 3.4), (0.62, 1.1, 2.85)],
          [0.1, 0.1, 0.09, 0.015], seg=4, sx=2.4, up=(1, 0, 0))

    for s, side in SIDES:
        bone = side + "Arm"
        x = s * 1.38
        arm = m.piece(bone, "Cloth2", bone=bone)
        block(arm, (0.56, 0.58, 1.7), loc=(x, 0, 3.08), rot=(0, -s * 5, 0), bottom=(0.9, 0.9), bevel=0.12)
        bracer = m.piece(bone + "Bracer", "MetalDark", bone=bone)
        lathe(bracer, [(0.36, 2.42), (0.4, 2.86)], seg=8, phase=22.5, loc=(x + s * 0.07, -0.02, 0))
        glove = m.piece(bone + "Glove", "Leather", bone=bone)
        gauntlet_fist(glove, x + s * 0.08, z=2.16, size=(0.52, 0.56, 0.5))
    # twin daggers, blades forward and a little down (the left one angled out)
    for s, side, d in ((1, "Left", Vector((0.22, -0.88, -0.36))), (-1, "Right", Vector((-0.1, -0.9, -0.3)))):
        bone = side + "Arm"
        d = d.normalized()
        hand = Vector((s * 1.46, -0.04, 2.16))
        g = hand + d * 0.34
        blade = m.piece(bone + "Dagger", "Blade", "Metal", bone=bone)
        sweep(blade, [g, g + d * 0.28, g + d * 1.05, g + d * 1.42], [0.075, 0.08, 0.06, 0.0], seg=4, sx=2.3)
        hilt = m.piece(bone + "DaggerHilt", "Gold", "Metal", bone=bone)
        block(hilt, (0.62, 0.14, 0.16), loc=g, rot=aim(d), bevel=0.05)
        hilt.ico(0.1, loc=hand - d * 0.34, subdiv=0)

    legs(m, "Cloth2", width=0.68)
    boots(m, "Leather", z_top=0.95)


# ---------------------------------------------------------------------------------- Priest

@register("Priest", "Heroes", "Ivory robes with a gold stole, mitre, golden sun staff and a small book.")
def priest(m):
    rig(m, palette(Cloth="ivory_100", Cloth2="ivory_300", Accent="gold_600", AccentDark="gold_700",
                   Gold="gold_400", Hat="ivory_100", HatAccent="gold_500", Metal="ivory_200", MetalDark="ivory_400",
                   Hair="dirt_300", Skin="skin_400", Glow="fx_gold", Book="crimson_700"))
    head(m)
    hair = hair_cap(m, back_to=5.2)
    brows(hair, z=5.38, tilt=4)
    hat_mitre(m, HAT_ORIGIN, "Head")

    t = m.piece("Torso", "Cloth", bone="Torso", shadow=True)
    lathe(t, [(0.86, 2.2), (0.92, 2.75), (1.0, 3.3), (1.02, 3.85), (0.92, 4.28), (0.56, 4.48), (0.0, 4.52)],
          seg=8, phase=22.5, sx=1.06, sy=0.72)
    robe = m.piece("Robe", "Cloth", bone="Torso", shadow=True)
    lathe(robe, [(1.42, 0.08), (1.3, 0.6), (1.1, 1.45), (0.96, 2.2), (0.92, 2.5)], seg=8, phase=22.5,
          sx=1.05, sy=0.86)
    inner = m.piece("RobeFront", "Cloth2", bone="Torso")
    panel = [(-0.3, 1.08), (0.3, 1.08), (0.5, -1.04), (-0.5, -1.04)]
    slab(inner, panel, 0.1, loc=(0, -0.97, 1.14), rot=(-9, 0, 0), bevel=0.03)
    stole = m.piece("Stole", "Accent", bone="Torso")
    band(stole, 0.56, 0.7, 4.3, 4.5, phase=22.5, sx=1.08, sy=0.84)
    for s in (1, -1):
        slab(stole, [(-0.13, 0.98), (0.13, 0.98), (0.13, -0.98), (-0.13, -0.98)], 0.08,
             loc=(s * 0.3, -0.69, 3.42), rot=(-2, 0, 0), bevel=0.02)
        slab(stole, [(-0.13, 1.0), (0.13, 1.0), (0.2, -0.98), (-0.2, -0.98)], 0.08,
             loc=(s * 0.33, -1.08, 1.46), rot=(-9, 0, 0), bevel=0.02)
    trim = m.piece("RobeTrim", "Gold", "Metal", bone="Torso")
    revolve(trim, [(1.39, 0.05), (1.47, 0.05), (1.45, 0.22), (1.37, 0.22)], seg=8, phase=22.5, sx=1.05, sy=0.86)
    band(trim, 0.9, 1.0, 2.36, 2.56, phase=22.5, sx=1.06, sy=0.76)
    for s in (1, -1):
        slab(trim, [(-0.05, -0.16), (0.05, -0.16), (0.05, 0.16), (-0.05, 0.16)], 0.06, loc=(s * 0.34, -1.2, 0.72),
             rot=(-9, 0, 0), bevel=0.01)
        slab(trim, [(-0.13, -0.04), (0.13, -0.04), (0.13, 0.05), (-0.13, 0.05)], 0.06, loc=(s * 0.34, -1.2, 0.76),
             rot=(-9, 0, 0), bevel=0.01)
    sweep(trim, [(0.5, -0.86, 2.4), (0.56, -0.92, 2.0), (0.6, -0.98, 1.62)], [0.06, 0.05, 0.04], seg=4)
    trim.ico(0.09, loc=(0.6, -0.98, 1.58), subdiv=0)

    for s, side in SIDES:
        bone = side + "Arm"
        x = s * 1.38
        sleeve = m.piece(bone, "Cloth", bone=bone)
        k = mark(sleeve)
        lathe(sleeve, [(0.52, 2.42), (0.46, 2.75), (0.37, 3.4), (0.35, 3.95), (0.0, 4.14)], seg=8, phase=22.5,
              loc=(x, 0, 0))
        turn(sleeve, k, (x, 0, 3.95), (0, -s * 6, 0))
        cuff = m.piece(bone + "Cuff", "Gold", "Metal", bone=bone)
        k = mark(cuff)
        band(cuff, 0.44, 0.55, 2.38, 2.5, phase=22.5, loc=(x, 0, 0))
        turn(cuff, k, (x, 0, 3.95), (0, -s * 6, 0))
        hand = m.piece(bone + "Hand", "Skin", bone=bone)
        block(hand, (0.44, 0.48, 0.46), loc=(x + s * 0.16, -0.08, 2.2), bevel=0.12)

    # golden sun staff: a rayed disc facing forward and up, a tiny light at its heart
    base, top = Vector((-1.5, -0.22, 0.15)), Vector((-1.62, -0.36, 4.85))
    staff = m.piece("Staff", "Gold", "Metal", bone="RightArm")
    sweep(staff, [base, (base + top) / 2, top], [0.085, 0.09, 0.1], seg=6)
    sun_c, srot = top + Vector((0, -0.04, 0.42)), (55, 0, 0)
    sun = m.piece("StaffSun", "Gold", "Metal", bone="RightArm")
    sun.cyl(0.32, 0.32, 0.14, seg=8, loc=sun_c, rot=srot)
    band(sun, 0.36, 0.44, -0.05, 0.05, seg=12, loc=sun_c, rot=srot)
    u, v = Vector((1, 0, 0)), turned((0, 1, 0), srot)
    for i in range(8):
        a = i / 8 * math.tau
        r = 0.36 if i % 2 else 0.32
        dvec = u * math.cos(a) + v * math.sin(a)
        sun.limb(sun_c + dvec * r, sun_c + dvec * (r + (0.42 if i % 2 == 0 else 0.26)), 0.1, 0.0, seg=4)
    core = m.piece("StaffCore", "Glow", "Neon", bone="RightArm")
    core.ico(0.15, loc=sun_c + turned((0, -1, 0), srot) * 0.1, scale=(1, 1, 1), subdiv=1)

    # small book held at the left hip
    bk, brot = Vector((1.62, -0.32, 2.36)), (0, -8, 18)
    book = m.piece("Book", "Book", bone="LeftArm")
    block(book, (0.24, 0.66, 0.8), loc=bk, rot=brot, bevel=0.05)
    pages = m.piece("BookPages", "Cloth2", bone="LeftArm")
    block(pages, (0.2, 0.6, 0.72), loc=bk + turned((0.03, -0.05, 0), brot), rot=brot, bevel=0.02)
    clasp = m.piece("BookTrim", "Gold", "Metal", bone="LeftArm")
    side = turned((1, 0, 0), brot)
    block(clasp, (0.04, 0.1, 0.42), loc=bk + side * 0.13, rot=brot, bevel=0.01)
    block(clasp, (0.04, 0.3, 0.1), loc=bk + side * 0.13 + Vector((0, 0, 0.08)), rot=brot, bevel=0.01)

    legs(m, "Cloth2", width=0.7)
    boots(m, "Leather", z_top=0.62, cuff=False)
