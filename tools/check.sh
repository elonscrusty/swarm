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
STATUS=0
RAW="$("$LSP" analyze --definitions="$T/globalTypes.d.luau" --sourcemap="$SM" src 2>&1)" || STATUS=$?
OUT="$(printf '%s\n' "$RAW" | grep -v -E '^\[(INFO|WARN)\]' || true)"
if [ "$STATUS" -ne 0 ] || [ -n "$OUT" ]; then
	echo "$OUT"
	echo "TYPECHECK exit status: $STATUS"
	echo "TYPECHECK: $(echo "$OUT" | wc -l) problem(s)"
	exit 1
fi
echo "TYPECHECK: ok"

# Compile every script unoptimised, as Studio does: catches compile-only errors such as
# "Out of local registers" (more than 200 locals alive in one function or module chunk).
COMPILE="$T/luau/luau-compile"
if [ -x "$COMPILE" ]; then
	while IFS= read -r f; do
		if ! COUT="$("$COMPILE" -O0 --null "$f" 2>&1)"; then
			echo "$f: $COUT"
			echo "COMPILE: failed"
			exit 1
		fi
	done < <(find src -name '*.lua' -o -name '*.luau')
	echo "COMPILE: ok"
fi

# Small-art icon keys: every key Icons.lua wires has its PNG and a drawn fallback.
python3 tools/check_icon_art.py

if [ "${1:-}" != "--quick" ]; then
	"$ROJO" build default.project.json -o "$(dirname "$SM")/Swarm.rbxlx" >/dev/null
	echo "BUILD: ok"
fi
