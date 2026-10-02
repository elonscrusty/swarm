"""SWARM art style for Blender models: the shared palette and modelling rules.

Colours come from art/palette.json (the same file the game uses through
src/shared/Palette.lua), so a model's slot colours match the UI and the world.

    from style import P
    m.extra["palette"] = {"Metal": P("steel_400"), "Accent": P("crimson_500")}

Rules (see docs/ART_DIRECTION.md for the full brief):
  * Chunky, readable silhouettes; faceted (flat shaded) low-poly; bevelled blocks.
  * Big confident shapes first, few small details; no noisy greebles.
  * Colour by slot; materials SmoothPlastic by default, Metal for armour/blades,
    Neon only for small glowing bits (eyes, gems, flames, magic cores).
"""

import json
import os

_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
with open(os.path.join(_ROOT, "art", "palette.json")) as _f:
    HEX = {k: v for k, v in json.load(_f).items() if not k.startswith("_")}


def P(name):
    """Palette colour as an sRGB 0-1 tuple, e.g. P("moss_500")."""
    h = HEX[name].lstrip("#")
    return tuple(int(h[i:i + 2], 16) / 255 for i in (0, 2, 4))


def mix(a, b, t):
    """Blend two palette colours (names or tuples), t = 0..1 toward b."""
    a = P(a) if isinstance(a, str) else a
    b = P(b) if isinstance(b, str) else b
    return tuple(a[i] + (b[i] - a[i]) * t for i in range(3))
