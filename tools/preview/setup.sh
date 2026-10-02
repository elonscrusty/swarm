#!/usr/bin/env bash
# Installs what the preview renderer needs (idempotent): Lune 0.10.4, three.js, fonts.
#   bash tools/preview/setup.sh
# Chromium comes from the global Playwright install (/opt/pw-browsers); never run
# `playwright install`.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
T="${SWARM_TOOLS:-/tmp/sh-tools}"
LUNE="$T/lune/lune"
LUNE_VERSION="0.10.4"

if [ ! -x "$LUNE" ] || ! "$LUNE" --version 2>/dev/null | grep -q "$LUNE_VERSION"; then
	echo "setup: installing Lune $LUNE_VERSION"
	mkdir -p "$T/lune"
	tmp="$(mktemp -d)"
	curl -fsSL -o "$tmp/lune.zip" "https://github.com/lune-org/lune/releases/download/v$LUNE_VERSION/lune-$LUNE_VERSION-linux-x86_64.zip"
	python3 -c "import sys, zipfile; zipfile.ZipFile(sys.argv[1]).extractall(sys.argv[2])" "$tmp/lune.zip" "$T/lune"
	chmod +x "$LUNE"
	rm -rf "$tmp"
fi

if [ ! -d "$HERE/node_modules/three" ]; then
	echo "setup: npm install (three.js)"
	(cd "$HERE" && npm install --no-audit --no-fund --silent)
fi

python3 "$HERE/fonts/fetch_fonts.py"
echo "setup: ok (lune $("$LUNE" --version | awk '{print $2}'), three $(node -p "require('$HERE/node_modules/three/package.json').version"))"
