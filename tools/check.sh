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
OUT="$("$LSP" analyze --definitions="$T/globalTypes.d.luau" --sourcemap="$SM" src 2>&1 || true)"
if [ -n "$OUT" ]; then
	echo "$OUT"
	echo "TYPECHECK: $(echo "$OUT" | wc -l) problem(s)"
	exit 1
fi
echo "TYPECHECK: ok"

if [ "${1:-}" != "--quick" ]; then
	"$ROJO" build default.project.json -o "$(dirname "$SM")/Swarm.rbxlx" >/dev/null
	echo "BUILD: ok"
fi
