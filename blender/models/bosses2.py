"""The two late-stage bosses and the Briar Sentinel's summon (heroic low-poly fantasy).

Same conventions as models/enemies.py (category "Enemies"): origin = ground centre (z = 0),
front = -Y, client-drawn pieces with the runtime anim keys of src/client/ModelLibrary.lua and a
pivot at the joint, one or two big shadow pieces, Neon only on small glowing bits. Big forms are
convex hulls of jittered points (clean, chunky facets, like the biome rocks). Budget <= 3500
tris for a boss.

  FrostboundColossus  (FrostBoss) a hunched ice giant ~13 tall: deep steel-blue ice slabs over a
                      dark rock core that shows through a cleft in the chest (glowing pale-cyan
                      heart), teal crystal spikes on the shoulders and back, a small sunk head
                      with glowing eyes and an icicle beard, long arms with huge rock fists for
                      ground slams. "Frost*" pieces are the phase-2 frost armour shell (hidden by
                      EnemyRenderer unless the body attribute FrostArmor is set).
  BriarSentinel       (BriarBoss) a bramble treant knight ~13 tall: twisted dark bark body and
                      root legs, mossy bramble armour plates, pale bone thorn spikes, a bark helm
                      with amber eyes under a crown of thorny branches with amber berries, an
                      amber heart-knot in the chest, long root arms whose root fingers reach
                      the ground.
  ThornSprout         (ThornSprout) the Sentinel's summon, a small thorn beetle ~2.4 wide:
                      bark-brown shell with a moss saddle and three bold bone thorns, dark head
                      and legs, amber eyes.

The colours deliberately avoid the arena floors: the Colossus is deep blue, teal and dark rock
(it fights on white snow), the Sentinel is dark bark with bone thorns and amber (forest grass).
"""

import math

from mathutils import Vector

from models._biomekit import shard
from models._propkit import blob_points, hull, loft, ring
from models.enemies import X, ellipsoid, gem, tube
from style import P, mix
from swarmkit import register


def rock(piece, c, r, seed, n=14, jitter=0.14, floor=None):
    """Faceted chunk: convex hull of jittered points on an ellipsoid (flat base under floor)."""
    pts = blob_points(seed, n, *r, jitter=jitter, floor=floor)
    hull(piece, [(c[0] + x, c[1] + y, c[2] + z) for x, y, z in pts])


def column(piece, a, ra, b, rb, seed, n=10, jitter=0.12):
    """Faceted column: one convex hull around two jittered blobs (thighs, forearms)."""
    pts = [(a[0] + x, a[1] + y, a[2] + z) for x, y, z in blob_points(seed, n, *ra, jitter=jitter)]
    pts += [(b[0] + x, b[1] + y, b[2] + z) for x, y, z in blob_points(seed + 7, n, *rb, jitter=jitter)]
    hull(piece, pts)


def spike(piece, base, d, length, r, seg=4):
    """Straight cone from base along direction d."""
    b = Vector(base)
    tube(piece, [b, b + Vector(d).normalized() * length], [r, 0.0], seg=seg)


def thorn(piece, base, d, length, r, curl=(0, 0, 0), seg=4):
    """Curved thorn: a cone bending toward `curl` at the tip."""
    b = Vector(base)
    d = Vector(d).normalized()
    mid = b + d * length * 0.55
    tip = b + d * length + Vector(curl)
    tube(piece, [b, mid, tip], [r, r * 0.5, 0.0], seg=seg)


# ------------------------------------------------------------------ FROSTBOUND COLOSSUS

TEAL = (0.29, 0.69, 0.78)
CYAN_GLOW = (0.62, 0.96, 1.0)


@register("FrostboundColossus", "Enemies", "Boss (FrostBoss). Hunched ice giant ~13 tall: deep steel-blue ice slabs over "
                                           "a dark rock core showing through a chest cleft with a pale-cyan Neon heart "
                                           "(Pulse), teal crystal spikes on shoulders and back, sunk head with glowing "
                                           "eyes and icicle beard, huge rock fists. Legs SwingA/B, arms SwingB/A. Frost* "
                                           "pieces = phase-2 frost armour shell (hidden unless FrostArmor).")
def frostbound_colossus(m):
    m.extra["palette"] = {
        "Base": mix("ice_500", "slate_500", 0.45),       # deep steel-blue ice slabs
        "Light": mix("ice_300", TEAL, 0.25),             # icicles, brow frost
        "Accent": TEAL,                                  # crystal spikes
        "Dark": mix("slate_800", "stone_800", 0.3),      # rock core
        "Stone": mix("slate_700", "stone_700", 0.4),     # rock limbs and fists
        "Glow": CYAN_GLOW, "Eye": CYAN_GLOW,
        "White": mix("ice_100", TEAL, 0.3),              # phase-2 frost armour
    }
    m.extra["render_hide"] = ["FrostChest", "FrostBack", "FrostShoulderL", "FrostShoulderR", "FrostArmL", "FrostArmR"]
    # ---- legs: short rock pillars with an ice knee cap and a broad flat foot
    for s, side in ((1, "L"), (-1, "R")):
        anim = "SwingA" if s > 0 else "SwingB"
        hip = (s * 2.3, 0.6, 4.8)
        leg = m.piece("Leg" + side, "Stone", anim=anim, pivot=hip)
        column(leg, (s * 2.3, 0.6, 4.4), (1.5, 1.5, 0.9), (s * 2.6, 0.2, 1.4), (1.3, 1.4, 0.8), seed=11 + s)
        rock(leg, (s * 2.7, -0.1, 0.75), (1.75, 2.1, 0.8), seed=21 + s, n=14, floor=-0.75)
        knee = m.piece("Knee" + side, "Base", anim=anim, pivot=hip)
        rock(knee, (s * 2.6, -0.8, 2.9), (1.25, 0.8, 1.1), seed=31 + s, n=10)
    # ---- the dark rock core: hips, belly and the chest the ice slabs leave open
    core = m.piece("Core", "Dark", shadow=True)
    rock(core, (0, 0.6, 5.4), (3.0, 2.3, 1.5), seed=41, n=16)
    rock(core, (0, 0.3, 8.0), (3.2, 2.6, 2.7), seed=42, n=18)
    # ---- the ice body: a hunched back mass, two chest slabs with a cleft between, side slabs
    ice = m.piece("Body", "Base", shadow=True)
    rock(ice, (0, 1.5, 9.6), (4.0, 2.6, 2.5), seed=51, n=20, jitter=0.12)
    for s in (-1, 1):
        rock(ice, (s * 2.05, -1.55, 8.9), (1.65, 1.25, 1.9), seed=52 + s, n=14)
        rock(ice, (s * 2.7, -0.4, 6.5), (1.2, 1.7, 1.3), seed=55 + s, n=12)
    rock(ice, (0, 2.3, 6.6), (2.6, 1.3, 1.6), seed=58, n=12)  # lower back
    # ---- the heart in the chest cleft
    heart = m.piece("Heart", "Glow", "Neon", anim="Pulse")
    gem(heart, (0, -2.45, 8.7), 0.8, scale=(0.8, 0.6, 1.25))
    # ---- head: a small rock skull sunk forward between the shoulders, ice brow, glowing eyes
    head = m.piece("Head", "Dark")
    rock(head, (0, -2.2, 11.3), (1.45, 1.3, 1.2), seed=61, n=14)
    brow = m.piece("Brow", "Base")
    rock(brow, (0, -2.95, 11.95), (1.7, 0.75, 0.5), seed=62, n=10)
    for s in (-1, 1):  # brow horns sweeping back
        thorn(brow, (s * 1.2, -2.7, 12.1), (s * 0.6, 0.5, 0.6), 1.5, 0.35, curl=(0, 0.5, 0.2))
    eyes = m.piece("Eyes", "Eye", "Neon")
    for s in (-1, 1):
        gem(eyes, (s * 0.55, -3.4, 11.45), 0.28, scale=(1.3, 0.6, 0.75))
    beard = m.piece("Beard", "Light")
    for x, h in ((0, 1.6), (0.45, 1.25), (-0.45, 1.25), (0.85, 0.85), (-0.85, 0.85)):
        spike(beard, (x, -3.2, 10.75), (x * 0.1, -0.25, -1), h, 0.3)
    # ---- crystal spikes on the back (static)
    back = m.piece("BackSpikes", "Accent")
    for base, h, r, tilt in (((0, 2.5, 11.4), 3.4, 0.6, (-30, 0)), ((-1.5, 2.2, 11.0), 2.6, 0.5, (-25, -22)),
                             ((1.5, 2.2, 11.0), 2.8, 0.5, (-28, 24)), ((-0.7, 3.4, 9.6), 2.2, 0.45, (-58, -10)),
                             ((0.8, 3.5, 9.3), 2.0, 0.42, (-62, 14)), ((0, 3.6, 7.6), 1.6, 0.38, (-75, 0))):
        shard(back, base, h, r, tilt=tilt, sides=5)
    # ---- arms: ice pauldron, rock arm, ice forearm slab, huge rock fist, shoulder crystals
    for s, side in ((1, "L"), (-1, "R")):
        anim = "SwingB" if s > 0 else "SwingA"
        sh = (s * 4.3, 0.5, 10.0)
        arm = m.piece("Arm" + side, "Stone", anim=anim, pivot=sh)
        tube(arm, [sh, (s * 5.25, -0.3, 7.4), (s * 5.45, -1.0, 4.7)], [1.15, 1.0, 1.05], seg=6)
        fist = m.piece("Fist" + side, "Stone", anim=anim, pivot=sh, shadow=True)
        rock(fist, (s * 5.5, -1.35, 2.75), (1.85, 1.9, 1.75), seed=71 + s, n=16, jitter=0.1)
        ice_arm = m.piece("Shoulder" + side, "Base", anim=anim, pivot=sh)
        rock(ice_arm, (s * 4.55, 0.45, 10.5), (2.0, 2.0, 1.55), seed=81 + s, n=16)
        column(ice_arm, (s * 5.4, -0.7, 6.4), (1.25, 1.2, 0.6), (s * 5.55, -1.1, 4.6), (1.3, 1.25, 0.5), seed=85 + s)
        cry = m.piece("Spikes" + side, "Accent", anim=anim, pivot=sh)
        for base, h, r, tilt in (((4.6, 0.6, 11.6), 3.0, 0.55, (-8, 22)), ((5.5, 0.0, 11.0), 2.2, 0.45, (12, 48)),
                                 ((3.9, 1.5, 11.4), 2.0, 0.42, (-35, 12)), ((5.7, -1.4, 6.6), 1.3, 0.32, (20, 70))):
            shard(cry, (s * base[0], base[1], base[2]), h, r, tilt=(tilt[0], s * tilt[1]), sides=5)
        knuckles = m.piece("Knuckles" + side, "Light", anim=anim, pivot=sh)
        for kx, kz in ((-0.8, 3.35), (0.0, 3.6), (0.8, 3.35)):
            rock(knuckles, (s * 5.5 + kx, -3.05, kz), (0.45, 0.35, 0.4), seed=91 + int(kx * 10) + s, n=8)
    # ---- phase-2 frost armour shell (pale translucent ice, hidden until FrostArmor)
    tr = 0.18
    chest = m.piece("FrostChest", "White", transparency=tr)
    rock(chest, (0, -2.75, 9.0), (2.9, 0.75, 2.1), seed=101, n=14)
    for s in (-1, 1):
        shard(chest, (s * 1.6, -3.1, 9.8), 1.6, 0.4, tilt=(70, s * 20), sides=4)
    fback = m.piece("FrostBack", "White", transparency=tr)
    rock(fback, (0, 1.9, 10.9), (3.2, 1.6, 0.9), seed=102, n=12)
    for x, h, tx in ((-2.2, 2.4, -30), (2.2, 2.4, 30), (-1.0, 3.6, -12), (1.0, 3.8, 12)):
        shard(fback, (x, 2.4, 11.4), h, 0.45, tilt=(-20, tx), sides=4)
    for s, side in ((1, "L"), (-1, "R")):
        anim = "SwingB" if s > 0 else "SwingA"
        sh = (s * 4.3, 0.5, 10.0)
        fs = m.piece("FrostShoulder" + side, "White", anim=anim, pivot=sh, transparency=tr)
        rock(fs, (s * 4.75, 0.3, 11.5), (2.15, 2.15, 0.9), seed=111 + s, n=12)
        for base, h, tilt in (((5.6, 0.9, 12.0), 3.4, (-10, 38)), ((4.4, -0.6, 12.1), 2.6, (25, 18)),
                              ((6.1, -0.4, 11.4), 2.2, (20, 62))):
            shard(fs, (s * base[0], base[1], base[2]), h, 0.5, tilt=(tilt[0], s * tilt[1]), sides=4)
        fa = m.piece("FrostArm" + side, "White", anim=anim, pivot=sh, transparency=tr)
        column(fa, (s * 5.5, -1.0, 5.6), (1.6, 1.55, 0.6), (s * 5.55, -1.4, 3.6), (2.1, 2.1, 0.6), seed=121 + s)
        shard(fa, (s * 6.6, -1.0, 4.6), 1.6, 0.4, tilt=(0, s * 75), sides=4)


# ------------------------------------------------------------------ BRIAR SENTINEL

AMBER = P("amber_500")


@register("BriarSentinel", "Enemies", "Boss (BriarBoss). Bramble treant knight ~13 tall: twisted dark bark body and "
                                      "root legs, mossy bramble armour plates, pale bone thorns, bark helm with amber "
                                      "eyes, crown of thorny branches with amber berries, amber heart-knot (Pulse), "
                                      "long root arms (SwingB/A) whose root fingers reach the ground.")
def briar_sentinel(m):
    m.extra["palette"] = {
        "Base": mix("wood_700", "wood_800", 0.35),     # dark bark
        "Dark": P("wood_900"),                          # deep bark grooves, crown
        "Leaf": mix("moss_500", "moss_400", 0.4),       # bramble armour
        "Accent": P("moss_700"),                        # vines
        "Light": mix("gold_200", "wood_400", 0.3),      # bone thorns
        "Wood": P("wood_500"),                          # the crown's branches
        "Glow": P("amber_300"), "Eye": AMBER,
    }
    # ---- root legs: twisted roots that split into three toes on the ground
    for s, side in ((1, "L"), (-1, "R")):
        anim = "SwingA" if s > 0 else "SwingB"
        hip = (s * 1.7, 0.4, 4.6)
        leg = m.piece("Leg" + side, "Base", anim=anim, pivot=hip)
        tube(leg, [hip, (s * 2.15, 0.1, 2.7), (s * 2.25, 0.0, 0.9)], [1.25, 1.05, 1.1], seg=6)
        for dx, dy in ((0.9, -1.6), (1.3, 0.3), (0.1, 1.4), (-0.6, -1.3)):
            tube(leg, [(s * 2.25, 0.0, 1.1), (s * (2.25 + dx * 0.6), dy * 0.6, 0.55), (s * (2.25 + dx), dy, 0.0)],
                 [0.6, 0.42, 0.0], seg=4)
        knee = m.piece("KneeThorns" + side, "Light", anim=anim, pivot=hip)
        thorn(knee, (s * 2.1, -0.75, 2.9), (s * 0.3, -1, 0.3), 1.0, 0.25, curl=(0, 0, 0.3))
    # ---- the trunk: a twisted bark body, wider at the chest, with spiral grooves
    body = m.piece("Body", "Base", shadow=True)
    rings = []
    for k, (z, r, cy) in enumerate(((3.8, 2.0, 0.4), (5.4, 2.2, 0.4), (7.2, 2.6, 0.3), (9.0, 3.0, 0.5), (10.6, 2.6, 0.6),
                                    (11.5, 1.5, 0.6))):
        rings.append(ring(8, r, z, phase=k * 0.32, cy=cy, sx=1.08, sy=0.88, wobble=0.07, seed=200 + k))
    loft(body, rings)
    rock(body, (0, 0.4, 4.3), (2.4, 1.8, 1.0), seed=205, n=12)  # pelvis knot
    grooves = m.piece("Grooves", "Dark")
    for k in range(5):  # spiral bark ridges
        a0 = k * math.tau / 5
        pts = []
        for i in range(5):
            a = a0 + i * 0.42
            z = 4.0 + i * 1.6
            r = (1.85, 2.15, 2.5, 2.7, 2.35)[i]
            pts.append((math.cos(a) * r * 1.08, 0.4 + math.sin(a) * r * 0.88, z))
        tube(grooves, pts, [0.26, 0.3, 0.3, 0.28, 0.0], seg=4)
    # ---- bramble armour: breastplate halves around the heart-knot, pauldrons, a back mantle
    armour = m.piece("Armour", "Leaf", shadow=True)
    for s in (-1, 1):
        rock(armour, (s * 1.55, -1.75, 8.7), (1.55, 1.0, 2.0), seed=211 + s, n=12)
    rock(armour, (0, 1.9, 9.6), (2.6, 1.0, 1.5), seed=214, n=12)
    rock(armour, (0, -1.1, 5.4), (1.9, 0.9, 0.8), seed=215, n=10)  # belt plate
    heart = m.piece("Heart", "Glow", "Neon", anim="Pulse")
    gem(heart, (0, -2.25, 8.5), 0.62, scale=(0.9, 0.6, 1.2))
    knot = m.piece("HeartKnot", "Dark")  # a ring of knotted roots framing the heart
    for s in (-1, 1):
        tube(knot, [(0, -2.15, 9.6), (s * 0.85, -2.35, 9.0), (s * 0.8, -2.35, 7.9), (0, -2.15, 7.35)],
             [0.2, 0.26, 0.26, 0.2], seg=4)
    vines = m.piece("Vines", "Accent")
    for s in (-1, 1):  # vines wrapping the trunk under the armour
        tube(vines, X(s, [(0.3, -2.0, 6.2), (1.7, -1.6, 6.8), (2.5, 0.0, 7.6), (1.8, 2.1, 8.2), (0.2, 2.6, 8.6)]),
             [0.22, 0.24, 0.24, 0.22, 0.2], seg=4)
    thorns = m.piece("Thorns", "Light")
    for s in (-1, 1):
        thorn(thorns, (s * 1.8, -2.0, 9.5), (s * 0.6, -1, 0.4), 1.2, 0.26, curl=(0, 0, 0.35))
        thorn(thorns, (s * 2.1, -1.8, 7.6), (s * 0.8, -1, -0.1), 1.0, 0.22, curl=(0, 0, 0.3))
    for i, (z, y) in enumerate(((10.8, 2.6), (9.6, 2.95), (8.3, 2.85), (7.0, 2.55))):  # spine thorns
        thorn(thorns, (0, y - 0.3, z), (0, 1, 0.55 - i * 0.15), 1.7 - i * 0.25, 0.36, curl=(0, 0, 0.35))
    for s in (-1, 1):
        thorn(thorns, (s * 1.6, 2.6, 9.9), (s * 0.7, 1, 0.5), 1.3, 0.28, curl=(0, 0, 0.3))
    # ---- helm: a bark head with a dark visor slit, amber eyes, under a crown of thorny branches
    head = m.piece("Head", "Base")
    rock(head, (0, -0.8, 12.3), (1.65, 1.5, 1.6), seed=231, n=14)
    visor = m.piece("Visor", "Dark")
    rock(visor, (0, -2.15, 12.4), (1.3, 0.38, 0.4), seed=232, n=8)
    rock(visor, (0, -2.2, 11.6), (0.3, 0.32, 0.6), seed=233, n=6)  # nasal ridge
    eyes = m.piece("Eyes", "Eye", "Neon")
    for s in (-1, 1):
        gem(eyes, (s * 0.55, -2.5, 12.45), 0.3, scale=(1.3, 0.6, 0.7))
    crown = m.piece("Crown", "Wood")
    berries = m.piece("Berries", "Glow", "Neon")
    for k in range(7):
        a = math.radians(-90 + (k - 3) * 34)
        ox, oy = math.cos(a), math.sin(a)
        base = Vector((ox * 1.15, -0.75 + oy * 1.05, 13.4))
        h = 2.6 if k == 3 else (2.1 if k % 2 else 1.7)
        mid = base + Vector((ox * 0.45, oy * 0.3, h * 0.6))
        tip = base + Vector((ox * 1.0, oy * 0.6 + 0.3, h))
        tube(crown, [base, mid, tip], [0.38, 0.24, 0.0], seg=4)
        if k % 2 == 0:
            spike(crown, mid, (ox, oy, 0.3), 0.7, 0.13, seg=3)
            gem(berries, tuple(mid + Vector((ox, oy, 0.3)).normalized() * 0.15), 0.2)
    # ---- long root arms reaching the ground, mossy bramble pauldrons with thorns
    for s, side in ((1, "L"), (-1, "R")):
        anim = "SwingB" if s > 0 else "SwingA"
        sh = (s * 3.0, 0.4, 10.0)
        arm = m.piece("Arm" + side, "Base", anim=anim, pivot=sh)
        elbow, wrist = (s * 4.4, -0.4, 7.4), (s * 4.85, -1.3, 4.0)
        tube(arm, [sh, elbow, wrist, (s * 4.95, -1.7, 2.3)], [1.3, 1.1, 0.95, 1.0], seg=6)
        for dx, dy in ((0.9, -1.4), (0.2, -1.9), (-0.6, -1.4), (1.2, -0.2)):  # root fingers to the ground
            tube(arm, [(s * 4.95, -1.7, 2.4), (s * (4.95 + dx * 0.55), -1.7 + dy * 0.55, 1.0), (s * (4.95 + dx), -1.7 + dy, 0.05)],
                 [0.5, 0.36, 0.0], seg=4)
        pauldron = m.piece("Pauldron" + side, "Leaf", anim=anim, pivot=sh)
        rock(pauldron, (s * 3.3, 0.4, 10.85), (2.0, 1.9, 1.2), seed=241 + s, n=12)
        rock(pauldron, (s * 4.75, -0.8, 5.9), (1.15, 1.15, 1.3), seed=244 + s, n=10)  # bracer
        at = m.piece("ArmThorns" + side, "Light", anim=anim, pivot=sh)
        for base, d, ln in (((3.5, 0.2, 11.6), (0.35, 0.1, 1), 1.6), ((4.4, -0.4, 11.0), (1, -0.2, 0.6), 1.3),
                            ((2.7, 1.3, 11.3), (0.1, 0.9, 0.8), 1.2), ((5.5, -0.9, 6.3), (1, -0.3, 0.3), 1.0)):
            thorn(at, (s * base[0], base[1], base[2]), (s * d[0], d[1], d[2]), ln, 0.3, curl=(0, 0, 0.3))
        vine = m.piece("ArmVine" + side, "Accent", anim=anim, pivot=sh)
        tube(vine, X(s, [(3.2, -0.6, 9.4), (4.3, -1.3, 8.4), (5.0, -0.4, 7.4), (4.4, 0.5, 6.6), (4.8, -0.6, 5.0)]),
             [0.2, 0.22, 0.22, 0.2, 0.18], seg=4)


# ------------------------------------------------------------------ THORN SPROUT

@register("ThornSprout", "Enemies", "ThornSprout id. Briar Sentinel's summon: small thorn beetle ~2.4 wide, bark-brown "
                                    "shell, moss saddle, three bold bone thorns, dark head and legs, amber eyes.")
def thorn_sprout(m):
    """Cheap swarm model (summoned in groups): 7 pieces, <= 450 tris."""
    m.extra["palette"] = {"Base": P("wood_500"), "Leaf": mix("moss_400", "moss_300", 0.3), "Light": mix("gold_200", "wood_400", 0.3),
                          "Dark": P("wood_900"), "Eye": AMBER}
    shell = m.piece("Shell", "Base", shadow=True)
    c = (0, 0.25, 0.55)
    for s in (-1, 1):  # two domed elytra; the dark underside shows through the seam
        ellipsoid(shell, c, (1.15, 1.3, 1.0), seg=8, rings=5, axis="Y",
                  keep=[(c, (0, 0, 1)), (c, (s, 0, 0))], shift=(s * 0.05, 0, 0))
    under = m.piece("Under", "Dark")
    ellipsoid(under, (0, 0.25, 0.6), (1.0, 1.2, 0.35), seg=8, rings=4)
    moss = m.piece("Moss", "Leaf")
    rock(moss, (0, 0.2, 1.42), (0.75, 0.85, 0.25), seed=302, n=10, jitter=0.12)
    thorns = m.piece("Thorns", "Light")
    for base, d, ln in (((0, 0.1, 1.55), (0, 0.45, 1), 1.15), ((0.55, 0.65, 1.3), (0.6, 0.5, 0.8), 0.85),
                        ((-0.55, 0.65, 1.3), (-0.6, 0.5, 0.8), 0.85)):
        thorn(thorns, base, d, ln, 0.22, curl=(0, 0.25, 0.0))
    head = m.piece("Head", "Dark")
    rock(head, (0, -1.0, 0.72), (0.62, 0.48, 0.45), seed=303, n=10, jitter=0.08)
    for s in (-1, 1):  # little mandibles
        tube(head, X(s, [(0.22, -1.38, 0.6), (0.26, -1.68, 0.55), (0.06, -1.85, 0.5)]), [0.09, 0.07, 0.0], seg=3)
    eyes = m.piece("Eyes", "Eye", "Neon")
    for s in (-1, 1):
        gem(eyes, (s * 0.3, -1.35, 0.86), 0.12)
    for s, name, anim in ((1, "LegsL", "SwingA"), (-1, "LegsR", "SwingB")):
        legs = m.piece(name, "Dark", anim=anim, pivot=(s * 0.7, 0.1, 0.5))
        for hip, knee, foot in (((0.7, -0.5, 0.5), (1.1, -0.8, 0.62), (1.22, -1.05, 0.0)),
                                ((0.75, 0.15, 0.48), (1.18, 0.2, 0.65), (1.3, 0.3, 0.0)),
                                ((0.7, 0.75, 0.48), (1.1, 1.0, 0.62), (1.2, 1.3, 0.0))):
            tube(legs, X(s, [hip, knee, foot]), [0.15, 0.12, 0.0], seg=4)
