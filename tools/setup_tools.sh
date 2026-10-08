#!/usr/bin/env bash
# Installs the check tools into "${SWARM_TOOLS:-/tmp/sh-tools}" (idempotent; re-running skips
# what is already in place):
#   $T/rojo/rojo                 Rojo 7.4.4 (rojo-rbx/rojo)
#   $T/lsp/luau-lsp              luau-lsp 1.52.1 (JohnnyMorganz/luau-lsp)
#   $T/globalTypes.d.luau        Roblox global types for luau-lsp
#   $T/luau/luau-compile         luau-compile (luau-lang/luau, luau-ubuntu.zip)
# then runs tools/preview/setup.sh (Lune for the preview renderer).
#   bash tools/setup_tools.sh
set -euo pipefail
cd "$(dirname "$0")/.."
T="${SWARM_TOOLS:-/tmp/sh-tools}"
ROJO_VERSION="7.4.4"
LSP_VERSION="1.52.1"

# Downloads are fetched with curl -fsSL (TLS verification stays on; the agent proxy CA is
# picked up from the environment) and unpacked with python3 zipfile.
fetch() { # url dest
	curl -fsSL -o "$2" "$1"
}

extract_bin() { # zip binary-name dest
	local zip="$1" name="$2" dest="$3" tmp src
	tmp="$(mktemp -d)"
	python3 -c "import sys, zipfile; zipfile.ZipFile(sys.argv[1]).extractall(sys.argv[2])" "$zip" "$tmp"
	src="$(find "$tmp" -type f -name "$name" | head -n 1)"
	if [ -z "$src" ]; then
		echo "setup_tools: $name not found in $(basename "$zip")" >&2
		rm -rf "$tmp"
		exit 1
	fi
	cp -f "$src" "$dest"
	chmod +x "$dest"
	rm -rf "$tmp"
}

mkdir -p "$T/rojo" "$T/lsp" "$T/luau"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# Rojo
if ! { [ -x "$T/rojo/rojo" ] && "$T/rojo/rojo" --version 2>/dev/null | grep -q "$ROJO_VERSION"; }; then
	echo "setup_tools: installing Rojo $ROJO_VERSION"
	fetch "https://github.com/rojo-rbx/rojo/releases/download/v$ROJO_VERSION/rojo-$ROJO_VERSION-linux-x86_64.zip" "$TMP/rojo.zip"
	extract_bin "$TMP/rojo.zip" rojo "$T/rojo/rojo"
fi

# luau-lsp
if ! { [ -x "$T/lsp/luau-lsp" ] && "$T/lsp/luau-lsp" version 2>/dev/null | grep -q "$LSP_VERSION"; }; then
	echo "setup_tools: installing luau-lsp $LSP_VERSION"
	fetch "https://github.com/JohnnyMorganz/luau-lsp/releases/download/$LSP_VERSION/luau-lsp-linux.zip" "$TMP/luau-lsp.zip"
	extract_bin "$TMP/luau-lsp.zip" luau-lsp "$T/lsp/luau-lsp"
fi

# Roblox global type definitions (main branch file; a versioned globalTypes.None.d.luau
# is not needed because the unversioned file exists).
if [ ! -s "$T/globalTypes.d.luau" ]; then
	echo "setup_tools: fetching globalTypes.d.luau"
	fetch "https://raw.githubusercontent.com/JohnnyMorganz/luau-lsp/main/scripts/globalTypes.d.luau" "$T/globalTypes.d.luau"
fi

# luau-compile (latest stable release of luau-lang/luau)
if [ ! -x "$T/luau/luau-compile" ]; then
	echo "setup_tools: installing luau-compile"
	fetch "https://github.com/luau-lang/luau/releases/latest/download/luau-ubuntu.zip" "$TMP/luau.zip"
	extract_bin "$TMP/luau.zip" luau-compile "$T/luau/luau-compile"
fi

echo "setup_tools: rojo $("$T/rojo/rojo" --version | awk '{print $2}'), luau-lsp $("$T/lsp/luau-lsp" version 2>/dev/null | grep -o '[0-9][0-9.]*' | head -n 1 || true), luau-compile ok"

# Lune and three.js for the preview renderer (idempotent itself).
SWARM_TOOLS="$T" bash tools/preview/setup.sh
echo "setup_tools: ok"
