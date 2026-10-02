#!/usr/bin/env bash
# Type check (luau-lsp with Roblox types, strict about new problems) and Rojo build.
# Usage: bash tools/check.sh [--quick]   (--quick skips the place build)
# Needs rojo and luau-lsp; set SWARM_TOOLS to a folder holding rojo/rojo, lsp/luau-lsp and
# globalTypes.d.luau (defaults to /tmp/sh-tools, the cloud session's tool cache).
set -euo pipefail
cd "$(dirname "$0")/.."
T="${SWARM_TOOLS:-/tmp/sh-tools}"
ROJO="$T/rojo/rojo"
LSP="$T/lsp/luau-lsp"
SM="$(mktemp -d)/sourcemap.json"

"$ROJO" sourcemap default.project.json -o "$SM" >/dev/null
OUT="$("$LSP" analyze --definitions="$T/globalTypes.d.luau" --sourcemap="$SM" src 2>&1 | grep -v -E '^\[(INFO|WARN)\]' || true)"
if [ -n "$OUT" ]; then
	echo "$OUT"
	echo "TYPECHECK: $(echo "$OUT" | wc -l) problem(s)"
	exit 1
fi
echo "TYPECHECK: ok"

# Compile every script unoptimised, as Studio does: catches compile-only errors such as
# "Out of local registers" (more than 200 locals alive in one function or module chunk).
COMPILE="$T/luau/luau-compile"
if [ -x "$COMPILE" ]; then
	CERR="$(find src -name '*.lua' -o -name '*.luau' | while read -r f; do "$COMPILE" -O0 --null "$f" 2>&1 | grep -i error || true; done)"
	if [ -n "$CERR" ]; then
		echo "$CERR"
		echo "COMPILE: failed"
		exit 1
	fi
	echo "COMPILE: ok"
fi

# Small-art icon keys: every key Icons.lua wires has its PNG and a drawn fallback.
python3 tools/check_icon_art.py

if [ "${1:-}" != "--quick" ]; then
	"$ROJO" build default.project.json -o "$(dirname "$SM")/Swarm.rbxlx" >/dev/null
	echo "BUILD: ok"
fi
