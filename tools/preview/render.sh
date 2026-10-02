#!/usr/bin/env bash
# Offline preview renderer for SWARM (docs/PREVIEW.md).
#
#   bash tools/preview/render.sh <scene> [--device pc|laptop|phone|iphone|phone-portrait|tablet]
#                                [--out file.png] [--seed N] [--repo PATH] [--studio]
#                                [--set key=value] [--json file.json] [--no-coreui]
#                                [--ref GIT_REF]   render a committed version (snapshot)
#   bash tools/preview/render.sh <scene>[,<scene>...] --devices pc,phone [--outdir DIR]
#   bash tools/preview/render.sh --all [--outdir DIR]      every scene x every device
#   bash tools/preview/render.sh --check-meshes            FBX pieces vs catalog offsets
#
# Step 1 runs the real game modules on a mock Roblox API (Lune) and writes scene JSON;
# step 2 draws it with three.js in headless Chromium. Scene JSON and metrics land next
# to the PNG (*.json) when --json / --outdir is used.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO_DEFAULT="$(cd "$HERE/../.." && pwd)"
T="${SWARM_TOOLS:-/tmp/sh-tools}"
LUNE="$T/lune/lune"

if [ ! -x "$LUNE" ] || [ ! -d "$HERE/node_modules/three" ] || [ ! -f "$HERE/.cache/fonts/metrics.json" ]; then
	bash "$HERE/setup.sh"
fi

SCENES=""
DEVICES=""
OUT=""
OUTDIR=""
JSON=""
REPO="$REPO_DEFAULT"
EXTRA=()
ALL=0
CHECK=0
REF=""
while [ $# -gt 0 ]; do
	case "$1" in
		--device|--devices) DEVICES="$2"; shift 2 ;;
		--out) OUT="$2"; shift 2 ;;
		--outdir) OUTDIR="$2"; shift 2 ;;
		--json) JSON="$2"; shift 2 ;;
		--repo) REPO="$(cd "$2" && pwd)"; shift 2 ;;
		--ref) REF="$2"; shift 2 ;;
		--seed|--set|--wait-timeout|--max-time) EXTRA+=("$1" "$2"); shift 2 ;;
		--studio|--no-coreui|--print-metrics) EXTRA+=("$1"); shift ;;
		--all) ALL=1; shift ;;
		--check-meshes) CHECK=1; shift ;;
		-h|--help) sed -n '2,16p' "$0"; exit 0 ;;
		*) SCENES="$1"; shift ;;
	esac
done

# --ref <git ref>: render a committed version (e.g. HEAD or main~3) from a clean snapshot,
# so before/after comparisons don't depend on uncommitted work in the tree.
if [ -n "$REF" ]; then
	SNAP="$(mktemp -d)"
	git -C "$REPO_DEFAULT" archive "$REF" | tar -x -C "$SNAP"
	REPO="$SNAP"
	echo "render: using $REF ($(git -C "$REPO_DEFAULT" rev-parse --short "$REF")) from a snapshot"
fi

if [ "$CHECK" = 1 ]; then
	exec node "$HERE/renderer/render.mjs" --check-meshes --repo "$REPO"
fi

if [ "$ALL" = 1 ]; then
	SCENES="$(cd "$HERE/scenes" && ls *.luau | grep -v '^_' | sed 's/\.luau$//' | paste -sd, -)"
	DEVICES="${DEVICES:-pc,laptop,phone,phone-portrait,tablet}"
	OUTDIR="${OUTDIR:-$HERE/out/all}"
fi
if [ -z "$SCENES" ]; then
	echo "usage: bash tools/preview/render.sh <scene> [--device phone] [--out file.png]  (scenes: $(cd "$HERE/scenes" && ls *.luau | grep -v '^_' | sed 's/\.luau$//' | paste -sd' ' -))"
	exit 2
fi
DEVICES="${DEVICES:-pc}"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP" ${SNAP:+"$SNAP"}' EXIT
JOBS=()
IFS=',' read -ra SCENE_LIST <<< "$SCENES"
IFS=',' read -ra DEVICE_LIST <<< "$DEVICES"
N=0
for s in "${SCENE_LIST[@]}"; do
	for d in "${DEVICE_LIST[@]}"; do
		if [ -n "$OUTDIR" ]; then
			png="$OUTDIR/$s-$d.png"; json="$OUTDIR/$s-$d.json"
		elif [ -n "$OUT" ] && [ ${#SCENE_LIST[@]} -eq 1 ] && [ ${#DEVICE_LIST[@]} -eq 1 ]; then
			png="$OUT"; json="${JSON:-$TMP/$s-$d.json}"
		else
			png="$HERE/out/$s-$d.png"; json="${JSON:-$HERE/out/$s-$d.json}"
		fi
		mkdir -p "$(dirname "$png")" "$(dirname "$json")"
		N=$((N + 1))
		{
			printf '%q ' "$LUNE" run "$HERE/runtime/main.luau" -- --scene "$s" --device "$d" --out "$json" --repo "$REPO" --root "$HERE" ${EXTRA[@]+"${EXTRA[@]}"}
			printf '> %q 2>&1; cat %q\n' "$TMP/$s-$d.log" "$TMP/$s-$d.log"
		} > "$TMP/job_$(printf %03d $N).sh"
		JOBS+=(--job "$json:$png")
	done
done

# step 1: game code on the mock runtime (parallel)
ls "$TMP"/job_*.sh | xargs -P "${PREVIEW_JOBS:-4}" -n 1 bash
# step 2: draw
node "$HERE/renderer/render.mjs" --repo "$REPO" "${JOBS[@]}"
