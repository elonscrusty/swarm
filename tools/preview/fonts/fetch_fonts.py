"""Download the fonts the preview renderer uses and measure them.

    python3 tools/preview/fonts/fetch_fonts.py          (idempotent, cached)

Fonts come from Google Fonts (static TTF per weight) into tools/preview/.cache/fonts/.
Roblox font families map to them like this (see FAMILY_MAP; docs/PREVIEW.md):

    Merriweather.json   -> Merriweather          (same font)
    SourceSansPro.json  -> Source Sans 3          (the renamed Source Sans Pro)
    Inconsolata.json    -> Inconsolata            (same font, Enum.Font.Code)
    GothamSSm.json      -> Montserrat             (substitute: Gotham is proprietary)
    BuilderSans.json    -> Inter                  (substitute: Builder Sans is not public)
    Arial / Legacy      -> Arimo                  (metric-compatible Arial clone)
    anything else       -> Source Sans 3          (reported as a substitution)

The measurements (advance widths in em, ascent/descent) go to .cache/fonts/metrics.json.
The Luau runtime uses them for TextBounds / TextScaled / wrapping, and the browser draws
the very same TTF files, so wrapping in the screenshot matches what the runtime computed.
"""

import json
import os
import re
import sys
import urllib.request

HERE = os.path.dirname(os.path.abspath(__file__))
CACHE = os.path.join(os.path.dirname(HERE), ".cache", "fonts")
METRICS = os.path.join(CACHE, "metrics.json")
VERSION = 3  # bump when the families or the measured characters change

# Google family -> weights (normal) and weights that also get an italic file.
FAMILIES = {
    "Merriweather": ([300, 400, 700, 900], [400, 700]),
    "Source Sans 3": ([200, 300, 400, 600, 700, 900], [400, 700]),
    "Montserrat": ([300, 400, 500, 600, 700, 800, 900], [400, 700]),
    "Inter": ([300, 400, 500, 600, 700, 800, 900], []),
    "Inconsolata": ([400, 700], []),
    "Arimo": ([400, 700], [400, 700]),
}

# Roblox family json -> (google family, note). Keys are lower case file stems.
FAMILY_MAP = {
    "merriweather": ("Merriweather", "same font"),
    "sourcesanspro": ("Source Sans 3", "same font (renamed)"),
    "sourcesans": ("Source Sans 3", "same font (renamed)"),
    "inconsolata": ("Inconsolata", "same font"),
    "gothamssm": ("Montserrat", "substitute for Gotham"),
    "gotham": ("Montserrat", "substitute for Gotham"),
    "buildersans": ("Inter", "substitute for Builder Sans"),
    "arial": ("Arimo", "metric-compatible Arial"),
    "legacyarial": ("Arimo", "substitute for Legacy"),
    "montserrat": ("Montserrat", "same font"),
    "roboto": ("Inter", "substitute for Roboto"),
    "nunito": ("Montserrat", "substitute for Nunito"),
}

CHARS = [chr(c) for c in range(32, 127)] + [chr(c) for c in range(160, 256)] + list(
    "‘’“”–—…•·×←↑→↓"
    "★☆♥✓✗▶◀▲▼✕✖∞€™")

UA = "Mozilla/4.0"  # Google Fonts then serves plain TTF files


def css_url(family, weights, italic_weights):
    if italic_weights:
        axis = "ital,wght@"
        spec = ";".join(["0,%d" % w for w in weights] + ["1,%d" % w for w in italic_weights])
    else:
        axis = "wght@"
        spec = ";".join(str(w) for w in weights)
    return "https://fonts.googleapis.com/css2?family=%s:%s%s&display=swap" % (family.replace(" ", "+"), axis, spec)


def fetch(url):
    req = urllib.request.Request(url, headers={"User-Agent": UA})
    with urllib.request.urlopen(req, timeout=60) as r:
        return r.read()


def download_family(family, weights, italics):
    css = fetch(css_url(family, weights, italics)).decode("utf8")
    files = {}
    for block in re.findall(r"@font-face\s*{([^}]*)}", css):
        style = re.search(r"font-style:\s*(\w+)", block).group(1)
        weight = int(re.search(r"font-weight:\s*(\d+)", block).group(1))
        url = re.search(r"url\((https://[^)]+)\)", block).group(1)
        name = "%s-%d-%s.ttf" % (family.replace(" ", ""), weight, style)
        path = os.path.join(CACHE, name)
        if not os.path.exists(path):
            data = fetch(url)
            with open(path, "wb") as f:
                f.write(data)
        files["%d-%s" % (weight, style)] = name
    return files


def measure(path):
    from PIL import ImageFont
    size = 1000
    font = ImageFont.truetype(path, size)
    adv = {}
    for ch in CHARS:
        try:
            adv[ch] = round(font.getlength(ch) / size, 4)
        except Exception:
            pass
    ascent, descent = font.getmetrics()
    # cap height / x height from the glyph boxes (used to centre text like Roblox)
    cap = font.getbbox("H")
    xh = font.getbbox("x")
    return {
        "adv": adv,
        "fallback": adv.get("n", 0.5),
        "ascent": round(ascent / size, 4),
        "descent": round(descent / size, 4),
        "capHeight": round((cap[3] - cap[1]) / size, 4),
        "xHeight": round((xh[3] - xh[1]) / size, 4),
    }


def main():
    os.makedirs(CACHE, exist_ok=True)
    if os.path.exists(METRICS) and "--force" not in sys.argv:
        with open(METRICS) as f:
            old = json.load(f)
        if old.get("version") == VERSION and all(os.path.exists(os.path.join(CACHE, fn)) for fam in old["families"].values() for fn in fam.values()):
            print("fonts: cached (%s)" % CACHE)
            return
    out = {"version": VERSION, "families": {}, "metrics": {}, "map": {k: list(v) for k, v in FAMILY_MAP.items()}, "default": "Source Sans 3"}
    for family, (weights, italics) in FAMILIES.items():
        files = download_family(family, weights, italics)
        out["families"][family] = files
        for key, fn in files.items():
            out["metrics"][fn] = measure(os.path.join(CACHE, fn))
        print("fonts: %s %s" % (family, ", ".join(sorted(files))))
    with open(METRICS, "w") as f:
        json.dump(out, f, ensure_ascii=False, separators=(",", ":"))
    print("fonts: metrics written to %s" % METRICS)


if __name__ == "__main__":
    main()
