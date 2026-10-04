"""Three more swarm bosses: Moth Matriarch, Rhino Warlord, Hive Mother (heroic low-poly fantasy).

Same conventions as models/enemies.py (category "Enemies"): origin = ground centre (z = 0),
front = -Y, client-drawn pieces with the runtime anim keys of src/client/ModelLibrary.lua and a
pivot at the joint, one or two big shadow pieces, dark chitin legs and undersides, tiny amber
Neon eyes, Neon only on small glowing bits. Budget <= 3500 tris, 12-14 studs.

  MothMatriarch  regal moth, ~14 span; layered translucent wings with gold eye-spots, a crown of
                 feathery antennae (flies: the body hangs ~4 studs up, legs dangle)
  RhinoWarlord   massive armoured rhino beetle in gold-trimmed steel battle plates carrying a
                 crimson war banner, ~13 long
  HiveMother     bloated queen: armoured head and thorax, a huge egg-sac abdomen with amber
                 pods that Throb, many small legs, ~13 long
"""

import math

from mathutils import Vector

from models.enemies import X, annulus, ellipsoid, gem, on_ellipsoid, plate, stud, tube
from models.hats import band, slab
from style import P, mix
from swarmkit import register


def wing_outline(pts, s, k=1.0):
    out = [(s * x * k, y * k) for x, y in pts]
    return list(reversed(out)) if s < 0 else out


# ------------------------------------------------------------------ MOTH MATRIARCH

@register("MothMatriarch", "Enemies", "Boss (flies). Huge regal moth ~14 span x 9 long: ivory fur, two layers of "
                                      "translucent wings (slate under-wings, pale lavender fore-wings) with gold "
                                      "eye-spots and dark rims, a gold coronet and a crown of five feathery antennae, "
                                      "glowing heart (Pulse). Wings FlutterL/R, antennae Wiggle, legs SwingA/B.")
def moth_matriarch(m):
    # overhaul 2026-10: closer to art/bosses/MothMatriarch.png and readable on snow: violet
    # fore-wings and deep plum under-wings with a dark plum rim along the outer edge, cream fur
    # thorax, a dark navy abdomen under gold bands (the lavender wings and gold eye-spots stay)
    lav = (0.6, 0.5, 0.78)
    m.extra["palette"] = {"Base": mix("ivory_200", "moth_300", 0.35), "Light": lav,
                          "Accent": (0.34, 0.25, 0.5), "Gold": P("gold_400"), "Belly": (0.2, 0.2, 0.32),
                          "Dark": P("chitin_800"), "Eye": P("amber_500"), "Glow": P("moth_glow"),
                          "White": P("ivory_100"), "Metal": (0.17, 0.12, 0.26)}
    zc = 4.2  # body height
    body = m.piece("Body", "Base", shadow=True)
    ellipsoid(body, (0, -0.6, zc), (1.3, 1.35, 1.25), seg=10, rings=7, lumps=0.08, seed=5)  # thorax
    ellipsoid(body, (0, -1.85, zc + 0.1), (1.25, 0.6, 1.05), seg=10, rings=5, lumps=0.14, seed=9)  # fur ruff
    ellipsoid(body, (0, -2.45, zc + 0.05), (0.72, 0.6, 0.66), seg=8, rings=5)  # head
    abd = m.piece("Abdomen", "Belly", anim="Tail", pivot=(0, 0.6, zc))
    gold_b = m.piece("AbdomenBands", "Gold", "Metal", anim="Tail", pivot=(0, 0.6, zc))
    pts = [Vector((0, 0.5, zc)), Vector((0, 1.6, zc - 0.25)), Vector((0, 2.7, zc - 0.6)), Vector((0, 3.6, zc - 1.05)),
           Vector((0, 4.3, zc - 1.5))]
    rad = [0.95, 1.0, 0.85, 0.55, 0.0]
    tube(abd, pts, rad, seg=8)
    for i in (1, 2, 3):
        d = (pts[i + 1] - pts[i - 1]).normalized()
        tube(gold_b, [pts[i] - d * 0.1, pts[i] + d * 0.1], [rad[i] * 1.06 + 0.02] * 2, seg=8)
    # gold coronet on the brow and the crown of feathery antennae fanning up and out
    crown = m.piece("Coronet", "Gold", "Metal")
    hc = Vector((0, -2.45, zc + 0.05))
    band(crown, 0.5, 0.64, -0.1, 0.12, seg=8, loc=hc + Vector((0, 0.05, 0.5)), rot=(-18, 0, 0))
    for x in (-0.36, 0.0, 0.36):
        tube(crown, [hc + Vector((x, -0.15, 0.6)), hc + Vector((x * 1.2, -0.2, 1.02))], [0.1, 0.0], seg=4)
    gem(crown, tuple(hc + Vector((0, -0.62, 0.48))), 0.13)
    ant = m.piece("Antennae", "White", anim="Wiggle", pivot=tuple(hc + Vector((0, 0, 0.5))))
    for ang, ln, lift in ((-62, 2.2, 0.9), (-28, 2.9, 1.5), (0, 2.4, 1.9), (28, 2.9, 1.5), (62, 2.2, 0.9)):
        a = math.radians(ang)
        out = Vector((math.sin(a), -math.cos(a) * 0.8, 0))
        b0 = hc + Vector((math.sin(a) * 0.35, -0.2, 0.62))
        spine = [b0, b0 + out * ln * 0.35 + Vector((0, 0, lift * 0.55)), b0 + out * ln * 0.75 + Vector((0, 0, lift)),
                 b0 + out * ln + Vector((0, 0, lift * 0.92))]
        tube(ant, spine, [0.1, 0.08, 0.06, 0.0], seg=4)
        side = out.cross(Vector((0, 0, 1))).normalized()
        for t in (0.15, 0.4, 0.65, 0.9):  # feather barbs: flat blades both sides of the shaft
            q = spine[1].lerp(spine[2], t) if t < 0.9 else spine[2].lerp(spine[3], 0.4)
            for sgn in (1, -1):
                tube(ant, [q, q + side * sgn * 0.75 * (1.15 - t * 0.6) + out * 0.35 + Vector((0, 0, 0.1))],
                     [0.13, 0.0], seg=3, flat=0.35, up=(0, 0, 1))
    eyes = m.piece("Eyes", "Eye", "Neon")
    for s in (-1, 1):
        gem(eyes, (s * 0.42, -2.95, zc + 0.15), 0.16, scale=(0.9, 1, 1.2))
    core = m.piece("Heart", "Glow", "Neon", anim="Pulse")
    gem(core, (0, -0.7, zc + 1.28), 0.3, scale=(1, 1.4, 0.6))
    for s, name, anim in ((1, "LegsL", "SwingA"), (-1, "LegsR", "SwingB")):  # dangling legs
        legs = m.piece(name, "Dark", anim=anim, pivot=(s * 0.6, -0.8, zc - 0.9))
        for y, dk in ((-1.4, -0.3), (-0.8, 0.0), (-0.2, 0.35)):
            tube(legs, X(s, [(0.55, y, zc - 0.9), (1.15, y + dk * 0.5, zc - 1.6), (1.05, y + dk, zc - 2.8)]),
                 [0.12, 0.09, 0.0], seg=4)
    # wings: under-wings (slate, a little more solid) and fore-wings (pale, translucent),
    # each with a gold eye-spot ring, a dark pupil and a dark rim at the tip
    fore = [(0.4, -1.6), (2.2, -2.9), (4.6, -3.4), (6.6, -2.8), (7.1, -1.4), (6.6, -0.6), (6.0, 0.0), (4.7, 0.15),
            (3.4, 0.5), (1.3, 0.1), (0.4, -0.5)]
    # hind wings sweep back into long regal tails
    hind = [(0.4, -0.2), (2.2, 0.3), (4.2, 1.0), (4.9, 2.4), (4.1, 3.6), (3.2, 4.4), (2.6, 6.2), (2.1, 6.4),
            (1.9, 4.6), (0.8, 2.0)]
    zr, dih = zc + 0.55, 14
    for s, side, anim in ((1, "L", "FlutterL"), (-1, "R", "FlutterR")):
        piv = (s * 0.7, -0.6, zr)
        rot = (0, -s * dih, 0)
        under = m.piece("UnderWing" + side, "Accent", anim=anim, pivot=piv, transparency=0.08)
        plate(under, wing_outline(hind, s), 0.1, loc=(0, 0, zr - 0.08), rot=rot)
        plate(under, wing_outline([(x * 0.9, y * 0.9 - 0.15) for x, y in fore], s), 0.1, loc=(0, 0, zr - 0.1), rot=rot)
        over = m.piece("Wing" + side, "Light", anim=anim, pivot=piv, transparency=0.12)
        plate(over, wing_outline(fore, s), 0.08, loc=(0, 0, zr + 0.04), rot=rot)
        spots = m.piece("EyeSpots" + side, "Gold", "Metal", anim=anim, pivot=piv)
        annulus(spots, (s * 4.3, -1.6), 0.95, 0.55, 0.12, seg=10, loc=(0, 0, zr + 0.08), rot=rot)
        annulus(spots, (s * 2.9, 2.0), 0.6, 0.34, 0.12, seg=8, loc=(0, 0, zr + 0.0), rot=rot)
        marks = m.piece("WingMarks" + side, "Metal", anim=anim, pivot=piv)
        ring = [(s * 4.3 + math.cos(2 * math.pi * k / 8) * 0.5, -1.6 + math.sin(2 * math.pi * k / 8) * 0.5) for k in range(8)]
        plate(marks, ring if s > 0 else list(reversed(ring)), 0.1, loc=(0, 0, zr + 0.08), rot=rot)
        tip = [(5.9, -3.05), (6.6, -2.8), (7.1, -1.4), (6.75, -0.75), (6.5, -1.9)]
        plate(marks, wing_outline(tip, s), 0.12, loc=(0, 0, zr + 0.06), rot=rot)
        edge = [(2.6, 6.2), (2.1, 6.4), (2.0, 5.5), (2.7, 5.4)]
        plate(marks, wing_outline(edge, s), 0.12, loc=(0, 0, zr - 0.02), rot=rot)
        # dark rim along the fore-wing's outer edge: a strip between the outline and a copy
        # pulled 0.42 studs toward the wing centre (wing-edge contrast on snow and grass)
        cx = sum(x for x, _ in fore) / len(fore)
        cy = sum(y for _, y in fore) / len(fore)
        for i in range(1, 7):
            a, b = fore[i], fore[i + 1]
            def inner(q):
                dx, dy = cx - q[0], cy - q[1]
                d = math.hypot(dx, dy) or 1.0
                return (q[0] + dx / d * 0.42, q[1] + dy / d * 0.42)
            quad = [a, b, inner(b), inner(a)]
            plate(marks, wing_outline(quad, s), 0.1, loc=(0, 0, zr + 0.09), rot=rot)


# ------------------------------------------------------------------ RHINO WARLORD

@register("RhinoWarlord", "Enemies", "Boss. Massive armoured rhino beetle ~10 wide x 13 long, horn to ~8.5, banner to "
                                     "~13: dark slate shell under gold-trimmed steel battle plates, ivory horn with "
                                     "gold bands (Jaw = horn toss), a crimson war banner with a gold crown on a pole "
                                     "on its back (Tail = sway), six legs SwingA/B.")
def rhino_warlord(m):
    m.extra["palette"] = {"Base": P("slate_600"), "Metal": P("steel_400"), "Accent": P("steel_600"),
                          "Gold": P("gold_500"), "Dark": P("chitin_900"), "White": P("ivory_200"),
                          "Eye": P("amber_500"), "Cloth": P("crimson_500"), "Wood": P("wood_700"),
                          "Glow": P("amber_300")}
    shell = m.piece("Shell", "Base", shadow=True)
    ec, er = (0, 1.4, 3.1), (4.1, 4.3, 3.4)
    for s in (-1, 1):
        ellipsoid(shell, ec, er, seg=12, rings=8, axis="Y", keep=[(ec, (0, 0, 1)), (ec, (s, 0, 0))],
                  shift=(s * 0.1, 0, 0))
    body = m.piece("Body", "Dark")
    ellipsoid(body, (0, 0.2, 3.0), (3.6, 5.0, 1.6), seg=10, rings=4, keep=[((0, 0, 3.0), (0, 0, -1))])
    ellipsoid(body, (0, -4.3, 2.6), (1.7, 1.4, 1.3), seg=8, rings=5)  # head
    # battle plates: three overlapping steel saddle plates across the back, gold rims and studs
    plates = m.piece("Plates", "Metal", "Metal", shadow=True)
    trim = m.piece("PlateTrim", "Gold", "Metal")
    for i, (y, w) in enumerate(((-0.6, 3.5), (1.4, 3.7), (3.3, 3.2))):
        c, r = (0, y, ec[2] - 0.15), (w, 1.25, er[2] + 0.25)
        ellipsoid(plates, c, r, seg=12, rings=6, axis="Y", keep=[((0, 0, ec[2] + 1.1), (0, 0, 1))])
        ellipsoid(trim, c, (r[0] + 0.06, r[1] + 0.06, r[2] + 0.06), seg=12, rings=6, axis="Y",
                  keep=[((0, 0, ec[2] + 1.1), (0, 0, 1)), ((0, y - 0.85, 0), (0, -1, 0))])
        for s in (-1, 1):
            q, n = on_ellipsoid(c, r, (s * 0.8, 0, 0.8))
            gem(trim, tuple(q + n * 0.05), 0.24)
    pron = m.piece("Pronotum", "Accent", "Metal")
    pc = (0, -2.5, 3.2)
    ellipsoid(pron, pc, (3.2, 1.9, 2.6), seg=12, rings=6, axis="Y", keep=[(pc, (0, 0, 1))])
    ptrim = m.piece("PronotumTrim", "Gold", "Metal")
    ellipsoid(ptrim, pc, (3.26, 1.96, 2.66), seg=12, rings=6, axis="Y",
              keep=[(pc, (0, 0, 1)), ((0, -3.3, 0), (0, -1, 0))])
    horns = m.piece("Horns", "White")
    for s in (-1, 1):  # two short pronotum horns
        tube(horns, X(s, [(1.2, -3.2, 5.0), (1.5, -3.9, 5.9), (1.4, -4.3, 6.4)]), [0.42, 0.24, 0.0], seg=5)
    piv = (0, -4.7, 2.7)
    horn = m.piece("Horn", "White", anim="Jaw", pivot=piv)
    hp = [(0, -5.1, 2.5), (0, -6.3, 2.9), (0, -6.9, 4.1), (0, -6.85, 5.8), (0, -6.3, 7.4), (0, -5.7, 8.3)]
    tube(horn, hp, [0.95, 0.82, 0.66, 0.48, 0.26, 0.0], seg=7)
    hb = m.piece("HornBands", "Gold", "Metal", anim="Jaw", pivot=piv)
    for i in (1, 3):
        a, b = Vector(hp[i]), Vector(hp[i + 1])
        d = (b - a).normalized()
        r = [0.95, 0.82, 0.66, 0.48, 0.26][i]
        tube(hb, [a + d * 0.05, a + d * 0.35], [r * 1.08, r * 1.02], seg=7)
    eyes = m.piece("Eyes", "Eye", "Neon")
    for s in (-1, 1):
        gem(eyes, (s * 1.15, -5.2, 2.9), 0.2)
    for i, (y, dk, df) in enumerate(((-2.4, -0.7, -1.5), (0.6, 0.0, 0.2), (3.4, 0.7, 1.7))):
        for s, side in ((1, "L"), (-1, "R")):
            anim = "SwingA" if (i % 2 == 0) == (s > 0) else "SwingB"
            hip = (s * 2.6, y, 2.4)
            leg = m.piece(f"Leg{side}{i + 1}", "Dark", anim=anim, pivot=hip)
            knee = (s * 4.6, y + dk, 3.8)
            ankle = (s * 5.1, y + df, 0.9)
            tube(leg, [hip, knee, ankle, (s * 5.2, y + df * 1.1, 0.0)], [0.7, 0.58, 0.36, 0.0], seg=5)
            for t in (0.35, 0.7):
                q = Vector(knee).lerp(Vector(ankle), t)
                tube(leg, [q, q + Vector((s * 0.6, 0.0, 0.3))], [0.16, 0.0], seg=3)
    # the war banner: pole socketed into the rear plate, crimson flag with a gold crown, swaying
    bp = (0, 3.6, 5.6)
    pole = m.piece("BannerPole", "Wood", anim="Tail", pivot=bp)
    tube(pole, [(0, 3.6, 5.0), (0, 3.9, 13.0)], [0.2, 0.17], seg=6)
    cap = m.piece("BannerTrim", "Gold", "Metal", anim="Tail", pivot=bp)
    tube(cap, [(0, 3.9, 12.9), (0, 3.92, 13.3), (0, 3.94, 13.8)], [0.32, 0.26, 0.0], seg=5)
    tube(cap, [(-1.9, 3.85, 12.4), (1.9, 3.85, 12.4)], [0.13, 0.13], seg=5)  # crossbar
    for s in (-1, 1):
        gem(cap, (s * 2.0, 3.85, 12.4), 0.2)
    flag = m.piece("Banner", "Cloth", anim="Tail", pivot=bp, shadow=True)
    outline = [(-1.75, 12.3), (1.75, 12.3), (1.8, 7.9), (0.9, 8.6), (0.0, 7.5), (-0.9, 8.6), (-1.8, 7.9)]
    slab(flag, outline, 0.14, loc=(0, 4.05, 0), bevel=0.04)
    emb = m.piece("BannerCrown", "Gold", "Metal", anim="Tail", pivot=bp)
    crown = [(-0.85, 9.9), (0.85, 9.9), (1.0, 11.3), (0.5, 10.75), (0.0, 11.55), (-0.5, 10.75), (-1.0, 11.3)]
    slab(emb, crown, 0.06, loc=(0, 3.94, 0))
    slab(emb, crown, 0.06, loc=(0, 4.16, 0))
    slab(emb, [(-1.75, 12.3), (1.75, 12.3), (1.75, 12.0), (-1.75, 12.0)], 0.2, loc=(0, 4.05, 0))


# ------------------------------------------------------------------ HIVE MOTHER

@register("HiveMother", "Enemies", "Boss. Bloated hive queen ~9 wide x 13.5 long x 6.5 tall: dark amber armoured head "
                                   "and thorax with a gold crown, crushing mandibles (Jaw), a huge pale banded egg-sac "
                                   "abdomen dragging behind (Tail = slow heave) studded with glowing amber pods "
                                   "(Throb), an egg at the tip, ten small legs (SwingA/B), antennae Wiggle.")
def hive_mother(m):
    m.extra["palette"] = {"Base": mix("ivory_200", "amber_300", 0.3), "Accent": mix("dirt_300", "amber_500", 0.35),
                          "Metal": mix("wasp_900", "amber_500", 0.28), "Gold": P("gold_500"),
                          "Dark": P("chitin_900"), "Eye": P("amber_500"), "Glow": P("amber_300"),
                          "Light": mix("amber_300", "ivory_100", 0.4)}
    # abdomen: a chain of swelling segments, pale wax with tan joints, resting on the ground
    piv = (0, -0.6, 2.4)
    sac = m.piece("EggSac", "Base", anim="Tail", pivot=piv, shadow=True)
    joints = m.piece("SacBands", "Accent", anim="Tail", pivot=piv)
    segs = [(0.3, 2.2, 2.3, 1.6), (2.0, 2.9, 3.0, 2.15), (3.9, 3.2, 3.2, 2.4), (5.7, 2.9, 2.9, 2.2),
            (7.2, 2.2, 2.2, 1.75), (8.3, 1.3, 1.4, 1.2)]
    for i, (y, rx, rz, ry) in enumerate(segs):
        c = (0, y, rz * 0.92)
        ellipsoid(sac, c, (rx, ry * 0.62, rz * 0.92), seg=12, rings=6, axis="Y")
        if i:
            yj = (segs[i - 1][0] + y) / 2
            rj = min(rx, segs[i - 1][1]) * 0.94
            zj = min(rz, segs[i - 1][2]) * 0.92
            tube(joints, [(0, yj - 0.18, zj), (0, yj + 0.18, zj)], [rj, rj], seg=12, flat=zj / rj)
    pods = m.piece("Pods", "Glow", "Neon", anim="Throb")
    for i, (y, rx, rz, ry) in enumerate(segs[1:5]):
        c, r = (0, y, rz * 0.92), (rx, ry * 0.62, rz * 0.92)
        for d, size in (((0.0, 0.0, 1.0), 0.5), ((0.75, 0.0, 0.6), 0.4), ((-0.75, 0.0, 0.6), 0.4)):
            if i % 2 and d[0] == 0:
                continue
            stud(pods, c, r, d, size, seg=6)
    egg = m.piece("Egg", "Light", anim="Tail", pivot=piv)
    ellipsoid(egg, (0, 9.45, 1.0), (0.6, 0.8, 0.6), seg=8, rings=5, axis="Y")
    # thorax and head: dark amber chitin plates, gold crown, mandibles
    tho = m.piece("Thorax", "Metal", shadow=True)
    tc = (0, -1.8, 2.5)
    ellipsoid(tho, tc, (2.3, 1.6, 1.85), seg=10, rings=6, axis="Y")
    ellipsoid(tho, (0, -3.6, 2.9), (1.85, 1.1, 1.5), seg=10, rings=6, axis="Y")  # prothorax
    ellipsoid(tho, (0, -5.0, 2.7), (1.4, 1.0, 1.15), seg=8, rings=6)  # head
    gold = m.piece("Crown", "Gold", "Metal")
    hc = Vector((0, -5.0, 2.7))
    band(gold, 1.0, 1.24, -0.18, 0.18, seg=8, loc=hc + Vector((0, 0.2, 0.75)), sy=0.85)
    for i in range(5):
        a = math.radians(-64 + i * 32)
        b = hc + Vector((math.sin(a) * 1.12, 0.2 - math.cos(a) * 1.12 * 0.85, 0.85))
        tube(gold, [b, b + Vector((math.sin(a) * 0.3, 0.1, 1.3 - abs(i - 2) * 0.3))], [0.26, 0.0], seg=4)
        if i % 2 == 0:
            gem(gold, tuple(b + Vector((0, -0.05, 0.0))), 0.16)
    ellipsoid(gold, tc, (2.36, 1.66, 1.91), seg=10, rings=6, axis="Y",
              keep=[((0, -1.3, 0), (0, 1, 0)), ((0, -0.9, 0), (0, -1, 0)), ((0, 0, 2.6), (0, 0, 1))])
    jaw = m.piece("Mandibles", "Dark", anim="Jaw", pivot=(0, -5.7, 2.3))
    for s in (-1, 1):
        tube(jaw, X(s, [(0.55, -5.75, 2.2), (0.9, -6.65, 2.0), (0.3, -7.2, 1.85)]), [0.34, 0.25, 0.0], seg=5)
    eyes = m.piece("Eyes", "Eye", "Neon")
    for s in (-1, 1):
        gem(eyes, (s * 0.85, -5.78, 2.95), 0.2, scale=(0.9, 1, 1.2))
    ant = m.piece("Antennae", "Dark", anim="Wiggle", pivot=(0, -5.6, 3.2))
    for s in (-1, 1):
        tube(ant, X(s, [(0.45, -5.7, 3.25), (1.1, -6.5, 4.0), (1.7, -6.9, 4.2), (2.1, -7.0, 3.9)]),
             [0.1, 0.08, 0.06, 0.0], seg=4)
    # ten small legs: four under the thorax, six little stubs along the sac's front
    for s, name, anim in ((1, "LegsL", "SwingA"), (-1, "LegsR", "SwingB")):
        legs = m.piece(name, "Dark", anim=anim, pivot=(s * 1.5, -2.5, 1.5))
        for y, dk in ((-3.8, -0.8), (-2.8, -0.35), (-1.8, 0.15), (-0.8, 0.55), (0.5, 0.9)):
            tube(legs, X(s, [(1.5, y, 1.6), (2.9, y + dk * 0.4, 2.3), (3.3, y + dk, 0.0)]), [0.22, 0.16, 0.0], seg=4)
