"""Portable counterpart to check.sh; every tool's exit status is checked."""
import argparse
import os
from pathlib import Path
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parent.parent


def run(command):
    result = subprocess.run(command, cwd=ROOT, text=True, encoding="utf-8", errors="replace",
                            stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    if result.returncode:
        raise SystemExit(f"Command failed ({result.returncode}): {command[0]}\n{result.stdout}")
    return result.stdout


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--tools", type=Path, default=Path(os.environ.get("SWARM_TOOLS", ROOT.parent / "toolchain")))
    parser.add_argument("--rojo", default=os.environ.get("SWARM_ROJO", "rojo"))
    parser.add_argument("--quick", action="store_true")
    args = parser.parse_args()
    tools = args.tools.resolve()
    lsp = str(tools / "lsp" / ("luau-lsp.exe" if os.name == "nt" else "luau-lsp"))
    compiler = tools / "luau" / ("luau-compile.exe" if os.name == "nt" else "luau-compile")
    with tempfile.TemporaryDirectory(prefix="swarm-check-") as temp:
        sourcemap = str(Path(temp) / "sourcemap.json")
        run([args.rojo, "sourcemap", "default.project.json", "-o", sourcemap])
        output = run([lsp, "analyze", f"--definitions={tools / 'globalTypes.d.luau'}", f"--sourcemap={sourcemap}", "src"])
        diagnostics = [line for line in output.splitlines() if line and not line.startswith(("[INFO]", "[WARN]"))]
        if diagnostics:
            raise SystemExit("\n".join(diagnostics))
        print("TYPECHECK: ok")
        for source in sorted((ROOT / "src").rglob("*")):
            if source.suffix in (".lua", ".luau"):
                run([str(compiler), "-O0", "--null", str(source)])
        print("COMPILE: ok")
        print(run([sys.executable, "-X", "utf8", "tools/check_icon_art.py"]).strip())
        if not args.quick:
            run([args.rojo, "build", "default.project.json", "-o", str(Path(temp) / "Swarm.rbxlx")])
            print("BUILD: ok")


if __name__ == "__main__":
    main()
