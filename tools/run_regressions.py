"""Run SWARM's offline module regressions; preserve raw evidence outside the source tree."""
import argparse
import concurrent.futures
import json
import os
from pathlib import Path
import re
import subprocess
import sys


def main():
    repo = Path(__file__).resolve().parent.parent
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--lune", default=str(repo.parent / "toolchain/lune" / ("lune.exe" if os.name == "nt" else "lune")))
    parser.add_argument("--out", type=Path, default=repo.parent / "verification")
    args = parser.parse_args()
    args.out = args.out.resolve()
    args.out.mkdir(parents=True, exist_ok=True)
    checks = [(name, []) for name in (
        "economy-sim", "storage-sim", "difficulty-sim", "ground-sim", "audio-sim",
        "progression-regression", "mastery-regression", "combat-regression", "whip-regression", "data-regression", "passives-regression", "run-manager-regression", "fall-regression",
        "settlement-lifecycle", "reward-regression", "encounters-sim", "encounter-placement",
        "expedition-sim", "party-sim", "stage-sim", "weapons-sim", "xp-sim", "synergy-sim", "chest-gold-sim", "curses-sim",
    )]
    checks += [("storage-sim", ["outage=all"]), ("runserver-sim", ["role=lobby"]),
               ("runserver-sim", ["role=run"]), ("difficulty-handoff", []),
               ("difficulty-handoff", ["unlocked=off"])]
    checks += [("boss-sim", ["boss=" + name]) for name in (
        "ScorpionQueen", "MothMatriarch", "RhinoWarlord", "HiveMother",
        "BriarSentinel", "FrostboundColossus",
    )]
    checks += [("ui", ["phone"]), ("ui", ["phone-portrait"])]
    checks += [("menu", ["phone"]), ("menu", ["phone-portrait"])]
    checks += [("discovery", ["phone"]), ("discovery", ["phone-portrait"])]
    checks += [("pings", ["phone"]), ("pings", ["phone-portrait"])]
    checks += [("accessibility-sim", [])]
    checks += [("coop-regression", ["rejoin=" + value]) for value in ("success", "expired", "ended", "forged")]
    checks += [("reconnect-lobby", []), ("reconnect-lobby", ["fail=teleport"]), ("reconnect-lobby", ["fail=expired"])]
    # phone layouts: the scene's GUI export goes through tools/preview/check_layout.py
    # (text over text, text off screen or under the Roblox top bar, panels off screen)
    checks += [("layout", [scene, device]) for device in ("iphone", "phone-portrait")
               for scene in ("menu", "levelup", "results", "pause", "revive", "stage-choice", "characters", "countdown")]
    # the CHARACTERS screen with the Hero Mastery upgrade rows open
    checks += [("layout", ["characters", device, "mastery=open"]) for device in ("iphone", "phone-portrait")]

    def run(check):
        scene, settings = check
        name = scene + ("-" + "-".join(settings).replace("=", "-") if settings else "")
        scripts = {"ui": "ui_regression.luau", "menu": "menu_clarity_regression.luau", "discovery": "menu_discovery_regression.luau", "pings": "team_pings_regression.luau"}
        command = [args.lune, "run", "tools/" + scripts[scene], *settings] if scene in scripts else [
            args.lune, "run", "tools/preview/runtime/main.luau", "--", "--scene", scene,
            "--studio", "--device", "pc", "--out", str(args.out / (name + ".json")),
            "--max-time", "400", "--set", "headless=on",
        ]
        # Live-store and teleport fixtures intentionally run outside Studio.
        if scene in ("storage-sim", "runserver-sim", "difficulty-handoff", "coop-regression", "reconnect-lobby"):
            command.remove("--studio")
        if scene == "layout":
            layout_scene, device = settings[0], settings[1]
            command = [args.lune, "run", "tools/preview/runtime/main.luau", "--", "--scene", layout_scene,
                       "--device", device, "--out", str(args.out / (name + ".json")), "--set", "images=loaded"]
            for setting in settings[2:]:
                command.extend(["--set", setting])
        elif scene not in scripts:
            for setting in settings:
                command.extend(["--set", setting])
        try:
            result = subprocess.run(command, cwd=repo, capture_output=True, text=True, encoding="utf-8", errors="replace", timeout=360)
            output = result.stdout + result.stderr
            if scene == "layout" and result.returncode == 0:
                layout = subprocess.run([sys.executable, "tools/preview/check_layout.py", str(args.out / (name + ".json")), "--quiet"],
                                        cwd=repo, capture_output=True, text=True, encoding="utf-8", errors="replace", timeout=120)
                output += layout.stdout + layout.stderr
                if layout.returncode != 0:
                    output += "\nFAIL layout check\n"
            passed = result.returncode == 0 and not re.search(r"\bFAIL\b|Step error:|handler error|start client failed", output)
            code = result.returncode
        except subprocess.TimeoutExpired as error:
            output = (error.stdout or b"").decode("utf-8", errors="replace") if isinstance(error.stdout, bytes) else error.stdout or ""
            output += "\nRegression process timed out.\n"
            passed, code = False, "timeout"
        (args.out / (name + ".log")).write_text(output, encoding="utf-8")
        print(("PASS " if passed else "FAIL ") + name, flush=True)
        return {"name": name, "passed": passed, "exit": code}

    with concurrent.futures.ThreadPoolExecutor(max_workers=3) as pool:
        results = list(pool.map(run, checks))
    (args.out / "results.json").write_text(json.dumps(results, indent=2), encoding="utf-8")
    print(f"{sum(item['passed'] for item in results)}/{len(results)} checks passed; evidence: {args.out}")
    return 0 if all(item["passed"] for item in results) else 1


if __name__ == "__main__":
    sys.exit(main())
