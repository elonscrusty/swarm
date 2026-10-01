"""The four exterminator heroes: Knight, Mage, Rogue, Priest.

Rig layout (Blender, z up, front -Y, character's LEFT is +X) matches ModelBuilder's
Roblox rig: torso centre (0, 0, 3) 2x1x2, head centre (0, 0, 4.6), arms at x = +-1.45,
legs at x = +-0.5 (centre z = 1). Every piece names its `bone`; the game welds gear to
that body part and swaps the six body parts for these meshes. Colours come from slots,
so skins only recolour (Cloth, Cloth2, Metal, Accent, Skin...).
"""

import math

from swarmkit import register


def rgb(h):
    return tuple(int(h[i:i + 2], 16) / 255 for i in (0, 2, 4))


def blocky_body(m, torso_slot="Cloth", arm_slot="Cloth", leg_slot="Cloth2", boot_slot="Dark", glove_slot=None):
    """Chunky Roblox-style body with bevelled blocks, belt, boots and gloves."""
    torso = m.piece("Torso", torso_slot, bone="Torso")
    torso.box((2.0, 1.0, 2.0), loc=(0, 0, 3.0), bevel=0.12)
    head = m.piece("Head", "Skin", bone="Head")
    head.box((1.3, 1.25, 1.25), loc=(0, 0, 4.62), bevel=0.14)
    for side, bone in ((1, "LeftArm"), (-1, "RightArm")):
        arm = m.piece(bone, arm_slot, bone=bone)
        arm.box((0.9, 0.9, 2.0), loc=(side * 1.45, 0, 3.0), bevel=0.1)
        if glove_slot:
            g = m.piece(bone + "Glove", glove_slot, bone=bone)
            g.box((1.0, 1.0, 0.6), loc=(side * 1.45, 0, 2.25), bevel=0.1)
    for side, bone in ((1, "LeftLeg"), (-1, "RightLeg")):
        leg = m.piece(bone, leg_slot, bone=bone)
        leg.box((0.95, 0.95, 2.0), loc=(side * 0.5, 0, 1.0), bevel=0.1)
        boot = m.piece(bone + "Boot", boot_slot, bone=bone)
        boot.box((1.05, 1.2, 0.6), loc=(side * 0.5, -0.08, 0.3), bevel=0.1)
    belt = m.piece("Belt", "Leather", bone="Torso")
    belt.box((2.08, 1.08, 0.32), loc=(0, 0, 2.2), bevel=0.05)
    belt.box((0.4, 0.15, 0.36), loc=(0, -0.55, 2.2), bevel=0.04)


def face(m, eye_slot="Black", glow=False):
    eyes = m.piece("Eyes", eye_slot, "Neon" if glow else "SmoothPlastic", bone="Head")
    for x in (-0.3, 0.3):
        eyes.box((0.2, 0.06, 0.3), loc=(x, -0.64, 4.7), bevel=0.02)


@register("Knight", "Heroes", "Armoured warrior: plumed helm, red cape, shield, glowing sword.")
def knight(m):
    m.extra["palette"] = {"Cloth": rgb("9aa3b5"), "Cloth2": rgb("4a5468"), "Metal": rgb("c4cad6"), "Dark": rgb("2c3140"),
                          "Accent": rgb("c8282d"), "Gold": rgb("f2c14e"), "Glow": rgb("ffb347"), "Leather": rgb("5b3b25"),
                          "Skin": rgb("ffd6aa")}
    blocky_body(m, torso_slot="Metal", arm_slot="Cloth2", leg_slot="Cloth2", boot_slot="Dark", glove_slot="Metal")
    helm = m.piece("Helm", "Metal", "Metal", bone="Head")
    helm.box((1.5, 1.45, 1.35), loc=(0, 0.02, 4.68), bevel=0.18)
    visor = m.piece("Visor", "Dark", bone="Head")
    visor.box((1.2, 0.1, 0.22), loc=(0, -0.74, 4.72), bevel=0.03)
    visor.box((0.12, 0.1, 0.7), loc=(0, -0.74, 4.5), bevel=0.02)
    plume = m.piece("Plume", "Accent", bone="Head")
    for i, (y, z) in enumerate([(-0.3, 5.55), (0.05, 5.65), (0.4, 5.55), (0.7, 5.3)]):
        plume.box((0.28, 0.5, 0.55), loc=(0, y, z), rot=(i * 18, 0, 0), bevel=0.08)
    trim = m.piece("Trim", "Gold", "Metal", bone="Torso")
    trim.box((2.1, 1.1, 0.18), loc=(0, 0, 3.92), bevel=0.04)
    trim.box((0.25, 0.1, 1.5), loc=(0, -0.53, 3.1), bevel=0.03)
    for side, bone in ((1, "LeftArm"), (-1, "RightArm")):
        pad = m.piece(bone + "Pauldron", "Metal", "Metal", bone=bone)
        pad.box((1.3, 1.25, 0.65), loc=(side * 1.5, 0, 3.95), taper=(0.8, 0.85), bevel=0.15)
        pad.box((1.2, 1.15, 0.3), loc=(side * 1.55, 0, 3.55), bevel=0.08)
    cape = m.piece("Cape", "Accent", bone="Torso")
    cape.box((1.9, 0.18, 3.2), loc=(0, 0.62, 2.45), rot=(-8, 0, 0), taper=(1.15, 1.0), bevel=0.05)
    shield = m.piece("Shield", "Accent", bone="LeftArm")
    shield.box((0.22, 1.7, 2.0), loc=(2.05, -0.15, 2.65), bevel=0.08)
    shield.box((0.24, 1.2, 0.6), loc=(2.05, -0.15, 1.45), taper=(1, 0.3), bevel=0.06)
    rim = m.piece("ShieldRim", "Gold", "Metal", bone="LeftArm")
    rim.box((0.3, 0.9, 0.22), loc=(2.12, -0.15, 3.65), bevel=0.04)
    rim.box((0.3, 0.22, 1.6), loc=(2.12, -0.15, 2.5), bevel=0.04)
    rim.box((0.3, 0.9, 0.22), loc=(2.12, -0.15, 2.6), bevel=0.04)
    sword = m.piece("SwordBlade", "Glow", "Neon", bone="RightArm")
    sword.box((0.18, 0.4, 3.0), loc=(-1.45, -2.4, 2.0), rot=(-90, 0, 0), taper=(0.6, 0.3), bevel=0.04)
    hilt = m.piece("SwordHilt", "Gold", "Metal", bone="RightArm")
    hilt.box((0.25, 0.25, 1.0), loc=(-1.45, -0.85, 2.0), rot=(-90, 0, 90), bevel=0.05)
    hilt.box((0.22, 0.7, 0.22), loc=(-1.45, -0.45, 2.0), bevel=0.04)
    face(m, "Black")


@register("Mage", "Heroes", "Arcane mage: tall wizard hat, star robe, glowing crystal staff.")
def mage(m):
    m.extra["palette"] = {"Cloth": rgb("3446c8"), "Cloth2": rgb("2a2f8c"), "Gold": rgb("f2c14e"), "Dark": rgb("1c1d3a"),
                          "Glow": rgb("5ad7ff"), "Leather": rgb("5b3b25"), "Skin": rgb("1c1d3a"), "Wood": rgb("6b4a2c")}
    blocky_body(m, torso_slot="Cloth", arm_slot="Cloth", leg_slot="Cloth2", boot_slot="Dark")
    robe = m.piece("Robe", "Cloth", bone="Torso")
    robe.box((2.3, 1.3, 1.9), loc=(0, 0, 1.35), taper=(0.85, 0.85), bevel=0.1)
    trim = m.piece("RobeTrim", "Gold", "Metal", bone="Torso")
    trim.box((2.35, 1.35, 0.2), loc=(0, 0, 0.45), bevel=0.04)
    trim.box((0.3, 0.1, 3.4), loc=(0, -0.62, 2.3), bevel=0.03)
    hat = m.piece("Hat", "Cloth", bone="Head")
    hat.cyl(1.5, 1.5, 0.18, seg=8, loc=(0, 0, 5.25))
    hat.cyl(0.85, 0.12, 2.3, seg=8, loc=(0.15, 0.1, 6.35), rot=(-8, 6, 0))
    band = m.piece("HatBand", "Gold", "Metal", bone="Head")
    band.cyl(0.88, 0.82, 0.25, seg=8, loc=(0, 0, 5.45))
    star = m.piece("HatStar", "Glow", "Neon", bone="Head")
    star.ico(0.2, loc=(0, -0.82, 5.5), subdiv=1)
    face(m, "Glow", glow=True)
    staff = m.piece("Staff", "Wood", bone="RightArm")
    staff.limb((-1.45, -0.6, 0.6), (-1.45, -0.6, 5.6), 0.13, 0.11, seg=6)
    staff.cyl(0.32, 0.18, 0.5, seg=6, loc=(-1.45, -0.6, 5.7))
    crystal = m.piece("StaffCrystal", "Glow", "Neon", bone="RightArm")
    crystal.ico(0.42, loc=(-1.45, -0.6, 6.3), scale=(0.8, 0.8, 1.3), subdiv=0)
    shards = m.piece("Shards", "Glow", "Neon", bone="RightArm", anim="Spin", pivot=(-1.45, -0.6, 6.3))
    for i, (x, z) in enumerate([(0.55, 0.2), (-0.5, -0.1), (0.1, 0.6)]):
        shards.box((0.18, 0.18, 0.18), loc=(-1.45 + x, -0.6 + 0.3 * (i - 1), 6.3 + z), rot=(45, 45, 0), bevel=0.0)


@register("Rogue", "Heroes", "Shadow rogue: deep purple hood, mask, twin glowing daggers.")
def rogue(m):
    m.extra["palette"] = {"Cloth": rgb("3a2350"), "Cloth2": rgb("221630"), "Dark": rgb("140c1e"), "Glow": rgb("c35bff"),
                          "Accent": rgb("7a3fb0"), "Leather": rgb("3a2a22"), "Skin": rgb("140c1e"), "Metal": rgb("b9b9c9")}
    blocky_body(m, torso_slot="Cloth", arm_slot="Cloth", leg_slot="Cloth2", boot_slot="Dark", glove_slot="Dark")
    hood = m.piece("Hood", "Cloth", bone="Head")
    hood.box((1.55, 1.5, 1.45), loc=(0, 0.08, 4.72), taper=(0.75, 0.8), bevel=0.2)
    hood.box((0.5, 0.6, 0.6), loc=(0, 0.6, 5.35), rot=(30, 0, 0), taper=(0.3, 0.5), bevel=0.05)
    face(m, "Glow", glow=True)
    scarf = m.piece("Scarf", "Accent", bone="Torso")
    scarf.box((1.8, 1.2, 0.45), loc=(0, 0, 4.05), bevel=0.1)
    scarf.box((0.45, 0.15, 1.4), loc=(0.4, 0.6, 3.4), rot=(-12, 0, -8), bevel=0.05)
    cloak = m.piece("Cloak", "Cloth2", bone="Torso")
    cloak.box((2.2, 0.2, 2.8), loc=(0, 0.6, 2.6), rot=(-6, 0, 0), taper=(1.2, 1.0), bevel=0.05)
    for side, bone in ((1, "LeftArm"), (-1, "RightArm")):
        blade = m.piece(bone + "Dagger", "Glow", "Neon", bone=bone)
        blade.prism([(-0.18, 0), (0.18, 0), (0.28, 0.9), (0.0, 2.1), (-0.22, 0.9)], 0.12,
                    loc=(side * 1.45, -0.55, 1.85), rot=(-90, 0, 0))
        grip = m.piece(bone + "Grip", "Metal", "Metal", bone=bone)
        grip.box((0.3, 0.55, 0.3), loc=(side * 1.45, -0.25, 1.8), bevel=0.05)
    pouches = m.piece("Pouches", "Leather", bone="Torso")
    for x in (-0.7, 0.75):
        pouches.box((0.45, 0.4, 0.45), loc=(x, -0.55, 2.05), bevel=0.08)


@register("Priest", "Heroes", "Healer priest: white and gold robes, halo, sun staff.")
def priest(m):
    m.extra["palette"] = {"Cloth": rgb("f4f1e8"), "Cloth2": rgb("e2dccb"), "Gold": rgb("f2c14e"), "Dark": rgb("6b5a3a"),
                          "Glow": rgb("fff0a0"), "Leather": rgb("8a6a3a"), "Skin": rgb("ffd6aa"), "Wood": rgb("e7d3a1")}
    blocky_body(m, torso_slot="Cloth", arm_slot="Cloth", leg_slot="Cloth2", boot_slot="Dark")
    robe = m.piece("Robe", "Cloth", bone="Torso")
    robe.box((2.4, 1.35, 2.0), loc=(0, 0, 1.3), taper=(0.82, 0.85), bevel=0.1)
    stole = m.piece("Stole", "Gold", "Metal", bone="Torso")
    for x in (-0.45, 0.45):
        stole.box((0.35, 0.1, 3.4), loc=(x, -0.62, 2.4), bevel=0.03)
    stole.box((2.45, 1.4, 0.18), loc=(0, 0, 0.35), bevel=0.04)
    mitre = m.piece("Mitre", "Cloth", bone="Head")
    mitre.box((1.2, 1.0, 1.3), loc=(0, 0, 5.75), taper=(0.6, 0.85), bevel=0.12)
    cross = m.piece("MitreCross", "Gold", "Metal", bone="Head")
    cross.box((0.14, 0.08, 0.6), loc=(0, -0.53, 5.7), bevel=0.02)
    cross.box((0.4, 0.08, 0.14), loc=(0, -0.53, 5.8), bevel=0.02)
    halo = m.piece("Halo", "Glow", "Neon", bone="Head", anim="Spin", pivot=(0, 0.3, 6.6))
    for i in range(10):
        a = i / 10 * math.tau
        halo.box((0.45, 0.14, 0.12), loc=(math.cos(a) * 0.85, 0.3 + math.sin(a) * 0.85, 6.6),
                 rot=(0, 0, math.degrees(a) + 90), bevel=0.02)
    face(m, "Black")
    staff = m.piece("Staff", "Wood", bone="RightArm")
    staff.limb((-1.45, -0.6, 0.6), (-1.45, -0.6, 5.4), 0.12, 0.12, seg=6)
    sun = m.piece("StaffSun", "Glow", "Neon", bone="RightArm")
    sun.ico(0.4, loc=(-1.45, -0.6, 5.85), subdiv=1)
    for i in range(8):
        a = i / 8 * math.tau
        sun.spike(0.1, 0.45, seg=4, base=(-1.45 + math.cos(a) * 0.35, -0.6, 5.85 + math.sin(a) * 0.35),
                  direction=(math.cos(a), 0, math.sin(a)))
    book = m.piece("Book", "Dark", bone="Torso")
    book.box((0.25, 0.7, 0.85), loc=(1.15, -0.1, 2.2), bevel=0.05)
