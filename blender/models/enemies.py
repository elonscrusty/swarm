"""Alien insect swarm: six enemy types and the Scorpion Queen boss.

Enemy ids stay as in EnemyData (Slime, Bat, Skeleton, Ghost, Brute, Bomber, Boss); only
their looks change. Every model stands on the ground at z = 0, faces -Y, and roughly
fills its EnemyData Size so hit radii stay honest.
"""

import math

from swarmkit import register

S = math.sin
C = math.cos


def rgb(h):
    return tuple(int(h[i:i + 2], 16) / 255 for i in (0, 2, 4))


def legs(model, side, anim, attach, length, thickness, count=3, spread=0.9, height=0.0, name="Legs"):
    """`count` jointed insect legs on one side. attach = (x_offset, y_centre, z)."""
    p = model.piece(f"{name}{'L' if side < 0 else 'R'}", "Dark", anim=anim,
                    pivot=(side * attach[0], attach[1], attach[2]))
    for i in range(count):
        y = attach[1] + (i - (count - 1) / 2) * spread
        hip = (side * attach[0], y, attach[2])
        knee = (side * (attach[0] + length * 0.55), y + (i - 1) * 0.15, attach[2] + length * 0.35 + height)
        foot = (side * (attach[0] + length * 0.85), y + (i - 1) * 0.35, 0.05)
        p.chain([hip, knee, foot], [thickness, thickness * 0.8, thickness * 0.35], seg=5)
    return p


# ------------------------------------------------------------------ MITE (Slime id)

@register("Mite", "Enemies", "Slime id. Small scuttling alien mite.")
def mite(m):
    m.extra["palette"] = {"Base": rgb("4fd16a"), "Dark": rgb("1d5a33"), "Eye": rgb("eaff5a"), "Light": rgb("a8f5b5")}
    body = m.piece("Body", "Base")
    body.ico(1.05, loc=(0, 0.45, 0.95), scale=(1.15, 1.25, 0.85), subdiv=1)  # abdomen
    body.ico(0.7, loc=(0, -0.55, 0.85), scale=(1.1, 1.0, 0.9), subdiv=1)  # head/thorax
    shell = m.piece("Shell", "Dark")
    # overlapping armour plates down the back, widest in the middle
    for i, (y, w, z, tilt) in enumerate([(-0.5, 1.25, 1.42, -25), (0.05, 1.75, 1.72, -5), (0.6, 1.65, 1.62, 15), (1.05, 1.2, 1.3, 35)]):
        shell.box((w, 0.62, 0.22), loc=(0, y, z), rot=(tilt, 0, 0), taper=(0.75, 0.9), bevel=0.08)
    shell.spike(0.12, 0.45, seg=4, base=(-0.45, 0.1, 1.8), direction=(-0.3, 0.2, 1))
    shell.spike(0.12, 0.45, seg=4, base=(0.45, 0.1, 1.8), direction=(0.3, 0.2, 1))
    eyes = m.piece("Eyes", "Eye", "Neon")
    for x in (-0.32, 0.32):
        eyes.ico(0.17, loc=(x, -1.12, 1.0), subdiv=1)
    jaws = m.piece("Jaws", "Light", anim="Jaw", pivot=(0, -1.0, 0.7))
    for x in (-0.22, 0.22):
        jaws.limb((x, -1.05, 0.72), (x * 0.4, -1.55, 0.55), 0.1, 0.02, seg=4)
    legs(m, -1, "SwingA", (0.75, 0.05, 0.75), 0.75, 0.14, spread=0.5)
    legs(m, 1, "SwingB", (0.75, 0.05, 0.75), 0.75, 0.14, spread=0.5)


# ------------------------------------------------------------------ WASP (Bat id)

@register("Wasp", "Enemies", "Bat id. Fast flying alien wasp (model floats; the game adds fly height).")
def wasp(m):
    m.extra["palette"] = {"Base": rgb("ffcc2e"), "Dark": rgb("1e1a24"), "Eye": rgb("ff3b30"), "Light": rgb("cfe9ff")}
    body = m.piece("Body", "Base")
    body.ico(0.45, loc=(0, -0.2, 0.55), scale=(1, 1.1, 0.95), subdiv=1)  # thorax
    body.ico(0.55, loc=(0, 0.75, 0.45), scale=(0.9, 1.4, 0.85), subdiv=1)  # abdomen
    stripes = m.piece("Stripes", "Dark")
    for i, y in enumerate((0.45, 0.8, 1.12)):
        stripes.cyl(0.52 - i * 0.08, 0.52 - i * 0.08, 0.14, seg=8, loc=(0, y, 0.45), rot=(90, 0, 0))
    stripes.spike(0.12, 0.45, seg=4, base=(0, 1.45, 0.42), direction=(0, 1, -0.2))
    stripes.ico(0.32, loc=(0, -0.75, 0.6), subdiv=1)  # head
    eyes = m.piece("Eyes", "Eye", "Neon")
    for x in (-0.2, 0.2):
        eyes.ico(0.16, loc=(x, -0.95, 0.68), scale=(1, 0.7, 1.2), subdiv=1)
    ant = m.piece("Antennae", "Dark", anim="Wiggle", pivot=(0, -0.9, 0.8))
    for x in (-0.1, 0.1):
        ant.chain([(x, -0.9, 0.82), (x * 3, -1.2, 1.15), (x * 4, -1.45, 1.2)], [0.04, 0.03, 0.02], seg=4)
    for side in (-1, 1):
        w = m.piece(f"Wing{'L' if side < 0 else 'R'}", "Light", "Glass",
                    anim="FlapL" if side < 0 else "FlapR", pivot=(side * 0.3, -0.15, 0.85))
        prof = [(0.0, 0.0), (1.4, 0.35), (1.6, 0.15), (1.1, -0.2), (0.0, -0.1)]
        w.prism([(side * x, z) for x, z in prof] if side > 0 else [(side * x, z) for x, z in reversed(prof)],
                0.04, loc=(side * 0.3, -0.15, 0.9), rot=(0, 0, 0))
    legs(m, -1, "SwingA", (0.3, -0.2, 0.4), 0.6, 0.05, spread=0.25)
    legs(m, 1, "SwingB", (0.3, -0.2, 0.4), 0.6, 0.05, spread=0.25)


# ------------------------------------------------------------------ BEETLE WARRIOR (Skeleton id)

@register("BeetleWarrior", "Enemies", "Skeleton id. Upright armoured beetle soldier with blade arms.")
def beetle_warrior(m):
    m.extra["palette"] = {"Base": rgb("3a6fe0"), "Dark": rgb("1a2550"), "Eye": rgb("7dfcff"), "Light": rgb("c8d6ff")}
    torso = m.piece("Torso", "Base")
    torso.box((1.5, 1.0, 1.4), loc=(0, 0, 2.55), taper=(0.85, 0.85), bevel=0.2)  # chest
    torso.ico(0.65, loc=(0, 0.05, 1.75), scale=(1.1, 0.9, 0.8), subdiv=1)  # waist
    torso.box((1.7, 1.1, 0.35), loc=(0, 0.05, 3.25), bevel=0.12)  # shoulder plate
    head = m.piece("Head", "Dark")
    head.box((0.85, 0.85, 0.7), loc=(0, -0.15, 3.75), taper=(0.75, 0.8), bevel=0.15)
    head.spike(0.14, 0.7, base=(-0.3, -0.2, 4.0), direction=(-0.5, -0.2, 1))
    head.spike(0.14, 0.7, base=(0.3, -0.2, 4.0), direction=(0.5, -0.2, 1))
    head.limb((0, -0.55, 3.6), (0, -0.9, 3.4), 0.12, 0.03, seg=4)  # snout
    eyes = m.piece("Eyes", "Eye", "Neon")
    for x in (-0.22, 0.22):
        eyes.box((0.22, 0.08, 0.12), loc=(x, -0.58, 3.82), bevel=0.02)
    for side in (-1, 1):
        sfx = "L" if side < 0 else "R"
        arm = m.piece(f"Arm{sfx}", "Dark", anim="SwingA" if side < 0 else "SwingB", pivot=(side * 0.95, 0, 3.1))
        arm.chain([(side * 0.95, 0, 3.1), (side * 1.2, -0.1, 2.3), (side * 1.15, -0.5, 1.7)], [0.2, 0.17, 0.14], seg=5)
        blade = m.piece(f"Blade{sfx}", "Light", "Metal", anim="SwingA" if side < 0 else "SwingB", pivot=(side * 0.95, 0, 3.1))
        blade.prism([(0, 0), (0.12, 0.0), (0.05, -1.3), (-0.02, -0.9)], 0.06,
                    loc=(side * 1.15, -0.55, 1.75), rot=(90, 0, 0))
        leg = m.piece(f"Leg{sfx}", "Dark", anim="SwingB" if side < 0 else "SwingA", pivot=(side * 0.4, 0.05, 1.5))
        leg.chain([(side * 0.4, 0.05, 1.5), (side * 0.55, -0.25, 0.8), (side * 0.5, 0.15, 0.1)], [0.22, 0.17, 0.14], seg=5)
        leg.box((0.4, 0.6, 0.18), loc=(side * 0.5, -0.05, 0.09), bevel=0.05)
    wings = m.piece("Elytra", "Base")
    for side in (-1, 1):
        wings.box((0.7, 0.3, 1.6), loc=(side * 0.38, 0.55, 2.3), rot=(8, 0, side * 6), taper=(0.7, 1.0), bevel=0.12)


# ------------------------------------------------------------------ PHASE MOTH (Ghost id)

@register("PhaseMoth", "Enemies", "Ghost id. Glowing moth that drifts through the swarm.")
def phase_moth(m):
    m.extra["palette"] = {"Base": rgb("b9a7ff"), "Dark": rgb("3c2f6e"), "Glow": rgb("7ef0ff"), "Light": rgb("f2eeff"), "Eye": rgb("ffffff")}
    body = m.piece("Body", "Light")
    body.ico(0.55, loc=(0, -0.3, 1.9), scale=(1, 1, 1), subdiv=1)  # fuzzy thorax
    body.ico(0.5, loc=(0, 0.45, 1.75), scale=(0.85, 1.5, 0.85), subdiv=1)  # abdomen
    body.ico(0.38, loc=(0, -0.9, 2.0), subdiv=1)  # head
    eyes = m.piece("Eyes", "Glow", "Neon")
    for x in (-0.2, 0.2):
        eyes.ico(0.15, loc=(x, -1.15, 2.08), subdiv=1)
    ant = m.piece("Antennae", "Dark", anim="Wiggle", pivot=(0, -1.0, 2.3))
    for x in (-1, 1):
        ant.chain([(x * 0.12, -1.05, 2.3), (x * 0.45, -1.45, 2.8), (x * 0.7, -1.6, 2.95)], [0.05, 0.04, 0.02], seg=4)
        ant.prism([(0, 0), (0.18, 0.1), (0.05, 0.35)], 0.03, loc=(x * 0.5, -1.5, 2.75))
    for side in (-1, 1):
        sfx = "L" if side < 0 else "R"
        anim = "FlapL" if side < 0 else "FlapR"
        piv = (side * 0.35, -0.2, 2.0)
        wing = m.piece(f"Wing{sfx}", "Base", anim=anim, pivot=piv)
        prof = [(0, 0.3), (1.0, 1.1), (1.9, 0.9), (1.7, 0.0), (1.2, -0.7), (0.4, -0.9), (0, -0.3)]
        pts = [(side * x, z) for x, z in prof]
        if side < 0:
            pts.reverse()
        wing.prism(pts, 0.06, loc=(side * 0.35, -0.2, 2.0))
        spots = m.piece(f"WingGlow{sfx}", "Glow", "Neon", anim=anim, pivot=piv)
        spots.cyl(0.32, 0.32, 0.08, seg=6, loc=(side * 1.45, -0.2, 2.5), rot=(90, 0, 0))
        spots.cyl(0.2, 0.2, 0.08, seg=6, loc=(side * 1.0, -0.2, 1.6), rot=(90, 0, 0))


# ------------------------------------------------------------------ RHINO BEETLE (Brute id)

@register("RhinoBeetle", "Enemies", "Brute id. Huge armoured beetle with a battering horn.")
def rhino(m):
    m.extra["palette"] = {"Base": rgb("8a3b22"), "Dark": rgb("2b1612"), "Light": rgb("e8d2a8"), "Eye": rgb("ffd23a")}
    shell = m.piece("Shell", "Base")
    # two wing cases meeting along the back, like a beetle's elytra
    for side in (-1, 1):
        shell.ico(1.35, loc=(side * 0.68, 0.7, 2.45), scale=(0.9, 1.6, 0.95), subdiv=2)
    shell.box((2.6, 1.3, 1.1), loc=(0, -0.9, 2.75), taper=(0.8, 0.9), bevel=0.3)  # pronotum
    belly = m.piece("Belly", "Dark")
    belly.ico(1.9, loc=(0, 0.3, 1.5), scale=(1.0, 1.1, 0.55), subdiv=1)
    belly.box((1.9, 1.3, 1.4), loc=(0, -1.75, 2.0), taper=(0.8, 0.8), bevel=0.25)  # head
    horn = m.piece("Horn", "Light", anim="Jaw", pivot=(0, -2.2, 2.2))
    horn.chain([(0, -2.2, 2.1), (0, -3.1, 2.4), (0, -3.6, 3.2), (0, -3.5, 4.2), (0, -3.1, 4.8)], [0.5, 0.42, 0.32, 0.18, 0.03], seg=6)
    horn.spike(0.25, 1.4, base=(0, -1.0, 3.2), direction=(0, -0.7, 1))
    eyes = m.piece("Eyes", "Eye", "Neon")
    for x in (-0.6, 0.6):
        eyes.ico(0.18, loc=(x, -2.38, 2.25), subdiv=1)
    legs(m, -1, "SwingA", (1.4, 0.4, 1.5), 1.5, 0.36, spread=1.2)
    legs(m, 1, "SwingB", (1.4, 0.4, 1.5), 1.5, 0.36, spread=1.2)


# ------------------------------------------------------------------ BOMBARDIER TICK (Bomber id)

@register("BombTick", "Enemies", "Bomber id. Tick with a glowing, swelling abdomen that explodes.")
def bomb_tick(m):
    m.extra["palette"] = {"Base": rgb("ff4a2e"), "Dark": rgb("2a1a1a"), "Glow": rgb("ffae2b"), "Eye": rgb("fff15a")}
    body = m.piece("Body", "Dark")
    body.ico(0.65, loc=(0, -0.65, 0.9), scale=(1.0, 0.9, 0.75), subdiv=1)
    body.box((1.2, 0.6, 0.3), loc=(0, -0.55, 1.35), bevel=0.1)
    sac = m.piece("Sac", "Glow", "Neon", anim="Pulse")
    sac.ico(1.0, loc=(0, 0.45, 1.15), scale=(1.0, 1.1, 0.95), subdiv=2)
    plates = m.piece("Plates", "Base")
    for i, y in enumerate((0.0, 0.45, 0.9)):
        plates.box((1.5 - i * 0.25, 0.22, 0.5), loc=(0, y, 2.0 - i * 0.12), rot=(-10 + i * 12, 0, 0), bevel=0.08)
    eyes = m.piece("Eyes", "Eye", "Neon")
    for x in (-0.22, 0.22):
        eyes.ico(0.12, loc=(x, -1.18, 1.0), subdiv=1)
    jaws = m.piece("Jaws", "Dark", anim="Jaw", pivot=(0, -1.1, 0.8))
    for x in (-0.18, 0.18):
        jaws.limb((x, -1.15, 0.8), (x * 0.3, -1.55, 0.65), 0.08, 0.02, seg=4)
    legs(m, -1, "SwingA", (0.55, -0.3, 0.75), 0.9, 0.09, count=4, spread=0.35)
    legs(m, 1, "SwingB", (0.55, -0.3, 0.75), 0.9, 0.09, count=4, spread=0.35)


# ------------------------------------------------------------------ SCORPION QUEEN (Boss id)

@register("ScorpionQueen", "Enemies", "Boss. Giant armoured scorpion with glowing seams, claws and a stinger tail.")
def scorpion_queen(m):
    m.extra["palette"] = {"Base": rgb("3d4250"), "Dark": rgb("1f2229"), "Glow": rgb("ff8a1e"), "Eye": rgb("ff2a2a"),
                          "Light": rgb("c98f5c"), "Gold": rgb("ffc23a")}
    body = m.piece("Body", "Base")
    for i, (y, w, h) in enumerate([(-2.6, 4.2, 2.4), (-0.9, 4.8, 2.6), (0.8, 4.6, 2.5), (2.4, 4.0, 2.2), (3.8, 3.2, 1.9)]):
        body.box((w, 1.6, h), loc=(0, y, 2.6 + h * 0.1), taper=(0.8, 0.85), bevel=0.35)
    seams = m.piece("Seams", "Glow", "Neon", anim="Pulse")
    for y in (-1.75, -0.05, 1.6, 3.1):
        seams.box((3.9, 0.18, 0.2), loc=(0, y, 3.95), bevel=0.04)
        seams.box((0.18, 0.18, 1.6), loc=(-2.1, y, 2.9), bevel=0.04)
        seams.box((0.18, 0.18, 1.6), loc=(2.1, y, 2.9), bevel=0.04)
    head = m.piece("Head", "Dark")
    head.box((3.4, 1.8, 1.9), loc=(0, -4.1, 2.5), taper=(0.75, 0.8), bevel=0.35)
    for x in (-1, 1):
        head.spike(0.25, 1.2, base=(x * 1.2, -4.0, 3.3), direction=(x * 0.4, -0.3, 1))
    eyes = m.piece("Eyes", "Eye", "Neon")
    for x in (-0.65, -0.25, 0.25, 0.65):
        eyes.box((0.32, 0.12, 0.22), loc=(x, -5.02, 2.85 - abs(x) * 0.3), bevel=0.04)
    jaw = m.piece("Mandibles", "Light", anim="Jaw", pivot=(0, -4.9, 1.9))
    for x in (-1, 1):
        jaw.chain([(x * 0.6, -4.9, 1.9), (x * 0.5, -5.6, 1.6), (x * 0.15, -6.0, 1.5)], [0.2, 0.14, 0.04], seg=4)
    for side in (-1, 1):
        sfx = "L" if side < 0 else "R"
        claw = m.piece(f"Claw{sfx}", "Light", anim="SwingA" if side < 0 else "SwingB", pivot=(side * 2.0, -3.6, 2.6))
        claw.chain([(side * 2.0, -3.6, 2.6), (side * 3.6, -5.0, 2.8), (side * 3.4, -6.8, 2.6)], [0.55, 0.5, 0.45], seg=6)
        claw.box((1.8, 2.4, 1.3), loc=(side * 3.3, -7.8, 2.6), taper=(0.7, 0.6), bevel=0.3)  # palm
        claw.prism([(0, 0), (0.5, 0), (0.15, -2.2)], 0.9, loc=(side * 3.6, -8.9, 2.6), rot=(90, 0, side * -10))
        claw.prism([(0, 0), (0.45, 0), (0.25, -1.8)], 0.8, loc=(side * 2.8, -8.8, 2.6), rot=(90, 0, side * 15))
        legs(m, side, "SwingA" if side < 0 else "SwingB", (2.2, 1.0, 2.2), 3.2, 0.32, count=4, spread=1.5, name="Legs")
    tail = m.piece("Tail", "Base", anim="Tail", pivot=(0, 4.6, 3.0))
    pts = [(0, 4.6, 3.0), (0, 6.2, 4.4), (0, 6.8, 6.4), (0, 6.2, 8.4), (0, 4.6, 9.6), (0, 2.8, 9.8)]
    rad = [1.1, 0.95, 0.85, 0.75, 0.65, 0.55]
    tail.chain(pts, rad, seg=6)
    sting = m.piece("Stinger", "Glow", "Neon", anim="Tail", pivot=(0, 4.6, 3.0))
    sting.ico(0.9, loc=(0, 2.4, 9.6), scale=(1, 1.2, 1), subdiv=1)
    sting.spike(0.45, 1.8, seg=5, base=(0, 1.8, 9.3), direction=(0, -0.8, -0.6))
