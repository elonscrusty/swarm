"""Four class characters from the redesign sheet (docs/redesign/reference/Swarm-Characters.png):
Ruckus (raccoon), Toastmaster (toaster robot), CaptainCroak (frog), GrannyBoom (granny on a rocket walker).

Same rig contract as models/heroes.py: feet at z = 0, front = -Y, the character's LEFT is +X, six
bone pieces named Torso / Head / LeftArm / RightArm / LeftLeg / RightLeg, every other piece names
the bone it is welded to ("Head", "Eyes" and "Face*" are the face). Unlike the human heroes these
bodies are not the standard blocky rig, so each model sets its own joint points (the game reads
MeshCatalog Joints per model, ModelBuilder.buildMeshCharacter).

Slots: Fur / FurDark / FurLight, Skin, Dark, Leather, Metal / MetalDark, Cloth / Cloth2, Accent, Gold,
Lens (goggle glass, plain), Glow (Neon, tiny parts only), White. Plain colour names, so skins that
override Metal / Cloth / Accent / Gold recolour them like on the heroes.
"""

import math

from mathutils import Vector

from models.hats import arc_shell, band, block, lathe, slab, sweep
from swarmkit import register

SIDES = ((1, "Left"), (-1, "Right"))


def hexc(h):
    h = h.lstrip("#")
    return tuple(int(h[i:i + 2], 16) / 255 for i in (0, 2, 4))


def rig(m, pal, joints):
    m.extra["joints"] = joints
    m.extra["palette"] = {k: hexc(v) for k, v in pal.items()}


def std_joints(neck, sh_x, sh_z, hip_x, hip_z):
    return {"Neck": (0.0, 0.0, neck), "LeftShoulder": (sh_x, 0.0, sh_z), "RightShoulder": (-sh_x, 0.0, sh_z),
            "LeftHip": (hip_x, 0.0, hip_z), "RightHip": (-hip_x, 0.0, hip_z)}


def cyl(p, r, h, loc, rot=(0, 0, 0), seg=8, r2=None, phase=0.0, sx=1.0, sy=1.0):
    """Closed faceted cylinder / cone frustum along local Z, centred on loc."""
    r2 = r if r2 is None else r2
    lathe(p, [(r, -h / 2), (r2, h / 2)], seg=seg, loc=loc, rot=rot, phase=phase, sx=sx, sy=sy)


def tube(p, a, b, r1, r2=None, seg=6):
    """Tapered closed segment from a to b."""
    sweep(p, [a, b], [r1, r1 if r2 is None else r2], seg=seg)


# ====================================================================================== Ruckus

@register("Ruckus", "Classes", "Stocky grey raccoon: black eye mask, orange aviator goggles on the brow, striped tail, "
                               "teal patched vest, metal trash-can backpack with a lid, dark fingerless gloves, boots.")
def ruckus(m):
    rig(m, dict(Fur="7d8086", FurDark="3b3d43", FurLight="d9d6cc", Skin="d9d6cc", Dark="1c1d21",
                Cloth="2f8c86", Cloth2="46484f", Leather="6b4a2e", Metal="9096a0", MetalDark="5a5f69",
                Lens="f08a1c", Gold="c9a04a", White="f2f0e8", Accent="2f8c86"),
        std_joints(4.4, 1.38, 3.95, 0.58, 2.0))
    # torso: round fur body
    t = m.piece("Torso", "Fur", bone="Torso", shadow=True)
    lathe(t, [(0.8, 2.0), (1.1, 2.4), (1.28, 3.1), (1.3, 3.7), (1.1, 4.25), (0.5, 4.45), (0.0, 4.5)], seg=8,
          phase=22.5, sy=0.86)
    belly = m.piece("Belly", "FurLight", bone="Torso")
    block(belly, (1.2, 0.3, 1.5), loc=(0, -1.0, 3.3), top=(0.9, 1), bevel=0.1)
    vest = m.piece("Vest", "Cloth", bone="Torso", shadow=True)
    arc_shell(vest, [(1.12, 4.3, 0), (1.34, 3.75, 0), (1.36, 3.1, 0), (1.3, 2.55, 0)], 28, 332, seg=8, thick=0.14,
              sy=0.9)
    pat = m.piece("VestPatch", "Cloth2", bone="Torso")
    block(pat, (0.5, 0.1, 0.5), loc=(0.8, -1.08, 3.55), rot=(0, 0, 12), bevel=0.02)
    block(pat, (0.4, 0.1, 0.4), loc=(-0.95, 0.9, 3.0), rot=(0, 0, 20), bevel=0.02)
    belt = m.piece("Belt", "Leather", bone="Torso")
    band(belt, 1.18, 1.4, 2.4, 2.7, seg=8, phase=22.5, sy=0.9)
    block(belt, (0.5, 0.18, 0.4), loc=(0, -1.2, 2.55), bevel=0.04)
    strap = m.piece("Strap", "Leather", bone="Torso")
    sweep(strap, [(0.95, -0.78, 4.5), (0.25, -1.2, 3.4), (-0.5, -1.15, 2.6)], [0.13, 0.13, 0.13], seg=4, sx=1.6)
    # trash-can backpack
    can = m.piece("TrashCan", "Metal", bone="Torso", shadow=True)
    cyl(can, 0.82, 2.0, (0, 1.4, 3.35), seg=8)
    ribs = m.piece("CanRibs", "MetalDark", bone="Torso")
    for z in (2.6, 3.35, 4.05):
        band(ribs, 0.8, 0.9, z - 0.07, z + 0.07, seg=8, loc=(0, 1.4, 0))
    lid = m.piece("CanLid", "Metal", bone="Torso")
    lathe(lid, [(0.92, 4.32), (0.92, 4.44), (0.6, 4.62), (0.0, 4.68)], seg=8, loc=(0, 1.4, 0))
    block(lid, (0.5, 0.12, 0.14), loc=(0, 1.4, 4.78), bevel=0.03)
    # tail: alternating grey and dark rings sweeping out behind and up
    pts = []
    for i in range(9):
        u = i / 8
        pts.append(Vector((-1.9 * u + 0.3 * math.sin(u * 3), 1.0 + 2.1 * u - 0.4 * u * u, 2.3 + 1.2 * u + 1.4 * u * u)))
    for i in range(8):
        rad = lambda k: 0.5 + 0.42 * math.sin(math.pi * min(k / 8 * 1.05, 1.0))
        p = m.piece("Tail%d" % i, "FurDark" if i % 2 else "Fur", bone="Torso")
        sweep(p, [pts[i], pts[i + 1]], [rad(i), rad(i + 1) if i < 7 else rad(i) * 0.8], seg=7)
    # head: wide raccoon head with mask, muzzle, ears, goggles
    h = m.piece("Head", "Fur", bone="Head", shadow=True)
    block(h, (2.1, 1.6, 1.5), loc=(0, 0, 5.2), bottom=(0.88, 0.9), bevel=0.4)
    mask = m.piece("FaceMask", "FurDark", bone="Head")
    block(mask, (2.14, 0.2, 0.62), loc=(0, -0.72, 5.18), bevel=0.1)
    for s in (1, -1):
        block(mask, (0.5, 0.2, 0.5), loc=(s * 0.86, -0.64, 4.9), rot=(0, s * 20, 0), bevel=0.05)
    muz = m.piece("FaceMuzzle", "FurLight", bone="Head")
    block(muz, (0.95, 0.7, 0.6), loc=(0, -0.95, 4.72), top=(0.9, 0.85), bevel=0.16)
    nose = m.piece("FaceNose", "Dark", bone="Head")
    block(nose, (0.34, 0.24, 0.24), loc=(0, -1.35, 4.95), bevel=0.05)
    block(nose, (0.6, 0.06, 0.07), loc=(0, -1.31, 4.58), bevel=0)
    brow = m.piece("FaceBrow", "FurLight", bone="Head")
    for s in (1, -1):
        block(brow, (0.62, 0.14, 0.3), loc=(s * 0.55, -0.85, 5.43), rot=(0, s * -8, 0), bevel=0.03)
    ew = m.piece("FaceEyeWhite", "White", bone="Head")
    for s in (1, -1):
        block(ew, (0.4, 0.1, 0.34), loc=(s * 0.55, -0.83, 5.15), bevel=0.02)
    eyes = m.piece("Eyes", "Dark", bone="Head")
    for s in (1, -1):
        block(eyes, (0.2, 0.1, 0.24), loc=(s * 0.55, -0.9, 5.14), bevel=0)
    ears = m.piece("Ears", "Fur", bone="Head")
    inner = m.piece("EarsInner", "FurDark", bone="Head")
    for s in (1, -1):
        cyl(ears, 0.55, 0.7, (s * 0.85, 0.0, 6.2), r2=0.18, seg=5)
        cyl(inner, 0.32, 0.5, (s * 0.85, -0.2, 6.18), r2=0.1, seg=5)
    gb = m.piece("Goggles", "Leather", bone="Head")
    band(gb, 0.98, 1.08, 5.8, 6.05, seg=8, phase=22.5, loc=(0, 0.05, 0), sy=0.78)
    gl = m.piece("GoggleLens", "Lens", bone="Head")
    gr = m.piece("GoggleRims", "Gold", bone="Head")
    for s in (1, -1):
        cyl(gr, 0.46, 0.18, (s * 0.5, -0.5, 6.3), rot=(60, 0, 0), seg=8)
        cyl(gl, 0.34, 0.26, (s * 0.5, -0.55, 6.34), rot=(60, 0, 0), seg=8)
    # arms: thick fur with a dark fingerless glove
    for s, side in SIDES:
        bone = side + "Arm"
        a = m.piece(bone, "Fur", bone=bone)
        block(a, (0.86, 0.9, 1.5), loc=(s * 1.55, -0.05, 3.3), bottom=(0.9, 0.9), bevel=0.16)
        sh = m.piece(bone + "Pad", "Metal", bone=bone)
        block(sh, (1.0, 1.0, 0.4), loc=(s * 1.55, 0, 4.0), bevel=0.1)
        g = m.piece(bone + "Glove", "FurDark", bone=bone)
        block(g, (0.96, 1.0, 0.8), loc=(s * 1.58, -0.1, 2.35), bottom=(0.9, 0.9), bevel=0.14)
        bd = m.piece(bone + "Band", "Leather", bone=bone)
        block(bd, (0.94, 0.96, 0.18), loc=(s * 1.58, -0.08, 2.8), bevel=0.03)
    # legs and boots
    for s, side in SIDES:
        bone = side + "Leg"
        leg = m.piece(bone, "FurDark", bone=bone)
        block(leg, (0.95, 0.95, 1.4), loc=(s * 0.6, 0, 1.4), bottom=(0.95, 0.95), bevel=0.14)
        b = m.piece(bone + "Boot", "MetalDark", bone=bone)
        block(b, (1.0, 1.4, 0.75), loc=(s * 0.6, -0.2, 0.38), top=(0.9, 0.8), shift=(0, 0.1), bevel=0.14)
        c = m.piece(bone + "BootCuff", "Leather", bone=bone)
        block(c, (1.06, 1.0, 0.2), loc=(s * 0.6, 0, 0.82), bevel=0.04)


# ================================================================================== Toastmaster

def toast_slice(p, crust, x, tilt):
    """One bread slice standing in a slot: crust outline with a lighter face."""
    outline = [(-0.5, -0.5), (0.5, -0.5), (0.52, 0.0), (0.46, 0.4), (0.5, 0.6), (0.3, 0.78), (-0.3, 0.78),
               (-0.5, 0.6), (-0.46, 0.4), (-0.52, 0.0)]
    slab(crust, outline, 0.34, loc=(x, 0, 5.3), rot=(0, tilt, 0), bevel=0.04)
    face = [(a * 0.82, b * 0.84 + 0.02) for a, b in outline]
    slab(p, face, 0.4, loc=(x, 0, 5.3), rot=(0, tilt, 0), bevel=0.03)


@register("Toastmaster", "Classes", "Boxy silver toaster robot: the body is torso and head, big angry eyes and brows, "
                                    "glowing heating-coil mouth, two golden toast slices on top, small dark mechanical "
                                    "arms, tiny dark boots, red lever knob on the side.")
def toastmaster(m):
    rig(m, dict(Metal="b5bbc4", MetalDark="3a3d44", Dark="1e1f24", Gold="e0a838", Cloth="f0c860",
                Cloth2="b87a2a", Accent="c9302c", Glow="ff9a1c", White="f4f2ea", Leather="6a4a2c"),
        std_joints(3.9, 1.95, 3.5, 0.9, 1.75))
    t = m.piece("Torso", "Metal", bone="Torso", shadow=True)
    block(t, (3.3, 2.2, 2.3), loc=(0, 0, 2.85), bevel=0.28)
    trim = m.piece("TorsoTrim", "MetalDark", bone="Torso")
    block(trim, (3.4, 2.3, 0.18), loc=(0, 0, 1.78), bevel=0.04)
    block(trim, (3.4, 2.3, 0.18), loc=(0, 0, 3.98), bevel=0.04)
    for x in (-1.1, 1.1):
        block(trim, (0.12, 0.1, 1.2), loc=(x, 1.1, 3.0), bevel=0)  # rear vent slits
    recess = m.piece("CoilRecess", "Dark", bone="Torso")
    block(recess, (2.5, 0.2, 1.4), loc=(0, -1.08, 2.85), bevel=0.05)
    coil = m.piece("Coils", "Glow", "Neon", bone="Torso")
    for i in range(5):
        block(coil, (0.28, 0.12, 1.1), loc=(-1.0 + i * 0.5, -1.18, 2.85), bevel=0)
    knob = m.piece("LeverKnob", "Accent", bone="Torso")
    cyl(knob, 0.26, 0.5, (1.8, 0.1, 3.2), rot=(0, 90, 0), seg=8)
    knob.ico(0.34, loc=(2.05, 0.1, 3.2), subdiv=1)
    track = m.piece("LeverTrack", "Dark", bone="Torso")
    block(track, (0.1, 0.34, 1.0), loc=(1.68, 0.1, 3.0), bevel=0)
    # head: the upper box with the face
    h = m.piece("Head", "Metal", bone="Head", shadow=True)
    block(h, (3.3, 2.2, 1.2), loc=(0, 0, 4.58), bevel=0.28)
    slots = m.piece("ToastSlots", "Dark", bone="Head")
    block(slots, (1.2, 0.5, 0.1), loc=(-0.78, 0, 5.18), bevel=0)
    block(slots, (1.2, 0.5, 0.1), loc=(0.78, 0, 5.18), bevel=0)
    ew = m.piece("FaceEyeWhite", "White", bone="Head")
    for s in (1, -1):
        block(ew, (1.0, 0.16, 0.78), loc=(s * 0.82, -1.08, 4.62), top=(0.9, 1), bevel=0.14)
    eyes = m.piece("Eyes", "Dark", bone="Head")
    for s in (1, -1):
        block(eyes, (0.5, 0.16, 0.55), loc=(s * 0.74, -1.17, 4.55), bevel=0.06)
    brows = m.piece("FaceBrows", "MetalDark", bone="Head")
    for s in (1, -1):
        block(brows, (1.25, 0.22, 0.3), loc=(s * 0.8, -1.12, 5.08), rot=(0, s * 24, 0), bevel=0.05)
    cr = m.piece("ToastCrust", "Cloth2", bone="Head")
    toast = m.piece("Toast", "Cloth", bone="Head")
    toast_slice(toast, cr, -0.78, 3)
    toast_slice(toast, cr, 0.78, -3)
    # arms: dark mechanical: shoulder ball, upper arm, forearm, claw
    for s, side in SIDES:
        bone = side + "Arm"
        x = s * 2.0
        a = m.piece(bone, "MetalDark", bone=bone)
        a.ico(0.42, loc=(x, 0, 3.5), subdiv=1)
        tube(a, (x, 0, 3.5), (x + s * 0.2, -0.1, 2.75), 0.24, 0.22)
        block(a, (0.36, 0.36, 0.5), loc=(x + s * 0.2, -0.1, 2.75), bevel=0.06)
        tube(a, (x + s * 0.2, -0.1, 2.75), (x + s * 0.3, -0.4, 2.05), 0.22, 0.2)
        cl = m.piece(bone + "Claw", "Metal", bone=bone)
        block(cl, (0.62, 0.6, 0.55), loc=(x + s * 0.32, -0.45, 1.8), bottom=(0.8, 0.8), bevel=0.08)
    # tiny boots
    for s, side in SIDES:
        bone = side + "Leg"
        lg = m.piece(bone, "MetalDark", bone=bone)
        cyl(lg, 0.34, 1.0, (s * 0.9, 0, 1.25), seg=6)
        b = m.piece(bone + "Boot", "Dark", bone=bone)
        block(b, (1.2, 1.5, 0.7), loc=(s * 0.9, -0.2, 0.35), top=(0.9, 0.8), shift=(0, 0.1), bevel=0.14)
        sole = m.piece(bone + "Sole", "MetalDark", bone=bone)
        block(sole, (1.26, 1.56, 0.14), loc=(s * 0.9, -0.2, 0.08), bevel=0.02)


# ================================================================================ CaptainCroak

@register("CaptainCroak", "Classes", "Round bright green frog: pale belly, wide mouth, gold aviator goggles above bulging "
                                     "eyes, yellow scarf, tan expedition backpack with a bedroll, short limbs, wide webbed feet.")
def croak(m):
    rig(m, dict(Fur="62b53a", FurDark="3f8a28", FurLight="e8efb0", Skin="62b53a", Dark="1c2418",
                Cloth="d9b65a", Cloth2="b08a52", Accent="f0c42a", Leather="6a4a2c", Gold="d6a838",
                Lens="b8d8e8", White="f4f2ea", Metal="9096a0"),
        std_joints(4.2, 1.5, 3.5, 0.75, 1.9))
    t = m.piece("Torso", "Fur", bone="Torso", shadow=True)
    lathe(t, [(0.9, 1.75), (1.45, 2.2), (1.72, 3.0), (1.62, 3.8), (1.15, 4.3), (0.0, 4.45)], seg=8, phase=22.5,
          sy=0.9)
    belly = m.piece("Belly", "FurLight", bone="Torso")
    belly.ico(1.2, loc=(0, -0.62, 2.95), scale=(1.0, 0.45, 1.15), subdiv=1)
    sc = m.piece("Scarf", "Accent", bone="Torso")
    band(sc, 1.05, 1.5, 4.0, 4.5, seg=8, phase=22.5, sy=0.9)
    slab(sc, [(-0.8, 0.5), (0.8, 0.5), (0.0, -0.75)], 0.22, loc=(0, -1.22, 3.85), rot=(-14, 0, 0), bevel=0.03)
    sweep(sc, [(0.7, 1.0, 4.2), (1.3, 1.4, 3.7), (1.45, 1.75, 3.1)], [0.2, 0.18, 0.04], seg=4, sx=1.8)
    pk = m.piece("Pockets", "Cloth2", bone="Torso")
    for s in (1, -1):
        block(pk, (0.7, 0.4, 0.6), loc=(s * 1.15, -1.18, 2.35), rot=(0, 0, s * -8), bevel=0.07)
    sl = m.piece("Straps", "Leather", bone="Torso")
    for s in (1, -1):
        sweep(sl, [(s * 0.85, -1.1, 4.3), (s * 0.95, -1.45, 3.3), (s * 0.9, -1.2, 2.3)], [0.12, 0.12, 0.12], seg=4, sx=1.6)
    # expedition backpack
    bp = m.piece("Backpack", "Cloth2", bone="Torso", shadow=True)
    block(bp, (2.3, 1.2, 2.3), loc=(0, 1.55, 3.2), bevel=0.2)
    flap = m.piece("BackpackFlap", "Leather", bone="Torso")
    block(flap, (2.4, 1.3, 0.5), loc=(0, 1.55, 4.1), bevel=0.1)
    block(flap, (0.5, 0.2, 0.5), loc=(0, 0.9, 3.5), bevel=0.04)
    roll = m.piece("Bedroll", "Cloth", bone="Torso")
    cyl(roll, 0.5, 2.7, (0, 1.55, 4.55), rot=(0, 90, 0), seg=8)
    rb = m.piece("BedrollBands", "Leather", bone="Torso")
    for x in (-0.8, 0.8):
        band(rb, 0.5, 0.58, -0.09, 0.09, seg=8, loc=(x, 1.55, 4.55), rot=(0, 90, 0))
    # head: wide flat head with a wide mouth, bulging eyes, goggles
    h = m.piece("Head", "Fur", bone="Head", shadow=True)
    h.ico(1.0, loc=(0, -0.05, 5.05), scale=(1.7, 1.35, 0.95), subdiv=1)
    lip = m.piece("FaceLip", "FurLight", bone="Head")
    lip.ico(1.0, loc=(0, -0.3, 4.65), scale=(1.45, 1.1, 0.45), subdiv=1)
    mouth = m.piece("FaceMouth", "Dark", bone="Head")
    sweep(mouth, [(-1.2, -1.2, 4.88), (-0.6, -1.4, 4.7), (0.6, -1.4, 4.7), (1.2, -1.2, 4.88)],
          [0.04, 0.07, 0.07, 0.04], seg=4)
    nos = m.piece("FaceNostrils", "FurDark", bone="Head")
    for s in (1, -1):
        block(nos, (0.12, 0.1, 0.1), loc=(s * 0.25, -1.4, 5.15), bevel=0)
    eb = m.piece("EyeBulges", "Fur", bone="Head")
    ew = m.piece("FaceEyeWhite", "White", bone="Head")
    eyes = m.piece("Eyes", "Dark", bone="Head")
    for s in (1, -1):
        eb.ico(0.62, loc=(s * 0.72, -0.4, 5.62), scale=(1.0, 1.0, 0.95), subdiv=1)
        ew.ico(0.5, loc=(s * 0.72, -0.78, 5.7), scale=(1.0, 0.7, 1.0), subdiv=1)
        block(eyes, (0.32, 0.12, 0.4), loc=(s * 0.72, -1.1, 5.7), bevel=0.02)
    gs = m.piece("Goggles", "Leather", bone="Head")
    band(gs, 0.88, 1.0, 6.0, 6.25, seg=8, phase=22.5, loc=(0, -0.1, 0), sx=1.7, sy=1.3)
    gr = m.piece("GoggleRims", "Gold", bone="Head")
    gl = m.piece("GoggleLens", "Lens", bone="Head")
    for s in (1, -1):
        cyl(gr, 0.5, 0.2, (s * 0.72, -0.1, 6.5), rot=(50, 0, 0), seg=8)
        cyl(gl, 0.37, 0.3, (s * 0.72, -0.16, 6.55), rot=(50, 0, 0), seg=8)
    # arms: short, thick, with hand blocks
    for s, side in SIDES:
        bone = side + "Arm"
        a = m.piece(bone, "Fur", bone=bone)
        block(a, (0.9, 1.0, 1.5), loc=(s * 1.95, -0.1, 3.0), rot=(0, -s * 8, 0), bottom=(0.9, 0.9), bevel=0.16)
        hnd = m.piece(bone + "Hand", "FurDark", bone=bone)
        block(hnd, (0.85, 0.95, 0.5), loc=(s * 2.05, -0.2, 2.1), bevel=0.12)
        for k in (-1, 0, 1):
            block(hnd, (0.2, 0.3, 0.2), loc=(s * 2.05 + k * 0.28, -0.7, 2.0), bevel=0.03)
    # short legs with wide webbed feet
    for s, side in SIDES:
        bone = side + "Leg"
        lg = m.piece(bone, "Fur", bone=bone)
        block(lg, (1.1, 1.1, 1.3), loc=(s * 0.85, 0, 1.3), bottom=(0.95, 0.95), bevel=0.2)
        f = m.piece(bone + "Foot", "FurDark", bone=bone)
        block(f, (1.3, 1.1, 0.5), loc=(s * 0.9, -0.3, 0.3), top=(0.9, 0.85), bevel=0.12)
        for k, rz in ((-1, -22), (0, 0), (1, 22)):
            block(f, (0.42, 0.9, 0.34), loc=(s * 0.9 + k * 0.52, -1.1, 0.2), rot=(0, 0, s * rz), top=(0.85, 0.8),
                  bevel=0.08)


# ================================================================================== GrannyBoom

@register("GrannyBoom", "Classes", "Tiny granny with a grey bun, huge orange welding goggles and a purple outfit, "
                                   "armored slippers, both hands on a grey rocket walker: hazard-stripe front plate, "
                                   "red canisters on each side, two rear rocket nozzles with glow.")
def granny(m):
    rig(m, dict(Skin="eab898", Hair="c4c4cc", Dark="1e1f24", Cloth="7a3fa0", Cloth2="5a2a80", Accent="d85a9a",
                Leather="5a4030", Metal="8a909a", MetalDark="4a4e58", Lens="f58a18", Gold="e8c020",
                Glow="ffa030", White="f4f2ea", Fur="c4c4cc", FurLight="eab898", Red="c42828", Cloth3="a65ac8"),
        std_joints(4.0, 1.0, 3.7, 0.5, 1.7))
    # torso: small, a little forward lean
    t = m.piece("Torso", "Cloth", bone="Torso", shadow=True)
    lathe(t, [(0.62, 1.8), (0.85, 2.3), (1.0, 3.0), (0.95, 3.6), (0.6, 3.95), (0.0, 4.0)], seg=8, phase=22.5, sy=0.9)
    cardi = m.piece("Cardigan", "Cloth2", bone="Torso")
    block(cardi, (0.18, 0.12, 1.5), loc=(0, -0.88, 2.9), bevel=0)
    for z in (2.4, 2.9, 3.4):
        block(cardi, (0.24, 0.12, 0.24), loc=(0.22, -0.9, z), bevel=0.03)
    sk = m.piece("Skirt", "Cloth2", bone="Torso")
    lathe(sk, [(0.86, 1.65), (0.95, 2.0), (0.8, 2.4)], seg=8, phase=22.5, sy=0.9)
    # head: big, with bun, brows, goggles
    h = m.piece("Head", "Skin", bone="Head", shadow=True)
    block(h, (1.7, 1.55, 1.55), loc=(0, 0, 4.95), bottom=(0.9, 0.9), bevel=0.4)
    nose = m.piece("FaceNose", "Skin", bone="Head")
    block(nose, (0.3, 0.3, 0.34), loc=(0, -0.86, 4.78), bevel=0.06)
    mouth = m.piece("Eyes", "Dark", bone="Head")
    block(mouth, (0.5, 0.08, 0.1), loc=(0, -0.8, 4.35), bevel=0)
    brow = m.piece("FaceBrow", "Hair", bone="Head")
    for s in (1, -1):
        block(brow, (0.62, 0.14, 0.14), loc=(s * 0.5, -0.88, 5.42), rot=(0, s * -14, 0), bevel=0.02)
    hair = m.piece("Hair", "Hair", bone="Head", shadow=True)
    lathe(hair, [(0.88, 5.0), (0.92, 5.4), (0.78, 5.8), (0.0, 5.95)], seg=8, phase=22.5, loc=(0, 0.1, 0), sy=0.9)
    hair.ico(0.5, loc=(0, 0.2, 6.2), scale=(1, 1, 0.9), subdiv=1)
    hair.ico(0.15, loc=(0, 0.0, 6.35), subdiv=1)
    gs = m.piece("Goggles", "Leather", bone="Head")
    band(gs, 0.9, 1.0, 5.1, 5.4, seg=8, phase=22.5, loc=(0, 0.05, 0), sy=0.9)
    gr = m.piece("GoggleRims", "Metal", bone="Head")
    gl = m.piece("GoggleLens", "Lens", bone="Head")
    for s in (1, -1):
        cyl(gr, 0.52, 0.35, (s * 0.5, -0.88, 5.18), rot=(90, 0, 0), seg=8)
        cyl(gl, 0.42, 0.45, (s * 0.5, -0.92, 5.18), rot=(90, 0, 0), seg=8)
    # arms: purple sleeves reaching forward to the walker handles, pink hands
    for s, side in SIDES:
        bone = side + "Arm"
        a = m.piece(bone, "Cloth", bone=bone)
        tube(a, (s * 1.0, 0, 3.7), (s * 1.15, -1.0, 3.3), 0.36, 0.32)
        a.ico(0.42, loc=(s * 1.0, 0, 3.7), subdiv=1)
        hd = m.piece(bone + "Hand", "Skin", bone=bone)
        block(hd, (0.5, 0.5, 0.45), loc=(s * 1.15, -1.3, 3.3), bevel=0.1)
    # legs: short purple with armored slippers
    for s, side in SIDES:
        bone = side + "Leg"
        lg = m.piece(bone, "Cloth2", bone=bone)
        block(lg, (0.62, 0.62, 1.2), loc=(s * 0.5, 0, 1.15), bottom=(0.95, 0.95), bevel=0.1)
        sl = m.piece(bone + "Slipper", "MetalDark", bone=bone)
        block(sl, (0.85, 1.25, 0.6), loc=(s * 0.5, -0.2, 0.3), top=(0.9, 0.8), shift=(0, 0.08), bevel=0.14)
        tp = m.piece(bone + "SlipperTip", "Metal", bone=bone)
        block(tp, (0.7, 0.4, 0.4), loc=(s * 0.5, -0.65, 0.3), bevel=0.1)
    # rocket walker: welded to the torso, grey frame on four legs
    w = m.piece("WalkerFrame", "Metal", bone="Torso", shadow=True)
    block(w, (3.7, 0.4, 0.4), loc=(0, -1.35, 3.0), bevel=0.08)  # front bar
    block(w, (3.7, 0.4, 0.4), loc=(0, 1.2, 3.0), bevel=0.08)  # rear bar
    for s in (1, -1):
        block(w, (0.4, 2.9, 0.4), loc=(s * 1.75, -0.08, 3.0), bevel=0.08)  # side rails
        for y in (-1.35, 1.2):
            block(w, (0.42, 0.42, 2.3), loc=(s * 1.75, y, 1.75), bevel=0.08)  # posts
    hnd = m.piece("WalkerGrips", "Dark", bone="Torso")
    for s in (1, -1):
        block(hnd, (0.75, 0.55, 0.55), loc=(s * 1.15, -1.35, 3.0), bevel=0.1)
    feet = m.piece("WalkerFeet", "MetalDark", bone="Torso")
    for s in (1, -1):
        for y in (-1.45, 1.1):
            block(feet, (0.95, 1.0, 0.5), loc=(s * 1.75, y, 0.25), top=(0.8, 0.8), bevel=0.1)
            cyl(feet, 0.28, 0.5, (s * 1.75, y, 0.62), seg=6)
    plate = m.piece("HazardPlate", "Gold", bone="Torso")
    block(plate, (2.1, 0.22, 1.2), loc=(0, -1.6, 2.35), bevel=0.06)
    stripes = m.piece("HazardStripes", "Dark", bone="Torso")
    for i in range(-3, 4):
        block(stripes, (0.26, 0.1, 1.3), loc=(i * 0.3, -1.76, 2.35), rot=(0, 35, 0), bevel=0)
    frame = m.piece("HazardFrame", "MetalDark", bone="Torso")
    for z in (1.7, 3.0):
        block(frame, (2.3, 0.26, 0.16), loc=(0, -1.62, z), bevel=0.03)
    can = m.piece("Canisters", "Red", bone="Torso", shadow=True)
    cap = m.piece("CanisterCaps", "MetalDark", bone="Torso")
    for s in (1, -1):
        for y in (-0.55, 0.45):
            cyl(can, 0.5, 2.0, (s * 2.45, y, 2.35), seg=8)
            cyl(cap, 0.52, 0.2, (s * 2.45, y, 3.4), seg=8)
            cyl(cap, 0.52, 0.2, (s * 2.45, y, 1.3), seg=8)
    # rear rocket nozzles with glow
    nz = m.piece("RocketNozzles", "MetalDark", bone="Torso", shadow=True)
    gw = m.piece("RocketGlow", "Glow", "Neon", bone="Torso")
    for s in (1, -1):
        cyl(nz, 0.5, 1.1, (s * 0.75, 1.75, 2.7), rot=(90, 0, 0), seg=8, r2=0.38)
        cyl(nz, 0.34, 0.9, (s * 0.75, 1.1, 2.7), rot=(90, 0, 0), seg=8)
        cyl(gw, 0.3, 0.16, (s * 0.75, 2.35, 2.7), rot=(90, 0, 0), seg=8)
