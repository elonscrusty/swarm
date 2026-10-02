"""Check that every small-art icon key wired in src/client/Icons.lua has a PNG under art/icons/,
that its drawn fallback exists, and that every art key written in src/ is known to Icons.

    python3 tools/check_icon_art.py     # exit 1 on any problem
"""

import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


def read(rel):
    with open(os.path.join(ROOT, rel), encoding="utf-8") as f:
        return f.read()


icons = read("src/client/Icons.lua")
iconData = read("src/shared/IconData.lua")
draw = set(re.findall(r"^DRAW\.(\w+)\s*=", icons, re.M))
images = set(re.findall(r"^\t(\w+) = \d+,", iconData, re.M))
pngs = {}
for d, _, fs in os.walk(os.path.join(ROOT, "art", "icons")):
    for f in fs:
        if f.endswith(".png"):
            pngs[f[:-4]] = d
folders = dict(re.findall(r'\b(\w+) = "(\w+)"', re.search(r"local ART_FOLDER = \{(.*?)\n\}", icons, re.S).group(1)))
fallback = dict(re.findall(r'\b((?:ui|hero|arena|curse|opt|meta|ach|track|shop|stat|reward)_\w+) = "(\w+)"', re.search(r"ART_FALLBACK[^\n]*= \{(.*?)\n\}", icons, re.S).group(1)))
symbols = re.findall(r'"(\w+)"', re.search(r"local SYMBOLS.*?ipairs\(\{(.*?)\}\)", icons, re.S).group(1))
problems = []

for key, fb in fallback.items():
    folder = folders.get(key.split("_")[0])
    d = pngs.get(key)
    if d is None or os.path.basename(d) != folder:
        problems.append("%s: no art/icons/%s/%s.png" % (key, folder, key))
    if fb not in draw and fb not in images:
        problems.append("%s: drawn fallback '%s' does not exist" % (key, fb))
for n in symbols:
    if "sym_" + n not in pngs:
        problems.append("symbol %s: no sym_%s.png" % (n, n))
    if n not in draw:
        problems.append("symbol %s: no drawn icon" % n)

# every art key written in src (outside Icons.lua) must be one Icons knows
used = set()
for d, _, fs in os.walk(os.path.join(ROOT, "src")):
    for f in fs:
        if f.endswith(".lua") and f != "Icons.lua":
            for m in re.finditer(r'"((?:ui|hero|arena|curse|opt|meta|ach|track|shop|stat|reward)_\w+)"', read(os.path.relpath(os.path.join(d, f), ROOT))):
                used.add(m.group(1))
for key in sorted(used):
    if key not in fallback:
        problems.append("%s used in src but not in Icons.lua ART_FALLBACK" % key)

print("checked %d art keys, %d symbols, %d keys used in src: %d problems" % (len(fallback), len(symbols), len(used), len(problems)))
for p in problems:
    print("  FAIL", p)
sys.exit(1 if problems else 0)
