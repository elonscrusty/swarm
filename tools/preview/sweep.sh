#!/usr/bin/env bash
# Every lobby screen in one Lune run per device (scene lobby-sweep, preview.snapshot), then
# PNGs and the layout check. docs/MOBILE_FIX.md.
#   bash tools/preview/sweep.sh OUTDIR [--devices iphone,phone-portrait,phone] [--set k=v ...]
#                               [--repo PATH] [--no-png]
# Waits while another Lune process runs (one Lune at a time on shared machines).
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
T="${SWARM_TOOLS:-/tmp/sh-tools}"
LUNE="$T/lune/lune"
OUT="${1:?usage: sweep.sh OUTDIR [--devices ...] [--set k=v]}"; shift
DEVICES="iphone,phone-portrait,phone"
EXTRA=()
PNG=1
while [ $# -gt 0 ]; do
	case "$1" in
		--devices) DEVICES="$2"; shift 2 ;;
		--set) EXTRA+=("--set" "$2"); shift 2 ;;
		--repo) REPO="$(cd "$2" && pwd)"; shift 2 ;;
		--no-png) PNG=0; shift ;;
		*) echo "unknown option $1"; exit 2 ;;
	esac
done
mkdir -p "$OUT"
OUT="$(cd "$OUT" && pwd)"
IFS=',' read -ra DEV <<< "$DEVICES"
for d in "${DEV[@]}"; do
	while [ "$(pgrep -cx lune || true)" -ge 1 ]; do sleep 0.5; done
	"$LUNE" run "$HERE/runtime/main.luau" -- --scene lobby-sweep --device "$d" --out "$OUT/.sweep-$d.json" \
		--repo "$REPO" --root "$HERE" --max-time 400 ${EXTRA[@]+"${EXTRA[@]}"} 2>&1 | grep -E "^\[preview\]|FAIL|error|Error" | grep -v "snapshot" || true
	rm -f "$OUT/.sweep-$d.json" "$OUT/.sweep-$d.metrics.json"
done
if [ "$PNG" = 1 ]; then
	JOBS=()
	for j in "$OUT"/*.json; do
		case "$j" in *.metrics.json) continue ;; esac
		JOBS+=(--job "$j:${j%.json}.png")
	done
	node "$HERE/renderer/render.mjs" --repo "$REPO" "${JOBS[@]}" | tail -2
fi
python3 "$HERE/check_layout.py" "$OUT" --quiet || true
