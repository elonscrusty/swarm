"""Low-poly world props: forest arena, ruins arena and the castle lobby."""

import math
import random

from swarmkit import register


def rgb(h):
    return tuple(int(h[i:i + 2], 16) / 255 for i in (0, 2, 4))


@register("Tree_Round", "World", "Big faceted broadleaf tree. Trunk is the collision obstacle.")
def tree_round(m):
    m.extra["palette"] = {"Wood": rgb("7a5232"), "Leaf": rgb("4fae4a"), "Leaf2": rgb("3c8f3f")}
    trunk = m.piece("Trunk", "Wood")
    trunk.cyl(1.3, 0.9, 7.0, seg=7, loc=(0, 0, 3.5))
    trunk.limb((0, 0, 5.0), (2.2, 0.5, 7.5), 0.45, 0.25, seg=5)
    trunk.limb((0, 0, 5.5), (-2.0, -0.6, 8.0), 0.45, 0.25, seg=5)
    leaves = m.piece("Leaves", "Leaf")
    leaves.ico(4.2, loc=(0, 0, 10.0), scale=(1.1, 1.05, 0.85), subdiv=1, jitter=0.12, seed=3)
    leaves.ico(2.8, loc=(3.0, 0.8, 8.4), subdiv=1, jitter=0.12, seed=4)
    leaves.ico(2.6, loc=(-2.8, -1.0, 8.6), subdiv=1, jitter=0.12, seed=5)
    dark = m.piece("Leaves2", "Leaf2")
    dark.ico(2.4, loc=(0.6, 1.8, 12.2), subdiv=1, jitter=0.12, seed=6)


@register("Tree_Pine", "World", "Tall faceted pine.")
def tree_pine(m):
    m.extra["palette"] = {"Wood": rgb("6b4a2c"), "Leaf": rgb("2f7d46")}
    trunk = m.piece("Trunk", "Wood")
    trunk.cyl(0.9, 0.6, 4.0, seg=6, loc=(0, 0, 2.0))
    leaves = m.piece("Leaves", "Leaf")
    for i, (r, z) in enumerate([(4.2, 5.0), (3.4, 7.6), (2.5, 10.0), (1.5, 12.0)]):
        leaves.cyl(r, 0.0, 4.2 - i * 0.5, seg=7, loc=(0, 0, z), rot=(0, 0, i * 20))


@register("Mushroom", "World", "Giant red spotted mushroom (decoration / obstacle).")
def mushroom(m):
    m.extra["palette"] = {"Light": rgb("f3ead8"), "Accent": rgb("e0362e"), "White": rgb("ffffff")}
    stem = m.piece("Stem", "Light")
    stem.cyl(0.9, 0.7, 4.0, seg=8, loc=(0, 0, 2.0))
    cap = m.piece("Cap", "Accent")
    cap.ico(3.0, loc=(0, 0, 4.6), scale=(1, 1, 0.55), subdiv=2)
    spots = m.piece("Spots", "White")
    rng = random.Random(7)
    for i in range(9):
        a = i / 9 * math.tau + rng.uniform(-0.2, 0.2)
        r = rng.uniform(1.0, 2.4)
        z = 4.6 + 1.65 * math.sqrt(max(0.0, 1 - (r / 3.0) ** 2))
        spots.cyl(0.38, 0.38, 0.12, seg=6, loc=(math.cos(a) * r, math.sin(a) * r, z),
                  rot=(math.degrees(-math.sin(a) * r / 3.0 * 0.9), math.degrees(math.cos(a) * r / 3.0 * 0.9), 0))


@register("Rock", "World", "Faceted boulder.")
def rock(m):
    m.extra["palette"] = {"Stone": rgb("8c8f99"), "Moss": rgb("5f9a4a")}
    r = m.piece("Rock", "Stone")
    r.ico(2.2, loc=(0, 0, 1.2), scale=(1.2, 1.0, 0.7), subdiv=1, jitter=0.18, seed=11)
    r.ico(1.2, loc=(1.6, 0.6, 0.6), subdiv=1, jitter=0.2, seed=12)
    moss = m.piece("Moss", "Moss")
    moss.ico(1.4, loc=(-0.3, -0.2, 2.15), scale=(1.2, 1.0, 0.25), subdiv=1, jitter=0.1, seed=13)


@register("Pillar", "World", "Broken stone pillar (ruins arena obstacle).")
def pillar(m):
    m.extra["palette"] = {"Stone": rgb("a7a49a"), "Dark": rgb("6e6b62"), "Moss": rgb("5f9a4a")}
    p = m.piece("Pillar", "Stone")
    p.box((3.2, 3.2, 0.8), loc=(0, 0, 0.4), bevel=0.15)
    p.cyl(1.2, 1.1, 7.0, seg=8, loc=(0, 0, 4.3))
    p.box((2.8, 2.8, 0.7), loc=(0.2, 0, 8.1), rot=(0, 6, 8), bevel=0.15)
    rubble = m.piece("Rubble", "Dark")
    for i, (x, y) in enumerate([(2.2, 1.0), (-1.8, 1.9), (1.4, -2.2)]):
        rubble.ico(0.6, loc=(x, y, 0.35), subdiv=1, jitter=0.2, seed=20 + i)
    moss = m.piece("Moss", "Moss")
    moss.box((3.25, 3.25, 0.25), loc=(0, 0, 0.82), bevel=0.05)


@register("Bush", "World", "Low-poly bush (decoration).")
def bush(m):
    m.extra["palette"] = {"Leaf": rgb("4fae4a"), "Accent": rgb("ff5a8a")}
    b = m.piece("Bush", "Leaf")
    b.ico(1.4, loc=(0, 0, 1.0), subdiv=1, jitter=0.15, seed=31)
    b.ico(1.0, loc=(1.2, 0.3, 0.75), subdiv=1, jitter=0.15, seed=32)
    b.ico(1.0, loc=(-1.1, -0.2, 0.7), subdiv=1, jitter=0.15, seed=33)
    berries = m.piece("Berries", "Accent")
    for x, y, z in [(0.5, -1.1, 1.4), (-0.6, -1.0, 1.1), (1.4, -0.6, 1.2)]:
        berries.ico(0.18, loc=(x, y, z), subdiv=0)


@register("Banner", "World", "Lobby castle banner on a pole.")
def banner(m):
    m.extra["palette"] = {"Wood": rgb("6b4a2c"), "Cloth": rgb("2d4fbf"), "Gold": rgb("f2c14e")}
    pole = m.piece("Pole", "Wood")
    pole.cyl(0.18, 0.18, 9.0, seg=6, loc=(0, 0, 4.5))
    pole.box((3.4, 0.25, 0.25), loc=(0, 0, 8.6), bevel=0.05)
    cloth = m.piece("Cloth", "Cloth", anim="Wiggle", pivot=(0, 0, 8.5))
    cloth.prism([(-1.5, 8.5), (1.5, 8.5), (1.5, 3.6), (0, 4.4), (-1.5, 3.6)], 0.1, loc=(0, -0.2, 0))
    emblem = m.piece("Emblem", "Gold", anim="Wiggle", pivot=(0, 0, 8.5))
    emblem.box((0.9, 0.12, 1.2), loc=(0, -0.28, 6.6), rot=(0, 45, 0), bevel=0.02)


@register("Torch", "World", "Wall/standing torch for the lobby and ruins.")
def torch(m):
    m.extra["palette"] = {"Metal": rgb("4a4e5a"), "Glow": rgb("ff9a2b"), "Wood": rgb("6b4a2c")}
    post = m.piece("Post", "Wood")
    post.cyl(0.25, 0.2, 4.0, seg=6, loc=(0, 0, 2.0))
    bowl = m.piece("Bowl", "Metal", "Metal")
    bowl.cyl(0.6, 0.35, 0.5, seg=6, loc=(0, 0, 4.2))
    flame = m.piece("Flame", "Glow", "Neon", anim="Flicker")
    flame.cyl(0.42, 0.0, 1.2, seg=5, loc=(0, 0, 5.0))


@register("CrystalCluster", "World", "Purple crystal cluster (ruins decoration).")
def crystal_cluster(m):
    m.extra["palette"] = {"Glow": rgb("b05bff"), "Stone": rgb("6e6b78")}
    base = m.piece("Base", "Stone")
    base.ico(1.4, loc=(0, 0, 0.4), scale=(1.2, 1.2, 0.45), subdiv=1, jitter=0.2, seed=41)
    c = m.piece("Crystals", "Glow", "Neon")
    for i, (x, y, h, tx, ty) in enumerate([(0, 0, 3.2, 0, 0), (0.8, 0.3, 2.2, 20, 10), (-0.7, 0.4, 2.0, -18, 12), (0.2, -0.8, 1.6, 8, -22)]):
        c.cyl(0.42, 0.0, h, seg=5, loc=(x, y, 0.6 + h / 2), rot=(ty, tx, i * 17))
