"""Snow biome kit: snowy pines, rocks and bushes, ice crystals, drifts, a frozen pond, a snowy
ruin wall, a carved shrine totem landmark and stone lamps.

Same conventions as world.py: origin = ground centre, front = -Y (Roblox -Z), colours from the
shared palette (snow_* whites, ice_* blues; cool stone and dark pine greens for contrast on the
pale ground). Extras: collider on deliberate obstacles only, light at glow cores. Frozen_Pond is a
walkable flat hazard visual: the game owns the slippery radius.
"""

import math
import random

from swarmkit import register
from style import P, mix

from ._biomekit import blob, block_wall, flat_patch, pad, rock_points, shard, strand
from ._propkit import TAU, blob_points, cap_of, hull, light_at, loft, prism_xz, ring
from .world import trunk

SNOW = P("snow_100")


# ------------------------------------------------------------------ pines

def snowy_tier(needles, snow, z, r, h, seed, n=10, droop=0.38, star=0.17, cover=0.42):
    """Pine skirt with a snow blanket over its upper part (cover = share of the slope covered)."""
    rng = random.Random(seed)
    phase = rng.uniform(0, TAU)
    rim = ring(n, r, z, phase=phase, star=star, wobble=0.06, seed=seed,
               zfn=lambda a, i: -droop if i % 2 == 0 else droop * 0.25)
    mid = ring(n, r * 0.6, z + h * 0.38, phase=phase, star=star * 0.45, wobble=0.05, seed=seed + 1)
    apex = (rng.uniform(-0.06, 0.06) * r, rng.uniform(-0.06, 0.06) * r, z + h)
    loft(needles, [apex, mid, rim, (0.0, 0.0, z + h * 0.16)])
    t = 1 - cover
    low = []
    for (rx, ry, rz), (mx, my, mz) in zip(rim, mid):
        low.append((rx + (mx - rx) * t, ry + (my - ry) * t, rz + (mz - rz) * t + 0.14))
    mid_s = [(x * 1.04, y * 1.04, zz + 0.12) for x, y, zz in mid]
    top = (apex[0], apex[1], apex[2] + 0.1)
    loft(snow, [top, mid_s, low, (0.0, 0.0, z + h * 0.3)])


def build_snow_pine(m, rims, radii, heights, seed, trunk_r=0.62):
    m.extra["palette"] = {"Bark": P("wood_700"), "Needles": P("moss_900"), "Needles2": P("moss_800"), "Snow": SNOW}
    t = m.piece("Trunk", "Bark", shadow=True)
    trunk(t, rims[-1], trunk_r, trunk_r * 0.35, seed, sides=7, lean=(0.15, -0.1), flare=0.35, roots=4, root_len=0.9)
    dark = m.piece("Needles", "Needles", shadow=True)
    light = m.piece("Needles2", "Needles2", shadow=True)
    snow = m.piece("Snow", "Snow", shadow=True)
    for k, (z, r, h) in enumerate(zip(rims, radii, heights)):
        snowy_tier(dark if k % 2 == 0 else light, snow, z, r, h, seed * 10 + k, cover=0.42 + 0.06 * k / len(rims))


@register("Snow_Pine", "Snow", "Snow-laden pine, ~16 tall, canopy radius ~4.5: dark needles under snow blankets. "
          "Collider = trunk.")
def snow_pine(m):
    m.extra["collider"] = {"kind": "circle", "radius": 0.9, "height": 8}
    build_snow_pine(m, rims=[3.4, 6.0, 8.4, 10.6, 12.6], radii=[4.5, 3.8, 3.1, 2.3, 1.5],
                    heights=[4.2, 3.8, 3.4, 3.0, 3.4], seed=611)


@register("Snow_PineTall", "Snow", "Tall snowy pine for the tree line, ~22 tall. Collider = trunk.")
def snow_pine_tall(m):
    m.extra["collider"] = {"kind": "circle", "radius": 1.0, "height": 8}
    build_snow_pine(m, rims=[4.4, 7.4, 10.2, 12.8, 15.2, 17.4], radii=[4.6, 4.0, 3.4, 2.75, 2.05, 1.35],
                    heights=[4.6, 4.2, 3.9, 3.6, 3.3, 4.6], seed=623, trunk_r=0.7)


# ------------------------------------------------------------------ rocks, ice, drifts

@register("Snow_Rock", "Snow", "Cool grey boulder with a snow blanket, ~4.6 x 3. Collider circle.")
def snow_rock(m):
    m.extra["palette"] = {"Stone": P("stone_500"), "Stone2": P("stone_600"), "Snow": SNOW}
    m.extra["collider"] = {"kind": "circle", "radius": 2.0, "height": 3}
    main = rock_points(631, 18, 2.15, 1.7, 1.5, -0.25, 0.1, 1.2, floor=-1.32)
    hull(m.piece("Rock", "Stone", shadow=True), main)
    side = rock_points(632, 12, 1.05, 0.95, 0.8, 1.45, -0.55, 0.58, floor=-0.72)
    hull(m.piece("Rock2", "Stone2", shadow=True), side)
    snow = m.piece("Snow", "Snow")
    cap_of(snow, main, plane_co=(-0.4, 0.3, 1.85), plane_no=(-0.2, 0.25, 1.0), grow=1.03, lift=0.03, centre=(-0.25, 0.1, 1.2))
    cap_of(snow, side, plane_co=(1.45, -0.55, 1.05), plane_no=(0.0, 0.1, 1.0), grow=1.04, lift=0.03, centre=(1.45, -0.55, 0.6))


@register("Ice_Crystal", "Snow", "Cluster of pale ice crystals from a snowy rock, ~3 x 3.4, with a small frost glow. "
          "Collider circle; light = glow.")
def ice_crystal(m):
    m.extra["palette"] = {"Stone": P("stone_600"), "Snow": SNOW, "Ice": P("ice_300"), "Ice2": P("ice_100"),
                          "Glow": P("fx_holy")}
    m.extra["collider"] = {"kind": "circle", "radius": 1.3, "height": 3}
    m.extra["light"] = light_at(0.1, -0.3, 0.8)
    base_pts = [(x, y, 0.25 + z) for x, y, z in blob_points(641, 16, 1.5, 1.3, 0.5, floor=-0.35)]
    hull(m.piece("Base", "Stone"), base_pts)
    cap_of(m.piece("Snow", "Snow"), base_pts, plane_co=(0, 0, 0.45), plane_no=(0, 0, 1), grow=1.06, lift=0.02,
           centre=(0, 0, 0.25))
    c1 = m.piece("Crystals", "Ice")
    c2 = m.piece("Crystals2", "Ice2")
    shard(c1, (0.0, 0.15, 0.2), 3.2, 0.42, (-5, 4), 10)
    shard(c2, (0.6, 0.35, 0.2), 2.2, 0.32, (-16, 24), 40)
    shard(c1, (-0.65, 0.3, 0.2), 2.0, 0.3, (-12, -26), 5)
    shard(c2, (-0.25, -0.6, 0.2), 1.5, 0.26, (26, -10), 25)
    shard(c1, (0.8, -0.5, 0.2), 1.2, 0.24, (22, 28), 15)
    shard(c2, (-0.95, -0.35, 0.15), 0.9, 0.2, (10, -40), 30)
    shard(m.piece("Glow", "Glow", "Neon"), (0.15, -0.3, 0.3), 0.75, 0.1, (18, 10), 0)


@register("Snow_Drift", "Snow", "Soft snow drift mound, ~5.4 x 3.6 x 1.1, wind crest on top. Decoration (no collider).")
def snow_drift(m):
    m.extra["palette"] = {"Snow": P("snow_200"), "Crest": SNOW}
    pts = [(x * (1 + 0.15 * (y > 0)), y, 0.0 + z) for x, y, z in blob_points(651, 22, 2.7, 1.8, 1.1, jitter=0.1, floor=0.0)]
    pts = [(x, y, max(0.0, z) * (0.75 if x < 0 else 1.0) - 0.05) for x, y, z in pts]
    hull(m.piece("Drift", "Snow"), pts)
    cap_of(m.piece("Crest", "Crest"), pts, plane_co=(0.4, 0.1, 0.72), plane_no=(0.3, 0.5, 1.0), grow=1.03, lift=0.02,
           centre=(0.4, 0.1, 0.4))
    hull(m.piece("Drift", "Snow"), [(-2.2 + x, -1.0 + y, z - 0.05) for x, y, z in
                                     blob_points(652, 12, 1.0, 0.75, 0.45, jitter=0.1, floor=0.0)])


@register("Frozen_Pond", "Snow", "Flat frozen pond ~10.4 x 9.2, 0.3 tall: snow bank, pale ice with a deeper centre "
          "and glint streaks, a few rocks. Slippery hazard visual (hazard radius ~4.4). Walkable decoration.")
def frozen_pond(m):
    m.extra["palette"] = {"Bank": P("snow_200"), "Ice": P("ice_300"), "Deep": mix("ice_500", "ice_300", 0.35),
                          "Glint": P("ice_100"), "Stone": P("stone_500"), "Snow": SNOW}
    bank = m.piece("Bank", "Bank")
    flat_patch(bank, 0, 0, 5.2, 4.6, -0.04, 0.12, 661, n=16, wobble=0.08, top_scale=0.97)
    ice = m.piece("Ice", "Ice")
    flat_patch(ice, 0.1, 0.0, 4.55, 3.95, 0.0, 0.17, 662, n=15, wobble=0.09, top_scale=0.99)
    deep = m.piece("Deep", "Deep")
    flat_patch(deep, 0.5, 0.4, 2.3, 1.8, 0.1, 0.185, 663, n=11, wobble=0.15)
    gl = m.piece("Glints", "Glint")
    rng = random.Random(664)
    for k in range(7):
        x, y = rng.uniform(-3.0, 3.0), rng.uniform(-2.6, 2.6)
        L = rng.uniform(0.8, 2.0)
        gl.box((L, 0.12, 0.03), loc=(x, y, 0.19), rot=(0, 0, 35 + rng.uniform(-12, 12)), bevel=0.0)
    for k in range(3):  # a hairline crack
        x0, y0 = -2.2 + k * 0.8, -1.4 + k * 0.5 + (k % 2) * 0.3
        gl.box((0.95, 0.07, 0.03), loc=(x0, y0, 0.195), rot=(0, 0, -20 + (k % 2) * 50), bevel=0.0)
    st = m.piece("Stones", "Stone")
    snow = m.piece("Snow", "Snow")
    for x, y, s, seed in ((-4.6, 1.8, 0.6, 665), (4.2, -2.4, 0.5, 666), (3.4, 3.2, 0.38, 667)):
        pts = rock_points(seed, 10, s * 1.2, s, s * 0.75, x, y, s * 0.4, floor=-s * 0.4)
        hull(st, pts)
        cap_of(snow, pts, plane_co=(x, y, s * 0.6), plane_no=(0, 0, 1), grow=1.08, lift=0.02, centre=(x, y, s * 0.4))
    for x, y, rx, seed in ((-3.2, -3.4, 0.9, 668), (4.6, 0.8, 0.7, 669), (-1.0, 4.1, 0.8, 670), (-4.7, -0.9, 0.7, 671),
                           (1.8, -4.1, 0.75, 672), (2.6, 3.9, 0.6, 673)):
        hull(snow, [(x + px, y + py, pz) for px, py, pz in blob_points(seed, 10, rx, rx * 0.7, 0.42, floor=0.0)])


@register("Snow_Bush", "Snow", "Low dark shrub under a snow blanket, 3 x 1.9. Decoration (no collider).")
def snow_bush(m):
    m.extra["palette"] = {"Leaves": P("moss_800"), "Leaves2": P("moss_700"), "Snow": SNOW}
    lo = m.piece("Leaves", "Leaves")
    hi = m.piece("Leaves2", "Leaves2")
    snow = m.piece("Snow", "Snow")
    for piece, c, r, seed in ((lo, (0.0, 0.0, 0.8), (1.2, 1.0, 0.9), 671), (lo, (0.95, 0.3, 0.6), (0.8, 0.72, 0.68), 672),
                              (hi, (-0.95, -0.2, 0.55), (0.75, 0.7, 0.62), 673), (hi, (0.25, -0.15, 1.3), (0.7, 0.6, 0.5), 674)):
        pts = blob(piece, c, r, seed, n=14, floor=-r[2] * 0.95)
        cap_of(snow, pts, plane_co=(c[0], c[1], c[2] + r[2] * 0.55), plane_no=(0.1, -0.1, 1), grow=1.03, lift=0.02,
               centre=c)


# ------------------------------------------------------------------ ruins, landmark, lamp

@register("Snow_Ruin_Wall", "Snow", "Broken stone wall under snow with icicles, 8 x 3.6 x 1.4 (length along X). "
          "Collider box.")
def snow_ruin_wall(m):
    m.extra["palette"] = {"Stone": P("stone_500"), "Stone2": P("stone_400"), "Stone3": P("stone_600"), "Snow": SNOW,
                          "Ice": P("ice_100")}
    m.extra["collider"] = {"kind": "box", "size": [8.0, 1.4], "height": 3.5}
    tones = [m.piece("Stone", "Stone", shadow=True), m.piece("Stone2", "Stone2", shadow=True),
             m.piece("Stone3", "Stone3", shadow=True)]
    snow = m.piece("Snow", "Snow")

    def standing(x):
        return 4 if x < -2.1 else 3 if x < 0.9 else 2 if x < 2.6 else 1
    tops = block_wall(m, tones, snow, 8.0, 1.4, [0.95, 0.9, 0.85, 0.8], standing, seed=681, cap_chance=1.0, cap_thick=0.24,
                      fallen=[((3.15, -1.15, 0.3), (1.1, 0.8, 0.62), (6, -8, 28)), ((1.9, 1.15, 0.24), (0.85, 0.7, 0.5), (0, 10, -16))])
    ice = m.piece("Icicles", "Ice")
    rng = random.Random(682)
    for x0, x1, d, shift, z in tops:
        for k in range(rng.randint(1, 3)):
            x = rng.uniform(x0 + 0.2, x1 - 0.2)
            strand(ice, (x, shift - d / 2 - 0.02, z - 0.02), rng.uniform(0.35, 0.75), 0.09, int(x * 100), sway=0.0, n=2)
    pad(snow, 2.6, 3.7, -1.6, -0.7, 0.58, 683, thick=0.14, inset=0.1)
    for x, y, rx, seed in ((-3.6, -1.2, 1.0, 684), (0.6, 1.3, 0.9, 685)):
        hull(snow, [(x + px, y + py, pz) for px, py, pz in blob_points(seed, 10, rx, rx * 0.6, 0.38, floor=0.0)])


@register("Snow_Shrine_Totem", "Snow", "Landmark carved totem ~7.6 tall on a snowy stone plinth: stacked carved wood "
          "segments with slate-blue paint, spread wings (T silhouette from above), ivory antlers, a gold sun disc and "
          "a small frost gem; slate prayer cloths. Front = -Y. Collider circle; light = gem.")
def snow_shrine_totem(m):
    m.extra["palette"] = {"Base": P("stone_600"), "Stone": P("stone_500"), "Wood": P("wood_600"), "Wood2": P("wood_500"),
                          "Paint": P("slate_500"), "Dark": P("slate_900"), "Horn": P("ivory_200"), "Gold": P("gold_500"),
                          "Glow": P("fx_holy"), "Cloth": P("slate_600"), "Snow": SNOW}
    m.extra["collider"] = {"kind": "circle", "radius": 1.7, "height": 7}
    m.extra["light"] = light_at(0, -0.7, 4.35)
    base = m.piece("Plinth", "Base", shadow=True)
    loft(base, [ring(8, 1.85, -0.05, phase=TAU / 16), ring(8, 1.85, 0.4, phase=TAU / 16), ring(8, 1.6, 0.5, phase=TAU / 16)])
    stone = m.piece("Stone", "Stone", shadow=True)
    loft(stone, [ring(8, 1.3, 0.48, phase=TAU / 16), ring(8, 1.3, 0.85, phase=TAU / 16), ring(8, 1.1, 0.95, phase=TAU / 16)])
    w1 = m.piece("Wood", "Wood", shadow=True)
    w2 = m.piece("Wood2", "Wood2", shadow=True)
    paint = m.piece("Paint", "Paint")
    dark = m.piece("Dark", "Dark")
    # segment 1: banded base log
    loft(w1, [ring(8, 0.72, 0.9), ring(8, 0.7, 2.3), ring(8, 0.62, 2.4)])
    for z in (1.25, 1.95):
        loft(paint, [ring(8, 0.74, z - 0.08), ring(8, 0.74, z + 0.08)])
    # segment 2: face with brows, dark eyes and a beak
    w2.box((1.35, 1.2, 1.55), loc=(0, 0, 3.12), bevel=0.12, taper=(1.05, 1.05))
    w1.box((1.5, 0.35, 0.28), loc=(0, -0.58, 3.55), bevel=0.06)
    for x in (-0.33, 0.33):
        dark.box((0.3, 0.1, 0.18), loc=(x, -0.62, 3.32), bevel=0.0)
    loft(paint, [ring(3, 0.2, 2.95, phase=math.radians(90), cy=-0.6, sy=0.6), (0, -1.05, 2.75)])
    for x in (-0.55, 0.55):
        paint.box((0.12, 0.08, 0.7), loc=(x, -0.62, 2.85), bevel=0.0)
    # segment 3: spread wings
    w1.box((1.15, 1.05, 0.9), loc=(0, 0, 4.35), bevel=0.1)
    for sx in (-1, 1):
        prof = [(0.4, 4.0), (2.3, 4.55), (2.55, 5.05), (1.9, 4.85), (1.6, 5.05), (1.2, 4.8), (0.4, 4.8)]
        prism_xz(w2, [(sx * x, z) for x, z in prof][::(1 if sx > 0 else -1)], -0.22, 0.22)
        paint.box((1.2, 0.48, 0.1), loc=(sx * 1.3, 0, 4.42), rot=(0, sx * -16, 0), bevel=0.0)
    gold = m.piece("Gold", "Gold")
    prism_xz(gold, [(math.cos(i / 10 * TAU) * 0.42, 4.35 + math.sin(i / 10 * TAU) * 0.42) for i in range(10)], -0.6, -0.5)
    glow = m.piece("Glow", "Glow", "Neon")
    prism_xz(glow, [(0, 4.55), (0.16, 4.35), (0, 4.15), (-0.16, 4.35)], -0.68, -0.58)
    # segment 4: head with antlers
    w2.box((0.95, 0.9, 0.85), loc=(0, 0, 5.25), bevel=0.1, taper=(0.85, 0.85))
    for x in (-0.22, 0.22):
        dark.box((0.18, 0.08, 0.12), loc=(x, -0.43, 5.3), bevel=0.0)
    horn = m.piece("Antlers", "Horn")
    for sx in (-1, 1):
        pts = [(sx * 0.35, 0, 5.55), (sx * 0.85, 0.05, 6.1), (sx * 1.0, 0.1, 6.8), (sx * 0.85, 0.15, 7.5)]
        for (a, b), (r0, r1) in zip(zip(pts, pts[1:]), ((0.14, 0.11), (0.11, 0.08), (0.08, 0.03))):
            horn.limb(a, b, r0, r1, seg=5)
        horn.limb((sx * 0.85, 0.05, 6.1), (sx * 1.45, -0.05, 6.55), 0.08, 0.03, seg=4)
        horn.limb((sx * 0.98, 0.1, 6.7), (sx * 0.5, 0.0, 7.15), 0.07, 0.02, seg=4)
    # prayer cloths hanging from the wings
    cloth = m.piece("Cloth", "Cloth")
    for sx in (-1, 1):
        for k, (x, L) in enumerate(((1.0, 1.3), (1.6, 1.05), (2.1, 0.8))):
            cloth.box((0.28, 0.05, L), loc=(sx * x, -0.25, 4.55 - L / 2 - 0.05 * k), rot=(0, sx * 4, 0), bevel=0.0)
    snow = m.piece("Snow", "Snow")
    for sx in (-1, 1):
        pad(snow, sx * 2.35 - 0.3 if sx > 0 else -2.35 - 0.1, sx * 2.35 + 0.1 if sx > 0 else -2.35 + 0.3, -0.22, 0.22, 5.0,
            690 + sx, thick=0.1, inset=0.04, jit=0.04)
        pad(snow, (0.45 if sx > 0 else -1.25), (1.25 if sx > 0 else -0.45), -0.24, 0.24, 4.8, 692 + sx, thick=0.12,
            inset=0.06, jit=0.04)
    pad(snow, -0.4, 0.4, -0.38, 0.38, 5.66, 694, thick=0.14, inset=0.05, jit=0.04)
    pad(snow, -0.62, 0.62, -0.55, 0.55, 3.88, 695, thick=0.12, inset=0.06, jit=0.04)
    for k in range(5):
        a = k / 5 * TAU + 0.3
        x, y = math.cos(a) * 1.45, math.sin(a) * 1.45
        hull(snow, [(x + px, y + py, 0.4 + pz) for px, py, pz in blob_points(696 + k, 8, 0.45, 0.35, 0.16, floor=0.0)])


@register("Snow_Lamp", "Snow", "Stone lantern ~4.2 tall: square post, lamp house with warm glowing windows, pyramid "
          "roof under snow. Collider circle; light = lamp.")
def snow_lamp(m):
    m.extra["palette"] = {"Stone": P("stone_500"), "Stone2": P("stone_400"), "Glow": P("gold_300"), "Snow": SNOW,
                          "Dark": P("stone_800")}
    m.extra["collider"] = {"kind": "circle", "radius": 0.7, "height": 4.2}
    m.extra["light"] = light_at(0, 0, 2.85)
    st = m.piece("Stone", "Stone", shadow=True)
    st2 = m.piece("Stone2", "Stone2", shadow=True)
    st.box((1.3, 1.3, 0.35), loc=(0, 0, 0.12), bevel=0.07)
    st2.box((0.62, 0.62, 1.9), loc=(0, 0, 1.25), bevel=0.06, taper=(0.9, 0.9))
    st.box((1.15, 1.15, 0.22), loc=(0, 0, 2.25), bevel=0.05)
    for sx in (-1, 1):
        for sy in (-1, 1):
            st2.box((0.2, 0.2, 0.75), loc=(sx * 0.42, sy * 0.42, 2.72), bevel=0.03)
    dark = m.piece("Dark", "Dark")
    dark.box((0.66, 0.66, 0.66), loc=(0, 0, 2.72), bevel=0.0)
    glow = m.piece("Glow", "Glow", "Neon")
    glow.box((0.5, 0.74, 0.5), loc=(0, 0, 2.72), bevel=0.0)
    glow.box((0.74, 0.5, 0.5), loc=(0, 0, 2.72), bevel=0.0)
    loft(st, [ring(4, 1.0, 3.08, phase=TAU / 8), ring(4, 1.05, 3.2, phase=TAU / 8), (0, 0, 3.95)])
    st2.box((0.2, 0.2, 0.32), loc=(0, 0, 4.0), bevel=0.04, taper=(0.5, 0.5))
    snow = m.piece("Snow", "Snow")
    loft(snow, [ring(4, 0.8, 3.38, phase=TAU / 8), ring(4, 0.42, 3.72, phase=TAU / 8), (0, 0, 4.02)])
    pad(snow, -0.62, 0.62, -0.62, 0.62, 0.28, 699, thick=0.1, inset=0.08, jit=0.05)
