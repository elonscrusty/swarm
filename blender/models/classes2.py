"""Eight more class characters for the twelve-character roster (category "Classes"):
CoachCrunch, DougJanitor, PeterParkour, BarryPlotter, Rambozo, Swolverine, CrashCassidy, KnucklesMcGee.

Same rig contract as models/classes.py (read that first): feet at z = 0, front = -Y, the character's LEFT
is +X, six bone pieces named Torso / Head / LeftArm / RightArm / LeftLeg / RightLeg, every other piece names
the bone it is welded to ("Head", "Eyes" and "Face*" are the face and stay under a skin hat; every other
Head-bone piece is headgear). Each model sets its own joint points through rig() (MeshCatalog Joints).

Art language: docs/redesign/reference/Swarm-Characters.png and the per-character reference pictures: squat
bodies, BIG heads, oversized hands / boots / gear, chunky faceted forms, strong main colours. Humans use Granny
Boom's compact stylisation. Pieces share a slot + bone wherever they can, to keep the MeshPart count low.

Skin slots (recoloured by skins): Metal / MetalDark, Cloth / Cloth2, Accent, Gold, Hat / HatAccent. Every other
slot name is private to the model (Skin, Hair, Dark, White, Leather, Red, Clay, Copper ...).
"""

import math

from mathutils import Vector

from models.classes import SIDES, cyl, rig, std_joints, tube
from models.hats import arc_shell, band, block, lathe, mark, revolve, slab, sweep, turn
from swarmkit import register


# ================================================================================ shared helpers

def eye_pair(m, z, x=0.5, y=-0.9, r=0.36, pr=0.2, look=(0.0, 0.0), depth=0.22):
    """Round eyes: white discs (FaceEyeWhite) and dark pupils (Eyes, returned so the mouth can join it)."""
    ew = m.piece("FaceEyeWhite", "White", bone="Head")
    ep = m.piece("Eyes", "Dark", bone="Head")
    for s in (1, -1):
        cyl(ew, r, depth, (s * x, y, z), rot=(90, 0, 0), seg=8)
        cyl(ep, pr, depth, (s * x + s * look[0], y - 0.09, z + look[1]), rot=(90, 0, 0), seg=8)
    return ep


def brows(p, x, y, z, w=0.8, t=0.2, d=0.28, tilt=16):
    """Angry brows when tilt > 0 (inner ends low), sad or tired when negative."""
    for s in (1, -1):
        block(p, (w, t, d), loc=(s * x, y, z), rot=(0, -s * tilt, 0), bevel=0.04)


def star(p, r_out, r_in, depth, loc, rot=(0, 0, 0), pts=5):
    """Five-point star slab facing front (extruded along Y)."""
    outline = []
    for i in range(pts * 2):
        a = math.pi * i / pts
        r = r_out if i % 2 == 0 else r_in
        outline.append((math.sin(a) * r, math.cos(a) * r))
    slab(p, outline, depth, loc=loc, rot=rot, bevel=0.0)


def spikes(p, base, count, r, h, spread, seed_dir=(0, 0, 1), seg=4, phase=0.0):
    """Cones fanned out from `base`: used for hair tufts, broom straw, mop strands."""
    for i in range(count):
        a = phase + i / count * math.tau
        d = (math.cos(a) * spread[0], math.sin(a) * spread[1], seed_dir[2] + (i % 2) * 0.25)
        p.spike(r, h, seg=seg, base=base, direction=d)


# ================================================================================== CoachCrunch

@register("CoachCrunch", "Classes", "Loud gym teacher: barrel chest in a royal-blue polo, tiny red shorts, bare thighs, striped "
                                    "tube socks and huge white sneakers, thick moustache and a shouting mouth under a flat-top and red sweatband, "
                                    "whistle on a lanyard, a net sack of dodgeballs on his back and a big red dodgeball in his "
                                    "right hand.")
def coach(m):
    rig(m, dict(Skin="e6b088", Hair="3b2b22", Dark="1c1d21", White="f4f2ea", Cloth="2f6fe0", Cloth2="d83a2e",
                Accent="f0c428", Gold="f0c428", Hat="d83a2e", HatAccent="f4f2ea", Leather="6b4a2e", Red="d83a2e",
                Net="cdbf93", Metal="b8bcc4", MetalDark="5a5f69"),
        std_joints(4.0, 1.85, 3.8, 0.75, 2.0))
    # torso: broad barrel chest in a polo, tiny shorts below
    t = m.piece("Torso", "Cloth", bone="Torso", shadow=True)
    lathe(t, [(1.2, 2.15), (1.4, 2.6), (1.6, 3.3), (1.54, 3.95), (1.05, 4.35), (0.0, 4.4)], seg=8, phase=22.5, sy=0.85)
    col = m.piece("Collar", "White", bone="Torso")
    band(col, 0.95, 1.32, 4.0, 4.34, seg=8, phase=22.5, sy=0.85)
    sh = m.piece("Shorts", "Cloth2", bone="Torso", shadow=True)
    lathe(sh, [(1.05, 1.55), (1.28, 1.8), (1.3, 2.2), (1.2, 2.3)], seg=8, phase=22.5, sy=0.85)
    ss = m.piece("ShortsStripe", "White", bone="Torso")
    for s in (1, -1):
        block(ss, (0.12, 0.9, 0.62), loc=(s * 1.24, 0, 1.95), rot=(0, 0, 0), bevel=0.02)
    lan = m.piece("Lanyard", "Cloth2", bone="Torso")
    for s in (1, -1):
        sweep(lan, [(s * 0.6, -1.0, 4.3), (s * 0.35, -1.42, 3.9), (0.0, -1.5, 3.5)], [0.08, 0.08, 0.08], seg=4, sx=1.6)
    wh = m.piece("Whistle", "Gold", "Metal", bone="Torso")
    block(wh, (0.62, 0.42, 0.36), loc=(0, -1.6, 3.35), bevel=0.08)
    block(wh, (0.24, 0.5, 0.2), loc=(0, -1.95, 3.3), bevel=0.04)
    cyl(wh, 0.2, 0.3, (0, -1.6, 3.62), seg=6)
    # back: net sack of dodgeballs
    bag = m.piece("NetSack", "Net", bone="Torso", shadow=True)
    lathe(bag, [(0.0, 2.5), (0.9, 2.62), (1.25, 3.1), (1.32, 3.7), (1.05, 4.2), (0.0, 4.25)], seg=8, loc=(0, 1.95, 0),
          sy=0.7)
    nb = m.piece("NetBands", "MetalDark", bone="Torso")
    for z, r in ((3.0, 1.26), (3.55, 1.34)):
        band(nb, r - 0.02, r + 0.1, z - 0.05, z + 0.05, seg=8, loc=(0, 1.95, 0), sy=0.7)
    balls = m.piece("SackBalls", "Red", bone="Torso", shadow=True)
    for x, y, z, r in ((-0.6, 1.95, 4.45, 0.62), (0.6, 2.0, 4.5, 0.62), (0.0, 1.8, 5.0, 0.62)):
        balls.ico(r, loc=(x, y, z), subdiv=1)
    bs = m.piece("SackStraps", "Leather", bone="Torso")
    for s in (1, -1):
        sweep(bs, [(s * 1.0, 1.6, 4.2), (s * 1.25, 0.1, 4.45), (s * 1.0, -1.4, 3.6), (s * 0.7, -1.4, 2.7)],
              [0.13, 0.13, 0.13, 0.13], seg=4, sx=1.8)
    # head: big square-jawed head, shouting
    h = m.piece("Head", "Skin", bone="Head", shadow=True)
    block(h, (2.5, 2.1, 2.0), loc=(0, 0, 5.05), top=(0.97, 0.97), bottom=(0.95, 0.95), bevel=0.55)
    nose = m.piece("FaceNose", "Skin", bone="Head")
    block(nose, (0.62, 0.6, 0.62), loc=(0, -1.2, 4.85), bevel=0.12)
    for s in (1, -1):
        block(nose, (0.4, 0.5, 0.7), loc=(s * 1.3, 0.05, 4.95), bevel=0.1)
    ep = eye_pair(m, 5.4, x=0.68, y=-1.04, r=0.44, pr=0.26, look=(0.0, -0.04))
    block(ep, (1.2, 0.12, 0.6), loc=(0, -1.07, 4.23), bevel=0)  # open mouth
    teeth = m.piece("FaceTeeth", "White", bone="Head")
    block(teeth, (1.04, 0.1, 0.2), loc=(0, -1.13, 4.45), bevel=0)
    brow = m.piece("FaceBrow", "Hair", bone="Head")
    brows(brow, 0.72, -1.1, 5.92, w=1.12, t=0.24, d=0.34, tilt=18)
    mus = m.piece("FaceMoustache", "Hair", bone="Head")
    block(mus, (1.5, 0.4, 0.42), loc=(0, -1.15, 4.69), bevel=0.08)
    for s in (1, -1):
        block(mus, (0.6, 0.4, 0.36), loc=(s * 0.98, -1.1, 4.49), rot=(0, s * 25, 0), bevel=0.06)
    hair = m.piece("Hair", "Hair", bone="Head", shadow=True)
    lathe(hair, [(1.3, 5.85), (1.32, 6.2), (1.15, 6.5), (0.8, 6.6), (0.0, 6.62)], seg=8, sy=0.84)  # crew cut
    block(hair, (2.5, 0.4, 0.9), loc=(0, 0.95, 5.5), bevel=0.08)
    hb = m.piece("Headband", "Hat", bone="Head")
    band(hb, 1.12, 1.4, 5.85, 6.2, seg=8, phase=22.5, sy=0.86)
    sweep(hb, [(0.9, 0.9, 6.0), (1.8, 1.6, 5.7), (2.5, 2.3, 5.2)], [0.18, 0.18, 0.04], seg=4, sx=2.0)
    bs2 = m.piece("HeadbandStripe", "HatAccent", bone="Head")
    band(bs2, 1.14, 1.43, 5.98, 6.08, seg=8, phase=22.5, sy=0.86)
    # arms: thick bare arms in short sleeves, fists
    for s, side in SIDES:
        bone = side + "Arm"
        a = m.piece(bone, "Skin", bone=bone)
        block(a, (0.95, 1.0, 1.7), loc=(s * 2.15, 0, 3.1), bottom=(0.95, 0.95), bevel=0.16)
        block(a, (1.08, 1.12, 0.78), loc=(s * 2.15, -0.1, 2.15), bevel=0.14)
        sl = m.piece(bone + "Sleeve", "Cloth", bone=bone)
        block(sl, (1.15, 1.2, 0.95), loc=(s * 2.15, 0, 3.6), bevel=0.12)
        bd = m.piece(bone + "Band", "White", bone=bone)
        block(bd, (1.02, 1.06, 0.2), loc=(s * 2.15, -0.02, 2.68), bevel=0.03)
    ball = m.piece("Dodgeball", "Red", bone="RightArm", shadow=True)
    ball.ico(0.95, loc=(-2.3, -1.15, 2.1), subdiv=2)
    seam = m.piece("DodgeballSeam", "White", bone="RightArm")
    band(seam, 0.93, 0.99, -0.07, 0.07, seg=8, loc=(-2.3, -1.15, 2.1), rot=(0, 0, 0))
    # legs: bare thighs, striped socks, huge sneakers
    for s, side in SIDES:
        bone = side + "Leg"
        lg = m.piece(bone, "Skin", bone=bone)
        block(lg, (0.98, 0.98, 0.75), loc=(s * 0.75, 0, 1.35), bevel=0.14)
        shoe = m.piece(bone + "Shoe", "White", bone=bone, shadow=True)
        block(shoe, (1.0, 1.0, 0.6), loc=(s * 0.75, 0.05, 0.98), bevel=0.1)  # tube sock
        block(shoe, (1.45, 2.0, 0.9), loc=(s * 0.75, -0.45, 0.55), top=(0.85, 0.7), shift=(0, 0.15), bevel=0.2)
        block(shoe, (1.4, 0.95, 0.72), loc=(s * 0.75, -1.2, 0.42), top=(0.85, 0.8), bevel=0.2)
        st = m.piece(bone + "Stripe", "Cloth2", bone=bone)
        block(st, (1.05, 1.05, 0.1), loc=(s * 0.75, 0.05, 1.12), bevel=0.02)
        block(st, (1.05, 1.05, 0.1), loc=(s * 0.75, 0.05, 1.27), bevel=0.02)
        so = m.piece(bone + "Sole", "Dark", bone=bone)
        block(so, (1.56, 2.25, 0.24), loc=(s * 0.75, -0.5, 0.12), bevel=0.06)
        sw = m.piece(bone + "Swoosh", "Cloth", bone=bone)
        block(sw, (1.5, 1.1, 0.26), loc=(s * 0.75, -0.3, 0.62), bevel=0.04)


# ================================================================================== DougJanitor

@register("DougJanitor", "Classes", "Exhausted janitor: slouching slate-blue work shirt and pants, droopy half-lidded eyes with "
                                    "eye bags, big red nose and grey moustache under a crooked navy cap, key ring on the belt, "
                                    "oversized yellow cleaning tank on his back with hose coils, a spray bottle and a plunger, "
                                    "a shaggy mop in his right hand and a pink soap bar with bubbles in his left.")
def doug(m):
    rig(m, dict(Skin="d9aa84", Hair="9a9aa2", Dark="1c1d21", White="f0eee4", Cloth="5a85a8", Cloth2="3e5c7c",
                Accent="f0c428", Gold="c9a04a", Hat="26364e", HatAccent="f0c428", Leather="6a4a2e", Metal="b8bcc4",
                MetalDark="5a5f69", Pink="f08ac0", Blue="3a8ad8", Red="d03030", Wood="9a7040", Strand="c9c6b8",
                Hose="3a3d44", Bag="8a7a8a", Nose="d98a78", Bubble="d8f0ff"),
        std_joints(3.95, 1.55, 3.55, 0.58, 1.9))
    m.extra["joints"]["Neck"] = (0.0, -0.35, 3.95)
    t = m.piece("Torso", "Cloth", bone="Torso", shadow=True)
    lathe(t, [(1.0, 1.8), (1.3, 2.3), (1.4, 3.0), (1.3, 3.6), (0.9, 4.0), (0.0, 4.05)], seg=8, phase=22.5, sy=0.88)
    belly = m.piece("Belly", "Cloth", bone="Torso")
    belly.ico(0.95, loc=(0, -0.65, 2.55), scale=(1.1, 0.8, 0.85), subdiv=1)
    clr = m.piece("Collar", "Cloth2", bone="Torso")
    band(clr, 0.85, 1.25, 3.7, 4.0, seg=8, phase=22.5, sy=0.88)
    tag = m.piece("NameTag", "White", bone="Torso")
    block(tag, (0.6, 0.1, 0.32), loc=(0.62, -1.28, 3.35), bevel=0.02)
    belt = m.piece("Belt", "Leather", bone="Torso")
    band(belt, 1.2, 1.42, 1.95, 2.28, seg=8, phase=22.5, sy=0.88)
    block(belt, (0.5, 0.16, 0.36), loc=(0, -1.3, 2.1), bevel=0.04)
    ring = m.piece("KeyRing", "Metal", bone="Torso")
    revolve(ring, [(0.22, -0.05), (0.34, -0.05), (0.34, 0.05), (0.22, 0.05)], seg=8, loc=(1.3, -0.55, 1.95),
            rot=(0, 90, 0))
    keys = m.piece("Keys", "Gold", "Metal", bone="Torso")
    for dy, rz in ((-0.2, -15), (0.15, 12), (-0.45, -35)):
        block(keys, (0.12, 0.18, 0.52), loc=(1.3, -0.55 + dy, 1.55), rot=(rz, 0, 0), bevel=0.02)
    # cleaning tank backpack
    tank = m.piece("Tank", "Accent", bone="Torso", shadow=True)
    cyl(tank, 1.12, 2.7, (0, 1.95, 3.2), seg=8, phase=22.5)
    cap = m.piece("TankCap", "MetalDark", bone="Torso")
    cyl(cap, 0.55, 0.3, (0, 1.95, 4.66), seg=8)
    cyl(cap, 0.3, 0.3, (0, 1.95, 4.9), seg=8)
    hose = m.piece("Hose", "Hose", bone="Torso")
    for z in (2.45, 2.85, 3.25):
        band(hose, 1.08, 1.27, z - 0.08, z + 0.08, seg=8, phase=22.5, loc=(0, 1.95, 0))
    sweep(hose, [(-1.05, 2.5, 2.4), (-1.55, 2.2, 1.7), (-1.5, 1.6, 1.0), (-1.2, 1.2, 0.7)], [0.14, 0.14, 0.14, 0.14],
          seg=5)
    bot = m.piece("SprayBottle", "Blue", bone="Torso")
    cyl(bot, 0.42, 1.2, (1.55, 2.0, 2.6), seg=6)
    block(bot, (0.5, 0.8, 0.35), loc=(1.55, 1.75, 3.35), bevel=0.06)
    bot2 = m.piece("SprayNozzle", "MetalDark", bone="Torso")
    block(bot2, (0.2, 0.5, 0.2), loc=(1.55, 1.3, 3.4), bevel=0.03)
    block(bot2, (0.16, 0.2, 0.4), loc=(1.55, 1.5, 3.05), bevel=0.03)
    plh = m.piece("PlungerHandle", "Wood", bone="Torso")
    sweep(plh, [(0.75, 2.2, 3.7), (0.95, 2.4, 5.0), (1.05, 2.5, 6.2)], [0.15, 0.15, 0.15], seg=6)
    plc = m.piece("PlungerCup", "Red", bone="Torso")
    lathe(plc, [(0.15, 6.0), (0.4, 6.15), (0.68, 6.6), (0.7, 6.72), (0.0, 6.76)], seg=8, loc=(1.05, 2.5, 0))
    # head: big, slumped forward
    h = m.piece("Head", "Skin", bone="Head", shadow=True)
    block(h, (2.3, 2.0, 1.9), loc=(0, -0.45, 5.0), bottom=(0.9, 0.9), bevel=0.5)
    nose = m.piece("FaceNose", "Nose", bone="Head")
    nose.ico(0.55, loc=(0, -1.62, 4.75), scale=(1.0, 1.0, 1.1), subdiv=1)
    ear = m.piece("FaceEar", "Skin", bone="Head")
    for s in (1, -1):
        block(ear, (0.45, 0.55, 0.95), loc=(s * 1.22, -0.4, 5.0), bevel=0.1)
    ep = eye_pair(m, 5.2, x=0.62, y=-1.42, r=0.42, pr=0.22, look=(0.0, -0.1))
    block(ep, (0.7, 0.1, 0.14), loc=(0, -1.5, 4.22), bevel=0)  # flat mouth
    for s in (1, -1):
        block(ep, (0.2, 0.1, 0.32), loc=(s * 0.42, -1.5, 4.12), bevel=0)
    lid = m.piece("FaceLid", "Skin", bone="Head")
    for s in (1, -1):
        block(lid, (1.02, 0.28, 0.46), loc=(s * 0.62, -1.56, 5.42), rot=(0, 0, 0), bevel=0.04)
    bags = m.piece("FaceBags", "Bag", bone="Head")
    for s in (1, -1):
        block(bags, (0.85, 0.1, 0.18), loc=(s * 0.62, -1.5, 4.72), bevel=0.02)
    brow = m.piece("FaceBrow", "Hair", bone="Head")
    brows(brow, 0.66, -1.45, 5.85, w=0.95, t=0.22, d=0.24, tilt=-14)
    mus = m.piece("FaceMoustache", "Hair", bone="Head")
    block(mus, (1.3, 0.4, 0.34), loc=(0, -1.52, 4.5), bevel=0.06)
    for s in (1, -1):
        block(mus, (0.8, 0.4, 0.46), loc=(s * 0.72, -1.46, 4.3), rot=(0, s * 28, 0), bevel=0.06)
    # crooked cap: built straight, then tipped about its own base
    cp = m.piece("Cap", "Hat", bone="Head", shadow=True)
    st = mark(cp)
    lathe(cp, [(1.25, 5.75), (1.3, 5.98), (1.12, 6.32), (0.62, 6.52), (0.0, 6.56)], seg=8, loc=(0, -0.4, 0), sy=0.85)
    block(cp, (1.9, 1.2, 0.18), loc=(0, -1.55, 5.95), rot=(10, 0, 0), bevel=0.05)
    turn(cp, st, (0, -0.4, 5.7), (0, 13, 6))
    cb = m.piece("CapBadge", "HatAccent", bone="Head")
    st = mark(cb)
    block(cb, (0.6, 0.1, 0.36), loc=(0, -1.35, 6.2), rot=(-10, 0, 0), bevel=0.02)
    turn(cb, st, (0, -0.4, 5.7), (0, 13, 6))
    # arms: long sleeves, slumped forward
    for s, side in SIDES:
        bone = side + "Arm"
        a = m.piece(bone, "Cloth", bone=bone)
        block(a, (0.98, 1.05, 1.75), loc=(s * 1.85, -0.2, 2.95), bottom=(0.95, 0.95), bevel=0.16)
        cf = m.piece(bone + "Cuff", "Cloth2", bone=bone)
        block(cf, (1.05, 1.1, 0.24), loc=(s * 1.85, -0.25, 2.2), bevel=0.04)
        hd = m.piece(bone + "Hand", "Skin", bone=bone)
        block(hd, (0.85, 0.9, 0.7), loc=(s * 1.85, -0.35, 1.9), bevel=0.14)
    # mop in the right hand
    ms = m.piece("MopShaft", "Wood", bone="RightArm")
    sweep(ms, [(-1.8, -0.9, 1.0), (-1.85, -0.35, 1.95), (-2.1, 0.2, 6.3)], [0.2, 0.2, 0.2], seg=6)
    mh = m.piece("MopHead", "Strand", bone="RightArm", shadow=True)
    lathe(mh, [(0.7, 0.0), (0.98, 0.25), (0.9, 0.85), (0.55, 1.35), (0.0, 1.5)], seg=8, loc=(-1.8, -1.0, 0), sy=0.85)
    for i in range(8):
        a = i / 8 * math.tau
        mh.spike(0.3, 1.0, seg=4, base=(-1.8 + 0.85 * math.cos(a), -1.0 + 0.72 * math.sin(a), 0.98),
                 direction=(0.35 * math.cos(a), 0.35 * math.sin(a), -1.0))
    mt = m.piece("MopTie", "Metal", bone="RightArm")
    band(mt, 0.55, 0.78, 1.2, 1.4, seg=8, loc=(-1.8, -1.0, 0), sy=0.85)
    band(mt, 0.8, 1.0, 0.55, 0.72, seg=8, loc=(-1.8, -1.0, 0), sy=0.85)
    # soap + bubbles in the left hand
    sp = m.piece("Soap", "Pink", bone="LeftArm")
    block(sp, (1.2, 0.85, 0.58), loc=(2.0, -1.0, 1.95), rot=(0, 0, 15), bevel=0.14)
    bb = m.piece("Bubbles", "Bubble", bone="LeftArm", transparency=0.4)
    for x, y, z, r in ((2.5, -1.3, 2.9, 0.34), (1.8, -1.5, 3.4, 0.24), (2.8, -0.7, 3.5, 0.4), (2.2, -1.1, 4.2, 0.2)):
        bb.ico(r, loc=(x, y, z), subdiv=1)
    # legs: work pants, big boots
    for s, side in SIDES:
        bone = side + "Leg"
        lg = m.piece(bone, "Cloth2", bone=bone)
        block(lg, (0.98, 0.98, 1.4), loc=(s * 0.58, 0, 1.2), bottom=(0.95, 0.95), bevel=0.14)
        b = m.piece(bone + "Boot", "Leather", bone=bone, shadow=True)
        block(b, (1.1, 1.6, 0.8), loc=(s * 0.58, -0.3, 0.4), top=(0.9, 0.8), shift=(0, 0.1), bevel=0.16)
        so = m.piece(bone + "Sole", "Dark", bone=bone)
        block(so, (1.16, 1.68, 0.16), loc=(s * 0.58, -0.3, 0.08), bevel=0.02)


# ================================================================================= PeterParkour

@register("PeterParkour", "Classes", "Lanky parkour kid from the reference sheet: orange mask-head with big round goggles and a knotted "
                                    "bandana, teal hoodie under an orange vest, maroon shorts, grey leggings, yellow-taped knee "
                                    "and elbow pads, fingerless gloves, olive messenger bag, an orange crate of spare shoes on his "
                                    "back and huge orange platform sneakers with copper coil springs.")
def peter(m):
    rig(m, dict(Skin="e8b08a", Dark="1c1d21", White="f4f2ea", Cloth="2f7f93", Cloth2="f07a28", Accent="f0cc2a",
                Gold="f0cc2a", Metal="8a8e98", MetalDark="4a4c54", Leather="3a3c44", Lens="d6e6ee", Maroon="a8404c",
                Leggings="6f6f7c", Cream="dcd4bc", Copper="b87333", Olive="7a7a4a", MaskDark="d0601c"),
        std_joints(4.6, 1.22, 4.45, 0.65, 2.95))
    # torso: slim teal hoodie, orange vest, maroon shorts
    t = m.piece("Torso", "Cloth", bone="Torso", shadow=True)
    lathe(t, [(0.85, 2.9), (1.0, 3.3), (1.08, 4.0), (0.95, 4.5), (0.6, 4.72), (0.0, 4.76)], seg=8, phase=22.5, sy=0.85)
    hood = m.piece("Hood", "Cloth", bone="Torso")
    hood.ico(0.8, loc=(0, 0.75, 4.75), scale=(1.25, 0.85, 0.7), subdiv=1)
    vest = m.piece("Vest", "Cloth2", bone="Torso", shadow=True)
    arc_shell(vest, [(1.0, 4.55, 0), (1.22, 4.0, 0), (1.22, 3.3, 0), (1.14, 2.9, 0)], 28, 332, seg=8, thick=0.15, sy=0.88)
    for s in (1, -1):
        block(vest, (0.62, 0.26, 0.62), loc=(s * 0.85, -0.92, 3.1), bevel=0.06)
    patch = m.piece("VestPatch", "Cream", bone="Torso")
    block(patch, (0.6, 0.08, 0.46), loc=(-0.78, -1.0, 3.95), rot=(0, 0, -6), bevel=0.02)
    block(patch, (0.8, 0.08, 0.55), loc=(0, 1.1, 3.85), bevel=0.02)
    sh = m.piece("Shorts", "Maroon", bone="Torso", shadow=True)
    lathe(sh, [(0.92, 2.42), (1.18, 2.62), (1.2, 3.0), (1.0, 3.12)], seg=8, phase=22.5, sy=0.85)
    bag = m.piece("MessengerBag", "Olive", bone="Torso", shadow=True)
    block(bag, (0.62, 1.35, 1.1), loc=(1.42, 0.35, 2.85), bevel=0.12)
    flap = m.piece("MessengerFlap", "Leather", bone="Torso")
    block(flap, (0.7, 1.4, 0.3), loc=(1.42, 0.35, 3.3), bevel=0.06)
    sweep(flap, [(-0.85, -0.2, 4.7), (-0.2, -1.12, 4.0), (0.6, -1.15, 3.3), (1.3, -0.3, 3.1)], [0.1, 0.1, 0.1, 0.1],
          seg=4, sx=1.8)
    # back: orange crate of spare shoes
    crate = m.piece("Crate", "Cloth2", bone="Torso", shadow=True)
    block(crate, (2.1, 1.35, 1.7), loc=(0, 1.55, 3.75), bevel=0.14)
    block(crate, (2.18, 1.4, 0.3), loc=(0, 1.55, 4.7), bevel=0.06)
    cs = m.piece("CrateStraps", "MetalDark", bone="Torso")
    for z in (3.2, 4.3):
        block(cs, (2.24, 1.42, 0.2), loc=(0, 1.55, z), bevel=0.02)
    for s in (1, -1):
        block(cs, (0.2, 1.8, 1.8), loc=(s * 0.7, 1.15, 3.8), bevel=0.02)
    soles = m.piece("CrateSoles", "Cream", bone="Torso")
    uppers = m.piece("CrateUppers", "Cloth2", bone="Torso")
    for x, rz in ((-0.55, -10), (0.0, 4), (0.55, 12)):
        block(soles, (0.5, 0.95, 0.26), loc=(x, 1.55, 4.98), rot=(0, rz, 0), bevel=0.04)
        block(uppers, (0.44, 0.7, 0.34), loc=(x, 1.62, 5.22), rot=(0, rz, 0), bevel=0.06)
    # head: orange mask-head with round goggles
    h = m.piece("Head", "Cloth2", bone="Head", shadow=True)
    block(h, (2.2, 1.9, 1.8), loc=(0, 0, 5.5), bottom=(0.85, 0.9), bevel=0.55)
    nose = m.piece("FaceNose", "Cloth2", bone="Head")
    block(nose, (0.42, 0.34, 0.55), loc=(0, -1.0, 5.2), bevel=0.08)
    seam = m.piece("FaceSeam", "MaskDark", bone="Head")
    block(seam, (1.0, 0.1, 0.1), loc=(0, -0.95, 4.85), bevel=0)
    ep = eye_pair(m, 5.62, x=0.6, y=-1.08, r=0.42, pr=0.25, look=(0.0, 0.0))
    strap = m.piece("GoggleStrap", "Leather", bone="Head")
    band(strap, 1.0, 1.16, 5.3, 5.82, seg=8, phase=22.5, sx=1.08, sy=0.9)
    rim = m.piece("GoggleRims", "MetalDark", bone="Head", shadow=True)
    lens = m.piece("GoggleLens", "Lens", bone="Head", transparency=0.8)
    for s in (1, -1):
        band(rim, 0.5, 0.72, -0.26, 0.26, seg=8, loc=(s * 0.6, -1.05, 5.62), rot=(90, 0, 0))
        cyl(lens, 0.54, 0.1, (s * 0.6, -1.28, 5.62), rot=(90, 0, 0), seg=8)
    block(rim, (0.5, 0.45, 0.3), loc=(0, -1.15, 5.62), bevel=0.04)
    knot = m.piece("BandanaKnot", "Cloth2", bone="Head")
    knot.ico(0.4, loc=(0, 1.05, 5.5), subdiv=1)
    sweep(knot, [(0.1, 1.2, 5.45), (0.6, 1.5, 5.1), (0.9, 1.7, 4.6)], [0.22, 0.2, 0.04], seg=4, sx=1.6)
    sweep(knot, [(-0.1, 1.2, 5.45), (-0.55, 1.55, 5.2), (-0.8, 1.8, 4.8)], [0.22, 0.2, 0.04], seg=4, sx=1.6)
    # arms: teal sleeves, taped elbow pads, fingerless gloves
    for s, side in SIDES:
        bone = side + "Arm"
        a = m.piece(bone, "Cloth", bone=bone)
        block(a, (0.72, 0.76, 1.55), loc=(s * 1.5, 0, 3.6), bottom=(0.9, 0.9), bevel=0.14)
        pad = m.piece(bone + "Pad", "MetalDark", bone=bone)
        block(pad, (0.92, 0.95, 0.52), loc=(s * 1.5, 0.02, 3.5), bevel=0.12)
        tape = m.piece(bone + "Tape", "Accent", bone=bone)
        block(tape, (0.98, 1.0, 0.18), loc=(s * 1.5, 0.02, 3.5), bevel=0.02)
        hd = m.piece(bone + "Hand", "Skin", bone=bone)
        block(hd, (0.58, 0.55, 0.6), loc=(s * 1.5, -0.1, 2.5), bevel=0.1)
        gl = m.piece(bone + "Glove", "Leather", bone=bone)
        block(gl, (0.7, 0.66, 0.36), loc=(s * 1.5, -0.08, 2.72), bevel=0.08)
    # legs: grey leggings, knee pads, spring sneakers
    for s, side in SIDES:
        bone = side + "Leg"
        x = s * 0.65
        lg = m.piece(bone, "Leggings", bone=bone)
        block(lg, (0.62, 0.66, 1.5), loc=(x, 0, 2.3), bevel=0.12)
        kp = m.piece(bone + "KneePad", "MetalDark", bone=bone)
        block(kp, (0.86, 0.6, 0.72), loc=(x, -0.2, 2.1), bevel=0.14)
        kt = m.piece(bone + "KneeTape", "Accent", bone=bone)
        block(kt, (0.9, 0.66, 0.16), loc=(x, -0.18, 1.82), bevel=0.02)
        block(kt, (0.9, 0.66, 0.16), loc=(x, -0.18, 2.38), bevel=0.02)
        so = m.piece(bone + "Sole", "Cream", bone=bone, shadow=True)
        block(so, (1.2, 2.0, 0.28), loc=(x, -0.4, 0.14), bevel=0.06)
        block(so, (1.2, 2.0, 0.3), loc=(x, -0.4, 0.99), bevel=0.06)
        sp = m.piece(bone + "Spring", "Copper", bone=bone)
        for y in (-0.95, 0.15):
            for z in (0.4, 0.58, 0.76):
                revolve(sp, [(0.22, -0.06), (0.42, -0.06), (0.42, 0.06), (0.22, 0.06)], seg=8, loc=(x, y, z))
        up = m.piece(bone + "Shoe", "Cloth2", bone=bone, shadow=True)
        block(up, (1.05, 1.7, 0.72), loc=(x, -0.45, 1.5), top=(0.85, 0.7), shift=(0, 0.1), bevel=0.14)
        tc = m.piece(bone + "ToeCap", "Cream", bone=bone)
        block(tc, (1.12, 0.75, 0.5), loc=(x, -1.15, 1.4), bevel=0.12)
        st = m.piece(bone + "ShoeStrap", "Accent", bone=bone)
        block(st, (1.12, 0.34, 0.16), loc=(x, -0.5, 1.78), bevel=0.02)
        block(st, (1.12, 0.34, 0.16), loc=(x, 0.1, 1.74), bevel=0.02)


# ================================================================================= BarryPlotter

@register("BarryPlotter", "Classes", "Wiry gardener from the reference sheet: messy brown hair, big round goggle eyes, long nose and a "
                                    "grin, plum patched coat with a green apron and yellow neckerchief, green wellies with tan "
                                    "cuffs, a copper watering-can backpack with hose coil, spout and spade, and a straw-broom "
                                    "staff in his right hand with three flower pots tied up its shaft.")
def barry(m):
    rig(m, dict(Skin="eab898", Hair="8a5a30", Dark="1c1d21", White="f4f2ea", Cloth="7a3a68", Cloth2="6a8a3a",
                Accent="f0c428", Gold="f0c428", Metal="a8acb4", MetalDark="5a5f69", Leather="6a4a2e", Pants="5a4430",
                Wellie="4a6a48", Cuff="c8b090", Copper="b8703a", Clay="c8643a", Leaf="4a9a3a", Wood="8a6238",
                Straw="b08a48", Lens="a8e098", Hose="3f6a52", Cream="e6dcc0"),
        std_joints(4.0, 1.3, 3.7, 0.55, 1.75))
    # torso: long plum coat, apron, scarf
    t = m.piece("Torso", "Cloth", bone="Torso", shadow=True)
    lathe(t, [(1.05, 1.4), (1.32, 1.9), (1.14, 2.7), (1.06, 3.5), (0.72, 3.95), (0.0, 4.0)], seg=8, phase=22.5, sy=0.88)
    ap = m.piece("Apron", "Cloth2", bone="Torso")
    block(ap, (1.55, 0.16, 1.9), loc=(0, -1.0, 2.55), bevel=0.04)
    block(ap, (1.05, 0.16, 0.85), loc=(0, -0.96, 3.6), bevel=0.04)
    block(ap, (1.0, 0.3, 0.6), loc=(0, -1.08, 2.0), bevel=0.06)
    tools = m.piece("ApronTools", "Wood", bone="Torso")
    block(tools, (0.14, 0.14, 0.7), loc=(-0.25, -1.1, 2.4), bevel=0.02)
    block(tools, (0.14, 0.14, 0.7), loc=(0.2, -1.1, 2.4), bevel=0.02)
    blades = m.piece("ApronBlades", "Metal", bone="Torso")
    block(blades, (0.28, 0.1, 0.4), loc=(-0.25, -1.1, 2.9), bevel=0.02)
    block(blades, (0.2, 0.1, 0.4), loc=(0.2, -1.1, 2.9), bevel=0.02)
    seed = m.piece("SeedPacket", "Cream", bone="Torso")
    block(seed, (0.4, 0.1, 0.52), loc=(-0.6, -1.12, 2.3), rot=(0, 0, 10), bevel=0.02)
    sc = m.piece("Scarf", "Accent", bone="Torso")
    band(sc, 0.8, 1.2, 3.72, 4.14, seg=8, phase=22.5, sy=0.88)
    slab(sc, [(-0.6, 0.5), (0.6, 0.5), (0.0, -0.75)], 0.22, loc=(0, -1.0, 3.55), rot=(-14, 0, 0), bevel=0.03)
    patch = m.piece("CoatPatch", "Cream", bone="Torso")
    block(patch, (0.1, 0.55, 0.55), loc=(-1.2, 0.1, 2.0), rot=(0, 0, 0), bevel=0.02)
    block(patch, (0.6, 0.1, 0.6), loc=(0.4, 1.1, 2.0), rot=(0, 0, 8), bevel=0.02)
    # back: copper watering can, hose, spade
    can = m.piece("WateringCan", "Copper", bone="Torso", shadow=True)
    cyl(can, 0.9, 2.1, (0, 1.65, 3.1), seg=8, phase=22.5)
    lathe(can, [(0.9, 4.1), (0.86, 4.2), (0.5, 4.3), (0.0, 4.34)], seg=8, loc=(0, 1.65, 0), phase=22.5)
    sweep(can, [(0.55, 1.8, 2.5), (1.0, 2.2, 3.6), (1.45, 2.4, 4.7)], [0.26, 0.24, 0.2], seg=6)
    lathe(can, [(0.22, 4.55), (0.4, 4.75), (0.75, 5.05), (0.0, 5.1)], seg=8, loc=(1.5, 2.4, 0))
    sweep(can, [(-0.55, 1.5, 4.25), (-0.5, 2.3, 4.7), (-0.4, 2.8, 3.7), (-0.5, 2.7, 2.6)], [0.15, 0.15, 0.15, 0.15], seg=4)
    rose = m.piece("CanRose", "MetalDark", bone="Torso")
    cyl(rose, 0.3, 0.1, (1.5, 2.4, 5.1), seg=8)
    hose = m.piece("Hose", "Hose", bone="Torso")
    for y in (2.4, 2.62):
        revolve(hose, [(0.5, -0.1), (0.9, -0.1), (0.9, 0.1), (0.5, 0.1)], seg=8, loc=(0, y, 2.9), rot=(90, 0, 0))
    spade = m.piece("SpadeBlade", "Metal", bone="Torso")
    block(spade, (0.6, 0.12, 0.8), loc=(-0.7, 1.75, 5.6), top=(0.7, 1.0), bevel=0.03)
    sh = m.piece("SpadeHandle", "Wood", bone="Torso")
    sweep(sh, [(-0.7, 1.75, 4.2), (-0.7, 1.75, 5.3)], [0.12, 0.12], seg=4)
    bs = m.piece("PackStraps", "Leather", bone="Torso")
    for s in (1, -1):
        sweep(bs, [(s * 0.85, 1.5, 3.8), (s * 1.0, 0.0, 4.0), (s * 0.85, -1.0, 3.3), (s * 0.6, -1.0, 2.4)],
              [0.12, 0.12, 0.12, 0.12], seg=4, sx=1.8)
    # head: goggle-eyed grin
    h = m.piece("Head", "Skin", bone="Head", shadow=True)
    block(h, (2.2, 1.9, 1.9), loc=(0, 0, 5.0), bottom=(0.88, 0.9), bevel=0.5)
    nose = m.piece("FaceNose", "Skin", bone="Head")
    block(nose, (0.44, 0.75, 0.5), loc=(0, -1.25, 4.78), bevel=0.1)
    for s in (1, -1):
        block(nose, (0.4, 0.5, 0.8), loc=(s * 1.28, 0.05, 4.95), bevel=0.1)
    ep = eye_pair(m, 5.2, x=0.62, y=-0.82, r=0.44, pr=0.22, look=(0.0, 0.0))
    sweep(ep, [(-0.6, -1.02, 4.4), (-0.3, -1.1, 4.22), (0.3, -1.1, 4.22), (0.6, -1.02, 4.4)], [0.07, 0.08, 0.08, 0.07],
          seg=4)
    gs = m.piece("GoggleStrap", "Leather", bone="Head")
    band(gs, 1.04, 1.18, 4.95, 5.38, seg=8, phase=22.5, sx=1.0, sy=0.88)
    rim = m.piece("GoggleRims", "MetalDark", bone="Head", shadow=True)
    lens = m.piece("GoggleLens", "Lens", bone="Head", transparency=0.7)
    for s in (1, -1):
        band(rim, 0.48, 0.68, -0.25, 0.25, seg=8, loc=(s * 0.62, -1.0, 5.2), rot=(90, 0, 0))
        cyl(lens, 0.5, 0.1, (s * 0.62, -1.23, 5.2), rot=(90, 0, 0), seg=8)
    block(rim, (0.3, 0.3, 0.18), loc=(0, -0.98, 5.2), bevel=0.02)
    hair = m.piece("Hair", "Hair", bone="Head", shadow=True)
    lathe(hair, [(1.0, 5.3), (1.16, 5.65), (1.0, 6.05), (0.55, 6.28), (0.0, 6.32)], seg=8, sy=0.95)
    for i in range(12):
        a = i / 12 * math.tau
        r = 0.7 if i % 2 else 0.35
        hair.spike(0.3, 0.85, seg=4, base=(math.sin(a) * r, math.cos(a) * r * 0.8, 6.0),
                   direction=(math.sin(a) * 0.5, math.cos(a) * 0.4 - 0.1, 1.0))
    for s in (1, -1):
        hair.spike(0.3, 0.8, seg=4, base=(s * 1.0, -0.1, 5.7), direction=(s * 1.0, 0, 0.5))
        hair.spike(0.28, 0.7, seg=4, base=(s * 0.7, -0.75, 6.0), direction=(s * 0.4, -0.8, 0.7))
    # arms: coat sleeves with rolled cuffs
    for s, side in SIDES:
        bone = side + "Arm"
        a = m.piece(bone, "Cloth", bone=bone)
        block(a, (0.88, 0.94, 1.55), loc=(s * 1.58, -0.1, 3.1), bottom=(0.92, 0.92), bevel=0.15)
        cf = m.piece(bone + "Cuff", "Cream", bone=bone)
        block(cf, (1.0, 1.04, 0.32), loc=(s * 1.58, -0.12, 2.28), bevel=0.05)
        hd = m.piece(bone + "Hand", "Skin", bone=bone)
        block(hd, (0.7, 0.7, 0.65), loc=(s * 1.58, -0.2, 1.88), bevel=0.12)
    # broom staff with flower pots, right hand
    stf = m.piece("Staff", "Wood", bone="RightArm")
    sweep(stf, [(-1.75, -0.7, 1.9), (-1.75, -0.7, 4.3), (-1.8, -0.62, 6.5)], [0.17, 0.17, 0.15], seg=6)
    bind = m.piece("StaffRope", "Straw", bone="RightArm")
    for z in (3.4, 4.5, 5.6, 2.2):
        band(bind, 0.17, 0.3, z - 0.1, z + 0.1, seg=6, loc=(-1.75, -0.7, 0))
    bris = m.piece("Bristles", "Straw", bone="RightArm", shadow=True)
    for i in range(12):
        a = i / 12 * math.tau
        bris.spike(0.3, 2.2, seg=4, base=(-1.75 + 0.3 * math.cos(a), -0.7 + 0.3 * math.sin(a), 2.15),
                   direction=(0.3 * math.cos(a), 0.3 * math.sin(a), -1.0))
    bris.spike(0.4, 2.1, seg=5, base=(-1.75, -0.7, 2.15), direction=(0, 0, -1))
    bb = m.piece("BroomBinding", "Leather", bone="RightArm")
    cyl(bb, 0.5, 0.35, (-1.75, -0.7, 2.0), seg=8)
    pots = m.piece("Pots", "Clay", bone="RightArm", shadow=True)
    plants = m.piece("Plants", "Leaf", bone="RightArm")
    flowers = m.piece("Flowers", "White", bone="RightArm")
    for (px, py, pz) in ((-2.65, -0.7, 3.3), (-1.75, -1.55, 4.4), (-2.65, -0.7, 5.5)):
        cyl(pots, 0.46, 0.8, (px, py, pz), r2=0.64, seg=8)
        band(pots, 0.5, 0.72, pz + 0.3, pz + 0.48, seg=8, loc=(px, py, 0))
        plants.ico(0.5, loc=(px, py, pz + 0.7), scale=(1.1, 1.1, 0.8), subdiv=1)
        for fx, fy, fz in ((-0.2, -0.1, 0.25), (0.22, 0.12, 0.3), (0.0, 0.25, 0.2)):
            flowers.ico(0.15, loc=(px + fx, py + fy, pz + 0.95 + fz), subdiv=1)
        block(bind, (abs(px + 1.75) + 0.12 if px != -1.75 else 0.2, abs(py + 0.7) + 0.12 if py != -0.7 else 0.2, 0.2),
              loc=((px - 1.75) / 2, (py - 0.7) / 2, pz - 0.1), bevel=0.02)
    # legs: brown trousers, green wellies with tan cuffs
    for s, side in SIDES:
        bone = side + "Leg"
        x = s * 0.55
        lg = m.piece(bone, "Pants", bone=bone)
        block(lg, (0.9, 0.92, 1.3), loc=(x, 0, 1.55), bevel=0.14)
        wl = m.piece(bone + "Wellie", "Wellie", bone=bone, shadow=True)
        block(wl, (1.0, 1.05, 1.1), loc=(x, 0, 0.9), top=(1.0, 1.0), bevel=0.14)
        block(wl, (1.05, 1.8, 0.78), loc=(x, -0.4, 0.4), top=(0.9, 0.78), shift=(0, -0.05), bevel=0.16)
        cf = m.piece(bone + "BootCuff", "Cuff", bone=bone)
        block(cf, (1.1, 1.14, 0.3), loc=(x, 0, 1.38), bevel=0.05)
        so = m.piece(bone + "Sole", "Dark", bone=bone)
        block(so, (1.1, 1.92, 0.18), loc=(x, -0.4, 0.09), bevel=0.02)


# ===================================================================================== Rambozo

@register("Rambozo", "Classes", "Squat, broad commando-clown from the reference sheet: huge bare arms, olive tank, camo pants, "
                                "red headband with tails, tiny red clown nose and a scowl, bandolier of red / yellow / blue "
                                "confetti shells, red-and-yellow barrel backpack with a gold star, colourful grenades on the "
                                "hip and a red-and-yellow confetti minigun held in both hands in front.")
def rambozo(m):
    rig(m, dict(Skin="e2a878", Hair="2a2018", Dark="1c1d21", White="f4f2ea", Cloth="4d6a2f", Cloth2="6a7a3a",
                Camo="4a5a28", Accent="d02828", Gold="f0c020", Blue="2f5fc0", Leather="5a4028", Metal="9096a0",
                MetalDark="4a4e58", Nose="e02828", Red="d02828"),
        std_joints(4.1, 2.45, 3.8, 0.9, 1.85))
    # torso: wide olive tank over a bare chest
    t = m.piece("Torso", "Cloth", bone="Torso", shadow=True)
    lathe(t, [(1.4, 1.85), (1.9, 2.4), (2.2, 3.2), (2.15, 3.9), (1.4, 4.3), (0.0, 4.35)], seg=8, phase=22.5, sy=0.85)
    chest = m.piece("ChestSkin", "Skin", bone="Torso")
    slab(chest, [(-0.75, 0.5), (0.75, 0.5), (0.0, -0.75)], 0.14, loc=(0, -1.72, 3.85), bevel=0.02)
    belt = m.piece("Belt", "Leather", bone="Torso")
    band(belt, 1.55, 1.9, 2.0, 2.4, seg=8, phase=22.5, sy=0.85)
    buckle = m.piece("BeltBuckle", "Metal", "Metal", bone="Torso")
    block(buckle, (0.7, 0.18, 0.5), loc=(0, -1.6, 2.2), bevel=0.04)
    pants = m.piece("Pants", "Cloth2", bone="Torso", shadow=True)
    lathe(pants, [(1.5, 1.2), (1.8, 1.5), (1.84, 2.0), (1.7, 2.2)], seg=8, phase=22.5, sy=0.85)
    # bandolier of confetti shells
    pts = [(-1.7, -1.05, 4.15), (-0.5, -1.86, 3.4), (0.9, -1.74, 2.7), (1.55, -1.2, 2.3)]
    bl = m.piece("Bandolier", "Leather", bone="Torso")
    sweep(bl, pts, [0.17, 0.17, 0.17, 0.17], seg=4, sx=2.2)
    shells = {"Red": m.piece("ShellsRed", "Red", bone="Torso"), "Gold": m.piece("ShellsYellow", "Gold", bone="Torso"),
              "Blue": m.piece("ShellsBlue", "Blue", bone="Torso")}
    order = ["Red", "Gold", "Blue"]
    segs = [(Vector(pts[i]), Vector(pts[i + 1])) for i in range(3)]
    for k in range(7):
        u = (k + 0.5) / 7 * 3
        i = min(int(u), 2)
        a, b = segs[i]
        pos = a.lerp(b, u - i)
        d = b - a
        ang = math.degrees(math.atan2(-d.z, d.x))
        cyl(shells[order[k % 3]], 0.27, 0.85, (pos.x, pos.y - 0.2, pos.z), rot=(0, ang, 0), seg=6)
    # grenades on the hip
    gr = m.piece("GrenadeRed", "Red", bone="Torso")
    gr.ico(0.42, loc=(2.0, -0.9, 1.7), subdiv=1)
    gb = m.piece("GrenadeBlue", "Blue", bone="Torso")
    gb.ico(0.42, loc=(2.4, -0.5, 1.65), subdiv=1)
    # back: red-and-yellow barrel pack with a gold star
    bp = m.piece("Barrel", "Accent", bone="Torso", shadow=True)
    cyl(bp, 1.25, 2.9, (0, 2.65, 3.2), seg=8, phase=22.5)
    bg = m.piece("BarrelGold", "Gold", bone="Torso")
    cyl(bg, 1.3, 0.35, (0, 2.65, 4.7), seg=8, phase=22.5)
    band(bg, 1.22, 1.34, 2.05, 2.4, seg=8, phase=22.5, loc=(0, 2.65, 0))
    star(bg, 0.7, 0.32, 0.12, (0, 3.9, 3.35), rot=(0, 0, 0))
    bm = m.piece("BarrelMetal", "MetalDark", bone="Torso")
    block(bm, (0.9, 0.3, 0.3), loc=(0, 2.65, 5.0), bevel=0.05)
    for s in (1, -1):
        block(bm, (0.22, 2.0, 0.22), loc=(s * 1.05, 1.7, 3.2), bevel=0.02)
    # head: blocky head, scowl, clown nose
    h = m.piece("Head", "Skin", bone="Head", shadow=True)
    block(h, (2.4, 2.0, 1.9), loc=(0, 0, 5.15), top=(0.98, 0.98), bottom=(1.0, 1.0), bevel=0.5)
    nose = m.piece("FaceNose", "Nose", bone="Head")
    nose.ico(0.34, loc=(0, -1.2, 4.95), subdiv=1)
    ear = m.piece("FaceEar", "Skin", bone="Head")
    for s in (1, -1):
        block(ear, (0.4, 0.5, 0.8), loc=(s * 1.3, 0.1, 5.1), bevel=0.1)
    ep = eye_pair(m, 5.38, x=0.62, y=-1.02, r=0.34, pr=0.2, look=(-0.06, 0.0))
    block(ep, (1.0, 0.1, 0.14), loc=(0, -1.02, 4.4), bevel=0)  # scowling mouth
    for s in (1, -1):
        block(ep, (0.2, 0.1, 0.4), loc=(s * 0.52, -1.02, 4.25), bevel=0)
    br = m.piece("FaceBrow", "Hair", bone="Head")
    brows(br, 0.64, -1.05, 5.78, w=1.1, t=0.26, d=0.4, tilt=24)
    jaw = m.piece("FaceChin", "Skin", bone="Head")
    block(jaw, (1.5, 0.5, 0.6), loc=(0, -0.9, 4.2), bevel=0.12)
    hb = m.piece("Headband", "Accent", bone="Head")
    band(hb, 1.12, 1.32, 5.78, 6.1, seg=8, phase=22.5, sy=0.86)
    sweep(hb, [(0.9, 0.8, 5.95), (1.9, 1.7, 5.7), (2.8, 2.5, 5.2)], [0.2, 0.2, 0.04], seg=4, sx=2.0)
    sweep(hb, [(0.6, 0.95, 5.9), (1.4, 1.9, 5.4), (2.0, 2.8, 4.7)], [0.2, 0.2, 0.04], seg=4, sx=2.0)
    hair = m.piece("Hair", "Hair", bone="Head", shadow=True)
    lathe(hair, [(1.2, 5.55), (1.3, 5.9), (1.1, 6.2), (0.6, 6.4), (0.0, 6.45)], seg=8, sy=0.9)
    hair.ico(1.05, loc=(0, 0.75, 5.4), scale=(1.15, 0.8, 1.0), subdiv=1)
    for i in range(12):
        a = i / 12 * math.tau
        r = 0.8 if i % 2 else 0.4
        hair.spike(0.32, 0.65, seg=4, base=(math.sin(a) * r, math.cos(a) * r * 0.8 - 0.05, 6.1),
                   direction=(math.sin(a) * 0.6, math.cos(a) * 0.5, 1.0))
    # arms: huge, reaching forward onto the gun
    gun = m.piece("MinigunBody", "Accent", bone="Torso", shadow=True)
    block(gun, (1.9, 2.2, 1.6), loc=(0, -3.1, 2.95), bevel=0.22)
    gg = m.piece("MinigunGold", "Gold", bone="Torso")
    for y in (-2.45, -3.7):
        block(gg, (1.98, 0.3, 1.68), loc=(0, y, 2.95), bevel=0.04)
    for s in (1, -1):
        star(gg, 0.5, 0.24, 0.08, (s * 0.97, -3.05, 2.95), rot=(0, 0, 90))
    gm = m.piece("MinigunMetal", "MetalDark", bone="Torso", shadow=True)
    cyl(gm, 0.95, 0.45, (0, -4.3, 2.95), rot=(90, 0, 0), seg=6)
    block(gm, (0.3, 1.7, 0.26), loc=(0, -3.0, 3.95), bevel=0.04)
    for y in (-2.4, -3.6):
        block(gm, (0.26, 0.26, 0.45), loc=(0, y, 3.75), bevel=0.03)
    bar = m.piece("MinigunBarrels", "Metal", "Metal", bone="Torso", shadow=True)
    muz = m.piece("MinigunMuzzle", "Gold", bone="Torso")
    bore = m.piece("MinigunBore", "Dark", bone="Torso")
    for i in range(6):
        a = i / 6 * math.tau
        bx, bz = math.cos(a) * 0.52, 2.95 + math.sin(a) * 0.52
        cyl(bar, 0.28, 1.4, (bx, -4.65, bz), rot=(90, 0, 0), seg=6)
        cyl(muz, 0.4, 0.3, (bx, -5.4, bz), rot=(90, 0, 0), seg=6)
        cyl(bore, 0.25, 0.1, (bx, -5.58, bz), rot=(90, 0, 0), seg=6)
    for s, side in SIDES:
        bone = side + "Arm"
        a = m.piece(bone, "Skin", bone=bone, shadow=True)
        a.ico(1.0, loc=(s * 2.5, 0, 3.75), scale=(1.0, 1.0, 0.95), subdiv=1)
        tube(a, (s * 2.5, 0, 3.75), (s * 2.25, -1.1, 3.1), 0.95, 0.8, seg=6)
        tube(a, (s * 2.25, -1.1, 3.1), (s * 1.6, -2.4, 2.9), 0.82, 0.68, seg=6)
        gl = m.piece(bone + "Glove", "MetalDark", bone=bone)
        block(gl, (1.05, 1.0, 1.0), loc=(s * 1.35, -2.75, 2.9), bevel=0.2)
        block(gl, (1.1, 0.8, 0.4), loc=(s * 1.55, -2.1, 3.0), bevel=0.1)
        st = m.piece(bone + "Stud", "Metal", "Metal", bone=bone)
        for k in (-1, 0, 1):
            block(st, (0.16, 0.16, 0.16), loc=(s * 1.55 + k * 0.28, -2.1, 3.25), bevel=0.02)
    # legs: camo pants, huge boots
    for s, side in SIDES:
        bone = side + "Leg"
        x = s * 0.95
        lg = m.piece(bone, "Cloth2", bone=bone)
        block(lg, (1.4, 1.45, 1.4), loc=(x, 0, 1.2), bevel=0.2)
        block(lg, (0.35, 1.0, 0.7), loc=(s * 1.68, 0, 1.2), bevel=0.06)
        cf = m.piece(bone + "Camo", "Camo", bone=bone)
        for px, py, pz, r in ((0.3, -0.7, 1.4, 0.4), (-0.35, -0.72, 0.9, 0.34), (0.2, -0.73, 0.65, 0.28)):
            cf.ico(r, loc=(x + px * s, py, pz), scale=(1.1, 0.35, 0.9), subdiv=1)
        b = m.piece(bone + "Boot", "Dark", bone=bone, shadow=True)
        block(b, (1.55, 2.2, 1.0), loc=(x, -0.35, 0.5), top=(0.9, 0.78), shift=(0, 0.1), bevel=0.22)
        so = m.piece(bone + "Sole", "MetalDark", bone=bone)
        block(so, (1.65, 2.35, 0.28), loc=(x, -0.35, 0.14), bevel=0.05)
        bk = m.piece(bone + "Buckle", "Metal", "Metal", bone=bone)
        block(bk, (0.9, 0.2, 0.2), loc=(x, -1.0, 0.8), bevel=0.02)


# ================================================================================== Swolverine

@register("Swolverine", "Classes", "Short, grumpy gym fanatic: wide yellow tank over a barrel chest, enormous sideburns, thick "
                                   "scowling brows and a flat-top under a yellow sweatband, towel round the neck, weight belt, "
                                   "charcoal shorts, yellow-and-charcoal sneakers and huge charcoal gym gauntlets with weight "
                                   "plates and three steel claws on each fist.")
def swolverine(m):
    rig(m, dict(Skin="e0a070", Hair="3a2818", Dark="1c1d21", White="f4f2ea", Cloth="f0c428", Cloth2="3a3c44",
                Accent="f0c428", Gold="e8b830", Metal="c8ccd4", MetalDark="4a4c54", Leather="6a4a2e", Cream="e0d8c0",
                Hat="f0c428", Blue="3a8ad8"),
        std_joints(3.75, 2.5, 3.45, 0.85, 1.55))
    # torso: broad yellow tank over a bare barrel chest
    t = m.piece("Torso", "Cloth", bone="Torso", shadow=True)
    lathe(t, [(1.25, 1.5), (1.8, 2.0), (2.15, 2.8), (2.1, 3.4), (1.4, 3.75), (0.0, 3.8)], seg=8, phase=22.5, sy=0.85)
    tr = m.piece("TankTrim", "Cloth2", bone="Torso")
    band(tr, 1.12, 1.4, 3.55, 3.78, seg=8, phase=22.5, sy=0.85)
    chest = m.piece("ChestSkin", "Skin", bone="Torso")
    slab(chest, [(-0.8, 0.5), (0.8, 0.5), (0.0, -0.75)], 0.14, loc=(0, -1.7, 3.4), bevel=0.02)
    wb = m.piece("WeightBelt", "Leather", bone="Torso", shadow=True)
    band(wb, 1.5, 1.98, 1.5, 2.15, seg=8, phase=22.5, sy=0.85)
    bk = m.piece("BeltBuckle", "Gold", "Metal", bone="Torso")
    block(bk, (0.8, 0.2, 0.55), loc=(0, -1.78, 1.82), bevel=0.05)
    sh = m.piece("Shorts", "Cloth2", bone="Torso", shadow=True)
    lathe(sh, [(1.3, 0.95), (1.62, 1.2), (1.66, 1.6), (1.5, 1.7)], seg=8, phase=22.5, sy=0.85)
    tw = m.piece("Towel", "White", bone="Torso")
    band(tw, 1.0, 1.75, 3.55, 3.95, seg=8, phase=22.5, sy=0.85)
    for s in (1, -1):
        block(tw, (0.55, 0.14, 1.5), loc=(s * 0.42, -1.72, 2.9), rot=(0, 0, s * -4), bevel=0.03)
    ts = m.piece("TowelStripe", "Cloth2", bone="Torso")
    for s in (1, -1):
        block(ts, (0.57, 0.16, 0.14), loc=(s * 0.42, -1.74, 2.45), bevel=0)
    sk = m.piece("Shaker", "Blue", bone="Torso")
    cyl(sk, 0.38, 1.1, (-1.85, 0.7, 1.75), seg=6)
    skl = m.piece("ShakerLid", "MetalDark", bone="Torso")
    cyl(skl, 0.4, 0.22, (-1.85, 0.7, 2.4), seg=6)
    # head: wide jaw, scowl, sideburns
    h = m.piece("Head", "Skin", bone="Head", shadow=True)
    block(h, (2.5, 2.0, 1.95), loc=(0, -0.1, 4.5), top=(0.96, 0.96), bottom=(1.0, 1.0), bevel=0.55)
    nose = m.piece("FaceNose", "Skin", bone="Head")
    block(nose, (0.62, 0.55, 0.62), loc=(0, -1.3, 4.3), bevel=0.12)
    for s in (1, -1):
        block(nose, (0.4, 0.5, 0.75), loc=(s * 1.38, 0.0, 4.5), bevel=0.1)
    block(nose, (1.5, 0.5, 0.55), loc=(0, -1.0, 3.75), bevel=0.14)  # square chin
    ep = eye_pair(m, 4.72, x=0.64, y=-1.12, r=0.36, pr=0.21, look=(-0.05, -0.03))
    block(ep, (1.1, 0.1, 0.15), loc=(0, -1.15, 3.88), bevel=0)  # grim mouth
    for s in (1, -1):
        block(ep, (0.2, 0.1, 0.42), loc=(s * 0.6, -1.15, 3.7), bevel=0)
    br = m.piece("FaceBrow", "Hair", bone="Head")
    brows(br, 0.7, -1.16, 5.14, w=1.25, t=0.28, d=0.42, tilt=26)
    sb = m.piece("FaceSideburns", "Hair", bone="Head")
    for s in (1, -1):
        block(sb, (0.8, 0.75, 1.5), loc=(s * 1.45, -0.55, 4.0), top=(0.6, 0.8), bottom=(1.7, 1.1), bevel=0.12)
    hair = m.piece("Hair", "Hair", bone="Head", shadow=True)
    block(hair, (2.3, 1.7, 0.7), loc=(0, 0.15, 5.75), bevel=0.25)
    block(hair, (1.6, 0.8, 0.5), loc=(0, -0.85, 6.0), rot=(-12, 0, 0), bevel=0.15)
    hb = m.piece("Headband", "Hat", bone="Head")
    band(hb, 1.14, 1.36, 5.28, 5.56, seg=8, phase=22.5, sy=0.86, loc=(0, -0.1, 0))
    sweep(hb, [(0.5, 1.0, 5.4), (1.1, 1.7, 5.05), (1.5, 2.3, 4.5)], [0.16, 0.16, 0.04], seg=4, sx=2.0)
    # arms: bare upper arm, gigantic gauntlet forearms with claws
    for s, side in SIDES:
        bone = side + "Arm"
        x = s * 2.6
        a = m.piece(bone, "Skin", bone=bone, shadow=True)
        a.ico(1.0, loc=(s * 2.45, 0, 3.3), scale=(1.0, 1.0, 0.95), subdiv=1)
        block(a, (1.3, 1.3, 1.2), loc=(x, -0.1, 2.65), bevel=0.28)
        block(a, (1.7, 1.7, 1.3), loc=(x, -0.6, 1.7), bevel=0.3)
        ga = m.piece(bone + "Gauntlet", "MetalDark", bone=bone, shadow=True)
        block(ga, (2.0, 2.1, 1.15), loc=(x, -0.75, 1.55), bevel=0.25)
        gy = m.piece(bone + "GauntletStripe", "Accent", bone=bone)
        block(gy, (2.08, 2.18, 0.2), loc=(x, -0.75, 1.9), bevel=0.04)
        block(gy, (2.08, 2.18, 0.2), loc=(x, -0.75, 1.2), bevel=0.04)
        wr = m.piece(bone + "Wrap", "Cream", bone=bone)
        block(wr, (1.5, 1.5, 0.3), loc=(x, -0.2, 2.2), bevel=0.06)
        pl = m.piece(bone + "Plate", "Metal", "Metal", bone=bone)
        cyl(pl, 0.85, 0.3, (s * 3.7, -0.75, 1.55), rot=(0, 90, 0), seg=8)
        cyl(pl, 0.3, 0.45, (s * 3.7, -0.75, 1.55), rot=(0, 90, 0), seg=6)
        cl = m.piece(bone + "Claws", "Metal", "Metal", bone=bone, shadow=True)
        for k in (-1, 0, 1):
            cl.spike(0.26, 2.1, seg=4, base=(x + k * 0.6, -1.7, 1.5), direction=(0, -1.0, -0.12))
    # legs: short and thick, huge sneakers
    for s, side in SIDES:
        bone = side + "Leg"
        x = s * 0.85
        lg = m.piece(bone, "Skin", bone=bone)
        block(lg, (1.2, 1.2, 0.8), loc=(x, 0, 1.1), bevel=0.18)
        sn = m.piece(bone + "Shoe", "Accent", bone=bone, shadow=True)
        block(sn, (1.55, 2.1, 0.95), loc=(x, -0.45, 0.52), top=(0.85, 0.7), shift=(0, 0.15), bevel=0.22)
        tc = m.piece(bone + "ToeCap", "Cloth2", bone=bone)
        block(tc, (1.5, 0.9, 0.68), loc=(x, -1.25, 0.4), top=(0.9, 0.8), bevel=0.18)
        so = m.piece(bone + "Sole", "White", bone=bone)
        block(so, (1.65, 2.35, 0.24), loc=(x, -0.5, 0.12), bevel=0.05)


# ================================================================================ CrashCassidy

@register("CrashCassidy", "Classes", "Compact roller-derby bruiser from the reference sheet: teal helmet with a yellow stripe and "
                                     "a maroon ponytail, wicked grin, cropped teal jacket with purple collar, black tank, belt of "
                                     "light-blue pouches, purple tights, mismatched orange and teal pads with yellow tape, heavy "
                                     "fingerless gloves, huge four-wheel quad skates and a taped purple hockey stick in her "
                                     "right hand.")
def crash(m):
    rig(m, dict(Skin="f2b894", Hair="7a2a4a", Dark="2a2630", White="f4f2ea", Cloth="2a9a98", Cloth2="7a3a8a",
                Accent="f08a30", Gold="c89a30", Hat="2a9a98", HatAccent="f0c428", Metal="9096a0", MetalDark="4a4e58",
                Leather="6a4a2e", Cream="ddd0a8", Pouch="38b8d8", Yellow="f0c428", StickDark="4a4448"),
        std_joints(4.0, 1.85, 3.7, 0.7, 2.35))
    # torso: cropped teal jacket over a black tank, belt of pouches
    t = m.piece("Torso", "Cloth", bone="Torso", shadow=True)
    lathe(t, [(1.2, 2.4), (1.5, 2.8), (1.62, 3.4), (1.55, 3.95), (1.05, 4.3), (0.0, 4.35)], seg=8, phase=22.5, sy=0.88)
    tank = m.piece("Tank", "Dark", bone="Torso")
    block(tank, (0.9, 0.14, 1.5), loc=(0, -1.42, 3.2), bevel=0.04)
    col = m.piece("Collar", "Cloth2", bone="Torso")
    band(col, 0.95, 1.5, 3.95, 4.38, seg=8, phase=22.5, sy=0.88)
    hem = m.piece("JacketHem", "Cloth2", bone="Torso")
    band(hem, 1.2, 1.62, 2.36, 2.58, seg=8, phase=22.5, sy=0.88)
    sh = m.piece("Shorts", "Dark", bone="Torso", shadow=True)
    lathe(sh, [(1.12, 1.85), (1.36, 2.05), (1.38, 2.4), (1.2, 2.5)], seg=8, phase=22.5, sy=0.88)
    belt = m.piece("Belt", "Leather", bone="Torso")
    band(belt, 1.3, 1.56, 2.5, 2.78, seg=8, phase=22.5, sy=0.88)
    block(belt, (0.45, 0.16, 0.34), loc=(0, -1.5, 2.62), bevel=0.04)
    po = m.piece("Pouches", "Pouch", bone="Torso")
    for x in (-0.7, 0.0, 0.7):
        block(po, (0.55, 0.42, 0.46), loc=(x, -1.55, 2.38), bevel=0.1)
    # head: big head, grin, teal helmet
    h = m.piece("Head", "Skin", bone="Head", shadow=True)
    block(h, (2.5, 2.1, 2.0), loc=(0, 0, 5.0), bottom=(0.9, 0.9), bevel=0.55)
    nose = m.piece("FaceNose", "Skin", bone="Head")
    block(nose, (0.45, 0.45, 0.45), loc=(0, -1.1, 4.7), bevel=0.09)
    for s in (1, -1):
        block(nose, (0.3, 0.4, 0.65), loc=(s * 1.3, 0.0, 4.85), bevel=0.08)
    ep = eye_pair(m, 5.05, x=0.68, y=-1.06, r=0.46, pr=0.27, look=(0.08, 0.0))
    block(ep, (1.4, 0.12, 0.36), loc=(0, -1.07, 4.28), bevel=0)  # grin
    teeth = m.piece("FaceTeeth", "White", bone="Head")
    block(teeth, (1.25, 0.1, 0.18), loc=(0, -1.13, 4.4), bevel=0)
    brow = m.piece("FaceBrow", "Hair", bone="Head")
    brows(brow, 0.72, -1.1, 5.5, w=1.1, t=0.24, d=0.32, tilt=22)
    ba = m.piece("FaceBandaid", "Cream", bone="Head")
    block(ba, (0.55, 0.1, 0.22), loc=(-0.98, -1.08, 4.5), rot=(0, 0, 32), bevel=0.02)
    helm = m.piece("Helmet", "Hat", bone="Head", shadow=True)
    lathe(helm, [(1.5, 5.62), (1.55, 5.95), (1.38, 6.35), (0.8, 6.62), (0.0, 6.7)], seg=8, sy=0.72)
    hs = m.piece("HelmetStripe", "HatAccent", bone="Head")
    sweep(hs, [(0, -1.18, 5.9), (0, -1.0, 6.4), (0, -0.55, 6.68), (0, 0.0, 6.77), (0, 0.55, 6.68), (0, 1.0, 6.4),
               (0, 1.18, 5.9)], [0.1] * 7, seg=4, sx=4.5)
    ve = m.piece("HelmetVents", "Dark", bone="Head")
    for x, y in ((-0.75, -0.2), (0.75, -0.2), (-0.55, 0.5), (0.55, 0.5)):
        block(ve, (0.24, 0.24, 0.14), loc=(x, y, 6.6), bevel=0.0)
    ec = m.piece("EarCovers", "MetalDark", bone="Head")
    for s in (1, -1):
        cyl(ec, 0.48, 0.4, (s * 1.45, 0.0, 5.0), rot=(0, 90, 0), seg=8)
    hr = m.piece("Hair", "Hair", bone="Head", shadow=True)
    block(hr, (2.3, 0.5, 0.9), loc=(0, 1.05, 5.25), bevel=0.1)
    tail = []
    for i in range(9):
        u = i / 8
        tail.append((0.0, 0.95 + 1.9 * math.sin(u * 1.75), 5.95 + 0.75 * math.sin(u * 2.4) - 1.7 * u * u))
    sweep(hr, tail, [0.4, 0.62, 0.72, 0.72, 0.66, 0.56, 0.42, 0.25, 0.04], seg=6, sx=1.25)
    for s in (1, -1):
        block(hr, (0.3, 1.0, 0.9), loc=(s * 1.15, -0.2, 5.2), bevel=0.06)
    # arms: cropped sleeves, mismatched elbow pads, heavy gloves
    for s, side in SIDES:
        bone = side + "Arm"
        a = m.piece(bone, "Skin", bone=bone)
        block(a, (0.84, 0.88, 1.1), loc=(s * 2.05, -0.05, 2.95), bevel=0.14)
        sl = m.piece(bone + "Sleeve", "Cloth", bone=bone)
        block(sl, (1.1, 1.12, 0.9), loc=(s * 2.05, 0, 3.75), bevel=0.14)
        pad = m.piece(bone + "Pad", "Accent" if s > 0 else "Cloth", bone=bone, shadow=True)
        block(pad, (1.35, 1.35, 0.9), loc=(s * 2.1, -0.08, 3.05), bevel=0.3)
        tp = m.piece(bone + "PadTape", "Yellow", bone=bone)
        block(tp, (1.4, 1.4, 0.16), loc=(s * 2.1, -0.08, 3.08), bevel=0.02)
        block(tp, (0.18, 1.4, 0.84), loc=(s * 2.1, -0.08, 3.05), bevel=0.02)
        gl = m.piece(bone + "Glove", "Dark", bone=bone)
        block(gl, (1.15, 1.2, 1.05), loc=(s * 2.05, -0.2, 2.15), bevel=0.22)
        gp = m.piece(bone + "GlovePlate", "Metal", "Metal", bone=bone)
        block(gp, (0.8, 0.14, 0.6), loc=(s * 2.05, -0.84, 2.25), bevel=0.03)
    # hockey stick, right hand (the glove closes round the shaft)
    def on_shaft(z):
        u = (z - 2.15) / 4.05
        return (-2.05 - 0.3 * u, -0.2 + 0.3 * u, z)

    sd = m.piece("StickShaft", "StickDark", bone="RightArm")
    sweep(sd, [(-2.2, -0.55, 0.45), on_shaft(2.15), on_shaft(6.2)], [0.2, 0.2, 0.2], seg=6)
    block(sd, (0.44, 0.56, 0.4), loc=(on_shaft(6.35)[0], on_shaft(6.35)[1], 6.4), bevel=0.06)
    sb = m.piece("StickBlade", "Cloth2", bone="RightArm", shadow=True)
    block(sb, (0.44, 2.9, 1.0), loc=(-2.2, -1.75, 0.55), bevel=0.1)
    stp = m.piece("StickTape", "Cream", bone="RightArm")
    sweep(stp, [on_shaft(4.6), on_shaft(6.0)], [0.27, 0.27], seg=6)
    sweep(stp, [(-2.2, -0.55, 0.7), (-2.12, -0.48, 1.5)], [0.27, 0.27], seg=6)
    for y in (-1.0, -1.6, -2.2):
        block(stp, (0.48, 0.22, 1.04), loc=(-2.2, y, 0.55), bevel=0.02)
    # legs: purple tights, mismatched knee pads, quad skates
    for s, side in SIDES:
        bone = side + "Leg"
        x = s * 0.7
        lg = m.piece(bone, "Cloth2", bone=bone)
        block(lg, (0.9, 0.92, 0.9), loc=(x, 0, 2.0), bevel=0.14)
        kp = m.piece(bone + "KneePad", "Accent" if s > 0 else "Cloth", bone=bone, shadow=True)
        block(kp, (1.1, 0.8, 0.9), loc=(x, -0.3, 1.95), bevel=0.26)
        kt = m.piece(bone + "KneeTape", "Yellow", bone=bone)
        block(kt, (0.2, 0.85, 0.84), loc=(x, -0.3, 1.95), bevel=0.02)
        block(kt, (1.15, 0.85, 0.16), loc=(x, -0.3, 1.95), bevel=0.02)
        bt = m.piece(bone + "Boot", "Dark", bone=bone, shadow=True)
        block(bt, (1.1, 1.2, 1.0), loc=(x, 0.05, 1.55), bevel=0.16)
        block(bt, (1.15, 2.0, 0.55), loc=(x, -0.4, 1.33), top=(0.9, 0.8), bevel=0.18)
        tc = m.piece(bone + "ToeCap", "Cream", bone=bone)
        block(tc, (1.2, 0.75, 0.52), loc=(x, -1.2, 1.3), bevel=0.14)
        lc = m.piece(bone + "Laces", "Yellow", bone=bone)
        for y in (-0.55, -0.2, 0.15):
            block(lc, (0.7, 0.12, 0.12), loc=(x, y, 1.98 - (y + 0.55) * 0.2), bevel=0.0)
        pl = m.piece(bone + "Plate", "MetalDark", bone=bone)
        block(pl, (1.05, 2.0, 0.24), loc=(x, -0.35, 1.0), bevel=0.04)
        wh = m.piece(bone + "Wheels", "Gold", bone=bone, shadow=True)
        for wy in (-1.0, 0.15):
            for wx in (-0.4, 0.4):
                cyl(wh, 0.46, 0.36, (x + wx, wy, 0.46), rot=(0, 90, 0), seg=8)
        ax = m.piece(bone + "Axles", "Metal", "Metal", bone=bone)
        for wy in (-1.0, 0.15):
            cyl(ax, 0.14, 1.3, (x, wy, 0.46), rot=(0, 90, 0), seg=6)


# =============================================================================== KnucklesMcGee

@register("KnucklesMcGee", "Classes", "Tiny, cocky human boxer from the reference sheet: huge head with orange spiky hair, big ears, "
                                      "band-aids and a toothy grin, bare chest, teal shorts with a cream waistband and a gold "
                                      "champion belt, a towel at the back, enormous red gloves with cream cuffs and huge navy "
                                      "boots with yellow laces.")
def knuckles(m):
    rig(m, dict(Skin="f0b890", Hair="c8602a", Dark="1c1d21", White="f4f2ea", Cloth="2a6a62", Cloth2="e8d8b0",
                Accent="d02830", Gold="e8b830", Metal="9096a0", MetalDark="5a5648", Leather="6a4428", Boot="3a4458",
                Cream="e8c890", Brow="5a3018"),
        std_joints(3.35, 1.25, 3.05, 0.7, 1.4))
    # torso: bare little chest, teal shorts, champion belt
    t = m.piece("Torso", "Skin", bone="Torso", shadow=True)
    lathe(t, [(0.9, 2.15), (1.05, 2.55), (1.2, 3.0), (1.1, 3.3), (0.6, 3.42), (0.0, 3.45)], seg=8, phase=22.5, sy=0.88)
    for s in (1, -1):
        t.ico(0.42, loc=(s * 0.5, -0.95, 3.0), scale=(1.0, 0.6, 0.8), subdiv=1)
    sh = m.piece("Shorts", "Cloth", bone="Torso", shadow=True)
    lathe(sh, [(1.0, 1.3), (1.28, 1.55), (1.3, 2.0), (1.18, 2.3)], seg=8, phase=22.5, sy=0.88)
    wb = m.piece("Waistband", "Cloth2", bone="Torso")
    band(wb, 1.1, 1.36, 2.1, 2.55, seg=8, phase=22.5, sy=0.88)
    band(wb, 0.98, 1.34, 1.3, 1.5, seg=8, phase=22.5, sy=0.88)
    belt = m.piece("ChampBelt", "Leather", bone="Torso")
    band(belt, 1.2, 1.42, 2.15, 2.5, seg=8, phase=22.5, sy=0.88)
    plate = m.piece("BeltPlate", "Gold", "Metal", bone="Torso", shadow=True)
    cyl(plate, 0.66, 0.2, (0, -1.28, 2.32), rot=(90, 0, 0), seg=8)
    star_p = m.piece("BeltStar", "Leather", bone="Torso")
    star(star_p, 0.44, 0.2, 0.1, (0, -1.43, 2.32))
    tw = m.piece("Towel", "White", bone="Torso")
    block(tw, (1.0, 0.14, 1.5), loc=(0.35, 1.36, 1.75), rot=(0, 0, 3), bevel=0.03)
    tws = m.piece("TowelStripe", "Cloth", bone="Torso")
    block(tws, (1.02, 0.16, 0.14), loc=(0.35, 1.38, 1.3), bevel=0)
    block(tws, (1.02, 0.16, 0.14), loc=(0.35, 1.38, 1.5), bevel=0)
    # head: huge head, big ears, grin
    h = m.piece("Head", "Skin", bone="Head", shadow=True)
    block(h, (2.7, 2.25, 2.05), loc=(0, 0, 4.4), bottom=(0.86, 0.88), top=(0.98, 0.98), bevel=0.62)
    ear = m.piece("FaceEar", "Skin", bone="Head")
    for s in (1, -1):
        ear.ico(0.62, loc=(s * 1.48, 0.05, 4.35), scale=(0.5, 0.75, 1.0), subdiv=1)
    ep = eye_pair(m, 4.55, x=0.74, y=-1.18, r=0.52, pr=0.34, look=(0.08, -0.02), depth=0.24)
    nose = m.piece("FaceNose", "Skin", bone="Head")
    nose.ico(0.46, loc=(0, -1.32, 4.28), scale=(1.0, 0.9, 0.9), subdiv=1)
    block(ep, (1.55, 0.12, 0.52), loc=(0, -1.16, 3.75), bevel=0)  # wide grin
    teeth = m.piece("FaceTeeth", "White", bone="Head")
    block(teeth, (1.4, 0.1, 0.28), loc=(0, -1.22, 3.9), bevel=0)
    block(teeth, (1.2, 0.1, 0.2), loc=(0, -1.22, 3.6), bevel=0)
    br = m.piece("FaceBrow", "Brow", bone="Head")
    brows(br, 0.8, -1.22, 5.1, w=1.2, t=0.3, d=0.42, tilt=22)
    ba = m.piece("FaceBandaid", "Cream", bone="Head")
    for s in (1, -1):
        block(ba, (0.55, 0.1, 0.22), loc=(s * 1.1, -1.12, 4.0), rot=(0, 0, s * -35), bevel=0.02)
    hair = m.piece("Hair", "Hair", bone="Head", shadow=True)
    lathe(hair, [(1.3, 4.95), (1.38, 5.3), (1.2, 5.62), (0.66, 5.85), (0.0, 5.9)], seg=8, sy=0.88)
    hair.ico(1.1, loc=(0, 0.75, 4.95), scale=(1.15, 0.8, 1.0), subdiv=1)
    for i in range(13):
        a = i / 13 * math.tau
        r = 0.9 if i % 2 else 0.45
        hair.spike(0.34, 0.9, seg=4, base=(math.sin(a) * r, math.cos(a) * r * 0.8 - 0.1, 5.7),
                   direction=(math.sin(a) * 0.55, math.cos(a) * 0.5 - 0.1, 1.0))
    for s in (1, -1):
        hair.spike(0.3, 0.8, seg=4, base=(s * 1.0, -1.0, 5.45), direction=(s * 0.3, -0.7, 0.8))
    # arms: thin arms, ENORMOUS red gloves with cream cuffs
    for s, side in SIDES:
        bone = side + "Arm"
        a = m.piece(bone, "Skin", bone=bone)
        a.ico(0.52, loc=(s * 1.25, 0, 3.05), subdiv=1)
        a.limb((s * 1.25, 0, 3.05), (s * 2.1, -0.5, 2.6), 0.42, 0.4, seg=6)
        cf = m.piece(bone + "Cuff", "Cloth2", bone=bone)
        cf.limb((s * 2.0, -0.45, 2.66), (s * 2.55, -0.75, 2.38), 0.66, 0.66, seg=8)
        gl = m.piece(bone + "Glove", "Accent", bone=bone, shadow=True)
        gl.ico(1.28, loc=(s * 3.15, -1.0, 2.2), scale=(1.0, 1.08, 1.1), subdiv=1)
        gl.ico(0.55, loc=(s * 2.55, -1.85, 2.5), scale=(0.9, 1.1, 0.9), subdiv=1)  # thumb
    # legs: stubby, huge boots with yellow laces
    for s, side in SIDES:
        bone = side + "Leg"
        lg = m.piece(bone, "Skin", bone=bone)
        block(lg, (0.8, 0.8, 0.6), loc=(s * 0.7, 0, 1.2), bevel=0.14)
        b = m.piece(bone + "Boot", "Boot", bone=bone, shadow=True)
        block(b, (1.7, 2.3, 0.95), loc=(s * 0.9, -0.5, 0.5), top=(0.85, 0.75), shift=(0, 0.15), bevel=0.25)
        block(b, (1.3, 1.25, 0.7), loc=(s * 0.9, 0.05, 1.05), bevel=0.2)
        so = m.piece(bone + "Sole", "MetalDark", bone=bone)
        block(so, (1.8, 2.4, 0.2), loc=(s * 0.9, -0.5, 0.1), bevel=0.04)
        lc = m.piece(bone + "Laces", "Gold", bone=bone)
        for y, z in ((-0.15, 1.38), (-0.55, 1.1), (-0.95, 0.9)):
            block(lc, (0.95, 0.14, 0.14), loc=(s * 0.9, y, z), bevel=0.0)
