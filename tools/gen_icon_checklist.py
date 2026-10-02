"""Write docs/ICON_CHECKLIST.md: every icon key the game uses, with its status.

    python3 tools/gen_icon_checklist.py          # rewrite the checklist, list problems
    python3 tools/gen_icon_checklist.py --check  # exit 1 if any catalog entry has no real icon

Reads the catalogs (WeaponData, PassiveData, ItemData, CharacterData, MetaUpgradeData,
CurseData, AchievementData, AccountData, the arena / shop / stat tables in src/client),
src/shared/IconData.lua (uploaded pictures), art/icons/*.png and the DRAW table in
src/client/Icons.lua (vector icons), and scans src for every literal icon name.

Status values
  working (image)         uploaded picture in IconData and a PNG in art/icons
  working (drawn)         vector icon drawn in code (menu / UI icons; fine for UI)
  MISSING                 no picture and no drawn icon: shows the fallback only
  NO IMAGE (drawn only)   a weapon / passive / item that should have a picture but has none
  missing (upload blocked) PNG exists but has no uploaded id
  INVALID                 the catalog points at an icon key that does not exist
  intentionally locked    shown as a lock icon until unlocked
Catalog entries flagged MISSING / NO IMAGE / INVALID / upload blocked are listed at the end.
"""

import json
import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SRC = os.path.join(ROOT, "src")
OUT = os.path.join(ROOT, "docs", "ICON_CHECKLIST.md")


def read(rel):
    with open(os.path.join(ROOT, rel), encoding="utf-8") as f:
        return f.read()


icons_lua = read("src/client/Icons.lua")
DRAW = set(re.findall(r"^DRAW\.(\w+)\s*=", icons_lua, re.M)) - {"missing"}
IMAGES = {k: v for k, v in re.findall(r"^\t(\w+) = (\d+),", read("src/shared/IconData.lua"), re.M)}
PNGS = {f[:-4] for f in os.listdir(os.path.join(ROOT, "art", "icons")) if f.endswith(".png")}
PRELOAD_NOTE = "Icons.PreloadList()"


def blocks(rel, start=None, stop=None, indent=2):
    """[(id, name, icon_or_None)] for every `Id = "x",` line at the given tab depth."""
    text = read(rel)
    if start:
        text = text[text.index(start):]
    if stop and stop in text:
        text = text[: text.index(stop)]
    pat = re.compile(r"^\t{%d}Id = \"(\w+)\",\n(?:\t{%d}[^\n]*\n)*?" % (indent, indent), re.M)
    out = []
    ms = list(pat.finditer(text))
    for i, m in enumerate(ms):
        end = ms[i + 1].start() if i + 1 < len(ms) else len(text)
        body = text[m.start():end]
        name = re.search(r'Name = "([^"]*)"', body)
        icon = re.search(r'^\t{%d}Icon = "(\w+)"' % indent, body, re.M)
        out.append((m.group(1), name.group(1) if name else m.group(1), icon.group(1) if icon else None))
    return out


def status(key, want_image=False):
    """(status, asset reference) for an icon key."""
    if key is None:
        return "MISSING", "-"
    img = IMAGES.get(key)
    if img and key in PNGS:
        return "working (image)", "rbxassetid://" + img
    if img:
        return "working (image)", "rbxassetid://%s (no PNG in art/icons)" % img
    if key in PNGS:
        return "missing (upload blocked)", "PNG only: art/icons/%s.png" % key
    if key in DRAW:
        return ("NO IMAGE (drawn only)" if want_image else "working (drawn)"), "drawn: DRAW." + key
    return "INVALID" if key else "MISSING", "no picture, no drawn icon"


sections = []  # (title, note, [rows]) row = (key, name, where, status, asset)
problems = []


def add(title, note, entries, want_image=False):
    rows = []
    for key, name, where in entries:
        st, asset = status(key, want_image)
        rows.append((key, name, where, st, asset))
        if st.startswith(("MISSING", "INVALID", "NO IMAGE", "missing")):
            problems.append("%s: %s (%s) -> %s" % (title, key, name, st))
    sections.append((title, note, rows))


# --- catalogs ----------------------------------------------------------------------------
weapons = blocks("src/shared/WeaponData.lua", "WeaponData.Weapons = {", None, 2)
evos = blocks("src/shared/WeaponData.lua", "WeaponData.Weapons = {", None, 3)
add("Weapons", "Level-up cards, HUD weapon bar, character screen (start weapon), chest rewards, results build.",
    [(i, n, "level-up card, HUD bar, results") for i, n, _ in weapons], True)
add("Weapon evolutions", "EVOLUTION cards, HUD bar once evolved, results build.",
    [(i, n, "evolution card, HUD bar, results") for i, n, _ in evos], True)
passives = blocks("src/shared/PassiveData.lua", "PassiveData.Passives", None, 2)
add("Passives (upgrades)", "Level-up cards, HUD passive row, results build. Vacuum = pickup radius.",
    [(i, n, "level-up card, HUD passive row, results") for i, n, _ in passives], True)
items = re.findall(r'\{ Id = "(\w+)", Name = "([^"]*)", Rarity = "(\w+)"', read("src/shared/ItemData.lua"))
add("Run items", "Item popups, chest / shrine / altar rewards, item strip, results.",
    [(i, n + " (" + r + ")", "item popup, loot panels, results") for i, n, r in items], True)
add("Fallback cards and loot markers", "Level-up fallback cards (all slots maxed), loot prompts, portal and revive markers.",
    [("Gold", "Gold bonus card", "level-up fallback card, shop"), ("Heal", "Heal bonus card", "level-up fallback card"),
     ("chest", "Chest", "loot prompt, chest panel, shop"), ("shrine", "Bargain Shrine", "loot prompt"),
     ("altar", "Guarded Altar", "loot prompt, achievement"), ("portal", "Portal / stage", "HUD stage pill, stage panels, stats"),
     ("revive", "Revive", "team HUD, meta upgrade, stats")], False)

# characters: Icons.lua CHARACTER_ICONS
cmap = dict(re.findall(r"(\w+) = \"(\w+)\"", re.search(r"CHARACTER_ICONS = \{(.*?)\}", icons_lua).group(1)))
chars = blocks("src/shared/CharacterData.lua", None, "CharacterData.Skins", 2)
rows = []
for i, n, _ in chars:
    key = cmap.get(i)
    rows.append((key, n + " [" + i + "]", "character select, lobby, team HUD, results"))
add("Characters (class icon)", "Class icons are drawn in code (Icons.Character). Skins reuse the class icon.", rows)
add("Locked / state icons", "Icons that mark a state.", [
    ("lock", "Locked character / arena / reward", "intentionally locked: character cards, arena cards, track rewards"),
    ("check", "Selected / done / confirm", "character select, curses, bug report, achievements"),
    ("warning", "Warning / confirm", "results, level-up skip, popups"),
    ("close", "Close / cancel", "panels")])
# fix status label for the lock row
sections[-1] = (sections[-1][0], sections[-1][1], [
    (r[0], r[1], r[2], "intentionally locked" if r[0] == "lock" else r[3], r[4]) for r in sections[-1][2]])

meta_map = dict(re.findall(r"(\w+) = \"(\w+)\"", re.search(r"META_ICONS = \{(.*?)\}", icons_lua, re.S).group(1)))
meta = blocks("src/shared/MetaUpgradeData.lua", "MetaUpgradeData.Upgrades", None, 2)
add("Meta upgrades (permanent)", "UPGRADES screen (Icons.MetaIcon); reuse the passive pictures.",
    [(meta_map.get(i), n + " [" + i + "]", "UPGRADES > Permanent") for i, n, _ in meta])

look = re.search(r"local LOOK.*?\n\}", read("src/client/MenuArenas.lua"), re.S).group(0)
add("Arenas / stages", "ARENAS screen cards (the stage pill uses portal).",
    [(ic, a, "ARENAS screen") for a, ic in re.findall(r'(\w+) = \{ Sky.*?Icon = "(\w+)"', look)])
curses = blocks("src/shared/CurseData.lua", "CurseData.Curses", None, 2)
curses += re.findall(r'(\w+) = \{ Id = "\w+", Name = "([^"]*)", Icon = "(\w+)"', read("src/shared/CurseData.lua"))
curses = [(c[0], c[1], c[2]) for c in curses]
add("Curses and run options", "CURSES screen, countdown panel, HUD chips, results.",
    [(ic, n + " [" + i + "]", "CURSES screen, HUD chips") for i, n, ic in curses])
ach = blocks("src/shared/AchievementData.lua", None, None, 2)
add("Achievements", "STATS > Achievements.", [(ic, n + " [" + i + "]", "STATS > Achievements") for i, n, ic in ach])
kind = dict(re.findall(r"(\w+) = \"(\w+)\"", re.search(r"KIND_ICON = \{(.*?)\}", read("src/client/MenuTrack.lua")).group(1)))
add("Track (account level)", "TRACK screen reward rows (by reward kind) and the medallion.",
    [(ic, "%s reward" % k, "TRACK screen") for k, ic in kind.items()] + [("medal", "Account level medal", "TRACK, results")])
shop = re.findall(r'Name = "([^"]+)", Kind = "\w+", Key = "\w+", Icon = "(\w+)"', read("src/client/MenuUpgrades.lua"))
add("Shop (Robux = cosmetics / coins only)", "UPGRADES > Shop rows.", [(ic, n, "UPGRADES > Shop") for n, ic in shop] + [("robux", "Robux price tag", "shop, character unlock")])
tiles = re.findall(r'Key = "(\w+)", Icon = "(\w+)", Caption = "([^"]+)"', read("src/client/MenuStats.lua"))
add("Stats tiles", "STATS screen.", [(ic, c + " [" + k + "]", "STATS") for k, ic, c in tiles])
boards = re.findall(r'Id = "(\w+)", Title = "([^"]+)", Icon = "(\w+)"', read("src/client/MenuLeaderboards.lua"))
add("Leaderboards", "LEADERBOARDS tabs.", [(ic, t + " [" + i + "]", "LEADERBOARDS") for i, t, ic in boards] + [("podium", "Leaderboards / rank button", "lobby menu, daily"), ("trophy", "Wins / achievements / rank", "stats")])

# --- every literal icon name in src/client, grouped by key -------------------------------
used = {}
pat = re.compile(r'Icons\.(?:Draw|Upgrade)\([^,]+, "(\w+)"|\bIcon(?:Right)? = "(\w+)"|\bicon = "(\w+)"|\bIcon = [\w\.]+ or "(\w+)"')
for dp, _, fs in os.walk(SRC):
    for fn in fs:
        if not fn.endswith(".lua") or fn in ("Icons.lua", "IconData.lua"):
            continue
        p = os.path.join(dp, fn)
        for ln, line in enumerate(open(p, encoding="utf-8"), 1):
            for m in pat.finditer(line):
                k = next(g for g in m.groups() if g)
                used.setdefault(k, set()).add(fn[:-4])
rows = []
for k in sorted(used):
    desc = ", ".join(sorted(used[k]))
    rows.append((k, k, desc))
add("All literal UI icon keys", "Every icon name written in src (screens that use it).", rows)
sections.append(("Controls without an icon", "Intentional: text buttons.", [
    ("-", "Return to Main Menu (pause)", "pause menu: uses key `castle` (same as results MAIN MENU)", "working (drawn)", "drawn: DRAW.castle"),
    ("-", "DEV invincibility / DEV panel controls", "DEV panel", "working (text button, no icon: intentional)", "-"),
    ("-", "Reroll / Skip / Auto-pick / Banish", "level-up buttons: `cycle`, `skip`; auto-pick is a timer bar (no icon); banish does not exist", "working (drawn)", "drawn: DRAW.cycle, DRAW.skip"),
    ("-", "Coins / XP / pause / settings / daily", "keys `coin`, XP gems are 3D (no icon), `pause`, `gear`, `calendar`", "working (drawn)", "drawn"),
]))

# --- write -------------------------------------------------------------------------------
lines = ["# Icon checklist", "",
         "Generated by `python3 tools/gen_icon_checklist.py`; do not edit by hand.",
         "One lookup path: `src/client/Icons.lua` (`Icons.Draw`, `Icons.Upgrade`, `Icons.Character`, `Icons.MetaIcon`).",
         "Uploaded pictures live in `src/shared/IconData.lua` (filled by `tools/gen_icon_data.py`); everything else is drawn in code.",
         "If a picture cannot load, Icons draws the vector icon (or a framed glyph) underneath.",
         "Preload list for ContentProvider: `Icons.PreloadList()`.", ""]
total = sum(len(r) for _, _, r in sections)
lines += ["Entries: %d. Problems: %d." % (total, len(problems)), ""]
for title, note, rows in sections:
    lines += ["## " + title, "", note, "", "| Key | Name | Where it appears | Asset | Status |", "|---|---|---|---|---|"]
    for key, name, where, st, asset in rows:
        lines.append("| `%s` | %s | %s | %s | %s |" % (key, name, where, asset, st))
    lines.append("")
lines += ["## Problems", ""] + (["- " + p for p in problems] if problems else ["None: every catalog entry has a real icon."]) + [""]
with open(OUT, "w", encoding="utf-8") as f:
    f.write("\n".join(lines))
print("wrote %s: %d entries, %d problems" % (os.path.relpath(OUT, ROOT), total, len(problems)))
for p in problems:
    print("  FLAG", p)
if "--check" in sys.argv and problems:
    sys.exit(1)
