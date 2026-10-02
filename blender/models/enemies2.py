"""More of the swarm: Spitter, Burrower, Healer, Nest, the Spitter's acid shot and the elite
aura props (heroic low-poly fantasy, same conventions as models/enemies.py).

Creatures: origin = ground centre (z = 0), front = -Y, client-drawn pieces with the runtime
anim keys of src/client/ModelLibrary.lua (SwingA/SwingB legs, FlapL/FlapR, FlutterL/FlutterR
wings, Jaw, Tail, Wiggle, Pulse, Throb, Spin) and a pivot at the joint. One or two big body
pieces cast a shadow. Each type owns a hue; legs and undersides are dark chitin; eyes are tiny
amber Neon; Neon only on small glowing bits.

  Spitter   mauve beetle carrying a bulbous amber acid sac with a raised spout (ranged)
  Burrower  ochre mole-cricket with huge digging claws, a soil ring at its feet (emerges)
  Healer    soft pale aphid with a halo of glowing motes (heals allies)
  Nest      stationary hive mound with openings and glowing egg pods (spawns enemies)

Shot_Acid (Projectiles): the Spitter's glob, centred on the origin, flying toward -Y.
EliteAura_* (Fx): rings around an elite, origin = ground centre, authored for a body of
radius ~1.4 (scale by Radius / 1.4); every piece turns with Spin around the origin axis.
"""

import math

from mathutils import Euler, Vector

from models._propkit import flame
from models.enemies import X, ellipsoid, gem, on_ellipsoid, plate, stud, tube
from models.hats import band, slab, sweep
from style import P, mix
from swarmkit import register

# creature colours that are mixes of palette entries (ModelLibrary can Lerp the same way)
MAUVE = mix("crimson_500", "slate_400", 0.5)          # Spitter shell
MAUVE_DARK = mix("crimson_800", "slate_700", 0.5)     # Spitter pronotum / spout
ACID = mix("amber_500", "crimson_400", 0.32)          # acid sac, acid shot
ACID_GLOW = mix("amber_300", "tick_glow", 0.5)        # acid Neon bits
OCHRE = mix("dirt_400", "amber_500", 0.3)             # Burrower body
OCHRE_DARK = mix("leather_500", "dirt_600", 0.4)      # Burrower shield / claws
APHID = mix("moss_100", "ivory_100", 0.45)            # Healer body
APHID_SHADE = mix("moss_200", "ivory_300", 0.4)       # Healer belly stripes


def legs6(m, hips, knees, feet, r=(0.15, 0.125, 0.0), pivot_y=0.0, pivot_z=0.5, names=("LegsL", "LegsR")):
    """Two leg pieces (three legs each) stepping as alternating sides (SwingA / SwingB)."""
    for s, name, anim in ((1, names[0], "SwingA"), (-1, names[1], "SwingB")):
        legs = m.piece(name, "Dark", anim=anim, pivot=(s * hips[1][0], pivot_y, pivot_z))
        for hip, knee, foot in zip(hips, knees, feet):
            tube(legs, X(s, [hip, knee, foot]), list(r), seg=4)


# ------------------------------------------------------------------ SPITTER

@register("Spitter", "Enemies", "Ranged beetle: mauve shell carrying a bulbous amber acid sac (Pulse) with glowing "
                                "bubbles (Throb) with a raised spout (Jaw = recoil when it "
                                "spits). ~3.2 wide x 3.6 long x 3.2 tall.")
def spitter(m):
    m.extra["palette"] = {"Base": MAUVE, "Accent": ACID, "Light": mix("amber_300", "ivory_100", 0.25),
                          "Glow": ACID_GLOW, "Metal": MAUVE_DARK, "Dark": P("chitin_900"), "Eye": P("amber_500")}
    # acid sac: a fat amber bladder riding high on the abdomen (sloshes = Pulse), a few glowing
    # bubbles welling up on top (Throb), held by two chitin rib bands
    sc, sr = (0, 0.5, 1.32), (1.0, 1.06, 0.92)
    sac = m.piece("Sac", "Accent", anim="Pulse", shadow=True)
    ellipsoid(sac, sc, sr, seg=10, rings=8, axis="Y", taper=-0.12)
    shine = m.piece("SacShine", "Light", anim="Pulse")
    ellipsoid(shine, sc, (sr[0] + 0.03, sr[1] + 0.03, sr[2] + 0.03), seg=10, rings=8, axis="Y", taper=-0.12,
              keep=[((0.3, 0, 0), (1, 0, 0)), ((0.62, 0, 0), (-1, 0, 0)), ((0, 0, 1.75), (0, 0, 1)),
                    ((0, 0.1, 0), (0, 1, 0)), ((0, 0.9, 0), (0, -1, 0))])
    core = m.piece("Core", "Glow", "Neon", anim="Throb")
    for dvec, size in (((0.1, 0.15, 1.0), 0.3), ((-0.45, 0.6, 0.8), 0.2), ((0.5, 0.9, 0.7), 0.17)):
        stud(core, sc, sr, dvec, size, taper=-0.12, seg=5)
    straps = m.piece("Shell", "Base", shadow=True)
    for y in (0.08, 0.92):  # rib bands over the sac
        q = Vector((0, y, sc[2]))
        tube(straps, [q + Vector((-1.0, 0, -0.32)), q + Vector((-0.84, 0, 0.44)), q + Vector((0, 0, 0.99)),
                      q + Vector((0.84, 0, 0.44)), q + Vector((1.0, 0, -0.32))],
             [0.12, 0.13, 0.14, 0.13, 0.12], seg=4, flat=0.55, up=(0, 1, 0))
    # pronotum: the armoured front half, a low dome
    pc = (0, -0.62, 0.72)
    ellipsoid(straps, pc, (0.9, 0.72, 0.62), seg=8, rings=6, axis="Y", keep=[((0, 0, 0.55), (0, 0, 1))])
    body = m.piece("Body", "Dark")
    ellipsoid(body, (0, 0.1, 0.62), (0.86, 1.25, 0.42), seg=8, rings=4)  # underside
    ellipsoid(body, (0, -1.28, 0.62), (0.46, 0.38, 0.34), seg=6, rings=4)  # head
    for s in (-1, 1):  # mandibles
        tube(body, X(s, [(0.18, -1.55, 0.5), (0.22, -1.78, 0.46), (0.06, -1.92, 0.42)]), [0.08, 0.06, 0.0], seg=3)
    # the spout: a curved chitin nozzle rising from the sac front, lip ring, acid bead
    base = Vector((0, -0.1, 2.0))
    spout_pts = [base, Vector((0, -0.28, 2.4)), Vector((0, -0.62, 2.7)), Vector((0, -0.98, 2.84))]
    sp = m.piece("Spout", "Metal", anim="Jaw", pivot=tuple(base))
    tube(sp, spout_pts, [0.34, 0.24, 0.2, 0.2], seg=6)
    tip = spout_pts[-1]
    d = (spout_pts[-1] - spout_pts[-2]).normalized()
    tube(sp, [tip - d * 0.04, tip + d * 0.2], [0.27, 0.33], seg=6)  # flared lip
    drip = m.piece("SpoutGlow", "Glow", "Neon", anim="Jaw", pivot=tuple(base))
    gem(drip, tip + d * 0.18, 0.15, scale=(1, 1, 1))
    eyes = m.piece("Eyes", "Eye", "Neon")
    for s in (-1, 1):
        gem(eyes, (s * 0.27, -1.56, 0.74), 0.095)
    ant = m.piece("Antennae", "Dark", anim="Wiggle", pivot=(0, -1.5, 0.84))
    for s in (-1, 1):
        tube(ant, X(s, [(0.16, -1.52, 0.86), (0.4, -1.86, 1.14), (0.52, -2.0, 1.06)]), [0.05, 0.035, 0.0], seg=3)
    legs6(m, hips=((0.66, -0.7, 0.5), (0.74, 0.0, 0.48), (0.7, 0.68, 0.48)),
          knees=((1.28, -1.1, 0.86), (1.42, 0.0, 0.9), (1.32, 1.04, 0.84)),
          feet=((1.42, -1.42, 0.0), (1.6, 0.06, 0.0), (1.46, 1.38, 0.0)), pivot_y=0.0)


# ------------------------------------------------------------------ SHOT_ACID

@register("Shot_Acid", "Projectiles", "Spitter's acid glob ~1.5 wide x 2.6 long: a fat round head at -Y (flight "
                                      "direction) pulling a wavy tapering tail toward +Y, two trailing droplets, a "
                                      "dark outline rim around the outline (reads by shape), tiny Neon core. "
                                      "Centred on the origin.")
def shot_acid(m):
    m.extra["palette"] = {"Base": ACID, "Accent": P("crimson_400"), "Glow": ACID_GLOW, "Dark": P("crimson_900"),
                          "Light": mix("amber_300", "ivory_100", 0.3)}
    glob = m.piece("Glob", "Base")
    tl = m.piece("Tail", "Accent")
    hc, hr = (0, -0.62, 0), (0.62, 0.66, 0.56)
    ellipsoid(glob, hc, hr, seg=10, rings=6, axis="Y")
    tail = [Vector((0, -0.4, 0)), Vector((0.12, 0.2, 0.02)), Vector((-0.1, 0.78, 0.0)), Vector((0.08, 1.3, 0.0)),
            Vector((0.0, 1.72, 0.0))]
    tube(tl, tail, [0.5, 0.36, 0.24, 0.12, 0.0], seg=6, flat=0.85)
    drops = m.piece("Drops", "Accent")
    for c, r in (((0.5, 0.65, 0.05), 0.15), ((-0.42, 1.25, -0.02), 0.11)):
        ellipsoid(drops, c, (r, r * 1.3, r), seg=6, rings=4, axis="Y")
    # dark outline: a thin flat rim following the top-view silhouette, a little larger
    rim = m.piece("Outline", "Dark")
    pts = []
    for k in range(11):  # round front half
        a = math.radians(180 + 18 * k)
        pts.append((math.cos(a) * (hr[0] + 0.12), hc[1] + math.sin(a) * (hr[1] + 0.12)))
    pts += [(0.66, -0.32), (0.44, 0.3), (0.2, 0.95), (0.12, 1.45), (0.0, 1.86), (-0.14, 1.4), (-0.3, 0.8),
            (-0.6, -0.34)]
    plate(rim, pts, 0.14, loc=(0, 0, -0.04))
    shine = m.piece("Shine", "Light")
    ellipsoid(shine, (0.18, -0.82, 0.38), (0.18, 0.24, 0.12), seg=6, rings=4, axis="Y")
    core = m.piece("Core", "Glow", "Neon", anim="Pulse")
    gem(core, (0, -0.62, 0.42), 0.2, scale=(1, 1.2, 0.6))


# ------------------------------------------------------------------ ELITE AURAS (Fx)

AURA_R = 1.55  # ring radius for a body of radius ~1.4


@register("EliteAura_Burning", "Fx", "Elite aura: a ring of ten low-poly flame licks (fire orange outside, gold "
                                     "inner licks, tiny Neon sparks above) around the body, radius ~1.8, ~1.5 tall. "
                                     "Spin.")
def aura_burning(m):
    m.extra["palette"] = {"Accent": P("fx_fire"), "Gold": mix("fx_gold", "fx_fire", 0.2), "Glow": P("gold_300"),
                          "Dark": P("crimson_500")}
    piv = (0, 0, 0)
    outer = m.piece("Flames", "Accent", anim="Spin", pivot=piv, transparency=0.1)
    inner = m.piece("FlameCores", "Gold", anim="Spin", pivot=piv)
    roots = m.piece("FlameRoots", "Dark", anim="Spin", pivot=piv, transparency=0.1)
    tips = m.piece("Sparks", "Glow", "Neon", anim="Spin", pivot=piv)
    n = 10
    for i in range(n):
        a = i / n * math.tau
        out = Vector((math.cos(a), math.sin(a), 0))
        tang = Vector((-math.sin(a), math.cos(a), 0))
        h = (1.35, 0.85, 1.1, 0.75, 1.2)[i % 5]
        c = out * AURA_R
        lean = tang * 0.38 + out * 0.12  # licks trail the spin and flare outward a little
        flame(roots, tuple(c - tang * 0.08 + Vector((0, 0, -0.02))), 0.17, h * 0.4, seg=4, twist=10,
              lean=(lean.x * 0.3, lean.y * 0.3))
        flame(outer, tuple(c), 0.26, h, seg=5, twist=35, lean=(lean.x, lean.y))
        ci = c + out * 0.13
        flame(inner, (ci.x, ci.y, 0.02), 0.15, h * 0.55, seg=4, twist=-25, lean=(lean.x * 0.55, lean.y * 0.55))
        if i % 2 == 0:
            e = c + lean * 1.5 + Vector((0, 0, h * 1.2))
            gem(tips, tuple(e), 0.06)


@register("EliteAura_Shield", "Fx", "Elite aura: three translucent steel hex shield plates with gold rims orbiting "
                                    "the body at mid height (radius ~1.9, plates ~1.1 across), a small arcane glint "
                                    "on each. Spin.")
def aura_shield(m):
    m.extra["palette"] = {"Metal": mix("slate_200", "fx_arcane", 0.3), "Gold": P("gold_400"), "Glow": P("fx_arcane"),
                          "Accent": P("slate_400")}
    piv = (0, 0, 0)
    plates = m.piece("Plates", "Metal", "Metal", anim="Spin", pivot=piv, transparency=0.25)
    rims = m.piece("Rims", "Gold", "Metal", anim="Spin", pivot=piv)
    glints = m.piece("Glints", "Glow", "Neon", anim="Spin", pivot=piv)
    bosses = m.piece("Bosses", "Accent", "Metal", anim="Spin", pivot=piv, transparency=0.1)
    r_hex, z = 0.6, 1.25
    hexo = [(math.cos(math.radians(30 + 60 * k)) * r_hex, math.sin(math.radians(30 + 60 * k)) * r_hex)
            for k in range(6)]
    for i in range(3):
        a = math.radians(90 + i * 120)
        out = Vector((math.cos(a), math.sin(a), 0))
        c = out * (AURA_R + 0.35) + Vector((0, 0, z + (0.15 if i == 1 else 0.0)))
        yaw = math.degrees(a) - 90  # plate faces outward
        slab(plates, hexo, 0.08, loc=tuple(c), rot=(-8, 0, yaw), bevel=0.02)
        ring = []
        for k in range(6):
            p0 = Vector((hexo[k][0], 0, hexo[k][1]))
            ring.append(p0)
        rm = Euler((math.radians(-8), 0, math.radians(yaw)), "XYZ").to_matrix()
        for k in range(6):  # gold rim bars along each edge
            p0, p1 = rm @ ring[k] + c, rm @ ring[(k + 1) % 6] + c
            tube(rims, [p0.lerp(p1, -0.06), p0.lerp(p1, 1.06)], [0.05, 0.05], seg=4)
        nrm = rm @ Vector((0, -1, 0))
        boss_c = c - nrm * 0.06
        ellipsoid(bosses, tuple(boss_c), (0.2, 0.2, 0.2), seg=6, rings=4, keep=[(tuple(boss_c), tuple(-nrm))])
        gem(glints, tuple(c - nrm * 0.18), 0.07)


@register("EliteAura_Swift", "Fx", "Elite aura: three pale wind-streak ribbons spiralling around the body at "
                                   "different heights (radius ~1.7-2.0), tapered at both ends, translucent ivory; "
                                   "tiny Neon tips at the leading ends. Spin.")
def aura_swift(m):
    m.extra["palette"] = {"Light": P("ivory_100"), "Accent": P("fx_holy"), "Glow": P("fx_bolt")}
    piv = (0, 0, 0)
    streaks = m.piece("Streaks", "Light", anim="Spin", pivot=piv, transparency=0.3)
    inner = m.piece("StreakCores", "Accent", anim="Spin", pivot=piv, transparency=0.1)
    tips = m.piece("Tips", "Glow", "Neon", anim="Spin", pivot=piv)
    for i, (z0, rr, span, a0) in enumerate(((0.35, AURA_R + 0.25, 150, 0), (1.05, AURA_R + 0.4, 130, 120),
                                            (1.75, AURA_R + 0.1, 110, 240))):
        pts, rad, rad2 = [], [], []
        n = 7
        for k in range(n):
            u = k / (n - 1)
            a = math.radians(a0 + span * u)
            z = z0 + 0.35 * u
            pts.append(Vector((math.cos(a) * rr, math.sin(a) * rr, z)))
            w = math.sin(math.pi * min(1.0, u * 1.25)) if u < 0.8 else math.sin(math.pi * u) * 1.6
            rad.append(max(0.0, 0.085 * w) if 0 < k < n - 1 else 0.0)
            rad2.append(max(0.0, 0.05 * w) if 0 < k < n - 1 else 0.0)
        sweep(streaks, pts, rad, seg=4, sx=2.8, up=(0, 0, 1))
        inn = [p * 0.985 + Vector((0, 0, 0.02)) for p in pts]
        sweep(inner, inn, rad2, seg=4, sx=2.2, up=(0, 0, 1))
        gem(tips, tuple(pts[-2] + (pts[-1] - pts[-2]) * 0.5), 0.06)


# ------------------------------------------------------------------ BURROWER

@register("Burrower", "Enemies", "Digger: ochre mole-cricket with an armoured pronotum and huge shovel claws (Jaw = dig "
                                 "stroke), soft segmented abdomen, a ring of soil clods at its feet (Mound piece, "
                                 "hide it when walking on the surface). ~3.4 wide x 3.6 long x 1.9 tall.")
def burrower(m):
    m.extra["palette"] = {"Base": OCHRE, "Accent": OCHRE_DARK, "Light": mix("dirt_300", "amber_300", 0.3),
                          "Dark": P("chitin_900"), "Eye": P("amber_500"), "Stone": P("dirt_600"),
                          "Wood": P("dirt_700")}
    # abdomen: soft ochre segments tapering back, with lighter rims (dorsal bands)
    ab = m.piece("Abdomen", "Base", shadow=True)
    rims = m.piece("Bands", "Light")
    for i, (y, r, z) in enumerate(((0.18, 0.8, 0.82), (0.78, 0.7, 0.76), (1.3, 0.5, 0.66))):
        c = (0, y, z)
        ellipsoid(ab, c, (r, 0.44, r * 0.82), seg=6, rings=4, axis="Y")
        if i < 2:
            tube(rims, [(0, y + 0.26, z), (0, y + 0.34, z)], [r * 0.9, r * 0.78], seg=6, caps=(False, True))
    for s in (-1, 1):  # cerci
        tube(ab, X(s, [(0.18, 1.7, 0.66), (0.4, 2.1, 0.8), (0.5, 2.36, 0.74)]), [0.06, 0.04, 0.0], seg=3)
    # pronotum: a velvety helmet-shaped shield over the front
    pron = m.piece("Pronotum", "Accent", shadow=True)
    pc = (0, -0.62, 0.92)
    ellipsoid(pron, pc, (0.84, 0.8, 0.68), seg=8, rings=6, axis="Y", keep=[((0, 0, 0.5), (0, 0, 1))])
    body = m.piece("Body", "Dark")
    ellipsoid(body, (0, -0.2, 0.62), (0.7, 1.3, 0.36), seg=6, rings=4)  # underside
    ellipsoid(body, (0, -1.38, 0.72), (0.42, 0.36, 0.32), seg=6, rings=4)  # head
    eyes = m.piece("Eyes", "Eye", "Neon")
    for s in (-1, 1):
        gem(eyes, (s * 0.3, -1.56, 0.86), 0.09)
    ant = m.piece("Antennae", "Dark", anim="Wiggle", pivot=(0, -1.6, 0.86))
    for s in (-1, 1):
        tube(ant, X(s, [(0.12, -1.66, 0.88), (0.3, -1.96, 1.0), (0.5, -2.1, 0.94)]), [0.045, 0.03, 0.0], seg=3)
    # shovel claws: thick forelegs ending in flat, toothed digging hands, forward and out
    for s, side in ((1, "L"), (-1, "R")):
        sh = (s * 0.62, -1.02, 0.62)
        claw = m.piece("Claw" + side, "Accent", anim="Jaw", pivot=sh)
        tube(claw, X(s, [(0.62, -1.02, 0.62), (1.2, -1.32, 0.8), (1.4, -1.7, 0.55)]), [0.3, 0.3, 0.26], seg=5)
        hc = Vector((s * 1.5, -2.0, 0.42))
        ellipsoid(claw, tuple(hc), (0.66, 0.46, 0.24), seg=6, rings=4, rot=(20, 0, s * -25))
        tips = m.piece("ClawTips" + side, "Dark", anim="Jaw", pivot=sh)
        for k in range(4):  # four digging teeth fanning forward
            a = math.radians(-60 + k * 34) * s
            base = hc + Vector((math.sin(a) * 0.44, -math.cos(a) * 0.3, -0.02))
            tip = base + Vector((math.sin(a) * 0.5, -math.cos(a) * 0.44, -0.26))
            tube(tips, [base, tip], [0.12, 0.0], seg=4)
    for s, name, anim in ((1, "LegsL", "SwingA"), (-1, "LegsR", "SwingB")):
        lp = m.piece(name, "Dark", anim=anim, pivot=(s * 0.6, 0.0, 0.55))
        tube(lp, X(s, [(0.6, -0.2, 0.55), (1.18, -0.3, 0.86), (1.36, -0.5, 0.0)]), [0.12, 0.1, 0.0], seg=4)
        tube(lp, X(s, [(0.62, 0.3, 0.55), (1.22, 0.62, 1.14), (1.44, 1.16, 0.0)]), [0.15, 0.12, 0.0], seg=4)
    # the soil it dug through: a broken ring of clods round the feet
    mound = m.piece("Mound", "Stone", shadow=True)
    for k in range(6):
        a = k / 6 * math.tau + 0.3
        r = 1.85 + 0.18 * math.sin(k * 2.3)
        c = (math.cos(a) * r, math.sin(a) * r * 1.1, 0.08)
        size = 0.46 + 0.14 * ((k * 7) % 3) / 2
        ellipsoid(mound, c, (size, size * 0.85, size * 0.55), seg=5, rings=3, lumps=0.18, seed=k,
                  keep=[((0, 0, 0.0), (0, 0, 1))])


# ------------------------------------------------------------------ HEALER

@register("Healer", "Enemies", "Support bug: soft pale aphid with a round glowing belly (Pulse), two cornicles, small "
                               "translucent wings (FlutterL/R) and a halo of six glowing motes above it (Spin, "
                               "pivot on the halo axis). ~2.6 wide x 2.8 long x 3.1 tall incl. halo.")
def healer(m):
    m.extra["palette"] = {"Base": APHID, "Light": APHID_SHADE, "Glow": P("fx_heal"), "Dark": P("chitin_800"),
                          "Eye": P("amber_500"), "White": P("ivory_100"), "Accent": mix("fx_heal", "moss_300", 0.4)}
    bc, br = (0, 0.28, 1.0), (0.92, 1.05, 0.82)
    body = m.piece("Body", "Base", shadow=True)
    ellipsoid(body, bc, br, seg=10, rings=7, axis="Y", taper=-0.18)  # pear-shaped abdomen
    ellipsoid(body, (0, -0.78, 0.92), (0.46, 0.42, 0.42), seg=8, rings=5)  # thorax
    stripes = m.piece("Stripes", "Light")
    for y in (0.12, 0.7):  # soft dorsal bands
        ellipsoid(stripes, bc, (br[0] + 0.025, br[1] + 0.025, br[2] + 0.025), seg=10, rings=7, axis="Y",
                  taper=-0.18, keep=[((0, y - 0.08, 0), (0, 1, 0)), ((0, y + 0.08, 0), (0, -1, 0)),
                                     ((0, 0, 1.2), (0, 0, 1))])
    head = m.piece("Head", "Dark")
    ellipsoid(head, (0, -1.22, 0.84), (0.32, 0.28, 0.28), seg=6, rings=4)
    tube(head, [(0, -1.42, 0.74), (0, -1.6, 0.48)], [0.07, 0.0], seg=3)  # beak
    eyes = m.piece("Eyes", "Eye", "Neon")
    for s in (-1, 1):
        gem(eyes, (s * 0.2, -1.4, 0.92), 0.07)
    horns = m.piece("Cornicles", "Accent")
    for s in (-1, 1):  # the aphid's two little siphons, tipped with glow
        tube(horns, X(s, [(0.34, 1.0, 1.36), (0.52, 1.36, 1.7), (0.56, 1.5, 1.84)]), [0.1, 0.08, 0.07], seg=5)
    belly = m.piece("Glow", "Glow", "Neon", anim="Pulse")
    for s in (-1, 1):
        gem(belly, (s * 0.56, 1.5, 1.86), 0.09)
    stud(belly, bc, br, (0, 0.1, 1.0), 0.34, taper=-0.18, seg=6)  # a soft glowing heart on the back
    ant = m.piece("Antennae", "White", anim="Wiggle", pivot=(0, -1.3, 1.0))
    for s in (-1, 1):
        tube(ant, X(s, [(0.12, -1.32, 1.02), (0.36, -1.6, 1.38), (0.6, -1.66, 1.6)]), [0.04, 0.03, 0.0], seg=3)
    wing = [(0.1, -0.2), (0.6, -0.42), (1.12, -0.3), (1.22, 0.0), (0.7, 0.2), (0.2, 0.12)]
    for s, name, anim in ((1, "WingL", "FlutterL"), (-1, "WingR", "FlutterR")):
        w = m.piece(name, "White", anim=anim, pivot=(s * 0.3, -0.66, 1.3), transparency=0.45)
        pts = [(s * (x + 0.2), y - 0.6) for x, y in wing]
        if s < 0:
            pts.reverse()
        plate(w, pts, 0.03, loc=(0, 0, 1.32), rot=(0, -s * 24, 0))
    legs6(m, hips=((0.32, -0.92, 0.7), (0.4, -0.66, 0.66), (0.4, -0.36, 0.66)),
          knees=((0.86, -1.24, 0.96), (1.02, -0.7, 1.0), (0.98, 0.06, 0.96)),
          feet=((0.98, -1.5, 0.0), (1.22, -0.68, 0.0), (1.16, 0.32, 0.0)), r=(0.07, 0.06, 0.0), pivot_y=-0.66,
          pivot_z=0.66)
    hc = (0, 0.1, 2.62)
    halo = m.piece("Halo", "Glow", "Neon", anim="Spin", pivot=hc)
    ring = m.piece("HaloRing", "White", anim="Spin", pivot=hc, transparency=0.55)
    band(ring, 0.86, 0.94, -0.025, 0.025, seg=9, loc=hc)
    for k in range(6):
        a = k / 6 * math.tau
        gem(halo, (hc[0] + math.cos(a) * 0.9, hc[1] + math.sin(a) * 0.9, hc[2] + 0.06 * math.sin(3 * a)),
            0.13 if k % 2 == 0 else 0.09)


# ------------------------------------------------------------------ NEST

def disc_on(p, c, r, d, radius, depth, seg=8, out=0.0):
    """Flat disc lying on an ellipsoid surface in direction d (openings, lips)."""
    from models.enemies import disc
    q, n = on_ellipsoid(c, r, d)
    return disc(p, tuple(q + n * out), tuple(n), radius, depth, seg=seg)


@register("Nest", "Enemies", "Stationary hive mound ~5.2 wide x 4.2 tall: lumpy dirt-and-wax tiers, dark openings with "
                             "waxy lips (enemies crawl out of them), a cluster of glowing amber egg pods at the "
                             "base (Pulse) and a glowing crown vent (Throb). Does not move or turn.")
def nest(m):
    m.extra["palette"] = {"Base": P("dirt_500"), "Accent": mix("dirt_400", "amber_500", 0.25),
                          "Light": mix("amber_300", "ivory_100", 0.25), "Dark": P("chitin_900"),
                          "Glow": P("tick_glow"), "Stone": P("dirt_700")}
    mound = m.piece("Mound", "Base", shadow=True)
    tiers = [((0, 0.1, 0.0), (2.35, 2.15, 1.55), 1), ((0.1, 0.0, 1.4), (1.65, 1.5, 1.35), 2),
             ((-0.05, 0.1, 2.55), (0.95, 0.9, 1.25), 3)]
    for c, r, seed in tiers:
        ellipsoid(mound, c, r, seg=8, rings=5, lumps=0.07, seed=seed, keep=[((0, 0, 0.0), (0, 0, 1))])
    wax = m.piece("WaxRims", "Accent")
    for c, r, seed in tiers[:2]:  # waxy shelf at the top of each tier
        tube(wax, [(c[0], c[1], c[2] + r[2] * 0.55 - 0.08), (c[0], c[1], c[2] + r[2] * 0.55 + 0.1)],
             [r[0] * 0.86, r[0] * 0.8], seg=9, caps=(False, True))
    base = m.piece("Footing", "Stone")
    for k in range(4):
        a = k / 4 * math.tau + 0.4
        cc = (math.cos(a) * 2.3, math.sin(a) * 2.1, 0.05)
        ellipsoid(base, cc, (0.55, 0.46, 0.34), seg=5, rings=2, lumps=0.2, seed=30 + k, keep=[((0, 0, 0), (0, 0, 1))])
    holes = m.piece("Openings", "Dark")
    lips = m.piece("Lips", "Light")
    for (ti, d, rad) in ((0, (0.0, -1.0, 0.25), 0.58), (0, (0.85, 0.5, 0.25), 0.5), (1, (0.6, -0.8, 0.35), 0.42),
                         (2, (0.1, -0.9, 0.3), 0.34)):
        c, r, _ = tiers[ti]
        disc_on(lips, c, r, d, rad + 0.14, 0.16, seg=6, out=0.02)
        disc_on(holes, c, r, d, rad, 0.2, seg=6, out=0.08)
    eggs = m.piece("Eggs", "Light", anim="Pulse")
    cores = m.piece("EggGlow", "Glow", "Neon", anim="Pulse")
    for k, (x, y, z, s) in enumerate(((1.5, -1.65, 0.38, 0.42), (1.98, -1.02, 0.34, 0.38), (1.72, -1.4, 0.88, 0.32),
                                      (-1.72, -1.5, 0.36, 0.4), (-2.1, -0.82, 0.32, 0.34), (-1.0, -2.0, 0.3, 0.3))):
        ellipsoid(eggs, (x, y, z), (s, s, s * 1.3), seg=5, rings=3)
        if k < 5:
            gem(cores, (x * 1.06, y * 1.06, z + 0.05), s * 0.42, scale=(1, 1, 1.3))
    vent = m.piece("Vent", "Glow", "Neon", anim="Throb")
    vent.cyl(0.32, 0.22, 0.2, seg=6, loc=(0, 0.05, 3.86))
    rim = m.piece("VentRim", "Dark")
    tube(rim, [(0, 0.05, 3.7), (0, 0.05, 3.9)], [0.5, 0.42], seg=8)
