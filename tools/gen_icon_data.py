"""Fill the IconData.Icons table in src/shared/IconData.lua from art/icons/uploaded_ids.json.

    python3 tools/gen_icon_data.py

Every key of the table keeps its place; ids missing from the JSON stay nil. Names in the JSON
that are not in the table yet are added under "Other" (run items and markers are in the
table already). Re-run after tools/upload_icons.py.
"""

import json
import os
import re

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
LUA = os.path.join(ROOT, "src", "shared", "IconData.lua")
IDS = os.path.join(ROOT, "art", "icons", "uploaded_ids.json")

ids = json.load(open(IDS))
src = open(LUA).read()
m = re.search(r"(IconData\.Icons = \{\n)(.*?)(\n\} :: )", src, re.S)
assert m, "Icons table not found"
body = m.group(2)
seen = set()


def fill(line):
    mm = re.match(r"(\t)(\w+) = [^,]+,(.*)$", line)
    if not mm:
        return line
    seen.add(mm.group(2))
    v = ids.get(mm.group(2))
    return "\t%s = %s,%s" % (mm.group(2), v if v else "nil", mm.group(3))


lines = [fill(l) for l in body.split("\n")]
extra = sorted(k for k in ids if k not in seen)
if extra:
    lines.append("\t-- Other")
    lines += ["\t%s = %s," % (k, ids[k]) for k in extra]
src = src[: m.start(2)] + "\n".join(lines) + src[m.end(2):]
open(LUA, "w").write(src)
print("filled %d ids%s" % (len(seen), ", added " + ", ".join(extra) if extra else ""))
