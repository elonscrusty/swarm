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
    parser.add_argument("--only", default="", help="comma-separated check names (as printed) to rerun just those")
    parser.add_argument("--workers", type=int, default=3)
    args = parser.parse_args()
    args.out = args.out.resolve()
    args.out.mkdir(parents=True, exist_ok=True)
    checks = [(name, []) for name in (
        "economy-sim", "storage-sim", "difficulty-sim", "ground-sim", "arena-dressing-regression", "ground-zfight-regression", "audio-sim",
        "progression-regression", "mastery-regression", "combat-regression", "corner-regression", "world-regression", "journey-regression", "loot-focus-regression", "lobby-screens-regression", "hud-key-regression", "whip-regression", "data-regression", "passives-regression", "math-regression", "economy-regression", "run-manager-regression", "choice-regression", "portal-hold-regression", "fall-regression", "single-map-regression", "safety-sim", "settings-sim", "security-regression", "pass-warm-regression", "perf-regression",
        "settlement-lifecycle", "foundation-regression", "heropower-regression", "challenges-regression", "explore-regression", "events-regression", "feel-regression", "meta-regression", "team-regression", "reward-regression", "reward-once-regression", "encounters-sim", "encounter-placement",
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
    checks += [("daily-quests-regression", []), ("comeback-regression", ["headless=off"])] + [("layout", ["meta", d, "screen=" + s]) for d in ("iphone", "phone-portrait", "pc") for s in ("Quests", "Comeback")]  # DailyQuests + ComebackGift (docs/next)
    checks += [("bugreport-plus-regression", [])]  # BugReportPlus: snapshot, filter, 3/hour, DEV-only inbox (live rules)
    # StarterBundle / GroupBonus / InviteRewards (docs/next) are held by the owner (switches off): their
    # logic regressions and the social Home card check need the switch on, so they are left out until release
    checks += [("layout", ["social", d, "screen=" + s]) for d in ("iphone", "phone-portrait", "pc") for s in ("Starter", "Group", "Invite", "Store", "More")]
    checks += [("uistate", [])]
    # DAILY CHALLENGE screen + the go-home notice (bottom-right, clear of the panel; ticks live; GO NOW / STAY remotes)
    checks += [("layout", ["daily", d, "travel=on"]) for d in ("iphone", "phone-portrait", "pc", "tablet")]
    checks += [("layout", ["daily", d, "used=on", "details=on", "travel=on"]) for d in ("iphone", "phone-portrait", "pc")]
    checks += [("home-board-regression", [])]
    checks += [("layout", ["menu", d, "board=" + b]) for d in ("iphone", "phone-portrait") for b in ("empty", "error", "out")]
    # the player's Roblox Text size setting on a phone (TextFit, docs/MOBILE_FIX.md)
    checks += [("textfit-regression", []), ("textfit-regression", ["textsize=Medium"])]
    checks += [("lobby-regression", [])]
    checks += [("layout", [s, d]) for s in ("weapon-mastery", "photo-mode", "lobby-fun") for d in ("iphone", "phone-portrait")]
    checks += [("layout", ["lobby-fun", d, "view=mirror"]) for d in ("iphone", "phone-portrait")]
    checks += [("layout", ["challenges", d, "extras=on"]) for d in ("iphone", "phone-portrait")]
    checks += [("layout", ["explore", d, "pad=on"]) for d in ("iphone", "phone-portrait")]
    checks += [("store-regression", [])]
    checks += [("layout", ["store", d, "section=Gift", "ids=on"]) for d in ("iphone", "phone-portrait")]
    checks += [("layout", ["store", d, "section=Pets"]) for d in ("iphone", "phone-portrait")]
    checks += [("heroes-regression", []), ("heroes-regression", ["coop=on"])]
    checks += [("layout", ["team", d, "mode=Duo", "wheel=on"]) for d in ("iphone", "phone-portrait")]
    checks += [("layout", ["meta", d, "screen=" + s]) for d in ("iphone", "phone-portrait") for s in ("Sigils", "Weekly", "Season", "Titles", "Collection", "Streak", "Play", "More")]
    # the PLAY run setup (MenuPlay): full screen with a last run, and the new-account setup with ADVANCED open
    checks += [("layout", ["menu", d, "screen=Play", "runs=10"]) for d in ("iphone", "phone-portrait", "tablet", "pc")]
    checks += [("layout", ["menu", d, "screen=Play", "runs=0", "advanced=open"]) for d in ("iphone", "phone-portrait")]
    checks += [("events-fx", [])]
    checks += [("layout", ["explore", d]) for d in ("iphone", "phone-portrait")]
    checks += [("layout", ["characters", d, "favourites=open"]) for d in ("iphone", "phone-portrait")]
    checks += [("layout", ["levelup", d, "fav=on"]) for d in ("iphone", "phone-portrait")]
    checks += [("run-intro", ["stage=2", "panel=on"]), ("results", ["bestscore=on"])]
    checks += [("results-flow", ["case=" + c]) for c in ("auto", "stay", "replay", "portal", "plain")]
    checks += [("leaderboards", ["mismatch=board"])]
    checks += [("leaderboards", ["status=error", "rows=0", "textcheck=on"])]
    # the home screen's TOP SCORES panel (HomeBoard) and its states on phones
    checks += [("home-board-regression", [])]
    checks += [("layout", ["menu", d, "board=" + b]) for d in ("iphone", "phone-portrait") for b in ("empty", "error", "out")]
    checks += [("coop-regression", ["rejoin=" + value]) for value in ("success", "expired", "ended", "forged")]
    checks += [("reconnect-lobby", []), ("reconnect-lobby", ["fail=teleport"]), ("reconnect-lobby", ["fail=expired"])]
    # phone layouts: the scene's GUI export goes through tools/preview/check_layout.py
    # (text over text, text off screen or under the Roblox top bar, panels off screen)
    checks += [("layout", [scene, device]) for device in ("iphone", "phone-portrait")
               for scene in ("menu", "levelup", "results", "pause", "revive", "stage-choice", "characters", "countdown")]
    # the CHARACTERS screen with the Hero Mastery upgrade rows open
    checks += [("layout", ["characters", device, "mastery=open"]) for device in ("iphone", "phone-portrait")]
    checks += [("layout", ["arenas", d]) for d in ("iphone", "phone-portrait", "pc", "tablet")]  # ARENAS screen: four cards per row, fixed footer
    # the PARTY screen: with a party, alone (empty server list) and the Friends tab
    checks += [("layout", ["party", d, "view=" + v]) for d in ("iphone", "phone-portrait", "pc") for v in ("panel", "alone", "friends")]
    checks += [("fast-start-regression", [])]  # FastStart: quicker, bigger waves 1-3 on stage 1 (PASS/FAIL lines)
    checks += [("layout", ["danger-arrows-regression", d]) for d in ("iphone", "phone-portrait", "pc")]  # DangerArrows: logic PASS/FAIL lines + layout
    checks += [("layout", ["smart-tutorial-regression", d]) for d in ("iphone", "phone-portrait", "pc")]  # SmartTutorial: logic PASS/FAIL lines + layout
    checks += [("walkthrough-regression", [])]  # Walkthrough: interactive first-run steps, holds, exactly-once chest, timeouts (PASS/FAIL lines)
    # batch B (docs/PROMPT_BATCH_B.md, docs/next/); one block per group
    # batch B group A: AffixIcons, DamageNumberOptions
    checks += [("affix-sight-regression", []), ("damage-settings-regression", [])]  # AffixIcons first-sight notice + SeenAffixes (real server); DamageNumberOptions settings path (real server)
    checks += [("layout", [scene, d]) for scene in ("affix-icons-regression", "damage-numbers-regression") for d in ("iphone", "phone-portrait", "pc")]  # AffixIcons badges (logic + layout), DamageNumberOptions rules, counts and Settings rows (logic + layout)
    # batch B group B: EvolutionPreview, Banish
    checks += [("evolution-preview-regression", [])] + [("layout", ["evolution-panel-regression", d]) for d in ("iphone", "phone-portrait", "pc")] + [("layout", ["levelup", d, "evo=on"]) for d in ("iphone", "phone-portrait", "pc")] + [("layout", ["hud-build", d]) for d in ("iphone", "phone-portrait", "pc")]  # EvolutionPreview (docs/next/EVOLUTION_PREVIEW.md)
    checks += [("banish-regression", [])] + [("layout", ["levelup", d, "banish=3"]) for d in ("iphone", "phone-portrait", "pc")] + [("layout", ["levelup", d, "banish=2", "banishmode=on", "evo=on"]) for d in ("iphone", "phone-portrait", "pc")]  # Banish (docs/next/BANISH.md)
    # batch B group C: FinalStand, StageModifiers
    # batch B group D: PartyQuickLines, ReviveThanks
    checks += [("revive-thanks-regression", [])]  # ReviveThanks: offer, once, XP, pair limit, DEV taint, solo, 6 s offer (PASS/FAIL lines; server run, client module without UI)
    checks += [("layout", ["revive-thanks-layout", d]) for d in ("iphone", "phone-portrait", "pc")]  # ReviveThanks: THANKS! button clear of JUMP / ULT / team list
    # batch B group E: Prestige, QuickResume
    # menu redesign 2026-10-08: the compact Settings modal (lobby and from the run menu) and the
    # level-up cards' DETAILS toggle (opens the panel, never picks the card)
    checks += [("layout", ["settings", d]) for d in ("iphone", "phone-portrait", "pc")]
    checks += [("layout", ["pause", d, "view=settings"]) for d in ("iphone", "phone-portrait")]
    # (landscape cards only: the narrow portrait cards keep their one-line details inline, no toggle)
    checks += [("layout", ["levelup", d, "details=2"]) for d in ("iphone", "pc")]
    # SwarmV2 lobby UI (basecamp-ui scene): class sheet, gates, queue, countdown on phones
    checks += [("layout", ["basecamp-ui", d, "view=" + v]) for d in ("iphone", "phone-portrait") for v in ("idle", "classes", "gates", "countdown")]
    # funnel analytics (server Analytics.lua, docs/ANALYTICS.md): AnalyticsService mock as a
    # published lobby, the same flow in Studio (nothing sent), and the real client's ready report
    checks += [("run-entry-regression", [])]  # SwarmV2 arrival barrier, local match start with the admitted class, return hook
    checks += [("admission-regression", []), ("lobby-queue-regression", []), ("party-v2-regression", [])]  # SwarmV2 lobby: MatchAdmission + TicketStore, QueueService/Transfer/ClassService, PartyService Promote/OnChanged + save normalisation (PASS/FAIL lines)
    checks += [("analytics-regression", ["mode=published"]), ("analytics-regression", ["mode=studio"]), ("analytics-client", [])]
    # redesign: ground height + flow fields (server HeightGrid; flat fallback, ramp / cliff, routing, cave)
    checks += [("heightgrid-regression", [])]
    # redesign: the four class kits (signature weapons, passives, dash reactions) and an integrated
    # Cliffwood run per class (HeightGrid, class rig, weapon kills, stage 2 on the same map, pads, dash)
    checks += [("class-kits-sim", []), ("cliffwood-run-sim", [])]
    # redesign integration: basecamp avatar + camera, ClassService select / buy, gate -> local match on
    # Cliffwood with the class rig, results -> back at the bonfire, rewards once, a 2-player party
    checks += [("swarm-v2-flow", [])]
    # continuation pack, stream B: rank builds + combat core (formulas, offers, rarity / category
    # distributions, slots, evolutions, heal fallback, deadlines, rerolls, statuses, budget, line of
    # sight); choice-regression also runs once with the old 12-level system switched back on
    checks += [("builds-sim", []), ("choice-regression", ["builds=legacy"])]

    def run(check):
        scene, settings = check
        name = scene + ("-" + "-".join(settings).replace("=", "-") if settings else "")
        scripts = {"ui": "ui_regression.luau", "menu": "menu_clarity_regression.luau", "discovery": "menu_discovery_regression.luau", "pings": "team_pings_regression.luau", "uistate": "uistate_regression.luau"}
        command = [args.lune, "run", "tools/" + scripts[scene], *settings] if scene in scripts else [
            args.lune, "run", "tools/preview/runtime/main.luau", "--", "--scene", scene,
            "--studio", "--device", "pc", "--out", str(args.out / (name + ".json")),
            "--max-time", "3000" if scene in ("corner-regression", "class-kits-sim", "cliffwood-run-sim", "swarm-v2-flow") else "400", "--set", "headless=on",
        ]
        # Live-store and teleport fixtures intentionally run outside Studio.
        if scene in ("storage-sim", "runserver-sim", "difficulty-handoff", "coop-regression", "reconnect-lobby", "safety-sim", "security-regression", "heroes-regression", "store-regression", "starter-bundle-regression", "invite-regression", "bugreport-plus-regression") or (scene == "quick-resume-regression" and settings and settings[0] in ("case=run", "case=lobby")) or (scene == "analytics-regression" and settings == ["mode=published"]):
            command.remove("--studio")
        # results-flow drives the client results screen, so it needs the client running
        if scene in ("results-flow", "leaderboards", "home-board-regression", "run-intro", "results", "lobby-screens-regression", "hud-key-regression", "perf-regression", "events-fx", "textfit-regression", "analytics-client", "swarm-v2-flow"):
            command.remove("--set")
            command.remove("headless=on")
        if scene == "textfit-regression":
            command[command.index("--device") + 1] = "iphone"
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
            # Long client scenes: 220-290 s each when run alone (menu was 267 s before the
            # features batch too, so this is Lune time, not game cost); with three workers in
            # parallel they pass 360 s, so they get 600 s.
            limit = 1500 if scene in ("corner-regression", "world-regression", "reward-once-regression", "stage-sim", "run-entry-regression", "class-kits-sim", "cliffwood-run-sim", "swarm-v2-flow") else (
                600 if scene in ("menu", "ui", "run-intro", "events-fx", "loot-focus-regression", "perf-regression", "results-flow", "textfit-regression", "comeback-regression", "analytics-client")
                or (scene == "layout" and settings[0] == "smart-tutorial-regression") else 360)
            result = subprocess.run(command, cwd=repo, capture_output=True, text=True, encoding="utf-8", errors="replace", timeout=limit)
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

    if args.only:
        wanted = set(n.strip() for n in args.only.split(",") if n.strip())

        def check_name(check):
            scene, settings = check
            return scene + ("-" + "-".join(settings).replace("=", "-") if settings else "")
        checks = [c for c in checks if check_name(c) in wanted]
    with concurrent.futures.ThreadPoolExecutor(max_workers=args.workers) as pool:
        results = list(pool.map(run, checks))
    (args.out / "results.json").write_text(json.dumps(results, indent=2), encoding="utf-8")
    print(f"{sum(item['passed'] for item in results)}/{len(results)} checks passed; evidence: {args.out}")
    return 0 if all(item["passed"] for item in results) else 1


if __name__ == "__main__":
    sys.exit(main())
