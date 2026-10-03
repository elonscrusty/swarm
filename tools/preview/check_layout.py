#!/usr/bin/env python3
"""Automatic layout check over preview scene JSONs (tools/preview/render.sh --outdir DIR).

For every scene JSON it looks at the exported GUI (every ScreenGui layer in paint order) and
reports, per scene and device:

  OVERLAP    two visible text runs from different GUI objects whose glyph boxes intersect by
             more than a sliver, with nothing opaque drawn between them (a panel over the HUD
             does not count: the HUD text is covered, not overlapping)
  OFFSCREEN  visible text that runs past the screen edge
  TOPBAR     visible text under Roblox's own top-bar buttons (menu / chat ghost)
  COVERED    visible text partly hidden under an opaque panel or button painted later
  TRUNCATED  text cut with "..." (information only; lists and long names truncate on purpose)

Usage:
  python3 tools/preview/check_layout.py DIR [DIR ...] [--strict] [--quiet]
  python3 tools/preview/check_layout.py out/sweep/levelup-iphone.json

Exit code 1 when any OVERLAP / OFFSCREEN / TOPBAR / COVERED finding is left after the allowlist
(--strict also fails on TRUNCATED). The allowlist below names known, intended cases.
"""
from __future__ import annotations

import json
import os
import sys

# (scene prefix or "*", device or "*", text substring) → intentional overlap / off-screen.
ALLOW = [
    # the lobby hero nameplate's name sits over the hero ring on purpose
]

MIN_OVERLAP_PX = 3.0  # both axes
MIN_OVERLAP_FRAC = 0.2  # of the smaller glyph box
COVER_ALPHA = 0.55  # a box at least this opaque drawn between two texts covers the first


def clip_rect(r, c):
    if not c:
        return r
    x0, y0, x1, y1 = r
    cx0, cy0, cx1, cy1 = c
    return (max(x0, cx0), max(y0, cy0), min(x1, cx1), min(y1, cy1))


def valid(r):
    return r[2] - r[0] > 0.5 and r[3] - r[1] > 0.5


def inter(a, b):
    r = (max(a[0], b[0]), max(a[1], b[1]), min(a[2], b[2]), min(a[3], b[3]))
    return r if valid(r) else None


def area(r):
    return max(0.0, r[2] - r[0]) * max(0.0, r[3] - r[1])


def contains(outer, inner, pad=0.5):
    return outer[0] - pad <= inner[0] and outer[1] - pad <= inner[1] and outer[2] + pad >= inner[2] and outer[3] + pad >= inner[3]


def flatten(items, out, alpha=1.0):
    """Paint-ordered list of (item, alpha) with CanvasGroups unwrapped."""
    for it in items:
        if it.get("t") == "group":
            flatten(it.get("items", []), out, alpha * float(it.get("alpha", 1)))
        else:
            out.append((it, alpha))


def collect(doc):
    gui = doc.get("gui") or {}
    layers = [L for L in gui.get("layers", []) if L.get("kind") == "screen" and isinstance(L.get("items"), list)]
    layers.sort(key=lambda L: L.get("displayOrder", 0))
    boxes = []  # (index, rect, alpha)
    texts = []  # dict(index, rect, text, name, alpha, truncated)
    idx = 0
    for L in layers:
        flat = []
        flatten(L["items"], flat)
        for it, galpha in flat:
            m = it.get("m") or [1, 0, 0, 1, 0, 0]
            if abs(m[1]) > 1e-3 or abs(m[2]) > 1e-3:
                continue  # rotated: skip
            sx, sy = (m[0] or 1), (m[3] or 1)
            x, y = m[4], m[5]
            w, h = it.get("w", 0) * sx, it.get("h", 0) * sy
            rect = (x, y, x + w, y + h)
            clip = it.get("clip")
            idx += 1
            bg = it.get("bg")
            if bg and len(bg) >= 4:
                a = bg[3] * galpha
                if a > 0.02:
                    r = clip_rect(rect, clip)
                    if valid(r):
                        boxes.append((idx, r, a, it.get("name", "?")))
            img = it.get("image")
            if img and img.get("color") and len(img["color"]) >= 4 and img["color"][3] * galpha > 0.9 and not img.get("slice"):
                r = clip_rect(rect, clip)
                if valid(r):
                    boxes.append((idx, r, img["color"][3] * galpha, it.get("name", "?")))
            t = it.get("text")
            if t:
                for line in t.get("lines", []):
                    for seg in line.get("segs", []):
                        col = seg.get("color") or [0, 0, 0, 1]
                        a = col[3] * galpha if len(col) >= 4 else galpha
                        if a < 0.08 or not seg.get("t", "").strip():
                            continue
                        lx = x + t.get("x", 0) * sx + seg.get("x", 0) * sx
                        ly = y + t.get("y", 0) * sy + line.get("y", 0) * sy
                        r = (lx, ly, lx + seg.get("w", 0) * sx, ly + line.get("h", 0) * sy)
                        rc = clip_rect(r, clip)
                        if not valid(rc):
                            continue
                        texts.append({
                            "index": idx,
                            "rect": rc,
                            "raw": r,
                            "text": seg["t"],
                            "name": it.get("name", "?"),
                            "alpha": a,
                            "truncated": seg["t"].endswith("..."),
                            "layer": L.get("name"),
                        })
    return boxes, texts, gui


def allowed(scene, device, text):
    for s, d, sub in ALLOW:
        if (s == "*" or scene.startswith(s)) and (d == "*" or d == device) and sub in text:
            return True
    return False


def check_doc(path, strict=False):
    with open(path) as f:
        doc = json.load(f)
    base = os.path.basename(path)[:-5]
    scene, _, device = base.rpartition("-")
    if device in ("portrait",) and scene.endswith("-phone"):
        scene, device = scene[:-6], "phone-portrait"
    dev = doc.get("device") or {}
    W, H = dev.get("width", 1920), dev.get("height", 1080)
    boxes, texts, gui = collect(doc)
    findings = []

    # top-bar ghost buttons (renderer/page/gui.js paintCoreUi)
    tb = gui.get("topbar") or {"y": 0, "h": 58}
    safe = gui.get("safe") or {}
    left = (safe.get("left") or 0) + 16
    by = tb.get("y", 0) + (tb.get("h", 58) - 44) / 2
    buttons = [(left, by, left + 44, by + 44)]
    core = gui.get("coreGui") or {}
    if core.get("Chat") is not False:
        buttons.append((left + 56, by, left + 100, by + 44))

    screen = (0, 0, W, H)
    # panels (opaque boxes of some size) running off the screen; full-bleed layers are fine
    for bi, br, ba, bn in boxes:
        if ba < 0.5 or area(br) < 0.02 * W * H:
            continue
        if contains(br, screen, pad=-1.0):
            continue
        if not contains(screen, br, pad=4.0):
            findings.append(("OFFSCREEN", bn, "panel %.0fx%.0f" % (br[2] - br[0], br[3] - br[1]), br))
    for t in texts:
        r = t["rect"]
        if t["alpha"] < 0.25:
            continue
        if not contains(screen, r, pad=2.0):
            findings.append(("OFFSCREEN", t["name"], t["text"], r))
        for b in buttons:
            i = inter(r, b)
            if i and (i[2] - i[0]) >= MIN_OVERLAP_PX and (i[3] - i[1]) >= MIN_OVERLAP_PX:
                findings.append(("TOPBAR", t["name"], t["text"], r))
                break
        if t["truncated"]:
            findings.append(("TRUNCATED", t["name"], t["text"], r))

    # text partly hidden under an opaque panel painted later (a card or button lying over
    # the end of a caption); text fully under a later panel is simply covered, which is fine
    for t in texts:
        if t["alpha"] < 0.25:
            continue
        r = t["rect"]
        # behind a dimmer (a later translucent layer over the whole text): a modal over
        # the lobby; whatever its panel then covers is meant to be hidden
        dimmed = False
        for bi, br, ba, bn in boxes:
            if bi > t["index"] and ba >= 0.35 and contains(br, r):
                dimmed = True
                break
        if dimmed:
            continue
        for bi, br, ba, bn in boxes:
            if bi <= t["index"] or ba < COVER_ALPHA or area(br) < 400:
                continue
            x = inter(r, br)
            if not x or contains(br, r):
                continue
            if (x[2] - x[0]) >= MIN_OVERLAP_PX and (x[3] - x[1]) >= MIN_OVERLAP_PX and area(x) / max(1e-6, area(r)) >= MIN_OVERLAP_FRAC:
                findings.append(("COVERED", t["name"] + " under " + bn, t["text"], x))
                break

    # text / text overlaps, in paint order
    texts.sort(key=lambda t: t["index"])
    n = len(texts)
    for i in range(n):
        a = texts[i]
        if a["alpha"] < 0.25:
            continue
        for j in range(i + 1, n):
            b = texts[j]
            if b["index"] == a["index"] or b["alpha"] < 0.25:
                continue
            x = inter(a["rect"], b["rect"])
            if not x:
                continue
            if (x[2] - x[0]) < MIN_OVERLAP_PX or (x[3] - x[1]) < MIN_OVERLAP_PX:
                continue
            small = min(area(a["rect"]), area(b["rect"]))
            if small <= 0 or area(x) / small < MIN_OVERLAP_FRAC:
                continue
            # the same words drawn twice at (almost) the same spot: a shadow / glow copy
            if a["text"] == b["text"] and abs(a["rect"][0] - b["rect"][0]) < 4 and abs(a["rect"][1] - b["rect"][1]) < 4:
                continue
            # covered by an opaque box painted between the two
            covered = False
            for bi, br, ba, _bn in boxes:
                if a["index"] < bi < b["index"] and ba >= COVER_ALPHA and contains(br, a["rect"]):
                    covered = True
                    break
            if covered:
                continue
            findings.append(("OVERLAP", a["name"] + " / " + b["name"], a["text"] + "  <>  " + b["text"], x))

    kept = []
    for kind, name, text, r in findings:
        if allowed(scene, device, text):
            continue
        kept.append((kind, name, text, r))
    return scene, device, kept


def main(argv):
    strict = "--strict" in argv
    quiet = "--quiet" in argv
    paths = []
    for a in argv:
        if a.startswith("--"):
            continue
        if os.path.isdir(a):
            for fn in sorted(os.listdir(a)):
                if fn.endswith(".json") and not fn.endswith(".metrics.json"):
                    paths.append(os.path.join(a, fn))
        elif a.endswith(".json"):
            paths.append(a)
    if not paths:
        print(__doc__)
        return 2
    bad = 0
    total = {"OVERLAP": 0, "OFFSCREEN": 0, "TOPBAR": 0, "COVERED": 0, "TRUNCATED": 0}
    for p in paths:
        try:
            scene, device, findings = check_doc(p, strict)
        except Exception as e:  # noqa: BLE001
            print(f"{os.path.basename(p)}: could not read ({e})")
            bad += 1
            continue
        hard = [f for f in findings if f[0] != "TRUNCATED" or strict]
        soft = [f for f in findings if f[0] == "TRUNCATED" and not strict]
        for f in findings:
            total[f[0]] += 1
        if hard:
            bad += 1
        if hard or (soft and not quiet):
            print(f"== {scene} [{device}]: {len(hard)} problem(s), {len(soft)} truncated")
            for kind, name, text, r in hard:
                print(f"   {kind:9s} {name}: {text!r} @ ({r[0]:.0f},{r[1]:.0f})-({r[2]:.0f},{r[3]:.0f})")
            if not quiet:
                for kind, name, text, r in soft:
                    print(f"   {kind:9s} {name}: {text!r}")
    print(f"checked {len(paths)} scene(s): {total['OVERLAP']} overlap, {total['OFFSCREEN']} off-screen, {total['TOPBAR']} under top bar, {total['COVERED']} part-covered, {total['TRUNCATED']} truncated; {bad} scene(s) with problems")
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
