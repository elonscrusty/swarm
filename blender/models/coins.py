"""Gold pickups: the coins that pop out of enemies when a kill pays gold (client-side visual).

Both stand on the ground (origin = ground centre). Slots:
  Gold  coin bodies (chunky 12-sided coins with a raised rim and a sunk field)
  Trim  the embossed crowns (a lighter gold so the crown catches the eye)

GoldCoin stands on its edge, face toward -Y (Roblox -Z); the client spins it around the
vertical axis, so the crown flashes at the camera every half turn. GoldPile is a small
stack of four coins with one leaning on it (big gold amounts).
"""

import math

from swarmkit import register
from style import P

from ._propkit import loft, ring


def coin_rings(r, h, z0=0.0, simple=False):
    """Rings of a chunky coin around +Z, centred at z0: sunk field, raised rim, faceted edge.
    simple: just the chamfered edge (coins under others in a pile, fewer triangles)."""
    hh = h / 2
    if simple:
        prof = [(0.92, -hh), (1.0, -hh + 0.04), (1.0, hh - 0.04), (0.92, hh)]
        return [ring(12, r * k, z0 + z, phase=math.pi / 12) for k, z in prof]
    prof = [
        (0.74, -hh + 0.035), (0.8, -hh), (0.93, -hh), (1.0, -hh + 0.04),
        (1.0, hh - 0.04), (0.93, hh), (0.8, hh), (0.74, hh - 0.035),
    ]
    return [ring(12, r * k, z0 + z, phase=math.pi / 12) for k, z in prof]


CROWN = [(-0.26, -0.16), (0.26, -0.16), (0.26, 0.02), (0.31, 0.21), (0.13, 0.07), (0.0, 0.25),
         (-0.13, 0.07), (-0.31, 0.21), (-0.26, 0.02)]


def crown_profile(s):
    return [(x * s, z * s) for x, z in CROWN]


def upright_coin(body, crown, r, h, loc=(0, 0, 0), rot_z=0.0, lean=0.0):
    """A coin standing on its edge (faces along Y) with a crown on both faces."""
    rot = (90 + lean, 0, rot_z)
    loft(body, coin_rings(r, h), loc=loc, rot=rot)
    s = r / 0.5
    depth = 0.05
    for side in (-1, 1):
        # the crown sits on the sunk field and stands just proud of the rim
        off = side * (h / 2 - 0.035 + depth / 2)
        crown.prism(crown_profile(s * 0.95), depth, loc=_rot_offset(loc, (0, off, 0), rot), rot=rot_with(rot))


def _rot_offset(loc, off, rot):
    """loc + off rotated by the coin's extra rotation (rot minus the 90 deg that stands it up)."""
    from mathutils import Euler, Vector
    e = Euler([math.radians(rot[0] - 90), math.radians(rot[1]), math.radians(rot[2])], "XYZ")
    v = e.to_matrix() @ Vector(off)
    return (loc[0] + v.x, loc[1] + v.y, loc[2] + v.z)


def rot_with(rot):
    # prism profiles live in XZ with thickness along Y: same frame as the upright coin
    return (rot[0] - 90, rot[1], rot[2])


def flat_coin(body, r, h, loc, rot_z=0.0, simple=False):
    loft(body, coin_rings(r, h, simple=simple), loc=loc, rot=(0, 0, rot_z))


@register("GoldCoin", "Pickups", "Gold coin: one chunky faceted coin ~1.0 across x 0.22 thick, standing on its edge "
          "(face toward -Y), a raised rim and an embossed crown on both faces. Spun by the client.")
def gold_coin(m):
    m.extra["palette"] = {"Gold": P("gold_500"), "Trim": P("gold_200")}
    body = m.piece("Coin", "Gold")
    crown = m.piece("Crown", "Trim")
    upright_coin(body, crown, 0.5, 0.22, loc=(0, 0, 0.5))


@register("GoldPile", "Pickups", "Small pile of gold: four coins stacked a little askew with a fifth leaning on them, "
          "~1.5 x 1.2 x 1.0; crowns on the top coin and the leaning one.")
def gold_pile(m):
    m.extra["palette"] = {"Gold": P("gold_500"), "Trim": P("gold_200")}
    body = m.piece("Coins", "Gold")
    crown = m.piece("Crowns", "Trim")
    h = 0.16
    stack = [(0.0, 0.0, 0), (0.05, -0.04, 17), (-0.04, 0.03, 31), (0.03, 0.05, 8)]
    for i, (x, y, rz) in enumerate(stack):
        flat_coin(body, 0.42, h, (x - 0.2, y + 0.05, h / 2 + i * (h - 0.01)), rot_z=rz, simple=i < 3)
    # the top coin's crown, flat on its field
    top_z = h / 2 + 3 * (h - 0.01) + h / 2 - 0.035 + 0.025
    crown.prism(crown_profile(0.78), 0.05, loc=(-0.17, 0.1, top_z), rot=(90, 0, 8))
    # one coin on the floor and one leaning against the stack
    flat_coin(body, 0.4, h, (0.3, -0.42, h / 2), rot_z=40, simple=True)
    upright_coin(body, crown, 0.44, 0.18, loc=(0.5, 0.2, 0.46), rot_z=-12, lean=-22)
